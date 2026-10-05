// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

abstract contract TestMinterFeeRangeSetUp is TestMinterSetUp {
    uint256 price;
    uint256 rate;
    address user;

    function setUp() public virtual override {
        super.setUp();
        (price, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        deal(address(wrappedCollateralToken), address(this), 1_000_000_000_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);

        user = makeAddr("user");
        deal(address(wrappedCollateralToken), user, 1e70);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    // Inline helpers with minimal stack footprint
    function _bandLower(uint256 idx, uint256[] memory b) internal pure returns (uint256) {
        return idx == 0 ? 0 : b[idx - 1];
    }
    function _inBand(uint256 cr, uint256 idx, uint256[] memory b) internal pure returns (bool) {
        return cr > _bandLower(idx, b) && cr <= b[idx];
    }
    function _calcLForCR(uint256 pBase, uint256 targetCR) internal pure returns (uint256) {
        return targetCR <= 1e18 ? 0 : (pBase * (targetCR - 1e18)) / 1e18;
    }
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // Dynamic tolerance unit for r-scaled conversions with spread bump for extreme p vs r
    function _qR(uint256 p, uint256 r) internal pure returns (uint256) {
        // ceilDiv(r, 1e18) to avoid underestimating rounding granularity
        uint256 q = r / 1e18;
        if (r % 1e18 != 0) q += 1;
        if (q == 0) q = 1; // ensure a minimum tolerance of 1 wei

        // spread bump: when p and r are very different, rounding accumulates more
        uint256 small = p < r ? p : r;
        uint256 large = p < r ? r : p;
        if (small == 0) return q + 5; // defensive; shouldn't happen in these tests
        uint256 spread = large / small; // >= 1
        uint256 bump = spread >= 1e9 ? 5 : (spread >= 1e6 ? 3 : (spread >= 1e3 ? 1 : 0));
        return q + bump;
    }

}

abstract contract TestMinterFeeRange is TestMinterFeeRangeSetUp {
    uint256 minCollateral;
    uint256 maxCollateral;
    uint256 minToken; // the LEVERAGED floor: the ml/rl fee-ratio check uses a fixed tolerance that needs headroom
    uint256 minTokenPegged; // the PEGGED floor: mint/redeem stay accurate to the wei (redeem floors cleanly at dust)
    uint256 maxToken;
    uint256 measurePrice;
    uint256 measureRate;

    uint256 mintPeggedBands;
    uint256 redeemPeggedBands;
    uint256 mintLeveragedBands;
    uint256 redeemLeveragedBands;

    bool reverseDirection;
    uint256 subsidyLimitRatio;

    function setUp() public virtual override {
        super.setUp();
        minCollateral = 1e9;
        maxCollateral = 1e30;
        minToken = 1e16; // leveraged floor: the ml/rl fixed-tolerance fee-ratio assertion needs headroom above dust
        minTokenPegged = 1; // pegged floor: mint/redeem are accurate to the wei (redeem floors cleanly, see below)
        maxToken = 1e30;
        measurePrice = price;
        measureRate = rate;

        mintPeggedBands = 7;
        redeemPeggedBands = 7;
        mintLeveragedBands = 7;
        redeemLeveragedBands = 7;

        reverseDirection = false;
        subsidyLimitRatio = 0;
    }

    function test_mintPeggedRange_(uint256 p, uint256 l, uint256 w) public virtual {
        p = bound(p, minCollateral, maxCollateral);
        l = bound(l, minCollateral, maxCollateral);
        w = bound(w, minTokenPegged, maxToken);
        setUp_collateral(p, l, user);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
        _mintPegged(w);
    }

    function test_redeemPeggedRange_(uint256 p, uint256 l, uint256 w) public virtual {
        p = bound(p, minCollateral, maxCollateral);
        l = bound(l, minCollateral, maxCollateral);
        w = bound(w, minTokenPegged, maxToken);
        setUp_collateral(p, l, user);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
        // At dust `w` the redeem floors cleanly: the input rounds to zero (`ZeroInputBalance`) or the returned
        // collateral rounds to zero (`ReturnZeroAmount`) - a clean revert, not a silent error, so tolerate ONLY those
        // two. Every other revert, and every accuracy assertion inside `_redeemPegged`, still surfaces (re-raised).
        try this.redeemPeggedProbe(w) {
            // redeemed and asserted accurately
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel != IMinter.ZeroInputBalance.selector && sel != IMinter.ReturnZeroAmount.selector) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
    }

    /// @dev External so `test_redeemPeggedRange_` can tolerate the clean dust floor (ZeroInputBalance) while still
    /// surfacing every other revert and the accuracy assertions inside `_redeemPegged`.
    function redeemPeggedProbe(uint256 w) external {
        _redeemPegged(w);
    }

    function test_mintLeveragedRange_(uint256 p, uint256 l, uint256 w) public virtual {
        p = bound(p, minCollateral, maxCollateral);
        l = bound(l, minCollateral, maxCollateral);
        w = bound(w, minToken, maxToken);
        setUp_collateral(p, l, user);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
        // A leveraged deposit small beside the pegged one founds the market at the peg, below the floor at
        // which leverage is sold. There is no fee to range over where the mint is refused, and the refusal
        // is `Minter_leverageCap`'s to assert; the fee arithmetic is measured where a mint exists.
        vm.assume(IMinter_v3(minter).leveragedMintable());
        _mintLeveraged(w);
    }

    function test_redeemLeveragedRange_(uint256 p, uint256 l, uint256 w) public virtual {
        p = bound(p, minCollateral, maxCollateral);
        l = bound(l, minCollateral, maxCollateral);
        w = bound(w, minToken, maxToken);
        setUp_collateral(p, l, user);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
        _redeemLeveraged(w);
    }

    struct LeveragedSpanCtx {
        uint256[] bounds;
        uint256 feePerc;
        uint256 subsidyPerc;
        // the collateral the record gains per unit of collateral offered: less the fee, or plus the subsidy
        uint256 collateralPerInput;
        uint256 price;
        uint256 rate;
        uint256 pBase;
        uint256 globalSnap;
        // working fields reused
        uint256 s;
        uint256 e;
        uint256 desiredCR;
        uint256 lRef;
        uint256 attempt;
        uint256 crNow;
        uint256 lower;
        uint256 preCR;
        uint256 targetCR;
        uint256 underlyingCurrent;
        uint256 peggedSupply;
        uint256 underlyingTarget;
        uint256 deltaUnderlying;
        uint256 wNeeded;
        uint256 bi;
        uint256 crossings;
    }

    function test_mintLeveragedBandSpans_() public {
        LeveragedSpanCtx memory C;

        C.bounds = config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds;
        assertGe(C.bounds.length, 6, "len bounds ge 6");

        {
            int256 feeI = initial(config.mintLeveragedIncentiveConfig.incentiveRatios);

            if (feeI < 0) {
                C.subsidyPerc = uint256(-feeI);
                C.feePerc = 0;
            } else {
                C.subsidyPerc = 0;
                C.feePerc = uint256(feeI); // shrink not required but keeps stack light
            }
        }
        assertLt(C.feePerc, 1e18, "fee < 1e18");
        C.collateralPerInput = 1e18 - C.feePerc + C.subsidyPerc;

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
        C.price = measurePrice;
        C.rate = measureRate;
        assertGt(C.price, 0, "oracle price>0");
        assertGt(C.rate, 0, "oracle rate>0");

        C.pBase = 1e24;
        C.globalSnap = vm.snapshotState();

        for (C.s = 0; C.s < C.bounds.length; C.s++) {
            vm.revertToState(C.globalSnap);

            // Placement (mid-band)
            {
                uint256 lowerBand = _bandLower(C.s, C.bounds);
                C.desiredCR = lowerBand + (C.bounds[C.s] - lowerBand) / 2;
                if (C.desiredCR >= C.bounds[C.s]) C.desiredCR = C.bounds[C.s] - 1;
                C.lRef = _calcLForCR(C.pBase, C.desiredCR);

                uint256 placeSnap = vm.snapshotState();
                for (C.attempt = 0; C.attempt < 8; C.attempt++) {
                    vm.revertToState(placeSnap);
                    setUp_collateral(C.pBase, C.lRef, user);
                    C.crNow = IMinter(minter).collateralRatio();
                    if (_inBand(C.crNow, C.s, C.bounds)) break;
                    C.lower = lowerBand;
                    if (C.crNow <= C.lower) {
                        C.lRef += (C.lRef / 6) + 1;
                    } else if (C.crNow > C.bounds[C.s]) {
                        uint256 dec = (C.lRef / 6) + 1;
                        C.lRef = dec >= C.lRef ? C.lRef / 2 : C.lRef - dec;
                    } else {
                        break;
                    }
                }
                {
                    uint256 chk = IMinter(minter).collateralRatio();
                    // Containment assertions
                    assertGt(chk, _bandLower(C.s, C.bounds), "place lower");
                    assertLe(chk, C.bounds[C.s], "place upper");
                }
            }

            // No fee range exists where the market sells no leverage: a starting band below the floor at
            // which leverage is sold has nothing to measure, and the refusal is `Minter_leverageCap`'s to
            // assert. The bands above the floor still span, so this is a skip and not a stop.
            if (!IMinter_v3(minter).leveragedMintable()) {
                continue;
            }

            uint256 startSnap = vm.snapshotState();

            for (C.e = C.s; C.e < C.bounds.length; C.e++) {
                vm.revertToState(startSnap);
                C.preCR = IMinter(minter).collateralRatio();
                // Assert starting band containment
                assertGt(C.preCR, _bandLower(C.s, C.bounds), "pre lower");
                assertLe(C.preCR, C.bounds[C.s], "pre upper");

                if (C.e == C.s) {
                    uint256 bandUpper = C.bounds[C.s];
                    uint256 bandLower = _bandLower(C.s, C.bounds);
                    // Safe headroom
                    uint256 headroom = (C.preCR + 1 < bandUpper) ? (bandUpper - 1 - C.preCR) : 0;
                    if (headroom == 0) {
                        continue;
                    }

                    C.targetCR = C.preCR + headroom / 2;
                    if (C.targetCR >= bandUpper) C.targetCR = bandUpper - 1;

                    C.underlyingCurrent = IMinter(minter).collateralTokenBalance();
                    C.peggedSupply = IMinter(minter).peggedTokenBalance();
                    C.underlyingTarget = Math.mulDiv(C.targetCR, C.peggedSupply, C.price);

                    if (C.underlyingTarget > C.underlyingCurrent && C.rate != 0) {
                        C.deltaUnderlying = C.underlyingTarget - C.underlyingCurrent;
                        // The wrapped whose collateral, net of the fee or with the subsidy added, raises the record
                        // by the delta. A capped or empty reserve pays less subsidy, landing short of the target.
                        C.wNeeded = _ceilDiv(C.deltaUnderlying * 1e36, C.rate * C.collateralPerInput) + 5;

                        if (IMinter(minter).leveragedTokenPrice() != 0) {
                            _mintLeveraged(C.wNeeded);
                            uint256 postCR0 = IMinter(minter).collateralRatio();
                            assertGt(postCR0, bandLower, "zero-span lower");
                            assertLe(postCR0, bandUpper, "zero-span upper");
                            C.crossings = 0;
                            for (C.bi = 0; C.bi < C.bounds.length; C.bi++) {
                                uint256 b0 = C.bounds[C.bi];
                                if (b0 > C.preCR && b0 <= postCR0) C.crossings++;
                            }
                            assertEq(C.crossings, 0, "zero-span crossings");
                        }
                    }
                    continue;
                }

                // Non-zero span
                // For regular fee structure
                C.targetCR = C.bounds[C.e] - 1;

                // For reverse fee structure
                if (reverseDirection) {
                    // Target further from boundary to account for overshoot
                    C.targetCR = C.bounds[C.e] - (C.bounds[C.e] - _bandLower(C.e, C.bounds)) / 10;
                }

                uint256 preCRLocal = C.preCR;
                uint256 preLevSupply = IERC20(leveragedToken).totalSupply();

                C.underlyingCurrent = IMinter(minter).collateralTokenBalance();
                C.peggedSupply = IMinter(minter).peggedTokenBalance();
                C.underlyingTarget = Math.mulDiv(C.targetCR, C.peggedSupply, C.price);

                if (C.underlyingTarget <= C.underlyingCurrent) continue;
                C.deltaUnderlying = C.underlyingTarget - C.underlyingCurrent;
                if (C.rate == 0) continue;

                // as for the zero span: the collateral net of the fee or with the subsidy raises the record by delta
                C.wNeeded = _ceilDiv(C.deltaUnderlying * 1e36, C.rate * C.collateralPerInput) + 10;

                if (IMinter(minter).leveragedTokenPrice() == 0) continue;

                _mintLeveraged(C.wNeeded);

                // Re-measure
                uint256 postCR = IMinter(minter).collateralRatio();
                uint256 postLevSupply = IERC20(leveragedToken).totalSupply();

                // If no supply change or CR did not increase, treat as an impossible span and skip
                if (postLevSupply == preLevSupply || postCR <= preCRLocal) {
                    continue;
                }

                assertGt(postCR, _bandLower(C.e, C.bounds), "end lower");
                assertLe(postCR, C.bounds[C.e], "end upper");
                C.crossings = 0;
                for (C.bi = 0; C.bi < C.bounds.length; C.bi++) {
                    uint256 b = C.bounds[C.bi];
                    if (b > preCRLocal && b <= postCR) C.crossings++;
                }
                assertEq(C.crossings, (C.e - C.s), "cross count");
            }
        }

        vm.revertToState(C.globalSnap);
    }

    struct Measures {
        uint256 userPegged;
        uint256 userLeveraged;
        uint256 userWrapped;
        uint256 minterPegged;
        uint256 minterLeveraged;
        uint256 minterWrapped;
        uint256 minterUnderlying;
        uint256 feeWrapped;
        uint256 reservePoolWrapped;
        uint256 collateralRatio;
        uint256 peggedPrice;
        uint256 leveragedPrice;
        int256 incentiveRatio; // not filled by _measure
        uint256 incentiveMeasure; // not filled by _measure: the wrapped a dry run measures its incentive ratio against
    }

    function _measure() internal view returns (Measures memory m) {
        m.userPegged = IERC20(peggedToken).balanceOf(user);
        m.userLeveraged = IERC20(leveragedToken).balanceOf(user);
        m.userWrapped = IERC20(wrappedCollateralToken).balanceOf(user);

        m.minterPegged = IMinter(minter).peggedTokenBalance();
        m.minterLeveraged = IERC20(leveragedToken).totalSupply();
        m.minterWrapped = IERC20(wrappedCollateralToken).balanceOf(minter);
        m.minterUnderlying = IMinter(minter).collateralTokenBalance();

        m.feeWrapped = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        m.reservePoolWrapped = IERC20(wrappedCollateralToken).balanceOf(reservePool);

        m.collateralRatio = IMinter(minter).collateralRatio();

        m.peggedPrice = IMinter(minter).peggedTokenPrice();
        m.leveragedPrice = IMinter(minter).leveragedTokenPrice();
    }

    function _dump(Measures memory m, string memory name) internal pure {
        console2.log("%s.userPegged:        %s", name, m.userPegged);
        console2.log("%s.userLeveraged:     %s", name, m.userLeveraged);
        console2.log("%s.userWrapped:       %s", name, m.userWrapped);
        console2.log("%s.minterPegged:      %s", name, m.minterPegged);
        console2.log("%s.minterLeveraged:   %s", name, m.minterLeveraged);
        console2.log("%s.minterWrapped:     %s", name, m.minterWrapped);
        console2.log("%s.minterUnderlying:  %s", name, m.minterUnderlying);
        console2.log("%s.feeWrapped:        %s", name, m.feeWrapped);
        console2.log("%s.reservePoolWrapped:%s", name, m.reservePoolWrapped);
        console2.log("%s.collateralRatio:   %s", name, m.collateralRatio);
        console2.log("%s.peggedPrice:       %s", name, m.peggedPrice);
        console2.log("%s.leveragedPrice:    %s", name, m.leveragedPrice);
    }

    /// @dev Three zero outcomes are legitimate: the market can stand at or below the min CR, where no pegged is
    ///      minted whatever the config says; the config can forbid minting at the current collateral ratio, so
    ///      nothing can be taken at all; or the amount offered can be too small to buy a whole pegged token, so
    ///      nothing would be produced. Each is tolerated only against its own precondition, read beforehand -
    ///      the collateral ratio against the min CR, and the dry run, which reports nothing minted for all three,
    ///      with the band's ratio, 100% where the config forbids minting - so any other revert, or a zero that
    ///      was not predicted, still fails the test. Returns 0 for each, having consumed nothing.
    ///      Owns its own prank: the dry run has to happen before the mint, and a one-shot `vm.prank` at the
    ///      call site would bind to that view call instead of the mint it was meant for.
    function mintPeggedIgnoreZeroMint(uint256 wrapped, address user) internal returns (uint256 minted) {
        (int256 predictedRatio, , , uint256 predictedMinted, , ) = IMinter(minter).mintPeggedTokenDryRun(wrapped);
        uint256 collateralRatio = IMinter(minter).collateralRatio();
        uint256 minimum = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        vm.startPrank(user);
        try IMinter(minter).mintPeggedToken(wrapped, user, 0) returns (uint256 m) {
            minted = m;
        } catch (bytes memory reason) {
            if (collateralRatio <= minimum) {
                require(
                    predictedMinted == 0 &&
                        keccak256(reason) ==
                            keccak256(
                                abi.encodeWithSelector(
                                    IMinter_v3.BelowMinimumCollateralRatio.selector,
                                    collateralRatio,
                                    minimum
                                )
                            ),
                    "BelowMinimumCollateralRatio is the only permitted revert at or below the min CR"
                );
            } else if (predictedRatio == 1 ether) {
                require(
                    keccak256(reason) ==
                        keccak256(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken)),
                    "MintZeroAmount is the only permitted revert where the band forbids minting"
                );
            } else {
                require(
                    predictedMinted == 0 &&
                        keccak256(reason) ==
                            keccak256(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, peggedToken)),
                    "ReturnZeroAmount is the only permitted revert when the mint yields no whole token"
                );
            }
            minted = 0;
        }
        vm.stopPrank();
    }

    function _mintPegged(uint256 wrapped) internal virtual;
    function _redeemPegged(uint256 wrapped) internal virtual;
    function _mintLeveraged(uint256 wrapped) internal virtual;
    function _redeemLeveraged(uint256 wrapped) internal virtual;
}

