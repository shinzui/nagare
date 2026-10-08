# MP-23 step 5: independent verification against release line (b) (2026-10-07)

**Reviewer:** session nagare-verify (claude-opus-5-5), which implemented none of MP-23's code.
**Candidate:** `96c1da1193f3768baa85f7cc0f67537ff6463bf6`. Its shipped code is identical to
`8824f469`; the only change is a checklist edit.
**Scope:** step 5 of [MP-23](../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md),
judged against the [production readiness checklist](../../releases/production-readiness-checklist.md)
and the 2026-10-07 Decision Log entry. That entry says v1 ships the single-fault guarantee
already proved: the fast tier and the harness self-test on the validated world, a zero-survivor
mutation sweep, a green `just gate`, and runbooks for F77 and F78.

This is a review of existing evidence, not a re-audit. Closed findings are not re-derived, and
the deep tier is not re-run. Everything below is observed unless it is marked inferred.

## Release-line evidence

| Gate | Evidence | Result |
|---|---|---|
| Green `just gate` on the candidate | [`gate-96c1da11.json`](gate-96c1da11.json); `just gate-verify 96c1da11` printed `green, tree 5acb0965…, systems x86_64-linux aarch64-darwin` | The builder probe ran first; `nix flake check --all-systems` realised 37/37 aarch64-darwin and 36/36 x86_64-linux checks |
| Fast tier and harness self-test on the validated world | [`test-evidence-96c1da11.txt`](test-evidence-96c1da11.txt) | All 1,362 `nagarectl` tests and 466 `nagare-dsl` tests passed. The fast tier covers 9 explicit scenarios plus 43 generated from the kind table. The self-test made 14,680 runs with 0 named violations. The two-sided known-defect ledger test passed |
| Zero-survivor mutation sweep | [`mutation-sweep-8824f469.tsv`](mutation-sweep-8824f469.tsv), [`.status`](mutation-sweep-8824f469.status) | All 117 records in `records.json` were killed: 116 by a test failure (exit 1), and `ADR25-model-check-reads-faulting-store` by its expected build failure. No record is missing from the manifest |
| Known-defect ledger holds only the documented limits | `cli/nagarectl/test/Nagare/Test/Model/KnownDefects.hs` | 4 entries: F77 twice (counts 1 and 3) and F78 twice (`LandsUnready` and `LandsFailed`, count 1 each). Nothing else |
| Release consistency at the candidate | `scripts/check-release.sh --version 0.4.0` in a pinned worktree; `scripts/audit-managed-commands.py` | "release-consistent at 96c1da11… for x86_64-linux, aarch64-darwin"; coverage `complete: true`, `dirty: false` |
| Fixture workloads run (before-a-native-run §2) | `just fixture-smoke` at the candidate, on a daemon without k3d | `green`; scenario-b bound to PostgreSQL fails as required |
| F31 regression, which no gate check runs | `python3 scripts/test-registry-credential-delegation.py` at the candidate | Passed: cadence invariant, owned create/no-op/refresh, short-token refusal, six foreign/race refusals and legacy policy |

## Documented limits

