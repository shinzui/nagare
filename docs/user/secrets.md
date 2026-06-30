# Secrets

> **Status:** 🟡 In progress. Host secrets via sops-nix work today. Runtime app
> secrets are managed with `nagarectl secret` (see
> [Environment and secrets](env-and-secrets.md)). Git-encrypted cluster bootstrap
> secrets via sops+age are still planned.

Nagare keeps secrets simple and rebuildable: **encrypted in Git**, decrypted on
the host at activation. There's no external secret manager — sops + age is
simpler to operate and to rebuild from scratch, which is the whole point of a
disposable single-node platform.

```text
Host secrets:     sops-nix  (decrypt at NixOS activation)
App runtime:      nagarectl secret (Kubernetes Secret per app/scope)
Cluster bootstrap secrets: sops + age (planned decrypt into Kubernetes Secrets)
Encrypted files:  committed to Git
```

External Secrets Operator + GCP Secret Manager is an explicit non-goal for v1.

---

## How host secrets work (sops-nix) — ✅

The encrypted secrets file is **committed to Git**; the **private age key lives
only on the host**, never in Git. At activation, sops-nix decrypts the file
using that key and writes each secret to a runtime path.

Configuration (`nixos/hosts/nagare-01/configuration.nix`):

```nix
sops.defaultSopsFile = ./secrets/nagare-01.yaml;
sops.age.keyFile = "/var/lib/sops-nix/age-key.txt";

sops.secrets."tailscale/authkey" = { mode = "0400"; };
```

`nixos/.sops.yaml` records which age key encrypts which files:

```yaml
keys:
  - &host_nagare01 age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99
creation_rules:
  - path_regex: hosts/nagare-01/secrets/.*\.yaml$
    key_groups:
      - age:
          - *host_nagare01
```

That `age1…` value is the host's **public** key — anyone can encrypt *to* it;
only the host (holding the matching private key) can decrypt.

### One-time setup: place the host age key

Before first boot, the host's age **private** key must exist at
`/var/lib/sops-nix/age-key.txt` (mode `0400`, owned by root). The matching
public key is the one in `.sops.yaml`. This is what lets sops-nix decrypt during
activation; without it the host can't bring up anything that depends on a secret
(e.g. Tailscale won't get its auth key).

> Keep the private key off Git and out of the image. Store it in your own
> password manager / offline backup so a from-scratch rebuild can re-place it.
> If you regenerate it, you must re-encrypt every secrets file to the new public
> key and update `.sops.yaml`.

## Add or edit a host secret — ✅

1. Edit the encrypted file (sops opens it decrypted, re-encrypts on save):

   ```bash
   sops nixos/hosts/nagare-01/secrets/nagare-01.yaml
   ```

2. Declare it in `configuration.nix` (mode/owner as needed) and consume it in
   the module that needs it, by its decrypted path
   (`config.sops.secrets."<name>".path`). The Tailscale key is the worked
   example: `tailscale.nix` reads
   `config.sops.secrets."tailscale/authkey".path`.

3. Apply: `just host-switch` (see [Day-2 host changes](day-2-host-changes.md)).

## App runtime secrets — ✅

Use `nagarectl secret` for per-app runtime, build, and preview secrets. Values
are read from stdin, written to Kubernetes `Secret` objects, and consumed by the
rendered Service through optional `envFrom` blocks. See
[Environment and secrets](env-and-secrets.md) for the full command reference.

## Cluster bootstrap secrets — 🔭 Planned

Platform-level Kubernetes secrets that should be reproducible from Git, such as
bootstrap credentials for optional cluster services, will be managed with
sops+age encrypted files and rendered into Kubernetes `Secret` objects. The exact
wiring is still planned. Until then, use explicit templates or `kubectl create
secret` for those platform bootstrap cases.

## Rotation

- **Tailscale auth key:** edit the sops file, `just host-switch`.
- **Host age key:** regenerate, re-encrypt all secrets to the new public key,
  update `.sops.yaml`, re-place the private key on the host, rebuild.
- **App runtime secrets:** use `nagarectl secret set/delete`.
- **Cluster bootstrap secrets:** until the sops renderer exists, update the
  explicit template or recreate the Kubernetes Secret.

## What's committed vs. what isn't

| In Git | Never in Git |
| --- | --- |
| `*.yaml` sops-**encrypted** secrets | the host age **private** key |
| `.sops.yaml` (public keys + rules) | decrypted secret values |
| NixOS config referencing secrets | the k3s kubeconfig (`k3s.yaml`) |

## Next

Make the whole machine rebuildable:
**[Backups and disaster recovery →](backups-and-disaster-recovery.md)**
