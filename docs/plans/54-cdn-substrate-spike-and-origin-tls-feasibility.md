---
id: 54
slug: cdn-substrate-spike-and-origin-tls-feasibility
title: "CDN substrate spike and origin-TLS feasibility"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:37:02Z
      mode: "update"
      note: "Reconcile deferred origin reachability against tan-ng-labs"
---

# CDN substrate spike and origin-TLS feasibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [54-cdn-substrate-spike-and-origin-tls-feasibility.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today, Nagare — a single-node personal Platform-as-a-Service (PaaS) running on one
Google Cloud virtual machine named `nagare-01` — serves every app directly from that
one VM. A visitor in Tokyo and a visitor in New York both reach the same machine in
`us-west1` (Oregon), and every byte of every response travels the whole way every time.
A **Content Delivery Network (CDN)** is a globally distributed cache that sits *in front
of* an origin server: it answers requests from a cache at an edge location near the
visitor, and only forwards to the origin (`nagare-01`) when it has nothing cached. The
parent initiative, MasterPlan 11 (`docs/masterplans/11-cdn-integration-for-nagare.md`),
adds first-class CDN support to Nagare with two interchangeable backends — **Google Cloud
CDN** (a Google global HTTP(S) load balancer with caching enabled, provisioned through
Pulumi) and **Cloudflare** (a third-party reverse proxy in front of the VM's public IP,
configured through Cloudflare's HTTP API).

This plan, **EP-54**, is the **substrate spike** for that initiative: a throwaway,
hand-run, de-risking experiment, not production code. "Spike" here means exactly what it
meant in this repository's two most recent spikes — the managed-database spike
(`docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`)
and the scheduled-task spike
(`docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md`): you stand
up a *minimal* version of the thing by hand on the live cluster, prove the cloud actually
accepts it, and then write the verified facts and decisions into *this file* so the later
plans encode a *proven* shape instead of a guess. EP-54 stands up a minimal Google Cloud
CDN load balancer **and** a minimal Cloudflare proxy in front of `nagare-01`, and proves,
for each: that the edge can route to the in-cluster origin (Kourier, Knative's ingress
gateway) while preserving the **Host header** Knative needs to pick the right app; that
edge TLS and origin TLS work; and that a **cache HIT** actually occurs on a static asset.

What someone "gains" after EP-54 is not a clickable feature — it is **a settled set of
substrate decisions and a body of validation evidence**. Four later plans consume those
decisions directly, and none of them is allowed to encode a guess about what the cloud
will accept. EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`) defines the
shared typed `Cdn` model in Haskell, and needs this spike to confirm that the proposed
contract shape is sufficient and provider-portable. EP-56
(`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`) builds the Google
Cloud CDN load balancer in Pulumi, and needs this spike's exact load-balancer topology,
health-check path, host-header handling, and the standing-infra-vs-deploy-time split. EP-57
(`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`) builds the Cloudflare
API client in `nagarectl`, and needs this spike's chosen default origin-TLS mode and the
resolution of the DNS-authority collision (described below). EP-58
(`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`) wires it all
into the deploy engine, and needs the per-hostname DNS topology this spike validates. You
can see the spike "working" by reading the captured `curl` transcripts in Concrete Steps:
a response routed through each edge to the correct in-cluster app, and a second identical
request that the edge serves from cache (`CF-Cache-Status: HIT` for Cloudflare, a growing
`Age:` header and `cache result=HIT` for Google).

This plan touches **no Haskell and no TypeScript production code**. Its only durable,
committed artifacts are this document and a throwaway example directory
(`cluster/examples/cdn-spike/`) holding the reusable `gcloud`/Cloudflare scripts and a
README, following the same spike-example convention as `cluster/examples/db-spike/`.
Everything provisioned in the cloud (a global IP, a load balancer, a Cloudflare DNS
record) is torn down by the teardown commands recorded below.

**Powered-off caveat (read this first).** The VM `nagare-01` is **currently `TERMINATED`
(powered off) to save cost**, and standing up a Google load balancer or proxying a real
hostname through Cloudflare both require the origin to be reachable. Therefore the
**live validation legs** of Milestones 1 and 2 are explicitly **deferred / manual**: this
plan delivers the exact commands, scripts, and decisions *now*, but the live `curl`
transcripts can only be captured once an operator starts the VM (and, for Cloudflare,
provides a real domain and a scoped API token). This mirrors exactly how EP-43 and EP-49
handled the same powered-off constraint: the commands and the proposed decisions are the
deliverable; the live transcripts are filled in when the box is up. Every live step below
states plainly what to run and what output to expect so the validation is mechanical when
the time comes.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Authored the plan: ground-truth context, the Google Cloud CDN command sequence
  (M1), the Cloudflare command sequence (M2), the substrate decisions (M3), and the
  `cluster/examples/cdn-spike/` artifact layout. Live legs marked deferred (VM is off).
- [x] Created and syntax-validated the `cluster/examples/cdn-spike/` artifacts:
  `README.md`, `gcp-cdn-up.sh`/`gcp-cdn-down.sh` (project-preflighted, idempotent,
  reverse-order teardown), and `cf-cdn-up.sh`/`cf-cdn-down.sh` (reading
  `CF_API_TOKEN`/`CF_ZONE_ID`/`CF_HOST`/`ORIGIN_IP`). `bash -n` passes on all four;
  the project preflight and the required-env guards were verified to fire before any
  cloud or API call (a wrong `CLOUDSDK_CORE_PROJECT` is refused; a missing `HC_HOST`
  / `CF_API_TOKEN` aborts).
- [x] M0 live origin reachability: the labs stack output reports public IP `8.235.22.170`, and
  `curl -H 'Host: hello.personal.labs.topagentnetwork.net' http://8.235.22.170/` returned
  `HTTP/1.1 200 OK` with body `Hello Nagare!` through Kourier. (2026-09-15)
- [ ] M1 (deferred — needs VM up): stand up the throwaway Google Cloud CDN load balancer
  (instance group, health check, CDN backend service, URL map, target proxy, forwarding
  rule, global IP, managed cert); capture the routed-response and cache-HIT `curl`
  transcripts; tear down.
- [ ] M2 (deferred — needs VM up + a real domain + a CF API token): add a proxied
  (orange-cloud) Cloudflare DNS record and a cache rule via the API; capture the
  `CF-Cache-Status: HIT` transcript; determine the working origin-TLS mode; tear down.
- [ ] M3 (partially done — proposals recorded, confirmation deferred): finalize the
  Substrate Decisions subsection from the M1/M2 evidence; confirm or amend the typed `Cdn`
  contract back to EP-55.
- [x] Commit the plan and the `cluster/examples/cdn-spike/` artifacts with the mandated
  trailers (committed directly to the current branch; spike touches no Haskell/TypeScript
  production code).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Live M0 evidence (2026-09-15): the independent labs target at `mori://tan/tan-ng-labs`
  removes the old powered-off-origin blocker. Pulumi reports `publicIp=8.235.22.170`; direct HTTP
  to that address with the Knative host header returns 200 and `Hello Nagare!`. This proves the
  reusable origin-routing prerequisite only. It does not create a Google load balancer, call the
  Cloudflare API, or establish either cache-HIT/TLS topology.

## Decision Log

Record every decision made while working on the plan. The first three entries below are
**proposals the live spike will confirm** (the VM is currently off — see Purpose); the
remaining entries record settled scoping decisions for how the spike itself is run. Every
proposal names the later plan that consumes it.

- Decision (scoping): Lead MasterPlan 11 with a hand-run substrate spike (this plan) before
  any typed model or provider code is written.
  Rationale: CDN-in-front-of-Knative is unproven on this box. A Google global load balancer
  must health-check and route to Kourier while preserving the `Host` header Knative routes
  by, and a Cloudflare proxy must front a wildcard origin while the origin still presents a
  valid TLS certificate. These are cloud-topology unknowns of exactly the kind this
  repository has repeatedly de-risked with a spike before committing a typed contract and
  infrastructure (EP-33 Knative-PVC, EP-43 managed-database, EP-49 scheduled-task). The
  ExecPlan specification explicitly encourages an isolated prototyping spike to de-risk
  significant unknowns. Skipping it would let EP-55/EP-56/EP-57 bake in assumptions the
  cloud rejects.
  Date: 2026-06-10

- Decision (PROPOSAL, to be CONFIRMED by M2; consumed by EP-57/EP-58): the **default
  Cloudflare origin-TLS mode is `Full (strict)`**, reached in two steps — start at
  `Flexible` for the very first HTTP-only bring-up, then move to `Full (strict)` as the
  steady state once the origin serves the Let's Encrypt wildcard on port 443.
  Rationale: Cloudflare's SSL/TLS "encryption mode" governs how the Cloudflare edge talks to
  the origin. `Flexible` means the edge serves HTTPS to the browser but connects to the
  origin over **plaintext HTTP on port 80** — it works immediately against Nagare's current
  HTTP-first origin (HTTPS is deferred until a real `baseDomain` is delegated; see
  `docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`), but it leaves the
  Cloudflare→origin hop unencrypted across the public internet, which is unacceptable as a
  durable default. `Full` encrypts that hop but does not verify the origin certificate;
  `Full (strict)` encrypts *and* verifies it. Because Nagare's origin can present a real,
  publicly-trusted Let's Encrypt wildcard once TLS is enabled (one config flip, see Context),
  `Full (strict)` is achievable and is the correct steady-state default. EP-57's
  `OriginTlsMode` type therefore needs at least `Flexible | Full | FullStrict`, and EP-58
  passes `FullStrict` as the deploy-time default once origin TLS is on.
  Date: 2026-06-10

- Decision (PROPOSAL, to be CONFIRMED by M1; consumed by EP-56): for **Google Cloud CDN**,
  the edge terminates client TLS with a **Google-managed certificate** and connects to the
  origin over **HTTPS on port 443** (backend-service protocol `HTTPS`), with the load
  balancer's health check probing Kourier over HTTPS once origin TLS is on (and over HTTP on
  port 80 during the HTTP-first interim). The single VM lives in an **unmanaged zonal
  instance group** with named ports `http:80` and `https:443`, and the backend service
  forwards the original `Host` header unchanged so Knative still routes.
  Rationale: a Google managed cert removes cert renewal from the operator for the edge; an
  HTTPS origin hop matches the Cloudflare `Full (strict)` posture and keeps the origin leg
  encrypted. EP-56 implements exactly this topology.
  Date: 2026-06-10

