---
id: 284
slug: give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket
title: "Give each granted workload a keyless cloud identity on a GCS bucket"
kind: exec-plan
created_at: 2026-11-25T16:08:21Z
intention: "intention_01m89q6asjedws62wy3n95r4e7"
master_plan: "docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-25T16:08:21Z
---

# Give each granted workload a keyless cloud identity on a GCS bucket

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements part of IR-55,
[`docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md`](../improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md),
requested by `mori://shinzui/hanmoto` (specification `mori://shinzui/hanmoto/docs/initial-spec`,
sections 5, 6 and 9). It is a child of [MasterPlan 39](../masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md), which holds the order of the four
child plans and the artifacts they share.

Prerequisite: [283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md](283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md) is complete. It provides the `ObjectBucket` declaration, the
scope `bucket-<key>`, `nagarectl bucket plan|status|retire`, workload `buckets` bindings, the
`NAGARE_BUCKET_<NAME>_*` variables, `PlatformMount` and `reviewEffects`. Its compile refuses a
`GcsBackend` with `bucket-backend-unsupported`; this plan replaces that refusal.


## Purpose / Big Picture

On a cloud context the bucket declaration becomes a private GCS bucket, and each granted workload
becomes its own Google service account with exactly the declared access. A workload that may sign
URLs can call `signBlob` as itself, so it can hand out V4 signed upload URLs. No service-account
key is created, stored or mounted anywhere: the pod proves who it is with a short-lived Kubernetes
token.

```bash
curl -sS https://content-app.BASE/put-and-sign
curl -sS https://content-app.BASE/gateway-try-put
gcloud iam service-accounts keys list --iam-account "$API_SA" --managed-by user --format 'value(name)'
```

```text
put ok; signed url https://storage.googleapis.com/PROJECT-CTX-publications/staging/probe?X-Goog-Algorithm=GOOG4-RSA-SHA256...
gateway: get ok, put 403
```

The third command prints nothing.


## Progress

- [x] M1. From the accepted head `nagarectl` derives `nagare:appBuckets` and
  `nagare:workloadIdentity`, and the cloud catalog expands one set of entries per bucket and grant.
  Evidence: `BucketCloudAccessSpec` (5 tests) pass; commits 33abcd7c, c712818b.
- [x] M2. The Pulumi program creates the identity pool, the bucket and the per-grant accounts and
  bindings, with no key, no public member and no project-level role. Evidence: `npm test` in
  `infra/pulumi` passes; commit b95918a0.
- [x] M3. On a `GcsBackend` the bucket scope holds one ServiceAccount and one credential
  configuration per grant, a bound workload mounts them, and an application review is refused until
  the cloud review has converged. Evidence: `BucketCloudScopeSpec` (6 tests: manifests, no key,
  refusal before and acceptance after federation, the bound worker's account, mount and variables,
  the own-account and two-bucket refusals, retirement) pass, with `bucket binding` and
  `key set binding` unchanged.
- [ ] M4. On a disposable cloud context the API workload writes an object and returns a signed URL
  that accepts an upload, the gateway workload's write is refused, neither account has a
  user-managed key, and the bucket shows uniform access, enforced public access prevention and the
  prefix rule. Evidence: transcript here (IR-55 AC-1 cloud half, AC-2).
- [ ] M5. Retiring a bucket on a cloud context disables its accounts and keeps the bucket; the
  review says so. User documentation and two ADR changes exist. Evidence: tests (IR-55 AC-5).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A workload's cloud identity is a Google service account reached through workload
  identity federation. The cluster's service-account signing keys (its JWKS) are uploaded to a
  workload identity pool provider; the pod exchanges a projected Kubernetes token for short-lived
  credentials and impersonates its account.
  Rationale: It is the only option with no stored long-lived secret. The existing alternatives are
  an exported JSON key (lifecycle worker, admin API) and the VM's metadata-server identity, which
  every pod shares. Uploading the JWKS means the issuer needs no public URL and k3s needs no new
  flag, so there is no host change. M4 confirms it; nothing else in the repository can.
  Date: 2026-11-25

