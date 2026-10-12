---
id: 57
slug: cloudflare-cdn-provisioning-via-api-in-nagarectl
title: "Cloudflare CDN provisioning via API in nagarectl"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Cloudflare CDN provisioning via API in nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a single-node personal Platform-as-a-Service. "Single-node" means the whole
platform runs on exactly one Google Cloud virtual machine named `nagare-01` in the GCP
project `tan-nb-exp`, region `us-west1`. A developer describes an app or a website in a
typed Haskell configuration file and runs one command (`nagarectl ...`) to deploy it.

This plan delivers the **Cloudflare provider capability**: a new Haskell module inside the
`nagarectl` command-line tool that talks to Cloudflare's public REST API to put a Cloudflare
edge (a globally distributed cache and reverse proxy) in front of the one VM. "Cloudflare"
here is a third-party CDN service: when you point a hostname's DNS at Cloudflare with the
"proxied" flag turned on, visitors hit a nearby Cloudflare data center, which serves cached
content directly and forwards cache-misses to the VM (the "origin"). A "CDN" (Content
Delivery Network) is exactly that globally distributed cache-in-front-of-an-origin.

After this plan, the `nagarectl` library contains a single module,
`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`, that can: create-or-update a proxied DNS
record so a hostname resolves to Cloudflare and forwards to the VM's public IP; apply a set
of cache rules (a default edge time-to-live plus per-path overrides, where one path can be
marked "never cache"); set the "origin-TLS mode" (how Cloudflare's edge connects back to the
VM — plaintext or encrypted); and purge the edge cache after a deploy so visitors stop
seeing stale content. The module reads its credential (a scoped Cloudflare API token) from
an environment variable and never logs it.

What you can observe when this plan is done. First, a unit-test transcript: running
`cabal test` in `cli/nagarectl` exercises pure functions that build the exact JSON request
bodies Cloudflare expects, and the tests assert those bodies byte-for-byte — so you can read
the test output and see, for example, a `Cdn` configuration with a one-year `/assets/` rule
and a never-cache `/api/` rule turn into a concrete Cloudflare ruleset. Second, a deferred
live demonstration (gated on a real Cloudflare zone, a real token, and the powered-on VM):
a recorded `curl` transcript showing a proxied DNS record created and a second request to the
same URL returning the HTTP response header `CF-Cache-Status: HIT`, which is Cloudflare's
proof that the response came from the edge cache rather than the origin.

