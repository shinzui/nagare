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


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing. All paths
are repository-relative to `/Users/shinzui/Keikaku/bokuno/nagare`.

### Terms of art (defined in plain language)

- **`nagarectl`** — the Haskell command-line program operators run to deploy apps, take backups,
  check platform health, and (after this plan) onboard a fresh GCP project. Its library code lives
  under `cli/nagarectl/src/`, its `main` entry point at `cli/nagarectl/app/Main.hs`, its tests at
  `cli/nagarectl/test/Spec.hs`, and its build description at `cli/nagarectl/nagarectl.cabal`.

- **GCP / Google Cloud Platform** — the cloud nagare runs on. A **GCP project** is the top-level
  container for cloud resources, identified by a project id like `tan-nb-exp` or `acme-prod`.

- **target profile** — a single git-ignored file `nagare.target.env` at the repo root holding the
  operator's GCP target (project id, region, zone, Artifact Registry host and id, image bucket,
  backup bucket, base domain, VM instance name) as plain `export VAR=value` shell lines. It is the
  single source of truth for *which* GCP project nagare acts on. It was defined by the prerequisite
  plan EP-60 (`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`); a
  tracked sibling `nagare.target.env.example` documents the schema. This plan **writes** that file
  (the first writer of it).

- **`TargetProfile`** — the Haskell record (in `cli/nagarectl/src/Nagare/Target.hs`, created by
  EP-62) that holds the fully-resolved GCP target. Its fields are `tpProject`, `tpRegion`, `tpZone`,
  `tpRegistryHost`, `tpArtifactRegistryId`, `tpImageBucket`, `tpBackupBucket`, `tpBaseDomain`,
  `tpInstanceName`, all `Text`. The function `resolveTargetProfile :: IO TargetProfile` reads the
  nine environment variables (with EP-60's defaults and `<region>-docker.pkg.dev` /
  `<project>-nagare-*` derivations) and returns the record. This plan **reuses** that record and that
  function — it does not redefine them.

- **ADC / Application Default Credentials** — the credentials `gcloud` (and the Pulumi GCP provider)
  use to authenticate to GCP without an explicit key file. An operator establishes them by running
  `gcloud auth login` (for the human account) and `gcloud auth application-default login` (for tools).
  When this plan says "check gcloud is authenticated," it means: confirm there is an *active*
  authenticated account, which `gcloud auth list` reports. A fresh machine with no login has no
  active account, and every subsequent `gcloud`/Pulumi call would fail — the preflight catches that
  early with a clear message.

- **IAM role** — IAM (Identity and Access Management) is GCP's permission system. A **role** is a
  named bundle of permissions (e.g. `roles/compute.admin` lets you create and manage Compute Engine
  resources). A role is **granted** to a member (a user, group, or service account) **on** a project
  via an *IAM binding* in the project's IAM policy. The preflight verifies the active account holds
  the admin roles needed to create nagare's resources; without them, `pulumi up` would fail partway
  with an opaque permission error, so checking up front is far kinder.

- **service API enablement** — every GCP feature is exposed by a *service API* identified by a
  hostname like `compute.googleapis.com`. On a brand-new project most APIs are **off** and must be
  turned on once with `gcloud services enable <api> --project=<id>` before any resource using that
  API can be created. This is the step the original bootstrap got bitten by (see below); this plan
  codifies it so it is never a surprise again.

- **optparse subcommand** — `nagarectl` parses its command line with the `optparse-applicative`
  Haskell library. The top-level commands (`deploy`, `site`, `db`, `doctor`, …) are declared in
  `app/Main.hs` as a `subparser` of `command "<name>" <parserInfo>` entries, each producing a value
  of the `data Command` type, which `main` then dispatches in a `case` (the "run dispatcher"). Adding
  `init` means adding one `command "init" …` entry, one `Init InitOpts` constructor to `data Command`,
  and one `Init o -> runInit o` arm to the dispatcher — the same idiom every existing subcommand
  follows.

- **Pulumi stack config** — Pulumi is the infrastructure-as-code tool that creates nagare's GCP
  resources. Its program lives in `infra/pulumi/index.ts`; its per-stack configuration (a set of
  `key: value` pairs) lives in `infra/pulumi/Pulumi.dev.yaml` and is read by the program at the top
  of `index.ts`. You set a config value with `pulumi config set <key> <value>` (run from
  `infra/pulumi/`, or with `pulumi -C infra/pulumi config set …`). The keys the program reads are
  `gcp:project`, `gcp:region`, `gcp:zone`, `nagare:baseDomain`, `nagare:imageBucket`,
  `nagare:backupBucket`, `nagare:artifactRegistryId`, and `nagare:instanceName`. The "config set"
  step in `init` writes these eight from the resolved profile.

- **idempotent** — an operation is *idempotent* when running it again produces the same end state
  with no harm: re-running `nagarectl init` re-checks auth and IAM, re-writes (or, without `--force`,
  refuses to overwrite) the same profile, re-enables already-enabled APIs (a no-op), and re-seeds the
  same Pulumi config values. Nothing is duplicated or corrupted by a second run.

- **`cradle`** — the Haskell process-running library this repo uses to shell out. You build a command
  with `cmd "exe" & addArgs ["a","b"]` and run it with `run` (capturing output, polymorphic in the
  return type) or `run_` (discarding output). It does **not** invoke a shell — it `fork`/`exec`s
  directly with an argv list, so there is no quoting or injection concern. The existing helper
  `Nagare.Ops.Probe.captureTool :: String -> [String] -> IO (Maybe ByteString)` wraps `run` to return
  `Just` the stdout on success and `Nothing` on failure or a missing binary; `init` reuses exactly
  this helper for its read-only `gcloud` queries, and uses a small "run and report exit code" wrapper
  for the side-effecting `services enable` / `config set` calls (Concrete Steps M2.1).

### Why API enablement matters here — the EP-2 surprise (verbatim context)

MasterPlan 1 (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) records, in its Surprises
section, that the original bootstrap hit a wall:

> EP-2: the shared `tan-nb-exp` project did not have all required GCP service APIs enabled.
> `compute`, `dns`, and `storage` were on, but `artifactregistry.googleapis.com` and
> `iam.googleapis.com` were off and had to be enabled with
> `gcloud services enable ... --project=tan-nb-exp` before `pulumi up` could create the Artifact
> Registry repo and the service account.

On a *brand-new* project, even `compute`, `dns`, and `storage` may be off. This plan therefore
codifies the full set the Pulumi program needs: `compute.googleapis.com` (the VM, static IP, disks),
`dns.googleapis.com` (the Cloud DNS zone and records), `storage.googleapis.com` (the image and backup
GCS buckets), `artifactregistry.googleapis.com` (the container-image repository), `iam.googleapis.com`
(the node service account and its bindings), and `servicenetworking.googleapis.com` (included
defensively because private-services networking is commonly needed and enabling an already-on or
unused API is harmless — see Idempotence and Recovery).

### The command tree this plan extends (where `init` is wired)

`app/Main.hs` declares every command in a `data Command` sum type (around lines 291–316) and a
top-level `subparser` (around lines 972–988) where each `command "<name>" <cmd>` binds a name to a
`ParserInfo Command`. The `main` function (around lines 1418–1445) pattern-matches the parsed
`Command` and calls the matching `run*` handler. The existing `doctor` command is the simplest
template to copy: one constructor `Doctor DoctorOpts`, one `command "doctor" doctorCmd`, and one
`Doctor o -> runDoctor o` arm. `init` follows the same shape.

The handler `runInit` will resolve a `TargetProfile` for prompt defaults via
`Nagare.Target.resolveTargetProfile` (the EP-62 function), and use the `cradle`-based helpers for all
external calls. `app/Main.hs` already imports `System.IO (hFlush, hSetEcho, hIsTerminalDevice, stderr, stdin)`,
`System.Environment (lookupEnv, setEnv)`, `System.Directory (doesFileExist, makeAbsolute)`, and
`System.Exit (exitFailure, exitWith, ExitFailure)` — every IO primitive `init` needs is already in
scope, so no new import beyond `Nagare.Init` and `Nagare.Target` is required in `Main.hs`.

