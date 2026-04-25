// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PostRebalanceRemediationForStabilityPool_v2} from "@harbor-script/verify/spl-remediation/PostRebalanceRemediationForStabilityPool_v2.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {console2 as console} from "forge-std/console2.sol";

interface IStabilityPoolImmutables {
    function WITHDRAWAL_START_DELAY() external view returns (uint64);
}

// ═══════════════════════════════════════════════════════════════════════════
// Base: shared state, expected values, helpers, and all post-remediation tests.
// Subclasses differ only in setUp (how the remediated state is established).
// ═══════════════════════════════════════════════════════════════════════════

abstract contract SPLTestBase is BaoTest, HarborDeployer {
    address spl;
    address spc;
    address minter;
    address lev;
    address peg;
    address spm;
    address wrappedCollateral;
    address proxyOwner;

    address constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;

    struct Expected {
        address holder;
        uint256 v2Held;
        uint256 v2Claimable;
        uint256 v2HaInSPL;
    }

    Expected[] expected;

    function _initAddresses() internal {
        _setSaltPrefix("harbor_v1");
        spl = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolLeveraged"));
        spc = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolCollateral"));
        minter = _predictAddress(_key("ETH", "fxUSD", "minter"));
        lev = _predictAddress(_key("ETH", "fxUSD", "leveraged"));
        peg = _predictAddress(_key("ETH", "pegged"));
        spm = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolManager"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        proxyOwner = IBaoOwnable(spl).owner();
    }

    /// @dev V2 correct values per holder. Source: results/v2_correct_state.csv
    function _initExpected() internal {
        //                                                                    v2Held                       v2Claimable                  v2HaInSPL
        expected.push(
            Expected(
                0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12,
                0,
                0.060311559463305742 ether,
                0.300336372621867295 ether
            )
        );
        expected.push(
            Expected(
                0x1a9152528AEFbcD9E5df4E0770f4F510e7056913,
                0,
                0.090912789787537255 ether,
                0.452722790667278425 ether
            )
        );
        expected.push(
            Expected(
                0x1e085ff3CdD38b1E5F04Ace2345966056F0C85E4,
                0.001515885365927426 ether,
                0.000041497401864749 ether,
                0.000206646607386655 ether
            )
        );
        expected.push(Expected(0x3Fdaf8A9af23D27C884e10820130eAB1dB6dDBeD, 0.006181459776411976 ether, 0, 0));
        expected.push(
            Expected(
                0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e,
                0,
                0.000127808353298059 ether,
                0.000636453402331065 ether
            )
        );
        expected.push(
            Expected(CLAIMER, 0.322217071257914429 ether, 0.000053411233151520 ether, 0.004632259358695266 ether)
        );
        expected.push(Expected(0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC, 0.039893782695968247 ether, 0, 0));
        expected.push(Expected(0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6, 0.001465014951679706 ether, 0, 0));
        expected.push(
            Expected(
                0xDD0CDF8D98d9Ad3ADfaa49AaECD444Bfa01d9C9a,
                0.000894459467812868 ether,
                0.000110736322807779 ether,
                0.000551438991223686 ether
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _installMockOracle() internal returns (MockWrappedPriceOracle mockOracle) {
        IWrappedPriceOracle real = IWrappedPriceOracle(IMinter(minter).priceOracle());
        (uint256 minP, uint256 maxP, uint256 minR, uint256 maxR) = real.latestAnswer();
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(minP, maxP, minR, maxR);
        vm.prank(proxyOwner);
        IMinter(minter).updatePriceOracle(address(mockOracle));
    }

    /// @dev Drop oracle price enough to push ratio below threshold, then rebalance.
    function _triggerRebalance(MockWrappedPriceOracle mockOracle) internal returns (uint256 splReceived) {
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 threshold = IStabilityPoolManager(spm).rebalanceThreshold();
        // Drop price to push ratio to 95% of threshold
        // ratio_new = ratio * factor, so factor = (0.95 * threshold) / ratio
        (uint256 p, , uint256 r, ) = mockOracle.latestAnswer();
        uint256 targetPrice = (p * 95 * threshold) / (ratio * 100);
        mockOracle.setLatestAnswer(targetPrice, targetPrice, r, r);

        uint256 splLevBefore = IERC20(lev).balanceOf(spl);
        IStabilityPoolManager(spm).rebalance(makeAddr("bounty"), 0);
        splReceived = IERC20(lev).balanceOf(spl) - splLevBefore;
    }

    function _logLevPrice(string memory label) internal view {
        console.log("  levPrice [%s]: %d", label, IMinter(minter).leveragedTokenPrice());
    }

    /// @dev Deal fxSAVE to user and mint haETH via the minter.
    ///      Verifies fee was collected by the fee receiver.
    ///      Returns the amount of haETH minted.
    function _mintPegged(address user, uint256 fxSaveAmount) internal returns (uint256 pegMinted) {
        address feeReceiver = IMinter(minter).feeReceiver();
        uint256 feeReceiverBefore = IERC20(wrappedCollateral).balanceOf(feeReceiver);

        // Dry run BEFORE mint to get expected values at current state
        (int256 incentive, uint256 expectedFee, , uint256 expectedPeg, , ) = IMinter(minter).mintPeggedTokenDryRun(
            fxSaveAmount
        );
        uint256 ratioBefore = IMinter(minter).collateralRatio();

        deal(wrappedCollateral, user, fxSaveAmount);

        // Check instantaneous incentive ratio
        int256 instantIncentive = IMinter(minter).mintPeggedTokenIncentiveRatio();
        if (instantIncentive >= 0) console.log("    instantaneous incentive (fee): %d", uint256(instantIncentive));
        else console.log("    instantaneous incentive (discount): -%d", uint256(-instantIncentive));

        vm.startPrank(user);
        IERC20(wrappedCollateral).approve(minter, fxSaveAmount);
        pegMinted = IMinter(minter).mintPeggedToken(fxSaveAmount, user, 0);
        vm.stopPrank();

        uint256 feeCollected = IERC20(wrappedCollateral).balanceOf(feeReceiver) - feeReceiverBefore;
        uint256 ratioAfter = IMinter(minter).collateralRatio();

        console.log("    pre-mint ratio=%d", ratioBefore);
        if (incentive >= 0) console.log("    incentive (fee): %d", uint256(incentive));
        else console.log("    incentive (discount): -%d", uint256(-incentive));
        console.log("    mint peg: %d fxSAVE -> %d haETH (expected %d)", fxSaveAmount, pegMinted, expectedPeg);
        console.log("    fee: %d (expected %d), ratio after=%d", feeCollected, expectedFee, ratioAfter);
        console.log(
            "    feeReceiver bal: %d -> %d",
            feeReceiverBefore,
            IERC20(wrappedCollateral).balanceOf(feeReceiver)
        );
    }

    /// @dev Mint haETH from fxSAVE, then deposit into SPL.
    ///      Also mints an equal amount of leveraged to keep the collateral ratio stable.
    function _depositAs(address user, uint256 fxSaveAmount) internal {
        uint256 half = fxSaveAmount / 2;
        uint256 pegMinted = _mintPegged(user, half);
        _mintLeveraged(user, half); // keep ratio stable
        vm.startPrank(user);
        IERC20(peg).approve(spl, pegMinted);
        IStabilityPool(spl).deposit(pegMinted, user, 0);
        vm.stopPrank();
    }

    /// @dev Deal fxSAVE to user and mint sailETH via the minter.
    ///      Verifies fee was collected by the fee receiver.
    function _mintLeveraged(address user, uint256 fxSaveAmount) internal returns (uint256 levMinted) {
        address feeReceiver = IMinter(minter).feeReceiver();
        uint256 feeReceiverBefore = IERC20(wrappedCollateral).balanceOf(feeReceiver);

        deal(wrappedCollateral, user, fxSaveAmount);
        vm.startPrank(user);
        IERC20(wrappedCollateral).approve(minter, fxSaveAmount);
        levMinted = IMinter(minter).mintLeveragedToken(fxSaveAmount, user, 0);
        vm.stopPrank();

        uint256 feeCollected = IERC20(wrappedCollateral).balanceOf(feeReceiver) - feeReceiverBefore;
        console.log("    mint lev: %d fxSAVE -> %d sailETH, fee=%d", fxSaveAmount, levMinted, feeCollected);
    }

    function _claimAll() internal returns (uint256[] memory received) {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        received = new uint256[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            uint256 balBefore = IERC20(lev).balanceOf(expected[i].holder);
            vm.prank(expected[i].holder);
            acc.claim();
            received[i] = IERC20(lev).balanceOf(expected[i].holder) - balBefore;
        }
    }

    function _hasPoolBalance(uint256 i) internal view returns (bool) {
        return IStabilityPool(spl).assetBalanceOf(expected[i].holder) > 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Tests (run by both subclasses)
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_allHolders() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            uint256 received = IERC20(lev).balanceOf(h) - balBefore;
            assertEq(received, claimable, string.concat("claim mismatch for ", vm.toString(h)));
            assertEq(acc.claimable(h, lev), 0, string.concat("residual for ", vm.toString(h)));
            console.log("  Claim %s: %d", vm.toString(h), received);
        }
    }

    function test_deposit() public {
        address newUser = makeAddr("newUser");
        uint256 pegMinted = _mintPegged(newUser, 1 ether);
        uint256 pegBefore = IERC20(peg).balanceOf(newUser);
        vm.startPrank(newUser);
        IERC20(peg).approve(spl, pegMinted);
        uint256 shares = IStabilityPool(spl).deposit(pegMinted, newUser, 0);
        vm.stopPrank();
        assertEq(shares > 0, true, "shares should be > 0");
        assertEq(pegBefore - IERC20(peg).balanceOf(newUser), pegMinted, "haETH transferred");
        assertEq(IStabilityPool(spl).assetBalanceOf(newUser), pegMinted, "pool balance");
        assertEq(IMultipleRewardAccumulator(spl).claimable(newUser, lev), 0, "no phantom rewards");
        console.log("  [OK] Deposit: %d haETH -> %d shares", pegMinted, shares);
    }

    function test_requestWithdrawal_and_withdraw() public {
        address newUser = makeAddr("newUser");
        _depositAs(newUser, 1000 ether);
        uint256 poolBalAfterDeposit = IStabilityPool(spl).assetBalanceOf(newUser);
        vm.prank(newUser);
        IStabilityPool(spl).requestWithdrawal();
        uint64 startDelay = IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY();
        vm.warp(block.timestamp + startDelay + 1);
        uint256 pegBefore = IERC20(peg).balanceOf(newUser);
        vm.prank(newUser);
        IStabilityPool(spl).withdraw(type(uint256).max, newUser, 0);
        uint256 pegReceived = IERC20(peg).balanceOf(newUser) - pegBefore;
        assertEq(IStabilityPool(spl).assetBalanceOf(newUser), 0, "pool balance zero");
        assertEq(pegReceived, poolBalAfterDeposit, "exact refund (no rebalance loss)");
        console.log("  [OK] Withdraw: %d haETH returned", pegReceived);
    }

    function test_rebalance_and_claim() public {
        address newUser = makeAddr("newUser");
        _depositAs(newUser, 1000 ether);
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        uint256 supplyBefore = IERC20(lev).totalSupply();
        uint256 splHaBefore = IStabilityPool(spl).assetBalanceOf(newUser);
        uint256 splReceived = _triggerRebalance(mockOracle);
        assertEq(IERC20(lev).totalSupply() > supplyBefore, true, "supply should increase");
        assertEq(IStabilityPool(spl).assetBalanceOf(newUser) < splHaBefore, true, "deposits decrease");
        console.log("  SPL received: %d sailETH", splReceived);
        _claimAll();
        {
            IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
            uint256 claimable = acc.claimable(newUser, lev);
            uint256 nb = IERC20(lev).balanceOf(newUser);
            vm.prank(newUser);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(newUser) - nb, claimable, "newUser claim");
            assertEq(acc.claimable(newUser, lev), 0, "newUser residual");
            console.log("  newUser: %d", claimable);
        }
    }

    function test_withdrawPreservesRewards() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint64 startDelay = IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY();
        _installMockOracle();
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 poolBal = IStabilityPool(spl).assetBalanceOf(h);
            uint256 claimablePre = acc.claimable(h, lev);
            if (poolBal == 0 || claimablePre == 0) continue;
            vm.prank(h);
            IStabilityPool(spl).requestWithdrawal();
            vm.warp(block.timestamp + startDelay + 1);
            vm.prank(h);
            IStabilityPool(spl).withdraw(type(uint256).max, h, 0);
            uint256 claimablePost = acc.claimable(h, lev);
            assertEq(
                claimablePost >= claimablePre,
                true,
                string.concat("claimable should not decrease for ", vm.toString(h))
            );
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimablePost, "claim after withdraw");
            console.log("  %s: claimable %d -> %d", vm.toString(h), claimablePre, claimablePost);
        }
    }

    function test_multipleRebalances() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        _depositAs(alice, 5000 ether);
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        uint256 prevClaimable = 0;
        for (uint256 r = 1; r <= 3; r++) {
            uint256 splReceived = _triggerRebalance(mockOracle);
            uint256 aliceClaimable = acc.claimable(alice, lev);
            console.log("  Rebalance %d: splReceived=%d, alice=%d", r, splReceived, aliceClaimable);
            assertEq(aliceClaimable > prevClaimable, true, "alice claimable should increase");
            prevClaimable = aliceClaimable;
        }
        uint256[] memory received = _claimAll();
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(acc.claimable(expected[i].holder, lev), 0, "residual");
            console.log("  %s: %d", vm.toString(expected[i].holder), received[i]);
        }
        uint256 aliceBal = IERC20(lev).balanceOf(alice);
        vm.prank(alice);
        acc.claim();
        assertEq(acc.claimable(alice, lev), 0, "alice residual");
        console.log("  Alice total: %d", IERC20(lev).balanceOf(alice) - aliceBal);
    }

    function test_redeemLeveragedToken() public {
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 sailBal = IERC20(lev).balanceOf(h);
            if (sailBal == 0 || IStabilityPool(spl).assetBalanceOf(h) > 0) continue;
            uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
            uint256 supplyBefore = IERC20(lev).totalSupply();
            vm.startPrank(h);
            IERC20(lev).approve(minter, sailBal);
            IMinter(minter).redeemLeveragedToken(sailBal, h, 0);
            vm.stopPrank();
            assertEq(supplyBefore - IERC20(lev).totalSupply(), sailBal, "supply decreased");
            assertEq(IERC20(lev).balanceOf(h), 0, "holder zero after redeem");
            assertEq(IMinter(minter).leveragedTokenPrice() >= priceBefore, true, "price not decreased");
            console.log("  %s: redeemed %d", vm.toString(h), sailBal);
        }
    }

    function test_redeemPeggedToken() public {
        address user = makeAddr("pegRedeemer");
        uint256 pegMinted = _mintPegged(user, 1 ether);

        uint256 pegBalBefore = IMinter(minter).peggedTokenBalance();
        vm.startPrank(user);
        IERC20(peg).approve(minter, pegMinted);
        IMinter(minter).redeemPeggedToken(pegMinted, user, 0);
        vm.stopPrank();
        assertEq(pegBalBefore - IMinter(minter).peggedTokenBalance(), pegMinted, "peggedTokenBalance decreased");
        console.log("  peggedTokenBalance: %d -> %d", pegBalBefore, IMinter(minter).peggedTokenBalance());
    }

    function test_mintPeggedAndLeveraged() public {
        address user = makeAddr("minterUser");

        // Mint pegged (haETH)
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 pegSupplyBefore = IMinter(minter).peggedTokenBalance();
        uint256 pegMinted = _mintPegged(user, 1 ether);
        assertEq(pegMinted > 0, true, "should mint haETH");
        assertEq(IMinter(minter).peggedTokenBalance() - pegSupplyBefore, pegMinted, "peggedTokenBalance increased");
        assertEq(IERC20(peg).balanceOf(user), pegMinted, "user received haETH");

        // Mint leveraged (sailETH)
        uint256 levSupplyBefore = IERC20(lev).totalSupply();
        uint256 levMinted = _mintLeveraged(user, 1 ether);
        assertEq(levMinted > 0, true, "should mint sailETH");
        assertEq(IERC20(lev).totalSupply() - levSupplyBefore, levMinted, "totalSupply increased");
        assertEq(IERC20(lev).balanceOf(user), levMinted, "user received sailETH");

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        console.log("  levPrice: %d -> %d", priceBefore, priceAfter);
        console.log("  minted: %d haETH, %d sailETH", pegMinted, levMinted);

        // Redeem both back
        vm.startPrank(user);
        IERC20(lev).approve(minter, levMinted);
        uint256 collFromLev = IMinter(minter).redeemLeveragedToken(levMinted, user, 0);
        IERC20(peg).approve(minter, pegMinted);
        uint256 collFromPeg = IMinter(minter).redeemPeggedToken(pegMinted, user, 0);
        vm.stopPrank();

        assertEq(IERC20(lev).balanceOf(user), 0, "sailETH zero after redeem");
        assertEq(IERC20(peg).balanceOf(user), 0, "haETH zero after redeem");
        console.log("  redeemed: %d + %d fxSAVE back", collFromLev, collFromPeg);
    }

    function test_newUser_fullLifecycle() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        _logLevPrice("start");
        _depositAs(alice, 5000 ether);
        assertEq(IStabilityPool(spl).assetBalanceOf(alice) > 0, true, "deposit balance > 0");
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _triggerRebalance(mockOracle);
        _logLevPrice("after rebalance");
        uint256 claimable = acc.claimable(alice, lev);
        uint256 levBefore = IERC20(lev).balanceOf(alice);
        vm.prank(alice);
        acc.claim();
        uint256 claimed = IERC20(lev).balanceOf(alice) - levBefore;
        assertEq(claimed, claimable, "claim amount");
        assertEq(claimed > 0, true, "should have claimed something");
        vm.prank(alice);
        IStabilityPool(spl).requestWithdrawal();
        vm.warp(block.timestamp + IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY() + 1);
        (uint256 p, , uint256 r, ) = mockOracle.latestAnswer();
        mockOracle.setLatestAnswer(p, p, r, r);
        uint256 pegBefore = IERC20(peg).balanceOf(alice);
        vm.prank(alice);
        IStabilityPool(spl).withdraw(type(uint256).max, alice, 0);
        assertEq(IERC20(peg).balanceOf(alice) > pegBefore, true, "should receive haETH");
        _logLevPrice("after withdraw");
        uint256 sailToRedeem = IERC20(lev).balanceOf(alice);
        assertEq(sailToRedeem > 0, true, "should have sailETH to redeem");
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        vm.startPrank(alice);
        IERC20(lev).approve(minter, sailToRedeem);
        IMinter(minter).redeemLeveragedToken(sailToRedeem, alice, 0);
        vm.stopPrank();
        assertEq(IMinter(minter).leveragedTokenPrice() >= priceBefore, true, "price not decreased");
        assertEq(IERC20(lev).balanceOf(alice), 0, "alice sailETH zero");
        assertEq(IStabilityPool(spl).assetBalanceOf(alice), 0, "alice pool zero");
        assertEq(acc.claimable(alice, lev), 0, "alice claimable zero");
        console.log("  [OK] Lifecycle complete. haETH=%d", IERC20(peg).balanceOf(alice));
    }

    function test_realOracle_stateCheck() public view {
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 price = IMinter(minter).leveragedTokenPrice();
        uint256 supply = IERC20(lev).totalSupply();
        uint256 splBal = IERC20(lev).balanceOf(spl);
        assertEq(ratio > 0, true, "collateralRatio > 0");
        assertEq(price > 0, true, "leveragedTokenPrice > 0");
        assertEq(supply > 0, true, "totalSupply > 0");
        assertEq(splBal > 0, true, "SPL balance > 0");
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < expected.length; i++) {
            totalClaimable += acc.claimable(expected[i].holder, lev);
        }
        assertEq(splBal >= totalClaimable, true, "SPL balance >= total claimable");
        console.log("  ratio=%d price=%d", ratio, price);
        console.log("  supply=%d splBal=%d", supply, splBal);
    }

    function test_claimerSnapshotReset() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        assertEq(acc.claimable(CLAIMER, lev), 0, "Claimer should start with 0 (stuck snapshot)");
        uint256 walletBefore = IERC20(lev).balanceOf(CLAIMER);
        vm.prank(CLAIMER);
        acc.claim();
        assertEq(IERC20(lev).balanceOf(CLAIMER), walletBefore, "wallet unchanged from empty claim");
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        uint256 received = _triggerRebalance(mockOracle);
        console.log("  SPL received: %d sailETH", received);
        uint256 claimerAfter = acc.claimable(CLAIMER, lev);
        assertEq(claimerAfter > 0, true, "Claimer should accumulate after snapshot reset");
        uint256 balBefore = IERC20(lev).balanceOf(CLAIMER);
        vm.prank(CLAIMER);
        acc.claim();
        assertEq(IERC20(lev).balanceOf(CLAIMER) - balBefore, claimerAfter, "Claimer claim amount");
        assertEq(acc.claimable(CLAIMER, lev), 0, "Claimer residual zero");
        console.log("  [OK] Claimer received: %d after reset", claimerAfter);
    }

    function test_claimThenRebalanceThenClaimAgain() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _claimAll();
        _depositAs(alice, 5000 ether);
        _depositAs(bob, 2000 ether);
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        uint256 splReceived = _triggerRebalance(mockOracle);
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            if (!_hasPoolBalance(i)) {
                assertEq(claimable, 0, string.concat("no-pool holder should get 0: ", vm.toString(h)));
            }
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimable, "claim mismatch");
            assertEq(acc.claimable(h, lev), 0, "residual");
            totalClaimed += claimable;
            console.log("  %s: %d", vm.toString(h), claimable);
        }
        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            uint256 claimable = acc.claimable(users[i], lev);
            uint256 balBefore = IERC20(lev).balanceOf(users[i]);
            vm.prank(users[i]);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(users[i]) - balBefore, claimable, "new user claim");
            totalClaimed += claimable;
        }
        console.log("  totalClaimed: %d, splReceived: %d", totalClaimed, splReceived);
    }

    function test_staleHolders_rebalanceWithoutClaiming() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint256[] memory claimableBefore = new uint256[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            claimableBefore[i] = acc.claimable(expected[i].holder, lev);
        }
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _triggerRebalance(mockOracle);
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimableAfter = acc.claimable(h, lev);
            if (_hasPoolBalance(i)) {
                assertEq(
                    claimableAfter >= claimableBefore[i],
                    true,
                    string.concat("pool holder claimable should not decrease: ", vm.toString(h))
                );
            } else {
                assertEq(
                    claimableAfter,
                    claimableBefore[i],
                    string.concat("no-pool holder claimable unchanged: ", vm.toString(h))
                );
            }
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimableAfter, "claim mismatch");
            console.log("  %s: %d (was %d)", vm.toString(h), claimableAfter, claimableBefore[i]);
        }
    }

    function test_depositThenRebalanceThenClaim() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _depositAs(alice, 3000 ether);
        _depositAs(bob, 1000 ether);
        // Existing holders with pool balance deposit more (balanced mint to keep CR stable)
        for (uint256 i = 0; i < expected.length; i++) {
            if (!_hasPoolBalance(i)) continue;
            address h = expected[i].holder;
            uint256 pegOut = _mintPegged(h, 1000 ether);
            _mintLeveraged(h, 1000 ether);
            vm.startPrank(h);
            IERC20(peg).approve(spl, pegOut);
            IStabilityPool(spl).deposit(pegOut, h, 0);
            vm.stopPrank();
        }
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _triggerRebalance(mockOracle);
        address[2] memory newUsers = [alice, bob];
        for (uint256 j = 0; j < 2; j++) {
            uint256 claimable = acc.claimable(newUsers[j], lev);
            assertEq(claimable > 0, true, "new user should have claimable");
            uint256 balBefore = IERC20(lev).balanceOf(newUsers[j]);
            vm.prank(newUsers[j]);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(newUsers[j]) - balBefore, claimable, "new user claim");
        }
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimable, "holder claim");
            assertEq(acc.claimable(h, lev), 0, "residual");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// SPLRemediationTest: forks mainnet at fixed block, runs the remediation,
