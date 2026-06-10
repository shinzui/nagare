---
id: 59
slug: cdn-docs-and-end-to-end-examples
title: "CDN docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# CDN docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A "CDN" — Content Delivery Network — is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to Nagare's one VM in `us-west1`, visitors
are served cached copies from a nearby edge location. Nagare ships two CDN backends:
**Cloudflare** (a reverse proxy in front of the VM's public IP, configured through the
Cloudflare API by `nagarectl`) and **Google Cloud CDN** (a global HTTP(S) load balancer with
caching turned on, provisioned through Pulumi). A developer turns one on by adding a `cdn`
field to the same typed `nagare/Config.hs` they already write, and `nagarectl site deploy`
provisions and wires it as part of the normal deploy.

This plan is the **proof** of the whole CDN initiative (MasterPlan 11,
`docs/masterplans/11-cdn-integration-for-nagare.md`). It delivers the user documentation, the
DNS and origin-TLS runbook, and two worked end-to-end examples that demonstrate both headline
cases: a static site fronted by Cloudflare and a TanStack Start full-stack app fronted by
Google Cloud CDN. After this plan, a reader can: understand what a CDN buys them and which
backend to choose; add `cdn = Just (cloudflareCdn & …)` or `gcpCloudCdn` to a config; run
`nagarectl site deploy --dry-run` and see the generated Knative Service, DomainMapping, and the
**planned CDN changes** before anything touches the cloud; operate the edge with
`nagarectl cdn list|status|purge|disable`; and follow a step-by-step runbook to set the DNS
record and origin-TLS mode for a CDN-fronted hostname, including the cert-manager DNS-authority
caveat when a zone moves to Cloudflare.

This plan writes **documentation and examples only** — it adds no library or CLI code. It
depends on the typed model (EP-55, `cdn :: Maybe Cdn` on `StaticSite`/`ServerSite`/`Deployment`
with the `cloudflareCdn`/`gcpCloudCdn` presets and `with*` combinators), the deploy wiring and
`nagarectl cdn` command group (EP-58,
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`), the Google Cloud
CDN load balancer in Pulumi (EP-56,
`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`), and the Cloudflare
provisioner in `nagarectl` (EP-57,
`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`). The substrate decisions —
Cloudflare's steady-state origin-TLS mode is `Full (strict)`, Google's origin hop is HTTPS, the
load balancer preserves the `Host` header, and the cert-manager DNS-authority caveat — come
from the spike EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`).

The honest limitation, stated up front exactly as the static-hosting and database docs do:
`nagare-01` is currently **powered off**, and no real delegated domain or Cloudflare token
exists in this environment. The **dry-run-verifiable** parts of every example work offline
today; the **live** legs — the actual `CF-Cache-Status: HIT` curl against Cloudflare and the
Google Cloud CDN cache-`Age:` curl — are documented as **deferred** until the box is powered on
and a real domain plus token exist. This is the same gating MasterPlan 3's docs plan (EP-17)
and the database/task docs plans used for the powered-off box.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — write `docs/user/cdn.md` (the guide + the DNS/origin-TLS runbook chapter)
      and wire it into the `docs/user/README.md` operator-guide index (a "CDN (edge caching)"
      bullet after the static-hosting entry and a `MP-11 (EP-54–59)` status-table row).
- [x] Milestone 2 — create `cluster/examples/static-cdn-site/` (static site behind Cloudflare):
      copied `public/`, `nagare/Config.hs` with a Cloudflare `cdn`, and a `README.md` walking
      through deploy + `nagarectl cdn status` + cache-purge + the deferred `CF-Cache-Status: HIT`
      curl.
- [x] Milestone 2 — create `cluster/examples/tanstack-start-cdn/` (TanStack Start behind Google
      Cloud CDN): `package.json`, `nagare/Config.hs` with a `gcpCloudCdn`, and a `README.md`
      walking through `pulumi config set nagare:enableCdn true && pulumi up`, deploy,
      `nagarectl cdn status`, and the deferred cache-`Age:` curl.
