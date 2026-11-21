---
id: 37
slug: make-releases-routine-by-deleting-what-nagare-does-not-need
title: "Make Nagare releases fast and reliable"
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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-21T16:50:03Z
      mode: "implement"
      note: "D1 complete: nagare-core split, serving image, v0.25.0 and v0.25.1 released"
---

# Make Nagare releases fast and reliable

The operator asked for this plan on 2026-11-20, after v0.24.1, a 30-line CLI fix, took seven
candidate runs and most of a day. Its scope is release engineering: make releasing faster and more
reliable, and improve the tests (operator, 2026-11-21).


## Vision & Scope

### Finish line

The plan is done when the following three observations are recorded. Use a real CLI-only release for the
first, a platform-changing release for the second, and either release for the clean-checkout run.

1. **A CLI-only fix ships without moving the platform.** Its intranet plan has zero operations: no
   host activation, no image publication, no cluster change.
2. **A platform release that stops at the intranet step restarts at that step.** Nothing before it
   runs again.
3. **A release is cut from a clean checkout on a second machine**, with nothing copied from the
   first except credentials.

### What this plan may change

- Release tooling: the candidate, rehearsal, intranet and publish steps, their scripts and recipes.
- Refactoring for faster builds and releases, with no change to what Nagare does for an operator.
- Deleting tests, test tiers and markdown plans that are already Complete or Cancelled.

### What this plan does not change

- No Nagare feature is removed, and no runtime or recovery behaviour changes.
- No open or held plan is cancelled or closed. MasterPlans 21 and 25 stay held.
- `docs/audits/`, `docs/evidence/` and `docs/release-evidence/` stay.
- Everything that guards data stays exactly as strict: the reviewed, journalled, fenced path for
  databases, migrations, backups, restores and volumes, and the upgrade rehearsal that reads a seeded
  row back. So do the GCP guardrail in `scripts/lib/target.sh` and its fail-closed cloud branch,
  guarded host activation (`just host-switch`, ADR 11) and Kubernetes ownership stamps.

### What is wrong, measured

- **Every release moves the host and the admin API, whatever changed.** The host flake carries the
  source revision (`Host/Config.hs:344`), so a new revision is a host activation. The admin API
  image links the whole `nagarectl` library and depends on `cluster/`, `nixos/` and `release.json`
  (`nix/haskell-packages.nix:36`), so its digest changed in all 20 of the last 20 releases.
  v0.24.1 planned a host update and 14 platform operations for a planner fix.
- **A candidate run cannot resume.** Each run starts a new directory and repeats every step.
  `release-publish` needs a `latest` link and a landed evidence commit that only a complete run
  writes. Pin-file refusals interrupted two of v0.24.1's seven runs.
- **Release state lives on one workstation:** gate and sweep records under `~/.local/state`, a
  Colima profile whose socket path is hard-coded, two container images that must already be in its
  store, and an on-demand x86 builder.


## Decomposition Strategy

D1 changes how a release proves what is installed. D3 changes how it is rehearsed and published. D5
retires superseded test tiers and plan files after their callers have moved. All three go through the
existing release commands. The deliverable numbers are kept from the first draft; D2 and D4 left the plan
on 2026-11-21.


## Exec-Plan Registry

| Deliverable | Plan or owner | Hard prerequisite | Status |
|---|---|---|---|
| D1. CLI-only release | MasterPlan, release identity and packaging | None | Complete |
| D3. Resumable release steps | MasterPlan, release tooling | D1 identity for combined release acceptance | In Progress |
| D5. Test tiers and plan files | MasterPlan, landing and plans | D3 switch for gate removal | In Progress |


## Dependency Graph

D1 and D3 overlap and are accepted together through the candidate, intranet and publish commands. D5
removes each gate recipe or record only with the cutover of its last caller.


## Integration Points

