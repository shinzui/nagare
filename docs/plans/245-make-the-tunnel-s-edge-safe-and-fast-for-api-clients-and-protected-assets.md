---
id: 245
slug: make-the-tunnel-s-edge-safe-and-fast-for-api-clients-and-protected-assets
title: "Make the tunnel's edge safe and fast for API clients and protected assets"
kind: exec-plan
created_at: 2026-11-04T13:59:20Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T13:59:20Z
---

# Make the tunnel's edge safe and fast for API clients and protected assets

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

A machine client of the admin API, a webhook sender, or a browser on a protected site gets the same result through the
Cloudflare edge as it would directly: no challenge page, a `304 Not Modified` when its `If-None-Match` matches, hashed assets
served from its own cache on the next visit, and a `Strict-Transport-Security` header on every response. The operator can
read who made a request in tunnel mode, see the connector's metrics in Grafana, and knows what latency the edge adds, from
a measurement rather than an estimate. Nothing here weakens the two cache controls or the connector's bound.


## Progress

Each item passes only with the named evidence.

- [ ] D1: The enforcer tightens the proxied `Cache-Control` instead of replacing it. It keeps the upstream's directives,
  adds `private` and `no-transform`, removes `public` and `s-maxage`, and strips `CDN-Cache-Control`,
  `Cloudflare-CDN-Cache-Control` and `Surrogate-Control`, which Cloudflare reads in preference to `Cache-Control`. A
  response with no upstream `Cache-Control` gets `private, no-store, no-transform`, as today. `EdgeCacheControlSpec`
  covers: no upstream header; `public, max-age=31536000, immutable`; `private, no-cache` with an `ETag`; `no-store`; a
  `Cloudflare-CDN-Cache-Control` header; and direct mode, where nothing changes. Natively on a disposable context: a
  signed-in `If-None-Match` to `admin.<base>/v1/openapi.json` answers `304` through the edge; EP-242 D6's leak check is
  repeated with the new header on `.pdf` and `.js` and an anonymous request never sees `HIT`; a protected echo sending
  `Cloudflare-CDN-Cache-Control: max-age=600` answers `cf-cache-status: DYNAMIC` to the next anonymous request.
- [ ] D2: The edge never challenges a non-browser client. The zone's edge policy declares `browser_check` off and
  `browser_cache_ttl` as respect existing headers, with fake-adapter drift tests like the existing settings. `docs/user`
  says never to turn on Bot Fight Mode or Under Attack mode on the zone, because they challenge API clients and no rule can
  skip them, and the token cannot manage them. Natively: a request with no `User-Agent` and a bearer token to
  `admin.<base>/v1/openapi.json` answers `200` through the edge, and a signed webhook delivery to `nagared` is accepted.
- [ ] D3: HSTS at the edge. The edge policy declares `security_header` with `Strict-Transport-Security` on, a six-month
  `max-age`, `includeSubDomains` on, preload off and `nosniff` off. Drift tests cover a zone that turns it off. Natively,
  every response through the edge carries the header. `docs/user/choosing-ingress.md` states the consequence: once set,
  every name under the zone must serve HTTPS for six months, which is why the zone holds nothing but this installation.
- [ ] D4: Visitor attribution in tunnel mode. The enforcer writes one bounded JSON access line per request, like the admin
  API's, and in tunnel mode both carry `CF-Connecting-IP` and `CF-Ray`, read through an environment variable the Auth
  component sets only in tunnel mode, as it does `NAGARE_ACCESS_PROXIED_CACHE_CONTROL`. Nothing authorizes, throttles or
  records a decision on them. Tests: the line carries both in tunnel mode, neither in direct mode, and never a cookie,
  bearer token or query string.
- [ ] D5: Checks run concurrently. `nagarectl domains check` probes hostnames with a bounded concurrency of eight, and
  `nagarectl doctor` issues its three Cloudflare reads at once. Fake-runner tests prove the order of rows is unchanged and
  that one slow probe does not delay the others. On a context with ten hostnames, `domains check` finishes in under the
  slowest probe's time plus two seconds, measured.
- [ ] D6: The connector's metrics are scraped and alerted on. A `VMPodScrape` in `monitoring` reads port 2000 of the
  `cloudflared` pods, the connector NetworkPolicy admits ingress on 2000 from the `monitoring` namespace only, and one
  alert fires when `cloudflared_tunnel_ha_connections` for any pod stays below four for five minutes. Grafana shows the
  connector's request count and latency.
