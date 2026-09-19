// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What the anchor-to-sail conversion rate does at the collateral ratio where the bound lets go,
/// and what decides the size of the step it takes there.
contract TestMinterConversionBoundRelease is TestConversionBoundReleaseSetUp {
    /// The applied conversion rate steps down when the bound releases rather than meeting the fair
    /// conversion rate there, and in a market funded with equal collateral behind anchor and sail that
    /// step is about five percent.
    function test_theAppliedConversionRateStepsDownWhenTheBoundReleases() public {
        uint256 step = stepAcrossTheRelease();

        assertGt(step, 1 ether, "the applied conversion rate falls as the bound releases");
        // The step is the collateral value per sail token at the release. This market carries one sail
        // token per anchor token, and the release itself fixes the collateral value at 20/19 of the
        // anchor supply, so the step is that same 20/19.
        assertApproxEqRel(step, uint256(1 ether * 20) / 19, 0.001 ether, "a 5% step, not a continuous join");
    }

    /// The size of that step is not a property of the bound: it is the sail price at the release, which
    /// an ordinary exit by sail holders moves by orders of magnitude.
    function test_theSizeOfTheStepIsSetByTheSailPriceAndIsNotBounded() public {
        uint256 stepAsFunded = stepAcrossTheRelease();

        uint256 sailPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        uint256 sailHeld = IERC20(leveragedToken).balanceOf(address(this));
        IMinter_v3(minter).freeRedeemLeveragedToken((sailHeld * 99) / 100, address(this));

        // Nothing improper happened: a redeem hands back the redeemer's share of the residual and leaves
        // what each remaining token is worth exactly where it was. The market is intact - it simply has
        // fewer, dearer sail tokens, which is all it takes.
        assertApproxEqRel(
            IMinter_v3(minter).leveragedTokenPrice(),
            sailPriceBefore,
            0.0001 ether,
            "redeeming sail leaves the sail price where it was"
        );

        uint256 stepAfterExit = stepAcrossTheRelease();

        assertGt(
            stepAfterExit,
            stepAsFunded * 50,
            "the same bound in the same market steps by orders of magnitude more once sail has exited"
        );
        // A hundredfold fewer sail tokens carry the same residual, so each is worth a hundred times more
        // and the bound over-issues by a hundred times as much.
        assertApproxEqRel(stepAfterExit, stepAsFunded * 100, 0.02 ether, "the step tracks the sail price");
    }

    /// Below one sail token per anchor token the bound over-issues at the release; above it the bound is
    /// still binding when it lets go, so the applied conversion rate steps UP and the pool is handed less
    /// than fair right up to the release. The same code, the same cap, opposite directions.
    function test_theStepReversesWhenSailIsPlentiful() public {
        uint256 achieved = setSailSupplyMultiple(minter, priceOracle, 20 ether);
        assertApproxEqRel(achieved, 20 ether, 0.001 ether, "the sail supply was moved to twenty per anchor");

        uint256 step = stepAcrossTheRelease();

        assertLt(step, 1 ether, "with sail this plentiful the conversion rate steps up, not down");
    }
}
