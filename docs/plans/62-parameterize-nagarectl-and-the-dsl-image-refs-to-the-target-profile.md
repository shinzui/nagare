---
id: 62
slug: parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile
title: "Parameterize nagarectl and the DSL image refs to the target profile"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# Parameterize nagarectl and the DSL image refs to the target profile

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the Haskell command-line tool **`nagarectl`** (the program that deploys apps, runs
backups, checks platform health, and provisions the CDN) is welded to one Google Cloud
Platform (GCP) project, `tan-nb-exp`, in region `us-west1`, zone `us-west1-a`. That binding
is not a single configuration value: it is six literal `tan-nb-exp` strings scattered across
the source, one hard-coded Artifact Registry host constant (`us-west1-docker.pkg.dev`), and
several hard-coded region/zone/bucket/instance defaults. The deployment DSL is welded the same
way: every example app's `nagare/Config.hs` bakes the full container-image path
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>` into application source, so pointing an app at
a different registry means editing Haskell.

After this change, an operator who has set up their own GCP target — by copying
`nagare.target.env.example` to `nagare.target.env` and editing one project id (the mechanism
delivered by the prerequisite plan EP-60, described below) — can run every `nagarectl` command
against **their** project with no edit to any tracked Haskell file, and an app author can write
`Config.hs` that names only the image's short name (e.g. `notes`) while the registry prefix
(`<host>/<project>/<repo-id>`) is supplied from the environment at deploy time. Concretely, the
user-visible behaviors you will be able to demonstrate at the end are:

- With no profile and an unset environment, `nagarectl` behaves exactly as it does today: it
  targets `tan-nb-exp` / `us-west1` / `us-west1-a`, the backup Job it renders carries
  `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, and `doctor`/`status` print the `us-west1-docker.pkg.dev/
  tan-nb-exp/nagare` registry strings — proving no regression.
- With `CLOUDSDK_CORE_PROJECT=acme-prod` (and the other `NAGARE_*` variables) set in the
  environment, the **same** `nagarectl db backup --dry-run` run renders a Job whose
  `CLOUDSDK_CORE_PROJECT` env value is `acme-prod`, the CDN `gcloud` argv carry
  `--project=acme-prod`, and `doctor` points the operator at `acme-prod`'s registry — all
  observable in command output and in unit tests that fail before this change and pass after.
- An example app whose `Config.hs` supplies only `notes` (not the full path) deploys to
  `acme-prod`'s registry because the prefix is derived from the environment, and the same app
  deploys to `tan-nb-exp` when the environment is unset — both observable by inspecting the
  rendered image reference.

This plan touches only Haskell under `cli/` (the CLI `nagarectl` and the DSL library
`nagare-dsl`) plus the example/fixture `Config.hs` files. It makes no GCP call and changes no
Pulumi program. It hard-depends on EP-60 (the prerequisite plan
`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`), which defines the
exact environment-variable names this plan reads. Those names, and the fallback defaults that
preserve today's behavior, are restated in full below so this plan is self-contained.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 — Created `cli/nagarectl/src/Nagare/Target.hs` with the `TargetProfile` record,
      `resolveTargetProfile :: IO TargetProfile`, and `registryPrefix`, reading the nine env vars
      with EP-60 fallbacks (derived `<region>-docker.pkg.dev` and `<project>-nagare-*`). (2026-06-10)
- [x] M1.2 — Registered `Nagare.Target` in `cli/nagarectl/nagarectl.cabal` `exposed-modules`;
      `cabal build lib:nagarectl` green. (2026-06-10)
- [x] M1.3 — Added the `Nagare.Target (EP-62)` group to `cli/nagarectl/test/Spec.hs` (one
      sequential, env-restoring `testCase` covering defaults, project/region override + derivation,
      and explicit-derived-wins); `cabal test` green (247 tests). (2026-06-10)
- [x] M2.1 — Threaded `TargetProfile` through `Nagare.Image` (`registryHost` constant removed;
      `configureDockerAuth` resolves the profile internally), `Nagare.Ops.Status`
      (`defaultInventoryOpts`→`inventoryOptsFor tp`, `defaultBackupBucket` removed, `gatherInventory`/
      `probeRegistryAuth` take `tp`), and `Nagare.Ops.Doctor` (`gradeChecks`/`remediationFor`/`why`/
      `command` take `tp`; instance/zone/registry-host interpolated). (2026-06-10)
- [x] M2.2 — Removed the two `--project=tan-nb-exp` literals in `Nagare.Cdn.Provision` via a new
      `gsrProject` field + leading project args on `gcloudDnsUpsertArgs`/`gcloudBackendCacheArgs`, and
      the `runCdnDisable` literals in `app/Main.hs`. (2026-06-10)
- [x] M2.3 — Parameterized the rendered Job env (`CLOUDSDK_CORE_PROJECT`) in
      `Nagare.Database.Backup` (`bjiProject`), `Nagare.Database.Restore` (`rjiProject`), and
      `Nagare.Storage.Snapshot` (`sjiProject`); threaded through `runDbBackup`/`runDbRestore`/
      `runSnapshot`/`renderDbBackupCronJob`. (2026-06-10)
- [x] M2.4 — Unified backup-bucket/base-domain resolution on the profile (`Database.Create` resolves
      `resolveTargetProfile`; `app/Main.hs` `resolveBackupBucket`/`resolveBaseDomain` fall back to the
      profile); removed every `tan-nb-exp`/behavioral `us-west1` literal under `cli/nagarectl/src` and
      `app/`. `cabal test` green (250 tests). (2026-06-10)
- [x] M3.1 — Added `cli/nagare-dsl/src/Nagare/Dsl/Image.hs` (`imageRefFromName`, `mkImageName`)
      joining `<host>/<project>/<repo-id>/<name>` via `mkImageRef`; registered in the cabal. (2026-06-10)
- [x] M3.2 — Applied the prefix at the CLI deploy/load boundary: `Nagare.Image.qualifyImage`
      (bare name → `registryPrefix tp <> "/" <> name`; already-qualified ref unchanged), wired into
      `runDeploy` and `runSiteDeploy` (both static and server kinds) right after load. Added the
      `nagare-dsl` `imageRefFromName` round-trip tests and `nagarectl` `qualifyImage` tests. (2026-06-10)
