---
id: 9
slug: managed-databases-for-nagare
title: "Managed Databases for Nagare"
kind: master-plan
created_at: 2026-06-10T14:25:04Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
---


# Managed Databases for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


This initiative implements **Phase 4 (Managed Databases and Backups)** of the PaaS capability roadmap
at `docs/roadmaps/paas-gap-roadmap.md`. It is the sixth initiative in the roadmap's recommended order
and the largest remaining gap, following static hosting (`docs/masterplans/3-static-hosting-for-nagare.md`),
application build modes (`docs/masterplans/4-application-build-modes-for-nagare.md`), environment and
secret management (`docs/masterplans/5-environment-and-secret-management-for-nagare.md`), application
lifecycle (`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`), persistent storage
(`docs/masterplans/7-persistent-storage-for-nagare.md`), and server/operations UX
(`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`). Per the roadmap, managed
databases "should not be started until storage and secrets have a stable shape" — both have now
shipped, so this work builds the database layer directly on top of the typed `Volume` primitive
(MasterPlan 7) and the managed Secret store (MasterPlan 5).

The user-requested scope for this initiative is **three engines: PostgreSQL, Redis, and ClickHouse**
(the roadmap's Phase 4 names PostgreSQL and Redis; ClickHouse is added here as an analytical store).


## Vision & Scope

Today a Nagare workload is stateless-by-default at the platform level. A developer writes a typed
`nagare/Config.hs` that produces a `Deployment` value (the record in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), runs `nagarectl deploy`, and the CLI builds, pushes, and
applies a **Knative Service** — a request-driven workload that scales to zero. MasterPlan 7 added
durable disk to those apps: a typed `Volume` renders a `local-path` `ReadWriteOnce`
**PersistentVolumeClaim** (the Kubernetes object an app uses to request a durable disk; "PVC" for
short) and the cluster pins any volume-bearing Service to a single always-on replica. But there is no
first-class way to run a *database*. A database is not a request-driven, scale-to-zero workload: it is
a long-lived process with a stable network identity, durable storage, and generated credentials. The
repository demonstrates one stateful pattern at the raw-Kubernetes level — `cluster/examples/sqlite-litestream/`
runs a plain Kubernetes `Deployment` (not a Knative Service) with a Litestream sidecar — but there is
no typed `Database` resource, no `nagarectl db` command group, no generated `DATABASE_URL`/`REDIS_URL`
injection into apps, and no database-level backup or restore. This is, per the roadmap, "the biggest
remaining PaaS gap."

Two terms used throughout. A **StatefulSet** is the Kubernetes controller for a workload that needs a
stable identity and durable per-instance storage; unlike a Knative Service it does not scale to zero
and keeps the same pod name and PVC across restarts. It is the natural substrate for a single-replica
database. A **headless / ClusterIP Service** is the in-cluster DNS name other pods use to reach the
database (for example `pg-main.personal.svc.cluster.local`); it is an internal address, never exposed
to the public internet.

After this initiative, a developer can declare a managed database in typed config, provision and
operate it from the CLI, connect an app to it without copying credentials by hand, and rely on
scheduled backups with a tested restore path:

- **Typed databases in the DSL.** A new `Database` record names an engine (`Postgres`, `Redis`, or
  `ClickHouse`), pins a version, requests a disk size and resource limits, and sets a retention
  policy — declared in a typed config exactly the way an app is, so illegal databases (bad names,
  malformed sizes, an unsupported engine/version pair) are unrepresentable and caught at config-load
  time with a precise error.
- **Generated stateful Kubernetes resources.** `nagarectl db create` / the deploy path renders and
  applies, per database, a **StatefulSet** running the official engine image, a **ClusterIP Service**
  giving it a stable in-cluster DNS name, a **PVC** for its data (reusing the MasterPlan 7
  `local-path` primitive), and a managed **Secret** holding generated credentials. Databases run as
  raw Kubernetes manifests rendered by the typed DSL — no operator, no Helm — consistent with how
  every other Nagare resource is produced.
- **Generated secrets and app env injection.** A strong password is generated at create time (never
  written into `Config.hs`, which is pure and deterministic) and stored in the managed Secret. An app
  declares that it uses a database by name, and `nagarectl deploy` injects connection variables into
  the app's runtime environment: `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and a composed
  `DATABASE_URL` for Postgres; `REDIS_URL` for Redis; `CLICKHOUSE_URL` and host/user/password for
  ClickHouse. Variables that embed the password (the composed URLs and `*_PASSWORD`) are injected as
  Kubernetes Secret references; the rest are plain literals.
- **Database CLI.**

```text
nagarectl db list
nagarectl db create postgres NAME
nagarectl db get NAME
nagarectl db shell NAME
nagarectl db backup NAME
nagarectl db restore NAME BACKUP_ID
nagarectl db restart NAME
nagarectl db delete NAME
```

- **Scheduled backups and tested restores.** Each database gets a Kubernetes **CronJob** that runs an
  engine-appropriate logical backup (`pg_dump` for Postgres, an RDB save for Redis, a `clickhouse-backup`
  / native dump for ClickHouse), gzips it, and uploads it to the existing GCS backup bucket
  `gs://tan-nb-exp-nagare-backups` under a `databases/<name>/` prefix, with keep-last-N retention that
  reuses the MasterPlan 7 pruning logic. `nagarectl db backup` triggers an on-demand backup;
  `nagarectl db restore NAME BACKUP_ID` restores a chosen backup (scratch-first where feasible). A
  restore drill against a disposable database is documented and exercised.

What is **in scope**: a feasibility spike that proves all three engines run on the single-node cluster
and settles the stateful rendering substrate and credential model; the typed `Database` model and its
JSON round-trip; the StatefulSet/Service/PVC/Secret renderer; the `nagarectl db` lifecycle command
group with deploy-time provisioning; generated connection-env injection into apps; scheduled backups,
on-demand backup, restore, and retention with runbook integration; and user documentation with three
working end-to-end examples (one per engine).

What is **out of scope** (deferred or noted as integration points): high availability, replication,
and clustering (each database is a single replica on this single-node PaaS — the same constraint the
whole platform accepts); automatic major-version upgrades and in-place engine migration; connection
pooling as a managed feature (apps may run their own pooler); multi-tenant database users and
fine-grained grants beyond a single generated application role; managed MySQL/MariaDB and MongoDB (the
roadmap names them as possible future engines, not this initiative); point-in-time recovery / WAL
archiving for Postgres (this initiative does logical `pg_dump` backups, not continuous archiving);
exposing a database to the public internet (databases are ClusterIP-only); a web UI for databases
(Phase 10). The typed `Volume` model from MasterPlan 7 is *reused* for database storage but not
extended, and the managed Secret store from MasterPlan 5 is *reused conceptually* for the
Nagare-managed labelling and naming conventions rather than driven through `nagarectl secret`.


## Decomposition Strategy

The initiative is decomposed into six child ExecPlans (EP-43 through EP-48). The guiding principle is
the same seam the sibling MasterPlans use: separate *platform feasibility* from the *typed model* from
the *renderer and CLI lifecycle* from the *app-integration* from the *backup policy* from the
*documentation*, so that each plan produces an independently verifiable behavior and groups one
functional concern rather than one file — and, critically, so the three engines are handled as typed
**variants of one model** rather than as three near-duplicate plans.

The decisive structural decision is that **engines are a typed dimension, not a unit of decomposition.**
PostgreSQL, Redis, and ClickHouse differ in their image, default port, credential shape, connection-URL
format, and backup command — but they share the entire renderer (StatefulSet + Service + PVC + Secret),
the entire CLI surface (`db create/list/get/shell/...`), and the entire env-injection and backup
*mechanism*. Splitting by engine would force three plans to modify the same renderer and the same
subparser in the same way, which the MasterPlan decomposition principles explicitly warn against
("two plans that must modify the same function in the same way should likely be one plan"). So each
plan handles all three engines, exactly the way `BuildSpec` in
`cli/nagare-dsl/src/Nagare/Dsl/Build.hs` handles `DockerfileBuild`/`PrebuiltImage`/`NixpacksBuild` as
one typed model. Engine-specific facts (images, ports, backup commands, URL templates) live as data
inside each plan.

The most significant unknown — and the reason this is a MasterPlan with an isolated first plan rather
than a single ExecPlan — is that **Nagare has never rendered a stateful workload.** Every existing
renderer produces a Knative Service (or, in the SQLite example, a hand-written plain Deployment). A
database needs a fundamentally different substrate: a StatefulSet that does not scale to zero, a
ClusterIP Service for stable internal DNS, generated credentials that cannot come from the pure
deterministic DSL, and — for ClickHouse especially — a real question of whether the engine even runs
acceptably on the small single-node VM (`nagare-01`, an `e2-standard-2`). Per the ExecPlan
specification's guidance to de-risk significant unknowns with an explicit spike, this feasibility work
is its own first plan (**EP-43**), mirroring how MasterPlan 7 isolated the Knative-PVC spike (EP-33).
EP-43 produces verified raw-YAML proof that each engine runs, survives a pod restart with data intact,
and is reachable in-cluster; it settles the credential-generation architecture; and it fixes the
rendered shapes the typed renderer must reproduce.

The typed model and renderer (**EP-44**) is the foundation every later plan imports: it owns the
`Database` type and engine enum, their placement in a loadable typed config, the JSON round-trip
(emit/decode), and the renderer that turns a `Database` into the StatefulSet/Service/PVC/Secret
manifest set EP-43 verified, all with golden tests. It is pure DSL work and golden-testable without a
cluster, so it only *soft*-depends on EP-43 — but the YAML it emits must match the shape EP-43 proved,
which is an explicit integration point.

The CLI lifecycle plan (**EP-45**) is the first *operational* consumer: it adds the `nagarectl db`
command group (`list`, `create`, `get`, `shell`, `restart`, `delete`), generates the credential
Secret at create time, and provisions the rendered resources in the correct order (Secret and PVC
before the StatefulSet, then wait for ready). The app-integration plan (**EP-46**) is deliberately
separate because connecting an app to a database is a distinct functional concern that touches a
different part of the repo (the app deploy path and `cli/nagarectl/src/Nagare/Env/Generated.hs`), not
the `db` subcommands: it adds the app→database reference in the DSL and injects the generated
connection env. The backup plan (**EP-47**) is its own coherent, separately demonstrable policy:
scheduled CronJobs, on-demand `db backup`, `db restore`, retention, GCS layout, and runbook
integration, reusing the MasterPlan 7 bucket and pruning conventions. Documentation and three
end-to-end examples (**EP-48**) come last, mirroring how every sibling initiative finished with a
docs/example plan (`docs/plans/37-...`, `docs/plans/42-...`).

Alternatives considered and rejected. **A single ExecPlan**: the roadmap explicitly says "one
MasterPlan with child plans for database model, Postgres, Redis, backups, and app env integration,"
and the stateful-substrate unknown is large enough to deserve isolation, so a MasterPlan is warranted.
**One plan per engine** (a Postgres plan, a Redis plan, a ClickHouse plan): rejected because all three
share the renderer, CLI, env-injection, and backup mechanisms — three engine plans would all edit the
same functions identically, maximizing cross-plan coupling; the engine belongs as a typed enum inside
each functional plan. **Folding the feasibility spike into the model plan**: rejected because they
touch entirely different parts of the repo (live cluster experiments and raw YAML vs `cli/nagare-dsl/`)
and the spike is the de-risking gate — keeping it separate lets the model proceed in parallel against
the verified shapes. **Merging app-env-injection into the CLI lifecycle plan**: rejected because
provisioning a database and wiring an app to consume one are different concerns in different code
paths; merging would produce one oversized plan and one trivial one. **Splitting backups by engine or
into "schedule" and "restore" plans**: rejected to keep the plan count at six — they share the bucket,
the retention logic, and the CronJob/Job substrate, so they are one plan with per-engine and
schedule/restore milestones.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 43 | Managed-database substrate spike and stateful rendering feasibility | docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md | None | None | Complete |
| 44 | Typed Database model and stateful StatefulSet, Service, PVC, and Secret renderer | docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md | None | EP-43 | Complete |
| 45 | nagarectl db lifecycle commands and deploy-time provisioning | docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md | EP-44 | EP-43 | Complete |
| 46 | Generated database connection env injection for apps | docs/plans/46-generated-database-connection-env-injection-for-apps.md | EP-44 | EP-45 | Complete |
| 47 | Scheduled database backups, restore commands, and retention | docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md | EP-44, EP-45 | EP-43 | Complete |
| 48 | Managed databases docs and end-to-end examples | docs/plans/48-managed-databases-docs-and-end-to-end-examples.md | EP-45, EP-46, EP-47 | EP-44 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-43, EP-45). The numbers
continue the repository's sequential plan numbering; the most recent existing plan is EP-42 (a child
of MasterPlan 8).


