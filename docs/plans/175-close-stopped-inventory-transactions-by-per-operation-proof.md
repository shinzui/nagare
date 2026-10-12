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

Full plan before trimming: [175-close-stopped-inventory-transactions-by-per-operation-proof.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M4 (2026-10-05): attested close and U2.
  - **Command.** `inventory close --attest FILE` reads a strict version-1 attestation: operator,
    reason, and evidence notes with optional digests. The record keeps it under `attestation`,
    omitted when absent so unattested record bytes are unchanged.
  - **Rule.** An attested close is admissible only when unknown operations are the sole blocker.
    It keeps every changed scope at its desired revision, removes no retained entry and records no
    never-started create. With every operation proved it refuses (`attestation-unneeded`).
  - **U2.** The CDN purge and VM power wrappers settle their own one-shot operations as unknown,
    naming the attested close. Every other operation settles as the wrapped adapter's.
    Previously the wrappers' `Nothing` bypassed the base adapter's own settlement.
  - **Tests.**
    - "close refuses while an operation is unproved, …; an attested close then accepts nothing":
      head unchanged except the release, and a repeat is idempotent;
    - "an attestation file is strict";
    - the H2 test refuses an unneeded attestation;
    - the CDN purge and VM power specs assert the attested resolution.
  - **Mutation records.** `ADR26-attest-overrides-proof` and `ADR26-U2-cdn-purge-settles-by-recovery`
    and `ADR26-U2-vm-power-settles-by-recovery`, each failing a named test.
  - The runbook documents the attested close.

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

- Decision: An attested close keeps every changed scope at its desired revision rather than reverting
  any of them, even a scope whose operations all classed as no effect.
  Rationale: ADR 26 §5 says the attested exit accepts nothing and binds nothing. Keeping the admitted
  revision leaves every member owned and unconverged, so the next plan observes the truth. A revert
  would drop ownership on the strength of an attestation about a different operation.
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

Completed 2026-10-05; release line (b) steps 1 and 4 are implemented.

- **One exit.** Every stopped transaction now has one exit. Close by proof keeps or reverts each
  changed scope. Attested close accepts nothing. Five decision names survive only as aliases of
  close.
- **Deletions.** The per-kind allowlists, two head writers that reset to the converged revision,
  and twelve instance mutation records are gone. Eleven rule-level records cover the rules that
  replaced them.
- **Hazards.** H1, H2, H3/U3 and U1 each have a regression, and E's U2 has an exit.
- **What worked.**
  - Writing the close as one pure record plus one head write made re-entry trivial. It also let
    the fenced rollback share the same commit (`commitClose`), which fixed H1 on that path too.
  - The surviving mutants were the most useful signal. Three of the four new rule-level records
    survived the existing suite, and each exposed an assertion the close tests lacked: absence
    observation, incarnations, never-started updates.
- **What to watch.**
  - Close's correctness rests on each adapter's settlement. An adapter that settles a real effect
    as no-effect would revert a scope with live objects. EP-177's kind table must check settlement
    per kind, not per scenario.
  - `RecoveryLandedUnready` and `RecoveryTargetReplaced` move to EP-176.
  - The attested U2 path is proven at two levels: adapter settlement, and close with an
    unprovable operation. It is not proven through a reviewed CDN or VM transaction end to end.
    The step 5 native run should exercise one.

