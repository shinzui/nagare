# Nagare cluster-access runbook

How to reach the single-node `nagare-01` k3s cluster from an operator workstation.
Every step is a command plus the observation that confirms it worked. All cloud
work targets project **`tan-nb-exp`**, region **`us-west1`**, zone
**`us-west1-a`** (see `CLAUDE.md` — no other project, even for reads).

## The cluster

Nagare runs on one GCE VM, **`nagare-01`** (NixOS + k3s). To save cost the VM is
often left **`TERMINATED`**; start it before any cluster work:

```bash
gcloud compute instances start nagare-01 --zone=us-west1-a
```

Allow ~1–2 minutes after the start returns for sshd and the k3s service to come
up. Confirm the API is live (see SSH below):

```text
NAME        STATUS   ROLES           AGE   VERSION
nagare-01   Ready    control-plane   ...   v1.35.x+k3s1
```

## SSH access — the `deploy` user

`nagare-01` is reached over an IAP tunnel (direct SSH is firewalled). Use the
repo wrapper `scripts/iap-ssh.sh`. The working login is the dedicated NixOS user
**`deploy`**, authenticating with **`~/.ssh/id_ed25519`** (the `shinzui@sungkyung`
key authorized in `nixos/hosts/nagare-01/users.nix`):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 \
  scripts/iap-ssh.sh ssh nagare-01 -- 'echo ok; id'
```

Expected:

```text
ok
uid=1000(deploy) gid=100(users) groups=100(users),1(wheel)
```

**Pitfall — do not rely on OS Login defaults.** `iap-ssh.sh` defaults `SSH_USER`
to the OS Login name (`nadeem_topagentnetwork_com`) and `SSH_KEY` to
`id_ed25519`/`id_rsa`. The OS Login path fails with
`Permission denied (publickey)` on this host even though `id_ed25519` is also
registered in OS Login — always pass `SSH_USER=deploy` explicitly.

## Running cluster commands

The `deploy` user has `sudo` (wheel). Run cluster operations through k3s's bundled
kubectl on the VM:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 \
  scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get nodes'
```

The kubeconfig on the host is `/etc/rancher/k3s/k3s.yaml` (root-readable;
`server: https://127.0.0.1:6443`). To run kubectl locally instead, open a tunnel
to port 6443 (`scripts/iap-ssh.sh tunnel nagare-01 6443 <local-port>`), copy the
kubeconfig, and rewrite its `server` to `https://127.0.0.1:<local-port>` — the
k3s serving cert includes `127.0.0.1`, so TLS validates over the tunnel.

**Pitfall — the local default kubectl context is the wrong cluster.** A
workstation here typically has its default context pointed at an unrelated GKE
cluster (`tan-cluster`/`sennari`). Never run nagare cluster commands against the
default context; use `sudo k3s kubectl` on the VM, or an explicit
`--kubeconfig`/`KUBECONFIG` pointing at the tunneled k3s config.
