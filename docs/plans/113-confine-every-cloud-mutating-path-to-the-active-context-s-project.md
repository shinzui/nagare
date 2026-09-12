---
id: 113
slug: confine-every-cloud-mutating-path-to-the-active-context-s-project
title: "Confine every cloud-mutating path to the active context's project"
kind: exec-plan
created_at: 2026-09-12T14:08:28Z
intention: "intention_01m2az59r0ejqtvw1mgvhe4d7f"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T14:08:28Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T14:37:24Z
      mode: "implement"
      note: "Implementing EP-113 milestones 1-6"
---

# Confine every cloud-mutating path to the active context's project

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare is a single-operator Platform-as-a-Service. An operator picks one Google Cloud
project, and Nagare creates a virtual machine, a small Kubernetes cluster, some storage
buckets and a container registry inside it. Which project that is comes from the **active
target context** — a small file of `export VAR=value` lines under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, selected with
`nagarectl context use <name>`, the `NAGARE_CONTEXT` environment variable, or a
`--context` flag. The repository's operating rules in [`CLAUDE.md`](../../CLAUDE.md)
state the promise plainly: no script, command, or instruction may act on a project other
than the active context's, and the check must **fail closed** — refuse rather than guess.

Today that promise is kept on most paths and broken on four. Each break is reachable from
an ordinary command typed in an ordinary shell; none requires the operator to do anything
that looks reckless. The worst of them is concrete: an operator whose `gcloud` command-line
tool is still configured to point at a production project, who runs the auth-plane image
build without a Nagare context loaded, submits a Cloud Build job **into that production
project**, because the script reads the project from `gcloud config get-value project`
rather than from the context.

After this change, an operator can have a production project selected in `gcloud config`,
run any Nagare command from any directory with a context active, and be certain that no
create, update or delete lands outside that context's project — and that when the
configuration is ambiguous the command stops and says so rather than choosing for them.
Concretely, after implementation:

- Running `scripts/upload-images.sh` or `nagarectl init` when the image bucket or the
  Pulumi state bucket name is already taken by a bucket in *someone else's* project prints
  `refusing: gs://<bucket> is owned by project number …, not the target project …` and
  exits non-zero, instead of quietly reconfiguring or writing into that foreign bucket.
- Running `cluster/bootstrap/auth-images/build-local-image.sh shomei` with a context whose
  project disagrees with the ambient environment prints
  `refusing to run: effective project '…' does not match the active context's declared
  project '…'` and exits non-zero, instead of building into whatever `gcloud config` names.
- Running `just infra-up` (or the installed `nagare infra-up`) when the selected Pulumi
  stack's `gcp:project` disagrees with the active context prints a refusal naming both
  values and exits non-zero, before Pulumi is invoked at all.
- Running `nagare infra-preview` from a directory with no `.envrc` and no source checkout
  uses the active context's Pulumi state and stack, exactly as a `direnv`-loaded checkout
  does.

The work is defensive and observable: every one of those refusals is proven by an automated
test that fails before the change and passes after it.


## Progress

- [x] M1 (2026-09-12): added `_require_bucket_in_target_project` to `scripts/lib/target.sh`;
      `scripts/migrate-pulumi-backend.sh` now calls it instead of carrying its own copy;
      `scripts/upload-images.sh` calls it after the create-if-missing block and again inside
      `upload_if_missing`; `scripts/test-bucket-ownership-guard.sh` added and registered in
      `flake.nix` as the `bucket-ownership-guard` check. All four cases pass and
      `nix build .#checks.aarch64-darwin.bucket-ownership-guard` succeeds.
- [x] M2 (2026-09-12): `Nagare.Ops.PulumiBackend` gained `bucketProjectNumberArgs`,
      `projectNumberArgs`, `bucketOwnershipVerdict`, the injectable `GcloudOps` seam,
      `realGcloudOps` and `bootstrapPulumiStateBucketWith`; `runBootstrap` asserts
      ownership between create-if-missing and update; `bootstrapCommands` shows the two
      reads in the dry run; `bootstrapGcsIfNeeded` in `cli/nagarectl/app/Main.hs` is now
      fatal. Fourteen cases in the `Nagare.Ops.PulumiBackend (EP-93, EP-113)` group pass,
      including the three behavioral cases that assert on the recorded `gcloud` argv.
- [x] M3 (2026-09-12): both `cluster/bootstrap/auth-images/build-local-image.sh` and
      `cluster/bootstrap/nagare-access/build-image.sh` source `scripts/lib/target.sh`,
      take the project only from the resolved context, and call
      `_require_target_project` before every cloud mutation; the
      `gcloud config get-value project` fallback is gone from both (the only remaining
      matches under `cluster/` are the comments explaining its absence);
      `shellcheck-scripts` now lints both; `scripts/test-image-build-guard.sh` is added
      and registered as the `image-build-guard` check. All three cases pass, and case one
      fails when the change is stashed.
- [x] M4 (2026-09-12): new module `cli/nagarectl/src/Nagare/Ops/ContextGuard.hs` holds
      `ProjectGuardInputs`, `projectGuardVerdict` and `renderProjectGuard`;
      `nagarectl context guard [--json]` is wired into the context subparser and
      `runContextGuard` in `cli/nagarectl/app/Main.hs`; `infra-up` and `infra-preview` in
      `justfile` run it before Pulumi. Eight unit cases in the
      `Nagare.Ops.ContextGuard (EP-113)` group pass, and the
      `nagare-clone-free-platform` check now drives the guard twice through a fake
      `pulumi config get gcp:project`, expecting acceptance then refusal.
- [x] M5 (2026-09-12): `renderContextShellEnv` added to
      `cli/nagarectl/src/Nagare/Target.hs` with shell-safe single quoting;
      `nagarectl context env` added to the context subparser; the `nagare` launcher in
      `nix/haskell-packages.nix` evaluates it (its build-time shellcheck accepted the
      `eval` unmodified); `scripts/rehearse-clone-free-release.sh` asserts the stack,
      backend URL and project in `nagarectl context env` output and that the recipe plan
      contains the guard, and records `context-env` in its `checks` array. Three unit
      cases pass, including a single-quote round-trip through `bash -c`.
      The command is `nagarectl context env`, not `--export`: the plan named a flag in
      Progress that its own Milestone 5 body and Interfaces section never define, and the
      subcommand prints nothing but `export` lines, so a flag would have no other mode to
      select against.
- [x] M6 (2026-09-12): `docs/user/gcp-prerequisites.md` gained a "What keeps Nagare inside
      your project" section; `docs/user/contexts.md` documents `context guard` and
      `context env` with their exact refusal messages; `docs/user/provisioning-with-pulumi.md`
      documents the `infra-up` / `infra-preview` preflight and what to do when it refuses;
      `docs/user/log.md` has the `okf log add` entry and `just docs-validate` passes;
      `docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md` is
      written; `docs/plan-registry.md` has the EP-113 row. IR-2 was already accepted and
      linked to this plan in commit `2cc6f12`, before implementation began, so that step
      needed no change.
- [ ] Follow-up, outside EP-113: the `docs/improvement-requests` bundle fails strict
      profile validation for all four September-2026 IRs (missing the recommended `reviews`
      field). See Surprises & Discoveries; it predates this plan and must not be closed by
      writing review records that did not happen.


## Surprises & Discoveries

**The `nagarectl-test` suite has eight pre-existing failures in this working tree, all in
`AppDeploySpec`, and they are unrelated to this plan.** They come from the fixture compile
in `cli/nagarectl/test/AppDeploySpec.hs`, which invokes GHC over
`test/fixtures/app/kizashi/Config.hs` and finds two versions of the `nagare-dsl` package in
the local Cabal store:

```text
test/fixtures/app/kizashi/Config.hs:18:1: error: [GHC-45102]
    Ambiguous module name 'Nagare.Dsl.Application'.
    it was found in multiple packages:
    nagare-dsl-0.1.0 nagare-dsl-0.1.0.0
```

Confirmed pre-existing by stashing every change this plan makes to `cli/nagarectl` and
re-running the same case, which still fails. The sandboxed `nix flake check` derivations
build against a pinned package set and are unaffected. Verify this plan's Haskell work with
`cabal test nagarectl-test --test-options='-p "PulumiBackend"'` (and the equivalent filter
for the other groups) rather than reading the whole-suite tally, and do not attempt to
"fix" those eight as part of EP-113 — the remedy is a store cleanup outside this plan's
scope. (2026-09-12)

**The `docs/improvement-requests` bundle does not pass strict profile validation, and that
predates this plan.** The plan's Milestone 6 acceptance names this command:

```bash
okf validate docs/improvement-requests --strict \
  --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

It exits 1, identically before and after every change here:

```text
profile: confine-cloud-mutations-to-context-project: missing profile-recommended field: reviews (Chronological human or model review provenance for this document revision.)
profile: context-owned-acme-identity: missing profile-recommended field: reviews (...)
profile: data-disk-grow-procedure: missing profile-recommended field: reviews (...)
profile: seed-vm-shape-keys-at-init: missing profile-recommended field: reviews (...)
```

All four September-2026 improvement requests are affected equally, including the three
(IR-3, IR-4, IR-5) accepted before this plan started. Verified by stashing every change in
this working tree and re-running the same command, which produces byte-identical output.
The repository's own gate, `just docs-validate`, covers `docs/reviews`, `docs/user` and
`docs/guides` and does **not** include this bundle, so nothing in CI was failing; the plan
simply cited a command stricter than the gate.

This is deliberately left open rather than made to pass. `reviews` records who reviewed a
document and when; satisfying the validator would mean writing review provenance for
reviews that did not happen. Adding the field honestly is separate work covering all four
requests at once. (2026-09-12)


## Decision Log

- Decision: The bucket-ownership assertion is implemented **twice** — once as a Bash
  function in `scripts/lib/target.sh` and once in Haskell in
  `cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs` — rather than having the Haskell code
  shell out to the Bash helper.
  Rationale: IR-2 asks for "a single shared helper". A single *implementation* would mean
  `nagarectl` spawning `bash scripts/lib/target.sh` from the resolved platform payload on
  every bootstrap. That adds a failure mode (payload resolution, `bash` on `PATH`, argument
  quoting) to a guardrail whose entire value is that it cannot fail open, it makes the
  Haskell path untestable without a shell, and it produces error messages the Haskell caller
  cannot shape. What must be shared is the *contract*: the same two `gcloud` reads, the same
  comparison, the same refusal semantics, and the same message wording. Both implementations
  are tested against that contract, and the ADR written in M6 records it so a future change
  updates both. See "Interfaces and Dependencies" for the exact shared contract.
  Date: 2026-09-12.

- Decision: The state-bucket bootstrap failure becomes **fatal**, rather than leaving
  `nagarectl init` succeeding with the backend unconfigured.
  Rationale: IR-2 offers both. Fatal is simpler to reason about and to test, and the blast
  radius is small: `bootstrapPulumiStateBucket` is a no-op for every context whose Pulumi
  backend is `local`, which is the default, so only a context that explicitly opted into
  `NAGARE_PULUMI_BACKEND=gcs` can reach the failure at all. A partially-applied bootstrap
  that lets `init` report success is exactly the state that hides a foreign-bucket refusal
  from the operator.
  Date: 2026-09-12.

- Decision: The `infra-up` / `infra-preview` preflight is a **new `nagarectl context guard`
  subcommand**, not an extension of `nagarectl platform guard`.
  Rationale: `platform guard` answers one question — are the CLI, payload, context, host and
  cluster release versions compatible? (`cli/nagarectl/src/Nagare/Platform/Status.hs`,
  `guardPlatformMutation`.) Project confinement is an orthogonal question with a different
  failure mode and a different remedy. Keeping them separate keeps each command's output
  honest about what it checked, and lets a recipe request one, the other, or both. The two
  are composed in the `justfile`, which is where the recipe's full preflight belongs.
  Date: 2026-09-12.

- Decision: The `nagare` launcher exports the resolved context's Pulumi environment
  (IR-2's first option), and `infra-up` / `infra-preview` *additionally* run the new guard
  (IR-2's separate bullet).
  Rationale: IR-2 presents "launcher exports" and "each recipe resolves the context itself"
  as alternatives for the launcher gap, and asks for the recipe preflight separately. Doing
  the launcher export fixes every Pulumi-invoking recipe uniformly and restores parity with
  `direnv`; doing the guard as well means a wrongly-configured shell still refuses instead
  of proceeding on a bad environment. Neither alone gives both properties.
  Date: 2026-09-12.

- Decision: `_require_target_project` in `scripts/lib/target.sh` is **not modified**.
  Rationale: IR-2 explicitly identifies it as the pattern that works and worth preserving
  as-is, in particular its cross-check with `env -u CLOUDSDK_CORE_PROJECT gcloud config
  get-value project`, which stops the environment from shadowing the check into a tautology.
  This plan adds new call sites and a new sibling function; it changes no existing
  comparison.
  Date: 2026-09-12.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository.

### The vocabulary

A **target context** (or just "context") is a named file of `export VAR=value` lines that
says which Google Cloud project, region and zone Nagare should act on, plus the derived
names it uses (registry host, bucket names, base domain, VM instance name). Contexts live
in `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`. Which one is active is
decided by, in order: the `--context` flag, the `NAGARE_CONTEXT` environment variable, the
pointer file `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context`, an in-repository
`nagare.target.env` / `nagare.local.env` compatibility profile, and finally built-in
defaults that reproduce the original `tan-nb-exp` / `us-west1` / `us-west1-a` setup.

A context has a **mode**: `cloud` (the real GCP target) or `local` (a loopback substitute —
a `k3d` Kubernetes cluster, a `localhost` container registry, MinIO instead of Google Cloud
Storage). Local mode has no GCP project to protect, so the project guardrail deliberately
steps aside there after asserting that the local target really is loopback. Everything this
plan adds must preserve that: **local mode must never start requiring a GCP project**, and
must never invoke `gcloud`.

The **guardrail** is the Bash function `_require_target_project` in
`scripts/lib/target.sh` (defined at `scripts/lib/target.sh:276`, the file is 330 lines).
A script that talks to GCP sources `scripts/lib/target.sh` and calls this function once, at
the top. In cloud mode it refuses to continue unless the effective project agrees with the
project the active context *declares*; when no context declares one, it cross-checks
`gcloud`'s own configured project, read with `env -u CLOUDSDK_CORE_PROJECT` so that the
environment cannot make the check compare a value against itself. In local mode it instead
asserts that `NAGARE_BASE_DOMAIN` and `NAGARE_REGISTRY_HOST` are provably loopback.

**Pulumi** is the infrastructure-as-code tool that creates the GCP resources. Its program
lives in `infra/pulumi/index.ts` and it keeps per-context state, selected through the
environment variables `PULUMI_HOME`, `PULUMI_BACKEND_URL` and a **stack** name (the stack
name is the context name). The Pulumi **stack config** — including the key `gcp:project`
that tells Pulumi's Google provider which project to write to — is a *derived projection*
of the context, written by `nagarectl` at onboarding and at context selection
(`cli/nagarectl/src/Nagare/Init.hs`, function `seedKeys` at line 146, and
`pulumiConfigSetArgs` at line 160). It is not hand-edited.

**`gcloud`** and **`gsutil`** are Google Cloud command-line tools. `gcloud config get-value
project` prints the project the operator's *local gcloud installation* is configured with —
which has nothing to do with the Nagare context, and is the root of two of the four bugs.

**GCS bucket names are globally unique across all of Google Cloud.** This is the crux of two
more of the bugs: if a bucket named `<project>-nagare-images` already exists in a project
belonging to someone else, and the operator has permission to see it, then "does the bucket
exist?" answers *yes* and every subsequent operation targets that foreign bucket. The only
reliable defence is to read the bucket's **owning project number** and compare it with the
target project's number, because a project number is a stable numeric identity that a
name collision cannot forge.

### The four paths that are not confined today

**Path 1 — the Pulumi state bucket, in Haskell.**
`cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs` bootstraps the Google Cloud Storage bucket
that holds Pulumi state for a context that opted into `NAGARE_PULUMI_BACKEND=gcs`. Its
runner is `runBootstrap` at `cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs:138`:

```haskell
runBootstrap :: Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
runBootstrap bucket project location mMember = do
  exists <- gcloudDescribeOk (bucketDescribeArgs bucket)
  createStep <-
    if exists
      then pure (Right ())
      else runGcloud ("create bucket gs://" <> bucket) (bucketCreateArgs bucket project location)
  chain createStep $
    chainIO (runGcloud ("update bucket gs://" <> bucket) (bucketUpdateArgs bucket)) $
      case mMember of
        Nothing -> pure (Right ())
        Just m -> runGcloud ("grant " <> m <> " on gs://" <> bucket) (bucketIamArgs bucket m)
```

`bucketCreateArgs` (line 67) carries `--project`, so a *creation* is confined. But
`bucketUpdateArgs` (line 82) and `bucketIamArgs` (line 95) address the bucket only by its
global `gs://<name>` URL. If the bucket already exists in a foreign project, `exists` is
`True`, the create is skipped, and the update rewrites that foreign bucket's versioning,
uniform bucket-level access and public-access-prevention settings — and the IAM step grants
a principal `roles/storage.objectAdmin` on it.

**Path 2 — the image bucket, in shell.** `scripts/upload-images.sh` creates the bucket that
holds the NixOS VM image tarball. Lines 60–63:

```bash
if ! gsutil ls -b "gs://${BUCKET}/" >/dev/null 2>&1; then
  log "Creating bucket gs://${BUCKET}/ in ${REGION}"
  gsutil mb -p "${PROJECT}" -l "${REGION}" -b on "gs://${BUCKET}/"
fi
```

and the upload at line 102, `gsutil cp "${src}" "${uri}"`, plus the builder-side variant at
line 105. This script *does* call `_require_target_project` (line 48), so the project it
believes in is correct — but nothing checks that `gs://${BUCKET}` belongs to that project,
so a pre-existing foreign bucket of the same name receives the multi-gigabyte host image.

**The fix that already exists.** `scripts/migrate-pulumi-backend.sh` — the shell twin of the
Haskell bootstrap — already has exactly the assertion the other two paths need, inside
`ensure_bucket` starting at `scripts/migrate-pulumi-backend.sh:99`:

```bash
  # GCS bucket names are GLOBAL: a same-named bucket may exist in a FOREIGN
  # project, and describe/update/IAM would mutate someone else's bucket. Assert
  # the bucket's owning project number equals the target project's before any
  # update, IAM change, or state import.
  local bucket_pn target_pn
  bucket_pn="$(gcloud storage buckets describe "gs://${bucket}" --format='value(projectNumber)' 2>/dev/null || true)"
  target_pn="$(gcloud projects describe "${CLOUDSDK_CORE_PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
  if [ -z "${bucket_pn}" ] || [ -z "${target_pn}" ] || [ "${bucket_pn}" != "${target_pn}" ]; then
    echo "refusing: gs://${bucket} is owned by project number '${bucket_pn:-<unknown>}', not the target project '${CLOUDSDK_CORE_PROJECT}' (number '${target_pn:-<unknown>}')." >&2
    echo "  GCS bucket names are global; pick a different state bucket with --url gs://<unique-name>/nagare/${CTX}." >&2
    return 1
  fi
```

Note the fail-closed shape: an *empty* project number — the tool is missing, the caller
lacks permission, the network failed — is treated as a mismatch, not as permission to
continue. This plan lifts that logic verbatim into a shared helper and reproduces its
contract in Haskell.

