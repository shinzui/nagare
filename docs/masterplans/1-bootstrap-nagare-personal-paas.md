---
id: 1
slug: bootstrap-nagare-personal-paas
title: "Bootstrap Nagare Personal PaaS"
kind: master-plan
created_at: 2026-06-02T15:39:38Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
---

# Bootstrap Nagare Personal PaaS

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan coordinates the from-scratch construction of **Nagare** (流れ, "flow") — a cheap,
single-node personal Platform-as-a-Service (PaaS) running on one Google Cloud Platform (GCP)
Compute Engine virtual machine. It is derived from `docs/initial-spec.md`. Where the research
behind this plan found the spec to be inaccurate, the spec was corrected; those corrections are
listed in `docs/initial-spec.md` under the "Spec Accuracy Corrections" appendix and are reflected
in the child plans. Read that appendix before implementing any child plan.

This project reuses the established conventions of a sibling repository on the same workstation,
`/Users/shinzui/Keikaku/bokuno/load-testing-infra`, which runs the same toolchain family (NixOS +
GCP + Pulumi + Haskell). That repository is the canonical pattern source for: the project-pinned
Pulumi-via-Nix dev shell (`flake.nix`), the in-repo isolated Pulumi state backend and `.envrc`, the
component-based Pulumi/TypeScript layout under `infra/pulumi/src/components`, and — most importantly
— the way NixOS GCE images are built. Because the developer workstation is `aarch64-darwin` and GCE
images are `x86_64-linux`, images are **not** built locally: an on-demand x86_64-linux Nix remote
builder is provisioned in GCP (`scripts/setup-nix-builder.sh` in the reference repo), the image is
built there, its `*.raw.tar.gz` is uploaded to a GCS bucket, registered as a GCE image with
`gcloud compute images create --source-uri`, and the image self-link is written into Pulumi config
(`scripts/upload-images.sh`). Child plans that touch Nix images or Pulumi must read the corresponding
reference files before implementing.

All GCP work targets the **`tan-nb-exp`** project, region **`us-west1`**, default zone
**`us-west1-a`** — the same hard isolation policy as the reference repo (see Integration Point 9 and
the Decision Log). No plan may target another GCP project without a Decision Log entry first.


## Vision & Scope

After this initiative is complete, the owner can deploy a personal web project to their own cloud
with a single command — `nagarectl deploy` — and get back a working HTTPS URL, with metrics, logs,
and traces visible in Grafana, and the whole machine reproducible from this Git repository plus a
handful of encrypted secrets. Concretely, when the initiative is done:

A developer runs `pulumi up` and a GCP Compute Engine VM appears with a static public IP, a Cloud
DNS zone whose wildcard record `*.apps.example.com` points at that IP, a dedicated service account,
a mounted data disk, an Artifact Registry repository for container images, and a Google Cloud Storage
(GCS) bucket for backups. They run `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01`
and the machine boots NixOS with a single-node Kubernetes distribution called k3s, Tailscale for
private access, and host secrets decrypted by sops-nix. They run the cluster bootstrap and the box
gains Knative Serving (which lets one container image become a scale-to-zero web service), Kourier
(the lightweight ingress that routes traffic into Knative, backed by Envoy), and cert-manager (which
obtains TLS certificates from Let's Encrypt). They install the observability stack and get
VictoriaMetrics (metrics), VictoriaLogs (logs), VictoriaTraces (traces), an OpenTelemetry Collector
(which receives trace data from apps), and Grafana (the dashboard UI). Finally they build the
`nagarectl` command-line tool (written in Haskell) and use it to deploy an example app described by a
small `nagare.yaml` file: the tool builds and pushes the image, renders and applies a Knative Service,
wires up secrets and a custom domain, waits for readiness, and prints the URL.

In scope: everything in the "MVP Definition" of `docs/initial-spec.md` — provisioning, host, cluster
platform, TLS, the three-pillar observability stack, the deploy CLI, and backups with a documented
disaster-recovery runbook. The guiding constraint is that rebuilding the entire system from Git plus
backups must be boring and reliable.

Explicitly out of scope for this initiative (the "Non-Goals for v1" in the spec): multi-node
Kubernetes, a service mesh (Istio/Linkerd), GitOps controllers (Argo CD, Flux), Crossplane, the
External Secrets Operator, complex autoscaling policy, multi-tenant authentication, running production
databases inside Kubernetes, large observability retention, and production-grade high availability.
These may be added later but are not part of bootstrapping.


## Decomposition Strategy

The initiative was decomposed by **functional concern and ownership boundary**, mirroring the clean
boundary the spec insists on: Pulumi owns cloud resources, NixOS owns the host, k3s owns the cluster,
Knative owns app deployment, the Victoria stack owns observability, and `nagarectl` owns the developer
experience. This boundary maps almost one-to-one onto the five packages declared in the project's
`mori` identity (`infra-pulumi`, `nixos-hosts`, `cluster-bootstrap`, `cluster-observability`,
`nagarectl`), plus a foundational scaffolding stream and a cross-cutting backups/recovery stream.

Seven child plans result. That is at the upper bound of the recommended two-to-seven range, so they
are grouped into four implementation waves (phases) below. The boundaries were chosen to maximize
independent verifiability: each plan ends in a behavior a human can observe (a `pulumi preview` that
plans the right resources; `kubectl get nodes` returning Ready; a sample Knative service answering
over HTTPS; logs searchable in Grafana; `nagarectl deploy` printing a live URL; a restore that brings
data back). Cross-plan coupling is concentrated into a small number of explicit Integration Points
(below) rather than spread implicitly through the plans.

Alternatives considered and rejected. **One mega-plan**: rejected because the spec spans nine phases
and well over ten files across unrelated toolchains (TypeScript, Nix, YAML/Helm, Haskell); a single
ExecPlan would be unwieldy and could not be verified incrementally. **Splitting observability into
three plans** (metrics, logs, traces): rejected because they share one Helm repository, one data
disk, one Grafana, and one set of namespaces — splitting them would multiply integration points
without improving verifiability; they are one plan with three milestones instead. **Splitting DNS/TLS
into its own plan separate from cluster bootstrap**: rejected because wildcard TLS via cert-manager
is wired directly into Knative/Kourier through the `net-certmanager` bridge and the `config-domain`
and `config-network` ConfigMaps; separating it would split a single tightly-coupled configuration
across two plans. DNS records themselves live in the Pulumi plan (they are a cloud resource), and the
cluster-side TLS wiring lives with the Knative bootstrap.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Repository scaffolding and Nix flake dev environment | docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md | None | None | Complete |
| 2 | Pulumi GCP infrastructure | docs/plans/2-pulumi-gcp-infrastructure.md | None | EP-1 | Complete |
| 3 | NixOS host nagare-01 with k3s | docs/plans/3-nixos-host-nagare-01-with-k3s.md | None | EP-1, EP-2 | Complete |
| 4 | Knative Serving, Kourier ingress, and cert-manager TLS | docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md | EP-3 | EP-2 | Complete (TLS deferred) |
| 5 | Victoria observability stack and Grafana | docs/plans/5-victoria-observability-stack-and-grafana.md | EP-3 | EP-4 | Complete |
| 6 | nagarectl deploy CLI in Haskell | docs/plans/6-nagarectl-deploy-cli-in-haskell.md | EP-4 | EP-1 | Not Started |
| 7 | Backups, secrets, and disaster recovery | docs/plans/7-backups-secrets-and-disaster-recovery.md | None | EP-2, EP-3, EP-4, EP-6 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference other
rows by their `EP-<#>` prefix.

Implementation waves (phases):

- **Wave 1 — Foundation:** EP-1.
- **Wave 2 — Infrastructure & Host:** EP-2 and EP-3. EP-3's host configuration can be authored in
  parallel with EP-2, but EP-3 cannot be fully deployed/validated until EP-2 has produced the VM,
  disk, and image-staging bucket.
- **Wave 3 — Cluster Platform:** EP-4 then EP-5. Both hard-depend on EP-3 (a running cluster). EP-5
  soft-depends on EP-4 because Knative service metrics and Grafana exposure are nicer once ingress
  exists, but observability can install on a bare k3s.
- **Wave 4 — Developer Experience & Durability:** EP-6 (after EP-4) and EP-7 (after the rest).


## Dependency Graph

EP-1 (scaffolding) has no dependencies; it creates the repository skeleton, the Nix flake, the shared
developer shell (the toolchain every other plan runs commands from), and the `justfile`. Every other
plan soft-depends on it because they run their tools (`pulumi`, `kubectl`, `helm`, `cabal`, `sops`,
`gcloud`) from that shell, but each plan also states its own tool prerequisites so it can stand alone.

EP-2 (Pulumi) soft-depends on EP-1 for the dev shell. It owns the GCP perimeter and **defines the
stack outputs that three later plans consume** (see Integration Point 1). It has no hard dependency:
a `pulumi preview` can be demonstrated without any other plan.

EP-3 (NixOS host) soft-depends on EP-1 and EP-2. The NixOS configuration can be authored without
anything else, but deploying and validating it (the VM boots, k3s starts, `kubectl get nodes` works)
requires EP-2's VM, static IP, and attached data disk. EP-3 consumes EP-2's `dataDiskName`,
`instanceName`, and `publicIp` outputs (Integration Point 1) and the image-staging bucket for the
NixOS GCE image (Integration Point 3).

EP-4 (Knative/Kourier/cert-manager TLS) **hard-depends on EP-3**: installing Knative and running a
sample service requires a live k3s cluster, which only exists after EP-3 is deployed. It
soft-depends on EP-2 because cert-manager's wildcard TLS uses the Cloud DNS zone and the service
account created by EP-2 (Integration Point 2 and 4).

EP-5 (observability) **hard-depends on EP-3** for the cluster and the mounted data disk used for
persistent storage. It soft-depends on EP-4 so that Grafana can be reached through ingress and so
Knative request metrics exist to visualize; without EP-4 it still installs and shows node and cluster
metrics.

EP-6 (nagarectl) **hard-depends on EP-4**: the CLI's whole purpose is to deploy a Knative Service and
print its URL, which is only meaningful once Knative, ingress, and TLS exist. It soft-depends on EP-1
for the Haskell toolchain in the dev shell.

EP-7 (backups/recovery) has no hard dependency but soft-depends on EP-2 (the GCS bucket and service
account), EP-3 (sops-nix host secrets and the data disk), EP-4 (the secrets pattern apps use), and
EP-6 (apps deployed by `nagarectl` are what we back up). It is last because a disaster-recovery
runbook can only be written and tested once there is a system to restore.

Parallelism: within Wave 2, EP-2 and EP-3 authoring proceed in parallel. Within Wave 3, after EP-3 is
Complete, EP-4 and EP-5 can both proceed; a single implementer should finish EP-4 first to satisfy EP-5's
soft dependency cleanly. EP-7 documentation can begin early and be finalized last.


## Integration Points

**1. Pulumi stack outputs (defined by EP-2; consumed by EP-3, EP-4, EP-6, EP-7).** EP-2 is the single
source of truth for cloud identifiers. All resources live in GCP project `tan-nb-exp`, region
`us-west1`, zone `us-west1-a`. EP-2 must export exactly these stack output names so later plans can
read them with `pulumi stack output <name>`: `publicIp` (the static external IP), `sshCommand` (a
ready-to-paste SSH command), `baseDomain` (the apps wildcard base, e.g. `apps.example.com`),
`instanceName` (e.g. `nagare-01`), `serviceAccountEmail` (the node/workload service account),
`dataDiskName` (the attached persistent disk), `dnsZoneName` (the Cloud DNS managed-zone name),
`artifactRegistry` (the container image repository URL, e.g.
`us-west1-docker.pkg.dev/tan-nb-exp/nagare`), and `backupBucket` (the GCS bucket name). The VM is
booted from a registered NixOS GCE image whose self-link EP-3 writes into Pulumi **config** (key
`nagareImageSelfLink`, mirroring the reference repo's `postgresImageSelfLink` pattern), which EP-2's
instance component reads. Later plans must reference outputs by these names, never by hard-coded
values. If EP-2 needs to rename an output, it updates this section and notifies the consuming plans.

**2. GCP service account and IAM roles (defined by EP-2; consumed by EP-4, EP-6, EP-7).** EP-2 creates
one service account (exported as `serviceAccountEmail`) attached to the VM, and grants it the roles
later plans rely on: `roles/dns.admin` (so cert-manager in EP-4 can solve the Let's Encrypt DNS-01
challenge against the Cloud DNS zone using the VM's ambient credentials), `roles/artifactregistry.writer`
(so `nagarectl` in EP-6 can push images), and `roles/storage.objectAdmin` scoped to the backup bucket
(so EP-7's backup jobs can write). EP-4 must use the VM's attached service account via Application
Default Credentials rather than GKE Workload Identity, which does not exist on self-managed k3s.

**3. Data disk and host mount layout (disk created by EP-2; mounted by EP-3; consumed by EP-5, EP-7).**
EP-2 creates the persistent disk. EP-3 attaches and mounts it at `/var/lib/nagare` and creates this
subdirectory layout: `/var/lib/nagare/victoria-metrics`, `/var/lib/nagare/victoria-logs`,
`/var/lib/nagare/victoria-traces`, `/var/lib/nagare/postgres`, `/var/lib/nagare/sqlite`,
`/var/lib/nagare/backups`, and `/var/lib/nagare/local-path`. EP-3 configures k3s's built-in
local-path-provisioner to use `/var/lib/nagare/local-path` via the durable k3s server flag
`--default-local-storage-path` (not by editing the `local-path-config` ConfigMap, which k3s overwrites
on restart). EP-5 requests storage through PersistentVolumeClaims that bind to that provisioner. EP-7
backs up from the relevant subdirectories.

**4. Wildcard DNS and the apps base domain (zone + record created by EP-2; consumed by EP-4 and EP-6).**
EP-2 creates the Cloud DNS managed zone and a wildcard A record `*.apps.example.com` pointing at
`publicIp`. The canonical base domain placeholder used across all plans is `apps.example.com`; the
real domain is supplied through Pulumi configuration and surfaced as the `baseDomain` output. EP-4
sets Knative's `config-domain` ConfigMap to `baseDomain` so a service named `notes` in namespace
`personal` is served at `notes.personal.apps.example.com`. EP-6 computes the same URL shape when it
prints a deployed app's address, and uses Knative DomainMapping for nicer public names like
`notes.example.com`.

**5. Kubernetes namespaces (established by EP-4 and EP-5; used by EP-6).** The fixed namespaces are:
`knative-serving` and `kourier-system` (EP-4), `cert-manager` (EP-4), `monitoring`, `logging`, and
`tracing` (EP-5), and the default application namespace `personal` for deployed apps (EP-6, also used
by EP-4's sample service). Plans must use these exact names so service URLs and ConfigMap references
line up.

**6. The `nagare.yaml` application contract (defined and consumed by EP-6; referenced by EP-4's sample
app).** This is the schema every deployable app repository provides. It is the contract between an app
author and `nagarectl`. The canonical shape is:

```yaml
name: notes                       # Knative Service name (DNS-safe)
namespace: personal               # Kubernetes namespace (default: personal)
image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes   # image repo, no tag; nagarectl appends a tag
domain: notes.example.com         # optional: custom public domain via DomainMapping
port: 8080                        # optional container port (default 8080)
env:                              # optional environment variables
  DATABASE_URL:
    secretRef: notes-db-url       # value pulled from a Kubernetes Secret named notes-db-url
  LOG_LEVEL:
    value: info                   # literal value
resources:
  cpu: 250m
  memory: 512Mi
scale:
  min: 0                          # scale-to-zero
  max: 3
```

EP-6 owns the parser and the renderer that turns this into a `serving.knative.dev/v1` Service plus, if
`domain` is set, a `serving.knative.dev/v1beta1` DomainMapping. `min`/`max` become the Knative
autoscaling annotations `autoscaling.knative.dev/min-scale` and `.../max-scale`. EP-4 must ship an
example app under `cluster/examples/hello-knative-service/` whose `nagare.yaml` conforms to this shape
so EP-6 has a real artifact to test against.

**7. Cluster access / kubeconfig (produced by EP-3; consumed by EP-4, EP-5, EP-6).** EP-3 configures
k3s to write its kubeconfig at `/etc/rancher/k3s/k3s.yaml` with mode `0644`, and the operator reaches
the cluster over Tailscale or SSH. Plans that run `kubectl`/`helm`/`nagarectl` against the cluster must
document copying that kubeconfig locally (rewriting its `server:` field to the Tailscale name or
`publicIp`) and exporting `KUBECONFIG`. This is the single mechanism all cluster-touching plans use.

**8. Developer shell toolchain (provided by EP-1; consumed by all).** EP-1's `nix develop` shell must
provide at least: `pulumi` and Node.js (for EP-2), `kubectl` and `helm` (EP-4, EP-5), the GHC Haskell
compiler and `cabal` (EP-6), `sops` and `age` (EP-3, EP-7), the Google Cloud SDK `gcloud`/`gsutil`
(EP-2, EP-3, EP-4, EP-7), `tailscale` client tooling, `socat` (the SSH `ProxyCommand` for IAP tunnels,
working around the macOS OpenSSH 10.x ↔ gcloud bug documented in the reference repo), `jq`, and `just`
(the command runner for the `justfile`). Pulumi is pinned to a current upstream release via a
`pkgs.pulumi.overrideAttrs` overlay (with `pulumi-nodejs` overridden to inherit it), exactly as in the
reference repo's `flake.nix`. Each consuming plan restates the specific tools it needs so it remains
independently implementable.

**9. GCP project isolation (policy owned by EP-1's `CLAUDE.md`/`.envrc`; obeyed by EP-2, EP-3, EP-4,
EP-7).** Every GCP resource and every `gcloud`/`gsutil`/`pulumi` invocation targets `tan-nb-exp`,
`us-west1`, `us-west1-a`. EP-1 establishes this with a repo-root `.envrc` exporting
`CLOUDSDK_CORE_PROJECT=tan-nb-exp`, `CLOUDSDK_COMPUTE_REGION=us-west1`, `CLOUDSDK_COMPUTE_ZONE=us-west1-a`,
`PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"`, and `PULUMI_CONFIG_PASSPHRASE=""`, plus a `CLAUDE.md`
section restating the policy. Every shell script under `scripts/` that calls `gcloud` must include the
preflight assertion (refuse to run unless the active project equals `tan-nb-exp`) and pass
`--project=tan-nb-exp` explicitly, copied verbatim from the reference repo. Pulumi state is isolated
in-repo via `pulumi login file://./infra/pulumi/.pulumi-state` with the passphrase secrets provider.

**10. NixOS GCE image build/upload pipeline (owned by EP-3; bucket from EP-2; consumed by EP-2's
instance).** Because the workstation is `aarch64-darwin`, NixOS images are built on an on-demand
`x86_64-linux` Nix remote builder in GCP. EP-3 provides a `nixos/flake.nix` with a `mkImage` helper
that composes `${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix` with the host
configuration and exposes `config.system.build.image` (a directory containing one `*.raw.tar.gz`), and
a `scripts/setup-nix-builder.sh` (provision the builder) plus `scripts/upload-images.sh` (build the
image addressed by its full attribute path `packages.x86_64-linux.nagare-image`, upload the tarball to
the GCS image bucket, register it with `gcloud compute images create --source-uri`, and write the
resulting self-link into Pulumi config key `nagareImageSelfLink`). EP-2 creates the image-staging GCS
bucket and its instance component reads `nagareImageSelfLink` as the boot image. These scripts are
adapted directly from the reference repo's `scripts/setup-nix-builder.sh` and `scripts/upload-images.sh`;
read those before implementing. Day-2 host changes use `nixos-rebuild switch --flake .#nagare-01
--target-host nagare-01 --sudo` over Tailscale; the image build is only for first boot and clean
rebuilds.


## Progress

Milestone-level progress across all child plans. Updated as each child plan's milestones complete.

- [x] EP-1: Flake, dev shell, repository skeleton, and `justfile` exist; `nix develop` provides the toolchain. (2026-06-02)
- [x] EP-2: Pulumi project creates the IP, DNS, disk, SA+IAM, Artifact Registry, and both buckets; all nine stack outputs exported; VM `nagare-01` created and RUNNING from the registered NixOS image (M1+M2+M3 done). (2026-06-02)
- [x] EP-3: NixOS image built & registered, `nagare-01` deployed booting the baked image; data disk formatted & mounted with all seven subdirs; the sshd "connection closed at userauth" blocker was resolved (disable PerSourcePenalties + OS Login; public DNS resolvers; post-mount subdir oneshot). Verified live: `kubectl get nodes` = Ready (k3s v1.35.4, NixOS 26.11); coredns/local-path-provisioner/metrics-server Running; a test PVC Bound under `/var/lib/nagare/local-path`. Residual operator follow-ups (non-blocking for EP-4/5/6): join Tailscale with a real auth key, and exercise the day-2 `nixos-rebuild --target-host`. (2026-06-02)
- [x] EP-4: cert-manager + `letsencrypt-dns` issuer (Ready), Knative Serving + Kourier, and
  net-certmanager all installed and wired; the hello sample service answers over **HTTP**
  (`Hello Nagare!`, 200) and a custom-domain DomainMapping routes. **Marked Complete (operator
  decision 2026-06-02)** with Let's Encrypt wildcard **TLS/HTTPS deferred** as a domain-gated
  follow-up — enabling it is one config flip (`just cluster-enable-tls`) once a real apps domain is
  set in Pulumi `baseDomain`, `pulumi up`-applied, and delegated to the zone's nameservers. This
  unblocks EP-6's hard dependency. (2026-06-02)
- [x] EP-5: VictoriaMetrics/Logs/Traces + OTel Collector + Grafana installed and verified live —
  `up`/node metrics return data; container logs searchable via `{kubernetes.pod_namespace="..."}`; a
  test trace (`nagare-test`) is queryable through VictoriaTraces' Jaeger API; retention 30d/7d/3d; all
  PVCs Bound to `local-path`; reproducible via `just observability`. Required enlarging the boot disk
  to 100 GB (VM rebuild) and a live DNS workaround (EP-3 image follow-up). (2026-06-03)
- [ ] EP-6: `nagarectl deploy` reads `nagare.yaml`, builds/pushes, renders/applies the Knative Service, and prints a live URL.
- [ ] EP-7: sops-encrypted secrets, Litestream/Postgres backups to GCS, dashboards in Git, and a tested recovery runbook.


## Surprises & Discoveries

- EP-1: `pkgs.nodejs_20` is now marked insecure (end-of-life) in the resolved `nixos-unstable` channel
  and refuses to evaluate, so the dev shell pins `pkgs.nodejs_22` (current LTS) instead. This affects
  EP-2, which authors the Pulumi/TypeScript program against that Node runtime — EP-2 should assume
  Node 22, not 20. The pinned Pulumi CLI is unchanged (3.239.0). (2026-06-02)
- EP-1: Nix flakes only see Git-tracked files; new flake-referenced files must be `git add`-ed before
  `nix develop` / `nixos-rebuild` will see them. Directly relevant to EP-3's `nixos/flake.nix` image
  build. (2026-06-02)
- EP-2: the shared `tan-nb-exp` project did not have all required GCP service APIs enabled. `compute`,
  `dns`, and `storage` were on, but `artifactregistry.googleapis.com` and `iam.googleapis.com` were
  off and had to be enabled with `gcloud services enable ... --project=tan-nb-exp` before `pulumi up`
  could create the Artifact Registry repo and the service account. Affects every GCP-touching plan on
  a clean project: EP-4 (cert-manager DNS-01 needs `dns` — already on), EP-7 (storage — on). Likely
  still-needed-but-unverified APIs for later plans: none known beyond these. Consider adding
  `gcp.projects.Service` resources to EP-2 so a clean-project rebuild is fully self-contained.
  (2026-06-02)
- EP-3: **host SSH access to `nagare-01` is an open blocker** affecting any plan that needs a shell on
  the node (EP-4/5/6 run `kubectl`/`helm` against the cluster). After two initial successful IAP-SSH
  sessions, sshd closes every subsequent connection (IAP and direct, even on a freshly-reset VM) at the
  start of userauth. Not resolved remotely because SSH is the failing channel, NixOS routes
  startup-script stdout to journald (not the serial console), and a GCS-upload diagnostic did not land.
  The image build, GCE image registration, VM deploy, and data-disk format all succeeded; this is a
  host-access/observability issue, not an infra defect. Likely culprits to check with a working shell
  (GCP interactive serial console, or a rebuilt image): OS Login `AuthorizedKeysCommand` failure during
  userauth, or OpenSSH `PerSourcePenalties` (try `services.openssh.settings.PerSourcePenalties = "no"`).
  Also: NixOS does not forward metadata `startup-script` stdout to the serial console (use GCS or
  journald), and `scripts/iap-ssh.sh` should add `-o IdentitiesOnly=yes`. (2026-06-02)
- EP-3: **the M3 sshd host-access blocker is RESOLVED.** Two changes fixed it: (1)
  `services.openssh.settings.PerSourcePenalties = "no"` — the OpenSSH 9.8+/10.x per-source penalty
  heuristic was dropping post-KEX connections (all IAP connections share one source IP, so a few
  failed attempts locked the box out); (2) `security.googleOsLogin.enable = lib.mkForce false` — the
  GCE module's OS Login `AuthorizedKeysCommand` was the other userauth-close cause; we auth as
  `deploy` with the operator key so OS Login is unnecessary. A separate fix made first boot fully
  clean: the GCE metadata DNS (169.254.169.254) is unreachable on this VM, so `networking.nix` sets
  public resolvers (8.8.8.8/8.8.4.4) and stops dhcpcd overwriting resolv.conf — without which k3s
  could not pull coredns/local-path images. The cluster is now verified Ready live. (2026-06-02)
- EP-4: **the apps base domain is still the placeholder `apps.example.com`**, and the Cloud DNS zone
  EP-2 created is authoritative only for that placeholder. Let's Encrypt DNS-01 validation therefore
  cannot succeed (the real authoritative nameservers for `example.com` are not this zone's), so EP-4's
  Let's Encrypt **wildcard TLS (M1 test cert + M3 HTTPS) is deferred** until the operator supplies a
  real domain and delegates it to the zone's Cloud DNS nameservers. Per the operator's choice
  (HTTP-first), EP-4 installs cert-manager + Knative + Kourier + net-certmanager and proves the hello
  app over **HTTP** (`curl --resolve … :80:publicIp`); enabling TLS later is a one-config flip
  (`config-network: external-domain-tls: Enabled` + `namespace-wildcard-cert-selector: {}`). This
  affects EP-6 too (a deployed app's HTTPS URL needs the same real domain). (2026-06-02)
- EP-4/cluster access: the kube-apiserver (6443) is reachable **only** on the Tailscale interface
  (firewall opens 22/80/443; 6443 is `trustedInterfaces = [tailscale0]`), and Tailscale is not yet
  joined. IAP cannot tunnel directly to 6443 either (the IAP firewall rule permits only port 22).
  The working pattern for cluster-touching plans (EP-4/5/6) until Tailscale is up: an SSH local
  forward over the port-22 IAP path — `ssh -L 6443:127.0.0.1:6443 -N deploy@nagare-01` through the
  IAP tunnel — then `kubectl` against the unmodified kubeconfig (server `https://127.0.0.1:6443`,
  whose k3s cert SAN includes 127.0.0.1). One durable connection avoids the per-command IAP-tunnel
  throttling EP-3 documented. (2026-06-02)
- EP-5 (cross-plan, affects EP-2/EP-3/EP-4): **`nagare-01`'s 6 GB boot disk is too small.** EP-2's
  `NagareInstance.ts` sets `bootDisk.initializeParams` with **no `size`**, so GCE defaults the boot
  disk to the NixOS image's ~6 GB minimum. That 6 GB root holds both `/nix/store` and the containerd
  image store, and filled to 99% when EP-5's observability images pulled, tripping `DiskPressure` →
  node-exporter `Evicted`, the `vmks` install `context deadline exceeded`, and EP-4's Knative pods
  destabilized. The 100 GB data disk (`/var/lib/nagare`) is the right place for bulk storage and is
  only 1% used (PVCs bind there fine), but **container images and ephemeral storage live on the root
  disk**, which is the constraint. EP-5 M1–M3 are blocked until this is fixed. Fix options: (A)
  in-place `gcloud compute disks resize nagare-01 --size=<N>` + reboot (EP-3's `google-compute-image`
  module has `growPartition`, so root auto-grows; then `pulumi refresh` + set `size` in
  `NagareInstance.ts` to keep Git authoritative); or (B) set `bootDisk.initializeParams.size` in
  `NagareInstance.ts` and `pulumi up` to recreate the VM, then re-run `just cluster-bootstrap` (EP-4)
  + `just observability` (EP-5). The data disk is a separate resource and survives either path. This
  belongs in EP-2's instance component (boot disk sizing) and should be recorded so a clean rebuild
  is correctly sized from the start. (2026-06-02)
  **RESOLVED (2026-06-03):** per the operator, `NagareInstance.ts` now sets
  `bootDisk.initializeParams.size = 100`; `pulumi up` replaced only the instance (`+-1 replaced, 20
  unchanged` — data disk, IP, DNS, SA preserved) and NixOS grew root to 99 G. EP-4 was re-bootstrapped
  and EP-5 installed cleanly; root now 8 % used.
- EP-5/EP-3 (cross-plan, reproducibility): **the registered NixOS GCE image lacks EP-3's
  `networking.nix` DNS fix, so a clean rebuild boots with broken DNS.** When EP-5's VM rebuild booted a
  fresh instance from `nagareImageSelfLink`, `/etc/resolv.conf` had the unreachable metadata resolver
  `169.254.169.254` (the booted system has no `nohook resolv.conf` in `/etc/dhcpcd.conf` and no
  `/etc/static/resolv.conf`), so external image pulls failed (`Temporary failure in name resolution`)
  and coredns (`forward . /etc/resolv.conf`) inherited the broken upstream (the `letsencrypt-dns`
  issuer reported `acme-v02... server misbehaving`). The `networking.nix` **source is correct** — the
  image was evidently built before that file was git-tracked (EP-1 surprise: flakes only see
  git-tracked files), and the previously-working VM had the fix applied via a day-2 `nixos-rebuild`.
  Worked around live (static `8.8.8.8` resolv.conf, `chattr +i`, coredns restart) — **not reboot-safe.**
  Durable fix: rebuild + re-register the image with `just host-image` so clean rebuilds boot with
  working DNS (EP-3 follow-up; see EP-3 Surprises). This directly threatens the MasterPlan's
  "boring, reproducible rebuild" goal until done. (2026-06-03)
- EP-2: the in-repo Pulumi file backend is logged into from **within `infra/pulumi`** with
  `file://./.pulumi-state` (a relative `file://` URL re-resolves against the project dir, so the
  repo-root form doubles the path). This refines Integration Point 9's wording for any plan that runs
  `pulumi` (EP-3 sets `nagareImageSelfLink` config the same way: `cd infra/pulumi && pulumi config
  set ...`). (2026-06-02)


## Decision Log

- Decision: `nagarectl` is implemented in Haskell, not TypeScript as the spec's suggested layout
  implied.
  Rationale: The authoritative `mori` project identity declares the `nagarectl` package as a Haskell
  tool, and the user confirmed this explicitly ("the CLI nagare is going to be written in haskell, but
  the provisioning is pulumi and nix"). The relevant Haskell dependencies are available in the local
  `mori` corpus (`brendanhay/gogol` for GCP, `codedownio/kubernetes-api`, `haskell-servant/servant`,
  `dhall-lang/dhall-haskell`, `iand675/hs-opentelemetry`, `garnix-io/cradle` and
  `pcapriotti/optparse-applicative`). The spec's `cli/nagarectl/package.json`/`.ts` layout was
  corrected accordingly.
  Date: 2026-06-02

- Decision: v1 TLS uses cert-manager + Kourier (Kubernetes-native), not host-level Caddy.
  Rationale: The user chose "cert-manager + Kourier" over the spec's Caddy recommendation. This makes
  wildcard certificates require a Let's Encrypt DNS-01 challenge (HTTP-01 cannot issue wildcards),
  which drives Integration Points 2 and 4 (Cloud DNS solver + `roles/dns.admin` on the VM service
  account) and the use of the `net-certmanager` bridge with `external-domain-tls: Enabled`.
  Date: 2026-06-02

- Decision: keep k3s's built-in ServiceLB (Klipper) enabled; only disable Traefik.
  Rationale: Research found that disabling ServiceLB conflicts with Kourier, whose gateway Service is
  `type: LoadBalancer` by default; on a single node, ServiceLB simply binds host ports 80/443 to that
  Service, which is the simplest reliable path. The spec's `--disable=servicelb` was therefore
  reconsidered and recorded as a correction in the spec appendix.
  Date: 2026-06-02

- Decision: decompose into seven child plans grouped into four implementation waves.
  Rationale: The boundaries follow the spec's ownership boundary (Pulumi/NixOS/k3s/Knative/Victoria/
  nagarectl) and the five `mori` packages, plus foundation and durability streams. Observability is
  kept as one plan with three milestones rather than three plans, and DNS/TLS cluster wiring is kept
  with the Knative bootstrap rather than split out, to minimize integration points. See Decomposition
  Strategy for rejected alternatives.
  Date: 2026-06-02

- Decision: the canonical apps base domain placeholder is `apps.example.com`, supplied via Pulumi
  config and surfaced as the `baseDomain` stack output.
  Rationale: Every plan needs a consistent domain to compute Knative URLs and DNS records; pinning a
  single placeholder and a single source (the Pulumi output) prevents drift across plans (Integration
  Point 4).
  Date: 2026-06-02

- Decision: all GCP work targets the `tan-nb-exp` project, region `us-west1`, zone `us-west1-a`, with
  the same hard isolation policy as the sibling `load-testing-infra` repo.
  Rationale: The user instructed "it's important to use the tan-nb-exp gcp account for the work." The
  reference repo enforces single-project isolation via `.envrc` env vars, a `CLAUDE.md` policy, and a
  per-script preflight assertion; Nagare adopts the identical mechanism (Integration Point 9). Changing
  the target project later requires a Decision Log entry first.
  Date: 2026-06-02

- Decision: reuse the sibling `load-testing-infra` repo as the canonical pattern source for the Pulumi
  dev shell, in-repo Pulumi state, component-based Pulumi layout, and the NixOS GCE image pipeline.
  Rationale: The user pointed at `/Users/shinzui/Keikaku/bokuno/load-testing-infra` and said "we use
  latest pulumi with nix" and "we have a linux builder to build images." That repo already solves the
  exact problems Nagare faces (current Pulumi pinned via a Nix overlay; aarch64-darwin workstation that
  cannot build x86_64-linux images locally). Copying its proven patterns reduces risk and keeps the two
  repos consistent. See Integration Points 8 and 10.
  Date: 2026-06-02

- Decision: NixOS images are built on an on-demand x86_64-linux Nix remote builder in GCP, uploaded to
  a GCS bucket, and registered as GCE images; the VM boots from the registered image self-link, and
  day-2 changes use `nixos-rebuild switch --target-host` over Tailscale.
  Rationale: The developer workstation is aarch64-darwin and cannot natively build the x86_64-linux GCE
  image; the reference repo's `setup-nix-builder.sh` + `upload-images.sh` pipeline is the established
  solution. This supersedes the spec's implicit assumption that `nixos-rebuild` alone provisions the
  box. The baked image gives a clean first boot and reproducible rebuilds (Integration Point 10).
  Date: 2026-06-02


## Outcomes & Retrospective

(To be filled during and after implementation. Compare the delivered system against the Vision &
Scope and the spec's MVP Definition: one-command deploy, scale-to-zero, observability, and a boring,
reproducible rebuild.)
