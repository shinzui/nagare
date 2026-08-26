# Secrets

> **Status:** ✅ Supported. Host secrets use sops-nix, runtime app secrets use
> `nagarectl secret` (see [Environment and secrets](env-and-secrets.md)), and
> Context-owned encrypted cluster bootstrap Secrets use the `sops -d | kubectl apply`
> loop below. Backing up the private recovery keys remains an operator duty.

Nagare keeps secrets simple and rebuildable: **encrypted in operator-owned
configuration**, decrypted only where they are consumed. A source checkout may
track encrypted examples or a personal deployment's ciphertext, but released
Nagare payloads never package cluster credentials. There's no external secret
manager — sops + age is simpler to operate and to rebuild from scratch.

```text
Host secrets:     sops-nix  (decrypt at NixOS activation)
App runtime:      nagarectl secret (Kubernetes Secret per app/scope)
Cluster bootstrap secrets: sops + age (`sops -d | kubectl apply`)
Encrypted files:  operator-owned and safe to back up or commit to a private config repo
```

External Secrets Operator + GCP Secret Manager is an explicit non-goal for v1.

---

## How host secrets work (sops-nix) — ✅

The encrypted secrets file is **operator-owned and may be committed to a private
configuration repository**; the **private age key lives only on the host**,
never in Git. At activation, sops-nix decrypts the file
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

3. Apply: `nagare host-switch` (`just host-switch` in a contributor checkout;
   see [Day-2 host changes](day-2-host-changes.md)).

## App runtime secrets — ✅

Use `nagarectl secret` for per-app runtime, build, and preview secrets. Values
are read from stdin, written to Kubernetes `Secret` objects, and consumed by the
rendered Service through optional `envFrom` blocks. See
[Environment and secrets](env-and-secrets.md) for the full command reference.

## Cluster bootstrap secrets — ✅

Store each platform bootstrap credential as a normal Kubernetes `Secret`
manifest under the active context's directory:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/
```

Set `NAGARE_CLUSTER_SECRETS_DIR` to use an explicitly managed directory instead.
A source checkout also accepts its tracked `cluster/secrets/` as a compatibility
fallback when the context-owned directory does not exist. Encrypt manifests in
place with `sops -e -i`; put an operator-owned `.sops.yaml` in that directory
with a rule like the following (replace the recipient with the public key for
your workstation/recovery policy):

```yaml
creation_rules:
  - path_regex: .*\.ya?ml$
    encrypted_regex: "^(data|stringData)$"
    age: age1REPLACE_WITH_OPERATOR_PUBLIC_RECIPIENT
```

This leaves kind, name, namespace, and keys readable.
The checkout's `cluster/secrets/notes-db-url.yaml` remains a worked example, not
part of the released payload.

Apply every encrypted manifest idempotently:

```bash
context="$(nagarectl context current)"
secret_dir="${NAGARE_CLUSTER_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/${context}}"
for f in "${secret_dir}"/*.yaml; do
  sops -d "$f" | kubectl apply -f -
done
```

The plaintext flows only through the pipe; it is never written back to the
working tree.

## Rotation

- **Tailscale auth key:** edit the sops file, `nagare host-switch`.
- **GitHub App forge credentials (optional):** follow the operator-owned App,
  key, installation, and live-token procedures in
  [Forge credentials](forge-credentials.md).
- **Host age key:** regenerate, re-encrypt all secrets to the new public key,
  update `.sops.yaml`, re-place the private key on the host, rebuild.
- **App runtime secrets:** use `nagarectl secret set/delete`.
- **Cluster bootstrap secrets:** edit the context-owned encrypted file, then
  re-apply the loop above. `nagare observability` resolves the same directory
  and fails closed when a required Secret is absent.

## What's committed vs. what isn't

| Back up or commit to a private configuration repo | Never commit or package |
| --- | --- |
| context-owned `*.yaml` sops-**encrypted** secrets | the host age **private** key |
| operator-owned `.sops.yaml` (public keys + rules) | decrypted secret values |
| NixOS config referencing secrets | the k3s kubeconfig (`k3s.yaml`) |

## Next

Make the whole machine rebuildable:
**[Backups and disaster recovery →](backups-and-disaster-recovery.md)**