- [x] Milestone 2 — verified the offline acceptance: `nagarectl site deploy --dry-run` (run from
      `cli/nagarectl/`) renders nginx/Dockerfile + Knative Service + DomainMapping + the planned
      CDN-changes block in each example, and a no-CDN config prints zero CDN banners (unchanged).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The actual EP-58 dry-run block is `--- CDN plan (Cloudflare) ---` / `--- CDN plan (GcpCloudCdn)
  ---` with `DNS:` / `Origin TLS:` / `Cache:` lines (Cloudflare) and `gcloud …` lines (Google),
  produced by `renderCdnPlan`. This plan's draft showed an illustrative `--- Planned CDN changes
  ---` format; the guide and READMEs document the **real** output instead. The Google plan's
  `gcloud` lines each carry `--project=tan-nb-exp`, and unresolved stack outputs render as
  `<publicIp>`/`<cdnGlobalIp>`/`<dnsZoneName>`/`<cdnBackendService>` placeholders in the offline
  dry-run (the real values substitute when the Pulumi stack is available).

- The copied `tanstack-start` example config used a bare `EnvLiteral "0.0.0.0"` in the
  `ServerSite.env` map, which no longer type-checks — that field is `Map EnvName ScopedEnvVar`, so
  it needs `runtimeScoped (EnvLiteral "0.0.0.0")`. The pre-existing `tanstack-start` example shares
  this staleness (it is not exercised by tests). The new `tanstack-start-cdn` config uses
  `runtimeScoped` and dry-runs cleanly.

- Verified offline: the static example dry-run prints `--- Generated nginx.conf ---`, `--- Knative
  Service manifest ---`, `--- DomainMapping manifest ---` (`blog.apps.example.com`), the URL, and
  the `--- CDN plan (Cloudflare) ---` block; the no-CDN `static-site` baseline prints **zero** CDN
  banners (`grep -c "CDN plan"` → 0), confirming MasterPlan 11's "unchanged when no CDN" promise.


## Decision Log

Record every decision made while working on the plan.

- Decision: ship a dedicated CDN guide and runbook (`docs/user/cdn.md`) rather than folding CDN
  content into the existing `docs/user/static-hosting.md`.
  Rationale: a CDN introduces concerns that static hosting does not — splitting a hostname's DNS
  authority off to a different provider, edge versus origin TLS modes (`Flexible`/`Full`/
  `Full (strict)`), the cert-manager DNS-01 caveat when a zone moves to Cloudflare, and edge
  cache semantics (default TTL, per-path overrides, "never cache", purge). These warrant their
  own runbook a reader can follow under pressure, and `cdn` applies to `ServerSite` and
  `Deployment` too, not only static sites, so it does not belong inside the static-only page.
  Date: 2026-06-10

- Decision: provide two worked examples that prove both providers AND both runtimes — a static
  site behind Cloudflare (`cluster/examples/static-cdn-site/`) and a TanStack Start server site
  behind Google Cloud CDN (`cluster/examples/tanstack-start-cdn/`) — as new sibling directories
  rather than mutating the existing `static-site`/`tanstack-start` examples.
  Rationale: the existing examples are referenced by `docs/user/static-hosting.md` and its
  dry-run transcripts as the no-CDN baseline; leaving them untouched preserves that baseline and
  lets the CDN examples read as a clean diff (the same config plus a `cdn` field). Cross-pairing
  the providers and runtimes (Cloudflare+static, Google+TanStack) demonstrates that `cdn` is a
  uniform, provider-agnostic and runtime-agnostic field, which is MasterPlan 11's headline
  acceptance.
  Date: 2026-06-10

- Decision: deliver the docs and examples and the dry-run-verifiable acceptance now; defer the
  live cache-HIT proofs (Cloudflare `CF-Cache-Status: HIT`, Google Cloud CDN cache-`Age:`) until
  `nagare-01` is powered on and a real delegated domain plus a real `CF_API_TOKEN` exist.
  Rationale: the VM is powered off and the placeholder base domain `apps.example.com` is not
  delegated, so a live edge cannot be reached. This matches how MasterPlan 3's EP-17 and the
  database/task docs plans handle the powered-off box: ship everything that is verifiable offline,
  mark the live leg clearly as the intended behaviour, and gate it on the box coming back up.
  Date: 2026-06-10

- Decision: write the example `nagare/Config.hs` files threading `withCacheRule` monadically in
  the `Either String` do-block, not as the pure `&`-chain shown in MasterPlan 11's vision excerpt.
  Rationale: EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`) defines
  `withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn` (it validates the per-path TTL),
  while `withDefaultTtl` and `withoutStaticAssetCache` are total `Cdn -> Cdn`. The MasterPlan's
  `&`-only excerpt is illustrative; the real, compiling code must bind the `Either` result. The
  examples must compile under `nagarectl site deploy --dry-run`, so they use the true signatures.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-10).** The CDN initiative is proven end to end offline. `docs/user/cdn.md` is
a self-contained guide + DNS/origin-TLS runbook (what a CDN buys you and which to choose, the typed
`cdn` field, the cache model, the deploy flow with the real `--dry-run` block, the `nagarectl cdn`
command surface, and the runbook covering proxied-vs-more-specific DNS, the `Flexible →
Full (strict)` / Google-HTTPS origin-TLS modes, the cert-manager DNS-01 caveat, and provider
credentials). It is linked from the operator-guide index and the status table. Two worked examples
demonstrate both providers AND both runtimes — `static-cdn-site` (static + Cloudflare) and
`tanstack-start-cdn` (TanStack Start + Google Cloud CDN) — each a clean diff over its no-CDN
sibling (the same config plus a `cdn` field). Both dry-run cleanly from `cli/nagarectl/`, printing
the rendered Service/DomainMapping and the planned CDN changes; the no-CDN baseline is unchanged.

