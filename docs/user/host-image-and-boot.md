# Host image and first boot

> **Status:** 🟡 In progress (EP-3)
>
> The NixOS flake, the `nagare-01` host config, and the image build/upload
> pipeline exist; `nagare-01` has been booted from a baked image and the data
> disk auto-formats on first boot. What's still being firmed up is reliable
> cluster readiness right after boot — see [Troubleshooting](troubleshooting.md).

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

Two NixOS outputs are produced from **one shared module list** so they never
drift (`nixos/flake.nix`):

- `packages.x86_64-linux.nagare-image` — the GCE image
  (`config.system.build.image`, a directory containing one `*.raw.tar.gz`).
- `nixosConfigurations.nagare-01` — the day-2 `nixos-rebuild` target.

Both include the upstream `google-compute-image.nix` module, so the day-2 target
has a root filesystem and bootloader matching exactly what's baked into the
image. (Putting the GCE module only in the image path is a known trap — it
breaks `nixosConfigurations.nagare-01` evaluation. It's correctly shared here.)

## What the image config contains

`nixos/hosts/nagare-01/` configures:

- **k3s** (`k3s.nix`) — `role = server`, Traefik disabled, ServiceLB kept,
  kubeconfig mode `0640 root:wheel`, Secret encryption enabled, local-path
  storage at `/var/lib/nagare/local-path`.
  Ordered after the data-disk mount and the directory-layout unit.
- **Storage** (`storage.nix`) — auto-formats the blank data disk to ext4 on
  first boot (idempotent), mounts it `nofail` at `/var/lib/nagare`, then creates
  the subdirectory layout *after* the mount.
- **Networking** (`networking.nix`) — hostname, public DNS resolvers
  (`8.8.8.8`/`8.8.4.4` — the GCE metadata resolver is unreachable on this VM),
  firewall (`22`/`80`/`443`, trust `tailscale0`).
- **Security** (`security.nix`) — key-only SSH, no root login, `PerSourcePenalties`
  off, Google OS Login disabled, passwordless sudo for `wheel`.
- **Users** (`users.nix`) — the `deploy` user with the operator's SSH key.
- **Tailscale** (`tailscale.nix`) — joins the tailnet using a sops-provided
  auth key, with `--ssh` enabled.
- **sops-nix** (`configuration.nix`) — decrypts secrets at activation using an
  age key on the host.

The rationale for the non-obvious choices is in [Troubleshooting](troubleshooting.md)
— they were each the fix for a real first-boot failure.

## Prerequisite: the host age key and secrets

Before the host can boot cleanly, sops-nix needs to decrypt
`nixos/hosts/nagare-01/secrets/nagare-01.yaml`. That requires:

- The host's **age private key** placed on the VM at
  `/var/lib/sops-nix/age-key.txt` (mode `0400`, root) **before first boot**.
- The secrets file encrypted to the host's age **public** key (recorded in
  `nixos/.sops.yaml`).

The one secret managed at this stage is `tailscale/authkey` (a Tailscale
pre-auth key), consumed by `tailscale.nix`. See [Secrets](secrets.md) for how
the age key is generated, where it's stored, and how to add/rotate secrets.

> On the from-zero path these are Steps 3–4 of the
> [bring-your-own-project onboarding](onboarding-bring-your-own-project.md):
> the operator SSH key (`users.nix`), the host age key, and the Tailscale key all
> go in **before first boot**, in that order. This page is the "how"; the runbook
> fixes the "when."

## Build and register the image

If this is a deliberate rebuild of an existing VM, first set
`nagare:vmDeletionProtection` to `false` and apply that protection-only change
as described in
[Provisioning with Pulumi → Review replacements and protected resources](provisioning-with-pulumi.md#review-replacements-and-protected-resources).
Do this before `host-image` writes a replacement-causing image self-link. First
creation needs no such step.

One recipe does the whole pipeline:

```bash
just host-image      # runs scripts/upload-images.sh
```

`scripts/upload-images.sh` (the details are owned by the script):

1. Ensures an x86_64-linux Nix builder is available
   (`scripts/setup-nix-builder.sh` provisions an on-demand one if needed).
2. Builds `.#packages.x86_64-linux.nagare-image` on it.
3. Uploads the resulting `*.raw.tar.gz` to the active context's
   `$NAGARE_IMAGE_BUCKET` (`<project>-nagare-images` by default).
4. Registers it as a GCE image (`gcloud compute images create --source-uri …`).
5. Writes the image self-link into Pulumi config key `nagareImageSelfLink`.

The remote builder is on-demand and costs money while it runs. The
`setup-nix-builder.sh` / `nix-builder-startup.sh.tpl` scripts manage its
lifecycle; tear it down when you're done iterating on the image.

## Boot the VM

With `nagareImageSelfLink` now set, declare and create the VM:

```bash
just infra-up        # pulumi up — now includes the nagare-01 instance
```

Pulumi creates `nagare-01` from the image, attaches the static IP and the
`nagare-data` disk, and runs it under the `nagare-node` service account.

That command is enough for first creation. For an existing VM, confirm the
preview replaces only the boot instance while preserving `nagare-data`, apply,
then immediately set `nagare:vmDeletionProtection` back to `true` and apply
again. Never unprotect the persistent data disk merely to replace the boot
image.

## Verify first boot

```bash
pulumi -C infra/pulumi stack output publicIp     # VM has its static IP

# Once you can reach the host (see Accessing the host):
# - the data disk is mounted and formatted:
#     mount | grep /var/lib/nagare
#     ls /var/lib/nagare          # victoria-metrics, …, local-path (no stray lost+found)
# - k3s is up:
#     systemctl status k3s
#     kubectl get nodes           # nagare-01  Ready
```

> **Known gap (EP-3):** confirming `kubectl get nodes` = `Ready` end-to-end was
> initially blocked by an sshd host-access issue and the blank-disk/mount
> ordering. Those fixes are committed (DNS resolver, auto-format, post-mount
> layout, `PerSourcePenalties`/OS Login). If a fresh boot still misbehaves,
> work through [Troubleshooting](troubleshooting.md) before assuming new breakage.

## Next

Get a shell and a working `kubectl`:
**[Accessing the host →](accessing-the-host.md)**