### What the Pulumi program reads (the keys `init` seeds)

`infra/pulumi/index.ts` reads its GCP target entirely from stack config (verified by reading the file):

```typescript
const gcpProject = gcpCfg.require("project");   // gcp:project
const region = gcpCfg.require("region");        // gcp:region
const zone = gcpCfg.require("zone");            // gcp:zone
const instanceNameCfg = cfg.get("instanceName") ?? "nagare-01";
const baseDomainCfg = cfg.get("baseDomain") ?? "apps.example.com";
const artifactRegistryIdCfg = cfg.get("artifactRegistryId") ?? "nagare";
const backupBucketNameCfg = cfg.get("backupBucket") ?? `${gcpProject}-nagare-backups`;
const imageBucketNameCfg = cfg.require("imageBucket"); // set in Pulumi.dev.yaml — REQUIRED, no default
```

Two keys are `require` (`gcp:project`, `gcp:region`, `gcp:zone` and `nagare:imageBucket`) — Pulumi
*errors* if they are unset — and the rest have defaults. **`nagare:imageBucket` has no default and is
mandatory**, so `init` must always seed it (and `gcp:project`/`region`/`zone`), or the operator's first
`pulumi up`/`preview` fails with a "Missing required configuration variable 'imageBucket'" error. The
committed `Pulumi.dev.yaml` keeps the `tan-nb-exp` values as the worked example; a new operator's
config is generated by `init`, not the committed file (MasterPlan 12 Integration Point 3).

The eight keys `init` seeds and their `TargetProfile` source field:

```text
gcp:project               <- tpProject
gcp:region                <- tpRegion
gcp:zone                  <- tpZone
nagare:baseDomain         <- tpBaseDomain
nagare:imageBucket        <- tpImageBucket        (REQUIRED — always seeded)
nagare:backupBucket       <- tpBackupBucket
nagare:artifactRegistryId <- tpArtifactRegistryId
nagare:instanceName       <- tpInstanceName
```

`init` does **not** seed `nagare:nagareImageSelfLink` — that is written later by
`scripts/upload-images.sh` (the `just host-image` step) after the NixOS image is built, and it embeds
the project, so it must never be carried over from a foreign project (MasterPlan 12 Integration Point
3).

### Why only `init` drives Pulumi (the env-canonical decision)

MasterPlan 12's Decision Log fixes that the target profile is canonical and the Pulumi stack config is
a *derived projection* of it, written once at onboarding. The everyday `nagarectl` commands
(`status`, `doctor`, `db`, `cdn`, `deploy`) resolve their target purely from the environment
(`resolveTargetProfile`) and never shell out to `pulumi config get`, because doing so on every command
would add Pulumi-engine latency and would fail before a stack exists. `nagarectl init` is the single
deliberate one-time bootstrap that is *allowed* to drive Pulumi (`pulumi config set`) and gcloud
(`services enable`). This plan therefore keeps every Pulumi/gcloud side effect inside `Nagare.Init` and
its `runInit` handler, and adds none to any other command.

### Files this plan creates

- `scripts/enable-apis.sh` — NEW, tracked. The codified API-enablement script.
- `cli/nagarectl/src/Nagare/Init.hs` — NEW. The `nagarectl init` logic: `InitOpts`, profile
  construction, env-file writer, preflight, enable, and seed.

### Files this plan edits

- `cli/nagarectl/nagarectl.cabal` — register `Nagare.Init` in the library `exposed-modules`.
- `cli/nagarectl/app/Main.hs` — add the `Init` constructor, `initOptsParser`, the `command "init"`
  entry, and the `Init o -> runInit o` dispatch.
- `cli/nagarectl/test/Spec.hs` — add unit tests for the pure pieces.
- `infra/pulumi/index.ts` — add the `gcp.projects.Service` resources and the `dependsOn` wiring.

### Scope boundary — what this plan does NOT do

It does not modify the target-profile contract or `scripts/lib/target.sh` (EP-60). It does not change
`Nagare.Target` or any other consumer's resolution (EP-62). It does not rewrite the other scripts under
`scripts/` (EP-61). It does not write user-facing onboarding docs (EP-64). It does not change *what*
gets provisioned beyond adding the API-enablement `Service` resources — the VM/DNS/registry/bucket
topology is unchanged.


## Plan of Work

The work is three milestones, each ending in observable behavior, not merely added code. **M1**
codifies API enablement in a shell script and in Pulumi, verifiable by running the script and listing
enabled services (or, against a simulated target, by the dry-run transcript). **M2** adds the
`nagarectl init` skeleton — the subcommand wired into the command tree, the non-interactive and
interactive prompt paths, and the idempotent profile write guarded by `--force` — verifiable by a
non-interactive run that writes a correct `nagare.target.env` with all cloud side effects skipped.
**M3** adds the preflight (auth + IAM) and the full ordered enable+seed+next-steps flow, verifiable by
a complete non-interactive onboarding against a real or simulated project, a `pulumi config get`
showing the seeded value, and a forced preflight failure printing the remediation.


### Milestone 1 — codified API enablement (script + Pulumi)

Scope: at the end of M1, `scripts/enable-apis.sh` exists and enables the six-API set on the configured
target project, and `infra/pulumi/index.ts` declares a `gcp.projects.Service` resource per API with the
API-dependent resources made to `dependsOn` them. Nothing about `nagarectl` changes yet.

What will exist that did not before: the API list — previously only a sentence in MasterPlan 1's
Surprises — is now executable (the script) and declarative (the Pulumi resources). A clean project can
be made provisioning-ready either by running the script or by a `pulumi up` that self-enables.

Commands to run (from the repo root): `bash scripts/enable-apis.sh` (against the configured target), then
`gcloud services list --enabled --project="$TARGET_PROJECT" | grep -E 'compute|dns|storage|artifactregistry|iam|servicenetworking'`.
Acceptance: the six services are listed as enabled; re-running the script is a harmless no-op. Where no
real project is available, acceptance is the dry-run transcript in Concrete Steps M1.3 (the script
prints the exact `gcloud services enable` argv it would run when `NAGARE_ENABLE_APIS_DRY_RUN=1`).


### Milestone 2 — the `nagarectl init` skeleton, profile write, prompts, idempotence

Scope: at the end of M2, `nagarectl init` is a real subcommand. It accepts non-interactive flags
(`--project`, `--region`, `--zone`, `--base-domain`) and the skip/force flags
(`--force`, `--skip-preflight`, `--skip-enable`, `--skip-seed`, `--dry-run`); when run on a TTY without
the required flags it prompts; it constructs a `TargetProfile`, writes `nagare.target.env` idempotently
(refusing to clobber without `--force`), and — with `--skip-enable --skip-seed` — does nothing to the
cloud. The preflight and the real enable/seed are stubbed to print "skipped" until M3 wires them.

What will exist that did not before: a guided command that produces a correct, byte-for-byte
profile file from flags or prompts, observable by reading the written file.

Commands to run (from the repo root): build with `cd cli/nagarectl && cabal build`; then
`cabal run nagarectl -- init --project acme-prod --region us-west1 --base-domain apps.acme.com --skip-preflight --skip-enable --skip-seed`.
Acceptance: it prints what it wrote and the file `nagare.target.env` contains the nine `export` lines
with `CLOUDSDK_CORE_PROJECT=acme-prod`, `NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev`,
`NAGARE_IMAGE_BUCKET=acme-prod-nagare-images`, etc.; a second run without `--force` refuses with a
clear message; with `--force` it overwrites.


### Milestone 3 — preflight (auth + IAM), enable + seed + next steps, tests

