---
id: 123
slug: model-resumable-replacement-upgrade-transactions-and-downtime-budgets
title: "Model resumable replacement-upgrade transactions and downtime budgets"
kind: exec-plan
created_at: 2026-09-13T22:09:03Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:36Z
      mode: "update"
      note: "Adopt the existing replacement core as a compatibility-preserving implementation baseline"
---

# Model resumable replacement-upgrade transactions and downtime budgets

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare gains a second, explicit transaction type for replacement upgrades. An operator can
plan a move to a target Nagare release, record a downtime budget (initially 15 minutes),
resume interrupted preparation, and see whether fresh rehearsal evidence proves that the
final state transfer, public verification, and rollback reserve fit inside that budget. This
plan deliberately models and persists the workflow before any child plan is allowed to
provision or mutate cloud resources.

After this change, `nagarectl platform replacement plan --to 0.3.0
--downtime-budget 15m --json` creates a transaction without changing the running platform.
`nagarectl platform replacement status <transaction-id> --json` reports the active and
candidate identities, phase state, evidence freshness, predicted downtime, rollback
reserve, and the reasons that cutover is blocked. The existing in-place
`nagarectl platform upgrade` transaction remains valid and unchanged.

The current tree already contains a deliberately minimal `Nagare.Platform.Replacement` module
landed by ExecPlan 127 so its provider-independent cutover engine could compile and be tested. This
plan now adopts that schema version and extends it with complete preparation/evidence transitions,
context-owned paths, and the read-only CLI; it must preserve the 14 existing cutover tests and JSON
tokens rather than introducing a competing transaction type.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-13 21:28 PDT) ExecPlan 127 supplied the minimal version-1 replacement schema,
      cutover phase checkpoints, downtime arithmetic, atomic persistence, future-version refusal,
      stable JSON tokens, and deterministic executor coverage needed by its safety core.
- [ ] Reconcile and extend the existing replacement schema into the complete preparation/evidence
      phase graph with dedicated deterministic model tests.
- [ ] Extend the existing atomic persistence and future-version refusal with context-owned paths,
      evidence digests, migration behavior, and ownership guards.
- [ ] Add read-only `platform replacement plan` and `status` command surfaces.
- [ ] Document the transaction lifecycle and amend the feasibility ADR from ExecPlan 122
      if implementation establishes a durable detail not already captured there.
- [ ] Run focused Haskell tests, CLI behavioral tests, and the full flake check.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The current `UpgradeTransaction` schema is version 1 and combines planning
  and in-place application phases in `Nagare.Platform.Upgrade`; changing its meaning would
  risk invalidating resumable upgrades already stored in operator contexts.
  Evidence: `cli/nagarectl/src/Nagare/Platform/Upgrade.hs` decodes a fixed phase vocabulary
  and `cli/nagarectl/app/Main.hs` executes `HostApply` against the active VM.
- Observation: A useful downtime promise is an inequality backed by evidence, not a fixed
  sleep or a claim that every workload can move in 15 minutes.
  Evidence: final PostgreSQL dump/restore and retained-volume synchronization times depend
  on the actual data set, while address movement and rollback have separate measured costs.
- Observation: `Nagare.Platform.Replacement` is no longer hypothetical, but it intentionally covers
  only the cutover-facing contract and does not provide planning/status CLI, full evidence
  references, or preparation transitions.
  Evidence: the current module exports `ReplacementTransaction`, readiness/deadline arithmetic,
  phase checkpoints, persistence, and rendering; `PlatformCutoverSpec` exercises 14 safety cases,
  while `app/Main.hs` exposes no `platform replacement` command.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a separate `ReplacementTransaction` instead of extending schema version 1
  of `UpgradeTransaction`.
  Rationale: Existing in-place upgrades keep their compatibility and semantics, while the
  replacement workflow can represent two hosts, rehearsal evidence, rollback, and cleanup.
  Date: 2026-09-13
- Decision: Make the downtime budget user supplied and default it to 15 minutes in the CLI.
  Rationale: Fifteen minutes is the product goal, but the tool must be able to refuse that
  budget for data sets whose measured final transfer cannot fit and allow an operator to
  choose a larger explicit window.
  Date: 2026-09-13
- Decision: Reserve rollback time before entering cutover and use monotonic elapsed time
  while executing it.
  Rationale: Wall-clock timestamps are appropriate for durable audit records but can jump;
  a deadline and rollback threshold must not depend on wall-clock adjustments.
  Date: 2026-09-13
