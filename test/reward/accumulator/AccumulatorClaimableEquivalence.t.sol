// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {Array} from "@harbor-test/Array.sol";
import {MockMultipleRewardCompoundingAccumulator_v2} from "@harbor-test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v2.sol";
import {MockMultipleRewardCompoundingAccumulator_v3} from "@harbor-test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v3.sol";

/// @notice v3 computes the temporal-pending share of `claimable` as a single fused divide
/// (`_scaleAdjustedShare`) so that `amount * shares` never forms in a uint256 - its two factors are bounded
/// independently, so the product can exceed uint256 even where the result cannot. v2 is the untouched reference: it
/// still computes `_scaleAdjustedValue(amount * shares, ...) / totalShares`.
///
/// Fusing is only safe because successive FLOOR DIVISIONS compose, so reordering the divides cannot change the value.
/// Reordering a MULTIPLICATION across a floor could - silently, by a wei or more on every claim. These tests hold the
/// two implementations to being numerically IDENTICAL across the whole input domain v2 can compute (share sizes,
/// reward sizes, magnitudes and exponent gaps), so a future edit that changes the arithmetic rather than the division
/// order goes red rather than quietly drifting every user's reward.
contract AccumulatorClaimableEquivalenceTest is Test, Array {
    uint40 internal constant PERIOD = 1 weeks;
    /// @dev Large enough that v3's reward-integral cap admits every reward these tests deposit (the cap scales with the
    ///      share floor; v2 has no such cap, so this only affects whether v3 ACCEPTS the deposit, never the math).
    uint256 internal constant SHARE_FLOOR = 1e30;

    address internal deployer;
    address internal manager;

    function setUp() public {
        deployer = address(this);
        manager = makeAddr("manager");
    }

    /// @dev Stand up v2 and v3 on identical state, then read both at the same instant. Both are armed BEFORE the warp
    /// so the streamed reward has accrued for exactly the same elapsed time in each.
    function _bothClaimable(
        uint256 totalShares,
        uint256 shares,
        uint256 reward,
        uint128 currentProd,
        uint128 userProd
    ) internal returns (uint256 v2Claimable, uint256 v3Claimable) {
        address token = address(new MockERC20("Reward", "RWD", 18));

        MockMultipleRewardCompoundingAccumulator_v2 v2 = new MockMultipleRewardCompoundingAccumulator_v2(PERIOD);
        v2.initialize(deployer);
        v2.grantRoles(manager, v2.REWARD_MANAGER_ROLE());
        vm.prank(manager);
        v2.registerRewardToken(token);
        v2.setTotalPoolShare(totalShares, currentProd);
        v2.setUserPoolShare(shares, userProd);

        MockMultipleRewardCompoundingAccumulator_v3 v3 = new MockMultipleRewardCompoundingAccumulator_v3(PERIOD);
        v3.initialize(deployer, address(0));
        v3.grantRoles(manager, v3.REWARD_MANAGER_ROLE());
        vm.prank(manager);
        v3.registerRewardToken(token);
        v3.setMinTotalPoolShare(SHARE_FLOOR);
        v3.setTotalPoolShare(totalShares, currentProd);
        v3.setUserPoolShare(shares, userProd);

        MockERC20(token).mint(deployer, reward * 2);
        MockERC20(token).approve(address(v2), reward);
        MockERC20(token).approve(address(v3), reward);
        v2.depositReward(token, reward);
        v3.depositReward(token, reward);

        // mid-period: part of the stream is distributed, the remainder is the temporal-pending `amount`
        vm.warp(block.timestamp + PERIOD / 2);

        v2Claimable = v2.claimable(deployer, token);
        v3Claimable = v3.claimable(deployer, aa(token))[0];
    }

    /// @dev The largest reward this PAIR can be driven with. v2 is the binding side: its stream `rate` is a uint80
    /// (v3 widened it to uint128), so a reward whose rate overflows that field cannot be deposited into v2 at all.
    /// Within this domain `amount * shares` also always fits uint256 - which is exactly the region where v2's unfused
    /// formula is computable, and so the region where it is a valid reference.
    function _maxReward(uint256 shares) internal pure returns (uint256 capped) {
        uint256 byProduct = type(uint256).max / shares;
        uint256 byV2RateField = uint256(type(uint80).max) * PERIOD;
        capped = byProduct < byV2RateField ? byProduct : byV2RateField;
    }

    /// @notice Across the whole domain v2 supports, v3's fused share equals v2's unfused one EXACTLY.
    function testFuzz_claimable_v3MatchesV2Exactly(
        uint256 rewardSeed,
        uint256 sharesSeed,
        uint256 totalSeed,
        uint256 magSeed,
        uint256 gapSeed
    ) public {
        uint256 totalShares = bound(totalSeed, 1, uint256(type(uint128).max));
        uint256 shares = bound(sharesSeed, 1, totalShares);
        uint256 reward = bound(rewardSeed, 1, _maxReward(shares));

        // the user's snapshot exponent never exceeds the current one; magnitudes span the legal band
        uint8 gap = uint8(bound(gapSeed, 0, DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE));
        uint120 userMag = uint120(bound(magSeed, DecrementalFloatingPoint.MIN_PRECISION, 1e36));
        uint120 currentMag = uint120(
            bound(uint256(keccak256(abi.encode(magSeed))), DecrementalFloatingPoint.MIN_PRECISION, 1e36)
        );

        (uint256 v2Claimable, uint256 v3Claimable) = _bothClaimable(
            totalShares,
            shares,
            reward,
            DecrementalFloatingPoint.encode(gap, currentMag),
            DecrementalFloatingPoint.encode(0, userMag)
        );

        assertEq(v3Claimable, v2Claimable, "v3's fused temporal share drifted from v2's unfused formula");
    }

    /// @notice The corners the fuzz reaches only by chance: each ladder rung of the exponent gap, at the magnitude
    /// extremes, with the whole pool in one position and with a dust position. A rounding change shows first at a
    /// boundary, so these are pinned deterministically rather than left to the sampler.
    function test_claimable_v3MatchesV2AtTheBoundaries() public {
        uint256[3] memory shareSplits = [uint256(1), 1e18, uint256(type(uint128).max)];
        uint120[2] memory mags = [uint120(DecrementalFloatingPoint.MIN_PRECISION), uint120(1e36)];

        for (uint256 s = 0; s < shareSplits.length; s++) {
            uint256 totalShares = shareSplits[s];
            for (uint8 gap = 0; gap <= DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE; gap++) {
                for (uint256 m = 0; m < mags.length; m++) {
                    (uint256 v2Claimable, uint256 v3Claimable) = _bothClaimable(
                        totalShares,
                        totalShares, // the whole pool in one position - the largest `shares` for this total
                        _maxReward(totalShares), // the largest reward v2 can still compute
                        DecrementalFloatingPoint.encode(gap, mags[m]),
                        DecrementalFloatingPoint.encode(0, mags[m])
                    );
                    assertEq(
                        v3Claimable,
                        v2Claimable,
                        string.concat(
                            "drift at shares=",
                            vm.toString(totalShares),
                            " gap=",
                            vm.toString(uint256(gap)),
                            " mag=",
                            vm.toString(uint256(mags[m]))
                        )
                    );
                }
            }
        }
    }
}
