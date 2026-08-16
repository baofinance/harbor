// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

/// @title StabilityPoolMigrationPreflight — is every deployed pool safe to upgrade v2->v3 with a plain upgrade?
/// @notice The v2->v3 reward-divisor migration relies on the delta encoding: a plain `upgradeToAndCall(v3)` leaves
///         `rewardDivisorGap` zero-initialised, so the reward divisor reads `totalAssetSupply.amount`, which is
///         `>= Sum(balanceOf)` only when the pool's ledger gap `supply - Sum(balanceOf)` is >= 0. This pre-flight
///         measures that gap for every deployed StabilityPool on a mainnet fork and classifies each:
///           - `plain`     : gap >= 0  -> a plain upgrade is safe (divisor = supply >= Sum(balanceOf));
///           - `seed`      : gap  < 0  -> a plain upgrade would over-credit; seed the divisor via the SeedUpgrader
///                                        (`seedAndUpgrade(holders, v3)`) instead;
///           - `empty`     : no captured holders and totalSupply == 0 -> nothing to migrate;
///           - `recapture` : the captured holders do not account for the supply -> the list is stale, re-capture.
///
///         It also gates - orthogonally to the gap - on the SUPPLY CEILING v3 will enforce
///         (`MIN_TOTAL_ASSET_SUPPLY * FACTOR_PRECISION`, saturated at the supply field width). The migration does not
///         go through the deposit path where v3 checks that ceiling, so a pool already above it would migrate into a
///         state where a floor-capped liquidation zeroes the product factor; such a pool needs its floor re-based
///         before it can migrate at all, whatever its gap says.
///
///         PASSES iff every deployed pool is `plain` or `empty` (a plain all-pools upgrade is safe), sits within the
///         supply ceiling, AND the measurement is reliable. FAILS - naming the pool - if any needs a `seed`, exceeds
///         the ceiling, has an incomplete/stale holder list, or the harness did not run.
///         Per-pool results -> ./results/sp-pool-gaps.csv.
///
///         RUN AT MIGRATION TIME:
///           1. Pause the pools (freeze state) and re-capture the holder .txt files up to the migration block.
///           2. Set CAPTURE_BLOCK to that block.
///           3. `forge test --mc StabilityPoolMigrationPreflight -vv`  (needs MAINNET_RPC_URL, archival at the block).
///           4. Green -> plain-upgrade every pool. Red -> the message names the pool(s) to seed or re-capture.
///
///         Read-only. Reuses the market enumeration + captured holder files from Migrate_StabilityPool_v2_Data_mainnet.
contract StabilityPoolMigrationPreflight is
    Test,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    /// @dev The captured holder lists (bare `0x...` = holder; `# no-work: 0x...` = holder that needed no
    ///      reward-migration work but still holds a balance; other `#` lines = header). BOTH address forms count.
    string internal constant HOLDERS_DIR = "script/Migrate_StabilityPool_v2_Data_mainnet/";
    /// @dev The block the holder lists were captured to (their `# to-block`), so the sum is over the complete set.
    ///      At migration time, re-capture the lists to the migration block and set this to it.
    uint256 internal constant CAPTURE_BLOCK = 25272609;
    /// @dev A gap above this fraction of supply (parts-per-billion) is not rounding dust - the holder list is
    ///      stale/incomplete and must be re-captured. Legitimate gaps measure ~0 ppb; the incomplete-list artifact
    ///      measures ~9e8 ppb, so this cleanly separates them.
    uint256 internal constant MAX_REL_GAP_PPB = 1_000_000; // 0.1% of supply

    /// @dev Output path for a result set, stamped with the capture block. The two files answer different questions -
    ///      the gap classification, and which per-user snapshots move - for different consumers, so they stay separate.
    ///
    ///      The block is in the NAME so a run at a new block writes a new file instead of overwriting the old one: the
    ///      pre-migration and post-migration censuses are precisely the evidence that a migration step did its job
    ///      (e.g. V1-resident pairs going 45 -> 0 across the force-migrate), and one overwritten file cannot show both.
    ///      It is repeated in a `# to-block:` header INSIDE each file - matching the header the holder lists these are
    ///      derived from already carry - so a copied, renamed or pasted CSV is still self-describing.
    ///
    ///      This is provenance, NOT a cache: the expensive part (the archive reads) is already cached per block by
    ///      foundry's own fork cache, and the assertions are computed from those reads - so nothing here may be skipped
    ///      when a file already exists, or the run would go green without checking anything.
    function _csvPath(string memory name) internal view returns (string memory) {
        return string.concat("./results/", name, "-", vm.toString(CAPTURE_BLOCK), ".csv");
    }

    uint256 internal deployedCount;
    uint256 internal negativeGapCount; // pools that need a seed (Sum(balanceOf) > supply)
    uint256 internal emptyNonZeroCount; // no-holder pools with supply > 0 (holder list missed depositors)
    uint256 internal looseGapCount; // holder pools whose gap exceeds rounding level (holder list stale)
    uint256 internal overCeilingCount; // pools whose supply exceeds the ceiling v3 will enforce (need a MIN re-base)
    uint256 internal historicalTokenCount; // reward tokens ever unregistered, across all pools (expected: 0)
    uint256 internal claimDataPairsToCopy; // (holder, token) pairs whose V2 ClaimData must be copied to V3
    uint256 internal claimDataPairsAlreadyV3; // pairs already carrying V3 data (a re-run would skip them)
    uint256 internal claimDataPairsStillOnV1; // pairs whose live data is in the V1 mapping the upgrader does NOT read

    /// @dev The accumulator's ERC-7201 namespace, and the member offsets of the two per-user snapshot mappings within
    ///      it. V2 and V3 agree on the first four members, so `userRewardSnapshotV2` sits at offset 3 under both; V3
    ///      adds its widened mapping at offset 4. Read directly because the live V2 pool exposes no getter for the
    ///      checkpoint `integral` - and the integral is the field that MUST be copied (see `_censusClaimData`).
    bytes32 internal constant _ACCUMULATOR_STORAGE = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;
    uint256 internal constant _SNAPSHOT_V1_OFFSET = 2;
    uint256 internal constant _SNAPSHOT_V2_OFFSET = 3;
    uint256 internal constant _SNAPSHOT_V3_OFFSET = 4;

    /// @dev The supply ceiling StabilityPool_v3 derives from a pool's floor, mirroring the v3 constructor: the mirror
    ///      of the floor, saturated at the supply field width above which a larger ceiling is unreachable. Migration
    ///      does not go through the deposit path where v3 enforces this, so it is gated here instead: above the
    ///      ceiling a floor-capped liquidation rounds its loss-per-unit up to a total loss and zeroes the product
    ///      factor. A pool over it needs its floor re-based (a new implementation) before it can migrate.
    function _ceiling(uint256 minTotalAssetSupply) internal pure returns (uint256) {
        return
            minTotalAssetSupply > type(uint128).max / DecrementalFloatingPoint_v2.FACTOR_PRECISION
                ? type(uint128).max
                : minTotalAssetSupply * DecrementalFloatingPoint_v2.FACTOR_PRECISION;
    }

    uint256 internal constant _RESIDENT_NONE = 0;
    uint256 internal constant _RESIDENT_V2 = 1;
    uint256 internal constant _RESIDENT_V1 = 2;

    /// @dev First slot of `mapping(address => mapping(address => T))` held at member `offset` of the accumulator
    ///      namespace, for the `[holder][token]` entry.
    function _snapshotSlot(uint256 offset, address holder, address token) internal pure returns (uint256 slot) {
        bytes32 inner = keccak256(abi.encode(holder, uint256(_ACCUMULATOR_STORAGE) + offset));
        slot = uint256(keccak256(abi.encode(token, inner)));
    }

    /// @dev Census the per-(holder, token) reward snapshots the ClaimData migration must copy, and pin the invariant
    ///      that the copy's completeness rests on.
    ///
    ///      V3 relocated the per-user snapshot to a NEW mapping (`ClaimData` uint128/uint128 -> `ClaimDataV3`
    ///      uint256/uint256) and `_claimable`/`_checkpoint` read ONLY the new one - there is no lazy fallback to the V2
    ///      mapping. So every holder's snapshot must be copied by the upgrader. A holder the list misses loses their
    ///      unclaimed `pending` and, worse, checkpoints from `integral` 0 and is massively over-credited on the next
    ///      accrual.
    ///
    ///      This measures two things the gap classification above CANNOT see:
    ///      - HISTORICAL TOKENS. `_checkpoint` iterates active + historical tokens, so a holder can hold `pending` on
    ///        an unregistered token. The upgrader copies over `activeRewardTokens` only, which is the complete set
    ///        exactly while no token has ever been unregistered - asserted per pool here rather than assumed.
    ///      - REWARD-DATA COVERAGE. The gap check compares Sum(balanceOf) against supply, so it only proves the list
    ///        covers holders with a BALANCE. A holder who fully withdrew has balanceOf 0 - invisible to the gap check -
    ///        yet can still carry `claimed` history and unclaimed `pending` that must be copied.
    function _censusClaimData(
        address pool,
        string memory saltKey,
        address[] memory holders
    ) internal returns (uint256 pairsToCopy, uint256 historicalCount, uint256 v1Pairs) {
        // Census over active + historical: the two sets are disjoint (unregistering moves a token from one to the
        // other), so concatenating needs no de-duplication. Merged inside a scope so only the combined list stays live
        // through the loops below - this function is at the stack limit.
        address[] memory tokens;
        {
            address[] memory active = IMultipleRewardDistributor(pool).activeRewardTokens();
            address[] memory historical = IMultipleRewardDistributor(pool).historicalRewardTokens();
            historicalCount = historical.length;
            if (historicalCount > 0) {
                historicalTokenCount += historicalCount;
                console.log(
                    string.concat(
                        "HISTORICAL TOKENS: ",
                        saltKey,
                        " has ",
                        vm.toString(historicalCount),
                        " unregistered reward token(s) - the upgrader's active-only copy would miss holder pending"
                    )
                );
            }
            tokens = new address[](active.length + historicalCount);
            for (uint256 i = 0; i < tokens.length; i++) {
                tokens[i] = i < active.length ? active[i] : historical[i - active.length];
            }
        }

        for (uint256 t = 0; t < tokens.length; t++) {
            for (uint256 h = 0; h < holders.length; h++) {
                // Resolve which mapping holds this pair's LIVE snapshot, exactly as the deployed accumulator's
                // `_getUserRewardSnapshot` resolves it: the V2 entry wins when its `integral` or `timestamp` is set,
                // otherwise every read falls back to the V1 mapping. Live data therefore sits in EITHER mapping,
                // depending on whether the V1->V2 remediation ever reached that pair - which is the point of measuring
                // it here, because the V3 upgrader reads the V2 mapping ONLY.
                uint256 residency = _RESIDENT_NONE;
                uint256 rawClaimed;
                // Each candidate mapping is read in its own scope, so the slot local goes out of scope with the branch
                // that owns it (this function is at the stack limit) and each name still says which mapping it means.
                {
                    uint256 v2Base = _snapshotSlot(_SNAPSHOT_V2_OFFSET, holders[h], tokens[t]);
                    if (
                        uint256(vm.load(pool, bytes32(v2Base + 2))) != 0 || // integral
                        uint256(vm.load(pool, bytes32(v2Base + 1))) != 0 // timestamp
                    ) {
                        residency = _RESIDENT_V2;
                        rawClaimed = uint256(uint128(uint256(vm.load(pool, bytes32(v2Base))) >> 128));
                    }
                }
                if (residency == _RESIDENT_NONE) {
                    uint256 v1Base = _snapshotSlot(_SNAPSHOT_V1_OFFSET, holders[h], tokens[t]);
                    if (
                        uint256(vm.load(pool, bytes32(v1Base))) != 0 || // ClaimData: pending | claimed
                        uint256(vm.load(pool, bytes32(v1Base + 1))) != 0 // checkpoint: timestamp | integral
                    ) {
                        residency = _RESIDENT_V1;
                        rawClaimed = uint256(uint128(uint256(vm.load(pool, bytes32(v1Base))) >> 128));
                    }
                }
                // Anchor the raw slot arithmetic against the contract's own getter, so a wrong namespace or member
                // offset fails loudly here instead of silently reporting a census of zeros.
                assertEq(
                    rawClaimed,
                    IMultipleRewardAccumulator(pool).claimed(holders[h], tokens[t]),
                    string.concat("raw claimed disagrees with claimed() - snapshot slot math wrong: ", saltKey)
                );

                if (residency == _RESIDENT_V1) {
                    // The upgrader copies from the V2 mapping ONLY, so this pair would migrate as all-zero: pending and
                    // claimed lost, and - worse - a checkpoint integral of 0 that over-credits the next accrual.
                    v1Pairs++;
                    claimDataPairsStillOnV1++;
                    pairsToCopy++;
                } else if (residency == _RESIDENT_V2) {
                    pairsToCopy++;
                }

                {
                    uint256 v3Base = _snapshotSlot(_SNAPSHOT_V3_OFFSET, holders[h], tokens[t]);
                    if (
                        uint256(vm.load(pool, bytes32(v3Base))) != 0 || // pending
                        uint256(vm.load(pool, bytes32(v3Base + 1))) != 0 || // claimed
                        uint256(vm.load(pool, bytes32(v3Base + 2))) != 0 || // timestamp
                        uint256(vm.load(pool, bytes32(v3Base + 3))) != 0 // integral
                    ) {
                        claimDataPairsAlreadyV3++;
                    }
                }
            }
        }
        claimDataPairsToCopy += pairsToCopy;
        if (v1Pairs > 0) {
            console.log(
                string.concat(
                    "V1-RESIDENT: ",
                    saltKey,
                    " has ",
                    vm.toString(v1Pairs),
                    " (holder, token) pair(s) whose live snapshot is still in the V1 mapping - the upgrader's",
                    " V2-only copy would write zeros and over-credit them"
                )
            );
        }
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), CAPTURE_BLOCK);
        _setSaltPrefix("harbor_v1");
    }

    function test_migrationPreflight() public {
        // No `generated:` timestamp alongside the block: these files are regenerated often and tracked in git, so a
        // timestamp would produce a diff on every run even when the measurement is identical. The block is the
        // provenance that matters - the same data always comes back from the same block.
        string memory toBlock = string.concat("# to-block: ", vm.toString(CAPTURE_BLOCK), "\n");
        vm.writeFile(
            _csvPath("sp-pool-gaps"),
            string.concat(toBlock, "pool,action,totalSupply,sumBalanceOf,gap,relGapPpb\n")
        );
        vm.writeFile(
            _csvPath("sp-pool-claimdata"),
            string.concat(toBlock, "pool,holders,claimDataPairsToCopy,claimDataPairsStillOnV1,historicalTokens\n")
        );

        Config_MinterMarket[] memory markets;
        (, markets) = createBTCMintersConfig();
        _scan(markets);
        (, markets) = createETHMintersConfig();
        _scan(markets);
        (, markets) = createEURMintersConfig();
        _scan(markets);
        (, markets) = createGOLDMintersConfig();
        _scan(markets);
        (, markets) = createMCAPMintersConfig();
        _scan(markets);
        (, markets) = createSILVERMintersConfig();
        _scan(markets);

        console.log("Pre-flight: %d pools deployed, %d need a seed (negative gap)", deployedCount, negativeGapCount);

        assertGt(deployedCount, 0, "no pools scanned - fork / enumeration broken");
        assertEq(emptyNonZeroCount, 0, "a no-holder pool has totalSupply > 0 - holder list incomplete, re-capture");
        assertEq(looseGapCount, 0, "a pool's gap exceeds rounding level - holder list stale, re-capture");
        assertEq(negativeGapCount, 0, "a pool has a negative gap - seed it via the SeedUpgrader before plain upgrade");
        assertEq(
            overCeilingCount,
            0,
            "a pool's supply exceeds the v3 supply ceiling - re-base its floor before migrating"
        );

        console.log(
            "ClaimData census: %d (holder, token) pairs to copy, %d still on V1, %d already on V3",
            claimDataPairsToCopy,
            claimDataPairsStillOnV1,
            claimDataPairsAlreadyV3
        );

        // The upgrader copies each holder's snapshot over `activeRewardTokens` only. That set is complete exactly while
        // no reward token has ever been unregistered; if one ever is, holders can hold `pending` on it and the copy
        // must widen to active + historical before this migration can run.
        assertEq(
            historicalTokenCount,
            0,
            "a pool has unregistered reward tokens - the upgrader's active-only ClaimData copy would miss them"
        );
        // Pre-migration every pool is still on V2, so nothing may be sitting in the V3 mapping. A non-zero count means
        // either a pool was already migrated (this run is stale) or the snapshot slot arithmetic is wrong.
        assertEq(
            claimDataPairsAlreadyV3,
            0,
            "a (holder, token) pair already carries V3 snapshot data - pool already migrated, or slot math wrong"
        );
        // The whole point of the ClaimData copy: if there were nothing to copy, the upgrader's holder loop would be
        // dead code and this pre-flight would be silently vacuous.
        assertGt(claimDataPairsToCopy, 0, "no ClaimData pairs to copy - holder lists empty or census not reading");
        // The deployed V2 accumulator resolves a snapshot with a lazy fallback - the V2 entry wins only when its
        // integral or timestamp is set, otherwise the read comes from the V1 mapping - so a pair the V1->V2 remediation
        // never reached still lives in V1. The V3 upgrader copies from V2 ONLY and V3 has NO fallback, so such a pair
        // migrates as all-zero: its pending and claimed are lost and its zero checkpoint integral over-credits the next
        // accrual. Either finish the V1->V2 remediation for these pairs, or widen the upgrader's copy to resolve V1
        // exactly as `_getUserRewardSnapshot` does.
        assertEq(
            claimDataPairsStillOnV1,
            0,
            "a (holder, token) pair's live snapshot is still in the V1 mapping - the upgrader's V2-only copy would zero it"
        );
    }

    function _scan(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            _measure(stabilityPoolKey(markets[i], StabilityPoolType.Collateral));
            _measure(stabilityPoolKey(markets[i], StabilityPoolType.Leveraged));
        }
    }

    function _measure(string memory saltKey) internal {
        address pool = _predictAddress(saltKey);
        if (pool.code.length == 0) {
            return; // not deployed - nothing to migrate
        }
        deployedCount++;

        uint256 totalSupply = IStabilityPool(pool).totalAssetSupply();

        // Gate on the v3 supply ceiling. Orthogonal to the gap classification below: a pool over the ceiling cannot
        // migrate at all, whatever its gap says. Scoped so the ceiling does not stay live across the rest of the
        // measurement, which is already at the stack limit.
        {
            uint256 ceiling = _ceiling(IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY());
            if (totalSupply > ceiling) {
                overCeilingCount++;
                console.log(
                    string.concat(
                        "REBASE REQUIRED: ",
                        saltKey,
                        " supply ",
                        vm.toString(totalSupply),
                        " exceeds the v3 supply ceiling ",
                        vm.toString(ceiling)
                    )
                );
            }
        }

        address[] memory holders = _readHolders(saltKey);

        // Census the per-user reward snapshots the ClaimData copy must carry, and pin the no-historical-tokens
        // invariant the upgrader's active-only token loop relies on. Scoped so neither result stays live across the
        // gap measurement below, which is already at the stack limit.
        {
            (uint256 pairs, uint256 historical, uint256 v1Pairs) = _censusClaimData(pool, saltKey, holders);
            vm.writeLine(
                _csvPath("sp-pool-claimdata"),
                string.concat(
                    saltKey,
                    ",",
                    vm.toString(holders.length),
                    ",",
                    vm.toString(pairs),
                    ",",
                    vm.toString(v1Pairs),
                    ",",
                    vm.toString(historical)
                )
            );
        }

        uint256 sumBalance = 0;
        for (uint256 h = 0; h < holders.length; h++) {
            sumBalance += IStabilityPool(pool).assetBalanceOf(holders[h]);
        }
        int256 gap = int256(totalSupply) - int256(sumBalance);
        uint256 relGapPpb = totalSupply == 0 ? 0 : (_abs(gap) * 1e9) / totalSupply; // |gap| as parts-per-billion of supply

        // Classify the pool for the migration and flag any condition that blocks an all-pools plain upgrade.
        string memory action;
        if (holders.length == 0) {
            // No captured holders: the pool must be empty. A non-zero supply means depositors were missed.
            action = "empty";
            if (totalSupply != 0) {
                emptyNonZeroCount++;
                console.log(string.concat("INCOMPLETE: ", saltKey, " has no captured holders but totalSupply > 0"));
            }
        } else if (gap < 0) {
            // Sum(balanceOf) > supply: a plain upgrade (divisor = supply) would over-credit. Seed this pool.
            // Classified ahead of the stale-list check at any magnitude: a missing holder only shrinks the sum, so
            // it can never drive the gap negative - a negative gap is always a seed case, never a stale list.
            action = "seed";
            negativeGapCount++;
            console.log(string.concat("SEED REQUIRED: ", saltKey, " has a negative gap"));
        } else if (relGapPpb >= MAX_REL_GAP_PPB) {
            // The captured holders do not account for the supply: the list is stale, re-capture before migrating.
            action = "recapture";
            looseGapCount++;
            console.log(string.concat("INCOMPLETE: ", saltKey, " gap exceeds rounding level - holder list stale"));
        } else {
            action = "plain";
        }

        console.log(
            string.concat(
                saltKey,
                " action=",
                action,
                " totalSupply=",
                vm.toString(totalSupply),
                " gap=",
                vm.toString(gap)
            )
        );
        vm.writeLine(
            _csvPath("sp-pool-gaps"),
            string.concat(
                saltKey,
                ",",
                action,
                ",",
                vm.toString(totalSupply),
                ",",
                vm.toString(sumBalance),
                ",",
                vm.toString(gap),
                ",",
                vm.toString(relGapPpb)
            )
        );
    }

    function _abs(int256 x) internal pure returns (uint256 absolute) {
        absolute = x < 0 ? uint256(-x) : uint256(x);
    }

    // Holder-file reader for the FILTERED capture format: bare `0x...` lines are holders that needed
    // reward-migration work; `# no-work: 0x...` lines are holders that needed none but still hold a balance. BOTH
    // are real holders and must be summed - reading only the bare lines undercounts Sum(balanceOf) massively (the
    // no-work holders are usually the majority). Other `#` header lines (proxy, source, ...) are skipped.
    function _readHolders(string memory saltKey) internal returns (address[] memory holders) {
        string memory path = string.concat(HOLDERS_DIR, saltKey, ".txt");
        if (!vm.isFile(path)) {
            return new address[](0);
        }
        uint256 count = 0;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (_isHolderLine(line)) {
                count++;
            }
        }
        vm.closeFile(path);

        holders = new address[](count);
        uint256 idx = 0;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (_isHolderLine(line)) {
                holders[idx] = _holderAddress(line);
                idx++;
            }
        }
        vm.closeFile(path);
    }

    /// @dev A holder line is a bare `0x...` address, or a `# no-work: 0x...` filtered entry. Header `#` lines
    ///      (e.g. `# proxy: 0x...`) are not holders and return false.
    function _isHolderLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length == 0) {
            return false;
        }
        if (b[0] != 0x23) {
            return true; // bare address line
        }
        return _hasPrefix(b, "# no-work: ");
    }

    /// @dev The holder address is the trailing `0x`+40-hex (42 chars): a bare line IS it, a `# no-work: ` line
    ///      suffixes it. Taking the last 42 chars is robust to the comment prefix length.
    function _holderAddress(string memory line) internal pure returns (address) {
        bytes memory b = bytes(line);
        bytes memory a = new bytes(42);
        uint256 start = b.length - 42;
        for (uint256 i = 0; i < 42; i++) {
            a[i] = b[start + i];
        }
        return vm.parseAddress(string(a));
    }

    function _hasPrefix(bytes memory b, string memory prefixStr) internal pure returns (bool) {
        bytes memory p = bytes(prefixStr);
        if (b.length < p.length) {
            return false;
        }
        for (uint256 i = 0; i < p.length; i++) {
            if (b[i] != p[i]) {
                return false;
            }
        }
        return true;
    }
}
