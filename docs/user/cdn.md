# CDN (edge caching)

> 🟡 **Built and tested offline; live edge deploy pending `nagare-01`.** The typed
> `cdn` field, the deploy-time provisioning, the `nagarectl cdn` command group, the
> Google Cloud CDN Pulumi component, and the Cloudflare client all exist and are
> unit-tested. `nagarectl site deploy --dry-run` shows the planned CDN changes
> offline today. The live edge legs — the actual `CF-Cache-Status: HIT` curl
> against Cloudflare and the Google Cloud CDN cache-`Age:` curl — are **deferred**
> because the VM is powered off and the base domain `apps.example.com` is a
> placeholder, exactly as the static-hosting and database guides flag their live
> legs.

A **Content Delivery Network (CDN)** is a globally distributed cache that sits in
front of your origin. Instead of every request travelling to Nagare's one VM in
`us-west1`, a visitor near London or Tokyo is served a cached copy from a nearby
edge location, and only cache-misses reach the VM. You turn a CDN on by adding a
`cdn` field to the same typed `nagare/Config.hs` you already write — no separate
CDN console, no hand-written load-balancer YAML, no manual DNS edits.

The two worked examples for this guide are
[`cluster/examples/static-cdn-site/`](../../cluster/examples/static-cdn-site/) (a
static site behind Cloudflare) and
[`cluster/examples/tanstack-start-cdn/`](../../cluster/examples/tanstack-start-cdn/)
(a TanStack Start app behind Google Cloud CDN).

## What a CDN gives you, and which one to choose

Nagare ships two interchangeable CDN backends behind one typed contract:

- **Cloudflare (the preferred default).** A reverse proxy in front of the VM's
  public IP, configured through the Cloudflare API by `nagarectl`. Larger edge
  network, a generous free tier, and built-in DDoS protection. Choose this unless
  you have a reason not to.
- **Google Cloud CDN.** A global external HTTP(S) load balancer with caching
  enabled, provisioned through Pulumi. For operators who want to stay entirely
  inside GCP — one cloud, one bill, a Google-managed TLS certificate.

**Out of scope** (matching MasterPlan 11): edge compute (Cloudflare Workers,
Google edge functions). Nagare runs your application logic on the origin VM by
design; the CDN only caches in front of it.

## Turn it on: the `cdn` field

The typed model lives in `Nagare.Dsl.Cdn.Types`:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn

-- A per-path edge cache rule. Requests whose path begins with pathPrefix get
-- edgeTtlSeconds as their edge TTL (seconds); Nothing means "never cache this path".
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
cloudflareCdn :: Cdn   -- CloudflareCdn, no default TTL, static-asset caching on, no rules
gcpCloudCdn   :: Cdn   -- same, but provider = GcpCloudCdn

-- Total combinators (cannot fail):
withDefaultTtl          :: Int -> Cdn -> Cdn   -- set the default edge TTL
withoutStaticAssetCache :: Cdn -> Cdn          -- turn the static-asset long-cache off

-- Validating combinator (the per-path TTL is checked, so it returns Either):
withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn   -- Nothing TTL = never cache
```

The field added to `StaticSite`, `ServerSite`, and `Deployment` is
`cdn :: Maybe Cdn`. `Nothing` means "no CDN" — every existing config and deploy is
byte-for-byte unchanged.

The minimal addition, when no per-path rule is needed (both combinators are total,
so a pure `&`-chain works):

```haskell
import Data.Function ((&))
-- ...
, cdn = Just (cloudflareCdn & withDefaultTtl 3600)
```

When you add per-path rules, `withCacheRule` validates the TTL and returns
`Either`, so thread it in the config's `Either String` do-block:

```haskell
cdn' <-
  first show
    ( withCacheRule "/api/" Nothing
        =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
    )
