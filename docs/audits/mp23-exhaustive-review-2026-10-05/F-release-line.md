# MP-23 release-line review: remaining obligations and candidate lines

**Snapshot:** master `09241d35` (read-only copy at `scratchpad/m1`).
**Sources read:** MasterPlan 23 (Vision, Finish line, Decision Log, Progress), the Progress sections of EP-153 to EP-160, EP-173 and EP-174, `docs/audits/mp23-findings.md` (every non-Closed entry), `docs/audits/mp23-engineering-retrospective-2026-10-04.md`, ADR 22 (known limits and the F49/F51/F52/F55/F59 amendments), ADR 25, MasterPlan 26, the reviewer's `phase3a-c3-mp23-c3i.json`, and the stop-rule and recovery source (`Plan/History.hs` `incompleteApplicationOnlyReview`, `Adapters/Kubernetes.hs` recover).
**Labels:** "observed" means read in a document or in source. "Inferred" means my reading.

**Outside the snapshot (inferred from file names only).** The live working tree at the same HEAD has 15 modified files (+404/−85) and untracked mutation diffs named `F58-admission-holds-no-data`, `F59-standalone-unstarted-creates`, `F61-transfer-redoes-incomplete-copy`, four `F63-*`, two `F64-*` (deleted update target / deleted workload update stop) and `F65-create-stop-companions`, plus a new `InventoryTransferScriptSpec.hs`. So fixes for F58, F59 gap A, F61 and F63 are in flight. **F64 and F65 look like two new findings that are not yet in the tracker.** The tables below cover the snapshot only.

---

## 1. Every remaining obligation, grouped by root class

Type key: **Code** = source fix, **Test** = regression, model scenario or mutation record, **Native** = cp3 or cloud run, **Rev** = independent reviewer write-up, **Doc** = documentation or decision, **Op** = operator decision.

### 1A. Stuck state / no reviewed exit (invariant I1)

| ID | Pri | Status | What exactly remains | Type |
|---|---|---|---|---|
| F59 | P1 | Partial (reopened) | **Gap A:** `loadUnstartedApplicationCreates` computes never-started creates only for `Application` scopes. After a database stop with `backup-signing-key` still Pending, both the corrected review and the retirement refuse `durable-resource-missing`. This depends on the database name through operation-ID digest order. **Gap B:** a broker StatefulSet with topics under `LandsUnready` has no exit, because the create path requires every operation to be `KubernetesExecutor` and topics are `BrokerExecutor`. Needed: a post-stop corrected-review or retire step in the DB scenario, a broker scenario, fixes for both gaps, and mutations. | Code + Test |
| F61 | P1 | Open | A rename copy Job that dies partway leaves a dirty destination. Every retry then refuses, recovery is always `SafeToRetry`, and no reviewed action clears the volume. Needed: a `PartialCopy` world fault (it should fail I1 on HEAD), a reviewed exit (prove no other users, then wipe or recreate the destination), and a mutation. This also invalidates the "relaxed I4" that the reviewer was asked to confirm. | Code + Test |
| F63 | P1 | Open | F54's landed-update stop is Knative-only. A Deployment (worker) or database StatefulSet `UpdateResource` that lands unready returns `RecoveryUnresolved`, the same wedge. Needed: two `LandsUnready` scenarios, an exit for each, and mutations. | Code + Test |
| F55 | P1 | Verifying | **Class gap:** a never-started companion update of a task CronJob, DomainMapping or broker trigger that is ordered after the Service is refused by the companion rule (create/update only of a "stateless ConfigMap ordered after"). Needed: a model scenario whose release also changes a CronJob and a DomainMapping under `LandsUnready`, or a written proof that such companions always run first. | Test (likely + Code) |
| F56 | P1 | Verifying | **Class gap:** out-of-band *deletion* without recreation (`KubernetesAbsent`) falls to `RecoveryUnresolved`. Needed: a `Deleted` world fault, plus a fix or a new finding (probably the in-flight F64). | Test + Code |
| F57 | P1 | Verifying | **Class gap:** the fix is Kubernetes-only. Broker, CDN, Cloudflare and Foundation recovery still return `RecoveryUnresolved` on a mismatched verify. Needed: a generic `VerifyResource` rule in the driver or recovery with a generic-adapter regression, or an operator deferral of the other executors to EP-173 M4 with the ledger shown. | Code + Test, or Op |
| F58 | P2 | Verifying | Admission's own `holdsNoData` check has no regression (the mutation only reverts planning). Needed: a review that carries an absence proof for a durable volume, which admission must refuse, plus an admission mutation. | Test |
| F16 | P1 | Verifying | Source verified (phase 1). The native create stop and conditional update are proved on `mp23-c3i`, and the F54 native run converged a correction. Needed: the reviewer's closure under ADR 25 class coverage (F16 mutations are now in the M1 model). | Rev |
| F30 | P1 | Verifying | The A4 terminal native record exists but sits in `/tmp` and was written with the dev binary `ab3aabf7`. Needed: archive the `a4-*.json` records under `docs/audits/`, then reviewer closure (the F30 mutation is in the M1 model). | Doc + Rev |
| F40 | P1 | Partial | The in-scope part (contribution targets, scope cycles, host and artifact retention) is source-verified. The remainder was moved to MP-25 by the operator. Needed: native retirement of every scope including the cloud scope on the acceptance C3 (phase 3b), plus a tracker disposition that lets a "Partial, remainder moved" finding stop blocking. | Native + Doc |

