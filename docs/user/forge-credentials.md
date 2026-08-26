# Forge credentials

> **Status:** 🟢 Available as an opt-in host capability. Each operator supplies
> their own GitHub App registrations, repository selections, and encrypted keys.

Use this playbook when workloads deployed through Nagare need short-lived GitHub
credentials without receiving a personal access token or a GitHub App private
key. The capability is disabled by default. Enabling it publishes two stable
Kubernetes Secrets in a namespace chosen by the operator:

```text
nagare-forge-read   selected-repository read access, never write access
nagare-forge-write  narrow selected-repository write and pull-request access
```

The host refreshes each role independently every thirty minutes. Workloads know
only a role Secret name and receive `GITHUB_TOKEN`; they never receive a GitHub
App ID, installation ID, private key, or personal access token.

## Before you enable it

You need:

- a Nagare context with an operator-owned host flake;
- permission to create and install GitHub Apps for the account that owns the
  target repositories;
- an exact selected-repository boundary for each role; and
- access to the context's sops recipient and age-key recovery process.

One role has one installation ID, and one installation belongs to one GitHub
user or organization account. If a role must cover repositories owned by more
than one account, do not combine them under this interface; use separate Nagare
contexts or extend the module with an explicitly reviewed multi-installation
design.

## Record the operator-owned GitHub state

Copy the following table into documentation owned by the target context, beside
its host flake or in the operator's configuration repository. Do not fill it in
inside Nagare's release documentation: App registrations, installations, and
repository choices belong to the operator who enables the feature. Never record
App IDs, installation IDs, private keys, or installation tokens in the table.

| Setting | Read role | Write role |
| --- | --- | --- |
| Registration owner | `<GitHub user or organization>` | `<GitHub user or organization>` |
| App slug | `<globally unique read App slug>` | `<globally unique write App slug>` |
| Installation owner | `<same owner as selected repositories>` | `<same owner as selected repositories>` |
| Webhooks | Disabled; no event subscriptions | Disabled; no event subscriptions |
| Repository permissions | Metadata read; Contents read | Metadata read; Contents read/write; Pull requests read/write |
| Selected repositories | `<enumerate every repository>` | `<enumerate the disposable publishing target and each approved production target>` |
| Private-key owner | `<operator role or team>` | `<operator role or team>` |
| Installation-scope owner | `<repository owner or team>` | `<repository owner or team>` |

Treat this context-owned record as the reviewable source of truth for non-secret
GitHub state. Update it whenever permissions or repository selections change.

## Register and install two GitHub Apps

An owner of the account that owns the selected repositories performs this
one-time setup in GitHub under **Settings → Developer settings → GitHub Apps →
New GitHub App**. Create two private Apps with globally unique names derived from
`nagare-forge-read` and `nagare-forge-write`. A uniqueness suffix is external
metadata; it never changes the stable Kubernetes Secret names.

For both Apps:

- use a URL controlled by the operator as the homepage;
- leave callback and setup URLs empty and request no user authorization;
- disable webhooks and subscribe to no events;
- restrict installation to the owning account; and
- leave every repository, organization, account, and enterprise permission at
  **No access** except for the role-specific permissions below.

Set the read App's **Contents** permission to **Read-only**. Set the write App's
**Contents** and **Pull requests** permissions to **Read and write**. GitHub adds
Metadata read permission automatically. Do not grant Administration, Actions,
Workflows, Members, Secrets, or webhook permissions.

Generate exactly one private key for each App. Install each App on the recorded
owner using **Only select repositories**. The read installation contains only
the explicit mirror boundary. The write installation contains only a disposable
probe/publishing repository and narrow production publishing targets. Copy the
App ID from the App settings page and the installation ID from the installed App
settings URL directly into sops; do not put either in a plaintext note.

## Enable the host capability and encrypt its inputs

Choose the context and resolve its operator-owned host flake:

```bash
context_name="<context>"
host_root="$(nagarectl host path --context "$context_name")"
```

Add the opt-in block to that context's `host.nix` inside `nagare.host`:

```nix
forgeCredentials = {
  enable = true;
  namespace = "personal";
};
```

The namespace defaults to `personal`, so it may be omitted when that is the
desired target. When `enable` is false or absent, Nagare declares none of the six
sops inputs, services, timers, or Kubernetes Secrets described by this playbook.

Now edit the context's encrypted file:

```bash
sops "$host_root/secrets.yaml"
```

Add the following decrypted shape. The values remain inside the sops editor and
the encrypted file:

```yaml
github-app:
  read:
    app-id: <integer>
    installation-id: <integer>
    private-key: <PEM>
  write:
    app-id: <integer>
    installation-id: <integer>
    private-key: <PEM>
```

