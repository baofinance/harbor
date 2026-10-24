# Holder stories — the rebalance dilution exploits of 2026-10-16

One story per wallet that the exploits changed or that acted afterwards, across both exploited markets, with a
proposed treatment for each. Each wallet is taken to be its own person.

Written against the generated holders files, [BTC-stETH-holders.md](BTC-stETH-holders.md) and
[EUR-stETH-holders.md](EUR-stETH-holders.md), which follow every holder up to block 26,248,724, where the minters and the
pools were paused. Figures here are rounded to show their size. The exact ones are in those files and in the accounts
files.

How to read the figures:
- **The exploit's change** is the change in a wallet's value across the exploit's transaction, in wstETH, at that
  block's prices. It is the sum of the wallet's rows in the accounts file. Negative is a loss.
- **Since** means from the exploit to the pause. Nothing happened in either market after the managers were paused on
  2026-10-21.
- **Prices:** hsSTETH-BTC fell from 19.16 to 1.75 wstETH a token in the BTC::stETH exploit, and hsSTETH-EUR from
  0.000308 to 0.0000227 wstETH a token in the EUR::stETH exploit. Both fell by more than 90%.

## In short

| | wstETH |
|---|---|
| Lost by 17 wallets | −14.55 |
| Gained by 2 leveraged pool depositors | +0.10 |
| Gained by the multisig, in fees | +6.57 |
| Gained by the accounts the exploits paid | +7.88 |

The rows sum to zero, to rounding. One wallet, `0x619e71ec…`, lost 13.31 of the 14.55.

- **Nobody bought into either market after the exploits.** There was no mint at all. The leveraged token supply grew
  only through the rebalances that followed (16 on BTC::stETH, 5 on EUR::stETH), each at the fair rate.
- **Nobody sold a leveraged token they held through the exploit.** Every wallet still holds the leveraged tokens it held
  before. One gainer redeemed the reward the exploit overpaid it.
- **The wallets new since the exploits are rebalance bots.** They took the bounties of the rebalances that the
  exploits' low collateral ratio set off.

## The proposed rule

This is a proposal for decision.

- **A wallet is owed, or owes, the exploit's change.** That is its value change across the exploit's transaction, in
  wstETH at that block's prices, with all its positions netted: wallet, both pools and genesis claim.
- **The amount follows the wallet, not its tokens.** What a wallet did afterwards does not change what it is owed.
- **Later price moves are not counted.** The exploit's transaction is the whole of the harm the rule measures.

## Wallets that lost

### `0x619e71ec…10E3` — both markets, owed about 13.31 wstETH

The largest holder in both markets, and nine-tenths of the loss.

- **BTC::stETH, −10.52.**
  - **Before:** 0.619 hsSTETH-BTC in its wallet, worth 11.9 wstETH. In the leveraged pool, 0.208 haBTC. In the
    collateral pool, 0.204 haBTC.
  - **The exploit:** its wallet tokens lost 10.78. Its leveraged pool deposit lost 0.034 haBTC (0.92), converted at the
    capped rate into 0.677 hsSTETH-BTC of reward (+1.19). Its collateral pool gave 0.033 haBTC (0.90) for 0.89 of
    wstETH reward.
- **EUR::stETH, −2.80.**
  - **Before:** 7,238 hsSTETH-EUR in its wallet, worth 2.23 wstETH. In each pool, 2,987 haEUR.
  - **The exploit:** its wallet tokens lost 2.07. In the leveraged pool, 585 haEUR (0.22) became 11,591 hsSTETH-EUR of
    reward. Its reward grew in count but fell 0.51 in value, as the price fell.
- **Since.** The later rebalances converted more of its deposits in both markets at the fair rate. On 2026-10-20 it
  claimed every reward in both markets:
  - 2.12 wstETH and 1.24 hsSTETH-BTC on BTC::stETH;
  - 1.05 wstETH and 24,979 hsSTETH-EUR on EUR::stETH.

  It redeemed nothing.
- **At the pause.** It holds 1.86 hsSTETH-BTC, 84% of the supply, and 32,217 hsSTETH-EUR, 97% of the supply. It still
  has 0.27 haBTC and 3,518 haEUR in the pools.