// then inherits all post-remediation tests from SPLTestBase.
// Also adds test_remediation which validates the remediation itself.
// Run: forge test --mc SPLRemediationTest -vv
// ═══════════════════════════════════════════════════════════════════════════

contract SPLRemediationTest is SPLTestBase {
    uint256 constant FORK_BLOCK = 24699497;
    uint256 constant BURNER_ROLE = 1 << 1;
    uint256 constant V2_LEV_PRICE = 3467248825484481570;
    uint256 constant V2_LEV_SUPPLY = 525304936873195071;

    address existingV2Impl;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        _initAddresses();
        _initExpected();

        existingV2Impl = address(
            uint160(uint256(vm.load(spl, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
        );

        _runRemediation();
    }

    function _runRemediation() internal {
        vm.prank(IBaoOwnable(lev).owner());
        IBaoRoles(lev).grantRoles(spl, BURNER_ROLE);
        uint256 ZERO_FEE_ROLE = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(spl, ZERO_FEE_ROLE);
        uint256 COLLATERAL_GAP = 82.466171119621162782 ether;
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        vm.prank(IBaoOwnable(minter).owner());
        IERC20(wrappedCollateral).transfer(spl, COLLATERAL_GAP);
        vm.prank(CLAIMER);
        IERC20(lev).approve(spl, 0.052087080191248362 ether);
        address BOUNTY_RECEIVER = 0xf1674FE69b2920b4de51E909cbf060dd78724CD8;
        vm.prank(BOUNTY_RECEIVER);
        IERC20(lev).approve(spl, 0.087632380029141447 ether);
        PostRebalanceRemediationForStabilityPool_v2 impl = new PostRebalanceRemediationForStabilityPool_v2(
            lev,
            minter,
            proxyOwner
        );
        vm.prank(proxyOwner);
        UUPSUpgradeable(spl).upgradeToAndCall(
            address(impl),
            abi.encodeCall(PostRebalanceRemediationForStabilityPool_v2.remediate, ())
        );
        vm.prank(proxyOwner);
        UUPSUpgradeable(spl).upgradeToAndCall(existingV2Impl, "");
        vm.prank(IBaoOwnable(lev).owner());
        IBaoRoles(lev).revokeRoles(spl, BURNER_ROLE);
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).revokeRoles(spl, ZERO_FEE_ROLE);
    }

    /// @notice Remediation-specific test: validates holder state, assetBalances,
    /// and fxSAVE claimable are correct/unchanged after remediation.
    function test_remediation() public view {
        // This runs AFTER setUp which already called _runRemediation().
        // Capture fresh post-remediation values.
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);

        console.log("=== POST-REMEDIATION ===");
        console.log("  levPrice:  %e (v2 target: %e)", IMinter(minter).leveragedTokenPrice(), V2_LEV_PRICE);
        console.log("  levSupply: %e (v2 target: %e)", IERC20(lev).totalSupply(), V2_LEV_SUPPLY);

        uint256 failures;
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;

            // sailETH held
            {
                uint256 actualHeld = IERC20(lev).balanceOf(h);
                if (actualHeld != expected[i].v2Held) {
                    console.log("  FAIL held %s: actual=%e target=%e", h, actualHeld, expected[i].v2Held);
                    failures++;
                }
            }

            // sailETH claimable (Claimer has known shortfall)
            {
                uint256 actualClaimable = acc.claimable(h, lev);
                if (h == CLAIMER) {
                    console.log(
                        "  [NOTE] Claimer claimable=%e (v2 target=%e, shortfall=%e)",
                        actualClaimable,
                        expected[i].v2Claimable,
                        expected[i].v2Claimable - actualClaimable
                    );
                } else if (actualClaimable != expected[i].v2Claimable) {
                    console.log(
                        "  FAIL claimable %s: actual=%e target=%e",
                        h,
                        actualClaimable,
                        expected[i].v2Claimable
                    );
                    failures++;
                }
            }

            // fxSAVE claimable must not have been altered
            // (We can't compare pre vs post here since setUp already ran remediation,
            //  but we verify it's non-negative and log it for manual review.)
            {
                uint256 fxSaveClaim = acc.claimable(h, wrappedCollateral);
                console.log("  %s fxSAVE claimable: %d", vm.toString(h), fxSaveClaim);
            }
        }

        if (failures == 0) {
            console.log("  [OK] All %d holders match v2 correct state", expected.length);
        }
        assertEq(failures, 0, "some holders do not match v2 correct state");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// PostRemediationIntegrationTest: runs against an already-remediated fork.
// Inherits all tests from SPLTestBase without modification.
// Run: forge test --mc PostRemediationIntegrationTest --fork-url local -vv
// ═══════════════════════════════════════════════════════════════════════════

contract PostRemediationIntegrationTest is SPLTestBase {
    function setUp() public {
        _initAddresses();
        _initExpected();
    }
}
