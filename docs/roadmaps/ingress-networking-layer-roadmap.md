# Ingress Networking-Layer Roadmap for Nagare

Created: 2026-06-10

This page asks a single question: should Nagare change the **networking layer** that sits
underneath Knative Serving — today that is **Kourier** — and in particular should it migrate to
**Envoy Gateway** via Knative's **Gateway API** adapter (`net-gateway-api`)? Like
`docs/roadmaps/kubernetes-controller-roadmap.md` and `docs/roadmaps/paas-gap-roadmap.md`, this is an
analysis and a set of decision triggers, not an implementation plan.

The short version: **not now.** The specific limitation that prompted the question — wildcard TLS
problems attributed to "Contour" — does not apply to Nagare, for two independent reasons that this
document verifies below. But the underlying instinct (align with the Kubernetes Gateway API, get
more of Envoy's capabilities) is sound and matches Knative's own published direction, so this page
records what we would gain, what must never change, and the exact triggers that should reopen the
decision.

**Hard constraint, stated once and for all: Knative Serving stays.** Nothing in this document
proposes removing Knative. Scale-to-zero, revisions, per-revision traffic splitting, and
`DomainMapping` are load-bearing for shipped work (MasterPlan 3 static hosting, MasterPlan 11 CDN)
and for the product's identity. Every option considered here keeps Knative as the application
runtime and changes only the layer that programs the HTTP edge beneath it.


## What Nagare runs today

Nagare's HTTP edge is **Kourier** (`net-kourier`, pinned to release `knative-v1.22.0`; see
`cluster/bootstrap/kourier/README.md`). Kourier is Knative's purpose-built, lightweight ingress
implementation. Its own one-line description is *"a Knative Ingress implementation using just Envoy
with no additional CRDs."* The request path looks like this:

```text
Nagare app (Knative Service + optional DomainMapping)
        │  rendered by cli/nagare-dsl/src/Nagare/Dsl/Render.hs
        ▼
Knative Serving ── renders ──▶ KIngress (Knative-internal CRD)
        │
        ▼
Kourier controller ── xDS ──▶ Envoy proxy  ◀── terminates :80/:443, routes by Host header
```

TLS is **cert-manager + Let's Encrypt** issuing a **per-namespace wildcard certificate**
(`*.<namespace>.<baseDomain>`) over the **DNS-01** challenge against Google Cloud DNS, bridged into
Knative by `net-certmanager` pointing at the `letsencrypt-dns` ClusterIssuer (see
`cluster/bootstrap/cert-manager/README.md` and `cluster/bootstrap/net-certmanager/`). As of this
writing the live wiring is deferred until a real domain is delegated, but the design is fixed.

The single most important fact for this whole discussion: **the data-plane proxy is Envoy in both
the current world and any Gateway-API world.** A migration would not swap the proxy. It would swap
the *controller and the API* that program that proxy.


## Correcting the premise

Three names collide here and were conflated in the original framing. Keeping them apart is what makes
the decision clear:

- **Contour** — a *different* Knative networking layer (`net-contour`) that Nagare does **not** use.
  A repository-wide search finds zero Contour anywhere in this codebase. The wildcard-TLS limitations
  written up against "Contour" online (the Safari HTTP/2 connection-coalescing issue; HTTPProxy/Ingress
  `secretName` requirements) are properties of `net-contour`, a layer we would have to deliberately
  opt into and have not.

- **Envoy (the proxy)** — the C++ data-plane binary that actually terminates TLS and routes HTTP.
  Kourier already runs Envoy. We are *already on Envoy.*

- **Envoy Gateway (the project)** — a controller that implements the Kubernetes **Gateway API**
  (`GatewayClass` / `Gateway` / `HTTPRoute` CRDs) and manages Envoy proxies. This — not "a better
  proxy" — is what a migration would actually adopt: the standard Gateway API surface plus Envoy
  Gateway's policy extensions, programming the same Envoy.

So "aren't we already on Envoy?" — yes. Adopting Envoy Gateway does not buy a different or better
proxy. It buys a different, standardized, more capable **control surface** in front of the same
proxy.


## The wildcard-certificate concern, verified

Two questions had to be answered with evidence rather than memory.

**1. Does Kourier support wildcard certificates at all?** Yes. Wildcard TLS in Knative is delivered
by the **per-namespace wildcard certificate** feature, which is networking-layer-agnostic (it works
identically on Kourier, Contour, and Istio). A controller watches namespaces, requests one
`*.<namespace>.<baseDomain>` certificate per namespace from the domain template, and each Knative
route in that namespace reuses it. Wildcards require **DNS-01** (HTTP-01 cannot validate a
wildcard). Nagare is already architected exactly this way, so "give every app in a namespace HTTPS
under one wildcard" is supported and is the path we are on.

