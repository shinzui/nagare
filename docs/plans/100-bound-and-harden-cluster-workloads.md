---
id: 100
slug: bound-and-harden-cluster-workloads
title: "Bound and harden cluster workloads"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:51:51Z
      mode: "update"
      note: "Reconcile live rollout with current auth manifests and context-owned secrets"
---

# Bound and harden cluster workloads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a personal PaaS running on a single 2-vCPU / 8 GB GCP VM (`nagare-01`,
k3s + Knative). On a box that small, one misbehaving pod can take down everything:
a workload with no memory limit can OOM the node, a log store with time-only
retention can fill the shared data disk that every PVC lives on, and a migration
Job that silently skips its work can leave the auth database behind the code that
talks to it. A July 2026 platform review (MasterPlan 19) found nine such gaps in
the cluster manifests; this plan closes all of them.

The repository now encodes the following target behavior; the remaining work is
to observe it on the live platform. Every auth-plane pod (`en`, `shomei`, `nagared`,
`nagare-access`) and every Victoria observability pod runs with explicit CPU
requests and memory limits, so `kubectl describe node` shows a truthful
reservation picture and a runaway build inside `nagared` gets OOM-killed at 1 GiB
instead of taking the node with it; `en` has readiness and liveness probes on its
real health endpoints; `en`, `shomei`, and the migration Jobs run under the same
hardened securityContext `nagare-access` already has; Grafana's admin password
comes from a sops-encrypted Secret in the active context's operator-owned
`cluster-secrets/<context>/` directory instead of a literal committed to Git or
an immutable release payload, and its datasource list has exactly one source of
truth;
VictoriaLogs and VictoriaTraces carry hard disk-usage caps below their PVC sizes,
so they can never fill the data disk; re-running `cluster/bootstrap/auth-install.sh`
after adding a migration actually applies that migration; and the auth images
deploy by immutable git-SHA tag by default, with mutable `latest` an explicit
opt-in.


## Progress

- [x] M1: add resources, probes, and securityContext to `cluster/bootstrap/en/service.yaml`. (2026-08-24)
- [x] M1: add resources and securityContext to `cluster/bootstrap/shomei/service.yaml`. (2026-08-24)
- [x] M1: add resources to `cluster/bootstrap/nagare-access/service.yaml`. (2026-08-24)
- [x] M1: add resources to `cluster/bootstrap/nagared/service.yaml`. (2026-08-24)
- [x] M1: add resources and securityContext to the Job in `cluster/bootstrap/en/migrations.yaml`. (2026-08-24)
- [x] M1: render all five manifests and assert their resource, probe, and security
  fields with `yq`; all assertions passed. (2026-08-24)
- [ ] M1 live validation: apply the current combined manifests after
  `docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md` and run
  `nagare local-smoke` or the local-auth install to observe pods Running with the
  declared limits. ExecPlan 104 proved the upgraded auth plane reaches Ready locally,
  but did not record the resource/probe observations required by this milestone.
- [x] M1: commit the bounded auth-plane manifests and plan state. (2026-08-24)
- [x] M2: create sops-encrypted `cluster/secrets/grafana-admin.yaml` without
  exposing the generated password in tool output or plaintext Git state. (2026-08-24;
  this was the checkout-owned source before the packaging reconciliation below)
- [x] M2: switch `grafana.adminPassword` to `grafana.admin.existingSecret` and
  pin the plugin to the current verified release, 0.31.0, in
  `cluster/observability/victoria-metrics/values.yaml`. (2026-08-24)
- [x] M2: remove `grafana.additionalDataSources`; apply
  `cluster/observability/grafana/datasources/*.yaml` as labelled ConfigMaps from
  `cluster/observability/install.sh`; update the datasource file comments. (2026-08-24)
- [x] M2: add `retentionDiskSpaceUsage` and resources to
  `cluster/observability/victoria-logs/values.yaml` and
  `victoria-traces/values.yaml`; add resources to
  `victoria-logs/collector-values.yaml`. (2026-08-24)
- [x] M2: verify the exact pinned charts with `helm template`, assert the Secret and
  datasource ConfigMap shapes, and shellcheck the installer; commit M2. (2026-08-24)
- [x] M3: replace the stale embedded-SQL ConfigMap with the supported
  `en-migrate up` executable from the exact same image as `en-server`, and build both
  binaries into that image. (2026-08-24)
- [x] M3: delete-then-render-and-apply the migration Job in
  `cluster/bootstrap/auth-install.sh` and
  `cluster/bootstrap/local-auth/install.sh`. (2026-08-24)
- [x] M3: default `NAGARE_AUTH_TAG` to the git SHA in `auth-install.sh` and
  `render-context-template.sh`. (2026-08-24)
- [x] M3: pin MinIO images to Docker Hub-verified release tags and document the
  `emptyDir` decision in `cluster/local/minio/minio.yaml`. (2026-08-24)
- [x] M3: update `cluster/bootstrap/en/README.md` to match the pg-migrate-backed
  Job behavior and cite its canonical cross-repository packages. (2026-08-24)
- [x] M3: prove migration rerun behavior against disposable PostgreSQL: the first
  `en-migrate up` reported `applied_now`, the second `already_applied`, and
  `en-migrate verify` reported one applied, zero pending, zero unknown. (2026-08-24)
- [ ] M3 live installer validation: run the current local installer twice and confirm
  both recreated migration Jobs succeed against their cluster databases. ExecPlan 104
  (`docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md`) proved one fresh
  install of both Jobs; the second-run/idempotence observation remains.
- [x] M3: commit the pg-migrate Job, immutable tag defaults, and MinIO pins. (2026-08-24)
- [x] Packaging reconciliation: `cluster/observability/install.sh` now resolves
  `grafana-admin.yaml` from the active context's operator-owned cluster-secret directory
  via `scripts/lib/cluster-secrets.sh`, fails before mutation when it is absent, and
  keeps checkout `cluster/secrets/` only as a compatibility fallback. Released payloads
  and workspaces exclude encrypted credentials. (2026-08-26, implemented with
  `docs/plans/101-alerting-and-backup-freshness-monitoring.md`)
- [ ] Cloud rollout: apply M1/M2/M3 against the active cloud context and record observed steady-state usage
- [ ] Write Outcomes & Retrospective


## Surprises & Discoveries

These were found while authoring the plan (2026-07-15) and shape the steps below.

- At authoring, en exposed `GET /healthz` and `GET /readyz`.
  `docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md` later upgraded
  en to its servant-health interface, so the current combined manifest correctly uses
  `GET /health/live` (process liveness) and `GET /health/ready` (dependency
  readiness). Remaining validation must exercise those current paths rather than the
  superseded endpoints recorded in the original implementation commit.
- The Job-immutability problem in finding 5 is subtler than "apply fails": when
  only the ConfigMap SQL changes, `kubectl apply` on the Job succeeds (the Job
  spec is byte-identical) — but the completed Job never re-runs, so new
  migrations are silently never applied. Apply only fails when the Job spec
  itself changes. Delete-then-apply fixes both failure shapes at once.
- The chart value keys for disk-based retention exist and render correctly.
  Verified against the pinned chart versions with `helm show values` and
  `helm template`: `vm/victoria-logs-single` 0.13.5 and
  `vm/victoria-traces-single` 0.1.6 both expose `server.retentionDiskSpaceUsage`
  (default unit GiB), which renders as the container flag
  `--retention.maxDiskSpaceUsageBytes=<value>`; both expose `server.resources`;
  `vm/victoria-logs-collector` 0.3.4 exposes top-level `resources`. Evidence:

  ```text
  $ helm template victoria-logs vm/victoria-logs-single --version 0.13.5 \
      --set server.retentionDiskSpaceUsage=15GiB --set server.retentionPeriod=7d \
      | grep retention
              - --retention.maxDiskSpaceUsageBytes=15GiB
              - --retentionPeriod=7d
  ```

