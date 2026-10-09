// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {GraphRefinement} from "@bao-test/GraphRefinement.t.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

import {console2} from "forge-std/console2.sol";

abstract contract TestCollateralRatioRangeSetUp is GraphRefinement, TestStabilityPool2SetUp {
    /// @dev The collateral ratio of the market's genesis: where every sweep starts, and what the sweeps that scale a
    ///      starting quantity - the wrapped-to-underlying rate, the collateral held - scale it against.
    uint256 internal constant START_COLLATERAL_RATIO = 2 ether;

    uint256 startPrice;
    uint256 start;
    uint256 finish;
    uint256 increment;

    function setUpRange() internal virtual {
        increment = 1 ether / 500;
        start = increment;
        finish = 16 ether / 10;
    }

    function setUp() public virtual override {
        super.setUp();
        setUpRange();

        (startPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(10 ether, 10 ether, address(this));
        deal(address(wrappedCollateralToken), address(this), 1000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();
        assertEq(0, IERC20(wrappedCollateralToken).balanceOf(reservePool), "reserve pool should be empty");
    }

    struct Holdings {
        uint256 feeReceiverCollateral;
        uint256 reservePoolCollateral;
        uint256 minterCollateral;
        uint256 minterUnderlyingCollateral;
        uint256 minterPegged;
        uint256 thisCollateral;
        uint256 thisPegged;
        uint256 thisLeveraged;
    }
    struct DeltaHoldings {
        int256 feeReceiverCollateral;
        int256 reservePoolCollateral;
        int256 minterCollateral;
        int256 minterUnderlyingCollateral;
        int256 minterPegged;
        int256 thisCollateral;
        int256 thisPegged;
        int256 thisLeveraged;
    }

    function logDeltaHoldings(DeltaHoldings memory holdings) internal pure {
        console2.log("DeltaHoldings:");
        console2.log("   feeReceiverCollateral=%s", holdings.feeReceiverCollateral);
        console2.log("   reservePoolCollateral=%s", holdings.reservePoolCollateral);
        console2.log("   minterCollateral=%s", holdings.minterCollateral);
        console2.log("   minterUnderlyingCollateral=%s", holdings.minterUnderlyingCollateral);
        console2.log("   minterPegged=%s", holdings.minterPegged);
        console2.log("   thisCollateral=%s", holdings.thisCollateral);
        console2.log("   thisPegged=%s", holdings.thisPegged);
        console2.log("   thisLeveraged=%s", holdings.thisLeveraged);
    }

    function logHoldings(string memory name, Holdings memory holdings) internal pure {
        console2.log("Holdings %s:", name);
        console2.log("   feeReceiverCollateral=%s", holdings.feeReceiverCollateral);
        console2.log("   reservePoolCollateral=%s", holdings.reservePoolCollateral);
        console2.log("   minterCollateral=%s", holdings.minterCollateral);
        console2.log("   minterUnderlyingCollateral=%s", holdings.minterUnderlyingCollateral);
        console2.log("   minterPegged=%s", holdings.minterPegged);
        console2.log("   thisCollateral=%s", holdings.thisCollateral);
        console2.log("   thisPegged=%s", holdings.thisPegged);
        console2.log("   thisLeveraged=%s", holdings.thisLeveraged);
    }

    function readHoldings() internal view returns (Holdings memory holdings) {
        holdings.feeReceiverCollateral = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        holdings.reservePoolCollateral = IERC20(wrappedCollateralToken).balanceOf(reservePool);
        holdings.minterCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);
        holdings.minterUnderlyingCollateral = IMinter(minter).collateralTokenBalance();
        holdings.minterPegged = IMinter(minter).peggedTokenBalance();
        holdings.thisCollateral = IERC20(wrappedCollateralToken).balanceOf(address(this));
        holdings.thisPegged = IERC20(peggedToken).balanceOf(address(this));
        holdings.thisLeveraged = IERC20(leveragedToken).balanceOf(address(this));
    }

    /// @param recordRoundUp How much further than `cambios` says the record may fall. A debit the minter rounds up from
    ///        an exact figure the test cannot see, while the wrapped that leaves is the same figure rounded down, can
    ///        take up to this much more from the record than left the holding. It never takes less: a record that gave
    ///        up less than the holding did would go on claiming the difference.
    function compareHoldings(
        Holdings memory antes,
        Holdings memory postres,
        DeltaHoldings memory cambios,
        uint256 recordRoundUp,
        string memory context
    ) internal pure {
        // logHoldings("before", antes);
        // logHoldings("after", postres);
        // logDeltaHoldings(cambios);
        assertEq(
            postres.feeReceiverCollateral,
            uint256(int256(antes.feeReceiverCollateral) + cambios.feeReceiverCollateral),
            string.concat(context, ":", "feeReceiverCollateral")
        );
        assertEq(
            postres.reservePoolCollateral,
            uint256(int256(antes.reservePoolCollateral) + cambios.reservePoolCollateral),
            string.concat(context, ":", "reservePoolCollateral")
        );
        assertEq(
            postres.minterCollateral,
            uint256(int256(antes.minterCollateral) + cambios.minterCollateral),
            string.concat(context, ":", "minterWrappedCollateral")
        );
        uint256 expectedRecord = uint256(int256(antes.minterUnderlyingCollateral) + cambios.minterUnderlyingCollateral);
        assertLe(
            postres.minterUnderlyingCollateral,
            expectedRecord,
            string.concat(context, ":", "minterUnderlyingCollateral gave up less than the holding")
        );
        assertGe(
            postres.minterUnderlyingCollateral + recordRoundUp,
            expectedRecord,
            string.concat(context, ":", "minterUnderlyingCollateral")
        );
        assertEq(
            postres.minterPegged,
            uint256(int256(antes.minterPegged) + cambios.minterPegged),
            string.concat(context, ":", "minterPegged")
        );
        assertEq(
            postres.thisCollateral,
            uint256(int256(antes.thisCollateral) + cambios.thisCollateral),
            string.concat(context, ":", "thisCollateral")
        );
        assertEq(
            postres.thisPegged,
            uint256(int256(antes.thisPegged) + cambios.thisPegged),
            string.concat(context, ":", "thisPegged")
        );
        assertEq(
            postres.thisLeveraged,
            uint256(int256(antes.thisLeveraged) + cambios.thisLeveraged),
            string.concat(context, ":", "thisLeveraged")
        );
    }

    struct Data {
        int256 incentiveRatio;
        uint256 peggedMinted;
        uint256 peggedRedeemed;
        uint256 leveragedMinted;
        uint256 levergedRedeemed;
        uint256 collateralUsed;
        uint256 collateralReturned;
        uint256 fee;
        uint256 subsidy;
        uint256 price;
        uint256 rate;
    }

    /// @dev The measurement at one point of the sweep. `collateralRatio` is the one the market reported when it was
    ///      placed there: the point's position on the sweep, which stays fixed even where the measurement moves the
    ///      market.
    function doOneCollateralRatio(uint256 collateralRatio) internal virtual;

    function setDown() internal virtual {}

    /// @dev Move the market to `requested` by pricing the collateral for it, and return the collateral ratio the
    ///      market then reports, which is the one each measurement records. For the swept points the two are equal;
    ///      a refined point between them may land a wei away, and the row should carry where the market
    ///      is rather than where it was asked to be. `MarketActions` reverts on a placement further off than
    ///      the derived price's own flooring allows.
    ///
    ///      Pricing the collateral is one of several ways to reach a collateral ratio, and a sweep that
    ///      needs another - the backing written down while the collateral's own price holds still -
    ///      overrides this. They are not interchangeable: what a deposit is worth depends on the
    ///      underlying price and on the wrapped-to-underlying rate, and a backing written down to what
    ///      is held depends on those AND on how much is still held, so the same collateral ratio
    ///      reached different ways prices a deposit differently.
    function _setCollateralRatio(uint256 requested) internal virtual returns (uint256 collateralRatio) {
        marketActions.setCollateralRatioByPrice(requested);
        collateralRatio = IMinter(minter).collateralRatio();
    }

    /// @inheritdoc GraphRefinement
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snap = vm.snapshotState();
        _setCollateralRatio(ratio);
        signals = refinementSignals();
        vm.revertToStateAndDelete(snap);
    }

    /// @inheritdoc GraphRefinement
    /// @dev Not guarded. Every revert a sweep expects is handled inside its own measurement, where the reason can
    ///      be checked, and a graph records such a point as a `NaN`, which gnuplot draws as a break in the line. A
    ///      revert that reaches here is therefore an error, and fails the test rather than costing a row unseen.
    function emitSampleAt(uint256 ratio) internal override {
        uint256 snap = vm.snapshotState();
        uint256 collateralRatio = _setCollateralRatio(ratio);
        doOneCollateralRatio(collateralRatio);
        vm.revertToStateAndDelete(snap);
    }

    /// @notice Every line the graph draws, for a graph that opts in by also setting a tolerance.
    /// @dev All of them, not one chosen: a stretch is only uninteresting if nothing drawn there is
    ///      doing anything, and a single chosen column would report a region as having nothing to say
    ///      while another line moved through it.
    function refinementSignals() internal virtual returns (int256[] memory) {
        return new int256[](0);
    }

    function test_allCollateralRatios() public virtual {
        assertEq(IMinter(minter).collateralRatio(), START_COLLATERAL_RATIO);

        console2.log("Testing collateral ratios from %s to %s by %s", start, finish, increment);
        bool refining = refinementTolerance() > 0;
        bool havePrevious;
        uint256 previousRatio;
        int256[] memory previousSignals;

        for (uint256 ratio = start; ratio <= finish; ratio += increment) {
            // Refinement needs the interval's far end before it can judge the interval, and its rows
            // belong between the two - so the swept point is measured, then the interval behind it is
            // filled in, and only then is the swept point itself recorded.
            if (refining) {
                int256[] memory signals = probeSignalsAt(ratio);
                if (havePrevious) {
                    refineBetween(previousRatio, previousSignals, ratio, signals);
                }
                previousRatio = ratio;
                previousSignals = signals;
                havePrevious = true;
            }

            emitSampleAt(ratio);
        }
        reportRefinement();
        setDown();
    }
}

