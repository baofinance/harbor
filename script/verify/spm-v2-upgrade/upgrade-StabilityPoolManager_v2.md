# StabilityPoolManager v1 -> v2 upgrade

## What changes

v2 removes `updateHarvestBountyRatio` and `updateHarvestCutRatio` and replaces them with a single
`updateHarvestRatios(bounty, cut)`. The harvest bounty and cut are independent slices of the same harvest gross,
and what a stability pool is streamed is the residual they leave of it, so a pair summing above 100% describes a
split that does not exist. v1 capped each ratio on its own and so could store such a pair; v2 validates the pair,
and writing both together means any valid pair is reachable in one call from any stored pair.

Because a function is removed, `IStabilityPoolManager_v2` is a standalone copy of `IStabilityPoolManager` rather
than an extension of it, and the upgraded proxy reports the v2 interface id and stops reporting the v1 one.

## Precondition

Every market's stored bounty and cut must already sum within 100% before the upgrade: v2 has no single-ratio setter
to repair a stored pair with. Two markets did not satisfy this - MCAP::fxUSD and MCAP::stETH held a 100% cut
alongside the 1% bounty, the pair the deploy config carried before it was corrected - and were repaired by
`script/UpdateHarvestCut_MCAP.s.sol` at mainnet block 25691117. All eleven markets now hold 1e16 / 99e16.

A market upgraded without that repair is not bricked: harvest is unavailable until the owner calls
`updateHarvestRatios`, which validates the pair being written rather than the pair stored, so one call fixes it.
`test_upgradedPairAboveOneHundredPercentIsRepairable_` pins that recovery path.

## What the verification asserts

Forking mainnet at block 25691117 and upgrading each of the eleven live stability pool managers:

- **`test_upgradePreservesSettings_`** - both harvest ratios, both rebalance settings and the fee receiver survive
  the upgrade unchanged, and the reported interface swaps from the v1 ABI to the v2 one.
- **`test_upgradedHarvestRatiosAreWithinOneHundredPercent_`** - the precondition above holds for every market.
- **`test_upgradedHarvestWorks_`** - a market holding harvestable yield harvests it; one holding none reverts
  `NoHarvestable` rather than failing some other way. At least one market must actually harvest, so the check
  cannot pass by every market having nothing to do.
- **`test_upgradedPairAboveOneHundredPercentIsRepairable_`** - the recovery path described above.

## Running it

    script/verify/spm-v2-upgrade/run-upgrade-test-StabilityPoolManager_v2

No anvil instance and no prior deploy run: the test forks mainnet at the pinned block and performs the upgrade
itself, because there is no StabilityPoolManager v2 upgrade script yet. When that script exists, these assertions
apply unchanged to a proxy it upgraded - only the test's own upgrade step goes away.