- The `victoria-metrics-k8s-stack` 0.81.0 chart already runs the Grafana
  datasource sidecar with label `grafana_datasource` and labelValue `"1"`
  (chart defaults, confirmed in `helm show values`), and delivers its own
  auto-provisioned VictoriaMetrics datasource through that same sidecar — so
  applying our two standalone datasource files as labelled ConfigMaps unifies
  everything onto one mechanism.
- The auth images already run as a non-root `nagare` system user
  (`cluster/bootstrap/auth-images/Dockerfile.local-haskell` lines 46 and 55:
  `useradd --system ... nagare`, `USER nagare`) and install binaries mode 0555
  owned by that user. So forcing `runAsUser: 10001` via the pod securityContext
  is safe: the binaries are world-readable/executable and nothing writes to the
  filesystem.
- Current pinned upstream image tags for MinIO, checked on Docker Hub
  2026-07-15: `minio/minio:RELEASE.2025-09-07T16-13-09Z` and
  `minio/mc:RELEASE.2025-08-13T08-35-41Z`. Current version of the Grafana
  VictoriaLogs datasource plugin from the grafana.com plugin API: 0.29.0.
  Re-check both at implementation time (commands are in Concrete Steps).

- Implementation (2026-08-24): `kubectl apply --dry-run=client` is not actually
  offline with this kubeconfig; it attempts OpenAPI discovery and current-object
  lookup through the GKE credential plugin, which fails while gcloud needs
  interactive reauthentication. The rendered YAML was instead parsed and its exact
  M1 fields asserted with `yq`. Live apply remains an explicit unchecked item.

- Implementation (2026-08-24): the Grafana plugin release recorded during planning
  was stale. Grafana's authoritative plugin catalog now reports
  `victoriametrics-logs-datasource` 0.31.0 (released 2026-08-06), so M2 pins 0.31.0.
  The pinned k8s-stack chart 0.81.0 embeds Grafana chart 12.3.x and renders that pin
  through `GF_PLUGINS_PREINSTALL_SYNC`, not the older `GF_INSTALL_PLUGINS` variable
  named by the plan. The rendered ConfigMap value is exactly
  `victoriametrics-logs-datasource 0.31.0`.

- Implementation (2026-08-24): `mori://shinzui/en/packages/en-migrations` changed
  from the two timestamped SQL files assumed during planning to an append-only,
  pg-migrate-managed component with an `en-migrate` executable and a fixed-point
  bootstrap schema. The old Nagare ConfigMap was not merely behind: its live unique
  index still included `caveat_name` and it lacked the datastore identity and GC
  horizon tables. Adding `IF NOT EXISTS` would therefore have preserved an obsolete
  schema while reporting success. M3 now runs the dependency-owned executable from
  the same image as `en-server`. The controlling cross-repository ADR is in
  `mori://shinzui/en` at project-relative path
  `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`; an
  artifact-level Mori URI is pending registry coverage.

- Implementation (2026-08-24): the MinIO release tags named during planning still
  exist in Docker Hub's authoritative registry for amd64 and arm64:
  `minio/minio:RELEASE.2025-09-07T16-13-09Z` and
  `minio/mc:RELEASE.2025-08-13T08-35-41Z`.

