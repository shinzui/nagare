# Nagare 0.4.0

Nagare 0.4.0 makes every resource Nagare manages first-class: one typed, scoped inventory
records what each context owns across cloud, host, cluster, data, secrets and artifacts, and
every change to it is a reviewed, journalled, resumable transaction (MasterPlan 23,
[IR-24](../improvement-requests/make-managed-resources-first-class.md)). It also adds an optional
in-cluster Attic binary cache and hardens the platform-upgrade path used to deliver it.

This is a pre-1.0 minor release. It is not a production-readiness claim: see
[Unmet production targets](#unmet-production-targets) and the
[production-readiness checklist](production-readiness-checklist.md).

## Inventory highlights

- **One ledger per context.** Compile the desired inventory, review a context-bound plan across
  Pulumi, NixOS, Kubernetes, Helm, data and access executors, and apply it. Colliding identities and
  ambiguous ownership refuse before any mutation; an existing object with another owner is an
  explicit adoption decision, never a name match.
- **Reviewed, resumable transactions.** A durable journal records intent and completion for every
  operation. `inventory resume` continues from proven receipts; `inventory close` ends a stopped
  transaction by per-operation proof and accepts nothing it cannot prove
  ([ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)). Identity is recorded at
  creation, and a replaced or unrecorded member is rebound through review
  ([ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)).
- **Data protection.** Scheduled, signed database backups land off-cluster in GCS under a
  per-context recovery-point objective (`NAGARE_BACKUP_RECOVERY_POINT=hourly|daily`). Freshness
  holds unattended, the signing key is escrowed in sops-encrypted operator material, and a total
  cluster loss is recoverable from the escrow and GCS alone (drilled, with verified content).
- **Reviewed data operations.** Reviewed manual backups and receipts, restores into isolated
  targets, a fenced PostgreSQL rename with a backward exit (`inventory abandon-migration`), and a
  side-by-side PostgreSQL major-version upgrade. Planning refuses an in-place major-version or engine
  change, and `app deploy --retire-database NAME` retires a database an application no longer
  declares, retaining every member.
- **Reviewed host changes.** `host plan` and `host apply` run the self-reverting activation. A
  lock-only re-pin moves NixOS and k3s (one k3s minor at a time, forward only) without changing the
  platform payload, and an activation that did not commit closes with no effect instead of
  switching again ([day-2 host changes](../user/day-2-host-changes.md)).
- **Access.** Grants are inventory members; a scope retires only after its live grants are revoked.

## Cache and upgrade-path highlights

- **Context-local Nix cache.** A cloud context may enable one Attic service backed by a protected,
  non-versioned GCS bucket and a managed PostgreSQL database. The payload pins the upstream Attic
  source and multi-architecture image by digest, publishes the server image into the context's
  Artifact Registry, and stores its HMAC and JWT credentials through the existing Pulumi and sops
  boundaries.
- **Explicit cache trust and access.** Bootstrap configures public pull with context-specific NAR
  signing, writes `nagare-nix-cache-client` in `personal`, and limits server and opted-in client
  traffic with NetworkPolicies. Producers use short-lived, cache-scoped writer tokens over
  `kubectl port-forward`; anonymous push and wrong-key substitution are expected to fail.
- **Cache lifecycle.** Nagare checks configuration before migration, uses a one-shot migration Job,
  schedules Attic garbage collection and PostgreSQL backups, reports non-secret cache status, and
  documents credential rotation and recovery boundaries.
- **Provider-free upgrade resume.** A private receipt binds successful Pulumi apply to the exact
  transaction, context, payload, plan, and tool version. Later-phase resumes skip an already proven
  apply; ambiguous or legacy receipts require the explicit audited recovery command.
- **Reviewed legacy certificate migration.** TLS-enabled 0.2.2 clusters receive a private
  Kubernetes review that narrows the historical `{}` namespace selector, preserves opted-in
  application wildcard certificates, and removes only unchanged obsolete certificate chains.
- **Context-bound host upgrades.** Host evaluation and switching use the validated host name from
  the transaction's staged `host.nix`, independently of the GCE instance name and ambient host
  overrides.
- **Clone-free operator tooling.** The `#nagare` output supplies the candidate CLI, Pulumi CLI, and
  Node.js language host used by upgrade planning and apply.

## Install

After publication, platform operators install the complete immutable operator output:

```bash
export NAGARE_VERSION=0.4.0
nix profile install "github:shinzui/nagare/v${NAGARE_VERSION}#nagare"
nagarectl version --json --tools
nagare --list
```

Application developers who do not operate infrastructure may use `#nagarectl` instead.

## Prerequisites

Nix remains the supported distribution channel. Cloud operations require an authenticated Google
Cloud SDK, Application Default Credentials whose quota project matches the context project, the
context's Pulumi backend and stack configuration, SSH access to the generated host name, and the
matching context kubeconfig.

Enabling the cache additionally requires the operator's sops age identity and a globally unique GCS
bucket name owned by the context project. The HMAC secret is protected by the Pulumi stack secrets
provider and state-bucket IAM; the Attic JWT key remains only in the operator-owned encrypted
cluster secret.

## Upgrading

Use the target candidate or released `#nagare` operator package and follow the staged
[per-context upgrade procedure](../user/upgrades.md). For a published release the normal selector
is:

```bash
export TARGET_NAGARE_VERSION=0.4.0
export TARGET_NAGARE="github:shinzui/nagare/v${TARGET_NAGARE_VERSION}"
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl platform status
```

The upgrade stages the exact candidate payload, retains Pulumi and Kubernetes review bundles,
switches the host and reconciles the cluster only after review, stamps the cluster, and advances the
context pin last. Do not bypass an unexpected VM, DNS-zone, or bucket replacement refusal.

The cache is disabled by default. To enable it, update the selected cloud context with
`--enable-nix-cache` and its context-owned bucket name before planning the upgrade. The reviewed
Pulumi plan must add only the protected bucket, bucket-scoped object-admin IAM member, and protected
HMAC key expected by the cache runbook. Initialize the encrypted cache secret once, publish the
pinned image, run normal cluster bootstrap, and complete the positive and negative smoke tests in
[the cache runbook](../user/nix-binary-cache.md).

## Compatibility and rollback

- **Systems and schemas.** Supported client systems remain `x86_64-linux` and
  `aarch64-darwin`. Asset, host-flake metadata, and platform compatibility schema versions remain 1.
- **Cluster migration.** A TLS-enabled legacy cluster may narrow the old namespace wildcard
  selector and remove reviewed obsolete Knative/cert-manager certificate chains. Apply rechecks
  object identities and refuses drift.
- **Attic state.** Enabling the optional cache creates a PostgreSQL schema and persistent signing
  identity plus GCS objects. Review Attic migration compatibility before later image changes. A
  server-image rollback across an incompatible migration requires the matching database backup.
- **Infrastructure.** The optional cache adds a protected GCS bucket, bucket-scoped IAM member, and
  HMAC credential. Disabling the component does not delete them or its cluster state.
- **Rollback.** `rollbackSupportedFrom` remains empty because a reverse `0.4.0` release-selection
  transaction has not been tested. Selecting an older package does not restore Pulumi resources,
  certificates, databases, bucket contents, or persistent volumes.
- **Distribution.** Nix-by-immutable-tag remains the supported channel. The Cabal packages are not
  published to Hackage by this release.

## Unmet production targets

Release acceptance is not production readiness. These targets are not met by 0.4.0:

- **Volumes outside the recovery-point objective (D2).** Application volumes are not part of the
  scheduled, freshness-graded backups. Manual volume backup and isolated restore to a new PVC remain
  supported.
- **No agreed recovery-time and retention targets (D4).** Scheduled backup keep and expiry are not
  enforced; archives are retained until a separately reviewed disposal.
- **HTTPS routes and protected browser login (D3).** The acceptance fixture is HTTP-only; HTTPS
  routes and protected browser login are a restriction of this release.
- **Node and database upgrades.** These are documented procedures:
  - a node upgrade is a reviewed, lock-only NixOS and k3s re-pin, applied through the self-reverting
    activation and finished with a reviewed reboot ([Day-2 host changes](../user/day-2-host-changes.md#upgrade-nixos-and-k3s));
  - a PostgreSQL major upgrade runs side by side
    ([Managed databases](../user/managed-databases.md#upgrade-postgresql-to-a-new-major-version)).
  They count as production-ready only where the drills in sections 3 and 4 of the
  [production-readiness checklist](production-readiness-checklist.md) are ticked with evidence on
  this release's candidate. Any section left unticked there is an unmet target.
- **Deferred findings.** Findings deferred to the next release are listed in the
  [findings tracker](../audits/mp23-findings.md), among them F89: a transient GCS store read
  during a journal write can leave an apply ambiguous until `inventory resume`.

## Known limitations

- Attic is private and cluster-local; Nagare does not expose it through the configured public
  domain. Producers need Kubernetes access and a port-forward.
- Cache client egress permits TCP 443 because Attic may redirect chunks to presigned GCS URLs;
  Kubernetes NetworkPolicy cannot restrict that allowance by hostname.
- The cache bucket is deliberately not versioned so garbage collection can reclaim chunks. The
  cache is transport, not an artifact source of truth.
- The provider-independent replacement-cutover engine remains non-mutating and is not a production
  replacement command.
- An admitted inventory context cannot change platform version in place (ADR 6). The inventory
  release covers fresh inventory-backed contexts; pre-inventory contexts are disposable.
- Nagare runs a single node: no high availability, and a database pod restart is brief downtime.
- A transient failure reading the GCS inventory store while a journal event is written can leave
  an apply stopped as ambiguous (F89, deferred). The journal stays consistent;
  `inventory resume` recovers it.
- All capabilities remain experimental.

## Validation

The source and native release gates cover the Haskell suites, Pulumi topology tests, payload and
operator-package boundaries, clone-free upgrades, host-identity confinement, receipt-backed resume,
certificate-migration convergence, cache asset/configuration checks, documentation validation, and
full flake checks on the supported systems.

Before publication, the `tan-ng-labs` context is the authorized live proving target for the exact
candidate revision. Required evidence is a reviewed `0.3.0` to `0.4.0` upgrade without protected
resource replacement, healthy host and cluster identities, Attic configuration and database
migration, a successful no-build cache substitution, rejection with an untrusted NAR key, service
restart persistence, and a successful manual garbage-collection Job. Until that rehearsal passes,
these live cloud paths remain validation gaps rather than inferred results.

### IR-24 acceptance evidence

Each case is proven by named assertions in this release's inventory evidence. The release
manifest binds the local acceptance run (C2, a fresh k3d context) and the cloud acceptance run
(C3, a fresh GCP context bootstrapped from this payload) to one source revision and payload digest.
Each run's `inventory-evidence.json` lists its assertions.

| IR-24 case | Evidence (assertion, scenario) |
|---|---|
| 1. Two components claiming one Kubernetes address, and one cloud/provider address and logical ID, refuse before mutation | `collision-refusal` (local, cloud) |
| 2. An object with a different or absent owner is an adoption decision, unmodified without review | `adoption` (local, cloud) |
| 3. A rename plans create, migrate, verify and retire in dependency order and preserves durable data | `retained-postgresql-rename` (local) |
| 4. An interrupted multi-component upgrade resumes from verified receipts without replaying completed phases | `interrupted-recovery` (local, cloud); `shared-history-takeover` (cloud) |
| 5. Drift is classified: repairable drift, missing, foreign, immutable replacement, retained orphan, collection candidate | `drift-classification` (local, cloud) |
| 6. A disposable production-shaped context applies, converges, reruns as a no-op, and honours lifecycle on removal | `convergence-noop-removal`, `retained-data`, `independent-scope-preservation` (local, cloud) |
| 7. Release evidence archives inventory, reviewed change set, receipts and final observed state under one payload identity | The release manifest and both scenarios' `inventory-evidence.json`, assembled from one source revision and payload digest |
