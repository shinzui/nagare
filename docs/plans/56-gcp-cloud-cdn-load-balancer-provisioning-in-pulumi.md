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

- [ ] Milestone 1 — Add the `nagare:enableCdn` config flag and a `NagareCdn` component
      (`infra/pulumi/src/components/NagareCdn.ts`) creating the global IP, unmanaged instance
      group, health check, CDN backend service, URL map, managed cert, HTTP/HTTPS proxies, and
      forwarding rules; instantiate it from `NagarePerimeter` only when the flag is set.
- [ ] Milestone 1 — Add the load-balancer health-check firewall rule
      (`130.211.0.0/22`, `35.191.0.0/16`) to `NagareNetwork`.
- [ ] Milestone 1 — Bubble `cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap` through
      `NagarePerimeter`, export them from `index.ts`, and add them to `StackOutputs` in
      `infra/pulumi/src/outputs.ts`.
- [ ] Milestone 1 — `cd infra/pulumi && npm run build` (`tsc --noEmit`) passes; `pulumi -C
      infra/pulumi preview` shows the new resources with the flag `true` and none with it
      `false`. Capture the preview transcript.
- [ ] Milestone 2 — `pulumi -C infra/pulumi up` applies the resources; verify with
      `gcloud compute ... --project=tan-nb-exp` and `pulumi -C infra/pulumi stack output`.
- [ ] Milestone 2 (DEFERRED, VM-off) — once `nagare-01` is powered on, run the
      `curl`-through-the-load-balancer acceptance and record the result.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan happens in `infra/pulumi/`, a TypeScript Pulumi program. Pulumi is an
infrastructure-as-code tool: you describe cloud resources as TypeScript objects, and
`pulumi preview` shows the plan while `pulumi up` makes it real. The program's dependencies
(`infra/pulumi/package.json`) are `@pulumi/pulumi` `^3.140.0`, `@pulumi/gcp` `^8.10.0`, and
TypeScript `^5.4`. The build is type-checking only: `npm run build` runs `tsc --noEmit`.

State is stored in the repository, not in Pulumi's cloud. The repo-root `CLAUDE.md` and
`.envrc` configure `pulumi login file://./infra/pulumi/.pulumi-state` with a passphrase-based
secrets provider; `PULUMI_HOME` and `PULUMI_CONFIG_PASSPHRASE` come from `.envrc` (run
`direnv allow` once). The active stack is `dev`. Run every Pulumi command with the working-
directory flag, `pulumi -C infra/pulumi <verb>`, so you do not need to `cd`.

The strict project-isolation policy from `CLAUDE.md` applies to this entire plan: every
resource — created, modified, or merely read — lives in GCP project `tan-nb-exp`, region
`us-west1`, zone `us-west1-a`. No command here may target another project. `Pulumi.dev.yaml`
already pins `gcp:project: tan-nb-exp`, `gcp:region: us-west1`, `gcp:zone: us-west1-a`,
`nagare:baseDomain: apps.example.com`, and `nagare:imageBucket: tan-nb-exp-nagare-images`.

The program's entry point, `infra/pulumi/index.ts`, reads configuration and instantiates ONE
component, `new NagarePerimeter("nagare", {...})`, then exports nine stack outputs whose names
are exactly the exported binding names (`publicIp`, `baseDomain`, `instanceName`,
`serviceAccountEmail`, `dataDiskName`, `dnsZoneName`, `artifactRegistry`, `backupBucket`,
`sshCommand`). A "stack output" is a named value Pulumi records after `up`, readable with
`pulumi -C infra/pulumi stack output <name>`. The CLI's `Nagare.Ops.Pulumi.stackOutput`
(`cli/nagarectl/src/Nagare/Ops/Pulumi.hs`, signature
`stackOutput :: FilePath -> Text -> IO (Maybe Text)`) already reads outputs this way; EP-58 will
read the three new outputs through it.

The components live under `infra/pulumi/src/components/`. The orchestrator
`NagarePerimeter.ts` (class `NagarePerimeter extends pulumi.ComponentResource`) instantiates
`NagareNetwork` and (only when an image self-link is configured) `NagareInstance`, and directly
creates the static regional IP, the data disk, the service account and its IAM, the GCS
buckets, the Cloud DNS managed zone with its single `*.apps.example.com` wildcard A record, and
the Artifact Registry repository. It exposes the static IP as `this.publicIp` and the VM (when
present) via the instance it constructs.

