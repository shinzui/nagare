---
id: 32
slug: serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports
title: "Serve a Nagare context through an optional Cloudflare Tunnel with no inbound web ports"
kind: master-plan
created_at: 2026-11-02T02:49:49Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-02T02:49:49Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-02T03:00:33Z
      mode: "update"
      note: "Record the operator's low-budget constraint; rule out Business and Enterprise; make a full zone on a new domain the preferred fallback"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-02T20:19:20Z
      mode: "update"
      note: "Security review: bound the connector in-cluster, two cache controls and edge policy, both Cloudflare credentials as interception credentials, hostnames and grants carried on a move, DNSSEC in the DNS step"
---

# Serve a Nagare context through an optional Cloudflare Tunnel with no inbound web ports

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current. If durable project context changes, update or create ADRs in
docs/adr/ in the same change.


## Vision & Scope

Anyone installing Nagare is guided to put their domain on Cloudflare and serve every site through a
Cloudflare Tunnel. Visitors use an ordinary browser, with no VPN or client software, and the VM
accepts no inbound connection from the internet. SSH stays limited to Google's IAP range and the
Kubernetes API stays on the tailnet.

A tunnel is an outbound connection from a small program, `cloudflared` (the connector), to
Cloudflare's edge. The edge receives each browser request and sends it down that connection.

```text
browser
  -> Cloudflare edge (the base domain's zone, proxied wildcard record)
  -> tunnel
  -> cloudflared pod in the cluster
  -> Kourier -> Knative route -> site
```

The feature is optional. Direct ingress stays supported, and a context that does not opt in is
unchanged. New installations are nudged towards the tunnel: onboarding leads with it and `nagarectl`
points to it.

**This plan is about Nagare in general, for any operator.** An operator's own installation is not
part of its acceptance. Acceptance runs on a disposable context. Each installation decides for
itself; the intranet's decision, which has extra constraints, is
`mori://tan/tan-ng-labs/plans/13-decide-how-the-intranet-closes-its-inbound-web-ports`.

In scope: the connector, a route for every hostname, health and DNS checks that understand tunnel
mode, a Pulumi perimeter with no internet-facing rule, a reversible move for existing direct
contexts, and the onboarding path and nudge.

Out of scope:

- A per-site CDN in tunnel mode (refused at planning).
- More than one tunnel per context, private-network routes, Cloudflare Access as a login layer.
- Local-mode tunnels.
- Removing the VM's public IP, which stays for outbound traffic with no port open.
- Domains that cannot move to Cloudflare. Cloudflare for SaaS and a Google load balancer are recorded
  in RES-7 but not built here.

### What an operator accepts by choosing this

- **Cloudflare decrypts traffic at its edge,** including session cookies and page content.
- **Free and Pro limits apply:** 100 MB maximum upload, and a 125-second proxy read timeout.
- **The domain's DNS moves to Cloudflare.**
- **The Cloudflare account and the registrar become the roots of trust for every site.** Whoever
  controls either controls DNS, edge TLS and where the tunnel points. Two-factor authentication on
  both is part of the recommended path, and the API token is scoped to the one account and zone.
- **The tunnel token is an interception credential.** A connector started anywhere with it receives a
  share of every request, session cookies included. Nagare keeps it in one namespace, rotates it, and
  reports any connector it did not start.
- **No edge request logs on Free or Pro.** Incident response uses the gateway's own logs.

Cost is $0 if the base domain is the Cloudflare zone itself, because the free certificate covers the
apex and one label below it. A base domain that is a subdomain of the zone needs Advanced Certificate
Manager at $10 a month. Internet egress from GCP is charged as it is today.


## Decomposition Strategy

The work splits by what can be proven independently. EP-240 lands no product code, because its
answers fix the design. The connector and hostname routing are separate because one is a single
platform component and the other touches every web workload kind. Closing the firewall is separate
because it is the only step that can take a live site down. The nudge is last because Nagare must not
recommend a path before it has been proven.

Alternatives are compared in
[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md).

Relevant ADRs:

- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) says Pulumi owns the wildcard
  record, the wildcard targets the VM, and Nagare adds no credentials for external DNS providers.
  Tunnel mode needs an amendment, because DNS moves to Cloudflare.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): every
  resource is declared before mutation and has one lifecycle owner.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects are
  found by fake adapters, and native runs only confirm.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md): protected sites refuse
  a CDN. Cloudflare's default edge cache must not weaken this.
- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  the tunnel token is operator material and stays out of this repository.
- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): cloud writes
  stay pinned to the active project.
