# The leverage cap: how it works

This describes `Minter_v3` and `StabilityPoolManager_v2` as they stand. What they replace, and why, is in
[leverage-cap-before.md](leverage-cap-before.md).

## The cap is a floor on the collateral ratio

A sail token is a claim on the residual: the collateral's value less the anchor claim. Its leverage, how many
percent it moves for one percent of the collateral price, is

$$\text{leverage ratio} = \frac{CR}{CR - 1}$$

where $CR$ is the collateral ratio. The minter will not mint sail above a leverage of `MAX_LEVERAGE_RATIO` = 20.
Leverage of 20 is a collateral ratio of 20/19, so the cap is a floor on the ratio:

$$\text{MINIMUM\_COLLATERAL\_RATIO} = \frac{K}{K-1} = \frac{20}{19} \approx 1.0526$$

Both are constants on the minter. The floor is derived from the cap, so changing the cap moves the floor with it.
It is rounded up to the collateral ratio's 18 decimal places, so a market standing exactly at the floor is sold
leverage of the cap or a hair under it, never over.

### Choosing the cap

The cap is 20 today and is expected to be raised. The higher the cap, the closer the floor sits to the peg:

| cap `K` | floor `K/(K-1)` |
|---|---|
| 20 | 1.0526 |
| 100 | 1.0101 |
| 500 | 1.0020 |

The floor has to sit well below the rebalance threshold, or the market spends its whole rebalance range unable to
mint sail. A market with a threshold of 1.05 shows it. With a cap of 20 its floor, 1.0526, is ABOVE the
threshold: sail cannot be minted anywhere a rebalance is offered, a rebalance never pays the sail pool in sail,
and nobody can buy sail to recapitalise the market as it approaches the threshold. With a cap of 100 sail can be
minted down to 1.0101, most of the way from the threshold to the peg; with 500, to 1.0020.

| collateral ratio | leverage ratio | with a cap of 20 |
|---|---|---|
| 1.3 | 4.3 | healthy, a typical rebalance threshold |
| 1.1 | 11 | stressed |
| 1.0526 | 20 | the floor |
| 1.02 | 51 | between the peg and the floor: no sail mints |
| 1.01 | 101 | the same; the floor for a cap of 100 |
| 1.002 | 501 | the same; the floor for a cap of 500 |
| 1.0 or below | a claim on nothing | at or below the peg: no sail mints, no rebalance |

## What is capped, and what is not

The cap limits one thing: **minting sail**. Everything else is uncapped.

- **Redeeming sail is never capped.** A holder can always leave, at any leverage, subject only to the redeem
  fee bands and to there being a residual to pay out. The cap stops anyone ENTERING at a leverage above it; it
  never traps anyone already in. Below the floor there is little reason to redeem - it sells the position at
  its most leveraged, giving up the market's recovery - but the choice is always the holder's.
- **The leverage reported is not capped.** `leverageRatio()` reports what a holder carries now, $CR/(CR-1)$,
  however high. When the residual is gone it reports `type(uint256).max`. A price fall can take holders'
  leverage past the cap; the cap only stops anyone buying in at that leverage.

## Minting sail

Every route that mints sail reverts `BelowMinimumCollateralRatio(ratio, floor)` where the market stands below
the floor before the trade:

- `mintLeveragedToken`, the fee-paying mint;
- the conversion leg of `freeRedeemPeggedToken`, which mints sail for a stability pool's anchor;
- `freeMintLeveragedToken`, the zero-fee mint, wherever sail tokens exist.

A sail mint is judged on the market it starts from because that is the price it is sold at: below the floor the
residual is so small that a small error in the collateral price is a large error in the sail price, and a mint
priced there hands its buyer a very large count of tokens at the existing holders' expense. A mint only ever
raises the ratio, so judging it on the market it leaves would guard nothing.

The ratio is judged at the middle of the oracle's price band, the same figure `collateralRatio()` reports.
`leveragedMintable()` answers the question in advance, and a front end should read it rather than compare
`leverageRatio()` against the cap itself: the floor is `K/(K-1)` rounded up, so the two comparisons can differ by
a wei.

