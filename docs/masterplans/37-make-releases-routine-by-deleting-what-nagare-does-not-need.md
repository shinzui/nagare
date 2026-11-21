---
id: 37
slug: make-releases-routine-by-deleting-what-nagare-does-not-need
title: "Make releases routine by deleting what Nagare does not need"
kind: master-plan
created_at: 2026-11-20T14:59:44Z
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-20T14:59:44Z
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T05:51:56Z
      verdict: "changes-requested"
      note: "Define payload identity, mixed-review recovery and retry, disposable rehearsal isolation, and the publication contract before removing their current checks. Scope feature and plan deletions explicitly."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T05:59:18Z
      verdict: "approved"
      note: "Post-revision review of the staged plan and EP-274. Release identity, proof consumers, rehearsal isolation and cleanup ownership are explicit. D2b cutover remains conditional."
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T05:58:44Z
      mode: "update"
      note: "Applied review findings across release identity, publication, rehearsal isolation, cleanup scope and EP-274 recovery boundaries."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-21T06:43:27Z
      mode: "implement"
      note: "D1 host and cluster identity slices, D5 CLAUDE.md rules; registry D1 and D5 In Progress"
---

# Make releases routine by deleting what Nagare does not need

The operator asked for this plan on 2026-11-20, after v0.24.1, a 30-line CLI fix, took seven
candidate runs and most of a day. Its deliverables are deletions. A deliverable that adds a
mechanism states what it adds and what it deletes, and the second number is larger.


## Vision & Scope

### Finish line

The plan is done when the following four observations are recorded. Use a real CLI-only release for the
first, a platform-changing release for the second, and either release for the clean-checkout run. Exercise
the two-engineer case on one shared test context.

1. **A CLI-only fix ships without moving the platform.** Its intranet plan has zero operations: no
   host activation, no image publication, no cluster change.
2. **A platform release that stops at the intranet step restarts at that step.** Nothing before it
   runs again.
3. **A release is cut from a clean checkout on a second machine**, with nothing copied from the
   first except credentials.
4. **One engineer's stopped stateless apply does not block another engineer's unrelated apply.**

The operator's aim (2026-11-20) is an architecture several engineers can operate safely. What
protects them from each other is at the review level and is not touched here: admission checks the
review's head and base, active transaction, data fence and deployer delegation
(`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`), and every review records its actor. What hurts them is that one
unresolved transaction blocks every other apply, so each stop state is a team-wide stop.

Measure the Haskell reduction against v0.24.1. Its Git archive contains 177,313 source lines and 104,437
test lines. Count physical lines in regular `cli/**/*.hs` files from each revision's archive, counting
`cli/<package>/test/` as tests and all other paths as source. Record shortfalls against the estimates in
Progress.

### What stays exactly as strict

- Everything that guards data: the reviewed, journalled, fenced path for databases, migrations,
  backups, restores and volumes, and the upgrade rehearsal that reads a seeded row back.
- The GCP guardrail in `scripts/lib/target.sh` and its fail-closed cloud branch.
- Guarded, self-reverting host activation (`just host-switch`, ADR 11).
- Ownership: Nagare still refuses to write a Kubernetes object or Helm release that is not stamped
  as this context's.

### What is wrong, measured

- **Nothing is ever removed.** From v0.4.0 (2026-10-09) to v0.24.0 (2026-11-19), 146,760 lines
  were added under `cli/` and 10,789 deleted. ExecPlans went from 182 to 270, ADRs from 27 to 40.
  Of 969 commits, 231 are fixes.
- **The engine treats a ConfigMap like a database.** The planner computes a recovery class per
  operation (`Plan/Changes.hs:954`), and no executor reads it. A stateless Deployment and a
  PostgreSQL volume take the same journal, the same per-object proof and the same stop states.
- **A slow rollout becomes an ambiguous stop.** When a Deployment update lands and is not Ready in
  180 s, resume re-reads Nagare's own stamp, sees it differs from the reviewed "before" value and
  reports "stamp changed since review" (`Adapters/Kubernetes.hs:404`, `KubernetesProof.hs:376`).
  Only a Knative Service update is exempt. This was v0.24.1's stage-4 stop.
