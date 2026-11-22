---
type: Improvement Request
title: Ship a render-only nagarectl for credential-free build images
description: Publish a flake output that runs only site render and site package, with no documentation, test frameworks, Helm, Pulumi or platform payload in its closure, so Kotei's credential-free build image shrinks from 6.7 GB.
timestamp: "2026-11-20T18:36:00Z"
generated:
  by: process:claude-code
  at: "2026-11-20T18:36:00Z"
requestId: IR-48
status: accepted
targetPlan: docs/plans/271-package-a-render-only-nagarectl-for-credential-free-build-images.md
origin: mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer
originPlan: mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer
acceptanceCriteria:
  - id: AC-1
    statement: A stable flake output, packages.x86_64-linux.nagarectl-render, runs nagarectl site render and nagarectl site package, and its closure has no -doc output, test framework, Helm, Pulumi, Node.js, gcloud or platform payload.
    verification: The nagarectl-render-closure flake check enumerates the closure and refuses any forbidden name.
  - id: AC-2
    statement: The x86_64-linux closure is at most 2.5 GiB, with a hard ceiling of 3.0 GiB.
    verification: nix path-info -S on the output, recorded in the target plan; the closure check enforces the bound.
  - id: AC-3
    statement: site render and site package produce byte-identical output under nagarectl-render and under packages.nagarectl of the same revision.
    verification: The nagarectl-render-equivalence flake check compares rendered.json, the layered archive and the content digest on the shipped static-site examples, with a fixed tag and a pinned base archive, offline.
  - id: AC-4
    statement: The output exposes its compiler, config runtime and CLI as separate attributes, so a consumer image can cache the GHC layer across Nagare releases.
    verification: The attributes are documented in docs/user, and Kotei's build image consumes them.
  - id: AC-5
    statement: The render runtime's docs-free, profiling-free GHC comes from mori://shinzui/haskell-nix-dev and its shinzui.cachix.org cache, not from a GHC build owned by Nagare, and its version equals the GHC that builds nagare-dsl in the main package set.
    verification: Nagare reads the compiler from its haskell-nix-dev input, an evaluation-time assertion compares the versions, and nix path-info --store https://shinzui.cachix.org finds the compiler for x86_64-linux.
---

# Ship a render-only nagarectl for credential-free build images

Requested by `mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`
under `mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.

## Consumer evidence

Kotei builds a repository's site in a credential-free Kubernetes build Job, because ADR 35 lets
repository config programs run only there. The Job image, `kotei-forge-nagare-bun-build`, is
defined in `mori://shinzui/kotei` by `flake.module.nix` and `nix/kotei-forge-build-image.nix`
(project-relative paths; artifact-level URI pending). It puts `packages.<system>.nagarectl` on
`PATH` and runs only `site render` and `site package --archive --builder layered`. The image is
one 6.7 GB layer, and the Job's seed step copies that whole store into a writable one when each
Job starts.

## Nagare evidence (2026-11-20, v0.24.2)

- On aarch64-darwin, `packages.nagarectl` is 6.73 GiB in 569 paths. The largest are
  `ghc-9.12.4` (2.0 GiB), `ghc-9.12.4-doc` (807 MiB), the nagarectl Haskell output (449 MiB,
  with its library and `nagared`), Helm, and the platform payload (115 MiB). On Darwin, test
  frameworks enter through each library's `lib/links` (aeson to tasty-golden, vector to doctest).
- On x86_64-linux, the GHC closure alone is 3.73 GiB (`ghc` 2.58 GiB, `ghc-doc` 0.79 GiB).
  GHC's own `package.conf.d` references its documentation, so removing it needs a GHC built with
  `enableDocs = false`.
- `site render` and `site package` need the typed config runtime and skopeo, for the layered
  builder's base fetch, and nothing else. Their pins are compiled in, and neither reads the
  platform payload.

## Compiler source (operator, 2026-11-20)

The docs-free GHC is published and cached by `mori://shinzui/haskell-nix-dev`, the operator's
toolchain flake. Nagare already follows that flake's nixpkgs, so its main GHC is already
haskell-nix-dev's `ghc9124`. Adding the runtime compiler variant to haskell-nix-dev is separate
work in that repository, and the target plan depends on it.

## Out of scope

Rendering without any GHC is IR-49.
