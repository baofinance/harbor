# Rebalance dilution exploit — BTC::stETH, 2026-10-16

Every figure is in [2026-10-16-rebalance-dilution-figures.md](2026-10-16-rebalance-dilution-figures.md). That file
is generated from the chain by `script/verify/incidents/run-rebalance-dilution-report`, and checks itself before it
is written. This page explains the figures and carries none of its own.

## Summary

- **What happened.** In one transaction, the caller diluted the holders of hsSTETH, BTC::stETH's leveraged token, and
  took most of the value they lost. The protocol's fee receivers took the rest as fees.
- **The cause.** Once the collateral ratio is at or below 20/19, Minter_v2 pays the leveraged stability pool a flat 20
  leveraged tokens per pegged token in a rebalance, whatever the leveraged token is worth. The caller pushed the ratio
  to that point, triggered the rebalance, and owned nearly all of the pool that received the new leveraged tokens.
- **The attack is reproduced in a fork test.** Three mitigations were measured against it:
  - a larger early-withdrawal fee — **not a fix**;
  - refusing leveraged redemption below a collateral ratio of 1.10 — **stops it**;
  - Minter_v3 — **fixes the cause**.

## What the transaction did

The figures file lists every step with its amounts ("What the transaction did"). In outline:

1. **Borrowed wrapped collateral** in a flash loan.
2. **Minted leveraged tokens, then pegged tokens.** The leveraged mint came first and raised the collateral ratio.
3. **Deposited the pegged tokens in the leveraged stability pool**, becoming nearly all of it.
4. **Redeemed leveraged tokens in many slices.** This lowered the collateral ratio to 20/19 or below. Leveraged
   redemption is allowed all the way down to a ratio of 1.00.
5. **Called `rebalance`**, which anyone may call.
   - The collateral pool's pegged tokens were converted at the fair rate.
   - The leveraged pool's were converted at the capped rate of 20 leveraged tokens per pegged token.
6. **Cashed out.** It claimed the new leveraged tokens and redeemed them, withdrew its deposit (paying the
   early-withdrawal fee) and redeemed it, repaid the loan, and sent the rest to its sender.

## Cause

`Minter_v2._leveragedTokensForPegged` (`src/minter/Minter_v2.sol:1858-1883`) converts a pool's pegged tokens into
leveraged tokens during a rebalance:

```solidity
if (leverageRatio_ == _LEVERAGE_RATIO_CAP) {
    // cap the amount returned
    leveragedTokens = Math.mulDiv(peggedIn, _LEVERAGE_RATIO_CAP, 1 ether);
} else {
    leveragedTokens = Math.mulDiv(peggedIn * leveragedTokenBalance_, leverageRatio_, collateralTokenBalance_ * collateralPrice);
}
```

- **The fair amount** is the pegged value converted divided by the leveraged token's price. The uncapped branch
  computes exactly that.
- **The capped branch ignores the price.** The leverage ratio reaches its cap of 20 at a collateral ratio of 20/19,
  and from there the branch pays a flat 20 per pegged token.
- **The two rates match only when the leveraged price is 1/20 of a pegged unit.** At any higher price the capped branch
  overpays the pool, and every other leveraged holder is diluted by the difference. The figures file shows the rate
  paid against the fair rate.
- **Minter_v3 converts at the fair rate at every collateral ratio**
  (`src/minter/library/MinterAdjustments_v1.sol:671-694`).

Three things let one transaction exploit it:
- anyone can call `rebalance` (StabilityPoolManager_v1, and v2 too);
- leveraged redemption is allowed down to a collateral ratio of 1.00, so a trader can push the ratio into the capped
  zone;
- the market was small enough for a flash loan to dominate it.

## Who lost

The figures file values every party before and after, and the rows sum to zero.
- **The loss fell on leveraged tokens held outside the pools.** Their price fell with the dilution.
- **Depositors in the leveraged pool other than the caller gained a little**, because they shared in the overpaid
  leveraged tokens.
- **The collateral pool's depositors lost only the rebalance bounty**, because their conversion was fair.
- **Gains went to the caller and to the fee receivers.** One multisig is configured for every fee role: the minter's
  fee receiver, both pools' early-withdrawal fee address, and the manager's fee receiver for the harvest cut. There
  was no harvest in the transaction, so no cut was taken.

The figures file also reconciles the caller's gain flow by flow:
- what it lost in the leveraged pool;
- the leveraged tokens it claimed;
- the rebalance bounty;
- the dilution of the leveraged tokens it still held at the rebalance;
- the fees it paid.

