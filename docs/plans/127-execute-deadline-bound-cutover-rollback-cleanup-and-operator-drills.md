---
id: 127
slug: execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills
title: "Execute deadline-bound cutover rollback cleanup and operator drills"
kind: exec-plan
created_at: 2026-09-13T22:09:04Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:04Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T03:34:56Z
      mode: "implement"
      note: "Implement cutover executor, rollback, cleanup, drills, docs, and ADR distillation"
---

# Execute deadline-bound cutover rollback cleanup and operator drills

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare turns a verified candidate into the active platform through one deadline-bound command.
The command rechecks drift, quiesces writes, performs the rehearsed final state transfer,
moves the existing static IP without changing DNS, verifies the real public path while writes
remain gated, and either commits the candidate or restores the old path before the rollback
reserve is consumed. The former active VM and disks remain available but stopped until the
operator explicitly finalizes.

The operator runs `nagarectl platform replacement cutover <transaction-id> --confirm
<context>/<transaction-suffix>`. Status shows a monotonic downtime counter, current phase,
hard forward-work cutoff, rollback eligibility, and final observed outage. `rollback` is
available until candidate writes are admitted; `finalize` removes only recorded former-active
resources after the retention gate and returns steady state to one VM.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-13 20:35 PDT) Audited the working tree and established that the hard-prerequisite
      ExecPlans 122 through 126 have no implementation; added the missing prerequisite contract
      surface to this execution rather than pretending those APIs already exist.
- [x] (2026-09-13 20:58 PDT) Implemented the minimal replacement transaction, deadline, and state-transfer contract
      surface required by this executor without claiming the prerequisite plans complete.
- [ ] Implement pre-cutover arming, freshness/drift reconciliation, confirmation, and
      maintenance/quiesce contracts.
- [ ] Implement the monotonic deadline executor and exact static-IP handoff sequence.
- [ ] Implement automatic/manual rollback reconciliation for every interruption point.
- [ ] Implement atomic promotion, write admission, stopped-old retention, and guarded cleanup.
- [x] (2026-09-13 21:04 PDT) Added deterministic before/after fault-injection coverage and local
      integrated tests for every pre-commit external-operation boundary.
- [ ] Run forward/rollback live drills that satisfy the selected budget after ExecPlan 122
      supplies a disposable environment and measured address-handoff contract.
- [ ] Complete operator runbooks and distill durable decisions into the replacement ADR.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: Stopping a GCE VM does not detach its static external IP; address movement needs
  an explicit access-config detach/attach sequence.
  Evidence: current `NagareInstance` places the reserved address in `accessConfigs`, and the
  disposable proof in ExecPlan 122 measures the required operations.
- Observation: Rolling back after the candidate accepts writes can lose those new writes
  because the old and candidate use independent storage.
  Evidence: the low-cost design deliberately has no synchronous replica.
- Observation: Committing only the Pulumi active slot is insufficient; host, kubeconfig,
  platform version, and cluster stamps are context-owned identities used by later commands.
  Evidence: the existing upgrade transaction commits the context last under ADR 0006.
- Observation: None of the hard-prerequisite replacement plans have been implemented in the
  current working tree, including the disposable address-handoff proof from ExecPlan 122.
  Evidence: `Nagare.Platform.Replacement`, `Nagare.Platform.StateTransfer`, candidate-slot,
  and rehearsal modules are absent, while every Progress item in ExecPlans 122 through 126 is
  unchecked at commit `f4953c1`.
- Observation: The plan's root-level Cabal command is not executable because this repository has
  no root `cabal.project`; the package project lives in `cli/nagarectl/`.
  Evidence: `nix develop -c cabal build nagarectl` from the repository root reports Cabal error
  7136, while the same build from `cli/nagarectl/` succeeds.
- Observation: A failed write-gate command cannot be treated as proof that writes stayed fenced;
  actual gate observation determines whether the irreversible commit point occurred.
  Evidence: the injected failpoint after the admission side effect observes admitted writes and
  completes the promotion without invoking old-context rollback.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the old VM running but application-quiesced during final transfer and address
  handoff; stop it only after candidate verification and context commit.
  Rationale: A running, detached old host is the fastest rollback target and consumes only a
  few extra compute minutes during the bounded window.
  Date: 2026-09-13
- Decision: Keep candidate writes disabled until all public verification and durable context
  commit steps succeed; admitting candidate writes is the commit point.
  Rationale: Before that point, rollback can restore the old state without discarding accepted
  writes. After it, automatic rollback is unsafe without reverse state transfer.
  Date: 2026-09-13
- Decision: Stop forward progress when remaining time equals the measured rollback reserve
  plus safety margin, not when the total budget expires.
  Rationale: The budget must contain recovery, not merely detect that the attempt ran late.
  Date: 2026-09-13
