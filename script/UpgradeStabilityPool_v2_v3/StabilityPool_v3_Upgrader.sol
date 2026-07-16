// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {HarborFixedOwnable} from "@bao/HarborFixedOwnable.sol";

import {LinearReward} from "@harbor/reward/distributor/LinearReward.sol";
import {LinearReward_v2} from "@harbor/reward/distributor/LinearReward_v2.sol";
import {LinearMultipleRewardDistributor_v3} from "@harbor/reward/distributor/LinearMultipleRewardDistributor_v3.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

/// @title StabilityPool_v3_Upgrader
/// @notice One-shot throwaway implementation for the StabilityPool_v2 -> StabilityPool_v3 upgrade, run atomically as a
///         TEMPORARY proxy implementation. `migrateAndUpgrade`, in one transaction:
///           1. widen-copies each active token's reward stream from the legacy `rewardDataUNUSED` (v1 layout) into the
///              widened `rewardData` - the v3 reward-field widen relocated it to a fresh slot, so a plain upgrade would
///              read the empty widened mapping and drop every mid-period reward. Historical tokens are skipped:
///              unregistering a token requires a fully-distributed stream, so their data reads identically from the
///              empty widened mapping;
///           2. writes the reward-divisor gap (`rewardDivisor = totalAssetSupply.amount - rewardDivisorGap`, the
///              denominator reward accrual divides by, which must track Sum(balanceOf)). The value is the exact
///              `supply - Sum(balanceOf)` computed off-chain from the complete frozen holder list under realistic
///              bounds - `0` when supply already equals the summed balances;
///           3. upgrades the proxy to the real StabilityPool_v3.
///         Both steps run in one call because the gap does NOT self-heal - normal operation only rescales it on losses,
///         never re-derives it from balances - so it must be correct before any reward accrues; a separate later run
///         would leave the pool on v3 with an un-seeded divisor in between. It leaves no migration code on the
///         functional contract.
/// @dev Owner-gated and single-shot by construction: it upgrades away from itself in the same transaction, so
///      `migrateAndUpgrade` can never run twice - no re-run guard is needed. Storage safety: it reaches each namespace
///      it touches (the pool's and the linear distributor's) through that contract's own canonical struct type
///      (compiler-enforced, cannot drift) at the namespace's ERC-7201 slot - which storage-successor auto-verifies each
///      slot constant against its canonical hash. The bao-upgrades-from below makes storage-successor byte-compare
///      those reached (v3) structs against StabilityPool_v2's same namespaces - a PARTIAL successor check: the
///      namespaces it does not touch are left to `StabilityPool_v3 <- StabilityPool_v2`. So this upgrader is verified
///      compatible with v2 and identical to v3, which double-checks that StabilityPool_v3 is a valid route from v2.
///      OZ sees only @custom:oz-upgrades and validates it in isolation.
/// @custom:oz-upgrades
/// @custom:bao-upgrades-from src/minter/StabilityPool_v2.sol:StabilityPool_v2
// solhint-disable-next-line contract-name-capwords
contract StabilityPool_v3_Upgrader is UUPSUpgradeable, HarborFixedOwnable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev The linear distributor's ERC-7201 slot. Its storage LAYOUT is reached through the canonical
    ///      `LinearMultipleRewardDistributorStorage` type below, so only the slot is copied and it cannot drift; the
    ///      slot itself is verified against the namespace's canonical ERC-7201 hash by storage-successor (which
    ///      auto-detects the getter below), so a mistyped slot is caught.
    bytes32 private constant _LINEARMULTIPLEREWARDDISTRIBUTOR_STORAGE =
        0xe9dd8489e2940f6fb582767a094c112cfce2739b7a5f3357b085cab0a6a7d300;

    /// @dev The pool's ERC-7201 slot, reached through the canonical `StabilityPoolStorage` type below (same
    ///      auto-verified-slot guarantee as above).
    bytes32 private constant _STABILITYPOOL_STORAGE =
        0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    /// @param owner_ The account authorised to run the migration - the same account that owns the proxy (the Harbor
    ///        multisig in production).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_) HarborFixedOwnable(address(0), owner_, 0) {
        _disableInitializers();
    }

    /// @notice Widen-copy the reward streams, write the reward-divisor gap, then upgrade the proxy to StabilityPool_v3.
    /// @param rewardDivisorGap The gap to seed: `supply - Sum(balanceOf)`, computed off-chain from the complete frozen
    ///        holder list under realistic bounds so the v3 divisor (`supply - gap`) tracks Sum(balanceOf) from the
    ///        first block. `0` when supply already equals the summed balances.
    /// @param stabilityPoolV3 The real StabilityPool_v3 implementation to reinstate once migrated.
    function migrateAndUpgrade(int256 rewardDivisorGap, address stabilityPoolV3) external onlyOwner {
        LinearMultipleRewardDistributor_v3.LinearMultipleRewardDistributorStorage storage $reward = _rewardStorage();
        address[] memory tokens = $reward.activeRewardTokens.values();
        for (uint256 i = 0; i < tokens.length; ++i) {
            LinearReward.RewardData storage legacy = $reward.rewardDataUNUSED[tokens[i]];
            $reward.rewardData[tokens[i]] = LinearReward_v2.RewardData_v2({
                queued: legacy.queued,
                rate: legacy.rate,
                lastUpdate: legacy.lastUpdate,
                finishAt: legacy.finishAt
            });
        }

        _stabilityPoolStorage().rewardDivisorGap = rewardDivisorGap;

        upgradeToAndCall(stabilityPoolV3, "");
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @dev The distributor's namespaced storage, referenced through its canonical struct type at its fixed slot.
    function _rewardStorage()
        private
        pure
        returns (LinearMultipleRewardDistributor_v3.LinearMultipleRewardDistributorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _LINEARMULTIPLEREWARDDISTRIBUTOR_STORAGE
        }
    }

    /// @dev The pool's namespaced storage, referenced through its canonical struct type at its fixed slot.
    function _stabilityPoolStorage() private pure returns (StabilityPool_v3.StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STABILITYPOOL_STORAGE
        }
    }
}
