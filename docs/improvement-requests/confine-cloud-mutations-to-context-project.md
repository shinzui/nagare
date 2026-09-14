---
type: Improvement Request
title: Confine every cloud-mutating path to the active context's project
description: Close four paths where a globally-unique name or an ambient gcloud default can direct a write outside the selected context's GCP project.
timestamp: "2026-09-12T15:12:35Z"
generated:
  by: process:claude-code
  at: "2026-09-12T12:35:03Z"
requestId: IR-2
status: completed
completedAt: "2026-09-12T15:12:35Z"
resolution: "EP-113 added _require_bucket_in_target_project to scripts/lib/target.sh and called it from scripts/migrate-pulumi-backend.sh and scripts/upload-images.sh, made Nagare.Ops.PulumiBackend refuse a state bucket whose owning project number is not the target's and made that bootstrap failure fatal to nagarectl init, put both cluster/bootstrap image-build scripts under _require_target_project with the gcloud config fallback removed, added nagarectl context guard as the infra-up / infra-preview preflight, and made the nagare launcher export the active context's Pulumi environment via nagarectl context env. All four requested verifications are held by nix flake check (bucket-ownership-guard, image-build-guard, the extended nagare-clone-free-platform, the Nagare.Ops.PulumiBackend and Nagare.Ops.ContextGuard unit tests) and scripts/rehearse-clone-free-release.sh. Recorded as ADR 9."
targetPlan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-12T15:12:35Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against ExecPlan 113's progress and acceptance
      evidence plus the current project, bucket, image-build, Pulumi, launcher,
      and regression-check surfaces; the completed status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: confine every cloud-mutating path to the active context's project

**Authored by:** a pre-flight isolation audit of `v0.1.0` (HEAD `da24748`) performed before
onboarding a new cloud context into a GCP organization that also contains production projects.
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by [ExecPlan 113](../plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md);
the durable decision is recorded as [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md).
**Created:** 2026-09-12.


## Why

Nagare's project targeting is structurally sound: the Pulumi program creates twenty-five resource
types, every one project-scoped, with no organization, folder, billing, shared-VPC or peering
resources, no `gcp.Provider` override, no `import:` option that could adopt a pre-existing object,
and `infra/pulumi/index.ts:9` using `gcpCfg.require("project")` so that a stack without
`gcp:project` aborts rather than falling back. Every IAM grant is the non-authoritative `*IAMMember`
form; there is no `*IAMPolicy` or `*IAMBinding` anywhere in the repository.

That makes the remaining exceptions worth closing, because they are the whole of the residual risk.
Four paths can currently direct a write outside the selected context's project. None requires
operator error that looks reckless — each is reachable from an ordinary command run in an ordinary
shell. An operator installing Nagare into an organization that also holds production projects has no
way to see these from the documentation.

The consequence is not hypothetical for the most severe one: an operator whose `gcloud config` still
points at a production project, running the auth-stack image build outside a loaded context, submits
a Cloud Build job into that production project.


## What is missing

**1. The Pulumi state bucket is addressed by its global name without a project assertion.**
`cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs:139-149` describes the bucket, skips creation when it
exists, and then runs the update and IAM steps:

```haskell
runBootstrap bucket project location mMember = do
  exists <- gcloudDescribeOk (bucketDescribeArgs bucket)
  createStep <- if exists then pure (Right ()) else runGcloud (...) (bucketCreateArgs bucket project location)
  chain createStep $ chainIO (runGcloud ("update bucket gs://" <> bucket) (bucketUpdateArgs bucket)) $ ...
```

`bucketCreateArgs` carries `--project` (`:73`), but `bucketUpdateArgs` (`:82-91`) and `bucketIamArgs`
(`:95-103`) do not. GCS bucket names are globally unique, so if `<project>-nagare-pulumi-state`
already exists in a foreign project the operator can describe, the describe succeeds, creation is
skipped, and `gcloud storage buckets update` rewrites that foreign bucket's versioning, uniform
bucket-level access and public-access-prevention settings.

The shell implementation of the same routine already has the assertion this path needs —
`scripts/migrate-pulumi-backend.sh:114-125`:

```bash
  # GCS bucket names are GLOBAL: a same-named bucket may exist in a FOREIGN
  # project, and describe/update/IAM would mutate someone else's bucket. Assert
  # the bucket's owning project number equals the target project's before any
  # update, IAM change, or state import.
  bucket_pn="$(gcloud storage buckets describe "gs://${bucket}" --format='value(projectNumber)' ...)"
```

Compounding it, `cli/nagarectl/app/Main.hs:2686-2694` downgrades a failure of this bootstrap to a
warning rather than an error, so a partially-applied bootstrap does not stop `nagarectl init`.

