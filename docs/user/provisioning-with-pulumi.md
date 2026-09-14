---
type: Runbook
title: "Provisioning with Pulumi"
description: "Configure, preview, apply, verify, and recover Nagare cloud infrastructure managed by Pulumi."
docId: DOC-28
tags: [pulumi, provisioning, gcp, infrastructure]
generated:
  by: human:nadeem
  at: 2026-09-12T21:26:55Z
---

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
> `nagarectl context use NAME` write `Pulumi.<context>.yaml` (a symlink to the
> context-owned file described in [Target contexts](contexts.md)), so you normally
> don't hand-edit Pulumi stack config for a new project.

---

## What gets created

One Pulumi component, `NagarePerimeter`, declares the whole perimeter:

| Resource | Detail |
| --- | --- |
| **VPC + subnet** | Custom-mode VPC, single `/24` subnet (`10.10.0.0/24`) in `us-west1`. |
| **Firewall** | `80`/`443` from anywhere (Kourier ingress); `22` from the IAP range `35.235.240.0/20` only; `udp/41641` for Tailscale. |
| **Static external IP** | Regional, reserved — the VM keeps it across rebuilds so wildcard DNS stays valid. |
| **Data disk** | `pd-balanced`, 100 GB by default, attached as `nagare-data` and mounted at `/var/lib/nagare`. A blank disk is formatted before fsck, mounted, and brought through layout to a `Ready` k3s node during the first boot, without a reboot. Pulumi protects it from deletion and attaches a daily 08:00 UTC snapshot schedule with seven-day retention; automatic snapshots survive source-disk deletion. |
| **Service account** | `nagare-node`, with `roles/dns.admin` on Nagare's managed zone, project-level `roles/dns.reader` for zone discovery, project-level `roles/artifactregistry.writer`, and `roles/storage.objectAdmin` on the backup bucket only. |
| **Cloud DNS zone** | Managed zone for `<baseDomain>` with two `A` records at TTL 300: `*.<baseDomain>` always points to the VM's static `publicIp`; exact `<baseDomain>` points to exported `apexIp`, which is the standing CDN's global IP when the CDN exists and otherwise equals `publicIp`. |
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

Each target context maps to a Pulumi stack with the same name. Config lives at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi/Pulumi.<context>.yaml`, linked into
`infra/pulumi/Pulumi.<context>.yaml` of every workspace, and state lives in
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
| `nagare:dataDiskSizeGb` | no | `100` | Data-disk (`/var/lib/nagare`) size in GiB. An increase is an in-place update and the filesystem grows online; shrinking is refused (`protect: true`). See [Growing the data disk](resizing-the-vm.md#growing-the-data-disk). |
| `nagare:bootDiskSizeGb` | no | `100` | Boot-disk size in GiB. Any live change replaces the instance and loses its boot-resident k3s state; shrinking is unsupported. Size it for the VM lifetime. |
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
for the bucket naming, required IAM, and migration/rollback details. After a
migration, reload every shell (`direnv reload`) so no stale environment keeps
pointing Pulumi at the old local state.

## Preview and apply

Create a new private review bundle, inspect its `review.json`, and apply that exact bundle:

```bash
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/$(date +%Y%m%dT%H%M%S)"
nagare infra-preview --save-plan "$plan_dir"
jq . "$plan_dir/review.json"
nagare infra-up --plan "$plan_dir" --yes
```

Preview invokes Pulumi once with `--save-plan`. The bundle contains Pulumi's `pulumi-plan.json`, a
redacted operation classification in `review.json`, and Nagare's `metadata.json`. Metadata binds the
review to the context, GCP project, stack, backend, immutable payload, Pulumi program and config,
Pulumi version, and both file digests. The directory is mode `0700`; its three files are mode `0600`.
Treat the whole directory as confidential operator state: Pulumi's plan may contain configuration
and provider inputs even though Nagare's review is redacted. Do not commit, publish, or edit it.

Apply reruns the platform, ADC, and project guards, verifies every binding and digest, then invokes
`pulumi up --plan ... --yes --non-interactive`. It performs no second preview. This is a
**constrained**, not atomic, apply: Pulumi cannot introduce operations beyond the reviewed plan, but
cloud operations still happen over time and a failure can leave partial progress. Keep the bundle,
inspect the stack, and retry the same command only while its bindings still verify. A changed
payload, program, config, context, backend, stack, Pulumi version, or bundle member makes the plan
stale and refuses before update; create and review a new directory instead. Existing destinations
are never overwritten.

### The project preflight

Both commands run `nagarectl context guard` **before** Pulumi is invoked at all. It refuses
when the selected stack's `gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, or `gcloud`'s
configured project disagrees with the active context's project, and it has no escape hatch —
unlike `nagarectl platform guard`, which checks release compatibility and can be skipped
during an upgrade, there is no situation in which writing to the wrong project is correct.

