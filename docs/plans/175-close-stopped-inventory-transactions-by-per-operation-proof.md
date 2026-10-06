---
id: 175
slug: close-stopped-inventory-transactions-by-per-operation-proof
title: "Close stopped inventory transactions by per-operation proof"
kind: exec-plan
created_at: 2026-10-05T21:51:36Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T21:51:36Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T22:44:53Z
      mode: "implement"
      note: "M1: Settlement, adapterSettle, verify never executes, I8 totality"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T00:40:39Z
      mode: "implement"
      note: "EP-175 M3: allowlists deleted, fenced rollback closes, rule-level mutation records"
---

# Close stopped inventory transactions by per-operation proof

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare changes managed resources through reviewed *transactions*. A transaction can stop partway: a
Kubernetes object lands but never becomes Ready, a write's acknowledgement is lost, someone deletes or
replaces an object outside Nagare, or the process dies. While a transaction is stopped, every later
plan on that context is refused. That includes plans for unrelated applications, backups and
teardown. Today the only ways out are about 23 special-case "stop" and "abandon" rules. Each rule
guesses from the review's shape and from named resource kinds that nothing harmful happened. Each
finding from F16 to F65 widened one of those rules, and the exhaustive review found 281 reachable
stopped states that still have no exit
(`docs/audits/mp23-exhaustive-review-2026-10-05/A-recovery-matrix.md`).

After this plan, every stopped transaction in MP-23's release line has one supported exit:
`nagarectl inventory close TRANSACTION`. It ends the transaction when each operation's outcome is
proved from the journal or from a fresh provider observation. It writes nothing to any provider. It
keeps ownership of everything the transaction created or changed, and it reverts a scope only when
nothing in it took effect. The proof replaces the guessing. A reader sees it working in two places:
- the recovery model's fast tier, whose only exits become "resume" and "close", with no stopped state
  left without an exit;
- a focused test of each former special case (F16, F30, F35–F37, F54–F59, F63–F65), which now ends
  through `close`.

For a provider that cannot be observed at all, the operator gets a last resort that is recorded and
attested: `close --attest`. It accepts nothing and replaces hand edits of the store.

This plan implements [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md),
which is steps 1 and 4 of MasterPlan 23's release line (b).


## Progress

- [x] (2026-10-05) M1: proof classes and settlement.
  - **Settlement.** `Settlement` and `adapterSettle` exist, in `Nagare.Inventory.Adapter`, with
    `settleOperationWith` and `fencedSettle`. The Kubernetes adapter settles totally through
    `settleMutation`. Migration, live-restore and maintenance wrappers delegate to it, and settle
    their own excluded operations as `Unknown`.
  - **O6.** The driver never executes a `VerifyResource`.
  - **Proof.** Model invariant I8 passes the fast tier: every stopped operation settles to a proof
    class. `test/InventorySettleSpec.hs` proves O6.
  - **Mutations.** `ADR26-O1-kubernetes-settle-unknown` fails I8, and `ADR26-O6-verify-executes`
    fails the O6 test.
- [x] (2026-10-05) M2: `inventory close`.
  - **Close.** `Nagare.Inventory.Execute.Close.closeTransaction`:
    - classifies each operation from the journal or its settlement;
    - refuses while resume can progress (including the case where a refused retry would only
      repeat), and while any operation is `Unknown`;
    - publishes a `closes/<digest>.json` record (`Nagare.Inventory.Plan.CloseRecord`) and journals
      `closed:<digest>`;
    - writes one re-entrant head: revert to base with the review's retained additions removed, or
      keep.
  - **Resume.** It completes a journalled close and returns the new `Closed` result.
  - **Never-started set.** Planning reads it from close records, for any scope kind.
  - **Command.** `nagarectl inventory close TRANSACTION --review DIGEST [--take-over]` exists, and
    the five legacy recovery actions route to it.
  - **Model.** Its exits are resume and close. An admission refusal is a violation, except a named
    N1 tolerance (F51 reopened, removed by EP-176 M3) and expected refusals for data deleted outside
    review. A refused admission is re-run once when a fault fired.
  - **Proof.**
    - The fast tier passes (64 s) and the rename model passes.
    - `test/InventoryCloseSpec.hs` covers three cases: keep and re-entry after a refused release;
      revert with the retained additions removed; refusal while an operation is unknown.
  - **F61's mark.** It is bound to the transaction and operation, with the mounted-destination
    check, and ADR 26 §4 is updated to match.
  - The old stop path in `loadUnstartedApplicationCreates` stays until M3.
