# Day-2 host changes

> **Status:** 🟡 In progress (EP-3)
>
> `nixos-rebuild switch --target-host` works against `nagare-01` over Tailscale.
> The `--sudo` flag is required because you deploy as the non-root `deploy` user.

Once a host is booted, you do **not** rebuild the image and recreate the VM
for ordinary config changes. Operator inputs live in the context-owned generated flake; reusable
platform behavior remains in Nagare's packaged NixOS modules. Push the selected configuration
to the running host with `nixos-rebuild switch`. The image build pipeline is
only for the *initial* boot (or a deliberate from-scratch rebuild).

---

## Apply a change

Regenerate operator inputs with `nagarectl host init --force`, or edit the relevant reusable module
under `nixos/` when contributing platform behavior, then:

```bash
just host-switch
scripts/host-switch.sh --dry-run  # inspect the exact flake, host, and command
```

What each flag does:

- `--flake <context-host-flake>#<host-name>` — build the selected generated flake's configuration.
- `--target-host deploy@<instance-name>` — activate it on the context's remote host, normally over
  Tailscale.
- `--sudo` — the `deploy` user isn't root, so activation runs under `sudo`.
  Passwordless sudo for `wheel` (set in `security.nix`) makes this unattended.

The build happens on a builder; because the workstation is `aarch64-darwin`, the
`x86_64-linux` closure is built on the remote Linux Nix builder (same mechanism
as the image build — see [Host image and first boot](host-image-and-boot.md)).
`deploy` is a Nix `trusted-user` (`@wheel`), so it can receive the pushed
closure.

## Break-glass switch over IAP

If Tailscale is unavailable, tunnel SSH port 22 to localhost and make the VM
both the build host and target host. The `NIX_SSHOPTS` value applies the tunnel
port and the same declarative operator identity to every SSH connection opened
by `nixos-rebuild`:

```bash
TUNPID=$(scripts/iap-ssh.sh tunnel nagare-01 22 2222)
trap 'kill "$TUNPID" 2>/dev/null || true' EXIT

export NIX_SSHOPTS="-p 2222 -i ${SSH_KEY:-$HOME/.ssh/id_ed25519} \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null"
host_flake="$(nagarectl host path)"
nixos-rebuild switch --flake "$host_flake#${NAGARE_INSTANCE_NAME:-nagare-01}" \
  --build-host deploy@127.0.0.1 --target-host deploy@127.0.0.1 --sudo

unset NIX_SSHOPTS
kill "$TUNPID"
trap - EXIT
```

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
- **Don't lock yourself out.** A bad `security.nix` or `networking.firewall`
  change applied via `switch` can sever SSH. Keep the IAP break-glass path
  (`scripts/iap-ssh.sh`) in mind, and consider `nixos-rebuild test` (activates
  without making it the boot default) for risky changes so a reboot reverts.
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
