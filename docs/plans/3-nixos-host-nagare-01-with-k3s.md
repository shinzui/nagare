---
id: 3
slug: nixos-host-nagare-01-with-k3s
title: "NixOS host nagare-01 with k3s"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# NixOS host nagare-01 with k3s

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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
- [~] Build via the remote builder: `cd nixos && nix build .#packages.x86_64-linux.nagare-image`.
      Config fully validated by evaluation (`nix eval` of both the image and the day-2 toplevel
      derivations succeeds); the actual remote-builder build is deferred to the user checkpoint
      (folded into M2's pipeline run). Record store path + size when built.

Milestone 2: builder provisioned; image uploaded, registered, and wired into Pulumi config.

- [x] Author `scripts/nix-builder-startup.sh.tpl` (copied verbatim from the reference repo).
      (2026-06-02)
- [x] Author `scripts/setup-nix-builder.sh` (IP-9 preflight; provisions `nix-builder-x86`). (2026-06-02
      — copied verbatim from the reference repo.)
- [x] Author `scripts/iap-ssh.sh` (IAP-tunneled ssh/scp wrapper, copied verbatim). (2026-06-02)
- [x] Author `scripts/upload-images.sh` (build `nagare-image`, upload, register, write
      `nagareImageSelfLink`). (2026-06-02 — Nagare-specific single-image adaptation.)
- [~] Run `scripts/setup-nix-builder.sh`; confirm the builder VM exists and is stopped. Already
      satisfied: `nix-builder-x86` exists in `tan-nb-exp` (TERMINATED) from the reference-repo setup;
      the script is idempotent and would no-op.
- [~] Configure the host-side builder SSH wiring. Already satisfied: `/etc/nix/machines` registers
      `builder@nix-gcp-builder`, `/etc/nix/builder_ed25519` exists, and the SSH host resolves via
      `/etc/ssh/ssh_config.d/200-nix-gcp-builder.conf` (nix-darwin managed). Deferred verification
      (`nix store info`) to the build checkpoint.
- [ ] Run `scripts/upload-images.sh`; confirm `pulumi config get nagareImageSelfLink` returns
      a `https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/images/...` URL. (Deferred to
      the user checkpoint — runs the remote-builder build + upload.)

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
- [ ] Exercise the day-2 path: edit a trivial setting and run
      `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo`. DEFERRED operator
      follow-up: requires Tailscale (real auth key) or direct SSH as `deploy`; non-blocking for
      EP-4/5/6, which reach the cluster via an SSH local-forward to the apiserver (see MasterPlan
      Surprises 2026-06-02).


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


## Context and Orientation

This plan assumes the reader has only this repository's working tree and this file. It does
not assume any prior plan has been read, though it references two sibling plans by path where
they own an interface this plan consumes.

The repository root is `/Users/shinzui/Keikaku/bokuno/nagare`. At the time this plan is
written, the repo contains the MasterPlan at
`docs/masterplans/1-bootstrap-nagare-personal-paas.md`, the original specification at
`docs/initial-spec.md` (whose "Spec Accuracy Corrections" appendix at the end overrides the
prose above it), and the skeleton child plans under `docs/plans/`. There is no `nixos/`
directory and no `scripts/` directory yet; this plan creates them.

The developer workstation is `aarch64-darwin` (Apple Silicon macOS). It cannot build
`x86_64-linux` artifacts natively. All GCP work targets project **`tan-nb-exp`**, region
**`us-west1`**, zone **`us-west1-a`** — the hard isolation policy from the MasterPlan
Integration Point 9. Every shell script under `scripts/` must include a preflight assertion
that refuses to run unless gcloud's active project equals `tan-nb-exp`, and must pass
`--project=tan-nb-exp` explicitly on every `gcloud`/`gsutil` call.

This plan is the canonical adaptation of the sibling reference repository
`/Users/shinzui/Keikaku/bokuno/load-testing-infra`, which solves the identical
aarch64-darwin-cannot-build-Linux-images problem. The reference files this plan adapts are
`nixos/flake.nix`, `nixos/configuration-base.nix`, `nixos/modules/gcp.nix`,
`scripts/setup-nix-builder.sh`, `scripts/nix-builder-startup.sh.tpl`, `scripts/iap-ssh.sh`,
and `scripts/upload-images.sh`. The reference repo's foundation ExecPlan documents the
discoveries that shaped that pipeline (most importantly: the macOS OpenSSH 10.x kex-handshake
bug in `gcloud compute ssh --tunnel-through-iap`, worked around with
`start-iap-tunnel --local-host-port` + `socat`; and that the image output is a *directory*
containing `*.raw.tar.gz`, not a symlink to a file). This plan re-states those findings so it
stands alone.

### Interfaces this plan depends on (from sibling plans)

EP-2's Pulumi project (`docs/plans/2-pulumi-gcp-infrastructure.md`) owns the cloud resources.
This plan consumes the following from EP-2, by name, never by hard-coded value:

- The Pulumi **config** key `nagareImageSelfLink` (a config value, not a stack output): this
  plan *writes* it via `scripts/upload-images.sh`; EP-2's instance component reads it to pick
  the boot image. This is the producer side of MasterPlan Integration Point 1 and 10.
- The Pulumi config key `imageBucket`: EP-2 sets the name of the GCS bucket that staged GCE
  image tarballs are uploaded to. `scripts/upload-images.sh` reads it with
  `pulumi config get imageBucket` (creating the bucket if missing, idempotently).
- The stack output `dataDiskName`: the name of the persistent data disk EP-2 attaches to the
  instance. This plan's `storage.nix` mounts it. GCP exposes an attached persistent disk to
  the guest at the stable path `/dev/disk/by-id/google-<deviceName>`, where `<deviceName>` is
  the device name EP-2 assigns when attaching the disk (it sets the device name equal to
  `dataDiskName`; if EP-2 ever decouples them, this plan reads whichever value EP-2 documents
  as the attached device name). The placeholder used in this plan is `nagare-data`; the
  reader must confirm the real value with `pulumi stack output dataDiskName` and the device
  name EP-2 records, then substitute it in `storage.nix`.
- The stack output `instanceName` (`nagare-01`) and `publicIp`: used for SSH/verification.

EP-1's dev shell (`docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md`)
provides the tools the commands here run: `gcloud`/`gsutil`, `pulumi`, `kubectl`, `sops`,
`age`, `tailscale`, `socat`, `jq`, `nix`. If you are not in `nix develop`, install equivalents
or enter the shell first. This plan re-states the specific tools each step needs so it remains
runnable on its own.

### Files this plan creates, by full repository-relative path

- `nixos/flake.nix` — the flake: inputs `nixpkgs` and `sops-nix`, a `mkImage` helper, and the
  output `packages.x86_64-linux.nagare-image`.
- `nixos/flake.lock` — generated by `nix flake lock`; pins the inputs.
- `nixos/configuration-base.nix` — shared base configuration imported into every image.
- `nixos/modules/gcp.nix` — the GCE-compatibility module (sshd, sysctls, journald, etc.).
- `nixos/hosts/nagare-01/configuration.nix` — the host aggregator that imports the other host
  files and sops-nix.
- `nixos/hosts/nagare-01/k3s.nix` — the k3s service configuration.
- `nixos/hosts/nagare-01/networking.nix` — hostname and firewall.
- `nixos/hosts/nagare-01/storage.nix` — data-disk mount and the `/var/lib/nagare` subdir layout.
- `nixos/hosts/nagare-01/users.nix` — the `deploy` user and SSH keys.
- `nixos/hosts/nagare-01/security.nix` — sshd hardening and sudo.
- `nixos/hosts/nagare-01/tailscale.nix` — Tailscale with a sops-managed auth key.
- `scripts/setup-nix-builder.sh` — provisions the on-demand x86_64-linux Nix builder VM.
- `scripts/nix-builder-startup.sh.tpl` — the builder VM's first-boot startup script template.
- `scripts/iap-ssh.sh` — IAP-tunneled ssh/scp wrapper (macOS-safe).
- `scripts/upload-images.sh` — builds, uploads, registers the image, writes Pulumi config.


## Plan of Work

The work proceeds in three milestones. Milestone 1 produces a buildable NixOS GCE image for
`nagare-01` (the configuration is complete, but nothing is on GCP yet). Milestone 2 stands up
the build/upload pipeline so the image lands in GCS, is registered, and its self-link reaches
Pulumi config. Milestone 3 deploys (via EP-2) and verifies the running host and cluster, then
demonstrates the day-2 rebuild path. Each milestone ends in a behavior a human can observe.

### Milestone 1: NixOS configuration + `mkImage` + a buildable `nagare-image`

Scope: author the flake, the shared base, the GCE module, and the seven host files, then
build the image on the remote builder. At the end, `nix build .#packages.x86_64-linux.nagare-image`
from inside `nixos/` produces a store path containing one `*.raw.tar.gz`.

The flake (`nixos/flake.nix`) declares two inputs. `nixpkgs` is pinned to `nixos-unstable`
(the GCE image module and the guest agent track unstable closely; the box is rebuildable so
the marginal stability risk is acceptable). `sops-nix` is the secret-decryption integration.
The flake defines `mkImage`, a helper that composes the upstream GCE module
`${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix` with `configuration-base.nix`
and a list of caller-supplied modules, then exposes the resulting NixOS system's
`config.system.build.image` derivation (the directory containing the `*.raw.tar.gz`). This is
exactly the reference repo's pattern; copying it keeps the two repos consistent. The flake
also exposes a `nixosConfigurations.nagare-01` attribute (the same composed system, but as a
configuration rather than an image) so that `nixos-rebuild --flake .#nagare-01` works for the
day-2 path in Milestone 3 — the image and the rebuild target are the *same* configuration, so
the box never drifts from what was baked.

The single image output is `packages.x86_64-linux.nagare-image`. The reader must build it by
its **full attribute path** (`nix build .#packages.x86_64-linux.nagare-image`), not the
shorthand `.#nagare-image`. On `aarch64-darwin`, Nix resolves the shorthand to
`packages.aarch64-darwin.nagare-image`, which does not exist; addressing the
`x86_64-linux` attribute explicitly is what makes Nix dispatch the build to the registered
remote `x86_64-linux` builder. This subtlety is exactly why the reference repo's
`upload-images.sh` always builds `packages.x86_64-linux.<name>`.

`configuration-base.nix` carries the shared ground every Nagare image needs: it imports
`modules/gcp.nix` and sets `services.gcp.enable = true;` (which turns on the GCE-friendly sshd
hardening, sysctls, chrony time sync, and journald retention), sets base packages, sets nix
settings (flakes enabled, the operator as a trusted user), and pins `system.stateVersion`.

`modules/gcp.nix` is adapted from the reference repo. The upstream
`google-compute-image.nix` (and the `google-compute-config.nix` it imports transitively)
already enables `services.openssh`, `security.googleOsLogin.enable`, the
`google-guest-agent` systemd unit, sets the firewall to a permissive default, and points
timeservers at the metadata server — so this module must *not* re-declare
`services.google-guest-agent.enable` (that option does not exist at the pinned nixpkgs and
declaring it errors; see the reference repo's Surprises). The module only tightens sshd
(`PermitRootLogin = "no"`, `PasswordAuthentication = false`), enables chrony, sets baseline
sysctls, caps journald, and optionally adds a break-glass user.

The seven host files compose the role of `nagare-01`:

- `k3s.nix` enables k3s as a single-node server with the corrected flags (see Concrete Steps).
- `networking.nix` sets the hostname to `nagare-01` and opens firewall TCP ports 22, 80, 443.
- `storage.nix` mounts the attached data disk at `/var/lib/nagare` and creates the seven
  subdirectories via `systemd.tmpfiles.rules`.
- `users.nix` creates the `deploy` user with the operator's SSH key and wheel/sudo membership.
- `security.nix` hardens sshd and configures passwordless sudo for the rebuild path.
- `tailscale.nix` enables Tailscale and joins the tailnet from a sops-managed auth key.
- `configuration.nix` imports the six files above plus the sops-nix NixOS module, and declares
  the sops secret for the Tailscale auth key.

Acceptance: `cd nixos && nix build .#packages.x86_64-linux.nagare-image` exits 0; the printed
store path is a directory; `find <store-path> -maxdepth 1 -name '*.raw.tar.gz'` lists exactly
one file on the order of 700 MiB–1.5 GiB.

### Milestone 2: build pipeline — provision builder, upload, register, wire Pulumi config

Scope: author the four scripts and run them. At the end, the image is in GCS, registered as a
GCE image, and `pulumi config get nagareImageSelfLink` returns the image self-link.

`scripts/nix-builder-startup.sh.tpl` and `scripts/setup-nix-builder.sh` are copied essentially
verbatim from the reference repo. `setup-nix-builder.sh` enables the compute/IAP/storage APIs,
creates an isolated VPC + subnet + IAP-only SSH firewall rule, renders the startup template
with the host's builder public key, creates an Ubuntu 24.04 `n2-standard-2` VM with nested
virtualization enabled, waits for the startup script to finish (probing the SSH banner over an
IAP tunnel — never `gcloud compute ssh --tunnel-through-iap`, which is broken on macOS OpenSSH
10.x), then stops the VM so it costs only its boot disk while idle. It is idempotent: re-running
only creates missing resources. All `gcloud` calls carry `--project=tan-nb-exp` and the script
opens with the IP-9 preflight assertion.

`scripts/iap-ssh.sh` is copied verbatim — it is the macOS-safe ssh/scp wrapper that opens an
IAP tunnel with `gcloud compute start-iap-tunnel --local-host-port` and routes OpenSSH through
`socat` as the `ProxyCommand`, with transient-failure retries. `upload-images.sh` uses it to
upload large tarballs builder→GCS directly (avoiding a multi-GB round-trip over the IAP-SSH
copy-back, which has been observed to drop on big closures).

`scripts/upload-images.sh` is adapted from the reference repo but simplified: Nagare has a
single image (`nagare-image`), so there is no dynamic driver-image discovery. The script reads
`imageBucket` from Pulumi config (creating the bucket if missing), builds
`packages.x86_64-linux.nagare-image` by full attribute path (so the remote builder is used),
locates the `*.raw.tar.gz` inside the result (globbing locally, or on the builder if the
local copy-back was skipped), uploads it under a content-addressed name
`nagare-image-<sha-prefix>.raw.tar.gz`, registers a GCE image of the same name if not already
present, reads the registered image's self-link, and runs
`pulumi config set nagareImageSelfLink <self-link>`. It is idempotent: existing GCS objects and
registered images are reused.

Before the first build dispatches to the remote builder, the host's Nix must know about that
builder. The reference repo wires this in a dotfiles module; here we document the minimal
manual equivalent (an `/etc/nix/machines` builder line plus an SSH `Host nix-gcp-builder` block
whose `ProxyCommand` opens the IAP tunnel). See Concrete Steps Step 8.

Acceptance: `scripts/setup-nix-builder.sh` finishes and the VM is `TERMINATED` (stopped);
`scripts/upload-images.sh` finishes and `pulumi --cwd infra/pulumi config get nagareImageSelfLink`
prints a URL of the form
`https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/images/nagare-image-<hash>`.

### Milestone 3: deploy and verify the host and cluster; demonstrate day-2 rebuild

Scope: after EP-2 boots `nagare-01` from the registered image, verify the running system, then
demonstrate the `nixos-rebuild --target-host` day-2 path.

This milestone has a hard prerequisite outside this plan: EP-2 must have run `pulumi up` (which
reads `nagareImageSelfLink`, the config key Milestone 2 wrote) and produced a running
`nagare-01` with the data disk attached. The operator reaches the box first over IAP-SSH (using
`scripts/iap-ssh.sh ssh nagare-01 -- ...`), and once Tailscale is up, by the Tailscale name
`nagare-01`. The verifications: the k3s node is `Ready`; the data disk is mounted with the
seven subdirectories; the kubeconfig is mode `0644`; and a test PVC binds under
`/var/lib/nagare/local-path` (proving `--default-local-storage-path` took effect). Finally,
edit a trivial setting and run the day-2 rebuild over Tailscale to prove the box stays in sync
with the flake without rebaking an image.

Acceptance: the exact transcripts in Validation and Acceptance below.


## Concrete Steps

The repository root is `/Users/shinzui/Keikaku/bokuno/nagare`. All paths below are absolute or
clearly repo-relative. Enter the dev shell first (`cd /Users/shinzui/Keikaku/bokuno/nagare &&
nix develop`) so `gcloud`, `pulumi`, `kubectl`, `sops`, `age`, `socat`, and `jq` are present;
where a step needs a specific tool it is named.

### Step 1: Create the directory structure

```bash
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/nixos/modules
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/scripts
```

### Step 2: Write `nixos/flake.nix`

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/flake.nix`. The `mkImage` helper mirrors the
reference repo: it composes the GCE module + base + caller modules and returns
`config.system.build.image`. Note the second output, `nixosConfigurations.nagare-01`, which is
the *same* module set wrapped as a configuration so `nixos-rebuild --flake .#nagare-01` works.

```nix
{
  description = "NixOS host images and configurations for the Nagare personal PaaS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      system = "x86_64-linux";

      # The module set that defines `nagare-01`. Used in two places:
      #   * mkImage below, to produce the GCE image (config.system.build.image).
      #   * nixosConfigurations.nagare-01 below, so `nixos-rebuild --flake
      #     .#nagare-01 --target-host nagare-01` rebuilds the SAME system the
      #     image was baked from (no drift between first boot and day-2 changes).
      nagare01Modules = [
        ./configuration-base.nix
        sops-nix.nixosModules.sops
        ./hosts/nagare-01/configuration.nix
      ];

      # mkImage composes the upstream GCE-format module from nixpkgs
      # (nixos/modules/virtualisation/google-compute-image.nix) with the given
      # modules, then exposes the resulting NixOS system's
      # `config.system.build.image` derivation. The output is a directory
      # containing a single `*.raw.tar.gz` (a sparse disk.raw inside a gzipped
      # tar) — exactly what `gcloud compute images create --source-uri` expects.
      mkImage = { modules ? [ ] }:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
          ] ++ modules;
        }).config.system.build.image;
    in {
      packages.${system} = {
        # Build with the FULL attribute path so aarch64-darwin dispatches to
        # the x86_64-linux remote builder:
        #   nix build .#packages.x86_64-linux.nagare-image
        nagare-image = mkImage { modules = nagare01Modules; };
      };

      nixosConfigurations.nagare-01 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = nagare01Modules;
      };
    };
}
```

### Step 3: Write `nixos/configuration-base.nix`

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/configuration-base.nix`. This is the shared
base; it mirrors the reference repo's base but adds the nix-settings needed so the operator can
build and `nixos-rebuild` against the box.

