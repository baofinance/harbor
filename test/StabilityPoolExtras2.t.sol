// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

/// @title TestStabilityPoolExtra
/// @dev This contract is designed to test additional functionalities and edge cases of the StabilityPool_v3 contract.
/// It extends the TestStabilityPoolSetUp to include more complex scenarios and edge cases.
/// @notice Test contract specifically designed to achieve 100% coverage for StabilityPool_v3
contract TestStabilityPoolExtra2 is TestStabilityPoolSetUp {
    address user3;
    address user4;
    MockERC20 rewardToken;

    // Constants for testing
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant TINY_DEPOSIT = 1; // Extremely small deposit to test edge cases
    uint256 constant REWARD_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        // Create additional users
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");

        // Create a reward token
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        vm.prank(rewardManager);
        // Register reward token
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(rewardToken));

        // Mint reward tokens
        rewardToken.mint(rewardDepositor, 1000 ether);

        // Approve the stabilityPool to spend reward tokens
        vm.prank(rewardDepositor);
        rewardToken.approve(stabilityPoolCollateral, type(uint256).max);

        // Give users tokens for deposits
        deal(peggedToken, user1, 1000 ether);
        deal(peggedToken, user2, 1000 ether);
        deal(peggedToken, user3, 1000 ether);
        deal(peggedToken, user4, 1000 ether);

        // Set approvals
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user4);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
    }

    // Test deposit with receiver = address(0)
    function testDepositToZeroAddress() public {
        uint256 beforeBalance = IERC20(peggedToken).balanceOf(user1);

        // Attempt deposit with zero address as receiver
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, address(0), 0);

        // Verify no tokens were transferred
        assertEq(
            IERC20(peggedToken).balanceOf(user1),
            beforeBalance,
            "User's pegged token balance should remain unchanged"
        );

        assertEq(IERC20(stabilityPoolCollateral).balanceOf(address(0)), 0, "Zero address should have no tokens");
    }

    // Test withdraw with receiver = address(0)
    function testWithdrawToZeroAddress() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Attempt withdraw with zero address as receiver
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, address(0), 0);

        // Verify balances remain unchanged
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            DEPOSIT_AMOUNT,
            "User's LP token balance should remain unchanged"
        );

        assertEq(IERC20(peggedToken).balanceOf(address(0)), 0, "Zero address should have no tokens");
    }

    // Test accumulating rewards with zero amount
    function testAccumulateRewardZeroAmount() public {
        // Setup: Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Try to accumulate zero rewards
        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), 0);

        // Verify zero rewards were accumulated
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(address(rewardToken)))[0],
            0,
            "No rewards should be accumulated"
        );
    }

    // Test withdrawing entire balance using exact amount
    // A request naming the exact whole balance (the non-sentinel branch, as opposed to `type(uint256).max`) is capped
    // the same way: the sole holder is paid their balance less the retained floor, which the pool never releases.
    function testWithdrawExactBalanceIsCappedAtTheFloor() public {
        uint256 floor = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        uint256 exactBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(exactBalance, user1, 0);

        assertEq(withdrawn, exactBalance - floor, "an exact-balance request is capped at the headroom above the floor");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), floor, "the retained floor is still the holder's");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "the floor is retained, never drained to 0");
    }

    // Test totalAssetSupplyHistory with invalid index
    function testtotalAssetSupplyHistoryInvalidIndex() public view {
        // Get total supply history with invalid index
        (uint40 atDay, uint256 amount) = IStabilityPool(stabilityPoolCollateral).totalAssetSupplyHistory(999);

        // Should return zeros for invalid index
        assertEq(uint256(atDay), 0, "Timestamp should be 0 for invalid index");
        assertEq(amount, 0, "Amount should be 0 for invalid index");
    }

    // Test multiple balance updates in one block
    function testMultipleBalanceUpdatesOneBlock() public {
        // Initial deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // In the same block: deposit more, withdraw some, transfer some
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        // Check final balances
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            DEPOSIT_AMOUNT + DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2,
            "User1 balance should reflect all operations"
        );
    }

    // Test contract initialization with invalid parameters
    function testReinitializeContract() public {
        // Try to initialize again (contract is already initialized)
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StabilityPool_v3(stabilityPoolCollateral).initialize(address(this), owner(), EARLY_WITHDRAWAL_FEE, FEE_ADDRESS);
    }
}
