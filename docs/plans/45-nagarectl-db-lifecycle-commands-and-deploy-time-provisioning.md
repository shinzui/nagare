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


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing anything.

**Where the code lives.** The deploy CLI is a Haskell package under `cli/nagarectl/`:

- `cli/nagarectl/app/Main.hs` — the command-line entry point. It uses the `optparse-applicative`
  library to describe a tree of subcommands (`subparser ( command "deploy" … <> command "storage" …
  )`) and a single `Command` sum type, then dispatches in `main = execParser opts >>= \case …`.
- `cli/nagarectl/src/Nagare/` — the library modules each command's handler lives in. Existing
  namespaces include `Nagare.Storage.*` (the `storage` commands — the closest precedent),
  `Nagare.Env.Store` (rendering and applying a managed Secret — the precedent for IP3 here),
  `Nagare.App` (app lifecycle), and `Nagare.Deploy` (the thin `kubectl` apply/wait layer).
- `cli/nagarectl/nagarectl.cabal` — the build manifest; library `exposed-modules`, the executable
  `nagarectl`, and the test suite `nagarectl-test`.
- `cli/nagarectl/test/Spec.hs` — the test suite, `tasty` + `tasty-hunit`, exercising *pure* logic.
  Cluster/`kubectl` behavior is exercised by `--dry-run` and by hand, not in this suite.
- The typed config model is a separate package under `cli/nagare-dsl/`. EP-44 adds
  `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` (the `Database` type, the `Engine` enum, the smart
  constructors) and `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` (the renderer
  `renderDatabase :: Database -> [ByteString]`). It reuses the existing `Namespace`, `Quantity`,
  `Resources`, and `RetentionPolicy` types from `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`.

**Key terms, defined in plain language.**

- *StatefulSet*: a Kubernetes controller for a workload that needs a stable identity and durable
  storage. Its pod gets a fixed name (`<name>-0` for a single replica) and keeps the same PVC across
  restarts. Short `kubectl` type: `statefulset` (or `sts`). Unlike a Knative Service it does not
  scale to zero.
- *ClusterIP Service*: a Kubernetes Service with a cluster-internal IP and DNS name
  (`<name>.<namespace>.svc.cluster.local`). It is how other pods reach the database; it is never
  exposed to the public internet. Short `kubectl` type: `service` (or `svc`).
- *PersistentVolumeClaim (PVC)*: the object that requests a durable disk. On this single-node k3s
  cluster it is satisfied by the built-in `local-path` StorageClass, which creates a directory on
  the node and binds the PVC only once a consuming pod is scheduled (`WaitForFirstConsumer`).
- *managed Secret*: a Kubernetes `Secret` (base64-encoded `data`, type `Opaque`) that Nagare creates
  and labels with `nagare.dev/managed-by: nagarectl`. This plan creates one per database holding the
  generated password and the composed connection URL.
- *`Cradle`*: the Haskell library this project uses to run subprocesses. `run_ $ cmd "kubectl" &
  addArgs [...]` runs a command and throws on non-zero exit (use for apply/wait/delete);
  `(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs [...] & silenceStderr` captures stdout
  and tolerates a non-zero exit (use for `kubectl get -o json` and for capturing `openssl` output).
- *IP3 / IP4*: MasterPlan 9 "Integration Points" — IP3 is the managed credential Secret contract
  (name/keys/labels), IP4 is the `db` command-group plumbing. Both are defined in
  `docs/masterplans/9-managed-databases-for-nagare.md`.

**The subparser pattern you will copy.** In `cli/nagarectl/app/Main.hs`, `opts :: ParserInfo Command`
builds the command tree. The top-level parser combines all groups:

```haskell
    commandParser =
      subparser
        ( command "deploy" deployCmd
            <> command "site" siteCmd
            <> command "env" envCmd
            <> command "secret" secretCmd
            <> command "app" appCmd
            <> command "deployments" deploymentsCmd
            <> command "storage" storageCmd
            <> command "server" serverCmd
            <> command "doctor" doctorCmd
            <> command "domains" domainsCmd
            <> command "cleanup" cleanupCmd
        )
```

You will add `<> command "db" dbCmd`. The closest model for `dbCmd` is `storageCmd`, a nested
subparser whose subcommands carry one constructor each:

```haskell
    storageCmd =
      info
        (storageSubparser <**> helper)
        (fullDesc <> progDesc "Inspect an app's persistent volumes")
    storageSubparser =
      subparser
        ( command "list"    ( info (Storage . StorageList    <$> storeCommonOptsParser <**> helper) (progDesc "...") )
            <> command "inspect" ( info (Storage <$> (StorageInspect <$> storeCommonOptsParser <*> strArgument (metavar "VOLUME")) <**> helper) (progDesc "...") )
            <> command "snapshot" ( info (...) (...) )
        )
```

`Storage` is the `Command` constructor wrapping a `StorageCommand` sum type (one constructor per
subcommand), dispatched in `main` by `Storage scmd -> runStorage scmd`, and `runStorage` is a
`\case` over the `StorageCommand` constructors. You will mirror this exactly for `db`: a `Db
DbCommand` constructor on `Command`, a `DbCommand` sum type, a `runDb :: DbCommand -> IO ()`
dispatcher, and one handler module per subcommand under `Nagare.Database.*`.