```nix
{ pkgs, ... }:

{
  imports = [ ./modules/gcp.nix ];

  services.gcp.enable = true;

  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [ vim curl git jq ];

  # Flakes are required for `nixos-rebuild --flake`. trusted-users lets the
  # deploy user push a closure during a remote rebuild without sudo for nix.
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # State version pins the semantics of stateful options. Match the nixpkgs
  # release line; never bump on an existing system without a migration.
  system.stateVersion = "26.05";
}
```

### Step 4: Write `nixos/modules/gcp.nix`

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/modules/gcp.nix`. This is adapted verbatim
from the reference repo's module. Do NOT add `services.google-guest-agent.enable` — the GCE
format wires the guest agent itself, and the option does not exist at the pinned nixpkgs.

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.gcp;
in {
  options.services.gcp = {
    enable = lib.mkEnableOption "GCE compatibility (guest agent, IAP-friendly sshd, baseline sysctls)";

    user.name = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = ''
        Name of the optional break-glass Linux user created when
        `services.gcp.user.sshAuthorizedKeys` is non-empty. Normal logins use
        OS Login (IAP) or the deploy user defined in hosts/nagare-01/users.nix.
      '';
    };

    user.sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Public SSH keys appended to the break-glass user's authorized_keys.
        Empty (the default) creates no extra user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # services.openssh.enable, security.googleOsLogin.enable, and the
    # google-guest-agent unit are set by the upstream GCE config module the
    # image format imports. We only tighten sshd here. Do NOT set
    # ListenAddress/AllowUsers — IAP arrives on the VM's primary internal IP.
    services.openssh.settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };

    services.chrony.enable = true;

    boot.kernel.sysctl = {
      "vm.swappiness" = 10;
      "net.ipv4.tcp_keepalive_time" = 60;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.kptr_restrict" = 2;
    };

    services.journald.extraConfig = ''
      SystemMaxUse=500M
      MaxRetentionSec=7day
    '';

    users.users = lib.mkIf (cfg.user.sshAuthorizedKeys != [ ]) {
      ${cfg.user.name} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = cfg.user.sshAuthorizedKeys;
      };
    };

    security.sudo.wheelNeedsPassword = false;
  };
}
```

