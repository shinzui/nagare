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

Full plan before trimming: [109-publish-versioned-releases-and-clone-free-onboarding.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/109-publish-versioned-releases-and-clone-free-onboarding.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

