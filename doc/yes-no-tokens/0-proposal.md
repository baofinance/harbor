# Harbor as a Prediction Market (Design Sketch)

Binary prediction market: collateral → **Yes** and **No** tokens. LPs provide liquidity (zero loss); bettors bet on outcome. No stability pools; fees to LPs. Settlement resolves one side = 1 collateral, the other = 0. The **mint/redeem setup** is the same pattern as current Harbor (pegged + leveraged tokens backed by collateral); we **repurpose** pegged → **Yes** and leveraged → **No**, with pricing from supply ratio instead of collateral/leverage ratio.

---

## Model

- **Yes / No tokens:** Same collateral backs both. **Before settlement:** price from supply ratio (e.g. 60 Y, 40 N → Yes 0.6, No 0.4). **At settlement:** winning token = 1 collateral, losing = 0.
- **LPs:** Deposit collateral, mint equal Yes + No (or at current ratio). Receive LP tokens. Redeem **matched pairs only** (1 Y + 1 N → 1 collateral at oracle price). Earn trading fees.
- **No stability pools.** Mint/redeem fees → LPs.
- **Clarifications:** (1) **First LP:** 1 collateral → 1 Yes + 1 No (1:1:1). (2) **First deposit opens trading** — no genesis wait. (3) **Later LPs** mint at **current supply ratio** (e.g. 60/40 → mint 60 Y + 40 N per 100 collateral). (4) **Factory:** Anyone can create a market (outcome + date + resolution source).
- **Minting mechanics:** Once trading is open, **single-token** mint/redeem uses the **oracle price** (supply ratio). So with 100 Y and 100 N, 1 Yes costs **0.5 collateral** to mint (and 1 No costs 0.5). If the market has moved to **300 Y and 100 N** (ratio 3:1), a **new LP** depositing **100 collateral** mints **150 Yes and 50 No** — i.e. 100 C buys (150 Y + 50 N) at the current ratio so the supply ratio is unchanged. Solvency: after the deposit, total collateral must still satisfy C ≥ max(Y, N).

---

## LP value: why 100+100 and matched book

**AMM-style pool (LPs as counterparty):** If LPs hold 50 Y + 50 N for 100 collateral, at settlement one side wins → LPs get 50 back (**50% leakage**). Plus adverse selection when traders trade against the pool. So LPs don’t maintain deposit value without heavy fees.

**Zero LP loss:** Use a **matched book**. Pool never holds net position: every Yes bought is sold by another participant (order book / batch / RFQ). LPs create initial supply (e.g. 100 Y + 100 N for 100 C) and **sell** both sides, or market-make with **zero net position**. All loss is with bettors who hold the losing side.

**100+100 (1 per winning token) vs 50+50 (2 per token):** When LPs **sell** all tokens at oracle price, 100+100 yields sales = 100, pool has 200, pays 100 to winners, LPs get 100 back (**no leakage**). With 50+50, sales = 50, pool has 150, pays 100, LPs get 50 (**50% leakage**). So **100+100 with 1 per winning token** is required when LPs sell into the market.

---

## Scenarios and redemptions

**Example (100 C, 100 Y, 100 N):** Oracle price = supply ratio (0.5 each when 50/50). Bettor buys at *p*, gets 1 if that side wins else 0 → **profit = (1 or 0) − p**. With *p_yes + p_no = 1*, sales sum to 100, so pool has 200, pays 100 to winners, LPs get 100 + fees.

**LP redemptions before settlement:** Mint/redeem is at **oracle price** (not 1). **One side only:** e.g. redeem 50 Y at 0.5 → 25 C out; pool has 75 C but 50 Y + 100 N left → can be **insolvent** at settlement. **Not allowed.** **Matched pairs only:** 1 Y + 1 N → 1 C (0.5+0.5). Preserves C ≥ max(Y,N). LPs can exit anytime with zero loss.

---

## Contract changes (high level)

| Current Harbor | Prediction market |
|----------------|-------------------|
| Minter (pegged + leveraged, rebalance) | **Market core** (Yes/No, 100+100, C ≥ max(Y,N), no rebalance) |
| Pegged + Leveraged tokens | **Yes + No** tokens |
| Genesis | **LP** (mint matched pairs, redeem matched pairs, get fees) |
| Stability pool | **Removed** |
| Oracle | **Pricing:** supply ratio. **Resolution:** at settlement (Yes or No wins). |
| Rebalancer, harvest | **Removed** |

**New/heavy:** Market contract per binary market (collateral, settlement time, resolution config). Yes/No ERC20s. Settlement: disable trading → resolve (Chainlink / UMA / committee) → set outcome → redeem winning tokens for 1 C each. **Fees:** see below.

---

## Passing trading fees to LPs

