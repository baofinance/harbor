// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

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
        //     uint256 subsidy;
        //     (, fee, subsidy, , receiverLeveragedIncrease, , ) = IMinter(minter).mintLeveragedTokenDryRun(
        //         ownerCollateralDecrease
        //     );
        //     receiverLeveragedIncrease = receiverLeveragedIncrease + (fee * price) - (subsidy * price);
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
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
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
        assertEq(IHarborOwnable(minter).owner(), owner());
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
        assertEq(IHarborOwnable(minter).owner(), owner());
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
        uint256 mintLeveragedSubsidy = 0;
        {
            int256 feeSubsidy = (int256(senderCollateralDecrease) *
                ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) / 1 ether;
            if (feeSubsidy >= 0) mintLeveragedFee = uint256(feeSubsidy);
            else mintLeveragedSubsidy = uint256(-feeSubsidy);
        }
        // uint256 receiverLeveragedIncrease = IMinter(minter).leveragedTokensForCollateral(
        //     senderCollateralDecrease - mintLeveragedFee + mintLeveragedSubsidy
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
            before.reservePoolCollateral - mintLeveragedSubsidy,
            "subsidy transferred"
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
            before.minterCollateralBalance + senderCollateralDecrease - mintLeveragedFee + mintLeveragedSubsidy,
            "minter is tracking the new collateral"
        );

        assertGt(IMinter(minter).collateralRatio(), before.collateralRatio, "collateral ratio <= before");
    }

    struct DryRunResults {
        int256 incentiveRatio;
        uint256 wrappedFee;
        uint256 wrappedSubsidy;
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
            r.wrappedSubsidy,
            r.wrappedCollateralUsed,
            r.leveragedMinted,
            r.price,
            r.rate
        ) = IMinter(minter).mintLeveragedTokenDryRun(collateralIn);
        console.log("r,incentiveRatio = %s", r.incentiveRatio);
        // console.log("expected.incentiveRatio = %s", expected.incentiveRatio);
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedSubsidy, expected.wrappedSubsidy, "wrappedSubsidy");
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
                wrappedSubsidy: 0,
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
        (, uint256 fee, uint256 subsidy, , uint256 oneMint, uint256 price, ) = IMinter(minter).mintLeveragedTokenDryRun(
            collateral
        );
        oneMint = oneMint + (fee * price) / 1 ether - (subsidy * price) / 1 ether;
        // mint multiple
        uint multiples = 100;
        uint256 collateral2 = collateral / multiples;
        uint256 prevCollateralRatio = startCollateralRatio;
        uint256 sum = 0;
        for (uint i = 0; i < multiples; i++) {
            uint256 oneOfMint;
            (, fee, subsidy, , oneOfMint, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral2);
            oneOfMint = oneOfMint + (fee * price) / 1 ether - (subsidy * price) / 1 ether;
            assertEq(
                oneOfMint,
                oneMint / multiples,
                string.concat("first mint not exactly linear, ", LibString.toString(i))
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

/// @notice Minting leveraged without a fee, into a market that already has leveraged tokens, prices the tokens as the
/// fee-paying mint does: against the collateral the record is credited with, at the residual's value.
contract TestMinterFreeMintLeveraged is TestMinterSetUp {
    /// @dev No incentive in any band, so a fee-paying mint pays nothing and receives nothing either, and the two
    ///      routes can be compared trade for trade.
    function setUpConfig() internal virtual override {
        setUp_config_free();
    }

    /// @dev A live market at a collateral ratio of two, priced and rated as the fuzz asks, with `wrappedIn` in the
    ///      hands of the zero-fee actor.
    function _liveMarket(uint256 wrappedIn, uint256 rate, uint256 price) private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 100 ether);
        deal(wrappedCollateralToken, zeroFee, wrappedIn);
    }

    /// @dev What each leveraged token is a claim on is the residual - the collateral's value less the pegged claim -
    ///      shared over the leveraged supply.
    function _residualAndSupply(uint256 price) private view returns (uint256 residualE36, uint256 supply) {
        residualE36 = IMinter(minter).collateralTokenBalance() * price - IMinter(minter).peggedTokenBalance() * 1 ether;
        supply = IMinter(minter).leveragedTokenBalance();
    }

    /// Minting leveraged for free never takes more of the residual than the collateral it brings, so the value
    /// behind each leveraged token already held does not fall - including where leveraged tokens held elsewhere make
    /// the supply so large that the supply times the price no longer fits in a word.
    function testFuzz_aFreeLeveragedMintNeverLowersTheValueOfALeveragedToken(
        uint256 wrappedIn,
        uint256 rate,
        uint256 price,
        uint256 leveragedHeldElsewhere
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        wrappedIn = bound(wrappedIn, 1e9, 100 ether);
        leveragedHeldElsewhere = bound(leveragedHeldElsewhere, 0, 2 ** 200);
        _liveMarket(wrappedIn, rate, price);
        deal(leveragedToken, makeAddr("leveragedHolder"), leveragedHeldElsewhere, true);

        (uint256 residualBefore, uint256 supplyBefore) = _residualAndSupply(price);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).freeMintLeveragedToken(wrappedIn, zeroFee);
        vm.stopPrank();
        (uint256 residualAfter, uint256 supplyAfter) = _residualAndSupply(price);

        // Residual per leveraged token, after against before: residualAfter / supplyAfter >= residualBefore /
        // supplyBefore. Exact without a product that overflows, because a whole-number bound holds for the floor
        // exactly when it holds for the quotient.
        assertGe(
            Math.mulDiv(residualAfter, supplyBefore, supplyAfter),
            residualBefore,
            "the value behind each leveraged token fell"
        );
    }

    /// With no incentive in force a free leveraged mint and a fee-paying one are the same trade: from the same market
    /// the same collateral mints the same leveraged tokens and credits the same backing - including where leveraged
    /// tokens held elsewhere have diluted each one's claim far below any price a market would show, and made the
    /// supply times the price too large for a word.
    function testFuzz_aFreeLeveragedMintMintsWhatAZeroFeeMintDoes(
        uint256 wrappedIn,
        uint256 rate,
        uint256 price,
        uint256 leveragedHeldElsewhere
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        wrappedIn = bound(wrappedIn, 1e9, 100 ether);
        leveragedHeldElsewhere = bound(leveragedHeldElsewhere, 0, 2 ** 200);
        _liveMarket(wrappedIn, rate, price);
        deal(leveragedToken, makeAddr("leveragedHolder"), leveragedHeldElsewhere, true);

        uint256 backingBefore = IMinter(minter).collateralTokenBalance();
        uint256 snapshot = vm.snapshotState();

        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 freeMinted = IMinter(minter).freeMintLeveragedToken(wrappedIn, zeroFee);
        vm.stopPrank();
        uint256 freeCredited = IMinter(minter).collateralTokenBalance() - backingBefore;

        vm.revertToState(snapshot);

        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 paidMinted = IMinter(minter).mintLeveragedToken(wrappedIn, zeroFee, 0);
        vm.stopPrank();
        uint256 paidCredited = IMinter(minter).collateralTokenBalance() - backingBefore;

        assertEq(freeMinted, paidMinted, "the same collateral mints the same leveraged tokens");
        assertEq(freeCredited, paidCredited, "and credits the same backing");
    }
}

