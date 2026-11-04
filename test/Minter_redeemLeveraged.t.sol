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

import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract TestMinterRedeemLeveraged is TestMinterMint {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    //---------------------------------------------------------------------------------------------
    // Free Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    /// @dev Redeems `ownerLeveragedDecrease` of the zero-fee actor's leveraged by the zero-fee route and checks every
    ///      balance it moves. It expects each leveraged token to be worth a pegged unit and the wrapped-to-underlying
    ///      rate to be one, as they are in the markets this suite builds.
    function _freeRedeemLeveragedToken(uint256 ownerLeveragedDecrease) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 receiverCollateralIncrease = (ownerLeveragedDecrease * 1 ether) / price;

        uint256 minterLeveragedBefore = IMinter(minter).leveragedTokenBalance();
        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 ownerLeveragedBefore = IERC20(leveragedToken).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before freeRedeemLeveraged"
        );

        vm.startPrank(zeroFee);
        vm.expectEmit(minter);
        emit IMinter.RedeemLeveragedToken(zeroFee, receiver, ownerLeveragedDecrease, receiverCollateralIncrease);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(ownerLeveragedDecrease, receiver);
        //                 --------------------------------------------------------------------------
        vm.stopPrank();
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "free redeem leveraged doesn't change the leveraged price"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance after freeRedeemLeveraged"
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

        assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBefore - ownerLeveragedDecrease);
        assertEq(
            IERC20(leveragedToken).balanceOf(zeroFee),
            ownerLeveragedBefore - ownerLeveragedDecrease,
            "leveraged not burned"
        );

        assertGe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio >= before");
    }

    /// The zero-fee leveraged redemption: reverts for a caller without the zero-fee role; with no leveraged
    /// outstanding, or for an offer of nothing, it reverts as having nothing to redeem; and it reverts in the leveraged
    /// token for an offer the caller has not approved or does not hold. Served, it burns the offer and pays its
    /// collateral's worth with no fee, as its event reports, at an unchanged leveraged price.
    function test_freeRedeemLeveraged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "should have no minted leveraged tokens");

        // mint noaccess
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.startPrank(sender);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        vm.stopPrank();
        // 1 ----------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).freeRedeemLeveragedToken(0, receiver);
        vm.stopPrank();
        // 2 ------------------------------------------------

        // some input, when none
        assertEq(IERC20(leveragedToken).totalSupply(), 0);
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        vm.stopPrank();
        // 3 ----------------------------------------------------

        // some input, when none, but minter has some
        assertEq(IHarborOwnable(minter).owner(), owner());
        deal(address(Deployed.wstETH), zeroFee, 20 ether);
        vm.startPrank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        IMinter(minter).freeMintLeveragedToken(1 ether, sender); // not zeroFee
        vm.stopPrank();
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(IERC20(leveragedToken).allowance(zeroFee, minter), 0, "zeroFee has none allowed");
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 0, 1 ether));
        IMinter(minter).freeRedeemLeveragedToken(1 ether, receiver);
        vm.stopPrank();
        // 4 ------------------------------------------------------

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, 1 ether);
        vm.stopPrank();
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), 0, "zeroFee has none");
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, zeroFee, 0, 1 ether));
        IMinter(minter).freeRedeemLeveragedToken(1 ether, receiver);
        vm.stopPrank();
        // 5 ------------------------------------------------------

        uint256 leveragedTotalSupplyBefore = IERC20(leveragedToken).totalSupply();
        uint256 leveragedBalanceOfOwnerBefore = IERC20(leveragedToken).balanceOf(zeroFee);

        uint256 mintedLeveraged = price;
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
        //++++++++++++++++++++++++++++++++++++++++++++++++++++

        assertEq(
            leveragedTotalSupplyBefore + mintedLeveraged,
            IERC20(leveragedToken).totalSupply(),
            "total supply correct after mint"
        );
        assertEq(
            leveragedBalanceOfOwnerBefore + mintedLeveraged,
            IERC20(leveragedToken).balanceOf(zeroFee),
            "zeroFee owns correct after mint"
        );
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged);

        // zero input, when some
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).freeRedeemLeveragedToken(0, receiver);
        vm.stopPrank();
        // 6 ------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged, "nothing redeemed");

        vm.startPrank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
        //+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), mintedLeveraged + price, "minted more 1:price");

        // a collateral token's worth of the supply, redeemed for exactly a collateral token
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0, "receiver has none");
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 2 * price);
        vm.startPrank(zeroFee);
        vm.expectEmit(minter);
        emit IMinter.RedeemLeveragedToken(zeroFee, receiver, price, 1 ether);
        IMinter(minter).freeRedeemLeveragedToken(price, receiver);
        vm.stopPrank();
        // 7 -----------------------------------------------------------------
        assertEq(IMinter(minter).leveragedTokenBalance(), mintedLeveraged + 1 * price);
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), 1 ether);

        // first normal redeem
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(6 ether, zeroFee);
        vm.stopPrank();
        //++++++++++++++++++++++++++++++++++++++++++++++++++++++

        _freeRedeemLeveragedToken(price);
        // 8 ---------------------------

        // more than one redeem
        _freeRedeemLeveragedToken(2 * price);
        // 9 ------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Redeem Leveraged
    //---------------------------------------------------------------------------------------------

    /// @dev Redeems `leveragedIn` of the sender's leveraged by the retail route - the sentinel passed on as given, for
    ///      the minter to read as the sender's whole balance - and checks every balance it moves against the dry run of
    ///      the amount, and that it leaves the reserve as it was. The record is expected to fall by exactly the wrapped
    ///      that leaves, which holds at the wrapped-to-underlying rate of one, and for the whole-wei claims, of the
    ///      markets this suite builds.
    function _redeemLeveragedToken(uint256 leveragedIn) private {
        uint256 senderLeveragedDecrease;
        if (leveragedIn == type(uint256).max) {
            senderLeveragedDecrease = IERC20(leveragedToken).balanceOf(sender);
        } else {
            senderLeveragedDecrease = leveragedIn;
        }

        vm.startPrank(sender);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        (, uint256 redeemLeveragedFee, , uint256 receiverCollateralIncrease, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(senderLeveragedDecrease);

        uint256 feeReceiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        // the leveraged supply, which the minter's leveragedTokenBalance() reports
        uint256 leveragedSupplyBefore = IERC20(leveragedToken).totalSupply();
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterCollateralBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();
        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
        uint256 reserveBefore = IERC20(Deployed.wstETH).balanceOf(reservePool);

        vm.startPrank(sender);
        vm.expectEmit(minter);
        emit IMinter.RedeemLeveragedToken(sender, receiver, senderLeveragedDecrease, receiverCollateralIncrease);
        uint256 returned = IMinter(minter).redeemLeveragedToken(leveragedIn, receiver, 0);
        //                 ------------------------------------------------------------
        vm.stopPrank();
        assertEq(leveragedPrice, IMinter(minter).leveragedTokenPrice(), "leveraged price doesn't change");
        assertEq(returned, receiverCollateralIncrease, "unexpected amount returned compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            feeReceiverCollateralBefore + redeemLeveragedFee,
            "fee transferred"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(sender),
            senderLeveragedBefore - senderLeveragedDecrease,
            "token sent"
        );
        assertEq(IERC20(leveragedToken).totalSupply(), leveragedSupplyBefore - senderLeveragedDecrease, "token burned");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + receiverCollateralIncrease,
            "collateral returned"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBalanceBefore - receiverCollateralIncrease - redeemLeveragedFee,
            "minter is tracking the collateral"
        );
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            leveragedSupplyBefore - senderLeveragedDecrease,
            "minter is tracking the leveraged tokens"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            minterCollateralBefore - receiverCollateralIncrease - redeemLeveragedFee,
            "wstETH has minter owning it"
        );
        assertLt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio < before");
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), reserveBefore, "the reserve is left as it was");
    }

    struct DryRunResults {
        int256 incentiveRatio;
        uint256 wrappedFee;
        uint256 leveragedRedeemed;
        uint256 wrappedCollateralReturned;
        uint256 price;
        uint256 rate;
    }

    function _testRedeemLeveragedDryRun(uint256 collateralIn, DryRunResults memory expected, address sender_) internal {
        DryRunResults memory r;
        vm.startPrank(sender_);
        (r.incentiveRatio, r.wrappedFee, r.leveragedRedeemed, r.wrappedCollateralReturned, r.price, r.rate) = IMinter(
            minter
        ).redeemLeveragedTokenDryRun(collateralIn);
        vm.stopPrank();
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.leveragedRedeemed, expected.leveragedRedeemed, "leveragedRedeemed");
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
                leveragedRedeemed: 0,
                wrappedCollateralReturned: 0,
                price: price_,
                rate: rate_
            });
    }

    /// The retail leveraged redemption: an offer of nothing, or the sentinel from an empty balance, reverts by name;
    /// with no leveraged outstanding there is nothing to redeem; inside the disallowed band it returns nothing and
    /// reverts; and above it the leveraged token reverts an offer the minter is not approved for. Served, it charges
    /// the band's fee exactly, as its dry run forecasts; a minimum the payout does not meet reverts naming both,
    /// before anything is burned; and the sentinel redeems the caller's whole balance.
    function test_redeemLeveragedBasic() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        int256 disallowed = config.redeemLeveragedIncentiveConfig.incentiveRatios[0];
        int256 feeRatio = ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(leveragedToken).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        vm.stopPrank();
        // 1 --------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 2 ----------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when no leveraged tokens
        assertEq(IERC20(leveragedToken).totalSupply(), 0);
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 3 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // collateral ratio 1.0
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 4 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 5 ------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get allowance
        vm.startPrank(sender);
        IERC20(leveragedToken).approve(minter, 10 ether);
        vm.stopPrank();

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        vm.stopPrank();
        // 6 ----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // disallowed
        setUp_collateral(11 ether, 1 ether, sender); // a ratio of 13/12
        assertLt(
            IMinter(minter).collateralRatio(),
            config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0],
            "should be in the disallowed band"
        );

        expected = zeros();
        expected.incentiveRatio = disallowed;
        _testRedeemLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, Deployed.wstETH));
        IMinter(minter).redeemLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 7 ----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // first normal redeem
        setUp_collateral(0, 5 ether, sender); // sender has 6 now
        setUp_collateral(10 ether, 100 ether); // make a nice collateral ratio
        assertGt(
            IMinter(minter).collateralRatio(),
            ultimate(config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            "should be in the fee band"
        );

        expected = zeros();
        expected.incentiveRatio = feeRatio;
        _testRedeemLeveragedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(0, receiver, 0);
        vm.stopPrank();
        // 8 -----------------------------------------------

        assertEq(IERC20(leveragedToken).allowance(sender, minter), 10 ether, "minter has no allowance");

        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = (1 ether * uint256(feeRatio)) / 1 ether;
        expected.leveragedRedeemed = 1 * price;
        expected.wrappedCollateralReturned = 1 ether - expected.wrappedFee;
        _testRedeemLeveragedDryRun(1 * price, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, minter, 10 ether, 1 * price)
        );
        IMinter(minter).redeemLeveragedToken(1 * price, receiver, 0);
        vm.stopPrank();
        // 9 -------------------------------------------------------

        vm.startPrank(sender);
        IERC20(leveragedToken).approve(minter, 20 * price);
        vm.stopPrank();

        _testRedeemLeveragedDryRun(1 * price, expected, sender);

        assertEq(IERC20(leveragedToken).balanceOf(sender), 6 * price, "sender has 6");
        vm.startPrank(sender);
        IMinter(minter).redeemLeveragedToken(1 * price, receiver, 0);
        vm.stopPrank();
        // 10 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender has 5");

        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = (6 ether * uint256(feeRatio)) / 1 ether;
        expected.leveragedRedeemed = 6 * price;
        expected.wrappedCollateralReturned = 6 ether - expected.wrappedFee;

        _testRedeemLeveragedDryRun(6 * price, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                expected.wrappedCollateralReturned,
                6 ether
            )
        );
        IMinter(minter).redeemLeveragedToken(6 * price, receiver, 6 ether);
        vm.stopPrank();
        // 11 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender still has 5");

        expected = zeros();
        expected.incentiveRatio = feeRatio;
        expected.wrappedFee = (5 ether * uint256(feeRatio)) / 1 ether;
        expected.leveragedRedeemed = 5 * price;
        expected.wrappedCollateralReturned = 5 ether - expected.wrappedFee;
        _testRedeemLeveragedDryRun(5 * price, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.ReturnInsufficientAmount.selector,
                Deployed.wstETH,
                expected.wrappedCollateralReturned,
                5 ether
            )
        );
        IMinter(minter).redeemLeveragedToken(5 * price, receiver, 5 ether);
        vm.stopPrank();
        // 12 -------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 5 * price, "sender still has 5");

        // the sentinel: the dry run prices the caller's whole balance, and the call redeems it
        _testRedeemLeveragedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        IMinter(minter).redeemLeveragedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 13 --------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(sender), 0, "sender has 0");

        // zero fee has the rest
        assertEq(
            IERC20(leveragedToken).totalSupply(),
            IERC20(leveragedToken).balanceOf(zeroFee),
            "zeroFee has the rest"
        );
    }

    /// A retail leveraged redemption from a collateral ratio of two charges the top band's fee and pays the rest, as
    /// its event reports, leaving a funded reserve as it was; a minimum the payout meets is served, one a wei above it
    /// reverts naming both, and the sentinel redeems the caller's whole balance for exactly its dry run's forecast.
    function test_redeemLeveragedNormal() public {
        setUp_collateral(20 ether, 0);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        setUp_collateral(0, 10 ether, sender);
        deal(address(Deployed.wstETH), reservePool, 100 ether); // a reserve that could fund a subsidy
        // first redeem
        _redeemLeveragedToken(price);
        // 1 --------------------

        // second redeem
        _redeemLeveragedToken(2 * price);
        // 2 ------------------------

        // check the minimum out
        uint256 collateral = 3 ether;
        uint256 leveraged = (collateral * price) / 1 ether;

        (, uint256 redeemLeveragedFee, , uint256 expectedCollateralOut, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(leveraged);
        assertEq(
            redeemLeveragedFee,
            (collateral * uint256(ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios))) / 1 ether,
            "fee correct"
        );
        assertEq(expectedCollateralOut, collateral - redeemLeveragedFee, "collateral out correct");

        deal(address(leveragedToken), sender, leveraged * 2);
        vm.startPrank(sender);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        deal(address(Deployed.wstETH), sender, collateral * 10);

        uint256 senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);

        // just within
        vm.startPrank(sender);
        IMinter(minter).redeemLeveragedToken(leveraged, receiver, expectedCollateralOut);
        vm.stopPrank();
        // 3 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore + expectedCollateralOut);

        assertEq(IERC20(leveragedToken).balanceOf(sender), senderLeveragedBefore - leveraged);

        senderLeveragedBefore = IERC20(leveragedToken).balanceOf(sender);
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
        IMinter(minter).redeemLeveragedToken(leveraged, receiver, expectedCollateralOut + 1);
        vm.stopPrank();
        // 4 ------------------------------------------------------------------------------
        assertEq(IERC20(Deployed.wstETH).balanceOf(receiver), receiverCollateralBefore);
        assertEq(IERC20(leveragedToken).balanceOf(sender), senderLeveragedBefore);

        // redeem all of the balance
        (, redeemLeveragedFee, , expectedCollateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(
            senderLeveragedBefore
        );

        _redeemLeveragedToken(type(uint256).max);
        // 5 --------------------------------
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            receiverCollateralBefore + expectedCollateralOut,
            "out correct"
        );
        assertEq(IERC20(leveragedToken).balanceOf(sender), 0, "transferred it all");
    }
}