- [x] M3 (2026-10-05): the allowlists are gone.
  - **Deleted:**
    - `incompleteApplicationOnlyReview` and `LandedUpdateProof`;
    - the legacy stop-proof reader in `loadUnstartedApplicationCreates`;
    - the four `*OnlyReview` predicates and `applicationStopMarker`;
    - the stop, abandon-refused and abandon-partial branches of `Execute/Recovery.hs`;
    - `releaseStoppedApplicationClaim` and `releaseAbortedClaim`.

    The library shrank by about 550 lines.
  - **Routing.** The five legacy actions reach close before the writer lock. The fenced backup
    rollback (three sites in `Execute/FencedRecovery.hs` and the resume rollback path) ends through
    `closeRolledBack`. That function writes the same close record and head, with classes taken
    from the journal alone.
  - **A closed transaction is final.** `inventory recover` refuses every other decision for it. A
    close record's never-started set is void once any later event names its transaction.
  - **Hazard regressions.** Each failed on the pre-routing code and passes now:
    - H1: "abandoning a refused correction after a stop reverts to the correction's base";
    - H2: "closing a refused update keeps a created member owned and admits no update as never-started (H2)";
    - U1: "an abandon whose head release was refused is completed by repeating it".

    H3/U3 is "a review in which nothing took effect reverts every changed scope and its retained
    additions". Its mutation record reintroduces the hazard.
  - **Rewritten tests.** The five focused specs and four `InventoryTransactionSpec` cases now
    assert close. A Platform scope, a durable workload and a terminal Job now close, since close
    has no per-kind rule. An unresolved or safe-to-retry operation still refuses.
  - **Mutation records.** Twelve instance records are retired; the README keeps their rows and
    names the rule-level record that replaces each one. There are four new rule-level records:
    revert to converged, never-started admits updates, never-started skips absence, and close
    rebinds incarnations. With the existing unknown-blocks and retained-additions records, these
    cover the six rules. `F59-standalone-unstarted-creates` was regenerated after a comment change.
  - **Docs.** The runbook gains "Close a stopped transaction". ADR 22 is amended, and the tracker
    has an exit-change note plus implementation updates on F35, F36, F37 and F51.
- [ ] M4: attested close and U2. `close --attest` closes a transaction whose operations an adapter
  cannot prove, accepting nothing. A CDN purge and a VM power operation that cannot be resolved end
  through it.


## Surprises & Discoveries

- A close record's never-started set ignored a later intent recorded against the same operation.
  The legacy stop reader re-read journal states and so caught it. The rewritten "corrected stopped
  application creates only its never-started durable member" test exposed the gap. Fixed in M3: a
  close record holds only while no later event names its transaction.
- After a journalled close, a re-activated head let an ordinary `accept-adapter-proof` decision
  reach the adapter's recover probe. The old stop had a dedicated guard against that. M3 replaces
  it with one rule: a closed transaction accepts only close.


## Decision Log

- Decision: Expose the exit as a new command, `nagarectl inventory close TRANSACTION --review
  DIGEST [--attest FILE] [--take-over]`. The five old action names in version-1 decision files
  (`stop-incomplete-application`, `abandon-refused-operation`, `abandon-partial-prune`,
  `abandon-partial-volume-restore`, `abandon-partial-database-restore`) keep parsing; `inventory
  recover` routes them to the same close, ignoring the named operation once it is checked to belong
  to the transaction.
  Rationale: ADR 26 says close names a transaction, not an operation. Keeping the aliases means
  runbooks and saved decision files from before this change still work.
  Date: 2026-10-05