`NagareNetwork.ts` (class `NagareNetwork`) builds a custom-mode VPC `nagare-network-net`
(`autoCreateSubnetworks: false`), the subnet `nagare-network-subnet` (`10.10.0.0/24`,
`us-west1`), and three firewall rules: `nagare-network-fw-web` (ingress, `sourceRanges
["0.0.0.0/0"]`, tcp `80`/`443`), `nagare-network-fw-iap-ssh` (`35.235.240.0/20`, tcp `22`), and
`nagare-network-fw-tailscale` (udp `41641`). It exposes `this.network` and `this.subnet`.

`NagareInstance.ts` (class `NagareInstance`) creates `gcp.compute.Instance` named `nagare-01`
in `us-west1-a` (machine type `e2-standard-2`, `allowStoppingForUpdate: true`, boot disk,
attached data disk, a network interface on the subnet with an access config that pins the
reserved static IP as `natIp`, a service account with the `cloud-platform` scope, and metadata
`enable-oslogin: TRUE`). It exposes the VM as `this.instance`, whose self-link
(`this.instance.selfLink`) is what an instance group needs to reference the VM.

`infra/pulumi/src/outputs.ts` declares the `StackOutputs` interface (the nine current output
fields) and `buildSshCommand(...)`. Adding the three CDN outputs means extending this interface
and the exports in `index.ts`.

By grep, there is NO existing load balancer, backend service, URL map, SSL certificate, or
Cloud CDN anywhere in the program; this is a clean, additive change.

This plan hard-depends on EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`),
which validates the load-balancer-to-Kourier topology, the health-check path/port, the
host-header handling, and the origin-TLS mode by hand before this plan encodes them as code. It
soft-depends on EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`) so the
provisioning inputs here match the typed model's field names. It is consumed by EP-58
(`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`).


## Plan of Work

The work is two milestones. Milestone 1 adds the component, the flag, and the outputs and is
fully reviewable with `tsc --noEmit` and `pulumi preview` (no live cloud needed, no VM needed).
Milestone 2 applies the stack and validates the live resources with `gcloud`, deferring the
end-to-end `curl` until the VM is powered on.


### Milestone 1 — the `NagareCdn` component and outputs, behind the `enableCdn` flag

At the end of this milestone, a new file `infra/pulumi/src/components/NagareCdn.ts` defines a
component that, when instantiated, creates the entire standing load-balancer-with-CDN topology;
`NagarePerimeter.ts` instantiates it only when `nagare:enableCdn` is `true` and passes the VM's
self-link, the zone, the project/region/zone, the `baseDomain`, and the existing `publicIp` for
reference; `NagareNetwork.ts` gains the load-balancer health-check firewall rule; and three new
outputs flow through `NagarePerimeter` → `index.ts` → `StackOutputs`. The whole thing
type-checks with `cd infra/pulumi && npm run build` and previews cleanly: with the flag `true`,
`pulumi -C infra/pulumi preview` lists the new resources; with the flag `false` (or unset), it
lists none of them. Acceptance is the `pulumi preview` transcript; the VM being OFF does not
matter because `preview` is a plan-only diff.

The component, `class NagareCdn extends pulumi.ComponentResource` with type token
`nagare:cdn:NagareCdn`, takes an args interface carrying `gcpProject`, `region`, `zone`,
`baseDomain`, `instanceSelfLink` (the VM's `selfLink`), `network` (the VPC id, for the named-
port-bearing instance group and so the firewall can be co-located if chosen), and `publicIp`
(passed for reference/diagnostics even though the load balancer uses its own anycast IP). It
creates, in order:

First, a `gcp.compute.GlobalAddress` named `${name}-ip` — the anycast IPv4. Its `.address` is
surfaced as the `cdnGlobalIp` field.

Second, a `gcp.compute.InstanceGroup` named `${name}-ig` — an UNMANAGED zonal instance group in
`us-west1-a`. Its `instances` list contains the single VM (`args.instanceSelfLink`), and its
`namedPorts` declare `http:80` and `https:443` so the backend service can target whichever port
EP-54 chose. The instance group is the seam that lets a load-balancer backend point at the one
hand-built VM without a managed instance group (see Decision Log).

Third, a `gcp.compute.HealthCheck` named `${name}-hc` — the HTTP health check EP-54 validated
against Kourier. Use an `httpHealthCheck` block with the `port` and `requestPath` EP-54
recorded (the readiness path Kourier answers without a deployed app). The health check is
global (a `gcp.compute.HealthCheck`, not a regional one) because it pairs with a global backend
service.