## Dependency Graph

EP-43 (the substrate spike) has no dependencies and is the practical root: it runs each engine on the
live single-node cluster from raw manifests, proves data survives a pod restart, confirms in-cluster
reachability, and answers the open architectural questions — StatefulSet versus plain Deployment, how
the credential Secret is generated and named, what resource limits ClickHouse needs to be viable on an
`e2-standard-2`, and what backup command each engine uses. It produces the *verified rendered shapes*
(the exact StatefulSet/Service/PVC/Secret stanzas per engine) and the *credential and naming contract*
that the rest of the initiative relies on.

EP-44 (the typed model and renderer) has no *hard* dependency because it is pure DSL work: the
`Database` type, the engine enum, the JSON round-trip, and the renderer can be written and
golden-tested without a cluster. It *soft*-depends on EP-43 because the YAML it renders must match the
shapes EP-43 proved the cluster accepts (Integration Point IP2); if EP-44 ran first, its goldens would
encode an unverified guess. The recommended order is EP-43 then EP-44, but EP-44 can begin in parallel
as soon as EP-43's spike has produced the verified stanzas.

EP-45 (CLI lifecycle + provisioning) hard-depends on EP-44: it applies the manifests EP-44 renders and
operates on the typed `Database` EP-44 defines. It soft-depends on EP-43 because a *live* end-to-end
provision needs the engines validated on the cluster; its pure logic (the subparser, the credential
generation, the apply ordering, the table formatters) is testable without the cluster via `--dry-run`.

