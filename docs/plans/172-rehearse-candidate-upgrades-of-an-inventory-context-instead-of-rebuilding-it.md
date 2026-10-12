---
id: 172
slug: rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it
title: "Move an inventory context to the next release through a reviewed transition"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
intention: intention_01m4q3c0mde4jvy5tgva4h9cvk
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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T02:46:57Z
      mode: "update"
      note: "Reference EP-183 (v0.4.0 intranet gaps)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-12T04:00:08Z
      mode: "implement"
      note: "M1 transition table and two-release fixture; M2 open acceptance"
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

- [x] (2026-10-11) M1 (pure; MasterPlan 26 lane A): characterise the transition.
  - The two-release fixture builds each scope from S's payload and from T's.
  - A recorded v0.4.0 store reads back under T's codecs.
  - Acceptance: a checked-in table of every state the transition must move (pin, workspace,
    platform scope declarations, host closure, cluster stamp `nagare-platform-version`, store head
    and journal wire), each with the operation that moves it or the reason it refuses. A test asserts
    the table matches what the fixture observes.
  - Done: `Nagare.Platform.Transition.transitionTable` (rendered under Context and Orientation),
    the fixture `cli/nagarectl/test/fixtures/transition-0.4.0/` written by
    `scripts/record-transition-fixture.sh`, and `PlatformTransitionTableSpec`. The spec has five
    cases, all green, under `-p '/transition table/'`:
    - the extract's 120 files match `payload.sha256`;
    - both v0.4.0 heads and the journal sample decode and re-encode byte for byte under T's codecs,
      and pass `checkTransition`;
    - each row's `observed` equals the fixture's, and per scope, T compiling both payloads agrees
      with the S-accepted and T-accepted revisions the rehearsal recorded;
    - the pin moves last and the stamp after every scope;
    - the rendering has one line per row.

    Flipping `foundation` to `Unchanged` fails the third case.
- [x] (2026-10-11) M2 (code and model; lane A): implement the reviewed transition and its compatibility table.
  - [x] (2026-10-10) The compatibility table: `transitionsFrom` in the payload manifest (0.5.0 lists
    0.4.0) and the pure check `Nagare.Platform.Transition.checkTransition`, which refuses an unpinned
    context, the target itself, an unlisted source, and a head wire version the payload does not
    read. Tests in `PlatformTransitionSpec`.
  - [x] (2026-10-11) The transition marker: an optional `transition` field (from, to, startedAt) in
    the store head, written by admission for the first review whose payload identity is
    `nagare-transition:<S>-><T payloadId>` and kept by the later ones. While it is open, admission
    refuses every other review, and `inventory apply|resume|recover|close` refuse under a CLI
    whose payload is not T, naming T. The head wire version stays 1; a v0.4.0 CLI refuses the
    head as unknown while the marker is present, which is the intended S-side refusal. Tests in
    `PlatformTransitionSpec`.
  - [x] (2026-10-11) The commands: `platform transition plan --out DIR` checks the compatibility
    table and the marker's owner, then plans the ordinary bootstrap stages (shared with bootstrap
    in `Nagare.Cli.Bootstrap.Sequence`) as if the context were pinned to T, under the transition
    identity; each stage is applied with `inventory apply DIR --yes`, whose execution registry
    accepts a transition review against the source pin. The host stage in transition mode
    re-targets the generated flake's `nagare` input to T's NixOS source, re-locks it and refuses
    a lock that leaves the payload (`hostLockRepin`); images are not rebuilt for an accepted host.
    `platform transition commit --yes` writes the pin last, after the store is idle and payload,
    host and cluster report T, then clears the marker.
  - [x] (2026-10-11) Run it in the [EP-173](173-find-recovery-defects-with-adversarial-provider-interpreters.md)
    recovery model under every single fault at every boundary: the scenario "create, then a release
    transition stage, then commit" reviews the application under the transition identity, takes
    every exit the faults force, and its commit step (I10) refuses unless the head is idle with the
    marker still open and the stage converged, then clears it idempotently. The host stage and the
    pin write are CLI-side and stay with the native rehearsal.
  - Acceptance:
    - invariants I1–I6 hold;
    - mutation records show that removing the unsupported-pair refusal, or reordering the pin commit
      before a scope update, fails a named model test;
    - every suite passes.
  - [x] (2026-10-11) Acceptance met.
    - Both guards now run in code the model executes. `platform transition commit`'s head checks moved
      into `Nagare.Platform.Transition.transitionCommitRefusal`: own marker, idle head, every moved
      scope converged at its accepted revision. The CLI passes the platform scopes; the model passes
      every scope.
    - The model now plans a transition as `platform transition plan` does (`checkTransition` against
      the head) and holds the verdict to its own reading of the table. A `TransitionDeploy` must be
      accepted from 0.4.0. The new scenario "create, then plan a transition from a release the payload
      does not list (EP-172)" must refuse from 0.3.0.
    - The commit step goes through the library guard, then checks its own oracle: the pin never lands
      before the stage converged.
    - The fast tier, which checks I1–I5 and I8–I10 on every scenario and placement, is green
      (`-p '/fast tier/'`, 53 s).
    - Two mutation records, proved in a scratch worktree:
      - `EP172-unlisted-source-accepted` fails the fast tier with "I10: planning accepted a transition
        from 0.3.0, which the payload does not list".
      - `EP172-pin-before-stage-converged` fails it on the transition scenario with "I10: the pin was
        committed before the transition stage converged", under 17 single faults.
    - Every suite passes: see the fast gate record in Outcomes & Retrospective.
