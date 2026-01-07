// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Configuration for ETH-pegged markets.
abstract contract Config_Peg_ETH {
    string internal constant PEGGED_BURN_SIGNATURE = "burn(uint256)";

    function peg() public pure virtual returns (string memory) { return "ETH"; }

    function minDeposit() public pure virtual returns (uint256) { return 2e14; }
    function minTotalSupply() public pure virtual returns (uint256) { return 2e14; }
}