- [ ] D7: A measured baseline through the edge, on a disposable context from one workstation, 40 requests each, recorded
  in `docs/audits/`: admin API `GET` with a bearer token on a new and on a reused connection (TTFB p50 and p95); a `304`
  revalidation (p50); a protected documentation page's second navigation, counting asset requests before and after D1; 50
  concurrent requests for 60 seconds against a public echo, with the connector's peak CPU and memory from the metrics of
  D6. Pass: no failed request, no connector restart, peak memory under the 256 MiB limit, and a reused-connection p50 within
  25 ms of EP-240 P8's 85 ms. The numbers go into ADR 34's consequences.
- [ ] D8: `docs/user/cloudflare-tunnel.md` and `docs/user/choosing-ingress.md` describe the edge for API clients: no
  challenge, HSTS, what the enforcer does to `Cache-Control`, that any stream or WebSocket silent for 125 seconds is reset so
  applications send keepalives, and which headers carry the visitor address. ADR 34 is amended with D1 to D4 and D7.
  `just user-documentation-validate` passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `CF-Connecting-IP` is read for attribution only, never for an access decision or a throttle.
  Rationale: Kourier's external Service is a `ClusterIP` any pod in the cluster can reach, so a workload could send a
  forged header past the edge. Attribution is still useful, because Free and Pro have no edge request logs.
  Date: 2026-11-04

- Decision: `includeSubDomains` is on for HSTS and preload is off.
  Rationale: the recommended zone holds nothing but this installation and every name is proxied with Always Use HTTPS, so
  the directive costs nothing; preload is irreversible on the timescale of a mistake.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

A tunnel-mode context ([ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md)) serves every
hostname through Cloudflare's edge, then the connector, then the external `kourier` Service. The admin API
(`docs/capabilities/read-only-admin-api.md`) is one of those hostnames, `admin.<base>`, protected by the enforcer
`cli/nagare-access`. Its clients are machines: `kotei` sends a bearer token and `User-Agent: kotei/1`. `nagared` receives
signed GitHub webhook deliveries on another platform hostname.

What the review of 2026-11-04 verified in the tree:

- `cli/nagare-access/src/Nagare/Access/Proxy.hs` has `withProxiedCacheControl`, which replaces `Cache-Control` on every
  proxied protected response with the value of `NAGARE_ACCESS_PROXIED_CACHE_CONTROL`. The Auth component
  (`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`, `addEnforcerEnv`) sets it to `private, no-store, no-transform`
  in tunnel mode only. `filterRequestHeaders` forwards `If-None-Match`, so conditional requests reach the upstream.
- `cli/nagare-api-server/src/Nagare/Api/Server/Validators.hs` serves every success with a strong `ETag`,
  `Cache-Control: private, no-cache` and `Vary: Authorization, Cookie, Accept`, and answers `304` to a matching
  `If-None-Match`. In tunnel mode the enforcer overwrites that header with `no-store`, so a conforming client cache never
  holds the representation and never revalidates: every poll transfers the full body. The same replacement removes the
  `max-age` and `immutable` a site puts on hashed assets, so a protected site's browser cache is empty on every visit.
- `cli/nagarectl/src/Nagare/Inventory/Components/CloudflareZone.hs` declares `tunnelEdgePolicy`: Always Use HTTPS, TLS 1.2,
  SSL strict, and four rewriting features off. It declares nothing about Browser Integrity Check, Browser Cache TTL or HSTS.
- `cli/nagare-api-server/src/Nagare/Api/Server/RequestLog.hs` records method, path, status, duration, user agent and cache
  outcome, and no address. `cli/nagare-access` writes no request log. Nothing in the repository reads `CF-Connecting-IP`.
- `cli/nagarectl/src/Nagare/Ops/Domains.hs` probes tunnel rows with `traverse`, one `curl` with a 15-second limit per
  hostname. `cli/nagarectl/app/Nagare/Cli/Runtime/PlatformStatus.hs` makes its three Cloudflare reads one after another.
- `cluster/bootstrap/cloudflare-tunnel/connector.yaml.tmpl` runs `cloudflared` with `--metrics 0.0.0.0:2000` under a
  NetworkPolicy that denies all ingress, so nothing scrapes it. Observability is VictoriaMetrics in `monitoring`, scraped
  through `VMServiceScrape` objects such as `cluster/observability/brokers/vmservicescrape.yaml` (`docs/user/observability.md`).

What Cloudflare documents, read on 2026-11-04:

- Browser Integrity Check is on by default and "challenges visitors without a user agent or with a non-standard user agent".
  Bot Fight Mode "may challenge API or mobile app traffic" and cannot be skipped by a rule. A challenge is a hard failure for
  a machine client.
