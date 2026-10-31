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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T15:23:32Z
      verdict: "changes-requested"
      note: "Host facts had no delivery channel, DB probe boundary misnamed and Redis omitted, no-store contradicts the ETag contract, unbounded post-apply refresh, new acceptance script, per-commit gate missing; applied in the same session"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T15:26:37Z
      mode: "update"
      note: "Host identity recorded via k3s manifest ConfigMap; ETag/304 kept; scoped 20s post-apply refresh; Redis probe; no Helm Secret reads; acceptance script dropped; contract read-document shape; exact files and per-commit gate named"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-31T15:38:53Z
      mode: "implement"
      note: "M1 contract and endpoint implemented"
---


# Expose installed platform, host, component, and database versions

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record implementation friction with `agents/skills/exec-plan/record-friction.ts` and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


Implement [IR-38](../improvement-requests/expose-installed-platform-host-and-engine-versions.md). After this plan an operator, or the tan-ng-labs portal, requests `GET /v1/platform/versions` on the admin API and receives one document with four sections: the Nagare release the context has installed (from the platform-version stamp) beside the release the serving admin API binary was built from, with a three-state comparison; the host's NixOS release, codename and nixpkgs revision beside its running kernel and k3s versions; every installed platform component's declared version or image beside the image digests its workloads actually run; and every managed database server's declared engine version beside the version the running server reports. Every value says whether it is recorded inventory state or an observation, names its source and carries the time it was read. A source that cannot be read leaves a null value with a stable reason code while the rest of the document is still served.

The existing `GET /v1/platform/version` keeps its meaning: the serving binary only. Consumers such as `mori://tan/tan-ng-labs` adopt the new document without receiving Kubernetes or database credentials, and read it with the same ETag and `If-None-Match` discipline as every other admin API route. This plan creates the contract, the endpoint, the collector that produces the observation snapshot, its delivery in local and cloud contexts, the tests and the documentation. It does not upgrade the consumer portal and does not publish a platform release.

## Progress


- [x] M1: A versioned contract and a fixture-backed HTTP endpoint demonstrate installed/serving skew, partial results with reason codes, conditional 304s, and unchanged behaviour of every existing route. (2026-10-31) `nagare-api-server-test`: 30 of 30 pass, including the 8 `platform versions (EP-236)` wire tests (different/match/unknown, legacy `payloadId` `not_recorded`, mixed rollout, missing/invalid/oversized/foreign/unavailable snapshot as 200, 304 and HEAD, deadline-bounded read, `/v1/platform/version` unchanged); `nagare-api-openapi` regenerated twice with the same output.
- [x] M2: A context-bound collector publishes a sanitized snapshot that the real API reads, proven end to end on the installed identity first, then extended to host, components and every managed database server (PostgreSQL, ClickHouse and Redis). (2026-10-31) `platform versions (EP-236)` in `nagarectl-test`: 13 of 13 pass (complete collection; mixed rollout and vendored chart version; denied nodes; missing identity ConfigMap and non-NixOS node; stopped server; replaced pod `identity_changed`; hung probe `collection_deadline` within a 0.3 s budget; failed engine and denied namespace; head changed once and repeatedly; secret sentinels; local atomic, newer-kept and concurrent publication; remote generation-conditional publication; schema and size refusals). `nagare-api-server-test` 31 of 31, including a collected snapshot published to a filesystem store and served by the real route with PostgreSQL, ClickHouse and Redis versions. The loopback cloud-reader proof moves to M3 with `freshObject`.
- [x] M3: Local and cloud deployments deliver and refresh snapshots while the API keeps its restricted credentials and exact-object grant; the host module records its identity into the cluster at activation. (2026-10-31) `adminApiReaderResources.test.js` OK with exactly `versions/latest.json` added and `native/`, `reviews/`, `journal/` and any wider `versions` prefix refused; `Admin API service store` loopback test reads the snapshot through `freshObject` with exact GETs only and refuses a foreign owner; the local API reads the object per request (no restart), proven by the filesystem end-to-end wire test; `nixos#nagare-01` evaluates `services.k3s.manifests.nagare-host-identity` with release 26.11, code name Zokor and revision `eaad0894…`; a converged `inventory apply` or `platform bootstrap apply` whose review touches a `platform:` or `database:` resource refreshes under 20 s and prints one `versions:` line on stderr, and any failure there is caught and reported without changing the outcome. Release transitions land through `inventory apply`, so they need no separate hook. ADR 22 and ADR 6 amended. The real host picks up the ConfigMap at its next `just host-switch`.
- [ ] M4: Adversarial interpreter tests, the generated contract, golden sample and native local/cloud comparisons satisfy AC-1 to AC-5; `docs/api/README.md`, ADR 6 and ADR 22 are updated.

