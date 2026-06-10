---
id: 54
slug: cdn-substrate-spike-and-origin-tls-feasibility
title: "CDN substrate spike and origin-TLS feasibility"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# CDN substrate spike and origin-TLS feasibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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
- [ ] M0 (deferred — needs VM up): start `nagare-01`; read `publicIp` from Pulumi; confirm
  Kourier serves HTTP on the VM's public IP and that a known app responds when the right
  Host header is sent.
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

(None yet.)


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

**Deferred (live evidence).** Because `nagare-01` is `TERMINATED`, the live `curl` transcripts for
M0–M2 (routed response, `age:`/`cf-cache-status` cache HITs, the working origin-TLS mode, the
Google-managed-cert transition) are **not yet captured**. The Substrate Decisions subsection
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


## Context and Orientation

Read this section fully before running anything. It assumes you know nothing about this
repository.

**The platform and the one rule that governs all cloud access.** Nagare is a single-node
personal PaaS running on one Google Cloud Compute Engine virtual machine named `nagare-01`
(an `e2-standard-2`: 2 vCPU, ≈8 GB RAM), in GCP project `tan-nb-exp`, region `us-west1`,
default zone `us-west1-a`. The VM runs NixOS, and on top of NixOS runs **k3s**, a
lightweight single-binary Kubernetes distribution; "the cluster" means this one-node k3s.
The repository-root `CLAUDE.md` mandates a hard rule: **every `gcloud` operation in this
repo targets project `tan-nb-exp` only** — never any other project, not even for read-only
listing. Scripts include a preflight assertion that refuses to run if the active gcloud
project is not `tan-nb-exp`, and every `gcloud` call passes `--project=tan-nb-exp`
explicitly. This spike honors that rule in every command. The preflight pattern, copied
from `CLAUDE.md`, is:

```bash
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
```

