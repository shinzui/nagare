# Example: SQLite on a durable PVC (with optional Litestream backup)

> **Status:** 🟡 Built and **dry-run-verified**. The typed config renders a `1Gi`
> `local-path` PVC and a `/data` volumeMount offline today. The live legs (deploy,
> write a row, roll, confirm survival, Litestream → GCS) run against `nagare-01`;
> where the VM is down they are **dry-run verified; live deferred**, like the rest
> of [Deploying apps](../../../docs/user/deploying-apps.md).

A tiny typed Nagare app that keeps a SQLite database on a **durable
PersistentVolumeClaim** mounted at `/data`. It is the real-PVC successor to the
sibling [`../sqlite-litestream/`](../sqlite-litestream/), which keeps its database
on an ephemeral `emptyDir` and is applied with raw `kubectl` — its own comment
says *"a real app would use a PVC on the data disk."* This is that real app:

|  | `sqlite-litestream` (old) | `sqlite-pvc-litestream` (this) |
| --- | --- | --- |
| Storage | `emptyDir` (ephemeral) | `local-path` PVC (durable) |
| Deployed via | raw `kubectl apply` | `nagarectl deploy` (typed config) |
| Survives pod restart? | ❌ no | ✅ yes |

The whole difference is one line in [`nagare/Config.hs`](nagare/Config.hs):
`attachVolume "data" "1Gi" "/data"`. The app ([`app.py`](app.py)) is a
dependency-free Python stdlib HTTP server: `GET /add` inserts a timestamped row
into `/data/app.db`, `GET /` returns the row count.


## Deploy and verify

```bash
# 1. Render offline (no cluster) — confirm the PVC + volumeMount appear, PVC first.
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs --dry-run

# 2. Deploy for real (builds app.py into an image, pushes, applies PVC then Service).
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs

# 3. Confirm the volume is provisioned and bound.
nagarectl storage list sqlite-pvc-litestream

# 4. Insert a row, then read the count (via the app's own URL).
URL=$(nagarectl app get sqlite-pvc-litestream | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/add"          # -> notes rows: 1

# 5. Roll a new revision (or delete the pod) to prove durability.
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs

# 6. Read the count again from the NEW pod — the row SURVIVED (durable PVC).
curl -fsS "$URL/"             # -> notes rows: 1   (emptyDir would show 0)
```

Expected (the acceptance):

```text
# Step 1: the dry-run prints the PVC manifest BEFORE the Service
--- PersistentVolumeClaim manifest ---
...
  name: nagare-vol-sqlite-pvc-litestream-data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
--- Knative Service manifest ---
...
        volumeMounts:
        - name: data
          mountPath: /data
          readOnly: false

# Step 3: storage list shows the bound 1Gi volume
  VOLUME      PVC                                    SIZE    STATUS    NODE-PATH
  data        nagare-vol-sqlite-pvc-litestream-data  1Gi     Bound     /var/lib/nagare/local-path/pvc-...

# Step 6: the row survived the revision roll — durable PVC, unlike emptyDir
notes rows: 1
```


## Optional: Litestream continuous backup

`nagarectl storage snapshot` takes *point-in-time* copies; for a *continuously
written* database, Litestream streams the write-ahead log to GCS so you can
recover to any point. The typed Nagare model has no sidecar field yet, so add the
Litestream container to the deployed Service as a supplementary step, using
[`litestream.yml`](litestream.yml) (replica URL
`gcs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db`).

```bash
# Put the litestream config in a ConfigMap, then patch a second container onto the
# Service's pod template that mounts the same PVC and runs `litestream replicate`.
kubectl create configmap sqlite-pvc-litestream-litestream -n personal \
  --from-file=litestream.yml=cluster/examples/sqlite-pvc-litestream/litestream.yml
# (see ../sqlite-litestream/deployment.yaml for the exact sidecar container spec:
#  image litestream/litestream:0.3.13, args [replicate -config /etc/litestream.yml],
#  env GCE_METADATA_HOST=169.254.169.254, and the /data + config volumeMounts.)

# Confirm Litestream replicated to GCS:
gsutil ls "gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db/"
```

> **Why `GCE_METADATA_HOST=169.254.169.254`?** Pods on this cluster cannot resolve
> `metadata.google.internal` by name, so the Google ADC library must be pointed at
> the metadata IP directly to find the node service account. Same trick the old
> example uses.


## Clean up

```bash
nagarectl app delete sqlite-pvc-litestream
# retention = Retain keeps the PVC (and the database) after the app is deleted.
# To reclaim the disk (DESTRUCTIVE — data is gone):
kubectl delete pvc -n personal nagare-vol-sqlite-pvc-litestream-data
```

See **[Persistent storage](../../../docs/user/persistent-storage.md)** for the
full feature guide and **[Backups & disaster recovery](../../../docs/user/backups-and-disaster-recovery.md)**
for restoring a volume.
