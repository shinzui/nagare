---
type: Improvement Request
title: Seed and pin the VM shape keys at init so a routine apply cannot replace the instance
description: Have nagarectl init seed machineType and bootDiskType, and warn before any plan that would destroy the boot disk holding k3s state and TLS material.
timestamp: "2026-09-12T13:08:46Z"
generated:
  by: process:claude-code
  at: "2026-09-12T13:08:46Z"
requestId: IR-4
status: accepted
targetPlan: docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md
origin: mori://shinzui/nagare
---

# Improvement Request: seed and pin the VM shape keys at init

**Authored by:** a pre-flight review of `v0.1.0` (HEAD `da24748`) performed while sizing a new
cluster intended to validate the platform before it carries real work.
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted; planned as [ExecPlan 110](../plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md).
**Created:** 2026-09-12.


## Why

`nagarectl init` seeds eight Pulumi keys and makes the context the source of truth for everything
else, which sets a reasonable expectation: a stack created by `init` is fully described by what
`init` wrote. Two keys that materially change the VM are not among them, so a fresh stack silently
adopts whatever the program's defaults happen to be at the moment of first apply, and records
nothing about that choice.

For `machineType` the cost is mild — the default may simply be the wrong size. For `bootDiskType`
the cost is severe and asymmetric, because the boot disk is where the cluster actually lives. GCE
cannot convert a boot disk's type in place, so if the default changes under an unpinned stack, the
*next ordinary* `infra-up` — run for an unrelated reason — plans a full instance replacement. The
code says so itself, at `infra/pulumi/index.ts:48-51`:

> GCE cannot convert a boot disk's type in place, so changing `bootDiskType` against a live VM
> forces an INSTANCE REPLACEMENT. A stack whose VM is already running on another type should pin it.

A replacement discards the boot disk, and `docs/user/resizing-the-vm.md:42` records what that means:
k3s cluster state lives at `/var/lib/rancher` on the boot disk, not on the protected data disk. So a
replacement destroys the etcd/sqlite datastore, every Knative and cert-manager object, every issued
TLS certificate, and the ACME account key — recoverable only by re-bootstrapping and re-issuing.
`vmDeletionProtection` defaulting true (`index.ts:44`) turns that into a failed apply rather than a
silent loss, which is the correct backstop, but it leaves the operator with a stack that cannot be
applied until they understand why.

Placing the decision at `init`, where the operator is already choosing the project, region and
domain, costs nothing and removes the trap permanently. It also makes "start small, validate, then
size up" a supported flow rather than an undocumented one: the sizing decision becomes visible in
the context the operator already reads.


## What is missing

`cli/nagarectl/src/Nagare/Init.hs:146-156` seeds exactly `gcp:project`, `gcp:region`, `gcp:zone`,
`nagare:baseDomain`, `nagare:imageBucket`, `nagare:backupBucket`, `nagare:artifactRegistryId` and
`nagare:instanceName`. There is no `machineType`, no `bootDiskType`, no `bootDiskSizeGb` and no
`dataDiskSizeGb`, no corresponding `nagarectl init` flags, and no context fields.

The values therefore come from program defaults read at apply time: `machineType` defaults to
`e2-standard-2` (`infra/pulumi/index.ts:19`), `bootDiskType` to `pd-balanced` (`index.ts:53`), both
disk sizes to 100 GB (`index.ts:20,52`).

The default size is also known to be tight rather than comfortable. An earlier plan records that on
`e2-standard-2` the observability stack's CPU *requests* alone left nothing schedulable — the
scheduler reporting `0/1 nodes are available: Insufficient cpu` — and the remedy was trimming
requests to leave roughly 600m free, with bumping the VM to four vCPU recorded as the standing
alternative. An operator who intends to run the observability stack plus applications plus a
database on the default shape is starting below the waterline and has nothing in the onboarding flow
telling them so.


## Requested change

- Seed `nagare:machineType` and `nagare:bootDiskType` in `nagarectl init`, with flags and
  interactive prompts alongside the existing project/region/zone/base-domain questions, so that
  every stack records its VM shape explicitly from creation.
- Seed `nagare:bootDiskSizeGb` and `nagare:dataDiskSizeGb` at the same time, for the same reason.
- Document in the onboarding runbook which of these can be changed later in place (machine type,
  disk growth) and which force replacement (boot disk type, image, zone), with a pointer to
  `docs/user/resizing-the-vm.md`.
- Add a guard — in `nagarectl doctor`, or as a preflight on `infra-up` — that inspects the pending
  plan and refuses, or requires explicit confirmation, when it would replace the instance. The
  message should name what is lost: k3s state, Knative and cert-manager objects, issued certificates
  and the ACME account key.
- State a recommended minimum shape in `docs/user/gcp-prerequisites.md` for a cluster that will run
  the observability stack, informed by the scheduling evidence above.


## Required verification

- A test proving a stack created by `nagarectl init` carries all four shape keys in its stack
  configuration.
- A fixture proving that a change to a program default does not alter the plan for a seeded stack —
  the property that makes pinning worthwhile.
- A test proving the replacement guard fires on a plan that replaces the instance and stays silent
  on an in-place machine-type update.


## Acceptance

An operator can create a context, see the VM shape in its stack configuration, resize the machine
later by changing one key, and never encounter an unexpected replacement plan produced by a default
they did not choose. When a replacement genuinely is intended, the operator is told exactly what
will be destroyed before it happens.


## Non-goals

This request does not ask for autoscaling, multi-node clusters, moving k3s state onto the data disk
(worthwhile, but a much larger change), or a different default machine type by itself. It does not
cover the data-disk filesystem grow, which is IR-5.


## Planning outcome (2026-09-12)

Accepted. Every claim above was checked against the working tree at `da24748` and holds: the
eight seeded keys at `cli/nagarectl/src/Nagare/Init.hs:146-156`, the four program defaults at
`infra/pulumi/index.ts:19,20,52,53`, the boot-disk replacement caution at
`infra/pulumi/index.ts:48-51`, the deletion-protection backstop at `infra/pulumi/index.ts:44`,
the k3s-on-the-boot-disk record at `docs/user/resizing-the-vm.md:42`, and the
`Insufficient cpu` scheduling evidence with its ~600m remedy in
`docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`.

The work is planned as
[ExecPlan 110](../plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md),
which covers every requested change and every required verification. Three scoping decisions
were made while planning and are recorded in that plan's Decision Log:

The guard is a blocking preflight (`nagarectl infra guard`) wired into the `infra-up` recipe
rather than a `nagarectl doctor` check, because a routine `infra-up` is the path this request is
about and an advisory check only helps an operator who thinks to run it.

The required fixture proving that a change to a program default does not alter the plan for a
seeded stack is realized as a unit test over an extracted pure `resolveVmShape` resolver, not as
a live `pulumi preview` diff: this repository's CI is `nix flake check`, which is sandboxed and
has no Google Cloud credentials, so a cloud-level plan diff cannot run there. A companion check
fails the build if the CLI's seeded defaults and the Pulumi program's fallbacks ever diverge.

Planning also found that `nagarectl context use` re-seeds the Pulumi stack config for a cloud
context, so extending the seed list pins the four keys on an already-created stack at the next
context selection; no separate migration is needed, provided the seeded defaults stay equal to
the literals the program uses today.
