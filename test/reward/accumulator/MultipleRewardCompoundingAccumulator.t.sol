// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {IMockMultipleRewardCompoundingAccumulator} from "@harbor-test/mocks/IMockMultipleRewardCompoundingAccumulator.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockMultipleRewardCompoundingAccumulator_v3} from "@harbor-test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v3.sol";
import {Array} from "@harbor-test/Array.sol";

contract MultipleRewardCompoundingAccumulatorTest is BaoTest, Array {
    // Addresses
    address deployer;
    address manager;
    address receiver;

    // Test parameters to loop through
    // TODO: make these fuzz possibilities (for all tests!)
    // TODO: test for no reward tokens
    // TODO: test for zero reward period
    uint256[] rewardCounts;

    // Error message constants
    bytes4 REENTRANT_ERROR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    function setUp() public {
        // Setup accounts
        deployer = address(this);
        manager = makeAddr("manager");
        receiver = makeAddr("receiver");

        // Setup test parameters
        rewardCounts = new uint256[](2);
        rewardCounts[0] = 1;
        rewardCounts[1] = 3;
    }

    function createMultipleRewardCompoundingAccumulator(
        uint40 periodLength
    ) internal virtual returns (IMockMultipleRewardCompoundingAccumulator) {
        return
            IMockMultipleRewardCompoundingAccumulator(
                address(new MockMultipleRewardCompoundingAccumulator_v3(periodLength))
            );
    }

    function _setupAccumulator(
        uint256 rewardCount,
        uint40 periodLength
    ) internal returns (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) {
        // Deploy accumulator
        accumulator = createMultipleRewardCompoundingAccumulator(periodLength);
        accumulator.initialize(address(this), address(0));

        // Grant manager role
        accumulator.grantRoles(manager, accumulator.REWARD_MANAGER_ROLE());

        tokenAddresses = new address[](rewardCount);
        // Deploy tokens
        for (uint256 i = 0; i < rewardCount; i++) {
            string memory i_str = vm.toString(i);
            string memory token_name = string.concat("Name_", i_str);
            string memory token_symbol = string.concat("Symbol_", i_str);
            tokenAddresses[i] = address(new MockERC20(token_name, token_symbol, 18));

            MockERC20(tokenAddresses[i]).mint(deployer, 1000000 * 1 ether);
            // Approve tokens
            MockERC20(tokenAddresses[i]).approve(address(accumulator), type(uint256).max);

            // Register reward token
            vm.prank(manager);
            accumulator.registerRewardToken(tokenAddresses[i]);
        }
    }

    function testInitialization() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (
                IMockMultipleRewardCompoundingAccumulator accumulator,
                address[] memory tokenAddresses
            ) = _setupAccumulator(rewardCount, periodLength);

            // Verify initialization
            assertEq(accumulator.REWARD_PERIOD_LENGTH(), periodLength);
            assertEq(accumulator.activeRewardTokens().length, rewardCount);

            // Check each token is in active rewards
            address[] memory activeRewards = accumulator.activeRewardTokens();
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(activeRewards[j], tokenAddresses[j]);
            }

            // Check historical rewards is empty
            assertEq(accumulator.historicalRewardTokens().length, 0);

            // Check deployer has default admin role
            assertEq(accumulator.owner(), deployer);
        }
    }

    function testReentrantCheckpoint() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSelector(accumulator.checkpoint.selector, abi.encode(address(0))));
        }
    }

    function testReentrantClaim() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            // Test claim()
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSelector(bytes4(keccak256("claim()")), ""));
        }
    }

    function testReentrantClaimVector() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint40 periodLength = 1 weeks;
            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(
                rewardCounts[i],
                periodLength
            );

            address[] memory emptyArray = new address[](0);
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSignature("claim(address[])", emptyArray));
        }
    }

    function testReentrantClaimSingle() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint40 periodLength = 1 weeks;
            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(
                rewardCounts[i],
                periodLength
            );

            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSignature("claim(address,uint256)", address(0), type(uint256).max));
        }
    }

    struct TestParams {
        uint256 rewardCount;
        uint40 periodLength;
        uint256 baseRewardAmount;
        uint256 totalPoolShare;
        uint256 userPoolShare;
    }

    function testCheckpoint() public {
        // TODO: fuzz this

        for (uint256 i = 0; i < rewardCounts.length; i++) {
            TestParams memory t;
            t.rewardCount = rewardCounts[i];
            t.periodLength = 1 weeks;
            t.baseRewardAmount = 2233 ether;
            t.totalPoolShare = 1234 ether;
            t.userPoolShare = 456 ether;

            uint256[3] memory timestamp;
            uint256 globalSnapshot;

            (
                IMockMultipleRewardCompoundingAccumulator accumulator,
                address[] memory tokenAddresses
            ) = _setupAccumulator(t.rewardCount, t.periodLength);

            // Set pool shares
            accumulator.setTotalPoolShare(t.totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(t.userPoolShare, 1 ether);

            // Deposit rewards
            for (uint256 j = 0; j < t.rewardCount; j++) {
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            // Test global checkpoint
            // TODO: get rid of timestamp array and replace with block.timestamp
            timestamp[0] = block.timestamp;
            vm.warp(timestamp[0] + t.periodLength);
            assertEq(block.timestamp, timestamp[0] + t.periodLength, "warp failed");

            accumulator.checkpoint(address(0));

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    (rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("Global integral mismatch for token ", vm.toString(j))
                );
            }

            // Test user checkpoint
            timestamp[1] = block.timestamp;
            vm.warp(timestamp[1] + t.periodLength);
            accumulator.checkpoint(deployer);

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    (rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("User integral mismatch for token ", vm.toString(j))
                );

                // Check user snapshot
                (uint256 userTimestamp, uint256 userIntegral, uint256 userPending, uint256 userClaimed) = accumulator
                    .userRewardSnapshot(deployer, tokenAddresses[j]);

                assertEq(userTimestamp, timestamp[1] + t.periodLength);
                assertEq(userIntegral, globalSnapshot);
                assertApproxEqRel(
                    userPending,
                    (depositAmount * t.userPoolShare) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("User pending mismatch for token ", vm.toString(j))
                );
                assertEq(userClaimed, 0);
            }

            // Deposit again and checkpoint
            for (uint256 j = 0; j < t.rewardCount; j++) {
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            timestamp[2] = block.timestamp;
            vm.warp(timestamp[2] + t.periodLength);
            accumulator.checkpoint(deployer);

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    ((rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare) * 2,
                    0.001e18, // Allow 0.1% error for accumulated calculations
                    string.concat("Global integral mismatch #2 for token ", vm.toString(j))
                );

                // Check user snapshot
                (uint256 userTimestamp, uint256 userIntegral, uint256 userPending, uint256 userClaimed) = accumulator
                    .userRewardSnapshot(deployer, tokenAddresses[j]);

                assertEq(userTimestamp, timestamp[2] + t.periodLength);
                assertEq(
                    userIntegral,
                    globalSnapshot,
                    string.concat("User integral mismatch #2 for token ", vm.toString(j))
                );
                assertApproxEqRel(
                    userPending,
                    ((depositAmount * t.userPoolShare) / t.totalPoolShare) * 2,
                    0.001e18, // Allow 0.1% error for accumulated calculations
                    string.concat("Global user pending mismatch #2 for token ", vm.toString(j))
                );
                assertEq(userClaimed, 0);
            }
        }
    }

    /// ═══════════════════════════════════════════════════════════════════════════════
    /// INTEGRAL OVERFLOW BOUNDS ANALYSIS
    /// ═══════════════════════════════════════════════════════════════════════════════
    ///
    /// Core formula (fresh pool, magnitude = MAGNITUDE_PRECISION = 1e36):
    ///   integral_delta = rewardAmount * 1e18 * 1e36 / totalPoolShare
    ///                  = rewardAmount * 1e54 / totalPoolShare
    ///
    /// Max cumulative reward/pool ratio before overflow:
    ///   v1 (uint192):  6.277e57 / 1e54 = 6,277
    ///   v2 (uint256):  1.158e77 / 1e54 = 1.158e23
    ///
    /// ─── TABLE 1: APY Model (reward proportional to pool) ──────────────────────
    /// Price-INDEPENDENT. Identical for all assets at any price.
    ///
    ///   APY     │  v1 years to overflow  │  v2 years
    ///  ─────────┼────────────────────────┼───────────
    ///    10%    │          62,770        │   never
    ///   100%    │           6,277        │   never
    ///  1000%    │             628        │   never
    ///
    ///  Formula: v1_years = 627,700 / APY
    ///
    /// ─── TABLE 2: Fixed Weekly Reward to MIN_DEPOSIT Pool (v1 only) ────────────
    /// Worst case: pool has exactly MIN_DEPOSIT, reward is a fixed USD amount
    /// independent of pool size. v2 is "never" for ALL rows.
    ///
    /// The asset price affects MIN_DEPOSIT's USD value (fixed in wei at deployment).
    /// Range spans from 1,000,000x BTC price to IRR (1M per USD).
    ///
    ///  Asset (config)         │ Token Price      │ MIN_DEP $  │ $100/wk  │ $1k/wk  │ $10k/wk
    ///  ──────────────────────┼──────────────────┼────────────┼──────────┼─────────┼─────────
    ///  BTC-peg at 1Mx price  │ $60,000,000,000  │ $600,000   │ 72.4M yr │ 7.24M yr│ 724k yr
    ///  BTC-peg at 1000x      │ $60,000,000      │ $600       │ 72.4k yr │ 7,240 yr│ 724 yr
    ///  BTC-peg (current)     │ $60,000          │ $0.60      │ 0.72 yr  │  27 days│ 2.6 days
    ///  ETH-peg (current)     │ $2,500           │ $0.50      │ 0.60 yr  │  22 days│ 2.2 days
    ///  EUR / stablecoin      │ $1.00            │ $1.00      │ 1.21 yr  │  44 days│ 4.4 days
    ///  IRR-peg (1M per USD)  │ $0.000001        │ $1.00 (*)  │ 1.21 yr  │  44 days│ 4.4 days
    ///  BTC-peg at 1/1Mx price│ $0.06            │ $6e-7      │  23 sec  │  2.3 sec│ <1 sec
    ///
    ///  (*) IRR MIN_DEPOSIT set to ~$1 at deployment (1e24 wei at $0.000001/token)
    ///
    ///  Formula: v1_years = 120.7 * MIN_DEPOSIT_$ / weekly_reward_$
    ///
    ///  Context: BTC $1k/wk to $0.60 pool = 8,666,667% effective APY.
    ///           These overflow fast because the reward/pool ratio is extreme.
    ///
    /// ─── KEY INSIGHTS ──────────────────────────────────────────────────────────
    /// 1. APY model: v1 safe for centuries at realistic rates. v2 is unlimited.
    /// 2. Fixed-reward risk: small pools receiving disproportionate rewards
    ///    overflow v1 rapidly. $1k/wk to BTC MIN_DEPOSIT pool = 27 days.
    /// 3. v2 (uint256 integral) eliminates integral overflow entirely.
    /// 4. The ratio reward/pool is what matters - asset price only affects
    ///    this through the MIN_DEPOSIT configuration (its USD value drifts).
    /// 5. Price appreciation makes existing pools safer (MIN_DEPOSIT $ rises).
    ///    Price depreciation makes them more vulnerable.
    /// 6. Other type limits (uint80 rate, uint96 queued, uint128 pending)
    ///    are generous and not practical constraints for any realistic scenario.
    /// ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Replicates the mainnet failure: uint192 integral overflow in _accumulateReward.
    /// Two tokens registered, only token0 gets deposits. Token1 develops finishAt=0 state.
    /// After enough deposit cycles, token0's integral exceeds uint192 max.
    /// v2 (uint256 integral): succeeds. v1 (uint192 integral): reverts with Panic(0x11).
    function test_accumulateReward_Uint192Overflow() public virtual {
        uint40 periodLength = 1 weeks;

        // Setup with 2 tokens — token1 will never receive deposits (mainnet scenario)
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            2,
            periodLength
        );

        // Tiny totalPoolShare amplifies integral growth: toAdd ≈ pending * 1e36
        accumulator.setTotalPoolShare(1, 1 ether);

        uint256 depositAmount = 1000 ether;

        // First deposit to token0 only: sets rate, no accumulation yet
        accumulator.depositReward(tokens[0], depositAmount);

        // Verify token1 has finishAt=0 but lastUpdate>0 (the mainnet precondition)
        (uint256 lastUpdate1, uint256 finishAt1, , ) = accumulator.rewardData(tokens[1]);
        assertEq(finishAt1, 0, "token1: finishAt should remain 0");
        assertEq(lastUpdate1, block.timestamp, "token1: lastUpdate set by _distributePendingReward");

        // 6 weekly cycles: each accumulates ~1e57, total ~6e57 < uint192.max (6.277e57)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], depositAmount);
        }

        // Integral should be near but below uint192 max
        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, (uint256(type(uint192).max) * 90) / 100, "Should be close to uint192 max");
        assertLe(integral, uint256(type(uint192).max), "Should still be under uint192 max");

        // 7th cycle: pushes integral past uint192 max — v2 succeeds (uint256)
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], depositAmount);

        integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, type(uint192).max, "v2: integral should exceed uint192 max");
    }

    /// @notice Verify integral growth matches the theoretical formula:
    ///   delta = rewardAmount * 1e54 / totalPoolShare (at magnitude = 1e36)
    function test_integralGrowth_MatchesFormula() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        // Fresh pool: magnitude = 1e36 (MAGNITUDE_PRECISION), exponent = 0
        accumulator.setTotalPoolShare(1 ether, uint128(1e36));

        uint256 reward = 1000 ether;
        accumulator.depositReward(tokens[0], reward);

        // Warp 1 full period, then trigger accumulation
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], reward);

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // Expected: reward * 1e54 / poolSize = 1e21 * 1e54 / 1e18 = 1e57
        assertApproxEqRel(integral, 1e57, 0.001e18, "delta = reward * 1e54 / poolSize");
    }

    /// @notice A stream that accrues while the pool is EMPTY is re-queued in FULL. `queued` is a uint256 field, so a
    /// large accrued reward - the cheap-collateral scale where a reward token COUNT is largest - must re-queue rather
    /// than be rejected by an artificially narrowed addend.
    function test_accumulateReward_emptyPoolQueuesRewardPastUint96() public {
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            1 weeks
        );

        // stream a reward whose full-period distribution exceeds uint96, while the pool still has share
        accumulator.setTotalPoolShare(1 ether, uint128(1e36));
        uint256 reward = uint256(type(uint96).max) * 2;
        MockERC20(tokens[0]).mint(deployer, reward + 1);
        accumulator.depositReward(tokens[0], reward);

        // the pool empties; the whole distributed stream is then re-queued by _accumulateReward
        accumulator.setTotalPoolShare(0, uint128(1e36));
        vm.warp(block.timestamp + 1 weeks);
        accumulator.depositReward(tokens[0], 1); // checkpoint: accrues the stream into the empty-pool queue

        // That checkpoint re-queues the whole accrued stream and then re-streams it, so the reward now lives in
        // `rate * period` plus the `queued` remainder. Asserting their sum proves the accrual was taken at full width:
        // narrowing the addend to uint96 (as v1 did) rejects this outright with a SafeCast overflow.
        (, , uint256 rate, uint256 queued) = IMultipleRewardDistributor_v3(address(accumulator)).rewardData(tokens[0]);
        assertGe(rate * 1 weeks + queued, reward, "whole accrued reward survived the empty-pool re-queue");
    }

    /// @notice `maxDepositReward` frees the finished stream's capacity at EXACTLY `finishAt`, not one block later. While
    /// the period is active `committed` holds `rate * period`; once `block.timestamp >= finishAt` the stream is fully
    /// distributed and `increase` restreams from a clean slate, so that term drops and the capacity frees. The freeing
    /// must land on the boundary block (`>= finishAt`) to match `increase`: a deposit arriving exactly at `finishAt`
    /// restreams fresh, so its full capacity must be reported. A `<= finishAt` guard would hold the stream one block too
    /// long, stalling recovery on the boundary block.
    function test_maxDepositReward_freesCapacityAtExactlyFinishAt() public {
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            1 weeks
        );
        accumulator.setTotalPoolShare(1 ether, uint128(1e36)); // share present, so the reward streams (sets finishAt)
        accumulator.setMinTotalPoolShare(1 ether); // sizes the deposit cap (integral headroom) so the reward is not capped to 0
        accumulator.depositReward(tokens[0], 1000 ether); // commits `rate * period` for one period, well below that cap

        (, uint256 finishAt, , ) = IMultipleRewardDistributor_v3(address(accumulator)).rewardData(tokens[0]);

        // one block BEFORE the period ends: the stream is active, so `committed` still holds `rate * period`
        vm.warp(finishAt - 1);
        uint256 beforeEnd = IMultipleRewardDistributor_v3(address(accumulator)).maxDepositReward(tokens[0]);

        // AT exactly `finishAt`: the stream is fully distributed, so `committed` drops `rate * period` and frees capacity
        vm.warp(finishAt);
        uint256 atEnd = IMultipleRewardDistributor_v3(address(accumulator)).maxDepositReward(tokens[0]);

        // the freeing lands on the boundary block: `< finishAt` frees here; a mutated `<= finishAt` would still hold it
        assertGt(
            atEnd,
            beforeEnd,
            "capacity frees at exactly finishAt (>= finishAt), matching increase's fresh restream"
        );
    }

    /// @notice `maxLiquidationReward` is the immediate-accrual integral cap sized against the LIVE total share - a
    /// liquidation reward accrues at once (before any loss), so it is bounded against the live share, not the pool
    /// floor the streamed-deposit cap must assume. It is therefore strictly larger while the pool sits above its floor.
    /// `assertDiscriminates` pins it to the live-share value and rejects the floor-share value (the plausible bug:
    /// sizing the immediate cap against the floor, as the streamed cap does).
    function test_maxLiquidationReward_sizedAgainstLiveShare() public {
        (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(1, 1 weeks);

        uint256 liveShare = 1000 ether;
        uint256 floorShare = 1 ether;
        accumulator.setTotalPoolShare(liveShare, uint128(1e36)); // the immediate liquidation accrues against this
        accumulator.setMinTotalPoolShare(floorShare); // the streamed-deposit cap uses this floor

        // uint256.max * share / (_REWARD_PRECISION * MAGNITUDE_PRECISION * _INTEGRAL_HEADROOM) = uint256.max * share / 1e60
        uint256 denominator = uint256(1e18) * 1e36 * 1e6;
        uint256 expectedLive = Math.mulDiv(type(uint256).max, liveShare, denominator);
        uint256 wrongFloor = Math.mulDiv(type(uint256).max, floorShare, denominator);

        assertDiscriminates(
            IMultipleRewardAccumulator(address(accumulator)).maxLiquidationReward(),
            expectedLive,
            0,
            wrongFloor,
            "maxLiquidationReward is the live-share integral cap, not the floor-share one"
        );
    }

    /// @notice An empty pool (no depositors) has no immediate-liquidation reward capacity: a reward would queue rather
    /// than accrue, so the cap is zero.
    function test_maxLiquidationReward_zeroWhenPoolEmpty() public {
        (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(1, 1 weeks);
        accumulator.setTotalPoolShare(0, uint128(1e36));
        assertEq(
            IMultipleRewardAccumulator(address(accumulator)).maxLiquidationReward(),
            0,
            "empty pool: zero liquidation reward capacity"
        );
    }

    /// @notice 52 weeks at 100% APY: integral ~ 1e54, safe for both v1 and v2.
    /// Demonstrates Table 1: at 100% APY, v1 safe for 6,277 years.
    function test_integralBounds_100pctAPY_52Weeks() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        uint256 poolSize = 100_000 ether;
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));

        // 100% APY: annual reward = poolSize, weekly = poolSize / 52
        uint256 weeklyReward = poolSize / 52;

        accumulator.depositReward(tokens[0], weeklyReward);
        for (uint256 i = 0; i < 52; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // After 52 weeks at 100% APY: integral ~ 52 * (poolSize/52) * 1e54 / poolSize = 1e54
        assertApproxEqRel(integral, 1e54, 0.01e18, "52wk at 100% APY: integral ~ 1e54");
        assertLt(integral, type(uint192).max, "Well within v1 uint192 bounds");
    }

    /// @notice 1000% APY for 10 years (520 weeks): integral ~ 1e56.
    /// Demonstrates Table 1: at 1000% APY, v1 has 628 years of headroom.
    /// 10 years uses ~1.6% of the v1 budget (1e56 / 6.277e57).
    function test_integralBounds_1000pctAPY_10Years() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        uint256 poolSize = 1_000 ether;
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));

        // 1000% APY: annual reward = 10 * poolSize, weekly = 10 * poolSize / 52
        uint256 weeklyReward = (poolSize * 10) / 52;

        accumulator.depositReward(tokens[0], weeklyReward);
        for (uint256 i = 0; i < 520; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // After 520 weeks at 1000% APY: integral ~ 520 * (10 * poolSize/52) * 1e54 / poolSize = 1e56
        assertApproxEqRel(integral, 1e56, 0.01e18, "10yr at 1000% APY: integral ~ 1e56");
        assertLt(integral, type(uint192).max, "Still within v1 uint192 bounds (62x headroom)");
    }

    /// @notice Realistic mainnet scenario: BTC MIN_DEPOSIT pool (1e13 wei) with
    /// fresh product (magnitude=1e36) receiving 1e16/week (~$600 at BTC $60k).
    /// Demonstrates Table 2: $600/wk to BTC MIN_DEPOSIT pool overflows v1 in ~7 weeks.
    /// v2 survives. v1 override expects Panic(0x11).
    function test_integralBounds_MinPool_RealisticOverflow() public virtual {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        accumulator.setTotalPoolShare(1e13, uint128(1e36));

        // 0.01 BTC/week ~ $600 at $60k/BTC (1,000x the $0.60 MIN_DEPOSIT pool)
        uint256 weeklyReward = 1e16;

        accumulator.depositReward(tokens[0], weeklyReward);

        // 6 weekly cycles: each adds ~1e57 to integral, total ~6e57 < uint192 max (6.277e57)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, (uint256(type(uint192).max) * 90) / 100, "Near uint192 max after 6 weeks");
        assertLe(integral, type(uint192).max, "Still under uint192 max");

        // 7th week: v2 survives past uint192 max
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], weeklyReward);

        integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, type(uint192).max, "v2: integral exceeds uint192 max");
    }

    /// @notice Minimum meaningful reward (rate=1/sec) to a large pool still
    /// produces non-zero integral and non-zero claimable.
    /// Verifies precision floor: the system handles extreme reward/pool ratios.
    function test_integralBounds_PrecisionFloor() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        uint256 poolSize = 1e25; // very large pool
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));
        accumulator.setUserPoolShare(poolSize, uint128(1e36)); // single user owns all

        // Minimum reward to get rate=1: periodLength + 1 (so rate = 1 per second)
        uint256 minReward = uint256(periodLength) + 1;
        accumulator.depositReward(tokens[0], minReward);

        vm.warp(block.timestamp + periodLength);
        accumulator.checkpoint(deployer); // triggers accumulation + user checkpoint

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // rate=1, accumulated=604800, delta = 604800 * 1e54 / 1e25 = 6.048e34
        assertGt(integral, 0, "Integral non-zero even at minimum rate");
        assertApproxEqRel(integral, 6.048e34, 0.001e18, "Integral matches minimum rate prediction");

        // Verify user can claim a non-zero amount
        uint256 claimable = IMultipleRewardAccumulator(address(accumulator)).claimable(deployer, aa(tokens[0]))[0];
        // claimable = shares * delta / (magnitude * 1e18) = 1e25 * 6.048e34 / 1e54 = 604800
        assertGt(claimable, 0, "User has non-zero claimable at minimum rate");
        assertApproxEqAbs(claimable, 604800, 10, "Claimable matches accumulated amount");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // claim(address[]) — vector claim
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice claim([t1, t2]) returns amounts[] parallel to the token array; ERC-20 balances match.
    function test_claim_vector_returnsAmounts() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(2);

        uint256[] memory balBefore = new uint256[](2);
        balBefore[0] = IERC20(tokenAddresses[0]).balanceOf(deployer);
        balBefore[1] = IERC20(tokenAddresses[1]).balanceOf(deployer);

        uint256[] memory amounts = IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses);

        assertEq(amounts.length, 2, "return length matches token count");
        assertEq(amounts[0], pending[0], "amounts[0] == pending[0]");
        assertEq(amounts[1], pending[1], "amounts[1] == pending[1]");
        assertEq(
            IERC20(tokenAddresses[0]).balanceOf(deployer) - balBefore[0],
            pending[0],
            "balance[0] increased by pending[0]"
        );
        assertEq(
            IERC20(tokenAddresses[1]).balanceOf(deployer) - balBefore[1],
            pending[1],
            "balance[1] increased by pending[1]"
        );
    }

    /// @notice claim(token, maxAmount) return value equals the amount actually transferred.
    function test_claim_scalar_returnsAmount() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        uint256 balBefore = IERC20(tokenAddresses[0]).balanceOf(deployer);
        uint256 returned = IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], type(uint256).max);

        assertEq(returned, pending[0], "returned == pending");
        assertEq(IERC20(tokenAddresses[0]).balanceOf(deployer) - balBefore, returned, "balance increase == returned");
    }

    /// @notice claim([t, t]) returns [pending, 0]: first entry claims the full pending; second
    /// entry finds pending zeroed after the first — no double-counting.
    function test_claim_vector_duplicateToken() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        address[] memory twoSame = new address[](2);
        twoSame[0] = tokenAddresses[0];
        twoSame[1] = tokenAddresses[0];

        uint256[] memory amounts = IMultipleRewardAccumulator(address(accumulator)).claim(twoSame);

        assertEq(amounts.length, 2, "return length == 2");
        assertEq(amounts[0], pending[0], "first entry claims full pending");
        assertEq(amounts[1], 0, "second entry finds pending zeroed - no double-count");
    }

    /// @notice claim([]) returns an empty uint256[] and does not revert.
    function test_claim_vector_emptyArray() public {
        (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(1, 1 weeks);
        accumulator.setTotalPoolShare(1000 ether, 1 ether);
        accumulator.setUserPoolShare(1000 ether, 1 ether);

        address[] memory empty = new address[](0);
        uint256[] memory amounts = IMultipleRewardAccumulator(address(accumulator)).claim(empty);

        assertEq(amounts.length, 0, "empty token list returns zero-length result");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // claim(token, maxAmount) — single-token capped claim
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Stake the test contract, deposit rewards, warp the full period and checkpoint —
    /// so each token has a known, non-zero pending read straight from the snapshot
    /// (source of truth — avoids replicating the integral math here).
    function _stakeAndAccruePending(
        uint256 rewardCount
    )
        internal
        returns (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        )
    {
        uint40 periodLength = 1 weeks;
        (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);
        accumulator.setTotalPoolShare(1234 ether, 1 ether);
        accumulator.setUserPoolShare(456 ether, 1 ether);
        // Different deposit per token so the multi-token test exercises distinct pending values.
        for (uint256 j = 0; j < rewardCount; j++) {
            accumulator.depositReward(tokenAddresses[j], 1000 ether * (j + 1));
        }
        vm.warp(block.timestamp + periodLength);
        accumulator.checkpoint(deployer);
        pending = new uint256[](rewardCount);
        for (uint256 j = 0; j < rewardCount; j++) {
            (, , uint256 p, ) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
            require(p > 0, "no pending: bad setup");
            pending[j] = p;
        }
    }

    /// @notice maxAmount below pending: exactly maxAmount is transferred and the remainder
    /// is left in pending. claimed advances by maxAmount.
    function test_claim_single_capBindsBelowPending_partialTransfer() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        uint256 cap = pending[0] / 3;
        uint256 balBefore = IERC20(tokenAddresses[0]).balanceOf(deployer);

        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], cap);

        assertEq(IERC20(tokenAddresses[0]).balanceOf(deployer) - balBefore, cap, "transferred == cap");
        (, , uint256 pendingAfter, uint256 claimedAfter) = accumulator.userRewardSnapshot(deployer, tokenAddresses[0]);
        assertEq(claimedAfter, cap, "claimed += cap");
        assertEq(pendingAfter, pending[0] - cap, "pending -= cap");
    }

    /// @notice maxAmount at or above pending: the full pending is paid out and pending goes to zero.
    function test_claim_single_capAtOrAbovePending_fullTransfer() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        uint256 balBefore = IERC20(tokenAddresses[0]).balanceOf(deployer);

        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], pending[0] * 10);

        assertEq(IERC20(tokenAddresses[0]).balanceOf(deployer) - balBefore, pending[0], "transferred == full pending");
        (, , uint256 pendingAfter, uint256 claimedAfter) = accumulator.userRewardSnapshot(deployer, tokenAddresses[0]);
        assertEq(pendingAfter, 0, "pending zeroed");
        assertEq(claimedAfter, pending[0], "claimed == original pending");
    }

    /// @notice maxAmount is applied INDEPENDENTLY per token via separate claim(token,cap) calls.
    function test_claim_single_capAppliedPerTokenIndependently() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(3);

        // Pick a cap that binds on every token (smaller than the smallest pending).
        uint256 cap = pending[0];
        for (uint256 j = 1; j < pending.length; j++) {
            if (pending[j] < cap) {
                cap = pending[j];
            }
        }
        cap = cap / 2;

        uint256[] memory balBefore = new uint256[](3);
        for (uint256 j = 0; j < 3; j++) {
            balBefore[j] = IERC20(tokenAddresses[j]).balanceOf(deployer);
        }

        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], cap);
        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[1], cap);
        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[2], cap);

        for (uint256 j = 0; j < 3; j++) {
            string memory tag = string.concat(" (token ", vm.toString(j), ")");
            assertEq(
                IERC20(tokenAddresses[j]).balanceOf(deployer) - balBefore[j],
                cap,
                string.concat("transferred == cap per token", tag)
            );
            (, , uint256 pendingAfter, uint256 claimedAfter) = accumulator.userRewardSnapshot(
                deployer,
                tokenAddresses[j]
            );
            assertEq(claimedAfter, cap, string.concat("claimed == cap", tag));
            assertEq(pendingAfter, pending[j] - cap, string.concat("pending -= cap", tag));
        }
    }

    /// @notice maxAmount == 0 is a no-op: no transfer, pending unchanged, claimed unchanged.
    function test_claim_single_capZero_noTransfer() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        uint256 balBefore = IERC20(tokenAddresses[0]).balanceOf(deployer);

        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], 0);

        assertEq(IERC20(tokenAddresses[0]).balanceOf(deployer), balBefore, "no tokens transferred");
        (, , uint256 pendingAfter, uint256 claimedAfter) = accumulator.userRewardSnapshot(deployer, tokenAddresses[0]);
        assertEq(pendingAfter, pending[0], "pending unchanged");
        assertEq(claimedAfter, 0, "claimed unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Historical token behaviour — claimable/claimed/claim work for
    // deregistered tokens. Verifies the §N plan assumption that the SP
    // accumulator treats active and historical tokens identically for claims.
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Distribute 1000 ether over one period, checkpoint deployer (100% shares),
    /// then deregister so the token is in historicalRewardTokens with a known
    /// exact pending. Returns the exact pendingAtCheckpoint read from storage
    /// (the authoritative source — no math replication needed).
    function _earnCheckpointDeregister() internal returns (address acc, address token, uint256 pendingAtCheckpoint) {
        (IMockMultipleRewardCompoundingAccumulator tmpAcc, address[] memory tokens) = _setupAccumulator(1, 1 weeks);
        acc = address(tmpAcc);
        token = tokens[0];

        IMockMultipleRewardCompoundingAccumulator(acc).setTotalPoolShare(1000 ether, 1 ether);
        IMockMultipleRewardCompoundingAccumulator(acc).setUserPoolShare(1000 ether, 1 ether); // deployer owns 100%

        IMockMultipleRewardCompoundingAccumulator(acc).depositReward(token, 1000 ether);
        vm.warp(block.timestamp + 1 weeks);

        // Checkpoint deployer: locks accrued rewards into snapshot.pending.
        IMultipleRewardAccumulator(acc).checkpoint(deployer);
        (, , pendingAtCheckpoint, ) = IMockMultipleRewardCompoundingAccumulator(acc).userRewardSnapshot(
            deployer,
            token
        );
        require(pendingAtCheckpoint > 0, "_earnCheckpointDeregister: no pending");

        // Move token to historical set.
        vm.prank(manager);
        IMockMultipleRewardCompoundingAccumulator(acc).unregisterRewardToken(token);
        assertFalse(
            IMockMultipleRewardCompoundingAccumulator(acc).isActiveRewardToken(token),
            "token should be historical"
        );
    }

    /// @notice claimable() returns the exact snapshot.pending after deregistration.
    /// After checkpoint + deregistration, the integral is frozen and temporal rewards
    /// are zero, so claimable = snapshot.pending exactly.
    function test_historicalToken_claimable_correctAfterDeregistration() public {
        (address acc, address token, uint256 pendingAtCheckpoint) = _earnCheckpointDeregister();

        uint256 claimable = IMultipleRewardAccumulator(acc).claimable(deployer, aa(token))[0];
        assertEq(claimable, pendingAtCheckpoint, "claimable == snapshot.pending (exact)");
    }

    /// @notice claim(vector) transfers exactly snapshot.pending for a historical token.
    function test_historicalToken_claim_vector_transfersCorrectAmount() public {
        (address acc, address token, uint256 pendingAtCheckpoint) = _earnCheckpointDeregister();

        address[] memory toks = new address[](1);
        toks[0] = token;
        uint256 balBefore = IERC20(token).balanceOf(deployer);

        IMultipleRewardAccumulator(acc).claim(toks);

        assertEq(IERC20(token).balanceOf(deployer) - balBefore, pendingAtCheckpoint, "received == snapshot.pending");
    }

    /// @notice After a full claim, claimed == original pending and claimable == 0.
    function test_historicalToken_claimed_tracksPaymentToZero() public {
        (address acc, address token, uint256 pendingAtCheckpoint) = _earnCheckpointDeregister();

        address[] memory toks = new address[](1);
        toks[0] = token;
        IMultipleRewardAccumulator(acc).claim(toks);

        (, , uint256 pendingAfter, uint256 claimedAfter) = IMockMultipleRewardCompoundingAccumulator(acc)
            .userRewardSnapshot(deployer, token);
        assertEq(claimedAfter, pendingAtCheckpoint, "claimed == original pending");
        assertEq(pendingAfter, 0, "pending zeroed after full claim");
        assertEq(
            IMultipleRewardAccumulator(acc).claimable(deployer, aa(token))[0],
            0,
            "claimable == 0 after full claim"
        );
    }

    /// @notice An account with zero pool shares and no prior checkpoint earns nothing.
    /// Uses manager (never checkpointed) with global shares set to 0: pending=0,
    /// accrual = 0*integral = 0, temporal = 0 => claimable = 0.
    function test_historicalToken_zeroShares_hasZeroClaimable() public {
        (address acc, address token, ) = _earnCheckpointDeregister();

        // Set global shares to 0. manager was never checkpointed so snapshot.pending = 0.
        IMockMultipleRewardCompoundingAccumulator(acc).setUserPoolShare(0, 1 ether);

        assertEq(IMultipleRewardAccumulator(acc).claimable(manager, aa(token))[0], 0, "zero shares: zero claimable");
    }

    /// @notice Gap scenario: if shares decrease AFTER rewards accumulate into the integral
    /// but BEFORE the user snapshot is checkpointed, the claim uses the post-change share
    /// count. This demonstrates why AC's _beforeTokenTransfer must checkpoint historical
    /// tokens before allowing share transfers.
    function test_historicalToken_gapScenario_shareCountUsedAtClaimTime() public {
        (IMockMultipleRewardCompoundingAccumulator tmpAcc, address[] memory tokens) = _setupAccumulator(1, 1 weeks);
        address acc = address(tmpAcc);
        address token = tokens[0];

        IMockMultipleRewardCompoundingAccumulator(acc).setTotalPoolShare(1000 ether, 1 ether);
        IMockMultipleRewardCompoundingAccumulator(acc).setUserPoolShare(1000 ether, 1 ether); // deployer has 100%

        IMockMultipleRewardCompoundingAccumulator(acc).depositReward(token, 1000 ether);
        vm.warp(block.timestamp + 1 weeks);

        // Global checkpoint only — deployer's user snapshot is NOT updated.
        IMultipleRewardAccumulator(acc).checkpoint(address(0));

        // Deregister: no more rewards accumulate.
        vm.prank(manager);
        IMockMultipleRewardCompoundingAccumulator(acc).unregisterRewardToken(token);

        // Correct entitlement (1000e18 shares = 100%): read from view before changing shares.
        uint256 correctEntitlement = IMultipleRewardAccumulator(acc).claimable(deployer, aa(token))[0];
        assertGt(correctEntitlement, 0, "should have earned rewards");

        // Shares halved WITHOUT prior checkpoint — this is the gap.
        IMockMultipleRewardCompoundingAccumulator(acc).setUserPoolShare(500 ether, 1 ether);

        // What the view reports with the post-gap share count.
        uint256 gapEntitlement = IMultipleRewardAccumulator(acc).claimable(deployer, aa(token))[0];
        assertLt(gapEntitlement, correctEntitlement, "gap: half shares gives less claimable");

        // Claim transfers exactly what the view reported — no surprise, no rounding.
        address[] memory toks = new address[](1);
        toks[0] = token;
        uint256 balBefore = IERC20(token).balanceOf(deployer);
        IMultipleRewardAccumulator(acc).claim(toks);

        assertEq(IERC20(token).balanceOf(deployer) - balBefore, gapEntitlement, "received == gapEntitlement (exact)");
    }

    /// @notice After a partial cap-bound claim, the remainder is still claimable in a second uncapped call
    /// (no new rewards accrue because we don't advance time).
    function test_claim_single_remainderClaimableAfterPartial() public {
        (
            IMockMultipleRewardCompoundingAccumulator accumulator,
            address[] memory tokenAddresses,
            uint256[] memory pending
        ) = _stakeAndAccruePending(1);

        uint256 firstCap = pending[0] / 4;
        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], firstCap);

        uint256 balBefore = IERC20(tokenAddresses[0]).balanceOf(deployer);
        IMultipleRewardAccumulator(address(accumulator)).claim(tokenAddresses[0], type(uint256).max);

        assertEq(
            IERC20(tokenAddresses[0]).balanceOf(deployer) - balBefore,
            pending[0] - firstCap,
            "second claim drains the remainder"
        );
        (, , uint256 pendingAfter, uint256 claimedAfter) = accumulator.userRewardSnapshot(deployer, tokenAddresses[0]);
        assertEq(pendingAfter, 0, "pending fully drained");
        assertEq(claimedAfter, pending[0], "claimed == original pending");
    }

    /// @notice `claimable` must hold at the reward cap even when the pool-share floor is large. The temporal-pending
    /// term forms `amount * shares` as a plain uint256 intermediate, but the two factors are bounded INDEPENDENTLY:
    /// the reward-integral cap sizes `amount` against the FLOOR (`_minTotalShare`), while `shares` is bounded by the
    /// pool's own field width. At a large floor a cap-sized reward times a field-sized share exceeds uint256 and the
    /// view reverts - a holder whose claimable cannot be read is the same failure class as one whose balance cannot be.
    function test_claimable_holdsAtTheRewardCapWithALargeFloor() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) = _setupAccumulator(
            1,
            periodLength
        );

        // A large floor raises the reward-integral cap; a field-sized share is the largest a pool can credit.
        accumulator.setMinTotalPoolShare(1e24);
        accumulator.setTotalPoolShare(1e38, uint128(1e36));
        accumulator.setUserPoolShare(1e38, uint128(1e36));

        uint256 reward = IMultipleRewardDistributor_v3(address(accumulator)).maxDepositReward(tokens[0]);
        MockERC20(tokens[0]).mint(deployer, reward);
        accumulator.depositReward(tokens[0], reward);

        // mid-period: the un-distributed remainder is the temporal-pending `amount`
        vm.warp(block.timestamp + periodLength / 2);

        uint256 claimable = IMultipleRewardAccumulator(address(accumulator)).claimable(deployer, aa(tokens[0]))[0];
        assertLe(claimable, reward, "claimable cannot exceed the reward injected");
    }
}
