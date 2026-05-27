// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {ForceMigrateAccumulator_v1} from "@harbor-script/verify/sp-v3-migration/ForceMigrateAccumulator_v1.sol";

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
    string internal constant HOLDERS_DIR = "script/verify/sp-v2-upgrade-prep-for-v3/holders/";

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
            if (_checkPool(marketKey, "stabilityPoolCollateral")) {
                checked++;
            }
            if (_checkPool(marketKey, "stabilityPoolLeveraged")) {
                checked++;
            }
        }
    }

    function _checkPool(string memory marketKey, string memory spType) internal returns (bool) {
        string memory saltKey = string.concat(marketKey, "::", spType);
        address pool = _predictAddress(_key(marketKey, spType));
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

        // 1. Upgrade to the migration contract.
        vm.prank(owner);
        UUPSUpgradeable(pool).upgradeToAndCall(migImpl, "");
        ForceMigrateAccumulator_v1 mig = ForceMigrateAccumulator_v1(pool);

        // 2. Snapshot raw (V1, V2) integrals before remediation.
        uint256[][] memory preOld = new uint256[][](holders.length);
        uint256[][] memory preNew = new uint256[][](holders.length);
        for (uint256 h = 0; h < holders.length; h++) {
            preOld[h] = new uint256[](tokens.length);
            preNew[h] = new uint256[](tokens.length);
            for (uint256 t = 0; t < tokens.length; t++) {
                (preOld[h][t], preNew[h][t]) = mig.balances(holders[h], tokens[t]);
            }
        }

        // 3. Remediate.
        vm.prank(owner);
        mig.remediate(tokens, holders);

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
                    // Already migrated: V2 unchanged.
                    assertEq(postNew, preNew[h][t], string.concat("already-migrated changed: ", label));
                } else if (preOld[h][t] != 0) {
                    // Was unmigrated: V2 now equals V1 (pure copy).
                    assertEq(postNew, preOld[h][t], string.concat("not copied: ", label));
                } else {
                    // No V1 data: stays zero.
                    assertEq(postNew, 0, string.concat("spurious V2: ", label));
                }
            }
        }

        console.log("    > %s: %d holders OK", saltKey, holders.length);
        return true;
    }

    // ── Holder file reading (same format as collect-sp-holders output) ────────

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
