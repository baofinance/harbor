// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";

/// @notice The production upgrade of live markets, held by a test: the two steps the upgrade script runs - read what
///         each market's upgrade needs, then `upgradeMarketsToV3` - for the markets and the holder capture it is
///         constructed with, both on the fork the test has selected.
/// @dev Driven from outside through the deploy base's own entry point, `run(saltPrefix)`, which under forge test
///      executes each market's batch as the owner - the Harbor multisig, which owns the live proxies. A subclass
///      changes what the upgrade installs only at the deploy's override points.
contract MarketUpgradeRun is UpgradeMarketToV3 {
    Config_MinterMarket[] private _markets;
    string private _capture;

    constructor(Config_MinterMarket[] memory markets_, string memory capture_) {
        _markets = markets_;
        _capture = capture_;
    }

    function build() internal override {
        upgradeMarketsToV3(readMarketUpgradeInputs(_markets, _capture), "mainnet");
    }
}

/// @dev The production upgrade of markets a pause has frozen, as the upgrade script runs it - read at the capture's
///      block, upgraded on the fork selected - for the markets and capture it is constructed with.
contract FrozenMarketUpgradeRun is UpgradeMarketToV3 {
    Config_MinterMarket[] private _markets;
    string private _capture;

    constructor(Config_MinterMarket[] memory markets_, string memory capture_) {
        _markets = markets_;
        _capture = capture_;
    }

    function build() internal override {
        upgradeMarketsToV3(readFrozenMarketUpgradeInputs(_markets, _capture, "mainnet"), "mainnet");
    }
}
