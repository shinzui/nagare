---
id: 196
slug: read-the-inventory-store-from-an-in-cluster-service-identity
title: "Read the inventory store from an in-cluster service identity"
kind: exec-plan
created_at: 2026-10-14T17:49:39Z
master_plan: "docs/masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-14T17:49:39Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T00:19:10Z
      mode: "update"
      note: "MasterPlan 28 design review for the admin UI and Kotei: one recorded-state reader, admin.<base> origin, service-account bearer, Deployment+NetworkPolicy, gateway problem documents, ETag/head summary"
---

# Read the inventory store from an in-cluster service identity

Child of [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md).
Progress holds the deliverables with pass/fail evidence; the Decision Log holds dated decisions.


## Purpose / Big Picture

Today only an operator's machine can open a context's inventory store. The admin API
([EP-197](197-serve-the-read-documents-through-a-typed-servant-admin-api.md)) runs inside the
cluster, so it needs to read the same store with a credential of its own. After this plan,
`nagarectl`'s library has a read-only `openServiceStore` that opens a context's GCS inventory store
from inside a pod, proves the bucket belongs to the context's project exactly as the operator path
does, and cannot write. Choosing the credential is the main decision here, because whatever the API
pod can read, a compromised pod with the same identity can read too.


## Progress

- [ ] M1. Exposure established and credential chosen. Pass: a dated Decision Log entry records
  (a) what the inventory store's objects contain, checked on the intranet's store read-only with
  `nagarectl inventory store status --json` and by listing and reading a sample of scope objects,
  in particular whether any object holds secret material rather than digests and references;
  (b) whether an ordinary application pod can obtain the node service account's token, shown
  by a disposable pod on a local context or by the existing backup-job path (`Nagare.Cluster.GcsJob`);
  and (c) the chosen credential with its exact IAM grant. If (a) finds secret material, or the
  only workable credential is readable by every workload, stop and ask the operator before M2.
- [ ] M2. `openServiceStore` reads a GCS store with a service credential and proves ownership
  without `gcloud`. Pass: interpreter tests over a fake token source and a fake GCS (the existing
  loopback `endpointOverride` in `Store/Remote.hs`) show a store opened and its head and scopes
  read; a bucket owned by another project number refused; a token failure surfacing as the
  `store_unavailable` or `reauthentication_required` catalog code, never as an empty result; and
  every write operation (`ObjectOps` writes) refused by construction, with a test that a write
  attempt fails before any request. `just haskell-style-check` and `just gate-fast` green, landed.
- [ ] M3. The grant exists as reviewed infrastructure. Pass: the IAM grant from M1 is declared in
  the Pulumi program (`infra/pulumi`), scoped to the inventory prefix, and a recorded preview on
  a disposable cloud context shows exactly that one added member. No apply here; EP-198 applies it
  with the deployment.


## Decision Log

- 2026-10-14: The reader reuses the existing gogol object operations rather than a second GCS
  client. `newGogolObjectOpsWithToken` (`src/Nagare/Inventory/Store/Gogol.hs:128`) already takes the
  token as an `IO Text` action; the service path supplies a different action. Ownership uses the
  same verdict function (`bucketOwnershipVerdict`, `src/Nagare/Ops/PulumiBackend.hs:168`) with the
  two project numbers read without `gcloud`.
- 2026-10-14: Only `gcs` stores are supported. A `local` store lives on the operator's machine and
  is not reachable from the cluster; local runs of the API open it with the existing local path.
- 2026-10-14 (MasterPlan 28 review): Option 1 is the default unless M1(a) finds plaintext secret
  material in scope objects; see Posture under Context. Store failures map to the shared catalog
  (`store_unavailable`, `reauthentication_required`).


## Context and Orientation

Paths are relative to the repository root; `src/` means `cli/nagarectl/src/`.

**The inventory store** ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md))
holds a mutable head (`HeadManifest`: accepted and converged scope revisions, the active
transaction) and immutable, digest-addressed scope objects (`src/Nagare/Inventory/Store.hs`). A
cloud context may keep it in GCS (`NAGARE_INVENTORY_STORE=gcs`); the default URL is
`gs://<project>-nagare-pulumi-state/nagare/<context>/inventory`, which is a prefix of the **Pulumi
state bucket** (see `docs/user/contexts.md`, "Shared inventory history"). The intranet uses a GCS
store. A local-mode context, and a cloud context without that setting, keep the store in a local
directory under `${XDG_STATE_HOME}/nagare/<context>/inventory`.

