---
id: 197
slug: serve-the-read-documents-through-a-typed-servant-admin-api
title: "Serve the read documents through a typed Servant admin API"
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

# Serve the read documents through a typed Servant admin API


## Purpose / Big Picture

Serve one context's recorded inventory promptly through `nagare-api-server`. The admin UI and
Kotei can read accepted and converged scope revisions, sites, publications, grants, and open
execution state without running provider inspection. Recorded convergence never claims current
workload health. [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md)
coordinates the work; [EP-198](198-run-the-admin-api-in-each-context-behind-an-admin-grant.md)
packages it and proves gateway access. This plan proves the HTTP behavior offline first.

One authoritative head is read per state request. Head and scope-summary routes need no scope
objects. Other routes hydrate that head through the shared reader and reuse verified immutable
objects and decoded projections. Polling must not reopen credentials, enumerate history, or
rebuild the full inventory on each unchanged request. `/v1/platform/version` describes the
serving binary and its packaged platform version, as CLI `VersionInfo` does; it is not evidence
that every platform component has converged on that release. The head's transition marker and
scope revisions describe recorded rollout state. The head does not contain a context release
version field, and scope declarations hold native-object digests, not the version ConfigMap's
body. Do not invent a recorded installed version or fetch archives to infer one.

After implementation, from the repository root:

```bash
cabal run --project-dir=cli/nagarectl nagare-api-server -- --context local-dev --store-dir ~/.local/state/nagare/local-dev/inventory --port 8085
curl -s -i localhost:8085/v1/inventory/head
curl -s 'localhost:8085/v1/inventory/scopes?first=2'
curl -s -i localhost:8085/v1/inventory/scopes/application:nope
curl -s localhost:8085/v1/openapi.json
```

The missing scope answers 404 with `application/problem+json`. The server binds loopback by
default; the deployed image explicitly binds its pod interface.


## Progress

- [x] M1. `cli/nagare-api` holds the `NamedRoutes` slices (`Platform`, `Inventory`, `Sites`,
  `Access`, root `AdminApi` with `servant-health`), the shared `MultiVerb` lists (200 with ETag,
  Cache-Control, Vary and `Nagare-Head-Revision`; bodyless 304; 400/404/500/503 problems) and
  `nagare-api-openapi`, which now writes `docs/api/openapi.json`. `HeadSummary` and `Grant` are in
  the contract, projected by `Nagare.Contract.Project`. Pass: `nagare-api-server-test` (8 tests):
  the artifact equals the generated document; its paths are exactly the served routes with
  stable operation IDs; every `/v1` operation has the cookie-or-bearer requirement and
  problem-typed 400–504 responses; health has no security; the client derived from the routes
  decodes a head with its validators and a 304, a Relay page of sites, and a 404 problem. The
  suite is a fast-gate step and a flake check.
- [x] M2. `cli/nagare-api-server` serves every route over `Nagare.Inventory.Recorded`
  (`Nagare.Api.Server.Serve`: one fresh head per request, validation before hydration, a
  representation cache keyed by route, arguments and the accepted/converged revision vector, one
  ten-second deadline) with `nagare-api-server --context --project --store-dir`. Pass:
  `nagare-api-server-test` "recorded store" (12 tests) over an in-memory store that counts reads:
  the head reports an open transaction, claim, fence, migration and transition and reads only
  `head.json`; scope pages read only the head and pass relay's conformance walk (forward,
  backward, determinism); a warm list reads only the head, head churn keeps its ETag, a changed
  scope reads one new member; `If-None-Match` (list, weak) answers 304 with validators, HEAD has
  no body; a missing scope is 404 even for `*`; invalid pages, malformed and foreign cursors are
  400 problems with no hydration; unknown route 404, POST 405, `Accept: text/html` 406 are
  problems; an unreadable unrelated scope breaks only sites (503 `store_invalid`); a hung store
  answers 503 `store_timeout` within the deadline and recovers; excess requests get 503
  `server_busy` with `Retry-After`; grants list user, team and retired-route viewers; the
  derived client walks 30 sites.
