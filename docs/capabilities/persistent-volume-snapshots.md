---
title: "Persistent application volumes and snapshots"
type: Capability
description: "Declare durable application volumes, inspect their claims, and snapshot or scratch-restore their contents through GCS or local MinIO."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
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
  - "nagarectl storage backup-receipts|prune-scheduled-backups|recover-scheduled-prune|restore-rebuilt"
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
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/Backup/VolumeSchedule.hs
    proves: A volume schedule archives its claim read-only and uploads a signed version-5 receipt, and its expectation comes only from the accepted CronJob's own app, volume and claim.
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/Backup/Retention.hs
    proves: Retention keeps every point for 48 hours, the newest of each day for 30 days, and the newest point, and admission refuses a prune of any of them.
  - kind: guide
    resource: docs/user/persistent-storage.md
    proves: Declaration, ownership, inspection, snapshot, and restore behavior are documented.
---

# Persistent application volumes and snapshots

Typed `Volume` values render PVCs and mounts alongside an application. Snapshot commands
save a reviewed, create-only archive and checksum receipt Job against an accepted PVC incarnation.
Restore saves a separate scratch PVC and verification Job, pinning and rechecking the accepted
archive and receipt bytes. Source storage remains intact. Manual pruning requires a separate
expiry-gated review of exact accepted objects and versions, with restore dependencies checked.

Since 0.5.0, every backup-included volume also has a scheduled producer
(`nagare-volbackup-<app>-<volume>`) that uploads signed receipts on the database schedule.
`server status` grades each volume's freshness against the context's recovery-point objective.
`storage backup-receipts` ingests runs, `storage restore --scheduled-run` restores an accepted run
into a scratch claim, and `storage prune-scheduled-backups` reviews the removal of runs past the
retention policy, which keeps every run for 48 hours, then one a day for 30 days, and always the
newest verified run. A volume lost from the cluster is recreated by `inventory rebuild` and refilled
with `storage restore-rebuilt` from its predecessor's verified recovery point.

Volume attachment builds on [typed application deployment](typed-application-deployment.md) (CAP-6).
Snapshot and restore execution use the [reviewed operation ledger](reviewed-operation-ledger.md)
(CAP-22); PVC identity and retention follow
[resource identity and reviewed lifecycle](resource-identity-and-lifecycle.md) (CAP-23).

## Limits

- Knative PVC concurrency constraints still apply; a volume is not shared multi-writer storage.
- Snapshot consistency is filesystem-level. Nagare does not quiesce arbitrary application writes.
- Live overwrite is unavailable; restore uses a new isolated PVC or a rebuilt incarnation.
- Retention is applied through a reviewed prune, never by automatic deletion; manual snapshot
  disposal needs its own expiry-gated review.
- The storage snapshot and restore commands load single-Service `Deployment` configs only.
