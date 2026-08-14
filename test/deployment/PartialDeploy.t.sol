// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";

/// @notice A market can be deployed a contract at a time, stopping anywhere, and what has been deployed is
///         complete rather than half-configured.
/// @dev Each contract's deploy function deploys AND configures it, so a caller who wants less calls a shorter
///      prefix of the same list instead of a different function. Asserting that a prefix works BY ITSELF is the
///      only thing that distinguishes this from a set of calls that merely happen to run in order — were the
///      contracts still entangled, stopping early would revert or leave what was deployed unusable.
abstract contract PartialDeploySetUp is BaoTest, Deploy_ETH_Minter {
    Config_MinterMarket internal market;

    /// @dev Deploys the peg's shared pegged token, then the market's leveraged token, reserve pool and minter —
    ///      the shortest prefix that yields a usable minter. Returns the deployment state so a subclass can
    ///      carry on: the struct holds dynamic arrays, which the legacy pipeline cannot copy into storage, so
    ///      it has to stay a memory value passed hand to hand.
    function _deployMinter(string memory saltPrefix) internal returns (DeploymentTypes.State memory state) {
        forkMainnetWithBaoFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];

        _setSaltPrefix(saltPrefix);
        state = DeploymentState.fresh(saltPrefix, "mainnet");
        state.baoFactory = baoFactory();

        deployPeggedTokenWithRoles(state, peg, mktConfigs);

        _deployLeveragedTokenWithRoles(state, market);
        deployReservePool(state, market);
        deployMinter(state, market);
    }
}

/// Stopping at the minter: a usable, fully wired minter, with nothing above it deployed.
contract MinterOnlyDeployTest is PartialDeploySetUp {
    function setUp() public {
        _deployMinter("partial_minter");
    }

    /// The minter is configured, not merely present — its deploy function sets every dependency it needs.
    function test_minterIsWiredNotMerelyDeployed() public {
        address minter = minterAddress(market);
        assertGt(minter.code.length, 0, "minter deployed");
        assertGt(leveragedTokenAddress(market).code.length, 0, "leveraged token deployed");
        assertGt(reservePoolAddress(market).code.length, 0, "reserve pool deployed");

        assertEq(IMinter_v3(minter).reservePool(), reservePoolAddress(market), "reservePool wired");
        assertEq(IMinter_v3(minter).priceOracle(), wrappedPriceOracleAddress(market), "priceOracle wired");
        assertEq(IMinter(minter).feeReceiver(), treasury(), "feeReceiver wired");
    }

    /// The discriminating assertion. Were the contracts still entangled, these would have code too.
    function test_minterDeploysNothingAboveIt() public {
        assertEq(
            stabilityPoolAddress(market, StabilityPoolType.Collateral).code.length,
            0,
            "collateral stability pool NOT deployed"
        );
        assertEq(
            stabilityPoolAddress(market, StabilityPoolType.Leveraged).code.length,
            0,
            "leveraged stability pool NOT deployed"
        );
        assertEq(stabilityPoolManagerAddress(market).code.length, 0, "stability pool manager NOT deployed");
        assertEq(genesisAddress(market).code.length, 0, "genesis NOT deployed");
    }

    /// Each contract grants its own roles as part of being deployed, including to grantees that do not exist
    /// yet — granting to a predicted CREATE3 address is the property the whole arrangement rests on.
    function test_deployGrantsItsOwnRoles() public {
        address minter = minterAddress(market);
        address reservePool = reservePoolAddress(market);

        assertTrue(
            IBaoRoles(reservePool).hasAllRoles(minter, ReservePool_v2(reservePool).REQUESTER_ROLE()),
            "minter holds REQUESTER_ROLE on the reserve pool"
        );
        assertTrue(
            IBaoRoles(minter).hasAllRoles(stabilityPoolManagerAddress(market), IMinter(minter).HARVESTER_ROLE()),
            "the not-yet-deployed manager already holds HARVESTER_ROLE on the minter"
        );
        assertTrue(
            IBaoRoles(minter).hasAllRoles(genesisAddress(market), IMinter(minter).ZERO_FEE_ROLE()),
            "the not-yet-deployed genesis already holds ZERO_FEE_ROLE on the minter"
        );
    }
}

