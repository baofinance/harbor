// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_monad} from "../chains/ConfigChain_monad.sol";

/// @notice Collateral configuration for sUSDe markets on Monad.
abstract contract ConfigCollateral_sUSDe_monad is ConfigChain_monad {
    function collateralToken() public pure virtual returns (address) {
        return sUSDe();
    }

    function wrappedCollateralToken() public pure virtual returns (address) {
        return sUSDe();
    }

    function collateral() public pure virtual returns (string memory) {
        return "sUSDe";
    }
}
