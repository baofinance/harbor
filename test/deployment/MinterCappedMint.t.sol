// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";

/// @title MinterCappedMintTest
/// @notice Tests for Minter_v3 fee-capped minting, deployed via production deployment scripts.
contract MinterCappedMintSetUp is BaoTest, Deploy_ETH_Minter, HarborTestActions {
    address minter;
    address pegged;
    address wrappedCollateral;

    MockWrappedPriceOracle mockOracle;

    function setUp() public virtual {
        forkMainnetWithBaoFactory();

        // Deploy the ETH::fxUSD market (one collateral) via the production deploy scripts (Minter_v3).
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createETHMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = new Config_MinterMarket[](1);
        marketsToDeploy[0] = allMarkets[0];
        deployHarborForPeg("capped_test", peg, allMarkets, "mainnet", true, marketsToDeploy);

        minter = minterAddress(allMarkets[0]);
        pegged = peggedTokenAddress(allMarkets[0]);
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Install the mock oracle (price=1, rate=1) where the deploy wired the minter, then grant the
        // zero-fee role for bootstrap minting.
        mockOracle = MockWrappedPriceOracle(installMockPriceOracle(wrappedPriceOracleAddress(allMarkets[0])));
        mockOracle.setLatestAnswer(1 ether, 1 ether);
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.startPrank(HARBOR_MULTISIG);
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();
    }

    /// @dev Mint pegged + leveraged to create a collateral ratio where minting is allowed with fees.
    /// Target: CR around 1.5-2.0 where fee bands are active.
    function _bootstrapCollateralRatio() internal {
        // Mint 500 pegged → CR starts very high (all collateral, small pegged supply)
        deal(wrappedCollateral, address(this), 500 ether);
        IERC20(wrappedCollateral).approve(minter, 500 ether);
        IMinter(minter).freeMintPeggedToken(500 ether, address(this));

        // Mint 500 leveraged → absorbs collateral, lowering effective CR
        deal(wrappedCollateral, address(this), 500 ether);
        IERC20(wrappedCollateral).approve(minter, 500 ether);
        IMinter(minter).freeMintLeveragedToken(500 ether, address(this));

        // CR = totalCollateral * price / peggedBalance = 1000 * 1 / 500 = 2.0
    }
}

