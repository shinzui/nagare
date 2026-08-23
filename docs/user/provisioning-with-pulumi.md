# Provisioning with Pulumi

> **Status:** 🟡 In progress (EP-2)
>
> The Pulumi program and its components exist and preview/apply the cloud
> perimeter. The VM resource is **gated** on the host image existing (see
> below), so a first `pulumi up` provisions everything *except* the VM until
> [the image is built](host-image-and-boot.md). EP-99's disk, bucket, IAM, and
> VM protection changes are implemented in the program but still await preview,
> apply, and verification against the operator-controlled cloud context.

Pulumi owns every cloud resource: the network and firewall, the static IP, the
data disk, the service account and its IAM, the DNS zone and wildcard record,
the Artifact Registry, the GCS buckets, and finally the VM. The program lives in
`infra/pulumi/`.

> New to nagare? Start at
> [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md); this
> page is the provisioning detail it links. The stack config below is a **derived
> projection of the active context** — `nagarectl init NAME` and
> `nagarectl context use NAME` write `Pulumi.<context>.yaml`, so you normally
> don't hand-edit Pulumi stack config for a new project.

---

## What gets created

One Pulumi component, `NagarePerimeter`, declares the whole perimeter:

| Resource | Detail |
| --- | --- |
| **VPC + subnet** | Custom-mode VPC, single `/24` subnet (`10.10.0.0/24`) in `us-west1`. |
| **Firewall** | `80`/`443` from anywhere (Kourier ingress); `22` from the IAP range `35.235.240.0/20` only; `udp/41641` for Tailscale. |
| **Static external IP** | Regional, reserved — the VM keeps it across rebuilds so wildcard DNS stays valid. |
| **Data disk** | `pd-balanced`, 100 GB by default, attached as `nagare-data` and mounted at `/var/lib/nagare`. Pulumi protects it from deletion and attaches a daily 08:00 UTC snapshot schedule with seven-day retention; automatic snapshots survive source-disk deletion. |
| **Service account** | `nagare-node`, with `roles/dns.admin` on Nagare's managed zone, project-level `roles/dns.reader` for zone discovery, project-level `roles/artifactregistry.writer`, and `roles/storage.objectAdmin` on the backup bucket only. |
| **Cloud DNS zone** | Managed zone for `<baseDomain>` with a wildcard `A` record `*.<baseDomain>` → static IP (TTL 300). |
| **Artifact Registry** | Docker repo `nagare` in `us-west1` → `us-west1-docker.pkg.dev/tan-nb-exp/nagare`. |
| **Backup bucket** | `tan-nb-exp-nagare-backups`, protected in Pulumi, uniform-access, non-public, `forceDestroy: false`, with object versioning and 30-day cleanup of noncurrent versions. |
| **Image-staging bucket** | `tan-nb-exp-nagare-images`, non-public and `forceDestroy: false`; the NixOS `*.raw.tar.gz` is staged here before image registration. |
| **VM** (`nagare-01`) | `e2-standard-2`, 100 GB `pd-balanced` boot disk, GCE deletion protection on by default, static IP and data disk attached, running as the node service account. **Only declared once `nagareImageSelfLink` is set.** |

The resource **names derive from your project/region**: the registry host is
`<region>-docker.pkg.dev`, the buckets are `<project>-nagare-images` /
`<project>-nagare-backups`, and the service account is `nagare-node@<project>…`.
The `tan-nb-exp` / `us-west1` values shown above are the worked default example.

IAM uses the **non-authoritative** `*IAMMember` variants so it never clobbers
existing bindings on the target project (which may be a shared project).

## Configuration

Each target context maps to a Pulumi stack with the same name. Config is the
git-ignored projection `infra/pulumi/Pulumi.<context>.yaml`, and state lives in
that context's file backend under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state`. The keys:
See [Target contexts](contexts.md) for context selection and migration from old
profile files.

| Key | Required? | Default | Notes |
| --- | --- | --- | --- |
| `gcp:project` | yes | `tan-nb-exp` | Your target project (the default example is `tan-nb-exp`). Seeded from the context by `nagarectl init NAME` / `context use`. |
| `gcp:region` | yes | `us-west1` | |
| `gcp:zone` | yes | `us-west1-a` | |
| `nagare:imageBucket` | yes | `tan-nb-exp-nagare-images` | Image-staging bucket. |
| `nagare:baseDomain` | no | `apps.example.com` | The wildcard apps domain. **Set this to your real domain.** |
| `nagare:nagareImageSelfLink` | no | — | Set by `scripts/upload-images.sh`. Gates the VM. |
| `nagare:instanceName` | no | `nagare-01` | |
| `nagare:machineType` | no | `e2-standard-2` | `e2-standard-4` for more headroom. |
| `nagare:dataDiskSizeGb` | no | `100` | |
| `nagare:bootDiskSizeGb` | no | `100` | Boot-disk size. Increasing is supported; shrinking is not. |
| `nagare:bootDiskType` | no | `pd-balanced` | Changing a live VM's type forces instance replacement; pin its existing type until a deliberate rebuild. |
| `nagare:vmDeletionProtection` | no | `true` | GCE blocks deletion and replacement while true. Temporarily disable only during an intentional VM rebuild. |
| `nagare:artifactRegistryId` | no | `nagare` | |
| `nagare:backupBucket` | no | `tan-nb-exp-nagare-backups` | |
| `nagare:enableCdn` | no | `false` | Opt in to the standing, billable Google Cloud CDN resources. |