- Decision (reviewer condition, nagare-84, 2026-10-05): the copy marker counts as ADR 26 §4's proof
  only when the redo clears the destination under all three of these conditions:
  - the marker was written by this reviewed migration before its copy started, and records that
    transaction's ID and operation ID;
  - the destination is the migration's own destination object: by recorded identity once
    `docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md`
    lands, and by its reviewed claim name and UID until then;
  - nothing else mounts it.

  Implementing these is part of M2. In the same change, update ADR 26 §4's wording, which says
  "reviewed wipe", to describe the marker-bound redo.
  Date: 2026-10-05

- Decision: F61's forward exit is the copy marker that commit `abe5f17a` already shipped. A copy
  that finds `.nagare-transfer-incomplete` clears and redoes the destination. ADR 26 §4 needs no
  further reviewed wipe for it. Migrations stay excluded from close.
  Rationale: the marker is a forward exit of the migration's own transfer stage. The model's
  `PartialCopy` fault and `test/InventoryTransferScriptSpec.hs` already prove it. A separate
  operator-reviewed wipe would add a command for a case that now resolves on resume. If the
  exhaustive matrix later shows a partial copy that the marker cannot cover (for example a
  persistent full disk), add a reviewed wipe then, in this plan.
  Date: 2026-10-05

- Decision: The settle-totality check is invariant I8 of the recovery model, not a separate
  `InventorySettleTotalitySpec.hs`. At every stop the model settles each operation that has intent
  and no completion, reading the world in inspection mode so no fault fires. A `SettledUnknown`
  fails the run unless it resolves by `inventory resume`.
  Rationale: the model already reaches every stop under every fault, and a separate harness would
  re-implement its replay.
  Date: 2026-10-05

- Decision: `adapterSettle` is a `Maybe` field on `Adapter`. `Nothing` derives settlement from
  `adapterRecover` (`settleOperationWith`). Wrappers around the Kubernetes adapter delegate to the
  base adapter's settlement, and settle their own excluded operations (migration stages, fenced
  data operations) as `SettledUnknown`.
  Rationale: 37 adapters are constructed with record syntax. A defaulted field keeps every
  out-of-line adapter blocked (`Unknown`) without per-adapter code, as the release line requires.
  Date: 2026-10-05

- Decision: The harness change "an admission refusal is never counted as a successful exit" is made
  in M2 here, not left to `docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md`.
  Rationale: M2's acceptance is the fast tier exiting only by resume or close. While the model still
  maps a refused retirement to `Done`, that acceptance would be vacuous for retirement scenarios. Plan
  177 still owns every other harness fix.
  Date: 2026-10-05


- Decision: Stores whose journals hold a pre-close `stopped-incomplete-application` marker get no
  reader for it. Their never-started creates fail closed as `durable-resource-missing`.
  Rationale: the marker was used only on retired native test candidates (`mp23-c3i`), and MP-23
  step 5 runs on a new candidate. Keeping the reader would keep `incompleteApplicationOnlyReview`,
  the allowlist this milestone deletes.
  Date: 2026-10-05

- Decision: The fenced backup rollback ends through `closeRolledBack` in `Execute/Close.hs`, not
  through a `releaseClosedClaim`. It classes every operation from the journal alone, and refuses
  if any operation needs an adapter.
  Rationale: a fenced rollback's review has no other mutating work, and the fenced adapters settle
  their operations as unknown. The general close would therefore refuse what the old release
  allowed. Sharing `commitClose` keeps one record format and one head write, and fixes the same
  revert-to-converged hazard (H1) on this path.
  Date: 2026-10-05

- Decision: `RecoveryLandedUnready` and `RecoveryTargetReplaced` stay as `RecoveryDecision`
  constructors for now. Folding them into `Settlement` moves to
  `docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md`.
  Rationale: they no longer authorize anything outside close. The driver stops on them, and the
  Kubernetes settle maps them to landed and target-gone. Removing them needs the Kubernetes settle
  to re-derive landedness from the live object. EP-176's checked identity accessor rewrites that
  same code.
  Date: 2026-10-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root. The Haskell package is `cli/nagarectl`: library code
