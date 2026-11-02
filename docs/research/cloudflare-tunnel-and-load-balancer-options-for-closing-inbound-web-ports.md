---
type: Research Document
title: Options for closing Nagare's inbound web ports with Cloudflare Tunnel or a Google load balancer
description: Compare Cloudflare Tunnel topologies and a Google load balancer for any Nagare operator whose users must keep reaching sites without a VPN.
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-11-02T03:20:38Z"
researchId: RES-7
status: complete
scope: >-
  Desk evaluation for a general Nagare installation against Nagare's source and provider documentation read on
  2026-11-02. Nothing was deployed or tested on Cloudflare or Google Cloud, so every provider behaviour is documented
  or explicitly open rather than observed. An individual installation's constraints are out of scope.
sources:
  - id: nagare-infra
    resource: mori://shinzui/nagare/packages/infra-pulumi
    title: Nagare network perimeter, DNS records and CDN load balancer
  - id: cf-full
    resource: https://developers.cloudflare.com/dns/zone-setups/full-setup/
    title: Cloudflare full setup
  - id: cf-partial
    resource: https://developers.cloudflare.com/dns/zone-setups/partial-setup/
    title: Cloudflare partial (CNAME) setup
  - id: cf-subdomain
    resource: https://developers.cloudflare.com/dns/zone-setups/subdomain-setup/
    title: Cloudflare subdomain setup
  - id: cf-tunnel-dns
    resource: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/dns/
    title: Routing DNS to a Cloudflare Tunnel
  - id: cf-tunnel-firewall
    resource: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-with-firewall/
    title: Cloudflare Tunnel with a firewall
  - id: cf-saas-plans
    resource: https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/
    title: Cloudflare for SaaS plans
  - id: cf-wildcards
    resource: https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/
    title: Cloudflare wildcard DNS records
  - id: cf-acm
    resource: https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/
    title: Cloudflare Advanced Certificate Manager
  - id: cf-total-tls
    resource: https://developers.cloudflare.com/ssl/edge-certificates/additional-options/total-tls/
    title: Cloudflare Total TLS
  - id: cf-cache
    resource: https://developers.cloudflare.com/cache/concepts/default-cache-behavior/
    title: Cloudflare default cache behaviour
  - id: cf-limits
    resource: https://developers.cloudflare.com/fundamentals/reference/connection-limits/
    title: Cloudflare connection limits
  - id: cf-prices
    resource: https://www.cloudflare.com/plans/network-cdn.md
    title: Cloudflare plan prices
  - id: gcp-alb
    resource: https://docs.cloud.google.com/load-balancing/docs/https
    title: Google external Application Load Balancer overview
  - id: gcp-backend
    resource: https://docs.cloud.google.com/load-balancing/docs/backend-service
    title: Google backend services
  - id: gcp-cert-quotas
    resource: https://docs.cloud.google.com/certificate-manager/docs/quotas
    title: Google Certificate Manager quotas
  - id: gcp-cert-dns
    resource: https://docs.cloud.google.com/certificate-manager/docs/dns-authorizations
    title: Google Certificate Manager DNS authorizations
  - id: gcp-cert-price
    resource: https://cloud.google.com/certificate-manager/pricing
    title: Google Certificate Manager pricing
  - id: gcp-lb-price
    resource: https://cloud.google.com/load-balancing/pricing
    title: Google Cloud Load Balancing pricing
  - id: gcp-lb-logging
    resource: https://docs.cloud.google.com/load-balancing/docs/https/https-logging-monitoring
    title: Google load balancer logging
  - id: gcp-armor-price
    resource: https://cloud.google.com/armor/pricing
    title: Google Cloud Armor pricing
  - id: gcp-tier-price
    resource: https://cloud.google.com/network-tiers/pricing
    title: Google Network Service Tiers pricing
---

# Options for closing Nagare's inbound web ports with Cloudflare Tunnel or a Google load balancer

Evidence checked: 2026-11-02. This record compares options for any Nagare operator and proposes a direction. It claims no
tested behaviour. Provider rates come from search extracts of the pricing pages, because those pages could not be read
directly, and should be confirmed before budgeting.

