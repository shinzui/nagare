---
id: 93
slug: remote-gcs-pulumi-backends-for-target-contexts
title: "Remote GCS Pulumi backends for target contexts"
kind: exec-plan
created_at: 2026-07-01T00:55:02Z
intention: "intention_01kwdjzg86eyhvbkvgq64hd7zs"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
---

# Remote GCS Pulumi backends for target contexts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [93-remote-gcs-pulumi-backends-for-target-contexts.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

MasterPlan 17, `docs/masterplans/17-first-class-target-contexts-for-nagare.md`, makes
Nagare target selection context-aware: one checkout can hold many named targets, and
each target owns its Pulumi stack and config projection. Its Pulumi child plan,
`docs/plans/90-per-context-pulumi-state-and-config-projection.md`, deliberately keeps
state in per-context local file backends. That is the right base layer, because it
preserves today's single-operator behavior and avoids adding GCP credentials to local
mode or first-time onboarding.

This follow-up adds an **opt-in remote Pulumi state backend on Google Cloud Storage
(GCS)** for cloud contexts. A Pulumi backend is where Pulumi stores stack state: the
ledger it uses to know which cloud resources it owns. A GCS backend lets an operator use
the same context from multiple machines, recover from a lost laptop, and later run
infrastructure commands from CI without copying `~/.local/state` or a repository-local
state directory. The feature is explicit: local file state remains the default, local
mode never uses GCS, and a context switches to GCS only when it says so.

After this change, a cloud context can contain:

```bash
export NAGARE_PULUMI_BACKEND=gcs
export NAGARE_PULUMI_BACKEND_URL=gs://<project>-nagare-pulumi-state/nagare/<context>
```

When that context is active, `.envrc`, `scripts/lib/target.sh`, `nagarectl init`, the
justfile recipes, `scripts/upload-images.sh`, and `nagarectl` operations that read Pulumi
outputs all use that `gs://` backend and the context's stack name. A human can see it
working with `pulumi -C infra/pulumi whoami -v`, which reports the GCS backend URL, and
with `gcloud storage objects list`, which shows Pulumi's `.pulumi/stacks/`, `.pulumi/locks/`,
and `.pulumi/history/` objects under the context's backend path after a stack operation.

## Progress

Use this checklist to track the actual implementation state. Every stopping point must
be recorded here with the date and enough evidence for the next contributor to resume.

- [x] M0 (reconciled 2026-09-15): later live execution supplied stronger evidence than the
  proposed prototype. EP-116 migrated the 32-resource `tan-nb-exp` stack from local state to
  `gs://tan-nb-exp-nagare-pulumi-state/nagare/tan-nb-exp` using the shipped export/import script,
  matched outputs, and obtained `pulumi preview --refresh` with 31 unchanged. The independently
  initialized labs context selects stack `labs` at
  `gs://tan-ng-labs-nagare-pulumi-state/nagare/labs`; `pulumi stack output` returned its live
  `sshCommand`, `publicIp`, and `instanceName`. As corrected by M3, stack selection uses
  `NAGARE_PULUMI_STACK`/explicit `--stack`, not a `PULUMI_STACK` export.
- [x] M1 (2026-07-01): Extended the context schema with `NAGARE_PULUMI_BACKEND` and
  `NAGARE_PULUMI_BACKEND_URL`, defaulting to the EP-90 local file backend. Added
  `PulumiBackendKind`, `tpPulumiBackend`/`tpPulumiBackendUrl` on `TargetProfile`,
  `peKind` on `PulumiEnv`, backend-aware `pulumiEnvFor`, `defaultGcsPulumiBackendUrl`,
  `effectivePulumiBackend` (force-local in local mode), and the two `renderTargetEnv`
  lines. Shell resolver (`_NAGARE_CONTEXT_VARS`, defaults, local-mode downgrade+warn).
  Evidence: `cabal test` = 349 tests PASS (7 new); shell transcript shows a gcs cloud
  context deriving `gs://example-project-nagare-pulumi-state/nagare/gcs-lab`, a local
  context downgrading gcs→local with a warning, and the default context unchanged on the
  EP-90 `file://…/state` backend.
