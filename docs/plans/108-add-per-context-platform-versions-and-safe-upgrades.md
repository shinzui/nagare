---
id: 108
slug: add-per-context-platform-versions-and-safe-upgrades
title: "Add per-context platform versions and safe upgrades"
kind: exec-plan
created_at: 2026-08-25T14:04:16Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Add per-context platform versions and safe upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, Nagare can answer four distinct version questions: which CLI is running, which
platform payload supplies operational assets, which release a context intends to manage, and which
release last bootstrapped the selected cluster. `nagarectl platform status --context labs` compares
those identities and explains compatible, legacy, drifted, and incompatible states. Mutating platform
commands refuse a major-version mismatch instead of silently applying one checkout's desired state to
another release.

`nagarectl platform upgrade --context labs --to 0.2.0` stages an immutable payload and generated host
flake, validates compatibility, shows Pulumi and Kubernetes changes, and updates the context pin only
after an explicit apply succeeds. Production and labs can therefore move independently. Failed or
interrupted upgrades preserve the prior pin and workspace and can be retried safely.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-25T19:03:00Z) M1: Define semantic platform versions, release metadata, context persistence, and compatibility rules.
- [x] (2026-08-25T19:50:27Z) M2: Stamp and inspect cluster and host release identities and integrate version checks into doctor/status.
- [ ] M3: Implement staged upgrade planning, apply, history, retry, and supported rollback behavior.
- [ ] M4: Validate legacy migration, multi-context skew, failure recovery, and operator upgrade documentation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Existing capability records use `since: unreleased`, the capability index states that Nagare has no
  release tags, and all three Cabal packages report `0.1.0.0`. There is currently no single platform
  identity to compare. Date: 2026-08-25.
- Context files are deliberately a flat `export VAR=value` schema shared by Haskell and bash. The
  platform version must extend that schema through both resolvers rather than living only in Haskell
  JSON state. Date: 2026-08-25.
- An ambient `NAGARE_PLATFORM_ROOT` from the packaged wrapper can leak into Cabal tests that intend to
  exercise source-root discovery. The source-fallback test now clears and restores that variable,
  while installed-root precedence remains covered separately. Evidence: all 386 `nagarectl-test`
  cases pass under the packaged development environment. Date: 2026-08-25.


## Decision Log

Record every decision made while working on the plan.

- Decision: use semantic `major.minor.patch` platform versions and retain the Git revision as separate
  provenance.
  Rationale: compatibility policy needs structured major/minor meaning, while two builds of a release
  may need exact source traceability. A raw Git SHA alone cannot express upgrade compatibility.
  Date: 2026-08-25.
- Decision: treat an absent context or cluster version as legacy/unmanaged with a warning, not as the
  running CLI version.
  Rationale: inventing a version would hide the very skew this feature exists to expose. Legacy users
  need a non-destructive adoption path, so read-only inspection remains available.
  Date: 2026-08-25.
- Decision: block platform mutations on major-version mismatch, warn on patch skew, and require an
  explicit upgrade plan for minor-version changes.
  Rationale: this is conservative enough to prevent incompatible schema/application while permitting
  diagnostic access and normal same-release day-2 operations.
  Date: 2026-08-25.
- Decision: update the context version only after all selected apply phases succeed.
  Rationale: the context is operator intent and the recovery anchor. Advancing it before infrastructure
  and bootstrap success would turn a partial failure into misleading desired state.
  Date: 2026-08-25.
- Decision: keep semantic-version parsing in `Nagare.Version` and add no new package dependency.
  Rationale: the required release grammar and compatibility matrix are small, strict, and now table
  tested; avoiding another library keeps EP-105's hermetic package closure unchanged.
  Date: 2026-08-25.
- Decision: use the resolved payload as the comparison anchor and one shared grader for status,
  doctor, and mutation guards.
  Rationale: every operational asset comes from that immutable payload, so comparing all other
  identities against it detects the release actually attempting the operation. One grader prevents
  diagnostics and guards from disagreeing about safety.
  Date: 2026-08-25.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
`docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md`, which defines the
payload `release.json`, resolved paths, and versioned context workspace. It soft-depends on
`docs/plans/107-externalize-per-operator-nixos-and-host-configuration.md`; upgrade implementation may
start with a fixture host flake, but final acceptance must preserve the generated `host.nix` while
changing only its Nagare release input.