Scope: at the end of M3, `runInit` performs the full ordered flow: (1) preflight — `gcloud auth list`
for an active account and per-role IAM checks for the six operator roles, aborting with a precise
remediation on failure; (2) prompt/resolve the target; (3) write the profile (idempotent, `--force`);
(4) run `scripts/enable-apis.sh`; (5) `pulumi config set` the eight keys; (6) print the ordered
next-step commands. Each side-effecting stage has a `--skip-*` flag for testing/CI. Unit tests cover the
pure pieces.

What will exist that did not before: an operator with a fresh project and a domain runs one command and
is provisioning-ready, and a misconfigured operator gets a clear, early failure instead of an opaque
mid-`pulumi up` error.

Commands to run (from the repo root): `cd cli/nagarectl && cabal test`; then a non-interactive end-to-end
run (Concrete Steps M3.4) and `pulumi -C infra/pulumi config get gcp:project`. Acceptance: the tests pass;
the end-to-end run seeds the config (the `config get` returns the chosen project); a run with an
unauthenticated/under-permissioned account prints the remediation and exits non-zero before writing.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a working
directory is stated. The Haskell toolchain (`cabal`, `ghc`), `gcloud`, and `pulumi` come from the repo's
Nix dev shell; if a command is not found, run it under `nix develop -c <cmd>` or enter the shell first.


### Step M1.1 — create `scripts/enable-apis.sh`

Create `scripts/enable-apis.sh` with exactly this content. It sources EP-60's helper to obtain
`TARGET_PROJECT` and the fail-closed guardrail, then enables the API set. The CLAUDE.md policy requires
the explicit `--project="$PROJECT"` flag on every gcloud call (defense in depth alongside the env-var
fallback and the preflight).

```bash
#!/usr/bin/env bash
# scripts/enable-apis.sh (EP-63) — codify the GCP service-API enablement that the
# original bootstrap had to do by hand (MasterPlan 1, EP-2 surprise:
# artifactregistry.googleapis.com and iam.googleapis.com were off and blocked
# `pulumi up`). On a brand-new project even compute/dns/storage may be off, so we
# enable the full set the Pulumi program needs, idempotently. Enabling an
# already-enabled API is a harmless no-op.
#
# Sources scripts/lib/target.sh (EP-60) for TARGET_PROJECT and the fail-closed
# project-isolation guardrail. SET NAGARE_ENABLE_APIS_DRY_RUN=1 to print the
# gcloud argv without running it (used by `nagarectl init --dry-run` and by tests
# on hosts with no real project).
set -euo pipefail

# Source the single target/guardrail helper from EP-60. It computes the repo root
# from its own path, loads nagare.target.env if present, and sets TARGET_PROJECT.
# shellcheck source=lib/target.sh
source "$(dirname "$0")/lib/target.sh"

# Fail closed unless gcloud's active project equals the configured target.
_require_target_project

APIS=(
  compute.googleapis.com
  dns.googleapis.com
  storage.googleapis.com
  artifactregistry.googleapis.com
  iam.googleapis.com
  servicenetworking.googleapis.com
)

if [ "${NAGARE_ENABLE_APIS_DRY_RUN:-0}" = "1" ]; then
  echo "DRY RUN: would run:"
  echo "  gcloud services enable ${APIS[*]} --project=${TARGET_PROJECT}"
  exit 0
fi

echo "Enabling GCP service APIs on ${TARGET_PROJECT}:"
printf '  %s\n' "${APIS[@]}"
gcloud services enable "${APIS[@]}" --project="${TARGET_PROJECT}"
echo "done."
```

Make it executable:

```bash
chmod +x scripts/enable-apis.sh
```

Why `servicenetworking` is in the list: it is commonly needed for private-services access and enabling
an unused API is harmless and free; including it now avoids a second surprise later. The other five are
exactly the APIs MasterPlan 1's EP-2 surprise and the Pulumi resource topology require.


### Step M1.2 — add `gcp.projects.Service` resources to `infra/pulumi/index.ts`

Add a `Service` resource per API and make the API-dependent resources `dependsOn` them, so a clean
project self-enables on `pulumi up` and Pulumi sequences enablement before resource creation. The Pulumi
GCP provider exposes this as `gcp.projects.Service`. Read the top of `infra/pulumi/index.ts` to find
where `gcpProject` is bound (line ~8) and where `NagarePerimeter` is instantiated (line ~30+); insert
the services after the config is read and pass them through `dependsOn`.

```typescript
import * as gcp from "@pulumi/gcp";

// EP-63: codify the GCP service APIs the topology needs. On a brand-new project
// these may be off; declaring them here makes `pulumi up` self-enable them, and
// the `dependsOn` below sequences enablement before any resource that uses them.
// disableDependentServices/disableOnDestroy are false so `pulumi destroy` never
// turns an API off under another workload in a shared project.
const requiredApis = [
  "compute.googleapis.com",
  "dns.googleapis.com",
  "storage.googleapis.com",
  "artifactregistry.googleapis.com",
  "iam.googleapis.com",
  "servicenetworking.googleapis.com",
];
const apiServices = requiredApis.map(
  (api) =>
    new gcp.projects.Service(`api-${api.split(".")[0]}`, {
      project: gcpProject,
      service: api,
      disableDependentServices: false,
      disableOnDestroy: false,
    }),
);
```

Then thread `dependsOn: apiServices` into the `NagarePerimeter` component's options (the third
argument to a Pulumi resource/component constructor is its options object). Find the existing
`new NagarePerimeter("...", { ... })` call and add the options object (or extend it if one exists):

```typescript
const perimeter = new NagarePerimeter(
  "nagare",
  {
    // ...existing args unchanged (instanceName, region, zone, baseDomain, etc.)...
  },
  { dependsOn: apiServices },
);
```

If `@pulumi/gcp` is not already a dependency in `infra/pulumi/package.json`, add it (it almost
certainly is, since the program creates GCP resources — verify with
`grep '@pulumi/gcp' infra/pulumi/package.json`; if missing, `cd infra/pulumi && npm install @pulumi/gcp`).

Note on the relationship to the script: the script (`enable-apis.sh`) is what runs *before* the very
first `pulumi up` (solving the chicken-and-egg the EP-2 surprise records); the Pulumi `Service`
resources make every subsequent `pulumi up` self-asserting. Both enable the identical six-API list, so
there is no drift. This is the "do both" decision (Decision Log).


### Step M1.3 — verify Milestone 1

Against a real configured target (from the repo root, with the dev shell active and `gcloud`
authenticated):

```bash
bash scripts/enable-apis.sh
gcloud services list --enabled --project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}" \
  | grep -E 'compute|dns|storage|artifactregistry|iam|servicenetworking'
```

Expected (order may vary; the point is all six appear):

```text
artifactregistry.googleapis.com   Artifact Registry API
compute.googleapis.com            Compute Engine API
dns.googleapis.com                Cloud DNS API
iam.googleapis.com                Identity and Access Management (IAM) API
servicenetworking.googleapis.com  Service Networking API
storage.googleapis.com            Cloud Storage API
```

Re-run `bash scripts/enable-apis.sh` and confirm it completes without error (idempotent).

Where no real project is available, prove the script's logic with the dry-run env toggle:

```bash
NAGARE_ENABLE_APIS_DRY_RUN=1 bash scripts/enable-apis.sh
```

Expected:

```text
DRY RUN: would run:
  gcloud services enable compute.googleapis.com dns.googleapis.com storage.googleapis.com artifactregistry.googleapis.com iam.googleapis.com servicenetworking.googleapis.com --project=tan-nb-exp
```

