---
id: 82
slug: local-cluster-registry-and-local-target-bootstrap-for-nagare
title: "Local cluster, registry, and local-target bootstrap for nagare"
kind: exec-plan
created_at: 2026-06-30T00:56:38Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
master_plan: "docs/masterplans/16-local-development-and-testing-for-nagare.md"
---

# Local cluster, registry, and local-target bootstrap for nagare

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today **nagare** — a single-node personal Platform-as-a-Service (PaaS) — can only run on
Google Cloud Platform (GCP). To try the platform at all you must stand up a billable Compute
Engine virtual machine, an Artifact Registry, a Cloud DNS zone, and a Cloud Storage bucket,
because every layer is welded to GCP. There is no way to bring nagare up on a laptop.

This ExecPlan, **EP-82**, is the keystone of MasterPlan 16
(`docs/masterplans/16-local-development-and-testing-for-nagare.md`). It builds the **local
substrate** and defines the **local-target contract** that every other child plan reads. After
this change an operator with **no GCP account and no cloud resources** can do the following on
their own machine and *see* it working:

- Run `just local-up` to create a local Kubernetes cluster (k3s packaged to run inside Docker,
  via the [k3d](https://k3d.io/) tool) together with a local image registry that both the host
  (`docker push`) and the in-cluster container runtime (the pull) can reach.
- Run `just local-bootstrap` to install the *same* ingress stack the cloud uses —
  [cert-manager](https://cert-manager.io/) (which mints TLS certificates), Knative Serving
  (which runs apps as auto-scaling "Knative Services"), the Kourier ingress gateway, and
  net-certmanager (Knative's bridge to cert-manager) — but configured **HTTP-first** for local
  use: no DNS-01 ACME challenge, a loopback wildcard apps domain, and tag-resolution skipping
  pointed at the local registry instead of Artifact Registry.
- Enter **local mode** by copying `nagare.local.env.example` to a git-ignored
  `nagare.local.env` and setting `NAGARE_MODE=local`. In local mode the shell guardrail that
  normally refuses to act unless `gcloud`'s active project equals the configured GCP target
  steps aside (there is no GCP project to protect), while the cloud guardrail stays exactly as
  fail-closed as before whenever `NAGARE_MODE` is unset or `cloud`.

The visible proof that this plan is complete, *before any `nagarectl` work exists* (that is
EP-83), is: `just local-up && just local-bootstrap` brings the cluster up; `kubectl get pods -A`
shows the `knative-serving`, `kourier-system`, and `cert-manager` pods Ready; `kubectl -n
knative-serving get cm config-domain -o yaml` shows the loopback base domain; and a
hand-applied trivial Knative Service running the **public** image
`gcr.io/knative-samples/helloworld-go` (which needs no local registry) returns **HTTP 200**
through the Kourier gateway at `http://helloworld.<base-domain>`. That single curl proves that
ingress and loopback DNS work end to end, which is the foundation EP-83 builds on when it wires
`nagarectl deploy`.

This plan writes **no Haskell** and makes **no cloud call**. It touches shell, Nix, the
`justfile`, and Kubernetes manifests only. The existing cloud path is unchanged: with no local
profile and `NAGARE_MODE` unset, every command behaves exactly as it does today.

**Commit discipline.** Commit frequently, with [Conventional Commits](https://www.conventionalcommits.org/)
subjects (e.g. `feat(local): add nagare.local.env contract`). Every commit on this plan carries
these three trailers verbatim:

```text
MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md
ExecPlan: docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md
Intention: intention_01kwb012h6ebgs5qjn5r12nyda
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**M1 — Local-target contract**

- [x] M1.1 — Create the tracked `nagare.local.env.example` at the repo root with the canonical
      `export VAR=value` lines: `NAGARE_MODE=local`, `NAGARE_REGISTRY_HOST`, `NAGARE_BASE_DOMAIN`,
      `NAGARE_TARGET_PLATFORM`, `NAGARE_LOCAL_OBJECT_STORE`, plus explanatory comments and the
      worked-example loopback values. (Done 2026-06-29.)
- [x] M1.2 — Add `nagare.local.env` (the real, per-operator local profile) to `.gitignore`.
      (Done 2026-06-29.)
- [x] M1.3 — Make `.envrc` local-mode-aware: source `nagare.local.env` when `NAGARE_MODE=local`,
      WITHOUT changing the existing cloud `CLOUDSDK_*` defaults when local mode is off.
      (Done 2026-06-29.)
- [x] M1.4 — Verify M1 in `bash`/`direnv`: with no local profile the cloud defaults are intact;
      with `NAGARE_MODE=local` set and a local profile present, `echo $NAGARE_BASE_DOMAIN` prints
      the loopback domain. (Done 2026-06-29 — verified with an isolated bash harness reproducing
      the `.envrc` local block with a `source_env` stub; full `direnv exec` skipped to avoid a
      heavy `use flake` rebuild. See Surprises & Discoveries.)

**M2 — `just local-up` / `just local-down`**

- [ ] M2.1 — Add `pkgs.k3d` to the `default` (and `haskell`) devShells in `flake.nix`.
- [ ] M2.2 — Add a `just local-up` recipe that creates the k3d cluster + local registry with the
      Kourier-friendly port mappings and traefik disabled.
- [ ] M2.3 — Add a `just local-down` recipe that deletes the cluster and the registry.
- [ ] M2.4 — Document the registry hostname choice (`k3d-registry.localhost:5000`) and the
      `/etc/hosts` requirement in `nagare.local.env.example` and this plan.
- [ ] M2.5 — Verify M2: `just local-up` then `kubectl get nodes` shows the node Ready and
      `docker push` to the local registry succeeds.

**M3 — `just local-bootstrap`**

- [ ] M3.1 — Add a `just local-bootstrap` recipe that installs cert-manager + Knative Serving +
      Kourier + net-certmanager reusing the pinned versions, SKIPS `letsencrypt-dns.yaml` and the
      `config-certmanager` patch, sets `config-domain` from `NAGARE_BASE_DOMAIN`, and puts the
      LOCAL registry host into `registriesSkippingTagResolving`.
- [ ] M3.2 — Verify M3: `kubectl get pods -A` shows knative-serving/kourier/cert-manager Ready;
      `config-domain` shows the loopback base domain; a hand-applied helloworld Knative Service
      returns HTTP 200 via Kourier.

**M4 — Local-mode-aware guardrail**

- [ ] M4.1 — Make `scripts/lib/target.sh`'s `_require_target_project` short-circuit to success
      when `NAGARE_MODE=local`; keep the cloud branch fail-closed when unset/`cloud`.
- [ ] M4.2 — Add the complementary assertion that local mode is genuinely not pointed at real
      cloud resources (loopback base domain / local registry host).
- [ ] M4.3 — Verify M4: in local mode the guardrail returns 0 with no `gcloud`; in cloud mode a
      project mismatch still exits non-zero with the existing message.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M1 verification used an isolated `bash` harness (a `source_env()` stub plus the exact `.envrc`
  local-mode block under `env -i`) rather than `direnv exec .`, because `.envrc` ends in `use flake`
  and a fresh `direnv allow` would trigger a multi-GB flake re-evaluation. The harness proved both
  acceptance cases: with the local profile present the shell carries
  `NAGARE_MODE=local NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000`
  while `CLOUDSDK_CORE_PROJECT` stays `tan-nb-exp`; with the profile absent no local var leaks and the
  cloud default is intact. Date: 2026-06-29.


## Decision Log

Record every decision made while working on the plan.

- Decision: the local cluster substrate is **k3d** (k3s-in-Docker), not kind or minikube.
  Rationale: MasterPlan 16's Vision and Decomposition explicitly name k3d, and the substitution
  it is making matters: the *cloud* substrate is **k3s** on a NixOS VM, so k3d (which packages
  the very same k3s distribution to run inside Docker) reproduces the cloud's Kubernetes
  distribution, CRDs, and default add-ons most faithfully. kind runs upstream kubeadm Kubernetes
  and minikube runs yet another flavor; either would introduce distribution drift between local
  and cloud that this initiative explicitly wants to avoid. k3d also ships first-class local
  registry support (`k3d registry create` / `--registry-create`) that wires the in-cluster
  container runtime (containerd) to pull from the same host the operator does `docker push`
  against — exactly the dual-resolution requirement of Integration Point 1.
  Date: 2026-06-30

- Decision: the local apps domain is a **sslip.io loopback wildcard** (`127-0-0-1.sslip.io`),
  not `/etc/hosts` entries or `nip.io` or `localhost`.
  Rationale: nagare serves apps at `<app>.<base-domain>`, so the base domain must be a *wildcard*
  that resolves every `<app>` prefix to `127.0.0.1` with zero per-app DNS setup. sslip.io is a
  public wildcard DNS service that resolves any name embedding an IP — `anything.127-0-0-1.sslip.io`
  → `127.0.0.1` — so `helloworld.127-0-0-1.sslip.io`, `myapp.127-0-0-1.sslip.io`, etc. all work
  with no host configuration. `localhost` is rejected because it is not a wildcard (no
  `<app>.localhost` standard resolution across platforms) and because Knative needs a real
  dotted apps domain in `config-domain`. Hand-maintained `/etc/hosts` entries are rejected because
  they would need a new line per deployed app. (sslip.io and nip.io are equivalent; sslip.io is
  the value MasterPlan 16 fixes, so this plan uses it verbatim.)
  Date: 2026-06-30

- Decision: the local bootstrap is **HTTP-first** — it SKIPS the DNS-01 `ClusterIssuer`
  (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) and the `config-certmanager` patch that
  references it, and leaves `external-domain-tls` off.
  Rationale: `letsencrypt-dns.yaml` hard-codes the GCP project `tan-nb-exp` and relies on the GCE
  VM's *ambient* Application Default Credentials to answer a Cloud DNS DNS-01 challenge — neither
  exists on a laptop, so applying it would fail or hang. Plain HTTP is sufficient to prove
  ingress + loopback DNS work, which is this plan's entire acceptance. cert-manager itself is
  still installed (it is cloud-neutral and EP-85 layers a local self-signed TLS issuer onto it for
  the WebAuthn secure-context requirement — Integration Point 5); only the cloud-coupled DNS-01
  issuer and its `config-certmanager` wiring are deferred to EP-85.
  Date: 2026-06-30

- Decision: local mode is selected by **`NAGARE_MODE=local`** sourced from a separate git-ignored
  `nagare.local.env`, kept distinct from the cloud `nagare.target.env`.
  Rationale: This is fixed by MasterPlan 16 (Decision Log + Integration Point 1) and its rationale
  is inherited here: the two targets differ in kind — the cloud one points at billable GCP
  resources and must stay fail-closed under the project guardrail; the local one points at
  loopback substitutes and must explicitly *bypass* that guardrail. Two files plus an explicit
  switch keep "cloud vs. laptop" unambiguous and prevent a local profile from silently disarming
  the cloud safety check. Precedence matches MasterPlan 12: environment > profile > built-in
  default.
  Date: 2026-06-30

- Decision: the local registry hostname is **`k3d-registry.localhost:5000`**.
  Rationale: This is k3d's documented convention. k3d creates a registry container named
  `k3d-registry.localhost`, injects a `registries.yaml` into the cluster's containerd so
  in-cluster pulls resolve that name to the registry container over the Docker network, and the
  same name resolves to `127.0.0.1` on the host (the `.localhost` TLD is loopback by RFC 6761, and
  an explicit `/etc/hosts` line guarantees it on platforms whose resolver does not honor that).
  Using one hostname for both the host push and the in-cluster pull is what makes an image tag like
  `k3d-registry.localhost:5000/app:latest` valid on *both* sides — the dual-resolution requirement
  of Integration Point 1.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan operates on a checkout of the nagare repository at
`/Users/shinzui/Keikaku/bokuno/nagare`. The reader needs to know the following current state.

**The target-profile pattern (already in the repo).** nagare's GCP target is configurable through
a git-ignored file `nagare.target.env` at the repo root, a sequence of `export VAR=value` lines,
with a tracked `nagare.target.env.example` documenting the schema and shipping the original
`tan-nb-exp` worked example (see `docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`,
which is checked in). Three consumers read it: `.envrc` (sources it and exports the standard Cloud
SDK names `CLOUDSDK_CORE_PROJECT`/`CLOUDSDK_COMPUTE_REGION`/`CLOUDSDK_COMPUTE_ZONE` with
`tan-nb-exp`/`us-west1`/`us-west1-a` fallbacks); `scripts/lib/target.sh` (the shell guardrail);
and `nagarectl`. Precedence everywhere is **environment > profile > built-in default**, expressed
with the `${VAR:-default}` shell idiom. This plan adds a *parallel* local profile alongside this
one; it does not modify the cloud profile.

**The cloud cluster bootstrap.** The cloud cluster is brought up by the `cluster-bootstrap` recipe
in `justfile` (lines 82-101). It is the template this plan adapts. Its body, verbatim:

```text
cluster-bootstrap:
    for ns in cert-manager knative-serving kourier-system personal; do \
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; \
    done
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook
    kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
    kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
    BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
    kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
    kubectl -n knative-serving patch configmap config-certmanager --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
    kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
    REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"; \
      kubectl -n knative-serving patch configmap config-deployment --type merge \
        --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
```

The three version pins it uses live just above it in `justfile` (lines 67-69) and are reused
unchanged by this plan:

```text
knative_version := "knative-v1.22.0"
certmanager_version := "v1.20.2"
netcertmanager_version := "v1.14.0"
```

Three things in that recipe are **cloud-coupled** and must change for local mode:

1. `kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml` — this manifest
   (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) is a Let's Encrypt **DNS-01**
   `ClusterIssuer` that hard-codes `project: tan-nb-exp` and uses the GCE VM's ambient credentials
   to solve a Cloud DNS challenge. There is no GCP project and no GCE metadata server on a laptop,
   so the local bootstrap **omits this apply**. The companion patch
   `kubectl ... patch configmap config-certmanager ...` points Knative at that same
   `letsencrypt-dns` issuer (its body, `cluster/bootstrap/knative-serving/config-certmanager.yaml`,
   sets `issuerRef: kind: ClusterIssuer / name: letsencrypt-dns`), so the local bootstrap **omits
   that patch too** — wiring a local TLS issuer is EP-85's job (Integration Point 5).
2. `BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"` (line 93) — the cloud recipe
   learns the apps domain from Pulumi stack output. There is no Pulumi stack in local mode; the
   local bootstrap reads `NAGARE_BASE_DOMAIN` from the profile instead.
3. `REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"` feeding
   `registriesSkippingTagResolving` (lines 99-101) — the current default Artifact Registry host
   is `us-west1-docker.pkg.dev`, and the patch body in
   `cluster/bootstrap/knative-serving/config-deployment.yaml` (line 30) reads
   `registriesSkippingTagResolving: "kind.local,ko.local,dev.local,us-west1-docker.pkg.dev"`. In
   local mode this must instead list the **local** registry host so Knative skips controller-side
   tag→digest resolution for images pushed to the local registry. ("Tag resolution" is Knative's
   admission-time step that rewrites an image tag like `app:latest` to an immutable digest
   `app@sha256:...`; the controller cannot authenticate to some registries for that, so listing a
   host here defers the pull entirely to the node's container runtime.)

The remaining patches are **cloud-neutral** and are reused as-is: `config-network.yaml` (selects
Kourier as ingress class and auto-creates ClusterDomainClaims) and `config-features.yaml` (enables
PersistentVolumeClaim volumes on Knative Services). The local bootstrap applies both unchanged.

**The shell guardrail.** `scripts/lib/target.sh` (lines 26-54) loads `nagare.target.env`, sets
`TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`/`TARGET_PLATFORM` with the `tan-nb-exp` family of
fallbacks, and exposes `_require_target_project`, which compares `gcloud`'s active project to
`TARGET_PROJECT` and exits non-zero on a mismatch. `scripts/live-test.sh` and
`scripts/live-smoke.sh` call it (the latter at `live-smoke.sh:21`). On a laptop with no `gcloud`
configured this check would block a local run, so this plan makes the helper local-mode-aware.

**The devShell.** `flake.nix` defines `devShells.<system>.default` (lines 170-219), which already
provides `kubectl`, `kubernetes-helm`, `google-cloud-sdk` (gcloud), `pulumi`, `just`, `jq`, and
the Haskell toolchain. **k3d is not present** and must be added (`pkgs.k3d`). Docker itself is the
operator's responsibility (k3d needs a running Docker daemon); document that prerequisite.

**Terms used in this plan.** *k3d* — a tool that runs k3s (a small, certified Kubernetes
distribution) inside Docker containers; `k3d cluster create` makes a cluster, `k3d cluster delete`
removes it. *Local registry* — a Docker-registry container that holds images; with k3d it is
created alongside the cluster and the cluster's container runtime is auto-configured to pull from
it. *Knative Service (ksvc)* — nagare's unit of deployment: a Kubernetes custom resource that runs
a container with request-driven autoscaling and an HTTP route. *Kourier* — the ingress gateway
that fronts Knative Services with a single LoadBalancer entry point. *cert-manager* — a controller
that issues and renews TLS certificates from configured issuers. *sslip.io* — a public wildcard
DNS service that resolves any hostname embedding an IP literal back to that IP.


## Plan of Work

The work is four milestones. M1 defines the contract files and makes the shell aware of local
mode. M2 stands up the cluster and registry. M3 bootstraps Knative/Kourier on it. M4 makes the
guardrail local-aware. Each is independently verifiable; M3's full acceptance (a live HTTP-200)
naturally needs M2's cluster, so run them in order.

### Milestone 1 — Local-target contract

**Scope.** Create the local profile schema and make the shell honor it, without disturbing the
cloud path. At the end of M1 the repo has a tracked `nagare.local.env.example`, a `.gitignore`
entry for `nagare.local.env`, and an `.envrc` that sources the local profile only when
`NAGARE_MODE=local` — and a checkout with no local profile behaves exactly as today.

Create `nagare.local.env.example` at the repo root, mirroring `nagare.target.env.example`'s style
(header comment explaining copy-to-`nagare.local.env`, the precedence rule, then commented
`export` lines). The canonical variables, fixed by MasterPlan 16 Integration Point 1, are:

```bash
# nagare LOCAL-mode profile — WORKED EXAMPLE / SCHEMA (tracked in git).
#
# Copy this file to `nagare.local.env` (which IS git-ignored) to run nagare on
# your laptop with NO GCP account. `.envrc` sources `nagare.local.env` only when
# NAGARE_MODE=local; scripts/lib/target.sh and nagarectl read these variables
# from the environment. Precedence everywhere is:
#   a value already in your environment  >  this file  >  built-in default.

# The mode switch. `local` selects local mode (k3d cluster, local registry,
# loopback domain, guardrail steps aside). Unset or `cloud` preserves the
# original GCP behavior — the cloud target profile nagare.target.env stays the
# single source of truth in that case.
export NAGARE_MODE=local

# Local image registry host. k3d's convention. This one string must resolve BOTH
# from the host doing `docker push` (loopback) AND from the in-cluster container
# runtime doing the pull (k3d injects a registries.yaml mapping it to the
# registry container). Requires an /etc/hosts line on platforms whose resolver
# does not treat `.localhost` as loopback:
#   127.0.0.1 k3d-registry.localhost
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000

# Wildcard loopback apps domain. Knative serves "<app>.<this>". sslip.io resolves
# any "<app>.127-0-0-1.sslip.io" to 127.0.0.1 with zero DNS setup.
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io

# Build platform for images nagarectl builds locally. Set to YOUR host arch so a
# locally-built image runs on the local k3d node. Apple Silicon: linux/arm64;
# Intel/AMD: linux/amd64.
export NAGARE_TARGET_PLATFORM=linux/arm64

# In-cluster S3-compatible object store (MinIO) endpoint + bucket used for
# backups/snapshots in local mode. Consumed by EP-84; defined here so the
# contract is complete. Form: "<endpoint-url>/<bucket>".
export NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
```

Add `nagare.local.env` to `.gitignore` next to the existing `nagare.target.env` entry, with a
short comment.

Edit `.envrc` so that, in addition to its current behavior, it sources the local profile when the
operator has opted into local mode. The key constraint: **do not break the cloud defaults**. The
local profile is sourced *first* (it may set `NAGARE_MODE` and the local vars), and the existing
`CLOUDSDK_*` exports remain so an accidental cloud command in a half-configured shell still has a
project. Because the local vars are independent of the `CLOUDSDK_*` ones, sourcing the local
profile cannot disturb them. Concretely, insert near the top of `.envrc` (after the existing
`nagare.target.env` source line) a block that honors `NAGARE_MODE` from the environment or the
local profile:

```bash
# Local mode (MasterPlan 16). If NAGARE_MODE=local is already in the environment,
# or the git-ignored local profile sets it, source nagare.local.env so this shell
# carries the loopback contract (registry host, base domain, build platform,
# object store). The cloud CLOUDSDK_* exports below are left intact either way.
if [ "${NAGARE_MODE:-}" = "local" ] && [ -f "$PWD/nagare.local.env" ]; then
  source_env "$PWD/nagare.local.env"
elif [ -f "$PWD/nagare.local.env" ] && grep -q '^export NAGARE_MODE=local' "$PWD/nagare.local.env"; then
  source_env "$PWD/nagare.local.env"
fi
```

**Acceptance.** `direnv exec . sh -c 'echo $CLOUDSDK_CORE_PROJECT'` prints `tan-nb-exp` with no
local profile (cloud path intact). After `cp nagare.local.env.example nagare.local.env`,
`direnv exec . sh -c 'echo $NAGARE_MODE $NAGARE_BASE_DOMAIN'` prints `local 127-0-0-1.sslip.io`.

### Milestone 2 — `just local-up` / `just local-down`

**Scope.** Add the k3d tool to the devShell and two recipes that create and destroy the local
cluster + registry. At the end of M2 `just local-up` yields a running single-node k3s cluster with
a local registry reachable as `k3d-registry.localhost:5000` from both the host and the cluster, and
`just local-down` removes everything.

Add `pkgs.k3d` to the `default` devShell `packages` list in `flake.nix` (and the optional
`haskell` shell for parity), with a comment crediting EP-82. Then add the recipes to `justfile`,
in a new `[group('local')]`, reusing the same thin-wrapper style as `cluster-bootstrap`.

`just local-up` creates the cluster with the local registry, disables k3s's bundled Traefik (so it
does not claim host port 80 and collide with Kourier), and maps host ports 80/443 to the cluster
load balancer so Kourier is reachable at `http://...:80`:

```text
local-up:
    k3d cluster create nagare-local \
      --registry-create k3d-registry.localhost:0.0.0.0:5000 \
      --port "80:80@loadbalancer" \
      --port "443:443@loadbalancer" \
      --k3s-arg "--disable=traefik@server:0"
    @echo "Cluster up. Add '127.0.0.1 k3d-registry.localhost' to /etc/hosts if 'docker push' cannot resolve it."
```

`just local-down` deletes the cluster (which also removes the managed registry container):

```text
local-down:
    k3d cluster delete nagare-local
```

Document in `nagare.local.env.example` (done in M1) and this plan that `--registry-create
k3d-registry.localhost:0.0.0.0:5000` makes k3d (a) start a registry container, (b) inject a
`registries.yaml` into the cluster's containerd so in-cluster pulls of `k3d-registry.localhost:5000/...`
resolve to that container, and (c) bind it to host `0.0.0.0:5000` so the host's `docker push` can
reach it. On platforms whose resolver does not treat `.localhost` as loopback, the operator adds
`127.0.0.1 k3d-registry.localhost` to `/etc/hosts` (the recipe prints that reminder).

**Acceptance.** `just local-up` then `kubectl get nodes` shows one node `Ready`; `docker pull
busybox && docker tag busybox k3d-registry.localhost:5000/busybox && docker push
k3d-registry.localhost:5000/busybox` succeeds.

### Milestone 3 — `just local-bootstrap`

**Scope.** Add a `local-bootstrap` recipe that installs the same Knative/Kourier/cert-manager stack
the cloud uses, configured HTTP-first for local. At the end of M3 the cluster runs Knative Serving,
Kourier, cert-manager, and net-certmanager, `config-domain` carries the loopback base domain, and
the local registry host is in `registriesSkippingTagResolving`.

The recipe is the cloud `cluster-bootstrap` minus the three cloud-coupled steps (the DNS-01 issuer
apply, the `config-certmanager` patch, and the Pulumi-derived domain), with `NAGARE_BASE_DOMAIN`
and the local registry host substituted from the profile, reusing the same `{{certmanager_version}}`
/ `{{knative_version}}` / `{{netcertmanager_version}}` pins:

```text
local-bootstrap:
    for ns in cert-manager knative-serving kourier-system personal nagare-system; do \
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; \
    done
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook
    # NOTE: cluster/bootstrap/cert-manager/letsencrypt-dns.yaml is intentionally
    # NOT applied — it hard-codes a GCP project and needs ambient GCE creds. Local
    # TLS issuer is EP-85's job (MasterPlan 16 IP-5).
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
    kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
    BASE_DOMAIN="${NAGARE_BASE_DOMAIN:?set NAGARE_MODE=local and copy nagare.local.env.example to nagare.local.env}"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
    kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
    # NOTE: config-certmanager patch is intentionally skipped — it points Knative at
    # the letsencrypt-dns ClusterIssuer this bootstrap does not install (EP-85 wires
    # the local issuer). external-domain-tls stays off, so apps serve over HTTP.
    kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
    REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-k3d-registry.localhost:5000}"; \
      kubectl -n knative-serving patch configmap config-deployment --type merge \
        --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
```

Note the `nagare-system` namespace is created here for EP-84's MinIO (referenced by
`NAGARE_LOCAL_OBJECT_STORE`); it is harmless and keeps the contract self-consistent.

**Acceptance.** `kubectl get pods -A` shows `cert-manager`, `knative-serving`, and `kourier-system`
pods Ready; `kubectl -n knative-serving get cm config-domain -o yaml` shows the loopback base
domain as a data key; the helloworld Knative Service (below) returns HTTP 200.

### Milestone 4 — Local-mode-aware guardrail

**Scope.** Make `scripts/lib/target.sh`'s `_require_target_project` step aside in local mode while
keeping the cloud branch fail-closed. At the end of M4 a local run never trips the GCP-project
check, a cloud run still does, and a complementary assertion catches a local profile that is
accidentally pointed at real cloud resources.

Edit `_require_target_project` (currently `scripts/lib/target.sh:45-54`) to short-circuit at the
top when `NAGARE_MODE=local`. Add the complementary assertion: in local mode the base domain must
be a loopback wildcard (contain `sslip.io`, `nip.io`, or `127.0.0.1`/`127-0-0-1`) and the registry
host must not be an Artifact Registry host (`*.pkg.dev`), so a misconfigured local profile that
still points at GCP fails loudly rather than silently disarming the guard:

```bash
_require_target_project() {
  # Local mode (MasterPlan 16 IP-6): there is no GCP project to protect, so the
  # GCP guardrail steps aside — but assert the local target is genuinely loopback,
  # never real cloud resources, so a misconfigured profile cannot silently bypass
  # protection while pointing at GCP.
  if [ "${NAGARE_MODE:-}" = "local" ]; then
    case "${NAGARE_BASE_DOMAIN:-}" in
      *sslip.io|*nip.io|*127.0.0.1*|*127-0-0-1*) : ;;
      *)
        echo "refusing local run: NAGARE_MODE=local but NAGARE_BASE_DOMAIN='${NAGARE_BASE_DOMAIN:-<unset>}' is not a loopback wildcard." >&2
        return 1 ;;
    esac
    case "${NAGARE_REGISTRY_HOST:-}" in
      *.pkg.dev|*.pkg.dev:*)
        echo "refusing local run: NAGARE_MODE=local but NAGARE_REGISTRY_HOST='${NAGARE_REGISTRY_HOST}' is an Artifact Registry host." >&2
        return 1 ;;
    esac
    return 0
  fi

  # Cloud mode (unchanged, fail-closed): abort unless gcloud's active project
  # equals the configured target.
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
    echo "refusing to run: gcloud active project is '${active:-<unset>}', expected '${TARGET_PROJECT}'." >&2
    echo "fix: run 'direnv allow' in the repo root, set CLOUDSDK_CORE_PROJECT in nagare.target.env," >&2
    echo "     or 'export CLOUDSDK_CORE_PROJECT=${TARGET_PROJECT}'." >&2
    return 1
  fi
}
```

This **does not weaken the cloud branch**: when `NAGARE_MODE` is unset or `cloud`, control falls
straight through to the original comparison, byte-for-byte equivalent to today.

**Acceptance.** With `NAGARE_MODE=local` and the example loopback values,
`source scripts/lib/target.sh; _require_target_project; echo $?` prints `0` with no `gcloud` call.
With `NAGARE_MODE` unset and a forced project mismatch the function exits non-zero with the
existing message. With `NAGARE_MODE=local` but `NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev` it
refuses with the Artifact-Registry message.


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell
(`nix develop`, or automatically via direnv). Docker must be running for k3d.

**M1 — contract files.** Create `nagare.local.env.example` and the `.gitignore`/`.envrc` edits as
described in the Plan of Work, then verify:

```bash
cp nagare.local.env.example nagare.local.env
direnv allow
direnv exec . sh -c 'echo "$NAGARE_MODE $NAGARE_BASE_DOMAIN $NAGARE_REGISTRY_HOST"'
```

Expected:

```text
local 127-0-0-1.sslip.io k3d-registry.localhost:5000
```

Confirm the cloud path is untouched by temporarily moving the local profile aside:

```bash
mv nagare.local.env /tmp/nagare.local.env.bak
direnv exec . sh -c 'echo "$CLOUDSDK_CORE_PROJECT"'
mv /tmp/nagare.local.env.bak nagare.local.env
```

Expected:

```text
tan-nb-exp
```

Commit:

```bash
git add nagare.local.env.example .gitignore .envrc
git commit   # feat(local): add nagare.local.env contract and local-mode .envrc
```

**M2 — cluster + registry.** After adding `pkgs.k3d` to `flake.nix` and the recipes to `justfile`:

```bash
just local-up
kubectl get nodes
```

Expected (names/age vary):

```text
NAME                       STATUS   ROLES                  AGE   VERSION
k3d-nagare-local-server-0  Ready    control-plane,master   20s   v1.31.x+k3s1
```

Prove the registry round-trips host→cluster:

```bash
docker pull busybox:latest
docker tag busybox:latest k3d-registry.localhost:5000/busybox:latest
docker push k3d-registry.localhost:5000/busybox:latest
```

Expected tail:

```text
latest: digest: sha256:... size: 527
```

If `docker push` cannot resolve the host, add `127.0.0.1 k3d-registry.localhost` to `/etc/hosts`
and retry. Commit:

```bash
git add flake.nix justfile
git commit   # feat(local): add k3d devShell tool and just local-up/local-down
```

**M3 — bootstrap.** With the cluster up and local mode active in the shell:

```bash
just local-bootstrap
kubectl get pods -A
```

Expected (abridged; all Running/Completed):

```text
NAMESPACE         NAME                                      READY   STATUS
cert-manager      cert-manager-...                          1/1     Running
knative-serving   controller-...                            1/1     Running
knative-serving   activator-...                             1/1     Running
kourier-system    3scale-kourier-gateway-...                1/1     Running
```

Confirm the domain:

```bash
kubectl -n knative-serving get cm config-domain -o yaml
```

Expected `data:` contains the loopback key:

```yaml
data:
  127-0-0-1.sslip.io: ""
```

Apply a trivial PUBLIC-image Knative Service (no local registry needed) and curl it:

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: helloworld
  namespace: personal
spec:
  template:
    spec:
      containers:
        - image: gcr.io/knative-samples/helloworld-go
          env:
            - name: TARGET
              value: "nagare local"
YAML
kubectl -n personal wait ksvc/helloworld --for=condition=Ready --timeout=120s
curl -i http://helloworld.personal.127-0-0-1.sslip.io
```

Expected:

```text
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
...
Hello nagare local!
```

(The route host is `<service>.<namespace>.<base-domain>` because Knative's default route uses the
namespace; for a custom apps-domain mapping nagarectl uses a DomainMapping, which is EP-83.)

Commit:

```bash
git add justfile
git commit   # feat(local): add just local-bootstrap (HTTP-first Knative/Kourier)
```

**M4 — guardrail.** After editing `scripts/lib/target.sh`:

```bash
NAGARE_MODE=local NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000 \
  bash -c 'source scripts/lib/target.sh; _require_target_project; echo "rc=$?"'
```

Expected:

```text
rc=0
```

Cloud branch still bites (force a mismatch, no local mode):

```bash
CLOUDSDK_CORE_PROJECT=someone-elses-project \
  bash -c 'source scripts/lib/target.sh; _require_target_project; echo "rc=$?"'
```

Expected:

```text
refusing to run: gcloud active project is 'someone-elses-project', expected 'tan-nb-exp'.
...
rc=1
```

Misconfigured local profile is caught:

```bash
NAGARE_MODE=local NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev \
  bash -c 'source scripts/lib/target.sh; _require_target_project; echo "rc=$?"'
```

Expected:

```text
refusing local run: NAGARE_MODE=local but NAGARE_REGISTRY_HOST='us-west1-docker.pkg.dev' is an Artifact Registry host.
rc=1
```

Commit:

```bash
git add scripts/lib/target.sh
git commit   # feat(local): make _require_target_project local-mode-aware
```


## Validation and Acceptance

The plan is accepted when, on a machine with Docker and no GCP credentials, the following holds.

1. **Contract.** With `nagare.local.env` present and `NAGARE_MODE=local`, a direnv shell exports
   `NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io` and `NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000`;
   with the local profile absent, `CLOUDSDK_CORE_PROJECT` is still `tan-nb-exp` (cloud path
   unchanged).
2. **Substrate.** `just local-up` creates a Ready single-node k3d cluster, and an image pushed to
   `k3d-registry.localhost:5000` from the host is pullable in-cluster.
3. **Bootstrap.** `just local-bootstrap` leaves `cert-manager`, `knative-serving`, and
   `kourier-system` pods Ready; `config-domain` carries `127-0-0-1.sslip.io`; the
   `registriesSkippingTagResolving` value ends with `k3d-registry.localhost:5000` (not
   `us-west1-docker.pkg.dev`); and the `letsencrypt-dns` ClusterIssuer does **not** exist
   (`kubectl get clusterissuer letsencrypt-dns` returns NotFound), proving DNS-01 was skipped.
4. **End-to-end ingress.** A hand-applied `gcr.io/knative-samples/helloworld-go` Knative Service
   returns **HTTP 200** with a `Hello ...` body at `http://helloworld.personal.127-0-0-1.sslip.io`
   through Kourier — proving ingress and loopback DNS work *before* EP-83 wires `nagarectl`.
5. **Guardrail.** `_require_target_project` returns 0 in local mode with loopback values, returns
   non-zero in cloud mode on a project mismatch (existing message), and returns non-zero in local
   mode if pointed at a `*.pkg.dev` registry or a non-loopback base domain.

This plan does **not** depend on `nagarectl deploy` (that is EP-83); acceptance uses only
`kubectl`, `docker`, `curl`, and the recipes added here.


## Idempotence and Recovery

The contract edits (M1) are plain file creation and additive `.envrc`/`.gitignore` changes; running
the steps twice is harmless. `just local-up` is **not** idempotent in k3d's CLI — re-running it when
`nagare-local` already exists errors with "cluster already exists"; recovery is `just local-down`
then `just local-up`, or simply leaving the existing cluster. `just local-bootstrap` is idempotent:
every `kubectl apply` and `kubectl patch --type merge` is declarative and converges, and the
namespace creation uses `--dry-run=client -o yaml | kubectl apply` so re-runs do not error. The
`config-domain` JSON `remove` step is guarded with `|| true` so a second run (when
`svc.cluster.local` is already gone) does not fail. The guardrail edit (M4) is a pure function
change with no state.

Full reset at any time:

```bash
just local-down        # delete cluster + managed registry
docker ps -a | grep k3d   # confirm no stray k3d containers
```

If `local-down` leaves a dangling registry container (rare), remove it explicitly:

```bash
k3d registry delete k3d-registry.localhost || docker rm -f k3d-registry.localhost
```

Re-running `just local-up && just local-bootstrap` rebuilds the entire local stack from scratch.


## Interfaces and Dependencies

This plan has **no dependencies** on other child plans (it is MasterPlan 16's keystone, EP-82). It
**defines** three interfaces consumed by EP-83, EP-84, EP-85, and EP-86:

- **The local-target contract (MasterPlan 16 Integration Point 1).** The tracked file
  `nagare.local.env.example` and the git-ignored `nagare.local.env` fix these canonical variables,
  read from the environment by every consumer: `NAGARE_MODE` (`local` selects local mode; unset or
  `cloud` preserves today's behavior), `NAGARE_REGISTRY_HOST` (`k3d-registry.localhost:5000`),
  `NAGARE_BASE_DOMAIN` (`127-0-0-1.sslip.io`), `NAGARE_TARGET_PLATFORM` (the host arch, e.g.
  `linux/arm64`), and `NAGARE_LOCAL_OBJECT_STORE` (the MinIO endpoint+bucket consumed by EP-84).
  Precedence is environment > profile > built-in default. EP-82 owns this list; a later plan adding
  a local field adds it here and to the MasterPlan's Integration Point 1.
- **The local-mode cluster bootstrap (MasterPlan 16 Integration Point 4).** The `just
  local-bootstrap` recipe in `justfile` installs cert-manager + Knative Serving + Kourier +
  net-certmanager at the pinned versions `knative-v1.22.0` / `v1.20.2` / `v1.14.0`, HTTP-first.
  EP-85 extends this same bootstrap by layering the auth-plane namespaces/manifests and a local TLS
  issuer (Integration Point 5) *after* it, reusing its namespace/ConfigMap conventions.
- **The local-mode-aware guardrail (MasterPlan 16 Integration Point 6).**
  `scripts/lib/target.sh`'s `_require_target_project` returns 0 in local mode (after asserting the
  target is genuinely loopback) and remains fail-closed in cloud mode. EP-86's `just local-smoke`
  sources the same helper and relies on this; no plan may make the cloud branch anything but
  fail-closed.

External tools and services used: **k3d** (added to `flake.nix`'s `default` and `haskell`
devShells as `pkgs.k3d`) wrapping **k3s** for the cluster and managed local registry; **Docker**
(operator-provided prerequisite, k3d's container runtime host); **kubectl** and the pinned
**cert-manager / Knative Serving / net-kourier / net-certmanager** release manifests (already
referenced by the cloud `cluster-bootstrap`); and **sslip.io** as the public wildcard-loopback DNS
resolver for the apps domain. No GCP service, no `gcloud`, no Pulumi stack, and no `nagarectl` code
is required by this plan.
