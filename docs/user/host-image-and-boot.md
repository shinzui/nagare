---
type: Runbook
title: "Host image and first boot"
description: "Build and register the Nagare NixOS image, boot the VM, and verify the first host startup."
docId: DOC-17
tags: [host, nixos, image, boot, gcp]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

# Host image and first boot

> **Status:** 🟡 In progress (EP-4)
>
> The NixOS flake, the `nagare-01` host config, and the image build/upload
> pipeline exist; `nagare-01` has been booted from a baked image and the data
> disk auto-formats on first boot. The blank-disk service graph is covered by
> repeated VM tests through an exactly-one-node `Ready` result without a reboot.
> The first boot is deliberately secretless; the supported IAP handoff below activates host secrets
> and Tailscale without rebuilding or rebooting.

This page covers turning the NixOS configuration into a bootable GCE image and
bringing `nagare-01` up from it. Because your workstation is `aarch64-darwin`
and GCE images are `x86_64-linux`, the image is built **on a remote Linux Nix
builder in GCP**, not locally.

---

## The model

```text
aarch64-darwin workstation
   │  nix build .#packages.x86_64-linux.nagare-image   (dispatched to…)
   ▼
x86_64-linux Nix builder (on-demand GCP VM)
   │  produces  result/nixos.raw.tar.gz
   ▼
GCS image-staging bucket ($NAGARE_IMAGE_BUCKET = <project>-nagare-images;
   │  default example tan-nb-exp-nagare-images)
   │  gcloud compute images create --source-uri …
   ▼
GCE image  →  Pulumi config  nagareImageSelfLink (embeds the project; regenerated per target)
   │  pulumi up
   ▼
nagare-01 boots the baked image
```

Each context-owned host flake produces two NixOS outputs from **one shared system** so they never
drift. The generated flake imports Nagare's reusable module and constructor from the packaged
`nixos/flake.nix`:

- `packages.x86_64-linux.nagare-image` — the GCE image
  (`config.system.build.image`, a directory containing one `*.raw.tar.gz`).
- `nixosConfigurations.<host-name>` — the day-2 `nixos-rebuild` target.

