// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Configuration for EUR-pegged markets.
abstract contract Config_Peg_EUR {
    string internal constant PEGGED_BURN_SIGNATURE = "burn(uint256)";

    function peg() public pure virtual returns (string memory) {
        return "EUR";
    }

    function minDeposit() public pure virtual returns (uint256) {
        return 1e18;
    }
    function minTotalSupply() public pure virtual returns (uint256) {
        return 1e18;
    }
}
