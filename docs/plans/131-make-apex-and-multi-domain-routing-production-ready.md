---
id: 131
slug: make-apex-and-multi-domain-routing-production-ready
title: "Make apex and multi-domain routing production-ready"
kind: exec-plan
created_at: 2026-09-14T02:27:03Z
intention: "intention_01m2evnr81eg5bvvjy2s63m4ny"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T02:27:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T20:01:10Z
      mode: "implement"
      note: "Implemented strict shared domain model and began milestone execution"
---

# Make apex and multi-domain routing production-ready

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare already renders more than one Knative `DomainMapping` for an application, but the
surrounding platform does not yet make that capability dependable. The exact apps base domain
(for example `apps.example.com`) has no DNS address record, the three workload kinds disagree on
which domain is canonical, malformed and duplicate hostnames pass the typed constructor, deploys
do not detect a hostname already owned by another application, and `nagarectl domains list`
reports a computed DNS expectation that is wrong for the base-domain apex. Google Cloud CDN adds
another correctness hole: its load balancer accepts many deployed hostnames while its edge
certificate contains only the base domain.

After this plan, an operator can deploy an ordinary application, static site, or server site whose
canonical hostname is the exact base domain and use it as the platform landing page. Every
workload kind can declare several strictly validated hostnames with exactly one canonical entry.
The base-domain apex resolves to the origin, or to the Google CDN when that standing edge is
enabled; Knative refuses a conflicting claim before any app manifest is changed; and domain
inventory reports actual public DNS, route ownership, and actionable certificate state. Google
CDN serves a valid certificate for the apex and every supported first-level hostname below the
base domain.

The result is visible without trusting implementation details. A local smoke test deploys one
site at three loopback hostnames and verifies all three routes and their certificates. A cloud
acceptance run deploys a landing site at the exact base domain, observes an exact apex `A` record,
receives HTTP 200 with a trusted certificate, and shows `nagarectl domains check` returning zero.
The same check exits non-zero with a specific explanation after a fixture introduces a DNS target
mismatch or a conflicting domain claim.

This plan deliberately does not add multiple platform base domains, automatic management of an
unrelated registrar's DNS, or HTTP redirects from non-canonical to canonical hostnames. An
unrelated hostname remains supported through a `DomainMapping`, but its DNS and certificate solver
must be configured by its owner. A Google CDN hostname must be either the base apex or one label
below it; Cloudflare remains the supported CDN for unrelated zones. These boundaries keep the
change implementable and make the supported combinations explicit rather than silently broken.


## Progress

- [x] (2026-09-14T20:01Z) M1: Made one strict, canonical domain model serve `Deployment`, `StaticSite`, and `ServerSite`, with backward-compatible JSON decoding and migration documentation. `nagare-dsl` passed 401 tests, `nagarectl` passed 527 tests, documentation validation passed, Haskell style passed in the Nix shell, and all 33 compatible `nix flake check` checks passed.
- [x] (2026-09-14T20:12Z) M2: Added fail-closed hostname-ownership preflight, managed metadata, and per-DomainMapping readiness waits to all production deploy paths. Hermetic tests prove conflicts and unreadable ownership perform zero applies while same-owner redeploys proceed; `nagarectl` passed 534 tests, `nagare-dsl` passed 401 tests, all executables built, documentation/style checks passed, and every compatible flake check passed.
- [x] (2026-09-14T20:28Z) M3: Added a pure, fully truth-tabled apex/wildcard target resolver; two Pulumi-owned RRsets; exported `apexIp`; a TCP Kourier health check; and an executable Pulumi mock proving the distinct records. `npm test`, the `infra-domain-topology` Nix check, documentation/style validation, all 535 `nagarectl` tests, and every compatible flake check passed; the infrastructure guard still refuses zone replacement but permits an apex RRset target update.
- [x] (2026-09-14T20:49Z) M4: Replaced guessed status with typed DNS, route, TLS-mode, issuer, and certificate observations; added real `dig` probes, `domains list --json` schema version 1, and the non-zero `domains check` gate. Recording fixtures cover NXDOMAIN, missing/failed tools, apex mismatch, wildcard and CDN success, disabled TLS, pending/failed ACME, and a fully ready inventory. All 539 tests, all executables, docs/style validation, and every compatible flake check passed.
- [x] (2026-09-14T21:35Z) M5: Added fail-closed origin-TLS preflight and readiness polling for automatic and supplied-secret modes, a three-host fixture, and local/cloud acceptance runners. The local runner proved trusted TLS for the apex, `www`, and `alternate` hosts, an exact apex canonical URL, and a green `domains check`; the environment-changing staging ACME runner remains intentionally gated until an authorized cloud context is supplied.
- [x] (2026-09-14T21:35Z) M6: Added the explicit `legacy`/`prepare`/`certificate-map` migration, Certificate Manager DNS authorization, apex and wildcard certificate-map entries, an ACTIVE-state activation guard, constrained Google CDN hostname planning, and convergent project-pinned Cloud DNS mutation. Pulumi compilation and all four hermetic TypeScript tests passed.
- [x] (2026-09-14T21:35Z) M7: Added the operator documentation, migration procedures, production runbook guidance, cloud acceptance runner, and ADR 20. The final matrix passed 401 `nagare-dsl` tests, 552 `nagarectl` tests, Pulumi compilation/tests, Haskell style, documentation validation, focused infrastructure and shell checks, and all 32 compatible `nix flake check` checks on `aarch64-darwin`.


## Surprises & Discoveries

- The platform creates only `*.<baseDomain> A`, while DNS wildcard synthesis cannot answer the
  already-existing zone-apex node. Nevertheless `dnsExpectationFor` deliberately classifies the
  apex as `UnderWildcard`, and its unit test locks in that error. Evidence:
  `infra/pulumi/src/components/NagarePerimeter.ts` creates only the wildcard record at lines
  194–202, while `cli/nagarectl/src/Nagare/Ops/Domains.hs` handles `domain == baseDomain` as
  `UnderWildcard` at lines 152–161. RFC 4592 explains that a zone apex exists because it owns its
  SOA and NS records and therefore is not synthesized from a descendant wildcard. Date:
  2026-09-13.