in `cli/nagarectl/src`, executables in `cli/nagarectl/app`, tests in `cli/nagarectl/test` (suite
`nagarectl-test`, registered in `cli/nagarectl/nagarectl.cabal` and assembled in
`cli/nagarectl/test/Nagare/Test/Suite.hs`). The production Haskell standard applies
([ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)): the package Prelude
`Nagare.Dsl.Prelude`, strict record fields, explicit deriving strategies. Since EP-174, incomplete
pattern matches are compile errors in every package.

**Terms.**
- A **scope** is one owner's declared set of resources (for example one application, or one
  standalone database).
- A **review** is a saved, immutable plan for a change of one or more scopes. It carries:
  - the scopes' **base** revisions (what was accepted when it was planned);
  - their **desired** revisions;
  - a list of **planned operations**, each with an action: `CreateResource`, `UpdateResource`,
    `VerifyResource`, `RetireResource`, `AdoptResource`, `MigrateResource`, `RunDeclaredOperation`,
    and so on. They are defined in `cli/nagarectl/src/Nagare/Inventory/Adapter.hs`.
- **Admission** (`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`) starts a
  **transaction** for a review. It writes the store's **head**, the single mutable record in
  `cli/nagarectl/src/Nagare/Inventory/Store.hs`, with these fields:
  - `headActiveTransaction`;
  - `headExecutorClaim`;
  - `headAccepted := desired`;
  - retention and migration entries added to `headRetained`;
  - `headConverged`, unchanged until convergence;
  - `headIncarnations`, `headDataFence` and `headMigration`.
- The **driver** (`cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs`) runs operations serially,
  in operation-ID (digest) order (`cli/nagarectl/src/Nagare/Inventory/OperationStep.hs`). It records
  each step in an append-only **journal**. The journal's states per operation are in
  `cli/nagarectl/src/Nagare/Inventory/Journal.hs`:
  - `Pending`, `IntentRecorded`;
  - `Completed digest`;
  - `Failed (KnownNoEffect | PartialOrUnknown)`;
  - `Ambiguous`, `OperatorResolved marker`.

  The driver journals `IntentRecorded` before any provider effect, so an operation with no intent
  event provably did nothing. This invariant is what makes "never started" a proof.
- An **adapter** (the `Adapter` record in `Adapter.hs`) is how the driver reaches a provider. Its
  functions are `adapterObserve`, `adapterPrepare`, `adapterPreflight`, `adapterExecute`,
  `adapterVerify` and `adapterRecover`. After an interruption, `adapterRecover` answers a
  `RecoveryDecision`:
  - `RecoveryProvedComplete`, `RecoverySafeToRetry`;
  - `RecoveryAwaitingReadiness`, `RecoveryLandedUnready`;
  - `RecoveryTargetReplaced`, `RecoveryTerminalFailure`;
  - `RecoveryUnresolved`.
- **Operator recovery** (`cli/nagarectl/src/Nagare/Inventory/Execute/Recovery.hs`, with predicates in
  `Execute/RecoveryPolicy.hs` and `Plan/History.hs`) is the `nagarectl inventory recover TRANSACTION
  --operation OP --decision FILE` command. It applies one `RecoveryAction`
  (`Execute/Types.hs`). The special-case exits this plan replaces are:
  - `stop-incomplete-application`, decided by `incompleteApplicationOnlyReview` in `Plan/History.hs`;
  - `abandon-refused-operation`;
  - `abandon-partial-prune`, `abandon-partial-volume-restore` and `abandon-partial-database-restore`,
    decided by the `*OnlyReview` predicates in `RecoveryPolicy.hs`;
  - their head releases, `releaseStoppedApplicationClaim` and `releaseAbortedClaim` in
    `Execute/Claims.hs`.
