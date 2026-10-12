---
id: 45
slug: nagarectl-db-lifecycle-commands-and-deploy-time-provisioning
title: "nagarectl db lifecycle commands and deploy-time provisioning"
kind: exec-plan
created_at: 2026-06-10T14:25:20Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
master_plan: "docs/masterplans/9-managed-databases-for-nagare.md"
---

# nagarectl db lifecycle commands and deploy-time provisioning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare developer can deploy stateless apps and attach durable disks to them, but
there is no first-class way to run a *database*. The only stateful example in the repository
(`cluster/examples/sqlite-litestream/`) is hand-written raw Kubernetes YAML, not a Nagare
resource. After this plan a developer can stand up a managed PostgreSQL, Redis, or ClickHouse
instance with a single command, operate it from the CLI, and tear it down safely — all without
hand-writing a manifest, hand-rolling a password, or copying credentials by hand.

Concretely, after this plan the following commands exist and work:

```text
nagarectl db list
nagarectl db create ENGINE NAME        # ENGINE ∈ postgres | redis | clickhouse
nagarectl db get NAME
nagarectl db shell NAME
nagarectl db restart NAME
nagarectl db delete NAME
```

A **database** here is a long-lived, single-replica Kubernetes workload with a stable network
identity, durable storage, and generated credentials. It is rendered as a **StatefulSet** (the
Kubernetes controller for a workload that keeps a stable pod name and disk across restarts and
does *not* scale to zero — unlike a Knative Service), fronted by a **ClusterIP Service** (an
internal-only DNS name such as `pg-main.personal.svc.cluster.local` that other pods use to
reach it; never exposed to the public internet), backed by a **PersistentVolumeClaim** (a
"PVC" — the Kubernetes object that requests a durable disk), and accompanied by a managed
**Secret** holding the generated password and the composed connection URL.

The user-visible win, demonstrable end to end: run `nagarectl db create postgres pg-main`,
watch the CLI generate a strong password, write a managed Secret named `nagare-db-pg-main`,
provision the PVC, StatefulSet, and Service in the correct order, and wait for the database pod
to become Ready; then `nagarectl db list` shows the database and its status; `nagarectl db get
pg-main` shows its engine, version, in-cluster host, and the keys present in its Secret;
`nagarectl db shell pg-main` drops you into a `psql` prompt inside the pod; `nagarectl db
restart pg-main` rolls the pod; and `nagarectl db delete pg-main` removes it, honoring the
retention policy for the data disk. Every mutating command supports `--dry-run`, which prints
exactly the manifests and actions that would be applied without touching the cluster — so the
entire create/delete behavior is provable offline.

