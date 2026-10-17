---
id: 3
slug: nixos-host-nagare-01-with-k3s
title: "NixOS host nagare-01 with k3s"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
---

# NixOS host nagare-01 with k3s

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [3-nixos-host-nagare-01-with-k3s.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/3-nixos-host-nagare-01-with-k3s.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan builds the single machine that the entire Nagare personal Platform-as-a-Service
runs on: a Google Cloud Compute Engine virtual machine named `nagare-01`, running the NixOS
Linux distribution, hosting a single-node Kubernetes cluster provided by k3s. Everything
above it in the stack (Knative for serverless web apps, Kourier for ingress, cert-manager
for TLS, the Victoria observability tools, and the `nagarectl` deploy command-line tool)
installs onto the cluster this plan creates. Without this plan there is no machine and no
cluster, so this plan is a hard dependency of the cluster-platform plans (EP-4, EP-5) and a
soft dependency of the deploy-tool and backups plans (EP-6, EP-7).

Several terms used throughout this plan, defined in plain language so a complete newcomer can
follow it:

- **NixOS** is a Linux distribution whose whole configuration — installed packages, running
  services, kernel settings, users, firewall rules, mounted disks — is written as a single
  declarative expression in the *Nix language*. Building that expression produces an
  immutable, content-addressed *system closure* (a tree under `/nix/store/`). To change the
  machine you edit the expression and rebuild; rollback is just switching to a previous
  closure. The practical payoff for Nagare is reproducibility: the machine can be rebuilt
  from this Git repository plus a few encrypted secrets, which is the project's guiding goal.
- **Flake** is a self-contained Nix project rooted at a file named `flake.nix`. It declares
  *inputs* (other Nix projects pinned by URL and commit hash in a generated `flake.lock`) and
  *outputs* (things you can build, under attribute paths like `packages.<system>.<name>`).
  Pinning makes every build reproducible against exact dependency revisions.
- **GCE image** (Google Compute Engine image) is a bootable disk image registered with GCP
  that a virtual machine can boot from. NixOS can build one: the resulting artifact is a
  directory containing a single `*.raw.tar.gz` file (a gzipped tar holding one sparse
  `disk.raw`), which is exactly what `gcloud compute images create --source-uri` expects.
- **k3s** is a lightweight, single-binary Kubernetes distribution from Rancher/SUSE.
  *Kubernetes* is the system that schedules and runs containers across machines; k3s packages
  a complete Kubernetes control plane plus a container runtime (containerd), a network plugin
  (flannel), a load-balancer controller (ServiceLB, also called Klipper), an ingress
  controller (Traefik), and a storage provisioner (local-path-provisioner) into one process
  that is easy to run on a single node. We keep most of those defaults but disable Traefik
  (Kourier owns ingress instead) and repoint local storage at the data disk.
- **Tailscale** is a private mesh VPN built on WireGuard. Once `nagare-01` joins the Tailscale
  network ("tailnet"), the operator can reach it by a stable private name from their laptop
  without exposing SSH to the public internet.
- **sops-nix** is a NixOS integration of `sops` (Secrets OPerationS). Secrets are stored
  encrypted in Git and decrypted on the host at activation time using an `age` private key
  that lives only on the host. This plan uses it for exactly one secret — the Tailscale
  authentication key — and leaves broader secret management to EP-7.
- **IAP** (Identity-Aware Proxy) is a GCP service that tunnels TCP (including SSH) to a VM
  that has no public IP, authenticated by the operator's Google identity. We use it to reach
  the on-demand build VM and `nagare-01` before Tailscale is up.

The user-visible behaviors unlocked at the end of this plan are concrete and checkable:

1. From inside `nagare/nixos/`, `nix build .#packages.x86_64-linux.nagare-image` produces a
   store path containing one `*.raw.tar.gz` GCE image, built on a remote x86_64-linux Nix
   builder (because the developer workstation is `aarch64-darwin` and cannot build Linux
   images natively).
2. `scripts/upload-images.sh` uploads that tarball to the GCS image bucket created by EP-2,
   registers it as a GCE image, and writes its self-link into Pulumi config under the key
   `nagareImageSelfLink`, which EP-2's instance component reads to choose the boot image.
3. After EP-2 runs `pulumi up` and boots `nagare-01` from that image, the operator joins the
   tailnet / SSHes in and observes: `kubectl get nodes` reports the node `Ready`; the data
   disk is mounted at `/var/lib/nagare` with the seven required subdirectories present; the
   kubeconfig is at `/etc/rancher/k3s/k3s.yaml` with file mode `0644`; and a test
   PersistentVolumeClaim binds to a directory under `/var/lib/nagare/local-path`, proving the
   `--default-local-storage-path` flag took effect.
4. Day-2 host changes apply over Tailscale with
   `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo`.

## Progress

This section tracks granular work. Every stopping point — even mid-task — must be recorded
here so the next contributor knows exactly what remains. Milestones (see Plan of Work) are
the narrative; this is the checklist.

Milestone 1: NixOS configuration authored and `nagare-image` builds on the remote builder.

- [x] Create directory `nixos/` at the repo root with `nixos/hosts/nagare-01/`. (2026-06-02)
- [x] Author `nixos/flake.nix` with inputs `nixpkgs` and `sops-nix`, a `mkImage` helper, and
      the output `packages.x86_64-linux.nagare-image`. (2026-06-02 — GCE module moved into the shared
      module set so the day-2 `nixosConfigurations.nagare-01` target is also bootable; see Decision Log.)
- [x] Author `nixos/configuration-base.nix` (shared base: GCE module wiring via
      `services.gcp.enable`, base packages, nix settings, state version). (2026-06-02)
- [x] Author `nixos/modules/gcp.nix` (GCE compatibility module, adapted from the reference repo).
      (2026-06-02)
- [x] Author the host files under `nixos/hosts/nagare-01/`: `configuration.nix`, `k3s.nix`,
      `networking.nix`, `storage.nix`, `users.nix`, `security.nix`, `tailscale.nix`. (2026-06-02 —
      `users.nix` uses the real operator key `id_ed25519`; secrets file created with a placeholder
      Tailscale key encrypted to host age key `age1rc26869…`.)
- [x] Run `nix flake lock` inside `nixos/`; commit `nixos/flake.lock`. (2026-06-02 — nixpkgs
      `331800d` / 26.11 line, sops-nix `c591bf6`.)
- [x] Build via the remote builder: `cd nixos && nix build .#packages.x86_64-linux.nagare-image`.
      The original `tan-nb-exp` run built the 891 MiB image recorded in Outcomes. A second released
      run through `nagare host-image` built the labs image on the same remote builder and uploaded a
      921 MiB tarball on 2026-09-13. (Reconciled 2026-09-15.)

Milestone 2: builder provisioned; image uploaded, registered, and wired into Pulumi config.

- [x] Author `scripts/nix-builder-startup.sh.tpl` (copied verbatim from the reference repo).
      (2026-06-02)
- [x] Author `scripts/setup-nix-builder.sh` (IP-9 preflight; provisions `nix-builder-x86`). (2026-06-02
      — copied verbatim from the reference repo.)
- [x] Author `scripts/iap-ssh.sh` (IAP-tunneled ssh/scp wrapper, copied verbatim). (2026-06-02)
- [x] Author `scripts/upload-images.sh` (build `nagare-image`, upload, register, write
      `nagareImageSelfLink`). (2026-06-02 — Nagare-specific single-image adaptation.)
- [x] Run `scripts/setup-nix-builder.sh`; confirm the builder VM exists and is stopped. The existing
      `tan-nb-exp` builder performed both image builds and auto-stopped after the labs build; the
      labs rollout recorded it TERMINATED at 02:52:30Z on 2026-09-13. (Reconciled 2026-09-15.)
- [x] Configure the host-side builder SSH wiring. The successful original and labs remote builds
      exercise the `/etc/nix/machines`, builder key, and SSH-host wiring end to end. (Reconciled
      2026-09-15.)
- [x] Run the image upload pipeline and confirm `nagareImageSelfLink`. The original run registered
      `nagare-image-bamf7v4ym3si` in `tan-nb-exp`; the independent labs run registered READY image
      `nagare-image-f9p6raz75qjf` and wrote
      `https://www.googleapis.com/compute/v1/projects/tan-ng-labs/global/images/nagare-image-f9p6raz75qjf`
      into the context-owned stack config. (Reconciled 2026-09-15.)

Milestone 3: deploy and verify the running host and cluster.

- [x] After EP-2's `pulumi up` boots `nagare-01`, SSH in. (2026-06-02 — EP-2 M3 `pulumi up` created the
      instance booting from `nagare-image-bamf7v4ym3si`; reached IAP-SSH as `deploy` with the operator
      key, auth confirmed "Server accepts key". Tailscale left unjoined per the IAP-SSH-only choice
      —`tailscaled-autoconnect` fails on the placeholder key, which is expected and non-fatal.)