- The word “canonical” has two different implementations. `Deployment` uses `DomainSpec` and
  finds the marked entry, while `StaticSite` and `ServerSite` store `[Domain]` and report the first
  entry as the URL. Evidence: `cli/nagarectl/src/Nagare/Deploy.hs` uses `canonicalDomain`, but
  `cli/nagarectl/src/Nagare/Static/Deploy.hs` and
  `cli/nagarectl/src/Nagare/Server/Deploy.hs` pattern-match `(d : _)`. Date: 2026-09-13.

- The current `mkDomain` is not hostname validation. It accepts uppercase text, leading or
  trailing hyphens, empty labels, a trailing dot, duplicate normalized names, wildcard names, and
  values longer than Kubernetes' DNS-subdomain limit. It checks only empty text, a literal space,
  and `://`. Date: 2026-09-13.

- Origin TLS and CDN edge TLS are separate systems. Knative/net-certmanager controls the
  certificate between a direct client (or CDN origin connection) and Kourier. Google Certificate
  Manager controls the certificate presented by Google's external load balancer. Fixing one does
  not fix the other. The current `NagareCdn` accepts per-host DNS rewrites but creates one legacy
  compute certificate whose only SAN is `baseDomain`. Date: 2026-09-13.

- Official Knative documentation says a `DomainMapping` maps one non-wildcard hostname and needs a
  `ClusterDomainClaim`; Nagare enables automatic claims because it is single-tenant. Official
  external-domain TLS documentation describes per-service certificates and per-namespace
  wildcard certificates as mutually exclusive modes. Nagare's local EP-85 evidence additionally
  observed an exact per-host certificate for an explicit `DomainMapping` while namespace wildcard
  mode was enabled. M5 therefore preserves the current configuration but requires observable tests
  for both automatic service URLs and explicit mappings instead of relying on either description
  alone. Date: 2026-09-13.

- Mori was consulted first as required by the repository instructions. `mori registry search
  knative`, `mori registry search cert-manager`, and `mori registry search dns` returned no
  registered dependency project, while `mori show --full` confirmed the local `cluster-bootstrap`,
  `nagare-dsl`, `nagarectl`, and `infra-pulumi` package boundaries. The dependency behavior above
  was consequently verified against the checked-in bootstrap documents and current official
  Knative and Google Cloud documentation. No new dependency version or compatibility bound is
  chosen by this plan. Date: 2026-09-13.

- The host `cabal` selected a GHC that cannot parse the repository's `MultilineStrings`
  extension, while `nix develop --command cabal ...` selected the supported GHC 9.12.4 and ran
  both suites successfully. Also, `nix fmt` fails because this flake does not expose
  `formatter.aarch64-darwin`; the explicit Fourmolu command and
  `nix develop --command just haskell-style-check` are the working format and style paths.
  Evidence: the host build returned Cabal-7107; the Nix-shell suites passed 401 and 527 tests,
  and the full flake check passed all 33 compatible checks. Date: 2026-09-14.

- A Nix flake source snapshot excludes a newly created file until Git knows about it. The first
  M2 flake check therefore failed to find `Nagare/Domain/Binding.hs` even though working-tree Cabal
  tests passed. Staging the milestone files made the source part of the flake snapshot, after which
  every compatible check passed. This is a packaging validation behavior, not a Haskell dependency
  or module-list problem. Date: 2026-09-14.

- The local Mori corpus has the Pulumi core project and Node SDK, but no registered
  `pulumi-gcp` provider project. After locating `mori://pulumi/pulumi/packages/@pulumi/pulumi`
  with Mori, the locked `@pulumi/gcp` 8.41.1 declaration in this repository confirmed that
  `gcp.compute.HealthCheck` accepts `tcpHealthCheck` with a `port`. The installed Pulumi mock
  runtime requires waiting for its RPC queue to drain before asserting on all asynchronously
  registered child resources. Date: 2026-09-14.

- The development and packaged operator environments did not contain `dig`; adding
  `pkgs.bind.dnsutils` to the default shell and the base `nagarectl` wrapper makes the observation
  dependency explicit. A Kubernetes API can also distinguish an absent optional certificate CRD
  only through command diagnostics, so the System.Process adapter classifies server “not found” /
  unknown-resource responses as `NotFound` and keeps other non-zero exits as `Unavailable`.
  Date: 2026-09-14.

- Local bootstrap documented TLS but previously enabled neither the local CA ClusterIssuer nor
  Knative external-domain TLS. The first end-to-end run also showed that domain status assumed
  Pulumi cloud outputs and a hard-coded cloud issuer even in local mode. Installing and waiting
  for the local CA, configuring Knative with that issuer, and using the loopback address as local
  DNS evidence made the documented local contract executable. Date: 2026-09-14.

- A Certificate Manager map can be created before its certificate is usable, so an operator-only
  two-step procedure is not sufficient protection against a premature edge switch. The target
  proxy input now depends on the managed certificate state and refuses `certificate-map` mode
  unless the observed state is exactly `ACTIVE`; hermetic Pulumi mocks cover both refusal and
  activation. Date: 2026-09-14.

- Cloud DNS `record-sets describe` does not have one stable absence spelling across gcloud error
  paths. Convergent provisioning recognizes `not found`, `NOT_FOUND`, “does not exist,” and HTTP
  404 diagnostics, while treating every other failed read as an error instead of risking an
  incorrect create. Date: 2026-09-14.


## Decision Log

- Decision: Treat the base-domain landing page as an ordinary workload with a `DomainMapping` for
  the exact base domain; do not add a special landing-page workload kind or fallback ingress.
  Rationale: Host routing already provides the required isolation. Keeping the landing page in the
  ordinary app lifecycle gives it the same build, rollback, access, and deletion behavior as every
  other app, while an unmatched apex can continue to return the ingress 404.
  Date: 2026-09-13

- Decision: Provision an exact apex `A` record as standing Pulumi infrastructure. Point it to the
  VM public IP when Google CDN is disabled and to the Google CDN global IP when that standing CDN
  is enabled and instantiated. Keep `*.<baseDomain>` pointed at the VM.
  Rationale: The apex is part of the platform-owned Cloud DNS zone and has no useful wildcard
  fallback. Pulumi is already the owner of that zone and its wildcard record, so it is the only
  drift-free owner for the apex. Selecting the CDN target at the infrastructure layer prevents a
  deploy-time `gcloud` command from fighting a Pulumi-owned record.
  Date: 2026-09-13

