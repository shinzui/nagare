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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T22:20:47Z
      mode: "update"
      note: "Source-based API validation: correct shared interfaces, bounded read costs, HTTP behavior and serving acceptance."
---

# Read the inventory store from an in-cluster service identity


## Purpose / Big Picture

Provide `openServiceStore` for the read-only admin API without `gcloud`, operator workspace
setup or a credential that can mutate the context. It must preserve context/project/bucket
ownership checks, support a long-running server, and fail within the caller's deadline.
[MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md)
coordinates this with the document contract and HTTP service; this plan does not deploy anything.


## Progress

- [ ] M1. Record the inventory exposure audit and exact credential/IAM design. Read only the
  selected context's store, report object classes rather than private contents, and distinguish
  canonical scope declarations from archived/native payloads. Establish a dedicated reader
  identity, its token exchange, numeric project lookup and delivery/rotation path. No default
  grant to the node account is permitted under the read-only credential requirement.
- [ ] M2. The service session opens an existing store, checks both numeric project ownership
  and canonical store binding, reads its head/scopes, refreshes expiring tokens and propagates
  cancellation. Fake-token/GCS tests prove the exact request permissions, fail-closed ownership,
  no writes/listing/initialization, missing/corrupt handling and concurrent refresh behavior.
  `just haskell-style-check` and `just gate-fast` pass.
- [ ] M3. Reviewed Pulumi infrastructure declares the dedicated identity, minimal IAM and its
  selected credential delivery. A disposable cloud preview shows all expected additions (account,
  role/bindings and delivery as applicable), with no unrelated permissions. EP-198 owns apply
  and native permission proof after its required authorization.


## Surprises & Discoveries

The existing object reader performs an absence-listing fallback and has per-attempt timeouts;
service reads need a different missing-object policy and a caller-owned total deadline.


## Decision Log

2026-10-16: Validation supersedes the 2026-10-14 node-account default. That account has
`roles/artifactregistry.writer` and backup-bucket `roles/storage.objectAdmin`
(`infra/pulumi/src/components/NagarePerimeter.ts`). A read-only ObjectOps wrapper does not make
its credential read-only. Existing backup exposure is not authorization to expose inventory or
Pulumi state to every pod. Use a dedicated reader account; a node-account exception would change
the stated requirement and needs an explicit operator decision, not a silent fallback.

2026-10-16: Reuse the gogol transport with a service-specific read policy, not the operator's
whole opener. GCS object GET currently performs metadata then generation-pinned media; a 404
falls back to listing. The service neither initializes stores nor proves absence for mutation,
so its missing-object path must fail closed without bucket listing. IAM resource-name conditions
cannot prefix-confine `storage.objects.list`. Grant exact object reads and separate bucket
metadata permission, rather than promising a prefix-scoped objectViewer list.

2026-10-16: Retain the HTTP manager and token source for the server lifetime, cache access tokens
only until shortly before their reported expiry and coalesce refresh. Ownership is rechecked for
each authoritative head read; no indefinitely cached mutable ownership/head substitutes for the
current check. EP-197's total deadline covers that check and token refresh. Configuration changes
construct and validate a new session before using it.


## Context and Orientation

The inventory's mutable `head.json` names immutable scope digests; remote storage is normally
`gs://<project>-nagare-pulumi-state/nagare/<context>/inventory`, inside the Pulumi state bucket.
`cli/nagarectl/src/Nagare/Inventory/Store/Target.hs` opens the operator store;
`Store/Remote.hs` calls `Store/GcloudAuth.hs` for credentials/project checks. Pods must not call
these CLI paths. `Store/Gogol.hs` exports `newGogolObjectOpsWithToken`, taking an `IO Text`
token source and retaining a manager. Its token adapter builds an SDK environment through a
private temporary token file per request; the service must provide a writable private temp
directory even with a read-only container root. Its current SDK attempts and manager response
timeouts are twenty seconds, longer than the API's total ten-second budget.

`Store.hs` exposes `openObjectStoreReadOnly`, `readHead` and immutable caching. Read-only opening
still validates format/binding and must not mint a writer identity, create a lock in the source
store, initialize missing format, migrate, or infer success from missing objects. Local cache
writes are allowed in a separate bounded writable cache directory. `Store/Remote.hs`'s
`endpointOverride` is private: extract a test-only/injected constructor or reuse the established
loopback test setup, rather than claiming it is an exported API.

[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires
context/project and bucket-owner binding, including read paths;
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps operator secret material outside this repository; the recorded-read amendment in
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) separates
observation from mutation authority. The service uses the existing gogol dependencies; consult
`mori://brendanhay/gogol` source/docs before selecting credential constructors. Do not assume a
service-account key's string `project_id` is the numeric project number.


## Plan of Work

