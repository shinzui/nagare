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
---

# Serve the read documents through a typed Servant admin API

Child of [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md).
Progress holds the deliverables with pass/fail evidence; the Decision Log holds dated decisions.


## Purpose / Big Picture

After this plan, Nagare has an HTTP service, `nagare-api-server`, that answers read-only questions
about one context from its inventory store: the platform version, the accepted and converged
scopes and whether a transaction is open, the recorded sites, the image publications and the
access grants. Its OpenAPI 3.1 document is generated from the route types into
`docs/api/openapi.json`, and every error is an RFC 9457 problem document. It is built and tested
offline here, against a local directory store and a fake GCS; running it inside a context is
[EP-198](198-run-the-admin-api-in-each-context-behind-an-admin-grant.md).

To see it work after this plan, start it against a local context's store and read it:

```bash
cabal run nagare-api-server -- --context local-dev --store-dir ~/.local/state/nagare/local-dev/inventory --port 8085
curl -s localhost:8085/v1/platform/version
curl -s 'localhost:8085/v1/inventory/scopes?first=2'
curl -s -i localhost:8085/v1/inventory/scopes/application:nope   # 404, application/problem+json
```


## Progress

- [ ] M1. Route types, OpenAPI document and conformance tests. Pass: package `cli/nagare-api`
  defines one `NamedRoutes` record per slice (Platform, Inventory, Sites, Publications, Access)
  with every terminal verb a `MultiVerb` over the shared problem tail; `nagare-api-openapi`
  writes `docs/api/openapi.json` (taking over the file from EP-192); tests pass that (a) the
  checked-in document equals the generated one, (b) the path set equals the served set, (c) every
  operation declares a 4xx/5xx response keyed by `application/problem+json`, and (d) every DTO's
  `ToJSON` validates against its `ToSchema` (`validateToJSON`). `just haskell-style-check` and
  `just gate-fast` green, landed.
- [ ] M2. Handlers over the store. Pass: package `cli/nagare-api-server` serves every route from
  a `StoreSource` (a local directory store, or EP-196's `openServiceStore`). In-process tests
  against fixture stores show: version; scope list paged with Relay cursors, proven by
  `relay-pagination-conformance` (no item skipped or duplicated, forward and backward); one scope
  by id and a 404 problem for an unknown one; the open transaction or none; sites (from EP-193's
  query, or the route returns 503 `not_ready` with the reason until EP-193 lands); publications;
  grants read from stored access relationships; and a 503 `store_unavailable` problem with
  `retryable: true` when the store cannot be read. Servant's own rejections (bad query, unknown
  path) render as problem documents through `ErrorFormatters`.
- [ ] M3. Operability. Pass: `/health/live` and `/health/ready` from `servant-health`, readiness
  checking only that the store head can be read; OpenTelemetry tracer and meter providers set up
  in `main` with Servant route span names, exporting to the context's collector when
  `OTEL_EXPORTER_OTLP_ENDPOINT` is set; one bounded JSON request log line per request, excluding
  probes; a Hurl suite under `cli/nagare-api-server/hurl/` run by `just api-hurl` against a
  running server over a fixture store, asserting status and media type for every request. The
  new recipe is registered in `scripts/audit-managed-commands.py` (`RECIPES`).


## Decision Log

