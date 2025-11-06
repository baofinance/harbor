// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterMint} from "test/Minter_mint.t.sol";

contract TestMinterMintLeveraged is TestMinterMint {
    using SafeERC20 for IERC20;

    //---------------------------------------------------------------------------------------------
    // Free Mint Leveraged
    //---------------------------------------------------------------------------------------------
    function _freeMintLeveragedToken(uint256 collateralIn) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(zeroFee);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        // uint256 receiverLeveragedIncrease = IMinter(minter).leveragedTokensForCollateral(ownerCollateralDecrease);
        // This fails because there are no pegged
        // uint256 receiverLeveragedIncrease;
        // {
        //     uint256 fee;
        //     uint256 discount;
        //     (, fee, discount, , receiverLeveragedIncrease, , ) = IMinter(minter).mintLeveragedTokenDryRun(
        //         ownerCollateralDecrease
        //     );
        //     receiverLeveragedIncrease = receiverLeveragedIncrease + (fee * price) - (discount * price);
        // }
        // assertEq(
        //     receiverLeveragedIncrease,
        //     (price * ownerCollateralDecrease) / 1 ether,
        //     "leveraged for collateral is correct"
        // );
        uint256 receiverLeveragedIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 ownerCollateralBefore = IERC20(Deployed.wstETH).balanceOf(zeroFee);
        uint256 receiverCollateralBefore = IERC20(Deployed.wstETH).balanceOf(receiver);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(Deployed.wstETH).balanceOf(minter);
        uint256 minterLeveragedBefore = IMinter(minter).leveragedTokenBalance();
        uint256 leveragedSupplyBefore = IERC20(leveragedToken).totalSupply();
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance before freeMintLeveraged"
        );

        vm.expectEmit(true, true, true, true, minter);
        emit IMinter.MintLeveragedToken(zeroFee, receiver, ownerCollateralDecrease, receiverLeveragedIncrease);
        vm.prank(zeroFee);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(collateralIn, receiver);
        //               --------------------------------------------------------------
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "free mint leveraged doesn't change the leveraged price"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(Deployed.wstETH).balanceOf(minter),
            "collaterals balance after freeMintLeveraged"
        );
        assertEq(minted, receiverLeveragedIncrease, "unexpected amount free minted leveraged compared to price");
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
            IERC20(leveragedToken).balanceOf(receiver),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "receiver leveraged balance after"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBefore + ownerCollateralDecrease,
            "stETH collateral transferred"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            minterWstETHBefore + ownerCollateralDecrease,
            "wstETH collateral transferred"
        );
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            minterLeveragedBefore + receiverLeveragedIncrease,
            "levereged token balance"
        );
        assertEq(
            IERC20(leveragedToken).totalSupply(),
            leveragedSupplyBefore + receiverLeveragedIncrease,
            "leveraged supply"
        );

        if (collateralRatioBefore != type(uint256).max)
            assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio > before");
    }

    function test_freeMintLeveraged() public {
        // mint noaccess
        assertFalse(IBaoRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(sender);
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        // 1 ----------------------------------------------------

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, IMinter(minter).LEVERAGED_TOKEN()));
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        // 2 ----------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        // 3 ----------------------------------------------------

        // // all input, when none
        // vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        // vm.prank(zeroFee);
        // IMinter(minter).freeMintLeveragedToken(type(uint256).max, receiver);
        // // 4 --------------------------------------------------------------

        // get collateral & allowance
        deal(address(Deployed.wstETH), zeroFee, 10 ether);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, IMinter(minter).LEVERAGED_TOKEN()));
        vm.prank(zeroFee);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        // 4 ----------------------------------------------

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // got to add some pegged tokens or collateral ratio checks don't work

        // first mint
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether,
            "collateral ratio = 1 for the first mint: 0/0, a special case = 1"
        ); /*  */
        assertEq(IBaoOwnable(minter).owner(), owner);
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        _freeMintLeveragedToken(1 ether);
        // 5 ---------------------------
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            (1 ether * price) / IMinter(minter).leveragedTokenPrice(),
            "1 ether worth of leveraged"
        );
        // collateral ratio is undefined for just minting leveraged tokens
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether * 1 ether,
            unicode"now we have collateral but no pegged, collateral ratio = x/0 = ∞"
        );
        assertEq(IERC20(leveragedToken).balanceOf(receiver), price);

        // mint with some collateral ratio
        vm.prank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        assertGt(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio > 1");
        assertEq(IBaoOwnable(minter).owner(), owner);
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        _freeMintLeveragedToken(1 ether);
        // 7 ---------------------------
        assertApproxEqAbs(
            IERC20(leveragedToken).balanceOf(receiver),
            (2 ether * price) / IMinter(minter).leveragedTokenPrice(),
            600,
            "2 ether worth of leveraged"
        );

        // more than one mint
        _freeMintLeveragedToken(2 ether);
        // 8 ---------------------------

        // no longe support -1
        // // check all-of function, when some
        // _freeMintLeveragedToken(type(uint256).max);
        // // 9 -------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Leveraged
    //---------------------------------------------------------------------------------------------

    struct MintLeveragedHolding {
        uint256 reservePoolCollateral;
        uint256 feeReceiverCollateral;
        uint256 senderCollateral;
        uint256 receiverCollateral;
        uint256 receiverLeveraged;
        uint256 minterCollateral;
        uint256 minterCollateralBalance;
        uint256 minterLeveragedBalance;
        uint256 minterLeveragedPrice;
        uint256 collateralRatio;
    }

    function _mintLeveragedToken(uint256 collateralIn) private {
        //(uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(sender);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(Deployed.wstETH), sender, senderCollateralDecrease);
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        uint256 mintLeveragedFee = 0;
        uint256 mintLeveragedDiscount = 0;
        {
            int256 feeDiscount = (int256(senderCollateralDecrease) *
                ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) / 1 ether;
            if (feeDiscount >= 0) mintLeveragedFee = uint256(feeDiscount);
            else mintLeveragedDiscount = uint256(-feeDiscount);
        }
        // uint256 receiverLeveragedIncrease = IMinter(minter).leveragedTokensForCollateral(
        //     senderCollateralDecrease - mintLeveragedFee + mintLeveragedDiscount
        // );

        MintLeveragedHolding memory before = MintLeveragedHolding(
            IERC20(Deployed.wstETH).balanceOf(reservePool),
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            IERC20(Deployed.wstETH).balanceOf(sender),
            IERC20(Deployed.wstETH).balanceOf(receiver),
            IERC20(leveragedToken).balanceOf(receiver),
            IERC20(Deployed.wstETH).balanceOf(minter),
            IMinter(minter).collateralTokenBalance(),
            IMinter(minter).leveragedTokenBalance(),
            IMinter(minter).leveragedTokenPrice(),
            IMinter(minter).collateralRatio()
        );

        vm.expectEmit(true, true, true, false, minter);
        emit IMinter.MintLeveragedToken(sender, receiver, senderCollateralDecrease, 0);
        vm.prank(sender);
        //uint256 minted =
        IMinter(minter).mintLeveragedToken(senderCollateralDecrease, receiver, 0);
        //               --------------------------------------------------------------------------
        assertEq(
            before.minterLeveragedPrice,
            IMinter(minter).leveragedTokenPrice(),
            "minting leverage doesn't change it's price"
        );
        // assertEq(minted, receiverLeveragedIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            before.feeReceiverCollateral + mintLeveragedFee,
            "fee transferred"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(reservePool),
            before.reservePoolCollateral - mintLeveragedDiscount,
            "discount transferred"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(sender),
            before.senderCollateral - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(receiver),
            before.receiverCollateral,
            "no change in receiver collateral"
        );
        // assertEq(
        //     IERC20(leveragedToken).balanceOf(receiver),
        //     before.receiverLeveraged + receiverLeveragedIncrease,
        //     "receiver received leveraged"
        // );
        // assertEq(
        //     IMinter(minter).leveragedTokenBalance(),
        //     before.minterLeveragedBalance + receiverLeveragedIncrease,
        //     "minter is tracking new leveraged tokens"
        // );
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(minter),
            IMinter(minter).collateralTokenBalance(),
            "wstETH has minter owning it"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            before.minterCollateralBalance + senderCollateralDecrease - mintLeveragedFee + mintLeveragedDiscount,
            "minter is tracking the new collateral"
        );

        assertGt(IMinter(minter).collateralRatio(), before.collateralRatio, "collateral ratio <= before");
    }

    struct DryRunResults {
        int256 incentiveRatio;
        uint256 wrappedFee;
        uint256 wrappedDiscount;
        uint256 wrappedCollateralUsed;
        uint256 leveragedMinted;
        uint256 price;
        uint256 rate;
    }

    function _testMintLeveragedDryRun(uint256 collateralIn, DryRunResults memory expected, address sender_) internal {
        // console.log("expected.incentiveRatio = %s", expected.incentiveRatio);
        DryRunResults memory r;
        vm.prank(sender_);
        (
            r.incentiveRatio,
            r.wrappedFee,
            r.wrappedDiscount,
            r.wrappedCollateralUsed,
            r.leveragedMinted,
            r.price,
            r.rate
        ) = IMinter(minter).mintLeveragedTokenDryRun(collateralIn);
        console.log("r,incentiveRatio = %s", r.incentiveRatio);
        // console.log("expected.incentiveRatio = %s", expected.incentiveRatio);
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedDiscount, expected.wrappedDiscount, "wrappedDiscount");
        assertEq(r.wrappedCollateralUsed, expected.wrappedCollateralUsed, "wrappedCollateralUsed");
        assertEq(r.leveragedMinted, expected.leveragedMinted, "leveragedMinted");
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
                wrappedCollateralUsed: 0,
                leveragedMinted: 0,
                price: price_,
                rate: rate_
            });
    }

    function test_mintLeveragedBasic() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        // 1 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        // 2 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when low collateral ratio
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        // 3 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        // make the CR > 1
        price = price + 2 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price);

        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(0, expected, sender);

        expected.incentiveRatio = 0.007 ether;
        expected.wrappedFee = 0.007 ether;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = 1989986000000000000000;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        // vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        // 4 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        // above we ignore the balance, here we don't
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(type(uint256).max, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        // 5 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get collateral
        deal(address(Deployed.wstETH), sender, 10 ether);

        // mint no allowance
        assertEq(IERC20(Deployed.wstETH).allowance(sender, minter), 0);

        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        expected.wrappedFee = 0.007 ether;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = 1989986000000000000000;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        // 6 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get allowance
        vm.prank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        _testMintLeveragedDryRun(0, expected, sender);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        // 7 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when some
        uint256 collateralBefore = IMinter(minter).collateralTokenBalance();
        expected = zeros();
        expected.incentiveRatio = 0.007 ether;
        expected.wrappedFee = 0.007 ether;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = 1989986000000000000000;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        // 8 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), expected.leveragedMinted);
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0, "received = returned");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            collateralBefore + 1 ether - 0.007 ether,
            "collaterals should be 1 more minus the fee"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
    }

    // TODO: check bonus function - do this as part of reserve pool
    function test_mintLeveragedBonus() public {
        // test bonus when reserve pool is empty
        // test bonus when reserve
        // CR out of bonus zone = no bonus
    }

    function test_mintLeveragedNormal() public {
        setUp_collateral(10 ether, 0);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintLeveragedToken(1 ether);
        // 1 --------------------------

        // second mint
        _mintLeveragedToken(2 ether);
        // 2 --------------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(Deployed.wstETH), sender, collateral * 10);

        (, , , , uint256 expectedLeveragedTokenOut, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);
        uint256 senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);

        // just within
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut);
        // 3 --------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut,
                expectedLeveragedTokenOut + 1
            )
        );
        vm.prank(sender);
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut + 1);
        // 4 ----------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore);

        (, , , , expectedLeveragedTokenOut, , ) = IMinter(minter).mintLeveragedTokenDryRun(senderCollateralBefore);
        _mintLeveragedToken(type(uint256).max);
        // 5 ------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0, "transferred it all");
    }

    // checks that two free mint leverage tokens does not produce more leverage tokens than one mint
    function test_leveragedToCollateralCalculation() public {
        setUp_collateral(1 ether, 1 ether);
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio, "CR=2");

        uint256 collateral = 100 ether;

        deal(address(Deployed.wstETH), zeroFee, collateral);
        vm.prank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, collateral);
        // for a range of collateral ratios,

        // mint one
        (, uint256 fee, uint256 discount, , uint256 oneMint, uint256 price, ) = IMinter(minter)
            .mintLeveragedTokenDryRun(collateral);
        oneMint = oneMint + (fee * price) / 1 ether - (discount * price) / 1 ether;
        // mint multiple
        uint multiples = 100;
        uint256 collateral2 = collateral / multiples;
        uint256 prevCollateralRatio = startCollateralRatio;
        uint256 sum = 0;
        for (uint i = 0; i < multiples; i++) {
            uint256 oneOfMint;
            (, fee, discount, , oneOfMint, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral2);
            oneOfMint = oneOfMint + (fee * price) / 1 ether - (discount * price) / 1 ether;
            assertEq(
                oneOfMint,
                oneMint / multiples,
                string.concat("first mint not exactly linear, ", Useful.toString(i))
            );
            sum += oneOfMint;

            vm.prank(zeroFee);
            uint256 oneOfMintActual = IMinter(minter).freeMintLeveragedToken(collateral2, receiver);
            assertEq(oneOfMintActual, oneOfMint, "calc meets reality");
            uint256 collateralRatio = IMinter(minter).collateralRatio();
            assertGt(collateralRatio, prevCollateralRatio, "CR not increasing");
            prevCollateralRatio = collateralRatio;
        }
        assertEq(sum, oneMint, "one is the sum of it's constituents");
    }
}