- [x] M2 (2026-07-01): Added GCS backend bootstrap in `Nagare.Ops.PulumiBackend` (pure
  `gcsBucketOfUrl`/`pulumiStateBucket`/`bucket*Args`/`bootstrapCommands` + idempotent
  `bootstrapPulumiStateBucket` runner: describe → create-if-missing → update → optional
  IAM grant, with a dry-run that prints the exact `gcloud storage` commands). `nagarectl
  init` and `nagarectl context create` accept `--pulumi-backend`, `--pulumi-backend-url`,
  and `--pulumi-backend-member`; the backend + URL persist to the context file, the member
  is bootstrap-only. Bootstrap is warn-not-fatal so a credential-less machine still writes
  the context. Evidence: 6 pure tests (355 total PASS); `nagarectl init --dry-run
  --pulumi-backend gcs` prints the create/update/IAM sequence in cloud mode and correctly
  emits nothing in local mode (downgraded).
- [x] M3 (2026-07-01): Made the backend derivation backend-aware inside EP-90's existing
  seam. `_nagare_export_pulumi_env` / `pulumiEnvFor` set `PULUMI_BACKEND_URL` to the
  `gs://` URL for a gcs context while `PULUMI_HOME` stays the per-context *local* home and
  `NAGARE_PULUMI_STACK` stays `<ctx>`. The eager `stack select` is skipped for gcs both in
  the shell (`.envrc` guard) and — no signature change — every caller inherits the ambient
  env. `Main.hs:ensurePulumiForContext` now takes the `TargetProfile`, guards the local
  state-dir `mkdir` behind `PulumiBackendLocal` (fixing a latent `file://`-strip bug on
  `gs://` URLs), and all four call sites pass the profile. Remaining under M3: live
  two-context verification against a real GCS bucket (deferred to manual validation).
