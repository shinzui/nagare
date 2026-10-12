---
id: 105
slug: package-nagarectl-and-its-typed-config-runtime-with-nix
title: "Package nagarectl and its typed config runtime with Nix"
kind: exec-plan
created_at: 2026-08-25T14:04:15Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Package nagarectl and its typed config runtime with Nix

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [105-package-nagarectl-and-its-typed-config-runtime-with-nix.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/105-package-nagarectl-and-its-typed-config-runtime-with-nix.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, a user with Nix can run `nagarectl` directly from the Nagare flake instead of
entering a development shell or compiling the repository by hand. More importantly, that installed
command can load an application-owned `nagare/Config.hs` from a directory that is not inside Nagare:
the wrapper supplies a `runghc` whose package database contains `nagare-dsl`. Running
`nix run .#nagarectl -- version` prints the installed program identity, and an isolated dry-run fixture
proves the typed configuration path works with no `.ghc.environment.*` and no Nagare source ancestor.

This plan establishes only the executable and typed-config runtime. Platform-owned Pulumi, NixOS,
manifest, and script assets remain a source-checkout concern until
`docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md` implements the
payload contract. Commands that do not need those assets—context management and app dry runs—must work
at this plan's completion.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-25T16:19:55Z) M1: Proved a Nix-built `ghcWithPackages` runtime in which `runghc` imports `Nagare.Dsl.*` with `GHC_ENVIRONMENT=-`; the hermetic DSL check passed all 384 tests, including loader fixtures and repository examples.
- [x] (2026-08-25T16:32:07Z) M2: Replaced the DSL and CLI checks with hermetic GHC 9.12 derivations for the locked Cradle revision, `nagare-dsl`, and `nagarectl`; the native flake check passed 384 DSL and 376 CLI tests without Cabal network access.
- [x] (2026-08-25T16:32:07Z) M3: Exposed the `nagarectl` package and named/default apps with the typed-runtime wrapper and stable text/JSON `version` command.
- [x] (2026-08-25T16:32:07Z) M4: Added valid and invalid external-config smoke tests, compiled every shipped example through the installed runtime, documented Nix installation, and passed the complete native hermetic flake check.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The root flake's current `nagarectl-build-test` is a `runCommand` with `__noChroot = true`; it runs
  `cabal update` and fetches a Git source dependency. It is a CI check, not a reusable package
  derivation. Packaging must not merely rename that check. Date: 2026-08-25.
- `cli/nagarectl/cabal.project` pins `cradle` at commit
  `711c441fa8f190a8964c56a3bae864cd5321c5c5`. Mori locates the source and documentation at
  the [canonical Cradle package](mori://garnix-io/cradle/packages/cradle); its Cabal package has only ordinary Hackage dependencies.
  A Nix derivation can therefore build the pinned source separately and override it into the package
  set. Date: 2026-08-25.
- A plain `doCheck` around the Cabal-derived DSL package inherited Cabal's in-place
  `GHC_ENVIRONMENT`, whose `-package nagare-dsl` entry was not visible to the subprocess
  `runghc`; setting `GHC_ENVIRONMENT=-` and putting a `ghcWithPackages` runtime containing the
  installed DSL first on `PATH` made all 384 tests pass. Cross-repository example paths also had
  to be projected into the isolated Nix check because `callCabal2nix` correctly packages only
  `cli/nagare-dsl`. Evidence: `nix build
  .#checks.aarch64-darwin.nagare-dsl-build-test --print-build-logs`. Date: 2026-08-25.
- Upstream publishes no Cradle release tags, so there is no newer authoritative release version to
  select. The existing Cabal pin resolves to upstream commit
  `711c441fa8f190a8964c56a3bae864cd5321c5c5`; the flake locks that immutable revision directly and
  the Mori corpus contains the same commit for API inspection. Date: 2026-08-25.
- `nagare-access` retains unrelated private `source-repository-package` dependencies and cannot be
  part of a sandboxed default check without a separate packaging migration. Its inherited networked
  check now lives under `hydraJobs` and a dedicated relaxed-sandbox CI job; the default `checks`
  output is hermetic and needs no private token. Date: 2026-08-25.

## Decision Log

Record every decision made while working on the plan.

- Decision: prove the `runghc` packaging shape in a milestone before choosing between
  `ghcWithPackages`, an explicit package-environment file, or a small loader wrapper.
  Rationale: the installed command must not depend on the repository's Cabal-generated environment,
  and Nix GHC wrappers differ in how they expose package databases to subprocesses. A concrete
  isolated import test is the reliable contract.
  Date: 2026-08-25.
- Decision: retain explicit `--ghc-env` and `NAGARE_GHC_ENVIRONMENT` overrides and checkout discovery.
  Rationale: they remain useful for contributor builds and debugging; the installed runtime adds a
  higher-quality default rather than deleting supported escape hatches.
  Date: 2026-08-25.
- Decision: do not publish to Hackage in this plan.
  Rationale: the first distribution channel is the versioned Nix flake, and `nagarectl` and
  `nagare-dsl` currently move together. Hackage publication would introduce an independent versioning
  and compatibility surface without helping the requested install experience.
  Date: 2026-08-25.
- Decision: use `ghcWithPackages` containing `nagare-dsl` as the installed typed-config runtime,
  and keep the package derivation separate from its check-enabled variant.
  Rationale: the resulting `runghc` wrapper works without a Cabal environment or source ancestor,
  while the separate check derivation can provide repository-wide fixtures without putting those
  fixtures into the installed library closure.
  Date: 2026-08-25.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

EP-105 is complete. The root flake now builds one locked GHC 9.12 package graph for Cradle,
`nagare-dsl`, and `nagarectl`, exports the CLI as a Nix package and application on both declared
systems, and wraps it with the typed-config compiler runtime. `nagarectl version` reports `0.1.0` in
text or stable JSON.

On `aarch64-darwin`, `nix flake check --print-build-logs` passed all 384 DSL tests, all 376 CLI tests,
every shipped typed-config example, shellcheck, and the isolated valid/invalid config check. The valid
fixture rendered a Knative Service with both package-environment variables unset; the invalid fixture
failed at compilation before Docker, kubectl, or Knative execution. The flake declares the same
outputs for `x86_64-linux`, where the hermetic Ubuntu CI job exercises them. Cross-system evaluation
from this Darwin host could not finish because its configured Linux SSH builder was unreachable, so
no local Linux build result is claimed.

The durable boundary—ship the GHC/DSL runtime as part of the CLI distribution while retaining
explicit contributor overrides—is recorded in
[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md). Platform-owned operational assets remain
checkout-relative by design and are the next child plan's scope.