**Path 3 — the ambient gcloud default in two image-build scripts.**
`cluster/bootstrap/auth-images/build-local-image.sh` builds the three auth-plane container
images. Lines 71–75:

```bash
project="${CLOUDSDK_CORE_PROJECT:-}"
# In local mode there is no GCP project and gcloud must never be invoked
# (MasterPlan 16 Integration Point 2): skip the project lookup entirely.
if [[ -z "$project" && "$mode" != "local" ]]; then
  project="$(gcloud config get-value project 2>/dev/null || true)"
fi
```

That `project` value then flows into two cloud mutations: `gcloud builds submit … --project
"$project"` at line 310, and the pushed image name
`${registry_host}/${project}/${artifact_repository}/${service}:${tag}` built at line 97 and
pushed at line 380 after `gcloud auth configure-docker` at line 379. The script never
sources `scripts/lib/target.sh`, so `_require_target_project` never runs.
`cluster/bootstrap/nagare-access/build-image.sh` repeats the same fallback at lines 16–19.
Both of the thin wrappers `cluster/bootstrap/shomei/build-image.sh` and
`cluster/bootstrap/en/build-image.sh` `exec` into `build-local-image.sh`, so fixing that one
file covers them.

**Path 4 — `infra-up` has no project preflight, and the installed launcher does not export
the context.** `justfile:53-61`:

```make
infra-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    cd infra/pulumi && pulumi up

# EP-2: preview the Pulumi changes without applying them.
[group('infra')]
infra-preview:
    cd infra/pulumi && pulumi preview
```

`nagarectl platform guard` checks release-version compatibility only
(`cli/nagarectl/src/Nagare/Platform/Status.hs:160`, `guardPlatformMutation`); it never looks
at the project. So the selected stack's config is the only thing standing between
`pulumi up` and the wrong project. Meanwhile, the installed `nagare` launcher —
`nix/haskell-packages.nix:69-79` — exports only `NAGARE_PLATFORM_ROOT` and
`NAGARE_WORKSPACE_ROOT`:

```nix
  nagareLauncher = pkgs.writeShellApplication {
    name = "nagare";
    runtimeInputs = [ nagarectl pkgs.jq pkgs.just ];
    text = ''
      export NAGARE_PLATFORM_ROOT="${platformPackage}/share/nagare"
      workspace_json="$(nagarectl platform root --json)"
      workspace_root="$(printf '%s' "$workspace_json" | jq -er '.workspaceRoot')"
      export NAGARE_WORKSPACE_ROOT="$workspace_root"
      exec just --justfile "$workspace_root/justfile" --working-directory "$workspace_root" "$@"
    '';
  };
```

It does not export `PULUMI_HOME`, `PULUMI_BACKEND_URL`, or a stack selection, because the
design assumed the invoking shell already carried them. That holds for a checkout loaded by
`direnv` (see `.envrc`, which sources `scripts/lib/target.sh`) and does not hold for a
clone-free install.

### What is already sound (so the plan does not disturb it)

The Pulumi program creates twenty-five resource types and every one is project-scoped: no
organization, folder, billing, shared-VPC or peering resources; no `gcp.Provider` override;
no `import:` option that could adopt a pre-existing object. `infra/pulumi/index.ts:8` uses
`gcpCfg.require("project")` so a stack with no `gcp:project` aborts rather than falling
back to a default. Every IAM grant is the non-authoritative `*IAMMember` form. None of that
changes here.

### Where things live

- `scripts/lib/target.sh` — the single home of context resolution and the guardrail.
  `CLAUDE.md` states that the guardrail lives in one place; new guard functions belong here.
- `scripts/upload-images.sh`, `scripts/migrate-pulumi-backend.sh` — guarded shell scripts.
- `cluster/bootstrap/auth-images/build-local-image.sh`,
  `cluster/bootstrap/nagare-access/build-image.sh` — the two unguarded build scripts.
- `cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs` — the Haskell state-bucket bootstrap.
- `cli/nagarectl/app/Main.hs` — the CLI: `bootstrapGcsIfNeeded` at line 2684, its two call
  sites at lines 2807 (`nagarectl init`) and 2886 (`nagarectl context create --use`), the
  context subcommand parser at line 1613, and `runContext` at line 2835.
- `cli/nagarectl/src/Nagare/Target.hs` — `TargetProfile`, `Mode`, `PulumiEnv`,
  `pulumiEnvFor`, `resolveActiveTarget`. The exported record fields used here are
  `tpProject`, `tpRegion`, `tpMode`, `tpPulumiBackend`, `tpPulumiBackendUrl`.
- `cli/nagarectl/test/Spec.hs` — the `tasty` test suite; the existing
  `Nagare.Ops.PulumiBackend` cases are imported at line 201 and the `Nagare.Init (EP-63)`
  test group begins at line 400.
- `flake.nix` — the `checks` attribute set: `shellcheck-scripts` at line 278,
  `forge-credential-refresh` at line 288 (the model for a Bash test with fake tools on
  `PATH`), and `nagare-clone-free-platform` at line 111 (the model for exercising the
  installed CLI against fake `gcloud`/`gsutil`/`pulumi` in an isolated `XDG` home).
- `scripts/test-forge-credentials-refresh.sh` — the worked example of a Bash test that puts
  fake executables on `PATH` and asserts on their recorded arguments.
- `scripts/rehearse-clone-free-release.sh` — the clone-free release rehearsal; line 121 is
  today's only recipe exercise, `run_operator --dry-run infra-preview`.
- `nix/haskell-packages.nix` — the `nagare` launcher.
- `justfile` — the recipe surface.

### Relevant Architecture Decision Records

`docs/adr/` holds eight records. Scanning their titles and headings, the ones that bear on
this work are:

