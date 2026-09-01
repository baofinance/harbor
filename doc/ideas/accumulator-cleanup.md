# Accumulator Storage Cleanup

**Status: not implemented, not scheduled.** The migration this depends on has not run on mainnet yet,
so nothing here can be done until it has.

For the reward accounting this concerns, see the [functional specification](../functional-spec.md),
particularly §2.7 (reward accrual) and §5.8 (claiming rewards).

## The leftover

`LinearMultipleRewardDistributor_v3` widened its per-token reward record from the v1 layout
(`LinearReward.RewardData`) to `LinearReward_v2.RewardData_v2`, chiefly to carry the reward integral in
a full `uint256` instead of the original `uint192`. The widened mapping is a new field appended to the
namespaced struct; the original mapping stays where it is, renamed:

```solidity
/// @dev Legacy v1-layout reward data; read once by the v2->v3 StabilityPool_v3_Upgrader migrator to
///      seed the widened `rewardData` below, then vestigial. Stays at slot 0 so the deployed data is
///      read in place.
mapping(address => LinearReward.RewardData) rewardDataUNUSED;
```

Keeping it at slot 0 is what lets the migrator read the deployed data in place, so the field must
survive the upgrade that consumes it. Once `script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol`
has run against every deployed pool, `rewardDataUNUSED` holds nothing any reader needs.

## What the cleanup would be

Drop `rewardDataUNUSED` from `LinearMultipleRewardDistributorStorage`, leaving the widened `rewardData`
as the only reward record. This is a storage-layout change to a namespaced struct, so it is not free:
removing the first member shifts every member after it. The two available shapes are to leave a
placeholder of the same size in slot 0 and drop only the type, or to move the remaining fields into a
new namespace under their own name and leave the old one intact — the second being what the ERC-7201
rule in `CLAUDE.md` prescribes for storage that cannot be appended to.

## Preconditions

1. Every deployed StabilityPool has been upgraded to v3 and its migration confirmed complete — the
   field cannot be removed while any pool still needs its v1-layout data read.
2. The choice between placeholder and new namespace is made deliberately, with `yarn validate`
   confirming the hardcoded slot constants still derive from their annotations.

## Why it is worth doing at all

It is dead storage carrying a type (`LinearReward.RewardData`) that exists only to be readable by a
migrator that has finished. Carrying it indefinitely means every future reader of the struct has to
work out that the first field is inert, and the v1 reward type cannot be deleted while a struct still
names it.

There is no urgency: the field costs nothing at runtime, since nothing reads it after migration.

## Provenance

This item was previously recorded, in one line, in `autocompounding-vault-design.md` — a document since
superseded by [`design.md` in the harbor-yield
repository](https://github.com/baofinance/harbor-yield/blob/main/doc/design.md) and removed. That line
named the migrator `ForceMigrateAccumulator_v1`, which no longer exists in this repository; the
migration is `StabilityPool_v3_Upgrader`, and the description above is written against the current
source rather than carried over.
