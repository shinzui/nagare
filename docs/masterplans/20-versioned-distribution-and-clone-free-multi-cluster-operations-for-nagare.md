---
id: 20
slug: versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare
title: "Versioned distribution and clone-free multi-cluster operations for Nagare"
kind: master-plan
created_at: 2026-08-25T14:04:09Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
---

# Versioned distribution and clone-free multi-cluster operations for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Nagare is currently distributed as a source checkout. The operator guide says that cloud and local
targets are operated entirely from the repository, the root flake exposes checks and development
shells rather than installable applications, and several `nagarectl` paths name `scripts/`,
`infra/pulumi`, or `cluster/bootstrap` relative to the current directory. The typed
`nagare/Config.hs` loader also discovers the `nagare-dsl` package environment through the checked-out
Cabal project. This is workable for one author-operated cluster, but it makes a Git worktree serve at
once as program installation, immutable platform source, mutable target state, and operator
configuration.

After this initiative, an operator can install or run a tagged Nagare release with Nix, use
`nagarectl` from an application directory with no Nagare checkout, and provision or operate multiple
contexts without modifying tracked project files. The root flake exposes a wrapped `nagarectl`
application whose typed-config runtime can import `nagare-dsl`, plus a versioned platform payload
containing the Pulumi program, cluster manifests, scripts, NixOS modules, and operator recipes.
Resource-dependent commands resolve that payload explicitly and materialize any required writable
workspace below Nagare's per-context XDG state tree rather than assuming `$PWD` is the repository.

Each context records the platform release it is intended to run. A cluster carries a matching
version marker, and `nagarectl platform status` and `nagarectl platform upgrade` detect or prevent
unsafe CLI, payload, context, and cluster skew. Per-operator NixOS inputs—including SSH public keys,
registry settings, host identity, and sops paths—live in a generated context-owned host flake that
imports Nagare's exported NixOS module. No personal key or target-specific generated Nix file remains
part of the distributable source. Tagged releases publish the Nix entry points, immutable release
metadata, checksums, release notes, and clone-free onboarding instructions.

In scope are the Nix package/application outputs and hermetic Haskell dependency build; the bundled
typed-config runtime; an explicit platform-payload and resource-root contract; migration of
repository-relative CLI and script call sites; generated per-context host configuration; a semantic
platform version and compatibility contract; safe staged upgrades; tag-driven GitHub releases; and
operator, contributor, upgrade, multi-cluster, and capability documentation.

Explicitly out of scope are Homebrew and other native package managers, portable non-Nix binary
archives, a containerized CLI, Helm as the primary Nagare distribution, a hosted control plane,
cross-cluster scheduling or failover, and automatic migration of application data between clusters.
The source checkout remains the contributor workflow and a supported compatibility path during the
migration, but it ceases to be the required end-user installation method. The initiative does not
remove external credentials or tools that necessarily belong to the operator, such as GCP
authentication, Docker access, kubeconfig, age private keys, or Tailscale enrollment secrets.


## Decomposition Strategy

The work is split by independently observable user behavior rather than by file type. EP-105 makes
the developer-facing executable installable and proves typed configs work outside the checkout.
EP-106 packages the repository-owned platform resources and removes current-directory assumptions.
Once that foundation exists, EP-107 and EP-108 can proceed in parallel: EP-107 moves operator-owned
host inputs out of distributable source, while EP-108 gives every installed payload, context, and
cluster a compatible release identity and provides staged upgrades. EP-109 publishes the integrated
result and rewrites onboarding around released artifacts. Five plans remain within the recommended
two-to-seven range and keep each outcome demonstrable on its own.