**How the operator path opens it.** `openTargetStoreReadOnly` (`src/Nagare/Inventory/Store/Target.hs:34`)
calls `remoteObjectOps` (`src/Nagare/Inventory/Store/Remote.hs`, around line 70). With the default
transport (`gogol`), that calls `newGcloudSession` (`src/Nagare/Inventory/Store/GcloudAuth.hs`),
which runs `gcloud config config-helper` for an access token and refuses unless the credential's
project equals the context's. The ownership check then reads the bucket's project number and the
context project's number through `gcloud` (`readProjectNumber`) and compares them with
`bucketOwnershipVerdict`. Only then does it build object operations with
`newGogolObjectOpsWithToken`. A pod has no `gcloud`, so every step before the last must be replaced.

**Who can read what today.** The Pulumi program creates one node service account, described in
`infra/pulumi/src/components/NagarePerimeter.ts` as the "node/workload service account". It has
`roles/artifactregistry.writer` on the project and `roles/storage.objectAdmin` on the backup bucket
only, not on the Pulumi state bucket. Pods reach the GCE metadata server for that account's token:
the backup jobs do exactly that (`src/Nagare/Cluster/GcsJob.hs`, header comment). So any grant to
the node account is, in practice, a grant to every workload on the node, developer applications
included. The state bucket also holds Pulumi state, which is why any grant must be limited to the
inventory prefix.

**Credential options M1 decides between.**

1. The node service account, with `roles/storage.objectViewer` on the state bucket under an IAM
   condition restricting `resource.name` to the inventory prefix, plus `storage.buckets.get` for the
   ownership check. Simple, no secret to rotate, but readable by every pod.
2. A dedicated read-only service account with the same scoped grant, whose key is delivered as a
   sops-encrypted Secret readable only in `nagare-system`. Only the API pod can read, but a
   long-lived key must be created, delivered and rotated.
3. Option 1 or 2, plus blocking the metadata server for non-`nagare-system` namespaces with a
   NetworkPolicy, which would also change what backup jobs can do. Larger, and outside this plan
   unless M1 shows it is needed.

The project number of the context comes from the metadata server
(`computeMetadata/v1/project/numeric-project-id`) under option 1, or from the key's project under
option 2, and must still equal the bucket's owning project number.

**Posture (MasterPlan 28 review, 2026-10-14).** Option 1's exposure class, a node-account grant
readable by every pod, already exists: the backup bucket holds database dumps under
`roles/storage.objectAdmin` on that account. Option 1 therefore adds no new class, and option 3
is what closes the class for both; it goes to the deferral ledger with the operator's approval
rather than into this plan. M1's stop condition stands. The API pod is a plain Deployment with
an egress NetworkPolicy (EP-198), so under option 1 the metadata server (`169.254.169.254:80`)
and the GCS endpoint are explicit egress rules, not an implicit path.

**ADRs.** [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md):
every cloud path is bound to the active context's project; the service reader keeps the same
binding even though it only reads. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
operator secrets never live in this repository, which governs where option 2's key is kept.


## Plan of Work

M1 is investigation and a decision; do it read-only. Use the operator's normal context selection
for the intranet read (`nagarectl --context <intranet> inventory store status --json`), and a
disposable local context for the pod-token check. Record findings as one Decision Log entry.

M2 adds `src/Nagare/Inventory/Store/Service.hs` exporting `openServiceStore`. It takes the context
name, project, store URL and a `ServiceCredential` (the M1 choice: a metadata-server token source,
or a key file path), builds the token action, reads both project numbers through the GCS and
metadata (or IAM) APIs via gogol, applies `bucketOwnershipVerdict`, and returns an `InventoryStore`
whose write operations are absent: give the service path a read-only wrapper over `ObjectOps`
(`src/Nagare/Inventory/Store/ObjectOps.hs:66`) whose write fields fail without sending a request.
Map failures onto the problem catalog owned by EP-192 (`Nagare.Contract.Problem`): add catalog
entries only if a needed code is missing. Test with the loopback fake GCS already supported by
`endpointOverride` in `Store/Remote.hs`.

M3 declares the grant in `infra/pulumi` beside the existing bucket grants, with a comment naming
this plan, and records a preview.


## Validation and Acceptance

Offline: the M2 tests named in Progress, run with
`cabal test nagarectl-test --offline --test-show-details=failures` from `cli/nagarectl`. Native:
M3's recorded preview. The in-cluster read itself is proven by EP-198's native run.


## Interfaces and Dependencies

- `openServiceStore :: ServiceStoreConfig -> IO (Either StoreError InventoryStore)` in
  `src/Nagare/Inventory/Store/Service.hs`, consumed by EP-197.
- `data ServiceCredential`, whose constructors follow M1's decision.
- Problem codes from `Nagare.Contract.Problem` (EP-192).
- No new library dependency: `gogol` 1.0.0.0 and `gogol-storage` 1.0.0 are already in
  `cli/nagarectl/nagarectl.cabal`.