- [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md):
  a rebuilt node must rejoin the same tunnel.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 240 | Prove a Cloudflare zone and tunnel can serve a context with no inbound ports | docs/plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md | None | None | Complete |
| 241 | Run a reviewed Cloudflare Tunnel connector beside direct ingress | docs/plans/241-run-a-reviewed-cloudflare-tunnel-connector-beside-direct-ingress.md | EP-240 | None | In Progress |
| 242 | Route a context's hostnames through its Cloudflare zone and check them | docs/plans/242-route-a-context-s-hostnames-through-its-cloudflare-zone-and-check-them.md | EP-240 | EP-241 | Complete |
| 243 | Close a context's inbound ports and move existing contexts onto the tunnel | docs/plans/243-close-a-context-s-inbound-ports-and-move-existing-contexts-onto-the-tunnel.md | EP-241, EP-242 | None | In Progress |
| 244 | Make the tunnel the recommended path for new Nagare installations | docs/plans/244-make-the-tunnel-the-recommended-path-for-new-nagare-installations.md | EP-243 | None | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-240 blocks everything, because a failed topology changes the design. EP-241 and EP-242 can then
run in parallel. EP-243 needs both, because closing the firewall is safe only when the connector runs
and every hostname has a route. EP-244 comes last, so that the recommendation rests on a proven path.


## Integration Points

- **Ingress mode.** `NAGARE_INGRESS`, either `direct` (the default) or `cloudflare-tunnel`, read in
  `cli/nagarectl/src/Nagare/Target.hs` and projected into Pulumi config. EP-241 defines it. Later plans
  read it and add no switch of their own.
- **Cloudflare adapter.** `CloudflareTarget` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/Cloudflare.hs` and its transport in
  `CloudflareRuntime.hs`. EP-241 adds the tunnel and its configuration. EP-242 extends the DNS target
  beyond proxied A records. Both reuse `CF_ACCOUNT_ID`, `CF_ZONE_ID` and `CF_API_TOKEN`, which stay on
  the operator's machine. Only the tunnel token enters the cluster.
- **Default hostname shape.** EP-242 owns it. Tunnel-mode names must be one label below the base so the
  free certificate covers them. `serviceUrl` in `cli/nagarectl/src/Nagare/Deploy.hs` and the static and
  server equivalents must agree with Knative's domain template.
- **DNS expectation.** `dnsExpectationFor` in `cli/nagarectl/src/Nagare/Ops/Domains.hs`. EP-242 changes
  it, and EP-243's move uses `nagarectl domains check` as its gate.
- **Perimeter.** `infra/pulumi/src/components/NagareNetwork.ts`, `NagarePerimeter.ts`,
  `infra/pulumi/src/domainTopology.ts` and `infra/pulumi/resource-catalog.json`. Only EP-243 changes them.
  In tunnel mode it also makes the `kourier` Service `ClusterIP`, so k3s binds no host port.
- **Connector boundary.** EP-241 owns the connector's namespace, its NetworkPolicy (egress only to the
  external `kourier` Service, cluster DNS and port 7844 TCP and UDP; no ingress), its pod hardening and
  the tunnel's ingress rules (`<base>`, `*.<base>`, then a 404 catch-all). The tunnel's ingress
  configuration is managed from Cloudflare, so this policy is the only control over what a change made
  there can reach. EP-242 and EP-243 must not widen it.
- **Edge policy and cache.** EP-242 owns them through the platform scope's zone claims from ADR 20's
  2026-09-25 amendment: Always Use HTTPS, minimum TLS 1.2, SSL mode strict, response-rewriting features
  off, and one cache rule that bypasses the cache for every hostname. The enforcer's
  `Cache-Control: private, no-store` on every proxied protected response is the second control, owned by
  EP-242 in `cli/nagare-access`.
- **Hostnames on a move.** Flattening changes every default hostname of an existing context, and ADR 29
  grants are per hostname. EP-242 defines the shape; EP-243's move re-declares protected routes and their
  grants for the new names, or keeps the old names with Advanced Certificate Manager when the operator
  chooses that.
- **Visitor address.** Shomei and the gateway key on the socket peer, which behind Kourier is already a
  proxy address, and Kourier keeps `trusted-hops-count: "0"`. No plan raises it, because a direct client
  could then forge `X-Forwarded-For` while both paths are open during a move. Anything new that records a
  visitor address in tunnel mode reads `CF-Connecting-IP`, and only once the perimeter is closed (EP-241).
- **Representative check.** EP-240 is the producer/consumer check: a real browser login through a real
  tunnel to a protected site on a disposable context.
- **ADRs.** EP-240 writes the new ADR for the topology when accepted and amends ADR 20. The new ADR
  carries the threat model: the tunnel token and the API token as interception credentials, the
  in-cluster bound on the connector's reach, the two cache controls and the edge policy. EP-242 amends
  ADR 29: a protected site behind Cloudflare is not a CDN, and the two cache controls are its rule.


## Progress

EP-240 is complete and passed on 2026-11-02; its topology and threat model are in
[ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md). EP-242 is complete. A new context bootstraps
through the reviewed path and serves a protected site with no web port, proved natively on `ep243` on 2026-11-03. v0.16.0 carries this.
Left: EP-244 D6, and EP-243's move of an existing context. EP-241 D7's rebuild drill passed and found F142 and F143, fixed on master after v0.16.0.

- [ ] Gate: a new installation followed from the onboarding page alone ends with sites serving, login
  working, an outside port check finding nothing open, and the host listening on no web port (EP-244).


## Surprises & Discoveries

- 2026-11-02, security review before any child started. The tunnel's ingress configuration is remotely
  managed, so the connector pod is a reverse proxy into the cluster whose targets are set from Cloudflare;
  the plan had no in-cluster bound on its reach. Flattening default names re-keys every ADR 29 grant on a
  converted context, which EP-243's move did not carry. Verified against the tree: Kourier's
  `trusted-hops-count: "0"` and `use-remote-address: "false"` (`cluster/bootstrap/vendor/kourier-v1.22.0.yaml`);
  Knative's default `http-protocol: Enabled` serves plain HTTP
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs`); the gateway hard-codes `Secure`
  cookies and `https://` portal URLs but sets `Cache-Control: no-store` only on its own responses, not on
  proxied ones (`cli/nagare-access/src/Nagare/Access/Cookie.hs`, `Portal.hs`, `Response.hs`); nothing in the
  repository sends HSTS; Shomei keys login attempts and throttling on the socket peer; `nagared` checks an
  HMAC signature and no source address. These changed EP-240 to EP-244 and the Decision Log below.


