// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice Does a rebalance offer the same terms as the one before it?
///
/// A market does not fall once. It falls, is rebalanced, and falls again - and the question a stability pool
/// depositor is actually asking is whether being liquidated in the fourth round is worse than being
/// liquidated in the first. Every other measurement here samples a market once and cannot answer it: a sweep
/// across the collateral ratio compares DIFFERENT markets, one per point, each fresh from its genesis.
///
/// THE COLLATERAL RATIO IS PUT BACK TO THE SAME VALUE BEFORE EVERY REBALANCE. That is the whole design. Each
/// round therefore faces a market of identical HEALTH, so anything that changes between rounds is
/// accumulated state and nothing else - which is what hysteresis means and what makes this a controlled
/// experiment rather than a sequence of different situations.
///
/// A `phi` column is carried, and is zero: it was the escrow's value as a share of the pegged claim, the
/// state an escrow rule carried from round to round, and the files the escrow rules wrote have it. This tree
/// has no escrow, so the column reads zero, and is kept so that a run from this tree and a file from that era
/// compare column for column. The leverage a rule carries into the next round is the `leverage ratio before`
/// column, which is the reading that matters.
abstract contract HysteresisMeasurement is GraphTestBase, Array, MarketUnderTest {
    /// @dev Where each round starts. Below the peg by default, where the conversion is the only leg that can
    /// recapitalise and where the rules differ most; a run asking whether a rule holds its terms where it
    /// actually rebalances - above the leverage cap's floor, below the threshold - overrides it.
    function roundCollateralRatio() internal pure virtual returns (uint256) {
        return 0.6 ether;
    }

    /// @dev Far enough to find the END of the candidate's escrow floor, not just to show it holding. The
    /// leveraged price falls about 24x a round while the supply grows about 11x, so a price quoted in wei
    /// runs out: at round twelve it is 17 wei and the round after that it floors to zero. A sequence that
    /// stopped at twelve would report a rule that works.
    uint256 internal constant ROUNDS = 16;

    /// @dev The pool's share of the pegged supply, restored before EVERY round - see `_restorePoolShare`.
    ///
    /// Not all of it, and not a minority either: both are ruled out, from opposite directions. A pool holding
    /// ALL the pegged claims the whole collateral below the peg however much of its own it has burned, so its
    /// position cannot fall and the measurement is blind. A pool holding too LITTLE cannot complete a round:
    /// reaching the 1.3 threshold from 0.6 burns `1 - 0.6/1.3` = 53.85% of the supply, so anything under that
    /// empties first and the sequence stops after one. This sits above the 53.85% a round needs while leaving
    /// 40% of the pegged held outside the pool at every point a measurement is taken.
    uint256 internal constant LEVERAGED_POOL_SHARE = 0.6 ether;

    string internal hysteresisFile;
    address internal keeper;

    /// @inheritdoc GraphTestBase
    function context() internal view virtual override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    /// @dev Put the pool's holding back to its share of the CURRENT pegged supply, so that each round faces a
    /// market identical in COMPOSITION as well as in health - which is what makes anything differing between
    /// rounds accumulated state rather than a different situation.
    ///
    /// Without this there is no experiment to run. A round burns 53.85% of the supply reaching the threshold,
    /// so a pool that starts at any fixed share is left with a share of a SMALLER supply and cannot complete
    /// the next one: 0.6 becomes 0.133, and round two stops early. Only a pool holding everything is a fixed
    /// point, and that is the degenerate market this measurement exists to avoid.
    ///
    /// It is funded from the harness's own retained pegged by a real `deposit`, and the harness can always
    /// cover it, because whatever a round did not convert is still held here. No pegged is minted, so the
    /// market's collateral is untouched and the supply shrinks exactly as the rebalances left it.
    function _restorePoolShare() internal {
        uint256 target = Math.mulDiv(IMinter(market.minter).peggedTokenBalance(), LEVERAGED_POOL_SHARE, 1 ether);
        uint256 held = IERC20(market.pegged).balanceOf(market.leveragedPool);
        if (target <= held) {
            return;
        }
        uint256 topUp = Math.min(target - held, IERC20(market.pegged).balanceOf(address(this)));
        if (topUp > 0) {
            // The pool is a deployed v2 one or a v3 one, so the deposit goes through the base interface v2 implements,
            // whose `deposit` v3 carries too.
            IStabilityPool(market.leveragedPool).deposit(topUp, address(this), 0);
        }
    }

    /// @dev The collateral's price in the peg, derived from the minter's own getters rather than read off the
    /// oracle: the two markets wrap their collateral differently, and it is the minter's accounting that every
    /// other column here is denominated in. `collateralRatio` is `backing x price / peggedBalance`, so the
    /// price falls out of it exactly.
    function _collateralPrice() internal view returns (uint256) {
        uint256 backing = IMinter(market.minter).collateralTokenBalance();
        if (backing == 0) {
            return 0;
        }
        return
            Math.mulDiv(IMinter(market.minter).collateralRatio(), IMinter(market.minter).peggedTokenBalance(), backing);
    }

    /// @dev Wrapped collateral as the collateral it stands for, at the middle of the oracle's rate band: the rate a
    /// rebalance pays a pool at.
    function _wrappedAsCollateral(uint256 wrapped) internal view returns (uint256) {
        (, , uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(market.oracle).latestAnswer();
        return Math.mulDiv(wrapped, (minRate + maxRate + 1) / 2, 1 ether);
    }

    /// @dev What the leveraged stability pool's WHOLE position is worth, denominated in collateral.
    ///
    /// The peg is the one unit this measurement manipulates - the collateral ratio is put back before each
    /// round by writing the oracle price - so a figure in peg units carries the reset inside it and no two
    /// rounds can be compared. A collateral token is the yardstick instead: the reset writes only its price,
    /// and within a single round that price does not move at all, so dividing by it leaves the
    /// before-against-after comparison exact. A rebalance that mints leveraged tokens leaves the market's
    /// collateral where it is; one that pays the pool in collateral moves that collateral from the market to
    /// the pool, where it is counted as it stands.
    ///
    /// EVERY LEG IS COUNTED, and that is the point of measuring the position rather than the conversion: the
    /// pegged the pool keeps, the leveraged tokens it holds, and the collateral the rounds have paid it. A
    /// rebalance is partial, so the pool keeps pegged as well as being paid - and where burning the converted
    /// pegged lifts the collateral ratio, it marks the pegged the pool KEPT up with it. A figure covering only
    /// the converted increment cannot see that gain.
    /// @param collateralHeldAtTheStart The wrapped collateral the pool held before the first round, which no
    ///        round paid it and so is not part of the position measured.
    function _holdingInCollateral(uint256 collateralHeldAtTheStart) internal view returns (uint256 holding) {
        holding = _wrappedAsCollateral(
            IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool) - collateralHeldAtTheStart
        );
        uint256 collateralPrice = _collateralPrice();
        if (collateralPrice > 0) {
            uint256 valueInPeg = Math.mulDiv(
                IERC20(market.pegged).balanceOf(market.leveragedPool),
                IMinter_v3(market.minter).peggedTokenPrice(),
                1 ether
            ) +
                Math.mulDiv(
                    IERC20(market.leveraged).balanceOf(market.leveragedPool),
                    IMinter_v3(market.minter).leveragedTokenPrice(),
                    1 ether
                );
            holding += Math.mulDiv(valueInPeg, 1 ether, collateralPrice);
        }
    }

    function test_graph_hysteresis() public {
        hysteresisFile = openFile(
            "hysteresis",
            sa(
                "round",
                "CR before",
                "CR after",
                "leveraged price before",
                "leveraged price after",
                "leveraged returned",
                "value returned",
                "value given up",
                "value back per given",
                "phi",
                "leverage ratio before",
                "minter collateral",
                "holding before",
                "holding after",
                "collateral returned"
            )
        );
        keeper = makeAddr("keeper");
        standUpMarket(0, LEVERAGED_POOL_SHARE, context());
        uint256 collateralHeldAtTheStart = IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool);

        for (uint256 round = 1; round <= ROUNDS; round++) {
            // Back to the same health AND the same composition before every round, so the only thing that
            // differs between rounds is what the rounds before it left behind. Moving pegged between holders
            // changes neither the supply nor the collateral, so the order of these two does not matter.
            _restorePoolShare();
            actions.setCollateralRatioByPrice(roundCollateralRatio());

            uint256[] memory row = new uint256[](15);
            row[0] = round;
            row[1] = IMinter(market.minter).collateralRatio();
            row[3] = IMinter_v3(market.minter).leveragedTokenPrice();
            row[10] = IMinter_v3(market.minter).leverageRatio();

            if (!_canRebalance()) {
                break;
            }
            uint256 peggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
            uint256 leveragedBefore = IERC20(market.leveraged).balanceOf(market.leveragedPool);
            uint256 collateralBefore = IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool);
            uint256 peggedPriceBefore = IMinter_v3(market.minter).peggedTokenPrice();
            row[12] = _holdingInCollateral(collateralHeldAtTheStart);

            // A rule that REVERTS a leveraged mint at this ratio ends the sequence here, and that is the
            // reading: below its floor there is no rebalance to have, and a file with one row says so.
            if (!_rebalanceUnlessTheRuleReverts(keeper)) {
                break;
            }

            row[2] = IMinter(market.minter).collateralRatio();
            row[4] = IMinter_v3(market.minter).leveragedTokenPrice();
            row[5] = IERC20(market.leveraged).balanceOf(market.leveragedPool) - leveragedBefore;
            row[14] = IERC20(market.wrappedCollateral).balanceOf(market.leveragedPool) - collateralBefore;
            // Valued at the price ruling when each side moved: what came back at the price it is now worth - the
            // leveraged tokens at theirs, the collateral at the collateral's - and what went out at the price it
            // was worth when it was taken.
            row[6] =
                Math.mulDiv(row[5], row[4], 1 ether) +
                Math.mulDiv(_wrappedAsCollateral(row[14]), _collateralPrice(), 1 ether);
            row[7] = Math.mulDiv(
                peggedBefore - IERC20(market.pegged).balanceOf(market.leveragedPool),
                peggedPriceBefore,
                1 ether
            );
            row[8] = row[7] == 0 ? 0 : Math.mulDiv(row[6], 1 ether, row[7]);
            // `phi`: zero, this tree having no escrow - see the contract's note on why the column stays.
            row[9] = 0;
            // The market's whole collateral, recorded every round so the graph can check what a round did to it: a
            // round that mints leveraged tokens leaves it where it was, and one that pays the pool in collateral
            // lowers it by what it paid.
            row[11] = IMinter(market.minter).collateralTokenBalance();
            row[13] = _holdingInCollateral(collateralHeldAtTheStart);

            uint8[] memory decimals = new uint8[](15);
            decimals[0] = 0;
            for (uint256 i = 1; i < 15; i++) {
                decimals[i] = DEFAULT_DECIMALS;
            }
            writeLine(hysteresisFile, row, decimals);
        }
        vm.closeFile(hysteresisFile);
    }
}
