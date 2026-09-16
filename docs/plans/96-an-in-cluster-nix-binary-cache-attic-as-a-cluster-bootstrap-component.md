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

The main cross-repository follow-up is to reconcile
`mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure` with
this provider boundary and replace the byte-identical `pod-nix.conf` fixture proposed by
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`
with a structural contract that permits a context-generated public key.


## Context and Orientation

Nix builds immutable paths under `/nix/store`. A binary cache is a substituter: Nix
downloads a Nix Archive (NAR) plus metadata and accepts it only when the signature matches
a trusted public key. Attic stores metadata and each cache's signing key in PostgreSQL,
stores compressed NAR chunks in an object backend, and exposes a Nix HTTP endpoint plus an
authenticated upload API.

Nagare's root `flake.nix` already configures `https://shinzui.cachix.org`. That cache
accelerates Nagare development and releases; this plan's cache is runtime transport
inside one Nagare context. Root Nix composition lives in `flake.nix`,
`nix/nagare-packages.nix`, `nix/packages.nix`, `nix/dev-shells.nix`, and
`nix/haskell-packages.nix`. The operator package is `#nagare`; adding Attic only to the
developer shell would leave clone-free operators without the client or image-copy tool.

`nix/platform-package.nix` builds the immutable payload. It packages
`cluster/bootstrap`, and `cli/nagarectl/src/Nagare/Platform/Workspace.hs` creates one
writable workspace per context and payload digest. Attic templates, image archive,
scripts, tests, and operator documentation must be in that payload and asserted by
`nix/checks/scripts/nagare-platform-assets.sh`.

Context parsing and rendering live in `cli/nagarectl/src/Nagare/Target.hs`; context CLI
parsing lives in `cli/nagarectl/app/Main.hs`; Pulumi seeding lives in
`cli/nagarectl/src/Nagare/Init.hs`; and the shell twin is
`scripts/lib/target.sh`. Add `NAGARE_NIX_CACHE_ENABLED=1` and
`NAGARE_NIX_CACHE_BUCKET=<name>` consistently to all four surfaces and their tests.
Local mode rejects an enabled cache because v1 provisions GCS and a GCP HMAC credential.

`infra/pulumi/index.ts` constructs the cloud program.
`infra/pulumi/src/components/NagarePerimeter.ts` owns common network, service account,
protected data disk, registry, and backup resources. The cache has a different opt-in and
deletion boundary, so create `infra/pulumi/src/components/NagareNixCache.ts` rather than
adding unrelated resources to `NagarePerimeter`.

Cloud changes follow
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
and [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md).
Release assets follow
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md).
Component identity follows
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md).
Secrets follow
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
and [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md).
Capacity recovery follows
[ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md).

The one-shot Job side is implemented. `cli/nagare-dsl/src/Nagare/Dsl/Job.hs` has optional
`nixConfigMap`; its renderer mounts key `nix.conf` at `/etc/nix/nix.conf` and labels the
Pod `nagare.dev/nix-cache-client: "true"`. ExecPlan 95 owns the base Job policy. This plan
owns the additive cache policies and ConfigMap data.

The server, database, migration, GC, and their Secrets live in `nagare-system`. The
consumer ConfigMap and client policy live in `personal`. The managed database command is
idempotent and preserves Secret `nagare-db-nix-cache-db`; key `DATABASE_URL` maps to
`ATTIC_SERVER_DATABASE_URL`. Its daily backup is required because the NAR private key
lives in PostgreSQL.

Central alerts are in `cluster/observability/vmrules/nagare-alerts.yaml`. vmalert is
already enabled. Cache chunks do not consume the node disk, but PostgreSQL does. GCS
growth is observed separately with `gcloud storage du`.

The originating requirement is
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`.
Competing consumer-side work is
`mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure`,
especially
`mori://shinzui/kotei/plans/36-run-a-managed-in-cluster-nix-cache-profile`. Those Kotei
artifacts predate this refreshed boundary and must not deploy another cache into a Nagare
context. Mori has no registered Attic source project, so implementation must inspect the
pinned upstream checkout and authoritative GitHub registry rather than remembered APIs.


