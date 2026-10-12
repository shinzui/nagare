---
id: 56
slug: gcp-cloud-cdn-load-balancer-provisioning-in-pulumi
title: "GCP Cloud CDN load balancer provisioning in Pulumi"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# GCP Cloud CDN load balancer provisioning in Pulumi

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a single-node personal Platform-as-a-Service: one Google Cloud virtual machine
named `nagare-01` in GCP project `tan-nb-exp`, region `us-west1`, zone `us-west1-a`, running
k3s (a small Kubernetes), Knative Serving, and the Kourier ingress gateway (an Envoy-based
HTTP front door for Knative). Today every request from anyone in the world travels all the way
to that one VM, because the only public entry point is the VM's static regional IP behind a
`*.apps.example.com` wildcard DNS record.

A Content Delivery Network ("CDN") is a globally distributed cache that sits in front of an
origin server, so visitors are served cached responses from a nearby edge location instead of
every byte travelling to `us-west1`. Google Cloud CDN is enabled by putting a Google "global
external Application Load Balancer" (a worldwide anycast HTTP/HTTPS front door) in front of the
VM and turning caching on. "Anycast" means a single IP address is announced from many Google
edge locations at once, so clients reach the closest one.

After this ExecPlan, the Pulumi stack can stand up that whole standing capability — a global
anycast IP, a backend that points at `nagare-01`, a health check, a CDN-enabled backend
service, a URL map (the routing table that maps incoming hostnames/paths to backends), a
Google-managed TLS certificate, HTTP and HTTPS front-end proxies and forwarding rules, and the
firewall allowances Google's load balancer needs — all behind a single opt-in configuration
flag `nagare:enableCdn` (default `false`, so nothing changes for existing deployments and the
load balancer, which costs money, is never created implicitly). The capability surfaces three
new stack outputs — `cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap` — that a later plan
(`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`, "EP-58") reads to
wire per-site DNS and per-path cache rules at deploy time.

You can see it working without the VM even being powered on: with `nagare:enableCdn` set to
`true`, `pulumi -C infra/pulumi preview` lists the new load-balancer resources in its plan, and
with the flag `false` (or unset) the preview shows none of them. Applying the stack (`pulumi up`)
creates the resources and makes the three new outputs readable with
`pulumi -C infra/pulumi stack output cdnGlobalIp`. End-to-end caching can only be proven once
`nagare-01` is powered back on (it is currently OFF to save cost), so the live `curl`-through-
the-load-balancer check is recorded here as a deferred, environment-gated acceptance, exactly
as sibling plans `docs/plans/43-*.md` and `docs/plans/49-*.md` recorded their VM-required legs.

This plan delivers the STANDING Google Cloud CDN infrastructure only. The PER-SITE and
PER-PATH cache rules are deliberately NOT created by `pulumi up`; EP-58 applies them at deploy
time with `gcloud compute backend-services update` and URL-map path matchers. This division is
a hard contract recorded in the MasterPlan Decision Log and restated in this plan's Decision
Log; the URL map and backend service built here are shaped so EP-58 can layer on top of them.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Add the `nagare:enableCdn` config flag and a `NagareCdn` component
      (`infra/pulumi/src/components/NagareCdn.ts`) creating the global IP, unmanaged instance
      group, health check, CDN backend service, URL map, managed cert, HTTP/HTTPS proxies, and
      forwarding rules; instantiate it from `NagarePerimeter` only when the flag is set and the
      VM exists (else a `"(cdn disabled)"` sentinel output).
- [x] Milestone 1 — Add the load-balancer health-check firewall rule
      (`130.211.0.0/22`, `35.191.0.0/16`) to `NagareNetwork` (`nagare-network-fw-lb-health`,
      ungated).
- [x] Milestone 1 — Bubble `cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap` through
      `NagarePerimeter`, export them from `index.ts`, and add them to `StackOutputs` in
      `infra/pulumi/src/outputs.ts`.
