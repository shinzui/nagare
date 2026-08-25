---
id: 106
slug: make-nagare-platform-assets-resolvable-outside-a-source-checkout
title: "Make Nagare platform assets resolvable outside a source checkout"
kind: exec-plan
created_at: 2026-08-25T14:04:15Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Make Nagare platform assets resolvable outside a source checkout

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, the Nagare flake distributes a `nagare-platform` payload containing the Pulumi
program, cluster manifests, scripts, NixOS source, operator recipes, and the small set of documentation
needed by runtime diagnostics. `nagarectl` locates those resources through one tested path resolver
instead of assuming it was launched from the repository root. Read-only resources can run directly
from the installed payload; resources that tools must modify are materialized atomically into a
versioned workspace under the selected context's XDG state directory.

A user can create an isolated `prod` context and run `nagarectl init --dry-run`, platform status, and
Pulumi preview preparation from an arbitrary empty directory. The same commands still work in a
source checkout for contributors. The later host-configuration and version plans build on this
immutable-payload/mutable-workspace boundary.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Inventory every repository-relative runtime path and define the payload manifest, path resolver, and workspace layout.
- [ ] M2: Package `nagare-platform` and implement idempotent per-context workspace materialization.
- [ ] M3: Migrate Haskell, shell, Pulumi, bootstrap, and operator-recipe call sites to resolved absolute paths.
- [ ] M4: Prove clone-free dry-run operations from an empty directory while preserving source-checkout compatibility.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `nagarectl init` invokes `scripts/enable-apis.sh` and seeds `infra/pulumi`; status, cleanup, doctor,
  CDN, and Pulumi helpers contain additional relative paths. Packaging only the obvious bootstrap
  manifests would leave important admin commands checkout-dependent. Date: 2026-08-25.
- The current Pulumi config projection and NixOS registry override are written into repository-owned
  directories. Because Nix payloads are read-only and contexts may operate concurrently, installed
  operation needs a writable per-context copy rather than direct mutation of `$out/share/nagare`.
  Date: 2026-08-25.


## Decision Log

Record every decision made while working on the plan.

- Decision: define one payload root containing the repository-owned operational tree instead of a
  separate locator for each asset family.
  Rationale: scripts and recipes refer to one another; one validated root preserves those internal
  relationships and prevents divergent resolution rules.
  Date: 2026-08-25.
- Decision: make installed payloads immutable and materialize only commands requiring writes into a
  per-context, payload-identified state workspace.
  Rationale: this matches Nix store semantics, isolates multiple clusters, and makes rollback possible
  without overwriting a previous release workspace.
  Date: 2026-08-25.
- Decision: preserve a validated source-root fallback, but never silently treat an arbitrary current
  directory as Nagare.
  Rationale: contributor workflows remain useful, while installed commands fail with a precise
  resource error instead of operating on unrelated same-named files.
  Date: 2026-08-25.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
`docs/plans/105-package-nagarectl-and-its-typed-config-runtime-with-nix.md`. EP-105 owns the root
flake's Haskell derivations and `nagarectl` app. Extend those outputs; do not introduce a second CLI
build.

The operational source tree has several families. `infra/pulumi/` is a Node/TypeScript Pulumi project
whose stack config projections are context-specific. `cluster/bootstrap/`, `cluster/observability/`,
and `cluster/local/` contain YAML, Kustomize resources, Helm values, and installers. `nixos/` contains
a nested flake for the GCE host image. `scripts/` contains cloud, host-image, local, and smoke
orchestration. `justfile` is the operator recipe index. These are platform assets: files owned by a
Nagare release rather than by an application or operator.

