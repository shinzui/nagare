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

- [ ] M1: Prototype and record a Nix-built GHC package environment in which `runghc` imports `Nagare.Dsl.*` outside the repository.
- [ ] M2: Replace network-enabled Cabal packaging with hermetic Nix derivations for pinned `cradle`, `nagare-dsl`, and `nagarectl`.
- [ ] M3: Expose `packages.<system>.nagarectl`, `apps.<system>.nagarectl`, and the default app with a runtime wrapper and version command.
- [ ] M4: Add flake checks proving isolated typed-config execution and document the Nix-first developer CLI install path.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Nagare's root `flake.nix` currently declares `x86_64-linux` and `aarch64-darwin`, a set of
network-enabled `checks`, and two `devShells`. It does not declare `packages` or `apps`. The default
development shell provides GHC 9.12, Cabal, cloud/Kubernetes tools, and other command-line programs,
but `nagarectl` itself is normally built under `cli/nagarectl/`. The CI workflow
`.github/workflows/ci.yml` installs Nix and runs `nix flake check` with a relaxed sandbox.

`cli/nagare-dsl/nagare-dsl.cabal` defines the typed deployment library. An application config imports
modules such as `Nagare.Dsl.Types` and emits JSON by running under `runghc`.
`cli/nagarectl/nagarectl.cabal` defines the library plus `nagarectl` and `nagared` executables and
depends on the sibling DSL. `cli/nagarectl/cabal.project` includes both local packages and pins the
unpublished process library `cradle` by Git commit. Before changing that pin or choosing a dependency
bound, use `mori registry show garnix-io/cradle --full`, read its source under the returned project
path, and verify any newer intended revision against upstream tags as required by `AGENTS.md`.

`cli/nagarectl/src/Nagare/GhcEnv.hs` is the current bridge from the executable to the typed DSL. It
walks upward from the current directory and executable location looking for
`cli/nagarectl/cabal.project`, then locates a `.ghc.environment.*` written by Cabal; if it finds the
repository it can invoke `cabal exec` as a fallback. `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` owns the
actual `runghc` subprocess. `cli/nagarectl/app/Main.hs` calls `resolveProjectGhcEnv` for deploy-class
commands. An installed Nix closure must make those imports work when repository discovery returns
`Nothing`.

No local `docs/adr/` directory or registered ADR bundle exists, and Mori returned no relevant
cross-repository packaging ADR. If implementation fixes a durable Haskell packaging or runtime
boundary, create an ADR using the repository's plain Markdown convention only after checking that an
ADR convention has not been introduced meanwhile.


## Plan of Work

### Milestone 1 — Prove the packaged typed-config runtime

This milestone is an isolated packaging prototype. In a temporary test derivation, build
`nagare-dsl`, construct the candidate GHC runtime, and run a minimal `Config.hs` from a directory
whose ancestors do not contain this repository. Test `runghc -XGHC2024 Config.hs` without
`GHC_ENVIRONMENT` pointing at a Cabal file. Record which Nix mechanism makes the import work and add
the prototype as a permanent flake check rather than leaving an ad hoc result. Acceptance is the
config emitting valid JSON under the same loader command used by `Nagare.Dsl.Load`.

### Milestone 2 — Build a hermetic Haskell package set

This milestone creates a hermetic Haskell package set in `flake.nix` or a small imported Nix module such
as `nix/haskell-packages.nix`. Fetch the exact `cradle` revision already pinned by
`cli/nagarectl/cabal.project`, build it with the selected GHC 9.12 package set, build local
`nagare-dsl`, and then build `nagarectl` with those overrides. Use fixed-output Nix sources and normal
Hackage inputs from the locked nixpkgs; do not run `cabal update` or allow network access in the
package derivation. Keep the existing build-and-test checks until equivalent package-based checks
prove all tests and examples.

### Milestone 3 — Expose the installable Nix application

This milestone adds `packages.<system>.nagarectl`, `apps.<system>.nagarectl`, and
`apps.<system>.default` to `flake.nix`. Wrap the executable with the tested GHC runtime and only the
external tools needed for checkout-independent developer operations. Add a small
`Nagare.Version` module or Cabal-generated version handler so `nagarectl version` exists; EP-108 will
extend its metadata, so this plan needs only a stable text and JSON surface. Do not add the platform
payload or operator launcher here. Ensure explicit environment overrides still work.

