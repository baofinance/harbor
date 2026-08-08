// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";

/// @notice A production market configuration with one thing made settable: the incentive config.
/// @dev Derived from `ConfigMarket_BTC_stETH_mainnet`, so the collateral pair, token names, stability-pool
///      parameters and peg all come from real production configuration rather than values invented for tests.
///      Only `minterConfig()` is overridden — the one value a Minter suite needs to choose per test.
///
///      BTC over stETH collateral because that is a wide peg-to-collateral price ratio, closer to the range the
///      Minter suites drive through their mocked oracle; and its `ConfigCollateral_stETH_mainnet` returns the
///      wstETH/stETH pair those suites already use, so moving them onto the deploy stack changes no numbers.
contract TestMinterMarketConfig is ConfigMarket_BTC_stETH_mainnet {
    IMinter.Config private _minterConfig;
    bool private _minterConfigSet;

    /// @notice Choose the incentive config this market presents to the deploy.
    /// @dev Must be called BEFORE the deploy runs: `deployMinter` reads `minterConfig()` and applies it, which is
    ///      the production path this exists to exercise. Setting it afterwards would configure the minter directly
    ///      and test nothing about the deploy.
    function setMinterConfig(IMinter.Config memory config_) external {
        _minterConfig = config_;
        _minterConfigSet = true;
    }

    /// @dev Falls through to the production volatility config until a test chooses one, so a suite that does not
    ///      care still deploys against real settings rather than an empty struct.
    function minterConfig() public view override returns (IMinter.Config memory) {
        if (!_minterConfigSet) {
            return super.minterConfig();
        }
        return _minterConfig;
    }

    /// @notice The early-withdrawal fee the stability-pool suites were written against.
    /// @dev Production BTC charges 1e16 (1%). The suites compute their expectations from this rate, so they
    ///      would still pass at either value — but they would be exercising a different one than they were
    ///      designed for. The market presents the rate the tests intend, and the deploy applies it by its own
    ///      path, so nothing is configured behind the deploy's back.
    function stabilityPoolEarlyWithdrawalFeeRatio() public pure override returns (uint256) {
        return 0.025 ether;
    }

    /// @notice The stability-pool supply floor the suites were written against.
    /// @dev The one value where production's BTC setting (1e13) would genuinely change what is tested rather
    ///      than merely rescale it: this floor gates every deposit and withdrawal — a deposit must leave the
    ///      total at zero or at or above it — and 1e13 is 100,000x smaller, so the boundary cases the suites
    ///      drive would stop being boundaries at all.
    function minTotalSupply() public pure override returns (uint256) {
        return 1 ether;
    }
}