- Decision: Use one shared `DomainSpec` for all three web workload kinds. Exactly one entry in a
  non-empty list is canonical, and every entry explicitly chooses automatic TLS or a supplied
  Kubernetes TLS Secret.
  Rationale: Ordering is not a durable substitute for an explicit canonical marker, and a caller
  needs a truthful way to represent domains whose certificates are managed outside Nagare's ACME
  solver. An empty list continues to mean the automatic Knative hostname.
  Date: 2026-09-13

- Decision: Canonicalize hostnames to lowercase ASCII without a terminal dot, require RFC
  1123-compatible labels and total length, reject wildcards and IP literals, and require IDNs to be
  supplied as their ASCII A-label (punycode) form.
  Rationale: The normalized hostname becomes a Kubernetes resource name, an SNI hostname, a DNS
  owner name, and a deletion key. One byte representation prevents duplicate resources and cleanup
  ambiguity. DomainMapping itself accepts only non-wildcard domains, while wildcard ownership
  belongs to platform certificate and DNS configuration.
  Date: 2026-09-13

- Decision: Keep automatic `ClusterDomainClaim` creation because Nagare is single-tenant, but add a
  read-before-write conflict check and managed labels to every rendered `DomainMapping`.
  Rationale: Turning claim autocreation off would add an administrator step to every deploy without
  improving the single-operator threat model. A preflight provides the useful safety property: an
  app cannot silently steal or retarget another app's hostname.
  Date: 2026-09-13

- Decision: Keep automatic origin certificates for platform-managed domains, allow a supplied TLS
  Secret for externally managed certificates, and diagnose unsupported DNS authority before
  waiting for issuance. Do not embed Cloudflare credentials in the cluster in this plan.
  Rationale: Nagare's ACME issuer writes DNS-01 challenges only to Cloud DNS in the active context's
  project. Pretending it can validate an unrelated Cloudflare-hosted zone causes permanent pending
  certificates. A Secret reference supports externally issued certificates without expanding the
  cluster credential surface.
  Date: 2026-09-13

- Decision: Use Google Certificate Manager DNS authorization, one certificate containing the apex
  and `*.<baseDomain>`, and exact plus wildcard certificate-map entries for Google CDN. Introduce a
  prepare/activate migration rather than replacing the legacy certificate in one apply.
  Rationale: DNS authorization can finish before the certificate map is attached and supports a
  wildcard; load-balancer authorization cannot issue wildcards. A staged switch retains the old
  edge certificate until the new certificate is ACTIVE. Google CDN hostnames outside the managed
  base zone are rejected; Cloudflare is the supported provider for those zones.
  Date: 2026-09-13

- Decision: Do not implement canonical-host redirects or multiple platform base domains here.
  Rationale: A Knative `DomainMapping` routes but does not redirect, so a uniform redirect requires
  a new shared redirect service or workload-level behavior. Multiple base domains also change
  automatic service URLs, wildcard certificates, auth cookie scope, and context identity. Neither
  is necessary to make the apex and current multi-domain contract correct.
  Date: 2026-09-13

- Decision: Serialize `DomainTls` as a required nested `tls` object with mode `automatic` or
  `supplied-secret`; tolerate an absent object when reading the previous deployment object shape,
  and tolerate whole legacy string arrays for static/server configs.
  Rationale: One explicit shared wire shape makes TLS intent inspectable without overloading the
  hostname or canonical fields. Rejecting mixed string/object arrays avoids ambiguous canonical
  migration semantics, while the two historical homogeneous shapes continue to decode.
  Date: 2026-09-14

- Decision: Read all `ClusterDomainClaim` and all-namespace `DomainMapping` objects in one
  fail-closed ownership snapshot, and grant `nagared` only cluster-wide `get`/`list` access to
  those two resource kinds while retaining its namespaced mutation Role.
  Rationale: A per-target not-found query cannot prove that another namespace does not already
  route the same hostname, while a read-only cluster role provides the required evidence without
  broadening the webhook runner's write authority. Current Knative documentation confirms that a
  claim delegates one hostname through `spec.namespace` and that a mapping is namespace-local.
  Date: 2026-09-14

- Decision: Keep DNS selection in a dependency-free generic resolver and treat a requested CDN
  that was not constructed (for example, before the VM exists) as absent. Fail if a constructed
  CDN has no global IP.
  Rationale: `enableCdn` alone does not prove that an edge resource exists. Testing all four flag
  and existence combinations prevents an apex from receiving the disabled sentinel or an
  unavailable target, while the explicit impossible-state failure keeps future refactors honest.
  Date: 2026-09-14

- Decision: Model actual DNS, route, and certificate evidence independently from the expected DNS
  targets, and keep `domains list` tolerant while making `domains check` strict.
  Rationale: Absence and probe failure demand different remedies, and an expected record is not
  evidence that public resolvers serve it. The apex accepts only `apexIp`; a first-level hostname
  accepts either `publicIp` or the live CDN IP; unrelated/deeper names require an address but have
  no platform-owned target. Schema-versioned JSON exposes the same distinctions without column
  scraping. Globally disabled TLS remains a truthful HTTP-only state, while pending/failed/unknown
  enabled TLS fails the operational gate.
  Date: 2026-09-14

- Decision: Read the configured Knative issuer and TLS mode before every custom-domain apply,
  verify supplied Secrets by key name only, and poll certificate evidence after route readiness.
  In local mode, use the configured local CA and loopback DNS evidence without invoking gcloud.
  Rationale: The same deploy path must fail before mutation when issuance is impossible, avoid
  exposing Secret data, and report success only when every automatic hostname has a covering Ready
  certificate. Reading configuration rather than assuming issuer names keeps local and cloud
  behavior aligned.
  Date: 2026-09-14

- Decision: Retain the legacy Compute certificate in all CDN migration modes, create Certificate
  Manager resources in `prepare`, and attach the certificate map only when an explicit
  `certificate-map` selection observes the managed certificate as `ACTIVE`.
  Rationale: A Pulumi state transition is safer than resource replacement: existing stacks remain
  unchanged by default, preparation cannot interrupt traffic, and both operator intent and live
  certificate evidence are required before the serving proxy changes.
  Date: 2026-09-14