`cli/nagarectl/src/Nagare/Target.hs` defines `nagareConfigDir`, `nagareStateDir`, context names, and
per-context Pulumi state. Reuse these XDG helpers. `cli/nagarectl/src/Nagare/Init.hs` currently uses
literal `scripts/enable-apis.sh` and `infra/pulumi`; `cli/nagarectl/app/Main.hs` has direct Pulumi
working directories; `Nagare.Ops.Status`, `Nagare.Ops.Cleanup`, and `Nagare.Ops.Doctor` contain more
relative runtime/remediation paths. `scripts/lib/target.sh` and `.envrc` assume a checkout, and the
`justfile` recipes run relative to it. Use `rg` to refresh this inventory before editing because the
tree is active.

A payload is the read-only release-owned asset directory installed by Nix. A workspace is a writable,
per-context materialization of one payload used by programs that create generated config, npm files,
or Nix inputs. Application project roots and build contexts are not platform workspaces and must never
be rewritten through this resolver.

No relevant local or Mori ADR exists. MasterPlan 17,
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`, is authoritative context history:
it established `${XDG_STATE_HOME}/nagare/<context>` and noted the remaining checkout-local generated
files. This plan extends that state root without changing context-selection precedence.


## Plan of Work

### Milestone 1 — Define the payload and path contracts

This milestone creates the contract before moving call sites. Add
`cli/nagarectl/src/Nagare/Platform/Paths.hs` with pure path derivation and IO validation. Define a
payload manifest at the payload root—initially `release.json` with a development identity, asset
schema version, and source revision—and a required-file sentinel list. Resolution precedence is an
explicit command/test override, `NAGARE_PLATFORM_ROOT` set by the installed wrapper, then an ancestor
that validates as a Nagare source root. A named but invalid root is a hard error. Add tests using
temporary directories, including lookalike and missing-asset failures.

### Milestone 2 — Package and materialize platform assets

This milestone adds `packages.<system>.nagare-platform` to `flake.nix`. Copy the required assets to
`$out/share/nagare` with deterministic permissions and omit contributor-only build outputs, secrets,
and local state. Extend the `nagarectl` wrapper with the installed payload root and add a
`nagarectl platform root` diagnostic. Implement workspace preparation in
`Nagare.Platform.Workspace`: copy or render through a staging directory below
`${XDG_STATE_HOME}/nagare/<context>/platform/`, write a digest manifest, then atomically rename.
Reusing a matching workspace is a no-op; a digest mismatch selects a distinct directory and never
modifies the old one.

### Milestone 3 — Remove runtime checkout assumptions

This milestone migrates runtime call sites. Thread `PlatformPaths` into init, Pulumi stack selection and
outputs, status, cleanup, doctor remediation rendering, IAP access, host-image scripts, bootstrap, and
local-platform recipes. Prefer changing functions to accept a resolved path or an operations record so
pure tests remain pure. Shell scripts compute their own physical script directory and accept
`NAGARE_PLATFORM_ROOT`/`NAGARE_WORKSPACE_ROOT`; they do not depend on the caller's current directory.
The operator launcher `apps.<system>.nagare` runs the packaged `justfile` against the prepared
workspace, allowing `nix run .#nagare -- infra-preview` without `cd`.

### Milestone 4 — Prove clone-free and source-compatible operation

This milestone adds isolated tests and compatibility documentation. Use temporary XDG config/state roots,
a local context, fake external executables, and dry-run flags so no cloud or Kubernetes state changes.
Run representative commands from an empty temporary directory. Also exercise `nix develop` and the
repository `justfile` from source to prove contributor behavior still works. Update
`docs/user/reference.md` with payload/workspace diagnostics, but leave public onboarding finalization
to EP-109.


## Concrete Steps

From the repository root, refresh the coupling inventory:

```bash
rg -n 'scripts/|infra/pulumi|cluster/bootstrap|cluster/observability|nixos/|justfile' \
  cli/nagarectl/src cli/nagarectl/app scripts justfile
```

Build and inspect both Nix artifacts:

```bash
nix build .#nagarectl .#nagare-platform --print-build-logs
nix run .#nagarectl -- platform root --json
nix run .#nagare -- --list
```