/// @notice A leveraged redemption never pays more than the exact formula: the leveraged's share of the collateral
/// above what the pegged supply is worth, converted at the rate, less the fee. Every rounding on the way goes the
/// protocol's way.
contract TestMinterRedeemLeveragedExact is TestMinterSetUp {
    address user;

    /// @dev Redeeming leveraged is disallowed below the peg and charges 0.5% in every band above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 110, 120, 130, 140, 150, 160), ia(disallow, 50, 50, 50, 50, 50, 50, 50))
        );
    }

    /// Never more than the exact formula, across rates, ratios from just above the peg to far above it, and amounts up
    /// to the whole balance.
    function testFuzz_redeemLeveraged_neverPaysMoreThanTheExactFormula(
        uint256 leveragedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 0.7 ether, 100 ether); // the ratio from 1.05 to 150
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, rate);
        setUp_collateral(100 ether, 50 ether, user); // a ratio of 1.5
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        leveragedIn = bound(leveragedIn, 1e9, IERC20(leveragedToken).balanceOf(user));
        uint256 exact = Math.mulDiv(
            IMinter(minter).collateralTokenBalance() * price - IMinter(minter).peggedTokenBalance() * 1 ether,
            leveragedIn * uint256(1 ether - config.redeemLeveragedIncentiveConfig.incentiveRatios[1]),
            price * IMinter(minter).leveragedTokenBalance() * rate
        );

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        uint256 paid = IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
        vm.stopPrank();

        assertLe(paid, exact, "no more than the exact formula pays");
    }
}