Both include the upstream `google-compute-image.nix` module, so the day-2 target
has a root filesystem and bootloader matching exactly what's baked into the
image. (Putting the GCE module only in the image path is a known trap — it
breaks `nixosConfigurations.nagare-01` evaluation. It's correctly shared here.)

## What the image config contains

Nagare's packaged modules under `nixos/` configure:

- **k3s** (`k3s.nix`) — `role = server`, Traefik disabled, ServiceLB kept,
  kubeconfig mode `0640 root:wheel`, Secret encryption enabled, local-path
  storage at `/var/lib/nagare/local-path`.
  Ordered after the data-disk mount and the directory-layout unit.
- **Storage** (`storage.nix`) — auto-formats the blank data disk to ext4 on
  first boot (idempotent), before either systemd-fsck or the mount can open it;
  mounts it `nofail` at `/var/lib/nagare`; then creates the subdirectory layout
  *after* the mount. A recovered mount transaction also pulls layout and k3s
  back in, so a transient failure does not require a reboot.
- **Networking** (`networking.nix`) — context-supplied hostname, public DNS resolvers
  (`8.8.8.8`/`8.8.4.4` — the GCE metadata resolver is unreachable on this VM),
  firewall (`22`/`80`/`443`, trust `tailscale0`).
- **Security** (`security.nix`) — key-only SSH, no root login, `PerSourcePenalties`
  off, Google OS Login disabled, passwordless sudo for `wheel`.
- **Users** (`users.nix`) — the configured deploy user with the context's explicit SSH keys.
- **Tailscale** (`tailscale.nix`) — joins the tailnet using a sops-provided
  auth key, with `--ssh` enabled.
- **sops-nix** (`nixos/modules/nagare-host.nix`) — decrypts the context's encrypted secrets using an
  age-key path on the host.

The rationale for the non-obvious choices is in [Troubleshooting](troubleshooting.md)
— they were each the fix for a real first-boot failure.

## Prerequisite: encrypted host secrets and an operator-held age key

Before the host can boot cleanly, generate its context-owned flake with `nagarectl host init`.
sops-nix later decrypts the copied `secrets.yaml`. Prepare:

- The host's **age private key** in an operator-controlled backup outside Git and the image.
- The supplied secrets file encrypted to the host's age **public** key.

The one secret managed at this stage is `tailscale/authkey` (a Tailscale
pre-auth key), consumed by `tailscale.nix`. See [Secrets](secrets.md) for how
the age key is generated, where it's stored, and how to add/rotate secrets.

> On the from-zero path these are Steps 3–4 of the
> [bring-your-own-project onboarding](onboarding-bring-your-own-project.md):
> the operator SSH key and encrypted Tailscale secret are prepared before image build. The private
> age key is delivered only after the VM exists and IAP SSH is reachable.

## Build and register the image

If this is a deliberate rebuild of an existing VM, first set
`nagare:vmDeletionProtection` to `false` and apply that protection-only change
as described in
[Provisioning with Pulumi → Review replacements and protected resources](provisioning-with-pulumi.md#review-replacements-and-protected-resources).
Do this before `host-image` writes a replacement-causing image self-link. First
creation needs no such step.

Confirm the selected host before building, then run the pipeline:

```bash
nagarectl host path
nagare host-image --dry-run
nagare host-image      # runs scripts/upload-images.sh
```

`scripts/upload-images.sh` (the details are owned by the script):

1. Renders a private per-context SSH route and explicit Nix builders specification, then uses the
   context's project, zone, and `nix-builder-x86` instance
   (`scripts/setup-nix-builder.sh` provisions that on-demand VM if needed).
2. Resolves the active context's generated flake (or an explicit `NAGARE_HOST_FLAKE`) and builds
   `.#packages.x86_64-linux.nagare-image` on it.
3. Uploads the resulting `*.raw.tar.gz` to the active context's
   `$NAGARE_IMAGE_BUCKET` (`<project>-nagare-images` by default).
4. Registers it as a GCE image (`gcloud compute images create --source-uri …`).
5. Writes the image self-link into Pulumi config key `nagareImageSelfLink`.

Dry-run and the real build print the local and target systems, builder URI, project, zone, instance,
and shared-project status. The generated SSH config and builders file live under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/nix-builder/` with directory mode `0700` and
file mode `0600`. `nix build` receives that builders value explicitly; ambient
`/etc/nix/machines` cannot select another VM.

The remote builder is on-demand and costs money while it runs. The shipped
`nagare-nix-builder-proxy` starts exactly the displayed GCP instance and opens its IAP tunnel; every
gcloud call carries the displayed project and zone. To use a deliberate shared builder in another
project, both select it and acknowledge that exact project:

```bash
NAGARE_BUILDER_PROJECT=shared-build-project \
  nagare host-image --allow-shared-builder shared-build-project --dry-run
NAGARE_BUILDER_PROJECT=shared-build-project \
  nagare host-image --allow-shared-builder shared-build-project
```

A foreign builder project without the matching flag refuses before Nix or gcloud. The
`setup-nix-builder.sh` / `nix-builder-startup.sh.tpl` scripts manage the builder lifecycle; tear it
down when you're done iterating on the image.

## Boot the VM

With `nagareImageSelfLink` now set, declare and create the VM:

```bash
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/first-vm"
nagare infra-preview --save-plan "$plan_dir"
nagare infra-up --plan "$plan_dir" --yes
```

Pulumi creates `nagare-01` from the image, attaches the static IP and the
`nagare-data` disk, and runs it under the `nagare-node` service account.

The VM's first boot intentionally has no private age key. Its Tailscale autoconnect unit fails fast
with `age key missing` before the upstream client can print an interactive login URL. Complete the
handoff through project-confined IAP:

```bash
nagarectl host place-age-key --context prod --key-file /secure/path/prod-host.agekey
nagarectl --context prod server status
```

Placement verifies the local and remote SHA-256 values, installs the module-configured path as
`root:root` mode `0400`, reruns sops-nix, and starts Tailscale. Do not proceed to tailnet-only access
until `server status` reports `OK host age key`.

That command is enough for first creation. For an existing VM, confirm the
preview replaces only the boot instance while preserving `nagare-data`, apply,
then immediately set `nagare:vmDeletionProtection` back to `true` and apply
again. Never unprotect the persistent data disk merely to replace the boot
image.

## Verify first boot

```bash
pulumi -C infra/pulumi stack output publicIp     # VM has its static IP
nagarectl --context prod server status           # host age key is OK

# Once you can reach the host (see Accessing the host):
# - the data disk is mounted and formatted:
#     mount | grep /var/lib/nagare
#     ls /var/lib/nagare          # victoria-metrics, …, local-path (no stray lost+found)
# - k3s is up:
#     systemctl status k3s
#     kubectl get nodes           # nagare-01  Ready
```

The first-boot VM acceptance suite starts five independent blank data disks. In
every sample, formatting completes before fsck and mount, the layout is created
on the mounted ext4 filesystem, k3s reports exactly one `Ready` node, and the
boot ID remains unchanged. It also stops the mount dependency chain and proves
that starting only the mount recovers layout and k3s without a reboot. If a
fresh cloud boot still misbehaves, work through
[Troubleshooting](troubleshooting.md) before assuming new breakage.

The dedicated host-age-key VM check separately proves the intentional missing state, checksum and
`root:root 0400` placement, sops secret appearance, and successful Tailscale autoconnect without an
interactive login.

## Next

Get a shell and a working `kubectl`:
**[Accessing the host →](accessing-the-host.md)**
