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

Full plan before trimming: [82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M2.1 — Add `pkgs.k3d` to the `default` (and `haskell`) devShells in `flake.nix`.
      (Done 2026-06-29.)
- [x] M2.2 — Add a `just local-up` recipe that creates the k3d cluster + local registry with the
      Kourier-friendly port mappings and traefik disabled. (Done 2026-06-29.)
- [x] M2.3 — Add a `just local-down` recipe that deletes the cluster and the registry.
      (Done 2026-06-29.)
- [x] M2.4 — Document the registry hostname choice (`k3d-registry.localhost:5000`) and the
      `/etc/hosts` requirement in `nagare.local.env.example` and this plan. (Done 2026-06-29 —
      also documented the second, more important prerequisite: Docker `insecure-registries`. See
      Surprises & Discoveries.)
- [x] M2.5 — Verify M2: `just local-up` then `kubectl get nodes` shows the node Ready and
      `docker push` to the local registry succeeds. (Done 2026-06-29 — cluster node Ready; the
      registry round-trip verified functionally: the registry accepts HTTP pushes and an
      in-cluster pod successfully pulled `k3d-registry.localhost:5000/busybox` via the injected
      registries.yaml. The host `docker push` to the *named* host additionally requires the
      operator to add `k3d-registry.localhost:5000` to Docker `insecure-registries`; see
      Surprises & Discoveries.)

**M3 — `just local-bootstrap`**

- [x] M3.1 — Add a `just local-bootstrap` recipe that installs cert-manager + Knative Serving +
      Kourier + net-certmanager reusing the pinned versions, SKIPS `letsencrypt-dns.yaml` and the
      `config-certmanager` patch, sets `config-domain` from `NAGARE_BASE_DOMAIN`, and puts the
      LOCAL registry host into `registriesSkippingTagResolving`. (Done 2026-06-29. Also added a
      `k3s_image` pin to `just local-up` — k3d defaulted to an old k3s; Knative v1.22.0 needs
      k8s >= 1.34. See Surprises & Discoveries.)
- [x] M3.2 — Verify M3: `kubectl get pods -A` shows knative-serving/kourier/cert-manager Ready;
      `config-domain` shows the loopback base domain; a hand-applied helloworld Knative Service
      returns HTTP 200 via Kourier. (Done 2026-06-29. All control-plane pods Running 1/1;
      `config-domain` has `127-0-0-1.sslip.io: ""`; `registriesSkippingTagResolving` ends with
      `k3d-registry.localhost:5000`; `clusterissuer letsencrypt-dns` is NotFound (DNS-01 skipped).
      The helloworld ksvc returns `HTTP 200` + `server: envoy` + body `Hello nagare local!` via
      Kourier, and `*.127-0-0-1.sslip.io` resolves to 127.0.0.1. The curl was issued against
      Kourier directly (port-forward + Host header) because this host already runs a Caddy on
      port 80; see Surprises & Discoveries.)

**M4 — Local-mode-aware guardrail**

- [x] M4.1 — Make `scripts/lib/target.sh`'s `_require_target_project` short-circuit to success
      when `NAGARE_MODE=local`; keep the cloud branch fail-closed when unset/`cloud`.
      (Done 2026-06-29.)
- [x] M4.2 — Add the complementary assertion that local mode is genuinely not pointed at real
      cloud resources (loopback base domain / local registry host). (Done 2026-06-29.)
- [x] M4.3 — Verify M4: in local mode the guardrail returns 0 with no `gcloud`; in cloud mode a
      project mismatch still exits non-zero with the existing message. (Done 2026-06-29. local +
      loopback → rc=0 (no gcloud); local + `*.pkg.dev` registry → rc=1; local + non-loopback
      base domain → rc=1; cloud + gcloud reporting a foreign project → rc=1 with the original
      message; cloud + correct project → rc=0. Note: the cloud mismatch must be exercised with
      `CLOUDSDK_CORE_PROJECT` unset and a differing `gcloud config` project — if you instead
      `export CLOUDSDK_CORE_PROJECT=other` with no `nagare.target.env`, `TARGET_PROJECT` derives
      from that same value so there is no mismatch; this is pre-existing cloud-branch behavior,
      unchanged by M4. See Surprises & Discoveries.)

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

- **Host `docker push` to `k3d-registry.localhost:5000` needs an `insecure-registries` entry, not just
  `/etc/hosts`.** The plan framed the host-push prerequisite as a name-resolution problem
  (`/etc/hosts`), but on this machine `k3d-registry.localhost` already resolves to `127.0.0.1`
  (RFC 6761). The real blocker is that the local registry serves plain **HTTP**, and Docker only
  auto-trusts bare `localhost`/`127.0.0.0/8` as insecure — for the *named* host it attempts HTTPS and
  fails with `server gave HTTP response to HTTPS client`. Evidence: `docker push
  localhost:5000/busybox` (same registry container) succeeded, while `docker push
  k3d-registry.localhost:5000/busybox` failed with that exact HTTPS error; `docker info` lists only
  `::1/128` and `127.0.0.0/8` under Insecure Registries. The in-cluster pull is unaffected — a pod
  pulling `k3d-registry.localhost:5000/busybox` ran successfully (`PULLED_OK`, phase Succeeded),
  proving k3d's `registries.yaml` injection works. Resolution: documented the `insecure-registries`
  prerequisite (Docker Desktop / Colima / Linux Engine variants) in `nagare.local.env.example` and the
  `just local-up` echo. This is a hard prerequisite for EP-83, which pushes nagarectl-built images to
  this registry. The host here is **Colima on aarch64** (Apple Silicon), so `NAGARE_TARGET_PLATFORM=
  linux/arm64` is the correct contract default for this machine. The daemon reconfiguration +
  `colima restart` was intentionally NOT performed during this session because it tears down the
  in-VM k3d cluster and disrupts the operator's running Docker environment. Date: 2026-06-29.

- **k3d's default k3s is too old for the platform; pin k3s >= 1.34 in `local-up`.** The k3d binary
  from nixpkgs created a k3s **v1.21.7** node by default. Two failures cascaded: (1) cert-manager
  v1.20.2's CRDs use the `selectableFields` field that the old apiserver rejected ("unknown field
  selectableFields"); (2) after bumping to v1.31.7, Knative v1.22.0's controller crash-looped with
  `kubernetes version "1.31.7+k3s1" is not compatible, need at least "1.34.0-0"`. Both resolved by
  pinning `k3s_image := "rancher/k3s:v1.34.6-k3s1"` (a new `just` variable) and passing `--image` to
  `k3d cluster create`. After the bump the node is `v1.34.6+k3s1` and the whole control plane
  (controller, webhook, activator, autoscaler, kourier-gateway, net-kourier, net-certmanager) rolls
  out 1/1. The pin must move in lockstep with the knative/certmanager version pins. Date: 2026-06-29.

- **This host runs a Caddy on port 80, so the literal `curl http://<app>.127-0-0-1.sslip.io` is
  intercepted before reaching Kourier.** k3d published the cluster load balancer at host `0.0.0.0:80`
  correctly, but a pre-existing macOS host process (`caddy run --config .../local-web-proxy.Caddyfile`,
  running since Jun 17) holds host port 80 and answered the curl with an empty `200` / `Server: Caddy`.
  This is a machine-specific port conflict, not an EP-82 defect — on a host with port 80 free the
  `80:80@loadbalancer` mapping is reached directly. Knative ingress was instead proven against Kourier
  directly: `kubectl -n kourier-system port-forward svc/kourier 18080:80` then `curl -H 'Host:
  helloworld.personal.127-0-0-1.sslip.io' http://127.0.0.1:18080/` returns `HTTP 200`, `server: envoy`,
  body `Hello nagare local!`. EP-86's smoke test should either require host port 80 free or curl
  through a port-forward as done here. Date: 2026-06-29.

- **The cloud guardrail only "bites" via the gcloud fallback, not via an exported
  `CLOUDSDK_CORE_PROJECT`.** The plan's M4 Case 2 (`CLOUDSDK_CORE_PROJECT=someone-elses-project ...`
  expecting rc=1) does NOT fail-closed as written, because `TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-
  tan-nb-exp}"` derives the *expected* project from the very same env var as the *active* project, so
  they always match (rc=0). This is original, pre-M4 behavior — the cloud branch is byte-for-byte
  unchanged. The real fail-closed path is: `CLOUDSDK_CORE_PROJECT` unset (so `TARGET_PROJECT` falls
  back to the profile/default) and `gcloud config get-value project` returning a *different* project.
  Verified with a `gcloud` stub: foreign project → `rc=1` with `refusing to run: gcloud active
  project is 'someone-elses-project', expected 'tan-nb-exp'`; correct project → `rc=0`. Date:
  2026-06-29.

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