One mint is judged on the market it leaves instead: the zero-fee mint of a market's FIRST sail tokens. No sail
holder exists to be diluted and there is no sail price to get wrong, and a genesis needs it: its own anchor mint
leaves a new market exactly at the peg, below the floor, and its sail mint then lifts the market to about two.
That mint reverts where it would leave the market below the floor.

A later genesis on a live market is a sail mint like any other. At or above the floor it is served at the price
before the trade. Below the floor, with sail tokens outstanding, it reverts and waits: for the price, for anchor
redemptions, or for a donation the owner chooses to make. Nobody is sold sail below the floor, and nobody is made
to pay more than its price to enter.

The dry runs agree with the calls. Below the floor `mintLeveragedTokenDryRun` reports nothing minted: every
amount zero, with the incentive ratio of the band the market is in. `freeRedeemDryRun`, asked for a conversion
there, reports zero on both legs, because the call refuses the whole redeem; asked only for collateral, it is not
judged, and neither is the call. So no forecast shows a trade that will revert.

The first sail token of a market is judged like every other. It buys the whole residual the backing holds after
its deposit - the collateral at the price, less the whole anchor claim - so from at or below the peg the deposit
first makes the anchor holders whole.

## Minting anchor, and donating

The floor closes the market to retail anchor mints as well, in code, whatever the incentive config allows. A
retail anchor mint lowers the ratio, so from at or below the floor it reverts `BelowMinimumCollateralRatio`, and
one that would cross the floor is cut where the ratio reaches it, the rest of the offer left with the caller.
The fee-capped mint reports nothing taken instead of reverting. The zero-fee anchor mint is not judged.

A market with no collateral and no anchor reads a ratio of exactly one, so no retail mint can open it: that is a
genesis's job. `donateWrappedCollateral` is for the owner, the zero-fee role and the donor role only, because a
donation moves the ratio - an empty market's from one to infinity.

Minting reopens by itself once the ratio is back above the floor: through a price rise, through anchor
redemptions, or through a rebalance, whose first step stops exactly at the floor.

## Rebalancing

A rebalance takes the stability pools' anchor to lift the collateral ratio back to the rebalance threshold.
What it can do depends on where the ratio stands.

**At or below the peg, no rebalance.** There, an anchor token redeemed for collateral takes its share of the
backing with it, so no amount redeemed moves the ratio. `rebalanceable()` is false, and `rebalance()` reverts
`CollateralRatioNotAbovePeg(ratio)`. The pools keep their anchor for when the price brings the market back
above the peg, where it can repair something.

**Between the peg and the floor, everything goes to collateral.** The sail pool cannot be paid in sail, because
the minter will not mint it. So both pools give up anchor by the collateral route, pro rata to what each holds
and within each pool's headroom, until the ratio reaches the floor, or the threshold if that is lower. Both pools
are paid in collateral, in proportion to the anchor each gave up.

**From the floor to the threshold, both legs.** The collateral pool's anchor is redeemed for collateral and the
sail pool's is converted into sail at the residual's price. A rebalance that starts below the floor does this
second step in the same call, once the first has reached the floor.

| where the ratio starts | collateral pool paid in | sail pool paid in |
|---|---|---|
| at or below the peg | refused | refused |
| peg to floor | collateral | collateral |
| floor to threshold | collateral | sail |

In every step the keeper's bounty is its ratio of each payment, in the token that payment is made in, and the
keeper's `minPeggedLiquidated` is judged against both steps together. A pool whose share exceeds its headroom
gives up what it can and the other pool takes the rest in the same call. Pools too small to reach the target
lift the ratio as far as their headroom goes, and a later rebalance continues.

## Pricing inside a rebalance

The rebalance is sized and paid at the middle of the oracle's price band, the price the collateral ratio is
reported at. Sizing and payout at one price means a rebalance lands on its target as `collateralRatio()`
measures it, and the second step is never stranded by a spread. The sized amount is rounded up, with one wei of
backing allowed for, so rounding cannot leave the ratio a hair below the floor either.
