<!-- # Gauge Claim Flow

This diagram illustrates the sequence of operations during a gauge claim in the rebalance pool system. -->

```mermaid
---
config:
  mirrorActors: false
---
sequenceDiagram
    autonumber
    actor keeper as Claimer (keeper)
    participant spm as StabilityPool<br>Manager
    participant spc as StabilityPool<br>collateral
    participant spl as StabilityPool<br>steamed
    participant steamer as STEAM Minter
    participant ve as veBAO
    participant minter as Minter
    %%participant gauge as "gauge"
    %%participant reserve as ReservePool

    keeper->>+spm: claim()
    note over spm: determine eligible pools<br>and reward amounts

    spm->>spm: getPools()
    note over spm: returns registered pools

    spm->>ve: getVotingPower()
    note over ve: checks voting power<br>for boost calculation

    spm->>+steamer: mint(gauge_rewards)
    steamer-->>-spm: STEAM tokens

    spm->>+spm: distributeRewards(tokens)
    note over spm: calculate distribution<br>based on weights

    spm->>+spc: notifyRewardAmount(token, amount)
    note over spc: update reward data<br>and distribution rate
    spc-->>-spm: confirmation

    spm->>+spl: notifyRewardAmount(token, amount)
    note over spl: update reward data<br>and distribution rate
    spl-->>-spm: confirmation

    spm->>keeper: return claimable amounts
    note over keeper, spm: rewards now available<br>in respective pools
    spm-->>-keeper: transaction complete
```

<!-- ## Overview

The gauge claim process involves several contracts working together to:

1. Calculate eligible rewards
2. Mint new tokens through the TokenMinter
3. Distribute these tokens to various rebalance pools according to their weights
4. Make rewards claimable by users who have staked in these pools

The VotingEscrow system provides boosting mechanics that can increase rewards for users who have locked tokens. -->
