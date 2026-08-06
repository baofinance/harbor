# PR #33 — CodeRabbit audit triage

Source: the six CodeRabbit reviews on [PR #33](https://github.com/baofinance/harbor/pull/33),
submitted 2026-07-29. Regenerate with:

```bash
gh api "repos/baofinance/harbor/pulls/33/reviews?per_page=100" --paginate
```

Findings are keyed by CodeRabbit's own content hash (`cr-comment:v1:<id>`, truncated to 8
characters here). That hash is stable across review runs, so it — not file:line — is the
identity of a finding. Line numbers below are as they stood at review time, against commit
`4c05265`; the code has moved since (`Minter_v3.sol` by ~125 lines), so treat them as
historical pointers rather than current locations.

| | |
|---|---|
| Raw finding-instances across 6 reviews | 107 |
| Unique by content hash | **70** |
| Of which semantic duplicates of another finding | 11 |
| Genuinely distinct issues | **59** |

Severity as reported: 2 Critical, 66 Major, 1 Minor, 1 Trivial. CodeRabbit labelled almost
everything Major, so severity carries no useful signal here and is not used to order this
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

**1 finding is outstanding**: `56e24c6a`, deploy-script test coverage. The other 69 need no
further work. Its fix prompt is reproduced in the appendix.

Five findings turned out to be false positives, and the pattern is worth recording: CodeRabbit
reads a single file without the surrounding system, so it reported a CI check as deleted when
it had moved into the composite action being called, a test suite as not covering v3 when its
mock inherits v3, and a directory as an input when it is generated output. A sixth
(`077b539f`) would have broken a working script had its fix been applied as written.

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
| `2ec5976e` | `.claude/settings.json:7-9` | Allowlist exposes other local repos and `~/.claude/**` | ✅ **done** — `2b3bdeb`; `Read(//home/tfras/github/baofinance/**)` removed, `Read(//home/tfras/.claude/**)` narrowed to `plans/**` and this project's directory |
| `5b4d32ae` | `.claude/settings.json:7` | CWE-732: constrain permissions to minimum scope | ✅ **duplicate** of `2ec5976e` |
| `87c9d0d1` | `.claude/settings.json:22` | Remove the `~/.claude/plans` git allow rules | ✅ **won't-fix** — `lib/bao-base/CLAUDE.md` *requires* committing to the plan repo after every plan update ("you own its git, and committing there is required"). Removing the rule would break the documented working mode. The remaining rule is already an exact command with a fixed argument, which is what the sibling finding asked for |
| `ea436f80` | `.claude/settings.local.json:6` | `Bash(chmod:*)` grants chmod on any path | ✅ **done** — rule removed, so chmod now requires approval. Removing rather than narrowing avoids guessing a scope: a rule can be re-added against a real path if one proves necessary. Whether this machine-local file should be git-tracked at all remains an open question, carried in the plan |
| `0a5116c7` | `CI-test-foundry-stable.yml:40-41` | Audited-source verification step removed before invoking the submodule action | ✅ **false-positive** — the check was not removed, it moved *into* the action being invoked: [`test-foundry/action.yml:94-101`](../../lib/bao-base/.github/actions/test-foundry/action.yml) runs a "Check audit and deployed code" step calling `yarn verify-audit`. CodeRabbit read only the workflow file and could not see inside the composite action it calls |
| `077b539f` | `foundry.toml:70` | `read-write` granted on the git-tracked holder-input directory | ✅ **false-positive** — the premise is wrong. That directory holds the *filtered output* of `FilterSpHolders.s.sol`, not its input: inputs are read from the untracked `tmp/sp-holders` ([FilterSpHolders.s.sol:48](../../script/Migrate_StabilityPool_v2_Data_mainnet/FilterSpHolders.s.sol#L48)) and the results written back to the tracked directory, which is git-tracked *deliberately* — "the filtered files are git-tracked: they form the auditable record of which holders were included in the migration batch and which were skipped" (lines 19-21). Write access is required by design; both prescribed remedies would break it — read-only stops `run()` writing at all, and relocating the output to `./tmp` destroys the audit record that tracking exists to preserve |
| `23d31d75` | `pyproject.toml:7` | Wake used but not declared | ✅ **won't-fix** — Wake is not part of the CI tooling yet; the Python testing of Solidity it supports is work in progress and not on any official path. Declaring it now would pin a dependency the build does not use. Revisit when Wake joins CI, at which point the `requires-python = "==3.10.*"` pin will need resolving against the 3.13 the bao-base tooling expects |
| `04f01408` | `scripts/deploy.py:3-6` | Literal `ENTER_NODE_URL_HERE` placeholder committed | ✅ **won't-fix** — same reason as `23d31d75`: Python testing of Solidity via Wake is work in progress and not part of any official process. The placeholder marks an entry point that is not yet wired up, not a broken deployment path |
| `56e24c6a` | `regression/coverage.txt:3` | `ForceMigrateAccumulator_v1.sol` 0%, `HarborDeployStack.sol` 75%, `HarborDeployer.sol` 53% | ❌ **open** — accepted: deployment is part of the production process, so the deploy scripts should be tested alongside the contracts. `ForceMigrateAccumulator_v1` is spent migration code and may reasonably be excluded; `HarborDeployStack` and `HarborDeployer` are live and are the real targets |
| `9b58cc3b` | `regression/sizes.txt:48` | `Minter_v3` near the EIP-170 limit | ✅ **won't-fix** — no action needed: contract size is tracked by CI against `regression/sizes.txt`, so an overrun fails the build rather than surprising a deployment. Recorded for context: the margin was 182 B at review, 143 B at `HEAD~6`, and is **134 B** now — the oracle guards took a third of the remaining headroom, and `StabilityPool_v3` fell 775 B → 646 B. Changes to `Minter_v3` are size-budgeted from here on |

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

## Appendix — fix prompt for the one outstanding finding

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

`ForceMigrateAccumulator_v1` is migration code that has already run, so it is arguably archive;
`HarborDeployStack` and `HarborDeployer` are the live targets. Note the prompt's closing
caution: `regression/coverage.txt` is generated, so it is the tests that change, not the file.
