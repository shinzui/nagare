---
id: 39
slug: provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys
title: "Provision app object storage, isolated content domains and rotating signing keys"
kind: master-plan
created_at: 2026-11-25T16:08:21Z
intention: "intention_01m89q6asjedws62wy3n95r4e7"
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
      note: "EP-1 started"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-25T19:25:59Z
      mode: "implement"
      note: "EP-3 M2-M3 and EP-4 M1-M2 landed locally; cross-plan retirement finding"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-26T01:47:28Z
      mode: "implement"
      note: "EP-4 M3 landed locally; PlatformMount consumption finding"
---

# Provision app object storage, isolated content domains and rotating signing keys

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

## Vision & Scope

IR-55
([`docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md`](../improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md)),
filed by `mori://shinzui/hanmoto`, asks for three capabilities so that a service that stores user
files and serves untrusted HTML needs no hand-made cloud resources. When this initiative is
complete an application's `nagare/Config.hs` can declare:

1. A private object bucket with prefix-scoped expiry rules, where each named workload gets its own
   identity with read-write or read-only access and, optionally, the right to sign URLs as itself.
   On a cloud context the bucket is on GCS and no service-account key exists. On a local context
   the same declaration is served by the packaged MinIO store.
2. A wildcard content domain on a registrable domain separate from the context's base domain,
   plus fixed hosts under it, all routed to one worker that receives the original `Host` header
   under a DNS-01 wildcard certificate.
3. A generated Ed25519 signing key set that the platform rotates, which signers and verifiers read
   from files that change in place.

Each is a reviewed change, and retiring one is a reviewed change that prints what is lost.

Out of scope: any knowledge of publications, revisions or grants; CDN fronting of a content
domain; content routes on a Cloudflare Tunnel context; deleting a bucket; escrow of signing keys;
blocking application pods from the VM's metadata server.


## Decomposition Strategy

The three capabilities share almost no code and each has a different unknown, so each is a child
plan. Object storage is split in two because its local half is ordinary inventory work that can
land and be used at once, while its cloud half adds IAM, a Pulumi component and the one mechanism
in the initiative that only a cloud run can confirm (workload identity federation).

One piece of groundwork is shared: a review field that lists what a retirement loses, and a way
for the platform to mount files into a workload. It is the first milestone of EP-1, so the other
plans depend on that milestone and not on a fifth plan.

Alternatives rejected. One ExecPlan (the first draft, 2026-11-25): eight milestones with three
unrelated native confirmations, hard to resume and to review. One plan per IR acceptance
criterion: AC-5 (removal) cuts across all three capabilities and cannot be delivered apart from
them. Declaring buckets and key sets as fields of `Application`: both hold state that must outlive
an application retirement, and cloud identities must exist before workloads start, so they are
standalone scopes like app databases.

Relevant ADRs:

- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): every
  cloud mutation asserts the active context's project. EP-2 and EP-3 create cloud resources only
  through the guarded Pulumi path.
- [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md): a public wildcard
  certificate needs an explicit opt-in. EP-3 adds one.
- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  Pulumi holds no service-account key. EP-2 creates none.
- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md): one base domain per
  context, no credentials for external DNS providers. EP-3 amends it with context-owned content
  zones.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): one owner
  per resource, generated values are templates, durable data is retained.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): every
  adapter path gets an interpreter test before a native run.
- [ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md): the
  tunnel serves one zone, so EP-3 refuses content routes there.
- [ADR 36](../adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md):
  Nagare authors no application ServiceAccount. EP-2 amends it.
- [ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md): a
  workload gets only the Secrets it is entitled to. EP-1, EP-2 and EP-4 follow it.

New ADRs expected: workload cloud identity through federation (EP-2) and platform-rotated key sets
(EP-4).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Declare an app object bucket with per-workload access on the local object store | docs/plans/283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md | None | None | Complete |
| 2 | Give each granted workload a keyless cloud identity on a GCS bucket | docs/plans/284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md | EP-1 | None | In Progress |
| 3 | Serve a wildcard content domain from one worker with the Host header intact | docs/plans/285-serve-a-wildcard-content-domain-from-one-worker-with-the-host-header-intact.md | EP-1 M1 | None | Complete |
| 4 | Generate and rotate an Ed25519 signing key set that workloads read from files | docs/plans/286-generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files.md | EP-1 M1 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-1 M1 comes first. It delivers `reviewEffects` (the "This review removes:" lines) and
`PlatformMount` (files the platform mounts into a workload), and it confirms that Knative admits
those mounts. EP-3 and EP-4 need only that milestone: EP-3 uses `reviewEffects` for its retirement,
EP-4 uses both. After EP-1 M1, EP-3 and EP-4 can proceed in parallel with the rest of EP-1.

EP-2 needs all of EP-1: it adds a GCS backend to the bucket scope, CLI, bindings and retirement
that EP-1 defines.

