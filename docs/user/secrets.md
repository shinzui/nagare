# Secrets

> **Status:** ✅ Supported. Host secrets use sops-nix, runtime app secrets use
> `nagarectl secret` (see [Environment and secrets](env-and-secrets.md)), and
> Git-encrypted cluster bootstrap Secrets use the `sops -d | kubectl apply`
> loop below. Backing up the private recovery keys remains an operator duty.

Nagare keeps secrets simple and rebuildable: **encrypted in Git**, decrypted on
the host at activation. There's no external secret manager — sops + age is
simpler to operate and to rebuild from scratch, which is the whole point of a
disposable single-node platform.

```text
Host secrets:     sops-nix  (decrypt at NixOS activation)
App runtime:      nagarectl secret (Kubernetes Secret per app/scope)
Cluster bootstrap secrets: sops + age (`sops -d | kubectl apply`)
Encrypted files:  committed to Git
```

External Secrets Operator + GCP Secret Manager is an explicit non-goal for v1.

---

## How host secrets work (sops-nix) — ✅

The encrypted secrets file is **committed to Git**; the **private age key lives
only on the host**, never in Git. At activation, sops-nix decrypts the file
using that key and writes each secret to a runtime path.

The generated context `host.nix` supplies the encrypted file and on-host age-key path through the
reusable `nagare.host` module:

```nix
nagare.host.sopsDefaultFile = ./secrets.yaml;
nagare.host.ageKeyFile = "/var/lib/sops-nix/age-key.txt";
```

Your sops configuration records which age key encrypts the context file. It may live beside your
operator configuration or in your own configuration repository; it is not part of the Nagare
release. A rule has the same shape as:

```yaml
keys:
  - &host_nagare01 age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99
creation_rules:
  - path_regex: secrets\.yaml$
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

1. Edit the context's encrypted file (sops opens it decrypted, re-encrypts on save):

   ```bash
   host_root="$(nagarectl host path --context prod)"
   sops "$host_root/secrets.yaml"
   ```

2. Declare it in the reusable Nagare host module (mode/owner as needed) and consume it in
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

## Cluster bootstrap secrets — ✅

Commit each platform bootstrap credential as a normal Kubernetes `Secret`
manifest under `cluster/secrets/`, then encrypt it in place with `sops -e -i`.
The repository's `.sops.yaml` encrypts only `data` and `stringData`, leaving the
kind, name, namespace, and keys readable in review. The existing
`cluster/secrets/notes-db-url.yaml` is the worked example.

Apply every encrypted manifest idempotently:

```bash
for f in cluster/secrets/*.yaml; do
  sops -d "$f" | kubectl apply -f -
done
```

The plaintext flows only through the pipe; it is never written back to the
working tree.

## Rotation

- **Tailscale auth key:** edit the sops file, `just host-switch`.
- **GitHub App forge credentials:** follow the key, installation, and live-token
  procedures in [Forge credentials](forge-credentials.md).
- **Host age key:** regenerate, re-encrypt all secrets to the new public key,
  update `.sops.yaml`, re-place the private key on the host, rebuild.
- **App runtime secrets:** use `nagarectl secret set/delete`.
- **Cluster bootstrap secrets:** edit with
  `sops cluster/secrets/<file>.yaml`, then re-apply the loop above.

## What's committed vs. what isn't

| In Git | Never in Git |
| --- | --- |
| `*.yaml` sops-**encrypted** secrets | the host age **private** key |
| `.sops.yaml` (public keys + rules) | decrypted secret values |
| NixOS config referencing secrets | the k3s kubeconfig (`k3s.yaml`) |

## Next

Make the whole machine rebuildable:
**[Backups and disaster recovery →](backups-and-disaster-recovery.md)**