**2. Were the real Kourier TLS sharp edges still live?** The genuine historical weakness was not
"Kourier can't do wildcards" — it was Kourier's handling of **multiple certificates on one Envoy
listener**, i.e. the default per-namespace wildcard *plus* per-domain `DomainMapping` certificates
served together via SNI. Two issues captured this:

- `knative-extensions/net-kourier#740` — *"Global TLS is disabled when a KIngress is configured with
  a TLS secret."* **Status: CLOSED / COMPLETED, 2022-01-11.**
- `knative/serving#12377` — *"BYO Certificate / Kourier issues with autoTLS."* **Status: CLOSED /
  COMPLETED, 2022-01-26.**

Both were fixed in **January 2022**. Nagare pins `knative-v1.22.0`, a 2025 release, so both fixes are
included by a wide margin. **The limitation that prompted this investigation is historical and does
not apply to Nagare.** This is the primary reason the migration is postponed rather than scheduled.


## Why postpone

1. **The triggering limitation is not applicable.** As verified above, Nagare's wildcard model is the
   supported per-namespace DNS-01 path, and the multi-cert Kourier bugs were fixed three years before
   the version we run.

2. **Pre-launch stability beats churn.** Nagare is between "deployable" and "has users." Swapping the
   networking layer now introduces a migration risk with no offsetting user-facing benefit today.

3. **The replacement is still Beta.** Knative's `net-gateway-api` adapter is Beta (alpha for full
   feature parity). Known gaps at the time of writing: the HTTP-disable option is not fully
   implemented, and external HTTP-01 TLS is capped at 64 certificates by the Gateway API listener
   limit. Nagare's per-namespace wildcard DNS-01 model sidesteps the 64-cert cap, which makes us a
   *good* future candidate — but "good candidate for a Beta component" is not "migrate before
   launch."

4. **Nothing we ship today routes through raw `Ingress`.** Nagare uses Knative's `KIngress`
   abstraction and `DomainMapping`, not Kubernetes `Ingress` resources. The generic "Kubernetes is
   migrating Ingress → Gateway API" pressure therefore does not land on Nagare directly; it lands one
   level down, on which Knative networking layer we choose, and Knative continues to support Kourier.


## What we would gain if we migrate

Because Kourier is deliberately minimal ("just Envoy, no additional CRDs"), it exposes almost none of
Envoy's richer capabilities — you get Host-based routing and TLS termination and little else
configurable. Envoy Gateway surfaces a large fraction of Envoy's feature set through standard,
attachable policy CRDs. The capabilities below already exist in the Envoy that Kourier runs; the gain
is that Envoy Gateway makes them *configurable* through a supported API rather than hidden:

- **A vendor-neutral, standard control surface.** `Gateway` / `HTTPRoute` (plus `GRPCRoute`,
  `TLSRoute`, `TCPRoute`, `UDPRoute`) instead of Kourier's bespoke `KIngress` translation. Portable
  across implementations and aligned with where Kubernetes networking is converging.

- **Edge security policy** (`SecurityPolicy`): JWT authentication, OIDC login, external authorization
  (ext-authz), CORS, API-key auth, and IP allow/deny lists — attachable per route or per gateway.
  Today none of these are expressible at Nagare's edge without a sidecar or app-level code.

- **Traffic management** (`BackendTrafficPolicy` / `ClientTrafficPolicy`): global and local rate
  limiting, circuit breaking, retries, timeouts, request buffering, and connection tuning as
  first-class configuration rather than Envoy bootstrap hacks.

- **Standardized multi-certificate TLS.** Multiple `certificateRefs` and clean SNI selection for
  serving a per-namespace wildcard alongside many custom per-domain certificates — precisely the
  scenario Kourier historically handled poorly. This is the one item that could become a *technical*
  (not merely strategic) driver, if and when custom-domain-with-own-cert usage grows under the
  MasterPlan 11 CDN and custom-domain features.

- **Deeper extensibility** (`EnvoyExtensionPolicy` / `EnvoyPatchPolicy`): Wasm modules, external
  processing (ext-proc), and targeted raw-xDS patches for anything the high-level policies do not
  cover.

- **Managed proxy provisioning.** Creating a `Gateway` automatically provisions the backing
  Deployment / Service / HPA, versus Kourier's fixed static deployment.

- **Roadmap alignment.** Knative's stated direction (knative/serving#15729) is to make the Gateway
  API the default network layer, let operators skip Kourier/Istio entirely, and deprecate the legacy
  layers opt-in. Migrating eventually moves Nagare *with* the project rather than against it.