## Plan of Work

### Milestone 1: make Attic a pinned, clone-free, optional capability

Add `nixCacheEnabled` and `nixCacheBucket` to the target profile, persisted as
`NAGARE_NIX_CACHE_ENABLED` and `NAGARE_NIX_CACHE_BUCKET`. Default to disabled and
`<project>-nagare-nix-cache`. Extend context create/update, Pulumi seeding, shell export,
docs, and tests. Reject enabled local contexts.

Pin Attic at a reviewed full commit whose official GHCR image exists under the same
commit name. Upstream has no tags, so record the commit, source date, manifest digest,
and Linux/amd64 digest in `nix/attic.nix` and the component README. Add the source as a
flake input for the native client. Represent the server as a digest-pinned
`dockerTools.pullImage` output. Do not force Attic's nixpkgs inputs to follow Nagare until
a focused evaluation proves compatibility.

Expose `attic-client` and `attic-server-image` from `nix/packages.nix`. Thread the image
through `nix/nagare-packages.nix` into `nix/platform-package.nix`, which copies it to
`cluster/bootstrap/nix-cache/attic-server-image.tar.gz`. Add `attic` and `skopeo` to the
operator tools in `nix/haskell-packages.nix` and the default shell. Extend payload and
operator checks to prove the archive, pin metadata, client, and copy tool survive
clone-free packaging.

Milestone 1 is complete when supported native release systems evaluate the same source
identity, installed `#nagare` exposes the pinned tools, the payload contains the exact
server archive, and no install path needs a checkout or mutable upstream image.

### Milestone 2: provision storage and establish the secret boundary

Create `infra/pulumi/src/components/NagareNixCache.ts`. When
`nagare:enableNixCache` is true, create a regional bucket with uniform access, public
access prevention, `forceDestroy: false`, and Pulumi protection; a non-authoritative
bucket IAM member granting `roles/storage.objectAdmin` to the node service account; and
a protected `gcp.storage.HmacKey` for that account. Do not enable object versioning:
Attic GC must reclaim chunks rather than retain noncurrent generations.

Export `nixCacheEnabled`, `nixCacheBucket`, `nixCacheHmacAccessId`, and secret
`nixCacheHmacSecret`. Disabled stacks create no cache resource or credential. Add Pulumi
tests for both branches.

Add `cluster/bootstrap/nix-cache/create-secret.sh` and a non-secret schema example. The
script runs the platform/project guard, resolves the context-owned secret directory,
refuses overwrite without a rotation flag, and uses a private temporary directory with a
trap. Generate the upstream-compatible JWT key:

```bash
openssl genrsa -traditional -out "$private_dir/attic-jwt.pem" 4096
base64 < "$private_dir/attic-jwt.pem" | tr -d '\n' > "$private_dir/attic-jwt.b64"
```

Read HMAC outputs only after the cache is enabled. Pipe all values into sops without
putting them in argv, stdout, tracked plaintext, or the payload. The encrypted operator
file contains Secrets `nagare-nix-cache-storage` and `nagare-nix-cache-token-key` in
`nagare-system`. The installer decrypts directly to `kubectl apply -f -`. The JWT never
enters Pulumi. Document that the HMAC necessarily exists in Pulumi state and inherits
the chosen secrets provider; for the current empty-passphrase `tan-nb-exp` stack,
state-bucket IAM is the confidentiality boundary.

Milestone 2 is complete when TypeScript build/tests pass, a retained preview contains
only the expected opt-in resources, guarded apply succeeds, the encrypted operator file
is outside the payload, and secret scans find no JWT or HMAC value.

### Milestone 3: deploy, initialize, and reconcile Attic

Create `cluster/bootstrap/nix-cache/` with README, pin metadata, payload-supplied image,
`publish-image.sh`, `create-secret.sh`, `install.sh`, `server.toml.tmpl`, workload
templates, policies, consumer ConfigMap template, and smoke assets. Scripts use
`set -euo pipefail`, repository guards, private temporary directories, traps, and no
tracing.