This plan is **EP-45** under MasterPlan 9 (`docs/masterplans/9-managed-databases-for-nagare.md`,
"Managed Databases for Nagare"). It **hard-depends on EP-44**
(`docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md`),
which defines the typed `Database` model and the renderer that turns a `Database` into the
StatefulSet/Service/PVC/Secret manifest set. It **soft-depends on EP-43**
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`), the
feasibility spike that proves each engine runs on the live single-node cluster — only the *live*
provisioning leg of this plan needs EP-43; everything else is provable through `--dry-run` and
unit tests.

This plan **owns** two MasterPlan Integration Points:

- **IP4** — the `nagarectl db` subparser in `cli/nagarectl/app/Main.hs` and the new
  `cli/nagarectl/src/Nagare/Database/` module namespace. EP-47
  (`docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md`) will *extend*
  this same subparser with `backup` and `restore` subcommands and reuse this plan's
  resource-discovery helper. This plan therefore designs the subparser and the discovery helper
  to be extended, not forked.

- **The create-time half of IP3** — generating the strong password at `db create` time and
  writing the managed Secret `nagare-db-<name>` with the engine-specific keys, the composed
  connection URL(s), and the IP3 labels. EP-44 owns the Secret *name/key/label contract* (so its
  renderer can reference the Secret); this plan generates the *values* and writes the Secret.
  EP-46 (`docs/plans/46-generated-database-connection-env-injection-for-apps.md`) and EP-47 read
  that Secret by name/label — they must never re-derive credentials.

## Progress

- [x] M1 (2026-06-10): `db` subparser wired into `Main.hs`; `Command` gains `Db DbCommand`;
      `DbCommand` ADT + option records defined; `engineReader`; `runDb` dispatcher;
      `Nagare.Database.Create.runDbCreate` builds the `Database` via EP-44 smart constructors,
      generates the password (`openssl rand`), renders+applies the IP3 Secret, applies
      `renderDatabase` (PVC, ClickHouse ConfigMap, Service, StatefulSet), stamps version/size/
      retention annotations, and waits for rollout; `--dry-run` prints the Secret + manifests and
      applies nothing. Pure helpers (`composeConnectionUrl`, `secretKeysFor`, `engineToken`,
      `passwordKey`, `buildDatabase`) unit-tested. Verified all three engines via real-CLI `--dry-run`.
- [x] M2 (2026-06-10): `Nagare.Database.Discover` (label selector, defensive `extractDbRows`,
      `listDatabases`/`getDatabase`, pure `formatDbTable`); `Nagare.Database.List`/`Get`;
      `db list` and `db get NAME` working (get shows Secret *key names* only). Discovery + table
      tests pass.
- [x] M3 (2026-06-10): `Nagare.Database.Shell` (`kubectl exec -it <name>-0 -- <engine client>`,
      credentials read from the pod env) and `Nagare.Database.Restart` (`kubectl rollout restart` +
      wait; `--dry-run` previews). Verified `db restart --dry-run`.
- [x] M4 (2026-06-10): `Nagare.Database.Delete` honoring `RetentionPolicy` read from the
      `nagare.dev/retention` annotation (Retain ⇒ keep PVC + warn; Delete ⇒ remove it), behind a
      `--yes` guard; deletes StatefulSet → Service → Secret → ConfigMap (→ PVC if Delete) explicitly
      with `--ignore-not-found`. All 186 `nagarectl-test` + 214 `nagare-dsl-test` pass.
- [ ] Live verification on `nagare-01` (deferred-with-instructions; the live create/list/get/shell/
      restart/delete transcripts belong to EP-48, which deploys real databases on the cluster).

## Surprises & Discoveries

- **EP-44 stamps only managed-by/database/engine labels — version/size/retention are not on any
  rendered resource, so `db create` must stamp them itself.** The plan assumed the StatefulSet
  carried engine/version/size labels; EP-44's renderer stamps only the three IP3 labels. Crucially,
  **retention** is a policy that lives only in the typed `Database` at create time and is reflected
  in no Kubernetes spec — so `db delete` cannot read it back unless `db create` persists it.
  Resolution: after applying, `db create` runs one `kubectl annotate statefulset/<name> --overwrite
  nagare.dev/version=… nagare.dev/size=… nagare.dev/retention=…`. `Discover.extractDbRows` reads
  these annotations (version falls back to the container image tag, size to `?`, retention to
  `Retain`); `db delete` reads `nagare.dev/retention`. Recorded as a Decision below.

- **`engineToken`/`dbSecretName` are already exported by EP-44's `Nagare.Dsl.Database`**, so
  `Nagare.Database.Secret` imports them rather than redefining (the plan listed them as new pure
  helpers here). The Secret module owns only the value-side helpers (`composeConnectionUrl`,
  `secretKeysFor`, `renderDbSecret`) and the base64 codec (Env.Store's `b64encode`/`b64decode` are
  not exported, so they are reimplemented from the `memory` package — same codec choice).

- **The managed Secret renders as compact JSON, not YAML** (like `Nagare.Env.Store.renderEnvSecret`),
  while the EP-44 manifests render as YAML. Both are accepted by `kubectl apply -f`, so it is
  correct; the dry-run Secret block is therefore one JSON line rather than a YAML block. Matches the
  existing env-secret house pattern.

- **`optparse-applicative`'s `argument` clashes with lens's `argument`** (both in scope via the
  custom Prelude and the `Options.Applicative` import). Qualified as `Options.Applicative.argument`
  for the `ENGINE` positional. `strArgument` (used elsewhere) is unambiguous.

## Decision Log

- Decision: Generate the database password in the CLI by shelling out to `openssl rand -base64 24`
  via the `Cradle` subprocess library, capturing stdout, and stripping the trailing newline. Fall
  back is not needed: `openssl` is present in the dev shell and on the VM. The 24 raw bytes yield a
  32-character base64 password with ~192 bits of entropy.
  Rationale: the typed DSL is pure and deterministic and must not generate randomness (MasterPlan
  IP3). The CLI already shells out to external tools through `Cradle` everywhere (`kubectl`,
  `gsutil`, `docker`), so `openssl` is consistent with the existing style and needs no new Haskell
  dependency. An alternative — reading from `/dev/urandom` and base64-encoding with the `memory`
  package's `Data.ByteArray.Encoding` (already a dependency, used in `Nagare.Env.Store`) — is
  recorded as the portable fallback if `openssl` is ever unavailable; the chosen path keeps the
  generator a single, auditable shell line.
  Date: 2026-06-10

- Decision: `db create ENGINE NAME` constructs the desired `Database` value *in memory* from argv
  plus flags (`--version`, `--size`, `--resources`/`--cpu`/`--memory`) using EP-44's smart
  constructors with sensible per-engine defaults — it does NOT require a `nagare/Config.hs`. A
  `--config FILE` path that loads a typed `Database` from a file is provided as a secondary form.
  Rationale: `db create` is an imperative operation (the roadmap and MasterPlan present it as
  `nagarectl db create postgres NAME`), so demanding a config file for a one-shot create would be
  awkward. Building the `Database` through EP-44's smart constructors still applies full validation
  (bad names, malformed sizes, unsupported engine/version pairs are rejected with a precise error),
  so we lose no safety. The engine, version, and size are stamped as labels/annotations on the
  StatefulSet at create time so `db list`/`get` can read state back from the live resources without
  a stored config. The `--config` form remains for users who prefer a checked-in typed `Database`.
  Date: 2026-06-10

- Decision: Provision order on create is Secret → PVC → StatefulSet → ClusterIP Service, then wait
  for the StatefulSet to become Ready (`kubectl rollout status statefulset/<name>`), and the entire
  apply path is idempotent (`kubectl apply`, never `kubectl delete`).
  Rationale: the StatefulSet's pod references the Secret (for `POSTGRES_PASSWORD` etc.) and mounts
  the PVC, so both must exist before the pod schedules. Applying the Secret and PVC first guarantees
  this. On the single-node k3s cluster the `local-path` StorageClass binds the PVC under
  `WaitForFirstConsumer` (it stays `Pending` until the pod consumes it), so we do NOT wait for the
  PVC to be `Bound` before the StatefulSet — that would deadlock; we wait for the StatefulSet
  rollout, which binds the PVC as a side effect. This mirrors the ordering EP-35 established for app
  PVCs (`docs/plans/35-...`).
  Date: 2026-06-10

- Decision: `db create` is idempotent with respect to the password: if the managed Secret
  `nagare-db-<name>` already exists, the existing password is reused — it is NOT regenerated.
  Rationale: regenerating the password on a re-run would break every consumer (the StatefulSet, any
  app that injected `DATABASE_URL` via EP-46, and any backup job in EP-47), because their references
  would point at a stale credential. Reusing the existing password keeps re-create a safe no-op for
  credentials while still re-applying the (idempotent) PVC/StatefulSet/Service manifests.
  Date: 2026-06-10

- Decision: `db delete NAME` honors the database's `RetentionPolicy` (the `Retain | Delete` enum
  reused from `Nagare.Dsl.Types`, MasterPlan 7): `Retain` keeps the PVC (and prints a warning naming
  the surviving disk and how to remove it manually); `Delete` removes the PVC too. The command
  deletes the StatefulSet, then the Service, then the Secret, then (conditionally) the PVC —
  explicitly and in that order — and is guarded by a typed `--yes` flag (without it, delete prints
  what it would remove and exits without deleting).
  Rationale: deleting a `local-path` PVC deletes the underlying host directory and all the data, so
  it must be opt-in via the policy, never the default. MasterPlan 7 found that relying on namespace
  cascade leaves resources stuck, so we delete each object explicitly and in dependency order
  (workload before its Service and Secret). The confirmation guard prevents accidental data loss.
  The default policy when none is specified at create is `Retain` (conservative: never lose data by
  default).
  Date: 2026-06-10

- Decision: `db shell NAME` runs `kubectl exec -it <pod> -n <ns> -- <engine client>` where the
  client is `psql` for Postgres, `redis-cli` for Redis, and `clickhouse-client` for ClickHouse, and
  authenticates using the generated credentials read from the managed Secret (passed via the
  engine-appropriate env/flags inside the exec command).
  Rationale: each official engine image ships its own client binary, so exec-ing the client inside
  the running pod needs no extra tooling and no public exposure. The pod name is the StatefulSet's
  stable `-0` ordinal pod (`<name>-0`), so it is deterministic.
  Date: 2026-06-10

- Decision: All mutating `db` commands (`create`, `restart`, `delete`) support `--dry-run`, printing
  the manifests/actions and applying nothing, exactly as the existing `env`/`secret`/`storage`
  commands and the `deploy` path do.
  Rationale: this is the established repository convention and is what makes the create/delete
  behavior fully verifiable offline (no cluster needed), which matters because the cluster is often
  unreachable from a workstation (see Context and Orientation).
  Date: 2026-06-10

- Decision: `db create` stamps `nagare.dev/version`, `nagare.dev/size`, and `nagare.dev/retention`
  as annotations on the StatefulSet via a post-apply `kubectl annotate --overwrite`, because EP-44's
  renderer stamps only the three IP3 labels and retention is reflected in no spec.
  Rationale: `db list`/`get` need version/size for their tables and `db delete` needs the retention
  policy; reading them back from the cluster requires persisting them. Annotating (idempotent,
  `--overwrite`) keeps EP-44's renderer untouched and avoids manifest surgery. `extractDbRows`
  reads the annotations with fallbacks (version → image tag, size → `?`, retention → `Retain`).
  Date: 2026-06-10

- Decision: `loadDatabase` (for the `db create --config` form) was added to `Nagare.Dsl.Load`
  (exported) by this plan, since EP-44 shipped `decodeDatabase` but not the `runConfig`-based loader
  (`runConfig` is private to `Load`). It mirrors `loadDeployment`/`loadStaticSite`.
  Rationale: the `--config` form needs to compile-and-run a `Database` config; the one-line loader
  belongs beside the others in `Load`, not duplicated in the CLI.
  Date: 2026-06-10

- Decision: Put the shared database-discovery logic in a new module `Nagare.Database.Discover` and
  design the `db` subparser so a new subcommand can be added without touching the existing ones.
  Rationale: EP-47 will add `nagarectl db backup` / `db restore`, which must discover the same
  databases by the same IP3 labels. Per MasterPlan IP4, EP-45 owns the subparser wiring and the
  discovery helper; EP-47 must *extend*, not fork, them — exactly as EP-36 extended EP-35's
  `Nagare.Storage.Discover` and the `storage` subparser.
  Date: 2026-06-10

## Outcomes & Retrospective

EP-45 is complete (offline-provable scope). The `nagarectl db` command group
(`list`/`create`/`get`/`shell`/`restart`/`delete`) is wired into `Main.hs` (IP4) with eight new
`Nagare.Database.*` modules. `db create` generates the password (`openssl rand -base64 24`), writes
the IP3 Secret (`nagare-db-<name>` with engine-specific keys + composed URL + IP3 labels — the
create-time half of IP3), applies EP-44's rendered manifests in order, stamps version/size/retention
annotations, and waits for the StatefulSet rollout; it is idempotent and never regenerates the
password. `db delete` honors `RetentionPolicy` behind a `--yes` guard. All mutating commands support
`--dry-run`. 15 new pure tests; 186 `nagarectl-test` + 214 `nagare-dsl-test` pass.

Two coordination points with EP-44 surfaced (recorded in Surprises): EP-44 stamps only the three IP3
labels, so `db create` annotates version/size/retention itself; and `loadDatabase` was added to
`Nagare.Dsl.Load` for the `--config` form. The contracts EP-46/EP-47 consume are now fixed: the IP3
Secret (name/keys/labels/values), `Nagare.Database.Discover.{dbLabelSelector,listDatabases,
getDatabase}` (the IP4 discovery helper EP-47 extends), and the `db` subparser extension point.

Deferred: the live create/list/get/shell/restart/delete transcripts on `nagare-01` (the cluster is
unreachable from a workstation; the live leg is exercised by EP-48, which deploys the three example
databases end to end).

