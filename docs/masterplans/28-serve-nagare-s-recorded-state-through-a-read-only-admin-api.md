---
id: 28
slug: serve-nagare-s-recorded-state-through-a-read-only-admin-api
title: "Serve Nagare's recorded state through a read-only admin API"
kind: master-plan
created_at: 2026-10-14T17:49:39Z
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
      at: 2026-10-16T22:20:11Z
      mode: "update"
      note: "Validated API and serving design against source and releases; corrected bounded reads, HTTP semantics, milestone ownership, credentials and deployment proof."
---

# Serve Nagare's recorded state through a read-only admin API


## Vision & Scope

Serve one context's recorded state at `https://admin.<base domain>/v1/…`: accepted/converged
scope revisions, recorded sites, image publications, host grants and the head's transaction,
claim, fence, migration and transition summaries. A signed-in person or Shomei service-account
bearer client must have an ordinary grant on that hostname. The future admin UI shares this
origin (`/` reserved), while Kotei continues to deploy through the CLI. Recorded convergence
is not live workload health or an effective-access check.

The service must be prompt: head/scope-summary requests read no scope objects, unchanged lists
reuse verified decoded data, request work has a total deadline, and real gateway-to-GCS latency
is measured before completion. EP-197 sets the test conditions and budgets: warm p95 below two
seconds remotely, below 250 ms locally, and a ten-second backend request deadline. These are
acceptance targets; no API has been implemented or benchmarked by this plan validation.

The API is read-only and its dedicated credential grants no mutation authority. It reads existing
inventory only, never initializes/migrates it, and never plans, applies, resumes or closes work.
It runs inside GCS-backed contexts. Local native proof uses a context-scoped read-only store
mount; a cloud context whose authoritative store is still on a workstation needs an explicit
existing store migration before enabling the in-cluster service. No store is silently substituted.

The public contract is one generated OpenAPI 3.1 artifact, `docs/api/openapi.json`, also served
unchanged at `/v1/openapi.json`. `/v1/platform/version` describes the serving binary and packaged
platform version, not the context's fully installed release; recorded rollout state is the head
transition plus per-scope revisions. The head stores no installed-version field, and fetching
native version ConfigMap bytes from review archives would violate this read boundary.

Included are the shared CLI/API/gateway document contract, recorded reader, service identity,
HTTP server, deployment, protected routing and native confirmation. Excluded are UI code,
mutating routes, live Kubernetes/provider inspection, raw native payloads/secrets, new auth flows,
a persistent discovery database and background reconciliation. `inventory status --contract 1`
retains observed drift for Kotei; v1 HTTP does not pretend to supply it.


## Decomposition Strategy

Five existing workstreams remain appropriate. EP-192 owns shared wire types and schemas;
EP-193 owns checked snapshot reading and recorded-site interpretation; EP-196 owns service
credentials and the GCS transport lifetime; EP-197 owns HTTP semantics, bounded request/cache
policy and offline latency proof; EP-198 owns packaging, gateway integration and native proof.
No extra plan or observability platform is needed to fix the identified gaps.

Relevant durable context: [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)
requires the Haskell/API standards at `mori://shinzui/haskell-jitsurei/docs/api-overview`;
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) owns
inventory authority and the recorded-read boundary;
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) preserves
context and bucket ownership checks;
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps credential delivery in operator material;
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) and
[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md)
cover hostname authorization and sessions;
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires release transitions; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
requires offline proof before native confirmation.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 192 | Publish the shared versioned document contract | [EP-192](../plans/192-publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes.md) | EP-193 M1 for M4 only | None | In Progress |
| 193 | Read recorded state and list recorded sites | [EP-193](../plans/193-list-recorded-sites-without-live-provider-observation.md) | EP-192 M1 for M1 DTO/converter acceptance | None | In Progress |
| 196 | Open the inventory through a read-only service identity | [EP-196](../plans/196-read-the-inventory-store-from-an-in-cluster-service-identity.md) | None | EP-193 head-reader interface | Not Started |
| 197 | Serve typed, bounded HTTP reads | [EP-197](../plans/197-serve-the-read-documents-through-a-typed-servant-admin-api.md) | EP-192 M1, EP-193 M1 | EP-196 for cloud source | In Progress |
| 198 | Deploy behind the admin hostname grant | [EP-198](../plans/198-run-the-admin-api-in-each-context-behind-an-admin-grant.md) | EP-196, EP-197 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled, Held.


## Dependency Graph

Start EP-192 M1 and EP-196 independently. EP-193's underlying store work can be prepared alongside
EP-192, but its M1 acceptance includes the site DTO/converter and therefore waits for EP-192 M1.
Then EP-197 can implement the whole HTTP surface against a local fixture. Its first proof is one
real compiled 200/304/503 slice, generated OpenAPI and generated-client decode before expanding
routes. EP-196 supplies the cloud reader when ready. EP-198 waits for both completed children,
reviews/applies infrastructure prerequisites, and confirms the deployed path.

