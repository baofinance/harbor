# Upgrading every market to v3

`script/Upgrade_MarketsToV3_mainnet.s.sol` upgrades every live market's minter to Minter_v3, its two stability pools
to StabilityPool_v3 and its manager to StabilityPoolManager_v2. It deploys the new implementations and saves one Safe
batch per market for the multisig to sign. This document is the campaign's one reference: the runbook, what the upgrade
changes, and how the rehearsal checks it.

## Runbook

### Before you start

- The markets are frozen. The pause of 2026-10-22, at block 26,248,724, put every minter and pool on the pause
  implementation; the managers were paused earlier, at block 26,241,030. The upgrade reads each market at block
  26,248,723, the last before the pause.
- The holder capture the upgrade reads is `FROZEN_MARKETS_CAPTURE` in the script,
  `script/UpgradeStabilityPool_v2_v3/holders-26248723/`. It must list every holder of every pool.
- `MAINNET_RPC_URL` must be archival at block 26,248,723.
- The deploying account (`--account`) needs ETH for about 218M gas, in 49 transactions (measured on the rehearsal).
  With ETH at $2,313 (2026-10-26):

  | Gas price | ETH | USD |
  |---|---|---|
  | 0.054 gwei (the base fee on 2026-10-26) | 0.012 | about $27 |
  | 1 gwei | 0.22 | about $505 |
  | 5 gwei | 1.09 | about $2,530 |

  Forge checks the balance against its own estimate, which adds a margin.

### 1. Check the pools' ledger gaps

```bash
script/verify/sp-v3-reward-divisor-migration/run-migration-preflight --holders-dir script/UpgradeStabilityPool_v2_v3/holders-26248723
```

Each pool's ledger gap against the capture must be within rounding either side of zero, and its supply within the
ceiling StabilityPool_v3 enforces.

### 2. Rehearse on anvil

```bash
script/verify/v3-upgrade/run-upgrade-rehearsal
```

