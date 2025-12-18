// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

contract SetBalanceHelper {
    function setBalance(address /* token */, address account, uint256 amount) external {
        // Calculate storage slot for balance mapping (standard ERC20)
        uint256 slot = uint256(keccak256(abi.encode(account, uint256(0))));
        assembly {
            sstore(slot, amount)
        }
    }
}

contract SetWstETHBalanceDeploy is Script {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant DEV = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
    uint256 constant AMOUNT = 1000 * 1e18;

    function run() external {
        vm.startBroadcast();

        // Deploy helper contract
        SetBalanceHelper helper = new SetBalanceHelper();
        console.log("Helper deployed at:", address(helper));

        // Set balance via helper
        helper.setBalance(WSTETH, DEV, AMOUNT);

        // Verify
        (bool success, bytes memory data) = WSTETH.staticcall(abi.encodeWithSignature("balanceOf(address)", DEV));
        require(success, "Failed to read balance");
        uint256 balance = abi.decode(data, (uint256));

        console.log("wstETH balance:", balance);
        require(balance == AMOUNT, "Balance mismatch");

        vm.stopBroadcast();
    }
}
