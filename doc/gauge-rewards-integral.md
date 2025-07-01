<!-- # Gauge Claim Flow

This diagram illustrates the sequence of operations during a gauge claim in the rebalance pool system. -->

```mermaid
---
config:
  mirrorActors: false
---
sequenceDiagram
    autonumber
    actor keeper as Rebalancer (keeper)
    actor depositor
    participant ve as veSTEAM
    participant spm as StabilityPool<br>Manager
    participant sp as StabilityPool<br>collateral/steamed
    participant gauge
    %%participant steamer as STEAM Minter

    %%participant minter as Minter
    %%participant reserve as ReservePool

    depositor->>+sp: deposit/withdraw
    note over depositor,sp: deposit into, withdraw from or transfer zheTOKEN into/from StabilityPool<br>stabilityPool has the integrals for depositor balances
    sp->>+gauge: deposit/withdraw
    gauge-->>-sp: gauge.balanceOf(stabilityPool) increases/decreases
    sp-->>-depositor: StabilityPool.balanceOf(depositor) increases/decreases

    keeper->>+spm: rebalance
    spm->>+sp: sweep
    sp->>+gauge: withdraw
    note over keeper,gauge: rebalance liquidations become withdrawals from the gauge, so the gauge manages the stabilityPool balance integrals<br>also no issue with emptying the pool and starting a new stability pool epoch
    gauge-->>-sp: gauge.balanceOf(stabilityPool) increases/decreases
    sp-->>-spm: zheTokens that are redeemed by Minter
    spm-->>-keeper: rebalance bounty

    depositor->>+ve: lock/unlock STEAM
    note over depositor,ve: locks STEAM for veSTEAM
    ve-->>-depositor: veSTEAM

    depositor->>+sp: claim
    sp->>+gauge: claim
    gauge-->>-sp: rewards for stabilityPool
    note over gauge, sp: stabilityPool has the depositor balance integral and the reward
    sp->>+ve: query ve balance integral
    ve-->>-sp: ve balance integral
    note over ve, sp: stabilityPool has the ve boost integral for depositor
    sp-->>-depositor: rewards for depositor

```

<!-- ## Overview

The gauge claim process involves several contracts working together to:

1. Calculate eligible rewards
2. Mint new tokens through the TokenMinter
3. Distribute these tokens to various rebalance pools according to their weights
4. Make rewards claimable by users who have staked in these pools

The VotingEscrow system provides boosting mechanics that can increase rewards for users who have locked tokens. -->