**Honest caveat to record now:** with Knative + `net-gateway-api`, the `Gateway` and `HTTPRoute`
resources are generated and owned by the Knative adapter. Attaching Envoy Gateway policy CRDs
(`SecurityPolicy`, `BackendTrafficPolicy`, etc.) to adapter-owned resources via `targetRef` is
plausible but not proven for Nagare, and the adapter's reconciliation could contend with
externally-attached policy. Whether those Envoy Gateway features are *actually usable underneath
Knative* — as opposed to usable on a standalone Envoy Gateway — is the single most important
unknown, and is the first thing any future feasibility spike must answer.


## The shape of a migration, if we ever do it

Recorded so the decision starts from a known design rather than a blank page. The migration is a
**networking-layer swap that keeps Knative**, not a rewrite of how apps are modeled:

1. **Feasibility spike (hard gate).** Stand up Envoy Gateway + `net-gateway-api` *alongside* Kourier
   on a throwaway cluster. Prove KIngress → Gateway/HTTPRoute parity for a typical Nagare app, prove
   the per-namespace wildcard DNS-01 TLS path works, prove `DomainMapping` equivalents work, and test
   whether Envoy Gateway policy CRDs can attach to adapter-owned routes (the caveat above). If parity
   or the wildcard TLS path fails, stop — the migration is not viable yet.

2. **TLS parity.** Reproduce the cert-manager per-namespace wildcard model under Gateway API and
   confirm multi-cert SNI behavior for wildcard + custom domains.

3. **Bootstrap.** Replace `cluster/bootstrap/kourier/` with a scripted Envoy Gateway + `GatewayClass`
   install, mirroring the existing pinned-version, idempotent bootstrap conventions.

4. **Cutover + rollback runbook.** Switch Knative's `ingress-class` to the Gateway API adapter behind
   a documented, reversible procedure under `docs/runbooks/`; decommission Kourier only after a soak
   period.

5. **Docs + decision record.** Update `docs/user/cluster-bootstrap.md` and record the outcome here.

The renderers in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (and the Static/Server variants) emit
Knative `Service` + `DomainMapping`, which are **networking-layer-agnostic**. That is the key reason
this swap is contained: it should require little or no change to the typed DSL or `nagarectl`, only
to cluster bootstrap and TLS wiring. When this work is scheduled it is well-sized for its own
MasterPlan with roughly the five child plans above, spike-gated.


## Decision triggers — revisit when any of these becomes true

- **Custom-domain-with-own-certificate usage grows.** If users routinely bring custom domains with
  their own certificates (likely as MasterPlan 11 CDN and custom-domain features mature), the
  standardized multi-cert SNI handling of Gateway API becomes a real technical advantage and may
  justify migration on its own merits.

- **A need for edge auth, rate limiting, or CORS appears.** The first concrete requirement for
  JWT/OIDC auth, external authorization, global rate limiting, or managed CORS at the platform edge
  is a strong signal — these are awkward-to-impossible on Kourier and native to Envoy Gateway.

- **`net-gateway-api` graduates from Beta to a stable/recommended Knative networking layer**, closing
  the HTTP-disable gap and demonstrating large-`Service`-count stability.

- **Knative announces a concrete Kourier deprecation timeline.** Per knative/serving#15729 this is
  the stated direction; a dated deprecation converts "eventually" into "schedule it."

- **A new Kourier-specific TLS or routing limitation actually bites Nagare in production** — unlike
  the historical bugs in this document, which do not.

Until at least one trigger fires, Nagare stays on Kourier. This page should be updated (with a
`Last updated:` line) whenever a trigger is evaluated, so the postponement remains a deliberate,
re-examined choice rather than neglect.


## References

- Knative networking layers / adapters: https://knative.dev/docs/serving/config-network-adapters/
- `net-kourier` ("just Envoy, no additional CRDs"): https://github.com/knative-extensions/net-kourier
- `net-gateway-api` (Knative ↔ Gateway API): https://github.com/knative-extensions/net-gateway-api
- Knative proposal to make Gateway API the default and deprecate legacy layers:
  https://github.com/knative/serving/issues/15729
- Per-namespace wildcard cert + external-domain TLS:
  https://knative.dev/docs/serving/encryption/external-domain-tls/
- Kourier TLS bug, now fixed: https://github.com/knative-sandbox/net-kourier/issues/740
- Kourier BYO-cert / autoTLS bug, now fixed: https://github.com/knative/serving/issues/12377
- Envoy Gateway: https://gateway.envoyproxy.io/
- Gateway API implementations list: https://gateway-api.sigs.k8s.io/implementations/
