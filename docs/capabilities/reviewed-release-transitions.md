---
title: "Reviewed release transitions"
type: Capability
description: "Move an installed, inventory-backed context from its pinned release to a newer one through reviewed, resumable stages that keep its data."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
capabilityId: CAP-24
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.6.0
packages:
  - nagarectl
  - nagare-platform
interface:
  - "nagarectl platform transition plan|commit"
  - "Nagare.Platform.Transition"
  - "transitionsFrom"
requires:
  - CAP-19
  - CAP-22
evidence:
  - kind: module
    resource: cli/nagarectl/src/Nagare/Platform/Transition.hs
    proves: A transition plans stages from the context's pinned release to this payload's, refuses a source the payload's transitionsFrom does not list, and commits the pin last.
  - kind: test
    resource: cli/nagarectl/test/PlatformTransitionTableSpec.hs
    proves: A recorded 0.4.0 payload and store read back under this release's codecs, and the plan moves the pin last and the bootstrap stamp after every scope it covers.
  - kind: test
    resource: cli/nagarectl/test/PlatformTransitionSpec.hs
    proves: A release is accepted only with a rehearsal record of this candidate from a listed release whose seeded data read back unchanged.
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/Model/Transition.hs
    proves: In the recovery model the transition marker survives the faults and exits of each stage, and commit requires an idle head with the marker open.
  - kind: example
    resource: scripts/transition-rehearsal.sh
    proves: A disposable local context is seeded on the previous release, moved to the candidate through the same commands, and its seeded row is read back.
  - kind: conformance
    resource: docs/release-evidence/a6004f2292071f4587dc52b821f5c88edcb3eff2/transition-rehearsal.json
    proves: The 0.8.0 candidate moved a seeded local context from 0.7.1 and read the seeded row back unchanged.
  - kind: guide
    resource: docs/releases/v0.6.0.md
    proves: The upgrade steps (plan, apply, replan until empty, commit) and the transition marker's rules are documented.
---

# Reviewed release transitions

An installed context moves to a newer release in place. With the target release's `nagarectl`,
`platform transition plan --out DIR` reviews the next stage from the context's pinned release to
this payload's. Each stage is an ordinary saved review applied with `inventory apply DIR --yes`;
the operator plans again until the review has no operations, then `platform transition commit
--yes` pins the context to the new release.

The first admitted stage opens a transition marker in the store head. Until the commit, only the
target release's `nagarectl` applies, resumes, recovers or closes, and a stopped stage resumes from
its journal through the [reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22). Cloud
scopes are planned again from the new payload; an accepted host is re-pinned through the reviewed,
self-reverting activation and never re-imaged. The pin moves last, so an interrupted transition
leaves the context on its old release with its data in place.

A release names the releases it accepts in `transitionsFrom`, and it is published only with a
rehearsal record that moved a seeded disposable local context from a listed release and read the
seeded data back unchanged ([release runbook](../runbooks/releases.md)). Payload identity and
distribution build on [versioned Nix distribution](versioned-nix-distribution.md) (CAP-19).

## Limits

- A context moves only from a release in the target's `transitionsFrom`; skipping releases is not
  supported unless the target lists the source.
- A transition moves forward only; `rollbackSupportedFrom` is empty, and selecting an older
  release never restores application data.
- Node (NixOS and k3s) and PostgreSQL major upgrades within a context are separate procedures.
