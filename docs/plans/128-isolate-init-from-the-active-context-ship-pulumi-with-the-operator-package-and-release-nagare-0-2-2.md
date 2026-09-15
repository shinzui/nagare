---
id: 128
slug: isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2
title: "Isolate init from the active context, ship Pulumi with the operator package, and release Nagare 0.2.2"
kind: exec-plan
created_at: 2026-09-14T00:06:12Z
intention: "intention_01m2ekfg61edmbtnvv0tbkhprd"
provenance:
  created_by:
    model: "claude-opus-5"
    harness: "claude-code"
    at: 2026-09-14T00:06:12Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T00:22:36Z
      mode: "implement"
      note: "Validated Milestone 1 and began the init isolation implementation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
---

# Isolate init from the active context, ship Pulumi with the operator package, and release Nagare 0.2.2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare 0.2.0 and 0.2.1 cannot onboard a new cloud cluster. The operator rolling out a second
cluster, for the GCP project `tan-ng-labs`, hit three defects in a row. They are recorded as
improvement requests (IRs) in this repository:

1. `nagarectl host init` writes a NixOS option the host module does not declare, so no new host
   flake validates. This is IR-13,
   [docs/improvement-requests/host-init-renders-an-unknown-host-option.md](../improvement-requests/host-init-renders-an-unknown-host-option.md).
   It is already fixed on `master` in commit `3a107d3`, but no release contains the fix.
2. `nagarectl init NAME` copies values from whichever context is currently selected. On
   2026-09-13, creating `labs` for `tan-ng-labs` while the live `tan-nb-exp` context was current
   produced a context that pointed at `tan-nb-exp-nagare-images` and `tan-nb-exp-nagare-backups`,
   another cluster's live buckets. This is IR-7,
   [docs/improvement-requests/init-must-not-inherit-the-active-context.md](../improvement-requests/init-must-not-inherit-the-active-context.md).
3. The installable `nagare` package ships no `pulumi` binary. `init` enables APIs, creates the
   Pulumi state bucket, writes the context, and only then crashes with an uncaught `posix_spawnp`
   exception. Its recovery hints then point at a command that refuses to run. This is IR-8,
   [docs/improvement-requests/ship-pulumi-with-the-operator-package.md](../improvement-requests/ship-pulumi-with-the-operator-package.md).

After this plan, an operator can run `nix profile install github:shinzui/nagare/v0.2.2#nagare`
and then `nagarectl init labs --project tan-ng-labs …` with any context current. The command
produces a context whose buckets, registry, and Pulumi backend all belong to `tan-ng-labs`, and it
prints those derived names before it changes anything. It finds `pulumi` inside the package. If a
required tool is missing, it refuses before any side effect. Every failure after the context file
is written names a recovery command that works. `nagarectl host init` then produces a host flake
that evaluates.

To see it working after release, run
`nix shell github:shinzui/nagare/v0.2.2#nagare -c nagarectl version --json --tools`. The output
reports `"version":"0.2.2"` and a `tools.pulumi` path inside the Nix store. Then run
`nagarectl init newctx --project p --acme-email ops@example.com --dry-run --skip-preflight` with
some other context current. The printed context says `NAGARE_IMAGE_BUCKET=p-nagare-images`.

The user fixed the scope of this plan: release 0.2.2 with IR-13, IR-7, and IR-8. IR-9 (the
context guard misreports a missing `pulumi`) and IR-14 (default host names collide on a shared
tailnet) are related but out of scope. The Decision Log records why.


## Progress

- [x] (2026-09-14 00:06Z) Plan created. IR-13, IR-7, and IR-8 accepted and linked to this plan in
  the IR bundle (see Milestone 1).
- [x] (2026-09-13, before this plan) IR-13 code fix landed in `3a107d3`. `nix flake check` passed
  on aarch64-darwin with 29 checks, including `host-module-options-agree`. The result was relayed
  by the session that made the fix.
- [x] (2026-09-14 00:22Z) Milestone 1: the IR bundle acceptance is committed at `15754d8`;
  all 454 `nagarectl-test` cases, including the IR-13 HostSpec golden, pass; and
  `host-module-options-agree` builds successfully.
- [x] (2026-09-14 00:24Z) Milestone 1 remaining: the isolated `host init --dry-run` transcript
  prints only `hostName = "ir13-host";` for the host-name option.
- [x] (2026-09-14 00:53Z) Milestone 2: pure `init` base resolution (`initContextMap`, `resolveInitBase`) in
  `cli/nagarectl/src/Nagare/Init.hs`, with unit tests.
- [x] (2026-09-14 00:53Z) Milestone 2: derived-name ownership check (`checkInitOwnership`) and the derived-field
  summary (`renderInitSummary`), with unit tests.
- [x] (2026-09-14 00:53Z) Milestone 2: rewire `runInit` in `cli/nagarectl/app/Main.hs` for named contexts. Prompt
  defaults come from the base, the child-process environment is exported from the new profile,
  and the dry-run API enable is printed from Haskell.
- [x] (2026-09-14 00:53Z) Milestone 2: the hermetic foreign-current-context, fresh-init,
  forced-init, and ownership-refusal scenarios pass in `nagare-clone-free-platform`.
- [x] (2026-09-14 00:53Z) Milestone 3: add `pulumi` and `pulumi-language-nodejs` to an operator-only `nagarectl`
  wrapper (`--suffix`) and to the `nagare` launcher (appended PATH) in `nix/haskell-packages.nix`,
  leaving the app-developer `#nagarectl` output unchanged.
- [x] (2026-09-14 00:53Z) Milestone 3: tool preflight (`requiredInitTools`, `findMissingTools`) before the first side
  effect. `seedPulumiConfig` must not throw on a missing binary.
- [x] (2026-09-14 00:53Z) Milestone 3: recovery hints name `nagarectl context use NAME` or a safe
  `init NAME --force`, and `nextStepsText` renders `nagare <recipe>` for installed payloads.
- [x] (2026-09-14 00:53Z) Milestone 3: `nagarectl version --tools` reports resolved tool paths;
  `nagare-operator-tools` passes its installed-package-only PATH and Pulumi-absent scenarios.
- [x] (2026-09-14 00:53Z) Milestone 3: updated `docs/user/installation.md`,
  `docs/user/getting-started.md`, and `CHANGELOG.md` `[Unreleased]`; all 462 Haskell tests, the
  Haskell style gate, and strict user-documentation validation pass.
- [x] (2026-09-14 00:59Z) Pre-release gate: `nix flake check --print-build-logs` passes all 24
  aarch64-darwin checks from committed implementation checkpoint `73a2f4a`.
- [x] (2026-09-14 01:02Z) Milestone 4 candidate preparation: version sources, installation pins,
  changelog, workflow default, compatibility fixture, and `docs/releases/v0.2.2.md` agree on
  0.2.2. The source-only release check, documentation validators, capability profile and graph,
  and `mori validate` pass.
- [x] (2026-09-14 01:31Z) Milestone 4 candidate validation: committed `248e5f9`; a clean
  `nix flake check --print-build-logs` passed all 27 aarch64-darwin checks and all 462 Haskell
  tests; the assembled release audit reported payload digest
  `sha256-+dxcPuhQw9zD5NIy6OBCg0A+Elx7lgjA29Zj3DQ4l0c=` at that exact revision; and the local
  clone-free release rehearsal passed.