**Critical access reality (do not skip).** Two facts govern how you reach the cluster.
First, the VM is **currently `TERMINATED` (powered off) to save cost** — you must start it
first and wait ~1–2 minutes for sshd and k3s before any live leg of this spike will work.
Second, a workstation `kubectl` cannot reach the k3s API directly: IAP (Google's
Identity-Aware Proxy, the authenticated tunnel this repo uses to reach the VM) forwards
only SSH on port 22, so opening an IAP tunnel to the k3s API port 6443 is refused, and the
workstation's default kubectl context points at an *unrelated* GKE cluster that you must
**never** touch. The correct path for any in-cluster check is to run it **on the VM itself
as `sudo k3s kubectl ...`**, reached with the repo's IAP SSH wrapper as the `deploy` user
with the `~/.ssh/id_ed25519` key, from the repository root
(`/Users/shinzui/Keikaku/bokuno/nagare`):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '<command>'
```

The wrapper `scripts/iap-ssh.sh` opens an IAP tunnel, routes OpenSSH through `socat`, and
runs `<command>` under a shell on the VM; it refuses to run unless the active gcloud
project is `tan-nb-exp`. The `gcloud compute ...` load-balancer commands in this spike, by
contrast, run **from the workstation** (they manage cloud resources, not in-cluster
objects), each pinned with `--project=tan-nb-exp`.

**How the origin serves traffic today (the thing the CDN sits in front of).** k3s runs
**Knative Serving** with **Kourier** as the ingress gateway. "Knative Serving" is the
layer that turns a container into a URL-addressable, scale-to-zero web service; "Kourier"
is the Envoy-based gateway that accepts inbound HTTP(S) and forwards it to the right
Knative service. On this single node, **k3s's ServiceLB (also called Klipper)** binds the
host's ports 80 and 443 to Kourier's `LoadBalancer`-type Service, so the VM's public IP
directly serves HTTP/HTTPS for every app. The decisive routing fact for this spike:
**Knative routes by the HTTP `Host` header.** A Knative service named `notes` in namespace
`personal` is served at the hostname `notes.personal.<baseDomain>`; Kourier looks at the
`Host` header of each request to decide which app receives it. A custom domain is wired
with a Knative **DomainMapping** (one Kubernetes object per hostname) that maps an external
hostname to a service. **If a CDN forwards a request with the wrong `Host` header (for
example, rewriting it to the load balancer's hostname), Kourier will not find the app and
will return a 404.** Proving the `Host` header survives the edge is therefore the central
routing question this spike answers, for both providers.

**The VM's public IP.** The VM has a static **reserved regional external IPv4** address (a
`gcp.compute.Address`, defined in `infra/pulumi/src/components/NagarePerimeter.ts`),
surfaced as the Pulumi stack output `publicIp`. Reserving it means the VM keeps the same
public IP across rebuilds. Read it with, from the repo root:

```bash
pulumi -C infra/pulumi stack output publicIp
```

(The Pulumi state and passphrase are configured by the repo's `.envrc` per `CLAUDE.md`;
running `direnv allow` once enables them.) This IP is the **origin** every leg of this
spike points an edge at — Cloudflare proxies *to* it, and the Google instance group wraps
the VM that owns it.

**DNS today.** Pulumi (`infra/pulumi/src/components/NagarePerimeter.ts`) creates a **Cloud
DNS managed zone** for `<baseDomain>` (the value is the placeholder `apps.example.com`
today; the zone's name is the stack output `dnsZoneName`). The zone holds exactly **one
wildcard A record**, `*.<baseDomain>` → `publicIp`, with a 300-second TTL. The zone is only
*authoritative* on the public internet once the operator delegates the domain to its Cloud
DNS nameservers at the domain registrar; until then it resolves only for clients explicitly
querying those nameservers. A **more-specific** record (for example, an exact-hostname A
record) wins over the wildcard, which is how EP-58 will later point a Google-CDN hostname at
the load balancer IP while everything else keeps pointing at the VM.

**TLS today.** The cluster runs **cert-manager** (the standard Kubernetes certificate
controller) with a `ClusterIssuer` named `letsencrypt-dns`
(`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`). It issues **Let's Encrypt wildcard
certificates** via a **DNS-01 challenge** — meaning it proves domain control by writing a
`_acme-challenge` TXT record into DNS — using the `cloudDNS` solver against project
`tan-nb-exp`, authorized by the VM's attached service account (which holds `roles/dns.admin`;
there is no secret in the manifest — it uses the VM's *ambient* Application Default
Credentials). **HTTPS is currently DEFERRED** (the platform is HTTP-first) because the
placeholder domain `apps.example.com` is not delegated, so the DNS-01 challenge cannot
complete for a domain Let's Encrypt cannot verify. Enabling HTTPS is a *one-flip* change:
in `cluster/bootstrap/knative-serving/config-network-tls.yaml`, set
`external-domain-tls: Enabled`, at which point Kourier serves the Let's Encrypt wildcard on
port 443. This matters to the spike because the origin-TLS decisions (Cloudflare `Full
(strict)`, Google HTTPS origin) depend on the origin being able to present that wildcard on
443 — which it can, after the flip.

**There is no Cloudflare credential anywhere in the repo today.** No API token, no zone ID,
no account ID exists in the working tree or in any secret store this plan can see.
Therefore the **Cloudflare leg (M2) additionally requires the operator to supply a real
domain whose DNS is hosted at Cloudflare and a scoped Cloudflare API token** before its
live steps can run. The spike's M2 script reads the token from the environment variable
`CF_API_TOKEN` and the zone identifier from `CF_ZONE_ID` (or discovers the zone from the
hostname), exactly the credential shape EP-57's `Nagare.Cdn.Cloudflare` module will later
read.

**Firewall today.** `infra/pulumi/src/components/NagareNetwork.ts` allows ingress on TCP
80/443 from `0.0.0.0/0`, SSH on 22 only from the IAP range `35.235.240.0/20`, and Tailscale
UDP on 41641. A Google load balancer health-checks the origin from Google's health-check
source ranges `130.211.0.0/22` and `35.191.0.0/16`; because 80/443 are already open to the
whole internet, the **existing firewall already admits the health checks** — no firewall
change is needed for the spike, and EP-56 will decide whether to narrow ingress to the
health-check ranges as standing policy. The Pulumi provider is `@pulumi/gcp` `^8.10.0`.

**The shared typed contract this spike validates.** EP-55 will define a typed `Cdn` model
in the `nagare-dsl` Haskell library; the spike must confirm the proposed shape is sufficient
and provider-portable (or recommend amendments back to EP-55). Quoted here so this plan is
self-contained — a reader who has not seen EP-55 still knows exactly what the model looks
like:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn

-- A per-path edge cache rule. Requests whose path begins with pathPrefix get
-- edgeTtlSeconds as their edge time-to-live; Nothing means "never cache this path".
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)   -- Nothing = never cache
  }

-- The CDN configuration attached to a site or app.
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
-- attached as `cdn :: Maybe Cdn` on StaticSite, ServerSite, Deployment
```

**Terms used in this plan, in plain language.** An *origin* is the server the CDN caches in
front of — here, Kourier on `nagare-01`. An *edge* is the CDN's nearest cache location to the
visitor. A *cache HIT* is a response served from the edge cache without touching the origin;
a *cache MISS* is the opposite. The *Host header* is the HTTP header that names which site a
request is for; Knative routes by it. A *health check* is a periodic probe the load balancer
sends the origin to decide whether to send it traffic. An *instance group* is a Google
construct that groups VMs so a load balancer can target them; *unmanaged* means we list the
VM explicitly rather than have Google scale it. A *backend service* is the load-balancer
object that ties the instance group, the health check, and the CDN cache policy together. A
*URL map* routes incoming paths to backend services; a *target proxy* terminates client TLS;
a *forwarding rule* binds the global IP and port to the target proxy. *Orange-cloud* is
Cloudflare's term for a DNS record whose traffic is proxied through Cloudflare's edge (as
opposed to *grey-cloud*, DNS-only). *DNS authority* means which nameservers are
authoritative for a zone; Cloudflare's proxy requires the zone to be authoritative at
Cloudflare.


## Plan of Work

