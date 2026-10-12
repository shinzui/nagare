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

Full plan before trimming: [1-bootstrap-nagare-personal-paas.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/masterplans/1-bootstrap-nagare-personal-paas.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
typed `nagare/Config.hs` program: the tool builds and pushes the image, renders and applies a Knative
Service, wires up secrets and a custom domain, waits for readiness, and prints the URL. MP-2/EP-12
delivered this typed contract after replacing the original `nagare.yaml` proposal.

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

Seven original child-plan records resulted. Six were completed in this initiative; EP-6 was later
cancelled after MP-2/EP-12 delivered its intended deploy capability through the typed DSL. The
records are grouped into four implementation waves (phases) below. The boundaries were chosen to
maximize independent verifiability: each plan ends in a behavior a human can observe (a `pulumi preview` that
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
| 6 | nagarectl deploy CLI in Haskell | docs/plans/6-nagarectl-deploy-cli-in-haskell.md | None | None | Cancelled (superseded by MP-2 EP-12) |
| 7 | Backups, secrets, and disaster recovery | docs/plans/7-backups-secrets-and-disaster-recovery.md | None | EP-2, EP-3, EP-4 | Complete (Postgres live-test + full DR drill deferred) |

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
- **Wave 4 — Developer Experience & Durability:** EP-7 completed after the platform work. EP-6's
  original YAML implementation was cancelled after MP-2 EP-12 delivered the typed successor.

## Progress

Milestone-level progress across all child plans. Updated as each child plan's milestones complete.

- [x] EP-1: Flake, dev shell, repository skeleton, and `justfile` exist; `nix develop` provides the toolchain. (2026-06-02)
- [x] EP-2: Pulumi project creates the IP, DNS, disk, SA+IAM, Artifact Registry, and both buckets; all nine stack outputs exported; VM `nagare-01` created and RUNNING from the registered NixOS image (M1+M2+M3 done). (2026-06-02)
- [x] EP-3: NixOS image built & registered, `nagare-01` deployed booting the baked image; data disk formatted & mounted with all seven subdirs; the sshd "connection closed at userauth" blocker was resolved (disable PerSourcePenalties + OS Login; public DNS resolvers; post-mount subdir oneshot). Verified live: `kubectl get nodes` = Ready (k3s v1.35.4, NixOS 26.11); coredns/local-path-provisioner/metrics-server Running; a test PVC Bound under `/var/lib/nagare/local-path`. Residual operator follow-ups (non-blocking for EP-4/5 and the typed deploy CLI): join Tailscale with a real auth key, and exercise the day-2 `nixos-rebuild --target-host`. (2026-06-02)
- [x] EP-4: cert-manager + `letsencrypt-dns` issuer (Ready), Knative Serving + Kourier, and
  net-certmanager all installed and wired; the hello sample service answers over **HTTP**
  (`Hello Nagare!`, 200) and a custom-domain DomainMapping routes. **Marked Complete (operator
  decision 2026-06-02)** with Let's Encrypt wildcard **TLS/HTTPS deferred** as a domain-gated
  follow-up — enabling it is one config flip (`just cluster-enable-tls`) once a real apps domain is
  set in Pulumi `baseDomain`, `pulumi up`-applied, and delegated to the zone's nameservers. This
  supplied the cluster substrate later exercised by the typed deploy CLI. (2026-06-02)
- [x] EP-5: VictoriaMetrics/Logs/Traces + OTel Collector + Grafana installed and verified live —
  `up`/node metrics return data; container logs searchable via `{kubernetes.pod_namespace="..."}`; a
  test trace (`nagare-test`) is queryable through VictoriaTraces' Jaeger API; retention 30d/7d/3d; all
  PVCs Bound to `local-path`; reproducible via `just observability`. Required enlarging the boot disk
  to 100 GB (VM rebuild) and a live DNS workaround (EP-3 image follow-up). (2026-06-03)
- [x] EP-6: **Cancelled — superseded by MP-2 EP-12.** The original `nagare.yaml` parser and
  renderer were intentionally never implemented; EP-12 delivered `nagarectl deploy` against the
  typed `nagare/Config.hs` contract. Registry and dependency cleanup completed 2026-08-23.
- [x] EP-7: sops+age secrets (encrypted Secret round-trips to the cluster and into a pod via
  `secretRef`, verified live); Litestream SQLite backups replicating to
  `gcs://tan-nb-exp-nagare-backups/litestream/` via keyless ADC (verified live, after the metadata
  fix below); Postgres backup/restore scripts authored (live test deferred — no Postgres deployed);
  dashboards in Git; `docs/runbooks/disaster-recovery.md` written with backup inventory. Full
  clean-room DR drill deferred. (2026-06-03)
  **Update 2026-06-10 (deferral resolved via successor path):** the deferred Postgres
  backup/restore *live* test is now satisfied by MasterPlan 9's managed-database path, which
  supersedes the host-`notes`-Postgres `scripts/backup-postgres.sh` (that host DB was never
  deployed). Verified live against the running `nagare-01`: `nagarectl db backup` wrote a real
  `pg_dump` to `gs://tan-nb-exp-nagare-backups/databases/auditpg/…`, and `nagarectl db restore`
  round-tripped a known row into a scratch target (scratch-first DR drill) — see MP9 EP-47. The
  remaining open item is **wildcard TLS/HTTPS (EP-4)**, which stays **gated on a real DNS-01-capable
  domain** being delegated (the base domain is still the placeholder `apps.example.com`); a full
  bare-metal clean-room rebuild drill also remains future work. Litestream/SQLite backups stay
  live-verified.

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
  **DONE (2026-06-03):** per the operator, the image was rebuilt and re-registered (twice — once for
  DNS, then again for the metadata fix below); the latest `nagareImageSelfLink` boots with both fixes.
  The running host still carries the runtime workaround (immutable resolv.conf) until it next boots
  the new image via a VM replacement.
- EP-7/EP-3/EP-4 (cross-plan, in-cluster GCP auth): **pods could not reach the GCE metadata server,
  so keyless ADC failed for in-cluster workloads.** Surfaced when EP-7's Litestream sidecar could not
  authenticate to GCS (`could not find default credentials`, then `169.254.169.254:80: no route to
  host`). Root cause: dhcpcd assigned IPv4 link-local `169.254.0.0/16` addresses to the flannel/veth
  interfaces, and the on-link route hijacked the metadata IP onto `flannel.1`
  (`ip route get 169.254.169.254 → dev flannel.1`) instead of eth0. Fix in EP-3's `networking.nix`:
  `networking.dhcpcd.denyInterfaces = [veth* flannel* cni* kube* datapath*]` + a MASQUERADE for
  pod → `169.254.169.254`; the Litestream sidecar also sets `GCE_METADATA_HOST=169.254.169.254`.
  Validated at runtime (pod read the node SA from metadata; Litestream replicated to GCS), committed
  to source, and baked into the rebuilt image. **This also unblocks EP-4's deferred DNS-01 wildcard
  TLS** (cert-manager pods need GCP creds to write the Cloud DNS challenge record), which would have
  hit the same wall. (2026-06-03)
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

- Decision: retire EP-6 as Cancelled and remove it from active dependency edges.
  Rationale: MP-2 EP-12 delivered the plan's user-visible one-command deploy capability through the
  typed `nagare/Config.hs` contract while deliberately never creating EP-6's YAML parser and
  renderer. Marking EP-6 Complete would misstate history; implementing it would reintroduce an
  intentionally removed contract. EP-7 and later recovery work depend on the delivered CLI
  capability, not on this cancelled document.
  Date: 2026-08-23

## Outcomes & Retrospective

**Current resolution (2026-08-23): all seven original child-plan records are closed — six Complete
and EP-6 Cancelled as superseded.** MP-2 EP-12 delivered the typed `nagarectl deploy` experience
that replaced EP-6's abandoned YAML design. MP-1 therefore has no remaining implementation plan;
the environment-gated wildcard TLS and clean-room recovery exercises remain recorded validation
debt rather than active child implementation.

**Historical status snapshot (2026-06-03): six of seven child plans Complete (EP-1–EP-5, EP-7);
EP-6 (`nagarectl`) was Not Started.** The platform substrate exists end to end: Pulumi provisions
the GCP perimeter (IP,
DNS, disk, SA+IAM, Artifact Registry, buckets); a reproducible NixOS GCE image boots `nagare-01` with
k3s; Knative + Kourier + cert-manager serve a scale-to-zero web app over HTTP with a custom
DomainMapping; the VictoriaMetrics/Logs/Traces + Grafana observability stack is installed and verified
(metrics, logs, a test trace); and sops+age secrets plus Litestream backups to GCS work, with a
disaster-recovery runbook in `docs/runbooks/`. The headline `nagarectl deploy` one-command developer
experience (EP-6) is **not yet built** — it is the main remaining gap to the spec's MVP.

Delivered against the Vision & Scope / spec MVP:
- **Provisioning, host, cluster platform, observability, backups, runbook:** done and largely
  verified live.
- **Scale-to-zero web service over a real URL:** done over **HTTP** (`hello.personal.apps.example.com`
  → `Hello Nagare!`).

Deferred (each with a clear, recorded reason):
1. **Let's Encrypt wildcard HTTPS (EP-4)** — gated on a real apps domain delegated to the Cloud DNS
   zone; one config flip (`just cluster-enable-tls`) once a domain exists. The metadata-routing fix
   this session also removed the *second* blocker (cert-manager pods can now reach GCP for DNS-01).
2. **`nagarectl` one-command deploy (EP-6) — Not Started.** This session implemented EP-5 and EP-7;
   EP-6 (the Haskell deploy CLI) has not been built and is the principal remaining work to reach the
   spec's one-command-deploy MVP. A separate MasterPlan (`docs/masterplans/2-…`, plans 8–12) covers a
   typed config DSL for `nagarectl` and may inform or supersede parts of EP-6 — reconcile the two
   before implementing.
3. **Postgres backup live-test and a clean-room full DR drill (EP-7)** — the scripts/runbook exist;
   the Postgres test needs a deployed Postgres, and a true rebuild-from-nothing drill was not run to
   avoid destroying the live cluster.

Biggest lessons (all reproducibility-related, all now fixed in source + the rebuilt image):
- **Boot-disk sizing belongs in IaC.** The image's ~6 GB default tripped DiskPressure; `NagareInstance.ts`
  now pins 100 GB.
- **Clean-boot host networking was the recurring trap.** The registered image lagged `networking.nix`,
  and dhcpcd misbehaviour caused both the broken DNS (metadata resolver) and the metadata-route
  hijack that broke keyless in-cluster ADC. Both are fixed in `networking.nix` and baked into the
  rebuilt image; the running host carries runtime workarounds until its next clean boot.
- **A flake only bakes git-tracked files** — image rebuilds must follow source commits, or the image
  silently lags the repo (which is exactly how the DNS fix went missing).

Historical next steps recorded on 2026-06-03: (a) replace the VM onto the latest
`nagareImageSelfLink` to confirm a fully
clean boot (working DNS + metadata) and then drop the runtime workarounds; (b) implement/verify EP-6
`nagarectl` to realize the one-command-deploy MVP; (c) supply a real domain and run
`just cluster-enable-tls` for HTTPS; (d) deploy Postgres and run the EP-7 Postgres backup/restore.

**Operational state (2026-06-03):** `nagare-01` was **stopped** (`gcloud compute instances stop`,
status TERMINATED) to halt compute charges after this implementation pass. The boot + data disks and
the reserved static IP (`34.145.74.203`) remain (small storage/reservation cost); the latest fixed
image is `nagare-image-gnq7zw6pwd1a`. To resume, `gcloud compute instances start nagare-01` (note the
reboot caveats — re-apply the metadata route/MASQUERADE/coredns workarounds, or `pulumi up` to replace
the VM onto the fixed image for a clean boot). For a full cost stop, `cd infra/pulumi && pulumi
destroy`. See `docs/runbooks/disaster-recovery.md` → "Power management".