**2. `scripts/upload-images.sh` has the same gap for the image bucket.** It runs `gsutil ls -b`
then `gsutil mb` (`:60-62`) and later `gsutil cp` (`:102`) against `${NAGARE_IMAGE_BUCKET}` with no
project-number assertion, so a pre-existing foreign bucket of that name would receive the host
image tarball.

**3. Two image-build scripts fall back to the ambient gcloud default project.**
`cluster/bootstrap/auth-images/build-local-image.sh:71-75`:

```bash
project="${CLOUDSDK_CORE_PROJECT:-}"
if [[ -z "$project" && "$mode" != "local" ]]; then
  project="$(gcloud config get-value project 2>/dev/null || true)"
fi
```

and then `:310-315` runs `gcloud builds submit … --project "$project"`, with the pushed image name
derived from the same value. `cluster/bootstrap/nagare-access/build-image.sh:18` shares the
fallback. Neither script sources `scripts/lib/target.sh`, so neither is covered by
`_require_target_project`.

**4. `infra-up` performs no project preflight, and the launcher does not export the context.**
`justfile:53-56` is:

```make
infra-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    cd infra/pulumi && pulumi up
```

`nagarectl platform guard` checks release-version compatibility only
(`cli/nagarectl/src/Nagare/Platform/Status.hs:160-164`); it never consults the resolved target
profile. So the selected Pulumi stack's config is the single guard on the most consequential
command in the system. Meanwhile the launcher (`nix/haskell-packages.nix:69-79`) exports only
`NAGARE_PLATFORM_ROOT` and `NAGARE_WORKSPACE_ROOT` — not `PULUMI_HOME`, `PULUMI_BACKEND_URL` or a
stack selection — because the design assumes the invoking shell already carries them, which held
for `direnv`-loaded checkouts and does not hold for clone-free installs.

`_require_target_project` (`scripts/lib/target.sh:276-330`) is the pattern that works, and it is
worth preserving as-is: it cross-checks with `env -u CLOUDSDK_CORE_PROJECT gcloud config get-value
project`, so the environment cannot shadow the check into a tautology.


## Requested change

Give every cloud-mutating path the same project confinement the guarded shell scripts already have:

- Extract the project-number assertion from `scripts/migrate-pulumi-backend.sh` into a single shared
  helper, and call it from `Nagare.Ops.PulumiBackend` before any `buckets update` or
  `add-iam-policy-binding`, and from `scripts/upload-images.sh` before `mb` or `cp`. A bucket whose
  owning project number differs from the target's must abort the operation, not warn.
- Make the state-bucket bootstrap failure fatal to `nagarectl init` rather than a warning, or make
  `init` report a non-zero exit with the backend left unconfigured.
- Bring `cluster/bootstrap/auth-images/build-local-image.sh` and
  `cluster/bootstrap/nagare-access/build-image.sh` under `_require_target_project`, and remove the
  `gcloud config get-value project` fallback entirely. An unset context should fail closed.
- Give `infra-up` and `infra-preview` a project preflight that compares the selected stack's
  `gcp:project` against the active context's project and refuses on mismatch.
- Have the launcher export the resolved context's `PULUMI_HOME`, `PULUMI_BACKEND_URL` and stack
  selection before invoking a recipe, so clone-free operation matches the `direnv` behavior the
  recipes were written against. If that is undesirable, have each Pulumi-invoking recipe resolve the
  context itself.


## Required verification

- A test proving `Nagare.Ops.PulumiBackend` refuses when the named bucket's project number differs
  from the target's, and proceeds when it matches.
- A test proving `build-local-image.sh` fails closed with no context loaded, instead of resolving a
  project from `gcloud config`.
- A fixture proving `infra-up` refuses when the selected stack's `gcp:project` disagrees with the
  active context.
- An extension of `scripts/rehearse-clone-free-release.sh`, which today exercises only
  `--dry-run infra-preview`, to cover a recipe run with no `.envrc` present and assert the Pulumi
  backend and stack are those of the active context.


## Acceptance

An operator with a production project selected in `gcloud config`, running any Nagare command from
any directory with a context active, cannot cause a create, update or delete outside that context's
project — and when the configuration is ambiguous the command refuses rather than choosing. The
`docs/user/gcp-prerequisites.md` promise that Nagare confines itself to one project becomes
enforced by code on every path, not only on the guarded ones.


## Non-goals

This request does not ask for cross-project support, per-resource project overrides, a change to
the non-authoritative IAM model, or new isolation between contexts beyond the project boundary that
already exists. It does not ask to remove the `tan-nb-exp` built-in defaults, which are addressed
separately by IR-3.