`cli/nagarectl/src/Nagare/Version.hs` and `nagarectl version --json` are introduced by EP-105.
`cli/nagarectl/src/Nagare/Target.hs` defines `TargetProfile`, parses stored context environment files,
and returns `ActiveTarget`. `cli/nagarectl/src/Nagare/Init.hs` renders every context field, while
`scripts/lib/target.sh` implements the matching bash resolution/export contract. Add
`NAGARE_PLATFORM_VERSION` to all of these in one change and isolate XDG roots in tests.

`cluster/bootstrap/` owns cluster installation. A new ConfigMap named `nagare-platform-version` in
namespace `nagare-system` records release metadata after a successful bootstrap, not before.
`cli/nagarectl/src/Nagare/Ops/Status.hs` gathers Kubernetes and Pulumi observations;
`Nagare.Ops.Doctor.hs` grades them. Add version observation through injected `kubectl` operations so
offline tests can exercise all states.

`docs/user/upgrades.md` currently describes manual layer-by-layer upgrades, including rehearsing in a
non-production environment and preserving rollback paths. This plan builds on that safety model rather
than replacing it with an opaque all-or-nothing command. Pulumi previews, Nix evaluation, Kubernetes
server-side dry runs/diffs, data backup checks, and explicit approval remain visible phases.

The immutable payload/workspace and context-owned host boundaries are recorded in
`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md` and
`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`. This plan's implemented
compatibility matrix, five identity locations, and final context commit point are recorded in
`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`.


## Plan of Work

### Milestone 1 — Define version identity and compatibility

This milestone expands version identity into a compatibility contract. In `Nagare.Version`, parse and
render semantic platform versions without adding a dependency unless source inspection proves an
existing library is justified. Include the exact Git revision and asset schema versions in
`release.json`. Extend `TargetProfile`, context creation/init parsers, Haskell and bash renderers, and
documentation with optional `NAGARE_PLATFORM_VERSION`. New installed contexts default to the running
payload version; legacy source contexts remain unversioned. Define a pure comparison result covering
exact, patch skew, minor upgrade required, major incompatible, and unknown legacy states, with table
tests.

### Milestone 2 — Observe and guard installed versions

This milestone adds observed identities. Package a bootstrap template for the
`nagare-platform-version` ConfigMap and apply it only at the final successful bootstrap checkpoint.
Add a version field to the generated host flake input/metadata from EP-107. Implement
`nagarectl platform status [--json]` and add a doctor check that compares CLI, payload, context, host,
and cluster. Read-only commands always report; platform-mutating entry points call a shared guard
before executing. App deploy-class commands are not blocked merely because the cluster marker is
legacy unless their DSL/schema compatibility is actually affected and covered by tests.

### Milestone 3 — Stage and apply resumable upgrades

This milestone implements `nagarectl platform upgrade`. Separate pure planning from IO. The plan phase
resolves a tag/release through Nix, verifies its signed/fixed metadata as available, prepares the new
payload workspace, generates or updates a staged host flake, runs Nix evaluation, Pulumi preview, and
Kubernetes render/diff, then writes an upgrade transaction under the context state root. `--apply`
requires an existing successful plan and explicit confirmation, reruns stale checks, applies phases in
documented order, stamps the cluster last, and atomically updates the context version. Record previous
and target versions, payload digests, phase states, timestamps, and concise evidence. Provide
`platform upgrade status` and `--resume`. Rollback may reselect a previous payload/host pin when the
release metadata declares that direction supported; it must never claim to reverse data or Pulumi
schema migrations automatically.

### Milestone 4 — Validate adoption, skew, and recovery

This milestone tests legacy adoption and failure recovery. Simulate external tools through injected
operations and temporary workspaces: exact version, patch drift, incompatible major, absent ConfigMap,
failure after each apply phase, retry, and two contexts on different releases. Add a documented
`platform adopt --version` or equivalent explicit command for a legacy context only after status has
reported observations and the operator confirms them. Update `docs/user/upgrades.md` and
`docs/guides/running-multiple-clusters.md`; EP-109 owns final released install commands.


## Concrete Steps