## Outcomes & Retrospective

Implementation is complete. All three web workload kinds now share one strict domain/TLS contract,
fail closed on route or certificate ownership ambiguity, and expose an exact canonical URL without
inventing redirects. Pulumi owns both apex and wildcard DNS, domain inventory reports observed DNS,
route, issuer, and certificate health, and `domains check` provides a machine gate. Origin TLS works
for automatic certificates and supplied Secrets; the local three-host fixture proved trusted TLS
end to end. Google CDN now has a non-disruptive Certificate Manager prepare/activate migration,
rejects hostnames its wildcard cannot cover, and updates supported records convergently.

ADR 20 records the durable ownership and TLS boundaries, while the user guides and runbook describe
landing pages, multi-domain configuration, supplied-certificate escape hatches, CDN migration, and
failure recovery. The repository-wide validation matrix passed. A real staging ACME/CDN exercise is
available through `scripts/test-cloud-multi-domain-tls.sh` but was not run because no authorized
cloud context was supplied; the runner requires an explicit opt-in and records no secret material.


## Context and Orientation

Nagare is a single-node platform. Pulumi provisions Google Cloud resources, Knative Serving routes
HTTP requests inside Kubernetes, and `nagarectl` turns typed Haskell configuration into Knative
objects. A **base domain** is the one suffix stored in the active context, such as
`apps.example.com`. Knative automatically assigns each Service a hostname shaped like
`<service>.<namespace>.<baseDomain>`. A **custom domain** is an exact hostname represented by a
Knative `DomainMapping`. The **apex** in this plan means the exact base domain
`apps.example.com`, not its registrable parent `example.com`. A DNS **wildcard** record named
`*.apps.example.com` answers absent descendants such as `blog.apps.example.com`; it does not answer
the already-existing `apps.example.com` apex. **Origin TLS** is the certificate served by Kourier on
the VM. **Edge TLS** is the separate certificate served by a CDN before it connects to the origin.

The typed model is in `cli/nagare-dsl`. `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` defines `Domain`,
`DomainSpec`, `mkDomain`, `mkDomains`, and the ordinary `Deployment`. Its current `mkDomain` performs
only three superficial checks. `Deployment.domains` is `[DomainSpec]`, but
`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` and
`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` use `[Domain]`. The three renderers are
`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`,
`cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs`, and
`cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`; each writes one
`serving.knative.dev/v1beta1` `DomainMapping` per configured hostname.
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` emits config JSON and
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` decodes and revalidates it. Static and server JSON currently
uses arrays of strings, while ordinary deployments use objects containing `domain` and
`canonical`. Tests and golden YAML live under `cli/nagare-dsl/test`.

Production orchestration is split between reusable modules and `cli/nagarectl/app/Main.hs`.
`runDeploy`, `deployStatic`, and `deployServer` render and apply Services and DomainMappings, but
wait only for the Service before reporting success. `cli/nagarectl/src/Nagare/App.hs` implements
app deletion and DomainMapping discovery. `cli/nagarectl/src/Nagare/Ops/Domains.hs` parses
DomainMappings and cert-manager Certificates and formats `domains list`; its DNS column is computed
without a resolver and its Kubernetes capture deliberately collapses command failure into empty
data. `cli/nagarectl/src/Nagare/Ops/Probe.hs` contains the process-capture conventions reused by
operations commands. `cli/nagarectl/test/Spec.hs`, `AppDeploySpec.hs`, and the static/server deploy
tests are the main test surfaces.

Cloud DNS is owned by `infra/pulumi/src/components/NagarePerimeter.ts`. It creates the managed zone
and one wildcard `A` record pointing at the reserved VM address. `infra/pulumi/index.ts` exposes
`publicIp`, `baseDomain`, `dnsZoneName`, and CDN references as stack outputs. The component test
pattern is the dependency-free resolver in `infra/pulumi/src/vmShape.ts` with
`infra/pulumi/test/vmShape.test.ts` and its Nix check in `nix/checks/infra.nix`. New apex-target
selection must follow that pattern so it can be proven without a cloud account.

Google CDN standing infrastructure is in
`infra/pulumi/src/components/NagareCdn.ts`. It has a global IP, a CDN-enabled backend, an HTTP
health check whose `Host` is currently the unrouted base domain, and a legacy
`gcp.compute.ManagedSslCertificate` containing only `baseDomain`. Per-app CDN actions are planned
and executed in `cli/nagarectl/src/Nagare/Cdn/Provision.hs`; they create exact Cloud DNS records for
every declared hostname but do not create edge certificates. `docs/user/cdn.md` already documents
the DNS-authority caveat between Cloudflare and Cloud DNS and must be updated, not replaced.

Origin certificate bootstrap lives in `cluster/bootstrap`. The context-rendered
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` defines a Cloud DNS DNS-01
`ClusterIssuer`. `cluster/bootstrap/net-certmanager/README.md` explains the bridge that turns
Knative certificate requests into cert-manager resources.
`cluster/bootstrap/knative-serving/config-network.yaml` selects Kourier and enables automatic
`ClusterDomainClaim` creation. `cluster/bootstrap/knative-serving/config-network-tls.yaml` enables
external-domain TLS and namespace wildcards after a real domain is delegated. Local mode replaces
the public issuer with its local CA through `cluster/bootstrap/local-tls` and is the deterministic
place to prove several exact-host certificates without spending ACME rate limits.

The prior plans `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md`,
`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`, and
`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md` explain why the current pieces
look this way. They are historical context, not prerequisites; this plan states the replacement
contract completely.

Four local ADRs constrain the implementation. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires every `gcloud` or Pulumi mutation to be pinned to and checked against the active context's
project. [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md) requires ACME contact,
directory, and project to come from the context and requires missing identity to fail before
mutation. [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) classifies replacement of
the Cloud DNS zone as protected because it changes delegated nameservers. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires cluster and infrastructure changes to ship as one versioned platform payload. The
repository's `docs/adr` directory is not an OKF bundle in `mori.dhall`, so it follows the existing
filesystem ADR convention. No cross-repository ADR is needed.


## Plan of Work

### Milestone 1 — One strict domain model

First make the in-memory and serialized contract truthful without touching a cluster. In
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, replace the permissive `mkDomain` implementation with a
normalizer and RFC 1123-compatible validator. Strip one terminal dot, lowercase ASCII input, reject
non-ASCII with an error that tells the caller to use an IDNA A-label, require at least two labels,
enforce 63 bytes per label and 253 bytes total, allow only letters, digits, and internal hyphens,
and reject wildcard and IPv4/IPv6 literals. Make `mkDomains` reject two entries that normalize to
the same hostname before it checks that exactly one is canonical.

Extend the shared model to make certificate intent explicit:

```haskell
data DomainTls
  = AutomaticTls
  | SuppliedTlsSecret !SecretName

