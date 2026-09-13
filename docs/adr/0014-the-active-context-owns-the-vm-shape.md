---
title: "The active context owns the VM shape"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md
  - docs/improvement-requests/seed-vm-shape-keys-at-init.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
---

# ADR 14 — The active context owns the VM shape

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 110](../plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md),
which closes
[IR-4](../improvement-requests/seed-vm-shape-keys-at-init.md).

## Context

Nagare's Pulumi program creates one Google Compute Engine instance whose boot
disk holds the k3s datastore under `/var/lib/rancher`. The separately protected
data disk at `/var/lib/nagare` survives an instance replacement, but the boot
disk does not. Replacing the instance therefore loses the Kubernetes objects,
issued TLS certificates, and ACME account key that exist only in the cluster
datastore.

The machine type, boot-disk type, boot-disk size, and data-disk size previously
came from fallback literals in `infra/pulumi/index.ts`. `nagarectl init` did not
record those values in the target context or Pulumi stack configuration. A
later source release could therefore change a fallback and make an ordinary,
unrelated apply plan an instance replacement against a live stack.

Machine-type changes and disk growth are normal day-two operations. A
boot-disk-type change, image change, or zone change is fundamentally different
because it replaces the instance. GCE deletion protection is a useful last
backstop, but it fails only after an apply has begun and does not explain the
cluster state at risk.

## Decision

The active target context owns the VM shape. Every context resolves and renders
`NAGARE_MACHINE_TYPE`, `NAGARE_BOOT_DISK_TYPE`,
`NAGARE_BOOT_DISK_SIZE_GB`, and `NAGARE_DATA_DISK_SIZE_GB`.
`nagarectl init` and `nagarectl context create` validate those values, and init,
context selection, and `context create --use` project them into the matching
Pulumi stack as `nagare:machineType`, `nagare:bootDiskType`,
`nagare:bootDiskSizeGb`, and `nagare:dataDiskSizeGb`.

The Pulumi program retains fallback literals only for stacks that predate
shape seeding. A dependency-free resolver and a cross-language agreement check
prove that recorded stack values win and that the Haskell seeding defaults do
not drift from the TypeScript fallbacks.

Every ordinary infrastructure apply previews first and refuses when Pulumi
would replace the GCE instance. The classifier fails closed on malformed JSON,
an unknown operation, or a failed preview. A deliberate rebuild is possible
only for that invocation with `NAGARE_ALLOW_VM_REPLACEMENT=1` or
`nagarectl infra guard --allow-replacement`, after the operator has reviewed the
disaster-recovery procedure. GCE deletion protection remains enabled by
default as an independent backstop.

## Consequences

A new stack is fully explicit about the compute and disk shape it chose. An
existing context acquires the same pins the next time it is selected, and the
seeded defaults match the historical Pulumi literals so that migration is a
no-op for an uncustomized stack.

Changing a program fallback cannot silently resize or replace a seeded stack.
Operators can resize the machine in place or grow disks while retaining the
same instance and data, but an instance-replacing change stops before apply and
prints the boot-disk recovery cost and deliberate override.

The guard adds a Pulumi preview before every `infra-up`, so ordinary applies
take longer. This cost is accepted because a replacement can destroy cluster
state that the protected data disk and backup bucket do not contain. The
operation-token and GCE-resource-type contracts are pinned by fixtures and must
be updated if Pulumi changes its preview schema or the infrastructure stops
using `gcp.compute.Instance`.

## Amendment — 2026-09-13: the guard protects the DNS zone and buckets

The replacement guard now classifies a list of protected resource types:
`gcp:compute/instance:Instance`, `gcp:dns/managedZone:ManagedZone`, and
`gcp:storage/bucket:Bucket`. A managed zone's `dnsName` is create-only, so a base-domain
change replaces the zone. Cloud DNS then assigns new name servers and the parent delegation
breaks. A bucket replacement deletes the bucket's objects. `NAGARE_ALLOW_VM_REPLACEMENT=1`
remains the single per-run override.

The trigger was found in 0.2.0: `nagarectl context create --force` reset every omitted field to
its default, and the documentation recommended a partial forced create. That command now merges
the passed flags onto the stored context and keeps its platform pin.
`nagarectl platform upgrade` runs this guard too (ADR 18). Implemented by
[ExecPlan 121](../plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md).