### 1B. Identity / incarnation

| ID | Pri | Status | What exactly remains | Type |
|---|---|---|---|---|
| F52 | P2 | Verifying | The status half is proven. **A mutant survived:** with "a migration establishes its destination's record" disabled, every test still passes. Needed: assert that the renamed members' records name the new objects after convergence, ideally with a fault on the convergence observation, and name I3 and the rename model as covering. | Test |
| F62 | P2 | Open | A migration's source physical identity comes from planning and is never compared with the recorded incarnation. A replaced source is copied from and then retained (F51's harm through migration). Needed: `Replaced` on the rename source in the rename model, refusal of a non-recorded source, and a mutation. | Code + Test |
| F60 | P2 | Deferred (operator condition) | Recording is fail-open. One `Replaced` fault between create and convergence records the replacement. The design has five changes: UID from `kubectl create -o json`, `AdapterExecution` type, a journal `Completed` schema change, verify/recover comparison with a reviewed exit, and binding at convergence. Estimate 4–6 h. ADR 22 "Known limits" already documents it. The model's F60 tolerance stays. | Op (stays deferred) / Doc |
| F33 | P1 | Verifying | Source verified. The native check is entirely in phase 3b: each teardown leaf collection's review, digest, plan/apply logs, and the URN, provider ID and protection before and after. Needed: the reviewer's written record of the 3a→3b brief deviation (not yet in `phase3a-c3-mp23-c3i.json`). | Native + Rev |

### 1C. Verification-only (fix and evidence exist; a reviewer must write the closure)

| ID | Pri | Status | Evidence in hand | What remains |
|---|---|---|---|---|
| F15 | P1 | Verifying | Phase 3a on `mp23-c3i`: 8 private pulls after boot-credential expiry, 0 failures | Rev closure |
| F31 | P1 | Verifying | Phase 3a: timer replaced tokens before expiry, observed read-only | Rev closure |
| F32 | P1 | Verifying | Phase 3a: reviewed `cleanup --images` removed exactly 3 unused images; same-ID replan 0 ops | Rev closure; then B4 promotion of `Cleanup` (1C→1F) |
| F43 | P1 | Verifying | Phase 3a: 12 CDN members accepted and converged | Rev closure |
| F44 | P1 | Verifying | Phase 3a: final observation complete. The regression is structural only (a list, not the `app/` registry) | Rev closure (EP-173 M3 would make it real) |
| F45 / F46 / F47 | P1/P1/P2 | Verifying | Phase 3a: full B3 cycle (deploy → CDN IP, disable → origin, retire, collect). F45(a,b) and F47 have no unit test (`app/`) | Rev closure |
| F39 | P1 | Verifying | Source plus regression | Native staged-retirement records in phase 3b, then Rev |
| F53 | P1 | Verifying | Reviewer's oral verdict at `b74b7e49` (36/36, 35/35) | Rev write-up. The new candidate needs its own green flake check (EP-174 M3) |
| F48 | P2 | Open | Operator accepted the procedural guard; the code fix is in EP-168 (MP-26) | **Doc:** set a status (for example "Deferred, operator") so it stops counting as "not Closed" in the finish line |

