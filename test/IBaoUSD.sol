// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

interface IBaoUSD {
    function operator() external returns (address);
    function addMinter(address newMinter) external;
}
