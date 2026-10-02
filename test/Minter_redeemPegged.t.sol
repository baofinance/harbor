// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

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
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
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

        assertEq(IHarborOwnable(minter).owner(), owner());

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
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
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

        assertEq(IHarborOwnable(minter).owner(), owner());

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

    // Golden hand-computed case (no formula re-derivation): redeem 2000 pegged at oracle price 2000 (rate 1.0),
    // 0.8% redeem fee, collateral ratio >= 1 so the pegged price is exactly 1.0.
    //   fee (in pegged)     = 0.8% * 2000    = 16 pegged
    //   net pegged          = 2000 - 16      = 1984
    //   collateral returned = 1984 / 2000    = 0.992 collateral   (exact)
    //   fee (in collateral) = 16 / 2000      = 0.008 collateral   (exact)
    function test_redeemPegged_goldenExact() public {
        setUp_collateral(2 ether, 0); // CR == 1.0: minter holds 4000 pegged backed by 2 collateral
        deal(address(peggedToken), sender, 2000 ether);
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        uint256 feeBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 returned = IMinter(minter).redeemPeggedToken(2000 ether, receiver, 0);
        vm.stopPrank();

        assertEq(returned, 0.992 ether, "returned = 1984 / 2000 = 0.992");
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver) - feeBefore, 0.008 ether, "fee = 16 / 2000 = 0.008");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            0.992 ether,
            "receiver got exactly the returned collateral"
        );
    }

    // Rounding direction (intentional, pinned so a future flip is caught). Redeem rounds DOWN like mint, verified
    // against the contract with a non-integer amount.
    //
    // Redeeming 2000 + 1 wei pegged at price 2000, 0.8% fee, CR >= 1:
    //   fee (pegged)        = floor((2000e18 + 1) * 0.008)  = 16e18          (the +1 wei is below the fee granularity)
    //   net pegged          = 2000e18 + 1 - 16e18           = 1984e18 + 1
    //   collateral returned = (1984e18 + 1) / 2000          = 0.992e18 + 0.5 (rational) -> floors to 0.992e18
    // The user receives 0.992 ether (the floor), never 0.992 ether + 1.
    function test_redeemPegged_userAmountRoundsDown() public {
        setUp_collateral(2 ether, 0); // CR == 1.0, clean price 2000
        deal(address(peggedToken), sender, 2000 ether + 1);
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        uint256 returned = IMinter(minter).redeemPeggedToken(2000 ether + 1, receiver, 0);
        vm.stopPrank();
        // Returned floors to 0.992; the ceil (0.992 + 1) a rounding-flip would produce must be rejected — the
        // discrimination that used to need a manual src mutation now runs on every CI.
        assertDiscriminates(returned, 0.992 ether, 0, 0.992 ether + 1, "returned floors to 0.992");
    }

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
        uint256 wrappedSubsidy;
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
            r.wrappedSubsidy,
            r.peggedRedeemed,
            r.wrappedCollateralReturned,
            r.price,
            r.rate
        ) = IMinter(minter).redeemPeggedTokenDryRun(collateralIn);
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedSubsidy, expected.wrappedSubsidy, "wrappedSubsidy");
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
                wrappedSubsidy: 0,
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

    /// Redeeming the anchor token for collateral does not move the sail token's price - the redeem
    /// removes collateral and anchor claims in the same proportion, so the residual the sail is a
    /// claim on is unchanged - while a move in the collateral price does move it.
    ///
    /// Both halves are asserted together because the first alone cannot fail loudly enough to be
    /// trusted: an equality that holds because nothing in the setup could ever move the price looks
    /// identical to one that holds because the redeem is genuinely neutral. The second half is the
    /// control that tells them apart, on every run rather than once.
    ///
    /// Neutrality is claimed for the free path; a fee is the one thing that legitimately dilutes, and
    /// then only the payer.
    function test_freeRedeemPeggedToken_leavesLeveragedPriceUnchanged() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the sail has a price to move

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        uint256 anchorToRedeem = IERC20(peggedToken).balanceOf(zeroFee) / 2;
        assertGt(anchorToRedeem, 0, "nothing to redeem");

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, anchorToRedeem);
        IMinter(minter).freeRedeemPeggedToken(anchorToRedeem, 0, receiver);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "redeeming the anchor moved the sail price"
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

    /// Paying a redeem fee does not move the sail price either, so a fee dilutes only the payer. The
    /// fee is withheld from the collateral returned, so what leaves the minter and the anchor burnt
    /// stay in the proportion that leaves the residual untouched; the payer simply receives less.
    ///
    /// The fee is asserted non-zero, because a configuration with no fee would make this the free-path
    /// test again under a name claiming otherwise. The reserve pool is asserted empty, because a
    /// subsidy drawn from it would add collateral from outside the market and move the price for a
    /// reason that has nothing to do with the redeem's own proportions.
    function test_redeemPeggedToken_leavesLeveragedPriceUnchanged_whenFeePaid() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the sail has a price to move

        uint256 anchorToRedeem = IERC20(peggedToken).balanceOf(zeroFee) / 2;
        assertGt(anchorToRedeem, 0, "nothing to redeem");
        vm.startPrank(zeroFee);
        IERC20(peggedToken).transfer(sender, anchorToRedeem);
        vm.stopPrank();

        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, anchorToRedeem);
        vm.stopPrank();
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole), "the payer must not be fee-exempt");
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "a subsidy would move the price by other means");

        (, uint256 fee, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(anchorToRedeem);
        assertGt(fee, 0, "a fee of zero would make this the free path under another name");

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        vm.startPrank(sender);
        IMinter(minter).redeemPeggedToken(anchorToRedeem, sender, 0);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a fee-paying anchor redeem diluted the sail holders"
        );

        // the control: the collateral price is the one input that may move the sail price
        (uint256 collateralPrice2, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((collateralPrice2 * 110) / 100);
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the sail price, or the assertion above proves nothing"
        );
    }
}

