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

    function setUp_configFixed() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(80, 80, 80, 80, 80, 80, 80, 80)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(70, 70, 70, 70, 70, 70, 70, 70)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 120, 120, 120, 120, 120, 120, 120))
        );
    }

    function setUp_configVariable() internal {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)), // mint pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)) // redeem leveraged
        );
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

    function setUp() public virtual override {
        super.setUp();
        minCollateral = 1e9;
        maxCollateral = 1e30;
        factorCollateral = 1000;
        minToken = 1e16;
        maxToken = 1e36;
        factorToken = 100;
        measurePrice = price;
        measureRate = rate;
    }

    function test_mintPegged() public virtual returns (uint256 result) {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w < maxToken; w *= factorToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    result = _mintPegged(w, result);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemPegged() public virtual returns (uint256 result) {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w <= maxToken; w *= factorToken) {
                    bool finishAfterThis = w >= p;
                    w = finishAfterThis ? p : w; // to avoid truncated returns
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    result = _redeemPegged(w, result);
                    vm.revertToState(snap);
                    if (finishAfterThis) break;
                }
            }
        }
    }

    function test_mintLeveraged() public virtual returns (uint256 result) {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w < maxToken; w *= factorToken) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    result = _mintLeveraged(w, result);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemLeveraged() public virtual returns (uint256 result) {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p <= maxCollateral; p *= factorCollateral) {
            for (uint256 l = minCollateral; l <= maxCollateral; l *= factorCollateral) {
                for (uint256 w = minToken; w <= maxToken; w *= factorToken) {
                    bool finishAfterThis = w >= l;
                    w = finishAfterThis ? l : w; // to avoid truncated returns
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    result = _redeemLeveraged(w, result);
                    vm.revertToState(snap);
                    if (finishAfterThis) break;
                }
            }
        }
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

    function _mintPegged(uint256 wrapped, uint256 result) internal virtual returns (uint256);
    function _redeemPegged(uint256 wrapped, uint256 result) internal virtual returns (uint256);
    function _mintLeveraged(uint256 wrapped, uint256 result) internal virtual returns (uint256);
    function _redeemLeveraged(uint256 wrapped, uint256 result) internal virtual returns (uint256);
}

