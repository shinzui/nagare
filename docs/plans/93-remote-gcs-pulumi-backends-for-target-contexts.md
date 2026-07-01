---
id: 93
slug: remote-gcs-pulumi-backends-for-target-contexts
title: "Remote GCS Pulumi backends for target contexts"
kind: exec-plan
created_at: 2026-07-01T00:55:02Z
intention: "intention_01kwdjzg86eyhvbkvgq64hd7zs"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# Remote GCS Pulumi backends for target contexts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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

- [ ] M0: Prototype the Pulumi CLI behavior against a temporary local file backend and,
  if credentials are available, a throwaway GCS path. Confirm that `PULUMI_BACKEND_URL`
  selects the backend, `PULUMI_STACK` selects the stack, and `pulumi stack export` /
  `pulumi stack import` migrate a stack between backends without hand-copying state
  files. Record the transcript in Surprises & Discoveries.
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
- [ ] M4: Add a documented migration path from an EP-90 local per-context backend to GCS.
  The implementation exports state from the local backend with `pulumi stack export
  --show-secrets --file`, imports it into the GCS backend with `pulumi stack import
  --file`, verifies stack outputs, and leaves the local export as a rollback artifact.
- [ ] M5: Update operator documentation and MasterPlan 17 notes. Document when to use
  GCS, the bootstrap bucket naming scheme, required IAM, migration and rollback, and the
  fact that GCS state is a follow-up to EP-90 rather than a replacement for local file
  state.


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

- Decision: this plan is a follow-up whose deps are already satisfied — EP-90 (hard) and
  EP-88/EP-89/EP-92 (soft) are all Complete, and MasterPlan 17's EP-93 wiring (registry row,
  Integration Point 5 addendum, dependency graph, decision log, revision note) is internally
  consistent and consistent with this plan's scope. No MasterPlan change is required by this
  validation pass.
  Rationale: The validation the owner requested confirmed the MasterPlan additions are
  sound; the only corrections needed were inside EP-93 itself, reconciling it with
  EP-90-as-shipped.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section before editing. It repeats the relevant repository context so the plan
can be implemented without relying on memory.

Nagare is a personal PaaS. Its cloud perimeter is declared by a Pulumi TypeScript program
under `infra/pulumi/`. The Pulumi project file is `infra/pulumi/Pulumi.yaml`; the main
program is `infra/pulumi/index.ts`; the user-facing provisioning guide is
`docs/user/provisioning-with-pulumi.md`. The Pulumi outputs such as `publicIp`,
`baseDomain`, `backupBucket`, and `artifactRegistry` are an integration contract consumed
by shell recipes and Haskell commands.

The context model is owned by MasterPlan 17 and its completed child plans:
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` defines a context
as a flat `export VAR=value` file under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, plus a current-context
pointer file at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context`.
`docs/plans/88-nagarectl-context-command-group-and-context-selection.md` adds the
`nagarectl context` command group and global `--context` selection.
`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`
makes `.envrc` and `scripts/lib/target.sh` resolve the same active context in bash.

The Pulumi local-state layer is owned by `docs/plans/90-per-context-pulumi-state-and-config-projection.md`.
This EP-93 plan hard-depends on EP-90. **EP-90 is Complete as of 2026-07-01** — do not
re-plan it; extend what it shipped. EP-90's delivered behavior is: each context maps to
stack `<context>`; local file state lives under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/{state,home}`; and
`infra/pulumi/Pulumi.dev.yaml` is untracked (the working tree may still hold it and stray
`Pulumi.ep90-*.yaml` prototype files, but `git ls-files infra/pulumi/` lists no
`Pulumi.<stack>.yaml`). This plan adds an alternate backend kind. It must not reintroduce
a tracked `infra/pulumi/Pulumi.dev.yaml` or a single shared `dev` stack.

The shipped shell resolver is `scripts/lib/target.sh`. It exports `NAGARE_CONTEXT` as the
resolved active context name (`"default"` for the back-compatible in-repo/default case),
snapshots the per-field env overrides in `_NAGARE_CONTEXT_VARS`, and — this is the part
EP-93 extends — its `_nagare_export_pulumi_env` function derives the per-context Pulumi
environment and exports it. **As shipped it exports `PULUMI_HOME`, `PULUMI_BACKEND_URL`
(a `file://…/nagare/<ctx>/state` URL), `PULUMI_CONFIG_PASSPHRASE`,
`PULUMI_CONFIG_PASSPHRASE_FILE`, and `NAGARE_PULUMI_STACK=<ctx>` — and then calls
`_nagare_select_pulumi_stack`, which runs `pulumi -C infra/pulumi stack select <ctx>`
(falling back to `stack init`) so the selection persists in the per-context
`PULUMI_HOME`.** It does **not** export `PULUMI_STACK`; stack targeting is done by
selection, not by that variable. `.envrc` sources `target.sh` (which runs
`_nagare_export_pulumi_env`), then re-runs `_nagare_select_pulumi_stack` after `use flake`
puts `pulumi` on `PATH`. EP-93 must therefore change *what backend URL is derived* and
*whether the eager stack select runs*, not introduce a parallel `PULUMI_STACK` contract.

