// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

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

    /// @dev Redeems `peggedIn` of the zero-fee actor's pegged for collateral by the zero-fee route and checks every
    ///      balance it moves: capped at what this minter minted, each pegged paid a pegged unit's worth of collateral,
    ///      at the price and the wrapped-to-underlying rate of one this suite's oracle gives.
    function _freeRedeemPeggedToken(uint256 peggedIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 ownerPeggedDecrease = Math.min(peggedIn, minterPeggedBefore);

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

        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, ownerPeggedDecrease, receiverCollateralIncrease, 0);
        (uint256 returned, ) = IMinter(minter).freeRedeemPeggedToken(peggedIn, 0, receiver);
        vm.stopPrank();
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

    /// The zero-fee pegged redemption for collateral: reverts for a caller without the zero-fee role; a redemption of
    /// nothing is a no-op; where this minter has minted nothing - the caller's pegged minted elsewhere included - it
    /// reverts as having nothing to redeem, and its dry run reports nothing. Served, it pays a pegged unit's worth of
    /// collateral for each pegged, with no fee, capped at what this minter minted.
    function test_freeRedeemPegged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.startPrank(sender);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        vm.stopPrank();
        // 1 ----------------------------------------------------------------

        // zero input, when none: a redemption of nothing is a no-op
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        vm.startPrank(zeroFee);
        (uint256 collateralOut, uint256 leveragedOut) = IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        vm.stopPrank();
        assertEq(collateralOut, 0, "no collateral for redeeming nothing");
        assertEq(leveragedOut, 0, "no leveraged for redeeming nothing");
        // 2 ----------------------------------------------------------

        // some input, when none: nothing to redeem, and the dry run says so
        (uint256 previewedCollateral, uint256 previewedLeveraged) = IMinter_v3(minter).freeRedeemDryRun(price, 0);
        assertEq(previewedCollateral, 0, "the dry run pays no collateral where nothing was minted");
        assertEq(previewedLeveraged, 0, "and mints no leveraged");
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        vm.stopPrank();
        // 3 ----------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(peggedToken).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(peggedToken).balanceOf(zeroFee);

        uint256 mintedBaoUSD = 10 * price;

        _mintPegged(zeroFee, mintedBaoUSD);

        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(peggedToken).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(peggedToken).balanceOf(zeroFee));
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        // zero input, when some: still a no-op
        vm.startPrank(zeroFee);
        (collateralOut, leveragedOut) = IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        vm.stopPrank();
        assertEq(collateralOut, 0, "no collateral for redeeming nothing");
        assertEq(leveragedOut, 0, "no leveraged for redeeming nothing");
        // 4 -----------------------------------------------------------

        assertEq(IHarborOwnable(minter).owner(), owner());

        // the caller's pegged was minted elsewhere, and this minter has minted none, so there is nothing to redeem
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        vm.stopPrank();
        // 5 ----------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.startPrank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();

        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD + price);
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance"
        );

        // check that we can't redeem more than minter has minted
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, price, 1 ether, 0);
        IMinter(minter).freeRedeemPeggedToken(price, 0, receiver);
        vm.stopPrank();
        // 6 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 1 ether);

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before mint pegged"
        );
        // first normal mint
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(6 ether, zeroFee);
        vm.stopPrank();

        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 1");
        _freeRedeemPeggedToken(price);
        // 7 ------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio still 1"); // there are no leveraged tokens in this test

        // more than one mint
        _freeRedeemPeggedToken(2 * price);
        // 8 ----------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Free Swap Pegged
    //---------------------------------------------------------------------------------------------

    /// @dev Converts `peggedIn` of the zero-fee actor's pegged into leveraged by the zero-fee route and checks every
    ///      balance it moves: capped at what this minter minted, the pegged buying its value's share of the leveraged
    ///      supply, the backing untouched.
    function _freeSwapPeggedForLeveraged(uint256 peggedIn) private {
        uint256 minterPeggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 ownerPeggedDecrease = Math.min(peggedIn, minterPeggedBefore);

        // With no leveraged yet a pegged converts one for one; otherwise a leveraged token is a claim on the residual,
        // so the pegged buys its value's share of the leveraged supply - at the oracle's one price, which is also the
        // middle of its band that the free route prices at.
        uint256 receiverLeveragedIncrease = ownerPeggedDecrease;
        if (IMinter(minter).leveragedTokenBalance() > 0) {
            (uint256 minPrice, uint256 maxPrice, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            assertEq(minPrice, maxPrice, "precondition: the oracle answers one price");
            receiverLeveragedIncrease = Math.mulDiv(
                ownerPeggedDecrease * 1 ether,
                IMinter(minter).leveragedTokenBalance(),
                IMinter(minter).collateralTokenBalance() * minPrice - minterPeggedBefore * 1 ether
            );
        }
        uint256 ownerPeggedBefore = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(zeroFee, receiver, ownerPeggedDecrease, 0, receiverLeveragedIncrease);
        (, uint256 returned) = IMinter(minter).freeRedeemPeggedToken(0, peggedIn, receiver);
        vm.stopPrank();
        assertEq(returned, receiverLeveragedIncrease, "the pegged buys its value's share of the leveraged");
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            receiverLeveragedBefore + returned,
            "leveraged not mis-transferred to receiver"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore);

        assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBefore - ownerPeggedDecrease);
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), ownerPeggedBefore - ownerPeggedDecrease, "pegged not burned");

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    /// The zero-fee conversion of pegged into leveraged: reverts for a caller without the zero-fee role; a conversion of
    /// nothing is a no-op; where this minter has minted nothing it reverts as having nothing to redeem; in a market of
    /// pegged alone, at a ratio of one, it reverts at the min CR and burns nothing. Served, the pegged buys its value's
    /// share of the leveraged supply and the ratio rises.
    function test_freeSwapPegged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // mint noaccess
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.startPrank(sender);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        vm.stopPrank();
        // 1 ----------------------------------------------------------------

        // zero input, when none: a swap of nothing is a no-op
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        vm.startPrank(zeroFee);
        (uint256 collateralOut, uint256 leveragedOut) = IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        vm.stopPrank();
        assertEq(collateralOut, 0, "no collateral for swapping nothing");
        assertEq(leveragedOut, 0, "no leveraged for swapping nothing");
        // 2 ----------------------------------------------------------

        // some input, when none: nothing to redeem
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        vm.stopPrank();
        // 3 ----------------------------------------------------------------

        uint256 BaoUSDTotalSupplyBefore = IERC20(peggedToken).totalSupply();
        uint256 BaoUSDBalanceOfOwnerBefore = IERC20(peggedToken).balanceOf(zeroFee);

        uint256 mintedBaoUSD = 10 * price;
        _mintPegged(zeroFee, mintedBaoUSD);
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(BaoUSDTotalSupplyBefore + mintedBaoUSD, IERC20(peggedToken).totalSupply());
        assertEq(BaoUSDBalanceOfOwnerBefore + mintedBaoUSD, IERC20(peggedToken).balanceOf(zeroFee));
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);

        // approve of minter burning receiver's pegged
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        // zero input, when some: still a no-op
        vm.startPrank(zeroFee);
        (collateralOut, leveragedOut) = IMinter(minter).freeRedeemPeggedToken(0, 0, receiver);
        vm.stopPrank();
        assertEq(collateralOut, 0, "no collateral for swapping nothing");
        assertEq(leveragedOut, 0, "no leveraged for swapping nothing");
        // 4 -----------------------------------------------------------

        assertEq(IHarborOwnable(minter).owner(), owner());

        // the caller's pegged was minted elsewhere, and this minter has minted none, so there is nothing to convert
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        vm.stopPrank();
        // 5 ----------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.startPrank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();

        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD);
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), mintedBaoUSD + price);

        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        // pegged alone: a ratio of exactly one, under the min CR, where no leveraged is minted on any route, so the
        // swap reverts and burns nothing
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.startPrank(zeroFee);
        vm.expectRevert(belowMinimum);
        IMinter(minter).freeRedeemPeggedToken(0, price, receiver);
        vm.stopPrank();
        // 6 ----------------------------------------------------------------
        assertEq(IMinter(minter).peggedTokenBalance(), price);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // first normal swap: with a leveraged supply, and the market above the min CR
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        IMinter(minter).freeMintPeggedToken(6 ether, zeroFee);
        vm.stopPrank();
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++
        uint256 beforeCR = IMinter(minter).collateralRatio();
        _freeSwapPeggedForLeveraged(price);
        // 7 -----------------------------
        assertGt(IMinter(minter).collateralRatio(), beforeCR, "collateral ratio should be greater");

        // more than one swap
        _freeSwapPeggedForLeveraged(2 * price);
        // 8 ----------------------------
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
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        assertEq(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios), 0.008 ether, "the case's 0.8% fee");
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

    // Rounding direction (intentional, pinned so a future flip is caught). The collateral returned is the exact net
    // rounded down once, verified against the contract with a non-integer amount.
    //
    // Redeeming 2000e18 + 1500 wei pegged at price 2000, 0.8% fee, CR >= 1:
    //   collateral redeemed for = (2000e18 + 1500) / 2000      = 1e18 + 0.75        (rational, in wei)
    //   fee                     = 0.8% of that                 = 8e15 + 0.006
    //   collateral returned     = 1e18 + 0.75 - 8e15 - 0.006   = 0.992e18 + 0.744   -> floors to 0.992e18
    // The user receives 0.992 ether (the floor), never 0.992 ether + 1 - which rounding up, or to nearest, pays.
    function test_redeemPegged_userAmountRoundsDown() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        assertEq(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios), 0.008 ether, "the case's 0.8% fee");
        setUp_collateral(2 ether, 0); // CR == 1.0
        deal(address(peggedToken), sender, 2000 ether + 1500);
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        uint256 returned = IMinter(minter).redeemPeggedToken(2000 ether + 1500, receiver, 0);
        vm.stopPrank();
        // Returned floors to 0.992; the 0.992 + 1 a rounding flip would produce must be rejected, on every run.
        assertDiscriminates(returned, 0.992 ether, 0, 0.992 ether + 1, "returned floors to 0.992");
    }

    function _redeemPeggedToken(uint256 peggedIn) private {
        uint256 senderPeggedDecrease;
        if (peggedIn == type(uint256).max) {
            senderPeggedDecrease = IERC20(peggedToken).balanceOf(sender);
        } else {
            senderPeggedDecrease = peggedIn;
        }

        deal(address(peggedToken), sender, senderPeggedDecrease);
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        WrappedHeld memory before = WrappedHeld(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            IERC20(Deployed.wstETH).balanceOf(receiver),
            IERC20(Deployed.wstETH).balanceOf(minter),
            IERC20(Deployed.wstETH).balanceOf(reservePool)
        );
        uint256 senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        uint256 totalPeggedBefore = IERC20(peggedToken).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        uint256 receiverCollateralIncrease;
        uint256 redeemPeggedFee;
        {
            (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            uint256 redeemPeggedFeeInPegged = (senderPeggedDecrease *
                uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) / 1 ether;

            receiverCollateralIncrease = (collateralRatioBefore < 1 ether)
                ? (((peggedIn - redeemPeggedFeeInPegged) * minterCollateralBalanceBefore) / minterPeggedBalanceBefore)
                : ((senderPeggedDecrease - redeemPeggedFeeInPegged) * 1 ether) / price;
            redeemPeggedFee = (collateralRatioBefore < 1 ether)
                ? ((redeemPeggedFeeInPegged * minterCollateralBalanceBefore) / minterPeggedBalanceBefore)
                : (redeemPeggedFeeInPegged * 1 ether) / price;
        }

        vm.startPrank(sender);
        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(sender, receiver, senderPeggedDecrease, receiverCollateralIncrease, 0);
        uint256 returned = IMinter(minter).redeemPeggedToken(senderPeggedDecrease, receiver, 0);
        vm.stopPrank();
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemPeggedFee,
            "minter is tracking the underlying collateral"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            before.feeReceiver + redeemPeggedFee,
            "fee transferred"
        );
        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore - senderPeggedDecrease, "token sent");
        assertEq(IERC20(peggedToken).totalSupply(), totalPeggedBefore - senderPeggedDecrease, "token burned");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            before.receiver + receiverCollateralIncrease,
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
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(reservePool),
            before.reserve,
            "the reserve sends nothing to a redemption priced at the fee"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            before.minter - receiverCollateralIncrease - redeemPeggedFee,
            "wstETH has minter owning it"
        );
        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    /// @dev The wrapped collateral each party to a redemption holds: the fee receiver, the receiver, the minter and
    ///      the reserve.
    struct WrappedHeld {
        uint256 feeReceiver;
        uint256 receiver;
        uint256 minter;
        uint256 reserve;
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
        vm.startPrank(sender_);
        (
            r.incentiveRatio,
            r.wrappedFee,
            r.wrappedSubsidy,
            r.peggedRedeemed,
            r.wrappedCollateralReturned,
            r.price,
            r.rate
        ) = IMinter(minter).redeemPeggedTokenDryRun(collateralIn);
        vm.stopPrank();
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
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        int256 feeRatio = ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios); // one fee in every band
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(peggedToken).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        _testRedeemPeggedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        vm.stopPrank();
        // 1 --------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        _testRedeemPeggedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // some input, when no leveraged Tokens
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 3 -------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // some input, when none: with the burn approved, the caller's empty balance is what makes it revert
        setUp_collateral(1 ether, 0); // collateral ratio == 1.0
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = (1 ether * uint256(feeRatio)) / price;
        expected.peggedRedeemed = 1 ether;
        expected.wrappedCollateralReturned = (1 ether * 1 ether) / price - expected.wrappedFee;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, 0, 1 ether));
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        IERC20(peggedToken).approve(minter, 0);
        vm.stopPrank();
        // 4 -------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        // no actual balance
        expected.incentiveRatio = feeRatio;
        _testRedeemPeggedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // get tokens to redeem
        setUp_collateral(1 ether, 0, sender);
        assertEq(IERC20(peggedToken).balanceOf(sender), 1 * price, "sender has 1");

        // redeem no allowance: the burn reverts on the allowance before it looks at the balance
        assertEq(IERC20(peggedToken).allowance(sender, minter), 0);
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = (1 ether * uint256(feeRatio)) / price;
        expected.peggedRedeemed = 1 ether;
        expected.wrappedCollateralReturned = (1 ether * 1 ether) / price - expected.wrappedFee;
        _testRedeemPeggedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 0, 1 ether));
        IMinter(minter).redeemPeggedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 6 --------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        _testRedeemPeggedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(0, receiver, 0);
        vm.stopPrank();
        // 7 --------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 0);

        // can't mint some because the config has it disallowed at < 1.31 and we're at 1
        // mint some then redeem it:
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is 1");
        assertEq(IERC20(peggedToken).balanceOf(sender), 1 * price, "sender still has 1");
        setUp_collateral(2 ether, 0, sender);
        assertEq(IERC20(peggedToken).balanceOf(sender), 3 * price, "sender has 3");
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR is still 1");
        // get allowance
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, 3 * price);
        vm.stopPrank();

        assertEq(IMinter(minter).collateralTokenBalance(), 4 ether, "collaterals should be 4");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = 2 * uint256(feeRatio);
        expected.peggedRedeemed = 2 * price;
        expected.wrappedCollateralReturned = (2 ether) - expected.wrappedFee;
        _testRedeemPeggedDryRun(2 * price, expected, sender);

        vm.startPrank(sender);
        IMinter(minter).redeemPeggedToken(2 * price, receiver, 0);
        vm.stopPrank();
        // 8 ------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 2 ether - (2 * uint256(feeRatio)));
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after the redeem"
        );
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
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        deal(address(Deployed.wstETH), sender, collateral * 10);

        uint256 redeemPeggedFee = (collateral * uint256(ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios))) /
            1 ether;
        uint256 expectedCollateralOut = collateral - redeemPeggedFee;

        uint256 senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just within
        vm.startPrank(sender);
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut);
        vm.stopPrank();
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(peggedToken).balanceOf(sender), senderPeggedBefore - pegged);

        senderPeggedBefore = IERC20(peggedToken).balanceOf(sender);
        receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just over
        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                expectedCollateralOut,
                expectedCollateralOut + 1
            )
        );
        IMinter(minter).redeemPeggedToken(pegged, receiver, expectedCollateralOut + 1);
        vm.stopPrank();
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
    }

    /// Redeeming the pegged token for collateral does not move the leveraged token's price - the redeem
    /// removes collateral and pegged claims in the same proportion, so the residual the leveraged token
    /// is a claim on is unchanged - while a move in the collateral price does move it.
    ///
    /// Both halves are asserted together because the first alone cannot fail loudly enough to be
    /// trusted: an equality that holds because nothing in the setup could ever move the price looks
    /// identical to one that holds because the redeem is genuinely neutral. The second half is the
    /// control that tells them apart, on every run rather than once.
    ///
    /// Neutrality is claimed for the free path; a fee is the one thing that legitimately dilutes, and
    /// then only the payer.
    function test_freeRedeemPeggedToken_leavesLeveragedPriceUnchanged() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the leveraged token has a price to move

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the leveraged token needs a price for this to assert anything");

        uint256 peggedToRedeem = IERC20(peggedToken).balanceOf(zeroFee) / 2;
        assertGt(peggedToRedeem, 0, "nothing to redeem");

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, peggedToRedeem);
        IMinter(minter).freeRedeemPeggedToken(peggedToRedeem, 0, receiver);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "redeeming the pegged token moved the leveraged price"
        );

        // the control: the collateral price is the one input that may move the leveraged price
        (uint256 collateralPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((collateralPrice * 110) / 100);
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the leveraged price, or the assertion above proves nothing"
        );
    }

    /// Paying a redeem fee does not move the leveraged price either, so a fee dilutes only the payer. The
    /// fee is withheld from the collateral returned, so what leaves the minter and the pegged burnt
    /// stay in the proportion that leaves the residual untouched; the payer simply receives less.
    ///
    /// The fee is asserted non-zero, because a configuration with no fee would make this the free-path
    /// test again under a name claiming otherwise. The reserve pool is asserted empty, because a
    /// subsidy drawn from it would add collateral from outside the market and move the price for a
    /// reason that has nothing to do with the redeem's own proportions.
    function test_redeemPeggedToken_leavesLeveragedPriceUnchanged_whenFeePaid() public {
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so the leveraged token has a price to move

        uint256 peggedToRedeem = IERC20(peggedToken).balanceOf(zeroFee) / 2;
        assertGt(peggedToRedeem, 0, "nothing to redeem");
        vm.startPrank(zeroFee);
        IERC20(peggedToken).transfer(sender, peggedToRedeem);
        vm.stopPrank();

        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, peggedToRedeem);
        vm.stopPrank();
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole), "the payer must not be fee-exempt");
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "a subsidy would move the price by other means");

        (, uint256 fee, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(peggedToRedeem);
        assertGt(fee, 0, "a fee of zero would make this the free path under another name");

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the leveraged token needs a price for this to assert anything");

        vm.startPrank(sender);
        IMinter(minter).redeemPeggedToken(peggedToRedeem, sender, 0);
        vm.stopPrank();

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a fee-paying pegged redeem diluted the leveraged holders"
        );

        // the control: the collateral price is the one input that may move the leveraged price
        (uint256 collateralPrice2, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((collateralPrice2 * 110) / 100);
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the leveraged price, or the assertion above proves nothing"
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

    /// @dev A market whose genesis is at a price of one and a ratio of 1.5, `user` holding the pegged, then priced
    ///      at `price`.
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

/// @notice A pegged redemption walks up through the bands it crosses, each slice priced at its own band's fee or
/// subsidy; it redeems no more than this minter minted, reads the sentinel as the caller's whole balance, and reverts as
/// paying nothing wherever it would pay nothing, whatever minimum the caller set.
contract TestMinterRedeemPeggedAcrossBands is TestMinterSetUp {
    address user;

    /// @dev What a redemption moves: what the redeemer is paid, the fee receiver is paid, and the reserve sends.
    struct Outcome {
        uint256 paid;
        uint256 fee;
        uint256 subsidy;
    }

    /// @dev What the walk carries from band to band, at 1e36: the pegged still to redeem, the pegged held, the pegged
    ///      redeemed so far and the collateral it is worth, and the fee and the subsidy accrued, exact.
    struct RedeemWalk {
        uint256 leftE36;
        uint256 peggedHeldE36;
        uint256 redeemedE36;
        uint256 collateralRedeemedE36;
        uint256 feeE54;
        uint256 subsidyE54;
    }

    /// @dev Redeeming pegged is subsidised 0.5% below the peg and 0.3% from the peg to 1.2, and charges 0.3% from 1.2
    ///      to 1.5 and 0.8% above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 120, 150), ia(-50, -30, 30, 80)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
        deal(wrappedCollateralToken, reservePool, 1e30); // a subsidy is never capped
    }

    /// A redemption that pays nothing reverts as paying nothing, whatever minimum the caller set: a wei of pegged,
    /// worth a two-thousandth of a collateral wei, with a minimum of one.
    function test_redeemPegged_aPayoutOfNothingWithAMinimumSet_revertsAsReturningNothing() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        (, , , , uint256 dryRunPaid, , ) = IMinter(minter).redeemPeggedTokenDryRun(1);
        assertEq(dryRunPaid, 0, "precondition: a wei of pegged pays nothing");

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, 1);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemPeggedToken(1, user, 1);
        vm.stopPrank();
    }

    /// The sentinel redeems the caller's whole balance - here only part of the minter's supply - paying what a
    /// redemption of exactly that balance pays.
    function test_redeemPegged_withTheMaxSentinel_redeemsTheCallersWholeBalance() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8, its pegged held by another
        setUp_collateral(10 ether, 0, user); // the caller's part of the supply
        uint256 balance = IERC20(peggedToken).balanceOf(user);
        assertLt(balance, IMinter(minter).peggedTokenBalance(), "precondition: the caller holds part of the supply");
        (, , , , uint256 dryRunPaid, , ) = IMinter(minter).redeemPeggedTokenDryRun(balance);

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        uint256 paid = IMinter(minter).redeemPeggedToken(type(uint256).max, user, 0);
        vm.stopPrank();

        assertEq(IERC20(peggedToken).balanceOf(user), 0, "the caller's whole balance is redeemed");
        assertEq(paid, dryRunPaid, "paid as a redemption of exactly that balance");
    }

    /// A3: a caller holding pegged minted elsewhere as well as all this minter minted redeems exactly what this minter
    /// minted; the rest stays with them, beyond the reach of this market's collateral.
    function test_redeemPegged_redeemsNoMoreThanThisMinterMinted() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether, user); // the caller holds all this minter minted
        uint256 mintedHere = IMinter(minter).peggedTokenBalance();
        uint256 mintedElsewhere = 5000 ether;
        _mintPegged(user, mintedElsewhere);
        (, , , uint256 dryRunRedeemed, uint256 dryRunPaid, , ) = IMinter(minter).redeemPeggedTokenDryRun(
            mintedHere + mintedElsewhere
        );
        assertEq(dryRunRedeemed, mintedHere, "the dry run redeems only what this minter minted");

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.RedeemPeggedToken(user, user, mintedHere, dryRunPaid, 0);
        IMinter(minter).redeemPeggedToken(mintedHere + mintedElsewhere, user, 0);
        vm.stopPrank();

        assertEq(IMinter(minter).peggedTokenBalance(), 0, "exactly what this minter minted is redeemed");
        assertEq(IERC20(peggedToken).balanceOf(user), mintedElsewhere, "the pegged minted elsewhere stays");
    }

    /// Below the peg a pegged token redeems for its share of the backing, and the band's subsidy is paid on top from
    /// the reserve - exactly, with the event reporting the subsidised payout.
    function test_redeemPegged_belowThePeg_paysTheConfiguredSubsidy() public {
        uint256 rate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, rate);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether, rate); // a ratio of 0.9, below the peg
        uint256 pegged = 10_000 ether;
        uint256 expectedSubsidy;
        uint256 expectedPaid;
        {
            // the share of the backing the pegged is a claim on, and the band's subsidy on it, exact
            uint256 shareE36 = Math.mulDiv(
                pegged * 1 ether,
                IMinter(minter).collateralTokenBalance() * 1 ether,
                IMinter(minter).peggedTokenBalance()
            ) / 1 ether;
            uint256 subsidyE54 = shareE36 * uint256(-config.redeemPeggedIncentiveConfig.incentiveRatios[0]);
            expectedSubsidy = subsidyE54 / (rate * 1 ether);
            expectedPaid = Math.min(
                (shareE36 * 1 ether + subsidyE54) / (rate * 1 ether),
                shareE36 / rate + expectedSubsidy
            );
        }
        assertGt(expectedSubsidy, 0, "precondition: the band subsidises");
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(user);

        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, pegged);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.RedeemPeggedToken(user, user, pegged, expectedPaid, 0);
        IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();

        assertEq(
            reserveBefore - IERC20(wrappedCollateralToken).balanceOf(reservePool),
            expectedSubsidy,
            "the reserve sends exactly the band's subsidy"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(user) - heldBefore,
            expectedPaid,
            "the redeemer is paid the share and the subsidy"
        );
    }

    /// From a ratio of 1.1 a redemption to about 1.35 crosses one bound and one to about 1.8 crosses two. The collateral
    /// is priced once and split where the ratio reaches each band's upper bound, each slice's subsidy or fee exact on its
    /// collateral; the redeemer, the fee receiver and the reserve each move by exactly their part.
    function test_redeemPegged_acrossOneAndTwoBandBounds_pricesEachSliceAtItsBand(uint256 rate, uint256 price) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 10 ether, user); // a ratio of 1.1
        uint256[] memory bounds = config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds;
        assertGt(IMinter(minter).collateralRatio(), bounds[0], "precondition: the walk starts above the peg");
        assertLt(IMinter(minter).collateralRatio(), bounds[1], "precondition: and below the band's upper bound");

        uint256 snapshot = vm.snapshotState();
        uint256 pegged = _peggedToReach(1.35 ether);
        _redeemAndCheck(pegged, _expectedRedemption(pegged), bounds[1], bounds[2]); // one bound crossed
        vm.revertToState(snapshot);
        pegged = _peggedToReach(1.8 ether);
        _redeemAndCheck(pegged, _expectedRedemption(pegged), bounds[2], type(uint256).max); // two bounds crossed
    }

    /// @dev The pegged whose redemption at a pegged unit's worth takes the ratio to about `targetRatio`, by the ratio's
    ///      definition and leaving the incentives aside: (C p - x) / (P - x) = T, so x = (T P - C p) / (T - 1).
    function _peggedToReach(uint256 targetRatio) private view returns (uint256) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return
            (targetRatio * IMinter(minter).peggedTokenBalance() - IMinter(minter).collateralTokenBalance() * price) /
            (targetRatio - 1 ether);
    }

    /// @dev What a redemption of `pegged` moves, by the schedule. Walking up from the band at index 1, where the market
    ///      here starts, each band takes the pegged that brings the ratio to its upper bound and the last band the rest;
    ///      what the pegged redeemed so far is worth is priced once at a pegged unit's worth, and each slice's subsidy or
    ///      fee is exact on the collateral it takes. The redeemer is paid the collateral less the fee plus the subsidy,
    ///      rounded down once, within the whole wei released and sent; the reserve sends the subsidy's whole wei, and the
    ///      fee receiver the rest.
    function _expectedRedemption(uint256 pegged) private view returns (Outcome memory expected) {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 backingE36 = IMinter(minter).collateralTokenBalance() * 1 ether;
        RedeemWalk memory w = RedeemWalk(pegged * 1 ether, IMinter(minter).peggedTokenBalance() * 1 ether, 0, 0, 0, 0);
        for (uint256 band = 1; w.leftE36 > 0; band++) {
            uint256 inBandE36 = w.leftE36;
            if (band < config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds.length) {
                uint256 upperBound = config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[band];
                inBandE36 = Math.min(
                    inBandE36,
                    (upperBound * w.peggedHeldE36 - (backingE36 - w.collateralRedeemedE36) * price) /
                        (upperBound - 1 ether)
                );
            }
            w.leftE36 -= inBandE36;
            w.redeemedE36 += inBandE36;
            w.peggedHeldE36 -= inBandE36;
            uint256 sliceE36 = Math.mulDiv(w.redeemedE36, 1e36, price) / 1 ether - w.collateralRedeemedE36;
            w.collateralRedeemedE36 += sliceE36;
            int256 ratio = config.redeemPeggedIncentiveConfig.incentiveRatios[band];
            if (ratio < 0) {
                w.subsidyE54 += sliceE36 * uint256(-ratio);
            } else {
                w.feeE54 += sliceE36 * uint256(ratio);
            }
        }
        expected.subsidy = w.subsidyE54 / (rate * 1 ether);
        expected.paid = Math.min(
            (w.collateralRedeemedE36 * 1 ether - w.feeE54 + w.subsidyE54) / (rate * 1 ether),
            w.collateralRedeemedE36 / rate + expected.subsidy
        );
        expected.fee = w.collateralRedeemedE36 / rate + expected.subsidy - expected.paid;
    }

    /// @dev Redeems `pegged` and checks it ended between `lowerRatio` and `upperRatio` - the band the scenario aims for -
    ///      with the redeemer, the fee receiver and the reserve each moved by exactly what `expected` gives them.
    function _redeemAndCheck(uint256 pegged, Outcome memory expected, uint256 lowerRatio, uint256 upperRatio) private {
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(user);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);
        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, pegged);
        IMinter(minter).redeemPeggedToken(pegged, user, 0);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), lowerRatio, "the redemption ends in the band aimed for");
        assertLt(IMinter(minter).collateralRatio(), upperRatio, "the redemption ends in the band aimed for");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(user) - heldBefore,
            expected.paid,
            "the redeemer is paid each slice at its band"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            expected.fee,
            "the fee receiver is paid the fee"
        );
        assertEq(
            reserveBefore - IERC20(wrappedCollateralToken).balanceOf(reservePool),
            expected.subsidy,
            "the reserve sends the subsidy"
        );
    }
}