`publish-image.sh` validates the selected project and registry, copies the payload archive
to a deterministic Attic-commit tag, resolves the pushed digest, and prints only the
immutable destination. A rerun reuses the same digest. It never builds from the working
directory or uses a mutable tag. `install.sh` invokes this guarded publication step before
rendering manifests, so an enabled bootstrap or platform upgrade cannot deploy a release
whose server image has not been published. The standalone publish command remains a
preflight and rehearsal entry point.

`install.sh` resolves the encrypted Secret before mutation, creates `nagare-system`,
applies the Secret through sops, and idempotently runs:

```bash
nagarectl db create postgres nix-cache-db --namespace nagare-system --size 5Gi --cpu 500m --memory 1Gi
```

Render `server.toml` from the selected bucket and validate it with
`atticd --mode check-config` before applying workloads. Run that check in a short-lived
preflight Job using the published immutable image, rendered ConfigMap, and referenced
Secrets; wait for it before migrations or the API rollout. The server listens on 8080,
allows only the exact internal Service and `127.0.0.1:18080` port-forward Host headers,
sets `api-endpoint` to `http://127.0.0.1:18080/`, fixes `substituter-endpoint` to the
internal URL, reads PostgreSQL and JWT from environment, selects S3 storage with region
`auto` and endpoint
`https://storage.googleapis.com`, declares fixed chunking, uses zstd, and disables
in-process periodic GC. Every key must match pinned `server/src/config.rs`.

The migration Job runs `atticd -f /config/server.toml --mode db-migrations` before the
API rollout. The one-replica Deployment runs non-root, drops all capabilities, disables
service-account token mounting, uses a read-only root plus `emptyDir` for `/tmp`, and
sets requests 250m/256Mi and limits 1 CPU/1Gi. HTTP probes request `/` with an allowed
Service Host header. Service port 80 targets 8080.

The daily GC CronJob runs `garbage-collector-once` with `concurrencyPolicy: Forbid`, a
deadline, and no retry. Server policy allows labeled consumer ingress and egress to DNS,
managed PostgreSQL, and GCS HTTPS. Client policy in `personal` allows DNS, the
cross-namespace Attic Service, and TCP 443 for presigned GCS downloads. Document that
kube-router cannot restrict 443 by hostname and has the already-observed new-Pod policy
reconciliation window.

After rollout, use `kubectl exec` against Attic's `atticadm` to capture a five-minute
bootstrap token in a mode-0600 local file. A temporary client config references that
token by file, so it never appears in argv or history. Create `nagare-cache` if absent,
then converge public-read and 30-day retention. Query public
`/_api/v1/cache-config/nagare-cache` JSON, validate URL, visibility, retention, and key,
then render `nagare-nix-cache-client` in `personal`. The ConfigMap is live context state,
not a checked-in key.

Add `nix-cache-bootstrap` and `nix-cache-status` recipes. When
`NAGARE_NIX_CACHE_ENABLED=1`, normal cloud `cluster-bootstrap` invokes cache bootstrap
before stamping the release; when disabled it creates or deletes nothing. This keeps an
enabled component inside platform upgrades. Direct `nagare nix-cache-bootstrap` remains
available for repair.

Milestone 3 is complete when migrations, rollout, initialization, ConfigMap generation,
and status succeed from installed `#nagare`; a Pod restart preserves metadata and key;
the database backup CronJob exists; and all applied images use immutable digests.

### Milestone 4: prove the boundary and publish operations guidance

Add a deterministic smoke flake under `cluster/bootstrap/nix-cache/smoke/`. Build and
push it through a port-forward. The positive Pod copies only that source and the generated
ConfigMap, sets `--max-jobs 0` so it cannot build locally, and proves the path came from
the internal Attic URL. The negative Pod uses Attic as its only substituter and a wrong
public key; with local builds disabled it must fail on the untrusted signature rather
than fall back to Cachix.