### Step 5: Write the host files under `nixos/hosts/nagare-01/`

#### `configuration.nix` — the host aggregator

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/configuration.nix`. It
imports the six role files (the sops-nix *module* itself is added in the flake, not here) and
declares the sops secret for the Tailscale auth key. The `sops.age.keyFile` points at an `age`
private key on the host; that key is placed there out of band before first boot (see Step 11),
and the encrypted secrets file is committed to Git.

```nix
{ ... }:

{
  imports = [
    ./networking.nix
    ./storage.nix
    ./users.nix
    ./security.nix
    ./k3s.nix
    ./tailscale.nix
  ];

  # sops-nix: decrypt secrets at activation using an age key on the host.
  # The encrypted file is committed to Git; the private age key lives only on
  # the host at the path below (placed before first boot — see the plan's
  # Concrete Steps). EP-7 expands this; here we manage exactly one secret.
  sops.defaultSopsFile = ./secrets/nagare-01.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/age-key.txt";

  # The Tailscale pre-authentication key. tailscale.nix consumes this path.
  sops.secrets."tailscale/authkey" = {
    # Mode 0400 owned by root; tailscaled reads it as root at start.
    mode = "0400";
  };
}
```

#### `networking.nix` — hostname and firewall

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/networking.nix`. The
upstream GCE module sets a permissive firewall default; we explicitly enable the firewall and
open only 22 (SSH), 80 (HTTP), and 443 (HTTPS) — the ports Kourier/ServiceLB will bind for
ingress (EP-4). Tailscale traffic is allowed via the interface rule.

