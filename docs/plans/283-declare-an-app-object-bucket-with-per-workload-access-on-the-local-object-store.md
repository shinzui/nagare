---
id: 283
slug: declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store
title: "Declare an app object bucket with per-workload access on the local object store"
kind: exec-plan
created_at: 2026-11-25T16:08:21Z
intention: "intention_01m89q6asjedws62wy3n95r4e7"
master_plan: "docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-25T16:08:21Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-25T16:37:48Z
      mode: "implement"
      note: "M1 review effects and platform mounts implemented"
---

# Declare an app object bucket with per-workload access on the local object store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements part of IR-55,
[`docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md`](../improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md),
requested by `mori://shinzui/hanmoto` (specification `mori://shinzui/hanmoto/docs/initial-spec`,
sections 5, 6 and 9). It is a child of [MasterPlan 39](../masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md), which holds the order of the four
child plans and the artifacts they share.


## Purpose / Big Picture

An application cannot declare object storage today; every bucket is platform-owned. After this
plan a `nagare/Config.hs` declares a bucket with expiry rules and a list of grants, and each
granted workload gets its own credential with read-write or read-only access. This plan delivers
it on a local context, on the packaged MinIO store. The GCS backend is the sibling plan
[284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md](284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md).

It also delivers two shared pieces the sibling plans use: a review that lists what a retirement
loses, and platform-mounted files in workloads.

```bash
just local-bucket-smoke CTX
nagarectl --context CTX bucket status publications
```

```text
api: put ok, get ok
gateway: get ok, put AccessDenied
PASS
publications  s3  nagare-app-publications  content-app=read-write content-gateway=read-only
```


## Progress

- [x] M1. Shared groundwork. A review can carry effect lines and prints them; a workload can carry
  platform mounts and renders them for a Knative Service, a worker and a task; a transcript shows
  Knative admitting a Service with those mounts. Evidence: `nagare-dsl` and `nagarectl` tests and
  the transcript here.
  - 2026-11-25: code done, transcript open. `reviewEffects`, `withReviewEffects` and
    `renderReviewEffects` are in `Plan/Types.hs`; `SavedReview.effects` is absent when empty.
    `Nagare.Dsl.Mounts` renders and applies mounts. Tests: nagare-dsl `platform mounts` (9), nagarectl
    `action publication totality` (two effect cases) and the `saved-review-retirement.json` sample;
    `just gate-commit` green. The Knative admission transcript is not recorded: the only local
    cluster, `nagare-local`, has no running Knative webhook (its pods are evicted or pending), so a
    server-side dry run could not reach admission. It needs a working disposable local cluster.
  - 2026-11-25: done. Knative Serving 1.22.0 admits the mounts with no feature flag beyond the two
    Nagare already sets, and the container reads all three files. Run on a throwaway k3d cluster
    (k3s v1.34.6, the vendored `cluster/bootstrap/vendor/serving-{crds,core}-v1.22.0.yaml` and
    `knative-serving/config-features.yaml`), then deleted. The Service had a named ServiceAccount,
    `automountServiceAccountToken: false`, a projected volume with a service-account token
    (audience `nagare-workload-identity`) and a ConfigMap, and a projected Secret volume:

    ```text
    == knative
    1.22.0
    == feature flags Nagare sets
      kubernetes.podspec-persistent-volume-claim = enabled
      kubernetes.podspec-persistent-volume-write = enabled
    == server-side dry run
    service.serving.knative.dev/mount-probe created (server dry run)
    == apply
    service.serving.knative.dev/mount-probe created
    == pod spec as admitted
      automountServiceAccountToken: False  serviceAccountName: mount-probe
      volume nagare-identity ['serviceAccountToken', 'configMap']
      volume nagare-keys ['secret']
    == files the container sees
    /var/run/nagare/identity:
    credential-configuration.json -> ..data/credential-configuration.json
    token -> ..data/token
    /var/run/nagare/keys:
    current.jwk -> ..data/current.jwk
    == token audience
       "aud":["nagare-workload-identity"]
    == no default token
    ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
    ```
