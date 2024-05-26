// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
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

        uint256 receiverCollateralIncrease = (ownerPeggedDecrease * 1 ether) / price;
        uint256 ownerPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, receiver.addr, ownerPeggedDecrease, receiverCollateralIncrease);
        vm.prank(owner.addr);
        uint256 returned = IMinterTreasury(minter).freeRedeemPeggedToken(peggedIn, receiver.addr);
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

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(owner.addr),
            ownerPeggedBefore - ownerPeggedDecrease,
            "pegged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemPegged() public {
        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, sender.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender.addr, zeroFeeRole)
        );
        vm.prank(sender.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(0, receiver.addr);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert(); // BaoUSD does not give an error message when burning tokens you don't have
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(type(uint256).max, receiver.addr);
        //------------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(deployed.BaoUSD).balanceOf(owner.addr);
        uint256 mintedBaoUSD = 10 ether;
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
        IMinterTreasury(minter).freeRedeemPeggedToken(0, receiver.addr);
        //--------------------------------------------------------------

        (, uint256 price, , ) = priceOracle.getPrice();
        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));

        // check that we can't redeem more than minter has minted, i.e 0
        // TODO: check this for non-free redeems
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, deployed.BaoUSD));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------------
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), 0);

        deal(address(deployed.wstETH), owner.addr, 10 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD);
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken((1 ether * 1 ether) / price, owner.addr);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(deployed.BaoUSD).balanceOf(owner.addr), mintedBaoUSD + 1 ether);

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), 1 ether);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, receiver.addr, 1 ether, (1 ether * 1 ether) / price);
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeRedeemPeggedToken(3 ether, receiver.addr);
        //-------------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), (1 ether * 1 ether) / price);

        // first normal redeem
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(7 ether, owner.addr);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 1");
        _freeRedeemPeggedToken(1 ether);
        //-----------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio still 1"); // there are no leveraged tokens in this test

        // more than one mint
        _freeRedeemPeggedToken(2 ether);
        //-----------------------------

        // check all-of function, when some
        _freeRedeemPeggedToken(type(uint256).max);
        //---------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Pegged
    //---------------------------------------------------------------------------------------------

    function _redeemPeggedToken(uint256 peggedIn) private {
        //(, uint256 price, , ) = priceOracle.getPrice();

        uint256 senderPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            senderPeggedDecrease = IERC20(deployed.wstETH).balanceOf(sender.addr);
        } else {
            senderPeggedDecrease = peggedIn;
        }

        deal(address(deployed.wstETH), sender.addr, senderPeggedDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        int256 redeemPeggedFee = (int256(senderPeggedDecrease) * redeemPeggedNormalIncentiveRatio) / 1 ether;
        uint256 receiverCollateralIncrease = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderPeggedDecrease) - redeemPeggedFee)
        );

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        // removed to save stack space uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(sender.addr, receiver.addr, senderPeggedDecrease, receiverCollateralIncrease);
        vm.prank(sender.addr);
        uint256 returned = IMinter(minter).redeemPeggedToken(senderPeggedDecrease, receiver.addr, 0);
        //   ------------------------------------------------------------------
        // TODO: removed to save stack space assertEq(minterPeggedBalanceBefore, IMinter(minter).peggedTokenBalance(), "pegged tokens remain the same");
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBefore) + redeemPeggedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(sender.addr),
            senderCollateralBefore - senderPeggedDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverCollateralIncrease,
            "receiver received leveraged"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(minterCollateralBalanceBefore + senderPeggedDecrease) - redeemPeggedFee),
            "minter is tracking the new collateral"
        );
        //assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBalanceBefore, "no new pegged");
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            minterLeveragedBalanceBefore + receiverCollateralIncrease,
            "minter is tracking new leveraged tokens"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderPeggedDecrease) - redeemPeggedFee),
            "wstETH has minter owning it"
        );
        assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_redeemPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver.addr, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver.addr, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(1 ether, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
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
    }

    function test_redeemPegged() public {
        setUp_collateral(10 ether, 0);
        priceOracle.setPrice(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _redeemPeggedToken(1 ether);
        //--------------------------

        // second mint
        _redeemPeggedToken(2 ether);
        //--------------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(deployed.wstETH), sender.addr, collateral * 10);

        int256 redeemPeggedFee = (int256(collateral) * redeemPeggedNormalIncentiveRatio) / 1 ether;
        uint256 expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(collateral) - redeemPeggedFee)
        );
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(collateral, receiver.addr, expectedLeveragedTokenOut);
        //--------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut + 1,
                expectedLeveragedTokenOut
            )
        );
        vm.prank(sender.addr);
        IMinter(minter).redeemPeggedToken(collateral, receiver.addr, expectedLeveragedTokenOut + 1);
        //------------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore);

        // mint from all of balance
        redeemPeggedFee = (int256(senderCollateralBefore) * redeemPeggedNormalIncentiveRatio) / 1 ether;
        expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderCollateralBefore) - redeemPeggedFee)
        );
        _redeemPeggedToken(type(uint256).max);
        //------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0, "transferred it all");
    }
}