/// Carrying on into the stability pools: they come up complete, and nothing beneath them is disturbed.
contract MinterAndStabilityPoolsDeployTest is PartialDeploySetUp {
    function setUp() public {
        DeploymentTypes.State memory state = _deployMinter("partial_pools");

        deployStabilityPool(StabilityPoolType.Collateral, state, market);
        deployStabilityPool(StabilityPoolType.Leveraged, state, market);
    }

    function test_poolDeployBringsUpPoolsWithoutDisturbingTheMinter() public {
        assertGt(stabilityPoolAddress(market, StabilityPoolType.Collateral).code.length, 0, "collateral pool deployed");
        assertGt(stabilityPoolAddress(market, StabilityPoolType.Leveraged).code.length, 0, "leveraged pool deployed");

        address minter = minterAddress(market);
        assertGt(minter.code.length, 0, "the minter beneath is still there");
        assertEq(IMinter_v3(minter).reservePool(), reservePoolAddress(market), "the minter is still wired");

        assertEq(stabilityPoolManagerAddress(market).code.length, 0, "stability pool manager NOT deployed");
        assertEq(genesisAddress(market).code.length, 0, "genesis NOT deployed");
    }

    /// The two pools take different reward tokens, and each registers exactly its own as part of deploying:
    /// both earn harvest rewards in wrapped collateral, and only the leveraged pool receives leveraged tokens
    /// from rebalances. Asserting the full arrays (one entry, then two) pins the difference in both directions.
    function test_poolsRegisterExactlyTheirOwnRewardTokens() public {
        address wrappedCollateral = IHarborConfig(address(market)).wrappedCollateralToken();

        address[] memory collateralPoolRewards = IMultipleRewardDistributor(
            stabilityPoolAddress(market, StabilityPoolType.Collateral)
        ).activeRewardTokens();
        assertEq(collateralPoolRewards.length, 1, "collateral pool has one reward token");
        assertEq(collateralPoolRewards[0], wrappedCollateral, "collateral pool earns wrapped collateral");

        address[] memory leveragedPoolRewards = IMultipleRewardDistributor(
            stabilityPoolAddress(market, StabilityPoolType.Leveraged)
        ).activeRewardTokens();
        assertEq(leveragedPoolRewards.length, 2, "leveraged pool has two reward tokens");
        assertEq(leveragedPoolRewards[0], wrappedCollateral, "leveraged pool earns wrapped collateral");
        assertEq(leveragedPoolRewards[1], leveragedTokenAddress(market), "leveraged pool also earns leveraged tokens");
    }

    /// A pool's roles are read OFF the pool, so unlike every other grant this one needs its own contract to
    /// exist — which is exactly why it belongs to the pool's deploy function and not to a later step.
    function test_poolGrantsRolesToTheNotYetDeployedManager() public {
        address manager = stabilityPoolManagerAddress(market);
        assertEq(manager.code.length, 0, "the manager being granted to does not exist yet");

        address collateralPool = stabilityPoolAddress(market, StabilityPoolType.Collateral);
        assertTrue(
            IBaoRoles(collateralPool).hasAllRoles(
                manager,
                IStabilityPool(collateralPool).REBALANCER_ROLE() |
                    IMultipleRewardDistributor(collateralPool).REWARD_DEPOSITOR_ROLE()
            ),
            "manager holds REBALANCER | REWARD_DEPOSITOR on the collateral pool"
        );

        address leveragedPool = stabilityPoolAddress(market, StabilityPoolType.Leveraged);
        assertTrue(
            IBaoRoles(leveragedPool).hasAllRoles(
                manager,
                IStabilityPool(leveragedPool).REBALANCER_ROLE() |
                    IMultipleRewardDistributor(leveragedPool).REWARD_DEPOSITOR_ROLE()
            ),
            "manager holds REBALANCER | REWARD_DEPOSITOR on the leveraged pool"
        );
    }
}
