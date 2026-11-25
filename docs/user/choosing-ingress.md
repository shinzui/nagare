---
type: Guide
title: "Choosing how a context receives traffic"
description: "Why new Nagare contexts are recommended to serve through a Cloudflare Tunnel, what that trades away, and when to choose direct ingress instead."
docId: DOC-41
tags: [cloudflare, tunnel, ingress, security, onboarding]
generated:
  by: human:nadeem
  at: 2026-11-03T00:00:00Z
---

# Choosing how a context receives traffic

**For a new context, use a [Cloudflare Tunnel](cloudflare-tunnel.md).** The VM then accepts no connection from the internet: a
scan finds nothing to attack, and a mistake in a firewall rule reaches nothing. Choose direct ingress if one of the reasons below applies.

| | Cloudflare Tunnel | Direct |
|---|---|---|
| Open to the internet | Nothing | TCP 80 and 443, and UDP 41641 for Tailscale |
| Who ends TLS | Cloudflare | Your cluster, with a Let's Encrypt wildcard |
| DNS | A full Cloudflare zone | Cloud DNS |
| Monthly cost of the path | $0 on Cloudflare Free | $0 |
| Default hostname | `<name>-<namespace>.<base>` | `<name>.<namespace>.<base>` |

## What you trade away

- **Cloudflare decrypts your traffic.** Page content and session cookies are readable at its edge.
- **Your Cloudflare account and registrar become roots of trust.** Whoever controls either controls every site. Turn on two-factor
  authentication on both, and use a Cloudflare account that holds nothing else.
- **The tunnel token is an interception credential.** A connector started anywhere with it receives a share of every request. Rotate
  it after a suspected leak, when an operator leaves, or after rebuilding a node from material you do not trust.
- **No edge request logs** on Free or Pro.
- **Limits:** a 100 MB upload, and a response silent for 125 seconds is reset. A response that keeps sending is not, so a stream
  or WebSocket must send a keepalive.
- **Never turn on Bot Fight Mode or Under Attack mode.** Both challenge API clients and webhook senders, and no rule can skip them.
- **The base domain must be the zone itself.** Cloudflare's free certificate covers the zone and one label below it, so a deeper
  custom domain needs Advanced Certificate Manager at $10 a month, which Nagare does not manage.
- **No content domains.** A [content domain](content-domains.md), which serves untrusted uploads from a separate registrable domain,
  needs direct ingress: the tunnel's ingress rules cover only the base zone.

## What Nagare sets on the zone

Always Use HTTPS, a minimum of TLS 1.2 and strict SSL. Rocket Loader, email obfuscation, server-side excludes and automatic HTTPS
rewrites are off because they rewrite hosted pages. Browser Integrity Check is off, so API clients and webhook senders are never
challenged, and Browser Cache TTL respects each site's own headers.

HSTS is on for six months with `includeSubDomains`, and preload is off. Once a browser has seen it, every name under the zone must
serve HTTPS for six months. That is why the zone should hold nothing but this installation.

One cache rule bypasses the cache for every hostname. On protected responses the gateway adds `private` and `no-transform` to the
site's `Cache-Control` and strips the headers Cloudflare reads in its place, so no cached copy can answer for a login check while
browsers keep validators and hashed assets. [API clients, webhooks and the edge](cloudflare-tunnel.md#api-clients-webhooks-and-the-edge)
has the details.

## When to choose direct ingress

- You cannot let a third party read your traffic, for legal or contractual reasons.
- Your domain cannot move to Cloudflare's name servers.
- You need uploads over 100 MB.
- You serve untrusted user content from a [content domain](content-domains.md).
- You run a local context, which has no public ingress at all.

A context on direct ingress stays supported, and can move onto the tunnel later: see [Moving an existing context onto the Cloudflare Tunnel](moving-a-context-to-the-tunnel.md). `nagarectl platform status` and `nagarectl doctor` print one line pointing here. Add
`export NAGARE_INGRESS_NOTICE=off` to the context file to silence it.

## Alternatives we did not choose

[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md) compares them. A Google load balancer costs about $19–30 a month and leaves 80 and 443 open to Google's ranges. Cloudflare for SaaS needs a
second zone. A partial Cloudflare setup costs $200–250 a month. Serving only on the tailnet does not work for visitors outside it.