- [x] (2026-09-14 01:55Z) Milestone 4 publication: after bounded operator approval, normal CI run
  `34796315741` passed both the root flake and private `nagare-access` compatibility job; manual
  Release run `34796355804` passed on x86_64-linux and aarch64-darwin and assembled byte-identical
  evidence; signed tag `v0.2.2` was verified locally and pushed; tag run `34797271649` published
  [Nagare 0.2.2](https://github.com/shinzui/nagare/releases/tag/v0.2.2). The seven published
  attachments pass their checksums and match the rehearsed bundle byte for byte, and the public
  Nix-by-tag command reports version 0.2.2 at `248e5f9`.
- [x] (2026-09-14 01:58Z) Milestone 5 repository bookkeeping: IR-13, IR-7, and IR-8 are completed
  with resolutions; ADR 9 records isolated, fail-closed named context creation; ADR 7 records the
  operator-only Pulumi packaging rule; and the IR bundle log records the completion.
- [x] (2026-09-15 13:31Z) Milestone 5 external handoff reconciled: the operator supplied the
  registered `mori://tan/tan-ng-labs` repository as the authoritative labs context for this audit.
  That repository pins v0.2.2, records the context-owned Pulumi stack, and its rollout successfully
  used the packaged Pulumi path to create the host and cluster. The previously undeliverable
  runtime-session message has therefore been consumed as repository-level operator state.


## Surprises & Discoveries

- Observation: IR-7 overstates one inheritance path. `runInit` already overwrites
  `pulumiBackend` and `pulumiBackendUrl` from the flags; an absent flag becomes `local` and `""`.
  So a new context does not inherit the active context's Pulumi backend URL. Instead,
  `init EXISTING --force` without `--pulumi-backend` silently resets a `gcs` context to `local`.
  The fields that really are inherited are `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID`,
  `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_INSTANCE_NAME`,
  `NAGARE_TARGET_PLATFORM`, `NAGARE_MODE`, and `NAGARE_LOCAL_OBJECT_STORE`, plus every prompt
  default.
  Evidence: `cli/nagarectl/app/Main.hs` lines 2997-3003 at `3a107d3`
  (`& #pulumiBackendUrl .~ maybe "" T.pack (o ^. #pulumiBackendUrl)`), and `ctxOr` in
  `cli/nagarectl/src/Nagare/Target.hs` lines 714-721, which falls back from the environment to
  the active context map.

- Observation: `scripts/enable-apis.sh` does not receive the new target through arguments. It
  sources `scripts/lib/target.sh`, which resolves the active context (`NAGARE_CONTEXT`, then the
  `current-context` pointer) and lets environment values override fields. It then refuses when the
  effective project differs from the context's declared project. Today `init` gets away with this
  because `profileFromOpts` `setEnv`s `CLOUDSDK_CORE_PROJECT` in its own process, and a real run
  has already made the new context current. A pure profile no longer touches the environment, so
  `init` must export the new context to its children explicitly. A dry run has no context file for
  the script to resolve at all.
  Evidence: `scripts/enable-apis.sh` lines 18-21, and `scripts/lib/target.sh` lines 131-167 and
  369-392.

- Observation: `docs/user/getting-started.md` line 36 already lists `pulumi` and `node` as
  operator clients. `docs/user/installation.md`, the page IR-8 followed, lists neither.

- Observation: the Milestone 1 Cabal command must run from `cli/nagarectl`; the repository has
  one `cabal.project` per Haskell package and no root `cabal.project`. From the package directory,
  `nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct` passed all 454 tests.
  Evidence: running the plan's root-relative command first exited with `No cabal.project file or
  cabal file matching the default glob './*.cabal' was found.`

- Observation: strict improvement-request validation still fails only on the bundle-wide absence
  of truthful review provenance. `--strict --profile-enforce` reported `missing
  profile-recommended field: reviews` for all 14 concepts. This is the same known behavior recorded
  by ExecPlan 110; no review entries were invented. The enforceable schema, profile, and log gate
  without `--strict` passed with `OK: 14 concepts (okf_version 0.2)`.

- Observation: the first extended clone-free run left the fixture's synthetic `foreign` context
  current, so the later pre-existing status assertion inspected the wrong context. Restoring the
  original `local` current-context pointer after the IR-7 scenario made the complete check pass;
  the product behavior was correct in the failing run.

- Observation: `nagare --list` used to call `nagarectl context env`, which installs locked Pulumi
  Node dependencies and therefore required npm merely to list recipes. The package-only PATH check
  exposed this hidden side effect. The launcher now resolves the immutable workspace and executes
  `just --list` before context/Pulumi initialization; operational recipes still take the guarded
  context path.

- Observation: the release-candidate `mori validate` gate succeeds but warns that `mori.dhall`'s
  recorded schema hash predates the semantic hash embedded in the current Mori binary. The
  configuration is valid and this release does not change Mori configuration, so the unrelated
  schema-upgrade rewrite remains outside this candidate.

- Observation: at the post-approval publication boundary, authoritative `origin/master` already
  resolved to candidate `248e5f9`, and GitHub recorded push-triggered CI run `34796315741` for that
  revision at 2026-09-14 01:33Z. No redundant push was made; the session proceeded from the observed
  remote state and did not infer who synchronized it.

- Observation: the requested `labs-tan` Claude session is not reachable through this runtime's
  collaboration tree. `list_agents` returned only `/root`; `labs-tan` is not a valid runtime agent
  name, and the canonicalized `/root/labs_tan` target was absent. The release and repository
  bookkeeping are complete, but the external notification remains an explicit handoff rather than
  a claimed success.

- Observation (resolved 2026-09-15): the handoff no longer depends on reaching the old ephemeral
  Claude session. The operator explicitly brought `mori://tan/tan-ng-labs` into this audit; its
  README, pinned flake, context, context-owned stack config, and completed rollout demonstrate that
  v0.2.2 and the packaged-Pulumi workflow were received and used.


## Decision Log

- Decision: one ExecPlan covers IR-13, IR-7, IR-8, and the 0.2.2 release.
  Rationale: IR-7 and IR-8 both change `runInit` and `Nagare.Init`, and their tests share the
  clone-free command scenario. All three must ship in the same tag for the `tan-ng-labs` rollout
  to proceed. Separate plans would add coordination without enabling independent review of
  anything that could ship alone.
  Date: 2026-09-14

- Decision: IR-9 and IR-14 stay out of scope and are not linked to this plan.
  Rationale: The user chose the scope of 0.2.2 directly. IR-8's tool preflight and the bundled
  `pulumi` remove the common trigger of IR-9, a guard run with no `pulumi` on PATH. IR-9's
  remaining cases (backend auth failure, locked state) are a separate diagnostics change. IR-14
  changes the default host-name derivation, which the IR-7 non-goals exclude.
  Date: 2026-09-14

- Decision: for `init NAME`, the profile is built only with the pure
  `Nagare.Target.profileFromContextMap`. Its input map is
  `mergeContextOverrides base flagPairs payloadVersion`, where `base` is `Nothing` for a new
  context and `NAME`'s stored map under `--force`. `init` never consults the active context, the
  process environment, or the global `--context` flag. Prompt defaults come from the same base.
  Rationale: `profileFromContextMap` already exists and never reads the environment.
  `mergeContextOverrides` already implements "flags override stored values, omitted fields keep
  stored values, a stored platform pin is kept" for `context create --force` (EP-121). Reusing both
  makes `init` and `context create` agree by construction, and it satisfies IR-7's acceptance:
  creating a context never copies a value from a different context.
  Date: 2026-09-14

- Decision: legacy `init` with no `NAME` (which writes `./nagare.target.env`) keeps its current
  behavior through `profileFromOpts`.
  Rationale: The legacy path is a MasterPlan 12 back-compat surface, and IR-7 names only
  `init NAME`. Changing it would alter what an in-repo profile inherits for existing checkouts,
  with no reported defect. `profileFromOpts` stays exported, and its Haddock comment will say it
  serves only the legacy path.
  Date: 2026-09-14

- Decision: under `--force`, an omitted `--pulumi-backend` or `--pulumi-backend-url` keeps the
  stored value. It is no longer reset to `local`.
  Rationale: This follows from using `mergeContextOverrides`. The reset silently moved a `gcs`
  context's state location, which is the same class of defect as IR-7. Release notes call out the
  behavior change.
  Date: 2026-09-14

- Decision: before any side effect, `init NAME` refuses when `NAGARE_IMAGE_BUCKET` or
  `NAGARE_BACKUP_BUCKET` does not start with `<project>-`. It applies the same rule to the bucket
  of the effective GCS Pulumi backend URL, unless the operator passed `--pulumi-backend-url` on
  this invocation. The explicit URL is printed but exempt.
  Rationale: IR-7 asks to refuse any derived name that embeds a different project id. Nagare
  cannot enumerate "other" project ids, but every name it derives has the form `<project>-nagare-…`.
  A name without that prefix therefore came from a stored or foreign value. The typical case is
  `init existing --force --project new`, where the stored buckets name the old project. An explicit
  backend URL is a deliberate operator choice. EP-113's bucket-ownership check in
  `Nagare.Ops.PulumiBackend` still verifies the owning project number when the bucket is
  bootstrapped. Operators with custom bucket names can still use `nagarectl context create`, the
  low-level writer.
  Date: 2026-09-14

- Decision: after resolving the profile, `runInit` exports the new context's variables into its
  own environment: `NAGARE_CONTEXT=NAME` plus every `CLOUDSDK_*` / `NAGARE_*` field. Child scripts
  therefore see exactly the new context. In `--dry-run`, `init` prints the API-enable command from
  Haskell (`requiredApis` and the project) and does not invoke `scripts/enable-apis.sh`, because
  no context file exists yet for the script to resolve.
  Rationale: See Surprises & Discoveries. Setting `NAGARE_CONTEXT` also overrides an ambient
  `NAGARE_CONTEXT` exported by `.envrc`. The printed text keeps the `DRY RUN: would run:` line
  that `nix/checks/scripts/nagare-clone-free-platform.sh` asserts.
  Date: 2026-09-14

- Decision: `pulumi` and `pulumi-language-nodejs` go only into the operator package `#nagare`.
  Inside that package, `nagarectl` gets a second wrapper with `--suffix PATH`, and the tools are
  appended to the launcher's PATH. Neither is prepended. The app-developer `#nagarectl` output
  does not change.
  Rationale (package scope): `docs/user/installation.md` positions `#nagarectl` as the smaller
  app-developer CLI, and app developers never run Pulumi. IR-8 names the operator package.
  Rationale: `nix/checks/platform.nix` puts a fake `pulumi` on PATH for the clone-free scenario, and
  prepending would shadow it with the real binary. Appending also lets an operator deliberately
  use another `pulumi`. `nagarectl version --tools` reports which binary was resolved, so that
  choice stays visible.
  Date: 2026-09-14

- Decision: resolved tool paths are reported by `nagarectl version --tools` (text or `--json`),
  not added to plain `version --json`.
  Rationale: Plain `version --json` output feeds the release gates and the clone-free rehearsal,
  whose attachments must be byte-identical on a rerun. Tool paths depend on the invoking
  machine's PATH (gcloud, npm), so they must not leak into that output. IR-8 only asks that the
  resolved Pulumi be reportable.
  Date: 2026-09-14

- Decision: the tool preflight runs in `--dry-run` too, and Node.js/npm stay a documented
  prerequisite rather than a bundled one.
  Rationale: A dry run that passes and a real run that fails on a missing tool is the IR-8
  experience. IR-8 lists bundling Node.js as a non-goal.
  Date: 2026-09-14

- Decision: in the IR bundle, IR-13, IR-7, and IR-8 become `accepted` with `targetPlan` set to this
  plan now. They become `completed` with a `resolution` only after `v0.2.2` is published.
  Rationale: This follows the bundle's existing lifecycle (for example IR-2: accepted with
  ExecPlan 113, completed when the work was verified). IR-13's code is merged but no release
  contains it, and the defect is only resolved for operators once a tag exists.
  Date: 2026-09-14

