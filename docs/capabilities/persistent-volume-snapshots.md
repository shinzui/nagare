---
title: "Persistent application volumes and snapshots"
type: Capability
description: "Declare durable application volumes, inspect their claims, and snapshot or scratch-restore their contents through GCS or local MinIO."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
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
    resource: cli/nagarectl/test/InventoryVolumeRestorePinSpec.hs
    proves: Snapshot source identity, archive and receipt version pins, isolated restore downloads, and refusal of changed stored bytes are tested.
  - kind: test
    resource: scripts/local-smoke.sh
    proves: The local smoke driver snapshots a mounted sentinel and verifies its restoration into an isolated PVC through MinIO.
  - kind: example
    resource: cluster/examples/uploads-volume/nagare/Config.hs
    proves: A shipped application declares and uses a persistent upload volume.
  - kind: guide
    resource: docs/user/persistent-storage.md
    proves: Declaration, ownership, inspection, snapshot, and restore behavior are documented.
---

# Persistent application volumes and snapshots

Typed `Volume` values render PVCs and mounts alongside an application. In 0.4.0, snapshot commands
save a reviewed, create-only archive and checksum receipt Job against an accepted PVC incarnation.
Restore saves a separate scratch PVC and verification Job, pinning and rechecking the accepted
archive and receipt bytes. Source storage remains intact. Manual pruning requires a separate
expiry-gated review of exact accepted objects and versions, with restore dependencies checked.

Volume attachment builds on [typed application deployment](typed-application-deployment.md) (CAP-6).
Snapshot and restore execution use the [reviewed operation ledger](reviewed-operation-ledger.md)
(CAP-22); PVC identity and retention follow
[resource identity and reviewed lifecycle](resource-identity-and-lifecycle.md) (CAP-23).

## Limits

- Knative PVC concurrency constraints still apply; a volume is not shared multi-writer storage.
- Snapshot consistency is filesystem-level. Nagare does not quiesce arbitrary application writes.
- Live overwrite is unavailable in the 0.4.0 contract; restore uses a new isolated PVC.
- Volumes are outside the scheduled database recovery-point objective and need manual snapshots.
- Scheduled keep-N and expiry retention are unenforced. A saved expiry does not automatically
  delete an archive; eligible manual disposal needs its own review.
- The shipped storage snapshot/restore loader accepts single-Service `Deployment` configs;
  `Application` config support is deferred to the next release.
