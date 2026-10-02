// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {console2} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract TestMinterMintPegged is TestMinterMint {
    using SafeERC20 for IERC20;

    //---------------------------------------------------------------------------------------------
    // Free Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _freeMintPeggedToken(uint256 collateralIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(zeroFee);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverBaoUSDIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(Deployed.wstETH).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverBaoUSDBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 peggedSupplyBefore = IERC20(peggedToken).totalSupply();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before freeMintPegged"
        );

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(zeroFee, receiver, ownerCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(zeroFee);
        uint256 minted = IMinter(minter).freeMintPeggedToken(collateralIn, receiver);
        //               ------------------------------------------------------------------------
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance after freeMintPegged"
        );
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(zeroFee),
            ownerCollateralBefore - ownerCollateralDecrease,
            "collateral not paid"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore,
            "collateral not mis-transferred to receiver"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(receiver),
            receiverBaoUSDBefore + receiverBaoUSDIncrease,
            "receiver baoUSD balance after"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(Deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore + receiverBaoUSDIncrease);
        assertEq(IERC20(peggedToken).totalSupply(), peggedSupplyBefore + receiverBaoUSDIncrease);
    }

    function test_freeMintPegged() public {
        // mint noaccess
        assertFalse(IHarborRoles(minter).hasAllRoles(receiver, zeroFeeRole));
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        vm.prank(receiver);
        IMinter(minter).freeMintPeggedToken(1 ether, receiver);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(0, receiver);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, receiver);
        //-------------------------------------------------------------

        // // all input, when none
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        // vm.prank(zeroFee);
        // IMinter(minter).freeMintPeggedToken(type(uint256).max, receiver);
        // //-----------------------------------------------------------------------

        // get collateral & allowance
        deal(address(Deployed.wstETH), zeroFee, 10 ether);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(0, receiver);
        //-----------------------------------------------------------

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // first mint
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether,
            "collateral ratio = 0/0, which we define as 1, in this case"
        );
        assertEq(IHarborOwnable(minter).owner(), owner());
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        _freeMintPeggedToken(1 ether);
        //---------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 100%");
        assertEq(IERC20(peggedToken).balanceOf(receiver), price);

        // more than one mint
        _freeMintPeggedToken(2 ether);
        //---------------------------

        // // check all-of function, when some
        // _freeMintPeggedToken(type(uint256).max);
        // //-------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Pegged
    //---------------------------------------------------------------------------------------------

    struct Balances {
        uint256 feeReceiverCollateralBefore;
        uint256 senderCollateralBefore;
        uint256 receiverCollateralBefore;
        uint256 receiverPeggedBefore;
        uint256 minterCollateralBalanceBefore;
        uint256 minterPeggedBalanceBefore;
        uint256 minterLeveragedBalanceBefore;
        uint256 minterCollateralBefore;
    }
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

        Balances memory b;
        b.feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        b.senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        b.receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        b.receiverPeggedBefore = IERC20(peggedToken).balanceOf(receiver);
        b.minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        b.minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        b.minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        b.minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(sender, receiver, senderCollateralDecrease, receiverBaoUSDIncrease);
        vm.prank(sender);
        uint256 minted = IMinter(minter).mintPeggedToken(collateralIn, receiver, 0);
        //               ----------------------------------------------------------
        assertEq(
            b.minterLeveragedBalanceBefore,
            IMinter(minter).leveragedTokenBalance(),
            "leveraged tokens remain the same"
        );
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            uint256(int256(b.feeReceiverCollateralBefore) + mintPeggedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(sender),
            b.senderCollateralBefore - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            b.receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(receiver),
            b.receiverPeggedBefore + receiverBaoUSDIncrease,
            "receiver received baoUSD"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(b.minterCollateralBalanceBefore + senderCollateralDecrease) - mintPeggedFee),
            "minter is tracking the new collateral"
        );
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            b.minterPeggedBalanceBefore + receiverBaoUSDIncrease,
            "minter is tracking the new pegged"
        );
        assertEq(IMinter(minter).leveragedTokenBalance(), b.minterLeveragedBalanceBefore, "no new leveraged tokens");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            uint256(int256(b.minterCollateralBefore + senderCollateralDecrease) - mintPeggedFee),
            "wstETH has minter owning it"
        );
    }

    struct DryRunResults {
        int256 incentiveRatio;
        uint256 wrappedFee;
        uint256 wrappedCollateralUsed;
        uint256 peggedMinted;
        uint256 price;
        uint256 rate;
    }

    function _testMintPeggedDryRun(uint256 collateralIn, DryRunResults memory expected, address sender_) internal {
        DryRunResults memory r;
        vm.prank(sender_);
        (r.incentiveRatio, r.wrappedFee, r.wrappedCollateralUsed, r.peggedMinted, r.price, r.rate) = IMinter(minter)
            .mintPeggedTokenDryRun(collateralIn);
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedCollateralUsed, expected.wrappedCollateralUsed, "wrappedCollateralUsed");
        assertEq(r.peggedMinted, expected.peggedMinted, "peggedMinted");
        assertEq(r.price, expected.price, "price");
        assertEq(r.rate, expected.rate, "rate");
    }

    function zeros() internal view returns (DryRunResults memory) {
        (uint256 price_, , uint256 rate_, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return
            DryRunResults({
                incentiveRatio: 0,
                wrappedFee: 0,
                wrappedCollateralUsed: 0,
                peggedMinted: 0,
                price: price_,
                rate: rate_
            });
    }

    // Golden hand-computed case (no formula re-derivation): oracle price 2000, rate 1.0, mint fee 0.5%,
    // collateral ratio > 1 so the pegged price is exactly 1.0. Minting 1 collateral:
    //   fee          = 0.5% * 1        = 0.005 collateral
    //   net collateral = 1 - 0.005     = 0.995
    //   minted       = 0.995 * 2000    = 1990 pegged   (exact — every term divides evenly)
    function test_mintPegged_goldenExact() public {
        setUp_collateral(0, 1 ether); // collateral ratio ~2 (> 1): pegged price is exactly 1e18

        deal(address(Deployed.wstETH), sender, 1 ether);
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        uint256 feeBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        vm.stopPrank();

        assertEq(minted, 1990 ether, "minted = (1 - 0.005) * 2000");
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver) - feeBefore, 0.005 ether, "fee = 0.5% of 1 collateral");
        assertEq(IERC20(peggedToken).balanceOf(receiver), 1990 ether, "receiver got exactly the minted pegged");
    }

    function test_ROUNDPROBE() public {
        setUp_collateral(0, 1 ether); // CR > 1, pegged price 1.0, mint fee 0.5%
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 fr = uint256(ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)); // 0.5%
        for (uint256 k = 0; k < 6; k++) {
            uint256 c = 1 ether + 100 * k; // vary the sub-wei fee remainder
            (, uint256 wf, , uint256 pm, , ) = IMinter(minter).mintPeggedTokenDryRun(c);
            // exact rational fee (in wrapped) = c*fr/1e18 ; exact minted = (c - feeExact)*price*rate/(1e18*1e18)
            uint256 feeFloor = (c * fr) / 1 ether;
            uint256 feeRem = (c * fr) % 1 ether; // 0..1e18-1 ; >0 means non-integer
            uint256 mintedExactNum = (c - wf) * price * rate; // /1e36 exact
            console2.log(
                string.concat(
                    "PROBE c=",
                    LibString.toString(c),
                    " fee=",
                    LibString.toString(wf),
                    " feeFloor=",
                    LibString.toString(feeFloor),
                    " rem/1e15=",
                    LibString.toString(feeRem / 1e15)
                )
            );
            console2.log(
                string.concat(
                    "PROBE   minted=",
                    LibString.toString(pm),
                    " mintedNum%1e36=",
                    LibString.toString(mintedExactNum % 1e36)
                )
            );
        }
    }

    // Rounding direction (intentional, pinned so a future flip is caught). The Minter rounds DOWN throughout:
    // the fee to the receiver floors, and the pegged the user receives floors. Both are verified against the
    // contract with deliberately non-integer inputs, not assumed.
    //
    // Fee floors: minting 1e18 + 100 collateral at 0.5% gives an exact fee of 5e15 + 0.5 wei; the contract
    // pays the feeReceiver 5e15 (floored), never 5e15 + 1.
    function test_mintPegged_feeRoundsDown() public {
        setUp_collateral(0, 1 ether); // CR > 1, pegged price 1.0, mint fee 0.5%
        uint256 c = 1 ether + 100; // (c * 0.005) = 5e15 + 0.5 wei — a half-wei fee remainder
        deal(address(Deployed.wstETH), sender, c);
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        uint256 feeBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        IMinter(minter).mintPeggedToken(c, receiver, 0);
        vm.stopPrank();
        // The fee floors to 5e15; the ceil a rounding-flip bug would produce (5e15 + 1) must be rejected — so the
        // exact assertion is proven to discriminate the flip on every run (a continuous mutation-check).
        assertDiscriminates(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - feeBefore,
            5e15,
            0,
            5e15 + 1,
            "fee floors to 5e15"
        );
    }

    // Minted floors: an odd oracle price makes (net collateral) * price / 1e18 = 1990e18 + 0.995 (rational);
    // the user receives 1990e18 (floored), never 1990e18 + 1.
    function test_mintPegged_userAmountRoundsDown() public {
        setUp_collateral(0, 1 ether); // CR > 1, pegged price 1.0, mint fee 0.5%
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether + 1); // odd price forces a fractional quotient
        deal(address(Deployed.wstETH), sender, 1 ether);
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // Minted floors to 1990; the ceil (1990 + 1) a rounding-flip would produce must be rejected — the
        // discrimination that used to need a manual src mutation now runs on every CI.
        assertDiscriminates(minted, 1990 ether, 0, 1990 ether + 1, "minted floors to 1990");
    }

    function test_mintPeggedBasic() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = 1 ether; // its a disallow
        _testMintPeggedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(0, receiver, 0);
        // 1 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = 1 ether; // its a disallow
        _testMintPeggedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver, 0);
        // 2 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // some input, when infinite collateral ratio
        expected = zeros();
        expected.incentiveRatio = 1 ether; // its a disallow
        _testMintPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        // 3 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // some input, when in the disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        expected = zeros();
        expected.incentiveRatio = 1 ether; // its a disallow
        _testMintPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        // 4 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(0, 1 ether); // make collateral ratio ~ 2
        expected = zeros();
        expected.incentiveRatio = 0.005 ether; // it's allowed
        expected.wrappedFee = 0.005 ether; // and an actual transfer
        expected.wrappedCollateralUsed = 1 ether;
        expected.peggedMinted = ((1 ether - expected.wrappedFee) * price) / 1 ether;
        _testMintPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        // 5 ------------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = 0.005 ether; // it's allowed
        _testMintPeggedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver, 0);
        // 6 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // get collateral
        deal(address(Deployed.wstETH), sender, 10 ether);

        // mint no allowance
        assertEq(IERC20(Deployed.wstETH).allowance(sender, minter), 0);
        expected = zeros();
        expected.incentiveRatio = 0.005 ether; // it's allowed
        // although there is no allowance right now I'd expect the allowance in most UIs to set it later.
        expected.wrappedFee = 0.005 ether; // and an actual transfer
        expected.wrappedCollateralUsed = 1 ether;
        expected.peggedMinted = ((1 ether - expected.wrappedFee) * price) / 1 ether;
        _testMintPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        // 7 ----------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = 0.005 ether; // it's allowed
        _testMintPeggedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(0, receiver, 0);
        // 8 --------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);

        // non-zero input, when some
        uint256 collateralBefore = IMinter(minter).collateralTokenBalance();
        expected = zeros();
        expected.incentiveRatio = 0.005 ether; // it's allowed
        expected.wrappedFee = 0.005 ether; // and an actual transfer
        expected.wrappedCollateralUsed = 1 ether;
        expected.peggedMinted = ((1 ether - expected.wrappedFee) * price) / 1 ether;
        _testMintPeggedDryRun(1 ether, expected, sender);

        vm.prank(sender);
        uint256 peggedMinted = IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        // 9 --------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), peggedMinted, "received = returned");
        assertEq(
            IERC20(peggedToken).balanceOf(receiver),
            ((1 ether - uint256(config.mintPeggedIncentiveConfig.incentiveRatios[1])) * price) / 1 ether,
            "received 1 minus fees"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            collateralBefore + 1 ether - uint256(config.mintPeggedIncentiveConfig.incentiveRatios[1]),
            "collaterals should be 1 more minus the fee"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
    }

    function test_mintPeggedDisallow() public {
        // get collateral & allow
        deal(address(Deployed.wstETH), sender, 10 ether);
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // no minting in disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR=1.0");
        assertEq(IMinter(minter).peggedTokenBalance(), 2000 ether, "2000 pegged");
        assertEq(IMinter(minter).collateralTokenBalance(), 1 ether, "CR=1.0");
        assertEq(
            IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(minter),
            IMinter(minter).collateralTokenBalance(),
            "wrapped = underlying"
        );

        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(1 ether, receiver, 0);
        //--------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "still CR=1.0");

        // no minting into rebalance zone
        setUp_collateral(3 ether, 2 ether); // make CR = 6/4  = 1.5
        assertEq(IMinter(minter).collateralRatio(), 6 ether / 4, "CR=1.5");
        assertEq(IMinter(minter).peggedTokenBalance(), 4 * 2000 ether, "8000 pegged");
        assertEq(IMinter(minter).collateralTokenBalance(), 6 ether, "CR=1.0");
        assertEq(
            IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(minter),
            IMinter(minter).collateralTokenBalance(),
            "wrapped = underlying"
        );

        assertGt(
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            10 ether / 8, // This is where the CR should go if there were no disallow preventing it
            "test should push CR below disallow"
        );
        vm.prank(sender);
        // this mint pegged should hit the disallow boundary leaving the CR at 1.3
        IMinter(minter).mintPeggedToken(4 ether, receiver, 0); // push CR to 10/8 = 1.25
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
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintPeggedToken(1 ether);
        // 1 -----------------------

        // second mint
        _mintPeggedToken(2 ether);
        // 2 -----------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(Deployed.wstETH), sender, collateral * 3);

        int256 mintPeggedFee = (int256(collateral) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) /
            1 ether;
        uint256 expectedPeggedTokenOut = uint256((int256(collateral) - mintPeggedFee) * int256(price)) / 1 ether;
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverPeggedBefore = IERC20(peggedToken).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(collateral, receiver, expectedPeggedTokenOut);
        // 3 ------------------------------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        receiverPeggedBefore = IERC20(peggedToken).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                peggedToken,
                expectedPeggedTokenOut,
                expectedPeggedTokenOut + 1
            )
        );
        vm.prank(sender);
        IMinter(minter).mintPeggedToken(collateral, receiver, expectedPeggedTokenOut + 1);
        // 4 ----------------------------------------------------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), receiverPeggedBefore);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore);

        // mint from all of balance
        mintPeggedFee =
            (int256(senderCollateralBefore) * ultimate(config.mintPeggedIncentiveConfig.incentiveRatios)) / 1 ether;
        expectedPeggedTokenOut = uint256((int256(senderCollateralBefore) - mintPeggedFee) * int256(price)) / 1 ether;
        _mintPeggedToken(type(uint256).max);
        // 5 ------------------------------
        assertEq(IERC20(peggedToken).balanceOf(receiver), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0, "transferred it all");
    }

    //---------------------------------------------------------------------------------------------
    // Fee-capped mint
    //---------------------------------------------------------------------------------------------

    /// @dev Puts the minter at a collateral ratio where minting pegged tokens is allowed but charges a fee, and
    /// funds the sender. Returns a fee cap one wei below that fee, which no band on offer can satisfy - so the
    /// cap binds before any collateral is taken. Performs external calls, so callers must invoke it BEFORE any
    /// one-shot cheatcode.
    function _setUpUnaffordableFeeCap() private returns (uint256 maxFeeRatio) {
        setUp_collateral(1 ether, 0);
        setUp_collateral(0, 1 ether); // collateral ratio ~2, where minting pegged is allowed for a fee

        uint256 incentiveRatio = uint256(IMinter(minter).mintPeggedTokenIncentiveRatio());
        assertGt(incentiveRatio, 0, "the band must charge a fee for a cap to be able to bind");
        maxFeeRatio = incentiveRatio - 1;

        deal(wrappedCollateralToken, sender, 1 ether);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.stopPrank();
    }

    /// @notice The fee cap and `minPeggedOut` are independent promises and the capped path keeps both: when the
    /// cap binds so hard that no band is affordable, a caller that demanded a minimum is told the minimum was
    /// not met, rather than handed a silent zero it must remember to test for.
    function test_mintPegged_feeCappedStillHonoursMinPeggedOut() public {
        uint256 maxFeeRatio = _setUpUnaffordableFeeCap();
        uint256 minPeggedOut = 1;

        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(IMinter_v3.MintInsufficientAmount.selector, peggedToken, 0, minPeggedOut)
        );
        IMinter_v3(minter).mintPeggedToken(1 ether, receiver, minPeggedOut, maxFeeRatio);
        vm.stopPrank();
    }

    /// @notice With no minimum demanded, the capped path reports (0, 0) and consumes nothing instead of
    /// reverting - the graceful outcome the fee cap exists to provide.
    function test_mintPegged_feeCappedReturnsZeroWhenNoMinimumDemanded() public {
        uint256 maxFeeRatio = _setUpUnaffordableFeeCap();
        uint256 senderCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(sender);
        uint256 receiverPeggedBefore = IERC20(peggedToken).balanceOf(receiver);

        vm.startPrank(sender);
        (uint256 peggedOut, uint256 collateralUsed) = IMinter_v3(minter).mintPeggedToken(
            1 ether,
            receiver,
            0,
            maxFeeRatio
        );
        vm.stopPrank();

        assertEq(peggedOut, 0, "nothing minted when no band is affordable");
        assertEq(collateralUsed, 0, "nothing consumed when no band is affordable");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(sender),
            senderCollateralBefore,
            "sender keeps all its collateral"
        );
        assertEq(IERC20(peggedToken).balanceOf(receiver), receiverPeggedBefore, "receiver gets nothing");
    }

    /// Minting the anchor token does not move the sail token's price - the mint adds collateral and
    /// anchor claims in the same proportion, so the residual the sail is a claim on is unchanged, and
    /// a holder is not diluted by someone else's mint - while a move in the collateral price does move
    /// it, which is what a leveraged long is for.
    ///
    /// Both halves are asserted together because the first alone cannot fail loudly enough to be
    /// trusted: an equality that holds because nothing in the setup could ever move the price looks
    /// identical to one that holds because the mint is genuinely neutral. The second half is the
    /// control that tells them apart, on every run rather than once.
    ///
    /// Neutrality is claimed for the free path; a fee is the one thing that legitimately dilutes, and
    /// then only the payer.
    function test_freeMintPeggedToken_leavesLeveragedPriceUnchanged() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the sail has a price to move

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        IMinter(minter).freeMintPeggedToken(1 ether, receiver);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "minting the anchor moved the sail price"
        );

        // the control: the collateral price is the one input that may move the sail price
        (uint256 collateralPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((collateralPrice * 110) / 100);
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the sail price, or the assertion above proves nothing"
        );
    }

    /// Paying a mint fee does not move the sail price either, so a fee dilutes only the payer. The fee
    /// is taken out of the input, so the collateral entering and the anchor minted both correspond to
    /// the post-fee amount and stay in the proportion that leaves the residual untouched; the payer
    /// simply buys less anchor.
    ///
    /// The fee is asserted non-zero, because a configuration with no fee would make this the free-path
    /// test again under a name claiming otherwise.
    function test_mintPeggedToken_leavesLeveragedPriceUnchanged_whenFeePaid() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the sail has a price to move

        deal(address(Deployed.wstETH), sender, 1 ether);
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, 1 ether);
        vm.stopPrank();
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole), "the payer must not be fee-exempt");

        (, uint256 fee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(fee, 0, "a fee of zero would make this the free path under another name");

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        vm.startPrank(sender);
        IMinter(minter).mintPeggedToken(1 ether, sender, 0);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a fee-paying anchor mint diluted the sail holders"
        );

        // the control: the collateral price is the one input that may move the sail price
        (uint256 collateralPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((collateralPrice * 110) / 100);
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the sail price, or the assertion above proves nothing"
        );
    }
}

