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

Full plan before trimming: [46-generated-database-connection-env-injection-for-apps.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/46-generated-database-connection-env-injection-for-apps.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1 (2026-06-10): New module `cli/nagarectl/src/Nagare/Database/Connection.hs` with the pure
      `connectionEnv` (engine + name + namespace + identity → `Map EnvName ScopedEnvVar`) and the
      per-engine literal/secret-ref split; `mergeConnectionEnvs` with collision detection; added to
      `nagarectl.cabal`. Reuses EP-44's `dbSecretName` rather than redefining.
- [x] M1 (2026-06-10): Unit tests assert, per engine, exactly which keys are `EnvLiteral`s (with the
      right host/port/user/db) and which are `EnvSecretRef`s to `nagare-db-<name>`; all
      `{Runtime}`-scoped.
- [x] M2 (2026-06-10): `runDeploy` consumes `dep ^. #databases`; `resolveConnectionEnv` resolves each
      to its engine + identity (via the new `Nagare.Database.Discover.lookupConnection`, which reads
      the `nagare.dev/engine` label and the Secret's non-secret USER/DB keys) and merges the
      connection map alongside the `NAGARE_*` env via `mergeGenerated`. Empty `databases` ⇒ no cluster
      call (stateless apps unaffected). A render-demonstration test proves the Service carries both the
      literals and a `DATABASE_URL` `secretKeyRef` to `nagare-db-notes-db`.
- [x] M2 (2026-06-10): **Server-deploy skipped in v1** — EP-44 added `databases` only to `Deployment`,
      not `ServerSite`, so server sites cannot reference databases yet (documented; a future plan can
      add the field to `ServerSite`).
- [x] M3 (2026-06-10): Unknown/uncreated database → `lookupConnection` `Left` → deploy `dieT`s with a
      clear "run `nagarectl db create` first / check the namespace" message; same-engine collision →
      `mergeConnectionEnvs` `Left` (tested); precedence (generated wins over user env) tested. All 195
      `nagarectl-test` pass.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The IO engine lookup reused EP-45's `Discover` rather than adding a parallel `lookupEngine`.**
  EP-45 already shipped `Nagare.Database.Discover` with `getDatabase` (engine from the StatefulSet
  label). EP-46 added `lookupConnection` to that same module — it calls `getDatabase` for the engine
  and reads the managed Secret's non-secret `*_USER`/`*_DB` keys for the `ConnIdentity` (the
  authoritative values EP-45 wrote), so `POSTGRES_USER`/`POSTGRES_DB`/`CLICKHOUSE_USER` literals
  reflect cluster truth rather than a re-derived default. Extends, does not fork, per IP4.

- **`ServerSite` has no `databases` field**, so the server-deploy wiring the plan anticipated is
  out of scope for v1 (EP-44 added the field only to `Deployment`). Recorded as a known limitation;
  a follow-up can add `databases` to `ServerSite` and the same `resolveConnectionEnv` merge to
  `deployServer`.

- **`Nagare.Database.Connection` is pure (no IO) and reuses EP-44's `dbSecretName`.** The plan
  sketched a local `dbSecretName :: DatabaseName -> Text`; instead it imports EP-44's
  `dbSecretName :: Text -> Text` and applies it to `databaseNameText name`, keeping a single owner of
  the Secret-name format.

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

EP-46 is complete. An app declares `databases :: [DatabaseName]` (EP-44) and `nagarectl deploy`
injects the per-engine connection env (IP5): host/port/user/db as inline literals, password and
composed URL as `valueFrom.secretKeyRef` into `nagare-db-<name>`. The pure `connectionEnv` and
`mergeConnectionEnvs` (collision-detecting) live in `Nagare.Database.Connection`; the IO engine+
identity resolution is `Nagare.Database.Discover.lookupConnection`; the merge happens in `runDeploy`
alongside the `NAGARE_*` env, generated winning over user env. 9 new tests; 195 `nagarectl-test`
pass.

Against the purpose: the "no `DATABASE_URL`/`REDIS_URL` injection" gap the MasterPlan named is
closed for `Deployment` apps. Gaps: server sites can't reference databases yet (no `ServerSite.
databases` field); the live "app reads a real database" end-to-end demonstration belongs to EP-48.
The hard invariant (secretKeyRef key == env name == IP3 Secret key) holds by construction — the
secret-ref env names match EP-45's Secret keys exactly.

