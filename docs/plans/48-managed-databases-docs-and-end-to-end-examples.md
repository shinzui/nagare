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


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. This plan writes
and edits **Markdown** under `docs/user/` and adds three example directories (each a `nagare/Config.hs`,
a `README.md`, and a small amount of supporting source) under `cluster/examples/`. It contains **no
library code**; it consumes the behavior the sibling plans ship.

**The user docs directory — `docs/user/`.** It is the developer- and operator-facing guide. The pages
relevant here are `README.md` (the index), `deploying-apps.md` (the first-deploy on-ramp for app
developers, which links the per-feature guides), `persistent-storage.md` (the direct structural
precedent — concepts → typed config → CLI verbs → backup policy → restore pointer → worked examples),
and `backups-and-disaster-recovery.md` (what to back up and the rebuild-from-zero runbook, which EP-47
extends with a database-backup row and which this plan cross-links). The house style, visible at the top
of `persistent-storage.md`, `deploying-apps.md`, and `static-hosting.md`:

- An H1 title (`# Managed databases`).
- A `>` status box using one of the badges from `docs/user/README.md`'s "Status legend": ✅ Working,
  🟡 In progress, or 🔭 Planned, with plain-English caveats. Because the live legs may be deferred, use
  🟡 with the honest caveat "Built and dry-run-verified; live end-to-end run pending until `nagare-01` is
  back up," matching the persistent-storage page.
- An intro paragraph naming the audience ("for **app developers** who need a database for their app")
  and the promise.
- A fenced block showing "the smallest thing that works," then progressive detail.
- `>` callout blocks linking to related pages and rationale.

