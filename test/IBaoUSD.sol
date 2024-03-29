// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.25;

interface IBaoUSD {
    function operator() external returns (address);
    function addMinter(address newMinter) external;
}
