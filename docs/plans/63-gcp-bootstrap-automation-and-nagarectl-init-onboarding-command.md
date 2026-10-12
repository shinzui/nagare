---
id: 63
slug: gcp-bootstrap-automation-and-nagarectl-init-onboarding-command
title: "GCP bootstrap automation and nagarectl init onboarding command"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# GCP bootstrap automation and nagarectl init onboarding command

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [63-gcp-bootstrap-automation-and-nagarectl-init-onboarding-command.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/63-gcp-bootstrap-automation-and-nagarectl-init-onboarding-command.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

**nagare** is a single-node personal Platform-as-a-Service that runs on one Google Cloud
Platform (GCP) virtual machine. Until the broader "bring your own GCP project" initiative
(MasterPlan 12, `docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`), it
was welded to one project, `tan-nb-exp`, in region `us-west1`. Two prerequisite plans have since
made the GCP target configurable: **EP-60** defined a single git-ignored file `nagare.target.env`
that holds the operator's GCP target as `export VAR=value` shell lines (the "target profile"), and
**EP-62** added a Haskell module `Nagare.Target` to the `nagarectl` command-line tool that resolves
that same target from the process environment into a typed record, `TargetProfile`.

What is still missing is the *front door*. Today, an operator who wants to stand nagare up on a
fresh GCP project must, by hand: figure out which GCP service APIs to turn on (a step that bit the
very first bootstrap — see Context and Orientation), hand-write `nagare.target.env`, and hand-edit
the Pulumi stack configuration so the infrastructure program targets their project. There is no
single guided command, and the two operator-facing facts that were *only documented, never codified*
— the required API list and the Pulumi-config seeding — are easy to get wrong.

This plan delivers that front door. After it is complete, an operator with a clean GCP project and
a domain runs **one guided command** and is ready to provision:

```text
$ nagarectl init
Checking gcloud authentication...           OK  (you@example.com)
Checking operator IAM roles on acme-prod...  OK
GCP project id [tan-nb-exp]: acme-prod
Compute region [us-west1]:
Compute zone [us-west1-a]:
Apps base domain [apps.example.com]: apps.acme.com
Wrote nagare.target.env
Enabling GCP service APIs (compute, dns, storage, artifactregistry, iam)... done
Seeding Pulumi stack config from the profile... done

Next steps:
  1.  just infra-up        # create the GCP resources (VM omitted until the image exists)
  2.  just host-image      # build + register the NixOS image, write its self-link to Pulumi
  3.  just infra-up        # re-run to create the VM now that the image self-link is set
  4.  just cluster-bootstrap   # install the in-cluster platform (see docs)
```

Concretely, the user-visible behaviors you will be able to demonstrate at the end are:

- A new shell script `scripts/enable-apis.sh` that codifies the GCP service-API list and, after
  it runs, `gcloud services list --enabled` reports `compute`, `dns`, `storage`,
  `artifactregistry`, `iam`, and `servicenetworking` are enabled on the configured project.
- A new `nagarectl init` subcommand that, run **non-interactively**
  (`nagarectl init --project acme-prod --region us-west1 --base-domain apps.acme.com`), writes a
  correct `nagare.target.env` (refusing to clobber an existing one without `--force`), enables the
  APIs, seeds the Pulumi stack config with the eight keys the infrastructure program reads, and
  prints the ordered next-step commands. Re-running it is safe (idempotent).
- A **preflight** that fails with a clear, actionable message when `gcloud` is not authenticated or
  when the active account lacks an operator IAM role needed to provision — before anything is
  written or any API is touched.

This plan is the product surface (MasterPlan 12, Wave 3). It **hard-depends on EP-62** because
`nagarectl init` is a new subcommand in the same `optparse-applicative` command tree and reuses
EP-62's `TargetProfile` record and its resolution code. It **hard-depends on EP-60** because the
file it writes is EP-60's `nagare.target.env` contract. It **soft-depends on EP-61** (the shell-script
parameterization) because the guided flow invokes `scripts/enable-apis.sh`, which sources EP-60's
`scripts/lib/target.sh`; if EP-61 is not yet done, `init` still works because the helper EP-60
ships is all `enable-apis.sh` needs. This plan is the **one place** in the whole system permitted to
drive Pulumi (`pulumi config set`) and to call `gcloud services enable`; every other `nagarectl`
command reads its target purely from the environment and never touches Pulumi (MasterPlan 12,
Decision Log).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirmed prerequisites: `cli/nagarectl/src/Nagare/Target.hs` exposes `TargetProfile (..)` and
      `resolveTargetProfile` (EP-62); `scripts/lib/target.sh` has `_require_target_project` /
      `TARGET_PROJECT` (EP-60). Both Complete. (2026-06-10)
