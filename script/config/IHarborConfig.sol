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
///      - SP/SPM functions are `pure` — they return compile-time constants, never constructor state - except the
///        two bounty ceilings, which are `view`: each is computed from `aboutADollarInWrappedCollateral()`, read
///        through this interface, so a test config may compute it.
interface IHarborConfig {
    // ========== MARKET IDENTITY ==========

    function peg() external view returns (string memory);
    function collateral() external view returns (string memory);

    // ========== COLLATERAL ==========

    function wrappedCollateralToken() external view returns (address);

    /// @notice About a dollar's worth of the wrapped collateral token - the number of its tokens that make about a
    ///         dollar, stated when the config is written, never read from a price. It is the unit the stability pool
    ///         manager's bounty ceilings are counted in. Approximate by design: it is revised, and the ceilings
    ///         re-applied, when the price has moved far from it.
    function aboutADollarInWrappedCollateral() external view returns (uint256);

    // ========== MINTER ==========

    /// @dev Declared `view` (not `pure`) so test subclasses returning immutable addresses compile.
    function minterConfig() external view returns (IMinter.Config memory);

    // ========== PEG ==========

    /// @notice About a dollar's worth of the pegged token - the number of pegged tokens that make about a dollar,
    ///         stated when the config is written. See `ConfigPeg.aboutADollarInPegged`.
    function aboutADollarInPegged() external view returns (uint256);

    // ========== STABILITY POOL ==========

    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);

    // ========== STABILITY POOL MANAGER ==========

    function rebalanceThreshold() external pure returns (uint256);
    function rebalanceBountyRatio() external pure returns (uint256);
    function harvestBountyRatio() external pure returns (uint256);
    function harvestCutRatio() external pure returns (uint256);
    /// @notice The most a harvest pays its caller, in wrapped collateral; zero is no ceiling.
    function harvestBountyCeiling() external view returns (uint256);
    /// @notice The most a rebalance pays its caller in all, in wrapped collateral - a payment in leveraged tokens
    ///         counted as the collateral they were minted for; zero is no ceiling.
    function rebalanceBountyCeiling() external view returns (uint256);
}
