---
id: 240
slug: prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports
title: "Prove a Cloudflare zone and tunnel can serve a context with no inbound ports"
kind: exec-plan
created_at: 2026-11-02T03:17:41Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-02T03:17:41Z
---

# Prove a Cloudflare zone and tunnel can serve a context with no inbound ports

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

Decide, with evidence from a real Cloudflare account, whether the recommended path works: a base domain
on a full Cloudflare zone, a proxied wildcard record to a tunnel, and a login-protected site behind it.
This is a prototype on a disposable context. No product code lands. The output is a set of pass/fail
answers and a design decision.


## Progress

Each item passes only with a recorded observation.

- [ ] P1: A proxied wildcard CNAME to `<id>.cfargotunnel.com`, with a catch-all ingress rule, serves a
  one-label name such as `hello.<base>` with its `Host` header intact.
- [ ] P2: The base domain's apex is served through the tunnel by a proxied CNAME, with a free certificate.
- [ ] P3: `cloudflared` reaches Kourier inside the cluster with `external-domain-tls` off, and sites
  still route. If this fails, record what origin TLS works instead.
- [ ] P4: Knative's domain template gives one-label default names (`<name>-<namespace>.<base>`), and they
  are served with the free certificate.
- [ ] P5: With a subdomain base, an Advanced Certificate Manager certificate with `*.<base>` serves tunnel
  hostnames, given that Total TLS excludes them. Record the observed price.
- [ ] P6: A protected site's `.pdf` and `.js`, fetched once while signed in, are never served to an
  anonymous request: `cf-cache-status` is not `HIT` and the request reaches the login redirect. Record what
  makes this true: a zone cache rule, or `Cache-Control: private` from the gateway.
- [ ] P7: A full browser login works through the tunnel with the origin as chosen in P3: sign in at the
  auth host, reach a granted site, get refused on an ungranted one, and survive a session renewal. Cookies
  stay `Secure`, and redirects stay `https`.
- [ ] P8: Measurements are recorded: time to first byte direct and through the tunnel, and the behaviour of
  a response stream longer than 125 seconds.
- [ ] Result: the Decision Log states pass or fail. On pass, a new ADR records the topology and ADR 20 is
  amended. On fail, the work stops and the operator gets the alternatives from RES-7.
- [ ] Every prototype resource is removed from Cloudflare and the disposable context.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md) compares
the options and lists Cloudflare's documented limits. A **full setup** means the domain's name servers point
at Cloudflare; it is the only setup on Free and Pro. A **proxied** record is served through Cloudflare's edge.
The **connector** is the `cloudflared` process.

What the documentation leaves open, and this plan tests:

- It says wildcard records are multi-level by default and that several records may point at one tunnel, but
  shows no wildcard pointing at a tunnel (P1).
- A wildcard certificate covers one level, so Nagare's default `<name>.<namespace>.<base>` is not covered.
  Flattening to one label avoids a paid add-on (P4).
- It does not say whether a request's Cookie affects default caching. By default Cloudflare caches by file
  extension, including `.js`, `.css` and `.pdf`, unless the response has `Set-Cookie` or `Cache-Control:
  private`, `no-store`, `no-cache` or `max-age=0` (P6).

Nagare facts:

- `cluster/bootstrap/knative-serving/config-network-tls.yaml` enables `external-domain-tls`, and
  `cluster/bootstrap/net-certmanager/README.md` describes the state with it off.
- `cluster/bootstrap/knative-serving/config-network.yaml` sets no `domain-template` today.
- `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` issues through Cloud DNS, which would no longer be
  authoritative for a domain on Cloudflare. Keeping a Cloudflare DNS-01 token in the cluster is the rejected
  default, because it gives the cluster power over the whole zone.
- Service `kourier` in namespace `kourier-system` is the gateway.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) records per-hostname access.


## Plan of Work

The operator supplies a Cloudflare account, a disposable registered domain on a full setup, and an API token,
and approves this as one bounded cloud sequence. The target is a disposable cloud context, never a context in
real use. Complete [Before a native run](../runbooks/before-a-native-run.md) first.

Create a remotely managed tunnel through the API, run the connector as a throwaway Deployment with one
catch-all rule to Kourier, create the records, then work through P1 to P8. Keep scratch files in the session
scratchpad. Nothing is committed except this plan and the ADR.


## Validation and Acceptance

The acceptance is the Progress list. A browser session is the evidence for P7. Quote command output in Progress
for the others.


## Idempotence and Recovery

Everything is disposable. The firewall stays open throughout, so a failed experiment affects nothing else.
Removal is by tunnel and record ID.


## Interfaces and Dependencies

Cloudflare API, with a token holding Cloudflare Tunnel Edit and Zone DNS Edit. Tunnel creation is
`POST /accounts/{id}/cfd_tunnel`, and configuration is `PUT /accounts/{id}/cfd_tunnel/{tunnel}/configurations`.
Outbound port 7844 (TCP and UDP) must be open from the VM. No prerequisites.
