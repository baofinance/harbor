// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinterMint } from "test/Minter_mint.t.sol";

contract TestMinterRedeemLeveraged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    function _freeRedeemLeveragedToken(uint256 leveragedIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerLeveragedDecrease;
        if (leveragedIn == type(uint256).max) {
            ownerLeveragedDecrease = IERC20(leveragedToken).balanceOf(owner.addr);
        } else {
            ownerLeveragedDecrease = leveragedIn;
        }
        uint256 minterLeveragedBefore = IMinter(minter).leveragedTokenBalance();
        if (ownerLeveragedDecrease > 0 && ownerLeveragedDecrease > minterLeveragedBefore)
            ownerLeveragedDecrease = minterLeveragedBefore;

        uint256 receiverCollateralIncrease = (ownerLeveragedDecrease * 1 ether) / price;
        uint256 ownerLeveragedBefore = IERC20(leveragedToken).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemLeveragedToken(
            owner.addr,
            receiver.addr,
            ownerLeveragedDecrease,
            receiverCollateralIncrease
        );
        vm.prank(owner.addr);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(leveragedIn, receiver.addr);
        //                 ----------------------------------------------------------------------
        assertEq(
            returned,
            receiverCollateralIncrease,
            "unexpected amount of free collateral returned compared to price"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore - receiverCollateralIncrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore - receiverCollateralIncrease);

        assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBefore - ownerLeveragedDecrease);
        assertEq(
            IERC20(leveragedToken).balanceOf(owner.addr),
            ownerLeveragedBefore - ownerLeveragedDecrease,
            "leveraged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemLeveraged() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "should have no minted leveraged tokens");

        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, sender.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender.addr, zeroFeeRole)
        );
        vm.prank(sender.addr);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver.addr);
        // 1 -----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(0, receiver.addr);
        // 2 -------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(type(uint256).max, receiver.addr);
        // 3 -----------------------------------------------------------------------------

        // some input, when none
        //vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver.addr);
        // 4 -----------------------------------------------------------------

        // some input, when none, but minter has some

        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));
        deal(address(deployed.wstETH), owner.addr, 20 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
        vm.prank(owner.addr);
        IMinter(minter).freeMintLeveragedToken(1 ether, sender.addr); // not owner
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        //vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner.addr, 0, 1 ether));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(1 ether, receiver.addr);
        // 5 -----------------------------------------------------------------

        uint256 leveragedTotalSupplyBefore = IERC20(leveragedToken).totalSupply();
        uint256 leveragedBalanceOfOwnerBefore = IERC20(leveragedToken).balanceOf(owner.addr);

        uint256 mintedLeveraged = price;
        vm.prank(owner.addr);
        IMinter(minter).freeMintLeveragedToken(1 ether, owner.addr);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(leveragedTotalSupplyBefore + mintedLeveraged, IERC20(leveragedToken).totalSupply());
        assertEq(leveragedBalanceOfOwnerBefore + mintedLeveraged, IERC20(leveragedToken).balanceOf(owner.addr));
        assertEq(IERC20(leveragedToken).balanceOf(owner.addr), mintedLeveraged);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(0, receiver.addr);
        // 6 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(owner.addr), mintedLeveraged, "nothing redeemed");

        vm.prank(owner.addr);
        IMinter(minter).freeMintLeveragedToken(1 ether, owner.addr);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(leveragedToken).balanceOf(owner.addr), mintedLeveraged + price, "minted more 1:price");

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0, "receiver has none");
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 2 * price);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemLeveragedToken(owner.addr, receiver.addr, price, 1 ether);
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver.addr);
        // 7 -----------------------------------------------------------------
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 1 * price);
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), 1 ether);

        // first normal redeem
        vm.prank(owner.addr);
        IMinter(minter).freeMintLeveragedToken(6 ether, owner.addr);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        _freeRedeemLeveragedToken(price);
        // 8 ---------------------------

        // more than one redeem
        _freeRedeemLeveragedToken(2 * price);
        // 9 --------------------------------

        // check all-of function, when some
        _freeRedeemLeveragedToken(type(uint256).max);
        // 10 --------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    function _redeemLeveragedToken(uint256 leveragedIn) private {
        uint256 senderLeveragedDecrease;
        if (leveragedIn == type(uint256).max) {
            senderLeveragedDecrease = IERC20(leveragedToken).balanceOf(sender.addr);
        } else {
            senderLeveragedDecrease = leveragedIn;
        }
        //clog("senderLeveragedDecrease", senderLeveragedDecrease);

        vm.prank(sender.addr);
        IERC20(leveragedToken).approve(minter, type(uint256).max);

        // clog("redeemLeveragedNormalIncentiveRatio", ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios));
        uint256 redeemLeveragedFee = IMinter(minter).collateralForLeverageTokens(
            (senderLeveragedDecrease * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) /
                1 ether
        );
        // clog("redeemLeveragedFee", redeemLeveragedFee);
        uint256 receiverCollateralIncrease = IMinter(minter).collateralForLeverageTokens(
            (senderLeveragedDecrease *
                (1 ether - uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios)))) / 1 ether
        );
        // clog("receiverCollateralIncrease", receiverCollateralIncrease);

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 totalLeveragedBefore = IERC20(leveragedToken).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemLeveragedToken(
            sender.addr,
            receiver.addr,
            senderLeveragedDecrease,
            receiverCollateralIncrease
        );
        vm.prank(sender.addr);
        uint256 returned = IMinter(minter).redeemLeveragedToken(senderLeveragedDecrease, receiver.addr, 0);
        // -----------------------------------------------------------------------------------------------
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBefore + redeemLeveragedFee,
            1,
            "fee transferred"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(sender.addr),
            senderLeveragedBefore - senderLeveragedDecrease,
            "token sent"
        );
        assertEq(IERC20(leveragedToken).totalSupply(), totalLeveragedBefore - senderLeveragedDecrease, "token burned");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
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
            IERC20(deployed.wstETH).balanceOf(minter),
            minterCollateralBefore - receiverCollateralIncrease - redeemLeveragedFee,
            1,
            "wstETH has minter owning it"
        );
        assertLt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio < before");
    }

    function test_redeemLeveragedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(0, receiver.addr, 0);
        // 1 --------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver.addr, 0);
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(1 ether, receiver.addr, 0);
        // 3 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        // vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(1 ether, receiver.addr, 0);
        // 4 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver.addr, 0);
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // get tokens to redeem
        setUp_collateral(1 ether, 0, sender.addr);
        // deal(address(deployed.wstETH), sender.addr, 10 ether);

        // get allowance
        vm.prank(sender.addr);
        IERC20(leveragedToken).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(0, receiver.addr, 0);
        // 6 ----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_redeemLeveragedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
        // mixed bonus and fee
    }

    function test_redeemLeveraged() public {
        setUp_collateral(20 ether, 0);
        (, uint256 price, , ) = priceOracle.getPrice();
        price *= 2;
        priceOracle.setPrice(price); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        setUp_collateral(0, 10 ether, sender.addr);
        // first mint
        _redeemLeveragedToken(price);
        // 1 --------------------

        // second mint
        _redeemLeveragedToken(2 * price);
        // 2 ------------------------

        // check mintokenout
        uint256 collateral = 3 ether;
        uint256 leveraged = IMinter(minter).leverageTokensForCollateral(collateral);

        deal(address(leveragedToken), sender.addr, leveraged * 2);
        vm.prank(sender.addr);

        IERC20(leveragedToken).approve(minter, type(uint256).max);
        deal(address(deployed.wstETH), sender.addr, collateral * 10);

        uint256 redeemLeveragedFee = (collateral *
            uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) / 1 ether;
        uint256 expectedCollateralOut = collateral - redeemLeveragedFee;

        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).redeemLeveragedToken(leveraged, receiver.addr, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverCollateralBefore + expectedCollateralOut);
        // clog("senderLeveragedBefore", senderLeveragedBefore);
        // clog("leveraged", leveraged);

        assertEq(IERC20(leveragedToken).balanceOf(sender.addr), senderLeveragedBefore - leveraged);

        senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender.addr);
        receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);

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
        IMinter(minter).redeemLeveragedToken(leveraged, receiver.addr, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverCollateralBefore);
        assertEq(IERC20(leveragedToken).balanceOf(sender.addr), senderLeveragedBefore);

        // mint from all of balance
        redeemLeveragedFee = IMinter(minter).collateralForLeverageTokens(
            (senderLeveragedBefore * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) / 1 ether
        );
        expectedCollateralOut = collateral - redeemLeveragedFee;

        // clog("leverageToken.balanceOf(sender)", IERC20(leveragedToken).balanceOf(sender.addr));
        _redeemLeveragedToken(type(uint256).max);
        // 5 --------------------------------
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore + expectedCollateralOut,
            1,
            "out correct"
        );
        assertEq(IERC20(leveragedToken).balanceOf(sender.addr), 0, "transferred it all");
    }
}
