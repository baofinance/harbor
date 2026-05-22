// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";

/// @notice Collateral configuration for fxUSD markets.
/// @dev Addresses come from the chain config that this is composed with.
abstract contract ConfigCollateral_fxUSD_mainnet is ConfigChain_mainnet {
    function collateralToken() public pure virtual returns (address) {
        return fxUSD();
    }

    function wrappedCollateralToken() public view virtual returns (address) {
        return fxSAVE();
    }

    function collateral() public pure virtual returns (string memory) {
        return "fxUSD";
    }
}