- [x] M4 (2026-07-01): Added `scripts/migrate-pulumi-backend.sh` (a repository script, per
  the plan's "or a repository script" option). Forward: verify mode=cloud + guardrail,
  export the local stack with `pulumi stack export --show-secrets --file` to a timestamped
  `${state}/nagare/<ctx>/pulumi-migrations/pre-gcs-<stamp>.json`, bootstrap the bucket,
  `stack init`+`stack import --file` into GCS, verify `baseDomain`/`backupBucket` outputs
  match, and flip the context file to `NAGARE_PULUMI_BACKEND=gcs` only on success.
  `--rollback` re-imports the latest artifact into the local backend and flips back, never
  deleting the GCS bucket/objects. Idempotent (already-gcs is a no-op; local backend kept).
  Evidence: `bash -n` clean; `--help` works; local-mode context is refused. Forward/rollback
  require live pulumi+gcloud+GCP (manual validation).
- [x] M5 (2026-07-01): Documentation + MasterPlan updated. Added a "Remote GCS Pulumi state"
  section to `docs/user/contexts.md` (backend fields, bootstrap, IAM, `PULUMI_HOME`-stays-local,
  local-mode downgrade, offline-fast, and the migration/rollback commands) and a state-backend
  subsection to `docs/user/provisioning-with-pulumi.md`. Reconciled the rest of `docs/user`:
  `reference.md` (the two new context vars, the `init`/`context create` flags, and a backend
  note on the Pulumi-state section), `backups-and-disaster-recovery.md` (the stale "until remote
  state lands" lines now describe the shipped GCS option), and `getting-started.md` (the
  file-backend claim now notes the gcs alternative). All four link to the contexts.md anchor.
  Ticked EP-93 in MasterPlan 17 (registry row → Complete, progress line, Outcomes, Revision Notes).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Research note: Pulumi's official DIY backend docs say a backend URL may be
  `gs://<bucket-path>` for Google Cloud Storage, and that DIY backends store metadata
  under a `.pulumi` directory containing active stacks, lock files, and history. They
  also state that DIY backends require the operator to manage access control and backups.
  The current Pulumi CLI environment-variable docs state that `PULUMI_BACKEND_URL`
  selects a backend, and that stack priority is `--stack`, then `PULUMI_STACK`, then the
  stack selected with `pulumi stack select`.
- Research note: Pulumi's state migration docs explicitly recommend `pulumi stack export`
  and `pulumi stack import` for moving stacks between backends because stack state
  contains backend-specific information. Therefore this plan must not migrate by copying
  `.pulumi/stacks/*.json` objects or files.

- Validation (2026-07-01), against the shipped EP-90 code (EP-90 is Complete). Four drifts
  between this plan's first draft and what EP-90 actually delivered were found and
  corrected in this revision:
  1. **No `PULUMI_STACK` export.** EP-90's `scripts/lib/target.sh:_nagare_export_pulumi_env`
     exports `NAGARE_PULUMI_STACK=<ctx>` and calls `_nagare_select_pulumi_stack`
     (`pulumi -C infra/pulumi stack select <ctx> || stack init`), persisting the selection
     in the per-context `PULUMI_HOME`. Nothing exports `PULUMI_STACK`. The draft's
     shell-resolver acceptance test printed `$PULUMI_STACK` and would have printed an empty
     line against the real code; it now checks `$NAGARE_PULUMI_STACK`.
  2. **The Haskell producer already exists under different names.** EP-90 shipped
     `data PulumiEnv { peHome, peBackendUrl, peStack }` and
     `pulumiEnvFor :: FilePath -> Text -> PulumiEnv` in `Nagare/Target.hs`, applied once in
     `app/Main.hs` (~line 1977). The draft proposed a parallel `PulumiBackend`/
     `pulumiBackendFor`; per this plan's own "one producer" rule, EP-93 now extends
     `PulumiEnv`/`pulumiEnvFor` with a `peKind` instead.
  3. **`.envrc` orientation was stale.** The draft said `.envrc` "still exports
     `PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"`" and that EP-90 "is expected to" replace
     it. EP-90 already did: `target.sh` owns the per-context export; `.envrc` sources it and
     re-runs `_nagare_select_pulumi_stack` after `use flake`.
  4. **`seedPulumiConfig`/`pulumiConfigSetArgs` already take a stack.** They are
     `seedPulumiConfig :: Bool -> Text -> TargetProfile -> IO …` and
     `pulumiConfigSetArgs :: Text -> Text -> Text -> [String]` (threading `--stack`), so the
     projection is already stack-scoped; EP-93 need only add the two rendered fields via
     `renderTargetEnv`.

- Validation insight (2026-07-01): the eager stack select is a real GCS hazard.
  `_nagare_export_pulumi_env` runs on **every** `source scripts/lib/target.sh` (every
  `direnv reload`, every script run). For a `file://` backend that is a cheap local
  no-op; for a `gs://` backend it would attempt a credentialed network round-trip to GCS on
  every shell entry, breaking offline shells and slowing every `cd`. M3 must make the eager
  `_nagare_select_pulumi_stack` skip or stay best-effort for gcs contexts and defer the
  authoritative select/init to `nagarectl` operations and bootstrap. Also: `PULUMI_HOME`
  must remain the per-context *local* directory even for gcs (Pulumi keeps its workspace and
  credentials there); only `PULUMI_BACKEND_URL` becomes `gs://`.

- Live reconciliation (2026-09-15): EP-116 recorded the exact export/import migration that M0
  deferred, including the encrypted rollback artifact, output comparison, backend flip, and a
  clean 31-unchanged refresh preview. A second context in
  `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use` independently
  proves that direct GCS initialization, context selection, and stack-output reads survive across
  a released workspace. No throwaway migration is needed now that both production-shaped paths
  have observable evidence.

## Decision Log

Record every decision made while working on the plan.

- Decision: GCS Pulumi state is **opt-in per cloud context**, not the default.
  Rationale: MasterPlan 17's core promise is backward-compatible target contexts. EP-90's
  local file backend is simpler, works offline for local mode, and preserves existing
  single-operator behavior. Remote state solves a real recovery and multi-machine problem,
  but it requires GCP storage, IAM, and network access, so it belongs behind an explicit
  context field.
  Date: 2026-07-01

- Decision: represent backend choice with two context fields:
  `NAGARE_PULUMI_BACKEND=local|gcs` and `NAGARE_PULUMI_BACKEND_URL=<url>`.
  Rationale: the flat `export VAR=value` context schema is the shared contract between
  Haskell and bash from EP-87/EP-89. A backend kind is easy to validate, while an explicit
  URL allows operators to use an existing bucket or a custom path. When the kind is `gcs`
  and the URL is absent, Nagare derives `gs://<project>-nagare-pulumi-state/nagare/<context>`.
  Date: 2026-07-01

- Decision: keep Pulumi state separate from application backup buckets.
  Rationale: the backup bucket stores user workload and database data managed by Nagare.
  Pulumi state is operator control-plane metadata and may contain resource attributes and
  encrypted secrets. A distinct bucket, defaulting to `<project>-nagare-pulumi-state`,
  makes IAM, lifecycle policy, recovery, and accidental deletion boundaries clearer.
  Date: 2026-07-01

- Decision: do not declare the Pulumi state bucket inside `infra/pulumi/index.ts`.
  Rationale: Pulumi must be able to reach its backend before it can run the program that
  would create resources. The state bucket is a bootstrap prerequisite, like enabling the
  Storage API and authenticating with GCP. It belongs in `nagarectl init` / context
  bootstrap code, not in the main Pulumi stack whose state it stores.
  Date: 2026-07-01

- Decision: migrate state with `pulumi stack export --show-secrets --file` and
  `pulumi stack import --file`, never by copying backend files or GCS objects.
  Rationale: Pulumi's own docs describe export/import as the supported cross-backend
  migration mechanism. It preserves Pulumi's backend-specific state translations and gives
  an auditable rollback artifact.
  Date: 2026-07-01

- Decision: extend EP-90's shipped `PulumiEnv` / `pulumiEnvFor` /
  `_nagare_export_pulumi_env` and keep EP-90's `NAGARE_PULUMI_STACK` + `pulumi stack select`
  targeting; do **not** introduce a `PulumiBackend`/`pulumiBackendFor` type or a
  `PULUMI_STACK` export.
  Rationale: EP-90 is Complete and already provides the single Haskell/shell producer of the
  Pulumi backend environment. This plan's own Interfaces section mandates one producer, and
  the MasterPlan-17 integration point requires GCS to *extend* EP-90's local default, not
  fork it. Reconciling the draft (written against pre-completion assumptions) with the
  as-shipped names avoids a parallel, divergent derivation.
  Date: 2026-07-01

- Decision: for gcs contexts, `PULUMI_HOME` stays the per-context local directory and the
  per-shell eager `stack select` is made skip/best-effort; the authoritative select/init is
  deferred to `nagarectl` operations and bootstrap.
  Rationale: `_nagare_export_pulumi_env` runs on every shell source. An eager `stack select`
  against `gs://` would require GCP credentials + network on every `direnv reload`,
  defeating offline use and adding latency; Pulumi's local workspace/creds cache belongs in
  a local `PULUMI_HOME` regardless of backend.
  Date: 2026-07-01

- Decision: implement the M4 migration as the repository script
  `scripts/migrate-pulumi-backend.sh`, not a `nagarectl context` subcommand.
  Rationale: the migration is procedural orchestration of `pulumi stack export/import` and
  `gcloud storage` with no pure/unit-testable core, and it must run with explicit,
  hand-controlled backend-env overrides mid-flight (export from `file://`, import to
  `gs://`). A script keeps that sequencing legible and reviewable, matches the existing
  `scripts/*.sh` style (it sources `scripts/lib/target.sh` and reuses `_require_target_project`),
  and avoids threading a large imperative flow through optparse. The plan's M4 explicitly
  allowed "a `nagarectl context` subcommand or a repository script." Date: 2026-07-01

- Decision: this plan is a follow-up whose deps are already satisfied — EP-90 (hard) and
  EP-88/EP-89/EP-92 (soft) are all Complete, and MasterPlan 17's EP-93 wiring (registry row,
  Integration Point 5 addendum, dependency graph, decision log, revision note) is internally
  consistent and consistent with this plan's scope. No MasterPlan change is required by this
  validation pass.
  Rationale: The validation the owner requested confirmed the MasterPlan additions are
  sound; the only corrections needed were inside EP-93 itself, reconciling it with
  EP-90-as-shipped.
  Date: 2026-07-01

