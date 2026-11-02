---
id: 242
slug: route-a-context-s-hostnames-through-its-cloudflare-zone-and-check-them
title: "Route a context's hostnames through its Cloudflare zone and check them"
kind: exec-plan
created_at: 2026-11-02T03:17:41Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-02T03:17:41Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-02T20:19:20Z
      mode: "update"
      note: "Security review of MasterPlan 32: deliverables added for the connector bound, cache and edge policy, credential handling, hostnames and grants on a move"
---

# Route a context's hostnames through its Cloudflare zone and check them

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

In tunnel mode, deploying a site makes its hostname work through Cloudflare with no extra operator step, and each
default name is covered by the free certificate. `nagarectl domains check` tells the truth about the Cloudflare path,
and login protection is never weakened by edge caching.


## Progress

- [ ] D1: The base domain's proxied apex and wildcard records are typed inventory resources in the Cloudflare zone.
  Planning refuses a base domain outside `CF_ZONE_ID`'s zone. Fake-adapter tests cover a lost acknowledgement, a
  conflicting existing record, and resume after partial application.
- [ ] D2: In tunnel mode, default names are one label below the base (`<name>-<namespace>.<base>`), for every web kind
  and every preview. Knative's domain template, `serviceUrl` and its static and server equivalents, protected-route
  hostnames and `domains list` agree. Two workloads that flatten to one name are refused, using ADR 20's ownership
  check, across namespaces and including protected-route DomainMappings in `nagare-system` and preview names, so a
  workload in namespace `b-c` cannot claim the default name of `a-b` in namespace `c`. The platform's own hostnames
  (auth portal, admin API, `nagared` hooks, apex) are reserved from flattened names.
- [ ] D3: A custom domain deeper than the certificate covers is refused at planning, with a message naming Advanced
  Certificate Manager at $10 a month. A subdomain base where that certificate exists passes.
- [ ] D4: A redeploy makes no per-hostname Cloudflare call. A call-count test proves it.
- [ ] D5: In tunnel mode, planning refuses a per-site Cloudflare or Google CDN, a supplied origin TLS secret if EP-240
  shows it cannot work, and a custom domain outside the zone, each with a clear message. Direct mode makes no Cloudflare
  call and behaves as before.
- [ ] D6: An anonymous request never receives cached bytes of a protected site, by two independent controls: in
  tunnel mode the platform's zone ruleset bypasses the cache for every hostname, and the enforcer adds
  `Cache-Control: private, no-store, no-transform` to every proxied protected response (today it sets `no-store` only on its own
  responses). `nagare-access-test` asserts the header on a proxied response, and an automated test on the disposable
  context fetches an asset with a session and then without one.
- [ ] D7: `nagarectl domains list` and `domains check` expect the tunnel's records and report certificate state from
  Cloudflare. A missing record or certificate fails the check.
- [ ] D8: In tunnel mode, public origin certificates are not requested and the DNS-01 issuer is not installed, or the
  alternative EP-240 proved is in place. `domains tls` reports this accurately.
- [ ] D9: On a disposable context, deploying a new protected site works from a browser through the edge, and retiring
  it leaves no route.
- [ ] D10: `docs/user` covers hostnames and certificates in tunnel mode. ADR 29 is amended: a protected site behind
  Cloudflare is not a CDN, and the two cache controls of D6 are its rule.
- [ ] D11: Tunnel mode declares the zone's edge policy through the platform scope's zone claims: Always Use HTTPS on,
  minimum TLS version 1.2, SSL mode strict, and Rocket Loader, email obfuscation and minification off, because they
  rewrite hosted pages. Fake-adapter tests cover drift back to a default, and direct mode declares none of them.
  This plan also decides `automatic_https_rewrites` and `server_side_exclude`, which EP-240 found on, and the disposable
  context's test asserts that a browser-like request gets no analytics beacon, which zone setting `rum` did not stop.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

The route is one wildcard record pointing at the tunnel, so most hostnames need no Cloudflare resource of their own.
Read the accepted result of `docs/plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md`
and its ADR first: they fix the origin path, the certificate and the caching mechanism.

A wildcard certificate covers one level, so `*.<base>` does not cover today's default `<name>.<namespace>.<base>`.
Previews are Knative Services named `<site>-pr-<name>` in the same shape, as `docs/user/static-hosting.md` describes.

Key files:

- `cli/nagarectl/src/Nagare/Deploy.hs` has `serviceUrl`, with equivalents in `cli/nagarectl/src/Nagare/Server/Deploy.hs`
  and `cli/nagarectl/src/Nagare/Static/Deploy.hs`.
- `cli/nagarectl/src/Nagare/Inventory/ProtectedRoute.hs` composes protected routes for every web kind.
- `cli/nagarectl/src/Nagare/Inventory/Adapters/Cloudflare.hs` has `CloudflareDnsTarget`, which today holds an exact
  proxied A record and must also hold a proxied CNAME.
- `cli/nagarectl/src/Nagare/Ops/Domains.hs` has `dnsExpectationFor`, which expects A records.
- `cli/nagarectl/app/Nagare/Cli/Commands/Domains.hs` runs `domains list` and `domains check`.
- `cli/nagarectl/app/Nagare/Cli/Application/Cdn.hs` uses the `publicIp` output as a Cloudflare CDN origin, which is
  refused in tunnel mode.
- `cluster/bootstrap/knative-serving/config-network.yaml` is where the domain template is set. It sets no
  `http-protocol`, so Knative's default `Enabled` serves plain HTTP; the gateway hard-codes `Secure` cookies and
  `https://` portal URLs (`cli/nagare-access/src/Nagare/Access/Cookie.hs`, `Portal.hs`), nothing sends HSTS, and
  Cloudflare's zone defaults are TLS 1.0 and no redirect. D11 closes that at the edge.
- `cli/nagare-access/src/Nagare/Access/Response.hs` sets `Cache-Control: no-store` on the gateway's own responses
  only; D6 extends it to proxied protected responses.

Relevant decisions:

- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) makes domain ownership explicit.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) refuses a CDN on a protected site because
  a cache must not answer for an access check. The same reasoning applies to Cloudflare's default cache, which stores
  assets by file extension unless told otherwise.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) puts fakes first.


## Plan of Work

Decide the flattened name shape first, because everything else reads it. Add the records with fake-adapter tests, wire the
refusals and the caching guarantee, and teach `domains` the new expectation. Confirm natively last.


## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. Planner and adapter behaviour is proven in
`cabal test nagarectl-test`. Gateway changes, if EP-240 selects them, are proven in `cabal test nagare-access-test`. A
native run on a disposable context confirms D9, after [Before a native run](../runbooks/before-a-native-run.md) and with
the operator's go-ahead.


## Idempotence and Recovery

A failed apply resumes through the inventory journal. An uncertain Cloudflare response stays unresolved until observed, as
the existing transport does. Direct mode is untouched: the flattened names and new records exist only in tunnel mode.


## Interfaces and Dependencies

Requires EP-240 complete. Reads `NAGARE_INGRESS` from EP-241's `Target` field; if EP-241 has not landed, add the field as
EP-241 defines it and reconcile on merge. EP-243 consumes `nagarectl domains check`.
