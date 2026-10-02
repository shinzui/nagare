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
> Every inventory-managed host switch starts with `nagarectl host plan` and applies
> through `just host-switch REVIEW_DIR`, which reverts itself unless a
> fresh SSH login proves you still have access (ExecPlan 115,
> [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)).

Once a host is booted, you do **not** rebuild the image and recreate the VM
for ordinary config changes. Operator inputs live in the context-owned generated flake; reusable
platform behavior remains in Nagare's packaged NixOS modules. Push the selected configuration
to the running host with a saved host review. The image build pipeline is
only for the *initial* boot (or a deliberate from-scratch rebuild).

Keep the three host identities distinct. `NAGARE_INSTANCE_NAME` names the GCE VM for Google Cloud
and IAP operations. `nagarectl host name` reads the generated NixOS and Tailscale name from the
active context's `host.nix`; that logical name selects the flake attribute and ordinary SSH target.
For deliberate troubleshooting, `NAGARE_HOST_ATTR` can select another flake attribute and
`NAGARE_SSH_HOST` can select another logical SSH destination. Neither variable renames or selects a
GCE resource, and an upgrade transaction ignores ambient values for both.

---

## Apply a change

Before the first switch to the guarded registry refresher, inspect
`nagare-registry-pull` in `personal` and `nagare-system`. Existing unmarked
Secrets are refused so the host timer cannot adopt another owner's credential.
If you have verified each Secret came from the previous Nagare host timer,
explicitly add `nagare.dev/delegated-owner=host-registry-timer` to it before the
switch. The timer thereafter checks ownership and resource version, records its
source SHA-256 and token expiry on the Secret, and updates only those two
namespaces. It patches only `default` ServiceAccount's registry pull reference;
other pull references or a conflicting owner annotation cause refusal.

Edit the operator inputs in the context-owned `host.nix`, preserving the accepted
`flake.nix` and `flake.lock`, then:

```bash
nagarectl host plan --save-plan /private/reviews/host-change
nagarectl host apply /private/reviews/host-change --yes
# Equivalent application:
just host-switch /private/reviews/host-change
scripts/host-switch.sh --dry-run
```

Keep the accepted `flake.lock` unchanged: this command reconciles operator inputs
within the selected payload. It refuses dependency re-pinning; admitted-context
platform upgrades remain unavailable. If accepted host intent binds an age key and
you change the configuration, supply `--age-key-file /secure/host.agekey` when
planning. Set `NAGARE_HOST_AGE_KEY_FILE` to that same file for apply or resume.
Reviews contain its digest, never its private bytes. Unchanged reviews can verify
an already healthy host without reopening the private key file.

For credential placement or replacement, retain both keys privately until the
new encrypted secrets work, then save a separate explicit review:

```bash
nagarectl host place-age-key --key-file /secure/host.agekey --save-plan /private/reviews/host-key
# To replace a different installed key, add --force to the planning command.
NAGARE_HOST_AGE_KEY_FILE=/secure/host.agekey nagarectl host apply /private/reviews/host-key --yes
```

Replacement binds the exact observed old key digest. The transport checks it again
before streaming, activates the secret services, and records a private receipt
bound to the saved plan. An explicit credential review still requires this receipt
when the desired key already exists after a failed prior operation. An old healthy Tailnet connection cannot certify a failed
secret activation. Resume can retry activation with the already written new key
without rewriting it; a different installed key refuses. The value check is not
an atomic compare-and-swap against unrelated root writers. Avoid concurrent manual
key changes during the reviewed operation. A failed key write remains unresolved;
keep both private source files for explicit recovery.

The no-argument recipe and direct `host-switch.sh` mutation are compatibility paths
only before inventory admission. The script's `--dry-run` remains read-only.

Never activate a configuration on a Nagare host any other way (no direct `nixos-rebuild`
activation, no `switch-to-configuration`). The reviewed host transport does the following, in order:

1. **Refuses the evaluation fixture.** If the attribute is the in-repo `nixos#nagare-01`
   fixture (`nagare.host.evaluationFixture = true`), it exits 3.
2. **Refuses a lockout before building.** It reads your public key
   (`NAGARE_SSH_PUBLIC_KEY_FILE`, else `${SSH_KEY:-~/.ssh/id_ed25519}.pub`) and exits 3 with
   `refusing: the configuration does not authorize … applying it would lock you out` unless the
   configuration's deploy user authorizes that key.
3. **Builds and copies.** By default the `x86_64-linux` toplevel is built from the workstation
   (an `aarch64-darwin` workstation dispatches to the remote Linux Nix builder, the same mechanism
   as the image build — see [Host image and first boot](host-image-and-boot.md)) and copied with
   `nix copy --no-check-sigs --to ssh-ng://deploy@<host-name>`. With `--build-on-host` it is built
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
`ssh deploy@<host-name> true`. By then the host has reactivated the previous configuration by
itself. A reboot would also boot the previous one, because the boot default never changed.
Investigate the configuration before switching again. If SSH still fails after the window, use
the serial console boot menu in
[Accessing the host](accessing-the-host.md#path-3-serial-console-boot-menu-break-glass).

## Switch over an IAP tunnel

If Tailscale is unavailable, tunnel SSH port 22 to localhost and point every SSH connection the
switch opens (the closure copy, arm, activate, the fresh verification login, commit) at the
tunnel with `NIX_SSHOPTS`. `-o HostName=127.0.0.1` keeps the logical target named
`deploy@<host-name>` while connecting through the tunnel:

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
`--ssh-public-key-file` flags while retaining the same payload, then save and apply
a host review. `mutableUsers =
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
  [Accessing the host](accessing-the-host.md#path-3-serial-console-boot-menu-break-glass)).
- **The boot menu waits ten seconds** on every boot (`boot-recovery.nix`) and keeps the last 20
  generations. That is the cost of the break-glass path.
- **`nofail` on the data disk** means a disk problem won't wedge the whole boot —
  but it also means a missing disk boots a host with no `/var/lib/nagare`. Check
  the mount after risky storage changes.

## Verify

```bash
host_name="$(nagarectl host name)"
ssh "deploy@$host_name" 'systemctl status k3s; mount | grep /var/lib/nagare'
kubectl get nodes        # still Ready after the switch
```

## Next

With a healthy host, bootstrap the cluster platform:
**[Cluster bootstrap →](cluster-bootstrap.md)**


## Reviewed VM power

For an accepted cloud VM, save a power review and apply it separately:

```bash
nagarectl host stop --operation-id stop-20261002 --save-plan ./stop-review
nagarectl inventory apply ./stop-review --yes
nagarectl host start --operation-id start-20261002 --save-plan ./start-review
nagarectl inventory apply ./start-review --yes
```

Use a new operation ID for each intended transition. Reusing an unchanged ID
preserves its completed outcome; it does not request another stop or start.
Planning and recovery use the Compute API and accepted cloud inventory, so they
work while the host is off. The review pins its numeric instance ID and checks
it again before sending the name-based provider request. This is a precondition
check, not an atomic provider compare-and-swap. A lost acknowledgement remains
in the original transaction: resume proves the desired state on the same
instance or leaves it unresolved, without resending an uncertain power request.
Power-state completion does not establish guest or application readiness.
