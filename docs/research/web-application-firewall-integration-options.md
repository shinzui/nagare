---
type: Research Document
title: Web Application Firewall integration options for Nagare
description: Compare managed edge and self-hosted WAF placements against Nagare's ingress, CDN, and origin-access design.
generated:
  by: process:openai-codex
  at: "2026-09-25T13:14:46Z"
researchId: RES-2
status: complete
scope: Nagare's single-node GCP and local ingress as implemented on 2026-09-25, plus current official Cloud Armor, Cloudflare, Coraza, and OWASP CRS documentation; no live WAF or edge deployment was performed.
sources:
  - id: nagare-ingress
    resource: mori://shinzui/nagare/packages/cluster-bootstrap
    title: Nagare Kourier and Envoy ingress substrate
  - id: nagare-cloud
    resource: mori://shinzui/nagare/packages/infra-pulumi
    title: Nagare CDN load balancer and network perimeter
  - id: cloud-armor-cdn
    resource: https://docs.cloud.google.com/armor/docs/integrating-cloud-armor
    title: Google Cloud Armor and Cloud CDN integration
  - id: cloud-armor-policy
    resource: https://docs.cloud.google.com/armor/docs/security-policy-overview
    title: Google Cloud Armor security policy overview
  - id: cloudflare-waf
    resource: https://developers.cloudflare.com/waf/managed-rules/
    title: Cloudflare WAF managed rules
  - id: cloudflare-origin
    resource: https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/
    title: Cloudflare origin IP protection guidance
  - id: coraza-connectors
    resource: https://www.coraza.io/connectors/
    title: Coraza connectors
  - id: coraza-wasm-release
    resource: https://github.com/corazawaf/coraza-proxy-wasm/releases/tag/0.6.0
    title: Coraza Proxy WASM 0.6.0 release notes
  - id: crs-tuning
    resource: https://coreruleset.org/docs/2-how-crs-works/2-3-false-positives-and-tuning/
    title: OWASP CRS false positives and tuning
reviews:
  - kind: model
    reviewer: openai-codex
    reviewed_at: "2026-09-25T13:17:08Z"
    document_timestamp: "2026-09-25T13:14:46Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: gpt-6
    effort: medium
    context: >-
      Author self-review against Nagare source and the cited provider documentation; independent review and live edge evidence remain pending.
---

# Web Application Firewall integration options for Nagare

Evidence checked: 2026-09-25. This record describes options and a proposed direction; it does not select an implementation or claim production protection.

## Question and current boundary

Where can Nagare enforce application-layer filtering for HTTP requests without letting traffic bypass the filter or disrupting Knative host routing?

The default path is `client -> VM public IP:80/443 -> k3s ServiceLB -> Kourier/Envoy -> Knative Service`. Traefik is disabled. The [network component](../../infra/pulumi/src/components/NagareNetwork.ts) allows `0.0.0.0/0` to reach the VM on 80/443. Wildcard Cloud DNS points at the VM except for exact Google CDN records; Cloudflare's proxied records also forward to the VM. These are code and [operator-guide](../user/cdn.md) facts, and mean an edge WAF alone does not cover requests sent directly to the origin IP with a protected `Host` header.

Nagare also has an optional [Google global external Application Load Balancer](../../infra/pulumi/src/components/NagareCdn.ts) with one CDN-enabled backend service shared by Google CDN hosts. The component is created only when `nagare:enableCdn` is enabled. Its backend currently speaks HTTP to port 80, so enabling client-side HTTPS at the edge does not encrypt that origin hop. The Cloudflare [provisioner](../../cli/nagarectl/src/Nagare/Cdn/Provision.hs) currently sets the zone's SSL mode to `Flexible` on each deploy, which also leaves its origin hop unencrypted and changes a setting shared by that zone's proxied hosts. The [CDN guide](../user/cdn.md) identifies Full (strict) as the intended Cloudflare steady state. Live edge verification is still pending in that guide.

## Options