- [x] M2. A bucket and its bindings exist in the typed model and round-trip through the config
  program and the rendered document; existing goldens and config digests are unchanged. Evidence:
  `nagare-dsl` tests.
  - 2026-11-25: done. `Nagare.Dsl.ObjectBucket`, `emitObjectBuckets`, `loadObjectBuckets` and
    `buckets` on `Deployment`, `Worker` and `Task` (33 literals migrated). nagare-dsl: 568 tests
    pass with every earlier golden unchanged, including the `object bucket` group (11), which
    loads the example. The example is two files, as app databases are: `nagare/Config.hs` (the
    application, named `content`) and `nagare/Buckets.hs` (the bucket document).
- [x] M3. `nagarectl bucket plan` produces a reviewed standalone scope whose members create the
  MinIO bucket, its expiry rules and one store user per grant; no review carries a credential.
  Evidence: interpreter tests.
  - 2026-11-25: the scope compiler and the credential copy are done; the CLI and the interpreter
    tests through the planner and executor are not. `compileStandaloneBucket`
    (`cli/nagare-core/src/Nagare/Inventory/ObjectBucket.hs`): nagarectl `bucket scope` (10 tests).
    The adapter's user-credential copy: `Lifecycle worker credential` (3 new cases). The Jobs'
    `mc` commands were run against the packaged MinIO and client images in two throwaway
    containers: bucket creation and rule import repeat safely, a read-only user's put and list are
    refused, and removing a user leaves the objects.
  - 2026-11-25: done. `nagarectl bucket plan|status|retire` is wired
    (`cli/nagarectl/app/Nagare/Cli/Commands/Bucket.hs`) and registered in the command audit.
    nagarectl `bucket scope in the model world` (6 tests) drives the compiled scope through the
    real planner, executor and Kubernetes adapter: it converges with each workload holding its own
    user's key and no key in any reviewed byte; a second plan only verifies and keeps every key and
    Secret UID; a failed grant Job stops the review; a lost acknowledgement at each of the seven
    writes resumes to one set of objects; a dropped grant is retired in the review that adds its
    revoke Job; an added grant creates three members. The command's own wiring (image selection,
    the planning registry observing retired members) is first run by the M4 smoke.
