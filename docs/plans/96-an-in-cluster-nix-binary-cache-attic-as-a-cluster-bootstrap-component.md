---
id: 96
slug: an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component
title: "An in-cluster Nix binary cache (Attic) as a cluster bootstrap component"
kind: exec-plan
created_at: 2026-07-14T19:28:25Z
intention: "intention_01kx3qz212e989078m6ssetr2b"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:27:19Z
      mode: "update"
      note: "Refresh Attic scope for immutable payloads, guarded operations, and Nagare/Kotei ownership"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T12:24:44Z
      mode: "implement"
      note: "Implemented the optional context-owned Attic provider, immutable release payload, guarded cloud and secret boundaries, cluster reconciliation, smoke assets, observability, and operator documentation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T16:35:00Z
      mode: "implement"
      note: "Rehearsed unreleased 0.4.0 on tan-ng-labs, fixed live boundary faults, and recorded signed substitution, wrong-key, restart, and GC evidence"
  reviews:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:34:09Z
      verdict: "approved"
      note: "Approved after validating Nagare ownership, opt-in use cases, current repository contracts, and pinned Attic interfaces"
---

# An in-cluster Nix binary cache (Attic) as a cluster bootstrap component

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare will offer an optional, context-owned Attic binary cache to cloud installations
that need to move Nix build outputs between an operator workstation and Nix-capable
Kubernetes Jobs. Nagare owns the provider side: the Google Cloud bucket and credential,
the versioned server image, managed PostgreSQL, in-cluster service, and generated client
ConfigMap. Kotei and other workloads own whether and how they consume that stable
interface.

When enabled, Attic runs in `nagare-system` and serves cache `nagare-cache` at
`http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache`. An operator can push a
store path through a guarded `kubectl port-forward` with a narrow token. A Job in
`personal` opts in through the already-implemented `nagare-dsl` Job field, mounts
ConfigMap `nagare-nix-cache-client`, and substitutes the same signed path instead of
rebuilding it.

This capability does not replace `https://shinzui.cachix.org`, the public development
and release substituter in `flake.nix`. It also does not make Attic a Kotei subsystem.
Nagare owns the deployed service because its lifecycle crosses Nagare's Pulumi resources,
immutable payload, cluster bootstrap, managed database, secret boundary, and
observability. Kotei owns its cache configuration, push behavior, and Pod integration.

### When this capability is used

The cache is inactive by default. A cloud context enables it when workloads need to move
Nix store closures from a trusted producer into Kubernetes without building them in the
consumer Pod. Nagare then provisions and reconciles the provider during normal bootstrap
and upgrades, but it does not populate the cache implicitly. A workstation, CI job, or
Kotei producer explicitly pushes a closure with a narrow write token. Each consuming Job
explicitly selects `nagare-nix-cache-client` through its `nixConfigMap` field.

The primary use cases are Kotei-generated or operator-built one-shot workloads, repeated
Jobs that share expensive dependencies, and restricted Pods where local building is
disabled and only prebuilt, signed paths may run. The cache can reduce repeated builds
and network downloads within one context, but it is not a general artifact source of
truth. Bucket and database loss is recoverable by rebuilding and repushing closures;
PostgreSQL backup matters because it preserves the context's signing identity.

The expected speedup is specifically shorter Job time-to-first-command on a cache hit:
the Pod downloads and verifies a closure instead of building it. It does not accelerate
Pod scheduling, OCI image pulls, migrations, or manifest rollout. The first use can be
neutral or slower because a producer must build and push the closure. Acceptance records
cold-cache producer build-and-push time separately from warm-cache consumer substitution
time rather than claiming that every deployment becomes faster.

The user-value contract is recorded independently of this Attic implementation at
`mori://shinzui/nagare/okf/use-cases/concepts/UC-2`. This plan must keep its jobs,
feature ownership, non-goals, and observable acceptance aligned with that use case.

