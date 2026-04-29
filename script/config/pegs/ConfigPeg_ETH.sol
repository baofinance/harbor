// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";

/// @notice Configuration for ETH peg.
/// @dev Deployed pegged token: haETH ("Harbor anchored ETH")
/// @dev Used by markets: ETH::fxUSD, ETH::stETH
contract ConfigPeg_ETH is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "ETH";
    }

    function minDeposit() public pure override returns (uint256) {
        return 2e14;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 2e14;
    }
}
