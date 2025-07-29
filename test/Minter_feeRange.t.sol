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
    uint256 minToken;
    uint256 maxToken;
    uint256 measurePrice;
    uint256 measureRate;

    function setUp() public virtual override {
        super.setUp();
        minCollateral = 1e9;
        maxCollateral = 1e30;
        minToken = 1e3;
        maxToken = 1e36;
        measurePrice = price;
        measureRate = rate;
    }

    function test_mintPegged() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= 100) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= 100) {
                for (uint256 w = minToken; w < maxToken; w *= 10) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _mintPegged(w);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemPegged() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= 100) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= 100) {
                for (uint256 w = minToken; w <= maxToken; w *= 10) {
                    bool finishAfterThis = w >= p;
                    w = finishAfterThis ? p : w; // to avoid truncated returns
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _redeemPegged(w);
                    vm.revertToState(snap);
                    if (finishAfterThis) break;
                }
            }
        }
    }

    function test_mintLeveraged() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p < maxCollateral; p *= 100) {
            for (uint256 l = minCollateral; l < maxCollateral; l *= 100) {
                for (uint256 w = minToken; w < maxToken; w *= 10) {
                    setUp_collateral(p, l, user);
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    _mintLeveraged(w);
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_redeemLeveraged() public virtual {
        uint256 snap = vm.snapshotState();
        for (uint256 p = minCollateral; p <= maxCollateral; p *= 100) {
            for (uint256 l = minCollateral; l <= maxCollateral; l *= 100) {
                for (uint256 w = minToken; w <= maxToken; w *= 10) {
                    bool finishAfterThis = w >= l;
                    w = finishAfterThis ? l : w; // to avoid truncated returns
                    MockWrappedPriceOracle(priceOracle).setLatestAnswer(measurePrice, measureRate);
                    setUp_collateral(p, l, user);
                    _redeemLeveraged(w);
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
        uint256 collateralRatio;
    }

    function _measure() internal view virtual returns (Measures memory m) {
        m.userPegged = IERC20(peggedToken).balanceOf(user);
        m.userLeveraged = IERC20(leveragedToken).balanceOf(user);
        m.userWrapped = IERC20(wrappedCollateralToken).balanceOf(user);

        m.minterPegged = IMinter(minter).peggedTokenBalance();
        m.minterLeveraged = IERC20(leveragedToken).totalSupply();
        m.minterWrapped = IERC20(wrappedCollateralToken).balanceOf(minter);
        m.minterUnderlying = IMinter(minter).collateralTokenBalance();

        m.feeWrapped = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        m.collateralRatio = IMinter(minter).collateralRatio();
    }

    function _mintPegged(uint256 wrapped) internal virtual;
    function _redeemPegged(uint256 wrapped) internal virtual;
    function _mintLeveraged(uint256 wrapped) internal virtual;
    function _redeemLeveraged(uint256 wrapped) internal virtual;
}

contract TestMinterFixedFeeRange_ is TestMinterFeeRange {
    uint mintPeggedMostBands;
    uint mintLeveragedMostBands;
    uint redeemPeggedMostBands;
    uint redeemLeveragedMostBands;

    function setUpConfig() internal virtual override {
        // we need flat rates across close boundaries to measure the error in crossing boundaries
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(80, 80, 80, 80, 80, 80, 80, 80)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(70, 70, 70, 70, 70, 70, 70, 70)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 120, 120, 120, 120, 120, 120, 120))
        );
    }

    function test_mintPegged() public virtual override {
        super.test_mintPegged();
        assertEq(mintPeggedMostBands, 8, "mintPeggedMostBands should be 8");
    }

    function test_redeemPegged() public virtual override {
        super.test_redeemPegged();
        assertEq(redeemPeggedMostBands, 8, "redeemPeggedMostBands should be 8");
    }

    function test_mintLeveraged() public virtual override {
        super.test_mintLeveraged();
        assertEq(mintLeveragedMostBands, 8, "mintLeveragedMostBands should be 8");
    }

    function test_redeemLeveraged() public virtual override {
        super.test_redeemLeveraged();
        assertEq(redeemLeveragedMostBands, 8, "redeemLeveragedMostBands should be 8");
    }

    function _mostBands(
        uint mostBandsSoFar,
        Measures memory pre,
        Measures memory post
    ) internal pure returns (uint256) {
        // we are not testing the most bands here, so we just return the max
        // this is to ensure that the test passes even if the most bands are not set
        uint256 preCR = pre.collateralRatio;
        uint256 postCR = post.collateralRatio;
        return Math.max(mostBandsSoFar, Math.max(preCR, postCR) / 10 - Math.min(preCR, postCR) / 10);
    }

    // TODO: ensure that
    // 1) we enter the depeg band
    // 2) we cross more than one non-edge boundary
    // 3) we have disallows

    function _mintPegged(uint256 wrapped) internal override {
        // MINT PEGGED
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintPeggedToken(wrapped, user, 0);
        // ---------------------------------------------------------------
        Measures memory post = _measure();
        mintPeggedMostBands = _mostBands(mintPeggedMostBands, pre, post);

        uint256 fee = (uint256(initial(config.mintPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertApproxEqAbs(post.feeWrapped, pre.feeWrapped + fee, 3, "mp fee wrapped");

        assertEq(post.userPegged, pre.userPegged + minted, "mp user pegged returned");
        assertApproxEqAbs(minted, Math.mulDiv((wrapped - fee), (price * rate) / 1e18, 1e18), price, "mp user pegged");
        assertEq(post.userLeveraged, pre.userLeveraged, "mp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "mp user wrapped");

        assertEq(post.minterPegged, pre.minterPegged + minted, "mp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "mp minter leveraged");
        assertApproxEqAbs(post.minterWrapped, pre.minterWrapped + wrapped - fee, 3, "mp minter wrapped");
        assertApproxEqAbs(
            post.minterUnderlying,
            pre.minterUnderlying + ((wrapped - fee) * rate) / 1e18,
            3,
            "mp minter underlying"
        );
    }

    function _redeemPegged(uint256 wrapped) internal override {
        // REDEEM PEGGED
        Measures memory pre = _measure();
        uint256 pegged = (wrapped * price * rate) / 1e36;
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        // -------------------------------------------------------------------------
        Measures memory post = _measure();
        redeemPeggedMostBands = _mostBands(redeemPeggedMostBands, pre, post);

        uint256 fee = (uint256(initial(config.redeemPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "rp fee wrapped");

        assertEq(post.userPegged, pre.userPegged - pegged, "rp user pegged");
        assertEq(wrappedReturned, wrapped - fee, "rp user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged, "rp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rp user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged - pegged, "rp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "rp minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped - wrapped, "rp minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * rate) / 1e18, "rp minter underlying");
    }

    function _mintLeveraged(uint256 wrapped) internal override {
        // MINT LEVERAGED
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
        // ------------------------------------------------------------------
        Measures memory post = _measure();
        mintLeveragedMostBands = _mostBands(mintLeveragedMostBands, pre, post);

        uint256 fee = (uint256(initial(config.mintLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        // TODO: the fee is slightly low so is knowcking out all the rest below
        assertApproxEqAbs(post.feeWrapped, pre.feeWrapped + fee, 2, "ml fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "ml user pegged ");
        assertApproxEqAbs(
            minted,
            Math.mulDiv((wrapped - fee), (price * rate) / 1e18, 1e18),
            price,
            "ml user leveraged"
        );
        assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

        assertEq(post.minterPegged, pre.minterPegged, "ml minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
        assertApproxEqAbs(post.minterWrapped, pre.minterWrapped + wrapped - fee, 1, "ml minter wrapped");
        assertApproxEqAbs(
            post.minterUnderlying,
            pre.minterUnderlying + ((wrapped - fee) * rate) / 1e18,
            1,
            "ml minter underlying"
        );
    }

    function _redeemLeveraged(uint256 wrapped) internal override {
        // REDEEM LEVERAGED
        Measures memory pre = _measure();
        // uint256 leveraged = (wrapped * price * rate) / 1e36;
        uint256 leveragedTokenBalance = IMinter(minter).leveragedTokenBalance();
        uint256 collateralValue$ = IMinter(minter).collateralTokenBalance() * price;
        uint256 peggedValue$ = IMinter(minter).peggedTokenBalance() * IMinter(minter).peggedTokenPrice();
        uint256 amountCollateralValue$ = (wrapped * rate * price) / 1 ether;
        uint256 leveraged;
        if (leveragedTokenBalance > 0) {
            leveraged = Math.mulDiv(amountCollateralValue$, leveragedTokenBalance, collateralValue$ - peggedValue$);
        } else {
            leveraged = (collateralValue$ + amountCollateralValue$ - peggedValue$) / 1 ether;
        }
        // console2.log("leveraged=%s = %s", leveraged, (wrapped * price * rate) / 1e36);
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemLeveragedToken(leveraged, user, 0);
        // -------------------------------------------------------------------------------
        Measures memory post = _measure();
        redeemLeveragedMostBands = _mostBands(redeemLeveragedMostBands, pre, post);

        uint256 fee = (uint256(initial(config.redeemLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "rl fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "rl user pegged");
        assertEq(wrappedReturned, wrapped - fee, "rl user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged - leveraged, "rl user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rl user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged, "rl minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged - leveraged, "rl minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped - wrapped, "rl minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * rate) / 1e18, "rl minter underlying");
    }

    function test_effectOfRate() public {
        // scenarios:
        // * single band
        // * crossing bands not depegged
        // * crossing depegged line

        setUp_collateral(100 ether, 100 ether, user); // big enough numbers
        uint256 wrapped = 10 ether; // small enough
        uint256 snap = vm.snapshotState();
        _mintPegged(wrapped);
        vm.revertToState(snap);
        _redeemPegged(wrapped);
        vm.revertToState(snap);
        _mintLeveraged(wrapped);
        vm.revertToState(snap);
        _redeemLeveraged(wrapped);
    }
}

contract TestMinterFixedFeeRangedDepeg_ is TestMinterFixedFeeRange_ {
    function setUp() public virtual override {
        measurePrice = price / 2;
    }
}

contract TestMinterIntegralVarFees is TestMinterFeeRange {
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
        // we need flat rates across close boundaries to measure the error in crossing boundaries
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)), // mint pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 60, 70, 80, 90, 100, 110, 120)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(120, 110, 100, 90, 80, 70, 60, 50)) // redeem leveraged
        );
    }

    function _mintPegged(uint256 wrapped) internal override {
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

        assertEq(post.feeWrapped, postSteps.feeWrapped, "mp integral fee wrapped");
        assertEq(minted, mintedSteps, "mp integral minted");

        assertEq(post.userPegged, postSteps.userPegged, "mp integral user pegged");
        assertEq(post.userLeveraged, postSteps.userLeveraged, "mp integral user leveraged");
        assertEq(post.userWrapped, postSteps.userWrapped, "mp integral user wrapped");

        assertEq(post.minterPegged, postSteps.minterPegged, "mp integral minter pegged");
        assertEq(post.minterLeveraged, postSteps.minterLeveraged, "mp integral minter leveraged");
        assertEq(post.minterWrapped, postSteps.minterWrapped, "mp integral minter wrapped");
        assertEq(post.minterUnderlying, postSteps.minterUnderlying, "mp integral minter underlying");
    }

    function _redeemPegged(uint256 wrapped) internal override {
        // REDEEM PEGGED
        Measures memory pre = _measure();
        uint256 pegged = (wrapped * price * rate) / 1e36;
        vm.prank(user);
        uint256 wrappedReturned = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        // -------------------------------------------------------------------------

        Measures memory post = _measure();
        uint256 fee = (uint256(initial(config.redeemPeggedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "rp fee wrapped");

        assertEq(post.userPegged, pre.userPegged - pegged, "rp user pegged");
        assertEq(wrappedReturned, wrapped - fee, "rp user wrapped");
        assertEq(post.userLeveraged, pre.userLeveraged, "rp user leveraged");
        assertEq(post.userWrapped, pre.userWrapped + wrappedReturned, "rp user wrapped returned");

        assertEq(post.minterPegged, pre.minterPegged - pegged, "rp minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged, "rp minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped - wrapped, "rp minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * rate) / 1e18, "rp minter underlying");
    }

    function _mintLeveraged(uint256 wrapped) internal override {
        // MINT LEVERAGED
        Measures memory pre = _measure();
        vm.prank(user);
        uint256 minted = IMinter(minter).mintLeveragedToken(wrapped, user, 0);
        // ------------------------------------------------------------------
        Measures memory post = _measure();

        uint256 fee = (uint256(initial(config.mintLeveragedIncentiveConfig.incentiveRatios)) * wrapped) / 1 ether;
        assertEq(post.feeWrapped, pre.feeWrapped + fee, "ml fee wrapped");

        assertEq(post.userPegged, pre.userPegged, "ml user pegged ");
        assertEq(minted, Math.mulDiv((wrapped - fee), (price * rate) / 1e18, 1e18), "ml user leveraged");
        assertEq(post.userLeveraged, pre.userLeveraged + minted, "ml user leveraged returned");
        assertEq(post.userWrapped, pre.userWrapped - wrapped, "ml user wrapped");

        assertEq(post.minterPegged, pre.minterPegged, "ml minter pegged");
        assertEq(post.minterLeveraged, pre.minterLeveraged + minted, "ml minter leveraged");
        assertEq(post.minterWrapped, pre.minterWrapped + wrapped - fee, "ml minter wrapped");
        assertEq(post.minterUnderlying, pre.minterUnderlying + ((wrapped - fee) * rate) / 1e18, "ml minter underlying");
    }

    function _redeemLeveraged(uint256 wrapped) internal override {
        // REDEEM LEVERAGED
        Measures memory pre = _measure();
        // uint256 leveraged = (wrapped * price * rate) / 1e36;
        uint256 leveragedTokenBalance = IMinter(minter).leveragedTokenBalance();
        uint256 collateralValue$ = IMinter(minter).collateralTokenBalance() * price;
        uint256 peggedValue$ = IMinter(minter).peggedTokenBalance() * IMinter(minter).peggedTokenPrice();
        uint256 amountCollateralValue$ = (wrapped * rate * price) / 1 ether;
        uint256 leveraged;
        if (leveragedTokenBalance > 0) {
            leveraged = Math.mulDiv(amountCollateralValue$, leveragedTokenBalance, collateralValue$ - peggedValue$);
        } else {
            leveraged = (collateralValue$ + amountCollateralValue$ - peggedValue$) / 1 ether;
        }
        // console2.log("leveraged=%s = %s", leveraged, (wrapped * price * rate) / 1e36);
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
        assertEq(post.minterUnderlying, pre.minterUnderlying - (wrapped * rate) / 1e18, "rl minter underlying");
    }
}