Suggested order for one contributor: EP-1, then EP-3 (its prototype decides whether the routing
design holds, so learn it early), then EP-2, then EP-4. EP-2 M4 and EP-3 M4 each need a cloud run on
a disposable context; ask the operator once for both and run them on the same context.


## Integration Points

- `reviewEffects` and `SavedReview.effects`. Defined by EP-1 M1 in
  `cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs` and
  `cli/nagare-contract/src/Nagare/Contract/V1.hs`. EP-2, EP-3 and EP-4 only add effect lines.
- `PlatformMount`. Defined by EP-1 M1 in `cli/nagare-dsl/src/Nagare/Dsl/Mounts.hs` with ConfigMap,
  Secret and projected service-account-token sources, rendered for Knative Services, workers and
  tasks. EP-2 (identity files) and EP-4 (key files) consume it and do not change its shape.
- Workload records. EP-1 adds `buckets` to `Deployment`, `Worker` and `Task`; EP-4 adds `keySets`
  to the same three; EP-3 adds `http` to `Worker`. Each migrates every literal of those records, so
  each rebases on the landed tree first. No two plans add the same field.
- The bucket scope. EP-1 owns `ObjectBucket`, the scope `bucket-<key>`, `nagarectl bucket` and the
  `NAGARE_BUCKET_<NAME>_*` variables. EP-2 adds the `gcs` backend behind them.
- `infra/pulumi/resource-catalog.json` and `infra/pulumi/index.ts`. EP-2 adds the bucket and
  identity entries and `nagare:appBuckets` / `nagare:workloadIdentity`; EP-3 adds the content zone
  entries and `nagare:contentDomains`. Separate keys and components.
- The example `cluster/examples/content-app/nagare/Config.hs`. EP-1 creates it with the bucket;
  EP-3 adds the gateway's content route; EP-4 adds the key set. It is the fixture of the final
  gate.
- Context variables. EP-3 adds `NAGARE_CONTENT_DOMAINS` and updates `CLAUDE.md`'s list.

