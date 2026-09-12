---
type: Runbook
title: "Day-2 host changes"
description: "Apply, verify, and recover from routine Nagare host configuration changes after initial provisioning."
docId: DOC-11
tags: [host, nixos, maintenance, operations]
generated:
  by: human:nadeem
  at: 2026-09-12T21:26:55Z
---

# Day-2 host changes

> **Status:** 🟡 In progress (EP-3)
>
> Every host switch goes through `just host-switch`, which reverts itself unless a
> fresh SSH login proves you still have access (ExecPlan 115,
> [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)).

Once a host is booted, you do **not** rebuild the image and recreate the VM
for ordinary config changes. Operator inputs live in the context-owned generated flake; reusable
platform behavior remains in Nagare's packaged NixOS modules. Push the selected configuration
to the running host with `just host-switch`. The image build pipeline is
only for the *initial* boot (or a deliberate from-scratch rebuild).

---

## Apply a change

Regenerate operator inputs with `nagarectl host init --force`, or edit the relevant reusable module
under `nixos/` when contributing platform behavior, then:

```bash
just host-switch
scripts/host-switch.sh --dry-run        # inspect the flake, attribute, target, key file, window
scripts/host-switch.sh --build-on-host  # build on the host instead of the workstation
```

Never activate a configuration on a Nagare host any other way (no direct `nixos-rebuild`
activation, no `switch-to-configuration`). `just host-switch` does the following, in order:

1. **Refuses the evaluation fixture.** If the attribute is the in-repo `nixos#nagare-01`
   fixture (`nagare.host.evaluationFixture = true`), it exits 3.
2. **Refuses a lockout before building.** It reads your public key
   (`NAGARE_SSH_PUBLIC_KEY_FILE`, else `${SSH_KEY:-~/.ssh/id_ed25519}.pub`) and exits 3 with
   `refusing: the configuration does not authorize … applying it would lock you out` unless the
   configuration's deploy user authorizes that key.
3. **Builds and copies.** By default the `x86_64-linux` toplevel is built from the workstation
   (an `aarch64-darwin` workstation dispatches to the remote Linux Nix builder, the same mechanism
   as the image build — see [Host image and first boot](host-image-and-boot.md)) and copied with
   `nix copy --no-check-sigs --to ssh-ng://deploy@<instance>`. With `--build-on-host` it is built
   straight into the host's store. `deploy` is a Nix `trusted-user` (`@wheel`), so it can receive
   the closure. `--no-check-sigs` is required because paths built on the remote builder are
   unsigned, and `nix copy` otherwise rejects them on the workstation side even though the host
   trusts `deploy` (`lacks a signature by a trusted key`).
4. **Arms a rollback, activates, verifies, commits.** It prints:
   - `ARMED prev=… new=… seconds=600`: an on-host systemd timer will reactivate the boot-default
     generation after the window (`NAGARE_SWITCH_CONFIRM_SECONDS`, default 600).
   - `ACTIVATE_RC=<n>`: the new configuration is running but is **not** the boot default. The
     code is informational; pre-existing failed units make it non-zero.
   - `fresh login and sudo verified`: a brand-new SSH connection (no multiplexing) ran
     `sudo -n true` and saw the new system.
   - `COMMITTED new=…`: the timer is cancelled and the new configuration is the boot default.
     Exit 0.