- [x] M1.1 — Created `scripts/enable-apis.sh` (executable): sources `scripts/lib/target.sh`, runs
      `_require_target_project`, enables the six-API set with explicit `--project`, honors
      `NAGARE_ENABLE_APIS_DRY_RUN=1`. `bash -n` clean; dry-run prints the exact argv. (2026-06-10)
- [x] M1.2 — Added six `gcp.projects.Service` resources to `infra/pulumi/index.ts`
      (`disableDependentServices`/`disableOnDestroy` false) and threaded `{ dependsOn: apiServices }`
      into the `NagarePerimeter` options. `tsc --noEmit` clean. (2026-06-10)
- [x] M1.3 — Verified: `NAGARE_ENABLE_APIS_DRY_RUN=1 bash scripts/enable-apis.sh` matches the Step
      M1.3 transcript; `tsc --noEmit` typechecks the Pulumi program. (Real `gcloud services enable`
      against a foreign project deferred — no such project available this session.) (2026-06-10)
- [x] M2.1 — Created `cli/nagarectl/src/Nagare/Init.hs`: `InitOpts`, `profileFromOpts` (reuses
      `resolveTargetProfile`), `renderTargetEnv`, idempotent `writeTargetEnv` (`--force`),
      `seedKeys`/`pulumiConfigSetArgs`/`seedPulumiConfig`, `enableApis`, `runPreflight`,
      `nextStepsText`, `operatorRoles`. Registered in `nagarectl.cabal`. Library builds. (2026-06-10)
- [x] M2.2 — Wired `init` into `app/Main.hs`: `Init InitOpts` constructor, `initOptsParser`,
      `command "init" initCmd`, `Init o -> runInit o` dispatch, `Nagare.Init` import. (2026-06-10)
- [x] M2.3 — Non-interactive path + idempotent write verified: `init --project acme-prod --region
      us-west1 --base-domain apps.acme.com --skip-preflight --dry-run --force` prints the rendered
      profile, the enable-apis dry-run argv, and the eight `pulumi config set` argv, writing nothing;
      a real write then a re-run without `--force` refuses (exit 1), with `--force` overwrites. (2026-06-10)
- [x] M2.4 — Interactive vs non-TTY: `resolveField` prompts on a TTY with defaults; non-TTY requires
      only `--project` (region/zone/base-domain fall back to EP-60 defaults — matching the M2
      acceptance that omits `--zone`), erroring clearly if `--project` is absent. (2026-06-10)
- [x] M3.1 — Preflight: `gcloud auth list` for an active account + `gcloud projects get-iam-policy`
      (flattened, filtered by the active user) for the six operator roles, `roles/owner`
      short-circuits, precise remediation, `--skip-preflight` escape hatch. Verified the auth-failure
      path with an empty `CLOUDSDK_CONFIG`. (2026-06-10)
- [x] M3.2 — `runInit` wires the ordered flow (resolve → preflight → write → enable → seed →
      next-steps); each side-effecting stage is `--skip-*`-able and safe to re-run. (2026-06-10)
- [x] M3.3 — Added the `Nagare.Init (EP-63)` test group (env rendering, the eight seed keys,
      `pulumiConfigSetArgs`, `operatorRoles`, next-steps); `cabal test` green (258 tests). (2026-06-10)
