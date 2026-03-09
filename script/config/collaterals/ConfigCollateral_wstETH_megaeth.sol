// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_megaeth} from "../chains/ConfigChain_megaeth.sol";

/// @notice Collateral configuration for wstETH markets on MegaETH.
abstract contract ConfigCollateral_wstETH_megaeth is ConfigChain_megaeth {
    function collateralToken() public pure virtual returns (address) {
        return wstETH();
    }

    function wrappedCollateralToken() public pure virtual returns (address) {
        return wstETH();
    }

    function collateral() public pure virtual returns (string memory) {
        return "wstETH";
    }
}
