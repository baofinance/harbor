# Holder stories — the rebalance dilution exploits of 2026-10-16

One story per wallet that the exploits changed or that acted afterwards, across both exploited markets, with the
treatment decided for each on 2026-10-28: phase 1 of the repayment rides the markets' v3 upgrade, in each market's own
unpause batch ([How the repayment is made](#how-the-repayment-is-made)). Each wallet is taken to be its own person.

Written against the generated holders files, [BTC-stETH-holders.md](BTC-stETH-holders.md) and
[EUR-stETH-holders.md](EUR-stETH-holders.md), which follow every holder up to block 26,248,724, where the minters and the
pools were paused, and against the accounts files. Figures here are rounded to show their size. The exact ones are in
those files.

## How to read a story

Each story gives a wallet's token counts just before the exploit's transaction and just after it. It then splits the
change in their value into two parts:
- **from the count:** the change in the number of tokens, at the price after the exploit;
- **from the price:** the number of tokens held before, times the change in price.

Only the leveraged tokens changed price, so only they have a part from the price. A wallet whose token counts did not
change, and still lost value, lost it all through the leveraged price. Values are in the market's pegged unit (BTC or
EUR), with wstETH in brackets for totals. Each pegged token is worth exactly one pegged unit.

**Since** means from the exploit to the pause. Nothing happened in either market after the managers were paused on
2026-10-21.

## The mechanisms

Every change the exploits made to a holder came through one of these. Each wallet's table below names the mechanism
of each of its rows, and the totals per market are here.

- **Wallet price fall — the leveraged price's fall on leveraged tokens held in a wallet.** The count did not change;
  the value fell by the count times the fall in the price. Nine-tenths of the loss.
- **Unclaimed price fall — the same fall on leveraged tokens held for a wallet elsewhere:** the genesis contract's
  unclaimed claims, and a leveraged reward already in the pool before the exploit (`0x619e71ec…` in EUR::stETH).
- **Leveraged deposit taken — the pegged deposit the capped rebalance took from the leveraged pool.** A count loss, at
  one pegged unit each.
- **Leveraged reward overpaid — the leveraged tokens the capped rebalance paid the leveraged pool for that deposit,**
  20 a pegged token, at the price after. It outweighs the deposit taken: the capped rebalance overpaid the pool, and
  the overpayment is the leveraged pool depositors' gain. Netted per wallet, it is what the cut takes back.
- **Collateral deposit taken — the pegged deposit the rebalance took from the collateral pool,** a count loss at one
  pegged unit each, and **collateral wstETH received — the wstETH the collateral pool received for it,** at the fair
  rate less the rebalance bounty. The two nearly cancel: the difference is the depositor's share of the bounty.
- **Fees — the fees to the multisig:** minting, redemption and early-withdrawal fees, in wstETH and in pegged tokens.
- **Exploits' take:** the wstETH paid to the accounts the callers named.

| Mechanism | BTC::stETH | EUR::stETH |
|---|---|---|
| Wallet price fall | −0.4356 BTC (−11.73 wstETH) | −6,247 EUR (−2.298 wstETH) |
| Unclaimed price fall | −0.0027 BTC (−0.074 wstETH) | −2,108 EUR (−0.775 wstETH) |
| Leveraged deposit taken | −0.0505 BTC (−1.359 wstETH) | −585.4 EUR (−0.215 wstETH) |
| Leveraged reward overpaid | +0.0651 BTC (+1.753 wstETH) | +715.9 EUR (+0.263 wstETH) |
| Collateral deposit taken | −0.0502 BTC (−1.350 wstETH) | −585.4 EUR (−0.215 wstETH) |
| Collateral wstETH received | +0.0496 BTC (+1.337 wstETH) | +579.5 EUR (+0.213 wstETH) |
| Fees | +0.1856 BTC (+4.997 wstETH) | +4,275 EUR (+1.573 wstETH) |
| Exploits' take | +0.2386 BTC (+6.425 wstETH) | +3,955 EUR (+1.455 wstETH) |

Each column sums to zero, to rounding; summed from the accounts files, row by row. The two price falls together are
the "through the leveraged price" line of the table under [In short](#in-short); the deposits taken, the reward
overpaid and the wstETH received together are its "through changes in their token counts" line.

## The prices

| | Before the exploit | After it | At the pause |
|---|---|---|---|
| 1 hsSTETH-BTC, in BTC | 0.7117 | 0.06516 (−90.8%) | 0.06051 |
| 1 hsSTETH-BTC, in wstETH | 19.16 | 1.755 | 1.652 |
| 1 wstETH, in BTC | 0.03714 | 0.03714 | 0.03663 |
| 1 hsSTETH-EUR, in EUR | 0.8380 | 0.06177 (−92.6%) | 0.05803 |
| 1 hsSTETH-EUR, in wstETH | 0.0003083 | 0.00002272 | 0.00002160 |
| 1 wstETH, in EUR | 2,719 | 2,719 | 2,686 |

haBTC and haEUR stayed at one pegged unit. The leveraged price fell because the capped rebalance minted 20 leveraged
tokens for each pegged token it took from the leveraged pool, far above the fair rate. The exploits then redeemed those
tokens for collateral.

## In short

| | BTC::stETH | EUR::stETH |
|---|---|---|
| Holders, through the leveraged price | −0.4384 BTC | −8,355 EUR |
| Holders, through changes in their token counts | +0.0141 BTC | +125 EUR |
| **Holders, in all** | **−0.4242 BTC (−11.42 wstETH)** | **−8,230 EUR (−3.03 wstETH)** |
| The multisig, in fees | +0.1856 BTC (+5.00 wstETH) | +4,275 EUR (+1.57 wstETH) |
| The accounts the exploits paid | +0.2386 BTC (+6.43 wstETH) | +3,955 EUR (+1.45 wstETH) |

Each column sums to zero, to rounding.

- **The loss is the leveraged price's fall.** Holders lost value on tokens whose count did not change: in their
  wallets, in the genesis contract and in their pool rewards. Changes in counts left them slightly ahead, because the
  capped rebalance overpaid the leveraged pool.
- **17 wallets lost; 2 gained.** One wallet, `0x619e71ec…`, lost 13.31 of the 14.55 wstETH lost in all. The 2 gainers
  are leveraged pool depositors whose overpaid reward outweighed their loss on the price. Together they gained
  0.0038 BTC (0.10 wstETH).
- **Nobody bought into either market after the exploits.** There was no mint at all. The leveraged supply grew only
  through the rebalances that followed (16 on BTC::stETH, 5 on EUR::stETH), each at the fair rate.
- **Nobody sold a leveraged token they held through the exploit.** One gainer redeemed the reward the exploit overpaid
  it.

## The rule

Decided 2026-10-28. The exact figures it produces per wallet are generated into
[BTC-stETH-compensation.json](BTC-stETH-compensation.json) and [EUR-stETH-compensation.json](EUR-stETH-compensation.json),
and shown in each holders file's "Compensation inputs" section.

- **A wallet is owed, or owes, the exploit's change.** That is the change in value of all its positions across the
  exploit's transaction, netted, at that block's prices. The mechanisms above explain the change; they do not alter
  it. Undoing it row by row is impossible where a wallet has acted since - one gainer redeemed most of its overpaid
  reward, the largest loser claimed its - so the net is the one amount that can be charged to every wallet alike.
- **The amount follows the wallet, not its tokens.** What a wallet did afterwards does not change what it is owed.
- **Later price moves are not counted.** The exploit's transaction is the whole of the harm the rule measures.
- **A gain is taken back where it still sits:** from the wallet's unclaimed leveraged reward in the pool, up to the
  reward's value - the cut. The cut is added to what the wallet is owed, so it is charged exactly its gain.
- **Phase 1 pays each debt the same fraction:** the fund - the multisig's fees from the exploits and the cuts, all
  redeemed into wstETH - over every debt of both markets, about 46%. The rest is phase 2, to be settled.

## Wallets that lost

### `0x619e71ec…10E3` — both markets, owed 0.391 BTC and 7,601 EUR of value (13.31 wstETH)

The largest holder in both markets, with nine-tenths of the loss.

**BTC::stETH**, net −0.3906 BTC (−10.52 wstETH):

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | wallet price fall | 0.6189 | 0.6189 | none | | −0.4002 BTC |
| haBTC in the leveraged pool | leveraged deposit taken | 0.2083 | 0.1741 | −0.0342 | −0.0342 BTC | |
| hsSTETH-BTC reward, leveraged pool | leveraged reward overpaid | 0 | 0.6768 | +0.6768 | +0.0441 BTC | |
| wstETH reward, leveraged pool | | 0.1476 | 0.1476 | none | | |
| haBTC in the collateral pool | collateral deposit taken | 0.2035 | 0.1701 | −0.0334 | −0.0334 BTC | |
| wstETH reward, collateral pool | collateral wstETH received | 0.1459 | 1.036 | +0.8902 | +0.0331 BTC | |

- **Its wallet's 0.6189 hsSTETH-BTC kept their count and lost 0.4002 BTC through the price.**
- **The leveraged pool overpaid it.** The capped rebalance took 0.0342 haBTC of its deposit and paid 0.6768 hsSTETH-BTC,
  worth 0.0441 BTC at the new price: 0.0099 BTC more than it gave.
- **The collateral pool gave 0.0334 haBTC for 0.8902 wstETH,** worth 0.0331 BTC: its share of the rebalance bounty.

**EUR::stETH**, net −7,601 EUR (−2.80 wstETH):

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| hsSTETH-EUR in its wallet | wallet price fall | 7,238 | 7,238 | none | | −5,619 EUR |
| haEUR in the leveraged pool | leveraged deposit taken | 2,987 | 2,402 | −585.4 | −585.4 EUR | |
| hsSTETH-EUR reward, leveraged pool | leveraged reward overpaid, unclaimed price fall | 2,715 | 14,306 | +11,591 | +715.9 EUR | −2,107 EUR |
| wstETH reward, leveraged pool | | 0.0616 | 0.0616 | none | | |
| haEUR in the collateral pool | collateral deposit taken | 2,987 | 2,402 | −585.4 | −585.4 EUR | |
| wstETH reward, collateral pool | collateral wstETH received | 0.5362 | 0.7493 | +0.2132 | +579.5 EUR | |

- **The price took 7,726 EUR:** 5,619 EUR on its wallet's 7,238 hsSTETH-EUR, and 2,107 EUR on the 2,715 hsSTETH-EUR of
  reward it already had.
- **The counts gave it 125 EUR net.** The rebalance paid 11,591 hsSTETH-EUR, worth 715.9 EUR, for 585.4 haEUR. The
  collateral pool returned 579.5 EUR of wstETH for its 585.4 haEUR.

**Since.**
- **More of its deposits were converted.** The later rebalances, at the fair rate, took its leveraged pool deposits down
  to 0.1384 haBTC and 1,759 haEUR, and its collateral pool deposits to 0.1352 haBTC and 1,759 haEUR.
- **It claimed every reward in both markets on 2026-10-20:**
  - BTC::stETH: 1.239 hsSTETH-BTC and 2.123 wstETH;
  - EUR::stETH: 24,979 hsSTETH-EUR and 1.047 wstETH.
- **It redeemed nothing.**
- **At the pause** it holds 1.858 hsSTETH-BTC (84% of the supply) and 32,217 hsSTETH-EUR (97% of the supply) in its
  wallet.

**Treatment:** owed 13.31 wstETH, which already nets the leveraged pool's overpayment it has since claimed (the
leveraged reward overpaid against the leveraged deposit taken). Phase 1 mints leveraged tokens fee-free into its
wallet, in each market's unpause batch, for the fund's fraction
of its debt in that market, at the capture block's price; the rest is phase 2. The exact figures are in
[phase1.md](phase1.md).

### `0xb9ab9578…0E7F` — both markets, owed 0.0104 BTC and 359 EUR of value (0.41 wstETH)

**BTC::stETH**, net −0.01037 BTC (−0.279 wstETH):

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | wallet price fall | 0.01722 | 0.01722 | none | | −0.01113 BTC |
| haBTC in the leveraged pool | leveraged deposit taken | 0.01751 | 0.01463 | −0.00287 | −0.00287 BTC | |
| hsSTETH-BTC reward, leveraged pool | leveraged reward overpaid | 0 | 0.05688 | +0.05688 | +0.00371 BTC | |
| haBTC in the collateral pool | collateral deposit taken | 0.04133 | 0.03454 | −0.00678 | −0.00678 BTC | |
| wstETH reward, collateral pool | collateral wstETH received | 0.00505 | 0.1858 | +0.1808 | +0.00671 BTC | |

**EUR::stETH**, net −358.7 EUR (−0.132 wstETH): 462.1 hsSTETH-EUR in its wallet, count unchanged, all lost through the
price (wallet price fall).

**Since:** nothing. Its BTC::stETH rewards are still unclaimed: 0.1041 hsSTETH-BTC, 0.0569 of it from the exploit, and
0.379 wstETH.

**Treatment:** its leveraged pool's gain in BTC::stETH, 0.0225 wstETH (leveraged reward overpaid less leveraged deposit taken), is taken from its unclaimed
hsSTETH-BTC reward as the pool is migrated, and added to what it is owed: 0.3016 wstETH in BTC::stETH and 0.1320 in
EUR::stETH, so that it is charged exactly its gain. Phase 1 mints leveraged tokens fee-free into its wallet, in each
market's unpause batch, for the fund's fraction of each debt; the rest is phase 2. The exact figures are in
[phase1.md](phase1.md).

### `0xEE517179…F775` — BTC::stETH, owed 0.0112 BTC of value (0.30 wstETH)

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | wallet price fall | 0.0172 | 0.0172 | none | | −0.01112 BTC |
| haBTC in the collateral pool | collateral deposit taken | 0.0172 | 0.01437 | −0.00282 | −0.00282 BTC | |
| wstETH reward, collateral pool | collateral wstETH received | 0.02642 | 0.1016 | +0.07522 | +0.00279 BTC | |

The loss is the price's, on its wallet's tokens. Nothing since. **Treatment:** owed 0.30 wstETH; phase 1 mints
leveraged tokens fee-free into its wallet for the fund's fraction of it, the rest in phase 2 ([phase1.md](phase1.md)).

### `0xE8100351…9135` and `0xecfFe7b0…dCED` — BTC::stETH, owed 0.0028 and 0.0022 BTC of value (0.075 and 0.060 wstETH)

The same shape as `0xEE517179…`, smaller:
- `0xE8100351…`: 0.004299 hsSTETH-BTC in its wallet, count unchanged, −0.00278 BTC through the price (wallet price fall). Its
  collateral pool gave 0.000705 haBTC for 0.0188 wstETH (0.000698 BTC; collateral deposit taken and wstETH received).
- `0xecfFe7b0…`: 0.003439 hsSTETH-BTC, −0.00222 BTC through the price (wallet price fall). Its collateral pool gave 0.000564 haBTC for
  0.01504 wstETH (0.000559 BTC; collateral deposit taken and wstETH received).

Nothing since. **Treatment:** owed 0.075 and 0.060 wstETH; phase 1 mints leveraged tokens fee-free into each wallet
for the fund's fraction, the rest in phase 2 ([phase1.md](phase1.md)).

### `0x1a915252…6913` — BTC::stETH, owed 0.0072 BTC of value (0.19 wstETH)

0.01117 hsSTETH-BTC in its wallet, count unchanged, −0.00722 BTC through the price (wallet price fall). Nothing since. **Treatment:**
owed 0.19 wstETH; phase 1 mints leveraged tokens fee-free into its wallet for the fund's fraction, the rest in phase 2
([phase1.md](phase1.md)).

### `0xf7e9CAaa…31B2` — EUR::stETH, owed 248 EUR of value (0.091 wstETH)

318.9 hsSTETH-EUR in its wallet, count unchanged, −247.6 EUR through the price (wallet price fall). Nothing since. **Treatment:** owed
0.091 wstETH; phase 1 mints leveraged tokens fee-free into its wallet for the fund's fraction, the rest in phase 2
([phase1.md](phase1.md)).

### The genesis participants who never claimed — owed 0.0027 BTC and 0.78 EUR of value (0.074 wstETH)

The genesis contract holds their tokens: each claim is the same number of haBTC as of hsSTETH-BTC, and of haEUR as of
hsSTETH-EUR. Each claim's token counts were fixed when genesis ended. **They lost no tokens.** Their pegged tokens kept their value.
**Their whole loss is the leveraged price's fall** on the leveraged tokens they are owed (unclaimed price fall):

| Participant | Market | Claim, each token | Value from the price |
|---|---|---|---|
| `0xBA188C41…bEB7` | BTC::stETH | 0.002921 | −0.001889 BTC (−0.051 wstETH) |
| `0x787A7dA1…e83f` | BTC::stETH | 0.001169 | −0.000756 BTC (−0.020 wstETH) |
| `0x33abAf6F…48B0` | BTC::stETH | 0.0001374 | −0.0000889 BTC (−0.0024 wstETH) |
| `0x2f75E925…454f` | EUR::stETH | 0.9998 | −0.776 EUR (−0.0003 wstETH) |

None has claimed since. **Treatment:** each is paid directly - tokens sent to the genesis contract would never reach
them. Phase 1 mints leveraged tokens fee-free into each wallet for the fund's fraction of its loss, the rest in phase
2 ([phase1.md](phase1.md)).

### Small losses — owed under 0.001 BTC or 12 EUR of value each

Each held leveraged tokens in its wallet through the exploit, with the count unchanged, and lost through the price
(wallet price fall). None has done anything since.
- `0x061B84FD…35aa`, BTC::stETH: 0.001376 hsSTETH-BTC, −0.000889 BTC (−0.024 wstETH).
- `0x000000000000dEaa…83EB`, EUR::stETH: 15.01 hsSTETH-EUR, −11.66 EUR (−0.0043 wstETH).
- `0x3dE6aAAC…dDE8`, EUR::stETH: 12.41 hsSTETH-EUR, −9.63 EUR (−0.0035 wstETH). A contract with no standard
  interface, treated as one holder.
- `0xAE7Dbb17…c31e`, both markets: 0.0000712 hsSTETH-BTC and 0.3368 hsSTETH-EUR, −0.000046 BTC and −0.26 EUR
  (−0.0013 wstETH).
- `0xDD0CDF8D…9C9a`, BTC::stETH: 0.0000344 hsSTETH-BTC, −0.0000222 BTC (−0.0006 wstETH).
- `0xA0DD6477…534E`, BTC::stETH, a Safe in the collateral pool only, with no leveraged tokens: the pool gave 0.000861
  haBTC for 0.02294 wstETH (0.000852 BTC), −0.0000086 BTC (−0.0002 wstETH). That is its share of the rebalance bounty
  (collateral deposit taken and wstETH received).

**Treatment:** each is paid, however small: phase 1 mints leveraged tokens fee-free into every wallet with a debt, for
the fund's fraction of it, with no floor; the rest in phase 2 ([phase1.md](phase1.md)).

## Wallets that gained

### `0x0e4d5032…4869` — BTC::stETH leveraged pool, owes 0.0027 BTC of value (0.074 wstETH)

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| haBTC in the leveraged pool | leveraged deposit taken | 0.05764 | 0.04818 | −0.00946 | −0.00946 BTC | |
| hsSTETH-BTC reward, leveraged pool | leveraged reward overpaid | 0 | 0.1873 | +0.1873 | +0.0122 BTC | |

It held no leveraged tokens, so the price took nothing from it. The capped rebalance took 0.00946 haBTC and paid 0.1873
hsSTETH-BTC, worth 0.0122 BTC at the new price: a gain of 0.0027 BTC (leveraged reward overpaid less leveraged deposit taken).

**Since.**
- On 2026-10-18 it claimed 0.2867 hsSTETH-BTC: the exploit's 0.1873 and 0.0994 from later rebalances.
- Three minutes later it redeemed them for 0.4752 wstETH, which is 0.0609 BTC a token when the minter's price was
  0.0617 BTC.
- At the pause it still has 0.0383 haBTC deposited and 0.0561 hsSTETH-BTC to claim.

**Treatment:** its whole gain, 0.0739 wstETH, is taken from the 0.0561 hsSTETH-BTC it still has to claim - worth
0.0927 wstETH at the pause - as the pool is migrated in the unpause batch, paid to the multisig and redeemed into the
fund. It is owed nothing.

### `0x13F210c8…AF12` — BTC::stETH, both pools, owes 0.0011 BTC of value (0.029 wstETH)

| Position | Mechanism | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|---|
| haBTC in the leveraged pool | leveraged deposit taken | 0.02399 | 0.02006 | −0.00394 | −0.00394 BTC | |
| hsSTETH-BTC reward, leveraged pool | leveraged reward overpaid | 0 | 0.07796 | +0.07796 | +0.00508 BTC | |
| haBTC in the collateral pool | collateral deposit taken | 0.0306 | 0.02558 | −0.00502 | −0.00502 BTC | |
| wstETH reward, collateral pool | collateral wstETH received | 0.02546 | 0.1593 | +0.1339 | +0.00497 BTC | |

No leveraged tokens before, so no loss through the price. Its leveraged pool gained 0.00114 BTC on the counts (the
leveraged reward overpaid less the leveraged deposit taken). Its collateral pool was about even (collateral deposit
taken and wstETH received). Nothing since. Its 0.1427 hsSTETH-BTC of reward is still unclaimed, 0.0780 of it from the
exploit.

**Treatment:** its leveraged pool's gain, 0.0308 wstETH, is taken from the 0.1427 hsSTETH-BTC it still has to claim -
worth 0.2357 wstETH at the pause - as the pool is migrated in the unpause batch, paid to the multisig and redeemed
into the fund. Its collateral pool's share of the bounty, 0.0014 wstETH, is then owed to it like any loss, and phase 1
mints leveraged tokens fee-free into its wallet for the fund's fraction of it ([phase1.md](phase1.md)).

## The multisig `0x9bABfC1A…64a2` — fees of 0.186 BTC and 4,275 EUR of value (6.57 wstETH)

It is the fee receiver of every market. All counts, no price: the fees mechanism, whole.
- **BTC::stETH:** +3.003 wstETH (0.1115 BTC) and +0.07405 haBTC, in minting, redemption and early-withdrawal fees.
- **EUR::stETH:** +0.9899 wstETH (2,691 EUR) and +1,584 haEUR.

Which operation paid which fee is under [How each exploit made its take](#how-each-exploit-made-its-take-operation-by-operation).
It still holds the haBTC and haEUR at the pause. Its wstETH is not followed after the exploit.

**Treatment:** the fees are the fund of phase 1. In each market's unpause batch the multisig redeems its pegged fee
fee-free for wstETH, at the capture block's price, and mints leveraged tokens fee-free for every wallet that lost with
that wstETH, its wstETH fees and what the cuts redeem for. It must hold them when the batch executes.

## The accounts the exploits paid — 0.239 BTC and 3,955 EUR of value (7.88 wstETH)

The exploits' take, whole:
- `0x61F31C7B…A880`, BTC::stETH: 6.425 wstETH. Not moved, as traced on 2026-10-22.
- `0x0A678044…66F2`, EUR::stETH: 1.455 wstETH, swapped for 1.813 ETH on 2026-10-16.

Nothing is recovered from them in phase 1. What they took is the size of phase 2.

**Proposed treatment:** none through the contracts. Recovering this is a matter outside them.

## How each exploit made its take, operation by operation

Each exploit was one transaction by a contract made for it, on a flash loan of wstETH. The exact figures of every step
are in the figures files, under "What the transaction did" and "The caller's gain, flow by flow"; here they are rounded,
in wstETH, and sorted by what each operation did to the caller's take and to the multisig's fees.

**The take came from one operation: the rebalance.** The caller had deposited nearly all of the leveraged pool, so it
received nearly all of what the rebalance paid that pool - 20 leveraged tokens for each pegged token taken, where a
pegged token had been worth about 1.4 (BTC) or 1.2 (EUR) of them before the transaction. Everything else in the
transaction either set that up or paid for it: the
mints and redemptions pushed the collateral ratio down to where a rebalance could be called, and each of them paid a
fee to the multisig. The price part of the holders' loss is this same operation seen from the other side: the tokens
minted at 20 per pegged diluted every leveraged token, and the caller redeemed its new tokens before the dilution
could matter to it.

### BTC::stETH — the caller `0x2b9bE8d7…902D`, paying `0x61F31C7B…A880` 6.43 wstETH

| Operation | Count | The caller's take | The multisig's fee |
|---|---|---|---|
| Minted 5.63 hsSTETH-BTC with 108.5 wstETH | 1 | | +0.530 wstETH |
| Minted 8.95 haBTC with 241.5 wstETH | 4 | | +0.563 wstETH |
| Deposited 8.86 haBTC in the leveraged pool | 1 | | |
| Redeemed 5.61 hsSTETH-BTC for 106.3 wstETH, lowering the collateral ratio to the rebalance threshold | 40 | | +1.155 wstETH |
| Called `rebalance`: the manager took 1.55 haBTC from the pools and minted 30.08 hsSTETH-BTC for them; the leveraged pool gave 1.50 haBTC (worth 40.5) and got 29.78 hsSTETH-BTC | 1 | the pool position: −39.14 for the haBTC taken, +50.50 for the 28.78 hsSTETH-BTC claimed next, at the price after: **+11.36** | |
| The rebalance's bounty, 1% of what it minted and redeemed: 0.0135 wstETH and 0.30 hsSTETH-BTC | 1 | **+0.54** | |
| Its own 0.0275 hsSTETH-BTC left from the redemptions, held through the rebalance's price fall (0.7117 to 0.0652 BTC) | | **−0.48** | |
| Claimed 28.78 hsSTETH-BTC from the leveraged pool and redeemed 29.11 for 50.3 wstETH | 1 + 4 | | +0.755 wstETH |
| Withdrew 7.33 haBTC from the leveraged pool, paying the early-withdrawal fee | 1 | **−1.99** (the fee, in value) | +0.0740 haBTC (1.99 wstETH) |
| Redeemed 7.42 haBTC for 199.8 wstETH | 1 | | none: no fee was due at that collateral ratio |
| Repaid the 350 wstETH loan; paid out the rest | | | |
| **Sum** | | **+6.43** | **5.00** (3.003 wstETH + 0.074 haBTC) |

The mint and redemption fees, 3.00 wstETH, are the caller's fourth flow (**−3.00**): +11.36 + 0.54 − 0.48 − 1.99 − 3.00
= +6.43. Of a gross gain of 11.9, the multisig's fees took 5.0, the price fall on its leftovers 0.5, and 6.4 was paid
out.

### EUR::stETH — the caller `0x3e5604AF…66ba`, paying `0x0A678044…66F2` 1.45 wstETH

| Operation | Count | The caller's take | The multisig's fee |
|---|---|---|---|
| Minted 64,558 hsSTETH-EUR with 20 wstETH | 1 | | +0.100 wstETH |
| Minted 197,013 haEUR with 72.8 wstETH | 6 | | +0.344 wstETH |
| Deposited all 197,013 haEUR in the leveraged pool | 1 | | |
| Redeemed 63,438 hsSTETH-EUR for 19.3 wstETH, lowering the collateral ratio to the rebalance threshold | 10 | | +0.286 wstETH |
| Called `rebalance`: the manager took 39,779 haEUR from the pools and minted 783,877 hsSTETH-EUR for them; the leveraged pool gave 39,194 haEUR (worth 14.4) and got 776,038 hsSTETH-EUR | 1 | the pool position: −14.20 for the haEUR taken, +17.37 for the 764,447 hsSTETH-EUR claimed next, at the price after: **+3.17** | |
| The rebalance's bounty: 0.0022 wstETH and 7,839 hsSTETH-EUR | 1 | **+0.18** | |
| Its own 1,120 hsSTETH-EUR left from the redemptions, held through the price fall (0.8380 to 0.0618 EUR) | | **−0.32** | |
| Claimed 764,447 hsSTETH-EUR from the leveraged pool and redeemed 773,405 for 17.3 wstETH | 1 + 1 | | +0.261 wstETH |
| Withdrew 156,821 haEUR from the leveraged pool, paying the early-withdrawal fee | 1 | **−0.58** (the fee, in value) | +1,584 haEUR (0.58 wstETH) |
| Redeemed 156,821 haEUR for 57.7 wstETH | 1 | | none |
| Repaid the 180 wstETH loan; paid out the rest | | | |
| **Sum** | | **+1.45** | **1.57** (0.990 wstETH + 1,584 haEUR) |

With the mint and redemption fees as the caller's fourth flow (**−0.99**): +3.17 + 0.18 − 0.32 − 0.58 − 0.99 = +1.45. Of a
gross gain of 3.35, the multisig's fees took 1.57, the price fall on its leftovers 0.32, and 1.45 was paid out.

### What this says about the fees

The multisig's 6.57 wstETH of fees are the exploits' own payments: every one of them came out of the callers' gross gain,
none from a holder. Returning them to the holders moves back what the exploits paid for the damage, not what they took:
the 7.88 wstETH paid out is the rest of the holders' loss and sits in the two accounts above.

## Since the exploits: the rebalance bots

Each exploit left its market's collateral ratio below its rebalance threshold. Bots then called the permissionless
`rebalance` and took its bounty, in leveraged tokens, at the price of the moment:
- BTC::stETH: `0xE08D97e1…D015` 8 times, `0x00000F91…0CAc` 5 times, and `0x0000000000be226a…e69D`, `0x4A8DE25c…353f`
  and `0x682eA8AA…2979` once each. `0x0000000000be226a…` passed most of its bounty on to `0x000000000076403c…2343`.
- EUR::stETH: `0xE08D97e1…D015` once (73.3 hsSTETH-EUR), `0x682eA8AA…2979` twice, and `0x00E2E97E…F8FE` and
  `0xBb13d96f…95A0` once each.

Most redeemed their bounty in the same transaction. The rest hold less than a thousandth of a wstETH each in value. The
bounties came out of the pools, at 1% of each rebalance.

**Proposed treatment:** none. They were paid for calls the system invites, at the fair rate.

## Not affected

The pegged-only holders, among them the fxUSD markets' own contracts, which hold haBTC and haEUR, lost nothing. Their
counts did not change, and the pegged price did not move.

## How the repayment is made

Decided 2026-10-28. The code is `script/src/CompensateRebalanceDilution.sol`, mixed into the v3 upgrade script; its
tests are under `script/verify/incidents/`, and the runbook's compensation section is in
[script/verify/v3-upgrade/README.md](../../../script/verify/v3-upgrade/README.md).

- **The balance.** The holders' net loss, 0.4242 BTC and 8,230 EUR of value, equals the fees (0.1856 BTC and 4,275 EUR)
  plus what the exploits paid out (0.2386 BTC and 3,955 EUR). The wallets that lost are owed 14.58 wstETH in all, the
  debts of the two compensation files; the three wallets whose leveraged pool gained give up 0.127 wstETH. The fund of
  phase 1 is the fees and those cuts, about 6.7 wstETH at the capture block's prices: about 46% of every debt. The
  other 7.8 wstETH is what the exploits paid out. **Phase 2** is that remainder; the treasury has nothing to give, so
  its form is to be settled - nothing in the upgrade's batches depends on it, and [phase1.md](phase1.md) states what
  each wallet is still owed.
- **The unit.** The debts are wstETH, valued at the exploit's block. The batch prices every operation at the capture
  block's reading - the last block before the pause - held still for it, so what each wallet receives is fixed when
  the batch is built, whatever the price does before the batch executes.
- **Phase 1 is done in each market's own unpause batch,** the one transaction that moves the market onto v3, so
  nobody acts on the market between its upgrade and its repayment:
  1. the leveraged pool's migration takes each cut from the wallet's unclaimed leveraged reward and pays it to the
     multisig: the gains of `0x0e4d5032…` and `0x13F210c8…`, and `0xb9ab9578…`'s leveraged pool gain, all in BTC::stETH;
  2. the multisig redeems fee-free its pegged fee from the exploit, and the leveraged tokens taken back, for wstETH;
  3. the multisig mints leveraged tokens fee-free into every wallet with a debt, with the fund's fraction of that
     debt in wstETH. Leveraged tokens, because the loss was the leveraged price's fall: minted at the price of the
     moment, they dilute nobody, and they raise the market's collateral ratio where a pegged mint would lower it.
- **Not a donation.** Minter_v3's `donateWrappedCollateral` would raise the leveraged price for every holder in
  proportion to what each holds now: `0x619e71ec…` would get 84% of a BTC::stETH donation and 97% of a EUR::stETH one,
  the bots and every other holder their share, whatever the exploit did to them. The repayment follows the wallet.