EP-192 M4 waits for EP-193 M1 for CLI reader wiring; this is not a milestone cycle:
EP-192 M1 → EP-193 M1 → EP-192 M4. Pure publication/scope/version projections move to EP-192 M1,
and the site DTO/converter moves to EP-193 M1. Thus EP-197 has no hidden dependency on EP-192's
mutating CLI milestones or EP-193's CLI dispatch. EP-192 M2–M5 and EP-193 M2–M3 remain required
for the whole initiative, but do not block the first functioning HTTP service.


## Integration Points

**Document contract — EP-192 owns.** `cli/nagare-contract` has no Nagare dependency. It owns
`Nagare.Contract.V1` and `Nagare.Contract.Problem`, including the Servant content-type dependency
needed by `ProblemJSON`. One item shape is used in CLI arrays and HTTP Relay connections.
EP-193 M1 adds `SiteSummary`, the site-list envelope and converter; EP-197 M1 adds `HeadSummary`
and `Grant`. Pure projections live in `cli/nagarectl/src/Nagare/Contract/Project.hs`; version,
scope and publication projection is ready in EP-192 M1. Operation DTO changes and CLI dispatch
remain with their later milestones. Gateway `error`/`login` extensions are part of the shared
problem codec/schema, not hand-built alternate JSON.

**Recorded reader — EP-193 M1 owns.** `Nagare.Inventory.Recorded` exposes an opaque checked head,
a reusable reader, hydration of that exact head and a one-shot CLI convenience function. It
checks store/context binding, canonical bytes, digests and scope ownership and returns open
execution state as facts. Head/scope-summary handlers project without hydration. Accepted scopes
are hydrated for sites/publications/grants; previous converged declarations are loaded only for
sites that need them. No journals, reviews, native envelopes or retained/collected history are
loaded. `loadTargetSnapshotReadOnly` remains planning-only: it exits and refuses open transactions.
EP-196 supplies a cancellable fresh ownership/head action, while local callers use the existing
checked head path. The reader accepts that injected action without importing service credentials.

**Read cost and cache — EP-197 owns policy; EP-193 owns loader implementation.** The service
retains its session/manager, uses the shared byte-bounded digest decode cache and bounded
hydration workers, and memoizes sorted projections by their required revision vectors. Only
immutable verified data is reusable; every state request still reads an authoritative bound head.
A head-only transaction change does not force all declarations to decode again. Defaults are
64 MiB cache, eight hydration workers and 32 admitted state requests; deadline includes queue,
auth refresh, store IO and encoding. Full error/cancellation and cold/warm acceptance belongs to
EP-197, and EP-198 measures the real gateway/GCS path. Page size alone is not a read-cost bound.

**HTTP contract and artifact — EP-197 owns after M1.** EP-192 initially generates component
schemas; EP-197 takes over the one artifact/equality test and retains CLI-only components.
It publishes the exact routes, filters, cursor rules and statuses in its Plan of Work. Cookie
and bearer are alternatives (OR). A representative generated-client test covers success, a Relay
page and a problem; it must not rely only on schema equality. ETags hash encoded representation
bytes; `Nagare-Head-Revision` separately identifies the checked snapshot across routes. Health,
OpenAPI and build-version routes never trigger inventory hydration. Conditional requests do not
bypass authorization, validity or existence checks. Private caches must revalidate every use.

**Error catalog — EP-192 owns; EP-197/198 extend.** `about:blank` uses HTTP status titles;
`code` and `detail` carry domain distinctions. EP-196 returns typed store failures without an HTTP
package dependency. EP-197 maps them and owns Servant/middleware error rendering, including
405/406, cancellation deadlines and corruption. EP-198 maps gateway 401/403/503 and proxy 502/504,
with sanitized details and required headers. Nagare-produced `/v1` errors before response commit
are problems even without an Accept header; infrastructure errors, disconnects and health-status
bodies have separate limits. Future enum values are not automatically wire-compatible.

**Service identity — EP-196 owns.** A dedicated read-only identity has exact-prefix
`storage.objects.get`, separate exact-bucket metadata permission and any explicitly needed
project-number lookup. No bucket listing or writes, even after missing-object reads. The API
cannot receive the broadly privileged node credential; EP-198 isolates metadata access and
mounts dedicated credential material. HTTP manager/token refresh live for the service lifetime,
with fresh ownership checks and caller-controlled deadlines. Expected project ID and numeric
project number are validated rather than inferred from a service-account key string.