### 1D. Native-only checks and finish-line gates

| Item | State | What remains |
|---|---|---|
| **New candidate freeze** | Blocked | The F51, F52 and F54–F59 fixes changed shipped `cli/*/src`, so `b74b7e49` is superseded. The freeze waits for the in-flight F59, F61 and F63 (and F64/F65) fixes. **ADR 25 §5: the freeze refuses without a green full-gate record** (EP-174 M3/M4). |
| C1 | Must rerun (85 s) | On the new candidate's fresh payload |
| C2 | Must rerun (~40 min) | By the Dependency Graph rule, evidence counts only where its recorded inputs match, and the operator revision changes. The rename window must now show zero `replaced-incarnation` (F52 fixed), which differs from `b74b7e49`'s C2. |
| C3 scenario | Done on `84754389` (accepted as C3 for `b74b7e49`) | **Undecided:** does it carry over to the new candidate? The precedent covered only a harness-only diff. This time `Plan/History.hs`, `Adapters/Kubernetes.hs`, `Execute/*` and `Status.hs` changed, and C3 exercises them. Either a fresh C3 (hours, cloud spend, operator approval) or an operator carry-over ruling. **Op** |
| C3 exact cleanup (phase 3b) | Not run | Policy plus retirement of every scope including cloud on `mp23-c3i`. Feeds F33, F39 and F40. Runs after the runbook execution. Needs `mp23-c3i` alive, or a new C3 context. |
| Phase 3a steps 3–6 plus the full runbook | Not run | Drift repair, the F35 exit, access portal sync and kubeconfig recover were never run (blocked by F54). Then the full end-to-end independent runbook execution (safe-use gate). Required for MP-23 by operator decision; the fallback is to narrow it to the safe-use gate with a release-notes caveat. |
| C4 | In progress | aarch64-darwin clone-free passed at `b74b7e49`. **x86_64-linux clone-free has never run**, and the platform choice (Colima amd64 or the builder VM) is a pending user decision. A flake check is needed at the new candidate. EP-154 M1/M2. |
| C5 | Not started | `assemble-release.sh` over C2, C3 and C4; IR-24 cases 1–7 mapped; `docs/releases/v<version>.md` stating the unmet targets (data-protection gate, MP-21, D2, D3, D4, D6-daily). **Contradiction:** C5 and EP-157 still require a `workflow_dispatch` run, which is GitHub Actions, and the operator rejected Actions on 2026-10-04. **Op/Doc:** re-scope it to local assembly. |
| Native hold | In force | The operator's 2026-10-04 hold says no cp3 or cloud run until EP-173 M1–M2. M1 is done. **M2's checkbox is unticked**: "acceptance, except F50", and F50 lives in M4. Lifting the hold for the new candidate is effectively an operator call. ADR 25 rule 1 ("before any native exercise of an adapter path, an in-memory test drives it through the adversarial states") read strictly also requires worlds for Pulumi, Helm, host, CDN and broker before C3 (EP-173 M4). |
| EP-158 access grant/revoke, B3 | Done in C3 on `84754389` | Carry-over or rerun follows the C3 decision. Tick the EP-158 boxes. |
| EP-160 manual cloud receipts (Redis/ClickHouse) | Unclear | Decided to run inside C3. Check whether C3's "every engine" assertions were manual receipts, then tick or run. |
| EP-160 wrong-incarnation destination | Gated on F35 | F35 is Closed. Tick it with the cp3 record. |
| Independent local PostgreSQL isolated restore | Evidence exists | `postgresql-isolated-restore-7596632c.json` (reviewer, 2026-10-04). The finish-line box is unticked. Tick it, or decide whether it must be rebound to the new candidate. |

### 1E. Harness and tooling

