---
id: 251
slug: keep-a-local-context-s-inventory-store-in-its-in-cluster-object-store-so-an-in-cluster-deployer-can-apply
title: "Keep a local context's inventory store in its in-cluster object store so an in-cluster deployer can apply"
kind: exec-plan
created_at: 2026-11-07T17:05:29Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T17:05:29Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T03:56:33Z
      verdict: "changes-requested"
      note: "Assign scoped local object-store credential provisioning, bundle integration, and revocation to explicit deliverables shared with EP-248."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:04:19Z
      mode: "update"
      note: "Define private S3 credential-file input and hand scoped identity lifecycle and bundle acceptance to EP-248."
---

# Keep a local context's inventory store in its in-cluster object store so an in-cluster deployer can apply

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

A local context (`mode=local`, a k3d cluster on the operator's machine) can keep its inventory store in the cluster's
own object store instead of a private directory on the operator's machine. Afterwards a program running in a pod of
that cluster, such as a delegated deployer, can plan and apply reviewed changes against the same store the operator
uses, with the same conditional-write guarantees a cloud context gets from GCS. The operator's own `nagarectl` keeps
working against it from the workstation.

This is what lets [UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md) be
confirmed on a local context with the deployer hosted in the cluster, as the end-to-end gate in
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
requires. It is opt-in: a local context that does not ask for it keeps its filesystem store, unchanged.


## Progress

Each deliverable passes on the evidence it names. Interpreter evidence comes first, a native local run only confirms
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, the semantics prototype: a short experiment against the pinned local object store image proves, or disproves,
  that `PutObject` with `If-None-Match: *` refuses an existing key and `If-Match: <etag>` refuses a changed object, under
  two racing writers, and that a refused write leaves the object untouched. It is repeated for RustFS if
  [the RustFS request](../improvement-requests/migrate-from-minio-to-rustfs.md) has been accepted by then. Keep or
  discard: keep the S3 transport only if both conditions hold; otherwise record the failure and stop this plan.
  Evidence: the experiment script and its transcript under `docs/audits/`.
- [ ] D2, the transport: a new `s3ObjectOps` builds an `ObjectOps` (`cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs`)
  over the S3 API with the conditions above, classifying every response as found, absent, refused or uncertain the
  way `gcloudObjectOps` does, and never treating a failed read or list as absence. Evidence: the existing object-store
  property tests run against an in-memory S3 fake that implements ETag conditions, including lost acknowledgements and
  a racing writer.
- [ ] D3, the generation: `Generation` stops assuming an integer. S3 ETags are opaque strings, so the store compares an
  opaque token supplied by the transport; GCS keeps rendering its integer generation. No persisted head, review or
  journal byte changes: the generation is a transport observation, never stored. Evidence: the GCS transport tests pass
  unchanged, and a test proves no stored object's bytes differ between the two transports for the same history.
- [ ] D4, the store kind: `InventoryStoreKind` (`cli/nagarectl/src/Nagare/Target/Kinds.hs`) gains `object`, valid only for
  a local context and only with `NAGARE_INVENTORY_STORE_URL` naming a loopback or in-cluster S3 endpoint and bucket
  prefix; `effectiveInventoryStore` (`cli/nagarectl/src/Nagare/Target.hs`) stops forcing every local context to the
  filesystem and honours it. A cloud context refuses `object`, so the GCP guardrail and the GCS path are untouched.
  Credentials come from the existing local object-store Secret named by `minioCredentialsSecret`, read once and held in
  memory for an operator, or from a private JSON file named by `NAGARE_INVENTORY_STORE_CREDENTIALS_FILE`
  (fields `accessKeyId` and `secretAccessKey`), or from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for an
  in-cluster client. Refuse simultaneous file and environment credentials. A deployer must supply explicit scoped
  credentials and never falls back to reading the administrator Secret. Evidence:
  target-resolution tests for each kind and mode, including the refusals.
- [ ] D5, reaching it from the workstation: the operator's `nagarectl` reaches the in-cluster endpoint through a
  port-forward it opens and closes itself, the way reviewed access grants reach En, so no new host port is published.
  An in-cluster client uses the Service address directly. Evidence: a fake-command test of the forward's lifecycle,
  including a forward that dies mid-transaction leaving the transaction resumable.
- [ ] D6, moving an existing local context: `nagarectl inventory store migrate --to object` moves a quiescent filesystem store
  to the object store, and `--to local` moves it back, through the existing copy, tombstone, disable and activate sequence in
  `cli/nagarectl/src/Nagare/Inventory/Store/Migrate.hs` and `TargetMigration.hs`. Evidence: the existing migration tests
  extended to the new pair, interrupted after every step and resumed.
- [ ] D7, the local confirmation: on a fresh local context with the object store, the operator deploys a fixture app
  from the workstation, then a Pod in the cluster holding the object-store credential and the fixture Kubernetes credential applies a second change to
  the same context, then the operator's next saved review is refused as stale and succeeds after re-planning. Evidence:
  an audit file under `docs/audits/` with the transcript.
- [ ] D8, docs: `docs/user/local-development.md` and `docs/user/resource-inventory.md` describe the object store for
  local contexts, when to use it, and how to migrate. Evidence: the linked pages.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep transport and credential loading here; EP-248 owns scoped identities, policy and the bundle-only integration gate.
  Rationale: EP-251 remains independently testable with fixture credentials while EP-248 cannot complete with a workstation-only fallback.
  Date: 2026-11-08


- Decision: Use the S3 API with ETag conditions as a second `ObjectOps` transport, opt-in for local contexts only.
  Rationale: the store already isolates its transport behind `ObjectOps`, and its correctness rests on conditional
  create and conditional replace, which S3-compatible stores now offer. Rejected: a shared filesystem mounted into pods
  (no atomic conditional replace across machines and a host-path mount into the deployer); running the deployer on the
  operator's machine only (EP-248's fallback, which leaves "hosted on the installation" unproved locally).
  Date: 2026-11-07

