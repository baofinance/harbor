// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice Graphs the anchor mint's divergence: how much anchor a unit of collateral value buys as the
/// collateral ratio falls, and what that does to the anchor supply.
///
/// The anchor is priced at `min(1, collateral ratio)` and the mint divides by that price, so anchor
/// issued per unit of collateral value is `1 / collateral ratio` and grows without bound as the
/// collateral ratio falls. That is the same shape as the sail conversion's `1 / (collateral ratio - 1)`,
/// at the other singularity, and the two are graphed in the same units so a single bound can be chosen
/// for both.
///
/// The supply multiplier is the second column because per-unit mispricing and supply growth are not the
/// same question, and the anchor's open question is the second one: minting at a depressed anchor price
/// leaves the collateral ratio where it was and dilutes nobody's claim, so what matters is containment.
///
/// Every point is MEASURED, by minting and reading what came out.
abstract contract TestGraphsAnchorMintDivergenceBase is GraphTestBase, TestCollateralRatioRangeSetUp {
    /// @dev One wrapped collateral token per mint. A deposit is made in tokens, not in value, and which
    ///      of the two is held fixed decides what the supply multiplier does - so it is fixed at the
    ///      thing a depositor actually hands over.
    uint256 private constant COLLATERAL_IN = 1 ether;

    /// @dev The wrapped-to-underlying rate the market is deployed at, which a rate-driven sweep moves.
    uint256 internal startRate;

    /// @dev The wrapped collateral the market actually holds at deployment, which a backing-driven sweep
    ///      takes away.
    uint256 internal startHeld;

    string private file;

    /// @dev Every production volatility config disallows anchor minting below a collateral ratio of about
    ///      1.31, so swept with those bands this graph would be one long gap. That band table is policy,
    ///      and policy is not what this graph is about: the divergence is in the contract's own pricing,
    ///      and the question it informs is what the contract should do when a config does not stop it.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function graphName() internal pure virtual returns (string memory);

    /// @dev Swept above two, where a market is comfortably covered and the divergence ought to vanish - a
    /// measurement that only ever looks at distress cannot show where distress begins.
    ///
    /// All three mechanisms reach all of it, which is what makes them comparable at every ratio drawn. A
    /// price and a rate move the ratio either way and need no help; taking the collateral away can only
    /// LOWER it, so the market is opened above the top of this range for all three alike - see `setUp`.
    /// Raising the funding for that one mechanism alone would have been the mistake: their pegged supplies
    /// would then start from different markets and the comparison between them would mean nothing.
    function setUpRange() internal virtual override {
        super.setUpRange();
        finish = 2.5 ether;
    }

    function setUp() public virtual override {
        super.setUp();
        // Opened ABOVE the top of the range, so that all three mechanisms sweep the same ratios and can be
        // read against each other across the whole of it. Two of them move the ratio either way and need no
        // headroom; taking the collateral away can only lower it, so without this the backing-driven line
        // would stop where the market opened and there would be nothing to compare the other two against
        // above that point. Funded here rather than per mechanism: they must be funded ALIKE or their pegged
        // supplies are not comparable, which is the entire measurement.
        setUp_collateral(0, 10 ether, address(this));
        startCollateralRatio = IMinter(minter).collateralRatio();

        (, , startRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        startHeld = IERC20(wrappedCollateralToken).balanceOf(minter);
        file = openFile(
            graphName(),
            sa(
                "collateral ratio",
                "anchor price",
                "anchor issued per unit of collateral value",
                "anchor supply multiplier"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    /// @dev One percent of a line's own size: these lines run over five hundredfold on a logarithmic
    ///      axis, where equal proportions rather than equal differences are equal distances.
    function refinementTolerance() internal pure override returns (uint256) {
        return 0.01 ether;
    }

    /// @dev Everything this graph draws at the market's current collateral ratio, in the order the header
    ///      names. Shared by the recording and by refinement, so what is judged is exactly what is drawn.
    function _lines() private returns (int256[] memory lines) {
        uint256 anchorSupply = IMinter_v3(minter).peggedTokenBalance();

        lines = new int256[](3);
        lines[0] = int256(IMinter_v3(minter).peggedTokenPrice());
        lines[1] = NaN;
        lines[2] = NaN;

        if (anchorSupply == 0) {
            return lines;
        }

        // What the collateral going in is worth, priced from the market data rather than from the
        // minter's own valuation: a wrapped token is worth `wrappedRate` of the underlying and each of
        // those is worth `collateralPrice`. Taking it from the minter instead would make the answer
        // circular - minting anchor holds the collateral ratio still, so the minter's valuation of the
        // deposit is that collateral ratio times the anchor issued, and dividing one by the other could
        // only ever return 1 over the collateral ratio.
        (uint256 collateralPrice, , uint256 wrappedRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 valueIn = (COLLATERAL_IN * collateralPrice * wrappedRate) / (1 ether * 1 ether);
        if (valueIn == 0 || IERC20(wrappedCollateralToken).balanceOf(address(this)) < COLLATERAL_IN) {
            return lines;
        }

        uint256 snapshot = vm.snapshotState();
        try IMinter_v3(minter).freeMintPeggedToken(COLLATERAL_IN, address(this)) returns (uint256 anchorOut) {
            lines[1] = int256((anchorOut * 1 ether) / valueIn);
            lines[2] = int256(((anchorSupply + anchorOut) * 1 ether) / anchorSupply);
        } catch {
            // the mint is refused here; a gap says so
        }
        vm.revertToState(snapshot);
    }

    function doOneCollateralRatio() internal override {
        int256[] memory lines = _lines();
        writeLine(file, ia(int256(currentCollateralRatio), lines[0], lines[1], lines[2]));
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    function refinementSignals() internal override returns (int256[] memory) {
        return _lines();
    }
}

/// @notice The collateral ratio falls because the collateral is worth less - its price drops, while the
/// market still holds every token it was given and the wrapped-to-underlying rate is untouched.
contract TestGraphsAnchorMintDivergence is TestGraphsAnchorMintDivergenceBase {
    function graphName() internal pure override returns (string memory) {
        return "anchor_mint_divergence";
    }
}

/// @notice The collateral ratio falls because the WRAPPED-TO-UNDERLYING RATE falls - the wrapper is
/// worth fewer of the underlying than it was, so the recognised backing shrinks while the underlying's
/// own price is untouched and every token is still held.
///
/// This is the same sweep over the same collateral ratios and it is not the same measurement: the anchor
/// price is set by the recognised backing, while what a deposit is worth is set by the underlying price
/// AND that same wrapped-to-underlying rate. So this route moves both of them and a repricing moves both
/// of them, which is why neither changes what a deposit buys.
contract TestGraphsAnchorMintDivergenceByRate is TestGraphsAnchorMintDivergenceBase, HarborTestActions {
    function graphName() internal pure override returns (string memory) {
        return "anchor_mint_divergence_by_rate";
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    /// @dev Cutting the wrapped-to-underlying rate in proportion to the target collateral ratio leaves the
    ///      underlying price the seam derives where it started, so the collateral's own price does none of
    ///      the work.
    function _setCollateralRatio(uint256 requested) internal override {
        currentPrice = setCollateralRatioByRate(
            minter,
            priceOracle,
            requested,
            (startRate * requested) / startCollateralRatio
        );
        currentCollateralRatio = IMinter(minter).collateralRatio();
    }
}

/// @notice The collateral ratio falls because the collateral is GONE - neither repriced nor rewrapped at
/// a worse rate, but no longer held. The record still says it was received, so the recognised backing
/// falls to what is actually there.
///
/// This is the third way to reach a collateral ratio and the only one under which the anchor supply
/// diverges, because it is the only one that does not also reduce what a depositor's own tokens are
/// worth. Both the underlying price and the wrapped-to-underlying rate are untouched here, so a wrapped
/// token fetches exactly what it always did while the market behind the anchor has all but disappeared.
contract TestGraphsAnchorMintDivergenceByBacking is TestGraphsAnchorMintDivergenceBase {
    function graphName() internal pure override returns (string memory) {
        return "anchor_mint_divergence_by_backing";
    }

    /// @dev A guard, not a working limit: the market is opened above the whole range precisely so this never
    /// binds. It stays because the constraint it encodes is real - removing collateral can only LOWER the
    /// ratio - and because the alternative, leaving the overshoot to the refusal machinery, does not work
    /// here: refinement probes each interval OUTSIDE the try that catches a refused sample.
    function setUp() public virtual override {
        super.setUp();
        if (finish > startCollateralRatio) {
            finish = startCollateralRatio;
        }
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    /// @dev Two steps, because the protocol takes two. Removing the collateral does not move the record -
    /// the record says it was received and only `recogniseImpairment` is entitled to say otherwise, which is
    /// why every price and ratio reads the same until it is called. The contract used to floor the record
    /// against the holding on every read and so appeared to do this in one step; that flooring was a
    /// judgement made on every read, and removing it is what made the second step explicit rather than
    /// implicit. Each sample is snapshotted and rolled back by `emitSampleAt`, so a write-down here cannot
    /// carry into the next point - which matters, because recognition only ever writes DOWN.
    function _setCollateralRatio(uint256 requested) internal override {
        // Removing collateral can only lower the ratio, so anything above where the market opened is not
        // reachable by this mechanism at all. Refused rather than approximated: the sweep leaves the point
        // out and the line stops where the mechanism stops working, which is the honest report.
        if (requested > startCollateralRatio) {
            revert("backing-driven sweep cannot raise the collateral ratio");
        }
        deal(address(wrappedCollateralToken), minter, (startHeld * requested) / startCollateralRatio);
        // Near the top of the range the deal leaves barely anything to recognise, and at the opening ratio
        // nothing at all - so the one revert that means "the records already match the holding" is the
        // expected answer there rather than a failure. Any other revert is a real one and propagates.
        vm.prank(owner());
        try IMinter_v3(minter).recogniseImpairment() {} catch (bytes memory reason) {
            require(bytes4(reason) == IMinter_v3.NothingToRecognise.selector, "unexpected recognition failure");
        }
        currentCollateralRatio = IMinter(minter).collateralRatio();
        assertApproxEqAbs(
            currentCollateralRatio,
            requested,
            Math.ceilDiv(IMinter(minter).collateralTokenBalance(), IMinter(minter).peggedTokenBalance()) + 1,
            "taking the collateral away must put the market at the requested collateral ratio"
        );
    }
}