- The **never-started set**: when an application create stalls, its later creates never ran.
  `loadUnstartedApplicationCreates` in `Plan/History.hs` reconstructs them from the stop event, so a
  later plan can recreate them or retire them as absent (F55, F58, F59). Planning
  (`Plan/Changes.hs`) and admission's `holdsNoData` (`Execute/Admission.hs`) read it.
- The **recovery model** (`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`, worlds under
  `cli/nagarectl/test/Nagare/Test/World/`, the rename model in
  `cli/nagarectl/test/InventoryRenameRecoveryModelSpec.hs`) runs real planning, the driver,
  recovery and the Kubernetes adapter over an in-memory API server with injected faults.
  - Its exit search tries `Resume` and each `RecoveryAction` (`recoveryActions` there).
  - Invariant I1 says every stopped transaction has a supported exit.
  - Mutation records under `cli/nagarectl/test/mutations/` revert one guard each and must make a
    named test fail (see that directory's `README.md`).

**The design to implement** is specified in
`docs/audits/mp23-exhaustive-review-2026-10-05/B-exit-rules.md`, §3 (proof classes, the CLOSE rule,
per-adapter obligations O1–O8, the safety argument) and §4 (each finding checked against the rule).
Read it in full before starting. Its central points are restated here so this plan stands alone:
- **Classification, first match wins.**
  - `Completed`: the journal holds `Completed`.
  - `NeverStarted`: no intent-carrying event for the operation.
  - `Refused`: the latest state is `Failed KnownNoEffect`.
  - `Reverted`: a `fenced-recovery-proved` marker.
  - `NoEffect`: a `VerifyResource` operation, or `adapterSettle` proves the before-state unchanged.
  - `Landed`: the exact reviewed effect on the exact reviewed object, not ready.
  - `TargetGone`: the conditional write can no longer land, because the target was deleted or
    replaced. Its identity is evidence only and is never bound.
  - `TerminalPartial`: a run-to-completion object such as a Job failed terminally.
  - `Unknown`: blocks, with a stated way to resolve it.
- **Close is admissible only when all of these hold:**
  - the transaction is active;
  - there is no data fence and no migration;
  - resume cannot progress;
  - no operation is `Unknown`.
- **Close's effects, all without provider writes.** It publishes a close record and journals
  `OperatorResolved "closed:<record digest>"`. It then writes one head:
  - it clears the transaction and claim;
  - it leaves converged revisions, incarnations and unchanged scopes as they were;
  - for each changed scope it either **reverts** to the review's base (only if every operation on the
    scope is `NeverStarted`, `Refused`, `NoEffect` or `Reverted`, and it then also removes the
    retained and migration entries this review's admission added), or **keeps** the desired
    revision.
- **The never-started set N(T).** It holds the creates that are `NeverStarted` or `Refused` and that
  the adapter observes `ConfirmedAbsent` at close. It is valid while the scope's accepted revision
  is still that review's desired revision.

**Hazards this plan must reproduce first** (B §2.1; E's U1 and U3 in
`docs/audits/mp23-exhaustive-review-2026-10-05/E-crash-points.md`). These are inferred, so reproduce
each in the model before fixing it:
- **H1.** Abort resets every scope's accepted revision to `headConverged`, not to the review's base.
- **H2.** An abandon orphans objects that completed.
- **H3.** An abort keeps the retained entries that admission added, so the member is both accepted
  and retained.
- **U1.** An abandon is journalled before its head release. If that release fails, every command
  refuses afterwards.
- **U3** is H3 seen from the crash catalogue.

**What exists from the checkpoint** (`f0291362`, `abe5f17a`) and will be replaced:
- per-kind additions to `incompleteApplicationOnlyReview` (F59, F63, F65);
- `RecoverySafeToRetry` for a deleted update target (F64);
- standalone scopes in `loadUnstartedApplicationCreates` (F59 gap A);
- StatefulSet readiness by replica counts in `confirmLandedUnready`
  (`cli/nagarectl/src/Nagare/Inventory/KubernetesConfiguration.hs`). This part is reused by
  `adapterSettle`'s `Landed` proof.

The held worker-Deployment work in `docs/audits/mp23-held-work/` is superseded by this plan; do not
apply it.

**Relevant ADRs:**
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) is the decision.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines
  scopes, reviews, the journal and the special-case exits being retired. Its amendments for F16,
  F30, F54–F59 and F63–F65 describe the rules this plan deletes. Amend it when they go.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) and its
  2026-10-05 amendment: every fix lands with a model regression that fails without it, and no
  refusal counts as an exit.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
  is the identity work in `docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md`.
  Close must bind no incarnation, which keeps the two plans independent.


