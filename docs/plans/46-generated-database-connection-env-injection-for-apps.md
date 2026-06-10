---
id: 46
slug: generated-database-connection-env-injection-for-apps
title: "Generated database connection env injection for apps"
kind: exec-plan
created_at: 2026-06-10T14:25:20Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
master_plan: "docs/masterplans/9-managed-databases-for-nagare.md"
---

# Generated database connection env injection for apps

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a Nagare application can declare in its typed config that it *uses* a
managed database, and `nagarectl deploy` will automatically wire that database's connection
details into the running container's environment — without the developer ever copying a
hostname, a port, a username, or (critically) a password by hand. A developer who has run
`nagarectl db create postgres notes-db` (the command EP-45 provides) and then writes, in their
app's `nagare/Config.hs`, that the app references the database `notes-db`, will find that when
they deploy the app, its container receives `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`,
`POSTGRES_DB` as plain values and `POSTGRES_PASSWORD` and a ready-to-use `DATABASE_URL` as
**Kubernetes Secret references** — so the password is never written into a manifest, a log, or
the config file, yet the app can connect on first boot with code as simple as
`new Pool({ connectionString: process.env.DATABASE_URL })`.

The user-visible behavior this plan enables is exactly that injection. The "biggest remaining
PaaS gap" the MasterPlan names is partly that there is no `DATABASE_URL`/`REDIS_URL` injection
into apps; this plan closes that part. You can see it working without a live cluster by running
`nagarectl deploy --dry-run`, which prints the rendered Knative `Service` YAML: after this
change, an app that references a Postgres database `notes-db` in namespace `personal` shows in
its container's inline `env:` list both an inline literal such as

```yaml
        - name: POSTGRES_HOST
          value: notes-db.personal.svc.cluster.local
```

and a Secret reference such as

```yaml
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: nagare-db-notes-db
              key: DATABASE_URL
```

A **Knative `Service`** is the single YAML resource Nagare applies for an app; its container
spec carries an inline `env:` list (variables written directly into the manifest, either as a
literal `value:` or as a `valueFrom.secretKeyRef`). The `valueFrom.secretKeyRef` form tells
Kubernetes "read this variable's value from key `DATABASE_URL` of the Secret
`nagare-db-notes-db` at pod-start time" — the value lives only in that Secret, never in the
manifest. This plan owns the contract for *which* connection variables are emitted per engine
and *which* are inline literals versus Secret references. It does not create the database or
the Secret (EP-45 does that at `db create` time); it consumes the database's stable in-cluster
DNS name and its managed Secret (the contract EP-44 defines and EP-45 fills) and merges the
connection variables into the app's runtime environment.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: New module `cli/nagarectl/src/Nagare/Database/Connection.hs` with the pure
      `connectionEnv` function (engine + name + namespace + user/db → `Map EnvName ScopedEnvVar`)
      and the per-engine literal/secret-ref split; added to `nagarectl.cabal` `exposed-modules`.
- [ ] M1: Unit tests in `cli/nagarectl/test/Spec.hs` asserting, per engine, exactly which keys
      are `EnvLiteral`s with the right values and which are
      `EnvSecretRef (mkSecretName "nagare-db-<name>")`; all `{Runtime}`-scoped.
- [ ] M2: `databases :: ![DatabaseName]` field added to `Deployment` by EP-44 is consumed in
      `runDeploy`; engine lookup resolves each referenced database to its `Engine`; the
      connection map is merged via `mergeGenerated`; `nagarectl deploy --dry-run` shows both the
      inline literals and the `valueFrom.secretKeyRef` entries.
- [ ] M2: The server-deploy analog (`deployServer`) injects the same connection env.
- [ ] M3: Error handling — referencing an unknown/uncreated database fails with a clear
      message; same-engine collision rule implemented and tested; precedence over user env
      documented and verified.
- [ ] M3: End-to-end `--dry-run` transcript captured; `cabal test` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Model the connection-variable construction as a **pure function**
  `connectionEnv :: Engine -> DatabaseName -> Namespace -> ConnIdentity -> Map EnvName ScopedEnvVar`
  in a new module `cli/nagarectl/src/Nagare/Database/Connection.hs`, kept entirely separate from
  the IO that discovers each database's engine on the cluster.
  Rationale: the per-engine literal/secret-ref split is the heart of IP5 and must be exhaustively
  unit-tested without a cluster. Separating the pure map-builder from the IO engine-lookup mirrors
  how `Nagare.Env.Generated.generatedEnv` is a pure function the deploy site calls — and how
  `Nagare.Storage.Discover` separates its pure parsers/formatters from the `kubectl` IO.
  Date: 2026-06-10

- Decision: Inject database connection variables by **merging them into the same `#env` map via
  `mergeGenerated`** that EP-26 uses for the `NAGARE_*` variables, at the same `runDeploy` /
  `deployServer` call sites.
  Rationale: `mergeGenerated` is a left-biased `Map.union`, so generated entries win over
  same-named user entries. Database connection variables are *generated* (they reflect cluster
  truth — the DNS name and the managed Secret), so they should win over any user-declared value
  of the same name, exactly like `NAGARE_*`. Reusing the one merge path keeps a single,
  documented precedence rule rather than inventing a second mechanism. Order of the two merges is
  irrelevant unless a database variable collides with a `NAGARE_*` name, which it cannot (disjoint
  prefixes), so we apply both as nested left-biased unions.
  Date: 2026-06-10

- Decision: Emit `*_HOST`, `*_PORT`, `*_USER`, `*_DB` (where applicable) as inline `EnvLiteral`s
  and emit any `*_PASSWORD` and the composed `*_URL` (`DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL`)
  as `EnvSecretRef (mkSecretName "nagare-db-<name>")`.
  Rationale: this is the IP5 contract restated. Variables that embed or are the password must not
  be written into the manifest as plain text; modelled as `EnvSecretRef`, the renderer in
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (`envEntryValue`) emits them as
  `valueFrom.secretKeyRef` with `name = <SecretName>` and `key = <the EnvName map key>`. The
  host/port/user/db are not secret and are more useful inline (an app can read them directly).
  Date: 2026-06-10