Work from the repository root. Exercise the pure version behavior first:

```bash
cd cli/nagarectl
cabal test nagarectl-test --test-show-details=streaming
cd ../..
nix run .#nagarectl -- version --json
```

Create isolated `prod` and `labs` contexts at different fixture versions and inspect them with fake
cluster observations:

```bash
state_root="$(mktemp -d)"
XDG_CONFIG_HOME="$state_root/config" XDG_STATE_HOME="$state_root/state" \
  nix run .#nagarectl -- platform status --context labs --json
```

Expected JSON includes each identity and an actionable result:

```json
{"cli":"0.2.0","payload":"0.2.0","context":"0.1.0","cluster":"0.1.0","compatibility":"minor-upgrade-required"}
```

Exercise planning without applying:

```bash
XDG_CONFIG_HOME="$state_root/config" XDG_STATE_HOME="$state_root/state" \
  nix run .#nagarectl -- platform upgrade --context labs --to 0.2.0 --dry-run --json
```

The result must name the staged workspace and host flake, show preview/diff phase results, and leave
the stored context at `0.1.0`. Complete validation with:

```bash
nix flake check --print-build-logs
bash -n scripts/*.sh scripts/lib/*.sh
```


## Validation and Acceptance

Version parsing and compatibility tables must cover releases, prereleases if supported, invalid text,
exact matches, every skew direction, and legacy values. Haskell and bash must round-trip the same
`NAGARE_PLATFORM_VERSION`. `version --json`, payload `release.json`, context output, generated host
flake metadata, and cluster ConfigMap must agree in an exact-version fixture.

`platform status` must remain useful when Kubernetes is unreachable or the ConfigMap is absent; it
reports unknown/legacy rather than crashing. A major mismatch causes platform-changing dry-run/apply
entry points to exit nonzero before any external mutating command, while status and doctor still run.

Upgrade acceptance uses fake operations plus a local disposable cluster when available. A dry run
does not alter the context or cluster marker. Injected failure after each phase leaves the old context
pin current and records a resumable transaction. A successful apply stamps the cluster, updates the
host release reference without changing operator keys/secrets, advances the context atomically, and
makes status exact. `prod` remains at its old version while `labs` upgrades. Re-running a completed
upgrade is an idempotent no-op.


## Idempotence and Recovery

Payload workspaces and generated host revisions are immutable and retained until explicitly pruned.
Every upgrade writes a transaction before mutation and phase completion after successful observation.
Resume reruns idempotent previews/applies and skips only phases whose postcondition still holds. The
context pin is the final commit point.

If an upgrade cannot complete, the operator continues using the old payload and host flake and can
inspect the new workspace. Rollback never deletes infrastructure or restores application data. It may
switch the selected release only when compatibility metadata and documented manual checks permit it.
Back up databases and retained volumes using existing commands before any release that declares a
stateful migration.


## Interfaces and Dependencies

This plan consumes EP-106's payload manifest/workspace and EP-107's generated host flake. It adds
`NAGARE_PLATFORM_VERSION` to the context schema and exports it through `scripts/lib/target.sh`.

`cli/nagarectl/src/Nagare/Version.hs` must expose interfaces equivalent to:

```haskell
data PlatformVersion = PlatformVersion
  { major :: Natural
  , minor :: Natural
  , patch :: Natural
  , preRelease :: Maybe Text
  }

data Compatibility
  = Exact
  | PatchSkew
  | MinorUpgradeRequired
  | MajorIncompatible
  | LegacyUnknown

parsePlatformVersion :: Text -> Either VersionError PlatformVersion
comparePlatformVersions :: PlatformVersion -> Maybe PlatformVersion -> Compatibility
```

`cli/nagarectl/src/Nagare/Platform/Upgrade.hs` separates `planUpgrade` from `applyUpgrade` through an
injected operations record. Persist a versioned JSON transaction schema under
`${XDG_STATE_HOME}/nagare/<context>/upgrades/<transaction-id>.json`; include a `schemaVersion` field so
future releases can migrate it explicitly.

The cluster marker is `ConfigMap/nagare-platform-version` in `nagare-system`, with data keys
`version`, `revision`, `payloadSchema`, and `installedAt`. EP-109 must publish the same release metadata
and must not invent a second version source.