The Haskell resolver is `cli/nagarectl/src/Nagare/Target.hs`. It defines
`TargetProfile`, `ContextName`, `mkContextName`, `contextNameText`, context file helpers,
`parseContextEnv`, `profileFromContextMap`, and `resolveActiveContext`. EP-90 added the
single Haskell producer of the Pulumi environment here: `nagareStateDir :: IO FilePath`,
`data PulumiEnv = PulumiEnv { peHome :: FilePath, peBackendUrl :: Text, peStack :: Text }`,
and the pure `pulumiEnvFor :: FilePath -> Text -> PulumiEnv` (state root + context name →
env; today it hard-codes `peBackendUrl = "file://" <> root </> "state"`). Context files are
rendered from `cli/nagarectl/src/Nagare/Init.hs` through `renderTargetEnv`; the Pulumi
config projection is seeded by `seedPulumiConfig :: Bool -> Text -> TargetProfile -> IO …`
(the `Text` is the stack) via `pulumiConfigSetArgs :: Text -> Text -> Text -> [String]`
(which already threads `--stack`). `cli/nagarectl/app/Main.hs` applies `pulumiEnvFor` to the
resolved active context around line 1977 — `setEnv` for `PULUMI_HOME`, `PULUMI_BACKEND_URL`,
`PULUMI_CONFIG_PASSPHRASE`, `PULUMI_CONFIG_PASSPHRASE_FILE`, and `NAGARE_PULUMI_STACK` — and
wires the `nagarectl context` commands. EP-93 extends `PulumiEnv`/`pulumiEnvFor` and that
one application block; it does not add a second derivation.

All direct Pulumi calls were already routed through the ambient environment by EP-90, so
none names the backend or stack on the command line — changing the exported
`PULUMI_BACKEND_URL` is transparent to every caller. The known call sites to keep verified
are the justfile recipes `infra-up`, `infra-preview`, and `cluster-bootstrap`
(`pulumi -C infra/pulumi stack output baseDomain`); `scripts/upload-images.sh`, which
reads `imageBucket` and writes `nagareImageSelfLink` via `pulumi --cwd infra/pulumi
config get/set`; `scripts/live-smoke.sh` (`pulumi stack output publicIp`);
`cli/nagarectl/src/Nagare/Ops/Pulumi.hs`, whose `stackOutput` shells out to
`pulumi -C infra/pulumi stack output <name>` and relies on the ambient selected stack; and
the printed (non-executed) remediation strings in `cli/nagarectl/src/Nagare/Ops/Doctor.hs`.


## Plan of Work

Milestone 0 is a short prototype. In a temporary directory, create a minimal Pulumi
project or reuse `infra/pulumi` with a throwaway `XDG_CONFIG_HOME` and `XDG_STATE_HOME`.
Set `PULUMI_BACKEND_URL=file://<tmp>/state-a` and `PULUMI_STACK=ctx-a`, initialize a stack,
then change only `PULUMI_BACKEND_URL` and prove Pulumi sees an independent backend. If
GCP credentials are available and the operator permits a live bucket, repeat with a
throwaway `gs://` backend path. Record the commands and transcript in Surprises &
Discoveries. Acceptance for M0 is not a production bucket; it is confidence that the
environment variables behave exactly as this plan assumes.

