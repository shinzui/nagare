---
id: 55
slug: typed-cdn-model-and-provider-renderer
title: "Typed CDN model and provider renderer"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Typed CDN model and provider renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [55-typed-cdn-model-and-provider-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/55-typed-cdn-model-and-provider-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

A "CDN" (Content Delivery Network) is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to the single Nagare VM in `us-west1`, a
visitor near London or Tokyo is served a cached copy of the response from a nearby edge
location. Nagare's MasterPlan 11 (`docs/masterplans/11-cdn-integration-for-nagare.md`) adds
first-class CDN support so a developer can put their static site, their TanStack Start app, or
any generic container app behind Cloudflare or Google Cloud CDN by adding a few lines to the
same typed `nagare/Config.hs` file they already write — no separate CDN console, no
hand-written load-balancer YAML, no manual DNS edits.

This ExecPlan, EP-55, is the **shared typed contract** at the centre of that initiative: the
one piece of code every later plan reads from and writes to. It is deliberately small and
deliberately library-only. It adds, to the Haskell DSL library `cli/nagare-dsl/`, a typed
model of a CDN configuration and its JSON transport, and it attaches an optional `cdn` field
to the three top-level deployment shapes Nagare already understands (a static site, a
server-rendered site, and a generic container deployment). It renders no infrastructure and
talks to no cloud; it only lets a config author *describe* a CDN, and lets the rest of the
system *read that description back* with the same validation guarantees every other field in
the DSL already enjoys.

After this change, an author can write, in a `nagare/Config.hs`, something like
`cloudflareCdn & withDefaultTtl 3600`, attach the result to their site as `cdn = Just thatCdn`,
and the config will emit a JSON object that carries a nested `"cdn"` block. The loader will
read that block back, re-run every validation rule, and hand the rest of the system a fully
validated `Cdn` value riding inside the site record. You can *see this working entirely
offline* by running the package's test suite: `cd cli/nagare-dsl && cabal test`. The new tests
prove that a CDN with a Cloudflare provider and a 3600-second default TTL round-trips through
JSON unchanged, that a negative TTL or an empty path prefix is rejected with a precise error,
that an unknown provider token is rejected, and — crucially for backward compatibility — that a
config with no CDN emits exactly the JSON it emitted before this plan, with no `"cdn"` key at
all.

The downstream plans that consume this exact contract are EP-56 (Cloudflare provider renderer),
EP-57 (Google Cloud CDN provider renderer), and EP-58 (deploy-time CDN wiring and the
`nagarectl cdn` command group), all under `docs/plans/`. The master plan describes EP-55 as
"a shared typed contract every later plan consumes." Because three later plans depend on the
*shape* defined here, this plan implements that shape verbatim and treats it as fixed.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — the `Cdn` model: create `cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs` with
  `CdnProvider`, `CdnCacheRule`, `Cdn`, the smart constructor `mkCdnCacheRule`, the validated
  list builder `mkCacheRules`, the presets `cloudflareCdn`/`gcpCloudCdn`, and the combinators
  `withDefaultTtl`/`withCacheRule`/`withoutStaticAssetCache`.
- [x] Milestone 1 — add `Nagare.Dsl.Cdn.Types` to the `exposed-modules` of
  `cli/nagare-dsl/nagare-dsl.cabal`.
- [x] Milestone 1 — add a `CdnSpec` test module exercising the constructors, combinators, and
  presets; register it in the `.cabal` test-suite `other-modules` and wire it into `Spec.hs`.
- [x] Milestone 1 — `cd cli/nagare-dsl && cabal test` passes with the new `CdnSpec` group
  (248 tests, +13 in the `Nagare.Dsl.Cdn` group).
- [x] Milestone 2 — add `cdn :: !(Maybe Cdn)` to `StaticSite`, `ServerSite`, and `Deployment`.
- [x] Milestone 2 — emit a nested `"cdn"` object (omitted when `Nothing`) from `staticSiteJSON`,
  `serverSiteJSON`, and `deploymentJSON` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` via a shared
  `cdnJSON`; also exposed `encodeStaticSite`/`encodeServerSite` for the in-process round-trip.
- [x] Milestone 2 — add the `JsonCdn`/`JsonCdnCacheRule` mirrors and a `toCdn` validator to
  `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, wired into `decodeStaticSite`, `decodeServerSite`,
  and `decodeDeployment`.
- [x] Milestone 2 — update the fixture `Config.hs` files: the static-site fixture carries a
  Cloudflare CDN, the server-site fixture a Google Cloud CDN; the deployment fixture keeps
  `cdn = Nothing` as the backward-compat proof. All in-repo construction sites across
  `cli/nagare-dsl`, `cli/nagarectl`, and `cluster/examples` were given `cdn = Nothing`.
- [x] Milestone 2 — add round-trip, negative, and backward-compat tests in `CdnSpec`; existing
  Nginx/Knative goldens still pass (the inert field renders no infrastructure).
- [x] Milestone 2 — `cd cli/nagare-dsl && cabal test` passes (259); the emitted-JSON transcript
  reproduces exactly (static fixture `cdn` block + `has cdn key: False` for the deployment
  fixture). Downstream `cli/nagarectl` also builds and tests green (226).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)

