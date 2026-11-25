---
id: 285
slug: serve-a-wildcard-content-domain-from-one-worker-with-the-host-header-intact
title: "Serve a wildcard content domain from one worker with the Host header intact"
kind: exec-plan
created_at: 2026-11-25T16:08:21Z
intention: "intention_01m89q6asjedws62wy3n95r4e7"
master_plan: "docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-25T16:08:21Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-25T17:59:15Z
      mode: "implement"
      note: "M1 prototype run"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-25T19:25:59Z
      mode: "implement"
      note: "M2 and M3 implemented; M5 retirement needs a collection decision"
---

# Serve a wildcard content domain from one worker with the Host header intact

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements part of IR-55,
[`docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md`](../improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md),
requested by `mori://shinzui/hanmoto` (specification `mori://shinzui/hanmoto/docs/initial-spec`,
sections 5, 6 and 9). It is a child of [MasterPlan 39](../masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md), which holds the order of the four
child plans and the artifacts they share.

Prerequisite: milestone M1 of [283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md](283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md) is accepted. It provides `reviewEffects` on
`ReviewDocument` (`cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs`), printed under "This
review removes:", which M5 here fills. Nothing else from that plan is needed.


## Purpose / Big Picture

A service that serves untrusted HTML must serve it from a different registrable domain than the
application, so the browser never sends application or login cookies with it, and from one
subdomain per document, so each document is its own browser origin. Nagare can route only exact
hosts today, each as a Knative `DomainMapping`, which also replaces the `Host` header.

After this plan a context lists its content domains, and one worker of an application declares
that it serves `*.D` and fixed hosts under `D`. Every request reaches that worker with its original
`Host` header under one wildcard certificate, issued by DNS-01 on a cloud context.

```bash
curl -sS https://alpha.CONTENT_DOMAIN/whoami https://beta.CONTENT_DOMAIN/whoami https://share.CONTENT_DOMAIN/whoami
```

```text
host=alpha.CONTENT_DOMAIN
host=beta.CONTENT_DOMAIN
host=share.CONTENT_DOMAIN
```


## Progress

- [x] M1 (prototype, local, nothing committed but the transcript). Kourier serves a hand-written
  Knative `Ingress` with a wildcard host over TLS to a plain Service with the `Host` header intact,
  and the effect of a second overlapping host on Envoy is known. A failure stops the plan.
  - 2026-11-25: passed. Knative Serving and net-kourier 1.22.0 from the vendored manifests with
    `knative-serving/config-network.yaml`, on a throwaway k3d cluster (k3s v1.34.6), then deleted.
    The Ingress had the shape in Plan of Work: class `kourier.ingress.networking.knative.dev`, hosts
    `*.content.test` and `content.test`, `ExternalIP`, `httpOption: Redirected`, one `tls` entry
    and one split to a plain ClusterIP Service with no `rewriteHost`. Two things differ from the
    plan's wording and do not bear on the question: the certificates came from a private CA made
    with `openssl`, not from the `nagare-local-ca` ClusterIssuer, and the backend answers at
    `/cgi-bin/whoami`. Requests went to Kourier's Service address with the CA verified.

    ```text
    == part 1: wildcard Ingress
    Ready=True
    alpha.content.test -> host=alpha.content.test served-by=wildcard-ns
    beta.content.test -> host=beta.content.test served-by=wildcard-ns
    content.test -> host=content.test served-by=wildcard-ns
    http redirect: 301 https://alpha.content.test/cgi-bin/whoami
    unlisted other.test: curl: (35) Recv failure: Connection reset by peer
    == part 2: an overlapping exact host in another namespace
    Ready=True
    x.content.test -> host=x.content.test served-by=exact-ns
    x.content.test certificate: *  subject: CN=exact
    alpha.content.test -> host=alpha.content.test served-by=wildcard-ns
    == part 2b: change an unrelated route and confirm Kourier still applies it
    a third, unrelated Ingress: Ready=True
    elsewhere.test (certificate not checked) -> host=elsewhere.test served-by=third-ns
    beta.content.test -> host=beta.content.test served-by=wildcard-ns-v2
    x.content.test -> host=x.content.test served-by=exact-ns
    == kourier controller errors
    0
    ```
