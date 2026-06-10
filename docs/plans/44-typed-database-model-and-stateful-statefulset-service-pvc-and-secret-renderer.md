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


## Context and Orientation

This section assumes you have never seen this repository. Everything you need is named by full
path. All work happens inside `cli/nagare-dsl/`, the self-contained Haskell library that defines
the typed deployment model and renders Kubernetes/Knative YAML. It is a Cabal 3.0 / GHC2024
package. Build it with `cabal build nagare-dsl` and test it with `cabal test nagare-dsl-test`,
**run from the directory `cli/nagare-dsl/`** (that directory contains the `cabal.project`; there
is no `cabal.project` at the repository root). There is no `just` recipe for these tests, so
`cabal test` from that directory is the canonical command.

A **smart constructor** is a function `mkX :: ... -> Either Text X` that validates its input and
returns `Left "message"` on bad input or `Right value` on good input. The matching newtype's
data constructor is **not exported**, so the only way to obtain an `X` from outside the module is
through `mkX`; an invalid value is therefore unrepresentable. A read-only accessor
`xText :: X -> Text` reads the value back. The canonical example is in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`:

```haskell
newtype ServiceName = ServiceName Text
  deriving stock (Generic, Eq, Ord, Show)

mkServiceName :: Text -> Either Text ServiceName
mkServiceName t
  | Text.null t = Left "service name must not be empty"
  | Text.length t > 63 = Left ("service name too long ...")
  | Text.isPrefixOf "-" t = Left "service name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "service name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("service name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (ServiceName t)

serviceNameText :: ServiceName -> Text
serviceNameText (ServiceName t) = t
```

The private helper `validLabelChar :: Char -> Bool` (lowercase alnum or hyphen) is defined at the
bottom of `Types.hs` but is **not exported**. Because `Nagare.Dsl.Database` is a *separate*
module, you cannot import that helper; copy the same five guards into `mkDatabaseName` (they are
short and self-contained — see Plan of Work), exactly as the existing `mkVolumeName` duplicates
them within `Types.hs`.

### Types you must REUSE (do not duplicate)

All of these are exported from `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`:

- `Namespace` / `mkNamespace` / `defaultNamespace` / `namespaceText` — a Kubernetes namespace
  (DNS label). `defaultNamespace == Namespace "personal"`.
- `Quantity` / `mkQuantity` / `quantityText` — a Kubernetes quantity string such as `"10Gi"`.
  `mkQuantity` validates a number with an optional suffix in
  `m k M G T P E Ki Mi Gi Ti Pi Ei`.
- `Resources (..)` — the record `Resources { cpu, memory, cpuLimit, memoryLimit :: !(Maybe
  Quantity) }`. The app renderer's `resourcesField` (in `Render.hs`) shows how to render its
  `requests`/`limits` sub-blocks; you will reuse the same shape for the StatefulSet container.
- `RetentionPolicy (..)` — `data RetentionPolicy = Retain | Delete deriving (... Enum, Bounded)`.
  Read by EP-45's `db delete` and EP-47.

Your `Database` record's `namespace`, `size`, `resources`, and `retention` fields use these
types directly. Import them into `Nagare.Dsl.Database`; do not introduce parallel types.

### The existing `Deployment` record

`Deployment` (in `Types.hs`) is currently:

```haskell
data Deployment = Deployment
  { name :: !ServiceName
  , namespace :: !Namespace
  , image :: !ImageRef
  , build :: !BuildSpec
  , domains :: ![DomainSpec]
  , port :: !Port
  , env :: !(Map EnvName ScopedEnvVar)
  , resources :: !(Maybe Resources)
  , scale :: !(Maybe Scale)
  , healthCheck :: !(Maybe HealthCheck)
  , volumes :: ![Volume]
  }
  deriving stock (Generic, Eq, Show)
```

In M4 you add `databases :: ![DatabaseName]` (after `volumes`). Because Haskell record
construction names every field, each *full literal* that builds a `Deployment` must add
`databases = []`. Find them with the grep in Concrete Steps. From the EP-34 precedent the
full-literal sites are: `toDeployment` in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`; the
`webService` preset in `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`; the test fixture
`helloDep` in `cli/nagare-dsl/test/Spec.hs`; and the loadable fixture
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`. Apps built through `webService` (most examples)
inherit the default and need no change.

### The serialization layer

`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` is where each resource is turned into JSON. It already
exposes `emitDeployment`/`encodeDeployment`, `emitStaticSite`, and `emitServerSite`, and a
top-level `deploymentJSON :: Deployment -> Value`. Note the `StaticSite` and `ServerSite` JSON
objects carry a top-level `"kind"` discriminator (`"StaticSite"` / `"ServerSite"`), while the
`Deployment` object has **no** `kind` (its absence is what marks it as a `Deployment`). You will
add `emitDatabase`/`encodeDatabase` and a `databaseJSON :: Database -> Value` whose object carries
`"kind" .= ("Database" :: Text)`. You will also add a `"databases"` key to `deploymentJSON`
(M4).

### The loader

`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` decodes the JSON a config prints. Its error type:

```haskell
data LoadError
  = FileNotFound !FilePath
  | CompileError !FilePath !Text
  | MissingBinding !FilePath
  | MarshalError !Text !Text       -- field name, message
  | UnexpectedKind !Text !Text     -- expected kind, actual kind
  deriving stock (Generic, Eq, Show)
```

The discriminator mechanism is `JsonKindEnvelope { jkeKind :: Maybe Text }`: it reads only the
top-level `"kind"` before committing to a full decode. `decodeStaticSite` / `decodeServerSite`
match on that envelope and return `UnexpectedKind "StaticSite" other` when the kind is wrong;
`decodeSite` dispatches `"StaticSite"`/`"ServerSite"` and reports `UnexpectedKind` for anything
else (including a `Deployment`, which has no `"kind"` and so reads as `Nothing`). For each field,
the loader re-runs the smart constructor and maps failure to `MarshalError "<field>" "<message>"`
via the local helper `mapLeft :: (a -> b) -> Either a c -> Either b c`. You will add a
`JsonDatabase` intermediate record with a `FromJSON` instance, a `toDatabase :: JsonDatabase ->
Either LoadError Database`, and `decodeDatabase :: ByteString -> Either LoadError Database` that
checks the envelope's `"kind"` is `"Database"` (else `UnexpectedKind "Database" other`). You will
also make the existing `decodeDeployment`/`decodeStaticSite`/`decodeServerSite` reject a config
that emits a `Database`: `decodeDeployment` currently accepts any object that has the deployment
fields; add an envelope check so a `"Database"`-kinded object yields `UnexpectedKind "Deployment"
"Database"`. (See Plan of Work for the exact, minimal change.)

### The renderer

`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` serializes through `Data.Yaml.Pretty.encodePretty`
with `knativeConfig`, a config whose key comparator (`keyCompare`) consults a `ranks :: [(Text,
Int)]` table to impose a deterministic, *non-alphabetical* key order. Ranks need be distinct only
*within one object*; the same rank is safely reused across unrelated objects. Helpers such as
`resourcesField :: Maybe Resources -> [Pair]` return `[Pair]` and yield `[]` when the field is
absent, so no empty YAML key is emitted. The PVC renderer there
(`renderPersistentVolumeClaims`, `pvcValue`) is the exact shape your database PVC should follow:

```haskell
pvcValue :: Text -> Text -> Volume -> Value
pvcValue app ns v =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata" .= object
        [ "name" .= pvcName app (volumeNameText (v ^. #volName))
        , "namespace" .= ns
        , "labels" .= object
            [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
            , "nagare.dev/app" .= app
            , "nagare.dev/volume" .= volumeNameText (v ^. #volName)
            ]
        ]
    , "spec" .= object
        [ "accessModes" .= toJSON ["ReadWriteOnce" :: Text]
        , "storageClassName" .= ("local-path" :: Text)
        , "resources" .= object ["requests" .= object ["storage" .= quantityText (v ^. #size)]]
        ]
    ]
```

Your new module `Nagare.Dsl.Database.Render` will define its own `knativeConfig`-style config and
`ranks` table for the StatefulSet/Service keys it introduces (`serviceName`, `selector`,
`replicas`, `template`, `containers`, `volumeMounts`, `clusterIP`, `ports`, `targetPort`, and so
on). To keep one source of truth for the key comparator you may either (a) re-export
`knativeConfig` and the rank list pieces you need from `Nagare.Dsl.Render`, or (b) define a local
config and extend its rank table with the database keys. Option (b) is recommended because the
StatefulSet/Service key set is largely disjoint from the Knative key set, so a local table is
clearer; reuse the *approach*, not necessarily the table.

### The test suite

`cli/nagare-dsl/test/Spec.hs` is the tasty test driver (with `LoadSpec`, `ServerSpec`,
`StaticSpec` as `other-modules` in `nagare-dsl.cabal`). It uses **tasty-hunit** for unit/round-trip
tests and **tasty-golden** for golden tests. A golden test is written
`goldenVsString "name" "test/golden/<file>" (pure (fromStrict (renderX fixture)))`: it renders
and compares the bytes to the checked-in file at `test/golden/<file>`, failing with a diff if
they differ. Generate a new golden the first time by running with tasty-golden's accept flag
(`cabal test nagare-dsl-test --test-options=--accept`), then **inspect** the generated file
against the intended shape before committing — never hand-edit a golden to mask a wrong key
order; fix the `ranks` table instead. Helper functions already in `Spec.hs` you will reuse:
`unsafe :: Either Text a -> a` (unwrap a known-good constructor in a fixture),
`assertRight`, `assertLeftContains`, and the `jsonWith*` pattern for building minimal decode
inputs inline.

Existing golden files live in `cli/nagare-dsl/test/golden/`; loadable fixtures live in
`cli/nagare-dsl/test/fixtures/<kind>/nagare/Config.hs` (there are already `nagare/`,
`server-site/`, and `static-site/` fixtures). You will add `test/fixtures/database/<engine>/
nagare/Config.hs` per engine and `test/golden/db-<engine>.statefulset.yaml`,
`db-<engine>.service.yaml`, `db-<engine>.pvc.yaml` per engine.

### Dependency on EP-43 (soft)

This plan is **EP-44**, a child of `docs/masterplans/9-managed-databases-for-nagare.md`. It owns
Integration Point **IP1** (the `Database` type and its JSON shape), Integration Point **IP2** (the
rendered StatefulSet/Service/PVC/Secret shapes), and the app-side `databases` field on
`Deployment` that **IP5** builds on. It *soft*-depends on EP-43
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`), which
runs each engine on the live single-node cluster from raw manifests and records the *verified*
StatefulSet/Service/PVC stanzas, the chosen PVC substrate (standalone PVC vs
`volumeClaimTemplates`), each engine's official image and pinned version, default port, data
path, and required credential environment variables. **Before finalizing M3, open EP-43 and read
its Interfaces section: your goldens must reproduce those verified shapes byte-for-byte.** If
EP-43 is not yet complete when you implement M1/M2, those milestones are pure model work and can
proceed against the engine facts tabulated below; M3's goldens are provisional until reconciled
with EP-43, and you must mark them so in Progress.

The pure model and renderer can be written first against the per-engine facts below, taken as the
working assumption to be confirmed by EP-43:

```text
engine      official image          version (example)  port   data path                    required Secret keys
Postgres    postgres                16                 5432   /var/lib/postgresql/data     POSTGRES_PASSWORD, POSTGRES_USER, POSTGRES_DB, DATABASE_URL
Redis       redis                   7                  6379   /data                        REDIS_PASSWORD, REDIS_URL
ClickHouse  clickhouse/clickhouse-server  24           8123   /var/lib/clickhouse          CLICKHOUSE_PASSWORD, CLICKHOUSE_USER, CLICKHOUSE_URL
```

The StatefulSet wires the engine's startup credential env (e.g. Postgres needs
`POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB`) from the managed Secret `nagare-db-<name>`
via `valueFrom.secretKeyRef` with `name: nagare-db-<name>` and `key:` equal to the variable name.
ClickHouse's memory needs on an `e2-standard-2` VM are an EP-43 finding; until EP-43 records them,
the renderer simply emits whatever `resources` the `Database` carries (and none when `resources`
is `Nothing`), so an author or EP-45 can set a memory limit.


## Plan of Work

The work is four milestones, each independently verifiable with `cabal test nagare-dsl-test` from
`cli/nagare-dsl/`. M1–M3 introduce the new `Database` resource end-to-end (type → JSON → render);
M4 adds the app→database reference field. M4 is independent of M1–M3's renderer and could be done
first, but is placed last so the bulk of the new surface lands before the small backward-compatible
addition.


### Milestone M1 — the typed model, smart constructors, and unit/negative tests

Scope: create the module `Nagare.Dsl.Database` with `Engine`, `DatabaseName`, `EngineVersion`,
and `Database`, register it in the cabal file, and prove the constructors accept good input and
reject bad input. At the end the package builds and unit tests pass; nothing is serialized or
rendered yet.

Create `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`:

```haskell
-- | The typed managed-database model (MasterPlan 9, IP1). A 'Database' names an
-- engine, pins a version, requests a disk size and resource limits, and sets a
-- retention policy. Every constrained field goes through a smart constructor, so
-- an illegal database (bad name, unpinned version, unsupported engine/version)
-- cannot be written down. Reuses 'Namespace', 'Quantity', 'Resources', and
-- 'RetentionPolicy' from "Nagare.Dsl.Types"; it does not duplicate them.
module Nagare.Dsl.Database
  ( -- * Engine
    Engine (..)
  , engineToken
  , parseEngine
  , engineImage
  , enginePort
  , engineDataPath
  , engineSecretKeys

    -- * DatabaseName
  , DatabaseName
  , mkDatabaseName
  , databaseNameText

    -- * EngineVersion
  , EngineVersion
  , mkEngineVersion
  , engineVersionText

    -- * Database
  , Database (..)

    -- * Managed Secret naming (IP3)
  , dbSecretName
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit, isLower)
import Data.Text qualified as Text
import Nagare.Dsl.Types
  ( Namespace
  , Quantity
  , Resources
  , RetentionPolicy
  )

-- | The supported database engines. A typed dimension, not a unit of
-- decomposition: every engine shares the renderer and the JSON shape and differs
-- only in the data tabulated by 'engineImage' / 'enginePort' / 'engineDataPath'
-- / 'engineSecretKeys'.
data Engine = Postgres | Redis | ClickHouse
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | The lowercase token used in JSON, labels, and resource names:
-- @Postgres -> "postgres"@, @Redis -> "redis"@, @ClickHouse -> "clickhouse"@.
engineToken :: Engine -> Text
engineToken Postgres = "postgres"
engineToken Redis = "redis"
engineToken ClickHouse = "clickhouse"

-- | Parse an engine token back (the loader uses this). Unknown tokens are
-- 'Nothing' so the caller can raise a precise 'MarshalError'.
parseEngine :: Text -> Maybe Engine
parseEngine "postgres" = Just Postgres
parseEngine "redis" = Just Redis
parseEngine "clickhouse" = Just ClickHouse
parseEngine _ = Nothing

-- | The official container image repository for an engine (no tag; the tag is
-- the pinned 'EngineVersion'). Confirmed against EP-43's verified manifests.
engineImage :: Engine -> Text
engineImage Postgres = "postgres"
engineImage Redis = "redis"
engineImage ClickHouse = "clickhouse/clickhouse-server"

-- | The default in-container port the engine listens on (the ClusterIP Service
-- targets this).
enginePort :: Engine -> Int
enginePort Postgres = 5432
enginePort Redis = 6379
enginePort ClickHouse = 8123

-- | The in-container path the data volume mounts at.
engineDataPath :: Engine -> Text
engineDataPath Postgres = "/var/lib/postgresql/data"
engineDataPath Redis = "/data"
engineDataPath ClickHouse = "/var/lib/clickhouse"

-- | The keys of the managed credential Secret 'dbSecretName', per engine (IP3).
-- The renderer wires the credential env from these keys; the VALUES are filled
-- by EP-45 at create time, never by this pure renderer.
engineSecretKeys :: Engine -> [Text]
engineSecretKeys Postgres = ["POSTGRES_PASSWORD", "POSTGRES_USER", "POSTGRES_DB", "DATABASE_URL"]
engineSecretKeys Redis = ["REDIS_PASSWORD", "REDIS_URL"]
engineSecretKeys ClickHouse = ["CLICKHOUSE_PASSWORD", "CLICKHOUSE_USER", "CLICKHOUSE_URL"]

-- | A managed-database name: a DNS-1123 label (same character rules as
-- 'Nagare.Dsl.Types.ServiceName'), unique within its namespace. Constructor
-- hidden; use 'mkDatabaseName'.
newtype DatabaseName = DatabaseName Text
  deriving stock (Generic, Eq, Ord, Show)

mkDatabaseName :: Text -> Either Text DatabaseName
mkDatabaseName t
  | Text.null t = Left "database name must not be empty"
  | Text.length t > 63 =
      Left ("database name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "database name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "database name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("database name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (DatabaseName t)

databaseNameText :: DatabaseName -> Text
databaseNameText (DatabaseName t) = t

-- | A pinned engine image tag (e.g. @"16"@, @"7"@, @"24"@). Validated per
-- engine: must be non-empty and must not be the floating tag @"latest"@ (a
-- database image must be reproducible). The per-engine allow-list is
-- intentionally narrow and may be tightened from EP-43's findings.
newtype EngineVersion = EngineVersion Text
  deriving stock (Generic, Eq, Ord, Show)

mkEngineVersion :: Engine -> Text -> Either Text EngineVersion
mkEngineVersion eng t
  | Text.null t = Left "engine version must not be empty"
  | t == "latest" =
      Left "engine version must be pinned, not 'latest'"
  | Text.elem ' ' t = Left ("engine version must not contain spaces: " <> t)
  | Text.elem ':' t = Left ("engine version must not contain ':': " <> t)
  | not (firstCharOk t) =
      Left ("engine version must start with a digit (e.g. \"16\"): " <> t)
  | otherwise = Right (EngineVersion t)
  where
    -- 'eng' is accepted so a future per-engine allow-list (from EP-43) can be
    -- added here without changing the type. Today every engine shares the
    -- "non-empty, not latest, starts with a digit" rule.
    _ = eng
    firstCharOk s = case Text.uncons s of
      Just (c, _) -> isDigit c
      Nothing -> False

engineVersionText :: EngineVersion -> Text
engineVersionText (EngineVersion t) = t

-- | A managed database. There is no hidden constructor for 'Database' — the
-- safety guarantee comes from the field types, not from hiding this record
-- (mirrors 'Nagare.Dsl.Types.Deployment').
data Database = Database
  { dbName :: !DatabaseName
  , engine :: !Engine
  , version :: !EngineVersion
  , namespace :: !Namespace
  , size :: !Quantity
  , resources :: !(Maybe Resources)
  , retention :: !RetentionPolicy
  }
  deriving stock (Generic, Eq, Show)

-- | The deterministic managed-credential Secret name for a database (IP3):
-- @dbSecretName "pg-main" == "nagare-db-pg-main"@. EP-45 writes this Secret;
-- EP-46/EP-47 discover it by this name (and by the IP3 labels). The pure
-- renderer references it but never emits its data.
dbSecretName :: Text -> Text
dbSecretName n = "nagare-db-" <> n

-- Internal: show as Text for error messages (this module cannot import the
-- non-exported 'tshow' in "Nagare.Dsl.Types").
tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Internal: a valid RFC 1123 label character (lowercase alnum or hyphen).
validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'
```

Register the module in `cli/nagare-dsl/nagare-dsl.cabal` by adding `Nagare.Dsl.Database` to the
library's `exposed-modules` (the renderer module `Nagare.Dsl.Database.Render` is added in M3).

Add unit and negative tests. The cleanest place is a new `databaseTests :: [TestTree]` group in
`cli/nagare-dsl/test/Spec.hs`, added to the top-level `testGroup` list in `main` (import
`Nagare.Dsl.Database`):

```haskell
, testGroup "Nagare.Dsl.Database (EP-44)" databaseTests
```

```haskell
databaseTests :: [TestTree]
databaseTests =
  [ testGroup "mkDatabaseName"
      [ testCase "accepts pg-main" $ assertRight (mkDatabaseName "pg-main")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkDatabaseName "")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkDatabaseName "PG")
      , testCase "rejects leading hyphen" $ assertLeftContains "hyphen" (mkDatabaseName "-x")
      ]
  , testGroup "mkEngineVersion"
      [ testCase "accepts 16 for Postgres" $ assertRight (mkEngineVersion Postgres "16")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkEngineVersion Postgres "")
      , testCase "rejects latest" $ assertLeftContains "pinned" (mkEngineVersion Redis "latest")
      , testCase "rejects a tag with a colon" $
          assertLeftContains "':'" (mkEngineVersion Postgres "16:beta")
      ]
  , testGroup "engine facts"
      [ testCase "engineToken round-trips through parseEngine" $
          mapM (\e -> parseEngine (engineToken e)) [minBound .. maxBound]
            @?= Just [Postgres, Redis, ClickHouse]
      , testCase "parseEngine rejects an unknown token" $
          parseEngine "mysql" @?= Nothing
      ]
  ]
```

Acceptance for M1: from `cli/nagare-dsl/`, `cabal build nagare-dsl` succeeds and
`cabal test nagare-dsl-test` passes the new `mkDatabaseName`, `mkEngineVersion`, and `engine
facts` groups. No serialization or rendering exists yet.


### Milestone M2 — JSON round-trip with a `Database` config kind

Scope: emit a `Database` as JSON with a `"kind": "Database"` discriminator, decode it back with
the loader (re-running every smart constructor), and prove the value survives the
emit→decode round-trip and that loading the wrong kind fails with `UnexpectedKind`. At the end a
`Database` encodes to JSON and decodes back to an equal value; a `Database` loaded where a
`Deployment` is expected (and the reverse) is rejected precisely; and a per-engine fixture config
loads.

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, import `Nagare.Dsl.Database`, add `emitDatabase`
and `encodeDatabase` to the module export list, and define them plus the JSON shape:

```haskell
-- | Serialize a 'Database' to JSON and write it to stdout. Call this as the last
-- line of a database project's @Config.hs@ @main@. The top-level
-- @"kind": "Database"@ discriminator lets the loader dispatch and report a
-- precise 'UnexpectedKind' if a Database config is run under @nagarectl deploy@.
emitDatabase :: Database -> IO ()
emitDatabase db = LBS.putStr (encodeDatabase db)

-- | The exact JSON bytes 'emitDatabase' writes (exposed for the round-trip test).
encodeDatabase :: Database -> LBS.ByteString
encodeDatabase = encode . databaseJSON

databaseJSON :: Database -> Value
databaseJSON db =
  object
    [ "kind" .= ("Database" :: Text)
    , "name" .= databaseNameText (db ^. #dbName)
    , "engine" .= engineToken (db ^. #engine)
    , "version" .= engineVersionText (db ^. #version)
    , "namespace" .= namespaceText (db ^. #namespace)
    , "size" .= quantityText (db ^. #size)
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "retention" .= retentionToken (db ^. #retention)
    ]
  where
    res = db ^. #resources
    retentionToken Retain = "Retain" :: Text
    retentionToken Delete = "Delete"
```

(`RetentionPolicy`'s constructors `Retain`/`Delete` come from `Nagare.Dsl.Types`, already
imported in `Config.hs`.) The four flat resource keys mirror exactly how `deploymentJSON`
serializes `Resources`, so the loader can reuse the same `toResources`-style step.

In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, import `Nagare.Dsl.Database`, add `decodeDatabase`
to the export list, and add the intermediate record, instance, marshaller, and decoder. Place
them near the existing `JsonDeployment`/`toDeployment` block:

```haskell
data JsonDatabase = JsonDatabase
  { jdbName :: !Text
  , jdbEngine :: !Text
  , jdbVersion :: !Text
  , jdbNamespace :: !Text
  , jdbSize :: !Text
  , jdbCpuRequest :: !(Maybe Text)
  , jdbMemoryRequest :: !(Maybe Text)
  , jdbCpuLimit :: !(Maybe Text)
  , jdbMemoryLimit :: !(Maybe Text)
  , jdbRetention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDatabase where
  parseJSON = withObject "Database" $ \o ->
    JsonDatabase
      <$> o .: "name"
      <*> o .: "engine"
      <*> o .: "version"
      <*> o .: "namespace"
      <*> o .: "size"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "retention"

toDatabase :: JsonDatabase -> Either LoadError Database
toDatabase j = do
  name' <- mapLeft (MarshalError "name") $ mkDatabaseName (jdbName j)
  eng' <- case parseEngine (jdbEngine j) of
    Just e -> Right e
    Nothing -> Left (MarshalError "engine" ("unknown engine: " <> jdbEngine j))
  ver' <- mapLeft (MarshalError "version") $ mkEngineVersion eng' (jdbVersion j)
  ns' <- mapLeft (MarshalError "namespace") $ mkNamespace (jdbNamespace j)
  size' <- mapLeft (MarshalError "size") $ mkQuantity (jdbSize j)
  res' <- toDbResources j
  ret' <- case fromMaybe "Retain" (jdbRetention j) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "retention" ("unknown retention policy: " <> other))
  Right Database
    { dbName = name', engine = eng', version = ver', namespace = ns'
    , size = size', resources = res', retention = ret' }

toDbResources :: JsonDatabase -> Either LoadError (Maybe Resources)
toDbResources j =
  case (jdbCpuRequest j, jdbMemoryRequest j, jdbCpuLimit j, jdbMemoryLimit j) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (mapLeft (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (mapLeft (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (mapLeft (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (mapLeft (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a database config emits (via
-- 'Nagare.Dsl.Config.emitDatabase') into a validated 'Database'. The top-level
-- @kind@ is checked first: a missing or non-@Database@ kind is 'UnexpectedKind'.
decodeDatabase :: ByteString -> Either LoadError Database
decodeDatabase bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right envelope -> case jkeKind envelope of
      Just "Database" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode database: " <> Text.pack perr))
        Right jdb -> toDatabase jdb
      Just other -> Left (UnexpectedKind "Database" other)
      Nothing -> Left (UnexpectedKind "Database" "<none>")
```

(`Resources`, `mkQuantity`, `mkNamespace`, `Retain`/`Delete`, `fromMaybe` are already in scope in
`Load.hs`.)

Make `decodeDeployment` reject a `Database`. The current `decodeDeployment` decodes any object
with the deployment fields directly; a `Database` object lacks the deployment-required fields
(`port`, `env`) so today it would fail with a generic aeson `MarshalError "json"`. Make the
failure precise by checking the envelope first:

```haskell
decodeDeployment bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right envelope -> case jkeKind envelope of
      Nothing -> case eitherDecodeStrict bs of   -- a Deployment carries no "kind"
        Left perr ->
          Left (MarshalError "json" ("could not decode deployment: " <> Text.pack perr))
        Right jd -> toDeployment jd
      Just other -> Left (UnexpectedKind "Deployment" other)
```

This keeps every existing `Deployment` (no `kind`) decoding exactly as before while making a
`Database`/`StaticSite`/`ServerSite` config loaded under `nagarectl deploy` fail with
`UnexpectedKind "Deployment" "Database"` (etc.). Verify this does not break the existing
`Deployment` round-trip tests (the `Deployment` JSON has no `"kind"`, so it takes the `Nothing`
branch).

Add a loadable fixture per engine at `cli/nagare-dsl/test/fixtures/database/<engine>/nagare/
Config.hs` (engines: `postgres`, `redis`, `clickhouse`). The Postgres one, modelled on the hello
fixture:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Nagare.Dsl.Config (emitDatabase)
import Nagare.Dsl.Database
import Nagare.Dsl.Types (Resources (..), RetentionPolicy (..), mkNamespace, mkQuantity)

database :: Either String Database
database = do
  n   <- mapLeft show (mkDatabaseName "pg-main")
  v   <- mapLeft show (mkEngineVersion Postgres "16")
  ns  <- mapLeft show (mkNamespace "personal")
  sz  <- mapLeft show (mkQuantity "10Gi")
  Right Database
    { dbName = n, engine = Postgres, version = v, namespace = ns
    , size = sz, resources = Nothing, retention = Retain }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case database of
  Left err -> ioError (userError err)
  Right db -> emitDatabase db
```

The Redis and ClickHouse fixtures are identical except `engine`, `version`, and `dbName`
(`redis-cache`/`7`/`Redis`, `analytics`/`24`/`ClickHouse`).

Add round-trip and kind tests to `databaseTests` in `Spec.hs`. Reuse `unsafe` and `decodeDatabase`
(import it from `Nagare.Dsl.Load` and `loadDatabase` is not needed; you can also exercise the
fixture directly with `loadDatabase` if you add it, but a `decodeDatabase` round-trip is
sufficient and cluster-free). Use a fixture `Database` built in the test module:

```haskell
pgDb :: Database
pgDb = Database
  { dbName = unsafe (mkDatabaseName "pg-main")
  , engine = Postgres
  , version = unsafe (mkEngineVersion Postgres "16")
  , namespace = unsafe (mkNamespace "personal")
  , size = unsafe (mkQuantity "10Gi")
  , resources = Nothing
  , retention = Retain
  }
```

```haskell
, testCase "database survives emit -> decode round-trip" $
    decodeDatabase (toStrict (encodeDatabase pgDb)) @?= Right pgDb
, testCase "decoding a Database as a Deployment is UnexpectedKind" $
    case decodeDeployment (toStrict (encodeDatabase pgDb)) of
      Left (UnexpectedKind "Deployment" "Database") -> pure ()
      other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
, testCase "decoding a Deployment as a Database is UnexpectedKind" $
    case decodeDatabase (toStrict (encodeDeployment helloDep)) of
      Left (UnexpectedKind "Database" "<none>") -> pure ()
      other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
, testCase "unknown engine rejected as MarshalError engine" $
    case decodeDatabase
      "{\"kind\":\"Database\",\"name\":\"x\",\"engine\":\"mysql\",\"version\":\"8\",\"namespace\":\"personal\",\"size\":\"1Gi\"}" of
      Left (MarshalError "engine" _) -> pure ()
      other -> assertFailure ("expected MarshalError engine, got: " <> show other)
```

(Import `encodeDatabase` and `emitDatabase` is not needed in tests; `encodeDeployment`/`helloDep`
are already used in `Spec.hs`.)

Acceptance for M2: from `cli/nagare-dsl/`, `cabal test nagare-dsl-test` passes the round-trip,
both `UnexpectedKind` tests, and the unknown-engine test; every existing test (including the
`Deployment` and `ServerSite` round-trips) still passes.


### Milestone M3 — the renderer: StatefulSet, ClusterIP Service, PVC, Secret references, goldens

Scope: render, per `Database`, a StatefulSet (one replica) running the engine image at the pinned
version with the data PVC mounted at the engine data path and the credential env wired from the
managed Secret; a ClusterIP Service; and a standalone PVC. Stamp the IP3 labels. Lock the output
with golden files per engine, with deterministic key ordering, and confirm no existing golden
changed. **Reconcile every golden against EP-43's verified shapes before finalizing.**

Create `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` and register it in
`nagare-dsl.cabal` `exposed-modules`. The module's public surface:

```haskell
-- | Render a 'Database' to its Kubernetes manifest set (MasterPlan 9, IP2):
-- a StatefulSet, a ClusterIP Service, and a PersistentVolumeClaim. The managed
-- credential Secret 'dbSecretName' is REFERENCED by name and key (via
-- valueFrom.secretKeyRef) but its data is NOT emitted — the password is
-- generated and written by EP-45 at create time. Every resource carries the IP3
-- labels nagare.dev/managed-by, nagare.dev/database, nagare.dev/engine so EP-45
-- and EP-47 can discover them.
module Nagare.Dsl.Database.Render
  ( renderDatabase
  , renderStatefulSet
  , renderDatabaseService
  , renderDatabasePvc
  , statefulSetName
  , dbServiceName
  , dbPvcName
  ) where
```

Define the deterministic resource names (the single owners; EP-45/47 must discover by label, not
re-derive):

```haskell
-- | StatefulSet name for a database (= the database name).
statefulSetName :: Text -> Text
statefulSetName n = n

-- | ClusterIP Service name = the database name (stable in-cluster DNS).
dbServiceName :: Text -> Text
dbServiceName n = n

-- | PVC name for a database's data disk.
dbPvcName :: Text -> Text
dbPvcName n = "nagare-db-" <> n <> "-data"
```

The top-level function builds the three manifests in apply order (PVC, then Service, then
StatefulSet — the order EP-45 will apply them, with the Secret applied before all by EP-45):

```haskell
renderDatabase :: Database -> [ByteString]
renderDatabase db =
  [ renderDatabasePvc db
  , renderDatabaseService db
  , renderStatefulSet db
  ]
```

Each `renderX` is `YP.encodePretty dbConfig (xValue db)`, where `dbConfig` is a
`Data.Yaml.Pretty.Config` whose comparator imposes the StatefulSet/Service/PVC key order via a
local `ranks` table (model it on `Nagare.Dsl.Render.knativeConfig`/`keyCompare`; reuse the
*approach*). The standard labels helper, applied to every resource's `metadata.labels`:

```haskell
dbLabels :: Database -> Value
dbLabels db =
  object
    [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
    , "nagare.dev/database" .= databaseNameText (db ^. #dbName)
    , "nagare.dev/engine" .= engineToken (db ^. #engine)
    ]
```

The **StatefulSet** (`statefulSetValue`): `apiVersion: apps/v1`, `kind: StatefulSet`,
`metadata` (name = `statefulSetName name`, namespace, the labels), and a `spec` with
`serviceName: <dbServiceName>`, `replicas: 1`, a `selector.matchLabels` of `nagare.dev/database:
<name>`, and a `template` whose `metadata.labels` are the standard labels and whose `spec.
containers` has one container: `name: <engineToken>`, `image: <engineImage>:<engineVersionText>`,
`ports: [{containerPort: <enginePort>}]`, the credential `env` wired from the Secret (one entry
per *startup* env key — for Postgres `POSTGRES_PASSWORD`/`POSTGRES_USER`/`POSTGRES_DB`; for Redis
`REDIS_PASSWORD`; for ClickHouse `CLICKHOUSE_PASSWORD`/`CLICKHOUSE_USER` — i.e. the keys the
engine *reads at startup*, which is `engineSecretKeys` minus the composed `*_URL`), a
`resources` block from `db ^. #resources` (reuse the `requests`/`limits` shape of
`Nagare.Dsl.Render.resourcesField`; emit nothing when `resources` is `Nothing`), and
`volumeMounts: [{name: data, mountPath: <engineDataPath>}]`. The pod's `volumes` references the
PVC: `volumes: [{name: data, persistentVolumeClaim: {claimName: <dbPvcName>}}]`. The credential
env entry shape (matching the app renderer's `valueFrom.secretKeyRef`):

```haskell
secretEnvEntry :: Text -> Text -> Value
secretEnvEntry secret key =
  object
    [ "name" .= key
    , "valueFrom" .= object
        [ "secretKeyRef" .= object ["name" .= secret, "key" .= key] ]
    ]
```

with `secret = dbSecretName (databaseNameText (db ^. #dbName))`. Define a per-engine
`startupEnvKeys :: Engine -> [Text]` next to `engineSecretKeys` (or as a `where`-helper here) so
the composed `*_URL` keys are referenced by the Secret contract but not injected as engine
startup env. **Confirm the exact startup env set against EP-43** — if EP-43 records that an engine
needs a different env wiring (for example ClickHouse using a config file rather than env), encode
that and note it in the Decision Log.

The **ClusterIP Service** (`serviceValue`): `apiVersion: v1`, `kind: Service`, `metadata`
(name = `dbServiceName name`, namespace, labels), `spec` with `type: ClusterIP`, a `selector` of
`nagare.dev/database: <name>`, and `ports: [{port: <enginePort>, targetPort: <enginePort>}]`.

The **PVC** (`pvcValue`): identical shape to `Nagare.Dsl.Render.pvcValue` (the example in
Context) but with name = `dbPvcName name`, the IP3 database labels, and `storage = quantityText
(db ^. #size)`, `accessModes: [ReadWriteOnce]`, `storageClassName: local-path`. If EP-43 chose
`volumeClaimTemplates` instead of a standalone PVC, move this stanza into the StatefulSet's
`spec.volumeClaimTemplates` and have `renderDatabase` emit only the StatefulSet + Service; record
that change in the Decision Log and update the goldens.

Add golden tests to `databaseTests` in `Spec.hs`, one set per engine (import the render module).
For Postgres:

```haskell
, goldenVsString "renderStatefulSet postgres" "test/golden/db-postgres.statefulset.yaml"
    (pure (fromStrict (renderStatefulSet pgDb)))
, goldenVsString "renderDatabaseService postgres" "test/golden/db-postgres.service.yaml"
    (pure (fromStrict (renderDatabaseService pgDb)))
, goldenVsString "renderDatabasePvc postgres" "test/golden/db-postgres.pvc.yaml"
    (pure (fromStrict (renderDatabasePvc pgDb)))
```

with `redisDb` and `clickhouseDb` fixtures and the matching `db-redis.*`/`db-clickhouse.*`
goldens. The intended Postgres StatefulSet golden (reconcile with EP-43 before committing):

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg-main
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/database: pg-main
    nagare.dev/engine: postgres
spec:
  serviceName: pg-main
  replicas: 1
  selector:
    matchLabels:
      nagare.dev/database: pg-main
  template:
    metadata:
      labels:
        nagare.dev/managed-by: nagarectl
        nagare.dev/database: pg-main
        nagare.dev/engine: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nagare-db-pg-main
              key: POSTGRES_PASSWORD
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: nagare-db-pg-main
              key: POSTGRES_USER
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: nagare-db-pg-main
              key: POSTGRES_DB
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: nagare-db-pg-main-data
```

The intended Postgres Service golden:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pg-main
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/database: pg-main
    nagare.dev/engine: postgres
spec:
  type: ClusterIP
  selector:
    nagare.dev/database: pg-main
  ports:
  - port: 5432
    targetPort: 5432
```

The intended Postgres PVC golden:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-db-pg-main-data
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/database: pg-main
    nagare.dev/engine: postgres
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
```

Generate the goldens with `cabal test nagare-dsl-test --test-options=--accept`, inspect each
against the intended shape, fix the `ranks` table (not the golden) until the key order matches,
then commit. **Reconcile with EP-43**: open
`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`, read its
Interfaces section, and confirm the image, version, port, data path, env wiring, and PVC
substrate match. Record the reconciliation in the Decision Log. If EP-43 is not yet complete,
mark the goldens provisional in Progress.

Acceptance for M3: `cabal test nagare-dsl-test` passes; the nine new goldens (three per engine)
exist and match the intended shapes; the Secret is referenced by name `nagare-db-<name>` and is
*not* emitted as a manifest; and no pre-existing golden changed (the database renderer touches no
app/Service/PVC code path).


### Milestone M4 — the `databases` field on `Deployment` (IP5)

Scope: add `databases :: ![DatabaseName]` to `Deployment` with an empty default, round-trip it
through the existing emit/decode path, and prove every existing fixture/example still compiles
and every existing golden is byte-unchanged. At the end an app can name the databases it uses;
EP-46 will read this field to inject connection env.

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, the `Database` types live in a *separate* module, so
to avoid a module import cycle (`Types` must not import `Database`, since `Database` imports
`Types`) the `databases` field uses `DatabaseName`, which is defined in `Nagare.Dsl.Database`.
Resolve this by **moving `DatabaseName` (and its `mkDatabaseName`/`databaseNameText`) into
`Nagare.Dsl.Types`** and re-exporting it from `Nagare.Dsl.Database`. `DatabaseName` is a leaf
newtype with no dependency on `Engine` or `Database`, so it belongs naturally beside `VolumeName`
in `Types.hs`; `Nagare.Dsl.Database` then `import`s and re-exports it. Make this move in M1 if you
foresee M4 (cleanest), or as the first step of M4. Update the `databaseTests` import accordingly
(it can keep importing from `Nagare.Dsl.Database` via the re-export).

Then add the field to `Deployment` (after `volumes`):

```haskell
  -- | Names of managed databases this app connects to (IP5). Empty (the
  -- backward-compatible default) means the app uses no managed database. EP-46
  -- resolves each name to its in-cluster DNS and managed Secret and injects the
  -- connection env at deploy time.
  , databases :: ![DatabaseName]
```

and export `DatabaseName`, `mkDatabaseName`, `databaseNameText` from `Types.hs` (add a
`-- * DatabaseName` export block).

Add `databases = []` to every full `Deployment` literal: `toDeployment` in `Load.hs`,
`webService` in `Presets.hs`, `helloDep` in `Spec.hs`, and the fixture
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`. Run the grep in Concrete Steps to confirm the
list is complete before building; the compiler error `Fields of 'Deployment' not initialised:
databases` names any literal you missed.

Serialize the field. In `Config.hs` `deploymentJSON`, add (after `"volumes"`):

```haskell
    , "databases" .= map databaseNameText (dep ^. #databases)
```

In `Load.hs`, add `jdDatabases :: ![Text]` to `JsonDeployment` and its `FromJSON` instance with a
default-empty parse (`<*> o .:? "databases" .!= []`) so older JSON without the key still decodes,
a `toDatabaseNames :: [Text] -> Either LoadError [DatabaseName]` step that re-runs
`mkDatabaseName` (mapping failure to `MarshalError "databases"`), and set `databases = dbRefs'`
in the `Deployment {...}` literal in `toDeployment`.

Add a round-trip test to `databaseTests` (or `volumeTests`) in `Spec.hs`:

```haskell
, testCase "deployment with a database reference round-trips" $ do
    let dep = helloDep { databases = [unsafe (mkDatabaseName "pg-main")] }
    decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
```

Acceptance for M4: `cabal test nagare-dsl-test` passes, including the database-reference
round-trip; the existing `loadDeployment hello` test and **every existing golden** are
byte-unchanged (the new field defaults to `[]` and `deploymentJSON` emits `"databases": []`,
which the loader reads back to `[]`; the renderer does not read `databases`, so no Service/PVC
golden changes). Confirm by running the full suite and observing zero golden diffs.


## Concrete Steps

All commands run from the package directory unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
```

Build the package after each milestone:

```bash
cabal build nagare-dsl 2>&1 | tail -20
```

A missing-field error after M4 looks like this and names the literal still needing `databases`:

```text
error: [GHC-???] Fields of 'Deployment' not initialised: databases
```

Before M4's edits, find every full `Deployment` literal (run from the repo root):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
grep -rn "Deployment$" --include=*.hs cli cluster/examples | grep -v "::"
grep -rln "= webService\|webService " cluster/examples cli/nagare-dsl/test
```

Apps built through `webService` need no change (the preset literal carries the default). Apps
that write a full record literal need `databases = []` added.

Run the full test suite at any milestone:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test 2>&1 | tail -30
```

Expected success tail:

```text
All N tests passed (0.NNs)
Test suite nagare-dsl-test: PASS
```

Generate (accept) new golden files for M3, then inspect before committing:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test --test-options=--accept 2>&1 | tail -30
git status --short cli/nagare-dsl/test/golden
git diff --stat cli/nagare-dsl/test/golden    # confirm ONLY new db-*.yaml files appear
```

Read each generated golden and compare it to the intended shape in M3. If the key order is wrong,
fix the `ranks` table in `Nagare.Dsl.Database.Render` and re-accept; do not hand-edit goldens.

Exercise a fixture config end-to-end (proves the config-as-program path), for the Postgres
fixture (this compiles and runs the fixture with `runghc` exactly as the loader does):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
runghc -XGHC2024 -itest/fixtures/database/postgres/nagare \
  test/fixtures/database/postgres/nagare/Config.hs
```

Expected: a single line of JSON beginning `{"kind":"Database","name":"pg-main","engine":
"postgres",...}`.

**Git trailers.** Follow Conventional Commits and commit directly to the current branch (no
feature branch). Every commit for this plan must carry these trailers:

```text
MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md
Intention: intention_01ktryacjaezzbezmkt5j93abq
```

Example commit message:

```text
feat(dsl): EP-44 M1 typed Database model and smart constructors

Add Nagare.Dsl.Database with Engine, DatabaseName, EngineVersion, and the
Database record; register the module; unit-test name/version/engine validation.

MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md
Intention: intention_01ktryacjaezzbezmkt5j93abq
```

Commit at the end of each milestone (M1–M4), updating the Progress checklist in this plan before
committing.


## Validation and Acceptance

The change is effective beyond compilation in four observable ways, each a test you can run from
`cli/nagare-dsl/`:

1. **Construction validity.** `cabal test nagare-dsl-test` passes the `mkDatabaseName` /
   `mkEngineVersion` / `engine facts` groups: `mkDatabaseName "pg-main"` is `Right`,
   `mkDatabaseName "PG"` is `Left` containing "invalid", `mkEngineVersion Redis "latest"` is
   `Left` containing "pinned", and `parseEngine "mysql"` is `Nothing`.

2. **JSON round-trip and kind discrimination.** `decodeDatabase (encodeDatabase pgDb) == Right
   pgDb`; `decodeDeployment (encodeDatabase pgDb) == Left (UnexpectedKind "Deployment"
   "Database")`; and `decodeDatabase (encodeDeployment helloDep) == Left (UnexpectedKind
   "Database" "<none>")`. Run the Postgres fixture with `runghc` (command above) and confirm it
   prints a `{"kind":"Database",...}` line.

3. **Rendered shapes.** The nine golden tests (StatefulSet/Service/PVC for Postgres, Redis,
   ClickHouse) pass. Inspect the Postgres StatefulSet golden and confirm:
   `image: postgres:16`; `replicas: 1`; the data volume mounts at `/var/lib/postgresql/data`;
   each credential env entry is a `valueFrom.secretKeyRef` pointing at `name: nagare-db-pg-main`;
   and **no** `Secret` manifest with a `data:` block is emitted anywhere. Confirm the Service is
   `type: ClusterIP` on port 5432 and the PVC requests `10Gi` of `local-path` `ReadWriteOnce`
   storage. The Postgres StatefulSet golden is shown in full in M3.

4. **Backward compatibility.** After M4, `cabal test nagare-dsl-test` is green and
   `git diff --stat cli/nagare-dsl/test/golden` shows only the new `db-*.yaml` files — every
   existing golden (`hello.service.yaml`, `hello-volume.*`, `rich.*`, `server-site*.*`,
   `static-site*.*`, `preset-app-*`) is byte-unchanged. The `loadDeployment hello` test still
   returns `Right helloDep`, and the database-reference round-trip test passes.

The exact test command is `cabal test nagare-dsl-test` (run from `cli/nagare-dsl/`); interpret a
trailing `All N tests passed` / `PASS` as success and any `FAIL`/`golden diff` block as the
specific failing case to fix.


## Idempotence and Recovery

All work in this plan is pure Haskell and golden tests; there is no cluster state, no network
call, and no destructive operation. Every step is safely repeatable:

- Re-running `cabal build` / `cabal test` is idempotent.
- Re-running the accept step (`--test-options=--accept`) re-writes the golden files from the
  current renderer output; it never deletes unrelated files. If an accept run produced a wrong
  golden (e.g. a bad key order you only noticed later), fix the `ranks` table and re-accept — the
  golden is overwritten, not appended. Use `git checkout -- cli/nagare-dsl/test/golden/<file>` to
  discard a bad generated golden and `git status` to confirm no existing golden was touched.
- The `databases` field addition (M4) is additive and defaults to `[]`; if a build fails because
  a literal lacks the field, the compiler names it. There is no migration of on-disk data.
- If you discover mid-implementation that EP-43's verified shapes differ from the intended
  goldens here (different image/version/port/data path/env or `volumeClaimTemplates`), update the
  renderer and re-accept the goldens, and record the reconciliation in the Decision Log — the
  goldens are the source of truth for the rendered contract and must match EP-43.


## Interfaces and Dependencies

Libraries and modules used, and why: `aeson` (already a dependency) for `databaseJSON`/`FromJSON
JsonDatabase`; `yaml` (`Data.Yaml.Pretty`) for deterministic-ordered rendering, mirroring
`Nagare.Dsl.Render`; `text`, `containers`, `bytestring` (already present). **No new
`build-depends` is required.** The cabal change is purely adding `Nagare.Dsl.Database` and
`Nagare.Dsl.Database.Render` to the library's `exposed-modules`.

This plan's *soft* dependency is **EP-43**
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`): its
Interfaces section records the *verified* per-engine image, pinned version, port, data path,
credential env wiring, and PVC substrate (standalone PVC vs `volumeClaimTemplates`). The M3
goldens must reproduce those shapes byte-for-byte; until EP-43 is complete, M3's goldens are
provisional and the per-engine facts tabulated in Context and Orientation are the working
assumption.

Public type signatures, module paths, and JSON field names that exist at the end of this plan
(EP-45, EP-46, EP-47, and EP-48 depend on these — do not change them without updating the
MasterPlan Integration Points):

Module `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`:

```haskell
data Engine = Postgres | Redis | ClickHouse
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

engineToken             :: Engine -> Text          -- "postgres" | "redis" | "clickhouse"
parseEngine             :: Text -> Maybe Engine
engineImage             :: Engine -> Text          -- "postgres" | "redis" | "clickhouse/clickhouse-server"
enginePort              :: Engine -> Int           -- primary/URL port: 5432 | 6379 | 9000 (ClickHouse native)
enginePorts             :: Engine -> [(Text, Int)] -- named Service/container ports; ClickHouse = native 9000 + http 8123
engineDataPath          :: Engine -> Text          -- "/var/lib/postgresql/data" | "/data" | "/var/lib/clickhouse"
engineSecretKeys        :: Engine -> [Text]        -- the managed-Secret key set per engine (IP3)
engineStartupSecretKeys :: Engine -> [Text]        -- Secret keys wired into the engine container (engineSecretKeys minus *_URL)
engineMemoryConfig      :: Engine -> Maybe Text     -- ClickHouse config.d memory cap XML; Nothing for others
defaultEngineVersion    :: Engine -> EngineVersion  -- modern defaults: Postgres 18, Redis 8, ClickHouse 25.8

-- DatabaseName lives in Nagare.Dsl.Types after M4 and is re-exported here.
mkDatabaseName    :: Text -> Either Text DatabaseName     -- DNS-1123 label
databaseNameText  :: DatabaseName -> Text

mkEngineVersion   :: Engine -> Text -> Either Text EngineVersion  -- rejects empty/"latest"
engineVersionText :: EngineVersion -> Text

data Database = Database
  { dbName    :: !DatabaseName
  , engine    :: !Engine
  , version   :: !EngineVersion
  , namespace :: !Namespace          -- reused from Nagare.Dsl.Types
  , size      :: !Quantity           -- reused from Nagare.Dsl.Types
  , resources :: !(Maybe Resources)  -- reused from Nagare.Dsl.Types
  , retention :: !RetentionPolicy    -- reused from Nagare.Dsl.Types
  }
  deriving stock (Generic, Eq, Show)

dbSecretName :: Text -> Text         -- "nagare-db-<name>" (IP3; EP-45 writes it, EP-46/47 read it)
```

Module `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`:

```haskell
renderDatabase        :: Database -> [ByteString]   -- [PVC, Service, StatefulSet] manifests
renderStatefulSet     :: Database -> ByteString
renderDatabaseService :: Database -> ByteString
renderDatabasePvc     :: Database -> ByteString
statefulSetName       :: Text -> Text               -- = name
dbServiceName         :: Text -> Text               -- = name (in-cluster DNS)
dbPvcName             :: Text -> Text                -- "nagare-db-<name>-data"
```

Module `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (additions to the export list):

```haskell
emitDatabase   :: Database -> IO ()                 -- prints JSON with "kind":"Database"
encodeDatabase :: Database -> Data.ByteString.Lazy.ByteString
```

Module `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (addition to the export list):

```haskell
decodeDatabase :: ByteString -> Either LoadError Database
-- envelope "kind" must be "Database"; otherwise Left (UnexpectedKind "Database" <got>)
-- decodeDeployment now rejects a kinded object: Left (UnexpectedKind "Deployment" <got>)
```

JSON shape of a `Database` (the field names are the contract EP-45/46/47 do *not* read raw — they
read the loaded `Database` — but documented here for completeness): a flat object with `"kind":
"Database"`, `"name"`, `"engine"` (the lowercase token), `"version"`, `"namespace"`, `"size"`,
optional `"cpuRequest"`/`"memoryRequest"`/`"cpuLimit"`/`"memoryLimit"`, and optional `"retention"`
(`"Retain"` default | `"Delete"`).

Module `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (M4 additions):

```haskell
-- DatabaseName moved here (leaf newtype) and re-exported from Nagare.Dsl.Database:
newtype DatabaseName  -- DNS-1123 label
mkDatabaseName   :: Text -> Either Text DatabaseName
databaseNameText :: DatabaseName -> Text

-- Deployment gains:
data Deployment = Deployment { ... , databases :: ![DatabaseName] }  -- empty default; IP5
```

The new golden file names under `cli/nagare-dsl/test/golden/` are:
`db-postgres.statefulset.yaml`, `db-postgres.service.yaml`, `db-postgres.pvc.yaml`,
`db-redis.statefulset.yaml`, `db-redis.service.yaml`, `db-redis.pvc.yaml`,
`db-clickhouse.statefulset.yaml`, `db-clickhouse.service.yaml`, `db-clickhouse.pvc.yaml`. The new
loadable fixtures are `cli/nagare-dsl/test/fixtures/database/{postgres,redis,clickhouse}/nagare/
Config.hs`.

**Out of scope, restated:** the credential *values* (the generated password) are produced and
written by **EP-45**, not this plan; this renderer references the managed Secret `nagare-db-<name>`
by name and key only and never emits Secret `data`. The *verified* rendered shapes this plan must
reproduce come from **EP-43**; read its Interfaces section before finalizing the M3 goldens.