EP-46 (app env injection) hard-depends on EP-44 for the `Database` name type and the app→database
reference field it adds to `Deployment`, and on the credential-Secret naming/keys contract (IP3). It
soft-depends on EP-45 because the env-injection logic can be rendered and unit-tested against the known
Secret-name contract via `--dry-run` before EP-45's live `db create` exists; a real end-to-end "app
reads a live database" demonstration wants EP-45 done.

EP-47 (backups + restore) hard-depends on EP-44 (the engine and retention live in the typed model) and
EP-45 (it extends the `db` command group EP-45 introduces and needs a running database with its
credential Secret to back up). It soft-depends on EP-43 because an actual backup of live data needs a
running engine; the GCS layout, retention pruning, and CronJob/Job rendering are unit-testable
offline.

EP-48 (docs and examples) hard-depends on EP-45, EP-46, and EP-47 because it documents and exercises
their command surfaces end to end, and soft-depends on EP-44 to document the typed `Database` fields
accurately.

**Parallelism.** EP-43 and the non-rendering parts of EP-44 (the `Database` type, engine enum, smart
constructors, JSON round-trip) can proceed concurrently; EP-44's renderer goldens should be finalized
only once EP-43's verified shapes exist. After EP-44 completes, EP-45 and the rendering/unit parts of
EP-46 can proceed in parallel (EP-46 gates on EP-45 only for the live end-to-end leg). EP-47 begins its
GCS-layout and CronJob-rendering work in parallel with EP-45 but gates on EP-45 for the shared `db`
command plumbing and a live database to back up. EP-48 is last.


