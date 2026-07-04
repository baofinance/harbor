// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {MinterCappedMintSetUp} from "@harbor-test/deployment/MinterCappedMint.t.sol";

/// @title MinterFreeMintCappedTest
/// @notice A fee-free pegged mint that stops at the governance disallow floor — the redistribute wind
/// leg — is composed from two existing Minter calls rather than a bespoke Minter function:
///   1. `mintPeggedTokenDryRun(probe)` with a large probe walks the fee bands to the floor and reports
///      the fee'd `collateralTaken` (= backing + fee) and `fee`; the fee-free backing capacity to the
///      floor is `collateralTaken - fee`.
///   2. `freeMintPeggedToken(min(amount, capacity))` mints that backing fee-free.
/// `_cappedFreeMint` below is that sequence — the function under test and the reference for
/// VaultManager (Batch 2). Correctness is checked against INDEPENDENT oracles: the config-derived floor
/// and an analytic backing-to-floor formula — never by feeding the sequence's own output back in.
/// Reuses MinterCappedMintSetUp's ETH::fxUSD market (mock oracle price=1e18, rate=1e18; bootstrap
/// CR=2.0; disallow floor CR=1.31).
contract MinterFreeMintCappedTest is MinterCappedMintSetUp {
    /// @dev Probe input for the capacity dry-run: large enough to exceed any market's capacity to the
    /// floor (so the walk is floor-bound, not input-bound — `allOfQuiet` passes a concrete value through
    /// with no balance cap), yet small enough that `probe * rate` cannot overflow uint256 in the walk.
    uint256 internal constant FLOOR_PROBE = 1e40;

    // ── Function under test ───────────────────────────────────────────────────────────────────────
    /// @dev The redistribute wind's capped fee-free mint, composed from existing Minter calls. Pulls
    /// `min(amount, capacity)` wrapped collateral from the caller and mints it fee-free; returns (0,0)
    /// at/below the floor. This is the exact sequence VaultManager._windFromToken will run (Batch 2).
    function _cappedFreeMint(uint256 amount, address receiver) internal returns (uint256 peggedOut, uint256 used) {
        (, uint256 fee, uint256 collateralToFloor, , , ) = IMinter(minter).mintPeggedTokenDryRun(FLOOR_PROBE);
        uint256 capacity = collateralToFloor - fee; // fee-free backing to the floor ("collateral added")
        used = amount < capacity ? amount : capacity;
        if (used == 0) {
            return (0, 0);
        }
        peggedOut = IMinter(minter).freeMintPeggedToken(used, receiver);
    }

    // ── Independent oracles (do not use the dry-run / free-mint the sequence relies on) ────────────
    /// @dev The disallow floor CR — the lowest non-disallow band's lower bound, read from config.
    function _disallowFloor() internal view returns (uint256) {
        IMinter.Config memory cfg = IMinter(minter).config();
        assertEq(cfg.mintPeggedIncentiveConfig.incentiveRatios[0], int256(1 ether), "band 0 is the disallow band");
        return cfg.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[0];
    }

    /// @dev Analytic fee-free backing (wrapped) to bring CR to the floor, derived independently of the
    /// dry-run: from CR=(C+dC)·p/(Z+dC)=R (price=rate=peggedPrice=1e18 in this mock market) →
    /// dC = (C·1e18 − R·Z)/(R − 1e18). Valid only above the floor (dC > 0).
    function _analyticCapacityToFloor() internal view returns (uint256) {
        uint256 collateral = IMinter(minter).collateralTokenBalance();
        uint256 pegged = IMinter(minter).peggedTokenBalance();
        uint256 floor = _disallowFloor();
        return (collateral * 1 ether - floor * pegged) / (floor - 1 ether);
    }

    function _fund(uint256 amount) internal {
        deal(wrappedCollateral, address(this), amount);
        IERC20(wrappedCollateral).approve(minter, amount);
    }

    // ───────────────────────────────────────────────────────────────
    // Capacity equals the independent analytic backing-to-floor
    // ───────────────────────────────────────────────────────────────

    /// The sequence's consumed collateral (from the fee'd dry-run, minus the fee) equals the analytic
    /// fee-free backing to the floor computed independently. This is what proves `collateralTaken - fee`
    /// is the right number — subtracting the fee, not `collateralTaken` alone.
    function test_cappedFreeMint_capacityMatchesAnalytic() public {
        _bootstrapCollateralRatio();
        uint256 expected = _analyticCapacityToFloor();

        _fund(5000 ether); // exceeds the ~1113 capacity, so the capacity binds
        (, uint256 used) = _cappedFreeMint(5000 ether, address(this));

        // Dry-run accumulates per-band integer-division rounding over ~6 bands vs the analytic single
        // division; a few wei of drift, well under 1000.
        assertApproxEqAbs(used, expected, 1000, "sequence capacity == analytic backing-to-floor");
    }

    // ───────────────────────────────────────────────────────────────
    // Lands at the config-derived floor, never below
    // ───────────────────────────────────────────────────────────────

    /// Consuming the full capacity lands the collateral ratio at the config disallow floor.
    function test_cappedFreeMint_landsAtDisallowFloor() public {
        _bootstrapCollateralRatio();
        uint256 floor = _disallowFloor();

        _fund(5000 ether);
        _cappedFreeMint(5000 ether, address(this));

        // 1e6 is ~13 orders of magnitude below the 0.01e18 gap to the band-below (1.30), so this proves
        // the landing is at the 1.31 floor and not a band off, in either direction.
        assertApproxEqAbs(IMinter(minter).collateralRatio(), floor, 1e6, "CR lands at the disallow floor");
    }

    // ───────────────────────────────────────────────────────────────
    // Partial fill: amount exceeds capacity → remainder kept
    // ───────────────────────────────────────────────────────────────

    /// When the caller holds more than the capacity, it consumes exactly the capacity, keeps the
    /// remainder, and lands at the floor.
    function test_cappedFreeMint_partialFill_leavesRemainderWithCaller() public {
        _bootstrapCollateralRatio();
        uint256 floor = _disallowFloor();
        uint256 expectedCapacity = _analyticCapacityToFloor();
        uint256 amount = 5000 ether;

        _fund(amount);
        (uint256 peggedOut, uint256 used) = _cappedFreeMint(amount, address(this));

        assertApproxEqAbs(used, expectedCapacity, 1000, "consumed the capacity");
        assertLt(used, amount, "capacity binds below the amount");
        assertGt(peggedOut, 0, "minted a positive amount");
        assertEq(IERC20(wrappedCollateral).balanceOf(address(this)), amount - used, "remainder stays with caller");
        assertApproxEqAbs(IMinter(minter).collateralRatio(), floor, 1e6, "stopped at the floor");
    }

    // ───────────────────────────────────────────────────────────────
    // Full fill: amount below capacity → whole amount minted
    // ───────────────────────────────────────────────────────────────

    /// When the caller holds less than the capacity, the whole amount is minted fee-free, mints exactly
    /// `amount` pegged (price=1e18), and the floor is not reached.
    function test_cappedFreeMint_fullFill_whenAmountBelowCapacity() public {
        _bootstrapCollateralRatio();
        uint256 floor = _disallowFloor();
        uint256 amount = 50 ether;
        assertLt(amount, _analyticCapacityToFloor(), "amount is below the capacity");

        _fund(amount);
        (uint256 peggedOut, uint256 used) = _cappedFreeMint(amount, address(this));

        assertEq(used, amount, "entire amount consumed");
        assertEq(peggedOut, amount, "at price 1e18, minted pegged equals collateral posted");
        assertEq(IERC20(wrappedCollateral).balanceOf(address(this)), 0, "no remainder");
        assertGt(IMinter(minter).collateralRatio(), floor, "floor not reached");
    }

    // ───────────────────────────────────────────────────────────────
    // At or below the floor: capacity is zero → nothing minted
    // ───────────────────────────────────────────────────────────────

    /// Below the floor the dry-run consumes nothing, so the capacity is zero and the sequence mints
    /// nothing and pulls nothing — the market cannot be pushed further into the disallowed region.
    function test_cappedFreeMint_belowFloor_mintsNothing() public {
        _bootstrapCollateralRatio();

        // Drive CR below the floor with the uncapped free mint (which does not respect the floor).
        _fund(5000 ether);
        IMinter(minter).freeMintPeggedToken(5000 ether, address(this));
        assertLt(IMinter(minter).collateralRatio(), _disallowFloor(), "setup: CR is below the floor");

        uint256 backingBefore = IMinter(minter).collateralTokenBalance();
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();

        _fund(1000 ether);
        (uint256 peggedOut, uint256 used) = _cappedFreeMint(1000 ether, address(this));

        assertEq(used, 0, "nothing consumed below the floor");
        assertEq(peggedOut, 0, "nothing minted below the floor");
        assertEq(IMinter(minter).collateralTokenBalance(), backingBefore, "backing unchanged");
        assertEq(IMinter(minter).peggedTokenBalance(), peggedBefore, "pegged supply unchanged");
        assertEq(IERC20(wrappedCollateral).balanceOf(address(this)), 1000 ether, "nothing pulled from caller");
    }

    // ───────────────────────────────────────────────────────────────
    // Fee-free: nothing reaches the fee receiver
    // ───────────────────────────────────────────────────────────────

    /// The sequence mints via the free path, so no fee reaches the feeReceiver.
    function test_cappedFreeMint_feeFree_noFeeToReceiver() public {
        _bootstrapCollateralRatio();

        address feeReceiver = IMinter(minter).feeReceiver();
        uint256 feeBefore = IERC20(wrappedCollateral).balanceOf(feeReceiver);

        _fund(5000 ether);
        _cappedFreeMint(5000 ether, address(this));

        assertEq(IERC20(wrappedCollateral).balanceOf(feeReceiver), feeBefore, "no fee sent to feeReceiver");
    }

    // ───────────────────────────────────────────────────────────────
    // Access control: the mint step is role-gated
    // ───────────────────────────────────────────────────────────────

    /// `freeMintPeggedToken` (the mint step) reverts Unauthorized without ZERO_FEE_ROLE; the dry-run is
    /// a view and needs no role.
    function test_cappedFreeMint_mintStepOnlyZeroFeeRole() public {
        _bootstrapCollateralRatio();

        address bob = makeAddr("bob");
        deal(wrappedCollateral, bob, 50 ether);
        vm.startPrank(bob);
        IERC20(wrappedCollateral).approve(minter, 50 ether);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMinter(minter).freeMintPeggedToken(50 ether, bob);
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────────
    // Behavioural anchor: the sequence fixes the uncapped pathology
    // ───────────────────────────────────────────────────────────────

    /// The same amount that the uncapped freeMintPeggedToken drives through the floor toward CR≈1.0, the
    /// dry-run-capped sequence stops at the floor. This is the redistribute-wind pathology, fixed.
    function test_cappedFreeMint_vs_uncappedFreeMint_contrast() public {
        _bootstrapCollateralRatio();
        uint256 floor = _disallowFloor();
        uint256 amount = 5000 ether;

        uint256 snap = vm.snapshotState();

        // Uncapped: mints the whole amount, driving CR through the floor.
        _fund(amount);
        IMinter(minter).freeMintPeggedToken(amount, address(this));
        uint256 crUncapped = IMinter(minter).collateralRatio();

        vm.revertToState(snap);

        // Capped by the dry-run capacity: stops at the floor.
        _fund(amount);
        _cappedFreeMint(amount, address(this));
        uint256 crCapped = IMinter(minter).collateralRatio();

        assertLt(crUncapped, floor, "uncapped free-mint drives CR below the floor");
        assertApproxEqAbs(crCapped, floor, 1e6, "capped sequence stops at the floor");
    }
}
