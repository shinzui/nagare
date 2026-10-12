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
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T03:37:06Z
      mode: "update"
      note: "Refreshed receipt storage, resume semantics, recovery workflow, and validation scope"
---

# Skip proven Pulumi apply work when resuming upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [143-skip-proven-pulumi-apply-work-when-resuming-upgrades.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/143-skip-proven-pulumi-apply-work-when-resuming-upgrades.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] (2026-09-16T03:44:37Z) Milestone 1: added durable, transaction-bound Pulumi apply receipts
  and a resume-decision model that can skip, run, or refuse a phase with evidence. The 47 focused
  platform tests pass, the executable builds, and the Haskell style check passes.
- [x] (2026-09-16T04:00:30Z) Milestone 2: wired automatic success/failure receipts,
  provider-free later-phase resume, legacy and ambiguous refusal, and both audited
  `recover-pulumi` outcomes through the installed CLI. The clone-free platform regression passes.
- [x] (2026-09-16T04:11:49Z) Milestone 3: added exact-count later-phase resume and foreign-receipt
  regressions, documented the recovery contract, amended ADRs 6 and 18, and passed the installed
  process-count check plus the complete native flake gate (568 Haskell tests and 25 flake checks).
- [x] (2026-09-16T03:36:10Z) Refreshed the plan against the current transaction runner, saved-plan
  bundle loader, CLI parser, test fixture, ADR corpus, and installed clone-free regression before
  implementation.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The repository's durable-write convention flushes and closes a same-directory
  temporary file before atomic rename, but it has no shared file- or directory-`fsync` helper.
  Evidence: `writeReplacementTransaction` in
  `cli/nagarectl/src/Nagare/Platform/Replacement.hs` uses `openBinaryTempFile`, `hFlush`, `hClose`,
  and `renameFile`; the current upgrade writer uses a weaker fixed `.tmp` name.

- Observation: `loadPlanBundle` already centralizes the reviewed Pulumi bundle's no-symlink,
  private-mode, exact-member, and JSON-schema checks, but digest checking currently lives inside
  `verifyReviewedPlanBundle` after `currentInfraIdentity` invokes `pulumi version` and reads mutable
  program/config inputs.
  Evidence: `cli/nagarectl/app/Main.hs` lines 3976-4044 in the refreshed tree. Receipt verification
  must reuse the local loader and digest checks without calling `currentInfraIdentity`.

- Observation: The original focused Cabal command was not runnable from the repository root because
  this monorepo has package-local `cabal.project` files rather than a root project file.
  Evidence: the root invocation reported `No cabal.project file or cabal file`, while
  `cd cli/nagarectl && nix develop ../.. -c cabal test nagarectl-test --test-options='--pattern Platform'`
  passed all 47 selected tests.

- Observation: Skipping the Pulumi phase alone did not make a later host resume provider-free,
  because `scripts/host-switch.sh` sources `scripts/lib/target.sh` and a local-backend target eagerly
  ran `pulumi stack select` during shell initialization.
  Evidence: the installed regression logged `pulumi ... stack select local` after an
  operator-attested skip and before the injected host failure. Upgrade apply now scopes
  `NAGARE_SKIP_PULUMI_STACK_SELECT=1` across the runner, and the same regression observes zero Pulumi
  commands before that host failure.

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

- Decision: Publish `pulumi-apply-receipt.json` beside the transaction's retained `pulumi-plan/`
  directory, using a unique same-directory temporary file, mode `0600`, flush/close, and atomic
  rename; keep the transaction JSON at schema version 1.
  Rationale: The transaction already owns a private directory named by its ID. This matches the
  repository's existing durable-write convention, avoids a colliding fixed temporary name, and
  adds evidence without making old transaction JSON unreadable. The repository has no established
  `fsync` abstraction to reuse, so this change does not invent a partial one solely for receipts.
  Date: 2026-09-15.

- Decision: Split saved-plan validation into local immutable-bundle validation and current-runtime
  identity validation. Receipt decisions use only the former; Pulumi execution and recovery use
  both.
  Rationale: A later-phase resume must prove that the retained plan bytes still match their private
  metadata without needing a Pulumi executable, credentials, mutable stack config, or a provider
  observation. A command that is about to run Pulumi or let an operator attest its outcome must
  still perform the stronger current-identity checks required by ADR 18.
  Date: 2026-09-15.

- Decision: Suppress `target.sh`'s eager local stack selection only while an upgrade apply runner is
  active; explicit Pulumi execution and the audited recovery command continue to initialize and
  verify the stack themselves.
  Rationale: Host and Kubernetes scripts source the shared target environment even though they do
  not own infrastructure state. Once a receipt proves Pulumi success, those later phases must not
  accidentally require a Pulumi binary or provider access, while ordinary interactive shells and
  commands that actually use Pulumi retain the existing selection behavior.
  Date: 2026-09-15.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The implementation meets the original provider-independence goal. Pulumi apply now leaves a
private, atomically replaced receipt bound to the transaction and retained reviewed-plan evidence.
A verified automatic or operator-attested success repairs or skips the journal without loading a
Pulumi executable, selecting a stack, reading credentials, or contacting the provider. Failures in
host apply, Kubernetes apply, cluster stamp, and context commit each preserve exactly one total
Pulumi invocation across resume. Completed transactions remain no-ops, and transaction JSON stays
at schema version 1.

The external-operation crash window remains intentionally visible rather than falsely solved. A
durable `started` receipt or a successful pre-receipt journal refuses normal resume until the
operator runs the guarded `recover-pulumi` command with `applied` or `retry`; conflicting recovery,
tampered or foreign bindings, and unsafe permissions refuse. ADRs 6 and 18 now own that durable
contract, while the upgrade guide and command reference describe the operational procedure.

Validation completed with all 47 focused platform tests, the packaged clone-free process-count
regression, documentation profile validation, shell syntax checks, Haskell formatting/style checks,
and `nix flake check --print-build-logs`. The native flake run passed all 568 Haskell tests and 25
checks; it reported `x86_64-linux` as an incompatible non-native system, as expected. No live-cloud
upgrade was performed because the hermetic installed regression supplies the required call-count
and crash-boundary evidence without mutating provider state.