**Gaps / deferred.** The live cache-HIT proofs (Cloudflare `CF-Cache-Status: HIT`, Google Cloud CDN
growing `Age:`) and the live `nagarectl cdn list`/`status` discovery are deferred until `nagare-01`
is powered on, the base domain is delegated, and a real `CF_API_TOKEN` exists — documented in both
READMEs and the guide as the intended behaviour, matching the powered-off-box gating MasterPlan 3's
EP-17 and the database/task docs plans used. No code was changed by this plan; it consumes the
EP-55/56/57/58 surfaces verbatim.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**Nagare** (流れ, "flow") is a single-node personal Platform-as-a-Service. There is one VM,
`nagare-01`, in the GCP project `tan-nb-exp`, region `us-west1`, zone `us-west1-a`. It has a
reserved static public IP (the Pulumi stack output `publicIp`). On the host runs **k3s** (a
small Kubernetes), **Knative Serving** (request-driven, scale-to-zero containers), and
**Kourier** (Knative's ingress gateway) listening on host ports 80 and 443. Knative routes an
incoming request to the right app by reading the **`Host` header**; a custom hostname is wired
to a Knative Service through a **DomainMapping** object. The VM is **currently powered off**, so
every "live" step in this plan is deferred until it is back up — this is stated honestly in the
docs, exactly as `docs/user/static-hosting.md` flags its placeholder `apps.example.com` URLs.

**DNS today.** There is a Cloud DNS managed zone for the base domain (placeholder
`apps.example.com`; stack output `dnsZoneName`) holding a wildcard `*.<baseDomain>` `A` record
pointing at the VM's static IP, created by Pulumi. The operator delegates the base domain to
Google's nameservers at their registrar. A request to `notes.personal.apps.example.com`
therefore resolves to the VM and Kourier routes it by `Host`. The Pulumi config key for the
base domain is `nagare:baseDomain` (default `apps.example.com`).

**TLS today.** The cluster runs **cert-manager** (the standard Kubernetes certificate
controller) with a `letsencrypt-dns` ClusterIssuer that obtains **Let's Encrypt wildcard
certificates** via a **DNS-01 challenge** — it proves domain control by writing an
`_acme-challenge` TXT record into the Cloud DNS zone (the service account holds `roles/dns.admin`
for exactly this). HTTPS is currently **deferred / HTTP-first**: it is enabled by a single flip
of `external-domain-tls: Enabled` once the domain is delegated and the box is up. This matters
to CDN work because the origin-TLS decisions below depend on the origin being able to present a
valid certificate on port 443.

**The typed config a developer writes.** Instead of YAML, an app or site author ships a small,
compiler-checked `nagare/Config.hs`. The typed model lives in the `nagare-dsl` Haskell library
under `cli/nagare-dsl/`; the CLI and webhook runner live under `cli/nagarectl/`. A static site
is a `StaticSite` value (module `Nagare.Dsl.Static.Types`), emitted with `emitStaticSite`; a
full-stack app is a `ServerSite` value (module `Nagare.Dsl.Server.Types`), emitted with
`emitServerSite`; a generic container app is a `Deployment`, emitted with `emitDeployment`. The
existing no-CDN examples are `cluster/examples/static-site/` (an Nginx-served folder with
`public/` and `nagare/Config.hs`) and `cluster/examples/tanstack-start/` (a TanStack Start
server site with `package.json` and `nagare/Config.hs`). They are the templates this plan
copies. `nagarectl site deploy --dry-run` compiles-and-runs the config with `runghc` and prints
the generated artifacts (Nginx config or Dockerfile, the Knative Service, any DomainMappings)
with no Docker or cluster side effects — and that loader needs to resolve the `nagare-dsl`
package, which is why the examples are dry-run from `cli/nagarectl/` (which carries a
`.ghc.environment.*` file) with `--file` pointing at the example, or with an explicit
`--ghc-env` flag.

**The CDN typed model (added by EP-55,
`docs/plans/55-typed-cdn-model-and-provider-renderer.md`).** EP-55 adds a `cdn :: Maybe Cdn`
field to `StaticSite`, `ServerSite`, and `Deployment`. The types and constructors (which this
plan documents and uses verbatim) are:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn

-- A per-path edge cache rule. Requests whose path begins with @pathPrefix@ get
-- @edgeTtlSeconds@ as their edge time-to-live in seconds; @Nothing@ means never cache.
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }

data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)   -- Nothing = no default edge TTL (origin Cache-Control wins)
  , cacheStaticAssets :: !Bool          -- True = long-cache fingerprinted js/css/fonts/images
  , cacheRules        :: ![CdnCacheRule]
  }

