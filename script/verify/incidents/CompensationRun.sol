// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";

/// @notice The upgrade as the upgrade script builds it, held by a test: for the markets, the holder capture and the
///         compensation files it is constructed with, `run(saltPrefix)` reads the markets where each must be read, puts
///         the compensation into the inputs of those a file describes, upgrades them on the fork selected, and executes
///         each market's batch as the owner - the Harbor multisig, which owns the live proxies. The batches as queued
///         and the payout as sized are kept for reading, and the compensation's own functions are callable from
///         outside.
contract CompensationRun is CompensateRebalanceDilution {
    string private _saltPrefix;
    Config_MinterMarket[] private _markets;
    string private _capture;
    string[] private _files;
    Transaction[] private _batches;
    bytes private _payout;
    bytes private _inputs;

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
        (MarketUpgradeInput[] memory inputs, , Payout memory sized) = readUpgradeInputsAndCompensation(
            _markets,
            _capture,
            "mainnet",
            _files
        );
        _payout = abi.encode(sized);
        _inputs = abi.encode(inputs);
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
        FrozenMarket[] memory frozen
    ) public pure returns (Payout memory) {
        return sizePayout(markets, frozen);
    }

    function leveragedPriceAt(FrozenMarket memory state) public pure returns (uint256 pegged, uint256 wrapped) {
        return leveragedPriceOf(state);
    }

    function collateralRatioAt(FrozenMarket memory state) public pure returns (uint256) {
        return collateralRatioOf(state);
    }

    function writeReport(string memory path, MarketCompensation[] memory markets, Payout memory p) public {
        writePayoutReport(path, markets, p);
    }

    /// @notice Every market's batch as `run` queued it, in order, whether or not executed since.
    function batches() public view returns (Transaction[] memory) {
        return _batches;
    }

    /// @notice The payout as `run` sized it, which its batches carry.
    function payout() public view returns (Payout memory) {
        return abi.decode(_payout, (Payout));
    }

    /// @notice What `run` read for each market's upgrade, the compensation in it, in the markets' order.
    function inputs() public view returns (MarketUpgradeInput[] memory) {
        return abi.decode(_inputs, (MarketUpgradeInput[]));
    }
}
