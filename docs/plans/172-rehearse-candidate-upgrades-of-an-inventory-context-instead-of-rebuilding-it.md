---
id: 172
slug: rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it
title: "Move an inventory context to the next release through a reviewed transition"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Move an inventory context to the next release through a reviewed transition

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

The file path keeps its original slug. The plan was re-scoped on 2026-10-09 from "rehearse
candidate upgrades" to owning the transition itself; see the Decision Log.


## Purpose / Big Picture

Nagare v0.4.0 is the first release meant for production use. Today an installation on v0.4.0 has no
supported way to move to the next release:
- The context pins its platform version (`NAGARE_PLATFORM_VERSION` in the context file) and a payload
  workspace selected by digest.
- [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) refuses
  a version change after the context is admitted to the inventory.
- The legacy `nagarectl platform upgrade` refuses any context with inventory history
  (`guardLegacyMutationInventory`, `cli/nagarectl/app/Nagare/Cli/Platform/Upgrade.hs:366`).

After this plan, an operator moves an admitted context from release S to release T with one saved,
reviewed inventory transaction:
- The transaction binds both releases exactly, and refuses an unsupported pair before any write.
- Every stop has a reviewed exit.
- The context's version pin changes last.

Each release then ships with evidence that it can move a converged v0.4.0-lineage context: a
disposable local context is converged on the previous release, moved to the candidate, and
re-verified.

To see it working, run the transition rehearsal from the published v0.4.0 package to the current
candidate. The scenario's seeded rows read back unchanged. Scope revisions advance only where T's
declarations differ. An unchanged replan afterwards has zero operations, and `nagarectl platform
status` reports T on the CLI, payload, context, host and cluster.


## Progress

- [ ] M1 (pure; MasterPlan 26 lane A): characterise the transition.
  - The two-release fixture builds each scope from S's payload and from T's.
  - A recorded v0.4.0 store reads back under T's codecs.
  - Acceptance: a checked-in table of every state the transition must move (pin, workspace,
    platform scope declarations, host closure, cluster stamp `nagare-platform-version`, store head
    and journal wire), each with the operation that moves it or the reason it refuses. A test asserts
    the table matches what the fixture observes.
- [ ] M2 (code and model; lane A): implement the reviewed transition and its compatibility table.
  - Run it in the [EP-173](173-find-recovery-defects-with-adversarial-provider-interpreters.md)
    recovery model under every single fault at every boundary.
  - Acceptance:
    - invariants I1–I6 hold;
    - mutation records show that removing the unsupported-pair refusal, or reordering the pin commit
      before a scope update, fails a named model test;
    - every suite passes.
- [ ] M3 (native run L2 on cp3; lane B): script the rehearsal on top of
  [EP-168](168-script-the-local-acceptance-run-as-one-command.md).
  - Converge a fresh local context on the published v0.4.0 package, transition it to the candidate,
    then run EP-168's data checks, scope preservation and runner verify.
  - Acceptance: one green run from v0.4.0 to the next candidate, with seeded content intact and a
    zero-operation replan.


## Surprises & Discoveries

- 2026-10-09: No plan owned this capability. ADR 6 (2026-09-26 amendment) deferred it "until a
  separately reviewed transition has been implemented". MasterPlan 21 excludes general in-place
  release and schema migration. This plan's original M1 would only have recorded the legacy runner's
  refusal.


## Decision Log

- Decision: Prove upgrade mechanics only on disposable rehearsal contexts; leave work-data upgrade policy to MasterPlan 24 and MasterPlan 21.
  Rationale: The mechanics can be proven now and remove the rebuild-per-candidate cost; policy for installations holding work data depends on MasterPlan 24's evaluation.
  Date: 2026-10-04 (superseded in part 2026-10-09: this plan now also implements the transition)
- Decision (operator, 2026-10-09): This plan owns the reviewed release transition of an admitted inventory context.
  - It goes through inventory operations, not the legacy `platform upgrade` runner, which stays blocked for inventory contexts.
  - Its acceptance is a native rehearsal from v0.4.0 to the next candidate, repeated every release.
  - MasterPlan 21 keeps only replacement onto fresh infrastructure, and consumes this plan's compatibility table.

  Rationale: Production use of v0.4.0 needs a path to the next release. The node-upgrade drills of checklist section 3 already prove the reviewed host operation and self-reverting activation this transition reuses.
  Date: 2026-10-09
- Decision: Supported pairs are explicit. T's payload carries a compatibility table naming the source releases and the store wire versions it accepts. Anything else refuses at planning.
  - No journal migration is built speculatively.
  - If a release changes the store wire format, that release adds a reviewed migration step to this transition and a model scenario for it, or it does not ship the change.

  Rationale: This keeps the transition finite. It is consistent with the operator's no-speculative-compatibility rule, while still guaranteeing that a v0.4.0 store is never stranded silently.
  Date: 2026-10-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Terms.**
- A *release* is a published Nagare version: an immutable Nix package containing the `nagarectl` CLI
  and the platform payload under `share/nagare`
  ([ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
  [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md)).
- A *context* is one Nagare installation's target settings, in
  `${XDG_CONFIG_HOME}/nagare/contexts/<name>.env`.
- Its *version pin* is `NAGARE_PLATFORM_VERSION` there (`cli/nagarectl/src/Nagare/Target.hs`). The
  CLI runs from a per-context *payload workspace* selected by payload digest
  (`cli/nagarectl/src/Nagare/Platform/Workspace.hs`).
- *Admitted* means the context's inventory store has substantive history
  (`InventoryStore.hasSubstantiveHistory`).
- Scopes, reviews, `inventory apply`, `resume` and `recover` are the typed inventory's transaction
  vocabulary ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)).