/// @notice A pegged redemption never pays more than the exact formula: the collateral the pegged is worth - a pegged
/// unit's worth each at the peg, its share of the backing below it - converted at the rate, less the fee or plus the
/// subsidy. Every rounding on the way goes the protocol's way.
abstract contract TestMinterRedeemPeggedExact is TestMinterSetUp {
    address user;

    /// @dev The schedule's one ratio, a fee when positive and a subsidy when negative.
    function _ratio() internal view virtual returns (int256);

    /// @dev A market founded at a price of one at a ratio of 1.5, `user` holding the pegged, then priced at `price`.
    function _redeem(uint256 pegged, uint256 rate, uint256 price) internal returns (uint256 paid, uint256 exact) {
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, rate);
        setUp_collateral(100 ether, 50 ether, user);
        deal(wrappedCollateralToken, reservePool, 1e30); // a subsidy is never capped
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 supply = IMinter(minter).peggedTokenBalance();
        pegged = bound(pegged, 1e9, supply / 2);
        uint256 keptPerUnit = uint256(1 ether - _ratio()); // what is left of each unit after the fee or subsidy
        exact = backing * price >= supply * 1 ether
            ? Math.mulDiv(pegged * keptPerUnit, 1 ether, price * rate)
            : Math.mulDiv(pegged * keptPerUnit, backing, supply * rate);

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, pegged);
        paid = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();
    }

    /// Never more than the exact formula, across rates, prices from below the peg to far above it, and amounts.
    function testFuzz_redeemPegged_neverPaysMoreThanTheExactFormula(
        uint256 pegged,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 0.3 ether, 100 ether); // the ratio from 0.45 to 150
        (uint256 paid, uint256 exact) = _redeem(pegged, rate, price);
        assertLe(paid, exact, "no more than the exact formula pays");
    }
}

