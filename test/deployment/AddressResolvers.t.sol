// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployETHfxUSDSetUp} from "@harbor-test/deployment/DeployETHfxUSD.t.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Genesis_v2} from "@harbor/minter/Genesis_v2.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {Config_MinterMarket, Market} from "@harbor-script/config/ConfigBase.sol";

/// @notice Verifies that every predicted-address resolver on HarborDeployer names the contract the
///         deploy actually built there.
/// @dev The resolvers are the single home of each salt sub-key, and the deploy reaches every contract
///      through them, so a mistyped sub-key would silently produce a codeless address that only fails
///      much later, as a call to a non-contract. These tests turn that into an immediate, local failure.
///      Each resolver is checked two ways: the address has code, and the contract standing there names
///      its own dependencies as the OTHER resolvers name them — so the set has to agree with itself and
///      with what the deploy wired.
contract AddressResolversTest is DeployETHfxUSDSetUp {
    Config_MinterMarket internal market;

    function setUp() public override {
        super.setUp();
        // Same config source the deploy used, so the keys under test are not a second copy.
        (, Config_MinterMarket[] memory mktConfigs) = ethMintersConfig();
        market = mktConfigs[0];
    }

    /// Every resolver points at deployed code — the minimum a mistyped sub-key would break.
    function test_everyResolverPointsAtDeployedCode() public {
        assertGt(deployRun.peggedTokenAddress(market).code.length, 0, "peggedTokenAddress");
        assertGt(deployRun.leveragedTokenAddress(market).code.length, 0, "leveragedTokenAddress");
        assertGt(deployRun.minterAddress(market).code.length, 0, "minterAddress");
        assertGt(deployRun.reservePoolAddress(market).code.length, 0, "reservePoolAddress");
        assertGt(
            deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral).code.length,
            0,
            "stabilityPoolAddress(Collateral)"
        );
        assertGt(
            deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Leveraged).code.length,
            0,
            "stabilityPoolAddress(Leveraged)"
        );
        assertGt(deployRun.stabilityPoolManagerAddress(market).code.length, 0, "stabilityPoolManagerAddress");
        assertGt(deployRun.genesisAddress(market).code.length, 0, "genesisAddress");
    }

    /// The two forms of each resolver agree: naming a market by its config and by its (peg, collateral)
    /// components must land on the same address, or one population of callers is silently off.
    function test_theConfigAndMarketFormsAgree() public {
        Market memory named = Market("ETH", "fxUSD");
        assertEq(deployRun.minterAddress(market), deployRun.minterAddress(named), "minterAddress");
        assertEq(deployRun.peggedTokenAddress(market), deployRun.peggedTokenAddress(named.peg), "peggedTokenAddress");
        assertEq(
            deployRun.leveragedTokenAddress(market),
            deployRun.leveragedTokenAddress(named),
            "leveragedTokenAddress"
        );
        assertEq(deployRun.reservePoolAddress(market), deployRun.reservePoolAddress(named), "reservePoolAddress");
        assertEq(deployRun.genesisAddress(market), deployRun.genesisAddress(named), "genesisAddress");
        assertEq(
            deployRun.stabilityPoolManagerAddress(market),
            deployRun.stabilityPoolManagerAddress(named),
            "stabilityPoolManagerAddress"
        );
        assertEq(
            deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral),
            deployRun.stabilityPoolAddress(named, HarborDeployer.StabilityPoolType.Collateral),
            "stabilityPoolAddress(Collateral)"
        );
        assertEq(
            deployRun.wrappedPriceOracleAddress(market),
            deployRun.wrappedPriceOracleAddress(named),
            "wrappedPriceOracleAddress"
        );
    }

    /// The Minter's baked-in token addresses are the ones the token resolvers name.
    function test_minterNamesTheTokenResolvers() public {
        IMinter deployedMinter = IMinter(deployRun.minterAddress(market));
        assertEq(deployedMinter.PEGGED_TOKEN(), deployRun.peggedTokenAddress(market), "PEGGED_TOKEN");
        assertEq(deployedMinter.LEVERAGED_TOKEN(), deployRun.leveragedTokenAddress(market), "LEVERAGED_TOKEN");
    }

    /// Genesis's baked-in minter and token addresses are the ones the corresponding resolvers name.
    /// @dev Its fourth immutable, WRAPPED_COLLATERAL_TOKEN, is not asserted here: that address comes from
    ///      the market config rather than from a CREATE3 salt, so no resolver names it.
    function test_genesisNamesTheMinterAndTokenResolvers() public {
        Genesis_v2 deployedGenesis = Genesis_v2(deployRun.genesisAddress(market));
        assertEq(deployedGenesis.MINTER(), deployRun.minterAddress(market), "MINTER");
        assertEq(deployedGenesis.PEGGED_TOKEN(), deployRun.peggedTokenAddress(market), "PEGGED_TOKEN");
        assertEq(deployedGenesis.LEVERAGED_TOKEN(), deployRun.leveragedTokenAddress(market), "LEVERAGED_TOKEN");
    }

    /// The StabilityPoolManager's baked-in minter, and the two pools it manages, are what the resolvers name.
    function test_stabilityPoolManagerNamesTheMinterAndBothPools() public {
        IStabilityPoolManager deployedManager = IStabilityPoolManager(deployRun.stabilityPoolManagerAddress(market));
        assertEq(
            StabilityPoolManagerMinter(address(deployedManager)).MINTER(),
            deployRun.minterAddress(market),
            "MINTER"
        );

        address[] memory pools = deployedManager.stabilityPools();
        assertEq(pools.length, 2, "pool count");
        assertEq(
            pools[0],
            deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral),
            "pools[0]"
        );
        assertEq(
            pools[1],
            deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Leveraged),
            "pools[1]"
        );
    }

    /// The two stability-pool resolvers name distinct pools, each distributing the reward tokens its type
    /// implies — the check that would catch the two pool sub-keys being swapped or duplicated.
    ///
    /// A pool's type lives in its registered reward tokens, which are the tokens a rebalance may pay it in.
    /// Both pools take wrapped collateral: as harvest yield, and as the proceeds of a rebalance where the
    /// market sells no leverage. Only the leveraged pool takes the leveraged token, the proceeds of a
    /// rebalance where it does.
    function test_theTwoStabilityPoolResolversNameDistinctCorrectlyTypedPools() public {
        address collateralPool = deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral);
        address leveragedPool = deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Leveraged);
        assertNotEq(collateralPool, leveragedPool, "the two pools must be distinct");

        address wrappedCollateral = IMinter(deployRun.minterAddress(market)).WRAPPED_COLLATERAL_TOKEN();
        address leveraged = deployRun.leveragedTokenAddress(market);
        assertTrue(
            IMultipleRewardDistributor(collateralPool).isActiveRewardToken(wrappedCollateral),
            "the collateral pool distributes wrapped collateral"
        );
        assertFalse(
            IMultipleRewardDistributor(collateralPool).isActiveRewardToken(leveraged),
            "the collateral pool is paid in collateral on every route, so it does not distribute the leveraged token"
        );
        assertTrue(
            IMultipleRewardDistributor(leveragedPool).isActiveRewardToken(wrappedCollateral),
            "the leveraged pool distributes wrapped collateral"
        );
        assertTrue(
            IMultipleRewardDistributor(leveragedPool).isActiveRewardToken(leveraged),
            "the leveraged pool distributes the leveraged token"
        );
    }

    /// The reserve pool resolver names the pool that granted REQUESTER_ROLE to the resolved minter.
    function test_reservePoolResolverNamesThePoolWiredToTheMinter() public {
        address deployedReservePool = deployRun.reservePoolAddress(market);
        assertTrue(
            IBaoRoles(deployedReservePool).hasAllRoles(
                deployRun.minterAddress(market),
                ReservePool_v2(deployedReservePool).REQUESTER_ROLE()
            ),
            "minter holds REQUESTER_ROLE on the resolved reserve pool"
        );
    }
}

/// @dev `MINTER` is declared on StabilityPoolManager_v2 rather than on IStabilityPoolManager.
interface StabilityPoolManagerMinter {
    function MINTER() external view returns (address);
}