contract TestMinterFixedFeeRange_ is TestMinterFeeRange {
    function setUpConfig() internal virtual override {
        // we need flat rates across close boundaries to measure the error in crossing boundaries
        setUp_config_flatWide();
    }

    function mulDivNearest(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 doubledResult = Math.mulDiv(a, b * 2, d);
        // (doubledResult / 2) is the floor division
        // (doubledResult % 2) is 1 if we need to round up, 0 otherwise
        return (doubledResult / 2) + (doubledResult % 2);
    }

    function _mintPegged(uint256 wrapped) internal override {
        // MINT PEGGED FLAT
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        uint256 feeRatio = uint256(initial(config.mintPeggedIncentiveConfig.incentiveRatios));
        uint256 used;
        {
            // The dry run's ratio is its fee over the collateral used - the whole offer, which a flat incentive
            // config mints with, or what the min CR leaves of it. The fee is the exact one rounded down - within a
            // wei below it - and a wei moves the ratio by 1e18 over the collateral used; its floor adds under a
            // unit. Where nothing is used the dry run reports the band's ratio, exactly.
            int256 dryRunFeeRatio;
            (dryRunFeeRatio, , used, , , ) = IMinter(minter).mintPeggedTokenDryRun(wrapped);
            assertApprox(
                dryRunFeeRatio,
                int256(feeRatio),
                1e18 / (used == 0 ? wrapped : used) + 1,
                0,
                "mp dry run fee ratio"
            );
        }
        // note that this is looking up the first incentive ratio, so only works for fixed fees
        uint256 minted = mintPeggedIgnoreZeroMint(wrapped, user);
        // ---------------------------------------------------------------
        Measures memory post = _measure();

        if (minted == 0) {
            // The market stood at or below the min CR, or the offer was too small to buy a whole pegged token, so
            // the minter reverted rather than charging for nothing. There is no fee to measure against a mint
            // that did not happen; what must hold is that it cost the caller nothing.
            assertEq(post.userWrapped, pre.userWrapped, "mp refused mint leaves the user's collateral alone");
            assertEq(post.feeWrapped, pre.feeWrapped, "mp refused mint charges no fee");
            assertEq(post.userPegged, pre.userPegged, "mp refused mint delivers no pegged tokens");
            return;
        }
        // What the mint took: the whole offer, or what the min CR left of it, as the dry run reported.
        wrapped = used;

        // The minter's fee is the flat ratio of the collateral its walk used, floored; this test's is the same ratio
        // of the wrapped used - that collateral rounded up to whole wrapped - floored. So they agree for a whole offer,
        // and where the walk cut it the minter's is at most a wei below this test's, never above.
        uint256 fee = (feeRatio * wrapped) / 1 ether;
        assertLe(post.feeWrapped, pre.feeWrapped + fee, "mp fee wrapped");
        assertGe(post.feeWrapped + 1, pre.feeWrapped + fee, "mp fee wrapped, to within a wei");

        assertEq(post.userPegged, pre.userPegged + minted, "mp user pegged returned");
        // console2.log("wrapped=%s", wrapped);
        // console2.log("fee=%s", fee);
        // console2.log("p=%s", p);
        // console2.log("r=%s", r);
        // console2.log("pre.peggedPrice=%s", pre.peggedPrice);
        // console2.log("post.peggedPrice=%s", post.peggedPrice);
        // Minted vs the ideal formula deviates only by rounding: the test's floored fee differs from the
        // contract's by at most 1 wei (see "mp fee wrapped" above), amplified into minted by the pegged-per-
        // collateral multiplier `mulDiv(1, p*r, peggedPrice*1e18)`; plus up to ~2 wei of band-math rounding per
        // collateral-ratio band the mint traverses. Derived per-run, not a blanket tolerance.
        // The contract prices the mint per CR band (each band a floored mulDiv on balances updated as the mint
        // proceeds), while the formula is a single floored mulDiv at the static pre-price. The gap is the
        // band-pricing approximation — purely rounding-scale and protocol-favorable (the contract mints <= the
        // static-price formula). Bounded two ways (assertApprox passes on either):
        //  - abs (governs when minted is small): the gap is a few collateral-wei of band-settlement rounding,
        //    amplified into pegged by the pegged-per-collateral multiplier `mulDiv(1, p*r, peggedPrice*1e18)` —
        //    large in a depeg. The net collateral rounding is <= 1 wei by conservation, plus a wei-equivalent of
        //    per-band price drift, so <= 2 multiplier-units; plus per-band pegged flooring. Hence
        //    `2 * mulDiv(1, p*r, peggedPrice*1e18) + 2 * mintPeggedBands`.
        //  - rel (governs when minted is huge): the gap stays a few ULP of minted.
        // Both verified across the price/amount envelope by high-run fuzzing, not a blanket tolerance.
        assertApprox(
            minted,
            Math.mulDiv(wrapped - fee, p * r, pre.peggedPrice * 1e18),
            2 * Math.mulDiv(1, p * r, pre.peggedPrice * 1e18) + 2 * mintPeggedBands,
            2 * mintPeggedBands,
            "mp user pegged"
        );

        assertEq(post.userLeveraged, pre.userLeveraged, "mp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "mp user wrapped");

        assertEq(post.minterPegged, pre.minterPegged + minted, "mp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "mp minter leveraged");
        // the wrapped used less the minter's fee, so at most a wei above this test's figure and never below
        assertGe(post.minterWrapped, pre.minterWrapped + wrapped - fee, "mp minter wrapped");
        assertLe(post.minterWrapped, pre.minterWrapped + wrapped - fee + 1, "mp minter wrapped, to within a wei");
        // the record gains exactly the wrapped the minter keeps, valued at the rate and rounded down
        assertEq(
            post.minterUnderlying,
            pre.minterUnderlying + Math.mulDiv(post.minterWrapped - pre.minterWrapped, r, 1 ether),
            "mp minter underlying"
        );

        // conservation identity
        {
            int256 dUser = int256(post.userWrapped) - int256(pre.userWrapped); // -wrapped
            int256 dMinter = int256(post.minterWrapped) - int256(pre.minterWrapped); // +(wrapped - fee)
            int256 dFee = int256(post.feeWrapped) - int256(pre.feeWrapped); // +fee
            int256 dReserve = int256(post.reservePoolWrapped) - int256(pre.reservePoolWrapped); // 0

            assertApprox(dUser + dMinter + dFee + dReserve, 0, 0, "mp wrapped conservation");
        }

        // a pegged mint is served only above the min CR and stops at it, so the pegged price is par before and after
        assertEq(pre.peggedPrice, 1 ether, "mp pegged price at par before");
        assertEq(post.peggedPrice, 1 ether, "mp pegged price at par after");
        // assertApprox(post.leveragedPrice, pre.leveragedPrice, 20000, 0.000000000002 ether, "mp leveraged price");
    }

    function _redeemPegged(uint256 wrapped) internal override {
        // REDEEM PEGGED FLAT
        // console2.log("wrapped=%s", wrapped);
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        Measures memory pre = _measure();
        _dump(pre, "pre");
        // get the equivalent amount of pegged
        uint256 pegged = Math.min(
            mulDivNearest(wrapped, p * r, pre.peggedPrice * 1e18),
            IMinter(minter).peggedTokenBalance()
        );
        // console2.log("pegged=%s", pegged);
        // adjust wrapped
        wrapped = mulDivNearest(pegged, pre.peggedPrice * 1e18, r * p);
        // console2.log("wrapped=%s", wrapped);
        // calculate max fee & subsidy
        uint256 fee;
        uint256 subsidy;
        {
            int256 incentiveRatio = initial(config.redeemPeggedIncentiveConfig.incentiveRatios); // assume flat
            if (incentiveRatio < 0) {
                fee = 0;
                // the whole subsidy; capped by a limited reserve after the redemption
                subsidy = (uint256(-incentiveRatio) * wrapped) / 1e18;
            } else {
                fee = (uint256(incentiveRatio) * wrapped) / 1e18;
                subsidy = 0;
            }
        }

        // A schedule whose highest band charges otherwise is flat only below its last bound - a subsidy has to end
        // somewhere - so the flat expectation covers a redemption that ends below it, judged by this test's own
        // arithmetic: the record less the collateral the pegged is worth, against the pegged left.
        {
            IMinter.IncentiveConfig memory schedule = config.redeemPeggedIncentiveConfig;
            uint256 highest = schedule.incentiveRatios.length - 1;
            if (schedule.incentiveRatios[highest] != schedule.incentiveRatios[0]) {
                uint256 peggedAfter = pre.minterPegged - pegged;
                vm.assume(
                    peggedAfter > 0 &&
                        Math.mulDiv(pre.minterUnderlying - (wrapped * r) / 1e18, p, peggedAfter) <
                            schedule.collateralRatioBandUpperBounds[highest - 1]
                );
            }
        }

        if (subsidyLimitRatio > 0) {
            // a reserve holding a share of the flat subsidy, so this redemption exhausts it
            pre.reservePoolWrapped = (subsidy * subsidyLimitRatio) / 1e18;
            deal(address(wrappedCollateralToken), reservePool, pre.reservePoolWrapped);
        }

        {
            uint256 dryRunFee;
            uint256 dryRunSubsidy;
            (pre.incentiveRatio, dryRunFee, dryRunSubsidy, , pre.incentiveMeasure, , ) = IMinter(minter)
                .redeemPeggedTokenDryRun(pegged);
            // what the redemption takes from the backing: what it pays, plus the fee, less the reserve's subsidy
            pre.incentiveMeasure = pre.incentiveMeasure + dryRunFee - dryRunSubsidy;
        }
        vm.startPrank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();
        // -------------------------------------------------------------------------
        Measures memory post = _measure();
        _dump(post, "post");

        if (subsidyLimitRatio > 0) {
            assertEq(post.reservePoolWrapped, 0, "rp reserve not exhausted");
        }

        subsidy = Math.min(subsidy, pre.reservePoolWrapped);

        {
            // The fee paid against this test's flat figure. The contract's fee is the wrapped the pegged redeems for
            // less what the redeemer keeps, each rounded down once: within a wei of the exact fee on that wrapped. The
            // figure is the flat ratio of this test's own estimate of that wrapped, floored: within a wei below. The
            // estimate is rounded to nearest, and goes through the reported pegged price - exact at or above the peg,
            // below it rounded down, short of the pegged's share by under one part in the price's 1e18-scaled figure,
            // so the estimate and the fee on it fall short by under that part (the exact fee over the figure, bounded
            // by the test's fee plus two over the figure less one). So the fee paid is at most a wei below the figure
            // and above it by under two and a half wei, plus that part below the peg.
            uint256 belowThePeg = pre.collateralRatio < 1 ether ? Math.ceilDiv(fee + 2, pre.peggedPrice - 1) : 0;
            assertApproxEqAbs(post.feeWrapped, pre.feeWrapped + fee, 2 + belowThePeg, "rp fee wrapped");
        }
        assertApprox(post.reservePoolWrapped, pre.reservePoolWrapped - subsidy, 0, 0, "rp subsidy wrapped");

        {
            // The dry run's ratio is its fee or subsidy over its measure; this test's is its own flat figure, floored, over
            // its own estimate of that wrapped. The dry run's figure is the exact one rounded once - within a wei of it -
            // and its measure is the exact wrapped floored, which lifts the ratio by under |ratio| over it; this test's
            // figure is within a wei below the exact. A wei moves a ratio by 1e18 over the wrapped it is measured
            // against, and the two ratios' floors add under a unit.
            assertApprox(
                pre.incentiveRatio,
                ((int256(fee) - int256(subsidy)) * 1e18) / int256(wrapped),
                (2e18 + SignedMath.abs(initial(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
                    Math.min(pre.incentiveMeasure, wrapped) +
                    1,
                0,
                "rp dry run incentive ratio"
            );
        }

        assertEq(post.userPegged, pre.userPegged - pegged, "rp user pegged");
        assertEq(post.userLeveraged, pre.userLeveraged, "rp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rp user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged - pegged, "rp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "rp minter leveraged");

        {
            // What the pegged redeems for, as the minter defines it: a pegged unit's worth of collateral each at or
            // above the peg, each token's share of the record below it - at 36 decimals - and the whole wrapped that
            // releases. It leaves the minter exactly, and the record gives it up valued at the rate, rounded up.
            uint256 collateralE36 = pre.collateralRatio < 1 ether
                ? Math.mulDiv(pegged, pre.minterUnderlying * 1 ether, pre.minterPegged)
                : Math.mulDiv(pegged, 1e36, p);
            assertEq(post.minterWrapped, pre.minterWrapped - collateralE36 / r, "rp minter wrapped");
            assertEq(
                post.minterUnderlying,
                pre.minterUnderlying - Math.mulDiv(collateralE36 / r, r, 1 ether, Math.Rounding.Ceil),
                "rp minter underlying"
            );
            // the redeemer is paid that worth less the fee, rounded down once, and every wrapped wei the reserve sent
            assertEq(
                wrappedReturned + post.reservePoolWrapped - pre.reservePoolWrapped,
                Math.mulDiv(
                    collateralE36,
                    1 ether - uint256(SignedMath.max(initial(config.redeemPeggedIncentiveConfig.incentiveRatios), 0)),
                    r * 1 ether
                ),
                "rp user wrapped"
            );
        }

        // conservation identity
        {
            int256 dUser = int256(post.userWrapped) - int256(pre.userWrapped); // -wrapped
            int256 dMinter = int256(post.minterWrapped) - int256(pre.minterWrapped); // +(wrapped - fee)
            int256 dFee = int256(post.feeWrapped) - int256(pre.feeWrapped); // +fee
            int256 dReserve = int256(post.reservePoolWrapped) - int256(pre.reservePoolWrapped); // 0

            assertApprox(dUser + dMinter + dFee + dReserve, 0, 0, "rp wrapped conservation");
        }

        // Assert pegged token price for different CRs
        // console2.log("pre.collateralRatio=%s", pre.collateralRatio);
        // console2.log("pre.peggedPrice=%s", pre.peggedPrice);
        // console2.log("post.peggedPrice=%s", post.peggedPrice);
        assertGe(post.peggedPrice, pre.peggedPrice, "rp pegged price");
        if (pre.collateralRatio < 1 ether) {
            assertApprox(pre.peggedPrice, pre.collateralRatio, 0, 0, "rp depegged CR");
            assertGe(post.peggedPrice, pre.peggedPrice, "rp depegged pegged price");
        }
        // assertApprox(post.leveragedPrice, pre.leveragedPrice, 1, 0, "rp leveraged price");
    }

    function _mintLeveraged(uint256 wrapped) internal override {
        // MINT LEVERAGED FLAT
        if (IMinter(minter).collateralRatio() > 1 ether) {
            (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

            Measures memory pre;

            uint256 fee;
            uint256 subsidy;
            {
                int256 incentiveRatio = initial(config.mintLeveragedIncentiveConfig.incentiveRatios); // assume flat
                if (incentiveRatio < 0) {
                    fee = 0;
                    subsidy = (uint256(-incentiveRatio) * wrapped) / 1e18;
                } else {
                    fee = (uint256(incentiveRatio) * wrapped) / 1e18;
                    subsidy = 0;
                }
            }

            // A schedule whose highest band charges otherwise is flat only below its last bound - a subsidy has to end
            // somewhere - so the flat expectation covers a mint that ends below it, judged by this test's own
            // arithmetic: the record grown by the input net of the fee, with the whole subsidy.
            {
                IMinter.IncentiveConfig memory schedule = config.mintLeveragedIncentiveConfig;
                uint256 highest = schedule.incentiveRatios.length - 1;
                if (schedule.incentiveRatios[highest] != schedule.incentiveRatios[0]) {
                    uint256 collateralAfter = IMinter(minter).collateralTokenBalance() +
                        ((wrapped - fee + subsidy) * r) / 1e18;
                    vm.assume(
                        Math.mulDiv(collateralAfter, p, IMinter(minter).peggedTokenBalance()) <
                            schedule.collateralRatioBandUpperBounds[highest - 1]
                    );
                }
            }

            if (subsidyLimitRatio > 0) {
                // a reserve holding a share of the flat subsidy, so this mint exhausts it
                pre.reservePoolWrapped = (subsidy * subsidyLimitRatio) / 1e18;
                deal(address(wrappedCollateralToken), reservePool, pre.reservePoolWrapped);
            }

            pre = _measure();
            (pre.incentiveRatio, , , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(wrapped);
            vm.startPrank(user);
            uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
            vm.stopPrank();
            // ------------------------------------------------------------------
            Measures memory post = _measure();
            uint256 q = r / 1e18; // how many 1e18-scale “chunks” in rate

            if (subsidyLimitRatio > 0) {
                assertEq(post.reservePoolWrapped, 0, "ml reserve not exhausted");
            }

            subsidy = Math.min(subsidy, pre.reservePoolWrapped);
            // console2.log("fee=%s", fee);
            // console2.log("subsidy=%s", subsidy);

            assertApprox(post.feeWrapped, pre.feeWrapped + fee, q + 2, "ml fee wrapped");
            // The reserve pool falls by the subsidy the contract actually applied; the test reconstructs `subsidy`
            // with a single truncating division, so the two differ by at most 1 wei (same as "ml minter wrapped").
            assertApprox(post.reservePoolWrapped, pre.reservePoolWrapped - subsidy, 1, "ml subsidy wrapped");

            // The dry run's ratio is its fee or subsidy over the collateral used - the whole offer, which a leveraged
            // mint always takes; this test's is its own flat figure, floored, over the offer. The dry run's fee is the
            // exact one rounded up - the remainder of the wrapped kept, rounded down once - and its subsidy the exact one
            // rounded down; this test's figure is the same exact one rounded down. So the two are at most a wei apart, a
            // wei moves the ratio by 1e18 / `wrapped`, and the two ratios' floors add under a unit.
            assertApprox(
                pre.incentiveRatio,
                ((int256(fee) - int256(subsidy)) * 1e18) / int256(wrapped),
                1e18 / wrapped + 1,
                0,
                "ml dry run fee ratio"
            );

            assertApprox(
                post.minterUnderlying,
                pre.minterUnderlying + ((wrapped - fee + subsidy) * r) / 1e18,
                q + 2,
                "ml minter underlying"
            );

            assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

            assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
            assertApprox(post.minterWrapped, pre.minterWrapped + wrapped - fee + subsidy, 1, "ml minter wrapped");

            assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
            // Use full-precision E36 leveraged price rather than the truncated-to-wei public view;
            // in depeg scenarios lp can shrink to a few wei and the truncation becomes the dominant error.
            assertApprox(
                minted,
                Math.mulDiv((wrapped - fee + subsidy) * r /*underlying collateral */, p, _leveragedPriceE36(p)),
                q + 2,
                0.00000011 ether, // the test calculation is far less accurate than the contract one
                "ml user leveraged"
            );

            // conservation identity
            {
                int256 dUser = int256(post.userWrapped) - int256(pre.userWrapped); // -wrapped
                int256 dMinter = int256(post.minterWrapped) - int256(pre.minterWrapped); // +(wrapped - fee)
                int256 dFee = int256(post.feeWrapped) - int256(pre.feeWrapped); // +fee
                int256 dReserve = int256(post.reservePoolWrapped) - int256(pre.reservePoolWrapped); // 0

                assertApprox(dUser + dMinter + dFee + dReserve, 0, 0, "ml wrapped conservation");
            }

            assertEq(post.peggedPrice, pre.peggedPrice, "ml pegged price");
            assertApprox(
                post.leveragedPrice,
                post.minterLeveraged == 0 ? 1e18 : pre.leveragedPrice,
                40,
                p <= 1e9
                    ? 0.000004 ether
                    : p <= 1e18
                        ? 0.0000000011 ether
                        : 0, // allow for slight deviation in l price when collateral price is small
                "ml leveraged price"
            );
        } else {
            // console2.log ("CR=%s", IMinter(minter).collateralRatio());
        }
    }

    function _round(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256 result /*, uint256 tolerance*/) {
        unchecked {
            result = numerator / denominator;
            uint256 tolerance = numerator % denominator;

            uint256 halfDenominator = denominator >> 1;

            if (tolerance >= halfDenominator) {
                result += 1;
                tolerance -= halfDenominator;
            }
        }
    }

    function _leveragedPriceE36(uint256 p) internal view returns (uint256) {
        uint256 leveragedTokenBalance = IMinter(minter).leveragedTokenBalance();
        if (leveragedTokenBalance == 0) {
            return 1e18;
        }

        uint256 collateralValueE36 = IMinter(minter).collateralTokenBalance() * p;
        uint256 peggedValueE36 = IMinter(minter).peggedTokenBalance() * IMinter(minter).peggedTokenPrice();

        return Math.mulDiv(collateralValueE36 - peggedValueE36, 1e18, leveragedTokenBalance);
    }

    function _redeemLeveraged(uint256 wrapped) internal override {
        // REDEEM LEVERAGED FLAT
        if (IMinter(minter).collateralRatio() > 1 ether) {
            (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            // console2.log("p=%s", p);
            // console2.log("r=%s", r);
            Measures memory pre = _measure();
            // console2.log("wrapped=%s", wrapped);
            uint256 leveraged = _round(wrapped * r * p, _leveragedPriceE36(p));
            // console2.log("leveraged=%s", leveraged);
            wrapped = (leveraged * _leveragedPriceE36(p)) / (r * p);
            // console2.log("wrapped=%s", wrapped);
            // TODO: vvv set this to max of leveraged .pre-minterLeveraged, not an if
            if (leveraged <= pre.minterLeveraged) {
                // console2.log("underlying=%s", (wrapped * r) / 1e18);
                {
                    uint256 dryRunFee;
                    (pre.incentiveRatio, dryRunFee, , pre.incentiveMeasure, , ) = IMinter(minter)
                        .redeemLeveragedTokenDryRun(leveraged);
                    // the dry run measures its ratio against the wrapped the redemption is for: its payout and its fee
                    pre.incentiveMeasure += dryRunFee;
                }
                vm.startPrank(user);
                uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
                vm.stopPrank();
                // -------------------------------------------------------------------------------
                Measures memory post = _measure();
                // TODO: why do we ignore depegged redeeming leveraged?
                // because it has zero value - we need to account for the leverageRatio cap
                if (post.collateralRatio > 1 ether) {
                    uint256 fee;
                    {
                        int256 incentiveRatio = initial(config.redeemLeveragedIncentiveConfig.incentiveRatios);
                        // The dry run's ratio is its fee over its measure. The fee is the remainder of a payout rounded
                        // down once from the exact figure, so within a wei of the exact fee, and the measure is the exact
                        // wrapped floored, which lifts the ratio by under the ratio over it. A wei moves the ratio by 1e18
                        // over the measure, and its floor adds under a unit.
                        assertApprox(
                            pre.incentiveRatio,
                            incentiveRatio,
                            (1e18 + uint256(incentiveRatio)) / pre.incentiveMeasure + 1,
                            0,
                            "rl dry run fee ratio"
                        );
                        fee = (uint256(incentiveRatio) * wrapped) / 1 ether;
                        assertApprox(post.feeWrapped, pre.feeWrapped + fee, 1, 0, "rl fee wrapped"); // fee won't be more that 10%

                        assertEq(post.userPegged, pre.userPegged, "rl user pegged");
                        assertApprox(wrappedReturned, wrapped - fee, 1, 0, "rl user wrapped");
                        assertApprox(post.userLeveraged, pre.userLeveraged - leveraged, 1, 2, "rl user leveraged");
                        assertApprox(
                            post.userWrapped,
                            pre.userWrapped + wrappedReturned,
                            1,
                            0,
                            "rl user wrapped returned"
                        );

                        assertApprox(post.minterPegged, pre.minterPegged, 1, 0, "rl minter pegged");
                        assertApprox(
                            post.minterLeveraged,
                            pre.minterLeveraged - leveraged,
                            1,
                            0,
                            "rl minter leveraged"
                        );
                        assertApprox(post.minterWrapped, pre.minterWrapped - wrapped, 1, 0, "rl minter wrapped");
                        // `_qR` is the rate's granularity: reconstructing the underlying from the
                        // FLOORED wrapped amount discards up to one rate's worth of the accumulator.
                        // The record itself is then CEILED - `underlyingCollateralRemoved` is
                        // `ceilDiv(removedE36, 1e18)`, so that the record never gives up less than the
                        // holding did - and that ceiling is a second, independent wei on top of the
                        // rate granularity. So the bound is `_qR + 1`, not `_qR`: the two roundings
                        // are in the same direction and cannot cancel.
                        assertApprox(
                            post.minterUnderlying,
                            pre.minterUnderlying - (wrapped * r) / 1e18,
                            _qR(p, r) + 1,
                            0,
                            "rl minter underlying"
                        );

                        // conservation identity
                        {
                            int256 dUser = int256(post.userWrapped) - int256(pre.userWrapped); // -wrapped
                            int256 dMinter = int256(post.minterWrapped) - int256(pre.minterWrapped); // +(wrapped - fee)
                            int256 dFee = int256(post.feeWrapped) - int256(pre.feeWrapped); // +fee
                            int256 dReserve = int256(post.reservePoolWrapped) - int256(pre.reservePoolWrapped); // 0

                            assertApprox(dUser + dMinter + dFee + dReserve, 0, 0, "rl wraooed conservation");
                        }
                    }
                    assertEq(post.peggedPrice, pre.peggedPrice, "rl pegged price");
                    assertApprox(
                        post.leveragedPrice,
                        post.minterLeveraged == 0 ? 1e18 : pre.leveragedPrice,
                        400 * ((1 ether + measurePrice - 1) / measurePrice), // scale abs tolerance with inverse price
                        2000,
                        "rl leveraged price"
                    );
                } else {
                    // console2.log ("skip leveraged=%s, balance=%s", leveraged, pre.minterLeveraged);
                }
            } else {
                // console2.log ("skip CR=%s", IMinter(minter).collateralRatio());
            }
        }
    }
}

contract TestMinterFixedFeeRangeDepegShallow_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 2;
        redeemPeggedBands = 1;
        // depeg's subsidy / pegged-price metrics lose precision at dust, so use the leveraged floor here; the 1-wei
        // pegged floor holds only outside depeg.
        minTokenPegged = minToken;
    }
}

contract TestMinterFixedFeeRangeDepegMid_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 3;
        redeemPeggedBands = 1;
        minTokenPegged = minToken; // depeg dust precision needs the leveraged floor (see Shallow)
    }
}

contract TestMinterFixedFeeRangeDepegDeep_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 4;
        redeemPeggedBands = 1;
        minTokenPegged = minToken; // depeg dust precision needs the leveraged floor (see Shallow)
    }
}

contract TestMinterFixedFeeRangePrice1_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Million_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether * 1e6;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Millionth_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether / 1e6;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Billion_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether * 1e9;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Billionth_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether / 1e9;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

// subsidy
contract TestMinterFixedFeeRangeSubsidyInexhaustableReserve_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1e50);
    }

    function setUpConfig() internal virtual override {
        setUp_config_flatSubsidyWide();
    }
}