Repeat after deleting the Attic Pod and from a fresh client store. Run a Job from the GC
CronJob. Prove anonymous push fails, a narrow writer cannot create another cache, and
anonymous pull works. Rotate the NAR key, rerun install to regenerate the ConfigMap, and
retrieve an already-stored path without re-upload. Rotate JWT separately and prove old
write tokens fail while public pull and NAR trust remain unchanged.

Add a 90-percent, 15-minute critical rule to
`cluster/observability/vmrules/nagare-alerts.yaml` while preserving the current
80-percent warning. Document `gcloud storage du` for bucket growth.

Add `docs/user/nix-binary-cache.md` and link/update the user index, README, reference,
bootstrap, upgrade, and disaster-recovery docs. Cover enablement, push, ConfigMap use,
token revocation, NAR/JWT/HMAC rotation, database restore, bucket recovery, disabling
without deletion, and protected teardown. State that Kotei consumes the contract and
must not deploy another Nagare cache.

Milestone 4 is complete when positive and negative substitution, restart, redirect,
policy, GC, alert, backup, and rotation observations are recorded and production key and
retention configuration are restored.


## Concrete Steps

Run from the checkout root. Discover Attic locally first, then verify upstream:

```bash
mori registry search attic
git ls-remote https://github.com/zhaofengli/attic.git HEAD refs/heads/main 'refs/tags/*'
```

After choosing the source commit matching an official commit-named image:

```bash
nix flake update attic
git diff -- flake.lock nix/attic.nix
nix build .#attic-client
nix build .#attic-server-image
```

Build clone-free outputs and use the current native system in check attributes:

```bash
nix build .#nagare-platform
nix build .#nagare
result/bin/attic --version
result/bin/skopeo --version
nix build .#checks.aarch64-darwin.nagare-platform-assets --print-build-logs
nix build .#checks.aarch64-darwin.nagare-operator-tools --print-build-logs
```

Release validation also runs x86_64-linux equivalents on a native runner. Enable on an
existing cloud context, then review and apply one retained plan:

```bash
nagarectl context create prod --enable-nix-cache --nix-cache-bucket acme-prod-nagare-nix-cache --force --use
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/nix-cache-enable"
nagare infra-preview --save-plan "$plan_dir"
jq . "$plan_dir/review.json"
nagare infra-up --plan "$plan_dir" --yes
```

Do not apply to production until the operator reviews the bundle. Then create encrypted
bootstrap material, preflight publication, and reconcile (the bootstrap repeats the
publication check idempotently):

```bash
nagare nix-cache-secret-init
nagare nix-cache-publish
nagare cluster-bootstrap
nagare nix-cache-status
```

The secret command prints only the encrypted destination. Publish prints one reference
containing `@sha256:`. Status reports image, database, migration, rollout, public key,
retention, schedules, and ConfigMap digest without credentials.

For the end-to-end proof, keep port-forward in one terminal:

```bash
kubectl -n nagare-system port-forward service/nix-cache 18080:80
nix build ./cluster/bootstrap/nix-cache/smoke#default --print-out-paths
attic push nagare-cache "$(nix path-info ./cluster/bootstrap/nix-cache/smoke#default)"
kubectl -n personal apply -f cluster/bootstrap/nix-cache/smoke-pod.yaml
kubectl -n personal logs -f pod/nix-cache-smoke
```

Expected output names the internal Attic URL and never executes the builder. Record the
pinned Nix wrong-key wording in Surprises during implementation.

Run focused and aggregate checks:

```bash
nix build .#checks.aarch64-darwin.haskell-style
nix flake check
npm --prefix infra/pulumi run build
npm --prefix infra/pulumi test
nix shell nixpkgs#shellcheck -c shellcheck cluster/bootstrap/nix-cache/*.sh
nix build .#checks.aarch64-darwin.nix-cache-bootstrap-assets
git diff --check
```


## Validation and Acceptance

- Context defaults cache off, rejects it in local mode, round-trips cloud settings,
  seeds Pulumi, and exports identical Haskell and shell values.