```nix
{ ... }:

{
  networking.hostName = "nagare-01";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    # Trust the Tailscale interface so the tailnet can reach node services
    # (e.g. the kube-apiserver on 6443) without opening them to the world.
    trustedInterfaces = [ "tailscale0" ];
    # Let Tailscale's UDP discovery work through the firewall.
    allowedUDPPorts = [ 41641 ];
  };
}
```

#### `storage.nix` — data disk mount and subdir layout

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/storage.nix`. GCP exposes an
attached persistent disk to the guest at `/dev/disk/by-id/google-<deviceName>`. EP-2 attaches
the data disk (`pulumi stack output dataDiskName`) with that device name; the placeholder here
is `nagare-data` — confirm and substitute the real value. The mount is by stable by-id path so
it survives device renumbering. The seven IP-3 subdirectories are created with
`systemd.tmpfiles.rules` (declarative directory creation that runs on every boot, idempotent).

```nix
{ ... }:

let
  # The device name EP-2 assigns to the attached data disk. GCP surfaces it at
  # /dev/disk/by-id/google-<deviceName>. Confirm with EP-2's stack output
  # `dataDiskName` and the device name it attaches; substitute if different.
  dataDiskDevice = "/dev/disk/by-id/google-nagare-data";
in
{
  fileSystems."/var/lib/nagare" = {
    device = dataDiskDevice;
    fsType = "ext4";
    # nofail so a first boot before the disk is formatted does not hang the
    # boot; EP-2 attaches a pre-formatted disk, or the first boot formats it.
    options = [ "defaults" "nofail" ];
    # autoFormat is provided by some setups via a oneshot; if EP-2 does not
    # pre-format the disk, format once manually (see Idempotence and Recovery).
  };

  # Create the IP-3 subdirectory layout under the mount. These run on every
  # boot and are idempotent (tmpfiles only creates what is missing).
  systemd.tmpfiles.rules = [
    "d /var/lib/nagare 0755 root root -"
    "d /var/lib/nagare/victoria-metrics 0755 root root -"
    "d /var/lib/nagare/victoria-logs 0755 root root -"
    "d /var/lib/nagare/victoria-traces 0755 root root -"
    "d /var/lib/nagare/postgres 0755 root root -"
    "d /var/lib/nagare/sqlite 0755 root root -"
    "d /var/lib/nagare/backups 0755 root root -"
    "d /var/lib/nagare/local-path 0755 root root -"
  ];
}
```

#### `k3s.nix` — the single-node cluster

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/k3s.nix`. This is the heart
of the cluster. The flags apply the spec corrections: disable Traefik (Kourier owns ingress),
write the kubeconfig world-readable (`0644`, the IP-7 contract so the operator can copy it),
and point local-path-provisioner at the data disk. **ServiceLB stays enabled** — do not add
`--disable=servicelb`. On a single node, ServiceLB (Klipper) is the only controller that gives
Kourier's `type: LoadBalancer` gateway Service an external address by binding host ports 80/443
to it; disabling it would leave Kourier unreachable. On current nixpkgs `extraFlags` takes a
list of strings.

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

  # k3s needs the storage mount to exist before it starts so the
  # local-path-provisioner path is valid. Order the unit after the mount.
  systemd.services.k3s.after = [ "var-lib-nagare.mount" ];
  systemd.services.k3s.requires = [ "var-lib-nagare.mount" ];
}
```

#### `users.nix` — the deploy user

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/users.nix`. The `deploy`
user is the target of `nixos-rebuild --target-host nagare-01 --sudo`. Replace the placeholder
public key with the operator's real key (the same one registered for IAP/OS Login and Tailscale
SSH). `mutableUsers = false` keeps the user set fully declarative.

