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
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:53:19Z
      mode: "update"
      note: "Close the audited improvement-request review provenance follow-up"
---

# Confine every cloud-mutating path to the active context's project

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
      linked to this plan in commit `2cc6f12`, before implementation began. Closing it was
      missed at the time; on 2026-09-13 IR-2 was set to `status: completed` with its
      `resolution`, `completedAt` and an ADR 9 link, matching how IR-3 was closed.
- [x] (2026-09-14) Follow-up, outside EP-113: audited all 23 improvement requests against project
      scope, linked plans, lifecycle state, and implementation evidence; recorded truthful
      content-and-metadata review provenance and OKF verification; strict profile validation passes.

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

All six milestones are implemented and committed (`63b9642`, `17da481`, `aba8549`,
`560a8b3`, `732be3b`, `e6a4863`, `3304094`, `43151d4`). All four paths named in IR-2 are
closed, and each closure is held by an automated test that fails before the change.

**What an operator can now do that they could not before.** With a production project
selected in `gcloud config`, or exported as `CLOUDSDK_CORE_PROJECT`, every Nagare command
that would write outside the active context's project stops and names both compared values.
`scripts/upload-images.sh` and the Pulumi state-bucket bootstrap refuse a bucket whose
owning project number is not the target's — including when that number cannot be read at
all. `cluster/bootstrap/auth-images/build-local-image.sh` no longer has any way to learn a
project from `gcloud config`. `just infra-up` and `just infra-preview` refuse before Pulumi
is invoked. And `nagare <recipe>` from a directory with no `.envrc` carries the active
context's Pulumi backend and stack, so the preflight has correct inputs outside a checkout.

**Evidence.** `nix flake check` passes all sixteen checks, including the two added here
(`bucket-ownership-guard`, `image-build-guard`), the extended `shellcheck-scripts` — which
now lints the two `cluster/bootstrap` build scripts it previously skipped — and the extended
`nagare-clone-free-platform`, which drives `nagarectl context guard` through a fake
`pulumi config get gcp:project` and expects acceptance then refusal. The `nagarectl` suite
grew from 400 to 411 cases with no new failures; the eight pre-existing `AppDeploySpec`
failures are the local Cabal-store problem recorded in Surprises & Discoveries.
`bash scripts/rehearse-clone-free-release.sh --version 0.1.0` completes and lists
`context-env` among its `checks`. `just docs-validate` passes.

**Three deviations from the plan as written, each recorded above.** The `nagarectl context
env` subcommand takes no `--export` flag (Progress named one that the milestone body and
Interfaces section never define, and the command has no other output mode to select
against). The `image-build-guard` test runs the real `build-local-image.sh` against a
minimal four-file platform root rather than the repository, because the script stages its
build context by rsyncing the whole tree — gigabytes here, and unaffordable inside a Nix
check. And `scripts/rehearse-clone-free-release.sh` strips the `CLOUDSDK_*` / `NAGARE_*`
contract for its `nagarectl context env` invocation, because a developer runs the rehearsal
from a `direnv`-loaded checkout whose profile wins the documented per-field precedence
(environment over context) and would make the assertion describe the developer's machine
rather than the context under test (`e6a4863`).

**Two things were not done, both deliberately.** `just local-smoke` was not run: it needs a
live k3d cluster and the Docker daemon is not running on this machine. The property it would
regress — local mode never requiring a GCP project or invoking `gcloud` — is instead held by
three automated assertions: case four of `scripts/test-bucket-ownership-guard.sh` (empty
`gcloud` log in local mode), case three of `scripts/test-image-build-guard.sh` (a local-mode
no-push build never invokes `gcloud`), and the `nagare-clone-free-platform` check, which
exercises the new launcher `eval` against a `mode=local` context end to end. Running
`just local-smoke` once with a cluster available would close the last of it. Separately, the
`docs/improvement-requests` strict validation named in Milestone 6's acceptance exited 1 at
implementation time, identically before and after this plan, for all four September-2026
requests. The 2026-09-14 corpus audit later performed those reviews rather than inventing them;
the 23-concept strict validation now passes and the follow-up in Progress is closed.

**Lessons.** Two are worth carrying forward and are recorded in
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md).
First, an entry-point check is not a confinement guarantee: the two bucket bugs were both
cases where the project the script believed in was correct and the *object* was not ours, so
the assertion has to sit at the mutation, not at the door. Second, the tests that actually
prove confinement assert on the recorded argv of a fake tool, not on the returned value — a
guard that returns an error after issuing the mutation would pass a return-value test and
fail the argv test, and the argv test is the one that matches the promise.

