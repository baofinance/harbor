// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "./ConfigPeg.sol";

/// @notice Configuration for SOL peg.
/// @dev Deployed pegged token: haSOL ("Harbor anchored SOL")
/// @dev Used by markets: SOL::USDMY (megaeth)
contract ConfigPeg_SOL is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "SOL";
    }

    function minDeposit() public pure override returns (uint256) {
        return 0.01e18;
    }
    function minTotalSupply() public pure override returns (uint256) {
        return minDeposit();
    }
}
