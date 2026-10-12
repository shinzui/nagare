---
id: 155
slug: prove-local-application-and-data-recovery-end-to-end
title: "Prove local application and data recovery end to end"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T22:23:39Z
      mode: "update"
      note: "Cascade EP-148 decomposition: assign remaining feature, cutover, and proof ownership without weakening release acceptance"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:29:12Z
      mode: "implement"
      note: "Start local health fixture and repair observed k3d registry provider binding"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:10Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T05:44:42Z
      mode: "implement"
      note: "Accept installed full native local platform-bootstrap candidate gate and repair stale recording-fixture membership"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:25:08Z
      mode: "implement"
      note: "F34 diagnosis and gated recovery: DomainMapping Orphan collection leaves KIngress that breaks Kourier"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T14:20:42Z
      mode: "update"
      note: "Adopt the agreed scenario assertion record and finalize procedure"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T16:03:44Z
      mode: "implement"
      note: "B5: scenario fixture, native stateless companion collection, native reviewed PostgreSQL rename with cp3 proof"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T20:36:19Z
      mode: "implement"
      note: "F37: execute-time no-effect abandonment (d9aed800), reviewed field takeover (1df735a6); C2 adoption/drift/storage notes"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T22:41:09Z
      mode: "implement"
      note: "F41: durable local MinIO and offline escrow verification; 44ff0fd7 C2 checkpoint"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-04T14:16:36Z
      mode: "update"
      note: "C2 on 7d486457 finalized and assembled; what binds what"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-04T17:47:54Z
      mode: "implement"
      note: "C1 and C2 on frozen candidate 7596632c, assembled"
---

# Prove local application and data recovery end to end

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) (MP-23), which owns the supported release contract, the remaining-work phase IDs (A1–C5) and the pending operator decisions (D1–D5); this plan must agree with it. The plan was consolidated on 2026-10-02. Its earlier text, including every dated checkpoint and failed attempt, is preserved verbatim in [the pre-consolidation snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md); nothing in the snapshot overrides this file.