| Item | What remains | Needed for MP-23? |
|---|---|---|
| EP-174 M3 | The green full gate is blocked: `nix flake check --all-systems` times out on `nix-gcp-builder` until the SSH keepalive fix is activated (`a885433c` tailnet join is related) | **Yes**, because the freeze requires it (ADR 25 §5) |
| EP-174 M4 | The green acceptance of `gate verify` waits on M3 | Yes, through the runbooks |
| EP-173 M2 | Formal tick (all but F50) | Yes, for the hold |
| EP-173 M3 | Move the adapter registry from `app/` into the library | No by plan, but it is the only way F44, F45(a,b) and F47 get non-native regressions |
| EP-173 M4 | Worlds for Pulumi, Helm, host, broker and CDN, plus fidelity fixtures. This covers F50, F57's other executors and F59 gap B | Strictly, yes under ADR 25 rule 1 before any native run of those paths. Otherwise it needs an operator scoping decision |
| EP-173 M5 | Coverage record | No (an EP-170 / MP-26 precondition) |
| Model fast tier | 69 s, over M1's 60 s target | Minor |
| B4 coverage | `Cleanup`, `InfraDestroy` and `infra-destroy` are still `pending`; one gap row; the audit must emit `complete: true` for the candidate | Yes (C5 input). Waits on F32/F33 closure. |
| Non-blocking | Cloud `server status` UNKNOWN on the litestream and volume rows; a collectable lifecycle for the runner probe | No |

### 1F. Docs and decisions

- **Op:** accept or reject the recorded arguments: the EP-159 B1 re-scope ("out-of-band replacement refuses ingestion and isolated restore") and EP-160 B2 (Redis load interruption, partial ClickHouse effect).
- **Rev:** confirm the rename model's relaxed I4. F61 already shows it holds only for the three modelled faults.
- **Op:** C3 carry-over, the x86_64 platform, `workflow_dispatch` → local, and whether F57's non-Kubernetes executors are scoped to M4 (that would be a ledger deferral).
- **Doc:** archive the F30 `/tmp` records, write the reviewer's F33 deviation, set F48's status, and add a "Partial-with-remainder-moved" rule for F40.
- **Doc (Phase D):** finalize the living sections of EP-153 to EP-160 and tick their stale boxes (EP-153 A1/A2/A4/F35/B4; EP-156 A4/A5/B6/B3/C3; EP-158; EP-160). Mark the registry, distill into ADR 22, write MP-23's Outcomes, and update the IR-24 status. Update the ledger for every deferral (ADR 25 §7).

**Count:** 27 non-Closed findings (4 Open, 2 Partial, 20 Verifying, 1 Deferred), 2 probable untracked findings (F64, F65), 5 finish-line gates plus the freeze, 4 reviewer-pass items, 3 Phase-D items, 2 hard tooling prerequisites (EP-174 M3/M4), and about 6 operator decisions.

---

## 2. What collapses under which design

### 2.1 Produced by the per-kind allowlist pattern

The source confirms the pattern (observed). Exits are granted by enumerating cases:
- the scope kind must be `Application` or `Standalone`;
- the stopped member must be a Knative `service`, a preview `domainmapping`, or a standalone `statefulset`;
- the companions allowed are "verify anything; create/update only a stateless ConfigMap ordered after";
- `RecoveryAwaitingReadiness` only for `deployment/statefulset/service/domainmapping` creates;
- `RecoveryLandedUnready` and `RecoveryTargetReplaced` only for Knative Service updates, and only for Present/NotReady (not Absent);
- `RecoverySafeToRetry`-for-verify only in the Kubernetes adapter;
- never-started creates only for `Application` scopes;
- the create-stop requires every operation to be `KubernetesExecutor`.

Every missing case is an I1 wedge. The model then finds the next sibling: F55 → F56 → F57 → F59 → F63 → (F64, F65) on one day.

