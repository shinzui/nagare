# The admin API's reader credential

The admin API reads a context's GCS inventory as a dedicated service account (EP-196 in
[MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md)).
Pulumi declares the account and its two read-only grants when the stack sets
`enableAdminApiReader: true`; it never creates a key, because a key in Pulumi state would put
operator secret material in this repository's state ([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)).

What the account can do, and nothing else:

- read the objects `nagare/<context>/inventory/format.json`, `…/head.json` and `…/scopes/*` in
  `<project>-nagare-pulumi-state` (custom role `nagareInventoryObjectReader`, with an object-name
  IAM condition);
- read that bucket's metadata, for the owning-project check (custom role
  `nagareInventoryBucketReader`).

It cannot list, write, or read reviews, native payloads, journals or Pulumi state. The server
also asks only for the read-only storage scope and refuses writes before any request.

## Create the key

The context opts in with `NAGARE_ADMIN_API_ENABLED=1` (through `nagarectl context review`). Its
cloud stage then plans the reader account as reviewed cloud members (catalog section
`adminApiReaderEnabled`), with `enableAdminApiReader: true`. A context with an explicit
`NAGARE_INVENTORY_STORE_URL` also gets that URL's bucket and prefix as `stateBucket` and
`adminApiInventoryPrefix`, so the grant names its real inventory. The platform stage needs the key
and the project number, so do the following after the cloud stage has applied and before
planning the platform stage, from the operator's private repository, with the context's project
active:

```bash
email=$(pulumi -C infra/pulumi stack output adminApiReaderEmail)
pulumi -C infra/pulumi stack output adminApiProjectNumber   # the context's NAGARE_PROJECT_NUMBER
gcloud iam service-accounts keys create reader.json --iam-account "$email"
```

Wrap the key in the Secret the deployment binds, encrypt it in the context's cluster-secrets
directory (beside `grafana-admin.yaml`), and delete the plaintext:

```bash
secrets="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>"
{ printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: nagare-admin-api-reader\n  namespace: nagare-system\nstringData:\n  key.json: |\n'
  sed 's/^/    /' reader.json; } > "$secrets/admin-api-reader.yaml"
sops --config "$secrets/.sops.yaml" --encrypt --in-place "$secrets/admin-api-reader.yaml"
rm reader.json
```

The Secret must hold exactly `key.json`. The platform's `admin-api` scope (EP-198) decrypts it
into a private member mounted read-only into the admin API pod, and passes
`NAGARE_PROJECT_NUMBER` as the server's `--project-number`. The server exchanges the key for an
access token at `https://www.googleapis.com/oauth2/v4/token` (gogol's service-account flow) and
refreshes it once for all waiting requests.

## Rotate and revoke

Create the new key as above, replace the sops file, run the platform transition that re-accepts the
`admin-api` scope, then delete the old key:

```bash
gcloud iam service-accounts keys list --iam-account "$email"
gcloud iam service-accounts keys delete OLD_KEY_ID --iam-account "$email"
```

Deleting every key revokes the API's access at once; the API then answers
`store_credentials_unavailable` and readiness fails. Never print a key or a token into evidence.