At plan creation the repository had no `docs/adr/` directory, `mori show --full` reported no ADR OKF
bundle, and `mori registry concepts --search 'Nix package CLI release distribution' --json` returned
no relevant cross-repository ADR. The repository has since adopted numbered Markdown ADRs; EP-105's
runtime boundary is recorded in
`docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md`. The checked-in MasterPlan most relevant to this work is
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`: it established the user-level context
store, per-context XDG state, context-aware Pulumi state, and the remaining checkout-local generated
host files. This initiative preserves that context selection and extends its flat environment schema;
it does not replace it. During implementation, the immutable-payload/mutable-context boundary, the
version compatibility policy, and the exported NixOS-module boundary are durable decisions that must
be distilled into `docs/adr/` when they become real architecture.

The first plan deliberately owns the Haskell/Nix packaging mechanism. The current Cabal project has a
pinned `source-repository-package` for `cradle`; Mori identifies its source as the
[canonical Cradle package](mori://garnix-io/cradle/packages/cradle). EP-105 must build that exact dependency hermetically rather
than retaining the development checks' network-enabled `cabal update`. Later plans consume the
resulting package outputs rather than inventing another Haskell build.

Alternatives considered and rejected follow. Publishing only a bare `nagarectl` binary was rejected
because typed configs need GHC plus `nagare-dsl`, while provisioning commands need repository-owned
Pulumi, NixOS, manifest, and script assets. Treating a release tarball as a renamed Git checkout was
rejected because it would preserve mutable tracked configuration and `$PWD` coupling. Putting all work
in one ExecPlan was rejected because Haskell packaging, resource location, NixOS module design,
version negotiation, and release automation have different failure modes and validation surfaces.
Splitting one plan per asset family was rejected because every asset must obey one resource-root and
workspace contract. Shipping Helm as the distribution was rejected because Helm covers only the
cluster layer, not GCP provisioning or the NixOS host. Homebrew and portable archives are deferred
until the Nix-first path proves that the program is actually checkout-independent.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 105 | Package nagarectl and its typed config runtime with Nix | docs/plans/105-package-nagarectl-and-its-typed-config-runtime-with-nix.md | None | None | Complete |
| 106 | Make Nagare platform assets resolvable outside a source checkout | docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md | EP-105 | None | Complete |
| 107 | Externalize per-operator NixOS and host configuration | docs/plans/107-externalize-per-operator-nixos-and-host-configuration.md | EP-106 | None | Not Started |
| 108 | Add per-context platform versions and safe upgrades | docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md | EP-106 | EP-107 | Not Started |
| 109 | Publish versioned releases and clone-free onboarding | docs/plans/109-publish-versioned-releases-and-clone-free-onboarding.md | EP-107, EP-108 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-105 has no child-plan dependency. It establishes the root flake's supported systems, hermetic
Haskell package set, wrapped typed-config runtime, and `packages`/`apps` names that every later release
surface uses.

EP-106 hard-depends on EP-105 because the platform payload and operator launcher extend the same root
flake outputs and wrappers. It defines the payload manifest, resource-root precedence, per-context
writable workspace, and checkout compatibility fallback. Those are required before host configuration
or upgrades can identify which immutable release they consume.

After EP-106, EP-107 and EP-108 can proceed in parallel. EP-107 hard-depends on EP-106 because the
generated host flake must import the packaged NixOS module and live beside the context-owned workspace
rather than a checkout. EP-108 hard-depends on EP-106 because it compares and switches concrete
payload manifests and stamps the bootstrap resources shipped by that payload. EP-108 only
soft-depends on EP-107: upgrade work can use a fixture host flake before the generator lands, but its
final integration test must prove that upgrading preserves operator-owned host configuration.

EP-109 hard-depends on EP-107 and EP-108, which transitively require EP-105 and EP-106. A release
cannot truthfully promise clone-free onboarding until the installable CLI, payload resolution,
external host configuration, and version/upgrade checks all work together. EP-109 owns the release
workflow and end-to-end documentation rather than changing their underlying contracts.

The implementation waves are therefore: Wave 1, EP-105; Wave 2, EP-106; Wave 3, EP-107 and EP-108 in
parallel; Wave 4, EP-109.


## Integration Points

**1. Root flake output names and supported systems (defined by EP-105; consumed by EP-106 and
EP-109).** `flake.nix` exposes `packages.<system>.nagarectl`, `apps.<system>.nagarectl`, and
`apps.<system>.default`. EP-106 adds `packages.<system>.nagare-platform` and
`apps.<system>.nagare` without renaming EP-105's outputs. The initial supported systems remain the
existing `x86_64-linux` and `aarch64-darwin`; another system is added only when CI can build and test
the complete closure. EP-109's install commands and release matrix use these names verbatim.

**2. Typed-config runtime (defined by EP-105; consumed by all deploy-class commands and EP-109).** The
installed wrapper must put a `runghc` capable of importing `Nagare.Dsl.*` on `PATH`, without a
`.ghc.environment.*` from `cli/nagarectl`. `Nagare.GhcEnv` retains explicit `--ghc-env` and
`NAGARE_GHC_ENVIRONMENT` overrides and the checkout fallback for contributors, but the installed
package environment is the default for the Nix app. The exact implementation must be proved with an
isolated `nagare/Config.hs` test before it is fixed in an ADR.

**3. Payload manifest and platform path resolver (defined by EP-106; consumed by EP-107, EP-108, and
EP-109).** A packaged payload contains a machine-readable `release.json` and the repository-owned
`infra/pulumi`, `cluster`, `nixos`, `scripts`, `justfile`, and required documentation under one root.
`Nagare.Platform.Paths` is the only Haskell producer of absolute paths to these assets. Resolution
precedence is an explicit test override, an installed wrapper's payload root, then a validated source
checkout fallback. Later plans never concatenate `infra/pulumi` or `scripts/...` against `$PWD`.

**4. Immutable payload versus mutable per-context workspace (defined by EP-106; consumed by EP-107
and EP-108).** Nix-store payloads are read-only. When Pulumi, npm, Nix, or generated projections need
write access, Nagare materializes a versioned workspace below
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/<payload-id>/` by staging and atomic
rename. A manifest records the source payload digest. Re-running preparation is idempotent; a different
digest never overwrites an existing workspace. Context configuration remains under XDG config and
credentials remain outside both payload and workspace.

