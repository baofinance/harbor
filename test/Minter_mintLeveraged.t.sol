// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
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
        // the high price, the one the mint reads
        (, uint256 price, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(zeroFee);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
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

        vm.startPrank(zeroFee);
        vm.expectEmit(true, true, true, true, minter);
        emit IMinter.MintLeveragedToken(zeroFee, receiver, ownerCollateralDecrease, receiverLeveragedIncrease);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(collateralIn, receiver);
        //               --------------------------------------------------------------
        vm.stopPrank();
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

        if (collateralRatioBefore != type(uint256).max) {
            assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio > before");
        }
    }

    /// The zero-fee leveraged mint: reverts for a caller without the zero-fee role; for an offer of nothing into the
    /// empty market, which that offer leaves at a ratio of one, under the min CR; and in the collateral token for an
    /// offer the caller does not hold. It is served into the empty market and into one with pegged outstanding, each
    /// mint adding exactly its collateral's value in leveraged tokens at an unchanged leveraged price and raising the
    /// collateral ratio.
    function test_freeMintLeveraged() public {
        // mint noaccess
        assertFalse(IHarborRoles(minter).hasAllRoles(sender, zeroFeeRole));
        vm.startPrank(sender);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        vm.stopPrank();
        // 1 ----------------------------------------------------

        // zero input, when none: the market it would leave is the empty one, at a ratio of one
        assertEq(IERC20(Deployed.wstETH).balanceOf(zeroFee), 0);
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.startPrank(zeroFee);
        vm.expectRevert(belowMinimum);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        vm.stopPrank();
        // 2 ----------------------------------------------

        // some input, when none
        vm.startPrank(zeroFee);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        vm.stopPrank();
        // 3 ----------------------------------------------------

        // get collateral & allowance
        deal(address(Deployed.wstETH), zeroFee, 10 ether);
        vm.startPrank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);
        vm.stopPrank();

        // zero input, when some
        vm.startPrank(zeroFee);
        vm.expectRevert(belowMinimum);
        IMinter(minter).freeMintLeveragedToken(0, receiver);
        vm.stopPrank();
        // 4 ----------------------------------------------

        // the high price, the one the mint reads
        (, uint256 price, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // got to add some pegged tokens or collateral ratio checks don't work

        // first mint
        assertEq(
            IMinter(minter).collateralRatio(),
            1 ether,
            "collateral ratio = 1 for the first mint: 0/0, a special case = 1"
        );
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
        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();
        assertGt(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio > 1");
        assertEq(IHarborOwnable(minter).owner(), owner());
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0);
        _freeMintLeveragedToken(1 ether);
        // 7 ---------------------------
        // exact: the first leveraged mint priced each token at one, the free pegged mint left the residual it found,
        // and a free leveraged mint keeps the leveraged price, so both mints bought their collateral's value at one each
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            (2 ether * price) / IMinter(minter).leveragedTokenPrice(),
            "2 ether worth of leveraged"
        );

        // more than one mint
        _freeMintLeveragedToken(2 ether);
        // 8 ---------------------------
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
        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(Deployed.wstETH).balanceOf(sender);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(Deployed.wstETH), sender, senderCollateralDecrease);
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();

        uint256 mintLeveragedFee = 0;
        uint256 mintLeveragedSubsidy = 0;
        {
            int256 feeSubsidy = (int256(senderCollateralDecrease) *
                ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios)) / 1 ether;
            if (feeSubsidy >= 0) {
                mintLeveragedFee = uint256(feeSubsidy);
            } else {
                mintLeveragedSubsidy = uint256(-feeSubsidy);
            }
        }

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

        vm.startPrank(sender);
        (, , , , uint256 leveragedForecast, , ) = IMinter(minter).mintLeveragedTokenDryRun(senderCollateralDecrease);
        vm.expectEmit(minter);
        emit IMinter.MintLeveragedToken(sender, receiver, senderCollateralDecrease, leveragedForecast);
        // the sentinel is passed on as given, for the minter to read as the sender's whole balance
        uint256 minted = IMinter(minter).mintLeveragedToken(collateralIn, receiver, 0);
        //               ----------------------------------------------------------
        vm.stopPrank();
        assertEq(minted, leveragedForecast, "minted as the dry run forecast");
        assertEq(
            before.minterLeveragedPrice,
            IMinter(minter).leveragedTokenPrice(),
            "minting leverage doesn't change it's price"
        );
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
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver),
            before.receiverLeveraged + minted,
            "receiver received leveraged"
        );
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            before.minterLeveragedBalance + minted,
            "minter is tracking new leveraged tokens"
        );
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
        DryRunResults memory r;
        vm.startPrank(sender_);
        (
            r.incentiveRatio,
            r.wrappedFee,
            r.wrappedSubsidy,
            r.wrappedCollateralUsed,
            r.leveragedMinted,
            r.price,
            r.rate
        ) = IMinter(minter).mintLeveragedTokenDryRun(collateralIn);
        vm.stopPrank();
        assertEq(r.incentiveRatio, expected.incentiveRatio, "incentiveRatio");
        assertEq(r.wrappedFee, expected.wrappedFee, "wrappedFee");
        assertEq(r.wrappedSubsidy, expected.wrappedSubsidy, "wrappedSubsidy");
        assertEq(r.wrappedCollateralUsed, expected.wrappedCollateralUsed, "wrappedCollateralUsed");
        assertEq(r.leveragedMinted, expected.leveragedMinted, "leveragedMinted");
        assertEq(r.price, expected.price, "price");
        assertEq(r.rate, expected.rate, "rate");
    }

    function zeros() internal view returns (DryRunResults memory) {
        // the edges the mint reads
        (, uint256 price_, uint256 rate_, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
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

    /// The retail leveraged mint: a zero offer, or an offer from an empty balance, reverts by name; into the empty
    /// market, which reads a ratio of exactly one, it reverts at the min CR; into a market of pegged alone lifted above
    /// the min CR by price, the first leveraged mint is served, holding the whole residual its deposit leaves, once the
    /// minter is paid and approved - the collateral token reverts it until then. The dry run forecasts each mint
    /// exactly, and the incentive config's flat fee comes exactly off a whole-token offer.
    function test_mintLeveragedBasic() public {
        // the edges the mint reads
        (, uint256 price, uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        int256 incentiveRatio = ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios);
        uint256 fee = Math.mulDiv(1 ether, uint256(incentiveRatio), 1 ether);
        uint256 credited = Math.mulDiv(1 ether - fee, rate, 1 ether);

        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        DryRunResults memory expected;

        // zero input, when none
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0);
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        vm.stopPrank();
        // 1 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 2 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, into the empty market: it reads a ratio of exactly one, under the min CR, so the dry run reports
        // nothing and the mint reverts before anything is taken
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.startPrank(sender);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 3 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        // put the ratio above the min CR, at 1.02
        price = (price * 102) / 100;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price);
        // the first leveraged mint's residual: the backing after its deposit, at the price, less the pegged claim
        uint256 firstMintMinted = Math.mulDiv(IMinter(minter).collateralTokenBalance() + credited, price, 1 ether) -
            IMinter(minter).peggedTokenBalance();

        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(0, expected, sender);

        expected.wrappedFee = fee;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = firstMintMinted;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 4 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // all input, when none
        // above we ignore the balance, here we don't
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(type(uint256).max, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver, 0);
        vm.stopPrank();
        // 5 -------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get collateral
        deal(address(Deployed.wstETH), sender, 10 ether);

        // mint no allowance
        assertEq(IERC20(Deployed.wstETH).allowance(sender, minter), 0);

        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        expected.wrappedFee = fee;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = firstMintMinted;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 6 ---------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // get allowance
        vm.startPrank(sender);
        IERC20(Deployed.wstETH).approve(minter, 10 ether);
        vm.stopPrank();

        // zero input, when some
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        _testMintLeveragedDryRun(0, expected, sender);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, Deployed.wstETH));
        IMinter(minter).mintLeveragedToken(0, receiver, 0);
        vm.stopPrank();
        // 7 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), 0);

        // some input, when some
        uint256 collateralBefore = IMinter(minter).collateralTokenBalance();
        expected = zeros();
        expected.incentiveRatio = incentiveRatio;
        expected.wrappedFee = fee;
        expected.wrappedCollateralUsed = 1 ether;
        expected.leveragedMinted = firstMintMinted;
        _testMintLeveragedDryRun(1 ether, expected, sender);

        vm.startPrank(sender);
        IMinter(minter).mintLeveragedToken(1 ether, receiver, 0);
        vm.stopPrank();
        // 8 ---------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), expected.leveragedMinted);
        assertEq(IERC20(peggedToken).balanceOf(receiver), 0, "received = returned");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            collateralBefore + credited,
            "the backing gains the offer less the fee, at the rate"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(address(Deployed.wstETH)).balanceOf(minter),
            "collaterals balance after freeMint"
        );
    }

    /// A fee-paying leveraged mint from a collateral ratio of two charges the top band's fee and credits the backing
    /// with the rest; a minimum equal to the dry run's forecast is met, one wei more is refused naming both, and the
    /// max sentinel spends the caller's whole balance for exactly the forecast.
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
        vm.startPrank(sender);
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut);
        vm.stopPrank();
        // 3 --------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(Deployed.wstETH).balanceOf(sender);
        receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver);

        // just over
        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut,
                expectedLeveragedTokenOut + 1
            )
        );
        IMinter(minter).mintLeveragedToken(collateral, receiver, expectedLeveragedTokenOut + 1);
        vm.stopPrank();
        // 4 ----------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), senderCollateralBefore);

        (, , , , expectedLeveragedTokenOut, , ) = IMinter(minter).mintLeveragedTokenDryRun(senderCollateralBefore);
        _mintLeveragedToken(type(uint256).max);
        // 5 ------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(Deployed.wstETH).balanceOf(sender), 0, "transferred it all");
    }

    /// Splitting a leveraged mint into a hundred equal parts mints in total exactly what one mint of the whole would:
    /// each part's free mint equals its fee-paying forecast with the fee and subsidy added back at the price, and each
    /// part raises the collateral ratio.
    function test_leveragedToCollateralCalculation() public {
        setUp_collateral(1 ether, 1 ether);
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio, "CR=2");

        uint256 collateral = 100 ether;

        deal(address(Deployed.wstETH), zeroFee, collateral);
        vm.startPrank(zeroFee);
        IERC20(Deployed.wstETH).approve(minter, collateral);
        vm.stopPrank();
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

            vm.startPrank(zeroFee);
            uint256 oneOfMintActual = IMinter(minter).freeMintLeveragedToken(collateral2, receiver);
            vm.stopPrank();
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

