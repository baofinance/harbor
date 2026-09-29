// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IYieldVault} from "@harbor/interfaces/IYieldVault.sol";

/// @dev Minimal yield vault for the YieldVaultManager tests: counts successful compound() calls, and can be built to
/// revert so the non-fatal CompoundFailed path is exercised.
contract MockYieldVault is IYieldVault {
    uint256 public compoundCount;
    bool public immutable reverts;

    constructor(bool reverts_) {
        reverts = reverts_;
    }

    function compound() external override returns (uint256 peggedCompounded) {
        if (reverts) {
            revert("MockYieldVault: compound reverted");
        }
        compoundCount++;
        peggedCompounded = 1 ether; // dummy non-zero; the tests assert on compoundCount, not the return
    }
}