Full plan before trimming: [155-prove-local-application-and-data-recovery-end-to-end.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, one reproducible, disposable local run proves that an installed Nagare release candidate works end to end on a workstation. Using only public `nagarectl` commands, it bootstraps the platform on a local k3d cluster, deploys two independently owned applications with data, changes one without disturbing the other, survives interruption at every stage without repeating completed effects, backs up and restores every supported data store into isolated targets, recovers content while the source is unavailable, renames one retained PostgreSQL database without losing rows, collects only exactly eligible leftovers, and restores its private history into a fresh state root. The run writes redacted evidence that the release gate ([EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md)) accepts for the final candidate.

To see it working: the local runner's `verify` phase writes `target.json`, `fixture.json`, `local-health.json` and `inventory-evidence.json` into a new evidence directory, and `scripts/assemble-inventory-release-index.py` accepts that directory for the candidate revision. Cloud-only behavior (GCS shared history, writer takeover, the Compute Engine host, Google CDN) belongs to [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) and is never claimed from this local run. Completing this plan does not make Nagare production-ready; MP-23's data-protection and production gates are separate.

## Progress

Evidence counts toward final acceptance only where its recorded inputs (operator revision, payload, fixture definition and target) match the final candidate; everything recorded before that candidate exists is checkpoint evidence that shows the path works and which defects were fixed. "Implementer" marks evidence recorded by the implementing session; "independent" marks evidence from the independent reviewer in [the 2026-10-02 verification](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-verification-2026-10-02.md).

- [x] Installed local platform bootstrap on `nagare-mp23-cp3` (2026-09-30, implementer, candidate `705716b7`, payload `nagare-0.4.0-705716b7bdb7`): a fresh 217-operation platform review converged all 19 scopes, and an unchanged replan had 213 verification-only operations and zero barriers ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-native-bootstrap-results-2026-09-30/local-platform-candidate-705716b7.json)). Later installed CLIs passed the same cp3 gate independently against this accepted payload (`a027d1f6`, `76628094`, `ec2e1cd4`, `e6255e6f`, `c4d219e4`, `3905012e`, `caa37d19`, `c352cfec`, `762657ed`, `b805d64a`; for example [b805d64a](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/local-gate-b805d64a.json)). Those are CLI gates on an old payload, not fresh candidate-payload bootstrap.
- [x] First production path (2026-09-27, implementer only, installed `e97d65e1` on an earlier six-CPU Colima fixture, private `/tmp` evidence not checked in): platform, then applications A and B each with a separately owned retained PostgreSQL, then a read-only replan of both with seven VerifyResource operations, zero writes and zero barriers; both Knative Services kept their UID and Ready revision.
- [x] Local Redis, ClickHouse and volume isolated restores through MinIO (2026-10-02, independent, installed `ec2e1cd4` on cp3): automatic signed producers ran, the producer Jobs were removed before ingestion, isolated restores returned the original content while sources kept later changes, and accepted-only freshness reported healthy at 515 s ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)). Local PostgreSQL through MinIO is not part of this record.
- [x] Local release-history pruning and preview cleanup (2026-10-02, independent, cp3, frozen source executables rather than an immutable release binding): the F28 fix updates exactly one history ConfigMap and preserves adjacent members and 29 unselected scopes ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/release-cleanup-native-f28-fixed.json)); the F29 bounded preview-route correction and the following preview cleanup collect two stateless members and retain the durable PVC and its contents ([correction](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/preview-domainmapping-correction-f29.json), [cleanup](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/preview-cleanup-native-b805d64a.json)).
- [x] (F34 recovery, before C2) Kourier on cp3 accepts gateway updates again and preview cleanup no longer orphans DomainMapping descendants; see "F34 recovery" in Plan of Work for the gates. Diagnosis (2026-10-02, read-only): the orphaned KIngress and KCertificate of collected preview DomainMapping `7c6ab388…` put host `mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` into two HTTPS filter chains. Done (2026-10-02): step 1 source fix `beca6886` (gate: three authority regressions, 1,132 tests, six public cleanup variants, style gate). Step 2: two preconditioned Background DELETEs at 04:38:09Z; gate met within 20 s (no listener `error_state`, `mp23-correction-proof` Ready, prior routes Ready). Step 3: F30 resume converged; identities, known row and the zero-operation replan check out. Independent F34 verification and a native reviewed DomainMapping collection on the candidate remain (C2). (2026-10-09: F34 is Closed in [the tracker](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-findings-closed.md#f34). On the final candidate `83124396`, C2's reviewed preview cleanup collected the DomainMapping and Service with their KIngress and KCertificate descendants, and the other route was unchanged (`convergence-noop-removal`; [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396).)
- [x] (MP-23 B5) The full local scenario fixture is checked in (2026-10-03, `6ed92e61`). `fixtures/inventory-release/local/scenario.json` keeps the runner's health contract and defines the C2 run: applications A and B (typed Applications under `apps/`, each with frozen source and a Dockerfile), the collision variant, the site preview, channels, broker topic, scheduled and one-off Jobs, seed content and a later change for all four stores, the rename, the companion collection, the four interruption stages, and a step map for every scenario check the gate requires. The runner now copies it as `fixture.json`. `scripts/test-local-scenario-fixture.py` holds it to the gate's sensitivity rule and local check names; with `--check-configs` all three Applications pass `nagarectl app check`. During C2, record each assertion with `scripts/scenario-assertions.py record --mode local` as it passes, and run `finalize` after verify to produce the gate-ready `local-health.json`.
- [x] (MP-23 B5) A bounded retained PostgreSQL rename (IR-24 case 3) creates the new incarnation, migrates, verifies known rows and an unchanged auth signing-key identity, and retires the old one through public commands. Source `29f8a852`, `040040dd`, `bc2fd90e`; `InventoryPostgresRenameSpec` covers convergence, a lost transfer acknowledgement and a replaced source. Native cp3 run (2026-10-03, implementer, development binary): `db rename postgres mp23-b5-rename-src mp23-b5-renamed` reviewed 72 stages and converged in 70 s. The three known rows read back on the new Pod. All nine old incarnations stayed retained with unchanged UIDs, the old StatefulSet fenced at zero replicas and the old backup schedule suspended. `nagare-system/nagare-shomei-keys` kept its UID, resourceVersion and data digest, and every other StatefulSet and PVC kept its UID ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/cp3-postgresql-rename-bc2fd90e.json)). The run also exposed two review-reader defects, fixed in `bc2fd90e` (see Surprises). Final-candidate proof remains C2. (2026-10-09: `retained-postgresql-rename` passed in C2 on `83124396`: 72 reviewed stages, the three known rows read back, the old incarnations stay retained with unchanged UIDs and fenced writers, and the auth signing key is unchanged; [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396).)
- [-] (MP-23 B5) Companion collection bindings collect only exactly eligible database and broker companions, broker topics and schedules while protected neighbors survive, each with a focused local proof. Database companions done (2026-10-03, implementer, `dc53beb3`, development binary on cp3): reviewed collection now admits StatefulSets (Background propagation), ServiceAccounts, Roles and RoleBindings. A retired standalone PostgreSQL lost exactly its six stateless companions in three dependency-ordered reviews (backup CronJob; StatefulSet and RoleBinding; Service, Role and ServiceAccount). Its PVC and both Secrets stayed retained with unchanged UIDs, a PVC collection was refused at planning, and the neighbors' UIDs were unchanged ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/cp3-companion-collection-dc53beb3.json)). The backup CronJob is the database's schedule; application schedules already collect through `task delete`. Broker companions and topics have no eligible member under the current policy (see Decision Log, 2026-10-03). Database companions: confirmed on the final candidate `83124396` (2026-10-09: C2's `retained-data` collected only `scenario-retire`'s stateless companions in dependency order, kept the PVC, credential and signing key retained, and refused the PVC collection; [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396)). Broker companions and topics: Superseded/Moved (2026-10-09): MP-23's Decision Log (2026-10-03) deferred releasing durable data, deleting broker topics and collecting migrated-away incarnations to MP-21 or a later data-lifecycle plan; none is in the v0.4.0 contract. Closed (2026-10-09): database companions are done; broker companions and topics have no eligible member under the policy deferred on 2026-10-03. {disposition=out-of-scope}
- [x] (MP-23 C1) The final candidate passes the installed local platform bootstrap gate on cp3: a verification-only unchanged replan with zero provider mutations and all accepted scope digests unchanged. Passed 2026-10-03 (implementer) for frozen candidate `db808a74`, installed with `nix build .#nagarectl` (`/nix/store/pl52mxv9…-nagarectl-0.4.0`). The public platform bootstrap plan took 39 s and produced 213 `VerifyResource` operations; apply took 55 s. No provider mutation occurred, all 36 accepted scope digests are unchanged, the head is idle at generation 10019, and 71 pods are Ready or Succeeded ([proof](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c1-local-gate-db808a74.json)). As before, this is a CLI gate on the retained accepted payload `705716b7`, not a fresh-payload bootstrap; that is C2. (2026-10-09: on the final candidate `83124396`, C1 ran on the fresh C2 context bootstrapped from the candidate's own payload: 214 operations, all `VerifyResource`, no provider mutation; [proof](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396/c1-proof.json).)
- [x] (MP-23 C2) In one run on a fresh local context bootstrapped with the final candidate's own payload: platform plus applications A and B with protected routing and auth, PostgreSQL, a broker topic, scheduled and one-off Jobs, a preview, Runtime/Preview/Secret channels and image publication converge; an app-only update preserves the other owner's and the platform's revisions; and an unchanged replan performs zero writes. Done 2026-10-03 (implementer) for frozen candidate `14071e58` on a fresh context with its own payload, after C1 passed on that payload (214 VerifyResource, zero mutations); [record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json). (2026-10-09: repeated independently on the final candidate `83124396` by nagare-verify on a fresh context with payload `nagare-0.4.0-831243962c6b`: 16 of 16 assertions; [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396).)
- [x] (MP-23 C2) In that same run: interruption at each stage resumes without duplicate effects; a wrong-incarnation destination is refused; PostgreSQL, Redis, ClickHouse and a volume restore into isolated targets with checked content through MinIO; content is recovered with the source cluster unavailable; the private history export restores into an isolated state root with identical accepted identities; the PostgreSQL rename and companion collection pass. Done 2026-10-03 (implementer) for frozen candidate `14071e58` on a fresh context with its own payload, after C1 passed on that payload (214 VerifyResource, zero mutations); [record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json). (2026-10-09: the same checks passed in the 16/16 C2 run on the final candidate `83124396`, including `interrupted-recovery`, all four backup-restore checks, `source-unavailable-recovery`, `retained-data` and `retained-postgresql-rename`; [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396).)
- [x] (MP-23 C2 checkpoint) Full scenario on a fresh context with candidate `44ff0fd7`'s own payload (2026-10-03, implementer). 15 of 16 assertions recorded; F37 (field takeover) and F36 (failed Redis scratch abandonment) proved natively; the runner verified a zero-operation replan after a final-marker interruption. `source-unavailable-recovery` was not provable because the node stop deleted the local `emptyDir` bucket (F41), so `finalize` refused as expected. Checkpoint only: the acceptance run needs the next candidate. [Record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json).
- [x] (MP-23 C2) The run's evidence directory is accepted by `scripts/assemble-inventory-release-index.py` for the final candidate revision, with private exports and credentials kept out of it. Not yet (2026-10-03): `local-health.json` is finalized with all 16 assertions for `14071e58`, but `scripts/assemble-managed-resource-evidence.sh` refuses with "initial review has no bound operations" because the runner's plan candidate is the unchanged kourier and cert-manager replacement (0 operations). The decision is with EP-157 (C5); see the [record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json).

  **Update (2026-10-04, implementer, frozen candidate `7d486457`):** a fresh-context run finalized 16/16, and `assemble-managed-resource-evidence.sh` accepted the same directory. Index acceptance is the remaining step, done in C5 (nagare-f3).
  - **Assembly inputs:** the pinned worktree's assembler, its release manifest and complete coverage.
  - **Assembly result:** run `142b49a3…`, 46 scope revisions, 1 component receipt, no flagged keys.
  - **What binds what:** the one directory `evidence/c2-7d486457` holds everything.
    - `local-health.json` binds the 16 scenario assertions.
    - `inventory-evidence.json` binds the self-contained runner rehearsal: one `CreateResource` of the packaged probe, applied, then a verified zero-operation replan with a complete final observation.
    - `checks/` and `assertions/` hold the per-check evidence and records.
    - nagare-f3 places the directory under `local/` for C5.
  - **How the runner ran:** last, with plan, apply and verify back to back. Evidence was staged and records deferred until the runner's plan created the directory.
  - **First run that day:** it finalized 16/16 but could not be assembled. The runner's plan and apply ran early and its verify ran late. A repair was refused because the probe is declared `Retain`.
  - **Records:**
    - [the C2 record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-7d486457.json);
    - [the C1 proof](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c1-local-gate-7d486457-rerun.json);
    - the procedure, in [runbook §6](https://github.com/shinzui/nagare/blob/0331adaec93a69083e6e7295afa72b91540fb8e1/docs/runbooks/native-verification-harness.md).

  **Update (2026-10-04, implementer, frozen candidate `7596632c`):** `7d486457` became a checkpoint when C3 found F45–F47. The acceptance C2 for the new candidate finalized 16/16 on a fresh context with the candidate's own payload, and the assembler accepted the same directory.
  - **Assembly result:** run `af847e74…`, 46 scope revisions, 1 component receipt.
  - **C1:** 214 `VerifyResource`, zero mutations.
  - **Payload guard (F48):** `platform-root.json` records payload `nagare-0.4.0-7596632cee07`.
  - **Source-unavailable drill:** the first attempt picked a scheduled backup taken 62 s before the seed rows were written, because the receipts list is not time-ordered. Offline verification passed but the content check failed. The node was restarted and the attempt kept as evidence. The drill now selects the newest verified recovery point after the seed, and passed with the 17:30:01 backup.
  - The directory went to nagare-f3 for C5 index acceptance. Records: [C2](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-7596632c.json), [C1](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c1-local-gate-7596632c.json).

  **Update (2026-10-04, implementer, frozen candidate `84754389`):** `7596632c` became a checkpoint when the EP-159 drill found F49.
  - The acceptance C2 for `84754389` passed first time: 16/16, and the assembler accepted the same directory (run `282902a2…`).
  - C1: 214 `VerifyResource`, zero mutations.
  - F49 side-effect check: zero `replaced-incarnation` findings after C1 and before the runner.
  - `platform-root.json` records payload `nagare-0.4.0-847543896d07`.
  - The directory went to nagare-f3 for C5.
  - Records: [C2](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-84754389.json), [C1](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c1-local-gate-84754389.json). The F49 native drill on the same context is [recorded separately](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/ep159-source-replacement-84754389.json).

  **Update (2026-10-05, implementer, frozen candidate `b74b7e49`):** this adds only the F53 check-harness fix; no shipped source changed.
  - C1 (214 `VerifyResource`, zero mutations) and the acceptance C2 passed first time: 16/16, assembled (run `39d59de4…`), zero `replaced-incarnation` after C1 and before the runner.
  - `platform-root.json` records `nagare-0.4.0-b74b7e49bf33`.
  - The deferred F52 shows during the interrupted rename, as expected, and is recorded.
  - Records: [C2](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-b74b7e49.json), [C1](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c1-local-gate-b74b7e49.json), and the archived C2 evidence directory [`c2-b74b7e49/`](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/c2-b74b7e49/README.md).

  **Final (2026-10-09, independent, final candidate `83124396`):** C2's directory finalized 16/16 and the assembler accepted it ([C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396)). C5's `scripts/assemble-release.sh` then built the inventory index from it as `local/`, binding source revision `83124396`, twice with byte-identical output; `SHA256SUMS` verifies ([C5](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c5-83124396), [public local evidence](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/local)). The public directory holds only targets, health, fixture, inventory evidence and hashed check files; private exports stayed in the operator root.

## Surprises & Discoveries

Condensed in-force findings; dated detail is in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md).

On the macOS workstation, AirPlay intercepts host port 5000, so host tools cannot reach the fixed k3d registry directly, although Docker and the k3d node can. Publication uses a loopback SSH forward into Colima with `skopeo`, which preserves the reviewed manifest digest; `docker load`/`docker push` rewrites the digest and was rejected. The registry health probe observes the registry from inside its container.

The pinned upstream MinIO server and client images are no longer pullable (Quay 401, Docker Hub refusals, legacy download host 410). `scripts/publish-local-minio-images.sh` builds local images from the upstream GitHub release binaries after checking their published SHA-256 digests; the local-object-store compiler accepts both overrides only together and only as exact `k3d-registry.localhost:5000/nagare-{minio,mc}@sha256:...` references.

The default four-GiB Colima VM cannot hold the full platform plus applications; a six-CPU, 12-GiB profile can. That profile is `nagare-mp23-cp3`. The installed kubeconfig uses `local` as context and cluster alias while k3d's physical cluster is `k3d-nagare-local`; the local runner checks the API server and CA against k3d's kubeconfig and records both names.

F30 (controller status churn strands an admitted Service correction) was first observed on cp3, not in the cloud ([evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/application-status-race-f30.json)). The independent correction under source fixes `95b58a24`/`52432400` landed on the original Service UID and was then interrupted at the operator's instruction; its transaction `tx-b4da295e…` remains active at head generation 9314/sequence 9210 on the cp3 `local` store ([handoff](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/application-status-race-f30-handoff.json)). The Service UID in that handoff matches the local F30 record.

The release gate requires exact check names in `local-health.json`; a producer that emits different names is refused at assembly even if the behavior passed (MP-23 A5 addresses the analogous clone-free mismatch). The gate also rejects any fixture key matching its sensitivity pattern, including a key spelled like the `secret-read-refusal` check, so the scenario fixture lists assertions as objects with `name` values.

2026-10-03 (B5 rename): Two readers assumed every Kubernetes review member is a base mutation. Both migration bundles and the native run exposed it. `kubernetesSpecsFromReview` refused the saved rename review before admission: nothing was admitted and every UID was unchanged. Review publication stored no observation bytes for migration stages, so after convergence `inventory status` failed context-wide. cp3 was recovered with the public `inventory store materialize-native`, which only adds digest-addressed bytes (head generation unchanged at 9563). Both readers now take the destination object from the bundle (`bc2fd90e`). The end-to-end test had bypassed the CLI's spec reconstruction and observation loading; it now exercises both.

2026-10-03 (B5 rename): A migrated-away incarnation keeps the live ResourceId, so reviewed collection cannot select it (`active-incarnation`). Rather than leave a backup CronJob firing against a fenced database, the rename fences writers. Their fenced state is observed as the retained incarnation, not as drift. Stored history orders dependencies canonically, so the command's old-name equality check compares dependencies as sets.

2026-10-03: `scripts/check-haskell-architecture.py` already failed at the handoff commit for `Target.hs`, `AppDeploySpec.hs`, `InventoryApplicationSpec.hs` and `InventoryKubernetesSpec.hs`. B5 kept its own files within their allowances by moving the collection request, the migration planner and the fence predicates into separate modules. The pre-existing overages are not addressed here.

2026-10-03 (C2 adoption): `inventory status` reports only accepted addresses. Its `unowned` category means an accepted address observed without its owner stamp (`Status.hs` `UnownedResource`). A foreign object at an address no review has accepted is not listed. The adoption evidence is therefore the planner refusal: a restore whose scratch PVC address already held an unowned PVC refused with `adoption-required`, saved no review and left the store generation unchanged. Status was captured to show the object absent from findings (`checks/adoption/status-unowned.json`). Accepted by the implementer (nagare-f3) as the adoption evidence.

2026-10-03 (C2 drift, F37): Classification works: one `configuration-drift` finding for a `kubectl patch` on application B's Service, distinct from the `retained-orphan` members of the retired `scenario-retire`. The reviewed repair was refused because the field belongs to another manager (`kubectl-patch`). The admitted transaction `tx-a248f688…` then had no supported exit (`abandon-refused-operation` requires an operation with no recorded intent; resume repeats the refusal), which blocked the rest of the C2 run on that store. Tracked as [F37](../audits/mp23-findings.md#f37); `drift-classification` is not recorded as passed.

## Decision Log

2026-10-03 (F41, decision relayed by nagare-f3): Local MinIO keeps its bucket on a `local-path` PersistentVolumeClaim instead of an `emptyDir`. This supersedes the EP-100 decision that local backups may evaporate: local mode now carries release evidence for backups, restores and source-unavailable recovery, and the C2 checkpoint showed that one node `docker stop` deleted every local backup and the bucket. The volume still dies with the k3d cluster. Local `verify-escrowed-backup` gains an explicit loopback offline target so recovery evidence does not need the source cluster.

Condensed decisions still in force; the full entries are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md).