data DomainSpec = DomainSpec
  { domain :: !Domain
  , canonical :: !Bool
  , tls :: !DomainTls
  }

mkDomains :: [(Text, Bool)] -> Either Text [DomainSpec]
withTlsSecret :: SecretName -> DomainSpec -> DomainSpec
canonicalDomain :: [DomainSpec] -> Maybe Domain
```

`mkDomains` remains the easy source-compatible constructor for ordinary deployments and assigns
`AutomaticTls`. Change `StaticSite.domains` and `ServerSite.domains` to `[DomainSpec]`. This is a
compile-time migration for their `Config.hs` files: replace `[dom]` with
`unsafeOrEither (mkDomains [(domainText dom, True)])`, or construct the list directly from text.
Update all presets, examples, fixtures, CDN hostname extraction, URL selection, access-route
resolution, and deletion code to use the marked canonical entry instead of list order.

In `Nagare.Dsl.Config` emit the same object representation for every workload kind. In
`Nagare.Dsl.Load`, accept both the new object and the legacy static/server string. For a legacy
non-empty string list, mark the first entry canonical and the rest non-canonical, all with
`AutomaticTls`, preserving the old reported-URL behavior. Re-run the smart constructors after
decoding. Update each DomainMapping renderer to add deterministic labels
`nagare.dev/managed-by: nagarectl`, `nagare.dev/service`, and `nagare.dev/canonical`, and render
`spec.tls.secretName` only for `SuppliedTlsSecret`.

Add constructor, normalization, duplicate, JSON compatibility, URL selection, and golden YAML
tests in `cli/nagare-dsl/test/Spec.hs`, `StaticSpec.hs`, `ServerSpec.hs`, and `LoadSpec.hs`.
Acceptance for this milestone is that both Haskell package suites pass, the legacy JSON fixtures
still load, and all three workload kinds render byte-identical DomainMapping metadata for the same
`DomainSpec`.

### Milestone 2 — Safe ownership and readiness

Add `cli/nagarectl/src/Nagare/Domain/Binding.hs` and expose it from
`cli/nagarectl/nagarectl.cabal`. Keep decisions pure and IO thin. Parse the cluster-scoped
`ClusterDomainClaim` for each hostname and all-namespace DomainMappings into an `ExistingBinding`,
then implement:

```haskell
data BindingTarget = BindingTarget
  { host :: !Text
  , namespace :: !Text
  , service :: !Text
  }

data BindingConflict
  = ClaimedByNamespace !Text
  | RoutedToService !Text !Text

bindingConflict :: BindingTarget -> [ExistingBinding] -> Maybe BindingConflict
preflightDomainBindings :: [BindingTarget] -> IO (Either Text ())
waitForDomainBindings :: Int -> [BindingTarget] -> IO (Either Text ())
```

An absent claim is allowed because Knative will create it. A claim for the intended namespace and
a mapping to the intended service are idempotent. Any other owner is a refusal that names the
hostname, namespace, and service. Failure to query ownership is also a refusal on a live deploy;
absence of evidence must never authorize a hostname mutation. Dry-run remains offline and prints
the bindings it would check.

Call the preflight immediately before `applyManifests` in `runDeploy`, static production deploy,
and server production deploy. After the Service becomes Ready, wait for every DomainMapping's
`Ready=True` condition with the existing command timeout convention. On timeout, read and print the
mapping's `Ready` reason/message and any matching certificate condition rather than reporting only
“wait failed.” An empty domain list is a no-op. Unit tests use injected capture/apply functions to
prove that a conflict or unreadable ownership query performs no apply, while an idempotent existing
binding proceeds.

Acceptance is a hermetic test transcript in which `other.example.test` owned by namespace `other`
causes deployment to exit non-zero before `kubectl apply`, while redeploying a mapping already owned
by the same app succeeds and waits for both Service and DomainMapping readiness.

### Milestone 3 — Exact apex DNS

Create a dependency-free `infra/pulumi/src/domainTopology.ts` with a pure resolver that selects
wildcard and apex targets from `enableCdn`, whether the CDN component exists, the VM public IP, and
the CDN global IP. The wildcard target is always the VM. The apex target is the CDN global IP only
when the standing CDN exists; otherwise it is the VM. Test the full truth table in
`infra/pulumi/test/domainTopology.test.ts` and add a matching `infra-domain-topology` derivation to
`nix/checks/infra.nix`.

Refactor `NagarePerimeter` so the optional `NagareCdn` is constructed before the exact apex record.
Keep the existing wildcard record and add a separate `gcp.dns.RecordSet` named exactly
`<baseDomain>.`, type `A`, TTL 300, whose data comes from the pure topology. Export `apexIp` from
`NagarePerimeter`, `infra/pulumi/index.ts`, and `infra/pulumi/src/outputs.ts`. Change the Google CDN
health check from an HTTP request whose Host is the possibly-unbound apex to a TCP health check on
port 80; Kourier's listening socket, not an arbitrary application route, is the standing backend
health invariant.

Update the Pulumi preview documentation and protected-resource tests. Adding the record to an
existing zone is additive. Enabling or disabling the already-opt-in CDN updates only the apex RRset
target; it does not replace the zone. A base-domain change still replaces the protected managed
zone and remains behind ADR 14's infrastructure guard.

Acceptance is the TypeScript truth-table test plus a Pulumi mock or preview fixture showing two
distinct records: `*.<baseDomain>` to `publicIp` and `<baseDomain>` to `apexIp`. No real cloud
credentials are needed for the milestone test.

### Milestone 4 — Truthful domain inventory

Redesign `Nagare.Ops.Domains` around observations rather than the current three-state guess. Keep
the existing human table but introduce enough typed state to distinguish an answer from absence
and absence from a failed probe:

```haskell
data Observation a
  = Observed !a
  | NotFound
  | Unavailable !Text