// TODO: do a free comparison v fee'd comparison when fees are set to 0 and reserve pool is empty

contract TestCollateralRatioRangeTransfersNoReserve is TestCollateralRatioRangeSetUp {
    function setUp() public virtual override {
        super.setUp();
    }

    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        // collect the data and check against actuals
        Data memory data;
        Holdings memory beforeHolding;
        Holdings memory afterHolding;
        DeltaHoldings memory deltas;
        uint256 snap;

        // mint pegged: at or below the min CR the market mints none, whatever the config allows, and the mint
        // reverts naming the ratio it judged and the minimum
        (data.incentiveRatio, data.fee, data.collateralUsed, data.peggedMinted, , ) = IMinter(minter)
            .mintPeggedTokenDryRun(1 ether);

        if (collateralRatio <= IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()) {
            bytes memory belowMinimum = abi.encodeWithSelector(
                IMinter_v3.BelowMinimumCollateralRatio.selector,
                collateralRatio,
                IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
            );
            vm.expectRevert(belowMinimum);
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        } else {
            // minting pegged is allowed: this sweep's config disallows it nowhere above the min CR - the revert where
            // a config does is Minter_mint's to test
            assertLt(data.incentiveRatio, 1 ether, "the config allows minting pegged above the min CR");
            snap = vm.snapshotState();
            beforeHolding = readHoldings();
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
            afterHolding = readHoldings();
            deltas = DeltaHoldings(
                int256(data.fee),
                int256(0),
                int256(data.collateralUsed) - int256(data.fee),
                int256(data.collateralUsed) - int256(data.fee),
                int256(data.peggedMinted),
                -int256(data.collateralUsed),
                int256(data.peggedMinted),
                int256(0)
            );
            compareHoldings(beforeHolding, afterHolding, deltas, 0, "mintPegged");
            vm.revertToState(snap);
        }

        // redeem pegged
        data = Data(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        (, data.fee, data.subsidy, data.peggedRedeemed, data.collateralReturned, data.price, data.rate) = IMinter(
            minter
        ).redeemPeggedTokenDryRun(1000 ether);
        snap = vm.snapshotState();
        beforeHolding = readHoldings();
        IMinter(minter).redeemPeggedToken(1000 ether, address(this), 0);
        afterHolding = readHoldings();
        deltas = DeltaHoldings(
            int256(data.fee),
            -int256(data.subsidy),
            -int256(data.collateralReturned) + int256(data.subsidy) - int256(data.fee),
            -int256(data.collateralReturned) + int256(data.subsidy) - int256(data.fee),
            -int256(data.peggedRedeemed),
            int256(data.collateralReturned),
            -int256(data.peggedRedeemed),
            int256(0)
        );
        compareHoldings(beforeHolding, afterHolding, deltas, 0, "redeemPegged");
        vm.revertToState(snap);

        // mint leveraged: below the leverage cap's collateral-ratio floor the market sells no leverage, and the mint
        // reverts with that rule's error, naming the ratio it judged and the floor it wanted
        data = Data(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        uint256 minimumCollateralRatio = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        if (collateralRatio >= minimumCollateralRatio) {
            (, data.fee, data.subsidy, data.collateralUsed, data.leveragedMinted, , ) = IMinter(minter)
                .mintLeveragedTokenDryRun(1 ether);

            snap = vm.snapshotState();
            beforeHolding = readHoldings();
            IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);
            afterHolding = readHoldings();
            // logHoldings("before mint leveraged", beforeHolding);
            // logHoldings("after mint leveraged", afterHolding);
            deltas = DeltaHoldings(
                //int256 feeReceiverCollateral;
                int256(data.fee),
                // int256 reservePoolCollateral;
                -int256(data.subsidy),
                // int256 minterCollateral;
                int256(data.collateralUsed - data.fee + data.subsidy),
                // int256 minterUnderlyingCollateral;
                int256(data.collateralUsed - data.fee + data.subsidy),
                // int256 minterPegged;
                int256(0),
                // int256 thisCollateral;
                -int256(data.collateralUsed),
                // int256 thisPegged;
                int256(0),
                // int256 thisLeveraged;
                int256(data.leveragedMinted)
            );
            // logDeltaHoldings(deltas);
            compareHoldings(beforeHolding, afterHolding, deltas, 0, "mintLeveraged");
            vm.revertToState(snap);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMinter_v3.BelowMinimumCollateralRatio.selector,
                    collateralRatio,
                    minimumCollateralRatio
                )
            );
            IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);
        }

        // redeem leveraged: untouched by the cap, which governs only minting; depegged there is no residual to redeem
        if (collateralRatio > 1 ether) {
            data = Data(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
            (data.incentiveRatio, data.fee, data.levergedRedeemed, data.collateralReturned, , ) = IMinter(minter)
                .redeemLeveragedTokenDryRun(1000 ether);
            if (data.incentiveRatio < 1 ether) {
                snap = vm.snapshotState();
                beforeHolding = readHoldings();
                IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);
                afterHolding = readHoldings();
                deltas = DeltaHoldings(
                    int256(data.fee),
                    -int256(data.subsidy),
                    -int256(data.collateralReturned) + int256(data.subsidy) - int256(data.fee),
                    -int256(data.collateralReturned) + int256(data.subsidy) - int256(data.fee),
                    -int256(0),
                    int256(data.collateralReturned),
                    int256(0),
                    -int256(data.levergedRedeemed)
                );
                // The redemption debits the record its exact collateral removed rounded up, and pays out the same
                // figure rounded down: at the sweep's wrapped-to-underlying rate of 1 the two differ by a wei at most.
                compareHoldings(beforeHolding, afterHolding, deltas, 1, "redeemLeveraged");

                vm.revertToState(snap);
            }
        }
    }
}

