// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {frozenMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";

import {StabilityPoolRewardRecordLib} from "@harbor-test/harness/StabilityPoolRewardRecordLib.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

/// @title MarketsStorageCopy - Prong B of the v3 upgrade's verification
/// @notice White-box check of the storage the upgrade copies, which the before/after record (Prong A) sees only
///         through views - a holder's checkpoint integral and timestamp through nothing but claimable. For every pool:
///         each captured holder's reward record for each reward token - pending, claimed, timestamp, integral - read in
///         its V2 layout at the block of the upgrade's capture, `FROZEN_MARKETS_CAPTURE`, equals its V3 record after the
///         upgrade; each reward token's stream reads the same; and the ledger gap the upgrade wrote is the pool's supply
///         less what the captured holders held.
///
///         A pool whose migration takes rewards back (the compensation's deductions, read from the incident's files)
///         is checked for what that migration does instead: every stream, and every record of each holder a reward is
///         taken from - for every reward token, the checkpoint settling the holder whole - is settled at one moment,
///         the migration's; each such record then holds exactly what its account may claim at that moment, which is
///         what it could claim on the frozen pool at that moment, less its cut where one was taken in that token; its
///         claimed is copied; every other holder's records are copied exactly.
///
///         Runs against anvil after the upgrade script (`--fork-url local`, by run-upgrade-rehearsal), and forks
///         mainnet at the capture's block itself for the V2 side: the pools are frozen, so that is the state the
///         upgrade copied.
contract MarketsStorageCopy is BaoTest, HarborDeployer {
    Config_MinterMarket[] internal markets;

    /// @dev The compensation's own functions, for the deductions each pool's migration takes.
    CompensationRun internal compensation;

    /// @dev One reward stream, as both versions report it.
    struct Stream {
        uint256 lastUpdate;
        uint256 finishAt;
        uint256 rate;
        uint256 queued;
    }

    function setUp() public {
        _setSaltPrefix("harbor_v1");
        markets = frozenMintersConfig();
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
        string[] memory files = new string[](2);
        files[0] = BTC_STETH_COMPENSATION;
        files[1] = EUR_STETH_COMPENSATION;
        compensation = new CompensationRun("harbor_v1", markets, FROZEN_MARKETS_CAPTURE, files);
        vm.makePersistent(address(compensation));
    }

    /// @notice Every pool's reward records, streams and ledger gap were copied exactly, but for what a migration taking
    ///         rewards back settles.
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

    /// @dev What the upgraded pool holds: its reward tokens, each captured holder's record for each, each stream, the
    ///      ledger gap written, and - where the migration took rewards back - the moment it settled them at.
    struct Upgraded {
        address[] tokens;
        StabilityPoolRewardRecordLib.RewardRecord[] copied;
        Stream[] streams;
        int256 gap;
        uint256 settledAt;
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
        IStabilityPool_v3_Upgrader.Deduction[] memory taken = _deductionsOf(market, poolType);

        vm.selectFork(upgraded);
        Upgraded memory u = _readUpgraded(label, pool, holders, taken);

        vm.selectFork(frozen);
        records = _checkAgainstFrozen(label, pool, holders, taken, u);
        vm.selectFork(upgraded);
    }

    /// @dev Read the upgraded pool, check no captured holder has a fee-free amount, and check each deducted holder's every
    ///      record is settled.
    function _readUpgraded(
        string memory label,
        address pool,
        address[] memory holders,
        IStabilityPool_v3_Upgrader.Deduction[] memory taken
    ) private returns (Upgraded memory u) {
        u.tokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        u.copied = new StabilityPoolRewardRecordLib.RewardRecord[](holders.length * u.tokens.length);
        for (uint256 h = 0; h < holders.length; ++h) {
            assertEq(
                IStabilityPool_v3(pool).getWithdrawalFeeFreeAmount(holders[h]),
                0,
                string.concat(label, " ", vm.toString(holders[h]), ": a request carried from v2 makes nothing fee-free")
            );
            for (uint256 t = 0; t < u.tokens.length; ++t) {
                u.copied[h * u.tokens.length + t] = StabilityPoolRewardRecordLib.v3Record(
                    pool,
                    holders[h],
                    u.tokens[t]
                );
            }
        }
        u.streams = _streams(pool, u.tokens);
        u.gap = _rewardDivisorGap(pool);
        // A migration taking rewards back settles every stream, and each deducted holder's every record, at one
        // moment: its own. Every active stream's last update is that moment.
        u.settledAt = taken.length > 0 ? u.streams[0].lastUpdate : 0;
        for (uint256 d = 0; d < taken.length; ++d) {
            uint256 h = _indexOf(holders, taken[d].account);
            for (uint256 t = 0; t < u.tokens.length; ++t) {
                _checkSettled(
                    pool,
                    u.copied[h * u.tokens.length + t],
                    taken[d].account,
                    u.tokens[t],
                    u.settledAt,
                    label
                );
            }
        }
    }

    /// @dev On the frozen pool: the reward tokens kept, each stream copied or folded, each record copied or deducted,
    ///      and the ledger gap; return how many records had data.
    function _checkAgainstFrozen(
        string memory label,
        address pool,
        address[] memory holders,
        IStabilityPool_v3_Upgrader.Deduction[] memory taken,
        Upgraded memory u
    ) private returns (uint256 records) {
        assertEq(
            IMultipleRewardDistributor(pool).activeRewardTokens(),
            u.tokens,
            string.concat(label, ": the reward tokens are kept")
        );
        Stream[] memory frozenStreams = _streams(pool, u.tokens);
        _checkStreams(label, taken.length > 0, u, frozenStreams);
        uint256 held;
        RecordCheck memory c;
        c.pool = pool;
        c.settledAt = u.settledAt;
        c.supply = IStabilityPool_v3(pool).totalAssetSupply();
        c.gap = u.gap;
        for (uint256 h = 0; h < holders.length; ++h) {
            held += IStabilityPool_v3(pool).assetBalanceOf(holders[h]);
            c.holder = holders[h];
            c.settled = _isDeducted(taken, holders[h]);
            for (uint256 t = 0; t < u.tokens.length; ++t) {
                c.what = string.concat(label, " ", vm.toString(holders[h]), " token ", vm.toString(t));
                c.token = u.tokens[t];
                c.copy = u.copied[h * u.tokens.length + t];
                c.cut = _cutOf(taken, holders[h], u.tokens[t]);
                c.stream = frozenStreams[t];
                if (_checkRecord(c)) {
                    ++records;
                }
            }
        }
        assertEq(
            u.gap,
            int256(c.supply) - int256(held),
            string.concat(label, ": the ledger gap written is the supply less what the captured holders held")
        );
    }

    /// @dev One record to check on the frozen pool: whose and which token, its copy, whether the migration settled
    ///      the holder - a reward was taken from it, in this token or another - and the cut taken in this token, the
    ///      stream of its token, the moment the migration settled at, and the pool's supply and ledger gap.
    struct RecordCheck {
        string what;
        address pool;
        address holder;
        address token;
        StabilityPoolRewardRecordLib.RewardRecord copy;
        bool settled;
        uint256 cut;
        Stream stream;
        uint256 settledAt;
        uint256 supply;
        int256 gap;
    }

    /// @dev Each stream: copied exactly, or - where the migration took rewards back - folded at its moment, which is
    ///      after the stream's last update.
    function _checkStreams(
        string memory label,
        bool folded,
        Upgraded memory u,
        Stream[] memory frozenStreams
    ) private pure {
        for (uint256 t = 0; t < u.tokens.length; ++t) {
            string memory stream = string.concat(label, " stream ", vm.toString(t));
            assertEq(u.streams[t].finishAt, frozenStreams[t].finishAt, string.concat(stream, ": finishAt copied"));
            assertEq(u.streams[t].rate, frozenStreams[t].rate, string.concat(stream, ": rate copied"));
            assertEq(u.streams[t].queued, frozenStreams[t].queued, string.concat(stream, ": queued copied"));
            if (!folded) {
                assertEq(
                    u.streams[t].lastUpdate,
                    frozenStreams[t].lastUpdate,
                    string.concat(stream, ": lastUpdate copied")
                );
            } else {
                assertEq(
                    u.streams[t].lastUpdate,
                    u.settledAt,
                    string.concat(stream, ": folded at the migration's moment")
                );
                assertGt(
                    u.settledAt,
                    frozenStreams[t].lastUpdate,
                    string.concat(stream, ": which is after its last update")
                );
            }
        }
    }

    /// @dev One record on the frozen pool against its copy: copied exactly where the migration did not settle its
    ///      holder, settled otherwise; return whether it had data.
    function _checkRecord(RecordCheck memory c) private returns (bool hadData) {
        StabilityPoolRewardRecordLib.RewardRecord memory original = StabilityPoolRewardRecordLib.v2Record(
            c.pool,
            c.holder,
            c.token
        );
        if (!c.settled) {
            assertEq(c.copy.pending, original.pending, string.concat(c.what, ": pending copied"));
            assertEq(c.copy.claimed, original.claimed, string.concat(c.what, ": claimed copied"));
            assertEq(c.copy.timestamp, original.timestamp, string.concat(c.what, ": timestamp copied"));
            assertEq(c.copy.integral, original.integral, string.concat(c.what, ": integral copied"));
        } else {
            _checkSettledOnFrozen(c, original);
        }
        return original.timestamp != 0;
    }

    /// @dev On the upgraded pool, at the moment it was settled, a settled record holds exactly what its account may
    ///      claim of that token: nothing has accrued since.
    function _checkSettled(
        address pool,
        StabilityPoolRewardRecordLib.RewardRecord memory copy,
        address account,
        address token,
        uint256 settledAt,
        string memory label
    ) private {
        address[] memory one = new address[](1);
        one[0] = token;
        uint256 now_ = block.timestamp;
        vm.warp(settledAt);
        assertEq(
            copy.pending,
            IMultipleRewardAccumulator_v3(pool).claimable(account, one)[0],
            string.concat(label, " ", vm.toString(account), ": the record holds what it may claim when settled")
        );
        vm.warp(now_);
    }

    /// @dev On the frozen pool, a settled record: its claimed copied, its timestamp the migration's moment, and its
    ///      pending what the account could claim at that moment on the frozen pool - the stream extended to it - less
    ///      the cut taken in its token, if any; to the shift of the stream the migration folded, which v3 divides by
    ///      the supply less the gap where v2 divided by the supply, and a wei at each of two floors; a cut telling
    ///      against no cut.
    function _checkSettledOnFrozen(
        RecordCheck memory c,
        StabilityPoolRewardRecordLib.RewardRecord memory original
    ) private {
        assertEq(c.copy.claimed, original.claimed, string.concat(c.what, ": claimed copied"));
        assertEq(c.copy.timestamp, c.settledAt, string.concat(c.what, ": settled at the migration's moment"));
        uint256 now_ = block.timestamp;
        vm.warp(c.settledAt);
        uint256 couldClaim = IMultipleRewardAccumulator(c.pool).claimable(c.holder, c.token);
        vm.warp(now_);
        uint256 end = Math.min(c.settledAt, c.stream.finishAt);
        uint256 folded = end > c.stream.lastUpdate ? c.stream.rate * (end - c.stream.lastUpdate) : 0;
        uint256 tolerance = Math.mulDiv(
            folded,
            c.gap < 0 ? uint256(-c.gap) : uint256(c.gap),
            uint256(int256(c.supply) - c.gap)
        ) + 2;
        if (c.cut == 0) {
            assertApprox(
                c.copy.pending,
                couldClaim,
                tolerance,
                string.concat(c.what, ": pending is what it could claim when settled, nothing taken in this token")
            );
        } else {
            assertDiscriminates(
                c.copy.pending,
                couldClaim - c.cut,
                tolerance,
                couldClaim,
                string.concat(c.what, ": pending is what it could claim when settled, less the cut, not uncut")
            );
        }
    }

    /// @dev Whether a reward was taken from `holder` in this pool, in any token: the migration then settled every
    ///      record of its.
    function _isDeducted(
        IStabilityPool_v3_Upgrader.Deduction[] memory taken,
        address holder
    ) private pure returns (bool) {
        for (uint256 d = 0; d < taken.length; ++d) {
            if (taken[d].account == holder) {
                return true;
            }
        }
        return false;
    }

    /// @dev The deductions the `poolType` pool's migration takes: the compensation's, for a leveraged pool of a market
    ///      the incident's files describe; none otherwise.
    function _deductionsOf(
        Config_MinterMarket market,
        StabilityPoolType poolType
    ) private returns (IStabilityPool_v3_Upgrader.Deduction[] memory) {
        if (poolType == StabilityPoolType.Leveraged) {
            bytes32 name = keccak256(bytes(MinterMarketConfigLib.salt(market)));
            string[2] memory files = [BTC_STETH_COMPENSATION, EUR_STETH_COMPENSATION];
            for (uint256 f = 0; f < files.length; ++f) {
                CompensateRebalanceDilution.MarketCompensation memory m = compensation.read(files[f]);
                if (keccak256(bytes(m.name)) == name) {
                    return compensation.deductionsOf(m);
                }
            }
        }
        return new IStabilityPool_v3_Upgrader.Deduction[](0);
    }

    function _cutOf(
        IStabilityPool_v3_Upgrader.Deduction[] memory taken,
        address holder,
        address token
    ) private pure returns (uint256) {
        for (uint256 d = 0; d < taken.length; ++d) {
            if (taken[d].account == holder && taken[d].token == token) {
                return taken[d].amount;
            }
        }
        return 0;
    }

    function _indexOf(address[] memory list, address wanted) private pure returns (uint256) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == wanted) {
                return i;
            }
        }
        revert("a deduction names an account or token the pool does not list");
    }

    /// @dev Each reward stream of `tokens` on `pool`: both versions report it alike.
    function _streams(address pool, address[] memory tokens) private view returns (Stream[] memory streams) {
        streams = new Stream[](tokens.length);
        for (uint256 t = 0; t < tokens.length; ++t) {
            (
                streams[t].lastUpdate,
                streams[t].finishAt,
                streams[t].rate,
                streams[t].queued
            ) = IMultipleRewardDistributor(pool).rewardData(tokens[t]);
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
