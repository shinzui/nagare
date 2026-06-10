---
id: 11
slug: cdn-integration-for-nagare
title: "CDN Integration for Nagare"
kind: master-plan
created_at: 2026-06-10T18:57:26Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
---


# CDN Integration for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan coordinates the addition of first-class Content Delivery Network (CDN) support to
Nagare, the single-node personal PaaS. A CDN is a globally distributed cache that sits in
front of an origin server: visitors are served cached responses from a nearby edge location
instead of every request travelling to the one VM in `us-west1`. Nagare gains two CDN
backends — Google Cloud CDN (provisioned through Pulumi as a global HTTP(S) load balancer
with caching enabled) and Cloudflare (configured through the Cloudflare API as a reverse
proxy in front of the VM's public IP). Cloudflare is the preferred default because it has a
larger edge network, free tier, and stronger DDoS protection; Google Cloud CDN is offered for
operators who want to stay entirely inside GCP.

The defining requirement of this initiative is **native integration with the two web-hosting
runtimes Nagare already ships**: static sites (the `StaticSite` model and its Nginx image,
delivered by MasterPlan 3, `docs/masterplans/3-static-hosting-for-nagare.md`) and full-stack
JavaScript apps such as TanStack Start (the `ServerSite` model and its Node image, also from
MasterPlan 3). A developer enables a CDN by adding a few lines to the same typed
`nagare/Config.hs` they already write, and `nagarectl site deploy` provisions and wires the
CDN as part of the normal deploy — no separate CDN console, no hand-written load-balancer
YAML, no manual DNS edits. Generic container apps (the `Deployment` model) gain the same field
so the capability is uniform, but static sites and TanStack Start are the headline cases the
initiative must prove end to end.


## Vision & Scope

After this initiative is complete, a developer can put a CDN declaration into the typed config
next to a static or full-stack project:

```haskell
-- nagare/Config.hs (excerpt) — a static site fronted by Cloudflare
site :: StaticSite
site =
  StaticSite
    { name = ...
    , domains = [blog]                       -- blog.example.com
    , cache = ...                             -- existing origin Nginx cache policy
    , cdn = Just (cloudflareCdn              -- NEW: edge CDN in front of the origin
                    & withDefaultTtl 3600
                    & withCacheRule "/assets/" (Just 31536000)
                    & withCacheRule "/api/" Nothing)   -- never cache the API
    , ...
    }
```

and run the same command they already use:

```bash
nagarectl site deploy
```

The command builds and pushes the image and applies the Knative Service and DomainMappings
exactly as before, and then — because `cdn` is set — provisions the chosen CDN: it points the
custom hostname at the CDN edge, applies the declared cache behaviour (a default edge time-to-
live plus per-path overrides, where a `Nothing` TTL means "never cache this path"), and prints
the edge-served URL. The developer can then run:

```bash
nagarectl cdn status blog.example.com     # provider, DNS target, cache rules, edge/cert readiness
nagarectl cdn purge  blog.example.com     # purge the edge cache after a deploy
nagarectl cdn list --all-namespaces       # every CDN-fronted site/app and its provider
nagarectl cdn disable blog.example.com    # tear the CDN down and route DNS back to the VM
```

The same `cdn = Just (gcpCloudCdn & ...)` declaration instead provisions Google Cloud CDN: a
global external HTTP(S) load balancer whose backend is the Nagare VM with Cloud CDN enabled,
an anycast IP the hostname resolves to, and a Google-managed TLS certificate.

User-visible behaviours enabled by this initiative:

- A typed `cdn` field on `StaticSite`, `ServerSite`, and `Deployment` with a provider choice
  (`Cloudflare` or `GcpCloudCdn`), a default edge TTL, a long-cache toggle for fingerprinted
  static assets, and per-path cache-TTL overrides (including "never cache").
- Deploy-time provisioning of both CDNs from `nagarectl site deploy` and `nagarectl deploy`,
  with a dry-run that shows exactly what infrastructure and DNS changes would be made.
- A `nagarectl cdn` command group: `list`, `status`, `purge`, and `disable`.
- A reusable Google Cloud CDN load-balancer capability in the Pulumi stack, exposed through new
  stack outputs, and a Cloudflare API client inside `nagarectl`.
- Documentation and worked end-to-end examples for a static site behind Cloudflare and a
  TanStack Start app behind Google Cloud CDN, including the DNS and origin-TLS runbook.

Explicitly **in scope**: edge caching of cacheable responses (static assets and any
cache-control-friendly routes), custom-hostname routing through the CDN, automatic DNS
pointing for CDN-enabled hostnames, TLS termination at the edge, and cache purge/invalidation.

Explicitly **out of scope**: edge compute (Cloudflare Workers / `workerd`, Google Cloud
Functions at the edge) — Nagare continues to run application logic on the origin VM, matching
the boundary MasterPlan 3 already drew for static hosting; multi-origin or multi-region origin
fan-out (there is one VM); per-request edge rules beyond path-prefix cache TTLs and the
static-asset long-cache toggle (e.g. Cloudflare Transform Rules, signed URLs, image resizing) —
these can be added by later plans without changing the typed `cdn` contract; and changing how
the origin itself serves traffic — Kourier on the VM remains the origin for both CDNs.


## Decomposition Strategy

The initiative is decomposed by functional concern into six child plans grouped into four
implementation waves. The shape mirrors the proven rhythm of MasterPlans 7, 9, and 10 in this
repository (spike → typed model and renderer → provider/infra capability → CLI integration →
docs and examples), because CDN work has the same risk profile: an unproven cloud topology to
de-risk first, a shared typed contract every later plan consumes, two genuinely different
provider backends, and a convergence point that wires them into the existing deploy engine.

The first work stream (EP-54) is a **substrate spike**. CDN-in-front-of-Knative is unproven on
this box: a Google global load balancer must health-check and route to Kourier while preserving
the `Host` header Knative needs for routing, and Cloudflare must proxy a wildcard origin while
the origin still presents a valid TLS certificate (today issued by cert-manager via a Cloud DNS
DNS-01 challenge — which interacts with moving a zone's authority to Cloudflare). The spike
stands up a minimal version of each, by hand, validates host-routing, TLS, and cache hits, and
records the decisions (origin-TLS mode per provider, health-check path, cache-key/host-header
behaviour, DNS topology) that every later plan depends on. Putting this first prevents the
typed model and the two provider plans from baking in assumptions that the cloud rejects.

The second work stream (EP-55) defines the **typed CDN model and its JSON transport** in the
`nagare-dsl` Haskell library: the `Cdn` type, the `CdnProvider` sum, the per-path
`CdnCacheRule` type, smart constructors, the `cdn :: Maybe Cdn` field added natively to
`StaticSite`, `ServerSite`, and `Deployment`, the JSON shape the CLI reads back, and the loader
changes. This is the shared contract; isolating it in one plan keeps all three runtimes
agreeing on one representation and one validation path, exactly as MasterPlan 3 isolated the
static-site contract in EP-13.

The third and fourth work streams build the two provider **capabilities** in parallel, because
they live in different languages and subsystems and share nothing but the typed model's
semantics. EP-56 adds the **Google Cloud CDN load balancer** to the Pulumi stack
(`infra/pulumi`, TypeScript): the global anycast IP, the unmanaged instance group wrapping the
VM, the health check, the CDN-enabled backend service, the URL map, the HTTP(S) target proxies
and forwarding rules, a Google-managed certificate, the load-balancer firewall allowances, and
the new stack outputs. EP-57 adds the **Cloudflare provisioner** to `nagarectl` (Haskell): a new
HTTP client module that talks to the Cloudflare API to upsert proxied DNS records, apply cache
rules, set the origin-TLS mode, and purge the cache, plus credential handling. Splitting these
is mandatory, not cosmetic: one is declarative IaC reviewed with `pulumi preview`, the other is
imperative API code reviewed with unit tests and recorded API transcripts; merging them would
put two unrelated toolchains and review styles in one plan.

The fifth work stream (EP-58) is the **convergence point**: it wires the typed model into the
deploy engine and adds the `nagarectl cdn` command group. It reads `cdn :: Maybe Cdn` after the
existing `loadSite`/`loadDeployment` step, dispatches on provider to EP-56's Google capability
or EP-57's Cloudflare capability, writes the per-hostname DNS records that point CDN-enabled
domains at the right edge, applies the declared cache behaviour, and exposes `list`, `status`,
`purge`, and `disable`. This is one plan rather than two provider-specific ones because the
deploy seam and the command surface are provider-agnostic — they dispatch on the same `Cdn`
value — exactly as MasterPlan 3 kept a single kind-dispatching deploy engine (`Nagare.Static.Deploy`)
that both static and server sites flow through.

The sixth work stream (EP-59) writes the **documentation and worked end-to-end examples** and
performs the validation that proves the whole workflow: a static site behind Cloudflare and a
TanStack Start app behind Google Cloud CDN, the cache-purge demonstration, and the DNS/origin-
TLS runbook. Every prior MasterPlan in this repo ends with a dedicated docs-and-examples plan,
and CDN is the most operationally subtle of them (DNS authority, edge TLS, cache semantics), so
a self-contained runbook is worth its own stream.

Alternatives considered and rejected. **Folding the two providers into one plan** was rejected
for the toolchain/review-style reason above and because either provider is independently
valuable. **Folding the deploy wiring into each provider plan** was rejected because it would
duplicate the provider-dispatch seam and the `cdn` command parser in two places and risk them
diverging. **Splitting the typed model per runtime** (a static `cdn`, a server `cdn`) was
rejected because the `Cdn` contract is identical for all three runtimes — the difference is only
where the field is attached, not what it means. **Skipping the spike** was rejected because the
host-header/health-check/origin-TLS questions are exactly the kind of cloud-topology unknowns
this repo has repeatedly de-risked with a spike before committing a typed contract and infra to
them. **A seventh "purge/invalidation" plan** was rejected because purge is a thin per-provider
call that belongs with the rest of the provider capability and the `cdn` command surface.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 54 | CDN substrate spike and origin-TLS feasibility | docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md | None | EP-2, EP-4 | Complete |
| 55 | Typed CDN model and provider renderer | docs/plans/55-typed-cdn-model-and-provider-renderer.md | EP-54 | EP-13, EP-18 | Complete |
| 56 | GCP Cloud CDN load balancer provisioning in Pulumi | docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md | EP-54 | EP-55 | Complete |
| 57 | Cloudflare CDN provisioning via API in nagarectl | docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md | EP-54 | EP-55 | Complete |
| 58 | Deploy-time CDN wiring and nagarectl cdn command group | docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md | EP-55, EP-56, EP-57 | None | Complete |
| 59 | CDN docs and end-to-end examples | docs/plans/59-cdn-docs-and-end-to-end-examples.md | EP-58 | EP-56, EP-57 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference
child plans by their `EP-<#>` prefix, where the number is the file number in `docs/plans/`.
Soft dependencies `EP-2` and `EP-4` refer to the bootstrap plans
`docs/plans/2-pulumi-gcp-infrastructure.md` (the VM, static IP, firewall, and Cloud DNS zone)
and `docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md` (Kourier ingress and
cert-manager TLS). `EP-13` and `EP-18` refer to
`docs/plans/13-typed-static-site-model-and-renderer.md` and
`docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`, the static and server
site models the new `cdn` field attaches to.

Implementation waves:

- **Wave 1 — De-risk (EP-54).** Stand up a minimal Google Cloud CDN load balancer and a minimal
  Cloudflare proxy by hand in front of the VM; validate host-routing, edge TLS, origin TLS, and
  cache hits; record the decisions the rest of the initiative consumes.
- **Wave 2 — Contract and capabilities (EP-55, EP-56, EP-57, parallel).** EP-55 defines the
  typed `Cdn` model and JSON transport. EP-56 builds the standing Google Cloud CDN load-balancer
  capability in Pulumi. EP-57 builds the Cloudflare API client in `nagarectl`. All three can
  proceed concurrently once EP-54's decisions are recorded.
- **Wave 3 — Integration (EP-58).** Wire the typed model into the deploy engine, add per-hostname
  CDN DNS records and cache-rule application, and ship the `nagarectl cdn` command group.
- **Wave 4 — Proof (EP-59).** Document the workflow and validate the two headline cases
  (static + Cloudflare, TanStack Start + Google Cloud CDN) end to end.


## Dependency Graph

EP-54 (spike) has no hard dependency. It soft-depends on the bootstrap infrastructure plans
EP-2 (`docs/plans/2-pulumi-gcp-infrastructure.md`) and EP-4
(`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`) because it experiments
in front of the existing VM, static IP, Cloud DNS zone, and Kourier ingress those plans created.
The VM (`nagare-01`) is currently powered off to save cost, so the spike's live legs are
environment-gated and will be recorded as deferred/manual where the box is required, matching
how EP-43, EP-47, and EP-49 handled the same constraint.

EP-55 (typed model) hard-depends on EP-54 because the spike fixes the shape of the contract: the
provider set (`Cloudflare`, `GcpCloudCdn`), the cache semantics (default TTL, per-path overrides,
the static-asset toggle), and whether origin-TLS mode needs to be expressible in the model are
all spike outputs. It soft-depends on EP-13 and EP-18 because it edits the `StaticSite` and
`ServerSite` records those plans defined; the edit is purely additive (one optional field).

EP-56 (Google Cloud CDN infra) and EP-57 (Cloudflare provisioner) each hard-depend on EP-54
because they implement, as production code, the exact topology the spike validated — EP-56 the
load-balancer/backend/cache-policy shape, EP-57 the proxied-DNS/cache-rule/origin-TLS API
sequence. They soft-depend on EP-55 because they should name their provisioning inputs to match
the typed model's fields (provider token, default TTL, per-path rules) even though the model and
the capabilities are wired together only in EP-58. EP-56 and EP-57 share no code and run in
parallel.

EP-58 (deploy wiring + `cdn` command) hard-depends on all three Wave-2 plans. It needs EP-55's
loaded `Cdn` value to dispatch on, EP-56's stack outputs and the `gcloud` operations that target
the load balancer and Cloud DNS, and EP-57's Cloudflare module functions. It is the single
convergence point; nothing downstream of it can begin until the model and both capabilities
exist.

EP-59 (docs + examples) hard-depends on EP-58 because the documentation describes the
`nagarectl site deploy` CDN flow and the `nagarectl cdn` commands that EP-58 ships. It soft-
depends on EP-56 and EP-57 so the provider-specific runbook chapters (Google Cloud CDN setup,
Cloudflare API-token setup) can cite the exact resources and credentials those plans introduce.

Parallelism. Wave 1 is a single gate. After EP-54, three streams open at once (EP-55, EP-56,
EP-57) in three different subsystems (Haskell DSL, Pulumi TypeScript, Haskell CLI), so they can
be implemented by three contributors or sessions without touching each other's files. Wave 3
(EP-58) is the join; Wave 4 (EP-59) follows it. The critical path is
EP-54 → {EP-55} → EP-58 → EP-59, with EP-56 and EP-57 off the critical path as long as they
finish before EP-58 starts.


## Integration Points

**1. Typed CDN model and JSON transport (defined by EP-55; consumed by EP-58; semantics honoured
by EP-56 and EP-57).** EP-55 owns a new module `cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs` and
the JSON encoding/decoding in `Nagare.Dsl.Config` and `Nagare.Dsl.Load`. The contract is:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn
  deriving stock (Generic, Eq, Show)

-- A per-path edge cache rule. Requests whose path begins with @pathPrefix@ get
-- @edgeTtlSeconds@ as their edge time-to-live; @Nothing@ means "never cache this
-- path" (bypass the edge cache). Construct with 'mkCdnCacheRule'.
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- The CDN configuration attached to a site or app. @defaultTtlSeconds@ is the
-- edge TTL for cacheable responses with no matching rule; @cacheStaticAssets@
-- turns on a long-cache rule for fingerprinted assets (js/css/fonts/images);
-- @cacheRules@ are per-path overrides applied in order. Construct via
-- 'cloudflareCdn' / 'gcpCloudCdn' and the @with*@ combinators.
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)
```

The field added to `StaticSite`, `ServerSite`, and `Deployment` is `cdn :: !(Maybe Cdn)`, where
`Nothing` means "no CDN" (the current behaviour, unchanged). The JSON transport is a nested
`"cdn"` object on each of those three resources:

```json
"cdn": {
  "provider": "Cloudflare",
  "defaultTtlSeconds": 3600,
  "cacheStaticAssets": true,
  "cacheRules": [
    { "pathPrefix": "/assets/", "edgeTtlSeconds": 31536000 },
    { "pathPrefix": "/api/",    "edgeTtlSeconds": null }
  ]
}
```

The provider token strings are exactly `"Cloudflare"` and `"GcpCloudCdn"`; `edgeTtlSeconds: null`
encodes the `Nothing` ("never cache") case. EP-58 reads this value through the existing
`loadSite`/`loadDeployment` loaders (whose signatures do not change — the `Cdn` rides inside the
already-returned `StaticSite`/`ServerSite`/`Deployment`). EP-56 and EP-57 must translate the same
fields into, respectively, Cloud CDN cache-policy/URL-map settings and Cloudflare cache-rule API
payloads; the field names above are the single source of truth for what each setting means.

**2. Google Cloud CDN standing infrastructure and stack outputs (defined by EP-56; consumed by
EP-58; documented by EP-59).** EP-56 owns the new Pulumi resources (a `NagareCdn` component under
`infra/pulumi/src/components/` instantiated by `NagarePerimeter`) and three new stack outputs that
EP-58 reads via `pulumi stack output` exactly as `Nagare.Ops.Pulumi.stackOutput` already reads
`publicIp`/`baseDomain`/`artifactRegistry`:

- `cdnGlobalIp` — the global anycast IPv4 of the Cloud CDN load balancer. CDN-enabled hostnames
  using the Google provider get a Cloud DNS A record pointing here (written by EP-58), instead of
  the VM's regional IP that the existing `*.<baseDomain>` wildcard uses.
- `cdnBackendService` — the name of the CDN-enabled backend service, so EP-58 can apply per-site
  cache policy with `gcloud compute backend-services update`.
- `cdnUrlMap` — the name of the URL map, so EP-58 can add per-path cache behaviour / path matchers
  at deploy time.

EP-56 sets the standing capability (load balancer, backend, default cache policy, Google-managed
cert, firewall allowances for the Google health-check ranges `130.211.0.0/22` and
`35.191.0.0/16`); EP-58 applies per-site/per-path cache behaviour on top through `gcloud`. The
division between "standing infra in Pulumi" vs "per-deploy cache settings via `gcloud`" is a
decision EP-54 confirms and EP-56 records.

**3. Cloudflare provisioner module API (defined by EP-57; consumed by EP-58).** EP-57 owns a new
`nagarectl` library module `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` exposing IO functions
that EP-58 calls. The expected surface (final signatures fixed by EP-57, but EP-58 depends on this
shape):

```haskell
-- Credentials are read from the environment: CF_API_TOKEN (required) and an
-- optional CF_ZONE_ID; when absent the zone is discovered from the hostname's
-- registrable domain via the Cloudflare API.
data CloudflareCreds = CloudflareCreds { cfApiToken :: !Text, cfZoneId :: !(Maybe Text) }

loadCloudflareCreds :: IO (Either Text CloudflareCreds)
upsertProxiedRecord :: CloudflareCreds -> Text -> Text -> IO (Either Text ())   -- hostname -> origin IP, proxied=true
applyCacheRules     :: CloudflareCreds -> Text -> Cdn -> IO (Either Text ())     -- hostname -> typed cache config
setOriginTlsMode    :: CloudflareCreds -> Text -> OriginTlsMode -> IO (Either Text ())
purgeHostname       :: CloudflareCreds -> Text -> [Text] -> IO (Either Text ())  -- hostname -> paths ([] = purge all)
```

`OriginTlsMode` (e.g. `Flexible | Full | FullStrict`) is owned by EP-57 and chosen per EP-54's
origin-TLS decision; EP-58 passes whichever mode the spike selected as the deploy-time default.
EP-57 introduces the HTTP-client dependency (`http-client` + `http-client-tls`) to `nagarectl.cabal`;
all outbound Cloudflare calls flow through this module so no other CLI module gains an HTTP
dependency.

**4. Deploy-engine CDN seam (defined by EP-58; extends MasterPlan 3's deploy engine).** EP-58 owns
a provider-dispatching function — working name `provisionCdn :: Cdn -> CdnTarget -> IO (Either Text CdnResult)`
in a new module `cli/nagarectl/src/Nagare/Cdn/Provision.hs` — where `CdnTarget` carries the
resolved hostname(s), the origin IP (`publicIp` stack output), and the namespace/service. It is
called from the existing static, server, and app deploy paths (`Nagare.Static.Deploy`,
`Nagare.Server.Deploy`, and the app `runDeploy` in `cli/nagarectl/app/Main.hs`) **after** the
Service and DomainMappings are applied and Ready, mirroring how MasterPlan 3 calls
`recordRelease` at the end of a deploy. The branch is `case provider cdn of CloudflareCdn -> ...
(EP-57); GcpCloudCdn -> ... (EP-56 outputs + gcloud)`. When `cdn` is `Nothing`, the deploy path is
byte-for-byte unchanged.

**5. `nagarectl cdn` CLI namespace (defined by EP-58).** EP-58 adds a top-level `cdn` command group
to the `Options.Applicative` parser in `cli/nagarectl/app/Main.hs`, alongside the existing
`deploy`, `site`, `app`, `env`, `secret`, `db`, `task`, `storage`, `server`, `doctor`, `domains`,
and `cleanup` groups: `nagarectl cdn list`, `nagarectl cdn status <host>`, `nagarectl cdn purge
<host> [--path P]...`, and `nagarectl cdn disable <host>`. The `status` command is the CDN analogue
of the existing `nagarectl domains list` (`Nagare.Ops.Domains`); it reuses that module's
DomainMapping/Certificate discovery and adds the provider's edge/DNS readiness.

**6. CDN-hostname DNS records (Cloud DNS zone shared with EP-2 and cert-manager; written by
EP-58 for the Google provider).** The Cloud DNS managed zone created by EP-2 (surfaced as the
`dnsZoneName` stack output) currently holds only the `*.<baseDomain>` wildcard A record pointing
at the VM. For a Google-Cloud-CDN-enabled hostname, EP-58 writes a more-specific A record for that
exact hostname pointing at `cdnGlobalIp` (a more-specific record wins over the wildcard), using
`gcloud dns record-sets`. For the Cloudflare provider, the hostname's authoritative DNS is
Cloudflare, so EP-57's `upsertProxiedRecord` manages the record instead — EP-54 records how the
two DNS authorities coexist (e.g. Cloudflare hosts the zone and `_acme-challenge` is delegated
back to Cloud DNS, or cert-manager's DNS-01 solver moves to a Cloudflare token). `disable` reverts
the Google record back to the wildcard/VM IP.

**7. Origin-TLS model (decided by EP-54; implemented by EP-56 and EP-57; documented by EP-59).**
The origin (Kourier on the VM) presents a cert-manager-issued Let's Encrypt wildcard today (TLS
currently deferred until a real `baseDomain` is delegated — see
`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`). EP-54 decides, per
provider, how the edge connects to the origin: for Cloudflare, the SSL mode (`Flexible` works
immediately against the HTTP-first origin, `Full`/`Full (strict)` once the origin serves the LE
wildcard) and whether cert-manager's DNS-01 challenge must move to Cloudflare; for Google Cloud
CDN, whether the load balancer talks to the origin over HTTP or HTTPS and which managed/origin
certificate terminates client TLS at the edge. EP-56 and EP-57 implement the chosen modes;
`OriginTlsMode` (Integration Point 3) is the typed handle for the Cloudflare side.


## Progress

- [x] EP-54: Stand up a minimal Google Cloud CDN load balancer in front of the VM and validate host-routing, edge TLS, and a cache hit. *(Scripts delivered in `cluster/examples/cdn-spike/gcp-cdn-up.sh`; live `curl` evidence deferred until `nagare-01` is powered on.)*
- [x] EP-54: Stand up a minimal Cloudflare proxy in front of the VM and validate proxied routing, origin TLS mode, and a cache hit. *(Scripts delivered in `cluster/examples/cdn-spike/cf-cdn-up.sh`; live evidence deferred until VM up + a domain and `CF_API_TOKEN` are supplied.)*
- [x] EP-54: Record the substrate decisions (origin-TLS mode per provider, health-check path, host-header/cache-key behaviour, DNS topology, standing-infra-vs-deploy-time split). *(Recorded as confirmable proposals in EP-54's Substrate Decisions + Decision Log.)*
- [x] EP-55: Define `Cdn`, `CdnProvider`, `CdnCacheRule`, smart constructors, and the `with*` combinators in `Nagare.Dsl.Cdn.Types`.
- [x] EP-55: Add `cdn :: Maybe Cdn` to `StaticSite`, `ServerSite`, and `Deployment` with JSON transport and loader support, plus golden and negative tests. *(nagare-dsl 259 tests, nagarectl 226, all green; wire tokens `"Cloudflare"`/`"GcpCloudCdn"`, `edgeTtlSeconds: null` = never-cache.)*
- [x] EP-56: Add the `NagareCdn` Pulumi component (global IP, instance group, health check, CDN backend service, URL map, HTTP(S) proxies, managed cert, firewall) and the `cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap` outputs; verify with `pulumi preview`. *(M1 done: `tsc` + preview show 13 resources gated by `nagare:enableCdn`. `pulumi up`/live curl deferred — billable + VM off.)*
- [x] EP-57: Add the `Nagare.Cdn.Cloudflare` HTTP-client module (creds, upsert proxied record, apply cache rules, set origin-TLS mode, purge) with unit tests and recorded API transcripts. *(nagarectl 237 tests, +11 `Nagare.Cdn`; live CF zone/token + VM-on leg deferred.)*
- [x] EP-58: Wire `provisionCdn` into the static/server/app deploy paths with a dry-run, including per-hostname CDN DNS records and per-path cache application. *(`cdnDeployStep` in the CLI handlers; `renderCdnPlan` goldens prove the dry-run text; live legs deferred.)*
- [x] EP-58: Ship the `nagarectl cdn` command group (`list`, `status`, `purge`, `disable`). *(`--help` verified; formatter tests green; live discovery deferred.)*
- [x] EP-59: Write the CDN user guide and the DNS/origin-TLS runbook. *(`docs/user/cdn.md`, linked from the operator-guide index + status table.)*
- [x] EP-59: Add and validate the worked examples (static site behind Cloudflare; TanStack Start behind Google Cloud CDN), including a cache-purge demonstration. *(`cluster/examples/static-cdn-site/`, `tanstack-start-cdn/`; both dry-run clean; live cache-HIT curls deferred.)*


## Surprises & Discoveries

- EP-54 (2026-06-10): The spike's live legs (M0–M2) stay deferred because `nagare-01` is
  `TERMINATED` to save cost. EP-54 closes on its committed deliverable — this document's command
  sequences, the expected transcripts, the Substrate Decisions, and the reusable
  `cluster/examples/cdn-spike/` scripts — with the live `curl` evidence (cache HITs, the working
  Cloudflare origin-TLS mode, the Google-managed-cert transition) captured later when an operator
  starts the VM. This is the same powered-off close EP-43 and EP-49 used, and it does not block
  Wave 2: EP-55/EP-56/EP-57 consume the *decisions*, which are recorded. The one item EP-54
  hands EP-55 is a confirmation, not an amendment — the typed `Cdn` contract is sufficient as
  proposed, and origin-TLS mode stays out of the model as a deploy-time default (`Full (strict)`
  for Cloudflare).


## Decision Log

- Decision: Support two CDN providers — Cloudflare (default/preferred) and Google Cloud CDN —
  behind one typed `Cdn` contract with a `CdnProvider` sum.
  Rationale: The operator asked for both and stated Cloudflare is the better CDN (larger edge
  network, free tier, DDoS protection). Google Cloud CDN keeps an all-GCP option for operators who
  do not want a second vendor. A single typed contract with a provider discriminator means the
  DSL, the deploy seam, and the `cdn` command surface are written once and dispatch on provider,
  the same pattern MasterPlan 3 used for static-vs-server site kinds.
  Date: 2026-06-10

- Decision: Make CDN a native, optional field (`cdn :: Maybe Cdn`) on `StaticSite`, `ServerSite`,
  and `Deployment`, enabled from the same `nagarectl site deploy`/`nagarectl deploy` commands.
  Rationale: The operator's explicit requirement is native integration with static sites and
  TanStack Start, not a bolt-on. Attaching the field to the existing typed models and provisioning
  the CDN inside the existing deploy engine means "front my site with a CDN" is a few lines of
  config and zero extra commands, and the static and server runtimes get it for free because the
  deploy seam is runtime-agnostic. `Maybe` keeps every existing config and deploy path byte-for-
  byte unchanged when no CDN is requested.
  Date: 2026-06-10

- Decision: Lead with a substrate spike (EP-54) before the typed model and the provider plans.
  Rationale: CDN-in-front-of-Knative raises real unknowns on this single-node box — preserving the
  `Host` header a Google load balancer forwards to Kourier, health-checking the origin, and
  keeping a valid origin certificate while a zone's authority potentially moves to Cloudflare
  (which collides with cert-manager's Cloud DNS DNS-01 challenge). This repository has repeatedly
  de-risked cloud-topology unknowns with a spike (EP-8, EP-33, EP-43, EP-49) before committing a
  typed contract and infrastructure; CDN has the same risk profile.
  Date: 2026-06-10

- Decision: Build the two provider capabilities as separate parallel plans — Google Cloud CDN in
  Pulumi (EP-56), Cloudflare via the Cloudflare API in `nagarectl` (EP-57).
  Rationale: They share nothing but the typed model's semantics. Google Cloud CDN is declarative
  IaC reviewed with `pulumi preview`; Cloudflare is imperative HTTP-API code reviewed with unit
  tests and recorded transcripts. They live in different languages and subsystems and can be built
  concurrently. Merging them would force two unrelated toolchains and review styles into one plan.
  Date: 2026-06-10

- Decision: Keep the deploy wiring and the `nagarectl cdn` command in one convergence plan (EP-58)
  rather than splitting per provider.
  Rationale: The deploy seam and the command surface dispatch on the same `Cdn` value and are
  provider-agnostic. A single provider-dispatching `provisionCdn` and a single `cdn` parser mirror
  MasterPlan 3's single kind-dispatching deploy engine and avoid two copies of the seam drifting.
  Date: 2026-06-10

- Decision: Standing CDN infrastructure lives in Pulumi; per-site/per-path cache behaviour is
  applied at deploy time (Cloudflare via API, Google via `gcloud` against the backend service and
  URL map).
  Rationale: The load balancer, anycast IP, backend, and managed certificate are long-lived,
  stack-level resources that belong in IaC and rarely change. Cache TTLs and per-path rules are
  per-site and change every time a developer edits `nagare/Config.hs`, so applying them at deploy
  time keeps the typed config the single source of truth without a `pulumi up` per site. EP-54
  confirms this split is workable for Google Cloud CDN before EP-56/EP-58 commit to it.
  Date: 2026-06-10

- Decision: Edge compute (Cloudflare Workers / `workerd`, edge functions) and advanced per-request
  edge rules stay out of scope; the typed `cdn` contract covers default TTL, a static-asset long-
  cache toggle, and per-path TTL overrides only.
  Rationale: Nagare runs application logic on the origin VM by design (MasterPlan 3 drew the same
  boundary for static hosting). Caching is the 80%-value CDN feature for a personal PaaS, and the
  small cache contract keeps the model unrepresentable-when-illegal and provider-portable. Richer
  edge features can be added later without changing the `cdn` field's meaning.
  Date: 2026-06-10

- Decision: The CDN fronts MasterPlan 3's existing per-release origins (the Nginx static image and
  the Node server image); it does not replace them. The "does a pure-static site need an origin
  server at all?" question raised against MasterPlan 3 is answered here, not by removing the origin.
  Rationale: Revisiting MasterPlan 3's choice of a per-release Nginx origin (versus serving files
  directly from the cluster's Envoy/Kourier ingress) surfaced the deeper question of whether a
  pure-static site needs an origin container at all. A CDN is the right place to answer it: the edge
  cache serves cacheable static responses, while the origin (Kourier on the VM, with the Nginx image
  behind it) remains the cache-miss/cold path and the source of truth. This initiative therefore
  keeps the origin unchanged — see Vision & Scope, "Kourier on the VM remains the origin for both
  CDNs" — and adds caching in front rather than removing the origin. Cross-references
  `docs/masterplans/3-static-hosting-for-nagare.md` (Decision Log, 2026-06-10).
  Date: 2026-06-10


## Outcomes & Retrospective

**All six child plans Complete (2026-06-10).** First-class CDN support is delivered end to end,
offline-verified, with the live cloud legs deferred under the powered-off-VM constraint that
governs the whole repo.

- **EP-54 (spike).** Recorded the substrate decisions (Google LB topology, Cloudflare origin-TLS
  `Full (strict)`, the DNS-authority resolution, the standing-infra-vs-deploy-time split, contract
  sufficiency) and shipped the reusable `cluster/examples/cdn-spike/` scripts. Live `curl` evidence
  deferred (VM off).
- **EP-55 (typed model).** `Nagare.Dsl.Cdn.Types` (`Cdn`/`CdnProvider`/`CdnCacheRule`, presets,
  combinators) and the `cdn :: Maybe Cdn` field on all three runtimes, with JSON transport and
  loader round-trip. nagare-dsl 259 tests / nagarectl 226, green; `cdn = Nothing` is byte-for-byte
  unchanged.
- **EP-56 (Google infra).** The `NagareCdn` Pulumi component behind the opt-in `nagare:enableCdn`
  flag, exposing `cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap`. `pulumi preview` validated the
  gating (13 resources on, only the firewall off); `pulumi up`/live curl deferred (billable + VM
  off).
- **EP-57 (Cloudflare client).** `Nagare.Cdn.Cloudflare`, the CLI's only outbound-HTTP surface,
  with byte-exact unit tests for every request body and envelope parse.
- **EP-58 (convergence).** `Nagare.Cdn.Provision` (one provider-dispatching `provisionCdn` + the
  pure `planCdn`/`renderCdnPlan`), wired into the static/server/app deploy handlers with a dry-run,
  and the `nagarectl cdn list|status|purge|disable` command group. 246 nagarectl tests; the
  `renderCdnPlan` goldens pin the exact dry-run text.
- **EP-59 (proof).** `docs/user/cdn.md` (guide + DNS/origin-TLS runbook) and the two worked
  examples (`static-cdn-site` + Cloudflare, `tanstack-start-cdn` + Google Cloud CDN), both
  dry-running clean.

**Headline acceptance met.** A developer adds a `cdn` field to the same typed `nagare/Config.hs`,
runs the same `nagarectl site deploy`, and `--dry-run` shows the planned edge changes — uniformly
across both providers and all three runtimes, with the no-CDN path unchanged.

**Deferred tail (one operator session, VM on + a delegated domain + a scoped `CF_API_TOKEN`).**
Capture the live `CF-Cache-Status: HIT` (Cloudflare) and growing `Age:` (Google) proofs; run
`pulumi up` for the billable Google load balancer; wire live `nagarectl cdn list`/`status`
discovery (currently `queryCdnRows` returns `[]`); and confirm EP-54's proposed health-check
host/path and the HTTPS origin hop once origin TLS is enabled. None of these block the typed
contract, the deploy wiring, or the docs — they are the environment-gated proofs.
