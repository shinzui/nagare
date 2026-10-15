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
---

# Serve Nagare's recorded state through a read-only admin API

This MasterPlan coordinates the work; the registry owns child status, and each child owns its
milestones. Under the operator's rules (CLAUDE.md, 2026-10-10), the plans hold deliverables with
pass/fail evidence and a dated Decision Log, and nothing else is narrated.


## Vision & Scope

When this is done, every Nagare context runs an admin API inside its cluster at
`https://admin.<base domain>/v1/…`. A person signed in through the context's existing login, and
granted access to that hostname, can read what Nagare has recorded over HTTP: the platform
version, the head (its generation and whatever is open on it: a transaction, an executor claim, a
data fence, a migration, a release transition), the accepted and converged scopes, the recorded
sites, the image publications and the access grants. Every response body is described by one
generated OpenAPI 3.1 document, `docs/api/openapi.json`, served at `/v1/openapi.json`, and every
error, the gateway's included, is an RFC 9457 problem document.

Two clients are designed for from the start, because both are committed (operator, 2026-10-14):

- **The admin UI** the operator will build. It is served from the API's own origin
  (`admin.<base domain>`; the path `/` is reserved for it), so the browser never makes a
  cross-origin request, the gateway needs no CORS handling, and the parent-domain session cookie
  works unchanged. Its client code is generated from `/v1/openapi.json`, not hand-written.
- **Kotei**, as a machine client. Kotei is a Shomei service account (OAuth2 client credentials at
  Shomei's `/oauth/token`) presenting its access token as `Authorization: Bearer`. Nothing new is
  needed for that: `nagare-access` already accepts a bearer token when no session cookie is
  present (`cli/nagare-access/src/Nagare/Access/Credential.hs`), verifies issuer, audience and
  signature exactly as for a cookie (`Nagare/Access/Shomei.hs`), and Shomei mints every access
  token with its one configured audience; the gateway then checks the ordinary per-host grant on
  the account's `user_…` subject, which `nagarectl access grant --user` accepts. Over the API Kotei
  reads publications, scope state (accepted versus converged, so "has my deploy landed"), the
  head and the recorded sites. Deploys stay on the CLI (the API is read-only), and drift stays on
  `inventory status --contract 1` because it needs observed findings, which v1 does not serve.

The API is **read-only** (operator decision, 2026-10-14). It never plans, applies, resumes or
closes a transaction, and it holds no credential that can change a context. Changes stay with
`nagarectl` on an operator's machine, as reviewed transactions.

Included: the shared document contract (types, schemas, problem details) used by the CLI, the
API and the gateway; one recorded-state reader that every read document and every handler
projects from; reading the inventory store from inside the cluster; the Servant service and its
OpenAPI document; packaging and running it in a context behind the existing access gateway, with
the gateway as the only network path to it and the gateway's own refusals rendered as problem
documents; and the native proof on a disposable local context and then the intranet.

Excluded: the admin UI's code (a later plan; this one only reserves its origin); any mutating
endpoint; live provider observation that needs cloud or Pulumi credentials (Pulumi stack reads,
Cloud DNS, certificate issuance state); observed Kubernetes state (findings, backup freshness,
certificates), which the API can observe from inside the cluster with a read-only service account
and is the natural follow-up, as an additive resource beside the recorded ones; and any change to
how reviews are made or applied.


## Decomposition Strategy

Five work streams, split by the boundary each one owns:

1. **The document contract** (EP-192). Types, schemas and the problem-details shape, used by the
   CLI now and the API later. It already exists as a plan for Kotei; it is re-scoped as this
   initiative's foundation, because two contracts (one for the CLI, one for HTTP) would drift.
2. **The recorded-state reader and recorded sites** (EP-193). One total, read-only reader of the
   store (head once, every accepted scope by digest, never refusing because something is open on
   the head) that every read document and every API handler projects from, and the first
   projection over it: the recorded sites. It was already planned as a store-only query; its
   loader is promoted to the initiative's one read model, because four readers (one per
   document) would return four different snapshots inside one request.
3. **Reading the store from the cluster** (EP-196). Today only an operator's machine can open the
   store: the GCS reader takes its token and its ownership proof from the `gcloud` CLI. A service
   needs a credential and a reader of its own, and that credential is the initiative's main
   security decision.
4. **The Servant service** (EP-197). Routes, handlers, the generated OpenAPI document, health,
   telemetry, logging and the Hurl suite, all per the haskell-jitsurei API standards. Each
   request reads one recorded state and projects from it. It can be built and tested entirely
   offline against a local store.
5. **Running it in a context** (EP-198). Image, inventory-managed deployment in `nagare-system`
   as a plain Deployment whose NetworkPolicy admits only the gateway, the protected hostname and
   its grant, the gateway's problem-document rendering for API-shaped requests, the release
   transition, and the native runs (browser session, service-account bearer, and the bypass
   proof).

