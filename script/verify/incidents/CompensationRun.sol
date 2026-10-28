// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";

/// @notice The compensated upgrade of markets a pause has frozen, held by a test: for the markets, the holder capture
///         and the compensation files it is constructed with, `run(saltPrefix)` reads the frozen markets at the
///         capture's block, puts the compensation into their inputs, upgrades them on the fork selected, and executes
///         each market's batch as the owner - the Harbor multisig, which owns the live proxies. The batches as queued
///         are kept for reading, and the compensation's own functions are callable from outside.
contract CompensationRun is CompensateRebalanceDilution {
    string private _saltPrefix;
    Config_MinterMarket[] private _markets;
    string private _capture;
    string[] private _files;
    Transaction[] private _batches;

    /// @param saltPrefix_ The run's identity, fixed at construction, so every address it predicts resolves from the
    ///        moment it exists; `run` is given the same.
    constructor(
        string memory saltPrefix_,
        Config_MinterMarket[] memory markets_,
        string memory capture_,
        string[] memory files_
    ) {
        _saltPrefix = saltPrefix_;
        _markets = markets_;
        _capture = capture_;
        _files = files_;
    }

    function saltPrefix() public view override returns (string memory) {
        return _saltPrefix;
    }

    function build() internal override {
        MarketUpgradeInput[] memory inputs = readFrozenMarketUpgradeInputs(_markets, _capture, "mainnet");
        MarketCompensation[] memory compensated = new MarketCompensation[](_files.length);
        for (uint256 i = 0; i < _files.length; ++i) {
            compensated[i] = readCompensation(_files[i]);
        }
        compensate(inputs, compensated);
        upgradeMarketsToV3(inputs, "mainnet");
        for (uint256 i = 0; i < _allTransactions.length; ++i) {
            _batches.push(_allTransactions[i]);
        }
    }

    /// @notice Deploy the singleton BaoFactory if needed and register THIS run as a factory operator, so its address
    ///         predictions resolve where no deploy has run.
    function ensureFactory() public returns (address factory) {
        return BaoFactoryTestLib.ensureBaoFactory();
    }

    function read(string memory file) public returns (MarketCompensation memory) {
        return readCompensation(file);
    }

    function deductionsOf(MarketCompensation memory m) public returns (IStabilityPool_v3_Upgrader.Deduction[] memory) {
        return deductions(m);
    }

    function size(
        MarketCompensation[] memory markets,
        uint256[] memory peggedValues
    ) public pure returns (Payout memory) {
        return sizePayout(markets, peggedValues);
    }

    function peggedInWrappedOf(address oracle, uint256 pegged) public view returns (uint256) {
        return peggedInWrapped(oracle, pegged);
    }

    /// @notice Every market's batch as `run` queued it, in order, whether or not executed since.
    function batches() public view returns (Transaction[] memory) {
        return _batches;
    }
}