- [x] Milestone 1 — `cd infra/pulumi && npm run build` (`tsc --noEmit`) passes; `pulumi preview`
      shows **13 resources to create** with the flag `true` (the full `nagare:cdn:NagareCdn`
      component + the firewall) and, with the flag `false`, **only** the ungated
      `nagare-network-fw-lb-health` firewall. Transcript captured in Surprises & Discoveries.
- [ ] Milestone 2 (DEFERRED — billable + VM-off, operator-gated) — `pulumi up` creates a billable
      global external Application Load Balancer; the default flag is off and the operator has not
      opted in, so apply is left to the operator. The `gcloud` resource verification and the
      `stack output` reads run after that apply.
- [ ] Milestone 2 (DEFERRED, VM-off) — once `nagare-01` is powered on, run the
      `curl`-through-the-load-balancer acceptance and record the result.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `pulumi preview` ran fully offline (file-backed state + ambient ADC), so Milestone 1's
  acceptance is the real plan diff, not just `tsc`. The VM being powered OFF does not matter:
  `preview` is a plan-only diff.

- A `gcp.compute.BackendService` with `enableCdn: true` and a `cdnPolicy` block **requires**
  either `cdnPolicy.cacheKeyPolicy` or `cdnPolicy.signedUrlCacheMaxAgeSec` — the first preview
  failed with `Missing required argument "cdn_policy.0.cache_key_policy"`. Resolved by adding an
  explicit `cacheKeyPolicy { includeHost, includeProtocol, includeQueryString }`, which is also
  exactly what EP-54's cache-key decision wants (the key must include the host so multiple
  CDN-fronted hostnames sharing the one backend do not collide in the edge cache).

- Flag-gating transcript. With `nagare:enableCdn true`, `pulumi preview` plans **13 to create**:

  ```text
   +  nagare:cdn:NagareCdn          nagare-cdn               create
   +  gcp:compute:GlobalAddress     nagare-cdn-ip            create
   +  gcp:compute:HealthCheck       nagare-cdn-hc            create
   +  gcp:compute:InstanceGroup     nagare-cdn-ig            create
   +  gcp:compute:BackendService    nagare-cdn-backend       create
   +  gcp:compute:URLMap            nagare-cdn-urlmap        create
   +  gcp:compute:URLMap            nagare-cdn-redirect      create
   +  gcp:compute:ManagedSslCertificate nagare-cdn-cert      create
   +  gcp:compute:TargetHttpsProxy  nagare-cdn-https-proxy   create
   +  gcp:compute:TargetHttpProxy   nagare-cdn-http-proxy    create
   +  gcp:compute:GlobalForwardingRule nagare-cdn-fr-https   create
   +  gcp:compute:GlobalForwardingRule nagare-cdn-fr-http    create
   +  gcp:compute:Firewall          nagare-network-fw-lb-health create
  Outputs:
   +  cdnBackendService : "nagare-cdn-backend-8138a50"
   +  cdnUrlMap         : "nagare-cdn-urlmap-02b62b3"
  Resources: + 13 to create
  ```

  With `nagare:enableCdn false`, the preview plans **only** the ungated
  `nagare-network-fw-lb-health` firewall (`+ 1 to create`) and **none** of the `nagare:cdn:*`
  resources — proving the flag gates the whole capability. The flag was removed from
  `Pulumi.dev.yaml` afterward, so the committed default stays off.

- An unrelated pending diff on `gcp:compute:Instance nagare-01`
  (`+allowStoppingForUpdate ~bootDisk`) appears in the preview regardless of the CDN flag; it is
  pre-existing state-vs-code drift from a prior infra commit, not introduced by this plan.

## Decision Log

Record every decision made while working on the plan.

