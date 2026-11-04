# Rebalance Bug: Impact Analysis & Production Remediation

## The Bug

In `Minter_v1.freeRedeemPeggedToken()`, when a rebalance triggers both the collateral and leveraged redemption paths:

1. The **collateral path** (line 911) reads `$.underlyingCollateral`, computes collateral to return, and **writes the reduced value** to storage (line 920)
2. The **leveraged path** (line 928) then reads `$.underlyingCollateral` — which has already been reduced by the collateral path

Both paths should price against the **same pre-redemption state**, since `redeemPeggedForCollateralRatio()` computed the split amounts against that state.

The leveraged path sees artificially low collateral, which inflates the leverage ratio in `_leveragedTokensForPegged()`, causing **massive over-minting of leveraged tokens**.

### The Fix (Minter_v2)

Snapshot `underlyingCollateral_` before either path and pass that snapshot to the leveraged path (line 931) instead of re-reading the mutated storage value.

## Measured Impact (at block 24687073)

From `RebalanceCheck_remediation.test_log_overminting_delta()`:

| Metric | v1 (buggy) | v2 (correct) |
|--------|-----------|-------------|
| Leveraged tokens minted | ~8.92 (8.92e18) | ~0.14 (1.45e17) |
| Leveraged token price after | 0.171 ETH | 3.078 ETH |
| Collateral removed | ~5,256 (5.26e21) | ~5,256 (5.26e21) |
| underlyingCollateral after | ~15,093 (1.51e22) | ~15,093 (1.51e22) |

Key findings:

- **`underlyingCollateral` is identical** between v1 and v2 — the collateral accounting is not affected
- **Excess leveraged tokens: ~8.77** (61x over-mint)
- **Price crash: 3.08 -> 0.17 ETH** — purely from supply dilution
- Collateral removal is identical because the leveraged path only reads `$.underlyingCollateral` to compute the leverage ratio — it never writes to it

## Why This Cannot Be Fixed By Storage Adjustment

The leveraged token price formula:

```
leveragedTokenPrice = (collateralValue - peggedValue) / leveragedSupply
```

The numerator (collateral and pegged balances) is correct. The denominator (leveraged supply) is inflated by 8.77e18 excess tokens that have already been minted and distributed. No storage variable adjustment can un-mint tokens.

## Who Is Affected

Two distinct populations are harmed:

### 1. Existing leveraged token holders (buyers/minters)

Anyone who held leveraged tokens before the rebalance saw their token price drop from ~3.08 to ~0.17 ETH — a ~94% loss. This group did nothing wrong; their holdings were diluted by the excess minting.

This includes anyone who:
- Minted leveraged tokens via `mintLeveragedToken()`
- Bought leveraged tokens on secondary markets
- Received leveraged tokens through any other mechanism before the rebalance

### 2. Stability pool depositors (reward recipients)

The excess leveraged tokens were distributed to stability pool depositors as liquidation rewards. These depositors received ~61x more leveraged tokens than they should have, but at ~1/18th of the correct price.

The total value distributed is:
- v1: ~8.92 tokens * 0.171 ETH = ~1.52 ETH worth
- v2: ~0.14 tokens * 3.078 ETH = ~0.45 ETH worth

So depositors actually received ~3.4x more value than they should have, at the expense of existing holders. However, any depositor who also held leveraged tokens before the rebalance suffered the same dilution loss on those holdings.

## Production Remediation Options

### Option 1: Do Nothing — Accept the Dilution

Upgrade to Minter_v2 to prevent recurrence. The excess tokens remain in circulation. Over time, normal protocol activity (minting, redeeming, fee accumulation) will gradually dilute the relative impact of the excess, but the ~94% price drop is permanent unless supply is reduced.

**Pros:** No governance risk, no additional contract changes, no precedent of retroactive intervention
**Cons:** Existing leveraged token holders bear the full loss. May undermine confidence in the protocol.

### Option 2: Inject Additional Collateral

Transfer wrapped collateral tokens into the minter and call `reset()` to increase `underlyingCollateral` to match the new wrapped balance. This increases the numerator of the price formula, compensating for the inflated supply.

Required injection to restore price to ~3.08 ETH:
```
needed = (targetPrice * currentSupply + peggedValue - currentCollateralValue) / price
```

**Pros:** Restores leveraged token price for all holders without touching anyone's token balances. Both existing holders and reward recipients benefit proportionally.
**Cons:** Costs real money. The source of funds must be justified. This effectively subsidises the windfall that stability pool depositors already received — they keep the excess tokens AND get their price restored.

### Option 3: Remove Excess Leveraged Tokens from Stability Pools

Note: rebalance rewards are distributed immediately via `_accumulateReward` (not via the 7-day linear distributor). The reward integral is updated atomically during the rebalance transaction, so the excess tokens are **immediately claimable** by all depositors from the moment the rebalance completes.

The excess leveraged tokens sit in two places depending on claim status:

**If unclaimed:** The tokens are held by the stability pool contract. Each depositor's claimable amount is computed from reward integrals (`tokenToExponentToIntegral`) — there is no per-user ledger of "tokens owed". The integral records the cumulative reward-per-unit-of-pool-share. To reduce claimable amounts, you would need to either:

