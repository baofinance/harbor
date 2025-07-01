// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";
import {LiquidityGaugeV6Test, MockVeBoost} from "test/reward/LiquidityGaugeV6.t.sol";

contract LiquidityGaugeV6IntegrationTest is LiquidityGaugeV6Test {
    function setUp() public virtual override {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        manager = makeAddr("manager");

        // Deploy mock LP token
        lpToken = address(new MockERC20("Test LP Token", "TLP", 18));

        // --- Mock VEBOOST_PROXY ---
        MockVeBoost mockBoost = new MockVeBoost();
        vm.etch(VEBOOST_PROXY, address(mockBoost).code);

        // Provide placeholder bytecode so vm.mockCall works
        vm.etch(VOTING_ESCROW, hex"00");

        // Mock totalSupply() to return something > 0 so gauge logic proceeds
        vm.mockCall(
            VOTING_ESCROW,
            abi.encodeWithSignature("totalSupply()"),
            abi.encode(1e18) // simulate 1 voting escrow token in supply
        );

        // We need to mock the CRV token for the constructor to work
        // Since it calls CRV.future_epoch_time_write() and CRV.rate()
        vm.etch(CRV_ADDRESS, hex"00"); // Empty bytecode to avoid calls

        // Mock the CRV token calls that happen in constructor
        vm.mockCall(
            CRV_ADDRESS,
            abi.encodeWithSignature("future_epoch_time_write()"),
            abi.encode(block.timestamp + 86400 * 365) // 1 year from now
        );
        vm.mockCall(
            CRV_ADDRESS,
            abi.encodeWithSignature("rate()"),
            abi.encode(158548959918832) // Some sample rate
        );

        // Mock the LP token symbol call for the constructor
        vm.mockCall(lpToken, abi.encodeWithSignature("symbol()"), abi.encode("TLP"));

        // Deploy the gauge contract
        // We need to set tx.origin for the manager
        vm.prank(manager, manager);
        gauge = deployCode(
            "LiquidityGaugeV6.vy",
            abi.encode(lpToken, CRV_ADDRESS, GAUGE_CONTROLLER, MINTER, VOTING_ESCROW, VEBOOST_PROXY)
        );

        // Mint some LP tokens to users for testing
        MockERC20(lpToken).mint(user1, 1000 ether);
        MockERC20(lpToken).mint(user2, 500 ether);
    }
}