```nix
{ ... }:

{
  users.mutableUsers = false;

  users.users.deploy = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Replace with the operator's real public key:
      "ssh-ed25519 AAAA... operator@workstation"
    ];
  };
}
```

#### `security.nix` — sshd hardening and sudo

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/security.nix`. sshd is
key-only with no root login (the GCE module sets these too; we restate them so this host stands
on its own). Passwordless sudo for `wheel` is what lets `nixos-rebuild --sudo` activate the new
system as the non-root `deploy` user without an interactive password prompt.

```nix
{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Passwordless sudo for the wheel group enables the unattended
  # `nixos-rebuild switch --target-host nagare-01 --sudo` activation.
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };
}
```

#### `tailscale.nix` — private mesh VPN

Create `/Users/shinzui/Keikaku/bokuno/nagare/nixos/hosts/nagare-01/tailscale.nix`. The host
joins the tailnet headlessly on first boot using a pre-authentication key. NixOS's
`services.tailscale.authKeyFile` points at the decrypted sops secret; `tailscaled` reads it and
runs `tailscale up` automatically, so no human has to log in interactively to authenticate the
node. After the node has joined once, the state in `/var/lib/tailscale` keeps it joined across
reboots regardless of the key's expiry.

```nix
{ config, ... }:

{
  services.tailscale = {
    enable = true;
    # The decrypted auth key, provided by the sops secret declared in
    # configuration.nix. sops-nix writes it to this runtime path at activation.
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    # Open the firewall for the tailscale interface and accept the default
    # join behavior (ephemeral=false so the node persists in the tailnet).
    extraUpFlags = [ "--ssh" ];
  };
}
```

### Step 6: Create the encrypted secrets file

The sops secret needs an `age` keypair. Generate one for the host, encrypt a secrets file
against its public key, and commit the encrypted file (never the private key).

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mkdir -p nixos/hosts/nagare-01/secrets

# Generate the host age key (private key stays local + goes on the host later).
age-keygen -o /tmp/nagare-01-age-key.txt
# Note the printed public key, e.g. age1abc... ; put it in .sops.yaml below.

cat > nixos/.sops.yaml <<'YAML'
keys:
  - &host_nagare01 age1REPLACE_WITH_PUBLIC_KEY
creation_rules:
  - path_regex: hosts/nagare-01/secrets/.*\.yaml$
    key_groups:
      - age:
          - *host_nagare01
YAML

# Create and encrypt the secrets file. The plaintext key value is a Tailscale
# pre-auth key minted in the Tailscale admin console (Settings -> Keys).
SOPS_AGE_KEY_FILE=/tmp/nagare-01-age-key.txt \
  sops --config nixos/.sops.yaml \
  --encrypt --age age1REPLACE_WITH_PUBLIC_KEY \
  /dev/stdin > nixos/hosts/nagare-01/secrets/nagare-01.yaml <<'PLAINTEXT'
tailscale:
  authkey: tskey-auth-REPLACE_WITH_REAL_PREAUTH_KEY
PLAINTEXT
```

The decrypted secret will be exposed by sops-nix at the path
`config.sops.secrets."tailscale/authkey".path` because the YAML key
`tailscale.authkey` maps to the dotted secret name `tailscale/authkey`.

### Step 7: Lock the flake and (optionally) evaluate

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/nixos
nix flake lock
# Evaluate the derivation without building, to catch config errors fast:
nix eval --raw .#packages.x86_64-linux.nagare-image.drvPath
```

Expected: `nix flake lock` writes `flake.lock` pinning `nixpkgs` and `sops-nix`; the `nix eval`
prints a `/nix/store/...-google-compute-image.drv` path with no option errors.

### Step 8: Configure the host-side remote builder wiring (one-time)

Building an `x86_64-linux` image on macOS requires a registered Linux builder. The reference
repo wires this declaratively in dotfiles; the minimal manual equivalent is:

1. Generate (once) the builder key the startup template will trust, and place its public half
   where `setup-nix-builder.sh` reads it:

```bash
sudo mkdir -p /etc/nix
sudo ssh-keygen -t ed25519 -N "" -f /etc/nix/builder_ed25519
sudo chmod 600 /etc/nix/builder_ed25519
```

2. Add an SSH host block so `nix` can reach the builder by the name `nix-gcp-builder`, routing
   through an IAP tunnel via `socat` (the macOS-safe path). Put this in `~/.ssh/config`:

```text
Host nix-gcp-builder
  HostName localhost
  User builder
  IdentityFile /etc/nix/builder_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  # Open an IAP tunnel on a fixed local port and pipe ssh through socat.
  # Start the tunnel out of band (see below) before the first build, or
  # adapt scripts/iap-ssh.sh into an on-demand ProxyCommand.
  ProxyCommand socat - TCP:localhost:%p
  Port 2222
```

3. Register the builder with Nix so `nix build` offloads `x86_64-linux` jobs to it. Add to
   `/etc/nix/machines`:

```text
ssh-ng://nix-gcp-builder x86_64-linux /etc/nix/builder_ed25519 4 1 big-parallel,benchmark
```

4. Before a build, start the builder VM and open the IAP tunnel on port 2222:

```bash
gcloud --project=tan-nb-exp compute instances start nix-builder-x86 --zone=us-west1-a
gcloud --project=tan-nb-exp compute start-iap-tunnel nix-builder-x86 22 \
  --zone=us-west1-a --local-host-port=localhost:2222 &