**What already exists and is reused.**
- **Node upgrades.** Checklist section 3 moved NixOS and k3s on an inventory context with a reviewed
  `inventory apply` that drives the self-reverting activation
  ([ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md); evidence in
  `docs/audits/mp23-independent-results-2026-10-07/section3-83124396/`). The host-closure part of a
  transition is that same reviewed host operation.
- **Bootstrap stamp.** After any platform scope is re-accepted, the next bootstrap plan proposes one
  stamp update to ConfigMap `nagare-platform-version` in `nagare-system`
  (`Nagare.Inventory.Bootstrap`).
- **Legacy model.** The legacy upgrade transaction's phase model (`Nagare.Platform.Upgrade`, a source
  library) and [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
  list the guards a transition must keep.
- **Recovery model.** The EP-173 model (`cli/nagarectl/test/Nagare/Test/World/`, the recovery model
  specs) runs the real planner, driver and adapters under faults.

**What MasterPlan 23 learned that bears on this.**
- A candidate CLI pointed at an older payload workspace can refuse at planning. After F41 the CLI
  pins the digest of the local MinIO manifest, so the `14071e58` CLI refused the `44ff0fd7` payload.
  The workspace must therefore move together with the CLI, inside the reviewed transaction.
- Stores written before ADR 27 refuse data operations until rebound (EP-176). A transition must not
  re-open that gap: incarnation records carry over unchanged.
- Local MinIO keeps backups on a local-path volume (F41), so backup objects survive restarts during a
  transition.


## Plan of Work

**M1: characterise.**
- Build a test fixture that compiles the same scope set from two payload trees: the v0.4.0 payload,
  read from the published package or a checked-in digest-bound extract, and the working tree's
  payload.
- Load a recorded v0.4.0 store head and journal through the current codecs. Record it from the
  EP-168 run on `83124396`, or from any fresh v0.4.0 context.
- Define the transition table as a Haskell value (`Nagare.Platform.Transition.transitionTable`).
  For each kind of state it gives the source of truth, the operation that moves it, its ordering, and
  its recovery. A test checks the table against the fixture. Paste its rendering into this plan's
  Context section rather than a new document.

**M2: implement.** Add `nagarectl platform transition --to <package> --save-plan DIR` (name final in
M2) and `inventory apply DIR --yes` for it. The saved review contains, in order:
1. Prepare T's payload workspace by digest. This is local and reversible until admission.
2. Reviewed updates for every platform scope whose declarations differ under T, and zero operations
   for the rest.
3. The reviewed host operation, if T's host closure differs.
4. The bootstrap stamp update.
5. The context pin commit, as the last write (ADR 6).

Rules:
- **Compatibility.** The compatibility table ships in T's payload. Planning refuses an unsupported
  S→T pair or store wire version before any write.
- **Which CLI resumes.** After admission only T's CLI resumes or recovers the transaction. S's CLI
  refuses a store with an open transition and names T.
- **Model.** Add a transition scenario to the recovery model before running anything natively. It
  covers a single fault at every boundary, interruption between each step, and a transient read.

**M3: rehearse natively.** Add a `transition` mode to EP-168's runner:
1. Bootstrap and converge on S (v0.4.0), and seed the stores.
2. Run the transition to T, reviewing the saved plan.
3. Run the data checks, independent scope preservation, and the runner verify with an unchanged
   candidate.

Its evidence is what [EP-170](170-size-the-release-gate-to-the-change.md)'s gate accepts as
"transition rehearsal". The evidence is also handed to MasterPlan 24's upgrade-path stream and to
MasterPlan 21.


## Concrete Steps

Lane A work, from the repository root:

```bash
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /transition/'
just haskell-style-check && just gate-fast
```

Lane B (M3), after EP-168 M1 lands:

```bash
cabal run nagare-harness -- local-acceptance --transition-from /path/to/nagare-0.4.0 \
  --candidate /path/to/result-<rev>-nagare --images /path/to/oci-layout \
  --operator-root /private/tmp/nagare-transition-<rev>.XXXXXX
```

Expected ending:

```text
transition: converged <transaction> (0.4.0 -> <candidate version>)
data checks: postgresql, redis, clickhouse, volume rows intact
verify: zero-operation replan
```


## Validation and Acceptance

The milestone acceptances above. The decisive one is M3: a green native rehearsal from v0.4.0 to
the next candidate. A refusal at any step stops the rehearsal and is reported, never worked around.
A defect found in M3 gets a model regression that fails on the pre-fix source before M3 is repeated.


## Idempotence and Recovery

Planning is read-only. The transition is one saved review. If it stops, the supported paths are
`inventory resume` and the recorded recovery decisions, run with T's CLI. Before the pin commit the
context is still S in its pin, and T's CLI owns completion. The rehearsal uses a disposable local
context that EP-168 can rebuild.


## Interfaces and Dependencies

- **Produces:** the transition command, the compatibility table in the payload, and transition
  rehearsal evidence. MasterPlan 21 consumes the compatibility table for replacement pairs. ADR 6
  carries the 2026-10-09 ownership amendment.
- **Hard dependency:** M3 needs EP-168 M1.
- **Soft dependencies:** EP-173 (model and worlds) and EP-170 (gate acceptance of the evidence).
