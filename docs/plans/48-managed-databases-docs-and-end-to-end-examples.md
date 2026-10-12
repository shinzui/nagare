---
id: 48
slug: managed-databases-docs-and-end-to-end-examples
title: "Managed databases docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T14:25:20Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
master_plan: "docs/masterplans/9-managed-databases-for-nagare.md"
---

# Managed databases docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the sixth and final child of the MasterPlan at
`docs/masterplans/9-managed-databases-for-nagare.md` ("Managed Databases for Nagare"). The
managed-database *behavior* is built by its sibling plans: the substrate feasibility spike
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`), the typed
`Database` model and the StatefulSet/Service/PVC/Secret renderer
(`docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md`),
the `nagarectl db` lifecycle commands and deploy-time provisioning
(`docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md`), the app→database
connection-env injection (`docs/plans/46-generated-database-connection-env-injection-for-apps.md`),
and the scheduled backups, restore commands, and retention
(`docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md`). This plan makes that
behavior **discoverable and learnable**: it writes the user guide, cross-links it from the docs index
and the backup guide, and ships three runnable, deployable end-to-end examples — one per engine — that
prove the whole pipeline (declare → provision → connect an app → back up) works.

This plan **hard-depends** on EP-45 (the `db` CLI), EP-46 (app env injection), and EP-47 (backups and
restore), because a docs plan must describe commands and behaviors that actually exist: the
`nagarectl db list|create|get|shell|restart|delete` group (EP-45), the per-engine connection env an app
receives when it references a database (EP-46), and `nagarectl db backup|restore` with the GCS layout
and the restore drill (EP-47) must already be shipped. It **soft-depends** on EP-44 (the typed
`Database` model) so the guide can document the `Database` fields and the app `databases` reference
accurately; if EP-44's final field, constructor, or accessor names differ from what this plan assumes,
reconcile against EP-44's final Interfaces section before writing the Haskell snippets, and record any
divergence in this plan's Decision Log. The contract this plan relies on is fixed by the MasterPlan's
Integration Points IP1–IP6 (`docs/masterplans/9-managed-databases-for-nagare.md`), which are reproduced
where needed below so this plan is self-contained.

Full plan before trimming: [48-managed-databases-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/48-managed-databases-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare workload is stateless-by-default at the platform level: a developer writes a typed
`nagare/Config.hs` that produces an app `Deployment`, runs `nagarectl deploy`, and gets a Knative
Service whose container filesystem is wiped on every pod restart or scale-to-zero. MasterPlan 7 added
durable disks (typed `Volume` → `local-path` PVC), and the Managed Databases initiative builds on that
to add a first-class *database*: a typed `Database` value renders a long-lived StatefulSet with a stable
in-cluster DNS name, durable storage, and generated credentials, operated through a `nagarectl db`
command group, with scheduled and on-demand backups to GCS and a tested restore path. But a capability
nobody can find is a capability that does not exist. This plan is what turns the shipped machinery into
something a developer can use without reading Haskell source or the plan files.

After this plan, a developer can open a single new page,
[`docs/user/managed-databases.md`](../user/managed-databases.md), and learn the whole story:

- what a *managed database* is on this single-node cluster (a StatefulSet, not a scale-to-zero Knative
  Service; a ClusterIP Service for stable internal DNS; a PVC for its data; a managed Secret for its
  generated password);
- how to declare a `Database` in a typed `nagare/Config.hs` — choosing one of the three engines
  (`Postgres`, `Redis`, `ClickHouse`), pinning a version, requesting a disk size and resource limits,
  and setting a retention policy;
- how to operate it with `nagarectl db list|create|get|shell|restart|delete`;
- how to connect an app to it by name (the `databases` reference field) and which connection
  environment variables the app receives per engine (`DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` and
  their components, password values delivered as Kubernetes Secret references, never inline);
- how backups work (`nagarectl db backup`, the scheduled per-database CronJob, the GCS layout, and
  keep-last-N retention) and how to restore one (`nagarectl db restore`), plus a restore drill;
- and the constraints a reader must know: every database is a **single replica on a single node** (no
  high availability, no replication — the constraint the whole PaaS accepts), ClickHouse needs explicit
  **memory limits** to be viable on the small `e2-standard-2` VM, and databases are **ClusterIP-only**
  (reachable in-cluster, never exposed to the public internet).

The proof that the documentation is correct is **three runnable end-to-end examples** under
`cluster/examples/`, one per engine, each with a `nagare/Config.hs` and a `README.md`:

1. **`postgres-app`** — a managed Postgres `Database` plus an app `Deployment` that references it,
   demonstrating `DATABASE_URL` consumption: the app reads `DATABASE_URL` (injected from the managed
   Secret), connects, creates a row, and survives a database pod restart.
2. **`redis-cache`** — a managed Redis `Database` plus an app that uses `REDIS_URL` as a cache,
   demonstrating the Redis connection-env injection and a key surviving an app roll.
3. **`clickhouse-analytics`** — a managed ClickHouse `Database` plus an app that uses `CLICKHOUSE_URL`
   to write and query analytics rows, with the explicit memory-limit note for the `e2-standard-2`.

You can see this working by following each example README top to bottom against a live cluster: every
command runs and produces the shown output, data survives a restart, and a backup lands in GCS. Where no
cluster is reachable in the implementation environment — the common case, because `nagare-01` is often
TERMINATED and IAP forwards only SSH/22 so a workstation `kubectl`/`nagarectl` cannot reach the k3s API
(MasterPlan 7's cluster-access reality) — the examples are still verifiable offline via
`nagarectl db create ... --dry-run` and `nagarectl deploy --dry-run` (which render the
StatefulSet/Service/PVC/Secret and the injected connection-env YAML without touching a cluster), and the
live legs are marked "dry-run verified; live run deferred" with exact on-VM instructions, exactly as the
sibling docs plan `docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md` did.

Terms used throughout this plan, defined once here in plain language:

- A **managed database** is a long-lived database process Nagare runs for you. In typed config it is a
  `Database` value (engine, version, namespace, size, resources, retention). It is not an app `Deployment`
  and is not a Knative Service; it is provisioned and operated through the `nagarectl db` command group.
- A **StatefulSet** is the Kubernetes controller for a workload that needs a stable identity and durable
  per-instance storage. Unlike a Knative Service it does not scale to zero and keeps the same pod name and
  PVC across restarts. It is the substrate Nagare uses for a single-replica database.
- A **ClusterIP Service** is the in-cluster DNS name other pods use to reach the database — for example
  `pg-main.personal.svc.cluster.local`. It is internal only; databases are never exposed to the public
  internet.
- A **managed credential Secret** is the Kubernetes Secret, named `nagare-db-<name>`, that holds the
  database's generated password and composed connection URL. The password is generated once by
  `nagarectl db create` (the typed DSL is pure and cannot generate randomness) and lives only in the
  Secret. Apps read it by reference, never by copying the value.
- A **connection environment variable** is a variable an app receives at deploy time when it references a
  database — for example `DATABASE_URL` for Postgres. Variables that embed the password (the composed
  URLs and any `*_PASSWORD`) are injected as Secret references; the rest (host, port, user, db name) are
  plain literals.
- A **retention policy** says what happens to the database's underlying disk and resources when the
  database is deleted: `Retain` (keep the PVC and its data) or `Delete` (destroy it). This is independent
  of GCS backups.
- A **backup** here is an engine-appropriate logical dump (`pg_dump` for Postgres, an RDB save for Redis,
  a native/`clickhouse-backup` dump for ClickHouse), gzipped and uploaded to the GCS backup bucket. It is
  not a block snapshot.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-10): `docs/user/managed-databases.md` written (concepts → typed `Database` config →
  `nagarectl db` lifecycle → connecting an app + per-engine connection-env table → backups/restore +
  restore drill → single-node/ClickHouse-memory/ClusterIP constraints), reconciled against the shipped
  surface (modern versions 18/8/25.8; ClickHouse connection port 9000; the real IP5 env table; the
  GCS-routing blocker). Linked from `docs/user/README.md` (index sub-bullet + status row),
  `docs/user/deploying-apps.md` (data-tier section), and cross-linked with
  `docs/user/backups-and-disaster-recovery.md`. Every opening fence tagged.
- [x] M2 (2026-06-10): Three example directories created — `postgres-app`, `redis-cache`,
  `clickhouse-analytics` — each with `nagare/Database.hs` (typed `Database`), `nagare/Config.hs` (app
  `Deployment` referencing the db), `app.py`, `Dockerfile`, and `README.md`. All `Database.hs`/`Config.hs`
  emit valid JSON via `runghc`; `db create <engine> <name> --dry-run` renders the
  StatefulSet/Service/PVC/Secret/CronJob (the ClickHouse one with the `2Gi` limit + dual ports + memory
  ConfigMap). READMEs complete.
- [x] M3 (2026-06-10): Live end-to-end + restore drill **deferred-with-instructions** (per the EP-37
  precedent): the exact on-VM commands are in the user guide and each example README, with the explicit
  note that the live **backup** leg is additionally blocked by the EP-43 in-pod-ADC routing regression
  until the node route is fixed. Offline `db create --dry-run` renders (mandatory) all pass.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Engine versions are the modern majors, not the plan's drafts.** The plan's snippets named
  `16`/`7`/`24.3`; the shipped defaults (per user direction + EP-43 verification) are Postgres **18**,
  Redis **8**, ClickHouse **25.8** (LTS). The guide and all three examples use the modern tags.

- **ClickHouse connection port is 9000 (native), not 8123.** EP-46 injects `CLICKHOUSE_PORT=9000` (the
  `clickhouse://` URL uses the native protocol); the Service also exposes 8123 (HTTP). The example app
  uses `clickhouse-driver` on 9000 to match the injected env.

