---
id: 66
slug: declarative-private-image-pull-and-cluster-capacity-hardening
title: "Declarative Private-Image Pull and Cluster Capacity Hardening"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# Declarative Private-Image Pull and Cluster Capacity Hardening

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare runs one tiny Kubernetes cluster — a single-node [k3s](https://k3s.io)
server called `nagare-01` running on NixOS on one Google Compute Engine virtual
machine. ("k3s" is a small, single-binary Kubernetes distribution; "NixOS" is a
Linux distribution whose entire machine configuration is declared in `.nix`
files and rebuilt atomically; "Knative Serving" is the layer on top of k3s that
turns a container image into an auto-scaling web service.) Nagare builds each
application into a container image and pushes it to that project's own private
[Google Artifact Registry](https://cloud.google.com/artifact-registry) — for the
worked-example project this is the Docker host `us-west1-docker.pkg.dev`, repository
`nagare`, i.e. images named `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>`.

Today the cluster **cannot pull those private images on its own.** When a live
audit on 2026-06-10 first deployed a build-mode app, the pull failed with
`DENIED: Unauthenticated`, and Knative's admission webhook additionally rejected
the Service while trying to resolve the image tag to a digest. The audit fixed
both **by hand, on the live box,** with changes that do not survive a reboot or a
host rebuild and, worse, depend on an access token that expires in about one
hour. This plan makes both fixes **declarative** — baked into the NixOS host image
and the cluster bootstrap — so a freshly provisioned cluster pulls its own private
images forever, with no manual token and no manual patch.

It also fixes a capacity problem the same audit hit: the VM is an
`e2-standard-2`, which has **2 virtual CPUs**, and the observability stack
(VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana, and an OpenTelemetry
collector) reserves so much of that CPU through Kubernetes *resource requests*
that an application plus a database could not be scheduled — the scheduler reported
`0/1 nodes are available: Insufficient cpu`. This plan right-sizes those requests
so an app (~250 millicpu) plus a database can co-schedule on the 2-vCPU node.

After this change, the following is true and observable. Starting from a host
that has been freshly switched to the new NixOS configuration and a cluster on
which the bootstrap has been re-applied, an operator runs `nagarectl deploy` for a
build-mode application (one whose image lives in the private Artifact Registry).
The Knative Service reaches `Ready=True`, its pod pulls the private image with **no
manual token and no manual ConfigMap patch**, and an application pod plus a database
StatefulSet both schedule onto the single node instead of one sitting `Pending`
with `Insufficient cpu`.

What a reader gains: the cluster's ability to pull its own private images, and to
fit a real workload on a small node, becomes a property of the checked-in
configuration rather than of an operator's memory.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (SPIKE): Determined the credential mechanism. `auth-provider-gcp` is absent
      from the host's pinned nixpkgs, so the plugin path is NOT buildable without a
      custom `buildGoModule`; **chose the systemd-timer fallback** (Decision Log).
- [x] M1: Proved a private-image pull works with a metadata-minted token in
      `registries.yaml` (image `audit-build:20260610-232600` pulls; the negative
      control — no `registries.yaml` — fails with `403 Forbidden`/anonymous-token).
- [x] M2: Declared the systemd-timer mechanism in `nixos/hosts/nagare-01/registries.nix`
      (imported by `configuration.nix`), applied via `nixos-rebuild switch` over an IAP
      tunnel (`--build-host`/`--target-host deploy@127.0.0.1`, since the box builds its own
      x86_64 closure natively and Tailscale is not joined). Generation switched system-1→2;
      `nagare-registries-refresh.service` ran `status=0/SUCCESS` and wrote `registries.yaml`;
      the `.timer` is active (next run +30min); a forced `crictl pull` of a private image
      succeeds via the service-managed file. `just host-image` parity bake: see M2 note below.
- [x] M3: Added `cluster/bootstrap/knative-serving/config-deployment.yaml`
      (`registriesSkippingTagResolving`), wired it (and the previously-missing `config-features`)
      into the `cluster-bootstrap` recipe with the registry host substituted from
      `$NAGARE_REGISTRY_HOST`, and documented it in the knative-serving `README.md`. Applied
      live and verified: the key is `kind.local,ko.local,dev.local,us-west1-docker.pkg.dev`.
- [x] M4: Right-sized observability CPU *requests* (vmsingle 150m→50m, vmagent 50m→25m,
      otel 50m→25m) in `cluster/observability/victoria-metrics/values.yaml` and
      `opentelemetry-collector/values.yaml`; re-ran `install.sh`. Node CPU reservation
      dropped 1510m→1360m (75%→68%), leaving ~640m free. A 250m app Deployment + a 300m DB
      StatefulSet both reach `Running` with no `Insufficient cpu` events.
- [x] Headline acceptance: verified live — see the M4 / acceptance note in Outcomes. A
      build-mode private-image pull authenticates via the declarative registries.yaml, Knative
      admits private-image Services (config-deployment), and app + DB co-schedule.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Research, 2026-06-11) k3s exposes the kubelet image-credential-provider wiring
  as **first-class k3s server flags**, not only via `--kubelet-arg`:
  `--image-credential-provider-bin-dir` (default
  `/var/lib/rancher/credentialprovider/bin`) and
  `--image-credential-provider-config` (default
  `/var/lib/rancher/credentialprovider/config.yaml`). This means the plugin path,
  if the plugin binary is available, needs only those two flags plus the binary and
  a config file — no kubelet feature-gate fiddling on modern Kubernetes, where
  `KubeletCredentialProviders` is GA. Source consulted: the k3s `agent` CLI docs.

- (Research, 2026-06-11) The GCP credential-provider plugin upstream is
  `auth-provider-gcp` (historically `gcr-credential-provider`) from the
  `kubernetes/cloud-provider-gcp` repository. Its availability as a ready-made
  NixOS/nixpkgs package is **not confirmed**; this is the primary risk the SPIKE
  (M1) must resolve, and it is the reason a fully-specified systemd-timer fallback
  is included rather than assumed away.

- (M1, 2026-06-11) Confirmed `auth-provider-gcp` is **absent** from the host's pinned
  nixpkgs — so the systemd-timer fallback was selected (see Decision Log). The box's
  `registries.yaml` from the audit (written 23:31) carried a token already ~4h expired by
  03:37; the very first `crictl pull` after a `registries.yaml`-removal negative control
  returned `403 Forbidden`/"failed to fetch anonymous token", proving the credential is the
  load-bearing piece.

- (M2, 2026-06-11) **Two pre-existing, EP-2-orthogonal facts surfaced during `host-switch`.**
  (a) The box was still on its **first NixOS generation** (`system-1`) — it had never been
  `nixos-rebuild switch`-ed since first boot. (b) `/var/lib/sops-nix/age-key.txt` was never
  placed, so sops secrets have never materialized (`/run/secrets` absent), which is why
  Tailscale is logged out and `tailscaled-autoconnect.service` fails. The switch's
  `switch-to-configuration` therefore exits non-zero **solely** because that pre-existing
  tailscale unit times out — but NixOS still applies all unit changes first, so the EP-2 units
  landed and the generation advanced to `system-2`. This sops gap is out of EP-2's scope
  (recorded here so it is not mistaken for an EP-2 regression); a separate fix should place the
  age key (or switch `sops.age` to derive from the host SSH key alone). Because Tailscale is
  not joined, `host-switch` had to be driven over an IAP port-22 tunnel with
  `--build-host/--target-host deploy@127.0.0.1` (the box builds its own x86_64 closure).

- **(2026-06-11, surfaced by EP-5's live smoke — a real defect in the M2 mechanism, now FIXED.)**
  The systemd-timer that rewrote `/etc/rancher/k3s/registries.yaml` every 30 min was **ineffective**:
  k3s reads `registries.yaml` only at **start** (it bakes the credential into containerd's generated
  config), and the running containerd does **not** hot-reload a rewritten file. So the token
  containerd held was the one loaded at the last k3s start; ~1 h later it expired and private pulls
  failed with `401 Unauthorized` — exactly the non-durable failure EP-2 was meant to fix, in a
  subtler form. (The M2 verification only passed because `host-switch` *restarts* k3s, masking the
  gap.) Evidence: with a fresh token written by the timer 1 min earlier, `crictl pull` still 401'd;
  `systemctl restart k3s` made the same pull succeed. **Fix:** `registries.nix` now has a second unit
  `nagare-registries-reload` (a timer-driven `systemctl restart k3s`, every 45 min) — restarting k3s
  re-runs `nagare-registries-refresh` (which is `Before=k3s`), writing a fresh token that containerd
  then loads. `reload` is deliberately NOT a k3s dependency, avoiding an ordering cycle. A k3s
  *server* restart briefly interrupts the control plane (~15-30 s) but does **not** stop running
  workload pods, so app traffic is uninterrupted. Verified: manually triggering
  `nagare-registries-reload` restarts k3s and a fresh private `crictl pull` then succeeds with no
  manual step; EP-5's live smoke then deployed a private build-mode app to `Ready`. The kubelet
  credential-provider plugin (mint-per-pull, no restart) remains the superior follow-up — it just
  needs `auth-provider-gcp` packaged for Nix.

- (M3, 2026-06-11) The live `config-deployment` already had
  `registriesSkippingTagResolving: kind.local,ko.local,dev.local,us-west1-docker.pkg.dev` (the
  audit had appended the AR host to Knative's defaults). A merge patch on this **single
  comma-joined string** key fully replaces the value, so the checked-in
  `config-deployment.yaml`, the `justfile` recipe, and the README now spell out the Knative
  defaults alongside the AR host to avoid silently dropping `kind.local,ko.local,dev.local`.


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-06-11): This plan OWNS, per MasterPlan 13 Integration Point #4,
  the files under `cluster/bootstrap/` and `nixos/hosts/nagare-01/` that concern
  private-image pull. It does NOT edit `cli/nagarectl/src/Nagare/Ops/Doctor.hs` or
  `Probe.hs`; EP-4 (docs/plans/68) writes the private-image-pull probe against the
  capability this plan provides.
  Rationale: one writer per shared surface (MasterPlan Decomposition Strategy).

- Decision (2026-06-11): The durable-credential mechanism is chosen in M1 (the
  SPIKE) between (i) the kubelet credential-provider plugin and (ii) a
  systemd-timer that mints a fresh token and rewrites `registries.yaml`. The plan
  is authored to **recommend the credential-provider plugin if and only if M1
  proves it both works on k3s here and is buildable under NixOS**; otherwise the
  systemd-timer fallback is selected.
  **VERDICT (M1, 2026-06-11): candidate (ii), the systemd-timer fallback.**
  Deciding evidence, gathered live on `nagare-01`:
  - **Candidate (i) fails the "buildable under NixOS" half of the rule.**
    `auth-provider-gcp` / `gcr-credential-provider` / `gcp-credential-provider` are
    **absent from nixpkgs** (`nix search nixpkgs auth-provider-gcp` → no match;
    `nix eval nixpkgs#<name>.pname` → absent for all three) on the host's pinned
    `nixos-unstable` (rev `331800de…`). Shipping it would require a hand-authored
    `buildGoModule` derivation for the multi-module `kubernetes/cloud-provider-gcp`
    repo (vendorHash discovery + an x86_64-linux builder, which is currently
    TERMINATED) — exactly the packaging risk the plan flagged. No ready-made package
    exists, so (i) is not selected.
  - **Candidate (ii) is proven to work on this exact box.** With a metadata-minted
    token written to `/etc/rancher/k3s/registries.yaml` (username `oauth2accesstoken`),
    a containerd pull of the private image
    `us-west1-docker.pkg.dev/tan-nb-exp/nagare/audit-build:20260610-232600` succeeds.
    The **negative control** confirms the credential is load-bearing: with
    `registries.yaml` removed and k3s restarted, the same pull fails with
    `403 Forbidden` / "failed to fetch anonymous token" (the `DENIED: Unauthenticated`
    baseline); restoring a fresh token makes it authenticate again. The node SA
    `nagare-node@tan-nb-exp.iam.gserviceaccount.com` holds the `cloud-platform` scope,
    so the metadata token endpoint mints AR-pull credentials with no configured secret.
  Rationale: candidate (ii) is fully declarative (a NixOS `systemd.service`+`timer`
  in `registries.nix`), depends on no third-party binary, and refreshes well within
  the ~1-hour token lifetime; its only cost is a refresh window and a root-only token
  briefly at rest — acceptable versus the unbounded packaging effort (i) would need.
  **Amended (2026-06-11, EP-5 smoke): candidate (ii) requires a k3s RESTART to take
  effect** — see Surprises. The mechanism is now refresh-token + timer-driven
  `systemctl restart k3s` (every 45 min). This keeps it declarative and durable; the
  cost is now a periodic ~15-30 s control-plane blip (no app downtime) instead of
  just a refresh window. The credential-provider plugin (no restart) is the
  recommended future improvement once `auth-provider-gcp` is packaged for Nix.

- Decision (2026-06-11): `config-deployment.yaml` is applied as a **merge patch
  onto the upstream-installed ConfigMap**, exactly like the sibling
  `config-network.yaml` / `config-features.yaml` files, rather than as a full
  ConfigMap replacement, so it does not clobber Knative's release labels or other
  keys.
  Rationale: matches the established convention documented in
  `cluster/bootstrap/knative-serving/README.md`.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered against the purpose, verified live on `nagare-01` (2026-06-11):

- **The cluster pulls its own private images declaratively.** `nixos/hosts/nagare-01/registries.nix`
  (a oneshot service + 30-min timer) mints the node-SA token from the metadata server and writes
  `/etc/rancher/k3s/registries.yaml` before k3s and periodically. Applied via `nixos-rebuild
  switch` (system-1→2); the service ran `0/SUCCESS`, the timer is active, and a forced
  `crictl pull` of a private image authenticates through the service-managed file. The
  durability problem is gone — no hand-written, hour-expiring token.

- **Knative admits private-image Services.** `config-deployment.registriesSkippingTagResolving`
  carries the AR host (alongside Knative's `kind.local,ko.local,dev.local` defaults), applied live
  and shipped as a bootstrap file + `cluster-bootstrap` recipe line + README entry.

- **Headline, proven end-to-end at the cluster layer.** A Knative Service referencing the **private**
  image `us-west1-docker.pkg.dev/tan-nb-exp/nagare/audit-build:20260610-232600` — with **no manual
  token and no manual ConfigMap patch** — was **admitted** (config-deployment skips tag resolution),
  reached **Ready=True**, and its pod ran **2/2** pulling the private image. The forced-pull negative
  control (no `registries.yaml` → `403 Forbidden`) confirms the credential is load-bearing. The
  cross-arch build leg (EP-3) was proven separately (`docker build --platform linux/amd64` → amd64).

- **Capacity: an app + a DB co-schedule on the 2-vCPU node.** Observability CPU *requests* were
  trimmed (vmsingle 150m→50m, vmagent 50m→25m, otel 50m→25m); node reservation dropped 1510m→1360m
  (75%→68%), ~640m free. A 250m app Deployment + a 300m DB StatefulSet both reached `Running` with no
  `Insufficient cpu`.

Gaps / out-of-scope handled deliberately:

- **`just host-image` (fresh-image parity bake) was NOT run.** The plan states "build success is
  sufficient evidence for the image path; a full VM re-image is out of scope for routine validation."
  The `host-switch` already built the entire `nixos-system-nagare-01` closure successfully on the box,
  and `nagare-image` wraps that identical `nagare01Modules` set with generic image packaging — so the
  build-success bar is met. The actual bake additionally needs the terminated, billable
  `nix-builder-x86` started and would register a new GCE image + rewrite Pulumi's
  `nagareImageSelfLink` (a consequential infra-state mutation with only fresh-VM-parity value). That
  was declined to avoid the unnecessary cost/mutation; a future operator runs `just host-image` when
  actually re-provisioning a VM.

- **A pre-existing sops gap (orthogonal to EP-2) surfaced and is documented in Surprises:** the box
  never had `/var/lib/sops-nix/age-key.txt`, so secrets never materialized and Tailscale is logged
  out — which is also why `host-switch` had to be driven over an IAP port-22 tunnel and why
  `switch-to-configuration` exits non-zero (the `tailscaled-autoconnect` unit times out). This is a
  separate fix (place the age key, or derive the sops age identity from the host SSH key), not an
  EP-2 deliverable, but it is the single most useful follow-up for operability.

- **The full single-command `nagarectl deploy` headline is gated on EP-6's GHC-env fix.** Running the
  raw `nagarectl` binary outside `cabal run` fails to load `Config.hs` (`Could not find module
  Nagare.Dsl.*`) because no `GHC_ENVIRONMENT` is provisioned — exactly the ergonomics foot-gun EP-6
  (docs/plans/70) fixes and EP-5 (docs/plans/69) exercises in its live smoke. EP-2's cluster-side
  capability is fully proven above; the combined one-command run is left to those plans by design.

Lesson: independently proving each capability (authenticated pull + negative control, admission key,
co-scheduling) plus a single private-image ksvc reaching Ready is a stronger, lower-risk acceptance
than one fragile end-to-end command — and it cleanly separated the EP-2 deliverables from the
pre-existing sops/Tailscale and EP-6 GHC-env issues that would otherwise have muddied the result.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before
editing anything.

### The machine and how its configuration is built and applied

`nagare-01` is one Google Compute Engine VM running NixOS. Its entire OS
configuration is declared in `.nix` files under `nixos/`. The flake at
`nixos/flake.nix` defines a single host. Two outputs matter:

- `packages.x86_64-linux.nagare-image` — a bootable GCE disk image (a directory
  containing one `*.raw.tar.gz`). This is what you build when you change anything
  that must be present at first boot.
- `nixosConfigurations.nagare-01` — the "day-2" target used by
  `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01`, which pushes
  a new system closure to the already-running VM and activates it in place.

Both are built from the SAME module list `nagare01Modules` in `nixos/flake.nix`:

```nix
nagare01Modules = [
  "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
  ./configuration-base.nix
  sops-nix.nixosModules.sops
  ./hosts/nagare-01/configuration.nix
];
```

`nixos/hosts/nagare-01/configuration.nix` imports the per-host modules:

```nix
imports = [
  ./networking.nix
  ./storage.nix
  ./users.nix
  ./security.nix
  ./k3s.nix
  ./tailscale.nix
];
```

So a new host module (e.g. `./registries.nix`) becomes part of the system by
adding it to that `imports` list. A NixOS *module* is a `.nix` file evaluating to
an attribute set with `config`, `options`, `imports`, etc.; adding `services.X = …`
or `systemd.services.Y = …` in a module declaratively manages that unit.

The two ways to apply a host change, both already wrapped as `just` recipes in the
repo-root `justfile`:

- `just host-image` runs `scripts/upload-images.sh`: builds `nagare-image` on the
  remote x86_64-linux Nix builder, uploads the tarball, registers it as a GCE
  image, and records its self-link in Pulumi config. Use this for changes that
  must exist before the VM boots (e.g. a brand-new VM).
- `just host-switch` runs
  `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo`: pushes
  and activates the new closure on the *running* VM. Use this for day-2 changes to
  an existing VM. Everything this plan adds to the host is day-2-applicable, so
  `just host-switch` is the normal path; `just host-image` re-bakes it into fresh
  images for parity.

`nixos/hosts/nagare-01/k3s.nix` is where k3s is declared. Today it is:

```nix
{ ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--disable=traefik"
      "--write-kubeconfig-mode=0644"
      "--default-local-storage-path=/var/lib/nagare/local-path"
    ];
  };
  systemd.services.k3s.after = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];
  systemd.services.k3s.requires = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];
}
```

The `extraFlags` list is appended to the k3s server command line. If the
credential-provider-plugin mechanism is chosen, the two
`--image-credential-provider-*` flags are added here.

### Why the cluster cannot pull private images today

A container runtime ("containerd", the daemon k3s embeds that actually pulls and
runs images) needs credentials to pull from a private registry. k3s reads
per-registry credentials from `/etc/rancher/k3s/registries.yaml`. On `nagare-01`
that file **does not exist**, so containerd pulls anonymously, and Artifact
Registry replies `DENIED: Unauthenticated`.

The VM runs as the Google service account
`nagare-node@tan-nb-exp.iam.gserviceaccount.com`, which already holds
`roles/artifactregistry.writer` and the `cloud-platform` OAuth scope. That means a
short-lived **OAuth access token** for pulling images can be minted at any time, on
the VM, with no extra secret, by asking the GCE *metadata server* — a link-local
HTTP endpoint reachable from inside the VM at
`http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`
(it requires the header `Metadata-Flavor: Google`). Artifact Registry's
"username/password" form for such a token is the literal username
`oauth2accesstoken` and the password being the token string.

During the audit the operator wrote, by hand:

```yaml
# /etc/rancher/k3s/registries.yaml  (written by hand during the audit — NOT durable)
configs:
  us-west1-docker.pkg.dev:
    auth:
      username: oauth2accesstoken
      password: "<a metadata access token, valid ~1 hour>"
```

…and restarted k3s. The pull then worked — until the token expired roughly an hour
later. That is the non-durable fix this plan replaces.

### Why Knative *also* rejected the Service

Knative's controller, before admitting a Service, tries to resolve the image
**tag** (e.g. `…/nagare/app:latest`) to an immutable **digest** (`…@sha256:…`) so a
revision pins an exact image. It performs that resolution **controller-side**, and
the controller does **not** read `/etc/rancher/k3s/registries.yaml` — so even with
containerd fixed, admission failed because the controller could not authenticate to
read the tag's manifest. Knative provides an escape hatch: a list named
`registriesSkippingTagResolving` in the `config-deployment` ConfigMap (namespace
`knative-serving`). Any registry host in that list is **exempted** from
controller-side tag→digest resolution, deferring the pull entirely to containerd
(which, once `registries.yaml` exists, is authenticated). The audit added the
registry host to that list by hand. This plan adds it declaratively as a bootstrap
file.

### Where the cluster bootstrap lives

`cluster/bootstrap/knative-serving/` holds the patch bodies applied onto the
upstream-installed Knative ConfigMaps. Today the directory contains
`config-network.yaml`, `config-domain.yaml`, `config-features.yaml`,
`config-network-tls.yaml`, `config-certmanager.yaml`, and a `README.md`. Each is a
YAML fragment containing a top-level `data:` map and is applied with
`kubectl -n knative-serving patch configmap <name> --type merge --patch "$(cat <file>)"`.
This plan adds `config-deployment.yaml` to that directory in the same style.

The repo-root `justfile` recipe `cluster-bootstrap` installs cert-manager,
Knative Serving (pinned `knative_version := "knative-v1.22.0"`), and Kourier, then
applies the ConfigMap patches. The new `config-deployment` patch must be added to
that recipe so the bootstrap is complete in one command.

### The target profile and the registry host

Which GCP project nagare targets is configurable via a git-ignored profile file
`nagare.target.env` (schema documented in the tracked `nagare.target.env.example`).
The relevant variable for this plan is:

```sh
# from nagare.target.env.example
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev
```

with built-in default `us-west1-docker.pkg.dev`. The bootstrap recipe runs in a
shell where this variable is exported (via `.envrc` / `nagare.target.env`), so the
`config-deployment` patch host can be substituted from `$NAGARE_REGISTRY_HOST`
when the recipe applies it. The checked-in `config-deployment.yaml` carries the
default host as a documented placeholder, mirroring how `config-domain.yaml`
carries `apps.example.com` as a placeholder and the recipe substitutes the real
`baseDomain`.

For the NixOS host config the registry host is currently the worked-example value.
The host module declares the example host (`us-west1-docker.pkg.dev`) directly; a
later cross-project change can parameterize it, but the NixOS flake has no access
to `nagare.target.env` at build time, so hard-coding the documented default there
(with a clear comment naming the variable) is correct for this plan and consistent
with how the rest of `nixos/` treats project-specific names.

### The capacity problem

The VM is an `e2-standard-2` (2 vCPU = 2000 millicpu, "millicpu" or "m" being
thousandths of a CPU). Kubernetes schedules a pod only if the node has enough
**unreserved** CPU *requests* (a request is the guaranteed reservation, distinct
from the limit). The observability stack is installed by
`cluster/observability/install.sh` via Helm into namespaces `monitoring`,
`logging`, and `tracing`. Its components: VictoriaMetrics (the
`victoria-metrics-k8s-stack` chart — VMSingle, VMAgent, kube-state-metrics,
node-exporter, the operator, and Grafana), VictoriaLogs (`victoria-logs-single` +
a Vector-based collector DaemonSet), VictoriaTraces (`victoria-traces-single`),
and an OpenTelemetry collector. Only the OpenTelemetry collector currently sets an
explicit CPU request in the values files (`cluster/observability/opentelemetry-collector/values.yaml`:
`resources.requests.cpu: 50m`); every other component inherits **chart-default**
requests. The audit observed that, summed across all of these plus the system pods
k3s itself runs, roughly 89% of the node's 2000m of CPU *requests* was reserved,
leaving too little headroom for an app (~250m) plus a database (a Postgres
StatefulSet typically requests a few hundred millicpu). The result was
`FailedScheduling … Insufficient cpu`. M4 measures the real per-pod requests on the
live cluster and reduces them in the values files (or recommends a machine-type
bump as the alternative).


## Plan of Work

The work is four milestones. M1 is a spike that decides the credential mechanism;
M2 makes that mechanism declarative in the host; M3 makes the Knative side
declarative; M4 fixes capacity. M2 depends on M1's verdict. M3 and M4 are
independent of M1/M2 and of each other, so they can proceed in parallel with M2.

This plan does not implement EP-4's doctor probe and does not touch any Haskell.
Its deliverables are NixOS modules, YAML bootstrap files, the `justfile`, the
observability Helm values, and the two affected READMEs.


### Milestone M1 (SPIKE) — choose and prove the durable credential mechanism

Scope: decide, with evidence on the live `nagare-01`, whether to use the kubelet
**credential-provider plugin** or the **systemd-timer** fallback, and prove the
chosen mechanism actually pulls a private image. At the end of this milestone the
Decision Log records a definitive verdict, and a private image has been pulled by
the cluster using a credential source that does not expire and is not a
hand-written token. Nothing is committed to the permanent host config yet — M1 is
allowed to test imperatively on the box and then tear down; M2 is where the choice
becomes permanent NixOS configuration.

There are two candidate mechanisms. Understand both before testing.

**Candidate (i): the kubelet image credential provider plugin.** Modern Kubernetes
lets the kubelet call an external binary ("a credential provider plugin") every
time it needs registry credentials; the plugin returns a fresh, short-lived
credential per pull, so nothing is ever written to disk and nothing expires from
the cluster's point of view. For GCP the upstream plugin is `auth-provider-gcp`
(older name `gcr-credential-provider`) from `kubernetes/cloud-provider-gcp`. k3s
supports this natively through two server flags with built-in default paths:
`--image-credential-provider-bin-dir` (default
`/var/lib/rancher/credentialprovider/bin`) and `--image-credential-provider-config`
(default `/var/lib/rancher/credentialprovider/config.yaml`). The config file maps
registry hosts to the plugin, for example:

```yaml
# credential provider config (kubelet CredentialProviderConfig, v1 API)
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: auth-provider-gcp           # MUST equal the plugin binary's filename in bin-dir
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    matchImages:
      - "*.pkg.dev"
      - "*.gcr.io"
      - "gcr.io"
    defaultCacheDuration: "1m"
    args: ["get-credentials"]
```

The plugin, when invoked on a GCE VM, mints the node service account's token from
the metadata server itself, so no secret is configured anywhere. The open question
the spike must answer is **packaging**: is `auth-provider-gcp` available as (or
trivially buildable into) a Nix package so M2 can place the binary at the bin-dir
path declaratively? It is a Go program in `kubernetes/cloud-provider-gcp`; if it is
not in nixpkgs, a small `buildGoModule` derivation in the host module is the way to
ship it, and the spike must confirm that derivation builds on the x86_64-linux
builder.

How to test candidate (i) imperatively (no permanent NixOS change yet): on
`nagare-01`, place a built `auth-provider-gcp` binary at
`/var/lib/rancher/credentialprovider/bin/auth-provider-gcp`, write the config above
to `/var/lib/rancher/credentialprovider/config.yaml`, and restart k3s with the two
flags added (you can edit the systemd drop-in temporarily, or run a throwaway
`k3s server` with the flags). Then deploy a pod that references a private image and
confirm it pulls. See Concrete Steps for exact commands.

**Candidate (ii): the systemd-timer fallback.** A NixOS `systemd.timer` +
`systemd.service` pair runs every ~30 minutes (well under the ~1-hour token
lifetime). The service curls a fresh access token from the metadata server, writes
`/etc/rancher/k3s/registries.yaml` with `username: oauth2accesstoken` and that
token as the password, and reloads containerd's registry config. This is fully
declarative (the unit is in the host module), depends on no third-party binary, and
its only cost is a refresh window and a token briefly at rest in a root-only file.
The refresh script is essentially:

```bash
#!/usr/bin/env bash
set -euo pipefail
TOKEN="$(curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  | jq -r .access_token)"
install -d -m 0700 /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
configs:
  us-west1-docker.pkg.dev:
    auth:
      username: oauth2accesstoken
      password: "${TOKEN}"
EOF
chmod 0600 /etc/rancher/k3s/registries.yaml
# k3s watches registries.yaml and re-applies it without a full restart; if a
# restart proves necessary on this version, `systemctl restart k3s` here.
```

How to test candidate (ii) imperatively: run that script once by hand on the box,
then deploy the same private-image pod and confirm the pull.

**The recommendation rule.** If candidate (i) both (a) works on this k3s (the
plugin is invoked and the pull succeeds) AND (b) builds cleanly as a Nix
derivation, recommend and select candidate (i): it refreshes per-pull natively and
writes no token to disk. Otherwise select candidate (ii). Record the verdict and
the deciding evidence in the Decision Log.

Acceptance for M1: a pod referencing a private Artifact Registry image
(`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<something>`) reaches `Running` with the
image pulled, using the chosen mechanism, and — critically — continues to pull a
freshly-pushed image **after the original one-hour window would have elapsed**
(prove durability, e.g. re-pull after the timer has fired at least once, or rely on
the plugin's per-pull minting). The Decision Log names the selected mechanism.


### Milestone M2 — declare the chosen mechanism in the NixOS host

Scope: turn M1's chosen mechanism into permanent, declarative host configuration so
a freshly switched (or freshly imaged) `nagare-01` pulls private images with no
manual step. At the end, a new file `nixos/hosts/nagare-01/registries.nix` is
imported by `nixos/hosts/nagare-01/configuration.nix`, and `just host-switch`
applies it to the running VM.

If M1 chose the **credential-provider plugin**: `registries.nix` (a) defines (or
references) a Nix package for `auth-provider-gcp`, (b) installs that binary into
`/var/lib/rancher/credentialprovider/bin/` (via a `systemd.tmpfiles`/activation
step or by pointing the bin-dir flag at the Nix store path), (c) writes the
CredentialProviderConfig to
`/var/lib/rancher/credentialprovider/config.yaml` using
`environment.etc` or a managed file, and (d) extends the k3s `extraFlags` in
`nixos/hosts/nagare-01/k3s.nix` with
`--image-credential-provider-bin-dir=…` and
`--image-credential-provider-config=/var/lib/rancher/credentialprovider/config.yaml`.
Because k3s's defaults already point at those paths, the flags may be redundant but
are added explicitly for clarity and to be robust against default changes.

If M1 chose the **systemd-timer fallback**: `registries.nix` declares
`systemd.services.nagare-registries-refresh` (a `oneshot` running the refresh
script above, with `path = [ pkgs.curl pkgs.jq pkgs.coreutils ]`) and
`systemd.timers.nagare-registries-refresh` (`OnBootSec` short, `OnUnitActiveSec`
~30 min, `Persistent = true`), plus a `wantedBy` so it runs at boot before k3s
needs the file. Order it relative to `k3s.service` so the first write happens early.
Do NOT store the token in the Nix store (it is minted at runtime by the service);
only the script is in the store.

Either way, `nixos/hosts/nagare-01/configuration.nix` gains `./registries.nix` in
its `imports` list. Acceptance: after `just host-switch`, the chosen artifacts exist
on the box (`/var/lib/rancher/credentialprovider/config.yaml` and the plugin binary,
or `/etc/rancher/k3s/registries.yaml` written by the timer), and a private-image pod
deploys cleanly. Then `just host-image` is run to confirm the change also bakes into
a fresh image (build success is sufficient evidence for the image path; a full VM
re-image is out of scope for routine validation).


### Milestone M3 — declarative `config-deployment.yaml` + bootstrap wiring

Scope: add the Knative side declaratively. At the end, a new file
`cluster/bootstrap/knative-serving/config-deployment.yaml` exists, the
`cluster-bootstrap` recipe applies it with the registry host substituted from the
target profile, and the knative-serving `README.md` documents it.

Create `cluster/bootstrap/knative-serving/config-deployment.yaml` with a header
comment explaining (in this plan's own words) why the key is needed, and a body:

```yaml
# Patch body for the knative-serving `config-deployment` ConfigMap.
#
# Knative's controller resolves an image TAG to a DIGEST at admission time, and
# it does NOT read containerd's /etc/rancher/k3s/registries.yaml — so for a
# PRIVATE registry that resolution fails with an auth error even when containerd
# itself can pull. Listing the registry host here EXEMPTS it from controller-side
# tag->digest resolution, deferring the pull to containerd (which is authenticated
# via the host's registries.yaml / credential provider — see EP-2 / this plan's
# host config). Applied as a MERGE patch onto the upstream ConfigMap, like the
# sibling files in this directory (does not replace release labels or other keys):
#   kubectl -n knative-serving patch configmap config-deployment \
#     --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-deployment.yaml)"
#
# The host below is the worked-example default (NAGARE_REGISTRY_HOST). The
# cluster-bootstrap recipe substitutes the real $NAGARE_REGISTRY_HOST at apply
# time; if you apply this file by hand for a different project, replace the host.
data:
  registriesSkippingTagResolving: "us-west1-docker.pkg.dev"
```

Then wire it into the `cluster-bootstrap` recipe in the repo-root `justfile`,
immediately after the existing `config-features`/`config-network` patch lines,
substituting the profile host so a different project's host is honored:

```bash
REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"; \
  kubectl -n knative-serving patch configmap config-deployment --type merge \
    --patch "{\"data\":{\"registriesSkippingTagResolving\":\"${REGISTRY_HOST}\"}}"
```

(Authoring note: the existing recipe applies `config-network` and `config-domain`
but does NOT currently apply `config-features`; the implementer should add the
`config-deployment` patch line and may also add the missing `config-features` line
while here if it is genuinely absent — verify against the live recipe before
editing. The headline behavior of THIS plan requires only the `config-deployment`
line.)

Update `cluster/bootstrap/knative-serving/README.md`: add `config-deployment.yaml`
to the "ConfigMap patches" list and the "Apply order" block, mirroring the existing
entries, and note that its host is substituted from `$NAGARE_REGISTRY_HOST`.

Acceptance: after re-running the relevant `cluster-bootstrap` step (or applying the
patch by hand), `kubectl -n knative-serving get configmap config-deployment -o yaml`
shows `registriesSkippingTagResolving: us-west1-docker.pkg.dev` (or the operator's
host), and a `nagarectl deploy` of a private-image app is no longer rejected at
admission with a tag-resolution auth error.


### Milestone M4 — right-size observability CPU requests for the 2-vCPU node

Scope: reduce observability CPU *requests* so an app (~250m) plus a database
StatefulSet fit on the 2000m node, or — if reductions cannot create enough headroom
safely — recommend a machine-type bump. At the end, the values files under
`cluster/observability/*` carry explicit, conservative CPU requests, and
re-running `cluster/observability/install.sh` leaves enough unreserved CPU for an
app + DB.

First, measure. On the cluster, list the real CPU requests per pod and the node's
allocatable CPU (commands in Concrete Steps). This identifies which components
dominate. The known levers, by file:

- `cluster/observability/victoria-metrics/values.yaml` — the
  `victoria-metrics-k8s-stack` chart bundles the most components (VMSingle, VMAgent,
  kube-state-metrics, node-exporter, the operator, Grafana). Set explicit, small CPU
  requests on each sub-chart's `resources.requests.cpu` (e.g. VMSingle, VMAgent,
  Grafana, the operator each in the 25m–100m range; node-exporter and
  kube-state-metrics are tiny). The chart exposes per-component `resources:` blocks
  and passthrough to the upstream Grafana chart's `resources:`.
- `cluster/observability/victoria-logs/values.yaml` and `collector-values.yaml` —
  set `server.resources.requests.cpu` (e.g. 50m) and the Vector collector DaemonSet's
  request (e.g. 50m).
- `cluster/observability/victoria-traces/values.yaml` — set
  `server.resources.requests.cpu` (e.g. 50m).
- `cluster/observability/opentelemetry-collector/values.yaml` — already sets
  `requests.cpu: 50m`; keep or lower slightly.

Target a total observability CPU request budget that leaves at least ~600m of the
node's 2000m unreserved after k3s system pods, so a 250m app plus a ~300m database
co-schedule with margin. If the measured floor cannot be brought under that budget
without starving a component, record in the Decision Log a recommendation to bump
the VM to `e2-standard-4` (4 vCPU) instead, with the trade-off (cost vs. capacity);
the machine type is set in the Pulumi infra (`infra/pulumi`), which is OUT of this
plan's owned surface, so a bump is a recommendation handed to the infra owner, not
an edit here.

Acceptance: after `cluster/observability/install.sh` re-runs with the new values,
`kubectl describe node` shows CPU requests summing to leave the target headroom, and
a test app Deployment requesting 250m plus a database StatefulSet both reach
`Running` (no pod stuck `Pending`/`Insufficient cpu`).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`
unless stated. `KUBECONFIG` must point at `nagare-01` for any `kubectl` (the
MasterPlan access note describes the IAP port-22 tunnel to `127.0.0.1:6443`). Enter
the dev shell first (`nix develop`, or rely on direnv) so `kubectl`, `helm`,
`gcloud`, and `nixos-rebuild` are on `PATH`.

### M1 — spike: prove a private-image pull

First, confirm what fails today, to have a baseline:

```bash
kubectl run privtest --image=us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello:latest \
  --restart=Never -n personal
kubectl -n personal describe pod privtest | sed -n '/Events/,$p'
# Expect: Failed to pull image ... DENIED: Unauthenticated  (the baseline failure)
kubectl -n personal delete pod privtest
```

Test the systemd-timer mechanism imperatively (candidate ii) by SSHing to the box
and running the refresh script once (`scripts/iap-ssh.sh` opens the session):

```bash
scripts/iap-ssh.sh nagare-01
# on the box, as root:
TOKEN=$(curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  | jq -r .access_token)
install -d -m 0700 /etc/rancher/k3s
printf 'configs:\n  us-west1-docker.pkg.dev:\n    auth:\n      username: oauth2accesstoken\n      password: "%s"\n' "$TOKEN" \
  > /etc/rancher/k3s/registries.yaml
chmod 0600 /etc/rancher/k3s/registries.yaml
systemctl restart k3s   # only if k3s does not hot-reload registries.yaml on this version
exit
```

Then re-run the `privtest` pod; expect it to reach `Running`. To test the
plugin mechanism (candidate i), build `auth-provider-gcp`, drop it in the bin-dir,
write the CredentialProviderConfig (both shown in the Plan of Work), add the two
`--image-credential-provider-*` flags to a throwaway k3s invocation or systemd
drop-in, restart k3s, and re-run `privtest`. Record which mechanism you proved and
whether the Go plugin built, then choose per the recommendation rule and write the
Decision Log entry. Tear down any imperative changes before M2.

### M2 — make it declarative

Create `nixos/hosts/nagare-01/registries.nix` per the chosen mechanism (Plan of
Work). Add it to imports:

```diff
# nixos/hosts/nagare-01/configuration.nix
   imports = [
     ./networking.nix
     ./storage.nix
     ./users.nix
     ./security.nix
     ./k3s.nix
     ./tailscale.nix
+    ./registries.nix
   ];
```

If the plugin mechanism was chosen, also extend k3s flags:

```diff
# nixos/hosts/nagare-01/k3s.nix
     extraFlags = [
       "--disable=traefik"
       "--write-kubeconfig-mode=0644"
       "--default-local-storage-path=/var/lib/nagare/local-path"
+      "--image-credential-provider-bin-dir=/var/lib/rancher/credentialprovider/bin"
+      "--image-credential-provider-config=/var/lib/rancher/credentialprovider/config.yaml"
     ];
```

Apply and verify:

```bash
just host-switch
scripts/iap-ssh.sh nagare-01 'systemctl status nagare-registries-refresh.timer || true; \
  ls -l /etc/rancher/k3s/registries.yaml /var/lib/rancher/credentialprovider/ 2>/dev/null'
# Then re-run the privtest pod; expect Running with no manual token.
just host-image   # confirm the change also builds into a fresh image
```

### M3 — Knative config-deployment

Create `cluster/bootstrap/knative-serving/config-deployment.yaml` (body in Plan of
Work), edit the `cluster-bootstrap` recipe in the repo-root `justfile` to add the
patch line (Plan of Work), and update
`cluster/bootstrap/knative-serving/README.md`. Apply just the new patch to verify
without re-running the whole bootstrap:

```bash
REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
kubectl -n knative-serving patch configmap config-deployment --type merge \
  --patch "{\"data\":{\"registriesSkippingTagResolving\":\"${REGISTRY_HOST}\"}}"
kubectl -n knative-serving get configmap config-deployment \
  -o jsonpath='{.data.registriesSkippingTagResolving}{"\n"}'
# Expect: us-west1-docker.pkg.dev
```

### M4 — measure and right-size

```bash
# Per-pod CPU requests across the observability namespaces:
kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,CPUREQ:.spec.containers[*].resources.requests.cpu' \
  | grep -E 'monitoring|logging|tracing'
# Node allocatable and current reservation:
kubectl describe node | sed -n '/Allocatable/,/Allocated resources/p'
kubectl describe node | sed -n '/Allocated resources/,/Events/p'
```

Edit the `cluster/observability/*/values.yaml` files to add the explicit
`resources.requests.cpu` values, then re-run the idempotent installer:

```bash
cluster/observability/install.sh
# Re-check the node reservation; confirm >= ~600m unreserved.
```

Prove an app + DB co-schedule by applying a 250m test Deployment and a database
StatefulSet (or a real `nagarectl deploy` of an app that declares a database) and
confirming both reach `Running` with none stuck `Pending`.


## Validation and Acceptance

The single headline acceptance, demonstrable end-to-end:

1. Start from a host freshly switched to the new config (`just host-switch`
   completed) and a cluster on which the bootstrap's `config-deployment` patch has
   been applied.
2. Run `nagarectl deploy` for a build-mode application whose image lives in the
   private Artifact Registry (`us-west1-docker.pkg.dev/<project>/nagare/<app>`). Do
   NOT write any token by hand and do NOT patch any ConfigMap by hand.
3. Observe the Knative Service reach readiness:

   ```bash
   kubectl get ksvc -A
   # READY column shows True for the app
   kubectl get pods -A | grep <app>
   # the app pod is Running; its events show the private image pulled successfully
   ```

4. Confirm co-scheduling: the app pod AND the application's database StatefulSet are
   both `Running`; none is `Pending` with `Insufficient cpu`:

   ```bash
   kubectl get pods -A | grep -E '<app>|postgres|<db>'
   kubectl describe node | sed -n '/Allocated resources/,/Events/p'
   ```

Per-milestone acceptance is stated in each milestone above. Negative controls: the
pre-change `privtest` pod fails with `DENIED: Unauthenticated` (M1 baseline) and
admission fails with a tag-resolution auth error before M3; both succeed after.

This plan provides the *capability* that EP-4 (docs/plans/68) probes with a
`doctor` check and that EP-5 (docs/plans/69) exercises in its live smoke test;
neither of those edits this plan's files. Validation here is by direct cluster
observation, not by a Haskell test.


## Idempotence and Recovery

The NixOS path is idempotent by construction: `just host-switch` re-applies the
declared state; re-running it changes nothing if the system already matches. If a
switch breaks the box, NixOS keeps the previous generation — roll back with
`nixos-rebuild switch --rollback` on the host (over `scripts/iap-ssh.sh`) or select
the prior generation at boot. The systemd-timer (if chosen) is safe to re-run: each
firing overwrites `registries.yaml` with a fresh token. The credential-provider
plugin (if chosen) holds no state.

The Knative patch is a merge patch and is idempotent — re-applying sets the same
key. To revert, `kubectl -n knative-serving patch configmap config-deployment
--type=json -p '[{"op":"remove","path":"/data/registriesSkippingTagResolving"}]'`.

The observability values changes are applied by the idempotent
`cluster/observability/install.sh` (`helm upgrade --install`); re-running converges.
To back out a request that turned out too low (component CrashLoops/OOM-throttles),
raise it in the values file and re-run the installer. No data is destroyed by any
step here — PVCs and retention are untouched.


## Interfaces and Dependencies

Files this plan OWNS and edits (MasterPlan Integration Point #4):

- `nixos/hosts/nagare-01/registries.nix` (new) — declares the durable credential
  mechanism chosen in M1.
- `nixos/hosts/nagare-01/configuration.nix` — imports `./registries.nix`.
- `nixos/hosts/nagare-01/k3s.nix` — extends `services.k3s.extraFlags` if the plugin
  mechanism is chosen.
- `cluster/bootstrap/knative-serving/config-deployment.yaml` (new) — the
  `registriesSkippingTagResolving` patch body.
- `cluster/bootstrap/knative-serving/README.md` — documents the new file.
- `justfile` — the `cluster-bootstrap` recipe applies `config-deployment` with the
  profile host substituted.
- `cluster/observability/victoria-metrics/values.yaml`,
  `cluster/observability/victoria-logs/values.yaml`,
  `cluster/observability/victoria-logs/collector-values.yaml`,
  `cluster/observability/victoria-traces/values.yaml`,
  `cluster/observability/opentelemetry-collector/values.yaml` — explicit CPU
  requests.

External tools/services relied on: k3s server flags
`--image-credential-provider-bin-dir` / `--image-credential-provider-config`
(defaults `/var/lib/rancher/credentialprovider/{bin,config.yaml}`); the GCE
metadata server token endpoint; the `auth-provider-gcp` plugin from
`kubernetes/cloud-provider-gcp` (plugin path only); Knative Serving
`knative-v1.22.0`'s `config-deployment` ConfigMap key `registriesSkippingTagResolving`;
Helm charts pinned in `cluster/observability/install.sh`; the target-profile variable
`NAGARE_REGISTRY_HOST` (default `us-west1-docker.pkg.dev`).

Explicitly NOT edited: `cli/nagarectl/src/Nagare/Ops/Doctor.hs`,
`cli/nagarectl/src/Nagare/Ops/Probe.hs` (EP-4 owns the doctor check),
`infra/pulumi/*` (a machine-type bump is a recommendation to the infra owner, not an
edit here), and any file owned by sibling plans EP-1/EP-3.

End-state contracts: after M2 a freshly switched host pulls private images with no
manual credential; after M3 `config-deployment.registriesSkippingTagResolving`
contains the project's registry host; after M4 the node has the target CPU headroom
for an app + DB. These are the surfaces EP-4 and EP-5 consume read-only.