When it accepts you see one line before Pulumi's output:

```text
context guard: labs confined to project acme-prod (stack labs)
```

When it refuses, the command stops before preview or apply. Every refusal names the selected stack
and resolved backend:

```text
refusing to run: Pulumi stack 'labs' at backend 'file://.../state' targets project 'some-other-project', not the active context's project 'acme-prod'.
fix: re-project the stack config with 'nagarectl context use labs', or select the context that owns 'some-other-project'.
```

**If you see this, do not reach for a way around it — find out which of the two is wrong.**
The stack config is a *derived projection* of the context, never hand-edited, so a stack
naming a foreign project means either the projection is stale or you have the wrong context
selected. Regenerate the projection with `nagarectl context use <name>`, or switch to the
context that owns the project the stack names. If the message instead names the ambient
`CLOUDSDK_CORE_PROJECT` or gcloud's configured project, unset the override or run
`gcloud config set project <project>`; your local `gcloud` pointing somewhere else is fine
as long as nothing exports it into this shell. A `mode=local` context prints
`context guard: local mode; no GCP project to confine` and proceeds.

An unknown stack project does not always mean an absent key. If `pulumi` is missing, the guard says
it was not found and points to `nagarectl version --tools` and the operator package. If Pulumi exits
non-zero, the refusal includes its exit status and stderr; inspect the exact stack/backend
environment with `nagarectl context env` and fix that backend, authentication, or state error. Only
a successful config listing without `gcp:project` recommends `nagarectl context use <name>`. Invalid
JSON or a malformed config entry is reported as invalid output, and every case remains fail-closed.

For automation, `nagarectl context guard --json` writes one failure object to stderr and nothing to
stdout. The object keeps nullable `observations.stackProject`, adds the resolved
`observations.pulumiBackendUrl`, and describes the probe through
`observations.stackProjectProbe.status` plus applicable `project`, `exitCode`, `stderr`, or `error`
details.

See [Target contexts](contexts.md) for the full command reference, and
[GCP prerequisites](gcp-prerequisites.md) for everything else that keeps Nagare inside your
project.

On a clean checkout the first `pulumi up` creates everything **except the VM**,
because `nagareImageSelfLink` isn't set yet. That's expected and correct — the
network, IP, disk, DNS, registry, buckets, and IAM are exactly what the host
image build and the cluster need to exist first. You'll run `pulumi up` again
after [building the image](host-image-and-boot.md) to bring up the VM.

The second apply creates and immediately boots the VM from a secret-free image. That state is
intentional: use `nagarectl host place-age-key --context NAME --key-file PATH` over IAP immediately
afterward, then require `OK host age key` in `nagarectl --context NAME server status` before relying
on Tailscale. The private age identity is never a Pulumi input or state value.

### Review replacements and protected resources

Always read the saved `review.json` before applying. The program deliberately
fails closed around stateful resources:

- the data disk and backup bucket have Pulumi `protect: true`, so a deletion or
  replacement fails until you explicitly run `pulumi state unprotect <URN>`;
- the VM has GCE deletion protection by default, so image or boot-disk-type
  changes that require replacement fail until you set
  `nagare:vmDeletionProtection false` and apply; and
- a later apply reasserts the declared protections. `unprotect` is a temporary
  state operation, not a permanent code change.

The VM-shape fields have different live-update behavior:

| Context key | Live change |
| --- | --- |
| `NAGARE_MACHINE_TYPE` | In-place resize with a brief stop/start. |
| `NAGARE_BOOT_DISK_SIZE_GB` | **Replaces the instance and its boot disk.** Shrinking is unsupported; size it for the VM lifetime. |
| `NAGARE_DATA_DISK_SIZE_GB` | In-place growth only; the mounted filesystem grows online. |
| `NAGARE_BOOT_DISK_TYPE` | **Replaces the instance and its boot disk.** |

Changing the image self-link or zone also replaces the instance. `infra preview` classifies the
single saved Pulumi plan and refuses any such replacement unless the operator records approval
with `--allow-replacement`. Its message names the boot-disk state that would be lost. Since 0.2.1
the guard also refuses replacing the Cloud DNS managed zone (new name servers break
the parent delegation; a `NAGARE_BASE_DOMAIN` change causes it) and any storage
bucket (its objects are deleted), and `nagarectl platform upgrade` classifies its retained plan the
same way. A protected replacement requires `--allow-replacement` at preview and again at apply.
Adding the exact apex record to an existing zone is additive. Enabling or disabling the opt-in CDN
updates only that record's target; the wildcard record remains on `publicIp` and the managed zone is
not replaced. Review the preview for exactly that shape.
This is
separate from deletion protection: the guard stops the apply before it starts,
while deletion protection is the Compute API's last backstop.

For a deliberate VM rebuild, leave the data disk and backup bucket protected.
Disable only VM deletion protection and apply that change **before** changing
the image self-link, boot-disk type, or boot-disk size; then apply the replacement and re-enable
protection:

```bash
pulumi -C infra/pulumi config set nagare:vmDeletionProtection false
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/protection-off"
nagare infra-preview --save-plan "$plan_dir"
nagare infra-up --plan "$plan_dir" --yes

# now run nagare host-image, or change the replacement-causing boot-disk setting
replacement_plan="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/vm-replacement"
nagare infra-preview --save-plan "$replacement_plan" --allow-replacement
nagare infra-up --plan "$replacement_plan" --yes --allow-replacement

pulumi -C infra/pulumi config set nagare:vmDeletionProtection true
restore_plan="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/protection-on"
nagare infra-preview --save-plan "$restore_plan"
nagare infra-up --plan "$restore_plan" --yes
```

Do not use this sequence to force through an unexpected data-disk or
backup-bucket replacement. Stop and reconcile the preview first.

### Deliberate teardown

Complete teardown is separate from apply and never inferred as recovery:

```bash
nagare infra-destroy --yes
```

The command repeats the platform, ADC, and context/project guards immediately before
`pulumi destroy --yes --non-interactive`. It destroys only the selected stack; Pulumi-protected
resources and GCE deletion protection still refuse until deliberately removed. There is no saved
plan-bundle workflow for teardown, and omitting `--yes` refuses before Pulumi.

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

## Replacement ownership boundary

A future replacement transaction may temporarily own a candidate slot and, after promotion, a
stopped former-active slot. Do not delete either through an ad hoc Pulumi edit. Cutover must journal
and observe the direct reserved-address handoff, then reconcile Pulumi to the promoted slot. Finalize
may delete only exact resource IDs recorded with the former-active transaction role; it preserves
the reserved address, DNS zone, ordinary backups, and every unrecorded resource. See the
[replacement drill](../runbooks/replacement-cutover-drill.md) for the readiness gate.