- Decision: CDN provisioning is opt-in behind a Pulumi config flag `nagare:enableCdn`
  (default `false`); the entire `NagareCdn` component is instantiated only when the flag is set.
  Rationale: a global external Application Load Balancer is a billable resource (forwarding
  rules and data processing carry an hourly/throughput charge). Existing `pulumi up` runs must
  stay byte-for-byte unchanged until an operator deliberately opts in, mirroring how this repo
  already defers cost-incurring resources (the VM itself is omitted until `nagareImageSelfLink`
  is set, see `infra/pulumi/src/components/NagarePerimeter.ts`). An additive, gated component is
  non-destructive and previewable.
  Date: 2026-06-10

- Decision: the backend is an UNMANAGED zonal instance group containing the single VM
  `nagare-01`, not a managed instance group (MIG) with autoscaling.
  Rationale: Nagare is a single-node PaaS — there is exactly one origin and no horizontal
  scaling. A MIG exists to template and autoscale identical VMs from an instance template; that
  is the wrong model for a hand-built, stateful, single box with an attached data disk and a
  reserved static IP. An unmanaged instance group lets a load-balancer backend service point at
  an already-existing, individually-managed VM, which is exactly the topology
  `docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md` ("EP-54") validates.
  Date: 2026-06-10

- Decision: STANDING infrastructure (the load balancer, anycast IP, backend service, the
  DEFAULT cache policy, the managed certificate, the firewall allowances) lives here in Pulumi;
  PER-SITE and PER-PATH cache rules are applied at DEPLOY time by EP-58 via
  `gcloud compute backend-services update` and URL-map path matchers, NOT by `pulumi up`.
  Rationale: sites come and go on every deploy, while the load balancer is a long-lived
  singleton. Encoding per-site cache rules in Pulumi would couple the singleton's state to every
  deploy and force a `pulumi up` per site. This split is the MasterPlan's Integration Point 2
  contract; the URL map's default service and the backend service are therefore shaped so EP-58
  can add path matchers and update cache settings imperatively on top of them.
  Date: 2026-06-10

- Decision: the health check is an HTTP check on the backend port targeting Kourier's
  readiness path, as fixed by EP-54.
  Rationale: the load balancer must only send traffic to a healthy origin. Kourier (the Knative
  ingress Envoy) answers HTTP on the backend port; EP-54 validates the exact path and port that
  return success without depending on any particular app being deployed (the spike confirms the
  ingress answers an unauthenticated liveness path). This plan uses whatever path/port EP-54
  recorded; if EP-54 is not yet complete when this plan is implemented, the implementer reads
  EP-54's Decision Log for the confirmed value before hard-coding it here.
  Date: 2026-06-10

- Decision: the backend service preserves the original `Host` header so Knative still routes by
  hostname, per EP-54.
  Rationale: Knative Serving routes requests to the correct Knative Service by inspecting the
  HTTP `Host` header; if the load balancer rewrote `Host` to the backend's address, Knative
  would not find the route and would return a 404. EP-54 validates the host-header / custom-
  request-header handling (preserving the incoming `Host`, and where needed setting a custom
  request header) that keeps Knative routing intact through the load balancer.
  Date: 2026-06-10

- Decision: client-facing TLS is terminated at the edge with a Google-managed certificate; the
  origin-TLS mode (whether the load balancer talks to the VM over HTTP or HTTPS) follows EP-54.
  Rationale: a Google-managed certificate removes manual certificate rotation. EP-54 records
  whether a single-hostname `gcp.compute.ManagedSslCertificate` or a wildcard certificate via
  Certificate Manager (`gcp.certificatemanager.*`) is required, and whether the backend protocol
  is HTTP or HTTPS against the origin. This plan implements the mode EP-54 selected; until a real
  `baseDomain` is delegated, certificate provisioning may stay in a pending/deferred state, which
  is expected and recorded under Idempotence and Recovery.
  Date: 2026-06-10