/// @notice A pegged mint never mints more than the collateral it credits to the record buys - every rounding on the
/// way from the offer to the tokens goes the protocol's way.
contract TestMinterMintPeggedCredit is TestMinterSetUp {
    address user;

    /// @dev One fee in every band, either side of the peg, so a mint walking across bounds is priced alike throughout.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// The pegged minted is never more than the credited collateral buys: its value at the price while the backing
    /// covers the pegged supply, otherwise its share of that supply - each pegged token a claim on backing / supply -
    /// across rates, offers, and collateral ratios from below the peg to far above it.
    function testFuzz_mintPegged_mintsNoMoreThanTheCreditedCollateralBuys(
        uint256 wrappedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 0.3 ether, 100 ether); // the ratio from 0.45 to 150
        wrappedIn = bound(wrappedIn, 1e9, 100 ether);
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, rate);
        setUp_collateral(100 ether, 50 ether); // a ratio of 1.5 at a price of one
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 supply = IMinter(minter).peggedTokenBalance();

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 minted = IMinter(minter).mintPeggedToken(wrappedIn, user, 0);
        vm.stopPrank();

        uint256 credited = IMinter(minter).collateralTokenBalance() - backing;
        uint256 buys = backing * price >= supply * 1 ether
            ? Math.mulDiv(credited, price, 1 ether)
            : Math.mulDiv(credited, supply, backing);
        assertLe(minted, buys, "no more pegged than the credited collateral buys");
    }
}

