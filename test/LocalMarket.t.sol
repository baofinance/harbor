// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {ConfigMarket_MCAP_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_fxUSD_mainnet.sol";

import {TestMinterMarketConfig_rebalanceThreshold130} from "@harbor-test/config/TestMinterMarketConfig_rebalanceThreshold130.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";

// What a local market is, whatever is measured on it: the config it is deployed with, and the one rule it runs.

/// What the local market is configured as, apart from the unit-test market it is built from.
contract LocalMarketConfigTest is Test {
    /// A local market is measured beside the deployed one, so the two rebalance at the same collateral ratio: the
    /// local market's config carries the deployed market's rebalance threshold.
    function test_aLocalMarketCarriesTheDeployedMarketsRebalanceThreshold() public {
        assertEq(
            new TestMinterMarketConfig_rebalanceThreshold130().rebalanceThreshold(),
            new ConfigMarket_MCAP_fxUSD_mainnet().rebalanceThreshold(),
            "the deployed market's rebalance threshold"
        );
    }
}

/// A local market whose run names a rule other than the tree's.
contract LocalMarketRuleTest is LocalMarket {
    constructor() {
        useRule(new V3Rule());
    }

    /// The deploy chain builds the tree's minter and manager, and a local market puts nothing behind them - so a run
    /// naming another rule reverts, with that rule's label, rather than being measured as the tree under it.
    /// @dev The revert is inside the market, at this depth, which forge accepts only with the allowance below; and it
    ///      must come before the market creates anything, since a contract created first takes the expectation.
    /// forge-config: default.allow_internal_expect_revert = true
    function test_aLocalMarketRevertsOnARuleOtherThanTheTrees() public {
        string memory ruleLabel = overrideLabel();
        vm.expectRevert(abi.encodeWithSelector(LocalMarket.LocalMarketRunsOnlyTheTreesRule.selector, ruleLabel));
        standUpMarket(0.4 ether, 0.4 ether, string.concat(marketLabel(), ruleLabel, "_revertTest"));
    }
}
