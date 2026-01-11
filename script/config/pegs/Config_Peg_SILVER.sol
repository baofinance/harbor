// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg} from "./Config_Peg.sol";

/// @notice Configuration for SILVER peg.
/// @dev Deployed pegged token: haSILVER ("Harbor anchored SILVER")
/// @dev Used by markets: SILVER::fxUSD, SILVER::stETH
contract Config_Peg_SILVER is Config_Peg {
    function peg() public pure virtual override returns (string memory) {
        return "SILVER";
    }

    function minDeposit() public pure override returns (uint256) {
        return 0.01e18;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return minDeposit();
    }
}
