---
id: 236
slug: expose-installed-platform-host-component-and-database-versions
title: "Expose installed platform, host, component, and database versions"
kind: exec-plan
created_at: 2026-10-31T15:00:35Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-31T15:00:35Z
---


# Expose installed platform, host, component, and database versions

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record implementation friction with `agents/skills/exec-plan/record-friction.ts` and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


Implement [IR-38](../improvement-requests/expose-installed-platform-host-and-engine-versions.md). An operator will request `GET /v1/platform/versions` and see the installed Nagare release separately from the serving API build, the host operating system and Kubernetes versions, platform component versions, and declared versus running database engine versions. Each fact identifies its source and collection time. An unavailable source leaves a null value and a safe reason while other facts remain available.

The existing `GET /v1/platform/version` retains its binary-only meaning. Consumers such as `mori://tan/tan-ng-labs` can adopt the new contract without receiving Kubernetes or database credentials. This plan creates the endpoint, its observation producer, local/cloud delivery, tests, and documentation. It does not upgrade the consumer portal or publish a platform release.

## Progress


- [ ] M1: A versioned document and fixture-backed HTTP endpoint demonstrate installed/build skew, partial results, and unchanged existing API behavior.
- [ ] M2: A context-bound collector publishes a sanitized snapshot and the real API reads it, first for installed identity, then for host, components, and every managed database server.
- [ ] M3: Local and cloud deployments deliver and refresh snapshots while preserving the API's restricted credentials and permission boundary.
- [ ] M4: Adversarial tests, generated contract, and local/cloud comparisons satisfy all five IR acceptance criteria; operational documentation and ADR updates are complete.

## Surprises & Discoveries


## Decision Log


2026-10-31: Keep collection outside the HTTP service. The service currently has no Kubernetes token or database access, and its dedicated cloud identity cannot read private native inventory bytes. A sanitized observation snapshot preserves this boundary. This deliberately extends ADR 22's recorded-reader architecture with an observation producer and an exact additional readable object; record the amendment during implementation.

2026-10-31: Use an additive plural endpoint and a separately stored observation snapshot. Do not change `VersionInfo`, the accepted inventory head, or convergence status merely because observations changed. A sample is historical evidence, not a claim of current health. Explicit collection times make that distinction visible.

2026-10-31: Include `nagarectl platform versions` and `nagarectl platform versions refresh` as the reader and producer controls. Although the IR makes CLI presentation optional, a bounded, repeatable refresh command is needed to operate and validate this recorded-observation design. Successful platform bootstrap and inventory application also attempt refresh; collection failure must not retroactively fail an accepted apply.

## Outcomes & Retrospective


## Context and Orientation


An inventory scope is Nagare's named ownership boundary, such as a platform component or database server. An accepted inventory head identifies the reviewed declarations currently installed; declarations describe intent, and observations describe what a provider reported at a particular time. A payload is the immutable set of release assets. Its payload ID is distinct from its schema version.

`cli/nagare-contract/src/Nagare/Contract/V1.hs` defines public JSON records including `VersionInfo`. `cli/nagare-api/src/Nagare/Api/Platform/Routes.hs` presently has only `version`. `cli/nagare-api-server/src/Nagare/Api/Server/App.hs` serves the build from `AppConfig.version`. `cli/nagare-api-server/src/Nagare/Api/Server/Serve.hs` supplies checked inventory reads, deadlines, and representation caches; its `serveState` fails the whole response on head failure and therefore cannot directly implement the partial-source behavior required here. `cli/nagare-api/src/Nagare/Api/Response.hs` owns typed HTTP responses and validators. `cli/nagare-api/app/OpenApi.hs` generates `docs/api/openapi.json`.

`cli/nagarectl/src/Nagare/Platform/Status.hs` contains existing release identity parsers and comparisons. Its `ReleaseIdentity` omits installation time and payload ID. The modern stamp producer, `bootstrapMarkerValue` in `cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs`, adds `payloadId` and a composition digest. `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` preserves accepted installation time. The older `cluster/bootstrap/platform-version.yaml.tmpl` contains version, revision, payload schema, and installation time but no payload ID. Read actual stamp fields; older stamps must return an unavailable payload ID rather than substituting the schema or current CLI payload.

