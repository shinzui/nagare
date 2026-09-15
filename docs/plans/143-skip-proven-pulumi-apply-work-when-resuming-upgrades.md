---
id: 143
slug: skip-proven-pulumi-apply-work-when-resuming-upgrades
title: "Skip proven Pulumi apply work when resuming upgrades"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp3698e4182nkgpabaw3gp"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
---

# Skip proven Pulumi apply work when resuming upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a reviewed Pulumi infrastructure phase succeeds and a later host or Kubernetes phase fails,
`nagarectl platform upgrade --apply --resume` continues from the later failure without contacting
Pulumi again. A private receipt binds the success to the exact transaction, context, stack, payload,
and reviewed plan, so skipping is evidence-based rather than a blind trust in a phase label. The
current repeated-provider behavior is recorded in
[BUG-4](../bug-reports/upgrade-resume-reapplies-successful-pulumi-phase.md).

The observable proof injects failures independently into host apply, Kubernetes apply, cluster
stamp, and context commit. In every case the first run makes exactly one `pulumi up` call, the
transaction records its receipt, and all later resumes make zero additional Pulumi calls while
eventually completing. If the process dies during the unobservable instant between starting Pulumi
and durably recording its result, resume refuses and offers an explicit audited recovery command
instead of guessing whether to rerun cloud mutations.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add durable, transaction-bound Pulumi apply receipts and a resume-decision model
  that can skip, run, or refuse a phase with evidence.
- [ ] Milestone 2: wire normal success, later-phase resumes, legacy transactions, and ambiguous crash
  recovery through the upgrade CLI.
- [ ] Milestone 3: add exhaustive failure/resume regressions, document the recovery contract, amend
  the upgrade ADRs, and pass focused plus full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the transaction journal's `pulumi-apply: succeeded` record as necessary but not
  sufficient; skip only when a separate success receipt verifies against the retained reviewed-plan
  bundle and transaction bindings.
  Rationale: The current phase label proves that the generic runner once received success, but its
  free-text evidence is truncated and not structured enough to prove which plan was consumed. A
  small receipt can bind the exact plan/review digests and identities without querying the provider
  again during a later-phase recovery.
  Date: 2026-09-15.

- Decision: Write a `started` receipt atomically before `pulumi up`, replace it atomically with a
  `succeeded` or `failed` receipt after the process returns, and save the ordinary phase journal as
  the next step.
  Rationale: This distinguishes a never-entered phase and a known failed process from a process that
  may have changed cloud state before the CLI died. No local protocol can eliminate the last crash
  window around an external provider, but it can expose that ambiguity instead of silently rerunning.
  Date: 2026-09-15.

- Decision: Add `platform upgrade recover-pulumi TRANSACTION --outcome applied|retry --yes` for an
  ambiguous or pre-receipt transaction; do not make a normal resume flag double as acknowledgement.
  Rationale: Recovery changes what future automation is allowed to infer and must be a deliberate,
  separately auditable operator action. `applied` records an operator-attested success after showing
  the reviewed binding and current stack observations; `retry` records permission to run the exact
  retained plan again. Neither mode invents automatic proof.
  Date: 2026-09-15.

- Decision: Keep receipts as private files at a derived path inside the transaction directory and
  retain upgrade transaction schema compatibility.
  Rationale: A receipt is operational evidence, not a new phase or desired-state field. Deriving its
  location from the transaction and validating its own schema, permissions, and bindings lets old
  transaction JSON remain readable; old successes without receipts enter explicit recovery rather
  than being misclassified.
  Date: 2026-09-15.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

An upgrade transaction is JSON under the selected context's XDG state directory.
`cli/nagarectl/src/Nagare/Platform/Upgrade.hs` defines ordered apply phases `PulumiApply`,
`HostApply`, `KubernetesApply`, `ClusterStamp`, and `ContextCommit`. `runPhases` saves a successful
phase after its operation returns. On resume it skips a recorded success only if the operational
`upgradePhaseSatisfied` callback returns `True`; otherwise it reruns the phase.

`cli/nagarectl/app/Main.hs` constructs that callback in `upgradeOps`. `phaseSatisfied PulumiApply`
is currently `pure False`, so every resume after a later failure verifies and invokes the retained
Pulumi plan again. The live report observed 33 unchanged resources twice. Host and context phases
already have observable postconditions; Kubernetes apply is deliberately convergent but currently
reruns. This plan changes only Pulumi's evidence and the generic decision surface needed to express
an ambiguous result.

The reviewed infrastructure plan lives in `<transaction>/pulumi-plan/`.
`cli/nagarectl/src/Nagare/Infra/Plan.hs` defines `SavedPlanMetadata`, whose bindings include context,
project, stack, backend, payload ID/digest, Pulumi program/config digests, Pulumi version, and the
SHA-256 digests of `pulumi-plan.json` and `review.json`. `verifyReviewedPlanBundle` in
`cli/nagarectl/app/Main.hs` validates private file modes, exact bundle members, current bindings,
digests, and protected-replacement acknowledgement before `applyReviewedPlan` calls `pulumi up
--plan ... --yes --non-interactive`. Reuse those decoded saved bindings and digests in the receipt;
do not store provider output or secrets.