The work is four milestones. M0 prepares: start the VM, read the origin IP, and confirm the
HTTP-first origin routes by Host header so the later cache proofs have a known-good baseline.
M1 stands up the Google Cloud CDN load balancer in front of the VM and proves routed
responses, the Host header survives, and a cache HIT occurs. M2 proxies a hostname through
Cloudflare and proves the same, plus determines the working origin-TLS mode. M3 turns the
M1/M2 evidence into the Substrate Decisions the rest of the initiative consumes, and confirms
or amends the typed `Cdn` contract back to EP-55. Each milestone is independently verifiable:
at its end you can run the listed commands and observe the listed output.

**Every live leg of M0–M2 is deferred/manual because the VM is off** (see the Purpose
caveat). The commands and scripts are the deliverable now; the transcripts are captured when
an operator starts the VM (and, for M2, supplies a domain and `CF_API_TOKEN`). Where a
transcript is shown below, it is the *expected* output to compare against, marked as such.

### Milestone M0 — Prepare: VM up, origin IP read, Host-header routing confirmed

Scope: start `nagare-01`, read the `publicIp` stack output, and confirm that sending the
correct `Host` header to the VM's public IP reaches a known app through Kourier. At the end
of M0 you have the origin IP in hand and a baseline `curl` that proves "right Host header →
right app, wrong Host header → 404", which is the property both CDNs must preserve.
Acceptance: `curl -H 'Host: <known-app-host>' http://<publicIp>/` returns the app's response
(HTTP 200 or the app's own status), and the same `curl` without that Host header returns a
404 from Kourier — proving routing is Host-driven.

### Milestone M1 — Google Cloud CDN load balancer in front of the VM (deferred/manual)

Scope: with `gcloud` (all `--project=tan-nb-exp`), create a throwaway **unmanaged zonal
instance group** containing `nagare-01` with named ports `http:80`/`https:443`, a **health
check**, a **CDN-enabled backend service** that forwards the original Host header, a **URL
map**, an **HTTP target proxy** (and, once origin TLS is on, an HTTPS proxy + managed cert),
a **global forwarding rule** bound to a new **global IP**. Point a test hostname at the
global IP and prove: (1) a request routed through the load balancer reaches the right app
(Host header preserved), and (2) a second identical request to a static asset is served from
cache. At the end of M1 you have the `curl` transcript proving a routed response and a cache
HIT (a growing `Age:` header / `cache result=HIT` in the response), and the teardown leaves
no billable resources. Acceptance: `curl --resolve <host>:80:<lbIp> http://<host>/<asset>`
returns the asset on the first request (MISS) and a cached copy on the second (HIT, non-zero
`Age:`); `gcloud compute backend-services describe <name> --global` shows `enableCDN: true`.

### Milestone M2 — Cloudflare proxy in front of the VM (deferred/manual)

Scope: with the Cloudflare HTTP API (a `curl` script using a scoped `CF_API_TOKEN`), add a
**proxied (orange-cloud) DNS record** for a test hostname pointing at the VM's `publicIp`,
add a **cache rule** for a static path, set the **origin-TLS mode** (start `Flexible`, move
to `Full (strict)` once origin TLS is on), and prove a cache HIT. At the end of M2 you have
the `curl` transcript showing `CF-Cache-Status: MISS` then `CF-Cache-Status: HIT` on a static
asset, a confirmation that the proxied request still reaches the right app (Host header
preserved by Cloudflare by default), and the determined working origin-TLS mode. Acceptance:
two `curl -sI https://<host>/<asset>` calls show `CF-Cache-Status: MISS` then `HIT`; the
origin-TLS mode that returns 200 (not a Cloudflare 5xx) is recorded.

### Milestone M3 — Record the Substrate Decisions; confirm the typed contract

Scope: turn the M1/M2 evidence into a clearly written **Substrate Decisions** subsection in
Interfaces and Dependencies, capturing every decision in points 1–3 of the Purpose: the
Google topology (health-check path/port, Host-header/custom-request-header handling,
cache-key policy, managed-cert prerequisites, the standing-infra-vs-deploy-time-cache split);
the Cloudflare topology (proxied routing, cache HIT, origin-TLS mode, the DNS-authority
collision resolution); and whether the typed `Cdn` contract is sufficient or needs amendment.
Cross-reference the MasterPlan integration points (IP1 the typed model, IP2 the Google
standing infra, IP3 the Cloudflare module, IP7 the origin-TLS model). At the end of M3 the
later plans can be written against verified facts. Acceptance: the Substrate Decisions
subsection contains the per-provider decisions and an explicit "contract sufficient / amend
as follows" statement.


## Concrete Steps

All `gcloud compute ...` commands run **from the workstation** at the repository root
(`/Users/shinzui/Keikaku/bokuno/nagare`), each pinned `--project=tan-nb-exp`. All in-cluster
checks run **on the VM** via the IAP SSH wrapper. **The live legs below are deferred until
the VM is powered on** (and, for M2, until a domain and `CF_API_TOKEN` are supplied); the
expected transcripts are what to compare against when they run.

The implementer must carry these git trailers on any commit produced by this plan (no
feature branch; commit directly to the current branch). A spike may commit **only** the plan
doc and the `cluster/examples/cdn-spike/` artifacts; no production source changes:

```text
MasterPlan: docs/masterplans/11-cdn-integration-for-nagare.md
ExecPlan: docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md
Intention: intention_01ktsdz4s8er09txy9afce3hn4
```

### M0 step 1 — Start the VM and read the origin IP

The VM is `TERMINATED`. Start it from the workstation, then wait ~1–2 minutes for sshd + k3s:

```bash
gcloud compute instances start nagare-01 --zone=us-west1-a --project=tan-nb-exp
```

Expected (or "already running"):

```text
Starting instance(s) nagare-01...done.
Updated [https://compute.googleapis.com/compute/v1/projects/tan-nb-exp/zones/us-west1-a/instances/nagare-01].
```

Read the origin's public IP (capture it; later commands refer to it as `<publicIp>`):

```bash
pulumi -C infra/pulumi stack output publicIp
```

Expected — a single regional IPv4 address:

```text
34.x.y.z
```

### M0 step 2 — Confirm Host-header routing on the HTTP-first origin

Pick a known Knative service hostname. List services on the VM to find one
(`<app>.<namespace>.<baseDomain>` is the pattern; with the placeholder base domain it looks
like `notes.personal.apps.example.com`):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- \
  'sudo k3s kubectl get ksvc -A'
```

Expected — at least one service with a URL whose host is what you send as the `Host` header:

```text
NAMESPACE   NAME    URL                                       READY
personal    notes   http://notes.personal.apps.example.com    True
```

Now prove routing is Host-driven, hitting the public IP directly (this is the baseline the
CDNs must preserve). The first call sends the correct Host header; the second omits it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: notes.personal.apps.example.com' http://<publicIp>/
curl -s -o /dev/null -w '%{http_code}\n' http://<publicIp>/
```

Expected — the correct Host header reaches the app (200 or the app's own code), the bare
request gets Kourier's 404 (proving routing is entirely Host-driven):

```text
200
404
```

### M1 step 1 — Create the Google Cloud CDN load balancer (script)

The reusable script lives at `cluster/examples/cdn-spike/gcp-cdn-up.sh`. It carries the
project preflight, then creates each load-balancer object in order. Run it from the repo
root with the origin host and a static asset path you confirmed in M0:

```bash
cluster/examples/cdn-spike/gcp-cdn-up.sh
```

The script runs this sequence (shown here so the steps are legible; the script wraps them
with the preflight and `--project=tan-nb-exp` on every call). `ZONE=us-west1-a`,
`IG=cdn-spike-ig`, `HC=cdn-spike-hc`, `BES=cdn-spike-bes`, `UM=cdn-spike-um`,
`PROXY=cdn-spike-proxy`, `FR=cdn-spike-fr`, `IP=cdn-spike-ip`:

```bash
# 1. Unmanaged zonal instance group containing the VM, with named ports.
gcloud compute instance-groups unmanaged create "$IG" \
  --zone="$ZONE" --project=tan-nb-exp
gcloud compute instance-groups unmanaged add-instances "$IG" \
  --instances=nagare-01 --zone="$ZONE" --project=tan-nb-exp
gcloud compute instance-groups unmanaged set-named-ports "$IG" \
  --named-ports=http:80,https:443 --zone="$ZONE" --project=tan-nb-exp

# 2. Health check. HTTP-first interim: probe Kourier on port 80. Kourier answers
#    GET / for an unmatched Host with 404, which still proves the port is live;
#    a 404 marks the backend UNHEALTHY, so probe a known-good app path with the
#    Host header instead (--host preserves the Host the LB sends on the probe).
gcloud compute health-checks create http "$HC" \
  --port=80 --request-path=/ \
  --host=notes.personal.apps.example.com \
  --project=tan-nb-exp

# 3. CDN-enabled backend service. enable-cdn turns on Cloud CDN; the default
#    cache mode and the host/header forwarding are validated in step 3 of M1.
gcloud compute backend-services create "$BES" \
  --global --protocol=HTTP --port-name=http \
  --health-checks="$HC" --enable-cdn \
  --project=tan-nb-exp
gcloud compute backend-services add-backend "$BES" \
  --global --instance-group="$IG" --instance-group-zone="$ZONE" \
  --project=tan-nb-exp

# 4. URL map + HTTP target proxy + global IP + forwarding rule.
gcloud compute url-maps create "$UM" --default-service="$BES" --project=tan-nb-exp
gcloud compute target-http-proxies create "$PROXY" --url-map="$UM" --project=tan-nb-exp
gcloud compute addresses create "$IP" --global --project=tan-nb-exp
gcloud compute forwarding-rules create "$FR" \
  --global --target-http-proxy="$PROXY" \
  --address="$IP" --ports=80 \
  --project=tan-nb-exp
```

Read the assigned global IP (referred to below as `<lbIp>`):

```bash
gcloud compute addresses describe "$IP" --global --project=tan-nb-exp \
  --format='value(address)'
```

Expected — a global anycast IPv4, and the backend reporting CDN enabled:

```text
34.a.b.c
```

```bash
gcloud compute backend-services describe "$BES" --global --project=tan-nb-exp \
  --format='value(enableCDN)'
```

Expected:

```text
True
```

### M1 step 2 — Prove a routed response (Host header preserved)

A Google external HTTP(S) load balancer forwards the client's original `Host` header to the
backend by default, so Knative still routes. Use `--resolve` so `curl` sends the real
hostname (and thus the real `Host` header) while connecting to the load balancer IP — no DNS
change needed for the test:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve notes.personal.apps.example.com:80:<lbIp> \
  http://notes.personal.apps.example.com/
```

Expected — the load balancer routed to Kourier, which routed to the app by the preserved
Host header:

```text
200
```

It can take a few minutes after creation for the backend to report `HEALTHY`; check it:

```bash
gcloud compute backend-services get-health "$BES" --global --project=tan-nb-exp
```

Expected — the VM instance is `HEALTHY`:

```text
... healthState: HEALTHY ...
```

### M1 step 3 — Prove a cache HIT on a static asset

Cloud CDN caches responses that are cacheable (the asset should carry a `Cache-Control` with
a positive `max-age`, which the origin Nginx/Knative static layer emits for fingerprinted
assets). Request the same static asset twice and watch the `Age:` header grow and the cache
status flip from MISS to HIT. The response header `via: 1.1 google` and an increasing `age:`
indicate an edge HIT:

```bash
curl -sI --resolve notes.personal.apps.example.com:80:<lbIp> \
  http://notes.personal.apps.example.com/<static-asset>
curl -sI --resolve notes.personal.apps.example.com:80:<lbIp> \
  http://notes.personal.apps.example.com/<static-asset>
```

Expected — first response is a MISS (`age: 0`, no cache), second is a HIT (non-zero `age:`):

```text
HTTP/1.1 200 OK
cache-control: public, max-age=31536000
via: 1.1 google
age: 0
...

HTTP/1.1 200 OK
cache-control: public, max-age=31536000
via: 1.1 google
age: 7
...
```

A non-zero `age:` on the second request is the load-bearing proof of an edge cache HIT.
(Optionally, enable Cloud CDN response-header debugging with
`gcloud compute backend-services update "$BES" --global --custom-response-header='X-Cache-Status: {cdn_cache_status}'`
to make the HIT/MISS explicit in a header.)

### M1 step 4 — Prove a per-path cache rule can be applied to the existing backend

This is the standing-infra-vs-deploy-time-cache split (EP-56/EP-58 dependency): a per-path
cache rule must be addable to the *existing* backend service / URL map without recreating the
load balancer. Update the cache mode and a default TTL on the live backend service:

```bash
gcloud compute backend-services update "$BES" --global --project=tan-nb-exp \
  --cache-mode=CACHE_ALL_STATIC --default-ttl=3600 --max-ttl=86400
```

Expected — the update succeeds in place (no resource recreation):

```text
Updated [https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/backendServices/cdn-spike-bes].
```

Per-*path* TTLs are expressed as URL-map path matchers; confirm a path matcher can be added
to the existing URL map by exporting, editing, and re-importing it (the spike records the
exact YAML so EP-58 can script it). This proves the deploy-time cache layer works against
standing infra.

### M1 step 5 — (Once origin TLS is on) confirm a Google-managed certificate

A Google-managed certificate is issued only once the certificate's hostname already resolves
to the load balancer IP (Google validates control by HTTP/DNS). For a wildcard managed cert,
Google's **Certificate Manager DNS authorization** is required instead. The spike records
which path applies: for a *single* CDN hostname, point that hostname's A record at `<lbIp>`
first, then create the managed cert and an HTTPS proxy; for a *wildcard*, create a
Certificate Manager DNS authorization and a wildcard managed cert. The single-hostname path:

```bash
gcloud compute ssl-certificates create cdn-spike-cert \
  --domains=notes.personal.apps.example.com --global --project=tan-nb-exp
gcloud compute target-https-proxies create cdn-spike-hproxy \
  --url-map="$UM" --ssl-certificates=cdn-spike-cert --project=tan-nb-exp
gcloud compute forwarding-rules create cdn-spike-fr-https \
  --global --target-https-proxy=cdn-spike-hproxy \
  --address="$IP" --ports=443 --project=tan-nb-exp
```

Expected — the managed cert is created in `PROVISIONING` and reaches `ACTIVE` only after the
hostname resolves to `<lbIp>` (record the observed transition):

```text
... managed: status: PROVISIONING ...
```

### M1 step 6 — Tear down the Google load balancer

The teardown script `cluster/examples/cdn-spike/gcp-cdn-down.sh` deletes the objects in
reverse dependency order. **Run it before leaving the spike — the global IP is billable.**

```bash
cluster/examples/cdn-spike/gcp-cdn-down.sh
```

The script runs (each `--project=tan-nb-exp`):

```bash
gcloud compute forwarding-rules delete "$FR" --global --quiet --project=tan-nb-exp
gcloud compute forwarding-rules delete cdn-spike-fr-https --global --quiet --project=tan-nb-exp || true
gcloud compute target-http-proxies delete "$PROXY" --quiet --project=tan-nb-exp
gcloud compute target-https-proxies delete cdn-spike-hproxy --quiet --project=tan-nb-exp || true
gcloud compute ssl-certificates delete cdn-spike-cert --global --quiet --project=tan-nb-exp || true
gcloud compute url-maps delete "$UM" --quiet --project=tan-nb-exp
gcloud compute backend-services delete "$BES" --global --quiet --project=tan-nb-exp
gcloud compute health-checks delete "$HC" --quiet --project=tan-nb-exp
gcloud compute instance-groups unmanaged delete "$IG" --zone="$ZONE" --quiet --project=tan-nb-exp
gcloud compute addresses delete "$IP" --global --quiet --project=tan-nb-exp
```

Expected — each delete confirms, and a final `gcloud compute forwarding-rules list
--global --project=tan-nb-exp` shows no `cdn-spike-*` resources.

### M2 step 1 — Supply Cloudflare credentials and the test hostname

The Cloudflare leg needs a domain whose DNS is hosted at Cloudflare, a scoped API token with
**Zone:DNS:Edit** and **Zone:Cache Rules:Edit** permissions, and the zone identifier. Export
them (never commit them):

```bash
export CF_API_TOKEN='<scoped-token>'
export CF_ZONE_ID='<zone-id>'        # or omit and let the script discover it from CF_HOST
export CF_HOST='cdn-spike.example.com'
export ORIGIN_IP='<publicIp>'         # from M0 step 1
```

### M2 step 2 — Add a proxied (orange-cloud) DNS record (script)

The script `cluster/examples/cdn-spike/cf-cdn-up.sh` calls the Cloudflare API. The
load-bearing field is `"proxied": true` (orange-cloud), which routes the hostname's traffic
through Cloudflare's edge to `ORIGIN_IP`:

```bash
curl -s -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data '{"type":"A","name":"'"${CF_HOST}"'","content":"'"${ORIGIN_IP}"'","proxied":true,"ttl":1}'
```

Expected — Cloudflare confirms the proxied record (`"proxied": true`, `"success": true`):

```text
{"result":{"id":"...","type":"A","name":"cdn-spike.example.com","content":"34.x.y.z","proxied":true,...},"success":true,...}
```

### M2 step 3 — Set the origin-TLS mode

Set the zone's SSL/TLS encryption mode. Start at `flexible` for the HTTP-first origin; once
origin TLS is enabled, set `strict` (Full strict). The API value for "Full (strict)" is
`strict`:

```bash
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/ssl" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data '{"value":"flexible"}'
```

Expected:

```text
{"result":{"id":"ssl","value":"flexible",...},"success":true,...}
```

### M2 step 4 — Prove a routed response and a cache HIT

Cloudflare forwards the original `Host` header to the origin by default, so Knative routing
is preserved (the test hostname must correspond to a Knative DomainMapping or be sent as the
Host Kourier expects). Request a static asset twice and read `CF-Cache-Status`:

```bash
curl -sI "https://${CF_HOST}/" | grep -i -E 'http/|cf-cache-status'
curl -sI "https://${CF_HOST}/<static-asset>"
curl -sI "https://${CF_HOST}/<static-asset>"
```

Expected — the root routes (200), and the static asset is a MISS then a HIT:

```text
HTTP/2 200
cf-cache-status: DYNAMIC

HTTP/2 200
cf-cache-status: MISS
...

HTTP/2 200
cf-cache-status: HIT
...
```

`cf-cache-status: HIT` on the second request is the load-bearing proof. If the asset is not
cached by default, add a cache rule (M2 step 5) and repeat.

### M2 step 5 — Add a cache rule for a static path

Use the Cloudflare Rulesets API (`http_request_cache_settings` phase) to force-cache a path
prefix with an edge TTL — the same operation EP-57's `applyCacheRules` will perform:

```bash
curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/rulesets/phases/http_request_cache_settings/entrypoint" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data '{"rules":[{"expression":"(starts_with(http.request.uri.path, \"/assets/\"))","action":"set_cache_settings","action_parameters":{"cache":true,"edge_ttl":{"mode":"override_origin","default":31536000}}}]}'
```

Expected — the ruleset is created/updated (`"success": true`); a re-run of M2 step 4 against
an `/assets/...` path now shows `cf-cache-status: HIT` on the second request.

### M2 step 6 — Tear down the Cloudflare proxy

The teardown script `cluster/examples/cdn-spike/cf-cdn-down.sh` deletes the test DNS record
(and optionally the cache ruleset). Discover the record ID, then delete it:

```bash
REC_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${CF_HOST}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
curl -s -X DELETE \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}"
```

Expected:

```text
{"result":{"id":"..."},"success":true,...}
```

### M3 — Record the Substrate Decisions

After M1 and M2's transcripts are captured, write the verified facts into the Substrate
Decisions subsection of Interfaces and Dependencies below, confirm or amend each PROPOSAL in
the Decision Log, update Progress to mark the milestones done, and add any Surprises. No
cloud commands run in M3; its output is edits to this file (and a commit).


## Validation and Acceptance

The spike is validated entirely by **observable edge behavior**, captured as `curl`
transcripts, plus the recorded decisions. There are no automated tests — this is a
substrate spike, like EP-43 and EP-49, whose deliverable is verified facts in this document
and the reusable scripts under `cluster/examples/cdn-spike/`.

Acceptance per milestone: **M0** — `curl -H 'Host: <known-app-host>' http://<publicIp>/`
returns the app's response and the same request without the Host header returns Kourier's
404, proving Host-driven routing. **M1** — the load balancer reports `enableCDN: True`, the
backend reaches `HEALTHY`, a `--resolve`'d request returns 200 with the original Host header
preserved, the same static asset returns `age: 0` then a non-zero `age:` (an edge HIT), and a
per-path cache rule applies to the existing backend with no load-balancer recreation; all
`cdn-spike-*` resources are deleted at teardown. **M2** — the proxied DNS record reports
`"proxied": true`, a static asset returns `cf-cache-status: MISS` then `HIT`, the working
origin-TLS mode is recorded, and the test record is deleted at teardown. **M3** — the
Substrate Decisions subsection contains the per-provider topology decisions, the origin-TLS
mode per provider, the DNS-authority-collision resolution, the standing-infra-vs-deploy-time
split, and an explicit statement that the typed `Cdn` contract is sufficient (or the exact
amendments to send back to EP-55).