**These would collapse under one general proof-based exit rule.** Stated generically, in the driver and recovery policy, keyed on action, journal state and data policy rather than on resource kind:
> A transaction may be stopped (nothing accepted, the scope keeps its last accepted revision, never-started creates recorded for any scope kind) when every non-completed operation is proved to be one of: (a) no effect (never intended, refused-before-effect, or any executor's `VerifyResource`); (b) an effect confined to a member that holds no data under accepted history (stateless, or durable but never started) and carries no data fence; (c) a target that no longer carries the reviewed UID (replaced or deleted), so the conditional write cannot apply.

- **Collapse fully:** F55 class gap, F56 class gap (Deleted, probably F64), F57 (all executors), F59 gaps A and B, F63 (Deployment and StatefulSet update), F65 (companions), and the future siblings for CronJob, Job, ConfigMap or Helm-release updates. Each then needs only a world scenario for coverage, not a new branch.
- **Partly:** F58 (the retirement side has the same shape: an absence proof generalizes "no data" proofs, already done). F61 needs one extra reviewed *compensating* action ("wipe a never-accepted, unused destination"). Rule (b) proves it is safe to discard but does not clean the volume.
- **Historical members of the class (closed):** F16, F29, F30, F35, F36, F37, F54.

Caveat (inferred): the per-kind design was deliberate (ADR 22: never roll ownership back away from created retained data). The generic rule must keep the data-policy, fence and "accepts nothing" conditions. It is a 1–2 day design, implementation and model job, compared with roughly 2–4 h per sibling finding under the current pattern, which has not converged.

### 2.2 Produced by identity recording (the F60 design: bind from the create's completion UID)

- **F60** directly.
- **F62:** its guard ("source must equal the recorded incarnation") is only total if recording is never fail-open. Otherwise an unrecorded source still passes.
- **F52's survived mutant:** the destination record would come from the create's UID, not from the convergence observation.
- **The F49 and F51 known limits** on the ledger ("recording is fail-open", "unrecorded members pass").
- **Partly F56/F64:** a create-target-replaced exit is step 4 of the F60 design.

F33 is the Pulumi analogue, but it is independent and already fixed.

### 2.3 Independent

- **Platform/credentials:** F15, F31, F32.
- **Teardown:** F39, F40.
- **CDN:** F43 to F47.
- **Evidence and harness:** F48, F53, EP-174 M3/M4, C4 x86_64, C5.
- **Rename semantics:** F61's compensating action.
- **Test-only:** F58 admission.
- **Closure-only:** F16, F30.
- **All native gates.**

---

## 3. Candidate release lines

Effort is rough. It is based on observed velocity: F55–F59 were each fixed the same day; F60 was estimated at 4–6 h; C1 takes 85 s; C2 about 40 min; C3 roughly a day including approval.

### (a) "Everything" (the current finish line)

- **Must do:** all of §1. That means F59, F61, F62 and F63 plus the F55/F56/F57 class gaps (per kind, or the generic rule), F52 and F58 tests, and EP-174 M3/M4 green. Strictly under ADR 25 rule 1 it also means EP-173 M4 worlds for every executor C3 exercises. Then a new candidate, C1, C2, a fresh C3 (or a carry-over ruling), phase 3a steps 3–6, the full runbook, phase 3b, C4 x86_64, C5 re-scoped off Actions, a reviewer pass on about 27 findings, and Phase D. F60 stays deferred unless the operator changes the condition.
- **Effort:** about 2–3 weeks. The model and review are still finding 9–11 issues a day, so the date does not converge without the §2.1 rule.
- **Documented limits:** only those already decided (F60, F48 guard, F40 remainder → MP-25, B5 collections, D2/D3/D4).
- **Risk to the operator's use:** lowest residual risk, but the longest delay before the team gets anything.

### (b) "Kubernetes application and standalone-database scopes on the reviewed paths"

The release claims the I1 exit guarantee for `Application` and `Standalone` scopes on `KubernetesExecutor`. Other executors (Pulumi foundation, Helm, host, CDN, Cloudflare, broker topics) are supported on their ordinary reviewed paths, which C3 phase 3a already exercised natively, but their rare-fault exits become documented limits.

- **Must do:**
  - The generic exit rule of §2.1 for Kubernetes, or at least F63 (worker or database update unready is a frequent real event), F59 gap A, and the F55/F56 class gaps.
  - F61, because `db rename` is in scope and its wedge blocks every plan on the context. The alternative is to mark rename experimental.
  - F62 (a cheap guard), and the F52 and F58 tests.
  - EP-174 M3/M4 green.
  - A new candidate, then C1 and C2.
  - Either a bounded C3 confirmation limited to application and database paths, plus an operator carry-over ruling for the unchanged executors, or a fresh C3.
  - The runbook, phase 3b, C5 (local), C4 (darwin; x86_64 as an operator decision), and the reviewer pass.
  - The operator records the F57-others / F59-B / F50 scoping on the ledger.
- **Effort:** about 1–1.5 weeks.
- **Documented limits:**
  - F57 for non-Kubernetes executors: a verify whose target is replaced wedges.
  - F59 gap B: a broker with topics that never becomes Ready wedges.
  - F50's residual: a single failed `FoundationRuntime` read stops a run.
  - F60, F48, the F40 remainder, B5, D2, D3 and D4.
  - **Each wedge-class limit needs a stated recovery procedure.** Today there is none short of a raw edit, which the operator's rules forbid. So line (b) should include either the generic rule or an operator-attested "stop, accept nothing" decision as the last-resort exit.
- **Risk to the operator's use:** apps, databases and previews are on Kubernetes and inside the guarantee. Previews are DomainMappings and are covered. GCP foundation, host and image paths are rarely changed after bootstrap. Broker and CDN are the exposed areas: a Redpanda stall would block the shared context for the whole team until the limit is handled. It is acceptable for an intranet team **if** the broker is not used yet, or a last-resort exit exists.

### (c) Minimal line

- **Must do:**
  - Land the in-flight F58, F59, F61 and F63 fixes as they are.
  - EP-174 green gate, new candidate, C1 and C2.
  - An operator carry-over ruling for C3 (`84754389`) and C4 (darwin only; x86_64 declared untested).
  - C5 local, with release notes stating "not cleared for real workloads until the safe-use gate (independent runbook) passes". This is the operator's own recorded fallback.
  - Close only the findings with native evidence already in hand: F15, F31, F32, F43 to F47.
  - Everything else becomes a limit.
- **Effort:** about 2–4 days.
- **Documented limits:** every Open, Partial or Verifying class gap (F52, F55, F56, F57, F59-B, F62, the F64/F65 probables), F60, the unrun phase 3a steps (drift repair, F35 exit, access sync, kubeconfig recover), and the phase 3b teardown (F33, F39, F40 unconfirmed natively).
- **Risk to the operator's use:** high for team use. The most common real faults, a bad worker image or an out-of-band `kubectl` edit or delete, can still wedge the context's single-writer store, which blocks every app's deploys. The release does **not** work if it is shipped as `b74b7e49` as-is: it lacks the F54 fix, so a bad Knative deploy wedges. Suitable for operator-only evaluation, not the team intranet.

---

## 4. Findings by discovery source and day

`Found by` lines exist only for F55–F63. F01–F54 use the retrospective's Appendix A (SRC/REC/LOC/CLD/FLK), and dates come from the evidence dates in the tracker and archive. The 10-01 and 10-02 split for F19–F34 is approximate (inferred).

| Day | IDs | Total | Native: local | Native: cloud | Source review / audit | Recorder CLI probe | Model (EP-173) | Flake |
|---|---|---|---|---|---|---|---|---|
| 09-29 | F01–F13 | 13 | 0 | 0 | 11 | 2 | 0 | 0 |
| 09-30 | F14–F18 | 5 | 0 | 5 | 0 | 0 | 0 | 0 |
| 10-01/02 | F19–F34 | 16 | 5 | 7 | 2 | 2 | 0 | 0 |
| 10-03 | F35–F44 | 10 | 4 | 5 | 1 | 0 | 0 | 0 |
| 10-04 | F45–F54 | 10 | 3 | 6 | 0 | 0 | 0 | 1 |
| 10-05 | F55–F63 | 9 (+2 probable F64/F65) | 0 | 0 | 3 (F61–F63) | 0 | 6 (F55–F60) | 0 |
| **Total** | 63 | **63** | **12** | **23** | **17** | **4** | **6** | **1** |

By the requested grouping: **native runs 35**, **reviews 21** (17 source audit or independent review plus 4 reviewer recorder probes), **model 6**, **flake check 1**. This matches the retrospective's 54-finding totals plus F55–F63.

**Trend:**
- **The volume is flat** at about 10 a day (13, 5, 16, 10, 10, 9 to 11).
- **The source shifted.** On 10-03 and 10-04, 18 of 20 findings were native. On 10-05, 0 of 9 were native, because of the hold, while the model and review found 9.
- **Severity has not dropped.** 10-05 produced 6 P1 and 3 P2.
- **The class has narrowed.** 7 of 10-05's 9 are stuck-state and 2 are identity, and 6 of the 7 stuck ones are siblings from the allowlist pattern.

The discovery rate is not converging under per-kind fixing. That is the strongest argument for the §2.1 generic rule before any line is frozen.