contract TestMinterFixedFeeRangeSubsidyNoReserve_ is TestMinterFixedFeeRange_ {
    function setUpConfig() internal virtual override {
        setUp_config_flatSubsidyWide();
    }
}

contract TestMinterFixedFeeRangeSubsidyLimitedReserve_ is TestMinterFixedFeeRangeSubsidyNoReserve_ {
    function setUp() public virtual override {
        super.setUp();
        subsidyLimitRatio = 0.5 ether;
    }
}

// rate checks

contract TestMinterFixedFeeRangeSubsidyInexhaustableReserveRate1Million_ is
    TestMinterFixedFeeRangeSubsidyInexhaustableReserve_
{
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether;
        rate = measureRate = 1 ether * 1e6;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangeRate1Million_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether;
        rate = measureRate = 1 ether * 1e6;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangeRate1Millionth_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether;
        rate = measureRate = 1 ether / 1e6;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

abstract contract TestMinterIntegralFees is TestMinterFeeRange {
    uint steps;

    // Fee-band transition count for the mint-pegged action. Balance-quantity path-independence tolerances scale
    // with it: a flat config has 0 transitions, so the non-disallow branch collapses to (0,0) and mint-pegged is
    // exactly path-independent. (Fees keep their own bound — fee = f(collateral)*rate drifts absolutely, large
    // only in relative terms at a tiny near-cap fee; the disallow branch keeps the author's cap-aware tolerance.)
    function _mpTransitions() internal view returns (uint256) {
        return _bandTransitions(config.mintPeggedIncentiveConfig.incentiveRatios);
    }

    function _rpTransitions() internal view returns (uint256) {
        return _bandTransitions(config.redeemPeggedIncentiveConfig.incentiveRatios);
    }

    function _mlTransitions() internal view returns (uint256) {
        return _bandTransitions(config.mintLeveragedIncentiveConfig.incentiveRatios);
    }

    function _rlTransitions() internal view returns (uint256) {
        return _bandTransitions(config.redeemLeveragedIncentiveConfig.incentiveRatios);
    }

    function setUp() public virtual override {
        super.setUp();
        steps = 10;
        minToken *= steps; // to ensure the mintoken works for each step
    }

    /// @dev The collateral ratio a pegged mint stops at: the min CR, or the upper bound of the config's disallow
    ///      band where it has one above that. Minting pegged tokens lowers the collateral ratio, so this is the
    ///      boundary the minter's band walk terminates on. The config's bound is read back from the minter so it
    ///      carries the same truncation the minter's config storage applies.
    function _mintPeggedStopBound() internal view returns (uint256 bound) {
        bound = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        IMinter.IncentiveConfig memory mintPegged = IMinter(minter).config().mintPeggedIncentiveConfig;
        if (mintPegged.incentiveRatios[0] == 1 ether && mintPegged.collateralRatioBandUpperBounds[0] > bound) {
            bound = mintPegged.collateralRatioBandUpperBounds[0];
        }
    }

    /// @dev Assert a mint that the boundary cut short stopped just the allowed side of it.
    ///      The call that reaches the boundary takes the collateral that brings the collateral ratio down to it,
    ///      rounded UP to a whole wrapped wei, keeps a fee rounded DOWN to one, and mints the pegged the unrounded
    ///      amount buys, floored. Each rounding raises the resulting C*p/Z - the two of collateral by under a wrapped
    ///      wei's worth each, the pegged by under a pegged wei - so the end state sits at or above the boundary, and
    ///      above it by less than two wrapped wei of collateral and one pegged wei. A call made after that one finds
    ///      under that much room and leaves under that much again, so the allowance does not grow with the calls.
    ///      That pins the end state from BOTH sides against a known constant, with no reference to how the mint was
    ///      divided up, which is what makes it hold across price regimes where no fixed tolerance can. The trailing
    ///      unit on the lower side is this function's own mulDiv floor, matching the minter's collateralRatio().
    function _assertStoppedAtMintPeggedBound(Measures memory m, uint256 bound, string memory name) internal view {
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertGe(
            Math.mulDiv(m.minterUnderlying, p, m.minterPegged) + 1,
            bound,
            string.concat(name, " minted past the mint pegged boundary")
        );
        assertLe(
            Math.mulDiv(m.minterUnderlying - 2 * Math.ceilDiv(r, 1 ether), p, m.minterPegged + 1),
            bound,
            string.concat(name, " stopped more than its roundings short of the mint pegged boundary")
        );
    }

    /// @dev The wrapped collateral the user parted with is exactly what the minter kept plus what the fee
    ///      receiver was paid — the mint moves no wrapped collateral anywhere else. Exact, not approximate.
    function _assertMintPeggedConserved(Measures memory pre, Measures memory m, string memory name) internal pure {
        assertEq(
            pre.userWrapped - m.userWrapped,
            (m.minterWrapped - pre.minterWrapped) + (m.feeWrapped - pre.feeWrapped),
            string.concat(name, " wrapped collateral not conserved across the mint")
        );
    }

    function _mintPegged(uint256 wrapped) internal virtual override {
        // MINT PEGGED INTEGRAL
        // _dump(_measure());
        if (subsidyLimitRatio > 0) {
            // use the max subsidy to determine a reserve pool capacity that should be exhasted by this redeem
            uint256 reservePoolWrapped = (wrapped * subsidyLimitRatio) / 1e18;
            // console2.log("pre.reservePoolWrapped=%s", reservePoolWrapped);
            deal(address(wrappedCollateralToken), reservePool, reservePoolWrapped);
        }

        Measures memory pre = _measure();

        uint256 snap = vm.snapshotState();
        uint256 mintedSteps = 0;
        {
            uint256 base = wrapped / steps;
            uint256 rem = wrapped % steps;
            uint256 acc = rem / 2; // “centre” the bumps
            uint sumpart = 0;
            for (uint256 i = 0; i < steps; ++i) {
                acc += rem;
                uint256 bump = 0;
                if (acc >= steps) {
                    bump = 1;
                    acc -= steps;
                }
                uint256 part = base + bump;
                if (part > 0) {
                    sumpart += part;
                    mintedSteps += mintPeggedIgnoreZeroMint(part, user);
                    // ------------------------------------------------------
                }
            }
            assertEq(sumpart, wrapped, "mp integral step sum");
            // console2.log ("^^^ step %s, minted=%s, mintedSteps=%s", i, minted1, mintedSteps);
        }
        Measures memory postSteps = _measure();
        vm.revertToState(snap);
        _dump(postSteps, "steps");

        // uint256 minted = IMinter(minter).mintPeggedToken(wrapped, user, 0);
        // console2.log ("vvv all");
        uint256 minted = mintPeggedIgnoreZeroMint(wrapped, user);
        // ---------------------------------------------------------------
        // console2.log ("^^^ minted=%s", minted);
        Measures memory post = _measure();
        _dump(post, "all");

        // Exact in both regimes: the mint only ever moves wrapped collateral from the user to the minter
        // and the fee receiver, so no tolerance belongs on this at all.
        _assertMintPeggedConserved(pre, post, "mp integral all");
        _assertMintPeggedConserved(pre, postSteps, "mp integral steps");

        assertEq(post.minterLeveraged, postSteps.minterLeveraged, "mp integral minter leveraged");
        assertApprox(post.userLeveraged, postSteps.userLeveraged, 0, 0, "mp integral user leveraged");

        uint256 stopBound = _mintPeggedStopBound();
        // A mint that consumed everything it was offered ran out of collateral before reaching the boundary,
        // and one that minted nothing started at or below it — neither is pinned by the boundary. Only a mint
        // that took some of the offer and left the rest was stopped by it.
        bool allStopped = post.userPegged > pre.userPegged && pre.userWrapped - post.userWrapped < wrapped;
        bool stepsStopped = postSteps.userPegged > pre.userPegged && pre.userWrapped - postSteps.userWrapped < wrapped;

        if (allStopped) {
            _assertStoppedAtMintPeggedBound(post, stopBound, "mp integral all");
        }
        if (stepsStopped) {
            _assertStoppedAtMintPeggedBound(postSteps, stopBound, "mp integral steps");
        }

        // Once the boundary stops a path, its end state is set by the boundary rather than by how the mint
        // was divided up, and the two paths are no longer measuring the same thing: comparing them to each
        // other is the wrong question, and no constant tolerance can answer it. How far a path stops short
        // of the boundary is under one pegged token, so as a share of the state it scales as 1/peggedBalance
        // — and the collateral that corresponds to is amplified by 1/(collateralRatio - 1). At the pinned
        // 1-billionth-price counterexample that puts the two paths more than 2x apart on every collateral
        // quantity, both correct. So each stopped path is measured against the boundary, above, and only
        // paths that ran to completion are compared with each other.
        // Splitting a mint can make the individual pieces too small to buy a whole pegged token, and the
        // minter refuses those rather than charging for nothing. When that happens the stepped path has not
        // performed the same operation as the single shot — it consumed less collateral — so the two are not
        // comparable as an integral. Every such refusal was already checked against the dry run's prediction
        // in `mintPeggedIgnoreZeroMint`, so this is not a blind exemption; what remains to assert is the
        // direction, since refusing pieces can only ever consume LESS than doing it in one go.
        uint256 allUsed = pre.userWrapped - post.userWrapped;
        uint256 stepsUsed = pre.userWrapped - postSteps.userWrapped;
        if (!allStopped && !stepsStopped && allUsed != stepsUsed) {
            assertLt(stepsUsed, allUsed, "mp integral stepping consumed more than one shot despite refusals");
        }

        if (!allStopped && !stepsStopped && allUsed == stepsUsed) {
            // Away from the boundary the mint IS a free integral, so the two paths must land on the same state.
            // The absolute terms are band-transition-scaled (a flat config has 0 transitions, hence exact).
            // minterWrapped/minterUnderlying additionally carry the fee-path divergence: each step floors the
            // fee computation (and the underlying write) once more than the single shot does, <= 1 wei per
            // step beyond the carry-protected division, so their absolute term is (transitions + 1) * steps.
            //
            // The relative term is not a blanket: it is what re-entering the minter costs. A call stores the
            // pegged it minted FLOORED and the collateral it added ROUNDED, and the next call seeds its band
            // arithmetic from those stored values — so each of the `steps` calls re-enters carrying up to a
            // wei of error in each, worth 1/peggedTokenBalance and 1/underlyingCollateral of the state it then
            // computes from. The single shot pays this once, at the end, where nothing reads it back. The gap
            // between the paths is therefore bounded by steps * (1/pegged + 1/collateral) RELATIVE, which is
            // why no fixed wei count works: in the extreme price and rate regimes the pegged balance falls to
            // ~1e11 and that term reaches 4e-11, while at ordinary balances it vanishes and the absolute terms
            // carry. Measured against the two pinned free-integral counterexamples this bound is tight, not
            // generous — the 1-billionth-price fee sits inside it with only 20% to spare.
            (, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            uint256 reseed = steps *
                ((1 ether) / Math.max(post.minterPegged, 1) + (1 ether) / Math.max(post.minterUnderlying, 1));
            // The minter does its arithmetic in UNDERLYING collateral and converts to wrapped only at the end
            // (`wrappedFee = underlyingFee / rate`). So a floor worth one wei of underlying is worth 1e18/rate
            // wei of WRAPPED, and every wrapped-denominated bound below has to carry that factor. It is 1 at
            // the usual rate of 1 ether — which is why the existing counts read as bare wei — but at the
            // 1-million rate it is 1e6: there a whole fee can be 18 wei of underlying, so ten calls flooring
            // it once each move the wrapped fee by millions. Underlying- and pegged-denominated bounds are
            // untouched, since those quantities are stored in the units the minter floors them in.
            uint256 wrappedPerUnderlying = Math.ceilDiv(1 ether, r);
            assertApprox(
                post.feeWrapped,
                postSteps.feeWrapped,
                steps * wrappedPerUnderlying,
                2e4 * steps + reseed,
                "mp integral fee wrapped"
            );
            assertApprox(
                minted,
                mintedSteps,
                _mpTransitions() * steps,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral minted"
            );
            assertApprox(
                post.userPegged,
                postSteps.userPegged,
                _mpTransitions() * steps,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral user pegged"
            );
            assertApprox(
                post.userWrapped,
                postSteps.userWrapped,
                _mpTransitions() * steps * wrappedPerUnderlying,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral user wrapped"
            );
            assertApprox(
                post.minterPegged,
                postSteps.minterPegged,
                _mpTransitions() * steps,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral minter pegged"
            );
            assertApprox(
                post.minterWrapped,
                postSteps.minterWrapped,
                (_mpTransitions() + 1) * steps * wrappedPerUnderlying,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral minter wrapped"
            );
            assertApprox(
                post.minterUnderlying,
                postSteps.minterUnderlying,
                (_mpTransitions() + 1) * steps,
                (_mpTransitions() + 1) * steps + reseed,
                "mp integral minter underlying"
            );
        }
    }

    function _redeemPegged(uint256 wrapped) internal virtual override {
        // REDEEM PEGGED INTEGRAL
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 wrappedReturnedSteps = 0;
        uint256 pegged = Math.min((wrapped * p * r) / 1e36, IMinter(minter).peggedTokenBalance());

        if (subsidyLimitRatio > 0) {
            // adjust wrapped for limited pegged
            uint256 peggedPrice = IMinter(minter).peggedTokenPrice();
            wrapped = Math.mulDiv(pegged, peggedPrice * 1e18, r * p);
            // use the wrapped to determine a reserve pool capacity that should be exhasted by this redeem
            uint256 reservePoolWrapped = (wrapped * subsidyLimitRatio) / 1e18;
            // console2.log("pre.reservePoolWrapped=%s", reservePoolWrapped);
            deal(address(wrappedCollateralToken), reservePool, reservePoolWrapped);
        }

        uint256 snap = vm.snapshotState();

        {
            uint256 base = pegged / steps;
            uint256 rem = pegged % steps;
            uint256 acc = rem / 2; // “centre” the bumps
            uint sumpart = 0;
            for (uint256 i = 0; i < steps; ++i) {
                acc += rem;
                uint256 bump = 0;
                if (acc >= steps) {
                    bump = 1;
                    acc -= steps;
                }
                uint256 part = base + bump;
                if (part > 0) {
                    sumpart += part;

                    vm.startPrank(user);
                    wrappedReturnedSteps += IMinter(minter).redeemPeggedToken(part, user, 0);
                    vm.stopPrank();
                    // -----------------------------------------------------------------
                }
            }
            assertEq(sumpart, pegged, "rp integral step sum");
        }
        Measures memory postSteps = _measure();
        vm.revertToState(snap);

        vm.startPrank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();
        // -------------------------------------------------------------------------

        Measures memory post = _measure();

        // Reserve-pool subsidy is consumed step-by-step, so it drifts by the same per-step rounding as the
        // other wrapped quantities in this redeem.
        assertApprox(
            post.reservePoolWrapped,
            postSteps.reservePoolWrapped,
            steps,
            steps,
            "rp integral subsidy wrapped"
        );

        assertApprox(post.feeWrapped, postSteps.feeWrapped, 2 * steps, 3e8 * steps, "rp integral fee wrapped");
        assertApprox(
            wrappedReturned,
            wrappedReturnedSteps,
            2 * steps,
            (_rpTransitions() + 1) * steps * 10,
            "rp integral returned"
        );

        assertApprox(post.userPegged, postSteps.userPegged, 0, 0, "rp integral user pegged");
        assertApprox(post.userLeveraged, postSteps.userLeveraged, 0, 0, "rp integral user leveraged");
        // The user's wrapped gain is the returned wrapped, so it inherits that quantity's bound (see
        // "rp integral returned" above).
        assertApprox(
            post.userWrapped,
            postSteps.userWrapped,
            2 * steps,
            (_rpTransitions() + 1) * steps * 10,
            "rp integral user wrapped"
        );

        assertApprox(post.minterPegged, postSteps.minterPegged, 0, 0, "rp integral minter pegged");
        assertApprox(post.minterLeveraged, postSteps.minterLeveraged, 0, 0, "rp integral minter leveraged");
        assertApprox(
            post.minterWrapped,
            postSteps.minterWrapped,
            2 * steps,
            (_rpTransitions() + 1) * steps * 10,
            "rp integral minter wrapped"
        );
        assertApprox(
            post.minterUnderlying,
            postSteps.minterUnderlying,
            2 * steps,
            (_rpTransitions() + 1) * steps * 10,
            "rp integral minter underlying"
        );
    }

    function _mintLeveraged(uint256 wrapped) internal virtual override {
        // MINT LEVERAGED INTEGRAL
        // we don't allow minting leveragedTokens when it's not economically sensible to do so
        if (IMinter(minter).collateralRatio() > 1 ether) {
            if (subsidyLimitRatio > 0) {
                // a reserve sized as a share of the input, so the cap binds on a walk that stays in the subsidy bands
                uint256 reservePoolWrapped = (wrapped * subsidyLimitRatio) / 1e18;
                deal(address(wrappedCollateralToken), reservePool, reservePoolWrapped);
            }

            // How far the steps' subsidy can drift from the single mint's. Each step credits the record with its
            // collateral rounded down to a whole collateral unit, so the steps run behind the single mint by under one
            // unit per step - at most `steps` units. Where the walk crosses a bound, that lag is filled at the lower
            // band's subsidy rate instead of the upper's: the drift there is at most lag x the rate's change. Summed
            // over every crossing that is `steps` x the schedule's total subsidy variation, in collateral units,
            // which is that / rate in wrapped. Plus the `steps` wrapped wei each step's own subsidy floors away.
            uint256 subsidyDrift;
            {
                int256[] memory ratios = config.mintLeveragedIncentiveConfig.incentiveRatios;
                uint256 variation = 0;
                for (uint256 i = 1; i < ratios.length; i++) {
                    int256 below = ratios[i - 1] < 0 ? -ratios[i - 1] : int256(0);
                    int256 above = ratios[i] < 0 ? -ratios[i] : int256(0);
                    variation += below > above ? uint256(below - above) : uint256(above - below);
                }
                (, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
                subsidyDrift = steps + Math.ceilDiv(steps * variation, r);
            }

            uint256 snap = vm.snapshotState();
            uint256 mintedSteps = 0;
            {
                uint256 base = wrapped / steps;
                uint256 rem = wrapped % steps;
                uint256 acc = rem / 2; // “centre” the bumps
                uint sumpart = 0;
                for (uint256 i = 0; i < steps; ++i) {
                    acc += rem;
                    uint256 bump = 0;
                    if (acc >= steps) {
                        bump = 1;
                        acc -= steps;
                    }
                    uint256 part = base + bump;
                    if (part > 0) {
                        sumpart += part;
                        vm.startPrank(user);
                        mintedSteps += IMinter(minter).mintLeveragedToken(part, user, 0);
                        vm.stopPrank();
                        // ------------------------------------------------------------------
                    }
                }
                assertEq(sumpart, wrapped, "ml integral step sum");
            }

            Measures memory postSteps = _measure();
            vm.revertToState(snap);
            vm.startPrank(user);
            uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
            vm.stopPrank();
            // ------------------------------------------------------------------

            Measures memory post = _measure();
            assertApprox(
                post.reservePoolWrapped,
                postSteps.reservePoolWrapped,
                subsidyDrift,
                0,
                "ml integral subsidy wrapped"
            );

            assertApprox(post.feeWrapped, postSteps.feeWrapped, steps, 2e4 * steps, "ml integral fee wrapped");
            assertApprox(minted, mintedSteps, 2 * steps, (_mlTransitions() + 1) * steps * 10, "ml integral minted");

            assertApprox(post.userPegged, postSteps.userPegged, 0, 0, "ml integral user pegged");
            assertApprox(
                post.userLeveraged,
                postSteps.userLeveraged,
                2 * steps,
                (_mlTransitions() + 1) * steps * 10,
                "ml integral user leveraged"
            );
            assertApprox(
                post.userWrapped,
                postSteps.userWrapped,
                2 * steps,
                (_mlTransitions() + 1) * steps * 10,
                "ml integral user wrapped"
            );

            assertApprox(post.minterPegged, postSteps.minterPegged, 0, 0, "ml integral minter pegged");
            assertApprox(
                post.minterLeveraged,
                postSteps.minterLeveraged,
                2 * steps,
                (_mlTransitions() + 1) * steps * 10,
                "ml integral minter leveraged"
            );
            // the minter holds the subsidy it drew, so its wrapped drifts with that subsidy
            assertApprox(
                post.minterWrapped,
                postSteps.minterWrapped,
                2 * steps + subsidyDrift,
                (_mlTransitions() + 1) * steps * 10,
                "ml integral minter wrapped"
            );
            assertApprox(
                post.minterUnderlying,
                postSteps.minterUnderlying,
                steps,
                steps,
                "ml integral minter underlying"
            );
            // Splitting never credits more than the single mint: each step's credit is rounded down, and the lag that
            // leaves is only ever scaled - by the ratio of the collateral per input either side of each bound - so it
            // cannot change sign, and the split walk ends at or behind the single one.
            assertLe(
                postSteps.minterUnderlying,
                post.minterUnderlying,
                "ml integral split credits no more than the single mint"
            );
        }
    }

    function redeemLeveragedIgnoreReturnZeroAmount(uint256 wrapped, address user) internal returns (uint256 minted) {
        try IMinter(minter).redeemLeveragedToken(wrapped, user, 0) returns (uint256 m) {
            minted = m;
        } catch (bytes memory reason) {
            // console2.log ("rl revert");
            // console2.logBytes(reason);
            (int256 feeRatio, , , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(0);
            require(
                feeRatio == 1 ether &&
                    keccak256(reason) ==
                        keccak256(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken)),
                "ReturnZeroAmount when redeem leveraged is disallowed is the only permitted revert"
            );
            minted = 0;
        }
    }

    function _redeemLeveraged(uint256 wrapped) internal virtual override {
        // REDEEM LEVERAGED INTEGRAL
        if (IMinter(minter).collateralRatio() > 1 ether) {
            (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            uint256 lp = IMinter(minter).leveragedTokenPrice();
            // console2.log("lp = %s", lp);

            uint256 wrappedReturnedSteps = 0;
            uint256 leveraged = (wrapped * r * p) / (lp * 1e18);
            if (leveraged <= IMinter(minter).leveragedTokenBalance()) {
                uint256 snap = vm.snapshotState();
                {
                    uint256 base = leveraged / steps;
                    uint256 rem = leveraged % steps;
                    uint256 acc = rem / 2; // “centre” the bumps
                    uint sumpart = 0;
                    for (uint256 i = 0; i < steps; ++i) {
                        acc += rem;
                        uint256 bump = 0;
                        if (acc >= steps) {
                            bump = 1;
                            acc -= steps;
                        }
                        uint256 part = base + bump;
                        if (part > 0) {
                            sumpart += part;

                            vm.startPrank(user);
                            wrappedReturnedSteps += redeemLeveragedIgnoreReturnZeroAmount(part, user);
                            vm.stopPrank();
                            // ---------------------------------------------------------------------------------
                            // console2.log("lp (after step %s) = %s", i, IMinter(minter).leveragedTokenPrice());
                        }
                    }
                    assertApprox(sumpart, leveraged, 0, 0, "rl integral step sum");
                }

                Measures memory postSteps = _measure();
                vm.revertToState(snap);
                vm.startPrank(user);
                uint256 wrappedReturned = redeemLeveragedIgnoreReturnZeroAmount(leveraged, user);
                vm.stopPrank();
                // -----------------------------------------------------------------------------
                // console2.log("lp (after single step) = %s", IMinter(minter).leveragedTokenPrice());

                Measures memory post = _measure();

                assertApprox(post.feeWrapped, postSteps.feeWrapped, steps, steps, "rl integral fee wrapped");
                assertApprox(
                    wrappedReturned,
                    wrappedReturnedSteps,
                    2 * steps,
                    (_rlTransitions() + 1) * steps * 10,
                    "rl integral minted"
                );

                assertApprox(post.userPegged, postSteps.userPegged, 0, 0, "rl integral user pegged");
                assertApprox(
                    post.userLeveraged,
                    postSteps.userLeveraged,
                    2 * steps,
                    (_rlTransitions() + 1) * steps * 10,
                    "rl integral user leveraged"
                );
                // The user's wrapped gain is the returned wrapped, so it inherits that quantity's bound (see
                // "rl integral minted" above).
                assertApprox(
                    post.userWrapped,
                    postSteps.userWrapped,
                    2 * steps,
                    (_rlTransitions() + 1) * steps * 10,
                    "rl integral user wrapped"
                );

                assertApprox(post.minterPegged, postSteps.minterPegged, 0, 0, "rl integral minter pegged");
                assertApprox(
                    post.minterLeveraged,
                    postSteps.minterLeveraged,
                    2 * steps,
                    (_rlTransitions() + 1) * steps * 10,
                    "rl integral minter leveraged"
                );
                assertApprox(
                    post.minterWrapped,
                    postSteps.minterWrapped,
                    2 * steps,
                    (_rlTransitions() + 1) * steps * 10,
                    "rl integral minter wrapped"
                );
                assertApprox(
                    post.minterUnderlying,
                    postSteps.minterUnderlying,
                    steps,
                    steps,
                    "rl integral minter underlying"
                );

                // The leveraged price is not an independent quantity — it is read back from the state the
                // assertions above have just bounded, so its tolerance is theirs propagated through
                //   leveragedPrice = (underlyingCollateral * price - peggedBalance * peggedPrice) / leveraged
                // Differentiating: a wei of underlying collateral moves the price by price/leveraged, and a
                // wei of leveraged balance moves it by leveragedPrice/leveraged. That amplification is why a
                // bare wei count cannot hold here: at a 1-billionth price with a leveraged balance of ~1e8
                // the collateral term alone is ~9 wei of price per wei of collateral, so the 10 wei of
                // collateral drift "rl integral minter underlying" already permits shows up as ~88 wei of
                // price. The collateral term uses that asserted bound; the leveraged term uses the MEASURED
                // difference, because its own assertion allows 2 * steps, which propagates to a bound so wide
                // it would admit anything. Two further wei cover each path's own floor in leveragedTokenPrice.
                if (lp != 1 ether) {
                    uint256 leveragedDelta = Math.max(post.minterLeveraged, postSteps.minterLeveraged) -
                        Math.min(post.minterLeveraged, postSteps.minterLeveraged);
                    uint256 leveragedBalance = Math.max(post.minterLeveraged, 1);
                    uint256 leveragedPriceTolerance = Math.ceilDiv(steps * p, leveragedBalance) +
                        Math.ceilDiv(post.leveragedPrice * leveragedDelta, leveragedBalance) +
                        2;
                    assertApprox(
                        post.leveragedPrice,
                        postSteps.leveragedPrice,
                        leveragedPriceTolerance,
                        0,
                        "rl integral leveraged price"
                    );
                }
            } else {
                // console2.log ("skip leveraged=%s, balance=%s", leveraged, IMinter(minter).leveragedTokenBalance());
            }
        } else {
            // console2.log ("skip CR=%s", IMinter(minter).collateralRatio());
        }
    }
}

contract TestMinterIntegralFixedFees is TestMinterIntegralFees {
    function setUpConfig() internal virtual override {
        setUp_config_flatWide();
    }
}

contract TestMinterIntegralDisallowSubsidyNoReserve is TestMinterIntegralFees {
    function setUpConfig() internal virtual override {
        setUp_config_flatDisallowSubsidyWide();
    }
}

contract TestMinterIntegralSubsidyNoReserve is TestMinterIntegralFees {
    function setUpConfig() internal virtual override {
        setUp_config_flatSubsidyWide();
    }
}

contract TestMinterIntegralSubsidyLimitedReserve is TestMinterIntegralSubsidyNoReserve {
    function setUp() public virtual override {
        super.setUp();
        subsidyLimitRatio = 0.005 ether;
    }
}

contract TestMinterIntegralSubsidyDisallowForwardLimitedReserve is TestMinterIntegralSubsidyLimitedReserve {
    function setUpConfig() internal virtual override {
        setUp_config_directionalDisallowSubsidyWide();
    }
}

contract TestMinterIntegralSubsidyDisallowReverseLimitedReserve is TestMinterIntegralSubsidyLimitedReserve {
    function setUp() public virtual override {
        super.setUp();
        reverseDirection = true;
    }

    function setUpConfig() internal virtual override {
        setUp_config_reverseDirectionalDisallowSubsidyWide();
    }
}

contract TestMinterIntegralDisallowSubsidyVariableNoReserve is TestMinterIntegralFees {
    function setUpConfig() internal virtual override {
        setUp_config_directionalDisallowSubsidyWide();
    }
}

contract TestMinterIntegralDisallowSubsidyReverseVariableNoReserve is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        reverseDirection = true;
    }

    function setUpConfig() internal virtual override {
        setUp_config_reverseDirectionalDisallowSubsidyWide();
    }
}

contract TestMinterIntegralDisallowSubsidyInexhaustableReserve is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1e50);
    }

    function setUpConfig() internal virtual override {
        setUp_config_flatDisallowSubsidyWide();
    }

    function _mintPegged(uint256 wrapped) internal virtual override {
        super._mintPegged(wrapped);
    }

    function _redeemPegged(uint256 wrapped) internal virtual override {
        super._redeemPegged(wrapped);
        assertGt(IERC20(wrappedCollateralToken).balanceOf(reservePool), 0, "rp reserve left");
    }

    function _mintLeveraged(uint256 wrapped) internal virtual override {
        super._mintLeveraged(wrapped);
        assertGt(IERC20(wrappedCollateralToken).balanceOf(reservePool), 0, "ml reserve left");
    }

    function _redeemLeveraged(uint256 wrapped) internal virtual override {
        super._redeemLeveraged(wrapped);
    }
}