data DnsObservation = DnsObservation
  { addresses :: ![Text]
  , canonicalName :: !(Maybe Text)
  , authoritativeNameservers :: ![Text]
  }

data CertificateState
  = TlsDisabled
  | CertificatePending !Text
  | CertificateReady !Text
  | CertificateFailed !Text
  | CertificateUnknown !Text
```

Add a `Dig` adapter using `System.Process` and pure parsers for `dig +short A`, `AAAA`, `CNAME`, and
`NS`. Put `pkgs.bind.dnsutils` in the default development shell and the packaged operator
`nagarectl` PATH in `nix/haskell-packages.nix`; source-only execution may use a system `dig`, and a
missing executable becomes `Unavailable`, never an empty successful answer. Parse
DomainMapping condition reason/message, cert-manager Certificate conditions, the Knative internal
certificate objects when present, the `config-network` TLS mode, and ClusterIssuer readiness.

The base row must expect the exact `apexIp` output, not the wildcard. A one-label custom hostname
under the base expects either the wildcard VM target or an exact CDN target. A deeper or unrelated
hostname has no platform DNS expectation unless provider status supplies one. Add `--json` to
`domains list` using a versioned schema so scripts do not scrape columns.

Add `nagarectl domains check` with the same namespace and context selectors. It prints the detailed
rows and exits non-zero if a configured hostname has no public DNS answer, resolves away from its
expected ingress, has a conflicting/unready mapping, or has a failed certificate. A globally
disabled TLS mode is a warning for HTTP-only contexts, not a falsely “missing certificate” row.
`domains list` stays read-only and exits successfully when it can display partial observations;
`domains check` is the CI/operations gate.

Acceptance uses recording `dig` and `kubectl` fixtures. Tests must separately prove NXDOMAIN,
missing `dig`, command failure, apex mismatch, wildcard success, exact CDN success, TLS disabled,
pending ACME challenge, failed ACME challenge with reason, and fully ready output. The previous test
asserting that the apex is under the wildcard is deleted and replaced by the exact-record case.

### Milestone 5 — Explicit and verified origin TLS

Use `DomainTls` during preflight. `AutomaticTls` under the platform base zone is valid when
external-domain TLS and the context's `letsencrypt-dns` issuer are ready. For an unrelated hostname,
query the active project's Cloud DNS managed zones before claiming automatic support. Proceed when
the project contains an authoritative parent zone; otherwise refuse before apply with a message
that offers two valid actions: configure an appropriate cert-manager solver for that authority, or
set `SuppliedTlsSecret` to an existing TLS Secret. Every cloud read carries the active project
explicitly and follows ADR 9. Local mode does no `gcloud` call and accepts its configured local CA.

Do not make a certificate request in `nagarectl` itself. Automatic TLS remains owned by Knative and
net-certmanager; a supplied secret is referenced by the DomainMapping. Extend status parsing so a
supplied secret is checked for existence and `tls.crt`/`tls.key` keys without printing secret data.
Document that namespace wildcard certificates cover automatic Service URLs and explicit
DomainMappings may result in exact certificates. The deploy success condition is routing plus the
certificate appropriate to each `DomainTls` policy when TLS is enabled.

Extend `scripts/local-smoke.sh` or add a focused `scripts/test-multi-domain-tls.sh` that deploys one
fixture with three loopback `sslip.io` DomainMappings, waits for the local issuer, verifies each
hostname with `curl --cacert`, and confirms the canonical URL reported by all three workload kinds.
Add an environment-gated cloud test using the context's staging ACME directory and two base-zone
hostnames. It must record Certificate names and Ready conditions but no credentials.

Acceptance is three verified HTTPS responses with the same application identity and a green
`nagarectl domains check`. A fixture selecting automatic TLS for a hostname outside every
context-project Cloud DNS zone must fail before applying a DomainMapping and name the supplied
secret escape hatch.

### Milestone 6 — Multi-host Google CDN certificates

Replace the legacy `gcp.compute.ManagedSslCertificate` in `NagareCdn` with Certificate Manager,
using the `@pulumi/gcp` interfaces already present in the locked 8.41.1 dependency. Add
`certificatemanager.googleapis.com` to the shared required API list. Create one global
`gcp.certificatemanager.DnsAuthorization` for `baseDomain`, publish its returned CNAME record in the
platform Cloud DNS zone, create one Google-managed `gcp.certificatemanager.Certificate` whose SANs
are `baseDomain` and `*.<baseDomain>`, and create exact and wildcard
`CertificateMapEntry` resources in a `CertificateMap`.

Introduce `nagare:cdnCertificateMode` with `legacy`, `prepare`, and `certificate-map` values. Legacy
preserves the existing proxy. Prepare creates DNS authorization, certificate, and map alongside the
legacy proxy without changing serving. `nagarectl cdn status` must display the Certificate Manager
certificate state and print the exact activation command only after it is ACTIVE. Certificate-map
mode sets `TargetHttpsProxy.certificateMap` and removes `sslCertificates`. New contexts with Google
CDN follow prepare then activate; existing contexts default to legacy until explicitly migrated.
Invalid mode text is a Pulumi error, not a fallback.

Change `Nagare.Cdn.Provision` to reject a Google CDN hostname unless it is the base apex or exactly
one label below it, because that is the certificate and managed-zone coverage this plan provides.
Cloudflare continues to accept unrelated hostnames and uses its own edge certificates. Make Google
DNS record updates idempotent (`describe`, then create/no-op/update only the expected context-owned
record) instead of relying on `record-sets create`. All mutations remain pinned to the active
project. CDN disable restores a first-level hostname to wildcard resolution; it never deletes the
Pulumi-owned apex record.

Acceptance is a Pulumi mock/preview proving the DNS authorization, two certificate-map entries, and
mode-dependent proxy arguments; pure provisioning tests proving supported and rejected hostname
shapes; and, when a real CDN context is available, trusted HTTPS responses for both
`baseDomain` and `www.<baseDomain>` from the same global IP. The activation is retriable and cannot
remove the legacy certificate before the new certificate is ACTIVE.

### Milestone 7 — Documentation, compatibility, and durable decisions

Update `docs/user/config-reference.md`, `deploying-apps.md`, `static-hosting.md`,
`cluster-bootstrap.md`, `cdn.md`, `reference.md`, `docs/runbooks/server-operations.md`, and all
affected examples. Show a complete landing-page config using the exact base domain and a
three-domain config with one canonical name. Explain the supported DNS/TLS matrix: automatic
platform zone, supplied secret for external authority, Cloudflare edge for unrelated CDN zones,
and Google CDN only for the apex and first-level base-domain names. State plainly that canonical
currently selects the advertised URL and does not redirect.

Add a migration note for static/server config authors and Google CDN operators. Record the durable
domain-ownership, apex DNS, origin-versus-edge TLS, and CDN certificate-map decisions by creating a
new local ADR under `docs/adr` with the repository's existing numbering and frontmatter convention;
link this plan and relevant ADRs 9, 10, and 14. Do the ADR distillation only after implementation
evidence confirms the design. Finish by running package tests, Pulumi compilation and topology
tests, shell checks, documentation validation, the local multi-domain smoke, and `nix flake check`.


## Concrete Steps

Work from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. Before each milestone, inspect
`git status --short` and preserve unrelated edits. Use `apply_patch` for source and plan edits.

Run the fast Haskell loops after M1, M2, M4, and M5:

```bash
cd cli/nagare-dsl
cabal test
cd ../nagarectl
cabal test
```

The expected tail is two successful test suites with no failures. Test counts will change, so do
not encode a fixed count in acceptance evidence.

Run the Pulumi compilation and hermetic topology test after M3 and M6:

```bash
npm --prefix infra/pulumi run build
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).infra-domain-topology
```

Expected concise output from the compiled TypeScript test is:

```text
ok
```

Exercise the local system after M5. Use the repository recipes so local mode receives its loopback
context and local CA:

```bash
just local-up
just local-bootstrap
scripts/test-multi-domain-tls.sh
nagarectl domains check --all-namespaces
```

The focused script must end with output shaped like:

```text
ok: 127-0-0-1.sslip.io -> multi-domain fixture (trusted TLS)
ok: www.127-0-0-1.sslip.io -> multi-domain fixture (trusted TLS)
ok: alternate.127-0-0-1.sslip.io -> multi-domain fixture (trusted TLS)
ok: canonical URL is https://127-0-0-1.sslip.io
```

Use `just local-down` when the local cluster is no longer needed. It must remain safe to rerun after
a partial smoke failure.

For an authorized real cloud context, first use the staging ACME endpoint and preview every
infrastructure mutation:

```bash
nagarectl context show
just infra-preview
nagarectl domains check --all-namespaces --json
```

Do not run `just infra-up`, change DNS delegation, activate a CDN certificate map, or deploy a
public fixture merely because this plan lists the command. Those are environment-changing
acceptance actions and require the implementing session to have the user's authority for that
context. When authorized, capture only resource names, IPs, conditions, and HTTP status; never
capture ACME keys, Cloudflare tokens, or TLS private keys.

Run formatting and full validation before each implementation commit that closes a milestone:

```bash
nix fmt
just haskell-style-check
just docs-validate
nix flake check
```

Every implementation commit uses Conventional Commits and includes this trailer after a blank
line:

```text
ExecPlan: docs/plans/131-make-apex-and-multi-domain-routing-production-ready.md
```

Update this plan's Progress, Surprises & Discoveries, and Decision Log at every stopping point.
Record one provenance revision for the implementation session with the skill's
`record-provenance.ts` helper; do not edit provenance by hand.


## Validation and Acceptance

The finished behavior is accepted only when all of the following are observable.

An ordinary `Deployment`, a `StaticSite`, and a `ServerSite` accept the same three-host
`DomainSpec` list, report the explicitly marked canonical URL regardless of list position, render
three labeled DomainMappings, and reject duplicate normalized or invalid hostnames before emitting
JSON. Legacy static/server JSON string arrays still decode with their first domain canonical.

A live deploy reads claims before applying. A hostname owned by another namespace or Service stops
the deploy with no apply invocation. A same-owner redeploy is idempotent. Success is not printed
until every declared DomainMapping is Ready; failure includes the Knative or certificate reason.

The platform DNS zone contains both `*.<baseDomain> A -> publicIp` and
`<baseDomain> A -> apexIp`. With Google CDN absent, `apexIp == publicIp`. With it instantiated,
`apexIp == cdnGlobalIp`. Deploying a workload whose domain is exactly `baseDomain` then returns that
workload over HTTP, and over trusted HTTPS whenever the selected TLS policy is ready.

`nagarectl domains list --json` distinguishes observed, missing, and unavailable DNS; includes
mapping owner and condition; and includes TLS mode, certificate identity, and condition reason.
`nagarectl domains check` returns zero only for healthy configured routes. DNS mismatch, ownership
conflict, certificate failure, and unavailable required probes each have distinct non-zero evidence.
Globally disabled TLS is displayed as disabled rather than misreported as one missing certificate
per hostname.

Automatic TLS succeeds for all three loopback mappings in the local CA smoke. A supplied-secret
fixture renders the exact `spec.tls.secretName` and does not wait for an automatically generated
certificate. In cloud mode, asking for automatic TLS outside a Cloud DNS zone writable by the
active context fails before route mutation and explains the remedy.

In Google CDN certificate-map mode, the same global IP completes trusted TLS handshakes for the
base apex and a first-level hostname. A deeper or unrelated Google CDN hostname is rejected during
planning. Cloudflare hostnames remain accepted. The legacy-to-map transition cannot be activated
until status observes the replacement Certificate Manager certificate as ACTIVE.

Finally, `cabal test` passes in both Haskell packages, `npm --prefix infra/pulumi run build` passes,
the domain topology check prints `ok`, documentation validation passes, the focused local smoke
passes, and `nix flake check` succeeds. Environment-gated cloud/CDN evidence may be recorded as
pending only if no authorized real context is available; the plan cannot be marked fully complete
until that live acceptance is performed or the scope is explicitly revised with rationale.


## Idempotence and Recovery

Smart-constructor, JSON, rendering, and observation changes are pure and safe to rerun. Kubernetes
resources continue to use `kubectl apply`; the ownership preflight treats the intended existing
owner as success. If application succeeds but a readiness wait fails, inspect with `domains list`
or `domains check`, correct DNS/TLS, and redeploy. Never delete another namespace's
`ClusterDomainClaim` as recovery; change the requested hostname or deliberately remove the old app
through its owner.

The Pulumi apex record is a separate RRset and is additive on the first apply. Before applying to an
existing zone, use `just infra-preview`. If an operator already created an apex `A` record outside
Pulumi, import that exact record into the new resource rather than deleting it or allowing Pulumi
to replace it blindly. Verify its current target first. A failed apply can be rerun because the
record target is declarative. Disabling Google CDN moves the Pulumi-owned apex back to `publicIp`;
it must not delete the apex. Changing `baseDomain` remains a protected zone replacement and follows
ADR 14 rather than this plan's retry path.

Certificate Manager migration is intentionally staged. `legacy` is the rollback state before the
proxy switch. `prepare` creates validation and map resources without changing the serving proxy.
Only an ACTIVE replacement may move to `certificate-map`. After the switch, retain the legacy
certificate for one release so rollback means setting the mode to `legacy` and applying again.
Delete legacy resources only in a later reviewed cleanup after both apex and wildcard handshakes
have been observed. If DNS authorization is pending, leave the old proxy in place and repair the
CNAME; do not repeatedly recreate the authorization.

Domain diagnostics are read-only. A missing `dig`, `kubectl`, `gcloud`, or Pulumi output is an
explicit unavailable observation. Installing/restoring the tool and rerunning converges without
state changes. The cloud auto-TLS preflight performs only reads until all authority checks pass.

The static/server source migration is mechanical but not silently reversible: their field type
changes from `[Domain]` to `[DomainSpec]`. Preserve backward JSON decoding for at least one minor
release. If downstream source compatibility proves more important during implementation, add a
deprecated compatibility constructor or pattern in the DSL rather than weakening the unified
in-memory invariant; record that decision here.


## Interfaces and Dependencies

`Nagare.Dsl.Types` owns normalized `Domain`, `DomainTls`, and `DomainSpec`. Other DSL modules import
those types and must not reimplement hostname parsing or choose canonical entries by position.
`mkDomain`, `domainText`, `mkDomains`, `withTlsSecret`, and `canonicalDomain` are the public
construction/access API. The JSON decoder is the only compatibility boundary that accepts legacy
string entries.

`Nagare.Domain.Binding` owns pure ownership comparison plus injected `kubectl` IO. It consumes
Knative `ClusterDomainClaim` and `DomainMapping` JSON and returns typed conflicts. The application,
static, and server deploy paths call this one module. Resource labels use the stable keys
`nagare.dev/managed-by`, `nagare.dev/service`, and `nagare.dev/canonical`; changing them requires
coordinating deletion and inventory code.

`infra/pulumi/src/domainTopology.ts` is the pure owner of apex/wildcard target selection.
`NagarePerimeter` owns both Cloud DNS RRsets and exports `apexIp`. `NagareCdn` owns standing Google
edge infrastructure and Certificate Manager resources. `Nagare.Cdn.Provision` owns per-host exact
DNS changes and the provider eligibility check; it may not mutate the Pulumi-owned apex record.

`Nagare.Ops.Domains` owns observable route state and its stable JSON schema. A small process adapter
executes `dig`; pure parsers and graders remain unit-testable. `pkgs.bind.dnsutils` becomes an
explicit runtime tool in `nix/haskell-packages.nix` and a development input in
`nix/dev-shells.nix`. Do not add a Haskell DNS library unless implementation proves `dig` cannot
provide the required evidence; if that happens, follow the repository instruction to locate the
dependency with Mori first and verify its released version before adding bounds.

Knative Serving supplies `DomainMapping`, `ClusterDomainClaim`, automatic external-domain TLS, and
Kourier routing. cert-manager plus net-certmanager supplies origin certificates. Nagare continues
to use the installed API versions already rendered by the repository; this plan adds no Kubernetes
dependency pin. `gcp.certificatemanager.DnsAuthorization`, `Certificate`, `CertificateMap`, and
`CertificateMapEntry`, plus `gcp.compute.TargetHttpsProxy.certificateMap`, are present in the locked
`@pulumi/gcp` 8.41.1 source under `infra/pulumi/node_modules`. Before implementation changes any
Pulumi dependency bound, verify the registry release and upstream tag as required by `AGENTS.md`.

Google Certificate Manager DNS authorization returns a CNAME that proves control of the base
domain and can authorize both the exact domain and its first-level wildcard. Certificate maps
select an exact or wildcard certificate by the client's SNI hostname. The required service API is
`certificatemanager.googleapis.com`. Cloudflare remains managed through
`Nagare.Cdn.Cloudflare`; its edge certificate is provider-owned, and its DNS authority is not
silently treated as writable by the context's Cloud DNS issuer.

The work creates no cross-repository durable references. Repository-local plan and ADR references
remain relative Markdown links. If implementation discovers a cross-repository dependency or
decision, it must use the owning project's canonical `mori://` URI discovered with the Mori
registry, never a bare path or plan number.


Revision note (2026-09-14): Recorded Milestone 1 implementation, validation evidence, the shared
domain TLS JSON contract, and the Darwin formatter/toolchain discovery so the next milestone can
resume from the checked ownership-preflight item.

Revision note (2026-09-14): Recorded Milestone 2 ownership preflight, diagnostic readiness waits,
the minimal `nagared` read-only cluster RBAC, hermetic no-apply evidence, and the staged-file Nix
source discovery. The next unchecked work is exact apex DNS topology.

Revision note (2026-09-14): Recorded Milestone 3 exact apex DNS, the pure topology truth table,
the Pulumi two-record mock, the TCP origin health invariant, exported `apexIp`, and the additive
preview-guard contract. The next unchecked work is truthful domain inventory.

Revision note (2026-09-14): Recorded Milestone 4 observation types, real DNS probes, route and
certificate diagnostics, JSON schema, strict check command, packaged `dig`, fixture coverage, and
repository-wide validation. The next unchecked work is explicit and verified origin TLS.