- [`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md`](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  — establishes that the shipped platform payload is immutable and read-only, while
  per-context mutable state lives under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/`.
  This is why the Pulumi home and state directory are per-context paths that the launcher
  must be able to derive without a checkout, and why M5's launcher export reads them from
  `nagarectl` rather than from a file in the payload.
- [`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
  — the decision behind `nagarectl platform guard`, the existing recipe preflight. It
  explains why `platform guard` answers only the release-compatibility question, which is
  the basis for the Decision Log entry above choosing a separate `context guard` command.
- [`docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md`](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md)
  — the release contract that `scripts/rehearse-clone-free-release.sh` implements, which
  M5 extends.

No existing ADR states the project-confinement contract itself; the closest durable
statement is the "GCP project isolation" section of [`CLAUDE.md`](../../CLAUDE.md) and the
Decision Log of
[`docs/masterplans/17-first-class-target-contexts-for-nagare.md`](../masterplans/17-first-class-target-contexts-for-nagare.md).
M6 writes that missing ADR.

### The originating Improvement Request

This plan implements
[`docs/improvement-requests/confine-cloud-mutations-to-context-project.md`](../improvement-requests/confine-cloud-mutations-to-context-project.md)
(IR-2), raised by a pre-flight isolation audit of `v0.1.0` performed before onboarding a new
cloud context into a GCP organization that also contains production projects. Everything
that request asks for is in scope here; its Non-goals section — cross-project support,
per-resource project overrides, changing the non-authoritative IAM model, new isolation
between contexts beyond the project boundary — is out of scope for this plan too. IR-2 also
notes that removing the built-in `tan-nb-exp` defaults is handled separately, by
[`docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md`](112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md)
(EP-113 and EP-112 touch different files and can be implemented in either order).


## Plan of Work

The work is six milestones. Milestones 1–3 close the three script- and library-level holes;
each is independently shippable and independently verifiable. Milestone 4 adds the missing
`infra-up` preflight. Milestone 5 makes the installed launcher behave like a `direnv`-loaded
checkout so the preflight has correct inputs outside a source tree. Milestone 6 writes the
documentation and the ADR and closes IR-2.


### Milestone 1 — one shared bucket-ownership assertion for the shell paths

**Scope:** `scripts/lib/target.sh`, `scripts/migrate-pulumi-backend.sh`,
`scripts/upload-images.sh`, a new `scripts/test-bucket-ownership-guard.sh`, and `flake.nix`.

**What exists at the end:** a Bash function `_require_bucket_in_target_project` living
beside `_require_target_project` in `scripts/lib/target.sh`; `migrate-pulumi-backend.sh`
calling it instead of carrying its own copy; `upload-images.sh` calling it before it creates
a bucket and before it uploads anything; and an automated test that proves the refusal.

Add to `scripts/lib/target.sh`, immediately after `_require_target_project` (which ends at
line 330), a new function with this contract. In **local mode it returns 0 immediately and
invokes no tool**, because a local context has no GCS bucket and no project. In cloud mode
it reads the bucket's owning project number and the target project's project number, and
refuses unless both are non-empty and equal:

```bash
# Fail-closed assertion that a GCS bucket belongs to the ACTIVE CONTEXT'S project.
# GCS bucket names are GLOBAL: a same-named bucket may exist in a FOREIGN project
# that the operator can describe, so "the bucket exists" is not evidence that it is
# ours. Compare owning PROJECT NUMBERS, which a name collision cannot forge. An
# unreadable number (missing tool, missing permission, network failure) is a
# MISMATCH, never permission to continue.
#
#   _require_bucket_in_target_project <bucket-name-without-gs-prefix> [remedy-hint]
#
# Local mode has no GCS bucket and no project: return 0 without invoking any tool.
_require_bucket_in_target_project() {
  local bucket="${1:?_require_bucket_in_target_project: bucket name required}"
  local hint="${2:-}"
  [ "${NAGARE_MODE:-}" = "local" ] && return 0
  local bucket_pn target_pn
  bucket_pn="$(gcloud storage buckets describe "gs://${bucket}" --format='value(projectNumber)' 2>/dev/null || true)"
  target_pn="$(gcloud projects describe "${TARGET_PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
  if [ -z "${bucket_pn}" ] || [ -z "${target_pn}" ] || [ "${bucket_pn}" != "${target_pn}" ]; then
    echo "refusing: gs://${bucket} is owned by project number '${bucket_pn:-<unknown>}', not the target project '${TARGET_PROJECT}' (number '${target_pn:-<unknown>}')." >&2
    echo "  GCS bucket names are global; ${hint:-choose a bucket name that is unique across all of Google Cloud.}" >&2
    return 1
  fi
}
```

Two details matter. It compares against `TARGET_PROJECT` (the variable
`scripts/lib/target.sh` assigns at line 269 once resolution has finished) rather than reading
`CLOUDSDK_CORE_PROJECT` directly, so it agrees with whatever `_require_target_project`
just validated. And it takes an optional remedy hint so each caller can name the right fix
without the helper knowing about callers.

Then rewrite `ensure_bucket` in `scripts/migrate-pulumi-backend.sh` (line 99) so that the
inline block quoted in Context and Orientation is replaced by
`_require_bucket_in_target_project "${bucket}" "pick a different state bucket with --url gs://<unique-name>/nagare/${CTX}."`.
Keep the create step and everything after it exactly as it is; the assertion must sit
between the create-if-missing step and the `buckets update`, which is where it sits today.

In `scripts/upload-images.sh`, add the assertion in two places. First, after the bucket is
resolved from Pulumi config and before the create-if-missing block at line 60: if the bucket
already exists it must be ours before we do anything else, and if we are about to create it
the assertion is a cheap no-op that will then pass. The clean shape is to run the existing
`gsutil ls -b` existence probe, create when absent, and assert afterwards — mirroring
`ensure_bucket`, so both scripts have the same order of operations:

```bash
log "Target bucket: gs://${BUCKET}/"
if ! gsutil ls -b "gs://${BUCKET}/" >/dev/null 2>&1; then
  log "Creating bucket gs://${BUCKET}/ in ${REGION}"
  gsutil mb -p "${PROJECT}" -l "${REGION}" -b on "gs://${BUCKET}/"
fi
_require_bucket_in_target_project "${BUCKET}" \
  "set a unique nagare:imageBucket with 'pulumi --cwd infra/pulumi config set imageBucket <unique-name>'."
```

Second, inside `upload_if_missing` (line 98), before either `gsutil cp` runs. That second
call is not redundant: `upload_if_missing` also runs the *builder-side* upload over SSH at
line 105, and re-asserting immediately before the write keeps the guarantee local to the
mutation rather than depending on the caller's ordering.

The new test `scripts/test-bucket-ownership-guard.sh` follows the shape of
`scripts/test-forge-credentials-refresh.sh`: create a temporary directory, write fake
`gcloud` and `gsutil` executables into it that record their arguments and print scripted
output, put that directory first on `PATH`, point `XDG_CONFIG_HOME`/`XDG_STATE_HOME` at the
temporary tree, write a context file that declares a known project, and then source
`scripts/lib/target.sh` and call the function. It must cover four cases: matching project
numbers succeed; a differing bucket project number refuses; an *empty* bucket project number
(the fake `gcloud` prints nothing) refuses; and a local-mode context returns success without
the fake `gcloud` being invoked at all — assert the last one by checking that the recorded
argument log is empty. Register it in `flake.nix` `checks` as
`bucket-ownership-guard`, copying the `forge-credential-refresh` derivation at line 288 and
substituting the script name and the needed `nativeBuildInputs` (`bash`, `coreutils`,
`gnugrep`).

**Acceptance:** `nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).bucket-ownership-guard`
succeeds, and `bash scripts/test-bucket-ownership-guard.sh` prints `ok` for each of the four
cases. Reverting only the `scripts/lib/target.sh` addition and re-running must fail.


### Milestone 2 — the same assertion in `Nagare.Ops.PulumiBackend`, and a fatal bootstrap

**Scope:** `cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs`, `cli/nagarectl/app/Main.hs`,
`cli/nagarectl/test/Spec.hs`.

**What exists at the end:** `bootstrapPulumiStateBucket` refuses before its `buckets update`
and `add-iam-policy-binding` steps when the state bucket's owning project number differs
from the target project's; unit tests prove both the refusal and the acceptance by observing
which `gcloud` commands were attempted; and a bootstrap failure aborts `nagarectl init` and
`nagarectl context create --use` with a non-zero exit instead of printing a warning.

The module today is built from pure argv builders plus an IO runner, and the argv builders
are already unit-tested (`cli/nagarectl/test/Spec.hs:201`). Extend that same design rather
than replacing it.

Add two pure argv builders and one pure verdict function, and export them:

```haskell
-- | @gcloud storage buckets describe gs://<bucket> --format=value(projectNumber)@ —
-- reads the bucket's OWNING project number. GCS bucket names are global, so a
-- successful describe is not evidence that the bucket is ours.
bucketProjectNumberArgs :: Text -> [String]

-- | @gcloud projects describe <project> --format=value(projectNumber)@ — the target
-- project's own number, the value the bucket's must equal.
projectNumberArgs :: Text -> [String]

-- | Fail closed: refuse unless BOTH numbers are present and equal. An absent number
-- (missing gcloud, missing permission, network failure) is a mismatch, never
-- permission to continue. The message mirrors the Bash helper
-- @_require_bucket_in_target_project@ in @scripts/lib/target.sh@ word for word.
bucketOwnershipVerdict :: Text -> Text -> Maybe Text -> Maybe Text -> Either Text ()
```

`bucketOwnershipVerdict bucket project mBucketNumber mTargetNumber` returns `Right ()` only
when both `Maybe`s are `Just` a non-empty value and the values are equal; otherwise `Left`
with the message
`"refusing: gs://<bucket> is owned by project number '<n|unknown>', not the target project
'<project>' (number '<n|unknown>'). GCS bucket names are global; choose a state bucket name
that is unique across all of Google Cloud, or set NAGARE_PULUMI_BACKEND_URL to
gs://<unique-name>/nagare/<context>."`

Introduce a small injectable seam so the runner can be driven by a test without a real
`gcloud`. The module currently calls `runGcloud` and `gcloudDescribeOk` directly; wrap them
in a record and thread it through:

```haskell
-- | The external @gcloud@ effects this module needs, injectable so the bootstrap
-- sequence itself (not just its argv) can be unit-tested. 'realGcloudOps' is the
-- production implementation; tests supply a recording fake.
data GcloudOps = GcloudOps
  { gcloudCapture :: [String] -> IO (Maybe Text)
  -- ^ Run and capture trimmed stdout; 'Nothing' on any failure.
  , gcloudExec :: Text -> [String] -> IO (Either Text ())
  -- ^ Run for effect, streaming output; 'Left' names the failed step.
  }

realGcloudOps :: GcloudOps

-- | The existing entry point, unchanged in type, now defined as
-- @bootstrapPulumiStateBucketWith realGcloudOps@.
bootstrapPulumiStateBucket :: Bool -> Text -> TargetProfile -> Maybe Text -> IO (Either Text ())

bootstrapPulumiStateBucketWith :: GcloudOps -> Bool -> Text -> TargetProfile -> Maybe Text -> IO (Either Text ())
```

`gcloudCapture` is implemented with `System.Process.readProcessWithExitCode`, returning
`Just` the `Data.Text.strip`ped stdout on `ExitSuccess` and `Nothing` otherwise — the same
shape as `Nagare.Ops.Probe.captureTool`, which cannot be reused directly here because it
returns a `ByteString` and swallows the distinction this code needs. `gcloudExec` is the
existing `runGcloud`. The existence probe `gcloudDescribeOk` becomes
`isJust <$> gcloudCapture ops (bucketDescribeArgs bucket)`.

Rewrite `runBootstrap` so that the assertion sits between the create-if-missing step and the
update step, exactly where the Bash twin puts it:

1. probe existence with `bucketDescribeArgs`;
2. if absent, create with `bucketCreateArgs` (which carries `--project`);
3. **read both project numbers and apply `bucketOwnershipVerdict`; return its `Left`
   immediately on refusal, having run no update and no IAM change**;
4. run `bucketUpdateArgs`;
5. run `bucketIamArgs` when a member was supplied.

Extend `bootstrapCommands` (the pure list used for the `--dry-run` print at line 130) to
include the two read commands ahead of the create, so a dry run shows the full intended
sequence including the assertion.

Then, in `cli/nagarectl/app/Main.hs`, change `bootstrapGcsIfNeeded` at line 2684 from a
warning to a fatal error, and update its Haddock comment, which currently states the
opposite:

```haskell
-- | Bootstrap the GCS Pulumi state bucket for a context that opts into it. A
-- local/local-mode context is a no-op. A bootstrap failure is FATAL (EP-113): a
-- partially-applied bootstrap that lets `init` report success is exactly the state
-- that hides a foreign-bucket refusal from the operator.
bootstrapGcsIfNeeded :: Bool -> Text -> TargetProfile -> Maybe Text -> IO ()
bootstrapGcsIfNeeded dryRun ctx tp mMember =
  bootstrapPulumiStateBucket dryRun ctx tp mMember
    >>= either (\msg -> dieT ("GCS state-bucket bootstrap failed: " <> msg)) pure
```

Both existing call sites (line 2807 in `nagarectl init`, line 2886 in
`nagarectl context create --use`) keep their current shape and inherit the new behavior.

Add the tests to `cli/nagarectl/test/Spec.hs`, in the group that already covers this module.
Three pure cases — `bucketProjectNumberArgs`, `projectNumberArgs`, and a table of
`bucketOwnershipVerdict` inputs — and two behavioral cases driven through
`bootstrapPulumiStateBucketWith` with a fake `GcloudOps` that appends every argv it is given
to an `IORef [[String]]`:

- *refusal*: the fake reports the bucket exists, returns `Just "111111111111"` for the
  bucket's number and `Just "999999999999"` for the target's. Assert the result is a `Left`
  whose message contains `refusing: gs://`, and — this is the part that proves confinement —
  assert the recorded argv list contains **no** element beginning
  `["storage","buckets","update"]` and none beginning
  `["storage","buckets","add-iam-policy-binding"]`.
- *acceptance*: the same fake with both numbers `Just "999999999999"`. Assert `Right ()`,
  and that the recorded list *does* contain the update argv and the IAM argv in that order.

Add a third behavioral case for the fail-closed edge: the fake returns `Nothing` for the
bucket's project number (as a missing `gcloud` or a permission error would). Assert `Left`
and no update.

**Acceptance:** `cabal test nagarectl-test` passes with the new cases, and each of the two
behavioral cases fails if the assertion step is removed from `runBootstrap`.


### Milestone 3 — the image-build scripts fail closed

**Scope:** `cluster/bootstrap/auth-images/build-local-image.sh`,
`cluster/bootstrap/nagare-access/build-image.sh`, `flake.nix`, and a new
`scripts/test-image-build-guard.sh`.

**What exists at the end:** neither script can resolve a project from `gcloud config`;
both take the project only from the resolved active context; and both refuse before any
cloud mutation when the guardrail is unsatisfied. Local-mode and no-push builds keep
working without `gcloud`.

In `cluster/bootstrap/auth-images/build-local-image.sh`, source the resolver next to the
existing `scripts/lib/release.sh` source at line 41:

```bash
# shellcheck source=scripts/lib/release.sh
source "$root/scripts/lib/release.sh"
# Resolve the active target context and make the configurable, fail-closed
# guardrail available (EP-113). Sourcing exports CLOUDSDK_* / NAGARE_* and
# TARGET_PROJECT; it does NOT itself refuse — `_require_target_project` does,
# and this script calls it before every cloud mutation.
# shellcheck source=scripts/lib/target.sh
source "$root/scripts/lib/target.sh"
```

Replace lines 71–75 with a project that comes from the context and nothing else:

```bash
# The project comes ONLY from the resolved context (EP-113). There is deliberately
# no `gcloud config get-value project` fallback: an ambient gcloud default is not
# the Nagare target, and reading it is how a build lands in a production project.
# In local mode there is no project at all.
project=""
if [[ "$mode" != "local" ]]; then
  project="${CLOUDSDK_CORE_PROJECT:-}"
fi
```

Then call `_require_target_project` before each cloud mutation, and only before those, so a
purely local build (`NAGARE_AUTH_PUSH=0`, or `NAGARE_AUTH_BUILDER=k3s-import`, or a
local-mode context) still runs with no `gcloud` on `PATH` and no context configured beyond
the defaults. There are three mutation sites:

1. the `cloud-build` branch, immediately before `gcloud builds submit` at line 310;
2. the push branch's cloud arm, immediately before `gcloud auth configure-docker` at
   line 379;
3. the early validation at line 78 that rejects `cloud-build` without a project — keep it,
   but reword its message to name the context rather than "an active gcloud project":
   `fail "NAGARE_AUTH_BUILDER=cloud-build requires an active cloud context that declares a project (see 'nagarectl context use')"`.

Update the error at line 99 the same way. Note that in local mode `_require_target_project`
asserts loopback and returns 0 without touching `gcloud`, so calling it at site 2 is correct
even though the local arm of that branch is the plain `docker push`; place the call inside
the `else` (cloud) arm to keep local mode entirely gcloud-free.

`cluster/bootstrap/nagare-access/build-image.sh` gets the same treatment: source
`scripts/lib/target.sh` after line 9, replace lines 16–24 with a context-only project and a
refusal that names the context, and call `_require_target_project` before the
`gcloud auth configure-docker` / `docker push` block at lines 39–42. Its early `exec` into
`build-local-image.sh` at line 6 happens before any of this, which is correct — the delegate
does its own guarding.

Extend the `shellcheck-scripts` check in `flake.nix` (line 278) to cover the two build
scripts, which it does not lint today:

```bash
              shellcheck --severity=error \
                scripts/*.sh \
                scripts/lib/*.sh \
                cluster/bootstrap/auth-images/build-local-image.sh \
                cluster/bootstrap/nagare-access/build-image.sh \
                nixos/hosts/nagare-01/forge-credentials-refresh.sh
```

Add `scripts/test-image-build-guard.sh`, again in the `test-forge-credentials-refresh.sh`
shape. It must prove three things, using a fake `gcloud` that records its arguments and a
fake `docker` that records and succeeds:

- with a cloud context declaring project `nagare-guard-test` and an ambient
  `CLOUDSDK_CORE_PROJECT=some-production-project`, running
  `cluster/bootstrap/auth-images/build-local-image.sh shomei test-tag` with
  `NAGARE_AUTH_BUILDER=cloud-build NAGARE_AUTH_PUSH=1` exits non-zero, prints
  `refusing to run:`, and the recorded `gcloud` log contains **no** `builds submit` line;
- with no `CLOUDSDK_CORE_PROJECT` and a fake `gcloud config get-value project` that would
  print `some-production-project`, the same invocation still does not use that value —
  assert the recorded log contains no `config get-value project` line at all, which is the
  strongest available statement that the fallback is gone;
- with a local-mode context and `NAGARE_AUTH_PUSH=0 NAGARE_AUTH_BUILDER=docker`, the script
  reaches its build step without invoking `gcloud` (empty `gcloud` log).

The third case needs the script's source-directory prerequisites (`SHOMEI_SRC`, `EN_SRC`)
to exist; point them at empty temporary directories created by the test, and stop the run
before the real `docker build` by supplying a fake `docker` that exits 0. Register the test
in `flake.nix` `checks` as `image-build-guard`.

**Acceptance:** `bash scripts/test-image-build-guard.sh` prints `ok` for all three cases;
`nix build .#checks.<system>.shellcheck-scripts` and `.#checks.<system>.image-build-guard`
succeed; and `grep -rn 'gcloud config get-value project' cluster/` returns nothing.


### Milestone 4 — `nagarectl context guard`, wired into the Pulumi recipes

**Scope:** `cli/nagarectl/src/Nagare/Target.hs` (or a new
`cli/nagarectl/src/Nagare/Ops/ContextGuard.hs`), `cli/nagarectl/app/Main.hs`, `justfile`,
`cli/nagarectl/test/Spec.hs`, `flake.nix`.

**What exists at the end:** a command `nagarectl context guard` that refuses when anything
disagrees about which project the next Pulumi operation would write to, and `infra-up` and
`infra-preview` recipes that run it before invoking Pulumi.

Create `cli/nagarectl/src/Nagare/Ops/ContextGuard.hs` holding the pure comparison, so it can
be unit-tested without Pulumi, `gcloud`, or a filesystem:

```haskell
-- | What the guard compared and what it concluded. Rendered for humans and for
-- @--json@, so a failing recipe can be diagnosed from its output alone.
data ProjectGuardInputs = ProjectGuardInputs
  { pgiContext :: !Text          -- ^ active context name
  , pgiDeclared :: !Text         -- ^ the project the active context declares
  , pgiStack :: !Text            -- ^ the selected Pulumi stack
  , pgiStackProject :: !(Maybe Text)
    -- ^ the stack's @gcp:project@; 'Nothing' when unset or unreadable
  , pgiAmbient :: !(Maybe Text)
    -- ^ @CLOUDSDK_CORE_PROJECT@ from the environment, when set
  , pgiConfigured :: !(Maybe Text)
    -- ^ gcloud's configured project, read with @CLOUDSDK_CORE_PROJECT@ stripped
  }

-- | Fail closed on ANY disagreement. Returns the refusal text on 'Left'.
projectGuardVerdict :: ProjectGuardInputs -> Either Text ()
```

`projectGuardVerdict` refuses when: `pgiStackProject` is `Nothing`; `pgiStackProject` is
`Just p` and `p /= pgiDeclared`; `pgiAmbient` is `Just p` and `p /= pgiDeclared`; or
`pgiAmbient` is `Nothing` and `pgiConfigured` is `Just p` with `p /= pgiDeclared`. A
`pgiConfigured` of `Nothing` when `pgiAmbient` is set is not a refusal — `gcloud` may not be
installed on a machine that only previews. Each refusal message names both compared values
and the remedy, in the style already used by the cloud-branch refusals at
`scripts/lib/target.sh:316` and `scripts/lib/target.sh:324-326`.

Reading `CLOUDSDK_CORE_PROJECT` with the variable stripped matters for the same reason it
does in Bash: `gcloud` lets that environment variable shadow its own configuration, so
reading it without stripping would compare a value against itself. In Haskell, run the
`gcloud config get-value project` capture in a modified environment — `System.Process`'s
`env` field set to the current environment minus `CLOUDSDK_CORE_PROJECT` — rather than by
temporarily unsetting the variable in the process, which is not safe.

In `cli/nagarectl/app/Main.hs`, add a `ContextGuard` constructor to the `ContextCommand`
type (declared at line 549) and a `command "guard"` entry to the context subparser
(line 1613), with a `--json` switch. Its handler in `runContext` (line 2835):

1. resolves the active target with `activeTarget mctx`;
2. if the mode is `Local`, prints `context guard: local mode; no GCP project to confine`
   and exits 0 — a local context has no project, exactly as `_require_target_project` has no
   project to check there;
3. otherwise calls `ensurePulumiForContext` (line 2647) so the per-context `PULUMI_HOME`,
   backend URL and stack exist and are selected — this is what makes the guard usable as the
   *only* preflight a clone-free recipe needs;
4. reads the stack's project with
   `pulumi -C <pulumiDir> config get gcp:project --stack <ctx>`, captured through
   `Nagare.Ops.Probe.captureTool`, mapping failure to `Nothing`;
5. reads the ambient and configured projects;
6. applies `projectGuardVerdict` and either `dieT`s with the refusal or prints
   `context guard: <context> confined to project <project> (stack <stack>)`.

Then change the two recipes in `justfile` (lines 53–61):

```make
# Create/update GCP infrastructure (pulumi up).
[group('infra')]
infra-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    nagarectl context guard
    cd infra/pulumi && pulumi up

# EP-2: preview the Pulumi changes without applying them.
[group('infra')]
infra-preview:
    nagarectl context guard
    cd infra/pulumi && pulumi preview
```

Note that `platform guard` stays behind its `NAGARE_UPGRADE_APPLY` escape hatch (an
in-progress platform upgrade legitimately runs with skewed versions) while `context guard`
has no escape hatch: there is no situation in which writing to the wrong project is correct.

Unit-test `projectGuardVerdict` in `cli/nagarectl/test/Spec.hs` across the full table: all
agree (accept); stack project unset (refuse); stack project differs (refuse); ambient
differs (refuse); ambient unset and configured differs (refuse); ambient unset and
configured unset (accept, with the stack agreeing). Then add the end-to-end fixture to the
`nagare-clone-free-platform` check in `flake.nix` (line 111), whose fake `pulumi` at line 113
must grow a branch: when its arguments contain `config get gcp:project` it prints a value
taken from an environment variable the check controls, so the check can run the guard twice
— once with the stack agreeing (expect exit 0 and the confirmation line) and once with the
stack naming a foreign project (expect non-zero and a message containing `gcp:project`).

**Acceptance:** from a checkout with a cloud context selected,
`nagarectl context guard` prints the confirmation and exits 0; after
`pulumi -C infra/pulumi config set --stack <ctx> gcp:project some-other-project`, it exits
non-zero naming both projects and `just infra-preview` stops before invoking Pulumi; after
restoring the correct value, both succeed again.


### Milestone 5 — the installed launcher carries the context

**Scope:** `cli/nagarectl/src/Nagare/Target.hs`, `cli/nagarectl/app/Main.hs`,
`nix/haskell-packages.nix`, `scripts/rehearse-clone-free-release.sh`,
`cli/nagarectl/test/Spec.hs`.

**What exists at the end:** `nagare <recipe>` run from a directory with no `.envrc` and no
source checkout resolves the active context and exports the same Pulumi environment a
`direnv`-loaded checkout would, so every Pulumi-invoking recipe behaves identically in both
worlds.

Add to `cli/nagarectl/src/Nagare/Target.hs` a renderer that produces the *shell environment*
for a resolved context — distinct from `Nagare.Init.renderTargetEnv`, which renders the
*context file* and must not grow Pulumi keys, because that file is the persisted context:

```haskell
-- | The full shell environment an operator recipe needs: the CLOUDSDK_* / NAGARE_*
-- contract plus the per-context Pulumi selection. Emitted as shell-quoted
-- @export K=V@ lines for @eval@ by the `nagare` launcher, which has no .envrc.
-- This is the Haskell twin of what @scripts/lib/target.sh@ exports; the two must
-- agree, and @scripts/rehearse-clone-free-release.sh@ proves they do.
renderContextShellEnv :: ContextName -> TargetProfile -> PulumiEnv -> Text
```

It emits, single-quoted with embedded single quotes escaped: `NAGARE_CONTEXT`,
`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`, the
`NAGARE_*` context fields already produced by `renderTargetEnv`, and then `PULUMI_HOME`,
`PULUMI_BACKEND_URL`, `PULUMI_CONFIG_PASSPHRASE_FILE`, `PULUMI_CONFIG_PASSPHRASE` (empty,
matching `.envrc`) and `NAGARE_PULUMI_STACK`, all taken from
`Nagare.Target.pulumiEnvFor`. Unit-test it in `cli/nagarectl/test/Spec.hs` beside the
existing `pulumiEnvFor` cases (line 439): assert the exact `PULUMI_BACKEND_URL` line for a
local backend and for a GCS backend, and assert a project value containing a single quote
round-trips through `bash -c` unchanged.

Add `nagarectl context env [--context NAME]` to the context subparser. It resolves the
active target, ensures the per-context Pulumi home and state directory exist (reusing
`ensurePulumiForContext`, so the launcher does not have to), and prints
`renderContextShellEnv`. Nothing else — it must be safe to `eval`.

Change the launcher in `nix/haskell-packages.nix:69`:

```nix
  nagareLauncher = pkgs.writeShellApplication {
    name = "nagare";
    runtimeInputs = [ nagarectl pkgs.jq pkgs.just ];
    text = ''
      export NAGARE_PLATFORM_ROOT="${platformPackage}/share/nagare"
      workspace_json="$(nagarectl platform root --json)"
      workspace_root="$(printf '%s' "$workspace_json" | jq -er '.workspaceRoot')"
      export NAGARE_WORKSPACE_ROOT="$workspace_root"
      # EP-113: a clone-free install has no .envrc, so the launcher must export the
      # active context's CLOUDSDK_* / NAGARE_* / PULUMI_* contract itself. Without
      # this, `nagare infra-up` inherits whatever Pulumi state the invoking shell
      # happens to carry — which for a clone-free install is none.
      context_env="$(nagarectl context env)"
      eval "$context_env"
      exec just --justfile "$workspace_root/justfile" --working-directory "$workspace_root" "$@"
    '';
  };
```

`writeShellApplication` runs `shellcheck` on this text at build time; if it objects to the
`eval`, add a scoped `# shellcheck disable=SC2086` (or the code it actually reports) with a
comment explaining that the evaluated text is produced by `nagarectl` and shell-quoted by
`renderContextShellEnv`. Do not silence it globally.

Finally, extend `scripts/rehearse-clone-free-release.sh`. Today its only recipe exercise is
line 121, `run_operator --dry-run infra-preview`. Add, after it, a real assertion that the
recipe run carries the active context's Pulumi selection. The rehearsal already runs from
`$test_root/work` with isolated `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` and no
`.envrc`, so the environment is already the one to test; what is missing is the assertion:

```bash
# EP-113: a clone-free recipe run must carry the ACTIVE CONTEXT's Pulumi backend and
# stack, exactly as a direnv-loaded checkout does. `nagare` exports them itself.
run_cli context env > context-env.sh
grep -q "^export NAGARE_PULUMI_STACK='rehearsal-cloud'$" context-env.sh
grep -q "^export PULUMI_BACKEND_URL='file://${test_root}/state/nagare/rehearsal-cloud/state'$" context-env.sh
grep -q "^export CLOUDSDK_CORE_PROJECT='nagare-release-rehearsal'$" context-env.sh
run_operator --dry-run infra-preview > infra-preview.out 2>&1
grep -q 'nagarectl context guard' infra-preview.out
```

and add `"context-env"` to the `checks` array in the JSON result at line 136 so the
rehearsal artifact records that the new coverage ran.

**Acceptance:** `bash scripts/rehearse-clone-free-release.sh --version 0.1.0` completes and
its JSON output lists `context-env` among `checks`. Manually, from a directory with no
`.envrc` and a context selected, `nagare --dry-run infra-preview` prints both the
`nagarectl context guard` line and the `cd infra/pulumi && pulumi preview` line.


### Milestone 6 — documentation, the ADR, and closing IR-2

**Scope:** `docs/user/gcp-prerequisites.md`, `docs/user/contexts.md`,
`docs/user/provisioning-with-pulumi.md`, `docs/user/log.md`, a new file under `docs/adr/`,
`docs/improvement-requests/confine-cloud-mutations-to-context-project.md`,
`docs/improvement-requests/log.md`, and `docs/plan-registry.md`.

**What exists at the end:** the documented promise matches the enforced behavior, the
durable decision is recorded as an ADR, and IR-2 is accepted and linked to this plan.

In `docs/user/gcp-prerequisites.md`, the section listing what enforces project confinement
today (around lines 100–106) names `scripts/enable-apis.sh` and the `gcp.projects.Service`
resources. Extend it to state the enforced contract in full: every cloud-mutating path
asserts the active context's project before it writes; bucket operations additionally
compare owning project numbers because GCS names are global; and `infra-up` /
`infra-preview` refuse when the selected Pulumi stack disagrees with the context. In
`docs/user/contexts.md`, document `nagarectl context guard` and `nagarectl context env` in
the command reference, including the exact refusal messages so an operator can search for
them. In `docs/user/provisioning-with-pulumi.md`, document the new `infra-up` preflight and
what to do when it refuses.

`docs/user` is a profiled OKF bundle validated by `just user-documentation-validate`, and
`docs/user/log.md` is its reserved update log; add an entry for this change with
`okf log add` and re-run the validation, which is part of `just docs-validate`.

Write the ADR. Follow [`.claude/skills/exec-plan/ADR.md`](../../.claude/skills/exec-plan/ADR.md):
`docs/adr/` here is a plain filesystem convention (no `profile.dhall`, frontmatter fields
`title`, `status`, `date`, `authors`, `related`), so preserve that convention rather than
introducing OKF identity. The next unused number is 9; name the file
`docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md` and record:
the decision that project confinement is enforced at every mutation site rather than only at
the entry points; that GCS bucket names are global so bucket operations must compare owning
project numbers, and an unreadable number is a refusal; that the assertion is implemented
twice, in Bash and in Haskell, against one shared contract, with the reasoning from this
plan's Decision Log; that ambient `gcloud config` is never a source of the target project;
and that local mode is exempt because it has no GCP project, with the loopback assertion as
the compensating check. Relate it to
`docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md`,
`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md` and
`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`.

Accept IR-2 exactly as IR-3 was accepted in commit `cbee22d`: in
`docs/improvement-requests/confine-cloud-mutations-to-context-project.md` set
`status: accepted`, add
`targetPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md`,
refresh `timestamp` to the acceptance time, and change the body's `**Status:**` line to
`accepted; planned as [ExecPlan 113](../plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md).`
Add the matching `* **Update**: …` line to `docs/improvement-requests/log.md` under today's
date, and validate with `just reviews-validate`'s sibling command for that bundle (see
Concrete Steps).