- **Recovering from a stop makes a new state.** `inventory close` keeps the scope's desired
  revision and leaves it unconverged (`Execute/Close.hs:449`). The next plan then emits a
  journalled `VerifyResource` for every unchanged member of that scope (`Plan/Changes.hs:902`),
  each of which fails if its object is not Ready at that moment, and the scope converges only when
  one review operates on every member (`Execute/Claims.hs:203`). The planner already observes
  every member, so the converged revision is a second record of what observation says. This was
  v0.24.1's "artifact runtime only executes…" stop, and `4fe9b48b` answered it with more code.
- **Every release moves the host and the admin API, whatever changed.** The host flake carries the
  source revision (`Host/Config.hs:344`), so a new revision is a host activation. The admin API
  image links the whole `nagarectl` library and depends on `cluster/`, `nixos/` and `release.json`
  (`nix/haskell-packages.nix:36`), so its digest changed in all 20 of the last 20 releases.
  v0.24.1 planned a host update and 14 platform operations for a planner fix.
- **A candidate run cannot resume.** Each run starts a new directory and repeats every step.
  `release-publish` needs a `latest` link and a landed evidence commit that only a complete run
  writes. Pin-file refusals interrupted two of v0.24.1's seven runs. The current intranet step already accepts a dirty lock naming the candidate. It can still commit unrelated edits to a tracked pin file.
- **Release state lives on one workstation:** gate and sweep records under `~/.local/state`, a
  Colima profile whose socket path is hard-coded (`Rehearse.hs` selects the profile, `TransitionDrill.hs` refuses the shared daemon), two container images
  that must already be in its store, and an on-demand x86 builder.

### Why the earlier attempts made it worse

Each kept the engine's contract fixed and built around it.

- **MasterPlan 13** (June) fixed "abstractions": it deleted four shell scripts and added a typed
  Job module, doctor checks, a flake check and a live smoke.
- **MasterPlan 19** answered forty-five review findings with guards, bounds and alerts.
- **MasterPlan 23** built the typed inventory, journal and per-object proof for every resource
  class at once. It closed with 95 findings and the lesson "find defects with interpreters".
- **MasterPlan 26**, "make releases routine", put "weakening any MasterPlan 23 guarantee" out of
  scope. It added a harness, provider interpreters, a gate classifier and a rehearsal. The operator
  cut most of it on 2026-10-10 and closed it on 2026-10-14.
- **MasterPlan 29** made the review cheaper to read: one store open, a blob cache, concurrent
  reads. The review stayed.
- **MasterPlan 30** says "keep the existing reviewed-inventory model" and added five boundaries: a
  compiler, a command session, an observation epoch, a coordinator and a rollout runner.
- **The operator's decisions of 2026-10-10, 2026-10-29 and 2026-11-17** cut ceremony from plans
  and gates. They could not shrink the code, so the same code kept producing the same stops.

This plan narrows the journalled path for eligible stateless Kubernetes work. Mixed reviews, data-bearing
operations and legacy recovery keep the evidence their callers require.


## Decomposition Strategy

D1 changes how a release proves what is installed. D3 changes how it is rehearsed and published. Deliver
them through the existing release commands. D2 is the only child ExecPlan because a mistake at its
boundary can affect data recovery. D4 removes unused features individually. D5 removes obsolete gates,
evidence and documents after their consumers have moved.


## Exec-Plan Registry

| Deliverable | Plan or owner | Hard prerequisite | Status |
|---|---|---|---|
| D1. CLI-only release | MasterPlan, release identity and packaging | None | In Progress |
| D3. Resumable release steps | MasterPlan, release tooling | D1 identity for combined release acceptance | Not Started |
| D2. Stateless Kubernetes recovery | [EP-274](../plans/274-simplify-recovery-for-stateless-kubernetes-applies.md) | D2b requires two releases on D2a and the findings decision | Not Started |
| D4. Unused features | MasterPlan, per-feature removal | Usage and recovery check below | Not Started |
| D5. Gates and documents | MasterPlan, landing and documentation | D3 switch for gate removal, D2 findings review for ledger removal | In Progress |


## Dependency Graph

