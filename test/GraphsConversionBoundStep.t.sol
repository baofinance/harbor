// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Graphs the size of the step the applied conversion rate takes when the bound releases, against
/// how many leveraged tokens the market carries.
///
/// The bound always releases at the same collateral ratio - the leverage ratio reaches the cap `K` at
/// `K/(K-1)`, which the cap alone fixes. What the applied conversion rate does when it gets there is not
/// fixed at all, and this is that dependence, measured.
///
/// At the release the bound is applying its ceiling of `K` while the fair conversion rate is the leveraged
/// supply over the residual. The residual at the release is a fixed share of the collateral, so the fair
/// conversion rate is proportional to the leveraged supply and the step between the two goes as one over it.
/// The two lines cross - the step passes through one, a continuous join - at exactly one leveraged supply. A
/// market carrying any other leveraged supply gets a jump, in one direction or the other, and nothing in the
/// protocol holds a market at the crossing point or anywhere near it.
///
/// Leveraged supply is swept by buying and selling leveraged, both of which are price-neutral: they change how many
/// tokens carry the residual without changing what any one of them is worth, so no holder is diluted and
/// no market here is distressed. Each point is a market that could exist at any time.
///
/// The sweep is geometric because the relationship is a power law, and it is drawn over five orders of
/// magnitude because the quantity is unbounded and five orders of magnitude is enough to show that it is
/// a straight line rather than something that levels off.
contract TestGraphsConversionBoundStep is GraphTestBase, TestConversionBoundReleaseSetUp {
    uint256 private constant FIRST_LEVERAGED_PER_PEGGED = 0.001 ether;
    uint256 private constant LAST_LEVERAGED_PER_PEGGED = 100 ether;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "conversion_bound_step",
            sa(
                "sail supply per anchor token",
                "applied conversion rate inside the bound",
                "fair conversion rate at the release",
                "step at the release"
            )
        );
    }

    function test_theStepAcrossTheReleaseOverLeveragedSupply() public {
        for (
            uint256 target = FIRST_LEVERAGED_PER_PEGGED;
            target <= LAST_LEVERAGED_PER_PEGGED;
            target = (target * 4) / 3
        ) {
            uint256 snapshot = vm.snapshotState();

            // The achieved supply is what goes on the axis, not the requested one: buying leveraged to a
            // target rounds, and the row should say where the market was put.
            uint256 achieved = marketActions.setLeveragedSupplyMultiple(address(this), target);
            (uint256 bounded, uint256 released) = ratesAcrossTheRelease();

            writeLine(file, ua(achieved, bounded, released, released == 0 ? 0 : (bounded * 1 ether) / released));

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
