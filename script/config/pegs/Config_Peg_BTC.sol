// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Configuration for BTC-pegged markets.
abstract contract Config_Peg_BTC {
    string internal constant PEGGED_BURN_SIGNATURE = "burn(uint256)";

    function peg() public pure virtual returns (string memory) {
        return "BTC";
    }

    function minDeposit() public pure virtual returns (uint256) {
        return 1e13;
    }
    function minTotalSupply() public pure virtual returns (uint256) {
        return 1e13;
    }
}
