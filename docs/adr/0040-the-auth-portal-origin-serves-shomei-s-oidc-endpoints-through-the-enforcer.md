---
title: "The auth portal origin serves Shomei's OIDC endpoints through the enforcer"
status: accepted
date: 2026-11-18
authors: [shinzui]
related:
  - docs/plans/264-serve-the-platform-shomei-as-an-oidc-provider-for-native-clients.md
  - docs/improvement-requests/serve-the-platform-shomei-as-an-oidc-provider-for-native-clients.md
  - docs/adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md
  - docs/adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md
  - docs/adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md
---

# ADR 40 — The auth portal origin serves Shomei's OIDC endpoints through the enforcer

## Status

Accepted and implemented by [EP-264](../plans/264-serve-the-platform-shomei-as-an-oidc-provider-for-native-clients.md)
M1 and M2.

## Context

Shomei signs every intranet user in, but only protected web sites could use it: its Service is cluster-internal, its
issuer was the opaque `nagare-shomei`, and its OIDC endpoints were off. A command-line tool that signs a person in
through a browser, or a service account that gets its own token, needs a public `https` issuer and four Shomei
endpoints. Shomei serves its whole API on one port, including an always-open sign-up, the admin routes and metrics.
Its authorization endpoint identifies the user from a bearer access token, while the browser's session lives in the
enforcer's own cookies ([ADR 15](0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md)).

## Decision

1. The issuer is one context setting, `NAGARE_AUTH_ISSUER`, accepted only as `https://HOST` with `HOST` the
   registered auth portal's host. Shomei and `nagare-access` both take it from that one value; the login URL is
   `<issuer>/login`. Unset, the packaged manifests render unchanged with `nagare-shomei` and OIDC off.
2. `nagare-access` serves the endpoints on the issuer's host, before the portal, by forwarding exactly four
   method-and-path pairs to the private Shomei Service: discovery, the key set, `GET /oauth/authorize` and
   `POST /oauth/token`. Every other path on that host is the portal's; no Shomei route, DNS name, certificate or
   Service is made public.
3. At the authorization endpoint the enforcer resolves the browser's session cookie as for the portal and forwards
   its access token; a client's own `Authorization` header is never the session. It consults no site grant: an
   OAuth authorization is not a site grant ([ADR 29](0029-site-access-is-a-reviewed-relationship-per-hostname.md)).
   The token endpoint gets the client's form and HTTP Basic credentials and no cookie.
4. Shomei's answers pass through unchanged apart from hop-by-hop headers: no redirect is followed and no `Location`
   is rewritten. Behind an edge they get the enforcer's `Cache-Control` tightening like every proxied answer
   ([ADR 34](0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md)).
5. Every token keeps the single audience `nagare-access`; consumers check `iss`, `aud` and their own permission.

## Consequences

- The issuer follows the portal host. Changing it changes every token's `iss` and orphans every consumer binding on
  the exact issuer, so it is chosen before the first binding, and `nagarectl context move` refuses a context that
  sets it.
- Applying or removing the setting makes old access tokens unverifiable; browsers renew with their refresh tokens.
- Native access tokens also open protected sites as bearer tokens, under the same site grants, because the audience
  is shared.
- Every token request reaches Shomei from the enforcer's address, so Shomei's per-client rate limiter sees all of
  them as one client, and they share one bucket with every browser session renewal. Shomei can trust a forwarded
  address (`SHOMEI_TRUSTED_PROXIES`); the enforcer does not send one yet. Until it does, clients cache their tokens
  (operator, 2026-11-18). Sending the address is deferred as finding F157 in
  [the findings ledger](../audits/mp23-findings.md).
- `userinfo`, `introspect` and `revoke` are advertised by Shomei's discovery document but not served.
