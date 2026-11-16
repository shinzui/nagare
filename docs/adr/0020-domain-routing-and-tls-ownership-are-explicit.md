---
title: "Domain routing and TLS ownership are explicit"
status: accepted
date: 2026-09-14
authors: [shinzui]
related:
  - docs/plans/131-make-apex-and-multi-domain-routing-production-ready.md
  - docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
  - docs/adr/0010-the-active-context-owns-the-acme-identity.md
  - docs/adr/0014-the-active-context-owns-the-vm-shape.md
---

# ADR 20 — Domain routing and TLS ownership are explicit

## Status

Accepted, 2026-09-14. Implemented by
[ExecPlan 131](../plans/131-make-apex-and-multi-domain-routing-production-ready.md).

## Context

Nagare's ordinary, static, and server workloads previously disagreed about
domain shape and canonical selection. The platform owned a wildcard DNS record
but no exact base-domain record, even though DNS wildcard synthesis cannot
answer the zone apex. A deploy could also retarget a hostname claimed by
another workload. Origin certificates and CDN edge certificates were implicit,
and Google CDN could receive hostnames its one-name certificate did not cover.

These are ownership failures rather than renderer details. The same hostname is
a Kubernetes resource name, DNS owner, SNI name, advertised URL, and deletion
key. DNS, routing, origin TLS, and edge TLS have different controllers and must
not be treated as one readiness signal.

## Decision

All three web workload kinds use one normalized `DomainSpec` list. A non-empty
list has exactly one explicitly canonical entry and every entry selects either
automatic origin TLS or a supplied namespace-local TLS Secret. Canonical
selection controls the advertised URL only; Nagare does not redirect alternate
hostnames.

Pulumi owns both `*.<baseDomain>` and the exact `<baseDomain>` A records. The
wildcard always targets the VM. The apex targets the VM unless the standing
Google CDN exists, in which case it targets the CDN global IP. Application
deploys read all claims and routes before mutation, refuse conflicting
ownership, and wait for every DomainMapping and covering origin certificate.

Automatic origin TLS uses Knative and net-certmanager. It is supported for the
context base zone and other authoritative Cloud DNS parent zones in the active
project. An external authority requires an explicitly configured solver or a
supplied Secret containing `tls.crt` and `tls.key`. Every cloud read and write is
pinned to the active project, consistent with ADR 9; ACME identity remains
context-owned under ADR 10.

Google CDN uses a Certificate Manager DNS authorization, one certificate for
the apex and `*.<baseDomain>`, and exact plus wildcard certificate-map entries.
Migration is an explicit `legacy` → `prepare` → `certificate-map` state machine.
Prepare leaves the legacy proxy serving while the replacement is issued; the
status command offers activation only after `ACTIVE`. Google accepts only the
apex and one-label names under the base domain. Cloudflare remains the provider
for unrelated CDN zones.

## Consequences

The base domain can safely host an ordinary landing workload, and multi-domain
deployments behave identically across workload kinds. Conflicts, unsupported
certificate authority, missing supplied-secret keys, and unhealthy routes fail
before success is reported. `domains list` exposes partial observations while
`domains check` is a strict operational gate.

DNS-zone replacement remains protected by ADR 14. Existing CDN stacks retain
legacy serving until an operator previews and advances the certificate mode.
Certificate Manager adds a DNS-authorization record and service API, but avoids
per-host edge-certificate changes for every supported first-level hostname.

The stronger model intentionally does not add canonical redirects, multiple
platform base domains, or credentials for arbitrary external DNS providers.

## Amendment — 2026-09-25: reviewed Google host DNS ownership

The platform continues to own the apex A record, wildcard DNS, and standing
Google CDN backend. An application or production site with Google CDN owns each
of its explicit host A records through a separate DNS declaration scoped to
that workload. The declaration claims the exact project, zone, and hostname,
and depends on its DomainMapping and an accepted platform BackendService.
The DomainMapping and DNS record may share the hostname claim only when they
have the same scope owner and the DNS record waits for that route. A different
workload or third declaration still conflicts.

