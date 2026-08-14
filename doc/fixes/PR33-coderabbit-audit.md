# PR #33 — CodeRabbit audit triage

Source: the CodeRabbit reviews on [PR #33](https://github.com/baofinance/harbor/pull/33), in two
rounds — six reviews of 2026-07-29 (round 1, below) and two more of 2026-08-08 and 2026-08-09
(round 2, at the end of this document). Regenerate with:

```bash
gh api "repos/baofinance/harbor/pulls/33/reviews?per_page=100" --paginate
gh api "repos/baofinance/harbor/pulls/33/comments?per_page=100" --paginate
```

Findings are keyed by CodeRabbit's own content hash (`cr-comment:v1:<id>`, truncated to 8
characters here). That hash is stable across review runs, so it — not file:line — is the
identity of a finding. Line numbers below are as they stood at review time, against commit
`4c05265`; the code has moved since (`Minter_v3.sol` by ~125 lines), so treat them as
historical pointers rather than current locations.

## Where this stands

Each round has its own summary table further down; this is the position across both, and is the
one to read first.

| | round 1 | round 2 | total |
|---|---|---|---|
| Findings, unique by content hash | 70 | 16 | **86** |
| ✅ need no further work | 69 | 16 | **85** |
| ❌ outstanding | **1** | – | **1** |