## Decision Log

- Decision: The rebuild fixes (F142) and the backup image pin (F143) land now and ship in the next release, ahead of EP-244 D6.
  Rationale: the drill showed a cloud context had no reviewed rebuild and that a node pulling the current image takes no backup. Both reach the intranet, and the operator's requirement is upgrades without data loss.
  Date: 2026-11-03

- Decision: v0.16.0 ships the tunnel for new contexts, and moving the intranet follows as its own work.
  Rationale: operator, 2026-11-03: "cut the release first, move the intranet later". EP-243's move is not needed to use the tunnel on a new context.
  The rotation pairing in the entry below is now tested, EP-241 D9.
  Date: 2026-11-03

- Decision: The enforcer's header on proxied protected responses is `Cache-Control: private, no-store, no-transform`, and rotating the tunnel secret also removes existing connections.
  Rationale: EP-240 observed Cloudflare injecting its analytics beacon into the login form and protected pages with zone setting `rum` off, stopped only by `no-transform`, and a running connector
  keeping its connections after rotation. EP-242 and EP-241 own these. The rotation pairing is not yet tested.
  Date: 2026-11-02

- Decision: The recommended general path is a base domain on a full Cloudflare zone, served through a
  tunnel, and Nagare nudges new installations towards it. Direct ingress stays supported and unchanged.
  Rationale: operator, 2026-11-02: Nagare is open source, and this "should be the recommendation for
  anyone who want to use nagare and the plan should support that and nudge towards that". It leaves no
  inbound rule and needs no per-hostname Cloudflare resources.
  Date: 2026-11-02

- Decision: Separate the intranet from this plan. Its constraints (a delegated subdomain, an apex portal,
  company mail records on the parent domain) belong in `mori://tan/tan-ng-labs`, and its adoption is not
  part of this plan's acceptance. It must still upgrade unchanged on direct ingress.
  Rationale: operator, 2026-11-02, asked to differentiate the two.
  Date: 2026-11-02

- Decision: Do not build Cloudflare for SaaS. A first draft of this plan used it for per-hostname custom
  hostnames. It is recorded in RES-7 as the route for a domain that cannot move.
  Rationale: it adds per-hostname resources and cannot serve an apex, for a case the general path does not have.
  Date: 2026-11-02