`cli/nagarectl/test/PlatformSpec.hs` has pure transaction tests, including one where an injected host
failure resumes with a synthetic `PulumiApply` postcondition. However, the production callback is
not exercised and the failure-at-every-phase test deliberately uses an always-false postcondition,
so it masks BUG-4. `nix/checks/scripts/nagare-clone-free-platform.sh` supplies recording fake Pulumi,
Nix, gcloud, and Kubernetes tools and is the right installed-command boundary for exact process-call
counts.

[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) says each
successful phase is persisted and resume rechecks a postcondition before skipping it.
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds apply
to the retained reviewed Pulumi plan and describes partial-provider recovery. Preserve both rules
and amend them with the durable receipt/ambiguity contract. No cross-repository ADR governs this
fix. The live evidence originates at
`mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.


## Plan of Work

Milestone 1 adds structured evidence and resume semantics. In
`cli/nagarectl/src/Nagare/Platform/Upgrade.hs`, replace the Boolean-only resume callback with a
decision type that can say run, skip with evidence, or refuse with a diagnostic. On resume, ask for
a decision for each recorded-success phase and for `PulumiApply` when a receipt indicates the
process was entered even if the journal was not finalized. A skip recovered from a receipt must
persist `PulumiApply` as succeeded before moving on; a refusal must preserve the transaction and
must not invoke the phase. Keep completed transactions no-ops.

Add a focused module such as `cli/nagarectl/src/Nagare/Platform/PulumiReceipt.hs`. Its versioned JSON
record contains transaction ID, context, target version, payload ID/digest, saved-plan and review
digests, project, stack, backend, Pulumi version, state (`started`, `succeeded`, `failed`, or
`operator-attested`), timestamp, and optional recovery outcome. Write mode `0600` through a
same-directory temporary file, `fsync` as supported by existing repository conventions, then atomic
rename. Validate that the receipt is a regular non-symlink private file and that every binding
matches the transaction and retained plan metadata. Add round-trip, tamper, stale-binding, and state
transition tests. This milestone is accepted when the pure runner skips only a verified success,
recovers a success receipt that beat the phase journal, and refuses a `started` receipt with no
known outcome.

Milestone 2 wires the real Pulumi boundary and explicit recovery. Refactor `applyReviewedPlan` just
enough to make its verified `CurrentInfraIdentity` and saved-plan metadata/digests available to the
upgrade caller without weakening the standalone `nagarectl infra apply` path. In the upgrade
`PulumiApply` branch, atomically persist `started`, invoke the exact retained plan once, persist
`failed` on a known nonzero/launch error or `succeeded` on exit zero, and only then return to the
generic journal writer. The production resume callback verifies a `succeeded` receipt entirely from
private local transaction evidence and skips without running `pulumi version`, stack probes, plan
verification against mutable current config, or any provider command. Later phases cannot change
the reviewed Pulumi inputs, and a changed plan bundle must fail receipt verification.

Extend the upgrade command parser and handler in `cli/nagarectl/app/Main.hs` with `recover-pulumi`.
It is available only for a selected non-completed transaction whose Pulumi outcome is ambiguous or
whose old successful journal predates receipts. It re-runs the normal platform, ADC, project,
transaction, bundle-security, and stack-identity reads, prints the transaction and reviewed plan
bindings plus current Pulumi stack observations, and requires `--yes`. Outcome `applied` writes an
operator-attested success receipt and records the recovery decision in phase evidence; outcome
`retry` writes an explicit retry authorization that causes the next normal resume to enter
`PulumiApply` once and replace the receipt with the automatic result. Never infer `applied` from an
empty preview. This milestone is accepted when normal later-phase resumes need no Pulumi executable
or credentials, while ambiguous and legacy cases cannot proceed without the separate recovery
record.

Milestone 3 makes every boundary observable. Expand `cli/nagarectl/test/PlatformSpec.hs` so failures
in each of `HostApply`, `KubernetesApply`, `ClusterStamp`, and `ContextCommit` leave one successful
Pulumi receipt and every resume makes no new Pulumi call. Cover a crash after the `started` write, a
success receipt before journal persistence, a known Pulumi failure, tampered/foreign receipts,
legacy succeeded phases without receipts, both audited recovery outcomes, repeated resume, and a
completed no-op. Extend the installed clone-free fixture to count `preview`, `up`, `version`, and
config/stack probes separately and prove later recovery is provider-independent. Update
`docs/user/upgrades.md`, `docs/user/reference.md`, `[Unreleased]` in `CHANGELOG.md`, and ADRs 6 and 18
with the receipt and crash-window contract. Record final evidence in Outcomes & Retrospective.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/nagare` and inspect the current transaction and plan
interfaces before editing:

```bash
git status --short
sed -n '30,280p' cli/nagarectl/src/Nagare/Platform/Upgrade.hs
sed -n '2960,3060p' cli/nagarectl/app/Main.hs
sed -n '3450,3640p' cli/nagarectl/app/Main.hs
sed -n '230,330p' cli/nagarectl/test/PlatformSpec.hs
```

After each Haskell milestone, format and run the focused package tests:

```bash
nix develop -c fourmolu -i cli/nagarectl/src/Nagare/Platform/Upgrade.hs cli/nagarectl/src/Nagare/Platform/PulumiReceipt.hs cli/nagarectl/app/Main.hs cli/nagarectl/test/PlatformSpec.hs
nix develop -c cabal test nagarectl-test --test-options='--pattern Platform'
nix develop -c ./scripts/check-haskell-style.sh
```

Run the installed regression and inspect the fake tool log. For each injected later failure, the
expected count is:

```text
first apply:  pulumi up = 1
first resume: pulumi up = 0, pulumi version = 0, pulumi config/stack = 0
all resumes:  total pulumi up = 1
final state:  completed
```

Then run:

```bash
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nagare-clone-free-platform
just user-documentation-validate
nix flake check --print-build-logs
```

Every implementation commit must be a Conventional Commit and include:

```text
ExecPlan: docs/plans/143-skip-proven-pulumi-apply-work-when-resuming-upgrades.md
```


## Validation and Acceptance

Plan one cloud upgrade with a recording Pulumi double and apply it four times, injecting the first
failure separately at host apply, Kubernetes apply, cluster stamp, and context commit. Each scenario
must retain the same reviewed-plan bundle, make exactly one total `pulumi up --plan` call across all
attempts, perform no Pulumi executable or provider probe during later resumes, complete the remaining
phases in order, and preserve context commit as the final write. The receipt and journal must name
the same transaction, context, target, payload, stack/backend, and plan/review digests.

Kill or inject failure after writing `started` but before writing a result. A normal resume must exit
nonzero before Pulumi or later phases, show the ambiguity and exact `recover-pulumi` command, and
leave the old context pin. A success receipt written before journal persistence must instead repair
the journal and continue without Pulumi. A recorded nonzero Pulumi result may rerun the unchanged
retained plan on explicit normal resume under ADR 18. A legacy 0.3.0 transaction with a succeeded
free-text phase but no receipt must require audited recovery, not silently rerun.

Tampering with the receipt, plan, review, metadata, transaction identity, or private file mode must
refuse. `recover-pulumi --outcome applied` and `--outcome retry` must both require current context and
project guards, display the reviewed bindings, require `--yes`, and append durable recovery evidence.
All focused Haskell tests, installed process-count regression, documentation validation, and native
flake checks must pass.


## Idempotence and Recovery

Receipt writes are atomic and replace only the fixed private file inside one transaction. Re-reading
a verified success is idempotent and makes no external call. Reapplying a completed transaction
remains a no-op. A known Pulumi failure retains the unchanged reviewed bundle and may be retried
according to ADR 18; a changed binding requires a new upgrade plan.

A `started` receipt with no result is intentionally a hard stop because the provider may have
changed state. The operator inspects the selected Pulumi stack and chooses the explicit recovery
outcome. `applied` allows later phases without rerunning cloud updates; `retry` allows exactly the
next normal resume to consume the retained plan. Repeating the same recovery decision is a no-op;
attempting to reverse an established automatic success or choose conflicting outcomes refuses. Do
not delete receipts as a recovery technique, and never make rollback infer that Pulumi resources
were reversed.


## Interfaces and Dependencies

`Nagare.Platform.Upgrade` should replace the Boolean callback with an explicit result similar to:

```haskell
data ResumeDecision
  = RunPhase
  | SkipPhase !Text
  | RefusePhase !Text

data UpgradeOps = UpgradeOps
  { runUpgradePhase :: UpgradePhase -> IO (Either Text Text)
  , upgradeResumeDecision :: UpgradePhase -> PhaseState -> IO ResumeDecision
  , saveUpgradeTransaction :: UpgradeTransaction -> IO ()
  , upgradeNow :: IO Text
  }
```

The exact signature may avoid overloaded record-label conflicts, but it must let the generic runner
persist evidence when a receipt recovers a phase and refuse without invoking it when the result is
ambiguous. `Nagare.Platform.PulumiReceipt` should expose constructors/parsers and operations
equivalent to `writeStartedReceipt`, `writeResultReceipt`, and `verifySuccessReceipt`, all taking the
current `UpgradeTransaction` plus decoded `SavedPlanMetadata`/digests. Keep provider process
execution in `Main.hs`/the existing infra operations, and reuse Aeson, cryptonite SHA-256, POSIX mode
checks, and atomic filesystem helpers already present. No new external library or service is needed.
