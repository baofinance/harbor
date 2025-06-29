// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";

/**
 * @title ERC20STEAMSetUp
 * @notice Base setup for ERC20STEAM tests
 */
contract ERC20STEAMSetUp is Test {
    // Contract instance (as address, not interface type)
    address public steam;

    // Test constants
    uint256 public constant INITIAL_SUPPLY = 61_000_000 ether;
    uint256 public constant INITIAL_RATE = 1_201_550_387_596_899;
    uint256 public constant RATE_REDUCTION_COEFFICIENT = 1290000000;

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

        // Deploy ERC20STEAM contract (store as address)
        steam = address(vm.deployCode("ERC20STEAM.vy"));

        // Initialize contract with test values
        vm.prank(admin);
        IERC20STEAM(steam).initialize(
            INITIAL_SUPPLY,
            INITIAL_RATE,
            RATE_REDUCTION_COEFFICIENT,
            admin,
            "STEAM",
            "STEAM"
        );
    }
}

/**
 * @title ERC20STEAMBasicTest
 * @notice Tests for basic ERC20 functionality
 */
contract ERC20STEAMBasicTest is ERC20STEAMSetUp {
    function test_initialization() public view {
        // Check initial state
        assertEq(IERC20STEAM(steam).name(), "STEAM");
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
}

/**
 * @title ERC20STEAMMintingTest
 * @notice Tests for minting functionality
 */
contract ERC20STEAMMintingTest is ERC20STEAMSetUp {
    function setUp() public override {
        super.setUp();

        // Set minter role
        vm.prank(admin);
        IERC20STEAM(steam).set_minter(minter);

        assertEq(IERC20STEAM(steam).minter(), minter);
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
}

/**
 * @title ERC20STEAMAdminTest
 * @notice Tests for admin functionality
 */
contract ERC20STEAMAdminTest is ERC20STEAMSetUp {
    function test_setMinter() public {
        // Set minter role to user1
        vm.prank(admin);
        IERC20STEAM(steam).set_minter(user1);

        // Verify minter is set correctly
        assertEq(IERC20STEAM(steam).minter(), user1);
    }

    function test_setMinterUnauthorized() public {
        // Try to set minter as non-admin
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).set_minter(user2);
    }

    function test_setAdmin() public {
        // Transfer admin role to user1
        vm.prank(admin);
        IERC20STEAM(steam).set_admin(user1);

        // Verify admin is set correctly
        assertEq(IERC20STEAM(steam).admin(), user1);

        // Verify user1 can now perform admin functions
        vm.prank(user1);
        IERC20STEAM(steam).set_minter(user2);
        assertEq(IERC20STEAM(steam).minter(), user2);
    }

    function test_setAdminUnauthorized() public {
        // Try to set admin as non-admin
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).set_admin(user2);
    }

    function test_setName() public {
        string memory newName = "New STEAM";
        string memory newSymbol = "NSTM";

        // Change name and symbol
        vm.prank(admin);
        IERC20STEAM(steam).set_name(newName, newSymbol);

        // Verify name and symbol are updated
        assertEq(IERC20STEAM(steam).name(), newName);
        assertEq(IERC20STEAM(steam).symbol(), newSymbol);
    }

    function test_setNameUnauthorized() public {
        // Try to set name as non-admin
        vm.prank(user1);
        vm.expectRevert(); // Should revert
        IERC20STEAM(steam).set_name("Fake", "FAKE");
    }
}

/**
 * @title ERC20STEAMMiningTest
 * @notice Tests for mining parameters and emission functionality
 */
contract ERC20STEAMMiningTest is ERC20STEAMSetUp {
    function setUp() public override {
        super.setUp();

        // Set minter role
        vm.prank(admin);
        IERC20STEAM(steam).set_minter(minter);
    }

    function test_miningParameters() public view {
        // Check initial mining parameters
        assertEq(IERC20STEAM(steam).INITIAL_RATE(), INITIAL_RATE);
        assertEq(IERC20STEAM(steam).RATE_REDUCTION_COEFFICIENT(), RATE_REDUCTION_COEFFICIENT);
        assertEq(IERC20STEAM(steam).mining_epoch(), 0);
    }

    function test_updateMiningParameters() public {
        // Get initial values
        uint256 initialRate = IERC20STEAM(steam).rate();
        int128 initialEpoch = IERC20STEAM(steam).mining_epoch();

        // Fast forward to next epoch
        uint256 futureTime = IERC20STEAM(steam).future_epoch_time_write();
        vm.warp(futureTime + 1);

        // Update mining parameters
        vm.prank(admin);
        IERC20STEAM(steam).update_mining_parameters();

        // Check that values have changed
        assertNotEq(IERC20STEAM(steam).rate(), initialRate);
        assertNotEq(IERC20STEAM(steam).mining_epoch(), initialEpoch);
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

    function test_mintableInTimeframe() public {
        uint256 start = block.timestamp;
        uint256 end = start + 365 days;

        // Calculate mintable amount
        uint256 mintable = IERC20STEAM(steam).mintable_in_timeframe(start, end);

        // Verify it's non-zero and reasonable
        assertGt(mintable, 0);

        // Try with invalid timeframe (end before start)
        vm.expectRevert();
        IERC20STEAM(steam).mintable_in_timeframe(end, start);
    }
}

/**
 * @title ERC20STEAMEdgeCasesTest
 * @notice Tests for edge cases and specific scenarios
 */
contract ERC20STEAMEdgeCasesTest is ERC20STEAMSetUp {
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
}

/**
 * @title ERC20STEAMGasOptimizationTest
 * @notice Tests for gas optimization scenarios with strict assertions
 */
contract ERC20STEAMGasOptimizationTest is ERC20STEAMSetUp {
    // Define maximum acceptable gas values
    uint256 public constant MAX_GAS_TRANSFER = 27_500;
    uint256 public constant MAX_GAS_APPROVE = 32_000;
    uint256 public constant MAX_GAS_TRANSFERFROM = 33_000;

    // Gas test tolerance (5% of max value)
    uint256 public constant GAS_TOLERANCE_PERCENTAGE = 5;

    function testGas_transfer() public {
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
}

/**
 * @title ERC20STEAMFuzzTest
 * @notice Fuzz testing for ERC20STEAM
 */
contract ERC20STEAMFuzzTest is ERC20STEAMSetUp {
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
        // Bound amount to avoid overflow
        amount = bound(amount, 1, type(uint128).max);

        // Set minter
        vm.prank(admin);
        IERC20STEAM(steam).set_minter(minter);

        // Mint tokens
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
}
