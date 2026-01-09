// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigBase} from "../ConfigBase.sol";

/// @notice Collateral config for stETH-collateralized markets.
/// @dev Does not inherit chain; concrete markets must supply stETH() and wstETH().
abstract contract Config_Collateral_stETH is ConfigBase {
    function collateral() public pure virtual returns (string memory) {
        return "stETH";
    }

    function collateralToken() public pure returns (address) {
        return stETH();
    }

    function wrappedCollateral() public pure virtual returns (address) {
        return wstETH();
    }

    // Provided by concrete contracts (e.g., chain configs)
    function stETH() public pure virtual returns (address);
    function wstETH() public pure virtual returns (address);
}
