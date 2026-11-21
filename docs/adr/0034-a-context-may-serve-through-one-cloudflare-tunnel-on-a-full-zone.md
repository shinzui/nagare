---
title: "A context may serve through one Cloudflare Tunnel on a full zone"
status: accepted
date: 2026-11-02
authors: [shinzui]
related:
  - docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md
  - docs/plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md
  - docs/research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md
  - docs/adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md
  - docs/adr/0020-domain-routing-and-tls-ownership-are-explicit.md
  - docs/adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md
---

# ADR 34 — A context may serve through one Cloudflare Tunnel on a full zone

## Status

Accepted, 2026-11-02, on the observations in
[EP-240](../plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md). The prototype ran with the
firewall still open. Implemented for new contexts in v0.16.0 (EP-241, EP-242, EP-243 D1 and D7), which proved the closed perimeter
on a disposable context on 2026-11-03. Amended 2026-11-04, below.

## Context

A context today accepts web traffic on the VM's public address. MasterPlan 32 asks for an optional path with no inbound web port that
costs little and needs no client software. Its alternatives are compared in
[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md).

## Decision

The optional topology, for a context whose base domain is itself a Cloudflare zone on a full setup:

```text
browser -> Cloudflare edge -> tunnel -> cloudflared pod -> external kourier Service -> Knative route -> site
```

- **Records.** Proxied CNAMEs for the apex and `*` point at one remotely managed tunnel.
- **Ingress rules.** `<base>` and `*.<base>` go to the external `kourier` Service over plain HTTP inside the node, followed by a 404
  catch-all. `external-domain-tls` stays off, and the cluster holds no Cloudflare DNS credential.
- **Hostnames.** Default names are one label below the base (`{{.Name}}-{{.Namespace}}.{{.Domain}}`), because the free certificate covers
  the apex and one level only. A two-label name fails the TLS handshake.
- **Direct ingress** stays supported and is unchanged for any context that does not opt in.

## Threat model

- **Cloudflare is inside the trust boundary.** It decrypts traffic at its edge, including session cookies and page content.
- **Both Cloudflare credentials are interception credentials.** A connector started anywhere with the tunnel token receives a share of every
  request. An API token with Cloudflare Tunnel Edit reads every tunnel's token in the account. So the API token is scoped to one account and
  zone and stays on the operator's machine, the tunnel token rests sops-encrypted and in one Secret in the connector's namespace, and the account
  holds nothing else.
- **Rotation is not eviction.** Rotating `tunnel_secret` refuses the old token for new connections, but a connector already running keeps its
  connections and keeps serving until it restarts. Rotation therefore has to be paired with removing existing connections, and the status probe
  reports any connector the context did not start. Cloudflare's listing gives each connector's origin address.
- **The connector is bounded inside the cluster, not at Cloudflare.** The ingress rules are remotely managed, so the Cloudflare account can point
  them anywhere the pod can reach. The connector's namespace has a NetworkPolicy allowing egress only to the external `kourier` gateway pods, cluster
  DNS and port 7844 to public addresses, and no ingress. It runs with no service-account token, no host network and a restricted pod profile. Rules
  repointed at the API server, `kourier-internal` and the metadata server all answered 502.
- **Protected content needs two independent cache controls.** With neither, Cloudflare served an anonymous visitor a protected `.pdf` and `.js`
  with `200 HIT` after one signed-in fetch. A zone cache rule that bypasses the cache for every hostname, and `Cache-Control: private, no-store` on the
  proxied response, each stop it alone. Both ship. The rule also stops an already stored copy being served.
- **Cloudflare may rewrite responses.** It injected its analytics beacon into the login form and signed-in protected pages for browser-like requests
  with zone setting `rum` already `off`, and the zone-scoped token cannot read the Web Analytics setting. `Cache-Control: no-transform` stops the
  injection and `private, no-store` does not. So the enforcer's header is `private, no-store, no-transform`. Email obfuscation and Rocket Loader are off;
  `automatic_https_rewrites` and `server_side_exclude` were left on by the prototype and are for EP-242 to decide.
- **Edge policy is part of the topology.** Always Use HTTPS, minimum TLS 1.2 and SSL mode strict are set on the zone, because Cloudflare's defaults are a
  TLS 1.0 minimum and no redirect, and Knative serves plain HTTP.