- [x] M3.4 — End-to-end (non-interactive) acceptance demonstrated via dry-run + real-write +
      preflight-failure transcripts. The real `pulumi config get gcp:project` step is intentionally
      NOT run: it would overwrite the committed `tan-nb-exp` `Pulumi.dev.yaml` worked example; the
      dry-run printed the exact `pulumi -C infra/pulumi config set` argv for all eight keys as the
      seed evidence. (2026-06-10)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Field-name collision (resolved): `Nagare.Ops.Probe.InventoryOpts` already exports an `ioZone`
  selector, which collides with `InitOpts.ioZone`. With `DuplicateRecordFields` on, the records
  coexist, but the bare selector `ioZone` is ambiguous when used. Resolved by deriving `Generic` on
  `InitOpts` and accessing its fields in `runInit` via generic-lens labels (`o ^. #ioZone`) — the
  repo idiom for every other `*Opts` record — which disambiguates by type. (2026-06-10)
- Non-interactive requiredness (refined against the M2 acceptance): the plan's Decision Log said a
  non-TTY run "without them errors" but the M2 acceptance command omits `--zone` and expects the
  `us-west1-a` default. Reconciled: only `--project` is mandatory in non-interactive mode (no safe
  default for "your project"); `--region`/`--zone`/`--base-domain` fall back to their EP-60 defaults.
  `resolveField` takes a `required` flag accordingly. (2026-06-10)
- CWD convention: `enableApis` runs `bash scripts/enable-apis.sh` and the seed/profile paths
  (`nagare.target.env`, `infra/pulumi`) are all repo-root-relative — the same convention every other
  nagarectl command already uses (e.g. `stackOutput "infra/pulumi"`). `init` must be run from the
  repo root; `cabal run` from the package dir fails to find the script (CWD = package dir), so the
  acceptance was run via the built binary from the repo root. (2026-06-10)