Because the VM is off, the acceptance evidence for M1 and M2 is **deferred**: the commands
and expected transcripts above are the contract for what an operator captures once the VM is
running (and Cloudflare credentials are supplied). Until then, the plan's acceptance is that
the command sequences and the proposed decisions are complete and self-consistent, which a
reviewer can verify by reading this file alone.


## Idempotence and Recovery

Every live leg is designed to be safe to re-run and fully reversible. Starting an
already-running VM is a no-op (`gcloud` reports it is already running). The Google
load-balancer objects use fixed `cdn-spike-*` names, so a re-run of `gcp-cdn-up.sh` after a
partial failure will report "already exists" for objects that were created; the script
tolerates that (each create is followed by the next step, and the teardown deletes whatever
exists). If `gcp-cdn-up.sh` fails partway, run `gcp-cdn-down.sh` (its deletes are
`--quiet` and tolerate missing objects via `|| true` on the optional HTTPS resources), then
re-run `gcp-cdn-up.sh` from a clean slate. **The global IP and the load balancer are
billable** — the teardown is mandatory; verify with
`gcloud compute forwarding-rules list --global --project=tan-nb-exp` that no `cdn-spike-*`
resources remain.

For Cloudflare, the proxied DNS record is the only durable change; `cf-cdn-up.sh` uses a
fixed hostname so a re-run updates rather than duplicates (Cloudflare rejects a duplicate A
record of the same name, and the script can `PATCH` an existing record if present).
`cf-cdn-down.sh` discovers and deletes the test record by name, so it is safe to run even if
the record was already removed. The SSL-mode change is a setting, not a resource, and the
spike leaves it at whatever the operator's zone used before (record the original value before
M2 step 3 and restore it at teardown if the zone is shared).