- [x] (2026-10-11) M3 (native run on a disposable Docker daemon, never cp3; lane B):
  `just transition-rehearsal` (`scripts/transition-rehearsal.sh`) bootstraps a fresh local context on
  the source release's nix-built nagarectl, seeds a PostgreSQL row, runs `platform transition plan`
  and `inventory apply` with the candidate until a review has no operation and re-declares no
  scope but the plan-time stamp, commits, and reads the row back. EP-168 is held, so the driver is
  its own; it resumes ambiguous stops, scrubs the ambient context and payload variables, seeds the
  auth and MinIO images from another daemon's store, and forwards the registry on a free loopback
  port because host port 5000 is AirPlay.
  - Observed 2026-10-11, v0.4.0 (831243962c6b) to 37d8d45d on Colima profile `nagare-mp23`: the
    0.4.0 bootstrap converged in three stages (2, 1 and 218 operations, two resumes); the transition
    took three reviews: the local substrate re-declared with no operation, the platform stage with
    one operation (the stamp update) and six scopes re-declared (foundation and the five
    observability scopes, whose declarations embed the payload path), then no operation;
    `platform transition commit` pinned the context to 0.5.0 and cleared the marker; `platform
    status` reported 0.5.0 at 37d8d45d on CLI, payload, context and cluster; the head ended idle
    at generation 2213; the sentinel row read back unchanged; a replan had no operation.
- [x] (2026-10-11) Releases bind the rehearsal record: the driver writes
  `evidence/transition-rehearsal.json` (source and candidate version and revision, transition
  reviews, seeded row and read-back, final `platform status`, idle inventory, converged replan);
  `scripts/assemble-release.sh --transition-rehearsal FILE` and `nagarectl release publish`
  (`Nagare.Inventory.ReleaseEvidence`) require it, bound to the candidate's version and revision
  and to a source in the payload's `transitionsFrom`, in place of the MasterPlan 23 local and cloud
  evidence tree. Tests: `PlatformTransitionSpec` (release evidence), `scripts/test-release.sh`,
  `scripts/test-release-evidence-public.py`.


## Surprises & Discoveries

- 2026-10-09: No plan owned this capability. ADR 6 (2026-09-26 amendment) deferred it "until a
  separately reviewed transition has been implemented". MasterPlan 21 excludes general in-place
  release and schema migration. This plan's original M1 would only have recorded the legacy runner's
  refusal.


- 2026-10-11 (M1): T's code refuses to compile S's local object store: "pinned MinIO manifest
  digest changed" (F41). Compiling S's payload with T's code is therefore not something a
  transition ever does; T's CLI always plans from T's workspace. The fixture asserts the refusal,
  and the table's workspace row names it as the reason the workspace moves with the CLI.
- 2026-10-11 (M1): with no marker open, v0.4.0's `inventory export` and `inventory restore`
  rewrite the post-transition head byte for byte. A fresh v0.4.0 head has no `incarnations` key
  and still decodes canonically under T. The head wire is unchanged in both directions until the
  marker opens.
- 2026-10-11 (M1): two methods agree on every platform scope they both see. One is T's code
  compiling both payloads; the other is the revisions each release accepted in the M3 rehearsal.
  Eight scopes differ only in their payload path (local-substrate, foundation and the five
  observability scopes), and the stamp changes. `kubeconfig` and the other platform scopes are
  unchanged, and so is the host's NixOS source.


- 2026-10-11 (M2): no invariant I6 exists. EP-173 defined I1, I2 and I4. The model has since added
  I3, I5 and I7–I10, and the transition scenarios are checked against all of them. M2's "I1–I6" is
  read as the invariants the fast tier checks.


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


