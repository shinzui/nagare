# Reference

> **Status:** ✅ Working — a quick lookup for the fixed identifiers, config keys,
> recipes, ports, and paths you'll keep needing. Values reflect the current
> repo; if one drifts, the code is the source of truth.

---

## Default-example identifiers (derived from the active context)

These are the values for the default-example target (`tan-nb-exp` / `us-west1`).
For your own project they **derive from the active target context**: registry
host `<region>-docker.pkg.dev`, buckets `<project>-nagare-*`, SA
`nagare-node@<project>…`.

| Thing | Value (default example) |
| --- | --- |
| GCP project | `tan-nb-exp` |
| Region | `us-west1` |
| Zone | `us-west1-a` |
| Instance | `nagare-01` (`e2-standard-2`) |
| Subnet CIDR | `10.10.0.0/24` |
| Node service account | `nagare-node@tan-nb-exp.iam.gserviceaccount.com` |
| Artifact Registry | `us-west1-docker.pkg.dev/tan-nb-exp/nagare` |
| Backup bucket | `tan-nb-exp-nagare-backups` |
| Image-staging bucket | `tan-nb-exp-nagare-images` |
| Data disk device | `/dev/disk/by-id/google-nagare-data` → mounted at `/var/lib/nagare` |
| Host age key (on host) | `/var/lib/sops-nix/age-key.txt` |
| k3s kubeconfig (on host) | `/etc/rancher/k3s/k3s.yaml` (mode `0640`, owner `root:wheel`) |
| NixOS `stateVersion` | `26.05` |

## Context store

The context store is user-level, not per-checkout:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/
  contexts/<name>.env
  current-context
```

Selection precedence is `--context` / `NAGARE_CONTEXT` > `current-context` >
in-repo profile > built-in default. Per-field values still follow environment >
context/profile > default, except guarded cloud scripts reject a project
override that disagrees with the selected context. See [Target contexts](contexts.md).

## Platform payload and workspace

Packaged operation separates release-owned assets from mutable context state.
`nagare-platform` installs the Pulumi program, cluster manifests, scripts, NixOS
source, documentation, and `justfile` as an immutable payload. Commands that may
generate files use a content-addressed copy below:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/<payload-id>-<digest>/
```

Run `nagarectl platform root` (or `--json`) to inspect the resolved payload and
workspace. Resolution is the packaged `NAGARE_PLATFORM_ROOT`, then a validated
source-checkout ancestor for contributor workflows; an explicitly configured
but incomplete payload fails without falling back. The packaged `nagare`
launcher runs operator recipes from the active workspace, so its current
directory does not need to be a Nagare checkout.

## Cloud context variables (also `nagare.target.env`)

Each context `.env` file uses the same flat schema as the git-ignored
`nagare.target.env` back-compat profile (documented by
`nagare.target.env.example`). `nagarectl init NAME` writes a named context;
unnamed `nagarectl init` writes the old `nagare.target.env`.

| Variable | Default | Derivation |
| --- | --- | --- |
| `CLOUDSDK_CORE_PROJECT` | `tan-nb-exp` | the GCP project id |
| `CLOUDSDK_COMPUTE_REGION` | `us-west1` | compute region |
| `CLOUDSDK_COMPUTE_ZONE` | `us-west1-a` | compute zone |
| `NAGARE_REGISTRY_HOST` | `us-west1-docker.pkg.dev` | `<region>-docker.pkg.dev` |
| `NAGARE_ARTIFACT_REGISTRY_ID` | `nagare` | the Artifact Registry repo id |
| `NAGARE_IMAGE_BUCKET` | `tan-nb-exp-nagare-images` | `<project>-nagare-images` |
| `NAGARE_BACKUP_BUCKET` | `tan-nb-exp-nagare-backups` | `<project>-nagare-backups` |
| `NAGARE_BASE_DOMAIN` | `apps.example.com` | wildcard apps domain |
| `NAGARE_INSTANCE_NAME` | `nagare-01` | the VM instance name |
| `NAGARE_TARGET_PLATFORM` | `linux/amd64` | Docker/Nixpacks build platform for cloud node images |
| `NAGARE_PULUMI_BACKEND` | `local` | Pulumi state backend: `local` (per-context `file://`) or `gcs` (opt-in remote, cloud-only). |
| `NAGARE_PULUMI_BACKEND_URL` | — (derived) | explicit `gs://bucket/path`; empty + `gcs` derives `gs://<project>-nagare-pulumi-state/nagare/<context>`. |