- Decision: The Pulumi program creates the cloud resources from derived config computed from the
  accepted head, as it does for delegated deployers.
  Rationale: The inventory creates Google resources only through the `platform:cloud` scope and
  its catalog guard.
  Date: 2026-11-25

- Decision: Signing is granted as `roles/iam.serviceAccountTokenCreator` on the account, to the
  account itself.
  Rationale: The role carries `iam.serviceAccounts.signBlob`. A custom role with only that
  permission is not visible to IAM in the update that creates it and holds its ID for about 37
  days after deletion (`infra/pulumi/src/components/NagareDelegatedDeployer.ts`). The extra
  permissions let the account mint tokens only for itself.
  Date: 2026-11-25

- Decision: Nagare authors a Kubernetes ServiceAccount, with no RBAC, for each granted workload,
  and refuses a workload that both names its own `serviceAccount` and binds a bucket.
  Rationale: The federation subject must be an account Nagare controls. The pod still mounts no
  API token: only a projected token whose audience is the identity pool. This amends ADR 36.
  Date: 2026-11-25

- Decision: A retired bucket keeps its bucket and disables its accounts; a dropped grant removes
  that grant's account and bindings.
  Rationale: Durable data is retained (ADR 22) and
  `cli/nagarectl/src/Nagare/Inventory/CloudCollection.hs` does not collect buckets. A disabled
  account refuses every credential at once.
  Date: 2026-11-25

- Decision: On a cloud context a workload binds at most one bucket, and a task none.
  Rationale: A workload runs as one Kubernetes account, `nagare-wl-WORKLOAD`, and a second bucket's
  scope would declare the same account; its credential configuration impersonates one Google account.
  One account holding several grants is a later change. This replaces "a workload with two buckets has
  one account holding both grants" in M3.
  Date: 2026-11-26

- Decision: A bucket with no grant left records the grants it last had (`bucket.retired-grants`), and
  the cloud review keeps their accounts, disabled.
  Rationale: Retiring clears the declaration's grants, so the derived config would otherwise drop the
  accounts and Pulumi would delete them instead of disabling them. Found while writing M5's tests.
  Date: 2026-11-26

- Decision: Application pods keep their route to the VM's metadata server.
  Rationale: The node account has no role on an application bucket, so the grants hold. Closing
  that route is a separate change that affects every application.
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

Cloud resources today. `infra/pulumi` is a TypeScript Pulumi program. It may register only
resources named in `infra/pulumi/resource-catalog.json` (`installResourceDeclarationGuard` in
`infra/pulumi/src/resourceDeclarations.ts`), which `cli/nagarectl/src/Nagare/Inventory/Cloud.hs`
compiles into the `platform:cloud` scope and `cli/nagarectl/src/Nagare/Inventory/Adapters/Pulumi.hs`
applies as an exact saved plan. `infra/pulumi/src/components/NagarePerimeter.ts` shows the house
bucket settings (`uniformBucketLevelAccess`, `publicAccessPrevention: "enforced"`, `protect: true`).

