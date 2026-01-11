// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "./ConfigPeg.sol";

/// @notice Configuration for MCAP peg.
/// @dev Deployed pegged token: haMCAP ("Harbor anchored MCAP")
/// @dev Used by markets: MCAP::fxUSD, MCAP::stETH
contract ConfigPeg_MCAP is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "MCAP";
    }

    function minDeposit() public pure override returns (uint256) {
        return 0.5e18;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 0.5e18;
    }
}