**Outcome (2026-06-29).** EP-82 is complete: all four milestones implemented, committed, and verified
on a real local cluster. Against the original purpose — "an operator with no GCP account can stand up
the local substrate and see it working" — the delivered state is:

- **M1 — contract.** `nagare.local.env.example` fixes the canonical local variables (`NAGARE_MODE`,
  `NAGARE_REGISTRY_HOST`, `NAGARE_BASE_DOMAIN`, `NAGARE_TARGET_PLATFORM`, `NAGARE_LOCAL_OBJECT_STORE`);
  `nagare.local.env` is git-ignored; `.envrc` sources the local profile only when `NAGARE_MODE=local`
  without disturbing the cloud `CLOUDSDK_*` defaults. Verified by an isolated harness.
- **M2 — substrate.** `pkgs.k3d` is in both devShells; `just local-up`/`local-down` create and destroy
  a k3d cluster + managed local registry. A node comes up `Ready` and an in-cluster pod successfully
  pulls `k3d-registry.localhost:5000/...` via k3d's injected `registries.yaml`.
- **M3 — bootstrap.** `just local-bootstrap` installs cert-manager + Knative Serving + Kourier +
  net-certmanager HTTP-first (DNS-01 issuer and `config-certmanager` patch skipped; `config-domain`
  set from `NAGARE_BASE_DOMAIN`; local registry in `registriesSkippingTagResolving`). The whole control
  plane rolls out 1/1 and a helloworld ksvc returns `HTTP 200` / `Hello nagare local!` through Kourier.