Cross-plan decisions that become ADRs: buckets and key sets are standalone scopes that outlive
applications (in EP-2's and EP-4's ADRs); a bucket is never deleted by Nagare (EP-2's ADR).


## Progress

EP-1, EP-3 and EP-4 are complete. EP-2 M1 to M3 are done (derived config, Pulumi components, the
Kubernetes side with its review order and retirement); its cloud run (M4) runs on `ep285`, which
EP-3's cloud run left up. One gate is not owned by a child:

- [ ] Final gate. `cluster/examples/content-app` deploys with all three declarations on a local
  context and on the disposable cloud context; IR-55's five criteria each point at recorded
  evidence; IR-55's file and `docs/improvement-requests/log.md` are marked completed with the
  landed revision; Hanmoto is told the revision to qualify.


## Surprises & Discoveries

- EP-1 M1 is complete (2026-11-25): Knative Serving 1.22.0 admits the platform mounts with no new
  feature flag, so EP-2 and EP-4 may mount files into a Knative Service as well as a worker and a
  task. EP-3 and EP-4 are unblocked. (The Docker VM's disk pressure was cleared on 2026-11-25; the
  initiative's local native runs use the disposable context `mp39` on its own Colima profile,
  `nagare-mp39`, bootstrapped by the harness's transition drill, because `nagare-local` also hosts
  another project.)

- EP-3's routing design holds (2026-11-25): Kourier serves a hand-written wildcard Knative Ingress
  over TLS to a plain Service with the `Host` header intact. An exact host under the wildcard in
  another namespace is served by the exact Ingress without any error, so only the compile's claim
  rule keeps a content domain to one worker.

- A generated value that two namespaces need cannot be shared by a Secret reference or read by a
  Job: neither crosses a namespace. EP-1 solved it for a bucket credential with the adapter's copy
  template (`minioUserCopyKind` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`). EP-4 has the same shape
  when a key set's signer and verifiers are in different namespaces, and should read EP-1's
  Decision Log before designing its Secrets.

- An Application's own service and workers take no binding from another scope today; only a
  standalone Deployment, a standalone Worker and a task do (EP-202's rule for app databases).
  Buckets and key sets are standalone scopes, so EP-1's bindings, EP-4's `keySets` and the shared
  example `cluster/examples/content-app` all meet this. EP-1 built bindings on the standalone paths
  first; the operator then decided that an Application's service and workers bind too (Decision
  Log), and EP-1 added `scopeBucketBindings` to the application compile. EP-4 follows the same
  path for `keySets`.

- A Kubernetes Job member never changes once created, and the planner replaces none. EP-1 names
  each Job by a digest of what it runs and retires the superseded one in the same review. EP-4's
  rotation, if it uses Jobs, needs the same rule.

- A retirement removes a member from the desired state and leaves the object live; only an
  `ApproveCollection` deletes, and `collectionKinds`
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesCollection.hs`) admits neither a Kourier
  Ingress, a cert-manager Certificate nor a Secret (2026-11-25, EP-3's Surprises). EP-3 M5 says
  its retirement stops the hosts being served and destroys the certificate key; EP-4 M5 says its
  retirement destroys the private keys. Neither holds as written. One decision should cover both:
  collect the members in the retiring review (extending collection to those kinds, with the
  recovery model's `KindCollect` rows and mutation records), or retire them and state that the
  hosts and keys stay until a collect.

- The first consumer of `PlatformMount` is EP-4's key set binding (2026-11-25). The renderers in
  `cli/nagarectl/src/Nagare/App/Deploy.hs` apply the mounts a workload's own bindings derive
  (`keySetMounts`), so the bytes of a workload with no binding do not move, and the accepted
  state only refuses or orders. EP-2's identity mounts should be derived and applied the same
  way. Key set bindings share `scopeBucketBindings` (EP-1's map) as `keyset-NAME`.

- A key set works on a context only once a release rebuilds the admin-api image (2026-11-26). A
  context runs the release payload's pinned images (`release.json`), so a development package
  still runs the last release's admin-api image, which has no `/usr/local/bin/nagare-keyset`: on
  `mp39` the first-run Job failed with "stat /usr/local/bin/nagare-keyset: no such file". The run
  used `NAGARE_ADMIN_API_IMAGE` with `release-image-admin-api` built at this revision. Hanmoto can
  use key sets only from the release that carries this change; the final gate's qualification is a
  release, not a revision.

- A collect review refuses a member that another retained member depends on, even one collected in
  the same review (2026-11-26). EP-3's and EP-4's retirements therefore print one collect review per
  wave, leaves first (`collectionWaves`); a single printed command would have been refused.

- The first native deploy of a content route on `ep285` found a defect no interpreter test reached:
  `app deploy` rebinds generated members from their bytes, and an Ingress's domain claim was not
  derivable from its object (2026-11-26, fixed in `5ba934f0`). New generated kinds should get a
  rebind test (`validateSuppliedKubernetesMembers`) with their compile test.

- The recovery model's world holds a kind in line only with traces recorded from a real cluster,
  and the recording (`docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh`) covers
  neither net-kourier nor cert-manager. EP-3 keeps both as documented limits and confirms them
  natively (its Decision Log). EP-4's kinds (Secret, ConfigMap, RBAC, CronJob, Job) are in line.

## Decision Log

- Decision: Four child plans, with the shared groundwork as EP-1's first milestone.
  Rationale: See Decomposition Strategy. A fifth groundwork plan would have had no observable
  behaviour of its own.
  Date: 2026-11-25

- Decision: Buckets and key sets are standalone scopes; a content route belongs to a worker inside
  an application.
  Rationale: Buckets and key sets hold state that outlives an application and are granted to
  workloads with different rights. A route has no state and is meaningless without its workload.
  Date: 2026-11-25

- Decision: A content domain is a context property and the context owns its DNS zone.
  Rationale: Delegating a registrable domain is an operator act at a registrar, and the DNS-01
  solver's write grant is per zone.
  Date: 2026-11-25

- Decision (operator, 2026-11-25): an Application's own service and workers take bucket bindings,
  and key set bindings when EP-4 adds them. EP-202's rule for app databases is unchanged.
  Rationale: IR-55's shape is one Application; see Surprises & Discoveries.
  Date: 2026-11-25

- Decision: One intention, `intention_01m89q6asjedws62wy3n95r4e7`, covers the MasterPlan and its
  four children.
  Rationale: It was minted for the single-plan draft of the same work.
  Date: 2026-11-25


- Decision (operator, 2026-11-25): retiring a content route or a key set deletes its objects.
  Following ADR 22, deletion stays its own reviewed step: the retiring review retains the members,
  and the `inventory collect` review that follows deletes them and carries the "This review
  removes:" lines; the retire command prints that next step. Collection is extended to the Kourier
  Ingress and the cert-manager Certificate. Collecting a content Certificate also deletes the
  Secret cert-manager wrote for it (see the owner-reference decision below). The key set's Secret is declared `Stateless`, since a
  rebuilt cluster regenerates it (EP-286's no-escrow decision), which makes it collectable. Each
  new collectable kind gets its `KindCollect` row and a mutation record.
  Rationale: a retirement that leaves the Ingress serving or the private keys in place would
  make the review's removal lines false; ADR 22 keeps deletion a separate reviewed authority.
  Date: 2026-11-25

- Decision (operator, 2026-11-25): cert-manager runs with `--enable-certificate-owner-ref=true`
  on every context, so a Certificate owns the Secret it writes and a Background collection of a
  content Certificate deletes its private key. The flag is applied as a reviewed container-args
  override of the vendored cert-manager controller, not by editing the pinned manifest.
  Rationale: one platform rule, reusing the existing Background collection path, instead of a
  content-route Secret kind whose data another controller owns. Every Certificate's Secret now
  goes with its Certificate, including Knative route certificates and the local CA's.
  Date: 2026-11-25

## Outcomes & Retrospective

(To be filled during and after implementation.)
