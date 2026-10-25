# Holder stories — the rebalance dilution exploits of 2026-10-16

One story per wallet that the exploits changed or that acted afterwards, across both exploited markets, with a
proposed treatment for each. Each wallet is taken to be its own person.

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

## The proposed rule

This is a proposal for decision. The exact figures it produces per wallet are generated into
[BTC-stETH-compensation.json](BTC-stETH-compensation.json) and [EUR-stETH-compensation.json](EUR-stETH-compensation.json),
and shown in each holders file's "Compensation inputs" section.

- **A wallet is owed, or owes, the exploit's change.** That is the change in value of all its positions across the
  exploit's transaction, netted, at that block's prices.
- **The amount follows the wallet, not its tokens.** What a wallet did afterwards does not change what it is owed.
- **Later price moves are not counted.** The exploit's transaction is the whole of the harm the rule measures.

## Wallets that lost

### `0x619e71ec…10E3` — both markets, owed 0.391 BTC and 7,601 EUR of value (13.31 wstETH)

The largest holder in both markets, with nine-tenths of the loss.

**BTC::stETH**, net −0.3906 BTC (−10.52 wstETH):

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | 0.6189 | 0.6189 | none | | −0.4002 BTC |
| haBTC in the leveraged pool | 0.2083 | 0.1741 | −0.0342 | −0.0342 BTC | |
| hsSTETH-BTC reward, leveraged pool | 0 | 0.6768 | +0.6768 | +0.0441 BTC | |
| wstETH reward, leveraged pool | 0.1476 | 0.1476 | none | | |
| haBTC in the collateral pool | 0.2035 | 0.1701 | −0.0334 | −0.0334 BTC | |
| wstETH reward, collateral pool | 0.1459 | 1.036 | +0.8902 | +0.0331 BTC | |

- **Its wallet's 0.6189 hsSTETH-BTC kept their count and lost 0.4002 BTC through the price.**
- **The leveraged pool overpaid it.** The capped rebalance took 0.0342 haBTC of its deposit and paid 0.6768 hsSTETH-BTC,
  worth 0.0441 BTC at the new price: 0.0099 BTC more than it gave.
- **The collateral pool gave 0.0334 haBTC for 0.8902 wstETH,** worth 0.0331 BTC: its share of the rebalance bounty.

**EUR::stETH**, net −7,601 EUR (−2.80 wstETH):

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| hsSTETH-EUR in its wallet | 7,238 | 7,238 | none | | −5,619 EUR |
| haEUR in the leveraged pool | 2,987 | 2,402 | −585.4 | −585.4 EUR | |
| hsSTETH-EUR reward, leveraged pool | 2,715 | 14,306 | +11,591 | +715.9 EUR | −2,107 EUR |
| wstETH reward, leveraged pool | 0.0616 | 0.0616 | none | | |
| haEUR in the collateral pool | 2,987 | 2,402 | −585.4 | −585.4 EUR | |
| wstETH reward, collateral pool | 0.5362 | 0.7493 | +0.2132 | +579.5 EUR | |

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

**Proposed treatment:** repay 0.391 BTC and 7,601 EUR of value (13.31 wstETH). That already nets the leveraged pool's
overpayment, which it has since claimed.

### `0xb9ab9578…0E7F` — both markets, owed 0.0104 BTC and 359 EUR of value (0.41 wstETH)

**BTC::stETH**, net −0.01037 BTC (−0.279 wstETH):

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | 0.01722 | 0.01722 | none | | −0.01113 BTC |
| haBTC in the leveraged pool | 0.01751 | 0.01463 | −0.00287 | −0.00287 BTC | |
| hsSTETH-BTC reward, leveraged pool | 0 | 0.05688 | +0.05688 | +0.00371 BTC | |
| haBTC in the collateral pool | 0.04133 | 0.03454 | −0.00678 | −0.00678 BTC | |
| wstETH reward, collateral pool | 0.00505 | 0.1858 | +0.1808 | +0.00671 BTC | |

**EUR::stETH**, net −358.7 EUR (−0.132 wstETH): 462.1 hsSTETH-EUR in its wallet, count unchanged, all lost through the
price.

**Since:** nothing. Its BTC::stETH rewards are still unclaimed: 0.1041 hsSTETH-BTC, 0.0569 of it from the exploit, and
0.379 wstETH.

**Proposed treatment:** repay 0.0104 BTC and 359 EUR of value (0.41 wstETH), net of the overpaid reward still in its
account.

### `0xEE517179…F775` — BTC::stETH, owed 0.0112 BTC of value (0.30 wstETH)

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| hsSTETH-BTC in its wallet | 0.0172 | 0.0172 | none | | −0.01112 BTC |
| haBTC in the collateral pool | 0.0172 | 0.01437 | −0.00282 | −0.00282 BTC | |
| wstETH reward, collateral pool | 0.02642 | 0.1016 | +0.07522 | +0.00279 BTC | |

