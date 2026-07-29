// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {ForceMigrateAccumulator_v1} from "@harbor-script/Migrate_StabilityPool_v2_Data_mainnet/ForceMigrateAccumulator_v1.sol";

import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

/// @title MigrateBalancesTest — Prong B of the force-migrate verification
/// @notice White-box storage check, complementing the black-box before/after diff (Prong A).
/// For every pool, upgrades the proxy to ForceMigrateAccumulator_v1, reads each holder/token's
/// raw (V1, V2) integral via balances(), runs remediate(), and asserts the copy is correct:
///   - the old (V1) slot is never modified;
///   - an unmigrated holder (V1 set, V2 empty) ends with V2 integral == V1 integral;
///   - an already-migrated holder is left untouched;
///   - a holder with no V1 data stays zero.
/// This directly verifies the storage copy that Prong A only observes through claimable/claimed.
///
/// Pools/holders/tokens are derived exactly as Migrate_StabilityPool_v2_Data_mainnet derives
/// them (same salt keys, same holders/*.txt, active+historical reward tokens).
///
/// Run: forge test --mc MigrateBalancesTest --fork-url local -vv   (against a mainnet fork)
contract MigrateBalancesTest is
    Test,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    string internal constant HOLDERS_DIR = "tmp/sp-holders/";

    /// @dev ERC-1967 implementation slot — used to read/assert the proxy's current impl.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal migImpl;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("local"));
        _setSaltPrefix("harbor_v1");
        migImpl = address(new ForceMigrateAccumulator_v1());
    }

    /// @notice Migrate every pool and assert the V1->V2 copy is correct for all holders/tokens.
    function test_allPoolsMigrateCorrectly() public {
        Config_MinterMarket[] memory markets;
        uint256 checked = 0;

        (, markets) = createBTCMintersConfig();
        checked += _checkMarkets(markets);
        (, markets) = createETHMintersConfig();
        checked += _checkMarkets(markets);
        (, markets) = createEURMintersConfig();
        checked += _checkMarkets(markets);
        (, markets) = createGOLDMintersConfig();
        checked += _checkMarkets(markets);
        (, markets) = createMCAPMintersConfig();
        checked += _checkMarkets(markets);
        (, markets) = createSILVERMintersConfig();
        checked += _checkMarkets(markets);

        console.log("Checked %d pools with holders", checked);
    }

    function _checkMarkets(Config_MinterMarket[] memory markets) internal returns (uint256 checked) {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = MinterMarketConfigLib.salt(markets[i]);
            if (_checkPool(marketKey, StabilityPoolType.Collateral)) {
                checked++;
            }
            if (_checkPool(marketKey, StabilityPoolType.Leveraged)) {
                checked++;
            }
        }
    }

    function logV1(ForceMigrateAccumulator_v1.UserRewardSnapshot memory v1) private pure {
        console.log("        v1.timestamp: %s", v1.checkpoint.timestamp);
        console.log("        v1.integral:  %s", v1.checkpoint.integral);
        console.log("        v1.pending: %s", v1.rewards.pending);
        console.log("        v1.claimed: %s", v1.rewards.claimed);
    }

    function logV2(ForceMigrateAccumulator_v1.UserRewardSnapshotV2 memory v2) private pure {
        console.log("        v2.timestamp: %s", v2.timestamp);
        console.log("        v2.integral:  %s", v2.integral);
        console.log("        v2.pending: %s", v2.rewards.pending);
        console.log("        v2.claimed: %s", v2.rewards.claimed);
    }

    function _checkPool(string memory marketKey, StabilityPoolType poolType) internal returns (bool) {
        string memory saltKey = stabilityPoolKey(marketKey, poolType);
        address pool = stabilityPoolAddress(marketKey, poolType);
        address[] memory holders = _readHolders(saltKey);
        if (holders.length == 0) {
            return false;
        }

        // Reward tokens (active + historical) read before upgrade — the pauser reverts other calls.
        address[] memory tokens = _concat(
            IMultipleRewardDistributor(pool).activeRewardTokens(),
            IMultipleRewardDistributor(pool).historicalRewardTokens()
        );
        address owner = IBaoOwnable(pool).owner();

        // The original (StabilityPool_v2) implementation — the restore target the production
        // batch bakes into remediate's calldata.
        address currentImpl = address(uint160(uint256(vm.load(pool, IMPL_SLOT))));

        // 1. Upgrade to the migration contract to READ the pre-migration (V1, V2) integrals.
        vm.prank(owner);
        UUPSUpgradeable(pool).upgradeToAndCall(migImpl, "");
        ForceMigrateAccumulator_v1 mig = ForceMigrateAccumulator_v1(pool);

        // 2. Snapshot raw (V1, V2) integrals before remediation.
        console.log("scanning pre state...");
        uint256[][] memory preOld = new uint256[][](holders.length);
        uint256[][] memory preNew = new uint256[][](holders.length);
        for (uint256 h = 0; h < holders.length; h++) {
            preOld[h] = new uint256[](tokens.length);
            preNew[h] = new uint256[](tokens.length);
            for (uint256 t = 0; t < tokens.length; t++) {
                string memory label = string.concat(
                    saltKey,
                    " holder ",
                    vm.toString(holders[h]),
                    " token ",
                    vm.toString(t)
                );
                console.log("     ", label);

                (preOld[h][t], preNew[h][t]) = mig.balances(holders[h], tokens[t]);

                (
                    ForceMigrateAccumulator_v1.UserRewardSnapshot memory v1,
                    ForceMigrateAccumulator_v1.UserRewardSnapshotV2 memory v2
                ) = mig.snapshots(holders[h], tokens[t]);
                logV1(v1);
                logV2(v2);
            }
        }
        console.log("done scanning pre state");

        // 3. Restore the original impl so the production call runs from the real starting state.
        vm.prank(owner);
        UUPSUpgradeable(pool).upgradeToAndCall(currentImpl, "");

        // 4. Run the EXACT production batch transaction: one atomic
        //    upgradeToAndCall(migImpl, remediate(tokens, holders, currentImpl)) that
        //    upgrades, remediates, and self-restores to the original implementation.
        vm.prank(owner);
        UUPSUpgradeable(pool).upgradeToAndCall(
            migImpl,
            abi.encodeCall(ForceMigrateAccumulator_v1.remediate, (tokens, holders, currentImpl))
        );
        console.log("done remediating (production calldata).");

        // 5. The proxy is restored to its original implementation and is functional again
        //    (a v2-only call the pauser would have reverted now succeeds).
        assertEq(
            address(uint160(uint256(vm.load(pool, IMPL_SLOT)))),
            currentImpl,
            string.concat("impl not restored: ", saltKey)
        );
        IMultipleRewardDistributor(pool).activeRewardTokens();

        // 6. Re-upgrade to the migration contract to READ the post-migration state
        //    (the production call restored away from it).
        vm.prank(owner);
        UUPSUpgradeable(pool).upgradeToAndCall(migImpl, "");

        console.log("scanning post state...");
        // 4. Assert the copy is correct for every holder/token.
        for (uint256 h = 0; h < holders.length; h++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                (uint256 postOld, uint256 postNew) = mig.balances(holders[h], tokens[t]);
                string memory label = string.concat(
                    saltKey,
                    " holder ",
                    vm.toString(holders[h]),
                    " token ",
                    vm.toString(t)
                );

                // The old (V1) slot is never modified.
                assertEq(postOld, preOld[h][t], string.concat("old changed: ", label));

                if (preNew[h][t] != 0) {
                    console.log("      ", label, " already migrated");
                    // Already migrated: V2 unchanged.
                    assertEq(postNew, preNew[h][t], string.concat("already-migrated changed: ", label));
                } else if (preOld[h][t] != 0) {
                    console.log("      ", label, " now migrated");
                    // Was unmigrated: V2 now equals V1 (pure copy).
                    assertEq(postNew, preOld[h][t], string.concat("not copied: ", label));
                } else {
                    console.log("      ", label, " no v1 data to migrate");
                    // No V1 data: stays zero.
                    assertEq(postNew, 0, string.concat("spurious V2: ", label));
                }
                (
                    ForceMigrateAccumulator_v1.UserRewardSnapshot memory v1,
                    ForceMigrateAccumulator_v1.UserRewardSnapshotV2 memory v2
                ) = mig.snapshots(holders[h], tokens[t]);
                logV1(v1);
                logV2(v2);
            }
        }
        console.log("done scanning post state.");

        console.log("    > %s: %d holders OK", saltKey, holders.length);
        return true;
    }

    // ── Holder file reading (same format as capture-sp-holders output) ────────

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
            if (_isAddressLine(line)) {
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
            if (_isAddressLine(line)) {
                holders[idx] = vm.parseAddress(line);
                idx++;
            }
        }
        vm.closeFile(path);
    }

    function _isAddressLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length == 0) {
            return false;
        }
        if (b[0] == 0x23) {
            return false;
        }
        return true;
    }

    function _concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }
}