- [ ] M2. A context lists content domains; on a cloud context the Pulumi program owns each
  domain's zone, its wildcard and apex records and the solver's grant. Evidence: `nagarectl` and
  `npm test` tests.
  - 2026-11-25: done. `NAGARE_CONTENT_DOMAINS` is `contentDomains` on the profile, read from the
    context file (`Nagare.Target.ContentDomains`, with `ContentDomain` in
    `cli/nagare-dsl/src/Nagare/Dsl/ContentDomain.hs`); loading refuses a domain equal to, under or
    containing the base domain, a repeat, two domains whose zone names collide, and a name over 48
    characters (the zone name `nagare-content-<slug>` must fit Cloud DNS). A direct cloud context
    seeds `nagare:contentDomains`; a tunnel context seeds nothing and the program throws if it
    gets one. `NagareContentDomain` (`infra/pulumi/src/components/`) is one zone, `*.D` and `D`
    A records to the VM address and `roles/dns.admin` on that zone for the VM account; the catalog
    template `contentDomainEnabled` (`{domain}` is the slug, layers 21-23, above every other
    section) is instantiated by `withContentDomains` at both catalog sites. No stack output, so an
    existing stack previews unchanged. `domains list|check` prints each zone's name servers and
    whether public resolvers delegate the domain to them; `check` fails while they do not.
    Evidence: nagarectl `content domain context` (7 tests); `npm test` with the new
    `contentDomainResources` test and the parity test's content-domain and tunnel variants;
    `just gate-commit` green.
- [ ] M3. A worker declares an HTTP port and a content route; the application scope gains a
  Service, a Certificate and an Ingress; the compile refuses an unlisted domain, a tunnel context
  and a conflicting host; no other application's members change. Evidence: `nagare-dsl` and
  interpreter tests.
  - 2026-11-25: done but for `domains list`. `Worker` has `http :: Maybe WorkerHttp` (port and an
    optional `ContentRoute`, in `cli/nagare-dsl/src/Nagare/Dsl/ContentDomain.hs`); its JSON key is
    omitted when absent, so no earlier golden or config digest moved, and the loader refuses a route
    without a readiness probe. `Nagare.Dsl.Worker.Content` renders the Service, the Certificate
    (label `nagare.dev/content-domain`) and the Ingress of the M1 shape; the Deployment gains a
    named `http` container port. `Inventory/Application/ContentRoute.hs` compiles them into the
    application scope (Ingress after Certificate and Service, alias `Hostname D`, issuer
    `letsencrypt-dns` or `nagare-local-ca` by mode) and refuses `content-domain-not-listed`,
    `content-route-needs-direct-ingress` and `content-domain-claimed` (the app's own host under
    `D`, two workers on one domain). The composition refuses `content-domain-claimed` for any other
    member's host under a content Ingress's domain, and `claim-conflict` for its apex. A standalone
    worker with a port is refused (`worker-http-needs-application`). The Ingress is ready at
    `observedGeneration == generation` and `Ready=True`. The certificate policy expects a
    labelled content certificate for a listed domain, covering exactly `*.D` and `D`, in an app
    namespace. The example's gateway serves the context's first content domain. Evidence:
    nagare-dsl `content route (EP-285)` (9, two new goldens; 577 pass); nagarectl `content route`
    (8) and the policy case in `certificate policy`; `just gate-commit` green. Open: `domains list`
    does not yet show the route's hosts.
- [ ] M4. Two subdomains and a fixed host reach the worker with their own `Host` header under a
  valid wildcard certificate: on a local context under the local CA, and on a disposable cloud
  context under a DNS-01 certificate. Evidence: transcripts here (IR-55 AC-3).
- [ ] M5. Retiring a content route is a review that names the hosts that stop being served and the
  certificate key that is destroyed. User documentation and the ADR 20 amendment exist. Evidence:
  reviewed-change tests (IR-55 AC-5, domain).


## Surprises & Discoveries