## Decision Log

Record every decision made while working on the plan.

- Decision: the new field is `cdn :: !(Maybe Cdn)`, not a non-optional `Cdn`.
  Rationale: backward compatibility. Every existing `StaticSite`, `ServerSite`, and
  `Deployment` config, fixture, and golden output predates CDN. `Nothing` means "no CDN, behave
  exactly as before", so existing configs compile and existing golden files are byte-identical.
  A non-optional field would force every config author and every fixture to mention CDN.
  Date: 2026-06-10

- Decision: when `cdn = Nothing`, the encoders OMIT the `"cdn"` key entirely rather than
  emitting `"cdn": null`.
  Rationale: the existing golden JSON/YAML for static sites, server sites, and deployments has
  no `"cdn"` key. Emitting `"cdn": null` would change those bytes and break the golden tests
  that prove backward compatibility. Omission keeps the no-CDN output identical to today's, so
  the only observable JSON change is for configs that actually opt in. The decoders read the
  key with the optional `.:?` combinator, so a missing key decodes to `Nothing`.
  Date: 2026-06-10

- Decision: the provider tokens in JSON are EXACTLY `"Cloudflare"` and `"GcpCloudCdn"`.
  Rationale: this is the wire contract three downstream plans (EP-56, EP-57, EP-58) match
  against. Fixing the strings here, in writing, prevents drift. `"Cloudflare"` reads naturally;
  `"GcpCloudCdn"` mirrors the Haskell constructor name `GcpCloudCdn` so the encode/decode tables
  are mechanical (`Show`-style tokens, the same convention `accessModeToken`/`retentionToken`
  use in `Nagare.Dsl.Config`). Note the asymmetry is intentional: the Haskell constructor for
  Cloudflare is `CloudflareCdn` but its wire token drops the `Cdn` suffix to read as
  `"Cloudflare"`; the GCP token keeps `GcpCloudCdn`. The mapping lives in one place each
  direction so the asymmetry is impossible to get wrong twice.
  Date: 2026-06-10

- Decision: per-path edge TTL is `Maybe Int`, where `Nothing` (encoded as JSON `null`) means
  "never cache this path".
  Rationale: a CDN config commonly needs to say "cache `/assets/` for a year, but never cache
  `/api/`". Modelling the TTL as `Maybe Int` lets a single `CdnCacheRule` express both: a
  `Just seconds` rule caches for that long, a `Nothing` rule is a pass-through (bypass). This is
  cleaner than a sentinel value like `0` or `-1`, which would collide with validation and read
  ambiguously. `edgeTtlSeconds: null` is therefore a *meaningful* value, not an absent field.
  Date: 2026-06-10