Set a value with, e.g.:

```bash
cd infra/pulumi
pulumi config set nagare:baseDomain apps.yourdomain.com --stack "$(nagarectl context current)"
```

> **`baseDomain` is a real decision.** The default `apps.example.com` is a
> placeholder. Whatever you set becomes the Cloud DNS zone and the wildcard
> record, and later the suffix of every app's internal URL
> (`service.namespace.<baseDomain>`). You must also delegate this zone from your
> registrar to the Cloud DNS nameservers — see [Cluster bootstrap](cluster-bootstrap.md).

### State backend: local (default) or GCS (opt-in)

By default each context's Pulumi **state** lives in the local file backend shown
above. A cloud context can opt into a remote **Google Cloud Storage** backend so
the context is usable from multiple machines and recoverable after a lost laptop:

```bash
nagarectl context create prod --project acme-prod --pulumi-backend gcs --use
# or, on an existing context, migrate with export/import:
scripts/migrate-pulumi-backend.sh --context prod
```

This bootstraps a versioned, uniform-access `gs://<project>-nagare-pulumi-state`
bucket (distinct from the backup bucket), points `PULUMI_BACKEND_URL` at
`gs://<project>-nagare-pulumi-state/nagare/<context>`, and keeps `PULUMI_HOME`
local. Local file state remains the default and the only local-mode option. See
[Remote GCS Pulumi state](contexts.md#remote-gcs-pulumi-state-opt-in-cloud-contexts-only)
for the bucket naming, required IAM, and migration/rollback details.

## Preview and apply

From the dev shell:

```bash
just infra-preview     # cd infra/pulumi && pulumi preview
just infra-up          # cd infra/pulumi && pulumi up
```

On a clean checkout the first `pulumi up` creates everything **except the VM**,
because `nagareImageSelfLink` isn't set yet. That's expected and correct — the
network, IP, disk, DNS, registry, buckets, and IAM are exactly what the host
image build and the cluster need to exist first. You'll run `pulumi up` again
after [building the image](host-image-and-boot.md) to bring up the VM.

### Review replacements and protected resources

Always read `just infra-preview` before applying. The program deliberately
fails closed around stateful resources:

- the data disk and backup bucket have Pulumi `protect: true`, so a deletion or
  replacement fails until you explicitly run `pulumi state unprotect <URN>`;
- the VM has GCE deletion protection by default, so image or boot-disk-type
  changes that require replacement fail until you set
  `nagare:vmDeletionProtection false` and apply; and
- a later apply reasserts the declared protections. `unprotect` is a temporary
  state operation, not a permanent code change.

For a deliberate VM rebuild, leave the data disk and backup bucket protected.
Disable only VM deletion protection and apply that change **before** changing
the image self-link or boot-disk type; then apply the replacement and re-enable
protection:

```bash
pulumi -C infra/pulumi config set nagare:vmDeletionProtection false
just infra-up                  # protection-only update on the existing VM

# now run just host-image, or change the replacement-causing boot-disk setting
just infra-preview             # replacement must preserve nagare-data
just infra-up                  # deliberate VM replacement

pulumi -C infra/pulumi config set nagare:vmDeletionProtection true
just infra-up
```

Do not use this sequence to force through an unexpected data-disk or
backup-bucket replacement. Stop and reconcile the preview first.

## Stack outputs (the integration contract)

After `pulumi up`, these outputs are published. Other steps and plans read them
by name with `pulumi stack output <name>`; **the names are a stable contract** —
don't rename them.

| Output | Example / meaning |
| --- | --- |
| `publicIp` | The reserved static IP. |
| `sshCommand` | A ready-to-paste `gcloud compute ssh … --tunnel-through-iap`. |
| `baseDomain` | The apps domain. |
| `instanceName` | `nagare-01`. |
| `serviceAccountEmail` | `nagare-node@tan-nb-exp.iam.gserviceaccount.com`. |
| `dataDiskName` | The data disk resource name. |
| `dnsZoneName` | The Cloud DNS managed zone name (used by cert-manager's DNS-01 solver). |
| `artifactRegistry` | `us-west1-docker.pkg.dev/tan-nb-exp/nagare`. |
| `backupBucket` | `tan-nb-exp-nagare-backups`. |

Read one:

```bash
cd infra/pulumi
pulumi stack output publicIp
pulumi stack output dnsZoneName
```

## Verify

A successful provisioning looks like:

- `pulumi up` completes with no errors.
- `pulumi stack output publicIp` returns an IP.
- The Cloud DNS zone exists and the wildcard `A` record points at that IP.
- The Artifact Registry, both buckets, the service account, and its IAM exist.

The VM appears only after the next section.

## Next

Build and register the NixOS image, then re-run `pulumi up` to boot the VM:
**[Host image and first boot →](host-image-and-boot.md)**
