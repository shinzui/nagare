---
id: 16
slug: local-development-and-testing-for-nagare
title: "Local development and testing for nagare"
kind: master-plan
created_at: 2026-06-30T00:56:26Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
---

# Local development and testing for nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today **nagare** can only run on Google Cloud Platform (GCP). The platform is a single-node personal
PaaS — one project equals one [Knative](https://knative.dev/) Service, deployed with `nagarectl deploy`
— but every layer is welded to GCP: the cluster is [k3s](https://k3s.io/) on a NixOS Compute Engine VM
(`nagare-01`); container images live in Artifact Registry and `nagarectl` authenticates `docker push`
by shelling out to `gcloud auth configure-docker`; the public apps domain comes from Cloud DNS and TLS
is minted by cert-manager via a DNS-01 ACME challenge against that zone; database and volume backups are
moved by an in-cluster Kubernetes Job that authenticates to a Cloud Storage (GCS) bucket through the GCE
metadata server; and the shell scripts that drive the cluster refuse to run unless `gcloud`'s active
project equals the configured GCP target. Because of all this, the only way to exercise a real
end-to-end use case — deploy an app, attach a managed database, snapshot and restore a volume, put an
app behind login — is to stand up billable cloud infrastructure and run against the live VM. There is no
way to try nagare on a laptop.

After this initiative is complete, an operator can run nagare **entirely on their own machine, with no
GCP account and no cloud resources**, to test the platform's real use cases. Concretely: they run a
single command (`just local-up`) that creates a local Kubernetes cluster with a local image registry and
installs the same Knative + Kourier ingress stack the cloud uses; they enter local mode (a git-ignored
`nagare.local.env` profile selected by `NAGARE_MODE=local`); and from there the *same* `nagarectl`
commands they would run against the cloud work against the local cluster. `nagarectl deploy` builds the
app image, pushes it to the local registry, and applies a Knative Service reachable over HTTP at a
loopback-resolving hostname (for example `myapp.127-0-0-1.sslip.io`); `nagarectl db create postgres …`
stands up an in-cluster Postgres and wires its credentials; `nagarectl db backup` / `storage snapshot`
and their restores round-trip through a local S3-compatible object store instead of GCS; a scheduled
task runs as a Kubernetes CronJob; a messaging broker (Redpanda) runs as a StatefulSet; and an app
marked "require login" is fronted by the real Shomei + en + nagare-access auth plane running locally
behind locally-trusted TLS. A `just local-smoke` runs the same deploy → snapshot/restore → HTTP-200 →
teardown scenario that the cloud `just smoke` runs, but with zero cloud dependencies, so the platform's
core paths can be regression-tested on any developer machine.

The unifying concept is **local mode**: a second, parallel *target* for nagare that swaps each
GCP-backed primitive for a local equivalent — Artifact Registry → a local registry; Cloud DNS + DNS-01
TLS → a wildcard loopback domain + a locally-trusted self-signed certificate; GCS backups → a local
MinIO object store; the GCE-VM-on-NixOS substrate → a [k3d](https://k3d.io/) cluster (k3s packaged to
run inside Docker); the IAP-tunnel cluster access → a direct kubeconfig. Local mode is selected by one
environment variable (`NAGARE_MODE=local`, sourced from a git-ignored `nagare.local.env`), mirroring how
the existing **target profile** (`nagare.target.env`, see
`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`) already makes the GCP target
configurable. The existing cloud path is unchanged: with no local profile and `NAGARE_MODE` unset,
nagare behaves exactly as it does today.

In scope: a local cluster + registry bootstrap harness; making `nagarectl`'s build/push/deploy path
GCP-free in local mode (conditional Docker auth, local registry host, loopback base domain, host-arch
build platform); verifying the already-portable in-cluster data subsystems (managed databases as
StatefulSets, the Redpanda broker, scheduled-task CronJobs, local-path persistent volumes) run on the
local cluster and giving their backup/restore/snapshot paths a local object-store backend in place of
GCS; standing up the auth plane (Shomei identity, en authorization, the nagare-access forward-auth
enforcer) locally with locally-trusted TLS so "require login" apps can be tested; making the
project-isolation guardrail and the test scripts local-mode-aware so a local run never trips the
fail-closed GCP-project check and a cloud run still does; a local end-to-end smoke test; and the
developer documentation for the whole local workflow.

Explicitly out of scope: **reproducing the NixOS host or the Pulumi-provisioned cloud infrastructure
locally** — local mode replaces the *substrate* (a k3d cluster) rather than emulating the GCE VM, so the
`nixos/` host configuration and `infra/pulumi/` provisioning are untouched and untested by this work.
**CDN integration** is out of scope: the CDN layer (Cloudflare or Google Cloud CDN, see
`docs/masterplans/11-cdn-integration-for-nagare.md`) is optional and defaults to off (`cdn = Nothing`);
local mode simply skips it, and exercising the CDN seam locally (e.g. against a mock Cloudflare API) is
explicitly deferred. **Production-grade local TLS or a real public domain** is out of scope — local TLS
exists only to satisfy the WebAuthn secure-context requirement and browser trust on the developer's
machine, not to be publicly valid. Finally, this initiative does not change *what* nagare deploys (the
Knative Service shape, the DSL, the database engines); it changes only *where* and *how* an operator can
run it for testing.


## Decomposition Strategy

The initiative was decomposed by **the layer at which each GCP dependency lives**, because the
substitutions are independent and each ends in a behavior you can verify on its own. The research that
seeded this plan (recorded in the Decision Log) found the dependencies cluster into five separable
concerns: the cluster substrate, the CLI build/deploy path, the in-cluster data subsystems and their
backup backend, the auth plane, and the test harness plus docs. Five child plans result, inside the
recommended two-to-seven range, grouped into four implementation waves.

The keystone is **EP-82**, which builds the local substrate and defines the **local-target contract**.
It stands up a k3d cluster with a local registry and installs the Knative + Kourier stack in a
local-friendly way (HTTP-first, no DNS-01, a loopback wildcard domain, tag-resolution skipped for the
local registry), and it specifies the `nagare.local.env` profile and the `NAGARE_MODE=local` switch that
every other plan reads. It also makes the shell guardrail (`scripts/lib/target.sh`) local-mode-aware so a
local run does not trip the fail-closed GCP-project check. Nothing else can deploy or be verified until a
cluster exists and the mode switch is defined, so EP-82 comes first and is deliberately the broadest of
the five.

**EP-83** is the CLI layer: it teaches `nagarectl`'s `Nagare.Target`/`Nagare.Image` code to resolve a
*mode* and, in local mode, skip `gcloud auth configure-docker`, push to the local registry, build for the
host architecture, and serve apps on the loopback base domain — so `nagarectl deploy` (and the static
`site` and `server` deploy paths) works end to end against the EP-82 cluster with no gcloud. It
hard-depends on EP-82 because it needs both the contract values it resolves and a cluster to demonstrate
a real deploy against.

**EP-84** and **EP-85** are the two subsystem-parity plans and run in parallel after EP-83. EP-84 covers
the data plane: it verifies that managed databases (StatefulSets), the Redpanda broker, scheduled-task
CronJobs, and local-path volumes — all already cloud-agnostic in their *create* path — actually run on the
local cluster, and it gives the one genuinely GCP-coupled path, the shared data-movement Job in
`Nagare.Cluster.GcsJob` used by `db backup`/`db restore`/`storage snapshot`/`storage restore`, a local
object-store backend (MinIO) so backups and restores round-trip without GCS or the GCE metadata server.
EP-85 covers the auth plane: it builds the Shomei, en, and nagare-access images into the local registry,
installs them with a local managed Postgres, supplies a locally-trusted TLS issuer (so WebAuthn's
secure-context requirement is met), and makes a "require login" app testable locally. The two are
independent — disjoint code and manifests — but EP-85 soft-depends on EP-84 because the auth services need
a managed Postgres, whose *create* path EP-84 exercises and documents locally (the create path itself only
needs the EP-82 cluster, so the dependency is soft, not hard).

**EP-86** is the harness-and-docs layer: a `just local-smoke` that runs the cloud smoke scenario locally
and the `docs/user/local-development.md` runbook tying the whole workflow together. It soft-depends on all
four because it demonstrates and documents their delivered behavior, and it is finalized last so the
runbook matches what shipped.

A central design decision shaping the boundaries (see Decision Log): **local mode is a parallel target
selected by `NAGARE_MODE`, not a rewrite of the existing target profile.** This was chosen over
overloading `nagare.target.env` with local values because the two targets differ in kind — one points at
real GCP resources and must stay fail-closed under the project guardrail, the other points at loopback
substitutes and must explicitly *bypass* that guardrail — and conflating them risks a local profile
silently disarming the cloud safety check or vice versa. Keeping them separate files with an explicit
mode switch makes "am I about to act on the cloud or on my laptop?" unambiguous at every layer.

Alternatives considered and rejected. **One mega-plan ("make it run locally")**: rejected — the work
spans shell/k8s bootstrap, Haskell CLI internals, in-cluster Job rendering, a three-service auth plane,
and docs across unrelated toolchains; it could not be verified incrementally. **Splitting EP-82's cluster
harness from the local-target contract**: considered and rejected — the contract is small and the
bootstrap is its first and only consumer at that stage, so a separate keystone (as MasterPlan 12 used for
its profile contract) would add a plan boundary with no parallelism gain; instead the contract is EP-82's
first milestone. **Folding the GCS-free backup work into EP-84's data plan vs. giving it its own plan**:
kept inside EP-84 because the only coupled artifact is the single `Nagare.Cluster.GcsJob` module and the
verification (a snapshot/restore round-trip) is the same scenario that proves the data plane works
locally — splitting them would separate one change from its own test. **Making the auth plane part of
EP-84 (since it needs Postgres)**: rejected — the auth plane is its own functional concern with its own
images, manifests, TLS, and cookie-domain story, and bundling it would unbalance the plans; the Postgres
need is modeled as a soft dependency instead. **Doing local TLS as a sixth plan**: rejected — local TLS
exists *for* the auth plane (WebAuthn secure context) and is meaningless without it, so it lives in EP-85.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 82 | Local cluster, registry, and local-target bootstrap for nagare | docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md | None | None | Complete |
| 83 | Decouple nagarectl deploy and build from GCP for local mode | docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md | EP-82 | None | Complete |
| 84 | Local data services and GCS-free backups and snapshots for nagare | docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md | EP-83 | EP-82 | Complete |
| 85 | Local auth plane and TLS for nagare protected apps | docs/plans/85-local-auth-plane-and-tls-for-nagare-protected-apps.md | EP-82, EP-83 | EP-84 | Not Started |
| 86 | Local smoke test parity and developer documentation for nagare | docs/plans/86-local-smoke-test-parity-and-developer-documentation-for-nagare.md | EP-82 | EP-83, EP-84, EP-85 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-82, EP-84).

Implementation waves (phases):

- **Wave 1 — Substrate + contract:** EP-82. Creates the local k3d cluster + local registry, the
  local-mode bootstrap of Knative/Kourier, the `nagare.local.env` contract and `NAGARE_MODE` switch, and
  the local-mode-aware guardrail. Nothing else can deploy or be verified until this exists.
- **Wave 2 — CLI decoupling:** EP-83. Resolves a mode in `nagarectl` and makes build/push/deploy GCP-free
  in local mode. Hard-depends on EP-82 (needs the contract values and a cluster to deploy against).
- **Wave 3 — Subsystem parity (parallel):** EP-84 (data services + GCS-free backups) and EP-85 (auth plane
  + local TLS). Disjoint code/manifests; both build on EP-83's local-mode plumbing. EP-85 soft-depends on
  EP-84 for the managed-Postgres create path.
- **Wave 4 — Harness + docs:** EP-86. A local end-to-end smoke test and the developer runbook; drafted from
  Wave 1 onward, finalized after EP-85 so the docs match shipped behavior.


## Dependency Graph

EP-82 (local cluster + contract) has no dependencies. It is the foundation: it creates the k3d cluster
and local registry, the `nagare.local.env.example` + `NAGARE_MODE=local` switch, the local-mode bootstrap
of Knative/Kourier (Integration Point 4), and the local-mode-aware guardrail (Integration Point 6). Every
other plan needs either the cluster it stands up, the contract variables it fixes, or both.

EP-83 (CLI decoupling) **hard-depends on EP-82** because its acceptance is "`nagarectl deploy` works in
local mode against the cluster," which requires EP-82's cluster, local registry, and the
`NAGARE_REGISTRY_HOST`/`NAGARE_BASE_DOMAIN`/`NAGARE_MODE` values EP-82's contract defines. EP-83 owns the
Haskell mode-resolution type and the conditional Docker auth (Integration Point 2), which the later plans
reuse.

EP-84 (data services + GCS-free backups) **hard-depends on EP-83** and **soft-depends on EP-82**. The hard
dependency is on EP-83's local-mode resolution in `Nagare.Target`: EP-84 generalizes
`Nagare.Cluster.GcsJob` to emit a GCS Job in cloud mode and a local-object-store Job in local mode
(Integration Point 3), and that branch is driven by the same `tpMode` EP-83 introduces. It soft-depends on
EP-82 because the data subsystems (databases, broker, tasks, volumes) need the EP-82 cluster to run on, but
their *manifests* are unchanged and could be unit-rendered without it — the dependency is "needs a cluster
to demonstrate," which EP-82 provides.

EP-85 (auth plane + local TLS) **hard-depends on EP-82 and EP-83** and **soft-depends on EP-84**. It hard
needs EP-82 (the cluster and its local-mode bootstrap, onto which it layers the auth-plane manifests and a
local TLS issuer — Integration Points 4 and 5) and EP-83 (to *build and push* the Shomei, en, and
nagare-access images into the local registry, which is exactly EP-83's decoupled build/push path). It soft
needs EP-84 because Shomei and en require a managed Postgres; that Postgres comes from `nagarectl db
create postgres`, whose create path runs on the EP-82 cluster without EP-84, but EP-84 is where running
managed databases locally is verified and documented, so EP-85 benefits from it being done first.

EP-86 (smoke + docs) **hard-depends on EP-82** (the smoke test drives the cluster EP-82 stands up) and
**soft-depends on EP-83, EP-84, EP-85** because the end-to-end scenario and the runbook exercise and
describe their behavior. Its prose can be drafted from Wave 1 onward and is finalized after EP-85.

Parallelism: after EP-82, EP-83 is the single Wave-2 plan. After EP-83, EP-84 and EP-85 run in parallel
(disjoint files; EP-85's only tie to EP-84 is soft). EP-86 begins once EP-82 exists and is finalized after
EP-85.


## Integration Points

**1. The local-target contract (defined by EP-82; consumed by EP-83, EP-84, EP-85, EP-86).** EP-82 is the
single source of truth for the local target. The contract is a git-ignored file `nagare.local.env` at the
repo root (a sequence of `export VAR=value` lines), with a tracked `nagare.local.env.example` carrying the
schema and worked example, mirroring the existing `nagare.target.env` from MasterPlan 12. The canonical
variables every consumer reads are: `NAGARE_MODE` (the switch; `local` selects local mode, unset/`cloud`
preserves today's behavior), `NAGARE_REGISTRY_HOST` (the local registry, e.g. `k3d-registry.localhost:5000`
— a value that resolves both from the host doing `docker push` and from in-cluster containerd doing the
pull; EP-82 fixes the exact string and documents the host/etc-hosts setup it needs), `NAGARE_BASE_DOMAIN`
(a wildcard-loopback domain such as `127-0-0-1.sslip.io` so `<app>.<base>` resolves to `127.0.0.1` with no
DNS setup), `NAGARE_TARGET_PLATFORM` (the developer's host architecture, e.g. `linux/arm64` on Apple
Silicon, so locally-built images run on the local node), and `NAGARE_LOCAL_OBJECT_STORE` (the in-cluster
MinIO endpoint + bucket used for backups, consumed by EP-84). EP-82 owns this list; a later plan needing a
new local field adds it to EP-82's `.example` and this section and notifies the other consumers. Precedence
matches MasterPlan 12: environment > profile > built-in default.

**2. The Haskell mode resolution and conditional Docker auth (defined by EP-83; consumed by EP-84, EP-85).**
EP-83 extends `cli/nagarectl/src/Nagare/Target.hs`'s `TargetProfile` record with a resolved *mode* (read
from `NAGARE_MODE`; the new field, e.g. `tpMode :: Mode` with `data Mode = Cloud | Local`) and makes
`cli/nagarectl/src/Nagare/Image.hs`'s `configureDockerAuth` a no-op (or a local-registry `docker login`)
when the mode is `Local` instead of unconditionally calling `gcloud auth configure-docker`
(`Nagare/Image.hs:96-106`, called from `Nagare/App/Deploy.hs:440`). EP-84 and EP-85 must read this same
`tpMode` to branch their own behavior (EP-84 the backup backend, EP-85 nothing GCP-specific but it reuses
the local registry host derivation). EP-83 owns the `Mode` type and its resolution; later plans import it,
never re-derive the mode from the environment themselves.

**3. The data-movement Job backend (defined by EP-84; affects EP-86).** `cli/nagarectl/src/Nagare/Cluster/
GcsJob.hs` renders the one canonical Kubernetes Job that `db backup`, `db restore`, `storage snapshot`, and
`storage restore` all use to move data to/from GCS, authenticating via the GCE metadata server with the
`google/cloud-sdk:slim` image (`GcsJob.hs:47-69`). EP-84 generalizes this single module so that in local
mode it instead targets the MinIO object store from Integration Point 1 — swapping the container image and
the move commands (e.g. `mc`/`aws s3` against the MinIO endpoint) and dropping the metadata `hostAliases`/
env, while leaving the cloud path byte-for-byte unchanged. Because all four data-movement verbs render
through this one module, EP-84 changes exactly one rendering point. EP-86's smoke test exercises the local
branch (a snapshot/restore round-trip) as its acceptance.

**4. The local-mode cluster bootstrap (defined by EP-82; consumed/extended by EP-85).** The cloud bootstrap
is the `just cluster-bootstrap` recipe (`justfile:82-101`) plus the manifests under `cluster/bootstrap/`.
EP-82 produces a local-mode bootstrap — a new recipe (e.g. `just local-bootstrap`) or a parameterized form
of the existing one — that installs cert-manager, Knative Serving, Kourier, and net-certmanager but: skips
the Cloud-DNS DNS-01 `ClusterIssuer` (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`, which hard-
codes a GCP project and uses ambient GCE credentials); sets `config-domain` to `NAGARE_BASE_DOMAIN` from
the profile instead of `pulumi stack output baseDomain` (`justfile:93`); and points
`registriesSkippingTagResolving` at the local registry instead of the Artifact Registry host
(`justfile:99-101`, `cluster/bootstrap/knative-serving/config-deployment.yaml:30`). EP-85 extends this same
local bootstrap by adding the auth-plane namespaces/manifests and the local TLS issuer (Integration Point
5) on top; it must apply *after* EP-82's bootstrap and reuse its namespace/ConfigMap conventions, not fork
them.

**5. The local TLS issuer (defined by EP-85; depends on EP-82's cert-manager install).** The cloud path
gets browser-trusted wildcard TLS from Let's Encrypt via DNS-01 (the issuer EP-82's local bootstrap skips).
EP-85 introduces a local `ClusterIssuer` — a self-signed/`mkcert`-rooted issuer whose CA the developer
trusts on their machine — so that apps and the auth plane are reachable over HTTPS locally. This is
required specifically because WebAuthn (the second factor Shomei uses) only works in a browser "secure
context" (HTTPS, or `localhost`); a loopback wildcard domain like `127-0-0-1.sslip.io` is *not* `localhost`,
so plain HTTP would block the login flow. EP-85 owns this issuer; it consumes the cert-manager installation
that EP-82's bootstrap performs. Apps that do not require login still work over plain HTTP, so this issuer
is needed only when EP-85's auth path is exercised.

**6. The local-mode-aware guardrail (defined by EP-82; consumed by EP-86).** Today `scripts/lib/target.sh`
exposes `_require_target_project`, which refuses to run unless `gcloud`'s active project equals the
configured GCP target (`scripts/lib/target.sh:45-54`); `scripts/live-test.sh` and `scripts/live-smoke.sh`
call it (`live-smoke.sh:21`). A local run has no GCP project, so this check would block it. EP-82 makes the
helper mode-aware: when `NAGARE_MODE=local`, `_require_target_project` short-circuits to success (it is a
*GCP* guardrail and there is no GCP target to protect), while a complementary check ensures local mode is
genuinely not pointed at real cloud resources. The cloud guardrail remains fail-closed when
`NAGARE_MODE` is unset/`cloud` — local mode must never weaken the existing protection, only step aside when
there is nothing to protect. EP-86's `just local-smoke` sources the same helper and relies on this behavior;
no plan may make the cloud branch anything but fail-closed.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-82: `nagare.local.env.example` + `NAGARE_MODE` switch defined and git-ignore entry added; `just local-up`/`local-down` create and destroy a k3d cluster with a working local registry. (Done 2026-06-29.)
- [x] EP-82: `just local-bootstrap` installs Knative + Kourier on the local cluster HTTP-first (no DNS-01, loopback `config-domain`, local registry in `registriesSkippingTagResolving`); `scripts/lib/target.sh` is local-mode-aware (cloud branch still fail-closed). (Done 2026-06-29.)
- [x] EP-83: `Nagare.Target` resolves a `Mode`; `configureDockerAuth` is skipped/local in local mode; `nagarectl deploy` builds, pushes to the local registry, applies, and returns HTTP 200 from a loopback hostname with no gcloud. (Done 2026-06-29 — dockerfile-app served HTTP 200; zero-gcloud proven by a failing-shim redeploy.)
- [x] EP-83: the static `site` and `server` deploy paths work in local mode (host-arch build platform, local registry, loopback domain). (Done 2026-06-29 — static-site served HTTP 200; server path verified by shared construction; M4.2 → no `--platform` change.)
- [x] EP-84: managed databases (Postgres `pgdemo`, Redis `rdemo`), the Redpanda broker (`demo`), a scheduled-task CronJob, and a `local-path` volume app (`uploads-volume`) demonstrated running `Ready`/`Bound`/`Complete` on the local cluster. (Done 2026-06-29.)
- [x] EP-84: `Nagare.Cluster.GcsJob` renders a local-object-store (MinIO) Job in local mode; `db backup`/`db restore --into-live` round-tripped `hello-local` and `storage snapshot`/`storage restore --into-live` round-tripped `hello-volume` through MinIO with no GCS/metadata server; cloud bytes unchanged (`NAGARE_MODE` unset dry-run). (Done 2026-06-29.)
- [ ] EP-85: Shomei, en, and nagare-access images build+push to the local registry and install with a local managed Postgres; a local TLS issuer provides a locally-trusted cert.
- [ ] EP-85: an app marked "require login" is fronted by the local auth plane and completes a login over locally-trusted HTTPS.
- [ ] EP-86: `just local-smoke` runs deploy → snapshot/restore → HTTP 200 → teardown locally with zero cloud dependencies.
- [ ] EP-86: `docs/user/local-development.md` documents the full local workflow; the local mode is reconciled with `CLAUDE.md`/getting-started.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- **Local-mode host `docker push` requires a Docker `insecure-registries` entry for
  `NAGARE_REGISTRY_HOST` (EP-82 → affects EP-83).** Integration Point 1 calls the local registry a
  "value that resolves both from the host doing `docker push` and from in-cluster containerd"; EP-82
  verification found name resolution is not the issue (`.localhost` is loopback by RFC 6761) — the
  registry serves plain HTTP and Docker attempts HTTPS for the *named* host, failing with `server gave
  HTTP response to HTTPS client`. The in-cluster pull works unaffected (k3d injects `registries.yaml`).
  So local mode has a host-side operator prerequisite: add `k3d-registry.localhost:5000` to Docker's
  `insecure-registries` (Docker Desktop/Colima/Linux variants documented in `nagare.local.env.example`).
  **EP-83 must assume this prerequisite is met** for its `docker push` step; it does not need extra
  code, but its docs/runbook (and EP-86's) should reference the prerequisite. Date: 2026-06-29.

- **The local k3s must be pinned to k8s >= 1.34 (EP-82 → affects EP-85, EP-86).** k3d's default k3s
  was v1.21.7, too old for both cert-manager v1.20.2 (CRD `selectableFields`) and Knative v1.22.0
  (which hard-refuses k8s < 1.34.0). EP-82 added a `k3s_image := "rancher/k3s:v1.34.6-k3s1"` pin to
  `just local-up`. Any plan that recreates the local cluster (EP-86's smoke teardown/setup) must use
  `just local-up` (which carries the pin), not raw `k3d cluster create`. The pin moves in lockstep
  with the `knative_version`/`certmanager_version` pins. Date: 2026-06-29.

- **Literal `curl http://<app>.<base-domain>` can be intercepted by a host process on port 80
  (EP-82 → affects EP-86).** On the development host used here a pre-existing Caddy holds host port
  80, so the k3d `80:80@loadbalancer` mapping is shadowed; the real Knative path was proven via
  `kubectl -n kourier-system port-forward svc/kourier` + a `Host:` header (200, `server: envoy`,
  expected body). EP-86's `just local-smoke` should curl through a Kourier port-forward (robust to
  host port-80 conflicts) rather than assuming host port 80 is free. Date: 2026-06-29.

- **The local data-movement client image lacks `tar`/`gzip`, and the creds Secret is
  namespace-local (EP-84 → affects EP-85, EP-86).** Two gaps surfaced on the first live local
  backup. (1) `amazon/aws-cli:latest` (and `minio/mc:latest`) ship neither `tar` nor `gzip`, so
  `gzip | aws s3 cp -` wrote a 0-byte object; EP-84's fix is a `dnf install -y -q tar gzip`
  preamble in the MinIO data-movement shells (local mode only; cloud bytes unchanged), adding
  ~12 s to the first such Job. **EP-86's `just local-smoke` inherits this one-time cost.** (2)
  The Job's `secretKeyRef` to `nagare-minio-credentials` is namespace-local, so
  `cluster/local/minio/minio.yaml` seeds the Secret into both `nagare-system` and the default
  app/db namespace `personal`; **apps/databases in other namespaces need it copied there, which
  EP-86's runbook must document** (analogous to EP-82's insecure-registry prerequisite). EP-85's
  auth-plane Postgres lives in its own namespace and uses `db backup` only if its operator runs
  one, but EP-85 should be aware the creds Secret is per-namespace. Date: 2026-06-29.

- **A local managed Postgres comes up `Ready` and connects with no GCP (EP-84 → unblocks EP-85's
  soft dep).** `nagarectl db create postgres pgdemo` brought up the StatefulSet `1/1` with a
  `local-path` PVC `Bound` and the backup CronJob rendered against MinIO — confirming the
  managed-Postgres create path EP-85 soft-depends on works locally. EP-85 can stand up the
  Shomei/en Postgres the same way. Date: 2026-06-29.

- **The DSL image-ref validator needed a fix for the ported local registry (EP-83 → affects
  EP-84/EP-85).** `Nagare.Dsl.Types.mkImageRef` rejected every `:`, which broke
  `k3d-registry.localhost:5000/...` (the port colon read as a tag). Fixed to detect a tag only after
  the last `/`. Any later plan that qualifies an image against the ported registry (EP-84's data
  images, EP-85's auth-plane images) now works because the fix is in the shared DSL constructor; no
  per-plan action needed, but EP-84/EP-85 should expect their image refs to carry the `:5000` port.
  Date: 2026-06-29.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: nagare will support a first-class **local mode** that runs the platform end to end on a
  developer's machine with no GCP account, for testing real use cases (deploy, managed DB, snapshot/
  restore, require-login). This MasterPlan authorizes that capability and decomposes it.
  Rationale: The owner asked "how hard is it to run nagare locally to make testing some use cases easy,"
  and after seeing that only the cluster substrate, the CLI build/push auth, the GCS backup backend, the
  auth plane's domain/TLS, and the test scripts are GCP-coupled (everything else — Knative manifests,
  database StatefulSets, the Redpanda broker, CronJob tasks, local-path volumes — is already portable),
  chose **full local parity across subsystems** over a minimal web-app-only loop.
  Date: 2026-06-29