contract TestMinterFixedFeeRange_ is TestMinterFeeRange {
    uint256 mintPeggedBands;
    uint256 redeemPeggedBands;
    uint256 mintLeveragedBands;
    uint256 redeemLeveragedBands;

    function setUp() public virtual override {
        super.setUp();
        mintPeggedBands = 7;
        redeemPeggedBands = 7;
        mintLeveragedBands = 7;
        redeemLeveragedBands = 7;
    }

    function setUpConfig() internal virtual override {
        // we need flat rates across close boundaries to measure the error in crossing boundaries
        setUp_configFixed();
    }

    function test_mintPegged() public virtual override returns (uint256 result) {
        result = super.test_mintPegged();
        // starting from pegged cannot go de-pegged
        console2.log("mintPeggedMostBands:", result);
        assertEq(result, mintPeggedBands, "mintPeggedMostBands should be 7");
    }

    function test_redeemPegged() public virtual override returns (uint256 result) {
        result = super.test_redeemPegged();
        assertEq(result, redeemPeggedBands, "redeemPeggedMostBands should be 8");
    }

    function test_mintLeveraged() public virtual override returns (uint256 result) {
        result = super.test_mintLeveraged();
        assertEq(result, mintLeveragedBands, "mintLeveragedMostBands should be 8");
    }

    function test_redeemLeveraged() public virtual override returns (uint256 result) {
        result = super.test_redeemLeveraged();
        assertEq(result, redeemLeveragedBands, "redeemLeveragedMostBands should be 8");
    }

    function _mostBands(
        uint mostBandsSoFar,
        IMinter.IncentiveConfig memory bandConfig,
        Measures memory pre,
        Measures memory post
    ) internal pure returns (uint256 bands) {
        // Get the collateral ratios
        uint256 preCR = pre.collateralRatio;
        uint256 postCR = post.collateralRatio;

        // Sort the CRs to determine which direction we're moving
        uint256 lowerCR = preCR < postCR ? preCR : postCR;
        uint256 higherCR = preCR < postCR ? postCR : preCR;

        // Extract boundaries from the bandConfig
        uint256[] memory boundaries = bandConfig.collateralRatioBandUpperBounds;

        // Count how many boundaries fall between our CRs
        uint256 boundariesCrossed = 0;
        for (uint i = 0; i < boundaries.length; i++) {
            // Check if this boundary is between our collateral ratios
            if (boundaries[i] > lowerCR && boundaries[i] <= higherCR) {
                boundariesCrossed++;
            }
        }

        // The number of bands crossed is the number of boundaries crossed + 1
        // (starting from one band and potentially crossing into others)
        uint256 bandsCrossed = boundariesCrossed + 1;
        bands = Math.max(mostBandsSoFar, bandsCrossed);
        return bands;
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

    function _mintPegged(uint256 wrapped, uint256 result) internal override returns (uint256) {
        // MINT PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintPeggedToken(wrapped, user, 0);
        // ---------------------------------------------------------------
        Measures memory post = _measure();
        result = _mostBands(result, config.mintPeggedIncentiveConfig, pre, post);

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

        return result;
    }

    function _redeemPegged(uint256 wrapped, uint256 result) internal override returns (uint256) {
        // REDEEM PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        uint256 pegged = (wrapped * p * r) / 1e36;
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        // -------------------------------------------------------------------------
        Measures memory post = _measure();
        result = _mostBands(result, config.redeemPeggedIncentiveConfig, pre, post);

        // adjust wrapped value for de-pegged situation
        wrapped = (wrapped * pre.peggedPrice) / 1e18;
        uint256 fee = (uint256(initial(config.redeemPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1e18;
        assertNear(post.feeWrapped, pre.feeWrapped + fee, 1, 1, "rp fee wrapped");

        assertEq(post.userPegged, pre.userPegged - pegged, "rp user pegged");
        assertNear(wrappedReturned, wrapped - fee, 0, 1, "rp user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged, "rp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rp user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged - pegged, "rp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "rp minter leveraged");
        assertNear(post.minterWrapped, pre.minterWrapped - wrapped, 1, 0, "rp minter wrapped");
        assertNear(post.minterUnderlying, pre.minterUnderlying - (wrapped * r) / 1e18, 1, 0, "rp minter underlying");

        assertNear(post.peggedPrice, pre.peggedPrice, 1e12, "rp pegged price");
        // assertEq(post.leveragedPrice, pre.leveragedPrice, 1, "rp leveraged price");

        return result;
    }

    function _mintLeveraged(uint256 wrapped, uint256 result) internal override returns (uint256) {
        // MINT LEVERAGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
        // ------------------------------------------------------------------
        Measures memory post = _measure();
        result = _mostBands(result, config.mintLeveragedIncentiveConfig, pre, post);

        uint256 fee = (uint256(initial(config.mintLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        // TODO: the fee is slightly low so is knowcking out all the rest below
        assertApproxEqAbs(post.feeWrapped, pre.feeWrapped + fee, 2, "ml fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "ml user pegged ");
        assertApproxEqAbs(minted, Math.mulDiv((wrapped - fee), (p * r) / 1e18, 1e18), p, "ml user leveraged");
        assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

        assertEq(post.minterPegged, pre.minterPegged, "ml minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
        assertApproxEqAbs(post.minterWrapped, pre.minterWrapped + wrapped - fee, 1, "ml minter wrapped");
        assertApproxEqAbs(
            post.minterUnderlying,
            pre.minterUnderlying + ((wrapped - fee) * r) / 1e18,
            1,
            "ml minter underlying"
        );

        assertEq(post.peggedPrice, pre.peggedPrice, "ml pegged price");
        assertEq(post.leveragedPrice, pre.leveragedPrice, "ml leveraged price");

        return result;
    }

    function _redeemLeveraged(uint256 wrapped, uint256 result) internal override returns (uint256) {
        // REDEEM LEVERAGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        uint256 leveraged;
        {
            uint256 leveragedTokenBalance = IMinter(minter).leveragedTokenBalance();
            uint256 collateralValue$ = IMinter(minter).collateralTokenBalance() * p;
            uint256 peggedValue$ = IMinter(minter).peggedTokenBalance() * IMinter(minter).peggedTokenPrice();
            uint256 amountCollateralValue$ = (wrapped * p * r) / 1 ether;
            if (leveragedTokenBalance > 0) {
                leveraged = Math.mulDiv(amountCollateralValue$, leveragedTokenBalance, collateralValue$ - peggedValue$);
            } else {
                leveraged = (collateralValue$ + amountCollateralValue$ - peggedValue$) / 1 ether;
            }
        }

        // console2.log("leveraged=%s = %s", leveraged, (wrapped * p * r) / 1e36);
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
        // -------------------------------------------------------------------------------
        Measures memory post = _measure();
        result = _mostBands(result, config.redeemLeveragedIncentiveConfig, pre, post);

        uint256 fee = (uint256(initial(config.redeemLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "rl fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "rl user pegged");
        assertEq(wrappedReturned, wrapped - fee, "rl user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged - leveraged, "rl user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rl user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged, "rl minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged - leveraged, "rl minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped - wrapped, "rl minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * r) / 1e18, "rl minter underlying");

        assertEq(post.peggedPrice, pre.peggedPrice, "rl pegged price");
        assertEq(post.leveragedPrice, pre.leveragedPrice, "rl leveraged price");

        return result;
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

contract TestMinterFixedFeeRangePrice1Million is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether * 1e6;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Millionth is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether / 1e6;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Billion is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether * 1e9;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangePrice1Billionth is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether / 1e9;
        rate = measureRate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

// rate checks

contract TestMinterFixedFeeRangeRate1Million is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        super.setUp();
        price = measurePrice = 1 ether;
        rate = measureRate = 1 ether * 1e6;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }
}

contract TestMinterFixedFeeRangeRate1Millionth is TestMinterFixedFeeRange_ {
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
        setUp_configFixed();
    }

    function _mintPegged(uint256 wrapped, uint256) internal override returns (uint256) {
        // MINT PEGGED
        uint256 snap = vm.snapshotState();
        uint256 mintedSteps = 0;
        uint256 wrappedStep = wrapped / steps;
        assertEq(wrapped, wrappedStep * steps, "passed in the correct wrapped");
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

        assertNear(post.feeWrapped, postSteps.feeWrapped, 2, "mp integral fee wrapped");
        assertNear(minted, mintedSteps, pegTolAbs, 0, "mp integral minted");

        assertNear(post.userPegged, postSteps.userPegged, pegTolAbs, 1, "mp integral user pegged");
        assertEq(post.userLeveraged, postSteps.userLeveraged, "mp integral user leveraged");
        assertNear(post.userWrapped, postSteps.userWrapped, 1, colTolRel, "mp integral user wrapped");

        assertNear(post.minterPegged, postSteps.minterPegged, pegTolAbs, 1, "mp integral minter pegged");
        assertEq(post.minterLeveraged, postSteps.minterLeveraged, "mp integral minter leveraged");
        assertNear(post.minterWrapped, postSteps.minterWrapped, 1, colTolRel, "mp integral minter wrapped");
        assertNear(post.minterUnderlying, postSteps.minterUnderlying, 2, colTolRel, "mp integral minter underlying");
        return 0;
    }

    function _redeemPegged(uint256 wrapped, uint256) internal override returns (uint256) {
        // REDEEM PEGGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 snap = vm.snapshotState();
        uint256 wrappedReturnedSteps = 0;
        uint256 pegged = (wrapped * p * r) / 1e36;
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
        uint256 fee;
        uint256 discount;
        int256 fd = (initial(config.redeemPeggedIncentiveConfig.incentiveRatios) * int256(wrapped)) / 1 ether;
        if (fd > 0) {
            fee = uint256(fd);
        } else {
            discount = uint256(-fd);
        }

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
        return 0;
    }

    function _mintLeveraged(uint256 wrapped, uint256) internal override returns (uint256) {
        // MINT LEVERAGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
        // ------------------------------------------------------------------
        Measures memory post = _measure();

        uint256 fee = (uint256(initial(config.mintLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "ml fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "ml user pegged ");
        assertEq(minted, Math.mulDiv((wrapped - fee), (p * r) / 1e18, 1e18), "ml user leveraged");
        assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

        assertEq(post.minterPegged, pre.minterPegged, "ml minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped + wrapped - fee, "ml minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying + ((wrapped - fee) * r) / 1e18, "ml minter underlying");
        return 0;
    }

    function _redeemLeveraged(uint256 wrapped, uint256) internal override returns (uint256) {
        // REDEEM LEVERAGED
        (uint256 p, , uint256 r, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        Measures memory pre = _measure();
        uint256 leveraged;
        {
            uint256 leveragedTokenBalance = IMinter(minter).leveragedTokenBalance();
            uint256 collateralValue$ = IMinter(minter).collateralTokenBalance() * p;
            uint256 peggedValue$ = IMinter(minter).peggedTokenBalance() * IMinter(minter).peggedTokenPrice();
            uint256 amountCollateralValue$ = (wrapped * p * r) / 1 ether;
            if (leveragedTokenBalance > 0) {
                leveraged = Math.mulDiv(amountCollateralValue$, leveragedTokenBalance, collateralValue$ - peggedValue$);
            } else {
                leveraged = (collateralValue$ + amountCollateralValue$ - peggedValue$) / 1 ether;
            }
        }
        // console2.log("leveraged=%s = %s", leveraged, (wrapped * p * r) / 1e36);
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
        // -------------------------------------------------------------------------------
        Measures memory post = _measure();

        uint256 fee = (uint256(initial(config.redeemLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "rl fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "rl user pegged");
        assertEq(wrappedReturned, wrapped - fee, "rl user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged - leveraged, "rl user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rl user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged, "rl minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged - leveraged, "rl minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped - wrapped, "rl minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * r) / 1e18, "rl minter underlying");
        return 0;
    }
}

contract TestMinterIntegralVariableFees is TestMinterIntegralFixedFees {
    function setUpConfig() internal virtual override {
        setUp_configVariable();
    }
}
