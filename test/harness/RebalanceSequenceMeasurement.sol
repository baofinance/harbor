// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {RatioSweepMeasurement} from "@harbor-test/harness/RatioSweepMeasurement.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice What repeated rebalances do to a market, swept across the collateral ratio.
///
/// The measurement and nothing else: it holds its loop and its columns, and asks `MarketUnderTest` for a
/// market rather than knowing how one is built. That is what lets the same rows be produced against the
/// local deploy chain and against the deployed proxies on a fork, with only the rule differing - and a
/// difference between two such files is then the rule, not the deployment.
abstract contract RebalanceSequenceMeasurement is GraphTestBase, Array, RatioSweepMeasurement {
    /// @dev The span, matching `liquidate_partial_*` so the two can be read against each other as shapes.
    uint256 internal constant SWEEP_TOP = 1.6 ether;
    uint256 internal constant SWEEP_POINTS = 160;

    /// @dev A guard against a rule that never converges - which is itself a finding, and shows as a run that
    /// uses every one of them.
    uint256 internal constant MAX_REBALANCES = 12;

    string internal sequenceFile;
    address internal keeper;

    /// @inheritdoc GraphTestBase
    function context() internal view override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    /// @dev Opened by the test that writes it, NEVER in `setUp`. `openFile` truncates and forge runs `setUp`
    /// before every test in a contract, so a file opened there is emptied again by the next test's setup and
    /// the suite finishes with only the last test's rows. Silent: the run passes and the picture is empty.
    function _openSequenceFile() internal {
        sequenceFile = openFile(
            "rebalance_sequence",
            sa(
                "start CR",
                "rebalance",
                "collateral ratio",
                "leverage ratio",
                "leveraged price",
                "pegged supply",
                "collateral pool pegged",
                "leveraged pool pegged",
                "leveraged returned",
                "leveraged value returned",
                "pegged value given up",
                "collateral returned",
                "collateral value returned"
            )
        );
    }

    /// @dev The pool is paid in leveraged tokens where the market mints them and in wrapped collateral where it
    ///      does not, so what it got back is the two together. The collateral is valued as the rebalance pays it:
    ///      at the middle of the rate band and of the price band.
    function _row(
        uint256 startCollateralRatio,
        uint256 rebalanceIndex,
        uint256 leveragedReturned,
        uint256 peggedValueGivenUp,
        uint256 collateralReturned
    ) internal {
        uint256 leveragedPrice = IMinter_v3(market.minter).leveragedTokenPrice();
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(market.oracle)
            .latestAnswer();

        uint256[] memory row = new uint256[](13);
        row[0] = startCollateralRatio;
        row[1] = rebalanceIndex;
        row[2] = IMinter(market.minter).collateralRatio();
        row[3] = IMinter_v3(market.minter).leverageRatio();
        row[4] = leveragedPrice;
        row[5] = IMinter(market.minter).peggedTokenBalance();
        row[6] = IERC20(market.pegged).balanceOf(market.collateralPool);
        row[7] = IERC20(market.pegged).balanceOf(market.leveragedPool);
        row[8] = leveragedReturned;
        row[9] = Math.mulDiv(leveragedReturned, leveragedPrice, 1 ether);
        row[10] = peggedValueGivenUp;
        row[11] = collateralReturned;
        row[12] = Math.mulDiv(
            Math.mulDiv(collateralReturned, (minRate + maxRate) / 2, 1 ether),
            (minPrice + maxPrice) / 2,
            1 ether
        );

        uint8[] memory decimals = new uint8[](13);
        decimals[0] = DEFAULT_DECIMALS;
        decimals[1] = 0;
        for (uint256 i = 2; i < 13; i++) {
            decimals[i] = DEFAULT_DECIMALS;
        }
        writeLine(sequenceFile, row, decimals);
    }

    /// @dev Rebalance until the market stops asking, recording every call. What the pool RECEIVED is read
    /// from its own balances rather than from what the call was asked for, because the manager clamps each
    /// leg before it redeems; and what it GAVE UP is valued at the price ruling before the call, because
    /// reading it afterwards values it at the restored ratio and overstates it - by about twice, at a
    /// starting ratio of a half.
    function _rebalanceUntilSettled(uint256 startCollateralRatio) internal {
        _row(startCollateralRatio, 0, 0, 0, 0);

        for (uint256 i = 1; i <= MAX_REBALANCES; i++) {
            if (!_canRebalance()) {
                return;
            }
            uint256 peggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
            uint256 leveragedBefore = IERC20(market.leveraged).balanceOf(market.leveragedPool);
            uint256 collateralBefore = IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool);
            uint256 peggedPriceBefore = IMinter_v3(market.minter).peggedTokenPrice();

            // A rule that REFUSES at this ratio ends the sequence: the row before it stands as the reading.
            if (!_rebalanceUnlessTheRuleRefuses(keeper)) {
                return;
            }

            _row(
                startCollateralRatio,
                i,
                IERC20(market.leveraged).balanceOf(market.leveragedPool) - leveragedBefore,
                Math.mulDiv(
                    peggedBefore - IERC20(market.pegged).balanceOf(market.leveragedPool),
                    peggedPriceBefore,
                    1 ether
                ),
                IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool) - collateralBefore
            );
        }
    }

    /// @notice One rebalance sequence from every collateral ratio in the span.
    ///
    /// @dev Every point starts from the market as it was founded, by snapshot, so no point inherits the
    /// liquidation the point before it performed - depth is the only dimension a sequence accumulates in.
    function test_graph_rebalanceSequence() public {
        _openSequenceFile();
        keeper = makeAddr("keeper");
        // A MINORITY of the founding pegged into the pool. This measurement reports what a rebalance hands
        // back, and below the peg the pegged claim is the whole collateral divided by holding - so a pool
        // holding every pegged token claims the entire market however much of its own a conversion burned,
        // and what it gave up cannot be seen. The remainder stays with the harness, holding pegged outside
        // the pools.
        standUpMarket(0, 0.4 ether, context());

        sweepCollateralRatios();
        vm.closeFile(sequenceFile);
    }

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    /// @dev This sweep writes a VARIABLE NUMBER OF ROWS per point - one per rebalance pass - so there is no
    /// single row for refinement to judge. What it judges instead is what the graph plots per point: where
    /// the FIRST rebalance left the ratio, what it handed back, and HOW MANY passes the sequence took. The
    /// last of those is what makes this sweep worth refining at all - the pass count steps from one to many
    /// at the ratio where a pool stops being able to finish in a single call, and a step is invisible at a
    /// uniform 0.01.
    ///
    /// A point where nothing could be done has no first rebalance to describe, which is a gap rather than a
    /// zero: below the reach floor the pool cannot move the market at all.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snapshot = vm.snapshotState();
        actions.setCollateralRatioByPrice(ratio);

        uint256 passes;
        uint256 ratioAfterFirst;
        uint256 returnedByFirst;
        uint256 leveragedBefore = IERC20(market.leveraged).balanceOf(market.leveragedPool);

        while (passes < MAX_REBALANCES && _canRebalance()) {
            if (!_rebalanceUnlessTheRuleRefuses(keeper)) {
                break;
            }
            passes++;
            if (passes == 1) {
                ratioAfterFirst = IMinter(market.minter).collateralRatio();
                returnedByFirst = IERC20(market.leveraged).balanceOf(market.leveragedPool) - leveragedBefore;
            }
        }
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](3);
        signals[0] = passes == 0 ? SIGNAL_UNAVAILABLE : int256(ratioAfterFirst);
        signals[1] = passes == 0 ? SIGNAL_UNAVAILABLE : int256(returnedByFirst);
        signals[2] = int256(passes * 1 ether);
    }

    function emitSampleAt(uint256 ratio) internal override {
        // Every point starts from the market as founded, so no point inherits the sequence before it.
        uint256 snapshot = vm.snapshotState();
        actions.setCollateralRatioByPrice(ratio);
        _rebalanceUntilSettled(ratio);
        vm.revertToStateAndDelete(snapshot);
    }
}