Do not enable this component merely to accelerate Nagare development or release builds;
the existing Cachix substituter serves that purpose. Do not use it for OCI images,
source archives, mutable application data, or cross-context trust. Artifact Registry,
Git/source hosting, durable application storage, and a separately reviewed federation
design own those cases.

The observable proof is a round trip: build and push the checked-in smoke derivation from
the operator machine, then run a fresh opted-in Job with local building disabled and
observe Nix copy the path from the in-cluster URL. A wrong public key must make the same
Job fail signature verification. Restarting Attic must not lose the path or signing
identity.

## Progress

- [x] (2026-09-15) Refresh the plan against Nagare's immutable payload, context model,
  guarded Pulumi workflow, private operator state, current observability, and completed
  one-shot Job contract.
- [x] (2026-09-16) Add the context opt-in and package the pinned Attic client plus server image into
  Nagare's release outputs and immutable platform payload.
- [x] (2026-09-16) Implement the optional protected GCS bucket, scoped IAM, and HMAC credential
  through a separately owned Pulumi component and retained reviewed plan.
- [x] (2026-09-16) Add the operator-owned sops workflow for the Attic JWT key and Pulumi-produced HMAC
  credential without putting either value in the public payload or process arguments.
- [x] (2026-09-16) Add managed PostgreSQL plus Attic migration, API, garbage-collection, Service,
  ConfigMap, and NetworkPolicy resources.
- [x] (2026-09-16) Initialize the public-read cache and generate the consumer ConfigMap from the live
  server-reported public key.
- [x] (2026-09-16) Integrate enabled-cache reconciliation into clone-free bootstrap and upgrades, and
  document the Nagare/Kotei ownership boundary.
- [x] (2026-09-16) Rehearse the unreleased 0.4.0 provider on the `labs` context in
  `tan-ng-labs`: apply the retained cache infrastructure review, initialize the private
  sops material, publish the immutable image, create and migrate PostgreSQL, configure
  Attic, push the pinned smoke path, prove signed substitution with builds and fallback
  disabled, reject a wrong key, repeat substitution after restart, and complete one-shot GC.
- [ ] Complete destructive trust-rotation acceptance and the explicit unrelated-HTTP
  NetworkPolicy probe before calling every optional acceptance scenario complete. Live
  status already proves the public key, 30-day retention, API/database readiness, daily
  backup schedule, GC schedule, and consumer ConfigMap; static alert checks pass.

## Surprises & Discoveries

- Discovery: Nagare no longer treats a source checkout as the operator runtime.
  `nix/platform-package.nix` ships `cluster/bootstrap`, and
  `cli/nagarectl/src/Nagare/Platform/Workspace.hs` materializes a content-addressed
  per-context workspace. A cache installer or image publisher that only works from the
  checkout would regress the supported clone-free path.
  Evidence: `workspaceAssets` includes `cluster/bootstrap` while the payload deliberately
  excludes root Nix wiring and operator secrets.