2026-10-03 (B5 companion scope): "Exactly eligible" means eligible under the lifecycle policy already in force (EP-149, ADR 22): `DeleteWhenUnreferenced`, `Stateless`, a supported kind, and no retained or accepted consumer. A database's stateless companions qualify. Its PVC, credential and signing-key Secrets are `Retain`/`Durable` and stay retained. Broker topics are `Retain`/`Durable` and ordered after the broker StatefulSet, so a retired broker has no collectable member while its topics are retained. Releasing durable data or deleting topics would be a new operation with a new typed release policy, which EP-155 treats as a scope proposal for the MasterPlan and not a missing binding. It is recorded there and not implemented. Collection stays one review per dependency layer, because a candidate counts every retained declaration, including one selected in the same review, as a consumer.

2026-10-03 (B5 rename design): The rename keeps the database's logical identity (pinned scope key) and migrates all nine members under EP-149's contract. It copies the data volume file for file from the fenced old writer into a new PVC with a one-shot Job on the database image, and compares full manifests in both the copy and a separate verify pass, because the new StatefulSet depends on the verified destination PVC and cannot start first. Credentials keep their values, with only the in-cluster host in `DATABASE_URL` rewritten, so the copied data directory still authenticates. The signing key is copied byte for byte, so earlier receipts stay verifiable. The old incarnation is the recovery point and stays retained. Rejected: a logical dump into a running destination (impossible under the dependency order), renaming only stateless members while reusing the PVC (no data migration at all), and relaxing data-policy equality in general (only a credential renamed in the same proposal may differ).