| Placement | What Nagare could reuse | Coverage and cost of ownership | Main constraint |
| --- | --- | --- | --- |
| Google Cloud Armor on the external Application Load Balancer | Existing Pulumi global load balancer and backend service | Google operates the WAF; security-policy, rule, request, and load-balancer charges apply. Suitable for a GCP-first platform perimeter. | Only traffic routed through the load balancer is protected. The existing backend and CDN opt-in are coupled, and one backend policy is shared by all routed hosts. |
| Cloudflare WAF on proxied DNS records | Existing Cloudflare DNS/cache API client | Cloudflare operates the WAF; the Free Managed Ruleset is available on the free plan, while broader managed rules depend on plan. Suitable for Cloudflare-hosted zones. | Direct origin traffic bypasses it; zone ownership, zone-wide TLS settings, and cross-provider hostnames need an explicit operating model. |
| Self-hosted Coraza with OWASP CRS before Kourier | Existing single cluster and Envoy-based ingress | Works without a paid edge or DNS-provider dependency and can inspect direct requests if it owns every public HTTP entry point. Nagare operates the WAF, rule updates, tuning, CPU/memory, and failure behavior. | Kourier currently owns host ports through ServiceLB. A front proxy changes TLS, port ownership, health checks, and source-IP handling. Injecting a filter into Kourier's controller-managed Envoy requires a durable supported seam. |

[Cloud Armor policies](https://docs.cloud.google.com/armor/docs/security-policy-overview) attach to load-balancer backends. With Cloud CDN, a backend policy evaluates dynamic requests and cache misses, while an edge policy can filter before cache hits with a narrower feature set; the two placements should not be described as equivalent. An external Application Load Balancer can be used without caching, but Nagare's current Pulumi component couples it to CDN. Separating ingress/WAF from caching is an implementation inference, not a current Nagare capability. [Google's integration documentation](https://docs.cloud.google.com/armor/docs/integrating-cloud-armor) describes the cache boundary, and [pricing](https://cloud.google.com/armor/pricing) gives the current billable dimensions.

[Cloudflare WAF managed rules](https://developers.cloudflare.com/waf/managed-rules/) are a practical path for existing proxied hostnames. Cloudflare's [origin guidance](https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/) explicitly recommends blocking non-Cloudflare traffic to prevent bypass. That cannot be applied wholesale while Nagare still serves direct hosts on the same VM ports. A distinct protected origin listener, migration of all public hosts, or an outbound-only [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) would change that topology. Source-IP allowlisting by itself admits requests from Cloudflare's shared proxy ranges; it does not authenticate a particular zone. Full (strict) TLS and, where appropriate, authenticated origin pulls need separate design and verification.

[Coraza](https://www.coraza.io/connectors/) has Envoy and other proxy connectors, including Proxy-Wasm. That establishes technical feasibility for a prototype, not compatibility with Nagare's vendored Kourier lifecycle. The [Proxy-Wasm 0.6.0 release](https://github.com/corazawaf/coraza-proxy-wasm/releases/tag/0.6.0) warns of reported memory leaks and performance degradation in its runtime and recommends extensive testing. A separate Coraza-capable proxy before Kourier would avoid modifying Kourier-generated Envoy configuration but would become the public listener and an additional hop on Nagare's single node. These alternatives require a measured spike before selecting a connector or pin.

## Proposed direction

Treat WAF as an optional **platform ingress capability**, separate from CDN caching. Keep a context-level default and allow narrowly scoped per-host/path tuning where the chosen provider supports it. For Coraza, prototype both a supported Envoy integration and a separate front proxy against the actual Kourier version, then select the integration that survives reconciliation and upgrades. Do not promise that an origin WAF inspects Cloud CDN cache hits or traffic terminated entirely at another edge.

Before calling any option protective, verify the full public path and try a direct-IP request with the protected hostname. Preserve the original `Host` header for Knative routing; trust forwarded client-IP headers only from the configured proxy; define TLS termination and the origin hop; keep certificate DNS-01 issuance working; and ensure WAF failure cannot silently reopen an unfiltered path. Start CRS in detection mode, tune against legitimate routes, then enable blocking with a rollback path. [OWASP CRS tuning guidance](https://coreruleset.org/docs/2-how-crs-works/2-3-false-positives-and-tuning/) explains why exclusions and paranoia-level changes need review.

## Open questions for implementation

- Which connector is compatible with the Kourier/Envoy version Nagare vendors and remains stable during Knative reconciliation and platform upgrades?
- What are the measured latency, memory, and CPU costs on the single-node VM, including large bodies and concurrent requests?
- Should protected hosts share a global rule set, or should host/path exceptions be compiled into a reviewed context policy?
- How will logs identify a rule and hostname without retaining request bodies, credentials, or session tokens?
- When Cloudflare or Google CDN serves a cache hit, which edge policy, if any, is expected to evaluate it?

The corresponding Coraza proposal is [IR-25](../improvement-requests/add-coraza-web-application-firewall-support.md).