- [x] M3.3 — Rewrote the two DSL fixtures, the 15 example `Config.hs`, the `StaticSpec`/`ServerSpec`
      expected records, and the three affected render goldens to the name-only form;
      `hello-knative-service` (public `gcr.io` ref) left untouched. `cabal test` green in both
      `cli/nagare-dsl` (264) and `cli/nagarectl` (253). (2026-06-10)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Deviation from the plan's stated signatures for three IO helpers, recorded as an autonomous
  decision: `configureDockerAuth :: IO ()`, `resolveBackupBucket :: Maybe String -> IO Text`, and
  `resolveBaseDomain :: Maybe String -> IO Text` **resolve the profile internally** (via
  `resolveTargetProfile`) instead of taking a `TargetProfile` parameter. Rationale: the plan proposed
  threading `tp` into these, but `configureDockerAuth` is called from three deploy modules
  (`Nagare.Server.Deploy`, `Nagare.Static.Deploy`, `app/Main.hs`) and `resolveBaseDomain` from six
  handlers; threading a parameter would cascade signature changes through deploy functions that have
  no other need for the profile. Internal resolution keeps every call site unchanged, is equally
  correct (a few extra `lookupEnv` calls per command — negligible), and the plan itself sanctions
  this pattern for `Database.Create` ("OR call `resolveTargetProfile` directly in the create
  handler"). The job renderers and `gatherInventory`/`gradeChecks`/the CDN argv builders still take
  the project/profile explicitly as the plan specifies, because those are pure and their callers
  already resolve `tp`. (2026-06-10)
- The `Spec.hs` env-mutating `Nagare.Target` test group plus the new env-backed helpers exposed a
  parallelism hazard: `tasty` runs cases concurrently and these mutate global process env. Mitigated
  by collapsing the target tests into one sequential, env-restoring `testCase` (saves/restores all
  nine vars via `finally`). The new `backupProjectTests` build records directly (no env), so they are
  race-free. (2026-06-10)


## Decision Log

Record every decision made while working on the plan.

- Decision: a new module `Nagare.Target` (in the `nagarectl` library) owns the `TargetProfile`
  record and `resolveTargetProfile :: IO TargetProfile`; nothing reads the raw environment
  variables directly anymore.
  Rationale: today the target is a set of compile-time constants and scattered `lookupEnv` calls
  (two separate `resolveBackupBucket` functions, a `resolveBaseDomain`, a hard-coded
  `registryHost`) with no central layer. A single resolution point gives one place to test the
  EP-60 precedence rules and one type to thread through consumers, and is exactly the type EP-63's
  `nagarectl init` will reuse (MasterPlan 12, Dependency Graph).
  Date: 2026-06-10

- Decision: the DSL image-ref prefix is derived and applied in `nagarectl` at the deploy/load
  boundary, NOT inside the DSL `Config.hs` evaluation, and `mkImageRef` is kept for back-compat
  with fully-qualified refs (e.g. the public `gcr.io/knative-samples/helloworld-go`).
  Rationale: the DSL library `nagare-dsl` is environment-agnostic and must stay so (it has no
  notion of "the operator's project"); the registry prefix is a deploy-time GCP-target concern that
  belongs with the `TargetProfile` resolution in `nagarectl`. Keeping `mkImageRef` means apps that
  legitimately point at a public registry are unaffected. See MasterPlan 12 Integration Point 4.
  Date: 2026-06-10

- Decision: derived defaults match EP-60 exactly — `NAGARE_REGISTRY_HOST` defaults to
  `<CLOUDSDK_COMPUTE_REGION>-docker.pkg.dev`, `NAGARE_IMAGE_BUCKET` to `<project>-nagare-images`,
  `NAGARE_BACKUP_BUCKET` to `<project>-nagare-backups`, with the ultimate fallbacks being the
  `tan-nb-exp`/`us-west1` worked-example values.
  Rationale: MasterPlan 12 Integration Point 1 fixes these derivations; matching them keeps the
  Haskell resolution and the shell `.envrc`/`scripts/lib/target.sh` resolution byte-identical so an
  operator sees one consistent target across both layers.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-62 made `nagarectl` and the DSL image refs fully target-configurable. The new `Nagare.Target`
record/`resolveTargetProfile` is the single resolution point; every former literal (six `tan-nb-exp`
strings, the `registryHost` constant, the region/zone/bucket/instance defaults) now flows from the
profile. The DSL gained `Nagare.Dsl.Image.imageRefFromName`/`mkImageName` and the CLI gained
`Nagare.Image.qualifyImage`, applied at the deploy/load boundary so a name-only `Config.hs` is
prefixed at deploy time from the environment while a fully-qualified public ref is left untouched.
Example/fixture `Config.hs` now name only their image (e.g. `notes`), and the project no longer lives
in application source.

Acceptance was proven by tests that fail-before/pass-after: the `Nagare.Target` group (defaults +
override + derivation), the rendered-backup-Job project test (follows `bjiProject`), the
parameterized CDN argv test (`--project=acme-prod`), the `imageRefFromName` round-trip, and the
`qualifyImage` bare-name-vs-qualified tests. `grep tan-nb-exp` over `cli/nagarectl/src`,
`cli/nagarectl/app`, `cli/nagare-dsl/src`, and the example `Config.hs` returns only the documented
defaults in `Nagare.Target` and Haddock examples. Both suites are green (nagare-dsl 264, nagarectl
253).

Deviations from the plan, all recorded in the Decision Log / Surprises: (1) the helper preflight is
invoked explicitly rather than on source (an EP-60 contract correction inherited from EP-61);
(2) `configureDockerAuth`/`resolveBackupBucket`/`resolveBaseDomain` resolve the profile internally
rather than taking a `TargetProfile` parameter, to avoid cascading signature changes through deploy
modules with no other need for it; (3) the env-mutating target tests were collapsed into one
sequential, env-restoring `testCase` to avoid a tasty parallelism race. The end-to-end CLI dry-run
checks (A3/A4 via `cabal run nagarectl -- deploy --dry-run`) were not executed because they compile a
`Config.hs` through the GHC-environment provisioning path; the equivalent behavior is locked in by
the `qualifyImage` and rendered-Job unit tests, which exercise the same resolution and rendering code
deterministically.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What the pieces are (terms of art)

- **`nagarectl`** — the Haskell command-line program that operators run to deploy apps, take
  database backups, snapshot volumes, check platform health (`status`/`doctor`), and provision a
  CDN. Its library lives under `cli/nagarectl/src/`, its `main` entry point in
  `cli/nagarectl/app/Main.hs`, and its tests in `cli/nagarectl/test/Spec.hs`.

- **`nagare-dsl`** — the Haskell library that defines the typed deployment model and the
  "config-as-program" surface. An app author writes a `nagare/Config.hs` file that constructs a
  typed value (a `Deployment`, `StaticSite`, or `ServerSite`) and calls an `emit*` function;
  `nagarectl` compiles-and-runs that file to obtain the value as JSON. The library lives under
  `cli/nagare-dsl/src/`.

- **target profile** — a single git-ignored file `nagare.target.env` at the repo root holding the
  operator's GCP target (project, region, zone, registry host, registry id, image bucket, backup
  bucket, base domain, instance name) as `export VAR=value` shell lines. It is the single source of
  truth for *which* GCP project nagare acts on. It is created and documented by the prerequisite
  plan EP-60 (`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`); this
  plan does not create or parse the file — it reads the same variables from the **process
  environment** (EP-60's `.envrc` exports them into every shell entered in the repo).

- **image ref** — a container-image repository path with no tag, e.g.
  `us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes`. In the DSL it is the newtype `ImageRef`
  (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), constructed by the smart constructor `mkImageRef` and
  read back with `imageRefText`. The tag (a timestamp) is appended later, at deploy time, by
  `cli/nagarectl/src/Nagare/Image.hs`.

- **smart constructor** — a function `mkX :: ... -> Either Text X` that is the *only* way to build
  a value of a type whose data constructor is hidden. It validates its input and returns `Left`
  with a precise message on a bad value, so an invalid value can never be constructed. The DSL
  types module is built entirely from smart constructors (`mkServiceName`, `mkImageRef`, etc.).

- **stack output** — a named value the Pulumi infrastructure program publishes (e.g. `publicIp`,
  `baseDomain`, `backupBucket`). `nagarectl` reads these via
  `Nagare.Ops.Pulumi.stackOutput :: FilePath -> Text -> IO (Maybe Text)`. They are *not* the target
  profile: today some target values are read from a stack output with a hard-coded literal fallback
  (e.g. the backup bucket). After this plan the fallback comes from the `TargetProfile`, not from a
  literal.

- **optparse-applicative** — the Haskell library `nagarectl` uses to parse command-line options
  (flags like `--bucket`, `--skip-vm`). It builds a `Parser a` from small applicative combinators
  (`strOption`, `switch`, `optional`). Where this plan keeps a flag as an override on top of the
  profile, the flag's parser yields a `Maybe` and the handler falls back to the profile value when
  the flag is absent — exactly the existing pattern for `--bucket`/`--base-domain`.

### The current resolution mechanism (what is wrong today)

There is **no central target layer**. The GCP target is encoded three different ways:

1. **Compile-time constants.** `cli/nagarectl/src/Nagare/Image.hs` line 32-33 defines
   `registryHost = "us-west1-docker.pkg.dev"`. `cli/nagarectl/src/Nagare/Ops/Status.hs` lines
   36-43 define `defaultInventoryOpts` with `ioZone = "us-west1-a"` and `ioInstance = "nagare-01"`,
   and line 47-48 `defaultBackupBucket = "tan-nb-exp-nagare-backups"`.

2. **Literal strings inside rendered output or commands.** Six `tan-nb-exp` literals:
   - `cli/nagarectl/src/Nagare/Cdn/Provision.hs` line ~142 (`gcloudDnsUpsertArgs`) and line ~158
     (`gcloudBackendCacheArgs`) append `"--project=tan-nb-exp"` to a `gcloud` argv.
   - `cli/nagarectl/app/Main.hs` line ~1568 (`runCdnDisable`) appends `"--project=tan-nb-exp"`.
   - `cli/nagarectl/src/Nagare/Database/Backup.hs` line ~196 renders a Job env entry
     `plainEnv "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"`.
   - `cli/nagarectl/src/Nagare/Database/Restore.hs` line ~117 renders the same Job env entry.
   - `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` line ~163 renders the same Job env entry.
   Plus `us-west1`/`us-west1-a`/`nagare-01` literals in `Nagare.Ops.Status.probeRegistryAuth`
   (line 167-169) and in `Nagare.Ops.Doctor` (lines ~89, ~105, ~125, ~128) and the registry-string
   in `probeRegistryAuth`'s success message (`us-west1-docker.pkg.dev/tan-nb-exp/nagare reachable`).

3. **Scattered, duplicated `lookupEnv` reads.** `cli/nagarectl/app/Main.hs` line ~2317
   `resolveBackupBucket :: Maybe String -> IO Text` reads `NAGARE_BACKUP_BUCKET` with the literal
   default `tan-nb-exp-nagare-backups`; `cli/nagarectl/src/Nagare/Database/Create.hs` line ~184
   has a *second*, slightly different `resolveBackupBucket :: IO Text` doing the same; and
   `Main.hs` line ~2485 `resolveBaseDomain` reads `NAGARE_BASE_DOMAIN`. These prove the pattern
   exists but is not centralized.

4. **The DSL bakes the registry prefix into app source.** Every example/fixture `Config.hs`
   calls `mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>"` (or
   `webService "<app>" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>"`). The image string is
   serialized in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (lines 196, 295, 355 — `"image" .=
   imageRefText (...)`) and re-parsed in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (lines 256, 654,
   885, 1101 — `mkImageRef (jdImage jd)` etc.), so the round-trip is: `Config.hs` builds an
   `ImageRef` -> emitted as a JSON `image` string -> loaded back through `mkImageRef`.

### The EP-60 environment-variable contract (restated verbatim)

The prerequisite plan EP-60 fixes these nine variable names and their fallback defaults
(MasterPlan 12 Integration Point 1). Precedence everywhere: a value present in the environment
wins; otherwise the profile (which `.envrc` has already exported into the environment); otherwise
the built-in default. Because this plan reads the **environment**, it implements only the
"environment-or-default" half — the profile half is already applied by EP-60's `.envrc`.

```text
CLOUDSDK_CORE_PROJECT          (default tan-nb-exp)
CLOUDSDK_COMPUTE_REGION        (default us-west1)
CLOUDSDK_COMPUTE_ZONE          (default us-west1-a)
NAGARE_REGISTRY_HOST           (default <region>-docker.pkg.dev ; ultimately us-west1-docker.pkg.dev)
NAGARE_ARTIFACT_REGISTRY_ID    (default nagare)
NAGARE_IMAGE_BUCKET            (default <project>-nagare-images ; ultimately tan-nb-exp-nagare-images)
NAGARE_BACKUP_BUCKET           (default <project>-nagare-backups ; ultimately tan-nb-exp-nagare-backups)
NAGARE_BASE_DOMAIN             (default apps.example.com)
NAGARE_INSTANCE_NAME           (default nagare-01)
```

### Files this plan creates

- `cli/nagarectl/src/Nagare/Target.hs` — NEW. The `TargetProfile` record and
  `resolveTargetProfile`.
- `cli/nagare-dsl/src/Nagare/Dsl/Image.hs` — NEW. The pure image-prefix derivation
  (`registryPrefix`, `imageRefFromName`/`mkImageName`). (Alternatively these helpers may live in
  the existing `Nagare.Dsl.Types`; see M3 for the decision.)

### Files this plan edits

CLI (`cli/nagarectl/`): `nagarectl.cabal` (register the new module), `app/Main.hs`,
`src/Nagare/Image.hs`, `src/Nagare/Ops/Status.hs`, `src/Nagare/Ops/Probe.hs`,
`src/Nagare/Ops/Doctor.hs`, `src/Nagare/Cdn/Provision.hs`, `src/Nagare/Database/Backup.hs`,
`src/Nagare/Database/Restore.hs`, `src/Nagare/Database/Create.hs`,
`src/Nagare/Storage/Snapshot.hs`, `test/Spec.hs`.

DSL (`cli/nagare-dsl/`): `nagare-dsl.cabal` (if a new module is added), `src/Nagare/Dsl/Types.hs`
or the new `src/Nagare/Dsl/Image.hs`, `test/Spec.hs`, the two fixtures
`test/fixtures/static-site/nagare/Config.hs` and `test/fixtures/server-site/nagare/Config.hs`.

Examples: the sixteen `cluster/examples/*/nagare/Config.hs` files that bake
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>` (listed in Concrete Steps M3.3). The public-image
example `cluster/examples/hello-knative-service/nagare/Config.hs` (which uses
`gcr.io/knative-samples/helloworld-go`) is left unchanged — it intentionally points at a public
registry and exercises the `mkImageRef` back-compat path.

### Scope boundary — what this plan does NOT do

It does not create or parse `nagare.target.env` (that is EP-60). It does not edit any shell script
under `scripts/` (that is EP-61). It does not add the `nagarectl init` command or touch Pulumi
(that is EP-63). It does not edit user-facing docs (that is EP-64). It writes no Haskell that makes
a GCP call.


## Plan of Work

The work is three milestones. **M1** introduces the central `TargetProfile` resolution layer and
its tests — verifiable purely with `cabal test` and an env-var toggle, no cloud. **M2** threads the
profile through every consumer and deletes the six `tan-nb-exp` literals, the `registryHost`
constant, and the region/zone/bucket defaults — verifiable by a test that renders a backup Job and
sees its `CLOUDSDK_CORE_PROJECT` change with the environment. **M3** makes the DSL image-ref prefix
derivable and rewrites the example/fixture `Config.hs` files to the name-only form — verifiable by
a `nagare-dsl` round-trip test and by inspecting a rendered image reference change with the
environment. Each milestone ends in observable behavior, not a mere added record.


### Milestone 1 — the `TargetProfile` module and resolution, with tests

Scope: at the end of M1, `cli/nagarectl/src/Nagare/Target.hs` exists, is registered in the cabal
library, and exposes a `TargetProfile` record plus `resolveTargetProfile :: IO TargetProfile` that
reads the nine EP-60 environment variables with the EP-60 fallback defaults (including the derived
`<region>-docker.pkg.dev` and `<project>-nagare-*` forms). No consumer uses it yet, but a unit test
proves it resolves correctly. Nothing about live behavior changes because no call site is rewired
yet.

What will exist that did not before: one typed record describing the whole GCP target, and one IO
action that resolves it from the environment with the documented precedence, replacing the notion
that the target is a pile of constants and ad-hoc `lookupEnv` calls.

Commands to run: `cd cli/nagarectl && cabal build` then `cabal test`. Acceptance: the new
`targetProfileTests` group passes — with all `NAGARE_*`/`CLOUDSDK_*` unset the profile equals the
`tan-nb-exp` defaults; with them set it reflects the set values; with only the project set and the
derived vars unset, the registry host is `<region>-docker.pkg.dev` and the buckets are
`<project>-nagare-{images,backups}`.


### Milestone 2 — thread the profile through ops/CDN/DB/storage, deleting the literals

Scope: at the end of M2, the six `tan-nb-exp` literals, the `registryHost` constant, and the
hard-coded region/zone/bucket/instance defaults are gone from `cli/nagarectl/src` and `app/Main.hs`,
replaced by values resolved through `TargetProfile`. `grep -rn 'tan-nb-exp' cli/nagarectl/src
cli/nagarectl/app` returns nothing. The rendered database-backup Job, the restore Job, the volume
snapshot Job, the two CDN `gcloud` argvs, and the `runCdnDisable` argv all carry the *resolved*
project; `status`/`doctor` print the resolved registry/zone/instance strings.

What will exist that did not before: every GCP-target-dependent value in the CLI is read once from
`resolveTargetProfile` and threaded in, so flipping the environment flips the rendered output.

Commands to run: `cd cli/nagarectl && cabal test`. Acceptance: a new test renders the backup Job
with the profile's project field set to `acme-prod` and asserts the Job's `CLOUDSDK_CORE_PROJECT`
env value is `acme-prod`, and with it set to `tan-nb-exp` asserts the value is `tan-nb-exp` — the
literal-vs-parameterized difference is observable in the YAML the renderer produces.


### Milestone 3 — DSL image-ref prefix derivation + fixtures/examples + round-trip

Scope: at the end of M3, the DSL exposes a pure derivation that turns a short image *name* plus a
resolved registry prefix into an `ImageRef`, the example/fixture `Config.hs` files supply only the
short name, and `nagarectl` applies the resolved prefix at the deploy/load boundary. The
`Nagare.Dsl.Config` -> `Nagare.Dsl.Load` JSON round-trip still works. `mkImageRef` is retained for
fully-qualified refs (the `hello-knative-service` public-image example).

What will exist that did not before: an app author writes `mkImageName "notes"` (or passes `notes`
to a preset) and the registry prefix comes from the environment at deploy time, so the same
`Config.hs` deploys to `tan-nb-exp` or `acme-prod` depending only on the environment — application
source no longer encodes the GCP project.

Commands to run: `cd cli/nagare-dsl && cabal test` and `cd cli/nagarectl && cabal test`.
Acceptance: a `nagare-dsl` test asserts `imageRefText (imageRefFromName prefix "notes")` equals
`<prefix>/notes` for a profile-derived prefix and that the value round-trips through the JSON
`image` field unchanged; an end-to-end check (Concrete Steps) shows the rendered image reference of
a name-only app changing from the `tan-nb-exp` registry to an `acme-prod` registry when the
environment changes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a working
directory is stated. The Haskell toolchain (`cabal`, `ghc`) comes from the repo's Nix dev shell;
if commands are not found, run them under `nix develop -c <cmd>` or enter the shell first.


### Step M1.1 — create `cli/nagarectl/src/Nagare/Target.hs`

Create the file with the `TargetProfile` record and `resolveTargetProfile`. The resolution uses
`System.Environment.lookupEnv` (already used in `app/Main.hs`) and implements the EP-60 precedence:
environment value if set, else the derived default. Note that `lookupEnv` returns `Maybe String`;
an empty string from the environment is treated as "set to empty" by `lookupEnv`, so we additionally
guard against an empty value collapsing to the default (matching shell `${VAR:-default}`, which
also falls back on empty).

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | The single resolution point for the GCP "target profile" (MasterPlan 12,
-- EP-62; the variable contract is fixed by EP-60). Every value that used to be a
-- compile-time literal (the project, region, zone, Artifact Registry host/id, the
-- image/backup bucket names, the base domain, the VM instance name) is resolved
-- here, once, from the process environment with the EP-60 fallback defaults, so an
-- operator who sets `nagare.target.env` (which EP-60's `.envrc` exports) retargets
-- the whole CLI without editing Haskell. With nothing set, the defaults reproduce
-- the original tan-nb-exp / us-west1 / us-west1-a setup, so existing behavior is
-- unchanged. EP-63's `nagarectl init` reuses this record.
module Nagare.Target
  ( TargetProfile (..)
  , resolveTargetProfile
  , registryPrefix
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)

-- | The fully-resolved GCP target. Every field is the final value a consumer
-- should use; no further env lookups or literal fallbacks happen downstream.
data TargetProfile = TargetProfile
  { tpProject :: !Text
  -- ^ CLOUDSDK_CORE_PROJECT, e.g. "tan-nb-exp"
  , tpRegion :: !Text
  -- ^ CLOUDSDK_COMPUTE_REGION, e.g. "us-west1"
  , tpZone :: !Text
  -- ^ CLOUDSDK_COMPUTE_ZONE, e.g. "us-west1-a"
  , tpRegistryHost :: !Text
  -- ^ NAGARE_REGISTRY_HOST, default "<region>-docker.pkg.dev"
  , tpArtifactRegistryId :: !Text
  -- ^ NAGARE_ARTIFACT_REGISTRY_ID, default "nagare"
  , tpImageBucket :: !Text
  -- ^ NAGARE_IMAGE_BUCKET, default "<project>-nagare-images"
  , tpBackupBucket :: !Text
  -- ^ NAGARE_BACKUP_BUCKET, default "<project>-nagare-backups"
  , tpBaseDomain :: !Text
  -- ^ NAGARE_BASE_DOMAIN, default "apps.example.com"
  , tpInstanceName :: !Text
  -- ^ NAGARE_INSTANCE_NAME, default "nagare-01"
  }
  deriving stock (Eq, Show)

-- | The Artifact Registry image-name prefix: "<host>/<project>/<repo-id>". An
-- app's short image name is appended to this to form a full image ref (EP-62 M3,
-- MasterPlan 12 Integration Point 4).
registryPrefix :: TargetProfile -> Text
registryPrefix tp =
  tpRegistryHost tp <> "/" <> tpProject tp <> "/" <> tpArtifactRegistryId tp

-- | Resolve the profile from the process environment, applying the EP-60
-- precedence (environment > built-in default) and the EP-60 derivations for the
-- registry host and bucket names. An env var set to the empty string is treated
-- as unset (matching shell ${VAR:-default}).
resolveTargetProfile :: IO TargetProfile
resolveTargetProfile = do
  project <- envOr "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
  region <- envOr "CLOUDSDK_COMPUTE_REGION" "us-west1"
  zone <- envOr "CLOUDSDK_COMPUTE_ZONE" "us-west1-a"
  registryHost <- envOr "NAGARE_REGISTRY_HOST" (region <> "-docker.pkg.dev")
  registryId <- envOr "NAGARE_ARTIFACT_REGISTRY_ID" "nagare"
  imageBucket <- envOr "NAGARE_IMAGE_BUCKET" (project <> "-nagare-images")
  backupBucket <- envOr "NAGARE_BACKUP_BUCKET" (project <> "-nagare-backups")
  baseDomain <- envOr "NAGARE_BASE_DOMAIN" "apps.example.com"
  instanceName <- envOr "NAGARE_INSTANCE_NAME" "nagare-01"
  pure
    TargetProfile
      { tpProject = project
      , tpRegion = region
      , tpZone = zone
      , tpRegistryHost = registryHost
      , tpArtifactRegistryId = registryId
      , tpImageBucket = imageBucket
      , tpBackupBucket = backupBucket
      , tpBaseDomain = baseDomain
      , tpInstanceName = instanceName
      }

-- | Read an env var, falling back to @def@ when it is unset OR set to the empty
-- string. Returns 'Text' for direct use in the record.
envOr :: String -> Text -> IO Text
envOr name def = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> T.pack v
    _ -> def
```

A note on the derivation order: `registryHost` and the buckets reference `region`/`project`, which
are resolved first, so their derived defaults pick up the *resolved* region/project (whether those
came from the environment or their own defaults). This matches EP-60's
`<region>-docker.pkg.dev` / `<project>-nagare-*` derivations exactly.


### Step M1.2 — register `Nagare.Target` in the cabal file

Edit `cli/nagarectl/nagarectl.cabal`. Add `Nagare.Target` to the library's `exposed-modules`
(insert alphabetically, between `Nagare.Static.Webhook` and `Nagare.Storage.Discover`, or anywhere
in the list). The `text` and `base` dependencies it needs are already present in the library's
`build-depends`, so no new dependency is required.

```diff
     Nagare.Static.Release
     Nagare.Static.Webhook
+    Nagare.Target
     Nagare.Storage.Discover
```

Confirm it builds:

```bash
cd cli/nagarectl && cabal build
```


### Step M1.3 — add `resolveTargetProfile` unit tests in `cli/nagarectl/test/Spec.hs`

The test suite uses `tasty`/`tasty-hunit` (`testGroup`, `testCase`, `@?=`). Add an import and a
test group, and add the group to the top-level `testGroup` list (find where the existing groups are
assembled in `Spec.hs` and append `targetProfileTests`). Use `System.Environment.setEnv`/`unsetEnv`
to drive resolution; because the suite is single-threaded by default, set and unset around each
case. (`setEnv`/`unsetEnv` are in `base`, already a dependency.)

```haskell
import Nagare.Target (TargetProfile (..), resolveTargetProfile, registryPrefix)
import System.Environment (setEnv, unsetEnv)

targetProfileTests :: TestTree
targetProfileTests =
  testGroup
    "Nagare.Target"
    [ testCase "defaults reproduce tan-nb-exp when nothing is set" $ do
        mapM_ unsetEnv allTargetVars
        tp <- resolveTargetProfile
        tpProject tp @?= "tan-nb-exp"
        tpRegion tp @?= "us-west1"
        tpZone tp @?= "us-west1-a"
        tpRegistryHost tp @?= "us-west1-docker.pkg.dev"
        tpBackupBucket tp @?= "tan-nb-exp-nagare-backups"
        tpImageBucket tp @?= "tan-nb-exp-nagare-images"
        registryPrefix tp @?= "us-west1-docker.pkg.dev/tan-nb-exp/nagare"
    , testCase "environment overrides the project and derives the rest" $ do
        mapM_ unsetEnv allTargetVars
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "CLOUDSDK_COMPUTE_REGION" "europe-west1"
        tp <- resolveTargetProfile
        tpProject tp @?= "acme-prod"
        -- registry host derives from the (overridden) region
        tpRegistryHost tp @?= "europe-west1-docker.pkg.dev"
        -- buckets derive from the (overridden) project
        tpBackupBucket tp @?= "acme-prod-nagare-backups"
        registryPrefix tp @?= "europe-west1-docker.pkg.dev/acme-prod/nagare"
        mapM_ unsetEnv allTargetVars
    , testCase "explicit derived vars win over the derivation" $ do
        mapM_ unsetEnv allTargetVars
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "NAGARE_REGISTRY_HOST" "custom.registry.example"
        setEnv "NAGARE_BACKUP_BUCKET" "my-bucket"
        tp <- resolveTargetProfile
        tpRegistryHost tp @?= "custom.registry.example"
        tpBackupBucket tp @?= "my-bucket"
        mapM_ unsetEnv allTargetVars
    ]
  where
    allTargetVars =
      [ "CLOUDSDK_CORE_PROJECT", "CLOUDSDK_COMPUTE_REGION", "CLOUDSDK_COMPUTE_ZONE"
      , "NAGARE_REGISTRY_HOST", "NAGARE_ARTIFACT_REGISTRY_ID", "NAGARE_IMAGE_BUCKET"
      , "NAGARE_BACKUP_BUCKET", "NAGARE_BASE_DOMAIN", "NAGARE_INSTANCE_NAME"
      ]
```

Run it:

```bash
cd cli/nagarectl && cabal test
```

Expected (abridged): the `Nagare.Target` group reports `OK` for all three cases. If the
"defaults reproduce tan-nb-exp" case fails because the environment already has `CLOUDSDK_CORE_PROJECT`
exported (the repo's `.envrc` does this), the `mapM_ unsetEnv allTargetVars` at the top of each case
removes it for the duration of the test — that is why every case begins by clearing the variables.


### Step M2.1 — thread the profile through `Image`, `Status`/`Probe`, and `Doctor`

`Nagare.Image` (`cli/nagarectl/src/Nagare/Image.hs`). Delete the `registryHost` constant (lines
32-33) and make `configureDockerAuth` take the host as an argument from the profile.

```diff
-- | Artifact Registry host for Docker credential configuration.
-registryHost :: String
-registryHost = "us-west1-docker.pkg.dev"
```

```diff
-configureDockerAuth :: IO ()
-configureDockerAuth =
-  run_ $
-    cmd "gcloud"
-      & addArgs ["auth", "configure-docker", registryHost, "--quiet"]
+-- | Run @gcloud auth configure-docker <host> --quiet@ for the resolved Artifact
+-- Registry host (EP-62; the host comes from 'Nagare.Target.tpRegistryHost').
+configureDockerAuth :: Text -> IO ()
+configureDockerAuth registryHost =
+  run_ $
+    cmd "gcloud"
+      & addArgs ["auth", "configure-docker", T.unpack registryHost, "--quiet"]
```

Update the one call site of `configureDockerAuth` (find it with `grep -rn configureDockerAuth
cli/nagarectl`; it is in a deploy path under `cli/nagarectl/src` or `app/Main.hs`) to resolve the
profile once and pass `tpRegistryHost`. The caller already runs in `IO`, so it can call
`resolveTargetProfile` (or be passed a `TargetProfile` the top-level handler resolved once).

`Nagare.Ops.Probe` (`cli/nagarectl/src/Nagare/Ops/Probe.hs`). `InventoryOpts` already has `ioZone`
and `ioInstance` fields — keep the record shape; only the *defaults* move out of
`defaultInventoryOpts`. No change is required to `Probe.hs` itself.

`Nagare.Ops.Status` (`cli/nagarectl/src/Nagare/Ops/Status.hs`). Replace the literal-bearing
`defaultInventoryOpts` (lines 36-43) and `defaultBackupBucket` (lines 47-48) with a profile-driven
builder, and parameterize `probeRegistryAuth` (lines 165-170).

```diff
-defaultInventoryOpts :: InventoryOpts
-defaultInventoryOpts =
-  InventoryOpts
-    { ioZone = "us-west1-a"
-    , ioInstance = "nagare-01"
-    , ioPulumiDir = "infra/pulumi"
-    , ioSkipVm = False
-    }
+-- | Build the inventory knobs from a resolved 'TargetProfile' (EP-62). The zone
+-- and instance come from the profile; the Pulumi project dir is fixed.
+inventoryOptsFor :: TargetProfile -> InventoryOpts
+inventoryOptsFor tp =
+  InventoryOpts
+    { ioZone = tpZone tp
+    , ioInstance = tpInstanceName tp
+    , ioPulumiDir = "infra/pulumi"
+    , ioSkipVm = False
+    }
```

```diff
-defaultBackupBucket :: Text
-defaultBackupBucket = "tan-nb-exp-nagare-backups"
```

`gatherInventory` reads the backup bucket from the Pulumi `backupBucket` output with
`defaultBackupBucket` as the fallback. Change its signature to take the resolved profile (or just
the backup bucket) so the fallback is `tpBackupBucket`:

```diff
-gatherInventory :: InventoryOpts -> IO [Probe]
-gatherInventory o = do
+gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]
+gatherInventory tp o = do
   publicIp <- stackOutput (ioPulumiDir o) "publicIp"
   baseDomain <- stackOutput (ioPulumiDir o) "baseDomain"
-  bucket <- maybe defaultBackupBucket id <$> stackOutput (ioPulumiDir o) "backupBucket"
+  bucket <- maybe (tpBackupBucket tp) id <$> stackOutput (ioPulumiDir o) "backupBucket"
```

and thread `tp` into `probeRegistryAuth`:

```diff
-      , probeRegistryAuth
+      , probeRegistryAuth tp
```

```diff
-probeRegistryAuth :: IO Probe
-probeRegistryAuth = do
-  m <- captureTool "gcloud" ["artifacts", "repositories", "describe", "nagare", "--location=us-west1"]
-  pure $ case m of
-    Just _ -> Probe "Artifact Registry" StatusOk "us-west1-docker.pkg.dev/tan-nb-exp/nagare reachable"
-    Nothing -> Probe "Artifact Registry" StatusUnknown "gcloud unavailable or no access"
+probeRegistryAuth :: TargetProfile -> IO Probe
+probeRegistryAuth tp = do
+  m <- captureTool "gcloud"
+         [ "artifacts", "repositories", "describe"
+         , T.unpack (tpArtifactRegistryId tp)
+         , "--location=" <> T.unpack (tpRegion tp)
+         ]
+  pure $ case m of
+    Just _ -> Probe "Artifact Registry" StatusOk (registryPrefix tp <> " reachable")
+    Nothing -> Probe "Artifact Registry" StatusUnknown "gcloud unavailable or no access"
```

Update the module export list and imports of `Nagare.Ops.Status` accordingly: export
`inventoryOptsFor` (replacing `defaultInventoryOpts`), import
`Nagare.Target (TargetProfile (..), registryPrefix)`. The two `app/Main.hs` call sites (lines
~1454, ~1465) become `let invOpts = (inventoryOptsFor tp) {ioSkipVm = ...}` after the handler
resolves `tp <- resolveTargetProfile`, and `gatherInventory tp invOpts`.

`Nagare.Ops.Doctor` (`cli/nagarectl/src/Nagare/Ops/Doctor.hs`). The remediation strings at lines
~89 (`"The VM nagare-01 is powered off."`), ~105 (`gcloud compute instances start nagare-01
--zone=us-west1-a`), ~125 (`gcloud auth configure-docker us-west1-docker.pkg.dev; ...`) embed the
instance, zone, and registry host. The cleanest change that keeps `remediationFor`/`why`/`command`
pure is to thread the `TargetProfile` through `gradeChecks`/`remediationFor` so these strings are
interpolated from the profile:

```diff
-gradeChecks :: [Probe] -> [Check]
-gradeChecks = map (\p -> Check p (remediationFor p))
+gradeChecks :: TargetProfile -> [Probe] -> [Check]
+gradeChecks tp = map (\p -> Check p (remediationFor tp p))
```

```diff
-remediationFor :: Probe -> Maybe Remediation
-remediationFor p = case probeStatus p of
+remediationFor :: TargetProfile -> Probe -> Maybe Remediation
+remediationFor tp p = case probeStatus p of
   ...
-        , remCommand = command (probeName p)
+        , remCommand = command tp (probeName p)
   ...
-        { remWhy = why (probeName p) (probeDetail p)
-        , remCommand = command (probeName p)
+        { remWhy = why tp (probeName p) (probeDetail p)
+        , remCommand = command tp (probeName p)
```

and interpolate the three strings:

```diff
-  | name == "VM" = "The VM nagare-01 is powered off."
+  | name == "VM" = "The VM " <> tpInstanceName tp <> " is powered off."
```

```diff
-  | name == "VM" = "gcloud compute instances start nagare-01 --zone=us-west1-a"
+  | name == "VM" =
+      "gcloud compute instances start " <> tpInstanceName tp <> " --zone=" <> tpZone tp
```

```diff
-  | name == "Artifact Registry" =
-      "gcloud auth configure-docker us-west1-docker.pkg.dev; "
-        <> "verify the nagare-node service account holds roles/artifactregistry.writer"
+  | name == "Artifact Registry" =
+      "gcloud auth configure-docker " <> tpRegistryHost tp <> "; "
+        <> "verify the nagare-node service account holds roles/artifactregistry.writer"
```

Make `why` and `command` take `tp` as their first argument; import
`Nagare.Target (TargetProfile (..))`. Update the `app/Main.hs` doctor handler to call
`gradeChecks tp checks` after resolving `tp`. (The existing `Spec.hs` doctor tests that call
`remediationFor`/`gradeChecks` must be updated to pass a `TargetProfile` — construct one inline,
e.g. a `defaultTestProfile = TargetProfile{...}` test helper with the `tan-nb-exp` values, so the
existing assertions still hold.)


### Step M2.2 — remove the CDN `--project=tan-nb-exp` literals

`Nagare.Cdn.Provision` (`cli/nagarectl/src/Nagare/Cdn/Provision.hs`). Add a project field to
`GcpStackRefs` (the record already carries the Google-only inputs) and read it instead of the
literal in `gcloudDnsUpsertArgs` and `gcloudBackendCacheArgs`.

```diff
 data GcpStackRefs = GcpStackRefs
   { gsrGlobalIp :: !Text
   , gsrBackendService :: !Text
   , gsrUrlMap :: !Text
   , gsrDnsZone :: !Text
+  , gsrProject :: !Text
+  -- ^ the GCP project the gcloud argv target (EP-62; from 'Nagare.Target.tpProject')
   }
```

The argv builders currently take only their specific arguments. Thread the project in. Two clean
options: (a) add a `Text` project parameter to each builder, or (b) pass the whole `GcpStackRefs`.
Option (a) keeps the builders narrowly testable:

```diff
-gcloudDnsUpsertArgs :: Text -> Text -> Text -> [Text]
-gcloudDnsUpsertArgs zone hostname ip =
+gcloudDnsUpsertArgs :: Text -> Text -> Text -> Text -> [Text]
+gcloudDnsUpsertArgs project zone hostname ip =
   [ "dns", "record-sets", "create", hostname <> "."
   , "--type=A", "--ttl=300", "--rrdatas=" <> ip, "--zone=" <> zone
-  , "--project=tan-nb-exp"
+  , "--project=" <> project
   ]
```

```diff
-gcloudBackendCacheArgs :: Text -> Cdn -> [Text]
-gcloudBackendCacheArgs backendService cdn =
+gcloudBackendCacheArgs :: Text -> Text -> Cdn -> [Text]
+gcloudBackendCacheArgs project backendService cdn =
   [ "compute", "backend-services", "update", backendService
   , "--cache-mode=" <> cacheMode ]
     ++ maybe [] (\t -> ["--default-ttl=" <> tshow t]) (defaultTtlSeconds cdn)
-    ++ ["--project=tan-nb-exp"]
+    ++ ["--project=" <> project]
```

Update `gcpActions` (the only caller of these builders) to pass `gsrProject refs`:

```diff
 gcpActions cdn target refs =
-  [ GcloudCmd (gcloudDnsUpsertArgs (gsrDnsZone refs) h (gsrGlobalIp refs))
+  [ GcloudCmd (gcloudDnsUpsertArgs (gsrProject refs) (gsrDnsZone refs) h (gsrGlobalIp refs))
   | h <- cdnHostnames target
   ]
-    ++ [GcloudCmd (gcloudBackendCacheArgs (gsrBackendService refs) cdn)]
+    ++ [GcloudCmd (gcloudBackendCacheArgs (gsrProject refs) (gsrBackendService refs) cdn)]
```

`app/Main.hs`. `gatherGcpStackRefs` (lines ~1850-1857) builds the `GcpStackRefs`; add the resolved
project. It must resolve the profile (or be passed one); resolve once and add the field:

```diff
-gatherGcpStackRefs :: IO GcpStackRefs
-gatherGcpStackRefs = do
+gatherGcpStackRefs :: TargetProfile -> IO GcpStackRefs
+gatherGcpStackRefs tp = do
   let so name = fromMaybe ("<" <> name <> ">") <$> stackOutput "infra/pulumi" name
   GcpStackRefs
     <$> so "cdnGlobalIp"
     <*> so "cdnBackendService"
     <*> so "cdnUrlMap"
     <*> so "dnsZoneName"
+    <*> pure (tpProject tp)
```

The two callers of `gatherGcpStackRefs` (in `cdnDeployStep` line ~1838 and `runCdnDisable` line
~1560) resolve `tp <- resolveTargetProfile` and pass it. In `runCdnDisable` (lines ~1557-1584),
also remove the two `tan-nb-exp` literals — the `--project` argv (line ~1568) becomes
`"--project=" <> tpProject tp` and the error-message tail (line ~1583) becomes
`<> " (is it a Google-CDN hostname? is gcloud configured for " <> tpProject tp <> "?)"`.

The existing `Spec.hs` CDN tests that call `gcloudDnsUpsertArgs`/`gcloudBackendCacheArgs`/`planCdn`
with a `GcpStackRefs` literal must be updated to pass the new `gsrProject` field and the new
argument; set them to `"tan-nb-exp"` so the existing golden assertions hold, then add one case with
`gsrProject = "acme-prod"` asserting the argv now contains `--project=acme-prod` (this is the
fail-before/pass-after evidence for M2.2).


### Step M2.3 — parameterize the rendered Job env in DB Backup/Restore and Storage Snapshot

These three renderers hard-code `CLOUDSDK_CORE_PROJECT` to `tan-nb-exp` in the Job they produce.
Add a project field to each renderer's inputs record (or pass a `Text` project) and emit it.

`Nagare.Database.Backup` (`cli/nagarectl/src/Nagare/Database/Backup.hs`). Add `bjiProject :: !Text`
to `BackupJobInputs` and use it in `uploadContainer` (line ~196):

```diff
 data BackupJobInputs = BackupJobInputs
   { bjiNamespace :: !Text
   ...
   , bjiSelfPrune :: !Bool
+  , bjiProject :: !Text
+  -- ^ the GCP project for the upload container's CLOUDSDK_CORE_PROJECT (EP-62)
   }
```

```diff
           , plainEnv "GCE_METADATA_HOST" "169.254.169.254"
-          , plainEnv "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
+          , plainEnv "CLOUDSDK_CORE_PROJECT" (bjiProject i)
```

`renderDbBackupCronJob` and `runDbBackup` both build `BackupJobInputs`; give each a project
parameter. `renderDbBackupCronJob`'s signature grows one `Text`:

```diff
-renderDbBackupCronJob :: Text -> Text -> Engine -> Text -> Text -> Int -> ByteString
-renderDbBackupCronJob ns name eng version bucket keep =
+renderDbBackupCronJob :: Text -> Text -> Engine -> Text -> Text -> Int -> Text -> ByteString
+renderDbBackupCronJob ns name eng version bucket keep project =
   renderBackupCronJob
     BackupCronInputs
       { bciSchedule = defaultBackupSchedule
       , bciBase =
           BackupJobInputs
             { bjiNamespace = ns
             ...
             , bjiSelfPrune = True
+            , bjiProject = project
             }
       }
```

`runDbBackup` (line ~332) gains a project parameter resolved by its caller in `app/Main.hs`:
`runDbBackup ns name bucket keep project dryRun = ...` with `bjiProject = project` in `jobInputs`.

`Nagare.Database.Create` calls `renderDbBackupCronJob` (the create-time CronJob). Pass the resolved
project there too (this is the same handler that has the duplicate `resolveBackupBucket`; see M2.4).

`Nagare.Database.Restore` (`cli/nagarectl/src/Nagare/Database/Restore.hs`). Add a project field to
its inputs record (`RestoreJobInputs`) and replace line ~117:

```diff
           , plainEnv "GCE_METADATA_HOST" "169.254.169.254"
-          , plainEnv "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
+          , plainEnv "CLOUDSDK_CORE_PROJECT" (rjiProject i)
```

`Nagare.Storage.Snapshot` (`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`). Add a project field to
`SnapshotJobInputs` and replace line ~163:

```diff
                       [ envVar "DEST" (sjiDestUrl i)
                       , envVar "GCE_METADATA_HOST" "169.254.169.254"
-                      , envVar "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
+                      , envVar "CLOUDSDK_CORE_PROJECT" (sjiProject i)
                       ]
```

For each, the `app/Main.hs` (and `Nagare.Database.Create`) handler that builds the inputs resolves
the profile once and sets the new field to `tpProject tp`. The existing `Spec.hs` tests that build
these input records (e.g. `RestoreJobInputs` is imported in `Spec.hs`) must set the new field; set
it to `"tan-nb-exp"` to keep current goldens, then add the M2 fail-before/pass-after assertion (see
Validation).


### Step M2.4 — unify `resolveBackupBucket` and remove the remaining literals

There are two `resolveBackupBucket` functions. Replace both with the profile.

`app/Main.hs` (lines ~2315-2321). Keep the `--bucket` override but fall back to the profile:

```diff
-resolveBackupBucket :: Maybe String -> IO Text
-resolveBackupBucket (Just b) = pure (T.pack b)
-resolveBackupBucket Nothing = do
-  menv <- lookupEnv "NAGARE_BACKUP_BUCKET"
-  pure (maybe "tan-nb-exp-nagare-backups" T.pack menv)
+-- | Resolve the GCS backup bucket: an explicit @--bucket@ flag wins; otherwise
+-- the resolved target profile's backup bucket (EP-62; honors NAGARE_BACKUP_BUCKET
+-- and the <project>-nagare-backups derivation).
+resolveBackupBucket :: TargetProfile -> Maybe String -> IO Text
+resolveBackupBucket _ (Just b) = pure (T.pack b)
+resolveBackupBucket tp Nothing = pure (tpBackupBucket tp)
```

Its three callers (lines ~2231, ~2265, ~2268) pass the resolved `tp`. Likewise, `resolveBaseDomain`
(lines ~2485-2489) becomes `resolveBaseDomain tp (Just bd) = ...; resolveBaseDomain tp Nothing =
pure (tpBaseDomain tp)`.

`Nagare.Database.Create` (lines ~182-187). Delete its local `resolveBackupBucket :: IO Text` and
have the create handler accept the bucket (and project) from `app/Main.hs`, which already resolves
the profile, OR call `Nagare.Target.resolveTargetProfile` directly in the create handler. Prefer
having `app/Main.hs` resolve once and pass `tpBackupBucket tp`/`tpProject tp` into the create call
so there is a single resolution per command invocation.

After these edits, prove no literal remains:

```bash
grep -rn 'tan-nb-exp\|us-west1\b\|us-west1-a\|nagare-01' cli/nagarectl/src cli/nagarectl/app
```

Expected: no matches (the only remaining `us-west1` mentions allowed are in Haddock comments such
as `Probe.hs` line 85 `-- ^ compute zone, e.g. "us-west1-a"`, which are documentation, not behavior;
you may leave those or reword them — they do not affect resolution). Then:

```bash
cd cli/nagarectl && cabal test
```


### Step M3.1 — add the image-prefix derivation in `nagare-dsl`

Add a small pure module `cli/nagare-dsl/src/Nagare/Dsl/Image.hs` (no new dependency: `text` is
already a `nagare-dsl` dependency) that joins a resolved registry prefix with a short image name.
It re-uses `mkImageRef` so the colon/non-empty validation still applies.

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Deriving a fully-qualified container image reference from a short image NAME
-- plus a registry PREFIX supplied at deploy time (MasterPlan 12 Integration
-- Point 4, EP-62 M3). An app's Config.hs supplies only the name (e.g. "notes");
-- nagarectl prepends "<host>/<project>/<repo-id>" resolved from the target
-- profile, so application source no longer bakes in the GCP project/region.
-- 'mkImageRef' is retained for fully-qualified refs (e.g. a public registry).
module Nagare.Dsl.Image
  ( mkImageName
  , imageRefFromName
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Nagare.Dsl.Types (ImageRef, mkImageRef)

-- | Join a registry prefix and a short image name into a fully-qualified
-- 'ImageRef', validating the result through 'mkImageRef'. The @name@ must be a
-- bare name with no slash or tag; the @prefix@ is "<host>/<project>/<repo-id>".
-- Example: @imageRefFromName "us-west1-docker.pkg.dev/tan-nb-exp/nagare" "notes"@
-- yields an 'ImageRef' over "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes".
imageRefFromName :: Text -> Text -> Either Text ImageRef
imageRefFromName prefix name =
  mkImageRef (T.dropWhileEnd (== '/') prefix <> "/" <> name)

-- | An alias used in Config.hs surfaces: build an 'ImageRef' from a bare name,
-- deferring the prefix to deploy time. NOTE: because the prefix is not known at
-- Config.hs evaluation, the DSL marks a name-only image specially (see M3.2);
-- this helper exists for the prefix-known case and for tests.
mkImageName :: Text -> Either Text ImageRef
mkImageName = mkImageRef
```

Register it in `cli/nagare-dsl/nagare-dsl.cabal` `exposed-modules` (alphabetically near
`Nagare.Dsl.Load`):

```diff
     Nagare.Dsl.Load
+    Nagare.Dsl.Image
```

### Step M3.2 — apply the prefix at the CLI deploy/load boundary

Decision (recorded in the Decision Log): the prefix is applied in **nagarectl**, not in the DSL
`Config.hs` evaluation, because the DSL library is environment-agnostic and must not know "the
operator's project". The mechanism: an app's `Config.hs` emits a **name-only** image string (e.g.
`"notes"`) by passing the bare name to `mkImageRef` (which accepts it — a bare name has no colon).
`nagarectl`, immediately after it loads the typed value from the compiled `Config.hs` JSON, rewrites
the image to the fully-qualified form *if it is name-only* (contains no `/`), by prepending the
resolved `registryPrefix tp`. A fully-qualified ref (one containing a `/`, e.g.
`gcr.io/knative-samples/helloworld-go`, or an already-prefixed Artifact Registry path) is left
untouched, preserving back-compat.

Concretely, in the CLI load path (the code in `cli/nagarectl/src/Nagare/Deploy.hs` or the relevant
`Static`/`Server` deploy module that calls `Nagare.Dsl.Load` and then reads `dep ^. #image`), add a
normalization step after load and before the image is built/rendered:

```haskell
-- In nagarectl, after loading the Deployment/StaticSite/ServerSite:
import Nagare.Target (TargetProfile, registryPrefix)
import Nagare.Dsl.Types (imageRefText, mkImageRef)
import qualified Data.Text as T

-- | If the loaded image is a bare name (no '/'), qualify it with the resolved
-- registry prefix; otherwise leave it as-is (already fully qualified, e.g. a
-- public registry). EP-62 M3 / MasterPlan 12 IP4.
qualifyImage :: TargetProfile -> ImageRef -> Either Text ImageRef
qualifyImage tp ref =
  let t = imageRefText ref
   in if T.any (== '/') t
        then Right ref                                   -- already qualified
        else mkImageRef (registryPrefix tp <> "/" <> t)  -- bare name -> prefix it
```

Apply `qualifyImage tp` to the loaded value's image field at the single deploy entry point so all
of `deploy`, static, and server paths get it. (The image is read for build/push/render in
`Nagare.Image.imageRef`, `Nagare.Server.Deploy`, `Nagare.Static.Deploy` — qualifying once at load
time means those untouched call sites see the qualified ref.)

A `nagare-dsl` round-trip test in `cli/nagare-dsl/test/Spec.hs` proves the derivation and that the
JSON `image` field round-trips:

```haskell
import Nagare.Dsl.Image (imageRefFromName)
import Nagare.Dsl.Types (imageRefText)

-- prefix derivation produces the expected fully-qualified path
test_imageRefFromName :: Assertion
test_imageRefFromName =
  fmap imageRefText (imageRefFromName "us-west1-docker.pkg.dev/tan-nb-exp/nagare" "notes")
    @?= Right "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
```

(The existing fixture round-trip tests in `cli/nagare-dsl/test/Spec.hs` that compile-and-run the
`static-site`/`server-site` fixtures already exercise the `Config.hs` -> JSON `image` -> `mkImageRef`
path; after M3.3 those fixtures emit a name-only image, so update their expected `image` value to
the bare name and let the CLI-side `qualifyImage` add the prefix — the DSL round-trip itself
remains over the bare name.)


### Step M3.3 — rewrite the example/fixture `Config.hs` files to the name-only form

Edit each app's `Config.hs` to pass only the image's short name. For the `mkImageRef` sites, drop
the `us-west1-docker.pkg.dev/tan-nb-exp/nagare/` prefix; for the `webService` sites (which take the
image as the second argument), drop the same prefix.

Fixtures (these are exercised by `cli/nagare-dsl/test/Spec.hs`):
- `cli/nagare-dsl/test/fixtures/static-site/nagare/Config.hs` line 20:
  `mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"` -> `mkImageRef "notes"`.
- `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs` line 21:
  `mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes-app"` -> `mkImageRef "notes-app"`.

Examples (all under `cluster/examples/*/nagare/Config.hs`), drop the prefix in each:
`app-cleanup-task` (postgres-app), `clickhouse-analytics`, `dockerfile-app`, `app-lifecycle-demo`
(lifecycle-demo), `nixpacks-app`, `env-and-secrets` (envdemo), `heartbeat-task` (heartbeat-app),
`postgres-app`, `static-cdn-site`, `static-site`, `sqlite-pvc-litestream`, `redis-cache`,
`uploads-volume`, `tanstack-start`, `tanstack-start-cdn`. (The grep in Concrete Steps M2.4 lists the
exact lines.) Example edit:

```diff
-  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-site")
+  img' <- mapLeft show (mkImageRef "static-site")
```

```diff
-  dep <- mapLeft show (webService "redis-cache" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/redis-cache")
+  dep <- mapLeft show (webService "redis-cache" "redis-cache")
```

Leave `cluster/examples/hello-knative-service/nagare/Config.hs` unchanged
(`gcr.io/knative-samples/helloworld-go` is a fully-qualified public ref; `qualifyImage` leaves it
alone because it contains `/`).

Run both suites:

```bash
cd cli/nagare-dsl && cabal test
cd ../nagarectl && cabal test
```


## Validation and Acceptance

Acceptance is observable behavior — tests that fail before this change and pass after, and rendered
output that changes when the environment changes — not the mere presence of a record.

The project's test command is `cabal test`, run inside each package directory
(`cli/nagarectl/` and `cli/nagare-dsl/`), as established by EP-10 and EP-12
(`docs/plans/10-...` and `docs/plans/12-...`). Build first if needed with `cabal build`.

**A1 — `resolveTargetProfile` honors env vars and falls back (M1).** From `cli/nagarectl`,
`cabal test` runs the `Nagare.Target` group: with all variables unset the profile is the
`tan-nb-exp`/`us-west1`/`us-west1-a` defaults with `registryPrefix = us-west1-docker.pkg.dev/
tan-nb-exp/nagare`; with `CLOUDSDK_CORE_PROJECT=acme-prod` and `CLOUDSDK_COMPUTE_REGION=europe-west1`
set, the project is `acme-prod`, the host derives to `europe-west1-docker.pkg.dev`, and the buckets
to `acme-prod-nagare-*`. This group did not exist before, so it is fail-before (does not compile —
no `Nagare.Target`) / pass-after.

**A2 — rendered DB-backup Job env changes with the profile (M2).** Add this test to
`cli/nagarectl/test/Spec.hs`; it renders the backup Job and inspects the `CLOUDSDK_CORE_PROJECT`
env value. Before M2 the value is the literal `tan-nb-exp` regardless of inputs (so the second
assertion fails); after M2 it follows `bjiProject`:

```haskell
import Nagare.Database.Backup (BackupJobInputs (..), renderBackupJob)
import qualified Data.ByteString.Char8 as BC

backupProjectTests :: TestTree
backupProjectTests =
  testGroup "backup Job CLOUDSDK_CORE_PROJECT"
    [ testCase "defaults to tan-nb-exp" $
        assertBool "tan-nb-exp present"
          ("CLOUDSDK_CORE_PROJECT" `BC.isInfixOf` rendered "tan-nb-exp"
             && "tan-nb-exp" `BC.isInfixOf` rendered "tan-nb-exp")
    , testCase "follows the resolved project" $
        assertBool "acme-prod present"
          ("acme-prod" `BC.isInfixOf` rendered "acme-prod")
    ]
  where
    rendered project = renderBackupJob (sampleInputs project)
    sampleInputs project =
      BackupJobInputs
        { bjiNamespace = "personal", bjiJobName = "nagare-dbbackup-notes"
        , bjiEngine = Postgres, bjiClientImage = "postgres:18"
        , bjiSvcHost = "notes", bjiSecretName = "notes-db"
        , bjiName = "notes", bjiDestUrl = "gs://b/databases/notes/x.sql.gz"
        , bjiPrefix = "gs://b/databases/notes/", bjiKeep = 7
        , bjiSelfPrune = False, bjiProject = project
        }
```

The same shape proves the restore Job (`renderRestoreJob`) and the snapshot Job
(`renderSnapshotJob`) carry the resolved project. The CDN argv test asserts
`gcloudDnsUpsertArgs "acme-prod" "zone" "h" "ip"` contains `"--project=acme-prod"` and not
`"--project=tan-nb-exp"`.

**A3 — with NAGARE_* unset the Job still says the default project; with them set it changes (M2,
end-to-end).** This is the operator-observable version of A2, exercised through the resolution
layer rather than a hand-built record:

```bash
cd cli/nagarectl
# Build the CLI once.
cabal build
# Unset everything: the rendered backup Job carries the default project.
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_BACKUP_BUCKET \
  cabal run nagarectl -- db backup notes --dry-run 2>/dev/null | grep -A1 CLOUDSDK_CORE_PROJECT
# Expect a line:  value: tan-nb-exp
# Set the project: the same command renders acme-prod.
CLOUDSDK_CORE_PROJECT=acme-prod \
  cabal run nagarectl -- db backup notes --dry-run 2>/dev/null | grep -A1 CLOUDSDK_CORE_PROJECT
# Expect a line:  value: acme-prod
```

`db backup --dry-run` renders the Job/CronJob manifests and applies nothing (it reaches the cluster
only to resolve the database; if no cluster is reachable the dry-run still prints the manifest after
the resolve step, or use a database name that the renderer can template — the assertion is on the
rendered `CLOUDSDK_CORE_PROJECT` value, which is independent of any cluster call). The point is that
the only thing that changed between the two runs is the environment, and the rendered project
followed it.

**A4 — an app deploys to a different registry prefix purely via env (M3).** With a name-only
`Config.hs` (e.g. `cluster/examples/static-site` after M3.3, whose image is now `static-site`), the
rendered image reference follows the environment. Demonstrate it through the `nagare-dsl` round-trip
plus the CLI `qualifyImage` step:

```bash
cd cli/nagare-dsl && cabal test    # imageRefFromName + fixture round-trip over the bare name
cd ../nagarectl   && cabal test    # qualifyImage prefixes the bare name from the profile
```

and the behavioral check that the *same* app source produces different image refs under different
environments (the registry prefix is the only difference):

```bash
cd cli/nagarectl
# unset -> default tan-nb-exp registry
env -u CLOUDSDK_CORE_PROJECT cabal run nagarectl -- deploy --dry-run cluster/examples/static-site 2>/dev/null | grep -i 'image:'
# Expect: ...us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-site:<tag>
# set -> acme-prod registry, same Config.hs
CLOUDSDK_CORE_PROJECT=acme-prod NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev \
  cabal run nagarectl -- deploy --dry-run cluster/examples/static-site 2>/dev/null | grep -i 'image:'
# Expect: ...us-west1-docker.pkg.dev/acme-prod/nagare/static-site:<tag>
```

(If the static-site path uses a different dry-run flag, use the equivalent render-only path for that
kind; the load-then-`qualifyImage` step is shared, so any kind demonstrates the prefix change.)

**A5 — no literal regression.** `grep -rn 'tan-nb-exp' cli/nagarectl/src cli/nagarectl/app
cli/nagare-dsl/src cluster/examples/*/nagare/Config.hs cli/nagare-dsl/test/fixtures` returns nothing
(the only `tan-nb-exp` strings allowed to remain are the *default* fallbacks inside
`Nagare/Target.hs` and inside the `Nagare.Target` and golden tests, which are how "do nothing keeps
today's behavior" is realized). This proves application source and CLI behavior no longer hard-code
the project.


## Idempotence and Recovery

Every step is additive and safe to repeat. Creating `Nagare/Target.hs` and `Nagare/Dsl/Image.hs` is
idempotent (re-writing overwrites with identical content). The cabal `exposed-modules` edits are
one-line additions; if already applied, re-applying is a no-op (the `old_string` will not be found,
signalling the edit is in place). The literal-removal edits are textual replacements; if a `diff` is
already applied, the original literal is gone and the replacement is present.

No step makes a GCP call, applies a Kubernetes manifest, or mutates cloud state — every validation
uses `cabal test` or a `--dry-run` render, so there is nothing to roll back in the cloud. If a build
breaks mid-milestone (e.g. a consumer not yet rewired after a signature change), the compiler points
at the exact unrewired call site; finish threading the `TargetProfile` argument and rebuild. Because
the defaults reproduce `tan-nb-exp`, a partially-migrated tree still behaves identically to today
for the migrated paths, so milestones can be committed independently.

Recommended commit points (Conventional Commits, per repo policy): after M1
(`feat(cli): EP-62 M1 TargetProfile resolution layer + tests`), after M2
(`refactor(cli): EP-62 M2 thread TargetProfile, remove tan-nb-exp/registryHost literals`), after M3
(`feat(dsl): EP-62 M3 derive image-ref prefix from target profile; name-only Config.hs`).


## Interfaces and Dependencies

This plan **hard-depends on EP-60**
(`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`), which fixes the
nine environment-variable names and their fallback defaults (restated in Context and Orientation).
This plan reads those variables from the process environment; it does not parse `nagare.target.env`
(EP-60's `.envrc` exports the variables). EP-63 (`nagarectl init`) will reuse the `TargetProfile`
record and `resolveTargetProfile` defined here (MasterPlan 12 Dependency Graph).

**New module `Nagare.Target` (in the `nagarectl` library).** Required signatures at the end of M1:

```haskell
data TargetProfile = TargetProfile
  { tpProject            :: !Text
  , tpRegion             :: !Text
  , tpZone               :: !Text
  , tpRegistryHost       :: !Text
  , tpArtifactRegistryId :: !Text
  , tpImageBucket        :: !Text
  , tpBackupBucket       :: !Text
  , tpBaseDomain         :: !Text
  , tpInstanceName       :: !Text
  }

resolveTargetProfile :: IO TargetProfile
registryPrefix       :: TargetProfile -> Text   -- "<host>/<project>/<repo-id>"
```

The env-var contract (from EP-60, environment-or-default half): `CLOUDSDK_CORE_PROJECT`
(`tan-nb-exp`), `CLOUDSDK_COMPUTE_REGION` (`us-west1`), `CLOUDSDK_COMPUTE_ZONE` (`us-west1-a`),
`NAGARE_REGISTRY_HOST` (`<region>-docker.pkg.dev`), `NAGARE_ARTIFACT_REGISTRY_ID` (`nagare`),
`NAGARE_IMAGE_BUCKET` (`<project>-nagare-images`), `NAGARE_BACKUP_BUCKET`
(`<project>-nagare-backups`), `NAGARE_BASE_DOMAIN` (`apps.example.com`), `NAGARE_INSTANCE_NAME`
(`nagare-01`). An empty value is treated as unset.

**New module `Nagare.Dsl.Image` (in the `nagare-dsl` library).** Required signatures at the end of
M3:

```haskell
imageRefFromName :: Text -> Text -> Either Text ImageRef   -- prefix -> name -> ref
mkImageName      :: Text -> Either Text ImageRef           -- bare name (alias of mkImageRef)
```

and the CLI-side normalizer (in a `nagarectl` deploy module):

```haskell
qualifyImage :: TargetProfile -> ImageRef -> Either Text ImageRef
-- bare name (no '/')  -> registryPrefix tp <> "/" <> name
-- already qualified   -> unchanged (back-compat with mkImageRef public refs)
```

**Changed signatures threaded through consumers (M2).** `Nagare.Ops.Status`:
`gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]`,
`inventoryOptsFor :: TargetProfile -> InventoryOpts` (replaces `defaultInventoryOpts`),
`probeRegistryAuth :: TargetProfile -> IO Probe`; `defaultBackupBucket` removed.
`Nagare.Ops.Doctor`: `gradeChecks :: TargetProfile -> [Probe] -> [Check]`,
`remediationFor :: TargetProfile -> Probe -> Maybe Remediation`. `Nagare.Image`: `registryHost`
removed; `configureDockerAuth :: Text -> IO ()`. `Nagare.Cdn.Provision`: `GcpStackRefs` gains
`gsrProject :: !Text`; `gcloudDnsUpsertArgs :: Text -> Text -> Text -> Text -> [Text]` and
`gcloudBackendCacheArgs :: Text -> Text -> Cdn -> [Text]` gain a leading project parameter.
`Nagare.Database.Backup`: `BackupJobInputs` gains `bjiProject :: !Text`; `renderDbBackupCronJob` and
`runDbBackup` gain a project parameter. `Nagare.Database.Restore`: its inputs record gains
`rjiProject :: !Text`. `Nagare.Storage.Snapshot`: `SnapshotJobInputs` gains `sjiProject :: !Text`.
`app/Main.hs`: `gatherGcpStackRefs :: TargetProfile -> IO GcpStackRefs`;
`resolveBackupBucket :: TargetProfile -> Maybe String -> IO Text`;
`resolveBaseDomain :: TargetProfile -> Maybe String -> IO Text`; the two `runCdnDisable`
`tan-nb-exp` literals removed.

**Libraries used.** `text` and `base` (`System.Environment.lookupEnv`/`setEnv`/`unsetEnv`) — both
already direct dependencies of `nagarectl` and `nagare-dsl`. `tasty`/`tasty-hunit` for the new
tests (already test dependencies). `optparse-applicative` is unchanged: existing override flags
(`--bucket`, `--base-domain`) keep their `Maybe`-yielding parsers and now fall back to the profile
instead of a literal; no flag becomes required. No new dependency is introduced; no `gogol`/env-config
library is needed (the resolution is a handful of `lookupEnv` calls). Per the user's global rule,
APIs for any dependency were taken from the dependency's own source via `mori`, not guessed.