- **Proposed treatment:** repay about 13.31 wstETH. That already nets the leveraged pool overpayment it received and has
  since claimed.

### `0xb9ab9578…0E7F` — both markets, owed about 0.41 wstETH

- **BTC::stETH, −0.28.** Its 0.017 hsSTETH-BTC in its wallet lost 0.30. Its leveraged pool deposit gained 0.02 net from
  the overpaid reward. Its collateral pool position changed little.
- **EUR::stETH, −0.13.** Its 462 hsSTETH-EUR in its wallet lost 0.13.
- **Since:** nothing. Its BTC::stETH pool rewards are unclaimed: 0.104 hsSTETH-BTC, 0.057 of it from the exploit, and
  0.38 wstETH.
- **Proposed treatment:** repay about 0.41 wstETH, net of the overpaid reward still in its account.

### `0xEE517179…F775` — BTC::stETH, owed about 0.30 wstETH

0.017 hsSTETH-BTC in its wallet lost 0.30. Its collateral pool deposit of the same size gave 0.003 haBTC for about the
same in wstETH reward. Nothing since. **Proposed treatment:** repay about 0.30 wstETH.

### `0x1a915252…6913` — BTC::stETH, owed about 0.19 wstETH

0.011 hsSTETH-BTC in its wallet lost 0.19. Nothing since. **Proposed treatment:** repay about 0.19 wstETH.

### `0xf7e9CAaa…31B2` — EUR::stETH, owed about 0.091 wstETH

319 hsSTETH-EUR in its wallet lost 0.091. Nothing since. **Proposed treatment:** repay about 0.091 wstETH.

### `0xE8100351…9135` and `0xecfFe7b0…dCED` — BTC::stETH, owed about 0.075 and 0.060 wstETH

The same shape as `0xEE517179…`, smaller. Each held hsSTETH-BTC in its wallet and the same amount of haBTC in the
collateral pool: 0.0043 and 0.0034. The wallet tokens carry the loss. Nothing since. **Proposed treatment:** repay about
0.075 and 0.060 wstETH.

### The genesis participants who never claimed — owed about 0.074 wstETH together

The genesis contract holds their haBTC and hsSTETH-BTC, and their haEUR and hsSTETH-EUR. Each claim was fixed when
genesis ended, so the claims lost value with the leveraged price. None has claimed since.
- `0xBA188C41…bEB7`: 0.0029 of each BTC token, −0.051.
- `0x787A7dA1…e83f`: 0.0012 of each, −0.020.
- `0x33abAf6F…48B0`: 0.00014 of each, −0.0024.
- `0x2f75E925…454f` (EUR::stETH): 1.0 of each EUR token, −0.0003.

**Proposed treatment:** repay each directly. Tokens sent to the genesis contract would never reach them.

### Small losses — owed under 0.03 wstETH each

Each held leveraged tokens in its wallet through the exploit and has done nothing since.
- `0x061B84FD…35aa`, BTC::stETH: 0.0014 hsSTETH-BTC, −0.024.
- `0x000000000000dEaa…83EB`, EUR::stETH: 15 hsSTETH-EUR, −0.0043.
- `0x3dE6aAAC…dDE8`, EUR::stETH: 12.4 hsSTETH-EUR, −0.0035. A contract with no standard interface, treated as one
  holder.
- `0xAE7Dbb17…c31e`, both markets: tiny amounts of both leveraged tokens, −0.0013.
- `0xDD0CDF8D…9C9a`, BTC::stETH: 0.000034 hsSTETH-BTC, −0.0006.
- `0xA0DD6477…534E`, BTC::stETH: a Safe, in the collateral pool only, −0.0002. That is its share of the rebalance
  bounty.

**Proposed treatment:** repay each, unless the team sets a floor below which repayment is not worth its gas.

## Wallets that gained

### `0x0e4d5032…4869` — BTC::stETH leveraged pool, owes about 0.074 wstETH

- **The exploit.** The capped rebalance took 0.0095 haBTC of its deposit (0.25 wstETH). It paid back 0.187 hsSTETH-BTC
  of reward (0.33). Net +0.074.