The precedent to copy is the delegated deployer.
`cli/nagarectl/src/Nagare/Inventory/DeployerCloudAccess.hs` computes the derived config key
`nagare:delegatedDeployers` from the accepted head and derives each account ID in one place.
`withDelegatedDeployers` in `Cloud.hs` expands a catalog template per deployer.
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Cloud.hs` (`buildCloudStageCandidate`,
`foundationDeployerKeys`) wires both into the cloud review.
`infra/pulumi/src/components/NagareDelegatedDeployer.ts` creates the account and its bucket grants,
and its header comment records the IAM lessons this plan reuses.

Identity today. Every pod can reach the VM's metadata server
(`nixos/hosts/nagare-01/networking.nix`) and so shares the `nagare-node` account. There is no
workload identity federation, no `signBlob` grant and no projected token in `infra/`, `cli/`,
`nixos/` or `cluster/`. The k3s flags are in `nixos/hosts/nagare-01/k3s.nix` and set no issuer, so
the issuer is the k3s default; the API server serves it and its keys at
`/.well-known/openid-configuration` and `/openid/v1/jwks`.

Workload identity federation, in the terms used here: a workload identity pool is a Google
resource that trusts an external token issuer. Its provider holds the issuer's name and public
keys. A pod sends its Kubernetes token to Google's token service, which checks the signature
against those keys and returns a token for the principal
`principal://iam.googleapis.com/projects/NUMBER/locations/global/workloadIdentityPools/POOL/subject/SUBJECT`.
That principal holds `roles/iam.workloadIdentityUser` on one service account and impersonates it.
Google's client libraries do all of this from a credential configuration file of type
`external_account` named by `GOOGLE_APPLICATION_CREDENTIALS`.

Relevant ADRs:

- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): every
  cloud mutation asserts the active context's project. All resources here are created by the
  guarded Pulumi path; the M4 `gcloud` reads name the context's project explicitly.
- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  no key in Pulumi state. None is created.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): durable
  data is retained; every resource is declared before mutation.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): M3's
  interpreter tests precede M4.
- [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md):
  a rebuilt cluster has new token-signing keys, so the rebuild procedure gains one step (M5).
- [ADR 36](../adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md):
  amended by this plan, as the Decision Log says.

Module line caps (`scripts/check-haskell-architecture.py`,
`scripts/haskell-size-allowances.json`) will force new modules; create them up front. A new CLI
command is registered in `scripts/audit-managed-commands.py` and
`docs/architecture/managed-resource-coverage.md`. Changes to the planner, executor or adapters need
`just mutation-check REV BASE` before landing.


## Plan of Work

### M1. Derived config and catalog

Add `cli/nagarectl/src/Nagare/Inventory/BucketCloudAccess.hs`, modelled on
`DeployerCloudAccess.hs`. From the accepted bucket scopes it computes `nagare:appBuckets`: per
bucket its Google name (`<project>-<context>-<name>`, shortened with a digest past 63 characters),
its expiry rules, a `retired` flag, and per grant the Kubernetes subject
(`system:serviceaccount:<namespace>:nagare-wl-<workload>`), the account ID (`nagare-wl-` plus a
digest of namespace and workload, at most 30 characters), the access and the signing flag. Names
are derived only here. It computes `nagare:workloadIdentity` from the API server: the issuer
string and the JWKS document. Both are public values.

Add catalog templates for the pool, the provider, and per bucket and per grant entries to
`infra/pulumi/resource-catalog.json`, an expansion function beside `withDelegatedDeployers`, and
the wiring in `buildCloudStageCandidate`. Tests: name derivation including the long-name case, the
expansion, and that a context with no bucket yields no new entries.

### M2. Pulumi components

Add `infra/pulumi/src/components/NagareWorkloadIdentity.ts`: one `gcp.iam.WorkloadIdentityPool`
and one OIDC `WorkloadIdentityPoolProvider` with the uploaded JWKS, the issuer, one fixed allowed
audience and `google.subject` mapped from `assertion.sub`. It exists only when a bucket does.

Add `NagareAppBucket.ts`. The bucket is in the context's region with
`uniformBucketLevelAccess: true`, `publicAccessPrevention: "enforced"`, versioning off, one
`Delete` lifecycle rule per expiry rule with `matchesPrefix` and `age`, `protect: true` and no
`forceDestroy`. Per grant: a service account; `roles/storage.objectUser` (read-write) or
`roles/storage.objectViewer` (read-only) as a `BucketIAMMember` on that bucket;
`roles/iam.workloadIdentityUser` on the account for that grant's one pool subject; and, when
signing, `roles/iam.serviceAccountTokenCreator` on the account for the account itself. A retired
bucket sets `disabled: true` on its accounts and changes nothing else.