Register the plan in `docs/plan-registry.md` with a row in the same form as EP-110 through
EP-112: the plan link, the intention `intention_01m2az59r0ejqtvw1mgvhe4d7f`, a status, and
the note that it implements IR-2 from the September 2026 pre-flight review of `v0.1.0`,
which is outside MasterPlan 19's July 2026 review scope — hence a standalone plan rather
than a child of an existing MasterPlan.

**Acceptance:** `just docs-validate` passes; `okf validate docs/improvement-requests
--strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce`
passes; `docs/plan-registry.md` contains the EP-113 row; and
`docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md` exists.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, inside the
project's development shell. Enter it with `nix develop`, or let `direnv` load it after
`direnv allow`.

Determine your system string once; several commands need it:

```bash
system="$(nix eval --raw --impure --expr builtins.currentSystem)"
echo "$system"
```

Expected output on the development machine:

```text
aarch64-darwin
```

### Before you change anything

Record the current state so you can see the change take effect:

```bash
grep -n 'gcloud config get-value project' cluster/bootstrap/auth-images/build-local-image.sh cluster/bootstrap/nagare-access/build-image.sh
grep -n 'projectNumber' scripts/lib/target.sh scripts/upload-images.sh cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs
```

Expected before the work:

```text
cluster/bootstrap/auth-images/build-local-image.sh:75:  project="$(gcloud config get-value project 2>/dev/null || true)"
cluster/bootstrap/nagare-access/build-image.sh:18:  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
```

