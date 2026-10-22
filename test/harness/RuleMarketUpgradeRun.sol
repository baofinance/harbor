// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {MarketRule} from "@harbor-test/harness/MarketRule.sol";
import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @notice The production upgrade of live markets with a rule's minter and manager: what a measurement of a rule on a
///         live market installs. Only those two implementations come from the rule, through the deploy's override
///         points; the pools, their migration and every queued call are the production upgrade's.
contract RuleMarketUpgradeRun is MarketUpgradeRun {
    MarketRule private immutable _rule;

    constructor(
        MarketRule rule_,
        Config_MinterMarket[] memory markets_,
        string memory capture_
    ) MarketUpgradeRun(markets_, capture_) {
        _rule = rule_;
    }

    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal override returns (address impl) {
        impl = _rule.buildMinter(wrappedCollateral, peggedToken, leveragedToken);
        _recordImplementation(
            stateData,
            key,
            "@harbor-test/harness/MarketRule.sol",
            string.concat("minter of rule ", _rule.label()),
            impl
        );
    }

    function deployStabilityPoolManagerImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address minter,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal override returns (address impl) {
        impl = _rule.buildManager(minter, stabilityPoolCollateral, stabilityPoolLeveraged);
        _recordImplementation(
            stateData,
            key,
            "@harbor-test/harness/MarketRule.sol",
            string.concat("manager of rule ", _rule.label()),
            impl
        );
    }
}