- Decision: treat the operator's registered labs repository and its successful v0.2.2 rollout as
  durable delivery of the external handoff.
  Rationale: the purpose of the notification was to let labs stop depending on the two workarounds,
  not to preserve a message to one ephemeral agent session. The receiving repository now records
  and operates the released workflow, which is stronger and longer-lived evidence of receipt.
  Date: 2026-09-15


## Outcomes & Retrospective

Nagare 0.2.2 is published from signed annotated tag `v0.2.2`, which peels to reviewed candidate
`248e5f95803c0110b5890b611c7bbd24468f8d71`. The release contains the expected seven attachments for
x86_64-linux and aarch64-darwin; their checksums pass, their manifest names the exact tag and
revision, and they are byte-identical to the manual native rehearsal. Running
`nix run github:shinzui/nagare/v0.2.2#nagarectl -- version --json` without a checkout reports
platform and CLI version 0.2.2 at that revision.

IR-13 is resolved by the `3a107d3` renderer fix, its HostSpec golden, the
`host-module-options-agree` contract check, and the published patch release. IR-7 and IR-8 are
resolved by implementation commit `73a2f4a`: named init is isolated from the active context and
refuses foreign derived buckets before side effects, while the operator package carries the locked
Pulumi toolchain and init preflights every required tool before mutation. The focused clone-free and
operator-tool checks, all 462 Haskell tests, full local flake gate, normal CI, and native release
workflow all passed.

No Nagare context, Pulumi stack, GCP project, cluster, VM, or application was selected or mutated by
the release process. The intentionally unclosed product work remains IR-9, IR-14, and adding
`nixos/flake.nix` evaluation to CI. The existing strict improvement-request review-provenance gap and
GitHub's `actions/checkout@v4` Node 20 deprecation annotation are also recorded rather than hidden.

The labs handoff is now delivered through `mori://tan/tan-ng-labs`, not an ephemeral agent message.
The repository pins Nagare v0.2.2, retains the `labs` context and context-owned Pulumi stack, and its
rollout used that release to build the image, apply Pulumi, bootstrap the host and cluster, and serve
trusted HTTPS. The release session itself still ran no `infra-up` and created no VM; those later
operations belong to the receiving repository's evidence.


## Context and Orientation

**Nagare and its commands.** Nagare is a platform that provisions one GCP VM running k3s
(lightweight Kubernetes) through Pulumi (an infrastructure-as-code tool whose TypeScript program
is `infra/pulumi/index.ts`), then operates apps on it. The operator CLI is `nagarectl`, a Haskell
executable. Its entry point is `cli/nagarectl/app/Main.hs` (about 4,500 lines, one big command
dispatcher), and its library modules live in `cli/nagarectl/src/Nagare/`. The tests are the
`nagarectl-test` suite under `cli/nagarectl/test/`: `Spec.hs` is the main file, and `HostSpec.hs`
and `PlatformSpec.hs` are imported by it. A second command, `nagare`, is a shell "launcher" that
runs the release's `just` recipes (`infra-up`, `host-image`, `cluster-bootstrap`, …, defined in
the root `justfile`) inside a writable copy of the platform files.

**Target contexts.** A context is a named file
`${XDG_CONFIG_HOME:-~/.config}/nagare/contexts/<name>.env` of `export VAR=value` lines. The file
selects the GCP project (`CLOUDSDK_CORE_PROJECT`), region, zone, bucket names
(`NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`), registry, base domain, VM shape, ACME contact,
Pulumi backend (`NAGARE_PULUMI_BACKEND` = `local` or `gcs`, and optional
`NAGARE_PULUMI_BACKEND_URL`), and the pinned platform version. The file
`${XDG_CONFIG_HOME}/nagare/current-context` names the current context. The *active* context is
chosen, in precedence order, by `--context`, then `NAGARE_CONTEXT`, then that pointer, then a legacy
in-repo `nagare.target.env`. The repository's `CLAUDE.md` explains why this matters: every
command must act only on the active context's project.

The relevant code is `cli/nagarectl/src/Nagare/Target.hs`:

- `parseContextEnv` and `readContextMap path` read a context file into a
  `Map String Text`, keyed by variable name. `readContextMap` returns `Nothing` if the file is
  absent.
- `profileFromContextMap :: Map String Text -> TargetProfile` is **pure**. It fills every field
  of the `TargetProfile` record from the map or a built-in default. It derives
  `imageBucket = <project>-nagare-images`, `backupBucket = <project>-nagare-backups`, and
  `registryHost = <region>-docker.pkg.dev` when the map lacks them.
- `resolveProfileFrom` does the same but reads the process environment first through `ctxOr`
  (environment > map > default). `resolveTargetProfile` applies it to the **active** context's map.
- `mergeContextOverrides :: Maybe (Map String Text) -> [(String, Text)] -> Text -> Map String Text`
  was added for `context create --force` in EP-121. Flag pairs override stored values, omitted
  fields keep stored values, and `NAGARE_PLATFORM_VERSION` is inserted only when absent.
- `defaultGcsPulumiBackendUrl ctx tp` is `gs://<project>-nagare-pulumi-state/nagare/<ctx>`.
  `pulumiEnvFor` picks it when the backend is `gcs` and no URL is set.