- **`db backup`/`deploy --dry-run` for a db-referencing app need a reachable cluster** to resolve the
  engine/identity, so a fully-offline `deploy --dry-run` of an app that references a database errors
  cleanly rather than rendering. The offline proof is `db create --dry-run` (engine is an argument) and
  the pure renderers' unit tests; documented in the READMEs.

- **The live leg is not just deferred — the backup upload is blocked.** EP-43's flannel/metadata routing
  regression means in-pod GCS auth fails cluster-wide, so the live `db backup` upload will not work until
  the node route is fixed. The guide and READMEs say so plainly rather than implying a working live
  backup. `db create`/`deploy`/`db restart` are unaffected.

## Decision Log

Record every decision made while working on the plan.

- Decision: Put the managed-database user documentation in a new dedicated page
  `docs/user/managed-databases.md`, mirroring the other per-feature guides
  (`docs/user/persistent-storage.md`, `docs/user/static-hosting.md`, `docs/user/env-and-secrets.md`),
  rather than expanding `docs/user/deploying-apps.md` in place.
  Rationale: managed databases are a focused, sizeable sub-topic (concepts + a typed `Database` field
  group + a six-verb CLI + a per-engine connection-env contract + a backup/restore policy + several hard
  constraints). Every sibling per-feature initiative finished with its own page linked from
  `deploying-apps.md` and the README index; following that convention keeps the docs navigable. This is
  the same decision EP-37 made for persistent storage.
  Date: 2026-06-10