- Integration reconciliation (2026-08-26): MasterPlan 20 and
  [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  moved encrypted Kubernetes bootstrap credentials out of immutable payloads. The
  installer now resolves
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` or
  `NAGARE_CLUSTER_SECRETS_DIR` before contacting Helm. A source checkout's
  `cluster/secrets/` is only a compatibility fallback, so the remaining rollout must
  not expect `grafana-admin.yaml` inside an installed platform workspace.


## Decision Log

- Decision: no CPU limits anywhere; CPU requests as a guaranteed floor plus a
  memory limit only.
  Rationale: this is the established pattern of the carefully-trimmed
  observability stack (see the comment block in
  `cluster/observability/victoria-metrics/values.yaml` lines 15-26: "with no CPU
  limit VMSingle still bursts... The memory limit guards the small node against
  OOM"). CPU is compressible (throttling, not death); memory is not. On a
  2000m-CPU node the sum of requests must stay small enough for an app (~250m)
  plus a database (~300m) to co-schedule.
  Date: 2026-07-15.
- Decision: nagared gets the largest bounds (requests 100m/256Mi, memory limit
  1Gi); en gets a 384Mi limit; shomei and nagare-access get 256Mi.
  Rationale: nagared's in-pod work during a deploy is a git checkout, a `runghc`
  evaluation of the app's `nagare/Config.hs` against nagare-dsl (GHC
  interpretation — the dominant in-pod memory cost, easily several hundred MiB),
  and kubectl calls; the `docker build` itself executes in the Docker daemon
  reached over the mounted socket, i.e. outside the pod cgroup. A 1Gi limit lets
  a config evaluation finish while capping a runaway at ~12.5% of the node. en
  holds two 10,000-entry in-memory caches (`EN_DECISION_CACHE_MAX_ENTRIES`,
  `EN_TUPLE_READ_CACHE_MAX_ENTRIES` in its Deployment) — small entries, tens of
  MiB at capacity on top of the GHC RTS baseline, hence 384Mi rather than 256Mi.
  shomei (WebAuthn/JWT signer) and nagare-access (stateless auth proxy with a
  30-second decision cache) have no comparable state.
  Date: 2026-07-15.
- Decision: nagared does NOT get the hardened securityContext block in this
  plan.
  Rationale: finding 8 scopes the copy to en, shomei, and the en-migrate Job.
  nagared's runtime contract (header comment in
  `cluster/bootstrap/nagared/service.yaml`) requires docker (a daemon socket),
  kubectl, and git; `drop: [ALL]` + `runAsNonRoot` would need per-capability
  and socket-permission analysis that belongs with the nagared security work
  (EP-98 territory), not here. Left as a recorded gap.
  Date: 2026-07-15.
- Decision: datasource duplication resolved by keeping the standalone files in
  `cluster/observability/grafana/datasources/` as the single source of truth,
  applying them from `install.sh` as ConfigMaps labelled `grafana_datasource=1`,
  and deleting `grafana.additionalDataSources` from the chart values (option
  (a) of the two allowed by the review).
  Rationale: the stack chart already provisions its own VictoriaMetrics
  datasource through the sidecar with exactly this label (chart defaults
  `sidecar.datasources.label: grafana_datasource`, `labelValue: "1"`), and
  `install.sh` already applies dashboards through the identical
  ConfigMap-plus-label pattern (lines 33-37). One mechanism, one source of
  truth, and the sidecar picks up edits without a `helm upgrade`. The
  alternative — deleting the standalone files — would leave datasources as the
  only provisioned objects not represented as files under
  `cluster/observability/grafana/`.
  Date: 2026-07-15.
- Decision: migration idempotence via per-statement guards (`CREATE TABLE IF
  NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`) plus running every file on every
  Job run, rather than a `schema_migrations` tracking table.
  Rationale: the README in `cluster/bootstrap/en/README.md` already declares
  this psql Job a temporary bootstrap wrapper to be replaced by codd when en
  publishes a migration image; a hand-rolled tracking table would be throwaway
  machinery. With guards, re-running all files is a fast no-op, which also
  makes the delete-then-apply Job strategy cheap.
  Date: 2026-07-15.
  Superseded on 2026-08-24 by the dependency-owned migration decision below.
- Decision: run `en-migrate up` from the same tagged image as `en-server`, and
  treat `mori://shinzui/en/packages/en-migrations` as the sole owner of the en
  schema. Nagare must not copy en SQL into a ConfigMap.
  Rationale: en now publishes an append-only, pg-migrate-backed migration
  component and executable. Its accepted schema includes datastore identity
  and garbage-collection horizon state and changed a live uniqueness contract;
  retaining Nagare's guarded bootstrap SQL would silently preserve the obsolete
  schema. The pg-migrate ledger, checksums, advisory lock, and forward-only
  manifest provide the rerun behavior this plan needs without a second schema
  authority. The dependency is `mori://shinzui/pg-migrate`; release 1.1.0.0 was
  verified against Hackage and upstream tag `v1.1.0.0` on 2026-08-24. The
  controlling cross-repository ADR is in `mori://shinzui/en` at
  `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`;
  an artifact-level URI is pending registry coverage.
  Date: 2026-08-24.
- Decision: Job re-run strategy is `kubectl delete job en-migrate
  --ignore-not-found` followed by `kubectl apply`, in both installers, rather
  than content-hash-suffixed Job names.
  Rationale: hash-suffixed names would force both installers and the `kubectl
  wait` lines to compute and thread a dynamic name, and would accumulate
  completed Jobs to garbage-collect. Deleting first loses the previous run's
  pod logs, which is acceptable for an idempotent bootstrap migration; the
  logs of a failed run are inspected before retrying, per the README runbook.
  `kubectl replace --force -f migrations.yaml` was rejected outright: the file
  also contains the `nagare-system` Namespace, and replace --force would
  delete-and-recreate the namespace, cascading away the whole auth plane.
  Date: 2026-07-15.
- Decision: `NAGARE_AUTH_TAG` defaults to `git rev-parse --short HEAD` of this
  repository in `auth-install.sh` and `render-context-template.sh`; `latest`
  becomes an explicit opt-in (`NAGARE_AUTH_TAG=latest`). The local installer
  `cluster/bootstrap/local-auth/install.sh` keeps its `dev` default.
  Rationale: `cluster/bootstrap/knative-serving/config-deployment.yaml` (line
  30) exempts the registry host from Knative's controller-side tag-to-digest
  resolution, so a `:latest` reference is never pinned to a digest — a node
  restart can silently pull a different image. The image builder
  (`cluster/bootstrap/auth-images/build-local-image.sh` line 50) already
  defaults its tag to the same short SHA, so builder and installer agree by
  default. The local k3d registry is rebuilt per session and its `dev` tag is
  deliberately mutable for the edit-rebuild loop; pinning there would only add
  friction with no durability to protect.
  Date: 2026-07-15.
- Decision: MinIO keeps its `emptyDir` data volume, with a comment making the
  volatility explicit, instead of gaining a PVC.
  Rationale: `cluster/local/minio/minio.yaml` exists only in local mode
  (MasterPlan 16) as a GCS stand-in for smoke tests; `just local-down` wipes
  the whole cluster anyway, and `scripts/local-smoke.sh` deletes its snapshot
  object on exit. A PVC would imply a durability promise local mode does not
  make. The comment prevents anyone from mistaking local "backups" for real
  ones.
  Date: 2026-07-15.
- Decision: pin the VictoriaLogs Grafana datasource plugin at 0.31.0 rather than
  the 0.29.0 version found during plan authoring.
  Rationale: the authoritative Grafana plugin catalog lists 0.31.0 as the current
  signed release and declares compatibility with Grafana >=10.4. The repository's
  pinned k8s-stack 0.81.0 embeds Grafana chart 12.3.x, and `helm template` proves
  that the versioned value reaches the generated Grafana ConfigMap.
  Date: 2026-08-24.
- Decision: shared-file ownership with sibling plans (integration points from
  MasterPlan 19): `cluster/observability/victoria-metrics/values.yaml` is also
  edited by `docs/plans/101-alerting-and-backup-freshness-monitoring.md`, which
  enables the `vmalert:` and `alertmanager:` sections (currently
  `enabled: false`, lines 66-70). THIS plan owns the `grafana:` block and
  establishes the Kubernetes Secret contract;
  `docs/plans/101-alerting-and-backup-freshness-monitoring.md` consumes that contract for its
  alert-channel secrets and must not touch the `grafana:` block. The image-tag
  defaulting in M3 interacts with
  `docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`'s
  registry-credential work only at the documentation level (103 syncs docs; no
  shared code).
  Date: 2026-07-15.
- Decision: store the Grafana ciphertext with context-owned operator configuration,
  not in the released platform payload; preserve `monitoring/grafana-admin` and its
  `admin-user`/`admin-password` keys as the stable Kubernetes interface.
  Rationale: ADR 4 makes platform payloads immutable and credential-free. The
  location changed, but the chart and workload should not care where the operator
  keeps the encrypted source. `scripts/lib/cluster-secrets.sh` centralizes resolution
  and makes a missing file a pre-mutation failure.
  Date: 2026-08-26.


## Outcomes & Retrospective

M1, M2, and the code portion of M3 are complete as of 2026-08-24. Offline
manifest assertions, exact pinned Helm renders, sops shape checks, shell
linting, immutable-tag rendering, Docker Hub tag verification, and a disposable
PostgreSQL `en-migrate up`/rerun/verify proof all passed. The implementation
also eliminated a more serious form of drift than the original finding: Nagare
no longer carries stale en SQL and instead consumes en's accepted migration
interface from the same release image.

The plan remains in progress because the complete combined manifests have not yet
been observed with their declared resources/probes on the target cluster, the
observability stack has not been live-verified there, and the installer rerun plus
steady-state resource observations remain. ExecPlan 104
(`docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md`) later proved the
upgraded auth plane and both dependency-owned migrations on a disposable local
cluster, but it did not record the EP-4-specific resource, probe, rerun, and
node-capacity evidence. Those acceptance items remain explicit rather than inferred.

The 2026-08-26 packaging reconciliation made the remaining rollout usable from an
installed release: Grafana ciphertext is operator-owned, the installer finds it by
active context, and a missing file is a pre-mutation refusal. This changes the source
location, not the `monitoring/grafana-admin` Kubernetes contract.


## Context and Orientation

This repository (`nagare`) manages a single-node PaaS: a GCP VM named
`nagare-01` running k3s (a lightweight Kubernetes) with Knative Serving (a layer
that runs HTTP services with autoscaling, including scale-to-zero) on top. The
node has 2 vCPUs (2000 millicores, written `2000m`) and 8 GB of RAM. All
persistent volumes come from the `local-path` provisioner, which carves
directories out of one shared data disk mounted at `/var/lib/nagare/local-path`.
Crucially, local-path treats a PersistentVolumeClaim's requested size as
**advisory** — nothing enforces it — so any store that keeps writing can fill
the disk for everyone.

Two kinds of workload manifest appear in this plan, and their resource syntax
lives in the same place but the objects differ:

- A plain Kubernetes **Deployment** (`apiVersion: apps/v1`, `kind: Deployment`)
  — used by `en` and `shomei`. Container-level fields (`resources`, probes,
  `securityContext`) go under `spec.template.spec.containers[i]`.
- A **Knative Service** (`apiVersion: serving.knative.dev/v1`, `kind: Service`,
  often called "ksvc") — used by `nagared` and `nagare-access`. Container
  fields also go under `spec.template.spec.containers[i]`; the difference is
  that Knative stamps out immutable Revisions from that template and manages
  the underlying Deployment itself. Both `nagared` and `nagare-access` pin
  `autoscaling.knative.dev/min-scale: "1"`, so they are always-on.

The **auth plane** lives under `cluster/bootstrap/`:

- `cluster/bootstrap/en/service.yaml` — Deployment + Service for `en`, a
  relationship-based authorization service (think "who can access which app").
  It sits on the auth decision path. It currently has **no** resources, probes,
  or securityContext. Its container (line 25 onward) configures two
  10,000-entry in-memory caches via env vars (lines 56-59).
- `cluster/bootstrap/en/migrations.yaml` — originally a ConfigMap containing a
  stale copy of en's SQL plus a `postgres:18` Job. M3 reduces it to a Job that
  runs `/usr/local/bin/en-migrate up` from the exact tagged en release image.
  That image carries both `en-server` and `en-migrate`; the dependency-owned
  embedded manifest and pg-migrate ledger decide what applies.
- `cluster/bootstrap/shomei/service.yaml` — Deployment + Service for `shomei`,
  the WebAuthn/passkey signer. Has probes (lines 60-67: readiness `/ready`,
  liveness `/health`) but no resources or securityContext.
- `cluster/bootstrap/nagare-access/service.yaml` — Knative Service for the
  auth proxy. This is the **model file**: it already carries the hardened
  securityContext (lines 18-27: `allowPrivilegeEscalation: false`, drop ALL
  capabilities, `runAsNonRoot` as UID/GID 10001, seccomp `RuntimeDefault`) and
  probes (lines 52-59), but no resources.
- `cluster/bootstrap/nagared/service.yaml` — Knative Service for the deploy
  webhook daemon. Per its own header comment it runs git checkouts, `runghc`
  config evaluation, docker build/push (via a daemon socket), and kubectl. No
  resources (container at line 31).
- `cluster/bootstrap/auth-install.sh` — the cloud installer. It defaults the
  image tag to the current git SHA, recreates both dependency-owned migration
  Jobs, and waits for `job/shomei-migrate` and `job/en-migrate` before applying
  the service manifests.
- `cluster/bootstrap/local-auth/install.sh` — the local-mode (k3d) installer;
  applies the same bases, then patches images/env for the local registry and
  loopback domain. Lines 62-64 apply migrations and wait for the same Job.
- `cluster/bootstrap/render-context-template.sh` — substitutes
  `${NAGARE_REGISTRY_PREFIX}`, `${NAGARE_AUTH_TAG}`, etc. into the manifests.
  Line 23: `auth_tag="${NAGARE_AUTH_TAG:-latest}"`.
- `cluster/bootstrap/knative-serving/config-deployment.yaml` — a merge patch
  that adds the Artifact Registry host to Knative's
  `registriesSkippingTagResolving` (line 30). Consequence: for our registry,
  Knative does NOT resolve tags to digests, so a mutable tag like `latest` is
  genuinely mutable across node restarts. This file is context for M3, not an
  edit target.

The **observability stack** lives under `cluster/observability/` and is
installed by `cluster/observability/install.sh` (idempotent
`helm upgrade --install` per release, chart versions pinned at the top of the
script):

- `victoria-metrics/values.yaml` — values for the `vm/victoria-metrics-k8s-stack`
  chart 0.81.0 (release `vmks`, namespace `monitoring`): VMSingle, VMAgent, and
  Grafana. VMSingle/VMAgent already model the resource pattern this plan copies
  (CPU request floor + memory limit + rationale comment, lines 15-26 and 56-64).
  Problems: line 86 commits a literal Grafana admin password
  (`adminPassword: "change-me-nagare"`) which `install.sh` re-applies on every
  run (line 28-30); lines 94-103 declare the VictoriaLogs/VictoriaTraces
  datasources inline (`additionalDataSources`) while the same datasources also
  exist as standalone files with a "keep the two in sync" comment; lines
  106-107 fetch the `victoriametrics-logs-datasource` plugin unpinned at boot;
  lines 110-114 enable the dashboard and datasource sidecars.
- `victoria-logs/values.yaml` — `vm/victoria-logs-single` chart 0.13.5
  (release `victoria-logs`, namespace `logging`). Lines 5-9: `server:` with
  time-only `retentionPeriod: 7d` and a 20Gi PVC. No disk cap, no resources.
- `victoria-logs/collector-values.yaml` — `vm/victoria-logs-collector` chart
  0.3.4, a Vector-based DaemonSet (one pod per node — i.e. exactly one pod
  here) shipping container logs to VictoriaLogs. No resources.
- `victoria-traces/values.yaml` — `vm/victoria-traces-single` chart 0.1.6
  (release `victoria-traces`, namespace `tracing`). Lines 8-12: `server:` with
  `retentionPeriod: 3d` and a 10Gi PVC. No disk cap, no resources.
- `grafana/datasources/victoria-logs.yaml` and
  `grafana/datasources/victoria-traces.yaml` — Grafana datasource provisioning
  files that nothing applies today (install.sh never references them).
- `opentelemetry-collector/values.yaml` — already fully bounded; the fourth
  model file for the resource pattern.

The **sops secret pattern** (sops is a tool that encrypts values inside YAML
files with an age key): encrypted Kubernetes bootstrap Secrets are mutable
operator configuration, not platform assets. They live under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` by default,
or under `NAGARE_CLUSTER_SECRETS_DIR`; the directory's operator-owned `.sops.yaml`
encrypts only `data`/`stringData`. `scripts/lib/cluster-secrets.sh` implements this
resolution and permits a source checkout's `cluster/secrets/` only as a compatibility
fallback. Decrypt-and-apply remains `sops -d <file> | kubectl apply -f -`.
The selected private identity must match the operator-owned recipient policy; this
plan does not assume the public repository's historical workstation recipient.

**Local testing path**: `just local-smoke` (justfile line 290) runs
`scripts/local-smoke.sh`, which stands up a k3d cluster + local registry + MinIO
(`NAGARE_MODE=local`, no GCP) and exercises deploy → snapshot → restore → HTTP
200 → teardown. `cluster/local/minio/minio.yaml` is that MinIO: images
`minio/minio:latest` (line 55) and `minio/mc:latest` (line 98), data on an
`emptyDir` (line 72).

**Where the numbers must fit**: the node offers 2000m CPU. Existing observability
requests total roughly 100m (VMSingle 50m, VMAgent 25m, otel 25m) plus the
Knative/cert-manager platform. This plan adds ~375m of new requests (see M1/M2),
which still leaves room for an app (~250m) plus a database (~300m) to
co-schedule — the constraint the original trimming was done for. Check the live
picture any time with `kubectl describe node | grep -A8 "Allocated resources"`.


## Plan of Work

The work is three milestones, each independently verifiable and separately
committed. Commit messages follow Conventional Commits and carry the MasterPlan
and ExecPlan trailers, for example:

```text
feat(cluster): bound auth-plane workloads with resources, probes, and securityContext

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/100-bound-and-harden-cluster-workloads.md
```

### Milestone M1 — Resource bounds, probes, and securityContext for the auth plane

Scope: the four auth-plane workload manifests plus the migration Job. At the end
of M1, every auth-plane container declares a CPU request, a memory request, and
a memory limit (no CPU limits — see Decision Log); `en` has readiness/liveness
probes on `/health/ready` and `/health/live`; `en`, `shomei`, and the `en-migrate` Job
carry the same hardened securityContext block `nagare-access` already has.
Verification: rendered manifests pass `kubectl apply --dry-run=client`, and on a
live (local or cloud) cluster the pods reach Running/Ready with the limits
visible in `kubectl describe pod`.

In `cluster/bootstrap/en/service.yaml`, inside the single container entry
(currently starting at line 26 with `- name: en`), add three blocks. First the
securityContext, copied verbatim from `nagare-access/service.yaml` lines 18-27
(safe here because the auth images already run as a non-root `nagare` user with
0555 binaries — see Surprises):

```yaml
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            seccompProfile:
              type: RuntimeDefault
```

Then resources, with a rationale comment in the same voice as
`victoria-metrics/values.yaml`:

```yaml
          # CPU request is a floor, not a cap (no CPU limit, so en can burst);
          # the memory limit guards the 8 GB node. 384Mi (not 256Mi) because en
          # holds two 10,000-entry in-memory caches (EN_DECISION_CACHE_* and
          # EN_TUPLE_READ_CACHE_* below) on top of its RTS baseline.
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 384Mi
```

Then probes. Current en serves servant-health's `GET /health/live` and
`GET /health/ready` endpoints on its main port 8080. Liveness confirms the
process serves HTTP; readiness checks the dependencies needed to accept traffic. To
re-verify against a running pod, port-forward the Deployment and request both paths.

```yaml
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
```

(Liveness deliberately does not use the dependency-readiness path: restarting
replicas during a database outage helps nothing; readiness alone pulls the pod
out of the Service.)

In `cluster/bootstrap/shomei/service.yaml` (container at line 26), add the same
securityContext block and this resources block (probes already exist at lines
60-67 — leave them):

```yaml
          # Floor + memory cap (no CPU limit). Shomei signs WebAuthn/JWT
          # assertions and keeps no large in-memory state.
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
```

In `cluster/bootstrap/nagare-access/service.yaml` (container at line 17;
securityContext and probes already present), add:

```yaml
          # Floor + memory cap (no CPU limit). Stateless proxy; its only cache
          # is the 30s decision TTL below.
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
```

In `cluster/bootstrap/nagared/service.yaml` (container at line 32), add only
resources (no securityContext — Decision Log):

```yaml
          # Largest bounds in the auth plane: a deploy runs git checkout +
          # runghc (GHC interpreting the app's Config.hs against nagare-dsl —
          # the dominant in-pod memory cost) + kubectl. The docker build itself
          # runs in the Docker daemon over the mounted socket, OUTSIDE this
          # cgroup. The 1Gi limit means a runaway config evaluation OOM-kills
          # this pod (min-scale 1 restarts it) instead of the node.
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
```

In `cluster/bootstrap/en/migrations.yaml`, inside the Job's `migrate` container,
add the securityContext block. The en release image already runs as UID/GID
10001 and `en-migrate` only needs its embedded plan plus PostgreSQL access. Add:

```yaml
          # psql streaming two small SQL files; tiny fixed bounds.
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 128Mi
```

New CPU requests added by M1: 50+50+50+100+25 = 275m.

### Milestone M2 — Grafana secret, datasource single-sourcing, and disk-capped log/trace stores

Scope: the observability stack. At the end of M2, Grafana's admin credentials
come from a sops-encrypted Secret `grafana-admin` in the active context's
operator-owned cluster-secret directory; the plugin fetched at boot is
version-pinned; the two datasources are declared once
(as files applied by install.sh, not in chart values); VictoriaLogs and
VictoriaTraces have disk-usage caps sized below their PVCs plus explicit
resources; the Vector collector has resources. Verification: `helm template`
shows the retention flags and resources; after `install.sh`, Grafana login uses
the secret password and lists exactly one VictoriaLogs and one VictoriaTraces
datasource.

For a new context, create the secret in the operator-owned directory (working
directory: repo root; requires `sops`, `openssl`, and an operator-owned
`.sops.yaml` whose rule matches `grafana-admin.yaml`):

```bash
umask 077
context="$(nagarectl context current)"
secret_dir="${NAGARE_CLUSTER_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/${context}}"
mkdir -p "$secret_dir"
cat > "$secret_dir/grafana-admin.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: grafana-admin
    namespace: monitoring
type: Opaque
stringData:
    admin-user: admin
    admin-password: $(openssl rand -base64 24)
EOF
sops --config "$secret_dir/.sops.yaml" -e -i "$secret_dir/grafana-admin.yaml"
grep -c 'ENC\[' "$secret_dir/grafana-admin.yaml"   # must print >= 2 before committing
```

Store the encrypted file and its policy in the private operator repository, not
in a Nagare release. To read the password later:
`sops -d "$secret_dir/grafana-admin.yaml"`.

In `cluster/observability/victoria-metrics/values.yaml`, rewrite the `grafana:`
block (lines 80-114). Replace the `adminPassword` lines (83-86) with:

```yaml
  # Admin credentials come from the sops-managed Secret `grafana-admin`
  # from the active context's operator-owned cluster-secret directory and
  # applied by install.sh BEFORE the chart so the Grafana Deployment can mount
  # it. Grafana persistence is not enabled, so credentials re-seed from the
  # Secret on every pod start.
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

Delete the whole `additionalDataSources:` list (lines 90-103, including its
introductory comment) and replace it with a pointer comment:

```yaml
  # Datasources beyond the chart-provisioned VictoriaMetrics one are declared
  # ONCE, as files under cluster/observability/grafana/datasources/, applied by
  # install.sh as ConfigMaps labelled grafana_datasource=1 for the sidecar
  # below (same mechanism the chart itself uses).
```

Pin the plugin. The Grafana plugin API reported 0.29.0 during planning and
0.31.0 at implementation time; use the verified current release. The pinned
stack chart carries the space-separated pin through
`GF_PLUGINS_PREINSTALL_SYNC`:

```yaml
  plugins:
    - victoriametrics-logs-datasource 0.31.0
```

Keep the `sidecar:` block unchanged (both sidecars stay enabled; the datasource
sidecar is now load-bearing for our two ConfigMaps as well as the chart's own).

Do NOT touch the `alertmanager:`/`vmalert:` section (lines 66-70) — it is owned
by `docs/plans/101-alerting-and-backup-freshness-monitoring.md`.

`cluster/observability/install.sh` now resolves the operator-owned input before
the vmks `helm upgrade` through the shared helper:

```bash
source "${PLATFORM_ROOT}/scripts/lib/cluster-secrets.sh"
SECRETS_DIR="$(nagare_cluster_secrets_dir)"
GRAFANA_SECRET="$(nagare_require_cluster_secret "${SECRETS_DIR}" grafana-admin.yaml)"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
sops -d "${GRAFANA_SECRET}" | kubectl apply -f -
```

Resolution happens before Helm or any cluster mutation, so an absent packaged
secret fails closed. After the vmks install and next to the existing
dashboard-ConfigMap block, the datasource ConfigMaps use the identical pattern:

```bash
for ds in victoria-logs victoria-traces; do
  kubectl -n monitoring create configmap "grafana-datasource-${ds}" \
    --from-file="${ds}.yaml=$ROOT/grafana/datasources/${ds}.yaml" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_datasource=1 -o yaml | \
    kubectl apply -f -
done
```

Update the header comments of both files in
`cluster/observability/grafana/datasources/` to say they are the single source
of truth, applied by `install.sh` as sidecar ConfigMaps — delete the "mirrored
inline in the metrics chart values... Keep the two in sync" sentences.

Rewrite `cluster/observability/victoria-logs/values.yaml` as:

```yaml
# Helm values for vm/victoria-logs-single (chart 0.13.5), installed in the
# `logging` namespace as release `victoria-logs`. VictoriaLogs is the log store;
# it listens on HTTP 9428 for ingest, query (LogsQL), and its UI.
# EP-5 Milestone M2; bounds and disk cap from EP-100.
server:
  retentionPeriod: 7d           # keep logs 7 days (Decision Log)
  # Hard disk cap BELOW the 20Gi PVC request: the local-path provisioner treats
  # PVC sizes as advisory (nothing enforces them), so time-based retention alone
  # can fill the shared data disk. Renders as
  # -retention.maxDiskSpaceUsageBytes=15GiB; VictoriaLogs drops the oldest data
  # once usage reaches the cap. Default unit is GiB.
  retentionDiskSpaceUsage: 15GiB
  # Same pattern as vmsingle/vmagent/otel: CPU request floor (no CPU limit, so
  # ingest spikes can burst) + memory limit to guard the 8 GB node.
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi
  persistentVolume:
    enabled: true
    size: 20Gi                  # storageClassName unset -> default local-path (data disk)
```

Rewrite `cluster/observability/victoria-traces/values.yaml` the same way,
keeping its existing header comment and `retentionPeriod: 3d`, adding
`retentionDiskSpaceUsage: 8GiB` (below the 10Gi PVC) and:

```yaml
  resources:
    requests:
      cpu: 25m
      memory: 128Mi
    limits:
      memory: 512Mi
```

Append to `cluster/observability/victoria-logs/collector-values.yaml`
(top-level key — this chart does not nest under `server:`):

```yaml
# Vector DaemonSet bounds (one pod per node = exactly one pod here). Same
# pattern as the rest of the stack: CPU floor, memory cap, no CPU limit.
resources:
  requests:
    cpu: 25m
    memory: 64Mi
  limits:
    memory: 256Mi
```

New CPU requests added by M2: 50+25+25 = 100m (grand total with M1: 375m).

### Milestone M3 — Dependency-owned migrations, immutable-by-default tags, pinned MinIO

Scope: the migration Job, the auth-image builder, both installers, the render
script, the en bootstrap README, and the local MinIO manifest. At the end of
M3, Nagare delegates schema ownership to en's embedded pg-migrate plan, both
en executables ship in the same tagged image, each installer recreates the Job,
the cloud installer and render script default auth images to the current git
short SHA, and MinIO uses verified immutable release tags with an explicit
local-volatility contract.

Treat `mori://shinzui/en/packages/en-migrations` as the schema authority and
`mori://shinzui/pg-migrate` as its migration engine. The controlling accepted
ADR is in `mori://shinzui/en` at project-relative path
`docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md` (artifact
URI pending). Do not duplicate its SQL in Nagare.

In `cluster/bootstrap/auth-images/build-local-image.sh`, build both
`exe:en-server` and `exe:en-migrate` for service `en`, copy both into the
runtime image. `docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md`
subsequently removed codd and made the same-image contract
apply to Shomei with `shomei-server` plus `shomei-migrate`; the generated Cabal
project tails now mirror the current upstream dependency plans. Remaining M3
validation consumes that combined result and must not restore the historical codd
branch.

In `cluster/bootstrap/en/migrations.yaml`, remove the SQL ConfigMap and mount.
Use the same `${NAGARE_REGISTRY_PREFIX}/en:${NAGARE_AUTH_TAG}` image as the en
Deployment and invoke the embedded migration interface directly:

```yaml
          command: ["/usr/local/bin/en-migrate"]
          args: ["up"]
```

Keep the M1 securityContext and small resource bounds on this Job. The Job's
database environment remains sourced from `en-db-app`; pg-migrate supplies the
ledger, checksum verification, advisory locking, and rerun semantics.

In both `cluster/bootstrap/auth-install.sh` and
`cluster/bootstrap/local-auth/install.sh`, delete `job/shomei-migrate` and
`job/en-migrate` with `--ignore-not-found=true`, render both migration manifests
through `render-context-template.sh` using the installer-selected registry and tag,
apply them, and wait for completion. A completed Job never reruns, and its pod
template is immutable; recreation handles both facts without creating unbounded
hash-suffixed Jobs. The local installer keeps its deliberate `dev` tag default.

In the cloud installer and `cluster/bootstrap/render-context-template.sh`, make
unset `NAGARE_AUTH_TAG` resolve to this repository's short git SHA. Preserve
`NAGARE_AUTH_TAG=latest` as an explicit opt-in and fail only when a template
actually needs the tag but no SHA can be discovered. This matches the builder's
default and avoids silently mutable images at a registry excluded from
Knative's tag-to-digest resolution.

In `cluster/local/minio/minio.yaml`, pin the Docker Hub-verified releases
`minio/minio:RELEASE.2025-09-07T16-13-09Z` and
`minio/mc:RELEASE.2025-08-13T08-35-41Z`. Retain `emptyDir`, with a comment that
local MinIO is a disposable GCS stand-in and its objects do not survive a pod
restart. Both tags were rechecked in Docker Hub's registry for amd64 and arm64
on 2026-08-24.

Finally, update `cluster/bootstrap/en/README.md` to explain the same-image
`en-migrate up` contract, the dependency-owned append-only plan, Job
recreation, failure-log procedure, and canonical Mori package references.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/nagare`) inside the dev shell (`nix develop`
provides kubectl, helm, sops, shellcheck, just).

Step 1 — implement M1 edits (five YAML files as specified in Plan of Work),
then lint-render them offline:

```bash
for svc in en shomei nagare-access nagared; do
  cluster/bootstrap/render-context-template.sh "cluster/bootstrap/${svc}/service.yaml" \
    | kubectl apply --dry-run=client -f - ;
done
kubectl apply --dry-run=client -f cluster/bootstrap/en/migrations.yaml
```

Expected output: one `... created (dry run)` / `configured (dry run)` line per
object and no errors. (`--dry-run=client` validates schema without a cluster
write; it does need a reachable kube API for discovery — point KUBECONFIG at
the local k3d cluster if the cloud tunnel is down.)

Step 2 — commit M1:

```text
feat(cluster): bound auth-plane workloads with resources, probes, and securityContext

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/100-bound-and-harden-cluster-workloads.md
```

Stage files explicitly (`git add cluster/bootstrap/...` path by path — never
`git add -A` in this repo).

Step 3 — implement M2: create and encrypt the active context's
`cluster-secrets/<context>/grafana-admin.yaml` (exact commands in Plan of Work
M2), edit the three values files and the two datasource files, edit
`cluster/observability/install.sh`, then verify the chart-side rendering
offline. The 2026-08-26 reconciliation is part of the final state: the
installer must use `scripts/lib/cluster-secrets.sh`, and released payloads must
not contain `cluster/secrets/`.

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/ && helm repo update
helm template victoria-logs vm/victoria-logs-single --version 0.13.5 -n logging \
  -f cluster/observability/victoria-logs/values.yaml | grep -E 'retention|memory'
helm template victoria-traces vm/victoria-traces-single --version 0.1.6 -n tracing \
  -f cluster/observability/victoria-traces/values.yaml | grep -E 'retention|memory'
helm template victoria-logs-collector vm/victoria-logs-collector --version 0.3.4 -n logging \
  -f cluster/observability/victoria-logs/collector-values.yaml | grep -A4 'resources:'
helm template vmks vm/victoria-metrics-k8s-stack --version 0.81.0 -n monitoring \
  -f cluster/observability/victoria-metrics/values.yaml | grep -E 'GF_SECURITY_ADMIN|GF_PLUGINS_PREINSTALL_SYNC|grafana-admin'
```

Expected in the first two: `--retention.maxDiskSpaceUsageBytes=15GiB` (logs) and
`=8GiB` (traces) among the container args, plus the memory requests/limits. The
logs-single transcript should contain:

```text
            - --retention.maxDiskSpaceUsageBytes=15GiB
            - --retentionPeriod=7d
```

Expected in the last: `GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD`
sourced via `secretKeyRef` from `grafana-admin`, and
`GF_PLUGINS_PREINSTALL_SYNC: victoriametrics-logs-datasource 0.31.0`. Also shellcheck
the installer: `shellcheck cluster/observability/install.sh`.

Step 4 — commit M2 (`feat(observability): ...` with the same trailers). The
public repository stages only the installer/chart changes. Confirm the
operator-owned file is encrypted with
`grep -c 'ENC\[' "$secret_dir/grafana-admin.yaml"` (prints at least 2), and
confirm the release checks prove `cluster/secrets/` is absent from both the
payload and materialized workspace.

Step 5 — implement M3 edits (auth-image builder, migrations.yaml, both
installers, render script, minio.yaml, and en README), then:

```bash
shellcheck cluster/bootstrap/auth-install.sh cluster/bootstrap/local-auth/install.sh \
  cluster/bootstrap/render-context-template.sh \
  cluster/bootstrap/auth-images/build-local-image.sh
cluster/bootstrap/render-context-template.sh cluster/bootstrap/en/migrations.yaml \
  | yq 'select(.kind == "Job")' \
  | yq -e '.spec.template.spec.containers[0] as $c |
      $c.command[0] == "/usr/local/bin/en-migrate" and
      $c.args[0] == "up" and ($c | has("volumeMounts") | not)'
yq -e 'select(.kind == "Deployment") |
  .spec.template.spec.containers[0].image ==
    "minio/minio:RELEASE.2025-09-07T16-13-09Z"' cluster/local/minio/minio.yaml
NAGARE_AUTH_TAG= cluster/bootstrap/render-context-template.sh cluster/bootstrap/en/service.yaml | grep 'image:'
```

Expected: shellcheck has no errors, the migration assertion succeeds, the
MinIO assertion succeeds, and the rendered image line ends in the current
short git SHA, not `:latest`. Then
`NAGARE_AUTH_TAG=latest cluster/bootstrap/render-context-template.sh cluster/bootstrap/en/service.yaml | grep image:`
must end in `:latest` (the opt-in still works).

Prove the dependency-owned migration contract outside Kubernetes with a
disposable PostgreSQL instance: run the current en checkout's `en-migrate up`
twice and `en-migrate verify` once against the empty database. The first run
must report `applied_now`, the second `already_applied`, and verify must report
zero pending and zero unknown migrations. This was completed on 2026-08-24.

Step 6 — commit M3 (`fix(bootstrap): ...` with trailers).

Step 7 — live validation, local first, then cloud (see next section).


## Validation and Acceptance

Local path (no GCP; requires Docker):

1. `just local-smoke` — runs `scripts/local-smoke.sh` (verified: the justfile
   recipe at line 290 is exactly that script), standing up k3d + registry +
   MinIO and driving deploy → snapshot → restore → HTTP 200 → teardown. This
   proves the MinIO pinning and the shared local machinery still work; it ends
   with the smoke app returning HTTP 200 and a clean teardown.
2. Auth plane on the local cluster (needs the three images built by
   `cluster/bootstrap/auth-images/build-local-image.sh` first): run
   `cluster/bootstrap/local-auth/install.sh` once — every pod in
   `nagare-system` reaches Running/Ready and
   `kubectl -n nagare-system describe pod -l app.kubernetes.io/part-of=nagare-auth-plane | grep -A3 Limits`
   shows the memory limits from M1.
3. The migration rerun proof (the behavior that was broken): run
   `cluster/bootstrap/local-auth/install.sh` twice without changing tags.
   Acceptance: both runs complete; the installer recreates `job/shomei-migrate`
   and `job/en-migrate`; each second-run log reports its embedded plan as already
   applied; and the corresponding verify command reports zero pending and zero
   unknown migrations. New migrations are authored and tested in
   `mori://shinzui/shomei/packages/shomei-migrations` or
   `mori://shinzui/en/packages/en-migrations`, not by editing Nagare's Job manifests.
4. Probe proof for en: `kubectl -n nagare-system get pod -l app.kubernetes.io/name=en`
   shows READY 1/1; then scale the en database to zero
   (`kubectl -n nagare-system scale statefulset/en-db --replicas=0` or the
   nagarectl equivalent) and watch en go to READY 0/1 (readiness fails, pod NOT
   restarted — liveness stays green); scale the DB back and READY returns 1/1.

Cloud path (active cloud context, guardrail engaged):

1. `cluster/bootstrap/auth-install.sh` with no `NAGARE_AUTH_TAG` — it must
   render git-SHA image tags (visible in
   `kubectl -n nagare-system get deploy en -o jsonpath='{.spec.template.spec.containers[0].image}'`)
   and complete idempotently on a second run.
2. `nagare observability` (or `cluster/observability/install.sh` from a
   contributor checkout) — resolves `grafana-admin.yaml` from the active context
   and completes; then:
   `kubectl -n logging get sts -o yaml | grep maxDiskSpaceUsageBytes` shows the
   15GiB cap (and 8GiB in `tracing`); Grafana at its Tailscale-only URL rejects
   `admin` / `change-me-nagare` and accepts `admin` plus the password from
   `sops -d "$secret_dir/grafana-admin.yaml"`; Grafana → Connections →
   Data sources lists exactly one VictoriaLogs and one VictoriaTraces entry
   (no duplicates), and Explore against each returns data.

Resource-value tuning is expected, not a failure: the M1/M2 numbers are informed
floors/caps, to be adjusted from observation after a week of steady state.
Observe with `kubectl top pods -A` (k3s bundles metrics-server) for a spot
check, and with VictoriaMetrics for history — in Grafana Explore against the
VictoriaMetrics datasource:

```text
max_over_time(container_memory_working_set_bytes{namespace=~"nagare-system|personal|logging|tracing", container!="", container!="POD"}[7d])
```

for peak memory per container, and

```text
rate(container_cpu_usage_seconds_total{namespace=~"nagare-system|personal|logging|tracing", container!=""}[5m])
```

graphed over days for CPU. Rule of thumb: set the request near typical usage
and keep the memory limit at least 2x the observed 7-day peak; record any
change to the committed values in this plan's Decision Log.

Overall acceptance (all observable): every pod in `nagare-system`, `logging`,
`tracing`, and `monitoring` touched by this plan is Running with a memory limit
set (`kubectl get pods -A -o jsonpath` or `describe`); a second
`auth-install.sh` run after a migration edit succeeds and applies the edit;
Grafana login uses the sops secret; VictoriaLogs/VictoriaTraces args carry the
disk caps; rendered auth images default to a git-SHA tag; `kubectl describe
node` still shows enough unreserved CPU for an app + database (~550m) to
schedule.


## Idempotence and Recovery

Every step here is re-runnable. All `kubectl apply` calls are declarative; both
installers are idempotent by design — `delete job --ignore-not-found` is safe
when the Job is absent, and `en-migrate up` serializes through a PostgreSQL
advisory lock, verifies the append-only manifest against its checksum ledger,
and reports already-applied entries without executing them again. `helm upgrade
--install` re-converges each release. The sops secret
apply (`sops -d | kubectl apply -f -`) is idempotent; re-generating the secret
file with a NEW random password is also safe because Grafana has no persistence
and re-reads the env on pod restart — after rotating, run
`kubectl -n monitoring rollout restart deploy/vmks-grafana` (confirm the exact
deployment name with `kubectl -n monitoring get deploy`).

Riskiest change: the securityContext on `en` and `shomei`. If an image
regression ever makes them need root or a writable path, the rollout will show
CrashLoopBackOff/CreateContainerError; recover by reverting the securityContext
block in the manifest and re-running the installer (Deployments roll back
cleanly; nothing stateful is touched). Watch with
`kubectl -n nagare-system rollout status deploy/en deploy/shomei`.

The Job delete discards the previous run's logs. If a migration run FAILS, do
not immediately re-run the installer — read
`kubectl -n nagare-system logs job/en-migrate` first (the failed Job is left in
place precisely so this works). Do not edit an already-applied migration or
patch SQL into Nagare. Fix the migration component upstream in
`mori://shinzui/en/packages/en-migrations` by appending the appropriate
forward-only migration, rebuild the en release image, and then re-run the
installer. Checksum or unknown-ledger failures are deliberate stop conditions,
not conditions to bypass.

The retention caps only ever delete the OLDEST logs/traces (that is the
documented VictoriaLogs/VictoriaTraces semantics of
`-retention.maxDiskSpaceUsageBytes`), and 15GiB/8GiB sit below the 20Gi/10Gi
PVC requests — tightening a cap later is safe and takes effect on the next helm
upgrade without data-directory surgery.

If the git-SHA tag default selects a SHA for which no image was pushed, the
pods will show ImagePullBackOff; recover by building/pushing for that SHA
(`cluster/bootstrap/auth-images/build-local-image.sh <svc>`) or by explicitly
setting `NAGARE_AUTH_TAG` to a tag that exists. This failure is loud and
harmless — the previous ReplicaSet/Revision keeps serving.


## Interfaces and Dependencies

Tools (all from `nix develop` at the repo root or the released operator
package): `kubectl`, `helm` (>= 3), `sops` with an identity matching the active
context's operator-owned `.sops.yaml`, `openssl`, `shellcheck`, `just`, and
`git`. `NAGARE_CLUSTER_SECRETS_DIR` may override the default context-owned
directory explicitly.

Helm charts and the exact value keys this plan relies on (verified against the
pinned versions with `helm show values` / `helm template`, most recently on
2026-08-24):

- `vm/victoria-metrics-k8s-stack` 0.81.0 — `grafana.admin.existingSecret`,
  `grafana.admin.userKey`, `grafana.admin.passwordKey` (pass through to the
  upstream grafana chart and become `GF_SECURITY_ADMIN_*` env via
  `secretKeyRef`); `grafana.plugins` entries land in
  `GF_PLUGINS_PREINSTALL_SYNC`, which accepts the space-separated
  `<id> <version>` pin syntax; sidecar
  defaults `sidecar.datasources.label: grafana_datasource`, labelValue `"1"`.
- `vm/victoria-logs-single` 0.13.5 and `vm/victoria-traces-single` 0.1.6 —
  `server.retentionDiskSpaceUsage` (default unit GiB, renders as
  `--retention.maxDiskSpaceUsageBytes=<v>`), `server.retentionPeriod`,
  `server.resources`, `server.persistentVolume.size`.
- `vm/victoria-logs-collector` 0.3.4 — top-level `resources`.

Kubernetes objects and contracts that must hold at the end:

- Deployments `en`, `shomei` and Jobs `en-migrate`, `shomei-migrate`
  (namespace `nagare-system`)
  and Knative Services `nagare-access` (`nagare-system`) / `nagared`
  (`personal`): container 0 has `resources.requests.cpu`,
  `resources.requests.memory`, `resources.limits.memory`; `en`, `shomei`,
  `nagare-access`, and the Job container carry the securityContext
  {`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `runAsNonRoot: true`, `runAsUser/runAsGroup: 10001`,
  `seccompProfile.type: RuntimeDefault`}.
- en's probe endpoints: `GET /health/ready` for readiness and
  `GET /health/live` for liveness on port 8080, matching the current
  servant-health interface in `mori://shinzui/en/packages/en-server`.
- Job `en-migrate` uses the exact same registry prefix and tag as the en
  Deployment and invokes `/usr/local/bin/en-migrate up`. The image builder must
  therefore ship both `en-server` and `en-migrate`. The schema/manifest owner is
  `mori://shinzui/en/packages/en-migrations`; its released migration engine is
  `mori://shinzui/pg-migrate` 1.1.0.0.
- Job `shomei-migrate` follows the same same-image contract for Shomei and is
  owned by `mori://shinzui/shomei/packages/shomei-migrations`.
  `docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md` added this
  Job after EP-4 established the pattern; the remaining live rerun must cover both.
- Secret `grafana-admin` (namespace `monitoring`, keys `admin-user`,
  `admin-password`), stored encrypted at
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/grafana-admin.yaml`
  (or below `NAGARE_CLUSTER_SECRETS_DIR`) under the operator-owned `.sops.yaml`
  rule; applied by `cluster/observability/install.sh` before the vmks chart.
  A source checkout's `cluster/secrets/` is only a compatibility fallback and
  is absent from released payloads. This is the reusable sops-secret pattern
  that `docs/plans/101-alerting-and-backup-freshness-monitoring.md` consumes for
  alert-channel secrets.
- ConfigMaps `grafana-datasource-victoria-logs` /
  `grafana-datasource-victoria-traces` (namespace `monitoring`, label
  `grafana_datasource=1`) built from the files in
  `cluster/observability/grafana/datasources/`.
- `NAGARE_AUTH_TAG` semantics: unset → git short SHA of this repo;
  `latest` → explicit mutable opt-in; any other value → used verbatim. Shared
  by `cluster/bootstrap/auth-install.sh` and
  `cluster/bootstrap/render-context-template.sh`; the local installer keeps
  `dev`.

Cross-plan boundaries (MasterPlan 19 integration points): this plan owns the
`grafana:` block of `cluster/observability/victoria-metrics/values.yaml` and
the `monitoring/grafana-admin` Secret contract;
`docs/plans/101-alerting-and-backup-freshness-monitoring.md`
owns the `vmalert:`/`alertmanager:` sections of the same file and must not
touch the `grafana:` block. ADR 4 owns the context-directory boundary, and the
shared installer resolves it with `scripts/lib/cluster-secrets.sh`. Image-tag
defaulting touches
`docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`
only at the documentation level.

---

Revision note (2026-07-15): rewritten from the skeleton into the full ExecPlan
for MasterPlan 19 finding group 4 ("Bound and harden cluster workloads"),
after verifying all nine review findings against the working tree, the en
source checkout, and the pinned Helm charts. Reason: initial authoring.

Revision note (2026-08-24): replaced the planned Nagare-owned guarded SQL
ConfigMap with the dependency-owned `en-migrate` interface, extended the en
release image to carry both executables, updated the rerun/recovery contract,
and refreshed Grafana plugin rendering details. Reason: the en dependency's
accepted pg-migrate component made the original bootstrap approach both stale
and unsafe.

Revision note (2026-09-15): reconciled the remaining live rollout with
`docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md`'s
current servant-health paths and two migration Jobs, and with ADR 4's
context-owned encrypted-secret boundary. The historical EP-4 implementation
evidence remains intact; current operator commands now consume the combined
manifests and packaged secret resolver instead of obsolete checkout paths.
