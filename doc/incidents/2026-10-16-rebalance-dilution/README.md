# Rebalance dilution exploits — 2026-10-16

Two markets were exploited the same way on 2026-10-16, 124 blocks apart, by different senders:

| Market | Figures | Every account's change, in wei | With the new contracts | Every holder, from the exploit to the pause |
|---|---|---|---|---|
| BTC::stETH | [BTC-stETH-figures.md](BTC-stETH-figures.md) | [BTC-stETH-accounts.csv](BTC-stETH-accounts.csv) | [BTC-stETH-new-contracts.md](BTC-stETH-new-contracts.md) | [BTC-stETH-holders.md](BTC-stETH-holders.md) |
| EUR::stETH | [EUR-stETH-figures.md](EUR-stETH-figures.md) | [EUR-stETH-accounts.csv](EUR-stETH-accounts.csv) | [EUR-stETH-new-contracts.md](EUR-stETH-new-contracts.md) | [EUR-stETH-holders.md](EUR-stETH-holders.md) |

Every figure is in those files. They are generated from the chain by
`script/verify/incidents/run-rebalance-dilution-report`, which checks a market's files before writing them. It reads
the holder captures at each exploit's block and at the pause (`holders-<block>/`, written by
`script/holders/capture-holders`), and the logs of each market's contracts from the exploits to the pause
(`logs-<from block>-<to block>/`, written by `script/holders/capture-logs`). This page explains the figures and carries
none of its own. [holder-stories.md](holder-stories.md), written by hand from the holders files, tells each holder's
story, with rounded figures and a proposed treatment for each.

## Summary

- **What happened.** In one transaction per market, the caller diluted the holders of the market's leveraged token and
  took most of the value they lost. The protocol's fee receivers took the rest as fees.
- **The cause.** Once the collateral ratio is at or below 20/19, Minter_v2 pays the leveraged stability pool a flat 20
  leveraged tokens per pegged token in a rebalance, whatever the leveraged token is worth. Each caller pushed the ratio
  to that point, triggered the rebalance, and owned nearly all of the pool that received the new leveraged tokens.
- **The attack is reproduced in a fork test.** Three mitigations were measured against it:
  - a larger early-withdrawal fee — **not a fix**;
  - refusing leveraged redemption below a collateral ratio of 1.10 — **stops it**;
  - Minter_v3 — **fixes the cause**.
- **Every market's stability pool manager is now paused.** As of block 26,241,140 (2026-10-21), each manager's proxy
  points to the deployed `BaoPauser_v1` (`script/Pause_AllStabilityPoolManagers.s.sol`), so no rebalance can run.

## What each transaction did

Each figures file lists its transaction's steps with their amounts ("What the transaction did"). Both followed the
same outline:

1. **Borrowed wrapped collateral** in a flash loan.
2. **Minted leveraged tokens, then pegged tokens.** The leveraged mint came first and raised the collateral ratio.
3. **Deposited the pegged tokens in the leveraged stability pool**, becoming nearly all of it.
4. **Redeemed leveraged tokens in many slices**, each smaller than the last. This lowered the collateral ratio to 20/19
   or below. Leveraged redemption is allowed all the way down to a ratio of 1.00. Why it took so many slices is still
   to be investigated.
5. **Called `rebalance`**, which anyone may call.
   - The collateral pool's pegged tokens were converted at the fair rate.
   - The leveraged pool's were converted at the capped rate of 20 leveraged tokens per pegged token.
6. **Cashed out.** It claimed the new leveraged tokens and redeemed them, withdrew its deposit (paying the
   early-withdrawal fee) and redeemed it, repaid the loan, and paid out the rest.

The differences:
- **Who was paid.** The BTC::stETH transaction paid its own sender. The EUR::stETH transaction paid another account.
  Each figures file names the accounts its transaction paid ("paid by the exploit").
- **How it ran.** The EUR::stETH transaction deployed its contract in the same transaction.
- **Size.** The two markets differ in size, and so do the loans, mints and slices.

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
  overpays the pool, and every other leveraged holder is diluted by the difference. Each figures file shows the rate
  paid against the fair rate.