**One finding remains: `56e24c6a`** — deploy-script test coverage, from round 1. Its entry is under
[config](#config-10), its fix prompt is in the appendix, and what the deploy-stack refactor did and
did not do for it is measured in the section following that table. Short version: the refactor has
landed and **closed none of the three files**, though it took the per-contract deploy modules to
100%; and before anything is written against `HarborDeployer`, its contradictory coverage metrics
need explaining rather than chasing.

Round 1 raised 107 finding-instances across its six reviews, which deduplicated to 70 by content
hash; 11 of those were semantic duplicates of another finding, leaving 59 genuinely distinct
issues. Severity as reported was 2 Critical, 66 Major, 1 Minor, 1 Trivial — CodeRabbit labelled
almost everything Major, so severity carries no useful signal here and is not used to order this
document.

## Status vocabulary

A ✅ marks a finding that needs no further work — fixed, refuted, already counted elsewhere, or
deliberately declined. A ❌ marks one that is still outstanding.

| Status | Meaning |
|---|---|
| ✅ **done** | Fixed, verified against current code, commit cited |
| ❌ **open** | Confirmed still present |
| ❌ **decide** | Confirmed still present; fixing it is a design decision, not a defect |
| ✅ **false-positive** | Verified not to be a defect — evidence cited |
| ✅ **duplicate** | Same issue as another entry |
| ✅ **won't-fix** | Deliberately not fixed — reason given |

# Round 1 — the six reviews of 2026-07-29

## Summary

| Area | Total | ✅ done | ❌ open | ❌ decide | ✅ false-positive | ✅ duplicate | ✅ won't-fix |
|---|---|---|---|---|---|---|---|
| src | 4 | 3 | – | – | – | – | 1 |
| test | 6 | 3 | – | – | 3 | – | – |
| config | 10 | 2 | 1 | – | 2 | 1 | 4 |
| script (live) | 5 | 4 | – | – | – | 1 | – |
| script (archive) | 20 | 4 | – | – | – | 3 | 13 |
| doc | 25 | 6 | – | – | – | 5 | 14 |
| **Total** | **70** | **22** | **1** | **–** | **5** | **10** | **32** |

**1 of round 1's findings is outstanding**: `56e24c6a`, deploy-script test coverage. The other 69
need no further work. Its fix prompt is reproduced in the appendix.

Five findings turned out to be false positives, and the pattern is worth recording: CodeRabbit
reads a single file without the surrounding system, so it reported a CI check as deleted when
it had moved into the composite action being called, a test suite as not covering v3 when its
mock inherits v3, and a directory as an input when it is generated output. One of the five,
`077b539f`, would additionally have broken a working script had its fix been applied as written.

---

## src — contract code (4)

| id | location | finding | status |
|---|---|---|---|
| `41193653` | `Minter_v3.sol:2038-2061` | Oracle fetch helpers declare `ZeroOraclePrice`/`InvalidOracle` but never perform the check | ✅ **done** — `2e06a58`; `_fetchOracle` now reverts `ZeroOraclePrice`/`ZeroOracleRate`, callers routed through `_fetchMidPrice`/`_fetchMinRate` |
| `ecc6d23f` | `StabilityPool_v3.sol:616-622` | Unchecked signed↔unsigned casts around `rewardDivisorGap`, three sites | ✅ **done** — `17ec549`; all three now use `SafeCast` |
| `39f62036` | `StabilityPoolManager_v2.sol:534` | No sum check or migration for legacy ratios before `residualRatio` is computed | ✅ **won't-fix** — `def46d7` fixed the setter half (`updateHarvestRatios` enforces `bounty + cut <= 1e18` atomically, replacing two independently-validated setters that could drift). A runtime guard in `harvest()` is not needed: every existing deployment has been verified compliant with those bounds, so the underflow state is unreachable. The residual risk is that a ratio changes between that verification and the deploy script running — which is a **deployment-time check, not a contract change**. Tracked separately as a deployment-checker requirement, owned by another conversation |
| `43738187` | `Minter_v3.sol:753-765` | Capped mint returns `(0, 0)` without honouring `minPeggedOut` | ✅ **done** — the capped path now returns `(0, 0)` only when `minPeggedOut` is zero; otherwise it falls through to the existing `MintInsufficientAmount` check, which a zero output can only fail. Reusing that one revert site rather than adding a second kept the cost to **7 bytes** (margin 134 → 127). The contradicting docstring on `IMinter_v3.mintPeggedToken` was corrected, and the implementation's duplicate copy of it replaced with `@inheritdoc`. Covered by `test_mintPegged_feeCappedStillHonoursMinPeggedOut` (confirmed failing before the fix) and `test_mintPegged_feeCappedReturnsZeroWhenNoMinimumDemanded`, which pins the graceful zero for `minPeggedOut == 0` — the capped overload previously had no tests at all |

## test (6)

| id | location | finding | status |
|---|---|---|---|
| `9cc381b9` | `RebalanceFairnessScan.t.sol:285-287` | `_gapPct` underflows when `lower > higher` | ✅ **done** — `ad70356`; helper now clamps `lower >= higher` to 0, so every call site is safe |
| `4d347ef0` | `Genesis.t.sol:234-244` | `test_nullGenesis` calls `endGenesis` without granting `zeroFeeRole`, so it will revert | ✅ **false-positive** — `test_nullGenesis` passes. A null genesis has nothing to mint, so the Minter's zero-fee path is never reached |
| `cd76dc8c` | `StabilityPoolEnvelope.t.sol:619-630` | `test_widthCorner_depositBeyondUint128Reverts` lacks the supply-cap guard its siblings have; the cap should bind first on `ethScale`/`eurScale` | ✅ **false-positive** — the test passes on all 13 market configurations, including the two named |
| `2154e67c` | `IMockMultipleRewardCompoundingAccumulator.sol:18-27` | `userRewardSnapshot` widening not propagated to the mock interface | ✅ **done** — `pending`/`claimed_` widened to `uint256` to match the v3 accumulator. Widening made the compiler name the two places the truncation was actually reached, `MultipleRewardCompoundingAccumulator.t.sol:883` and `:927`, both of which declared `uint128` receivers; both now read `uint256`. The reverse direction is lossless (a v2 mock's `uint128` return is ABI-padded to 32 bytes), so the v2 mock needs no change. 31 accumulator tests pass |
| `4eefe8f5` | `Rebalance.t.sol:10-12` | Duplicate `IStabilityPool` import | ✅ **done** — duplicate removed. CodeRabbit's stated consequence was wrong (Solidity accepts a repeated identical import and the repo compiled), so this was cosmetic, not a build break |
| `7560604f` | `LinearMultipleRewardDistributor.t.sol:31-40` | Suite only instantiates the v3 mock, so `LinearMultipleRewardDistributor_v2` is unexercised | ✅ **false-positive** — both halves are wrong. The suite does exercise the real v3: `MockLinearMultipleRewardDistributor_v3 is LinearMultipleRewardDistributor_v3` and overrides exactly one member, `_accumulateReward`, replaced with an event so the test can observe it fired — rate, period bounds, queueing and role checks all run production code. And v2 is still exercised, just elsewhere: `LinearMultipleRewardDistributor_v2` has one consumer, `MultipleRewardCompoundingAccumulator_v2.sol:13`, reached in tests via `AccumulatorClaimableEquivalence.t.sol:48` |

## config (10)

| id | location | finding | status |
|---|---|---|---|
| `2ec5976e` | `.claude/settings.json:7-9` | Allowlist exposes other local repos and `~/.claude/**` | ✅ **done** — `2b3bdeb`; the rule granting read access to every sibling repository under the developer's home directory was removed, and the `~/.claude/**` rule narrowed to `plans/**` plus this project's own directory |
| `5b4d32ae` | `.claude/settings.json:7` | CWE-732: constrain permissions to minimum scope | ✅ **duplicate** of `2ec5976e` |
| `87c9d0d1` | `.claude/settings.json:22` | Remove the `~/.claude/plans` git allow rules | ✅ **won't-fix** — `lib/bao-base/CLAUDE.md` *requires* committing to the plan repo after every plan update ("you own its git, and committing there is required"). Removing the rule would break the documented working mode. The remaining rule is already an exact command with a fixed argument, which is what the sibling finding asked for |
| `ea436f80` | `.claude/settings.local.json:6` | `Bash(chmod:*)` grants chmod on any path | ✅ **done** — rule removed, so chmod now requires approval. Removing rather than narrowing avoids guessing a scope: a rule can be re-added against a real path if one proves necessary. Whether this machine-local file should be git-tracked at all remains an open question, carried in the plan |
| `0a5116c7` | `CI-test-foundry-stable.yml:40-41` | Audited-source verification step removed before invoking the submodule action | ✅ **false-positive** — the check was not removed, it moved *into* the action being invoked: [`test-foundry/action.yml:94-101`](../../lib/bao-base/.github/actions/test-foundry/action.yml) runs a "Check audit and deployed code" step calling `yarn verify-audit`. CodeRabbit read only the workflow file and could not see inside the composite action it calls |
| `077b539f` | `foundry.toml:70` | `read-write` granted on the git-tracked holder-input directory | ✅ **false-positive** — the premise is wrong. That directory holds the *filtered output* of `FilterSpHolders.s.sol`, not its input: inputs are read from the untracked `tmp/sp-holders` ([FilterSpHolders.s.sol:48](../../script/Migrate_StabilityPool_v2_Data_mainnet/FilterSpHolders.s.sol#L48)) and the results written back to the tracked directory, which is git-tracked *deliberately* — "the filtered files are git-tracked: they form the auditable record of which holders were included in the migration batch and which were skipped" (lines 19-21). Write access is required by design; both prescribed remedies would break it — read-only stops `run()` writing at all, and relocating the output to `./tmp` destroys the audit record that tracking exists to preserve |
| `23d31d75` | `pyproject.toml:7` | Wake used but not declared | ✅ **won't-fix** — Wake is not part of the CI tooling yet; the Python testing of Solidity it supports is work in progress and not on any official path. Declaring it now would pin a dependency the build does not use. Revisit when Wake joins CI, at which point the `requires-python = "==3.10.*"` pin will need resolving against the 3.13 the bao-base tooling expects |
| `04f01408` | `scripts/deploy.py:3-6` | Literal `ENTER_NODE_URL_HERE` placeholder committed | ✅ **won't-fix** — same reason as `23d31d75`: Python testing of Solidity via Wake is work in progress and not part of any official process. The placeholder marks an entry point that is not yet wired up, not a broken deployment path |
| `56e24c6a` | `regression/coverage.txt:3` | `ForceMigrateAccumulator_v1.sol` 0%, `HarborDeployStack.sol` 75%, `HarborDeployer.sol` 53% | ❌ **open** — accepted: deployment is part of the production process, so the deploy scripts are tested alongside the contracts. Three files, three different problems, and the deploy-stack refactor has since landed **without closing any of them** — see the measured outcome below. `ForceMigrateAccumulator_v1` is **not** spent: the migration is pending (`StabilityPool_v3` appears 3 times across `deployments/` against `StabilityPool_v2`'s 105) and it *is* tested, by `script/verify/sp-v2-data-prep-for-v3/ForceMigrateAccumulatorTest.t.sol`, which needs a mainnet fork and so cannot join `yarn test`; its assembly slot arithmetic is unit-testable without a fork and is what should be covered |
| `9b58cc3b` | `regression/sizes.txt:48` | `Minter_v3` near the EIP-170 limit | ✅ **won't-fix** — no action needed: contract size is tracked by CI against `regression/sizes.txt`, so an overrun fails the build rather than surprising a deployment. Recorded for context: the margin was 182 B at review, 143 B at `HEAD~6`, and is **134 B** now — the oracle guards took a third of the remaining headroom, and `StabilityPool_v3` fell 775 B → 646 B. Changes to `Minter_v3` are size-budgeted from here on |

### `56e24c6a` after the deploy-stack refactor — what it actually moved

The refactor was sequenced ahead of this finding on the expectation that running test setups through
the deploy chain would exercise these files as a side effect. It landed, and the current
`regression/coverage.txt` says it did not:

| file | at review | now |
|---|---|---|
| `ForceMigrateAccumulator_v1.sol` | 0% (0/36) | 0% (0/36) — unchanged |
| `HarborDeployStack.sol` | 75% (43/57) | **69% (31/45)** — *fell* |
| `HarborDeployer.sol` | 53% (42/79) | 57% (45/79) |

The expectation was not wrong, only aimed at the wrong files. The gain landed on the per-contract
deploy modules, which is where the migrated setups actually spend their time:
`script/src/contracts/` now reads **100%** for `Minter.sol`, `StabilityPool.sol`,
`StabilityPoolManager.sol`, `Genesis.sol` and `LeveragedToken.sol`, with `PeggedToken.sol` at 85%.
`HarborDeployStack.sol` *fell* because it shrank — 57 lines to 45 — as R1-R4 folded configuration
into those modules; what left the file was the well-exercised part.

**Before any test is written against `HarborDeployer`, its numbers need explaining rather than
chasing.** Its four metrics contradict each other: lines 57% (45/79), statements **95% (70/74)**,
branches 100% (0/0), functions 14% (5/37). A file cannot be 95% exercised by statement and 14% by
function, and its 37 functions are almost all two-line `public` key/address resolvers on an
*abstract* contract reached through inheritance — both overloads of which are in real use across
`test/` and `script/`. The statement figure is the one consistent with how heavily the deploy path
is driven. So the line and function figures are suspect as a measurement of this file, and writing
tests to move them would be precisely the "make line X execute" work `CLAUDE.md` warns against —
gaming a number that a second number already contradicts.

That makes the first task diagnostic, not remedial: establish what forge is counting here. Only
then is it worth asking what behaviour of the deploy scripts is genuinely unverified, working from
what they are meant to do rather than from an uncovered-lines list.

## script — live tooling (5)

| id | location | finding | status |
|---|---|---|---|
| `46648263` | `Deploy_StabilityPool_v3_mainnet.s.sol:96-114` | Market configs constructed inside the broadcast scope | ✅ **done** — all six `create*MintersConfig()` calls now sit at lines 94-99, before `vm.startBroadcast()` at 101 |
| `174b8161` | `FilterSpHolders.s.sol:95-112` | `vm.readLine` returns `""` for both a blank line and EOF, silently truncating the holder list | ✅ **done** — now reads whole-file and splits on `\n` |
| `c1b76166` | `capture-sp-holders:206` | `mapfile` ignores process-substitution exit status, so a partial holder file can be written | ✅ **done** — `fetch_owners` output is now captured and its status checked (`if ! owners_found=$(...)`) before `mapfile` |
| `25e7819e` | `capture-sp-holders:206` | Same, phrased as owner discovery | ✅ **duplicate** of `c1b76166` |
| `bd238ceb` | `capture-sp-holders:206` | Same, and asks for the checked-producer pattern on `mapfile -t SALTS < <(pool_salts)` too | ✅ **done** — the `fetch_owners` half was already fixed; `SALTS` now uses the same capture-check-load pattern, so a failed state-file read aborts instead of reporting "0 stability pools". Doing so exposed a second defect: under `set -euo pipefail` the trailing `grep` in `pool_salts` returns 1 when nothing matches, which the new check could not distinguish from a real failure — the grep now admits no-match as the empty result it is while still propagating grep's error status 2. Verified against four cases: normal, no matching pools, malformed state file, missing state file |

## script — spent one-off migration artefacts (20)

These are runbooks and runners for migrations that have already executed. Default disposition
is **won't-fix**: correcting a path in a script that will never run again has no value. Several
were fixed anyway because they set a precedent for how future verification scripts are written.

Both **Critical** findings live here, and both are the same bug — `PROJECT_ROOT` resolving to
`script/` instead of the repository root — in runners that have already served their purpose.

| id | location | finding | status |
|---|---|---|---|
| `788773c5` | `minter-v2-upgrade/test-deploy:4-8` | `TEST_PATH` points at a nonexistent file | ✅ **done** — retargeted to `script/verify/minter-v2-upgrade/DeployMinters.t.sol`, usage comments updated |
| `b2d7ba9e` | `sp-v2-upgrade/genesis-end.md:21-29` | `ZERO_FEE_ROLE` derived by hashing the signature instead of read from the contract | ✅ **done** — now `cast call $MINTER "ZERO_FEE_ROLE()(uint256)"`, with a comment explaining it is a role bitmask, not a hashed signature |
| `01b80661` | `sp-v2-upgrade/genesis-end.md:21-30` | Same | ✅ **duplicate** of `b2d7ba9e` |
| `632f4917` | `spl-remediation/collect-holders:28-40` | End block defaults to latest, so reruns are not reproducible | ✅ **done** — documented and made explicit, citing `RebalanceCheck.t.sol`'s fork block |
| `c4804fa0` | `sp-v3-reward-divisor-migration/StabilityPoolMigrationPreflight.t.sol:175-184` | Negative gaps misclassified as stale holder lists | ✅ **done** — `seed` is now classified before `recapture` |
| `97023cbc` | `minter-v2-upgrade/run-upgrade-test-Minter_v2:4-7` | **Critical** — `PROJECT_ROOT` resolves to `script/`, so `./script/run-script` becomes `script/script/run-script` | ✅ won't-fix — spent one-off |
| `14ded316` | `spl-remediation/run-upgrade-test-remediate-ETH_fxUSD_SPL:4-7` | **Critical** — same bug | ✅ won't-fix — spent one-off |
| `1b73a1a4` | `spl-remediation/run-upgrade-test-remediate-ETH_fxUSD_SPL:5-7` | Same | ✅ **duplicate** of `14ded316` |
| `2622590e` | `minter-v2-upgrade/run-upgrade-test-Minter_v2:79-90` | Stale `script/test/...` references after the move to `script/verify/` | ✅ won't-fix — spent one-off |
| `ca62f98f` | `minter-v2-upgrade/run-upgrade-test-Minter_v2:79-90` | Same | ✅ **duplicate** of `2622590e` |
| `053b5ec0` | `spl-remediation/collect-holders:34-42` | `tokentx` query not paginated | ✅ won't-fix — spent one-off |
| `85a40434` | `minter-v2-upgrade/upgrade-Minter_v2.md:18-22` | Documentation paths not normalised | ✅ won't-fix — spent one-off |
| `5ca283ee` | `sp-v2-data-prep-for-v3/MigrateBalancesTest.t.sol:57-75` | Test passes vacuously when no holder files exist | ✅ won't-fix — spent one-off |
| `019fdddc` | `sp-v2-data-prep-for-v3/migrate-StabilityPool_v2-data.md:107-123` | Block headers not normalised before diffing | ✅ won't-fix — spent one-off |
| `833a2eea` | `sp-v2-data-prep-for-v3/migrate-StabilityPool_v2-data.md:75-84` | Completeness claim unsupported | ✅ won't-fix — spent one-off |
| `a256bd96` | `sp-v2-upgrade/epoch-removal-summary.md:93-109` | Stale v1/uint104 excerpts | ✅ won't-fix — spent one-off |
| `ad94cb20` | `sp-v3-migration/run-upgrade-test-remediate-accumulators:68-75` | `--match-path` points at a nonexistent test | ✅ won't-fix — spent one-off |
| `1f52c246` | `spl-remediation/rebalance-bug-remediation.md:121-125` | Compensatory-mint formula unverified | ✅ won't-fix — spent one-off |
| `d92076aa` | `spl-remediation/rebalance-remediation.md:78-91` | Duplicate bounty-burning step | ✅ won't-fix — spent one-off |
| `cbbcac3f` | `spl-remediation/rebalance-remediation.md:81-83` | `TODO: confirm ours` left on the bounty receiver address | ✅ won't-fix — spent one-off |

## doc (25)

### doc/frontend (13) — ✅ won't-fix: belongs in another repository

Integration documentation for frontend consumers. It does not belong in this repository, so
these are not fixed here; they move with the documentation.

| id | location | finding | status |
|---|---|---|---|
| `38f49611` | `claim.md:9-26` | Update the claim ABI to the v3 interface | ✅ won't-fix |
| `df535dfd` | `claim.md:9-26` | Same | ✅ **duplicate** of `38f49611` |
| `4aa09fe1` | `claim.md:41-46` | Format reward amounts using each token's decimals | ✅ won't-fix |
| `10ba8d94` | `claim.md:109-117` | Replace the outdated Minter ABI and calls | ✅ won't-fix |
| `d10d09b8` | `claim.md:111-117` | Add `maxFeeRatio` to the minter examples | ✅ won't-fix |
| `55883954` | `claim.md:194-199` | Fix the undefined variable in the proportional split example | ✅ won't-fix |
| `f0c57f82` | `claim.md:194-199` | Same | ✅ **duplicate** of `55883954` |
| `19f21952` | `display.md:23-46` | Fix the APR example before publishing it | ✅ won't-fix |
| `f6320b94` | `redeem.md:38-44` | Limit the `1e18` blocked-value rule to supported operations | ✅ won't-fix |
| `ffbfc808` | `stability-pool.md:24-52` | Include every documented claim overload in the minimal ABI | ✅ won't-fix |
| `4e2d4df3` | `stability-pool.md:279-297` | Pass `provider` into `getAllClaimableRewards` | ✅ won't-fix |
| `f3d57c65` | `tokens.md:11-17` | Correct the `rewardData` tuple order and fields | ✅ won't-fix |
| `ac1a14ff` | `troubleshooting.md:273-286` | Use the configured mock feed addresses | ✅ won't-fix |

### doc/guides (6) — ✅ won't-fix, except one resolved by code

| id | location | finding | status |
|---|---|---|---|
| `12c77243` | `fee-structure.md:145-169` | Require bounty plus cut to remain at or below 100% | ✅ **done** — resolved in code, not documentation. This is the same underlying issue as `39f62036`; `def46d7`'s `updateHarvestRatios` now enforces it |
| `254a085d` | `deployment.md:3-25` | Separate legacy deployment data from the v3/mainnet guide | ✅ won't-fix |
| `c57cb1a9` | `deployment.md:7-25` | Label these addresses as legacy v1 | ✅ **duplicate** of `254a085d` |
| `581cf512` | `deployment.md:17` | CWE-16 misconfiguration | ✅ **duplicate** of `254a085d` |
| `bb6d5dcf` | `oracle-price-feeds.md:41-48` | Document the protocol oracle's actual wstETH source | ✅ won't-fix |
| `f760e919` | `risk-parameters.md:107-110` | Alert before the configured rebalance threshold | ✅ won't-fix |

### doc — design documents (6) — ✅ resolved by reconciling each document with the code

These are not integration guides; each describes system behaviour. Every one turned out to be
a *stale document* rather than a system defect: in all four cases where the finding alleged a
flaw, the code already did the right thing and the prose had not kept up. Two of them
(`fea3d21a`, `ceeb58b9`) asked for the implementation to change — neither needed to.

| id | location | finding | status |
|---|---|---|---|
| `fea3d21a` | `DataEnvelope.md:103-114` | "Do not ship the known harvest-allocation flaw as an accepted behavior" | ✅ **done** — the flaw no longer exists, and the document was describing a version of the harvest that predates the fairness work. `StabilityPoolManager_v2` keeps a per-pool `owed` ledger ([lines 529-559](../../src/minter/StabilityPoolManager_v2.sol#L529)): a share deferred past one period's capacity stays with the pool that earned it and is never re-split; only genuinely *new* yield is allocated by current holdings. Prose corrected to match — no code change needed |
| `53af2580` | `DataEnvelope.md:103-107` | Reconcile the documented rebalance overflow behaviour | ✅ **done** — the document contradicted *itself*: line 106 said the rebalance clamps and defers, while lines 156 and 191 said it reverts past the integral. The code clamps up front (`_capLiquidation`, [lines 460-481](../../src/minter/StabilityPoolManager_v2.sol#L460)), whose own comment records that the reward path "could revert on overflow" *before* — so 156/191 were the stale side, not 106. Both corrected |
| `ceeb58b9` | `autocompounding-vault-design.md:223-227` | Reconcile the HarborYield valuation model | ✅ **done** — the "No oracle. All managed assets are assumed 1:1 pegged" invariant was stale in three places (lines 226, 335, 376). `ValuationLib._fairRateInPegUnits` values an AutoCompounder at its Minter's `peggedTokenPrice()` and an equivalent at the `IWrappedPriceOracle` registered by `addEquivalentVault`, drift-checked at registration. The accurate statement is that HarborYield takes no *global* oracle dependency, not that it is oracle-free; all three corrected |
| `182c6c4d` | `harbor-deployment.md:217-219` | Do not treat `1e12` base units as universally dust | ✅ **done** — the arithmetic in the finding is right (`1e12` base units is 1e-6 of an 18-decimal token but 10,000 whole tokens at 8 decimals), but the implementation never used that constant. `HarborYieldDeployStack` seeds `peg.minDeposit()` in *pegged* tokens and converts via the oracle in `_wrappedCollateralSeedAmount`, so it carries no `decimals()` assumption at all. The document's "`~1e12` wei" was the stale part; corrected to describe the config-driven mechanism |
| `b4e6f1f1` | `ideas/rebalance-fairness.md:443-459` | Use the combined fee in the attack example | ✅ **done** — internal inconsistency: the document defines `fee = mintPeggedRatio - redeemPeggedRatio` ≈ 2.0% at CR 1.20 and repeats that figure in its open questions, but the Bob walk-through and the comparison table charged only the mint ratio (1.5%). Walk-through and table corrected to 2.0% / 98.0. The combined formula remains a proposal — the pool implements a plain `earlyWithdrawalFee` — so this is consistency within the design, not a description of shipped behaviour |
| `2e1f09c3` | `ideas/rebalance-fairness.md:443-459` | Use one withdrawal-fee formula consistently | ✅ **duplicate** of `b4e6f1f1` |

---

# Round 2 — reviews of 2026-08-08 and 2026-08-09

Two further reviews, 16 findings across 15 inline comments (one comment stacks two findings).
Each was checked against `HEAD` on `harbor-yield`. The **status vocabulary is the same as round
1** — a ✅ marks a finding needing no further work, a ❌ one that is still outstanding — and the
status cell carries both the verification result and what closing it takes.

Round 2 reviewed a much smaller diff than round 1, and it shows in the composition: no finding
touches `src/`. Ten are documentation, three are multisig batch scripts, two are tests, one is
tooling configuration.

## Summary

| Area | Total | ✅ done | ❌ open | ❌ decide | ✅ false-positive | ✅ duplicate | ✅ won't-fix |
|---|---|---|---|---|---|---|---|
| test | 2 | 1 | – | – | – | 1 | – |
| config | 1 | 1 | – | – | – | – | – |
| script (multisig batches) | 3 | – | – | – | – | – | 3 |
| doc — this audit file | 3 | 3 | – | – | – | – | – |
| doc — design documents | 6 | 5 | – | – | – | – | 1 |
| regression artefact | 1 | 1 | – | – | – | – | – |
| **Total** | **16** | **11** | **–** | **–** | **–** | **1** | **4** |

**Nothing from round 2 is outstanding.** Round 1's `56e24c6a`, deploy-script coverage, is the
single remaining finding of the 86 raised.

Every documentation finding in this round is closed. They fell into one pattern worth naming: in
five of the six, the document **contradicted itself** rather than the code — one section had been
brought up to date and another left behind, so the correct statement was usually already present
elsewhere in the same file. `00dc864c` is the clearest case, being round 1's `182c6c4d` returning
because that fix corrected §7 and left §11 saying the opposite.

## Two things to know before reading the table

**CodeRabbit's own "✅ Addressed" footers are unreliable.** Three findings carry one, and only one
of the three had actually been addressed. The mark is attributed to commit *ranges* touching the
same file, not to a re-check of the finding, so any nearby edit satisfies it.

| id | claim | reality |
|---|---|---|
| `69c3be35` | Addressed in `9f166a0`..`3b4c8be` | **true** — the row exists at `regression/gas-duration.txt:167` and `MinterV1ToV2Upgrade.t.sol` is gone |
| `8cb85991` | Addressed in `9f166a0`..`46c12ef` | **false** — the absolute home paths were still in this document when the mark was applied |
| `00dc864c` | Addressed in `9f166a0`..`46c12ef` | **false** — the universal `1e12` recommendation is still at `doc/harbor-deployment.md:349` |

**For a multisig batch script, whether it has already executed decides the disposition.** These
scripts queue transactions into a Safe batch; three findings are about the human-readable label
beside a queued call, which is the only thing a signer reads when approving. Once the batch has
been signed and executed, the label has done all the harm or good it ever will and correcting it
edits the record of what was approved rather than anything anyone will see — won't-fix. All three
turned out to be in that state.

Establishing which is which is where this audit went wrong once, and the mistake is worth keeping.
The rule is sound: **executed** is provable from a tracked artefact under `deployments/<network>/batch/`,
whereas **pending is not provable from the absence of one** — and nothing under `deployments/local*/`
is evidence either way, `.gitignore:44` excluding it, so it records one machine's anvil run.

Having said that, `UpdateHarvestCut_MCAP` was then filed as pending on an inference that does not
hold: that mainnet still runs `StabilityPoolManager_v1` at all 26 sites, and the script's docstring
gates it to run *before* the v2 upgrade. Both are true and neither says the script has not run. The
script does not upgrade anything — it calls `updateHarvestCutRatio` on the *existing* v1 managers,
and running while v1 is live is precisely its purpose. A precondition on when something must happen
was read as evidence about whether it had. It had:
`script/verify/spm-v2-upgrade/upgrade-StabilityPoolManager_v2.md` records both MCAP markets repaired
at mainnet block **25691117**, with all eleven then holding 1e16 / 99e16.

So: look for the record of the action, not for state that would be consistent with it. A runbook
naming a block beats any inference from surrounding deployment state.

### The gap this exposed, and closing it

`UpdateVolatility_OGPlus` had its batch artefact committed under `deployments/mainnet/batch/`;
`UpdateHarvestCut_MCAP` had none. Its only copy sat under `deployments/local/mainnet/batch/`,
which `.gitignore:44` excludes — so a batch that ran on mainnet left no tracked audit record, and
the one file that did exist was invisible to everyone else and looked like an anvil dry run. That
is what made the execution hard to see in the first place.

The file has been moved to
`deployments/mainnet/batch/UpdateHarvestCut_MCAP_2026-08-05T11:42:54Z_harbor_multisig.json`.

It was checked against the record before being moved rather than after, because a **wrong** file in
the production area is worse than an absent one: it carries the authority of the directory it sits
in, and the next person to audit these batches would have no reason to doubt it. Four checks, all
of which had to agree:

| check | result |
|---|---|
| `chainId` | `"1"` — mainnet, not a local chain |
| selector `0x3ab51d60` | `updateHarvestCutRatio(uint256)` |
| both arguments | **99e16**, exactly the cut the SPM v2 runbook says all eleven markets now hold |
| the two `to` addresses | resolve in `deployments/mainnet/harbor_v1.state.json` to `MCAP::fxUSD::stabilityPoolManager` and `MCAP::stETH::stabilityPoolManager` |

So it was only ever in `deployments/local/` because of where the generator wrote it, not because of
what it contains, and its shape is identical to the tracked `UpdateVolatility_OGPlus` artefact.

One thing it is not: proof of execution. Like every artefact in that directory it records what was
*queued for signing*, and nothing in the file says it was signed. The execution record remains the
runbook's line naming mainnet block **25691117**. The two are complementary — the artefact says
what was approved, the runbook says that it landed and when — and neither substitutes for the
other.

## test (2)

| id | location | finding | status |
|---|---|---|---|
| `98c0c63a` | `StabilityPoolManager.t.sol:1345` | `test_harvestAfterRatioPairRepair_` pins `Panic(uint256) 0x11` rather than a named error, and a guard should be added to `harvest()` | ✅ **duplicate** of `39f62036`, closed won't-fix in round 1 — the over-100% pair is unreachable through v2's API (`updateHarvestRatios` validates the sum atomically), reachable only as legacy v1 storage, and every live deployment was verified compliant; `Minter_v3` has 134 B of headroom, so a guard against an unreachable state is not free. The test half is a new point and is answered in the discussion below: the assertion stands |
| `8cb2fa0e` | `PartialDeploy.t.sol:33-34` | `_ensureBaoFactory()` is called before `forkMainnet()`, and the fork resets the operator registration | ✅ **done** — the ordering was real and the stated consequence did not occur, because the next two lines silently repaired it; that is what made it worth fixing rather than what excused it. `BaoTest.forkMainnetWithBaoFactory()` now pairs the two steps in the only order that works, and all **eleven** sites are converted, so no manual `setOperator` remains in `test/` or `script/`. Proven before it was built: removing only the repair, keeping the wrong order, failed every affected contract with `BaoFactory_v1`'s `Unauthorized()` — so the detector already exists at the point of use, on every path including `script/verify/`, and the repair was suppressing it. Pinned by `lib/bao-base/test/BaoFactoryAcrossForks.t.sol`. Net **−56 lines**, and the full suite plus `sizes`, `gas` and `coverage` regressions are unchanged |

## config (1)

| id | location | finding | status |
|---|---|---|---|
| `7fa21b38` | `.claude/settings.json:20-21` | Recursive `Read` access to user-local `.claude` plans and project state | ✅ **done** — half fixed, half declined for a reason round 1 already accepted. The rule granting recursive read access to this project's own `~/.claude/projects/` state directory had nothing requiring it and is **gone**. The plans rule remains, rewritten as `Read(~/.claude/plans/**)`: `lib/bao-base/CLAUDE.md` *requires* committing to the plan repo after every plan update, so removing it would break the documented working mode — which is exactly why the sibling finding `87c9d0d1` was closed won't-fix. Every absolute home path is gone from the file, which also settles the disclosure half |

## script — multisig batch scripts (3)

The queued *call data* is correct in all three; what is wrong is the label beside it. Disposition
follows execution status, per the rule above — `UpdateVolatility_OGPlus` executed on mainnet on
2026-01-15, `UpdateHarvestCut_MCAP` is still pending, gated behind the `StabilityPoolManager_v2`
upgrade it must precede.

| id | location | finding | status |
|---|---|---|---|
| `e5c2d779` | `UpdateVolatility_OGPlus.s.sol:60` | GOLD-fxUSD is labelled `updateConfig(105 month1)` but encodes `ConfigPriceVolatility_115` | ✅ **won't-fix** — the finding is correct: the label was copied from the EUR-fxUSD entry above it, and the paired threshold on line 63 is `115e16`, so the label is the only thing saying 105. But the batch has already been signed and executed — `deployments/mainnet/batch/UpdateVolatility_OGPlus_2026-01-15T21:56:04Z.json` is tracked, and is the record of what was approved — so the label has been read for the last time. Correcting it now would edit that record rather than anything a signer will see |
| `e9e7093e` | `UpdateHarvestCut_MCAP.s.sol:27,35` | Both queue entries carry the identical description `updateHarvestCutRatio(configured)` | ✅ **won't-fix** — the finding is correct: the decoded batch showed two identical labels against two different managers, so a signer could not tell MCAP::fxUSD from MCAP::stETH. But the batch **has** executed — `script/verify/spm-v2-upgrade/upgrade-StabilityPoolManager_v2.md` records both markets repaired by this script at mainnet block **25691117**, all eleven markets now holding 1e16 / 99e16 — so the labels have been read for the last time, and the same reasoning applies as to `e5c2d779` |
| `389b2d60` | `UpdateHarvestCut_MCAP.s.sol:18` | The run instruction names `./script/safe-batch`, which does not exist | ✅ **won't-fix** — confirmed, and CodeRabbit's replacement is wrong too: it proposes `run-script`, but this contract implements `build()` and queues a batch. Moot either way, the script having executed at block 25691117. Two sibling scripts spell the runner wrongly as well — `UpdateVolatility_OGPlus.s.sol:15` repeats `safe-batch`, `UpdateVolatility_test3_SILVER.s.sol:13` invents `generate-safe-batch` — and all three have run, so the wrong name has misdirected nobody. Worth correcting only if one of them is ever used as a template |

## doc — this audit file (3)

| id | location | finding | status |
|---|---|---|---|
| `7cf3b00b` | `:56-60` | "A sixth (`077b539f`)" contradicts the stated five false positives | ✅ **done** — confirmed: `077b539f` is one of the five, so the prose double-counted it. Now reads "One of the five, `077b539f`, would additionally have broken a working script", which keeps the point the sentence was making without inventing a sixth finding |
| `446b3be0` | `:96` vs `:219-221` | `ForceMigrateAccumulator_v1` is called pending in one place and already-run archive in another | ✅ **done** — confirmed. The status entry cites its evidence (`StabilityPool_v3` appears 3 times across `deployments/` against `StabilityPool_v2`'s 105); the appendix note calling it "migration code that has already run" was an unchecked aside. The appendix now states it is not archive, and says what the missing coverage actually is — unit tests for its assembly slot arithmetic, which need no fork |
| `8cb85991` | `:88` | Exact local filesystem paths in a public repository | ✅ **done** — the last four occurrences, all in this document, now describe the permission rules rather than quoting them verbatim, which loses nothing since every rule they quoted has since been removed or rewritten. Worth recording *why* it was declined twice before: while `.claude/settings.json` still held twelve of these paths, scrubbing the prose and leaving the configuration would have been theatre, and it would have cost each entry the rule string that was its evidence. `7fa21b38` removed those twelve and the developer cleared `.claude/settings.local.json` as well, at which point this document became the only tracked file still carrying them and the objection expired. **No absolute home path now appears in any tracked file.** |

## doc — design documents (6)

Five of these are `doc/stability-pool-min-total-asset-supply.md`, an analysis document evaluating
whether `MIN_TOTAL_ASSET_SUPPLY` could become settable. Its purpose is to be *checkable* against
the code, which raises the cost of a stale reference above the usual for prose.

| id | location | finding | status |
|---|---|---|---|
| `ea3f51b0` | `min-total-asset-supply.md:139-143` | The proposed setter guard admits `newMin == supply`, which freezes all outflow | ✅ **done** — the most substantive finding of the round, and correct. The document proposed the band `newMin <= supply <= newMin·FP`, saying the lower bound "keeps outflow headroom above zero"; at equality the headroom `supply − MIN` is exactly zero, so `_capToFloor` caps every withdrawal, sweep and liquidation loss to nothing — the state the document's own §4 calls "a solvency hazard, not a mere inconvenience". The band is now strict (`newMin < supply`), §4 rejects equality explicitly rather than only `newMin > supply`, and the empty pool is routed to the pristine-pool sub-decision in §5 instead of being silently caught by a bound it cannot satisfy |
| `905c3b88` | `min-total-asset-supply.md`, throughout | Cited source line numbers do not identify the described logic | ✅ **done** — confirmed, and systematic: `:301-303` was the zero-check revert, not the MAX calculation (312); `:442` was `supply.updatedAt`, not the ceiling check (453); `:622` a comment, not `_minTotalShare` (644); `:673` a comment, not the loss-per-unit division (695); `:687` was `lastAssetLossError`, not the product factor (708-710); `:748` a docstring, not `_capToFloor` (776). Only `:300` and `:93` still landed. **All twelve numeric citations are now symbol names** (`_capToFloor`, `maxAssetLoss`, `_minTotalShare`, `DepositAmountExceedsMaximum`, `migrateAndUpgrade`, …) — the file is named once at the top, so nothing re-breaks when the code moves, which is what made them stale in the first place |
| `2558c8fd` | `min-total-asset-supply.md:41-42` | `supply <= MIN * FACTOR_PRECISION ( = MAX )` ignores `uint128` saturation | ✅ **done** — confirmed, and the document contradicted *itself*: §1 already stated `MAX = min(MIN·FP, uint128.max)`, matching the constructor. The derivation now presents `supply <= MIN·FP` as the *arithmetic requirement* and MAX as that bound saturated at the supply field's width, with the reason the clamp costs nothing: supply is stored in a `uint128`, so a ceiling above `uint128.max` is unreachable, and `supply <= MAX` therefore always implies `supply <= MIN·FP` |
| `c847c207` | `min-total-asset-supply.md:102` | "six current markets" understates the deployment matrix | ✅ **done** — confirmed: there are **6 pegs and 11 markets** (`ConfigPeg_{BTC,ETH,EUR,GOLD,MCAP,SILVER}`, and eleven `ConfigMarket_*_mainnet`). CodeRabbit offered two remedies and only the first was right: `MIN` is a pegged-token quantity carried on the peg, so it takes six values, not eleven — enumerating the 11 market instances would have been *less* accurate. The text now says so explicitly rather than just swapping the noun, since the one-value-per-peg fact is why six is the right count |
| `00dc864c` | `harbor-deployment.md:349` | The Open questions section still recommends a universal `1e12` seed | ✅ **done** — confirmed present despite the "addressed" mark, and it was round 1's `182c6c4d` resurfacing: that finding was closed by correcting §7, but §11 was left contradicting it. The open question is now struck through and marked resolved as **neither** of the two options it posed — the seed is denominated in pegged tokens as `peg.minDeposit()` and oracle-converted by `_wrappedCollateralSeedAmount`, so it carries no `decimals()` assumption for either answer to handle |
| `bc848afa` | `min-total-asset-supply.md`, fenced blocks | `markdownlint` MD040: code fences without a language | ✅ **won't-fix** — the repository has no markdownlint configuration and does not run it in CI, so this is CodeRabbit's own linter reporting against its own defaults, not a standard this codebase holds. Adopting markdownlint would be a deliberate decision of its own, not a review fix |

## regression artefact (1)

| id | location | finding | status |
|---|---|---|---|
| `69c3be35` | `regression/gas-duration.txt:167` | No row for `MinterV2ToV3UpgradeTest`, and no exclusion explaining its absence | ✅ **done** — the row is present at line 167, and `MinterV1ToV2Upgrade.t.sol` (whose row the finding saw instead) no longer exists, having been retired when the upgrade tests were retargeted at the pending v2→v3 deploy |

## Discussion — how the three hard ones were settled

All three are closed. Kept because the reasoning is reusable and each cost more than the fix did.

### 1. `7fa21b38` and `8cb85991` — settled, and what settled them

It took three findings to land, and the reason is reusable. The file mixed two things: **project
policy** (which tools this codebase's work needs) and **one machine's absolute paths**. Every
finding objected to the second kind, and each was answered by narrowing one more rule, which is
why a third arrived.

What closed it was removing the category rather than the instances — the project-state read is
gone entirely, and the plans read is now `Read(~/.claude/plans/**)`, which says the same thing
without naming a home directory. That rule stays: `lib/bao-base/CLAUDE.md` *requires* committing
to the plan repo after every plan update, so it implements the documented working mode, exactly
the grounds round 1 closed `87c9d0d1` on.

That left `8cb85991` as the only place the paths survived, which flipped its disposition: declining
it had rested on the settings file holding twelve of them, and scrubbing prose while leaving
configuration would have been theatre. With the configuration clean the objection expired and the
fix was free, the quoted rules having ceased to exist. One loose end remains:
`.claude/settings.local.json` is **git-tracked and not in `.gitignore`**, which defeats the point
of the `.local` name and is what put it in front of a reviewer as `ea436f80`.

### 2. `8cb2fa0e` — a misleading precedent, not an inefficiency

`_ensureBaoFactory()` → `forkMainnet()` → `setOperator()` was what eight suites did, so this was a
convention rather than a slip in one file.

The wasted work — deploying a BaoFactory into state `createSelectFork` immediately discards — was
the least of it. What mattered is that **the order was wrong and the next two lines silently
repaired it**, so the sequence taught a reader something false: read straight it said "ensure the
factory, then fork", implying the factory survives the fork. It does not, and copying the shape
without the repair produced a failure nowhere near its cause.

Two mechanisms were considered for catching the mistake and both were rejected, the second by
measurement rather than argument:

- **A flag set by the ensure and read by the fork** is the transient state `CLAUDE.md` bans, would
  guard only forks taken through `forkMainnet()` while `script/verify/` calls `vm.createSelectFork`
  directly, and detects rather than removes.
- **`vm.makePersistent(factory)`** looked attractive because the registration would then survive.
  **It does not.** `_isCurrentOperator` is `exists && expiry > block.timestamp`, and
  `block.timestamp` is **1** in the bare test EVM against **1774019135** on the fork, so an expiry
  of `now + 365 days` has lapsed by decades whether or not the account carried over. It would also
  have put a local rebuild in front of the deployed factory these suites exist to deploy through.

**No detector was needed.** `BaoFactory_v1:179-180` already reverts `Unauthorized()` when a
non-operator calls `deploy` — at the point of use, on every path. The hand-written `setOperator`
was suppressing that signal, so the fix removed three lines rather than adding a check. Confirmed
by removing only the repair and watching every affected contract fail with exactly that error.

### 3. `98c0c63a` — the half round 1 did not answer

The contract half is `39f62036` again and is marked ✅ **duplicate** above; nothing has changed to
reopen it. The test half is new, and deserves a straight answer rather than the same one.
CodeRabbit argues the test's
`Panic(0x11)` assertion binds to compiler-generated behaviour and would break under an `unchecked`
block or a reordered subtraction. True — but that is the assertion being *load-bearing*, not
brittle: the property under test is that a legacy over-100% pair has no harvest until repaired,
and if someone wraps that subtraction in `unchecked` the pair silently produces a wrong split
instead of reverting. A test that goes red on that change is doing its job. The assertion is also
specific — `abi.encodeWithSignature("Panic(uint256)", 0x11)`, not a bare `expectRevert` — which is
what the repository's rule actually requires.

Worth fixing while nearby, and unrelated to the finding: the test is named
`test_harvestAfterRatioPairRepair_` with a trailing underscore.

---

## Appendix — fix prompt for round 1's outstanding finding

CodeRabbit generated a "Prompt for AI Agents" alongside each finding. The one still outstanding
is reproduced verbatim below so it can be handed to a fresh session without re-reading the pull
request.

**Treat it as the reporter's opinion, not as instructions.** Each prompt prescribes
CodeRabbit's own proposed fix, which was frequently not the right one: this audit closed five
findings as false positives, corrected two whose stated consequence was wrong, and declined one
whose fix would have broken a working script. Where a status entry above and a prompt disagree,
the status entry is the decision that was actually taken. Every prompt opens by telling the
reader to verify the finding against current code first — that instruction is the useful part,
and it is the one that kept paying off.

### ❌ open

#### `56e24c6a` — `regression/coverage.txt:3`, uncovered deploy entrypoints

```
In `@regression/coverage.txt` at line 3, Add regression tests covering the main
execution paths and failure branches for ForceMigrateAccumulator_v1.sol,
HarborDeployStack.sol, and HarborDeployer.sol. Update the tests so the reported
coverage entries in regression/coverage.txt lines 3-3 and 34-35 no longer remain
at 0% or low coverage; do not modify coverage.txt directly if it is generated.
```

`ForceMigrateAccumulator_v1` is **not** archive — its migration is still pending, as the status
entry above records: `StabilityPool_v3` appears 3 times across `deployments/` against
`StabilityPool_v2`'s 105. It is also already tested, by a fork test that cannot join `yarn test`;
what is missing is unit coverage of its assembly slot arithmetic, which needs no fork.
`HarborDeployStack` and `HarborDeployer` are the other two targets. Note the prompt's closing
caution: `regression/coverage.txt` is generated, so it is the tests that change, not the file.