- `contextFilePath`, `contextExists`, `setCurrentContext`, `readCurrentContext`, and
  `writeContextProfile` manage the files.

**How `init` works today** (at `3a107d3`). `nagarectl init [NAME] [flags]` is the onboarding
command. Its option record `InitOpts` and pure helpers are in `cli/nagarectl/src/Nagare/Init.hs`.
Its flow is `runInit` in `cli/nagarectl/app/Main.hs`, starting near line 2949, and runs in this
order:

1. `defs <- activeProfile mctx` resolves the active context. Its values become prompt defaults.
2. `resolveField` takes each field from its flag, a TTY prompt, or the default. Only `--project`
   and `--acme-email` are required when stdin is not a TTY.
3. `runPreflight project` runs unless `--skip-preflight`. It checks gcloud auth and operator IAM.
4. `profileFromOpts` (Init.hs, around line 107) `setEnv`s the chosen values, unsets five derived
   variables, and calls `resolveTargetProfile`. That call reads the active context, which is the
   IR-7 bug. The backend kind and URL are then overwritten from the flags.
5. For a named context, `writeNamedContext` writes the file (refusing an existing one without
   `--force`) and `setCurrentContext` makes it current. With `--dry-run`, the rendered file is
   printed instead.
6. `enableApis` runs `scripts/enable-apis.sh` unless `--skip-enable`. On failure it prints
   ``Re-run `nagarectl init --skip-preflight` ``, which is wrong after a partial run because the
   context now exists.
7. Unless `--skip-seed`: `bootstrapGcsIfNeeded` creates the GCS state bucket for `gcs` backends,
   `ensurePulumiInWorkspace` links stack config, runs `npm ci` via
   `ensurePulumiProgramDependencies`, and selects or inits the Pulumi stack, and
   `seedPulumiConfig` runs `pulumi config set` for the twelve keys from `seedKeys`.
   `seedPulumiConfig` calls `run $ cmd "pulumi"` from the `cradle` process library. If `pulumi` is
   not on PATH, that throws an `IOException`, which is the crash IR-8 reports.
8. `nextStepsText` prints `just infra-up` and similar steps and cites `docs/masterplans/…`.
   Neither `just` nor those docs exist for an installed (clone-free) operator.

`nagarectl context use NAME` (the `ContextUse` case of `runContext` in Main.hs, near line 3082) sets
the pointer, runs `ensurePulumiForContext`, and seeds the stack. It does not enable APIs. It is
the correct resume after a failure in step 7. `nagarectl context create NAME --force …`
(`ContextCreate`, near line 3106) already builds its profile purely with
`mergeContextOverrides` and `profileFromContextMap`. `init NAME` will follow the same pattern.

**Payload roots.** `Nagare.Platform.Paths` defines
`data PlatformRootSource = ExplicitRoot | InstalledRoot | SourceRoot`. `resolvePlatformWorkspace`
in Main.hs returns `(PlatformPaths, PlatformWorkspace)`, and `paths ^. #rootSource` is
`InstalledRoot` when `nagarectl` runs from the Nix package (`NAGARE_PLATFORM_ROOT` set by the
wrapper) and `SourceRoot` in a checkout. `nextStepsText` will use this to choose `nagare` or `just`.

**Packaging.** `nix/haskell-packages.nix` builds `nagarectl` as a `symlinkJoin` whose `postBuild`
runs `wrapProgram "$out/bin/nagarectl" --prefix PATH : <typedConfigRuntime> --set
NAGARE_PLATFORM_ROOT <payload>`. `wrapProgram` comes from nixpkgs `makeWrapper`, and it supports
`--suffix PATH : dirs`, which appends instead of prepends. The launcher `nagareLauncher` is a
`pkgs.writeShellApplication` with `runtimeInputs = [ nagarectl pkgs.jq pkgs.just ]`. Those inputs
are *prepended* to PATH. Its script evals `nagarectl context env` and execs `just`, and `just`
recipes call `pulumi` directly. The operator package `nagare` is a `symlinkJoin` of the two. The
file exports `checkedNagarectl`, `haskellPackages`, `nagare`, `nagarectl`, and
`typedConfigRuntime`, so a check can use the unwrapped binary at
`haskellPackages.nagarectl`. `pkgs.pulumi` and `pkgs.pulumiPackages.pulumi-nodejs` (which provides
`bin/pulumi-language-nodejs`, the plugin Pulumi uses to run a TypeScript program) are today only in
`nix/dev-shells.nix`.

**Checks.** `nix flake check` runs every derivation under `nix/checks/*.nix`. The ones this plan
touches are:

- `nagarectl-build-test` (`nix/checks/haskell.nix`) builds and runs the Haskell test suite.
- `nagare-clone-free-platform` (`nix/checks/platform.nix`) runs
  `nix/checks/scripts/nagare-clone-free-platform.sh`. Its PATH holds the real `nagare` package
  plus recording fakes for `pulumi`, `npm`, `nix`, `gcloud`, `gsutil`, `kubectl`, and `curl`. Every
  fake appends its argv to `$NAGARE_FAKE_TOOL_LOG`. The script already runs
  `nagarectl init trial --project example --acme-email ops@example.com --dry-run --skip-preflight`
  and greps its output.
- `host-module-options-agree` (`nix/checks/infra.nix`) is IR-13's check.

**IR-13 state.** Commit `3a107d3` changed `renderHostModule` in
`cli/nagarectl/src/Nagare/Host/Config.hs` to emit `hostName = …;` again. It added the golden file
`cli/nagarectl/test/fixtures/host/host.nix`, pinned it with a `HostSpec` test, and added
`nix/checks/scripts/host-module-options-agree.sh`, which fails when the golden sets a
`nagare.host.*` option that `nixos/modules/nagare-host.nix` does not declare. That session verified
by hand that the golden evaluates through `nixos#lib.mkNagareSystem`. IR-13 asked for a check that
evaluates a rendered flake. The text-level check was chosen instead, because `nixos/flake.nix`
checks are not run by CI. Evaluating a full NixOS system inside a root flake check would add a
heavy build. The IR resolution must say this plainly. One gap remains open: `nixos/flake.nix`
checks are not in CI.

**Improvement request bundle.** `docs/improvement-requests/` is an OKF (a typed-Markdown knowledge
format) bundle governed by `docs/improvement-requests/profile.dhall`. Each IR has frontmatter with
`requestId`, `status` (`proposed`, `accepted`, `completed`, …), and optionally `targetPlan` (a
repo-relative plan path) and `resolution` (one paragraph). A body line reads `**Status:** …`, and
`timestamp` records the last meaningful revision. `docs/improvement-requests/log.md` is updated with
`okf log add`. Precedent: commit `2cc6f12` accepted IR-2 with ExecPlan 113, and commit `7e2a36b`
completed it.

**Releases.** A release is an immutable signed Git tag `vX.Y.Z` plus a GitHub Release with
attachments built by `.github/workflows/release.yml`. The maintainer runbook is
`docs/runbooks/releases.md`, and the repository skill is `.claude/skills/nagare-release`. The
version appears in `release.json` (`platformVersion`), the three Cabal files
(`cli/nagarectl/nagarectl.cabal`, `cli/nagare-dsl/nagare-dsl.cabal`,
`cli/nagare-access/nagare-access.cabal`), the compatibility fixture string in
`cli/nagarectl/test/PlatformSpec.hs` (the manifest JSON near line 263; the two
`mergeContextOverrides … "0.2.1"` literals near lines 54 and 62 are test data and may stay),
`CHANGELOG.md`, `docs/releases/vX.Y.Z.md`, `NAGARE_VERSION` in `README.md` and
`docs/user/installation.md`, and the `default:` input in `.github/workflows/release.yml`.
`scripts/test-release.sh` and the clone-free check derive the version automatically.

**Relevant ADRs.**

- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): every
  cloud-mutating path asserts the active context's project. IR-7 is a hole *before* that
  assertion: the context itself can be born with foreign names. This plan's ownership check extends
  the same fail-closed principle to context creation.
- [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md): an
  installed payload is immutable and runs from a per-context workspace. That is why clone-free next
  steps must name `nagare <recipe>` and not `just` or repository docs.
- [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md): releases are
  validated signed tags that are never moved. It governs Milestone 4.