Formatting rules this plan must obey (per `.claude/skills/exec-plan/PLANS.md` and the existing docs):
two newlines after every heading, and **every fenced code block carries a language tag** — `haskell`,
`bash`, `text`, `yaml`, or `markdown` — never a bare ```` ``` ````.

**What the sibling plans deliver — the source of truth for what to document.** Because EP-44/45/46/47 may
not be fully fleshed out when this plan is written, the binding contract is MasterPlan 9's Integration
Points (`docs/masterplans/9-managed-databases-for-nagare.md`, IP1–IP6), reproduced here so this plan is
self-contained. **The implementer must reconcile every name below against the shipped surfaces** (run the
real `nagarectl db --help` and `--dry-run`, read EP-44's final Interfaces section) and record any
divergence in the Decision Log.

- **The typed `Database` model (IP1, owned by EP-44).** A validated record lives in a new module
  `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` (or an extension of `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`),
  loadable as a new config *kind* alongside the existing `Deployment`/`StaticSite`/`ServerSite`
  discriminator. Its shape, exactly as the MasterPlan specifies:

  ```haskell
  -- | A managed database. All fields are validated by smart constructors; the
  -- data constructor is not exported, so an illegal Database cannot be built
  -- (mirrors mkServiceName / mkQuantity / Volume in Nagare.Dsl.Types).
  data Engine = Postgres | Redis | ClickHouse
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

  data Database = Database
    { dbName    :: !DatabaseName      -- ^ DNS-label name, unique within the namespace
    , engine    :: !Engine            -- ^ Postgres | Redis | ClickHouse
    , version   :: !EngineVersion     -- ^ pinned image tag, validated per engine
    , namespace :: !Namespace         -- ^ reuses the existing Namespace newtype (default "personal")
    , size      :: !Quantity          -- ^ data volume size, reuses Quantity ("10Gi")
    , resources :: !(Maybe Resources) -- ^ reuses the existing Resources record
    , retention :: !RetentionPolicy   -- ^ reuses MasterPlan 7's Retain | Delete
    }
    deriving stock (Generic, Eq, Show)
  ```

  The default namespace is `personal` (confirmed in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, which
  defines `defaultNamespace = "personal"`). Smart constructors validate each field. EP-44 also adds the
  app→database reference field `databases :: [DatabaseName]` to the app `Deployment` record in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, defaulting to `[]` so every existing config compiles
  unchanged. When writing the config snippets, prefer any preset/overlay helper EP-44 ships (mirroring
  how `attachVolume` overlays a `Volume`, which EP-37's examples use); otherwise fall back to a record
  literal or record update, the pattern `cluster/examples/env-and-secrets/nagare/Config.hs` uses
  (the loader runs configs with `runghc -XGHC2024`, which does not enable `OverloadedLabels`).

- **The rendered stateful resource shapes (IP2, verified by EP-43, produced by EP-44).** Each `Database`
  renders (a) a **StatefulSet** running the engine's official image at the pinned version, one replica,
  the data PVC mounted at the engine's data path (`/var/lib/postgresql/data` for Postgres, `/data` for
  Redis, `/var/lib/clickhouse` for ClickHouse), resource limits, and the credential env wired from the
  managed Secret; (b) a **ClusterIP Service** giving stable in-cluster DNS
  (`<name>.<namespace>.svc.cluster.local`); (c) a **PVC** with `storageClassName: local-path` and
  `accessModes: [ReadWriteOnce]` reusing the MasterPlan 7 size/quantity convention; and (d) the
  **managed credential Secret** structure. This is what `nagarectl db create ... --dry-run` prints — the
  offline proof a reader can run without a cluster.

- **The managed credential Secret (IP3).** Named deterministically `nagare-db-<name>`; labelled
  `nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`, and `nagare.dev/engine: <engine>`;
  its keys are engine-specific but fixed — Postgres `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB`,
  and a composed `DATABASE_URL`; Redis `REDIS_PASSWORD` and `REDIS_URL`; ClickHouse `CLICKHOUSE_PASSWORD`,
  `CLICKHOUSE_USER`, and `CLICKHOUSE_URL`. The password is generated once by `nagarectl db create` and
  never stored in `Config.hs`.

- **The `nagarectl db` command group (IP4, owned by EP-45; extended by EP-47).**

  ```text
  nagarectl db list
  nagarectl db create ENGINE NAME
  nagarectl db get NAME
  nagarectl db shell NAME
  nagarectl db restart NAME
  nagarectl db delete NAME
  nagarectl db backup NAME            # EP-47
  nagarectl db restore NAME BACKUP_ID # EP-47
  ```

  `db create` generates the credential Secret and provisions the rendered resources in order
  (Secret + PVC before the StatefulSet, then wait for ready); `db delete` honors the `RetentionPolicy`.

- **The app→database connection-env contract (IP5, owned by EP-46).** An app declares
  `databases :: [DatabaseName]` (a list of database names it uses). At deploy time `nagarectl deploy`
  resolves each referenced database to its stable in-cluster DNS name and its managed Secret, and merges
  connection variables into the app's runtime env via the existing
  `cli/nagarectl/src/Nagare/Env/Generated.hs` / `mergeGenerated` mechanism. Per engine, the variables
  that are **plain literals** (injected inline) versus **Secret references** (`valueFrom.secretKeyRef`
  into the IP3 Secret):

  ```text
  Postgres:   POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_DB   (literals)
              POSTGRES_PASSWORD, DATABASE_URL                            (secret refs)
  Redis:      REDIS_HOST, REDIS_PORT                                     (literals)
              REDIS_PASSWORD, REDIS_URL                                  (secret refs)
  ClickHouse: CLICKHOUSE_HOST, CLICKHOUSE_PORT, CLICKHOUSE_USER          (literals)
              CLICKHOUSE_PASSWORD, CLICKHOUSE_URL                        (secret refs)
  ```

  The DB DNS host is `<name>.<namespace>.svc.cluster.local` (ClusterIP, never public). **Reconcile the
  exact variable names and the literal-vs-secret split against EP-46's shipped injection** before writing
  the per-engine table; this is the single most important table in the guide.

- **The backup GCS layout and retention (IP6, owned by EP-47).** `nagarectl db backup NAME` writes an
  engine-appropriate logical dump to `gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>`
  (the same bucket the Litestream example, `scripts/backup-postgres.sh`, and MasterPlan 7's volume
  snapshots use), with keep-last-N retention reusing the pure `snapshotsToPrune` helper from
  `cli/nagarectl/src/Nagare/Storage/Snapshot.hs`. A scheduled per-database CronJob writes to the same
  path. `nagarectl db restore NAME BACKUP_ID` restores a chosen backup (scratch-first where feasible).
  EP-47 updates `docs/runbooks/disaster-recovery.md` and `docs/user/backups-and-disaster-recovery.md`;
  this plan cross-links them.

**The existing examples layout — `cluster/examples/`.** Existing projects show the structure: a
`nagare/Config.hs` plus a `README.md`, and any source the app needs. EP-37's `sqlite-pvc-litestream/`
carries `nagare/Config.hs`, `app.py`, `Dockerfile`, `litestream.yml`, and `README.md`; that is the
shape to mirror. The `Config.hs` for an app that references a database will produce a `Deployment`
(via `webService` plus the `databases` reference); a separate `Config.hs` for the `Database` itself
produces a `Database` value (emitted by EP-44's emit function, the database analogue of
`emitDeployment`). Verify whether EP-44 emits a `Database` via a function like `emitDatabase` and whether
`nagarectl db create` accepts a `-f <config>` form or generates the resource from `ENGINE NAME` flags —
**this is a reconciliation point**; document whichever EP-44/EP-45 shipped.

**The GCP isolation rule.** Every cloud resource and read targets the `tan-nb-exp` project, region
`us-west1`, zone `us-west1-a` (repo `CLAUDE.md`). The backup bucket is `tan-nb-exp-nagare-backups`. All
examples and every `gsutil`/`nagarectl` command in the docs target only that project.

**The cluster-access reality (MasterPlan 7, repo memory).** The VM `nagare-01` is often TERMINATED —
start it first. Reach it via `scripts/iap-ssh.sh` as the deploy user (its `~/.ssh/id_ed25519`). IAP
forwards only SSH/22, so a workstation `kubectl`/`gsutil`/`nagarectl` cannot reach the k3s API — run them
*on the VM*, or SSH-forward port 6443. The workstation's default kubectl context is an unrelated GKE
cluster; do not use it. This is why M3's live leg may be deferred-with-instructions.


## Plan of Work

The work is three milestones: write the docs (M1), then build-and-verify each example offline (M2), then
run the live end-to-end + restore drill or defer it with exact instructions (M3). Each milestone ends
with an observable acceptance a reader can reproduce.

Before writing any snippet or transcript, the implementer reconciles the documented surfaces against what
the sibling plans actually shipped. Run, from the repository root, the real CLI help and a dry-run for
each engine, and read EP-44's final Interfaces section:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nagarectl db --help
nagarectl db create --help
nagarectl db backup --help
nagarectl db restore --help
# (or the cabal form from a source checkout, see Concrete Steps)
```