- [x] `kubectl get nodes -o wide` reports the node `Ready`. CONFIRMED live (2026-06-02) after the
      sshd blocker was resolved (disable PerSourcePenalties + OS Login; public DNS resolvers) and the
      image was rebuilt (`nagare-image-s04l9dg8rc01`): node `nagare-01` Ready, k3s `v1.35.4+k3s1`,
      NixOS 26.11; coredns/local-path-provisioner/metrics-server all `1/1 Running`.
- [x] `mount | grep nagare` shows the data disk mounted at `/var/lib/nagare`; the seven
      subdirectories exist. CONFIRMED — the post-mount subdir oneshot creates all seven after the
      (auto-formatted) disk mounts. (2026-06-02)
- [x] `stat -c '%a' /etc/rancher/k3s/k3s.yaml` reports `644`. Set by `--write-kubeconfig-mode=0644`;
      the kubeconfig was readable and copied off the host for cluster access. (2026-06-02)
- [x] Apply a test PVC; it binds and its hostPath lives under `/var/lib/nagare/local-path`. CONFIRMED
      live — a test PVC reached `Bound` with its backing dir at `/var/lib/nagare/local-path/pvc-…`.
      (2026-06-02)
- [-] Exercise the day-2 path: edit a trivial setting and run
      `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo`. DEFERRED operator
      follow-up: requires Tailscale (real auth key) or direct SSH as `deploy`; non-blocking for
      EP-4/5/6, which reach the cluster via an SSH local-forward to the apiserver (see MasterPlan
      Surprises 2026-06-02). Closed (2026-10-17): direct `nixos-rebuild switch` is no longer allowed; host
      changes go only through `just host-switch` ([ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)),
      whose day-2 upgrades are proven in [checklist §3](../releases/production-readiness-checklist.md). {disposition=out-of-scope}

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence (command output is ideal).

