// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployETHfxUSDSetUp} from "@harbor-test/deployment/DeployETHfxUSD.t.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

/// @notice Verifies that a market's contracts come out of the deploy already configured, with the values
///         their market config specifies.
/// @dev `deployMinter` and `deployStabilityPoolManager` each perform their own post-deploy setter calls;
///      the deploy stack no longer does. These tests pin the outcome rather than the mechanism, so moving
///      a value between constructor argument, `initialize` calldata and setter cannot change what they
///      assert — which is the point of putting the split inside one function.
contract DeployedConfigurationTest is DeployETHfxUSDSetUp {
    IHarborConfig internal cfg;
    Config_MinterMarket internal market;

    function setUp() public override {
        super.setUp();
        // Same config source the deploy used, so the expected values are not a second copy.
        (, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];
        cfg = IHarborConfig(address(market));
    }

    /// The StabilityPoolManager's four operating ratios and fee receiver are set by the deploy, from the
    /// market config and the deployer's treasury.
    function test_deployedStabilityPoolManagerIsConfiguredFromMarketConfig() public view {
        IStabilityPoolManager deployedManager = IStabilityPoolManager(stabilityPoolManager);
        assertEq(deployedManager.rebalanceThreshold(), cfg.rebalanceThreshold(), "rebalanceThreshold");
        assertEq(deployedManager.rebalanceBountyRatio(), cfg.rebalanceBountyRatio(), "rebalanceBountyRatio");
        assertEq(deployedManager.harvestBountyRatio(), cfg.harvestBountyRatio(), "harvestBountyRatio");
        assertEq(deployedManager.harvestCutRatio(), cfg.harvestCutRatio(), "harvestCutRatio");
        assertEq(deployedManager.feeReceiver(), treasury(), "feeReceiver");
    }

    /// Every Minter dependency is set by the deploy — no configuration step is outstanding once
    /// deployMinter returns. The price oracle is the address the deploy resolved, which is where the
    /// setup's mock is installed; asserting it here is what proves the mock reached the minter through
    /// the deploy rather than through a post-deploy setter.
    function test_deployedMinterIsWiredToAllItsDependencies() public {
        // Not `view`: the resolvers label the address they return, so they are state-changing.
        assertEq(IMinter_v3(minter).reservePool(), reservePoolAddress(market), "reservePool");
        assertEq(IMinter(minter).feeReceiver(), treasury(), "feeReceiver");
        assertEq(IMinter_v3(minter).priceOracle(), wrappedPriceOracleAddress(market), "priceOracle");
        assertEq(IMinter_v3(minter).priceOracle(), address(mockOracle), "the installed mock is that oracle");
    }

    /// The Minter's incentive config is the market config's, not the permissive default that
    /// `initialize` seeds — i.e. the deploy's updateConfig call actually landed.
    /// @dev The two Config structs are declared on both IMinter and IMinter_v3 and are structurally
    ///      identical, so they compare through their ABI encoding — which also makes this an exact
    ///      whole-struct check rather than a field-by-field one that could miss a field added later.
    function test_deployedMinterUsesTheMarketConfigIncentives() public view {
        assertEq(
            keccak256(abi.encode(IMinter_v3(minter).config())),
            keccak256(abi.encode(cfg.minterConfig())),
            "the deployed incentive config is the market config's, not initialize's permissive default"
        );
    }
}