`cli/nagarectl/src/Nagare/Inventory/Recorded.hs` reads checked inventory. `cli/nagarectl/src/Nagare/Inventory/Store.hs` and `cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs` provide local/object storage operations. `cli/nagarectl/src/Nagare/Inventory/Store/Service.hs` implements exact cloud reads with bucket ownership checks using a dedicated reader account. Its permissions cover only inventory format, head, and scopes. `cluster/bootstrap/admin-api/admin-api-local.yaml.tmpl` mounts inventory read-only and disables Kubernetes token mounting; its cloud counterpart uses dedicated storage credentials. The new endpoint must preserve both constraints.

`cli/nagarectl/src/Nagare/Inventory/Database.hs` binds database declarations to native Kubernetes members; `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` owns engine/version declarations. `cli/nagarectl/src/Nagare/Database/Connection.hs` and `cli/nagarectl/src/Nagare/Database/Secret.hs` are existing connection/credential boundaries to inspect before adding an engine probe. `cli/nagarectl/src/Nagare/Inventory/Components/` contains the Auth, AdminApi, Upstream, Observability, ObservabilityExtras, and other component compilers. Their accepted resources, rather than the serving binary's current pins, determine installed component inventory. `cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs` supplies context-bound cluster access. `nixos/modules/nagare-host.nix` is the host module integration point.

Relevant ADRs consulted are [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md), which separates build, payload, context, host, and installed identities and treats unknown identities explicitly; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), particularly its 2026-10-16 recorded-reader amendment, requiring context binding, bounded reads, exact object permissions, and no private native payloads in public DTOs; [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md), distinguishing physical database servers from application database tenants; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md), preserving wire contracts while applying the Haskell record/Prelude standard; and [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), requiring fault-injected interpreter tests before native validation.

## Plan of Work


### M1 — Define and serve the partial document


Add version records in a new `cli/nagare-contract/src/Nagare/Contract/Versions.hs`, re-exporting as appropriate from V1, and register modules in the Cabal files. Add `versions` to `PlatformRoutes` and a new `cli/nagare-api-server/src/Nagare/Api/Platform/Handler.hs`. Inject a snapshot-reader action into the server environment; fixtures supply this action before native integration. The endpoint is a read-only GET with HEAD support and existing authentication through the gateway. Keep all existing routes and their cache behavior unchanged.

The top-level document has `schemaVersion: 1`, context/project identity, `collectedAt`, `inventoryRevision`, `nagare`, `hosts`, `components`, and `databases`. Version facts use a common explicit JSON envelope: `value`, `sourceKind` (`recorded` or `observed`), `source`, `observedAt`, and `reason`. Null facts always have a stable reason code; do not include raw exceptions. `observedAt` is the source read/attempt time, never HTTP request time. Known installation timestamps remain a distinct fact. The serving-build facts are recorded build metadata, accompanied by a stable process-start read time. Identity keys and structural fields need no fact wrapper.

`nagare` contains `installed` (version, revision, payloadId, installedAt), `servingBuild` (existing VersionInfo), optional host/context pin facts, and a three-state comparison `match`, `different`, or `unknown`. Compare version and available revision; unequal known fields mean different, equal versions with missing revision evidence mean unknown, and complete equal evidence means match. Return the compared fields so callers can explain skew. Do not treat matching version strings alone as proof of equal builds.

Host entries are keyed by node name and UID and expose NixOS release, codename, nixpkgs revision, OS image, kernel, and Kubernetes/k3s version. Database entries are keyed by owner scope, namespace, and server name, with engine, declared engine version, declared image, and per-pod/container observations containing UID, resolved image digest, and reported engine version. Component entries expose owner scope, component name, declared version/chart version/image, and per-workload/container observed images/digests. Arrays preserve multiple rollout versions rather than selecting an arbitrary pod. Stable sorting keeps representations deterministic.