- Discovery: the plan's `nixos/flake.nix` placed the upstream GCE module
  (`google-compute-image.nix`) only inside `mkImage`, leaving
  `nixosConfigurations.nagare-01` (the day-2 `nixos-rebuild` target) without it. That target then
  fails to evaluate. Evidence — `nix eval --raw .#nixosConfigurations.nagare-01.config.system.build.toplevel.drvPath`:
  `Failed assertions: - The 'fileSystems' option does not specify your root file system. - You must
  set the option 'boot.loader.grub.devices' ...`. The GCE module is what supplies the root fs and grub
  config (via `google-compute-config.nix`), so without it the rebuild target is not bootable — directly
  contradicting the plan's claim that the image and rebuild target are identical. The reference repo
  only ever builds images (no `nixosConfigurations`), so it never hit this. Resolution: move the GCE
  module into the shared `nagare01Modules` list so both the image and `nixosConfigurations.nagare-01`
  are built from the identical, bootable module set (`mkSystem`). Both now evaluate: image drvPath
  unchanged at `…-google-compute-image.drv`; the day-2 target resolves to
  `…-nixos-system-nagare-01-google-compute-26.11….drv`.

- Discovery: the resolved `nixos-unstable` is the **26.11** release line (`nixos-system-…-26.11…`),
  not 26.05. `configuration-base.nix` pins `system.stateVersion = "26.05"`, which is still valid
  (stateVersion is intentionally a fixed lower bound, not the running release), so this is left as-is;
  noted so a future reader is not surprised by the version skew.