- Decision: close the M0 prototype with later live evidence from EP-116 and the labs context.
  Rationale: the prototype existed to de-risk backend selection and export/import before real use.
  EP-116 exercised the shipped implementation on a real 32-resource stack, while labs proves the
  fresh-GCS path. Re-running a weaker throwaway experiment would add no acceptance coverage.
  Date: 2026-09-15

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-93 is implemented and marked Complete in MasterPlan 17. The opt-in GCS Pulumi backend
landed as a clean extension of EP-90 rather than a fork, exactly as the validation pass
required:

- **Purpose met.** A cloud context can set `NAGARE_PULUMI_BACKEND=gcs` (with an optional
  explicit URL) and its Pulumi state lives in `gs://<project>-nagare-pulumi-state/nagare/<context>`.
  Local file state stays the default and the only local-mode option; a local context that asks
  for gcs is downgraded with a warning. A second machine/operator can share a context's state,
  and `scripts/migrate-pulumi-backend.sh` moves a context between backends with export/import.
- **One producer, not two.** The backend choice is a single field threaded through the
  shipped `PulumiEnv`/`pulumiEnvFor` (Haskell) and `_nagare_export_pulumi_env` (bash); no
  parallel derivation was introduced, and `NAGARE_PULUMI_STACK` + `stack select` (never
  `PULUMI_STACK`) remained the stack-targeting mechanism.
