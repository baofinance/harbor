// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBaoUSD {
    function operator() external returns (address);
    function addMinter(address newMinter) external;
}
