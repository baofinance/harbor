# Gauge Claim Flow

This diagram illustrates the sequence of operations during a gauge claim in the rebalance pool system.

```mermaid
---
config:
  look: handDrawn
---
sequenceDiagram
    autonumber
    actor keeper as Keeper
    participant claimer as RebalancePoolGaugeClaimer
    participant registry as RebalancePoolRegistry
    participant minter as TokenMinter
    participant splitter as RebalancePoolSplitter
    participant pool as ShareableRebalancePool
    participant ve as VotingEscrow

    keeper->>+claimer: claim()
    note over claimer: mint the FXN from the gauge<br>

    claimer->>registry: getPools()
    note over registry: returns registered pools

    claimer->>ve: getVotingPower()
    note over ve: checks voting power<br>for boost calculation

    claimer->>+minter: mint(gauge_rewards)
    minter-->>-claimer: minted tokens

    claimer->>+splitter: distributeRewards(tokens)
    note over splitter: calculate distribution<br>based on weights

    splitter->>+pool: notifyRewardAmount(token, amount)
    note over pool: update reward data<br>and distribution rate
    pool-->>-splitter: confirmation

    splitter-->>-claimer: distribution complete

    claimer->>keeper: return claimable amounts
    note over keeper, claimer: rewards now available<br>in respective pools
    claimer-->>-keeper: transaction complete
```

## Overview

The gauge claim process involves several contracts working together to:

1. Calculate eligible rewards
2. Mint new tokens through the TokenMinter
3. Distribute these tokens to various rebalance pools according to their weights
4. Make rewards claimable by users who have staked in these pools

The VotingEscrow system provides boosting mechanics that can increase rewards for users who have locked tokens.