## Surprises & Discoveries


## Decision Log


2026-10-31: Keep collection outside the HTTP service. The service has no Kubernetes token or database access, and its dedicated cloud identity cannot read private native inventory bytes. A sanitized observation snapshot preserves this boundary. This deliberately extends ADR 22's recorded-reader architecture with an observation producer and one additional exactly named readable object; record the amendment during implementation.

2026-10-31: Use an additive plural endpoint and a separately stored observation snapshot. Do not change `VersionInfo`, the accepted inventory head or convergence status because observations changed. A sample is historical evidence, not a claim of current health; explicit collection times make that visible.

2026-10-31: Include `nagarectl platform versions` and `nagarectl platform versions refresh` as the reader and producer controls. The IR makes CLI presentation optional, but a bounded, repeatable refresh command is needed to operate and validate a recorded-observation design.

2026-10-31 (review): Host facts are recorded into the cluster at activation, not read over SSH. The collector has cluster access through the command's cluster session, not host filesystem access. The host module therefore emits a `nagare-host-identity` ConfigMap through `services.k3s.manifests` (present in the host's pinned nixpkgs, 26.11 at `eaad0894`) carrying the evaluated NixOS release, codename, version and nixpkgs revision; the running kernel and k3s versions come from the node's `status.nodeInfo`. A host activated before this change reports `not_recorded` until its next `just host-switch`.

2026-10-31 (review): The new route keeps the admin API's cache contract. `docs/api/README.md` promises a strong ETag, `Cache-Control: private, no-cache` and a bodyless 304 on every 200; the earlier `no-store` choice broke that for one route and made a polling consumer re-download the body each time. The route computes its ETag from the exact response bytes per request, as `serveBuild` does, and uses no representation cache because the snapshot is mutable.

2026-10-31 (review): Post-apply refresh is scoped and bounded. A 60-second best-effort refresh after every apply would add up to a minute to every `inventory apply`. After an apply or bootstrap it runs only when the accepted set changed a `platform:` or `database:` scope, under a 20-second budget, and prints one line. The standalone refresh command keeps the 60-second budget.

2026-10-31 (review): Redis servers are in scope. IR AC-3 covers every managed database server and `Engine` has three constructors; the same in-pod execution boundary serves `redis-cli INFO server` as it serves `psql` and `clickhouse-client`.

2026-10-31 (review): Helm release Secrets are not read. Observability charts are vendored and digest-pinned in the accepted declaration, and a Helm release payload embeds rendered values that may carry secrets. Declared chart versions come from the accepted declaration; observed evidence is the workload image digest.

2026-10-31 (review): No acceptance shell script. The Hurl suite, the tasty fixtures and `nagarectl platform versions --json` beside `kubectl get nodes -o json` already prove AC-1 to AC-5; a new script would be one more surface to maintain (operator rule: prefer removing a step to adding one).

2026-10-31 (review): The document follows the contract's read-document shape: `contractVersion: 1`, `document: "platform-versions"`, and a `reason` string whose catalog lives in `docs/api/README.md` so a new reason is an additive catalog entry, as problem codes are, rather than a version-2 enum change.

2026-10-31 (implementation): The provider interface (`VersionProviders`) and the collection loop live in the library module `Nagare.Platform.Versions.Collect`, not in `app/`, because `nagarectl-test` cannot import executable modules; `app/Nagare/Cli/Platform/Versions.hs` holds only the native kubectl and store providers. The pure parsers and section builders are `Nagare.Platform.Versions.Assemble`.

2026-10-31 (implementation): `versions/` is derived observation data, so the store's listing (and therefore export, restore and migration) excludes it; `Nagare.Inventory.Store.observationTransport` is the only new store export. A refresh during a migration cannot break the member comparison, and a restored store starts with `snapshot_missing` until the next refresh.

2026-10-31 (implementation): A component is an accepted Deployment, StatefulSet, DaemonSet or Helm release member of a `platform:` scope; a database server is an accepted StatefulSet of a `database:` scope carrying `nagare.dev/engine`. The declared engine version is the declared image tag, kept literally. A Helm release's declared chart version is the version in its vendored chart archive name (`chartPath`); its pods are those labelled `app.kubernetes.io/instance=<release>`.