2026-10-02 (consolidation): Rewrite this plan as a current-state document with history moved to the snapshot. No scope, dependency or acceptance change.

2026-10-02 (F34): Knative blocks orphaning a Service's children but not a DomainMapping's. Ordinary Orphan collection of a preview DomainMapping left a KIngress that, hours later, made Envoy reject every gateway update on the whole cluster. Gateway health is therefore a cluster-wide effect of collection correctness, and C2 must include a native DomainMapping collection through the controller-descendant authority.

2026-10-02: Final acceptance binds one frozen candidate. Earlier native runs on cp3 are credited as checkpoints. The C2 run uses a fresh local context carrying the final candidate's payload, because an admitted context cannot change platform version (ADR 6) and the release gate checks that the evidence payload and operator revision match the candidate.

2026-10-02 (critical intranet): Local evidence contributes to EP-159/160's data-protection proof (source-unavailable recovery, known-content restore, recorded recovery time) without inventing an unagreed recovery-time target; D1, D2 and D4 remain operator decisions.

2026-09-29: Cloud integration (EP-156) has scheduling priority over the full local scenario; both remain required for release. Run focused local regressions whenever a cloud assertion needs them.

2026-09-28: Follow the operator-approved MP-23 scope reduction: live database/PVC overwrite, new interactive maintenance (EP-161 cancelled) and scheduled keep-N pruning are deferred and must refuse new admission, while recovery of already-admitted operations stays available. Local proof covers isolated restore only.

