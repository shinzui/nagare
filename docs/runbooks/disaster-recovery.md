# Nagare disaster-recovery runbook

Rebuild the entire Nagare platform from this Git repository plus the backup
bucket. The goal is **boring and reproducible**: every step is a command plus the
observation that confirms it worked. Run everything from the repo root
`/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell (`nix develop` or
`direnv allow`), which provides `pulumi`, `kubectl`, `helm`, `gcloud`/`gsutil`,
`sops`, `age`, `jq`, and `just`. All cloud work targets the active context; the
historic default context is project **`tan-nb-exp`**, region **`us-west1`**, zone
**`us-west1-a`**.

> For routine (non-rebuild) health checks and day-2 operations, use `nagarectl
> server status` / `nagarectl doctor` — see
> [`server-operations.md`](server-operations.md). This runbook is the full
> rebuild-from-scratch sequence; `doctor` automates many of its per-step
> "Observe:" assertions, noted inline below.

> **`nagarectl` is a disaster-recovery prerequisite.** The restore steps below
> call `nagarectl` verbs (`db restore`, `storage restore`) directly; the former
> hand-rolled `scripts/restore-*` / `scripts/backup-postgres` helper scripts have
> been removed (MasterPlan 13, EP-1) so that all control-plane logic lives in the
> typed CLI. Build it once with `cabal build exe:nagarectl` in `cli/nagarectl/`
> (inside `nix develop`), or have it on `PATH`, before starting a restore.

## The one thing that is NOT in Git or the bucket

The **age private key** (`~/.config/sops/age/keys.txt`; on the host
`/var/lib/sops-nix/age-key.txt`). It is the root of trust for every encrypted
secret. Store a copy offline (password manager / hardware token). **Without it,
nothing under `cluster/secrets/` or `nixos/secrets/` can be decrypted** and the
recovery cannot complete. Restore it first, before step 7.

## Backup inventory — what is backed up, where, and how it is restored

```text
NixOS config .............. Git (nixos/)                              -> git clone
Pulumi infra (TypeScript) . Git (infra/pulumi/src/)                  -> git clone
Pulumi state .............. ${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state -> restore active context state
Kubernetes manifests ...... Git (cluster/)                           -> git clone
Secrets ................... sops-encrypted in Git (.sops.yaml,
                            cluster/secrets/, nixos/secrets/)         -> sops -d | kubectl apply
SQLite app data ........... Litestream replica in
                            gcs://<backupBucket>/litestream/          -> litestream restore (scratch)
App volume data ........... tar.gz snapshots in
                            gcs://<backupBucket>/volumes/<app>/<volume>/ -> nagarectl storage restore <app> <volume> <id> (scratch)
Managed database data ..... pg_dump/.rdb/.native logical dumps in
                            gcs://<backupBucket>/databases/<name>/      -> nagarectl db restore <name> <id> (scratch)
Grafana dashboards ........ Git (cluster/observability/grafana/
                            dashboards/)                              -> provisioned by EP-5 sidecar
Victoria metrics/logs/traces  NOT backed up (non-critical;
                            re-derived from live workloads)           -> nothing to restore
age PRIVATE key ........... NOT in Git, NOT in the bucket; offline    -> restore from your vault
```

`nagarectl server status` reports the **freshness** (newest-object age) of each
`gs://tan-nb-exp-nagare-backups/` prefix (`postgres`, `litestream`, `volumes`),
so you can confirm backups are current without a manual `gsutil ls -l`.

## Rebuild sequence

### 1. Provision cloud resources (EP-2)

```bash
cd infra/pulumi && pulumi up
pulumi stack output backupBucket    # e.g. tan-nb-exp-nagare-backups
cd -
```

Observe: `Resources: + N created`; `backupBucket`, `publicIp`, `dnsZoneName`,
etc. print. The static IP, Cloud DNS zone, data disk, service account, Artifact
Registry, and both buckets exist.

### 2. Build & register the NixOS image, then boot the VM (EP-3, Integration Point 10)

```bash
just host-image                     # build on the x86_64-linux remote builder,
                                    # upload, register a GCE image, write
                                    # nagareImageSelfLink into Pulumi config
cd infra/pulumi && pulumi up && cd -   # instance boots from the registered image
```

Observe: `host-image` prints the registered image self-link; `pulumi up` shows
the instance created/replaced; the VM is `RUNNING`.

> **Boot disk size:** `NagareInstance.ts` sets `bootDisk.initializeParams.size =
> 100`. The 6 GB image default is too small — it holds both `/nix/store` and the
> containerd image store, and tripped DiskPressure during the observability
> install. Keep it at 100 GB (NixOS `growPartition` grows root to fill it).

> **DNS must be baked into the image.** The registered image MUST contain the
> `nixos/hosts/nagare-01/networking.nix` fix (`networking.nameservers =
> [8.8.8.8 8.8.4.4]`, `dhcpcd.extraConfig = "nohook resolv.conf"`). Verify on a
> fresh boot: `ssh deploy@nagare-01 'grep nohook /etc/dhcpcd.conf && cat
> /etc/resolv.conf'` shows `8.8.8.8`, NOT `169.254.169.254`. If it shows the
> metadata resolver, the image predates the fix — rebuild it (`just host-image`).
> Without working DNS, containerd cannot pull cluster images and coredns cannot
> resolve external names (cert-manager / Let's Encrypt fail).

### 3. Reach the cluster (Integration Point 7)

Until Tailscale is joined, the kube-apiserver (6443) is reachable only over an
SSH local-forward through the port-22 IAP tunnel:

```bash
export ZONE=us-west1-a
TUNPID=$(scripts/iap-ssh.sh tunnel nagare-01 22 2222)        # localhost:2222 -> VM:22
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -p 2222 \
    -L 6443:127.0.0.1:6443 -N -f deploy@127.0.0.1            # forward 6443
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p 2222 deploy@127.0.0.1 \
    'cat /etc/rancher/k3s/k3s.yaml' > /tmp/nagare-kubeconfig.yaml
sed 's#https://127.0.0.1:6443#https://127.0.0.1:6443#' /tmp/nagare-kubeconfig.yaml > /tmp/kc.yaml
export KUBECONFIG=/tmp/kc.yaml
kubectl get nodes
```

Observe: one node, `STATUS Ready`. (The k3s cert SAN includes 127.0.0.1, so the
unmodified server address works through the forward.) Clean up the forward/tunnel
with `pkill -f 'ssh.*-L 6443'; kill $TUNPID` when done.

### 4. Bootstrap the cluster platform (EP-4)

```bash
just cluster-bootstrap
just deploy-hello
kubectl -n personal wait --for=condition=Ready ksvc/hello --timeout=300s
curl -i --resolve hello.personal.apps.example.com:80:$(cd infra/pulumi && pulumi stack output publicIp) \
  http://hello.personal.apps.example.com
```

Observe: cert-manager, knative-serving, kourier-system pods `Running`; the
`letsencrypt-dns` ClusterIssuer `READY=True`; the hello ksvc `READY=True`; the
curl returns `200` / `Hello Nagare!`. (v1 is HTTP-first; Let's Encrypt wildcard
TLS is enabled with `just cluster-enable-tls` once a real `baseDomain` is
delegated — see EP-4.)

> `nagarectl doctor` now checks these same assertions automatically — the
> Knative/Kourier/cert-manager rollouts and the `letsencrypt-dns` ClusterIssuer
> readiness — so after this step you can run `nagarectl doctor` to confirm them
> in one graded command. The manual `kubectl`/`curl` assertions above remain the
> ground-truth fallback when the CLI is unavailable mid-rebuild.

> On a cold cluster, cert-manager/Knative images take a few minutes to pull. If a
> rollout times out, wait and re-run `just cluster-bootstrap` (idempotent). If
> pods are stuck `ImagePullBackOff`, confirm DNS (step 2 note) and delete the
> stuck pods so kubelet retries.

### 5. Install observability (EP-5)

```bash
just observability
kubectl get pods -n monitoring -n logging -n tracing
```

Observe: `helm list -A` shows `vmks`, `victoria-logs`, `victoria-logs-collector`,
`victoria-traces`, `otel-collector` all `deployed`; pods `Running`; PVCs `Bound`
to `local-path`. Reach Grafana with
`kubectl port-forward -n monitoring svc/vmks-grafana 3000:80`. Dashboards under
`cluster/observability/grafana/dashboards/` load via the sidecar. (Log search
uses the stream selector `{kubernetes.pod_namespace="<ns>"}`.)

> `nagarectl server status` reports boot- and data-disk usage (the
> `/var/lib/nagare` data disk backs these PVCs over `local-path`), so you can spot
> disk pressure here without an SSH `df -h`.

### 6. Restore secrets (EP-7 M1)

```bash
# Ensure the age private key is in place first (see "the one thing not in Git").
kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
for f in cluster/secrets/*.yaml; do sops -d "$f" | kubectl apply -f -; done
kubectl get secrets -n personal
```

Observe: each prints `secret/<name> created`; the Secrets are listed.

### 7. Restore data (EP-7 M2)

```bash
export BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
# SQLite (Litestream) into a scratch file, then promote into the app volume/disk.
# (The old restore-sqlite helper script is removed — restore with litestream
# directly, pointing at the replica prefix in the backup bucket.)
litestream restore -o /tmp/restore-app.db gcs://$BACKUP_BUCKET/litestream/<app-db>
sqlite3 /tmp/restore-app.db "SELECT count(*) FROM notes;"
# Postgres (managed database, EP-47) into a SCRATCH target, compare, then promote
# manually. (The host-side restore-postgres / backup-postgres helper scripts are
# removed; managed-DB backup/restore is the supported path.)
nagarectl db restore <name> "$(gsutil ls gs://$BACKUP_BUCKET/databases/<name>/ | tail -1)"
# App volume (EP-36) into a SCRATCH PVC, eyeball the restored tree, then promote:
nagarectl storage restore <app> <volume> <latest-id> --config <path-to-Config.hs>
# Managed database (EP-47) into a SCRATCH target, compare, then promote manually:
nagarectl db restore <name> "$(gsutil ls gs://$BACKUP_BUCKET/databases/<name>/ | tail -1)"
```

Observe: the scratch row counts (or, for an app volume, the restored file tree
the Job logs print) match the source at backup time. Only after comparing do you
promote (copy the scratch SQLite file to `/var/lib/nagare/sqlite/`, rename the
scratch Postgres db, or copy the scratch PVC's files into the live volume). The
`nagarectl` restore verbs only ever write to a scratch target by default
(`--into-live` is the sole, loudly-announced destructive path), so a botched
restore can never clobber live data.

**App-volume snapshots are file-level, point-in-time copies** (`tar` of the
mounted volume → `gs://<backupBucket>/volumes/<app>/<volume>/<ts>.tar.gz`, taken
by `nagarectl storage snapshot APP VOLUME`). A snapshot of a *hot* (actively
written) SQLite database can capture a torn page — quiesce the app first, or use
the continuous Litestream pattern (`cluster/examples/sqlite-litestream/`) for
databases that are written while live. Uploaded files / generated assets / a
stopped app's DB snapshot cleanly. Volumes declared with `retention = Delete` are
treated as throwaway and are **excluded** from backups (and `nagarectl deploy`
warns about them).

**Managed databases (EP-47) are backed up by default.** Each `nagarectl db
create` provisions a daily, self-pruning **CronJob** that runs an
engine-appropriate logical dump (`pg_dump` for Postgres, an RDB dump for Redis, a
native dump for ClickHouse), gzips it, and uploads it to
`gs://<backupBucket>/databases/<name>/<ts>.<ext>` (keep-last-N, default 7). Take
one on demand with `nagarectl db backup <name>`; list them with `gsutil ls
gs://<backupBucket>/databases/<name>/`. **Restore is scratch-first**: `nagarectl
db restore <name> <backup-id>` loads the dump into a disposable target
(`<db>_restore_scratch` for Postgres/ClickHouse) so live data is untouched until
you promote manually; pass `--into-live` to target the live database. A database
declared `retention = Delete` is treated as throwaway and gets **no** scheduled
backup.

**Restore drill (against a disposable database).** Prove the path end to end
without risking live data — run on the VM (`scripts/iap-ssh.sh`) or through a
forwarded kube-API port (IAP forwards only SSH/22):

```bash
nagarectl db create postgres drilldb
# write a known row, then:
nagarectl db backup drilldb
nagarectl db restore drilldb "$(gsutil ls gs://$BACKUP_BUCKET/databases/drilldb/ | tail -1)"
# the restore Job's logs print the scratch db's table list / row count to compare
nagarectl db delete drilldb --yes
```

> **In-pod GCS auth (fixed 2026-06-10):** in-pod GCS upload was blocked because
> k3s/flannel's IPv4LL `169.254.0.0/16` addresses hijacked the GCE metadata IP
> `169.254.169.254` into the VXLAN overlay (the litestream sidecar failed the same
> way). Fixed in `nixos/hosts/nagare-01/networking.nix`: a `/32` metadata route on
> the primary NIC (beats the `/16`) + a MASQUERADE for pod SNAT; the backup/restore
> Jobs also set `hostAliases` so gcloud/gsutil resolve `metadata.google.internal`.
> Applied live on the node and committed to NixOS — run `just host-switch` (or
> rebuild the image) to persist across reboots. See MasterPlan 9 and EP-43. As of
> MasterPlan 13 / EP-1, that `hostAliases` is rendered by the shared
> `Nagare.Cluster.GcsJob` module for every GCS data-movement Job (db backup/restore,
> volume snapshot/restore), so it cannot be present in one path and missing in another.

### 8. Redeploy the apps (EP-6)

```bash
nagarectl deploy        # run in each app repo containing a nagare/Config.hs
```

Observe: the tool prints the app URL; `curl` returns the app's response.
(EP-6 — the `nagarectl` CLI — is a separate child plan; until it exists, apply
the rendered Knative Service manifests directly as in
`cluster/examples/hello-knative-service/`.)

## Power management (stop / start / full teardown)

Nagare is designed to be disposable, so there are three "off" levels:

**Stop the VM (cheapest reversible — halts compute only).**

```bash
gcloud compute instances stop  nagare-01 --project=tan-nb-exp --zone=us-west1-a
gcloud compute instances start nagare-01 --project=tan-nb-exp --zone=us-west1-a
```

Stopping halts compute charges; the boot + data disks and the reserved static IP
still incur small storage/reservation costs. **Restart caveat:** `start` boots the
*existing* boot disk (the current system generation), NOT the latest registered
image. Two runtime workarounds applied during 2026-06-03 bring-up do **not** all
survive a reboot:
- `/etc/resolv.conf` is `chattr +i` immutable, so the `8.8.8.8` content **persists**
  across reboot (DNS keeps working).
- The pod→metadata route and MASQUERADE, and the coredns upstream, are runtime-only
  and are **lost** on reboot — so after a `start`, re-apply them (or replace the VM,
  below) before expecting keyless in-cluster ADC (Litestream/cert-manager) to work:
  ```bash
  GW=$(... default gw); ip route replace 169.254.169.254/32 via "$GW" dev eth0
  iptables -t nat -A POSTROUTING -d 169.254.169.254/32 -j MASQUERADE
  kubectl -n kube-system rollout restart deploy/coredns
  ```
  After a plain `start`, `nagarectl doctor` will flag the resulting downstream
  failures (cert-manager / control-plane not ready, `Artifact Registry`
  unreachable, stale backups) — re-apply the three commands above, then re-run
  `nagarectl doctor` until every line is `OK`. The end-to-end walkthrough is the
  day-2 recovery scenario in
  [`server-operations.md`](server-operations.md#day-2-recovery-scenario-terminated--green).

**Replace the VM onto the fixed image (clean boot, recommended).** A `pulumi up`
that recreates the instance boots from `nagareImageSelfLink`
(`nagare-image-gnq7zw6pwd1a`, which has the DNS + metadata fixes), giving a fully
clean boot with no workarounds — then re-bootstrap per steps 4–8 above. Do this
once to retire the runtime workarounds.

**Full teardown (stop all charges).**

```bash
cd infra/pulumi && pulumi destroy
```

This deletes the VM, disks, IP, DNS zone, and buckets' contents per the stack.
Rebuild from scratch with this runbook from step 1. The age private key, Git, and
the GCS backup bucket contents are what make that rebuild possible.

## Notes on idempotence

Every step is safe to re-run: `pulumi up` reconciles; `just cluster-bootstrap`
and `just observability` use declarative apply / `helm upgrade --install`;
`sops -d | kubectl apply` is idempotent; restores write to scratch first and
never clobber a live database.
