---
id: 109
slug: publish-versioned-releases-and-clone-free-onboarding
title: "Publish versioned releases and clone-free onboarding"
kind: exec-plan
created_at: 2026-08-25T14:04:16Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Publish versioned releases and clone-free onboarding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, a maintainer can push a semantic version tag and have CI verify that the tag, Cabal
packages, Nix application, platform payload, and compatibility metadata agree before creating a
GitHub release. The release contains machine-readable metadata, checksums, generated notes, and exact
Nix commands for supported systems. Publication never changes a live cluster.

A new operator follows the README without cloning Nagare: run a pinned `nagarectl` through Nix, create
a context, generate operator host configuration, preview provisioning, and bootstrap the platform
from the tagged payload. Existing source-checkout operators receive a documented migration path that
preserves context state and credentials. The capability catalog stops describing all features as
unreleased and gains evidence for versioned distribution.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-25T20:40:11Z) M1: Define and test the release consistency gate and machine-readable release artifact set.
- [x] (2026-08-25T20:46:56Z) M2: Add tag-driven CI that builds supported Nix outputs and publishes checksums, metadata, and release notes.
- [x] (2026-08-25T20:51:44Z) M3: Rewrite install, onboarding, multi-cluster, upgrade, contributor, and capability documentation around pinned releases.
- [x] (2026-08-25T20:59:21Z) M4: Run a clean-room clone-free acceptance rehearsal and document the maintainer release/rollback runbook.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `.github/workflows/ci.yml` runs only branch/PR flake checks and `.github/workflows/live-smoke.yml`
  is manual/monthly with cloud authentication intentionally unconfigured. There is no tag workflow,
  Git tag, changelog, or release manifest today. Date: 2026-08-25.
- `docs/capabilities/index.md` explicitly says every capability is unreleased because Nagare has no
  release tags. The first release must update both the catalog-level statement and each shipped
  capability's `since` field consistently, under the existing OKF profile. Date: 2026-08-25.
- Forcing a foreign-system package derivation field during release validation starts Nix import from
  derivation and therefore tried the unavailable configured Linux SSH builder on this Apple Silicon
  workstation. The gate now compares foreign package attribute names lazily and builds/inspects only
  native artifacts; the workflow matrix owns native proof for the other system. Evidence: the first
  full gate failed on `packages.x86_64-linux.nagarectl.name`, while the revised gate and full
  `nix flake check --print-build-logs` passed locally. Date: 2026-08-25.
- The two native runners must not upload into one merged artifact directory because their common
  manifest and notes filenames collide. Each runner now uploads a uniquely named directory; the
  publish job compares the shared files byte-for-byte before assembling one checksum set. Evidence:
  the assembly test covers both declared systems and `actionlint` validates the workflow. Date:
  2026-08-25.
- An exact `git+file` revision preserves the immutable flake/ref behavior needed for a clean-room
  rehearsal before unpublished commits exist on GitHub. From an isolated home and a directory outside
  the checkout, revision `4430a972f86d4abcab8f82fbd6d8f586709ad0ff` passed version, context,
  external typed-config, payload, host-config, local/cloud onboarding, and operator-recipe checks on
  `aarch64-darwin`. The release matrix runs the same script on `x86_64-linux`. Date: 2026-08-25.


## Decision Log

Record every decision made while working on the plan.

- Decision: use Git tags of the form `v<major>.<minor>.<patch>` as the published release identity and
  require all internal version sources to match before publication.
  Rationale: users need one immutable reference for `nix run github:shinzui/nagare/vX.Y.Z#nagarectl`,
  payload selection, host inputs, and upgrade targets. Before the first release, normalize the three
  Cabal package versions from the current four-component `0.1.0.0` placeholder to the same
  three-component release version; do not maintain a hidden mapping between two version schemes.
  Date: 2026-08-25.
- Decision: the release workflow validates and publishes an existing tag; it does not bump versions,
  commit files, tag source, or operate clusters.
  Rationale: version choice remains an explicit reviewed source change, and CI publication stays
  reproducible and side-effect-limited.
  Date: 2026-08-25.
- Decision: Nix-by-tag is the supported install artifact in this initiative; GitHub release attachments
  are metadata and checksums, not a promise of portable binaries.
  Rationale: native archives would need separate runtime-dependency and platform support work and were
  explicitly excluded by the MasterPlan.
  Date: 2026-08-25.
- Decision: make root `release.json` the source of truth for the semantic platform version, supported
  Nix systems, and release schema versions, while Nix injects the clean or dirty Git revision into the
  built CLI and payload.
  Rationale: Cabal versions remain package metadata that the gate independently compares, but the
  flake and payload must not maintain a second supported-system or platform-version list. Revision is
  provenance of one build, not a manually edited source value.
  Date: 2026-08-25.
- Decision: build each supported Nix system on a native trusted runner, keep repository permissions
  read-only through validation, and grant `contents: write` only to the tag-only publication job.
  Rationale: Nix output identity must be proved on the platform that produced it, manual rehearsals
  must be incapable of publishing, and a rerun must either observe identical immutable attachments
  or stop rather than replace release evidence.
  Date: 2026-08-25.