## Plan of Work

### Milestone 1: proof classes and adapter settlement

Add `Settlement` to `cli/nagarectl/src/Nagare/Inventory/Adapter.hs`:
`SettledNoEffect evidence | SettledLanded physical evidence | SettledTargetGone (Maybe physical) |
SettledTerminalPartial physical | SettledUnknown reason resolvesBy`. Add an `adapterSettle ::
PlannedOperation -> PreparedNative -> IO Settlement` field to `Adapter`, with a default
`settleFromRecover` that maps `RecoveryProvedComplete` to "nothing to settle" (the driver already
records it as completed) and everything else to `SettledUnknown`. That default lets adapters opt in
one at a time and keeps out-of-line executors blocked, as the release line requires.

Implement `adapterSettle` totally for the Kubernetes adapter
(`cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`) across the in-line kinds:
- Knative Service and DomainMapping;
- Deployment and StatefulSet;
- ConfigMap and Secret;
- PersistentVolumeClaim;
- Service, NetworkPolicy and RBAC objects;
- CronJob and Job.

The rules follow B §3.3:
- **NoEffect**: only when every address the operation could write is still in its reviewed
  before-state, by UID and resourceVersion.
- **Landed**: F54's proof stated once for every kind. Readiness is the Ready condition for Knative
  kinds and replica counts for Deployments and StatefulSets, reusing `confirmLandedUnready`. A create
  is `Landed` when the stamped object carries the reviewed digest after an absent before-state.
- **TargetGone**: the conditional write's precondition cannot match, because the target is absent
  or present under another UID with the member's stamp.
- **TerminalPartial**: a failed Job or scratch pod of this review.

Implement it also for the controller collection adapter (`Collection/Adapter.hs`), and for the
backup, restore and prune Jobs that run through the Kubernetes adapter. The migration adapter
(`Adapters/KubernetesMigration.hs`) returns `SettledUnknown`, because migrations are excluded from
close.

In `Execute/Driver.hs`, never call `adapterExecute` for a `VerifyResource` operation (obligation O6);
verification is `adapterVerify` only.

Add a per-adapter totality test, `cli/nagarectl/test/InventorySettleTotalitySpec.hs`. For every
fault in the Kubernetes world (`Nagare.Test.World.Adversary`), at every write of the existing model
scenarios, it calls `adapterSettle` on each operation not proved complete. It asserts the answer is
not `SettledUnknown`, unless the reason names an unobservable provider or an in-flight effect. At
the end of M1 nothing calls `adapterSettle` in production yet; the test is the proof.

### Milestone 2: the close command

Add `closeTransaction` to `cli/nagarectl/src/Nagare/Inventory/Execute/Recovery.hs`, exported through
`cli/nagarectl/src/Nagare/Inventory/Execute.hs`. Under the process lock and the resume claim it:
1. checks authority: the transaction is active, `headDataFence` and `headMigration` are empty, no
   migration stage has intent, and the adapter identity and version match the review;
2. checks that resume is stuck: no pending operation with complete dependencies passes a fresh
   preflight, and no recoverable operation's `adapterRecover` answers proved-complete or safe-retry;
3. classifies every operation (journal classes first, then `adapterSettle`) and refuses if any is
   `Unknown`, naming each one with its `resolvesBy`;
4. computes, per changed scope, revert or keep, and the never-started set N(T) by observing each
   candidate create `ConfirmedAbsent`;
5. publishes the close record as an immutable store object (canonical JSON: transaction, review
   digest, per-operation class and evidence, per-scope disposition, N(T)) and appends
   `OperatorResolved "closed:<digest>"`;