- **Minter_v3 converts at the fair rate at every collateral ratio**
  (`src/minter/library/MinterAdjustments_v1.sol:671-694`). Each new-contracts file shows the exploit against it.

Three things let one transaction exploit it:
- anyone can call `rebalance` (StabilityPoolManager_v1, and v2 too);
- leveraged redemption is allowed down to a collateral ratio of 1.00, so a trader can push the ratio into the capped
  zone;
- each market was small enough for a flash loan to dominate it.

## Who lost

Each figures file values every party before and after its transaction, and the rows sum to zero.
- **The loss fell on leveraged tokens held outside the pools.** Their price fell with the dilution.
- **Depositors in the leveraged pool other than the caller gained a little**, because they shared in the overpaid
  leveraged tokens.
- **The collateral pool's depositors lost only the rebalance bounty**, because their conversion was fair.
- **Gains went to the caller, the accounts it paid and the fee receivers.** One multisig is configured for every fee
  role: the minter's fee receiver, both pools' early-withdrawal fee address, and the manager's fee receiver for the
  harvest cut. There was no harvest in either transaction, so no cut was taken.

### Correcting the balances

Each accounts file lists every account whose holdings changed in its market, losers and gainers alike, one row per
position and token:
- **Positions:** the wallet; the leveraged pool deposit and rewards; the collateral pool deposit and reward.
- **Columns:** the amount the contracts reported just before the transaction and just after it, and the change, all
  in wei.
- **The change in value,** in pegged-unit wei and in wrapped-collateral wei.

How the values are worked out:
- **The reference is the state just before the transaction, at its block's time.** A correction undoes that
  transaction's effect on each account. Rewards that stream over time are read as at that moment. A chain read at the
  end of the previous block shows them slightly lower, by what streamed in the 12 seconds between, which the
  transaction did not cause. Undoing the whole transaction, rather than only its overpayment, is what the new
  contracts would have done: replayed on the market upgraded to them, the transaction changes nothing (each
  new-contracts file). That undoing is, row by row, the reverse of the accounts file.
- **Each position is valued in wrapped collateral at its own end's prices.**
  - A wrapped-collateral position counts its own amount, so its value change equals its token change exactly.
  - Any other position counts its amount times the minter's price for its token, over the oracle's price for the
    wrapped collateral, floored to the wei.
  - For a leveraged token held in a wallet the amount does not change, and the loss is all in value: the amount times
    the fall in the leveraged price.
- **The rows add up.** An account's figures in its figures file are the sums of its rows in the accounts file, to the
  wei. The file also carries each change in pegged-unit wei, the unit the generator's books check uses.

Each figures file also reconciles its caller's gain flow by flow, against what the transaction paid out:
- what it lost in the leveraged pool;
- the leveraged tokens it claimed;
- the rebalance bounty;
- the dilution of the leveraged tokens it still held at the rebalance;
- the fees it paid.

### From the exploit to the pause

Each holders file follows every holder of its market from just before the exploit to the block in which the minters
and the pools were paused:
- **Readings.** Every party is read just before the exploit's transaction, just after it, at the end of every later
  block in which the market's contracts logged anything, and at the end of the block before the pause.
- **Actions.** What each party did in between is decoded from the captured logs: minting, redemptions, deposits,
  withdrawals, claims, transfers and rebalance bounties, with the price of each minting or redemption of leveraged
  tokens.
- **Genesis participants.** The genesis contract holds the tokens of the participants who have not claimed them. Each
  such participant is followed for its own claim.
- **Values.** As in the figures files, except that after the exploit the wrapped collateral in a wallet is left out:
  it also moves for reasons outside the market.
- **Checks.** At every reading the parties hold the pegged and leveraged supplies. Between readings, every wallet's
  token change is the net of its captured transfers. At the pause block, the minter and both pools are paused.

## Mitigations

`test/deployment/RebalanceDilution.t.sol` tests each mitigation against the BTC::stETH exploit, two ways:
- **replaying the attacker's own transaction**;
- **running a rebuilt attacker** that pursues the same goal against the mitigated market
  (`test/deployment/RebalanceDilutionFork.sol`).