/// @notice A fee-paying leveraged mint charges the schedule's fee in full: every rounding of the fee goes the
/// protocol's way.
contract TestMinterMintLeveragedFee is TestMinterSetUp {
    /// @dev One fee in every band, so the exact fee of any mint is the offer times that ratio, however many bands the
    ///      walk crosses.
    function setUpConfig() internal virtual override {
        setUp_config_flatWide();
    }

    /// The fee taken is never less than the exact fee - the offer times the ratio - and exceeds that fee's ceiling by
    /// at most a wei, across rates, prices and offers that walk through several bands.
    function testFuzz_mintLeveraged_neverChargesLessThanTheExactFee(
        uint256 wrappedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        wrappedIn = bound(wrappedIn, 1e9, 100 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 5 ether); // a ratio of 1.05, so a large offer walks through every bound to 1.6
        address minterUser = makeAddr("minterUser");
        deal(wrappedCollateralToken, minterUser, wrappedIn);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        vm.startPrank(minterUser);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, minterUser, 0);
        vm.stopPrank();

        uint256 fee = IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore;
        uint256 ratio = uint256(config.mintLeveragedIncentiveConfig.incentiveRatios[0]);
        assertGe(fee * 1 ether, wrappedIn * ratio, "the fee is never less than the exact fee");
        // Each band's share is rounded up at 1e-36 of a collateral unit and the total once to a wrapped wei, so the
        // charge passes the exact fee's ceiling only where those shares carry it over a whole wei: by one at most.
        assertLe(fee, Math.ceilDiv(wrappedIn * ratio, 1 ether) + 1, "and at most a wei over its ceiling");
    }
}