- `OverloadedStrings` made the bare `addArgs ["scripts/enable-apis.sh"]` literal list ambiguous
  (cradle's `addArgs` is polymorphic over `ConvertibleStrings`); annotated it `:: [String]`. (2026-06-10)

## Decision Log

Record every decision made while working on the plan.

- Decision: codify API enablement in **both** a shell script (`scripts/enable-apis.sh`) **and**
  Pulumi (`gcp.projects.Service` resources in `infra/pulumi`), rather than picking one.
  Rationale: the two cover different moments and different failure modes. The shell script is what
  `nagarectl init` calls *before* the first `pulumi up`, solving the original bootstrap
  chicken-and-egg the EP-2 surprise records (Artifact Registry and the service account cannot be
  created until `artifactregistry`/`iam` are enabled, but `pulumi up` is what creates them — so the
  enablement must happen out-of-band first). The Pulumi `Service` resources make the stack
  *self-describing and self-healing*: a later `pulumi up` re-asserts the APIs, and a fresh project
  that someone provisions without `init` still self-enables. Pulumi sequences this correctly with an
  explicit `dependsOn` from the API-dependent resources to the `Service` resources, and each
  `Service` is created with `disableDependentServices: false` / `disableOnDestroy: false` so a
  `pulumi destroy` never turns an API off under a foreign project's other workloads. Both paths
  enable the identical list, so there is no drift. See Integration Point analysis in Context and
  Orientation.
  Date: 2026-06-10

- Decision: `nagarectl init` shells out to `gcloud` and `pulumi` via the repo's `cradle` process
  library for every cloud/Pulumi side effect (auth check, IAM check, `services enable`,
  `config set`), rather than using a GCP client library such as `gogol`.
  Rationale: every other external-tool interaction in `nagarectl`
  (`Nagare.Ops.Probe.captureTool`, `Nagare.Ops.Pulumi.stackOutput`, `Nagare.Image.configureDockerAuth`)
  already shells out through `cradle`; matching that idiom keeps the toolchain consistent, inherits
  the operator's existing `gcloud` ADC credentials with zero extra auth plumbing, and avoids pulling
  a large generated API binding into the build. `cradle` does not invoke a shell (it `fork`/`exec`s
  directly with an argv list), so there is no quoting/injection risk. This also means `init` needs no
  new cabal dependency — the library already depends on `cradle`, `directory`, and `text`.
  Date: 2026-06-10

- Decision: interactive prompting is done with plain `getLine`/`putStr` on `stdin`/`stdout`, guarded
  by `System.IO.hIsTerminalDevice stdin`; a non-interactive invocation must supply the required
  values as flags (`--project` at minimum), and a non-TTY run without them errors with a clear
  message rather than hanging on a blocked read.
  Rationale: `app/Main.hs` already imports `System.IO (hIsTerminalDevice, hFlush, hSetEcho, ...)` and
  uses exactly this TTY-detection pattern elsewhere (the secret-value prompt), so the idiom and the
  imports already exist. A typed prompt library would be overkill for four string prompts with
  defaults.
  Date: 2026-06-10

- Decision: the operator IAM roles the preflight verifies are `roles/compute.admin`,
  `roles/dns.admin`, `roles/artifactregistry.admin`, `roles/storage.admin`,
  `roles/iam.securityAdmin`, and `roles/serviceusage.serviceUsageAdmin`. The check is "does the active
  account (or a group/role it is in) grant these on the project", verified by reading the project IAM
  policy with `gcloud projects get-iam-policy ... --flatten=bindings ... --filter=...`. A
  `roles/owner` binding for the account short-circuits to pass.
  Rationale: these are exactly the admin roles needed to create the resource topology the Pulumi
  program builds (Compute VM/IP/disks, Cloud DNS zone/records, Artifact Registry repo, GCS buckets,
  a service account with IAM bindings) plus the `serviceUsageAdmin` needed to *enable* the APIs in
  the step before. Owner trivially includes all of them, so it is accepted directly. See Concrete
  Steps M3.1 for the exact gcloud invocation and why `get-iam-policy` is preferred over
  `testIamPermissions` here.
  Date: 2026-06-10

- Decision: `init` resolves the *defaults* for its prompts from `Nagare.Target.resolveTargetProfile`
  (so an operator re-running `init` sees their current profile values as the prompt defaults), and
  constructs the *result* as a `TargetProfile` it serializes to `nagare.target.env`. The derived
  fields (registry host, buckets) follow the EP-60 derivations exactly, computed by reusing
  `resolveTargetProfile` with the chosen project/region exported into the environment for the
  resolution.
  Rationale: this keeps one resolution code path (EP-62's) and one set of derivation rules, so the
  file `init` writes and the values the rest of the CLI later reads are byte-identical (MasterPlan
  12 Integration Point 1).
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-63 delivered the onboarding front door. `scripts/enable-apis.sh` and the six
`gcp.projects.Service` resources codify API enablement (the EP-2 surprise) in both the
out-of-band script `init` calls and the self-asserting Pulumi program. `nagarectl init` is a
real subcommand that preflights gcloud auth + operator IAM, resolves the target from flags or TTY
prompts, writes a byte-correct `nagare.target.env` (idempotent, `--force`-guarded), runs the enable
script, seeds the eight Pulumi keys, and prints the ordered next steps — every side-effecting stage
individually skippable, the whole command safe to re-run, and the only command in nagarectl that
drives Pulumi/gcloud.

Acceptance demonstrated by observable behavior: the full `--dry-run` transcript (enable argv with
`--project=acme-prod`, the rendered nine-line profile with the EP-60 derivations, all eight `pulumi
config set` argv, the next-steps block, nothing written); a real write followed by a `--force`-less
re-run that refuses and exits 1; the auth-failure preflight printing its remediation under an empty
`CLOUDSDK_CONFIG`; and the `Nagare.Init` unit group (env rendering, seed keys, config-set argv,
`operatorRoles`, next-steps) green within `cabal test` (258 tests). The real `pulumi config get`
round-trip (A4) was deliberately not run because it would overwrite the committed `tan-nb-exp`
`Pulumi.dev.yaml` worked example; the dry-run argv is the seed evidence.

Deviations (Decision Log / Surprises): `InitOpts` fields are accessed via generic-lens labels to
dodge the `ioZone` collision with `InventoryOpts`; only `--project` is mandatory non-interactively
(region/zone/base-domain default), reconciling the Decision Log with the M2 acceptance; `init` is
repo-root-CWD-relative like every other command. No real foreign GCP project was available, so the
live `gcloud services enable` and the IAM-missing-role preflight branch were verified by transcript
reasoning rather than a live call.

