# sqlite-litestream — continuous SQLite backup sample (EP-7 M2)

A minimal app that writes to a SQLite database at `/data/app.db`, with a
**Litestream** sidecar that streams the database's write-ahead log to the GCS
backup bucket continuously. Litestream authenticates to GCS with Application
Default Credentials — on this single node that is the VM's attached service
account, which EP-2 grants `roles/storage.objectAdmin` on the backup bucket, so
no key files are involved.

## Deploy

```bash
kubectl create configmap sqlite-litestream-config \
  --namespace personal \
  --from-file=litestream.yml=cluster/examples/sqlite-litestream/litestream.yml \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cluster/examples/sqlite-litestream/deployment.yaml
```

## Verify the backup is flowing

```bash
kubectl logs deploy/sqlite-litestream -n personal -c litestream | tail
gsutil ls "gs://$(cd infra/pulumi && pulumi stack output backupBucket)/litestream/app.db/"
```

You should see Litestream log `initialized db` / `write wal segment` lines and
generation/WAL objects under `litestream/app.db/`.

## Restore (scratch-first)

```bash
BACKUP_BUCKET="$(cd infra/pulumi && pulumi stack output backupBucket)" \
  scripts/restore-sqlite.sh /tmp/restore-app.db
sqlite3 /tmp/restore-app.db "SELECT count(*) FROM notes;"
```

The restore writes to a scratch file, never over a live database. Only after you
compare row counts do you promote it (copy into the app's volume / data disk).
See `docs/runbooks/disaster-recovery.md`.