- Decision (PROPOSAL, to be CONFIRMED by M2; consumed by EP-57/EP-58): resolve the
  **DNS-authority collision** — that proxying a hostname through Cloudflare requires the
  zone's authoritative DNS to live at Cloudflare, which then prevents cert-manager's Cloud
  DNS DNS-01 ACME challenge from writing `_acme-challenge` TXT records — by **moving
  cert-manager's DNS-01 solver to a Cloudflare API-token solver** for Cloudflare-fronted
  hostnames (option (b) below).
  Rationale: three options exist. (a) **CNAME delegation**: keep certificate issuance on
  Cloud DNS by adding, in the Cloudflare zone, a CNAME `_acme-challenge.<host>` →
  `<host>.<cloud-dns-zone>` and letting cert-manager solve in Cloud DNS; this keeps the
  existing solver but adds a fragile per-hostname delegation record. (b) **Cloudflare token
  solver**: add a second cert-manager `ClusterIssuer` whose DNS-01 solver uses a Cloudflare
  API token, so certificates for Cloudflare-hosted zones are validated where the zone now
  lives. (c) **Cloudflare Origin CA**: stop using Let's Encrypt for Cloudflare-fronted
  hostnames entirely and install a Cloudflare-issued Origin CA certificate on the origin,
  paired with `Full (strict)`; this is operationally simplest but ties the origin cert to
  Cloudflare and is not publicly trusted outside Cloudflare's edge. Option (b) is
  recommended because it keeps publicly-trusted Let's Encrypt certs (so the origin remains
  directly reachable and valid even if Cloudflare is bypassed), avoids a per-hostname
  delegation record, and is a single additional `ClusterIssuer` — a self-contained,
  reviewable change. EP-57 records the chosen mechanism; EP-59 documents the runbook.
  Note: a zone's authority is all-or-nothing — Cloudflare's proxy *requires* CF-hosted DNS,
  so "keep the zone on Cloud DNS and proxy only some records" is **not possible**, which is
  why one of (a)/(b)/(c) must be chosen.
  Date: 2026-06-10

