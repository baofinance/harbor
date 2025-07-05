// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

// Mock Voting Escrow Boost that returns zero boost
contract MockVeBoost {
    function adjusted_balance_of(address) external pure returns (uint256) {
        return 0;
    }
}

contract LiquidityGaugeV6Test is Test {
    address public gauge;
    address public lpToken;
    address public crvToken;

    address public user1;
    address public user2;
    address public manager;

    // CRV token address from the contract (mainnet)
    address constant CRV_ADDRESS = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address constant MINTER = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;
    address constant VEBOOST_PROXY = 0x8E0c00ed546602fD9927DF742bbAbF726D5B0d16;
    address constant VOTING_ESCROW = 0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2;

    function setUp() public virtual {
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

    function test_Deployment() public view {
        // Test basic deployment parameters
        assertEq(ILiquidityGaugeV6(gauge).lp_token(), lpToken, "LP token should be set correctly");
        // assertEq(ILiquidityGaugeV6(gauge).factory(), manager, "Factory should be msg.sender");
        assertEq(ILiquidityGaugeV6(gauge).manager(), manager, "Manager should be tx.origin");
        assertFalse(ILiquidityGaugeV6(gauge).is_killed(), "Gauge should not be killed initially");
        assertEq(ILiquidityGaugeV6(gauge).reward_count(), 0, "Should have no rewards initially");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), 0, "Total supply should be 0 initially");
        assertEq(ILiquidityGaugeV6(gauge).working_supply(), 0, "Working supply should be 0 initially");
    }

    function test_TokenMetadata() public view {
        // Test ERC20 metadata
        string memory expectedName = "Curve.fi TLP Gauge Deposit";
        string memory expectedSymbol = "TLP-gauge";

        assertEq(ILiquidityGaugeV6(gauge).name(), expectedName, "Name should match expected format");
        assertEq(ILiquidityGaugeV6(gauge).symbol(), expectedSymbol, "Symbol should match expected format");
    }

    function test_Deposit() public {
        uint256 depositAmount = 100 ether;

        // Approve the gauge to spend LP tokens
        vm.prank(user1);
        IERC20(lpToken).approve(gauge, depositAmount);

        // Check initial balances
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), 0, "User1 should have 0 gauge tokens initially");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), 0, "Total supply should be 0 initially");

        // Deposit LP tokens
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check balances after deposit
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user1),
            depositAmount,
            "User1 should have deposited amount of gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), depositAmount, "Total supply should equal deposited amount");
        assertEq(IERC20(lpToken).balanceOf(user1), 900 ether, "User1 should have remaining LP tokens");
        assertEq(IERC20(lpToken).balanceOf(gauge), depositAmount, "Gauge should hold deposited LP tokens");
    }

    function test_DepositForRecipient() public {
        uint256 depositAmount = 50 ether;

        // Approve the gauge to spend LP tokens
        vm.prank(user1);
        IERC20(lpToken).approve(gauge, depositAmount);

        // Deposit LP tokens for user2
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount, user2);

        // Check balances after deposit
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), 0, "User1 should have 0 gauge tokens");
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user2),
            depositAmount,
            "User2 should have deposited amount of gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), depositAmount, "Total supply should equal deposited amount");
        assertEq(IERC20(lpToken).balanceOf(user1), 950 ether, "User1 should have remaining LP tokens");
        assertEq(IERC20(lpToken).balanceOf(gauge), depositAmount, "Gauge should hold deposited LP tokens");
    }

    function test_Withdraw() public {
        uint256 depositAmount = 200 ether;
        uint256 withdrawAmount = 75 ether;

        // First deposit
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, depositAmount);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check state before withdrawal
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), depositAmount, "User1 should have deposited amount");

        // Withdraw some tokens
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount);
        vm.stopPrank();

        // Check balances after withdrawal
        uint256 remainingGaugeBalance = depositAmount - withdrawAmount;
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user1),
            remainingGaugeBalance,
            "User1 should have remaining gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), remainingGaugeBalance, "Total supply should be reduced");
        assertEq(IERC20(lpToken).balanceOf(user1), 800 ether + withdrawAmount, "User1 should have withdrawn LP tokens");
        assertEq(IERC20(lpToken).balanceOf(gauge), remainingGaugeBalance, "Gauge should hold remaining LP tokens");
    }

    function test_MultipleUsersDeposit() public {
        uint256 deposit1 = 150 ether;
        uint256 deposit2 = 80 ether;

        // User1 deposits
        vm.prank(user1);
        IERC20(lpToken).approve(gauge, deposit1);
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(deposit1);

        // User2 deposits
        vm.prank(user2);
        IERC20(lpToken).approve(gauge, deposit2);
        vm.prank(user2);
        ILiquidityGaugeV6(gauge).deposit(deposit2);

        // Check individual balances
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), deposit1, "User1 should have correct balance");
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user2), deposit2, "User2 should have correct balance");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), deposit1 + deposit2, "Total supply should be sum of deposits");
        assertEq(IERC20(lpToken).balanceOf(gauge), deposit1 + deposit2, "Gauge should hold all LP tokens");
    }

    function test_UserCheckpoint() public {
        // Test user checkpoint functionality
        vm.prank(user1);
        bool success = ILiquidityGaugeV6(gauge).user_checkpoint(user1);
        assertTrue(success, "User checkpoint should succeed");
    }

    function test_WorkingBalances() public {
        uint256 depositAmount = 100 ether;

        // Deposit tokens
        vm.prank(user1);
        IERC20(lpToken).approve(gauge, depositAmount);
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check working balances (should be related to boost calculations)
        uint256 workingBalance = ILiquidityGaugeV6(gauge).working_balances(user1);
        uint256 workingSupply = ILiquidityGaugeV6(gauge).working_supply();

        // Working balance should be non-zero after deposit
        assertGt(workingBalance, 0, "Working balance should be greater than 0");
        assertGt(workingSupply, 0, "Working supply should be greater than 0");
        assertLe(workingBalance, depositAmount, "Working balance should not exceed actual balance");
    }

    function test_Period() public view {
        // Test that period tracking works
        int128 currentPeriod = ILiquidityGaugeV6(gauge).period();
        assertGe(currentPeriod, 0, "Period should be non-negative");
    }

    function test_RevertWhen_WithdrawMoreThanBalance() public {
        uint256 depositAmount = 50 ether;
        uint256 withdrawAmount = 100 ether; // More than deposited

        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, depositAmount);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // This should fail
        vm.expectRevert(); // the contract does a depositAmount - withdrawAmount which results in a data-less revert
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWithoutApproval() public {
        uint256 depositAmount = 100 ether;

        // Try to deposit without approval - should fail
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, gauge, 0, depositAmount)
        );
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);
    }
}