# Confirm Nix can talk to the builder:
nix store info --store ssh-ng://nix-gcp-builder
```

This manual wiring is the documented equivalent of the reference repo's
`dotfiles.nix/darwin/gcp-nix-builder.nix`. If you maintain a nix-darwin/home-manager config,
prefer porting that module so the tunnel is opened on demand by an SSH `ProxyCommand` rather
than started by hand. Either way, `scripts/upload-images.sh` (Step 10) opens its own tunnels
through `scripts/iap-ssh.sh` for the builder→GCS upload, so only the `nix build` dispatch
itself needs this host wiring.

### Step 9: Write the builder/upload scripts

Author the four scripts. `scripts/nix-builder-startup.sh.tpl`, `scripts/setup-nix-builder.sh`,
and `scripts/iap-ssh.sh` are copied essentially verbatim from the reference repo at
`/Users/shinzui/Keikaku/bokuno/load-testing-infra/scripts/` (they are already pinned to
`tan-nb-exp` and carry the IP-9 preflight). Read those three files and reproduce them under
`/Users/shinzui/Keikaku/bokuno/nagare/scripts/` unchanged. They are reproduced here in full so
this plan is self-contained; if the reference files have drifted, prefer the reference copies
and note the drift in Surprises.

`scripts/upload-images.sh` is the Nagare-specific adaptation. It drops the reference repo's
dynamic driver-image discovery (Nagare has one image) and writes the single Pulumi config key
`nagareImageSelfLink`. Create
`/Users/shinzui/Keikaku/bokuno/nagare/scripts/upload-images.sh`:

```bash
#!/usr/bin/env bash
# Build the Nagare NixOS GCE image on the remote x86_64-linux builder, upload
# the tarball to the image bucket, register it as a GCE image, and write its
# self-link to Pulumi config key `nagareImageSelfLink` (consumed by EP-2's
# instance component).
#
# Idempotent: existing GCS objects and registered GCE images are reused; only
# missing artifacts trigger writes. A rebuilt image gets a new content hash and
# therefore a new name, so old and new images coexist.
set -euo pipefail

PROJECT=tan-nb-exp
# IP-9 project-isolation guard: fail closed if gcloud's active project is wrong.
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  echo "fix: 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=$PROJECT'." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIXOS_DIR="${REPO_ROOT}/nixos"
PULUMI_DIR="${REPO_ROOT}/infra/pulumi"
IAP_SSH="${REPO_ROOT}/scripts/iap-ssh.sh"
REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
BUILDER_INSTANCE="${BUILDER_INSTANCE:-nix-builder-x86}"
OUTPUT="nagare-image"
ATTR="packages.x86_64-linux.${OUTPUT}"

log() { printf '[upload-images] %s\n' "$*" >&2; }

BUCKET="$(pulumi --cwd "${PULUMI_DIR}" config get imageBucket)"
if [ -z "${BUCKET}" ]; then
  echo "imageBucket not set in Pulumi config. Run: pulumi --cwd infra/pulumi config set imageBucket <name>" >&2
  exit 2
fi
log "Target bucket: gs://${BUCKET}/"
if ! gsutil ls -b "gs://${BUCKET}/" >/dev/null 2>&1; then
  log "Creating bucket gs://${BUCKET}/ in ${REGION}"
  gsutil mb -p "${PROJECT}" -l "${REGION}" -b on "gs://${BUCKET}/"
fi

# Build the image by FULL attribute path so aarch64-darwin offloads to the
# x86_64-linux remote builder. If the local copy-back over IAP-SSH drops on a
# multi-GB closure, recover by evaluating the (content-addressed) output path
# and checking it exists on the builder.
build_image() {
  local out_path
  if out_path=$( (cd "${NIXOS_DIR}" && nix build --print-out-paths --no-link ".#${ATTR}") 2>/tmp/nagare-nix-build.err ); then
    echo "${out_path}"; return 0
  fi
  out_path=$(cd "${NIXOS_DIR}" && nix eval --raw ".#${ATTR}" 2>/dev/null) || {
    log "nix build failed and nix eval could not resolve the output path:"; cat /tmp/nagare-nix-build.err >&2; return 1; }
  local q; q="$(printf '%q' "${out_path}")"
  if [ -n "${BUILDER_INSTANCE}" ] && "${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "test -d ${q}" 2>/dev/null; then
    log "Local copy-back failed but build is on builder at ${out_path} — using builder upload"
    echo "${out_path}"; return 0
  fi
  log "Build failed and is not on the builder; surfacing the nix error:"; cat /tmp/nagare-nix-build.err >&2; return 1
}

image_hash() { local b; b="$(basename "$1")"; b="${b%%-*}"; echo "${b:0:12}"; }

locate_tarball() {
  local store_path="$1" tarball
  if [ -d "${store_path}" ]; then
    tarball="$(find "${store_path}" -maxdepth 1 -name '*.raw.tar.gz' -print -quit)"
  elif [ -n "${BUILDER_INSTANCE}" ]; then
    local q; q="$(printf '%q' "${store_path}")"
    tarball="$("${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "find ${q} -maxdepth 1 -type f -name '*.raw.tar.gz' -print -quit")"
  fi
  [ -n "${tarball}" ] || { echo "no *.raw.tar.gz in ${store_path}" >&2; return 1; }
  echo "${tarball}"
}

upload_if_missing() {
  local src="$1" uri="$2"
  if gsutil -q stat "${uri}"; then log "Already in GCS: ${uri}"; return 0; fi
  if [ -f "${src}" ]; then
    log "Uploading ${src} -> ${uri}"; gsutil cp "${src}" "${uri}"
  else
    log "Uploading from builder: ${src} -> ${uri}"
    "${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "sudo -u builder gsutil cp '${src}' '${uri}'"
  fi
}

register_if_missing() {
  local name="$1" uri="$2"
  if gcloud --project="${PROJECT}" compute images describe "${name}" --format='value(name)' >/dev/null 2>&1; then
    log "Already registered: ${name}"
  else
    log "Registering GCE image ${name} from ${uri}"
    gcloud --project="${PROJECT}" compute images create "${name}" --source-uri "${uri}" --quiet
  fi
}

store_path="$(build_image)"
hash="$(image_hash "${store_path}")"
image_name="${OUTPUT}-${hash}"
gs_uri="gs://${BUCKET}/${image_name}.raw.tar.gz"
tarball="$(locate_tarball "${store_path}")"

upload_if_missing "${tarball}" "${gs_uri}"
register_if_missing "${image_name}" "${gs_uri}"