Start anvil when asked (`script/anvil --block latest`). The run must end with PASS. What it checks is described under
[How the rehearsal checks the upgrade](#how-the-rehearsal-checks-the-upgrade). Every request to the RPC provider is
paced and retried against its rate limit - anvil's to its upstream by `script/anvil`, the steps' by the runner, the
script's own forks by `script/run-script` - so a refusal (HTTP 429) waits rather than fails the run.

### 3. Deploy and save the batches

```bash
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
```

This is the rehearsal's command with `--account` in place of `--local`. It:

- deploys 11 Minter_v3, 22 StabilityPool_v3 and 11 StabilityPoolManager_v2 implementations, three libraries, one
  `StabilityPool_v3_Upgrader`, one `Minter_v3_Upgrader` (GOLD::fxUSD and SILVER::fxUSD need it), and two
  `FrozenPriceOracle`s (BTC::stETH's and EUR::stETH's compensation);
- saves 11 batch files, one per market, as
  `deployments/mainnet/batch/Upgrade_MarketsToV3_mainnet_<time>_<market>@harbor_multisig.json`;
- adds every contract it deploys to `deployments/mainnet/harbor_v1.state.json`: the implementations under their
  proxies, the upgraders and the frozen oracles under `*`, as one-shots;
- writes the compensation as queued to `doc/incidents/2026-10-16-rebalance-dilution/phase1.md`.

The batch files are written before any transaction is sent. If the run stops part way, finish it with `--resume`, and
sign nothing until every deployment has landed: a batch naming an implementation that does not exist reverts in the
Safe.

### 4. Check the batches

```bash
script/decode-safe-batch <batch.json>
```

The decoder names every address a batch carries from the state file of the salt prefix the batch names in its meta,
`<salt prefix>.state.json` beside the batch's directory: a batch under `deployments/mainnet/batch/` from mainnet's
state, a rehearsal's under `deployments/local/mainnet/batch/` from the rehearsal's. An implementation reads as its
contract, source, the proxy it serves or "one-shot", and its deploy time, for example:

```
newImplementation: 0x8456B2…  // Minter_v3 - @harbor/minter/Minter_v3.sol, impl for BTC::stETH::minter, deployed 2026-10-28T17:17:59Z
```

Each market's batch holds these calls, in this order:

1. the minter's upgrade - through `Minter_v3_Upgrader` for GOLD::fxUSD and SILVER::fxUSD;
2. for BTC::fxUSD, ETH::fxUSD, EUR::fxUSD and GOLD::fxUSD, `updatePriceOracle` to the oracle proxy the deploy
   predicts; for BTC::stETH and EUR::stETH, whose batches carry the compensation, `updatePriceOracle` to a
   `FrozenPriceOracle` of the batch's own, answering what the minter's oracle answered at the capture's block;
3. the collateral pool's migration through `StabilityPool_v3_Upgrader`;
4. the leveraged pool's migration through `StabilityPool_v3_Upgrader`;
5. the manager's upgrade, then `updateRebalanceConfig` and `updateHarvestConfig`, each setting one action's bounty
   ratio, bounty ceiling and cut ratio to the market config's - their descriptions state the values;
6. for BTC::stETH and EUR::stETH, the compensation's approvals, redemptions and mints, then `updatePriceOracle` to
   the oracle proxy the deploy predicts.

### The compensation: phase 1 in the batches, phase 2 after

BTC::stETH's and EUR::stETH's batches carry phase 1 of the repayment for the rebalance dilution exploits of
2026-10-16 ([the incident](../../../doc/incidents/2026-10-16-rebalance-dilution/README.md); the rule and each wallet's
treatment in its [holder-stories.md](../../../doc/incidents/2026-10-16-rebalance-dilution/holder-stories.md)). What
each batch does is under [Each market's batch](#each-markets-batch), item 4. Before signing those two batches:

- **Read `doc/incidents/2026-10-16-rebalance-dilution/phase1.md`**, which step 3 wrote: the fund, the fraction of each
  debt it pays, each market's reading held still with the leveraged token's price and the collateral ratio before the
  operations and after them, and per wallet what it is owed in wstETH, the leveraged tokens it receives, their worth
  at the reading and what it is still owed. Every figure is what the batch moves: the batch prices the operations at
  the capture block's oracle reading, held still for it, so nothing in it depends on the price at execution.
- **Check the decoded batch against it:** the move to the `FrozenPriceOracle`, the pegged fee approved and redeemed,
  the cuts approved and redeemed (BTC::stETH), the wrapped collateral approved for the mints' total, one mint per
  wallet with the amount `phase1.md` states, and the move to the oracle proxy last.
- **The multisig must hold what the batch spends:** its wstETH fees from the exploits (3.0028 for BTC::stETH, 0.9899
  for EUR::stETH), 0.07405 haBTC and 1,584.05 haEUR - its fees from the exploits, as the compensation files record
  them. The redemptions put back what the mints need beyond the wstETH fees. If any of these has moved, the batch
  reverts and the market stays paused.
- **Phase 2** is what remains of each debt after phase 1, the "still owed" column of `phase1.md`: about 7.8 wstETH
  over both markets, what the exploits paid out. Nothing in these batches depends on it. Its form is to be settled;
  it is not part of this upgrade.

### 5. Sign and execute

- Each market's batch is independent of the others: they can be executed in any order.
- The Safe runs a batch as one transaction: all of it happens, or none of it. The largest batch used about 4.2M gas
  on the rehearsal of 2026-10-28. The manager's two setters, added since, cost at most 0.15M more by their measured
  cost.
- Executing a market's batch moves its minter, pools and manager off the pause implementation onto v3: **that market is
  live again at once**.
- No call in a batch reads a live price: BTC::stETH's and EUR::stETH's batches price the compensation at the capture
  block's reading, held still in a `FrozenPriceOracle`; every other batch reads none.

### 6. Afterwards: the state file

The batches move no proxy's implementation pointer in `deployments/mainnet/harbor_v1.state.json`. Once they have
executed, set each proxy's implementation by hand to its new Minter_v3, StabilityPool_v3 or StabilityPoolManager_v2
implementation:

- not to an upgrader. `script/update-state --apply` reads only a batch's outer `upgradeToAndCall`, so it would record
  every pool, and the GOLD::fxUSD and SILVER::fxUSD minters, as running an upgrader;
- the pointers already lag the chain: the pause implementation was never recorded.

### 7. Later: when a market config's terms change

The batches set each manager's terms from the market configs as they are when the batches are built. When a config's
terms change - for a bounty ceiling, when the wrapped collateral's price has moved far from what its
`aboutADollarInWrappedCollateral` assumes - `script/UpdateHarvestAndRebalanceConfig_AllMarkets.s.sol` saves one batch
that sets every manager's harvest and rebalance terms to its config's again, through the same calls.

## What the upgrade changes

### Each market's batch

1. **The minter** is upgraded to Minter_v3, with its stored config loaded again through v3's loader in the same call:
   v3 refuses configs v2 accepted, and a plain upgrade would carry the stored encoding across unchecked. A minter that
   holds no wrapped collateral must record no backing. GOLD::fxUSD and SILVER::fxUSD, retired, hold none and record
   1 wei each: each is upgraded through `Minter_v3_Upgrader` (`script/UpgradeMinter_v2_v3/`), which refuses a minter
   holding wrapped collateral, sets the record to zero, then upgrades it to Minter_v3 in the same call.
   A deploy wires a minter to the oracle proxy it predicts, and a minter reading another oracle is pointed at that
   proxy. At the capture, BTC::fxUSD, BTC::stETH, ETH::fxUSD and EUR::fxUSD read the very implementation their proxy
   runs, directly. GOLD::fxUSD reads the fxUSD/XAU implementation, where its config names the fxUSD/GOLD proxy, which
   runs `Aggregator_fxUSD_GOLD_mainnet`: the XAU aggregator with its quote name changed, answering alike.
2. **Each pool** is migrated through `StabilityPool_v3_Upgrader` (`script/UpgradeStabilityPool_v2_v3/`), which copies
   its storage into v3's layout (below), writes its ledger gap, then upgrades it to StabilityPool_v3 in the same call.
3. **The manager** is upgraded to StabilityPoolManager_v2; its settings stay where they are in storage. Then
   `updateRebalanceConfig` and `updateHarvestConfig` set each action's bounty ratio, bounty ceiling and cut ratio to
   the market config's, as a deploy sets them. At the capture every market runs on its config's ratios, so no ratio
   changes: the calls set the bounty ceilings v2 adds, and the rebalance cut v2 adds, which the config makes zero. The
   ceilings are a hundred and two hundred times the config's `aboutADollarInWrappedCollateral` - for example, as
   configured on 2026-10-29, 0.03 and 0.06 wstETH in the stETH markets, 100 and 200 fxSAVE in the fxUSD markets. The
   rebalance threshold and the fee receiver stay as they are.
4. **The compensation**, in the two markets the rebalance dilution exploits of 2026-10-16 hit (BTC::stETH and
   EUR::stETH; `script/src/CompensateRebalanceDilution.sol`, from the incident's `<market>-compensation.json` files):
   the leveraged pool's migration takes each gainer's cut from what it may claim and pays it to the multisig; then the
   multisig approves and redeems, fee-free, its pegged fee from the exploit and the tokens taken back, approves the
   wrapped collateral it mints with, and mints leveraged tokens fee-free for each holder that lost, with its share of
   the fund. All in the market's one transaction, so nobody acts on the market in between. Every amount is fixed when
   the batch is built: before the pools' migration the batch points the minter at a `FrozenPriceOracle`
   (`script/UpgradeMinter_v2_v3/`) answering what its oracle answered at the capture's block, the reading the batch's
   every input was read at, and after the compensation at the oracle proxy the deploy predicts; the redemptions'
   returns and each mint's leveraged are sized by the minter's own arithmetic at that reading, so the fund is exactly
   what the multisig holds to mint with. The payout as queued, with what each loser receives, is written to the
   incident directory's `phase1.md`.

The upgrade refuses a capture not taken at the last block before the pause, holders that leave a ledger gap beyond
rounding, a minter config Minter_v3's loader refuses, and a pool implementation that would not keep the pool's floor
or withdrawal window.

### Storage layouts

- **Minter**: unchanged - the same namespace and struct in v2 and v3.
- **StabilityPoolManager**: v2 adds six fields at the end - what each pool is owed from harvests, the yield vaults,
  the two bounty ceilings and the rebalance cut - which start empty. The batch sets the ceilings and the cut.
- **StabilityPool**:

| Change from v2 to v3 | How the upgrade handles it | What checks it |
|---|---|---|
| Each reward token's stream moves to a new, wider mapping (queued 96 to 256 bits, rate 80 to 128); the old `rewardDataUNUSED` stays where it was | The pool upgrader copies each active token's stream. No pool has ever unregistered a reward token, so the active tokens are all of them | `MarketsStorageCopy`: each stream equal; `MarketsCapture`: the stream views |
| Each holder's reward record moves to a new, wider mapping (pending and claimed 128 to 256 bits), from `userRewardSnapshotV2NOTUSED` to `userRewardSnapshot` | The pool upgrader copies the record of every holder in the capture - why the capture must be complete | `MarketsStorageCopy`: every record field by field |
| v2's fallback to the older v1 holder records is gone | Nothing is copied from the v1 records | `MarketsCapture`: a holder still relying on v1 data would read a different claimable or claimed |
| The supply amount is widened in place (104 to 128 bits) | No copy is needed | `yarn validate` |
| The reward-divisor gap, `rewardDivisorGap`, is added | The pool upgrader writes it: the supply less what the captured holders hold | `MarketsStorageCopy`: the gap written; `MarketsCapture`: the reward divisor |

## How the rehearsal checks the upgrade

The rehearsal runs the upgrade script itself on an anvil fork of the chain's head, and checks what every market
contract reads after it against what it read before.

### How it runs

The upgrade reads one holder capture, `FROZEN_MARKETS_CAPTURE` in `script/Upgrade_MarketsToV3_mainnet.s.sol`, and the
campaign's tests read the same constant. The rehearsal and the mainnet run differ only in `--local` and `--account`:

```bash
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --local
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
```

`--local` sends each call of every batch as its own transaction from the multisig; the Safe sends each batch as one.
The calls are the same: the batch files and the local execution come from the same queue.

The runner first runs `CaptureExpectations`, the tests of the library that builds the expected-after records, so a
broken library fails the run before anything is forked. It then runs `FrozenMarketsReadPoint`: the state the upgrade
reads, at the end of the capture's block, is the state it runs on - the pause changed only which implementation each
minter and pool runs. It then runs
`UpgradedMarketsMatchANativeDeploy`: each upgraded market holds the settings a native deploy sets (see
[Settings against a native deploy](#settings-against-a-native-deploy)). It then asks you to start anvil
(`script/anvil --block latest`), and:

1. copies `deployments/mainnet/harbor_v1.state.json` to `deployments/local/mainnet/`, where the script reads the
   deployed addresses;
2. **before**: `MarketsCapture` with `VERSION=before`, on a fork of mainnet at the capture's block - the last block
   before the pause of 2026-10-22, where the markets still run. The managers were paused earlier, at block
   26,241,030, so the capture puts each manager's own implementation back first: their pause changed only that;
3. runs the upgrade script as it will be run on mainnet, with `--local` added: the batches execute on anvil as the
   multisig would execute them;
4. **after**: `MarketsCapture` with `VERSION=after`, on a fork of anvil, which must be past the capture's block;
5. **storage**: `MarketsStorageCopy`, on a fork of anvil;
6. **expected after**: `MarketsExpectedAfter` writes the record each contract must have after, reading on mainnet at
   the capture's block the oracle the deploy predicts for each market;
7. sorts the keys of each record and diffs the expected after against the after. Any difference fails the run.

The native-settings check and the rehearsal are independent: the runner runs both, reports each, and fails if either
failed.

`forge test` forks anvil in memory and writes nothing back, so one anvil session serves the whole run. Both captures
are warped to the same time, 12,000 seconds after anvil's head, so the reward streams and withdrawal windows read alike.

Each step's output is kept in `tmp/v3-upgrade/*.log`, and the records in `tmp/v3-upgrade/{before,after,expected-after}/`.
The runner needs `MAINNET_RPC_URL`, archival at the capture's block.

### What is recorded

`MarketsCapture` writes one record per contract, named by its salt key: `pre/` holds its state; for a pool, `post/`
holds its behaviour under the same interactions - a deposit, a reward deposited and streamed, claims, a withdrawal -
and its state after them. Every interaction must succeed: one that reverts fails the capture. A contract's state is
its settings - what a deploy writes, read by `MarketSettings.sol` - and its holdings - what holders' actions write.

- **Minter**: owner, config, the backing it records, its pegged and leveraged supply, the wrapped collateral it holds,
  its tokens, oracle - with the implementation it runs, zero for an oracle that is not a proxy - reserve pool and fee
  receiver, the roles of the manager and the genesis contract, and the owner of its reserve pool and of each token with
  the roles it holds on each.
- **StabilityPool**: supply, tokens, reward tokens and streams, withdrawal window and early-withdrawal fee, the roles
  of the manager, and per captured holder: balance, claimable and claimed rewards per reward token, withdrawal request;
  after, on StabilityPool_v3, its reward divisor and the minter it names.
- **StabilityPoolManager**: owner, pools, its minter and the market's tokens, the harvest bounty and cut, the rebalance
  bounty and threshold, and the fee receiver; after, whether it reports StabilityPoolManager_v2, its yield vaults, the
  two bounty ceilings and the rebalance cut.

Where the two versions answer the same question through different functions, each is read through its own, into the
same key.

### What the upgrade is expected to change

The expected after is the before record, changed only where an expectation says. Each expectation is written in
`MarketsExpectedAfter.t.sol` with its reason:

| Contract | Key | Expected after | Reason |
|---|---|---|---|
| Minter that records backing but holds no wrapped collateral (GOLD::fxUSD, SILVER::fxUSD) | `minter_recordedBacking` | `0` | a minter holding no wrapped collateral records none: its batch upgrades it through `Minter_v3_Upgrader`, which sets the record to zero |
| Minter that reads an oracle other than its predicted proxy (BTC::fxUSD, BTC::stETH, ETH::fxUSD, EUR::fxUSD, GOLD::fxUSD) | `minter_priceOracle` | the predicted proxy | its batch points it at the oracle proxy the deploy predicts |
| the same, where the proxy runs the oracle it read (all but GOLD::fxUSD) | `minter_priceOracle_implementation` | the oracle it read before | the proxy it reads runs the implementation it read before |
| the same, where the proxy runs other code (GOLD::fxUSD) | `minter_priceOracle_implementation` | the proxy's implementation | it answered as the oracle it read at the capture's block - the expected after is refused otherwise |
| StabilityPoolManager | `manager_reportsStabilityPoolManager_v2` | `true` | the upgrade puts StabilityPoolManager_v2 behind the manager |
| StabilityPoolManager | `manager_yieldVaultCount` | `0` | v2 adds yield vaults; the upgrade registers none |
| StabilityPoolManager | `manager_rebalanceBountyRatio`, `manager_rebalanceBountyCeiling`, `manager_rebalanceCutRatio`, `manager_harvestBountyRatio`, `manager_harvestBountyCeiling`, `manager_harvestCutRatio` | the market config's | its batch sets each action's bounty ratio, bounty ceiling and cut ratio to the market config's |
| StabilityPool | `state_liquidationToken`, `state_minDeposit` | removed | v3 names no single liquidation token, and calls its minimum `MIN_TOTAL_ASSET_SUPPLY` |
| StabilityPool | `state_minter` | the market's minter | v3 names its minter, which v2 does not |
| StabilityPool | `state_rewardDivisor` | supply less the ledger gap | v3 divides rewards by what the holders hold |
| StabilityPool with a ledger gap | each claimable before the claims, each claim's payout, and after the interactions each claimed total | the before value moved by the shift, within 2 wei per fold | v3 divides the reward it folds into its reward-per-share after the upgrade by what the holders hold, not by the supply |
| Minter of a compensated market (BTC::stETH, EUR::stETH) | `minter_peggedBalance` | before, less the pegged fee redeemed | the multisig redeems its pegged fee from the exploit, fee-free, in the market's batch; the fee redeemed is read from the minter's events on anvil and must be the file's |
| the same | `minter_leveragedBalance` | before, less the cuts redeemed, plus the leveraged minted (the events) | the multisig redeems the cuts taken back and mints fee-free for each loser |
| the same | `minter_wrappedCollateralHeld` | before, less the redemptions, plus the mints (the events) | the redemptions take wrapped collateral out of the minter and the mints put it in |
| the same | `minter_recordedBacking` | before moved by the same, each mint's wrapped collateral converted at the low rate and floored, each redemption's at the high rate and ceiled - the rates the batch held still for the operations, its oracle's at the capture's block - within 2 wei per operation | the record follows the holding |
| the same | `minter_priceOracle` | the predicted proxy, as for any minter reading another oracle | its batch points it at a `FrozenPriceOracle` for the compensation and at the proxy after; EUR::stETH, reading the proxy before, reads it after |
| StabilityPool whose migration takes rewards back (BTC::stETH's leveraged pool) | each deducted holder's claimable until its first claim, that claim's payout, and its claimed total | the before value less the cut, moved by the shift | the migration takes the cut from what the holder may claim and pays it to the multisig |
| the same | every claimable, payout and claimed total | within 2 wei per fold, one fold more | the migration's checkpoint folded the stream up to its moment, at the same divisor as fold 0 |
| the same | `state_reward_<t>_lastUpdate` | the migration's moment: the after's own reading, which must lie after the before's and no later than the captures' time | the checkpoint folded every stream |
| the same | `state_reward_<t>_pendingDistributable` | the rate over the time from the migration's moment to the captures' time, within the period | what is left to distribute runs from where the stream was folded |

An expectation of the `Within` kind admits the after value if it lies within its bound, derived for that value, and
otherwise writes the expected value, so the diff shows both. An expectation for a key neither record has is refused.

#### The shift of a pool's rewards

A holder's claimable is what is settled into their record, plus their share of what the pool has folded into its
reward-per-share, plus their share of the stream it has not folded yet. StabilityPool_v2 computed the first two and the
upgrade copies them; only reward folded after the upgrade - or read as the unfolded stream - is divided by v3's divisor,
the supply less the gap. For each such fold v3 credits a holder `credit x gap / (divisor - gap)` more than v2 did,
`credit` being v2's credit for that fold.

The capture folds three times: the test user's deposit folds the stream pending at the start, at the supply before
the interactions; the half-period and full-period claims fold the two halves of the rehearsal's reward stream, at the
supply after the two deposits. The first fold's credit is each holder's share of the pending stream; the other two are
read from v2's own readings. Each version floors a reading once per fold, and the computed shift truncates once, so the
after value lies within 2 wei per fold of the before value moved by the shift.

### Storage copied

`MarketsStorageCopy` reads, for every pool, the storage the upgrade copied, which the records see only through views:

- each captured holder's reward record for each reward token - pending, claimed, timestamp, integral - in its V2
  layout at the capture's block, against its V3 record after the upgrade;
- each reward token's stream;
- the ledger gap the upgrade wrote, against the pool's supply less what the captured holders held.

A pool whose migration takes rewards back (the compensation's deductions, read from the incident's files) is checked
for what that migration does instead: every stream's last update, and the timestamp of every record of each holder a
reward is taken from - for every reward token, the checkpoint settling the holder whole - is the migration's moment;
each such record's pending is what its account may claim at that moment on the upgraded pool,
and what it could claim on the frozen pool at that moment less its cut, where one was taken in that token, to the
shift of the stream the migration folded; its claimed is copied; every other holder's records are copied exactly.

It fails unless at least one reward record had data to compare.

### Settings against a native deploy

The records compare each market with itself before the upgrade. `UpgradedMarketsMatchANativeDeploy` compares it with a
market deployed natively on v3. A contract's behaviour follows from its code, its settings and its holdings. The code
is built from the same source as a native deploy's, and the records check the holdings carried over, so a market that
also holds a native deploy's settings behaves as a native market would, holding what it holds.

For each peg, on a fork of mainnet at the block after the capture, where every minter and pool is paused:

1. the upgrade script's own function upgrades the peg's markets, as the multisig would execute it;
2. the production deploy deploys the same peg beside them, under the salt prefix `native_v3`, wired to the live
   oracles, and owned and paid as production's;
3. `MarketSettings` reads the settings of both markets' minter, pools and manager. Each address the native market
   names is read as the upgraded market's at the same deploy key: its minter, reserve pool, genesis, pools, manager
   and tokens. Every setting must be equal; each difference is logged before the test fails.

One test per peg, so each stays within a test's gas and a failure names its peg. A role granted on mainnet to an
address the deploy grants none is not seen.

## Files

- `script/Upgrade_MarketsToV3_mainnet.s.sol` - the script, and `FROZEN_MARKETS_CAPTURE`
- `script/src/UpgradeMarketToV3.sol` - the read of each market, and its batch
- `script/src/contracts/StabilityPoolManager.sol` - `queueStabilityPoolManagerConfig`, the manager's two setter calls
  the batch carries, which `script/UpdateHarvestAndRebalanceConfig_AllMarkets.s.sol` queues for every market
- `script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol`, `script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol`
  - the one-shot upgraders
- `test/deployment/UpgradeMarketToV3.t.sol` - the upgrade's tests
- `script/verify/v3-upgrade/` - the rehearsal: `run-upgrade-rehearsal`, `CaptureExpectations.t.sol`,
  `FrozenMarketsReadPoint.t.sol`, `UpgradedMarketsMatchANativeDeploy.t.sol`, `MarketsCapture.t.sol`,
  `MarketSettings.sol`, `MarketsExpectedAfter.t.sol`, `CaptureExpectationsLib.sol`, `MarketsStorageCopy.t.sol`