## Integration Points

**IP1 — The typed `Database` model and its JSON shape.** Defined by **EP-44** in a new module
`cli/nagare-dsl/src/Nagare/Dsl/Database.hs` (or an extension of
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), serialized via the emit path in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` and decoded in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` as a
new config *kind* alongside the existing `Deployment`/`StaticSite`/`ServerSite` discriminator (the
`SiteConfig` discriminator pattern in `Load.hs`). The shared contract is a validated record:

```haskell
-- | A managed database. All fields are validated by smart constructors; the
-- data constructor is not exported, so an illegal Database cannot be built
-- (mirrors mkServiceName / mkQuantity / Volume in Nagare.Dsl.Types).
data Engine = Postgres | Redis | ClickHouse
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

data Database = Database
  { dbName    :: !DatabaseName    -- ^ DNS-label name, unique within the namespace
  , engine    :: !Engine          -- ^ Postgres | Redis | ClickHouse
  , version   :: !EngineVersion   -- ^ pinned image tag, validated per engine
  , namespace :: !Namespace       -- ^ reuses the existing Namespace newtype
  , size      :: !Quantity        -- ^ data volume size, reuses Quantity ("10Gi")
  , resources :: !(Maybe Resources) -- ^ reuses the existing Resources record
  , retention :: !RetentionPolicy -- ^ reuses MasterPlan 7's Retain | Delete
  }
  deriving stock (Generic, Eq, Show)
```

EP-45, EP-46, EP-47, and EP-48 import these types and the accessors. The JSON field names are owned by
EP-44; later plans read the loaded `Database`, never the raw JSON. EP-44 must reuse the existing
`Namespace`, `Quantity`, `Resources`, and `RetentionPolicy` types from `Nagare.Dsl.Types` rather than
introduce parallel ones, and must keep every existing config compiling unchanged.

**IP2 — The rendered stateful resource shapes (per engine).** *Verified* by **EP-43** (as raw YAML
applied by hand on the live cluster) and *produced* by **EP-44** in a new renderer
`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`. The two must agree exactly. The contract is: each
`Database` renders (a) a **StatefulSet** running the engine's official image at the pinned version,
with one replica, the data PVC mounted at the engine's data path (`/var/lib/postgresql/data`,
`/data`, `/var/lib/clickhouse` respectively), resource limits, and the credential env wired from the
managed Secret; (b) a **ClusterIP Service** giving stable in-cluster DNS; (c) a **PVC** with
`storageClassName: local-path` and `accessModes: [ReadWriteOnce]` reusing the MasterPlan 7 size/quantity
convention (or a StatefulSet `volumeClaimTemplates` entry — EP-43 decides which); and (d) the
*structure* of the managed credential **Secret** (its keys; the values are filled by EP-45 at create
time, not by the pure renderer). EP-43 owns the *facts* about what each engine needs (image, port,
data path, required env vars like `POSTGRES_PASSWORD`/`POSTGRES_USER`/`POSTGRES_DB`, ClickHouse memory
limits); EP-44 encodes those facts into the renderer and golden files. The renderer's YAML key
ordering must extend the deterministic-ordering table the existing `Render.hs` uses.

