// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";

/// @title ForceMigrateAccumulator_v1
/// @notice One-shot upgrade that copies user reward snapshot data from
/// the legacy V1 format (uint192 integral, 2 slots) to the V2 format
/// (uint256 integral, 3 slots).
///
/// Inherits HarborPauser_v1: all calls except `remediate` and `balances`
/// revert with Paused. Owner read from proxy storage. UUPS upgrade
/// authorization via HarborFixedOwnable.
///
/// Lifecycle:
///   1. Upgrade proxy to this contract
///   2. Call `remediate(tokens, holders)` to copy V1 → V2 for each holder/token pair
///   3. Upgrade proxy to StabilityPool_v3
///
/// @custom:oz-upgrades
/// @custom:oz-upgrades-from src/minter/StabilityPool_v2.sol:StabilityPool_v2
// solhint-disable-next-line contract-name-capwords
contract ForceMigrateAccumulator_v1 is HarborPauser_v1 {
    // ── Storage layout (mirrors Accumulator_v2) ─────────────────────────────

    struct RewardSnapshot {
        uint64 timestamp;
        uint192 integral;
    }

    struct ClaimData {
        uint128 pending;
        uint128 claimed;
    }

    /// @dev V1: 2 slots per entry.
    struct UserRewardSnapshot {
        ClaimData rewards;
        RewardSnapshot checkpoint;
    }

    /// @dev V2: 3 slots per entry.
    struct UserRewardSnapshotV2 {
        ClaimData rewards;
        uint64 timestamp;
        uint256 integral;
    }

    struct AccumulatorStorage {
        // these are not used but are needed as placeholders
        mapping(address => address) rewardReceiver;
        mapping(address => mapping(uint8 => uint256)) tokenToExponentToIntegral;
        // user -> token -> reward snapshot
        mapping(address => mapping(address => UserRewardSnapshot)) userRewardSnapshot;
        mapping(address => mapping(address => UserRewardSnapshotV2)) userRewardSnapshotV2;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.MultipleRewardCompoundingAccumulator")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _ACCUMULATOR_STORAGE = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

    function _getAccumulatorStorage() private pure returns (AccumulatorStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _ACCUMULATOR_STORAGE
        }
    }

    // ── Events ──────────────────────────────────────────────────────────────

    event AccountAlreadyMigrated(address indexed account, address indexed token);
    event AccountNoDataToMigrate(address indexed account, address indexed token);
    event AccountMigrated(
        address indexed account,
        address indexed token,
        uint256 pending,
        uint256 claimed,
        uint256 timestamp,
        uint256 integral
    );

    event MigrationComplete(uint256 holderCount, uint256 tokenCount);

    // ── View ─────────────────────────────────────────────────────────────────

    /// @notice Returns the raw V1 and V2 integral values for an account and reward token.
    /// @dev Always reads both slots. After remediation, both will be populated with the same value.
    function balances(address account, address token) external view returns (uint256 oldIntegral, uint256 newIntegral) {
        AccumulatorStorage storage $ = _getAccumulatorStorage();
        oldIntegral = uint256($.userRewardSnapshot[account][token].checkpoint.integral);
        newIntegral = $.userRewardSnapshotV2[account][token].integral;
    }

    function snapshots(
        address account,
        address token
    ) external view returns (UserRewardSnapshot memory v1, UserRewardSnapshotV2 memory v2) {
        AccumulatorStorage storage $ = _getAccumulatorStorage();
        v1 = $.userRewardSnapshot[account][token];
        v2 = $.userRewardSnapshotV2[account][token];
    }

    // ── Remediation ─────────────────────────────────────────────────────────

    /// @notice Copy V1 snapshot data to V2 format for each holder/token pair.
    /// @dev Pure data copy — no recalculation. Idempotent: already-migrated users are skipped.
    /// @param tokens The reward token addresses to migrate.
    /// @param holders The holder addresses to migrate.
    function remediate(address[] calldata tokens, address[] calldata holders, address upgradeTo) external onlyOwner {
        AccumulatorStorage storage $ = _getAccumulatorStorage();

        for (uint256 i = 0; i < holders.length; i++) {
            address account = holders[i];

            for (uint256 j = 0; j < tokens.length; j++) {
                address token = tokens[j];

                // Skip if already migrated: any non-zero value in v2
                UserRewardSnapshotV2 storage v2 = $.userRewardSnapshotV2[account][token];
                if (v2.integral != 0 || v2.timestamp != 0 || v2.rewards.pending != 0 || v2.rewards.claimed != 0) {
                    emit AccountAlreadyMigrated(account, token);
                    continue;
                }

                // Skip if no V1 data: all zero in v1
                UserRewardSnapshot storage v1 = $.userRewardSnapshot[account][token];
                if (
                    v1.checkpoint.integral == 0 &&
                    v1.checkpoint.timestamp == 0 &&
                    v1.rewards.pending == 0 &&
                    v1.rewards.claimed == 0
                ) {
                    emit AccountNoDataToMigrate(account, token);
                }

                // only get here if there is non-zero data in v1 and all zero data in v2
                // So, copy V1 → V2
                v2.rewards.pending = v1.rewards.pending;
                v2.rewards.claimed = v1.rewards.claimed;
                v2.timestamp = v1.checkpoint.timestamp;
                v2.integral = uint256(v1.checkpoint.integral);

                emit AccountMigrated(account, token, v2.rewards.pending, v2.rewards.claimed, v2.timestamp, v2.integral);
            }
        }

        emit MigrationComplete(holders.length, tokens.length);

        // finally upgrade to the new address, if non-zero which is just used for tests
        if (upgradeTo != address(0)) {
            upgradeToAndCall(upgradeTo, "");
        }
    }
}