Update the field names, command flags, connection-env variable names, and the literal-vs-secret split in
the guide and the examples to match the real output, and note any divergence from MasterPlan 9's IP1–IP6
in the Decision Log.

### Milestone 1 — The managed-databases guide and cross-links

Scope: create `docs/user/managed-databases.md`, index it in `docs/user/README.md`, link it from
`docs/user/deploying-apps.md`, and cross-link `docs/user/backups-and-disaster-recovery.md`. At the end of
this milestone the conceptual and reference documentation is complete and internally consistent; the
examples it references are added in M2/M3.

Create **`docs/user/managed-databases.md`** in the house style, with these sections in order:

1. **Title + status box + intro.** H1 `# Managed databases`, a `>` status box (🟡 In progress, honest
   caveat "Built and dry-run-verified; live end-to-end run pending until `nagare-01` is back up"). One
   paragraph naming the audience ("for **app developers** whose app needs a database — Postgres, Redis,
   or ClickHouse") and the promise (declare a database in typed config; Nagare provisions a durable,
   single-replica database with generated credentials, wires it into your app by name, and backs it up).

2. **Concepts.** Define, in prose, *managed database*, *StatefulSet* (long-lived, stable identity, does
   not scale to zero — unlike a Knative Service), *ClusterIP Service* and the in-cluster DNS name
   `<name>.<namespace>.svc.cluster.local`, the data *PVC* (`local-path`, `ReadWriteOnce`, single-node),
   the *managed credential Secret* `nagare-db-<name>` (generated password, never in `Config.hs`), and
   *retention* (`Retain` vs `Delete` on database deletion, independent of GCS backups). Reuse the wording
   from this plan's "Terms" list. Add a `>` callout stating the three hard constraints up front:
   **single replica on a single node** (no HA/replication — the constraint the whole PaaS accepts),
   **ClickHouse needs explicit memory limits** on the `e2-standard-2`, and **databases are ClusterIP-only**
   (never internet-exposed).

3. **Declaring a database in `Config.hs`.** A copy-pasteable Haskell snippet that builds a Postgres
   `Database` (the smallest thing that works), annotating each field (`dbName`, `engine`, `version`,
   `namespace`, `size`, `resources`, `retention`). Use EP-44's helper if it ships one; otherwise the
   record-literal form (the pattern `cluster/examples/env-and-secrets/nagare/Config.hs` uses). The
   canonical snippet to include (reconcile constructor/field names against EP-44):

   ```haskell
   {-# LANGUAGE OverloadedStrings #-}

   module Main (main) where

   import Nagare.Dsl.Config (emitDatabase)      -- reconcile: EP-44's Database emit fn
   import Nagare.Dsl.Database
     (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
   import Nagare.Dsl.Types
     (RetentionPolicy (..), defaultNamespace, mkQuantity)

   database :: Either String Database
   database = do
     name' <- mapLeft show (mkDatabaseName "pg-main")
     ver'  <- mapLeft show (mkEngineVersion Postgres "16")  -- pinned image tag
     size' <- mapLeft show (mkQuantity "10Gi")
     pure
       Database
         { dbName    = name'
         , engine    = Postgres
         , version   = ver'
         , namespace = defaultNamespace          -- "personal"
         , size      = size'
         , resources = Nothing                   -- engine defaults; set limits for ClickHouse
         , retention = Retain                     -- keep the data disk on `db delete`
         }
     where
       mapLeft f = either (Left . f) Right

   main :: IO ()
   main = case database of
     Left err -> ioError (userError err)
     Right db -> emitDatabase db
   ```

   State plainly that the database is *typed* and validated at load time (a bad name, a malformed size,
   an unsupported engine/version pair are rejected with a precise message), that the password is **not**
   in this config (it is generated by `nagarectl db create`), and that for ClickHouse the `resources`
   field should set explicit memory limits (point at the ClickHouse example for the exact value EP-43
   fixed for the `e2-standard-2`).

4. **Choosing an engine, version, size, and retention.** A short prose subsection plus a small table of
   the three engines, their default ports, their data paths, and a sample pinned version, so a reader
   knows what to put in `engine`/`version`. Reconcile the exact supported versions against EP-44:

   ```markdown
   | Engine | `engine` | Default port | Data path | Example `version` |
   | --- | --- | --- | --- | --- |
   | PostgreSQL | `Postgres` | 5432 | `/var/lib/postgresql/data` | `"16"` |
   | Redis | `Redis` | 6379 | `/data` | `"7"` |
   | ClickHouse | `ClickHouse` | 8123 (HTTP) / 9000 (native) | `/var/lib/clickhouse` | `"24.3"` |
   ```

   Explain `size` (the data PVC, e.g. `"10Gi"`, reusing the `Quantity` convention) and `retention`
   (`Retain` keeps the disk on `db delete`; `Delete` destroys it — GCS backups are separate).