- Discovery: **k3s did not start on first boot** — the serial console showed `Dependency failed for
  k3s service`. Root cause: `k3s.nix` makes k3s `requires`/`after` the `var-lib-nagare.mount`, but EP-2
  attaches a **blank, unformatted** persistent disk, so the ext4 mount of
  `/dev/disk/by-id/google-nagare-data` fails (the `nofail` option lets boot continue but the mount unit
  still fails, and k3s's hard `requires` on it then fails). The plan's Idempotence section anticipated a
  one-time manual `mkfs.ext4`. Resolution: added a `format-nagare-data` systemd oneshot to `storage.nix`
  that runs `mkfs.ext4 -F` on the disk **iff** `blkid` finds no filesystem, ordered `before`/`wantedBy`
  the mount — so a clean first boot self-heals and k3s starts without manual intervention. (The already-
  running `nagare-01` was built from the pre-fix image, so it still needs a one-time manual format until
  the image is rebuilt.)

- Discovery: reaching `nagare-01` over IAP-SSH was repeatedly blocked by two self-inflicted issues.
  (1) **OpenSSH `PerSourcePenalties`** (default-on in current NixOS sshd): rapid aborted/failed SSH
  attempts accrue a source-IP penalty that makes sshd close new connections, and each further failed
  retry *extends* it — manifesting as `kex_exchange_identification: Connection closed by remote host`.
  A VM `reset` clears the in-memory penalty state. (2) **IAP tunnel throttling**: creating many
  `start-iap-tunnel` processes in quick succession causes the IAP WebSocket connect to time out
  (`ConnectionCreationError: [Errno 60] Operation timed out`) / hang at "Testing if tunnel connection
  works"; it clears after a few minutes of no attempts. Lesson: make at most one IAP-SSH attempt at a
  time and wait between attempts; do not loop.

- Discovery (UNRESOLVED, M3 blocker): after the initial two successful IAP-SSH sessions on the first
  boot (KEX + "Server accepts key" confirmed), **every subsequent SSH connection — via IAP tunnel and
  via direct public IP, as the `deploy` user with the correct key — is closed by the server at the
  start of userauth** (`debug1: Authenticating to … as 'deploy'` → `Connection closed`). This persists
  even on a freshly-reset VM's very first connection, which rules out accumulated OpenSSH
  `PerSourcePenalties` as the sole cause. Remote diagnosis was thwarted on three channels: (a) SSH
  itself is the thing failing; (b) on this NixOS GCE image the google-guest-agent runs the metadata
  `startup-script` but routes its stdout to journald, **not** the serial console, so a startup-script
  cannot surface output via `get-serial-port-output`; (c) a startup-script that uploads its output to
  GCS via a metadata access token never produced an object (the upload step did not complete —
  possibly killed by a google-startup-scripts timeout, or a PATH/token issue in that restricted
  environment). The data disk **did** get formatted by an early startup-script run (confirmed by a
  later boot's `systemd-fsck` on `google-nagare-data` succeeding), proving startup-scripts execute.
  Net effect: the cluster could not be smoke-tested live. Most likely root causes to check next, with a
  working shell (e.g. GCP **interactive serial console** login, which needs a local user password set
  via a startup-script, or a rebuilt image): the OS Login `AuthorizedKeysCommand` failing/hanging
  during userauth, or `PerSourcePenalties` (set `services.openssh.settings.PerSourcePenalties = "no"`
  to test). The infra is otherwise in place; this is a host-access/observability problem, not a
  Pulumi/Nix/k3s-config defect.

- Discovery: `scripts/iap-ssh.sh` does not pass `-o IdentitiesOnly=yes`, so on a workstation whose
  ssh-agent holds several keys it offers them all and trips the host's `MaxAuthTries` before reaching
  `~/.ssh/id_ed25519` — surfacing as a generic `rc=255` that iap-ssh then misclassifies as a transient
  tunnel failure and retries. Direct `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519` authenticates
  cleanly ("Server accepts key"). Worth adding `IdentitiesOnly=yes` (and an `-i` honoring `SSH_KEY`
  ahead of agent keys) to the reference `iap-ssh.sh`.

- Discovery (operator inputs already present): the workstation already has the operator SSH key
  `~/.ssh/id_ed25519.pub` (used in `users.nix`), the Nix remote builder is already wired
  (`/etc/nix/machines` registers `builder@nix-gcp-builder`; `/etc/nix/builder_ed25519` exists; the SSH
  host is resolved by the nix-darwin-managed `/etc/ssh/ssh_config.d/200-nix-gcp-builder.conf` whose
  ProxyCommand opens the IAP tunnel on demand), and the builder VM `nix-builder-x86` already exists in
  `tan-nb-exp` (TERMINATED). So `scripts/setup-nix-builder.sh` is a no-op here and the host-side build
  wiring in the plan's Step 8 is already satisfied by the reference-repo setup.

- **FOLLOW-UP (open): the registered GCE image does not contain the `networking.nix` DNS fix, so a
  clean rebuild boots with broken DNS.** Discovered 2026-06-03 when EP-5 rebuilt the VM (to enlarge the
  boot disk to 100 GB) and the fresh instance booted from `nagareImageSelfLink` with
  `/etc/resolv.conf` pointing at the unreachable metadata resolver `169.254.169.254`. Evidence on the
  booted host: `grep nohook /etc/dhcpcd.conf` → absent; no `/etc/static/resolv.conf`. Effect:
  containerd could not pull non-airgap images (`Temporary failure in name resolution`) and coredns
  (`forward . /etc/resolv.conf`) inherited the broken upstream, so in-cluster external DNS also failed
  (cert-manager's `letsencrypt-dns` issuer reported `acme-v02... server misbehaving`). The
  `nixos/hosts/nagare-01/networking.nix` **source is correct** (it sets `networking.nameservers =
  [8.8.8.8 8.8.4.4]` and `networking.dhcpcd.extraConfig = "nohook resolv.conf"`); the registered image
  was evidently built before that file was git-tracked (cf. EP-1's flake/git-tracked-files surprise),
  and the earlier live-verified VM had the fix applied via a day-2 `nixos-rebuild`, which is why EP-4
  worked there but a fresh rebuild from the image did not. Live workaround applied (not reboot-safe):
  static `8.8.8.8/8.8.4.4` `/etc/resolv.conf`, `chattr +i` to keep dhcpcd from overwriting it, and
  `kubectl -n kube-system rollout restart deploy/coredns`. **Durable fix: rebuild + re-register the
  image with `just host-image` (which runs `scripts/upload-images.sh`), confirm the new image's
  `/etc/dhcpcd.conf` has `nohook resolv.conf` and `/etc/resolv.conf` shows `8.8.8.8` on a clean boot,
  then drop the manual `chattr +i`.** Until then the running host's DNS survives only until reboot, and
  a `pulumi`-driven VM replacement reintroduces the break. (2026-06-03)
  **UPDATE (2026-06-03):** the image was rebuilt and re-registered with `just host-image`
  (`nagareImageSelfLink` updated). It now contains the `networking.nix` DNS fix **and** the
  metadata-routing fix below. The running VM still carries the runtime workarounds; verify a fully
  clean boot (and drop the workarounds) on the next VM replacement onto the new image.

- **FOLLOW-UP (fixed in source + image; clean-boot verification pending): pods could not reach the
  GCE metadata server, breaking keyless ADC.** Discovered 2026-06-03 while bringing up EP-7's
  Litestream backup. dhcpcd assigned IPv4 link-local `169.254.0.0/16` addresses to the flannel/veth
  interfaces; the resulting on-link route hijacked `169.254.169.254` onto `flannel.1`
  (`ip route get 169.254.169.254 → dev flannel.1 src 169.254.x.x`) instead of eth0 to the real
  metadata server, so neither host nor pods could reach it. Effect: in-cluster GCP auth via
  Application Default Credentials fails — Litestream backups (EP-7) and cert-manager's DNS-01 wildcard
  TLS (EP-4) both need it. Fix added to `networking.nix`:
  `networking.dhcpcd.denyInterfaces = [ "veth*" "flannel*" "cni*" "kube*" "datapath*" ]` (removes the
  /16 hijack, leaving the GCE `/32` metadata route on eth0) plus a `firewall.extraCommands`
  MASQUERADE for pod → `169.254.169.254` (SNAT to the node IP). Validated at runtime before baking: a
  pod read `nagare-node@tan-nb-exp.iam.gserviceaccount.com` from the metadata server and Litestream
  replicated to GCS. GCP-using pods should also set `GCE_METADATA_HOST=169.254.169.254` so the Go
  metadata library skips the pod-unresolvable `metadata.google.internal` hostname. Baked into the
  rebuilt image; confirm on the next clean boot that `ip route get 169.254.169.254` uses eth0.
  (2026-06-03)

- Audit discovery (2026-09-15): the Progress section still described the remote build and upload
  as deferred even though this plan's own Outcomes recorded their successful original execution.
  The independent labs rollout (`mori://tan/tan-infrastructure/docs/nagare-labs-domain-delegation`)
  repeated the complete released `nagare host-image` path, so those stale partial markers are now
  reconciled. Only the explicit day-2 `nixos-rebuild switch` demonstration remains open.

## Decision Log

Record every decision made while working on the plan.

- Decision: Keep k3s's built-in ServiceLB (Klipper) enabled; only disable Traefik.
  Rationale: Kourier's gateway Service (installed by EP-4) is `type: LoadBalancer` by default.
  On a self-managed single-node k3s, the only controller that satisfies a LoadBalancer Service
  is ServiceLB, which binds the node's host ports 80/443 directly to that Service. Disabling
  ServiceLB (as the original spec suggested) would leave Kourier with no external IP and no
  way to receive HTTP/HTTPS. This overrides the spec's `--disable=servicelb`; recorded in the
  spec appendix and the MasterPlan Decision Log.
  Date: 2026-06-02

- Decision: Point k3s's local-path-provisioner at the data disk using the durable server flag
  `--default-local-storage-path=/var/lib/nagare/local-path`, not by editing the
  `local-path-config` ConfigMap.
  Rationale: k3s re-applies its bundled manifests (including the `local-path-config` ConfigMap)
  on every restart, so an edited ConfigMap is silently reverted. The server flag is part of the
  k3s configuration and survives restarts. This is the IP-3 contract and a spec correction.
  Date: 2026-06-02

- Decision: Build the GCE image on an on-demand x86_64-linux Nix remote builder in GCP, upload
  the tarball to GCS, register it as a GCE image, and write its self-link into Pulumi config;
  use `nixos-rebuild switch --target-host` over Tailscale for day-2 changes.
  Rationale: The workstation is `aarch64-darwin` and cannot natively build `x86_64-linux` GCE
  images. This is the established `load-testing-infra` pattern (`setup-nix-builder.sh` +
  `upload-images.sh`). The baked image gives a clean first boot; `nixos-rebuild` keeps later
  changes fast. This is IP-10.
  Date: 2026-06-02

- Decision: Use sops-nix for exactly one host secret in this plan — the Tailscale auth key —
  with the `age` key on the host; defer broader secret management to EP-7.
  Rationale: `nagare-01` must join the tailnet headlessly on first boot, which needs an auth
  key that cannot be committed in plaintext. sops-nix decrypts it at activation. Keeping the
  scope to one secret avoids entangling this plan with EP-7's full secrets/backup design.
  Date: 2026-06-02

- Decision: Add a non-root `deploy` user with passwordless sudo and SSH key auth; harden sshd
  to key-only, no root login.
  Rationale: Day-2 rebuilds use `nixos-rebuild switch --target-host nagare-01 --sudo`, which
  SSHes in as a non-root user and escalates via sudo to activate the new system. That requires
  a non-root user with NOPASSWD sudo and the operator's public key. Root SSH and password auth
  are disabled to reduce the attack surface on the box even though it is reachable mainly over
  Tailscale.
  Date: 2026-06-02

- Decision: Include the upstream GCE module (`google-compute-image.nix`) in the **shared**
  `nagare01Modules` list so both `packages.x86_64-linux.nagare-image` and
  `nixosConfigurations.nagare-01` are built from it, rather than adding it only in `mkImage` as the
  plan's Step 2 wrote.
  Rationale: `nixosConfigurations.nagare-01` (the day-2 `nixos-rebuild --target-host` target) must have
  a root filesystem and bootloader to evaluate and to be bootable; those come from the GCE module. With
  the module image-only, the day-2 target failed assertions (see Surprises). Sharing the module makes
  the plan's "image and rebuild target are identical" guarantee literally true. The extra
  `system.build.image` output on the rebuild target is unused and harmless.
  Date: 2026-06-02

- Decision: Use the existing operator key `~/.ssh/id_ed25519.pub`
  (`ssh-ed25519 AAAA…JZ7R shinzui@sungkyung`) as the `deploy` user's authorized key, and reuse the
  reference repo's already-provisioned Nix builder (`nix-builder-x86`) and host build wiring rather
  than re-provisioning.
  Rationale: The workstation already has this key and a working builder (see Surprises); fabricating a
  new key would lock the operator out, and re-provisioning the builder is unnecessary
  (`setup-nix-builder.sh` is idempotent and would no-op). If the operator prefers a different deploy
  key, replace the one line in `hosts/nagare-01/users.nix` and rebuild.
  Date: 2026-06-02

- Decision: Auto-format the blank data disk on first boot via a `format-nagare-data` systemd oneshot in
  `storage.nix`, rather than relying on the plan's manual `mkfs.ext4` recovery step.
  Rationale: EP-2 attaches an unformatted disk; without a filesystem the `/var/lib/nagare` mount fails
  and k3s (which `requires` the mount) never starts — observed on the first `nagare-01` boot
  (`Dependency failed for k3s service`). A guarded `mkfs.ext4 -F` (only when `blkid` finds no
  filesystem), ordered before the mount, makes a clean first boot self-healing and idempotent (existing
  data is never reformatted). This keeps the "rebuild from Git is boring" guarantee — no manual step on
  a fresh disk. Recorded as a spec/plan correction.
  Date: 2026-06-02

- Decision: Commit the sops secrets file with a clearly-marked PLACEHOLDER Tailscale auth key
  (`tskey-auth-PLACEHOLDER-REPLACE-BEFORE-DEPLOY`), encrypted to a freshly generated host age key
  (public `age1rc26869…`; private key stored locally at `~/.config/nagare/nagare-01-age-key.txt`, never
  committed).
  Rationale: The flake cannot evaluate without the sops file present, but a real Tailscale pre-auth key
  is an external secret only the operator can mint (Tailscale admin console). The placeholder lets the
  config be validated and committed now; it must be replaced (re-encrypt the file, redeploy) before the
  host can join the tailnet. The host still boots and k3s still runs without it — Tailscale join is the
  only affected behavior.
  Date: 2026-06-02

- Decision: use the successful original build recorded in Outcomes, corroborated by the later labs
  rollout, to close the stale M1/M2 execution markers.
  Rationale: both executions used the remote x86 builder, uploaded the resulting GCE archive,
  registered a READY image, and projected its self-link into Pulumi. Keeping those items partial
  contradicted the plan's own outcome and hid the sole remaining operator follow-up.
  Date: 2026-09-15

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original purpose.

Status (2026-06-02, updated): **Milestones 1, 2, and 3 are complete and the cluster is verified live.**
The earlier sshd host-access blocker (every post-KEX SSH session closed at userauth) was resolved by
disabling OpenSSH `PerSourcePenalties` and Google OS Login in the host config and rebaking the image
(`nagare-image-s04l9dg8rc01`); a companion fix set public DNS resolvers so k3s could pull its images.
With a working shell, M3 was smoke-tested: node `Ready` (k3s v1.35.4, NixOS 26.11), the core
kube-system pods Running, and a test PVC `Bound` under `/var/lib/nagare/local-path`. Two finishing
items remain as operator follow-ups and do **not** block downstream plans: joining Tailscale with a
real pre-auth key (the committed key is a placeholder), and a demonstration run of the day-2
`nixos-rebuild --target-host` path. Concretely:

- M1 ✅ — The NixOS configuration for `nagare-01` is authored and validated: both
  `packages.x86_64-linux.nagare-image` and the day-2 `nixosConfigurations.nagare-01` evaluate, and the
  GCE image **built on the remote x86_64-linux builder** (a real `*.raw.tar.gz`, 891 MiB).
- M2 ✅ — `scripts/upload-images.sh` uploaded the image to `gs://tan-nb-exp-nagare-images`, registered
  GCE image `nagare-image-bamf7v4ym3si` (STATUS: READY), and set Pulumi config `nagareImageSelfLink`.
  EP-2's `pulumi up` then created `nagare-01`, which boots from that image (serial console reaches
  "Reached target Multi-User System").
- M3 ✅ — `nagare-01` is RUNNING the rebuilt image and the cluster is healthy: `kubectl get nodes`
  reports `Ready`; coredns, local-path-provisioner, and metrics-server are `1/1 Running`; the data
  disk is mounted at `/var/lib/nagare` with all seven subdirectories; the kubeconfig is mode `0644`;
  and a test PVC `Bound` under `/var/lib/nagare/local-path` proves `--default-local-storage-path` took
  effect. The `storage.nix` auto-format + post-mount-subdir fixes mean a freshly rebuilt image mounts
  the disk and starts k3s on first boot with no manual step.

Remaining operator follow-ups (non-blocking for EP-4/5/6): replace the placeholder Tailscale auth key
(re-encrypt the secrets file, redeploy, restart `tailscaled`) so the node joins the tailnet, and
exercise the day-2 `nixos-rebuild --target-host` path once SSH-as-`deploy`/Tailscale access is in
place. Downstream cluster-touching plans reach the apiserver in the meantime via an SSH local-forward
over the port-22 IAP path (`ssh -L 6443:127.0.0.1:6443 -N deploy@nagare-01`).

