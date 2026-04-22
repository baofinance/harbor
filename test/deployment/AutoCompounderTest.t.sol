// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IAutoCompounder} from "@harbor/interfaces/IAutoCompounder.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {AutoCompounder_v1} from "@harbor/autocompounding/AutoCompounder_v1.sol";
import {DeployEURSetUp} from "@harbor-test/deployment/DeployEURSetUp.t.sol";
import {PermitTestBase} from "@bao-test/helpers/PermitTestBase.t.sol";

/// @title AutoCompounder tests using EUR peg (fxUSD + stETH collateral).
/// Run: forge test --mc AutoCompounderTest --fork-url mainnet -vv
contract AutoCompounderTest is DeployEURSetUp, PermitTestBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _permitTarget() internal view override returns (address) {
        return acCollFxUSD;
    }

    // ── Deployment verification ────────────────────────────────────────

    function test_deployment_immutables() public view {
        assertEq(AutoCompounder_v1(acCollFxUSD).STABILITY_POOL(), spCollFxUSD);
        assertEq(AutoCompounder_v1(acCollFxUSD).MINTER(), minterFxUSD);
        assertEq(AutoCompounder_v1(acCollFxUSD).WRAPPED_COLLATERAL(), wrappedCollateralFxUSD);
        assertEq(AutoCompounder_v1(acCollFxUSD).PEGGED_TOKEN(), pegged);

        assertEq(AutoCompounder_v1(acCollStETH).STABILITY_POOL(), spCollStETH);
        assertEq(AutoCompounder_v1(acCollStETH).MINTER(), minterStETH);
        assertEq(AutoCompounder_v1(acCollStETH).WRAPPED_COLLATERAL(), wrappedCollateralStETH);
        assertEq(AutoCompounder_v1(acCollStETH).PEGGED_TOKEN(), pegged);
    }

    function test_deployment_metadata() public view {
        assertGt(bytes(IERC4626(acCollFxUSD).name()).length, 0, "fxUSD AC name");
        assertGt(bytes(IERC4626(acCollFxUSD).symbol()).length, 0, "fxUSD AC symbol");
        assertEq(IERC4626(acCollFxUSD).decimals(), 18);

        assertGt(bytes(IERC4626(acCollStETH).name()).length, 0, "stETH AC name");
        assertGt(bytes(IERC4626(acCollStETH).symbol()).length, 0, "stETH AC symbol");
        assertEq(IERC4626(acCollStETH).decimals(), 18);
    }

    function test_deployment_mintMaxFeeRatio() public view {
        assertEq(AutoCompounder_v1(acCollFxUSD).mintMaxFeeRatio(), 0.05 ether, "fxUSD AC mintMaxFeeRatio");
        assertEq(AutoCompounder_v1(acCollStETH).mintMaxFeeRatio(), 0.05 ether, "stETH AC mintMaxFeeRatio");
    }

    function test_deployment_asset() public view {
        assertEq(IERC4626(acCollFxUSD).asset(), spCollFxUSD, "fxUSD AC asset is SP");
        assertEq(IERC4626(acCollStETH).asset(), spCollStETH, "stETH AC asset is SP");
    }

    // ── Deposit / Withdraw round-trip ──────────────────────────────────

    function test_depositWithdraw_roundTrip() public {
        // Alice deposits pegged -> SP -> gets SP tokens -> deposits to AC
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 10 ether);
        uint256 spBalance = IERC20(spCollFxUSD).balanceOf(alice);
        assertGt(spBalance, 0, "alice has SP tokens");

        // Approve AC and deposit SP tokens
        vm.startPrank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalance);
        uint256 shares = IERC4626(acCollFxUSD).deposit(spBalance, alice);
        vm.stopPrank();

        assertGt(shares, 0, "alice got AC shares");
        assertEq(IERC20(spCollFxUSD).balanceOf(alice), 0, "SP tokens moved to AC");
        assertEq(IERC4626(acCollFxUSD).balanceOf(alice), shares, "AC shares in alice's balance");

        // Redeem all AC shares -> get SP tokens back
        vm.prank(alice);
        uint256 spReturned = IERC4626(acCollFxUSD).redeem(shares, alice, alice);

        assertEq(spReturned, spBalance, "got same SP tokens back");
        assertEq(IERC4626(acCollFxUSD).balanceOf(alice), 0, "no AC shares left");
        assertEq(IERC20(spCollFxUSD).balanceOf(alice), spBalance, "SP tokens returned");
    }

    // ── depositPeggedToken ─────────────────────────────────────────────

    function test_depositPeggedToken() public {
        uint256 peggedAmount = 10 ether;
        _mintPegged(minterFxUSD, alice, peggedAmount);

        vm.startPrank(alice);
        IERC20(pegged).approve(acCollFxUSD, peggedAmount);
        uint256 shares = IAutoCompounder(acCollFxUSD).depositPeggedToken(peggedAmount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "alice got AC shares");
        assertEq(IERC20(pegged).balanceOf(alice), 0, "pegged tokens consumed");
        assertGt(IERC4626(acCollFxUSD).totalAssets(), 0, "AC has assets");
    }

    function test_depositPeggedToken_equivalentToDeposit() public {
        uint256 amount = 10 ether;

        // Alice deposits via depositPeggedToken (pegged -> SP -> AC in one call)
        _mintPegged(minterFxUSD, alice, amount);
        vm.startPrank(alice);
        IERC20(pegged).approve(acCollFxUSD, amount);
        uint256 sharesPegged = IAutoCompounder(acCollFxUSD).depositPeggedToken(amount, alice);
        vm.stopPrank();

        // Bob deposits via deposit (pegged -> SP manually, then SP tokens -> AC)
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, bob, amount);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(bob);
        vm.startPrank(bob);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        uint256 sharesDeposit = IERC4626(acCollFxUSD).deposit(spBal, bob);
        vm.stopPrank();

        // Same collateral amount should produce same shares (second depositor buys at same rate)
        assertEq(sharesPegged, sharesDeposit, "depositPeggedToken and deposit produce equal shares");

        // Both should redeem to the same SP token amount
        uint256 redeemAlice = IERC4626(acCollFxUSD).previewRedeem(sharesPegged);
        uint256 redeemBob = IERC4626(acCollFxUSD).previewRedeem(sharesDeposit);
        assertEq(redeemAlice, redeemBob, "equal redemption value");
    }

    function test_depositPeggedToken_doesNotAffectExistingUsers() public {
        // Charlie is an existing depositor
        address charlie = makeAddr("charlie");
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, charlie, 50 ether);
        uint256 spBalCharlie = IERC20(spCollFxUSD).balanceOf(charlie);
        vm.prank(charlie);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalCharlie);
        vm.prank(charlie);
        IERC4626(acCollFxUSD).deposit(spBalCharlie, charlie);

        uint256 charlieRedeemBefore = IERC4626(acCollFxUSD).previewRedeem(IERC4626(acCollFxUSD).balanceOf(charlie));

        // Alice enters via depositPeggedToken
        _mintPegged(minterFxUSD, alice, 10 ether);
        vm.startPrank(alice);
        IERC20(pegged).approve(acCollFxUSD, 10 ether);
        IAutoCompounder(acCollFxUSD).depositPeggedToken(10 ether, alice);
        vm.stopPrank();

        uint256 charlieRedeemAfterPegged = IERC4626(acCollFxUSD).previewRedeem(
            IERC4626(acCollFxUSD).balanceOf(charlie)
        );

        // Bob enters via deposit (SP tokens)
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, bob, 10 ether);
        uint256 spBalBob = IERC20(spCollFxUSD).balanceOf(bob);
        vm.prank(bob);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalBob);
        vm.prank(bob);
        IERC4626(acCollFxUSD).deposit(spBalBob, bob);

        uint256 charlieRedeemAfterBoth = IERC4626(acCollFxUSD).previewRedeem(IERC4626(acCollFxUSD).balanceOf(charlie));

        // Charlie's redemption value should be unchanged by either deposit path
        assertEq(charlieRedeemAfterPegged, charlieRedeemBefore, "depositPeggedToken did not dilute charlie");
        assertEq(charlieRedeemAfterBoth, charlieRedeemBefore, "deposit did not dilute charlie");
    }

    function test_depositPeggedToken_maxAmount() public {
        uint256 peggedAmount = 10 ether;
        _mintPegged(minterFxUSD, alice, peggedAmount);

        vm.startPrank(alice);
        IERC20(pegged).approve(acCollFxUSD, type(uint256).max);
        uint256 shares = IAutoCompounder(acCollFxUSD).depositPeggedToken(type(uint256).max, alice);
        vm.stopPrank();

        assertGt(shares, 0, "alice got AC shares");
        assertEq(IERC20(pegged).balanceOf(alice), 0, "all pegged tokens consumed");
    }

    // ── Compound: full mint ────────────────────────────────────────────

    function test_compound_fullMint() public {
        // Setup: healthy CR via leveraged tokens, so minting pegged during compound has low fee
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        IERC4626(acCollFxUSD).deposit(spBal, alice);
        vm.stopPrank();

        uint256 totalAssetsBefore = IERC4626(acCollFxUSD).totalAssets();

        // Deposit small reward (0.5% of pool - keeps CR impact minimal)
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 5 ether);
        skip(2 weeks); // let rewards fully accrue

        // Verify claimable exists
        uint256 claimable = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertGt(claimable, 0, "AC has claimable rewards");

        // totalAssets should include claimable value
        uint256 totalAssetsWithRewards = IERC4626(acCollFxUSD).totalAssets();
        assertGt(totalAssetsWithRewards, totalAssetsBefore, "totalAssets includes claimable");

        // Compound - anyone can call
        vm.prank(bob);
        IAutoCompounder(acCollFxUSD).compound();

        // After compound: all claimable consumed, SP position grew
        uint256 claimableAfter = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertEq(claimableAfter, 0, "all rewards claimed");
        uint256 totalAssetsAfter = IERC4626(acCollFxUSD).totalAssets();
        // totalAssets preserved (claimable converted to SP position, minus small minting fee)
        assertApproxEqRel(totalAssetsAfter, totalAssetsWithRewards, 0.05 ether, "totalAssets preserved");
    }

    // ── Compound: fee too high -> claims but does not mint ──────────────

    function test_compound_feeTooHigh_claimsButDoesNotMint() public {
        // Setup: healthy CR
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        IERC4626(acCollFxUSD).deposit(spBal, alice);
        vm.stopPrank();

        // Deposit rewards
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 5 ether);
        skip(2 weeks);

        // Push Minter fees above MAX_FEE_RATIO.
        // Minter config requires a disallow sentinel (1e18) at index 0 (depeg band). The test market's CR (~200%)
        // is below the band upper bound (1000%), so incentiveRatios[0] = 1e18 (disallow) applies.
        // 1e18 fee >> MAX_FEE_RATIO (0.05e18) → mintPeggedToken returns (0, 0) → compound() routes as residual.
        IMinter.IncentiveConfig memory highFeeConfig = IMinter.IncentiveConfig({
            collateralRatioBandUpperBounds: new uint256[](1),
            incentiveRatios: new int256[](2)
        });
        highFeeConfig.collateralRatioBandUpperBounds[0] = 10e18; // band upper bound at 1000% CR
        highFeeConfig.incentiveRatios[0] = 1e18; // disallow below band (depeg sentinel, valid at index 0)
        highFeeConfig.incentiveRatios[1] = 0.1e18; // 10% fee above band (unreachable given test CR)

        IMinter.Config memory highFeeFullConfig = IMinter.Config({
            mintPeggedIncentiveConfig: highFeeConfig,
            redeemPeggedIncentiveConfig: IMinter(minterFxUSD).config().redeemPeggedIncentiveConfig,
            mintLeveragedIncentiveConfig: IMinter(minterFxUSD).config().mintLeveragedIncentiveConfig,
            redeemLeveragedIncentiveConfig: IMinter(minterFxUSD).config().redeemLeveragedIncentiveConfig
        });
        vm.prank(HARBOR_MULTISIG);
        IMinter(minterFxUSD).updateConfig(highFeeFullConfig);

        // Track the raw SP token balance (not totalAssets — that includes claimable which drops to 0 after claim())
        uint256 spBalanceBefore = IERC20(spCollFxUSD).balanceOf(acCollFxUSD);

        // Compound should not revert, but should not mint (fee too high → try/catch skips minting)
        IAutoCompounder(acCollFxUSD).compound();

        // SP balance unchanged — no new haXXX deposited to the SP
        uint256 spBalanceAfter = IERC20(spCollFxUSD).balanceOf(acCollFxUSD);
        assertEq(spBalanceAfter, spBalanceBefore, "SP balance unchanged: minting skipped");

        // Claimable is now 0 — claim() always runs in compound()
        uint256 claimableAfter = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertEq(claimableAfter, 0, "all rewards claimed from SP");
    }

    // ── Compound: nothing to compound -> revert ─────────────────────────

    function test_compound_nothingToCompound_reverts() public {
        // Setup: alice deposits, no rewards
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 10 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        IERC4626(acCollFxUSD).deposit(spBal, alice);
        vm.stopPrank();

        vm.expectRevert(AutoCompounder_v1.NothingToCompound.selector);
        IAutoCompounder(acCollFxUSD).compound();
    }

    // ── Share price increases after compound ────────────────────────────

    function test_compound_sharePriceUp() public {
        // Healthy CR, then alice and bob deposit equal amounts
        _mintLeveraged(minterFxUSD, address(this), 200 ether);
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 50 ether);
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, bob, 50 ether);

        uint256 spBalAlice = IERC20(spCollFxUSD).balanceOf(alice);
        uint256 spBalBob = IERC20(spCollFxUSD).balanceOf(bob);

        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalAlice);
        vm.prank(alice);
        uint256 sharesAlice = IERC4626(acCollFxUSD).deposit(spBalAlice, alice);

        vm.prank(bob);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalBob);
        vm.prank(bob);
        uint256 sharesBob = IERC4626(acCollFxUSD).deposit(spBalBob, bob);

        assertEq(sharesAlice, sharesBob, "equal deposits -> equal shares");

        uint256 previewBefore = IERC4626(acCollFxUSD).previewRedeem(sharesAlice);

        // Deposit rewards and compound
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 10 ether);
        skip(2 weeks);
        IAutoCompounder(acCollFxUSD).compound();

        uint256 previewAfter = IERC4626(acCollFxUSD).previewRedeem(sharesAlice);
        assertGt(previewAfter, previewBefore, "share price increased after compound");
    }

    // ── No dilution on deposit when queue non-empty ────────────────────

    function test_noDilution_withPendingRewards() public {
        // Healthy CR, alice deposits first
        _mintLeveraged(minterFxUSD, address(this), 200 ether);
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 50 ether);
        uint256 spBalAlice = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalAlice);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBalAlice, alice);

        // Rewards accrue
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 10 ether);
        skip(2 weeks);

        // Bob deposits AFTER rewards accrued but BEFORE compound
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, bob, 50 ether);
        uint256 spBalBob = IERC20(spCollFxUSD).balanceOf(bob);
        vm.prank(bob);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalBob);
        vm.prank(bob);
        uint256 sharesBob = IERC4626(acCollFxUSD).deposit(spBalBob, bob);

        // Bob should get FEWER shares than alice (alice's shares are worth more due to pending rewards)
        uint256 sharesAlice = IERC4626(acCollFxUSD).balanceOf(alice);
        assertLt(sharesBob, sharesAlice, "bob gets fewer shares - no dilution");
    }

    // ── Two collaterals: independent compounding ───────────────────────

    function test_twoCollaterals_independentCompound() public {
        // Healthy CR for both markets, deposit to both
        _mintLeveraged(minterFxUSD, address(this), 100 ether);
        _mintLeveraged(minterStETH, address(this), 100 ether);
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 50 ether);
        _mintAndDepositToSP(minterStETH, spCollStETH, alice, 50 ether);

        uint256 spBalFx = IERC20(spCollFxUSD).balanceOf(alice);
        uint256 spBalSt = IERC20(spCollStETH).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBalFx);
        IERC4626(acCollFxUSD).deposit(spBalFx, alice);
        IERC20(spCollStETH).approve(acCollStETH, spBalSt);
        IERC4626(acCollStETH).deposit(spBalSt, alice);
        vm.stopPrank();

        // Deposit rewards only to fxUSD SP
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 5 ether);
        skip(2 weeks);

        // Compound fxUSD AC - should succeed
        IAutoCompounder(acCollFxUSD).compound();

        // stETH AC - nothing to compound
        vm.expectRevert(AutoCompounder_v1.NothingToCompound.selector);
        IAutoCompounder(acCollStETH).compound();
    }

    // ── totalAssets consistency ─────────────────────────────────────────

    function test_totalAssets_withClaimable() public {
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBal, alice);

        uint256 totalAssetsBefore = IERC4626(acCollFxUSD).totalAssets();

        // Deposit rewards
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 10 ether);
        skip(2 weeks);

        uint256 totalAssetsAfter = IERC4626(acCollFxUSD).totalAssets();

        // totalAssets should have increased by ~reward amount (at 1:1 price/rate)
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets increased");
        assertApproxEqRel(totalAssetsAfter - totalAssetsBefore, 10 ether, 0.01 ether, "increase ~= reward amount");
    }

    // ── totalAssets zero claimable -> just SP position ──────────────────

    function test_totalAssets_noClaimable() public {
        _mintAndDepositToSP(minterFxUSD, spCollFxUSD, alice, 10 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBal, alice);

        uint256 totalAssets = IERC4626(acCollFxUSD).totalAssets();
        uint256 spPosition = IERC20(spCollFxUSD).balanceOf(acCollFxUSD);
        assertEq(totalAssets, spPosition, "totalAssets == SP position when no claimable");
    }

    // ── Sweep ──────────────────────────────────────────────────────────

    function test_sweep_rescuesStuckTokens() public {
        // Accidentally send some tokens to the AC
        deal(wrappedCollateralFxUSD, acCollFxUSD, 1 ether);

        address sweepReceiver = makeAddr("sweepReceiver");
        vm.prank(HARBOR_MULTISIG);
        AutoCompounder_v1(acCollFxUSD).sweep(wrappedCollateralFxUSD, 1 ether, sweepReceiver);

        assertEq(IERC20(wrappedCollateralFxUSD).balanceOf(sweepReceiver), 1 ether, "swept to receiver");
    }
}

