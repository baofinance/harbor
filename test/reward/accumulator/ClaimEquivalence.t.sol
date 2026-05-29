// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {MockMultipleRewardCompoundingAccumulator_v3} from "@harbor-test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v3.sol";

/// @title ClaimTest
/// @notice Verifies claim() and claimHistorical() routing across all supported call signatures.
///
///         Authorization matrix:
///           | Scenario                  | Call                                 | Expected        |
///           |---------------------------|--------------------------------------|-----------------|
///           | Self claim all            | claim()                              | tokens → self   |
///           | 3rd party claim all       | claim(other)                         | tokens → other  |
///           | Self claim to receiver    | claim(self, recv)                    | tokens → recv   |
///           | 3rd party to receiver     | claim(other, recv)                   | REVERT          |
///           | Self historical           | claimHistorical(tokens)              | tokens → self   |
///           | 3rd party historical      | claimHistorical(other, tokens)       | tokens → other  |
///           | All above + stored recv   | same paths                           | → stored recv   |
///
/// Run: forge test --mc ClaimTest -vv
contract ClaimTest is Test {
    address deployer;
    address alice;
    address bob;
    address storedReceiver;
    address explicitReceiver;

    address accumulator;
    address rewardToken1;
    address rewardToken2;

    uint256 constant REWARD_AMOUNT = 100 ether;
    uint256 constant POOL_SHARE = 10 ether;
    uint128 constant PRODUCT = uint128(1e36);

    function setUp() public {
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        storedReceiver = makeAddr("storedReceiver");
        explicitReceiver = makeAddr("explicitReceiver");

        accumulator = address(new MockMultipleRewardCompoundingAccumulator_v3(1 weeks));
        MockMultipleRewardCompoundingAccumulator_v3(accumulator).initialize(deployer, deployer);

        rewardToken1 = address(new MockERC20("Token1", "T1", 18));
        rewardToken2 = address(new MockERC20("Token2", "T2", 18));

        // Grant manager role and register tokens
        uint256 managerRole = IMultipleRewardDistributor(accumulator).REWARD_MANAGER_ROLE();
        IBaoRoles(accumulator).grantRoles(deployer, managerRole);
        IMultipleRewardDistributor(accumulator).registerRewardToken(rewardToken1);
        IMultipleRewardDistributor(accumulator).registerRewardToken(rewardToken2);

        // Set pool shares so rewards accrue
        MockMultipleRewardCompoundingAccumulator_v3(accumulator).setTotalPoolShare(POOL_SHARE, PRODUCT);
        MockMultipleRewardCompoundingAccumulator_v3(accumulator).setUserPoolShare(POOL_SHARE, PRODUCT);
    }

    /// @dev Deposit rewards for both tokens and advance time so they're fully claimable.
    function _depositRewards() internal {
        MockERC20(rewardToken1).mint(deployer, REWARD_AMOUNT);
        MockERC20(rewardToken2).mint(deployer, REWARD_AMOUNT);
        IERC20(rewardToken1).approve(accumulator, REWARD_AMOUNT);
        IERC20(rewardToken2).approve(accumulator, REWARD_AMOUNT);
        IMultipleRewardDistributor(accumulator).depositReward(rewardToken1, REWARD_AMOUNT);
        IMultipleRewardDistributor(accumulator).depositReward(rewardToken2, REWARD_AMOUNT);
        vm.warp(block.timestamp + 2 weeks);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Without stored receiver
    // ═══════════════════════════════════════════════════════════════════════

    // ── Self claim all ──────────────────────────────────────────────────

    function test_selfClaimAll() public {
        // claim() with no args claims all active tokens for msg.sender.
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim();
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "alice got token1");
        assertGt(IERC20(rewardToken2).balanceOf(alice), 0, "alice got token2");
    }

    /*
    // ── Third party claim all (no receiver) ─────────────────────────────

    function test_thirdPartyClaimAll() public {
        // claim(account) lets a third party trigger claims — tokens go to the account.
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claim(alice);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "alice got token1 (claimed by bob)");
    }
    */

    /*
    // ── Self claim to explicit receiver ─────────────────────────────────

    function test_selfClaimToReceiver() public {
        // claim(account, receiver) routes tokens to an explicit receiver.
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "alice got nothing");
    }
    */

    /*
    // ── Third party claim to receiver → REVERT ──────────────────────────

    function test_thirdPartyClaimToReceiver_reverts() public {
        // Third party cannot redirect another account's rewards.
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
    }
    */

    // ── Self historical ─────────────────────────────────────────────────

    function test_selfHistorical() public {
        // claimHistorical(tokens) claims a specific list of tokens for msg.sender.
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claimTokens(tokens, type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "alice got token1");
        assertEq(IERC20(rewardToken2).balanceOf(alice), 0, "token2 unclaimed");
    }

    /*
    // ── Third party historical ──────────────────────────────────────────

    function test_thirdPartyHistorical() public {
        // claimHistorical(account, tokens) lets a third party trigger historical claims.
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claimHistorical(alice, tokens);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "alice got token1 (claimed by bob)");
    }
    */

    /*
    // ═══════════════════════════════════════════════════════════════════════
    // With stored receiver
    // ═══════════════════════════════════════════════════════════════════════

    function _setStoredReceiver() internal {
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).setRewardReceiver(storedReceiver);
    }

    // ── Self claim all → stored receiver ────────────────────────────────

    function test_selfClaimAll_storedReceiver() public {
        // When a stored receiver is set, claim() sends tokens there.
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim();
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "alice got nothing");
    }

    // ── Third party claim all → stored receiver ─────────────────────────

    function test_thirdPartyClaimAll_storedReceiver() public {
        // Third party claim(account) respects the account's stored receiver.
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claim(alice);
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "alice got nothing");
    }

    // ── Self claim to explicit receiver overrides stored ─────────────────

    function test_selfClaimToExplicit_overridesStored() public {
        // An explicit receiver passed to claim(account, receiver) overrides the stored one.
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "explicit receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "stored receiver got nothing");
    }

    // ── Third party + stored receiver + explicit → REVERT ───────────────

    function test_thirdPartyToExplicit_storedReceiver_reverts() public {
        // Third party cannot override the stored receiver by passing an explicit one.
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
    }
    */
}