## Outcomes & Retrospective


## Context and Orientation


Terms used below. An *inventory scope* is Nagare's named ownership boundary, such as `platform:upstream` or `database:labs-postgres`. The *accepted head* (`head.json` in the context's inventory store) names the reviewed scope revisions currently installed. A *declaration* describes intent and an *observation* describes what a provider reported at a time. A *payload* is the immutable set of release assets; its *payload ID* is distinct from its *payload schema* version. The *stamp* is the ConfigMap `nagare-system/nagare-platform-version` that records which release a cluster has installed. The *snapshot* is the one sanitized JSON object this plan adds to the inventory store at `versions/latest.json`; the *collector* is the `nagarectl` code that produces it. A *fact* is the JSON envelope every reported value uses: `value` (string or null), `sourceKind` (`recorded` or `observed`), `source` (a short description such as `configmap nagare-system/nagare-platform-version`), `observedAt` (when that source was read or the read was attempted; never the HTTP request time) and `reason` (null, or a code from the catalog when `value` is null).

The admin API. `cli/nagare-contract/src/Nagare/Contract/V1.hs` defines the public JSON records including `VersionInfo` (version, platformVersion, revision, tools, contracts). `cli/nagare-api/src/Nagare/Api/Platform/Routes.hs` has only `version`. `cli/nagare-api-server/src/Nagare/Api/Server/App.hs` serves it from `AppConfig.version` through `serveBuild`, and wires the route handlers that live in `cli/nagare-api-server/src/Nagare/Api/{Access,Inventory,Sites}/Handler.hs`. `cli/nagare-api-server/src/Nagare/Api/Server/Serve.hs` owns `Env` (the recorded reader, the build identity, the 10-second request deadline, the representation cache) and `serveState`, which fails the whole response on a head failure and so cannot implement partial results. `cli/nagare-api/src/Nagare/Api/Response.hs` owns the response types (`Build`, `Snapshot`, `IfNoneMatch`, `Encoded`) and `entityTag`-based validators. `cli/nagare-api/app/OpenApi.hs` (executable `nagare-api-openapi`) regenerates `docs/api/openapi.json`; `nagare-api-server-test` fails while the checked-in document differs. The nagare-access gateway admits any path under the admin host's `/v1` prefix (`isApiPath` in `cli/nagare-access/src/Nagare/Access/BackendMap.hs`), so the new route needs no gateway change.

Tests and fixtures. `cli/nagare-api-server/test/Nagare/Api/Server/Test/Fixture.hs` is an in-memory object store that counts reads and can hang or lose an object; `Serve.hs` beside it holds the wire tests (`withServer`). `cli/nagare-api-server/hurl/run.sh` lists the Hurl files it runs, and `just api-hurl` seeds a fixture store through `seedStore` and serves it on `127.0.0.1:18085`. `cli/nagarectl/test/Nagare/Test/Contract.hs` holds `samples`, the golden documents under `docs/api/samples/` with schema conformance and decode round trips. `cli/nagarectl/test/Nagare/Test/Suite.hs` assembles the CLI suite; a new `*Spec.hs` is imported there and registered in the test stanza of `cli/nagarectl/nagarectl.cabal`. `InventoryServiceStoreSpec.hs` points the cloud reader at a loopback server and `InventoryObjectOpsSpec.hs` exercises conditional object operations.

The installed release. `cli/nagarectl/src/Nagare/Platform/Status.hs` has `ReleaseIdentity` (version, revision, payloadSchema; no payload ID or installation time) and `parseClusterIdentity`, which parses the stamp. `cli/nagarectl/app/Nagare/Cli/Runtime/PlatformStatus.hs` (`gatherPlatformStatus`) already reads the stamp with `kubectl get configmap nagare-platform-version -n nagare-system -o json --request-timeout=5s` through `Nagare.Ops.Probe.captureTool`, and reads the context's host pin from the generated host flake with `parseHostIdentity`. `bootstrapMarkerValue` in `cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs` writes the modern stamp with `payloadId` and `scopeVectorDigest`; the older `cluster/bootstrap/platform-version.yaml.tmpl` has version, revision, payloadSchema and installedAt but no payload ID. Read the fields the stamp actually has; an older stamp reports `payloadId` as `not_recorded`.

