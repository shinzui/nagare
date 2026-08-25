---
title: "Version platform state across CLI, payload, context, host, and cluster"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
---

# ADR 6 — Version platform state across CLI, payload, context, host, and cluster

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 108](../plans/108-add-per-context-platform-versions-and-safe-upgrades.md).

## Context

An installed Nagare operation crosses five independently replaceable artifacts: the running
`nagarectl`, its immutable platform payload, a context's intended release, the context-owned host
flake, and the resources last bootstrapped into Kubernetes. Before this decision only the Cabal
package and payload carried versions. A source checkout, generated host input, and live cluster could
silently drift while commands continued to mutate infrastructure.

Legacy contexts and clusters cannot be assigned a truthful historical version automatically. They
also need read-only diagnosis and an explicit adoption path rather than an immediate hard failure.

## Decision

Nagare uses semantic `major.minor.patch` platform versions, optionally with a semantic-version
prerelease suffix. Git revision and payload schema remain separate provenance fields. The running CLI
reports its platform version, `release.json` identifies the payload, named context files optionally
store `NAGARE_PLATFORM_VERSION`, generated host flakes carry explicit version and revision comments,
and the final successful bootstrap step writes ConfigMap `nagare-platform-version` in namespace
`nagare-system`.

`nagarectl platform status` observes all five identities without mutating them and grades their
relationship against the payload supplying the operation. Exact versions are compatible. Patch skew
warns but remains operable. Minor skew requires an explicit upgrade transaction. Major skew blocks
platform mutation. A missing, malformed, or unreachable identity is legacy/unknown: status and doctor
warn, read-only commands continue, and mutation remains available for the explicit adoption and
initial-bootstrap paths.

Platform-changing recipes call the shared guard before mutation. Cloud and local bootstrap stamp the
cluster only after all earlier bootstrap commands succeed, so the ConfigMap is an observed completion
marker rather than an optimistic desired version.

## Consequences

Operators can distinguish CLI/payload drift from context intent and live host/cluster state. Known
incompatible releases fail before external mutation, while existing source-managed installations
remain inspectable and can be adopted deliberately.

Every future distribution channel must populate the same payload metadata and preserve the semantic
compatibility policy. A missing marker cannot prove compatibility, so automation that requires a
strictly managed target must first adopt or upgrade it. The context pin remains operator intent; a
later upgrade transaction advances it only after host and cluster phases succeed.