- **a) Reduce the integral:** Upgrade the stability pool to subtract the excess from the current reward integral for the leveraged token. This retroactively reduces every depositor's unclaimed reward proportionally. The excess tokens (still held by the pool contract) can then be burned or transferred out. This is the cleanest approach if no claims have occurred yet.

- **b) Transfer excess tokens out of the pool:** Upgrade the pool with a governance function that transfers the excess leveraged tokens to a burn address or back to the minter. However, without also adjusting the integral, depositors would still see the original claimable amount — their claims would eventually fail with "transfer amount exceeds balance" when the pool runs dry. So this must be paired with (a).

**If partially claimed:** Some depositors have already received their share of the excess. The integral has been checkpointed per-user at claim time (`userRewardSnapshot[account][token].checkpoint.integral`). Reducing the global integral would only affect depositors who haven't claimed yet, creating an inequitable split where early claimers keep the windfall and late claimers get reduced amounts.

**If fully claimed:** The tokens are dispersed across depositor wallets (or further traded/transferred). No contract change can recover them.

**Implementation sketch for (a):**
1. Compute `excessPerPoolShare = excessTokens * REWARD_PRECISION * magnitude / totalPoolShare` at the time of the rebalance
2. Upgrade the stability pool (StabilityPool_v3 or a one-time migration function)
3. Subtract the excess integral delta from `tokenToExponentToIntegral[leveragedToken][currentExponent]`
4. Transfer the corresponding excess leveraged tokens out of the pool and burn them

**Pros:** Directly addresses root cause (excess supply). Restores price without spending money. Fair to existing leveraged token holders.
**Cons:** Invasive — requires stability pool contract upgrade. Only works fully if no claims have occurred. Partial-claim scenarios create inequity between early and late claimers. Penalises depositors who received rewards in good faith. Must be done for each affected stability pool (SPL receives leveraged tokens as liquidation rewards).

### Option 4: Compensatory Mint to Non-Pool Holders

Instead of removing excess tokens from pools, mint additional leveraged tokens to all non-pool holders to restore their proportional share of system value.

The bug diluted non-pool holders because the pool depositors received a disproportionate share of the total supply. Minting additional tokens to non-pool holders restores their ownership fraction, effectively diluting away the pool depositors' windfall without touching the stability pool contracts.

**Math:** For a non-pool holder with N tokens (out of total supply S, with E excess minted):
```
tokens_to_mint = N * E / (S - E)
```
This restores their fraction of total value to what it was pre-bug. The leveraged token price drops further (more supply against the same collateral), but each non-pool holder's total value (`tokens * price`) is preserved.

**Implementation:**
1. Snapshot leveraged token holders at the block of the buggy rebalance (from chain data / events)
2. Exclude stability pool contract addresses (they hold the excess)
3. Add a governance function to Minter_v2 that calls `IMintable(LEVERAGED_TOKEN).mint(holder, amount)` for each eligible address
4. Alternatively, deploy a claim contract where eligible holders can claim their compensatory tokens

**Effect on each party:**
- Non-pool holders: more tokens, lower price, **same total value** — made whole
- Pool depositors (unclaimed): same token count claimable, but each token is now worth less — their windfall is diluted away
- Pool depositors (claimed): if they still hold the tokens, same dilution applies; if they already sold, the buyer bears the dilution

**Pros:** Does not require stability pool upgrade. Does not touch reward integrals. Mechanically simple (just mint calls). Works regardless of claim status. Fair to non-pool holders.
**Cons:** Requires identifying all non-pool holders at the time of the bug (on-chain snapshot). Secondary market activity between bug and fix complicates eligibility. The per-token price drops further, which may confuse users even though total value is preserved. Still doesn't address users who sold at the depressed price before the fix.

### Option 5: Hybrid — Partial Injection + Partial Burn

Combine options 2 and 3 to share the cost between the protocol (injection) and reward recipients (burn/reduction).

**Pros:** Distributes the impact more fairly across stakeholders
**Cons:** Complex to implement and justify the split ratio

### Option 6: Compensation via Future Rewards

Redirect a portion of future protocol revenue (harvest yield, fees) to a compensation pool for affected leveraged token holders.

**Pros:** No immediate capital outlay. No contract changes beyond accounting.
**Cons:** Slow recovery. Difficult to track eligible holders (secondary market trades complicate this). Doesn't help holders who sell at the depressed price before compensation arrives.

## Considerations for Any Remediation

1. **Secondary market activity:** Between the buggy rebalance and any fix, leveraged tokens may have been traded. Buyers at the depressed price would receive a windfall if the price is restored; sellers took the loss and won't benefit from remediation.

2. **Stability pool claims:** If depositors have already claimed the excess leveraged tokens and sold them, a burn is impossible and the tokens are dispersed across unknown wallets.

3. **Precedent:** Any retroactive intervention sets a governance precedent. Future bugs or market events may be compared to the response here.

4. **Timing:** The longer remediation is delayed, the more secondary market activity occurs, making fair remediation harder to define.

## Verification

Test suite: `forge test --mp test/RebalanceCheck.t.sol`

| Test | Purpose |
|------|---------|
| `RebalanceCheck_v1` | Confirms v1 bug exists (skipped price/mint tests fail) |
| `RebalanceCheck_v2` | Confirms v2 fix works — all assertions pass |
| `test_log_overminting_delta` | Quantifies exact excess minting and price impact |
| `test_confirm_collateralDelta_isZero` | Proves collateral accounting is unaffected |
