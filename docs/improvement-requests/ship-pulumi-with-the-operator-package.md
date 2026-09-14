---
type: Improvement Request
title: Ship Pulumi with the operator package and make init fail before it changes anything
description: The clone-free nagare package has no pulumi binary and no documented prerequisite, so init crashes after enabling APIs and creating the state bucket, and its recovery hints point the wrong way.
timestamp: "2026-09-14T01:56:48Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-8
status: completed
completedAt: "2026-09-14T01:56:48Z"
resolution: "Commit 73a2f4a added Pulumi and pulumi-language-nodejs from the locked nixpkgs to the operator-only nagare package with an appended PATH, added a pre-side-effect gcloud/pulumi/npm tool check, totalized missing-Pulumi failures, corrected partial-run recovery and installed-root next steps, and added version --tools. The 462-test suite, nagare-operator-tools, nagare-clone-free-platform, full local flake check, normal CI, and native release rehearsals passed. The behavior is published in the signed v0.2.2 tag at commit 248e5f9."
targetPlan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-14T01:56:48Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against ExecPlan 128's signed-release evidence and the
      current operator package, tool preflight, version reporting, clone-free tests,
      recovery guidance, and ADR surfaces; the completed status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: ship Pulumi with the operator package, and preflight `init`'s tools

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by [ExecPlan 128](../plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md) and published in signed tag `v0.2.2` at `248e5f9`.
**Created:** 2026-09-13.


## Why

Following `docs/user/installation.md` exactly (`nix profile install
"github:shinzui/nagare/v0.2.1#nagare"`) on a workstation with Node.js but no Pulumi, `nagarectl init
labs … --pulumi-backend gcs` enabled six APIs, created `gs://tan-ng-labs-nagare-pulumi-state`, ran
`npm ci` in the payload workspace, wrote the context, set it current, and then died:

```text
Seeding Pulumi stack config from the profile...
nagarectl: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.IOException:
pulumi: Cradle.run: posix_spawnp: does not exist (No such file or directory)
```

The command that is documented as the single onboarding step left cloud state half-built and
crashed with an uncaught exception instead of a diagnosis.


## What is missing

- **Pulumi is not in the operator package.** At `v0.2.1`, `nagare` is a `symlinkJoin` of `nagarectl`
  and the launcher (`nix/haskell-packages.nix:94-96`). `pkgs.pulumi` and
  `pkgs.pulumiPackages.pulumi-nodejs` appear only in the developer shell (`nix/dev-shells.nix:22-24`).
  `docs/user/installation.md` lists no Pulumi prerequisite. The `nagarectl` wrapper already
  prefixes `PATH` with its runtime tools (`wrapProgram … --prefix PATH : ${lib.makeBinPath [
  typedConfigRuntime ]}`, `nix/haskell-packages.nix:66-69`), so there is an obvious place to add them. Operators who previously worked from a
  checkout's dev shell never noticed.
- **No tool preflight.** `init`'s preflight checks gcloud auth and IAM only; the missing binary is
  discovered after the side effects.
- **Wrong recovery hints.** The handled failure text for the seed step says
  `re-run nagarectl init --skip-preflight --skip-enable` (`cli/nagarectl/app/Main.hs:3046`), and the
  enable-apis failure says `Re-run nagarectl init --skip-preflight` (`Main.hs:3036`). After a
  partial run the context already exists, so `init` refuses without `--force`, and `--force`
  re-exposes IR-7. The actual resume is `nagarectl context use NAME`, which re-runs exactly the
  remaining steps (`Main.hs:3082-3099`); it worked here.
- **Stale next steps.** `nextStepsText` (`cli/nagarectl/src/Nagare/Init.hs:200-212`) tells a clone-free
  operator to run `just infra-up`, `just host-image`, `just cluster-bootstrap`, and points at
  `docs/masterplans/…`, which do not exist outside a checkout; the launcher is `nagare <recipe>`.

The workaround used was Pulumi from the release's own locked nixpkgs (`nixos/nixpkgs`
`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`, Pulumi and `pulumi-nodejs` `3.255.0`) via `nix shell … -c`.
That is not something an operator should have to derive from `flake.lock`.


## Requested change

- Put `pulumi` and `pulumi-language-nodejs` from the release's pinned nixpkgs on the `PATH` of
  `nagarectl` and the launcher (wrapper or `runtimeInputs`), so the version matches what the release
  was tested with. If that is rejected, list Pulumi (with the exact version) in
  `docs/user/installation.md` and have `nagarectl version --json` report the Pulumi it will use.
- Preflight every external binary `init` needs (`gcloud`, `pulumi`, `npm`) before the first side
  effect, and report missing ones as a normal error.
- Make every partial-failure hint in `init` name `nagarectl context use NAME` once the context file
  has been written.
- Render `nagare <recipe>` next steps for a clone-free install.


## Required verification

- The clone-free platform check runs `init --dry-run` and a guard in a sandbox whose `PATH` holds only
  the installed package, and finds `pulumi`.
- A test that `init` with `pulumi` absent exits non-zero before enabling APIs or creating a bucket.


## Acceptance

Installing `#nagare` and running `nagarectl init` is sufficient to reach a seeded stack, or `init`
refuses up front and changes nothing.


## Non-goals

Bundling Node.js, or supporting a non-Nix install.