5. **Provisioning and operating: `nagarectl db`.** Document every verb with one transcript each.
   `nagarectl db create ENGINE NAME` (generates the `nagare-db-<name>` Secret and provisions
   Secret + PVC then StatefulSet then ClusterIP Service, waiting for ready); `nagarectl db list` (the
   table: name, engine, version, status, age); `nagarectl db get NAME` (detail: the ClusterIP DNS name,
   the Secret name, the PVC, ready status); `nagarectl db shell NAME` (an interactive client into the
   running engine — `psql`/`redis-cli`/`clickhouse-client`); `nagarectl db restart NAME`; and
   `nagarectl db delete NAME` (honors `RetentionPolicy` — with `Retain` the PVC and data survive; with
   `Delete` they are removed). Show the offline `--dry-run` form of `db create` and an abbreviated `text`
   transcript of the rendered StatefulSet/Service/PVC/Secret — the no-cluster proof. State that resources
   are discovered by the `nagare.dev/managed-by: nagarectl` + `nagare.dev/database: <name>` labels (IP3),
   so the `db` commands always reflect what was provisioned.

6. **Connecting an app to a database.** The heart of the guide. Explain the app→database reference: add
   the database's name to the app's `databases` list in its `Config.hs`, and at deploy time the app
   receives per-engine connection environment variables. Show the **per-engine connection-env table**
   (reconcile against EP-46's shipped injection):

   ```markdown
   | Engine | Literals (inline) | Secret references (`secretKeyRef` → `nagare-db-<name>`) |
   | --- | --- | --- |
   | Postgres | `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB` | `POSTGRES_PASSWORD`, `DATABASE_URL` |
   | Redis | `REDIS_HOST`, `REDIS_PORT` | `REDIS_PASSWORD`, `REDIS_URL` |
   | ClickHouse | `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_USER` | `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_URL` |
   ```

   State the rule plainly: variables that embed the password (the composed `*_URL` and any `*_PASSWORD`)
   are injected as Kubernetes Secret references (`valueFrom.secretKeyRef` into `nagare-db-<name>`), never
   as inline values; host/port/user/db are plain literals. The host is the ClusterIP DNS name
   `<name>.<namespace>.svc.cluster.local`. Show a short app `Config.hs` snippet adding the reference and
   an abbreviated `nagarectl deploy --dry-run` transcript proving the injected env appears (a literal
   `POSTGRES_HOST` and a `valueFrom.secretKeyRef` `DATABASE_URL`). Add a `>` callout that an app and its
   database must share a namespace (the default `personal`) for the DNS name and Secret reference to
   resolve.

7. **Backups and restore.** Document `nagarectl db backup NAME` (writes an engine-appropriate logical
   dump to `gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>`), the scheduled
   per-database CronJob (created at `db create` time), keep-last-N retention, and
   `nagarectl db restore NAME BACKUP_ID` (scratch-first where feasible). Then describe the **restore
   drill** in prose: take a backup, list it in GCS, create a *disposable* database, restore the backup
   into it, verify the data, and delete the disposable database — never restore over a live production
   database without verifying first. Point at `docs/user/backups-and-disaster-recovery.md` and
   `docs/runbooks/disaster-recovery.md` (extended by EP-47) for the full restore steps; do not duplicate
   them.

8. **Constraints and limits.** A dedicated section restating, with rationale, the constraints from the
   concepts callout: **single replica / single node** (no HA, no replication, no failover — a database
   pod restart means brief downtime; this is the deliberate single-node design, the same constraint
   apps accept); **ClickHouse memory** (it must be given explicit `resources` memory limits or it will
   destabilize the `e2-standard-2` — cite the exact limit EP-43 fixed); **ClusterIP-only** (databases are
   never exposed to the public internet — to reach one from your workstation, port-forward, do not create
   a public DomainMapping). Note that major-version upgrades and connection pooling are out of scope
   (apps run their own pooler if needed), matching MasterPlan 9's scope.

9. **Three worked examples.** Three short subsections, each one paragraph plus the key commands, pointing
   at `cluster/examples/postgres-app/`, `cluster/examples/redis-cache/`, and
   `cluster/examples/clickhouse-analytics/` (added in M2/M3) for the full walk-throughs.

Index the new page in **`docs/user/README.md`**: add a sub-bullet under item 8 ("Deploying apps"),
alongside the existing "Persistent storage" and "Environment and secrets" sub-bullets, linking
`managed-databases.md` with a one-line description and a 🟡 status badge. Also add a row to the
"Area / Plan / Status" mapping table (e.g. "Managed databases (Postgres/Redis/ClickHouse) | MP-9
(EP-43–48) | 🟡 Built; live deploy pending").

Link the new page from **`docs/user/deploying-apps.md`** wherever the "data tier" / related-features
links live (the same place EP-37 linked persistent storage), with a one-line description.

Cross-link **`docs/user/backups-and-disaster-recovery.md`**: ensure its "What to back up" table has a
"Managed databases → `nagarectl db backup` → `gs://…/databases/<name>/`" row (EP-47 owns this row; this
plan only ensures the cross-link to `managed-databases.md` exists and is consistent), and add a one-line
pointer from its restore/drill section to the database restore drill in `managed-databases.md`.

Acceptance for M1: `docs/user/managed-databases.md` exists and renders; every command, field name, and
connection-env variable in it matches MasterPlan 9's IP1–IP6 contract and EP-44/45/46/47's shipped
surface (verified by running the real `--help`/`--dry-run`); `README.md` and `deploying-apps.md` link the
new page; `backups-and-disaster-recovery.md` is cross-linked both ways; no bare ```` ``` ```` fences exist
in any edited file.

### Milestone 2 — The three end-to-end examples (offline-verified)

Scope: create `cluster/examples/postgres-app/`, `cluster/examples/redis-cache/`, and
`cluster/examples/clickhouse-analytics/`, each with a `Database` config, an app `Deployment` config that
references the database, a tiny dependency-free app where source is needed, and a `README.md`. At the end
of this milestone every example renders offline: `nagarectl db create ... --dry-run` renders the
StatefulSet/Service/PVC/Secret, and `nagarectl deploy --dry-run` renders the app with the injected
connection env. The live legs are M3.

Each example directory follows the EP-37 shape — a `nagare/` subdirectory with `Config.hs` for the app,
a second `Config.hs` (or a clearly named file) for the `Database`, a small `app.py`/`app.js` +
`Dockerfile` for the app where the engine's connection must be exercised, and a `README.md`. Decide,
during reconciliation, whether the database is declared in its own `nagare/Config.hs` emitting a
`Database` (provisioned by `nagarectl db create -f ...` if EP-45 supports `-f`, or by
`nagarectl db create ENGINE NAME` with flags) — document whichever EP-44/EP-45 shipped, and keep the
file layout consistent across all three examples.

**Example 1 — `cluster/examples/postgres-app/` (Postgres-backed app, `DATABASE_URL`).** Files:
`nagare/Database.hs` (a `Database` with `engine = Postgres`, a pinned `version`, `size = "10Gi"`,
`retention = Retain`, named e.g. `pg-main`); `nagare/Config.hs` (an app `Deployment` from `webService`
that lists `pg-main` in its `databases` field); `app.py` (a stdlib HTTP server that reads `DATABASE_URL`
from the environment, connects to Postgres, on `GET /add` inserts a timestamped row, on `GET /` returns
the row count — keep it dependency-light; if a Postgres driver is needed, the `Dockerfile` installs it);
`Dockerfile`; and `README.md`. The README shows: `nagarectl db create postgres pg-main --dry-run` (or the
`-f` form) and the rendered StatefulSet/Service/PVC/Secret; `nagarectl db create postgres pg-main` (live);
`nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs --dry-run` showing the injected
`DATABASE_URL` (a `secretKeyRef`) and `POSTGRES_HOST` (a literal); the live deploy; a `curl "$URL/add"`
then a database pod restart (`nagarectl db restart pg-main`) then `curl "$URL/"` proving the row survived;
and `nagarectl db backup pg-main` + `gsutil ls "gs://tan-nb-exp-nagare-backups/databases/pg-main/"`
proving the dump landed.

**Example 2 — `cluster/examples/redis-cache/` (Redis cache, `REDIS_URL`).** Files: `nagare/Database.hs`
(`engine = Redis`, pinned `version`, a small `size`, named e.g. `cache`); `nagare/Config.hs` (an app
referencing `cache`); `app.py` (reads `REDIS_URL`, on `GET /set?k=…&v=…` sets a key, on `GET /get?k=…`
reads it back, demonstrating the cache); `Dockerfile`; `README.md`. The README shows the
`db create redis cache --dry-run`/live, the `deploy --dry-run` proving `REDIS_URL` is a `secretKeyRef` and
`REDIS_HOST` a literal, a set/get round-trip, and a `db backup cache` to GCS. Note in the README that
Redis is a cache here (single replica, no replication) so treat its contents as ephemeral-tolerant.

**Example 3 — `cluster/examples/clickhouse-analytics/` (ClickHouse analytics store, `CLICKHOUSE_URL`).**
Files: `nagare/Database.hs` (`engine = ClickHouse`, pinned `version`, `size`, **explicit `resources`
memory limits** for the `e2-standard-2` — use the exact value EP-43 fixed), named e.g. `events`;
`nagare/Config.hs` (an app referencing `events`); `app.py` (reads `CLICKHOUSE_URL`, on `GET /track`
inserts an event row over the HTTP interface, on `GET /count` queries the row count); `Dockerfile`;
`README.md`. The README must carry a prominent **memory-limit note**: ClickHouse on the small
`e2-standard-2` VM must be given explicit memory limits in `resources`, or it will destabilize the node;
show the exact `resources` value in the `Database.hs` and explain why. Show the same dry-run → live →
write → query → backup walk-through as the other two.

Each README ends with a **Clean up** section: `nagarectl db delete <name>` (note `retention = Retain`
keeps the PVC and data; show the explicit destructive `kubectl delete pvc` to reclaim the disk, mirroring
EP-37's uploads/sqlite cleanup), `nagarectl app delete <app>`, and a note that GCS dumps survive deletion
and must be removed manually (`gsutil rm -r gs://tan-nb-exp-nagare-backups/databases/<name>/`) respecting
the bucket's `forceDestroy: false` protection.

Acceptance for M2: for each of the three examples, `nagarectl db create ... --dry-run` renders the
StatefulSet (one replica, the engine image at the pinned version, the data path mount), the ClusterIP
Service, the `local-path` RWO PVC at the requested size, and the `nagare-db-<name>` Secret; and
`nagarectl deploy -f .../Config.hs --dry-run` renders the app with the per-engine connection env (the
literals inline and the `*_URL`/`*_PASSWORD` as `secretKeyRef`). The ClickHouse example's rendered
StatefulSet shows the memory limits. No bare ```` ``` ```` fences in any new file.

### Milestone 3 — One live end-to-end run and a restore drill (or deferred-with-instructions)

Scope: on a live cluster, run one example (recommended: `postgres-app`, the richest) end to end —
`db create`, `deploy`, write a row, restart the database pod, confirm the row survived, `db backup`,
confirm the dump in GCS — and exercise a restore drill on a *disposable* database. Capture the real
transcripts into the example README and this plan's Progress. If `nagare-01` is unreachable, defer this
leg with the exact on-VM commands, exactly as EP-37 deferred its live legs.

The live run must happen on the VM (workstation `nagarectl`/`kubectl`/`gsutil` cannot reach the k3s API —
IAP forwards only SSH/22). The exact deferral-with-instructions to embed in the README and Progress:

```bash
# Live end-to-end + restore drill for the managed-database examples.
# Run these ON nagare-01 (the workstation cannot reach the k3s API: IAP forwards only SSH/22,
# and the workstation default kubectl context is an unrelated GKE cluster — do not use it).

# 1. Start the VM (it is often TERMINATED), then SSH in as the deploy user.
gcloud compute instances start nagare-01 --project=tan-nb-exp --zone=us-west1-a
scripts/iap-ssh.sh            # opens a shell on nagare-01 as the deploy user

# --- the following run on nagare-01 ---

# 2. Provision a disposable Postgres database and deploy the app that references it.
nagarectl db create postgres pg-main
nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs
nagarectl db get pg-main      # shows DNS name, Secret nagare-db-pg-main, Bound PVC, Ready

# 3. Write a row and prove it survives a database pod restart.
URL=$(nagarectl app get postgres-app | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/add"          # -> rows: 1
nagarectl db restart pg-main
curl -fsS "$URL/"             # -> rows: 1   (data survived; durable PVC + StatefulSet identity)

# 4. Back up and confirm the dump landed in GCS.
nagarectl db backup pg-main
gsutil ls "gs://tan-nb-exp-nagare-backups/databases/pg-main/"

# 5. Restore drill on a DISPOSABLE database (never restore over the live one unverified).
BACKUP=$(gsutil ls "gs://tan-nb-exp-nagare-backups/databases/pg-main/" | tail -1)
nagarectl db create postgres pg-drill
nagarectl db restore pg-drill "$BACKUP"
nagarectl db shell pg-drill   # verify the row count matches, then exit
nagarectl db delete pg-drill  # tear down the disposable database
```

Expected observations to capture into the README (the acceptance):

```text
# Step 2: db get shows the provisioned database, in-cluster DNS, Secret, Ready
NAME     ENGINE    VERSION   STATUS   DNS
pg-main  postgres  16        Ready    pg-main.personal.svc.cluster.local
SECRET   nagare-db-pg-main
PVC      Bound (10Gi, local-path)

# Step 3: the row survived the database pod restart (StatefulSet identity + durable PVC)
rows: 1

# Step 4: the logical dump landed under the documented GCS layout
gs://tan-nb-exp-nagare-backups/databases/pg-main/2026-06-...T....sql.gz

# Step 5: the restore drill reproduced the row count in a disposable database
rows: 1
```

Acceptance for M3: either the transcripts above are captured from a real run on `nagare-01` (the row
survives the database restart, the dump appears in GCS, and the restore drill reproduces the data in a
disposable database), or the README and this plan's Progress record "dry-run verified; live run deferred"
with the exact on-VM commands above, mirroring `docs/plans/37-...`. The offline dry-run renders from M2
are mandatory and must pass regardless.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

First reconcile the documented surfaces against the shipped CLI (see Plan of Work). When `nagarectl` is
on `PATH`:

```bash
nagarectl db --help
nagarectl db create --help
nagarectl db backup --help
```

From a source checkout where `nagarectl` is not on `PATH`, use the cabal form (the same form EP-37's
examples use; the `--ghc-env` mechanism lets the loader's `runghc` find `nagare-dsl`):

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- db --help
cabal --project-dir=cli/nagarectl run nagarectl -- db create postgres pg-main --dry-run
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/postgres-app/nagare/Config.hs --dry-run
```

Write the docs (M1), then create the three example directories (M2). After each example's configs,
verify they load and render offline (no cluster — the `--dry-run` path renders manifests from the typed
config):

```bash
# Database manifests render (StatefulSet + ClusterIP Service + PVC + Secret):
nagarectl db create postgres   pg-main --dry-run
nagarectl db create redis      cache   --dry-run
nagarectl db create clickhouse events  --dry-run

# App with injected connection env renders:
nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs        --dry-run
nagarectl deploy -f cluster/examples/redis-cache/nagare/Config.hs         --dry-run
nagarectl deploy -f cluster/examples/clickhouse-analytics/nagare/Config.hs --dry-run
```

Expected (abbreviated) `db create --dry-run` output showing the rendered database resources:

```text
--- Secret: nagare-db-pg-main ---
metadata:
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/database: pg-main
    nagare.dev/engine: postgres
--- PersistentVolumeClaim: <pg-main data PVC> ---
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
--- StatefulSet: pg-main ---
spec:
  replicas: 1
  template:
    spec:
      containers:
        - image: postgres:16
          volumeMounts:
            - mountPath: /var/lib/postgresql/data
--- Service: pg-main (ClusterIP) ---
spec:
  type: ClusterIP
  ports:
    - port: 5432
```

Expected (abbreviated) `deploy --dry-run` output showing the injected Postgres connection env:

```text
        env:
          - name: POSTGRES_HOST
            value: pg-main.personal.svc.cluster.local
          - name: POSTGRES_PORT
            value: "5432"
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: nagare-db-pg-main
                key: DATABASE_URL
          - name: POSTGRES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: nagare-db-pg-main
                key: POSTGRES_PASSWORD
```

(The exact key names, ordering, and the literal-vs-secret split must match EP-44/EP-46's shipped output —
update the snippets to the real values during reconciliation.)

Check that the docs render, links resolve, and no bare fences slipped in:

```bash
grep -rn "managed-databases.md" docs/user/
grep -rn '^```$' docs/user/managed-databases.md \
  cluster/examples/postgres-app/README.md \
  cluster/examples/redis-cache/README.md \
  cluster/examples/clickhouse-analytics/README.md || echo "all fences tagged"
```

There is no separate doc build; the docs are read as Markdown in the repo. The "test" is that every
command in each example README runs and matches its shown output (or is marked live-deferred).

Commit the work in coherent chunks (docs, then examples), following Conventional Commits and committing
directly to the current branch (no feature branch). Every commit on this plan carries these trailers:

```text
docs(db): EP-48 managed-databases user guide and per-engine examples

MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/48-managed-databases-docs-and-end-to-end-examples.md
Intention: intention_01ktryacjaezzbezmkt5j93abq
```


## Validation and Acceptance

Acceptance is documentation-by-demonstration. Concretely:

1. `docs/user/managed-databases.md` exists, is linked from `docs/user/README.md` (index sub-bullet and
   the status table row) and `docs/user/deploying-apps.md`, and is cross-linked both ways with
   `docs/user/backups-and-disaster-recovery.md`. Every concept, `Database` field name, `nagarectl db`
   command, connection-env variable, and the literal-vs-secret split match MasterPlan 9's IP1–IP6 and
   EP-44/45/46/47's shipped surface (verified by reading their final Interfaces sections, or by running
   `nagarectl db --help` and the dry-runs).
2. `cluster/examples/postgres-app/` renders: `nagarectl db create postgres pg-main --dry-run` produces a
   one-replica StatefulSet on `postgres:<ver>` with the data path mount, a ClusterIP Service on 5432, a
   `10Gi` `local-path` RWO PVC, and the `nagare-db-pg-main` Secret; `nagarectl deploy --dry-run` injects
   `POSTGRES_HOST`/`POSTGRES_PORT`/`POSTGRES_USER`/`POSTGRES_DB` as literals and
   `DATABASE_URL`/`POSTGRES_PASSWORD` as `secretKeyRef`s into the app.
3. `cluster/examples/redis-cache/` renders: `db create redis cache --dry-run` produces the Redis
   StatefulSet/Service/PVC/Secret; `deploy --dry-run` injects `REDIS_HOST`/`REDIS_PORT` literals and
   `REDIS_URL`/`REDIS_PASSWORD` `secretKeyRef`s.
4. `cluster/examples/clickhouse-analytics/` renders: `db create clickhouse events --dry-run` produces the
   ClickHouse StatefulSet **with explicit memory limits** in `resources`, the Service, PVC, and Secret;
   `deploy --dry-run` injects `CLICKHOUSE_HOST`/`CLICKHOUSE_PORT`/`CLICKHOUSE_USER` literals and
   `CLICKHOUSE_URL`/`CLICKHOUSE_PASSWORD` `secretKeyRef`s.
5. On a live cluster (M3, or deferred-with-instructions): for at least one example a row written through
   the app survives a `nagarectl db restart`, `nagarectl db backup` writes a dump under
   `gs://tan-nb-exp-nagare-backups/databases/<name>/`, and the restore drill reproduces the data in a
   disposable database.
6. No bare ```` ``` ```` fences in any new or edited file (every block has a language tag).

Where a live cluster is unavailable in the implementation environment, item 5's live legs are marked
"dry-run verified; live run deferred" in the example READMEs and this plan's Progress, with the exact
on-VM commands from M3, mirroring `docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md`. The
offline dry-run rendering (items 2–4) is mandatory and must pass regardless.


## Idempotence and Recovery

All work here is additive: one new Markdown page, three new example directories, and edits to existing
docs (index links and a cross-link). Every step is safe to re-run and re-render. `nagarectl db create
--dry-run` and `nagarectl deploy --dry-run` have no side effects, so example verification can be repeated
freely. `git checkout <file>` recovers any bad edit.

The examples are provisionable repeatedly. `nagarectl db create NAME` is idempotent on the resource names
(the Secret `nagare-db-<name>`, the PVC, the StatefulSet, and the ClusterIP Service are named
deterministically from the database name), so re-running it against an already-provisioned database
reconciles rather than duplicates; re-running `db create` does **not** regenerate the password (the
generated credential lives in the existing Secret and is reused), which is exactly the behavior that lets
an app keep its `secretKeyRef` working across re-provisions. `nagarectl deploy` is declarative
(`kubectl apply` with a fresh image tag per build) and re-deploying an app re-resolves the same database
DNS name and Secret.

The restore drill is non-destructive by construction: it restores into a *disposable* database
(`pg-drill` in the M3 transcript), never over the live one, then deletes the disposable database — so a
failed or partial drill leaves the production database untouched. If a drill database is left behind,
`nagarectl db delete <drill-name>` removes it (with `Retain`, also `kubectl delete pvc` to reclaim the
disk).

Cleanup is documented in each example README per the retention policy:

```bash
# Delete the example database and app.
nagarectl db delete pg-main          # retention = Retain keeps the PVC and its data
nagarectl app delete postgres-app
# To reclaim the disk (DESTRUCTIVE — data is gone):
kubectl delete pvc -n personal <pg-main data PVC>
# GCS dumps survive deletion; remove them explicitly if desired (bucket is forceDestroy: false):
gsutil rm -r gs://tan-nb-exp-nagare-backups/databases/pg-main/
```

State in each README that with `retention = Delete` the PVC is removed when the database is deleted,
whereas `retention = Retain` (the examples' choice) keeps it — so deleting the disk is an explicit,
separate, destructive step. GCS dumps are never touched by database deletion.


## Interfaces and Dependencies

No code dependencies; this plan writes Markdown and example `Config.hs`/`Database.hs`/source files. It
**documents — it does not define** — the user-facing surfaces of the sibling plans, named here by path:

- `docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md` — the
  typed `Database` record (`dbName`, `engine`, `version`, `namespace`, `size`, `resources`, `retention`),
  the `Engine` enum (`Postgres`/`Redis`/`ClickHouse`), the smart constructors and any preset/overlay
  helper, the `databases :: [DatabaseName]` reference field added to the app `Deployment`, the
  `Database` emit/decode path, and the rendered StatefulSet/Service/PVC/Secret YAML shapes (IP1, IP2,
  IP3). The config snippets in M1 and the example configs in M2 consume these from `Nagare.Dsl.Database`
  (or `Nagare.Dsl.Types`) and the emit function in `Nagare.Dsl.Config`. **Soft dependency** — reconcile
  exact names against EP-44's final Interfaces section before finalizing snippets.
- `docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md` — the
  `nagarectl db list|create|get|shell|restart|delete` command group, the credential-Secret generation at
  `create` time, the Secret + PVC before StatefulSet provisioning order, and `delete` honoring the
  `RetentionPolicy` (IP4). The guide and examples document and exercise these commands. **Hard dependency.**
- `docs/plans/46-generated-database-connection-env-injection-for-apps.md` — the per-engine connection-env
  contract (which variables, and which are literals vs `secretKeyRef`) injected at deploy time via
  `cli/nagarectl/src/Nagare/Env/Generated.hs` / `mergeGenerated`, and the ClusterIP DNS host
  `<name>.<namespace>.svc.cluster.local` (IP5). The connection-env table in the guide and the
  `DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` consumption in the example apps depend on this. **Hard
  dependency** — the connection-env table is the single most accuracy-critical artifact; verify it against
  the real `deploy --dry-run` output.
- `docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md` — `nagarectl db backup`,
  `nagarectl db restore`, the scheduled per-database CronJob, the GCS layout
  `gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>`, keep-last-N retention, and the
  runbook/backup-guide updates (IP6). The backup/restore sections of the guide and the restore drill in
  M3 depend on these. **Hard dependency.**

New files this plan creates:

- `docs/user/managed-databases.md` (the new guide).
- `cluster/examples/postgres-app/nagare/Database.hs`, `cluster/examples/postgres-app/nagare/Config.hs`,
  `cluster/examples/postgres-app/app.py`, `cluster/examples/postgres-app/Dockerfile`,
  `cluster/examples/postgres-app/README.md`.
- `cluster/examples/redis-cache/nagare/Database.hs`, `cluster/examples/redis-cache/nagare/Config.hs`,
  `cluster/examples/redis-cache/app.py`, `cluster/examples/redis-cache/Dockerfile`,
  `cluster/examples/redis-cache/README.md`.
- `cluster/examples/clickhouse-analytics/nagare/Database.hs`,
  `cluster/examples/clickhouse-analytics/nagare/Config.hs`, `cluster/examples/clickhouse-analytics/app.py`,
  `cluster/examples/clickhouse-analytics/Dockerfile`, `cluster/examples/clickhouse-analytics/README.md`.

(The exact set of source files per example may shrink if a prebuilt public image with a built-in client
suffices; keep each example minimal and dependency-light, matching EP-37's stdlib apps. The `Database`
may be declared in its own file or, if EP-45's `db create` takes only `ENGINE NAME` flags, documented
directly in the README without a `Database.hs` — choose whichever matches the shipped CLI and keep the
layout consistent across the three examples.)

Files this plan edits:

- `docs/user/README.md` (index the new page and add the MP-9 status-table row),
  `docs/user/deploying-apps.md` (link the new page from the data-tier/related-features section), and
  `docs/user/backups-and-disaster-recovery.md` (cross-link to the database backup/restore in
  `managed-databases.md`; EP-47 owns the actual database backup row and restore steps in this file — this
  plan only ensures the cross-links exist and are consistent).

The only "interface" this plan must keep accurate is that the documented `Database` field names, the
`nagarectl db` command and flag names, the per-engine connection-env variable names and their
literal-vs-secret split, the Secret name `nagare-db-<name>` and its labels, the ClusterIP DNS form
`<name>.<namespace>.svc.cluster.local`, and the GCS layout
`gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>` match what EP-44/45/46/47 actually
shipped. Re-read their final Interfaces sections (and run the real `--help`/`--dry-run`) before writing
the snippets and transcripts, and record any divergence in this plan's Decision Log. All cloud reads and
writes target the `tan-nb-exp` project / `us-west1` region only, per the repository `CLAUDE.md`.
