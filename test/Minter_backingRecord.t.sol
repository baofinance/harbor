// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// The recorded backing against the collateral actually held.
///
/// The Minter records the backing as a collateral-token quantity and holds a wrapped balance. The
/// record is only ever a claim about the holding, so it must never come to claim more than the
/// holding converts to — otherwise the protocol prices against cover it does not have, and the
/// excess is a shortfall carried silently for the life of the market.
///
/// The tests assert the CHANGE across a single operation rather than the absolute figures, because
/// an accrued surplus would otherwise mask a record that moved further than the collateral did.
contract MinterBackingRecordTest is TestMinterSetUp {
    /// The `bao.storage.Minter` ERC-7201 slot; `underlyingCollateral` is the second field in the struct.
    bytes32 private constant _MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _rate() private view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _price() private view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// The record itself, read from storage rather than through a getter, so that what the getters report
    /// can be checked against it instead of being taken as it.
    function _recordedBacking() private view returns (uint256) {
        return uint256(vm.load(minter, bytes32(uint256(_MINTER_STORAGE) + 1)));
    }

    /// What is actually held, expressed in collateral tokens, at the rate the record is valued against.
    function _heldAsCollateral() private view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether);
    }

    /// A market low enough in the schedule to sit in the SUBSIDY bands — below 1.10 for leveraged minting and
    /// below 1.15 for pegged redemption — with a reserve to pay them from. The subsidy is the term that
    /// makes the record and the holding separable: it is floored in wrapped when the reserve pays it, while
    /// the band walk accumulates it in full, so a record derived from the accumulator claims collateral the
    /// reserve never sent.
    function _setUpSubsidisedMarket(uint256 reserveWrapped) private {
        setUp_collateral(100 ether, 8 ether); // collateral ratio 1.08
        deal(wrappedCollateralToken, reservePool, reserveWrapped);
        assertLt(IMinter(minter).collateralRatio(), 1.10 ether, "the market must sit in the subsidy bands");
    }

    /// A wrapped-to-underlying rate from a millionth to a million, drawn evenly across the twelve decades between.
    /// The extremes are where conversions round coarsest - a millionth floors the collateral a wrapped wei credits, a
    /// million the wrapped a collateral wei pays out - and the mantissa is drawn too, because at a power of ten one
    /// direction of each conversion is exact.
    function _rateFromAMillionthToAMillion(uint256 decade, uint256 mantissa) private pure returns (uint256) {
        return bound(mantissa, 1e12, 1e13 - 1) * 10 ** bound(decade, 0, 11);
    }

    /// The wrapped collateral held by everyone an operation can pay or charge.
    struct WrappedHoldings {
        uint256 caller;
        uint256 minter;
        uint256 feeReceiver;
        uint256 reserve;
    }

    function _wrappedHoldings(address caller) private view returns (WrappedHoldings memory holdings) {
        holdings.caller = IERC20(wrappedCollateralToken).balanceOf(caller);
        holdings.minter = IERC20(wrappedCollateralToken).balanceOf(minter);
        holdings.feeReceiver = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        holdings.reserve = IERC20(wrappedCollateralToken).balanceOf(reservePool);
    }

    /// A zero-fee route charges no fee and draws on no reserve: the wrapped the caller gives up or receives,
    /// `callerChange`, is exactly what the minter receives or gives up, and nobody else's holding moves.
    function _assertOnlyTheCallerAndTheMinterMoved(
        WrappedHoldings memory pre,
        WrappedHoldings memory post,
        int256 callerChange
    ) private pure {
        assertEq(int256(post.caller) - int256(pre.caller), callerChange, "the caller's wrapped moves by the amount");
        assertEq(int256(post.minter) - int256(pre.minter), -callerChange, "and the minter's by the opposite");
        assertEq(post.feeReceiver, pre.feeReceiver, "no fee is taken");
        assertEq(post.reserve, pre.reserve, "no reserve is drawn on");
    }

    /*//////////////////////////////////////////////////////////////
                             THE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// A mint credits the record with the collateral standing behind it, so the record may never gain
    /// more than the holding gained. A rate that does not divide evenly is what makes the two
    /// derivations separable: the collateral credited and the wrapped taken are computed apart, and
    /// only their agreement keeps the record honest. Every test here mints its market's genesis at a rate
    /// from a millionth to a million, so the rounding at both extremes is reached on every route.
    function testFuzz_peggedMintRecordNeverGainsMoreThanTheHolding(
        uint256 wrappedIn,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        setUp_collateral(100 ether, 40 ether);
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address peggedMinter = makeAddr("peggedMinter");
        deal(wrappedCollateralToken, peggedMinter, wrappedIn);
        vm.startPrank(peggedMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintPeggedToken(wrappedIn, peggedMinter, 0);
        vm.stopPrank();

        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    /// The fee-capped pegged mint takes only as much of the offer as its cap allows, and the record must follow
    /// what it took: the caller gives up exactly the wrapped the mint reports using, which reaches the minter and
    /// the fee receiver and nobody else, and the record gains no more than the holding. From a ratio of 1.6, in
    /// the 0.5% band, a cap below 1% cuts the mint inside the 1% band below 1.40, where the average fee reaches the
    /// cap - at 1.40 itself for a cap of 0.5%; a cap of 1% cuts it at 1.30, where minting is disallowed.
    function testFuzz_cappedPeggedMint_conservesTheWrappedAndTheRecordGainsNoMoreThanTheHolding(
        uint256 wrappedIn,
        uint256 maxFeeRatio,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        setUp_collateral(100 ether, 60 ether);
        wrappedIn = bound(wrappedIn, 1e15, 200 ether);
        // From the cheapest band's fee, so every cap buys some of the offer, to the dearest band's, so most caps cut the
        // mint where the average fee reaches them - the cut with the most rounding in it. A cap below every fee mints
        // nothing, which Minter_mintPegged pins.
        int256[] memory fees = IMinter_v3(minter).config().mintPeggedIncentiveConfig.incentiveRatios;
        maxFeeRatio = bound(maxFeeRatio, uint256(fees[fees.length - 1]), uint256(fees[fees.length - 2]));

        address peggedMinter = makeAddr("cappedPeggedMinter");
        deal(wrappedCollateralToken, peggedMinter, wrappedIn);
        WrappedHoldings memory pre = _wrappedHoldings(peggedMinter);
        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(peggedMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        (, uint256 wrappedUsed) = IMinter_v3(minter).mintPeggedToken(wrappedIn, peggedMinter, 0, maxFeeRatio);
        vm.stopPrank();

        WrappedHoldings memory post = _wrappedHoldings(peggedMinter);
        assertEq(post.caller, pre.caller - wrappedUsed, "the caller gives up exactly the wrapped used");
        assertEq(
            post.minter + post.feeReceiver,
            pre.minter + pre.feeReceiver + wrappedUsed,
            "which reaches the minter and the fee receiver"
        );
        assertEq(post.reserve, pre.reserve, "and none of it the reserve");
        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    /// The zero-fee pegged mint takes the whole offer and charges nothing for it: the caller gives up exactly
    /// what it offers, all of it to the minter, and the record gains no more than the holding.
    function testFuzz_zeroFeePeggedMint_conservesTheWrappedAndTheRecordGainsNoMoreThanTheHolding(
        uint256 wrappedIn,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        setUp_collateral(100 ether, 40 ether);
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);

        deal(wrappedCollateralToken, zeroFee, wrappedIn);
        WrappedHoldings memory pre = _wrappedHoldings(zeroFee);
        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter_v3(minter).freeMintPeggedToken(wrappedIn, zeroFee);
        vm.stopPrank();

        _assertOnlyTheCallerAndTheMinterMoved(pre, _wrappedHoldings(zeroFee), -int256(wrappedIn));
        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    function testFuzz_leveragedMintRecordNeverGainsMoreThanTheHolding(
        uint256 wrappedIn,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        setUp_collateral(100 ether, 40 ether);
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address leveragedMinter = makeAddr("leveragedMinter");
        deal(wrappedCollateralToken, leveragedMinter, wrappedIn);
        vm.startPrank(leveragedMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, leveragedMinter, 0);
        vm.stopPrank();

        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    /// The zero-fee leveraged mint takes the whole offer and charges nothing for it: the caller gives up
    /// exactly what it offers, all of it to the minter, and the record gains no more than the holding.
    function testFuzz_zeroFeeLeveragedMint_conservesTheWrappedAndTheRecordGainsNoMoreThanTheHolding(
        uint256 wrappedIn,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        setUp_collateral(100 ether, 40 ether);
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);

        deal(wrappedCollateralToken, zeroFee, wrappedIn);
        WrappedHoldings memory pre = _wrappedHoldings(zeroFee);
        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter_v3(minter).freeMintLeveragedToken(wrappedIn, zeroFee);
        vm.stopPrank();

        _assertOnlyTheCallerAndTheMinterMoved(pre, _wrappedHoldings(zeroFee), -int256(wrappedIn));
        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      THE INVARIANT, INVERTED
    //////////////////////////////////////////////////////////////*/

    /// Redeeming pays collateral out, so the mirror applies: a record that gives up LESS than the
    /// holding did is left claiming the difference, which is the same shortfall arrived at from the
    /// other direction.
    function testFuzz_peggedRedeemRecordNeverLosesLessThanTheHolding(
        uint256 redeeming,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        redeeming = bound(redeeming, 1e15, peggedTokens / 10);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        IMinter(minter).redeemPeggedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "the record must give up at least as much collateral as the holding did"
        );
    }

    /// The zero-fee pegged redemption pays its collateral leg out of the minter and converts its leveraged leg in
    /// place: the caller receives exactly the wrapped returned, all of it from the minter, and the record gives up
    /// no less than the holding.
    function testFuzz_zeroFeePeggedRedemption_conservesTheWrappedAndTheRecordLosesNoLessThanTheHolding(
        uint256 forCollateral,
        uint256 forLeveraged,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        forCollateral = bound(forCollateral, peggedTokens / 1e9, peggedTokens / 10);
        forLeveraged = bound(forLeveraged, peggedTokens / 1e9, peggedTokens / 10);

        WrappedHoldings memory pre = _wrappedHoldings(zeroFee);
        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, forCollateral + forLeveraged);
        (uint256 wrappedOut, ) = IMinter_v3(minter).freeRedeemPeggedToken(forCollateral, forLeveraged, zeroFee);
        vm.stopPrank();

        _assertOnlyTheCallerAndTheMinterMoved(pre, _wrappedHoldings(zeroFee), int256(wrappedOut));
        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "the record must give up at least as much collateral as the holding did"
        );
    }

    function testFuzz_leveragedRedeemRecordNeverLosesLessThanTheHolding(
        uint256 redeeming,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        redeeming = bound(redeeming, 1e15, leveragedTokens / 10);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, redeeming);
        IMinter(minter).redeemLeveragedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "the record must give up at least as much collateral as the holding did"
        );
    }

    /// The zero-fee leveraged redemption pays out of the minter alone: the caller receives exactly the wrapped
    /// returned, all of it from the minter, and the record gives up no less than the holding.
    function testFuzz_zeroFeeLeveragedRedemption_conservesTheWrappedAndTheRecordLosesNoLessThanTheHolding(
        uint256 leveragedIn,
        uint256 decade,
        uint256 mantissa
    ) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _rateFromAMillionthToAMillion(decade, mantissa));
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        leveragedIn = bound(leveragedIn, leveragedTokens / 1e9, leveragedTokens / 10);

        WrappedHoldings memory pre = _wrappedHoldings(zeroFee);
        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedIn);
        uint256 wrappedOut = IMinter_v3(minter).freeRedeemLeveragedToken(leveragedIn, zeroFee);
        vm.stopPrank();

        _assertOnlyTheCallerAndTheMinterMoved(pre, _wrappedHoldings(zeroFee), int256(wrappedOut));
        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "the record must give up at least as much collateral as the holding did"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      WITH A SUBSIDY IN PLAY
    //////////////////////////////////////////////////////////////*/

    /// Minting leveraged into a subsidy band brings collateral in from two sources — the caller and the reserve —
    /// and the reserve's share is floored on its way in. The record must follow what arrived, not what the
    /// schedule offered.
    function testFuzz_subsidisedLeveragedMintRecordNeverGainsMoreThanTheHolding(uint256 wrappedIn) public {
        wrappedIn = bound(wrappedIn, 1e15, 1 ether);
        _setUpSubsidisedMarket(100 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address leveragedMinter = makeAddr("subsidisedLeveragedMinter");
        deal(wrappedCollateralToken, leveragedMinter, wrappedIn);
        vm.startPrank(leveragedMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, leveragedMinter, 0);
        vm.stopPrank();

        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    function testFuzz_subsidisedPeggedRedeemRecordNeverLosesLessThanTheHolding(uint256 redeeming) public {
        _setUpSubsidisedMarket(100 ether);
        redeeming = bound(redeeming, 1e15, IMinter(minter).peggedTokenBalance() / 20);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        IMinter(minter).redeemPeggedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "the record must give up at least as much collateral as the holding did"
        );
    }

    /// A reserve too small to pay the whole subsidy caps it, so the collateral arriving falls short of what
    /// the schedule offered. The record must account for what the reserve actually sent — a record built from
    /// the offered figure claims the shortfall, and the reserve is not there to be overdrawn.
    function test_subsidisedRedeemDoesNotOverdrawTheReserve() public {
        _setUpSubsidisedMarket(1e12); // far less than the subsidy the schedule offers
        uint256 redeeming = IMinter(minter).peggedTokenBalance() / 20;

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        IMinter(minter).redeemPeggedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        uint256 paid = reserveBefore - IERC20(wrappedCollateralToken).balanceOf(reservePool);
        assertGt(paid, 0, "the subsidy must actually be paid, or this proves nothing");
        assertLe(paid, reserveBefore, "the reserve pays at most what it holds");
        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "a capped subsidy still leaves the record giving up at least what the holding did"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     THE CONSEQUENCE FOR DEPOSITORS
    //////////////////////////////////////////////////////////////*/

    /// Why the record tracking the holding matters to anyone: a record sitting above the holding is a
    /// shortfall, and `harvestable` stays at zero until accruing yield has repaid it. Yield must reach the
    /// stability pools in full from the first moment it accrues, however many times the market has traded.
    function test_yieldReachesThePoolsInFullAfterManyOperations() public {
        setUp_collateral(100 ether, 40 ether);

        address trader = makeAddr("trader");
        for (uint256 i = 0; i < 10; i++) {
            deal(wrappedCollateralToken, trader, 1 ether);
            vm.startPrank(trader);
            IERC20(wrappedCollateralToken).approve(minter, 1 ether);
            IMinter(minter).mintLeveragedToken(1 ether, trader, 0);
            vm.stopPrank();
        }

        uint256 balance = IERC20(wrappedCollateralToken).balanceOf(minter);
        assertEq(IMinter(minter).harvestable(), 0, "a market that has only traded has earned nothing to harvest");

        // 1% of yield: the holding is now worth 1% more of its underlying than the record claims
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), (_rate() * 101) / 100);

        // the whole of it is harvestable — none spent repaying a shortfall the trading left behind
        assertApproxEqAbs(
            IMinter(minter).harvestable(),
            balance - Math.mulDiv(balance, 100, 101),
            10,
            "the yield arrives undiminished"
        );
    }
}