**Deployment and authorization — EP-198 owns.** A one-replica Deployment and ClusterIP Service
in `nagare-system` are protected from ordinary workloads by ingress requiring both the gateway
namespace and stable pod label. Prove both Service and Pod-IP isolation, including unrelated pods
in the same namespace; trusted node/admin traffic is outside that claim. Native NetworkPolicy
cannot select GCS by DNS name: documented HTTPS egress plus exact IAM is the chosen boundary,
with metadata access blocked. EP-198 owns 512 MiB runtime limit, private writable temp/cache,
read-only source/credential mounts and probes, plus the protected DomainMapping, backend-map
update and gateway rollout. The gateway authenticates and checks the host grant; forwarded
identity is only log/trace context. Its admin `/v1` classifier must not depend on Accept.

**Cloud/local rollout — EP-198 owns.** Pulumi identity/IAM prerequisites are reviewed/applied
explicitly before platform transition; a transition-table row does not create an account.
The local native fixture uses a real read-only context mount; a workstation-only server cannot
replace the network-policy proof. Native work follows existing authorization requirements.


## Progress

EP-192 M1, EP-193 M1 and EP-197 M1 are complete: the contract package, the pure projections,
the shared recorded-state reader, the route types and the one generated artifact, whose
generator moved to `cli/nagare-api`. Next: EP-197 M2 (handlers over the reader) and EP-196.
The credential's actual project lookup, provider IAM enforcement and local mount/network behavior
remain explicit implementation proofs, not claims established by this documentation review.


## Surprises & Discoveries

The initial design hydrated all scopes even before conditional responses; the GCS transport uses
two HTTP operations per uncached object and a twenty-second per-attempt timeout. Existing
`acceptedAccessBindings` filters unbindable grants, `Proxy.hs` emits text 502s, and the node
identity already has mutating permissions. Those source findings motivate the corrections below.


## Decision Log

2026-10-16 (EP-197 M1): The upstream servant-client `MultiVerb` client cannot decode a declared
problem or a bodyless 304 (it checks the verb's media list first). `nagare-api` owns the client
of its own verbs rather than widening every route's media list. Worth raising upstream.

2026-10-14 (operator): The API is read-only. EP-192 becomes the shared CLI/API contract and joins
this initiative with EP-193. Follow the haskell-jitsurei API standards: NamedRoutes/MultiVerb,
generated OpenAPI 3.1, RFC 9457, Relay, health, telemetry, bounded logs and Hurl.

2026-10-14: One shared recorded-state reader; no use of the planning loader that refuses an open
transaction. Admin UI and API share `admin.<base domain>`; Kotei uses Shomei service-account bearer
and an ordinary per-host grant. Use a plain Deployment protected by NetworkPolicy, not a shared
Knative origin. Local stores require workstation access or a scoped local mount; no cloud-store
credential is assumed to work for a local directory. Native deployment proof requires the mount.

2026-10-14: Head summary includes open execution state. Gateway JSON errors share the problem
shape. Cursors continue across heads. The initial generation-only strong ETag and node-account
default are superseded by the following validation decisions.

2026-10-16: Preserve the five workstreams but expose checked-head and hydration separately,
move API-needed pure projections/DTO conversion into prerequisite M1s, and make read costs,
request deadlines and measured gateway latency acceptance criteria. Reuse immutable data without
caching away fresh mutable ownership/head checks. This addresses both implementation ordering
and serving latency without adding a persistent index or another service.

2026-10-16: Correct validators, pagination consistency claims, version meaning, grants and error
coverage. Representation ETags and snapshot identity are separate; fixed-snapshot walks have
no-skip/no-duplicate proof while cross-head cursors make no frozen-snapshot promise. The grants
route reports recorded viewers including unbindable ones, not live authorization. Build version
is not installed-context version. Every API error produced by Nagare before commit uses the
shared shape; probe and external transport failures are explicitly scoped.

2026-10-16: The node credential cannot meet the read-only promise because it already grants
writes. Use a dedicated identity and minimal exact-object reads with separate ownership metadata
permission. Correct the unimplementable GCS-by-hostname NetworkPolicy claim, require blocked
metadata credentials and same-namespace bypass proof, and make Pulumi prerequisites explicit.
Durable boundaries are recorded now in ADR 22 and ADR 29 rather than deferred until completion.

Revision note, 2026-10-16: Validated against store, gateway, access and deployment sources and
current dependency releases; corrected API semantics, bounded serving costs, prerequisite
ownership and credential/deployment feasibility. Removed an accidentally embedded tool transcript
from the previous MasterPlan tail. No implementation or native performance result is claimed.


## Outcomes & Retrospective

Implementation is pending. The plan now specifies the behavior and measurements required to
establish that the API is correct and prompt; completion requires all child acceptance and the
real gateway/GCS proof.