contract LiquidityGaugeV6RewardsTest is LiquidityGaugeV6Test {
    MockERC20 public steamToken;
    address public distributor;

    uint256 constant REWARD_DURATION = 1 weeks;

    function setUp() public override {
        // Call parent setup
        super.setUp();

        // Mock GAUGE_CONTROLLER
        vm.etch(GAUGE_CONTROLLER, hex"00");

        // Mock checkpoint_gauge - this can be a no-op
        vm.mockCall(
            GAUGE_CONTROLLER,
            abi.encodeWithSignature("checkpoint_gauge(address)"),
            abi.encode() // empty return
        );

        // Mock gauge_relative_weight - return a reasonable weight like 1e18 (100%)
        vm.mockCall(
            GAUGE_CONTROLLER,
            abi.encodeWithSignature("gauge_relative_weight(address,uint256)"),
            abi.encode(1e18) // 100% weight
        );

        // Create STEAM token for rewards
        steamToken = new MockERC20("STEAM Token", "STEAM", 18);

        // Create distributor address
        distributor = makeAddr("distributor");

        // Mint STEAM tokens to distributor for reward distribution
        steamToken.mint(distributor, 10000 ether);
    }

    function test_AddRewardToken() public {
        // Only manager can add reward tokens
        vm.prank(manager);
        ILiquidityGaugeV6(gauge).add_reward(address(steamToken), distributor);

        // Check reward was added
        assertEq(ILiquidityGaugeV6(gauge).reward_count(), 1, "Should have 1 reward token");
    }

    function test_RevertWhen_NonManagerAddsReward() public {
        // Non-manager should not be able to add rewards
        vm.expectRevert();
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).add_reward(address(steamToken), distributor);
    }

    function test_DepositRewardTokens() public {
        uint256 rewardAmount = 1000 ether;

        // Setup: Add reward token
        vm.prank(manager);
        ILiquidityGaugeV6(gauge).add_reward(address(steamToken), distributor);

        // Distributor deposits reward tokens
        vm.startPrank(distributor);
        steamToken.approve(gauge, rewardAmount);
        ILiquidityGaugeV6(gauge).deposit_reward_token(address(steamToken), rewardAmount);
        vm.stopPrank();

        // Check tokens were transferred to gauge
        assertEq(steamToken.balanceOf(gauge), rewardAmount, "Gauge should have reward tokens");
        assertEq(steamToken.balanceOf(distributor), 9000 ether, "Distributor balance should be reduced");
    }

    function test_RevertWhen_NonDistributorDepositsRewards() public {
        uint256 rewardAmount = 1000 ether;

        // Setup: Add reward token
        vm.prank(manager);
        ILiquidityGaugeV6(gauge).add_reward(address(steamToken), distributor);

        // Mint tokens to user1 to attempt unauthorized deposit
        steamToken.mint(user1, rewardAmount);

        // Non-distributor should not be able to deposit rewards
        vm.startPrank(user1);
        steamToken.approve(gauge, rewardAmount);
        vm.expectRevert();
        ILiquidityGaugeV6(gauge).deposit_reward_token(address(steamToken), rewardAmount);
        vm.stopPrank();
    }

    function test_SingleUserDepositAndClaimRewards() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User1 deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Fast forward time to accrue rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2); // Half way through reward period

        // Check claimable rewards
        uint256 claimable = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        assertGt(claimable, 0, "User should have claimable rewards");

        // Claim rewards
        uint256 initialBalance = steamToken.balanceOf(user1);
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).claim_rewards();

        uint256 finalBalance = steamToken.balanceOf(user1);
        assertGt(finalBalance, initialBalance, "User should receive STEAM tokens");
        assertEq(finalBalance - initialBalance, claimable, "Should receive exact claimable amount");
    }

    function test_WorkingBalanceReducesAfterWithdrawal() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        uint256 withdrawAmount = 50 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        uint256 workingBalanceBefore = ILiquidityGaugeV6(gauge).working_balances(user1);

        // Withdraw half the LP tokens
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount, false);

        uint256 workingBalanceAfter = ILiquidityGaugeV6(gauge).working_balances(user1);

        // Working balance should be reduced proportionally
        assertApproxEqRel(workingBalanceAfter, workingBalanceBefore / 2, 0.01e18, "Working balance should be halved");
        assertLt(workingBalanceAfter, workingBalanceBefore, "Working balance should decrease after withdrawal");
    }

    function test_ProportionalRewardsMultipleUsers() public {
        uint256 rewardAmount = 1000 ether;
        _setupRewards(rewardAmount);

        // User1: 25 ether, User2: 75 ether (3:1 ratio)
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, 25 ether);
        ILiquidityGaugeV6(gauge).deposit(25 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(lpToken).approve(gauge, 75 ether);
        ILiquidityGaugeV6(gauge).deposit(75 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION);

        uint256 user1Rewards = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 user2Rewards = ILiquidityGaugeV6(gauge).claimable_reward(user2, address(steamToken));

        // User2 should earn ~3x more than User1
        assertApproxEqRel(user2Rewards, user1Rewards * 3, 0.1e18, "User2 should earn ~3x more");

        // Total should be close to reward amount
        assertApproxEqRel(
            user1Rewards + user2Rewards,
            rewardAmount,
            0.01e18,
            "Total rewards should equal reward amount"
        );
    }

    function test_WithdrawDoesNotLoseRewards() public {
        uint256 rewardAmount = 1000 ether;
        _setupRewards(rewardAmount);

        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, 100 ether);
        ILiquidityGaugeV6(gauge).deposit(100 ether);
        vm.stopPrank();

        // Accrue rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);
        uint256 rewardsBeforeWithdraw = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Withdraw without claiming
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).withdraw(50 ether, false);

        uint256 rewardsAfterWithdraw = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Rewards should not decrease from withdrawal
        assertGe(rewardsAfterWithdraw, rewardsBeforeWithdraw, "Withdrawal should not reduce claimable rewards");

        // Should be able to claim the rewards
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).claim_rewards();

        uint256 steamBalance = steamToken.balanceOf(user1);
        assertGe(steamBalance, rewardsBeforeWithdraw, "Should receive at least pre-withdrawal rewards");
    }

    function test_RewardRateReflectsBalanceWithMultipleUsers() public {
        uint256 user1Amount = 100 ether;
        uint256 user2Amount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        uint256 withdrawAmount = 75 ether; // User1 withdraws most tokens

        // Setup rewards
        _setupRewards(rewardAmount);

        // Both users deposit equal amounts
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, user1Amount);
        ILiquidityGaugeV6(gauge).deposit(user1Amount);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(lpToken).approve(gauge, user2Amount);
        ILiquidityGaugeV6(gauge).deposit(user2Amount);
        vm.stopPrank();

        // Fast forward and check rewards (equal stakes)
        vm.warp(block.timestamp + REWARD_DURATION / 10);
        uint256 user1RewardsBefore = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 user2RewardsBefore = ILiquidityGaugeV6(gauge).claimable_reward(user2, address(steamToken));

        // User1 withdraws most of their stake
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount, false);

        // Check working balances after withdrawal
        uint256 user1WorkingBalance = ILiquidityGaugeV6(gauge).working_balances(user1);
        uint256 user2WorkingBalance = ILiquidityGaugeV6(gauge).working_balances(user2);

        // Fast forward the same period
        vm.warp(block.timestamp + REWARD_DURATION / 10);

        uint256 user1RewardsAfter = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 user2RewardsAfter = ILiquidityGaugeV6(gauge).claimable_reward(user2, address(steamToken));

        uint256 user1NewRewards = user1RewardsAfter - user1RewardsBefore;
        uint256 user2NewRewards = user2RewardsAfter - user2RewardsBefore;

        // User2 should now earn significantly more than User1
        assertGt(
            user2NewRewards,
            user1NewRewards,
            "User2 should earn more rewards than User1 after User1's withdrawal"
        );

        // The ratio should reflect the working balance difference
        uint256 expectedRatio = (user2WorkingBalance * 100) / user1WorkingBalance;
        uint256 actualRatio = (user2NewRewards * 100) / user1NewRewards;

        // Allow some tolerance for the ratio comparison
        assertApproxEqRel(
            actualRatio,
            expectedRatio,
            0.2e18,
            "Reward ratio should roughly match working balance ratio"
        );
    }

    function test_MultipleUsersProportionalRewards() public {
        uint256 user1Amount = 100 ether;
        uint256 user2Amount = 300 ether; // 3x more
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // Both users deposit
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, user1Amount);
        ILiquidityGaugeV6(gauge).deposit(user1Amount);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(lpToken).approve(gauge, user2Amount);
        ILiquidityGaugeV6(gauge).deposit(user2Amount);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 user1Rewards = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 user2Rewards = ILiquidityGaugeV6(gauge).claimable_reward(user2, address(steamToken));

        // User2 should earn approximately 3x more (allowing for rounding)
        assertApproxEqRel(user2Rewards, user1Rewards * 3, 0.05e18, "User2 should earn ~3x more rewards");
        assertGt(user2Rewards, user1Rewards * 2, "User2 should earn at least 2x more");
    }

    function test_RewardsStopAfterPeriodEnd() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Go to end of reward period
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 rewardsAtEnd = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Go well past reward period
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 rewardsAfterEnd = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        assertEq(rewardsAfterEnd, rewardsAtEnd, "Rewards should not increase after period ends");
        assertApproxEqRel(rewardsAtEnd, rewardAmount, 0.01e18, "Should be able to claim most of reward pool");
    }

    function test_WithdrawAndRewardAccrual() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Accrue some rewards
        vm.warp(block.timestamp + REWARD_DURATION / 4);
        uint256 rewardsBefore = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Withdraw some tokens but don't claim rewards
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).withdraw(50 ether, false);

        // Check that previous rewards are still claimable
        uint256 rewardsAfterWithdraw = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        assertGe(rewardsAfterWithdraw, rewardsBefore, "Previous rewards should still be claimable");

        // User should be able to claim their accumulated rewards
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).claim_rewards();

        uint256 steamBalance = steamToken.balanceOf(user1);
        assertGe(steamBalance, rewardsBefore, "Should receive at least the pre-withdrawal rewards");
    }

    function test_WithdrawWithoutClaimingRewards() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        uint256 withdrawAmount = 30 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 claimableBefore = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 steamBalanceBefore = steamToken.balanceOf(user1);

        // Withdraw without claiming rewards (using low-level call until interface is updated)
        vm.prank(user1);
        (bool success, ) = gauge.call(abi.encodeWithSignature("withdraw(uint256,bool)", withdrawAmount, false));
        require(success, "Withdraw without claiming should succeed");

        // Check that rewards weren't claimed during withdrawal
        assertEq(steamToken.balanceOf(user1), steamBalanceBefore, "STEAM balance should not change");

        // But claimable rewards should still be available
        uint256 claimableAfter = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        assertGe(claimableAfter, claimableBefore, "Claimable rewards should not decrease");
    }

    function test_WithdrawAndClaimRewards() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        uint256 withdrawAmount = 30 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 claimableBefore = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        uint256 steamBalanceBefore = steamToken.balanceOf(user1);

        // Withdraw and claim rewards (using low-level call until interface is updated)
        vm.prank(user1);
        (bool success, ) = gauge.call(abi.encodeWithSignature("withdraw(uint256,bool)", withdrawAmount, true));
        require(success, "Withdraw with claiming should succeed");

        // Check that rewards were claimed during withdrawal
        uint256 steamBalanceAfter = steamToken.balanceOf(user1);
        assertEq(steamBalanceAfter, steamBalanceBefore + claimableBefore, "Should receive STEAM rewards");

        // Claimable rewards should be reset
        uint256 claimableAfter = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        assertLt(claimableAfter, claimableBefore, "Claimable rewards should decrease after claiming");
    }

    function test_WithdrawImmediatelyAfterDeposit() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        uint256 withdrawAmount = 50 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);

        // Try to withdraw immediately without any time passing
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount, false);
        vm.stopPrank();
    }

    function test_ClaimRewardsToCustomReceiver() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;
        address customReceiver = makeAddr("customReceiver");

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        // Claim rewards to custom receiver
        uint256 claimable = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).claim_rewards(user1, customReceiver);

        // Check custom receiver got the tokens
        assertEq(steamToken.balanceOf(customReceiver), claimable, "Custom receiver should get rewards");
        assertEq(steamToken.balanceOf(user1), 0, "User1 should not receive tokens");
    }

    function test_RewardsAccrueCorrectlyOverTime() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Check rewards at different time intervals
        uint256[] memory timePoints = new uint256[](5);
        uint256[] memory rewards = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + REWARD_DURATION / 5);
            timePoints[i] = block.timestamp;
            rewards[i] = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));
        }

        // Rewards should increase over time
        for (uint256 i = 1; i < 5; i++) {
            assertGt(rewards[i], rewards[i - 1], "Rewards should increase over time");
        }

        // At the end of reward period, user should be able to claim most of the reward
        // (accounting for the fact that user is the only depositor)
        assertApproxEqRel(rewards[4], rewardAmount, 0.01e18, "Should be able to claim most rewards");
    }

    function test_NoRewardsAfterPeriodFinish() public {
        uint256 lpAmount = 100 ether;
        uint256 rewardAmount = 1000 ether;

        // Setup rewards
        _setupRewards(rewardAmount);

        // User deposits LP tokens
        vm.startPrank(user1);
        IERC20(lpToken).approve(gauge, lpAmount);
        ILiquidityGaugeV6(gauge).deposit(lpAmount);
        vm.stopPrank();

        // Fast forward to end of reward period
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 claimableAtEnd = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Fast forward well past reward period
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 claimableAfter = ILiquidityGaugeV6(gauge).claimable_reward(user1, address(steamToken));

        // Claimable amount should not increase after reward period ends
        assertEq(claimableAfter, claimableAtEnd, "No additional rewards after period finish");
    }

    // Helper function to setup reward system
    function _setupRewards(uint256 rewardAmount) internal {
        // Add reward token
        vm.prank(manager);
        ILiquidityGaugeV6(gauge).add_reward(address(steamToken), distributor);

        // Deposit reward tokens
        vm.startPrank(distributor);
        steamToken.approve(gauge, rewardAmount);
        ILiquidityGaugeV6(gauge).deposit_reward_token(address(steamToken), rewardAmount);
        vm.stopPrank();
    }
}