Start with D1 and D3. Their implementation can overlap. Accept their release behavior together through the
candidate, intranet and publish commands. D2a can be developed independently of those changes. Run its
first two release observations before beginning D2b. D4 can inventory features immediately. Defer deletion
of a shared adapter until D2 has shown which strict or legacy callers still use it. D5 can classify files
immediately. Remove each gate, fixture or evidence source only with the cutover of its last caller.


## Integration Points

- **Installed identity belongs to D1.** The CLI and payload report the release version and revision.
  Compare the host by the desired host configuration and locked inputs, the cluster by deployed content
  including image digests. Compare like components. When the source is admitted and the reviewed
  comparison finds no platform work, finalization must be able to advance the context pin with zero
  provider writes, including when there was no first mutating stage to open a transition marker. Preserve
  the recoverable pin-last protocol. D3 consumes this comparison in rehearsal, intranet and publication.
  Missing evidence still requires observation or the existing adoption path.
  [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
- **The run directory and its public record belong to D3.** The candidate writes its version, revision and
  previous version before a restartable step needs them. Each step reads that run and validates its
  prerequisite results for the same candidate. Publication requires passing landing, rehearsal and
  intranet results. The candidate descriptor alone proves only identity. The tag publisher owns the
  reduced public asset set. D5 removes obsolete gate calls after the candidate consumes the per-landing
  result. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) and
  [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
- **Recovery and scope convergence belong to D2.** D1 and D3 use the transition command's judgment. D2
  owns any change to how the command reaches it. Strict or mixed reviews, older open transactions, data
  fences and lifecycle facts still have consumers. D4 inventories these before removing an adapter.
  [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
  [ADR 39](../adr/0039-lifecycle-sources-are-committed-by-the-converged-release.md)


## Progress

D1 and D5 are in progress; D3, D2 and D4 have not started. Record the accepting commit and line deltas
for each deliverable.

D1 so far: the host's reviewed identity ignores the release comments and payload store path
(`f4cfb2c4`); a plan that moves no platform scope keeps the earlier release's cluster marker, and the
transition commit pins such a release after its own plan finds no work. Outstanding: the admin image
split, which waits on how an unchanged admin API reports its version, and the real CLI-only release. D5 so far: the
`CLAUDE.md` rules and the plan-owner hook are removed (`0f5ae649`).

**D1. A CLI-only release has nothing to apply.** In `cli/nagarectl/src/Nagare/Host/Config.hs` and the
bootstrap host stage, account for the generated version comments, the release-dependent input path and the
lock as well as the source revision. Use the content that changes the evaluated host or installed cluster
to decide whether either moves. Keep the CLI build provenance, compatibility checks, pin-last protocol,
protected-route migrations when required, and guarded host switch. Use an already-current context to
demonstrate a CLI-only patch with a bumped version. Check the opposite case by changing a real host input
or deployed image and observing its reviewed operation. Exercise old version-only stamps and a genuinely
wrong host through `platform status`, transition commit, and the harness's `exactOn` check.

Separate the admin image's actual library and executable inputs from the whole CLI package in Cabal
**and** Nix. The image ships both `nagare-api-server` and `nagare-events`. Keep `sourceForTests` available
to the tests that read the payload or API documents. Remove the release-specific `nagareRebuild` override.
Compare two image manifests after an unrelated CLI edit and version bump, then after a change to a shipped
binary. An unchanged image must keep its digest and layout path.

- [ ] A real CLI-only release reports zero intranet operations, including host activation, image
  publication into the context registry and cluster writes. The candidate and published tag pass identity
  verification.

**D3. Each release step can run alone.** Make the explicit run directory work through `just`, the
candidate harness, intranet, rehearsal and `scripts/release-publish.sh`. In
`cli/nagarectl/app/Nagare/Cli/Commands/Release.hs` and
`cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs`, switch producer and publisher together to the
signed tag, its notes and the candidate-bound rehearsal record. Validate the previous release, candidate
revision, completed transition, seeded row read-back and intranet outcome before publishing. Preserve
immutable-tag and same-draft retry behavior. Drop the native output and clone-free assets, double
assembly, Apple-container attachment step and attachment-only x86 work. Verify that the retained x86
release-image build or cache substitution works from the second machine. Remove assembly, attachment
checks, the evidence commit, `latest` and historical release-evidence files after their readers move.
Target a net reduction of 1,200 script lines. Update the release skill and runbook with the actual entry
points.

Use a clean, dedicated operator worktree for pin edits, or verify that every pending pin diff is the exact
change produced by this run before continuing. A matching lock revision alone cannot establish this.
Exercise a retry after pinning and an unrelated edit in the same file. It must survive outside the pin
commit. Keep that regression in the harness when retiring the shell test.

Use a disposable daemon or an explicitly isolated context for the rehearsal. The current wrapper sets
`NAGARE_REHEARSAL_RESET=1`, and the drill deletes fixed cluster and registry names. A pre-existing
cluster, registry or forwarder belonging to someone else must survive. Remove the hard-coded socket,
Colima DNS rewrite and unconditional reset. For the two local MinIO images, reuse the pinned upstream
binary downloads, digest checks and architecture selection in `scripts/publish-local-minio-images.sh`. Run
against the drill's registry. Keep the source and candidate service images bound to their own releases.

- [ ] Interrupt a platform release at the intranet step. Rerun that step and publish from the same run
  directory. The previous step results and invocation counts show the gate, image preparation and
  rehearsal ran once. A mismatched revision or a missing rehearsal refuses publication before a provider
  write.
- [ ] Cut a release from a clean checkout on a second machine using its credentials, ordinary toolchain
  and documented remote sources. Start without first-machine run records, preloaded drill images or a
  workstation-specific daemon. Its published rehearsal record shows the seeded value read back.

**D2. Stateless Kubernetes recovery.** EP-274 owns the milestones, including the slow-update regression.
Its deletion estimates are 2,500 Haskell source lines and 6,000 test lines. Shared constructors and their
tests can leave only after their strict and historical callers have gone.

- [ ] Two qualifying D2a releases and the ledger decision are recorded in the child. After D2b, two
  engineers using separate clients demonstrate that an interrupted eligible apply leaves an unrelated
  fresh review able to complete.

**D4. Remove unused features.** Check the declared intranet configuration in `mori://tan/tan-ng-labs`,
generated platform scopes and runtime/operator entry points. Maintenance sessions, live restore, domain
moves, stuck-pod recovery, VM power, CDN and purge, the broker, ClickHouse, previews and image prune each
need an individual disposition. A recovery command may be needed only during an incident. Admission
already refuses new live restores and maintenance sessions while directing old transactions to recover by
ID. Prove that retained records and currently supported upgrades have an exit before removing their
readers or adapters. Keep delegated deployers, actor recording and the data-recovery and rebuild
commitments. Remove the unused `registerKubernetesDataFence` registration helper after confirming the
production fence path and its tests.

- [ ] Each deleted feature has a recorded usage finding, a decision on its recovery obligations and a
  passing test of the surviving caller or supported upgrade.

**D5. Retire gates and documentation.** D5 owns the per-commit and per-landing commands. D3 owns removing
the release-time sweep, deep tier and candidate gate invocation. Cut them over together with `just land`,
its hook and the release skill. A clean second checkout must be able to establish that the candidate's
landing check passed, either by retrieving its result or running that same check locally. Remove the
superseded recipes and records after that path works. Keep the GCP isolation and host mutation rules.
Remove the plan-owner hook and its registration, held-plan rule, duplicated decision-basis text, per-fix
mutation/trace/ledger ceremony, native-run prerequisite and checklist tick-with-evidence paragraph.

Cancel MasterPlans 21 and 25 as decided. The 36 ExecPlans with open boxes at the planning commit
`dfddb8f3` are 71, 96, 101, 116, 117, 122–127, 164–167, 183, 194, 201, 202, 204–206, 210, 211, 215, 216,
219, 220, 223, 224, 230, 238, 239, 243, 244 and 268. Close each with its actual disposition and identify
the owner of any surviving obligation. Preserve later independent work, including EP-271 through EP-274.
Remove completed and cancelled plans after checking live registry links, ADR references and Mori handles.
Where a surviving document needs historical evidence, use a commit-pinned local-repository history link.
Move live audit fixtures, including generator inputs, with their consumers. Keep the MP-23 ledger
accessible to D2b until its findings decision. Then remove retired files from `docs/audits/` and
`docs/evidence/`.

- [ ] The two retained gates accept a clean candidate. Surviving tests, fixture generators and documentation resolve their inputs after cleanup.


The isolated builder store corruption during v0.24.1 remains outside this initiative.


## Surprises & Discoveries

The findings ledger already records F73, a foreign write to a Knative Service that was wrongly treated as
Nagare's landed update. The planner also represents a matching unready Deployment as `ObservedPresent`.
Both affect what can count as a successful D2 apply. [Findings ledger](../audits/mp23-findings.md) and
[Kubernetes adapter](../../cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs)


## Decision Log

- Decision (operator, 2026-11-20): Write this as a new MasterPlan. The rule "no new MasterPlan
  until the readiness checklist is ticked" does not apply and is being removed from `CLAUDE.md`.
  Rationale: the operator asked for cruft removal three times before, and each plan added
  machinery.
  Date: 2026-11-20

- Decision: Use the existing `dataPolicy` and Kubernetes overlap predicate to identify candidates. EP-274 selects the execution path for the whole review.
  Rationale: `Stateless` and `Durable` already exist on every member and are already branched on
  in two places (`Execute/Driver.hs:347`, `KubernetesApplication.hs:129`).
  Date: 2026-11-20

- Decision: The brief's reading that stage 4 was "controller activity read as a fault" is
  corrected. The stop was Nagare failing to recognise its own landed write after a readiness
  timeout.
  Rationale: the stamp is the `nagare.dev/spec-digest` annotation, which no controller writes
  (`KubernetesConfiguration.hs:33`).
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Drop the release attachments (`nix-output-*.json`,
  `clone-free-*.json`, the byte-identical double assembly). A release is a signed tag, its notes
  and the rehearsal record.
  Rationale: operators pin the tag. The current checked publisher reads the attachments, so D3 changes that consumer in the same cutover.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Delete the mutation sweep and the deep tier.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Delete the `CLAUDE.md` rules listed in D5, and delete completed
  and cancelled plan files from the tree. The GCP guardrail and host mutation rules stay.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): The aim is an architecture several engineers can operate
  safely, and the system must stay robust. D2 is split. D2a goes now. D2b is accepted in principle
  with the audit trail kept (actor and review per apply) and starts after two releases on D2a and
  the ledger check. Finish-line test 4 is added.
  Rationale: the protections between engineers are at admission and are untouched; the
  one-transaction rule makes every stop state a team-wide stop. D2b gives up exact resume and the
  stop on a `kubectl` edit made between plan and apply. How a stopped stateless apply holds no
  transaction is addressed by EP-274's two-client experiment before the new path can ship.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): The delegated deployer and actor recording are not deletion
  candidates. The other candidates leave after the D4 usage check. The review below clarifies how to check recovery-only uses.
  Date: 2026-11-20


- Decision (D1, 2026-11-20): The host moves only when what it evaluates changes. Its reviewed
  configuration digest drops the generated release comments and replaces a payload store path in
  `inputs.nagare.url`; its lock digest compares the payload node by narHash. The transport still checks
  raw file digests. The first release on this formula activates the unchanged closure once.
  Rationale: the evaluated system depends on the payload input only through its narHash.
  Date: 2026-11-20

- Decision (D1, 2026-11-20): A plan whose platform scope vector equals the live cluster marker's keeps
  that marker, so the cluster records the release that last changed it. `platform transition commit`
  pins such a release only after planning it again finds zero operations and no re-accepted scope, and
  when no stage was admitted it opens the marker already finalizing, keeping the pin-last protocol.
  `platform status` reports the payload's identity for the cluster, and the marker's as `clusterStamp`,
  only when the pin names this release, the marker's vector equals the head's accepted platform vector,
  every platform scope converged and nothing is in flight.
  Rationale: the transition command stays the only judge of "nothing to apply"; the pin is version
  only, so two different payloads of one version are not distinguished, as before.
  Date: 2026-11-20

- 2026-11-20 review revision. Give recovery one named child and bind each shared release check to its
  owner. Distinguish release provenance from installed content, isolate rehearsal resets and preserve
  strict recovery for mixed or historical work. These decisions address the checked publisher, scope-level
  convergence and existing operator edits found during review.

## Outcomes & Retrospective

(One paragraph at completion.)
