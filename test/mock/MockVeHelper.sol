// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IVotingEscrowHelper} from "src/interfaces/IVotingEscrowHelper.sol";
import {console2} from "forge-std/console2.sol";

contract MockVeHelper is IVotingEscrowHelper {
    function totalSupply(uint256 timestamp) external pure returns (uint256) {
        console2.log("MockVeHelper: totalSupply called at timestamp:", timestamp);
        // Mock implementation, always returns 0
        return 0;
    }

    function balanceOf(address account, uint256 timestamp) external pure returns (uint256) {
        console2.log("MockVeHelper: balanceOf called for account:", account, "at timestamp:", timestamp);
        // Mock implementation, always returns 0
        return 0;
    }

    function checkpoint(address account) external pure override {
        console2.log("MockVeHelper: checkpoint called for account:", account);
        // Mock implementation, does nothing
    }

    function checkpoint(address account, uint256 timestamp) external pure override {
        console2.log("MockVeHelper: checkpoint called for account:", account, "at timestamp:", timestamp);
        // Mock implementation, does nothing
    }
}