**IP3 — The managed credential Secret: naming, keys, and labels.** Defined jointly by **EP-44** (which
owns the Secret *name* and *key* contract and the labels, so the renderer can reference them) and
**EP-45** (which *generates the values* — a strong password — at create time and writes the Secret).
Consumed by **EP-46** (which reads the Secret name/keys to inject connection env into apps) and
**EP-47** (which reads it for backup/restore authentication). The contract: the Secret is named
deterministically from the database name, e.g. `nagare-db-<name>`; it carries the labels
`nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`, and `nagare.dev/engine: <engine>`
(aligning with the `nagare.dev/managed-by` convention MasterPlan 6 stamps on Services and MasterPlan 7
stamps on PVCs); and its keys are engine-specific but fixed — for Postgres `POSTGRES_PASSWORD`,
`POSTGRES_USER`, `POSTGRES_DB`, and a composed `DATABASE_URL`; for Redis `REDIS_PASSWORD` and
`REDIS_URL`; for ClickHouse `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_USER`, and `CLICKHOUSE_URL`. **The
password is never stored in `Config.hs`** (the DSL is pure and deterministic and cannot generate
randomness); it is generated once by `nagarectl db create` and lives only in the Secret. EP-46 and
EP-47 must query the Secret by name/label, never re-derive credentials.

**IP4 — The `nagarectl db` command-group plumbing.** Introduced by **EP-45** in
`cli/nagarectl/app/Main.hs` (a new `db` subparser following the existing `storage`/`secret` subparser
pattern) and a new module namespace `cli/nagarectl/src/Nagare/Database/`. **EP-47** extends the same
subparser with the `backup` and `restore` subcommands and adds modules under the same namespace,
reusing EP-45's resource-discovery helpers (which query by the IP3 labels) and the `Cradle`-based
`kubectl`/`gcloud` shell-out conventions used across `cli/nagarectl/src/Nagare/`. EP-45 owns the
subparser wiring and the shared discovery helper; EP-47 must extend, not fork, them.