/// @notice A pegged mint charges the trader the collateral its slices use, rounded up once from their exact sum, and
/// mints the pegged those slices buy, rounded down once - never more than the collateral credited buys; the backing
/// absorbs the remainder of the fee's rounding.
contract TestMinterMintPeggedRoundedOnce is TestMinterSetUp {
    address user;

    /// @dev Minting pegged is disallowed below a ratio of 1.3, charges 1.2% up to 1.5 and 0.7% above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(130, 150), ia(disallow, 120, 70)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.8 a mint pays 0.7% down to 1.5 and 1.2% down to 1.3, where the disallow stops it with the
    /// offer part used. Each slice is cut where the ratio reaches its band's lower bound and its fee is exact on the
    /// collateral it takes. The trader pays the slices' sum rounded up once and is minted the pegged their net collateral
    /// buys, priced once and rounded down once, capped at what the collateral credited buys.
    function testFuzz_mintPegged_acrossAFeeToADisallow_chargesAndMintsTheExactSumsRoundedOnce(
        uint256 extra,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8

        uint256 usedE36; // the collateral the slices use, their fees included
        uint256 feeE54;
        {
            uint256 collateralE36 = IMinter(minter).collateralTokenBalance() * 1 ether;
            uint256 peggedHeldE36 = IMinter(minter).peggedTokenBalance() * 1 ether;
            for (uint256 band = 2; band > 0; band--) {
                uint256 lowerBound = config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[band - 1];
                uint256 feeRatio = uint256(config.mintPeggedIncentiveConfig.incentiveRatios[band]);
                // the collateral, its fee included, whose mint brings the ratio down to the band's lower bound
                uint256 sliceE36 = Math.mulDiv(
                    collateralE36 * price - lowerBound * peggedHeldE36,
                    1e36,
                    price * (lowerBound - 1 ether) * (1 ether - feeRatio)
                );
                usedE36 += sliceE36;
                feeE54 += sliceE36 * feeRatio;
                // the state the next band is cut from, at 1e36: the net collateral held and, a pegged unit being worth
                // one above the peg, the pegged it buys
                uint256 netE54 = sliceE36 * 1 ether - sliceE36 * feeRatio;
                collateralE36 += netE54 / 1 ether;
                peggedHeldE36 += Math.mulDiv(netE54, price, 1e36);
            }
        }
        uint256 payment = Math.ceilDiv(usedE36, rate);
        uint256 credited = Math.mulDiv(payment - feeE54 / (rate * 1 ether), rate, 1 ether);
        // the walk's pegged: the slices' net collateral, priced once
        uint256 expectedMinted = Math.min(
            Math.mulDiv(usedE36 * 1 ether - feeE54, price, 1e54),
            Math.mulDiv(credited, price, 1 ether)
        );
        uint256 wrappedIn = payment + bound(extra, 1e9, 50 ether); // more than the slices use

        deal(wrappedCollateralToken, user, wrappedIn);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 minted = IMinter(minter).mintPeggedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertEq(wrappedIn - IERC20(wrappedCollateralToken).balanceOf(user), payment, "the payment, rounded up once");
        assertEq(minted, expectedMinted, "the pegged, rounded down once, capped at what the credited collateral buys");
    }
}

