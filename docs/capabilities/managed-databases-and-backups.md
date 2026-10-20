---
title: "Managed databases and backups"
type: Capability
description: "Create and operate single-replica Postgres, Redis, or ClickHouse services, inject typed connection values, and back up or restore them through object storage."
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
capabilityId: CAP-12
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Database"
  - "nagarectl db list|create|get|restart|delete|backup|backup-receipt|backup-receipts|restore"
  - "nagarectl db prune-scheduled-backups|recover-scheduled-prune|restore-rebuilt"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Database types, StatefulSet, Service, PVC, ConfigMap, and connection-secret rendering are tested for the supported engines.
  - kind: test
    resource: cli/nagarectl/test/InventoryApplicationSpec.hs
    proves: Complete database members compile into reviewed scopes with accepted namespace and dependency bindings.
  - kind: test
    resource: cli/nagarectl/test/InventoryIncarnationSpec.hs
    proves: Manual backups, restores, and receipt ingestion require the recorded source or target incarnation.
  - kind: test
    resource: cli/nagarectl/test/InventoryDatabaseEngineSpec.hs
    proves: In-place PostgreSQL major-version and database engine changes refuse while compatible updates remain allowed.
  - kind: test
    resource: cli/nagarectl/test/InventoryRecoveryPointScanSpec.hs
    proves: Recovery-point selection uses the newest verified backup, skips unverified uploads, and refuses to report an unverified recovery point.
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/Backup/Retention.hs
    proves: Scheduled prune selects only accepted runs past the retention policy, and admission refuses a prune of the newest, a recent, a day's newest, or an unsigned run.
  - kind: example
    resource: cluster/examples/postgres-app/nagare/Database.hs
    proves: A Postgres definition can be loaded beside a consuming application.
  - kind: example
    resource: cluster/examples/clickhouse-analytics/nagare/Config.hs
    proves: A shipped application consumes generated ClickHouse connection settings.
  - kind: guide
    resource: docs/user/managed-databases.md
    proves: Engine selection, lifecycle, app binding, backups, and restore behavior are documented.
---

# Managed databases and backups

Nagare renders a database as a single-replica StatefulSet with a Service, persistent storage,
configuration, and generated credentials. Applications refer to a database by name and receive the
engine-specific host, port, user, and URL values. Lifecycle and data changes use the
[reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22). Deletion retires a database and
retains its members; backup and isolated restore require saved reviews.

Manual and scheduled backups have verified receipts bound to exact stored bytes and source
identities. Cloud scheduled backups are signed, with signing keys escrowed in operator material.
Freshness is graded against the accepted hourly or daily recovery-point objective; verified pending
uploads can count toward freshness, while reviewed acceptance grants restore authority. Restores
preserve the source. PostgreSQL major upgrades use the documented side-by-side procedure rather
than changing an accepted StatefulSet's major version in place.

Since 0.5.0, `db backup-receipts --all` ingests every verified scheduled run in one review, and
`db prune-scheduled-backups` reviews the removal of runs past the retention policy (every run for
48 hours, then one a day for 30 days, and always the newest verified run); a stopped prune has one
reviewed recovery. A database lost from the cluster is recreated by `inventory rebuild` and refilled
with `db restore-rebuilt` from its predecessor's verified recovery point. Many apps can share one
PostgreSQL or ClickHouse server through
[app databases on shared servers](app-databases-on-shared-servers.md) (CAP-26).

## Limits

- These databases are explicitly non-HA and single-replica. They are not suitable for workloads
  requiring managed failover. For the workplace intranet this is a decision, not a gap:
  [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
  keeps one node and commits to a one-hour recovery point and a four-hour rebuild instead.
- Nagare owns workload-level backup Jobs, not physical-volume snapshots or point-in-time recovery.
- Live overwrite of an accepted database and interactive mutating maintenance sessions are not
  offered; already admitted historical operations retain their evidence-bound recovery paths.
- Retention is applied through a reviewed prune, never by automatic deletion. Manual backup
  disposal requires a separate review of exact accepted receipts, stored versions, and dependencies.
- The ledger contains backup authority and evidence, not database contents. Preserve off-cluster
  archives, receipts, and escrowed credentials; see the
  [backup and recovery guide](../user/backups-and-disaster-recovery.md).
- Release acceptance, first recorded in the [0.4.0 evidence](../releases/v0.4.0.md#ir-24-acceptance-evidence),
  does not establish every engine/configuration combination or automatic live-service cutover.
