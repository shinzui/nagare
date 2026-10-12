---
id: 44
slug: typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer
title: "Typed Database model and stateful StatefulSet, Service, PVC, and Secret renderer"
kind: exec-plan
created_at: 2026-06-10T14:25:20Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
master_plan: "docs/masterplans/9-managed-databases-for-nagare.md"
---

# Typed Database model and stateful StatefulSet, Service, PVC, and Secret renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare workload is stateless-by-default. A developer writes a typed Haskell file at
`nagare/Config.hs` that imports `Nagare.Dsl.*` and, as the last line of `main`, calls an
`emit*` function (such as `emitDeployment dep`) which prints a JSON description of a
`Deployment` to standard output; `nagarectl` runs that file with `runghc`, captures the JSON,
and turns it into a Knative `Service` — a request-driven container that scales to zero. There
is durable disk for apps (a typed `Volume` renders a `PersistentVolumeClaim`), but there is no
first-class way to declare a *database*. A database is not a request-driven, scale-to-zero
workload: it is a long-lived single process with a stable in-cluster network name, durable
storage, and generated credentials. Two Kubernetes terms used throughout this plan: a
**StatefulSet** is the controller for a workload that needs a stable identity and durable
per-instance storage and that does *not* scale to zero (the right substrate for one database
replica); a **ClusterIP Service** is the in-cluster DNS name other pods use to reach the
database (for example `pg-main.personal.svc.cluster.local`), never exposed to the public
internet.

After this ExecPlan a developer can declare a managed database in the same typed config style
they already use for apps:

```haskell
module Main (main) where

import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database
import Nagare.Dsl.Types (mkNamespace, mkQuantity)

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
  where
    database = do
      n   <- mapLeft show (mkDatabaseName "pg-main")
      v   <- mapLeft show (mkEngineVersion Postgres "16")
      ns  <- mapLeft show (mkNamespace "personal")
      sz  <- mapLeft show (mkQuantity "10Gi")
      Right Database
        { dbName = n, engine = Postgres, version = v, namespace = ns
        , size = sz, resources = Nothing, retention = Retain }
    mapLeft f = either (Left . f) Right
```

and the tooling turns that value into the exact set of Kubernetes manifests a single-node
database needs: a **StatefulSet** running the official engine image at the pinned version with
the data disk mounted at the engine's data path and its required credential environment wired
from a managed Secret; a **ClusterIP Service** giving the database a stable in-cluster DNS name;
and a **PersistentVolumeClaim** for the data (reusing the existing `local-path`,
`ReadWriteOnce` storage convention). Illegal databases — a name that is not a DNS label, an
empty or `latest` version tag, an unsupported engine/version pair — are rejected at config-load
time with a precise error, exactly the way the model already rejects a bad image reference.

This plan is **pure DSL work** under `cli/nagare-dsl/`: it adds types, a JSON round-trip, and a
YAML renderer, all covered by golden tests (tests that compare rendered output byte-for-byte
against a checked-in expected file). It does **not** touch the cluster and does **not** generate
or store any password. The credential **values** are deliberately out of scope: the pure DSL is
deterministic and cannot (and must not) produce randomness, so the renderer references a managed
Secret named `nagare-db-<name>` *by name and by key* but never emits Secret `data`. EP-45
(`docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md`) generates the
password at `db create` time and writes that Secret. This plan is the foundation every later
plan in MasterPlan 9 imports: EP-45 (lifecycle), EP-46 (app env injection), EP-47 (backups),
and EP-48 (docs) all consume the `Database` type, its accessors, and the rendered shapes defined
here.

The observable proof is a passing `cabal test nagare-dsl-test` that: constructs a `Database`
through the smart constructors and rejects bad input; round-trips a `Database` through
`emitDatabase`/`decodeDatabase` to an equal value; rejects a `Database` loaded where a
`Deployment` is expected (and vice-versa) with `UnexpectedKind`; renders Postgres, Redis, and
ClickHouse to StatefulSet/Service/PVC YAML that byte-matches checked-in goldens; and leaves
every existing golden byte-unchanged after adding the new `databases :: ![DatabaseName]` field
to `Deployment`.

