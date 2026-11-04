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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:04:32Z
      mode: "update"
      note: "Outcomes & Retrospective written; the header and edge-policy follow-ups point at EP-245"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:04:32Z
      verdict: "comments"
      note: "D6 replaces the upstream Cache-Control and defeats the admin API's ETag revalidation and browser caching in tunnel mode; D11 declares nothing about Browser Integrity Check or HSTS; Outcomes was empty for a Complete plan"
---

# Route a context's hostnames through its Cloudflare zone and check them

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

In tunnel mode, deploying a site makes its hostname work through Cloudflare with no extra operator step, and each
default name is covered by the free certificate. `nagarectl domains check` tells the truth about the Cloudflare path,
and login protection is never weakened by edge caching.


## Progress

- [x] D1 (`InventoryCloudflareZoneSpec`, read-only requests against the real API): The base domain's proxied apex and wildcard records are typed inventory resources in the Cloudflare zone.
  Planning refuses a base domain outside `CF_ZONE_ID`'s zone. Fake-adapter tests cover a lost acknowledgement, a
  conflicting existing record, and resume after partial application.
- [x] D2 (`Nagare.Test.SiteInventory.Tunnel`; `-p flatten`): In tunnel mode, default names are one label below the base (`<name>-<namespace>.<base>`), for every web kind
  and every preview. Knative's domain template, `serviceUrl` and its static and server equivalents, protected-route
  hostnames and `domains list` agree. Two workloads that flatten to one name are refused, using ADR 20's ownership
  check, across namespaces and including protected-route DomainMappings in `nagare-system` and preview names, so a
  workload in namespace `b-c` cannot claim the default name of `a-b` in namespace `c`. The platform's own hostnames
  (auth portal, admin API, `nagared` hooks, apex) are reserved from flattened names.
- [x] D3 (`Nagare.Test.SiteInventory.Tunnel`; the subdomain base is replaced, see the Decision Log): A custom domain deeper than the certificate covers is refused at planning, with a message naming Advanced
  Certificate Manager at $10 a month. A subdomain base where that certificate exists passes.
- [x] D4 (`Nagare.Test.SiteInventory.Tunnel`: a site's scope holds only Kubernetes members): A redeploy makes no per-hostname Cloudflare call. A call-count test proves it.
- [x] D5 (`Nagare.Test.SiteInventory.Tunnel`; EP-240 ran with `external-domain-tls` off, so a supplied Secret is refused): In tunnel mode, planning refuses a per-site Cloudflare or Google CDN, a supplied origin TLS secret if EP-240
  shows it cannot work, and a custom domain outside the zone, each with a clear message. Direct mode makes no Cloudflare
  call and behaves as before.
- [x] D6 (`EdgeCacheControlSpec`; native on `ep243`: after signed-in browser fetches answered 200 with `private, no-store, no-transform`, the same URLs answered an anonymous client 302 with `cf-cache-status: DYNAMIC`, never `HIT`): An anonymous request never receives cached bytes of a protected site, by two independent controls: in
  tunnel mode the platform's zone ruleset bypasses the cache for every hostname, and the enforcer adds
  `Cache-Control: private, no-store, no-transform` to every proxied protected response (today it sets `no-store` only on its own
  responses). `nagare-access-test` asserts the header on a proxied response, and an automated test on the disposable
  context fetches an asset with a session and then without one.
- [x] D7 (`Nagare.Test.Domains`; certificate state is the one a visitor gets from a verified handshake, and the wildcard is probed through an unused label): `nagarectl domains list` and `domains check` expect the tunnel's records and report certificate state from
  Cloudflare. A missing record or certificate fails the check.
- [x] D8 (`tunnelUpstreamInputs` drops the issuer scope; `Nagare.Test.Domains` shows no certificate read): In tunnel mode, public origin certificates are not requested and the DNS-01 issuer is not installed, or the
  alternative EP-240 proved is in place. `domains tls` reports this accurately.
- [x] D9 (native on `ep243`: a real Chrome sign-in on a deployed protected site through the edge reached it, on the custom name `staging.<base>`, after the flat default name was checked anonymously and retired; retiring and collecting that site left no route, and its name answers 404): On a disposable context, deploying a new protected site works from a browser through the edge, and retiring
  it leaves no route.
- [x] D10 ([cloudflare-tunnel.md](../user/cloudflare-tunnel.md), ADR 29 amendment): `docs/user` covers hostnames and certificates in tunnel mode. ADR 29 is amended: a protected site behind
  Cloudflare is not a CDN, and the two cache controls of D6 are its rule.
- [x] D11 (`InventoryCloudflareZoneSpec`; both settings EP-240 left on are off, and Cloudflare retired minification): Tunnel mode declares the zone's edge policy through the platform scope's zone claims: Always Use HTTPS on,
  minimum TLS version 1.2, SSL mode strict, and Rocket Loader, email obfuscation and minification off, because they
  rewrite hosted pages. Fake-adapter tests cover drift back to a default, and direct mode declares none of them.
  This plan also decides `automatic_https_rewrites` and `server_side_exclude`, which EP-240 found on, and the disposable
  context's test asserts that a browser-like request gets no analytics beacon, which zone setting `rum` did not stop.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The base domain is the Cloudflare zone itself, so D3's subdomain base with its own certificate is out of scope, and a name deeper than one label is refused.
  Rationale: ADR 34 fixes the topology on a full zone, and nothing in this plan manages an Advanced Certificate Manager certificate.
  Date: 2026-11-03

- Decision: Two workloads on one name are refused by a `Hostname` claim on the public Knative Service, not by a new check. A protected workload's route already holds that claim. Platform services hold none, so
  the suffix `-nagare-system` is reserved outside that namespace.
  Rationale: ADR 20's claim machinery already covers accepted history and retained incarnations.
  Date: 2026-11-03


## Outcomes & Retrospective

Flattened one-label names, the zone's records, edge policy and cache bypass, the enforcer's header on proxied protected
responses, and `domains check` for the tunnel path ship in v0.16.0; a real browser signed in through the edge and an
anonymous request never saw a cached protected byte. Two things move on: the review of 2026-11-04 found that D6's header
replaces the upstream's `Cache-Control`, which breaks the admin API's `ETag` revalidation and browser caching of protected
assets in tunnel mode, and that the edge policy says nothing about Browser Integrity Check or HSTS; both go to
`docs/plans/245-make-the-tunnel-s-edge-safe-and-fast-for-api-clients-and-protected-assets.md`. The Advanced Certificate
Manager path (D3's subdomain base) was dropped by decision and stays unbuilt.


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