contract MinterCappedMintTest is MinterCappedMintSetUp {
    // ═══════════════════════════════════════════════════════════════
    // Uncapped mint (3-arg) behavior unchanged
    // ═══════════════════════════════════════════════════════════════

    function test_uncappedMint_matchesV2Behavior() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        // Actual mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        uint256 peggedOut = IMinter(minter).mintPeggedToken(collateralIn, alice, 0);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches dry run");
        // Collateral used = what was taken from alice
        uint256 aliceRemaining = IERC20(wrappedCollateral).balanceOf(alice);
        assertEq(collateralIn - aliceRemaining, dryCollUsed, "collateral used matches dry run");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint (4-arg) — full mint when fee below cap
    // ═══════════════════════════════════════════════════════════════

    function test_cappedMint_fullMint_feeBelowCap() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Get current fee ratio
        (int256 incentiveRatio, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        // Set cap well above current fee
        uint256 maxFeeRatio = uint256(incentiveRatio) * 2;

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches capped dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches capped dry run");
        // Full mint — all collateral used (fee is below cap)
        assertEq(collUsed, collateralIn, "all collateral used when fee below cap");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint — no mint when fee exceeds cap from start
    // ═══════════════════════════════════════════════════════════════

    function test_cappedMint_noMint_feeExceedsCap() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Set cap to 0 — any fee exceeds it
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, 0);
        vm.stopPrank();

        assertEq(peggedOut, 0, "no pegged minted");
        assertEq(collUsed, 0, "no collateral used");
        // Alice still has all her collateral
        assertEq(IERC20(wrappedCollateral).balanceOf(alice), collateralIn, "collateral returned");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint — partial mint when fee exceeds cap mid-band
    // ═══════════════════════════════════════════════════════════════

    /// @dev A partial fill exists only for a cap strictly between the cheapest band's rate and the
    ///      average rate over the whole offer: below the cheapest rate nothing is affordable at all,
    ///      at or above the average the whole offer is. In between, the cheap bands are taken in full
    ///      and only as much of the dearer band as keeps the average within the cap.
    function test_cappedMint_partialMint() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        // Large enough to drive the collateral ratio down out of its starting band: the bootstrap
        // leaves 1000 collateral against 500 pegged, and minting adds to both, so ~125 crosses the
        // first boundary below 2.0.
        uint256 collateralIn = 400 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Uncapped: the whole offer, and the average rate it pays.
        (int256 uncappedRatio, , uint256 uncappedCollUsed, uint256 uncappedPegged, , ) = IMinter(minter)
            .mintPeggedTokenDryRun(collateralIn);
        uint256 cheapestBandRate = uint256(IMinter_v3(minter).mintPeggedTokenIncentiveRatio());
        assertGt(uint256(uncappedRatio), cheapestBandRate, "the offer crosses into a dearer band");
        uint256 maxFeeRatio = (cheapestBandRate + uint256(uncappedRatio)) / 2;

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches capped dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches capped dry run");

        // Partial: used less collateral, minted less pegged
        assertGt(collUsed, 0, "some collateral used");
        assertLt(collUsed, uncappedCollUsed, "less than uncapped");
        assertGt(peggedOut, 0, "some pegged minted");
        assertLt(peggedOut, uncappedPegged, "less than uncapped pegged");

        // Alice keeps the unused portion
        assertEq(IERC20(wrappedCollateral).balanceOf(alice), collateralIn - collUsed, "remaining collateral");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: dry run always matches actual mint
    // ═══════════════════════════════════════════════════════════════

    function test_fuzz_dryRunMatchesActualMint(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        // Bound inputs to reasonable ranges
        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0, 0.5 ether); // 0% to 50%

        address alice = makeAddr("alice");
        deal(wrappedCollateral, alice, collateralIn);

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches dry run");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: capped mint uses <= uncapped mint collateral
    // ═══════════════════════════════════════════════════════════════

    function test_fuzz_cappedUsesLessOrEqualCollateral(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0, 1 ether); // 0% to 100%

        // Uncapped dry run
        (, , uint256 uncappedCollUsed, uint256 uncappedPegged, , ) = IMinter(minter).mintPeggedTokenDryRun(
            collateralIn
        );

        // Capped dry run
        (, , uint256 cappedCollUsed, uint256 cappedPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        assertLe(cappedCollUsed, uncappedCollUsed, "capped uses <= uncapped collateral");
        assertLe(cappedPegged, uncappedPegged, "capped mints <= uncapped pegged");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint — the cap is a ratio over the collateral USED
    // ═══════════════════════════════════════════════════════════════

    /// @notice A cap below the rate of the cheapest band on offer mints NOTHING: every unit of
    ///         collateral would cost more than the cap, so no amount has an average fee that fits.
    ///         The amount offered does not buy a proportional fee budget to spend on a smaller amount.
    function test_cappedMint_capBelowCurrentBandRate_mintsNothing() public {
        _bootstrapCollateralRatio();

        // The band the current collateral ratio sits in is the cheapest rate available: minting only
        // ever moves the ratio down into dearer bands.
        uint256 currentBandRate = uint256(IMinter_v3(minter).mintPeggedTokenIncentiveRatio());
        uint256 maxFeeRatio = currentBandRate / 2;

        (, uint256 dryFee, uint256 dryCollateralUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            100 ether,
            maxFeeRatio
        );

        assertEq(dryCollateralUsed, 0, "no collateral used: every unit costs more than the cap");
        assertEq(dryPegged, 0, "no pegged minted");
        assertEq(dryFee, 0, "no fee charged");
    }

    /// @notice The cap bounds the fee ratio over the collateral actually USED. A partial fill takes
    ///         only as much as keeps its own average fee within the cap — it does not spend a budget
    ///         sized by the whole offer on the smaller amount it takes. (The weaker bound, fee within
    ///         `maxFeeRatio × collateralIn`, follows from this since used never exceeds offered.)
    function test_fuzz_feeNeverExceedsCap(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0.001 ether, 0.5 ether); // 0.1% to 50%

        // Capped dry run. `incentiveRatio` IS the realised fee over collateral used.
        (int256 incentiveRatio, , uint256 dryCollateralUsed, , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );
        // With nothing taken there is no realised ratio to bound (the getter reports the band's rate).
        vm.assume(dryCollateralUsed > 0);

        // Fee and collateral used are each floored independently out of the 1e36-scaled internals, so
        // the reported ratio can exceed the exact one by at most one wei of fee spread over the amount
        // used — `1e18 / used` in ratio terms.
        uint256 roundingDust = 1 ether / dryCollateralUsed + 1;
        assertLe(
            uint256(incentiveRatio),
            maxFeeRatio + roundingDust,
            "realised fee ratio over collateral used <= maxFeeRatio"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // Uncapped via type(uint256).max matches 3-arg version
    // ═══════════════════════════════════════════════════════════════

    function test_cappedWithMaxUint_matchesUncapped() public {
        _bootstrapCollateralRatio();

        uint256 collateralIn = 50 ether;

        // Uncapped dry run (3-arg)
        (int256 ir1, uint256 fee1, uint256 coll1, uint256 peg1, uint256 p1, uint256 r1) = IMinter(minter)
            .mintPeggedTokenDryRun(collateralIn);

        // Capped with max (4-arg)
        (int256 ir2, uint256 fee2, uint256 coll2, uint256 peg2, uint256 p2, uint256 r2) = IMinter_v3(minter)
            .mintPeggedTokenDryRun(collateralIn, type(uint256).max);

        assertEq(ir1, ir2, "incentive ratio matches");
        assertEq(fee1, fee2, "fee matches");
        assertEq(coll1, coll2, "collateral used matches");
        assertEq(peg1, peg2, "pegged minted matches");
        assertEq(p1, p2, "price matches");
        assertEq(r1, r2, "rate matches");
    }
}
