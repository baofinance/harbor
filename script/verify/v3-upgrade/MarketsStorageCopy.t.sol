// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {StabilityPoolRewardRecordLib} from "@harbor-test/harness/StabilityPoolRewardRecordLib.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

/// @title MarketsStorageCopy - Prong B of the v3 upgrade's verification
/// @notice White-box check of the storage the upgrade copies, which the before/after record (Prong A) sees only
///         through views - a holder's checkpoint integral and timestamp through nothing but claimable. For every pool:
///         each captured holder's reward record for each reward token - pending, claimed, timestamp, integral - read in
///         its V2 layout at the block of the upgrade's capture, `FROZEN_MARKETS_CAPTURE`, equals its V3 record after the
///         upgrade; each reward token's stream reads
///         the same; and the ledger gap the upgrade wrote is the pool's supply less what the captured holders held.
///
///         Runs against anvil after the upgrade script (`--fork-url local`, by run-upgrade-rehearsal), and forks
///         mainnet at the capture's block itself for the V2 side: the pools are frozen, so that is the state the
///         upgrade copied.
contract MarketsStorageCopy is Test, HarborDeployer {
    Config_MinterMarket[] internal markets;

    function setUp() public {
        _setSaltPrefix("harbor_v1");
        markets = allMintersConfig();
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
    }

    /// @notice Every pool's reward records, streams and ledger gap were copied exactly.
    function test_everyPoolsStorageIsCopied() public {
        uint256 upgraded = vm.activeFork();
        uint256 frozen = vm.createFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE));
        uint256 records;
        for (uint256 i = 0; i < markets.length; ++i) {
            records += _checkPool(markets[i], StabilityPoolType.Collateral, upgraded, frozen);
            records += _checkPool(markets[i], StabilityPoolType.Leveraged, upgraded, frozen);
        }
        console.log("reward records with data, compared:", records);
        assertGt(records, 0, "no reward record had data to compare - the holder lists or the slot reads are wrong");
    }

    /// @dev Check one pool; return how many of its reward records had data.
    function _checkPool(
        Config_MinterMarket market,
        StabilityPoolType poolType,
        uint256 upgraded,
        uint256 frozen
    ) private returns (uint256 records) {
        string memory label = stabilityPoolKey(market, poolType);
        address pool = stabilityPoolAddress(market, poolType);
        address[] memory holders = HolderCaptureLib.holders(FROZEN_MARKETS_CAPTURE, label);

        vm.selectFork(upgraded);
        address[] memory tokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        StabilityPoolRewardRecordLib.RewardRecord[] memory copied = new StabilityPoolRewardRecordLib.RewardRecord[](
            holders.length * tokens.length
        );
        for (uint256 h = 0; h < holders.length; ++h) {
            for (uint256 t = 0; t < tokens.length; ++t) {
                copied[h * tokens.length + t] = StabilityPoolRewardRecordLib.v3Record(pool, holders[h], tokens[t]);
            }
        }
        bytes memory streamsAfter = _streams(pool, tokens);
        int256 gapWritten = _rewardDivisorGap(pool);

        vm.selectFork(frozen);
        assertEq(
            IMultipleRewardDistributor(pool).activeRewardTokens(),
            tokens,
            string.concat(label, ": the reward tokens are kept")
        );
        assertEq(_streams(pool, tokens), streamsAfter, string.concat(label, ": every reward stream is copied"));
        uint256 held;
        for (uint256 h = 0; h < holders.length; ++h) {
            held += IStabilityPool_v3(pool).assetBalanceOf(holders[h]);
            for (uint256 t = 0; t < tokens.length; ++t) {
                StabilityPoolRewardRecordLib.RewardRecord memory original = StabilityPoolRewardRecordLib.v2Record(
                    pool,
                    holders[h],
                    tokens[t]
                );
                StabilityPoolRewardRecordLib.RewardRecord memory copy = copied[h * tokens.length + t];
                string memory what = string.concat(label, " ", vm.toString(holders[h]), " token ", vm.toString(t));
                assertEq(copy.pending, original.pending, string.concat(what, ": pending copied"));
                assertEq(copy.claimed, original.claimed, string.concat(what, ": claimed copied"));
                assertEq(copy.timestamp, original.timestamp, string.concat(what, ": timestamp copied"));
                assertEq(copy.integral, original.integral, string.concat(what, ": integral copied"));
                if (original.timestamp != 0) {
                    ++records;
                }
            }
        }
        assertEq(
            gapWritten,
            int256(IStabilityPool_v3(pool).totalAssetSupply()) - int256(held),
            string.concat(label, ": the ledger gap written is the supply less what the captured holders held")
        );
        vm.selectFork(upgraded);
    }

    /// @dev Each reward stream of `tokens` on `pool`, encoded: both versions report it alike.
    function _streams(address pool, address[] memory tokens) private view returns (bytes memory streams) {
        for (uint256 t = 0; t < tokens.length; ++t) {
            (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool)
                .rewardData(tokens[t]);
            streams = bytes.concat(streams, abi.encode(lastUpdate, finishAt, rate, queued));
        }
    }

    /// @dev StabilityPool_v3's reward-divisor gap, which it keeps internal: read through `MockStabilityPool` - v3 with
    ///      accessors added, built with the pool's own settings - put in place of the pool's code inside a snapshot that
    ///      is then reverted.
    function _rewardDivisorGap(address pool) private returns (int256 gap) {
        uint256 snapshot = vm.snapshotState();
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(pool).getWithdrawalWindow();
        address exposer = address(
            new MockStabilityPool(
                IStabilityPool_v3(pool).MINTER(),
                IStabilityPool_v3(pool).ASSET_TOKEN(),
                startDelay,
                endWindow,
                IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY(),
                IERC20Metadata(pool).name(),
                IERC20Metadata(pool).symbol()
            )
        );
        vm.etch(pool, exposer.code);
        gap = MockStabilityPool(pool).__rewardDivisorGap();
        vm.revertToState(snapshot);
    }
}
