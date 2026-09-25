---
type: Reference
title: "Reference"
description: "Look up Nagare identifiers, context variables, commands, infrastructure contracts, ports, paths, and operational interfaces."
docId: DOC-29
tags: [nagare, commands, configuration, infrastructure, reference]
generated:
  by: human:nadeem
  at: 2026-09-12T21:26:55Z
---

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
| Generated host | `tan-nb-exp-nagare` (NixOS, flake attribute, and Tailscale identity) |
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
  kubeconfigs/<name>.yaml
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

Encrypted cluster bootstrap credentials are not workspace assets. They default
to `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/`; set
`NAGARE_CLUSTER_SECRETS_DIR` for an explicit operator-owned location. Source
checkouts still read a `cluster/secrets/` directory as a compatibility fallback,
but the public repository ships none.

Fetched Kubernetes credentials live at `kubeconfigs/<context>.yaml` by default. Each private
mode-`0600` file names its cluster, user, and current context after the Nagare context and points at
that context's generated host name. It is operator state, not part of the immutable workspace.

Reviewed infrastructure plans are operator-confidential directories chosen with
`infra preview --save-plan`; each contains `pulumi-plan.json`, `review.json`, and `metadata.json`.
An upgrade keeps the same bundle under its private transaction directory and records Pulumi apply
state in mode-`0600` `pulumi-apply-receipt.json`. This receipt is transaction-bound evidence; it is
not a file to edit or remove during recovery.
Per-context builder routing lives at
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/nix-builder/{ssh_config,builders}`. Both use a
private mode-`0700` directory and mode-`0600` files.

| Platform command | Does |
| --- | --- |
| `nagarectl platform status [--json]` | Compare CLI, payload, context, host, and cluster release identities. |
| `nagarectl platform adopt --version VERSION --yes` | Confirm observations and assign the first explicit release to a legacy context. |
| `nagarectl platform upgrade --to VERSION --dry-run [--json]` | Persist Nix, Pulumi, and Kubernetes preflight results without mutating the target. |
| `nagarectl platform upgrade --apply --resume ID --yes` | Apply or resume a reviewed transaction; advance the context pin last. |
| `nagarectl platform upgrade status [ID] [--json]` | Inspect a selected or latest context-owned transaction. |
| `nagarectl platform upgrade recover-pulumi ID --outcome applied\|retry --yes` | Record an audited decision for an ambiguous or pre-receipt Pulumi outcome. |
| `nagarectl platform upgrade rollback ID --yes` | Reverse the release selection only when target metadata permits it. |

When invoking these platform commands from an immutable release without installing it, use
`nix shell "${TARGET_NAGARE}#nagare" -c nagarectl ...`. The `#nagare` package carries the
release-pinned operator tools; the smaller `#nagarectl` output is for application-only work.