- 2026-10-14: Two packages, per `mori://shinzui/haskell-jitsurei/docs/api-servant-routes`
  ("Packages are layers"): `nagare-api` holds route types and the OpenAPI generator and depends
  only on `nagare-contract` and Servant, so a client (an admin UI's generator input, Kotei) can
  depend on it without `nagarectl`; `nagare-api-server` holds handlers and `main` and depends on the
  `nagarectl` library. Module paths are domain-first: `Nagare/Api/<Slice>/Routes.hs` in
  `nagare-api`, `Nagare/Api/<Slice>/Handler.hs` in `nagare-api-server`.
- 2026-10-14: Lists that grow (scopes, sites, publications, grants) use Relay pagination. The data
  is one immutable head snapshot per request, not a database, so the handlers page an in-memory
  list sorted by its unique id with `relay-pagination`'s core `Cursor`, `Request` and `Connection`
  types, and prove it with `relay-pagination-conformance`; `relay-pagination-hasql` is not used.
  Each page is cut from one head read, so a page is internally consistent; a cursor carries the
  head digest it was cut from, and a cursor from an older head is refused with a 400 problem
  `stale_cursor` rather than silently mixing two snapshots.
- 2026-10-14: This plan adds the `Grant` item type (host, subject kind, subject) to the
  `nagare-contract` package, with `ToSchema` from its shared aeson `Options`, because the API is its
  first consumer. EP-192 owns the package and its catalog; additions follow its README rules.
- 2026-10-14: The service trusts `X-Forwarded-User` only as the caller's identity for logs and
  traces. Authorization is entirely the gateway's (ADR 29); the service makes no access decision.
- 2026-10-14: Versioned under `/v1`, matching contract version 1. A breaking change is `/v2` served
  beside `/v1` for one release, the same rule as `--contract`.


## Context and Orientation

**Standards.** Production Haskell follows haskell-jitsurei
([ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)). The API family is
`mori://shinzui/haskell-jitsurei/docs/api-overview`; read these before writing code:
`api-servant-routes` (NamedRoutes, MultiVerb, statuses: a failed dependency is 503 with
`retryable: true`, an internal fault is 500), `api-rfc9457-problem-details` (the problem shape,
`RespondAs ProblemJSON`, `ErrorFormatters`, the 405 limitation), `api-openapi-from-types`
(`toOpenApi`, the generator executable, the four document tests, the `ToSchema Value` instance),
`api-relay-pagination`, `api-health-endpoints`, `api-opentelemetry-integration`,
`api-request-logging` and `api-hurl-integration-testing`. Resolve each with
`mori registry docs shinzui/haskell-jitsurei`.

**Versions** (Hackage, checked 2026-10-14): `servant` and `servant-server` 0.20.3.0, `openapi-hs`
5.0.0, `servant-openapi-hs` 5.1.0, `relay-pagination`, `relay-pagination-servant` and `relay-pagination-conformance` 0.1.1.2,
`servant-health` 0.1.0.0.
Re-check Hackage and upstream tags before choosing bounds. Use `openapi-hs >=5.0 && <5.1` and
`servant-openapi-hs >=5.1 && <5.2` (one cohort). Nagare builds Haskell with nixpkgs'
`haskell.packages.ghc9124` plus overrides in `nix/haskell-packages.nix` (line 45); add a
`callHackage` override there for any of these the package set lacks, as is already done for
`generic-lens`.

**What the service reads.** Documents and items come from `nagare-contract` (`Nagare.Contract.V1`,
EP-192), built from internal values by `Nagare.Contract.Project` in the `nagarectl` library.
The store is opened read-only: a local directory store through the existing local path, or a GCS
store through `openServiceStore` from
[EP-196](196-read-the-inventory-store-from-an-in-cluster-service-identity.md). Accepted scopes come
from the head (`headAccepted`, `headConverged`, `headActiveTransaction` in
`cli/nagarectl/src/Nagare/Inventory/Store.hs`); publications from the same snapshot reader EP-192
uses (`loadTargetSnapshotReadOnly`); sites from EP-193's query; stored access relationships from
the access scope's declarations (`cli/nagarectl/src/Nagare/Inventory/Access.hs`). Nothing here
observes a provider; `inventory status`'s live findings are not served.

**Precedent.** `nagared` (`cli/nagarectl/nagared/Main.hs`) is an existing WAI/warp executable in
this repository; `cli/nagare-access` is an existing Servant-client user with a Dockerfile.


## Plan of Work

M1: create `cli/nagare-api` (library plus executable `nagare-api-openapi`) and add it to the
Cabal project and `nix/haskell-packages.nix`. Write the slice records, the shared problem tail
from `Nagare.Contract.Problem`, and `Nagare.Api.OpenApi` with the orphan instances and stable
`operationId`s. The generated document must still contain every contract schema the routes do
not reach (the CLI-only operation documents), so EP-192's components remain published: add them
with `declareSchemaRef` into `components.schemas`. Move the "checked-in equals generated" test
from `nagare-contract` to `nagare-api`.

M2: create `cli/nagare-api-server`. `Env` holds the store source and the context name. Each
handler reads the head once, projects, and pages. Write `AsUnion` instances by hand and one total
`faultToResult` per slice, per the routes standard.

M3: mount `servant-health`, set up telemetry and logging in `main` in the order the standards
give (OpenTelemetry middleware outermost, then the request logger, then the application), and
write the Hurl suite with one file per resource family.


## Validation and Acceptance

From the repository root: `just haskell-style-check`, `just gate-fast`, then for M3
`just api-hurl`. Acceptance is the Progress list; the command block in Purpose must work against
a local context.


## Interfaces and Dependencies

- Consumes `nagare-contract` (EP-192), `openServiceStore` (EP-196), the site query (EP-193).
- Produces `nagare-api` (routes, `docs/api/openapi.json`) and the `nagare-api-server` executable,
  configured by flags or environment: context name, store source, port, OTLP endpoint. EP-198
  packages and runs it.