Milestone 1 extends the context contract. In `cli/nagarectl/src/Nagare/Target.hs`, add a
small type such as `PulumiBackendKind = PulumiBackendLocal | PulumiBackendGcs`, add a
`peKind :: PulumiBackendKind` field to the existing `PulumiEnv` record, and extend the
existing pure `pulumiEnvFor` (rather than adding a parallel function) so it takes the
resolved backend choice and returns the `gs://` `peBackendUrl` for a gcs context while
keeping `peHome` local and `peStack = ctx`. Add pure helpers that parse
`NAGARE_PULUMI_BACKEND`, validate `NAGARE_PULUMI_BACKEND_URL`, and derive the default GCS
URL for a cloud context (`defaultGcsPulumiBackendUrl`). In
`cli/nagarectl/src/Nagare/Init.hs`, teach `renderTargetEnv` to write the two new fields.
In `scripts/lib/target.sh`, add `NAGARE_PULUMI_BACKEND` and `NAGARE_PULUMI_BACKEND_URL` to
the `_NAGARE_CONTEXT_VARS` snapshot list (so per-field env overrides survive context
sourcing), and extend `_nagare_export_pulumi_env` to branch on the backend kind: for
`gcs`, set `PULUMI_BACKEND_URL` to the `gs://` URL and keep the local `PULUMI_HOME`; for
`local`, keep EP-90's `file://…/state` URL. `NAGARE_PULUMI_STACK` stays `<ctx>` in both
cases; do **not** introduce a `PULUMI_STACK` export. The default must remain `local` for
existing context files. Acceptance is unit and shell coverage proving old context files
still resolve, a GCS context derives the expected URL, and a local-mode context rejects or
ignores `NAGARE_PULUMI_BACKEND=gcs`.

Milestone 2 adds bucket bootstrap. Extend `nagarectl init` and `nagarectl context create`
with flags equivalent to `--pulumi-backend local|gcs`, `--pulumi-backend-url <gs://...>`,
and optionally `--pulumi-backend-member <principal>`. The exact option names can be
adjusted to match EP-88's parser style, but they must be explicit and test-covered. When
GCS is selected, bootstrap must ensure the target project has a state bucket before any
Pulumi command uses it. Use `gcloud storage buckets describe gs://<bucket>` to detect an
existing bucket; if missing, run:

```bash
gcloud storage buckets create gs://<bucket> \
  --project=<project> \
  --location=<region> \
  --uniform-bucket-level-access \
  --public-access-prevention
```

Then run an idempotent update:

```bash
gcloud storage buckets update gs://<bucket> \
  --versioning \
  --uniform-bucket-level-access \
  --public-access-prevention
```

If a principal is supplied for CI or another operator, grant it bucket-scoped object
access:

```bash
gcloud storage buckets add-iam-policy-binding gs://<bucket> \
  --member=<principal> \
  --role=roles/storage.objectAdmin
```

Acceptance is a dry-run mode that prints these exact commands, plus pure tests for bucket
name/path derivation and validation. A live validation can be performed manually against
a real GCP project, but the automated suite must not require creating a real bucket.

Milestone 3 keeps every Pulumi caller correct through EP-90's existing ambient-environment
seam — no caller is re-wired. EP-90 already established the style: the resolver exports
`PULUMI_BACKEND_URL`/`PULUMI_HOME`/`NAGARE_PULUMI_STACK` and calls
`pulumi stack select <ctx>` so the selection persists in the per-context `PULUMI_HOME`;
callers then run bare `pulumi` and inherit both. EP-93 keeps `PULUMI_HOME` a per-context
*local* cache/config directory (Pulumi's workspace and credentials live there even for a
gcs backend), keeps `PULUMI_CONFIG_PASSPHRASE`/`PULUMI_CONFIG_PASSPHRASE_FILE` behavior
unchanged, and only redirects `PULUMI_BACKEND_URL` to the `gs://` URL for gcs contexts.
`just infra-up` stays `cd infra/pulumi && pulumi up`; it works because direnv has already
exported the right backend and selected the stack. `scripts/upload-images.sh` keeps calling
`pulumi --cwd "${PULUMI_DIR}" config get imageBucket` and
`pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink ...`; those land in the
context's stack because the ambient backend + selected stack are the context's.
`Nagare.Ops.Pulumi.stackOutput` continues to inherit the environment and the ambiently
selected stack — matching EP-90; do not add a `--stack` flag or a `PULUMI_STACK` export.
The one genuinely new decision is the eager `stack select`: against a `gs://` backend,
running `_nagare_select_pulumi_stack` on *every* shell source would hit GCS (credentials +
network) on each `direnv reload`. M3 must make the eager select skip or best-effort for gcs
contexts (it already runs under `|| true`, but should not block or slow an offline shell),
deferring the authoritative `stack select`/`init` to `nagarectl` operations and bootstrap.
Acceptance is a two-context dry-run test showing each context reads/writes a different stack
config and backend URL, and that entering a gcs context offline does not error.