- **F77:** runbook at [`inventory-operations.md` "A database volume claim deleted outside review (F77)"](../../runbooks/inventory-operations.md#a-database-volume-claim-deleted-outside-review-f77).
- **F78:** the procedure (correct the template, then `db restart`) is in
  [`docs/user/managed-databases.md`](../../user/managed-databases.md), under "A database whose pod
  is stuck". The operations runbook does not link to it. Doc gap, proposed for the deferral ledger.

## Verdicts on every finding not yet Closed

Short names used below:
- **Test** = a named test that passes in the candidate's gate run (lines in `test-evidence-96c1da11.txt`).
- **Killed** = a mutation record killed in the sweep.
- **Source** = closed on source under ADR 25: the interpreters find defects, and native runs only
  confirm. Native confirmation, where it applies, comes from C2 or C3 on this candidate.

| ID | Verdict | Evidence |
|---|---|---|
| F51 | **Closed (source)** | Test "a reviewed rebind records a replacement, after which it is the accepted incarnation (ADR 27 §3)". Killed: `F51-retention-proof-uses-observed`, `ADR27-N1-replaced-retirement-unnamed`, `ADR27-rebind-*` (3). The fast tier injects `Replaced`. The earlier "native throwaway drill" requirement is superseded by ADR 25's interpreter-first rule |
| F53 | **Closed** | The candidate's full gate is green; `nix flake check --all-systems` has 0 failures on both systems |
| F55 | **Closed (source)** | Test "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)". Killed: `ADR26-close-reverts-to-converged`, `ADR26-close-ignores-unknown`, `ADR26-never-started-admits-updates`. The companion rule it named is deleted by ADR 26 |
| F56 | **Closed (source)** | Test for F56's deleted answer. Killed: `ADR26-O1-kubernetes-settle-unknown`, `ADR27-N9-update-proof-accepts-replacement` |
| F57 | **Closed (source), Kubernetes** | Tests "a retry the adapter proved safe that preflight then refuses is journalled as failed with no effect (F57)" and "the driver never executes a verification (O6)". Killed: `F57b-journal-no-effect-refusal`, `ADR26-O6-verify-executes`, `M9-verify-guard-compares-resource-version`, `B7-i8-asks-adapter-for-verify`. Non-Kubernetes verifies are a documented limit of release line (b) |
| F58 | **Closed (source)** | Three F58 tests. Killed: `F58-absence-proof-holds-no-data`, `F58-admission-absence-recheck`, `F58-admission-holds-no-data` |
| F59 | **Closed (source), gap A** | Test for the unready StatefulSet create. Killed: `F59-standalone-unstarted-creates`. Gap B (broker) is a documented limit of release line (b) ("F59's broker gap") |
| F60 | **Closed (source)** | Test "convergence binds the object the create returned, not one that replaced it before convergence (F60)". Killed: `ADR27-F60-binds-from-observation`, `ADR27-driver-drops-returned-identity`, `ADR27-runtime-ignores-returned-uid` |
| F61 | **Closed (source)** | Rename transfer tests. Killed: `F61-transfer-ignores-mounts`, `F61-transfer-mark-ignores-owner`, `F61-transfer-redoes-incomplete-copy`. MP-23's separate item "confirm the relaxed I4" stays open |
| F63 | **Closed (source)** | Tests "a corrective update of an unready object reaches the API server (F63, M1)" and "… unready Deployment plans and closes (EP-180, F63's worker half)". Killed: `F63-correct-unready-statefulset`, `F63-deployment-correction-refused`, `F72-unready-update-unsupported`, `EP181-model-correction-never-replaced`. Its StatefulSet half needed G3, which EP-181 delivered |
| F64 | **Closed (source)** | Test "an owned update target deleted outside review settles as target gone (F64's deleted answer)". The fast tier's `Deleted` fault passes. The old record is retired, and no rule-level record names F64 |
| F65 | **Closed (source), weakly** | Its companion rule is deleted by ADR 26. It is covered only by the fast tier and the `ADR26-close-*` records; the focused test EP-175 promised does not exist. Proposed for the deferral ledger |
| F66–F75 | **Closed (source)** | Each has its named test and killed records: `F66-…`, `F67-settle-ignores-stamp`, `G6-repair-proves-by-stamp`, `F68-…`, `F69-…`, `F70-…`, both `G4-…`, `F72-…`, `F73-…`, the four `G5-…` and the four `G7-…` |
| F76 | **Closed** | The incarnation group runs. `mutations patterns` passes in the gate, so every record selects at least one test |
| F79 | **Closed (source)** | Tests "close refuses, retryably, while a never-started create's absence cannot be confirmed (F79)" and the model pin. Killed: `F79-close-drops-unconfirmed-absence`, `ADR26-never-started-skips-absence` |
| F52 | **Verifying: product defect, reproduced natively in the C2 checkpoint (below); fix with nagare-fix** | The status half is proven. The convergence half has a surviving mutant (`Execute/Incarnations.hs` `establishes`, with `migrates action` disabled; see the mutation README). The operator un-deferred F52 on 2026-10-04 and made it block MP-23 completion. It needs a regression plus a record, and C2's interrupted rename shows no `replaced-incarnation` |
| F62 | **Verifying: gap sent to nagare-fix** | The refusal is pinned: test "a rename refuses a source replaced outside Nagare, at planning (F62)"; killed `ADR27-F62-migration-source-unchecked`, `ADR27-A52-writer-unchecked`. Its required `Replaced`-on-source fault in the rename recovery model is not done, so "migrate under every fault" is unproved for this fault |
| F16, F30 | **Verifying: native confirmation pending (C2 or C3)** | Source: ADR 26 close, the G6 guard (`G6-write-guard-compares-whole-state`, `G6-retire-stale-precondition` killed), and the fast tier. F30's A4 native records were never archived, so the closing evidence will be this candidate's native run |
| F15, F31, F32, F33, F39, F43, F44, F45, F46, F47 | **Verifying: C3 on this candidate** | Every earlier native pass was on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling (which covered only a check-harness change) does not apply. F33 and F39 need the staged teardown |
| F40 | **Partial** | The remainder belongs to MasterPlan 25 (operator, 2026-10-04). The in-scope part is retiring every scope on the C3 context |
| F48 | **Open, accepted** | Procedural guard for this release (operator, 2026-10-04): every acceptance run uses a fresh context, and `platform root --json` is checked before the runner. The code fix is in EP-168 / MP-26 |
| F77, F78 | **Deferred** | Operator, 2026-10-07; both are in the two-sided ledger |

## Proposed for the deferral ledger (operator decision; none risks data loss)

1. `scripts/test-registry-credential-delegation.py` (the F31 regression) runs in no `nix flake check`
   and no `just` gate step. It passes at the candidate when run by hand.
2. The operations runbook has no F78 section or link; the procedure is only in the managed-databases guide.
3. F65 has no focused test. It is pinned only by the fast tier.
4. Doc drift for the implementer, not this reviewer:
   - the tracker register lacked rows for F73–F76 and F79 (added in this pass);
   - MP-23's step boxes 3, 3a, 3b and 3d and its plan-registry rows for EP-180, EP-181 and EP-182 lag the checklist;
   - its finding snapshot is dated 2026-10-05.

## C2 checkpoint on `96c1da11` (2026-10-07, stopped at restores)

A fresh local context ran the archived C2 drivers, repointed at this candidate, its pinned
worktree and a new operator root.

- **Phase 1:** bootstrap stages 1–3 converged. Stage 3 went ambiguous once, as documented, and one
  resume converged it.
- **C1:** 214 operations, all `VerifyResource`; zero provider mutations; accepted digests unchanged.
- **After C1:** zero `replaced-incarnation`.
- **Phases 2 and 2b:** passed. These cover the databases, broker, images and secret; deploy A and B,
  each killed mid-apply and resumed; drift repair with `--take-over-fields`; the collision refusal;
  and the PostgreSQL rename, killed at its copy Job and resumed.
- **Restores:** stopped at its first step. `db backup scenario-pg` refused because the database's
  StatefulSet was `unrecorded`.

What the stop showed:
- **[F52](../mp23-findings.md#f52), reproduced natively.** Every renamed member is `unrecorded`,
  although its `MigrateResource` completion recorded the live UID.
- **[F80](../mp23-findings.md#f80), new P1.** The documented rebind cannot be issued for application or
  database members.

Both went to session nagare-fix as product defects, so `96c1da11` is not the final candidate.
Evidence: [`c2-checkpoint-96c1da11/`](c2-checkpoint-96c1da11/).

Pipeline rehearsals done before the run (before-a-native-run §4):
- the candidate's assembler and finalizer accepted scratch copies of the real `b74b7e49` C2 output
  (16 assertions);
- the same tools accepted the real `84754389` C3 output (17 assertions), reproducing its recorded run
  digest.

## Next checks

C2 (fresh local context on this candidate) and C3 (fresh cloud context, then the staged teardown
and the `mp23-c3i` teardown). The F52 and F62 closure gaps come back from nagare-fix as test-only
changes. If either exposes a product defect, the candidate changes.

## Final candidate `3ae20f8c`: results (2026-10-08)

The final candidate is `3ae20f8c`: F52 and F80 (`a7958867`), F81 (`2df33205`), F83 (`0d828d50`) and F81's E2 and E3 (`3ae20f8c`). Its gate record is green on both systems, and the mutation sweep killed 132 of 132 records.

| Check | Result | Evidence |
|---|---|---|
| C2, fresh local context | Pass: 16/16 assertions, inventory evidence assembled, C1 verify-only with 0 provider mutations; F83 confirmed (kept scratch scopes retire) | [`c2-acceptance-3ae20f8c/`](c2-acceptance-3ae20f8c/) |
| C3, fresh cloud context `mp23-c3j` (`c3-1009`) | Pass: 17/17 assertions, inventory evidence assembled (run `7c8dbfbc…`), F48 guard held, secret scan 0 | [`c3-acceptance-3ae20f8c/`](c3-acceptance-3ae20f8c/) |
| Operations runbook, end to end on `mp23-c3j` | Pass for every section exercised (see below) | [`runbook-execution-3ae20f8c/`](runbook-execution-3ae20f8c/) |
| Section-2 no-data-loss drill | Pass: cluster destroyed; recovered from a fresh root with escrow and GCS only; 4/4 rows; 20 s | [`section2-drill-3ae20f8c/`](section2-drill-3ae20f8c/) |
| C4 | aarch64-darwin pass; x86_64-linux fails at `local-init` (F85) | [`c4-3ae20f8c/`](c4-3ae20f8c/) |
| `mp23-c3i` teardown | Stage 1 converged (F39). Retirement is blocked by F84. Disposed by exact-name deletes from its own stack export after a final history export | [`c3i-teardown/`](c3i-teardown/) |
| `mp23-c3j` disposal | History exported. VM, disk and snapshots deleted for the drill; then the remaining 30 exact deletes. A read-only sweep finds nothing named `c3-1009` | this record |

**Runbook sections.** Each was executed natively on `mp23-c3j`, unless the cell says otherwise.

| Section | Result |
|---|---|
| Select the private context | `context guard`; `kubeconfig recover` into a fresh root (19 s, mode 0600, node reached) |
| Apply a saved review | Inspected, applied and converged; `inventory explain` captured |
| Resume the original transaction | Apply killed mid-flight, then resumed to convergence |
| Take over after a crash | C3 `takeover.sh`: a plain resume from root B was refused ("explicit takeover is required"); `--take-over` converged in 31 s with UIDs unchanged |
| Resolve with adapter proof | Not reached natively: no operation was uncertain at the kill. Covered by tests |
| Close a stopped transaction | An update that landed but never became Ready was closed with its scope kept; the corrected review converged with the same Service UID, Ready. An attested close replayed on the closed transaction is idempotent and accepts nothing |
| Abandon a migration (F81) | Rename killed at its copy Job, then abandoned: the writer went from replicas 0 under the fence to 1, unfenced, same UID; the row is intact; 4 leftovers listed (D1) |
| Replaced and unrecorded members | Replaced Role and lost-response members rebound through `inventory adopt` |
| F77 procedure | Not executed natively; steps 1, 2, 4 and 6 were verified on k3s by RES-4 E16 |
| Repair configuration drift | C3 `drift-classification`: strict apply refused, `--take-over-fields` repair converged |
| Synchronize a protected backend | `access portal sync` converged |
| Reviewed controller collection | Application B was retired with its Redis backup and restore scopes; its release history was collected first; then its Service and all 5 controller descendants were collected; its Redis data was retained |
| Staged cloud teardown | Blocked by F84 on both contexts; the exact-name disposal path was used |

**Deferral ledger for the next release** (operator rule, 2026-10-07: only a critical break delays the release):
- **F84:** access-grant retirement. Fixed on `next-release` `de7100f0`; its revoke-first policy is a choice for the operator.
- **F85:** npm missing from `operatorTools`. Fixed on `next-release` `6011d1ba`.
- **F33:** the cloud-collection recheck; native proof is owed by a staged teardown, which F84 blocks.
- **D1:** leftover destination objects block a re-rename; the runbook has a manual exit.
- Recording the identity a stamp-proved lost create observes, so no rebind is needed. Needs an uncopyable discriminator, likely managed fields; an experiment and an ADR 27 amendment come first.
- Done on `next-release`, landing next release: F31 gate wiring (`e96fee1a`), the F78 runbook section and the F65 test (`eb642303`).
- Section-2 breach grading and corrupt/incomplete-upload refusal are ticked from tests in the candidate's green gate run ([tests](test-evidence-section2-3ae20f8c.txt)). A native breach observation and a native tamper drill on this candidate remain a monitoring item, not a box.
- C5: release assembly, IR-24 mapping and release notes.