**Reward-per-LP-share accumulator:** Use a single global **rewardPerShare** (collateral per LP share, scaled 1e18). On each mint/redeem fee: `rewardPerShare += fee * 1e18 / total_LP_supply`. Each LP stores **last_rewardPerShare** at last interaction (deposit, withdraw, claim). **Claimable** = `LP_balance * (rewardPerShare - last_rewardPerShare) / 1e18`. New depositors get current `rewardPerShare`; on withdraw/redeem (or `claimFees()`), send accrued collateral and update `last_rewardPerShare`. Same pattern as Synthetix staking / Uniswap V3 fee growth — fair when LPs join/leave, one state update per trade.

---

## Protocol cut and yield-bearing collateral

**Protocol cut:** The protocol can take a **cut** of revenue (e.g. 10–20% of fees, or of fees + yield) before the remainder is credited to the LP accumulator. So on each fee: `protocolShare = fee * protocolCutBps / 10000`; `rewardPerShare += (fee - protocolShare) * 1e18 / total_LP_supply`. Protocol share is sent to a treasury or fee collector.

**Yield-bearing collateral:** For USD-based markets, collateral can be **yield-bearing** (e.g. **sUSDe**, or other staked/rebasing stablecoins). The market holds sUSDe; sUSDe accrues yield over time. That yield can be used to **supplement** LP income: either (a) yield is added to the LP reward stream (so LPs get fees + yield), or (b) **fees and yield are combined** into one revenue stream, then the **protocol takes a cut** and the rest goes to LPs via the same accumulator. Option (b) keeps one distribution path: (fees + accrued yield) × (1 - protocolCut) → `rewardPerShare`. Requires tracking yield (e.g. increase in sUSDe balance or rebase) and attributing it to the LP pool; protocol cut applies to the combined amount before crediting LPs.

**Example (sUSDe):** Market uses sUSDe as collateral. Trading fees (mint/redeem) are taken in sUSDe. sUSDe balance in the market grows from yield. Periodically (or continuously), compute yield = current balance − (deposits − withdrawals − fees collected). Combine fees + yield; take protocol cut (e.g. 15%); credit the rest to `rewardPerShare` for LPs. LPs then earn from both trading activity and collateral yield, with the protocol taking a share of the total.

---

## Settlement and resolution

- **Price-at-time** (e.g. “ETH > X at time T”): **Chainlink** (or similar) at settlement → automatic, trust-minimized. Only for numeric conditions on a feed.
- **Elections, sports, real-world:** **Oracle** (UMA, etc.) or **committee** pushes outcome. Not automatic; trust and optionally dispute window.
- **On-chain state:** Read contract at block → can be automatic for simple reads.

**Contracts:** Per-market **resolution type** (`PRICE_AT_TIME` | `ORACLE` | `COMMITTEE` | `ON_CHAIN`) and params (feed, threshold, timestamp; or oracle/committee). Settlement module: disable trading → call resolver → set outcome → allow redemption of winning side only.

---

## Comparison with Polymarket

**Similarities:** Binary Yes/No outcome tokens; LPs (liquidity providers) exist; trading fees can flow to LPs. Polymarket uses a **CLOB** (order book), so trades are matched peer-to-peer or with market makers — conceptually close to our “matched book” (no single pool as counterparty).

**Polymarket LPs:** Yes — Polymarket **does allow LPs**. They act as **market makers**: they post limit orders on both sides (Yes and No) and earn from **spreads** and from the **Maker Rebates Program** (a share of taker fees is redistributed to LPs on selected markets, e.g. 15-min crypto, some sports). So LPs **do earn trading-related revenue** (spreads + rebates).

**Key difference — LP risk:** Polymarket LPs can end up with **inventory** (net position on one side) when takers hit one side more than the other. Their docs call out **adverse selection** as the main LP risk: informed traders can leave LPs holding an imbalanced position, so LPs **can lose** if the market moves against that position. Our design instead **enforces** zero net position: LPs may only redeem **matched pairs** (1 Y + 1 N → 1 C); one-side redemption is disallowed. So in our design LPs are **guaranteed zero outcome risk** (they never hold net Yes/No to settlement); on Polymarket, LPs are market makers who **can** take loss from adverse selection.

**Fees:** Polymarket: many markets have no trading fees; where they do, taker fees apply and a portion is rebated to LPs on certain markets. Our design: explicit mint/redeem fees, all to LPs via the reward-per-share accumulator.

---

## Summary

- **100+100 design:** LPs provide liquidity with zero loss; redeem all via matched pairs (1 Y + 1 N → 1 C) anytime for zero loss; earn fees (accumulator). Bettors profit/lose by outcome and entry price.
- **Matched book** (no pool as counterparty) + **1 Yes + 1 No per 1 C** at settlement avoids LP leakage. First LP 1:1:1; later LPs at current ratio; first deposit opens trading; factory can allow anyone to create markets.
- **Fees to LPs:** Reward-per-LP-share accumulator; claim on withdraw or `claimFees()`. **Protocol cut:** Take a share of fees (or of fees + yield) to treasury; rest to LPs. **Yield-bearing collateral** (e.g. sUSDe for USD markets): combine fees + yield, take protocol cut, credit remainder to LPs.
- **Settlement:** Price-at-time (Chainlink) = automatic; elections/sports = oracle/committee. Support multiple resolution types per market.
