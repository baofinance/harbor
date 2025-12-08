// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

/// @title Set wstETH Balance for Developer Account
/// @notice Sets the wstETH balance directly using storage manipulation
contract SetWstETHBalance is Script {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant DEV = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
    uint256 constant AMOUNT = 1000 * 1e18;

    function run() external {
        // Try standard ERC20 storage slot first (OpenZeppelin style)
        // balanceOf[address] is at keccak256(abi.encode(address, slot))
        // For ERC20, balances are typically at slot 0
        uint256 slot1 = uint256(keccak256(abi.encode(DEV, uint256(0))));
        
        // Try Solady ERC20 storage slot
        // balanceOf[address] is at keccak256(abi.encode(0x87a211a2, address))
        uint256 slot2 = uint256(keccak256(abi.encode(uint256(0x87a211a2), DEV)));
        
        // Try both slots
        vm.store(WSTETH, bytes32(slot1), bytes32(AMOUNT));
        vm.store(WSTETH, bytes32(slot2), bytes32(AMOUNT));
        
        // Verify the balance
        (bool success, bytes memory data) = WSTETH.staticcall(
            abi.encodeWithSignature("balanceOf(address)", DEV)
        );
        require(success, "Failed to read balance");
        uint256 balance = abi.decode(data, (uint256));
        
        console.log("wstETH balance set to:", balance);
        console.log("Expected:", AMOUNT);
        require(balance == AMOUNT, "Balance mismatch");
    }
}

