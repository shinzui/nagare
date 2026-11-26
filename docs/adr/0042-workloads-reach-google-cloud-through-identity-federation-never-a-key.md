---
title: "Workloads reach Google Cloud through identity federation, never a key"
status: accepted
date: 2026-11-26
authors: [shinzui]
related:
  - docs/plans/284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md
  - docs/plans/283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md
  - docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md
---

# ADR 42 — Workloads reach Google Cloud through identity federation, never a key

## Status

Accepted and implemented by [EP-284](../plans/284-give-each-granted-workload-a-keyless-cloud-identity-on-a-gcs-bucket.md)
(MasterPlan 39), for IR-55 from `mori://shinzui/hanmoto`.

## Context

An application needed a Google Cloud Storage bucket of its own on a cloud context. The only cloud
identities Nagare had were an exported JSON key (the lifecycle worker, the admin API) and the VM's
metadata-server identity, which every pod on the node shares. A key is a long-lived secret that has
to be stored, rotated and escrowed; the node identity cannot tell one workload from another.

## Decision

1. **Each grant is its own Google service account**, reached by workload identity federation. The
   context's pool provider trusts the k3s cluster's service-account issuer; nagarectl reads the
   issuer and its JWKS from the API server and the cloud review uploads the JWKS, so the issuer
   needs no public URL and the host needs no change. The workload's projected token, whose audience
   is the provider, is exchanged at STS and impersonates the grant's account. No key exists.
2. **The account admits one subject**, `system:serviceaccount:NS:nagare-wl-WORKLOAD`, and holds one
   role on one bucket: Storage Object User for read-write, Storage Object Viewer for read-only. A
   signing grant may also mint tokens as itself (`roles/iam.serviceAccountTokenCreator`), for V4
   signed URLs. Nothing is granted at project level.
3. **Three reviews in order.** The bucket review creates the Kubernetes account and the credential
   configuration; the cloud review creates the pool, the bucket and the accounts from the accepted
   buckets; the application review binds the bucket and is refused (`bucket-cloud-identity-missing`)
   until the cloud review has created that grant's federation.
4. **Buckets are standalone scopes Nagare never deletes** (ADR 22). The Google bucket is protected
   in Pulumi. A retired bucket keeps its bucket, its objects and its accounts, and the cloud review
   disables the accounts, which refuses every credential at once; a dropped grant's account is
   deleted.

## Consequences

- A workload runs as one Kubernetes account, so on a cloud context it binds at most one bucket and
  cannot also name its own `serviceAccount`; a task cannot bind a cloud bucket. Lifting this needs
  one account holding several grants.
- A rebuilt cluster signs tokens with new keys: the cloud review must run again, uploading the new
  JWKS, before workloads reach their buckets.
- Application pods keep their route to the VM's metadata server. The node account holds no role on
  an application bucket, so grants hold; closing that route is a separate change.
- Exported keys elsewhere in the platform (the lifecycle worker, the admin API) are unchanged; they
  can move to the same federation later.