Milestone 4 implements migration and rollback. Add either a `nagarectl context` subcommand
or a repository script, following EP-88's style, that migrates one context from EP-90's
local file backend to GCS. The command must:

1. Resolve the context and verify it is `mode=cloud`.
2. Export the current local stack to a timestamped file under
   `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/pulumi-migrations/`.
3. Bootstrap the GCS bucket if needed.
4. Switch only the Pulumi backend environment to the GCS URL, initialize/select the same
   stack name, and import the exported state.
5. Run `pulumi -C infra/pulumi stack output` for at least `baseDomain` and `backupBucket`
   and compare them to the pre-migration values.
6. Update the context file to `NAGARE_PULUMI_BACKEND=gcs` and
   `NAGARE_PULUMI_BACKEND_URL=<url>` only after verification succeeds.

Rollback is the inverse: set the context back to `local`, select the local backend, and
import the saved export file. The rollback must not delete the GCS bucket or objects.

Milestone 5 updates documentation and the MasterPlan. Update
`docs/user/provisioning-with-pulumi.md` and the context documentation owned by EP-92
(if it exists by then) with the backend choices, GCS bootstrap commands, IAM requirements,
and migration/rollback instructions. Amend `docs/masterplans/17-first-class-target-contexts-for-nagare.md`
so it remains truthful: remote GCS backend support was out of scope for the original
EP-90 delivery but is now tracked as follow-up EP-93 after EP-90.


## Concrete Steps

From the repository root (`/Users/shinzui/Keikaku/bokuno/nagare`), begin by confirming
the baseline and the dependencies:

```bash
mori show --full
mori registry search pulumi
sed -n '1,360p' docs/masterplans/17-first-class-target-contexts-for-nagare.md
sed -n '1,360p' docs/plans/90-per-context-pulumi-state-and-config-projection.md
```

Run the M0 prototype in a temporary directory, not in the real state directory. Use
commands shaped like this, adapting only the temporary paths:

```bash
tmp="$(mktemp -d)"
export PULUMI_HOME="$tmp/home-a"
export PULUMI_BACKEND_URL="file://$tmp/state-a"
export PULUMI_STACK="ctx-a"
pulumi -C infra/pulumi stack init ctx-a --non-interactive || pulumi -C infra/pulumi stack select ctx-a
pulumi -C infra/pulumi whoami -v
pulumi -C infra/pulumi stack ls
```

Expected evidence:

```text
Backend URL: file://.../state-a
NAME   LAST UPDATE  RESOURCE COUNT
* ctx-a ...
```

After M1 and M2, run the Haskell tests:

```bash
cd cli/nagarectl
cabal test
```

Expected evidence:

```text
Test suite nagarectl-test: PASS
```

Run shell resolver tests or add an explicit temporary-store shell transcript if the repo
does not yet have a shell test harness:

```bash
tmp="$(mktemp -d)"
mkdir -p "$tmp/config/nagare/contexts"
cat > "$tmp/config/nagare/contexts/gcs-lab.env" <<'EOF'
export CLOUDSDK_CORE_PROJECT=example-project
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export NAGARE_BASE_DOMAIN=apps.example.test
export NAGARE_MODE=cloud
export NAGARE_PULUMI_BACKEND=gcs
EOF
XDG_CONFIG_HOME="$tmp/config" NAGARE_CONTEXT=gcs-lab bash -lc 'source scripts/lib/target.sh && printf "%s\n%s\n%s\n" "$PULUMI_BACKEND_URL" "$NAGARE_PULUMI_STACK" "$NAGARE_PULUMI_BACKEND"'
```

Expected evidence:

```text
gs://example-project-nagare-pulumi-state/nagare/gcs-lab
gcs-lab
gcs
```

For a live GCS validation, only run the following after confirming the target project and
cost implications:

```bash
nagarectl context use <context>
pulumi -C infra/pulumi whoami -v
pulumi -C infra/pulumi stack output baseDomain
gcloud storage objects list gs://<project>-nagare-pulumi-state/nagare/<context>/.pulumi/ --recursive --project=<project>
```

Expected evidence:

```text
Backend URL: gs://<project>-nagare-pulumi-state/nagare/<context>
<base-domain-from-the-context>
gs://<project>-nagare-pulumi-state/nagare/<context>/.pulumi/meta.yaml
gs://<project>-nagare-pulumi-state/nagare/<context>/.pulumi/stacks/...
```


## Validation and Acceptance

The implementation is accepted when all of these behaviors are true.