Splitting 3 from 4 keeps the security-sensitive credential work reviewable on its own and lets the
service be built in parallel against a local store. Splitting 5 from 4 keeps the native runs
(which per ADR 25 only confirm) out of the code plans. A single "API" plan was rejected: it would
mix a credential decision, a library, and a cloud deployment in one checklist.

Relevant ADRs:

- [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md): production Haskell
  follows haskell-jitsurei. Its API family applies here:
  `mori://shinzui/haskell-jitsurei/docs/api-overview` and the documents it lists (Servant routes,
  RFC 9457 problem details, OpenAPI from types, Hurl, Relay pagination, OpenTelemetry, request
  logging, health endpoints).
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): the
  inventory store, scopes, heads and the rule that decoding JSON never grants authority.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) and
  [ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md):
  protected hostnames, per-host grants and the `nagare-access` gateway, which the API sits behind.
- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): the
  project guardrail; the API's reader must stay bound to its own context's project.
- [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md):
  platform versions; a new platform component reaches existing contexts through a release
  transition (EP-172).
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): native
  runs confirm; defects are found offline first.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 192 | Publish Nagare's versioned document contract for Kotei and the read-only admin API | [EP-192](../plans/192-publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes.md) | EP-193 M1 (for its M4 only) | None | Not Started |
| 193 | List recorded sites without live provider observation | [EP-193](../plans/193-list-recorded-sites-without-live-provider-observation.md) | EP-192 M1 (for its M2 only) | None | Not Started |
| 196 | Read the inventory store from an in-cluster service identity | [EP-196](../plans/196-read-the-inventory-store-from-an-in-cluster-service-identity.md) | None | None | Not Started |
| 197 | Serve the read documents through a typed Servant admin API | [EP-197](../plans/197-serve-the-read-documents-through-a-typed-servant-admin-api.md) | EP-192 M1, EP-193 M1 | EP-196 | Not Started |
| 198 | Run the admin API in each context behind an admin grant | [EP-198](../plans/198-run-the-admin-api-in-each-context-behind-an-admin-grant.md) | EP-196, EP-197 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled, Held.


## Dependency Graph

EP-192 M1 creates the `nagare-contract` package: the document types, their `ToSchema` instances,
the RFC 9457 `ProblemDetails` type and its catalog, and the generated `docs/api/openapi.json`
holding their component schemas. EP-193 M1 creates the recorded-state reader,
`Nagare.Inventory.Recorded`, and the sites projection over it. Neither depends on the other, and
EP-196 depends on neither, so all three start at once.

