---
type: Guide
title: "Accessing the host"
description: "Reach a Nagare host through Tailscale SSH, an IAP tunnel, or the serial console boot menu, and obtain cluster access."
docId: DOC-3
tags: [host, ssh, tailscale, iap, kubectl]
generated:
  by: human:nadeem
  at: 2026-08-25T18:46:42Z
---

# Accessing the host

> **Status:** 🟡 In progress (EP-3)
>
> Tailscale SSH and the IAP tunnel both work; the `scripts/iap-ssh.sh` wrapper
> exists specifically because plain `gcloud … --tunnel-through-iap` is broken on
> macOS OpenSSH 10.x (see below).

There are two SSH paths onto a Nagare host, and they intentionally use different names. Tailscale
uses the NixOS host name, which defaults from the context (`prod-nagare` for context `prod`). The
IAP tunnel uses the GCE instance name, which may remain `nagare-01` in each separate project.
Tailscale is the day-to-day path; IAP works even if Tailscale is down. Both use the same operator
key, so neither helps if a configuration removed that key. For that case there is a break-glass
path that needs no SSH key (the serial console boot menu), and a last resort (the rescue disk).
Port 22 is **never** open to the public internet — the firewall only admits SSH from Google's IAP
range (`35.235.240.0/20`).

GCE startup scripts (`startup-script` metadata) **do not run** on Nagare's NixOS
image. They are not a recovery tool; do not use them.

---

## Path 1: Tailscale SSH (primary)

The `prod` context's host joins your tailnet at boot (`tailscale.nix`, with `--ssh`), so once it is
up you can reach it by its context-derived tailnet name from any device on the same tailnet:

```bash
ssh deploy@prod-nagare         # via Tailscale MagicDNS
```

The firewall trusts the `tailscale0` interface, so node-local services (like the
kube-apiserver on `:6443`) are reachable over the tailnet without being exposed
publicly. This is what makes `kubectl` and `nixos-rebuild --target-host`
convenient — they ride the tailnet.

`nagarectl host init --context prod` defaults the OS and Tailscale name to `prod-nagare` while
leaving the GCE instance name independent. If the context name cannot become a lowercase DNS label,
or if you deliberately need another name, pass `--host-name NAME`. An implicit default already
recorded by a sibling context is refused. Check the effective public host configuration at any time:

```bash
nagarectl host show --context prod | rg 'hostName'
#     hostName = "prod-nagare";
```

With Tailscale MagicDNS the name resolves automatically; otherwise add an entry to
`~/.ssh/config` pointing `prod-nagare` at its tailnet IP. The deploy user and operator keys come
from the same context-owned host flake.

## Path 2: IAP tunnel

When Tailscale isn't available (first boot before the node joins, a tailnet
outage, debugging the network stack), tunnel in over Google IAP.

Pulumi even prints a ready command:

```bash
pulumi -C infra/pulumi stack output sshCommand
# gcloud compute ssh nagare-01 --project=<your-project> --zone=<your-zone> --tunnel-through-iap
```

### The macOS caveat — use `scripts/iap-ssh.sh`

On **macOS with OpenSSH 10.x**, `gcloud compute ssh --tunnel-through-iap` is
broken (a kex-handshake bug that eats the connection). The repo ships a wrapper
that opens the IAP tunnel with `gcloud compute start-iap-tunnel` and routes
OpenSSH through `socat` as the `ProxyCommand`, managing the tunnel lifecycle for
you:

```bash
# Run a command on the host:
scripts/iap-ssh.sh ssh nagare-01 -- systemctl status k3s

# Copy a file up or down (exactly one side may be remote):
scripts/iap-ssh.sh scp ./local.txt nagare-01:/tmp/local.txt
scripts/iap-ssh.sh scp nagare-01:/etc/hostname ./hostname.txt

# Stream a root-owned file you can't read as the SSH user:
scripts/iap-ssh.sh recv-file nagare-01 /etc/rancher/k3s/k3s.yaml ./k3s.yaml

# Open a long-lived TCP tunnel (e.g. to an HTTP API on the VM) and get its PID:
scripts/iap-ssh.sh tunnel nagare-01 6443 6443
```

Environment knobs the wrapper honors:

