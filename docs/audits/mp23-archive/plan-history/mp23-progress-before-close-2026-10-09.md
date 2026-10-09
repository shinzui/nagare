# Snapshot: MP-23 Progress before close-out

Verbatim Progress material of [MasterPlan 23](../../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) as of 2026-10-07 (`80e8089f`), moved here at close-out on 2026-10-09. Only relative links were adjusted. It covers the 2026-10-04 finish line (candidate `b74b7e49`, sessions nagare-phase-b and nagare-f3), the dated phase checkpoints, the Phase A–D work list and the cross-plan gates. This is history, not current instruction; the live plan's final status supersedes it.

---

### Finish line (canonical checklist, 2026-10-04)

This list says what remains before MP-23 is complete. It was agreed between sessions nagare-phase-b and nagare-f3. Where a dated snapshot below or a child plan disagrees with it, this list wins.
- **Candidate: `b74b7e49`** (frozen 2026-10-04 by f3). It adds only the F53 check-harness fix to `84754389`, which includes F38, F45–F50 and the F49 StatefulSet follow-up. `nix flake check --all-systems` is green at `b74b7e49`. The earlier candidates `7d486457` and `7596632c` are checkpoints: C3 found F45–F47, and the EP-159 drill found F49.
  - **Superseded in source (2026-10-05).** The F51, F52 and F54–F59 fixes change shipped code, so a new candidate is needed. `b74b7e49`'s gate results then count only where their recorded inputs still match it (Dependency Graph); C1 always reruns. Freezing it waits for EP-173 M2 (operator decision, 2026-10-04); a receipt-ingestion scenario and the in-model rename remain.
- Tick a box only with linked evidence, on the frozen candidate unless the box says otherwise. Results on earlier candidates are linked as checkpoints.
- When a box is ticked here, tick the matching `(MP-23 …)` box in its child plan.
- Owners: **phase-b** = session nagare-phase-b; **f3** = session nagare-f3; **user** = the operator; **reviewer** = an independent session that did not implement the work.

**Gates on the frozen candidate**
- [x] **C1** (owner phase-b) on `b74b7e49`'s fresh payload: 214 `VerifyResource`, zero mutations, digests unchanged ([proof](../../mp23-implementer-results-2026-10-03/c1-local-gate-b74b7e49.json)). Checkpoints: [`84754389`](../../mp23-implementer-results-2026-10-03/c1-local-gate-84754389.json), [`7596632c`](../../mp23-implementer-results-2026-10-03/c1-local-gate-7596632c.json), [`7d486457`](../../mp23-implementer-results-2026-10-03/c1-local-gate-7d486457-rerun.json).
- [x] **C2** (EP-155, owner phase-b): a fresh local context on `b74b7e49` finalized 16/16, and `assemble-managed-resource-evidence.sh` accepted the same directory (2026-10-05, [record](../../mp23-implementer-results-2026-10-03/c2-acceptance-b74b7e49.json)). `platform-root.json` shows the candidate's payload (F48 guard), and zero `replaced-incarnation` findings appeared after C1 and before the runner. The deferred F52 shows inside the interrupted-rename window, as expected, and is recorded rather than gated. The directory went to f3 for C5. The F49 native drills ran on `84754389`, whose shipped source is identical. Checkpoints: [`84754389`](../../mp23-implementer-results-2026-10-03/c2-acceptance-84754389.json), [`7596632c`](../../mp23-implementer-results-2026-10-03/c2-acceptance-7596632c.json), [`7d486457`](../../mp23-implementer-results-2026-10-03/c2-acceptance-7d486457.json).
- [ ] **C3** (EP-156, owner f3; every check done, only exact cleanup remains): fresh GCP context `mp23-c3i` (`*-c3-1008`), bootstrapped from candidate `84754389`'s own payload. **Operator decision (2026-10-04):** this run is C3 for `b74b7e49`. The only code commit between the two revisions is F53's check-harness fix, with nothing under `cli/*/src`, `cli/*/app`, `cluster/`, `infra/` or `nixos/`, and the reviewer ruled closures carry over across it ([record](../../mp23-implementer-results-2026-10-03/c3-acceptance-84754389.json)). Checkpoints: `mp23-c3g` (`7d486457`), [`mp23-c3h`](../../mp23-implementer-results-2026-10-03/c3-checkpoint-7596632c.json) (`7596632c`).
  - [x] all 17 cloud scenario assertions recorded and finalized. They cover the six operational checks: application change with unchanged replay, GCS backup and isolated restore for every engine plus a volume, interrupted-operation recovery, clean-root recovery, writer refusal and takeover, and collision, adoption and drift refusals.
  - [ ] exact cleanup:
    - [x] perimeter-only exact collection, proven on the candidate's own build in disposable `mp23-c3p` (`b5d059d7`);
    - [ ] on `mp23-c3i`, policy plus retirement of every scope, including the cloud scope. This runs after the independent runbook execution (phase 3a), and its records feed phase 3b (F39, F33).

    Full-context VM collection is MasterPlan 25 by operator decision.
  - [x] F15/F31: 8 private pulls after the boot credential expired, with no failures, and all three owned pull Secrets rewritten since boot.
  - [x] F32: reviewed image-cache cleanup with every previously Ready pod staying Ready, and a same-request replan of zero operations.
  - [x] B3 (EP-158) with the candidate CLI itself: the host record goes to the CDN, back to the origin on disable, is retained on retirement, and is collected.
  - [x] B6: takeover from a second root with a distinct client identity, after a plain resume and an unrelated plan were refused.
  - [x] EP-158 access grant/revoke: an interrupted acknowledgement resumed, then revoke.
  - [x] source-unavailable recovery: the newest verified backup after the seed, verified with the VM stopped and restored with its seed rows.
  - [x] the runner ran last, with plan, apply and verify back to back (verify interrupted, then re-run), and the cloud `inventory-evidence.json` assembled. The F48 guard (`platform-root.json` revision equals the candidate) held, and status showed zero `replaced-incarnation` after bootstrap and before the runner.
