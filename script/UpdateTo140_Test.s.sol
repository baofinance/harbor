// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SafeBatchBase} from "script/safe/SafeBatchBase.s.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_130} from "script/config/volatility/ConfigPriceVolatility_130.sol";

/// @notice Test batch: Update BTC::fxUSD to 140 config (different from current 130).
/// @dev This should generate transactions since the target values differ from on-chain.
contract UpdateTo140_Test is SafeBatchBase, ConfigPriceVolatility_130 {
    function name() internal pure override returns (string memory) {
        return "UpdateTo140_Test";
    }

    /// @notice For testing, we return 130 config but claim it's 140.
    /// In reality, you'd have ConfigPriceVolatility_140.sol with different values.
    function volatilityConfig(uint256 threshold) internal pure override returns (IMinter.Config memory) {
        if (threshold == 130 || threshold == 140) {
            return minterConfig(); // Same config for testing
        }
        revert("Unsupported threshold");
    }

    function build() internal override {
        // BTC::fxUSD - update rebalance threshold to 140 (1.40e18)
        // Currently on-chain it's 130 (1.30e18), so this should generate a transaction
        {
            address spm = stabilityPoolManager("BTC::fxUSD");
            uint256 threshold = rebalanceThreshold(140); // 1.40e18

            // Precheck: fail if already at 140 (it's at 130, so this will pass)
            precheck(rebalanceThresholdMatches(spm, threshold), "BTC::fxUSD SPM threshold already 1.40e18");

            // Queue transaction
            queue(
                spm,
                abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (threshold)),
                "BTC::fxUSD::stabilityPoolManager.updateRebalanceThreshold(1.40e18)"
            );
        }
    }
}