The loss is the price's, on its wallet's tokens. Nothing since. **Proposed treatment:** repay 0.0112 BTC of value (0.30
wstETH).

### `0xE8100351…9135` and `0xecfFe7b0…dCED` — BTC::stETH, owed 0.0028 and 0.0022 BTC of value (0.075 and 0.060 wstETH)

The same shape as `0xEE517179…`, smaller:
- `0xE8100351…`: 0.004299 hsSTETH-BTC in its wallet, count unchanged, −0.00278 BTC through the price. Its collateral
  pool gave 0.000705 haBTC for 0.0188 wstETH (0.000698 BTC).
- `0xecfFe7b0…`: 0.003439 hsSTETH-BTC, −0.00222 BTC through the price. Its collateral pool gave 0.000564 haBTC for
  0.01504 wstETH (0.000559 BTC).

Nothing since. **Proposed treatment:** repay 0.0028 and 0.0022 BTC of value (0.075 and 0.060 wstETH).

### `0x1a915252…6913` — BTC::stETH, owed 0.0072 BTC of value (0.19 wstETH)

0.01117 hsSTETH-BTC in its wallet, count unchanged, −0.00722 BTC through the price. Nothing since. **Proposed
treatment:** repay 0.0072 BTC of value (0.19 wstETH).

### `0xf7e9CAaa…31B2` — EUR::stETH, owed 248 EUR of value (0.091 wstETH)

318.9 hsSTETH-EUR in its wallet, count unchanged, −247.6 EUR through the price. Nothing since. **Proposed treatment:**
repay 248 EUR of value (0.091 wstETH).

### The genesis participants who never claimed — owed 0.0027 BTC and 0.78 EUR of value (0.074 wstETH)

The genesis contract holds their tokens: each claim is the same number of haBTC as of hsSTETH-BTC, and of haEUR as of
hsSTETH-EUR. Each claim's token counts were fixed when genesis ended. **They lost no tokens.** Their pegged tokens kept their value.
**Their whole loss is the leveraged price's fall** on the leveraged tokens they are owed:

| Participant | Market | Claim, each token | Value from the price |
|---|---|---|---|
| `0xBA188C41…bEB7` | BTC::stETH | 0.002921 | −0.001889 BTC (−0.051 wstETH) |
| `0x787A7dA1…e83f` | BTC::stETH | 0.001169 | −0.000756 BTC (−0.020 wstETH) |
| `0x33abAf6F…48B0` | BTC::stETH | 0.0001374 | −0.0000889 BTC (−0.0024 wstETH) |
| `0x2f75E925…454f` | EUR::stETH | 0.9998 | −0.776 EUR (−0.0003 wstETH) |

None has claimed since. **Proposed treatment:** repay each directly. Tokens sent to the genesis contract would never
reach them.

### Small losses — owed under 0.001 BTC or 12 EUR of value each

Each held leveraged tokens in its wallet through the exploit, with the count unchanged, and lost through the price. None
has done anything since.
- `0x061B84FD…35aa`, BTC::stETH: 0.001376 hsSTETH-BTC, −0.000889 BTC (−0.024 wstETH).
- `0x000000000000dEaa…83EB`, EUR::stETH: 15.01 hsSTETH-EUR, −11.66 EUR (−0.0043 wstETH).
- `0x3dE6aAAC…dDE8`, EUR::stETH: 12.41 hsSTETH-EUR, −9.63 EUR (−0.0035 wstETH). A contract with no standard
  interface, treated as one holder.
- `0xAE7Dbb17…c31e`, both markets: 0.0000712 hsSTETH-BTC and 0.3368 hsSTETH-EUR, −0.000046 BTC and −0.26 EUR
  (−0.0013 wstETH).
- `0xDD0CDF8D…9C9a`, BTC::stETH: 0.0000344 hsSTETH-BTC, −0.0000222 BTC (−0.0006 wstETH).
- `0xA0DD6477…534E`, BTC::stETH, a Safe in the collateral pool only, with no leveraged tokens: the pool gave 0.000861
  haBTC for 0.02294 wstETH (0.000852 BTC), −0.0000086 BTC (−0.0002 wstETH). That is its share of the rebalance bounty.

**Proposed treatment:** repay each, unless the team sets a floor below which a repayment is not worth its gas.

## Wallets that gained

### `0x0e4d5032…4869` — BTC::stETH leveraged pool, owes 0.0027 BTC of value (0.074 wstETH)

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| haBTC in the leveraged pool | 0.05764 | 0.04818 | −0.00946 | −0.00946 BTC | |
| hsSTETH-BTC reward, leveraged pool | 0 | 0.1873 | +0.1873 | +0.0122 BTC | |

