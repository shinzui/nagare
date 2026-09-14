---
title: "Version platform state across CLI, payload, context, host, and cluster"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md
  - docs/plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md
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

Legacy adoption is an explicit observed-state commit, not an inferred upgrade. The command first
reports all five identities and requires operator confirmation. It accepts only an unversioned
context whose active payload matches the requested version, rejects every known CLI, host, or
cluster mismatch, stamps an absent cluster marker, and writes the context pin last. Unknown host or
cluster observations are tolerated because old installations may not contain either marker; an
unreachable cluster still prevents adoption when the stamp cannot be applied.

Platform-changing recipes call the shared guard before mutation. Cloud and local bootstrap stamp the
cluster only after all earlier bootstrap commands succeed, so the ConfigMap is an observed completion
marker rather than an optimistic desired version.

An explicit upgrade is a schema-versioned JSON transaction under the context's XDG state directory.
Planning stages a content-addressed payload workspace and a copied host flake, then records Nix
evaluation, Pulumi preview, and Kubernetes diff evidence. Apply records Pulumi, host, Kubernetes,
cluster-stamp, and context-commit phases in that order. Each successful phase is persisted; resume
re-checks the postcondition before skipping it. The host phase can advance only generated `flake.nix`
and `flake.lock`; it never copies staged `host.nix` or `secrets.yaml` back over operator files. The
context version is the final commit point.

Release metadata may list versions from which selecting this release can later be reversed. Nagare
offers an automated reverse transaction only when that direction was explicitly recorded and the old
content-addressed workspace is retained. It does not claim to reverse application data or Pulumi
schema migrations.

## Consequences

Operators can distinguish CLI/payload drift from context intent and live host/cluster state. Known
incompatible releases fail before external mutation, while existing source-managed installations
remain inspectable and can be adopted deliberately.

Every future distribution channel must populate the same payload metadata and preserve the semantic
compatibility policy. A missing marker cannot prove compatibility, so automation that requires a
strictly managed target must first adopt or upgrade it. The context pin remains operator intent; a
later upgrade transaction advances it only after host and cluster phases succeed.

Interrupted upgrades can leave the host or cluster at the target release while the context still
names the previous version. That visible skew is intentional: status reports it, the transaction
identifies the completed phase, and resume converges forward without inventing success.

## Amendment — 2026-09-14: distinguish confirmed absence from unknown identity

[ExecPlan 135](../plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md) separates
deployment evidence from release identity. For a cloud context, a project-, zone-, and
instance-scoped GCE describe that explicitly reports resource NotFound establishes that the
single host is `not-deployed`; because Nagare's cluster resides on that host, the cluster is then
also `not-deployed` without contacting Kubernetes. A successful malformed response, missing tool,
authentication, permission, network, or other lookup failure is unknown, never absence. An existing
host or cluster without a readable release identity remains legacy/unknown.

Compatibility aggregation excludes only resources proven not deployed. It therefore preserves a
real patch skew between payload and context instead of letting absent identities outrank it. Human
and JSON status carry the explicit deployment states alongside the existing identity fields.

`nagarectl platform repin --version VERSION --yes` is the sole pre-deployment pin correction. It
requires the requested release to equal the active immutable payload, a versioned cloud context,
normal platform and project guards, confirmed host and cluster absence, and no cluster identity. If
a recognized generated host flake exists, its generated release metadata and Nagare input advance
with the context while `host.nix` and `secrets.yaml` remain unchanged; unrecognized files refuse.
The command has no force mode and becomes permanently unavailable once deployment exists. Deployed
contexts continue to use adoption or the upgrade transaction according to their identity state.
