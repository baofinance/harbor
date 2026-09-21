// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Canonical interface for Harbor market configuration contracts.
/// @dev All concrete market configs (e.g. ConfigMarket_ETH_fxUSD_mainnet) implement this interface
///      via their mixin inheritance chain. Scripts cast Config_MinterMarket to IHarborConfig to call
///      config functions across the full mixin hierarchy.
///
///      Mutability rules:
///      - `wrappedCollateralToken()` and `minterConfig()` are `view` (not `pure`) so test subclasses
///        can return immutable constructor arguments.
///      - SP/SPM functions are `pure` — they return compile-time constants, never constructor state.
interface IHarborConfig {
    // ========== MARKET IDENTITY ==========

    function peg() external view returns (string memory);
    function collateral() external view returns (string memory);

    // ========== COLLATERAL ==========

    function wrappedCollateralToken() external view returns (address);

    // ========== MINTER ==========

    /// @dev Declared `view` (not `pure`) so test subclasses returning immutable addresses compile.
    function minterConfig() external view returns (IMinter.Config memory);

    // ========== PEG ==========

    function minTotalSupply() external view returns (uint256);

    // ========== STABILITY POOL ==========

    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);

    // ========== STABILITY POOL MANAGER ==========

    function rebalanceThreshold() external pure returns (uint256);
    function rebalanceBountyRatio() external pure returns (uint256);
    function harvestBountyRatio() external pure returns (uint256);
    function harvestCutRatio() external pure returns (uint256);
}