- Decision: combinators that cannot fail are total (`withDefaultTtl`, `withoutStaticAssetCache`
  return `Cdn`); combinators that can fail validation return `Either Text`
  (`mkCdnCacheRule`, `withCacheRule`, `mkCacheRules`).
  Rationale: this matches the repository's existing approach. Leaf builders that validate
  (`mkSiteName`, `mkCachePolicy`, `mkHeaderRule`, `mkRedirectRule` in
  `Nagare.Dsl.Static.Types`) return `Either Text`; pure transformations that cannot produce an
  invalid value are plain functions. `withDefaultTtl` is kept total (it takes an `Int` and sets
  the field) for ergonomics, and the validating entry points are
  `mkCdnCacheRule`/`withCacheRule`/`mkCacheRules`, which is where untrusted per-path TTLs enter.
  A default TTL set via `withDefaultTtl` is not validated by the combinator itself, but a
  hand-written or out-of-range value is still caught on the round-trip by the loader's `toCdn`
  re-validation (which rejects a negative `cdn.defaultTtlSeconds`), so nothing invalid reaches
  the rest of the system. See "Interfaces and Dependencies" for the exact signatures.
  Date: 2026-06-10

- Decision: the contract shape (field names, provider tokens, `null`-means-never-cache) is
  fixed by EP-54, the substrate spike at
  `docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`.
  Rationale: EP-54 proves the cloud topology (Google global load balancer health-checking
  Kourier while preserving the `Host` header; Cloudflare proxying a wildcard origin that still
  presents a valid TLS certificate) and, in doing so, pins down what knobs a CDN config actually
  needs to expose. EP-55 hard-depends on EP-54: this plan must not invent shape that EP-54's
  findings contradict. If EP-54's outcome differs from the shape transcribed here, update this
  plan's Decision Log and the contract before implementing.
  Date: 2026-06-10

- Decision: expose `encodeStaticSite`/`encodeServerSite` from `Nagare.Dsl.Config` rather than the
  raw `staticSiteJSON`/`serverSiteJSON` `Value` builders.
  Rationale: the round-trip test needs the exact emitted bytes; adding `encodeX` mirrors the
  existing `encodeDeployment`/`encodeDatabase`/`encodeTask` house pattern and keeps the `*JSON`
  builders private, so the public surface stays the small `emit*`/`encode*` set.
  Date: 2026-06-10

- Decision: drive `CdnSpec`'s round-trip and negative tests through the `Deployment` transport
  (`encodeDeployment`/`decodeDeployment`) instead of the static-site one.
  Rationale: with `DuplicateRecordFields`, importing the `cdn` selector for more than one of the
  three records makes a bare `cdn x` application ambiguous. Routing through `Deployment` keeps a
  single `cdn` selector in scope while still exercising the *shared* `cdnJSON`/`toCdn` path. The
  static path is proven separately by `StaticSpec`'s load test against the CDN-bearing fixture.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-10).** The shared typed contract is delivered exactly as the spike (EP-54)
fixed it. `Nagare.Dsl.Cdn.Types` defines `Cdn`/`CdnProvider`/`CdnCacheRule` with validating
constructors, presets, and combinators; the three top-level shapes carry `cdn :: !(Maybe Cdn)`;
the shared `cdnJSON` encoder and the `toCdn` loader validator round-trip the value with the wire
tokens `"Cloudflare"`/`"GcpCloudCdn"` and `edgeTtlSeconds: null` for never-cache. `cabal test`:
259 in `nagare-dsl` (+24), 226 in `nagarectl`, all green. The emitted-JSON transcripts reproduce
exactly. Backward compatibility holds: a `cdn = Nothing` shape emits no `"cdn"` key and the
existing Nginx-config / Knative-YAML goldens are unchanged (the field is inert until EP-56/EP-57/
EP-58 render it).

**Gaps / hand-offs.** Two interface refinements beyond the plan's letter, both additive and
consistent with house style: (1) `encodeStaticSite`/`encodeServerSite` were added to
`Nagare.Dsl.Config` (mirroring `encodeDeployment`) so the in-process round-trip needs no exposed
`staticSiteJSON`. (2) The negative/round-trip tests route through the `Deployment` transport (the
same shared `cdnJSON`/`toCdn`) to keep `CdnSpec` free of the three-record field-selector ambiguity;
the static fixture's CDN-bearing load test in `StaticSpec` proves the static path end to end. No
contract amendment was needed — EP-56/EP-57/EP-58 can consume the shape verbatim, and origin-TLS
mode stays out of the model as the spike recommended.