/// @notice A leveraged mint walks up through the bands it crosses, each slice subsidised or charged at its own band's
/// rate, the subsidy only as far as the reserve holds; the tokens it mints leave the leveraged price where it was; it
/// reads the sentinel as the caller's whole balance, and reverts for a deposit that buys no token.
contract TestMinterMintLeveragedAcrossBands is TestMinterSetUp {
    address user;

    /// @dev What a mint moves: what the reserve sends, what the fee receiver is paid, and what the minter keeps - the
    ///      offer plus the subsidy less the fee.
    struct Outcome {
        uint256 subsidy;
        uint256 fee;
        uint256 kept;
    }

    /// @dev What the walk carries from band to band: the collateral still to place and the collateral held, at 1e36;
    ///      and what the reserve can still fund, the subsidy and the fee accrued, at 1e54, exact.
    struct MintWalk {
        uint256 leftE36;
        uint256 heldE36;
        uint256 capacityE54;
        uint256 subsidyE54;
        uint256 feeE54;
    }

    /// @dev Minting leveraged is subsidised 0.5% from the peg to 1.2 and 0.3% from 1.2 to 1.5, and charges 0.7% above
    ///      it.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(0, 0)),
            ic(ua(100), ia(0, 0)),
            ic(ua(100, 120, 150), ia(-50, -50, -30, 70)),
            ic(ua(100), ia(0, 0))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
    }

    /// The sentinel spends the caller's whole balance: the mint takes all of it, mints what an offer of exactly that
    /// balance mints, and reports the balance taken in its event.
    function test_mintLeveraged_withTheMaxSentinel_spendsTheCallersWholeBalance() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        uint256 balance = 7 ether;
        deal(wrappedCollateralToken, user, balance);
        (, , , , uint256 dryRunMinted, , ) = IMinter(minter).mintLeveragedTokenDryRun(balance);
        assertGt(dryRunMinted, 0, "precondition: the balance buys leveraged");

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, balance);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter_v3.MintLeveragedToken(user, user, balance, dryRunMinted);
        uint256 minted = IMinter(minter).mintLeveragedToken(type(uint256).max, user, 0);
        vm.stopPrank();

        assertEq(IERC20(wrappedCollateralToken).balanceOf(user), 0, "the caller's whole balance is spent");
        assertEq(minted, dryRunMinted, "minting what an offer of exactly that balance mints");
    }

    /// The dry run reads the sentinel as the caller's whole balance, as the mint does: asked to price the maximum it
    /// reports exactly what an offer of the caller's balance would.
    function test_mintLeveragedDryRun_withTheMaxSentinel_pricesTheCallersWholeBalance() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        uint256 balance = 7 ether;
        deal(wrappedCollateralToken, user, balance);
        (int256 ratio, uint256 fee, , uint256 used, uint256 minted, , ) = IMinter(minter).mintLeveragedTokenDryRun(
            balance
        );
        assertGt(minted, 0, "precondition: the balance buys leveraged");

        vm.startPrank(user);
        (int256 sentinelRatio, uint256 sentinelFee, , uint256 sentinelUsed, uint256 sentinelMinted, , ) = IMinter(
            minter
        ).mintLeveragedTokenDryRun(type(uint256).max);
        vm.stopPrank();

        assertEq(sentinelUsed, used, "the caller's whole balance is priced");
        assertEq(sentinelMinted, minted, "minting what the balance buys");
        assertEq(sentinelFee, fee, "for the balance's fee");
        assertEq(sentinelRatio, ratio, "at the balance's ratio");
    }

    /// A deposit whose fee leaves nothing to credit buys no token: the mint reverts by name, and nothing is taken.
    function test_mintLeveraged_aDepositTooSmallForOneToken_reverts() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8
        assertGt(
            IMinter(minter).collateralRatio(),
            ultimate(config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            "precondition: in the top band, which charges a fee"
        );
        uint256 wrappedIn = 1; // one wei: less its fee, rounded down, it leaves nothing to credit
        deal(wrappedCollateralToken, user, wrappedIn);

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertEq(IERC20(wrappedCollateralToken).balanceOf(user), wrappedIn, "nothing is taken");
    }

    /// For a deposit too small for one token the dry run says what the call does - nothing: nothing used, no fee, no
    /// subsidy, nothing minted, at the band's ratio.
    function test_mintLeveragedDryRun_forAnOfferTooSmallForOneToken_reportsNothingUsed() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2000 ether, 1 ether);
        setUp_collateral(100 ether, 80 ether); // a ratio of 1.8, in the top band, which charges a fee

        // one wei: less its fee, rounded down, it leaves nothing to credit
        (int256 ratio, uint256 fee, uint256 subsidy, uint256 used, uint256 minted, , ) = IMinter(minter)
            .mintLeveragedTokenDryRun(1);
        assertEq(used, 0, "nothing used");
        assertEq(fee, 0, "no fee");
        assertEq(subsidy, 0, "no subsidy");
        assertEq(minted, 0, "nothing minted");
        assertEq(
            ratio,
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "and reports the ratio of the band the market is in"
        );
    }

    /// From a ratio of 1.1 a mint to about 1.35 crosses one bound and one to about 1.8 crosses two. Each slice is cut
    /// where the ratio reaches its band's upper bound - the subsidy it draws counted in - and subsidised or charged at
    /// its band's rate exactly; the reserve, the fee receiver and the minter each move by exactly their part.
    function test_mintLeveraged_acrossOneAndTwoBandBounds_subsidisesEachSliceAtItsBandsRate(
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 10 ether); // a ratio of 1.1
        deal(wrappedCollateralToken, reservePool, 1e30); // a subsidy is never capped
        uint256[] memory bounds = config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds;

        uint256 snapshot = vm.snapshotState();
        uint256 wrappedIn = _wrappedToReach(1.35 ether);
        _mintAndCheck(wrappedIn, _expectedMint(wrappedIn), bounds[1], bounds[2]); // one bound crossed
        vm.revertToState(snapshot);
        wrappedIn = _wrappedToReach(1.8 ether);
        _mintAndCheck(wrappedIn, _expectedMint(wrappedIn), bounds[2], type(uint256).max); // two bounds crossed
    }

    /// With a reserve that runs out part-way through the second slice, the mint is subsidised only by what the reserve
    /// holds, and empties it: the trader's own collateral makes up the rest of the way to the band's bound, so less of
    /// the offer is left to be charged above it.
    function test_mintLeveraged_withAReserveThatRunsOutInTheSecondSlice_subsidisesOnlyWhatItHolds(
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 10 ether); // a ratio of 1.1
        deal(wrappedCollateralToken, reservePool, 1e30);
        // what a funded mint that ends inside the second band draws: the first slice's subsidy and part of the second's
        uint256 reserve = _expectedMint(_wrappedToReach(1.35 ether)).subsidy;
        uint256 wrappedIn = _wrappedToReach(1.8 ether);
        Outcome memory funded = _expectedMint(wrappedIn);
        assertLt(reserve, funded.subsidy, "precondition: less than the mint draws from a funded reserve");
        deal(wrappedCollateralToken, reservePool, reserve);

        Outcome memory expected = _expectedMint(wrappedIn);
        assertEq(expected.subsidy, reserve, "precondition: the subsidy due is all the reserve holds");
        assertLt(expected.fee, funded.fee, "precondition: and less of the offer is left to charge above the bound");
        _mintAndCheck(
            wrappedIn,
            expected,
            config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[2],
            type(uint256).max
        );
    }

    /// A subsidised leveraged mint, at a wrapped-to-underlying rate away from one, leaves the leveraged price
    /// unchanged: its tokens are priced at the price before the mint against the collateral the record gains - the
    /// offer and the subsidy, at the rate, rounded down - so the residual grows in proportion to the supply.
    function test_mintLeveraged_withASubsidyAtARateAwayFromOne_leavesTheLeveragedPriceUnchanged(
        uint256 wrappedIn,
        uint256 rate,
        uint256 price
    ) public {
        rate = bound(rate, 0.5 ether, 5 ether);
        price = bound(price, 1 ether, 100_000 ether);
        wrappedIn = bound(wrappedIn, 1e9, 20 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        setUp_collateral(100 ether, 10 ether); // a ratio of 1.1, and an offer that stays in the subsidised bands
        deal(wrappedCollateralToken, reservePool, 1e30); // the subsidy is never capped
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 residualBeforeE36 = recordBefore * price - IMinter(minter).peggedTokenBalance() * 1 ether;
        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);

        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        uint256 minted = IMinter(minter).mintLeveragedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertLt(
            IERC20(wrappedCollateralToken).balanceOf(reservePool),
            reserveBefore,
            "precondition: the mint is subsidised"
        );
        assertEq(
            minted,
            Math.mulDiv(
                (IMinter(minter).collateralTokenBalance() - recordBefore) * price,
                supplyBefore,
                residualBeforeE36
            ),
            "minted at the price before, against the collateral the record gained"
        );
        // Rounding the tokens down raises the residual behind each one, by less than the square of the leveraged price
        // over the residual - a fraction of a wei of the reported price here - so the price reported does not move.
        assertEq(IMinter(minter).leveragedTokenPrice(), leveragedPriceBefore, "the leveraged price is unchanged");
    }

    /// @dev The wrapped collateral whose mint takes the ratio to about `targetRatio`, by the ratio's definition and
    ///      leaving the incentives aside: (C + x) p / P = T, so x = (T P - C p) / p.
    function _wrappedToReach(uint256 targetRatio) private view returns (uint256) {
        // the edges the mint reads
        (, uint256 price, uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        return
            Math.mulDiv(
                targetRatio * IMinter(minter).peggedTokenBalance() - IMinter(minter).collateralTokenBalance() * price,
                1 ether,
                price * rate
            );
    }

    /// @dev What a mint of `wrappedIn` moves, by the incentive config and the reserve's balance. Walking up from the
    ///      band at index 1, where the market here starts, each subsidised band takes the collateral that, with the
    ///      subsidy it draws, brings the ratio to the band's upper bound, and the top band, which charges, takes the
    ///      rest; each slice's subsidy or fee is exact on its collateral. Where the reserve cannot fund a slice's
    ///      subsidy it gives what it holds and the trader's own collateral makes up the difference to the bound. The
    ///      reserve sends the subsidy's whole wei; the minter keeps the offer plus the subsidy less the fee, rounded
    ///      down once; and the fee receiver is paid the rest.
    function _expectedMint(uint256 wrappedIn) private view returns (Outcome memory expected) {
        // the edges the mint reads
        (, uint256 price, uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 peggedHeldE36 = IMinter(minter).peggedTokenBalance() * 1 ether;
        MintWalk memory w = MintWalk(
            wrappedIn * rate,
            IMinter(minter).collateralTokenBalance() * 1 ether,
            IERC20(wrappedCollateralToken).balanceOf(reservePool) * rate * 1 ether,
            0,
            0
        );
        uint256 topBand = config.mintLeveragedIncentiveConfig.incentiveRatios.length - 1;
        for (uint256 band = 1; w.leftE36 > 0; band++) {
            uint256 sliceE36 = w.leftE36;
            uint256 sliceSubsidyE54 = 0;
            uint256 sliceFeeE54 = 0;
            if (band < topBand) {
                uint256 subsidyRatio = uint256(-config.mintLeveragedIncentiveConfig.incentiveRatios[band]);
                sliceE36 = Math.min(
                    sliceE36,
                    Math.mulDiv(
                        config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[band] * peggedHeldE36 -
                            w.heldE36 * price,
                        1 ether,
                        price * (1 ether + subsidyRatio)
                    )
                );
                sliceSubsidyE54 = sliceE36 * subsidyRatio;
                if (sliceSubsidyE54 > w.capacityE54) {
                    sliceE36 = Math.min(w.leftE36, sliceE36 + (sliceSubsidyE54 - w.capacityE54) / 1 ether);
                    sliceSubsidyE54 = w.capacityE54;
                }
            } else {
                sliceFeeE54 = sliceE36 * uint256(config.mintLeveragedIncentiveConfig.incentiveRatios[band]);
            }
            w.feeE54 += sliceFeeE54;
            w.subsidyE54 += sliceSubsidyE54;
            w.capacityE54 -= sliceSubsidyE54;
            w.leftE36 -= sliceE36;
            w.heldE36 += (sliceE36 * 1 ether + sliceSubsidyE54 - sliceFeeE54) / 1 ether;
        }
        expected.subsidy = w.subsidyE54 / (rate * 1 ether);
        expected.kept = (wrappedIn * rate * 1 ether + w.subsidyE54 - w.feeE54) / (rate * 1 ether);
        expected.fee = wrappedIn + expected.subsidy - expected.kept;
    }

    /// @dev Mints `wrappedIn` and checks the mint ended between `lowerRatio` and `upperRatio` - the band the scenario
    ///      aims for - with the reserve, the fee receiver and the minter each moved by exactly what `expected` gives
    ///      them.
    function _mintAndCheck(uint256 wrappedIn, Outcome memory expected, uint256 lowerRatio, uint256 upperRatio) private {
        deal(wrappedCollateralToken, user, wrappedIn);
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, user, 0);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), lowerRatio, "the mint ends in the band aimed for");
        assertLt(IMinter(minter).collateralRatio(), upperRatio, "the mint ends in the band aimed for");
        assertEq(
            reserveBefore - IERC20(wrappedCollateralToken).balanceOf(reservePool),
            expected.subsidy,
            "the reserve sends each slice's subsidy"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore,
            expected.fee,
            "the fee receiver is paid the fee"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - heldBefore,
            expected.kept,
            "the minter keeps the offer plus the subsidy less the fee"
        );
    }
}
