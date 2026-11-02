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
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-02T20:19:20Z
      mode: "update"
      note: "Security review of MasterPlan 32: deliverables added for the connector bound, cache and edge policy, credential handling, hostnames and grants on a move"
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
- [ ] P3: `cloudflared` reaches the external Service `kourier` inside the cluster with `external-domain-tls`
  off, and sites still route. If this fails, record what origin TLS works instead. The hop from the
  connector to Kourier is plain HTTP inside the node, like Kourier to a pod today; record that it is
  accepted.
- [ ] P4: Knative's domain template gives one-label default names (`<name>-<namespace>.<base>`), and they
  are served with the free certificate.
- [ ] P5: With a subdomain base, an Advanced Certificate Manager certificate with `*.<base>` serves tunnel
  hostnames, given that Total TLS excludes them. Record the observed price.
- [ ] P6: A protected site's `.pdf` and `.js`, fetched once while signed in, are never served to an
  anonymous request: `cf-cache-status` is not `HIT` and the request reaches the login redirect. Prove the
  leak first with neither control, then that each control alone stops it, then both: a zone cache rule
  that bypasses the cache for every hostname, and `Cache-Control: private, no-store` added by the gateway
  to the proxied response. Both ship; record each observation.
- [ ] P7: A full browser login works through the tunnel with the origin as chosen in P3: sign in at the
  auth host, reach a granted site, get refused on an ungranted one, and survive a session renewal. Cookies
  stay `Secure`, and redirects stay `https`. With Always Use HTTPS on at the zone, an `http://` request is
  redirected at the edge, and a TLS 1.0 or 1.1 handshake is refused once the minimum is set to 1.2.
- [ ] P8: Measurements are recorded: time to first byte direct and through the tunnel, and the behaviour of
  a response stream longer than 125 seconds.
- [ ] P9: The connector is bounded in the cluster. With a NetworkPolicy allowing egress only to the external
  `kourier` Service, cluster DNS and port 7844, an ingress rule repointed from Cloudflare at
  `https://kubernetes.default.svc`, `kourier-internal` and `http://169.254.169.254` fails to connect; the
  rule is then restored. Ingress rules that name `<base>` and `*.<base>` with a 404 catch-all return 404
  for any other hostname.
- [ ] P10: Rotating the tunnel secret through the API makes Cloudflare refuse the old token, and a connector
  restarted with the new token reconnects. Cloudflare's connector listing shows each connector's origin
  address, so a connector the context did not start is visible.
- [ ] Result: the Decision Log states pass or fail. On pass, a new ADR records the topology and its threat
  model (both Cloudflare credentials as interception credentials, the in-cluster bound on the connector,
  the two cache controls and the edge policy), and ADR 20 is amended. On fail, the work stops and the
  operator gets the alternatives from RES-7.
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
- Service `kourier` in namespace `kourier-system` is the external gateway; `kourier-internal` serves
  cluster-local routes and must never be the connector's origin. Kourier's `config-kourier` keeps
  `trusted-hops-count: "0"` and `use-remote-address: "false"`.
- Knative's default `http-protocol: Enabled` serves plain HTTP
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs`), and nothing in the repository
  sends HSTS. The gateway hard-codes `Secure` cookies and `https://` portal URLs
  (`cli/nagare-access/src/Nagare/Access/Cookie.hs`, `Portal.hs`) and sets `Cache-Control: no-store` only on
  its own responses, not on the responses it proxies.
- Cloudflare's zone defaults are minimum TLS 1.0 and no HTTP to HTTPS redirect.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) records per-hostname access.


## Plan of Work

The operator supplies a Cloudflare account, a disposable registered domain on a full setup, and an API token,
and approves this as one bounded cloud sequence. The target is a disposable cloud context, never a context in
real use. Complete [Before a native run](../runbooks/before-a-native-run.md) first.

Create a remotely managed tunnel through the API, run the connector as a throwaway Deployment with one
catch-all rule to Kourier, create the records, then work through P1 to P10. Keep scratch files in the session
scratchpad. Nothing is committed except this plan and the ADR.

Prototype inputs, 2026-11-02: the disposable zone is `topagentnetworklabs.com`, registered through Cloudflare
Registrar, so it is on a full setup from the start. Account `d605625d4375aa3120a1374daf2f9a87`, zone
`a0bc2ff68ebe0ae99b7f9864a2219722`. The API token and the Tailscale test key are operator material, held as
files outside this repository and never recorded here.

Cloudflare side done on 2026-11-02 with the `cf` CLI (`nix run github:NixOS/nixpkgs/nixpkgs-unstable#cf`, 1.0.0-beta.21),
each step dry-run first: remotely managed tunnel `nagare-ep240` (`b855f1f5-a95c-4af1-af30-f707e1d3d6cd`) with ingress
rules for the apex and `*.<base>` to `http://kourier.kourier-system.svc.cluster.local:80` and a 404 catch-all; proxied
CNAMEs for `*` and the apex to the tunnel; zone settings Always Use HTTPS on, minimum TLS 1.2, SSL strict, email
obfuscation and Rocket Loader off (the zone's defaults were off, 1.0, full and on). Tunnel creation needed no Zero
Trust onboarding step. The cache bypass rule is deliberately not created yet, so P6 can first observe the leak. The
cluster side waits for the disposable context.


## Validation and Acceptance

The acceptance is the Progress list. A browser session is the evidence for P7. Quote command output in Progress
for the others.


## Idempotence and Recovery

Everything is disposable. The firewall stays open throughout, so a failed experiment affects nothing else.
Removal is by tunnel and record ID.


## Interfaces and Dependencies

Cloudflare API, with a token scoped to the one account and the one zone holding exactly Account: Cloudflare
Tunnel Edit, Zone: DNS Edit, Zone: Zone Settings Edit and Zone: Cache Rules Edit. Cloudflare Tunnel Edit reads
every tunnel's token in the account, so the account should hold nothing but this installation. The token rests
sops-encrypted with the operator's other material and is exported for a command, never written to a context
file. Tunnel creation is `POST /accounts/{id}/cfd_tunnel`, configuration is
`PUT /accounts/{id}/cfd_tunnel/{tunnel}/configurations`, and rotation is `PATCH /accounts/{id}/cfd_tunnel/{tunnel}`
with a new `tunnel_secret`. Outbound port 7844 (TCP and UDP) must be open from the VM. No prerequisites.
