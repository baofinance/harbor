// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";

/// @notice A market's infrastructure deploys in three independent layers, and the lower ones stand alone.
/// @dev This is what the split exists for: a test needing only a minter should not have to deploy two stability
///      pools, a manager and a genesis contract to get one. Asserting that the minter layer works BY ITSELF is the
///      only thing that distinguishes a real split from three functions that happen to be called in order — if the
///      layers were still entangled, deploying just the first would revert or leave the minter unusable.
abstract contract DeployLayersSetUp is BaoTest, Deploy_ETH_Minter {
    Config_MinterMarket internal market;

    /// @dev Deploys the peg's shared pegged token and then `layers` of the market's infrastructure: 1 for the
    ///      minter layer alone, 2 to add the stability pools. The deployment state stays a memory local — its
    ///      struct holds dynamic arrays, which the legacy pipeline cannot copy into storage — and it is only
    ///      needed while deploying, since the assertions afterwards read addresses from the resolvers.
    function _deployLayers(string memory saltPrefix, uint256 layers) internal {
        address factory = _ensureBaoFactory();
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);
        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];

        _setSaltPrefix(saltPrefix);
        DeploymentTypes.State memory state = DeploymentState.fresh(saltPrefix, "mainnet");
        state.baoFactory = baoFactory();

        deployPeggedTokenWithRoles(state, peg, mktConfigs);

        deployMinterMarket(state, market);
        if (layers > 1) {
            deployStabilityPoolsForMarket(state, market);
        }
    }
}

/// The minter layer on its own: a usable, fully wired minter, with nothing above it deployed.
contract DeployMinterMarketOnlyTest is DeployLayersSetUp {
    function setUp() public {
        _deployLayers("layers_minter", 1);
    }

    function test_minterLayerAloneProducesAWiredMinter() public {
        address minter = minterAddress(market);
        assertGt(minter.code.length, 0, "minter deployed");
        assertGt(leveragedTokenAddress(market).code.length, 0, "leveraged token deployed");
        assertGt(reservePoolAddress(market).code.length, 0, "reserve pool deployed");

        // Wired, not merely present — the layer runs deployMinter, which configures as well as deploys.
        assertEq(IMinter_v3(minter).reservePool(), reservePoolAddress(market), "reservePool wired");
        assertEq(IMinter_v3(minter).priceOracle(), wrappedPriceOracleAddress(market), "priceOracle wired");
        assertEq(IMinter(minter).feeReceiver(), treasury(), "feeReceiver wired");
    }

    /// The discriminating assertion. Were the layers still entangled, these would have code too.
    function test_minterLayerDeploysNothingAboveIt() public {
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

    /// The roles the minter layer owns are granted by it, including those whose grantee does not exist yet —
    /// granting to a predicted CREATE3 address is what lets the layer stand alone.
    function test_minterLayerGrantsItsOwnRoles() public {
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
    }
}

/// Adding the pool layer on top brings up the pools without redeploying anything beneath them.
contract DeployStabilityPoolLayerTest is DeployLayersSetUp {
    function setUp() public {
        _deployLayers("layers_pools", 2);
    }

    function test_poolLayerAddsThePoolsAndLeavesTheManagerUndeployed() public {
        assertGt(
            stabilityPoolAddress(market, StabilityPoolType.Collateral).code.length,
            0,
            "collateral pool deployed"
        );
        assertGt(stabilityPoolAddress(market, StabilityPoolType.Leveraged).code.length, 0, "leveraged pool deployed");
        assertGt(minterAddress(market).code.length, 0, "the minter beneath is still there");

        assertEq(stabilityPoolManagerAddress(market).code.length, 0, "stability pool manager NOT deployed");
    }
}