- Decision: make the tagged `nagarectl` output the app-developer entry point and the tagged `nagare`
  output the operator entry point; reserve `nix develop`, checkout-local `just`, and uncommitted flake
  references for contributors.
  Rationale: users can pin the smallest artifact they need, while platform recipes resolve the same
  immutable payload without conflating released operation with source development.
  Date: 2026-08-25.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Nagare 0.1.0 now has one consistency gate across all Cabal packages, source release metadata, CLI,
payload, host schema, compatibility fixtures, changelog, notes, revision, and supported systems. A
tag/manual workflow validates normal flake checks and clone-free use on native Linux and Apple Silicon
runners, then a tag-only minimal-permission job publishes deterministic metadata, Nix output
identities, notes, and checksums without replacing different existing attachments.

The user path is now release-first: app developers select tagged `nagarectl`, operators select the
tagged `nagare` launcher and immutable payload, contexts/host inputs remain in XDG state, and only
contributors use a checkout dev shell. All 19 capability records pass the strict shared profile and
identify 0.1.0 while retaining experimental compatibility. The local exact-commit clean-room
rehearsal passed every command family on `aarch64-darwin`; Linux execution is encoded in the same
release matrix and will produce its native evidence when maintainers run the non-publishing workflow.

No Git tag or GitHub release was created while implementing this plan. The signed first tag, native
CI evidence, and public release remain explicit maintainer actions after review, as required by the
runbook. Durable distribution and immutability decisions are captured in
`docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md`.


## Context and Orientation

This plan is the integration layer. It hard-depends on
`docs/plans/107-externalize-per-operator-nixos-and-host-configuration.md` and
`docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md`, which transitively depend on
the installable CLI and platform payload. Read their current interfaces before editing; do not change
the root flake output names, payload manifest, host module, or compatibility policy here unless the
MasterPlan and affected child plans are revised first.

The current workflows are `.github/workflows/ci.yml` and `.github/workflows/live-smoke.yml`. CI uses
`nix flake check` as its source of truth. Preserve that: a release job first runs or depends on the same
checks, then validates release-specific invariants. Before selecting GitHub runner labels or action
versions, consult current official GitHub Actions documentation because availability and action
releases are temporally unstable. Supported build systems come from `flake.nix`, initially
`x86_64-linux` and `aarch64-darwin`; do not claim another system without a native or trusted remote
build and acceptance test.

User entry points are `README.md`, `docs/user/README.md`, `docs/user/getting-started.md`,
`docs/user/onboarding-bring-your-own-project.md`, `docs/user/deploying-apps.md`,
`docs/user/contexts.md`, `docs/user/host-image-and-boot.md`, `docs/user/upgrades.md`, and
`docs/guides/running-multiple-clusters.md`. Contributor operation still uses `nix develop` and the
checkout. End-user operation should use a pinned tag and installed XDG configuration/workspaces.

The OKF-governed capability bundle lives in `docs/capabilities/`, with its profile in
`docs/capabilities/profile.dhall`, reserved `index.md`/`log.md`, and stable `CAP-N` handles. Use
`okf id next` rather than guessing a new handle, update `log.md` through the CLI, and run strict
profile validation. There is no ADR bundle at plan creation; consult again before implementation and
distill the durable release/version decisions from EP-105 through EP-108.


## Plan of Work

### Milestone 1 — Build the release consistency gate

This milestone creates a release gate runnable locally and in CI. Add a script such as
`scripts/check-release.sh` that takes an explicit tag/version and compares it with all Cabal package
versions, `nagarectl version --json`, the built payload `release.json`, host-flake metadata schema, and
the version compatibility fixtures. It must reject a dirty tree when used for publication, malformed
or moving tags, mismatched versions, missing changelog/release-note content, and unsupported flake
outputs. Emit JSON for the workflow and human-readable diagnostics locally. Generate a release
manifest and SHA-256 checksum file from already-built outputs without embedding machine-specific
store paths as user-facing identities. Normalize `nagare-dsl`, `nagarectl`, and `nagare-access` to the
same three-component Cabal version before the first tag so the release gate performs equality rather
than an undocumented conversion.

### Milestone 2 — Publish tags through a minimal-permission workflow

This milestone adds `.github/workflows/release.yml`, triggered only by matching pushed tags and manual
rehearsal. The workflow checks out the exact tag, installs Nix, runs the normal flake checks, runs the
release gate, builds every supported output on an appropriate trusted runner, uploads metadata and
checksums as workflow artifacts, and creates a GitHub release with generated/reviewed notes. Grant the
minimum `contents: write` permission only to the publish job. Pull requests and manual dry runs never
publish. Use concurrency keyed by tag and refuse to replace an existing release with different
artifacts.

### Milestone 3 — Make released artifacts the documented user path

This milestone rewrites documentation. Make the primary command form
`nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- ...` and show `nix profile install` as the persistent
alternative. Clearly distinguish developer CLI use, full platform/operator use, and contributor
checkout use. Update onboarding to generate per-context host configuration rather than edit source;
update multi-cluster docs to pin and upgrade contexts independently; update upgrades with release
selection and transaction recovery. Add or update the distribution capability record, replace
`since: unreleased` for capabilities included in the first release, and preserve experimental
stability where appropriate.

