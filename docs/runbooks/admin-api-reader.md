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

After `just infra-up` has applied the account, from the operator's private repository, with the
context's project active:

```bash
email=$(pulumi -C infra/pulumi stack output adminApiReaderEmail)
gcloud iam service-accounts keys create reader.json --iam-account "$email"
sops --encrypt --in-place reader.json
```

Keep `reader.json` only in the operator repository's sops material. The deployment (EP-198)
decrypts it into a Kubernetes Secret mounted read-only into the admin API pod, together with
`adminApiProjectNumber` as the server's `--project-number`. The server exchanges the key for an
access token at `https://www.googleapis.com/oauth2/v4/token` (gogol's service-account flow) and
refreshes it once for all waiting requests.

## Rotate and revoke

Create the new key as above, replace the sops file, roll the admin API, then delete the old key:

```bash
gcloud iam service-accounts keys list --iam-account "$email"
gcloud iam service-accounts keys delete OLD_KEY_ID --iam-account "$email"
```

Deleting every key revokes the API's access at once; the API then answers
`store_credentials_unavailable` and readiness fails. Never print a key or a token into evidence.