This module is the hard contract that a sibling plan,
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` (EP-58), calls at
deploy time. EP-58 does not re-implement any Cloudflare logic; it imports the five functions
this plan exports. This plan introduces the outbound-HTTP capability into the CLI for the
first time (the CLI has no HTTP-client dependency today), and confines every Cloudflare call
to this one module.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Add `http-client` and `http-client-tls` to the `nagarectl.cabal` library
  `build-depends`, and expose the new module `Nagare.Cdn.Cloudflare`.
- [x] Milestone 1 — Create `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` with the credential,
  origin-TLS, and result types plus the pure request-builders
  (`buildUpsertRecordPayload`, `buildCacheRulesPayload`, `buildPurgePayload`,
  `sslModeToken`, `zoneNameFromHostname`, the Cloudflare-envelope parsers).
- [x] Milestone 1 — Add a `Nagare.Cdn (EP-57)` test group to `cli/nagarectl/test/Spec.hs`
  asserting the exact JSON payloads (default-TTL + `/assets/` + never-cache `/api/` +
  static-asset caching), the SSL-mode mapping, purge-all vs purge-paths, the envelope parsing,
  and `parseZoneId`/`parseDnsRecordId` (both list and single-object shapes).
- [x] Milestone 1 — `cd cli/nagarectl && cabal test` passes (237 total, +11 in `Nagare.Cdn`);
  EP-55's `Nagare.Dsl.Cdn.Types` is merged, so it is imported directly (no stand-in needed).
- [x] Milestone 2 — Implement the five IO functions (`loadCloudflareCreds`,
  `upsertProxiedRecord`, `applyCacheRules`, `setOriginTlsMode`, `purgeHostname`) on top of the
  pure builders, with find-or-create idempotency (`parseDnsRecordId` made robust to both the
  list-find and the single-object create responses) and `Either Text` totality via a shared
  `cfRequest`/`withZone`/`sendUnit`.
- [x] Milestone 2 — The manual live-validation runbook (token scopes, env vars, the
  `curl` transcript showing `CF-Cache-Status: HIT`) is in Validation & Acceptance; the live leg
  is deferred/manual (no Cloudflare account/token in CI; VM off).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The plan's `parseDnsRecordId` (reading `result.id`) does not detect an existing record in
  `upsertProxiedRecord`'s find step: `GET /zones/{zone}/dns_records?name=...` returns `result` as
  an **array**, so `result.id` is always absent → every deploy would POST a duplicate. Fixed by
  making `parseDnsRecordId` read `result[0].id` when `result` is an array and `result.id` when it
  is a single object, so the same parser serves both the find (list) and the create/update
  (object) responses and the find-or-create idempotency actually holds.

- `http-client` + `http-client-tls` resolve cleanly in the project's GHC 9.12 package set; the
  library compiled and `cabal test` ran 237 tests green (+11 `Nagare.Cdn`). No stand-in for the
  EP-55 model was needed — `Nagare.Dsl.Cdn.Types` is already merged and imported directly.

## Decision Log

Record every decision made while working on the plan.

- Decision: Use `http-client` + `http-client-tls` as the HTTP library, added only to the
  `nagarectl.cabal` *library* stanza, and route every Cloudflare call through
  `Nagare.Cdn.Cloudflare`.
  Rationale: The CLI today has no outbound-HTTP dependency at all (verified: no
  `http-client`/`wreq`/`req`/`servant-client` in `nagarectl.cabal`; the `nagared` executable
  uses `wai`/`warp`/`http-types` only for an *inbound* webhook server). `http-client` is the
  lowest-dependency, most widely-used Haskell HTTP client and matches the repository's
  minimalism better than the heavier `req` or `wreq`. Confining it to this one module keeps the
  outbound-HTTP blast radius to a single file, mirroring how `Nagare.Ops.Probe` confines all
  external-tool shell-outs.
  Date: 2026-06-10

- Decision: Read the Cloudflare credential from the environment variable `CF_API_TOKEN` (a
  *scoped API token*, never the account-global API key), with an optional `CF_ZONE_ID`, and
  never log the token.
  Rationale: A scoped token can be limited to exactly the permissions this module needs
  (DNS edit, cache rules, cache purge, zone settings) on exactly one zone, so a leak is far less
  damaging than the global key (which can do anything to every zone on the account). Reading from
  the environment matches the secret-handling convention already used elsewhere in the CLI and
  keeps the token out of config files and process arguments. When `CF_ZONE_ID` is absent the
  module discovers the zone from the hostname's registrable domain via the Cloudflare API, so the
  operator only has to set it when auto-discovery is ambiguous.
  Date: 2026-06-10

- Decision: Factor all URL/JSON construction into *pure* functions and unit-test those,
  mirroring `Nagare.Ops.Domains`.
  Rationale: `Nagare.Ops.Domains` separates pure JSON extractors/formatters from the thin
  `kubectl` IO so the inventory is testable without a cluster. The same split lets us assert the
  exact Cloudflare request bodies in `cabal test` with no network, no token, and no live zone —
  which is the only way to get meaningful coverage while the live leg is environment-gated.
  Date: 2026-06-10

- Decision: Apply cache behaviour through the Cloudflare **Rulesets** API — specifically the
  `http_request_cache_settings` phase entrypoint — replacing the managed ruleset wholesale on
  each apply.
  Rationale: The Rulesets engine is Cloudflare's current, account-API-token-accessible mechanism
  for per-path edge-TTL control (the older "Page Rules" product is legacy and capped at a small
  count). Writing the whole phase entrypoint in one PUT makes `applyCacheRules` deterministic and
  idempotent: the result is a function of the `Cdn` value, with no accumulation of stale rules
  across re-runs.
  Date: 2026-06-10

- Decision: `OriginTlsMode` defaults to `Flexible` until the origin serves the Let's Encrypt
  wildcard certificate on port 443, per the sibling spike
  `docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md` (EP-54).
  Rationale: `Flexible` means Cloudflare terminates client TLS at the edge and talks to the
  origin over plain HTTP, which works against today's HTTP-first Kourier origin (TLS is deferred
  in `docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md` until a real
  `baseDomain` is delegated). Once the origin presents the wildcard on 443, the operator can move
  to `Full`/`FullStrict`. EP-57 only honours whichever mode it is handed;
  `docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` (EP-58) passes the
  EP-54 default at deploy time.
  Date: 2026-06-10

- Decision: `upsertProxiedRecord` is find-or-create-then-update; `applyCacheRules` replaces the
  managed ruleset deterministically.
  Rationale: Re-running a deploy must not create duplicate DNS records or accumulate duplicate
  cache rules. Listing the record by name, then PATCHing if found or POSTing if not, makes the
  DNS write idempotent; PUTting the whole cache phase entrypoint makes the cache write
  idempotent. Both are safe to run any number of times.
  Date: 2026-06-10

- Decision: Every exported function returns `Either Text` and never throws to the caller for an
  *expected* failure (auth rejected, zone not found, Cloudflare `success:false`).
  Rationale: EP-58 composes these calls in a deploy path and needs to turn failures into a clean
  user-facing message and a non-zero exit, not a Haskell exception stack. Parsing Cloudflare's
  `{ "success": false, "errors": [...] }` envelope into a `Left Text` keeps the surface total and
  greppable, matching the tolerant style of `Nagare.Ops.Probe.captureTool`.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-10).** `Nagare.Cdn.Cloudflare` is the single outbound-HTTP surface in the CLI
(the first; `http-client`/`http-client-tls` added to the library stanza only). The five IO
functions EP-58 consumes — `loadCloudflareCreds`, `upsertProxiedRecord`, `applyCacheRules`,
`setOriginTlsMode`, `purgeHostname` — are implemented over the pure builders, total via
`Either Text`, with the token read from `CF_API_TOKEN` and never logged. The pure builders and
envelope parsers are unit-tested byte-exactly (`cabal test`: 237 total, +11 `Nagare.Cdn`),
including the worked `buildCacheRulesPayload` golden (default + `/assets/` + never-cache `/api/` +
static-asset rule, in precedence order) the plan specifies.

**Gaps / deferred.** The live leg (a real Cloudflare zone + scoped token + powered-on VM) is
deferred/manual — the runbook and the `CF-Cache-Status: HIT` proof are in Validation & Acceptance,
to be captured when an operator runs it. EP-58 wires these functions into the deploy seam and the
`nagarectl cdn` command group. One correctness fix vs the plan's draft (the array-aware
`parseDnsRecordId`) is recorded in Surprises.

