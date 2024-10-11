// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";
import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { IMinter } from "src/minter/IMinter.sol";
import { Deployed } from "@bao/Deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinterMint } from "test/Minter_mint.t.sol";

contract TestMinterMintLeveraged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Mint Leveraged
    //---------------------------------------------------------------------------------------------

    function _freeMintLeveragedToken(uint256 collateralIn) private {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(owner);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverLeveragedIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(Deployed.wstETH).balanceOf(owner);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 minterLeveragedBefore = IMinter(minter).leveragedTokenBalance();
        uint256 leveragedSupplyBefore = IERC20(leveragedToken).totalSupply();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(owner, receiver, ownerCollateralDecrease, receiverLeveragedIncrease);
        vm.prank(owner);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(collateralIn, receiver);
        //               ---------------------------------------------------------------------------
        assertEq(minted, receiverLeveragedIncrease, "unexpected amount free minted leveraged compared to price");
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
            IERC20(leveragedToken).balanceOf(receiver),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "receiver leveraged balance after"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(Deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBefore + receiverLeveragedIncrease);
        assertEq(IERC20(leveragedToken).totalSupply(), leveragedSupplyBefore + receiverLeveragedIncrease);

        if (collateralRatioBefore != type(uint256).max)
            assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio > before");
    }

    function test_freeMintLeveraged() public {
        // mint noaccess
        assertFalse(IOwnableRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(owner), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(owner);
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        //-------------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintLeveragedToken(type(uint256).max, receiver);
        //------------------------------------------------------------------------------

        // get collateral & allowance
        deal(address(Deployed.wstETH), owner, 10 ether);
        vm.prank(owner);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(owner);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        //--------------------------------------------------------------

        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        // got to add some pegged tokens or collateral ratio checks don't work

        // first mint
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, "collateral ratio = 1/0");
        assertEq(IOwnable(minter).owner(), owner);
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);
        _freeMintLeveragedToken(1 ether);
        //---------------------------
        // collateral ratio is undefined for just minting leveraged tokens
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, unicode"collateral ratio = ∞");
        assertEq(IERC20(leveragedToken).balanceOf(receiver), price);

        // mint with some collateral ratio
        vm.prank(owner);
        IMinter(minter).freeMintPeggedToken(1 ether, owner);
        assertGt(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio > 1");
        assertEq(IOwnable(minter).owner(), owner);
        assertEq(IERC20(Deployed.BaoUSD).balanceOf(receiver), 0);
        _freeMintLeveragedToken(1 ether);
        //---------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), price * 2);

        // more than one mint
        _freeMintLeveragedToken(2 ether);
        //---------------------------

        // check all-of function, when some
        _freeMintLeveragedToken(type(uint256).max);
        //-------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Leveraged
    //---------------------------------------------------------------------------------------------

    function _mintLeveragedToken(uint256 collateralIn) private {
        //uint256 price = MockPriceOracle(priceOracle).latestAnswer();

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(sender);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(Deployed.wstETH), sender, senderCollateralDecrease);
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        int256 mintLeveragedFee = (int256(senderCollateralDecrease) *
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) / 1 ether;
        uint256 receiverLeveragedIncrease = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderCollateralDecrease) - mintLeveragedFee)
        );

        uint256 feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        // removed to save stack space uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(sender, receiver, senderCollateralDecrease, receiverLeveragedIncrease);
        vm.prank(sender);
        uint256 minted = IMinter(minter).mintLeveragedToken(senderCollateralDecrease, receiver, 0);
        //   ------------------------------------------------------------------
        // TODO: removed to save stack space assertEq(minterPeggedBalanceBefore, IMinter(minter).peggedTokenBalance(), "pegged tokens remain the same");
        assertEq(minted, receiverLeveragedIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            uint256(int256(feeReceiverCollateralBefore) + mintLeveragedFee),
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
            IERC20(leveragedToken).balanceOf(receiver),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "receiver received leveraged"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(minterCollateralBalanceBefore + senderCollateralDecrease) - mintLeveragedFee),
            "minter is tracking the new collateral"
        );
        //assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBalanceBefore, "no new pegged");
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            minterLeveragedBalanceBefore + receiverLeveragedIncrease,
            "minter is tracking new leveraged tokens"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderCollateralDecrease) - mintLeveragedFee),
            "wstETH has minter owning it"
        );
        assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_mintLeveragedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get collateral
        deal(address(Deployed.wstETH), sender, 10 ether);

        // mint no allowance
        assertEq(IERC20(Deployed.wstETH).allowance(sender, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_mintLeveragedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
    }

    function test_mintLeveraged() public {
        setUp_collateral(10 ether, 0);
        MockPriceOracle(priceOracle).setLatestAnswer(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintLeveragedToken(1 ether);
        //--------------------------

        // second mint
        _mintLeveragedToken(2 ether);
        //--------------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(Deployed.wstETH), sender, collateral * 10);

        int256 mintLeveragedFee = (int256(collateral) * ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) /
            1 ether;
        uint256 expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(collateral) - mintLeveragedFee)
        );
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut);
        //--------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut + 1,
                expectedLeveragedTokenOut
            )
        );
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut + 1);
        //------------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore);

        // mint from all of balance
        mintLeveragedFee =
            (int256(senderCollateralBefore) * ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) /
            1 ether;
        expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderCollateralBefore) - mintLeveragedFee)
        );
        _mintLeveragedToken(type(uint256).max);
        //------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0, "transferred it all");
    }

    // checks that two free mint leverage tokens does not produce more leverage tokens than one mint
    function test_leveragedToCollateralCalculation() public {
        setUp_collateral(1 ether, 1 ether);
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio, "CR=2");

        uint256 collateral = 100 ether;

        deal(address(Deployed.wstETH), owner, collateral);
        vm.prank(owner);
        IERC20(Deployed.wstETH).approve(minter, collateral);
        // for a range of collateral ratios,

        // mint one
        uint256 oneMint = IMinter(minter).leverageTokensForCollateral(collateral);

        // mint multiple
        uint multiples = 100;
        uint256 collateral2 = collateral / multiples;
        uint256 prevCollateralRatio = startCollateralRatio;
        uint256 sum = 0;
        for (uint i = 0; i < multiples; i++) {
            uint256 oneOfMint = IMinter(minter).leverageTokensForCollateral(collateral2);
            assertEq(oneOfMint, oneMint / multiples, "first mint not exactly linear");
            sum += oneOfMint;

            vm.prank(owner);
            uint256 oneOfMintActual = IMinter(minter).freeMintLeveragedToken(collateral2, receiver);
            assertEq(oneOfMintActual, oneOfMint, "calc meets reality");
            uint256 collateralRatio = IMinter(minter).collateralRatio();
            assertGt(collateralRatio, prevCollateralRatio, "CR not increasing");
            prevCollateralRatio = collateralRatio;
        }
        assertEq(sum, oneMint, "one is the sum of it's constituents");
    }
}
