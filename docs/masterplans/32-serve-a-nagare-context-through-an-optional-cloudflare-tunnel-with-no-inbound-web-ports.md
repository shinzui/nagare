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
| 240 | Prove a Cloudflare zone and tunnel can serve a context with no inbound ports | docs/plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md | None | None | Not Started |
| 241 | Run a reviewed Cloudflare Tunnel connector beside direct ingress | docs/plans/241-run-a-reviewed-cloudflare-tunnel-connector-beside-direct-ingress.md | EP-240 | None | Not Started |
| 242 | Route a context's hostnames through its Cloudflare zone and check them | docs/plans/242-route-a-context-s-hostnames-through-its-cloudflare-zone-and-check-them.md | EP-240 | EP-241 | Not Started |
| 243 | Close a context's inbound ports and move existing contexts onto the tunnel | docs/plans/243-close-a-context-s-inbound-ports-and-move-existing-contexts-onto-the-tunnel.md | EP-241, EP-242 | None | Not Started |
| 244 | Make the tunnel the recommended path for new Nagare installations | docs/plans/244-make-the-tunnel-the-recommended-path-for-new-nagare-installations.md | EP-243 | None | Not Started |

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
- **Perimeter.** `infra/pulumi/src/components/NagareNetwork.ts`, `NagarePerimeter.ts`, `domainTopology.ts`
  and `resource-catalog.json`. Only EP-243 changes them.
- **Representative check.** EP-240 is the producer/consumer check: a real browser login through a real
  tunnel to a protected site on a disposable context.
- **ADRs.** EP-240 writes the new ADR for the topology when accepted and amends ADR 20. EP-242 amends
  ADR 29 if its caching rule changes that decision.


## Progress

No child plan has started. EP-240 needs from the operator a Cloudflare account, a disposable registered
domain on it, and go-ahead for its bounded cloud sequence on a disposable context.

- [ ] Gate: a new installation followed from the onboarding page alone ends with sites serving, login
  working, and an outside port check finding nothing open (EP-244).


## Surprises & Discoveries

(None yet.)


## Decision Log

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


## Outcomes & Retrospective

(To be filled at completion.)
