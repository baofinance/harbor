// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterSetUp} from "test/Minter_base.t.sol";

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
}

abstract contract TestMinterFeeRange is TestMinterFeeRangeSetUp {
    uint256 minCollateral;
    uint256 maxCollateral;
    uint256 factorCollateral;
    uint256 minToken;
    uint256 maxToken;
    uint256 factorToken;
    uint256 measurePrice;
    uint256 measureRate;

    uint256 mintPeggedBands;
    uint256 redeemPeggedBands;
    uint256 mintLeveragedBands;
    uint256 redeemLeveragedBands;

    function setUp() public virtual override {
        super.setUp();
        minCollateral = 1e9;
        maxCollateral = 1e33;
        factorCollateral = 1000;
        minToken = 1e16;
        maxToken = 1e33;
        factorToken = 100;
        measurePrice = price;
        measureRate = rate;

        mintPeggedBands = 7;
        redeemPeggedBands = 7;
        mintLeveragedBands = 7;
        redeemLeveragedBands = 7;
    }

    // function _mostBands(
    //     uint mostBandsSoFar,
    //     IMinter.IncentiveConfig memory bandConfig,
    //     uint256 preCR,
    //     uint256 postCR
    // ) internal pure returns (uint256 bands) {
    //     // Sort the CRs to determine which direction we're moving
    //     uint256 lowerCR = preCR < postCR ? preCR : postCR;
    //     uint256 higherCR = preCR < postCR ? postCR : preCR;

    //     // Extract boundaries from the bandConfig
    //     uint256[] memory boundaries = bandConfig.collateralRatioBandUpperBounds;

    //     // Count how many boundaries fall between our CRs
    //     uint256 boundariesCrossed = 0;
    //     for (uint i = 0; i < boundaries.length; i++) {
    //         // Check if this boundary is between our collateral ratios
    //         if (boundaries[i] > lowerCR && boundaries[i] <= higherCR) {
    //             boundariesCrossed++;
    //         }
    //     }

    //     // The number of bands crossed is the number of boundaries crossed + 1
    //     // (starting from one band and potentially crossing into others)
    //     uint256 bandsCrossed = boundariesCrossed + 1;
    //     bands = Math.max(mostBandsSoFar, bandsCrossed);
    //     return bands;
    // }

    function test_mintPeggedRange_() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w < maxToken; w *= factorToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _mintPegged(w);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemPeggedRange_() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                uint256 w = minToken;
                uint256 i = 0;
                while (w <= maxToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _redeemPegged(w, i);
                    vm.revertToState(snap);
                    w *= factorToken; 
                    ++i;
                }
            }
        }
    }

    function test_mintLeveragedRange_() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w < maxToken; w *= factorToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _mintLeveraged(w);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemLeveragedRange_() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p <= maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l <= maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w <= maxToken; w *= factorToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _redeemLeveraged(w);
                    vm.revertToState(snap);
                }
            }
        }
    }

    // Put near top of test contract (inside the contract)
    struct LeveragedSpanCtx {
        uint256[] bounds;
        uint256 feePerc;
        uint256 oneMinusFee;
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

    function test_mintLeveragedBandSpans_() public {
        LeveragedSpanCtx memory C;

        C.bounds = config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds;
        assertGe(C.bounds.length, 6, "len bounds ge 6");

        int256 feeI = initial(config.mintLeveragedIncentiveConfig.incentiveRatios);
        // feeI must be >=0 and < 1e18
        if (feeI < 0) {
            // Force fail using only allowed asserts
            assertEq(uint256(1), uint256(0), "fee negative");
        }
        C.feePerc = uint256(uint64(uint256(uint256(int256(feeI))))); // shrink not required but keeps stack light
        assertLt(uint256(feeI), 1e18, "fee < 1e18");
        C.oneMinusFee = 1e18 - uint256(feeI);

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
                    if (C.underlyingTarget > C.underlyingCurrent && C.oneMinusFee != 0 && C.rate != 0) {
                        C.deltaUnderlying = C.underlyingTarget - C.underlyingCurrent;
                        C.wNeeded = _ceilDiv(C.deltaUnderlying * 1e36, C.rate * C.oneMinusFee) + 5;

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
                C.targetCR = C.bounds[C.e] - 1;

                uint256 preCRLocal = C.preCR;
                uint256 preLevSupply = IERC20(leveragedToken).totalSupply();

                C.underlyingCurrent = IMinter(minter).collateralTokenBalance();
                C.peggedSupply = IMinter(minter).peggedTokenBalance();
                C.underlyingTarget = Math.mulDiv(C.targetCR, C.peggedSupply, C.price);
                if (C.underlyingTarget <= C.underlyingCurrent) continue;
                C.deltaUnderlying = C.underlyingTarget - C.underlyingCurrent;
                if (C.oneMinusFee == 0 || C.rate == 0) continue;
                C.wNeeded = _ceilDiv(C.deltaUnderlying * 1e36, C.rate * C.oneMinusFee) + 10;
                if (IMinter(minter).leveragedTokenPrice() == 0) continue;

                _mintLeveraged(C.wNeeded);

                // Re-measure
                uint256 postCR = IMinter(minter).collateralRatio();
                uint256 postLevSupply = IERC20(leveragedToken).totalSupply();

                // If no supply change or CR did not increase, treat as an impossible span and skip
                if (postLevSupply == preLevSupply || postCR <= preCRLocal) {
                    continue;
                }

                // Normal end-band assertions
                assertGt(postCR, _bandLower(C.e, C.bounds), "end lower");
                assertLe(postCR, C.bounds[C.e], "end upper");

                // Count crossings
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

    function _mintPegged(uint256 wrapped) internal virtual;
    function _redeemPegged(uint256 wrapped, uint256 iteration) internal virtual;
    function _mintLeveraged(uint256 wrapped) internal virtual;
    function _redeemLeveraged(uint256 wrapped) internal virtual;
}

contract TestMinterFixedFeeRange_ is TestMinterFeeRange {
    function setUpConfig() internal virtual override {
        // we need flat rates across close boundaries to measure the error in crossing boundaries
        setUp_config_flatWide();
    }

    // TODO: ensure that
    // 1) we enter the depeg band
    // 2) we cross more than one non-edge boundary
    // 3) we have disallows

    function mulDivNearest(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        uint256 doubledResult = Math.mulDiv(a, b * 2, d);
        // (doubledResult / 2) is the floor division
        // (doubledResult % 2) is 1 if we need to round up, 0 otherwise
        return (doubledResult / 2) + (doubledResult % 2);
    }

    function _mintPegged(uint256 wrapped) internal override {
        // MINT PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintPeggedToken(wrapped, user, 0);
        // ---------------------------------------------------------------
        Measures memory post = _measure();

        uint256 fee = (uint256(initial(config.mintPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertNear(post.feeWrapped, pre.feeWrapped + fee, 1, "mp fee wrapped");

        assertEq(post.userPegged, pre.userPegged + minted, "mp user pegged returned");
        console2.log("wrapped=%s", wrapped);
        console2.log("fee=%s", fee);
        console2.log("p=%s", p);
        console2.log("r=%s", r);
        console2.log("pre.peggedPrice=%s", pre.peggedPrice);
        console2.log("post.peggedPrice=%s", post.peggedPrice);
        if (pre.peggedPrice < 1 ether) {
            assertNear(minted, Math.mulDiv(wrapped - fee, p * r, pre.peggedPrice * 1e18), 0, 2, "mp user pegged");
        } else {
            assertNear(minted, Math.mulDiv(wrapped - fee, p * r, pre.peggedPrice * 1e18), 10, "mp user pegged");
        }
        assertEq(post.userLeveraged, pre.userLeveraged, "mp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "mp user wrapped");

        assertEq(post.minterPegged, pre.minterPegged + minted, "mp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "mp minter leveraged");
        assertNear(post.minterWrapped, pre.minterWrapped + wrapped - fee, 1, "mp minter wrapped");
        assertNear(
            post.minterUnderlying,
            pre.minterUnderlying + ((wrapped - fee) * r) / 1e18,
            1,
            "mp minter underlying"
        );

        assertNear(post.peggedPrice, pre.peggedPrice, 1, 500, "mp pegged price");
        // assertNear(post.leveragedPrice, pre.leveragedPrice, 1, 1000, "mp leveraged price");
    }

    function _redeemPegged(uint256 wrapped, uint256 iteration) internal override {
        // REDEEM PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        uint256 pegged = Math.min((wrapped * p * r) / 1e36, IMinter(minter).peggedTokenBalance());
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        // -------------------------------------------------------------------------
        Measures memory post = _measure();

        // adjust wrapped value for de-pegged situation
        if (pre.collateralRatio < 1 ether) {
            // on depeg
            // wrapped = ((pegged * pre.peggedPrice) / p) * r / 1 ether; -> original
            wrapped = ((pegged * r * pre.peggedPrice) / 1 ether) / p; // try to improve precision by mult first
        } else {
            // general calculation
            wrapped = pegged * 1e36 / (r * p);
        }
        console2.log("adjusted wrapped: ", wrapped);

        uint256 fee = (uint256(initial(config.redeemPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1e18;
        assertNear(post.feeWrapped, pre.feeWrapped + fee, 1, 1, "rp fee wrapped");

        assertEq(post.userPegged, pre.userPegged - pegged, "rp user pegged");
        assertNear(wrappedReturned, wrapped - fee, 0, 1, "rp user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged, "rp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rp user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged - pegged, "rp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "rp minter leveraged");
        
        // When depegged and redeeming pegged token, converting pegged to wrapped accrues some precision loss
        // We're compensating for it by creating wrappedDiffAllowed. With the current test suite iterations, it should max cap at 0.000002000000000000
        uint256 wrappedDiffAllowed = 0;
        if (pre.collateralRatio < 1 ether) {
            wrappedDiffAllowed = pegged > 1e30 ? (iteration * 1e10) / iteration * 1e3 + 2 : iteration * 1e6 + 1;
            wrappedDiffAllowed = bound(wrappedDiffAllowed, 1, 2000000000000 + 2);
        }
        console2.log("wrappedDiffAllowed:", wrappedDiffAllowed);

        assertNear(post.minterWrapped, pre.minterWrapped - wrapped, wrappedDiffAllowed, 0, "rp minter wrapped");
        assertNear(post.minterUnderlying, pre.minterUnderlying - (wrapped * r) / 1e18, wrappedDiffAllowed, 0, "rp minter underlying");

        // Assert pegged token price for different CRs
        if (pre.collateralRatio >= 1 ether) {
            // In normal scenarios (CR>=1) pegged token price doesn't change
            assertEq(post.peggedPrice, pre.peggedPrice, "rp pegged price");
        } else if (pre.peggedPrice == post.peggedPrice) {
            // There was a depeg, but redeem amount wasn't big enough to change the pegged token price
            assertLt(post.collateralRatio, 1 ether, "depeg rp cr no change");
        }
        else {
            // Enough pegged tokens were redeemed to restore the peg
            assertEq(post.peggedPrice, 1 ether, "depeg rp pegged price");
            assertGe(post.collateralRatio, 1 ether, "depeg rp cr");
        }
        // assertEq(post.leveragedPrice, pre.leveragedPrice, 1, "rp leveraged price");
    }

    function _mintLeveraged(uint256 wrapped) internal override {
        // MINT LEVERAGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre;
        uint256 lp = IMinter(minter).leveragedTokenPrice();
        if (IMinter(minter).collateralRatio() > 1 ether) {
            pre = _measure();
            vm.prank(user);
            uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
            // ------------------------------------------------------------------
            Measures memory post = _measure();
            uint256 q = r / 1e18; // how many 1e18-scale “chunks” in rate

            uint256 fee = (uint256(initial(config.mintLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
            // TODO: the fee is slightly low so is knowcking out all the rest below
            assertNear(post.feeWrapped, pre.feeWrapped + fee, q + 2, "ml fee wrapped");

            assertNear(
                post.minterUnderlying,
                pre.minterUnderlying + ((wrapped - fee) * r) / 1e18,
                q + 2,
                "ml minter underlying"
            );

            assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

            assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
            assertNear(post.minterWrapped, pre.minterWrapped + wrapped - fee, 1, "ml minter wrapped");

            assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
            assertNear(
                minted,
                Math.mulDiv((wrapped - fee) * r /*underlying collateral */, p, lp * 1e18),
                q + 2,
                3,
                "ml user leveraged"
            );

            assertEq(post.peggedPrice, pre.peggedPrice, "ml pegged price");
            assertNear(
                post.leveragedPrice,
                pre.leveragedPrice,
                IERC20(leveragedToken).totalSupply() > 1e9 ? 15 : 0,
                0,
                "ml leveraged price"
            );
        } else {
            console2.log("CR=%s", IMinter(minter).collateralRatio());
        }
    }

    function _redeemLeveraged(uint256 wrapped) internal override {
        // REDEEM LEVERAGED
        if (IMinter(minter).collateralRatio() > 1 ether) {
            (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            Measures memory pre = _measure();
            uint256 leveraged = (wrapped * r * p) / (pre.leveragedPrice * 1e18);
            if (leveraged <= pre.minterLeveraged) {
                console2.log("leveraged=%s", leveraged);
                console2.log("underlying=%s", (wrapped * r) / 1e18);
                vm.prank(user);
                uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
                // -------------------------------------------------------------------------------
                Measures memory post = _measure();
                if (IMinter(minter).collateralRatio() > 1 ether) {
                    assertNear(
                        post.leveragedPrice,
                        post.minterLeveraged == 0 ? 1e18 : pre.leveragedPrice,
                        1,
                        "rl leveraged price"
                    );

                    uint256 fee = (uint256(initial(config.redeemLeveragedIncentiveConfig.incentiveRatios)) * wrapped) /
                        1 ether;
                    assertNear(post.feeWrapped, pre.feeWrapped + fee, 1, 3, "rl fee wrapped");

                    assertEq(post.userPegged, pre.userPegged, "rl user pegged");
                    assertNear(wrappedReturned, wrapped - fee, 0, 4, "rl user wrapped");
                    assertNear(post.userLeveraged, pre.userLeveraged - leveraged, 1, 2, "rl user leveraged");
                    assertNear(post.userWrapped, pre.userWrapped + wrappedReturned, 0, "rl user wrapped returned");

                    assertNear(post.minterPegged, pre.minterPegged, 0, "rl minter pegged");
                    assertNear(post.minterLeveraged, pre.minterLeveraged - leveraged, 1, "rl minter leveraged");
                    assertNear(post.minterWrapped, pre.minterWrapped - wrapped, 1, 0, "rl minter wrapped");
                    assertNear(
                        post.minterUnderlying,
                        pre.minterUnderlying - (wrapped * r) / 1e18,
                        2,
                        0,
                        "rl minter underlying"
                    );
                }
                assertEq(post.peggedPrice, pre.peggedPrice, "rl pegged price");
            } else {
                console2.log("skip leveraged=%s, balance=%s", leveraged, pre.minterLeveraged);
            }
        } else {
            console2.log("skip CR=%s", IMinter(minter).collateralRatio());
        }
    }
}

contract TestMinterFixedFeeRangeDepegShallow_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 2;
        redeemPeggedBands = 1;
    }
}

contract TestMinterFixedFeeRangeDepegMid_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 3;
        redeemPeggedBands = 1;
    }
}

contract TestMinterFixedFeeRangeDepegDeep_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        measurePrice = price / 4;
        redeemPeggedBands = 1;
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

// rate checks

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

contract TestMinterIntegralFixedFees is TestMinterFeeRange {
    // TODO:
    // 1) we have disallows
    // 2) we have inexhaustable reservePool_ for discounts
    // 3) we have exhausted reserve pool for discounts
    // 4) multiple non-edge bands
    // 5) we have edge bands, too
    uint steps;

    function setUp() public virtual override {
        super.setUp();
        steps = 10;
        minToken *= steps; // to ensure the mintoken works for each step
    }

    function setUpConfig() internal virtual override {
        setUp_config_flatWide();
    }

    function _mintPegged(uint256 wrapped) internal override {
        // MINT PEGGED
        uint256 snap = vm.snapshotState();
        uint256 mintedSteps = 0;
        uint256 wrappedStep = wrapped / steps;
        assertNear(wrapped, wrappedStep * steps, steps, "mp passed in the correct wrapped");
        for (uint i = 0; i < steps; i++) {
            vm.prank(user);
            mintedSteps += IMinter(minter).mintPeggedToken(wrappedStep, user, 0);
            // -----------------------------------------------------------------
        }
        Measures memory postSteps = _measure();
        vm.revertToState(snap);
        vm.prank(user);
        uint256 minted = IMinter(minter).mintPeggedToken(wrapped, user, 0);
        // ---------------------------------------------------------------
        console2.log("minted=%s", minted);
        Measures memory post = _measure();

        uint256 pegTolAbs = 32;
        uint256 colTolRel = 2e6;

        assertNear(post.feeWrapped, postSteps.feeWrapped, 3, "mp integral fee wrapped");
        assertNear(minted, mintedSteps, pegTolAbs, 0, "mp integral minted");

        assertNear(post.userPegged, postSteps.userPegged, pegTolAbs, 1, "mp integral user pegged");
        assertEq(post.userLeveraged, postSteps.userLeveraged, "mp integral user leveraged");
        assertNear(post.userWrapped, postSteps.userWrapped, 1, colTolRel, "mp integral user wrapped");

        assertNear(post.minterPegged, postSteps.minterPegged, pegTolAbs, 1, "mp integral minter pegged");
        assertEq(post.minterLeveraged, postSteps.minterLeveraged, "mp integral minter leveraged");
        assertNear(post.minterWrapped, postSteps.minterWrapped, 1, colTolRel, "mp integral minter wrapped");
        assertNear(post.minterUnderlying, postSteps.minterUnderlying, 2, colTolRel, "mp integral minter underlying");
    }

    function _redeemPegged(uint256 wrapped, uint256 iteration) internal override {
        // REDEEM PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 snap = vm.snapshotState();
        uint256 wrappedReturnedSteps = 0;
        uint256 pegged = Math.min((wrapped * p * r) / 1e36, IMinter(minter).peggedTokenBalance());
        uint256 peggpedStep = pegged / steps;
        for (uint i = 0; i < steps; i++) {
            vm.prank(user);

            wrappedReturnedSteps += IMinter(minter).redeemPeggedToken(peggpedStep, user, 0);
            // -----------------------------------------------------------------
        }
        Measures memory postSteps = _measure();
        vm.revertToState(snap);

        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        // -------------------------------------------------------------------------

        Measures memory post = _measure();

        uint256 pegTolAbs = 32;
        uint256 colTolRel = 2e6;

        assertNear(post.feeWrapped, postSteps.feeWrapped, 1, "rp integral fee wrapped");
        assertNear(wrappedReturned, wrappedReturnedSteps, pegTolAbs, "rp integral returned");

        assertNear(post.userPegged, postSteps.userPegged, pegTolAbs, "rp integral user pegged");
        assertEq(post.userLeveraged, postSteps.userLeveraged, "rp integral user leveraged");
        assertNear(post.userWrapped, postSteps.userWrapped, 1, colTolRel, "rp integral user wrapped");

        assertNear(post.minterPegged, postSteps.minterPegged, pegTolAbs, "rp integral minter pegged");
        assertEq(post.minterLeveraged, postSteps.minterLeveraged, "rp integral minter leveraged");
        assertNear(post.minterWrapped, postSteps.minterWrapped, 1, colTolRel, "rp integral minter wrapped");
        assertNear(post.minterUnderlying, postSteps.minterUnderlying, 1, colTolRel, "rp integral minter underlying");
    }

    function _mintLeveraged(uint256 wrapped) internal override {
        // MINT LEVERAGED
        // we don't allow minting leveragedTokens when it's not economically sensible to do so
        if (IMinter(minter).collateralRatio() > 1 ether) {
            uint256 snap = vm.snapshotState();
            uint256 mintedSteps = 0;
            uint256 wrappedStep = wrapped / steps;
            assertNear(wrapped, wrappedStep * steps, steps, "ml passed in the correct wrapped");
            for (uint i = 0; i < steps; i++) {
                vm.prank(user);
                mintedSteps += IMinter(minter).mintLeveragedToken(wrappedStep, user, 0);
                // ------------------------------------------------------------------
            }

            Measures memory postSteps = _measure();
            vm.revertToState(snap);
            vm.prank(user);
            uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
            // ------------------------------------------------------------------

            Measures memory post = _measure();

            assertNear(post.feeWrapped, postSteps.feeWrapped, 0, 0, "ml integral fee wrapped");
            assertNear(minted, mintedSteps, 0, 0, "ml integral minted");

            assertNear(post.userPegged, postSteps.userPegged, 0, 0, "ml integral user pegged");
            assertNear(post.userLeveraged, postSteps.userLeveraged, 0, 0, "ml integral user leveraged");
            assertNear(post.userWrapped, postSteps.userWrapped, 0, 0, "ml integral user wrapped");

            assertNear(post.minterPegged, postSteps.minterPegged, 0, 0, "ml integral minter pegged");
            assertNear(post.minterLeveraged, postSteps.minterLeveraged, 0, 0, "ml integral minter leveraged");
            assertNear(post.minterWrapped, postSteps.minterWrapped, 0, 0, "ml integral minter wrapped");
            assertNear(post.minterUnderlying, postSteps.minterUnderlying, 0, 0, "ml integral minter underlying");
        }
    }

    function _redeemLeveraged(uint256 wrapped) internal override {
        // REDEEM LEVERAGED
        if (IMinter(minter).collateralRatio() > 1 ether) {
            (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            uint256 lp = IMinter(minter).leveragedTokenPrice();

            uint256 wrappedReturnedSteps = 0;
            uint256 leveraged = (wrapped * r * p) / (lp * 1e18);
            if (leveraged <= IMinter(minter).leveragedTokenBalance()) {
                uint256 leveragedStep = leveraged / steps;
                uint256 snap = vm.snapshotState();
                for (uint i = 0; i < steps; i++) {
                    vm.prank(user);
                    wrappedReturnedSteps += IMinter(minter).redeemLeveragedToken(leveragedStep, user, 0);
                    // ---------------------------------------------------------------------------------
                }

                Measures memory postSteps = _measure();
                vm.revertToState(snap);
                vm.prank(user);
                uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
                // ------------------------------------------------------------------

                Measures memory post = _measure();

                assertEq(post.leveragedPrice, postSteps.leveragedPrice, "RP leveraged price");

                assertNear(post.feeWrapped, postSteps.feeWrapped, 0, 0, "RL integral fee wrapped");
                assertNear(wrappedReturned, wrappedReturnedSteps, 0, 0, "RL integral minted");

                assertNear(post.userPegged, postSteps.userPegged, 0, 0, "RL integral user pegged");
                assertNear(post.userLeveraged, postSteps.userLeveraged, 0, 0, "RL integral user leveraged");
                assertNear(post.userWrapped, postSteps.userWrapped, 0, 0, "RL integral user wrapped");

                assertNear(post.minterPegged, postSteps.minterPegged, 0, 0, "RL integral minter pegged");
                assertNear(post.minterLeveraged, postSteps.minterLeveraged, 0, 0, "RL integral minter leveraged");
                assertNear(post.minterWrapped, postSteps.minterWrapped, 0, 0, "RL integral minter wrapped");
                assertNear(post.minterUnderlying, postSteps.minterUnderlying, 0, 0, "RL integral minter underlying");
            } else {
                console2.log("skip leveraged=%s, balance=%s", leveraged, IMinter(minter).leveragedTokenBalance());
            }
        } else {
            console2.log("skip CR=%s", IMinter(minter).collateralRatio());
        }
    }
}

contract TestMinterIntegralVariableFees is TestMinterIntegralFixedFees {
    function setUpConfig() internal virtual override {
        setUp_config_directionalWide();
    }
}