See [Getting started](getting-started.md), [Target contexts](contexts.md), and
[`CLAUDE.md`](../../CLAUDE.md) for the configurable-isolation model.

## Local context variables (also `nagare.local.env`)

The git-ignored `nagare.local.env` (schema in `nagare.local.env.example`) is now
the back-compatible form of a `mode=local` context.

| Variable | Default example | Purpose |
| --- | --- | --- |
| `NAGARE_MODE` | `local` | mode switch; unset or `cloud` keeps cloud behavior |
| `NAGARE_REGISTRY_HOST` | `k3d-registry.localhost:5000` | local image registry |
| `NAGARE_BASE_DOMAIN` | `127-0-0-1.sslip.io` | loopback wildcard app domain |
| `NAGARE_TARGET_PLATFORM` | `linux/arm64` in the example | local image build platform |
| `NAGARE_LOCAL_OBJECT_STORE` | `http://minio.nagare-system.svc.cluster.local:9000/nagare-backups` | MinIO endpoint + bucket for local backups |

## `nagarectl context` commands

| Command | Does |
| --- | --- |
| `nagarectl context list` | List stored contexts and mark the current one. |
| `nagarectl context current` | Print the current context name. |
| `nagarectl context use NAME` | Set the current context, select its Pulumi stack/backend, and regenerate its config projection. |
| `nagarectl context show [NAME]` | Print a context bundle as `export VAR=value`; with no name, show the active context. |
| `nagarectl context create NAME [flags]` | Write a context. Flags include `--project`, `--region`, `--zone`, `--base-domain`, `--registry-host`, `--artifact-registry-id`, `--image-bucket`, `--backup-bucket`, `--instance-name`, `--target-platform`, `--mode`, `--local-object-store`, `--pulumi-backend` (`local`\|`gcs`), `--pulumi-backend-url`, `--pulumi-backend-member`, `--force`, and `--use`. |
| `nagarectl context delete NAME --yes` | Delete a context. If it was current, clear the pointer. |

`nagarectl --context NAME ...` is the global per-command target selector.
Shell recipes use `NAGARE_CONTEXT=NAME just <recipe>`.

## `justfile` recipes

| Recipe | Does | Plan |
| --- | --- | --- |
| `just` / `just default` | List all recipes | — |
| `just infra-preview` | `pulumi preview` the cloud perimeter | EP-2 |
| `just infra-up` | `pulumi up` the cloud perimeter | EP-2 |
| `just vm-stop` / `just vm-start` | Stop or start the context-selected VM without changing disks or the static IP | MP-8 |
| `just host-image` | Build + upload + register the NixOS GCE image (`scripts/upload-images.sh`) | EP-3 |
| `just nixos-registry-host` | Regenerate the NixOS registry-host projection from the active context | MP-17 EP-91 |
| `just host-switch` | `nixos-rebuild switch --flake ./nixos#nagare-01 --target-host nagare-01 --sudo` | EP-3 |
| `just cluster-bootstrap` | Apply cert-manager, Knative, Kourier, config-domain | EP-4 ✅ |
| `just cluster-enable-tls` | Enable Knative external-domain TLS after DNS delegation | EP-4 |
| `just job-runs-bootstrap` | Apply the two-slot ResourceQuota for deadline-bounded one-shot Jobs in `personal` | MP-18 EP-95 ✅ |
| `just job-runs-status` | Show bounded-run quota use, admitted Pods, and `FailedCreate` backpressure events | MP-18 EP-95 ✅ |
| `just context-show` | Print the selected kubectl context and API server without contacting the cluster | MP-8 |
| `just local-up` | Create local k3d cluster + local registry | MP-16 EP-82 |
| `just local-bootstrap` | Install Knative/Kourier locally, HTTP-first | MP-16 EP-82 |
| `just local-minio` | Install local MinIO backup object store | MP-16 EP-84 |
| `just local-down` | Delete the local k3d cluster and registry | MP-16 EP-82 |
| `just local-smoke` | Local zero-cloud smoke: deploy → volume snapshot/restore (MinIO) → HTTP 200 → teardown | MP-16 EP-86 ✅ |
| `just observability` | Install the Victoria stack + Grafana via Helm | EP-5 ✅ |
| `just deploy-hello` | Apply the sample Knative service | EP-4 ✅ |
| `just status` | `kubectl get pods -A` + `kubectl get ksvc -A` | — |
| `just live-test` | Open an IAP/SSH-forwarded kube connection and print the `KUBECONFIG` to use | MP-8 EP-70 |
| `just smoke` | Run the cloud deploy, GCS volume round-trip, HTTP check, and teardown smoke test | EP-69 |