- [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) and
  [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md): `init` must keep seeding the
  VM shape and requiring the ACME contact. This plan does not change either rule.
- [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
  covers the context-owned stack config that `ensurePulumiInWorkspace` links. It is unchanged here.

**Operating rules that apply.** Always stage explicit paths (`git add <path>`), never `git add -A`,
because other sessions leave untracked files (MasterPlan 21, ExecPlans 122-127). Commits use
Conventional Commits and carry the trailers `ExecPlan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md`
and `Intention: intention_01m2ekfg61edmbtnvv0tbkhprd`. Run `just haskell-style-check` before
committing Haskell. Pushing, dispatching CI, and pushing tags are outward-facing and need the
operator's go-ahead. Ask once for the bounded release sequence in Milestone 4. No step in this plan
touches a live cluster or cloud project.

External cross-repository reference: the `tan-ng-labs` rollout plan is
`mori://tan/tan-infrastructure` at `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`
(the artifact-level URI is pending).


## Plan of Work

### Milestone 1: confirm IR-13 and record the IR acceptance

IR-13's code is already on `master`. This milestone proves it on the current tree and records the
bookkeeping, so that later milestones start from a verified base. At the end, the three IRs are
`accepted` with `targetPlan` pointing at this plan, and there is a transcript showing that
`host init` renders `hostName`.

Run the Haskell test suite and the IR-13 check (commands in Concrete Steps). Then, in a scratch
XDG tree, create a throwaway local context and run `nagarectl host init --dry-run`. Confirm that
the printed `host.nix` contains `hostName =` and no `    name =` line. Record the transcript in
Surprises & Discoveries if anything differs.

The IR edits were made when this plan was created. Each of the three IR files gets
`status: accepted`, a new `targetPlan:` line after `status`, a refreshed `timestamp`, and its body
`**Status:**` line changed to `accepted; planned as [ExecPlan 128](../plans/128-….md).` IR-13's line
also notes that the fix is in `3a107d3` and ships in 0.2.2. The log gets one entry. Validate with
`okf validate` and commit with explicit paths.

Acceptance: `okf validate … --strict --profile-enforce --log-enforce` exits 0,
`nagarectl-build-test` and `host-module-options-agree` pass, and the dry run shows `hostName`.

### Milestone 2: `init NAME` never reads another context (IR-7)

At the end of this milestone, `nagarectl init NAME` builds its context only from its flags, the
built-in defaults, and, under `--force`, `NAME`'s own stored file. Before changing anything, it
prints the derived names and refuses a bucket that does not belong to `--project`.

In `cli/nagarectl/src/Nagare/Init.hs`, add these pure pieces (signatures in Interfaces and
Dependencies):

`initFlagPairs :: InitOpts -> [(String, Text)]` turns the flag values into context variable pairs,
the same way `contextEnvPairs` in Main.hs does for `context create`. It maps `--project` to
`CLOUDSDK_CORE_PROJECT`, `--region`, `--zone`, `--base-domain`, the four VM-shape flags,
`--pulumi-backend`, `--pulumi-backend-url`, `--acme-email`, and `--acme-directory`. The result
includes only flags that were given.
`runInit` will call it on an `InitOpts` whose `Maybe` fields have been filled by prompts, so it can
operate on the resolved values too.

`initContextMap :: Maybe (Map String Text) -> [(String, Text)] -> Text -> Map String Text` is
exactly `mergeContextOverrides`. Name it in `Nagare.Init` and document that `init` uses it. It
takes the base (`Nothing` for a new context), the pairs, and the payload version.

`checkInitOwnership :: Bool -> Text -> TargetProfile -> Either Text ()` takes a flag saying whether
`--pulumi-backend-url` was passed explicitly, plus the context name and the profile. It returns
`Left` naming every offending variable when `imageBucket` or `backupBucket` does not start with
`project <> "-"`. It does the same for the bucket of the effective GCS backend URL when the
backend is `gcs` (after `effectivePulumiBackend`) and the URL was not explicit. That URL is
`pulumiBackendUrl`, or `defaultGcsPulumiBackendUrl ctx tp` when empty; its bucket is the text
between `gs://` and the next `/`. The message must say that the stored or inherited value belongs
to a different project, and suggest a new context name or
`nagarectl context create NAME --force --image-bucket …`.

`renderInitSummary :: Text -> TargetProfile -> Text` renders an indented block headed
`Derived names for context '<name>':`. It lists the project, registry prefix (`registryPrefix`),
image bucket, backup bucket, instance name, Pulumi backend kind, and effective backend URL (from
`pulumiEnvFor`'s rule; implement it as a pure function over the profile and context name,
without the state root, using `defaultGcsPulumiBackendUrl` for `gcs` and the literal
`file://<state>/<ctx>/state` shape for `local`).

`resolveInitBase :: ContextName -> Bool -> IO (Either Text (Maybe (Map String Text)))` is the only
IO piece. It reads `NAME`'s stored map with `contextFilePath` and `readContextMap`. If the file
exists and `force` is false, it returns `Left "context 'NAME' already exists; pass --force to
re-initialize it (omitted flags keep its stored values)"`. If the file exists and `force` is true,
it returns `Right (Just stored)`. If the file is absent, it returns `Right Nothing`. It must never
call `readCurrentContext`, `lookupEnv`, or `resolve*`. Moving the "already exists" refusal here
means `init` refuses before prompting or preflighting instead of after.

Then rewire the named-context branch of `runInit` in `cli/nagarectl/app/Main.hs`. The legacy
no-`NAME` branch keeps today's code. Update `profileFromOpts`'s Haddock to say it serves the
legacy path only.

1. Parse `NAME` first and call `resolveInitBase`, dying on `Left`.
2. Compute `defs = profileFromContextMap (initContextMap base [] payloadVersion)` for prompt
   defaults. The payload version comes from `resolvePlatformWorkspace`, whose call moves earlier.
   Resolving a workspace creates only a local state directory, not a cloud side effect. The project
   and ACME contact are required whenever the base does not supply them. Change `resolveField`'s
   `required` argument to `required && T.null def` for these two fields, and pass an empty default
   for the project when `base` is `Nothing`. Otherwise a TTY prompt would offer the built-in
   `tan-nb-exp` fallback, which must never happen.
3. Resolve fields and validate the VM shape and ACME values exactly as today.
4. Build `tp = profileFromContextMap (initContextMap base (initFlagPairs resolvedOpts)
   payloadVersion)`. Validate `vmShapeOf tp`. For a new context,
   `mergeContextOverrides` stamps `NAGARE_PLATFORM_VERSION`. Under `--force`, the stored pin is
   kept, because re-initializing is not an upgrade.
5. Print `renderInitSummary`. Run `checkInitOwnership` and die on `Left`. Both happen before the
   gcloud preflight, so a refusal needs no credentials.
6. Run the gcloud preflight as today.
7. Export the new context to the process environment for child processes: `setEnv
   "NAGARE_CONTEXT" NAME`, then `setEnv` each `export` line of
   `renderContextShellEnv name tp (pulumiEnvFor stateRoot ctx tp)`. The simplest correct way is a
   small helper `exportProfileEnv :: ContextName -> TargetProfile -> IO ()` in Main.hs that sets
   the same variables `renderContextShellEnv` lists, except `PULUMI_*`, which
   `ensurePulumiInWorkspace` already sets. Unset a variable when its value is empty.
8. Write the context and set it current (or print it in dry-run), as today via
   `writeNamedContext`. Its refusal is now unreachable but harmless; keep it as a backstop.
9. Enable APIs. In `--dry-run`, print `DRY RUN: would run:` and
   `  gcloud services enable <requiredApis…> --project=<project>` from Haskell without invoking the
   script. In a real run, invoke `scripts/enable-apis.sh` as today. Its hint changes in Milestone 3.
10. Seed as today.

Tests. In `cli/nagarectl/test/Spec.hs` (`initTests`), add pure tests:
`initContextMap Nothing pairs v` then `profileFromContextMap` yields `p-nagare-images`,
`p-nagare-backups`, `us-west1-docker.pkg.dev`, `nagare-01`, `linux/amd64`, `cloud`, and backend
`local`. A stored map plus `[("NAGARE_ACME_DIRECTORY","staging")]` keeps the stored bucket and
`NAGARE_PULUMI_BACKEND=gcs`. `checkInitOwnership False "labs"` refuses a profile whose image bucket
is `tan-nb-exp-nagare-images` while the project is `tan-ng-labs`, names both bucket variables,
accepts the derived names, refuses a stored `gs://other-nagare-pulumi-state/…` backend, and
accepts it when the explicit flag is `True`. `renderInitSummary` contains both bucket names and
the default GCS URL. In `cli/nagarectl/test/PlatformSpec.hs`, which already has
`withTemporaryEnv`, add an IO test. Set `XDG_CONFIG_HOME` to a temp dir, write
`contexts/other.env` with `NAGARE_IMAGE_BUCKET=other-nagare-images`, write `current-context` as
`other`, and set `NAGARE_CONTEXT=other` and `NAGARE_IMAGE_BUCKET=env-nagare-images` in the
environment. Then `resolveInitBase new False` returns `Right Nothing`,
`resolveInitBase other False` returns `Left`, and `resolveInitBase other True` returns the stored
map.

Command scenario. In `nix/checks/scripts/nagare-clone-free-platform.sh`, after the existing `init
trial` block, create a foreign current context with
`nagarectl context create foreign --project other --image-bucket other-nagare-images
--backup-bucket other-nagare-backups --target-platform linux/arm64 --use` (check that
`context create` accepts these flags; `contextEnvPairs` shows it does). Then run
`nagarectl init fresh --project p --acme-email ops@example.com --dry-run --skip-preflight` and
grep for `NAGARE_IMAGE_BUCKET=p-nagare-images`, `NAGARE_BACKUP_BUCKET=p-nagare-backups`, and
`NAGARE_TARGET_PLATFORM=linux/amd64`. Assert that `other-nagare` does not appear. Next, run
`nagarectl context create kept --project p --pulumi-backend gcs` (without `--use`), then
`nagarectl init kept --force --acme-email ops@example.com --dry-run --skip-preflight --skip-seed`.
Its output must keep `NAGARE_PULUMI_BACKEND=gcs` and `NAGARE_IMAGE_BUCKET=p-nagare-images`.
Finally, `nagarectl init kept --force --project q --acme-email ops@example.com --dry-run
--skip-preflight` must exit non-zero, with stderr naming `NAGARE_IMAGE_BUCKET`. The `context create
foreign --use` step may try to seed Pulumi through the fakes. If that makes the scenario noisy,
write the `foreign.env` file and the `current-context` pointer directly instead.

Acceptance: the new unit tests fail on `3a107d3` (the functions do not exist, or, for an IO test
written against the old path, the foreign bucket appears) and pass after. The command scenario
passes in `nix build .#checks.aarch64-darwin.nagare-clone-free-platform`.

### Milestone 3: ship Pulumi and make `init` fail before it changes anything (IR-8)

At the end of this milestone, the installed `nagare` and `nagarectl` find a Pulumi from the
release's own nixpkgs. `init` refuses up front when a needed tool is missing. Every post-write
failure names a working recovery. Next steps match how Nagare was installed.

Packaging, in `nix/haskell-packages.nix`: define
`operatorTools = [ pkgs.pulumi pkgs.pulumiPackages.pulumi-nodejs ]`. Leave the existing `nagarectl`
derivation (the app-developer `#nagarectl` output) unchanged. Add a new `operatorNagarectl`, a
`pkgs.symlinkJoin` over `nagarectl` with `nativeBuildInputs = [ pkgs.makeWrapper ]` and a
`postBuild` that wraps the already-wrapped binary again:
`wrapProgram "$out/bin/nagarectl" --suffix PATH : ${lib.makeBinPath operatorTools}`.
`symlinkJoin` links `bin/nagarectl`, and `wrapProgram` replaces the link with a script that
execs the original, so the inner `--prefix typedConfigRuntime` and `NAGARE_PLATFORM_ROOT` still
apply. If `wrapProgram` refuses to wrap a symlink, first run
`rm "$out/bin/nagarectl"` and then
`makeWrapper ${nagarectl}/bin/nagarectl "$out/bin/nagarectl" --suffix PATH : …`. Use
`operatorNagarectl` in `nagareLauncher`'s `runtimeInputs` and in the `nagare` `symlinkJoin` paths,
replacing `nagarectl`. In `nagareLauncher`'s `text`, add
`export PATH="$PATH:${lib.makeBinPath operatorTools}"` as the first line, so `just` recipes that call
`pulumi` directly find it. Do not add these tools to `runtimeInputs`, which prepends. Comment both
places: the suffix is deliberate, because the clone-free check's fake `pulumi` must win.

Tool preflight, in `cli/nagarectl/src/Nagare/Init.hs`:
`requiredInitTools :: InitOpts -> PulumiBackendKind -> [String]` is pure. It needs `gcloud` unless
all of `--skip-preflight`, `--skip-enable`, and (`--skip-seed` or a non-`gcs` backend) hold,
because the preflight, the enable script, and the GCS bootstrap all call gcloud. It needs `pulumi`
and `npm` unless `--skip-seed`. `findMissingTools :: [String] -> IO [String]` uses
`System.Directory.findExecutable`. In `runInit`, both branches call them immediately after the
backend kind is known (for a named context, right after step 1 using the base's or the flag's
backend kind) and before prompts. A non-empty result dies with a message like the one below. It
exits 1 and touches no file.

```text
nagarectl init: required tools are not on PATH: pulumi, npm
  pulumi ships with the nagare package (nix profile install github:shinzui/nagare/vX.Y.Z#nagare);
  npm comes from Node.js, which must be installed separately.
  Nothing was changed.
```

Make `seedPulumiConfig` total. Wrap the `run $ cmd "pulumi" …` call in `try`, and map an
`IOException` to `Left (k, ExitFailure 127)`. In Main.hs, every caller that formats the failure
(`runInit`, and `ContextUse` and `ContextCreate` in `runContext`) says
`pulumi could not be started` when the code is 127.

Recovery hints, in `runInit`:
- The enable-apis failure for a named context says ``enable-apis failed; see the gcloud output
  above. The context '<NAME>' is written and current. After fixing the cause, re-run `nagarectl
  init <NAME> --force --skip-preflight` (it keeps the context's stored values).`` Milestone 2 makes
  `--force` safe.
- The seed failure for a named context says ``pulumi config set failed at key <k>; the context
  '<NAME>' is written and current. Fix the cause and run `nagarectl context use <NAME>` to finish
  seeding.``
- A GCS bootstrap failure (`bootstrapGcsIfNeeded`, called from `runInit`) appends the same
  `nagarectl context use <NAME>` sentence when the context has been written.
- The legacy no-`NAME` branch keeps its texts.

Next steps: change `nextStepsText :: Text` to
`nextStepsText :: PlatformRootSource -> Text`. For `InstalledRoot` and `ExplicitRoot`, it prints
`nagare infra-up`, `nagare host-image`, `nagare infra-up`, `nagare cluster-bootstrap`, and a pointer
to the installed guide (`docs/user/getting-started.md` in the release's documentation). It drops the
`docs/masterplans` sentence. For `SourceRoot`, it keeps the `just …` lines. `runInit` passes
`paths ^. #rootSource`. Update `Spec.hs`'s `nextStepsText` test (currently near line 652) to assert
both renderings, and assert that the installed rendering contains no `just ` and no `masterplans`.

Tool report: add a `--tools` switch to `nagarectl version` (extend `VersionOpts` in Main.hs). With
`--json --tools`, the object gains
`"tools":{"pulumi":<path or null>,"pulumi-language-nodejs":<path or null>,"gcloud":…,"npm":…}`.
Without `--json`, it prints one `tool: path` line per tool, or `tool: not found`. Resolve the paths
with `findExecutable` in `main`'s `Version` case. Pass them to a new
`renderBuildVersionJsonWithTools :: BuildVersion -> [(Text, Maybe FilePath)] -> ByteString` in
`cli/nagarectl/src/Nagare/Version.hs`. Leave plain `version --json` and `renderBuildVersionJson`
unchanged (see the Decision Log). `scripts/check-release.sh` (line 227) and
`scripts/rehearse-clone-free-release.sh` (lines 88-92) read it by field.

Checks: add `nagare-operator-tools` to `nix/checks/platform.nix` as a `pkgs.runCommand` with
no `nativeBuildInputs`, and put its script in `nix/checks/scripts/nagare-operator-tools.sh`. It
runs these scenarios:

1. It sets `PATH=${nagarePackages.nagare}/bin` only and
   `HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME` under `$PWD`. It runs
   `nagarectl version --json --tools` and uses `${pkgs.jq}/bin/jq` by absolute path to assert
   that `.tools.pulumi` starts with `/nix/store/` and that `.tools["pulumi-language-nodejs"]` is
   non-null. It then runs that `pulumi version` and asserts exit 0. Pulumi may try to write under
   `$HOME/.pulumi`, which the temp `HOME` covers. Also run `nagare --list` to prove that the
   launcher's PATH resolves.
2. It uses a fake-tools directory holding recording `gcloud` and `npm` scripts (reuse the
   `fakeJsonTool` and `fakeNpm` pattern) and the **unwrapped**
   `${nagarePackages.haskellPackages.nagarectl}/bin/nagarectl`, with `NAGARE_PLATFORM_ROOT` set to
   `${nagarePackages.nagarePlatform}/share/nagare`. PATH is the fake-tools directory plus
   coreutils, with no pulumi. It runs `nagarectl init nopulumi --project p --acme-email
   ops@example.com` (not a dry run) and asserts a non-zero exit, stderr containing
   `required tools are not on PATH: pulumi`, an empty tool log (gcloud was never called), and no
   `$XDG_CONFIG_HOME/nagare/contexts/nopulumi.env`.

`nagare-clone-free-platform` keeps passing unchanged, because its fakes precede the suffixed real
`pulumi`. If it starts logging real Pulumi output, the suffix is wrong.

Docs: `docs/user/installation.md` states that the `nagare` package includes Pulumi and its
Node.js language plugin, from the release's pinned nixpkgs. It says that Node.js with npm and the
Google Cloud SDK are prerequisites that must be installed separately, and that
`nagarectl version --tools` shows which binaries will be used. `docs/user/getting-started.md` line 36
moves `pulumi` out of the prerequisite list with a note. `CHANGELOG.md` `[Unreleased]` gets bullets
for IR-13, IR-7, and IR-8, including the `--force` backend behavior change.

Acceptance: `nix build .#checks.aarch64-darwin.nagare-operator-tools` passes. The same check with
the `--suffix` line removed fails scenario 1. Scenario 2 fails on `3a107d3`, where the crash comes
after the gcloud calls. `nagarectl-build-test` and `nagare-clone-free-platform` pass.

### Milestone 4: release Nagare 0.2.2

Follow `docs/runbooks/releases.md` and `.claude/skills/nagare-release` end to end. Lessons from
0.2.0 and 0.2.1 apply and are spelled out in Concrete Steps. At the end, `v0.2.2` is a signed tag
on the reviewed commit, the GitHub Release has all attachments, and `nix run
github:shinzui/nagare/v0.2.2#nagarectl -- version --json` reports 0.2.2.

Set `0.2.2` in `release.json`, the three Cabal files, the manifest fixture string in
`cli/nagarectl/test/PlatformSpec.hs`, `README.md`, `docs/user/installation.md` (`NAGARE_VERSION`
and "The examples use version"), and the `release.yml` dispatch default. Cut `CHANGELOG.md`
`[Unreleased]` into `[0.2.2] - <date>`. Write `docs/releases/v0.2.2.md`, modeled on
`docs/releases/v0.2.1.md`, covering: host init renders `hostName` (IR-13; 0.2.0 and 0.2.1 cannot
create host flakes); `init NAME` isolation, the ownership refusal, and the `--force` backend
change (IR-7); bundled Pulumi, the tool preflight, recovery hints, next steps, and `version`
tools (IR-8); known gaps (IR-9, IR-14, and the absence of `nixos/flake.nix` checks in CI); and the
upgrade note that workstation packages change and contexts do not. Commit as
`chore(release): prepare 0.2.2`.

Run the gates in order on the clean committed tree. Do not edit tracked files while they run. Then
ask the operator once for the bounded publish sequence: push `master`, dispatch Release, sign and
push the tag. Proceed after approval.

Acceptance: every gate passes. The published release lists the seven attachments, the checksums
verify, and the `nix run` command prints `"version":"0.2.2"` with the tag's revision.

### Milestone 5: close the IRs and notify labs

Set IR-13, IR-7, and IR-8 to `status: completed` with a one-paragraph `resolution` naming commits,
checks, and the tag, and update their body status lines. Add a log entry, validate, and commit.
Fill in Outcomes & Retrospective. Distill durable context into ADRs: amend
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) with
"context creation never reads another context and refuses foreign derived bucket names". Record the
decision "the operator package carries the Pulumi it was tested with, appended to PATH" as a new
ADR allocated by the ADR workflow, or as an amendment to
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md). Then send the `labs-tan`
Claude session the tag commit and state that IR-7 and IR-8 are in. With IR-7 in, `labs-tan` can
drop its no-active-context workaround for `init`. With IR-8 in, it can drop its `nix shell` Pulumi.
`labs-tan` currently has context `labs` (tan-ng-labs), with no `infra-up` and no VM.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless stated.

Milestone 1:

```bash
(cd cli/nagarectl && nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct)
nix build .#checks.aarch64-darwin.host-module-options-agree --print-build-logs
scratch="$(mktemp -d)"
env -i HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" \
  PATH="$PATH" nix run .#nagarectl -- context create ir13 --project ir13-test \
  --mode local --base-domain localhost --registry-host localhost:5000 --use
env -i HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" \
  PATH="$PATH" nix run .#nagarectl -- --context ir13 host init --dry-run \
  --ssh-public-key-file ~/.ssh/id_ed25519.pub --host-name ir13-host | grep -n 'hostName\|^    name ='
```

Expected: tests report `All N tests passed`, the check builds, and the grep prints one
`hostName = "ir13-host";` line and no `name =` line. If `host init` requires other flags such as
`--sops-file`, add them as its `--help` shows. The dry run writes nothing.

```bash
okf validate docs/improvement-requests --strict \
  --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git add docs/improvement-requests/host-init-renders-an-unknown-host-option.md \
  docs/improvement-requests/init-must-not-inherit-the-active-context.md \
  docs/improvement-requests/ship-pulumi-with-the-operator-package.md \
  docs/improvement-requests/log.md \
  docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
git commit
```

Commit message:

```text
docs(improvement-requests): accept IR-13, IR-7 and IR-8 and link ExecPlan 128

Move the host-init, init-isolation and operator-Pulumi requests to accepted and
target them at the 0.2.2 ExecPlan. IR-13's fix is already in 3a107d3.

ExecPlan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
Intention: intention_01m2ekfg61edmbtnvv0tbkhprd
```

Milestones 2 and 3 use this development loop:

```bash
(cd cli/nagarectl && nix develop ../.. -c cabal build exe:nagarectl)
(cd cli/nagarectl && nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct)
just haskell-style-check
nix build .#checks.aarch64-darwin.nagare-clone-free-platform --print-build-logs
nix build .#checks.aarch64-darwin.nagare-operator-tools --print-build-logs
```

After each milestone, commit with explicit paths, for example
`fix(init): build named contexts from flags and their own stored values only` for Milestone 2 and
`feat(nagare): ship Pulumi with the operator package and preflight init's tools` for Milestone 3.
Use both trailers. Run `nix flake check --print-build-logs` once before moving to Milestone 4.

Milestone 4, in order. Check the clean tree with
`git status --porcelain --untracked-files=no`, which must print nothing.

```bash
./scripts/check-release.sh --version 0.2.2 --source-only
nix flake check --print-build-logs
./scripts/check-release.sh --version 0.2.2 --json
./scripts/rehearse-clone-free-release.sh --version 0.2.2
```

After operator approval:

```bash
git push origin master
gh workflow run release.yml --ref master -f version=0.2.2
gh run list --workflow release.yml --limit 3
```

Only a run created *after* the push builds the pushed commit. Cancel any run whose `headSha` is
older (`gh run view <id> --json headSha`). When the dispatch succeeds, download and assemble:

```bash
gh run download <run-id> --dir native-artifacts
./scripts/assemble-release.sh --version 0.2.2 --input-root native-artifacts --output-dir dist
(cd dist && shasum -a 256 -c SHA256SUMS)
```

Keep `native-artifacts` and `dist` outside the repository (for example under the scratchpad), or
delete them before tagging so that the tree stays clean. Sign and verify:

```bash
git -c gpg.format=ssh -c user.signingkey="$HOME/.ssh/id_ed25519.pub" \
  tag -s v0.2.2 -m 'Nagare v0.2.2'
git cat-file -t v0.2.2          # expect: tag
git rev-parse v0.2.2^{commit}   # expect: the reviewed commit
git -c gpg.ssh.allowedSignersFile=/path/outside/repo/allowed_signers tag -v v0.2.2
git push origin v0.2.2
gh run watch "$(gh run list --workflow release.yml --event push --limit 1 --json databaseId -q '.[0].databaseId')"
gh release view v0.2.2 --json assets -q '.assets[].name'
nix run github:shinzui/nagare/v0.2.2#nagarectl -- version --json
```

The allowed-signers file maps `nadeem@gmail.com` to the existing public key. Never create or
register keys during a release, and never push an unsigned tag. `CACHIX_AUTH_TOKEN` is configured,
so CI pushes to the `shinzui` cache and the tag run should be faster than 0.2.1's.

Milestone 5 uses `okf log add docs/improvement-requests -m "…"` and the validation command
above. To message `labs-tan`, use the SendMessage tool with `to: "labs-tan"`.


## Validation and Acceptance

The plan is accepted when all of the following are observed.

IR-7. With a current context `foreign` whose file sets `NAGARE_IMAGE_BUCKET=other-nagare-images`,
`nagarectl init fresh --project p --acme-email ops@example.com --dry-run --skip-preflight` prints
`export NAGARE_IMAGE_BUCKET=p-nagare-images`, `export NAGARE_BACKUP_BUCKET=p-nagare-backups`, and
`export NAGARE_TARGET_PLATFORM=linux/amd64`, preceded by the `Derived names for context 'fresh':`
block. `other-nagare` appears nowhere. `nagarectl init kept --force …` keeps `kept`'s stored
`NAGARE_PULUMI_BACKEND=gcs`. `nagarectl init kept --force --project q …` exits 1 before the preflight,
naming `NAGARE_IMAGE_BUCKET` and `NAGARE_BACKUP_BUCKET`. The `nagare-clone-free-platform` check
covers all three. The unit tests in `Spec.hs` and `PlatformSpec.hs` pass.

IR-8. `nix build .#checks.aarch64-darwin.nagare-operator-tools` passes. With PATH containing only
the installed package, `nagarectl version --json --tools` reports a Nix-store `pulumi`, and `pulumi version`
runs. With `pulumi` absent, `init` exits non-zero with `required tools are not on PATH: pulumi`,
calls no gcloud, and writes no context. The installed-root next steps say `nagare infra-up`. The
unit test for `nextStepsText` passes for both roots.

IR-13. `HostSpec` and `host-module-options-agree` pass, and `host init --dry-run` renders
`hostName`.

Release. `nix flake check` passes locally and in CI on both systems. The GitHub release `v0.2.2`
carries `nagare-release-0.2.2.json`, `nagare-v0.2.2.md`, `nix-output-x86_64-linux.json`,
`nix-output-aarch64-darwin.json`, `clone-free-x86_64-linux.json`, `clone-free-aarch64-darwin.json`,
and `SHA256SUMS`. `nix run github:shinzui/nagare/v0.2.2#nagarectl -- version --json` prints
`"version":"0.2.2"`.


## Idempotence and Recovery

Milestones 1-3 are local code and document changes, and every command in them can be re-run. The
Milestone 1 dry run uses a throwaway `mktemp -d` home and never touches the operator's real
contexts. Delete the directory afterwards. The new `init` behavior is itself safer to retry: an
`init NAME --force` now reproduces the stored context rather than mixing in another one.

Release gates are read-only and can be repeated. If a gate fails, fix the source in a new commit and
restart the gates from the first. If a dispatch run built the wrong commit, cancel it and dispatch
again. Never move, delete, or reuse a tag once pushed (ADR 7). If the tag workflow fails for
infrastructure reasons with unchanged source, rerun it. If the source is wrong after the tag is
pushed, publish 0.2.3 instead. If any guard or script refuses during the release, stop and report
to the operator rather than working around it, as this repository's `CLAUDE.md` requires.

IR bundle edits are plain Markdown. If `okf validate` fails, fix the frontmatter and re-run it.
Nothing is committed until validation passes.


## Interfaces and Dependencies

No new Haskell dependencies. `containers` (`Data.Map.Strict`), `directory`
(`findExecutable`, `doesFileExist`), and `cradle` are already dependencies of `nagarectl`. Nix
adds `pkgs.pulumi` and `pkgs.pulumiPackages.pulumi-nodejs` from the root flake's locked nixpkgs,
the same attributes `nix/dev-shells.nix` already uses.

At the end of Milestone 2, `cli/nagarectl/src/Nagare/Init.hs` exports, in addition to its current
list:

```haskell
initFlagPairs :: InitOpts -> [(String, Text)]
initContextMap :: Maybe (Map String Text) -> [(String, Text)] -> Text -> Map String Text
resolveInitBase :: ContextName -> Bool -> IO (Either Text (Maybe (Map String Text)))
checkInitOwnership :: Bool -> Text -> TargetProfile -> Either Text ()
renderInitSummary :: Text -> TargetProfile -> Text
```

At the end of Milestone 3, it also exports the following, and `nextStepsText` changes type:

```haskell
requiredInitTools :: InitOpts -> PulumiBackendKind -> [String]
findMissingTools :: [String] -> IO [String]
nextStepsText :: PlatformRootSource -> Text
seedPulumiConfig :: FilePath -> Bool -> Text -> TargetProfile -> IO (Either (Text, ExitCode) ())
  -- unchanged type; a missing binary is now Left (key, ExitFailure 127), never an exception
```

`cli/nagarectl/src/Nagare/Version.hs` gains
`renderBuildVersionJsonWithTools :: BuildVersion -> [(Text, Maybe FilePath)] -> ByteString`, and
`renderBuildVersionJson` stays byte-compatible. `nix/haskell-packages.nix` adds
`operatorNagarectl` to its export set, and `nagare` and `nagarectl` keep their names. The `#nagarectl`
flake output is byte-for-byte the same derivation as before. `nix/checks/platform.nix` gains the `nagare-operator-tools` check.

Follow ADR 16's Haskell conventions in new code: the package Prelude, postpositive `qualified`,
strict record fields, explicit deriving strategies, and generic-lens labels (`tp ^. #imageBucket`).
Prefer standard library functions (for example `Data.Bifunctor.first`) over local helpers.


Revision note (2026-09-14): Implementation began by validating the already-committed Milestone 1
IR acceptance and IR-13 fix. The Progress and Surprises sections now record the correct per-package
Cabal working directory and the pre-existing strict OKF review-provenance deviation so the plan can
be resumed from observed results rather than the original command assumptions.

Revision note (2026-09-14 00:53Z): Milestones 2 and 3 are implemented and their focused acceptance
checks pass. Progress now records the 462-test suite, clone-free init isolation, operator-tool
packaging, documentation validation, and the launcher-listing discovery before the release
milestone begins.

Revision note (2026-09-14 01:02Z): The 0.2.2 candidate sources and operator notes are prepared after
the committed implementation passed the full local flake gate. Progress and Surprises now record
the exact candidate validators and the non-blocking Mori schema-hash warning before the clean
candidate rehearsal.

Revision note (2026-09-14 01:58Z): The clean candidate, normal CI, native rehearsal, signed tag,
tag-triggered publication, public attachments, and Nix-by-tag execution are verified. The three IRs
are completed and ADRs 9 and 7 amended. The requested `labs-tan` notification could not be routed by
the available collaboration runtime, so the precise handoff remains open and is recorded above.

Revision note (2026-09-15): Closed the external handoff after the operator supplied
`mori://tan/tan-ng-labs` as the authoritative receiving context and its repository/rollout evidence
showed v0.2.2 and the packaged-Pulumi workflow in active use. No release or cloud state changed.
