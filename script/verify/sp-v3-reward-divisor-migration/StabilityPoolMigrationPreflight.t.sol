// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
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
    string internal constant CSV = "./results/sp-pool-gaps.csv";
    /// @dev The block the holder lists were captured to (their `# to-block`), so the sum is over the complete set.
    ///      At migration time, re-capture the lists to the migration block and set this to it.
    uint256 internal constant CAPTURE_BLOCK = 25272609;
    /// @dev A gap above this fraction of supply (parts-per-billion) is not rounding dust - the holder list is
    ///      stale/incomplete and must be re-captured. Legitimate gaps measure ~0 ppb; the incomplete-list artifact
    ///      measures ~9e8 ppb, so this cleanly separates them.
    uint256 internal constant MAX_REL_GAP_PPB = 1_000_000; // 0.1% of supply

    uint256 internal deployedCount;
    uint256 internal negativeGapCount; // pools that need a seed (Sum(balanceOf) > supply)
    uint256 internal emptyNonZeroCount; // no-holder pools with supply > 0 (holder list missed depositors)
    uint256 internal looseGapCount; // holder pools whose gap exceeds rounding level (holder list stale)
    uint256 internal overCeilingCount; // pools whose supply exceeds the ceiling v3 will enforce (need a MIN re-base)
    uint256 internal historicalTokenCount; // reward tokens ever unregistered, across all pools (expected: 0)
    uint256 internal claimDataPairsToCopy; // (holder, token) pairs whose V2 ClaimData must be copied to V3
    uint256 internal claimDataPairsAlreadyV3; // pairs already carrying V3 data (a re-run would skip them)

    /// @dev The accumulator's ERC-7201 namespace, and the member offsets of the two per-user snapshot mappings within
    ///      it. V2 and V3 agree on the first four members, so `userRewardSnapshotV2` sits at offset 3 under both; V3
    ///      adds its widened mapping at offset 4. Read directly because the live V2 pool exposes no getter for the
    ///      checkpoint `integral` - and the integral is the field that MUST be copied (see `_censusClaimData`).
    bytes32 internal constant _ACCUMULATOR_STORAGE = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;
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

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), CAPTURE_BLOCK);
        _setSaltPrefix("harbor_v1");
    }

    function test_migrationPreflight() public {
        vm.writeFile(CSV, "pool,action,totalSupply,sumBalanceOf,gap,relGapPpb\n");

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
        } else if (relGapPpb >= MAX_REL_GAP_PPB) {
            // The captured holders do not account for the supply: the list is stale, re-capture before migrating.
            action = "recapture";
            looseGapCount++;
            console.log(string.concat("INCOMPLETE: ", saltKey, " gap exceeds rounding level - holder list stale"));
        } else if (gap < 0) {
            // Sum(balanceOf) > supply: a plain upgrade (divisor = supply) would over-credit. Seed this pool.
            action = "seed";
            negativeGapCount++;
            console.log(string.concat("SEED REQUIRED: ", saltKey, " has a negative gap"));
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
            CSV,
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