- Decision (2026-10-10, after reading the code paths): the transition reuses the staged bootstrap
  planner rather than a new planner, and is committed by an explicit pin step.
  - Today `resolvePlatformWorkspace` always prepares the running CLI's own payload per context, and
    `buildPlatformCandidate` refuses when the context pin differs from that payload. The transition
    is therefore T's CLI planning the ordinary bootstrap stages against a context pinned to S, under
    the identity `nagare-transition:<S>-><T payloadId>`, with that one pin check replaced by the
    compatibility check. The planner already proposes updates only for scopes whose declarations
    differ, and proposes the stamp update.
  - The host stage gets a release-transition mode: the host flake's `nagare` input moves to T's
    payload store path and the lock is re-pinned, which `hostLockRepin` refuses today by design.
    It is the same reviewed self-reverting activation the section 3 drills proved.
  - Because the stages are planned one review at a time, a transition is an ordered sequence of
    saved reviews, not one. The store head carries a transition marker (from, to, started) written
    at the first review's admission. A CLI whose payload is not the marker's target refuses every
    platform mutation and names T; T's CLI requires the marker. This is the "which CLI resumes"
    rule, and the marker is the only wire change, with a compatibility row.
  - `platform transition --commit` writes the pin last. It refuses unless the head has no open
    transaction, the marker's target is T, and `platform status` reports T on payload, host and
    cluster. It then clears the marker.
  - The compatibility table is a field of the payload manifest (`release.json`): accepted source
    releases and the store schema versions. v0.4.0 to v0.5.0 needs no store migration (EP-183:
    head and journal formats unchanged).
  - The recovery model covers the platform scope updates, the stamp and the marker under every
    fault. The host step is covered by the section 3 native drills, since the host world
    (EP-173 M4) is held.
  Rationale: the staged planner, the diff against the accepted snapshot, the stamp update and the
  reviewed host activation already exist and are proven; the transition adds a compatibility check,
  a marker, a host mode and a pin step, and nothing speculative.
  Date: 2026-10-10

- Decision (2026-10-11, M1): the recorded v0.4.0 store is bytes the v0.4.0 nagarectl wrote,
  taken without a new native run:
  - a fresh head from planning a scratch context;
  - the M3 head as v0.4.0's own export and restore rewrite it;
  - journal events from before the first transition review;
  - both releases' revisions of every scope the transition re-declared.

  Rationale: a fresh v0.4.0 bootstrap needs a Docker daemon whose k3d cluster name collides with
  the kept M3 rehearsal. The M3 store already holds v0.4.0's journal and scope bytes; the fixture
  test checks each recorded file's digest, so nothing in it was edited by hand.
  Date: 2026-10-11

- Decision (2026-10-11, M2): `platform transition commit` also refuses while any platform scope is
  accepted at a revision that has not converged. The check is one library function
  (`transitionCommitRefusal`) shared by the CLI and the recovery model.
  Rationale: the pin is the transition's last write. Before this, the CLI checked only that the
  cluster stamp reported T, and the model's own check guarded nothing in production. Sharing the
  function lets a mutation of the guard fail a model test. Application scopes are not required to
  converge, so an unhealthy application does not block a platform pin.
  Date: 2026-10-11

## Outcomes & Retrospective

(2026-10-11) Every milestone is complete. An admitted v0.4.0 context moves to the next release
through staged reviews under a head marker, and the pin is committed last:
- M2 implemented it, and the recovery model checks it under every single fault.
- M3 rehearsed it natively, and releases bind that rehearsal's record.
- M1 checked in the table of every state the transition moves, held to a two-release fixture.

The M1 fixture found what M3 had shown natively: eight scopes differ only in the payload path, and
the stamp is the one change. It also showed that the target's code refuses the source's payload, so
the transition plans only from the target's workspace.

Lessons:
- **Production code must own each guard.** A guard the model re-implements in test code proves
  nothing about production. M2's commit check lived only in the model until it moved into the
  library.
- **Record native bytes when the run happens.** A fixture recorded from a native run's kept root
  avoids a second native run. Here only the head had to be re-derived, through v0.4.0's own export
  and restore.

Follow-up outside this plan: `docs/user/upgrades.md` still says an inventory-backed context has no
in-place version transition (its install section and the `minor-upgrade-required` row).

ADR 6 carries the 2026-10-11 amendment describing the transition as built.


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

**The transition table (M1).** `Nagare.Platform.Transition.transitionTable`, rendered by
`renderTransitionTable`. The last column is what `PlatformTransitionTableSpec` observes from v0.4.0
to the working tree. The test fails when that differs, so a release that changes a state updates
its row:

