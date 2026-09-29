// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

// New version for testing upgrades
contract StabilityPool_vN is StabilityPool_v3 {
    // Keep the same constructor signature
    constructor(address minter_) StabilityPool_v3(minter_, 3600, 90000, 1 ether, "Mock SP", "mSP") {}

    // Add a new function to verify the upgrade worked
    function version() external pure returns (string memory) {
        return "v3";
    }
}