- Decision: Ship exactly three end-to-end examples, one per engine —
  `cluster/examples/postgres-app/` (Postgres-backed app consuming `DATABASE_URL`),
  `cluster/examples/redis-cache/` (Redis cache consuming `REDIS_URL`), and
  `cluster/examples/clickhouse-analytics/` (ClickHouse analytics store consuming `CLICKHOUSE_URL`).
  Rationale: the MasterPlan's Vision & Scope names "three working end-to-end examples (one per engine)"
  as the deliverable for this plan. One example per engine is the minimum that exercises every engine's
  distinct image, port, credential shape, connection-URL format, and (for ClickHouse) memory-limit
  concern, while sharing the same provision → reference → deploy → back up pipeline so the three
  READMEs reinforce one mental model.
  Date: 2026-06-10

- Decision: Place each example as a directory carrying *both* a `Database` `nagare/Config.hs` and an app
  `Deployment` (with a tiny dependency-free stdlib app where source is needed), deployed/provisioned via
  `nagarectl db create` + `nagarectl deploy`, not raw `kubectl apply` manifests.
  Rationale: the whole point is to prove the typed pipeline — typed `Database` → rendered
  StatefulSet/Service/PVC/Secret → generated credentials → app `databases` reference → injected
  connection env → backup — which raw YAML cannot demonstrate. This matches how every other
  `cluster/examples/*` project teaches a feature through a runnable typed config, and how EP-37's
  `sqlite-pvc-litestream` and `uploads-volume` examples are structured (a `nagare/Config.hs`, a `README.md`,
  and a small `app.py`/`Dockerfile`).
  Date: 2026-06-10

