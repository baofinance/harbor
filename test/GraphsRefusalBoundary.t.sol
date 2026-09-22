// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Where a conversion would start refusing, under the two rules that could make it refuse, as the
/// sail supply varies.
///
/// A conversion issues `pegged / leveragedPrice`, so something has to stop it before the leveraged price
/// reaches zero. Two rules can: a FLOOR ON THE LEVERAGED PRICE, which is the mirror of the rule the
/// pegged token already has in `MIN_REPORTABLE_PEGGED_PRICE_E36`, or a CAP ON THE LEVERAGE RATIO, which
/// is what the contract already tests for and then declines to act on. They are not the same rule and
/// the difference is the whole point of this graph.
///
/// The sail price is the residual divided by the sail SUPPLY, while the leverage ratio is the collateral
/// value divided by the same residual and so depends on no supply at all. A market with more sail in it
/// therefore has a lower sail price at the same collateral ratio, and a price floor refuses higher and
/// higher up as the supply grows, while a leverage cap stays where it is. Since every conversion issues
/// sail, a price floor's refusal boundary is pushed up by the very operation it governs.
///
/// The candidates are paired so that each price floor refuses at the same collateral ratio as its
/// leverage cap when the market holds one sail token per anchor token - `1/(K-1)` against `K`. They start
/// together by construction, and the graph is what happens to them either side of that.
///
/// Every boundary is found by BISECTION ON THE MARKET, not from the algebra, and the conversion at the
/// two middle candidates is then actually performed there.
contract TestGraphsRefusalBoundary is GraphTestBase, TestConversionBoundReleaseSetUp {
    uint256 private constant FIRST_SAIL_PER_ANCHOR = 0.01 ether;
    uint256 private constant LAST_SAIL_PER_ANCHOR = 100 ether;

    /// @dev Rounds of halving. The bracket is a collateral ratio of 1 to 1000, so sixty rounds close it
    ///      to far below the wei the ratio is expressed in.
    uint256 private constant BISECTIONS = 60;

    /// @dev The top of every bracket: a collateral ratio no candidate's boundary reaches, so the
    ///      bisection always starts with the answer inside it.
    uint256 private constant HIGHEST_RATIO = 1000 ether;

    string private file;

    function _leverageCaps() private pure returns (uint256[3] memory) {
        return [uint256(5 ether), 20 ether, 100 ether];
    }

    /// @dev Each floor is `1/(K-1)` of its cap, which is where the two coincide at one sail token per
    ///      anchor token - derived from the caps rather than written out again, so the pairing cannot
    ///      drift if a candidate changes.
    function _priceFloors() private pure returns (uint256[3] memory floors) {
        uint256[3] memory caps = _leverageCaps();
        for (uint256 i = 0; i < 3; i++) {
            floors[i] = Math.mulDiv(1 ether, 1 ether, caps[i] - 1 ether);
        }
    }

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "conversion_refusal_boundary",
            sa(
                "sail supply per anchor token",
                "refusal ratio, leverage cap 5",
                "refusal ratio, leverage cap 20",
                "refusal ratio, leverage cap 100",
                "refusal ratio, price floor 1/4",
                "refusal ratio, price floor 1/19",
                "refusal ratio, price floor 1/99",
                "sail per anchor at the leverage cap 20 boundary",
                "sail per anchor at the price floor 1/19 boundary",
                "sail supply multiple at the leverage cap 20 boundary",
                "sail supply multiple at the price floor 1/19 boundary"
            )
        );
    }

    /// @dev The leverage ratio as the market actually stands, uncapped: collateral value over the
    ///      residual. Read from the contract's own balances rather than from `leverageRatio()`, which
    ///      saturates at the cap in force and so cannot express a candidate above it.
    function _trueLeverageRatio() private view returns (uint256) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 collateralValueE36 = IMinter(minter).collateralTokenBalance() * price;
        uint256 anchorClaimE36 = IMinter(minter).peggedTokenBalance() * 1 ether;
        if (collateralValueE36 <= anchorClaimE36) {
            return type(uint256).max; // no residual: leverage is unbounded
        }
        return Math.mulDiv(collateralValueE36, 1 ether, collateralValueE36 - anchorClaimE36);
    }

    /// @dev The lowest collateral ratio at which the leverage ratio has fallen to `cap`. The leverage
    ///      ratio falls as the collateral ratio rises, so the crossing is bracketed and halved.
    function _boundaryForLeverageCap(uint256 cap) private returns (uint256) {
        uint256 low = 1 ether + 1;
        uint256 high = HIGHEST_RATIO;
        for (uint256 i = 0; i < BISECTIONS; i++) {
            uint256 middle = low + (high - low) / 2;
            setCollateralRatio(middle);
            if (_trueLeverageRatio() > cap) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return high;
    }

    /// @dev The lowest collateral ratio at which the reported sail price has risen to `floor`. The sail
    ///      price rises as the collateral ratio rises, so the crossing is bracketed the other way up.
    function _boundaryForPriceFloor(uint256 floor) private returns (uint256) {
        uint256 low = 1 ether + 1;
        uint256 high = HIGHEST_RATIO;
        for (uint256 i = 0; i < BISECTIONS; i++) {
            uint256 middle = low + (high - low) / 2;
            setCollateralRatio(middle);
            if (IMinter_v3(minter).leveragedTokenPrice() < floor) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return high;
    }

    /// @dev What one anchor token is actually given at `collateralRatio`, and what that one conversion
    ///      does to the whole sail supply. Performed rather than predicted, and put back afterwards.
    function _conversionAt(uint256 collateralRatio) private returns (int256 sailOut, int256 supplyMultiple) {
        uint256 snapshot = vm.snapshotState();
        setCollateralRatio(collateralRatio);
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        sailOut = NaN;
        supplyMultiple = NaN;
        try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 out) {
            sailOut = int256(out);
            supplyMultiple = int256(Math.mulDiv(IMinter(minter).leveragedTokenBalance(), 1 ether, supplyBefore));
        } catch {
            // refused at its own boundary, and a gap says so
        }
        vm.revertToState(snapshot);
    }

    /// @notice The two rules' refusal boundaries across a ten-thousandfold range of sail supply, with the
    /// conversion each would allow at its own edge.
    function test_whereEachRuleWouldRefuse() public {
        uint256[3] memory caps = _leverageCaps();
        uint256[3] memory floors = _priceFloors();

        for (uint256 target = FIRST_SAIL_PER_ANCHOR; target <= LAST_SAIL_PER_ANCHOR; target = (target * 10) / 3) {
            uint256 snapshot = vm.snapshotState();

            // The achieved supply is what goes on the axis, not the requested one: buying sail to a
            // target rounds, and the row should say where the market was put.
            uint256 achieved = setSailSupplyMultiple(minter, priceOracle, target);

            int256[] memory row = new int256[](11);
            row[0] = int256(achieved);
            for (uint256 i = 0; i < 3; i++) {
                row[1 + i] = int256(_boundaryForLeverageCap(caps[i]));
                row[4 + i] = int256(_boundaryForPriceFloor(floors[i]));
            }
            (row[7], row[9]) = _conversionAt(uint256(row[2])); // at the leverage cap of 20
            (row[8], row[10]) = _conversionAt(uint256(row[5])); // at the price floor of 1/19
            writeLine(file, row);

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }

    /// @notice The refusal boundary against the cap that sets it, so a market can be read off against its
    /// own rebalance threshold.
    ///
    /// A cap refuses at and below `K/(K-1)`, and a rebalance restores UP to its threshold - so a cap
    /// whose boundary sits above a market's threshold refuses the sail leg across that market's entire
    /// rebalancing range, and its leveraged stability pool is never drawn on at all. The threshold is
    /// therefore a hard floor on the cap, market by market, and the production tiers are far enough apart
    /// that no single cap clears all of them by much.
    function test_theBoundaryAgainstTheCapThatSetsIt() public {
        // One sail token per anchor token: the boundary does not depend on the supply - that is what the
        // sweep above establishes - but the supply multiple recorded beside it does, so it is pinned at
        // an ordinary market rather than left wherever the deploy put it.
        setSailSupplyMultiple(minter, priceOracle, 1 ether);

        string memory capFile = openFile(
            "conversion_refusal_by_leverage_cap",
            sa(
                "leverage ratio cap",
                "collateral ratio at or below which the conversion refuses",
                "sail supply multiple, one anchor converted at that boundary"
            )
        );

        for (uint256 cap = 1.2 ether; cap <= 1000 ether; cap = (cap * 7) / 5) {
            uint256 snapshot = vm.snapshotState();
            uint256 boundary = _boundaryForLeverageCap(cap);
            (, int256 supplyMultiple) = _conversionAt(boundary);
            writeLine(capFile, ia(int256(cap), int256(boundary), supplyMultiple));
            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(capFile);
    }

    /// @notice The uncapped leverage ratio this measurement bisects on agrees with the one the contract
    /// reports, wherever the contract is not saturating it. Without that the boundaries above would be
    /// this test's arithmetic rather than the market's.
    function test_theUncappedLeverageRatioAgreesWithTheReportedOne() public {
        uint256[4] memory ratios = [uint256(1.2 ether), 1.5 ether, 2 ether, 5 ether];
        for (uint256 i = 0; i < ratios.length; i++) {
            setCollateralRatio(ratios[i]);
            uint256 reported = IMinter_v3(minter).leverageRatio();
            assertLt(reported, 20 ether, "the reported ratio must be off its cap for this to compare");
            assertApproxEqAbs(_trueLeverageRatio(), reported, 1, "the uncapped ratio is the reported one");
        }
    }
}