-- Presets: a Cloudflare CDN with sensible defaults, and the same for Google Cloud CDN.
cloudflareCdn :: Cdn   -- provider = CloudflareCdn, defaultTtlSeconds = Nothing,
                       -- cacheStaticAssets = True, cacheRules = []
gcpCloudCdn   :: Cdn   -- same as cloudflareCdn but provider = GcpCloudCdn

-- Total combinators (cannot fail):
withDefaultTtl          :: Int -> Cdn -> Cdn          -- set the default edge TTL
withoutStaticAssetCache :: Cdn -> Cdn                 -- turn the static-asset long-cache off

-- Validating combinator (the per-path TTL is checked, so it returns Either):
withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn   -- Nothing TTL = never cache
```

Because `withCacheRule` returns `Either Text Cdn`, the example configs thread it inside the
existing `Either String` do-block rather than as a pure `&`-chain. The `&` operator (reverse
application, from `Data.Function`) is still used for the total combinators.

**The deploy wiring and command group (added by EP-58,
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`).** After the existing
config-load step, the deploy engine reads `cdn :: Maybe Cdn`; when it is `Just`, it dispatches on
`provider` to either the Google capability (EP-56) or the Cloudflare capability (EP-57), points
the custom hostname at that provider's edge, applies the declared cache behaviour, and prints the
edge-served URL. `nagarectl site deploy --dry-run` shows the **planned CDN changes** (provider,
DNS target, cache rules) alongside the Service/DomainMapping, with no cloud side effects. The new
command group is `nagarectl cdn list`, `nagarectl cdn status <host>`, `nagarectl cdn purge <host>
[--path P]`, and `nagarectl cdn disable <host>` (tear the CDN down and route DNS back to the VM).

**The Cloudflare capability (added by EP-57,
`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`).** A module
`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` talks to the Cloudflare REST API v4 (base URL
`https://api.cloudflare.com/client/v4`, every request carrying `Authorization: Bearer
<token>`). It upserts a **proxied** DNS record (an `A` record with Cloudflare's orange-cloud
"proxied" flag on, so visitors hit a nearby Cloudflare data center instead of the VM directly),
applies cache rules through the Rulesets engine, sets the **origin-TLS mode** (Cloudflare's zone
"SSL mode": `Flexible`, `Full`, or `Full (strict)`), and purges the edge cache. It reads a
**scoped Cloudflare API token** from the environment variable `CF_API_TOKEN` (never the
account-global key), with an optional `CF_ZONE_ID`, and never logs the token.

**The Google Cloud CDN capability (added by EP-56,
`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`).** A `NagareCdn` Pulumi
component (TypeScript, `infra/pulumi`) builds a global external HTTP(S) load balancer in front of
`nagare-01` with caching enabled: a global **anycast** IP (one IP announced from many Google
locations), an unmanaged instance group wrapping the single VM, an HTTP health check targeting
Kourier, a CDN-enabled backend service that **preserves the `Host` header** so Knative still
routes correctly, a URL map, HTTP and HTTPS proxies and forwarding rules, and a **Google-managed
TLS certificate**. It is opt-in behind the Pulumi config flag `nagare:enableCdn` (default
`false`), and exposes the stack outputs `cdnGlobalIp`, `cdnBackendService`, and `cdnUrlMap`.