- [x] M3. `servant-health` probes (liveness without IO; readiness reads a fresh bound head
  within one second); one bounded JSON access line per non-probe request
  (`Nagare.Api.Server.RequestLog`: method, path without query, status, duration, user agent,
  cache hit/miss, deadline exceeded; never a body, credential or query string);
  `cli/nagare-api-server/hurl/` with `just api-hurl` (registered). Pass:
  `nagare-api-server-test` (22 tests) adds the access line and a slow store (20 ms a read)
  whose cold list reads members concurrently and never more than eight at once; `just api-hurl`
  passes 21 requests in 6 files against the built server. Measured at `dc3a03c9` on a 250-site
  fixture (253 scopes, about 2,560 declarations) on disk, with a full gate loading the machine:
  cold 11–86 ms per route; 100 requests at concurrency 8, warm p95 95–128 ms (target 250 ms);
  RSS 35 MB at start, 67 MB after (limit 512 MiB).

## Surprises & Discoveries

The original full hydration prelude would charge every request for the whole inventory.
Source inspection also found that recorded grant binding filters are unsuitable for a complete
recorded grant list; neither claim is treated as acceptable behavior.


## Decision Log

2026-10-16: Validation replaces the full-inventory-per-request design with one checked head plus
selective hydration and bounded immutable reuse. The current GCS reader performs metadata and
media requests for each uncached object, with a 20-second bound per SDK attempt; neither a page
size nor that per-attempt timeout bounds the total HTTP request. This plan owns the end-to-end
budget and measurement; EP-196 owns token/transport lifecycle.

2026-10-16: ETags identify representations, not merely inventory generations. A binary or
OpenAPI document can change while the head does not, and different pages are different
representations. A separate `Nagare-Head-Revision` header identifies the snapshot for comparisons.
This supersedes the 2026-10-14 generation-only strong ETag decision. Conditional requests still
validate authorization, route/query/cursor validity, store freshness, and resource existence.

