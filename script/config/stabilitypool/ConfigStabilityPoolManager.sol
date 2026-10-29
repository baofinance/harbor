// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

/// @notice Stability pool manager configuration.
/// @dev Reads the collateral's dollar unit through `IHarborConfig(this)`, as `ConfigTokenNames` reads the peg and
///      collateral names: a function declared by two mixins is a diamond every market config would have to resolve.
abstract contract ConfigStabilityPoolManager {
    function rebalanceBountyRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function harvestBountyRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function harvestCutRatio() public pure virtual returns (uint256) {
        return 99e16;
    }

    /// @notice The share of each rebalance payment taken to the cut receiver: none. The manager can take one; the
    ///         markets are configured without it.
    function rebalanceCutRatio() public pure virtual returns (uint256) {
        return 0;
    }

    /// @notice The most a harvest pays its caller, in wrapped collateral: a hundred dollars' worth, by the collateral's
    ///         `aboutADollarInWrappedCollateral`. Zero is no ceiling.
    function harvestBountyCeiling() public view virtual returns (uint256) {
        return 100 * IHarborConfig(address(this)).aboutADollarInWrappedCollateral();
    }

    /// @notice The most a rebalance pays its caller in all, in wrapped collateral - a payment in leveraged tokens
    ///         counted as the collateral they were minted for: two hundred dollars' worth, by the collateral's
    ///         `aboutADollarInWrappedCollateral`. Zero is no ceiling.
    function rebalanceBountyCeiling() public view virtual returns (uint256) {
        return 200 * IHarborConfig(address(this)).aboutADollarInWrappedCollateral();
    }
}
