# Example: uploaded files on a durable volume (+ snapshot/restore)

> **Status:** 🟡 Built and **dry-run-verified**. The typed config renders a `1Gi`
> `local-path` PVC and a `/uploads` volumeMount offline today. The live legs
> (deploy, upload, roll, confirm survival, snapshot to GCS, restore drill) run
> against `nagare-01`; where the VM is down they are **dry-run verified; live
> deferred**, like the rest of [Deploying apps](../../../docs/user/deploying-apps.md).

A tiny typed Nagare app that stores uploaded files on a **durable
PersistentVolumeClaim** mounted at `/uploads`. The app ([`app.py`](app.py)) is a
dependency-free Python stdlib HTTP server: `POST /upload/<name>` saves the request
body to `/uploads/<name>`, `GET /files/<name>` serves it back, `GET /` lists them.
The durable volume is one line in [`nagare/Config.hs`](nagare/Config.hs):
`attachVolume "uploads" "1Gi" "/uploads"`.


## Deploy, verify durability, snapshot, restore

```bash
# 1. Render offline (no cluster) — confirm the PVC + /uploads volumeMount.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs --dry-run

# 2. Deploy for real, then discover the app URL.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs
URL=$(nagarectl app get uploads-volume | sed -n 's/^URL:[[:space:]]*//p')

# 3. Upload a file.
echo "hello durable storage" > /tmp/hello.txt
curl -fsS --data-binary @/tmp/hello.txt "$URL/upload/hello.txt"   # -> stored hello.txt (22 bytes)

# 4. Confirm it is served back.
curl -fsS "$URL/files/hello.txt"          # -> hello durable storage

# 5. Roll the app to prove durability.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs

# 6. Re-fetch from the new pod — the file is STILL served (durable PVC).
curl -fsS "$URL/files/hello.txt"          # -> hello durable storage

# 7. Snapshot the volume to GCS and confirm the tarball landed.
export NAGARE_BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
nagarectl storage snapshot uploads-volume uploads
gsutil ls "gs://${NAGARE_BACKUP_BUCKET}/volumes/uploads-volume/uploads/"

# 8. Restore drill (scratch-first): restore the latest snapshot into a SCRATCH
#    PVC and list it — never over the live volume.
SNAP=$(gsutil ls "gs://${NAGARE_BACKUP_BUCKET}/volumes/uploads-volume/uploads/" | tail -1)
scripts/restore-volume.sh "$SNAP"
```

Expected (the acceptance):

```text
# Step 4 and Step 6: the upload is served, before AND after the roll
hello durable storage

# Step 7: the snapshot tarball exists under the documented GCS layout
gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/20260609T141503Z.tar.gz

# Step 8: the restore Job lists the restored tree from a SCRATCH PVC
--- restored tree (first 50 entries) ---
/restore
/restore/hello.txt
restored into scratch PVC 'vol-restore-scratch' in namespace 'personal'; ... Promote manually.
```

The restore is **scratch-first**: `scripts/restore-volume.sh` untars the snapshot
into a disposable `vol-restore-scratch` PVC and only lists it; it never touches
the live `/uploads` volume. Promote the verified contents back manually per the
[disaster-recovery runbook](../../../docs/runbooks/disaster-recovery.md).


## Clean up

```bash
nagarectl app delete uploads-volume
# retention = Retain keeps the PVC (and the uploads) after the app is deleted.
# To reclaim the disk (DESTRUCTIVE — uploads are gone):
kubectl delete pvc -n personal nagare-vol-uploads-volume-uploads
# Scratch PVC + restore Job from the drill, if any:
kubectl delete job nagare-restore-vol-restore-scratch pvc vol-restore-scratch -n personal --ignore-not-found
```

See **[Persistent storage](../../../docs/user/persistent-storage.md)** for the
full feature guide and **[Backups & disaster recovery](../../../docs/user/backups-and-disaster-recovery.md)**
for the restore procedure.
