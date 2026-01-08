// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../chains/Config_Chain_Mainnet.sol";

/// @notice Collateral configuration for fxUSD markets.
/// @dev Addresses come from the chain config that this is composed with.
abstract contract Config_Collateral_fxUSD is Config_Chain_Mainnet {
    function collateralToken() public pure virtual returns (address) {
        return fxUSD();
    }

    function wrappedCollateralToken() public pure virtual returns (address) {
        return fxSAVE();
    }

    function collateral() public pure virtual returns (string memory) {
        return "fxUSD";
    }
}
