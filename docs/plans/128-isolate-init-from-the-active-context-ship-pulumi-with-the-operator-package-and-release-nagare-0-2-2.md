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

Full plan before trimming: [128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

