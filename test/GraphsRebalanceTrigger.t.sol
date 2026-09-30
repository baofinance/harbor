// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice Graphs the conversion rate the anchor-to-sail conversion actually applies against the
/// conversion rate that would be fair, across the collateral ratio.
///
/// A conversion rate here is sail minted per unit of anchor value, and the fair one is the reciprocal of
/// the sail price. The bound is a ceiling on that conversion rate, so it should engage where the fair
/// conversion rate crosses it. It engages on the reported LEVERAGE ratio instead - the same comparison
/// taken against the collateral value rather than against the sail supply. The two agree only if those
/// two quantities are equal, which nothing maintains, so between the collateral ratio where the bound
/// engages and the collateral ratio where it starts costing the pool value, the conversion is active but
/// mints MORE sail than fairness requires - diluting existing sail holders in the pool's favour. This
/// graph is that band, measured.
///
/// The applied conversion rate is measured by putting anchor through the conversion itself and dividing
/// the sail received by the anchor given up, rather than recomputed here from the same inputs the
/// contract uses: a recomputation would agree with the implementation by construction and show nothing.
contract TestGraphsRebalanceTrigger is GraphTestBase, TestCollateralRatioRangeSetUp {
    /// @dev One anchor token, so the sail received IS the applied conversion rate. Small against the
    ///      pool, so what is measured is the conversion rate a conversion faces rather than one its own
    ///      size has moved.
    uint256 private constant ANCHOR_IN = 1 ether;

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "rebalance_trigger_mismatch",
            sa(
                "collateral ratio",
                "reported leverage ratio",
                "fair conversion rate (1 over sail price)",
                "applied conversion rate (measured)",
                "applied over fair conversion rate"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    /// @dev One percent of a line's own magnitude. Relative rather than absolute because the lines run
    ///      from under 2 to 500 and are drawn on a logarithmic axis, where equal proportions are equal
    ///      distances. The drop at disengagement moves a line by about five percent of itself, so it is
    ///      caught; a line rising in a straight line needs no help however steeply it climbs.
    function refinementTolerance() internal pure override returns (uint256) {
        return 0.01 ether;
    }

    /// @dev Everything this graph draws at the market's current collateral ratio, in the order the header
    ///      names. Shared by the recording and by refinement, so what is judged is exactly what is drawn.
    function _lines() private returns (int256[] memory lines) {
        uint256 sailPrice = IMinter_v3(minter).leveragedTokenPrice();

        // At and below a collateral ratio of 1 the residual behind the sail token is zero, so the fair
        // conversion rate is not a finite number. Left as a gap rather than plotted as something.
        int256 fairRate = sailPrice == 0 ? NaN : int256((1 ether * 1 ether) / sailPrice);
        int256 appliedRate = _measureAppliedRate();

        int256 appliedOverFair = NaN;
        if (fairRate != NaN && appliedRate != NaN && fairRate != 0) {
            appliedOverFair = (appliedRate * 1 ether) / fairRate;
        }

        // With no residual the minter reports the maximum - a claim of nothing rather than a leverage - so the line
        // breaks there instead of carrying a number.
        uint256 leverageRatio_ = IMinter_v3(minter).leverageRatio();

        lines = new int256[](4);
        lines[0] = leverageRatio_ == type(uint256).max ? NaN : SafeCast.toInt256(leverageRatio_);
        lines[1] = fairRate;
        lines[2] = appliedRate;
        lines[3] = appliedOverFair;
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        int256[] memory lines = _lines();
        writeLine(file, ia(int256(collateralRatio), lines[0], lines[1], lines[2], lines[3]));
    }

    /// @dev Every line, so a stretch counts as having nothing to say only when none of them is moving.
    function refinementSignals() internal override returns (int256[] memory) {
        return _lines();
    }

    /// @dev Convert a fixed amount of anchor into sail and report the conversion rate that came out, then
    ///      undo it so the sweep's next point starts from the same market.
    function _measureAppliedRate() private returns (int256 appliedRate) {
        if (IERC20(peggedToken).balanceOf(address(this)) < ANCHOR_IN) {
            return NaN;
        }
        uint256 snapshot = vm.snapshotState();
        appliedRate = NaN;
        try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 sailOut) {
            appliedRate = int256((sailOut * 1 ether) / ANCHOR_IN);
        } catch (bytes memory reason) {
            // the conversion is refused here by the leverage cap; a gap says so
            _requireLeverageCapRefusal(reason);
        }
        vm.revertToState(snapshot);
    }
}