/// @notice A leveraged redemption pays the redeemer the collateral the leveraged is worth less the fee, rounded down
/// once from the exact figure; the fee receiver absorbs the remainder.
contract TestMinterRedeemLeveragedRoundedOnce is TestMinterSetUp {
    address user;

    /// @dev Redeeming leveraged is disallowed below the peg, charges 1.2% up to a ratio of 1.5 and 0.7% above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 150), ia(disallow, 120, 70))
        );
    }

    /// From a ratio of 1.8 a redemption pays 0.7% down to 1.5 and 1.2% past it, staying above the peg. Each slice is
    /// cut where the ratio reaches its band's lower bound - the collateral there rounded up, so the cheaper slice is
    /// never overstated - the fee is exact, and the redeemer is paid the collateral less the fee, rounded down once.
    function testFuzz_redeemLeveraged_acrossTwoFees_paysTheExactNetRoundedOnce(
        uint256 leveragedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        uint256 supply = IMinter(minter).leveragedTokenBalance();
        // 45% to 85% of the residual: past 1.5 (37.5% of it) and short of the peg
        leveragedIn = bound(leveragedIn, (supply * 45) / 100, (supply * 85) / 100);

        uint256 expected;
        {
            uint256 backing = IMinter(minter).collateralTokenBalance();
            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            // the collateral the leveraged is a claim on: its share of the residual
            uint256 redeemedForE36 = Math.mulDiv(
                backing * price - peggedSupply * 1 ether,
                leveragedIn * 1 ether,
                price * supply
            );
            // the collateral that brings the ratio down to 1.5, its lower-bound collateral rounded up
            uint256 aboveE36 = backing * 1 ether -
                Math.mulDiv(
                    config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1] * 1 ether,
                    peggedSupply,
                    price,
                    Math.Rounding.Ceil
                );
            uint256 feeE54 = aboveE36 * uint256(config.redeemLeveragedIncentiveConfig.incentiveRatios[2]) +
                (redeemedForE36 - aboveE36) * uint256(config.redeemLeveragedIncentiveConfig.incentiveRatios[1]);
            expected = (redeemedForE36 * 1 ether - feeE54) / (rate * 1 ether);
        }

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        uint256 paid = IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
        vm.stopPrank();

        assertEq(paid, expected, "the collateral less the fee, rounded down once");
    }
}

