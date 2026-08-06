// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployETHfxUSDSetUp} from "@harbor-test/deployment/DeployETHfxUSD.t.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Genesis_v2} from "@harbor/minter/Genesis_v2.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
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
        (, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];
    }

    /// Every resolver points at deployed code — the minimum a mistyped sub-key would break.
    function test_everyResolverPointsAtDeployedCode() public {
        assertGt(peggedTokenAddress(market).code.length, 0, "peggedTokenAddress");
        assertGt(leveragedTokenAddress(market).code.length, 0, "leveragedTokenAddress");
        assertGt(minterAddress(market).code.length, 0, "minterAddress");
        assertGt(reservePoolAddress(market).code.length, 0, "reservePoolAddress");
        assertGt(
            stabilityPoolAddress(market, StabilityPoolType.Collateral).code.length,
            0,
            "stabilityPoolAddress(Collateral)"
        );
        assertGt(
            stabilityPoolAddress(market, StabilityPoolType.Leveraged).code.length,
            0,
            "stabilityPoolAddress(Leveraged)"
        );
        assertGt(stabilityPoolManagerAddress(market).code.length, 0, "stabilityPoolManagerAddress");
        assertGt(genesisAddress(market).code.length, 0, "genesisAddress");
    }

    /// The two forms of each resolver agree: naming a market by its config and by its (peg, collateral)
    /// components must land on the same address, or one population of callers is silently off.
    function test_theConfigAndMarketFormsAgree() public {
        Market memory named = Market("ETH", "fxUSD");
        assertEq(minterAddress(market), minterAddress(named), "minterAddress");
        assertEq(peggedTokenAddress(market), peggedTokenAddress(named.peg), "peggedTokenAddress");
        assertEq(leveragedTokenAddress(market), leveragedTokenAddress(named), "leveragedTokenAddress");
        assertEq(reservePoolAddress(market), reservePoolAddress(named), "reservePoolAddress");
        assertEq(genesisAddress(market), genesisAddress(named), "genesisAddress");
        assertEq(
            stabilityPoolManagerAddress(market),
            stabilityPoolManagerAddress(named),
            "stabilityPoolManagerAddress"
        );
        assertEq(
            stabilityPoolAddress(market, StabilityPoolType.Collateral),
            stabilityPoolAddress(named, StabilityPoolType.Collateral),
            "stabilityPoolAddress(Collateral)"
        );
        assertEq(wrappedPriceOracleAddress(market), wrappedPriceOracleAddress(named), "wrappedPriceOracleAddress");
    }

    /// The Minter's baked-in token addresses are the ones the token resolvers name.
    function test_minterNamesTheTokenResolvers() public {
        IMinter deployedMinter = IMinter(minterAddress(market));
        assertEq(deployedMinter.PEGGED_TOKEN(), peggedTokenAddress(market), "PEGGED_TOKEN");
        assertEq(deployedMinter.LEVERAGED_TOKEN(), leveragedTokenAddress(market), "LEVERAGED_TOKEN");
    }

    /// Genesis's baked-in minter and token addresses are the ones the corresponding resolvers name.
    /// @dev Its fourth immutable, WRAPPED_COLLATERAL_TOKEN, is not asserted here: that address comes from
    ///      the market config rather than from a CREATE3 salt, so no resolver names it.
    function test_genesisNamesTheMinterAndTokenResolvers() public {
        Genesis_v2 deployedGenesis = Genesis_v2(genesisAddress(market));
        assertEq(deployedGenesis.MINTER(), minterAddress(market), "MINTER");
        assertEq(deployedGenesis.PEGGED_TOKEN(), peggedTokenAddress(market), "PEGGED_TOKEN");
        assertEq(deployedGenesis.LEVERAGED_TOKEN(), leveragedTokenAddress(market), "LEVERAGED_TOKEN");
    }

    /// The StabilityPoolManager's baked-in minter, and the two pools it manages, are what the resolvers name.
    function test_stabilityPoolManagerNamesTheMinterAndBothPools() public {
        IStabilityPoolManager deployedManager = IStabilityPoolManager(stabilityPoolManagerAddress(market));
        assertEq(StabilityPoolManagerMinter(address(deployedManager)).MINTER(), minterAddress(market), "MINTER");

        address[] memory pools = deployedManager.stabilityPools();
        assertEq(pools.length, 2, "pool count");
        assertEq(pools[0], stabilityPoolAddress(market, StabilityPoolType.Collateral), "pools[0]");
        assertEq(pools[1], stabilityPoolAddress(market, StabilityPoolType.Leveraged), "pools[1]");
    }

    /// The two stability-pool resolvers name distinct pools, each holding the token its type implies —
    /// the check that would catch the two pool sub-keys being swapped or duplicated.
    function test_theTwoStabilityPoolResolversNameDistinctCorrectlyTypedPools() public {
        address collateralPool = stabilityPoolAddress(market, StabilityPoolType.Collateral);
        address leveragedPool = stabilityPoolAddress(market, StabilityPoolType.Leveraged);
        assertNotEq(collateralPool, leveragedPool, "the two pools must be distinct");

        // The collateral pool liquidates into wrapped collateral; the leveraged pool into the leveraged token.
        assertEq(
            StabilityPool_v3(collateralPool).LIQUIDATION_TOKEN(),
            IMinter(minterAddress(market)).WRAPPED_COLLATERAL_TOKEN(),
            "collateral pool LIQUIDATION_TOKEN"
        );
        assertEq(
            StabilityPool_v3(leveragedPool).LIQUIDATION_TOKEN(),
            leveragedTokenAddress(market),
            "leveraged pool LIQUIDATION_TOKEN"
        );
    }

    /// The reserve pool resolver names the pool that granted REQUESTER_ROLE to the resolved minter.
    function test_reservePoolResolverNamesThePoolWiredToTheMinter() public {
        address deployedReservePool = reservePoolAddress(market);
        assertTrue(
            IBaoRoles(deployedReservePool).hasAllRoles(
                minterAddress(market),
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