- Decision: Cloud contexts keep GCS and cannot select `object`.
  Rationale: the cloud path, its guardrail and its ownership checks are proved; widening it is not needed for UC-4.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** The inventory store is where a context keeps its reviewed state: `format.json`, a single head object naming
the current journal position and any active transaction, immutable journal and review objects, and scope snapshots. A
conditional write replaces an object only if it has not changed since it was read; the whole store's safety against two
writers rests on the head being replaced that way (`replaceHeadIfGenerationMatches` in
`cli/nagarectl/src/Nagare/Inventory/Store.hs`). A transport is the code that performs object reads and writes for a
backend.

**Today.** `Backend` in `cli/nagarectl/src/Nagare/Inventory/Store.hs` has a filesystem, an in-memory and an object
backend. The object backend takes an `ObjectOps` record (get, immutable get, batch get, conditional put, list, retry
pause) from `cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs`; GCS is implemented by `gcloudObjectOps` there and
by the Gogol client in `cli/nagarectl/src/Nagare/Inventory/Store/Gogol.hs` and `Remote.hs`. `PutCondition` is
`IfAbsent` or `IfGenerationMatches Generation`, and `Generation` wraps an `Integer`. A local context always resolves to
the filesystem store under `$XDG_STATE_HOME/nagare/<context>/inventory` (`effectiveInventoryStore`,
`openTargetStoreReadOnly` in `cli/nagarectl/src/Nagare/Inventory/Store/Target.hs`), which no Pod can reach.

A local context already runs an S3-compatible object store in `nagare-system` for backups and data movement
(`NAGARE_LOCAL_OBJECT_STORE`, `just local-minio`, `cluster/local/minio/minio.yaml`, the credentials Secret named by
`minioCredentialsSecret` in `cli/nagarectl/src/Nagare/Target.hs`). This plan stores the inventory in a separate bucket
or prefix of that store.

**Related plans.** [EP-248](248-issue-least-privilege-credentials-to-a-delegated-deployer.md) issues the deployer's
bundle and owns scoped policy creation, key issuance, rotation and revocation in its D10. This plan owns only
the transport, credential-file reader and endpoint selection. EP-248 hard-depends on this plan and must prove
a bundle-only in-cluster apply and prefix isolation; this plan's D7 independently uses fixture credentials.
The bundle uses an object-store credential limited to the inventory prefix instead of `NAGARE_INVENTORY_STORE_ROOT`. EP-248's workstation-only local deployer remains for contexts that do
not opt in.

**ADRs.** [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) keeps one executor and
one head per context; this plan changes where the head lives, not that rule.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) asks for remote,
conditional state; this extends that to local contexts that want it.


## Plan of Work

Start with D1, because everything depends on the object store honouring conditions; it is a script, not product code.
Then generalize `Generation` (D3) with the GCS tests as the guard, add `s3ObjectOps` (D2) with an in-memory S3 fake
driven by the existing store property tests, then the store kind and resolution (D4), the workstation forward (D5) and
migration (D6). Sign requests with AWS Signature Version 4; prefer an existing Haskell S3 client already in the package
set (check with `mori registry search` before adding one) and keep it behind `ObjectOps`, so nothing above the transport
changes.


## Validation

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
just haskell-style-check
just gate-fast
cabal test nagarectl-test --test-options='-p /Store/'
```

D7 runs on a disposable local context created for it and deleted afterwards.


## Interfaces

`s3ObjectOps :: S3Endpoint -> S3Credentials -> Text -> IO ObjectOps` in a new module
`cli/nagarectl/src/Nagare/Inventory/Store/S3.hs`; `InventoryStoreObject` added to `InventoryStoreKind`; `Generation`
becomes an opaque transport token with the same `Eq`. `NAGARE_INVENTORY_STORE_CREDENTIALS_FILE` names a
private JSON object with `accessKeyId` and `secretAccessKey`, read as data and never logged. File credentials
select the same ObjectOps path as environment credentials; endpoint and prefix stay in the context. No contract document changes.

Revision (2026-11-08): applied the MasterPlan 33 review findings to the interfaces, acceptance and ownership described above.