The inventory store. `cli/nagarectl/src/Nagare/Inventory/Store.hs` exports `readObject` (any store, one named object), `openFilesystemStore` and `openObjectStoreReadOnly`; `Nagare.Inventory.Store.FileIO.atomicWrite` is the temp-and-rename write every local object uses. `cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs` defines `ObjectOps` with `getObject`, `putObject` under `PutCondition` (`IfAbsent` or `IfGenerationMatches`), and `gcloudObjectOps`, the operator's cloud transport. `cli/nagarectl/src/Nagare/Inventory/Store/Service.hs` is the API's cloud session: exact GETs under one prefix, writes and listings refused, and `freshHead`, which rechecks the bucket's owning project number before each head read. `cli/nagarectl/src/Nagare/Inventory/Recorded.hs` is the recorded reader both the CLI and HTTP use. The cloud reader's grant is `infra/pulumi/src/components/NagareAdminApiReader.ts`, whose `inventoryReadCondition` names exactly `format.json`, `head.json` and `scopes/`, tested by `infra/pulumi/test/adminApiReaderResources.test.ts`. The deployments are `cluster/bootstrap/admin-api/admin-api-local.yaml.tmpl` (read-only hostPath mount of `/var/lib/nagare/inventory`, no service account token, DNS-only egress) and `admin-api-cloud.yaml.tmpl` (reader key Secret, `--store-url`, `--project-number`, HTTPS egress to public addresses only).

Databases. `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` owns `Engine` (Postgres, Redis, ClickHouse) and the declared `engineVersion`; `cli/nagarectl/src/Nagare/Inventory/Database.hs` binds a declaration to its StatefulSet, Service and volume members. The authenticated engine boundary is `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`: it runs `kubectl exec -i --namespace <ns> pod/<server>-0 -- sh -c 'psql -X -q -A -t -U "$POSTGRES_USER" …'` or `clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"`, so credentials come from the pod's own environment and never leave it; `cli/nagarectl/src/Nagare/Database/Shell.hs` has the same shape for Redis (`redis-cli -a "$REDIS_PASSWORD"`). `cli/nagarectl/src/Nagare/Database/Connection.hs` only assembles environment variables for applications and is not a probe boundary. ADR 30 distinguishes a physical server from the application-database tenants it hosts; the document lists servers, never tenants.

Components. `cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs` compiles the digest-pinned upstream manifests (Knative Serving and its ingress, cert-manager); `Observability.hs` and `ObservabilityExtras.hs` compile vendored Helm charts (`cluster/observability/vendor/`) with a chart digest into release claims; `AdminApi.hs`, `Auth.hs`, `PackagedAuth.hs`, `Foundation.hs` and the rest compile the other platform scopes. The accepted scope members retain their native objects under the store's private `native/` prefix, which the collector reads as the operator and the API never can. Declared images and versions come from those accepted members, never from the running binary's current pins.

Cluster access and the host. `cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs` gives a command one admitted, context-bound cluster session (EP-226). `nixos/modules/nagare-host.nix` is the host module; `nixos/hosts/nagare-01/k3s.nix` configures k3s. The host's pinned nixpkgs (`nixos/flake.lock`, 26.11 at `eaad0894`) provides `services.k3s.manifests`, which writes manifests k3s applies on start and re-applies on change, and `system.nixos.revision`, the nixpkgs revision the host was built from. `/etc/os-release` on NixOS carries only `VERSION_ID` (release) and `BUILD_ID` (release plus date and short revision), so the full revision has to be recorded by the module. `docs/user/local-development.md` brings up the local harness (k3d, not NixOS) and `docs/runbooks/before-a-native-run.md` precedes any cloud or host mutation.

Relevant ADRs consulted: [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) separates build, payload, context, host and installed identities and treats unknown identities explicitly; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), particularly its 2026-10-16 "bounded recorded-state readers" amendment, requires context binding, bounded reads, an exact object grant (`format.json`, `head.json`, `scopes/`) and no native payloads in public DTOs; [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) distinguishes servers from tenants; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs the Haskell record and Prelude standard; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires fault-injected interpreter tests before native runs.

## Plan of Work


### M1 — Define and serve the partial document