/// @title AutoCompounder tests for alias and liquidation reward paths.
/// @dev Inherits AutoCompounderTest setup; tests reward flows through harvest and liquidation.
///
///      Reward paths for collateral SP:
///        - Harvest:      depositReward(wrappedCollateral, amount) -> linear distribution over period
///        - Rebalance:    notifyLiquidation(liquidated, returned) -> _accumulateReward(wrappedCollateral) -> instant
///        - Both flow through claimable(AC, wrappedCollateral) and are drained by compound()
///
/// Run: forge test --mc AutoCompounderRewardTest --fork-url mainnet -vv
contract AutoCompounderRewardTest is AutoCompounderTest {
    // ── Helpers ────────────────────────────────────────────────────────

    /// @dev Simulate a liquidation on the collateral SP: burns pegged, distributes wCOL as reward.
    function _simulateLiquidation(
        address sp,
        address spm,
        address wCol,
        uint256 peggedLiquidated,
        uint256 collateralReturned
    ) internal {
        deal(wCol, sp, IERC20(wCol).balanceOf(sp) + collateralReturned);
        vm.prank(spm);
        IStabilityPool(sp).notifyLiquidation(peggedLiquidated, collateralReturned);
    }

    // ── Compound via depositReward ────────────────────────────────────

    function test_compound_viaDepositReward() public {
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBal, alice);

        uint256 totalAssetsBefore = IERC4626(acCollFxUSD).totalAssets();

        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 5 ether);
        skip(2 weeks);

        uint256 claimable = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertGt(claimable, 0, "AC has claimable");

        IAutoCompounder(acCollFxUSD).compound();

        uint256 claimableAfter = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertEq(claimableAfter, 0, "all rewards claimed");
        assertGt(IERC4626(acCollFxUSD).totalAssets(), totalAssetsBefore, "totalAssets grew");
    }

    // ── Compound via liquidation (notifyLiquidation -> _accumulateReward) ──

    function test_compound_viaLiquidation() public {
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBal, alice);

        uint256 totalAssetsBefore = IERC4626(acCollFxUSD).totalAssets();

        // Simulate liquidation: burn 10 pegged, return 10 wrappedCollateral (instant, not linear)
        _simulateLiquidation(spCollFxUSD, spmFxUSD, wrappedCollateralFxUSD, 10 ether, 10 ether);

        // Claimable should be available immediately (no skip needed)
        uint256 claimable = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertGt(claimable, 0, "AC has claimable from liquidation");

        // totalAssets reflects the claimable (minus the pegged loss from liquidation)
        // The SP position dropped by ~10 ether (loss), but gained ~10 ether claimable wCOLn
        // At price=1, rate=1 these roughly cancel out
        uint256 totalAssetsAfterLiq = IERC4626(acCollFxUSD).totalAssets();
        assertApproxEqRel(
            totalAssetsAfterLiq,
            totalAssetsBefore,
            0.01 ether,
            "totalAssets roughly preserved through liquidation"
        );

        IAutoCompounder(acCollFxUSD).compound();

        uint256 claimableAfter = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertEq(claimableAfter, 0, "liquidation rewards compounded");
    }

    // ── Compound: harvest + liquidation combined ───────────────────────

    function test_compound_harvestPlusLiquidation() public {
        _setupHealthyMarket(minterFxUSD, spCollFxUSD, alice, 100 ether, 100 ether);
        uint256 spBal = IERC20(spCollFxUSD).balanceOf(alice);
        vm.prank(alice);
        IERC20(spCollFxUSD).approve(acCollFxUSD, spBal);
        vm.prank(alice);
        IERC4626(acCollFxUSD).deposit(spBal, alice);

        // Harvest reward (linear)
        _depositReward(spCollFxUSD, wrappedCollateralFxUSD, wrappedCollateralFxUSD, 3 ether);
        skip(2 weeks);

        // Liquidation reward (instant)
        _simulateLiquidation(spCollFxUSD, spmFxUSD, wrappedCollateralFxUSD, 5 ether, 5 ether);

        // Both should be claimable
        uint256 claimable = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertGt(claimable, 3 ether, "claimable includes harvest + liquidation");

        // Single compound drains everything
        IAutoCompounder(acCollFxUSD).compound();

        uint256 claimableAfter = IMultipleRewardAccumulator(spCollFxUSD).claimable(acCollFxUSD, wrappedCollateralFxUSD);
        assertEq(claimableAfter, 0, "single compound drained all reward sources");
    }
}