Fourth, a `gcp.compute.BackendService` named `${name}-backend` with `enableCdn: true`. It sets
`protocol` to the origin protocol EP-54 chose (`HTTP` or `HTTPS`), references the health check
in `healthChecks`, lists the instance group as its single `backend` (with the named port
`balancingMode: "UTILIZATION"` or `"RATE"` per EP-54's spike, defaulting to the load-balancer
default), and includes a `cdnPolicy` block: a `cacheMode` (`USE_ORIGIN_HEADERS` to honour the
origin's `Cache-Control`, or `CACHE_ALL_STATIC` per the spike) and a conservative
`defaultTtl`. It preserves the original `Host` header / sets the custom request header EP-54
chose so Knative still routes by hostname (via `customRequestHeaders` if EP-54 requires an
explicit `Host: {client_host}` style header, otherwise relying on the default host-preserving
behaviour the spike confirmed). Its `.name` is surfaced as `cdnBackendService`. This is the
default cache policy only; per-site policy is layered on by EP-58.

Fifth, a `gcp.compute.URLMap` named `${name}-urlmap` whose `defaultService` is the backend
service. It is intentionally minimal (default route only) so EP-58 can add per-host path
matchers at deploy time. Its `.name` is surfaced as `cdnUrlMap`.

Sixth, TLS termination at the edge: a Google-managed certificate per EP-54's decision — either
`gcp.compute.ManagedSslCertificate` named `${name}-cert` for a single hostname, or Certificate
Manager resources (`gcp.certificatemanager.Certificate` + `gcp.certificatemanager.DnsAuthorization`
+ a `gcp.certificatemanager.CertificateMap`) for a wildcard. Then a
`gcp.compute.TargetHttpsProxy` named `${name}-https-proxy` referencing the URL map and the
certificate.

Seventh, the HTTP→HTTPS redirect: a tiny separate `gcp.compute.URLMap` named `${name}-redirect`
whose `defaultUrlRedirect` sets `httpsRedirect: true` and `stripQuery: false`, and a
`gcp.compute.TargetHttpProxy` named `${name}-http-proxy` referencing that redirect map.

Eighth, the front-end entry points bound to the anycast IP: a `gcp.compute.GlobalForwardingRule`
named `${name}-fr-https` (`portRange: "443"`, `loadBalancingScheme: "EXTERNAL_MANAGED"`,
`ipAddress: globalAddress.address`, `target: httpsProxy.id`) and a `gcp.compute.GlobalForwardingRule`
named `${name}-fr-http` (`portRange: "80"`, same scheme and address, `target: httpProxy.id`).

The component exposes three public readonly fields — `cdnGlobalIp: pulumi.Output<string>`,
`cdnBackendService: pulumi.Output<string>`, `cdnUrlMap: pulumi.Output<string>` — and registers
them via `this.registerOutputs(...)`.

The firewall rule that allows Google's load-balancer health-check and proxy source ranges
`130.211.0.0/22` and `35.191.0.0/16` to reach the VM on the backend port goes into
`NagareNetwork.ts` as `nagare-network-fw-lb-health` (ingress, those two source ranges, tcp
`80`/`443`). It is placed there, not in `NagareCdn`, because `NagareNetwork` already owns every
firewall rule and the VPC the rule attaches to (`this.network.id`), keeping all ingress policy
in one module; the rule is harmless and free even when the CDN is disabled (it only widens which
source ranges may reach already-open ports), so it does not need to be gated behind the flag.
This is defense in depth: `nagare-network-fw-web` already opens `0.0.0.0/0` on `80`/`443`, but
declaring the Google ranges explicitly documents the dependency and survives any future
tightening of `fw-web`.

In `index.ts`, read the flag near the other config: `const enableCdnCfg =
cfg.getBoolean("enableCdn") ?? false;` and pass `enableCdn: enableCdnCfg` into the
`NagarePerimeter` args. After the existing nine exports, add three more:
`export const cdnGlobalIp = perimeter.cdnGlobalIp;`,
`export const cdnBackendService = perimeter.cdnBackendService;`,
`export const cdnUrlMap = perimeter.cdnUrlMap;`. Because the exported binding name is the
stack-output name, these names are the exact `cdnGlobalIp` / `cdnBackendService` / `cdnUrlMap`
contract EP-58 reads.

In `NagarePerimeter.ts`, add `enableCdn: boolean;` to `NagarePerimeterArgs`, add the three
`public readonly cdn*` fields to the class, and at the end of the constructor instantiate
`NagareCdn` only when both the flag is set and the VM exists (the load balancer needs a backend
VM to point at). When the flag is off, assign the three fields to a clear sentinel so the stack
output is still well-typed but obviously absent (for example `pulumi.output("(cdn disabled)")`),
and document that EP-58 treats that sentinel as "no Google CDN provisioned". Register the three
new fields in `this.registerOutputs(...)`.

In `infra/pulumi/src/outputs.ts`, add `cdnGlobalIp: pulumi.Output<string>;`,
`cdnBackendService: pulumi.Output<string>;`, and `cdnUrlMap: pulumi.Output<string>;` to the
`StackOutputs` interface, with a comment noting these are MasterPlan Integration Point 2 and are
read by EP-58.


### Milestone 2 — apply and live validation (environment-gated)

At the end of this milestone the load balancer exists in `tan-nb-exp` and the three outputs are
readable. Because `nagare-01` is currently powered OFF, `pulumi up` creates the load balancer
but the backend has no live origin, so the end-to-end `curl`-through-the-load-balancer check is
deferred until the box is on. This milestone provides the exact `pulumi up`, the `gcloud`
verification of the created resources, and the deferred `curl` acceptance to run later. The
deferral is recorded plainly, matching `docs/plans/43-*.md` and `docs/plans/49-*.md`.


## Concrete Steps

All commands run from the repository root unless a working directory is given. The shell must
have `direnv allow` already run so `PULUMI_HOME`, `PULUMI_CONFIG_PASSPHRASE`, and the
`CLOUDSDK_*` project pins are set.

First, set the opt-in flag on the `dev` stack:

```bash
pulumi -C infra/pulumi config set nagare:enableCdn true
```

Type-check the program:

```bash
cd infra/pulumi && npm run build
```

Expected: `tsc --noEmit` prints nothing and exits `0`. Any error names a file and line to fix.

Preview with the flag ON. Expect the new load-balancer resources in the plan:

```bash
pulumi -C infra/pulumi preview
```

Expected (abridged) transcript — resource names will carry Pulumi's random suffixes, and the
exact set of certificate resources depends on EP-54's managed-cert choice:

```text
Previewing update (dev):
     Type                                          Name                          Plan
 +   ├─ nagare:cdn:NagareCdn                        nagare-cdn                    create
 +   │  ├─ gcp:compute:GlobalAddress                nagare-cdn-ip                 create
 +   │  ├─ gcp:compute:InstanceGroup                nagare-cdn-ig                 create
 +   │  ├─ gcp:compute:HealthCheck                  nagare-cdn-hc                 create
 +   │  ├─ gcp:compute:BackendService               nagare-cdn-backend            create
 +   │  ├─ gcp:compute:URLMap                        nagare-cdn-urlmap             create
 +   │  ├─ gcp:compute:URLMap                        nagare-cdn-redirect           create
 +   │  ├─ gcp:compute:ManagedSslCertificate        nagare-cdn-cert               create
 +   │  ├─ gcp:compute:TargetHttpsProxy             nagare-cdn-https-proxy        create
 +   │  ├─ gcp:compute:TargetHttpProxy              nagare-cdn-http-proxy         create
 +   │  ├─ gcp:compute:GlobalForwardingRule         nagare-cdn-fr-https           create
 +   │  └─ gcp:compute:GlobalForwardingRule         nagare-cdn-fr-http            create
 +   └─ gcp:compute:Firewall                        nagare-network-fw-lb-health   create

Resources:
    + 13 to create
    ~ ... unchanged
```

Now prove the flag gates the whole capability. Turn it OFF and preview again:

```bash
pulumi -C infra/pulumi config set nagare:enableCdn false
pulumi -C infra/pulumi preview
```

Expected: none of the `nagare:cdn:NagareCdn` resources appear and the plan reports no CDN
creations (the `nagare-network-fw-lb-health` firewall rule is intentionally not gated and may
still appear; that is expected and explained in Plan of Work). Re-enable the flag before
applying:

```bash
pulumi -C infra/pulumi config set nagare:enableCdn true
```

Apply (Milestone 2):

```bash
pulumi -C infra/pulumi up
```

Expected: the same resource list as the preview, applied, ending with a summary such as
`Resources: + 13 created` and the `Outputs:` block now showing `cdnGlobalIp`,
`cdnBackendService`, and `cdnUrlMap`.

Read the three new outputs:

```bash
pulumi -C infra/pulumi stack output cdnGlobalIp
pulumi -C infra/pulumi stack output cdnBackendService
pulumi -C infra/pulumi stack output cdnUrlMap
```

Expected: `cdnGlobalIp` prints an IPv4 address (the anycast IP), `cdnBackendService` prints the
backend service's name (e.g. `nagare-cdn-backend-<suffix>`), and `cdnUrlMap` prints the URL
map's name.

Verify the live resources with `gcloud`, always pinning the project:

```bash
gcloud compute forwarding-rules list --global --project=tan-nb-exp
gcloud compute backend-services list --global --project=tan-nb-exp
gcloud compute backend-services describe "$(pulumi -C infra/pulumi stack output cdnBackendService)" \
  --global --project=tan-nb-exp --format='value(enableCDN, cdnPolicy.cacheMode)'
gcloud compute url-maps list --project=tan-nb-exp
gcloud compute addresses list --global --project=tan-nb-exp
```

Expected: the forwarding rules list shows the `:80` and `:443` global rules bound to the anycast
IP; the backend-services `describe` prints `True` for `enableCDN` and the configured cache mode;
the URL map and global address are present.

The end-to-end caching check is DEFERRED because `nagare-01` is powered OFF. Once it is on, run:

```bash
gcloud compute instances start nagare-01 --zone=us-west1-a --project=tan-nb-exp
CDN_IP="$(pulumi -C infra/pulumi stack output cdnGlobalIp)"
curl -sS -o /dev/null -D - --resolve "test.apps.example.com:443:${CDN_IP}" \
  https://test.apps.example.com/ | grep -i -E 'HTTP/|cache|via|age'
```

Expected once the box is up and a test app is deployed: an `HTTP/2 200`, and on a second request
an `Age:` or cache-status header indicating an edge hit. Record the transcript in this plan's
Surprises & Discoveries and flip the Progress item to done. Until then, the deferred item stays
checked-as-deferred, exactly as `docs/plans/49-*.md` recorded its VM-required legs.


## Validation and Acceptance

Milestone 1 is accepted when `cd infra/pulumi && npm run build` exits `0` and the two previews
behave as specified: with `nagare:enableCdn true`, `pulumi -C infra/pulumi preview` plans the
`nagare:cdn:NagareCdn` component and its children (global address, instance group, health check,
CDN-enabled backend service, URL maps, managed certificate, target proxies, forwarding rules);
with the flag `false`, it plans none of them. The acceptance evidence is the preview transcript
shown under Concrete Steps. No live cloud and no running VM are required, because `preview` is a
plan-only diff.

Milestone 2 is accepted when `pulumi -C infra/pulumi up` creates the resources and all three
outputs read back: `pulumi -C infra/pulumi stack output cdnGlobalIp` returns an IPv4 address,
`cdnBackendService` and `cdnUrlMap` return resource names, and the `gcloud compute
backend-services describe ... --project=tan-nb-exp` call reports `enableCDN: True`. These three
outputs are the hard contract EP-58 consumes; their names must be exactly `cdnGlobalIp`,
`cdnBackendService`, `cdnUrlMap`.

The live, behavioural acceptance — a `curl` through the anycast IP returning `200` with an
edge-cache header on a second request — is deferred until `nagare-01` is powered on, and is
recorded as such (not a failure). When the box is on, run the deferred `curl` from Concrete
Steps and record the transcript.


## Idempotence and Recovery

Every step is safe to repeat. `pulumi preview` is read-only. `pulumi up` is convergent: running
it again with no source changes is a no-op (`Resources: ... unchanged`). Toggling
`nagare:enableCdn` is the supported on/off switch — setting it `false` and running `pulumi up`
deletes the `NagareCdn` resources cleanly (the load balancer is composed of independent global
resources with no data to lose), and setting it `true` recreates them. Because the capability is
gated and additive, an operator can stand the load balancer up to evaluate cost and tear it down
without touching the VM, the data disk, the DNS wildcard, or any other existing resource.

The Google-managed certificate may sit in a `PROVISIONING`/pending state until a real
`baseDomain` is delegated and DNS points the hostname at the anycast IP; this is expected and
does not block `pulumi up` from succeeding (the certificate resource is created; Google
provisions it asynchronously). EP-54's origin-TLS decision and EP-58's per-hostname DNS records
resolve this; until then a pending certificate is the correct, non-erroneous state, and the HTTP
forwarding rule still serves the redirect. If a `pulumi up` is interrupted, re-running it
re-converges from the file-backed state under `infra/pulumi/.pulumi-state`; if a single resource
is stuck, `pulumi -C infra/pulumi refresh` reconciles Pulumi's state with the live cloud before
retrying. All `gcloud` verification commands are read-only except the explicit
`instances start`, which is itself idempotent (starting an already-running instance is a no-op).


## Interfaces and Dependencies

This plan uses `@pulumi/gcp` `^8.10.0` and `@pulumi/pulumi` `^3.140.0` (already in
`infra/pulumi/package.json`); no new npm dependency is added. The new resources are all in the
`gcp.compute` namespace — `GlobalAddress`, `InstanceGroup`, `HealthCheck`, `BackendService`,
`URLMap`, `ManagedSslCertificate`, `TargetHttpsProxy`, `TargetHttpProxy`, `GlobalForwardingRule`,
`Firewall` — plus, only if EP-54 chose a wildcard certificate, the `gcp.certificatemanager.*`
resources. These are the standard building blocks of a Google global external Application Load
Balancer with Cloud CDN.

At the end of Milestone 1 the following must exist:

The new file `infra/pulumi/src/components/NagareCdn.ts` exporting:

```typescript
export interface NagareCdnArgs {
    gcpProject: string;
    region: string;
    zone: string;
    baseDomain: string;
    /** Self-link of the VM `nagare-01` (NagareInstance `this.instance.selfLink`). */
    instanceSelfLink: pulumi.Input<string>;
    /** VPC network id, for the instance group and (if co-located) firewall. */
    network: pulumi.Input<string>;
    /** The VM's existing regional static IP, passed for reference/diagnostics. */
    publicIp: pulumi.Input<string>;
}

export class NagareCdn extends pulumi.ComponentResource {
    public readonly cdnGlobalIp: pulumi.Output<string>;
    public readonly cdnBackendService: pulumi.Output<string>;
    public readonly cdnUrlMap: pulumi.Output<string>;
    constructor(name: string, args: NagareCdnArgs, opts?: pulumi.ComponentResourceOptions);
}
```

`infra/pulumi/src/components/NagarePerimeter.ts` — `NagarePerimeterArgs` gains
`enableCdn: boolean;`, and `NagarePerimeter` gains
`public readonly cdnGlobalIp: pulumi.Output<string>;`,
`public readonly cdnBackendService: pulumi.Output<string>;`, and
`public readonly cdnUrlMap: pulumi.Output<string>;`, populated either from a `NagareCdn`
instance (flag on, VM present) or from a clear disabled-sentinel output.

`infra/pulumi/src/components/NagareNetwork.ts` — a new `gcp.compute.Firewall`
`nagare-network-fw-lb-health` allowing source ranges `130.211.0.0/22` and `35.191.0.0/16` on tcp
`80`/`443`.

`infra/pulumi/index.ts` — reads `cfg.getBoolean("enableCdn") ?? false`, passes it to
`NagarePerimeter`, and adds the exports `cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap`.

`infra/pulumi/src/outputs.ts` — the `StackOutputs` interface gains `cdnGlobalIp`,
`cdnBackendService`, `cdnUrlMap`, each `pulumi.Output<string>`.

The three stack outputs `cdnGlobalIp`, `cdnBackendService`, and `cdnUrlMap` are MasterPlan
Integration Point 2 and are read by EP-58 via `pulumi -C infra/pulumi stack output <name>`
through `Nagare.Ops.Pulumi.stackOutput`
(`cli/nagarectl/src/Nagare/Ops/Pulumi.hs`,
`stackOutput :: FilePath -> Text -> IO (Maybe Text)`). Their names are a hard cross-plan
contract and must not be renamed without updating the MasterPlan and EP-58.

The exact health-check path/port, the origin protocol (HTTP vs HTTPS), the host-header handling,
and the managed-certificate kind (single-hostname `ManagedSslCertificate` vs Certificate-Manager
wildcard) are inputs decided by EP-54
(`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`); read its Decision Log for
the confirmed values before hard-coding them in `NagareCdn.ts`. The provisioning input names
(provider, default TTL, per-path rules) should match the typed model defined by EP-55
(`docs/plans/55-typed-cdn-model-and-provider-renderer.md`), though the model and this capability
are wired together only in EP-58.