self_link="$(gcloud --project="${PROJECT}" compute images describe "${image_name}" --format='value(selfLink)')"
log "pulumi config set nagareImageSelfLink ${self_link}"
pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink "${self_link}"
log "Done."
```

Make the scripts executable:

```bash
chmod +x /Users/shinzui/Keikaku/bokuno/nagare/scripts/*.sh
```

### Step 10: Provision the builder and run the pipeline

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
# Provision the on-demand builder (idempotent). Requires /etc/nix/builder_ed25519.pub.
scripts/setup-nix-builder.sh

# Ensure EP-2 has set the image bucket name (it owns this config key):
pulumi --cwd infra/pulumi config get imageBucket || \
  pulumi --cwd infra/pulumi config set imageBucket tan-nb-exp-nagare-images

# Start the builder + tunnel (Step 8.4), then build/upload/register:
scripts/upload-images.sh

# Confirm the self-link was written:
pulumi --cwd infra/pulumi config get nagareImageSelfLink
```

Expected tail of `upload-images.sh`:

```text
[upload-images] Uploading from builder: /nix/store/...-google-compute-image/nixos-image-google-compute-...-x86_64-linux.raw.tar.gz -> gs://tan-nb-exp-nagare-images/nagare-image-<hash>.raw.tar.gz
[upload-images] Registering GCE image nagare-image-<hash> from gs://tan-nb-exp-nagare-images/nagare-image-<hash>.raw.tar.gz
[upload-images] pulumi config set nagareImageSelfLink https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/images/nagare-image-<hash>
[upload-images] Done.
```

### Step 11: Place the host age key (out of band, before first boot)

sops-nix on `nagare-01` needs the private `age` key to decrypt the Tailscale secret at boot.
Because the box has no secrets baked in, place the key once after the VM is created (EP-2's
`pulumi up`), via IAP-SSH, before relying on the secret:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo install -d -m 0700 /var/lib/sops-nix'
scripts/iap-ssh.sh scp /tmp/nagare-01-age-key.txt nagare-01:/tmp/age-key.txt
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo mv /tmp/age-key.txt /var/lib/sops-nix/age-key.txt && sudo chmod 0400 /var/lib/sops-nix/age-key.txt'
# Re-activate so sops decrypts the Tailscale key and tailscaled joins:
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo systemctl restart sops-nix.service tailscaled.service'
```

Alternatively, EP-7 (the secrets/recovery plan) may automate seeding this key from the backup
bucket; until then this manual seed is the documented path.


## Validation and Acceptance

These are the observable behaviors that prove the plan worked. Run them after EP-2's
`pulumi up` has booted `nagare-01` from the registered image.

First, confirm the image build artifact (Milestone 1):

```text
$ cd /Users/shinzui/Keikaku/bokuno/nagare/nixos
$ nix build --print-out-paths --no-link .#packages.x86_64-linux.nagare-image
/nix/store/XXXXXXXXXXXX-google-compute-image
$ find /nix/store/XXXXXXXXXXXX-google-compute-image -maxdepth 1 -name '*.raw.tar.gz'
/nix/store/XXXXXXXXXXXX-google-compute-image/nixos-image-google-compute-26.05....-x86_64-linux.raw.tar.gz
```

Confirm the image is registered and the Pulumi config key is set (Milestone 2):

```text
$ gcloud --project=tan-nb-exp compute images describe nagare-image-<hash> --format='value(name,status)'
nagare-image-<hash>	READY
$ pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi config get nagareImageSelfLink
https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/images/nagare-image-<hash>
```

Now verify the running host (Milestone 3). SSH in over Tailscale (or IAP-SSH if Tailscale is
not yet up). The kubeconfig at `/etc/rancher/k3s/k3s.yaml` is world-readable so `kubectl` works
for any logged-in user:

```text
$ ssh deploy@nagare-01 'sudo k3s kubectl get nodes -o wide'
NAME        STATUS   ROLES                  AGE   VERSION        INTERNAL-IP   OS-IMAGE
nagare-01   Ready    control-plane,master   2m    v1.3x.x+k3s1   10.x.x.x      NixOS 26.05
```

The data disk is mounted at `/var/lib/nagare` with the seven IP-3 subdirectories:

```text
$ ssh deploy@nagare-01 'mount | grep nagare'
/dev/sdb on /var/lib/nagare type ext4 (rw,relatime)
$ ssh deploy@nagare-01 'ls /var/lib/nagare'
backups  local-path  postgres  sqlite  victoria-logs  victoria-metrics  victoria-traces
```

The kubeconfig has mode `0644` (the IP-7 contract that EP-4/5/6 rely on to copy it):

```text
$ ssh deploy@nagare-01 'stat -c "%a %n" /etc/rancher/k3s/k3s.yaml'
644 /etc/rancher/k3s/k3s.yaml
```

Prove `--default-local-storage-path` took effect by binding a test PVC and finding its backing
directory under `/var/lib/nagare/local-path`:

```bash
ssh deploy@nagare-01 'cat <<YAML | sudo k3s kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-storage-test
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 64Mi
YAML
'
```

A PVC with the default `local-path` StorageClass only binds once a consuming pod is scheduled
(the provisioner is `WaitForFirstConsumer`), so create a throwaway pod that mounts it, then
inspect where the volume landed:

```text
$ ssh deploy@nagare-01 'sudo k3s kubectl run pvc-probe --image=busybox --restart=Never \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"nagare-storage-test\"}}],\"containers\":[{\"name\":\"c\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"sleep 60\"],\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}]}}"'
$ ssh deploy@nagare-01 'sudo k3s kubectl get pvc nagare-storage-test'
NAME                  STATUS   VOLUME        CAPACITY   ACCESS MODES   STORAGECLASS
nagare-storage-test   Bound    pvc-xxxx...   64Mi       RWO            local-path
$ ssh deploy@nagare-01 'sudo find /var/lib/nagare/local-path -maxdepth 2 -type d -name "pvc-*"'
/var/lib/nagare/local-path/pvc-xxxx..._default_nagare-storage-test
```

The presence of the `pvc-*` directory under `/var/lib/nagare/local-path` is the proof that the
provisioner is writing to the data disk and not k3s's default `/var/lib/rancher/...` path.

Clean up the probe:

```bash
ssh deploy@nagare-01 'sudo k3s kubectl delete pod pvc-probe; sudo k3s kubectl delete pvc nagare-storage-test'
```

Finally, demonstrate the day-2 rebuild path over Tailscale. Edit a trivial setting (for
example add a package to `environment.systemPackages` in `configuration-base.nix`), then:

```text
$ cd /Users/shinzui/Keikaku/bokuno/nagare/nixos
$ nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo
building the system configuration...
... copying closure to nagare-01 ...
activating the configuration...
$ ssh deploy@nagare-01 'which <the-new-package>'
/run/current-system/sw/bin/<the-new-package>
```

The rebuild succeeding without rebaking an image — and the new package being present — proves
the host stays in sync with the flake via `--target-host`/`--sudo`, the day-2 workflow.


## Idempotence and Recovery

`scripts/setup-nix-builder.sh` is idempotent: it only creates resources that are missing (VPC,
subnet, firewall, VM). Re-running after the VM exists skips creation; editing the startup
template has no effect unless the VM is deleted first. The builder stops itself when idle, so
re-running mostly just confirms it exists.

`scripts/upload-images.sh` is idempotent: GCS objects and GCE images are content-addressed by
the image's 12-char store-hash prefix and reused if present (`gsutil -q stat`, `gcloud compute
images describe`). Rebuilding after a config change yields a new hash and therefore a new image
name, so old and new images coexist without manual cleanup — re-running simply registers the
new one and rewrites `nagareImageSelfLink`. `gcloud compute images create` is not itself
idempotent (it errors if the name exists), which is why the script guards it with a `describe`.

The image build (`nix build`) is reproducible: the same flake at the same lock produces the
same store path. If the IAP-SSH copy-back drops mid-transfer on a multi-GB closure (a known
flake of large transfers over the tunnel — see the reference repo's Surprises), re-run
`upload-images.sh`; it recovers by evaluating the content-addressed output path and uploading
builder→GCS directly. If `nix store info --store ssh-ng://nix-gcp-builder` fails, the builder
VM is probably stopped or the tunnel is closed — start the VM and re-open the tunnel (Step 8.4).

`nixos-rebuild switch --target-host` is repeatable: applying the same flake twice is a no-op
(the system closure is unchanged, so activation does nothing). A bad rebuild can be rolled back
on the host with `sudo nixos-rebuild switch --rollback` or by selecting a previous generation in
the bootloader; because the configuration is also baked into the image, a fully broken host can
be recreated by `pulumi up` from the last-good `nagareImageSelfLink`.

The `systemd.tmpfiles.rules` in `storage.nix` are idempotent — they create only missing
directories on each boot and never delete data. The data-disk mount uses `nofail` so a first
boot before the disk is formatted does not hang. If EP-2 attaches an *unformatted* disk, format
it once (data-destroying — only on a fresh disk) and reboot:

```bash
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo mkfs.ext4 -F /dev/disk/by-id/google-nagare-data && sudo systemctl restart var-lib-nagare.mount && sudo systemctl restart k3s'
```

The host `age` key seed (Step 11) is idempotent (re-copying the same key is harmless). If the
Tailscale join fails, confirm the secret decrypted (`sudo systemctl status sops-nix.service`
and check `config.sops.secrets."tailscale/authkey".path` exists) and that the pre-auth key has
not expired; mint a fresh key, re-encrypt the secrets file, re-deploy, and restart `tailscaled`.


## Interfaces and Dependencies

This plan produces and consumes the following named interfaces. They must hold at the end of
the listed milestone so the dependent plans can rely on them.

**Produced by this plan (end of Milestone 1):**

- The flake output `packages.x86_64-linux.nagare-image` in `nixos/flake.nix`: a derivation
  building a directory that contains exactly one `*.raw.tar.gz` GCE image. Built by full
  attribute path so it dispatches to the remote x86_64-linux builder.
- The flake attribute `nixosConfigurations.nagare-01`: the same module set as a configuration,
  the target of `nixos-rebuild --flake .#nagare-01`. Image and rebuild target are identical, so
  the booted host never drifts from the flake.
- The NixOS option contract `services.gcp.enable` in `nixos/modules/gcp.nix`: enables GCE
  compatibility; downstream host modules just set it `true` (already done in
  `configuration-base.nix`).

**Produced by this plan (end of Milestone 2):**

- The Pulumi **config** key `nagareImageSelfLink`, written by `scripts/upload-images.sh`. This
  is the producer side of MasterPlan Integration Point 1 and 10. EP-2's instance component
  reads it to choose the boot image. The value is a full GCE image self-link under
  `projects/tan-nb-exp/global/images/`.

**Produced by this plan (end of Milestone 3, consumed by EP-4/5/6):**

- The cluster: a running single-node k3s server on `nagare-01`. EP-4 (Knative/Kourier/cert-
  manager) and EP-5 (Victoria observability) install onto it; EP-6 (`nagarectl`) deploys apps
  to it. This is MasterPlan Integration Point 7's cluster.
- The kubeconfig at `/etc/rancher/k3s/k3s.yaml`, mode `0644` (Integration Point 7). Consuming
  plans copy it locally and rewrite its `server:` field to the Tailscale name `nagare-01` (or
  `publicIp`) and export `KUBECONFIG`.
- The data mount at `/var/lib/nagare` with the seven subdirectories (Integration Point 3).
  EP-5 requests storage via PVCs that bind under `/var/lib/nagare/local-path`; EP-7 backs up
  from `victoria-*`, `postgres`, `sqlite`. The local-path StorageClass `local-path` (k3s's
  default) is repointed at the data disk via `--default-local-storage-path`.

**Consumed by this plan (from sibling plans):**

- From EP-2 (`docs/plans/2-pulumi-gcp-infrastructure.md`): the Pulumi config key `imageBucket`
  (the GCS bucket for staged image tarballs), the stack output `dataDiskName` and the attached
  device name (to set `dataDiskDevice` in `storage.nix`), and the running `nagare-01` VM with
  the disk attached (produced by `pulumi up` after this plan writes `nagareImageSelfLink`).
- From EP-1 (`docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md`): the dev
  shell tools (`gcloud`, `gsutil`, `pulumi`, `kubectl`, `sops`, `age`, `tailscale`, `socat`,
  `jq`, `nix`) and the repo-root `.envrc` that pins `CLOUDSDK_CORE_PROJECT=tan-nb-exp` etc.
- Libraries/modules used: `nixpkgs` (the GCE image module and all NixOS options), `sops-nix`
  (the `sops-nix.nixosModules.sops` module and `sops.secrets.*` options), the k3s NixOS module
  (`services.k3s`), and the Tailscale NixOS module (`services.tailscale`).