2026-09-27: Grow one scenario from the smallest production path (platform, application with database, unchanged replay) and add each assertion to it, rather than building separate fixtures. Use verified local MinIO image overrides rather than a new object-store provider.

2026-09-26: This plan takes over the local integration obligations of EP-150 and the native migration/collection bindings of EP-148 under EP-149's lifecycle contract; both parents are superseded history, not pending gates.

## Outcomes & Retrospective

**Status: Complete (2026-10-09).** Every required item is met on the final candidate `83124396` or explicitly moved.

Final outcome (2026-10-09): v0.4.0 carries a passing local end-to-end proof on its own payload. C1 verified 214 operations with no provider mutation, and C2 on a fresh k3d context finalized all 16 assertions, including interruption at every stage, isolated restores for PostgreSQL, Redis, ClickHouse and a volume, source-unavailable recovery, history restore, the PostgreSQL rename and companion collection. The assembler accepted it and C5 bound it into the release index ([C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396), [C5](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c5-83124396)). C2 also passed on each earlier candidate (`3ae20f8c`, `3b78d905`, `3b59bcb7`), so the local run was never the reason a candidate was replaced. Moved: releasing durable data, deleting broker topics and collecting migrated-away incarnations are deferred to MP-21 or a later data-lifecycle plan (MP-23 Decision Log, 2026-10-03). Lessons: archived driver scripts plus a fresh operator root per candidate let an independent session repeat C2 unchanged on every new candidate; and macOS temporary-file cleanup purged the pinned image export under `/private/tmp` between candidates (`3b78d905`), so driver inputs that must outlive a few days belong outside `/tmp`.

Earlier state (2026-10-03). Delivered so far: the local platform bootstrap gate on cp3, a first platform/two-application/replay production path, independent local isolated restores for Redis, ClickHouse and a volume through MinIO, and independent local release-history and preview cleanup. Several local provider bindings (k3d observation shapes, registry transport, MinIO images, Namespace resolution, release-history replay stability) were repaired along the way. B5 (2026-10-03) added the checked-in scenario fixture, native stateless companion collection and the native reviewed PostgreSQL rename, each with focused tests and a bounded cp3 run. Remaining: the final-candidate runs C1 and C2; collection of durable members, broker topics and migrated-away incarnations is outside the current contract (MasterPlan scope proposal). Lesson: local k3d reproduces Kubernetes-level defects in minutes that cost hours in the cloud, so every candidate passes the cp3 gate first; but evidence spread across many candidates and old payloads still has to be rebound to one candidate.

