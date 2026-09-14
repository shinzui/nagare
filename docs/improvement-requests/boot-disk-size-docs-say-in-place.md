---
type: Improvement Request
title: Correct the docs that call a boot-disk size change in-place growth
description: provisioning-with-pulumi.md and reference.md still say NAGARE_BOOT_DISK_SIZE_GB grows in place, but a recorded preview shows the change replaces the instance and its k3s state.
timestamp: "2026-09-14T04:26:09Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-11
status: accepted
acceptedAt: "2026-09-14T04:26:09Z"
targetPlan: docs/plans/139-prove-and-document-one-pass-gcp-cluster-onboarding.md
origin: mori://shinzui/nagare
---

# Improvement Request: correct the boot-disk size documentation

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted for implementation by
[ExecPlan 139](../plans/139-prove-and-document-one-pass-gcp-cluster-onboarding.md).
**Created:** 2026-09-13.


## Why

Operators size the boot disk at `nagarectl init` based on these tables. Believing growth is in place,
they will start small and plan to grow later; in fact growing later replaces the VM, which destroys
k3s state, Knative and cert-manager objects, issued certificates and the ACME account key. The
instance replacement guard (IR-4) refuses such an apply, so the error is not silently destructive,
but the documented expectation is wrong at exactly the moment it matters. The `tan-ng-labs` rollout
chose a 200 GB boot disk up front for this reason.


## What is missing

At `v0.2.1`:

- `docs/user/provisioning-with-pulumi.md:193`: `` `NAGARE_BOOT_DISK_SIZE_GB` | In-place growth; grow
  the root filesystem separately. Shrinking is impossible. ``
- `docs/user/reference.md:215`: `` `nagare:bootDiskSizeGb` | … | Boot-disk size in GiB. Growth is in
  place; filesystem growth is separate. Shrinking is impossible. ``

The evidence is nagare's own
[ExecPlan 111](../plans/111-automate-and-document-growing-the-data-disk.md), Progress line 108: a
preview of `bootDiskSizeGb` 100 → 110 showed `~ initializeParams: { ~ size : 100 => 110 }` inside an
instance `+- (replace)`, because the size is create-time only. That plan's line 128 records correcting
the boot-disk claim, but both rows above still say in-place at the tag. The `nagarectl init --help`
text for `--boot-disk-size-gb` gives no warning either, while `--boot-disk-type` does.


## Requested change

- Change both rows to say a boot-disk size change replaces the instance, with a pointer to the
  replacement guard and to the deliberate-rebuild procedure.
- Add "changing a live VM replaces it" to `nagarectl init --boot-disk-size-gb`'s help, matching
  `--boot-disk-type`.
- Recommend sizing the boot disk for the VM's lifetime in `docs/user/gcp-prerequisites.md`.


## Required verification

- The existing VM-shape default-agreement check, or a docs check, fails if either table describes
  boot-disk size as in-place again.


## Acceptance

No user-facing document or help text describes a boot-disk size change as in-place.


## Non-goals

Making boot-disk growth genuinely in place (for example with `ignore_changes` plus an out-of-band
`gcloud compute disks resize`); that would be a separate request.