### Milestone 4 — Rehearse clone-free installation and release recovery

This milestone performs a clean-room rehearsal. In a temporary home/XDG tree on every supported system,
use a local immutable tag candidate or exact commit through the same flake URL shape, run version and
context commands, load an external typed config, generate host configuration, prepare the payload, and
run cloud/local onboarding dry runs without a Nagare clone. Record concise evidence in this plan and
the release runbook. Test the workflow in non-publishing mode; the actual first tag and GitHub release
remain an explicit maintainer action after review. Document how to deprecate/yank a broken release
without moving or deleting its Git tag and how operators remain pinned to the prior version.


## Concrete Steps

From the repository root, run the release gate against the candidate version before tagging:

```bash
./scripts/check-release.sh --version 0.1.0 --json
nix flake check --print-build-logs
nix build .#nagarectl .#nagare-platform
```

Expected gate shape:

```json
{"version":"0.1.0","tag":"v0.1.0","consistent":true,"systems":["x86_64-linux","aarch64-darwin"]}
```

Validate the capability bundle after updating release evidence:

```bash
okf validate docs/capabilities \
  --strict \
  --profile docs/capabilities/profile.dhall \
  --profile-enforce \
  --log-enforce
mori validate
```

Exercise the clean-room flow with isolated directories. Do not search or traverse `/nix/store`; let
Nix and the CLI consume their own outputs:

```bash
clean_home="$(mktemp -d)"
HOME="$clean_home/home" XDG_CONFIG_HOME="$clean_home/config" XDG_STATE_HOME="$clean_home/state" \
  nix run .#nagarectl -- version --json
HOME="$clean_home/home" XDG_CONFIG_HOME="$clean_home/config" XDG_STATE_HOME="$clean_home/state" \
  nix run .#nagarectl -- context create local --mode local --use
```

After maintainer review, tag creation is deliberately manual and Conventional Commits remain required
for commits:

```bash
git tag -s v0.1.0 -m 'Nagare v0.1.0'
git push origin v0.1.0
```

Do not run these last two commands while implementing the plan unless the user explicitly authorizes
publication.


## Validation and Acceptance

The release gate must pass on a consistent clean candidate and fail for each deliberately mismatched
version source, malformed tag, dirty publication tree, missing output, and unsupported system. The
release workflow must be syntax-valid, use the normal flake checks, restrict write permission to
publication, and support a rehearsal that uploads artifacts without creating a release. Generated
metadata and checksums must be deterministic across retries of the same source/tag.

On every supported system, the clean-room test starts outside a Nagare clone and proves: `version`
works; the CLI creates and shows a context; a typed external config dry-runs; the installed payload
resolves and prepares; host configuration dry-runs/evaluates; and local/cloud init dry-run reaches the
expected external command plan. No step edits a released payload or source checkout.

Documentation acceptance is task-oriented: a reader can identify the latest stable release, pin it,
install temporarily or persistently, distinguish app versus operator prerequisites, create two
contexts at different versions, upgrade labs first, and recover from a failed staged upgrade. All
local Markdown links resolve. Strict capability validation and `mori validate` pass, and the catalog
no longer incorrectly says all shipped behavior is unreleased after the first release is actually
published.


## Idempotence and Recovery

Release checks and builds are safe to repeat. The publish job first checks for an existing release; if
its manifest matches, it reports success without replacement, and if it differs, it fails for manual
investigation. Never move or reuse a published version tag. A failed workflow may be rerun against the
same immutable tag after fixing only external CI infrastructure; a source fix requires a new version.

Publishing does not select or upgrade any context. Operators remain pinned until they run the EP-108
upgrade flow. If a release is bad, mark it deprecated in release notes and documentation, keep its tag
for reproducibility, and direct operators to a fixed later release or their retained prior payload.


## Interfaces and Dependencies

This plan consumes, without renaming, the root flake outputs `nagarectl` and `nagare-platform`, the
payload `release.json`, `nagarectl version --json`, EP-107's generated host flake, and EP-108's
semantic-version and compatibility contracts.

`scripts/check-release.sh` accepts `--version`, optional `--tag`, and `--json`; it performs no write
outside an explicit temporary/output directory. Its JSON includes at least `version`, `tag`,
`revision`, `consistent`, `systems`, `payloadDigest`, and a list of checked sources. Shell parsing may
delegate JSON work to the already-pinned `jq`; avoid adding a new release framework unless source and
documentation are first located with Mori and authoritative upstream versions are verified.

`.github/workflows/release.yml` has separate check/build and publish jobs. It uploads a
`nagare-release-<version>.json`, `SHA256SUMS`, and release notes. The supported end-user interfaces are:

```bash
nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- <args>
nix profile install github:shinzui/nagare/vX.Y.Z#nagarectl
nix run github:shinzui/nagare/vX.Y.Z#nagare -- <operator-recipe>
```

Homebrew formulae, container images for the CLI, Helm distribution, and portable binary tarballs are
not outputs of this plan.
