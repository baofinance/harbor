// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

contract SetBalanceHelper {
    function setBalance(address /* token */, address account, uint256 amount) external {
        // Calculate storage slot for balance mapping
        // balanceOf[address] is at keccak256(abi.encode(address, slot))
        // For ERC20, balances are typically at slot 0
        uint256 slot = uint256(keccak256(abi.encode(account, uint256(0))));

        // Set the balance directly in storage using assembly
        assembly {
            sstore(slot, amount)
        }
    }
}
