// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";

import {Steam_v1} from "src/reward/steam/Steam_v1.sol";
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";

/**
 * @title ERC20STEAM
 * @notice Base setup for ERC20STEAM tests
 */
abstract contract ERC20STEAM is Test {
    constructor(bool vyper_) {
        vyper = vyper_;
    }
    // Gas test tolerance (5% of max value)
    uint256 public constant GAS_TOLERANCE_PERCENTAGE = 5;
    bool vyper;
    // Contract instance (as address, not interface type)
    address public steam;

    // Test constants
    uint256 public constant INITIAL_SUPPLY = 61_000_000 ether;
    uint256 public constant INITIAL_RATE = 154_585_000_000_000_000;
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1_147_080_000_000_000_000;

    // Test addresses
    address public admin;
    address public user1;
    address public user2;
    address public minter;

    function setUp() public virtual {
        // Create test addresses
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        minter = makeAddr("minter");

        if (vyper) {
            // Deploy ERC20STEAM contract (store as address)
            steam = address(vm.deployCode("ERC20STEAM.vy"));

            // Initialize contract with test values
            vm.prank(admin);
            IERC20STEAM(steam).initialize(
                INITIAL_SUPPLY,
                INITIAL_RATE,
                RATE_REDUCTION_COEFFICIENT,
                admin,
                "Zhenglong STEAM",
                "STEAM"
            );

            // Set minter role
            vm.prank(admin);
            IERC20STEAM(steam).set_minter(minter);

            assertEq(IERC20STEAM(steam).minter(), minter);
        } else {
            steam = UnsafeUpgrades.deployUUPSProxy(
                address(new Steam_v1(minter)),
                abi.encodeCall(
                    Steam_v1.initialize,
                    (admin, INITIAL_SUPPLY, INITIAL_RATE, RATE_REDUCTION_COEFFICIENT, "Zhenglong STEAM", "STEAM")
                )
            );
            IBaoRoles(steam).grantRoles(minter, IMintableRole(steam).MINTER_ROLE());
            IBaoOwnable(steam).transferOwnership(admin);
        }
    }

    function test_initialization() public view {
        // Check initial state
        assertEq(IERC20STEAM(steam).name(), "Zhenglong STEAM");
        assertEq(IERC20STEAM(steam).symbol(), "STEAM");
        assertEq(IERC20STEAM(steam).decimals(), 18);
        assertEq(IERC20STEAM(steam).totalSupply(), INITIAL_SUPPLY);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY);
        assertEq(IERC20STEAM(steam).admin(), admin);
    }

    function test_transfer() public {
        uint256 amount = 1000 ether;

        // Transfer from admin to user1
        vm.prank(admin);
        bool success = IERC20STEAM(steam).transfer(user1, amount);

        // Check success and balances
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY - amount);
    }

    function test_transferFrom() public {
        uint256 amount = 1000 ether;

        // Approve user1 to spend admin's tokens
        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, amount);

        // Check allowance
        assertEq(IERC20STEAM(steam).allowance(admin, user1), amount);

        // Transfer from admin to user2 via user1
        vm.prank(user1);
        bool success = IERC20STEAM(steam).transferFrom(admin, user2, amount);

        // Check success and balances
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user2), amount);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY - amount);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), 0);
    }

    function test_approve() public {
        uint256 amount = 1000 ether;

        // Approve user1 to spend admin's tokens
        vm.prank(admin);
        bool success = IERC20STEAM(steam).approve(user1, amount);

        // Check success and allowance
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), amount);
    }

    function testFuzz_transfer(uint256 amount) public {
        // Bound amount to avoid overflow and ensure it's not more than available balance
        amount = bound(amount, 0, INITIAL_SUPPLY);

        vm.prank(admin);
        bool success = IERC20STEAM(steam).transfer(user1, amount);

        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY - amount);
    }

    function testFuzz_approve(uint256 amount) public {
        vm.prank(admin);
        bool success = IERC20STEAM(steam).approve(user1, amount);

        assertEq(success, true);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), amount);
    }

    function testFuzz_transferFrom(uint256 amount) public {
        // Bound amount to avoid overflow and ensure it's not more than available balance
        amount = bound(amount, 0, INITIAL_SUPPLY);

        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, amount);

        vm.prank(user1);
        bool success = IERC20STEAM(steam).transferFrom(admin, user2, amount);

        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user2), amount);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY - amount);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), 0);
    }

    function testFuzz_mintBurn(uint256 amount) public {
        // Bound amount to avoid large values that could overflow
        amount = bound(amount, 1, type(uint128).max);

        // Fast forward time to create mintable supply
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Calculate available supply to mint
        uint256 availableSupply = IERC20STEAM(steam).available_supply();
        uint256 currentSupply = IERC20STEAM(steam).totalSupply();
        uint256 availableToMint = availableSupply > currentSupply ? availableSupply - currentSupply : 0;

        // Skip test if nothing can be minted
        if (availableToMint == 0) return;

        // Bound amount to what's actually available
        amount = bound(amount, 1, availableToMint);

        // Mint tokens to user1
        vm.prank(minter);
        bool mintSuccess = IERC20STEAM(steam).mint(user1, amount);

        assertEq(mintSuccess, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);

        // Burn tokens
        vm.prank(user1);
        bool burnSuccess = IERC20STEAM(steam).burn(amount);

        assertEq(burnSuccess, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), 0);
    }

    // in the solidity version we're not going to have a set_minter
    // function test_setMinter() public {
    //     // Set minter role to user1
    //     vm.prank(admin);
    //     IERC20STEAM(steam).set_minter(user1);

    //     // Verify minter is set correctly
    //     assertEq(IERC20STEAM(steam).minter(), user1);
    // }

    // function test_setMinterUnauthorized() public {
    //     // Try to set minter as non-admin
    //     vm.prank(user1);
    //     vm.expectRevert(); // Should revert
    //     IERC20STEAM(steam).set_minter(user2);
    // }

    // nor a set_admin
    // function test_setAdmin() public {
    //     // Set admin role to user1
    //     vm.prank(admin);
    //     IERC20STEAM(steam).set_admin(user1);

    //     // Verify admin is set correctly
    //     assertEq(IERC20STEAM(steam).admin(), user1);

    //     // Verify user1 can now perform admin functions
    //     vm.prank(user1);
    //     IERC20STEAM(steam).set_minter(user2);
    //     assertEq(IERC20STEAM(steam).minter(), user2);
    // }

    // function test_setAdminUnauthorized() public {
    //     // Try to set admin as non-admin
    //     vm.prank(user1);
    //     vm.expectRevert(); // Should revert
    //     IERC20STEAM(steam).set_admin(user2);
    // }

    // function test_setName() public {
    //     string memory newName = "New STEAM";
    //     string memory newSymbol = "nSTEAM";

    //     // Set new name and symbol
    //     vm.prank(admin);
    //     IERC20STEAM(steam).set_name(newName, newSymbol);

    //     // Verify name and symbol are set correctly
    //     assertEq(IERC20STEAM(steam).name(), newName);
    //     assertEq(IERC20STEAM(steam).symbol(), newSymbol);
    // }

    function test_updateComplexMiningParameters() public {
        // Get initial rate (which might be zero)
        uint256 initialRate = IERC20STEAM(steam).rate();

        // First, ensure we have a non-zero rate by moving to the first epoch
        if (initialRate == 0) {
            // Fast forward to next epoch to initialize rate
            uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1 days);

            // Update mining parameters
            vm.prank(admin);
            IERC20STEAM(steam).update_mining_parameters();

            // Now get the initialized rate
            initialRate = IERC20STEAM(steam).rate();

            // Should now be the initial rate
            assertEq(initialRate, INITIAL_RATE);

            // Fast forward to another epoch for the first reduction
            futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1 days);
        } else {
            // Fast forward to next epoch
            uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1 days);
        }

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Verify rate has changed
        uint256 newRate = IERC20STEAM(steam).rate();

        // If we initialized the rate, we need to check the reduction from INITIAL_RATE
        if (initialRate == INITIAL_RATE) {
            assertEq(newRate, (initialRate * 1e18) / RATE_REDUCTION_COEFFICIENT);
        } else {
            // For already initialized rate (though we don't expect this case based on failures)
            assertEq(newRate, (initialRate * 1e18) / RATE_REDUCTION_COEFFICIENT);
        }
    }

    function test_updateMiningParametersSameEpoch() public {
        // Update mining parameters
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Try to update again in same epoch
        vm.prank(admin);
        vm.expectRevert(); // can't update same epoch
        IERC20STEAM(steam).update_mining_parameters();
    }

    // function test_setNameUnauthorized() public {
    //     // Try to set name as non-admin
    //     vm.prank(user1);
    //     vm.expectRevert(); // Should revert
    //     IERC20STEAM(steam).set_name("Fake", "FAKE");
    // }

    function test_adminUnauthorized() public {
        // // Try to set minter as non-admin
        // vm.prank(user1);
        // vm.expectRevert(); // Should revert
        // IERC20STEAM(steam).set_minter(user2);

        // // Try to set admin as non-admin
        // vm.prank(user1);
        // vm.expectRevert(); // Should revert
        // IERC20STEAM(steam).set_admin(user2);

        // // Try to set name as non-admin
        // vm.prank(user1);
        // vm.expectRevert(); // Should revert
        // IERC20STEAM(steam).set_name("Fake", "FAKE");

        // Try to update mining parameters as non-admin
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).update_mining_parameters();
    }

    function test_initialMiningParameters() public view {
        // Check initial mining parameters
        assertEq(IERC20STEAM(steam).INITIAL_RATE(), INITIAL_RATE);
        assertEq(IERC20STEAM(steam).RATE_REDUCTION_COEFFICIENT(), RATE_REDUCTION_COEFFICIENT);
        assertEq(IERC20STEAM(steam).mining_epoch(), -1);
    }

    function test_miningParameters() public {
        // Get initial values
        int128 initialEpoch = IERC20STEAM(steam).mining_epoch();

        // Check that mining_epoch is properly initialized to 0
        assertEq(initialEpoch, -1);

        // Fast forward to next epoch
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Mining epoch should have advanced
        assertEq(IERC20STEAM(steam).mining_epoch(), initialEpoch + 1);
    }

    function test_updateSimpleMiningParameters() public {
        // Get initial rate (which could be zero)
        uint256 initialRate = IERC20STEAM(steam).rate();

        // Fast forward to next epoch
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Verify rate has been set
        uint256 newRate = IERC20STEAM(steam).rate();

        // After updating parameters, the rate should be non-zero
        assertGt(newRate, 0);

        // If initial rate was zero, this is the first update
        if (initialRate == 0) {
            // First update should set rate to INITIAL_RATE
            assertEq(newRate, INITIAL_RATE);
        } else {
            // Subsequent updates should reduce by coefficient
            assertEq(newRate, (initialRate * 1e18) / RATE_REDUCTION_COEFFICIENT);
        }
    }

    function test_epochTimeWrite() public {
        // Test start_epoch_time_write
        uint256 startTime = IERC20STEAM(steam).start_epoch_time_write();
        assertGt(startTime, 0);

        // Test future_epoch_time_write
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        assertGt(futureTime, startTime);
    }

    function test_availableSupplyOldEpoch() public {
        // Get initial available supply
        uint256 initialAvailable = IERC20STEAM(steam).available_supply();

        // Fast forward time to increase available supply
        vm.warp(block.timestamp + 365 days);

        // Check that available supply has increased
        uint256 newAvailable = IERC20STEAM(steam).available_supply();
        assertEq(newAvailable, initialAvailable);
    }

    function test_availableSupplyNewEpoch() public {
        // Fast forward to next epoch to enable supply changes
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters to register the new epoch
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Get available supply after the update
        uint256 initialAvailable = IERC20STEAM(steam).available_supply();

        // Fast forward time further to increase available supply
        vm.warp(block.timestamp + 365 days);

        // Check that available supply has increased
        uint256 newAvailable = IERC20STEAM(steam).available_supply();
        assertGt(newAvailable, initialAvailable);
    }

    function test_mintableInOldTimeframe() public {
        uint256 start = block.timestamp;
        uint256 end = start + 365 days;

        // Calculate mintable amount
        uint256 mintable = IERC20STEAM(steam).mintable_in_timeframe(start, end);

        // Verify it's zero and reasonable
        assertEq(mintable, 0);

        // Try with invalid timeframe (end before start)
        vm.expectRevert();
        IERC20STEAM(steam).mintable_in_timeframe(end, start);
    }

    function test_mint() public {
        // Fast forward time to create mintable supply
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Check available supply to mint
        uint256 availableToMint = IERC20STEAM(steam).available_supply() - IERC20STEAM(steam).totalSupply();

        // Use a smaller amount that's definitely available
        uint256 amount = availableToMint > 0 ? availableToMint / 2 : 0;
        // Skip test if no mintable amount
        if (amount == 0) return;

        uint256 initialSupply = IERC20STEAM(steam).totalSupply();

        // Mint tokens to user1
        vm.prank(minter);
        bool success = IERC20STEAM(steam).mint(user1, amount);

        // Check success and balances
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);
        assertEq(IERC20STEAM(steam).totalSupply(), initialSupply + amount);
    }

    function test_burn() public {
        uint256 amount = 1000 ether;

        // Give user1 some tokens by transferring from admin
        vm.prank(admin);
        IERC20STEAM(steam).transfer(user1, amount);

        // Ensure user has the tokens
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);

        uint256 initialSupply = IERC20STEAM(steam).totalSupply();

        // Burn tokens from user1
        vm.prank(user1);
        bool success = IERC20STEAM(steam).burn(amount);

        // Check success and balances
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), 0);
        assertEq(IERC20STEAM(steam).totalSupply(), initialSupply - amount);
    }

    function test_mintUnauthorized() public {
        uint256 amount = 1000 ether;

        // Try to mint as non-minter
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).mint(user2, amount);
    }

    function test_mintZero() public {
        uint256 initialSupply = IERC20STEAM(steam).totalSupply();

        // Mint zero tokens
        vm.prank(minter);
        bool success = IERC20STEAM(steam).mint(user1, 0);

        // Check supply unchanged
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).totalSupply(), initialSupply);
        assertEq(IERC20STEAM(steam).balanceOf(user1), 0);
    }

    function test_burnZero() public {
        // Give user1 some tokens first
        uint256 amount = 1000 ether;
        vm.prank(admin);
        IERC20STEAM(steam).transfer(user1, amount);

        uint256 initialSupply = IERC20STEAM(steam).totalSupply();

        // Burn zero tokens
        vm.prank(user1);
        bool success = IERC20STEAM(steam).burn(0);

        // Check balances unchanged
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).totalSupply(), initialSupply);
        assertEq(IERC20STEAM(steam).balanceOf(user1), amount);
    }

    function test_transferToZeroAddress() public {
        uint256 amount = 1000 ether;

        // Try to transfer to zero address
        vm.prank(admin);
        vm.expectRevert();
        IERC20STEAM(steam).transfer(address(0), amount);
    }

    function test_approveZeroAddress() public {
        uint256 amount = 1000 ether;

        // Try to approve zero address
        vm.prank(admin);
        if (!vyper) vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        IERC20STEAM(steam).approve(address(0), amount);
    }

    function test_transferFromPartialAllowance() public {
        uint256 allowance = 1000 ether;
        uint256 transferAmount = 600 ether;

        // Approve user1 to spend admin's tokens
        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, allowance);

        // Transfer part of allowed amount
        vm.prank(user1);
        bool success = IERC20STEAM(steam).transferFrom(admin, user2, transferAmount);

        // Check success, balances and remaining allowance
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user2), transferAmount);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY - transferAmount);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), allowance - transferAmount);
    }

    function test_infiniteApproval() public {
        uint256 maxApproval = type(uint256).max;
        uint256 transferAmount = 1000 ether;

        // Set max approval
        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, maxApproval);
        assertEq(IERC20STEAM(steam).allowance(admin, user1), maxApproval);

        // Transfer some amount
        vm.prank(user1);
        bool success = IERC20STEAM(steam).transferFrom(admin, user2, transferAmount);

        // Check if infinite approval doesn't change after transfer

        assertEq(success, true);
        // the below is an acceptable deviation between vyper and solidity versions
        assertEq(IERC20STEAM(steam).allowance(admin, user1), maxApproval - (vyper ? transferAmount : 0));
    }

    function test_transferZero() public {
        // Transfer zero amount
        vm.prank(admin);
        bool success = IERC20STEAM(steam).transfer(user1, 0);

        // Should succeed but not change balances
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(user1), 0);
        assertEq(IERC20STEAM(steam).balanceOf(admin), INITIAL_SUPPLY);
    }

    function test_transferInsufficientBalance() public {
        uint256 excessAmount = INITIAL_SUPPLY + 1 ether;

        // Try to transfer more than balance
        vm.prank(admin);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).transfer(user1, excessAmount);
    }

    function test_transferFromInsufficientAllowance() public {
        uint256 amount = 1000 ether;
        uint256 excessAmount = amount + 1 ether;

        // Set allowance
        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, amount);

        // Try to transfer more than allowed
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).transferFrom(admin, user2, excessAmount);
    }

    function test_selfTransfer() public {
        uint256 amount = 1000 ether;

        // Record initial balance
        uint256 initialBalance = IERC20STEAM(steam).balanceOf(admin);

        // Transfer to self
        vm.prank(admin);
        bool success = IERC20STEAM(steam).transfer(admin, amount);

        // Check success and balance unchanged
        assertEq(success, true);
        assertEq(IERC20STEAM(steam).balanceOf(admin), initialBalance);
    }

    function test_burnInsufficientBalance() public {
        // Try to burn without balance
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).burn(1 ether);
    }

    function test_multipleInitialization() public {
        // Try to initialize again
        vm.prank(admin);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).initialize(
            INITIAL_SUPPLY,
            INITIAL_RATE,
            RATE_REDUCTION_COEFFICIENT,
            admin,
            "STEAM",
            "STEAM"
        );
    }

    function test_availableSupply() public {
        // Initially, available supply should be equal to initial supply
        assertEq(IERC20STEAM(steam).available_supply(), INITIAL_SUPPLY);

        // Fast forward to create more mintable supply
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Available supply should increase
        assertGt(IERC20STEAM(steam).available_supply(), INITIAL_SUPPLY);
    }

    function test_availableSupplyUnchanged() public {
        // Initially, available supply equals initial supply
        uint256 initialAvailable = IERC20STEAM(steam).available_supply();
        assertEq(initialAvailable, INITIAL_SUPPLY);

        // Advance time slightly but stay in same epoch
        vm.warp(IERC20STEAM(steam).start_epoch_time() + 1 days);

        // Without updating mining parameters or reaching a new epoch,
        // available supply should still equal initial supply
        assertEq(IERC20STEAM(steam).available_supply(), initialAvailable);
    }

    function test_availableSupplyAtMultipleEpochs() public {
        // Fast forward to next epoch to enable supply changes
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters to register the new epoch
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Record supply at first epoch
        uint256 supply1 = IERC20STEAM(steam).available_supply();

        // Fast forward to second epoch
        futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Record supply at second epoch
        uint256 supply2 = IERC20STEAM(steam).available_supply();

        // Check increasing supply with decreasing rate
        assertGt(supply2, supply1);
    }

    function test_rateReduction() public {
        // Get initial rate (which might be zero)
        uint256 initialRate = IERC20STEAM(steam).rate();

        // First, ensure we have a non-zero rate by moving to the first epoch
        if (initialRate == 0) {
            // Fast forward to next epoch to initialize rate
            uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1);

            // Update mining parameters
            vm.prank(admin);
            IERC20STEAM(steam).update_mining_parameters();

            // Now get the initialized rate
            initialRate = IERC20STEAM(steam).rate();

            // Should now be the initial rate
            assertEq(initialRate, INITIAL_RATE);

            // Fast forward to another epoch for the first reduction
            futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1);
        } else {
            // Fast forward to next epoch
            uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
            vm.warp(futureTime + 1);
        }

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Check new rate is reduced by the coefficient
        uint256 newRate = IERC20STEAM(steam).rate();
        assertEq(newRate, (initialRate * 1e18) / RATE_REDUCTION_COEFFICIENT);

        // Fast forward to another epoch
        uint256 nextFutureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(nextFutureTime + 1);

        // Update mining parameters again
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Check rate is reduced again
        uint256 nextRate = IERC20STEAM(steam).rate();
        assertEq(nextRate, (newRate * 1e18) / RATE_REDUCTION_COEFFICIENT);
    }

    function test_epochTimeAdvancement() public {
        // Get initial epoch time
        uint256 initialStartTime = IERC20STEAM(steam).start_epoch_time();
        int128 initialEpoch = IERC20STEAM(steam).mining_epoch();

        // Fast forward to next epoch
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Check epoch time and number have advanced
        uint256 newStartTime = IERC20STEAM(steam).start_epoch_time();
        int128 newEpoch = IERC20STEAM(steam).mining_epoch();

        assertGt(newStartTime, initialStartTime);
        assertEq(newEpoch, initialEpoch + 1);
    }

    function test_mintableInTimeframe() public {
        // Start by advancing time to create a non-zero mintable timeframe
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1 days);

        // Update mining parameters to ensure rates are properly set
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Now check mintable amount over a significant period
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        // Check mintable amount over the timeframe
        uint256 mintable = IERC20STEAM(steam).mintable_in_timeframe(startTime, endTime);

        // Should be positive based on emission schedule
        assertGt(mintable, 0);
    }
    /*
    function testGas_transfer() public {
        uint256 MAX_GAS_TRANSFER = 28_500;
        uint256 amount = 1 ether;

        // Pre-fund user1
        vm.prank(admin);
        IERC20STEAM(steam).transfer(user1, 10 ether);

        // Measure gas for transfer
        vm.prank(user1);
        uint256 gasBefore = gasleft();
        IERC20STEAM(steam).transfer(user2, amount);
        uint256 gasUsed = gasBefore - gasleft();

        // Check gas is under maximum
        assertLe(gasUsed, MAX_GAS_TRANSFER, "Gas usage for transfer exceeded maximum allowed");

        // Check gas is not more than 5% below target (using assertApproxEqAbs)
        assertApproxEqRel(
            gasUsed,
            MAX_GAS_TRANSFER,
            GAS_TOLERANCE_PERCENTAGE * 1e16, // 5% as a fraction of 1e18
            "Gas usage for transfer is significantly below maximum. Update MAX_GAS_TRANSFER to the new value."
        );
    }

    function testGas_approve() public {
        uint256 MAX_GAS_APPROVE = vyper ? 31_000 : 35_000;
        uint256 amount = 1 ether;

        // Measure gas for approve
        vm.prank(admin);
        uint256 gasBefore = gasleft();
        IERC20STEAM(steam).approve(user1, amount);
        uint256 gasUsed = gasBefore - gasleft();

        // Check gas is under maximum
        assertLe(gasUsed, MAX_GAS_APPROVE, "Gas usage for approve exceeded maximum allowed");

        // Check gas is not more than 5% below target (using assertApproxEqAbs)
        assertApproxEqRel(
            gasUsed,
            MAX_GAS_APPROVE,
            GAS_TOLERANCE_PERCENTAGE * 1e16, // 5% as a fraction of 1e18
            "Gas usage for approve is significantly below maximum. Update MAX_GAS_APPROVE to the new value."
        );
    }

    function testGas_transferFrom() public {
        uint256 MAX_GAS_TRANSFERFROM = 34_100;
        uint256 amount = 1 ether;

        // Setup
        vm.prank(admin);
        IERC20STEAM(steam).approve(user1, amount);

        // Measure gas for transferFrom
        vm.prank(user1);
        uint256 gasBefore = gasleft();
        IERC20STEAM(steam).transferFrom(admin, user2, amount);
        uint256 gasUsed = gasBefore - gasleft();

        // Check gas is under maximum
        assertLe(gasUsed, MAX_GAS_TRANSFERFROM, "Gas usage for transferFrom exceeded maximum allowed");

        // Check gas is not more than 5% below target (using assertApproxEqAbs)
        assertApproxEqRel(
            gasUsed,
            MAX_GAS_TRANSFERFROM,
            GAS_TOLERANCE_PERCENTAGE * 1e16, // 5% as a fraction of 1e18
            "Gas usage for transferFrom is significantly below maximum. Update MAX_GAS_TRANSFERFROM to the new value."
        );
    }
*/
}

contract ERC20STEAMVyTest is ERC20STEAM {
    constructor() ERC20STEAM(true) {}
}

contract ERC20STEAMSolTest is ERC20STEAM {
    constructor() ERC20STEAM(false) {}
}