The rebuilt attacker is first shown to reproduce the exploit on the market as deployed, so its failure under a
mitigation means something. Each figures file's "Mitigations" table runs the same scenarios against its own market,
with that market's exploit's own mints and loan.

### A larger early-withdrawal fee is not a fix

- **A prepared attacker pays nothing.** A deposit cancels only its sender's withdrawal request, and requesting a
  withdrawal needs no balance. So a contract that requested a withdrawal one withdrawal delay earlier can receive the
  attacker's deposit and withdraw it, fee-free, inside its open window.
- **That attacker gains more than the real one did**, because it also avoids today's fee.
- **Holders are diluted either way.** The fee changes only who keeps the proceeds.
- Each figures file gives the break-even fee for an attacker who withdraws normally.

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
  - Leveraged token holders cannot redeem below the floor.
- **EUR::fxUSD is an exception** (see the "Every market" table).
  - Its next redeem leveraged bound is below 1.10, so the bands below 1.10 must merge into the refused band.
  - Its rebalance threshold is below 20/19, so every rebalance there pays the capped rate, whoever triggers it. The
    floor does not change that; raising the threshold would, with its pegged-mint floor moved up too.

### Minter_v3 needs the whole market upgraded with it

- **The manager must move with the minter.** StabilityPoolManager_v1 calls `redeemPeggedForCollateralRatio(uint256)`,
  which Minter_v3 replaced with a five-argument version.
- **Both pools must move with the manager.** StabilityPoolManager_v2 calls `maxAssetLoss()`, which only
  StabilityPool_v3 has.
- **The test upgrades all four together, in place**, by the upgrade script's own function (see below), so the manager
  keeps its rebalance threshold and bounty. The rebuilt attacker still reaches the capped zone and still triggers the
  rebalance, but it is paid the fair rate and loses.

### The exploits against the new contracts

Each new-contracts file upgrades its market just before its exploit by `UpgradeMarketToV3.upgradeMarketsToV3`
(`script/src/UpgradeMarketToV3.sol`), the function the upgrade script `script/Upgrade_MarketsToV3_mainnet.s.sol`
runs. It upgrades in place, as production will: the minter to Minter_v3, each pool through
`StabilityPool_v3_Upgrader` with every holder in the capture and the pool's ledger gap, and the manager to
StabilityPoolManager_v2 at its own address. The pools are StabilityPool_v3 with StabilityPool_v2's claim functions put
back, because the exploits call them.
- **The upgrade moves no token.** Every holder's wallet and deposits read the same before and after it, and each
  reward the same to within the rounding the file derives.
- **The exploit's own transaction changes nothing.** Paid the fair rate, it cannot repay its flash loan, and a trace
  shows it reverting there.
- **Without a flash loan the attack still runs, and loses.** The rebuilt attacker, with the loan as its own capital,
  triggers the rebalance at the fair rate; the file shows every party's gain or loss, as the figures file does for the
  exploit.

## Exposure of the other markets

Every market runs Minter_v2 with StabilityPoolManager_v1. Each figures file's "Every market" table shows every market
at its exploit's block:
- its rebalance threshold and refusal bounds;
- its leveraged price and holders' value;
- how much a rebalance at 20/19 would overpay its leveraged pool.

## Recommendations

1. **Keep the managers paused until a fix is in place.** Unpausing reopens the hole.
2. **Refuse leveraged redemption below a collateral ratio of 1.10 on every Minter_v2 market** before unpausing, if
   Minter_v3 is not yet deployed. This is a config change only. EUR::fxUSD needs its own edit.
3. **Bring the Minter_v3 deployment forward.** Upgrade the minter, the manager and both pools together, with
   `script/Upgrade_MarketsToV3_mainnet.s.sol`. This is the fix for the cause.
4. **Do not rely on a larger early-withdrawal fee.** An attacker who prepares one withdrawal delay ahead avoids it.
5. **Decide on compensation** for the accounts listed in the two accounts files, each followed to the pause in its
   holders file.

## Reproducing

- The tests: `forge test --no-dynamic-test-linking --deny never --match-path test/deployment/RebalanceDilution.t.sol -vv`
- The figures: `script/verify/incidents/run-rebalance-dilution-report`

Both need `MAINNET_RPC_URL` on an archival node.