**The IP3 precedent — rendering and applying a Secret.**
`cli/nagarectl/src/Nagare/Env/Store.hs` already renders and applies a managed Secret:
`renderEnvSecret app ns scope kvs :: ByteString` builds the JSON (`kind: Secret`, `type: Opaque`,
`data` base64-encoded via the `memory` package's `convertToBase Base64`, sorted keys for
determinism) and `writeSecretStore = applyManifests [renderEnvSecret …]` applies it with `kubectl
apply -f`. The base64 helper `b64encode :: Text -> Text` and the `data` builder there are the
pattern this plan's Secret renderer copies. The crucial difference: this plan's Secret is keyed and
labeled per IP3 (engine-specific keys plus a composed URL, labels `nagare.dev/managed-by`,
`nagare.dev/database`, `nagare.dev/engine`), and its name is `nagare-db-<name>`, not the env-store
name.

**The discovery precedent.** `cli/nagarectl/src/Nagare/Storage/Discover.hs` shows the exact shape of
the discovery helper this plan needs: a pure label selector (`appPVCLabelSelector app =
"nagare.dev/app=" <> app`), a defensive `extractPVCStatus :: ByteString -> Either Text [PVCRow]`
that walks `kubectl get … -o json` with local `lookupPath`/`textAt` helpers (never crashing on a
malformed shape), a `listAppPVCs :: Text -> Text -> IO (Either Text [PVCRow])` that runs `kubectl get
pvc -l <selector> -o json` and returns `Right []` on a failed query, and a pure `formatStorageTable`
that pads columns. `Nagare.Database.Discover` mirrors all four for databases.

**Cluster access reality (important — read this before attempting a live run).** The single-node VM
`nagare-01` is often in the `TERMINATED` state and must be started first. It is reached over an IAP
tunnel that forwards *only* SSH (port 22) via `scripts/iap-ssh.sh` as the `deploy` user; a
workstation `kubectl` therefore cannot reach the k3s API directly. The workstation's default
`kubectl` context points at an unrelated GKE cluster — do NOT use it. Consequently the *live*
provisioning leg of this plan must run `nagarectl` on the VM itself, or via an SSH port-forward of
the k3s API (`ssh -L 16443:127.0.0.1:6443 …` then point `KUBECONFIG` at a copy of
`/etc/rancher/k3s/k3s.yaml` with `server:` rewritten to the forwarded port). All of the
create/list/get/delete behavior is otherwise provable offline through `--dry-run` and the unit
tests, so the live leg is deferred-with-instructions (the precedent is EP-35/36/37, which deferred
on-cluster transcripts to the docs plan EP-37). The live database transcripts for this plan belong
to EP-48 (`docs/plans/48-managed-databases-docs-and-end-to-end-examples.md`), which deploys real
databases on the cluster.

**GCP project isolation.** Per the repository `CLAUDE.md`, all cluster/GCP work targets `tan-nb-exp`
only (region `us-west1`, zone `us-west1-a`). This plan issues no `gcloud` calls (backups are EP-47's
concern); its `kubectl` calls target the active `tan-nb-exp` cluster context the repo's `.envrc`
configures.

**State of the dependency right now.** As of authoring, EP-44 has not yet merged the `Database` type
or the renderer (`cli/nagare-dsl/src/Nagare/Dsl/Database.hs` and `…/Database/Render.hs` do not exist
yet). This plan **hard-depends on EP-44**: do not begin M1's implementation until EP-44 has merged
the `Database`/`Engine` types, their smart constructors, and `renderDatabase`. The Interfaces and
Dependencies section records the exact signatures to code against; treat any mismatch with what EP-44
actually ships as a coordination point and update this plan (the *shapes* are fixed by the
MasterPlan; only the Haskell identifiers may need a rename).


## Plan of Work

The work is four milestones. M1 delivers the `db` subparser plumbing and `db create` (the
credential generation, the IP3 Secret, and the ordered provision) — the riskiest and most novel
part. M2 adds read commands (`list`, `get`) on a shared discovery helper. M3 adds `shell` and
`restart`. M4 adds `delete` with retention handling and a confirmation guard. Each milestone is
independently verifiable; M1–M4 are each provable offline through `--dry-run` plus unit tests, with
the live legs deferred-with-instructions per Context and Orientation.

### Milestone 1 — `db` subparser plumbing and `db create`

**Scope.** Wire the `db` command group into `Main.hs`, define the `DbCommand` ADT and the `runDb`
dispatcher, and implement `nagarectl db create ENGINE NAME` end to end: build the desired `Database`
in memory from argv plus flags through EP-44's smart constructors; generate a strong password;
render and apply the managed Secret `nagare-db-<name>` (IP3); then apply the PVC, StatefulSet, and
ClusterIP Service in that order via EP-44's `renderDatabase`; then wait for the StatefulSet to become
Ready. `--dry-run` prints the Secret (with a generated password), then the PVC, StatefulSet, and
Service manifests, applying nothing. At the end of M1, a developer can run `nagarectl db create
postgres pg-main --dry-run` and see the full manifest set.

**The credential generation, explained.** The typed DSL cannot generate randomness (it is pure), so
the CLI generates the password. The handler shells out via `Cradle`:

```haskell
generatePassword :: IO Text
generatePassword = do
  (code, StdoutRaw out) <- run $ cmd "openssl" & addArgs ["rand", "-base64", "24"] & silenceStderr
  case code of
    ExitSuccess -> pure (T.strip (TE.decodeUtf8 out))
    ExitFailure _ -> dieT "could not generate a password: 'openssl rand' failed"
```

24 raw bytes base64-encode to 32 characters (~192 bits). The `T.strip` removes `openssl`'s trailing
newline.