/// @notice A pegged mint charges each band's fee exactly on the collateral it takes there, so a mint whose exact outcome
/// is a whole number of wei is minted exactly that, whatever bounds it crosses.
contract TestMinterMintPeggedAcrossEqualFees is TestMinterSetUp {
    address user;

    /// @dev Minting pegged is disallowed below the peg and charges 0.5% either side of a bound at 1.5.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100, 150), ia(disallow, 50, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.8 an offer of 100 crosses 1.5 into the second band. At a wrapped-to-underlying rate of one and
    /// a price of 2000 the offer less 0.5%, at the price, is a whole number of pegged wei, and it is minted exactly.
    function test_mintPegged_acrossABoundBetweenEqualFees_mintsExactlyTheOfferLessTheFee() public {
        uint256 price = 2000 ether;
        uint256 rate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        user = makeAddr("user");
        uint256 wrappedIn = 100 ether;
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 feeRatio = uint256(config.mintPeggedIncentiveConfig.incentiveRatios[1]);

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 minted = IMinter(minter).mintPeggedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertLt(
            IMinter(minter).collateralRatio(),
            config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[1],
            "the mint crossed the bound"
        );
        assertEq(
            minted,
            (((wrappedIn * rate) / 1 ether) * (1 ether - feeRatio) * price) / 1e36,
            "the offer less the fee, at the price"
        );
    }
}