/// @notice ... charging one fee in every band.
contract TestMinterRedeemPeggedExactFee is TestMinterRedeemPeggedExact {
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(50, 50, 50, 50, 50, 50, 50, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    function _ratio() internal view override returns (int256) {
        return config.redeemPeggedIncentiveConfig.incentiveRatios[0];
    }
}

/// @notice A pegged redemption pays the redeemer the collateral the pegged is worth, less the fee, plus the subsidy,
/// rounded down once from the exact figure - but never more than the whole wei the backing releases and the reserve
/// sends; the fee receiver absorbs the remainder.
contract TestMinterRedeemPeggedRoundedOnce is TestMinterSetUp {
    address user;

    /// @dev A subsidy up to a ratio of 1.5 and a fee above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 150), ia(-50, -50, 70)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.3 a redemption takes the subsidy up to 1.5 and pays the fee past it. The collateral is priced
    /// once, each slice's subsidy and fee are exact on the collateral it takes, and the redeemer is paid their sum rounded
    /// down once, within what is released and sent in whole wei.
    function testFuzz_redeemPegged_acrossASubsidyIntoAFee_paysTheExactNetRoundedOnce(
        uint256 extra,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 30 ether, user); // a ratio of 1.3
        deal(wrappedCollateralToken, reservePool, 1e30); // the subsidy is never capped

        uint256 pegged;
        uint256 expected;
        {
            uint256 bound15 = config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[1];
            uint256 supply = IMinter(minter).peggedTokenBalance();
            // the pegged whose redemption brings the ratio from 1.3 to 1.5, at a pegged price of one
            uint256 toTheBoundE36 = (bound15 * (supply * 1 ether) -
                (IMinter(minter).collateralTokenBalance() * 1 ether) * price) / (bound15 - 1 ether);
            pegged = Math.ceilDiv(toTheBoundE36, 1 ether) + bound(extra, 1e9, supply / 4);
            uint256 subsidyE54;
            uint256 feeE54;
            uint256 collateralE36;
            {
                // the collateral the pegged redeems for, at a pegged unit's worth each, and the part of it below the bound
                collateralE36 = Math.mulDiv(pegged * 1 ether, 1e36, price) / 1 ether;
                uint256 subsidisedE36 = Math.mulDiv(toTheBoundE36, 1e36, price) / 1 ether;
                subsidyE54 = subsidisedE36 * uint256(-config.redeemPeggedIncentiveConfig.incentiveRatios[1]);
                feeE54 =
                    (collateralE36 - subsidisedE36) * uint256(config.redeemPeggedIncentiveConfig.incentiveRatios[2]);
            }
            expected = Math.min(
                (collateralE36 * 1 ether - feeE54 + subsidyE54) / (rate * 1 ether),
                collateralE36 / rate + subsidyE54 / (rate * 1 ether)
            );
        }

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, pegged);
        uint256 paid = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();

        assertEq(paid, expected, "the collateral less the fee plus the subsidy, rounded down once");
    }
}

/// @notice ... subsidising at one rate up to the widest bound the storage holds, beyond every ratio reached here.
contract TestMinterRedeemPeggedExactSubsidy is TestMinterRedeemPeggedExact {
    function setUpConfig() internal virtual override {
        IMinter.IncentiveConfig memory redeemPegged = ic(ua(100, 110), ia(-50, -50, 0));
        redeemPegged.collateralRatioBandUpperBounds[1] = ConfigIncentiveLib.MAX_COLLATERAL_RATIO_BOUND;
        setUp_config(ic(ua(100), ia(0, 0)), redeemPegged, ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)));
    }

    function _ratio() internal view override returns (int256) {
        return config.redeemPeggedIncentiveConfig.incentiveRatios[0];
    }
}

/// @notice A pegged redemption is worth the collateral its pegged redeems for, priced once, and each band's fee is
/// charged exactly on the collateral it takes there - so a redemption whose exact payout is a whole number of wei is paid
/// exactly that, whatever bounds it crosses.
contract TestMinterRedeemPeggedAcrossEqualFees is TestMinterSetUp {
    address user;

    /// @dev Redeeming pegged charges 0.5% in every band, either side of bounds at the peg and at 1.45 - where the pegged
    ///      that brings the ratio up from 1.3 is a fraction of a wei, so each slice's collateral and fee are fractions too.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 145), ia(50, 50, 50)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.3 a redemption of 50 collateral's worth crosses 1.45. At a wrapped-to-underlying rate of one
    /// and a price of 2000 the collateral less 0.5% is a whole number of wei, and it is paid exactly.
    function test_redeemPegged_acrossABoundBetweenEqualFees_paysExactlyTheCollateralLessTheFee() public {
        uint256 price = 2000 ether;
        uint256 rate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        user = makeAddr("user");
        setUp_collateral(100 ether, 30 ether, user); // a ratio of 1.3
        uint256 collateral = 50 ether;
        uint256 pegged = (collateral * price) / 1 ether;
        uint256 feeRatio = uint256(config.redeemPeggedIncentiveConfig.incentiveRatios[1]);

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, pegged);
        uint256 paid = IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();

        assertGt(
            IMinter(minter).collateralRatio(),
            config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[1],
            "the redemption crossed the bound"
        );
        assertEq(paid, (collateral * (1 ether - feeRatio)) / rate, "the collateral less the fee");
    }
}