/// @notice A leveraged redemption that reaches a band where redeeming is disallowed fills only to that band's bound: it
/// burns the leveraged whose claim is the collateral above the bound, and the caller keeps the rest of the offer.
contract TestMinterRedeemLeveragedIntoADisallow is TestMinterSetUp {
    address user;

    /// @dev Redeeming leveraged is disallowed below a ratio of 1.3, and charges 1.2% from 1.3 to 1.5 and 0.7% above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(130, 150), ia(disallow, 120, 70))
        );
    }

    /// From a ratio of 1.8 an offer of the whole supply would take the ratio to the peg. The redemption burns only the
    /// leveraged that brings it to 1.3 - the share of the supply that the collateral above the bound is of the collateral
    /// above the peg - and the caller keeps the rest; the event and the dry run report the partial fill, and the ratio
    /// ends on the bound.
    function test_redeemLeveraged_intoTheDisallowBand_fillsToTheBoundary() public {
        uint256 price = 2000 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1 ether);
        user = makeAddr("user");
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        uint256 offer = IERC20(leveragedToken).balanceOf(user);
        assertEq(offer, IMinter(minter).leveragedTokenBalance(), "precondition: the offer is the whole supply");
        uint256 disallowedBelow = config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0];
        uint256 expectedBurned;
        {
            uint256 collateralValue = IMinter(minter).collateralTokenBalance() * price;
            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            expectedBurned = Math.mulDiv(
                offer,
                collateralValue - disallowedBelow * peggedSupply,
                collateralValue - 1 ether * peggedSupply
            );
        }
        (, , uint256 dryRunBurned, uint256 dryRunPaid, , ) = IMinter(minter).redeemLeveragedTokenDryRun(offer);
        assertEq(dryRunBurned, expectedBurned, "the dry run burns the share above the bound");
        assertLt(dryRunBurned, offer, "precondition: the offer is more than the band can take");

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, offer);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.RedeemLeveragedToken(user, user, dryRunBurned, dryRunPaid);
        uint256 paid = IMinter(minter).redeemLeveragedToken(offer, user, 0);
        vm.stopPrank();

        assertEq(paid, dryRunPaid, "paid what the dry run reports");
        assertEq(IERC20(leveragedToken).balanceOf(user), offer - dryRunBurned, "the caller keeps the rest");
        assertEq(IMinter(minter).collateralRatio(), disallowedBelow, "the ratio ends on the bound");
    }

    /// A partial fill never burns fewer leveraged than the collateral it removes is the claim of - that collateral's
    /// share of the residual, of the supply, rounded up - and at most a wei more, across rates, prices and offers from
    /// just past the fill to the whole supply.
    function testFuzz_redeemLeveraged_partialFillBurnsAtLeastTheShareRedeemed(
        uint256 leveragedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        user = makeAddr("user");
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        uint256 supply = IMinter(minter).leveragedTokenBalance();
        // 63% to all of the supply: past the 62.5% whose claim is the collateral above 1.3
        leveragedIn = bound(leveragedIn, (supply * 63) / 100, supply);

        uint256 share;
        {
            uint256 backing = IMinter(minter).collateralTokenBalance();
            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            // the collateral above the bound, the collateral at the bound rounded up
            uint256 aboveE36 = backing * 1 ether -
                Math.mulDiv(
                    config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0] * 1 ether,
                    peggedSupply,
                    price,
                    Math.Rounding.Ceil
                );
            share = Math.mulDiv(
                aboveE36,
                price * supply,
                (backing * price - peggedSupply * 1 ether) * 1 ether,
                Math.Rounding.Ceil
            );
        }

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
        vm.stopPrank();

        uint256 burned = supply - IMinter(minter).leveragedTokenBalance();
        assertLt(burned, leveragedIn, "precondition: the offer is more than the band can take");
        assertGe(burned, share, "never fewer than the collateral removed is the claim of");
        // The burn is the offer's part in proportion to the collateral removed out of the offer's own claim, and that
        // claim is rounded down, by under 1e-36 of a collateral unit: enough to carry the burn past a whole token wei,
        // by one at most.
        assertLe(burned, share + 1, "and at most a wei more");
    }
}

