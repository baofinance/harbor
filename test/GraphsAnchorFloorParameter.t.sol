// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What one dial buys and what it costs, for the story a holder needs to be told.
///
/// The proposal has a single economic parameter, `delta`: the share of the collateral the anchor may
/// never claim, and which the sail therefore always may. Everything a holder cares about follows from it,
/// and this is the graph that says so in their own terms rather than in the protocol's.
///
/// WHAT IT COSTS an anchor holder: how much the anchor is worth less than one at its very worst, and how
/// wide the band is where it is worth less than one at all. Outside that band nothing changes - which is
/// the part worth saying loudest, because it includes every collateral ratio a market is normally run at.
///
/// WHAT IT BUYS: a ceiling on how levered a sail position can get, and a floor under what it costs to
/// mint a large share of the sail supply cheaply - which is the thing the sail floor exists to stop.
///
/// Every figure is MEASURED by building the rule at that `delta`, installing it over a market, and
/// reading it - not computed from the algebra it is supposed to obey. The relationships here are simple
/// enough that computing them would be easy and would prove nothing; measuring them has already caught
/// one rule that misbehaved far from where anyone was looking, and one that priced the anchor at one
/// where it was not.
contract TestGraphsAnchorFloorParameter is GraphTestBase, TestConversionBoundReleaseSetUp {
    uint256 private constant FIRST_DELTA = 0.0005 ether; // one twentieth of a percent
    uint256 private constant LAST_DELTA = 0.05 ether; // five percent

    /// @dev The share of the anchor outstanding converted when measuring what one conversion does to the
    ///      sail supply. A hundredth is a realistic size for one rebalance and small enough that the
    ///      answer is not dominated by the conversion having eaten the market.
    uint256 private constant CONVERTED_SHARE = 0.01 ether;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "anchor_floor_parameter",
            sa(
                "delta, the share of collateral the anchor never claims",
                "worst the anchor is ever worth",
                "collateral ratio below which the anchor is worth less than one",
                "leverage ratio ceiling",
                "sail supply multiple from converting one percent of the anchor"
            )
        );
    }

    /// @dev The lowest collateral ratio at which the anchor is worth EXACTLY one, found by halving. Above
    ///      it the proposal is indistinguishable from what the contract does today; below it is the whole
    ///      of the cost.
    function _whereTheAnchorIsWholeAgain() private returns (uint256) {
        uint256 low = 1 ether;
        uint256 high = 1.2 ether;
        for (uint256 i = 0; i < 60; i++) {
            uint256 middle = low + (high - low) / 2;
            setCollateralRatio(middle);
            if (IMinter_v3(minter).peggedTokenPrice() < 1 ether) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return high;
    }

    /// @dev What converting a hundredth of the anchor outstanding does to the whole sail supply, at the
    ///      peg, where the floor is doing all of the work.
    function _supplyMultipleAtThePeg() private returns (int256) {
        setCollateralRatio(1 ether);
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 converting = Math.mulDiv(IMinter(minter).peggedTokenBalance(), CONVERTED_SHARE, 1 ether);
        try IMinter_v3(minter).freeRedeemPeggedToken(0, converting, address(this)) returns (uint256, uint256) {
            return int256(Math.mulDiv(IMinter(minter).leveragedTokenBalance(), 1 ether, supplyBefore));
        } catch {
            return NaN; // cannot convert at the peg at all, which is what this rule exists to change
        }
    }

    /// @notice The dial, swept from a twentieth of a percent to five percent.
    function test_whatTheDialCostsAndBuys() public {
        for (uint256 delta = FIRST_DELTA; delta <= LAST_DELTA; delta = (delta * 3) / 2) {
            uint256 outer = vm.snapshotState();
            installContractAt(
                minter,
                address(
                    new Minter_v3(
                        address(wrappedCollateralToken),
                        address(peggedToken),
                        address(leveragedToken),
                        delta
                    )
                )
            );

            uint256 inner = vm.snapshotState();
            setCollateralRatio(1 ether);
            uint256 worstAnchor = IMinter_v3(minter).peggedTokenPrice();
            uint256 ceiling = IMinter_v3(minter).leverageRatio();
            vm.revertToStateAndDelete(inner);

            inner = vm.snapshotState();
            uint256 whole = _whereTheAnchorIsWholeAgain();
            vm.revertToStateAndDelete(inner);

            inner = vm.snapshotState();
            int256 supplyMultiple = _supplyMultipleAtThePeg();
            vm.revertToStateAndDelete(inner);

            writeLine(file, ia(int256(delta), int256(worstAnchor), int256(whole), int256(ceiling), supplyMultiple));

            vm.revertToStateAndDelete(outer);
        }
        vm.closeFile(file);
    }
}