- Decision: all resources target GCP project `tan-nb-exp`, region `us-west1`, zone
  `us-west1-a`, and nothing else — read or write.
  Rationale: the repo-root `CLAUDE.md` mandates strict project isolation: no script, command, or
  instruction in this repository may target any other GCP project, including read operations.
  The Pulumi stack already pins these via `infra/pulumi/Pulumi.dev.yaml`; every `gcloud` check in
  this plan passes `--project=tan-nb-exp` explicitly as defense in depth.
  Date: 2026-06-10

- Decision (implementation): the backend-service origin protocol is **HTTP** (port-name `http`)
  for now, matching the platform's HTTP-first origin; the health check is HTTP on port 80.
  Rationale: HTTPS is currently deferred on the origin (no delegated `baseDomain`, so cert-manager
  cannot complete the DNS-01 challenge — see EP-4). EP-54's steady-state proposal is an HTTPS
  origin hop once origin TLS is enabled; flipping `protocol`/`portName`/the health-check port to
  HTTPS is a one-line change tied to that enablement. Encoding HTTP now keeps the standing infra
  working against the real current origin instead of a not-yet-existing HTTPS endpoint.
  Date: 2026-06-10

- Decision (implementation): edge TLS uses a single-hostname `gcp.compute.ManagedSslCertificate`
  with `managed.domains = [baseDomain]`, not Certificate Manager.
  Rationale: EP-54 offers both the single-hostname `ManagedSslCertificate` path and a wildcard
  Certificate Manager path. The simpler single-hostname path keeps Milestone 1 to one cert
  resource and is sufficient for the standing capability; the cert sits in `PROVISIONING` until
  `baseDomain` is delegated and a hostname resolves to the anycast IP (expected, non-blocking).
  For multiple CDN hostnames or a wildcard, migrate to `gcp.certificatemanager.*` — recorded as a
  follow-up the operator/EP-58 picks up when real hostnames exist.
  Date: 2026-06-10

- Decision (implementation): `cdnPolicy.cacheKeyPolicy` includes host, protocol, and query string.
  Rationale: forced by the provider (a `cdnPolicy` requires a cache-key policy or signed-URL TTL)
  and required for correctness — the one backend service fronts every CDN hostname, so the cache
  key must include the host to avoid cross-host cache collisions, exactly EP-54's cache-key
  decision.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Milestone 1 complete (2026-06-10).** The standing Google Cloud CDN capability is implemented as
the `NagareCdn` component (`infra/pulumi/src/components/NagareCdn.ts`) and wired through
`NagarePerimeter` behind the opt-in `nagare:enableCdn` flag (default off; the disabled state
yields a `"(cdn disabled)"` sentinel for the three outputs). `NagareNetwork` gained the ungated
Google health-check firewall rule. The three Integration-Point-2 outputs `cdnGlobalIp`,
`cdnBackendService`, `cdnUrlMap` flow through `index.ts` and `StackOutputs`. `tsc --noEmit` passes
and `pulumi preview` validates the gating (13 resources on, only the firewall off) — acceptance is
the real plan diff, captured in Surprises. The contract EP-58 consumes (output names, the
`gcloud`-targetable backend service and URL map, the anycast IP for per-hostname DNS) is in place.

**Deferred / gaps.** Milestone 2 (`pulumi up` + live `gcloud`/`curl`) is intentionally NOT run: a
global external Application Load Balancer is billable and the default flag is off, so applying is
an operator decision; the end-to-end cache `curl` additionally needs `nagare-01` powered on. Both
are recorded as deferred, matching EP-43/EP-49. Two values inherit EP-54's *proposed* (not yet
live-confirmed) decisions and will be confirmed/tuned when the VM is on: the health-check
host/path that returns HEALTHY through Kourier (the standing probe uses `host = baseDomain`,
`path = /`, which Kourier answers 404 for an unmatched host — so the backend may read UNHEALTHY
until EP-58 points the probe at a deployed host), and the eventual HTTPS origin hop. Neither blocks
the standing infra or EP-58.