- [ ] M4. A bound workload reads and writes through its own credential and a read-only workload's
  write is refused, through the example `Config.hs`. Evidence: `just local-bucket-smoke CTX`
  transcript (IR-55 AC-1, local half).
  - 2026-11-25: bindings are done for a standalone Deployment, a standalone Worker and a task
    (`acceptedBucketBindings`, `ObjectBucketBinding` in
    `cli/nagarectl/src/Nagare/Inventory/Application/`): nagarectl `bucket binding` (4 tests) covers
    the five variables, the ordering after the grant Job and the credential, the
    `bucket-grant-missing` refusals and an unbound worker's manifest.
  - 2026-11-25: an Application's service and workers bind too (operator decision):
    `scopeBucketBindings` in `ApplicationScopeInput`, resolved by `app deploy` for each workload's
    own name. `bucket binding` now has 6 tests; the Application case checks each workload's
    variables, its dependency on its own credential, and that `boundBy` then reports the bucket
    bound. Open: `scripts/local-bucket-smoke.sh` and its transcript. They need a full local
    context, and the Docker VM that hosts `nagare-local` has kubelet disk pressure (98 GB disk,
    87% used, about 83 GB of it other projects' images), so a recreated cluster there evicts its
    pods again. The operator has to free or grow that disk, or name another daemon.
- [ ] M5. `nagarectl bucket retire` is a review that names each workload losing access and states
  that the objects are kept; it is refused while a workload binds the bucket. User documentation
  exists. Evidence: reviewed-change tests (IR-55 AC-5, bucket).


## Surprises & Discoveries

- A Job in `nagare-system` cannot read a Secret in the workload's namespace, and the workload
  cannot read one in `nagare-system`, so one template Secret cannot serve both the grant Job and
  the workload. The store's client image has no TLS-verifying HTTP client to read the Kubernetes
  API with either (BusyBox `wget` only). The existing answer is the adapter's copy template
  (`nagare.dev/minio-credential-copy`, which fills the `personal` copy of the store's root
  credential at creation). Changed the design: see the Decision Log.

- A Kubernetes Job cannot be updated, and the planner replaces none (only superseded migration
  Jobs leave a scope without a decision, `supersededMigrationJobs`). A grant Job that kept its
  name would never apply a changed policy. Changed the design: see the Decision Log.

- An Application's own service and workers take no binding from another scope today. The
  application compile refused every such binding: app databases on them (`app-database-not-bindable-from-application`,
  EP-202: "deploy the workload as a Deployment or Worker to bind an app database"), and only a
  standalone Deployment, a standalone Worker and a task resolve accepted bindings
  (`reviewedStandaloneDatabases`). This plan's M4 and its example assumed an Application whose
  service and worker bind the bucket. Bindings were built on the standalone paths, which both
  answers need; the Application path is a scope decision for the operator.

- `mc ilm rule rm --all` fails on a bucket with no rules ("The lifecycle configuration does not
  exist"), so the bucket Job lists the rules first. Evidence: the container run recorded under M3.

- `DataPolicy`'s `Durable` needs a `RecoveryIntent` (a backup name and key references), which a
  bucket does not have, and no member is the bucket itself: the member is the Job that made it.
  The Job is `Protect` and `Stateless`. Nothing in the scope can delete the bucket or an object.


## Decision Log

- Decision: A bucket is a standalone document with its own scope, like an app database, not a
  field of `Application`.
  Rationale: Its objects must outlive an application retirement, and two workloads hold different
  rights on it. A standalone scope gives it a `plan` and a `retire` review of its own.
  Date: 2026-11-25

- Decision: The bucket declaration lists its grants (namespace, workload, access, signing). A
  workload binds the bucket by name and the compile refuses a binding with no accepted grant.
  Rationale: The grant is where trust is given, so it belongs to the bucket's review. Brokers and
  app databases are bound the same way.
  Date: 2026-11-25

- Decision: Retiring a bucket removes access and keeps the bucket and every object. Nothing in
  this plan deletes a bucket.
  Rationale: ADR 22: durable data defaults to retention.
  Date: 2026-11-25

- Decision: The workload learns its backend from `NAGARE_BUCKET_<NAME>_BACKEND` (`s3` here, `gcs`
  on a cloud context) and must hold an adapter for each.
  Rationale: IR-55 asks for the same declaration on both, not the same wire protocol. GCS's
  S3-compatible interface needs HMAC keys, which are exported long-lived credentials.
  Date: 2026-11-25


- Decision: `applyPlatformMounts` lives in `cli/nagare-dsl/src/Nagare/Dsl/Mounts.hs` with the
  renderer, not in `Application/Bindings.hs`. A service-account token source writes the file
  `token` under the mount path.
  Rationale: Each workload kind has its own YAML key order, and the encoders are in `nagare-dsl`.
  The applier is pure, so its goldens sit beside the renderers' goldens.
  Date: 2026-11-25

- Decision: A planner sets a review's effects with `withReviewEffects` on the prepared bundle,
  before it is published. `ChangeProposal` and `LifecycleDecisions` are unchanged.
  Rationale: The effects are sentences a command writes, not something the change planner derives.
  Setting them before publication puts them under the review digest.
  Date: 2026-11-25

- Decision: Each grant has two Secrets. The store user's credential is a template in
  `nagare-system` (the existing `nagare.dev/minio-user-template`), which the grant Job reads. The
  workload's Secret `nagare-bucket-<bucket>-<workload>` in its own namespace is a copy template
  (`nagare.dev/minio-user-copy`), which the adapter fills at creation from the user's Secret after
  checking the context and the member it names. The store user is `nagare-bucket-<12 hex>`, a
  digest of bucket, namespace and workload, because the three names together exceed a Job name.
  Rationale: See Surprises & Discoveries. It reuses the copy mechanism the root credential already
  has, adds no image and no Kubernetes API access to a Job, and still puts no key in a review.
  Date: 2026-11-25

- Decision: Every Job is named after a digest of what it runs. A changed rule or policy is a new
  Job, and `bucket plan` retires the members that leave the scope in the same review with
  `decideMemberRetirement`. A dropped grant's revoke Job stays in the scope until the workload is
  granted again; that grant is a new Job. Granting again also needs the retired Secrets collected
  first, as any redeclared retained member does.
  Rationale: See Surprises & Discoveries. The planner is unchanged.
  Date: 2026-11-25

- Decision: The bucket Job sets the expiry rules with `mc ilm rule import`, not one
  `mc ilm rule add` per rule.
  Rationale: An import replaces the whole configuration, so a changed or removed rule takes effect
  and a repeat changes nothing.
  Date: 2026-11-25

- Decision: `bucket retire NAME` replaces the scope with the same bucket and no grant. It does
  not retire the scope.
  Rationale: The store users must be removed, which only a revoke Job in the scope does, and the
  bucket Job must stay so that nothing reads the scope as collectable. The review lists each
  workload that loses access and that the objects are kept. It is refused while a member of
  another scope is ordered after one of the bucket's members, which is how a bound workload shows
  in accepted history.
  Date: 2026-11-25

- Decision (operator, 2026-11-25): an Application's own service and workers bind a bucket.
  Rationale: IR-55 and Hanmoto's shape are one Application with the API as its service and the
  gateway as a worker. The application compile takes bucket bindings; EP-202's rule for app
  databases is unchanged.
  Date: 2026-11-25

- Decision: A bucket binding is a third kind of workload binding beside a server and an app
  database (`ObjectBucketBinding`, keyed `bucket-<name>`), resolved by the command from accepted
  history and turned into variables, a Secret dependency and ordering edges by
  `standaloneDatabaseEnvironment`.
  Rationale: That path already carries a credential Secret of another scope into a workload with
  the exact-dependency checks; a second path would repeat them.
  Date: 2026-11-25

- Decision: The accepted declaration is kept in the scope override `bucket.declaration`.
  Rationale: Bindings, `bucket status` and retirement read the accepted grants without the config
  file, as a delegation's record is read.
  Date: 2026-11-25

## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Nagare runs applications on one k3s node: a GCE VM running NixOS on a cloud context, or a k3d cluster
on a local context (`mode=local`). An application is a typed Haskell program, `nagare/Config.hs`,
that prints JSON documents. `nagarectl` loads them, compiles them into reviewed inventory scopes,
and applies a saved review with `nagarectl inventory apply DIR --yes`.

Terms used below:

- A scope is a set of resources with one owner and its own revision history
  (`cli/nagare-dsl/src/Nagare/Resource/Types.hs`: `ScopeKind = Platform | Application | Standalone
  | Publication`). A standalone scope holds one data service, such as an app database
  (`cli/nagare-core/src/Nagare/Inventory/AppDatabase.hs`, `compileStandaloneAppDatabase`).
- A managed resource is `ManagedResource` in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`: an identity, an owner scope, an executor
  (`KubernetesExecutor`, `PulumiExecutor` and others), a provider address, a lifecycle policy
  (`Retain | DeleteWhenUnreferenced | Protect`) and a data policy (`Stateless | Durable`).
- A review is the saved plan, `review.json` (`ReviewDocument` in
  `cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs`). Its `--contract 1` projection is
  `SavedReview` in `cli/nagare-contract/src/Nagare/Contract/V1.hs`.
- Retirement removes a resource from the desired state under an explicit decision
  (`ApproveRetirement`). Removing a member without one refuses with `retirement-required`
  (`cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`). Retirement deletes nothing at the
  provider; deletion is a separate `inventory collect` review that refuses durable data.
- A credential template is a reviewed Secret with no data. The adapter fills it with generated
  values at creation and afterwards compares only its key set
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`). A `Delegation`
  (`cli/nagare-dsl/src/Nagare/Resource/Policy.hs`) names another writer allowed to change fields.
- The interpreter tests run the real planner, executor and adapters against an in-memory world
  (`cli/nagarectl/test/Nagare/Test/World/`). New `*Spec` modules are registered in
  `cli/nagarectl/test/Nagare/Test/Suite.hs`.

The application model (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) has one web workload,
`service :: Maybe Deployment` (a Knative Service, `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), plus
`workers :: [Worker]` (plain Deployments, `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) and
`tasks :: [Task]` (CronJobs, `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`). Workloads are named by their
`ServiceName`. In Hanmoto's shape the API is the `service` and the gateway is a worker.

Object storage today. On a local context the store is MinIO (`cluster/local/minio/minio.yaml`,
reviewed by `cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs`), selected by
`NAGARE_LOCAL_OBJECT_STORE` and parsed into `StoreBackend = GcsBackend | MinioBackend`
(`cli/nagare-core/src/Nagare/Cluster/GcsJob.hs`; resolved by
`cli/nagarectl/app/Nagare/Cli/Runtime/ObjectStore.hs`). Its one bucket, `nagare-backups`, is made
by a reviewed Job running `mc mb`. Two precedents give one identity its own store user:
`cli/nagarectl/src/Nagare/Inventory/DeployerStoreAccess.hs` (a policy document and a grant Job
running `mc admin`) and `minioUserCredentialKind` in `CredentialTemplate.hs` (a template Secret
whose access key is the user name and whose secret key is generated). Nothing in `nagare-dsl`
refers to a bucket.

Reviews today. `ReviewDocument` lists operations, retentions, collections, rebinds and rebuilds.
`printPlannedReview` in `cli/nagarectl/src/Nagare/Inventory/Command.hs` prints the digest and the
rebind and rebuild lines. No field says what a retirement loses. `docs/api/README.md` states that
a new optional field keeps contract version 1.

Mounts today. The only volume a workload can declare is a PVC (`Volume` in `Types.hs`). Secrets
reach workloads only as environment variables (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`). A
workload with `serviceAccount = Nothing` renders `automountServiceAccountToken: false`
(`serviceAccountPairs`). Knative feature flags are in
`cluster/bootstrap/knative-serving/config-features.yaml`.

Relevant ADRs:

- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): one owner
  per resource; generated credentials are data-free templates; durable data is retained.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): each
  adapter path is driven by an interpreter test before the local smoke.
- [ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md): a
  workload receives only the Secrets it is entitled to; only a granted workload references its
  bucket credential.

Module line caps (`scripts/check-haskell-architecture.py`,
`scripts/haskell-size-allowances.json`) will force new modules; create them up front. A new CLI
command is registered in `scripts/audit-managed-commands.py` and
`docs/architecture/managed-resource-coverage.md`. Changes to the planner, executor or adapters need
`just mutation-check REV BASE` before landing.


## Plan of Work

### M1. Shared groundwork

Review effects. Add `reviewEffects :: [ReviewEffect]` (a resource ID and one sentence) to
`ReviewDocument`, with its JSON key, and thread it from planning. Print it in `printPlannedReview`
under the heading `This review removes:`. Add the optional `effects :: [Text]` to `SavedReview`
and its builder in `cli/nagarectl/src/Nagare/Contract/Project.hs`, and document it in
`docs/api/README.md`. A review with no effects prints and encodes exactly as before. This plan
fills it only in M5; test it now with a hand-built review.

Platform mounts. Add `cli/nagare-dsl/src/Nagare/Dsl/Mounts.hs` with `PlatformMount` (see
Interfaces and Dependencies) and a renderer that yields the `volumes` and `volumeMounts` entries.
It is not part of the user's typed surface or the JSON wire format: the inventory compilers add
mounts to a workload's manifest after rendering, as they add binding variables today
(`cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`). Add a helper there that applies a
list of mounts to a rendered Knative Service, Deployment or CronJob. Tests: one golden per kind
with all three sources, and that no mount means byte-identical output.

Admission check. On a disposable local context, apply by hand a Knative Service with
`automountServiceAccountToken: false`, a named ServiceAccount, a projected volume with a
`serviceAccountToken` source and a custom audience, a ConfigMap volume and a Secret volume. Pass:
admitted, and the three files are readable in the container. If a `config-features` flag is
required, add it to `cluster/bootstrap/knative-serving/config-features.yaml` in this milestone. If
Knative refuses, record it in Surprises & Discoveries and in MasterPlan 39: the sibling plans
would then support only workers and tasks, which needs a scope decision.

### M2. Typed declaration

Add `cli/nagare-dsl/src/Nagare/Dsl/ObjectBucket.hs`, its loader under `Load/`, and
`emitObjectBuckets` in `Config.hs` beside `emitAppDatabases`. Add
`buckets :: [BucketBinding]` to `Deployment`, `Worker` and `Task`. Adding a strict field means migrating every literal of that record in the libraries,
tests, `cluster/examples/` and `fixtures/inventory-release/`. The new JSON key is omitted when
empty so no accepted config digest moves, as `managedEnv` did; a regression fixture proves a
pre-change Application encodes to the same bytes. The other child plans of MasterPlan 39 add
fields to the same records, so rebase on the landed tree before migrating.

Smart constructors refuse: a bucket name that is not a DNS label of at most 30 characters, an
expiry prefix that is empty or does not end in `/`, a non-positive day count, and two grants for
the same namespace and workload.

Create the example under `cluster/examples/content-app/nagare/`: `Buckets.hs` declares the bucket
`publications`, which expires `staging/` after one day and grants a web service `content-app`
read-write with signing and a worker `content-gateway` read-only; `Config.hs` declares the
application whose two workloads bind it.

### M3. The bucket scope on MinIO

Add `cli/nagare-dsl/src/Nagare/Resource/ObjectBucket.hs` (resource identities; scope
`bucket-<logicalKey or name>`) and `cli/nagare-core/src/Nagare/Inventory/ObjectBucket.hs` with
`compileStandaloneBucket`, taking the `StoreBackend`. A `GcsBackend` refuses with
`bucket-backend-unsupported` until the sibling plan lands. For a `MinioBackend` the members are
Kubernetes objects in `nagare-system` unless noted:

- a Job that runs `mc mb --ignore-existing root/nagare-app-<name>` and imports the expiry rules
  with `mc ilm rule import`. It is `Protect`;
- per grant, the store user's credential template `nagare-bucket-<digest>` in `nagare-system`
  (the `minioUserCredentialKind` template), the workload's copy template
  `nagare-bucket-<bucket>-<workload>` in the workload's namespace (`minioUserCopyKind`), and a
  grant Job ordered after the bucket Job and the user's Secret, with the policy in its script.
  Read-write allows `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the bucket's objects and
  `s3:ListBucket`; read-only allows `s3:GetObject` only. Dropping a grant adds a revoke Job.

Each Job's name ends in a digest of its script (see the Decision Log).

CLI: `nagarectl bucket plan --file CONFIG --save-plan DIR` and `nagarectl bucket status [NAME]`
in `cli/nagarectl/app/Nagare/Cli/{Commands,Options,Parser}/Bucket.hs`, modelled on the
`AppDatabase` trio.

Interpreter tests in `cli/nagarectl/test/ObjectBucketSpec.hs` and `ObjectBucketWorldSpec.hs`:
create; lost acknowledgement of the Secret create; a grant Job that fails; a second identical plan
that changes nothing and does not regenerate a credential; adding and dropping a grant; and that
no byte of the review contains a secret key.

### M4. Bindings and the local smoke

In `cli/nagarectl/src/Nagare/Inventory/Application/` (`Bindings.hs`, `Environment.hs`, and the
standalone service, worker and task paths), a workload with `BucketBinding publications` gets `NAGARE_BUCKET_PUBLICATIONS_BACKEND=s3`,
`_NAME`, `_ENDPOINT`, and `_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY` as `secretKeyRef` to its own
Secret, and a dependency on its grant Job. The compile refuses `bucket-grant-missing` when the
accepted head has no grant for that namespace and workload, and the same for a standalone
workload. Tests: the variables, the refusal, and that an unbound workload's manifest names no
bucket Secret.

Add `scripts/local-bucket-smoke.sh` and the recipe `just local-bucket-smoke CTX`, modelled on
`scripts/local-secret-scope-smoke.sh`. It plans and applies the bucket, deploys the example with a
small image that has an S3 client, and from each workload's pod puts and gets one object, printing
the lines shown in Purpose. Complete
[`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md) first.

### M5. Retirement and documentation

`nagarectl bucket retire NAME --save-plan DIR` retires the scope's members under
`ApproveRetirement` and fills `reviewEffects` with one line per grant ("workload W in N loses
read-write access to bucket B") and one line stating that the bucket and its objects are kept. It
refuses `bucket-still-bound` while an accepted workload binds the bucket. The store users are
removed by the revoke Jobs; the bucket and its objects are not touched. Removing the document
without `retire` keeps the `retirement-required` refusal. Tests assert the exact lines, the
`SavedReview.effects` projection and both refusals.

Write `docs/user/object-storage.md` and a capability page under `docs/capabilities/`, and add the
types to `docs/user/config-reference.md` and the store to `docs/user/local-development.md`.


## Concrete Steps

All commands run from the repository root.

```bash
just gate-commit                 # per Haskell commit
just mutation-check HEAD BASE    # before landing planner, executor or adapter changes
just gate-fast && just land HEAD
```

Focused runs:

```bash
cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /bucket/' --test-show-details=direct
```

Local confirmation (M4), on a disposable `mode=local` context `CTX` built per
[`docs/user/local-development.md`](../user/local-development.md):

```bash
just local-bucket-smoke CTX
nagarectl --context CTX bucket status publications
```

Expected output is in Purpose. Record the transcript under Progress.


## Validation and Acceptance

IR-55 AC-1 (local half): M2's round trips, M3's review tests, and M4's smoke through the example
`Config.hs`. IR-55 AC-5 (bucket): M5's effect-line tests. The shared groundwork is accepted by M1's
tests and transcript, which the sibling plans rely on.

The plan is accepted when `just gate-fast` is green on the landed commit, the post-land full gate
is green, and the M1 and M4 transcripts are under Progress.


## Idempotence and Recovery

Every change is a saved review; reapply one from its own directory and prepare a new one in a new
directory. The bucket Job uses `--ignore-existing` and the rule and grant commands are safe to
repeat. A credential is generated once and never regenerated by a re-plan. A failed grant Job
stops the review with the bucket in place; fix and retry the same review. The smoke uses a
disposable context; delete it to clean up.


## Interfaces and Dependencies

In `cli/nagare-dsl/src/Nagare/Dsl/ObjectBucket.hs`:

```haskell
data BucketAccess = ReadOnly | ReadWrite
  deriving stock (Generic, Eq, Show)

data BucketGrant = BucketGrant
  { namespace :: !Namespace
  , workload :: !ServiceName
  , access :: !BucketAccess
  , signUrls :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Delete objects under a prefix after a number of days.
data ExpireRule = ExpireRule
  { prefix :: !ObjectPrefix
  , afterDays :: !PositiveDays
  }
  deriving stock (Generic, Eq, Show)

data ObjectBucket = ObjectBucket
  { name :: !BucketName
  , logicalKey :: !(Maybe LogicalKey)
  , expire :: ![ExpireRule]
  , grants :: ![BucketGrant]
  }
  deriving stock (Generic, Eq, Show)

newtype BucketBinding = BucketBinding {name :: BucketName}
  deriving stock (Generic, Eq, Show)
```

`signUrls` has no effect on the S3 backend, where any credential can presign.

In `cli/nagare-dsl/src/Nagare/Dsl/Mounts.hs`:

```haskell
data MountSource
  = ConfigMapSource !Text
  | SecretSource !Text
  | ServiceAccountTokenSource !Text !Int   -- audience, expiry in seconds
  deriving stock (Generic, Eq, Show)

data PlatformMount = PlatformMount
  { volume :: !Text
  , mountPath :: !Text
  , sources :: !(NonEmpty MountSource)   -- rendered as one read-only projected volume
  }
  deriving stock (Generic, Eq, Show)
```

In `cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs`:

```haskell
data ReviewEffect = ReviewEffect
  { resource :: !ResourceId
  , loses :: !Text
  }
  deriving stock (Generic, Eq, Show)
```

A bound workload sees `NAGARE_BUCKET_<NAME>_BACKEND`, `_NAME`, `_ENDPOINT`, `_ACCESS_KEY_ID` and
`_SECRET_ACCESS_KEY`, where `<NAME>` is the bucket name upper-cased with `-` as `_`.

Consumers: [284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md](284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md) adds the `gcs` backend and needs this whole plan.
[285-serve-a-wildcard-content-domain-from-one-worker-with-the-host-header-intact.md](285-serve-a-wildcard-content-domain-from-one-worker-with-the-host-header-intact.md) and [286-generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files.md](286-generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files.md) need only M1.