- **Visitor address.** Nothing raises Kourier's `trusted-hops-count`. `CF-Connecting-IP` is trusted only once the perimeter is closed, since until then a
  direct client could forge it.

## Consequences

- An operator accepts Cloudflare's limits: a 100 MB upload, no edge request logs on Free or Pro, and a 125-second read timeout. A stream that sends
  regularly is unaffected (200 s observed); one silent for longer is reset at about 126 s.
- Measured from one workstation, time to first byte excluding TLS setup was 85 ms at p50 through the tunnel against 73 ms direct
  (EP-240). EP-245 D7 on `ep245e`, 2026-11-15, through the edge to the admin API: 91 ms p50 and 137 ms p95 on a new connection,
  64 ms p50 and 92 ms p95 on a reused one, and 75 ms p50 for a `304` revalidation. Fifty concurrent clients for 60 seconds against a
  public site made 42,002 requests at about 700 per second with none failed, 65 ms p50 and 98 ms p95; the two connectors did not
  restart and peaked at 54 MB of their 256 MiB limit and half a core
  ([evidence](../audits/ep245e-edge-2026-11-15/measure.tsv)).
- Moving a context changes its default hostnames, and ADR 29 grants are per hostname, so a move carries its routes and grants.
- Local-mode contexts, more than one tunnel per context, and per-site CDN stay out of scope.

## Amendment — 2026-11-04: machine clients, caching validators and attribution

A review of the shipped code against the API, performance and security found four gaps, decided here and implemented by
[EP-245](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/245-make-the-tunnel-s-edge-safe-and-fast-for-api-clients-and-protected-assets.md).

- **The header control tightens and never replaces.** The enforcer adds `private` and `no-transform` to a proxied protected
  response, removes `public` and `s-maxage`, strips `Cloudflare-CDN-Cache-Control`, `CDN-Cache-Control` and `Surrogate-Control`,
  which Cloudflare reads in preference to `Cache-Control`, and keeps everything else the upstream said: `no-cache`, `no-store`,
  `max-age`, `immutable` and its validators. A response with no `Cache-Control` gets `private, no-store, no-transform`. Cloudflare
  documents `private` as uncacheable on its own, so the two independent controls stand. Replacing the header had turned the admin
  API's `private, no-cache` and strong `ETag` into `no-store`, so no client revalidated, and had emptied the browser cache of every
  protected site on each visit.
- **The edge never challenges a machine client.** Browser Integrity Check is off on the zone, Browser Cache TTL respects origin
  headers, and Bot Fight Mode and Under Attack mode are never turned on, because a challenge is a hard failure for a bearer-token
  client or a webhook sender and no rule can skip those two.
- **HSTS is set at the edge:** six months, `includeSubDomains`, no preload. The zone holds nothing but the installation, so every
  name under it serves HTTPS already.
- **Attribution without edge logs.** In tunnel mode the enforcer's and the admin API's access lines carry `CF-Connecting-IP` and
  `CF-Ray`. No access decision or throttle keys on them: Kourier's external Service is a `ClusterIP` any pod can reach with a forged
  header.

Implementation (EP-245) settled two further points:

- **Without an edge, the enforcer removes `CF-Connecting-IP` and `CF-Ray`** before any upstream sees them, so an address on the
  admin API's access line was forwarded by a tunnel-mode enforcer, never chosen by a direct client. The Auth component sets
  `NAGARE_ACCESS_EDGE_ATTRIBUTION=cloudflare` beside the cache header in tunnel mode only.
- **Number- and object-valued zone settings** (`browser_cache_ttl`, `security_header`) are a separate inventory spec compared
  structurally on the declared keys, so the string settings keep their recorded encoding and a field Cloudflare adds to a value
  is not drift.

The first measured latency and load baseline through the edge is EP-245 D7, recorded under Consequences.

## Amendment — 2026-11-16: a direct context can move to a new base that is a Cloudflare zone (EP-246)

Besides moving onto a tunnel on its own domain (EP-243), a direct context can move to a new base domain that is already an active
Cloudflare zone, served by one tunnel. The base is still the zone, so the free edge certificate covers every name; default names
flatten and a name two labels deep is refused. The move is one cutover with a stated sign-in outage, because a context has one cookie
domain and one relying party. See [Moving a context to a new base domain](../user/moving-to-a-new-base-domain.md).
