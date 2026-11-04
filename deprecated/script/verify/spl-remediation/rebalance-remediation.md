# fxUSD-ETH Sail Stability Pool Rebalance Remediation

## What happened

The fxUSD-ETH market underwent five rebalances in quick succession. While each rebalance correctly restored the collateral ratio, a bug in Minter_v1 caused approximately 23x too many sail (hsFXUSD-ETH) tokens to be minted and distributed as rewards to the sail stability pool. The excess supply caused the sail price to drop by over 90%, visible in the price chart on the app.

## What we did

1. **Fixed the bug and upgraded all minters.** A two-line change in the `freeRedeemPeggedToken` function corrects the sail minting calculation. The fix has been deployed across all markets, ensuring no other market can be affected. The new contract replaced the old one in the automated test suite, and new tests were written to confirm the bug is fixed.

2. **Paused the affected stability pool.** This prevented further user actions -- claims, deposits, withdrawals -- that would have compounded the problem and made remediation more difficult.

3. **Simulated the correct outcome.** We replayed all 15 on-chain transactions, from the first rebalance through to the pause, against the fixed Minter_v2 to determine the exact token counts each depositor should hold in the absence of the bug.

4. **Executed the remediation.** The stability pool was temporarily upgraded to a one-shot remediation contract that:
   - Scaled down the reward-token integral to match the correct (v2) distribution. This single number is the only direct change to stability pool state; all other changes were made through the pool's own external functions to burn sail tokens.
   - Burned the excess sail tokens from the pool. Where excess tokens had already been withdrawn by claimers or paid out as rebalance bounties, the resulting collateral gap (82 fxSAVE) was covered by the Harbor treasury.

   The pool was then restored to its original StabilityPool_v2 implementation.

5. **Verified the result comprehensively.** We confirmed:
   - Every depositor's claimable sail matches, to the wei, what they would have received without the bug.
   - The sail price recovered to the correct level.
   - All normal operations (deposit, withdraw, claim, rebalance, mint, redeem) function correctly after remediation.
   - fxSAVE reward claimable amounts were not affected.
   - haETH deposit balances in the pool were not altered.

## Lessons learned

If a similar issue were to occur in the future, we would pause all affected contracts immediately to prevent any user interaction with the affected market. An early pause protects user funds by preventing claims, redeems, or withdrawals at distorted prices, and greatly simplifies remediation by removing the need to account for interim user activity.

This remediation would not have been possible without the ability to upgrade contracts. Harbor's goal is to move toward immutable contracts while accepting that complex software can have bugs. ERC-7201 namespaced storage also made this fix significantly easier to implement, allowing the remediation contract to access the stability pool's internal state without inheriting its full contract hierarchy.