**The idempotent-password rule.** Before generating, the handler checks whether the managed Secret
already exists by reading it with `kubectl get secret nagare-db-<name> -n <ns> -o json` (reusing the
defensive read pattern from `Nagare.Env.Store.readStore`). If it exists, the existing password is
read out of its `data` (base64-decoded with the `b64decode` helper from `Nagare.Env.Store`, which
this plan re-exports or copies) and reused; only when the Secret is absent is a fresh password
generated. Under `--dry-run` no cluster read happens, so dry-run always shows a freshly generated
password (clearly an illustrative value).

**The Secret contract (IP3) this plan writes.** The Secret is named `nagare-db-<name>` in the
database's namespace, type `Opaque`, with labels `nagare.dev/managed-by: nagarectl`,
`nagare.dev/database: <name>`, `nagare.dev/engine: <engine>` (where `<engine>` is the lower-case
token `postgres` | `redis` | `clickhouse`). The `data` keys are engine-specific and fixed:

- *Postgres*: `POSTGRES_PASSWORD` (the generated password), `POSTGRES_USER` (default `nagare`),
  `POSTGRES_DB` (default the database name), and `DATABASE_URL` =
  `postgresql://<user>:<password>@<host>:5432/<db>`.
- *Redis*: `REDIS_PASSWORD` (the generated password) and `REDIS_URL` =
  `redis://:<password>@<host>:6379`.
- *ClickHouse*: `CLICKHOUSE_PASSWORD` (the generated password), `CLICKHOUSE_USER` (default
  `nagare`), and `CLICKHOUSE_URL` = `clickhouse://<user>:<password>@<host>:9000`.

`<host>` in every URL is the deterministic in-cluster DNS name
`<name>.<namespace>.svc.cluster.local`, which is the ClusterIP Service EP-44 renders. The composed
URL is computed by a pure helper `composeConnectionUrl :: Engine -> ConnectionParts -> Text` that is
unit-tested; the key set is computed by a pure helper `secretKeysFor :: Engine -> ConnectionParts ->
[(Text, Text)]` that is unit-tested. The Secret JSON is built with the same `kind: Secret`, `type:
Opaque`, base64 `data` (sorted keys), plus `metadata.labels`, exactly as `renderEnvSecret` does in
`Nagare.Env.Store`.

**The edits.**

*Edit 1 — the `DbCommand` ADT and options, in `Main.hs`.* Add to the `Command` sum type a
constructor `Db DbCommand`. Define the `DbCommand` sum type and the options records (see Interfaces
and Dependencies for the exact text). One constructor per subcommand. `DbCreate` carries the engine,
the name, and the create options (version, size, resources, dry-run, optional `--config`); the
read/single-name commands carry a name plus a namespace option.

*Edit 2 — the `db` subparser, in `opts`.* Add `<> command "db" dbCmd` to `commandParser`, and define
`dbCmd` as a nested subparser with `command "list" … <> command "create" … <> command "get" … <>
command "shell" … <> command "restart" … <> command "delete" …`, each `info (…  <**> helper)
(progDesc "…")`, mirroring `storageSubparser`. The `create` command takes two positional arguments
(`ENGINE`, `NAME`) parsed with `strArgument`, plus the option fragments. Parse `ENGINE` into the
typed `Engine` with a small `engineReader :: ReadM Engine` (an `optparse-applicative` `eitherReader`
that maps `"postgres"`/`"redis"`/`"clickhouse"` to the enum, erroring on anything else). Design note
for EP-47: a `command "backup" …` and `command "restore" …` slot into this subparser with no change
to the others — this is the IP4 extension point.

*Edit 3 — the `runDb` dispatcher and the `main` case.* Add `Db dcmd -> runDb dcmd` to the `main`
`\case`, and define `runDb :: DbCommand -> IO ()` as a `\case` calling the per-subcommand handlers
(`Nagare.Database.Create.runDbCreate`, etc.).

*Edit 4 — the create handler, `cli/nagarectl/src/Nagare/Database/Create.hs`.* Implement
`runDbCreate`: resolve the namespace; build the `Database` in memory through EP-44's smart
constructors (or load it from `--config` if given), dying with a precise error on validation
failure; compute the in-cluster host; under `--dry-run`, generate an illustrative password, render
the Secret + the `renderDatabase` manifest list, and print them in order (Secret first) with
`--- Secret manifest ---` / `--- PersistentVolumeClaim manifest ---` / `--- StatefulSet manifest ---`
/ `--- Service manifest ---` headers; otherwise, read-or-generate the password (idempotent rule),
apply the Secret, then apply the PVC/StatefulSet/Service from `renderDatabase`, then
`waitForRollout`, then print `Created database <name> (<engine>) at <host>`.

*Edit 5 — pure helpers, `cli/nagarectl/src/Nagare/Database/Secret.hs`.* Hold the pure
`composeConnectionUrl`, `secretKeysFor`, `engineToken`, `dbSecretName`, the IP3 label set, and
`renderDbSecret :: DbSecretInputs -> ByteString` (the Secret JSON builder mirroring `renderEnvSecret`).
Keeping these pure and in their own module makes them unit-testable and makes the contract EP-46/EP-47
read explicit in one place.

*Edit 6 — register modules and wire imports.* Add `Nagare.Database.Create`, `Nagare.Database.Secret`
(and, in later milestones, `Discover`, `Get`, `List`, `Shell`, `Restart`, `Delete`) to the library
`exposed-modules` in `cli/nagarectl/nagarectl.cabal`. The needed dependencies (`aeson`, `cradle`,
`nagare-dsl`, `text`, `bytestring`, `temporary`, `memory`) are already present.