- Decision: Use the proven direct GCE address operation for the short handoff and then
  reconcile Pulumi state/config to the promoted slot.
  Rationale: A single Pulumi update cannot safely express every intermediate failure boundary;
  the executor needs observable, reversible steps, followed by declarative convergence.
  Date: 2026-09-13
- Decision: Default former-active retention to 24 hours but show its disk cost and allow a
  shorter explicit retention or immediate finalization after acceptance.
  Rationale: Stopped VMs do not need ongoing compute, while a short rollback window is valuable;
  retained disks still cost money and must not become unnoticed permanent infrastructure.
  Date: 2026-09-13
- Decision: Implement the smallest prerequisite transaction/deadline/state-transfer contracts
  needed by the cutover executor in this plan, but leave infrastructure provisioning,
  rehearsal, and state-adapter delivery attributed to their owning plans.
  Rationale: The cutover module cannot compile or prove its safety invariants against nonexistent
  types. Supplying the pure shared boundary here permits deterministic executor work without
  falsely marking ExecPlans 122 through 126 complete or performing their cloud mutations.
  Date: 2026-09-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The current in-place executor is wired in `cli/nagarectl/app/Main.hs` and modeled by
`Nagare.Platform.Upgrade`. It previews infrastructure and Kubernetes, applies Pulumi, runs
`scripts/host-switch.sh` on the active instance, applies cluster objects, stamps the cluster,
and commits the context last. It does not manage two hosts or a downtime deadline.

ExecPlan 123 supplies the `ReplacementTransaction`, budget arithmetic, and legal transitions.
ExecPlan 124 supplies two Pulumi host slots and authoritative resource IDs. ExecPlan 125
supplies expiring fenced-rehearsal evidence and explicit candidate targeting. ExecPlan 126
supplies the complete state plan and deadline-aware final-transfer operations. This plan is
the sole owner of production quiesce, GCE address mutation, public verification, active-slot
promotion, rollback, and former-active cleanup.

Quiesce means the public ingress presents maintenance for ordinary requests, every declared
writer is stopped or in a verified read-only mode, CronJobs and hooks are suspended, database
connections drain, and a write-fence token is observed. The downtime clock starts when the
first successful quiesce action denies a production write. The candidate also remains behind
a write gate. Verification traffic uses an explicit transaction-scoped bypass to exercise
the candidate internally and through the reserved public IP without opening ordinary writes.

The commit point is the ordered conjunction of successful public verification, atomic context
promotion, and removal of the candidate write gate. Before it, rollback restores the old
address and unquiesces old writers. After it, automatic rollback is disabled because candidate
writes may exist; recovery requires a new planned state transfer or application-specific
reverse adapter.