| Var | Default | Meaning |
| --- | --- | --- |
| `ZONE` | gcloud's active zone (`us-west1-a`) | The instance's zone. |
| `SSH_USER` | `NAGARE_SSH_USER`, then `deploy` | Linux user to log in as. |
| `SSH_KEY` | first readable of `~/.ssh/id_ed25519`, `~/.ssh/id_rsa` | Private key. |

The wrapper enforces the same project isolation as everything else: the active
gcloud project must match the selected target context.

> **Note on OS Login vs. the `deploy` user.** The host config *disables* Google
> OS Login (`security.nix`) and authenticates the `deploy` user via its
> declarative `authorized_keys`. So for both paths, log in as `deploy` with the
> operator key. (The VM metadata still has `enable-oslogin=TRUE` at the GCE
> layer, but the host's sshd ignores it.)

## Path 3: Serial console boot menu (break-glass)

Use this when SSH is refused on both paths even after a `NOT COMMITTED` switch's confirmation
window has passed. It needs no SSH key. `boot-recovery.nix` puts the GRUB menu on the GCE serial
port with a ten-second timeout and keeps the last 20 generations. Rebooting the instance takes
the platform down for a few minutes, so only do this when you have no other way in.

1. Make sure your account can use the serial console (IAM
   `roles/compute.instanceAdmin.v1` on the project, or an equivalent custom role).
2. Enable the serial port on the instance. This is a cloud mutation; in agent sessions it needs
   your approval:

   ```bash
   gcloud compute instances add-metadata nagare-01 --metadata=serial-port-enable=TRUE
   ```

3. Connect to the serial console and leave it open:

   ```bash
   gcloud compute connect-to-serial-port nagare-01
   ```

4. From a second terminal, reset the instance:

   ```bash
   gcloud compute instances reset nagare-01
   ```

5. Within ten seconds, in the serial console, choose **NixOS - All configurations**, then the
   newest generation that is *older* than the bad one, and press Enter.
6. Once it has booted, confirm `ssh deploy@prod-nagare true` over Tailscale or
   `scripts/iap-ssh.sh ssh nagare-01 -- true` over IAP. Then fix the configuration and run
   `just host-switch`, which makes a verified generation the boot default again. The generation
   you picked in the menu is only booted once.
7. Disable the serial port again:

   ```bash
   gcloud compute instances remove-metadata nagare-01 --keys=serial-port-enable
   ```

## Path 4: Rescue disk (last resort)

If the boot menu cannot help (for example, every listed generation lacks your key), stop the
instance, attach its boot disk to a temporary rescue VM, and repair the system profile from
there. The step-by-step procedure, with pass/fail gates, is Path B in
[ExecPlan 114](../plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md).

## Getting a working `kubectl`

k3s writes its root-owned kubeconfig on the host at
`/etc/rancher/k3s/k3s.yaml` (mode `0640`, group `wheel`). To drive the cluster
from your workstation:

1. Copy the kubeconfig down (it may be root-owned — use `recv-file`):

   ```bash
   scripts/iap-ssh.sh recv-file nagare-01 /etc/rancher/k3s/k3s.yaml ./k3s.yaml
   ```

   Or over Tailscale:

   ```bash
   ssh deploy@prod-nagare sudo cat /etc/rancher/k3s/k3s.yaml > ./k3s.yaml
   ```

2. Edit the `server:` field from `https://127.0.0.1:6443` to the host's tailnet
   address (`https://prod-nagare:6443`), since you trust `tailscale0` in the
   firewall.

3. Point `kubectl` at it:

   ```bash
   export KUBECONFIG=$PWD/k3s.yaml
   kubectl get nodes        # prod-nagare  Ready
   just status              # pods + Knative services across namespaces
   ```

> Keep this kubeconfig out of Git — it contains cluster credentials. If you
> prefer not to copy it locally, run `kubectl` directly on the host over SSH.

## Verify

You have access when:

- `ssh deploy@prod-nagare true` (Tailscale) or
  `scripts/iap-ssh.sh ssh nagare-01 -- true` (IAP) succeeds, and
- `kubectl get nodes` shows `prod-nagare  Ready`.

If SSH connects and then drops *"connection closed at userauth"*, that's the
documented sshd-penalties / OS-Login issue — see
[Troubleshooting](troubleshooting.md#ssh-connection-closed-right-after-the-handshake).

## Next

Make host configuration changes safely:
**[Day-2 host changes →](day-2-host-changes.md)**