/// @notice The zero-fee leveraged redemption pays the leveraged's share of the residual with no fee, and reverts by name
/// where it would pay nothing, as the fee-paying redemption does: for an offer whose payout rounds to nothing, and at
/// the peg or below it, where the leveraged has no residual to claim.
contract TestMinterFreeRedeemLeveraged is TestMinterSetUp {
    /// @dev A market at a ratio of two, at a price of 2000 and a rate of one, its leveraged held by the zero-fee actor
    ///      and approved to the minter: each leveraged token is worth a pegged unit.
    function setUp() public virtual override {
        super.setUp();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 100 ether); // a ratio of 2
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Expects the zero-fee redemption of `leveragedIn` to revert as paying nothing, leaving the leveraged supply
    ///      and the record as they were.
    function _expectNothingRedeemed(uint256 leveragedIn) private {
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).freeRedeemLeveragedToken(leveragedIn, zeroFee);
        vm.stopPrank();

        assertEq(IMinter(minter).leveragedTokenBalance(), supplyBefore, "nothing is burned");
        assertEq(IMinter(minter).collateralTokenBalance(), recordBefore, "and the record is unchanged");
    }

    /// An offer whose payout rounds to nothing - a wei of leveraged, worth a two-thousandth of a collateral wei -
    /// reverts by name: nothing is burned, and the record is not debited.
    function test_freeRedeemLeveraged_aPayoutThatRoundsToNothing_reverts() public {
        _expectNothingRedeemed(1);
    }

    /// At the peg and below it the leveraged has no residual to claim, so the zero-fee redemption reverts by name and
    /// nothing is burned.
    function test_freeRedeemLeveraged_withNoResidual_reverts() public {
        uint256 offer = IERC20(leveragedToken).balanceOf(zeroFee) / 2;
        uint256[2] memory prices = [uint256(1000 ether), 900 ether]; // a ratio of exactly one, and of 0.9
        for (uint256 i = 0; i < prices.length; i++) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(prices[i], 1 ether);
            assertLe(IMinter(minter).collateralRatio(), 1 ether, "precondition: at the peg or below it");
            _expectNothingRedeemed(offer);
        }
    }

    /// The zero-fee leveraged redemption pays the offer its share of the residual - the backing's worth above the
    /// pegged supply's, over the leveraged supply - converted at the rate and rounded down once, with no fee, at any
    /// price above the peg and any rate at or above the one the record was written at: it burns the offer, the minter's
    /// holding falls by exactly the payout, and the record gives up the share rounded up.
    function testFuzz_freeRedeemLeveraged_paysTheOffersShareOfTheResidual_atAnyPriceAndRate(
        uint256 offer,
        uint256 price,
        uint256 rate
    ) public {
        price = bound(price, 1100 ether, 100_000 ether); // a ratio from 1.1 to 100
        rate = bound(rate, 1 ether, 5 ether); // from the rate of one the record was written at
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        uint256 supply = IMinter(minter).leveragedTokenBalance();
        offer = bound(offer, 1 ether, IERC20(leveragedToken).balanceOf(zeroFee));
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        // the offer's share of the residual, in collateral, at 1e36
        uint256 claimE36 = Math.mulDiv(
            offer * 1 ether,
            recordBefore * price - IMinter(minter).peggedTokenBalance() * 1 ether,
            price * supply
        );
        uint256 expectedPaid = claimE36 / rate;
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(zeroFee);
        uint256 holdingBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        vm.startPrank(zeroFee);
        uint256 paid = IMinter(minter).freeRedeemLeveragedToken(offer, zeroFee);
        vm.stopPrank();

        assertEq(paid, expectedPaid, "the offer's share of the residual, at the rate, rounded down once");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(zeroFee) - heldBefore, expectedPaid, "paid to the redeemer");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), feeBefore, "with no fee");
        assertEq(IMinter(minter).leveragedTokenBalance(), supply - offer, "the offer is burned");
        assertEq(
            holdingBefore - IERC20(wrappedCollateralToken).balanceOf(minter),
            expectedPaid,
            "the minter's holding falls by the payout"
        );
        assertEq(
            recordBefore - IMinter(minter).collateralTokenBalance(),
            Math.ceilDiv(claimE36, 1 ether),
            "the record gives up the share, rounded up"
        );
    }
}

