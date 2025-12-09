// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, console} from "forge-std/Test.sol";

contract SetWstETHBalanceTest is Test {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant DEV = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
    uint256 constant AMOUNT = 1000 * 1e18;

    function testSetBalance() external {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
        // Calculate storage slot for balance mapping
        // balanceOf[address] is at keccak256(abi.encode(address, slot))
        // For ERC20, balances are typically at slot 0
        uint256 slot = uint256(keccak256(abi.encode(DEV, uint256(0))));

        // Set the balance directly in storage
        vm.store(WSTETH, bytes32(slot), bytes32(AMOUNT));

        // Verify the balance
        (bool success, bytes memory data) = WSTETH.staticcall(abi.encodeWithSignature("balanceOf(address)", DEV));
        require(success, "Failed to read balance");
        uint256 balance = abi.decode(data, (uint256));

        console.log("wstETH balance set to:", balance);
        console.log("Expected:", AMOUNT);
        assertEq(balance, AMOUNT, "Balance mismatch");
    }
}
