// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg} from "./Config_Peg.sol";

/// @notice Configuration for EUR peg.
/// @dev Deployed pegged token: haEUR ("Harbor anchored EUR")
/// @dev Used by markets: EUR::fxUSD, EUR::stETH
contract Config_Peg_EUR is Config_Peg {
    function peg() public pure virtual override returns (string memory) { return "EUR"; }

    function minDeposit() public pure override returns (uint256) { return 1e18; }
    function minTotalSupply() public pure override returns (uint256) { return 1e18; }
}