/// @notice A pegged mint that reaches a band where minting is disallowed fills only to that band's bound: it takes the
/// collateral that brings the ratio down to the bound, and the caller keeps the rest of the offer.
contract TestMinterMintPeggedIntoADisallow is TestMinterSetUp {
    address user;

    /// @dev Minting pegged is disallowed below a ratio of 1.3 and charges 0.5% above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(130), ia(disallow, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.8 an offer of 200 would take the ratio far below 1.3. The mint takes only what brings it to
    /// 1.3 and the caller keeps the rest; the event and the dry run report the partial fill, and the ratio ends on the
    /// bound.
    function test_mintPegged_intoTheDisallowBand_fillsToTheBoundaryAndLeavesTheRest() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        user = makeAddr("user");
        uint256 offer = 200 ether;
        deal(wrappedCollateralToken, user, offer);
        (, , uint256 dryRunUsed, uint256 dryRunMinted, , ) = IMinter(minter).mintPeggedTokenDryRun(offer);
        assertLt(dryRunUsed, offer, "precondition: the offer is more than the band can take");

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, offer);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.MintPeggedToken(user, user, dryRunUsed, dryRunMinted);
        uint256 minted = IMinter(minter).mintPeggedToken(offer, user, 0);
        vm.stopPrank();

        assertEq(minted, dryRunMinted, "minted what the dry run reports");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(user), offer - dryRunUsed, "the caller keeps the rest");
        assertEq(
            IMinter(minter).collateralRatio(),
            config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[0],
            "the ratio ends on the bound"
        );
    }
}

