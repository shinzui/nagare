---
title: "The intranet stays single-node with hourly recovery points and a four-hour rebuild"
status: accepted
date: 2026-10-10
authors: [shinzui]
related:
  - docs/use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md
  - docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md
  - docs/plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md
  - docs/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md
  - docs/adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md
  - docs/adr/0014-the-active-context-owns-the-vm-shape.md
  - docs/adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md
---

# ADR 28 — The intranet stays single-node with hourly recovery points and a four-hour rebuild

## Status

Accepted on 2026-10-10. The operator stated the objectives below on 2026-10-09 in answer to
EP-162's questions ([UC-3](../use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md)): an
hourly recovery point, the proposed retention, and a four-hour recovery time. The operator chose
the four-hour objective over a one-hour objective that would have needed a warm standby.

## Context

Nagare runs on one Compute Engine VM in one zone. It runs NixOS and k3s, and its data is on one
persistent disk ([ADR 12](0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md),
[ADR 14](0014-the-active-context-owns-the-vm-shape.md)). Managed databases are single-replica
StatefulSets, and the Redpanda broker is a single node. Scheduled database backups are uploaded
every 15 minutes under the `hourly` objective. They go to a regional GCS bucket with public access
prevention enforced (`infra/pulumi/src/components/NagarePerimeter.ts`), and their signing keys are
escrowed. v0.4.0 proved that data survives the destruction of the cluster
([checklist](../releases/production-readiness-checklist.md), section 2). It did not prove that the
same installation can be brought back into service.

The workplace intranet holds personal data and is run by one operator, who accepts up to four hours
of downtime after the VM is lost.

## Decision

1. **Single node remains the supported shape for the intranet.** Nagare does not add a second
   node, replicated databases, or a managed database for it. A VM, disk or zone failure is an
   outage, recovered by rebuilding from backups.
2. **Recovery point objective: one hour** for every authoritative store, using the existing
   `hourly` preset. This covers the managed databases and the backup-included application volumes
   (EP-183 M3). `nagarectl server status` grades it, warns before a breach, and reports a breach as
   unhealthy.
3. **Recovery time objective: four hours.** The clock starts when the operator begins the rebuild
   and stops when the service answers with its data. Detection time is not counted; the operator
   watches `server status` and the VM.
4. **Retention.** Keep every scheduled recovery point for 48 hours, the newest point of each day
   for 30 days, and always the newest verified point. Retention is a target that `server status`
   grades plus a reviewed prune. Nothing deletes backups in the background (EP-183 M2).
5. **Restore is tested by drills, not assumed.** The four-hour objective counts as met only after a
   timed drill that deletes the VM and rebuilds the installation with its data (EP-183 M5, native
   run N2). The drill is repeated for any release that changes a backup, receipt or rebuild format.
6. **Backups stay in the installation's region.** The regional bucket survives the loss of the
   VM's zone, but not of the region. Surviving a region loss is not an objective.

## Consequences

- An intranet outage can last up to four hours, and up to one hour of writes can be lost. Users of
  the intranet should be told this.
- No availability implementation stream is needed in MasterPlan 24 (its stream 5). It reopens only
  if the operator tightens the recovery time objective or asks for zero data loss.
- EP-183's milestones carry these objectives: retention (M2), volumes (M3), rebuild (M4) and the
  timed drill (M5).
- Managed databases and the broker stay non-HA. Their capability pages cite this ADR.

## Amendment (2026-10-10, EP-183 M2): how the retention policy is bound

- **The release fixes the policy.** `Nagare.Inventory.BackupRetention.standardRetention` is the one
  policy, as MasterPlan 23's decision D6 fixed the two objective presets. No context or environment
  value selects another. The signed schedule metadata is unchanged: its `keep` field is the legacy
  keep-last-N of unadmitted CronJobs, and no reviewed schedule uses it. Not adding a field means no
  accepted CronJob changes bytes, so the upgrade rewrites no schedule. A second preset, if one is
  ever needed, goes into the signed metadata the way `recoveryPoint` did: written only when it is
  not the default, so existing bytes stay the same.
- **Only signed times count.** The policy reads the recovery point that a v5 receipt signed and
  ingestion recorded (`scheduled.backup.recovery.point`). A run accepted without one, a v4
  receipt, is kept and never selected.
- **Admission re-evaluates the policy.** A reviewed prune records its policy text
  (`scheduled.prune.policy.retention`). Admission refuses unless every pruned run is past policy at
  admission time against the accepted receipts. The check uses the widest objective's breach window,
  so the newest point, any point inside the 48-hour or breach window, and each retained day's newest
  point can never be removed.
- **Cloud pruning waits.** The reviewed prune is local (MinIO) only. Receipt recovery after a
  partial cloud prune needs GCS exact-generation listing, which does not exist yet. In a cloud
  context, `server status` grades retention, but runs past policy stay in place until that
  recovery exists.
