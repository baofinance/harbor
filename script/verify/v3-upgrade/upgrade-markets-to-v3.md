# Rehearsing the upgrade of every market to v3

`script/Upgrade_MarketsToV3_mainnet.s.sol` upgrades every live market to Minter_v3, StabilityPool_v3 and
StabilityPoolManager_v2, one Safe batch per market. This campaign rehearses that script on an anvil fork of the
chain's head, and checks what every market contract reads after it against what it read before.

## How it runs

```bash
script/verify/v3-upgrade/run-upgrade-rehearsal
```

The upgrade reads one holder capture, `FROZEN_MARKETS_CAPTURE` in `script/Upgrade_MarketsToV3_mainnet.s.sol`, and the
campaign's tests read the same constant. The rehearsal and the mainnet run differ only in `--local` and `--account`:

```bash
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --local
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
```

The runner first runs `FrozenMarketsReadPoint`: the state the upgrade reads, at the end of the capture's block, is the
state it runs on - the pause changed only which implementation each minter and pool runs. It then asks you to start
anvil (`script/anvil --block latest`), and:

1. copies `deployments/mainnet/harbor_v1.state.json` to `deployments/local/mainnet/`, where the script reads the
   deployed addresses;
2. **before**: `MarketsCapture` with `VERSION=before`, on a fork of mainnet at the capture's block - the last block
   before the pause of 2026-10-22, where the markets still run. The managers were paused earlier, at block
   26,241,030, so the capture puts each manager's own implementation back first;
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

## What is recorded

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

## What the upgrade is expected to change

The expected after is the before record, changed only where an expectation says. Each expectation is written in
`MarketsExpectedAfter.t.sol` with its reason:

| Contract | Key | Expected after | Reason |
|---|---|---|---|
| Minter | `minter_impaired` | `false` | Minter_v3 halts a minter that records more backing than it holds; the upgrade leaves none so |
| Minter that records backing but holds no wrapped collateral (GOLD::fxUSD, SILVER::fxUSD) | `minter_recordedBacking` | `0` | its batch recognises the backing it records but does not hold |
| StabilityPoolManager | `manager_reportsStabilityPoolManager_v2` | `true` | the upgrade puts StabilityPoolManager_v2 behind the manager |
| StabilityPoolManager | `manager_yieldVaultCount` | `0` | v2 adds yield vaults; the upgrade registers none |
| StabilityPool | `state_liquidationToken`, `state_minDeposit` | removed | v3 names no single liquidation token, and calls its minimum `MIN_TOTAL_ASSET_SUPPLY` |
| StabilityPool | `state_minter` | the market's minter | v3 names its minter, which v2 does not |
| StabilityPool | `state_rewardDivisor` | supply less the ledger gap | v3 divides rewards by what the holders hold |
| StabilityPool with a ledger gap | each claimable before the claims, each claim's payout, and after the interactions each claimed total | the before value moved by the shift, within 2 wei per fold | v3 divides the reward it folds into its reward-per-share after the upgrade by what the holders hold, not by the supply |

An expectation of the `Within` kind admits the after value if it lies within its bound, derived for that value, and
otherwise writes the expected value, so the diff shows both. An expectation for a key neither record has is refused.

### The shift of a pool's rewards

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

## Storage copied

`MarketsStorageCopy` reads, for every pool, the storage the upgrade copied, which the records see only through views:

- each captured holder's reward record for each reward token - pending, claimed, timestamp, integral - in its V2
  layout at the capture's block, against its V3 record after the upgrade;
- each reward token's stream;
- the ledger gap the upgrade wrote, against the pool's supply less what the captured holders held.

It fails unless at least one reward record had data to compare.