## Mitigations

`test/deployment/RebalanceDilution.t.sol` tests each mitigation two ways:
- **replaying the attacker's own transaction**;
- **running a rebuilt attacker** that pursues the same goal against the mitigated market
  (`test/deployment/RebalanceDilutionFork.sol`).

The rebuilt attacker is first shown to reproduce the exploit on the market as deployed, so its failure under a
mitigation means something. The figures file's "Mitigations" table has the numbers.

### A larger early-withdrawal fee is not a fix

- **A prepared attacker pays nothing.** A deposit cancels only its sender's withdrawal request, and requesting a
  withdrawal needs no balance. So a contract that requested a withdrawal one withdrawal delay earlier can receive the
  attacker's deposit and withdraw it, fee-free, inside its open window.
- **That attacker gains more than the real one did**, because it also avoids today's fee.
- **Holders are diluted either way.** The fee changes only who keeps the proceeds.
- The figures file gives the break-even fee for an attacker who withdraws normally.

### Refusing leveraged redemption below a collateral ratio of 1.10

- **It is one config edit per market.** In the redeem leveraged band config, the bound of band 0 — the band where
  redemption is refused — moves from 1.00 to 1.10. Every ratio and every other config stays as it is.
  - Pegged minting is already refused below a bound just above each market's rebalance threshold (see "Every market").
  - Minting leveraged and redeeming pegged both raise the collateral ratio, so they need no floor.
  - A redemption that starts above the floor stops at it rather than reverting.
- **No trade can then take the ratio into the capped zone.** The rebuilt attacker stops at the floor, and the
  rebalance pays the fair rate.
- **Why 1.10.** It sits above 20/19 with room for a fall in the collateral price while an attacker waits at the floor.
  Refusing at the pegged-mint bound instead would stop leveraged redemption much earlier, and leave a market whose
  threshold is close to 20/19 with little margin.
- **Its limits.**
  - It does not stop a fall in the collateral price from reaching the capped zone, and a rebalance there still
    overpays the pool.
  - hsSTETH holders cannot redeem below the floor.
- **EUR::fxUSD is an exception** (see the figures file's "Every market" table).
  - Its next redeem leveraged bound is below 1.10, so the bands below 1.10 must merge into the refused band.
  - Its rebalance threshold is below 20/19, so every rebalance there pays the capped rate, whoever triggers it. The
    floor does not change that; raising the threshold would, with its pegged-mint floor moved up too.

### Minter_v3 needs the whole market upgraded with it

- **The manager must move with the minter.** StabilityPoolManager_v1 calls `redeemPeggedForCollateralRatio(uint256)`,
  which Minter_v3 replaced with a five-argument version.
- **Both pools must move with the manager.** StabilityPoolManager_v2 calls `maxAssetLoss()`, which only
  StabilityPool_v3 has.
- **The test upgrades all four together**, through the existing harness (`test/harness/DeployedMarket.sol`), and
  restores the deployed rebalance threshold and bounty.
- **The real transaction is not replayed under v3.** It calls the old manager, which cannot call Minter_v3, so the
  replay would fail whatever the conversion did. The rebuilt attacker carries the result: it still reaches the capped
  zone and still triggers the rebalance, but it is paid the fair rate and loses.

## Exposure of the other markets

Every market runs Minter_v2 with StabilityPoolManager_v1. The figures file's "Every market" table shows each market at
the exploit's block:
- its rebalance threshold and refusal bounds;
- its leveraged price and holders' value;
- how much a rebalance at 20/19 would overpay its leveraged pool.

## Recommendations

1. **Refuse leveraged redemption below a collateral ratio of 1.10 on every Minter_v2 market now.** This is a config
   change only. EUR::fxUSD needs its own edit.
2. **Bring the Minter_v3 deployment forward.** Upgrade the minter, the manager and both pools together. This is the
   fix for the cause.
3. **Do not rely on a larger early-withdrawal fee.** An attacker who prepares one withdrawal delay ahead avoids it.
4. **Decide on compensation** for the leveraged token holders listed in the figures file.

## Reproducing

- The tests: `forge test --no-dynamic-test-linking --deny never --match-path test/deployment/RebalanceDilution.t.sol -vv`
- The figures: `script/verify/incidents/run-rebalance-dilution-report`

Both need `MAINNET_RPC_URL` on an archival node.