**The substrate decisions (from EP-54,
`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`).** The spike established the
ground truths the runbook must repeat: Cloudflare's steady-state origin-TLS mode is **`Full
(strict)`** (start at `Flexible` for the very first HTTP-only bring-up, then move to
`Full (strict)` once the origin presents its real Let's Encrypt wildcard certificate); Google's
origin hop runs over HTTPS once origin TLS is on; both providers must preserve the `Host` header;
and, critically, **when a zone's authoritative DNS moves to Cloudflare, cert-manager's Cloud DNS
DNS-01 challenge can no longer write `_acme-challenge` records in Cloud DNS** — so a
Cloudflare-fronted zone needs either a per-host approach that keeps DNS authority in Cloud DNS, or
a second cert-manager ClusterIssuer whose DNS-01 solver uses a Cloudflare API token.

**Reference identifiers (from `docs/user/reference.md`).** Base domain placeholder
`apps.example.com` (`nagare:baseDomain`); stack outputs include `publicIp`, `baseDomain`,
`dnsZoneName`, `artifactRegistry`; firewall admits `80`/`443` TCP from `0.0.0.0/0` (Kourier),
which is why Google's health checks already reach the origin with no new firewall rule; the
service account holds `roles/dns.admin` for the cert-manager DNS-01 solver.


## Plan of Work

The work is documentation and examples only, in two independently verifiable milestones. No
library or CLI code changes; this plan consumes the surfaces EP-55 through EP-58 define.

### Milestone 1 — the CDN guide and the DNS/origin-TLS runbook

Scope: create one new user-guide page, `docs/user/cdn.md`, and link it from the operator-guide
index `docs/user/README.md`. At the end of this milestone the guide exists, is internally
consistent with the typed model and the `nagarectl cdn` commands, and the index points at it.

Write `docs/user/cdn.md` mirroring the structure and tone of `docs/user/static-hosting.md`
(status badge at the top; prose-first; fenced blocks with language tags; a placeholder-URL
caveat). Its chapters, in order:

First, a **status badge** identical in spirit to the static-hosting page:
"🟡 Built and tested offline; live edge deploy pending `nagare-01`." Explain that the typed
model, the deploy wiring, the `nagarectl cdn` commands, the Pulumi Google Cloud CDN component,
and the Cloudflare client all exist and are tested, that `nagarectl site deploy --dry-run` shows
the planned CDN changes offline today, and that the live edge legs are deferred because the box
is powered off and the base domain is a placeholder.

Second, **"What a CDN gives you, and which one to choose."** Define CDN in plain language (a
global cache in front of the one VM). State the choice rule: **Cloudflare is the preferred
default** — larger edge network, a generous free tier, and built-in DDoS protection — and
**Google Cloud CDN** is for operators who want to stay entirely inside GCP (one cloud, one bill,
a Google-managed certificate). Note the out-of-scope boundary (no edge compute / Workers; Nagare
runs application logic on the origin VM), matching MasterPlan 11.

Third, **"Turn it on: the `cdn` field."** Show the typed model verbatim (the `Cdn`,
`CdnProvider`, `CdnCacheRule` definitions and the `cloudflareCdn`/`gcpCloudCdn` presets and the
`withDefaultTtl`/`withCacheRule`/`withoutStaticAssetCache` combinators). Show the minimal
addition to a config: `cdn = Just (cloudflareCdn & withDefaultTtl 3600)` for the total case, and
the `Either`-threaded form for `withCacheRule`. Emphasise the `Nothing` TTL = never cache
semantics and the static-asset toggle.

Fourth, **"The cache model."** Explain default TTL (`defaultTtlSeconds`), the static-asset
long-cache toggle (`cacheStaticAssets`), per-path overrides (`cacheRules`, longest-prefix wins),
and that a `Nothing` edge TTL means the edge never caches that path (e.g. `/api/`). Relate it to
the origin's own `Cache-Control` (the origin Nginx cache policy from MasterPlan 3 still applies;
the CDN layers on top).

Fifth, **"Deploy flow."** `nagarectl site deploy` builds/pushes/applies exactly as before, then
provisions the CDN because `cdn` is set, and prints the edge-served URL. Show the `--dry-run`
output shape including the planned-CDN-changes block.

Sixth, **"Operating the edge: `nagarectl cdn`."** Document `list`, `status <host>`,
`purge <host> [--path P]`, and `disable <host>` with a one-line transcript each.

Seventh, the **DNS + origin-TLS RUNBOOK** chapter. This is the load-bearing part. Cover: how a
CDN hostname's DNS is split off (Cloudflare: a **proxied** `A` record at the edge; Google: a
**more-specific** exact-hostname `A` record to the anycast IP that beats the broad
`*.<baseDomain>` wildcard, because DNS resolution prefers the most specific match); the
origin-TLS modes from EP-54 (`Flexible` for first bring-up → `Full (strict)` steady state for
Cloudflare; HTTPS origin for Google); the **cert-manager DNS-authority caveat** (moving a zone to
Cloudflare blocks the Cloud DNS DNS-01 challenge; keep DNS authority in Cloud DNS per-host, or add
a Cloudflare-token ClusterIssuer); and provider credential setup (a scoped `CF_API_TOKEN` with the
minimal scopes — Zone DNS edit, Zone cache purge, Zone cache rules, Zone settings, on exactly one
zone; and `nagare:enableCdn true` + `pulumi up` for Google).

Then wire `docs/user/cdn.md` into `docs/user/README.md`: add a bullet under the "Deploying apps"
group, immediately after the "Static & full-stack site hosting" entry, with the same 🟡 badge,
and add a status-table row mapping the CDN area to MasterPlan 11 / EP-54–59.

Commands to run for acceptance (from the repo root): `ls docs/user/cdn.md` and a `grep` showing
the README links to it. Acceptance: the guide reads end-to-end, every fenced block carries a
language tag, the typed-model excerpts match EP-55's signatures, and the index links it.

### Milestone 2 — the two worked examples and the deferred end-to-end validation

Scope: create two example directories that prove both providers and both runtimes, each with a
`nagare/Config.hs`, a `README.md`, and (for the static one) `public/` content. At the end of this
milestone both examples dry-run cleanly offline and their READMEs carry the deferred live
cache-HIT validation transcripts.

`cluster/examples/static-cdn-site/` is a copy of `static-site` plus a Cloudflare `cdn`. Copy
`public/` (an `index.html`, a `404.html`, and `assets/app.css`) and the `nagare/Config.hs`, then
add to the config: `cdn = Just …` where the CDN is `cloudflareCdn & withDefaultTtl 3600` further
refined by `withCacheRule "/assets/" (Just 31536000)` (one year for fingerprinted assets) and
`withCacheRule "/api/" Nothing` (never cache). Because `withCacheRule` is `Either`-returning,
thread it in the do-block. Set a custom domain so there is a hostname to front (e.g.
`blog.apps.example.com` via a `Domain`), since CDN routing targets a custom hostname. The
`README.md` mirrors `static-site`'s but adds: the deploy provisions Cloudflare; `nagarectl cdn
status blog.apps.example.com`; a cache-purge demo (`nagarectl cdn purge blog.apps.example.com`
and `… --path /assets/app.css`); and the **deferred** `curl -sI https://blog.apps.example.com/
assets/app.css | grep -i cf-cache-status` showing `CF-Cache-Status: HIT` to run once live.

`cluster/examples/tanstack-start-cdn/` is a copy of `tanstack-start` plus a Google Cloud CDN
`cdn`. Copy `package.json` and `nagare/Config.hs`, then add `cdn = Just (gcpCloudCdn &
withDefaultTtl 600)` refined with a `withCacheRule "/assets/" (Just 31536000)` and a
`withCacheRule "/api/" Nothing`, and a custom domain (e.g. `app.apps.example.com`). The
`README.md` mirrors `tanstack-start`'s but prepends the one-time Pulumi step
(`pulumi -C infra/pulumi config set nagare:enableCdn true && pulumi -C infra/pulumi up`) that
stands up the Google load balancer, then the deploy, `nagarectl cdn status app.apps.example.com`,
and the **deferred** cache-HIT curl reading the `Age:` header (Google Cloud CDN does not emit
`CF-Cache-Status`; a non-zero, growing `Age:` on a second request is the cache-hit signal).

Both READMEs include an explicit **"End-to-end validation (live legs DEFERRED)"** section: the
exact command sequence and the expected transcript, with the live legs marked deferred until
`nagare-01` is powered on and a real domain plus a real `CF_API_TOKEN` exist — exactly the
gating MasterPlan 3's EP-17 used.

Commands to run for acceptance (from `cli/nagarectl/`, which carries the `.ghc.environment.*`):
`cabal run nagarectl -- site deploy --dry-run --file
../../cluster/examples/static-cdn-site/nagare/Config.hs` and the same for
`tanstack-start-cdn`. Acceptance: each dry-run renders the expected Knative Service +
DomainMapping + planned CDN changes block offline (VM off); the live cache-HIT curls are present
in the READMEs but documented as deferred.


## Concrete Steps

All paths are repository-relative to `/Users/shinzui/Keikaku/bokuno/nagare`. Run editor/file
commands from the repo root; run the dry-run commands from `cli/nagarectl/`.

### Step 1 — write `docs/user/cdn.md`

Create the file with the seven chapters described in Milestone 1. The typed-model excerpt and the
combinator signatures must be copied verbatim from the Context section above (they match EP-55).
The static-site config excerpt with a Cloudflare `cdn` (threading `withCacheRule`) is:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Function ((&))
import Nagare.Dsl.Cdn.Types (cloudflareCdn, withCacheRule, withDefaultTtl)
import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- mapLeft show (mkSiteName "static-cdn-site")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-cdn-site")
  dir' <- mapLeft show (mkFilePathText "public")
  blog <- mapLeft show (mkDomain "blog.apps.example.com")
  cache' <- mapLeft show (mkCachePolicy True (Just 600))
  -- Cloudflare CDN: default 1h edge TTL, 1y for fingerprinted assets, never cache the API.
  cdn' <-
    mapLeft show
      ( withCacheRule "/api/" Nothing
          =<< withCacheRule "/assets/" (Just 31536000) (cloudflareCdn & withDefaultTtl 3600)
      )
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = [blog]
      , redirects = []
      , headers = []
      , cache = cache'
      , notFound = Nothing
      , cdn = Just cdn'
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
```