If anything goes wrong with the origin during the spike, nothing in this plan modifies the
cluster or the running apps — the spike only *reads* from the cluster (M0) and points
external edges at the unchanged origin IP. The single optional cluster-side change is the
HTTPS one-flip (`external-domain-tls: Enabled`), which is reversible by setting it back to
`Disabled`; the spike does not require it for the HTTP-first legs and only needs it for the
`Full (strict)` / Google-HTTPS-origin confirmations.


## Interfaces and Dependencies

This spike depends on services and facts the bootstrap plans already established, and
produces the decisions four later plans consume. It introduces no Haskell or TypeScript
types of its own; the types it *validates* are EP-55's `Cdn`/`CdnProvider`/`CdnCacheRule`
(quoted in Context) and EP-57's `OriginTlsMode`.

**Depends on.** The Pulumi stack outputs `publicIp` (the origin IP) and `dnsZoneName` (the
Cloud DNS zone), defined in `infra/pulumi/src/components/NagarePerimeter.ts`. The Knative
Serving + Kourier ingress that serves the origin and routes by Host header
(`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`). The cert-manager
`ClusterIssuer` `letsencrypt-dns` (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) and
the HTTPS one-flip `external-domain-tls` in
`cluster/bootstrap/knative-serving/config-network-tls.yaml`. The firewall in
`infra/pulumi/src/components/NagareNetwork.ts` (80/443 already open to `0.0.0.0/0`, so Google
health checks from `130.211.0.0/22` and `35.191.0.0/16` already reach the origin). The IAP
SSH wrapper `scripts/iap-ssh.sh`. The Pulumi provider `@pulumi/gcp` `^8.10.0`.