- Decision: Planning and status are read-only with respect to cloud and cluster state.
  Rationale: An operator must be able to inspect feasibility before accepting temporary
  infrastructure cost or production risk.
  Date: 2026-09-13
- Decision: Evolve the version-1 schema already consumed by `Nagare.Platform.Cutover` instead of
  replacing it or creating a second planning record.
  Rationale: the early implementation has persisted-token and executor tests that are now a
  compatibility boundary; this plan owns completing that boundary while preserving those callers.
  Date: 2026-09-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The cutover-facing subset now exists: version-1 transaction persistence, deadline/readiness
arithmetic, cutover checkpoints, stable JSON tokens, and the executor's deterministic compatibility
tests. The complete preparation/evidence graph, context-owned evidence storage, model transition
suite, and read-only planning/status CLI remain unimplemented, so this plan is In Progress rather
than complete.


## Context and Orientation

The current in-place transaction engine is
`cli/nagarectl/src/Nagare/Platform/Upgrade.hs`. It stores a schema-versioned JSON record and
runs preview phases followed by `PulumiApply`, `HostApply`, `KubernetesApply`,
`ClusterStamp`, and `ContextCommit`. `cli/nagarectl/app/Main.hs` wires those phases to the
active context. Its Pulumi phase now retains a reviewed plan through `Nagare.Infra.Plan` and
records guarded completion/recovery through `Nagare.Platform.PulumiReceipt`; replacement planning
must reuse those evidence conventions where it controls Pulumi. The tests live primarily in
`cli/nagarectl/test/PlatformSpec.hs`, and the library module list and test-suite module list are in
`cli/nagarectl/nagarectl.cabal`.

The replacement safety core is already in `cli/nagarectl/src/Nagare/Platform/Replacement.hs`, with
its executor in `Nagare.Platform.Cutover`, its minimal state-plan contract in
`Nagare.Platform.StateTransfer`, and its 14 deterministic tests in
`cli/nagarectl/test/PlatformCutoverSpec.hs`. Treat these as the current baseline, not as the final
EP-123 design.

`cli/nagarectl/src/Nagare/Platform/Paths.hs` and
`cli/nagarectl/src/Nagare/Platform/Workspace.hs` define context-owned paths and staged
payload workspaces. Replacement transactions must follow those ownership rules but store
their artifacts in a distinct `replacement-upgrades/<transaction-id>/` directory. A
transaction is the durable control record. A phase is one idempotent step. Evidence is a
typed, checksummed JSON artifact produced by a phase. A drift token is a digest over the
inputs that make rehearsal evidence valid, including the target payload, infrastructure
preview, state inventory, source data measurements, and candidate identity.

The budget is divided into three amounts: predicted forward downtime, rollback reserve,
and a safety margin. The transaction may become `ready` only when:

    predictedFinalTransferSeconds
      + predictedPublicVerificationSeconds
      + rollbackReserveSeconds
      + safetyMarginSeconds
      <= totalBudgetSeconds

The inequality is evaluated with integer seconds after each evidence update. A prediction
is the maximum observed rehearsal duration multiplied by a documented conservative factor,
not the latest sample alone. ExecPlan 126 supplies state-transfer evidence and ExecPlan 127
supplies address-handoff, verification, and rollback evidence.