Relevant decisions are [ADR 0004](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
[ADR 0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
[ADR 0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md),
[ADR 0011](../adr/0011-host-activation-is-guarded-and-self-reverting.md),
[ADR 0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md),
[ADR 0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md),
[ADR 0014](../adr/0014-the-active-context-owns-the-vm-shape.md), and
[ADR 0018](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md).
The ADR created by ExecPlan 122 must be updated at completion with the actual deadline and
commit semantics. Mori found no applicable cross-repository ADR.


## Plan of Work

### Milestone 1: Arm and revalidate without downtime

Add `Nagare.Platform.Cutover` and CLI parsers in `Main.hs`. `cutover` first resolves actual
GCP/Pulumi/Kubernetes state, checks project/zone/resource IDs, recomputes the drift token and
state sizes, requires fresh successful evidence, and evaluates the budget again. While the
old platform serves, switch the candidate from reader identity/local TLS to its production
identity and TLS material, restart it if GCE requires that change, remove its ephemeral
access config, and rerun every check affected by arming. It remains tagged candidate and
write-fenced. Print the exact planned sequence, predicted forward time, rollback threshold,
retention cost/time, and require the context/transaction confirmation token. No downtime
begins in this milestone.

### Milestone 2: Quiesce and final state transfer

Install/activate the maintenance gate on old and candidate. Execute each declared source
quiesce contract, suspend schedules, drain active requests/connections, and verify the global
write-fence token. Start the injected monotonic deadline on the first write denial. Invoke
ExecPlan 126 final-transfer adapters in their planned order or safe parallel groups, enforcing
their individual timeouts and recording commit tokens. Reverify candidate state and remaining
headroom. If any step fails or the rollback threshold is reached, immediately enter rollback;
do not move the public address.

### Milestone 3: Address handoff, public verification, and commit

Apply the candidate's `nagare-active` tag while it has no external address. Detach the named
reserved access config from old and attach that same reserved address to candidate using the
exact commands and polling rules proven in ExecPlan 122. Verify the address resource and both
instance network interfaces rather than trusting command success. Probe DNS resolution (which
must be unchanged), TCP 80/443, certificate chain/name, maintenance response, authentication,
Knative routing, and transaction-bypassed read-only application/database sentinels through
the public IP. If all pass with rollback headroom, atomically write the context's active slot,
instance, host flake, kubeconfig, payload/platform version, and cluster stamp; reconcile
Pulumi ownership; then remove the candidate write gate. Record that instant as the irreversible
write-admission commit point. Stop the old VM only after commit and verify it is terminated
but not deleted.

### Milestone 4: Reconcile every failure into rollback

Implement `rollback <transaction-id>` plus automatic rollback entry from every pre-commit
phase. Cancel forward jobs and fence candidate writes. If the address moved, detach it from
candidate, restore old's active tag/access config, and poll authoritative attachment. Ensure
old is running, restore its prior Kubernetes scale/schedules/write mode from captured state,
remove maintenance, and probe the public path. Persist before and after each substep so a
process crash can resume by inspecting actual address/tag/instance state. If GCP remains
unavailable beyond the measured reserve, continue recovery and clearly mark the SLO breach;
no single-node design can absolutely bound a provider control-plane outage.

### Milestone 5: Retention and guarded finalization

After commit, status reports the former-active VM stopped, its protected disks, rollback
expiry, and estimated temporary storage cost. `finalize` requires an explicit confirmation,
no active transaction references to the old resources, current public health, current backup
and replacement evidence retention, and elapsed configured retention unless `--now` is given.
It removes only resources whose exact IDs and transaction/slot roles match the transaction,
preserves ordinary backups and the reserved IP, converges Pulumi to active-only, prunes
transaction-specific seed artifacts, and marks the transaction complete. A scheduled/operator
invoked cleanup reminder prevents the old slot from becoming permanent; deletion itself is
never silent.

### Milestone 6: Fault injection, live drills, docs, and ADR distillation

Build a deterministic fake executor with an injected monotonic clock and failpoints before
and after every external operation. Prove restart/reconcile, rollback threshold selection,
no write admission before commit, and cleanup ownership. Run local integrated state drills,
then use the disposable GCP environment for one successful promotion and one forced
post-handoff rollback. Both must restore a healthy public endpoint within the requested 900
seconds using the same reserved IP and no DNS update. Update upgrade, provisioning, database,
storage, context, troubleshooting, and disaster-recovery docs plus an operator drill runbook.
Perform the final Decision Log/Surprises distillation into the replacement ADR.


## Concrete Steps

Run from the repository root:

    nix develop -c cabal test nagarectl-test --test-show-details=direct
    npm --prefix infra/pulumi run build
    nix flake check --print-build-logs

Focused output must include failures at every boundary, for example:

    PlatformCutover
      starts deadline on first successful write fence: OK
      rolls back before reserved threshold: OK
      reconciles crash after old address detach: OK
      never admits candidate writes before context commit: OK
      cleanup rejects an unrecorded resource: OK

Before a real drill, inspect without mutation:

    nagarectl platform replacement status <transaction-id> --json
    nagarectl platform replacement cutover <transaction-id> --dry-run

The transaction must be `ready`, blockers empty, evidence fresh, prediction at or below 900
seconds, and rollback reserve nonzero. Then execute in the explicitly disposable environment:

    nagarectl platform replacement cutover <transaction-id> \
      --confirm <context>/<transaction-suffix> --json

Expected terminal fields include `"state":"committed"`,
`"dnsChanged":false`, `"activeSlot":"<candidate-slot>"`, and
`"observedDowntimeSeconds":<value-at-most-900>`. Check the public sentinel and confirm the
new value written between seed and final transfer is present.

For the rollback drill, create a fresh replacement, inject failure immediately after address
attachment, and run the same cutover. It must finish in state `rolled-back`, restore the old
public sentinel within 900 seconds, accept writes only on old, and leave candidate writes
fenced. Finally, after the chosen retention:

    nagarectl platform replacement finalize <transaction-id> \
      --confirm <context>/<transaction-suffix> --json
    pulumi -C <context-infra-workspace> preview --diff

The preview reports no pending change and stack outputs show one active VM, no candidate,
one active data disk, and the unchanged reserved IP/DNS record.


## Validation and Acceptance

Acceptance requires:

* Cutover cannot start without exact confirmation, fresh rehearsal/state evidence, matching
  actual resource identities and drift token, a complete quiesce contract, and a budget with
  measured rollback reserve.
* Arming occurs while old serves. Candidate has no ordinary public ingress and accepts no
  production writes before commit.
* The downtime clock starts with the first denied production write. Forward work stops at the
  rollback threshold; it does not consume reserved recovery time.
* DNS records and TTL are byte-for-byte unchanged. The existing reserved IP is observed first
  on old, then on candidate for success, or back on old for rollback. No load balancer exists.
* A successful cutover includes final post-seed state, passes public TLS/auth/routing/data
  probes, commits all context identities, admits candidate writes exactly once, and stops but
  does not delete old.
* Every injected pre-commit failure converges to either safe pre-handoff old service or a
  verified rollback. A process restart reconciles actual state without double-detaching,
  double-attaching, or unquiescing both clusters.
* Forward and forced-rollback live drills each restore healthy public service within the
  selected 900-second budget under the provider behavior measured by ExecPlan 122. A provider
  control-plane outage is reported as an SLO breach, not mislabeled success.
* Finalize refuses mismatched/unrecorded resources, preserves backups/IP/DNS, deletes the
  former slot and transaction-only artifacts, and returns to one-VM steady state.


## Idempotence and Recovery

Preflight, arming checks, and dry-run are repeatable while the candidate remains fenced. Each
cutover phase persists intent before mutation and observation after mutation. On restart,
reconcile GCE address users, instance access configs/tags/status, Pulumi outputs, Kubernetes
write fences, and context commit record before selecting the next legal transition. Never
blindly rerun a mutating command.

Before commit, rollback is always the recovery path. Keep old data and context commit backup
untouched, cancel candidate operations, restore the address and old workload snapshot, and
verify public health. After write admission, do not run automatic rollback; fence further
writes and require a new state-transfer/recovery decision so accepted candidate writes are
not silently lost. `finalize` writes a resource manifest and preview first; if deletion
partially fails, reconcile only remaining manifest IDs. Protected disk deletion requires the
normal explicit unprotect step after every ownership and backup guard passes.


## Interfaces and Dependencies

Use existing Haskell dependencies and command wrappers. Use GCE CLI/provider operations only
as selected by ExecPlan 122, Kubernetes scale/patch/wait APIs through explicit kubeconfigs,
and Pulumi reconciliation through the context-owned stack. Do not add DNS APIs, a load
balancer, a daemon, or a new always-on service. A monotonic clock and cancellable timeout
interface must be injectable in tests; UTC is recorded only for audit.

`Nagare.Platform.Cutover` owns interfaces equivalent to:

    data CutoverPhase
      = ArmCandidate | Revalidate | QuiesceOld | FinalizeState
      | PrepareCandidateIngress | DetachOldAddress | AttachCandidateAddress
      | VerifyPublic | CommitContext | AdmitCandidateWrites | StopOld
      | RestoreOldAddress | RestoreOldWorkloads

    data CutoverOps = CutoverOps
      { monotonicNow :: IO MonotonicTime
      , armCandidate :: CandidateTarget -> IO ArmEvidence
      , quiesceOld :: ActiveTarget -> IO QuiesceSnapshot
      , finalizeState :: Deadline -> StateTransferPlan -> IO FinalStateEvidence
      , observeAddress :: IO AddressObservation
      , detachAddress :: HostIdentity -> IO ()
      , attachAddress :: HostIdentity -> IO ()
      , verifyPublic :: VerificationMode -> IO PublicEvidence
      , commitContext :: Promotion -> IO ()
      , setWriteGate :: ClusterTarget -> WriteGate -> IO ()
      , setInstancePower :: HostIdentity -> PowerState -> IO ()
      , restoreOldWorkloads :: QuiesceSnapshot -> IO ()
      }

    runCutover :: CutoverOps -> ReplacementTransaction
               -> IO (Either CutoverError ReplacementTransaction)
    runRollback :: CutoverOps -> ReplacementTransaction
                -> IO (Either CutoverError ReplacementTransaction)
    reconcileCutover :: CutoverOps -> ReplacementTransaction
                     -> IO (Either CutoverError Reconciliation)
    finalizeReplacement :: CleanupOps -> ReplacementTransaction
                        -> IO (Either CleanupError ReplacementTransaction)

The executor uses `Deadline { hardStop, rollbackAt }` from ExecPlan 123 and the
`StateTransferPlan` from ExecPlan 126. ExecPlan 124 is the authority for resource IDs and
Pulumi slot config; ExecPlan 125 is the authority for candidate/fence evidence. No later plan
may independently mutate the reserved address or admit writes. This plan closes the MasterPlan
only after updating all child outcomes, the master outcome, and the replacement ADR.


Revision note (2026-09-13): Recorded the missing prerequisite implementation discovered at the
start of execution and the scoped decision to supply only the pure contracts needed by cutover.

Revision note (2026-09-13): Recorded completion of the prerequisite contract slice and the focused
11-test cutover/rollback/cleanup validation, including the observed write-admission commit rule.

Revision note (2026-09-13): Expanded the deterministic suite to exercise both sides of every
pre-commit mutation boundary and separated that completed local proof from the blocked live drills.