- Decision: The Secret `key` that an `EnvSecretRef` resolves against is the **env-variable name
  itself** (the `Map` key). Therefore the connection map's keys for password/URL variables
  (`POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_PASSWORD`, `REDIS_URL`, `CLICKHOUSE_PASSWORD`,
  `CLICKHOUSE_URL`) MUST be byte-identical to the keys EP-45 writes into the `nagare-db-<name>`
  Secret (IP3). This is a hard invariant; the renderer offers no way to point a `secretKeyRef`
  at a differently-named key.
  Rationale: confirmed against `envEntryValue` in `Render.hs` — for `EnvSecretRef sn` it renders
  `secretKeyRef.name = secretNameText sn` and `secretKeyRef.key = n` (the env var name). The IP3
  key set (Postgres `POSTGRES_PASSWORD`/`DATABASE_URL`, Redis `REDIS_PASSWORD`/`REDIS_URL`,
  ClickHouse `CLICKHOUSE_PASSWORD`/`CLICKHOUSE_URL`) was chosen to match these env names exactly,
  so no re-keying is needed.
  Date: 2026-06-10

- Decision: Learn each referenced database's `Engine` by **querying the live cluster** for the
  managed resources labelled `nagare.dev/database=<name>` and reading the `nagare.dev/engine`
  label (the label EP-44 stamps on the rendered Secret/StatefulSet and EP-45 applies). On
  `--dry-run` with no reachable cluster, fail with a clear "engine unknown (database `<name>` not
  found; run `nagarectl db create` first, or it is in another namespace)" message rather than
  guessing.
  Rationale: the app config stores only `DatabaseName`s, not engines (per IP1/IP5 the engine lives
  on the `Database` record, not on the app's reference). The label-by-discovery pattern reuses the
  exact approach `Nagare.Storage.Discover` uses for PVCs (`kubectl get ... -l nagare.dev/app=<app>
  -o json`, then read a label). A wrong-guess fallback would render a manifest that silently fails
  at runtime, which the MasterPlan's "demonstrably working behavior" requirement forbids.
  Date: 2026-06-10

- Decision: In v1, **at most one database per engine** may inject the canonical unprefixed
  variable names (`POSTGRES_*`, `REDIS_*`, `CLICKHOUSE_*`). If an app references two databases of
  the same engine, the deploy fails with a clear collision error naming both databases and the
  conflicting variable names.
  Rationale: the canonical names (`DATABASE_URL`, `REDIS_URL`, …) are what application libraries
  expect by convention; two same-engine databases would both want `DATABASE_URL`, and a
  left-biased union would silently drop one. A loud error is honest and keeps v1 simple; a future
  plan can add a per-reference prefix (e.g. `ANALYTICS_DATABASE_URL`) if multi-same-engine support
  is needed. Different engines (one Postgres, one Redis) coexist freely because their variable
  names are disjoint.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan adds code to the **`nagarectl`** Cabal package at
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl` and reuses types from the **`nagare-dsl`**
library at `/Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl`. Both build with GHC 9.12 inside
the repository's Nix flake dev shell (the repo uses direnv; run `direnv allow` once, or `nix
develop`, before building). The build tool is Cabal; the test framework is **tasty**
(`tasty-hunit` for assertion tests in `IO`, `tasty-golden` for byte-for-byte file comparisons).
All GCP/cluster work targets project `tan-nb-exp`, region `us-west1` only (repository
`CLAUDE.md`); this plan touches the cluster only read-only (a label query), but that constraint
still applies.

Terms defined so the reader needs no outside context:

- **Inline `env:`** is the list of environment variables written directly into the Knative
  `Service` manifest's container spec. The renderer
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` builds it from the typed model's `env` map. Each entry
  is either a literal (`name`/`value`) or a Secret reference (`name`/`valueFrom.secretKeyRef`).
- **`EnvVar`** (in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`) is a sum type: `EnvLiteral Text`
  renders as `value: <text>`; `EnvSecretRef SecretName` renders as `valueFrom.secretKeyRef` with
  `name = the SecretName` and `key = the env var's own name`. You pick exactly one branch — a
  value cannot be simultaneously a literal and a secret reference.
- **`ScopedEnvVar`** wraps an `EnvVar` with a non-empty set of `EnvScope`s (`Runtime`, `Build`,
  `Preview`). `runtimeScoped :: EnvVar -> ScopedEnvVar` produces a `{Runtime}` entry. The
  renderer's inline `env:` block includes only entries whose scope set contains `Runtime`.
- **Managed Secret (IP3)** is the Kubernetes Secret EP-45 creates at `db create` time, named
  `nagare-db-<name>`, labelled `nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`,
  `nagare.dev/engine: <engine>`. Its keys are engine-specific and fixed (see the variable table
  in Interfaces and Dependencies).
- **In-cluster DNS host** is the stable internal address of a database's ClusterIP Service:
  `<name>.<namespace>.svc.cluster.local`. It is never exposed to the public internet.

### How env injection already works (the precedent this plan follows)

`cli/nagarectl/src/Nagare/Env/Generated.hs` (EP-26, checked in) is the model. It defines a pure
function `generatedEnv :: GeneratedContext -> Map EnvName ScopedEnvVar` that builds the reserved
`NAGARE_*` identity variables as inline `{Runtime}` `EnvLiteral`s, and a merge function:

```haskell
mergeGenerated
  :: Map EnvName ScopedEnvVar  -- ^ generated (wins)
  -> Map EnvName ScopedEnvVar  -- ^ user / config env
  -> Map EnvName ScopedEnvVar
mergeGenerated = Map.union  -- Data.Map.union is left-biased
```

`Data.Map.union` keeps the left map's value on a key collision, so generated entries win over
same-named user entries. The deploy path in `cli/nagarectl/app/Main.hs` merges these into the
app's env map right before rendering. In `runDeploy` (the prebuilt-image / build path), at line
~1078:

```haskell
      dep' = dep & #env %~ mergeGenerated (generatedEnv gctx)
```

`dep'` then feeds `renderService dep' imageTag`, so the rendered Service carries the generated
env. The server analog, `deployServer` (line ~1204), does the same to a `ServerSite`:

```haskell
      site = site0 & #env %~ mergeGenerated (generatedEnv gctx)
```

This plan adds a second generated map — the database connection variables — and merges it into
the same `#env` map at the same two call sites.

### How an `EnvSecretRef` renders (the key fact this plan relies on)

`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` defines `envEntryValue`:

```haskell
envEntryValue :: Text -> EnvVar -> Value
envEntryValue n (EnvLiteral lit) =
  object ["name" .= n, "value" .= lit]
envEntryValue n (EnvSecretRef sn) =
  object
    [ "name" .= n
    , "valueFrom"
        .= object
          [ "secretKeyRef"
              .= object
                [ "name" .= secretNameText sn
                , "key" .= n           -- the env var's OWN name
                ]
          ]
    ]
```

This was confirmed by reading the real source. The consequence is the **hard invariant** of this
plan: a map entry keyed `DATABASE_URL` whose value is `EnvSecretRef (mkSecretName
"nagare-db-notes-db")` renders a `secretKeyRef` with `name: nagare-db-notes-db` and `key:
DATABASE_URL`. For the app to start, the Secret `nagare-db-notes-db` MUST contain a key named
exactly `DATABASE_URL`. EP-45 writes that key (IP3); this plan's only obligation is to use the
identical env-variable name as the map key. The renderer offers no facility to point a
`secretKeyRef` at a key whose name differs from the env-variable name, so the two contracts are
forced to agree.

The renderer also sorts inline `env:` entries by name (`Map.toAscList`) and includes only
`Runtime`-scoped entries (`envField`). No renderer change is needed by this plan: inserting the
connection entries into the `env` map is sufficient for them to render.

### The dependency on EP-44 (hard) — the `databases` field and `DatabaseName`

This plan **hard-depends on EP-44**
(`docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md`),
which must be merged first. From EP-44 this plan consumes:

- The `DatabaseName` type (a DNS-label newtype, hidden constructor, `mkDatabaseName :: Text ->
  Either Text DatabaseName` and `databaseNameText :: DatabaseName -> Text`), in
  `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` (or `Nagare.Dsl.Types`).
- The `Engine` enum (`Postgres | Redis | ClickHouse`), same module.
- The new field on `Deployment` (in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`):
  `databases :: ![DatabaseName]`, defaulting to the empty list, round-tripping through the same
  emit/decode path as the rest of the app model. An app declares the databases it uses here.
- The Secret naming/keys contract (IP3): the Secret is `nagare-db-<name>`, labels include
  `nagare.dev/engine: <engine>`, and the engine-specific keys listed in the variable table.

If EP-44 is not yet merged when implementing this plan, stop and do EP-44 first; this plan cannot
compile without the `databases` field and the `Engine`/`DatabaseName` types.

### The soft dependency on EP-45

This plan **soft-depends on EP-45**
(`docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md`), which creates
the `nagare-db-<name>` Secret and stamps the `nagare.dev/engine` label at `db create` time. The
pure variable-construction (M1) and the wiring/rendering (M2) can be written and unit/`--dry-run`
tested against the *known* IP3 contract before EP-45's live `db create` exists — the dry-run path
renders `secretKeyRef`s without needing the Secret to actually exist. A real end-to-end "an app
reads a live database" demonstration wants EP-45 done; until then, M2's live-cluster engine
lookup is exercised against a database created by hand following the IP3 contract, or deferred
with instructions (per MasterPlan 7's "live legs can be deferred-with-instructions"). M3's offline
error-handling tests do not need a cluster.


## Plan of Work

The work is three milestones. M1 builds and tests the pure connection-variable function in
isolation — no CLI behavior changes, only a tested pure function. M2 wires it into the two deploy
paths (prebuilt-image and server), including the IO engine lookup, so `nagarectl deploy
--dry-run` renders the connection variables. M3 adds the error handling and the same-engine
collision rule and proves them with tests. Each milestone is independently verifiable: M1 by a
green `cabal test` exercising `connectionEnv`; M2 by a `--dry-run` transcript showing the injected
literals and `secretKeyRef`s; M3 by tests that fail-before/pass-after for the error and collision
behaviors.


### Milestone M1 — The pure `Connection` module and its unit tests

Scope: a new module `cli/nagarectl/src/Nagare/Database/Connection.hs` that, given an engine, a
database name, a namespace, and the connection identity (the user and database name for engines
that have them), produces the `Map EnvName ScopedEnvVar` of connection variables with the correct
literal/secret-ref split. At the end of M1 the module compiles, is listed in `nagarectl.cabal`,
and pure unit tests prove the per-engine output. No deploy behavior changes yet.

Create `cli/nagarectl/src/Nagare/Database/Connection.hs`. The shape, modelled directly on
`Nagare.Env.Generated`:

```haskell
{-# LANGUAGE PackageImports #-}

-- | Deploy-time generated database connection environment variables (EP-46, IP5).
--
-- A pure assembly of the per-engine connection variables for a managed database
-- an app references. Host/port/user/db are inline @{Runtime}@ 'EnvLiteral's; the
-- password and the composed connection URL are 'EnvSecretRef's pointing at the
-- managed Secret @nagare-db-<name>@ (EP-45 / IP3). The map is merged into the
-- app's env at the deploy call site via 'Nagare.Env.Generated.mergeGenerated',
-- exactly like the @NAGARE_*@ identity variables.
module Nagare.Database.Connection
  ( ConnIdentity (..)
  , connectionEnv
  , dbSecretName
  , mergeConnectionEnvs
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Database (DatabaseName, Engine (..), databaseNameText)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral, EnvSecretRef)
  , Namespace
  , ScopedEnvVar
  , mkEnvName
  , mkSecretName
  , namespaceText
  , runtimeScoped
  )

-- | The non-secret connection identity for a database: the application role/user
-- and the logical database name. Redis has neither a user nor a database name in
-- the variable contract, so both are 'Nothing' for Redis; Postgres and ClickHouse
-- populate 'connUser', and Postgres additionally populates 'connDb'.
data ConnIdentity = ConnIdentity
  { connUser :: !(Maybe Text)
  , connDb   :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | The deterministic managed-Secret name for a database (IP3):
-- @dbSecretName name == "nagare-db-" <> databaseNameText name@.
dbSecretName :: DatabaseName -> Text
dbSecretName name = "nagare-db-" <> databaseNameText name

-- | The per-engine connection variables for one referenced database, as a
-- @{Runtime}@-scoped env map. Literals: host, port, and (where applicable) user
-- and db. Secret references (into @nagare-db-<name>@, key = the env var name):
-- the password and the composed URL.
connectionEnv :: Engine -> DatabaseName -> Namespace -> ConnIdentity -> Map EnvName ScopedEnvVar
connectionEnv eng name ns ident =
  Map.fromList (lits <> refs)
  where
    host = databaseNameText name <> "." <> namespaceText ns <> ".svc.cluster.local"
    secret = dbSecretName name
    lit n v = (envName n, runtimeScoped (EnvLiteral v))
    ref n = (envName n, runtimeScoped (EnvSecretRef (secretName secret)))
    maybeLit n = maybe [] (\v -> [lit n v])
    (lits, refs) = case eng of
      Postgres ->
        ( [lit "POSTGRES_HOST" host, lit "POSTGRES_PORT" "5432"]
            <> maybeLit "POSTGRES_USER" (connUser ident)
            <> maybeLit "POSTGRES_DB" (connDb ident)
        , [ref "POSTGRES_PASSWORD", ref "DATABASE_URL"]
        )
      Redis ->
        ( [lit "REDIS_HOST" host, lit "REDIS_PORT" "6379"]
        , [ref "REDIS_PASSWORD", ref "REDIS_URL"]
        )
      ClickHouse ->
        ( [lit "CLICKHOUSE_HOST" host, lit "CLICKHOUSE_PORT" "9000"]
            <> maybeLit "CLICKHOUSE_USER" (connUser ident)
        , [ref "CLICKHOUSE_PASSWORD", ref "CLICKHOUSE_URL"]
        )

-- | Left-biased merge of two database connection maps, surfacing a collision on
-- any shared key (used by the multi-database caller to detect same-engine
-- canonical-name conflicts). See 'Nagare.Database.Connection' Decision Log.
mergeConnectionEnvs
  :: [Map EnvName ScopedEnvVar]
  -> Either Text (Map EnvName ScopedEnvVar)
mergeConnectionEnvs maps =
  case findCollision maps of
    Just k -> Left ("two referenced databases of the same engine both inject '"
                      <> envText k <> "'; only one database per engine may be referenced in v1")
    Nothing -> Right (Map.unions maps)
  where
    findCollision = ...   -- pairwise key-intersection check; see implementation note

-- internal constructors that cannot fail for the fixed names/strings here;
-- a failure is a programmer error surfaced loudly (mirrors EP-26's envName).
envName :: Text -> EnvName
envName t = either (\e -> error ("EP-46 connection env name invalid: " <> show e)) id (mkEnvName t)

secretName :: Text -> SecretName
secretName t = either (\e -> error ("EP-46 secret name invalid: " <> show e)) id (mkSecretName t)
```

Notes for a novice. `Nagare.Dsl.Prelude` is the package's local prelude (re-exports `Generic`,
`Text`, lens operators). `mkEnvName` and `mkSecretName` only reject the empty string, so the
fixed names always succeed; the `error` branches are unreachable and exist for totality, exactly
as in `Nagare.Env.Generated`. The `findCollision` helper returns the first `EnvName` that appears
in more than one of the maps (pairwise `Map.intersectionWith` over the list, or fold the keys into
a `Set` and detect a repeat). The exact `Engine`/`DatabaseName` import path
(`Nagare.Dsl.Database` vs `Nagare.Dsl.Types`) is whatever EP-44 chose — check EP-44's module and
import accordingly; the MasterPlan IP1 names `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` as the
likely home.

Add the module to the **library** stanza of `cli/nagarectl/nagarectl.cabal`:

```cabal
  exposed-modules:
    ...
    Nagare.Database.Connection
    Nagare.Env.Generated
    ...
```

(It is exposed, not `other-modules`, because the test suite imports it — same reason
`Nagare.Env.Generated` is exposed.) The library already depends on `containers`, `text`, and
`nagare-dsl`, so no new dependency is needed.

Add a pure unit-test group to `cli/nagarectl/test/Spec.hs`. Add `testGroup
"Nagare.Database.Connection" connectionEnvTests` to the tasty tree in `main` and define tests
that assert the exact key set per engine and the literal/secret-ref classification. A helper
that classifies a looked-up entry:

```haskell
import Nagare.Database.Connection
import Nagare.Dsl.Database (Engine (..), mkDatabaseName)
import Nagare.Dsl.Types (EnvVar (..), envNameText, mkEnvName, mkNamespace, value, secretNameText)
import qualified Data.Map as Map

-- classify a generated entry: Left literal-value, or Right secret-name, by name
classify :: Map.Map EnvName ScopedEnvVar -> Text -> Maybe (Either Text Text)
classify m name = do
  en <- either (const Nothing) Just (mkEnvName name)
  sev <- Map.lookup en m
  pure $ case value sev of
    EnvLiteral t   -> Left t
    EnvSecretRef s -> Right (secretNameText s)

pgEnv :: Map.Map EnvName ScopedEnvVar
pgEnv =
  connectionEnv Postgres
    (unsafe (mkDatabaseName "notes-db"))
    (unsafe (mkNamespace "personal"))
    (ConnIdentity { connUser = Just "app", connDb = Just "notes" })

connectionEnvTests :: [TestTree]
connectionEnvTests =
  [ testCase "Postgres: host/port/user/db are literals" $ do
      classify pgEnv "POSTGRES_HOST" @?= Just (Left "notes-db.personal.svc.cluster.local")
      classify pgEnv "POSTGRES_PORT" @?= Just (Left "5432")
      classify pgEnv "POSTGRES_USER" @?= Just (Left "app")
      classify pgEnv "POSTGRES_DB"   @?= Just (Left "notes")
  , testCase "Postgres: password and DATABASE_URL are secret refs to nagare-db-notes-db" $ do
      classify pgEnv "POSTGRES_PASSWORD" @?= Just (Right "nagare-db-notes-db")
      classify pgEnv "DATABASE_URL"      @?= Just (Right "nagare-db-notes-db")
  , testCase "Postgres: exactly these six keys" $
      sort (map envNameText (Map.keys pgEnv))
        @?= sort [ "POSTGRES_HOST","POSTGRES_PORT","POSTGRES_USER","POSTGRES_DB"
                 , "POSTGRES_PASSWORD","DATABASE_URL" ]
  -- analogous groups for Redis (REDIS_HOST/REDIS_PORT literals;
  -- REDIS_PASSWORD/REDIS_URL refs) and ClickHouse (CLICKHOUSE_HOST/PORT/USER
  -- literals; CLICKHOUSE_PASSWORD/CLICKHOUSE_URL refs)
  , testCase "every entry is Runtime-scoped" $
      mapM_ (\sev -> scopes sev @?= scopes (runtimeScoped (EnvLiteral "x"))) (Map.elems pgEnv)
  ]
```

`unsafe :: Either Text a -> a` is the existing test helper in `Spec.hs` that forces a `Right`.
`sort` comes from `Data.List`. Write the Redis and ClickHouse groups by the same template using
the variable table in Interfaces and Dependencies.

Commands (working directory `cli/nagarectl`):

```bash
cabal build
cabal test
```

Acceptance: `cabal build` succeeds; the new `Nagare.Database.Connection` cases pass, proving for
each engine which keys are literals (with the right host/port/user/db values) and which are
`EnvSecretRef`s pointing at `nagare-db-<name>`, and that every entry is `{Runtime}`-scoped.
Nothing about a real deploy has changed yet.


### Milestone M2 — Wire into the deploy paths and demonstrate the rendered env

Scope: `runDeploy` and `deployServer` in `cli/nagarectl/app/Main.hs` resolve each `databases`
reference to its engine, build the per-database connection maps, merge them into the app env via
`mergeGenerated`, and render. The IO engine lookup is added as a small helper. At the end of M2,
`nagarectl deploy --dry-run` of an app referencing a Postgres database prints a Service whose
inline `env:` contains both the inline literals and the `valueFrom.secretKeyRef` entries.

First, the IO engine lookup. Create `cli/nagarectl/src/Nagare/Database/Discover.hs` (mirroring
`Nagare.Storage.Discover`), exposing:

```haskell
-- | The label selector that finds a database's managed resources (IP3):
-- @dbLabelSelector "notes-db" == "nagare.dev/database=notes-db"@.
dbLabelSelector :: Text -> Text

-- | Look up the engine of a referenced database by reading the
-- @nagare.dev/engine@ label off its managed Secret in @ns@, via
-- @kubectl get secret -n <ns> -l nagare.dev/database=<name> -o json@.
-- 'Left' with a clear message when not found / not reachable / ambiguous.
lookupEngine :: Namespace -> DatabaseName -> IO (Either Text (Engine, ConnIdentity))
```

`lookupEngine` shells out exactly the way `Nagare.Storage.Discover.listAppPVCs` does (the
`Cradle`/`run`/`cmd "kubectl"` pattern already used across `cli/nagarectl/src/Nagare/`), parses
the JSON list, and reads `.items[0].metadata.labels["nagare.dev/engine"]` plus the non-secret
identity it needs (the Postgres/ClickHouse user and the Postgres db name — these live as
*non-secret* keys/annotations on the Secret or are read from the database's StatefulSet env; EP-44
fixes where the user/db live, so read them from there). Map the engine label string to the
`Engine` enum (`"postgres" -> Postgres`, `"redis" -> Redis`, `"clickhouse" -> ClickHouse`),
failing on any unknown value. On `--dry-run` the cluster may be unreachable; the `Left` message
must say so plainly, and the deploy must exit non-zero with that message rather than render a
half-wired Service (see M3).

Then wire `runDeploy`. After `dep` is loaded and `dep'` is formed by the EP-26 merge, resolve the
databases and merge their connection env into `dep'`'s env:

```haskell
  -- EP-46: resolve each referenced database to its engine and merge the per-engine
  -- connection variables (literals + Secret refs) into the app env, like NAGARE_*.
  connEnv <- resolveConnectionEnv (dep ^. #namespace) (dep ^. #databases)
  let dep'' = dep' & #env %~ mergeGenerated connEnv
```

where a small `Main.hs` helper composes the lookup, the pure `connectionEnv`, and the
collision-checking merge:

```haskell
resolveConnectionEnv :: Namespace -> [DatabaseName] -> IO (Map EnvName ScopedEnvVar)
resolveConnectionEnv _  []   = pure Map.empty
resolveConnectionEnv ns dbs  = do
  maps <- forM dbs $ \name -> do
    r <- lookupEngine ns name
    case r of
      Left err -> dieT ("nagarectl deploy: " <> err)
      Right (eng, ident) -> pure (connectionEnv eng name ns ident)
  case mergeConnectionEnvs maps of
    Left err  -> dieT ("nagarectl deploy: " <> err)
    Right m   -> pure m
```

Then render from `dep''` instead of `dep'` (rename the existing `dep'` bindings to `dep''` in the
render lines `imageRef`, `renderVolumeClaims`, `renderService`, `renderDomainMappings`, `name`,
`ns`). `dieT` is the existing exit-with-message helper used throughout `Main.hs`. Add imports:
`import Nagare.Database.Connection (connectionEnv, mergeConnectionEnvs)` and `import
Nagare.Database.Discover (lookupEngine)`.

Wire `deployServer` identically: after `site` is formed by the EP-26 merge, do `site' <- ...`
merging the resolved connection env (the server `ServerSite` also has a `databases` field if EP-44
added it there; if EP-44 added `databases` only to `Deployment` and not `ServerSite`, document
that server sites cannot reference databases in v1 and skip the server wiring with a comment —
resolve this by checking EP-44's actual `ServerSite` record). Build `ServerDeployInputs` from the
final merged site.

A `--dry-run` deploy never applies anything, but it still calls `lookupEngine`, which performs a
read-only `kubectl get`. That is acceptable (read-only, project-isolated). When no cluster is
reachable and the app references no databases (`databases == []`), `resolveConnectionEnv` returns
`Map.empty` without any `kubectl` call, so stateless apps and apps with no DB references deploy
exactly as before — a strict additive change.

Add a render-level demonstration test to `cli/nagarectl/test/Spec.hs` that does not need a
cluster: build a `Deployment` with an empty `databases` (so no lookup), manually merge a
`connectionEnv Postgres ...` map into its `env`, render with `renderService`, and assert the bytes
contain both `POSTGRES_HOST`/`notes-db.personal.svc.cluster.local` and a `secretKeyRef` block with
`nagare-db-notes-db` and `DATABASE_URL`:

```haskell
  , testCase "rendered Service carries DB literals and a DATABASE_URL secretKeyRef" $ do
      let cm = connectionEnv Postgres (unsafe (mkDatabaseName "notes-db"))
                 (unsafe (mkNamespace "personal"))
                 (ConnIdentity { connUser = Just "app", connDb = Just "notes" })
          dep' = demoDep { env = mergeGenerated cm (env demoDep) }
          yaml = renderService dep' "20260602-120000"
      assertInfix "POSTGRES_HOST" yaml
      assertInfix "notes-db.personal.svc.cluster.local" yaml
      assertInfix "DATABASE_URL" yaml
      assertInfix "secretKeyRef" yaml
      assertInfix "nagare-db-notes-db" yaml
```

`assertInfix` and `demoDep` follow the EP-26 test conventions in `Spec.hs`.

Commands (working directory `cli/nagarectl`):

```bash
cabal build
cabal test
```

Acceptance: `cabal test` green including the render-demonstration case; and the `--dry-run`
transcript in Concrete Steps shows the literals and `secretKeyRef`s in the rendered Service.


### Milestone M3 — Error handling, collision rules, and precedence

Scope: prove the failure modes. Referencing a database that does not exist (or is unreachable)
fails the deploy with a clear message and a non-zero exit. Referencing two databases of the same
engine fails with a collision message naming the conflicting variables. The precedence of
generated connection vars over user env is documented and tested. At the end of M3 these
behaviors are covered by tests that fail-before/pass-after where applicable.

Work — the unknown-database error is already produced by `lookupEngine` returning `Left` and
`resolveConnectionEnv` calling `dieT`. Add a unit test for the pure collision path
(`mergeConnectionEnvs`): two Postgres maps for different database names share the key
`DATABASE_URL` (and `POSTGRES_HOST`, etc.), so `mergeConnectionEnvs [pg1, pg2]` returns `Left`
with a message naming a conflicting variable; a Postgres map plus a Redis map share no keys, so it
returns `Right` and the union has all variables of both. The engine-lookup IO path (`Left` →
`dieT`) is best demonstrated by the `--dry-run` transcript against a missing database (see
Concrete Steps); document it there with the exact message rather than mocking `kubectl`.

Work — precedence over user env. Because `connEnv` is merged with `mergeGenerated connEnv` (the
connection map on the left), a user who wrote `DATABASE_URL` themselves in `Config.hs` is
overridden by the generated Secret reference. Add a unit test merging a user `DATABASE_URL`
literal under a generated `connectionEnv` map and asserting the result is the `EnvSecretRef`, not
the user literal. Document this in Interfaces and Dependencies: database connection variable names
are effectively reserved for an app that references that engine's database; a same-named user
variable is silently replaced (the same rule EP-26 uses for `NAGARE_*`).

Commands (working directory `cli/nagarectl`):

```bash
cabal build
cabal test
```

Acceptance: the collision test returns `Left` with a clear message; the cross-engine test returns
`Right` with the merged superset; the precedence test shows the generated `EnvSecretRef` wins; and
a `--dry-run` against a non-existent database prints the clear "database not found" message and
exits non-zero.


## Concrete Steps

All commands run from `cli/nagarectl` unless stated otherwise. Enter the flake dev shell first if
not already inside it (the repo uses direnv: `direnv allow` once, or `nix develop`).

Build and test after each milestone:

```bash
cabal build
cabal test
```

Expected (abbreviated) after M1 — the new pure tests appear and pass:

```text
nagarectl
  Nagare.Database.Connection
    Postgres: host/port/user/db are literals:                              OK
    Postgres: password and DATABASE_URL are secret refs to nagare-db-...:   OK
    Postgres: exactly these six keys:                                      OK
    Redis: host/port literals; password/URL secret refs:                   OK
    ClickHouse: host/port/user literals; password/URL secret refs:         OK
    every entry is Runtime-scoped:                                         OK
All N tests passed (…s)
```

End-to-end dry-run transcript (after M2/M3). From the repo root, deploy an app that references a
Postgres database `notes-db`. This assumes either a live cluster where `nagarectl db create
postgres notes-db` (EP-45) has run, or a hand-created Secret/StatefulSet following IP3:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/db-backed-app/nagare/Config.hs \
  --base-domain apps.example.com \
  --tag 20260602-120000 \
  --dry-run
```

Expected — the printed Knative Service's container `env:` contains the Postgres literals and the
two Secret references (sorted by name, interleaved with the user vars and the `NAGARE_*` block):

```yaml
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: nagare-db-notes-db
              key: DATABASE_URL
        - name: POSTGRES_DB
          value: notes
        - name: POSTGRES_HOST
          value: notes-db.personal.svc.cluster.local
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nagare-db-notes-db
              key: POSTGRES_PASSWORD
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_USER
          value: app
```

Error transcript — referencing a database that has not been created (no reachable Secret with the
`nagare.dev/database=notes-db` label):

```text
nagarectl deploy: engine unknown: database 'notes-db' not found in namespace 'personal'
(run `nagarectl db create <engine> notes-db` first, or check the namespace). Exiting.
```

Collision transcript — an app referencing two Postgres databases:

```text
nagarectl deploy: two referenced databases of the same engine both inject 'DATABASE_URL';
only one database per engine may be referenced in v1
```

Git: commit each milestone with Conventional Commits and the MasterPlan trailers. No feature
branch — commit on the current branch. Example after M1:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
git add cli/nagarectl/src/Nagare/Database/Connection.hs cli/nagarectl/nagarectl.cabal \
        cli/nagarectl/test/Spec.hs docs/plans/46-generated-database-connection-env-injection-for-apps.md
git commit -m "feat(db): EP-46 pure database connection-env builder

MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/46-generated-database-connection-env-injection-for-apps.md
Intention: intention_01ktryacjaezzbezmkt5j93abq"
```

Use the same three trailers on the M2 and M3 commits (`feat(db): EP-46 ...` / `feat(cli): EP-46
...` as appropriate).


## Validation and Acceptance

Acceptance is behavioral, phrased as observable input/output, not "code compiles."

First, the per-engine variable contract holds. The `Nagare.Database.Connection` unit tests assert,
for each of the three engines, the exact key set and that host/port/user/db are `EnvLiteral`s with
the right values (the host being `<name>.<ns>.svc.cluster.local`) and that the password and
composed URL are `EnvSecretRef`s whose Secret name is `nagare-db-<name>`. These fail before this
plan (the function does not exist) and pass after.

Second, the rendered Service carries both forms. The render-demonstration test renders a
`Deployment` whose env was merged with a Postgres `connectionEnv` and asserts the bytes contain
`POSTGRES_HOST`, the literal host `notes-db.personal.svc.cluster.local`, `DATABASE_URL`, a
`secretKeyRef` block, and the Secret name `nagare-db-notes-db`. The `--dry-run` transcript above is
the human-observable version: the printed YAML shows an inline `POSTGRES_HOST` literal AND a
`DATABASE_URL` `valueFrom.secretKeyRef` with `name: nagare-db-notes-db`, `key: DATABASE_URL` — the
exact IP5 acceptance excerpt the MasterPlan calls for.

Third, the hard invariant is respected. The Secret key a `secretKeyRef` reads is the env-variable
name; the connection map uses `DATABASE_URL` (etc.) as the map key, which the renderer copies into
`secretKeyRef.key`. Because EP-45 (IP3) writes the Secret with exactly those keys, the app starts
and connects. This is verified end-to-end on a live cluster once EP-45 exists (an app that
references a real `notes-db` and reads `DATABASE_URL` connects); offline, it is verified by the
matching key names in the rendered YAML against the IP3 key list documented below.

Fourth, the failure modes are clear. A deploy referencing an absent database exits non-zero with
the "database not found" message; a deploy referencing two same-engine databases exits with the
collision message; both are shown above. An app referencing no databases (`databases == []`)
deploys byte-identically to before this plan (no `kubectl` call, no extra env) — verified by
deploying an existing example with no `databases` field and diffing the rendered Service against
the pre-change output.

The exact test command is `cabal test` (from `cli/nagarectl`). A failing `tasty-hunit` test prints
the failed assertion and the offending value; an `assertInfix` failure dumps the full rendered
YAML so you can see what was emitted.


## Idempotence and Recovery

`connectionEnv`, `dbSecretName`, and `mergeConnectionEnvs` are pure total functions; calling them
repeatedly with the same inputs yields byte-for-byte identical maps, so re-rendering and
re-deploying the same app against the same databases produces an identical Service manifest. The
only IO this plan adds on the deploy path is `lookupEngine`, a read-only `kubectl get` against
project `tan-nb-exp` — it mutates nothing and is safe to repeat. A real (non `--dry-run`) deploy
applies the rendered Service with `kubectl apply`, which is idempotent (re-applying an identical
manifest is a no-op).

If `lookupEngine` fails (cluster unreachable, database not yet created), the deploy stops before
applying anything, with a clear message; nothing is left half-applied. To retry, create the
database (EP-45) or fix the namespace and re-run. To roll back the code, revert the commits; the
new module and the call-site merges are additive — reverting restores the previous (no
connection-env) behavior with no migration, because an app with no `databases` references behaved
identically before and after.


## Interfaces and Dependencies

This plan adds two `nagarectl` modules and depends only on libraries already in the build. The
new public interface, in `cli/nagarectl/src/Nagare/Database/Connection.hs` (module
`Nagare.Database.Connection`):

```haskell
data ConnIdentity = ConnIdentity
  { connUser :: Maybe Text   -- Postgres/ClickHouse application role; Nothing for Redis
  , connDb   :: Maybe Text   -- Postgres logical database; Nothing for Redis/ClickHouse
  }

-- "nagare-db-" <> databaseNameText name  (the IP3 Secret name)
dbSecretName :: DatabaseName -> Text

-- The IP5 per-engine variable map: {Runtime}-scoped, literals for host/port/user/db,
-- EnvSecretRef (nagare-db-<name>) for the password and the composed URL.
connectionEnv :: Engine -> DatabaseName -> Namespace -> ConnIdentity -> Map EnvName ScopedEnvVar

-- Union of per-database maps; Left on a shared key (same-engine canonical-name collision).
mergeConnectionEnvs :: [Map EnvName ScopedEnvVar] -> Either Text (Map EnvName ScopedEnvVar)
```

And in `cli/nagarectl/src/Nagare/Database/Discover.hs` (module `Nagare.Database.Discover`):

```haskell
dbLabelSelector :: Text -> Text   -- "nagare.dev/database=<name>"
lookupEngine :: Namespace -> DatabaseName -> IO (Either Text (Engine, ConnIdentity))
```

From `nagare-dsl` this plan imports (paths per EP-44): `DatabaseName`, `databaseNameText`,
`Engine (Postgres, Redis, ClickHouse)` from `Nagare.Dsl.Database`; and from `Nagare.Dsl.Types`:
`EnvName`, `mkEnvName`, `envNameText`, `EnvVar (EnvLiteral, EnvSecretRef)`, `SecretName`,
`mkSecretName`, `secretNameText`, `ScopedEnvVar` with `value`/`scopes`, `runtimeScoped`,
`Namespace`, `namespaceText`, and (in tests) `Deployment (..)`, `mkServiceName`, `mkImageRef`,
`defaultPort`; plus `Nagare.Dsl.Render.renderService`. From `nagarectl` it imports
`Nagare.Env.Generated.mergeGenerated` (the existing left-biased merge) at the wiring sites. No new
third-party dependency is introduced; the `nagarectl` library already depends on `containers`,
`text`, and `nagare-dsl`, and on the `Cradle`/process machinery `Nagare.Storage.Discover` uses for
`kubectl`.

**Hard dependency — EP-44** (`docs/plans/44-...`). This plan cannot compile without EP-44's
`databases :: ![DatabaseName]` field on `Deployment` (and, if present, `ServerSite`), the
`DatabaseName`/`Engine` types, and the IP3 Secret naming/keys/labels contract. Implement EP-44
first.

**Soft dependency — EP-45** (`docs/plans/45-...`). EP-45 creates the `nagare-db-<name>` Secret
with the IP3 keys and stamps the `nagare.dev/engine` label that `lookupEngine` reads. M1 and the
render parts of M2/M3 are testable offline against the known contract; the live "app reads a real
database" demonstration and a non-stubbed `lookupEngine` need EP-45 (or a hand-created
IP3-conformant database).

### The per-engine connection-variable contract (IP5)

The canonical reference EP-48 documents. For an app referencing database `<name>` (engine as
shown) in namespace `<ns>`, with host `<name>.<ns>.svc.cluster.local` and Secret `nagare-db-<name>`:

| Engine | Variable | Kind | Value / Secret key |
| --- | --- | --- | --- |
| Postgres | `POSTGRES_HOST` | literal | `<name>.<ns>.svc.cluster.local` |
| Postgres | `POSTGRES_PORT` | literal | `5432` |
| Postgres | `POSTGRES_USER` | literal | the application role (from `ConnIdentity.connUser`) |
| Postgres | `POSTGRES_DB` | literal | the logical database (from `ConnIdentity.connDb`) |
| Postgres | `POSTGRES_PASSWORD` | secret ref | `nagare-db-<name>` key `POSTGRES_PASSWORD` |
| Postgres | `DATABASE_URL` | secret ref | `nagare-db-<name>` key `DATABASE_URL` |
| Redis | `REDIS_HOST` | literal | `<name>.<ns>.svc.cluster.local` |
| Redis | `REDIS_PORT` | literal | `6379` |
| Redis | `REDIS_PASSWORD` | secret ref | `nagare-db-<name>` key `REDIS_PASSWORD` |
| Redis | `REDIS_URL` | secret ref | `nagare-db-<name>` key `REDIS_URL` |
| ClickHouse | `CLICKHOUSE_HOST` | literal | `<name>.<ns>.svc.cluster.local` |
| ClickHouse | `CLICKHOUSE_PORT` | literal | `9000` |
| ClickHouse | `CLICKHOUSE_USER` | literal | the application user (from `ConnIdentity.connUser`) |
| ClickHouse | `CLICKHOUSE_PASSWORD` | secret ref | `nagare-db-<name>` key `CLICKHOUSE_PASSWORD` |
| ClickHouse | `CLICKHOUSE_URL` | secret ref | `nagare-db-<name>` key `CLICKHOUSE_URL` |

The literal-versus-secret-ref split is exactly: **host, port, user, db are literals; password and
composed URL are Secret references.** Every entry is `{Runtime}`-scoped.

**Hard invariant (restated).** A `secretKeyRef` reads from the Secret key whose name equals the
env-variable name (confirmed in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`, `envEntryValue`:
`secretKeyRef.key = n`, the env var name). Therefore the secret-ref env names in the table above
(`POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_PASSWORD`, `REDIS_URL`, `CLICKHOUSE_PASSWORD`,
`CLICKHOUSE_URL`) MUST be byte-identical to the keys EP-45 writes into the `nagare-db-<name>`
Secret (IP3). They were chosen to match, so no re-keying is needed; if EP-45's keys and these
names ever diverge, the app fails to start with a "couldn't find key in Secret" error. This is the
single contract that binds this plan to EP-44/EP-45.

**Precedence.** The connection map is merged with `mergeGenerated connEnv userEnv` (connection map
on the left, so it wins the left-biased `Map.union`). A user-declared variable of the same name
(e.g. a hand-written `DATABASE_URL`) is therefore overridden by the generated Secret reference.
The database variable names are, in effect, reserved for an app that references that engine's
database — the same reserved-and-overriding rule EP-26 applies to `NAGARE_*`.

**Multiple databases.** Different engines coexist (disjoint variable names). Two databases of the
**same** engine collide on the canonical unprefixed names; `mergeConnectionEnvs` detects the
shared key and the deploy fails with a clear collision error. v1 supports at most one database per
engine per app; a future plan may add per-reference prefixes.