EP-193 M2 (the `site-list` document) needs EP-192 M1's types. EP-192 M4 (`inventory
publications`) reads through EP-193 M1's reader, so that one milestone has EP-193 M1 as a hard
dependency; the rest of EP-192 has none. EP-197 M1 (routes and the document) needs EP-192 M1;
EP-197 M2 (handlers) needs EP-193 M1, since every handler projects from one `RecordedState` and
the sites route is a projection it serves from the first day rather than a placeholder. EP-197
reads a GCS store once EP-196 exists and a local directory store until then, so EP-196 is soft.
EP-198 needs a reader that works in the cluster (EP-196) and a service to run (EP-197), so both
are hard dependencies.

Suggested order: (EP-192 M1, EP-193 M1, EP-196) in parallel → EP-197 → EP-198. EP-192's later
milestones (the CLI `--contract 1` commands for Kotei) proceed alongside and do not block the API.


## Integration Points

- **Document types and the problem shape.** Owner: EP-192. The `nagare-contract` package
  (`cli/nagare-contract`) holds `Nagare.Contract.V1` (every document and item type, with `ToJSON`,
  `FromJSON` and `ToSchema` derived through one shared aeson `Options` per type) and
  `Nagare.Contract.Problem` (`ProblemDetails`, the `ProblemJSON` content type and the problem
  catalog). It depends on nothing from Nagare, so a client (Kotei, a UI's generated client, the
  gateway) can depend on it alone. EP-193 adds `SiteSummary` and the `site-list` document there,
  and EP-197 adds `Grant` and `HeadSummary`; EP-197 returns the item types inside Relay
  `Connection`s. Projections from internal values stay in `nagarectl` (`Nagare.Contract.Project`),
  owned by EP-192 and extended by EP-193 and EP-197.
- **Item types versus list documents.** Owner: EP-192. Each list is an item type (`ScopeState`,
  `SiteSummary`, `Publication`, `Finding`, `Grant`) plus a CLI list document that wraps a plain
  array. The API returns the same item type inside a Relay `Connection`
  (`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`). Neither may define its own item
  shape.
- **The recorded-state reader.** Owner: EP-193 M1. `Nagare.Inventory.Recorded` in the `nagarectl`
  library exports `RecordedState` (the head plus every accepted scope declaration, digest-checked
  and bound to the context) and `readRecordedState :: InventoryStore -> IO (Either StoreError
  RecordedState)`. It reads the head exactly once, loads no journal, review archive or
  retained/collected history, and never refuses because a transaction, claim, fence, migration or
  transition is open: those are facts it returns. Every read document (EP-192's `inventory
  publications`; EP-193's sites) and every EP-197 handler is a pure projection from one
  `RecordedState`, read once per command or request. `loadTargetSnapshotReadOnly`
  (`cli/nagarectl/src/Nagare/Inventory/Command.hs`) stays for planning; it exits the process and
  refuses an open transaction, so no read document may use it.
- **`docs/api/openapi.json`.** Owner: EP-192 until EP-197 M1 lands, then EP-197. EP-192 writes it
  from an executable as a components-only document (every contract schema, no paths). EP-197
  moves the generator to the API package: `toOpenApi` of the served route type, plus every
  contract schema the routes do not reach (the CLI-only operation documents), plus the two
  security schemes (the `nagare_session` cookie and HTTP bearer) applied to every operation. It
  stays one file, served unchanged at `/v1/openapi.json`, and a test in each owning package fails
  when the checked-in file differs from the generated one.
- **The problem catalog.** Owner: EP-192. Every `code` the CLI, the API or the gateway can emit is
  a catalog entry with a fixed status and title. EP-196 adds store codes it introduces; EP-197
  adds HTTP-only codes (for example `not_found`); EP-198 adds the gateway's `unauthenticated`
  (401), `forbidden` (403) and `authorization_unavailable` (503, retryable). No plan writes a
  problem body by hand; `cli/nagare-access` takes `nagare-contract` as a dependency the way it
  already takes `nagare-dsl` (its own `cabal.project` and Dockerfile).
- **The store reader.** Owner: EP-196. A read-only `openServiceStore` in the `nagarectl` library
  that opens a context's GCS store with a service credential and the same ownership guarantee as
  the operator path, and never writes. EP-197 calls it; EP-198 supplies its configuration.
- **The identity the service sees.** Owner: EP-198. The service reads `X-Forwarded-User` (a
  Shomei `user_…` id, for a person or a service account) for logs and traces only and makes no
  access decision. That is sound only because EP-198 makes the gateway the sole network path: the
  API is a plain Deployment behind a ClusterIP Service whose NetworkPolicy admits ingress from the
  `nagare-access` pods alone. (A Knative Service cannot be pinned that way: every cluster-local
  Knative route is reachable from every pod through the shared ingress and activator.)
- **The hostname, origin and grant.** Owner: EP-198. `admin.<base domain>` is a protected host
  under ADR 29, wired like any protected site (backend-map contribution, DomainMapping to the
  enforcer; the upstream `http://admin-api.nagare-system.svc.cluster.local` that `upstreamFor` in
  `cli/nagarectl/src/Nagare/Access/Resolve.hs` builds resolves to the plain Service as well).
  Reading requires an ordinary reviewed `access grant` on that hostname, for a person or for
  Kotei's service account. The API owns `/v1/…` and `/v1/openapi.json`; `/` is reserved for the
  admin UI, which a later plan serves from the same origin and image.
- **The gateway's answers to API-shaped requests.** Owner: EP-198. `nagare-access` already
  classifies a request as JSON-shaped (`Accept` containing `application/json`, `Sec-Fetch-Mode`
  `cors` or `same-origin`, or `X-Requested-With: XMLHttpRequest`;
  `cli/nagare-access/src/Nagare/Access/Challenge.hs`) and answers 401 JSON instead of a redirect.
  EP-198 widens the classifier to any `+json` media type and renders those 401, 403 and 503
  bodies as `application/problem+json` from the catalog, keeping the existing `error` and `login`
  members as RFC 9457 extension members so nothing that reads them breaks.