The `--dry-run` transcript to show in the guide (Service, DomainMapping, then the planned-CDN
block) is:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: static-cdn-site
  namespace: personal
...
--- Knative DomainMapping ---
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: blog.apps.example.com
  namespace: personal
spec:
  ref:
    name: static-cdn-site
--- Planned CDN changes (Cloudflare) ---
provider:    Cloudflare
host:        blog.apps.example.com
dns:         proxied A blog.apps.example.com -> <vm-public-ip>  (orange-cloud)
origin-tls:  Full (strict)
default-ttl: 3600s
cache rules: /assets/  -> 31536000s
             /api/     -> never cache
             (static assets: long-cache on)
URL: https://blog.apps.example.com
Release: 20260610-…
```

### Step 2 — wire the guide into `docs/user/README.md`

Under the "Deploying apps" group (item 8 in "Read in this order"), immediately after the
"Static & full-stack site hosting" bullet, add a "CDN (edge caching)" bullet linking
`cdn.md` with the 🟡 badge. Add a row to the status table mapping
"CDN integration (Cloudflare / Google Cloud CDN)" to "MP-11 (EP-54–59)" with status
"🟡 Built; live edge deploy pending."

### Step 3 — create `cluster/examples/static-cdn-site/`

Copy `cluster/examples/static-site/public/` verbatim, then write `nagare/Config.hs` (the Step 1
static excerpt) and a `README.md`. Verify the dry run from `cli/nagarectl/`:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/static-cdn-site/nagare/Config.hs
```