/// @notice A leveraged redemption walks down through the bands it crosses, each slice charged at its own band's rate; it
/// is served wherever the leveraged has value - below the min CR as above it - and reverts at the peg and below it,
/// whatever the incentive config says there, and wherever it would pay nothing, whatever minimum the caller set.
contract TestMinterRedeemLeveragedAcrossBands is TestMinterSetUp {
    address user;

    /// @dev What a redemption moves: what the redeemer is paid and what the fee receiver is paid.
    struct Outcome {
        uint256 paid;
        uint256 fee;
    }

    /// @dev Redeeming leveraged charges 1.5% from the peg to 1.3, 1% from 1.3 to 1.6 and 0.6% above it. Below the peg
    ///      the band is a fee too, of 2%: no band disallows.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 130, 160), ia(200, 150, 100, 60))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
    }

    /// At the peg and below it the leveraged is a claim on nothing: a redemption reverts and its dry run reports
    /// nothing, though the incentive config's band there charges a fee and does not disallow.
    function test_redeemLeveraged_atThePegAndBelow_revertsWhateverTheIncentiveConfig() public {
        uint256 rate = 1 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, rate);
        setUp_collateral(100 ether, 100 ether, user); // a ratio of 2
        assertLt(
            config.redeemLeveragedIncentiveConfig.incentiveRatios[0],
            1 ether,
            "precondition: the band below the peg charges a fee, it does not disallow"
        );
        uint256 offer = IERC20(leveragedToken).balanceOf(user);
        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, offer);
        vm.stopPrank();

        uint256[2] memory prices = [uint256(1000 ether), 900 ether]; // a ratio of exactly one, and of 0.9
        for (uint256 i = 0; i < prices.length; i++) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(prices[i], rate);
            assertLe(IMinter(minter).collateralRatio(), 1 ether, "precondition: at the peg or below it");
            (, uint256 dryRunFee, uint256 dryRunBurned, uint256 dryRunPaid, , ) = IMinter(minter)
                .redeemLeveragedTokenDryRun(offer);
            assertEq(dryRunBurned, 0, "the dry run burns nothing");
            assertEq(dryRunPaid, 0, "pays nothing");
            assertEq(dryRunFee, 0, "and charges nothing");

            vm.startPrank(user);
            vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
            IMinter(minter).redeemLeveragedToken(offer, user, 0);
            vm.stopPrank();
        }
    }

    /// An offer whose claim on the residual rounds to nothing redeems nothing: the redemption reverts by name and its
    /// dry run reports nothing - here a wei of price above the peg, where the whole residual is a fraction of a
    /// collateral wei.
    function test_redeemLeveraged_anOfferWhoseClaimRoundsToNothing_reverts() public {
        uint256 rate = 1 ether;
        uint256 price = 1000 ether + 1;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, rate);
        setUp_collateral(100 ether, 100 ether, user); // a ratio of 2
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        uint256 offer = 1e5;
        uint256 residualE36 = IMinter(minter).collateralTokenBalance() * price -
            IMinter(minter).peggedTokenBalance() * 1 ether;
        assertGt(residualE36, 0, "precondition: above the peg, so the leveraged has a claim");
        assertEq(
            Math.mulDiv(residualE36, offer * 1 ether, price * IMinter(minter).leveragedTokenBalance()),
            0,
            "precondition: the offer's claim is under 1e-36 of a collateral unit"
        );

        (, uint256 dryRunFee, uint256 dryRunBurned, uint256 dryRunPaid, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(offer);
        assertEq(dryRunBurned, 0, "the dry run burns nothing");
        assertEq(dryRunPaid, 0, "pays nothing");
        assertEq(dryRunFee, 0, "and charges nothing");

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, offer);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(offer, user, 0);
        vm.stopPrank();
    }

    /// An offer whose payout rounds to nothing redeems nothing, and its dry run says what the call does: nothing
    /// burned, nothing charged, nothing paid, at the band's ratio - here a collateral wei's worth of leveraged, which
    /// the fee, rounded the protocol's way, would take whole.
    function test_redeemLeveragedDryRun_forAnOfferThatPaysNothing_reportsNothingRedeemed() public {
        uint256 price = 2000 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1 ether);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        uint256 offer = price / 1 ether; // each leveraged token is worth a pegged unit here

        (int256 ratio, uint256 fee, uint256 burned, uint256 paid, , ) = IMinter(minter).redeemLeveragedTokenDryRun(
            offer
        );
        assertEq(burned, 0, "the dry run burns nothing");
        assertEq(paid, 0, "pays nothing");
        assertEq(fee, 0, "charges nothing");
        assertEq(
            ratio,
            ultimate(config.redeemLeveragedIncentiveConfig.incentiveRatios),
            "and reports the ratio of the band the market is in"
        );

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, offer);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(offer, user, 0);
        vm.stopPrank();
    }

    /// A redemption that pays nothing reverts as paying nothing, whatever minimum the caller set: a wei of leveraged,
    /// worth a two-thousandth of a collateral wei, with a minimum of one.
    function test_redeemLeveraged_aPayoutOfNothingWithAMinimumSet_revertsAsReturningNothing() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8
        (, , , uint256 dryRunPaid, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1);
        assertEq(dryRunPaid, 0, "precondition: a wei of leveraged pays nothing");

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, 1);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(1, user, 1);
        vm.stopPrank();
    }

    /// Between the peg and the min CR no leveraged is minted, but the leveraged outstanding still has value and a
    /// redemption is served: it pays its share of the residual less its band's fee, rounded down once.
    function test_redeemLeveraged_belowTheMinimumCollateralRatio_isServed() public {
        uint256 rate = 1 ether;
        uint256 price = 1005 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, rate);
        setUp_collateral(100 ether, 100 ether, user); // a ratio of 2
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate); // a ratio of 1.005
        assertGt(IMinter(minter).collateralRatio(), 1 ether, "precondition: above the peg");
        assertFalse(
            IMinter_v3(minter).leveragedMintable(),
            "precondition: below the min CR, so no leveraged is minted"
        );
        uint256 leveragedIn = IERC20(leveragedToken).balanceOf(user) / 2;
        uint256 claimE36 = Math.mulDiv(
            IMinter(minter).collateralTokenBalance() * price - IMinter(minter).peggedTokenBalance() * 1 ether,
            leveragedIn * 1 ether,
            price * IMinter(minter).leveragedTokenBalance()
        );
        uint256 expectedPaid = (claimE36 *
            uint256(1 ether - config.redeemLeveragedIncentiveConfig.incentiveRatios[1])) / (rate * 1 ether);
        assertGt(expectedPaid, 0, "precondition: the share is worth something");

        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        uint256 paid = IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
        vm.stopPrank();

        assertEq(paid, expectedPaid, "the share of the residual less the band's fee");
    }

    /// A leveraged redemption is charged the rate of the band the market is in, and here the bands charge more as the
    /// ratio falls: a collateral token's worth of leveraged pays 0.6% at a ratio of 1.8, 1% at 1.45 and 1.5% at 1.15.
    function test_redeemLeveraged_costsMoreAsTheCollateralRatioFalls() public {
        uint256 price = 2000 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1 ether);
        uint256 collateral = 1 ether;
        // the collateral behind the leveraged for ratios of 1.8, 1.45 and 1.15, which sit in bands 3, 2 and 1
        uint256[3] memory collateralForLeveraged = [uint256(80 ether), 45 ether, 15 ether];
        uint256 feeAtTheRatioAbove = 0;
        uint256 snapshot = vm.snapshotState();
        for (uint256 i = 0; i < collateralForLeveraged.length; i++) {
            vm.revertToState(snapshot);
            setUp_collateral(100 ether, collateralForLeveraged[i], user);
            uint256 expectedFee = (collateral *
                uint256(config.redeemLeveragedIncentiveConfig.incentiveRatios[collateralForLeveraged.length - i])) /
                1 ether;
            uint256 leveragedIn = (collateral * price) / 1 ether; // each leveraged token is worth a pegged unit here

            vm.startPrank(user);
            IERC20(leveragedToken).approve(minter, leveragedIn);
            uint256 paid = IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
            vm.stopPrank();

            assertEq(paid, collateral - expectedFee, "the redeemer is paid the collateral less the band's fee");
            assertEq(
                IERC20(wrappedCollateralToken).balanceOf(feeReceiver),
                expectedFee,
                "the fee receiver is paid the band's fee"
            );
            assertGt(expectedFee, feeAtTheRatioAbove, "a lower ratio costs more");
            feeAtTheRatioAbove = expectedFee;
        }
    }

    /// From a ratio of 1.8 a redemption to about 1.45 crosses one bound and one to about 1.15 crosses two. The collateral
    /// the leveraged is a claim on is split where the ratio reaches each band's lower bound, each slice's fee exact on
    /// its collateral; the redeemer and the fee receiver are each paid exactly their part.
    function test_redeemLeveraged_acrossOneAndTwoBandBounds_chargesEachSliceAtItsBandsRate(
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8, in the top band
        uint256[] memory bounds = config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds;

        uint256 snapshot = vm.snapshotState();
        uint256 leveragedIn = _leveragedToReach(1.45 ether);
        _redeemAndCheck(leveragedIn, _expectedRedemption(leveragedIn), bounds[1], bounds[2]); // one bound crossed
        vm.revertToState(snapshot);
        leveragedIn = _leveragedToReach(1.15 ether);
        _redeemAndCheck(leveragedIn, _expectedRedemption(leveragedIn), bounds[0], bounds[1]); // two bounds crossed
    }

    /// An offer above the leveraged supply redeems exactly the supply, however large - here the largest short of the
    /// whole-balance sentinel: the holder of all of it burns the supply and is paid as a redemption of exactly the
    /// supply - its claim on the whole residual, walked down through every band to the peg, less each slice's fee - and
    /// the dry run of the offer reports the same.
    function test_redeemLeveraged_anOfferAboveTheSupply_redeemsExactlyTheSupply() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether, user); // a ratio of 1.8, the user holding the whole leveraged supply
        uint256 supply = IMinter(minter).leveragedTokenBalance();
        assertEq(IERC20(leveragedToken).balanceOf(user), supply, "precondition: the user holds the whole supply");
        Outcome memory expected = _expectedRedemption(supply);
        uint256 offer = type(uint256).max - 1;

        (, uint256 dryRunFee, uint256 dryRunBurned, uint256 dryRunPaid, , ) = IMinter(minter)
            .redeemLeveragedTokenDryRun(offer);
        assertEq(dryRunBurned, supply, "the dry run burns exactly the supply");
        assertEq(dryRunPaid, expected.paid, "pays a redemption of exactly the supply");
        assertEq(dryRunFee, expected.fee, "and charges its fee");

        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, offer);
        uint256 paid = IMinter(minter).redeemLeveragedToken(offer, user, 0);
        vm.stopPrank();

        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "exactly the supply is burned");
        assertEq(paid, expected.paid, "the redeemer is paid a redemption of exactly the supply");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            expected.fee,
            "the fee receiver is paid its fee"
        );
    }

    /// @dev The leveraged whose redemption takes the ratio to about `targetRatio`, by the ratio's definition: the share
    ///      of the supply that the collateral above the target is of the collateral above the peg. The fee comes out of
    ///      the collateral returned, so the backing falls by the whole claim.
    function _leveragedToReach(uint256 targetRatio) private view returns (uint256) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 collateralValue = IMinter(minter).collateralTokenBalance() * price;
        uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
        return
            Math.mulDiv(
                IMinter(minter).leveragedTokenBalance(),
                collateralValue - targetRatio * peggedSupply,
                collateralValue - 1 ether * peggedSupply
            );
    }

    /// @dev What a redemption of `leveragedIn` moves, by the incentive config. The leveraged is a claim on its share of
    ///      the residual; walking down from the top band, where the market here starts, each band takes the collateral
    ///      above its lower bound - the collateral at the bound rounded up, so the cheaper slice is never overstated -
    ///      and the last band entered takes the rest, each slice's fee exact on its collateral. The redeemer is paid
    ///      the claim less the fees, rounded down once, and the fee receiver the rest of the whole wei that leave.
    function _expectedRedemption(uint256 leveragedIn) private view returns (Outcome memory expected) {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
        uint256 heldE36 = IMinter(minter).collateralTokenBalance() * 1 ether;
        uint256 claimE36 = Math.mulDiv(
            IMinter(minter).collateralTokenBalance() * price - peggedSupply * 1 ether,
            leveragedIn * 1 ether,
            price * IMinter(minter).leveragedTokenBalance()
        );
        uint256 leftE36 = claimE36;
        uint256 feeE54 = 0;
        for (uint256 band = config.redeemLeveragedIncentiveConfig.incentiveRatios.length - 1; leftE36 > 0; band--) {
            uint256 sliceE36 = Math.min(
                leftE36,
                heldE36 -
                    Math.mulDiv(
                        config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[band - 1] * 1 ether,
                        peggedSupply,
                        price,
                        Math.Rounding.Ceil
                    )
            );
            feeE54 += sliceE36 * uint256(config.redeemLeveragedIncentiveConfig.incentiveRatios[band]);
            leftE36 -= sliceE36;
            heldE36 -= sliceE36;
        }
        expected.paid = (claimE36 * 1 ether - feeE54) / (rate * 1 ether);
        expected.fee = claimE36 / rate - expected.paid;
    }

    /// @dev Redeems `leveragedIn` and checks it ended between `lowerRatio` and `upperRatio` - the band the scenario aims
    ///      for - with the redeemer and the fee receiver each paid exactly what `expected` gives them.
    function _redeemAndCheck(
        uint256 leveragedIn,
        Outcome memory expected,
        uint256 lowerRatio,
        uint256 upperRatio
    ) private {
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(user);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        IMinter(minter).redeemLeveragedToken(leveragedIn, user, 0);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), lowerRatio, "the redemption ends in the band aimed for");
        assertLt(IMinter(minter).collateralRatio(), upperRatio, "the redemption ends in the band aimed for");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(user) - heldBefore,
            expected.paid,
            "the redeemer is paid each slice less its band's fee"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            expected.fee,
            "the fee receiver is paid the fees"
        );
    }
}