## Question and constraints

How can a context stop accepting web traffic directly from the internet while its users keep opening sites in an ordinary
browser? Requiring visitors to join a VPN or a tailnet is not acceptable for a general platform. The cost should stay in
the tens of dollars a month at most.

## What Nagare exposes today

[NagareNetwork.ts](../../infra/pulumi/src/components/NagareNetwork.ts) declares these rules unconditionally:

| Rule | Port | Source |
| --- | --- | --- |
| `fw-web` | TCP 80, 443 | `0.0.0.0/0` |
| `fw-tailscale` | UDP 41641 | `0.0.0.0/0` |
| `fw-lb-health` | TCP 80, 443 | Google load balancer ranges |
| `fw-iap-ssh` | TCP 22 | Google IAP range only |

The Kubernetes API is reachable only over the tailnet and databases only inside the cluster.

## Cloudflare's plan rules

- A full setup, where the domain's name servers point at Cloudflare, is the only setup on Free and Pro. A subdomain setup is
  Enterprise only. A partial (CNAME) setup is Business or Enterprise.
- A wildcard certificate covers one level. Multi-level names need Advanced Certificate Manager, at $10 a month and up to 50
  hosts per certificate. Total TLS does not issue for Cloudflare Tunnel hostnames.
- Proxied wildcard DNS records are available on every plan and are multi-level by default.
- Cloudflare for SaaS includes 100 custom hostnames on Free, Pro and Business, then $0.10 each. Wildcard custom hostnames
  and apex proxying are Enterprise only.
- Pro is $20 a month billed annually or $25 monthly. Business is $200 or $250. Enterprise is a custom contract.

## Options

| Option | Monthly cost | Inbound rules left | Domain's DNS | Upload limit |
| --- | --- | --- | --- | --- |
| **A. Base domain on a full Cloudflare zone, with a tunnel** | $0, or $10 for a subdomain base | None | Moves to Cloudflare | 100 MB |
| B. Google load balancer in front of the VM | About $19–30 plus the items below | 80 and 443 from Google ranges only | Stays in Cloud DNS | None found |
| C. Cloudflare for SaaS on a separate zone | $0 for up to 100 hostnames, plus a domain | None | Stays | 100 MB |
| D. Cloudflare Business partial setup | $200–250 | None | Stays | 200 MB |
| E. Cloudflare Enterprise subdomain setup | Custom contract | None | Subdomain moves | Up to 5 GB |
| F. Direct ingress, today's default | $0 | 80, 443 and 41641 from anywhere | Stays | None |
| G. Tailnet only | $0 or Tailscale seats | None | Stays | None |

D and E are outside the budget, and Cloudflare's documentation does not state that a tunnel works behind D. G fails the
constraint on visitors. Prices for a domain and for Tailscale seats were not looked up.

### A. A full Cloudflare zone with a tunnel

The apex and `*.<base>` become proxied CNAME records to the tunnel. A connector inside the cluster forwards to Kourier.
One wildcard record replaces per-hostname routes, and a zone apex can be served.

The cost depends on where the base domain sits:

- **The base domain is the zone** (`example.dev`). The free certificate covers the apex and one label below it, so one-label
  names cost nothing. This is the shape to recommend.
- **The base domain is a subdomain of the zone** (`apps.example.com`). Its sites are two levels below the zone, so Advanced
  Certificate Manager is required at $10 a month.

In both shapes, Nagare's default `<name>.<namespace>.<base>` is one level too deep for the free certificate. Flattening default
names to `<name>-<namespace>.<base>` in tunnel mode avoids a paid add-on. Knative supports this through its domain template, and
Nagare's ownership checks would have to refuse a collision.

cert-manager's Cloud DNS solver stops working once the domain moves. Rather than keep a Cloudflare DNS-01 token in the cluster, which
would give the cluster power over the whole zone, the connector can talk to Kourier inside the cluster with public origin certificates
off. Only the tunnel token then enters the cluster, and `CF_API_TOKEN` stays on the operator's machine.

