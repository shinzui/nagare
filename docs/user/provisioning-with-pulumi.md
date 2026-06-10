# Provisioning with Pulumi

> **Status:** 🟡 In progress (EP-2)
>
> The Pulumi program and its components exist and preview/apply the cloud
> perimeter. The VM resource is **gated** on the host image existing (see
> below), so a first `pulumi up` provisions everything *except* the VM until
> [the image is built](host-image-and-boot.md).

Pulumi owns every cloud resource: the network and firewall, the static IP, the
data disk, the service account and its IAM, the DNS zone and wildcard record,
the Artifact Registry, the GCS buckets, and finally the VM. The program lives in
`infra/pulumi/`.

> New to nagare? Start at
> [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md); this
> page is the provisioning detail it links. The stack config below is a **derived
> projection of the target profile** — `nagarectl init` writes it from
> `nagare.target.env`, so you normally don't hand-edit `Pulumi.dev.yaml` for a new
> project.

---

## What gets created

One Pulumi component, `NagarePerimeter`, declares the whole perimeter:

| Resource | Detail |
| --- | --- |
| **VPC + subnet** | Custom-mode VPC, single `/24` subnet (`10.10.0.0/24`) in `us-west1`. |
| **Firewall** | `80`/`443` from anywhere (Kourier ingress); `22` from the IAP range `35.235.240.0/20` only; `udp/41641` for Tailscale. |
| **Static external IP** | Regional, reserved — the VM keeps it across rebuilds so wildcard DNS stays valid. |
| **Data disk** | `pd-balanced`, 100 GB by default, attached with device name `nagare-data`, mounted at `/var/lib/nagare` by the host. |
| **Service account** | `nagare-node`, with `roles/dns.admin` (cert-manager DNS-01) and `roles/artifactregistry.writer` (image pushes) on the project, plus `roles/storage.objectAdmin` on the backup bucket only. |
| **Cloud DNS zone** | Managed zone for `<baseDomain>` with a wildcard `A` record `*.<baseDomain>` → static IP (TTL 300). |
| **Artifact Registry** | Docker repo `nagare` in `us-west1` → `us-west1-docker.pkg.dev/tan-nb-exp/nagare`. |
| **Backup bucket** | `tan-nb-exp-nagare-backups`, uniform bucket-level access, `forceDestroy: false`. |
| **Image-staging bucket** | `tan-nb-exp-nagare-images`, where the NixOS `*.raw.tar.gz` is uploaded before image registration. |
| **VM** (`nagare-01`) | `e2-standard-2`, boots the registered NixOS image, attaches the static IP and data disk, runs as the service account. **Only declared once `nagareImageSelfLink` config is set.** |

The resource **names derive from your project/region**: the registry host is
`<region>-docker.pkg.dev`, the buckets are `<project>-nagare-images` /
`<project>-nagare-backups`, and the service account is `nagare-node@<project>…`.
The `tan-nb-exp` / `us-west1` values shown above are the worked default example.

IAM uses the **non-authoritative** `*IAMMember` variants so it never clobbers
existing bindings on the target project (which may be a shared project).

## Configuration

Config is in `infra/pulumi/Pulumi.dev.yaml` (stack `dev`). The keys:

| Key | Required? | Default | Notes |
| --- | --- | --- | --- |
| `gcp:project` | yes | `tan-nb-exp` | Your target project (the default example is `tan-nb-exp`). Seeded from the target profile by `nagarectl init`. |
| `gcp:region` | yes | `us-west1` | |
| `gcp:zone` | yes | `us-west1-a` | |
| `nagare:imageBucket` | yes | `tan-nb-exp-nagare-images` | Image-staging bucket. |
| `nagare:baseDomain` | no | `apps.example.com` | The wildcard apps domain. **Set this to your real domain.** |
| `nagare:nagareImageSelfLink` | no | — | Set by `scripts/upload-images.sh`. Gates the VM. |
| `nagare:instanceName` | no | `nagare-01` | |
| `nagare:machineType` | no | `e2-standard-2` | `e2-standard-4` for more headroom. |
| `nagare:dataDiskSizeGb` | no | `100` | |
| `nagare:artifactRegistryId` | no | `nagare` | |
| `nagare:backupBucket` | no | `tan-nb-exp-nagare-backups` | |

Set a value with, e.g.:

```bash
cd infra/pulumi
pulumi config set nagare:baseDomain apps.yourdomain.com
```

> **`baseDomain` is a real decision.** The default `apps.example.com` is a
> placeholder. Whatever you set becomes the Cloud DNS zone and the wildcard
> record, and later the suffix of every app's internal URL
> (`service.namespace.<baseDomain>`). You must also delegate this zone from your
> registrar to the Cloud DNS nameservers — see [Cluster bootstrap](cluster-bootstrap.md).

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