| Step | State | Source of truth | Moved by | Refuses | Recovery | v0.4.0 to this payload |
|---|---|---|---|---|---|---|
| 1 | PayloadWorkspace | ${XDG_STATE_HOME}/nagare/<context>/platform/<payloadId>-<digest>, selected by payload digest | platform transition plan prepares the target payload's workspace beside the source's; local and outside the store | a workspace whose manifest disagrees with the payload refuses before planning; this release refuses the source payload's MinIO manifest (F41), so the workspace moves with the CLI | prepared again from the immutable payload; the source workspace is kept | Changed |
| 2 | StoreHead | head.json in the inventory store: wire version and transition marker | admission of the first transition review opens the marker (source, target payload, start); later transition reviews keep it; the commit clears it after the pin | planning refuses a head wire version outside the payload's minimumInventorySchemaVersion to inventorySchemaVersion; while the marker is open, admission refuses any other review and apply, resume, recover and close refuse under a CLI whose payload is not the target | the marker survives every stop; resume, recover and close with the target's nagarectl | Unchanged |
| - | JournalWire | journal/<sequence>.json in the inventory store | nothing: the target reads the source's events and appends at the same wire version | a release that changes the journal wire ships a reviewed migration step with a model scenario, or does not ship the change | none needed | Unchanged |
| 3 | platform scope local-substrate | accepted scope platform:local-substrate | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 4 | CloudScopes | accepted cloud-foundation, cloud, host-image-build, host-image, cache and cache-image scopes | the cloud stages are planned again from the target payload; an accepted host is re-pinned, never re-imaged | planning refuses a cloud context whose cloud foundation is not accepted | inventory resume, recover and close of the stage's transaction | NotInLocalContext |
| 5 | HostClosure | the host flake's nagare input, the payload's NixOS source (scope host) | the host stage re-targets the input to the target payload's NixOS source, re-locks it, and applies the reviewed self-reverting activation (ADR 11) | hostLockRepin refuses a lock that leaves the payload; a local context has no host | the activation reverts itself unless confirmed; resume or recover the host operation | Unchanged |
| 6 | platform scope kubeconfig | accepted scope platform:kubeconfig | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope auth | accepted scope platform:auth | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope cert-manager | accepted scope platform:cert-manager | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope certificate-issuer | accepted scope platform:certificate-issuer | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope foundation | accepted scope platform:foundation | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope kourier | accepted scope platform:kourier | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope local-object-store | accepted scope platform:local-object-store | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope net-certmanager | accepted scope platform:net-certmanager | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope net-controller-image | accepted scope platform:net-controller-image | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope observability-extra | accepted scope platform:observability-extra | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope observability-otel-collector | accepted scope platform:observability-otel-collector | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope observability-secrets | accepted scope platform:observability-secrets | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 7 | platform scope observability-victoria-logs | accepted scope platform:observability-victoria-logs | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope observability-victoria-logs-collector | accepted scope platform:observability-victoria-logs-collector | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope observability-victoria-traces | accepted scope platform:observability-victoria-traces | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope observability-vmks | accepted scope platform:observability-vmks | re-accepted at a new revision with no operation; only its members' payload path differs | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | SourcePathsOnly |
| 7 | platform scope serving | accepted scope platform:serving | nothing: the planner keeps the accepted revision | admission refuses a review whose base revisions are not the head's accepted ones | inventory resume, recover and close of the stage's transaction | Unchanged |
| 8 | ClusterStamp | ConfigMap nagare-platform-version in nagare-system, accepted as scope bootstrap-stamp | one reviewed update in the platform stage, ordered after every other member of that review | platform transition commit refuses while the cluster marker does not report the target | inventory resume, recover and close; plan the stage again | Changed |
| 9 | ContextPin | NAGARE_PLATFORM_VERSION in ${XDG_CONFIG_HOME}/nagare/contexts/<context>.env | platform transition commit writes it last, then clears the marker | planning refuses an unpinned context, a pin equal to the target, and a pin the payload's transitionsFrom does not list; the commit refuses unless the head is idle, the marker names this payload, and payload, host and cluster report the target | until the commit, the context is still pinned to the source and the target's nagarectl owns completion | Changed |

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
- **Consumer of the table (2026-10-09):** [EP-183](183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md)
  (MasterPlan 24) changes receipt and journal formats:
  - scheduled volume receipts;
  - the `restoredFrom` lineage record;
  - retention bound into schedule metadata.

  Each change ships only with a compatibility row from v0.4.0, or with a reviewed migration step
  that has its own model scenario.
- **Soft dependencies:** EP-173 (model and worlds) and EP-170 (gate acceptance of the evidence).