## Progress

- [x] M1 (2026-06-10): `Engine`, `Database`, `EngineVersion` in new module `Nagare.Dsl.Database`;
      `DatabaseName` placed in `Nagare.Dsl.Types` (leaf newtype, avoids the import cycle) and
      re-exported from `Nagare.Dsl.Database`; both modules registered in `nagare-dsl.cabal`;
      package builds; unit tests reject bad names, empty/`latest`/`:`-bearing versions, unknown
      engines.
- [x] M2 (2026-06-10): JSON round-trip — `emitDatabase`/`encodeDatabase` in `Config.hs`,
      `decodeDatabase` + a `"Database"` `kind` branch in `Load.hs`, and an envelope guard so
      `decodeDeployment` rejects any kinded object with `UnexpectedKind`; per-engine fixtures under
      `test/fixtures/database/{postgres,redis,clickhouse}/nagare/Config.hs`; round-trip, both
      `UnexpectedKind`, and unknown-engine tests pass.
- [x] M3 (2026-06-10): `renderDatabase` per engine → StatefulSet/Service/PVC (+ ConfigMap for
      ClickHouse) with credential env wired from the managed Secret by `secretKeyRef`; 10 golden
      files under `test/golden/db-*.yaml`; deterministic key ordering via a local `ranks` table; no
      existing golden changed. **Reconciled against EP-43's verified shapes** — see Decision Log.
- [x] M4 (2026-06-10): `databases :: ![DatabaseName]` added to `Deployment` (empty default);
      round-trips through `emit`/`decode`; every dsl fixture/example and the two `nagarectl` test
      Deployment literals updated; all 214 `nagare-dsl-test` + 171 `nagarectl-test` pass; every
      existing golden byte-unchanged.

## Surprises & Discoveries

- **The drafted renderer was a simplification; reconciling with EP-43's verified shapes required
  per-engine specifics the draft omitted.** EP-43 proved each engine needs more than "env from
  Secret": Postgres needs a literal `PGDATA` subdirectory env; Redis needs a `command`/`args`
  override interpolating `--requirepass "$REDIS_PASSWORD"` (the image ignores a password env on its
  own); ClickHouse needs two Service/container ports (native 9000 + HTTP 8123) and a mounted
  `config.d` memory-cap ConfigMap. The renderer and goldens encode all of these (see Decision Log).
  The result is engine-specific data inside one renderer — the intended shape — not three renderers.

