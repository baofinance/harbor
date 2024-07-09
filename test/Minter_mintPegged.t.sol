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
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinterMint } from "test/Minter_mint.t.sol";

contract TestMinterMintPegged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _freeMintPeggedToken(uint256 collateralIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(deployed.wstETH).balanceOf(owner.addr);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverBaoUSDIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(deployed.wstETH).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverBaoUSDBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 peggedSupplyBefore = IERC20(deployed.BaoUSD).totalSupply();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(owner.addr, receiver.addr, ownerCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(owner.addr);
        uint256 minted = IMinterTreasury(minter).freeMintPeggedToken(collateralIn, receiver.addr);
        //               ------------------------------------------------------------------------
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(owner.addr),
            ownerCollateralBefore - ownerCollateralDecrease,
            "collateral not paid"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "collateral not mis-transferred to receiver"
        );
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(receiver.addr),
            receiverBaoUSDBefore + receiverBaoUSDIncrease,
            "receiver baoUSD balance after"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore + receiverBaoUSDIncrease);
        assertEq(IERC20(deployed.BaoUSD).totalSupply(), peggedSupplyBefore + receiverBaoUSDIncrease);
    }

    function test_freeMintPegged() public {
        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, receiver.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, receiver.addr, zeroFeeRole)
        );
        vm.prank(receiver.addr);
        IMinterTreasury(minter).freeMintPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(0, receiver.addr);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(type(uint256).max, receiver.addr);
        //-----------------------------------------------------------------------

        // get collateral & allowance
        deal(address(deployed.wstETH), owner.addr, 10 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(0, receiver.addr);
        //-----------------------------------------------------------

        (, uint256 price, , ) = priceOracle.getPrice();

        // first mint
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, "collateral ratio = 1/0");
        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        _freeMintPeggedToken(1 ether);
        //---------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 100%");
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), price);

        // more than one mint
        _freeMintPeggedToken(2 ether);
        //---------------------------

        // check all-of function, when some
        _freeMintPeggedToken(type(uint256).max);
        //-------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _mintPeggedToken(uint256 collateralIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(deployed.wstETH).balanceOf(sender.addr);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(deployed.wstETH), sender.addr, senderCollateralDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        int256 mintPeggedFee = (int256(senderCollateralDecrease) *
            ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) / 1 ether;
        uint256 receiverBaoUSDIncrease = uint256(int256(price) * (int256(senderCollateralDecrease) - mintPeggedFee)) /
            1 ether;

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        // removed to save stack space uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(sender.addr, receiver.addr, senderCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(sender.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(collateralIn, receiver.addr, 0);
        //               -----------------------------------------------------------
        // TODO: removed to save stack space assertEq(
        //     minterLeveragedBalanceBefore,
        //     IMinter(minter).leveragedTokenBalance(),
        //     "leveraged tokens remain the same"
        // );
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBefore) + mintPeggedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(sender.addr),
            senderCollateralBefore - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(receiver.addr),
            receiverPeggedBefore + receiverBaoUSDIncrease,
            "receiver received baoUSD"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(minterCollateralBalanceBefore + senderCollateralDecrease) - mintPeggedFee),
            "minter is tracking the new collateral"
        );
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            minterPeggedBalanceBefore + receiverBaoUSDIncrease,
            "minter is tracking the new pegged"
        );
        //assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBalanceBefore, "no new leveraged tokens");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderCollateralDecrease) - mintPeggedFee),
            "wstETH has minter owning it"
        );
    }

    function test_mintPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when in the disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(0, 1 ether); // make collateral ratio ~ 2
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //--------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //--------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
    }

    function test_mintPeggedDisallow() public {
        // get collateral & allow
        deal(address(deployed.wstETH), sender.addr, 10 ether);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // no minting in disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR=1.0");
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //--------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "still CR=1.0");

        // no minting into rebalance zone
        setUp_collateral(3 ether, 2 ether); // make CR = 6/4  = 1.5
        assertEq(IMinter(minter).collateralRatio(), 6 ether / 4, "CR=1.5");
        assertGt(
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            10 ether / 8,
            "test should push CR below disallow"
        );
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(4 ether, receiver.addr, 0); // push CR to 10/8 = 1.25
        //--------------------------------------------------------
        // CR should now be disallow (1.3+), not 1.25
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            1,
            "CR=disallow(1.3) - right amount"
        );
        assertGe(
            IMinter(minter).collateralRatio(),
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            "CR>disallow(1.3), right side of boundary"
        );
    }

    function test_mintPegged() public {
        // set up some collateral,
        setUp_collateral(10 ether, 10 ether);
        (, uint256 price, , ) = priceOracle.getPrice();
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintPeggedToken(1 ether);
        //-----------------------

        // second mint
        _mintPeggedToken(2 ether);
        //-----------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(deployed.wstETH), sender.addr, collateral * 3);

        int256 mintPeggedFee = (int256(collateral) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) /
            1 ether;
        uint256 expectedPeggedTokenOut = uint256((int256(collateral) - mintPeggedFee) * int256(price)) / 1 ether;
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(collateral, receiver.addr, expectedPeggedTokenOut);
        //--------------------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                deployed.BaoUSD,
                expectedPeggedTokenOut + 1,
                expectedPeggedTokenOut
            )
        );
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(collateral, receiver.addr, expectedPeggedTokenOut + 1);
        //------------------------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore);

        // mint from all of balance
        mintPeggedFee =
            (int256(senderCollateralBefore) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) /
            1 ether;
        expectedPeggedTokenOut = uint256((int256(senderCollateralBefore) - mintPeggedFee) * int256(price)) / 1 ether;
        _mintPeggedToken(type(uint256).max);
        //---------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0, "transferred it all");
    }
}
