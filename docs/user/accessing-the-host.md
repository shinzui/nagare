---
type: Guide
title: "Accessing the host"
description: "Reach a Nagare host through Tailscale SSH or an IAP break-glass tunnel and obtain cluster access."
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

There are two ways onto `nagare-01`, by design. Tailscale is the day-to-day
path; the IAP tunnel is the break-glass path that works even if Tailscale is
down. Port 22 is **never** open to the public internet — the firewall only
admits SSH from Google's IAP range (`35.235.240.0/20`).

---

## Path 1: Tailscale SSH (primary)

`nagare-01` joins your tailnet at boot (`tailscale.nix`, with `--ssh`), so once
it's up you can reach it by its tailnet name from any device on the same
tailnet:

```bash
ssh deploy@nagare-01           # via Tailscale MagicDNS
```

The firewall trusts the `tailscale0` interface, so node-local services (like the
kube-apiserver on `:6443`) are reachable over the tailnet without being exposed
publicly. This is what makes `kubectl` and `nixos-rebuild --target-host`
convenient — they ride the tailnet.

> Set up a host alias so `nagare-01` resolves. With Tailscale MagicDNS this is
> automatic; otherwise add an entry to `~/.ssh/config` pointing the context's instance name at
> its tailnet IP. The deploy user and operator keys come from the context-owned flake created by
> `nagarectl host init`.

## Path 2: IAP tunnel (break-glass)

When Tailscale isn't available (first boot before the node joins, a tailnet
outage, debugging the network stack), tunnel in over Google IAP.

Pulumi even prints a ready command:

```bash
pulumi -C infra/pulumi stack output sshCommand
# gcloud compute ssh nagare-01 --project=tan-nb-exp --zone=us-west1-a --tunnel-through-iap
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
   ssh deploy@nagare-01 sudo cat /etc/rancher/k3s/k3s.yaml > ./k3s.yaml
   ```

2. Edit the `server:` field from `https://127.0.0.1:6443` to the host's tailnet
   address (`https://nagare-01:6443`), since you trust `tailscale0` in the
   firewall.

3. Point `kubectl` at it:

   ```bash
   export KUBECONFIG=$PWD/k3s.yaml
   kubectl get nodes        # nagare-01  Ready
   just status              # pods + Knative services across namespaces
   ```

> Keep this kubeconfig out of Git — it contains cluster credentials. If you
> prefer not to copy it locally, run `kubectl` directly on the host over SSH.

## Verify

You have access when:

- `ssh deploy@nagare-01 true` (Tailscale) or
  `scripts/iap-ssh.sh ssh nagare-01 -- true` (IAP) succeeds, and
- `kubectl get nodes` shows `nagare-01  Ready`.

If SSH connects and then drops *"connection closed at userauth"*, that's the
documented sshd-penalties / OS-Login issue — see
[Troubleshooting](troubleshooting.md#ssh-connection-closed-right-after-the-handshake).

## Next

Make host configuration changes safely:
**[Day-2 host changes →](day-2-host-changes.md)**