Expected diagnostic shape:

```json
{"source":"installed","payloadRoot":"/nix/store/...-nagare-platform/share/nagare","workspaceRoot":".../nagare/test/platform/dev-..."}
```

Run the checkout-independent smoke in isolated state:

```bash
test_root="$(mktemp -d)"
XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  nix run .#nagarectl -- context create local --mode local --use
XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  nix run .#nagarectl -- init --dry-run --skip-preflight
```

The test harness should perform equivalent commands from a current directory outside the checkout and
remove only its own `mktemp` directory afterward. Finish with:

```bash
nix flake check --print-build-logs
bash -n scripts/*.sh scripts/lib/*.sh cluster/bootstrap/*.sh cluster/bootstrap/*/*.sh
```


## Validation and Acceptance

`nix build .#nagare-platform` must produce a payload containing a valid manifest and every sentinel
asset. `nagarectl platform root --json` must distinguish installed, explicit, and source roots.
Invalid explicit roots fail before invoking Pulumi, gcloud, kubectl, or a script and name the missing
asset.

From an empty directory with isolated XDG roots, context creation, `init --dry-run`, platform status
with fake tools, and at least one operator recipe dry-run must succeed. Test logs must prove subprocess
working directories and arguments point into the resolved workspace, not the test's current directory.
Preparing the same payload twice returns the same workspace without rewriting it. Preparing a fixture
with a different digest creates a second workspace. Two contexts prepare different paths and can run
simultaneously without touching the other's generated files.

Source compatibility is also acceptance: `nix develop`, Cabal tests, `just --list`, and existing local
smoke dry-run paths continue to resolve the repository root. No test searches or writes `/nix/store`;
the packaged path is supplied by the build result and treated as opaque.


## Idempotence and Recovery

Workspace creation uses a staging directory and atomic rename so interruption cannot expose a partial
workspace as current. Existing workspaces are immutable after their digest manifest is written. A
retry either reuses the complete match or discards only its own incomplete staging directory. Do not
delete earlier payload workspaces automatically; EP-108 needs them for rollback and a future cleanup
policy can prune unreferenced versions.

Keep the source fallback until EP-109 completes clone-free onboarding. If a migrated command regresses,
the operator can run it from a checkout while the call site is corrected. Never fall back from an
explicit invalid installed root to `$PWD`, because that could mix two releases.


## Interfaces and Dependencies

This plan hard-depends on EP-105's `packages.<system>.nagarectl` and app wrapper. It adds
`packages.<system>.nagare-platform` and `apps.<system>.nagare`.

`cli/nagarectl/src/Nagare/Platform/Paths.hs` owns an interface equivalent to:

```haskell
data PlatformRootSource = ExplicitRoot | InstalledRoot | SourceRoot

data PlatformPaths = PlatformPaths
  { platformRoot :: FilePath
  , pulumiDir :: FilePath
  , scriptsDir :: FilePath
  , clusterDir :: FilePath
  , nixosDir :: FilePath
  , justfilePath :: FilePath
  , rootSource :: PlatformRootSource
  }

resolvePlatformPaths :: Maybe FilePath -> IO (Either PlatformPathError PlatformPaths)
```

`cli/nagarectl/src/Nagare/Platform/Workspace.hs` owns an interface equivalent to:

```haskell
data Workspace = Workspace
  { workspaceRoot :: FilePath
  , workspacePayloadId :: Text
  }

prepareWorkspace :: FilePath -> ContextName -> PlatformPaths -> IO (Either WorkspaceError Workspace)
```

All resource-dependent functions accept `PlatformPaths`, `Workspace`, or an injected operations
record. `NAGARE_PLATFORM_ROOT` is the installed-wrapper contract; `NAGARE_WORKSPACE_ROOT` may be
exported to scripts only after validation. Neither variable is a target selector and neither belongs
in the stored context `.env` schema.
