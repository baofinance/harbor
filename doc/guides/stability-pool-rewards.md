# Stability Pool Rewards

How value reaches a stability-pool depositor, and how to read it off-chain.

For what the pools are *for* and how they fit the protocol, see the
[functional specification](../functional-spec.md) — §2.6 (the pools), §5.6 (rebalancing),
§5.7 (harvesting), §5.8 (claiming).

## Overview

Stability pool depositors earn from two sources, which behave differently:

| | Liquidation rewards | Harvest rewards |
|---|---|---|
| **Trigger** | `rebalance()` when the collateral ratio is below the threshold | `harvest()` when yield has accrued |
| **Arrives** | Immediately, in one step | Streamed, vesting linearly over 7 days |
| **Token received** | Wrapped collateral, or leveraged tokens | Wrapped collateral |
| **Who triggers** | Anyone (keepers, arbitrageurs) | Anyone (keepers) |
| **Priced at** | Maximum of the oracle band, zero fee | n/a — a transfer of accrued yield |

## Two types of stability pool

Both accept the **same deposit asset** — anchor (ha) tokens — and both raise the collateral ratio by
reducing anchor supply. They differ only in the payout:

### Collateral stability pool
- Deposit: **ha tokens** (anchor tokens)
- Liquidation payout: **wrapped collateral** (e.g. wstETH)
- Collateral leaves the system

### Leveraged stability pool
- Deposit: **ha tokens** (anchor tokens)
- Liquidation payout: **hs tokens** (leveraged/sail tokens)
- Collateral stays in the system as sail-token backing, so a smaller liquidation achieves the same
  ratio improvement

## Liquidation rewards

When the collateral ratio drops below the rebalance threshold (e.g. 1.3×), anyone can call
`rebalance()`. Anchor tokens are taken from the stability pools and redeemed; the proceeds, less a
bounty, are credited to that pool's depositors.

### How a liquidation is sized

The split across the two pools is **fitted, not merely proportional**. It starts proportional to
each pool's anchor holdings, then each leg is constrained by two caps:

| Cap | Meaning | Read via |
|---|---|---|
| **Solvency headroom** | A loss may take a pool only down to its floor, never below | `maxAssetLoss()` |
| **Reward capacity** | The proceeds are credited in one step and must not overflow the pool's reward integral | `maxLiquidationReward()` |

Where a pool's proportional share exceeds its headroom, it is capped there and **the shortfall
slides into the other pool's leg** — each leg still redeemed for its own token. One call therefore
reaches the threshold wherever the pools' combined capacity allows; where it does not, the call
liquidates the combined capacity and a later call continues.

The manager measures what each pool *actually* handed over and drives the redemption and crediting
from those actuals, so a pool is never left backing supply it no longer holds.

### How the payout is priced

```
collateralOut = (peggedTokens * peggedTokenPrice) / collateralPrice
```

Two properties favour the depositor:

- Liquidation reads the **maximum** of the oracle price band — the end most favourable to the pool.
- Liquidation redeems at **zero fee**, unlike an ordinary redemption.