See [Upgrades](upgrades.md) for compatibility states, recovery, and rollback
boundaries.

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
| `NAGARE_NIX_CACHE_ENABLED` | `0` | cloud-only Attic opt-in (`0` or `1`) |
| `NAGARE_NIX_CACHE_BUCKET` | `tan-nb-exp-nagare-nix-cache` | `<project>-nagare-nix-cache` |
| `NAGARE_BASE_DOMAIN` | `apps.example.com` | wildcard apps domain |
| `NAGARE_ACME_EMAIL` | — (none) | Let's Encrypt contact for the cluster's ACME account. **No default**; rendering the `letsencrypt-dns` ClusterIssuer refuses without it. See [ACME identity](contexts.md#acme-identity). |
| `NAGARE_ACME_DIRECTORY` | `production` | ACME service: `production`, `staging` (untrusted certs, looser rate limits), or an absolute `https://` directory URL. An unrecognized value is an error, not a fallback. |
| `NAGARE_INSTANCE_NAME` | `nagare-01` | the VM instance name |
| `NAGARE_MACHINE_TYPE` | `e2-standard-2` | GCE machine type; live changes are in-place stop/start resizes |
| `NAGARE_BOOT_DISK_TYPE` | `pd-balanced` | boot-disk type; changing a live VM replaces the instance |
| `NAGARE_BOOT_DISK_SIZE_GB` | `100` | boot-disk size in GB; changing a live value replaces the instance and its boot-resident k3s state; shrinking is unsupported |
| `NAGARE_DATA_DISK_SIZE_GB` | `100` | protected data-disk size in GB; growth only |
| `NAGARE_TARGET_PLATFORM` | `linux/amd64` | Docker/Nixpacks build platform for cloud node images |
| `NAGARE_BUILDER_PROJECT` | target project | GCP project of the context's x86_64 Nix builder; a different value also requires `--allow-shared-builder PROJECT`. |
| `NAGARE_BUILDER_ZONE` | target zone | GCE zone of the Nix builder. |
| `NAGARE_BUILDER_INSTANCE` | `nix-builder-x86` | GCE instance selected by the context-owned builder proxy. |
| `NAGARE_PULUMI_BACKEND` | `local` | Pulumi state backend: `local` (per-context `file://`) or `gcs` (opt-in remote, cloud-only). |
| `NAGARE_PULUMI_BACKEND_URL` | — (derived) | explicit `gs://bucket/path`; empty + `gcs` derives `gs://<project>-nagare-pulumi-state/nagare/<context>`. |
| `NAGARE_PLATFORM_VERSION` | current payload for new contexts | explicit per-context release intent; absent means legacy/unadopted. |

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

Local mode uses neither `NAGARE_ACME_EMAIL` nor `NAGARE_ACME_DIRECTORY`: it never
contacts Let's Encrypt. `just local-bootstrap` installs the `nagare-local-ca`
ClusterIssuer and configures Knative external-domain TLS to use it.

## Host-switch identity variables

The generated `host.nix`, not the GCE instance variable, is the default source for NixOS and
Tailscale identity. `nagarectl host name [--context NAME] [--json]` prints that validated name.

| Variable | Default | Purpose |
| --- | --- | --- |
| `NAGARE_HOST_ATTR` | generated host name | Nix attribute below `nixosConfigurations`; a direct troubleshooting override only. |
| `NAGARE_SSH_HOST` | `NAGARE_HOST_ATTR`, then generated host name | Logical Tailscale/SSH destination; use `NIX_SSHOPTS` to map that name through another transport such as an IAP localhost tunnel. |
| `NAGARE_SSH_USER` | `deploy` | User prepended to the logical SSH destination. |
| `NAGARE_INSTANCE_NAME` | `nagare-01` | GCE resource identity for `gcloud` and IAP; never a Nix attribute or host-switch SSH fallback. |

`nagarectl platform upgrade` replaces the first two values with the identity preserved in the
transaction's staged host flake, so inherited values from another context cannot redirect apply.

## `nagarectl context` commands

| Command | Does |
| --- | --- |
| `nagarectl context list` | List stored contexts and mark the current one. |
| `nagarectl context current` | Print the current context name. |
| `nagarectl context use NAME` | Set the current context, select its Pulumi stack/backend, and regenerate its config projection. |
| `nagarectl context show [NAME]` | Print a context bundle as `export VAR=value`; with no name, show the active context. |
| `nagarectl context create NAME [flags]` | Write a context. Flags include `--project`, `--region`, `--zone`, `--base-domain`, `--machine-type`, `--boot-disk-type`, `--boot-disk-size-gb`, `--data-disk-size-gb`, `--registry-host`, `--artifact-registry-id`, `--image-bucket`, `--backup-bucket`, `--enable-nix-cache`/`--disable-nix-cache`, `--nix-cache-bucket`, `--instance-name`, `--target-platform`, `--mode`, `--local-object-store`, `--acme-email`, `--acme-directory` (`production`\|`staging`\|URL), `--pulumi-backend` (`local`\|`gcs`), `--pulumi-backend-url`, `--pulumi-backend-member`, `--force`, and `--use`. The cache is cloud-only and defaults off. Both ACME flags are optional here (unlike `nagarectl init`) because this command also writes local contexts. With `--force` on an existing context, only the passed flags change; every other field and the platform pin are kept. |
| `nagarectl context delete NAME --yes` | Delete a context. If it was current, clear the pointer. |
| `nagarectl infra guard [--allow-replacement]` | Compatibility guard that previews and classifies protected replacements. New apply workflows use the saved-plan commands below. |
| `nagarectl infra preview --save-plan DIR [--allow-replacement]` | Guard, save, classify, and bind one Pulumi preview as a private immutable bundle. |
| `nagarectl infra apply --plan DIR --yes [--allow-replacement]` | Re-run guards, verify the bundle and current bindings, then apply exactly its Pulumi plan without a TTY. |
| `nagarectl infra destroy --yes` | Re-run the platform, ADC, and project guards immediately before deliberate selected-stack teardown. |
| `nagarectl host init [--context NAME] --ssh-public-key-file PATH... --sops-file PATH` | Atomically generate and Nix-evaluate a context-owned host flake. `--dry-run` needs no secrets file; `--force` preserves an existing encrypted file when `--sops-file` is omitted. |
| `nagarectl host place-age-key [--context NAME] --key-file PATH [--force]` | Validate and SHA-256 hash an operator-held age identity, stream it over context-confined IAP SSH stdin, activate sops-nix, and start Tailscale. Replaying the same key is idempotent; replacing a different key requires interruption-sensitive `--force`. |
| `nagarectl host show [--context NAME]` | Print the generated public operator module. |
| `nagarectl host path [--context NAME]` | Print the generated host-flake path. |
| `nagarectl host name [--context NAME] [--json]` | Print the generated NixOS/flake/Tailscale host name after validating that `host.nix` declares it exactly once. |
| `nagarectl kubeconfig fetch [--context NAME] [--output FILE]` | Fetch k3s credentials through the context's project-confined IAP transport, normalize all identities and the API endpoint, and atomically install a private per-context kubeconfig. |
| `nagarectl cluster guard [--context NAME] [--json]` | Refuse unless ambient kubectl selects the named Nagare context and reports exactly its context-owned server node. Cloud Kubernetes mutation recipes run this automatically. |

`nagarectl --context NAME ...` is the global per-command target selector.
Shell recipes use `NAGARE_CONTEXT=NAME just <recipe>`.

## `justfile` recipes

| Recipe | Does | Plan |
| --- | --- | --- |
| `just` / `just default` | List all recipes | — |
| `just infra-preview --save-plan DIR` | Save and classify one guarded cloud-perimeter plan | MP-22 EP-136 |
| `just infra-up --plan DIR --yes` | Verify and non-interactively apply the exact reviewed plan | MP-22 EP-136 |
| `just infra-destroy --yes` | Guard and deliberately destroy the selected Pulumi stack | MP-22 EP-136 |
| `just vm-stop` / `just vm-start` | Stop or start the context-selected VM without changing disks or the static IP | MP-8 |
| `just host-image [--dry-run] [--allow-shared-builder PROJECT]` | Build + upload + register the NixOS GCE image with an explicit context-owned builder (`scripts/upload-images.sh`) | MP-22 EP-136 |
| `just nixos-registry-host` | Compatibility alias that shows the generated host module; it no longer writes source | MP-20 EP-107 |
| `just host-switch` | Apply the active context's generated NixOS configuration | MP-20 EP-107 |
| `just cluster-bootstrap` | Guard the selected cluster; apply cert-manager, Knative, Kourier, and config-domain; import the payload's patched latest net-certmanager controller; verify certificate policy | EP-4 ✅ / MP-22 EP-134, EP-138 |
| `just cluster-enable-tls` | Guard the selected cluster, then enable Knative external-domain TLS after DNS delegation | EP-4 / MP-22 EP-134 |
| `just job-runs-bootstrap` | Guard the selected cluster, then apply the two-slot ResourceQuota for deadline-bounded one-shot Jobs in `personal` | MP-18 EP-95 ✅ / MP-22 EP-134 |
| `just job-runs-status` | Show bounded-run quota use, admitted Pods, and `FailedCreate` backpressure events | MP-18 EP-95 ✅ |
| `nagare nix-cache-secret-init [--rotate]` | Write context-owned sops ciphertext for Attic JWT and GCS HMAC credentials | MP-18 EP-96 |
| `nagare nix-cache-publish` | Mirror the payload's digest-pinned Attic image into the selected registry | MP-18 EP-96 |
| `nagare nix-cache-bootstrap` | Reconcile the enabled Attic database, server, cache, policies, and consumer ConfigMap | MP-18 EP-96 |
| `nagare nix-cache-status` | Report readiness, public trust, retention, schedules, and ConfigMap digest without credentials | MP-18 EP-96 |
| `just context-show` | Print the selected kubectl context and API server without contacting the cluster | MP-8 |
| `just local-up` | Create local k3d cluster + local registry | MP-16 EP-82 |
| `just local-bootstrap` | Install Knative/Kourier locally with the `nagare-local-ca` TLS issuer | MP-16 EP-82 / EP-85 |
| `just local-minio` | Install local MinIO backup object store | MP-16 EP-84 |
| `just local-down` | Delete the local k3d cluster and registry | MP-16 EP-82 |
| `nagare local-smoke` (`just local-smoke` in a checkout) | Local zero-cloud smoke: deploy → volume/database backup+restore (MinIO) → HTTP 200 → teardown | MP-16 EP-86 / MP-19 EP-101 |
| `nagare observability` (`just observability` in a checkout) | Guard the selected cluster, then install the Victoria stack + Grafana via Helm using context-owned encrypted Secrets | EP-5 / MP-19 EP-101 / MP-22 EP-134 |
| `just deploy-hello` | Guard the selected cluster, then apply the sample Knative service | EP-4 ✅ / MP-22 EP-134 |
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
| `nagare:dataDiskSizeGb` | no | `100` | Data-disk (`/var/lib/nagare`) size in GiB. An increase is an in-place update and the filesystem grows online; shrinking is refused (`protect: true`). See [Growing the data disk](resizing-the-vm.md#growing-the-data-disk). |
| `nagare:bootDiskSizeGb` | no | `100` | Boot-disk size in GiB. Any live change replaces the instance and loses its boot-resident k3s state; shrinking is unsupported. Size it for the VM lifetime. |
| `nagare:bootDiskType` | no | `pd-balanced` | Changing a live VM's disk type forces instance replacement; pin the current type until a deliberate rebuild. |
| `nagare:vmDeletionProtection` | no | `true` | GCE refuses instance deletion/replacement while true. Disable only for the deliberate rebuild window, then re-enable. |
| `nagare:artifactRegistryId` | no | `nagare` | |
| `nagare:backupBucket` | no | `tan-nb-exp-nagare-backups` | |
| `nagare:enableNixCache` | no | `false` | Opt in to the cloud-only Attic provider. |
| `nagare:nixCacheBucket` | no | `<project>-nagare-nix-cache` | Dedicated unversioned cache-chunk bucket. |
| `nagare:enableCdn` | no | `false` | Opt in to the standing, billable Google Cloud CDN load balancer. |
| `nagare:cdnCertificateMode` | no | `legacy` | Google edge-certificate migration: `legacy`, `prepare`, or `certificate-map`. Invalid text fails the Pulumi program. Existing stacks stay legacy until explicitly prepared and activated. |

## Pulumi stack outputs (the integration contract — names are stable)

`publicIp`, `apexIp`, `sshCommand`, `baseDomain`, `instanceName`, `serviceAccountEmail`,
`dataDiskName`, `dnsZoneName`, `artifactRegistry`, `backupBucket`, `nixCacheEnabled`,
`nixCacheBucket`, `nixCacheHmacAccessId`, secret `nixCacheHmacSecret`, `cdnGlobalIp`,
`cdnBackendService`, `cdnUrlMap`, `cdnCertificate`, `cdnCertificateMap`,
`cdnCertificateMode`.

`publicIp` is the VM and wildcard-DNS target. `apexIp` is the exact base-domain target: it equals
`cdnGlobalIp` when the opt-in CDN component exists and otherwise equals `publicIp`.

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
| `lib/host.sh` | Resolve and validate `NAGARE_HOST_FLAKE`, defaulting to `nagarectl host path` for the active context. |
| `enable-apis.sh` | Enable the six GCP service APIs against the target project (run by `nagarectl init`). |
| `upload-images.sh` | Render an explicit per-context builder, build the NixOS image, upload to GCS, register it, and write `nagareImageSelfLink`. |
| `nix-builder-proxy.sh` | Packaged as `nagare-nix-builder-proxy`; start one positional project/zone/instance and proxy SSH through an IAP local tunnel. |
| `host-switch.sh` | Apply the active generated host flake over its logical Tailscale/SSH name; `--dry-run` prints the GCE instance, Nix attribute, and SSH target separately. |
| `setup-nix-builder.sh` | Provision the on-demand x86_64-linux Nix builder. |
| `nix-builder-startup.sh.tpl` | Startup-script template for the builder VM (no project literal). |
| `iap-ssh.sh` | IAP-tunneled `ssh`/`scp`/`recv-file`/`tunnel` wrapper (macOS-safe), exposed from installed releases as `nagare iap-ssh`. |
| `live-test.sh` | Open the IAP + SSH kube-apiserver forward, fetch/rewrite kubeconfig, and print the environment to use. |
| `vm-power.sh` | Context-guarded VM `start`/`stop` implementation used by the `just` recipes. |
| `migrate-pulumi-backend.sh` | Export/import one context's state between its local file backend and opt-in GCS backend. |
| `live-smoke.sh` | Cloud deploy + GCS-backed volume snapshot/restore + HTTP + teardown acceptance path. |
| `local-smoke.sh` | Zero-cloud k3d/MinIO equivalent of the live smoke path. |

### `nagarectl init` (onboarding)

`nagarectl init [NAME]` is the guided onboarding command (the one command
permitted to drive Pulumi/gcloud). Flags: `--project`, `--region`, `--zone`,
`--base-domain`, `--machine-type`, `--boot-disk-type`, `--boot-disk-size-gb`,
`--data-disk-size-gb`, `--acme-email`, `--acme-directory` (`production`\|`staging`\|URL),
`--pulumi-backend` (`local`\|`gcs`), `--pulumi-backend-url`,
`--pulumi-backend-member`, `--force`, `--skip-preflight`, `--skip-enable`,
`--skip-seed`, `--dry-run`. `--acme-email` is **required**: on a terminal it is
prompted for, and a non-interactive run without it exits non-zero naming the
flag. With `NAME`, it preflights gcloud auth + the six operator IAM roles,
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
| `nagarectl app deploy [-f FILE] [--dry-run] [--json]` | Direct live rollout supports hooks; reviewed `--dry-run` requires an explicit tag and accepted image resource, and prints public scope identities or JSON without native Secret values. |
| `nagarectl app list [-n NS] [--all]` | List Nagare-managed Knative apps; `--all` includes unmanaged Services. |
| `nagarectl app get NAME [-n NS]` | Show image, revision, URL, readiness, and config-enriched limits/domains when available. |
| `nagarectl app logs NAME [--follow] [--tail N]` | Show or stream current app logs. |
| `nagarectl app restart NAME` | Create a fresh revision and bring a stopped app back online. |
| `nagarectl app stop NAME` | Recoverably take an app offline. |
| `nagarectl app delete NAME [--save-plan DIR] [--scope-key KEY]` | Direct delete removes a legacy Service, DomainMappings, and history. `--save-plan` reviews retirement of the accepted application or standalone web-Service scope and retains all its managed resources. |
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
| `nagarectl cdn status HOST` | Show provider, DNS target, cache config, readiness, and Certificate Manager state. In `prepare`, print the exact map-activation command only after the certificate is `ACTIVE`. |
| `nagarectl cdn purge HOST [--path PATH ...] [--dry-run]` | Purge everything or selected paths from the edge cache. |
| `nagarectl cdn disable HOST [--dry-run]` | Delete a supported first-level exact record so wildcard DNS restores the VM/origin. Refuses the Pulumi-owned apex and unsupported Google hostname shapes. |

See [CDN (edge caching)](cdn.md).

## Platform inspection and cleanup commands

| Command | Does |
| --- | --- |
| `nagarectl server status [--skip-vm]` | Print one-screen VM, host age-key, disk, Kubernetes, ingress, observability, app, database, and backup inventory. Ready is `OK`; confirmed missing/invalid is `FAIL`; an old or unreachable host is `UNKNOWN`. `--skip-vm` avoids the shared IAP/SSH host probe. |
| `nagarectl doctor [--skip-vm]` | Run platform health checks with remediation hints; a confirmed host age-key failure points to `nagarectl host place-age-key --key-file <private-key-file>` and exits 1. `UNKNOWN` remains a warning. |
| `nagarectl cluster certificate-policy` | Fail if a public ACME certificate contains an internal name or a public wildcard belongs to an unlabeled namespace. |
| `nagarectl domains list [-n NS] [--all-namespaces] [--base-domain DOMAIN] [--json]` | Show live public DNS, route, and certificate observations. Partial/unavailable observations still exit successfully; JSON schema version is 1. |
| `nagarectl domains check [-n NS] [--all-namespaces] [--base-domain DOMAIN] [--json]` | Print the same inventory and exit non-zero for missing/mismatched DNS, unavailable or unready routes, or non-ready certificates while TLS is enabled. |
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
TLS via cert-manager DNS-01 (HTTP-01 can't issue wildcards). Only namespaces
labeled `nagare.dev/app-namespace=true` are eligible; internal and cluster-local
certificates remain on `knative-selfsigned-issuer`.

Local bootstrap enables HTTPS for `*.127-0-0-1.sslip.io` and exact
DomainMappings with the `nagare-local-ca` issuer. Automated checks export only
the public CA certificate and use `curl --cacert`.

## Related docs

- Design rationale: [`../initial-spec.md`](../initial-spec.md) (and its
  **Spec Accuracy Corrections** appendix — the corrections win over the prose).
- Build coordination + live status:
  [`../masterplans/1-bootstrap-nagare-personal-paas.md`](../masterplans/1-bootstrap-nagare-personal-paas.md).
- Implementation plans: [`../plans/`](../plans/).
- Project isolation policy: [`../../CLAUDE.md`](../../CLAUDE.md).