Relevant local decisions are [ADR 0004](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
which separates immutable payloads from mutable context workspaces; [ADR 0005](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md),
which makes host flakes context-owned; [ADR 0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
which requires resumable upgrades and commits the context last; [ADR 0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md),
which confines cloud mutations to the selected project; [ADR 0011](../adr/0011-host-activation-is-guarded-and-self-reverting.md),
which establishes self-reverting host activation; [ADR 0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md),
which assigns mutable state to the context; [ADR 0014](../adr/0014-the-active-context-owns-the-vm-shape.md),
which guards VM replacement; and [ADR 0018](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md),
which requires phase recipe guards. ExecPlan 122 creates the additional local ADR for the
replacement topology after proving it. Mori registry and documentation searches found no
cross-repository ADR needed by this plan.


## Plan of Work

### Milestone 1: Pure transaction model and budget gate

Extend the existing `cli/nagarectl/src/Nagare/Platform/Replacement.hs`, which is already exposed
from `cli/nagarectl/nagarectl.cabal`. Reconcile its cutover phase vocabulary with the complete
preparation/evidence phase graph and define legal state
transitions, evidence references, drift token, and pure budget calculation. Do not import
Pulumi or process-running code into this module. Add `PlatformReplacementSpec` to the test
suite and test every legal transition, representative illegal transitions, boundary values
at exactly 15 minutes, insufficient rollback reserve, expired evidence, and changed drift
tokens. Keep `PlatformCutoverSpec` green and preserve existing version-1 stable tokens. This
milestone is complete when the model serializes deterministically and no state can reach `Ready`
without the required fresh evidence.

### Milestone 2: Atomic context-owned persistence

Extend `Nagare.Platform.Paths` with a replacement transaction root and strengthen the existing
same-directory temporary-file/rename persistence in `Nagare.Platform.Replacement`. Reject unknown future schema
versions with an actionable error; never silently coerce them. Store large evidence in
separate canonical JSON files under the transaction directory and put the SHA-256 digest and
relative path in the transaction. On resume, verify context, project, zone, target payload,
and evidence digests before trusting prior success. Tests use temporary directories and
cover a torn temporary file, missing evidence, digest mismatch, and a transaction copied to
another context. This milestone is complete when a process interruption cannot turn a
partly written record into a valid transaction.

### Milestone 3: Read-only planning and status commands

In `cli/nagarectl/app/Main.hs`, add the command group `platform replacement` with:

    nagarectl platform replacement plan --to VERSION [--downtime-budget DURATION] [--json]
    nagarectl platform replacement status TRANSACTION_ID [--json]

Use the existing context and payload resolvers, but do not call Pulumi, SSH, Kubernetes, or
GCP from `plan`. The default duration is `15m`; accept whole positive seconds or minutes and
render the normalized value in seconds. `plan` creates or reuses a transaction keyed by the
context and target payload. `status` renders human-readable phase and budget tables or the
stable JSON schema. Later ExecPlans add `prepare`, `rehearse`, `cutover`, `rollback`, and
`finalize` to this group. This milestone is complete when planning against a fixture context
causes no subprocess mutation and status explains every missing readiness condition.

### Milestone 4: Operator documentation and compatibility proof

Update `docs/user/upgrades.md` to distinguish in-place upgrades from replacement upgrades,
describe the planning/status commands, and state explicitly that a 15-minute request is
accepted only when measured evidence fits. Preserve all current in-place command examples.
If implementation settles a durable transaction rule not covered by the new replacement
ADR from ExecPlan 122, amend that ADR rather than creating a near-duplicate. Run focused and
full checks. This milestone is complete when old schema-v1 fixtures still decode and the
new command is documented without implying zero downtime.


## Concrete Steps

Run focused Cabal commands from `cli/nagarectl/` because this monorepo has no root
`cabal.project`; run the flake command from the repository root.

    nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct

Expected focused output includes:

    PlatformReplacement
      refuses readiness when rollback reserve does not fit: OK
      invalidates evidence after drift: OK
    All ... tests passed

Create a disposable fixture context using the existing test helpers, then run:

    cabal run nagarectl -- platform replacement plan --to 0.3.0 \
      --downtime-budget 15m --json
    cabal run nagarectl -- platform replacement status <transaction-id> --json

The first JSON object contains `"totalBudgetSeconds":900`, state `planning`, and an array of
blocking reasons. The second reads the same transaction and exits zero. Capture the context
directory before and after planning and verify that only the replacement transaction files
changed; no Pulumi state or kubeconfig changed.

Finally run:

    nix flake check --print-build-logs

Expected result: exit status 0, including the `nagarectl-test` suite.


## Validation and Acceptance

Acceptance requires all of the following observable behavior:

* Planning a replacement against a valid context creates schema version 1 of a
  `ReplacementTransaction`, records the resolved source and target identities, defaults the
  budget to 900 seconds, and performs no external mutation.
* Repeating the same plan command returns the existing nonterminal transaction rather than
  creating competing candidates. A different target requires the operator to finalize or
  abandon the old transaction explicitly.
* A transaction with all required evidence and a predicted total of exactly 900 seconds is
  ready; a total of 901 seconds is blocked with the amount by which it exceeds the budget.
* Missing, stale, digest-mismatched, or drift-invalidated evidence makes status non-ready and
  names the exact phase that must be repeated.
* Illegal transitions such as `planning` directly to `cutting-over`, or `complete` back to
  `rehearsing`, fail before an operation is invoked.
* Unknown transaction schema versions fail closed. Existing `UpgradeTransaction` schema-v1
  fixture tests and in-place upgrade commands continue to pass byte-for-byte where golden
  output exists.
* Human status output distinguishes expected service downtime, temporary candidate cost,
  and rollback eligibility. JSON output uses stable machine-readable tokens.


## Idempotence and Recovery

Model transitions are pure and may be retested without side effects. Writes use a sibling
temporary file, `fsync` where supported by the existing persistence helpers, and atomic
rename; an orphaned temporary file is ignored on the next read. Evidence files are
content-addressed and may be regenerated safely.

Planning is idempotent for `(context, target payload)`. A transaction in `planning`,
`rehearsing`, `ready`, or `failed` may be resumed after revalidating guards. `cutting-over`
and `rolling-back` are intentionally not auto-resumed by this plan; ExecPlan 127 defines
their reconciliation against real cloud state. Do not delete or rewrite an unknown schema
record to recover. Preserve it, report its path, and require a newer Nagare version or an
explicit operator recovery procedure.


## Interfaces and Dependencies

Use the repository's existing `aeson`, `bytestring`, `text`, `time`, `directory`, and
`filepath` dependencies. Use the project's existing digest helper where one exists; if no
shared SHA-256 helper exists, add one internal helper without adding a package. No cloud SDK
dependency is introduced here.

`Nagare.Platform.Replacement` must expose at least these conceptual interfaces; exact record
field syntax may follow existing lens conventions:

    data ReplacementState
      = Planning | Preparing | Rehearsing | Ready | CuttingOver
      | RollingBack | RolledBack | Committed | Finalizing | Complete
      | Abandoned | ReplacementFailed

    data ReplacementPhase
      = CandidatePlan | CandidateProvision | CandidateFence | CandidateBootstrap
      | StateSeed | CandidateVerify | CutoverReady | CandidateArm
      | Quiesce | StateFinalize | OldAddressDetach | CandidateAddressAttach
      | PublicVerify | ContextCommit | CandidateWriteAdmit | OldStop
      | RollbackRestore | Cleanup

    data DowntimeBudget = DowntimeBudget
      { totalSeconds :: Natural
      , rollbackReserveSeconds :: Natural
      , safetyMarginSeconds :: Natural
      }

    data EvidenceRef = EvidenceRef
      { kind :: EvidenceKind
      , relativePath :: FilePath
      , sha256 :: Text
      , observedAt :: UTCTime
      , validUntil :: UTCTime
      , driftToken :: Text
      }

    data Deadline = Deadline
      { hardStop :: MonotonicTime
      , rollbackAt :: MonotonicTime
      }

    readiness :: UTCTime -> ReplacementTransaction -> Readiness
    transition :: ReplacementEvent -> ReplacementTransaction
               -> Either ReplacementError ReplacementTransaction
    predictedDowntimeSeconds :: ReplacementTransaction -> Maybe Natural
    beginDeadline :: MonotonicTime -> DowntimeBudget -> Deadline
    writeReplacementTransaction :: FilePath -> ReplacementTransaction -> IO ()
    readReplacementTransaction :: FilePath -> IO (Either ReplacementError ReplacementTransaction)

`Readiness` contains the calculated forward estimate, rollback reserve, safety margin,
remaining headroom, and a nonempty list of blockers when not ready. The transaction also
records source and candidate `HostIdentity`, `ClusterIdentity`, project, zone, payload IDs,
infrastructure/state drift digests, and a phase record for each phase. JSON durations are
integer seconds and timestamps are UTC RFC 3339 strings. `Deadline` is constructed from an
injected monotonic time only when quiesce succeeds and is not serialized as if it were a UTC
timestamp. Persist the UTC start/deadline for audit; after a process/host restart, reconcile
conservatively and enter rollback if trustworthy remaining time cannot be established.

This plan owns the replacement schema consumed by ExecPlans 124 through 127. ExecPlan 122 is
a hard prerequisite because its address-handoff evidence determines whether
`AddressHandoff` is a valid phase at all. ExecPlan 124 must not add candidate fields outside
this schema; ExecPlans 125 and 126 attach evidence by `EvidenceRef`; ExecPlan 127 is the only
child plan that executes the deadline and terminal transitions.

The current version-1 records and types in `Nagare.Platform.Replacement` are the migration input to
this plan. Any incompatible field or token change requires an explicit schema migration and fixtures;
silently reusing schema version 1 for incompatible JSON is not acceptable.


Revision note (2026-09-15): Refreshed the plan against the early EP-127 replacement core and the
Nagare 0.3.0 reviewed-plan/receipt boundary, changing greenfield steps into compatibility-preserving
extension work while retaining EP-123 ownership of the complete model and read-only CLI.
