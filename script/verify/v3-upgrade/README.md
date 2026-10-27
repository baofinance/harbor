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
[How the rehearsal checks the upgrade](#how-the-rehearsal-checks-the-upgrade).

### 3. Deploy and save the batches

```bash
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
```

This is the rehearsal's command with `--account` in place of `--local`. It:

- deploys 11 Minter_v3, 22 StabilityPool_v3 and 11 StabilityPoolManager_v2 implementations, three libraries, one
  `StabilityPool_v3_Upgrader`, and one `Minter_v3_Upgrader` (GOLD::fxUSD and SILVER::fxUSD need it);
- saves 11 batch files, one per market, as
  `deployments/mainnet/batch/Upgrade_MarketsToV3_mainnet_<time>_<market>@harbor_multisig.json`;
- adds the new implementations to `deployments/mainnet/harbor_v1.state.json`.

The batch files are written before any transaction is sent. If the run stops part way, finish it with `--resume`, and
sign nothing until every deployment has landed: a batch naming an implementation that does not exist reverts in the
Safe.

### 4. Check the batches

```bash
script/decode-safe-batch <batch.json>
```

Each market's batch holds four calls, in this order:

1. the minter's upgrade - through `Minter_v3_Upgrader` for GOLD::fxUSD and SILVER::fxUSD;
2. the collateral pool's migration through `StabilityPool_v3_Upgrader`;
3. the leveraged pool's migration through `StabilityPool_v3_Upgrader`;
4. the manager's upgrade.

### 5. Sign and execute

- Each market's batch is independent of the others: they can be executed in any order.
- The Safe runs a batch as one transaction: all of it happens, or none of it. The largest batch uses about 4.2M gas.
- Executing a market's batch moves its minter, pools and manager off the pause implementation onto v3: **that market is
  live again at once**.
- No call in a batch reads a price.

### 6. Afterwards: the state file

The batches move no proxy's implementation pointer in `deployments/mainnet/harbor_v1.state.json`. Once they have
executed, set each proxy's implementation by hand to its new Minter_v3, StabilityPool_v3 or StabilityPoolManager_v2
implementation:

- not to an upgrader. `script/update-state --apply` reads only a batch's outer `upgradeToAndCall`, so it would record
  every pool, and the GOLD::fxUSD and SILVER::fxUSD minters, as running an upgrader;
- the pointers already lag the chain: the pause implementation was never recorded.

## What the upgrade changes

### Each market's batch

1. **The minter** is upgraded to Minter_v3, with its stored config loaded again through v3's loader in the same call:
   v3 refuses configs v2 accepted, and a plain upgrade would carry the stored encoding across unchecked. A minter that
   records backing but holds no wrapped collateral - GOLD::fxUSD and SILVER::fxUSD, 1 wei each - would be halted by
   Minter_v3 as impaired. It is upgraded through `Minter_v3_Upgrader` (`script/UpgradeMinter_v2_v3/`), which refuses a
   minter holding wrapped collateral, sets the record to zero, then upgrades it to Minter_v3 in the same call.
2. **Each pool** is migrated through `StabilityPool_v3_Upgrader` (`script/UpgradeStabilityPool_v2_v3/`), which copies
   its storage into v3's layout (below), writes its ledger gap, then upgrades it to StabilityPool_v3 in the same call.
3. **The manager** is upgraded to StabilityPoolManager_v2; its settings stay where they are in storage.

The upgrade refuses a capture not taken at the last block before the pause, holders that leave a ledger gap beyond
rounding, a minter config Minter_v3's loader refuses, and a pool implementation that would not keep the pool's floor
or withdrawal window.

### Storage layouts

- **Minter**: unchanged - the same namespace and struct in v2 and v3.
- **StabilityPoolManager**: v2 adds three fields at the end - what each pool is owed from harvests, and the yield
  vaults - which start empty.
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

The runner first runs `FrozenMarketsReadPoint`: the state the upgrade reads, at the end of the capture's block, is the
state it runs on - the pause changed only which implementation each minter and pool runs. It then asks you to start
anvil (`script/anvil --block latest`), and:

1. copies `deployments/mainnet/harbor_v1.state.json` to `deployments/local/mainnet/`, where the script reads the
   deployed addresses;
2. **before**: `MarketsCapture` with `VERSION=before`, on a fork of mainnet at the capture's block - the last block
   before the pause of 2026-10-22, where the markets still run. The managers were paused earlier, at block
   26,241,030, so the capture puts each manager's own implementation back first: their pause changed only that;
3. runs the upgrade script as it will be run on mainnet, with `--local` added: the batches execute on anvil as the
   multisig would execute them;
4. **after**: `MarketsCapture` with `VERSION=after`, on a fork of anvil, which must be past the capture's block;
5. **storage**: `MarketsStorageCopy`, on a fork of anvil;
6. **expected after**: `MarketsExpectedAfter` writes the record each contract must have after;
7. sorts the keys of each record and diffs the expected after against the after. Any difference fails the run.

`forge test` forks anvil in memory and writes nothing back, so one anvil session serves the whole run. Both captures
are warped to the same time, 12,000 seconds after anvil's head, so the reward streams and withdrawal windows read alike.

Each step's output is kept in `tmp/v3-upgrade/*.log`, and the records in `tmp/v3-upgrade/{before,after,expected-after}/`.
The runner needs `MAINNET_RPC_URL`, archival at the capture's block.

### What is recorded

`MarketsCapture` writes one record per contract, named by its salt key: `pre/` holds its state; for a pool, `post/`
holds its behaviour under the same interactions - a deposit, a reward deposited and streamed, claims, a withdrawal -
and its state after them.

- **Minter**: owner, config, the backing it records, its pegged and leveraged supply, the wrapped collateral it holds,
  its tokens, oracle, reserve pool and fee receiver, and the roles of the manager and the genesis contract; after, on
  Minter_v3, whether it is impaired.
- **StabilityPool**: supply, tokens, reward tokens and streams, withdrawal window and early-withdrawal fee, and per
  captured holder: balance, claimable and claimed rewards per reward token, withdrawal request; after, on
  StabilityPool_v3, its reward divisor and the minter it names.
- **StabilityPoolManager**: owner, pools, its minter and the market's tokens, the harvest bounty and cut, the rebalance
  bounty and threshold, and the fee receiver; after, whether it reports StabilityPoolManager_v2, and its yield vaults.

Where the two versions answer the same question through different functions, each is read through its own, into the
same key.

### What the upgrade is expected to change

The expected after is the before record, changed only where an expectation says. Each expectation is written in
`MarketsExpectedAfter.t.sol` with its reason:

| Contract | Key | Expected after | Reason |
|---|---|---|---|
| Minter | `minter_impaired` | `false` | Minter_v3 halts a minter that records more backing than it holds; the upgrade leaves none so |
| Minter that records backing but holds no wrapped collateral (GOLD::fxUSD, SILVER::fxUSD) | `minter_recordedBacking` | `0` | its batch upgrades it through `Minter_v3_Upgrader`, which sets the backing it does not hold to zero |
| StabilityPoolManager | `manager_reportsStabilityPoolManager_v2` | `true` | the upgrade puts StabilityPoolManager_v2 behind the manager |
| StabilityPoolManager | `manager_yieldVaultCount` | `0` | v2 adds yield vaults; the upgrade registers none |
| StabilityPool | `state_liquidationToken`, `state_minDeposit` | removed | v3 names no single liquidation token, and calls its minimum `MIN_TOTAL_ASSET_SUPPLY` |
| StabilityPool | `state_minter` | the market's minter | v3 names its minter, which v2 does not |
| StabilityPool | `state_rewardDivisor` | supply less the ledger gap | v3 divides rewards by what the holders hold |
| StabilityPool with a ledger gap | each claimable before the claims, each claim's payout, and after the interactions each claimed total | the before value moved by the shift, within 2 wei per fold | v3 divides the reward it folds into its reward-per-share after the upgrade by what the holders hold, not by the supply |

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
after value lies within 2 wei per fold of the before value moved by the shift. A pool whose deposits failed before the
upgrade is refused, since its folds fall elsewhere.

### Storage copied

`MarketsStorageCopy` reads, for every pool, the storage the upgrade copied, which the records see only through views:

- each captured holder's reward record for each reward token - pending, claimed, timestamp, integral - in its V2
  layout at the capture's block, against its V3 record after the upgrade;
- each reward token's stream;
- the ledger gap the upgrade wrote, against the pool's supply less what the captured holders held.

It fails unless at least one reward record had data to compare.

## Files

- `script/Upgrade_MarketsToV3_mainnet.s.sol` - the script, and `FROZEN_MARKETS_CAPTURE`
- `script/src/UpgradeMarketToV3.sol` - the read of each market, and its batch
- `script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol`, `script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol`
  - the one-shot upgraders
- `test/deployment/UpgradeMarketToV3.t.sol` - the upgrade's tests
- `script/verify/v3-upgrade/` - the rehearsal: `run-upgrade-rehearsal`, `FrozenMarketsReadPoint.t.sol`,
  `MarketsCapture.t.sol`, `MarketsExpectedAfter.t.sol`, `CaptureExpectationsLib.sol`, `MarketsStorageCopy.t.sol`