M1 audits the selected store and establishes the dedicated identity. Default delivery is the
existing operator-secret mechanism: a service-account key held in sops-encrypted operator material
and mounted only into the API pod. A keyless dedicated identity may replace it only after proving
that this self-managed k3s deployment can actually obtain it without exposing the node account.
Record key creation/rotation/revocation and the exact token endpoint in the delivery decision.
Never put a key or token in evidence. Confirm API summaries exclude native Secret/configuration
payloads even when the reader can access inventory objects.

Use a custom role granting `storage.objects.get`, with a bucket IAM condition whose
`resource.name` starts with `projects/_/buckets/<bucket>/objects/nagare/<context>/inventory/`
(the trailing slash matters). Supply `storage.buckets.get` separately on the exact bucket for
ownership; object resource-name conditions do not match bucket metadata. Obtain the expected
numeric project number through a documented authoritative project lookup, bound to the configured
project ID; if Cloud Resource Manager is used, declare `resourcemanager.projects.get` and the
required client dependency explicitly. A key's `project_id`, metadata numeric ID, quota project,
and bucket owner number are different values; compare the actual owner to the configured target's
number, not to a guessed key field. Use no write/list role and no blanket access to Pulumi state.
Verify chosen IAM expressions and lookup behavior against current provider documentation before
implementation; offline tests do not establish provider enforcement.

M2 adds `cli/nagarectl/src/Nagare/Inventory/Store/Service.hs`. `ServiceStoreConfig` identifies
context, project, store URL and explicit credential source. `openServiceStore` creates a
read-only service session whose underlying `InventoryStore` rejects every write before any
request, validates format/binding, and supplies a fresh ownership-and-head action to the shared
recorded reader. Ownership checks and object reads share a deadline supplied by the caller.
Use the gogol implementation through an explicit read-only transport policy: exact object GET,
no listing fallback after 404, no initialization, generation-pinned downloads, cancellation-safe
resource cleanup. Missing head/format/referenced scopes are typed failures, not an empty store.

Reuse the manager and a synchronized expiring-token source; refresh once for simultaneous
requests, retry a provider-auth rejection at most once within the remaining deadline, and
propagate persistent failure. Fake clocks and token providers exercise expiry and refresh
failure without sleeps. Never catch asynchronous cancellation as an ordinary IO error or hold
a shared-cache lock across abandoned work. A permanently unavailable credential must not start
one refresh storm per waiting request.

The store layer returns typed errors independent of HTTP. EP-192 owns the shared problem catalog;
EP-197 maps service errors to sanitized `store_unavailable`, `store_timeout`, `store_invalid`
or `store_credentials_unavailable`. Service credentials do not tell a browser to run
`gcloud auth login`; that remedy belongs to the operator CLI's `reauthentication_required`.
This removes EP-196's undeclared build dependency on EP-192 while keeping the catalog integration.

M3 declares IAM and delivery in `infra/pulumi`, with reviewed scope and preview. Do not assume
an existing deployment's `platform transition` automatically applies Pulumi account/bucket
changes: EP-198 explicitly reviews/applies the infrastructure prerequisites before the API scope.


## Validation and Acceptance

Fake GCS/token tests cover wrong/unreadable bucket owner, wrong canonical binding, missing format,
missing head, missing scope, token expiry under concurrent reads and failed refresh. Record the
exact HTTP calls and assert zero list/write calls, including error paths. A write attempt fails
before network IO. Test foreign-prefix and sibling Pulumi-object requests fail at the wrapper;
EP-198 also proves actual IAM refusal without relying on that wrapper. EP-197's hung-provider
fixture supplies the total request-deadline proof. Test cached immutable bytes cannot bypass
fresh head/ownership failure. Run the focused `nagarectl-test` cases and required style/fast gates.
The public remote latency/native IAM evidence belongs to EP-198, not to this offline milestone.


## Interfaces and Dependencies

`openServiceStore` returns a service session containing the read-only `InventoryStore`, a
cancellable fresh ownership/head action and lifecycle cleanup. EP-193's recorded-reader
constructor accepts this head action; local callers use the ordinary checked `readHead` path.
Service construction never exposes writable ObjectOps. EP-196 owns transport/credential behavior
and typed store errors, EP-193 owns snapshot validation/hydration, EP-197 owns HTTP mappings and
request budgets, EP-198 owns secret mounts, writable temp/cache mounts and native permission proof.
No hard dependency on EP-192 is required to build the reader.

Provider constraints checked during validation: [Cloud Storage IAM conditions](https://docs.cloud.google.com/storage/docs/access-control/iam#conditions)
explain why `resource.name` cannot confine object listing, and [Cloud Storage permissions](https://docs.cloud.google.com/storage/docs/access-control/iam-permissions)
distinguish object GET from bucket metadata. Verify uniform bucket-level access and inherited
bindings in M1 so another grant/ACL does not defeat the intended confinement.


## Outcomes & Retrospective

The identity/session design is specified; implementation, provider IAM enforcement and native
credential isolation are not yet proven.
