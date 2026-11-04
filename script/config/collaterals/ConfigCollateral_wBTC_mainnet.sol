// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";

/// @notice Collateral configuration for wBTC markets.
/// @dev Addresses come from the chain config that this is composed with.
/// @dev WBTC has 8 decimals and the minter has no decimals handling, so a market on it needs an oracle whose price is
///      scaled 1e28, not 1e18.
abstract contract ConfigCollateral_wBTC_mainnet is ConfigChain_mainnet {
    function collateralToken() public pure virtual returns (address) {
        return WBTC();
    }

    function wrappedCollateralToken() public view virtual returns (address) {
        return WBTC();
    }

    function collateral() public pure virtual returns (string memory) {
        return "wBTC";
    }

    /// @notice About a dollar's worth of WBTC - see `IHarborConfig.aboutADollarInWrappedCollateral`.
    function aboutADollarInWrappedCollateral() public pure virtual returns (uint256) {
        return 1300;
    }
}
