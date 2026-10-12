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

Full plan before trimming: [131-make-apex-and-multi-domain-routing-production-ready.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/131-make-apex-and-multi-domain-routing-production-ready.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