- Decision (PROPOSAL, to be CONFIRMED by M1; consumed by EP-56/EP-58): split CDN
  responsibilities so **standing infrastructure** (the load balancer, the global anycast IP,
  the backend service, the URL map, and the managed certificate) lives in **Pulumi**, while
  **per-site / per-path cache rules** are applied **at deploy time** via
  `gcloud compute backend-services update` and URL-map path matchers (and, for Cloudflare,
  via the API).
  Rationale: the load balancer and IP are long-lived stack-level resources that rarely
  change and belong in declarative IaC; cache TTLs and per-path rules are per-site and change
  every time a developer edits their config, so applying them at deploy time keeps the typed
  config the single source of truth without a `pulumi up` per site. The spike confirms a
  per-path cache rule can be added to an existing backend service / URL map by `gcloud`
  without recreating the load balancer (the EP-56/EP-58 dependency).
  Date: 2026-06-10

- Decision (scoping): run every cloud operation against **only** GCP project `tan-nb-exp`
  with an explicit `--project=tan-nb-exp` flag and the repo's preflight assertion, and run
  every in-cluster check **on the VM via `sudo k3s kubectl`** through the IAP SSH wrapper —
  never the workstation's default kubectl context.
  Rationale: the repository-root `CLAUDE.md` mandates `tan-nb-exp`-only operation, and the
  project memory note records that IAP forwards only SSH/22 (so a workstation `kubectl`
  cannot reach the k3s API) and that the workstation's default context points at an unrelated
  GKE cluster that must never be touched. This matches EP-43 and EP-49.
  Date: 2026-06-10