and no `projectNumber` match outside `scripts/migrate-pulumi-backend.sh`. After the full plan
both greps invert: no `gcloud config get-value project` anywhere under `cluster/`, and
`projectNumber` present in `scripts/lib/target.sh` and
`cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs`.

### Milestone 1

```bash
# after editing scripts/lib/target.sh, scripts/migrate-pulumi-backend.sh,
# scripts/upload-images.sh and adding scripts/test-bucket-ownership-guard.sh
chmod +x scripts/test-bucket-ownership-guard.sh
bash scripts/test-bucket-ownership-guard.sh
nix shell nixpkgs#shellcheck --command shellcheck --severity=error \
  scripts/lib/target.sh scripts/upload-images.sh scripts/migrate-pulumi-backend.sh \
  scripts/test-bucket-ownership-guard.sh
nix build ".#checks.${system}.bucket-ownership-guard"
```

Expected transcript from the test:

```text
ok: matching project numbers proceed
ok: a foreign bucket project number refuses
ok: an unreadable bucket project number refuses
ok: local mode returns success without invoking gcloud
```

Commit:

```text
feat(scripts): assert bucket ownership against the active context's project

GCS bucket names are global, so a same-named bucket in a foreign project would
receive the image tarball and the state-bucket reconfiguration. Extract the
project-number assertion from migrate-pulumi-backend.sh into
_require_bucket_in_target_project in scripts/lib/target.sh and call it from both
bucket paths before any create, update, IAM change or upload.

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

### Milestone 2

```bash
cabal build nagarectl
cabal test nagarectl-test
```

Expected tail of the test output:

```text
  Nagare.Ops.PulumiBackend (EP-93, EP-113)
    bucketProjectNumberArgs reads the bucket's owning project number: OK
    projectNumberArgs reads the target project's number:              OK
    bucketOwnershipVerdict fails closed on absent or differing numbers: OK
    bootstrap refuses a foreign bucket before update or IAM:          OK
    bootstrap proceeds to update and IAM when the numbers match:      OK

