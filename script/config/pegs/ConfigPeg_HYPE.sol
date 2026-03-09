// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "./ConfigPeg.sol";

/// @notice Configuration for HYPE peg.
/// @dev Deployed pegged token: haHYPE ("Harbor anchored HYPE")
/// @dev Used by markets: HYPE::USDMY (megaeth)
contract ConfigPeg_HYPE is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "HYPE";
    }

    function minDeposit() public pure override returns (uint256) {
        return 0.01e18;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return minDeposit();
    }
}
