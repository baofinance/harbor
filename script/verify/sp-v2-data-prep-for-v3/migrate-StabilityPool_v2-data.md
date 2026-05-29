# StabilityPool v2 accumulator data migration (prep for v3)

Force-migrate every stability pool's per-user reward data from the legacy **V1**
(`uint192` integral) format to the **V2** (`uint256` integral) format, then restore each
pool to its current `StabilityPool_v2` implementation.

## Why

When the pools went v1 → v2, the reward integral was widened to `uint256`. To avoid
disrupting users, v2's accumulator lazily migrates a user's data on first interaction and
keeps a **V1 read-fallback** for those not yet touched
(`MultipleRewardCompoundingAccumulator_v2._getUserRewardSnapshot`). That fallback can only
be removed safely once **every** remaining user is in V2 format.

This step force-migrates the stragglers so a later `StabilityPool_v3` upgrade can delete the
fallback. **It ends on v2** — it does not upgrade to v3. The migration is a pure storage
copy: no user-visible value (balance, claimable, claimed, withdrawal request) changes.

Key facts (verified):

- The V1 mapping is **never written** by v2 — so the set of users needing migration was
  frozen at the v1→v2 upgrade and can only shrink (users self-migrate on interaction). New
  depositors are born directly in V2.
- `remediate` is a **pure copy** (V1 integral/timestamp/pending → V2), idempotent (skips
  already-migrated and no-V1-data entries). The old V1 slot is never modified.
- The migration covers **active + historical** reward tokens: a user can carry V1 data for a
  no-longer-active token, and `_checkpoint` snapshots both.

## Pieces

| File | Role |
|------|------|
| `collect-sp-holders` | Discover holders per pool via Etherscan `UserDepositChange` logs → `tmp/sp-holders/<saltKey>.txt` |
| `../../Migrate_StabilityPool_v2_Data_mainnet.s.sol` | The migration: per pool, queue upgrade→ForceMigrate, `remediate(tokens, holders)`, restore→v2. Reads the holder files. |
| `MigrateCaptureTest.t.sol` | **Prong A** (black-box): capture all pool/holder state + interactions to JSON for a before/after diff |
| `MigrateBalancesTest.t.sol` | **Prong B** (white-box): upgrade→ForceMigrate, assert `balances()` copies V1→V2 correctly |
| `run-migrate-StabilityPool_v2-data` | Local end-to-end verification driver |

Holder discovery uses `UserDepositChange(owner,…)` — the event emitted whenever an account is
checkpointed (deposit→receiver, withdraw→sender, liquidation→account). The distinct `owner`
set is exactly the accounts that may carry V1 data. (Over-approximation is harmless:
`remediate` skips accounts with no V1 data.) This was cross-checked against the holder list
hardcoded in `script/test/MainnetForkUpgradeTest.t.sol`: the discovery set is complete and
precise (it found real holders that list missed, and the addresses that list had but discovery
did not were verified to have zero `UserDepositChange`/`Deposit`-as-receiver events).

## Local verification (one command)

Start nothing first — the runner prompts you. It regenerates holders, captures before, runs
both prongs + the real migrate script against a local anvil fork, captures after, and diffs.

```bash
script/verify/sp-v2-data-prep-for-v3/run-migrate-StabilityPool_v2-data
# options: --block <n|latest> (default 25186514, matched to discovery), --include <pool-filter>
```

What it does, in one anvil session (`forge test` forks in-memory; `run-script --broadcast
--local` persists to anvil — so the order is correct without cycling anvil):

1. Discover holders → `tmp/sp-holders/` (Etherscan, `--to-block <fork block>`).
2. **Prong A**: `VERSION=before` capture → `tmp/before/{pre,post}/*.json`.
3. **Prong B**: `MigrateBalancesTest` asserts the V1→V2 copy on the un-migrated node.
4. Run the **actual** `Migrate_StabilityPool_v2_Data_mainnet` (`--broadcast --local`) — this
   persists upgrade→remediate→restore to anvil.
5. **Prong A**: `VERSION=after` capture → `tmp/after/{pre,post}/*.json`.
6. `diff -ru tmp/before tmp/after` — **MUST be empty** (the migration changed nothing
   observable). `meld tmp/before tmp/after` if available.

The empty diff also proves the pure-copy ≡ on-demand equivalence: "before" reads unmigrated
users via the V1 fallback, "after" reads the same users via pure-copied V2 data.

## Producing the mainnet Safe batch

```bash
# 1. Discover holders (fixed --to-block for reproducibility)
script/verify/sp-v2-data-prep-for-v3/collect-sp-holders --to-block <block>

# 2. Build the Safe batch JSON (no --local: writes deployments/mainnet/batch/*.json)
script/run-script Migrate_StabilityPool_v2_Data_mainnet --salt harbor_v1 --network mainnet --broadcast
```

The holder lists are embedded in each pool's `remediate` calldata in the batch JSON, so the
exact migrated set is auditable in the transaction the Safe signs.

## Re-run / completeness check (after the Safe batch executes)

The needs-migration set is frozen and can only shrink, so a post-execution re-run cannot find
genuinely-new users that need migration — it catches a *discovery miss*. To verify:

```bash
# Re-discover up to a later block, into a separate dir, and diff.
script/verify/sp-v2-data-prep-for-v3/collect-sp-holders --to-block latest --out-dir tmp/sp-holders-rerun
diff -ru tmp/sp-holders tmp/sp-holders-rerun
```

Any address present only in the re-run is either a user who self-migrated in the interim
(harmless — already V2) or a new depositor (born in V2). If you want to be certain none carry
unmigrated V1 data, run `MigrateBalancesTest` (Prong B) against a fork with the re-run holder
files: it flags any holder with `oldIntegral != 0 && newIntegral == 0`.

## Notes

- `tmp/sp-holders/` is ephemeral (gitignored). The runner regenerates it; the mainnet flow
  regenerates it in step 1 above.
- Fork block default (`25186514`) is kept in sync between `collect-sp-holders` (`TO_BLOCK`) and
  the runner (`BLOCK`) so the verification forks exactly the state the holders were found in.
