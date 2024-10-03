// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IOwnableRoles, IOwnable } from "@bao/interfaces/IOwnableRoles.sol";
import { IMinter } from "src/minter/IMinter.sol";
import { IMintable } from "@bao/interfaces/IMintable.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/clog.sol";
import { TestMinterMint } from "test/Minter_mint.t.sol";

contract TestMinterRedeemPegged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Redeem Pegged
    //---------------------------------------------------------------------------------------------

    function _freeRedeemPeggedToken(uint256 peggedIn) private {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        uint256 ownerPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            ownerPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(owner);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverCollateralIncrease = (ownerPeggedDecrease * 1 ether) / price;
        uint256 ownerPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(owner);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner, receiver, ownerPeggedDecrease, receiverCollateralIncrease);
        vm.prank(owner);
        uint256 returned = IMinter(minter).freeRedeemPeggedToken(peggedIn, receiver);
        //                 ----------------------------------------------------------------------
        assertEq(
            returned,
            receiverCollateralIncrease,
            "unexpected amount of free collateral returned compared to price"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore - receiverCollateralIncrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore - receiverCollateralIncrease);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(owner),
            ownerPeggedBefore - ownerPeggedDecrease,
            "pegged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemPegged() public {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IOwnableRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeRedeemPeggedToken(price, receiver);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(0, receiver);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(price, receiver);
        // 3 ----------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(type(uint256).max, receiver);
        // 4 --------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(deployed.BaoUSD).balanceOf(owner);

        uint256 mintedBaoUSD = 10 * price;
        // deal(address(deployed.BaoUSD), owner, mintedBaoUSD);
        vm.prank(IBaoUSD(deployed.BaoUSD).operator());
        IMintable(deployed.BaoUSD).mint(owner, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).balanceOf(owner));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(owner);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(0, receiver);
        // 5 -----------------------------------------------------------

        assertEq(IOwnable(minter).owner(), owner);

        // check that we can't redeem more than minter has minted, i.e 0
        // TODO: check this for non-free redeems
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(price, receiver);
        // 6 ----------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), 0);

        deal(address(deployed.wstETH), owner, 20 ether);
        vm.prank(owner);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD);
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(1 ether, owner);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD + price);

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner, receiver, price, 1 ether);
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(price, receiver);
        // 7 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), 1 ether);

        // first normal redeem
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(6 ether, owner);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 1");
        _freeRedeemPeggedToken(price);
        // 8 ------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio still 1"); // there are no leveraged tokens in this test

        // more than one mint
        _freeRedeemPeggedToken(2 * price);
        // 9 ----------------------------

        // check all-of function, when some
        _freeRedeemPeggedToken(type(uint256).max);
        // 10 -----------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Free Swap Pegged
    //---------------------------------------------------------------------------------------------

    function _freeSwapPeggedForLeveraged(uint256 peggedIn) private {
        uint256 ownerPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            ownerPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(owner);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverLeveragedIncrease = ownerPeggedDecrease;
        uint256 ownerPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(owner);
        uint256 receiverCollateralBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(minter);
        emit IMinter.SwapPeggedForLeveraged(owner, receiver, ownerPeggedDecrease, receiverLeveragedIncrease);
        vm.prank(owner);
        uint256 returned = IMinter(minter).freeSwapPeggedForLeveraged(peggedIn, receiver);
        //                 ----------------------------------------------------------------------
        assertEq(returned, receiverLeveragedIncrease, "unexpected amount of free collateral returned");
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            receiverCollateralBefore + receiverLeveragedIncrease,
            "leveraged not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(owner),
            ownerPeggedBefore - ownerPeggedDecrease,
            "pegged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeSwapPegged() public {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IOwnableRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(0, receiver);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver);
        // 3 ----------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(type(uint256).max, receiver);
        // 4 --------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(deployed.BaoUSD).balanceOf(owner);

        uint256 mintedBaoUSD = 10 * price;
        // deal(address(deployed.BaoUSD), owner, mintedBaoUSD);
        vm.prank(IBaoUSD(deployed.BaoUSD).operator());
        IMintable(deployed.BaoUSD).mint(owner, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).balanceOf(owner));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(owner);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(0, receiver);
        // 5 -----------------------------------------------------------

        assertEq(IOwnable(minter).owner(), owner);

        // check that we can't swap more than minter has minted, i.e 0
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver);
        // 6 ----------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), 0);

        deal(address(deployed.wstETH), owner, 20 ether);
        vm.prank(owner);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD);
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(1 ether, owner);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner), mintedBaoUSD + price);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(minter);
        emit IMinter.SwapPeggedForLeveraged(owner, receiver, price, price);
        vm.prank(owner);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver);
        // 7 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), price);

        // first normal swap
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(6 ether, owner);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++
        uint256 beforeCR = IMinter(minter).collateralRatio();
        _freeSwapPeggedForLeveraged(price);
        // 8 -----------------------------
        assertGt(IMinter(minter).collateralRatio(), beforeCR, "collateral ratio should be greater");

        // more than one swap
        _freeSwapPeggedForLeveraged(2 * price);
        // 9 ----------------------------

        // check all-of function, when some
        _freeSwapPeggedForLeveraged(type(uint256).max);
        // 10 -----------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Pegged
    //---------------------------------------------------------------------------------------------

    function _redeemPeggedToken(uint256 peggedIn) private {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        uint256 senderPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            senderPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(sender);
        } else {
            senderPeggedDecrease = peggedIn;
        }

        deal(address(deployed.BaoUSD), sender, senderPeggedDecrease);
        vm.prank(sender);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);
        uint256 totalPeggedBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        uint256 redeemPeggedFeeInPegged = (senderPeggedDecrease *
            uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) / 1 ether;

        uint256 receiverCollateralIncrease = (collateralRatioBefore < 1 ether)
            ? (((peggedIn - redeemPeggedFeeInPegged) * minterCollateralBalanceBefore) / minterPeggedBalanceBefore)
            : ((senderPeggedDecrease - redeemPeggedFeeInPegged) * 1 ether) / price;
        uint256 redeemPeggedFee = (collateralRatioBefore < 1 ether)
            ? ((redeemPeggedFeeInPegged * minterCollateralBalanceBefore) / minterPeggedBalanceBefore)
            : (redeemPeggedFeeInPegged * 1 ether) / price;

        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(sender, receiver, senderPeggedDecrease, receiverCollateralIncrease);
        vm.prank(sender);
        uint256 returned = IMinter(minter).redeemPeggedToken(senderPeggedDecrease, receiver, 0);
        //   ---------------------------------------------------------------------------------------
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver),
            feeReceiverCollateralBefore + redeemPeggedFee,
            "fee transferred"
        );
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), senderPeggedBefore - senderPeggedDecrease, "token sent");
        assertEq(IERC20(deployed.BaoUSD).totalSupply(), totalPeggedBefore - senderPeggedDecrease, "token burned");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral returned"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemPeggedFee,
            "minter is tracking the collateral"
        );
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            minterPeggedBalanceBefore - senderPeggedDecrease,
            "minter is tracking the pegged tokens"
        );
        // TODO: track the reserve pool too
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            minterCollateralBefore - receiverCollateralIncrease - redeemPeggedFee,
            "wstETH has minter owning it"
        );
        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_redeemPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        // 1 --------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 3 -------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        vm.expectRevert /*"ERC20: transfer amount exceeds balance"*/(); // BaoUSD just reverts with a subtraction underflow
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 4 -------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // get tokens to redeem
        setUp_collateral(1 ether, 0, sender);
        // deal(address(deployed.wstETH), sender, 10 ether);

        // redeem no allowance
        assertEq(IERC20(deployed.BaoUSD).allowance(sender, minter), 0);
        vm.expectRevert /*"ERC20: transfer amount exceeds allowance"*/();
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 6 ----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(deployed.BaoUSD).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver), 0);
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_redeemPeggedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
        // mixed bonus and fee
    }

    function test_redeemPegged() public {
        setUp_collateral(20 ether, 0);
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        price *= 2;
        MockPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first redeem
        _redeemPeggedToken(price);
        // 1 --------------------

        // second redeem
        _redeemPeggedToken(2 * price);
        // 2 ------------------------

        // check mintokenout
        uint256 collateral = 3 ether;
        uint256 pegged = (collateral * price) / 1 ether;

        deal(address(deployed.BaoUSD), sender, pegged * 2);
        vm.prank(sender);

        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);
        deal(address(deployed.wstETH), sender, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender);
        receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                deployed.wstETH,
                expectedCollateralOut + 1,
                expectedCollateralOut
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), senderPeggedBefore);

        // mint from all of balance
        redeemPeggedFee =
            (senderPeggedBefore * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            price;
        expectedCollateralOut = collateral - redeemPeggedFee;

        _redeemPeggedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), 0, "transferred it all");
    }

    function test_redeemPeggedDepegged() public {
        setUp_collateral(20 ether, 0);
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        price /= 2;
        MockPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 0.5, tro depeg
        assertEq(IMinter(minter).collateralRatio(), 1 ether / 2);

        // first mint
        _redeemPeggedToken(price);
        // 1 --------------------

        /*
        // second mint
        _redeemPeggedToken(2 * price);
        // 2 ------------------------

        // check mintokenout
        uint256 collateral = 3 ether;
        uint256 pegged = (collateral * price) / 1 ether;

        deal(address(deployed.BaoUSD), sender, pegged * 2);
        vm.prank(sender);

        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);
        deal(address(deployed.wstETH), sender, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender);
        receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                deployed.wstETH,
                expectedCollateralOut + 1,
                expectedCollateralOut
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), senderPeggedBefore);

        // mint from all of balance
        redeemPeggedFee =
            (senderPeggedBefore * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            price;
        expectedCollateralOut = collateral - redeemPeggedFee;

        _redeemPeggedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender), 0, "transferred it all");
*/
    }
}
