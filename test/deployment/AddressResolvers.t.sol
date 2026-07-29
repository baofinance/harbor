// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployETHfxUSDSetUp} from "@harbor-test/deployment/DeployETHfxUSD.t.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Genesis_v2} from "@harbor/minter/Genesis_v2.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";

/// @notice Verifies that every predicted-address resolver on HarborDeployer names the contract the
///         deploy actually built there.
/// @dev The resolvers are the single home of each salt sub-key, and the deploy reaches every contract
///      through them, so a mistyped sub-key would silently produce a codeless address that only fails
///      much later, as a call to a non-contract. These tests turn that into an immediate, local failure.
///      Each resolver is checked two ways: the address has code, and the contract standing there names
///      its own dependencies as the OTHER resolvers name them — so the set has to agree with itself and
///      with what the deploy wired.
contract AddressResolversTest is DeployETHfxUSDSetUp {
    string internal marketKey;
    string internal pegKey;

    function setUp() public override {
        super.setUp();
        // Same config source the deploy used, so the keys under test are not a second copy.
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        marketKey = MinterMarketConfigLib.salt(mktConfigs[0]);
        pegKey = peg.key();
    }

    /// Every resolver points at deployed code — the minimum a mistyped sub-key would break.
    function test_everyResolverPointsAtDeployedCode() public {
        assertGt(peggedTokenAddress(pegKey).code.length, 0, "peggedTokenAddress");
        assertGt(leveragedTokenAddress(marketKey).code.length, 0, "leveragedTokenAddress");
        assertGt(minterAddress(marketKey).code.length, 0, "minterAddress");
        assertGt(reservePoolAddress(marketKey).code.length, 0, "reservePoolAddress");
        assertGt(
            stabilityPoolAddress(marketKey, StabilityPoolType.Collateral).code.length,
            0,
            "stabilityPoolAddress(Collateral)"
        );
        assertGt(
            stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged).code.length,
            0,
            "stabilityPoolAddress(Leveraged)"
        );
        assertGt(stabilityPoolManagerAddress(marketKey).code.length, 0, "stabilityPoolManagerAddress");
        assertGt(genesisAddress(marketKey).code.length, 0, "genesisAddress");
    }

    /// The Minter's baked-in token addresses are the ones the token resolvers name.
    function test_minterNamesTheTokenResolvers() public {
        IMinter deployedMinter = IMinter(minterAddress(marketKey));
        assertEq(deployedMinter.PEGGED_TOKEN(), peggedTokenAddress(pegKey), "PEGGED_TOKEN");
        assertEq(deployedMinter.LEVERAGED_TOKEN(), leveragedTokenAddress(marketKey), "LEVERAGED_TOKEN");
    }

    /// Genesis's baked-in minter and token addresses are the ones the corresponding resolvers name.
    /// @dev Genesis_v2 also declares STABILITY_POOL_COLLATERAL and STABILITY_POOL_LEVERAGED, but its
    ///      constructor never assigns them, so they are not assertable here.
    function test_genesisNamesTheMinterAndTokenResolvers() public {
        Genesis_v2 deployedGenesis = Genesis_v2(genesisAddress(marketKey));
        assertEq(deployedGenesis.MINTER(), minterAddress(marketKey), "MINTER");
        assertEq(deployedGenesis.PEGGED_TOKEN(), peggedTokenAddress(pegKey), "PEGGED_TOKEN");
        assertEq(deployedGenesis.LEVERAGED_TOKEN(), leveragedTokenAddress(marketKey), "LEVERAGED_TOKEN");
    }

    /// The StabilityPoolManager's baked-in minter, and the two pools it manages, are what the resolvers name.
    function test_stabilityPoolManagerNamesTheMinterAndBothPools() public {
        IStabilityPoolManager deployedManager = IStabilityPoolManager(stabilityPoolManagerAddress(marketKey));
        assertEq(StabilityPoolManagerMinter(address(deployedManager)).MINTER(), minterAddress(marketKey), "MINTER");

        address[] memory pools = deployedManager.stabilityPools();
        assertEq(pools.length, 2, "pool count");
        assertEq(pools[0], stabilityPoolAddress(marketKey, StabilityPoolType.Collateral), "pools[0]");
        assertEq(pools[1], stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged), "pools[1]");
    }

    /// The two stability-pool resolvers name distinct pools, each holding the token its type implies —
    /// the check that would catch the two pool sub-keys being swapped or duplicated.
    function test_theTwoStabilityPoolResolversNameDistinctCorrectlyTypedPools() public {
        address collateralPool = stabilityPoolAddress(marketKey, StabilityPoolType.Collateral);
        address leveragedPool = stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged);
        assertNotEq(collateralPool, leveragedPool, "the two pools must be distinct");

        // The collateral pool liquidates into wrapped collateral; the leveraged pool into the leveraged token.
        assertEq(
            StabilityPool_v3(collateralPool).LIQUIDATION_TOKEN(),
            IMinter(minterAddress(marketKey)).WRAPPED_COLLATERAL_TOKEN(),
            "collateral pool LIQUIDATION_TOKEN"
        );
        assertEq(
            StabilityPool_v3(leveragedPool).LIQUIDATION_TOKEN(),
            leveragedTokenAddress(marketKey),
            "leveraged pool LIQUIDATION_TOKEN"
        );
    }

    /// The reserve pool resolver names the pool that granted REQUESTER_ROLE to the resolved minter.
    function test_reservePoolResolverNamesThePoolWiredToTheMinter() public {
        address deployedReservePool = reservePoolAddress(marketKey);
        assertTrue(
            IBaoRoles(deployedReservePool).hasAllRoles(
                minterAddress(marketKey),
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
