// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg} from "./Config_Peg.sol";

/// @notice Configuration for GOLD peg.
/// @dev Deployed pegged token: haGOLD ("Harbor anchored GOLD")
/// @dev Used by markets: GOLD::fxUSD, GOLD::stETH
contract Config_Peg_GOLD is Config_Peg {
    function peg() public pure override returns (string memory) {
        return "GOLD";
    }

    function minDeposit() public pure override returns (uint256) {
        return 2e14;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 2e14;
    }
}