Candidate ADRs at completion: the API is read-only and holds no mutating credential; the service
credential model chosen in EP-196; one contract package shared by the CLI, the API and the
gateway; one recorded-state reader for every read; the gateway is the only network path to a
platform service that makes no access decision; machine clients are Shomei service accounts with
ordinary per-host grants (amending ADR 29's "machine access" exclusion).


## Progress

No child started. Reviewed 2026-10-14 for the two committed clients (the admin UI and Kotei); the
Decision Log holds what changed. The first gates are EP-192 M1 (`nagare-contract` with the
generated components document) and EP-193 M1 (the recorded-state reader), which together unblock
EP-197. EP-196 M1 (the credential decision) is the first operator decision point.


## Decision Log

- 2026-10-14 (operator): The admin API is read-only. EP-192 becomes the shared contract for the CLI
  and the API, and joins this MasterPlan with EP-193.
- 2026-10-14 (operator): The API follows the haskell-jitsurei API standards: `NamedRoutes`,
  `MultiVerb` with declared error statuses, RFC 9457 problem documents, the OpenAPI 3.1 document
  derived by `toOpenApi` with the released `openapi-hs` / `servant-openapi-hs` cohort and never
  hand-written, Relay pagination for growing lists, `servant-health` probes, OpenTelemetry and
  bounded request logging, and a Hurl suite. This supersedes EP-192's 2026-10-13 decision to
  hand-write JSON Schemas and validate them with a test-local subset validator.
- 2026-10-14: The API reads only the inventory store and what it can observe in-cluster with its
  own read-only identity. It needs a `gcs` inventory store; a local-mode context keeps its store
  on the operator's machine, so local runs serve the API from the workstation against that store
  (EP-197, EP-198).
- 2026-10-14: Authentication and authorization come from the existing `nagare-access` gateway and
  a reviewed per-host grant (ADR 29). The API adds no login of its own.
- 2026-10-14 (review for the admin UI and Kotei): One recorded-state reader. EP-193 M1's loader
  becomes `Nagare.Inventory.Recorded`, the read model for every read document and every API
  handler; EP-192 M4 and EP-197 M2 project from it. `loadTargetSnapshotReadOnly` is planning-only:
  it calls `dieText` and refuses an open transaction, so a service built on it would exit, or
  answer nothing, exactly when an operator most needs to look.
- 2026-10-14 (review): The hostname is `admin.<base domain>`, one origin for the API (`/v1/…`,
  `/v1/openapi.json`) and the later UI (`/`). A UI on a second hostname would need CORS preflights
  through the gateway, which answers an unauthenticated `OPTIONS` with a challenge; sharing the
  origin removes the problem instead of handling it.
- 2026-10-14 (review): Kotei's access is a Shomei service account presenting a bearer token
  through the gateway, granted on the hostname like a person. Verified against the code: the
  gateway's credential extraction, its token verification (issuer, audience, signature; no session
  kind check) and Shomei's single configured audience. This supersedes "Kotei's service-to-service
  access is a later decision" and amends ADR 29's "machine access" exclusion at completion.
- 2026-10-14 (review): The API runs as a plain Deployment and ClusterIP Service with a
  NetworkPolicy admitting ingress only from the `nagare-access` pods (precedent:
  `cluster/bootstrap/nix-cache/`), not as a Knative Service. The service makes no access decision,
  so the gateway must be its only path; a cluster-local Knative route is reachable from every pod
  through the shared ingress, which would make "the service trusts `X-Forwarded-User`" unsound.
  The same choice lets a local context mount the store directory read-only without a Knative
  feature flag.
- 2026-10-14 (review): The gateway's 401, 403 and 503 for JSON-shaped requests on protected hosts
  are problem documents from the shared catalog, with the existing members kept as extensions.
  Otherwise the UI and Kotei would decode three error dialects (gateway JSON, gateway HTML, API
  problem).
- 2026-10-14 (review): Every API response carries the head generation it was read from as a
  strong `ETag`, and `If-None-Match` answers 304, so a polling UI is cheap and a client can tell
  when two responses came from different heads. Cursors are keyset cursors over the item's unique
  id and stay valid across heads; the planned `stale_cursor` refusal is dropped, because it would
  make a UI restart a list on every deploy for no consistency gain the `ETag` does not already give.
- 2026-10-14 (review): `/v1/inventory/head` serves a `HeadSummary` (generation, sequence, active
  transaction, executor claim, data fence phase, migration, open release transition) instead of a
  bare "is a transaction open". An operator looking at a stuck context needs all of them; they
  are in `HeadManifest` already, and adding them later would be a second endpoint for one object.
- 2026-10-14 (review): EP-197 serves the sites route from EP-193's projection from its first
  landing; the planned 503 `not_ready` placeholder is dropped, so the contract never publishes a
  route that does not work.
- 2026-10-14 (review): On EP-196's credential, the exposure class of option 1 (a grant to the node
  service account is readable by every pod) already exists for the backup bucket, which holds
  database dumps under `roles/storage.objectAdmin`. Option 1 adds no new class; option 3 (block the
  metadata server outside `nagare-system`) closes the class for both and goes to the deferral
  ledger with the operator's approval. M1's stop condition (plaintext secret material in scope
  objects) stands.
</content>
</invoke>
<invoke name="Bash">
<parameter name="command">cd /Users/shinzui/Keikaku/bokuno/nagare; grep -rn "requireLogin" docs/user/*.md | head -3; grep -rn "access grant" docs/user/*.md | head -3; command ls cli/nagarectl/src/Nagare/Inventory/ | grep -i -E "platform|auth|scope" | head; grep -rn "nagare-access" cli/nagarectl/src/Nagare/Inventory/*.hs -l | head -5