// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_megaeth} from "../chains/ConfigChain_megaeth.sol";

/// @notice Collateral configuration for stETH markets on MegaETH.
/// @dev Minter uses wrapped collateral token for accounting and transfers.
abstract contract ConfigCollateral_stETH_megaeth is ConfigChain_megaeth {
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
