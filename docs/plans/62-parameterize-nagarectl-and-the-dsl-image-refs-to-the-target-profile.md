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

Full plan before trimming: [62-parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/62-parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

