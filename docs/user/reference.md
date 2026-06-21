# Reference

> **Status:** ✅ Working — a quick lookup for the fixed identifiers, config keys,
> recipes, ports, and paths you'll keep needing. Values reflect the current
> repo; if one drifts, the code is the source of truth.

---

## Default-example identifiers (derived from the target profile)

These are the values for the default-example target (`tan-nb-exp` / `us-west1`).
For your own project they **derive from `nagare.target.env`**: registry host
`<region>-docker.pkg.dev`, buckets `<project>-nagare-*`, SA `nagare-node@<project>…`.

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
| k3s kubeconfig (on host) | `/etc/rancher/k3s/k3s.yaml` (mode `0644`) |
| NixOS `stateVersion` | `26.05` |

## Target profile variables (`nagare.target.env`)

The git-ignored `nagare.target.env` (schema in `nagare.target.env.example`) is the
single source of truth for the GCP target; `nagarectl init` writes it. Precedence:
**environment > profile > built-in default**.

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

See [Getting started](getting-started.md) and [`CLAUDE.md`](../../CLAUDE.md) for the
configurable-isolation model.

## `justfile` recipes

| Recipe | Does | Plan |
| --- | --- | --- |
| `just` / `just default` | List all recipes | — |
| `just infra-preview` | `pulumi preview` the cloud perimeter | EP-2 |
| `just infra-up` | `pulumi up` the cloud perimeter | EP-2 |
| `just host-image` | Build + upload + register the NixOS GCE image (`scripts/upload-images.sh`) | EP-3 |
| `just host-switch` | `nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo` | EP-3 |
| `just cluster-bootstrap` | Apply cert-manager, Knative, Kourier, config-domain | EP-4 🔭 |
| `just observability` | Install the Victoria stack + Grafana via Helm | EP-5 🔭 |
| `just deploy-hello` | Apply the sample Knative service | EP-4 🔭 |
| `just status` | `kubectl get pods -A` + `kubectl get ksvc -A` | — |

## Pulumi config keys (`infra/pulumi/Pulumi.dev.yaml`)

These keys are a **derived projection of the target profile** — `nagarectl init`
writes them from `nagare.target.env` with `pulumi config set`; you normally don't
hand-edit `Pulumi.dev.yaml` for a new project.

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `gcp:project` | yes | `tan-nb-exp` | Your target project (default example `tan-nb-exp`). Seeded from the profile by `nagarectl init`. |
| `gcp:region` | yes | `us-west1` | |
| `gcp:zone` | yes | `us-west1-a` | |
| `nagare:imageBucket` | yes | `tan-nb-exp-nagare-images` | |
| `nagare:baseDomain` | no | `apps.example.com` | Set to your real apps domain. |
| `nagare:nagareImageSelfLink` | no | — | Set by `upload-images.sh`; **gates the VM**. |
| `nagare:instanceName` | no | `nagare-01` | |
| `nagare:machineType` | no | `e2-standard-2` | |
| `nagare:dataDiskSizeGb` | no | `100` | |
| `nagare:artifactRegistryId` | no | `nagare` | |
| `nagare:backupBucket` | no | `tan-nb-exp-nagare-backups` | |

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
--write-kubeconfig-mode=0644
--default-local-storage-path=/var/lib/nagare/local-path
```

ServiceLB (Klipper) is **left enabled** — Kourier's `LoadBalancer` Service needs
it. Only Traefik is disabled.

## Scripts (`scripts/`)

| Script | Purpose |
| --- | --- |
| `lib/target.sh` | Sourced helper: loads `nagare.target.env`, sets `TARGET_PROJECT`/`REGION`/`ZONE`, and runs the fail-closed `_require_target_project` guardrail. Every script sources it. |
| `enable-apis.sh` | Enable the six GCP service APIs against the target project (run by `nagarectl init`). |
| `upload-images.sh` | Build the NixOS image on the remote builder, upload to GCS, register as a GCE image, write `nagareImageSelfLink`. |
| `setup-nix-builder.sh` | Provision the on-demand x86_64-linux Nix builder. |
| `nix-builder-startup.sh.tpl` | Startup-script template for the builder VM (no project literal). |
| `iap-ssh.sh` | IAP-tunneled `ssh`/`scp`/`recv-file`/`tunnel` wrapper (macOS-safe). |

### `nagarectl init` (onboarding)

`nagarectl init` is the guided onboarding command (the one command permitted to
drive Pulumi/gcloud). Flags: `--project`, `--region`, `--zone`, `--base-domain`,
`--force`, `--skip-preflight`, `--skip-enable`, `--skip-seed`, `--dry-run`. It
preflights gcloud auth + the six operator IAM roles, writes `nagare.target.env`,
runs `enable-apis.sh`, and seeds the eight Pulumi keys. See
[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md).

## IAM granted to `nagare-node`

| Role | Scope | Why |
| --- | --- | --- |
| `roles/dns.admin` | project | cert-manager Let's Encrypt DNS-01 solver |
| `roles/artifactregistry.writer` | project | `nagarectl` pushes images |
| `roles/storage.objectAdmin` | backup bucket only | EP-7 backup jobs write to GCS |

All via **non-authoritative** `*IAMMember` resources (never clobber the shared
project's existing bindings).

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
| `nagarectl storage snapshot APP VOLUME [--bucket B] [--keep N]` | Tar the volume's contents to the GCS backup bucket (keeps the newest `N`, default 7). |

PVCs are named deterministically `nagare-vol-<app>-<volume>` and labelled
`nagare.dev/managed-by: nagarectl` + `nagare.dev/app=<app>` + `nagare.dev/volume=<volume>`
(the storage commands discover them by these labels). Snapshots land at
`gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz`. A
volume's data lives on the host under `/var/lib/nagare/local-path/` (see *On-host
storage layout* above). Restore with `nagarectl storage restore APP VOLUME <id>` (scratch-first).
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
| `nagarectl db backup NAME [--bucket B] [--keep N]` | Logical dump to GCS; keep-last-N retention. |
| `nagarectl db restore NAME BACKUP_ID [--into-live]` | Restore a backup, scratch-first (or into the live DB). |

All mutating commands support `--dry-run`. An app references a database by name
(the `databases` field on `Deployment`) and receives the per-engine connection
env at deploy time. Backups land at
`gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>`. See the
[Managed databases](managed-databases.md) guide.

## Domain model

```text
Internal (automatic):  service.namespace.<baseDomain>   e.g. notes.personal.apps.example.com
Public  (optional):    <your-host>                      e.g. notes.example.com  (Knative DomainMapping)
```

Wildcard `*.<baseDomain>` `A` record → static IP, created by Pulumi. Wildcard
TLS via cert-manager DNS-01 (HTTP-01 can't issue wildcards).

## Related docs

- Design rationale: [`../initial-spec.md`](../initial-spec.md) (and its
  **Spec Accuracy Corrections** appendix — the corrections win over the prose).
- Build coordination + live status:
  [`../masterplans/1-bootstrap-nagare-personal-paas.md`](../masterplans/1-bootstrap-nagare-personal-paas.md).
- Implementation plans: [`../plans/`](../plans/).
- Project isolation policy: [`../../CLAUDE.md`](../../CLAUDE.md).
