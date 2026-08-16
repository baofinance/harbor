// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {ForceMigrateAccumulator_v1} from "@harbor-script/Migrate_StabilityPool_v2_Data_mainnet/ForceMigrateAccumulator_v1.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

import {Script} from "forge-std/Script.sol";

/// @notice Force-migrate accumulator storage from the legacy V1 (uint192 integral)
/// format to the V2 (uint256 integral) format for all stability pools, then restore
/// each pool to its current StabilityPool_v2 implementation.
///
/// This is the "prep for v3" step: once every remaining user is in V2 format, the
/// V1 read-fallback in the accumulator is dead code and a later StabilityPool_v3
/// upgrade can remove it safely. The proxy ends on v2 here — no v3 upgrade.
///
/// Per pool, the Safe batch contains 3 atomic transactions:
///   1. Upgrade proxy        -> ForceMigrateAccumulator_v1 (pauses the pool)
///   2. remediate(tokens, holders) -> pure copy of V1 snapshot data into V2
///   3. Restore proxy        -> the StabilityPool_v2 implementation it had before
///
/// Holders are read at runtime from per-pool files produced by
/// `script/Migrate_StabilityPool_v2_Data_mainnet/capture-sp-holders` (UserDepositChange
/// logs) and filtered by `FilterSpHolders.s.sol`. Pools with no holder file, or an empty one, are skipped.
///
/// Run via:
///   script/run-script Migrate_StabilityPool_v2_Data_mainnet --salt harbor_v1 --network mainnet --broadcast --local
contract Migrate_StabilityPool_v2_Data_mainnet is
    Script,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    using LibString for address;
    using LibString for string;

    /// @dev ERC1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Directory of per-pool holder files (one checksummed address per line, '#' comments).
    string internal constant HOLDERS_DIR = "script/Migrate_StabilityPool_v2_Data_mainnet/";

    /// @dev Deployed once, shared across all pools (no constructor params, deterministic bytecode).
    address internal migImpl;

    function _doOneMinter(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            _migratePool(markets[i], StabilityPoolType.Collateral);
            _migratePool(markets[i], StabilityPoolType.Leveraged);
        }
    }

    function _migratePool(Config_MinterMarket market, StabilityPoolType poolType) internal {
        // POOL_INCLUDE: optional env-var filter on market key segment.
        // ::VALUE:: wrapping ensures "ETH" matches "::ETH::" but not "::stETH::".
        string memory include = vm.envOr("POOL_INCLUDE", string(""));
        if (bytes(include).length > 0) {
            string memory marketKey = MinterMarketConfigLib.salt(market);
            if (!string.concat("::", marketKey, "::").contains(string.concat("::", include, "::"))) {
                return;
            }
        }

        string memory key = stabilityPoolKey(market, poolType);
        address pool = stabilityPoolAddress(market, poolType);

        // Read current implementation (restored after remediation).
        address currentImpl = address(uint160(uint256(vm.load(pool, IMPL_SLOT))));
        require(currentImpl.code.length != 0, string.concat("no impl for ", _saltString(key)));

        // Read reward tokens before the upgrade (the pauser fallback reverts all other calls).
        // Include BOTH active and historical: _checkpoint snapshots both, so a user can carry V1
        // data for a no-longer-active token. remediate() skips tokens with no V1 data, so passing
        // historical tokens is harmless and makes the migration complete (safe to remove the
        // fallback in a later v3 upgrade).
        address[] memory tokens = _concat(
            IMultipleRewardDistributor(pool).activeRewardTokens(),
            IMultipleRewardDistributor(pool).historicalRewardTokens()
        );

        // Holders for this pool, from the generated file.
        address[] memory holders = _readHolders(market, poolType);

        if (holders.length == 0) {
            console.log("    > %s: no holders, skipping", _saltString(key));
            return;
        }

        console.log("    > %s: %d holders, %d tokens", _saltString(key), holders.length, tokens.length);

        // 1. Upgrade to the migration contract.
        // 2. Remediate: copy V1 -> V2 for every holder/token pair -v=======v
        // 3. Restore the original (StabilityPool_v2) implementation-----------------------------v=========v
        queue(
            pool,
            abi.encodeCall(
                UUPSUpgradeable.upgradeToAndCall,
                (migImpl, abi.encodeCall(ForceMigrateAccumulator_v1.remediate, (tokens, holders, currentImpl)))
            ),
            "upgrade to ForceMigrateAccumulator_v1"
        );

        // // 2. Remediate: copy V1 -> V2 for every holder/token pair.
        // queue(
        //     pool,
        //     abi.encodeCall(ForceMigrateAccumulator_v1.remediate, (tokens, holders, currentImpl)),
        //     string.concat("remediate ", _saltString(key))
        // );

        // 3. Restore the original (StabilityPool_v2) implementation.
        // queue(
        //     pool,
        //     abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (currentImpl, "")),
        //     string.concat("restore to ", currentImpl.toHexString())
        // );
    }

    /// @dev Read a pool's holder list from HOLDERS_DIR/<the pool's salt key>.txt.
    /// Lines starting with '#' are comments; every other non-empty line is an address.
    /// Returns an empty array when the file is absent (pool skipped by the caller).
    function _readHolders(
        Config_MinterMarket market,
        StabilityPoolType poolType
    ) internal returns (address[] memory holders) {
        string memory path = string.concat(HOLDERS_DIR, stabilityPoolKey(market, poolType), ".txt");
        if (!vm.isFile(path)) {
            return new address[](0);
        }

        // First pass: count address lines.
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

        // Second pass: parse them.
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

    /// @dev True for a non-comment, non-empty line (an address). '#' (0x23) marks a comment.
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

    /// @dev Concatenate two address arrays.
    function _concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }

    function build() internal override {
        Config_MinterMarket[] memory markets;

        vm.startBroadcast();
        migImpl = address(new ForceMigrateAccumulator_v1());
        console.log("  Migration impl: %s", migImpl);
        vm.stopBroadcast();

        (, markets) = createBTCMintersConfig();
        _doOneMinter(markets);

        (, markets) = createETHMintersConfig();
        _doOneMinter(markets);

        (, markets) = createEURMintersConfig();
        _doOneMinter(markets);

        (, markets) = createGOLDMintersConfig();
        _doOneMinter(markets);

        (, markets) = createMCAPMintersConfig();
        _doOneMinter(markets);

        (, markets) = createSILVERMintersConfig();
        _doOneMinter(markets);
    }
}