- Envoy accepts an exact host under another Ingress's wildcard and gives the exact host its
  requests and its own certificate; the wildcard keeps every other host, and Kourier goes on
  applying unrelated changes with no error (M1 transcript, part 2). An overlap is therefore not a
  fault Kourier reports: without the claim rule, a second scope could take one host of a content
  domain from the worker that owns the wildcard. M3's rule stands as written, a wildcard claim
  excludes every other host under `D`, and the compile is the only place that enforces it.

- M5 as written needs deletion, which the inventory does not yet offer for these kinds
  (2026-11-25). A review's retirement (`ApproveRetirement`, `decideMemberRetirement` in
  `cli/nagarectl/src/Nagare/Inventory/Lifecycle.hs`) keeps the object live, so a retired Ingress
  would go on serving `*.D`; only an `ApproveCollection` deletes, and
  `collectionKinds` (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesCollection.hs`) admits
  neither a Kourier Ingress nor a cert-manager Certificate, and nothing collects the Secret
  cert-manager writes. Before M5's code, decide whether the route's retirement collects the
  Ingress, the Certificate and its Secret in the same review (adding the two kinds to collection,
  with the kind table's `KindCollect` and a mutation record), or retires them and states that the
  hosts stay served until a collect.

## Decision Log

- Decision: A content route is served through a Nagare-authored Knative `Ingress` and a
  Nagare-authored cert-manager `Certificate`, not a `DomainMapping`.
  Rationale: A `DomainMapping` is named after its host, so it cannot be a wildcard, and upstream
  Knative makes it rewrite `Host` to the target Service's internal name. M1 tests the replacement.
  Date: 2026-11-25

- Decision: The route's target is a worker with an HTTP port, never the application's Knative
  Service.
  Rationale: A worker is a plain Deployment that Kourier can reach through a ClusterIP Service. A
  Knative Service is reached through its own routing layer, which is what rewrites the host. The
  cost is that a content workload never scales to zero.
  Date: 2026-11-25

- Decision: A content domain is a context property, `NAGARE_CONTENT_DOMAINS`, and the context owns
  its Cloud DNS zone. An application claims one listed domain.
  Rationale: Delegating a registrable domain to the zone's name servers is an operator act at a
  registrar. The DNS-01 solver's write grant is per zone
  (`infra/pulumi/src/components/NagarePerimeter.ts`).
  Date: 2026-11-25

- Decision: A content domain must not equal, contain or be contained in the base domain.
  Rationale: The login cookie's domain is `.` plus the base domain
  (`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`); isolation is the point of the feature.
  Date: 2026-11-25

- Decision: Fixed hosts must be the content domain itself or one label below it, and a content
  route never passes the login enforcer.
  Rationale: The certificate for `*.D` and `D` then covers every host. The enforcer's backend map
  matches exact hosts only (`cli/nagare-access/src/Nagare/Access/BackendMap.hs`).
  Date: 2026-11-25

- Decision: A context that serves through a Cloudflare Tunnel refuses a content route.
  Rationale: The tunnel's ingress rules are fixed to the base zone and the cluster holds no
  Cloudflare DNS credential (ADR 20, ADR 34).
  Date: 2026-11-25


- Decision: The model world keeps the Kourier `Ingress` and the cert-manager `Certificate` as
  documented-limit kinds; M3's tests stop at the compile, the composition and the readiness
  predicate, and M4's native runs confirm the two controllers.
  Rationale: An in-line kind must replay traces recorded from a real cluster
  (`docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh`), which records neither
  net-kourier nor cert-manager; recording them is a project of its own. The adapter path for both
  kinds is the generic Kubernetes apply and observe, already in line; only the Ingress readiness
  predicate is new, and it has a unit test.
  Date: 2026-11-25

## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Nagare runs applications on one k3s node: a GCE VM running NixOS on a cloud context, or a k3d cluster
on a local context (`mode=local`). An application is a typed Haskell program, `nagare/Config.hs`,
that prints JSON documents. `nagarectl` loads them, compiles them into reviewed inventory scopes,
and applies a saved review with `nagarectl inventory apply DIR --yes`.

Terms used below:

- A scope is a set of resources with one owner and its own revision history
  (`cli/nagare-dsl/src/Nagare/Resource/Types.hs`: `ScopeKind = Platform | Application | Standalone
  | Publication`). A standalone scope holds one data service, such as an app database
  (`cli/nagare-core/src/Nagare/Inventory/AppDatabase.hs`, `compileStandaloneAppDatabase`).
- A managed resource is `ManagedResource` in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`: an identity, an owner scope, an executor
  (`KubernetesExecutor`, `PulumiExecutor` and others), a provider address, a lifecycle policy
  (`Retain | DeleteWhenUnreferenced | Protect`) and a data policy (`Stateless | Durable`).
- A review is the saved plan, `review.json` (`ReviewDocument` in
  `cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs`). Its `--contract 1` projection is
  `SavedReview` in `cli/nagare-contract/src/Nagare/Contract/V1.hs`.
- Retirement removes a resource from the desired state under an explicit decision
  (`ApproveRetirement`). Removing a member without one refuses with `retirement-required`
  (`cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`). Retirement deletes nothing at the
  provider; deletion is a separate `inventory collect` review that refuses durable data.
- A credential template is a reviewed Secret with no data. The adapter fills it with generated
  values at creation and afterwards compares only its key set
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`). A `Delegation`
  (`cli/nagare-dsl/src/Nagare/Resource/Policy.hs`) names another writer allowed to change fields.
- The interpreter tests run the real planner, executor and adapters against an in-memory world
  (`cli/nagarectl/test/Nagare/Test/World/`). New `*Spec` modules are registered in
  `cli/nagarectl/test/Nagare/Test/Suite.hs`.

The application model (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) has one web workload,
`service :: Maybe Deployment` (a Knative Service, `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), plus
`workers :: [Worker]` (plain Deployments, `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) and
`tasks :: [Task]` (CronJobs, `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`). Workloads are named by their
`ServiceName`. In Hanmoto's shape the API is the `service` and the gateway is a worker.

Hosts today. A host is a `Domain` in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`; `mkDomain` rejects
wildcards. Each `DomainSpec` of a web workload becomes a Knative `DomainMapping` named after the
host (`renderDomainMappings` in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`; `compileDomain` in
`cli/nagarectl/src/Nagare/Inventory/Application/Service.hs`), bound with an inventory alias
`Hostname host`, which is how two scopes are stopped from claiming one host.
`cli/nagarectl/src/Nagare/Domain/Binding.hs` refuses a host another namespace holds. A worker has
no port and no host.

Data plane. Kourier (an Envoy-based Knative ingress) serves ports 80 and 443 in both ingress modes
(`NAGARE_INGRESS` is `direct` or `cloudflare-tunnel`,
`cli/nagarectl/src/Nagare/Target/Kinds.hs`). Kourier is driven only by Knative `Ingress` objects
(`networking.internal.knative.dev/v1alpha1`, installed from
`cluster/bootstrap/vendor/serving-crds-v1.22.0.yaml`), which Knative writes for its own Services
and DomainMappings. Nagare authors none today. A past defect, F34
(`docs/plans/155-*.md`), matters: one host present in two Kourier TLS filter chains made Envoy
reject every update in the cluster.

TLS. One cert-manager ClusterIssuer, `letsencrypt-dns`
(`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`), with one solver: DNS-01 on Cloud DNS
using the VM's identity. The VM account holds `roles/dns.admin` on the platform zone only and
project-level `roles/dns.reader` (`NagarePerimeter.ts`), so it cannot write a challenge record in
any other zone. A local context signs with the `nagare-local-ca` issuer
(`cluster/bootstrap/local-tls/`), with no challenge. The issuer mode is `IssuerMode` in
`cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs`. `nagarectl cluster certificate-policy`
(`cli/nagarectl/src/Nagare/Cluster/CertificatePolicy.hs`) flags a public wildcard certificate in a
namespace without the label `nagare.dev/app-namespace=true` or on an unexpected issuer.
`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs` decides when a routing object
is ready.

DNS. The context declares one base domain, `NAGARE_BASE_DOMAIN`
(`cli/nagarectl/src/Nagare/Target.hs`, mirrored in `scripts/lib/target.sh`). Pulumi creates its
managed zone and the `*` and apex A records; resources must be named in
`infra/pulumi/resource-catalog.json`, which `cli/nagarectl/src/Nagare/Inventory/Cloud.hs` compiles
into the `platform:cloud` scope. `nagarectl domains list|check`
(`cli/nagarectl/src/Nagare/Ops/Domains.hs`) reports DNS and certificate state per host.

A stale claim to correct: `docs/user/config-reference.md` and `docs/user/cluster-bootstrap.md` say
automatic TLS works for any Cloud DNS zone in the project and is checked before deploy. The check
was removed in commit 097f7caf and the solver's grant does not allow it.

Relevant ADRs:

- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): the zone
  is created only by the guarded Pulumi path.
- [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md): a public wildcard spends
  rate budget and publishes names, so it needs an opt-in. Here the opt-in is the context listing
  the domain plus a label on the Certificate.
- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md): one base domain per
  context, Pulumi owns its records, no external DNS credentials. Amended by M5: content domains
  are additional context-owned Cloud DNS zones, not additional base domains, and carry no login.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): M3's
  interpreter tests precede M4's runs.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md): login protection
  is per exact host. A content route is always public at the platform; the application authorises.
- [ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md): the
  tunnel serves one zone.

Module line caps (`scripts/check-haskell-architecture.py`,
`scripts/haskell-size-allowances.json`) will force new modules; create them up front. A new CLI
command is registered in `scripts/audit-managed-commands.py` and
`docs/architecture/managed-resource-coverage.md`. Changes to the planner, executor or adapters need
`just mutation-check REV BASE` before landing.


## Plan of Work

### M1. Prototype

On a disposable `mode=local` context built per
[`docs/user/local-development.md`](../user/local-development.md), apply by hand in an application
namespace: a Deployment and ClusterIP Service whose `/whoami` prints `host=` and the request's
`Host` header; a `Certificate` from the `nagare-local-ca` ClusterIssuer for `*.content.test` and
`content.test`; and a Knative `Ingress` with the annotation
`networking.knative.dev/ingress.class: kourier.ingress.networking.knative.dev`, one rule with hosts
`*.content.test` and `content.test`, visibility `ExternalIP`, `httpOption: Redirected`, a `tls`
entry naming those hosts and the Secret, and one path whose split sends 100 percent to the Service
with no `rewriteHost`.

Pass: the Ingress reports Ready, and `alpha`, `beta` and the apex each print their own host over
HTTPS with the local CA. Then, in a second namespace, add another such Ingress for
`x.content.test` with its own certificate, change an unrelated existing route, and confirm Kourier
still applies it. Record which of the two Ingresses serves `x.content.test`.

If the first part fails, stop: record the failure against the first Decision Log entry and in
MasterPlan 39. The overlap result sets M3's claim rule: if Envoy rejects or misroutes the overlap,
a wildcard claim excludes every other host under `D`; if it is harmless, the rule still excludes
them, and the result is recorded only as evidence.

### M2. The context's content domains

Add `NAGARE_CONTENT_DOMAINS`, a comma-separated list, to the profile in `Target.hs` and
`scripts/lib/target.sh`, to `nagare.target.env.example` and `nagare.local.env.example`, and to
`docs/user/reference.md`. Loading refuses a domain that equals the base domain, is under it, or
contains it, and a duplicate.

On a cloud context, derive the Pulumi config key `nagare:contentDomains` from the profile, add
catalog templates and their expansion in `Cloud.hs`, and extend `NagarePerimeter.ts`: per domain a
`gcp.dns.ManagedZone`, A records for `*.D` and `D` to the address the base records use, and a
`DnsManagedZoneIamMember` giving the VM account `roles/dns.admin` on that zone. A tunnel context
and a local context create none. Tests: `infra/pulumi/test/` for the records and the grant, the
catalog parity test, and the profile refusals. `nagarectl domains check` reports, for each content
domain, the zone's name servers and whether the public delegation matches.

### M3. The typed route and its compile

Types. In `Types.hs` add `ContentDomain` with `mkContentDomain` (a plain multi-label DNS name; the
wildcard is implied). In `Worker.hs` add `http :: Maybe WorkerHttp`. Adding a strict field means migrating every literal of that record in the libraries,
tests, `cluster/examples/` and `fixtures/inventory-release/`. The new JSON key is omitted when
empty so no accepted config digest moves, as `managedEnv` did; a regression fixture proves a
pre-change Application encodes to the same bytes. The other child plans of MasterPlan 39 add
fields to the same records, so rebase on the landed tree before migrating. `mkContentRoute`
refuses a fixed host that is not `D` or one label below it. A worker with a content route must
declare a readiness probe.

Rendering. A worker with `http` renders a ClusterIP Service named after the worker, selecting its
pods, in `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`. A content route renders, in the worker's
namespace, a `Certificate` `nagare-content-<worker>` with DNS names `*.D` and `D`, the label
`nagare.dev/content-domain: D` and an `issuerRef` supplied by the compiler, and a Knative `Ingress`
`nagare-content-<worker>` of the M1 shape whose hosts are `*.D`, `D` and nothing else (the fixed
hosts are covered by them and are recorded for claims and documentation).

Compile. Add `cli/nagarectl/src/Nagare/Inventory/Application/ContentRoute.hs`, called from the
application compile (`Compile.hs`). It refuses: `content-domain-not-listed` when the context does
not list `D`; `content-route-needs-direct-ingress` on a tunnel context; `content-domain-claimed`
when any other scope holds a host equal to or under `D`, or this application's own `domains` do.
It binds the Ingress with aliases `Hostname "*.D"` and `Hostname "D"`, and extends the hostname
conflict check so a wildcard alias conflicts with every host under it. It sets the issuer from the
context's `IssuerMode` and orders the Ingress after the Certificate and the Service.

Readiness and policy. In `KubernetesReadiness.hs` the Ingress is ready when its status is Ready
and the Certificate's `Ready` condition is true; a failed challenge surfaces the Certificate's
message. In `CertificatePolicy.hs` a public wildcard certificate is expected when it carries the
`nagare.dev/content-domain` label and the value is a listed content domain. `Ops/Domains.hs` lists
the route's hosts with their certificate state.

Tests: goldens for the three objects in `cli/nagare-dsl/test/`; a new
`cli/nagarectl/test/ContentRouteSpec.hs` for each refusal, a second application claiming
`x.D`, the certificate landed but not ready, a lost acknowledgement on the Ingress create, and
that adding the route leaves every other scope's digest unchanged.

Add the gateway worker's `http` and content route to
`cluster/examples/content-app/nagare/Config.hs` (create the file with a web service and the worker
if the sibling plan has not).

### M4. Confirmations

Local, after [`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md): set
`NAGARE_CONTENT_DOMAINS=content.test` on a disposable local context, deploy the example with a
fixture image serving `/whoami`, and run the local commands in Concrete Steps.

Cloud, with the operator's go-ahead for the bounded sequence, on the disposable cloud context they
name and a real domain they delegate to the new zone: the cloud review (zone, records, grant), the
delegation at the registrar, then the application review. MasterPlan 39 suggests sharing the
go-ahead and the context with the cloud-identity plan's run.

### M5. Retirement, documentation and the ADR

Removing a worker's content route without a decision keeps the `retirement-required` refusal.
`nagarectl app deploy ... --retire-content-route WORKER` approves it and fills `reviewEffects`:
the hosts `*.D` and `D` stop being served, and the certificate `nagare-content-<worker>` and its
private key are destroyed. The Certificate, its Secret, the Ingress and the Service are stateless
and deletable. The zone is the context's and stays; removing a domain from
`NAGARE_CONTENT_DOMAINS` is refused while a route claims it. Tests assert the lines and the
refusals.

Write `docs/user/content-domains.md` (declaring, delegating, what the workload receives, the
tunnel refusal, that the worker never scales to zero) and a capability page; update
`config-reference.md`, `choosing-ingress.md` and `CLAUDE.md`'s list of canonical variables; correct
the stale TLS claim named in Context. Amend ADR 20 per `.claude/skills/exec-plan/ADR.md`.


## Concrete Steps

All commands run from the repository root.

```bash
just gate-commit                 # per Haskell commit
just mutation-check HEAD BASE    # before landing planner, executor or adapter changes
just gate-fast && just land HEAD
```

```bash
(cd infra/pulumi && npm test)    # after Pulumi changes
```

Local confirmation (M4). `local-ca.pem` is the `nagare-local-ca` certificate, exported as
[`docs/user/local-development.md`](../user/local-development.md) describes.

```bash
for h in alpha beta share; do
  curl -sS --cacert local-ca.pem --resolve "$h.content.test:443:127.0.0.1" "https://$h.content.test/whoami"
done
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve alpha.content.test:80:127.0.0.1 http://alpha.content.test/whoami
```

Expected:

```text
host=alpha.content.test
host=beta.content.test
host=share.content.test
301 https://alpha.content.test/whoami
```

Cloud confirmation (M4), on context `CTX` with content domain `D`:

```bash
nagarectl --context CTX domains check
curl -sS "https://alpha.$D/whoami" "https://beta.$D/whoami"
echo | openssl s_client -connect "alpha.$D:443" -servername "alpha.$D" 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName
nagarectl --context CTX cluster certificate-policy
```

Expected: the delegation reported as matching; the two hosts echoed; an issuer from the context's
ACME directory with `DNS:*.D, DNS:D`; and no policy finding. Record both transcripts under
Progress.


## Validation and Acceptance

IR-55 AC-3: M4's two transcripts (two subdomains, own `Host`, valid wildcard certificate, DNS-01 on
the cloud context) and M3's test that no other scope's digest changes. AC-5 (domain): M5's tests.