- Decision: The feature must stay cheap. Cloudflare Business and Enterprise are out of scope.
  Rationale: operator, 2026-11-02: "it does not have to be free ... just not expensive like GCP".
  Date: 2026-11-02

- Decision: Tunnel mode closes every internet-facing rule, including UDP 41641 for Tailscale.
  Rationale: the aim is no exposed ports. Tailscale falls back to its relays, and EP-243 measures the effect.
  Date: 2026-11-02

- Decision: If EP-240 fails, stop and bring the operator the alternatives instead of building one.
  Rationale: each alternative changes the cost or the recommendation, which is the operator's call.
  Date: 2026-11-02

- Decision: The connector's reach is bounded inside the cluster, not at Cloudflare. Its namespace carries
  a NetworkPolicy allowing egress only to the external `kourier` Service, cluster DNS and port 7844, no
  ingress, no service-account token, no host network, a restricted pod profile, and ingress rules that
  name `<base>` and `*.<base>` and end in a 404 catch-all. A repointed tunnel must fail to connect.
  Rationale: the ingress configuration is remotely managed, so the API token or the Cloudflare account
  could otherwise turn the tunnel into a path to the API server, En, the object store or the node
  metadata credential. The same isolation pattern already guards the admin API (ADR 29 amendment).
  Date: 2026-11-02

- Decision: Protected content is kept out of the edge cache by two independent controls: a zone cache
  rule that bypasses the cache for every hostname in tunnel mode, and `Cache-Control: private, no-store`
  from the enforcer on every proxied protected response. EP-240 proves the leak with neither control
  before proving each alone and both together. Tunnel mode also sets the zone's edge policy: Always Use
  HTTPS, minimum TLS 1.2, SSL mode strict, and response-rewriting features off.
  Rationale: Cloudflare caches `.js`, `.css` and `.pdf` by extension regardless of request cookies, so one
  control between an anonymous visitor and a protected file is too thin. Cloudflare's zone defaults are
  TLS 1.0 and no redirect, Knative serves plain HTTP, and nothing in Nagare sends HSTS, so without these
  settings the tunnel would serve sites over `http://`. Public sites lose edge caching, which they do not
  have today either, and per-site CDN is already refused in tunnel mode.
  Date: 2026-11-02

- Decision: Both Cloudflare credentials are treated as interception credentials. The tunnel token rests
  sops-encrypted in `cluster-secrets/<context>/` and in one Kubernetes Secret in the connector's
  namespace, is never a context variable, and is rotated through the API with the Deployment rolled; the
  status probe reports any connector Cloudflare lists that the context did not start. The API token is
  scoped to the one account and zone with exactly Cloudflare Tunnel Edit, DNS Edit, Zone Settings Edit
  and Cache Rules Edit, and the recommended path uses a Cloudflare account that holds nothing else.
  Rationale: a connector started anywhere with the tunnel token receives a share of every request;
  Cloudflare Tunnel Edit reads every tunnel's token in the account.
  Date: 2026-11-02

- Decision: A move carries hostnames. By default it re-declares every default route, its protected
  route and its ADR 29 grants for the flattened `<name>-<namespace>.<base>` name in the same reviewed
  move and lists the changed URLs first; alternatively the operator keeps two-label names by choosing
  Advanced Certificate Manager at the start. The DNS step refuses while the parent zone publishes a DS
  record and turns DNSSEC on at Cloudflare after activation.
  Rationale: ADR 29 grants are per hostname, so a renamed site with its old grants is unreachable to the
  people it was shared with, and a DS record left at the registrar blackholes the zone after the name
  server change.
  Date: 2026-11-02

- Decision: The intranet will adopt the apex-shaped zone `topagentnetworklabs.com` as a new base domain, planned in
  `mori://tan/tan-ng-labs/plans/14-re-home-the-intranet-onto-topagentnetworklabs-com-through-a-cloudflare-tunnel`
  and not here, because it is installation-specific. That plan needs a Nagare capability this MasterPlan does not yet
  hold: re-homing a context onto a new base domain, which carries every route and ADR 29 grant and rolls Shomei's
  issuer and relying-party ID. It is added as a child plan once EP-243 is complete, since it reuses EP-243's
  grant-carrying move, and is held until then. EP-240's P5 has no customer and is recorded as not observed unless the
  operator asks for it.
  Rationale: operator, 2026-11-02. The zone also serves EP-240's prototype first; the intranet adopts it only after
  the prototype's tunnel and records are removed, because one wildcard record points at one tunnel.
  Date: 2026-11-02


## Outcomes & Retrospective

(To be filled at completion.)