- Decision (scoping): keep all reusable spike artifacts under `cluster/examples/cdn-spike/`
  (a README plus `gcloud` and Cloudflare scripts), named and styled like
  `cluster/examples/db-spike/`, and make every script idempotent and accompanied by an
  explicit teardown.
  Rationale: the spike must be fully reversible and re-runnable; a real anycast IP and a real
  Cloudflare record are billable / externally visible, so teardown is mandatory and the
  scripts must be safe to re-run. Mirrors EP-43's `db-spike` example convention.
  Date: 2026-06-10

- Decision: accept labs as M0 evidence but keep M1–M3 open.
  Rationale: M0 asks only whether the public VM address reaches Kourier and Knative when the Host
  header is preserved, which labs proves exactly. M1 and M2 require distinct provider resources,
  cache HITs, TLS behavior, and teardown; none can be inferred from origin reachability alone.
  Date: 2026-09-15

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Artifacts delivered (2026-06-10).** The committed deliverable of this spike is complete:
this document (the command sequences, expected transcripts, and Substrate Decisions) plus the
reusable `cluster/examples/cdn-spike/` scripts. The scripts encode the exact provider topologies
the later plans build: `gcp-cdn-up.sh` is the hand-run analogue of EP-56's Pulumi `NagareCdn`
component (instance group → health check → CDN backend → URL map → proxy → global IP →
forwarding rule), and `cf-cdn-up.sh`'s three API calls are the verified shapes of EP-57's
`upsertProxiedRecord` / `setOriginTlsMode` / `applyCacheRules`. Every `gcloud` call is pinned to
`--project=tan-nb-exp` behind the repo preflight; both `up` scripts are idempotent and paired
with `--quiet`, missing-object-tolerant teardown.

**Deferred (live evidence).** M0 is now captured against the running labs origin: the Pulumi IP plus
the correct Host header routes through Kourier to the known app with HTTP 200. M1–M2 remain
uncaptured: no Google CDN load balancer or Cloudflare proxy/cache rule was created, so the
`age:`/`cf-cache-status` cache HITs, working origin-TLS mode, and Google-managed-cert transition are
**not yet proven**. The Substrate Decisions subsection
records them as the proposals the live spike confirms; an operator runs the scripts and fills in
the transcripts when the VM is started (and, for Cloudflare, a domain + `CF_API_TOKEN` are
supplied). This matches how EP-43 and EP-49 closed under the same powered-off constraint: the
command sequences and proposed decisions are the deliverable; the transcripts are mechanical to
capture later.

**Contract recommendation to EP-55 (unchanged).** The proposed typed `Cdn` contract
(`provider`, `defaultTtlSeconds`, `cacheStaticAssets`, `cacheRules` of
`(pathPrefix, Maybe edgeTtlSeconds)`) maps cleanly onto both providers (see Substrate Decisions),
so EP-55 should implement it as proposed, keeping origin-TLS mode **out** of the typed model as a
deploy-time default (`Full (strict)` for Cloudflare). The one item EP-55 must settle is confirming
that decision; no model amendment is required by the spike.