- **Two design refinements over the draft** (both from validation): `PULUMI_HOME` stays local
  for gcs (only the URL changes), and the per-shell eager `stack select` is skipped for gcs so
  offline shells don't hit GCS on every `direnv reload`. A latent `file://`-strip bug in
  `ensurePulumiForContext` (which would have mangled a `gs://` URL into a local path) was fixed
  as part of threading the profile through.
- **Verification.** `cabal test` = 355 tests pass (13 new across Target/Init and the new
  `Nagare.Ops.PulumiBackend`). Shell transcripts confirm gcs URL derivation, local-mode
  downgrade+warn, and unchanged default behavior. `nagarectl init --dry-run --pulumi-backend gcs`
  prints the exact idempotent `gcloud storage` bootstrap sequence. The migration script is
  `bash -n` clean with a working cloud-only guardrail.
- **Live gap closed later.** EP-116 created the versioned `tan-nb-exp` state bucket and migrated
  the live stack through `pulumi stack export`/`import`; outputs matched and refresh preview showed
  31 unchanged. The fresh labs rollout independently initialized and operated a second GCS-backed
  stack. The original implementation session itself mutated no GCP resource, but the deferred
  acceptance now has durable downstream evidence.

Lesson: validating a follow-up plan against the *shipped* dependency (not its plan text)
before writing code paid off — the `PULUMI_STACK`-vs-`NAGARE_PULUMI_STACK` and
`PulumiEnv`-vs-`PulumiBackend` reconciliations would otherwise have produced a divergent
second derivation that the MasterPlan's "one producer" rule forbids.

