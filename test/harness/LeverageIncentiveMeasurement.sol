// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {RatioSweepMeasurement} from "@harbor-test/harness/RatioSweepMeasurement.sol";
import {RevertReason} from "@harbor-test/RevertReason.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice WHERE THE INCENTIVES POINT, against where the damage is.
///
/// Every other measurement here asks what a rule DOES. This one asks what a user would CHOOSE to do, and
/// whether those two line up. They do not, and the mismatch belongs to the escrow rather than to any
/// conversion rule - minting and redeeming behave identically under all three, so this graph reads the same
/// for each.
///
/// THE QUANTITY IS `backing / escrow`, WHICH IS THE MAXIMUM LEVERAGE. Measured at exactly 20.0000 on a fresh
/// market and attained exactly at the peg. Minting moves collateral INTO the escrow and pushes it down;
/// redeeming releases escrow and pushes it back up. Neither is a defect on its own - the question is whether
/// the flow a rational user generates leaves it where it found it.
///
/// WHERE A USER WOULD ACT:
///
///   - a BUYER of leveraged exposure mints where leverage is cheapest per unit, which is AT THE PEG, since
///     `beta` is 20 there and falls monotonically above it;
///   - a HOLDER TAKING PROFIT redeems after the collateral has risen, which is AT HIGH `CR`.
///
/// WHERE THE DAMAGE IS. The share of a mint that lands in the escrow is `E/(R+E)` with `R = B(CR-1)/CR`, so
/// it is EVERYTHING at the peg and a tenth of it by a ratio of two. The gain from redeeming is
/// `(1 - (R/B)x)/(1-x)`, strongest at the peg and weakest high up - but it varies only about twofold across
/// the range where the mint's damage varies eightfold.
///
/// SO THE ARROWS POINT THE WRONG WAY THROUGH BOTH CURVES: users arrive where they hurt the figure most and
/// leave where they help it least. Both legs are measured here at the SAME COLLATERAL VALUE so the two are
/// directly comparable rather than being a mint and a redeem of unrelated size.
abstract contract LeverageIncentiveMeasurement is GraphTestBase, Array, RevertReason, RatioSweepMeasurement {
    uint256 internal constant SWEEP_TOP = 2.4 ether;
    uint256 internal constant SWEEP_POINTS = 120;

    /// @dev The size of both legs, as a share of ALL the collateral the market holds - backing and escrow
    /// together. One percent: large enough to move the figure by something readable, small enough that it is
    /// a local slope rather than a restructuring of the market.
    uint256 internal constant LEG_SHARE = 0.01 ether;

    string internal incentiveFile;

    /// @inheritdoc GraphTestBase
    function context() internal view override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    function test_graph_leverageIncentive() public {
        incentiveFile = openFile(
            "leverage_incentive",
            sa(
                "collateral ratio",
                "max leverage",
                "max leverage after a mint",
                "max leverage after a redeem",
                "mint cost",
                "redeem gain",
                "escrow share of a mint",
                "measured beta"
            )
        );
        standUpMarket(0, 0.4 ether, context());
        IERC20(market.wrappedCollateral).approve(market.minter, type(uint256).max);
        IERC20(market.leveraged).approve(market.minter, type(uint256).max);

        sweepCollateralRatios();
        vm.closeFile(incentiveFile);
    }

    /// @dev The two curves, plus the leverage they act on. The cost and the gain are what the graph is FOR,
    /// so they are what refinement resolves.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snapshot = vm.snapshotState();
        Incentive memory it = _measureAt(ratio);
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](3);
        signals[0] = it.maxLeverage == 0 ? SIGNAL_UNAVAILABLE : int256(it.maxLeverage);
        signals[1] = it.mintCost == 0 ? SIGNAL_UNAVAILABLE : int256(it.mintCost);
        signals[2] = it.redeemGain == 0 ? SIGNAL_UNAVAILABLE : int256(it.redeemGain);
    }

    function emitSampleAt(uint256 ratio) internal override {
        uint256 snapshot = vm.snapshotState();
        Incentive memory it = _measureAt(ratio);

        uint256[] memory row = new uint256[](8);
        row[0] = it.collateralRatio;
        row[1] = it.maxLeverage;
        row[2] = it.leverageAfterMint;
        row[3] = it.leverageAfterRedeem;
        row[4] = it.mintCost;
        row[5] = it.redeemGain;
        row[6] = it.escrowShareOfMint;
        row[7] = it.beta;
        writeLine(incentiveFile, row);

        vm.revertToStateAndDelete(snapshot);
    }

    struct Incentive {
        uint256 collateralRatio;
        uint256 maxLeverage;
        uint256 leverageAfterMint;
        uint256 leverageAfterRedeem;
        uint256 mintCost;
        uint256 redeemGain;
        uint256 escrowShareOfMint;
        uint256 beta;
    }

    function _measureAt(uint256 ratio) private returns (Incentive memory it) {
        setMarketCollateralRatio(ratio);
        it.collateralRatio = IMinter(market.minter).collateralRatio();
        it.maxLeverage = _maxLeverage();
        it.beta = IMinter_v3(market.minter).leverageRatio();

        uint256 leg = Math.mulDiv(
            IMinter(market.minter).collateralTokenBalance() + reader.escrowCollateral(market.minter),
            LEG_SHARE,
            1 ether
        );

        // ─── the mint leg ───
        uint256 snap = vm.snapshotState();
        uint256 escrowBefore = reader.escrowCollateral(market.minter);
        deal(market.wrappedCollateral, address(this), leg);
        try IMinter_v3(market.minter).freeMintLeveragedToken(leg, address(this)) returns (uint256) {
            it.leverageAfterMint = _maxLeverage();
            // How much of the deposit landed in the escrow rather than the backing - the mechanism the cost
            // curve is made of, reported beside it so the graph shows the cause next to the effect.
            it.escrowShareOfMint = leg == 0
                ? 0
                : Math.mulDiv(reader.escrowCollateral(market.minter) - escrowBefore, 1 ether, leg);
        } catch (bytes memory err) {
            _tolerate(err);
        }
        vm.revertToStateAndDelete(snap);

        // ─── the redeem leg, at the SAME collateral value so the two compare ───
        snap = vm.snapshotState();
        uint256 price = IMinter_v3(market.minter).leveragedTokenPrice();
        uint256 collateralPrice = _collateralPrice();
        if (price > 0 && collateralPrice > 0) {
            // Tokens whose claim is worth `leg` of collateral: value in the peg is `leg x collateralPrice`,
            // and each token is worth `price` of it.
            uint256 tokens = Math.mulDiv(Math.mulDiv(leg, collateralPrice, 1 ether), 1 ether, price);
            uint256 held = IERC20(market.leveraged).balanceOf(address(this));
            if (tokens > held) {
                tokens = held;
            }
            if (tokens > 0) {
                try IMinter_v3(market.minter).freeRedeemLeveragedToken(tokens, address(this)) returns (uint256) {
                    it.leverageAfterRedeem = _maxLeverage();
                } catch (bytes memory err) {
                    _tolerate(err);
                }
            }
        }
        vm.revertToStateAndDelete(snap);

        // Both as FRACTIONS of the leverage they started from, so a market whose absolute figure has drifted
        // is still comparable with one that has not.
        if (it.maxLeverage > 0) {
            it.mintCost = it.leverageAfterMint >= it.maxLeverage
                ? 0
                : Math.mulDiv(it.maxLeverage - it.leverageAfterMint, 1 ether, it.maxLeverage);
            it.redeemGain = it.leverageAfterRedeem <= it.maxLeverage
                ? 0
                : Math.mulDiv(it.leverageAfterRedeem - it.maxLeverage, 1 ether, it.maxLeverage);
        }
    }

    /// @dev `backing / escrow` - the maximum leverage the market can offer, attained at the peg.
    function _maxLeverage() private view returns (uint256) {
        uint256 escrow = reader.escrowCollateral(market.minter);
        return escrow == 0 ? 0 : Math.mulDiv(IMinter(market.minter).collateralTokenBalance(), 1 ether, escrow);
    }

    /// @dev The collateral's price in the peg, from the minter's own getters - `collateralRatio` is
    /// `backing x price / peggedBalance`, so the price falls out of it exactly.
    function _collateralPrice() private view returns (uint256) {
        uint256 backing = IMinter(market.minter).collateralTokenBalance();
        if (backing == 0) {
            return 0;
        }
        return
            Math.mulDiv(
                IMinter(market.minter).collateralRatio(),
                IMinter(market.minter).peggedTokenBalance(),
                backing
            );
    }

    /// @dev The two located limits a leg may legitimately hit - a leg that would hand back nothing, and a
    /// price that has reached the pole. Anything else propagates.
    function _tolerate(bytes memory err) private pure {
        if (
            bytes4(err) != IMinter_v3.ReturnZeroAmount.selector &&
            bytes4(err) != IMinter_v3.LeverageAboveCap.selector &&
            !_isPanic(err, PANIC_DIVIDE_BY_ZERO)
        ) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}