6. writes the head once, with the same reread-and-retry discipline as `commitHead` in
   `Execute/Journal.hs`.

Make it re-enterable. If the journal already holds the `closed:` event, a repeated close, and also
`resumeTransaction`, skip to step 6 using the published record. The release is a new
`releaseClosedClaim` in `Execute/Claims.hs`. It reverts to the review's base, not to
`headConverged`, and removes exactly the retained keys this review added for a reverted scope. It
keeps everything else.

Replace `loadUnstartedApplicationCreates` with a reader of the latest close record whose desired
revision matches the scope's accepted revision. Planning and admission's `holdsNoData` then read
N(T) from it, for every scope kind.

Add the command. In `cli/nagarectl/app/Nagare/Cli/Parser/Inventory.hs`:

```text
inventory close TRANSACTION --review DIGEST [--attest FILE] [--take-over]
```

The handler lives next to `InventoryRecover`'s in the `app/` command modules. Its output names each
operation's class, each scope's disposition and N(T), and it exits non-zero with the blocking
operations listed when close is refused. Route the five legacy action names in
`OperatorRecoveryInput`'s parser (`Execute/Types.hs`) to close. The fenced terminal steps in
`Execute/FencedRecovery.hs` call `releaseClosedClaim` instead of `releaseAbortedClaim`.

Change the recovery models to the new exits: `recoveryActions` becomes `[Resume, Close]` in
`InventoryRecoveryModelSpec.hs` and the rename model. Also make the model stop counting a planning or
admission refusal with no active transaction as a completed step: today `classify` maps it to
`Done`. A refusal becomes a violation unless the scenario declares it the expected outcome (for
example `durable-resource-missing` for data deleted outside review). Run the fast tier. Every
violation it now reports is either a close obligation an adapter does not meet (fix the adapter's
settle) or a real defect to record in the tracker.

### Milestone 3: delete the allowlists

With close in place, delete:
- `incompleteApplicationOnlyReview` and `LandedUpdateProof` in `Plan/History.hs`;
- the `*OnlyReview` predicates in `Execute/RecoveryPolicy.hs`;
- the stop, abandon-refused and abandon-partial branches in `Execute/Recovery.hs`;
- `releaseStoppedApplicationClaim` and `releaseAbortedClaim`;
- the stop-only `RecoveryDecision` constructors (`RecoveryLandedUnready`, `RecoveryTargetReplaced`),
  folded into `Settlement`.

Before deleting, add model scenarios that reproduce H1, H2 and H3 on the pre-close code: a stop
followed by an abandoned correction; a replan of the same scope after an abandon; and a
member-removing deploy refused by a foreign field manager. Add a store-fault placement that refuses
the abandon's head release (U1). They must fail on the commit before M2 and pass after.

Rewrite the focused tests that assert the old exits so they assert close:
- `cli/nagarectl/test/InventoryLandedUpdateStopSpec.hs`;
- `InventoryRefusedPreflightRecoverySpec.hs`;
- `InventoryRedisRestoreRecoverySpec.hs`;
- `InventoryPreviewRecoverySpec.hs`;
- `InventoryApplicationUpdateRecoverySpec.hs`.

Remove the mutation records whose guard no longer exists (F16, F35, F37, F54–F59 and F63–F65
instance diffs, after checking each guard is gone). Add six rule-level records:
1. `Unknown` does not block close;
2. revert to converged instead of base;
3. revert without removing the review's retained additions;
4. N(T) admits updates, not only creates;
5. N(T) skips the absence observation at close;
6. close binds an incarnation.

Each must fail a named test.

Rewrite the recovery section of `docs/runbooks/inventory-operations.md` around `inventory close`.
Amend ADR 22 to say its special-case exits are superseded by ADR 26. Record the behaviour change in
the tracker: F35, F36 and partial prune now keep their scope accepted but unconverged instead of
orphaning leftovers. The operator approved this as part of ADR 26 on 2026-10-05.

### Milestone 4: attested close, accepting nothing

