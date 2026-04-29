// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";

/// @notice Collateral configuration for stETH markets.
/// @dev Addresses come from the chain config that this is composed with.
abstract contract ConfigCollateral_stETH_mainnet is ConfigChain_mainnet {
    function collateralToken() public pure virtual returns (address) {
        return stETH();
    }

    function wrappedCollateralToken() public pure virtual returns (address) {
        return wstETH();
    }

    function collateral() public pure virtual returns (string memory) {
        return "stETH";
    }
}