-- ... cdn = Just cdn'
```

## The cache model

- **`defaultTtlSeconds`** — the edge TTL for cacheable responses with no matching
  rule. `Nothing` lets the origin's own `Cache-Control` decide.
- **`cacheStaticAssets`** — when `True`, fingerprinted static assets
  (js/css/fonts/images) get an aggressive one-year edge cache.
- **`cacheRules`** — per-path overrides, applied in order; a more-specific prefix
  wins. An `edgeTtlSeconds` of `Nothing` means the edge **never** caches that path
  (e.g. `/api/`), passing every request through to the origin.

The CDN layers on top of the origin: MasterPlan 3's origin Nginx `Cache-Control`
still applies; the edge cache is in front of it.

## Deploy flow

`nagarectl site deploy` (for a `StaticSite`/`ServerSite`) and `nagarectl deploy`
(for a `Deployment`) build, push, and apply exactly as before. Then, because `cdn`
is set, they provision the chosen CDN **after the origin is Ready** — so a CDN
hiccup never takes a working origin down — and print the edge-served URL.

`--dry-run` shows the planned CDN changes with **no** cloud side effects, after the
rendered Service and DomainMapping. For the Cloudflare static example:

```text
--- CDN plan (Cloudflare) ---
DNS: blog.apps.example.com -> <publicIp> (proxied)
Origin TLS: Flexible
Cache: /assets/ -> 31536000s
Cache: /api/ -> never
Cache: (static assets) -> 31536000s
Cache: (default) -> 3600s
```

For the Google Cloud CDN TanStack example, the plan is the exact `gcloud`
commands the deploy would run (each pinned to `--project=tan-nb-exp`):

```text
--- CDN plan (GcpCloudCdn) ---
gcloud dns record-sets create app.apps.example.com. --type=A --ttl=300 --rrdatas=<cdnGlobalIp> --zone=<dnsZoneName> --project=tan-nb-exp
gcloud compute backend-services update <cdnBackendService> --cache-mode=CACHE_ALL_STATIC --default-ttl=600 --project=tan-nb-exp
```

A config with **no** `cdn` field prints no CDN block — its deploy output is
identical to before.

## Operating the edge: `nagarectl cdn`

```bash
nagarectl cdn list                       # every CDN-fronted hostname, provider, DNS target, readiness
nagarectl cdn status blog.example.com    # one hostname's provider, DNS target, cache config, readiness
nagarectl cdn purge  blog.example.com    # purge the whole edge cache after a deploy
nagarectl cdn purge  blog.example.com --path /assets/app.css   # purge specific paths (repeatable)
nagarectl cdn disable blog.example.com   # tear the CDN down and route DNS back to the VM
```

`purge` and `disable` accept `--dry-run` and print the planned action without
making it. (Live `cdn list`/`status` discovery reads the cluster and the cloud
provider, so it is part of the deferred live legs while the VM is off.)

## DNS + origin-TLS runbook

This is the operationally subtle part. Read it before fronting a real hostname.

### How a CDN hostname's DNS is split off

- **Cloudflare.** The hostname's authoritative DNS lives at Cloudflare, and the
  record is **proxied** (Cloudflare's "orange-cloud" `A` record): visitors hit a
  nearby Cloudflare data center, which forwards cache-misses to the VM's public IP.
  `nagarectl` upserts this record for you.
- **Google Cloud CDN.** The Cloud DNS zone keeps its broad `*.<baseDomain>`
  wildcard pointing at the VM. For a CDN-fronted hostname, `nagarectl` writes a
  **more-specific** exact-hostname `A` record pointing at the load balancer's
  anycast IP (`cdnGlobalIp`). DNS resolution prefers the most specific match, so
  the exact record wins over the wildcard without touching it. `nagarectl cdn
  disable` deletes that more-specific record and the hostname falls back to the
  wildcard/VM.

### Origin-TLS modes (how the edge talks back to the VM)

From the EP-54 substrate spike:

- **Cloudflare.** Start at **`Flexible`** for the very first HTTP-only bring-up
  (edge serves HTTPS to the browser, talks to the origin over plain HTTP — works
  against today's HTTP-first Kourier origin). Move to **`Full (strict)`** as the
  steady state once the origin presents its real Let's Encrypt wildcard on port
  443 (the edge encrypts *and* verifies the origin certificate).
- **Google Cloud CDN.** The edge terminates client TLS with a Google-managed
  certificate; the origin hop runs over HTTPS once origin TLS is enabled.

### The cert-manager DNS-authority caveat (Cloudflare only)

Today the origin certificate is issued by cert-manager using a **Cloud DNS DNS-01
challenge** — it proves domain control by writing an `_acme-challenge` TXT record
into the Cloud DNS zone. When a zone's authoritative DNS **moves to Cloudflare**,
that challenge can no longer be satisfied from Cloud DNS. Resolve it one of two
ways before moving to `Full`/`Full (strict)`:

1. **Cloudflare-token solver (recommended).** Add a second cert-manager
   `ClusterIssuer` whose DNS-01 solver uses a scoped Cloudflare API token, so
   certificates for Cloudflare-hosted zones are validated where the zone now lives.
   This keeps publicly-trusted Let's Encrypt certificates.
2. **CNAME delegation.** Keep issuance on Cloud DNS by adding, in the Cloudflare
   zone, a CNAME `_acme-challenge.<host>` → `<host>.<cloud-dns-zone>` so
   cert-manager still solves in Cloud DNS.

### Provider credentials

- **Cloudflare.** A **scoped** API token (never the account-global key) in the
  `CF_API_TOKEN` environment variable, with the minimal scopes on exactly one
  zone: **Zone › DNS › Edit**, **Zone › Cache Rules › Edit**, the cache-purge
  capability, and **Zone › Zone Settings › Edit**. Optionally set `CF_ZONE_ID`;
  otherwise the zone is discovered from the hostname's registrable domain.
- **Google Cloud CDN.** Provision the standing load balancer once with `pulumi -C
  infra/pulumi config set nagare:enableCdn true && pulumi -C infra/pulumi up` (it
  is billable, so it is opt-in and never created implicitly).

## See also

- [`cluster/examples/static-cdn-site/`](../../cluster/examples/static-cdn-site/) — static site + Cloudflare.
- [`cluster/examples/tanstack-start-cdn/`](../../cluster/examples/tanstack-start-cdn/) — TanStack Start + Google Cloud CDN.
- [Static & full-stack site hosting](static-hosting.md) — the no-CDN baseline.