(The project shown is whatever `TARGET_PROJECT` resolves to — `tan-nb-exp` with no profile, or the
profile's project.) The guardrail still runs first, so if the active project does not match the
configured target the script aborts with EP-60's refusal message before printing anything.


### Step M2.1 — create `cli/nagarectl/src/Nagare/Init.hs`

Create the module. It holds the `InitOpts` record, the pure pieces (profile-from-opts, env-file
rendering, the `pulumi config set` argv builder, the next-steps text), and the IO actions (write,
preflight, enable, seed). It reuses `Nagare.Target` (EP-62) and `Nagare.Ops.Probe.captureTool` (the
existing `cradle` read-only wrapper), and adds one tiny side-effecting runner. No new cabal dependency
is needed: the library already depends on `cradle`, `directory`, and `text`.

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | @nagarectl init@ (MasterPlan 12, EP-63): the guided onboarding command. It is
-- the ONE place in nagarectl permitted to drive Pulumi (`pulumi config set`) and
-- gcloud (`services enable`) — a deliberate one-time bootstrap. Every other command
-- resolves its target purely from the environment (see 'Nagare.Target').
--
-- Flow (in 'runInit', app/Main.hs): preflight (gcloud auth + operator IAM) ->
-- prompt/resolve the target -> write nagare.target.env (idempotent; --force to
-- clobber) -> run scripts/enable-apis.sh -> `pulumi config set` the eight keys the
-- infra program reads -> print the ordered next-step commands.
module Nagare.Init
  ( InitOpts (..)
  , profileFromOpts
  , renderTargetEnv
  , pulumiConfigSetArgs
  , seedKeys
  , nextStepsText
  , operatorRoles
  , requiredApis
  , writeTargetEnv
  , runPreflight
  , enableApis
  , seedPulumiConfig
  , WriteResult (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, makeAbsolute)
import System.Exit (ExitCode (..))
import Cradle (cmd, addArgs, run, StdoutTrimmed (..), silenceStderr)

import Nagare.Target
  ( TargetProfile (..)
  , resolveTargetProfile
  )
import Nagare.Ops.Probe (captureTool)

-- | Options for @nagarectl init@. The four target flags are 'Maybe' so an absent
-- flag triggers an interactive prompt (on a TTY) or an error (non-TTY). The skip
-- flags exist for testing/CI and for partial recovery (e.g. re-seed without
-- re-enabling). @--force@ permits overwriting an existing profile.
data InitOpts = InitOpts
  { ioProject :: !(Maybe String)
  , ioRegion :: !(Maybe String)
  , ioZone :: !(Maybe String)
  , ioBaseDomain :: !(Maybe String)
  , ioForce :: !Bool
  , ioSkipPreflight :: !Bool
  , ioSkipEnable :: !Bool
  , ioSkipSeed :: !Bool
  , ioDryRun :: !Bool
  }
  deriving stock (Eq, Show)

-- | The operator IAM roles the preflight verifies (Decision Log). 'roles/owner'
-- short-circuits to pass because it includes all of these.
operatorRoles :: [Text]
operatorRoles =
  [ "roles/compute.admin"
  , "roles/dns.admin"
  , "roles/artifactregistry.admin"
  , "roles/storage.admin"
  , "roles/iam.securityAdmin"
  , "roles/serviceusage.serviceUsageAdmin"
  ]

-- | The service APIs enable-apis.sh turns on; kept here only for documentation /
-- the next-steps text. The script is the source of truth for the actual enable.
requiredApis :: [Text]
requiredApis =
  [ "compute.googleapis.com"
  , "dns.googleapis.com"
  , "storage.googleapis.com"
  , "artifactregistry.googleapis.com"
  , "iam.googleapis.com"
  , "servicenetworking.googleapis.com"
  ]

-- | Build the resolved 'TargetProfile' from the chosen project/region/zone/base
-- domain by REUSING 'resolveTargetProfile' with those values placed into the
-- environment, so the derived fields (registry host, buckets) follow EP-60's
-- derivations exactly. The caller (runInit) has already turned prompts/flags into
-- concrete strings; this just resolves derivations. Pure-ish: it sets env vars
-- then resolves. (See note in runInit on ordering.)
profileFromOpts :: Text -> Text -> Text -> Text -> IO TargetProfile
profileFromOpts project region zone baseDomain = do
  -- resolveTargetProfile reads the environment; export the chosen core values so
  -- the derivations (<region>-docker.pkg.dev, <project>-nagare-*) pick them up.
  -- We clear the derived overrides so derivation, not a stale env value, wins.
  setEnvT "CLOUDSDK_CORE_PROJECT" project
  setEnvT "CLOUDSDK_COMPUTE_REGION" region
  setEnvT "CLOUDSDK_COMPUTE_ZONE" zone
  setEnvT "NAGARE_BASE_DOMAIN" baseDomain
  unsetEnvSafe "NAGARE_REGISTRY_HOST"
  unsetEnvSafe "NAGARE_IMAGE_BUCKET"
  unsetEnvSafe "NAGARE_BACKUP_BUCKET"
  unsetEnvSafe "NAGARE_ARTIFACT_REGISTRY_ID"
  unsetEnvSafe "NAGARE_INSTANCE_NAME"
  resolveTargetProfile
  where
    setEnvT k v = setEnv k (T.unpack v)
    unsetEnvSafe k = unsetEnv k

-- | Render the profile as the nine `export VAR=value` lines of nagare.target.env,
-- matching EP-60's schema exactly so the file the rest of the system reads is
-- byte-compatible with the tracked example.
renderTargetEnv :: TargetProfile -> Text
renderTargetEnv tp =
  T.unlines
    [ "# nagare target profile — generated by `nagarectl init` (EP-63)."
    , "# Edit this file or re-run `nagarectl init --force` to change the target."
    , "export CLOUDSDK_CORE_PROJECT=" <> tpProject tp
    , "export CLOUDSDK_COMPUTE_REGION=" <> tpRegion tp
    , "export CLOUDSDK_COMPUTE_ZONE=" <> tpZone tp
    , "export NAGARE_REGISTRY_HOST=" <> tpRegistryHost tp
    , "export NAGARE_ARTIFACT_REGISTRY_ID=" <> tpArtifactRegistryId tp
    , "export NAGARE_IMAGE_BUCKET=" <> tpImageBucket tp
    , "export NAGARE_BACKUP_BUCKET=" <> tpBackupBucket tp
    , "export NAGARE_BASE_DOMAIN=" <> tpBaseDomain tp
    , "export NAGARE_INSTANCE_NAME=" <> tpInstanceName tp
    ]

-- | The eight Pulumi config (key, value) pairs to seed from the profile. Order is
-- stable for deterministic output. nagare:imageBucket is REQUIRED by the program
-- (no default), so it is always present here.
seedKeys :: TargetProfile -> [(Text, Text)]
seedKeys tp =
  [ ("gcp:project", tpProject tp)
  , ("gcp:region", tpRegion tp)
  , ("gcp:zone", tpZone tp)
  , ("nagare:baseDomain", tpBaseDomain tp)
  , ("nagare:imageBucket", tpImageBucket tp)
  , ("nagare:backupBucket", tpBackupBucket tp)
  , ("nagare:artifactRegistryId", tpArtifactRegistryId tp)
  , ("nagare:instanceName", tpInstanceName tp)
  ]

-- | The argv for one `pulumi -C infra/pulumi config set KEY VALUE`. Pure so it is
-- unit-testable without Pulumi.
pulumiConfigSetArgs :: Text -> Text -> [String]
pulumiConfigSetArgs key value =
  ["-C", "infra/pulumi", "config", "set", T.unpack key, T.unpack value]

-- | The ordered follow-on commands printed after a successful init.
nextStepsText :: Text
nextStepsText =
  T.unlines
    [ ""
    , "Next steps:"
    , "  1.  just infra-up        # create the GCP resources (the VM is omitted until the image exists)"
    , "  2.  just host-image      # build + register the NixOS image and write its self-link to Pulumi config"
    , "  3.  just infra-up        # re-run to create the VM now that nagareImageSelfLink is set"
    , "  4.  just cluster-bootstrap   # install the in-cluster platform (k3s/Knative/cert-manager)"
    , ""
    , "See docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md and the"
    , "EP-2/EP-3/EP-4 plans under docs/plans/ for the details behind each step."
    ]

-- | Outcome of attempting to write the profile file.
data WriteResult = Wrote | RefusedExists | DryRunWouldWrite
  deriving stock (Eq, Show)

-- | Write nagare.target.env at the repo root, idempotently. Refuses to clobber an
-- existing file unless @force@ is set. With @dryRun@, writes nothing. Returns what
-- it did so the handler can report it.
writeTargetEnv :: Bool -> Bool -> TargetProfile -> IO WriteResult
writeTargetEnv force dryRun tp = do
  let path = "nagare.target.env"
  exists <- doesFileExist path
  if dryRun
    then pure DryRunWouldWrite
    else if exists && not force
      then pure RefusedExists
      else do
        TIO.writeFile path (renderTargetEnv tp)
        pure Wrote

-- | Run scripts/enable-apis.sh (which sources the guardrail and enables the APIs).
-- Returns the exit code so the handler can fail the command on a real error.
-- @dryRun@ sets NAGARE_ENABLE_APIS_DRY_RUN=1 so the script prints the argv instead.
enableApis :: Bool -> IO ExitCode
enableApis dryRun =
  fmap fst $
    run $
      cmd "bash"
        & addArgs (["scripts/enable-apis.sh"] <> dryEnv)
  where
    -- We pass the dry flag via an env-style argument the script reads; simpler to
    -- set it in the process environment. The handler sets the env var before the
    -- call (see runInit); here we just thread the flag for clarity.
    dryEnv = []
    -- NOTE: when dryRun, runInit sets NAGARE_ENABLE_APIS_DRY_RUN=1 in the env.

-- | `pulumi config set` each seed key from the profile, from the infra/pulumi
-- stack. Stops and returns the first failing key (with its exit code) so the
-- handler can report a precise, recoverable error. @dryRun@ prints the argv.
seedPulumiConfig :: Bool -> TargetProfile -> IO (Either (Text, ExitCode) ())
seedPulumiConfig dryRun tp = go (seedKeys tp)
  where
    go [] = pure (Right ())
    go ((k, v) : rest)
      | dryRun = do
          TIO.putStrLn ("  pulumi " <> T.pack (unwords (pulumiConfigSetArgs k v)))
          go rest
      | otherwise = do
          (code, _ :: StdoutTrimmed) <-
            run $ cmd "pulumi" & addArgs (pulumiConfigSetArgs k v) & silenceStderr
          case code of
            ExitSuccess -> go rest
            ExitFailure _ -> pure (Left (k, code))

-- | Preflight: confirm gcloud has an active authenticated account and that it
-- holds (or owns) the operator roles on @project@. Returns @Right ()@ on pass, or
-- @Left msg@ with a precise remediation on failure. Read-only: it only queries.
runPreflight :: Text -> IO (Either Text ())
runPreflight project = do
  -- (1) active account
  mAcct <- captureTool "gcloud"
    ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
  case fmap (T.strip . decodeAcct) mAcct of
    Nothing ->
      pure (Left authRemediation)
    Just acct | T.null acct ->
      pure (Left authRemediation)
    Just acct -> do
      -- (2) IAM roles for that account on the project
      mPolicy <- captureTool "gcloud"
        [ "projects", "get-iam-policy", T.unpack project
        , "--flatten=bindings[].members"
        , "--filter=bindings.members:user:" <> T.unpack acct
        , "--format=value(bindings.role)"
        ]
      let held = maybe [] (T.lines . T.strip . decodeAcct) mPolicy
          isOwner = "roles/owner" `elem` held
          missing = filter (`notElem` held) operatorRoles
      if isOwner || null missing
        then pure (Right ())
        else pure (Left (iamRemediation acct project missing))
  where
    decodeAcct = T.pack . filter (/= '\r') . show -- placeholder; see note below
    authRemediation =
      T.unlines
        [ "nagarectl init preflight FAILED: no active gcloud account."
        , "  Run: gcloud auth login"
        , "  and: gcloud auth application-default login"
        , "  then re-run `nagarectl init`."
        ]
    iamRemediation acct proj missing =
      T.unlines
        ( [ "nagarectl init preflight FAILED: account " <> acct
              <> " is missing required roles on " <> proj <> ":"
          ]
            <> map ("    " <>) missing
            <> [ "  Grant them (or roles/owner), e.g.:"
               , "    gcloud projects add-iam-policy-binding " <> proj
                   <> " --member=user:" <> acct <> " --role=<role>"
               , "  then re-run `nagarectl init` (or pass --skip-preflight to bypass)."
               ]
        )
```

Two implementation notes the implementer must resolve when writing the file:

1. **Decoding `captureTool` output.** `captureTool` returns `Maybe ByteString`. Decode it with
   `Data.Text.Encoding.decodeUtf8` (import it), not the `show` placeholder shown above for
   `decodeAcct` — the placeholder is there only to keep the sketch self-contained. Replace every
   `decodeAcct x` with `decodeUtf8 x` and add `import Data.Text.Encoding (decodeUtf8)`.

2. **Passing the dry-run flag to the script.** `enableApis` runs `scripts/enable-apis.sh`; the script
   reads `NAGARE_ENABLE_APIS_DRY_RUN` from its environment. Either set that env var in `runInit`
   before calling `enableApis dryRun` (simplest — `setEnv "NAGARE_ENABLE_APIS_DRY_RUN" "1"` when
   `ioDryRun`), or use cradle's `addEnvVar`/`setEnvVar` modifier on the `cmd` (check the exact name
   with `mori` if you prefer per-invocation env). The env-var approach matches the rest of the repo
   and needs no extra cradle API.

The `&` operator and `run`/`run_`/`cmd`/`addArgs`/`silenceStderr`/`StdoutTrimmed`/`ExitCode` names all
come from `Cradle` (already a library dependency); `(&)` comes from `Data.Function` (re-exported by the
`Nagare.Dsl.Prelude` the other modules import, or import it explicitly).


### Step M2.2 — register `Nagare.Init` in the cabal file

Edit `cli/nagarectl/nagarectl.cabal`. Add `Nagare.Init` to the library `exposed-modules` (the block at
lines ~32–82). Insert it alphabetically near `Nagare.Image`:

```diff
     Nagare.Image
+    Nagare.Init
     Nagare.Ops.Cleanup
```

No new `build-depends` entry is required: `cradle`, `directory`, `text`, `bytestring`, and `base` (for
`System.Exit`/`System.Environment`) are already in the library's dependency list.


### Step M2.3 — wire `init` into `app/Main.hs`'s command tree

Three edits, each a file-scoped diff.

First, add the constructor to `data Command` (the block around lines 291–316). The `InitOpts` type comes
from `Nagare.Init`:

```diff
   | Doctor DoctorOpts
+  | Init InitOpts
   | Domains DomainsCommand
```

Add the import near the other `Nagare.*` imports (after `import Nagare.Image (...)`):

```diff
+import Nagare.Init
+  ( InitOpts (..)
+  , WriteResult (..)
+  , profileFromOpts
+  , renderTargetEnv
+  , nextStepsText
+  , writeTargetEnv
+  , runPreflight
+  , enableApis
+  , seedPulumiConfig
+  )
+import Nagare.Target (TargetProfile (..), resolveTargetProfile)
```

Second, add the parser and the `command "init"` entry. Add `initOptsParser` near the other
`*OptsParser` definitions, and the `command` to the top-level `subparser` (lines ~972–988):

```haskell
initOptsParser :: Parser InitOpts
initOptsParser =
  InitOpts
    <$> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id (prompted if absent on a TTY)"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> switch (long "force" <> help "Overwrite an existing nagare.target.env")
    <*> switch (long "skip-preflight" <> help "Skip the gcloud auth + operator-IAM checks")
    <*> switch (long "skip-enable" <> help "Skip running scripts/enable-apis.sh")
    <*> switch (long "skip-seed" <> help "Skip seeding the Pulumi stack config")
    <*> switch (long "dry-run" <> help "Show what would be written/enabled/seeded without doing it")
```

```diff
             <> command "doctor" doctorCmd
+            <> command "init" initCmd
             <> command "domains" domainsCmd
```

```haskell
    initCmd =
      info
        (Init <$> initOptsParser <**> helper)
        (fullDesc <> progDesc "Onboard a fresh GCP project: preflight, write the target profile, enable APIs, seed Pulumi config")
```

Third, add the dispatch arm in `main` (the `case` around lines 1418–1445):

```diff
     Doctor o -> runDoctor o
+    Init o -> runInit o
     Domains (DomainsList o) -> runDomainsList o
```

Then add the `runInit` handler. Place it near `runDoctor`. The handler orchestrates the ordered flow;
the prompt helper uses the TTY-detection idiom already in this file:

```haskell
-- | @nagarectl init@: the guided onboarding flow (EP-63). Order: preflight ->
-- resolve target (flags or prompts) -> write the profile -> enable APIs -> seed
-- Pulumi config -> print next steps. Each side-effecting stage is skippable. The
-- ONLY command that drives Pulumi/gcloud (MasterPlan 12 Decision Log).
runInit :: InitOpts -> IO ()
runInit o = do
  -- Defaults for prompts come from the current resolved profile, so re-running
  -- shows the operator their existing values.
  defs <- resolveTargetProfile

  -- (2) Resolve the four core target values from flags or interactive prompts.
  project <- resolveField "GCP project id" (ioProject o) (tpProject defs)
  region <- resolveField "Compute region" (ioRegion o) (tpRegion defs)
  zone <- resolveField "Compute zone" (ioZone o) (tpZone defs)
  baseDomain <- resolveField "Apps base domain" (ioBaseDomain o) (tpBaseDomain defs)

  -- (1) Preflight (unless skipped). Runs AFTER we know the project but BEFORE any
  -- write/enable/seed, so a failure leaves nothing changed.
  unless (ioSkipPreflight o) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    r <- runPreflight project
    case r of
      Left msg -> TIO.hPutStr stderr msg >> exitFailure
      Right () -> putStrLn "  preflight OK"

  -- Build the fully-derived profile (registry host, buckets) via the EP-62 resolver.
  tp <- profileFromOpts project region zone baseDomain

  -- (3) Write the profile idempotently.
  wr <- writeTargetEnv (ioForce o) (ioDryRun o) tp
  case wr of
    Wrote -> putStrLn "Wrote nagare.target.env"
    DryRunWouldWrite -> do
      putStrLn "DRY RUN — would write nagare.target.env:"
      TIO.putStr (renderTargetEnv tp)
    RefusedExists ->
      dieT "nagare.target.env already exists; re-run with --force to overwrite it."

  -- (4) Enable the GCP APIs (unless skipped).
  unless (ioSkipEnable o) $ do
    when (ioDryRun o) (setEnv "NAGARE_ENABLE_APIS_DRY_RUN" "1")
    putStrLn "Enabling GCP service APIs..."
    code <- enableApis (ioDryRun o)
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> dieT "enable-apis failed; see the gcloud output above. Re-run `nagarectl init --skip-preflight` after fixing it."

  -- (5) Seed the Pulumi stack config (unless skipped).
  unless (ioSkipSeed o) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    s <- seedPulumiConfig (ioDryRun o) tp
    case s of
      Right () -> pure ()
      Left (k, _) -> dieT ("pulumi config set failed at key " <> k <> "; fix Pulumi state and re-run `nagarectl init --skip-preflight --skip-enable`.")

  -- (6) Next steps.
  TIO.putStr nextStepsText

-- | Resolve one target field: a flag value wins; otherwise prompt on a TTY with
-- the default; otherwise (non-TTY, no flag) error clearly.
resolveField :: String -> Maybe String -> Text -> IO Text
resolveField _ (Just v) _ = pure (T.pack v)
resolveField label Nothing def = do
  tty <- hIsTerminalDevice stdin
  if not tty
    then dieT (T.pack ("nagarectl init: --" <> flagFor label <> " is required in non-interactive mode"))
    else do
      putStr (label <> " [" <> T.unpack def <> "]: ")
      hFlush stdout
      line <- getLine
      pure (if null line then def else T.pack line)
  where
    flagFor "GCP project id" = "project"
    flagFor "Compute region" = "region"
    flagFor "Compute zone" = "zone"
    flagFor _ = "base-domain"
```

`dieT` is the existing one-line-error-and-exit helper already defined in `app/Main.hs` (used throughout,
e.g. `dieT "..."`); `when`/`unless` come from `Control.Monad` (already imported); `stdout` may need
adding to the `System.IO` import list (`hFlush`, `hIsTerminalDevice`, `stdin`, `stderr` are already
imported — add `stdout`). `setEnv` is already imported from `System.Environment`.


### Step M3.1 — the preflight IAM check (already drafted in M2.1)

The preflight is `runPreflight` in `Nagare.Init` (Step M2.1). The exact gcloud calls:

```bash
# (1) is there an active authenticated account?
gcloud auth list --filter=status:ACTIVE --format='value(account)'
# (2) which roles does that account hold on the project?
gcloud projects get-iam-policy <PROJECT> \
  --flatten='bindings[].members' \
  --filter='bindings.members:user:<ACCOUNT>' \
  --format='value(bindings.role)'
```

Why `get-iam-policy` rather than `gcloud projects test-iam-permissions` / the `testIamPermissions` API:
`get-iam-policy` returns the *roles* the account is granted, which maps directly to the admin-role list
the operator must hold and produces a human-meaningful remediation ("missing roles/compute.admin"). It
requires `resourcemanager.projects.getIamPolicy`, which every admin/owner has. A `roles/owner` binding
short-circuits to pass. The check is intentionally advisory-but-blocking: a real failure aborts before
any write, but the operator can bypass it with `--skip-preflight` (e.g. when permissions are granted via
a group binding that this flat-policy query does not expand — a known limitation noted in Idempotence
and Recovery).


### Step M3.2 — the full flow (already wired in M2.3's `runInit`)

`runInit` already encodes the ordered flow with per-stage skips. No additional code beyond M2.3 and
M3.1 is needed; M3.2 is the integration point where you confirm the stages run in order and that a
preflight failure exits before the write (verified in M3.4).


### Step M3.3 — unit tests in `cli/nagarectl/test/Spec.hs`

Add a test group for the pure pieces and append it to the suite's top-level `testGroup` list (find where
the existing groups are assembled in `Spec.hs`). These tests need no cloud and no env mutation beyond the
profile fields.

```haskell
import Nagare.Init
  ( renderTargetEnv
  , pulumiConfigSetArgs
  , seedKeys
  , nextStepsText
  , operatorRoles
  )
import Nagare.Target (TargetProfile (..))

-- A worked-example profile with the acme-prod values.
acmeProfile :: TargetProfile
acmeProfile =
  TargetProfile
    { tpProject = "acme-prod"
    , tpRegion = "us-west1"
    , tpZone = "us-west1-a"
    , tpRegistryHost = "us-west1-docker.pkg.dev"
    , tpArtifactRegistryId = "nagare"
    , tpImageBucket = "acme-prod-nagare-images"
    , tpBackupBucket = "acme-prod-nagare-backups"
    , tpBaseDomain = "apps.acme.com"
    , tpInstanceName = "nagare-01"
    }

initTests :: TestTree
initTests =
  testGroup
    "Nagare.Init"
    [ testCase "renderTargetEnv emits the nine export lines with the right values" $ do
        let out = renderTargetEnv acmeProfile
        assertBool "has project" (T.isInfixOf "export CLOUDSDK_CORE_PROJECT=acme-prod" out)
        assertBool "has derived image bucket" (T.isInfixOf "export NAGARE_IMAGE_BUCKET=acme-prod-nagare-images" out)
        assertBool "has base domain" (T.isInfixOf "export NAGARE_BASE_DOMAIN=apps.acme.com" out)
    , testCase "seedKeys covers the eight Pulumi keys incl. the required imageBucket" $ do
        let ks = map fst (seedKeys acmeProfile)
        ks @?= [ "gcp:project", "gcp:region", "gcp:zone", "nagare:baseDomain"
               , "nagare:imageBucket", "nagare:backupBucket"
               , "nagare:artifactRegistryId", "nagare:instanceName" ]
    , testCase "pulumiConfigSetArgs targets the infra/pulumi stack" $
        pulumiConfigSetArgs "gcp:project" "acme-prod"
          @?= ["-C", "infra/pulumi", "config", "set", "gcp:project", "acme-prod"]
    , testCase "operatorRoles includes serviceUsageAdmin for the enable step" $
        assertBool "has serviceUsageAdmin" ("roles/serviceusage.serviceUsageAdmin" `elem` operatorRoles)
    , testCase "nextStepsText names the ordered just targets" $ do
        assertBool "infra-up" (T.isInfixOf "just infra-up" nextStepsText)
        assertBool "host-image" (T.isInfixOf "just host-image" nextStepsText)
    ]
```

`assertBool`/`testCase`/`@?=`/`testGroup` come from `tasty`/`tasty-hunit` (already test dependencies);
`T.isInfixOf` from `Data.Text` (import `qualified Data.Text as T` if not already in `Spec.hs`). Run:

```bash
cd cli/nagarectl && cabal test
```

Expected (abridged): the `Nagare.Init` group reports `OK` for all five cases.


### Step M3.4 — end-to-end acceptance (non-interactive)

From the repo root, build and run the full non-interactive onboarding against a scratch profile, with the
cloud stages in dry-run so it is safe on any host:

```bash
cd cli/nagarectl && cabal build && cd ../..
# write a profile, dry-run the cloud stages, skip preflight (no creds needed):
cabal run --project-dir cli/nagarectl nagarectl -- init \
  --project acme-prod --region us-west1 --base-domain apps.acme.com \
  --skip-preflight --dry-run --force
cat nagare.target.env
```

Expected (abridged): the command prints "DRY RUN — would write nagare.target.env:" followed by the nine
export lines, then the dry-run `enable-apis` argv, then the eight `pulumi ... config set` argv lines,
then the Next steps block. (With `--dry-run`, `cat nagare.target.env` shows the file only if a previous
non-dry run wrote it; in a pure dry run nothing is written — drop `--dry-run` to actually write and seed.)

For the real write + seed (requires the dev shell with `pulumi`; still skip preflight if you have no
creds):

```bash
cabal run --project-dir cli/nagarectl nagarectl -- init \
  --project acme-prod --region us-west1 --base-domain apps.acme.com \
  --skip-preflight --skip-enable --force
grep CLOUDSDK_CORE_PROJECT nagare.target.env
pulumi -C infra/pulumi config get gcp:project
```

Expected:

```text
export CLOUDSDK_CORE_PROJECT=acme-prod
acme-prod
```

To demonstrate the preflight FAILING with a clear message, simulate it two ways. (a) Unauthenticated:
temporarily make `gcloud auth list` report no active account — easiest is to run with a clobbered
`CLOUDSDK_CONFIG` pointing at an empty gcloud config dir:

```bash
CLOUDSDK_CONFIG=$(mktemp -d) cabal run --project-dir cli/nagarectl nagarectl -- init \
  --project acme-prod --region us-west1 --base-domain apps.acme.com
```

Expected (on stderr, then a non-zero exit, with nothing written):

```text
nagarectl init preflight FAILED: no active gcloud account.
  Run: gcloud auth login
  and: gcloud auth application-default login
  then re-run `nagarectl init`.
```

(b) Missing role: against a real project where the active account lacks, say, `roles/dns.admin`, the
same run prints "preflight FAILED: account you@example.com is missing required roles on acme-prod:
roles/dns.admin" and the grant hint. If you cannot arrange an under-permissioned account, the IAM branch
is also exercised by reasoning from the `get-iam-policy` output: an account whose policy listing omits a
role triggers the `missing` branch.

Clean up the scratch profile so the working tree returns to default:

```bash
rm -f nagare.target.env
```


## Validation and Acceptance

Acceptance is observable behavior with specific inputs and outputs, not the mere presence of code.

**A1 — codified API enablement (M1).** `bash scripts/enable-apis.sh` against the configured target makes
`gcloud services list --enabled --project="$TARGET_PROJECT"` report all six APIs (`compute`, `dns`,
`storage`, `artifactregistry`, `iam`, `servicenetworking`); re-running the script is a no-op. Where no
real project exists, `NAGARE_ENABLE_APIS_DRY_RUN=1 bash scripts/enable-apis.sh` prints the exact
`gcloud services enable … --project=<target>` argv (Step M1.3 transcript). In Pulumi, `pulumi -C
infra/pulumi preview` shows the six `gcp:projects:Service` resources and a `dependsOn` edge from the
perimeter to them (the topology now self-enables).

**A2 — non-interactive `init` writes a correct profile (M2).** `cabal run nagarectl -- init --project
acme-prod --region us-west1 --base-domain apps.acme.com --skip-preflight --skip-enable --skip-seed`
writes `nagare.target.env` whose nine `export` lines carry `CLOUDSDK_CORE_PROJECT=acme-prod`,
`NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev`, `NAGARE_IMAGE_BUCKET=acme-prod-nagare-images`,
`NAGARE_BACKUP_BUCKET=acme-prod-nagare-backups`, `NAGARE_BASE_DOMAIN=apps.acme.com`, and the EP-60
defaults for the rest. This proves the derivations (`<region>-docker.pkg.dev`, `<project>-nagare-*`)
are applied via the reused `resolveTargetProfile` and that the file matches the EP-60 schema.

**A3 — idempotent / `--force` guard (M2).** A second `init` over an existing `nagare.target.env`
*without* `--force` prints "nagare.target.env already exists; re-run with --force to overwrite it." and
exits non-zero, writing nothing; *with* `--force` it overwrites. This proves the safe-to-re-run guard.

**A4 — Pulumi config seeded (M3).** After a non-dry `init` (with `--skip-enable` if you lack creds),
`pulumi -C infra/pulumi config get gcp:project` returns the chosen project, and
`pulumi -C infra/pulumi config get nagare:imageBucket` returns `acme-prod-nagare-images` (the required,
no-default key is always seeded). This proves `init` is the projection step that makes the stack config
a derived view of the profile.

**A5 — preflight fails clearly (M3).** Run `init` with no flags under an empty `CLOUDSDK_CONFIG` (no
active account): it prints the auth-remediation block to stderr and exits non-zero *before* writing the
profile (confirm `nagare.target.env` is absent/unchanged afterward). Against a real project with an
under-permissioned account, it prints the missing-roles block. This proves the preflight is blocking and
actionable, and that a failure leaves the working tree and cloud untouched.

**A6 — unit tests (M3).** `cd cli/nagarectl && cabal test` reports the `Nagare.Init` group OK
(env rendering, the eight seed keys incl. the required `nagare:imageBucket`, the `pulumi config set`
argv, `operatorRoles` containing `serviceUsageAdmin`, the next-steps text).

A quick combined build/test check:

```bash
cd cli/nagarectl && cabal build && cabal test 2>&1 | grep -E 'Nagare.Init|PASS|FAIL|OK'
```


## Idempotence and Recovery

Every step is designed to be safe to repeat.

**API enablement** is idempotent at the GCP level: `gcloud services enable` on an already-enabled API
returns success and changes nothing, and the Pulumi `gcp.projects.Service` resources are declarative
(a second `pulumi up` re-asserts the same state). `servicenetworking` is included defensively;
enabling an unused API costs nothing and is harmless, so over-inclusion is safe. Because the `Service`
resources set `disableOnDestroy: false` / `disableDependentServices: false`, a `pulumi destroy` never
turns an API off under another workload in a shared project.

**Profile write** is idempotent and guarded: an existing `nagare.target.env` is never clobbered without
`--force`, and the file is git-ignored (EP-60) so a foreign project's profile can never be committed.
A dry run writes nothing.

**Pulumi seeding** writes the same key/value pairs every time; `pulumi config set` is naturally
idempotent (it overwrites the key). If seeding fails partway (e.g. a missing/uninitialized stack), the
handler reports the exact key it failed at and the recovery command
(`nagarectl init --skip-preflight --skip-enable` re-runs only the seed). The eight keys are written in a
stable order so a partial failure is deterministic and resumable.

**Partial-failure recovery scenarios.** (1) *APIs enabled but seed failed*: re-run
`nagarectl init --skip-preflight --skip-enable --force` — it re-writes the profile (harmless) and
re-seeds; the already-enabled APIs are untouched. (2) *Profile written but enable failed* (e.g. the
account lacks `serviceUsageAdmin`): fix the role and re-run `nagarectl init --skip-preflight` — the
profile write is a harmless rewrite, the enable retries, and the seed runs. (3) *Preflight failed*: no
write, no enable, no seed happened (preflight runs first), so simply fix auth/IAM and re-run from
scratch; or bypass a false negative (e.g. group-granted roles the flat policy query does not expand) with
`--skip-preflight`.

**Known preflight limitation.** `gcloud projects get-iam-policy --filter=bindings.members:user:<acct>`
matches *direct* user bindings. If the operator's roles are granted via a Google group, the flat query
will not see them and the preflight will report them missing. The remediation message names
`--skip-preflight` for exactly this case, and a `roles/owner` binding short-circuits to pass. This is an
accepted, documented trade-off (it errs toward a clear, bypassable warning rather than silently
proceeding into a mid-`pulumi up` permission failure).

No step is destructive: `init` creates/overwrites one git-ignored file, enables APIs (additive), and
writes stack config (overwrite-in-place). There is nothing to roll back in the cloud beyond the APIs,
which are intentionally left enabled.


## Interfaces and Dependencies

**Hard dependencies (MasterPlan 12 registry).** EP-60 (`docs/plans/60-…`) — provides
`nagare.target.env` (the file `init` writes), `nagare.target.env.example` (the schema), and
`scripts/lib/target.sh` (sourced by `scripts/enable-apis.sh` for `TARGET_PROJECT` and the fail-closed
`_require_target_project`). EP-62 (`docs/plans/62-…`) — provides
`cli/nagarectl/src/Nagare/Target.hs` with `TargetProfile (..)` and
`resolveTargetProfile :: IO TargetProfile`, which `init` reuses for prompt defaults and for the derived
fields. **Soft dependency:** EP-61 (`docs/plans/61-…`) — parameterizes the other scripts; `init`'s only
script dependency is EP-60's helper, so EP-61 need not be complete for `init` to work.

**If a prerequisite is missing.** If `cli/nagarectl/src/Nagare/Target.hs` does not yet exist (EP-62 not
done), this plan cannot proceed — `init` is built on that record; complete EP-62 first. If
`scripts/lib/target.sh` does not exist (EP-60 not done), `scripts/enable-apis.sh` cannot source it;
complete EP-60 first. Confirm both before starting:

```bash
test -f cli/nagarectl/src/Nagare/Target.hs && grep -q 'data TargetProfile' cli/nagarectl/src/Nagare/Target.hs && echo "EP-62 OK"
test -f scripts/lib/target.sh && grep -q '_require_target_project' scripts/lib/target.sh && echo "EP-60 OK"
```

**The `init` command surface (what exists at the end of each milestone).**

- End of M1: `scripts/enable-apis.sh` (executable) enabling `compute`, `dns`, `storage`,
  `artifactregistry`, `iam`, `servicenetworking` on `$TARGET_PROJECT`; `gcp.projects.Service` resources
  in `infra/pulumi/index.ts` with `dependsOn` wiring.

- End of M2: in `cli/nagarectl/src/Nagare/Init.hs` —
  `data InitOpts` (fields `ioProject`, `ioRegion`, `ioZone`, `ioBaseDomain` :: `Maybe String`;
  `ioForce`, `ioSkipPreflight`, `ioSkipEnable`, `ioSkipSeed`, `ioDryRun` :: `Bool`);
  `profileFromOpts :: Text -> Text -> Text -> Text -> IO TargetProfile`;
  `renderTargetEnv :: TargetProfile -> Text`;
  `writeTargetEnv :: Bool -> Bool -> TargetProfile -> IO WriteResult` (`data WriteResult = Wrote |
  RefusedExists | DryRunWouldWrite`).
  In `app/Main.hs` — the `Init InitOpts` constructor, `initOptsParser :: Parser InitOpts`, the
  `command "init"` entry, the `Init o -> runInit o` arm, and `runInit :: InitOpts -> IO ()`.

- End of M3: in `Nagare.Init` —
  `runPreflight :: Text -> IO (Either Text ())`;
  `enableApis :: Bool -> IO ExitCode`;
  `seedPulumiConfig :: Bool -> TargetProfile -> IO (Either (Text, ExitCode) ())`;
  `pulumiConfigSetArgs :: Text -> Text -> [String]`;
  `seedKeys :: TargetProfile -> [(Text, Text)]`;
  `nextStepsText :: Text`;
  `operatorRoles :: [Text]`;
  `requiredApis :: [Text]`.

**The IAM role list the preflight checks** (Decision Log): `roles/compute.admin`, `roles/dns.admin`,
`roles/artifactregistry.admin`, `roles/storage.admin`, `roles/iam.securityAdmin`,
`roles/serviceusage.serviceUsageAdmin` (with `roles/owner` short-circuiting to pass).

**The API list codified** (`scripts/enable-apis.sh`, `requiredApis`, and the Pulumi `Service` set):
`compute.googleapis.com`, `dns.googleapis.com`, `storage.googleapis.com`,
`artifactregistry.googleapis.com`, `iam.googleapis.com`, `servicenetworking.googleapis.com`.

**The env-var contract consumed (EP-60 / MasterPlan 12 Integration Point 1).** `init` writes — and the
rest of the system reads — exactly these nine variables: `CLOUDSDK_CORE_PROJECT`,
`CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`, `NAGARE_REGISTRY_HOST`,
`NAGARE_ARTIFACT_REGISTRY_ID`, `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
`NAGARE_INSTANCE_NAME`. Precedence: environment > profile > built-in default (the `tan-nb-exp` value).

**The Pulumi keys seeded (MasterPlan 12 Integration Point 3).** `gcp:project`, `gcp:region`, `gcp:zone`,
`nagare:baseDomain`, `nagare:imageBucket` (required, no default — always seeded), `nagare:backupBucket`,
`nagare:artifactRegistryId`, `nagare:instanceName`. `nagare:nagareImageSelfLink` is deliberately NOT
seeded (it is written later by `scripts/upload-images.sh` and embeds the project).

**The `TargetProfile` reused (EP-62).** `cli/nagarectl/src/Nagare/Target.hs` —
`data TargetProfile = TargetProfile { tpProject, tpRegion, tpZone, tpRegistryHost,
tpArtifactRegistryId, tpImageBucket, tpBackupBucket, tpBaseDomain, tpInstanceName :: Text }` and
`resolveTargetProfile :: IO TargetProfile`. `init` constructs its result `TargetProfile` via
`profileFromOpts` (which reuses `resolveTargetProfile`) and serializes it with `renderTargetEnv`.

**Libraries used.** `cradle` (process shell-out; already a library dependency) for the `gcloud`/`pulumi`
calls, via `cmd`/`addArgs`/`run`/`silenceStderr`/`StdoutTrimmed`/`ExitCode` and the existing
`Nagare.Ops.Probe.captureTool` wrapper. `optparse-applicative` (already an executable dependency) for the
`init` parser. `System.Directory` (`doesFileExist`) and `System.Environment` (`setEnv`/`unsetEnv`,
already imported in `Main.hs`) for the file write and the derivation env. No new cabal dependency is
added by this plan.