**Commands to run (M1).**

```bash
cd cli/nagarectl
cabal build
```

```bash
nagarectl db create postgres pg-main --dry-run
nagarectl db create redis cache --dry-run
nagarectl db create clickhouse analytics --dry-run
```

**Acceptance (M1).** `cabal build` is clean. Each `--dry-run` prints a `--- Secret manifest ---`
block first (with the engine-specific keys, a base64 value for the generated password, the composed
URL key, and the IP3 labels), then the PVC, StatefulSet, and Service blocks (whose bytes are EP-44's
to fix), and finally a summary line. No cluster contact occurs. The pure helpers pass their unit
tests (`composeConnectionUrl`, `secretKeysFor`, `engineToken`). See Validation and Acceptance for the
exact transcript.

### Milestone 2 — `db list` and `db get`

**Scope.** Add `nagarectl db list` (a table of all managed databases in a namespace) and `nagarectl
db get NAME` (one database's detail), discovered from the live cluster by the IP3 labels, on a shared
`Nagare.Database.Discover` helper EP-47 will reuse. At the end of M2, `db list` prints a table and `db
get NAME` prints a field block.

**New module — `cli/nagarectl/src/Nagare/Database/Discover.hs`.** Mirrors
`Nagare.Storage.Discover`: a pure label selector `dbLabelSelector :: Text` =
`"nagare.dev/managed-by=nagarectl,nagare.dev/database"` (selects every managed database — having the
`nagare.dev/database` label present, with `managed-by=nagarectl`); a defensive `extractDbRows ::
ByteString -> Either Text [DbRow]` that walks `kubectl get statefulset … -o json` (the StatefulSet
carries the engine/version/size labels stamped at create time, plus `.status.readyReplicas`); a
`listDatabases :: Text -> IO (Either Text [DbRow])` that runs `kubectl get statefulset -n <ns> -l
<dbLabelSelector> -o json` and returns `Right []` on a failed query; and a pure `formatDbTable ::
[DbRow] -> Text` with `pad`-aligned columns `NAME ENGINE VERSION SIZE STATUS HOST`. `DbRow` carries
`drName, drEngine, drVersion, drSize, drReady :: Bool, drHost`. EP-47 reuses `listDatabases` /
`dbLabelSelector` to find the same databases by the same labels — extend, not fork.

**New module — `cli/nagarectl/src/Nagare/Database/List.hs`.** `runDbList :: Text -> IO ()` (namespace)
loads the rows via `Discover.listDatabases`, prints `formatDbTable`, and prints `(no managed
databases)` when empty.

**New module — `cli/nagarectl/src/Nagare/Database/Get.hs`.** `runDbGet :: Text -> Text -> IO ()`
(namespace, name) reads the one StatefulSet, prints `Name / Engine / Version / Size / Host / Ready`,
and additionally reads the managed Secret `nagare-db-<name>` and prints the *key names present* (never
the values), so the operator can see which connection variables exist. A missing database is a clear
error (exit non-zero).

**Subparser/dispatch wiring.** Add `DbList DbListOpts` and `DbGet DbNameOpts` constructors and their
`db list` / `db get` commands and `runDb` cases.

**Tests.** In `Spec.hs`, add a `Nagare.Database.Discover` group: `dbLabelSelector` is the expected
string; `extractDbRows` on a small hand-written StatefulSet-list fixture returns the expected rows;
`extractDbRows` on `{"items":[]}` is `Right []`; on malformed JSON is `Left`; `formatDbTable` on a
known list produces the expected header and a row.

**Commands to run (M2).**

```bash
cd cli/nagarectl
cabal build
cabal test
nagarectl db list           # against the cluster (or shows empty when unreachable)
nagarectl db get pg-main
```

**Acceptance (M2).** `cabal test` is green including the new group. `db list` prints the table (one
row per managed database, `READY=False`/`True`); `db get NAME` prints the field block plus the Secret
key names; an unknown name errors clearly.

### Milestone 3 — `db shell` and `db restart`

**Scope.** Add `nagarectl db shell NAME` (an interactive engine client inside the pod) and `nagarectl
db restart NAME` (roll the StatefulSet pod and wait Ready).

**New module — `cli/nagarectl/src/Nagare/Database/Shell.hs`.** `runDbShell :: Text -> Text -> IO ()`
(namespace, name) resolves the engine from the StatefulSet's `nagare.dev/engine` label (via
`Discover`), then `run_ $ cmd "kubectl" & addArgs ["exec", "-it", "<name>-0", "-n", ns, "--",
<client> …]` where `<client>` is `psql` (Postgres, reading `PGPASSWORD`/`PGUSER`/`PGDATABASE` from the
pod's env, which the StatefulSet already sets from the Secret), `redis-cli` with `-a "$REDIS_PASSWORD"`
(Redis), or `clickhouse-client --password "$CLICKHOUSE_PASSWORD"` (ClickHouse). Because the
credentials are already present in the pod's environment (the StatefulSet wires them from the Secret),
the exec form references them by env-var rather than embedding the secret in argv. The `-it` flags
attach the terminal so the client is interactive.

**New module — `cli/nagarectl/src/Nagare/Database/Restart.hs`.** `runDbRestart :: Text -> Text -> Bool
-> IO ()` (namespace, name, dry-run) rolls the StatefulSet by patching a restart annotation
(`kubectl rollout restart statefulset/<name> -n <ns>`), then `waitForRollout`. Under `--dry-run` it
prints the command it would run and does nothing.

**Wiring.** Add `DbShell DbNameOpts` and `DbRestart DbNameOpts Bool` constructors, the subcommands,
and `runDb` cases.

**Commands to run (M3).**

```bash
cd cli/nagarectl
cabal build
nagarectl db restart pg-main --dry-run
# live (on the VM): nagarectl db shell pg-main  → a psql prompt
```

**Acceptance (M3).** `cabal build` clean. `db restart --dry-run` prints the rollout command without
running it. Live (deferred-with-instructions): `db restart` rolls the pod and returns once Ready; `db
shell` opens an interactive client inside the pod.

### Milestone 4 — `db delete` with retention and a confirmation guard

**Scope.** Add `nagarectl db delete NAME` that honors the database's `RetentionPolicy`, deletes the
StatefulSet → Service → Secret (→ PVC when policy is `Delete`) explicitly and in order, and is guarded
by a `--yes` flag.

**New module — `cli/nagarectl/src/Nagare/Database/Delete.hs`.** `runDbDelete :: DbDeleteOpts -> IO ()`
resolves the namespace, reads the database's retention policy (from the StatefulSet's stamped
`nagare.dev/retention` annotation, falling back to `Retain` if absent), and:

- Without `--yes` (or with `--dry-run`): print exactly which objects would be deleted (and, for
  `Retain`, note the PVC is kept), then exit without deleting.
- With `--yes`: delete in order — `kubectl delete statefulset/<name>`, then `service/<name>`, then
  `secret/nagare-db-<name>`, each `--ignore-not-found`; then, only if the policy is `Delete`, delete
  the PVC; if the policy is `Retain`, print a warning naming the surviving PVC and the manual command
  to remove it. Print `Deleted database <name>` on success.

Deleting each object explicitly and in dependency order (workload first, then its Service and Secret)
follows MasterPlan 7's finding that namespace-cascade leaves resources stuck.

**Wiring.** Add a `DbDelete DbDeleteOpts` constructor (carrying name, namespace, `--yes`, `--dry-run`),
the subcommand, and the `runDb` case.

**Commands to run (M4).**

```bash
cd cli/nagarectl
cabal build
nagarectl db delete pg-main            # prints the plan, deletes nothing (no --yes)
nagarectl db delete pg-main --yes      # live: deletes, honoring retention
```

**Acceptance (M4).** Without `--yes`, `db delete` prints the deletion plan and the retention note and
exits without deleting. With `--yes`, the StatefulSet/Service/Secret are removed in order; the PVC is
removed only when the policy is `Delete`, and a warning is printed when it is `Retain`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a `cd` is
shown. `kubectl` targets the active `tan-nb-exp` cluster context the repo's `.envrc` configures; per
`CLAUDE.md` no other GCP project may be touched, and this plan issues no `gcloud` calls. The
`--ghc-env <env-file>` flag (or the `NAGARE_GHC_ENVIRONMENT` env var) points the config loader's
`runghc` at the `nagare-dsl` package; it is needed only by the `--config` form of `db create`.

1. Confirm EP-44 has landed the `Database` model and renderer:

```bash
grep -n "data Database\|data Engine\|renderDatabase\|mkDatabaseName\|mkEngineVersion" cli/nagare-dsl/src/Nagare/Dsl/Database.hs cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs
```

   You should see the `Database`/`Engine` types, their smart constructors, and `renderDatabase`. If
   not, EP-44 is incomplete — pause M1 and coordinate (see Context and Orientation).

2. M1 — add the `Db`/`DbCommand` types and the `db` subparser to `cli/nagarectl/app/Main.hs`, create
   `cli/nagarectl/src/Nagare/Database/Secret.hs` and `…/Create.hs`, register them in
   `nagarectl.cabal`, and add the pure tests to `cli/nagarectl/test/Spec.hs`. Build and test:

```bash
cd cli/nagarectl
cabal build
cabal test
```

   Expected: `Linking …` with no errors; all test groups pass including `Nagare.Database.Secret`.

3. M1 dry-run check (no cluster contact). Compare against the transcripts in Validation and
   Acceptance:

```bash
nagarectl db create postgres pg-main --dry-run
```

4. M2 — create `Nagare.Database.Discover`, `…/List.hs`, `…/Get.hs`, register them, wire the
   subcommands, add the discovery tests. Build and test as in step 2.

5. M3 — create `…/Shell.hs`, `…/Restart.hs`, wire the subcommands. Build; verify `db restart
   --dry-run`.

6. M4 — create `…/Delete.hs`, wire the subcommand. Build; verify `db delete` (no `--yes`) prints the
   plan and deletes nothing.

7. Live verification on `nagare-01` (deferred-with-instructions): start the VM, reach it via
   `scripts/iap-ssh.sh`, and run the create/list/get/shell/restart/delete sequence on the VM (or via
   an SSH-forwarded k3s API port). See Validation and Acceptance; the live transcripts are recorded by
   EP-48.

Commit after each milestone with Conventional Commit messages and these trailers on every commit:

```text
feat(cli): EP-45 nagarectl db create with credential generation and ordered provision

MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md
Intention: intention_01ktryacjaezzbezmkt5j93abq
```

Commit directly to the current branch (no feature branch unless explicitly requested).


## Validation and Acceptance

Acceptance is phrased as behavior you can observe.

**M1 — `db create` dry-run (Postgres).** With no config file required:

```text
$ nagarectl db create postgres pg-main --dry-run
--- Secret manifest ---
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: nagare-db-pg-main
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/database: pg-main
    nagare.dev/engine: postgres
data:
  DATABASE_URL: <base64 of postgresql://nagare:****@pg-main.personal.svc.cluster.local:5432/pg_main>
  POSTGRES_DB: <base64 of pg_main>
  POSTGRES_PASSWORD: <base64 of the generated password>
  POSTGRES_USER: <base64 of nagare>
--- PersistentVolumeClaim manifest ---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-db-pg-main-data
  ...
--- StatefulSet manifest ---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg-main
  ...
--- Service manifest ---
apiVersion: v1
kind: Service
metadata:
  name: pg-main
  ...
Would create database pg-main (postgres) at pg-main.personal.svc.cluster.local
```

The Secret block prints first (it is applied first), then the PVC, StatefulSet, and Service (whose
exact bytes are EP-44's to fix). What M1 proves is that the Secret carries the IP3 keys/labels and the
composed URL, and that the manifests print in apply order. The Redis and ClickHouse forms print the
engine-specific key set (`REDIS_PASSWORD`/`REDIS_URL`; `CLICKHOUSE_PASSWORD`/`CLICKHOUSE_USER`/
`CLICKHOUSE_URL`).

**M1 — live create provisions in order, then Ready (deferred-with-instructions).** Against
`tan-nb-exp` on the VM:

```text
$ nagarectl db create postgres pg-main
secret/nagare-db-pg-main created
persistentvolumeclaim/nagare-db-pg-main-data created
statefulset.apps/pg-main created
service/pg-main created
statefulset rolling update complete
Created database pg-main (postgres) at pg-main.personal.svc.cluster.local
```

The `secret/… created` line appears before the workload. Re-running `nagarectl db create postgres
pg-main` reports `secret/nagare-db-pg-main unchanged` and reuses the password (the StatefulSet/Service
report `unchanged`); the data is never wiped.

**M1 — pure tests.**

```text
$ cabal test
  Nagare.Database.Secret
    composeConnectionUrl postgres builds postgresql URL:   OK
    composeConnectionUrl redis builds redis URL:           OK
    composeConnectionUrl clickhouse builds clickhouse URL: OK
    secretKeysFor postgres has the four keys:              OK
    engineToken maps the three engines:                    OK
All N tests passed
```

**M2 — `db list` / `db get`.**

```text
$ nagarectl db list
  NAME       ENGINE      VERSION   SIZE    STATUS   HOST
  pg-main    postgres    16        10Gi    Ready    pg-main.personal.svc.cluster.local
```

```text
$ nagarectl db get pg-main
Name:     pg-main
Engine:   postgres
Version:  16
Size:     10Gi
Host:     pg-main.personal.svc.cluster.local
Ready:    True
Secret:   nagare-db-pg-main (DATABASE_URL, POSTGRES_DB, POSTGRES_PASSWORD, POSTGRES_USER)
```

`db get` prints the Secret *key names only*, never values. An unknown name errors:

```text
$ nagarectl db get nope
nagarectl: no managed database named 'nope' in namespace personal
```

**M2 — discovery tests** pass in the `Nagare.Database.Discover` group (selector string, row
extraction from a fixture, empty-items, malformed-JSON `Left`, table formatting).

**M3 — `db restart` dry-run and `db shell` (deferred).**

```text
$ nagarectl db restart pg-main --dry-run
Would run: kubectl rollout restart statefulset/pg-main -n personal
```

Live, `db restart pg-main` rolls the pod and returns `Restarted: pg-main` once Ready; `db shell
pg-main` opens an interactive `psql` prompt inside `pg-main-0`.

**M4 — `db delete`.**

```text
$ nagarectl db delete pg-main
Would delete (run again with --yes):
  statefulset/pg-main
  service/pg-main
  secret/nagare-db-pg-main
Retention is Retain: the data volume nagare-db-pg-main-data is KEPT.
  Remove it manually with: kubectl delete pvc nagare-db-pg-main-data -n personal
```

```text
$ nagarectl db delete pg-main --yes
statefulset.apps "pg-main" deleted
service "pg-main" deleted
secret "nagare-db-pg-main" deleted
Retention is Retain: kept pvc nagare-db-pg-main-data (delete manually to reclaim the disk).
Deleted database pg-main
```

With a `Delete` retention policy, the final lines instead read `persistentvolumeclaim
"nagare-db-pg-main-data" deleted` and omit the warning.

**Tests.**

```bash
cd cli/nagarectl
cabal test
```

The new `Nagare.Database.Secret` and `Nagare.Database.Discover` groups fail before their modules exist
and pass after, demonstrating the logic beyond mere compilation.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **`db create` is idempotent and never regenerates the password.** It reads the existing
  `nagare-db-<name>` Secret and reuses its password when present; only an absent Secret triggers
  generation. The PVC/StatefulSet/Service are applied with `kubectl apply`, so re-applying reports
  `unchanged` and changes nothing. The create path never issues `kubectl delete`, so it can never wipe
  data.
- **A half-finished create is recoverable by re-running.** If `db create` fails after the Secret/PVC
  but before the StatefulSet is Ready (e.g. a bad image), fix the cause and re-run: the Secret already
  exists (password reused), the PVC already exists, and the StatefulSet/Service are re-applied.
- **`db list`, `db get` are read-only** (`kubectl get`); they can be run any number of times and
  degrade to an empty/`(no managed databases)` result when the cluster API is unreachable.
- **`db restart` is safe to repeat** — each run rolls a fresh pod; `--dry-run` previews it.
- **`db delete` is gated by `--yes`** — without it, nothing is deleted. With it, each delete uses
  `--ignore-not-found`, so re-running after a partial failure is safe. A `Retain` policy never deletes
  the PVC, so the data survives an accidental delete; recovery is `db create` again against the kept
  disk (the StatefulSet re-binds the existing PVC).
- **A `Pending` PVC after a failed create is expected, not an error** — `local-path` is
  `WaitForFirstConsumer`, so the PVC stays `Pending` until the StatefulSet pod schedules; the next
  successful create/rollout binds it.
- **Cluster isolation.** All `kubectl` calls target the active `tan-nb-exp` context; no command here
  targets another GCP project, and there is no `gcloud`/GCS use (that is EP-47's concern).


## Interfaces and Dependencies

**Libraries used.** `optparse-applicative` (the command tree, in `Main.hs`); `cradle` (subprocess
calls to `kubectl` and `openssl`, already a dependency); `aeson` (rendering the Secret JSON and
parsing `kubectl get … -o json`); `memory` (base64 via `Data.ByteArray.Encoding`, already used by
`Nagare.Env.Store`); `text`, `bytestring`, `temporary` (already used). No new dependency is added.

**Consumed from EP-44**
(`docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md`),
via MasterPlan Integration Points IP1/IP2/IP3. These must exist before M1 is implemented; the exact
Haskell identifiers are EP-44's to fix — the signatures below are the contract this plan codes against,
and any renaming must be reflected here and at the call sites:

- The `Database` record and the `Engine` enum in `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`
  (re-exported via the DSL's public surface), with the fields named in MasterPlan IP1 (`dbName`,
  `engine`, `version`, `namespace`, `size`, `resources`, `retention`) and accessors for each.
- Smart constructors `mkDatabaseName :: Text -> Either Text DatabaseName`, `mkEngineVersion :: Engine
  -> Text -> Either Text EngineVersion`, and a `mkDatabase`/record builder that validates and assembles
  a `Database` — so `db create` can build one in memory with full validation and no config file.
- `renderDatabase :: Database -> [ByteString]` — render the StatefulSet, ClusterIP Service, and PVC
  manifests (in apply order: PVC, then StatefulSet, then Service) for a database. The managed Secret's
  *values* are NOT rendered here (the DSL is pure); this plan renders and applies the Secret itself
  per IP3. (Confirm EP-44's exact name; if the list also includes a Secret-skeleton, this plan
  overlays the generated values.)
- The deterministic in-cluster host the renderer's Service uses, e.g. a helper `dbHost :: Database ->
  Text` returning `<name>.<namespace>.svc.cluster.local`, and the PVC name (e.g.
  `nagare-db-<name>-data`). If EP-44 exposes these as helpers, this plan imports them rather than
  re-deriving; otherwise this plan computes the host from the validated name/namespace and records the
  string contract here.

**Consumed from the existing CLI:**

- `Nagare.Deploy.applyManifests :: [ByteString] -> IO ()` — apply the rendered manifests (idempotent
  `kubectl apply -f`), reused for the Secret and the database manifests.
- `Nagare.Deploy.waitForReady` (for Knative) is the precedent; this plan adds a `waitForRollout ::
  Text -> Text -> IO ()` (namespace, name) running `kubectl rollout status statefulset/<name> -n <ns>
  --timeout=300s`, placed in `Nagare.Deploy` next to `waitForReady` (or local to `Create`).
- The base64 helpers `b64encode`/`b64decode` from `Nagare.Env.Store` (re-export them, or copy the
  two one-liners into `Nagare.Database.Secret` to keep the module self-contained).
- The `optparse-applicative` helpers already in `Main.hs`: `namespaceOpt`, `ghcEnvOpt`, `dryRunOpt`,
  `provisionGhcEnv`, `dieT`, `orDie`, `defaultConfigFile`.

**The `DbCommand` ADT (the IP4 surface, the final committed shape):**

```haskell
-- | The @db@ subcommands (EP-45, MasterPlan IP4). One constructor per
-- subcommand. EP-47 extends this with @DbBackup@/@DbRestore@ constructors and
-- the matching @command "backup"@/@command "restore"@ in the subparser — extend,
-- not fork.
data DbCommand
  = DbList   DbListOpts                  -- ^ nagarectl db list [-n NS]
  | DbCreate Engine String DbCreateOpts  -- ^ nagarectl db create ENGINE NAME [flags]
  | DbGet    DbNameOpts                  -- ^ nagarectl db get NAME [-n NS]
  | DbShell  DbNameOpts                  -- ^ nagarectl db shell NAME [-n NS]
  | DbRestart DbNameOpts Bool            -- ^ nagarectl db restart NAME [-n NS] [--dry-run]
  | DbDelete DbDeleteOpts                -- ^ nagarectl db delete NAME [-n NS] [--yes] [--dry-run]

-- | Options for @db list@: just a namespace (default @personal@).
newtype DbListOpts = DbListOpts { dbloNamespace :: Maybe String }
  deriving stock (Generic, Show)

-- | The positional NAME plus a namespace, shared by get/shell/restart.
data DbNameOpts = DbNameOpts
  { dbnName      :: !String
  , dbnNamespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @db create ENGINE NAME@: optional version/size/resources, an
-- optional typed-config path, and --dry-run. Engine and NAME are positionals on
-- the DbCreate constructor, not in this record.
data DbCreateOpts = DbCreateOpts
  { dbcNamespace :: !(Maybe String)
  , dbcVersion   :: !(Maybe String) -- ^ --version (pinned image tag; per-engine default if absent)
  , dbcSize      :: !(Maybe String) -- ^ --size (data volume; per-engine default if absent, e.g. 10Gi)
  , dbcCpu       :: !(Maybe String) -- ^ --cpu limit
  , dbcMemory    :: !(Maybe String) -- ^ --memory limit
  , dbcConfig    :: !(Maybe FilePath) -- ^ --config: load a typed Database instead of building from argv
  , dbcGhcEnv    :: !(Maybe FilePath) -- ^ --ghc-env (only used with --config)
  , dbcDryRun    :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @db delete NAME@: namespace, the --yes guard, and --dry-run.
data DbDeleteOpts = DbDeleteOpts
  { dbdName      :: !String
  , dbdNamespace :: !(Maybe String)
  , dbdYes       :: !Bool
  , dbdDryRun    :: !Bool
  }
  deriving stock (Generic, Show)
```

The `Command` sum type gains `| Db DbCommand`; `main`'s `\case` gains `Db dcmd -> runDb dcmd`; and
`runDb :: DbCommand -> IO ()` is a `\case` over the constructors calling the per-subcommand handlers.

**Handler module paths (new, under `cli/nagarectl/src/Nagare/Database/`, all registered in
`cli/nagarectl/nagarectl.cabal`):**

- `Nagare.Database.Secret` — pure IP3 helpers and the Secret renderer:
  - `dbSecretName :: Text -> Text` — `dbSecretName name == "nagare-db-" <> name`.
  - `engineToken :: Engine -> Text` — `Postgres -> "postgres"`, `Redis -> "redis"`, `ClickHouse ->
    "clickhouse"`.
  - `composeConnectionUrl :: Engine -> ConnectionParts -> Text` (pure, tested) — the per-engine URL.
  - `secretKeysFor :: Engine -> ConnectionParts -> [(Text, Text)]` (pure, tested) — the engine-specific
    key/value pairs including the composed URL.
  - `data DbSecretInputs = DbSecretInputs { dsiName :: Text, dsiNamespace :: Text, dsiEngine :: Engine,
    dsiKvs :: [(Text, Text)] }` and `renderDbSecret :: DbSecretInputs -> ByteString` — the `kind:
    Secret` JSON with the IP3 labels and base64 `data`, mirroring `renderEnvSecret`.
- `Nagare.Database.Create` — `runDbCreate :: Engine -> String -> DbCreateOpts -> IO ()`.
- `Nagare.Database.Discover` (the IP4 shared helper EP-47 reuses):
  - `dbLabelSelector :: Text` — `"nagare.dev/managed-by=nagarectl,nagare.dev/database"`.
  - `data DbRow = DbRow { drName, drEngine, drVersion, drSize, drHost :: Text, drReady :: Bool }`.
  - `extractDbRows :: ByteString -> Either Text [DbRow]` (pure, tested).
  - `listDatabases :: Text -> IO (Either Text [DbRow])` — namespace → rows; `Right []` on a failed
    query.
  - `getDatabase :: Text -> Text -> IO (Either Text DbRow)` — namespace, name → single row.
  - `formatDbTable :: [DbRow] -> Text` (pure, tested).
- `Nagare.Database.List` — `runDbList :: Text -> IO ()`.
- `Nagare.Database.Get` — `runDbGet :: Text -> Text -> IO ()`.
- `Nagare.Database.Shell` — `runDbShell :: Text -> Text -> IO ()`.
- `Nagare.Database.Restart` — `runDbRestart :: Text -> Text -> Bool -> IO ()`.
- `Nagare.Database.Delete` — `runDbDelete :: DbDeleteOpts -> IO ()`.

**The exact managed-Secret contract this plan commits to (IP3), read by EP-46 and EP-47:**

- *Name*: `nagare-db-<name>` (e.g. `nagare-db-pg-main`), in the database's namespace, type `Opaque`.
- *Labels*: `nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`, `nagare.dev/engine:
  <engine>` (`<engine>` ∈ `postgres` | `redis` | `clickhouse`).
- *Keys* (base64-encoded values), per engine:
  - Postgres: `POSTGRES_PASSWORD`, `POSTGRES_USER` (default `nagare`), `POSTGRES_DB` (default the
    sanitized database name), `DATABASE_URL` = `postgresql://<user>:<password>@<host>:5432/<db>`.
  - Redis: `REDIS_PASSWORD`, `REDIS_URL` = `redis://:<password>@<host>:6379`.
  - ClickHouse: `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_USER` (default `nagare`), `CLICKHOUSE_URL` =
    `clickhouse://<user>:<password>@<host>:9000`.
  - `<host>` in every URL is `<name>.<namespace>.svc.cluster.local`.

**Extension point for EP-47 (IP4).** EP-47
(`docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md`) adds `DbBackup`/
`DbRestore` constructors to the `DbCommand` sum type, the matching `command "backup"`/`command
"restore"` entries in the `db` subparser, and modules `Nagare.Database.Backup`/`…Restore` under the
same namespace, reusing `Nagare.Database.Discover.listDatabases` / `dbLabelSelector` to find databases
and reading the IP3 Secret above for backup/restore authentication. EP-47 must extend these, not fork
them.

**Soft dependency on EP-43**
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`): a *live*
end-to-end provision needs each engine validated on the cluster (and ClickHouse's resource limits
fixed for the `e2-standard-2` VM). All of M1's `--dry-run` behavior and all pure tests are verifiable
without the cluster; only the live transcripts require EP-43 to have run and the VM to be reachable
(see Context and Orientation).