- `flake.lock` pins one reviewed Attic source commit; the server archive uses the matching
  immutable Linux/amd64 digest; installed `#nagare` contains client and `skopeo`.
- The payload contains image, scripts, templates, and metadata. Clone-free checks invoke
  recipes without the checkout.
- A retained Pulumi review shows no cache resources when disabled and exactly one
  protected bucket, IAM member, and HMAC key when enabled. Apply uses that exact plan.
- JWT exists only in operator sops. HMAC remains secret-marked in Pulumi and encrypted in
  sops. Neither appears in Git, payload, argv, review, stdout, or bootstrap logs.
- `check-config` accepts TOML; migration succeeds; API becomes Ready; GC and database
  backup CronJobs exist.
- Cache configuration reports the fixed loopback upload API and internal substituter;
  producers succeed through port-forward and Pods are never directed to loopback for
  substitution.
- Server resources live in `nagare-system`. Consumer ConfigMap lives in `personal` and
  matches live URL, key, public flag, and 30-day retention.
- Anonymous pull succeeds; anonymous push fails; a cache-scoped writer pushes
  `nagare-cache` but cannot create/configure another cache.
- With local builds and fallbacks disabled, a fresh Job substitutes from Attic. A wrong
  key makes the same operation fail signature verification.
- Record producer build-and-push time and fresh-Pod cache-hit time-to-first-command as
  separate observations. Attribute any speedup only to avoided Nix build/download work;
  do not claim improvements to scheduling, OCI pulls, migrations, or manifest rollout.
- Client policy permits DNS, Attic, and observed GCS HTTPS redirects and blocks an
  unrelated non-HTTPS target after reconciliation. Docs disclose unrestricted 443 and
  startup-window limitations.
- Restart preserves metadata, key, and retrieval. One-shot GC succeeds without changing
  production retention.
- NAR rotation changes the ConfigMap key and retrieves existing data without re-upload.
  JWT rotation invalidates old writers without changing public pull or NAR trust.
- Central 80-percent warning and 90-percent critical rules load. GCS growth is separately
  observable and database/observability PVC use stays below warning.

Do not accept the feature based only on HTTP readiness or image rollout. The signed
workstation-to-Pod transfer with local building disabled is the feature.


## Idempotence and Recovery

Context update, retained Pulumi review/apply, image publication, database creation, sops
Secret apply, ConfigMap apply, Deployment apply, cache convergence, and bootstrap are
repeatable. The installer may recreate a completed migration Job under the same immutable
image; it never deletes database, bucket, or key material as implicit repair. A disabled
context skips the component and leaves state untouched.

The bucket uses `forceDestroy: false` and Pulumi protection. Removing opt-in must not
silently delete artifacts. To retire the cache, revoke writers, stop consumers, back up
PostgreSQL, decide whether to retain/export the bucket, deliberately remove protection,
and execute a new reviewed plan.

To roll back Attic, restore the prior Nagare payload, republish its pinned archive, and
deploy it only if the schema is backward-compatible. Otherwise restore the matching
PostgreSQL backup. Never run two schema versions against the database.

If JWT is lost, generate a new sops Secret, roll Attic, and issue new write tokens. Public
reads and NAR trust remain valid. If HMAC is exposed, provision an overlapping second
credential in one reviewed change, update sops and rollout, verify, then remove the old
credential in a second reviewed change.

The NAR private key is recovered with PostgreSQL. Restore a backup and compare the public
key before serving. If irrecoverable, initialize a new cache/key, regenerate every client
ConfigMap, and repopulate artifacts. Clients must not silently trust a replacement key.

GC is irreversible for unreferenced chunks. Test destructive retention only on a
disposable cache and path. Total cache loss is recoverable by rebuilding and pushing, but
database backup preserves signing identity and avoids coordinated trust reset.


## Interfaces and Dependencies