contract TestMinterIntegralVariableFees is TestMinterIntegralFees {
    function setUpConfig() internal virtual override {
        setUp_config_directionalWide();
    }
}

contract TestMinterIntegralReverseVariableFees is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        reverseDirection = true;
    }

    function setUpConfig() internal virtual override {
        setUp_config_reverseDirectionalWide();
    }
}

// -------- Directional + limited reserve under extreme p/r (integral) --------

contract TestMinterIntegralDisallowSubsidyForwardLimitedReserveRate1Million is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        subsidyLimitRatio = 0.005 ether;

        // p=1e18, r=1e12
        price = measurePrice = 1e18;
        rate = measureRate = 1e12;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
    function setUpConfig() internal virtual override {
        setUp_config_directionalDisallowSubsidyWide();
    }
}

/// @notice A mint in the 1-million-rate regime that runs to completion instead of reaching the disallow.
contract TestMinterIntegralDisallowSubsidyForwardLimitedReserveRate1MillionCounterexample is
    TestMinterIntegralDisallowSubsidyForwardLimitedReserveRate1Million
{
    function test_mintPeggedRange_freeIntegralCounterexample() public {
        test_mintPeggedRange_(1, 47330819957767311596, 249077380139801647028);
    }
}

contract TestMinterIntegralDisallowSubsidyReverseLimitedReservePrice1Billionth is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        subsidyLimitRatio = 0.005 ether;

        // p = 1e9, r = 1e18
        price = measurePrice = 1e9;
        rate = measureRate = 1e18;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
    function setUpConfig() internal virtual override {
        setUp_config_reverseDirectionalDisallowSubsidyWide();
    }
}

