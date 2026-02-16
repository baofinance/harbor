## critical issues

### 1.

- **Bull market** - yes draining USDC during a bull market would be an issue we have to handle. It is likely we will have to set a fee structure that will essentially prevent further minting as capacity goes towards 0.,

- **bear market** - it seems to have misunderstood how stability pools work? the pool would not be filled with depreciating collateral. Any collateral from rebalancing redemptions are not part of the stability pool.

### 2.

Yes this is accurate. Our stability pool design should include our hyTOKEN mechanics of swapping collateral recieved during rebalances for more equivalent tokens.

### 3.

yes, protections for swaps will be needed. Risks can be mitigated by using only the most liquid tokens for collateral, use mev protected protected protocols like cowswap so advanced solvers can find the most optiumal routes. Potential for leakage and actual leakage can be transparently communicated.

### 4.

yes. It may be prudent to only have one token, especially to start with. ,

### 5.

when you withdraw, you choose which asset. there may be a fee attached if there is an imbalance.,
it is acceptable to get pegged tokens back in all cases because they are redeemable for collateral,
yes, tracking complexity is more complex,
the pegged token will not depeg from usdc unless rebalancing fails, or USDC depegs from $1. rebalancing failling would likely mean there are no pegged tokens in the pool. a depeg would mean users can deposit pegged tokens and withdraw USDC at a discount, providing more pegged tokens for a rebalance and return to peg.
