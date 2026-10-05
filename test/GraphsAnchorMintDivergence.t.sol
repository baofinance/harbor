// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice Graphs the pegged mint's divergence: how much pegged a unit of collateral value buys as the
/// collateral ratio falls, and what that does to the pegged supply.
///
/// The pegged is priced at `min(1, collateral ratio)` and the mint divides by that price, so pegged
/// minted per unit of collateral value is `1 / collateral ratio` and grows without bound as the
/// collateral ratio falls. That is the same shape as the leveraged conversion's `1 / (collateral ratio - 1)`,
/// at the other singularity, and the two are graphed in the same units so a single bound can be chosen
/// for both.
///
/// The supply multiplier is the second column because per-unit mispricing and supply growth are not the
/// same question, and the pegged's open question is the second one: minting at a depressed pegged price
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

    /// @dev Every production volatility config disallows pegged minting below a collateral ratio of about
    ///      1.31, so swept with those bands this graph would be one long gap. That band table is policy,
    ///      and policy is not what this graph is about: the divergence is in the contract's own pricing,
    ///      and the question it informs is what the contract should do when a config does not stop it.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function graphName() internal pure virtual returns (string memory);

    function setUp() public virtual override {
        super.setUp();
        (, , startRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        startHeld = IERC20(wrappedCollateralToken).balanceOf(minter);
        file = openFile(
            graphName(),
            sa(
                "collateral ratio",
                "anchor price",
                "anchor minted per unit of collateral value",
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
        uint256 peggedSupply = IMinter_v3(minter).peggedTokenBalance();

        lines = new int256[](3);
        lines[0] = int256(IMinter_v3(minter).peggedTokenPrice());
        lines[1] = NaN;
        lines[2] = NaN;

        if (peggedSupply == 0) {
            return lines;
        }

        // What the collateral going in is worth, priced from the market data rather than from the
        // minter's own valuation: a wrapped token is worth `wrappedRate` of the underlying and each of
        // those is worth `collateralPrice`. Taking it from the minter instead would make the answer
        // circular - minting pegged holds the collateral ratio still, so the minter's valuation of the
        // deposit is that collateral ratio times the pegged minted, and dividing one by the other could
        // only ever return 1 over the collateral ratio.
        (uint256 collateralPrice, , uint256 wrappedRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 valueIn = (COLLATERAL_IN * collateralPrice * wrappedRate) / (1 ether * 1 ether);
        if (valueIn == 0 || IERC20(wrappedCollateralToken).balanceOf(address(this)) < COLLATERAL_IN) {
            return lines;
        }

        // Never reverts in this sweep: the pegged price stays far above the smallest it can report, and every way the
        // ratio is moved leaves the record covered. So the mint is not caught, and a revert fails the test.
        uint256 snapshot = vm.snapshotState();
        uint256 peggedOut = IMinter_v3(minter).freeMintPeggedToken(COLLATERAL_IN, address(this));
        lines[1] = int256((peggedOut * 1 ether) / valueIn);
        lines[2] = int256(((peggedSupply + peggedOut) * 1 ether) / peggedSupply);
        vm.revertToState(snapshot);
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        int256[] memory lines = _lines();
        writeLine(file, ia(int256(collateralRatio), lines[0], lines[1], lines[2]));
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
/// worth fewer of the underlying than it was, so the record is written down to what the holding is now
/// worth while the underlying's own price is untouched and every token is still held.
///
/// This is the same sweep over the same collateral ratios and it is not the same measurement: the pegged
/// price is set by the written-down backing, while what a deposit is worth is set by the underlying price
/// AND that same wrapped-to-underlying rate. So this route moves both of them and a repricing moves both
/// of them, which is why neither changes what a deposit buys.
contract TestGraphsAnchorMintDivergenceByRate is TestGraphsAnchorMintDivergenceBase {
    function graphName() internal pure override returns (string memory) {
        return "anchor_mint_divergence_by_rate";
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    /// @dev Cutting the wrapped-to-underlying rate in proportion to the target collateral ratio leaves the
    ///      underlying price the seam derives where it started, so the collateral's own price does none of
    ///      the work.
    function _setCollateralRatio(uint256 requested) internal override returns (uint256 collateralRatio) {
        marketActions.setCollateralRatioByWrapRate(requested, (startRate * requested) / START_COLLATERAL_RATIO);
        collateralRatio = IMinter(minter).collateralRatio();
    }
}

/// @notice The collateral ratio falls because the collateral is GONE - neither repriced nor rewrapped at
/// a worse rate, but no longer held. The record still says it was received, which halts the market until
/// the owner recognises the loss and writes the record down to what is actually there.
///
/// This is the third way to reach a collateral ratio and the only one under which the pegged supply
/// diverges, because it is the only one that does not also reduce what a depositor's own tokens are
/// worth. Both the underlying price and the wrapped-to-underlying rate are untouched here, so a wrapped
/// token fetches exactly what it always did while the market behind the pegged has all but disappeared.
contract TestGraphsAnchorMintDivergenceByBacking is TestGraphsAnchorMintDivergenceBase {
    function graphName() internal pure override returns (string memory) {
        return "anchor_mint_divergence_by_backing";
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    function _setCollateralRatio(uint256 requested) internal override returns (uint256 collateralRatio) {
        deal(address(wrappedCollateralToken), minter, (startHeld * requested) / START_COLLATERAL_RATIO);
        // The record now claims collateral that is gone, and the views report the record: recognising the loss is
        // what moves the ratio. Below the starting ratio there is always something to recognise.
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        collateralRatio = IMinter(minter).collateralRatio();
        assertApproxEqAbs(
            collateralRatio,
            requested,
            Math.ceilDiv(IMinter(minter).collateralTokenBalance(), IMinter(minter).peggedTokenBalance()) + 1,
            "taking the collateral away must put the market at the requested collateral ratio"
        );
    }
}
