# The leverage cap: what was wrong before

This describes the rule deployed today, `Minter_v2` with `StabilityPoolManager_v1`, and the faults found on the
way to its replacement. How the replacement works is in [leverage-cap.md](leverage-cap.md).

## The old rule: a cap on the count, not a floor on the ratio

The old minter capped the leverage it *reported* at 20 and used the same figure to price the conversion a
rebalance makes: below a collateral ratio of about 1.0526, where true leverage passes 20, the sail pool was
minted a flat 20 sail per unit of value of anchor it gave up, whatever that sail was worth. Retail sail mints
were not capped at all.

## What went wrong

**1. Rebalances robbed the sail pool.** Near the peg sail is worth little, so a flat count of it was worth far
less than the anchor taken for it. Measured, per unit of value given up:

| collateral ratio | the sail pool received | a retail minter received |
|---|---|---|
| 1.01 | 0.204 | 1.000 |
| 1.0 or below | 0 (the sail was worthless) | - |

The value the pool lost went to whoever held sail at the moment of the rebalance.

**2. Anyone could mint sail in the band, uncapped, and take that value.** Retail sail mints were served at a
fair price below the floor, at leverage far above 20. Mint just before a keeper's rebalance, redeem just after,
and the pool's loss becomes the minter's gain. Measured, value back per unit put in:

| collateral ratio | back per unit in |
|---|---|
| 1.0003 | 19.91 |
| 1.01 | 3.73 |
| 1.02 | 2.10 |
| 1.05 and above | 1.00 |

Anyone watching the keeper could front-run a rebalance for 3.7 times their stake at a ratio of 1.01.

**3. The report hid the risk.** `leverageRatio()` stopped at 20, so the leverage sail holders actually carried
near the peg, 51 at 1.02 and unbounded at the peg, was reported as 20 exactly when it mattered most.

**4. Rebalances below the peg spent the pools badly.** Below the peg an anchor token redeemed for collateral
takes its share of the backing, so the collateral route emptied the collateral pool at an unchanged ratio. The
conversion route did lift the ratio, but entirely at the sail pool's expense: it was paid in sail worth nothing.
Either way the pools spent the anchor that could have repaired the market once the price recovered.

**5. Rebalances were sized at one price and judged at another.** The rebalance fired when the collateral ratio,
read at the middle of the oracle's price band, fell below the threshold, but was sized at the band's top. With
any spread it stopped short of the threshold; the market still read as rebalanceable, and every later call was
sized at zero and did nothing until the price moved.

**6. The pools were charged the spread.** A rebalance paid the pools at the band's top price, the edge that
pays least, although the pools are forced to trade and do not choose to.

**7. The sized amount could fall a wei short.** The amount was rounded down, and where the held collateral
decides the backing, its valuation can round one wei further. Harmless at the threshold, but once the floor
became a target, a rebalance one wei short of it could not take its second step.

## During the redesign

Two intermediate states were found and not shipped:

- **Refusing the whole rebalance below the floor.** A rebalance prices both legs on the state before the trade,
  so with the conversion refused below the floor, the whole call reverted and the collateral leg never ran.
  Hence the two steps in one call.
- **The escrow candidate**, which held back part of the backing for sail holders instead of capping the mint.
  It removed the windfall but cost a minter 86.5% below a ratio of 0.57 and diluted holders by 14.1% across a
  rebalance.