Add the contract records in a new `cli/nagare-contract/src/Nagare/Contract/Versions.hs` (`PlatformVersions`, `Fact`, `SourceKind`, the section records) and register the module in `nagare-contract.cabal`; V1 need not re-export them. Add `versions` to `PlatformRoutes` as a GET with `IfNoneMatch` and a new `cli/nagare-api-server/src/Nagare/Api/Platform/Handler.hs`. Add a snapshot-read action to `Env` in `Serve.hs` (constructed in `cli/nagare-api-server/app/Main.hs`; tests supply fixture actions). The handler reads one snapshot of at most 1 MiB under the existing request deadline, combines it with `AppConfig.version` and a process-start read time, encodes the document, computes the ETag from the exact bytes as `serveBuild` does, answers 304 to a matching `If-None-Match`, and sends `Cache-Control: private, no-cache`. It uses no representation cache and sends no `Nagare-Head-Revision` header: the body's `snapshot.inventoryRevision` says which head the observations were taken against. Every existing route is unchanged.

The document is a contract read document: `contractVersion: 1`, `document: "platform-versions"`, `context`, `project`, then `snapshot` (`collectedAt`, `completedAt`, `inventoryRevision`, `available`, `reason`), `nagare`, `hosts`, `components` and `databases`. `nagare.installed` has facts for version, revision, payloadId and installedAt from the stamp; `nagare.servingBuild` is the existing `VersionInfo` plus `readAt`; `nagare.pins` holds the optional host and context pin facts; `nagare.comparison` has `state` (`match`, `different` or `unknown`) and the compared fields. Unequal known fields mean `different`; equal versions with missing revision evidence mean `unknown`; complete equal evidence means `match`. Hosts are keyed by node name and UID with facts for osImage, kernel and kubernetes (observed from `status.nodeInfo`) and a `nixos` group (release, codename, version, nixpkgsRevision; recorded from the host-identity ConfigMap). Components are keyed by owner scope and component name with declared facts (version, chart version, image, as the component has them) and `workloads`, each with its containers' observed image, image digest and pod UID. Databases are keyed by scope, namespace and server name with engine, declared engine version and declared image facts, and `instances`, each with pod UID, observed image, image digest and `reportedVersion`. Arrays preserve every version in a rollout; stable sorting keeps the bytes deterministic. Identity keys and structural fields carry no fact envelope.

A compact example of the shape, abbreviated:

```json
{
  "contractVersion": 1,
  "document": "platform-versions",
  "context": "intranet",
  "snapshot": {"collectedAt": "2026-10-31T16:00:02Z", "completedAt": "2026-10-31T16:00:09Z", "inventoryRevision": "sha256:…", "available": true, "reason": null},
  "nagare": {
    "installed": {"version": {"value": "0.13.0", "sourceKind": "recorded", "source": "configmap nagare-system/nagare-platform-version", "observedAt": "2026-10-31T16:00:02Z", "reason": null}},
    "servingBuild": {"version": "0.9.0", "platformVersion": "0.9.0", "revision": "…", "tools": null, "contracts": [1], "readAt": "2026-10-30T22:11:40Z"},
    "comparison": {"state": "different", "installedVersion": "0.13.0", "servingVersion": "0.9.0"}
  },
  "databases": [{"scope": "database:labs-postgres", "engine": "postgres",
    "declaredVersion": {"value": "18", "sourceKind": "recorded", "source": "accepted declaration", "observedAt": "2026-10-31T16:00:02Z", "reason": null},
    "instances": [{"podUid": "…", "imageDigest": "sha256:…", "reportedVersion": {"value": "PostgreSQL 18.6 …", "sourceKind": "observed", "source": "SELECT version()", "observedAt": "2026-10-31T16:00:06Z", "reason": null}}]}]
}
```

The reason catalog, documented in `docs/api/README.md` as a string catalog like problem codes: `not_recorded` (the source exists but never recorded this field, such as a legacy stamp's payload ID or a host without the identity ConfigMap), `not_applicable` (a non-NixOS substrate's NixOS facts), `unreadable`, `denied`, `probe_failed`, `probe_unsupported`, `identity_changed`, `collection_deadline`, `inventory_changed`, and for the whole snapshot `snapshot_missing`, `snapshot_invalid`, `snapshot_oversized`, `snapshot_foreign` (bound to another context), `snapshot_unavailable` (store or ownership check failed). A missing, corrupt, oversized or foreign snapshot still yields HTTP 200 with the serving build, `snapshot.available: false`, its reason, and empty sections; this is distinct from an available snapshot with an empty component or database list. Authentication and malformed requests keep their problem responses.