All N tests passed
```

Commit:

```text
feat(nagarectl): refuse a foreign Pulumi state bucket and fail init on bootstrap error

Nagare.Ops.PulumiBackend addressed the state bucket by its global gs:// name, so
`buckets update` and `add-iam-policy-binding` could reconfigure a same-named bucket
in another project. Compare owning project numbers before either step, behind an
injectable gcloud seam so the sequence is unit-tested, and make a bootstrap failure
fatal to `nagarectl init` instead of a warning.

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

### Milestone 3

```bash
chmod +x scripts/test-image-build-guard.sh
bash scripts/test-image-build-guard.sh
grep -rn 'gcloud config get-value project' cluster/ || echo 'no ambient project fallback remains'
nix build ".#checks.${system}.shellcheck-scripts" ".#checks.${system}.image-build-guard"
```

Expected:

```text
ok: cloud-build refuses when the ambient project disagrees with the context
ok: the gcloud config fallback is gone (no 'config get-value project' call)
ok: a local-mode no-push build never invokes gcloud
no ambient project fallback remains
```

Commit:

```text
fix(cluster): build auth images only for the active context's project

build-local-image.sh and nagare-access/build-image.sh resolved the project from
`gcloud config get-value project` and never sourced the guardrail, so an operator
whose gcloud pointed at production submitted Cloud Build jobs there. Take the
project only from the resolved context, call _require_target_project before every
cloud mutation, and lint both scripts.

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

### Milestone 4

```bash
cabal test nagarectl-test
just --dry-run infra-preview
nagarectl context guard
```

Expected from the last two, with a cloud context named `labs` selected:

```text
nagarectl context guard
cd infra/pulumi && pulumi preview
context guard: labs confined to project acme-prod (stack labs)
```

Then prove the refusal against a real stack, and restore it afterwards:

```bash
ctx="$(nagarectl context current)"
orig="$(pulumi -C infra/pulumi config get gcp:project --stack "$ctx")"
pulumi -C infra/pulumi config set --stack "$ctx" gcp:project some-other-project
nagarectl context guard; echo "exit=$?"
just infra-preview; echo "exit=$?"
pulumi -C infra/pulumi config set --stack "$ctx" gcp:project "$orig"
nagarectl context guard; echo "exit=$?"
```

Expected:

```text
refusing to run: Pulumi stack 'labs' targets project 'some-other-project', not the active context's project 'acme-prod'.
fix: re-project the stack config with 'nagarectl context use labs', or select the context that owns 'some-other-project'.
exit=1
...
exit=1
context guard: labs confined to project acme-prod (stack labs)
exit=0
```

Note that the `just infra-preview` run must stop *before* Pulumi runs; if you see Pulumi's
preview output, the recipe ordering is wrong.

Commit:

```text
feat(nagarectl): add `context guard` and preflight the Pulumi recipes with it

`just infra-up` had no project preflight at all: the selected stack's config was
the only guard on the most consequential command in the system. Add a command that
refuses when the stack's gcp:project, the ambient CLOUDSDK_CORE_PROJECT, or
gcloud's configured project disagrees with the active context, and run it from
infra-up and infra-preview.

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

### Milestone 5

```bash
cabal test nagarectl-test
nix build ".#checks.${system}.nagare-clone-free-platform"
git status --porcelain   # the rehearsal's default mode requires a clean worktree
bash scripts/rehearse-clone-free-release.sh --version 0.1.0 --output /tmp/rehearsal.json
jq -e '.checks | index("context-env") != null' /tmp/rehearsal.json
```

Expected from the last command:

```text
true
```

Commit:

```text
feat(nix): export the active context's Pulumi environment from the nagare launcher

A clone-free install has no .envrc, so recipes inherited whatever Pulumi state the
invoking shell carried — for an installed operator, none. Add
`nagarectl context env`, evaluate it in the launcher, and extend the clone-free
rehearsal to assert the backend and stack are the active context's.

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

### Milestone 6

```bash
just docs-validate
okf validate docs/improvement-requests \
  --strict \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Both must exit 0. Commit the documentation, the ADR, the IR acceptance and the registry row
as three commits mirroring how EP-112 was landed (`dc0e45b`, `cbee22d`, `0bd7c22`):

```text
docs(user): document the enforced project confinement

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

```text
docs(improvement-requests): accept IR-2 and link ExecPlan 113

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

```text
docs(plans): register EP-113 as a standalone plan

ExecPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
Intention: intention_01m2az59r0ejqtvw1mgvhe4d7f
```

Stage files by explicit path; do not use `git add -A` in this repository.

### Full check before declaring the plan complete

```bash
nix flake check
cabal test all
just docs-validate
```


## Validation and Acceptance

IR-2 names four required verifications. Each maps to a specific artifact in this plan, and
each must fail before the corresponding change and pass after it. Demonstrate that ordering
explicitly: write the test first, watch it fail, then make it pass.

**1. `Nagare.Ops.PulumiBackend` refuses on a project-number mismatch and proceeds on a
match.** The two behavioral cases added to `cli/nagarectl/test/Spec.hs` in Milestone 2. They
assert on the *recorded `gcloud` argv list*, not merely on the returned value, so the test
proves the update and IAM commands were never attempted rather than only that an error was
returned. Run with `cabal test nagarectl-test`.

**2. `build-local-image.sh` fails closed with no context loaded, instead of resolving a
project from `gcloud config`.** `scripts/test-image-build-guard.sh` from Milestone 3, case
two. The strongest available assertion is that the fake `gcloud` never received
`config get-value project`; assert that, and additionally that no `builds submit` was
attempted. Run with `bash scripts/test-image-build-guard.sh` or
`nix build .#checks.<system>.image-build-guard`.

**3. `infra-up` refuses when the selected stack's `gcp:project` disagrees with the active
context.** Two layers: the `projectGuardVerdict` unit table in `cli/nagarectl/test/Spec.hs`,
and the end-to-end fixture added to the `nagare-clone-free-platform` check in `flake.nix`,
both from Milestone 4. Confirm the recipe ordering by hand with the `just infra-preview`
transcript in Concrete Steps: the refusal must appear with no Pulumi output after it.

