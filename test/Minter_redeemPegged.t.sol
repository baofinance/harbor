// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterMint} from "test/Minter_mint.t.sol";

contract TestMinterRedeemPegged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Redeem Pegged
    //---------------------------------------------------------------------------------------------

    function _freeRedeemPeggedToken(uint256 peggedIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            ownerPeggedDecrease = IERC20(peggedToken).balanceOf(zeroFee);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverCollateralIncrease = (ownerPeggedDecrease * 1 ether) / price;
        uint256 ownerPeggedBefore = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before freeRedeemPegged"
        );

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, ownerPeggedDecrease, receiverCollateralIncrease, 0);
        vm.prank(zeroFee);
        (uint256 returned, ) = IMinter(minter).freeRedeemPeggedToken(peggedIn, 0, receiver);
        //                 ----------------------------------------------------------------------
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance after freeRedeemPegged"
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

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), ownerPeggedBefore - ownerPeggedDecrease, "pegged not burned");

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeRedeemPegged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IBaoRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.InsufficientRedeemableTokens.selector, peggedToken, 0, price));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        // 3 ----------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(peggedToken).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(peggedToken).balanceOf(zeroFee);

        uint256 mintedBaoUSD = 10 * price;

        // deal(address(peggedToken), owner, mintedBaoUSD);
        _mintPegged(zeroFee, mintedBaoUSD);

        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(peggedToken).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(peggedToken).balanceOf(zeroFee));
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(zeroFee);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        // zero input, when some
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        // 4 -----------------------------------------------------------

        assertEq(IBaoOwnable(minter).owner(), owner);

        // check that we can't redeem more than minter has minted, i.e 0
        vm.expectRevert(abi.encodeWithSelector(IMinter.InsufficientRedeemableTokens.selector, peggedToken, 0, price));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        // 5 ----------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD + price);
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance"
        );

        // check that we can't redeem more than minter has minted
        // TODO: check this for non-free redeems
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, price, 1 ether, 0);
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        // 6 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 1 ether);

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before mint pegged"
        );
        // first normal mint
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(6 ether, zeroFee);

        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 1");
        _freeRedeemPeggedToken(price);
        // 7 ------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio still 1"); // there are no leveraged tokens in this test

        // more than one mint
        _freeRedeemPeggedToken(2 * price);
        // 8 ----------------------------

        // // check all-of function, when some
        // _freeRedeemPeggedToken(type(uint256).max);
        // // 10 -----------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Free Swap Pegged
    //---------------------------------------------------------------------------------------------

    function _freeSwapPeggedForLeveraged(uint256 peggedIn) private {
        uint256 ownerPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            ownerPeggedDecrease = IERC20(peggedToken).balanceOf(zeroFee);
        } else {
            ownerPeggedDecrease = peggedIn;
        }
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        if (ownerPeggedDecrease > 0 && ownerPeggedDecrease > minterPeggedBefore)
            ownerPeggedDecrease = minterPeggedBefore;

        uint256 receiverLeveragedIncrease = ownerPeggedDecrease;
        uint256 ownerPeggedBefore = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, true, false, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, ownerPeggedDecrease, 0, receiverLeveragedIncrease);
        vm.prank(zeroFee);
        (, uint256 returned) = IMinter(minter).freeRedeemPeggedToken(0, peggedIn, receiver);
        //                     ------------------------------------------------------------
        assertApproxEqAbs(returned, receiverLeveragedIncrease, 1e5, "unexpected amount of free collateral returned");
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            receiverCollateralBefore + returned,
            "leveraged not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), ownerPeggedBefore - ownerPeggedDecrease, "pegged not burned");

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    function test_freeSwapPegged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IBaoRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        // 1 ----------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        // 2 ----------------------------------------------------------

        // some input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.InsufficientRedeemableTokens.selector, peggedToken, 0, price));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        // 3 ----------------------------------------------------------------

        // // all input, when none
        // vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ZeroInputBalance.selector, peggedToken));
        // vm.prank(zeroFee);
        // IMinter(minter).freeRedeemPeggedToken(0, type(uint256).max, receiver);
        // // 4 --------------------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(peggedToken).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(peggedToken).balanceOf(zeroFee);

        uint256 mintedBaoUSD = 10 * price;
        // deal(address(peggedToken), zeroFee, mintedBaoUSD);
        _mintPegged(zeroFee, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(peggedToken).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(peggedToken).balanceOf(zeroFee));
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.prank(zeroFee);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        // zero input, when some
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        // 4 -----------------------------------------------------------

        assertEq(IBaoOwnable(minter).owner(), owner);

        // check that we can't swap more than minter has minted, i.e 0
        vm.expectRevert(abi.encodeWithSelector(IMinter.InsufficientRedeemableTokens.selector, peggedToken, 0, price));
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        // 5 ----------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD + price);

        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, price, 0, price);
        vm.prank(zeroFee);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        // 6 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), price);

        // first normal swap
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(6 ether, zeroFee);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++
        uint256 beforeCR = IMinter(minter).collateralRatio();
        _freeSwapPeggedForLeveraged(price);
        // 7 -----------------------------
        assertGt(IMinter(minter).collateralRatio(), beforeCR, "collateral ratio should be greater");

        // more than one swap
        _freeSwapPeggedForLeveraged(2 * price);
        // 8 ----------------------------

        // // check all-of function, when some
        // _freeSwapPeggedForLeveraged(type(uint256).max);
        // // 10 -----------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Pegged
    //---------------------------------------------------------------------------------------------

    function _redeemPeggedToken(uint256 peggedIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 senderPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            senderPeggedDecrease = IERC20(peggedToken).balanceOf(sender);
        } else {
            senderPeggedDecrease = peggedIn;
        }

        deal(address(peggedToken), sender, senderPeggedDecrease);
        vm.prank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        uint256 feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 totalPeggedBefore = IERC20(peggedToken).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);
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
        emit IMinter.RedeemPeggedToken(sender, receiver, senderPeggedDecrease, receiverCollateralIncrease, 0);
        vm.prank(sender);
        uint256 returned = IMinter(minter).redeemPeggedToken(senderPeggedDecrease, receiver, 0);
        //   ---------------------------------------------------------------------------------------
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemPeggedFee,
            "minter is tracking the underlying collateral"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            feeReceiverCollateralBefore + redeemPeggedFee,
            "fee transferred"
        );
        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore - senderPeggedDecrease, "token sent");
        assertEq(IERC20(peggedToken).totalSupply(), totalPeggedBefore - senderPeggedDecrease, "token burned");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral returned"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemPeggedFee,
            "minter is tracking the wrapped collateral"
        );
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            minterPeggedBalanceBefore - senderPeggedDecrease,
            "minter is tracking the pegged tokens"
        );
        // TODO: track the reserve pool too
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            minterCollateralBefore - receiverCollateralIncrease - redeemPeggedFee,
            "wstETH has minter owning it"
        );
        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    struct DryRunResults {
        int256 incentiveRatio;
        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 peggedRedeemed;
        uint256 wrappedCollateralReturned;
        uint256 price;
        uint256 rate;
    }

    function _testRedeemPeggedDryRun(uint256 collateralIn, DryRunResults memory expected, address sender_) internal {
        DryRunResults memory r;
        vm.prank(sender_);
        (
            r.incentiveRatio,
            r.wrappedFee,
            r.wrappedDiscount,
            r.peggedRedeemed,
            r.wrappedCollateralReturned,
            r.price,
            r.rate
        ) = IMinter(minter).redeemPeggedTokenDryRun(collateralIn);
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedDiscount, expected.wrappedDiscount, "wrappedDiscount");
        assertEq(r.peggedRedeemed, expected.peggedRedeemed, "peggedRedeemed");
        assertEq(r.wrappedCollateralReturned, expected.wrappedCollateralReturned, "  wrappedCollateralReturned");
        assertEq(r.price, expected.price, "price");
        assertEq(r.rate, expected.rate, "rate");
    }

    function zeros() internal view returns (DryRunResults memory) {
        (uint256 price_, , uint256 rate_, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return
            DryRunResults({
                incentiveRatio: 0,
                wrappedFee: 0,
                wrappedDiscount: 0,
                peggedRedeemed: 0,
                wrappedCollateralReturned: 0,
                price: price_,
                rate: rate_
            });
    }

    function test_redeemPeggedBasic() public {
        // ic(ua(100), ia(80, 80)),

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(peggedToken).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        _testRedeemPeggedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        // 1 --------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        _testRedeemPeggedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // some input, when no leveraged Tokens
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 3 -------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // collateral ratio == 1.0
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        expected.wrappedFee = (1 ether * 0.008 ether) / price;
        expected.peggedRedeemed = 1 ether;
        expected.wrappedCollateralReturned = (1 ether * 1 ether) / price - expected.wrappedFee;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert/*"ERC20: transfer amount exceeds balance"*/ (); // BaoUSD just reverts with a subtraction underflow
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 4 -------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        // no actual balance
        expected.incentiveRatio = 0.008 ether;
        _testRedeemPeggedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // get tokens to redeem
        setUp_collateral(1 ether, 0, sender);
        assertEq(IERC20(peggedToken).balanceOf(sender), 1 * price, "sender has 1");

        // redeem no allowance
        assertEq(IERC20(peggedToken).allowance(sender, minter), 0);
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        expected.wrappedFee = (1 ether * 0.008 ether) / price;
        expected.peggedRedeemed = 1 ether;
        expected.wrappedCollateralReturned = (1 ether * 1 ether) / price - expected.wrappedFee;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.expectRevert/*"ERC20: transfer amount exceeds allowance"*/ ();
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        // 6 --------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        _testRedeemPeggedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        // 7 --------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // can't mint some because the config has it disallowed at < 1.31 and we're at 1
        // mint some then redeem it:
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is 1");
        // setUp_collateral(0, 100 ether, zeroFee); // make the collateral ratio nice
        assertEq(IERC20(peggedToken).balanceOf(sender), 1 * price, "sender still has 1");
        setUp_collateral(2 ether, 0, sender);
        assertEq(IERC20(peggedToken).balanceOf(sender), 3 * price, "sender has 3");
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is still 1");
        // get allowance
        vm.prank(sender);
        IERC20(peggedToken).approve(minter, 3 * price);

        assertEq(IMinter(minter).collateralTokenBalance(), 4 ether, "collaterals should be 3");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
        expected = zeros();
        expected.incentiveRatio = 0.008 ether;
        expected.wrappedFee = (2 * 0.008 ether);
        expected.peggedRedeemed = 2 * price;
        expected.wrappedCollateralReturned = (2 ether) - expected.wrappedFee;
        _testRedeemPeggedDryRun(2 * price, expected, sender);

        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(2 * price, receiver, 0);
        // 8 ------------------------------------------------
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            2 ether - (2 * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios)))
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_redeemPeggedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
        // mixed bonus and fee
    }

    function test_redeemPeggedNormal() public {
        setUp_collateral(20 ether, 0);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 2, so no excess fees
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

        deal(address(peggedToken), sender, pegged * 2);
        vm.prank(sender);

        IERC20(peggedToken).approve(minter, type(uint256).max);
        deal(address(Deployed.wstETH), sender, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
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
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore);

        // mint from all of balance
        redeemPeggedFee =
            (senderPeggedBefore * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) / price;
        expectedCollateralOut = collateral - redeemPeggedFee;

        _redeemPeggedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);
        assertEq(IERC20(peggedToken).balanceOf(sender), 0, "transferred it all");
    }

    function test_redeemPeggedDepegged() public {
        setUp_collateral(20 ether, 0);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        price /= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 0.5, to depeg
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

        deal(address(peggedToken), sender, pegged * 2);
        vm.prank(sender);

        IERC20(peggedToken).approve(minter, type(uint256).max);
        deal(address(Deployed.wstETH), sender, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut);
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                expectedCollateralOut + 1,
                expectedCollateralOut
            )
        );
        vm.prank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut + 1);
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore);

        // mint from all of balance
        redeemPeggedFee =
            (senderPeggedBefore * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            price;
        expectedCollateralOut = collateral - redeemPeggedFee;

        _redeemPeggedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);
        assertEq(IERC20(peggedToken).balanceOf(sender), 0, "transferred it all");
*/
    }
}