- **Since.** On 2026-10-18 it claimed 0.287 hsSTETH-BTC: the exploit's reward and what later rebalances added. Three
  minutes later it redeemed them for 0.475 wstETH, at 1.66 wstETH a token. At the pause it still has 0.038 haBTC
  deposited and 0.056 hsSTETH-BTC to claim.
- **Proposed treatment:** recover about 0.074 wstETH. The exploit's part of its reward has left the market, so recovery
  needs its consent, or a deduction from what it still has in the pool. Only the pool upgrade can make that deduction.

### `0x13F210c8…AF12` — BTC::stETH, both pools, owes about 0.029 wstETH

- **The exploit.** Its leveraged pool deposit gained net from the overpaid reward: −0.106 deposit for +0.137 reward. Its
  collateral pool position was about even. Net +0.029.
- **Since:** nothing. Its 0.143 hsSTETH-BTC of reward is still unclaimed, 0.078 of it from the exploit.
- **Proposed treatment:** recover about 0.029 wstETH. The gain is still in its claimable reward, which only the pool
  upgrade can reduce.

## The multisig `0x9bABfC1A…64a2` — fees of about 6.57 wstETH

It is every market's fee receiver.
- **BTC::stETH:** 3.00 wstETH and 0.074 haBTC (1.99 wstETH) in minting, redemption and early-withdrawal fees, +5.00.
- **EUR::stETH:** 0.99 wstETH and 1,584 haEUR (0.58), +1.57.

It still holds the haBTC and the haEUR at the pause. Its wstETH is not followed after the exploit.

**Proposed treatment:** return the fees, about 6.57 wstETH in value, to the repayment.

## The accounts the exploits paid — about 7.88 wstETH

- `0x61F31C7B…A880`, BTC::stETH: 6.43 wstETH. Not moved, as traced on 2026-10-22.
- `0x0A678044…66F2`, EUR::stETH: 1.45 wstETH, swapped for 1.81 ETH on 2026-10-16.

Not recoverable through the contracts. **Proposed treatment:** none through the contracts. Recovering it is a matter
outside them.

## Since the exploits: the rebalance bots

Each exploit left its market's collateral ratio below its rebalance threshold. Bots then called the permissionless
`rebalance` and took its bounty in leveraged tokens:
- BTC::stETH: `0xE08D97e1…D015` 8 times, `0x00000F91…0CAc` 5 times, and `0x0000000000be226a…e69D`,
  `0x4A8DE25c…353f` and `0x682eA8AA…2979` once each. `0x0000000000be226a…` passed most of its bounty on to
  `0x000000000076403c…2343`.
- EUR::stETH: `0xE08D97e1…D015` once (73 hsSTETH-EUR), `0x682eA8AA…2979` twice, and `0x00E2E97E…F8FE` and
  `0xBb13d96f…95A0` once each.

Most redeemed their bounty in the same transaction. The rest hold less than a thousandth of a wstETH each in value. The
bounties came out of the pools, at 1% of each rebalance.

**Proposed treatment:** none. They were paid for calls the system invites, at the fair rate.

## Not affected

The pegged-only holders, among them the fxUSD markets' own contracts, which hold haBTC and haEUR, lost nothing. The
pegged price did not move.

## What a repayment needs

- **The balance.** The losses, 14.55 wstETH, exceed the 6.57 of fees and the 0.10 the gainers owe by 7.88 wstETH. That
  is what the exploits paid out. The rest comes from the treasury, or from recovering the exploits' proceeds.
- **Transfers follow the wallet; a donation follows the tokens.**
  - **Direct transfers.** Wrapped collateral, or tokens minted fee-free on Minter_v3, transferred to each wallet,
    pay exactly the amounts above.
  - **A donation.** Minter_v3's `donateWrappedCollateral` raises the leveraged price for every holder, in proportion to
    what each holds now. `0x619e71ec…` would get 84% of a BTC::stETH donation and 97% of a EUR::stETH one. Today it
    holds more leveraged tokens than before the exploit, because it claimed its rewards. The bots, the genesis
    participants and every other holder would get their share, whatever the exploit did to them.
- **Two gains sit in the paused pools.** They are the unclaimed exploit rewards of `0x13F210c8…` and `0xb9ab9578…`. They
  can be reduced only through the pool upgrade, or paid out as they stand when the pools resume.