- Decision: local mode is a **parallel target selected by `NAGARE_MODE`**, backed by a git-ignored
  `nagare.local.env` (with a tracked `nagare.local.env.example`), separate from the existing cloud target
  profile `nagare.target.env`; the existing cloud path is unchanged when `NAGARE_MODE` is unset.
  Rationale: The cloud and local targets differ in kind — one points at billable GCP resources and must
  stay fail-closed under the project guardrail, the other points at loopback substitutes and must bypass
  it. Keeping them as separate files with an explicit switch keeps "cloud vs. laptop" unambiguous at every
  layer and prevents a local profile from silently disarming the cloud safety check. It mirrors the
  target-profile pattern already established in MasterPlan 12.
  Date: 2026-06-29

- Decision: the substrate substitute is a **k3d cluster with a local registry**, not an emulation of the
  NixOS GCE VM; the `nixos/` host config and `infra/pulumi/` provisioning are out of scope and untouched.
  Rationale: Reproducing the host/cloud topology locally is enormous and unnecessary for *testing use
  cases* — what matters is a real Knative-on-k3s cluster, which k3d provides in Docker on any machine. This
  keeps the initiative focused on the application/operations surface an operator actually exercises.
  Date: 2026-06-29

- Decision: **CDN is out of scope** for local mode (local mode skips it; `cdn = Nothing` is the default and
  is byte-for-byte unchanged), and **local TLS exists only to satisfy WebAuthn's secure-context / browser-
  trust requirement** for the auth plane, not to be publicly valid.
  Rationale: The CDN layer is provider-specific (Cloudflare/Google Cloud CDN) and inherently cloud-bound;
  mocking it adds cost without testing a local-relevant path. Local TLS is needed only because Shomei's
  WebAuthn second factor requires HTTPS on a non-`localhost` loopback domain; a self-signed/`mkcert` issuer
  is sufficient and is scoped to EP-85.
  Date: 2026-06-29

- Decision: decompose into five child plans in four waves — EP-82 (local cluster + contract + bootstrap +
  guardrail), EP-83 (nagarectl build/deploy decoupling), EP-84 (data services + GCS-free backups), EP-85
  (auth plane + local TLS), EP-86 (smoke + docs).
  Rationale: Boundaries follow the layer each GCP dependency lives at, each ending in an independently
  verifiable behavior. EP-84 and EP-85 touch disjoint files and run in parallel after EP-83. See
  Decomposition Strategy for rejected alternatives (mega-plan; splitting the contract from the cluster
  harness; separating the GCS-free backup work from the data plan; folding auth into the data plan; a sixth
  TLS-only plan).
  Date: 2026-06-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