2026-10-16: The published route set and filters below are v1. Keyset cursors survive head
changes, but do not promise one frozen snapshot across requests. Grants mean recorded direct
or team viewer relationships, never effective authorization. Build version is distinguished
from deployment convergence. See [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
and [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md).


2026-10-16 (M1): Handlers encode bodies themselves (`Encoded`, served as `PreEncodedJSON`), so a
strong ETag hashes the exact bytes and a cached representation answers without encoding again.
The four page arguments are ordinary query parameters validated by relay's `mkPageRequest`, not
the `RelayPage` combinator, whose own 400 body is not a problem document. Connection schemas are
named per item (`SiteSummaryConnection`) because relay's generic schemas all name themselves
`Connection`. servant-client-core 0.20.3 refuses any `MultiVerb` response whose media type is
not in the verb's list before trying the alternatives, so it cannot decode a declared
`application/problem+json` error or a bodyless 304; `nagare-api` defines the client for its own
`PreEncodedJSON` verbs, letting each alternative's status and media checks decide. Gateway-only
statuses (401, 403, 405, 406, 502, 504, and 503 for authorization) are added to every `/v1`
operation by the generator, not listed as handler alternatives.

2026-10-16 (M2): The representation cache sits above the reader's member cache: an unchanged
list is answered from its bytes after the fresh head read, without hydration. Admission is a WAI
middleware so the refusal can carry `Retry-After`; probes are never refused. The ETag hashes the
build identity with the bytes, so a new binary never revalidates an old representation.

2026-10-16 (M3): Telemetry is the access line on stdout, which the cluster's log collector reads;
the OTLP collector is optional in a Nagare cluster, so request handling never waits on one.
Tracing joins when a deployment requires it. tasty 1.5 raises capabilities to the processor
count and runs tests in parallel; concurrent first forcing of the large generated-document
thunk spun on its blackhole, so the server and the suite build it once before serving.

## Context and Orientation

`cli/nagarectl/src/Nagare/Inventory/Store.hs` defines `HeadManifest`, `readHead`, immutable
object reads and caches. `replaceObservedHeadUnlocked` increments `headGeneration` on every
head replacement, but HTTP validators must also cover representation changes. The
`Nagare.Inventory.Recorded` reader from
[EP-193 M1](193-list-recorded-sites-without-live-provider-observation.md) provides a checked
head and hydration of that same head, plus recorded-site projection and its contract converter.
[EP-192 M1](192-publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes.md)
provides `nagare-contract`, the shared problem catalog, and pure version/scope/publication
projections. Both milestones are hard dependencies. EP-192 M2–M5's CLI dispatch is not.

`cli/nagarectl/src/Nagare/Inventory/Access.hs` exposes `relationshipOf`, whose constructors
include `DirectViewer`, `TeamViewer` and `TeamMember`. Do not use `acceptedAccessBindings` to
list grants: its list comprehension silently excludes relationships that cannot bind to an
accepted route. Project viewer relationships directly from accepted declarations and retain
scope/resource identities and accepted/converged revisions. Team membership is not a host grant.
A recorded grant may still exist after its route disappears; report it, without claiming access.

Two packages: `cli/nagare-api` owns route types and `nagare-api-openapi`, depending on
`nagare-contract`, Servant, Relay and schema libraries, not `nagarectl`. `cli/nagare-api-server`
owns handlers and executable and links the `nagarectl` library. Pure DTO projections remain
in `cli/nagarectl/src/Nagare/Contract/Project.hs`; transport and cache policy stay in the server.
`Nagare/Api/<Slice>/Routes.hs` and `Nagare/Api/<Slice>/Handler.hs` are domain-first module paths.

Follow [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) and
`mori://shinzui/haskell-jitsurei/docs/api-overview`, especially the canonical documents
`mori://shinzui/haskell-jitsurei/docs/api-servant-routes`,
`mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`,
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`,
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`,
`mori://shinzui/haskell-jitsurei/docs/api-health-endpoints`,
`mori://shinzui/haskell-jitsurei/docs/api-opentelemetry-integration`,
`mori://shinzui/haskell-jitsurei/docs/api-request-logging` and
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing`.

Hackage preferred releases checked 2026-10-16: `servant`/`servant-server` 0.20.3.0,
`openapi-hs` 5.0.0, `servant-openapi-hs` 5.1.0, the three Relay packages 0.1.1.2,
and `servant-health` 0.1.0.0. Upstream tags confirm the OpenAPI and Relay cohorts. Keep
`openapi-hs >=5.0 && <5.1`, `servant-openapi-hs >=5.1 && <5.2`; recheck before implementation.
Released-source inspection confirms `RespondEmpty` is Servant's synonym for
`RespondAs '() ... ()`, covered by the cohort's response machinery; no compatibility patch is
prescribed. M1 still compiles the actual headers/200/304/503 slice before route expansion.
Add packages to `cli/nagarectl/cabal.project`, `nix/haskell-packages.nix`, and the payload's
package sources in `nix/platform-package.nix`. Check the pinned package set without traversing
`/nix/store`; use `callHackageDirect` with verified tarball hashes where the pin lacks a release.


## Plan of Work

### M1 — the wire contract

Define `NamedRoutes` slices with typed `MultiVerb` results. The public GET paths are exactly
`/v1/platform/version` (`VersionInfo`), `/v1/inventory/head` (`HeadSummary`),
`/v1/inventory/scopes` (`Connection ScopeState`), `/v1/inventory/scopes/:scopeId`
(`ScopeState`), `/v1/sites` (`Connection SiteSummary`), `/v1/inventory/publications`
(`Connection Publication`), `/v1/access/grants` (`Connection Grant`), and `/v1/openapi.json`.
Health paths `/health/live` and `/health/ready` are internal probes, separately documented and
without gateway security requirements. No write route, raw scope/native payload, journal,
observed findings or credential material is exposed. Reserve `/` for the future UI.

All growing lists use Relay `first/after/last/before`, default 50 and maximum 100; invalid or
oversized requests are 400, not silently clamped. `/v1/sites` additionally accepts `namespace`
and `includePreviews` (false by default). Other v1 lists have no filters. Sort scopes by full
scope ID, sites and publications by full resource ID, and grants by full resource ID (which
preserves user/team relation distinctions). The site CLI may retain its display ordering.
Cursors encode the complete ordering key and a fingerprint of context, endpoint, filter values,
sort definition and cursor version. Reject malformed or foreign cursors before scope hydration.
Do not include the head revision in that fingerprint: across heads the next page means items
strictly after/before that key in the new head. Inserts before the cursor may be missed and
removed records may disappear; clients needing a consistent walk compare `Nagare-Head-Revision`
and restart. Conformance's no-skip/no-duplicate claim applies to a fixed fixture head only.

Add `HeadSummary` and `Grant` to `nagare-contract` here. `HeadSummary` has context, generation,
sequence and the nullable active transaction, executor claim, data fence phase, migration and
release-transition summaries; use explicit DTOs, never raw internal serialization. `Grant`
has resource ID, scope, host, subject kind (`user` or `team`), subject, subject relation
(null or `member`), and accepted/converged revision facts. Never expand team members or query En.
`SiteSummary` and its converter arrive in EP-193 M1; publications' pure projection arrives in
EP-192 M1, without its later CLI milestone.

Generate one OpenAPI 3.1 artifact using `toOpenApi`, retaining every CLI-only schema introduced
by EP-192. Transfer generator ownership and its equality test from `nagare-contract` to
`nagare-api`; later children contribute schemas through one shared declaration list. Declare
cookie `nagare_session` and HTTP bearer as two alternative security requirement objects (OR,
not AND) for each `/v1` operation. Declare stable operation IDs, actual query/cursor types,
200 success, bodyless 304, response headers (`ETag`, `Cache-Control`, `Vary`, and snapshot header),
and applicable 400/401/403/404/405/406/500/502/503/504 problem responses, including gateway ones.
The OpenAPI endpoint returns the artifact bytes unchanged, not a JSON-encoded string.
A `ToSchema Value` instance needed by nested schema derivation must be reachable wherever the
instance is compiled; a generator-only orphan cannot satisfy an earlier library module.

### M2 — serving a bounded read

`Env` owns one context-bound read-only store session, its transport/token source, a bounded
immutable/decoded cache and request admission. EP-196 supplies cloud access; local fixtures use
the existing store implementation. Read the authoritative checked head once per state request;
never globally wrap health, version or OpenAPI requests in a full-state loader. Head and scope
summary routes project directly from the head. Sites, publications and grants hydrate the same
head through EP-193's `loadRecordedStateAt`; no second mutable-head read. Only sites need the
previous converged declarations. Missing/corrupt required objects are explicit failures, not
empty results. Catch synchronous boundary failures as sanitized problems; preserve cancellation.

Reuse verified scope decodes by digest and reuse the sorted projection when its accepted revision
vector (plus every converged revision used by the response, including site and grant state) is unchanged. Head transaction/claim churn
must not force every object to decode again. Bind cache keys to the store/context and schema
version. Start with 64 MiB charged cache storage, eight concurrent hydration workers per process,
and 32 admitted state requests; reject excess work promptly with 503 `server_busy` and
`Retry-After`. Coalesce concurrent loads of the same immutable digest, cancel failed work, release
waiters, and never cache errors as empty data. Eviction or restart affects cost only. An item too
large for the cache is processed within the request limit without permanently retaining it.
No persistent index, background reconciliation or TTL-cached mutable head is needed.

Use a ten-second total handler deadline covering admission, current ownership/head reads,
credential refresh, hydration, projection and strict response encoding. Do not stack fresh
ten-second timeouts on each operation. Dependency timeout is 503 `store_timeout`, with
`retryable: true`; corruption/unsupported stored schema is 503 `store_invalid`, non-retryable;
unexpected internal failure is sanitized 500. Close cancelled network work and do not start
unbounded retries. EP-196 must accept cancellation within this budget even though the existing
SDK attempt timeout is twenty seconds.

Cache a response's strong ETag as the hash of its exact encoded bytes, with representation
selection (route/query/media type and serving contract/build identity) in its cache key. Dynamic
200s include `Nagare-Head-Revision`, an opaque digest of the canonical checked head and binding;
that identifies snapshot equality across routes, independently of ETag. Build version and
OpenAPI use their own bytes/build identity and have no inventory snapshot header. A cache hit
can answer 304 after a fresh successful head check and validated request without rehydration;
on a cache miss, build and validate the representation first. Never turn a missing scope,
malformed cursor, unavailable store or failed authorization into 304, including for `*`.
Implement list-valued and weak-tag `If-None-Match` comparison for GET/HEAD. A 304 has no body and
retains the relevant cache/validator/snapshot headers. Protected responses use
`Cache-Control: private, no-cache` and `Vary: Authorization, Cookie, Accept`; errors use
`no-store`. Preserve these through the gateway. Every admission, including conditional requests,
passes gateway authorization (subject to its documented decision TTL).

Use `ErrorFormatters` plus a narrow WAI rejection renderer for Servant-generated 405/406 and
synchronous exceptions; `ErrorFormatters` alone cannot catch all of those. Preserve `Allow` on
405 and `WWW-Authenticate` on 401. Test `Accept: application/json` receiving a typed problem
when its handler fails; MultiVerb content negotiation must not replace the intended error with
406. Support HEAD as GET headers/status without a response body and test that behavior.
The problem-body guarantee covers responses produced by Nagare's gateway/server before response
commit; disconnects and infrastructure-generated errors cannot be guaranteed to contain JSON.

### M3 — operability and measurable acceptance

Mount `servant-health`. Liveness does no store IO. Readiness checks a fresh bound store head
under a one-second deadline, without loading scopes; its structured health failure body is a
probe contract, not an RFC 9457 application error. Allow normal cold startup with a startup
probe; store outages make readiness fail without repeatedly restarting a live process.
Telemetry and one bounded JSON request log per request (excluding probes) must not block the
request on a collector. Record route, status, duration, store calls/cache misses and deadline
outcomes, never tokens, cookies, native scope bytes or high-cardinality IDs as metric labels.

Add Hurl files per route family under `cli/nagare-api-server/hurl/`, `just api-hurl` and its
`scripts/audit-managed-commands.py` registration. Assert statuses, media types, conditional and
HEAD semantics, and actual generated-client decoding. Use the test store's read counter and
controllable delays to prove costs, not only wall-time assertions against a fast local disk.


## Validation and Acceptance

At least 250 scopes and 2,500 declarations, including protected/preview sites, publications,
user/team grants, a grant whose route is retired, and differing accepted/converged sites, form
the deterministic fixture. Head/scopes requests perform zero scope-object reads. A warm list
reads a fresh head but fetches/decodes zero unchanged scopes; a conditional warm hit avoids
projection and body encoding. Changing one scope fetches only changed required digests;
transaction-only head changes preserve cached scope decodes. Instrument exact object operations:
one logical GCS object read currently means metadata plus generation-pinned media, not one
HTTP round trip. No history listings or subprocesses are allowed.

On the already-built binary, record cold initialization separately from 100 warm requests at
concurrency eight for head and a page of each list. On the local fixture, warm p95 is below
250 ms; on EP-198's representative GCS deployment through the gateway, warm p95 is below two
seconds. A cold full fixture request must succeed within the ten-second handler deadline.
Record counts, response sizes, binary revision and runtime limits so the result is interpretable;
these are acceptance targets, not measurements already achieved. The default deployment has
512 MiB memory limit, and fixture load must remain below it without unbounded cache growth.

A fake remote store with 20 ms per HTTP operation proves bounded parallel cold hydration. A
hung token/head/object read returns a problem within ten seconds plus 500 ms scheduling tolerance,
readiness within one second plus tolerance, and liveness stays responsive. A failed shared load
must not deadlock subsequent requests. Repeat warm checks with head churn and an unavailable
collector. One unavailable/corrupt unrelated scope does not break the head/scopes routes; a
route requiring it fails explicitly. A matching ETag with an unknown route, malformed query,
missing scope, changed binary or unavailable store must not incorrectly return 304.

Run focused package tests, `just api-hurl`, `just haskell-style-check` and `just gate-fast`.
EP-198 confirms the same path with real gateway auth, network policy and GCS. Fix failures in the
owning milestone; do not call a paginated response or a per-operation timeout proof of promptness.


## Interfaces and Dependencies

EP-192 M1 owns shared DTO foundations and pure version/scope/publication projection. EP-193 M1
owns the checked-head/hydration API, site projection and converter. EP-196 supplies a cancellable,
read-only service session; it is soft until cloud integration. EP-197 owns request/caching policy,
HTTP routes, `HeadSummary`/`Grant`, OpenAPI generation and local cost/latency evidence. EP-198
owns image/runtime resource limits, protected routing, gateway errors, and native confirmation.
No dependency on EP-192's later mutating CLI documents is introduced.

The validator and conditional rules follow [RFC 9110 sections 8.8 and 13](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8).
The problem format, extension members and `about:blank` titles follow
[RFC 9457](https://www.rfc-editor.org/info/rfc9457/). These specify protocol semantics; the latency
budgets above are Nagare acceptance choices.


## Outcomes & Retrospective

M1–M3 pass offline: the route types and one artifact, the server over the recorded reader, the
access line, the Hurl suite and the local measurement. The gateway, GCS and network-policy
confirmation is EP-198's.