## Pulumi config keys (`infra/pulumi/Pulumi.<context>.yaml`)

These keys are a **derived projection of the active context**. `nagarectl init
NAME`, `nagarectl context use NAME`, and `nagarectl context create NAME --use`
write `infra/pulumi/Pulumi.<context>.yaml` in the resolved platform workspace
with `pulumi config set --stack <context>`. The generated stack config files are
context-local; you normally do not hand-edit them for a new project. Each
context also has its own file backend
and `PULUMI_HOME` under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/`.

A cloud context can instead store **state** in GCS by setting
`NAGARE_PULUMI_BACKEND=gcs` (see the context-variable table above); `PULUMI_HOME`
stays local and only `PULUMI_BACKEND_URL` points at
`gs://<project>-nagare-pulumi-state/nagare/<context>`. Migrate between backends
with `scripts/migrate-pulumi-backend.sh`. See
[Target contexts › Remote GCS Pulumi state](contexts.md#remote-gcs-pulumi-state-opt-in-cloud-contexts-only).

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `gcp:project` | yes | `tan-nb-exp` | Your target project (default example `tan-nb-exp`). Seeded from the context by `nagarectl init` / `context use`. |
| `gcp:region` | yes | `us-west1` | |
| `gcp:zone` | yes | `us-west1-a` | |
| `nagare:imageBucket` | yes | `tan-nb-exp-nagare-images` | |
| `nagare:baseDomain` | no | `apps.example.com` | Set to your real apps domain. |
| `nagare:nagareImageSelfLink` | no | — | Set by `upload-images.sh`; **gates the VM**. |
| `nagare:instanceName` | no | `nagare-01` | |
| `nagare:machineType` | no | `e2-standard-2` | |
| `nagare:dataDiskSizeGb` | no | `100` | |
| `nagare:bootDiskSizeGb` | no | `100` | Boot-disk size. Increasing is supported; shrinking is not. |
| `nagare:bootDiskType` | no | `pd-balanced` | Changing a live VM's disk type forces instance replacement; pin the current type until a deliberate rebuild. |
| `nagare:vmDeletionProtection` | no | `true` | GCE refuses instance deletion/replacement while true. Disable only for the deliberate rebuild window, then re-enable. |
| `nagare:artifactRegistryId` | no | `nagare` | |
| `nagare:backupBucket` | no | `tan-nb-exp-nagare-backups` | |
| `nagare:enableCdn` | no | `false` | Opt in to the standing, billable Google Cloud CDN load balancer. |

## Pulumi stack outputs (the integration contract — names are stable)

`publicIp`, `sshCommand`, `baseDomain`, `instanceName`, `serviceAccountEmail`,
`dataDiskName`, `dnsZoneName`, `artifactRegistry`, `backupBucket`.

```bash
pulumi -C infra/pulumi stack output <name>
```

## Firewall / ports

| Port | Source | Purpose |
| --- | --- | --- |
| `80`, `443` TCP | `0.0.0.0/0` | Kourier ingress (k3s ServiceLB binds host 80/443) |
| `22` TCP | `35.235.240.0/20` (IAP only) | SSH via IAP tunnel — never public |
| `41641` UDP | `0.0.0.0/0` | Tailscale direct connections (optimization; relays work without it) |
| `6443` | `tailscale0` (trusted iface) | kube-apiserver — reachable over the tailnet only |

## On-host storage layout (`/var/lib/nagare`)

Created by the `nagare-data-layout` unit *after* the data-disk mount:

```text
/var/lib/nagare/
  victoria-metrics/    # VictoriaMetrics data (EP-5)
  victoria-logs/       # VictoriaLogs data (EP-5)
  victoria-traces/     # VictoriaTraces data (EP-5)
  postgres/            # host Postgres data (Tier 3)
  sqlite/              # SQLite app data (Tier 2, Litestream → GCS)
  backups/             # local backup staging (EP-7)
  local-path/          # k3s local-path-provisioner volumes
```

## k3s server flags (`nixos/hosts/nagare-01/k3s.nix`)

```text
--disable=traefik
--write-kubeconfig-mode=0640
--write-kubeconfig-group=wheel
--secrets-encryption
--default-local-storage-path=/var/lib/nagare/local-path
```

ServiceLB (Klipper) is **left enabled** — Kourier's `LoadBalancer` Service needs
it. Only Traefik is disabled.

## Scripts (`scripts/`)

| Script | Purpose |
| --- | --- |
| `lib/target.sh` | Sourced helper: resolves the active context, sets `TARGET_PROJECT`/`REGION`/`ZONE`, exports `NAGARE_REGISTRY_PREFIX`, and runs the fail-closed `_require_target_project` guardrail. Every script sources it. |
| `enable-apis.sh` | Enable the six GCP service APIs against the target project (run by `nagarectl init`). |
| `upload-images.sh` | Build the NixOS image on the remote builder, upload to GCS, register as a GCE image, write `nagareImageSelfLink`. |
| `setup-nix-builder.sh` | Provision the on-demand x86_64-linux Nix builder. |
| `nix-builder-startup.sh.tpl` | Startup-script template for the builder VM (no project literal). |
| `iap-ssh.sh` | IAP-tunneled `ssh`/`scp`/`recv-file`/`tunnel` wrapper (macOS-safe). |
| `live-test.sh` | Open the IAP + SSH kube-apiserver forward, fetch/rewrite kubeconfig, and print the environment to use. |
| `vm-power.sh` | Context-guarded VM `start`/`stop` implementation used by the `just` recipes. |
| `migrate-pulumi-backend.sh` | Export/import one context's state between its local file backend and opt-in GCS backend. |
| `live-smoke.sh` | Cloud deploy + GCS-backed volume snapshot/restore + HTTP + teardown acceptance path. |
| `local-smoke.sh` | Zero-cloud k3d/MinIO equivalent of the live smoke path. |

### `nagarectl init` (onboarding)

`nagarectl init [NAME]` is the guided onboarding command (the one command
permitted to drive Pulumi/gcloud). Flags: `--project`, `--region`, `--zone`,
`--base-domain`, `--pulumi-backend` (`local`\|`gcs`), `--pulumi-backend-url`,
`--pulumi-backend-member`, `--force`, `--skip-preflight`, `--skip-enable`,
`--skip-seed`, `--dry-run`. With `NAME`, it preflights gcloud auth + the six operator IAM roles,
writes a named context, sets it current, runs `enable-apis.sh`, and seeds that
context's Pulumi keys. Without `NAME`, it writes the legacy `nagare.target.env`.
See
[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md).

## IAM granted to `nagare-node`

| Role | Scope | Why |
| --- | --- | --- |
| `roles/dns.admin` | Nagare managed zone only | cert-manager writes Let's Encrypt DNS-01 challenge records |
| `roles/dns.reader` | project | cert-manager discovers the configured managed zone before writing its challenge |
| `roles/artifactregistry.writer` | project | `nagarectl` pushes images |
| `roles/storage.objectAdmin` | backup bucket only | EP-7 backup jobs write to GCS |

All via **non-authoritative** `*IAMMember` resources (never clobber the shared
project's existing bindings).

## Global `nagarectl` target selection

The global parser accepts `nagarectl --context NAME ...`. Commands that resolve
a Nagare target context use it instead of `NAGARE_CONTEXT` or the
current-context pointer. Kubernetes-only lifecycle commands still use the
current `kubectl` context, so verify that it names the same target before a live
operation.

## `nagarectl deploy`, `app`, and `deployments`

| Command | Does |
| --- | --- |
| `nagarectl deploy [-f FILE] [--dry-run]` | Build/push as required, render one typed `Deployment`, apply its PVCs/Service/domains/tasks, and wait for readiness. |
| `nagarectl app deploy [-f FILE] [--dry-run] [--json]` | Roll out one typed multi-workload `Application`: pre-deploy hooks, databases, Service, then Workers. |
| `nagarectl app list [-n NS] [--all]` | List Nagare-managed Knative apps; `--all` includes unmanaged Services. |
| `nagarectl app get NAME [-n NS]` | Show image, revision, URL, readiness, and config-enriched limits/domains when available. |
| `nagarectl app logs NAME [--follow] [--tail N]` | Show or stream current app logs. |
| `nagarectl app restart NAME` | Create a fresh revision and bring a stopped app back online. |
| `nagarectl app stop NAME` | Recoverably take an app offline. |
| `nagarectl app delete NAME` | Delete the Service, DomainMappings, and deployment-history ConfigMap. Retained PVCs are not app-lifecycle resources. |
| `nagarectl deployments list NAME` | List recorded deployment ids newest first. |
| `nagarectl deployments logs NAME [DEPLOYMENT_ID]` | Show logs for the live revision or one recorded deployment. |

See [Deploying apps](deploying-apps.md) and [App lifecycle](app-lifecycle.md).

## `nagarectl task` and `worker`

| Command | Does |
| --- | --- |
| `nagarectl task list [APP] [-n NS]` | List managed CronJobs, optionally for one app; use `-` for app-less tasks. |
| `nagarectl task run APP TASK [--dry-run]` | Create a one-off Job from the deployed CronJob and wait for completion. |
| `nagarectl task logs APP TASK [--follow] [--tail N]` | Show the latest task-run Pod logs. |
| `nagarectl task delete APP TASK --yes [--dry-run]` | Delete the task CronJob and its run-history ConfigMap. |
| `nagarectl worker deploy [-f FILE] [--dry-run]` | Build/push as required and apply one continuous `apps/v1` Worker Deployment. |

These are separate from the finite `Nagare.Dsl.Job` library contract, which has
no `nagarectl job` command. See [Scheduled tasks](scheduled-tasks.md),
[Running workers](workers.md), and [Bounded one-shot jobs](one-shot-jobs.md).

## `nagarectl access`

| Command | Does |
| --- | --- |
| `nagarectl access grant --host HOST --user USER` | Grant one shomei user `access` on a protected host through en. |
| `nagarectl access revoke --host HOST --user USER` | Revoke that host grant. |
| `nagarectl access list --host HOST` | List users whose relationships expand to the host's `access` permission. |

All three accept `--en-url URL`; otherwise they use `NAGARE_EN_URL` or the
in-cluster default. See [Identity-aware access](access.md).

## `nagarectl site` commands (static & full-stack hosting)

| Command | Does |
| --- | --- |
| `nagarectl site deploy` | Build, package, and deploy the site in the current dir (static → Nginx image; full-stack → Node image, auto-detected from the config `kind`). |
| `nagarectl site deploy --dry-run` | Print the generated Nginx config / Dockerfile and Knative manifests; no side effects. |
| `nagarectl site releases` | List recorded releases (per-site ConfigMap; `*` = live). |
| `nagarectl site rollback RELEASE_ID` | Re-point production at a prior release's image tag. |
| `nagarectl site preview deploy --name NAME` | Deploy an isolated preview Service + domain (static sites). |
| `nagarectl site preview list` / `delete NAME` | List / remove previews. |

See the [Static & full-stack site hosting](static-hosting.md) guide. The webhook
runner `nagared` (`cluster/bootstrap/nagared/`) does Git-triggered deploys.

## `nagarectl broker` commands

| Command | Does |
| --- | --- |
| `nagarectl broker create redpanda NAME` | Provision a Redpanda-backed internal broker with PVC, Service, StatefulSet, and optional topics. |
| `nagarectl broker create redpanda NAME --dry-run` | Print the broker manifests and topic plan; no cluster changes. |
| `nagarectl broker list` | List managed brokers in a namespace. |
| `nagarectl broker get NAME` | Show provider, version, bootstrap, PVC, readiness, metrics endpoint health, and VictoriaMetrics scrape status. |
| `nagarectl broker restart NAME` | Roll the broker StatefulSet and wait for readiness. |
| `nagarectl broker delete NAME --yes` | Delete the StatefulSet and Service; keep the PVC unless you delete it explicitly. |

See the [Messaging brokers](messaging-brokers.md) guide.

## `nagarectl env` / `nagarectl secret` commands (app env & secrets)

The app identity comes from the loaded config (`-f/--config`, default
`nagare/Config.hs`), not the literal `APP`. Scope defaults to `runtime`
(`--runtime`/`--build`/`--preview` may be combined). Every mutating command takes
`--dry-run` (prints the would-be ConfigMap/Secret manifest; no side effects).

| Command | Does |
| --- | --- |
| `nagarectl env list APP [--all]` | List managed env keys/values (runtime scope; `--all` = all scopes). |
| `nagarectl env set APP KEY VALUE [scope] [--dry-run]` | Set one managed env key in the per-app ConfigMap. |
| `nagarectl env delete APP KEY [scope] [--dry-run]` | Remove one managed env key. |
| `nagarectl env sync APP --file FILE [--merge \| --reconcile-exact] [scope] [--dry-run]` | Bulk-import a dotenv file (`--merge` keeps other keys; `--reconcile-exact` replaces the store). |
| `nagarectl secret set APP KEY [scope] [--dry-run]` | Set one secret (value read from **stdin**, never argv) in the per-app Secret. |
| `nagarectl secret list APP [--all]` | List secret key **names** only (never values). |
| `nagarectl secret delete APP KEY [scope] [--dry-run]` | Remove one secret key. |

Managed values live in `nagare-env-<app>-<scope>` (ConfigMap) and
`nagare-secret-<app>-<scope>` (Secret); the running Service reads the runtime pair via
`envFrom`. See the [Environment and secrets](env-and-secrets.md) guide.

## `nagarectl storage` commands (persistent volumes)

App identity comes from the loaded config (`-f/--config`, default
`nagare/Config.hs`), like the `env`/`secret` commands. Volumes are declared in
the typed config (`volumes` field); `nagarectl deploy` provisions one PVC per
volume *before* the Service.

| Command | Does |
| --- | --- |
| `nagarectl storage list APP` | List the app's volumes: volume name, PVC name, size, bound status, node path (`MISSING` if a declared volume has no PVC yet). |
| `nagarectl storage inspect APP VOLUME` | `kubectl describe` the volume's PVC in detail. |
| `nagarectl storage snapshot APP VOLUME [--bucket B] [--keep N]` | Tar the volume's contents to the active backup store (GCS or local MinIO; keeps the newest `N`, default 7). |
| `nagarectl storage restore APP VOLUME BACKUP_ID [--bucket B] [--into-live] [--dry-run]` | Restore a snapshot, scratch-first by default. |

PVCs are named deterministically `nagare-vol-<app>-<volume>` and labelled
`nagare.dev/managed-by: nagarectl` + `nagare.dev/app=<app>` + `nagare.dev/volume=<volume>`
(the storage commands discover them by these labels). Snapshots land at
`gs://<backup-bucket>/volumes/<app>/<volume>/<timestamp>.tar.gz` in cloud mode or
`s3://nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz` in local mode. A
volume's data lives on the host under `/var/lib/nagare/local-path/` (or the k3d
node's local-path storage in local mode). Restore with
`nagarectl storage restore APP VOLUME <id>` (scratch-first).
See the [Persistent storage](persistent-storage.md) guide.

## `nagarectl db` commands (managed databases)

A managed database (Postgres/Redis/ClickHouse) is a separate typed `Database`
resource, not an app field. `db create` generates a password, writes the managed
Secret `nagare-db-<name>`, and provisions a single-replica StatefulSet + ClusterIP
Service + `local-path` PVC (+ a daily backup CronJob). Resources are discovered by
the labels `nagare.dev/managed-by: nagarectl` + `nagare.dev/database=<name>` +
`nagare.dev/engine=<engine>`.

| Command | Does |
| --- | --- |
| `nagarectl db list [-n NS]` | Table of managed databases: name, engine, version, size, status, host. |
| `nagarectl db create ENGINE NAME [--version V] [--size Q] [--memory Q] [--config F]` | Generate credentials and provision the database; idempotent (never regenerates the password). |
| `nagarectl db get NAME` | Detail: engine, version, size, in-cluster host, retention, ready, Secret key names. |
| `nagarectl db shell NAME` | Interactive `psql`/`redis-cli`/`clickhouse-client` inside the pod. |
| `nagarectl db restart NAME` | Roll the StatefulSet and wait for ready. |
| `nagarectl db delete NAME --yes` | Delete, honoring `RetentionPolicy` (guarded by `--yes`). |
| `nagarectl db backup NAME [--bucket B] [--keep N]` | Logical dump to GCS or local MinIO; keep-last-N retention. |
| `nagarectl db restore NAME BACKUP_ID [--into-live]` | Restore a backup, scratch-first (or into the live DB). |

All mutating commands support `--dry-run`. An app references a database by name
(the `databases` field on `Deployment`) and receives the per-engine connection
env at deploy time. Backups land at
`gs://<backup-bucket>/databases/<name>/<timestamp>.<ext>` in cloud mode or
`s3://nagare-backups/databases/<name>/<timestamp>.<ext>` in local mode. See the
[Managed databases](managed-databases.md) guide.

## `nagarectl cdn` commands

| Command | Does |
| --- | --- |
| `nagarectl cdn list [-n NS] [--all-namespaces]` | List CDN-fronted hostnames, providers, and edge state. |
| `nagarectl cdn status HOST` | Show provider, DNS target, cache config, and readiness for one hostname. |
| `nagarectl cdn purge HOST [--path PATH ...] [--dry-run]` | Purge everything or selected paths from the edge cache. |
| `nagarectl cdn disable HOST [--dry-run]` | Revert the hostname's DNS to the VM/origin and remove its active edge mapping. |

See [CDN (edge caching)](cdn.md).

## Platform inspection and cleanup commands

| Command | Does |
| --- | --- |
| `nagarectl server status [--skip-vm]` | Print one-screen VM, disk, Kubernetes, ingress, observability, app, database, and backup inventory. `--skip-vm` avoids the IAP/SSH disk probe. |
| `nagarectl doctor [--skip-vm]` | Run platform health checks with remediation hints; exits 1 if any check is `FAIL`. |
| `nagarectl domains list [-n NS] [--all-namespaces] [--base-domain DOMAIN]` | Compare the base domain and app DomainMappings with DNS and certificate state. |
| `nagarectl cleanup [selectors]` | Preview unused-image, stale-preview, and old-release cleanup. It deletes nothing without `--confirm`. |

> **Known status-probe gap:** the current `server status`/`doctor` backup rows
> still probe the legacy `postgres/`, `litestream/`, and `volumes/` prefixes.
> Managed-database objects now live under `databases/<name>/`, so a database
> freshness row can be `UNKNOWN` even when backups exist. Verify with
> `gsutil ls gs://<backup-bucket>/databases/<name>/` until EP-101 updates the
> inventory probe.

`cleanup` selectors are `--images`, `--previews`, and `--releases`; with none,
all three are included. Retention flags are `--preview-ttl-days N` (default 7)
and `--keep-releases N` (default 10), with optional `-n/--namespace` for preview
and release history.

## Bounded Job-run operations

The typed one-shot workload is currently operated at the cluster layer rather
than through `nagarectl`:

| Command | Does |
| --- | --- |
| `just job-runs-bootstrap` | Create/update `personal` and its `nagare-terminating-jobs` ResourceQuota. |
| `just job-runs-status` | Describe quota use, list deadline-bounded Pods, and show quota `FailedCreate` events. |
| `kubectl -n personal logs job/nagare-job-NAME` | Read a run's logs while the Job/Pod still exists. |
| `kubectl -n personal delete serviceaccount,networkpolicy nagare-job-NAME` | Remove the two resources that Job TTL cleanup cannot own. |

See [Bounded one-shot jobs](one-shot-jobs.md).

## Domain model

```text
Internal (automatic):  service.namespace.<baseDomain>   e.g. notes.personal.apps.example.com
Public  (optional):    <your-host>                      e.g. notes.example.com  (Knative DomainMapping)
```

Wildcard `*.<baseDomain>` `A` record → static IP, created by Pulumi. Wildcard
TLS via cert-manager DNS-01 (HTTP-01 can't issue wildcards).

Local mode uses `*.127-0-0-1.sslip.io` over HTTP by default.

## Related docs

- Design rationale: [`../initial-spec.md`](../initial-spec.md) (and its
  **Spec Accuracy Corrections** appendix — the corrections win over the prose).
- Build coordination + live status:
  [`../masterplans/1-bootstrap-nagare-personal-paas.md`](../masterplans/1-bootstrap-nagare-personal-paas.md).
- Implementation plans: [`../plans/`](../plans/).
- Project isolation policy: [`../../CLAUDE.md`](../../CLAUDE.md).
