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
---

# Serve Nagare's recorded state through a read-only admin API

This MasterPlan coordinates the work; the registry owns child status, and each child owns its
milestones. Under the operator's rules (CLAUDE.md, 2026-10-10), the plans hold deliverables with
pass/fail evidence and a dated Decision Log, and nothing else is narrated.


## Vision & Scope

When this is done, every Nagare context runs an admin API inside its cluster. A person signed in
through the context's existing login, and granted access to the API's hostname, can read what
Nagare has recorded over HTTP: the platform version, the accepted and converged scopes and
whether a transaction is open, the recorded sites, the image publications and the access grants.
The API is the backend for a future admin UI, and Kotei may read from it. Every response body is
described by one generated OpenAPI 3.1 document, `docs/api/openapi.json`, and every error is an
RFC 9457 problem document.

The API is **read-only** (operator decision, 2026-10-14). It never plans, applies, resumes or
closes a transaction, and it holds no credential that can change a context. Changes stay with
`nagarectl` on an operator's machine, as reviewed transactions.

Included: the shared document contract (types, schemas, problem details) used by both the CLI
and the API; reading the inventory store from inside the cluster; the Servant service and its
OpenAPI document; packaging and running it in a context behind the existing access gateway; and
the native proof on a disposable local context and then the intranet.