**4. `scripts/rehearse-clone-free-release.sh` covers a recipe run with no `.envrc` present
and asserts the Pulumi backend and stack are the active context's.** Milestone 5's addition,
verified by `jq -e '.checks | index("context-env") != null'` on the rehearsal's JSON output.

Beyond those four, the plan's own acceptance is the behavior stated in Purpose:

- With a cloud context `labs` declaring project `acme-prod`, and
  `CLOUDSDK_CORE_PROJECT=some-production-project` exported in the shell, every one of
  `scripts/upload-images.sh`, `cluster/bootstrap/auth-images/build-local-image.sh shomei`,
  `cluster/bootstrap/nagare-access/build-image.sh`, `nagarectl context guard`,
  `just infra-up` and `just infra-preview` exits non-zero with a message naming both
  projects, and none of them issues a mutating `gcloud`, `gsutil`, `docker push` or
  `pulumi up` call. Verify the "none of them issues" half by running each under a `PATH`
  whose `gcloud`/`gsutil`/`docker`/`pulumi` are the recording fakes from the new tests and
  inspecting the log.
- With the ambient override removed, all six succeed (or proceed to their real work) again.
- With a local-mode context selected, `just local-smoke` still passes and no `gcloud`
  invocation appears in its output — this is the regression that would indicate local mode
  had accidentally been made to require a GCP project.

Run the whole repository's checks at the end:

```bash
nix flake check
```

Every check must pass, including the pre-existing `shellcheck-scripts`,
`forge-credential-refresh`, `release-consistency-source`, `nagare-clone-free-platform`,
`examples-compile`, `nagarectl-external-config` and `github-actions`, plus the two added
here.


## Idempotence and Recovery

Every change in this plan is additive and safe to re-run.

The new Bash helper and the new Haskell assertion are pure preflights: they read two values
and either return or refuse. They mutate nothing, so running them repeatedly has no effect,
and a refusal leaves the system exactly as it was. That is the point — a refusal is a
*non-event*.

`_require_bucket_in_target_project` and its Haskell twin both add two `gcloud` reads to paths
that already make several. On a slow link this makes `nagarectl init` and
`scripts/upload-images.sh` marginally slower; no caching is introduced, because a cached
ownership answer is exactly the sort of stale assumption this plan exists to remove.

Making the state-bucket bootstrap fatal (Milestone 2) is the one behavior change that can
newly stop a command that used to complete. Recovery is to fix the cause the message names —
authenticate `gcloud`, grant the missing permission, or choose a state bucket name that is
globally unique by setting `NAGARE_PULUMI_BACKEND_URL` in the context — and re-run
`nagarectl init` or `nagarectl context use <name>`, both of which are idempotent. If an
operator needs to proceed without the GCS backend at all, they can set
`NAGARE_PULUMI_BACKEND=local` in the context, which makes the bootstrap a no-op. Nothing is
partially applied by a refusal: the assertion runs before the update and IAM steps, so the
bucket is left in whatever state it was in.

Milestone 3 can newly fail a build that previously succeeded by silently using the ambient
`gcloud` project. That is the intended behavior. Recovery is to select the right context
(`nagarectl context use <name>`) or to unset the conflicting `CLOUDSDK_CORE_PROJECT`; the
refusal message states both.

Milestone 4's `nagarectl context guard` calls `ensurePulumiForContext`, which creates
directories and selects (or initializes) the stack. Those operations are already idempotent
and are performed today by `.envrc` on every shell entry.

Milestone 5's launcher change is the riskiest to get wrong, because a broken `eval` would
break *every* recipe rather than one. Guard against that by testing the launcher through
`nix build .#checks.<system>.nagare-clone-free-platform` before committing, and note that
the failure mode is loud and immediate (the launcher exits before `just` runs), not silent.
If the launcher must be reverted, the recipes still work inside a `direnv`-loaded checkout,
and Milestone 4's guard still refuses a wrong project — so reverting M5 alone degrades
clone-free ergonomics without reopening the isolation hole.

Milestone 6 touches only documentation and metadata; re-running `just docs-validate` and the
OKF validation is free and idempotent.

If the plan must be abandoned partway, each milestone's commit stands alone: M1 and M2 close
the bucket holes independently of each other, M3 closes the build-script hole independently
of both, and M4–M5 close the Pulumi-recipe hole. No milestone depends on a later one to be
correct.


## Interfaces and Dependencies

### The shared bucket-ownership contract

Both implementations must satisfy the same contract, and the ADR written in M6 records it so
a future change updates both:

- **Inputs:** a GCS bucket name (no `gs://` prefix) and the active context's project id.
- **Reads:** `gcloud storage buckets describe gs://<bucket> --format=value(projectNumber)`
  and `gcloud projects describe <project> --format=value(projectNumber)`.
- **Verdict:** proceed only when both values are present, non-empty and equal. Any other
  outcome — either value absent, unreadable, or different — is a refusal.
- **Refusal message:** names the bucket, the observed owning project number (or `<unknown>`),
  the target project id and its number (or `<unknown>`), states that GCS bucket names are
  global, and gives a caller-specific remedy.
- **Local mode:** returns success immediately without invoking any tool.

### New Bash surface (`scripts/lib/target.sh`)

```bash
_require_bucket_in_target_project <bucket> [remedy-hint]   # returns 0 or 1
```

Callers: `scripts/migrate-pulumi-backend.sh` (`ensure_bucket`), `scripts/upload-images.sh`
(after the create-if-missing block, and inside `upload_if_missing`). The existing
`_require_target_project` is unchanged; new callers are
`cluster/bootstrap/auth-images/build-local-image.sh` and
`cluster/bootstrap/nagare-access/build-image.sh`.

### New Haskell surface

`cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs` gains these exports:

```haskell
bucketProjectNumberArgs :: Text -> [String]
projectNumberArgs :: Text -> [String]
bucketOwnershipVerdict :: Text -> Text -> Maybe Text -> Maybe Text -> Either Text ()
data GcloudOps = GcloudOps
  { gcloudCapture :: [String] -> IO (Maybe Text)
  , gcloudExec :: Text -> [String] -> IO (Either Text ())
  }
realGcloudOps :: GcloudOps
bootstrapPulumiStateBucketWith :: GcloudOps -> Bool -> Text -> TargetProfile -> Maybe Text -> IO (Either Text ())
```

`bootstrapPulumiStateBucket` keeps its existing type and becomes
`bootstrapPulumiStateBucketWith realGcloudOps`, so no other caller changes.

New module `cli/nagarectl/src/Nagare/Ops/ContextGuard.hs`:

```haskell
data ProjectGuardInputs = ProjectGuardInputs
  { pgiContext :: !Text
  , pgiDeclared :: !Text
  , pgiStack :: !Text
  , pgiStackProject :: !(Maybe Text)
  , pgiAmbient :: !(Maybe Text)
  , pgiConfigured :: !(Maybe Text)
  }
projectGuardVerdict :: ProjectGuardInputs -> Either Text ()
renderProjectGuard :: ProjectGuardInputs -> Text          -- the success line
```

Add the module to the `exposed-modules` list in `cli/nagarectl/nagarectl.cabal` (the library
stanza) so the test suite can import it.

`cli/nagarectl/src/Nagare/Target.hs` gains:

```haskell
renderContextShellEnv :: ContextName -> TargetProfile -> PulumiEnv -> Text
```

added to the module's export list beside the existing `pulumiEnvFor`.

### New CLI surface

```text
nagarectl context guard [--context NAME] [--json]
nagarectl context env   [--context NAME]
```

`context guard` exits 0 with a one-line confirmation, or non-zero with a refusal naming both
compared values. `context env` prints shell-quoted `export K=V` lines and nothing else, and
is safe to `eval`.

### Test surface

- `scripts/test-bucket-ownership-guard.sh` — new, registered in `flake.nix` `checks` as
  `bucket-ownership-guard`.
- `scripts/test-image-build-guard.sh` — new, registered as `image-build-guard`.
- `cli/nagarectl/test/Spec.hs` — new cases in the `Nagare.Ops.PulumiBackend` group, a new
  `Nagare.Ops.ContextGuard` group, and a `renderContextShellEnv` case beside the existing
  `pulumiEnvFor` tests.
- `flake.nix` — `shellcheck-scripts` extended to the two `cluster/bootstrap` scripts;
  `nagare-clone-free-platform`'s fake `pulumi` extended with a `config get gcp:project`
  branch and two guard invocations.
- `scripts/rehearse-clone-free-release.sh` — the `context-env` assertions and the new
  entry in its `checks` array.

### External tools relied on

`gcloud` (for `storage buckets describe`, `projects describe`, `config get-value project`,
`builds submit`, `auth configure-docker`), `gsutil` (bucket create, stat, copy), `pulumi`
(`config get`, `stack select`, `preview`, `up`), `docker`, `just`, `nix`, `jq`, `okf` and
`shellcheck`. All are provided by the project's development shell (`flake.nix`
`devShells.default`) and, for the packaged launcher, by the `runtimeInputs` of
`nagareLauncher` in `nix/haskell-packages.nix`. No new external dependency is introduced.

### Haskell libraries used

`text`, `process` (`readProcessWithExitCode`, and its `CreateProcess` `env` field for the
stripped-environment `gcloud` read), `cradle` (the existing `cmd`/`run`/`addArgs` wrapper
used by `runGcloud` and `Nagare.Ops.Probe.captureTool`), and for the tests `tasty`,
`tasty-hunit` and `Data.IORef` from `base`. All are already
dependencies of `nagarectl` or `nagarectl-test` in `cli/nagarectl/nagarectl.cabal`; no new
dependency is added.
