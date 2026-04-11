// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "src/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {MockMultipleRewardCompoundingAccumulator_v3} from "test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v3.sol";

/// @title ClaimEquivalenceTest
/// @notice Verifies that the v3 unified claim interface produces identical outcomes
///         to the legacy claim/claimHistorical wrappers it replaced.
///
///         Authorization matrix tested:
///           | Scenario                  | Legacy path                          | V3 equivalent                              | Expected        |
///           |---------------------------|--------------------------------------|--------------------------------------------|-----------------|
///           | Self claim all            | claim()                              | claim(self, 0, 0, max)                     | tokens → self   |
///           | 3rd party claim all       | claim(other)                         | claim(other, 0, 0, max)                    | tokens → other  |
///           | Self claim to receiver    | claim(self, recv)                    | claim(self, recv, 0, max)                  | tokens → recv   |
///           | 3rd party to receiver     | claim(other, recv)                   | claim(other, recv, 0, max)                 | REVERT          |
///           | Self historical           | claimHistorical(tokens)              | claim(self, 0, tokens, max)                | tokens → self   |
///           | 3rd party historical      | claimHistorical(other, tokens)       | claim(other, 0, tokens, max)               | tokens → other  |
///           | All above + stored recv   | same paths                           | same paths                                 | → stored recv   |
///
/// Run: forge test --mc ClaimEquivalenceTest -vv
contract ClaimEquivalenceTest is Test {
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
        MockMultipleRewardCompoundingAccumulator_v3(accumulator).initialize(deployer);

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

    function _claimableTotal(address account) internal view returns (uint256) {
        return
            IMultipleRewardAccumulator(accumulator).claimable(account, rewardToken1) +
            IMultipleRewardAccumulator(accumulator).claimable(account, rewardToken2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Without stored receiver
    // ═══════════════════════════════════════════════════════════════════════

    // ── Self claim all ──────────────────────────────────────────────────

    function test_selfClaimAll_legacy() public {
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim();
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got token1");
        assertGt(IERC20(rewardToken2).balanceOf(alice), 0, "legacy: alice got token2");
    }

    function test_selfClaimAll_v3() public {
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got token1");
        assertGt(IERC20(rewardToken2).balanceOf(alice), 0, "v3: alice got token2");
    }

    function test_selfClaimAll_equivalent() public {
        // Run legacy path, snapshot balances
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim();
        uint256 legacyBal1 = IERC20(rewardToken1).balanceOf(alice);
        uint256 legacyBal2 = IERC20(rewardToken2).balanceOf(alice);

        // Reset: redeploy
        setUp();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertEq(IERC20(rewardToken1).balanceOf(alice), legacyBal1, "token1 equivalent");
        assertEq(IERC20(rewardToken2).balanceOf(alice), legacyBal2, "token2 equivalent");
    }

    // ── Third party claim all (no receiver) ─────────────────────────────

    function test_thirdPartyClaimAll_legacy() public {
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claim(alice);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got token1 (claimed by bob)");
    }

    function test_thirdPartyClaimAll_v3() public {
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got token1 (claimed by bob)");
    }

    function test_thirdPartyClaimAll_equivalent() public {
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claim(alice);
        uint256 legacyBal1 = IERC20(rewardToken1).balanceOf(alice);

        setUp();
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertEq(IERC20(rewardToken1).balanceOf(alice), legacyBal1, "equivalent");
    }

    // ── Self claim to explicit receiver ─────────────────────────────────

    function test_selfClaimToReceiver_legacy() public {
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "legacy: receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got nothing");
    }

    function test_selfClaimToReceiver_v3() public {
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, explicitReceiver, address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "v3: receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got nothing");
    }

    // ── Third party claim to receiver → REVERT ──────────────────────────

    function test_thirdPartyClaimToReceiver_legacy_reverts() public {
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
    }

    function test_thirdPartyClaimToReceiver_v3_reverts() public {
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, explicitReceiver, address(0), type(uint256).max);
    }

    // ── Self historical ─────────────────────────────────────────────────

    function test_selfHistorical_legacy() public {
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claimHistorical(tokens);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got token1");
        assertEq(IERC20(rewardToken2).balanceOf(alice), 0, "legacy: token2 unclaimed");
    }

    function test_selfHistorical_v3() public {
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), tokens, type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got token1");
        assertEq(IERC20(rewardToken2).balanceOf(alice), 0, "v3: token2 unclaimed");
    }

    // ── Third party historical ──────────────────────────────────────────

    function test_thirdPartyHistorical_legacy() public {
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claimHistorical(alice, tokens);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got token1 (claimed by bob)");
    }

    function test_thirdPartyHistorical_v3() public {
        _depositRewards();
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken1;
        vm.prank(bob);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), tokens, type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got token1 (claimed by bob)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // With stored receiver
    // ═══════════════════════════════════════════════════════════════════════

    function _setStoredReceiver() internal {
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).setRewardReceiver(storedReceiver);
    }

    // ── Self claim all → stored receiver ────────────────────────────────

    function test_selfClaimAll_storedReceiver_legacy() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim();
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "legacy: stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got nothing");
    }

    function test_selfClaimAll_storedReceiver_v3() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "v3: stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got nothing");
    }

    // ── Third party claim all → stored receiver ─────────────────────────

    function test_thirdPartyClaimAll_storedReceiver_legacy() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator(accumulator).claim(alice);
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "legacy: stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "legacy: alice got nothing");
    }

    function test_thirdPartyClaimAll_storedReceiver_v3() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "v3: stored receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(alice), 0, "v3: alice got nothing");
    }

    // ── Self claim to explicit receiver overrides stored ─────────────────

    function test_selfClaimToExplicit_overridesStored_legacy() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "legacy: explicit receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "legacy: stored receiver got nothing");
    }

    function test_selfClaimToExplicit_overridesStored_v3() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, explicitReceiver, address(0), type(uint256).max);
        assertGt(IERC20(rewardToken1).balanceOf(explicitReceiver), 0, "v3: explicit receiver got token1");
        assertEq(IERC20(rewardToken1).balanceOf(storedReceiver), 0, "v3: stored receiver got nothing");
    }

    // ── Third party + stored receiver + explicit → REVERT ───────────────

    function test_thirdPartyToExplicit_storedReceiver_legacy_reverts() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator(accumulator).claim(alice, explicitReceiver);
    }

    function test_thirdPartyToExplicit_storedReceiver_v3_reverts() public {
        _setStoredReceiver();
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, explicitReceiver, address(0), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V3-specific: fractional claim (no legacy equivalent)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fractionalClaim_leavesRemainder() public {
        _depositRewards();
        uint256 total = IMultipleRewardAccumulator(accumulator).claimable(alice, rewardToken1);
        uint256 half = total / 2;

        vm.prank(alice);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), rewardToken1, half);

        assertEq(IERC20(rewardToken1).balanceOf(alice), half, "got half");
        assertGt(
            IMultipleRewardAccumulator(accumulator).claimable(alice, rewardToken1),
            0,
            "remainder still claimable"
        );
    }

    function test_fractionalClaim_thirdParty_leavesRemainder() public {
        _depositRewards();
        uint256 total = IMultipleRewardAccumulator(accumulator).claimable(alice, rewardToken1);
        uint256 half = total / 2;

        // Bob claims half of alice's rewards (receiver=0 → goes to alice)
        vm.prank(bob);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, address(0), rewardToken1, half);

        assertEq(IERC20(rewardToken1).balanceOf(alice), half, "alice got half");
        assertEq(IERC20(rewardToken1).balanceOf(bob), 0, "bob got nothing");
        assertGt(
            IMultipleRewardAccumulator(accumulator).claimable(alice, rewardToken1),
            0,
            "remainder still claimable"
        );
    }

    function test_fractionalClaim_thirdParty_toExplicitReceiver_reverts() public {
        _depositRewards();
        vm.prank(bob);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator_v3(accumulator).claim(alice, explicitReceiver, rewardToken1, 1 ether);
    }
}
