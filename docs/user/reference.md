# Reference

> **Status:** ✅ Working — a quick lookup for the fixed identifiers, config keys,
> recipes, ports, and paths you'll keep needing. Values reflect the current
> repo; if one drifts, the code is the source of truth.

---

## Fixed identifiers

| Thing | Value |
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

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `gcp:project` | yes | `tan-nb-exp` | Never change. |
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
| `upload-images.sh` | Build the NixOS image on the remote builder, upload to GCS, register as a GCE image, write `nagareImageSelfLink`. |
| `setup-nix-builder.sh` | Provision the on-demand x86_64-linux Nix builder. |
| `nix-builder-startup.sh.tpl` | Startup-script template for the builder VM. |
| `iap-ssh.sh` | IAP-tunneled `ssh`/`scp`/`recv-file`/`tunnel` wrapper (macOS-safe). |

## IAM granted to `nagare-node`

| Role | Scope | Why |
| --- | --- | --- |
| `roles/dns.admin` | project | cert-manager Let's Encrypt DNS-01 solver |
| `roles/artifactregistry.writer` | project | `nagarectl` pushes images |
| `roles/storage.objectAdmin` | backup bucket only | EP-7 backup jobs write to GCS |

All via **non-authoritative** `*IAMMember` resources (never clobber the shared
project's existing bindings).

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