Acceptance: wire tests on the fixture show an older serving build beside a newer installed release (`different`), matching identities (`match`), missing revision evidence (`unknown`), a missing and a corrupt snapshot (200 with reasons), a per-field null with its reason, a mixed rollout with two digests, HEAD without a body, and a 304 on a matching `If-None-Match`. The generated OpenAPI describes nullable `value`s and the recorded/observed distinction, and regenerating twice produces no diff.

### M2 — Produce a snapshot and exercise the complete path


Add `cli/nagarectl/src/Nagare/Platform/Versions.hs` for the pure assembly (inputs in, document out, no IO), `cli/nagarectl/src/Nagare/Platform/Versions/Store.hs` for snapshot validation and publication, and the provider interface with its native implementation in `cli/nagarectl/app/Nagare/Cli/Platform/Versions.hs`, wired through `cli/nagarectl/app/Nagare/Cli/Commands/Platform.hs` and the parser in `cli/nagarectl/app/Nagare/Cli/Parser/Platform.hs`. Library modules never import `Nagare.Cli.*` and pure modules contain no IO; `scripts/check-haskell-architecture.py` enforces both. Before writing every collector, prove stamp → collector → `versions/latest.json` → real HTTP response on a filesystem store, then through the loopback cloud reader of `InventoryServiceStoreSpec.hs`.

The snapshot is one object, `versions/latest.json`, under the context's inventory root, bound to the context and project, with its own `snapshotSchema: 1`, the collection start and end times, and the accepted head revision captured before any probe. Local publication uses `atomicWrite`; cloud publication reads the current object's generation and writes with `IfGenerationMatches` (or `IfAbsent`), and never replaces a snapshot whose `completedAt` is later than its own. If the accepted head changes during collection, discard and retry once, then publish with `available: false` and `inventory_changed` rather than attribute observations to the wrong declarations. Publication never touches the head, journal or convergence facts. Reads reject anything over 1 MiB, malformed, of an unknown schema, or bound to another context, each with its reason.

The installed identity reuses the stamp read `gatherPlatformStatus` already performs; extend `parseClusterIdentity` (or add a sibling in `Nagare.Platform.Status`) to also return `payloadId` and `installedAt`. Host facts come from `kubectl get nodes -o json` (osImage, kernelVersion, kubeletVersion, node UID) and from the ConfigMap `kube-system/nagare-host-identity` that M3's host module emits; a missing ConfigMap on a NixOS node is `not_recorded`, and a non-NixOS node (osImage not starting with `NixOS`) reports `not_applicable` for the whole `nixos` group. Never read the API container's OS, never infer the host's nixpkgs revision from the collector's own flake, and never traverse `/nix/store`.

Database servers are enumerated from the accepted `database:` scopes: the declared engine and version from the typed declaration (preserving a moving tag such as `18` literally), the declared image from the accepted StatefulSet's native object, and the running instances from one `kubectl get pods -o json` per namespace filtered to the server's pods, recording pod UID, `image` and `imageID`. The reported version is one fixed read-only statement through the same in-pod execution shape as `AppDatabaseRuntime`: `SELECT version()` via `psql -X -q -A -t`, `SELECT version()` via `clickhouse-client`, and `INFO server` via `redis-cli` (the `redis_version` line). Re-read the pod UID after the probe; a changed UID yields `identity_changed`. A stopped server keeps its declared facts with null instances. Credentials stay in the pod environment and never appear in the snapshot, the document, diagnostics or logs.

Components are enumerated from the accepted `platform:` scopes: declared image, version or chart version from each accepted member's native object or release claim, and observed digests from the pods of the matching workloads, read with the same per-namespace pod lists. Disabled components are absent; installed but unreadable components remain with reasons; an accepted member whose shape the collector does not understand is reported as `probe_unsupported`, never dropped.

Every provider read has a `--request-timeout=5s`, at most four run concurrently, and the standalone collection budget is 60 seconds; facts not attempted within the budget are `collection_deadline`. Prefer a handful of list reads (nodes once, pods once per namespace, two ConfigMaps by name) over per-object gets, so a normal collection is a dozen process launches and finishes in a few seconds. A failed probe never cancels another; cancellation of the collector itself is never swallowed.