If verification fails, it prints `NOT COMMITTED: access could not be verified …` and exits 4.
**Do not run further commands against the host.** Wait for the window to pass, then try a fresh
`ssh deploy@<instance> true`. By then the host has reactivated the previous configuration by
itself. A reboot would also boot the previous one, because the boot default never changed.
Investigate the configuration before switching again. If SSH still fails after the window, use
the serial console boot menu in
[Accessing the host](accessing-the-host.md#path-3-serial-console-boot-menu-break-glass).

## Switch over an IAP tunnel

If Tailscale is unavailable, tunnel SSH port 22 to localhost and point every SSH connection the
switch opens (the closure copy, arm, activate, the fresh verification login, commit) at the
tunnel with `NIX_SSHOPTS`. `-o HostName=127.0.0.1` keeps the target named `deploy@<instance>`
while connecting through the tunnel:

```bash
TUNPID=$(scripts/iap-ssh.sh tunnel nagare-01 22 2222)
trap 'kill "$TUNPID" 2>/dev/null || true' EXIT

export NIX_SSHOPTS="-o HostName=127.0.0.1 -p 2222 -i ${SSH_KEY:-$HOME/.ssh/id_ed25519} \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"
just host-switch
# or, to build on the VM instead of the workstation:
# scripts/host-switch.sh --build-on-host

unset NIX_SSHOPTS
kill "$TUNPID"
trap - EXIT
```

Keep the tunnel open until the script prints `COMMITTED` or `NOT COMMITTED`.

The active target context supplies the project, zone, host identity, and absolute generated-flake
path used by the IAP wrapper.

## How the host config is organized

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/
  flake.nix                     # imports the pinned Nagare NixOS flake
  flake.lock                    # exact Nagare/nixpkgs/sops-nix inputs
  host.nix                      # public operator inputs: identity, registry, SSH keys, paths
  secrets.yaml                  # sops-encrypted host secrets

Nagare payload:
  nixos/flake.nix               # exports nixosModules.nagare-host + lib.mkNagareSystem
  modules/nagare-host.nix       # nagare.host option contract + module composition
  configuration-base.nix        # shared base: GCP module, flakes, timezone, stateVersion
  modules/gcp.nix               # services.gcp: guest agent, hardened sshd, sysctls, journald caps
  .sops.yaml                    # which age keys encrypt which secret files
  hosts/nagare-01/
    configuration.nix           # imports the host modules + wires sops secrets
    networking.nix              # hostname, DNS resolvers, firewall
    storage.nix                 # data-disk format + mount + subdir layout
    users.nix                   # consumes the configured deploy user + SSH keys
    security.nix                # sshd hardening, sudo, OS Login off
    k3s.nix                     # k3s server flags + ordering
    tailscale.nix               # tailnet join via sops auth key
```

The generated `host.nix` supplies `nagare.host.*`; the reusable module declares the sops defaults.

## Common day-2 tasks

### Add or change an operator SSH key

Re-run `nagarectl host init --force` with the complete set of repeated
`--ssh-public-key-file` flags, then `just host-switch`. `mutableUsers =
false`, so the declarative key list is authoritative — keys not listed there are
removed on activation.

### Add a host secret

Add it to the generated flake's `secrets.yaml` and reference it from the reusable module. See
[Secrets](secrets.md). A new
secret that a service consumes (like the Tailscale key) needs both the sops
entry and the consuming module, then a `host-switch`.

### Change k3s flags

Edit `nixos/hosts/nagare-01/k3s.nix`. The current server flags are
`--disable=traefik --write-kubeconfig-mode=0640 --write-kubeconfig-group=wheel
--secrets-encryption
--default-local-storage-path=/var/lib/nagare/local-path` (ServiceLB is
intentionally left enabled — Kourier needs a LoadBalancer). k3s is ordered after
the data-disk mount and the `nagare-data-layout` unit; preserve that ordering if
you touch it, or k3s may start before its storage path exists.

### Change firewall / DNS

`networking.nix`. Note the deliberate `8.8.8.8`/`8.8.4.4` resolvers and
`nohook resolv.conf` — both are load-bearing fixes, not arbitrary. See
[Troubleshooting](troubleshooting.md#name-resolution-fails-on-the-vm).

## Safety notes

- **`stateVersion` is `26.05`.** Never bump it on a running system without a
  migration plan — it pins the semantics of stateful options.
- **Lockouts are guarded in three layers.** (1) The in-repo `nixos#nagare-01` evaluation
  fixture refuses activation by any tool through a NixOS pre-switch check, and a configuration
  carrying its placeholder key without being marked as the fixture fails to build.
  (2) `just host-switch` refuses a configuration that does not authorize your key. (3) Every
  switch reverts itself within the confirmation window, and on any reboot, unless a fresh SSH
  login and `sudo` succeed. If all of that fails, the GRUB menu on the serial console lets you
  boot an earlier generation (see
  [Accessing the host](accessing-the-host.md#path-3-serial-console-boot-menu-break-glass)). In
  Claude Code sessions, `.claude/hooks/guard_host_mutation.py` also blocks direct activation
  commands.
- **The boot menu waits ten seconds** on every boot (`boot-recovery.nix`) and keeps the last 20
  generations. That is the cost of the break-glass path.
- **`nofail` on the data disk** means a disk problem won't wedge the whole boot —
  but it also means a missing disk boots a host with no `/var/lib/nagare`. Check
  the mount after risky storage changes.

## Verify

```bash
ssh deploy@nagare-01 'systemctl status k3s; mount | grep /var/lib/nagare'
kubectl get nodes        # still Ready after the switch
```

## Next

With a healthy host, bootstrap the cluster platform:
**[Cluster bootstrap →](cluster-bootstrap.md)**