A source failure must yield HTTP 200 with partial facts. Missing/corrupt/denied entire snapshots still return serving-build facts and explicit section availability envelopes with null values and reason codes, distinguishing unreadable inventory from an empty component/database list. Authentication and invalid HTTP requests retain normal problem responses. Initially use `Cache-Control: no-store` on this endpoint and no conditional response cache; this avoids mixing mutable observation snapshots with inventory-head validators. Document the choice in OpenAPI and keep existing endpoints' conditional requests intact.

Acceptance: fixture HTTP tests demonstrate old serving build/new installed release, matching identities, unknown identities, missing snapshots, per-field failure, multi-pod versions, and GET/HEAD behavior. The generated OpenAPI describes nullable values and the distinction between recorded intent and observations.

### M2 — Produce a snapshot and exercise the complete path


Add `cli/nagarectl/src/Nagare/Platform/Versions.hs` for pure assembly and `cli/nagarectl/src/Nagare/Platform/Versions/Store.hs` for snapshot persistence. Add an injected observation interface and its native implementation in `cli/nagarectl/app/Nagare/Cli/Platform/Versions.hs`, wired through `cli/nagarectl/app/Nagare/Cli/Commands/Platform.hs`. Keep provider IO out of pure projection code. Before expanding all collectors, prove stamp → collector → persisted snapshot → real API response with a filesystem fixture, then with the existing cloud object-operation test interpreter.

Persist a single bounded sanitized document at `versions/latest.json` under the context inventory root. Include context/project binding, schema, collection start/end times, and the captured inventory head revision. Publish atomically by rename for files or conditional object replacement for cloud storage. Concurrent refreshes must not replace a newer completed observation with an older one. Capture the accepted head once; if it changes while collecting, discard and retry once, then publish only an explicitly unavailable/inconsistent collection result rather than attributing observations to the wrong declarations. Snapshot writes never alter the accepted head, journal, or convergence facts.

Read the installed stamp directly from `nagare-system/nagare-platform-version`. Read node `status.nodeInfo` for OS image, kernel, and kubelet version. For NixOS-specific facts use the target host's `/etc/os-release` and an allowlisted host identity file emitted by `nixos/modules/nagare-host.nix` from evaluated host release/nixpkgs metadata. Do not inspect the API container's OS or infer the host's nixpkgs revision from the collector's flake. Never traverse `/nix/store`. A non-NixOS local substrate reports observed OS/kernel/Kubernetes and null NixOS-specific values with `not_applicable`; legacy hosts without the identity file report `not_recorded` for unavailable revision fields.

Enumerate database servers from accepted declarations and owned native resources, including en-db, shomei-db, and shared application servers. Do not emit one server per application database tenant. Preserve declared engine version literally, including moving tags such as `18`. Obtain current image references and `imageID` digests from matched owned pod status, recording pod UID. Run only a fixed read-only `SELECT version()` through the existing authenticated engine/cluster boundaries for PostgreSQL and ClickHouse. Query each reported running server instance consistently; if identity changes between probe and status read, return `identity_changed` rather than attaching a version to another instance. Credentials remain internal, never serialized or placed in diagnostic strings. A stopped server retains its declared facts and null observations.

Enumerate installed platform scopes and their accepted resources, including en, Shōmei, nagare-access, admin API, Knative Serving and ingress, cert-manager, observability releases, and enabled optional platform components. Derive declared pins from the accepted payload/resource inputs, chart versions from installed Helm release metadata where applicable, and observed digests from the matching workloads. Do not use current checkout pins as installed evidence. Disabled components are omitted; installed but unreadable components remain with reasons. Detect unsupported resource shapes and report them explicitly rather than silently dropping installed components.

Every provider read has a timeout and bounded output; use a 60-second overall collection budget, five-second per-probe default, and at most four concurrent probes. Remaining unattempted facts become `collection_deadline` results. HTTP only reads a size-bounded snapshot under its existing ten-second deadline. A failed source cannot cancel successful unrelated probes. Reject oversized/malformed snapshots safely. Test cancellation without swallowing asynchronous exceptions.