### B. Google load balancer

Nagare already has this component in [NagareCdn.ts](../../infra/pulumi/src/components/NagareCdn.ts). The wildcard and apex A records would
point at the load balancer's global IP, and `fw-web` would be removed so only `fw-lb-health` admits 80 and 443.

Strengths: DNS stays where it is, an A record can sit at a zone apex, there is no new vendor, no upload limit was found, and the backend
timeout is configurable with a 30-second default.

Limits:

- **It does not remove the inbound rule.** Ports 80 and 443 stay open to `130.211.0.0/22` and `35.191.0.0/16`. Google's documentation
  does not state outright that only its front ends can reach them. It does say backend VMs need no external IP.
- **The existing backend cannot be reused as written.** It sets `enableCdn: true` with `CACHE_ALL_STATIC`, and protected sites refuse a CDN
  under [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md). A backend with the CDN off is needed.
- **Certificates are one level per authorization.** A DNS authorization covers one domain name, so two-label names need one per namespace.

Costs:

| Item | Rate | Note |
| --- | --- | --- |
| Forwarding rules | $0.025 an hour for the first five, about $18.25 a month | Nagare's two rules fit in this |
| Data processing | $0.008 per GiB, in and out; up to $0.012 by region | About $8–12 per TB out, plus requests in |
| Certificate Manager | Free for the first 100 certificates | No per-connection charge on RSA-2048 or ECDSA keys |
| Internet egress | About $0.12 per GiB on Premium Tier to North America, falling with volume | Not new, and applies to every option here |
| Cloud Logging | Default sample rate 1.0 when logging is on | Ingestion charges can apply; lower or disable the rate |
| Cloud Armor | About $5 per policy, $1 per rule a month, $0.75 per million requests | Optional |
| Cloud CDN | Cache and transfer charges | Optional and off here |
| Global static IP | Not confirmed | Could not be found in the sources read |

## Consequences common to the Cloudflare options

- Cloudflare decrypts traffic at its edge, including session cookies and page content. In option B Google does the same at its load balancer.
- The proxy read timeout is 125 seconds (error 524).
- Cloudflare caches by file extension by default, including `.js`, `.css` and `.pdf`, unless the response opts out. The documentation does not say
  a request's cookies affect this, so a protected file could reach an anonymous visitor. This must be disproven before a protected site goes through
  Cloudflare.
- The connector needs outbound TCP and UDP on port 7844 and no inbound port. Cloudflare's guide uses two replicas. On one node, that tolerates a pod
  restart and not a node loss.

## Consequences common to all options

Traffic still leaves GCP as internet egress. Closing `fw-tailscale` moves Tailscale to its relays, which may slow operator commands. Removing ports from
the NixOS firewall would probably not close them, because Kourier's host ports probably bypass it. The GCP firewall is the control to change.

## Proposed direction

**Recommend option A to anyone running Nagare**, with a domain used only for Nagare as the base domain. It leaves no inbound rule, costs nothing beyond
the domain and existing egress, and removes the Cloud DNS delegation step from onboarding. Direct ingress stays supported.

Option B is the alternative for an operator who cannot move their domain's DNS or will not let Cloudflare see their traffic. Option C is the alternative
when the domain cannot move and a load balancer's inbound rule is unacceptable. Neither is built by MasterPlan 32.

## Open questions to test before building

1. Does a proxied wildcard CNAME to `<id>.cfargotunnel.com` serve names? The documentation states wildcards are multi-level and that several records may
   point at one tunnel, but shows no wildcard tunnel example.
2. Do sites still route, and do login cookies and redirects stay correct, with `external-domain-tls` off and the connector talking to Kourier in the cluster?
3. Do flattened default names work across Knative, Nagare's URL code, previews and protected routes?
4. Does an Advanced Certificate Manager certificate with `*.<base>` serve tunnel hostnames, given Total TLS's exclusion?
5. Is a protected file ever served to an anonymous request?
6. Does a full browser login survive through the tunnel, including session renewal?