Reviewed Cloud DNS updates delete the exact accepted old record set and add the
new one in one provider change. A record already present without accepted
ownership is foreign even if its value matches. Because this contract has no
stable per-record incarnation, an uncertain mutation requires explicit
recovery even if a subsequent listing is empty; retirement retains the DNS
claim.

## Amendment — 2026-09-25: Cloudflare zone and host claims

Cloudflare proxied A records have separate zone-and-host claims owned by the
application or production site that declares the matching DomainMapping.
The DNS record and DomainMapping may share the hostname claim only for that
same owner with an explicit route dependency. A platform scope owns one
`http_request_cache_settings` ruleset and one origin-TLS setting claim per
Cloudflare zone. Its zone grant fixes the TLS mode. Workload scopes submit
host-specific cache intent through owner grants; the inventory
composer produces the complete ruleset from every accepted host contribution.
No workload owns a partial zone ruleset or can replace the complete set alone.
Cloudflare applies the last matching cache setting, so broad defaults precede
static rules and declared path rules are emitted in reverse priority order.
Expression string literals are escaped and path prefixes are validated.

The typed ownership, deterministic rules rendering, and a recording adapter
contract are in place. Its prepared operations bind old content and physical
identity; uncertain writes remain unresolved. Cloudflare HTTP transport,
context and zone verification, provider serialization, and live proof are
still required before reviewed Cloudflare writes can run. The direct
provisioner remains a legacy path. Direct zone-wide provision and purge refuse
while any Cloudflare zone is accepted or retained in the context or a review
transaction is active.

## Amendment — 2026-11-02: tunnel mode moves the wildcard to Cloudflare

For a context that opts in to [ADR 34](0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md), the base domain's DNS is on
Cloudflare and the apex and wildcard are proxied CNAMEs to the context's tunnel, not Pulumi records targeting the VM. Cloud DNS is no longer authoritative
for that domain, so `letsencrypt-dns` issues nothing there and `external-domain-tls` stays off; Cloudflare's free certificate covers the apex and one label
below it. The operator's machine holds the scoped Cloudflare API token and the cluster holds only the tunnel token, so the rule that the cluster holds no
credential for an external DNS provider still stands. A context that does not opt in is unchanged. EP-242 owns the DNS expectation and the platform zone claims
for this mode, using the zone-and-host ownership of the 2026-09-25 amendment; EP-240 observed the topology by hand and no product code implements it yet.

## Amendment — 2026-11-16: a moved context ends where a new tunnel context starts

EP-243 moves a direct context onto the tunnel with `nagarectl context move`. Its end state is the same as a new tunnel context's: Cloudflare is
authoritative for the base domain, the apex and wildcard are proxied CNAMEs to the tunnel, `fw-iap-ssh` is the network's only firewall rule,
and `kourier` is a `ClusterIP` Service. The `certificate-issuer` scope stays accepted and installed, since admission never reactivates a
retired identity and a rollback must be able to bring DNS-01 back; with Cloudflare authoritative it can no longer issue. Two other things differ
until the operator retires them. The Cloud DNS zone, its
two records and the solver's two grants are kept (`NAGARE_RETAINED_DNS_NAME`), so a resolver holding the old delegation still reaches an answer;
`context move retire-dns` collects the zone and records by review once the parent and public resolvers name only Cloudflare, and retires the two
grants without deleting them. And default names change from `<name>.<namespace>.<base>` to `<name>-<namespace>.<base>`, because the free edge
certificate covers one label below the base; a move does not start while a protected default name or a two-label custom domain would stop being
served. During the move Cloudflare serves DNS-only mirror records pointing at the VM, and origin certificates keep serving until `close-kourier`,
so a move refuses to start when a certificate renews within 14 days, and admission refuses every other review while it is open.

## Amendment — 2026-11-16: a context's base domain can change, through a move (EP-246)

`NAGARE_BASE_DOMAIN` is no longer fixed for a context's life. Only an open move to a new base changes it, together with
`NAGARE_INGRESS` and `NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED`; a plain context review of any of them is still refused. The Cloud DNS zone
keeps the old name as `NAGARE_RETAINED_DNS_NAME` until `context move retire` removes it, which it does only once the parent no longer
delegates the old base. See [Moving a context to a new base domain](../user/moving-to-a-new-base-domain.md).