/// @notice A leveraged mint keeps for the trader the offer plus the subsidy less the fee, rounded down once from the
/// exact figure; the fee receiver absorbs the remainder.
contract TestMinterMintLeveragedRoundedOnce is TestMinterSetUp {
    /// @dev A subsidy up to a ratio of 1.5 and a fee above it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 150), ia(-50, -50, 70)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.3 a mint takes the subsidy up to 1.5 and pays the fee past it. Each slice's subsidy and fee are
    /// exact on the collateral it takes, and the wrapped kept for the trader is their sum with the offer, rounded down
    /// once.
    function testFuzz_mintLeveraged_acrossASubsidyIntoAFee_keepsTheExactNetRoundedOnce(
        uint256 extra,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 30 ether); // a ratio of 1.3
        deal(wrappedCollateralToken, reservePool, 1e30); // the subsidy is never capped

        uint256 wrappedIn;
        uint256 expectedKept;
        {
            uint256 subsidyRatio = uint256(-config.mintLeveragedIncentiveConfig.incentiveRatios[1]);
            uint256 bound15 = config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1];
            // the collateral that, with its subsidy, brings the ratio from 1.3 to 1.5
            uint256 toTheBoundE36 = Math.mulDiv(
                bound15 * (IMinter(minter).peggedTokenBalance() * 1 ether) -
                    (IMinter(minter).collateralTokenBalance() * 1 ether) * price,
                1 ether,
                price * (1 ether + subsidyRatio)
            );
            wrappedIn = Math.ceilDiv(toTheBoundE36, rate) + bound(extra, 1e9, 50 ether);
            // the offer, plus the subsidy on the collateral below the bound, less the fee on the rest
            uint256 netE54 = wrappedIn * rate * 1 ether +
                toTheBoundE36 * subsidyRatio -
                (wrappedIn * rate - toTheBoundE36) * uint256(config.mintLeveragedIncentiveConfig.incentiveRatios[2]);
            expectedKept = netE54 / (rate * 1 ether);
        }

        address minterUser = makeAddr("minterUser");
        deal(wrappedCollateralToken, minterUser, wrappedIn);
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        vm.startPrank(minterUser);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, minterUser, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - heldBefore,
            expectedKept,
            "the wrapped kept: the offer plus the subsidy less the fee, rounded down once"
        );
    }
}

/// @notice A leveraged mint charges each band's fee exactly on the collateral it takes there, so a mint whose exact kept
/// collateral is a whole number of wei keeps exactly that, whatever bounds it crosses.
contract TestMinterMintLeveragedAcrossEqualFees is TestMinterSetUp {
    /// @dev Minting leveraged charges 0.5% in every band, either side of bounds at the peg and at 1.5.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 150), ia(50, 50, 50)),
            ic(ua(100), ia(0, 0))
        );
    }

    /// From a ratio of 1.3 an offer of 100 crosses 1.5. At a wrapped-to-underlying rate of one the offer less 0.5% is a
    /// whole number of wei, and the minter keeps exactly that for the trader.
    function test_mintLeveraged_acrossABoundBetweenEqualFees_keepsExactlyTheOfferLessTheFee() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 30 ether); // a ratio of 1.3
        uint256 wrappedIn = 100 ether;
        uint256 feeRatio = uint256(config.mintLeveragedIncentiveConfig.incentiveRatios[1]);

        address minterUser = makeAddr("minterUser");
        deal(wrappedCollateralToken, minterUser, wrappedIn);
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        vm.startPrank(minterUser);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, minterUser, 0);
        vm.stopPrank();

        assertGt(
            IMinter(minter).collateralRatio(),
            config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1],
            "the mint crossed the bound"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - heldBefore,
            (wrappedIn * (1 ether - feeRatio)) / 1 ether,
            "the offer less the fee"
        );
    }
}
