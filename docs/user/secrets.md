# Secrets

> **Status:** 🟡 In progress — host secrets via sops-nix work today
> (one secret: the Tailscale auth key). Cluster secrets (sops+age for Kubernetes)
> and the broader secret tooling are 🔭 **Planned (EP-7)**.

Nagare keeps secrets simple and rebuildable: **encrypted in Git**, decrypted on
the host at activation. There's no external secret manager — sops + age is
simpler to operate and to rebuild from scratch, which is the whole point of a
disposable single-node platform.

```text
Host secrets:     sops-nix  (decrypt at NixOS activation)
Cluster secrets:  sops + age (decrypt into Kubernetes Secrets)   [planned, EP-7]
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

## Cluster secrets (apps) — 🔭 Planned (EP-7)

App secrets referenced from a typed config via `EnvSecretRef` / the `secretEnv`
preset (see [Config reference](config-reference.md)) will be managed the same
way — sops+age encrypted in Git, decrypted into Kubernetes `Secret` objects in
the app's namespace. The exact wiring (a sops decrypt step in the deploy flow,
or a sops-rendered manifest applied during bootstrap) is owned by EP-7 and isn't
implemented yet. Until then, create app secrets manually with `kubectl create
secret` in the target namespace.

## Rotation

- **Tailscale auth key:** edit the sops file, `just host-switch`.
- **Host age key:** regenerate, re-encrypt all secrets to the new public key,
  update `.sops.yaml`, re-place the private key on the host, rebuild.
- **App/cluster secrets:** (planned) edit the sops file and re-run the deploy /
  bootstrap step that materializes them.

## What's committed vs. what isn't

| In Git | Never in Git |
| --- | --- |
| `*.yaml` sops-**encrypted** secrets | the host age **private** key |
| `.sops.yaml` (public keys + rules) | decrypted secret values |
| NixOS config referencing secrets | the k3s kubeconfig (`k3s.yaml`) |

## Next

Make the whole machine rebuildable:
**[Backups and disaster recovery →](backups-and-disaster-recovery.md)**