- Discovery: cloud apply is now a retained-review transaction. Direct `pulumi up`, the
  old `just infra-up` without a saved plan, and ad hoc `pulumi config set` instructions
  are no longer acceptable implementation guidance.
  Evidence: [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
  requires `nagare infra-preview --save-plan` followed by `nagare infra-up --plan`.

- Discovery: operator deployment material and bootstrap secrets moved out of the public
  repository. The previous design put the JWT private key in Pulumi config and rebuilt
  live Secrets from stack outputs, conflicting with the sops-managed
  `NAGARE_CLUSTER_SECRETS_DIR` boundary.
  Evidence: [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  and [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md).

- Discovery: a generated Attic NAR public key cannot be committed as a universal release
  asset. Each Nagare context has its own PostgreSQL database and cache keypair, while the
  immutable payload is shared across contexts. The repository can ship a template and
  renderer; the installer must query the live cache and apply a context-specific
  ConfigMap.

- Discovery: Attic has no stable release tags in the authoritative upstream repository as
  of 2026-09-15. Its official GHCR package publishes commit-named images, and upstream
  still calls the project an early prototype. Nagare must pin a reviewed full source
  commit for the client and the matching immutable Linux/amd64 image digest, never
  `main`, `latest`, or an unverified alias.

- Discovery: current Attic server configuration is TOML, not YAML. The pinned source
  requires `chunking`, supports `atticd --mode check-config`, expects a PKCS#1 RSA key
  for `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`, and recommends strict
  `allowed-hosts`. It also says `api-endpoint` must be set for production because an
  omitted value is synthesized from the request Host header. The old `openssl genpkey`
  command emits PKCS#8 by default.
  Evidence: upstream `server/src/config.rs`, `server/src/main.rs`, and
  `nixos/atticd.nix` at the reviewed commit.

- Discovery: Attic's S3 backend redirects a single-chunk NAR to a presigned object-store
  URL. GCS-backed client Pods therefore need HTTPS egress as well as DNS and the Attic
  Service. Kubernetes NetworkPolicy cannot restrict that egress to
  `storage.googleapis.com` by hostname.
  Evidence: upstream `server/src/api/binary_cache.rs` calls
  `download_file_db(..., false)` for a single chunk, and
  `server/src/storage/s3.rs` returns a presigned redirect in that mode.

- Discovery: vmalert and the central 80-percent `DiskUsageHigh` rule already exist. This
  plan must extend `cluster/observability/vmrules/nagare-alerts.yaml` with the missing
  critical threshold, not create a second cache-specific rule set or re-enable alerting.

- Discovery: the `pod-nix.conf` fixture promised by
  `mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`
  is still absent, while
  `mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure` is a
  separate stale cache initiative. The provider/consumer boundary must be explicit to
  prevent two repositories from deploying competing caches.

- Discovery: the newest Attic `main` commit did not have a corresponding official image.
  The most recent commit-named GHCR image that matched reviewed source was
  `12cbeca141f46e1ade76728bce8adc447f2166c6`; its multi-architecture manifest is
  `sha256:18574aba70fc89d2b695273fbe2e7b2f8ad7e8e786b4cc535124fbe14bada1d0` and its
  Linux/amd64 manifest is
  `sha256:317924e10e70416e69d401880bb71b3aae69b413ecafcfc54018f61929464526`.
  Evidence: authoritative upstream refs, GHCR manifests, and a checkout of that exact
  commit were inspected before implementing its CLI and TOML interfaces.

- Discovery: the installed Pulumi GCP provider marks `HmacKey.secret` as secret, but the
  unit-test mock does not reproduce provider schema annotations. Wrapping the value with
  `pulumi.secret` makes the stack contract explicit and keeps disabled and enabled tests
  fail-closed if provider behavior changes.

- Discovery: a Darwin operator's default smoke package must still resolve to the exact
  x86_64-linux derivation requested by the cluster Pod. Publishing a native Darwin path
  would make the substitution proof meaningless. The smoke flake therefore maps every
  supported operator-system default to one pinned x86_64-linux derivation and relies on
  Nagare's configured remote builder when the operator is not Linux.

- Discovery: `kubectl apply --dry-run=client --validate=false` still asks the configured
  API server for REST mappings. With no live cluster, it is not an offline manifest check.
  The hermetic check renders every template and parses the multi-document YAML with `yq`;
  live server-side acceptance remains in the unchecked final progress item.

- Discovery: the official Attic image has no OCI `User`, so Kubernetes interprets it as
  root and rejects `runAsNonRoot: true` unless the manifest supplies a numeric identity.
  Attic now runs explicitly as UID/GID 65532. The stock Nix smoke image is different: its
  single-user store must be writable by root, so the smoke Pods drop every capability and
  disable privilege escalation without claiming a non-root identity they cannot use.

- Discovery: this flake currently exposes no `formatter.<system>`, so the plan's inherited
  `nix fmt` command cannot run. The native `haskell-style` flake check is the repository's
  enforced Fourmolu/style gate; Nix expression formatting was reviewed in the focused diff.

- Discovery: release rehearsal originally exercised the assembled provider for the first
  time. macOS LibreSSL, sops policy discovery, OCI trust policy and digest preservation,
  persisted-context precedence, private registry pulls, and Kubernetes namespace policy
  all crossed package or runtime boundaries that the repository's component tests did not.
  These failures explain why release validation was slow despite green unit tests.

- Discovery: the first live manifests gave PostgreSQL and Attic the same Kubernetes
  Service name, `nix-cache`. Applying the API Service replaced the database Service and
  made Attic connect to itself on port 80. The managed database is now independently named
  `nix-cache-db` across Service, StatefulSet, Secret, backup, and NetworkPolicy identity.

- Discovery: port 8080 on the operator workstation was already occupied by Redpanda
  Console. The original readiness probe accepted that unrelated HTTP 200 and sent Attic
  API calls to the wrong process. The control port is now 18080; bootstrap and status both
  require the port-forward process to remain alive, and bootstrap verifies Attic's own page.

- Discovery: kube-router evaluates client egress against the Service ClusterIP before
  destination NAT, so a namespace-and-Pod peer did not authorize the ClusterIP even when
  both Service and container ports were listed. Consumers now use a headless Service on
  port 8080, preserving selector-scoped HTTP egress without opening arbitrary port 80.

- Discovery: an acceptance test that treats any Nix failure as a wrong-key success is
  dangerously weak. The first negative Pod passed only because flakes were disabled.
  The final smoke realizes the producer's exact immutable store path, keeps local builds
  and fallback disabled, and requires signature-related failure text for the wrong key.

## Decision Log

- Decision: Use Attic rather than Harmonia.
  Rationale: Attic supplies the authenticated push API, per-cache retention, deduplicated
  object storage, and garbage collection required for workstation-to-Pod transport.
  Harmonia serves an existing local Nix store and lacks the required upload and retention
  boundary.
  Date: 2026-07-14

- Decision: Provision a dedicated `<project>-nagare-nix-cache` GCS bucket.
  Rationale: Attic GC must not share a deletion boundary with database backups, Pulumi
  state, or image staging. The node service account receives object administration only
  on this bucket.
  Date: 2026-07-14

- Decision: Use GCS's XML/S3-compatible API with an HMAC key for the node service account.
  Rationale: Attic accepts access-key credentials and a custom endpoint; it does not
  exchange GCE metadata OAuth tokens. The IAM grant remains bucket-scoped.
  Date: 2026-07-14

- Decision: Use Nagare's managed PostgreSQL and run migrations and garbage collection
  separately from the API server.
  Rationale: the existing database kind supplies durable storage, credentials, readiness,
  and daily backup. Explicit migration and one-shot GC Jobs make ordering and failures
  observable.
  Date: 2026-07-14

- Decision: Keep Attic private to a ClusterIP and let workstations push through
  `kubectl port-forward`.
  Rationale: this meets the producer/consumer flow without adding public ingress and TLS
  to an early-prototype service.
  Date: 2026-07-14

- Decision: Make `nagare-cache` public-read and require narrow, expiring write tokens.
  Rationale: Nix verifies NAR signatures, so read bearer tokens would add Secret
  distribution without improving artifact integrity. Write authority stays revocable.
  Date: 2026-07-14

- Decision: Treat Attic's JWT key and NAR key as distinct secrets.
  Rationale: the JWT RSA key signs capability tokens. Attic generates the NAR keypair and
  stores its private half in PostgreSQL. Rotating one must not silently rotate the other.
  Date: 2026-07-14

- Decision: Make the cache an optional, cloud-only Nagare component selected by context.
  Rationale: it adds billable GCS, a database, credentials, and operational
  responsibility. Context ownership lets clone-free bootstrap and upgrades reconcile it
  when enabled without imposing it on local mode or installations using another cache.
  Date: 2026-09-15

- Decision: Put the server and database in `nagare-system` and publish the consumer
  ConfigMap in `personal`.
  Rationale: Attic is platform infrastructure, not an application. ConfigMaps are
  namespace-scoped, so consumer Jobs still need their ConfigMap in `personal`.
  Date: 2026-09-15

- Decision: Nagare owns the deployed provider; Kotei owns consumption and must not deploy
  a second Nagare cache.
  Rationale: cloud IAM, payloads, bootstrap, recovery, and observability are Nagare
  lifecycle concerns. Kotei's configuration and push/pull behavior are Kotei concerns.
  Date: 2026-09-15

- Decision: Package the pinned Attic client and immutable server image with each Nagare
  release.
  Rationale: the operator flow must work from `#nagare`, not only `nix develop`. A source
  commit identifies the client API; the matching GHCR digest identifies the server bytes
  copied to the selected Artifact Registry.
  Date: 2026-09-15

- Decision: Store the JWT key in the operator-owned sops file, not Pulumi config. Transfer
  the Pulumi-produced HMAC secret once into the same sops file.
  Rationale: JWT material is bootstrap configuration under ADR 4. The HMAC secret
  necessarily exists in Pulumi state as a cloud-resource output, but routine bootstrap
  should not decrypt state or print a stack secret.
  Date: 2026-09-15

- Decision: Generate `nagare-nix-cache-client` from the live cache rather than committing
  a real public key.
  Rationale: the NAR key is context-specific and restored with PostgreSQL. The release can
  own the renderer and stable ConfigMap contract while install and rotation converge live
  data.
  Date: 2026-09-15

- Decision: Accept and disclose TCP 443 egress for opted-in clients in v1.
  Rationale: upstream Attic redirects single-chunk S3-backed NARs to presigned GCS URLs.
  Forcing every download through Attic would require an upstream patch or egress proxy.
  Date: 2026-09-15

- Decision: Set `api-endpoint` to the fixed port-forward address
  `http://127.0.0.1:18080/`, set `substituter-endpoint` to the internal Service URL, and
  enforce an exact `allowed-hosts` list.
  Rationale: v1 producers push only through the private port-forward path, while Pods use
  only the Nix substituter. Separate endpoints obey Attic's production requirement and
  avoid constructing a delegated upload endpoint from an attacker-controlled Host
  header. An in-cluster API producer or public ingress is future scope.
  Date: 2026-09-15

- Decision: Pin the latest Attic commit for which upstream published an official matching
  image, not the newer unbuilt `main` head.
  Rationale: the release must bind reviewed client source and deployed server bytes to one
  immutable identity. A newer source-only commit cannot satisfy that supply-chain contract.
  Date: 2026-09-16

- Decision: Pin the smoke Pod's `nixos/nix:2.28.4` Linux/amd64 manifest by digest and commit
  the smoke flake lock.
  Rationale: a mutable test image or moving nixpkgs input could turn an acceptance change
  into an unrelated upstream change. The producer and Pod must request the same Linux store
  path across operator systems.
  Date: 2026-09-16

- Decision: Distill provider ownership and the three independent trust domains into
  [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md).
  Rationale: these boundaries constrain future Nagare and Kotei work beyond this implementation,
  especially upgrades, teardown, and key rotation.
  Date: 2026-09-16

- Decision: Give the managed database the identity `nix-cache-db` and reserve `nix-cache`
  for the Attic API Deployment and control Service.
  Rationale: Kubernetes resources share one namespace-wide name per kind. Separate names
  prevent the API Service from overwriting PostgreSQL discovery and make status, backup,
  and policy evidence unambiguous.
  Date: 2026-09-16

- Decision: Publish consumer traffic through headless Service `nix-cache-internal:8080`
  while retaining ClusterIP Service `nix-cache:80` for operator port-forwarding.
  Rationale: direct Pod DNS lets kube-router enforce namespace-and-Pod NetworkPolicy peers
  without depending on pre/post-DNAT implementation details. The control Service remains
  a stable port-forward target.
  Date: 2026-09-16

- Decision: Make the signed smoke consumer realize the exact producer store path rather
  than reevaluate its derivation in a different Nix client image.
  Rationale: the contract is transport and signature verification. Re-evaluation adds
  Nix-version-dependent derivation identity and can pass or fail before contacting Attic.
  Date: 2026-09-16

## Outcomes & Retrospective

The 2026-09-15 refresh validated that the capability still belongs in Nagare, but not as
an unconditional source-tree addon. It belongs as an optional, versioned provider
component because Nagare owns the cloud and cluster lifecycle. The refresh also exposed
three costs that implementation must keep visible: Attic lacks stable release tags,
generated trust is per context, and the S3 redirect path requires client HTTPS egress.

The repository implementation is complete and the focused static checks pass. Contexts now
round-trip the default-off cloud-only opt-in; Pulumi has tested enabled and disabled resource
graphs; the release exposes the pinned client and image; clone-free payload checks cover every
script and template; bootstrap orders config validation, migration, rollout, initialization, and
live-key publication; and the runbook covers use, trust, rotation, recovery, and retirement.

Validated locally on 2026-09-16: all 569 `nagarectl` tests, Pulumi TypeScript build and tests,
Attic client and server-image builds, `#nagare-platform`, `#nagare`, direct packaged tool probes,
the complete native `nix flake check` suite (including platform-assets, operator-tools,
shellcheck, cache-assets, and Haskell style), the cross-system smoke derivation build, OKF
user-documentation enforcement, and `git diff --check`. The image archive's observed digest
matched the reviewed Linux/amd64 digest.

Live cloud acceptance ran on 2026-09-16 against the `labs` context in project
`tan-ng-labs`, using the unreleased 0.4.0 payload and the private operator material owned
by `mori://shinzui/nagare-ops`. The retained Pulumi review created the protected cache
bucket, scoped IAM member, and HMAC key without replacing existing resources. The cluster
then accepted config validation and migration, reported database/API readiness 1/1,
published a context-specific key with 30-day retention, and exposed daily database backup
and GC schedules.

The producer build took one second and its first push took six seconds. A fresh Pod with
`max-jobs=0` and fallback disabled substituted the exact signed path in four seconds. A
wrong-key Pod rejected the same path with Attic's signature error. Restarting the API and
running another fresh Pod preserved metadata, signing identity, and retrieval, again in
four seconds. A manual Job from `nix-cache-gc` completed successfully. This is the core
provider acceptance proof; destructive JWT/NAR rotation and the explicit unrelated-HTTP
policy probe remain intentionally open in Progress.

The rehearsal also demonstrated why prior releases took hours: every cache-only iteration
rematerialized the full operator payload and reinstalled locked Pulumi dependencies, while
failed cluster bootstrap transactions could not resume at a component boundary. A focused
follow-up should add a reusable labs release-verification command, reuse one resolved
`--payload-root`, run production-shaped acceptance continuously before a version bump, and
make cluster components individually resumable. Release day should consume existing green
evidence instead of becoming the first assembled-system test.

The `Service/nagare-system/nix-cache` collision also exposed an ownership gap between
independent bootstrap reconcilers. Before adding a continuously running control plane,
Nagare should render one complete desired-resource inventory, assign every managed object a
stable component identity, reject duplicate `(cluster, namespace, kind, name)` claims, and
refuse to adopt a live object whose ownership annotation names another component. That
inventory and its collision check belong in CI and upgrade preflight; its schema can later
become the input to a controller when continuous drift reconciliation and garbage collection
justify one. [IR-24](../improvement-requests/make-managed-resources-first-class.md) generalizes
that work across Nagare's cloud, host, cluster, data, secret, artifact, and release resources.

The main cross-repository follow-up is to reconcile
`mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure` with
this provider boundary and replace the byte-identical `pod-nix.conf` fixture proposed by
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`
with a structural contract that permits a context-generated public key.

