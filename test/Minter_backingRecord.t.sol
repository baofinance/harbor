// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
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

    /// The record itself, read from storage. The getters all report the RECOGNISED backing — the lower
    /// of the record and the holding — which by construction can never exceed the holding, so it
    /// cannot show whether the record has drifted above it.
    function _recordedBacking() private view returns (uint256) {
        return uint256(vm.load(minter, bytes32(uint256(_MINTER_STORAGE) + 1)));
    }

    /// What is actually held, expressed in collateral tokens, at the rate the record is valued against.
    function _heldAsCollateral() private view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether);
    }

    /// A market low enough in the schedule to sit in the DISCOUNT bands — below 1.10 for sail minting and
    /// below 1.15 for anchor redemption — with a reserve to pay them from. The discount is the term that
    /// makes the record and the holding separable: it is floored in wrapped when the reserve pays it, while
    /// the band walk accumulates it in full, so a record derived from the accumulator claims collateral the
    /// reserve never sent.
    function _setUpDiscountedMarket(uint256 reserveWrapped) private returns (uint256 sailTokens) {
        (, sailTokens) = setUp_collateral(100 ether, 8 ether); // collateral ratio 1.08
        deal(wrappedCollateralToken, reservePool, reserveWrapped);
        assertLt(IMinter(minter).collateralRatio(), 1.10 ether, "the market must sit in the discount bands");
    }

    /*//////////////////////////////////////////////////////////////
                             THE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// A mint credits the record with the collateral standing behind it, so the record may never gain
    /// more than the holding gained. A rate that does not divide evenly is what makes the two
    /// derivations separable: the collateral credited and the wrapped taken are computed apart, and
    /// only their agreement keeps the record honest.
    function testFuzz_anchorMintRecordNeverGainsMoreThanTheHolding(uint256 wrappedIn) public {
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);
        setUp_collateral(100 ether, 40 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address anchorMinter = makeAddr("anchorMinter");
        deal(wrappedCollateralToken, anchorMinter, wrappedIn);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintPeggedToken(wrappedIn, anchorMinter, 0);
        vm.stopPrank();

        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    function testFuzz_sailMintRecordNeverGainsMoreThanTheHolding(uint256 wrappedIn) public {
        wrappedIn = bound(wrappedIn, 1e15, 10 ether);
        setUp_collateral(100 ether, 40 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address sailMinter = makeAddr("sailMinter");
        deal(wrappedCollateralToken, sailMinter, wrappedIn);
        vm.startPrank(sailMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, sailMinter, 0);
        vm.stopPrank();

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
    function testFuzz_anchorRedeemRecordNeverLosesLessThanTheHolding(uint256 redeeming) public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        redeeming = bound(redeeming, 1e15, anchorTokens / 10);
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

    function testFuzz_sailRedeemRecordNeverLosesLessThanTheHolding(uint256 redeeming) public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);
        redeeming = bound(redeeming, 1e15, sailTokens / 10);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

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

    /*//////////////////////////////////////////////////////////////
                      WITH A DISCOUNT IN PLAY
    //////////////////////////////////////////////////////////////*/

    /// Minting sail into a discount band brings collateral in from two sources — the caller and the reserve —
    /// and the reserve's share is floored on its way in. The record must follow what arrived, not what the
    /// schedule offered.
    function testFuzz_discountedSailMintRecordNeverGainsMoreThanTheHolding(uint256 wrappedIn) public {
        wrappedIn = bound(wrappedIn, 1e15, 1 ether);
        _setUpDiscountedMarket(100 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), 1.5 ether);

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();

        address sailMinter = makeAddr("discountedSailMinter");
        deal(wrappedCollateralToken, sailMinter, wrappedIn);
        vm.startPrank(sailMinter);
        IERC20(wrappedCollateralToken).approve(minter, wrappedIn);
        IMinter(minter).mintLeveragedToken(wrappedIn, sailMinter, 0);
        vm.stopPrank();

        assertLe(
            _recordedBacking() - recordBefore,
            _heldAsCollateral() - heldBefore,
            "the record may not gain more collateral than the holding did"
        );
    }

    function testFuzz_discountedAnchorRedeemRecordNeverLosesLessThanTheHolding(uint256 redeeming) public {
        _setUpDiscountedMarket(100 ether);
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

    /// A reserve too small to pay the whole discount caps it, so the collateral arriving falls short of what
    /// the schedule offered. The record must account for what the reserve actually sent — a record built from
    /// the offered figure claims the shortfall, and the reserve is not there to be overdrawn.
    function test_discountedRedeemDoesNotOverdrawTheReserve() public {
        _setUpDiscountedMarket(1e12); // far less than the discount the schedule offers
        uint256 redeeming = IMinter(minter).peggedTokenBalance() / 20;

        uint256 recordBefore = _recordedBacking();
        uint256 heldBefore = _heldAsCollateral();
        uint256 reserveBefore = IERC20(wrappedCollateralToken).balanceOf(reservePool);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        IMinter(minter).redeemPeggedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        uint256 paid = reserveBefore - IERC20(wrappedCollateralToken).balanceOf(reservePool);
        assertGt(paid, 0, "the discount must actually be paid, or this proves nothing");
        assertLe(paid, reserveBefore, "the reserve pays at most what it holds");
        assertGe(
            recordBefore - _recordedBacking(),
            heldBefore - _heldAsCollateral(),
            "a capped discount still leaves the record giving up at least what the holding did"
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