Existing contexts that do not mention Pulumi backend fields still use EP-90's local file
backend, with the same stack name and config projection as before. This proves backward
compatibility.

A cloud context with `NAGARE_PULUMI_BACKEND=gcs` and no explicit URL derives
`gs://<project>-nagare-pulumi-state/nagare/<context>`, bootstraps that bucket
idempotently, exports `PULUMI_BACKEND_URL` to that URL, sets `NAGARE_PULUMI_STACK=<context>`
and selects that stack, and makes `pulumi -C infra/pulumi whoami -v` report that backend.

A local-mode context cannot silently use GCS. Either the resolver forces
`NAGARE_PULUMI_BACKEND=local` in local mode or it fails with a clear error such as:

```text
nagare: local contexts cannot use NAGARE_PULUMI_BACKEND=gcs
```

Migration from local to GCS preserves stack outputs. Before and after migration,
`pulumi -C infra/pulumi stack output baseDomain` and `pulumi -C infra/pulumi stack output
backupBucket` return the same values for the context. The migration leaves a timestamped
export file that can be imported back into the local backend.

The normal command surface does not change for operators who are not using remote state.
`just infra-preview`, `just infra-up`, `just host-image`, `nagarectl server status`, and
`nagarectl doctor` continue to work from the active context without requiring a new flag.

Run these commands before marking the plan complete:

```bash
cd cli/nagarectl && cabal test
bash -n scripts/lib/target.sh
just infra-preview
```

If `just infra-preview` would touch a real GCP project and the operator does not want
that live check, record the reason in Outcomes & Retrospective and run an equivalent
dry-run or temporary-backend Pulumi preview instead.


## Idempotence and Recovery

Bucket bootstrap must be idempotent. If the bucket already exists, the implementation
updates versioning, uniform bucket-level access, and public access prevention to the
desired settings. If the bucket exists in a different project and GCP reports a name
collision, fail with a clear message telling the operator to pass
`NAGARE_PULUMI_BACKEND_URL` or the equivalent CLI flag with a different bucket name.

Do not lock a GCS retention policy in this plan. GCS retention locks are intentionally
hard to undo and can make development cleanup painful. Versioning is enough for the first
remote-state pass; retention policy can be a later hardening plan.

State migration must write an export file before it changes the context file. If import
to GCS fails, leave the context on `local` and print the export path. If verification
fails after import, leave both backends intact and require the operator to choose whether
to retry, roll back, or inspect the imported stack.

Never delete the old local backend automatically. The local backend is a rollback source
and a useful audit artifact. Document manual cleanup only after a successful GCS migration
and a successful `pulumi preview` or `pulumi up` on the GCS backend.


## Interfaces and Dependencies

This plan depends on the context contract from EP-87, the CLI command group from EP-88,
the shell resolver from EP-89, and the per-context local Pulumi state/config projection
from EP-90. Implement EP-90 first.

EP-90 already shipped the single Haskell producer of the Pulumi environment in
`cli/nagarectl/src/Nagare/Target.hs`:

```haskell
data PulumiEnv = PulumiEnv
  { peHome :: FilePath
  , peBackendUrl :: Text
  , peStack :: Text
  }

pulumiEnvFor :: FilePath -> Text -> PulumiEnv   -- stateRoot -> ctx -> env (file:// only today)
nagareStateDir :: IO FilePath
```

**Extend these — do not add a parallel `PulumiBackend`/`pulumiBackendFor`.** Add a backend
kind and thread it through the existing record and function:

```haskell
data PulumiBackendKind = PulumiBackendLocal | PulumiBackendGcs

-- extend the existing record with the kind
data PulumiEnv = PulumiEnv
  { peHome :: FilePath          -- stays local even for gcs (Pulumi workspace + creds cache)
  , peBackendUrl :: Text        -- "file://…/state" for local, "gs://…" for gcs
  , peStack :: Text
  , peKind :: PulumiBackendKind
  }

-- extend the existing pure function to be backend-aware
pulumiEnvFor :: FilePath -> Text -> PulumiBackendKind -> Maybe Text -> PulumiEnv
defaultGcsPulumiBackendUrl :: Text -> TargetProfile -> Text   -- ctx + profile -> gs:// URL
```

The `Main.hs` application block around line 1977 (which already `setEnv`s `PULUMI_HOME`,
`PULUMI_BACKEND_URL`, `PULUMI_CONFIG_PASSPHRASE`, `PULUMI_CONFIG_PASSPHRASE_FILE`, and
`NAGARE_PULUMI_STACK` from `pulumiEnvFor`) is the one place that consumes the extended
value. There must remain exactly one Haskell producer of the Pulumi backend environment,
not separate derivations in multiple modules.

