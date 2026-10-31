// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";

/// @notice Collateral configuration for tBTC markets.
/// @dev Addresses come from the chain config that this is composed with.
abstract contract ConfigCollateral_tBTC_mainnet is ConfigChain_mainnet {
    function collateralToken() public pure virtual returns (address) {
        return tBTC();
    }

    function wrappedCollateralToken() public view virtual returns (address) {
        return tBTC();
    }

    function collateral() public pure virtual returns (string memory) {
        return "tBTC";
    }

    /// @notice About a dollar's worth of tBTC - see `IHarborConfig.aboutADollarInWrappedCollateral`.
    function aboutADollarInWrappedCollateral() public pure virtual returns (uint256) {
        return 1.3e13;
    }
}