- [ ] **C4** (EP-154, owner f3, in progress on `b74b7e49`: the aarch64-darwin clone-free rehearsal passed with `typed-config`, and `nix flake check --all-systems` is green, 36/36 darwin and 35/35 x86_64-linux; F53 fixed the harness):
  - installed rehearsal without a repo clone on `aarch64-darwin` (workstation) and `x86_64-linux` (an amd64 container under Colima; if that can't run Nix plus the installed CLI, the user decides on the x86_64 builder VM);
  - `nix flake check` at the candidate;
  - this also proves A5's `typed-config` check name.
- [ ] **C5** (EP-157, owner f3):
  - `scripts/assemble-release.sh` over `coverage.json`, `local/` (C2), `cloud/` (C3), and per-system native outputs and clone-free records (C4);
  - IR-24 cases 1–7 mapped to that evidence;
  - `docs/releases/v<version>.md` stating the unmet production targets (D2 volumes, D4) and the D3 HTTPS/browser-login restriction;
  - a `workflow_dispatch` assembly run.

**Independent verification** (owner reviewer, arranged by the user; implementer sessions never self-close)
- [ ] Close every finding that is not yet Closed, per the [tracker](../../mp23-findings.md)'s closure rule:
  - Open: F48, F60, F61, F62, F63 (F61–F63 opened 2026-10-05 by independent verification; model reproductions pending)
  - Partial: F40, F59 (F59 reopened 2026-10-05: its post-stop exit fails for standalone databases)
  - Verifying: F15, F16, F30, F31, F32, F33, F39, F43, F44, F45, F46, F47, F51, F52, F53, F55, F56, F57, F58, F64, F65
  - Checkpoint 2026-10-05 (implementer, before the operator hold): fixes and model reproductions recorded for F59 gap A, F61, F63 (StatefulSets) and the new F64 and F65. Statuses are set by the reviewer. Further finding fixes are held pending the enumeration review and the structural exit-rule proposal; see [held work](../../mp23-held-work/README.md).
  - Closed 2026-10-05 by independent verification: F54 (F51 was closed, then reopened the same day by the exhaustive review: its fix refuses retirement of a replaced member)
  - F60 scheduled by ADR 27 (operator decision, 2026-10-05: approve all six); Open

  (Register as of 2026-10-05. The independent reviewer closed F34–F38, F41, F42, F49 and F50 on 2026-10-04.)

  Native proof already exists for:
  - F30: the A4 terminal resume, 2026-10-02;
  - F32: native image cleanup on the `14071e58` checkpoint;
  - F31: refreshes before expiry observed, with more during C3;
  - F33: exact collection on `7d486457`;
  - F34: the C2 preview cleanup;
  - F36, F37, F41: the C2 runs;
  - F45, F46, F47: the CDN cycle on the `mp23-c3g` checkpoint, to be repeated in the acceptance C3.

  So most of these need only the independent check. Per the operator decisions below, the F40 remainder moves to MasterPlan 25, and F48 is accepted for this release with a procedural guard. Its code fix belongs to EP-168.
- [ ] Accept or reject the recorded arguments:
  - EP-159 B1 source replacement, re-scoped to "out-of-band replacement refuses ingestion and isolated restore";
  - EP-160 B2 Redis load interruption and partial ClickHouse effect.
- [ ] Independent local PostgreSQL isolated restore with known content and the source preserved (EP-160).
- [ ] Confirm the rename recovery model's relaxed I4 (EP-173 Decision Log, 2026-10-05). A recreated copy Job only compares a non-empty destination; check this for every fault the model saw.
- [ ] Execute [the operations runbook](../../../runbooks/inventory-operations.md) end to end on the acceptance C3 context, before its teardown, and record F14–F18 and the cloud operational checks (EP-156; safe-use gate). Required for MP-23 completion (operator decision), in the same reviewer pass as the closures.

**Operator decisions** (all decided 2026-10-04)
- [x] F38 (P2, a GCS head-advance failure stops ambiguous): **fix before release** (operator decision, 2026-10-04). Implemented in `Execute/Journal`: bounded head retry with read-back, orphan adoption independent of proof equality, and store errors on stderr. It is in the next candidate.
- [x] Independent closure comes **before the release is published**, but runs **in parallel** with the candidate gates.
  - A reviewer session starts at the freeze, checking source fixes and regressions while C2–C4 run.
  - Findings that need native evidence (F15, F31, F33, F45–F47) are checked once C3 produces it.
  - The closures gate C5's publishing, not the runs.
- [x] The F40 remainder (collecting a full context's VM and its workloads) **moves to MasterPlan 25**. MP-23 covers perimeter-only exact cleanup plus retirement of every scope.
- [x] F48 (P2, evidence names the release manifest's payload without checking the payload the context runs): **accept the procedural guard for this release**; the code fix goes in EP-168.
  - Every acceptance run uses a fresh context from the candidate's own payload.
  - `platform root --json` is recorded before the runner's plan and saved with the evidence, so the reviewer can confirm which payload ran.
- [x] F51 (retirement retains a replacement's identity) and F52 (an address-changing migration reads as `replaced-incarnation` until it converges), both P2: first deferred, then **un-deferred and fixed in MP-23** (operator decision on the retrospective, 2026-10-04; fixed in `15ca45e1`, Verifying).
- [x] F58 (P2, an application whose first deploy stopped unready cannot be retired), found by the EP-173 model on 2026-10-05: **fix now in MP-23** (operator decision, 2026-10-05). Fixed with absence proofs; Verifying.
- [x] The independent runbook execution **stays required for MP-23 completion**. It is done in the same reviewer pass as the closures, on the acceptance C3 context before teardown. If reviewer availability becomes the bottleneck, the fallback is to narrow it to the safe-use gate, with the release notes saying the release is not cleared for real workloads until it passes.

**Close-out (Phase D)**
- [ ] Finalize the living sections of EP-153 to EP-160 and mark the registry.
- [ ] Distill durable lessons into ADR 22, and write this plan's Outcomes & Retrospective.
- [ ] Update IR-24's status from the evidence.

**Not required for MP-23** (recorded so nobody chases them):
- D4 recovery-time and retention targets;
- the data-protection and production gates;
- full-context VM collection, durable and topic collection (MasterPlan 25 and the deferred B5 scope);
- MasterPlan 26 streams.

**Non-blocking follow-ups:**
- cloud `server status` shows UNKNOWN for the litestream and volume backup rows ("gsutil unavailable"); f3 is recording it as a low-priority finding;
- a collectable lifecycle for the runner probe (harness).

**Snapshot (2026-10-02, consolidation assessment at `c57f1638`).** Seven foundation children are complete; eight remain In Progress. The architecture is implemented and holds up under independent review: typed composition, reviewed plans, the shared serial driver, conditional filesystem/GCS history, deferred-admission guards and the registration-only entrypoint all have evidence. Independent verification on 2026-10-02 additionally proved native F20 collection with interrupted-delete recovery, clean-root recovery, VM power transitions, CDN disable and purge, and isolated restores with checked content for PostgreSQL, Redis, ClickHouse and a volume on GCS. Access grant/revoke has only the implementer's native run on the retired fixture and must be re-proven in C3. That evidence spans roughly ten different candidates and partly the retired fixture, so none of it is yet final-candidate acceptance.

**Phase A checkpoint (2026-10-02, claude-opus-5-5, `d4aa7168`–`7e26a1bb`).** A6 is done: the full style gate passes. A1 (F33), A2 (F32) and A3 (F31) have source fixes with regressions that fail on the old code, and await independent closure and their native proofs (C3, or a cp3 image-cleanup run for F32). A5 is source-complete for the clone-free `typed-config` check (new read-only `nagarectl app check`) and the cloud fixture/health producer. The scenario-assertion names in health records still have no producer (see Surprises). A4 reached its terminal state later the same day. F34 was traced to reviewed DomainMapping collection using Orphan propagation and fixed in `beca6886` (ADR 22 amendment); cp3 was repaired under the gated EP-155 recovery, and the F30 transaction converged with identities, data and a zero-operation replan intact. F30, F16 and F34 await independent verification.

**Phase B checkpoint (2026-10-02, `cf3cd7fd`).** Two B1 pieces are done: `server status`/`doctor` grade each accepted database's recovery point from verified receipts, and the stale GCS statement in the backups guide is corrected. On cp3 the new rows show breaches without operator ingestion, which is the D1 gap now visible on the operational surface. B2–B6 need native local or cloud runs, and B3/B6 need operator approval for cloud mutation.

**Operator decisions and B1 checkpoint (2026-10-03, claude-opus-5-5).** The operator decided D1, D2, D3, D5 and the new D6 (Decision Log). D1 and D6 are source-complete. Freshness counts verified pending uploads. `db escrow-signing-key` and `db verify-escrowed-backup` escrow the signing key and verify receipts without the cluster. `NAGARE_BACKUP_RECOVERY_POINT=hourly|daily` sets the schedule and is bound into the signed metadata. 1,138 tests and the style gate pass. On cp3 (read-only, development binary), all five recovery-point rows turned healthy without ingestion, and escrow plus offline verification succeeded with refusals intact. D2 and D3 are recorded in docs and EP-157/158. D5 is recorded in an ADR 22 amendment. The public `scheduledRetention` check exposed a status bug: the signing Secret was matched on API group `v1` instead of the core group. It is fixed in `6bb275e7`, and on cp3 all five schedules are now listed. Orphan uploads are documented as permanently unresolved (operator decision). B1 still needs source-replacement ingestion, which is a native run.

Open findings ([tracker](../../mp23-findings.md)): F36 (a failed Redis scratch restore could not be abandoned; fixed in `6d7951c9`, Verifying), F35 (preflight refusal after admission strands the transaction; found by the 2026-10-03 cp3 drills; fixed in `570467f0` with the `abandon-refused-operation` decision and proven natively, Verifying), F34 (DomainMapping Orphan collection broke the Kourier gateway; source fix and cp3 repair done, verification pending), F30 (status-only churn strands an admitted Service correction; source fix in `95b58a24`/`52432400`, native correction interrupted at the operator's instruction with its transaction preserved, per `c57f1638`), F31 (registry credential refresh can lag expiry), F32 (image cleanup can select a sandbox image in use), F33 (cloud collection does not recheck the reviewed physical incarnation; unfinished guard checkpointed in `27bb0cd4`). F15 and F16 are Verifying.

**cp3 data drills (2026-10-03, implementer, under the cp3 claim protocol agreed with session nagare-phase-b).** B2 database-tamper refusal and wrong-destination refusal at planning are proven natively. A foreign object created between plan and apply wedged the store (new P1 F35), and the store was recovered. Volume tamper detection happens only inside the Job, after the scratch PVC exists (EP-160 Surprises). The B1 source-replacement premise conflicts with the design; no supported replacement exists (EP-159 analysis). [Raw record](../../mp23-implementer-results-2026-10-03/cp3-data-drills.json).

**Phase B close and candidate freeze (2026-10-03).** Phase B is code-complete. What is left needs cloud runs (B3, B6, manual cloud Redis/ClickHouse receipts, native F32/F33) or independent verification. Release candidate `db808a74` is frozen for Phase C, and any later code change makes a new candidate that must re-pass C1. C1 passed for `db808a74` on 2026-10-03: 213 verification-only operations, zero mutations, unchanged digests ([proof](../../mp23-implementer-results-2026-10-03/c1-local-gate-db808a74.json)). C2 (the full local scenario on a fresh local context) is assigned to session nagare-phase-b and starts after C1. The C3 cloud work, with B3, B6 and the F32/F33 proofs folded in, is written as one bounded sequence awaiting a single operator approval: [EP-156, "C3 bounded cloud sequence"](../../../plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) with target [`c3-target.json`](../../../../fixtures/inventory-release/gcp/c3-target.json).

**Candidate `44ff0fd7` (2026-10-03).** The F37 fixes made a new candidate, `44ff0fd7`: abandonment of a `Failed (KnownNoEffect)` operation (`d9aed800`), and the reviewed field-ownership takeover `app deploy --take-over-fields` (`1df735a6`). C1 passed for it on the C2 context's accepted `db808a74` payload: 213 verification-only operations, zero mutations, digests unchanged ([proof](../../mp23-implementer-results-2026-10-03/c1-local-gate-44ff0fd7.json)). That first required one reviewed refresh of the bootstrap stamp, which was stale from C2's platform-scope reviews; the runbook explains why. C2 must restart on a fresh local context carrying the `44ff0fd7` payload (EP-155 Decision Log, ADR 6). The C3 run on `db808a74` (context `mp23-c3`) continues only as a checkpoint. Its cluster stage found F38 (P2): a failed GCS head advance after a published journal event stops ambiguous and drops the store error. `inventory resume` adopted the orphan event. Final C3 needs a fresh cloud context on the final candidate.

**Checkpoint teardown and new fixes (2026-10-03).** Staged teardown ran natively for the first time, on the C3 checkpoint, and found:
- **F39:** Pulumi preparation; fixed in `24320d82`.
- **F40:** contribution targets, scope cycles, host and artifact retention, and cloud-retirement observation; fixed in `8fef3559` and `07d203ad`.

Every platform scope and the cloud scope then retired natively. Collection stopped at the design gap described in the Decision Log, which has moved to MasterPlan 25. The checkpoint was deleted out of band with operator approval. In the C3 checkpoint, F15 and F31 refresh behaviour was observed: an uncached private controller pull 109 minutes after boot, and a timer refresh four minutes before expiry. The next candidate collects these fixes plus the local MinIO durability work (F41, nagare-phase-b). It then needs C1, a fresh C2, and a fresh C3 on [`c3-final-target.json`](../../../../fixtures/inventory-release/gcp/c3-final-target.json).

**Candidate `14071e58` (2026-10-03).** Frozen with F39, F40 and F41. C1 passed on the fresh local C2 context immediately after its platform bootstrap: 214 verification-only operations, zero provider mutations, digests unchanged, 35 pods ready ([proof](../../mp23-implementer-results-2026-10-03/c1-local-gate-14071e58.json)). The acceptance C2 (nagare-phase-b) and the final C3 (`mp23-c3f`, `*-c3-1004`, operator-approved) are running on it.

**Candidate `7d486457` (2026-10-04).** Frozen with F42, F43, F44 and the coverage dispositions; the managed-command audit is complete. C1 passed on the fresh local C2 context immediately after its platform bootstrap: 214 verification-only operations, zero mutations ([proof](../../mp23-implementer-results-2026-10-03/c1-local-gate-7d486457.json)). The candidate's own build proved perimeter-only exact collection on a disposable context (EP-156 Decision Log). The acceptance C2 (nagare-phase-b) and the final C3 (`mp23-c3g`, `*-c3-1005`, CDN enabled) are running on it. The `14071e58` C3 checkpoint ([record](../../mp23-implementer-results-2026-10-03/c3-checkpoint-14071e58.json)) was removed after export.

**Scenario assertion checkpoint (2026-10-03).** The record shape is agreed and implemented across EP-155, EP-156 and EP-157. C2 and C3 now produce gate-ready health by recording each assertion as it passes and finalizing after verify. A name without a bound record refuses at assembly and in the CLI validator.

**B5 checkpoint (2026-10-03, claude-opus-5-5, `dc53beb3`–`6ed92e61`).** B5 is source-complete with bounded cp3 proof on development binaries.
- **Companion collection.** Retained collection now admits StatefulSets (Background propagation), ServiceAccounts, Roles and RoleBindings. On cp3 a retired PostgreSQL lost exactly its six stateless companions in three dependency-ordered reviews, while its PVC and Secrets kept their UIDs.
- **Rename.** `db rename` is the first native binding of EP-149's migration contract. On cp3 it moved a seeded database through 72 reviewed stages. The rows survived, all nine old incarnations stayed retained and fenced, and the auth signing key kept its identity.
- **Fixture.** `fixtures/inventory-release/local/scenario.json` defines the full C2 run and is validated against the gate's check names.

The native run exposed two review readers that assumed base mutations; both are fixed in `bc2fd90e` (Surprises). 1,148 tests, the style gate, the command audit and the CLI architecture check pass. The four Haskell architecture size overages came from `9fef284a`; they were fixed in `2124ce2a`. Collection of durable members, topics and migrated-away incarnations is the scope proposal below.

**Remaining work.** (Historical plan of record. For current status use the Finish line at the top of this section.) Each item is owned by the named child, whose plan holds the detail. Work proceeds in this order; items within a phase can run in parallel.

Phase A — blockers (code and local regressions; no cloud mutation):

- A1 (EP-153): finish F33 — bind the selected stack entry, physical ID and protection into collection evidence and recheck them at preflight and immediately before execution; regression for a change between the two.
- A2 (EP-153): fix F32 — protect images referenced by Ready and retained sandboxes and the configured sandbox image; fail closed on missing sandbox observations.
- A3 (EP-154/156): fix F31 — align refresh cadence and the token-lifetime check with metadata-token caching so a refresh always lands before expiry.
- A4 (EP-153/156, executed on local `cp3`): bring the interrupted F30 correction transaction, which lives in the local `nagare-mp23-cp3` store, to a terminal state through the supported resume path, then verify F30 and F16 independently with the known row and identities preserved. Do not dispose of `cp3` before this transaction is terminal.
- A5 (EP-157/154): make the clone-free rehearsal emit the check names the release gate requires (`typed-config`; it currently emits `inventory-compile`), add the missing cloud `fixture.json` and `cloud-health.json` producer, and correct `docs/user/upgrades.md`, which still calls inventory evidence an optional attachment.
- A6 (EP-153): make the repository-wide `just haskell-style-check` (including fourmolu over all tracked Haskell files) pass and keep it passing.

Phase B — finish the supported features (code plus focused local proof):

- B1 (EP-159): make the recovery-point objective hold unattended by counting verified pending uploads and escrowing the signing key off-cluster (D1); make the objective a per-context `hourly`/`daily` preset bound into the signed schedule (D6); surface freshness in `server status`/doctor rather than only `--check-freshness`; state volumes as outside the objective (D2); prove source-replacement ingestion; give orphaned uploads (objects without a receipt) a public disposition, show `scheduledRetention` as unenforced in `inventory status`, and correct the stale GCS-acceptance statement in `docs/user/backups-and-disaster-recovery.md`.
- B2 (EP-160): native refusal of a tampered accepted backup (database and volume) and of a wrong-incarnation destination; interruption during Redis load and a partial ClickHouse restore, or a recorded argument that existing runs cover them; manual cloud receipts for Redis and ClickHouse or an explicit scheduled-only statement.
- B3 (EP-158): native Google DNS/CDN create, disable, retire and collect; record the HTTPS/browser-login disposition (decision D3).
- B4 (EP-153): promote the `Cleanup` and `InfraDestroy` routes and the `infra-destroy`, `smoke` and `local-smoke` recipes; bring every gap row in the coverage catalogue to migrated or an explicit guarded exclusion. Status 2026-10-03: gap rows are down from 26 to 1, and `smoke`/`local-smoke` are promoted with restored-sentinel readback. `Cleanup`, `InfraDestroy` and `infra-destroy` wait on the independent closures of F32 and F33.
- B5 (EP-155): check in the full local scenario fixture; implement the bounded retained PostgreSQL rename (IR-24 case 3) and companion collection bindings. Source-complete with cp3 proof (2026-10-03 checkpoint); final-candidate proof is C2.
- B6 (EP-156): prove takeover from a genuinely different client.

Phase C — one frozen candidate, proven natively:

- C1: installed local platform bootstrap on `nagare-mp23-cp3` (candidate gate).
- C2 (EP-155): the full local scenario including interruption, wrong-incarnation refusal, history export/restore and the PostgreSQL rename.
- C3 (EP-156): a fresh cloud context with typed host credential delegation; the six operational checks (application change with owner isolation and unchanged replay; GCS backup and isolated restore; interrupted-operation recovery; clean-root recovery; writer refusal/takeover; exact cleanup including cloud teardown); a genuine automatic credential refresh and expired-credential pull (F15); independent runbook execution for the safe-use gate.
- C4 (EP-154): clone-free installed rehearsal on aarch64-darwin and x86_64-linux at the candidate revision, with `nix flake check` green.
- C5 (EP-157): non-publishing assembly of `docs/release-evidence/<revision>/`, IR-24 cases 1–7 mapped to that evidence, release notes stating unmet production targets.

Phase D — close-out: finalize each child's living sections, mark the registry, distill durable lessons into ADR 22, update IR-24's status from evidence.

**Operator decisions.** D1, D2, D3, D5 and D6 were decided on 2026-10-03 (see Decision Log). One remains pending and is not the implementer's to make:

- D4 — Recovery-time and retention targets for production use (no values have been agreed). It gates production use, not MP-23 completion; EP-157 reports it as an unmet production target.

Scope proposal from B5, decided 2026-10-03 as deferred (Decision Log). Three collections would each need a new operation, not a missing binding:
- releasing durable PVCs and credential Secrets;
- deleting broker topics, which also keep a retired broker's StatefulSet blocked;
- collecting a migrated-away incarnation that shares a live ResourceId.

None is required by the supported release contract. Retained members stay visible in status, and a renamed database's old writers are fenced.

**Cross-plan gates.**

- *Safe-use gate* (before any real low-risk workload): on one candidate that first passed C1 — the six cloud operational checks and F15 on a fresh context; EP-158 access grant/revoke; [the operations runbook](../../../runbooks/inventory-operations.md) executed end to end by an independent reviewer with F14–F18 recorded in the tracker; driver consolidation present. Final production go/no-go remains the operator's.
- *Data-protection gate* (before real company data): the context uses the `hourly` objective; every signing key is escrowed; every authoritative store backed up off-cluster within the one-hour objective measured from the latest usable recovery point (including upload, verification and retry delays); freshness deterioration visible before breach and a breach reported unhealthy; backups and recovery credentials retrievable with the cluster and operator root gone; verified restored content; corruption and incomplete-upload refusal; documented, timed recovery procedure.
- *Production gate* (outside MP-23 completion): the MP-21 supported upgrade/recovery rehearsal on an inventory-backed context.