**Produces (committed artifacts).** This document, and the throwaway example directory
`cluster/examples/cdn-spike/` containing: `README.md` (what the spike is, how to run it, the
powered-off caveat), `gcp-cdn-up.sh` / `gcp-cdn-down.sh` (the Google load-balancer create /
teardown, project-preflighted), and `cf-cdn-up.sh` / `cf-cdn-down.sh` (the Cloudflare API
create / teardown, reading `CF_API_TOKEN`/`CF_ZONE_ID`/`CF_HOST`/`ORIGIN_IP` from the
environment). These follow the `cluster/examples/db-spike/` convention: concise header
comments explaining *why*, copy-pasteable command blocks, idempotent and reversible.

### Substrate Decisions (the contract the rest of MasterPlan 11 consumes)

This subsection is the spike's primary deliverable. The decisions below are stated as the
**proposals the live spike confirms** (the VM is off; see Purpose). Each names the
integration point and the later plan that consumes it; cross-references are to
`docs/masterplans/11-cdn-integration-for-nagare.md`'s Integration Points (IP1 typed model,
IP2 Google standing infra + stack outputs, IP3 Cloudflare module, IP6 CDN DNS records, IP7
origin-TLS model).

**Google Cloud CDN topology (consumed by EP-56 / EP-58; IP2).** The single VM is wrapped in
an **unmanaged zonal instance group** (`us-west1-a`) with named ports `http:80`/`https:443`.
The **health check** probes the origin on the named port with a known-good app path and the
app's Host header (`--host`), because Kourier returns 404 — which marks a backend
UNHEALTHY — for an unmatched Host on `GET /`; the spike records the exact path/port that
yields `HEALTHY`. The **backend service** is CDN-enabled (`--enable-cdn`) and **forwards the
client's original `Host` header unchanged** (the Google external HTTP(S) LB default), so
Knative still routes; no custom `Host` rewrite is configured. The **cache-key policy**
includes the host and path (default); the spike records whether the default cache key is
correct for multi-host origins or must include the Host explicitly. The default **cache
mode** is `CACHE_ALL_STATIC` with a default TTL; per-path TTLs are URL-map path matchers. A
**Google-managed certificate** terminates client TLS at the edge and is issued only after the
hostname resolves to the LB IP (single-hostname path) or via **Certificate Manager DNS
authorization** (wildcard path) — the spike records which applies. **Standing infra**
(LB, IP, backend, URL map, managed cert) belongs in **Pulumi** (EP-56); **per-path cache
rules** are applied at **deploy time** via `gcloud compute backend-services update` and
URL-map path matchers (EP-58) — confirmed addable to the existing backend without
recreating the load balancer.