A bounty (a ratio of each leg's proceeds) goes to whoever triggered the rebalance; the remainder is
credited to the pool.

### Net effect

- You receive collateral or sail tokens at a favourable rate — maximum price, no fees.
- Rebalancing improves the system's collateral ratio.
- Your remaining deposit rebases down, but the system backing it is healthier.
- **The risk:** if the system is depegged (collateral ratio < 1), the anchor tokens taken from the
  pool redeem at their depressed share of collateral, so you can receive back less value than you
  deposited. This is the risk the yield pays for.

## Harvest rewards

The wrapped collateral is yield-bearing: its value in underlying terms grows. Anchor tokens are
backed by the *underlying* amount, so that growth is a surplus belonging to no claim in the
accounting identity. `harvest()` moves it to the stability pools. Anyone can call it.

### Harvest flow

```
harvest()
  |
  v
new yield = harvestable - already owed to the pools
  |
  v
split new yield by CURRENT pool holdings -> each pool's own `owed` ledger (gross, pre-skim)
  |
  v
each pool streams its owed up to ONE PERIOD'S reward capacity; the rest stays owed to that pool
  |
  v
bounty + cut taken as exact ratios of the gross ACTUALLY distributed this call
  |
  v
sweep that amount from the Minter; pay bounty, pay cut, deposit the rest to the pools
  |
  v
pool rewards enter a linear vesting schedule (7 days)
```

### The per-pool `owed` ledger

This is the part most worth understanding, and the part a naive reading of the flow gets wrong.

The manager does **not** split the whole harvestable amount on every call. It keeps a **separate
`owed` balance per pool**, and:

- **Only genuinely new yield is allocated by current holdings.** New yield is `harvestable` minus
  what is already owed. Joining a pool therefore does not retroactively earn a share of a backlog.
- **A pool's owed is its own.** Yield deferred past one period's reward capacity stays with the pool
  that earned it and is never re-split to the other pool. A pool that held nothing when a backlog
  accrued never receives any of it.
- **Bounty and cut are taken on value actually distributed**, not on the owed backlog — so a keeper's
  reward always matches the harvestable its call consumed.
- **Every party takes its own floored share.** No party is handed another's rounding shortfall; the
  remainder stays un-owed and is reconsidered on the next call by then-current holdings.
- **If the surplus shrinks** (a fall in the wrapped asset's rate), each pool's owed is written down
  proportionally, so the ledger never claims more than the Minter holds.
- **If no pool holds anything**, the new yield is allocated to the fee receiver instead — there is no
  reward stream to deposit it into.

### Deferral is by design

A deposit is capped at one reward period's capacity. Yield beyond that is **left harvestable**, and
the next harvest drains another chunk once the period has distributed. Recovery is by **waiting**,
not by harvesting more often. Nothing is at risk: the harvestable amount falls by exactly what each
harvest sweeps.

A call where every share floors or defers to zero **reverts** rather than emitting a zero harvest and
sweeping nothing, so the owed ledger is rolled back rather than left mutated.

### Distribution split (example: 100 wstETH actually distributed)

| Portion | Ratio | Destination |
|---|---|---|
| Bounty | 1–10% | Whoever called `harvest()` (a nominated receiver) |
| Cut | 5–20% | Fee receiver / treasury |
| Remainder | the rest | Stability pools, into a 7-day vesting stream |

Both ratios default to 0 and are set together by the owner — they are validated as a **pair**,
because what a pool is streamed is the residual the two leave, so a pair summing above 100% describes
a split that does not exist:

```solidity
stabilityPoolManager.updateHarvestRatios(0.05 ether, 0.1 ether); // 5% bounty, 10% cut
```

### Linear vesting

Harvest rewards are **not immediately claimable**. They vest linearly over the reward period, which
is **1 week**, fixed in the pool's implementation.

```
claimable ≈ (timeElapsed / REWARD_PERIOD_LENGTH) * totalRewards
```

| Time after harvest | Claimable |
|---|---|
| Day 0 | 0% |
| Day 3.5 | 50% |
| Day 7 | 100% |

Liquidation rewards, by contrast, are credited **immediately** — they are accrued in one step, not
streamed.

## Claiming

Rewards accumulate until claimed, and unclaimed accruals are **uncapped**. Claiming is never
required to preserve accrual — a depositor who never claims loses nothing.

```solidity
// everything, all reward tokens
pool.claim();

// selected reward tokens only
pool.claim(tokens);

// a single token, up to a maximum
pool.claim(token, maxAmount);

// forecast, per token
uint256[] memory amounts = pool.claimable(account, tokens);
uint256[] memory taken   = pool.claimed(account, tokens);
```

## Proportional distribution

Your share of rewards is proportional to your share of the pool at the time the reward accrues:

- **your share** = your balance ÷ the pool's reward divisor
- **your reward** = total reward × your share

The divisor is held at or above the summed depositor balances, so credited shares sum to no more
than the reward — rewards conserve by construction, not by tolerance.

## Checking harvestable amounts off-chain

### With cast

```bash
# on the Minter
cast call <MINTER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545

# human-readable
cast call <MINTER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545 | cast --to-unit eth
```

`harvestable()` returns the surplus of the held wrapped collateral over the underlying amount
backing the anchor tokens. It returns 0 if no yield has accrued.

### With TypeScript

```typescript
const MINTER_ABI = [
  "function harvestable() external view returns (uint256 wrappedAmount)",
] as const;

const minter = new Contract(minterAddress, MINTER_ABI, provider);
const harvestable = await minter.harvestable();
```

### Estimating a keeper's bounty

The bounty is a ratio of the gross **actually distributed**, which is not the same as `harvestable()`
whenever a pool's owed exceeds one period's capacity. `harvestable()` is therefore an **upper bound**
on the base, not the base itself:

```typescript
const harvestable = await minter.harvestable();          // upper bound on the distributable gross
const bountyRatio  = await manager.harvestBountyRatio();
const cutRatio     = await manager.harvestCutRatio();

// upper bound only — the actual base is the gross this call distributes
const maxBounty = (harvestable * bountyRatio) / ethers.parseEther("1");
```

To avoid an unprofitable call, pass a `minBounty` to `harvest()` — it reverts rather than paying
less:

```solidity
manager.harvest(bountyReceiver, minBounty);
```