/// @notice A pegged mint walks down through the bands it crosses, each slice charged at its own band's rate; the record
/// it credits is valued at the low edge of the rate band; and its dry run reads the sentinel as the mint does.
contract TestMinterMintPeggedAcrossBands is TestMinterSetUp {
    address user;

    /// @dev Minting pegged charges 0.3% above a ratio of 1.6, 0.7% from 1.4 to 1.6, and 1.2% from the peg to 1.4.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100, 140, 160), ia(disallow, 120, 70, 30)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.8 a mint to about 1.5 crosses one bound and a mint to about 1.2 crosses two. Each pays the sum
    /// of its slices' fees - every slice cut where the ratio reaches its band's lower bound and charged its band's rate
    /// exactly - rounded down once.
    function test_mintPegged_acrossOneAndTwoBandBounds_chargesEachSliceAtItsBandsRate(
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8, in the top band
        user = makeAddr("user");
        uint256[] memory bounds = config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds;

        uint256 snapshot = vm.snapshotState();
        uint256 wrappedIn = _wrappedToReach(1.5 ether);
        _mintAndCheckFee(wrappedIn, _expectedFee(wrappedIn), bounds[1], bounds[2]); // one bound crossed
        vm.revertToState(snapshot);
        wrappedIn = _wrappedToReach(1.2 ether);
        _mintAndCheckFee(wrappedIn, _expectedFee(wrappedIn), bounds[0], bounds[1]); // two bounds crossed
    }

    /// @dev The wrapped collateral whose mint takes the ratio to about `targetRatio`, by the ratio's definition and
    ///      leaving the fee aside: (C + x) p / (P + x p) = T, so x = (C p - T P) / (p (T - 1)).
    function _wrappedToReach(uint256 targetRatio) private view returns (uint256) {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return
            Math.mulDiv(
                IMinter(minter).collateralTokenBalance() * 1 ether * price -
                    targetRatio * IMinter(minter).peggedTokenBalance() * 1 ether,
                1 ether,
                price * (targetRatio - 1 ether) * rate
            );
    }

    /// @dev The schedule's fee on a mint of `wrappedIn`: walking down from the top band, each band takes the collateral
    ///      that brings the ratio to its lower bound and the last band entered takes the rest, each slice's fee exact on
    ///      the collateral it takes; the fee paid is their sum rounded down. Above the peg a pegged unit is worth one, so
    ///      each slice adds its net collateral's value to the pegged held.
    function _expectedFee(uint256 wrappedIn) private view returns (uint256) {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MintWalk memory w = MintWalk(
            wrappedIn * rate,
            IMinter(minter).collateralTokenBalance() * 1 ether,
            IMinter(minter).peggedTokenBalance() * 1 ether,
            0
        );
        for (uint256 band = config.mintPeggedIncentiveConfig.incentiveRatios.length - 1; w.leftE36 > 0; band--) {
            uint256 feeRatio = uint256(config.mintPeggedIncentiveConfig.incentiveRatios[band]);
            uint256 lowerBound = config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[band - 1];
            uint256 sliceE36 = w.leftE36;
            if (lowerBound > 1 ether) {
                sliceE36 = Math.min(
                    sliceE36,
                    Math.mulDiv(
                        w.heldE36 * price - lowerBound * w.peggedHeldE36,
                        1e36,
                        price * (lowerBound - 1 ether) * (1 ether - feeRatio)
                    )
                );
            }
            w.feeE54 += sliceE36 * feeRatio;
            w.leftE36 -= sliceE36;
            w.heldE36 += (sliceE36 * (1 ether - feeRatio)) / 1 ether;
            w.peggedHeldE36 += Math.mulDiv(sliceE36 * (1 ether - feeRatio), price, 1e36);
        }
        return w.feeE54 / (rate * 1 ether);
    }

    /// @dev What the fee walk carries from band to band, at 1e36: the collateral still to place, the collateral and the
    ///      pegged held, and the fee charged so far, exact.
    struct MintWalk {
        uint256 leftE36;
        uint256 heldE36;
        uint256 peggedHeldE36;
        uint256 feeE54;
    }

    /// @dev Mints `wrappedIn`, and checks the mint ended between `lowerRatio` and `upperRatio` - the band the scenario
    ///      aims for - with the fee receiver paid exactly `expectedFee`.
    function _mintAndCheckFee(
        uint256 wrappedIn,
        uint256 expectedFee,
        uint256 lowerRatio,
        uint256 upperRatio
    ) private {
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintPeggedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), lowerRatio, "the mint ends in the band aimed for");
        assertLt(IMinter(minter).collateralRatio(), upperRatio, "the mint ends in the band aimed for");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            expectedFee,
            "each slice charged at its band's rate"
        );
    }

    /// Under a band of rates the record is credited at its low edge: the collateral taken less the fee, converted at the
    /// minimum rate - the maximum would credit more than the wrapped held may be worth.
    function test_mintPegged_creditsTheRecordAtTheMinRate() public {
        uint256 minRate = 1 ether;
        uint256 maxRate = 1.02 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 2000 ether, minRate, maxRate);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        user = makeAddr("user");
        uint256 wrappedIn = 10 ether;
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintPeggedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertEq(IERC20(wrappedCollateralToken).balanceOf(user), 0, "precondition: the whole offer is taken");
        uint256 kept = wrappedIn - (IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore);
        assertDiscriminates(
            IMinter(minter).collateralTokenBalance() - recordBefore,
            (kept * minRate) / 1 ether,
            0,
            (kept * maxRate) / 1 ether,
            "the record gains what stays behind at the minimum rate"
        );
    }

    /// The dry run reads the sentinel as the caller's whole balance, as the mint does: asked to price the maximum it
    /// reports exactly what an offer of the caller's balance would.
    function test_mintPeggedDryRun_withTheMaxSentinel_pricesTheCallersWholeBalance() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        user = makeAddr("user");
        uint256 balance = 7 ether;
        deal(wrappedCollateralToken, user, balance);
        (int256 ratio, uint256 fee, uint256 used, uint256 minted, , ) = IMinter(minter).mintPeggedTokenDryRun(balance);
        assertGt(minted, 0, "precondition: the balance buys pegged");

        vm.startPrank(user);
        (int256 sentinelRatio, uint256 sentinelFee, uint256 sentinelUsed, uint256 sentinelMinted, , ) = IMinter(minter)
            .mintPeggedTokenDryRun(type(uint256).max);
        vm.stopPrank();

        assertEq(sentinelUsed, used, "the caller's whole balance is priced");
        assertEq(sentinelMinted, minted, "minting what the balance buys");
        assertEq(sentinelFee, fee, "for the balance's fee");
        assertEq(sentinelRatio, ratio, "at the balance's ratio");
    }
}