- Cloudflare does not cache a response whose `Cache-Control` is `private`, `no-store`, `no-cache` or `max-age=0`, so each of
  those is a complete header control on its own. `Cloudflare-CDN-Cache-Control` and `CDN-Cache-Control` take precedence over
  `Cache-Control` for Cloudflare's cache, and `Surrogate-Control` makes it ignore `Cache-Control`; a cache rule's own action
  wins over all of them.
- Browser Cache TTL defaults to four hours on every plan and overrides an origin `max-age` that is shorter.
- HSTS is the zone setting `security_header` with `max_age`, `include_subdomains`, `preload` and `nosniff`.
- The proxy read timeout is 125 seconds on Free and Pro; the maximum upload is 100 MB. `cloudflared` speaks HTTP/1.1 to the
  origin by default with `keepAliveConnections` 100 and `keepAliveTimeout` 90 seconds.

Relevant decisions:

- [ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md) holds the threat model and the
  two cache controls; this plan amends it.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md), 2026-11-03 amendment: a protected site
  behind the tunnel is not a CDN site and the two controls are its rule. D1 keeps both controls and changes only the header's
  shape; the amendment's quoted header value is updated.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): fakes first, one native run.
- [ADR 23](../adr/0023-observability-resource-bounds-cover-chart-and-operator-created-containers.md): the connector's
  bounds already exist; D6 adds its metrics.
- `mori://shinzui/haskell-jitsurei/docs/api-request-logging` is the shape of the access line D4 copies.


## Plan of Work

Change the enforcer first (D1, D4), because its tests run locally and the admin API's validators are the clearest proof.
Then extend `tunnelEdgePolicy` (D2, D3) with the drift tests the existing settings have. Make the probes concurrent (D5) and
add the scrape and alert (D6). Finish with one bounded native run on a disposable context that observes D1 to D3, D6 and D7
together, then write D8.

D1 lives in `withProxiedCacheControl`: parse the upstream directives, drop `public` and `s-maxage`, add `private` and
`no-transform` if absent, and strip the three CDN headers in `filterResponseHeaders`. The Auth component's value becomes the
fallback for a response with no header. D4 adds a middleware to `cli/nagare-access/app/Main.hs` and an environment variable
the Auth component sets beside the cache header. D2 and D3 add rows to `tunnelEdgePolicy`; `security_header` carries a JSON
object rather than a string, so `CloudflareZoneSettingSpec` must hold a value, not a `Text`, and the fake and live adapters
compare it structurally. D5 wraps the `traverse` in `Nagare.Ops.Domains` with a bounded concurrent map and runs the three
reads in `tunnelConnectorProbes` concurrently. D6 adds a `VMPodScrape` and an alert rule to the connector component and an
ingress rule to the NetworkPolicy in `connector.yaml.tmpl`.


## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. D1 and D4 are proven in `cabal test
nagare-access-test`, D2, D3 and D5 in `cabal test nagarectl-test`. The native run is one bounded sequence on a disposable
context, after [Before a native run](../runbooks/before-a-native-run.md) and with the operator's go-ahead, and records every
observation in `docs/audits/`. The requests that prove D1 and D2:

```bash
curl -sS -o /dev/null -w '%{http_code} %{header_json}\n' -H "Authorization: Bearer $TOKEN" -H 'User-Agent:' \
  "https://admin.$BASE/v1/openapi.json"
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -H "If-None-Match: $ETAG" \
  "https://admin.$BASE/v1/openapi.json"
```

Expected: `200` with `strict-transport-security` present and no `cf-mitigated` header, then `304`.


## Idempotence and Recovery

Every change is a reviewed inventory operation or a gateway release. The edge settings are declared state; removing a row
from `tunnelEdgePolicy` and applying restores Cloudflare's default. HSTS is the exception: once a browser has seen it, that
browser insists on HTTPS for the `max-age`, which is why preload stays off and the zone must hold nothing else.


## Interfaces and Dependencies

Requires EP-241 and EP-242 complete, which they are. Reads `NAGARE_INGRESS` through the `Target` value and extends
`tunnelEdgePolicy` in `cli/nagarectl/src/Nagare/Inventory/Components/CloudflareZone.hs` and `withProxiedCacheControl` in
`cli/nagare-access/src/Nagare/Access/Proxy.hs`. The admin API's validators in `cli/nagare-api-server` are unchanged and are
the consumer D1 is proven against. EP-244 D6 should run after D1 to D3 land, so the onboarding gate observes the final edge.
