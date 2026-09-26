# static-cdn-site — a static site fronted by Cloudflare (MasterPlan 11, EP-59)

> 🟡 **Reviewed compilation and offline provider tests passed.** A live
> Cloudflare zone and delegated host are still needed for edge verification.

This is the `static-site` example plus **one new field** — `cdn = Just …` in
`nagare/Config.hs`. The reviewed `nagarectl site deploy` declares the Nginx
Service and DomainMapping, plus a proxied Cloudflare DNS record and typed
cache contribution authorized by an accepted platform zone grant.

The CDN declaration (see `nagare/Config.hs`):

```haskell
cdn' <-
  first show
    ( withCacheRule "/api/" Nothing
        =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
    )
-- ... cdn = Just cdn'
```

That reads: front the site with Cloudflare, a 1-hour default edge TTL, cache
`/assets/` for a year, and never cache `/api/`. `withCacheRule` validates the
per-path TTL so it is threaded in the `Either` do-block; `withDefaultTtl` is total.

## Reviewed dry run

Set `CF_ZONE_ID` to an accepted platform zone grant and publish the exact site
image archive with `app image-plan`. The dry run then prints the canonical public
scope for the site, host DNS claim, and cache contribution without mutating the
provider:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --skip-build --tag TAG \
  --image-resource RESOURCE-ID --dry-run \
  --file ../../cluster/examples/static-cdn-site/nagare/Config.hs
```
## End-to-end validation (live legs DEFERRED until `nagare-01` is up)

A scoped Cloudflare API token is required — **Zone › DNS › Edit**, **Zone › Cache
Rules › Edit**, the **cache-purge** capability, and **Zone › Zone Settings › Edit**,
restricted to the one zone. Never the account-global key.

```bash
# 1. Use the accepted platform zone and image publication, then deploy.
export CF_API_TOKEN='<scoped-token>'
export CF_ZONE_ID='<accepted-zone-id>'
export CF_ACCOUNT_ID='<zone-account-id>'
nagarectl site deploy --skip-build --tag TAG --image-resource RESOURCE-ID

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