Acceptance: tests run the real assembler and writer/reader with missing stamp fields, denied node reads, stopped databases, changed pod UIDs, mixed rollouts, failed publication, concurrent refresh, and changed inventory heads. One PostgreSQL and one ClickHouse fixture show distinct declared and observed versions through the real HTTP route.

### M3 — Deliver and refresh in both environments


Extend the service-store reader and cloud IAM declaration at the existing inventory reader grant construction to allow exactly `versions/latest.json`, retaining the prohibition on listing, writes, private native bytes, journals, and other contexts. Locate the grant producer by searching the repository for its `head.json` and `scopes/` permission expressions. Reuse the cloud session's bucket ownership check for every snapshot read, even if head reading fails; a failed ownership check returns unavailable snapshot facts. The local deployment already mounts the inventory directory; ensure atomic snapshot replacement stays visible through that mount. No API Kubernetes token, host mount, database Secret, or broader egress is added.

Wire best-effort refresh after successful platform bootstrap and accepted inventory application, including transitions that change database or component versions. The public refresh command provides a current sample whenever an operator needs one, including after a moving image tag changes without a Nagare apply. Its output reports snapshot publication and partial-source counts, without secret details. No scheduler or freshness SLA is introduced: docs explicitly say observations are as of collection, and show the refresh command. Collection publication failures warn separately and retain the prior snapshot; subsequent reads preserve its old timestamp. Never rewrite an old sample's time as fresh.

Acceptance: local API serves a newly published snapshot without restarting. Cloud reader can read the exact snapshot and still cannot read native objects, another context, or write/list. Refresh failure cannot change a successful apply outcome. Gateway authentication and network restrictions continue to pass existing tests. Amend ADR 22 for the exact observation object and producer boundary, and ADR 6 for reporting installed/build skew without changing mutation compatibility policy.

### M4 — Prove the IR and document operation


Extend `cli/nagare-api-server/test/Main.hs` and the existing fixture/document/serve tests, `cli/nagare-api-server/hurl/platform.hurl`, and add `cli/nagarectl/test/PlatformVersionsSpec.hs` to the CLI test suite. Add an executable acceptance script `scripts/check-platform-versions.sh` that takes an authenticated API URL and expected fixture/context evidence, compares versions without printing credentials, and reports AC-1 through AC-5. Add `docs/api/samples/platform-versions.json` and update `docs/api/README.md` with source semantics, refresh, missing sources, rollout arrays, and legacy behavior.

Run native comparisons on a local harness and an explicitly selected cloud context after interpreter tests pass. Use the repository's existing context selection and gateway authentication instructions; record the actual context, commands, timestamp, and sanitized results here. Do not provision a new cloud context or upgrade a consumer merely to complete evidence. If a required environment is unavailable, leave its milestone evidence outstanding rather than claiming acceptance. Complete the ADR distillation and friction triage before marking M4 complete.

## Concrete Steps


Run commands from the repository root unless specified. Initial focused verification uses the existing development environment:

```bash
cabal build --project-dir=cli/nagarectl nagare-contract nagare-api exe:nagare-api-server exe:nagarectl
cabal test --project-dir=cli/nagarectl nagare-api-server-test --test-show-details=direct
cabal test --project-dir=cli/nagarectl nagarectl-test --test-options='-p PlatformVersions' --test-show-details=direct
cabal run --project-dir=cli/nagarectl nagare-api-openapi
just api-hurl
```

Name the new test group `PlatformVersions` so the focused selector runs it. Expect all selected tests to pass, Hurl to include the new route, and generated `docs/api/openapi.json` to contain `/v1/platform/versions`. Regeneration twice must produce no additional diff. Use the same developer shell as the existing project if these tools are not on PATH; do not inspect Nix store contents.

After M2, in an already selected test context:

```bash
cabal run --project-dir=cli/nagarectl nagarectl -- platform versions refresh
cabal run --project-dir=cli/nagarectl nagarectl -- platform versions --json
```

The refresh prints a published observation timestamp and unavailable-source count. The reader prints the same recorded sections as HTTP, with a separately labeled serving-build section when reading through the API; a CLI-only read must not pretend that its own binary is the serving API build. For endpoint verification, extend the existing Hurl fixture runner instead of embedding credentials in shell history. `just api-hurl` serves a fresh fixture on loopback port 18085 and tears it down automatically.

At meaningful implementation boundaries commit with Conventional Commit messages and `ExecPlan: docs/plans/236-expose-installed-platform-host-component-and-database-versions.md`. Run the repository landing gate on the resulting committed revision:

```bash
just gate-fast HEAD
```

Record concise results and any remaining native acceptance gaps. Creation of this plan alone does not require building the codebase.

## Validation and Acceptance


AC-1: fixture the installed stamp at a newer version than `AppConfig.version`; both remain visible and comparison is different. Fully matching version/revision is match; missing evidence is unknown. Installation time and payload ID come from the stamp. Legacy missing fields are explicit nulls.

AC-2: compare node observations with `kubectl get nodes -o json` through the selected context and NixOS facts with that node's `/etc/os-release` and activation identity file. Verify NixOS facts on the cloud host and appropriate not-applicable behavior on a non-NixOS local harness. Never substitute container OS facts.

AC-3: use PostgreSQL declared as `18` and ClickHouse declared at an exact version. Compare returned running engine strings with independent authenticated `SELECT version()` results and digests with pod `imageID`. Include platform databases and shared servers, with no duplicate entries for tenants. Stop or deny one fixture server and verify that declared values and unrelated server observations remain available.

AC-4: compare the full installed component list against accepted component scopes, the installed release assets, Helm releases, and workload images on both environments. Exercise optional-component absence and mixed rollout digests. Demonstrate that a newer serving binary does not relabel older installed components with its own pins.

AC-5: deny one source, deny snapshot access, corrupt a snapshot, and exceed a probe deadline. HTTP still returns partial documents with source/time and stable reasons. Test JSON and generated schema with real nulls, and plant recognizable secret/connection-string sentinels in provider errors and private native inputs; assert none appear in response bodies, snapshots, or logs. Verify reader IAM negatives, unauthorized gateway requests, unchanged old-route validators, and no additional HTTP-triggered provider calls. Measure that the overall request deadline bounds snapshot retrieval.

## Idempotence and Recovery


Reads and SQL probes are non-mutating. Refresh replaces only the observation document after complete assembly; it never updates installed stamps or accepted inventory state. Failed publication leaves the previous complete document, and repeating refresh is safe. Conditional cloud writes and local atomic replacement prevent torn documents and older concurrent collections overwriting newer samples. Removing or losing the snapshot yields explicit unavailable facts until refresh, without impairing old endpoints. Reverting the new route/collector leaves accepted inventory intact. Keep the narrow cloud permission and any host metadata addition in reviewed deployment changes, and preserve operator files during host activation.

## Interfaces and Dependencies


Use the existing Aeson, Servant, OpenAPI, storage, and cluster facilities; no dependency version change is planned. Before introducing or changing a dependency API, locate its source with `mori registry search`, `mori registry show --full`, and `mori registry docs`, and read it on disk. Before changing bounds or pins, verify current releases against the authoritative registry and upstream tags. Never search `/` or `/nix/store`.

The new contract module owns public data only. The collector owns provider access and sanitization. The snapshot store owns context binding, schema/size validation, atomic publication, and observation ordering. The API handler reads one snapshot, combines it with the actual API build, and renders partial availability; it never opens a database connection or invokes kubectl. Inject time and provider/storage operations for deterministic tests. Preserve the original recorded reader's immutable-scope cache and request invariants. The observation snapshot is a separate versioned format, so unsupported future versions return a safe reason without breaking existing inventory inspection.
