// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "./ConfigPeg.sol";

/// @notice Configuration for XAU (gold) peg.
/// @dev Deployed pegged token: haXAU ("Harbor anchored XAU")
/// @dev Used by markets: XAU::wstETH, XAU::sUSDe (monad)
contract ConfigPeg_XAU is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "XAU";
    }

    function minDeposit() public pure override returns (uint256) {
        return 2e14;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return 2e14;
    }
}
