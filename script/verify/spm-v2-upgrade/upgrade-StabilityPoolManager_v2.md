# StabilityPoolManager v1 -> v2 upgrade

## What changes

v2 removes `updateHarvestBountyRatio`, `updateHarvestCutRatio` and `updateRebalanceBountyRatio` and replaces them
with one setter per action: `updateHarvestConfig(bountyRatio, bountyCeiling, cutRatio)` and
`updateRebalanceConfig(bountyRatio, bountyCeiling, cutRatio)`. The harvest bounty and cut are independent slices of
the same harvest gross, and what a stability pool is streamed is the residual they leave of it, so a pair summing
above 100% describes a split that does not exist. v1 capped each ratio on its own and so could store such a pair; v2
validates the pair, and writing the terms together means any valid pair is reachable in one call from any stored
pair.

v2 adds a bounty ceiling to each action and a cut to the rebalance. The upgrade itself leaves them zero, which is no
ceiling and no cut, so each market's batch sets both actions' terms after the manager's upgrade, to what the market
config gives, as a deploy sets them. The rebalance threshold and the fee receiver stay as they are.

Because a function is removed, `IStabilityPoolManager_v2` is a standalone copy of `IStabilityPoolManager` rather
than an extension of it, and the upgraded proxy reports the v2 interface id and stops reporting the v1 one.

## A stored pair above 100%

The batch writes the config's pair through `updateHarvestConfig`, which validates the pair being written rather than
the pair stored, so a market whose stored bounty and cut sum above 100% comes out of its batch with the config's pair
and harvests at once. MCAP::fxUSD and MCAP::stETH held such a pair - a 100% cut alongside the 1% bounty, the pair the
deploy config carried before it was corrected - until `script/UpdateHarvestCut_MCAP.s.sol` repaired them at mainnet
block 25691117. Since then every market runs on its config's ratios, so the batch changes none of them and adds only
the ceilings.

## What the verification asserts

Forking mainnet at block 25691117 and upgrading each of the eleven live markets - the manager in place, with the minter
and both pools - by `UpgradeMarketToV3.upgradeMarketsToV3` (`script/src/UpgradeMarketToV3.sol`), the function the
upgrade script `script/Upgrade_MarketsToV3_mainnet.s.sol` runs, from the holder capture at that block
(`holders-25691117/`):

- **`test_upgradeSetsTheConfiguredTermsAndKeepsTheRest_`** - every market runs on its config's ratios before the
  upgrade and keeps them; it gains the config's bounty ceilings and rebalance cut; its rebalance threshold and fee
  receiver are unchanged; and the reported interface swaps from the v1 ABI to the v2 one.
- **`test_upgradedHarvestWorks_`** - a market holding harvestable yield harvests it; one holding none reverts
  `NoHarvestable` rather than failing some other way. At least one market must actually harvest, so the check
  cannot pass by every market having nothing to do.
- **`test_theUpgradeRepairsAPairAboveOneHundredPercent_`** - a market whose stored pair sums above 100% comes out of
  its batch with the config's pair and harvests straight after it.

## Running it

    script/verify/spm-v2-upgrade/run-upgrade-test-StabilityPoolManager_v2

No anvil instance and no prior deploy run: the test forks mainnet at the pinned block and runs the upgrade script's own
function there, so these assertions are about the proxies that function upgrades.
