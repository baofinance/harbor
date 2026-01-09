// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg} from "./Config_Peg.sol";

/// @notice Configuration for BTC peg.
/// @dev Deployed pegged token: haBTC ("Harbor anchored BTC")
/// @dev Used by markets: BTC::fxUSD, BTC::stETH
contract Config_Peg_BTC is Config_Peg {
    function peg() public pure virtual override returns (string memory) {
        return "BTC";
    }

    function minDeposit() public pure override returns (uint256) {
        return 1e13;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 1e13;
    }
}