/// @notice The zero-fee pegged redemption - the rebalance's - pays the collateral leg a pegged unit's worth of
/// collateral for each pegged and converts the conversion leg into its value's share of the leveraged supply, with no
/// fee; it debits the record by the collateral leg alone, rounded up; it redeems no more than this minter minted, both
/// legs cut in proportion where they ask for more; and a leg that would hand back nothing reverts by name.
contract TestMinterFreeRedeemPegged is TestMinterSetUp {
    /// @dev A market at a ratio of two, at a price of 2000 and a rate of one, its pegged and leveraged held by the
    ///      zero-fee actor and its pegged approved to the minter: each leveraged token is worth a pegged unit.
    function setUp() public virtual override {
        super.setUp();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 100 ether); // a ratio of 2
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev What a zero-fee redemption of `peggedForCollateral` and `peggedForLeveraged` pays, by the definitions, at
    ///      the oracle's one price and a rate of one, the backing covering the pegged supply: for the collateral leg a
    ///      pegged unit's worth of collateral for each pegged; for the conversion leg its value's share of the
    ///      leveraged supply, the residual being what that supply is a claim on.
    function _expectedRedemption(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged
    ) private view returns (uint256 collateral, uint256 leveraged) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        collateral = Math.mulDiv(peggedForCollateral, 1 ether, price);
        leveraged = Math.mulDiv(
            peggedForLeveraged * 1 ether,
            IMinter(minter).leveragedTokenBalance(),
            IMinter(minter).collateralTokenBalance() * price - IMinter(minter).peggedTokenBalance() * 1 ether
        );
    }

    /// A redemption of more than this minter minted - the caller holding pegged minted elsewhere too - is capped at what
    /// it minted, both legs in proportion: the collateral leg rounded down and the conversion leg the rest, each paid
    /// as a redemption of its capped amount is, and the event reporting what was burned. The rest stays with the
    /// caller.
    function test_freeRedeemPegged_ofMoreThanThisMinterMinted_isCappedAtWhatItMinted() public {
        uint256 supply = IMinter(minter).peggedTokenBalance();
        _mintPegged(zeroFee, supply); // as much again, minted elsewhere
        uint256 heldBefore = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 forCollateral = (supply * 3) / 4;
        uint256 forLeveraged = supply / 2; // together a quarter more than this minter minted
        uint256 cappedForCollateral = Math.mulDiv(forCollateral, supply, forCollateral + forLeveraged);
        (uint256 expectedCollateral, uint256 expectedLeveraged) = _expectedRedemption(
            cappedForCollateral,
            supply - cappedForCollateral
        );

        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.RedeemPeggedToken(zeroFee, zeroFee, supply, expectedCollateral, expectedLeveraged);
        (uint256 collateralOut, uint256 leveragedOut) = IMinter(minter).freeRedeemPeggedToken(
            forCollateral,
            forLeveraged,
            zeroFee
        );
        vm.stopPrank();

        assertEq(collateralOut, expectedCollateral, "the collateral leg is paid for its capped amount");
        assertEq(leveragedOut, expectedLeveraged, "and the conversion leg for the rest of the supply");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "exactly what this minter minted is redeemed");
        assertEq(IERC20(peggedToken).balanceOf(zeroFee), heldBefore - supply, "the pegged minted elsewhere stays");
    }

    /// A single leg asked for above what this minter minted stays a single leg, capped at the supply: the collateral
    /// leg alone pays collateral for the whole supply and mints no leveraged, and the conversion leg alone converts the
    /// whole supply and pays no collateral.
    function test_freeRedeemPegged_ofOneLegAboveWhatThisMinterMinted_staysOneLeg() public {
        uint256 supply = IMinter(minter).peggedTokenBalance();
        _mintPegged(zeroFee, supply); // as much again, minted elsewhere
        (uint256 expectedCollateral, uint256 expectedLeveraged) = _expectedRedemption(supply, supply);
        uint256 snapshot = vm.snapshotState();

        vm.startPrank(zeroFee);
        (uint256 collateralOut, uint256 leveragedOut) = IMinter(minter).freeRedeemPeggedToken(2 * supply, 0, zeroFee);
        vm.stopPrank();
        assertEq(collateralOut, expectedCollateral, "the collateral leg alone pays for the whole supply");
        assertEq(leveragedOut, 0, "and mints no leveraged");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "the whole supply is redeemed");

        vm.revertToState(snapshot);
        vm.startPrank(zeroFee);
        (collateralOut, leveragedOut) = IMinter(minter).freeRedeemPeggedToken(0, 2 * supply, zeroFee);
        vm.stopPrank();
        assertEq(collateralOut, 0, "the conversion leg alone pays no collateral");
        assertEq(leveragedOut, expectedLeveraged, "and converts the whole supply");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "the whole supply is converted");
    }

    /// The dry run of a redemption of more than this minter minted reports the capped redemption the call makes.
    function test_freeRedeemDryRun_ofMoreThanThisMinterMinted_reportsTheCappedRedeem() public {
        uint256 supply = IMinter(minter).peggedTokenBalance();
        uint256 forCollateral = (supply * 3) / 4;
        uint256 forLeveraged = supply / 2; // together a quarter more than this minter minted
        uint256 cappedForCollateral = Math.mulDiv(forCollateral, supply, forCollateral + forLeveraged);
        (uint256 expectedCollateral, uint256 expectedLeveraged) = _expectedRedemption(
            cappedForCollateral,
            supply - cappedForCollateral
        );

        (uint256 collateralOut, uint256 leveragedOut) = IMinter_v3(minter).freeRedeemDryRun(
            forCollateral,
            forLeveraged
        );

        assertEq(collateralOut, expectedCollateral, "the collateral the capped collateral leg pays");
        assertEq(leveragedOut, expectedLeveraged, "the leveraged the capped conversion leg mints");
    }

    /// A conversion too small to mint a leveraged wei - a wei of pegged, where each leveraged token is worth two pegged
    /// units - reverts by name, and nothing is burned.
    function test_freeRedeemPegged_aConversionThatYieldsNothing_reverts() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(3000 ether, 1 ether); // the residual now 400,000
        (, uint256 previewed) = IMinter_v3(minter).freeRedeemDryRun(0, 1);
        assertEq(previewed, 0, "precondition: a wei of pegged converts to no leveraged");
        uint256 supplyBefore = IMinter(minter).peggedTokenBalance();

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).freeRedeemPeggedToken(0, 1, zeroFee);
        vm.stopPrank();

        assertEq(IMinter(minter).peggedTokenBalance(), supplyBefore, "nothing is burned");
    }

    /// The collateral leg debits the record by the collateral it pays out, rounded up from the exact figure - so the
    /// record never claims collateral the holding no longer has - and by no more: at a price of 3000 a thousand pegged
    /// is a third of a collateral token, a whole number of wei only once rounded.
    function test_freeRedeemPegged_debitsTheRecordByTheCeiledCollateral() public {
        uint256 price = 3000 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1 ether);
        uint256 pegged = 1000 ether;
        uint256 collateralE36 = Math.mulDiv(pegged, 1e36, price);
        assertGt(collateralE36 % 1 ether, 0, "precondition: the collateral is not a whole number of wei");
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();

        vm.startPrank(zeroFee);
        (uint256 paid, ) = IMinter(minter).freeRedeemPeggedToken(pegged, 0, zeroFee);
        vm.stopPrank();

        assertEq(paid, collateralE36 / 1 ether, "the redeemer is paid the collateral rounded down");
        assertEq(
            recordBefore - IMinter(minter).collateralTokenBalance(),
            Math.ceilDiv(collateralE36, 1 ether),
            "the record is debited it rounded up"
        );
    }

    /// A redemption of both legs reports their total burned, the collateral paid and the leveraged minted, and debits
    /// the record by the collateral leg alone: the converted pegged's collateral stays, now behind the leveraged.
    function test_freeRedeemPegged_withBothLegs_emitsTheTotalAndDebitsOnlyTheCollateralLeg() public {
        uint256 forCollateral = 1000 ether;
        uint256 forLeveraged = 3000 ether;
        (uint256 expectedCollateral, uint256 expectedLeveraged) = _expectedRedemption(forCollateral, forLeveraged);
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();
        uint256 leveragedBefore = IMinter(minter).leveragedTokenBalance();

        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.RedeemPeggedToken(
            zeroFee,
            zeroFee,
            forCollateral + forLeveraged,
            expectedCollateral,
            expectedLeveraged
        );
        IMinter(minter).freeRedeemPeggedToken(forCollateral, forLeveraged, zeroFee);
        vm.stopPrank();

        assertEq(
            recordBefore - IMinter(minter).collateralTokenBalance(),
            expectedCollateral,
            "the record gives up the collateral leg alone"
        );
        assertEq(peggedBefore - IMinter(minter).peggedTokenBalance(), forCollateral + forLeveraged, "both legs burn");
        assertEq(IMinter(minter).leveragedTokenBalance() - leveragedBefore, expectedLeveraged, "the leveraged minted");
    }
}