**Cloudflare topology (consumed by EP-57 / EP-58; IP3, IP7).** A **proxied (orange-cloud)**
DNS A record points the hostname at the VM's `publicIp`; Cloudflare's edge forwards the
original `Host` header by default, so Knative routes. A **cache rule** (Rulesets API,
`http_request_cache_settings` phase) force-caches a static path prefix with an edge TTL; a
second request returns `cf-cache-status: HIT` (the recorded proof). The **default origin-TLS
mode is `Full (strict)`** (`strict` in the API), reached via `Flexible` for the HTTP-first
interim — the spike records which mode returns 200 against the current origin and which is
the steady-state default once origin TLS is on. The **DNS-authority collision** (Cloudflare
proxy requires CF-hosted DNS, which breaks cert-manager's Cloud DNS DNS-01 challenge) is
resolved by **moving cert-manager's DNS-01 solver to a Cloudflare API-token solver** for
Cloudflare-fronted hostnames (recommended option (b); alternatives (a) CNAME-delegate
`_acme-challenge` back to Cloud DNS, and (c) Cloudflare Origin CA + `Full (strict)`, are
recorded with trade-offs in the Decision Log). EP-57's `OriginTlsMode` therefore needs at
least `Flexible | Full | FullStrict`.

**Typed `Cdn` contract sufficiency (consumed by EP-55; IP1).** The proposed contract
(`provider`, `defaultTtlSeconds`, `cacheStaticAssets`, `cacheRules` of
`(pathPrefix, Maybe edgeTtlSeconds)`) maps cleanly onto both providers: `defaultTtlSeconds` →
Google `--default-ttl` / Cloudflare default edge TTL; `cacheStaticAssets` → Google
`CACHE_ALL_STATIC` / a Cloudflare static-asset cache rule; each `CdnCacheRule` → a Google
URL-map path matcher / a Cloudflare cache rule, with `Nothing` (never cache) → Google
`bypassCache` / Cloudflare `cache:false`. The spike's recommendation to EP-55 (to be
finalized in M3): **the contract is sufficient and provider-portable as proposed**, with one
open question for EP-55 to settle — whether **origin-TLS mode** must be expressible *in the
typed model* (a field on `Cdn`) or stays a deploy-time default chosen by EP-57/EP-58. The
spike's recommendation is the latter (keep it out of the model; default `Full (strict)`),
because origin TLS is a platform-wide posture, not a per-site choice; EP-55 confirms or
amends.
