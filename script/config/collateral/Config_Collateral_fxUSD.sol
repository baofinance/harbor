// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigBase} from "../ConfigBase.sol";

/// @notice Collateral config for fxUSD collateralized markets.
/// @dev Does not inherit chain; concrete markets must supply fxUSD() and fxSAVE().
abstract contract Config_Collateral_fxUSD is ConfigBase {
    function collateral() public pure virtual returns (string memory) {
        return "fxUSD";
    }

    function collateralToken() public pure returns (address) {
        return fxUSD();
    }

    function wrappedCollateral() public pure virtual returns (address) {
        return fxSAVE();
    }

    // Provided by concrete contracts (e.g., chain configs)
    function fxUSD() public pure virtual returns (address);
    function fxSAVE() public pure virtual returns (address);
}
