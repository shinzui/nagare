# Forge credentials

> **Status:** 🟡 In progress. The host refresher, focused tests, and operator
> workflow are implemented. The two GitHub Apps must still be registered,
> installed, encrypted into the active context, deployed, and live-verified.

Nagare gives runtime workloads short-lived GitHub credentials through two stable
Kubernetes Secrets in the `personal` namespace:

```text
nagare-forge-read   broad selected-repository read access, never write access
nagare-forge-write  narrow selected-repository write and pull-request access
```

The host refreshes each role independently every thirty minutes. Workloads know
only a role Secret name and receive `GITHUB_TOKEN`; they never receive a GitHub
App ID, installation ID, private key, or personal access token.

## Deployment record

Complete this record before enabling the timers. It is the reviewable source of
truth for the non-secret GitHub state. Do not record App IDs, installation IDs,
private keys, or installation tokens here.

| Setting | Read role | Write role |
| --- | --- | --- |
| Registration owner | Pending GitHub registration | Pending GitHub registration |
| App slug | Pending GitHub registration | Pending GitHub registration |
| Installation owner | Pending GitHub registration | Pending GitHub registration |
| Webhooks | Disabled; no event subscriptions | Disabled; no event subscriptions |
| Repository permissions | Metadata read; Contents read | Metadata read; Contents read/write; Pull requests read/write |
| Selected repositories | Pending: enumerate every repository explicitly | Pending: enumerate the disposable publishing target and each approved production target explicitly |
| Private-key owner | Nagare host operator | Nagare host operator |
| Installation-scope owner | Portfolio repository owner | Portfolio repository owner |

Every repository listed in one role must belong to the same GitHub user or
organization account. One role has one installation ID. If a role must cross
account boundaries, stop and revise the refresher schema before creating another
installation.

## Register and install the Apps

An owner of the account that owns the selected repositories performs this
one-time setup in GitHub under **Settings → Developer settings → GitHub Apps →
New GitHub App**. Create two private Apps with globally unique names derived from
`nagare-forge-read` and `nagare-forge-write`. The uniqueness suffix is external
metadata; it never changes the Kubernetes Secret names above.

For both Apps:

- use the Nagare repository URL as the homepage;
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
owner using **Only select repositories**. The read installation contains the
explicit mirror boundary. The write installation contains only a disposable
probe/publishing repository and narrow production publishing targets. Copy the
App ID from the App settings page and the installation ID from the installed
App settings URL directly into sops; do not put either in a plaintext note.

## Encrypt the bootstrap inputs

Host inputs belong to the active context's operator-owned host flake, not to the
checked-in `nagare-01` compatibility fixture. Resolve and edit it with:

```bash
host_root="$(nagarectl host path --context prod)"
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

Review the active context and apply the reusable host module:

```bash
just context-show
just host-switch
ssh nagare-01 'systemctl status nagare-forge-read-refresh.timer nagare-forge-write-refresh.timer --no-pager'
```

Both timers should show `active (waiting)`. Force an immediate independent
refresh and inspect metadata only:

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

There is no automated expiration alert in this change. Operators should alert
when either timer's last result is failed or when a decoded `expires_at` has less
than twenty minutes remaining. Never put the token value itself in an alert,
metric label, journal query, or support artifact.

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
to a nonexistent value, deploy, record the live Secret resource version and token
hash, and start only that role's service. The service must fail while both values
remain unchanged. Restore and deploy the valid value immediately.

Reboot the host after the access matrix passes. Both timers must return to
`active (waiting)`, and the read probe must succeed without any manual token
entry.

## Rotate or recover

To rotate an App private key, generate a second key in GitHub, replace the sops
value, deploy, force that role's refresher, and verify its access matrix. Revoke
the old key only after the new key has minted and published a valid token.

To change repository scope or permissions, make the narrow GitHub change, update
the deployment record above, force refresh, and rerun the full access matrix. An
installation token copied before a scope reduction remains live until GitHub
expires or revokes it.

If a private key is exposed, generate and deploy a replacement before revoking
the old key when a safe recovery window exists. If a live installation token is
exposed, suspend affected workloads, rotate or revoke the App installation/key as
appropriate, and republish. Deleting the Kubernetes Secret alone does not revoke
a copied bearer token.