Excluded: the admin UI itself; any mutating endpoint; live provider observation that needs cloud
or Pulumi credentials (Pulumi stack reads, Cloud DNS, certificate issuance state); backup
freshness and certificate views, which read the cluster and are a follow-up; programmatic
clients without a browser session (Kotei's service-to-service access is a later decision); and
any change to how reviews are made or applied.


## Decomposition Strategy

Five work streams, split by the boundary each one owns:

1. **The document contract** (EP-192). Types, schemas and the problem-details shape, used by the
   CLI now and the API later. It already exists as a plan for Kotei; it is re-scoped as this
   initiative's foundation, because two contracts (one for the CLI, one for HTTP) would drift.
2. **Recorded sites** (EP-193). A store-only query listing recorded sites. It is already planned;
   it joins as the first new read document.
3. **Reading the store from the cluster** (EP-196). Today only an operator's machine can open the
   store: the GCS reader takes its token and its ownership proof from the `gcloud` CLI. A service
   needs a credential and a reader of its own, and that credential is the initiative's main
   security decision.
4. **The Servant service** (EP-197). Routes, handlers, the generated OpenAPI document, health,
   telemetry, logging and the Hurl suite, all per the haskell-jitsurei API standards. It can be
   built and tested entirely offline against a local store.
5. **Running it in a context** (EP-198). Image, inventory-managed deployment in `nagare-system`,
   the protected hostname and admin grant, the release transition, and the native runs.

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
| 192 | Publish Nagare's versioned document contract for Kotei and the read-only admin API | [EP-192](../plans/192-publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes.md) | None | None | Not Started |
| 193 | List recorded sites without live provider observation | [EP-193](../plans/193-list-recorded-sites-without-live-provider-observation.md) | EP-192 M1 (for its M2 only) | None | Not Started |
| 196 | Read the inventory store from an in-cluster service identity | [EP-196](../plans/196-read-the-inventory-store-from-an-in-cluster-service-identity.md) | None | None | Not Started |
| 197 | Serve the read documents through a typed Servant admin API | [EP-197](../plans/197-serve-the-read-documents-through-a-typed-servant-admin-api.md) | EP-192 M1 | EP-193, EP-196 | Not Started |
| 198 | Run the admin API in each context behind an admin grant | [EP-198](../plans/198-run-the-admin-api-in-each-context-behind-an-admin-grant.md) | EP-196, EP-197 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled, Held.


## Dependency Graph

EP-192 M1 comes first. It creates the `nagare-contract` package: the document types, their
`ToSchema` instances, the RFC 9457 `ProblemDetails` type and its catalog, and the generated
`docs/api/openapi.json` holding their component schemas. EP-193's M2 (the `site-list` document)
and all of EP-197 build on those types, so both name EP-192 M1 as a hard dependency. EP-193's M1
(the query) and EP-196 start immediately and run in parallel with EP-192.

EP-197 serves sites once EP-193's query exists, and reads a GCS store once EP-196 exists. Until
then it serves the other endpoints and tests against a local directory store, so both are soft
dependencies. EP-198 needs a reader that works in the cluster (EP-196) and a service to run
(EP-197), so both are hard dependencies.

Suggested order: EP-192 M1 → (EP-193, EP-196, EP-197 in parallel) → EP-198. EP-192's later
milestones (the CLI `--contract 1` commands for Kotei) proceed alongside and do not block the API.


## Integration Points

- **Document types and the problem shape.** Owner: EP-192. The `nagare-contract` package
  (`cli/nagare-contract`) holds `Nagare.Contract.V1` (every document and item type, with `ToJSON`,
  `FromJSON` and `ToSchema` derived through one shared aeson `Options` per type) and
  `Nagare.Contract.Problem` (`ProblemDetails`, the `ProblemJSON` content type and the problem
  catalog). It depends on nothing from Nagare, so a client (Kotei, a UI's generated client) can
  depend on it alone. EP-193 adds `SiteSummary` and the `site-list` document there, and EP-197
  adds `Grant`; EP-197 returns the item types inside Relay `Connection`s. Projections from internal values stay in `nagarectl`
  (`Nagare.Contract.Project`), owned by EP-192 and extended by EP-193.
- **Item types versus list documents.** Owner: EP-192. Each list is an item type (`ScopeState`,
  `SiteSummary`, `Publication`, `Finding`, `Grant`) plus a CLI list document that wraps a plain
  array. The API returns the same item type inside a Relay `Connection`
  (`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`). Neither may define its own item
  shape.
- **`docs/api/openapi.json`.** Owner: EP-192 until EP-197 M1 lands, then EP-197. EP-192 writes it
  from an executable as a components-only document (every contract schema, no paths). EP-197
  moves the generator to the API package: `toOpenApi` of the served route type, plus every
  contract schema the routes do not reach (the CLI-only operation documents). It stays one file,
  and a test in each owning package fails when the checked-in file differs from the generated one.
- **The problem catalog.** Owner: EP-192. Every `code` the CLI or the API can emit is a catalog
  entry with a fixed status and title. EP-196 adds store codes it introduces; EP-197 adds HTTP-only
  codes (for example `not_found`). No other plan writes a problem body by hand.
- **The store reader.** Owner: EP-196. A read-only `openServiceStore` in the `nagarectl` library
  that opens a context's GCS store with a service credential and the same ownership guarantee as
  the operator path, and never writes. EP-197 calls it; EP-198 supplies its configuration.
- **The access grant for the API's hostname.** Owner: EP-198. The API's hostname is a protected
  host under ADR 29; reading requires an ordinary reviewed `access grant` on that hostname. EP-197
  only trusts the identity headers `nagare-access` sets and never checks grants itself.

Candidate ADRs at completion: the API is read-only and holds no mutating credential; the service
credential model chosen in EP-196; one contract package shared by the CLI and the API.


## Progress

No child started. The first gate is EP-192 M1 (`nagare-contract` with the generated components
document), which unblocks EP-193 M2 and EP-197. EP-196 M1 (the credential decision) is the first
operator decision point.


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
</content>
</invoke>
<invoke name="Bash">
<parameter name="command">cd /Users/shinzui/Keikaku/bokuno/nagare; grep -rn "requireLogin" docs/user/*.md | head -3; grep -rn "access grant" docs/user/*.md | head -3; command ls cli/nagarectl/src/Nagare/Inventory/ | grep -i -E "platform|auth|scope" | head; grep -rn "nagare-access" cli/nagarectl/src/Nagare/Inventory/*.hs -l | head -5