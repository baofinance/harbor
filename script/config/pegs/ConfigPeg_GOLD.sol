// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";

/// @notice Configuration for GOLD peg.
/// @dev Deployed pegged token: haGOLD ("Harbor anchored GOLD")
/// @dev Used by markets: GOLD::fxUSD, GOLD::stETH
contract ConfigPeg_GOLD is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "GOLD";
    }

    function minDeposit() public pure override returns (uint256) {
        return 2e14;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 2e14;
    }
}