contract TestCollateralRatioRangeTransfersWithReserve is TestCollateralRatioRangeTransfersNoReserve {
    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);
    }
}

contract TestCollateralRatioRangeTransfersWithPartialReserve is TestCollateralRatioRangeTransfersNoReserve {
    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1e15);
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////

contract TestCollateralRatioRangeIntegralNoReserve is TestCollateralRatioRangeSetUp {
    enum Action {
        MintPegged,
        RedeemPegged,
        MintLeveraged,
        RedeemLeveraged
    }

    uint repeats = 10;
    // One unit of each trade: the small side trades one unit `repeats` times, the large side `repeats` units once.
    uint256 internal constant COLLATERAL_PER_TRADE = 1 ether; // wrapped collateral offered to a mint
    uint256 internal constant PEGGED_PER_TRADE = 1000 ether; // pegged offered to a redemption
    uint256 internal constant LEVERAGED_PER_TRADE = 1000 ether; // leveraged offered to a redemption

    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function setUpRange() internal override {
        super.setUpRange();
        increment = 1 ether / 100;
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(repeats * 10, repeats * 10, address(this));
    }

    function makeDeltaHoldings(
        Holdings memory antes,
        Holdings memory postres
    ) internal pure returns (DeltaHoldings memory cambios) {
        cambios.feeReceiverCollateral = int256(postres.feeReceiverCollateral) - int256(antes.feeReceiverCollateral);
        cambios.reservePoolCollateral = int256(postres.reservePoolCollateral) - int256(antes.reservePoolCollateral);
        cambios.minterCollateral = int256(postres.minterCollateral) - int256(antes.minterCollateral);
        cambios.minterUnderlyingCollateral =
            int256(postres.minterUnderlyingCollateral) - int256(antes.minterUnderlyingCollateral);
        cambios.minterPegged = int256(postres.minterPegged) - int256(antes.minterPegged);
        cambios.thisCollateral = int256(postres.thisCollateral) - int256(antes.thisCollateral);
        cambios.thisPegged = int256(postres.thisPegged) - int256(antes.thisPegged);
        cambios.thisLeveraged = int256(postres.thisLeveraged) - int256(antes.thisLeveraged);
    }

    function addDeltaHoldings(
        DeltaHoldings memory changesSoFar,
        DeltaHoldings memory cambios
    ) internal pure returns (DeltaHoldings memory withNewChanges) {
        withNewChanges.feeReceiverCollateral = changesSoFar.feeReceiverCollateral + cambios.feeReceiverCollateral;
        withNewChanges.reservePoolCollateral = changesSoFar.reservePoolCollateral + cambios.reservePoolCollateral;
        withNewChanges.minterCollateral = changesSoFar.minterCollateral + cambios.minterCollateral;
        withNewChanges.minterUnderlyingCollateral =
            changesSoFar.minterUnderlyingCollateral + cambios.minterUnderlyingCollateral;
        withNewChanges.minterPegged = changesSoFar.minterPegged + cambios.minterPegged;
        withNewChanges.thisCollateral = changesSoFar.thisCollateral + cambios.thisCollateral;
        withNewChanges.thisPegged = changesSoFar.thisPegged + cambios.thisPegged;
        withNewChanges.thisLeveraged = changesSoFar.thisLeveraged + cambios.thisLeveraged;
    }

    /// @dev The market at a point of the sweep, read before its trades: what `compareDeltaHoldings` prices its
    ///      tolerances from.
    struct PointState {
        uint256 peggedPrice; // 1e18-scaled
        uint256 peggedPerCollateralWei; // the pegged wei one collateral wei of credit mints, rounded up
        uint256 leveragedPerCollateralWei; // the leveraged wei one collateral wei of credit mints, rounded up
        uint256 peggedSupply;
        uint256 leveragedSupply;
    }

    /// @dev How far each holding may move between the two sides of one comparison. Zero is an exact comparison.
    struct Tolerances {
        uint256 feeReceiverCollateral;
        uint256 reservePoolCollateral;
        uint256 minterCollateral;
        uint256 thisCollateral;
        uint256 pegged;
        uint256 leveraged;
    }

    /// @dev Compare `repeats` trades of one unit (`small`) with one trade of `repeats` units (`large`), holding by
    ///      holding, within what their roundings allow - derived from the code (MinterAdjustments_v1,
    ///      MinterValuationLib), not fitted to a run.
    ///
    ///      Each trade is priced exactly against the state it starts from and rounded once, the protocol's way, and
    ///      every trade compared here is path-independent in exact arithmetic: a mint at a token's own price leaves
    ///      that price where it is, a redemption pays at it, and a fee or subsidy is the integral of its bands over
    ///      the collateral moved. So the two sides differ by roundings alone. Where each trade's error lies in [0, b)
    ///      - one-signed, the protocol keeping the remainder - the difference is below `repeats x b`; where it lies in
    ///      (-b, b), below `(repeats + 1) x b`. A holding that moves by an amount the trade fixes is compared exactly.
    ///
    ///      One second-order term, `drift`, in collateral wei. Each small trade starts from a record of backing its
    ///      predecessors rounded, by under `recordRounding` collateral wei each (a wrapped wei's worth, then the
    ///      conversion's own floor). Such an offset reaches a later trade two ways: where the trade crosses a band's
    ///      bound it cuts it that far off, moving its fee or subsidy by the offset times the step between the two
    ///      bands' ratios; and where a token is priced off the backing - a pegged token below the peg, a leveraged
    ///      one always - it moves the trade's price by the offset times the share of the supply the trade moves. A
    ///      leveraged mint's own floor moves its token's price as well, by under one token in the supply.
    function compareDeltaHoldings(
        DeltaHoldings memory large,
        DeltaHoldings memory small,
        Action action,
        PointState memory point
    ) internal view {
        uint256 n = repeats;
        Tolerances memory t;
        uint256 recordRounding; // collateral wei, 1e18-scaled
        uint256 drift;
        uint256 wrappedDrift;
        {
            (, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            recordRounding = rate + 1 ether;
            IMinter.Config memory market = IMinter(minter).config();
            IMinter.IncentiveConfig memory bands = action == Action.MintPegged
                ? market.mintPeggedIncentiveConfig
                : action == Action.RedeemPegged
                    ? market.redeemPeggedIncentiveConfig
                    : action == Action.MintLeveraged
                        ? market.mintLeveragedIncentiveConfig
                        : market.redeemLeveragedIncentiveConfig;
            uint256 steepestStep;
            for (uint256 i = 1; i < bands.incentiveRatios.length; i++) {
                uint256 step = SignedMath.abs(bands.incentiveRatios[i] - bands.incentiveRatios[i - 1]);
                if (step > steepestStep) {
                    steepestStep = step;
                }
            }
            // the share of the supply one small trade moves, where the token it prices is priced off the backing
            uint256 tradeShare;
            if (action == Action.RedeemPegged && point.peggedPrice < 1 ether) {
                tradeShare = Math.mulDiv(PEGGED_PER_TRADE, 1 ether, point.peggedSupply, Math.Rounding.Ceil);
            } else if (action == Action.RedeemLeveraged) {
                tradeShare = Math.mulDiv(LEVERAGED_PER_TRADE, 1 ether, point.leveragedSupply, Math.Rounding.Ceil);
            }
            // the band channel takes the largest offset, at each bound; the price channel the offsets summed
            drift = Math.ceilDiv(
                bands.collateralRatioBandUpperBounds.length * (n - 1) * recordRounding * steepestStep +
                    ((n * (n - 1)) / 2) * recordRounding * tradeShare,
                1e36
            );
            wrappedDrift = Math.mulDiv(drift, 1 ether, rate, Math.Rounding.Ceil);
        }

        if (action == Action.MintPegged) {
            // the fee, and the backing's share of the offer it leaves: one floor each, one-signed
            t.feeReceiverCollateral = n + wrappedDrift;
            t.minterCollateral = n + wrappedDrift;
            // the tokens: the lesser of the walk's floored figure and the record's credit priced, the credit rounding
            // by under one collateral wei - below the exact figure by under one token and one credit's worth. Minted
            // only above the min CR, where the pegged price is one, so the backing does not price them
            t.pegged = n * (point.peggedPerCollateralWei + 1) + drift * point.peggedPerCollateralWei;
            // the offer is taken whole, the reserve takes no part, and leveraged does not move: exact
        } else if (action == Action.RedeemPegged) {
            // the payout: the floored figure, capped at the floored release plus the floored subsidy - under two wei
            t.thisCollateral = 2 * n + wrappedDrift;
            // the fee: what the release and the subsidy leave once the payout is taken - two-signed, under two wei
            t.feeReceiverCollateral = 2 * (n + 1) + wrappedDrift;
            // the subsidy, and the release: one floor each
            t.reservePoolCollateral = n + wrappedDrift;
            t.minterCollateral = n + wrappedDrift;
            // the pegged burned is the offer, and leveraged does not move: exact
        } else if (action == Action.MintLeveraged) {
            // the fee: the offer plus the floored subsidy less the floored collateral kept - two-signed, under one wei
            t.feeReceiverCollateral = n + 1 + wrappedDrift;
            // the subsidy, and the collateral kept: one floor each
            t.reservePoolCollateral = n + wrappedDrift;
            t.minterCollateral = n + wrappedDrift;
            // the tokens: the credit rounds by under `recordRounding` collateral wei, each buying
            // `leveragedPerCollateralWei`, the mint floors once more, and each earlier floor has raised the price by
            // under one token in the supply - one-signed
            t.leveraged =
                n * (Math.ceilDiv(recordRounding * point.leveragedPerCollateralWei, 1 ether) + 1) +
                drift * point.leveragedPerCollateralWei +
                Math.ceilDiv(
                    ((n * (n - 1)) / 2) * COLLATERAL_PER_TRADE * recordRounding * point.leveragedPerCollateralWei,
                    point.leveragedSupply * 1 ether
                );
            // the offer is taken whole, and pegged does not move: exact
        } else {
            // the payout: one floor
            t.thisCollateral = n + wrappedDrift;
            // the fee: the floored release less the payout - two-signed, under one wei
            t.feeReceiverCollateral = n + 1 + wrappedDrift;
            // the release: one floor
            t.minterCollateral = n + wrappedDrift;
            // the leveraged burned is the offer - this config disallows in no band, so every redemption takes its
            // whole claim - the reserve takes no part, and pegged does not move: exact
        }

        string memory context = toString(action);
        assertApproxEqAbs(
            large.feeReceiverCollateral,
            small.feeReceiverCollateral,
            t.feeReceiverCollateral,
            string.concat(context, ":", "feeReceiverCollateral")
        );
        assertApproxEqAbs(
            large.reservePoolCollateral,
            small.reservePoolCollateral,
            t.reservePoolCollateral,
            string.concat(context, ":", "reservePoolCollateral")
        );
        assertApproxEqAbs(
            large.minterCollateral,
            small.minterCollateral,
            t.minterCollateral,
            string.concat(context, ":", "minterCollateral")
        );
        assertApproxEqAbs(
            large.minterPegged,
            small.minterPegged,
            t.pegged,
            string.concat(context, ":", "minterPegged")
        );
        assertApproxEqAbs(
            large.thisCollateral,
            small.thisCollateral,
            t.thisCollateral,
            string.concat(context, ":", "thisCollateral")
        );
        assertApproxEqAbs(large.thisPegged, small.thisPegged, t.pegged, string.concat(context, ":", "thisPegged"));
        assertApproxEqAbs(
            large.thisLeveraged,
            small.thisLeveraged,
            t.leveraged,
            string.concat(context, ":", "thisLeveraged")
        );
    }

    function toString(Action action) internal pure returns (string memory s) {
        if (action == Action.MintPegged) s = "mintPegged";
        else if (action == Action.RedeemPegged) s = "redeemPegged";
        else if (action == Action.MintLeveraged) s = "mintLeveraged";
        else if (action == Action.RedeemLeveraged) s = "redeemLeveraged";
        else s = "unknown";
    }

    /// @dev `collateralRatio` is the one the market was placed at, which decides whether a leveraged action applies;
    ///      `peggedMintFits` says whether the whole pegged mint fits above the min CR from there.
    function doOne(
        Action action,
        uint multiple,
        DeltaHoldings memory changesSoFar,
        uint256 collateralRatio,
        bool peggedMintFits
    ) internal returns (DeltaHoldings memory withNewChanges) {
        // before
        Holdings memory antes = readHoldings();
        // do it
        if (action == Action.MintPegged) {
            // at or below the min CR the market mints no pegged, and a mint the min CR cuts is not `repeats` equal
            // parts of one, so there is nothing to compare
            if (peggedMintFits) {
                IMinter(minter).mintPeggedToken(multiple * COLLATERAL_PER_TRADE, address(this), 0);
            }
        } else if (action == Action.RedeemPegged) {
            IMinter(minter).redeemPeggedToken(multiple * PEGGED_PER_TRADE, address(this), 0);
        } else if (action == Action.MintLeveraged) {
            // below the leverage cap's collateral-ratio floor the market sells no leverage, so there is nothing to compare
            if (collateralRatio >= IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()) {
                IMinter(minter).mintLeveragedToken(multiple * COLLATERAL_PER_TRADE, address(this), 0);
            }
        } else if (action == Action.RedeemLeveraged) {
            // depegged there is no residual to redeem
            if (collateralRatio > 1 ether) {
                IMinter(minter).redeemLeveragedToken(multiple * LEVERAGED_PER_TRADE, address(this), 0);
            }
        }
        // after + changes
        DeltaHoldings memory cambios = makeDeltaHoldings(antes, readHoldings());
        withNewChanges = addDeltaHoldings(changesSoFar, cambios);
    }

    /// @dev For each action, one trade of `repeats` units against `repeats` trades of one unit, from the same state:
    ///      the holdings must move alike, within `compareDeltaHoldings`' derived tolerances. Each action is compared
    ///      on its own, from nothing.
    function doOneCollateralRatio(uint256 collateralRatio) internal virtual override(TestCollateralRatioRangeSetUp) {
        uint256 snap;
        // the dry run uses the whole offer only where the market is above the min CR and the mint is not cut at it
        (, , uint256 peggedMintUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(repeats * COLLATERAL_PER_TRADE);
        bool peggedMintFits = peggedMintUsed == repeats * COLLATERAL_PER_TRADE;

        PointState memory point;
        {
            (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            point.peggedPrice = IMinter(minter).peggedTokenPrice();
            uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
            // a market whose residual is gone prices its leveraged at nothing, and sells none
            point.peggedPerCollateralWei = Math.ceilDiv(price, point.peggedPrice);
            point.leveragedPerCollateralWei = leveragedPrice == 0 ? 0 : Math.ceilDiv(price, leveragedPrice);
            point.peggedSupply = IMinter(minter).peggedTokenBalance();
            point.leveragedSupply = IERC20(leveragedToken).totalSupply();
        }

        for (uint a = 0; a <= uint(type(Action).max); a++) {
            DeltaHoldings memory none;
            snap = vm.snapshotState();
            DeltaHoldings memory largeChanges = doOne(Action(a), repeats, none, collateralRatio, peggedMintFits);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            DeltaHoldings memory smallChanges = none;
            for (uint i = 0; i < repeats; i++) {
                smallChanges = doOne(Action(a), 1, smallChanges, collateralRatio, peggedMintFits);
            }
            compareDeltaHoldings(largeChanges, smallChanges, Action(a), point);
            vm.revertToState(snap);
        }
    }
}

contract TestCollateralRatioRangeIntegralWithReserve is TestCollateralRatioRangeIntegralNoReserve {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);
    }
}

contract TestCollateralRatioRangeIntegralWithPartialReserve is TestCollateralRatioRangeIntegralNoReserve {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1e15);
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////

/// @notice At every swept collateral ratio, each trade moves the holdings alike whether the market reached that
///         collateral ratio by a fall in the collateral price or by a recognised fall in the wrapped-to-underlying
///         rate with the price held. With the record written down to the holding, the collateral ratio is the wrapped
///         held times the wrapped price (price times rate) over the pegged supply. So the same collateral ratio,
///         holding and pegged supply fix the same wrapped price by either route: the same market, counted in wrapped
///         tokens. The record, kept in underlying tokens, follows the holding at each route's own rate.
contract TestCollateralRatioRangeRoutesNoReserve is TestCollateralRatioRangeIntegralNoReserve {
    /// @dev The wrapped-to-underlying rate at genesis, which the price route keeps.
    uint256 internal startRate;

    /// @dev One trade made from one route's market: what it moved, whether the whole pegged mint fitted above the min
    ///      CR there, and the market it was priced against - the collateral price and wrapped-to-underlying rate the
    ///      minter converted at, the two tokens' prices, and the backing counted in wrapped tokens.
    struct RouteTrade {
        DeltaHoldings changes;
        bool peggedMintFits;
        uint256 price;
        uint256 rate;
        uint256 peggedPrice;
        uint256 leveragedPrice;
        uint256 backingWrapped;
    }

    function setUp() public virtual override {
        super.setUp();
        (, , startRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev The sweep places the market by the price. Each trade is made from there, then from the same collateral
    ///      ratio reached by cutting the wrapped-to-underlying rate in proportion, which leaves the price the seam
    ///      derives at its genesis value.
    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        for (uint256 a = 0; a <= uint256(type(Action).max); a++) {
            string memory context = toString(Action(a));

            uint256 snap = vm.snapshotState();
            RouteTrade memory byPrice = _tradeOnce(Action(a), collateralRatio);
            vm.revertToState(snap);

            snap = vm.snapshotState();
            marketActions.setCollateralRatioByWrapRate(
                collateralRatio,
                (startRate * collateralRatio) / START_COLLATERAL_RATIO
            );
            // The rate route's price is floored when it is derived, so its collateral value is under one backing
            // wei's worth of price short of the target, and the reported collateral ratio, itself floored, lands on
            // the target or a wei below it - wherever the backing in collateral wei is no more than the pegged supply.
            assertLe(
                IMinter(minter).collateralTokenBalance(),
                IMinter(minter).peggedTokenBalance(),
                string.concat(
                    context,
                    ": the collateral ratio's bound is derived for a backing below the pegged supply"
                )
            );
            assertLe(
                IMinter(minter).collateralRatio(),
                collateralRatio,
                string.concat(context, ": the rate route is never above the price route's collateral ratio")
            );
            assertGe(
                IMinter(minter).collateralRatio() + 1,
                collateralRatio,
                string.concat(context, ": the rate route reaches the price route's collateral ratio")
            );
            // Recognition writes the record down to exactly what the holding converts to. Pinned here because the
            // comparison below cannot see below one underlying wei, which is the record's own resolution.
            {
                (, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
                assertEq(
                    IMinter(minter).collateralTokenBalance(),
                    Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), rate, 1 ether),
                    string.concat(context, ": recognition writes the record down to the holding")
                );
            }
            RouteTrade memory byRate = _tradeOnce(Action(a), collateralRatio);
            vm.revertToState(snap);

            assertEq(
                byRate.peggedMintFits,
                byPrice.peggedMintFits,
                string.concat(context, ": the pegged mint fits above the min CR by both routes alike")
            );
            _assertRecordFollowsTheHolding(byPrice, Action(a), string.concat(context, " by price"));
            _assertRecordFollowsTheHolding(byRate, Action(a), string.concat(context, " by rate"));
            assertLe(
                SignedMath.abs(byRate.changes.minterCollateral),
                byRate.backingWrapped,
                string.concat(context, ": the bounds below are derived for a trade smaller than the backing")
            );

            // How far each holding may differ between the routes. The rate route's backing is short of the price
            // route's by under one underlying wei counted in wrapped wei, `lostBacking`: the record is kept in whole
            // underlying wei, and recognition rounds it down. A payout pro rata to the backing takes its share of
            // that; an amount priced at the wrapped price differs by its share of the backing; and a band walk's
            // first slice, cut at a bound, moves under that much across the bound - each at most `lostBacking`
            // wrapped wei's worth, the trade being smaller than the backing. Each route's derived price is floored,
            // moving the wrapped price by under `1/price` (`_priceFloorReach`). And each side rounds its own
            // outputs, under the per-trade floors `compareDeltaHoldings` derives for one trade. A holding the trade
            // fixes - the offer taken whole, the tokens burned, a holding it does not touch - is compared exactly.
            Tolerances memory t;
            {
                uint256 lostBacking = Math.ceilDiv(1 ether, byRate.rate);
                if (Action(a) == Action.MintPegged) {
                    t.feeReceiverCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.feeReceiverCollateral, byPrice, byRate) +
                        1;
                    t.minterCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.minterCollateral, byPrice, byRate) +
                        1;
                    if (byPrice.peggedMintFits) {
                        // the credit is floored to a whole collateral wei, which buys `price / peggedPrice` pegged
                        (uint256 perWrappedByPrice, uint256 floorsByPrice) = _tokenBound(
                            byPrice,
                            byPrice.peggedPrice,
                            1 ether
                        );
                        (uint256 perWrappedByRate, uint256 floorsByRate) = _tokenBound(
                            byRate,
                            byRate.peggedPrice,
                            1 ether
                        );
                        t.pegged =
                            Math.max(perWrappedByPrice, perWrappedByRate) * lostBacking +
                            _priceFloorReach(byPrice.changes.minterPegged, byPrice, byRate) +
                            Math.max(floorsByPrice, floorsByRate);
                    }
                } else if (Action(a) == Action.RedeemPegged) {
                    t.thisCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.thisCollateral, byPrice, byRate) +
                        2;
                    // two-signed on each side
                    t.feeReceiverCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.feeReceiverCollateral, byPrice, byRate) +
                        4;
                    t.reservePoolCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.reservePoolCollateral, byPrice, byRate) +
                        1;
                    t.minterCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.minterCollateral, byPrice, byRate) +
                        1;
                } else if (Action(a) == Action.MintLeveraged) {
                    t.feeReceiverCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.feeReceiverCollateral, byPrice, byRate) +
                        2;
                    t.reservePoolCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.reservePoolCollateral, byPrice, byRate) +
                        1;
                    t.minterCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.minterCollateral, byPrice, byRate) +
                        1;
                    if (collateralRatio >= IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()) {
                        // the collateral kept is floored, then its credit: under `rate + 1` collateral wei, each
                        // buying `price / leveragedPrice` leveraged
                        (uint256 perWrappedByPrice, uint256 floorsByPrice) = _tokenBound(
                            byPrice,
                            byPrice.leveragedPrice,
                            byPrice.rate + 1 ether
                        );
                        (uint256 perWrappedByRate, uint256 floorsByRate) = _tokenBound(
                            byRate,
                            byRate.leveragedPrice,
                            byRate.rate + 1 ether
                        );
                        t.leveraged =
                            Math.max(perWrappedByPrice, perWrappedByRate) * lostBacking +
                            _priceFloorReach(byPrice.changes.thisLeveraged, byPrice, byRate) +
                            Math.max(floorsByPrice, floorsByRate);
                    }
                } else {
                    t.thisCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.thisCollateral, byPrice, byRate) +
                        1;
                    t.feeReceiverCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.feeReceiverCollateral, byPrice, byRate) +
                        2;
                    t.minterCollateral =
                        lostBacking +
                        _priceFloorReach(byPrice.changes.minterCollateral, byPrice, byRate) +
                        1;
                }
            }

            assertApproxEqAbs(
                byRate.changes.feeReceiverCollateral,
                byPrice.changes.feeReceiverCollateral,
                t.feeReceiverCollateral,
                string.concat(context, ":feeReceiverCollateral")
            );
            assertApproxEqAbs(
                byRate.changes.reservePoolCollateral,
                byPrice.changes.reservePoolCollateral,
                t.reservePoolCollateral,
                string.concat(context, ":reservePoolCollateral")
            );
            assertApproxEqAbs(
                byRate.changes.minterCollateral,
                byPrice.changes.minterCollateral,
                t.minterCollateral,
                string.concat(context, ":minterCollateral")
            );
            assertApproxEqAbs(
                byRate.changes.minterPegged,
                byPrice.changes.minterPegged,
                t.pegged,
                string.concat(context, ":minterPegged")
            );
            assertApproxEqAbs(
                byRate.changes.thisCollateral,
                byPrice.changes.thisCollateral,
                t.thisCollateral,
                string.concat(context, ":thisCollateral")
            );
            assertApproxEqAbs(
                byRate.changes.thisPegged,
                byPrice.changes.thisPegged,
                t.pegged,
                string.concat(context, ":thisPegged")
            );
            assertApproxEqAbs(
                byRate.changes.thisLeveraged,
                byPrice.changes.thisLeveraged,
                t.leveraged,
                string.concat(context, ":thisLeveraged")
            );
        }
    }

    /// @dev How far the two routes' price floors can move `change`: each route's collateral price is floored when it
    ///      is derived, so the collateral's value, and with it the wrapped price, is under `1/price` short on each side.
    function _priceFloorReach(
        int256 change,
        RouteTrade memory byPrice,
        RouteTrade memory byRate
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(
                SignedMath.abs(change),
                byPrice.price + byRate.price,
                byPrice.price * byRate.price,
                Math.Rounding.Ceil
            );
    }

    /// @dev For a token minted at `tokenPrice` on one route: how many of it one wrapped wei buys, and the floors its
    ///      mint takes - the credit falls under `creditShortfallE18 / 1e18` collateral wei short of the exact figure,
    ///      each collateral wei buying `price / tokenPrice` of the token, and the mint floors once more.
    function _tokenBound(
        RouteTrade memory trade,
        uint256 tokenPrice,
        uint256 creditShortfallE18
    ) internal pure returns (uint256 perWrappedWei, uint256 floors) {
        perWrappedWei = Math.ceilDiv(Math.mulDiv(trade.price, trade.rate, 1 ether), tokenPrice);
        floors = Math.ceilDiv(creditShortfallE18 * Math.ceilDiv(trade.price, tokenPrice), 1 ether) + 1;
    }

    /// @dev One unit of `action` from the market as it stands.
    function _tradeOnce(Action action, uint256 collateralRatio) internal returns (RouteTrade memory trade) {
        (trade.price, , trade.rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        trade.peggedPrice = IMinter(minter).peggedTokenPrice();
        trade.leveragedPrice = IMinter(minter).leveragedTokenPrice();
        trade.backingWrapped = Math.mulDiv(IMinter(minter).collateralTokenBalance(), 1 ether, trade.rate);
        (, , uint256 peggedMintUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(COLLATERAL_PER_TRADE);
        trade.peggedMintFits = peggedMintUsed == COLLATERAL_PER_TRADE;
        DeltaHoldings memory none;
        trade.changes = doOne(action, 1, none, collateralRatio, trade.peggedMintFits);
    }

    /// @dev The record follows the holding by the minter's rule, at the trade's rate: collateral coming in is credited
    ///      rounded down and collateral going out debited rounded up, so the record never claims more than the holding
    ///      stands up. A leveraged redemption rounds its debit up from an exact figure `E` that it pays out rounded
    ///      down, so it may take one wei more: for the `w` wrapped leaving, `w x rate <= E < (w + 1) x rate`, and
    ///      `ceil(a + b) <= ceil(a) + ceil(b)` adds at most one for `b = rate <= 1`.
    function _assertRecordFollowsTheHolding(
        RouteTrade memory trade,
        Action action,
        string memory context
    ) internal pure {
        assertLe(
            trade.rate,
            1 ether,
            string.concat(context, ": the record's bounds are derived for a rate of at most 1")
        );
        if (trade.changes.minterCollateral >= 0) {
            assertEq(
                trade.changes.minterUnderlyingCollateral,
                int256(Math.mulDiv(uint256(trade.changes.minterCollateral), trade.rate, 1 ether)),
                string.concat(context, ":minterUnderlyingCollateral credit")
            );
        } else {
            uint256 leastDebit = Math.mulDiv(
                uint256(-trade.changes.minterCollateral),
                trade.rate,
                1 ether,
                Math.Rounding.Ceil
            );
            uint256 debit = uint256(-trade.changes.minterUnderlyingCollateral);
            assertGe(
                debit,
                leastDebit,
                string.concat(context, ":minterUnderlyingCollateral gave up less than the holding")
            );
            assertLe(
                debit,
                action == Action.RedeemLeveraged ? leastDebit + 1 : leastDebit,
                string.concat(context, ":minterUnderlyingCollateral debit")
            );
        }
    }
}

/// @notice The same, with 1000 wrapped tokens in the reserve.
contract TestCollateralRatioRangeRoutesWithReserve is TestCollateralRatioRangeRoutesNoReserve {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);
    }
}

/// @notice The same, with only 1e15 wrapped tokens in the reserve.
contract TestCollateralRatioRangeRoutesWithPartialReserve is TestCollateralRatioRangeRoutesNoReserve {
    function setUp() public virtual override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1e15);
    }
}