After sops saves successfully, remove the browser-downloaded plaintext PEM. The
encrypted context file is the recovery copy. Keep the context's age private key
backed up separately as described in [Secrets](secrets.md).

## Deploy and inspect rotation

Review the selected context and apply its host configuration using your normal
Nagare host workflow. For a context selected in the current shell:

```bash
just context-show
just host-switch
ssh nagare-01 'systemctl status nagare-forge-read-refresh.timer nagare-forge-write-refresh.timer --no-pager'
```

Both timers should show `active (waiting)`. Force an immediate independent
refresh and inspect metadata only, substituting your configured namespace and
host name when they differ:

```bash
ssh nagare-01 'sudo systemctl start nagare-forge-read-refresh.service'
kubectl -n personal get secret nagare-forge-read
kubectl -n personal get secret nagare-forge-read -o jsonpath='{.data.expires_at}' | base64 -d
```

The Secret contains exactly `token`, `GITHUB_TOKEN`, and `expires_at`. The two
token keys contain identical bytes. A successful run replaces the named Secret
without restarting consumers. The matching timer starts again thirty minutes
after its last activation, with up to two minutes of jitter.

To inspect failures without exposing credentials:

```bash
ssh nagare-01 'journalctl -u "nagare-forge-*-refresh.service" --since today --no-pager'
```

The helper logs only a role and a sanitized failure. It stores its JWT, response,
and curl authorization config in a root-only systemd runtime directory and
removes them on exit. A non-2xx or malformed GitHub response exits before
`kubectl apply`, so the previous Secret remains available until its expiry.

There is no automated expiration alert in this capability. Alert when either
timer's last result is failed or when a decoded `expires_at` has less than twenty
minutes remaining. Never put a token value in an alert, metric label, journal
query, or support artifact.

## Select a role from `nagare-dsl`

The typed config maps the environment-variable name to the same-named Secret
key. Construct the validated names, then use `EnvSecretRef`:

```haskell
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Types

forgeReadEnv :: Either String (Map.Map EnvName ScopedEnvVar)
forgeReadEnv = do
  variable <- first show (mkEnvName "GITHUB_TOKEN")
  secret <- first show (mkSecretName "nagare-forge-read")
  pure (Map.singleton variable (runtimeScoped (EnvSecretRef secret)))
```

Use `nagare-forge-write` only in the isolated publisher that needs it. Consumers
must not read the host sops paths, hold App private keys, or call GitHub's
installation-token endpoint themselves.

## Prove least privilege safely

Run authorization probes only against a disposable repository and with shell
tracing disabled. Decode tokens into mode-`0600` temporary files, print only
SHA-256 hashes, and remove the files afterward. The acceptance matrix is:

| Token | Installed read target | Installed disposable write target | Repository outside installation |
| --- | --- | --- | --- |
| `nagare-forge-read` | Read succeeds | Write returns 403 or 404 | Returns 403 or 404 |
| `nagare-forge-write` | Only if explicitly selected | Create and delete a probe file succeeds | Returns 403 or 404 |

Force each unit twice and verify that its token hash and expiry change. For a
failure-preservation drill, temporarily set one role's encrypted installation ID
to a nonexistent value, deploy, record the live Secret resource version and
token hash, and start only that role's service. The service must fail while both
values remain unchanged. Restore and deploy the valid value immediately.

Reboot the host after the access matrix passes. Both timers must return to
`active (waiting)`, and the read probe must succeed without manual token entry.
Store the redacted acceptance evidence with the context-owned deployment record,
not in Nagare's release documentation.

## Rotate, recover, or disable

To rotate an App private key, generate a second key in GitHub, replace the sops
value, deploy, force that role's refresher, and verify its access matrix. Revoke
the old key only after the new key has minted and published a valid token.

To change repository scope or permissions, make the narrow GitHub change, update
the context-owned deployment record, force refresh, and rerun the full access
matrix. An installation token copied before a scope reduction remains live until
GitHub expires or revokes it.

If a private key is exposed, generate and deploy a replacement before revoking
the old key when a safe recovery window exists. If a live installation token is
exposed, suspend affected workloads, rotate or revoke the App installation/key
as appropriate, and republish. Deleting the Kubernetes Secret alone does not
revoke a copied bearer token.

To disable the capability, first remove any workload references, set
`nagare.host.forgeCredentials.enable = false`, and switch the host. The systemd
units and sops declarations disappear from the configuration. Delete the two
Kubernetes Secrets and the operator-owned GitHub registrations only when their
credentials are no longer needed.