**5. Exported NixOS module and generated host flake (defined by EP-107; consumed by EP-108 and
EP-109).** The nested `nixos/flake.nix` exports a reusable Nagare host module with explicit options for
operator SSH keys, host/instance identity, registry host, sops file, and age key path. A generated
per-context host flake below the Nagare config tree pins the Nagare release and supplies those options.
Host image and day-2 scripts accept this flake path rather than mutating
`nixos/hosts/nagare-01/registry-host.nix`. EP-108 changes only the pinned release reference; it must
preserve the operator module verbatim.

**6. Platform version and compatibility contract (defined by EP-108; consumed by EP-109).** One
semantic version and release revision appear in `nagarectl version --json`, the payload
`release.json`, `NAGARE_PLATFORM_VERSION` in a named context, the generated host flake input, and a
`nagare-platform-version` ConfigMap in namespace `nagare-system`. A missing value denotes a legacy
source-managed context and produces a warning, not an invented release. Major-version incompatibility
blocks mutating platform operations; read-only inspection remains available. EP-109 verifies and
publishes this exact contract.

**7. Release ownership (defined by EP-109).** Git tags matching `v<major>.<minor>.<patch>` are the
release identity. Cabal package versions, the Nix/payload version, release metadata, and the tag must
agree. The GitHub workflow validates and publishes an already-created tag; it does not decide a
version or mutate operator clusters. This distinction and Integration Points 3–6 are durable project
decisions that should become ADRs during implementation.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] (2026-08-25T16:32:07Z) EP-105: Hermetic Nix derivations build `nagare-dsl`, pinned `cradle`, and `nagarectl` without network-enabled Cabal checks.
- [x] (2026-08-25T16:32:07Z) EP-105: `nix run .#nagarectl` loads and dry-runs an external typed config with no Nagare checkout or Cabal package environment.
- [x] EP-106: A `nagare-platform` payload and single path resolver replace repository-relative CLI resource paths while preserving source development.
- [x] EP-106: A fresh temporary directory can run checkout-independent init/status dry runs against an isolated context workspace.
- [ ] EP-107: Nagare exports a reusable NixOS host module and generates one context-owned host flake without a personal key in tracked source.
- [ ] EP-107: Host image and day-2 build paths consume the generated host flake and preserve separate configuration for two contexts.
- [ ] EP-108: CLI, payload, context, generated host flake, and cluster expose one tested platform-version compatibility contract.
- [ ] EP-108: `nagarectl platform upgrade` stages, previews, applies, records, and safely retries a per-context version transition.
- [ ] EP-109: A tag-driven workflow validates release consistency and publishes release metadata, checksums, and notes for supported Nix systems.
- [ ] EP-109: README, onboarding, upgrades, multi-cluster guidance, and capability evidence demonstrate installation and operation without cloning.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The current onboarding page says `nagarectl` comes from the root flake, but `flake.nix` exposes only
  `checks` and `devShells`; there is no `packages` or `apps` output. EP-105 corrects both the
  implementation and the documentation rather than preserving that accidental claim. Date:
  2026-08-25.
