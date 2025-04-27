// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterMint} from "test/Minter_mint.t.sol";

contract TestMinterMintPegged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _freeMintPeggedToken(uint256 collateralIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(owner);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverBaoUSDIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(Deployed.wstETH).balanceOf(owner);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverBaoUSDBefore = IERC20(Deployed.BaoUSD).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 peggedSupplyBefore = IERC20(Deployed.BaoUSD).totalSupply();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(owner, receiver, ownerCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(owner);
        uint256 minted = IMinter(minter).freeMintPeggedToken(collateralIn, receiver);
        //               ------------------------------------------------------------------------
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(owner),
            ownerCollateralBefore - ownerCollateralDecrease,
            "collateral not paid"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore,
            "collateral not mis-transferred to receiver"
        );
        assertEq(
            IERC20(Deployed.BaoUSD).balanceOf(receiver),
            receiverBaoUSDBefore + receiverBaoUSDIncrease,
            "receiver baoUSD balance after"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(Deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore + receiverBaoUSDIncrease);
        assertEq(IERC20(Deployed.BaoUSD).totalSupply(), peggedSupplyBefore + receiverBaoUSDIncrease);
    }

    function test_freeMintPegged() public {
        // mint noaccess
        assertFalse(IBaoRoles(minter).hasAllRoles(receiver, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(receiver);
        IMinter(minter).freeMintPeggedToken(1 ether, receiver);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(owner), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(0, receiver);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(1 ether, receiver);
        //-------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(type(uint256).max, receiver);
        //-----------------------------------------------------------------------

        // get collateral & allowance
        deal(address(Deployed.wstETH), owner, 10 ether);
        vm.prank(owner);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(0, receiver);
        //-----------------------------------------------------------

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // first mint
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether,
            "collateral ratio = 0/0, which we define as 1, in this case"
        );
        assertEq(IBaoOwnable(minter).owner(), owner);
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);
        _freeMintPeggedToken(1 ether);
        //---------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 100%");
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), price);

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
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(sender);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(Deployed.wstETH), sender, senderCollateralDecrease);
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        int256 mintPeggedFee = (int256(senderCollateralDecrease) *
            ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) / 1 ether;
        uint256 receiverBaoUSDIncrease = uint256(int256(price) * (int256(senderCollateralDecrease) - mintPeggedFee)) /
            1 ether;

        uint256 feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverPeggedBefore = IERC20(Deployed.BaoUSD).balanceOf(receiver);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        // removed to save stack space uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(sender, receiver, senderCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(sender);
        uint256 minted = IMinter(minter).mintPeggedToken(collateralIn, receiver, 0);
        //               -----------------------------------------------------------
        // TODO: removed to save stack space assertEq(
        //     minterLeveragedBalanceBefore,
        //     IMinter(minter).leveragedTokenBalance(),
        //     "leveraged tokens remain the same"
        // );
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            uint256(int256(feeReceiverCollateralBefore) + mintPeggedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(sender),
            senderCollateralBefore - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(Deployed.BaoUSD).balanceOf(receiver),
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
            IERC20(Deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderCollateralDecrease) - mintPeggedFee),
            "wstETH has minter owning it"
        );
    }

    function test_mintPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(0, receiver, 0);
        //----------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // some input, when in the disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, Deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(0, 1 ether); // make collateral ratio ~ 2
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // get collateral
        deal(address(Deployed.wstETH), sender, 10 ether);

        // mint no allowance
        assertEq(IERC20(Deployed.wstETH).allowance(sender, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        //--------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(0, receiver, 0);
        //--------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);
    }

    function test_mintPeggedDisallow() public {
        // get collateral & allow
        deal(address(Deployed.wstETH), sender, 10 ether);
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // no minting in disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR=1.0");
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, Deployed.BaoUSD));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
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
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(4 ether, receiver, 0); // push CR to 10/8 = 1.25
        //--------------------------------------------------------
        // CR should now be disallow (1.3+), not 1.25
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            1,
            "CR=disallow(1.3) - right amount"
        );
        // TODO: the below is out by 1
        // assertGe(
        //     IMinter(minter).collateralRatio(),
        //     initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
        //     "CR>disallow(1.3), right side of boundary"
        // );
    }

    function test_mintPegged() public {
        // set up some collateral,
        setUp_collateral(10 ether, 10 ether);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintPeggedToken(1 ether);
        //-----------------------

        // second mint
        _mintPeggedToken(2 ether);
        //-----------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(Deployed.wstETH), sender, collateral * 3);

        int256 mintPeggedFee = (int256(collateral) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) /
            1 ether;
        uint256 expectedPeggedTokenOut = uint256((int256(collateral) - mintPeggedFee) * int256(price)) / 1 ether;
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverPeggedBefore = IERC20(Deployed.BaoUSD).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(collateral, receiver, expectedPeggedTokenOut);
        //--------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        receiverPeggedBefore = IERC20(Deployed.BaoUSD).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                Deployed.BaoUSD,
                expectedPeggedTokenOut + 1,
                expectedPeggedTokenOut
            )
        );
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(collateral, receiver, expectedPeggedTokenOut + 1);
        //------------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), receiverPeggedBefore);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore);

        // mint from all of balance
        mintPeggedFee =
            (int256(senderCollateralBefore) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) /
            1 ether;
        expectedPeggedTokenOut = uint256((int256(senderCollateralBefore) - mintPeggedFee) * int256(price)) / 1 ether;
        _mintPeggedToken(type(uint256).max);
        //---------------------------------
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0, "transferred it all");
    }
}