Extend context rendering in `cli/nagarectl/src/Nagare/Init.hs` so generated context files
include:

```bash
export NAGARE_PULUMI_BACKEND=local
export NAGARE_PULUMI_BACKEND_URL=
```

for the default local case, and `gcs` plus a `gs://` URL for a GCS-enabled context.

Extend `scripts/lib/target.sh`'s existing `_nagare_export_pulumi_env` (do not add a second
exporter) so the shell contract matches the Haskell one:

```bash
export NAGARE_PULUMI_BACKEND="${NAGARE_PULUMI_BACKEND:-local}"
export NAGARE_PULUMI_BACKEND_URL="${NAGARE_PULUMI_BACKEND_URL:-...derived when gcs...}"
# EP-90 already exports these; EP-93 only changes how PULUMI_BACKEND_URL is derived:
export PULUMI_HOME="${...per-context LOCAL home path (unchanged, even for gcs)...}"
export PULUMI_BACKEND_URL="${...file://…/state for local, ${NAGARE_PULUMI_BACKEND_URL} for gcs...}"
export NAGARE_PULUMI_STACK="${NAGARE_CONTEXT}"   # EP-90 name; do NOT switch to PULUMI_STACK
```

For `local`, `PULUMI_BACKEND_URL` is the EP-90 `file://…/nagare/<ctx>/state` URL. For
`gcs`, it is the `gs://` URL, while `PULUMI_HOME` stays the local per-context home. Stack
targeting stays EP-90's `NAGARE_PULUMI_STACK` + `pulumi stack select` (guarded/deferred for
gcs, per M3), never a `PULUMI_STACK` export. Keep `PULUMI_CONFIG_PASSPHRASE` /
`PULUMI_CONFIG_PASSPHRASE_FILE` as EP-90 established them.

Use the existing project toolchain: Haskell (`cabal`) for `nagarectl`, bash for
`scripts/lib/target.sh` and bootstrap scripts, Pulumi CLI for stack operations, and
`gcloud storage` for GCS bucket creation and IAM. No new TypeScript dependency is needed
for `infra/pulumi`, because the state bucket is intentionally outside the Pulumi program
whose state it stores.


## Revision Notes

- 2026-07-01 (validation pass) — Validated this plan against the **shipped** EP-90 code
  (EP-87 through EP-92 are all Complete) and reconciled the draft, which had been written
  against pre-completion assumptions. Changes:
  - **Context and Orientation** rewritten to describe EP-90 as delivered: `target.sh`'s
    `_nagare_export_pulumi_env` exports `PULUMI_HOME`/`PULUMI_BACKEND_URL`/
    `PULUMI_CONFIG_PASSPHRASE`/`PULUMI_CONFIG_PASSPHRASE_FILE`/`NAGARE_PULUMI_STACK` and runs
    `pulumi stack select` (no `PULUMI_STACK`); the Haskell producer is the shipped
    `PulumiEnv`/`pulumiEnvFor`/`nagareStateDir`, applied once in `app/Main.hs` (~line 1977);
    `seedPulumiConfig`/`pulumiConfigSetArgs` already take the stack; `.envrc` no longer sets
    `$PWD/infra/pulumi/.pulumi-home`.
  - **Progress M3, Plan of Work M1/M3, Concrete Steps, and Interfaces** updated to extend
    `PulumiEnv`/`pulumiEnvFor` (adding `peKind`) instead of a parallel `PulumiBackend`, to
    add the two new fields to `_NAGARE_CONTEXT_VARS`, and to keep `NAGARE_PULUMI_STACK` +
    `stack select` (removing every `PULUMI_STACK` reference). The shell-resolver test now
    checks `$NAGARE_PULUMI_STACK`.
  - Added a **new M3 concern and Decision**: the eager per-shell `stack select` must be
    skipped/best-effort for gcs backends (it would hit GCS on every `direnv reload`), and
    `PULUMI_HOME` stays local for gcs.
  - Recorded the validation findings in Surprises & Discoveries and the reconciliation
    decisions in the Decision Log.
  - Confirmed MasterPlan 17's EP-93 wiring (registry row, Integration Point 5 addendum,
    dependency graph, decision log, revision note) is internally consistent and consistent
    with this plan; **no MasterPlan edit was required.**
  Planning only; no source or config was modified.