**IP5 — The app→database connection-env contract.** Defined by **EP-46**: it adds an app→database
reference to the `Deployment` model (a `databases :: [DatabaseName]` field, or equivalent, on the
record in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`) and an injection function that, at deploy time,
resolves each referenced database to its stable in-cluster DNS name and its managed Secret (IP3) and
merges connection variables into the app's runtime env via the existing
`cli/nagarectl/src/Nagare/Env/Generated.hs` / `mergeGenerated` mechanism. The contract fixes which
variables are emitted per engine and which are *literals* (host, port, user, db name — injected
inline) versus *Secret references* (the composed `DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` and any
`*_PASSWORD`, which embed the password and so must render as `valueFrom.secretKeyRef` pointing at the
IP3 Secret). EP-44 owns the `databases` field on `Deployment` (so it round-trips through the same
emit/decode path as the rest of the app model); EP-46 owns the injection function and the variable
contract. EP-48 documents the exact variable names.

**IP6 — The backup GCS layout and retention, reusing MasterPlan 7.** Defined by **EP-47**, building on
the `RetentionPolicy` field EP-44 places in the model (IP1) and reusing the GCS bucket and pruning
logic MasterPlan 7 established. The contract: `nagarectl db backup NAME` writes an engine-appropriate
logical dump to `gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>` (the same bucket
`scripts/backup-postgres.sh`, the Litestream example, and MasterPlan 7's volume snapshots use), with
keep-last-N retention that reuses the pure `snapshotsToPrune` helper from
`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`. The scheduled CronJob writes to the same path. The
disaster-recovery runbook (`docs/runbooks/disaster-recovery.md`) and user backup guide
(`docs/user/backups-and-disaster-recovery.md`) are updated by EP-47 and referenced by EP-48. The GCS
bucket name and the project-isolation rule (`tan-nb-exp` only, per the repository `CLAUDE.md`) are
fixed constraints every plan must respect.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and the
milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-43 (2026-06-10): Postgres 18.4, Redis 8.8.0, and ClickHouse 25.8.24.21 each run on the live single-node cluster from raw manifests; data survives a pod restart; reachable over ClusterIP DNS.
- [x] EP-43 (2026-06-10): Stateful substrate decided (single-replica **StatefulSet** + standalone `local-path` PVC, not `volumeClaimTemplates`); credential model settled (IP3: `nagare-db-<name>` Secret, `envFrom`, Redis `--requirepass` interpolation); ClickHouse limits fixed (`2Gi` container limit + `max_server_memory_usage: 1610612736`); per-engine verified YAML shapes recorded as the input to EP-44.
- [x] EP-44 (2026-06-10): `Database`/`Engine`/`EngineVersion`/`DatabaseName` types + smart constructors; existing configs compile (dsl + nagarectl literals updated); the `databases` reference field added to `Deployment` (IP5).
- [x] EP-44 (2026-06-10): JSON round-trip (Config.hs emit / Load.hs decode) carries the `Database` config kind with `UnexpectedKind` cross-rejection; golden + round-trip tests pass.
- [x] EP-44 (2026-06-10): StatefulSet/Service/PVC(/ConfigMap) renderer per engine reproduces EP-43's verified shapes (Postgres PGDATA, Redis `--requirepass`, ClickHouse dual ports + memory ConfigMap); 10 goldens; deterministic key ordering; no existing golden changed.
- [x] EP-45 (2026-06-10): `nagarectl db create ENGINE NAME` generates the credential Secret (IP3) and provisions the resources in order (Secret, then PVC/ConfigMap/Service/StatefulSet, then wait for rollout); idempotent password; demonstrated via the real CLI `--dry-run` for all three engines. Live leg deferred to EP-48.
- [x] EP-45 (2026-06-10): `nagarectl db list|get|shell|restart|delete` implemented; delete honors `RetentionPolicy` (read from a stamped annotation) behind `--yes`; pure helpers unit-tested (186 nagarectl tests pass).
- [x] EP-46 (2026-06-10): An app declares `databases`; `nagarectl deploy` injects the per-engine connection env — host/port/user/db literals + `*_PASSWORD`/`*_URL` Secret refs to `nagare-db-<name>` — merged via `mergeGenerated` (generated wins over user env); collision + missing-db errors clear; verified via render-demonstration + unit tests (195 nagarectl tests). Server sites deferred (no `ServerSite.databases` field in v1).
- [x] EP-47 (2026-06-10): `nagarectl db backup NAME` renders+applies a two-container dump Job to the GCS layout `databases/<name>/<ts>.<ext>`; keep-last-N retention reuses `snapshotsToPrune`; daily self-pruning CronJob renders and is provisioned at `db create` (unless `retention = Delete`). **Live upload blocked by the EP-43 flannel/metadata routing regression** (renderers unit-tested; live leg deferred to EP-48).
- [x] EP-47 (2026-06-10): `nagarectl db restore NAME BACKUP_ID` renders a scratch-first restore Job (`--into-live` opt-in); restore drill documented; disaster-recovery runbook + user backup guide updated (incl. the routing caveat). 207 nagarectl tests pass.
- [x] EP-48 (2026-06-10): User guide `docs/user/managed-databases.md` written + cross-linked; one end-to-end example per engine (`postgres-app`, `redis-cache`, `clickhouse-analytics`) renders via `db create --dry-run` (configs emit valid JSON; ClickHouse shows its memory limit + dual ports). Live deploy/restore drill deferred-with-instructions (live backup additionally blocked by the flannel/metadata routing regression).


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected interactions
between child plans. Provide concise evidence.

- **Engine versions bumped to modern majors (affects EP-44/EP-48).** Per user direction (2026-06-10),
  the engines default to **Postgres 18, Redis 8, ClickHouse 25.8 (LTS)** — not the
  `postgres:16`/`redis:7`/`clickhouse-server:24` the child plans were originally drafted against. All
  three were re-verified on the cluster (18.4 / 8.8.0 / 25.8.24.21). EP-44's `EngineVersion` defaults
  and golden files must use the modern tags, and the validator must accept ClickHouse's `YY.M` calendar
  versioning (**there is no bare `:25` tag** — an initial `:25` pull failed `NotFound`; valid tags are
  `25.8`, `25.10`, `26.x`). Evidence: EP-43 Decision Log + Surprises.

- **EP-47 has a hard blocker discovered during EP-43: in-pod GCS auth is broken cluster-wide (IP6).**
  The metadata IP `169.254.169.254` is routed into the k3s `flannel.1` VXLAN overlay
  (`ip route get` → `dev flannel.1`) and is unreachable from pods *and* the host, so the
  `GCE_METADATA_HOST` ADC pattern (which IP6 and the litestream example rely on) fails — the existing
  litestream sidecar has been erroring continuously with `no route to host`. EP-47 must resolve this
  before scheduled/on-demand backups can reach `gs://tan-nb-exp-nagare-backups` — likely a node-route
  fix in `infra/` (a more-specific `169.254.169.254/32` route via the primary NIC) or a host-side
  upload step (the engine dump via `kubectl exec`, then upload from the host where native ADC works,
  mirroring `scripts/backup-postgres.sh`). The per-engine *dump commands* are verified and unaffected;
  only the *upload* leg is gated. Evidence: EP-43 Surprises & Discoveries.

- **EP-44 contract refinements EP-45/46/47 must consume (IP1/IP2/IP3 as built).** The renderer
  reproduces EP-43's verified shapes, so the exported helpers EP-45/46 should use are: `enginePort`
  (primary/URL port — ClickHouse is **9000** native, not 8123) and `enginePorts` (named Service ports;
  ClickHouse = native 9000 + http 8123); `engineStartupSecretKeys` (Secret keys wired into the engine
  container = `engineSecretKeys` minus the composed `*_URL`); `defaultEngineVersion` (18 / 8 / 25.8 for
  EP-45 `db create`); `engineMemoryConfig` (ClickHouse `config.d` cap, drives a 4th rendered manifest —
  a `nagare-db-<name>-mem` ConfigMap — so EP-45's apply step must apply the ConfigMap for ClickHouse).
  Resource names: `statefulSetName`/`dbServiceName` = the db name; `dbPvcName` = `nagare-db-<name>-data`;
  `dbConfigMapName` = `nagare-db-<name>-mem`; `dbSecretName` = `nagare-db-<name>`. Evidence: EP-44
  Interfaces & Decision Log.

- **No readinessProbe ⇒ "rollout complete" ≠ "engine ready" (affects EP-44/EP-45).** A connect right
  after `rollout status` returned raced Postgres `initdb` and got `Connection refused`. EP-44's renderer
  should emit a per-engine readinessProbe, and/or EP-45's "wait for ready" must poll the engine
  (`pg_isready` / `redis-cli ping` / ClickHouse `SELECT 1`), not just the StatefulSet rollout.
  Evidence: EP-43 Surprises & Discoveries.


## Decision Log

Record every decomposition or coordination decision made while working on the master plan.

- Decision: Decompose Managed Databases (roadmap Phase 4) into a MasterPlan with six child plans
  (EP-43–EP-48), grouping by functional concern — feasibility spike, typed model + renderer, CLI
  lifecycle, app env injection, backups, docs.
  Rationale: the roadmap itself says "one MasterPlan with child plans for database model, Postgres,
  Redis, backups, and app env integration," and the initiative includes backup integration and a large
  stateful-substrate unknown. The MasterPlan shape lets the high-risk feasibility spike be isolated
  from the pure DSL work so they can proceed in parallel, exactly as MasterPlan 7 did with its
  Knative-PVC spike (EP-33).
  Date: 2026-06-10

- Decision: Treat the three engines (PostgreSQL, Redis, ClickHouse) as a typed `Engine` enum inside one
  model and one renderer and one CLI, rather than as three separate engine plans.
  Rationale: the engines share the entire renderer, CLI surface, env-injection, and backup mechanism;
  splitting by engine would force multiple plans to edit the same functions in the same way, which the
  decomposition principles warn against. The engine is a data dimension like `BuildSpec`'s
  `DockerfileBuild`/`PrebuiltImage`/`NixpacksBuild`. Engine-specific facts (images, ports, backup
  commands, URL templates) live as data within each plan.
  Date: 2026-06-10

- Decision: Make the feasibility-and-substrate spike (EP-43) the first child plan, with no
  dependencies, gating the rest of the initiative's cluster-touching behavior on it as a soft
  dependency.
  Rationale: Nagare has only ever rendered Knative Services; a database needs a new stateful substrate
  (StatefulSet + ClusterIP Service + generated credentials), and ClickHouse's viability on the small
  `e2-standard-2` VM is a genuine open question. The ExecPlan spec encourages an explicit spike to
  de-risk significant unknowns; isolating it prevents EP-44's golden files from encoding an unverified
  guess about what YAML the cluster accepts.
  Date: 2026-06-10

- Decision: Render databases as raw Kubernetes manifests produced by the typed DSL — no Kubernetes
  operator and no Helm chart.
  Rationale: the roadmap allows "direct manifests or a chosen operator/Helm chart," and the repository
  uses neither Helm nor operators for its core (everything is rendered YAML applied with `kubectl`).
  Direct manifests keep databases consistent with every other Nagare resource and avoid a new heavy
  dependency on a single-node personal PaaS. EP-43 confirms feasibility before EP-44 commits the
  renderer.
  Date: 2026-06-10

- Decision: Run databases as Kubernetes StatefulSets (the working assumption, to be confirmed by
  EP-43), not Knative Services.
  Rationale: databases are long-lived, single-replica, stateful workloads with stable identity and
  durable storage; Knative Services scale to zero and are request-driven, which is wrong for a
  database. StatefulSet gives stable pod identity and ordered PVC management. EP-43 verifies this and
  decides PVC-vs-volumeClaimTemplates.
  Date: 2026-06-10

- Decision: Generate database credentials in the CLI at `db create` time and store them only in a
  managed Kubernetes Secret (`nagare-db-<name>`); never store passwords in `Config.hs`.
  Rationale: the typed DSL is pure and deterministic and cannot (and must not) generate randomness or
  hold secrets. The typed `Database` declares desired shape (engine, version, size); the password is a
  runtime credential generated once and referenced by both the database StatefulSet and consuming apps
  via Secret references, consistent with how MasterPlan 5 handles secrets.
  Date: 2026-06-10

- Decision: Reuse MasterPlan 7's storage primitive (the `local-path` `ReadWriteOnce` PVC and the
  `Quantity`/`RetentionPolicy` types), MasterPlan 5's managed-Secret labelling conventions, the GCS
  backup bucket `tan-nb-exp-nagare-backups`, and the `snapshotsToPrune` retention helper, rather than
  introducing new primitives.
  Rationale: these already exist, are tested, and respect the repository's GCP project-isolation rule
  (`tan-nb-exp` only); reusing them keeps the surface small and consistent with sibling initiatives.
  Date: 2026-06-10

- Decision: Inject app→database connection env as a mix of inline literals (host, port, user, db name)
  and Kubernetes Secret references (the composed `DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` and any
  `*_PASSWORD`), via the existing `Nagare.Env.Generated` / `mergeGenerated` mechanism.
  Rationale: variables that embed the password must not be written into a ConfigMap or inline value;
  they render as `valueFrom.secretKeyRef`. Reusing the generated-env merge path keeps app injection
  consistent with the existing `NAGARE_*` predefined variables and respects their precedence rules.
  Date: 2026-06-10

- Decision: Number the initiative MasterPlan as 9 and its children as EP-43 through EP-48 (the next
  sequential numbers; the init scripts assign them, continuing past EP-42, the last child of
  MasterPlan 8).
  Rationale: follows the repository's sequential numbering with no manual renumbering.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result
against the original vision.

**All six child plans (EP-43–EP-48) are Complete (2026-06-10).** Managed databases — the roadmap's
"biggest remaining PaaS gap" — are delivered as designed:

- **EP-43 (spike):** Postgres 18.4, Redis 8.8.0, and ClickHouse 25.8.24.21 (LTS) each verified on the
  live single-node k3s cluster as single-replica StatefulSets with a `local-path` PVC + ClusterIP
  Service + managed Secret, surviving a pod restart, reachable in-cluster, and producing a backup
  artifact. ClickHouse fits the `e2-standard-2` with a `2Gi` limit + `max_server_memory_usage` cap.
- **EP-44 (model + renderer):** the typed `Database`/`Engine`/`EngineVersion`/`DatabaseName` model, its
  JSON round-trip with a `"Database"` kind discriminator, and the StatefulSet/Service/PVC(/ConfigMap)
  renderer reproducing EP-43's verified shapes; the `databases` reference field on `Deployment`.
- **EP-45 (CLI):** `nagarectl db list|create|get|shell|restart|delete` with create-time credential
  generation (IP3) and ordered provisioning.
- **EP-46 (env injection):** apps reference a database by name and receive the per-engine connection env
  (literals + Secret refs) at deploy time.
- **EP-47 (backups):** `db backup`/`db restore`, a daily self-pruning CronJob provisioned at create,
  keep-last-N retention reusing `snapshotsToPrune`, runbook + user-guide integration.
- **EP-48 (docs + examples):** the user guide and three per-engine end-to-end examples.

**Compared to the vision:** the typed-database DSL, generated stateful resources, generated-secret +
app-env injection, the `db` CLI, and scheduled backups with a documented restore drill all landed.
Engine versions were bumped to modern majors (Postgres 18 / Redis 8 / ClickHouse 25.8) per user
direction during implementation.

**The one material gap — flagged, not hidden:** in-pod GCS auth is currently broken cluster-wide (the
metadata IP `169.254.169.254` is routed into the `flannel.1` overlay and is unreachable from pods; the
pre-existing litestream sidecar fails identically). So EP-47's **live backup/restore upload leg is
blocked** until a node-route fix lands (a more-specific `169.254.169.254/32` route via the primary NIC,
or a host-side upload step). Every backup/restore renderer, the GCS layout, retention, and the CLI are
built and unit-tested; only the live upload is gated. This is an infrastructure fix (an `infra/`/NixOS
change), tracked here and in the disaster-recovery runbook, and is the recommended first follow-up.

**Other deferred legs (cluster-access reality, EP-37 precedent):** the live `db create`/`deploy`/restart
end-to-end runs are deferred-with-instructions because the workstation cannot reach the k3s API (IAP
forwards only SSH/22); the exact on-VM commands are in the user guide and example READMEs. The example
apps' images are authored but not live-built.

**Test posture:** 214 `nagare-dsl-test` + 207 `nagarectl-test` pass; all pure model/renderer/CLI/backup
logic is covered offline; no pre-existing golden changed.

**Lessons:** (1) verify live infrastructure assumptions early — the spike (EP-43) caught the metadata
routing regression that would otherwise have surfaced only at EP-47's live backup; (2) the "engine as a
typed dimension" decomposition held up — one model, one renderer, one CLI, one backup mechanism absorbed
all three engines with per-engine data, not parallel code; (3) reconciling later plans against what
earlier siblings *actually shipped* (not their drafts) mattered repeatedly (PGDATA, Redis `--requirepass`,
ClickHouse dual ports + memory cap, the version bump).