It held no leveraged tokens, so the price took nothing from it. The capped rebalance took 0.00946 haBTC and paid 0.1873
hsSTETH-BTC, worth 0.0122 BTC at the new price: a gain of 0.0027 BTC.

**Since.**
- On 2026-10-18 it claimed 0.2867 hsSTETH-BTC: the exploit's 0.1873 and 0.0994 from later rebalances.
- Three minutes later it redeemed them for 0.4752 wstETH, which is 0.0609 BTC a token when the minter's price was
  0.0617 BTC.
- At the pause it still has 0.0383 haBTC deposited and 0.0561 hsSTETH-BTC to claim.

**Proposed treatment:** recover 0.0027 BTC of value (0.074 wstETH). The exploit's part of its reward has left the
market, so recovery needs its consent, or a deduction from what it still has in the pool. Only the pool upgrade can make
that deduction.

### `0x13F210c8…AF12` — BTC::stETH, both pools, owes 0.0011 BTC of value (0.029 wstETH)

| Position | Before | After | Change in count | Value from the count | Value from the price |
|---|---|---|---|---|---|
| haBTC in the leveraged pool | 0.02399 | 0.02006 | −0.00394 | −0.00394 BTC | |
| hsSTETH-BTC reward, leveraged pool | 0 | 0.07796 | +0.07796 | +0.00508 BTC | |
| haBTC in the collateral pool | 0.0306 | 0.02558 | −0.00502 | −0.00502 BTC | |
| wstETH reward, collateral pool | 0.02546 | 0.1593 | +0.1339 | +0.00497 BTC | |

No leveraged tokens before, so no loss through the price. Its leveraged pool gained 0.00114 BTC on the counts. Its
collateral pool was about even. Nothing since. Its 0.1427 hsSTETH-BTC of reward is still unclaimed, 0.0780 of it from the
exploit.

**Proposed treatment:** recover 0.0011 BTC of value (0.029 wstETH). The gain is still in its claimable reward, which only
the pool upgrade can reduce.

## The multisig `0x9bABfC1A…64a2` — fees of 0.186 BTC and 4,275 EUR of value (6.57 wstETH)

It is the fee receiver of every market. All counts, no price:
- **BTC::stETH:** +3.003 wstETH (0.1115 BTC) and +0.07405 haBTC, in minting, redemption and early-withdrawal fees.
- **EUR::stETH:** +0.9899 wstETH (2,691 EUR) and +1,584 haEUR.

It still holds the haBTC and haEUR at the pause. Its wstETH is not followed after the exploit.

**Proposed treatment:** return the fees to the repayment.

## The accounts the exploits paid — 0.239 BTC and 3,955 EUR of value (7.88 wstETH)

- `0x61F31C7B…A880`, BTC::stETH: 6.425 wstETH. Not moved, as traced on 2026-10-22.
- `0x0A678044…66F2`, EUR::stETH: 1.455 wstETH, swapped for 1.813 ETH on 2026-10-16.

**Proposed treatment:** none through the contracts. Recovering this is a matter outside them.

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

## What a repayment needs

- **The balance.** The holders' net loss, 0.4242 BTC and 8,230 EUR of value, equals the fees (0.1856 BTC and 4,275 EUR)
  plus what the exploits paid out (0.2386 BTC and 3,955 EUR). The repayment owes 14.55 wstETH to the wallets that lost
  and recovers 0.10 from the two that gained. The fees cover 6.57 of it. The other 7.88 is what the exploits paid out,
  which comes from the treasury or from recovering those proceeds.
- **The unit.** Value owed in a pegged unit and value owed in wstETH differ by how wstETH has moved since. 1 wstETH was
  0.03714 BTC at the exploit and 0.03663 BTC at the pause. The rule should name one.
- **Transfers follow the wallet; a donation follows the tokens.**
  - **Direct transfers.** Wrapped collateral, or tokens minted fee-free on Minter_v3, transferred to each wallet, pay
    exactly the amounts above.
  - **A donation.** Minter_v3's `donateWrappedCollateral` raises the leveraged price for every holder, in proportion to
    what each holds now. It would undo the price loss directly. But `0x619e71ec…` would get 84% of a BTC::stETH donation
    and 97% of a EUR::stETH one. Today it holds more leveraged tokens than before the exploit, because it claimed its
    rewards. The bots and every other holder would get their share, whatever the exploit did to them. It would reach the
    genesis participants through their unchanged claims.
- **Two gains sit in the paused pools:** the unclaimed exploit rewards of `0x13F210c8…` and `0xb9ab9578…`. They can be
  reduced only through the pool upgrade, or paid out as they stand when the pools resume.
