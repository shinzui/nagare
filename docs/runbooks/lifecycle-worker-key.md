# The lifecycle worker's key

The lifecycle event worker (`nagare-events`, EP-235 in
[MasterPlan 31](../masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md))
runs in a cloud context as its own service account, `nagare-events@<project>.iam.gserviceaccount.com`.
Pulumi declares the account and its grants when the stack sets `enableLifecycleWorker: true`; it never
creates a key ([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)).

What the account can do, and nothing else, all bound per bucket with predefined roles:

- read objects under `nagare/<context>/inventory/` in `<project>-nagare-pulumi-state`, and that
  bucket's metadata for the owning-project check (`storage.objectViewer`, `storage.bucketViewer`,
  conditioned on the bucket and the inventory prefix);
- create, overwrite and read objects under `nagare/<context>/lifecycle/v1/` only (`storage.objectUser`,
  conditioned on that prefix);
- read the backup bucket's objects and metadata (`storage.objectViewer`, `storage.bucketViewer`).

It cannot write the inventory, write or delete a backup, or act outside these buckets. It can list
object names in the state bucket. In the cluster its ServiceAccount may get only the signing Secrets
the `platform:lifecycle-events` scope names; adding a database schedule or a webhook subscription
re-reviews that scope.

## Enable

```bash
nagarectl context create <context> --force --enable-lifecycle-events --save-plan DIR
nagarectl context apply DIR --yes
```

The cloud stage then plans the account (catalog section `lifecycleWorkerEnabled`). After it has
applied and before the platform stage is planned, from the operator's private repository with the
context's project active:

```bash
gcloud iam service-accounts keys create worker.json --iam-account "nagare-events@<project>.iam.gserviceaccount.com"
secrets="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>"
{ printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: nagare-events-worker\n  namespace: nagare-system\nstringData:\n  key.json: |\n'
  sed 's/^/    /' worker.json; } > "$secrets/lifecycle-worker.yaml"
sops --config "$secrets/.sops.yaml" --encrypt --in-place "$secrets/lifecycle-worker.yaml"
rm worker.json
```

The Secret must hold exactly `key.json`. The platform stage binds it as a private member mounted
read-only into the worker; a changed key rolls the pod. The worker sends nothing until the context
also sets `--enable-lifecycle-delivery`; a candidate or rehearsal context leaves it off.

A local context needs no key: the worker reads backups as the read-only MinIO user its scope's grant
Job creates. Its lifecycle state is the workstation directory beside the inventory, mounted writable
when the local cluster is created, so an existing local context must be rebuilt before it can run
the worker.

## Rotate and revoke

Create a new key, replace `lifecycle-worker.yaml` as above, plan and apply the platform stage, then
delete the old key with `gcloud iam service-accounts keys delete`. Disabling the worker
(`--disable-lifecycle-events`) removes the Deployment and keeps all lifecycle state; backups and
deployments are unaffected.
