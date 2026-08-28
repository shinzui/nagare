---
type: Guide
title: "Persistent storage"
description: "Declare, deploy, back up, restore, and operate persistent application volumes on Nagare."
docId: DOC-26
tags: [storage, volumes, backups, applications]
generated:
  by: human:nadeem
  at: 2026-06-30T23:08:36Z
---

# Persistent storage

> **Status:** 🟡 **Built and tested through render/unit coverage, with cloud GCS
> and local MinIO data-movement backends implemented.** The typed `volumes` model,
> renderer, deploy-time PVC provisioning, `nagarectl storage` commands, restore
> verb, and backup policy exist. Live cluster drills still depend on the target
> you are operating — though the **local MinIO snapshot/restore round-trip is now
> verified end-to-end** by `just local-smoke` (see
> [Local development](local-development.md#run-the-local-smoke-test)).

This guide is for **app developers whose app needs to keep data across restarts**
— a SQLite database, uploaded files, a generated cache. By default a Nagare app
is stateless: its Knative Service runs a container whose filesystem is wiped on
every pod restart or scale-to-zero. Declare a **volume** in your typed config and
Nagare provisions a durable disk, mounts it into your container, lets you inspect
it from the CLI, and can back it up to GCS in cloud mode or MinIO in local mode.


## Concepts

- A **volume** is a durable disk attached to your app, declared as one entry in
  the new `volumes` list on your `Deployment`. It has a name, a size, a mount
  path, an access mode, a read-only flag, and a retention policy.
- A **PersistentVolumeClaim (PVC)** is the Kubernetes object that requests that
  disk. On this single-node k3s cluster a PVC is satisfied by the built-in
  **`local-path`** StorageClass, which carves a directory out of the host data
  disk at `/var/lib/nagare/local-path` and mounts it into your pod.
- A **mount path** is the in-container directory where the disk appears, e.g.
  `/data`. **Anything your app writes *inside* a mount path survives a restart;
  anything written elsewhere in the container filesystem is lost.**
- **ReadWriteOnce (RWO)** is the only access mode: "one node mounts this disk
  read-write." Nagare is intentionally single-node, so every volume is RWO.
- A **retention policy** says what happens to the disk when the app is *deleted*:
  `Retain` (keep the disk and its data — the default and safest) or `Delete`
  (destroy it). This is independent of object-store backups.

> **Durable volume vs container filesystem.** A file at `/data/app.db` (inside a
> volume mounted at `/data`) survives pod restarts, revision rolls, and
> scale-to-zero. A file at `/tmp/app.db` or `/app/app.db` (not under a mount
> path) is gone the moment the pod is replaced.


## Declaring a volume in `Config.hs`

Attach a `1Gi` volume mounted at `/data` to a `webService` with the `attachVolume`
overlay from `Nagare.Dsl.Presets`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (attachVolume, webService)

deployment :: Either String Deployment
deployment =
  first show
    (webService "notes" "gcr.io/myproject/notes"
       >>= attachVolume "data" "1Gi" "/data")

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

`attachVolume name size mountPath` validates each field through smart
constructors — a duplicate volume name, a relative or colliding mount path, or a
malformed size like `"1Gigs"` is rejected at config-load time with a precise
error — and defaults the new volume to `accessMode = ReadWriteOnce`,
`readOnly = False`, and `retention = Retain` (kept on app deletion, and included
in backups). The full field catalogue is in
[config reference → Volumes](config-reference.md#volumes).

> **Attaching a volume pins the app's scaling.** Any Service with at least one
> volume is rendered with `min-scale = 1`, `max-scale = 1`, and
> `rollout-duration = 0s` (verified by EP-33). A single-node `ReadWriteOnce`
> disk must not have two concurrent writers and the app should stay warm, so a
> volume-bearing app overrides whatever `scale` the config or a preset set. This
> is deliberate; plan capacity accordingly.

To opt a volume *out* of backups (throwaway data — a cache, scratch space), give
it `retention = Delete`. `attachVolume` only builds `Retain` volumes, so an
excluded volume is a record literal today:

```haskell
import Data.Bifunctor (first)
import Nagare.Dsl.Types

cacheVol :: Either String Volume
cacheVol = do
  vn <- first show (mkVolumeName "cache")
  sz <- first show (mkQuantity "1Gi")
  mp <- first show (mkMountPath "/cache")
  pure Volume
    { volName = vn, size = sz, mountPath = mp
    , accessMode = ReadWriteOnce, readOnly = False
    , retention = Delete           -- excluded from backups; warned at deploy
    }
```

then `pure base { volumes = [v] }`. `nagarectl deploy` prints a warning naming
every `Delete` volume so nothing is silently unprotected (see
[Backup ownership](#backup-ownership-and-the-deploy-time-warning)).


## Seeing the rendered storage offline

`nagarectl deploy --dry-run` renders the manifests from your typed config with no
cluster contact — the offline proof your storage is correct. Volumes print
**before** the Service (they are created first):

```bash
nagarectl deploy -f nagare/Config.hs --dry-run
```

```text
--- PersistentVolumeClaim manifest ---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-vol-notes-data
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/app: notes
    nagare.dev/volume: data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: notes
  ...
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: '1'
        autoscaling.knative.dev/max-scale: '1'
        serving.knative.dev/rollout-duration: 0s
    spec:
      containers:
      - image: gcr.io/myproject/notes:...
        ...
        volumeMounts:
        - name: data
          mountPath: /data
          readOnly: false
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: nagare-vol-notes-data
```

On a real `nagarectl deploy`, the PVC is `kubectl apply`ed before the Service
(the `local-path` provisioner binds the disk only once the consuming pod
schedules — `WaitForFirstConsumer` — so the deploy applies PVC → Service → waits
Ready, then reports each volume's bound phase). Re-deploying **reuses** the PVC;
it never recreates or wipes the disk.


## Operating volumes: `nagarectl storage`

PVCs are discovered by the `nagare.dev/managed-by: nagarectl` label plus a
per-volume `nagare.dev/app`/`nagare.dev/volume` label, so the commands always
reflect what `nagarectl deploy` provisioned.

```bash
nagarectl storage list notes
```

```text
  VOLUME      PVC                       SIZE    STATUS    NODE-PATH
  data        nagare-vol-notes-data     1Gi     Bound     /var/lib/nagare/local-path/pvc-...
```

A volume declared in the config but not yet deployed shows `STATUS = MISSING` and
`NODE-PATH = -`. Inspect one volume's PVC in detail:

```bash
nagarectl storage inspect notes data
```

Snapshot a volume's contents to the active backup store (GCS in cloud mode,
MinIO in local mode; see next section):

```bash
nagarectl storage snapshot notes data
```


## Backup ownership and the deploy-time warning

Every app volume is, by an explicit policy, **either** included in the object-store
backup flow **or** explicitly excluded — and an excluded volume triggers a **warning at
deploy time**, so no volume is ever silently unprotected:

- `retention = Retain` (the default) ⇒ **backup-included**: `nagarectl storage
  snapshot APP VOLUME` tars the volume's contents to
  `volumes/<app>/<volume>/<timestamp>.tar.gz` in the active store. In cloud mode
  that is `gs://<backup-bucket>/...`; in local mode it is
  `s3://nagare-backups/...` on MinIO. The newest few snapshots per volume are
  kept (`--keep`, default 7); older ones are pruned.
- `retention = Delete` ⇒ **backup-excluded**: `nagarectl deploy` prints, to
  stderr, `warning: volume '<vol>' on app '<app>' is NOT backed up (backup
  excluded in config)`.

Retention controls the *local disk* on app deletion; an object-store snapshot is a
*separate* durable copy. The two are independent.

> **Hot databases.** `nagarectl storage snapshot` copies files at the moment it
> runs; a snapshot of a *live, actively-written* SQLite database can capture a
> torn page. For a database that is written while serving, prefer the continuous
> **Litestream** pattern (see the SQLite example below) for consistent,
> point-in-time-recoverable replication. Uploaded files, generated assets, and a
> stopped app's database snapshot cleanly.


## Restoring

Restores are **scratch-first**: restore a snapshot into a *disposable* PVC,
compare its contents, then promote — never restore directly over a live volume.
The full step-by-step is in
[Backups & disaster recovery](backups-and-disaster-recovery.md#app-volumes-backup-included-by-default-opt-out-explicitly)
and the [disaster-recovery runbook](../runbooks/disaster-recovery.md); the verb
is `nagarectl storage restore APP VOLUME <timestamp>` (scratch-first by default;
`--into-live` targets the live PVC).


## Two worked examples

- **[`cluster/examples/sqlite-pvc-litestream/`](../../cluster/examples/sqlite-pvc-litestream/)**
  — a SQLite database on a `1Gi` durable volume at `/data`, with a Litestream
  sidecar continuously replicating to GCS. The README deploys it, writes a row,
  rolls a revision, and shows the row survives (durable PVC) — *unlike* the older
  raw `cluster/examples/sqlite-litestream/`, which keeps the database on an
  ephemeral `emptyDir` and is applied with raw `kubectl`, not `nagarectl deploy`.

- **[`cluster/examples/uploads-volume/`](../../cluster/examples/uploads-volume/)**
  — a web app that stores uploads on a durable volume at `/uploads`. The README
  uploads a file, rolls the app, confirms it is still served, then runs
  `nagarectl storage snapshot` and walks a restore drill.