### Milestone 4 — Replace checks and document CLI installation

This milestone changes `checks` to consume the hermetic packages, adds an isolated external-config smoke
test, and updates the CLI installation portions of `README.md` and `docs/user/deploying-apps.md`.
Keep `docs/user/getting-started.md`'s full operator path checkout-based until EP-106 and EP-109
complete. The observable endpoint is a user running the local flake app from a temporary application
directory and receiving rendered dry-run output.


## Concrete Steps

Work from the repository root. First inspect the locked flake and dependency pins:

```bash
mori registry show garnix-io/cradle --full
mori registry docs garnix-io/cradle
sed -n '1,120p' cli/nagarectl/cabal.project
nix flake metadata
```

After adding the package outputs, build and inspect them:

```bash
nix build .#nagarectl --print-build-logs
nix run .#nagarectl -- version --json
nix flake show
```

The output should include an installable package and application and a parseable version object:

```text
packages
  ... nagarectl
apps
  ... nagarectl
{"version":"0.1.0",...}
```

For the critical isolated test, let the flake check create its own temporary directory; locally also
copy one small checked-in fixture to a `mktemp -d` directory and run:

```bash
env -u GHC_ENVIRONMENT -u NAGARE_GHC_ENVIRONMENT \
  nix run .#nagarectl -- deploy --dry-run --file /absolute/path/to/temp/nagare/Config.hs
```

The command must emit rendered Kubernetes objects and must not mention `cabal.project`, a missing
package environment, or `Could not find module 'Nagare.Dsl...'`. Finish with:

```bash
nix flake check --print-build-logs
```


## Validation and Acceptance

Acceptance requires all of the following. `nix build .#nagarectl` succeeds for each system already
declared by the flake when run on that system. `nix run .#nagarectl -- version --json` exits zero and
prints valid JSON. `nix flake check` builds the packages, executes the Haskell test suites, compiles
the shipped examples, and runs the isolated external typed-config check without a relaxed networked
Cabal build.

The behavioral proof must run from a temporary directory outside Nagare with `GHC_ENVIRONMENT` and
`NAGARE_GHC_ENVIRONMENT` unset. A valid fixture reaches manifest rendering. An invalid fixture still
fails before Docker or Kubernetes with the existing precise load error. A contributor-built Cabal
binary inside the checkout continues to discover its environment, and an explicit `--ghc-env` still
wins over the installed default.


## Idempotence and Recovery

Nix builds are content-addressed and safe to repeat. Fixed dependency sources must be represented in
`flake.lock`; if a hash is wrong, update only after verifying the authoritative source revision. Do
not delete the current checks until their package-based replacements pass. If the chosen GHC wrapper
does not propagate its package database to `runghc`, revert only the prototype and try the alternate
explicit package-environment mechanism; do not add a reference to a developer's store path or Cabal
build tree. The existing `nix develop` plus Cabal workflow remains the recovery path throughout this
plan.


## Interfaces and Dependencies

`flake.nix` must expose `packages.<system>.nagarectl`, `apps.<system>.nagarectl`, and
`apps.<system>.default`. The `nagarectl` package includes the executable plus the tested typed-config
runtime. Later plans may wrap or compose this package but must not rebuild it through a second Cabal
path.

`cli/nagarectl/app/Main.hs` must accept `nagarectl version [--json]`. Put pure version rendering in
`cli/nagarectl/src/Nagare/Version.hs`, with an interface equivalent to:

```haskell
data BuildVersion = BuildVersion
  { versionText :: Text
  , revisionText :: Maybe Text
  }

renderBuildVersionJson :: BuildVersion -> ByteString
```

EP-108 may extend this type but must preserve the command and JSON compatibility. The DSL-loading
contract remains `Nagare.GhcEnv.resolveProjectGhcEnv` plus `Nagare.Dsl.Load`; the Nix wrapper supplies
the default runtime without embedding a path to a mutable checkout.

The only non-Hackage source dependency in `nagarectl` is the pinned
[Cradle package](mori://garnix-io/cradle/packages/cradle). Its current source API is already consumed throughout the
CLI via `cmd`, `addArgs`, `run`, and `run_`; this plan changes packaging, not those call sites.
