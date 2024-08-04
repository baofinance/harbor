// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
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
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            ownerPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverLeveragedIncrease = (ownerPeggedDecrease * 1 ether) / price;
        uint256 ownerPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        uint256 receiverLeveragedBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, receiver.addr, ownerPeggedDecrease, receiverLeveragedIncrease);
        vm.prank(owner.addr);
        uint256 returned = IMinter(minter).freeRedeemPeggedToken(peggedIn, receiver.addr);
        //                 ----------------------------------------------------------------------
        assertEq(
            returned,
            receiverLeveragedIncrease,
            "unexpected amount of free collateral returned compared to price"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "collateral not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore - receiverLeveragedIncrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore - receiverLeveragedIncrease);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(owner.addr),
            ownerPeggedBefore - ownerPeggedDecrease,
            "pegged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemPegged() public {
        (, uint256 price, , ) = priceOracle.getPrice();

        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, sender.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender.addr, zeroFeeRole)
        );
        vm.prank(sender.addr);
        IMinter(minter).freeRedeemPeggedToken(price, receiver.addr);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(0, receiver.addr);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(price, receiver.addr);
        // 3 ----------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(type(uint256).max, receiver.addr);
        // 4 --------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);

        uint256 mintedBaoUSD = 10 * price;
        // deal(address(deployed.BaoUSD), owner.addr, mintedBaoUSD);
        vm.prank(IBaoUSD(deployed.BaoUSD).operator());
        IMintable(deployed.BaoUSD).mint(owner.addr, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).balanceOf(owner.addr));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(owner.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(0, receiver.addr);
        // 5 -----------------------------------------------------------

        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));

        // check that we can't redeem more than minter has minted, i.e 0
        // TODO: check this for non-free redeems
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(price, receiver.addr);
        // 6 ----------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), 0);

        deal(address(deployed.wstETH), owner.addr, 20 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD);
        vm.prank(owner.addr);
        IMinter(minter).freeMintPeggedToken(1 ether, owner.addr);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD + price);

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, receiver.addr, price, 1 ether);
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(price, receiver.addr);
        // 7 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), 1 ether);

        // first normal redeem
        vm.prank(owner.addr);
        IMinter(minter).freeMintPeggedToken(6 ether, owner.addr);
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
            ownerPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverLeveragedIncrease = ownerPeggedDecrease;
        uint256 ownerPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(minter);
        emit IMinter.SwapPeggedForLeveraged(owner.addr, receiver.addr, ownerPeggedDecrease, receiverLeveragedIncrease);
        vm.prank(owner.addr);
        uint256 returned = IMinter(minter).freeSwapPeggedForLeveraged(peggedIn, receiver.addr);
        //                 ----------------------------------------------------------------------
        assertEq(returned, receiverLeveragedIncrease, "unexpected amount of free collateral returned");
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "leveraged not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(owner.addr),
            ownerPeggedBefore - ownerPeggedDecrease,
            "pegged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeSwapPegged() public {
        (, uint256 price, , ) = priceOracle.getPrice();

        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, sender.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender.addr, zeroFeeRole)
        );
        vm.prank(sender.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver.addr);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(0, receiver.addr);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver.addr);
        // 3 ----------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(type(uint256).max, receiver.addr);
        // 4 --------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);

        uint256 mintedBaoUSD = 10 * price;
        // deal(address(deployed.BaoUSD), owner.addr, mintedBaoUSD);
        vm.prank(IBaoUSD(deployed.BaoUSD).operator());
        IMintable(deployed.BaoUSD).mint(owner.addr, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(deployed.BaoUSD).balanceOf(owner.addr));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(owner.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(0, receiver.addr);
        // 5 -----------------------------------------------------------

        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));

        // check that we can't swap more than minter has minted, i.e 0
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver.addr);
        // 6 ----------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), 0);

        deal(address(deployed.wstETH), owner.addr, 20 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD);
        vm.prank(owner.addr);
        IMinter(minter).freeMintPeggedToken(1 ether, owner.addr);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD + price);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(minter);
        emit IMinter.SwapPeggedForLeveraged(owner.addr, receiver.addr, price, price);
        vm.prank(owner.addr);
        IMinter(minter).freeSwapPeggedForLeveraged(price, receiver.addr);
        // 7 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), price);

        // first normal swap
        vm.prank(owner.addr);
        IMinter(minter).freeMintPeggedToken(6 ether, owner.addr);
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
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 senderPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            senderPeggedDecrease = IERC20(deployed.BaoUSD).balanceOf(sender.addr);
        } else {
            senderPeggedDecrease = peggedIn;
        }

        deal(address(deployed.BaoUSD), sender.addr, senderPeggedDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        uint256 redeemPeggedFee = (senderPeggedDecrease *
            uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) / price;
        uint256 receiverLeveragedIncrease = (senderPeggedDecrease * 1 ether) / price - redeemPeggedFee;

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender.addr);
        uint256 receiverLeveragedBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 totalPeggedBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(sender.addr, receiver.addr, senderPeggedDecrease, receiverLeveragedIncrease);
        vm.prank(sender.addr);
        uint256 returned = IMinter(minter).redeemPeggedToken(senderPeggedDecrease, receiver.addr, 0);
        //   ---------------------------------------------------------------------------------------
        assertEq(returned, receiverLeveragedIncrease, "unexpected amount returned compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBefore + redeemPeggedFee,
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(sender.addr),
            senderPeggedBefore - senderPeggedDecrease,
            "token sent"
        );
        assertEq(IERC20(deployed.BaoUSD).totalSupply(), totalPeggedBefore - senderPeggedDecrease, "token burned");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "collateral returned"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverLeveragedIncrease - redeemPeggedFee,
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
            minterCollateralBefore - receiverLeveragedIncrease - redeemPeggedFee,
            "wstETH has minter owning it"
        );
        assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_redeemPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(0, receiver.addr, 0);
        // 1 --------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver.addr, 0);
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        // 3 -------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        vm.expectRevert /*"ERC20: transfer amount exceeds balance"*/(); // BaoUSD just reverts with a subtraction underflow
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        // 4 -------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver.addr, 0);
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get tokens to redeem
        setUp_collateral(1 ether, 0, sender.addr);
        // deal(address(deployed.wstETH), sender.addr, 10 ether);

        // redeem no allowance
        assertEq(IERC20(deployed.BaoUSD).allowance(sender.addr, minter), 0);
        vm.expectRevert /*"ERC20: transfer amount exceeds allowance"*/();
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        // 6 ----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.BaoUSD).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
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
        (, uint256 price, , ) = priceOracle.getPrice();
        price *= 2;
        priceOracle.setPrice(price); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _redeemPeggedToken(price);
        // 1 --------------------

        // second mint
        _redeemPeggedToken(2 * price);
        // 2 ------------------------

        // check mintokenout
        uint256 collateral = 3 ether;
        uint256 pegged = (collateral * price) / 1 ether;

        deal(address(deployed.BaoUSD), sender.addr, pegged * 2);
        vm.prank(sender.addr);

        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);
        deal(address(deployed.wstETH), sender.addr, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender.addr);
        uint256 receiverLeveragedBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(pegged, receiver.addr, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverLeveragedBefore + expectedCollateralOut);

        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender.addr), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(sender.addr);
        receiverLeveragedBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                deployed.wstETH,
                expectedCollateralOut + 1,
                expectedCollateralOut
            )
        );
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(pegged, receiver.addr, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverLeveragedBefore);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender.addr), senderPeggedBefore);

        // mint from all of balance
        redeemPeggedFee =
            (senderPeggedBefore * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            price;
        expectedCollateralOut = collateral - redeemPeggedFee;

        _redeemPeggedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverLeveragedBefore + expectedCollateralOut);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(sender.addr), 0, "transferred it all");
    }
}
