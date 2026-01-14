// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SafeBatchBase} from "script/safe/SafeBatchBase.s.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_130} from "script/config/volatility/ConfigPriceVolatility_130.sol";

/// @notice Example batch: Update volatility config for BTC markets.
/// @dev Run with: ./script/generate-safe-batch UpdateVolatility_Example
///
/// This example demonstrates the pattern. When values are already set,
/// prechecks will fail (as expected). Modify the threshold values to
/// generate actual transactions.
contract UpdateVolatility_Example is SafeBatchBase, ConfigPriceVolatility_130 {
    function name() internal pure override returns (string memory) {
        return "UpdateVolatility_Example";
    }

    function volatilityConfig(uint256 threshold) internal pure override returns (IMinter.Config memory) {
        if (threshold == 130) {
            return minterConfig(); // from ConfigPriceVolatility_130
        }
        revert("Unsupported threshold");
    }

    function build() internal override {
        // ─────────────────────────────────────────────────────────────────
        // BTC::fxUSD - set to 130 volatility config
        // ─────────────────────────────────────────────────────────────────
        {
            address m = minter("BTC::fxUSD");
            address spm = stabilityPoolManager("BTC::fxUSD");
            IMinter.Config memory cfg = volatilityConfig(130);
            uint256 threshold = rebalanceThreshold(130);

            // Prechecks: fail if already set
            precheck(configMatches(m, cfg), "BTC::fxUSD minter config already set to 130");
            precheck(rebalanceThresholdMatches(spm, threshold), "BTC::fxUSD SPM threshold already 1.30e18");

            // Queue transactions
            queue(m, abi.encodeCall(IMinter.updateConfig, (cfg)), "BTC::fxUSD::minter.updateConfig(130)");
            queue(
                spm,
                abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (threshold)),
                "BTC::fxUSD::stabilityPoolManager.updateRebalanceThreshold(1.30e18)"
            );
        }

        // ─────────────────────────────────────────────────────────────────
        // BTC::stETH - set to 130 volatility config
        // ─────────────────────────────────────────────────────────────────
        {
            address m = minter("BTC::stETH");
            address spm = stabilityPoolManager("BTC::stETH");
            IMinter.Config memory cfg = volatilityConfig(130);
            uint256 threshold = rebalanceThreshold(130);

            precheck(configMatches(m, cfg), "BTC::stETH minter config already set to 130");
            precheck(rebalanceThresholdMatches(spm, threshold), "BTC::stETH SPM threshold already 1.30e18");

            queue(m, abi.encodeCall(IMinter.updateConfig, (cfg)), "BTC::stETH::minter.updateConfig(130)");
            queue(
                spm,
                abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (threshold)),
                "BTC::stETH::stabilityPoolManager.updateRebalanceThreshold(1.30e18)"
            );
        }
    }
}