Acceptance: `PlatformVersionsSpec.hs` runs the real assembler, writer and reader against fake providers with missing stamp fields, a denied node read, a stopped server, a changed pod UID, a mixed rollout, a failed publication, two concurrent refreshes and a changed head. One PostgreSQL, one ClickHouse and one Redis fixture show distinct declared and observed versions through the real HTTP route.

### M3 — Deliver and refresh in both environments


Extend `inventoryReadCondition` in `infra/pulumi/src/components/NagareAdminApiReader.ts` and its test with exactly `versions/latest.json`; listing, writes, `native/`, `reviews/`, `journal/` and other contexts stay refused. Add a `freshObject` beside `freshHead` in `Service.hs` so every snapshot read passes the same bucket-ownership check; a failed check is `snapshot_unavailable`. The local deployment already mounts the inventory directory read-only, and `atomicWrite`'s rename is visible through that mount without a restart. No Kubernetes token, host mount, database Secret or wider egress is added to the API.

In `nixos/modules/nagare-host.nix` add `services.k3s.manifests.nagare-host-identity` with a ConfigMap `kube-system/nagare-host-identity` (kube-system exists before any manifest applies) whose data is `config.system.nixos.release`, `codeName`, `version` and `revision`. Evaluate the fixture host (`nixos#nagare-01`) to confirm the manifest renders; the real host only picks it up at the next `just host-switch`, which is a host mutation and needs the operator's go-ahead after [Before a native run](../runbooks/before-a-native-run.md).

Wire the best-effort refresh after a converged `runInventoryApply` (`cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`) and `runPlatformBootstrapApply` (`cli/nagarectl/app/Nagare/Cli/Commands/Bootstrap.hs`), only when the applied review changed a `platform:` or `database:` scope, under a 20-second budget, printing one line such as `versions: refreshed (2 of 41 facts unavailable)` or `versions: skipped (no platform or database scope changed)` to stderr under `--contract 1`. Confirm while implementing that the release transition lands through the same apply path; if not, hook its finalize step the same way. A refresh failure warns and keeps the previous snapshot with its old timestamp; it never changes the apply's outcome or exit code. No scheduler or freshness promise is introduced; the docs say observations are as of `collectedAt` and show the refresh command.

Acceptance: the local API serves a newly published snapshot without a restart. The cloud reader reads exactly the snapshot and still cannot read native objects, another context, list or write (Pulumi test plus the existing IAM negatives). A refresh failure leaves a converged apply converged. Existing gateway and network tests pass. Amend ADR 22 (the observation object, the producer boundary, the widened exact grant) and ADR 6 (reporting installed/serving skew without changing mutation compatibility; host identity recorded at activation).

### M4 — Prove the IR and document operation


Extend `cli/nagare-api-server/hurl/platform.hurl` (the fixture seeded by `seedStore` gains a snapshot so Hurl can assert facts, a 304 and HEAD), the serve tests, and `PlatformVersionsSpec.hs`. Add a `platform-versions.json` entry to `samples` in `Nagare.Test.Contract`, accept it with `--accept`, and review the generated `docs/api/samples/platform-versions.json`. Update `docs/api/README.md`: a Documents row (`platform-versions`, `PlatformVersions`, read, `nagarectl platform versions --contract 1` and the admin API), the reason catalog, the recorded/observed and `observedAt` semantics, rollout arrays, legacy stamps and hosts, and the refresh command.

Run the native comparisons after the interpreter tests pass: on the local harness from `docs/user/local-development.md`, then on an explicitly selected cloud context with the repository's context selection and gateway authentication. Compare `nagarectl platform versions --json` and the HTTP document with `kubectl get nodes -o json`, pod `imageID`s and an independent `SELECT version()`. Record the context, commands, timestamp and sanitized results here. Do not provision a cloud context or upgrade a consumer to complete evidence; if an environment is unavailable, leave its evidence outstanding. Triage friction and finish the ADR distillation before marking M4 complete.

## Concrete Steps


Run commands from the repository root. Per Haskell commit: `just haskell-style-check` first (it also checks the Cabal files with `cabal-gild --mode check`; after adding a module, format the Cabal file with `cabal-gild --io <file>` and register the module, or the architecture check reports "missing Cabal registration"), then `just gate-fast` on the committed revision. Focused checks while developing:

```bash
cabal build --project-dir=cli/nagarectl nagare-contract nagare-api exe:nagare-api-server exe:nagarectl
cabal test --project-dir=cli/nagarectl nagare-api-server-test --test-show-details=direct
cabal test --project-dir=cli/nagarectl nagarectl-test --test-options='-p "/platform versions/"' --test-show-details=direct
cabal run --project-dir=cli/nagarectl nagare-api-openapi && git diff --stat docs/api/openapi.json
just api-hurl
python3 scripts/check-haskell-architecture.py && python3 scripts/check-cli-architecture.py
```

Name the new tasty group `platform versions (EP-236)` so the selector above runs it; run the DSL and CLI suites serially. Expect the selected tests to pass, Hurl to cover the new route, and `docs/api/openapi.json` to contain `/v1/platform/versions` with no further diff on a second regeneration.

After M2, in an already selected test context:

```bash
cabal run --project-dir=cli/nagarectl nagarectl -- platform versions refresh
cabal run --project-dir=cli/nagarectl nagarectl -- platform versions --json
```

The refresh prints the published `completedAt` and the unavailable-fact count. The reader prints the recorded sections; it labels the serving build only when reading through the API, because the CLI binary is not the serving build.

Commit at working boundaries with Conventional Commit messages and the trailer `ExecPlan: docs/plans/236-expose-installed-platform-host-component-and-database-versions.md`, then:

```bash
just haskell-style-check
just gate-fast HEAD
```

Record concise results and any outstanding native evidence in Progress.

## Validation and Acceptance


AC-1: fixture the stamp at a newer version than `AppConfig.version`; both are visible and `comparison.state` is `different`. Equal version and revision give `match`; a missing revision gives `unknown`. Installation time and payload ID come from the stamp; a legacy stamp reports `payloadId` null with `not_recorded`.

AC-2: compare the host entry with `kubectl get nodes -o json` through the selected context, and the `nixos` group with the host's `/etc/os-release` and `kube-system/nagare-host-identity`. On the cloud host the group is populated after its host-switch; on the local harness it is `not_applicable`. Container OS facts never substitute for host facts.

AC-3: with PostgreSQL declared `18` and ClickHouse at an exact version, the declared literal sits beside the running engine string, and each matches an independent `SELECT version()`; Redis reports its `redis_version`; digests match pod `imageID`. Platform databases and shared servers appear once each with no tenant rows. Stopping or denying one server keeps its declared facts and leaves other servers' observations intact.

AC-4: the component list matches the accepted platform scopes, the installed release's members and the workload images on both environments, including an absent optional component and a mixed rollout. A newer serving binary does not relabel older installed components with its own pins.

AC-5: deny one source, deny snapshot access, corrupt a snapshot and exceed a probe deadline; the document is still 200 with sources, times and stable reasons. Real nulls validate against the generated schema. Secret and connection-string sentinels planted in provider errors and native inputs never appear in snapshots, responses or logs. The reader's IAM negatives, unauthenticated gateway requests, the old routes' validators, the absence of HTTP-triggered provider calls, and a snapshot read bounded by the request deadline are all tested.

## Idempotence and Recovery


Reads and probes are non-mutating. Refresh replaces only the snapshot after complete assembly and never touches the stamp or accepted inventory. Local `atomicWrite` and cloud generation-conditional writes prevent torn documents and prevent an older concurrent collection from overwriting a newer one; a failed publication keeps the previous snapshot and repeating refresh is safe. Deleting the snapshot yields `snapshot_missing` until the next refresh and leaves every other route untouched. Reverting the route and collector leaves accepted inventory intact. The IAM widening and the host-module ConfigMap land as reviewed deployment changes under the operator's go-ahead, and host activation preserves operator files as before.

## Interfaces and Dependencies


Use the existing Aeson, Servant, OpenAPI, store and cluster facilities; no dependency change is planned. Before touching a dependency API, locate its source with `mori registry search`, `mori registry show --full` and `mori registry docs` and read it on disk; never search `/` or `/nix/store`.

`Nagare.Contract.Versions` owns public data only. `Nagare.Platform.Versions` is pure assembly. `Nagare.Platform.Versions.Store` owns context binding, schema and size validation, atomic publication and ordering. `Nagare.Cli.Platform.Versions` owns provider access and sanitization. The HTTP handler reads one snapshot, combines it with the serving build and renders partial availability; it never opens a database connection or runs kubectl. Time and provider or store operations are injected for deterministic tests. The snapshot schema is versioned separately from the contract, so an unknown future snapshot schema yields `snapshot_invalid` without breaking inventory inspection.