- `Nagare.GhcEnv.resolveProjectGhcEnv` intentionally walks upward to locate
  `cli/nagarectl/cabal.project`, proving that an installed executable alone cannot load typed configs.
  EP-105 must validate the packaged `runghc` closure before any release is advertised. Date:
  2026-08-25.
- MasterPlan 17 eliminated target selection by checkout but still documents checkout-local generated
  NixOS files and forbids concurrent host-image builds from one checkout. That residual coupling is
  split between EP-106's per-context workspace and EP-107's generated host flake. Date: 2026-08-25.
- The tracked `nixos/hosts/nagare-01/users.nix` contains one operator's public key. Distribution is not
  safe or credible until EP-107 removes this source-owned identity and requires explicit generated
  configuration. Date: 2026-08-25.
- EP-105 proved that a `ghcWithPackages` runtime containing `nagare-dsl`, placed on the installed
  wrapper's `PATH` with Cabal's inherited environment disabled during checks, is sufficient for
  checkout-independent typed configs. Later plans must compose this wrapper instead of introducing a
  second Haskell build. Date: 2026-08-25.
- The unrelated `nagare-access` check still has private network-resolved Cabal dependencies. EP-105
  moved it to a dedicated `hydraJobs`/CI compatibility path so the default flake check is hermetic;
  packaging that service remains separate from the developer CLI distribution. Date: 2026-08-25.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: make Nix the first supported distribution channel and defer Homebrew, portable archives,
  containers, and Helm-as-distribution.
  Rationale: Nix is already required for host construction and can provide the CLI, GHC package
  environment, and external tools as one reproducible closure. Additional channels should consume a
  proven checkout-independent architecture rather than define it.
  Date: 2026-08-25.
- Decision: distribute two related artifacts, an executable closure and a platform payload, rather
  than calling a standalone CLI the whole product.
  Rationale: day-2 app commands mostly need the executable and typed DSL, while provisioning and host
  operations also need Pulumi, manifests, scripts, and NixOS modules. Naming both artifacts makes that
  boundary explicit without forcing developers to clone all source.
  Date: 2026-08-25.
- Decision: keep immutable released assets separate from mutable context workspaces and operator
  configuration.
  Rationale: Nix store paths are read-only, Pulumi and generated host inputs require writes, and
  multiple contexts must not race through one checkout. XDG context roots already provide the correct
  isolation boundary.
  Date: 2026-08-25.
- Decision: split release identity/safe upgrade behavior (EP-108) from release publication and docs
  (EP-109).
  Rationale: version comparison and upgrade state transitions can be fully unit/integration tested
  without creating a GitHub release, while publication is not truthful until the former behavior is
  complete.
  Date: 2026-08-25.
- Decision: preserve source-checkout operation as a contributor fallback throughout the migration.
  Rationale: incremental compatibility keeps existing development and live operations usable while
  each checkout assumption is removed and gives every milestone a safe rollback path.
  Date: 2026-08-25.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

Wave 1 (EP-105) is complete. Nagare now has a hermetic, installable `nagarectl` application with its
typed-config runtime, a stable version command, checkout-independent loader tests, and Nix-first
installation documentation. The immutable executable/runtime boundary is captured in
`docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md`. EP-106 is now unblocked and can
extend the same flake outputs with the platform payload and resource resolver.

Wave 2 (EP-106) is complete. The flake now packages the operational asset tree, the CLI resolves one
validated payload root, and write-capable tools use atomic content-addressed workspaces below each
context's XDG state. Empty-directory checks cover init, status, and operator-recipe dry runs while
source-checkout operation remains supported. The boundary is captured in
`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md`; EP-107 and EP-108 are
now unblocked.