- **M4 — guardrail.** `_require_target_project` steps aside in local mode (asserting a genuinely
  loopback target) and stays byte-for-byte fail-closed in cloud mode.

**The three interfaces this plan owns are live** for EP-83/84/85/86: the local-target contract, the
`just local-bootstrap` recipe, and the local-mode-aware guardrail.

**Gaps / things downstream plans inherit (all recorded in Surprises & Discoveries):**

1. **Host `docker push` needs a Docker `insecure-registries` entry** for `k3d-registry.localhost:5000`
   (the registry serves HTTP; Docker only auto-trusts bare `localhost`/`127.0.0.0/8`). The in-cluster
   pull needs nothing. Documented in `nagare.local.env.example` and the `local-up` echo. **EP-83**
   depends on this prerequisite for pushing nagarectl-built images.
2. **k3s is pinned to v1.34.6** in `local-up` because Knative v1.22.0 refuses k8s < 1.34 and
   cert-manager v1.20.2's CRDs need a modern apiserver. The pin must move with the Knative/cert-manager
   version pins.
3. **A host process on port 80 (here, a pre-existing Caddy) shadows the `80:80@loadbalancer` mapping.**
   The Knative path was proven via a Kourier port-forward + `Host:` header. **EP-86's** smoke test
   should curl through a port-forward rather than assume host port 80 is free.

**Verification caveat:** the `docker push` to the *named* registry host and the literal
`curl http://<app>.<base>:80` were not exercised on this machine because both are blocked by host-side
conditions (missing `insecure-registries`; a Caddy on port 80) that EP-82 cannot and should not change
unilaterally. Both were proven functionally equivalent through the unobstructed path (registry HTTP
push via `localhost:5000` to the same container; Kourier via port-forward). On a clean host both
literal commands succeed.

**Lessons.** (a) k3d's default k3s lags the platform's needs — always pin the k3s image. (b) The
"dual-resolution registry" requirement has two independent layers (name resolution AND HTTP/HTTPS
trust); only the first was anticipated. (c) Loopback-domain ingress testing is fragile to host port-80
occupancy; a port-forward is the robust verification primitive.