Add `--attest FILE` to `inventory close`. The file names:
- the operator;
- the reason;
- evidence references (free text plus optional digests).

An attested close is admissible when the ordinary close is refused only because some operations are
`Unknown` and observation cannot reduce them. It records the attestation in the close record. Its
head release clears the transaction and claim and changes nothing else:
- accepted revisions stay at the review's desired revisions;
- converged revisions, incarnations and retained entries are unchanged.

So the next plan re-observes everything and binds nothing. Route E's U2 to it, by giving the CDN
purge (`CdnPurge.hs`) and VM power (`VmPower.hs`) recovery an `adapterSettle` that answers `Unknown`
with a reason. Add one test per path showing that the attested close ends a transaction that is
otherwise stuck.


## Concrete Steps

Work from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`, and run cabal from the
package directory. A test run from the root writes `.ghc.environment.*` into the wrong directory and
causes spurious failures.

```bash
cd cli/nagarectl
cabal build nagarectl-test
cabal test nagarectl-test --test-options='-p "/fast tier/ || /rename recovery model/ || /settle totality/"'
```

Before each commit, from the repository root, run `just gate-fast` and `git diff --numstat`. Before
each push batch, also run `nix flake check` (ADR 25 §5):

```bash
just gate-fast
git diff --numstat
nix flake check   # per push batch
```

Expected: `gate: fast gate green`, and `nix flake check` exits 0. Record mutation proofs in a scratch
worktree (`git worktree add --detach "$SCRATCH/mut" HEAD`); never apply them in the shared checkout.
Check `git -C "$SCRATCH/mut" diff` shows the mutant applied before trusting a failure.


## Validation and Acceptance

Required acceptance:
- **Fast tier.** It passes with exit moves limited to resume and close, over every existing scenario
  and fault, including `Deleted` and `PartialCopy`. Any stopped state that close cannot end is listed
  with its blocking operation, and is either fixed or recorded as a documented limit with operator
  approval.
- **Settle totality.** The totality test passes for every in-line kind.
- **H1–H3 and U1.** Their regressions fail on the commit before M2 and pass after.
- **Rule-level mutations.** Each of the six records fails its test.
- **Focused tests.** Each former special case (F16, F30, F35–F37, F54–F59, F63–F65) has a focused
  test that ends the stopped transaction with `closeTransaction` and checks the head: the active
  transaction is cleared, converged revisions and incarnations are unchanged, and the scope is
  reverted or kept as B §4's table says.
- **Re-entry.** A repeated close after a refused head write reaches an idle head.
- **Attested close.** It ends a transaction with an `Unknown` CDN purge, and the next plan
  re-observes the purge.
- **Gates.** `just gate-fast` is green and `nix flake check` exits 0 at each commit.

Native runs are not part of this plan. They come in MasterPlan 23's step 5, on a new candidate.


## Idempotence and Recovery

Every milestone is additive until M3's deletions. M1 and M2 run the new path beside the old exits,
so tests keep passing, and M3 removes the old exits once their tests are rewritten. Close is
idempotent by construction: the journal event names the published record, and a replay only redoes
the head write. If a commit breaks the model, revert that commit; no store format is migrated:
- close records are new immutable objects;
- the journal gains a new `OperatorResolved` marker;
- journals written before this plan still decode.


## Interfaces and Dependencies

New and changed interfaces other plans rely on:
- `Nagare.Inventory.Adapter.Settlement` and `adapterSettle`.
  `docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md`
  classifies a live object that differs from the recorded identity as `SettledTargetGone`.
- `Nagare.Inventory.Execute.closeTransaction` and the close record. Plan 177's generated model
  product uses close as the universal exit move.
- The never-started-set reader. It replaces `loadUnstartedApplicationCreates` for planning and
  admission.

This is step 1 of MasterPlan 23's release line (b) and has no hard dependency within it. Plans 176
and 177 follow it. The design references are
`docs/audits/mp23-exhaustive-review-2026-10-05/B-exit-rules.md`, `A-recovery-matrix.md` and
`E-crash-points.md`.