The plan is accepted when `just gate-fast` is green on the landed commit, the post-land full gate
is green, and the M1 and M4 transcripts are under Progress.


## Idempotence and Recovery

Every change is a saved review. A certificate that cannot be issued (usually a missing delegation)
leaves the Ingress unready and the application review stopped with the Certificate's message; fix
the delegation and retry the same review. Nothing else in the application is ordered after the
route, so the rest of the application converges. The zone and its records are additive. Because of
F34, do not hand-apply overlapping Ingresses on a shared cluster: M1 uses a disposable context.
Delete the disposable contexts to clean up; the cloud context's zone goes with its reviewed
teardown.


## Interfaces and Dependencies

In `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`:

```haskell
data ContentRoute = ContentRoute
  { domain :: !ContentDomain   -- serves *.domain and domain
  , fixedHosts :: ![Domain]    -- the domain itself or one label below it
  }
  deriving stock (Generic, Eq, Show)

data WorkerHttp = WorkerHttp
  { port :: !Port
  , content :: !(Maybe ContentRoute)
  }
  deriving stock (Generic, Eq, Show)

-- new field on Worker
--   , http :: !(Maybe WorkerHttp)
```

The Ingress this plan authors:

```yaml
apiVersion: networking.internal.knative.dev/v1alpha1
kind: Ingress
metadata:
  name: nagare-content-content-gateway
  annotations:
    networking.knative.dev/ingress.class: kourier.ingress.networking.knative.dev
spec:
  httpOption: Redirected
  tls:
    - hosts: ["*.content.example", "content.example"]
      secretName: nagare-content-content-gateway
      secretNamespace: personal
  rules:
    - hosts: ["*.content.example", "content.example"]
      visibility: ExternalIP
      http:
        paths:
          - splits:
              - serviceName: content-gateway
                serviceNamespace: personal
                servicePort: 8080
                percent: 100
```

New context variable `NAGARE_CONTENT_DOMAINS`; derived Pulumi key `nagare:contentDomains`. The
workload receives the original `Host` header on its declared port and must treat every request as
unauthenticated.

External behaviour relied on: Kourier accepts wildcard hosts in an `Ingress` rule and its `tls`
entry (M1); cert-manager's Cloud DNS solver finds the zone for `D` among the project's zones (M4,
cloud).
