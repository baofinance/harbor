// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterMint} from "test/Minter_mint.t.sol";

contract TestMinterRedeemLeveraged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    function _freeRedeemLeveragedToken(uint256 leveragedIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerLeveragedDecrease;
        if (leveragedIn == type(uint256).max) {
            ownerLeveragedDecrease = IERC20(leveragedToken).balanceOf(zeroFee);
        } else {
            ownerLeveragedDecrease = leveragedIn;
        }
        uint256 minterLeveragedBefore = IMinter(minter).leveragedTokenBalance();
        if (ownerLeveragedDecrease > 0 && ownerLeveragedDecrease > minterLeveragedBefore)
            ownerLeveragedDecrease = minterLeveragedBefore;
        // uint256 receiverCollateralIncrease = IMinter(minter).collateralForLeverageTokens(ownerLeveragedDecrease);
        // TODO: this fails with actionpaused
        // (, , , uint256 receiverCollateralIncrease, , ) = IMinter(minter).redeemLeveragedTokenDryRun(
        //     ownerLeveragedDecrease
        // );
        // assertEq(
        //     receiverCollateralIncrease,
        //     (ownerLeveragedDecrease * 1 ether) / price,
        //     "collateral for leveraged calc is correct"
        // );
        uint256 receiverCollateralIncrease = (ownerLeveragedDecrease * 1 ether) / price;

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 ownerLeveragedBefore = IERC20(leveragedToken).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before freeRedeemLeveraged"
        );

        vm.expectEmit(true, true, true, true, minter);
        emit IMinter.RedeemLeveragedToken(zeroFee, receiver, ownerLeveragedDecrease, receiverCollateralIncrease);
        vm.prank(zeroFee);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(leveragedIn, receiver);
        //                 ---------------------------------------------------------------
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "free redeem leveraged doesn't change the leveraged price"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance after freeRedeemLeveraged"
        );
        assertEq(
            returned,
            receiverCollateralIncrease,
            "unexpected amount of free collateral returned compared to price"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore - receiverCollateralIncrease);
        assertEq(IERC20(Deployed.wstETH).balanceOf(minter), minterWstETHBefore - receiverCollateralIncrease);

        assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBefore - ownerLeveragedDecrease);
        assertEq(
            IERC20(leveragedToken).balanceOf(zeroFee),
            ownerLeveragedBefore - ownerLeveragedDecrease,
            "leveraged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemLeveraged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "should have no minted leveraged tokens");

        // mint noaccess
        assertFalse(IBaoRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        // 1 ----------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(0, receiver);
        // 2 ------------------------------------------------

        // no longer support -1
        // // all input, when none
        // vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        // vm.prank(zeroFee);
        // IMinter(minter).freeRedeemLeveragedToken(type(uint256).max, receiver);
        // // 3 ----------------------------------------------------------------

        // some input, when none
        assertEq(IERC20(leveragedToken).totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        // 4 ----------------------------------------------------

        // some input, when none, but minter has some
        assertEq(IBaoOwnable(minter).owner(), owner);
        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, sender); // not zeroFee
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++

        //vm.expectRevert("ERC20: transfer amount exceeds allowance");
        assertEq(IERC20(leveragedToken).allowance(zeroFee, minter), 0, "zeroFee has none allowed");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 0, 1 ether));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(1 ether, receiver);
        // 5 ------------------------------------------------------

        //vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(zeroFee);
        IERC20(leveragedToken).approve(minter, 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), 0, "zeroFee has none");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, zeroFee, 0, 1 ether));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(1 ether, receiver);
        // 6 ------------------------------------------------------

        uint256 leveragedTotalSupplyBefore = IERC20(leveragedToken).totalSupply();
        // console2.log("leveragedTotalSupplyBefore=%s", leveragedTotalSupplyBefore);
        uint256 leveragedBalanceOfOwnerBefore = IERC20(leveragedToken).balanceOf(zeroFee);
        // console2.log("leveragedBalanceOfOwnerBefore=%s", leveragedBalanceOfOwnerBefore);

        // console2.log("leveragedTokenPrice=%s", IMinter(minter).leveragedTokenPrice());
        uint256 mintedLeveraged = price;
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(
            leveragedTotalSupplyBefore + mintedLeveraged,
            IERC20(leveragedToken).totalSupply(),
            "total supply correct after mint"
        );
        assertEq(
            leveragedBalanceOfOwnerBefore + mintedLeveraged,
            IERC20(leveragedToken).balanceOf(zeroFee),
            "zeroFee owns correct after mint"
        );
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(0, receiver);
        // 7 ------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged, "nothing redeemed");

        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged + price, "minted more 1:price");

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        vm.prank(zeroFee);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0, "receiver has none");
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 2 * price);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemLeveragedToken(zeroFee, receiver, price, 1 ether);
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        // 8 -----------------------------------------------------------------
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 1 * price);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 1 ether);

        // first normal redeem
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(6 ether, zeroFee);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++

        _freeRedeemLeveragedToken(price);
        // 9 ---------------------------

        // more than one redeem
        _freeRedeemLeveragedToken(2 * price);
        // 10 ------------------------------

        // // check all-of function, when some
        // _freeRedeemLeveragedToken(type(uint256).max);
        // // 11 --------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    function _redeemLeveragedToken(uint256 leveragedIn) private {
        uint256 senderLeveragedDecrease;
        if (leveragedIn == type(uint256).max) {
            senderLeveragedDecrease = IERC20(leveragedToken).balanceOf(sender);
        } else {
            senderLeveragedDecrease = leveragedIn;
        }

        vm.prank(sender);
        IERC20(leveragedToken).approve(minter, type(uint256).max);

        (, uint256 redeemLeveragedFee, , uint256 receiverCollateralIncrease, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(senderLeveragedDecrease);

        //  = IMinter(minter).collateralForLeverageTokens(
        //     (senderLeveragedDecrease * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) /
        //         1 ether
        // );
        // uint256 receiverCollateralIncrease = IMinter(minter).collateralForLeverageTokens(
        //     (senderLeveragedDecrease *
        //         (1 ether - uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios)))) / 1 ether
        // );

        uint256 feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 totalLeveragedBefore = IERC20(leveragedToken).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();
        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();

        vm.expectEmit(true, true, true, false, minter);
        emit IMinter.RedeemLeveragedToken(sender, receiver, senderLeveragedDecrease, 0);
        vm.prank(sender);
        uint256 returned = IMinter(minter).redeemLeveragedToken(senderLeveragedDecrease, receiver, 0);
        // -----------------------------------------------------------------------------------------------
        assertEq(leveragedPrice, IMinter(minter).leveragedTokenPrice(), "leveraged price doesn't change");
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            feeReceiverCollateralBefore + redeemLeveragedFee,
            1,
            "fee transferred"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(sender),
            senderLeveragedBefore - senderLeveragedDecrease,
            "token sent"
        );
        assertEq(IERC20(leveragedToken).totalSupply(), totalLeveragedBefore - senderLeveragedDecrease, "token burned");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral returned"
        );
        assertApproxEqAbs(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemLeveragedFee,
            1,
            "minter is tracking the collateral"
        );
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            minterLeveragedBalanceBefore - senderLeveragedDecrease,
            "minter is tracking the leveraged tokens"
        );
        // TODO: track the reserve pool too
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(minter),
            minterCollateralBefore - receiverCollateralIncrease - redeemLeveragedFee,
            1,
            "wstETH has minter owning it"
        );
        assertLt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio < before");
    }

    function test_redeemLeveragedBasic() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        // 1 --------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver, 0);
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when no leveraged tokens
        assertEq(IERC20(leveragedToken).totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        // 3 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // collateral ratio 1.0
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        // vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, 0, 1 ether));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        // 4 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver, 0);
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(leveragedToken).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        // 6 ----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // disallowed
        setUp_collateral(10 ether, 1 ether, sender); // sender has 6 leveraged, CR = 11/10
        assertLt(IMinter(minter).collateralRatio(), 13e17, "shoule be in disallowed");

        // TODO: test all the other places this error is raised
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        // 7 ----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // first normal redeem
        setUp_collateral(0, 5 ether, sender); // sender has 6 now
        setUp_collateral(10 ether, 100 ether); // make a nice collateral ratio

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        // 8 -----------------------------------------------

        assertEq(IERC20(leveragedToken).allowance(sender, minter), 10 ether, "minter has no allowance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 10 ether, 1 * price)
        );
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(1 * price, receiver, 0);
        // 9 -------------------------------------------------------

        vm.prank(sender);
        IERC20(leveragedToken).approve(minter, 20 * price);
        assertEq(IERC20(leveragedToken).balanceOf(sender), 6 * price, "sender has 6");
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(1 * price, receiver, 0);
        // 10 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender has 5");

        // TODO: check all 4+ places where ReturnInsufficientAmount can be reverted
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                6 ether - (6 * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))),
                6 ether
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(6 * price, receiver, 6 ether);
        // 11 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender still has 5");

        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                5 ether - (5 * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))),
                5 ether
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(5 * price, receiver, 5 ether);
        // 12 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender still has 5");

        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(5 * price, receiver, 0);
        // 13 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 0, "sender has 0");
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_redeemLeveragedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
        // mixed bonus and fee
    }

    function test_redeemLeveragedNormal() public {
        setUp_collateral(20 ether, 0);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        setUp_collateral(0, 10 ether, sender);
        // first mint
        _redeemLeveragedToken(price);
        // 1 --------------------

        // second mint
        _redeemLeveragedToken(2 * price);
        // 2 ------------------------

        // check mintokenout
        uint256 collateral = 3 ether;
        uint256 leveraged = (collateral * price) / 1 ether;

        (, uint256 redeemLeveragedFee, , uint256 expectedCollateralOut, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(leveraged);
        assertEq(
            redeemLeveragedFee,
            (collateral * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) / 1 ether,
            "fee correct"
        );
        assertEq(expectedCollateralOut, collateral - redeemLeveragedFee, "collateral out correct");

        deal(address(leveragedToken), sender, leveraged * 2);
        vm.prank(sender);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        deal(address(Deployed.wstETH), sender, collateral * 10);

        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(leveraged, receiver, expectedCollateralOut - 0.025 ether);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);
        // clog("senderLeveragedBefore", senderLeveragedBefore);
        // clog("leveraged", leveraged);

        assertEq(IERC20(leveragedToken).balanceOf(sender), senderLeveragedBefore - leveraged);

        senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
        receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                expectedCollateralOut,
                expectedCollateralOut + 1
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemLeveragedToken(leveraged, receiver, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(leveragedToken).balanceOf(sender), senderLeveragedBefore);

        // mint from all of balance
        // redeemLeveragedFee = IMinter(minter).collateralForLeverageTokens(
        //     (senderLeveragedBefore * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) / 1 ether
        // );
        // expectedCollateralOut = collateral - redeemLeveragedFee;
        (, redeemLeveragedFee, , expectedCollateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(
            senderLeveragedBefore
        );

        _redeemLeveragedToken(type(uint256).max);
        // 5 --------------------------------
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + expectedCollateralOut,
            1,
            "out correct"
        );
        assertEq(IERC20(leveragedToken).balanceOf(sender), 0, "transferred it all");
    }
}