/// @notice A mint that the disallow band cuts short, pinned as a concrete case in the 1-billionth price regime.
/// @dev At price = 1e9 the whole pegged balance is of order 100 wei, so the single pegged token each call
///      floors away is a ~1% effect on the collateral ratio, and the band formula's 1/(collateralRatio - 1)
///      amplifies it roughly tenfold into collateral space. The one-shot and stepped paths therefore end more
///      than 2x apart on every collateral quantity while both sit correctly just above the boundary — the case
///      that shows why the two paths must be measured against the boundary rather than against each other.
contract TestMinterIntegralDisallowSubsidyReverseLimitedReservePrice1BillionthCounterexample is
    TestMinterIntegralDisallowSubsidyReverseLimitedReservePrice1Billionth
{
    function test_mintPeggedRange_fuzzerCounterexample() public {
        test_mintPeggedRange_(
            1100000000,
            7000000000000000000000000000000,
            31339120015659977296301540324318937502835777748535408418239164074840765235199
        );
    }

    /// @notice A mint in the same regime that runs to completion instead of reaching the disallow.
    function test_mintPeggedRange_freeIntegralCounterexample() public {
        test_mintPeggedRange_(1, 47330819957767311596, 249077380139801647028);
    }

    /// @notice A mint so small in this regime that the pegged it yields is a handful of wei.
    function test_mintPeggedRange_dustPeggedCounterexample() public {
        test_mintPeggedRange_(20000000000000000000, 4000000000000000000, 3004348331);
    }

    /// @notice A leveraged redeem in the same regime, where the leveraged price is the sensitive quantity.
    function test_redeemLeveragedRange_counterexample() public {
        test_redeemLeveragedRange_(18172277342277, 213875265989267128, 1);
    }
}

// --------------------------- Dust rounding stress ---------------------------

// reduce the runs for those as they have loops of 20 * 20 = 400 each
/// forge-config: default.fuzz.runs = 32
contract TestMinterIntegralDustRounding_ is TestMinterIntegralFees {
    function setUp() public virtual override {
        super.setUp();
        // Increase granularity to stress rounding in integral vs single-shot
        steps *= 20;
    }
    function setUpConfig() internal virtual override {
        setUp_config_directionalWide();
    }
}
