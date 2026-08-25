---
title: "Persistent application volumes and snapshots"
type: Capability
description: "Declare durable application volumes, inspect their claims, and snapshot or scratch-restore their contents through GCS or local MinIO."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-11
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Types.Volume"
  - "nagarectl storage list|inspect|snapshot|restore"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Volume validation and PVC plus workload manifest rendering are golden tested.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Claim discovery, backup object naming, retention, backend selection, and snapshot and restore Job rendering are tested.
  - kind: test
    resource: scripts/local-smoke.sh
    proves: A mounted file survives snapshot, deletion, and scratch-first restoration through MinIO.
  - kind: example
    resource: cluster/examples/uploads-volume/nagare/Config.hs
    proves: A shipped application declares and uses a persistent upload volume.
  - kind: guide
    resource: docs/user/persistent-storage.md
    proves: Declaration, ownership, inspection, snapshot, and restore behavior are documented.
---

# Persistent application volumes and snapshots

Typed `Volume` values render PVCs and mounts alongside an application. The storage commands compare
declarations with live claims, package a volume in a Kubernetes data-movement Job, store snapshots
under a deterministic prefix, retain the newest configured count, and restore into scratch storage
unless an explicit live overwrite is requested.

Volume attachment builds on [typed application deployment](typed-application-deployment.md) (CAP-6).

## Limits

- Knative PVC concurrency constraints still apply; a volume is not shared multi-writer storage.
- Snapshot consistency is filesystem-level. Nagare does not quiesce arbitrary application writes.
- Live restore is intentionally opt-in because it can overwrite current data.
- Cloud mode depends on GCS credentials; local mode's MinIO path is the one exercised end to end.