- Decision: Treat the live end-to-end and restore-drill legs (M3) as deferrable-with-instructions,
  exactly as EP-37 did, while mandatory offline `--dry-run` renders prove the examples and the docs.
  Rationale: `nagare-01` is often TERMINATED, and IAP forwards only SSH/22 so a workstation
  `kubectl`/`gsutil`/`nagarectl` cannot reach the k3s API or run in-cluster Jobs; the workstation's
  default kubectl context is an unrelated GKE cluster that must not be used (MasterPlan 7 / repo memory).
  The honest, reproducible posture is: dry-run everything offline now, and write the exact on-VM commands
  (start the VM, `scripts/iap-ssh.sh` as the deploy user, run `nagarectl`/`kubectl` on the VM or
  SSH-forward 6443) so the live leg can be completed when the VM is up.
  Date: 2026-06-10

- Decision: Document — do not define — every surface owned by the sibling plans. This plan adds no
  library code; the `Database` type and fields (EP-44), the `db` subcommands (EP-45), the connection-env
  contract (EP-46), and the backup/restore commands and GCS layout (EP-47) are read from their shipped
  state and from MasterPlan 9's IP1–IP6, and the docs/examples must match what was actually shipped.
  Rationale: this is the docs/examples plan; its only "interface" obligation is accuracy. Because the
  sibling plans may be fleshed out after this plan is written, the implementer must verify the real
  surfaces (run the real `--help` and `--dry-run`) before finalizing snippets and transcripts, and record
  any divergence here.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-48 is complete. `docs/user/managed-databases.md` documents the whole story (concepts, typed
`Database` config, the `nagarectl db` lifecycle, connecting an app with the per-engine connection-env
table, backups/restore + drill, and the hard constraints), reconciled against the shipped surface and
cross-linked from the docs index, the deploy guide, and the backups guide. Three runnable examples
(`postgres-app`, `redis-cache`, `clickhouse-analytics`) each carry a typed `Database`, an app that
references it, a minimal app + Dockerfile, and a README; all configs emit valid JSON and render via
`db create --dry-run` (the ClickHouse one with its memory limit and dual ports).

Against the purpose: the managed-database capability is now discoverable and learnable without reading
Haskell or the plans. Gaps, honestly flagged: the live end-to-end + restore drill is
deferred-with-instructions and the live **backup upload** is blocked by the EP-43 cluster routing
regression until the node route is fixed; the example apps' Dockerfiles/`app.py` are written but not
live-built. The dry-run renders (the mandatory offline acceptance) all pass.