Wire both in `infra/pulumi/index.ts`. Tests in `infra/pulumi/test/` assert every attribute above
and that the program creates no `gcp.serviceaccount.Key`, no member starting with `all`, and no
project-level IAM member for these accounts; the catalog parity test covers the new entries.

### M3. Kubernetes side and the review order

In `compileStandaloneBucket` (`cli/nagare-core/src/Nagare/Inventory/ObjectBucket.hs`), a
`GcsBackend` yields per grant, in the workload's namespace: a ServiceAccount `nagare-wl-<workload>`
with no RBAC, and a ConfigMap `nagare-bucket-<bucket>-<workload>` holding the `external_account`
credential configuration (the provider's audience, the token type
`urn:ietf:params:oauth:token-type:jwt`, the impersonation URL of the grant's account, and a file
credential source at the token's mount path).

A bound workload renders `serviceAccountName: nagare-wl-<workload>`, keeps
`automountServiceAccountToken: false`, and gets one `PlatformMount` at `/var/run/nagare/identity/`
with the ConfigMap and a `ServiceAccountTokenSource` for the provider's audience. Its variables
are `NAGARE_BUCKET_<NAME>_BACKEND=gcs`, `_NAME` (the Google bucket name), `_SERVICE_ACCOUNT` (the
account's email, which a client needs to sign) and `GOOGLE_APPLICATION_CREDENTIALS`. A workload
with two buckets has one account holding both grants.

The order is bucket review, cloud review, application review. The application compile refuses
`bucket-cloud-identity-missing` until the accepted `platform:cloud` scope contains that grant's
entries. `nagarectl bucket status` prints the backend, the Google name and each grant.

Interpreter tests: the manifests; the refusal before the cloud review and acceptance after; a
workload naming its own `serviceAccount`; adding a grant to a live bucket; and a JWKS change (a
rebuilt cluster) appearing as an update of the provider alone.

### M4. Cloud confirmation

Complete [`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md). Ask the
operator once for the sequence in Concrete Steps on a disposable cloud context they name; MasterPlan
39 suggests running it together with the content-domain plan's cloud run. The fixture image is a
small HTTP server using Google's storage client library unchanged, with two endpoints: one writes
an object and returns a V4 signed PUT URL, one tries a write and reports the status. Run it locally
against the declared variables first, as the runbook requires.

### M5. Retirement, documentation and ADRs

`nagarectl bucket retire` on a cloud context sets the `retired` flag, so the next cloud review
disables the accounts. Its `reviewEffects` lines name each workload and account losing access and
state that the bucket and its objects are kept and that Nagare offers no deletion. Tests assert
the lines and the Pulumi result.

Extend `docs/user/object-storage.md` with the cloud backend, the three-review order and signing.
Add to `docs/user/backups-and-disaster-recovery.md`: after a cluster rebuild, rerun the cloud
review so the new JWKS is uploaded before workloads can reach their buckets. Write a new ADR,
"Workloads reach Google Cloud through identity federation, never a key", which also records that
buckets are standalone scopes Nagare never deletes, and amend ADR 36. Follow
`.claude/skills/exec-plan/ADR.md` for handles and validation.


## Concrete Steps

All commands run from the repository root.

```bash
just gate-commit                 # per Haskell commit
just mutation-check HEAD BASE    # before landing planner, executor or adapter changes
just gate-fast && just land HEAD
```

```bash
(cd infra/pulumi && npm test)    # after Pulumi changes
```

Cloud confirmation (M4), with the operator's go-ahead, on the disposable cloud context `CTX`.
Every mutation is a saved review. Take exact flag spellings from each command's `--help`, and the
cloud review commands from [`docs/user/provisioning-with-pulumi.md`](../user/provisioning-with-pulumi.md).

```bash
nagarectl --context CTX bucket plan --file cluster/examples/content-app/nagare/Config.hs --save-plan review-bucket
nagarectl --context CTX inventory apply review-bucket --yes
# reviewed cloud stage here
nagarectl --context CTX app deploy --file cluster/examples/content-app/nagare/Config.hs --tag v1 --save-plan review-app
nagarectl --context CTX inventory apply review-app --yes

SIGNED_URL=$(curl -sS https://content-app.BASE/put-and-sign | sed -n 's/.*signed url //p')
curl -sS -X PUT --data-binary @/etc/hostname "$SIGNED_URL" -o /dev/null -w '%{http_code}\n'
curl -sS https://content-app.BASE/gateway-try-put
for sa in "$API_SA" "$GATEWAY_SA"; do
  gcloud --project "$PROJECT" iam service-accounts keys list --iam-account "$sa" --managed-by user --format 'value(name)'
done
gcloud --project "$PROJECT" storage buckets describe "gs://$BUCKET" \
  --format 'value(uniform_bucket_level_access,public_access_prevention,lifecycle_config)'
gcloud --project "$PROJECT" storage buckets get-iam-policy "gs://$BUCKET" --format json \
  | jq '[.bindings[].members[] | select(startswith("all"))]'
```

Expected: `200` from the upload; `gateway: get ok, put 403`; no key names; `True enforced` and a
rule matching `staging/`; and `[]`. Record the transcript under Progress.


## Validation and Acceptance

IR-55 AC-1 (cloud half): M2's tests and M4's bucket description. AC-2: M4's write, working signed
URL, refused write and empty key lists. AC-5 (bucket, cloud): M5's tests.

The plan is accepted when `just gate-fast` is green on the landed commit, the post-land full gate
is green, and the M4 transcript is under Progress.


## Idempotence and Recovery

Every change is a saved review. A bucket review followed by a failed cloud review leaves a
declared bucket with no cloud resources; the application compile refuses until the cloud review
converges, so nothing runs half-bound. The Pulumi resources are additive and the bucket is
protected. Undoing a grant is a bucket review that drops it, then the cloud review. If federation
does not work in M4, nothing is left to undo beyond the disposable context's reviewed teardown,
and the plan stops at the first Decision Log entry for a new decision. After any cluster rebuild,
rerun the cloud review to upload the new JWKS.


## Interfaces and Dependencies

Derived Pulumi config, written only by `nagarectl`:

```json
{
  "nagare:workloadIdentity": {"issuer": "https://kubernetes.default.svc.cluster.local", "jwks": {"keys": []}},
  "nagare:appBuckets": [{
    "name": "publications",
    "bucket": "PROJECT-CTX-publications",
    "retired": false,
    "expire": [{"prefix": "staging/", "afterDays": 1}],
    "grants": [{
      "subject": "system:serviceaccount:personal:nagare-wl-content-app",
      "accountId": "nagare-wl-3f9a1c",
      "access": "read-write",
      "signUrls": true
    }]
  }]
}
```

The issuer value shown is an example; read the real one from the cluster.

A bound workload on this backend sees `NAGARE_BUCKET_<NAME>_BACKEND=gcs`, `_NAME`,
`_SERVICE_ACCOUNT`, `GOOGLE_APPLICATION_CREDENTIALS=/var/run/nagare/identity/credentials.json`, and
the token file beside it.

External behaviour relied on and confirmed only by M4: Google accepts a pool provider with an
uploaded JWKS for an issuer it cannot reach; Google's client library signs V4 URLs through
`signBlob` when running as an impersonated account from an `external_account` configuration.

Hanmoto (`mori://shinzui/hanmoto`) selects its storage adapter from
`NAGARE_BUCKET_<NAME>_BACKEND`.