The external dependency is the exact Attic source commit and matching official
Linux/amd64 digest in `nix/attic.nix`. Reviewed interfaces are `attic`, `atticadm`,
`atticd --mode check-config`, `api-server`, `db-migrations`,
`garbage-collector-once`, TOML config, PostgreSQL URL, S3 backend, AWS credential
variables, and `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`. Any change requires pin,
source, migration, and Decision Log review.

Context contract:

```text
NAGARE_NIX_CACHE_ENABLED=0|1
NAGARE_NIX_CACHE_BUCKET=<globally-unique-gcs-bucket>
```

Pulumi contract:

```typescript
enableNixCache: boolean
nixCacheBucket: string
nixCacheEnabled: pulumi.Output<boolean>
nixCacheHmacAccessId: pulumi.Output<string>
nixCacheHmacSecret: pulumi.Output<string> // Pulumi secret
```

Cluster contract:

```text
Server namespace: nagare-system
Deployment/control Service: nix-cache
Consumer headless Service: nix-cache-internal:8080
Cache name: nagare-cache
URL: http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache
Database Secret: nagare-db-nix-cache-db, key DATABASE_URL
Storage Secret: nagare-nix-cache-storage
JWT Secret: nagare-nix-cache-token-key
Consumer namespace: personal
Client ConfigMap: nagare-nix-cache-client, key nix.conf
Client opt-in label: nagare.dev/nix-cache-client: "true"
```

The generated ConfigMap contains two logical settings:

```text
substituters = http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache https://cache.nixos.org/
trusted-public-keys = <complete-live-server-key> cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

Do not assume the generated key name includes `-1`; copy the entire server-reported
string. ExecPlan 95 consumes only ConfigMap name/key and opt-in label. Kotei consumes
URL, key, and write mechanism through its own config; it is not a Nagare source
dependency. GCS stores chunks, PostgreSQL stores metadata and signing identity, Artifact
Registry stores the mirrored image, and Victoria evaluates capacity alerts.


## Revision Notes

2026-07-14: Replaced every indented command, Nix configuration, TypeScript interface, and
cluster-contract excerpt with an explicitly language-tagged fenced code block, as
required by the ExecPlan formatting specification. No cache design changed.

2026-08-23: Replaced the informal Kikan source-plan reference with its canonical
`mori://` URI. Scope and status were unchanged.

2026-09-15: Revalidated the plan against Nagare's immutable payload, context-owned
configuration, guarded Pulumi workflow, private operator-secret boundary, completed Job
cache mount, and centralized alerting. Recast Attic as an optional cloud component in
`nagare-system`, clarified its opt-in producer-to-Job use cases, defined the Nagare/Kotei
boundary, made trust runtime-generated per context, replaced YAML and PKCS#8-era
assumptions with pinned TOML/PKCS#1 interfaces, and corrected client NetworkPolicy
acceptance for presigned GCS redirects. Scoped the performance claim to measured
cache-hit Job startup rather than deployment as a whole, and linked the implementation
plan to `mori://shinzui/nagare/okf/use-cases/concepts/UC-2`. Replaced Host-derived API
endpoints with a fixed port-forward upload endpoint after checking upstream's production
requirement.

2026-09-16: Implemented the optional Attic provider end to end in repository scope. Added
context and Pulumi contracts, exact source/image pins, clone-free release assets and tools,
guarded sops secret creation and Artifact Registry publication, ordered Attic database/runtime
reconciliation, live trust ConfigMap generation, policies, deterministic positive/negative smoke
assets, the critical disk alert, hermetic checks, and the operator runbook. Static acceptance
passes; retained cloud apply and live cluster behavior remain explicitly outstanding.

2026-09-16: Rehearsed the unreleased 0.4.0 provider on `tan-ng-labs`, corrected operator
portability and payload-boundary faults, private-image bootstrap ordering, Attic/database
resource identity, verified port-forwarding, kube-router Service handling, and smoke-test
false positives. Recorded successful push, signed substitution, wrong-key rejection,
restart persistence, GC, readiness, retention, and backup-schedule evidence; left destructive
key rotation and the unrelated-HTTP policy probe open.
