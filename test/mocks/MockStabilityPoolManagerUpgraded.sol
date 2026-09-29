// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

contract MockStabilityPoolManagerUpgraded is StabilityPoolManager_v2 {
    bool public upgradeSuccessful;

    // Keep the same constructor signature
    constructor(
        address minter_,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) StabilityPoolManager_v2(minter_, stabilityPoolCollateral, stabilityPoolLeveraged) {}

    // Add a new function that would only be available in the upgraded version
    function newFunctionOnlyInUpgrade() external pure returns (bool) {
        return true;
    }

    // Override a function to demonstrate it was upgraded
    function isUpgraded() external pure returns (bool) {
        return true;
    }
}