- **Installed identity belongs to D1.** The CLI and payload report the release version and revision.
  Compare the host by the desired host configuration and locked inputs, the cluster by deployed content
  including image digests. When the source is admitted and the reviewed comparison finds no platform
  work, finalization advances the context pin with zero provider writes. Preserve the recoverable
  pin-last protocol. D3 consumes this comparison in rehearsal, intranet and publication.
  [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
- **The run directory and its public record belong to D3.** The candidate writes its version, revision and
  previous version before a restartable step needs them. Each step reads that run and validates its
  prerequisite results for the same candidate. Publication requires passing landing, rehearsal and
  intranet results. D5 removes obsolete gate calls after the candidate consumes the per-landing result.
  [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) and
  [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)


## Progress

D1 is complete; D3 and D5 are in progress. Record the accepting commit and line deltas for each
deliverable.

D1 so far: the host's reviewed identity ignores the release comments and payload store path
(`f4cfb2c4`); a plan that moves no platform scope keeps the earlier release's cluster marker, and the
transition commit pins such a release after its own plan finds no work. The admin API reports its
serving image instead of a release version (`bc538ce2`) and links only `cli/nagare-core`, 79 modules
moved out of nagarectl (`6c2b9665`, `64c012d2`, `51133288`). After an unrelated CLI and planner
edit plus a version bump the admin layout keeps its store path (`fhn9cs4j…-nagare-nagare-admin-api-oci`);
a change in nagare-core changes it. Replayed over v0.24.1 to v0.24.5, only v0.24.4 (an `Inventory.Adapter`
change) would have moved the image. v0.25.0 (`39193ea4`) carried the one-time moves: 9 operations over
two stages, the host switch and the admin API and nagare-access images. v0.25.1 (`70ed811a`), a version
bump alone, kept every image digest and store path; its intranet stage planned 0 operations and
re-accepted nothing, `platform transition commit` confirmed the plan and moved the pin alone, the
cluster marker stayed at 0.25.0 (`clusterStamp`), the status was exact with the protected URL
answering 302, and the published tag passed the public flake check. D5 so far: the
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

- [x] A real CLI-only release reports zero intranet operations, including host activation, image
  publication into the context registry and cluster writes. The candidate and published tag pass identity
  verification. Pass: v0.25.1 (`70ed811a`), 2026-11-21; run
  `~/.local/state/nagare/releases/v0.25.1/20261121T163102Z/` (`intranet/stage-1.summary.json`:
  `operationCount` 0, `reaccepted` []).

**D3. Each release step can run alone.** Make the explicit run directory work through `just`, the
candidate harness, intranet, rehearsal and `scripts/release-publish.sh`. In
`cli/nagarectl/app/Nagare/Cli/Commands/Release.hs` and
`cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs`, switch producer and publisher together to the
signed tag, its notes and the candidate-bound rehearsal record. Validate the previous release, candidate
revision, completed transition, seeded row read-back and intranet outcome before publishing. Preserve
immutable-tag and same-draft retry behavior. Drop the native output and clone-free assets, double
assembly, Apple-container attachment step and attachment-only x86 work. Verify that the retained x86
release-image build or cache substitution works from the second machine. Remove assembly, attachment
checks, the evidence commit and `latest` after their readers move.
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

D3 so far (`e24f4542`..`67e11120`): the rehearsal runs on a Colima profile it creates with Rosetta
and deletes, or on an empty daemon `NAGARE_REHEARSAL_DOCKER_HOST` names; the drill refuses a daemon
holding k3d, publishes MinIO through `publish-local-minio-images.sh` (now `curl`) and forwards on a
host-free port. A candidate run is `releases/vX.Y.Z/<rev>` with `candidate.json` written first; a
rerun keeps the gate record, images receipt, rehearsal record and intranet record, indexed as
`kept`. The candidate consumes `gate-verify` (or runs `just gate`), so `gate-release` is gone.
Publication is `nagare-harness release publish`: every proof before the tag, the candidate CLI's
review before the push, two assets. The pin ledger (`intranet/pins.json`) refuses foreign pin
diffs. Deleted: assembly, native and clone-free attachments, the x86 container step, SHA256SUMS,
the evidence commit, `latest`, and their tests and checks. Scripts −1,381 net (target 1,200);
Haskell +226 source and +289 test lines, from publication moving out of shell. Native: the
harness tests cover the fake-transport cases; the disposable-profile rehearsal ran green and v0.25.2
published its record.
The mutation sweep and deep-tier recipes, Mutation.hs and the mutation records remain for the
D5 cutover.

- [ ] Interrupt a platform release at the intranet step. Rerun that step and publish from the same run
  directory. The previous step results and invocation counts show the gate, image preparation and
  rehearsal ran once. A mismatched revision or a missing rehearsal refuses publication before a provider
  write. So far on a CLI-only release: v0.25.2 (`3e0be405`), 2026-11-21, run
  `~/.local/state/nagare/releases/v0.25.2/3e0be405aa7e1a256c0373cfd9767095cda40c23/`, interrupted
  by SIGINT after the pin (`intranet/pins.json`) and before any plan; the rerun's `index.json` shows
  gate `kept` twice, images and rehearsal `passed` once then `kept`, intranet `failed` then
  `passed` (0 operations, status exact, protected URL 302); published from the same run directory.
  The refusals are covered by `ReleaseCandidateSpec`'s publish tests. Open until a release that
  changes the platform repeats it.
- [x] Cut a release from a clean checkout on a second machine using its credentials, ordinary toolchain
  and documented remote sources. Start without first-machine run records, preloaded drill images or a
  workstation-specific daemon. Its published rehearsal record shows the seeded value read back.
  Pass by operator decision, 2026-11-21: v0.25.0 and v0.25.1 were released from this machine after
  everything moved to it, and v0.25.2's rehearsal ran on a Colima profile it created and deleted,
  with MinIO from the upstream downloads; its published record reads the seeded row back. The gate
  record was this machine's own; without one the candidate runs `just gate` itself.

**D5. Retire superseded test tiers and plan files.** Delete the mutation sweep and deep-tier recipes,
`Mutation.hs`, the mutation records and `gate-fast`'s mutation-records check, together with `just land`'s
cutover so a clean checkout can establish that the candidate's landing check passed, by retrieving its
result or running that same check locally. Delete markdown plan files already marked Complete or Cancelled
after checking live registry links, ADR references and Mori handles; where a surviving document needs
their history, use a commit-pinned link. Do not cancel, close or edit the status of an open or held plan;
that is the operator's decision, plan by plan.

- [ ] The two retained gates accept a clean candidate, and the surviving tests pass.
- [ ] Completed and cancelled plan files are removed with no broken link.


The isolated builder store corruption during v0.24.1 remains outside this initiative.


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

- Decision (planning session, 2026-11-20; corrected 2026-11-21): The delegated deployer and actor
  recording are not deletion candidates. This entry also said the other feature candidates leave after
  a usage check and credited that to the operator. The operator never chose features to remove; their
  agreement covered the plan's other decisions. Superseded by the 2026-11-21 cancellation of D4.
  Date: 2026-11-20

- Decision (operator, 2026-11-21): Cancel D4. No Nagare feature is removed by this plan. Every
  feature was built for a goal, and Nagare runs more installations than `mori://tan/tan-ng-labs`:
  `mori://shinzui/kikan` depends on Redis, Kafka and almost every feature. Absence from one
  installation's configuration is not evidence that a feature is unneeded.
  Date: 2026-11-21


- Decision (operator, 2026-11-21): The plan's scope is release engineering only: faster, more
  reliable releases and better tests. It may delete tests and markdown plans that are already Complete
  or Cancelled, and refactor code for faster builds and releases. D2 (EP-274, stateless recovery) leaves
  the plan, since it changes Nagare's recovery behaviour; EP-274 is no longer a child and is not
  scheduled. MasterPlans 21 and 25 are not cancelled and stay held; the 36 ExecPlans with open boxes are
  not closed by this plan. `docs/audits/`, `docs/evidence/` and `docs/release-evidence/` stay.
  Finish-line test 4 is withdrawn with D2. The file keeps its slug so existing links resolve.
  Rationale: the first draft listed cancellations and removals the operator never chose, and their
  agreement to its numbered decisions was read as approval of everything in it.
  Date: 2026-11-21

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

- Decision (operator, 2026-11-21): The admin API reports what it is: `servingBuild` is the image
  reference its Deployment passes with `--image`, plus its contracts, and `comparison` matches that image
  against the accepted declaration's `nagare-admin-api` image by digest. `/v1/platform/version` returns the
  same serving build. This replaces the version and revision fields of contract 1 in place; every reader is
  in this repository.
  Rationale: an image reused across releases cannot embed the release that installed it.
  Date: 2026-11-21

- Decision (operator, 2026-11-21): The events worker's backup collector reads accepted CronJob bytes from
  observation bytes only. A member whose bytes exist only in a review published before observation bytes
  is an unresolved schedule naming `inventory store materialize-native`; the CLI keeps the review
  fallback. The code the admin API links moves, unchanged, into `cli/nagare-core`, which nagarectl
  re-exports; the architecture audit treats the two as one package for private modules.
  Rationale: the fallback alone linked the planner and adapters (204 modules against 79).
  Date: 2026-11-21

- Decision (operator, 2026-11-21): A rerun of the intranet step that finds a pin file whose bytes
  differ from what the run recorded refuses, naming the file, and commits nothing; the operator's
  edit stays in the working tree. The commit is not built from recorded bytes.
  Rationale: the least mechanism that keeps an unrelated edit out of the pin commit.
  Date: 2026-11-21

- Decision (D3, 2026-11-21): The candidate's landing check is the landed commit's green full-gate
  record (`gate-verify`), or that full gate run by the candidate when the machine has no record. The
  publication intent's `payloadId` is `git:<commit>`, since no manifest is assembled. Historical
  `docs/release-evidence/` records stay; nothing writes there now.
  Date: 2026-11-21

- Decision (operator, 2026-11-21): No separate second machine; the old workstation is retired and
  every release since the move has been cut on this one. Finish-line observation 3 counts as met
  by the move plus v0.25.2, as recorded in D3.
  Date: 2026-11-21

- 2026-11-20 review revision. Give recovery one named child and bind each shared release check to its
  owner. Distinguish release provenance from installed content, isolate rehearsal resets and preserve
  strict recovery for mixed or historical work. These decisions address the checked publisher, scope-level
  convergence and existing operator edits found during review.

## Outcomes & Retrospective

(One paragraph at completion.)
