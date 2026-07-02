// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import "@harbor-test/Useful.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";

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
        assertFalse(IBaoRoles(minter).hasAllRoles(receiver, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
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
        assertEq(IBaoOwnable(minter).owner(), owner);
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
                    Useful.toString(c),
                    " fee=",
                    Useful.toString(wf),
                    " feeFloor=",
                    Useful.toString(feeFloor),
                    " rem/1e15=",
                    Useful.toString(feeRem / 1e15)
                )
            );
            console2.log(
                string.concat(
                    "PROBE   minted=",
                    Useful.toString(pm),
                    " mintedNum%1e36=",
                    Useful.toString(mintedExactNum % 1e36)
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
}