Expected: the generated `nginx.conf`, the Knative Service, the DomainMapping for
`blog.apps.example.com`, and the "Planned CDN changes (Cloudflare)" block from Step 1.

### Step 4 — create `cluster/examples/tanstack-start-cdn/`

Copy `cluster/examples/tanstack-start/package.json`, then write `nagare/Config.hs` adding a
Google Cloud CDN `cdn` and a custom domain, and a `README.md`. The config excerpt:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Cdn.Types (gcpCloudCdn, withCacheRule, withDefaultTtl)
import Nagare.Dsl.Config (emitServerSite)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkDomain, mkSiteName)
import Nagare.Dsl.Types

serverSite :: Either String ServerSite
serverSite = do
  name' <- mapLeft show (mkSiteName "tanstack-start-cdn")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/tanstack-start-cdn")
  host <- mapLeft show (mkEnvName "HOSTNAME")
  app <- mapLeft show (mkDomain "app.apps.example.com")
  cdn' <-
    mapLeft show
      ( withCacheRule "/api/" Nothing
          =<< withCacheRule "/assets/" (Just 31536000) (gcpCloudCdn & withDefaultTtl 600)
      )
  Right
    ServerSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = tanstackStartBuild
      , runtime = defaultServerRuntime
      , port = defaultPort
      , env = Map.fromList [(host, EnvLiteral "0.0.0.0")]
      , resources = Nothing
      , scale = Nothing
      , domains = [app]
      , volumes = []
      , cdn = Just cdn'
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case serverSite of
  Left err -> ioError (userError err)
  Right s -> emitServerSite s
```

Verify the dry run:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/tanstack-start-cdn/nagare/Config.hs
```

Expected: the generated Dockerfile, the Knative Service (Node image, env, scale-to-zero), the
DomainMapping for `app.apps.example.com`, and a "Planned CDN changes (Google Cloud CDN)" block
showing `provider: GcpCloudCdn`, the more-specific `A` record to the anycast IP, the HTTPS origin,
the `600s` default TTL, and the per-path rules.

### Step 5 — the deferred live validation transcripts (in each README)

In `static-cdn-site/README.md` add an "End-to-end validation (live legs DEFERRED)" section:

```bash
# 1. Provision the edge + deploy (needs Docker, gcloud, kubectl, and CF_API_TOKEN scoped to the zone).
export CF_API_TOKEN=<scoped-token>          # Zone DNS edit, cache purge, cache rules, settings
nagarectl site deploy --skip-build

# 2. Inspect the edge.
nagarectl cdn status blog.apps.example.com  # provider, DNS target, cache rules, origin-TLS, readiness

# 3. Prove a cache HIT (DEFERRED until nagare-01 is up and blog.apps.example.com is delegated):
curl -sI https://blog.apps.example.com/assets/app.css | grep -i cf-cache-status
# expected once live:  CF-Cache-Status: HIT

# 4. Purge after a deploy, then re-warm:
nagarectl cdn purge blog.apps.example.com --path /assets/app.css
curl -sI https://blog.apps.example.com/assets/app.css | grep -i cf-cache-status
# first request after purge: MISS, then HIT
```

In `tanstack-start-cdn/README.md` the parallel section, gated the same way:

```bash
# 1. Stand up the Google Cloud CDN load balancer (one time), then deploy.
pulumi -C infra/pulumi config set nagare:enableCdn true
pulumi -C infra/pulumi up
nagarectl site deploy

# 2. Inspect the edge.
nagarectl cdn status app.apps.example.com

# 3. Prove a cache HIT (DEFERRED). Google Cloud CDN has no CF-Cache-Status; use Age:
curl -sI https://app.apps.example.com/assets/app.css | grep -i age
# expected once live: a non-zero, growing Age: on the second request (served from edge cache)
```


## Validation and Acceptance

Milestone 1 acceptance (offline, today): `docs/user/cdn.md` exists and renders end-to-end; every
fenced block carries a language tag; the typed-model excerpts match EP-55's `cloudflareCdn`,
`gcpCloudCdn`, `withDefaultTtl`, `withoutStaticAssetCache`, and the `Either`-returning
`withCacheRule`; the `nagarectl cdn list|status|purge|disable` surface matches MasterPlan 11; and
`docs/user/README.md` links the page and lists the CDN area in its status table. Observe with:

```bash
ls -1 docs/user/cdn.md
grep -n "cdn.md" docs/user/README.md
grep -nE "language|```$" docs/user/cdn.md | head   # spot-check: no bare fences
```

Milestone 2 acceptance (offline, today — the headline proof): from `cli/nagarectl/`, each example
dry-runs and prints its Knative Service, its DomainMapping, and the planned CDN changes block, with
no Docker or cluster side effects:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/static-cdn-site/nagare/Config.hs
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/tanstack-start-cdn/nagare/Config.hs
```

Success is the static example showing `provider: Cloudflare` with `/assets/ -> 31536000s` and
`/api/ -> never cache`, and the TanStack example showing `provider: GcpCloudCdn` with its
more-specific anycast `A` record — both alongside a valid Service and DomainMapping. Failure shows
either a Haskell type/load error (the config does not compile against EP-55's surface) or a missing
CDN block (EP-58's dry-run wiring is absent).

Live acceptance (DEFERRED until `nagare-01` is powered on, a real domain is delegated, and a real
`CF_API_TOKEN` exists): the `CF-Cache-Status: HIT` curl for the Cloudflare static example and the
growing `Age:` curl for the Google Cloud CDN TanStack example, both transcribed in the READMEs.
This plan does not run them; it documents them as the intended behaviour, matching the powered-off-
box gating used by MasterPlan 3's EP-17 and the database/task docs plans.


## Idempotence and Recovery

Every step here writes documentation and example files; nothing touches the cloud, so all steps
are safe to repeat. Re-running an edit overwrites the same file; re-running a dry-run is read-only
and produces the same transcript. If a dry-run fails because the loader cannot resolve
`nagare-dsl`, pass `--ghc-env /path/to/.ghc.environment.<arch>-<ghc>` (the same mechanism the
existing examples document) or run from `cli/nagarectl/` which carries that file. If the typed
model has not landed yet (EP-55 incomplete), the example configs will fail to compile against the
`Nagare.Dsl.Cdn.Types` module — that is the expected signal that this plan's HARD dependency is
unmet; pause until EP-55/EP-58 are merged. No destructive operations exist in this plan; recovery
is `git checkout -- <file>` on any doc or example you want to revert.


## Interfaces and Dependencies

This plan adds no code. It consumes, and must stay consistent with, these existing surfaces:

From EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`), the module
`Nagare.Dsl.Cdn.Types` exporting `data Cdn`, `data CdnProvider (CloudflareCdn | GcpCloudCdn)`,
`data CdnCacheRule`, the presets `cloudflareCdn :: Cdn` and `gcpCloudCdn :: Cdn`, the total
combinators `withDefaultTtl :: Int -> Cdn -> Cdn` and `withoutStaticAssetCache :: Cdn -> Cdn`, and
the validating `withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn`; plus the
`cdn :: Maybe Cdn` field added to `StaticSite`, `ServerSite`, and `Deployment`. The example
configs use `mkSiteName`, `mkNamespace`, `mkImageRef`, `mkFilePathText`, `mkCachePolicy`,
`mkDomain`, `mkEnvName`, `NoBuild`, `tanstackStartBuild`, `defaultServerRuntime`, `defaultPort`,
`EnvLiteral`, `emitStaticSite`, and `emitServerSite` from the existing
`Nagare.Dsl.Static.Types`, `Nagare.Dsl.Server.Types`, `Nagare.Dsl.Types`, and `Nagare.Dsl.Config`.

From EP-58 (`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`): the
`nagarectl site deploy` provisioning-on-`cdn` behaviour, the `--dry-run` planned-CDN-changes
block, and the `nagarectl cdn list|status <host>|purge <host> [--path P]|disable <host>` command
group, documented verbatim.

From EP-57 (`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`): the
`CF_API_TOKEN` (scoped) and optional `CF_ZONE_ID` credential model, the proxied-DNS-record and
origin-TLS-mode (`Flexible`/`Full`/`Full (strict)`) concepts the runbook cites.

From EP-56 (`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`): the
`nagare:enableCdn` Pulumi flag, `pulumi -C infra/pulumi up`, the anycast IP, the Host-preserving
backend, the Google-managed certificate, and the `cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap`
outputs the TanStack example's runbook cites.

From EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`): the steady-state
origin-TLS decisions (Cloudflare `Full (strict)`, Google HTTPS origin), the `Host`-header
preservation requirement, the more-specific-record-beats-wildcard DNS rule, and the cert-manager
DNS-authority caveat the runbook reproduces.

External services referenced (not invoked by this plan): the Cloudflare REST API v4
(`https://api.cloudflare.com/client/v4`) and Google Cloud CDN / the global HTTP(S) load balancer
in project `tan-nb-exp`. No new libraries are introduced.
