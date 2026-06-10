# static-cdn-site — a static site fronted by Cloudflare (MasterPlan 11, EP-59)

> 🟡 **Built and tested offline; live edge deploy pending `nagare-01`.** The
> `--dry-run` below works today; the live `CF-Cache-Status: HIT` curl is deferred
> until the VM is powered on and `blog.apps.example.com` is delegated to a
> Cloudflare zone with a scoped `CF_API_TOKEN`.

This is the `static-site` example plus **one new field** — `cdn = Just …` in
`nagare/Config.hs`. The same `nagarectl site deploy` builds and applies the Nginx
Service and the DomainMapping exactly as before, and then — because `cdn` is set —
provisions a Cloudflare edge in front of `blog.apps.example.com`: a proxied DNS
record at Cloudflare's edge, the origin-TLS mode, and the declared cache rules.

The CDN declaration (see `nagare/Config.hs`):

```haskell
cdn' <-
  mapLeft show
    ( withCacheRule "/api/" Nothing
        =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
    )
-- ... cdn = Just cdn'
```

That reads: front the site with Cloudflare, a 1-hour default edge TTL, cache
`/assets/` for a year, and never cache `/api/`. `withCacheRule` validates the
per-path TTL so it is threaded in the `Either` do-block; `withDefaultTtl` is total.

## Dry-run (works offline today)

From `cli/nagarectl/` (which carries the `.ghc.environment.*` the loader needs):

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/static-cdn-site/nagare/Config.hs
```

After the rendered Nginx config, Knative Service, and the `blog.apps.example.com`
DomainMapping, it prints the planned CDN changes (no cloud side effects):

```text
--- CDN plan (Cloudflare) ---
DNS: blog.apps.example.com -> <publicIp> (proxied)
Origin TLS: Flexible
Cache: /assets/ -> 31536000s
Cache: /api/ -> never
Cache: (static assets) -> 31536000s
Cache: (default) -> 3600s
```

(`<publicIp>` is the VM's reserved IP — the real value is substituted from the
`publicIp` Pulumi stack output when the stack is available.)

## End-to-end validation (live legs DEFERRED until `nagare-01` is up)

A scoped Cloudflare API token is required — **Zone › DNS › Edit**, **Zone › Cache
Rules › Edit**, the **cache-purge** capability, and **Zone › Zone Settings › Edit**,
restricted to the one zone. Never the account-global key.

```bash
# 1. Provision the edge + deploy.
export CF_API_TOKEN='<scoped-token>'
nagarectl site deploy --skip-build           # the files in public/ are served as-is

# 2. Inspect the edge.
nagarectl cdn status blog.apps.example.com   # provider, DNS target, cache, readiness

# 3. Prove a cache HIT (DEFERRED until the box is up and the host is delegated):
curl -sI https://blog.apps.example.com/assets/app.css | grep -i cf-cache-status
#   first request:  cf-cache-status: MISS
#   second request: cf-cache-status: HIT      <- served from the Cloudflare edge

# 4. Purge after a deploy, then re-warm:
nagarectl cdn purge blog.apps.example.com --path /assets/app.css
curl -sI https://blog.apps.example.com/assets/app.css | grep -i cf-cache-status
#   first after purge: MISS, then HIT

# 5. Tear the edge down (route DNS back to the VM):
nagarectl cdn disable blog.apps.example.com
```

See `docs/user/cdn.md` for the full guide and the DNS / origin-TLS runbook
(including the cert-manager DNS-01 caveat when a zone moves to Cloudflare).
