---
title: "Managed databases and backups"
type: Capability
description: "Create and operate single-replica Postgres, Redis, or ClickHouse services, inject typed connection values, and back up or restore them through object storage."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-12
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Database"
  - "nagarectl db list|create|get|shell|restart|delete|backup|restore"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Database types, StatefulSet, Service, PVC, ConfigMap, and connection-secret rendering are tested for the supported engines.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Discovery, creation, connections, deletion, backup schedules, retention, and scratch/live restore Jobs are tested.
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
engine-specific host, port, user, and URL values. CLI operations cover lifecycle, shells, scheduled
or on-demand backups, retention, and scratch-first restoration through GCS or MinIO.

## Limits

- These databases are explicitly non-HA and single-replica. They are suitable for a personal PaaS,
  not for workloads requiring managed failover.
- Nagare owns workload-level backup Jobs, not physical-volume snapshots or point-in-time recovery.
- Restore defaults to a scratch database; an in-place restore requires an explicit opt-in.
- Rendering and data movement are extensively tested, but no live matrix exercises every engine on
  every target in CI.
