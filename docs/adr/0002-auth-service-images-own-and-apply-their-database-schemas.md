---
title: "Auth-service images own and apply their database schemas"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md
  - "mori://shinzui/en — docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md"
  - mori://shinzui/pg-migrate
---

# ADR 2 — Auth-service images own and apply their database schemas

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 104](../plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md).

## Context

Nagare formerly carried a hand-copied En schema in a Kubernetes ConfigMap and applied
it with `psql`. Shomei and En have since made their schemas embedded pg-migrate
components (`mori://shinzui/shomei/packages/shomei-migrations` and
`mori://shinzui/en/packages/en-migrations`). A copied SQL bundle gives Nagare a second,
drift-prone description of another service's schema and cannot provide the checksum
ledger or append-only identity guarantees of the owning migration plan.

A migration executable and its server must also agree on source revision. Applying a
tool from one release before starting a server from another makes schema compatibility
implicit and difficult to audit.

## Decision

Each auth service owns its schema exclusively. Nagare builds that service's migration
executable and server into the same image, then runs an explicit Kubernetes Job from the
same immutable image tag before rolling out the workload:

- `shomei-migrate up` owns and applies Shomei's plan.
- `en-migrate up` owns and applies En's plan.

Installers delete the previous completed Job before applying the new template because Job
pod templates are immutable and completed Jobs do not rerun. pg-migrate's advisory lock,
append-only plan, checksums, and database ledger make this delete-and-recreate deployment
step safe and idempotent. Nagare never copies, edits, or hand-applies either service's SQL.

## Consequences

Migration logs, completion, and image provenance are observable deployment evidence, and
integration tests and real deployments use the same schema definitions. A failed migration
blocks the server rollout instead of surfacing later as an application error.

Applied migrations and their component/name identities are durable. They must not be
renamed or edited; corrections are new appended migrations. Recreating a database is valid
only when its data is explicitly disposable. A database with retained data requires the
owner's supported forward migration or history-import procedure.