/// @notice A capped pegged mint holds its fee, as a ratio of the collateral it uses, within the cap: past a bound into a
/// dearer band it takes only as much of that band as the cheaper band's headroom pays for.
contract TestMinterMintPeggedCapped is TestMinterSetUp {
    address user;

    /// @dev The cap the mints here are given: between the two bands' rates.
    uint256 constant FEE_CAP = 0.01 ether;

    /// @dev Minting pegged charges 0.5% above a ratio of 1.5 and 2% from the peg to 1.5.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100, 150), ia(disallow, 200, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        user = makeAddr("user");
        deal(wrappedCollateralToken, user, 400 ether);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// The fee, read from what the fee receiver is paid, is never more than the cap on the collateral used, and within a
    /// wei of it - where the cap measured against the offer would charge far more.
    function test_cappedMint_acrossBands_keepsTheFeeWithinTheCapOfTheCollateralUsed() public {
        uint256 offer = 200 ether;
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        vm.startPrank(user);
        (, uint256 used) = IMinter_v3(minter).mintPeggedToken(offer, user, 0, FEE_CAP);
        vm.stopPrank();
        uint256 fee = IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore;

        assertLt(used, offer, "precondition: the cap stops the mint short of the offer");
        assertLe(fee, (FEE_CAP * used) / 1 ether, "never more than the cap on the collateral used");
        // Within a wei below it: the walk stops the dearer band's slice where the exact fee meets the cap, short of it by
        // under a 1e-36 unit of collateral at the dearer rate; the payment rounds the collateral up to the wei, which
        // lifts the cap's figure by under a hundredth of a wei, and the fee rounds down, by under a wei.
        assertDiscriminates(
            fee,
            (FEE_CAP * used) / 1 ether,
            1,
            (FEE_CAP * offer) / 1 ether,
            "within a wei of the cap on the collateral used"
        );
    }

    /// Two offers, both past what the cap allows, use and mint the same: the cap is a ceiling on the average rate paid,
    /// so a larger offer buys no budget to spend on more of the dearer band.
    function test_cappedMint_aLargerOfferBuysNoMoreOfTheDearerBand() public {
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(user);
        (uint256 minted, uint256 used) = IMinter_v3(minter).mintPeggedToken(100 ether, user, 0, FEE_CAP);
        vm.stopPrank();
        vm.revertToState(snapshot);
        vm.startPrank(user);
        (uint256 largerMinted, uint256 largerUsed) = IMinter_v3(minter).mintPeggedToken(200 ether, user, 0, FEE_CAP);
        vm.stopPrank();

        assertLt(used, 100 ether, "precondition: the smaller offer is already past what the cap allows");
        assertEq(largerUsed, used, "the larger offer uses no more");
        assertEq(largerMinted, minted, "and mints no more");
    }

    /// The fee a capped mint charges is paid to the fee receiver, to the wei, and the minter keeps the rest of what it
    /// takes.
    function test_cappedMint_paysItsFeeToTheFeeReceiver() public {
        (, uint256 dryRunFee, , , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(200 ether, FEE_CAP);
        assertGt(dryRunFee, 0, "precondition: the mint charges a fee");
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        uint256 minterBefore = IERC20(wrappedCollateralToken).balanceOf(minter);

        vm.startPrank(user);
        (, uint256 used) = IMinter_v3(minter).mintPeggedToken(200 ether, user, 0, FEE_CAP);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            dryRunFee,
            "the fee is paid to the fee receiver"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - minterBefore,
            used - dryRunFee,
            "the minter keeps the rest"
        );
    }

    /// Where the pegged price is too small to report - the backing worth half the floor's share of the pegged supply - a
    /// capped mint is refused by name, as the plain mint is, rather than priced at a price no consumer can see.
    function test_cappedMint_belowTheReportablePeggedPrice_isRefused() public {
        uint256 price = Math.mulDiv(
            MinterValuationLib.MIN_REPORTABLE_PEGGED_PRICE_E36,
            IMinter(minter).peggedTokenBalance(),
            2 * IMinter(minter).collateralTokenBalance() * 1 ether
        );
        assertGt(price, 0, "precondition: the price is not zero");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1 ether);

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ZeroPeggedTokenPrice.selector));
        IMinter_v3(minter).mintPeggedToken(1 ether, user, 0, FEE_CAP);
        vm.stopPrank();
    }
}