- **`enginePort ClickHouse` is 9000 (native), not 8123, and a new `enginePorts` lists both.** The
  draft IP signature said `enginePort -> 8123`; that is the HTTP port, but the `clickhouse://` URL
  and `clickhouse-client` use the native protocol on 9000 (EP-43's `CLICKHOUSE_URL`). So `enginePort`
  returns the URL/primary port (9000 for ClickHouse) and `enginePorts :: Engine -> [(Text, Int)]`
  drives the Service/container port list. EP-46 composes URLs against `enginePort`.

- **Adding a required `databases` field to `Deployment` broke two `nagarectl` test Deployment
  literals** (`cli/nagarectl/test/Spec.hs`), not just the dsl-package literals the plan listed. The
  compiler `not initialised: databases` error named them; both were fixed with `databases = []`. A
  sibling `ServerSite` literal in the same file looked similar (no `healthCheck`) but must NOT get
  the field — `ServerSite` has no `databases`. Watch the discriminator (`runtime`/`healthCheck`) when
  patching literals, not just field order.

## Decision Log

- Decision: Place the new types in a dedicated module `Nagare.Dsl.Database`
  (`cli/nagare-dsl/src/Nagare/Dsl/Database.hs`) and the renderer in
  `Nagare.Dsl.Database.Render` (`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`), rather than
  extending the already-large `Nagare.Dsl.Types`/`Nagare.Dsl.Render`.
  Rationale: a database is a new top-level resource kind, not a field of `Deployment`; isolating
  it keeps the existing app model untouched and gives EP-45/46/47 a single, obvious import.
  `Nagare.Dsl.Database` reuses (does not duplicate) `Namespace`, `Quantity`, `Resources`, and
  `RetentionPolicy` from `Nagare.Dsl.Types`, and `Nagare.Dsl.Database.Render` reuses the
  deterministic key-ordering machinery from `Nagare.Dsl.Render`. The MasterPlan's IP1 names this
  module placement explicitly.
  Date: 2026-06-10

- Decision: Model the three engines as one typed enum `Engine = Postgres | Redis | ClickHouse`
  with `deriving (Generic, Eq, Ord, Show, Enum, Bounded)`, and keep all engine-specific facts
  (image, port, data path, required env keys, Secret key set) as data inside this plan and
  module — never as three separate models or renderers.
  Rationale: the MasterPlan's decisive structural decision is that engines are a typed dimension,
  not a unit of decomposition; the three engines share the entire renderer and JSON shape and
  differ only in data. This mirrors how `BuildSpec` handles
  `PrebuiltImage`/`DockerfileBuild`/`NixpacksBuild` as one model.
  Date: 2026-06-10

- Decision: Add a `DatabaseName` newtype (DNS-1123 label, same character rules as `ServiceName`)
  and an `EngineVersion` newtype validated *per engine* via
  `mkEngineVersion :: Engine -> Text -> Either Text EngineVersion`. Validation keeps it simple:
  reject an empty tag and reject the literal `latest`, and reject a known-unsupported engine
  family. The full per-engine allow-list is intentionally narrow and lives as data so EP-43's
  verified versions can pin it.
  Rationale: a database image tag must be reproducible, so an unpinned `latest` is forbidden (the
  same spirit as `mkImageRef` forbidding an inline tag). Per-engine validation lets the model
  reject, e.g., a ClickHouse tag offered to Postgres. Keeping the allow-list as data lets EP-43's
  feasibility findings tighten it without changing the type.
  Date: 2026-06-10

- Decision: The renderer emits the StatefulSet, the ClusterIP Service, and the PVC, and
  *references* the managed Secret `nagare-db-<name>` by name and key (via
  `valueFrom.secretKeyRef`), but never emits Secret `data` (the password values).
  Rationale: the pure DSL is deterministic and cannot generate randomness; the MasterPlan (IP3)
  fixes that the password is generated once by `nagarectl db create` (EP-45) and lives only in
  the Secret. This plan owns the Secret *name* and *key* contract so the StatefulSet can reference
  it and EP-46/EP-47 can discover it; EP-45 owns the values.
  Date: 2026-06-10

- Decision: Use a standalone PVC (the EP-34 `local-path`/`ReadWriteOnce` convention) rather than
  StatefulSet `volumeClaimTemplates`, *pending EP-43's confirmation*. If EP-43 records that it
  chose `volumeClaimTemplates`, switch to that shape and note the reconciliation here.
  Rationale: a standalone PVC reuses the exact storage primitive MasterPlan 7 verified and lets
  EP-45 provision the disk before the StatefulSet (mirroring how EP-35 applies a PVC before a
  Service). The MasterPlan (IP2) explicitly defers this PVC-vs-volumeClaimTemplates choice to
  EP-43; this plan's goldens are not final until reconciled against EP-43's recorded shape.
  Date: 2026-06-10

- Decision: Stamp the labels `nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`,
  and `nagare.dev/engine: <engine>` on every rendered resource.
  Rationale: EP-45 (delete/restart), EP-47 (backup discovery), and EP-46 (env injection) must
  *discover* a database's resources by label, never re-derive names by hand. The
  `nagare.dev/managed-by: nagarectl` key matches the convention the app renderer and the PVC
  renderer already stamp.
  Date: 2026-06-10

- Decision: Add `databases :: ![DatabaseName]` to `Deployment` with an empty-list default and
  round-trip it through the existing `Config.hs` emit / `Load.hs` decode path.
  Rationale: this is the app→database reference field IP5 builds on. EP-46 reads it to inject
  connection env. An empty list is the backward-compatible default so every existing config and
  fixture compiles unchanged once `databases = []` is added to each full `Deployment` literal.
  Date: 2026-06-10

- Decision (reconciliation with EP-43, implemented): the renderer reproduces EP-43's verified
  per-engine shapes rather than the plan's simplified draft. Concretely: (a) Postgres container gets a
  literal `PGDATA=/var/lib/postgresql/data/pgdata` env (fresh-PVC `lost+found` safety); (b) Redis gets
  `command: [sh,-c]` + `args` running `redis-server --requirepass "$REDIS_PASSWORD" --dir /data --save
  60 1 --appendonly no`, with `REDIS_PASSWORD` wired from the Secret (the image does not read a
  password env on its own); (c) ClickHouse exposes both ports (native 9000 + HTTP 8123) and mounts a
  `nagare-db-<name>-mem` ConfigMap at `/etc/clickhouse-server/config.d/low-memory.xml` capping
  `max_server_memory_usage` at 1.5 GiB, so `renderDatabase` emits a 4th manifest (ConfigMap) for
  ClickHouse only. The startup credential env is `engineStartupSecretKeys` (the Secret keys minus the
  composed `*_URL`, which are for consuming apps).
  Rationale: the draft "env from Secret" alone produces non-functional databases (Redis without auth,
  Postgres tripping on `lost+found`, ClickHouse unreachable on its native port / starving the node).
  EP-43 is the source of truth for the rendered contract (Idempotence & Recovery says so), so the
  goldens encode the verified shapes.
  Date: 2026-06-10

- Decision (versions, per user direction + EP-43): default and golden versions are the modern majors
  Postgres 18, Redis 8, ClickHouse 25.8 (LTS), not the `16`/`7`/`24` the plan was drafted against. A
  `defaultEngineVersion :: Engine -> EngineVersion` exposes these for EP-45's `db create`. ClickHouse's
  `YY.M` calendar versioning passes `mkEngineVersion` (starts with a digit); there is no bare `:25`
  tag. See `docs/plans/43-...` Decision Log.
  Date: 2026-06-10

- Decision: `enginePort` returns the primary/URL port (ClickHouse → 9000 native), and a new
  `enginePorts :: Engine -> [(Text, Int)]` carries the full named-port list the Service and container
  expose (ClickHouse → native 9000 + http 8123). This refines the draft IP signature
  (`enginePort -> 8123`); EP-46 composes connection URLs against `enginePort`.
  Rationale: the `clickhouse://` URL and `clickhouse-client` use the native protocol (9000), so the
  URL port must be 9000; the HTTP port (8123) is still exposed for HTTP clients.
  Date: 2026-06-10

## Outcomes & Retrospective

EP-44 is complete. The typed `Database` model (`Nagare.Dsl.Database`), its JSON round-trip
(`emitDatabase`/`decodeDatabase` with a `"kind":"Database"` discriminator and `UnexpectedKind`
cross-rejection), and the StatefulSet/Service/PVC(/ConfigMap) renderer
(`Nagare.Dsl.Database.Render`) are all in place and golden-tested. The `databases :: ![DatabaseName]`
reference field is on `Deployment` (IP5) and round-trips. All 214 `nagare-dsl-test` and 171
`nagarectl-test` tests pass; no pre-existing golden changed.

What shipped vs. the plan: the model and JSON layer match the draft closely. The renderer is more
engine-specific than the draft because it reproduces EP-43's *verified* shapes (Postgres `PGDATA`,
Redis `--requirepass` command, ClickHouse dual ports + memory ConfigMap) rather than a generic
"env-from-Secret" container — exactly the reconciliation the plan's Idempotence & Recovery section
mandated. Versions are the modern majors (18 / 8 / 25.8) per user direction.

Downstream contracts now fixed for EP-45/46/47: `Database`, its accessors, `dbSecretName`,
`engineSecretKeys`/`engineStartupSecretKeys`, `enginePort`/`enginePorts`, `defaultEngineVersion`, the
resource names (`statefulSetName`/`dbServiceName`/`dbPvcName`/`dbConfigMapName`), and `renderDatabase`.
The credential **values** remain out of scope (EP-45 generates and writes the Secret).

