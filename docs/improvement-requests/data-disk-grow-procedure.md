---
type: Improvement Request
title: Document and automate growing the data disk
description: Make the data-disk grow a real, tested procedure instead of a one-sentence reference that an operational alert already links to.
timestamp: "2026-09-12T21:27:16Z"
generated:
  by: process:claude-code
  at: "2026-09-12T21:27:16Z"
requestId: IR-5
status: completed
completedAt: "2026-09-12T21:27:16Z"
resolution: "EP-111 added autoResize (x-systemd.growfs) to /var/lib/nagare; EP-114 fixed the ordering cycle that silently dropped the grow (format-nagare-data without default dependencies, ordered after its device) and proved it with the data-disk-online-grow VM test (blank-disk format, grow on reboot, grow online; no ordering cycle) plus the data-disk-auto-grow evaluation check. Recorded previews show a dataDiskSizeGb increase is an in-place update and a decrease fails closed once protect is in state; a bootDiskSizeGb change forces instance replacement. Live on nagare-01 on 2026-09-12 the disk grew 100 to 110 GiB and df went 98G to 108G via systemctl restart systemd-growfs@var-lib-nagare.service, node Ready. docs/user/resizing-the-vm.md#growing-the-data-disk documents the procedure and the DiskUsageHigh alert now points at it."
targetPlan: docs/plans/111-automate-and-document-growing-the-data-disk.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-12T21:27:16Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against ExecPlans 111 and 114, their recorded VM,
      preview, and live-host evidence, and the current growfs, test, runbook,
      alert, and ADR surfaces; the completed status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: document and automate growing the data disk

**Authored by:** a pre-flight review of `v0.1.0` (HEAD `da24748`) performed while planning the
validation sweep for a new cluster.
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by [ExecPlan 111](../plans/111-automate-and-document-growing-the-data-disk.md), with the fix and live grow finished under [ExecPlan 114](../plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md).
**Created:** 2026-09-12.


## Why

The data disk is where everything an operator cannot afford to lose ends up: application persistent
volumes through the local-path provisioner, the VictoriaMetrics, VictoriaLogs and VictoriaTraces
stores, Postgres and SQLite data, and local backups. When it fills, the cluster degrades in ways
that are unpleasant to debug under pressure.

Nagare already anticipates this: an alert fires on disk pressure, and its remediation text points
the operator at the procedure for growing `/var/lib/nagare`. That procedure does not exist. The
documentation devotes one sentence to it, names no commands, and the repository contains no code
that grows the filesystem. So the one moment the operator most needs a reliable answer — a full disk
on a running cluster — is the moment they discover they have to improvise on a live box.

The asymmetry with the boot disk makes the gap easy to miss. The boot disk grows transparently,
because the NixOS image auto-grows the root partition to fill whatever size is provisioned
(`infra/pulumi/src/components/NagareInstance.ts:55-56`, echoed in
`docs/runbooks/disaster-recovery.md:94`). An operator who has grown a boot disk without incident
will reasonably assume the data disk behaves the same way. It does not.


## What is missing

`nixos/hosts/nagare-01/storage.nix:17-48` formats the data disk with `mkfs.ext4` only when it is
blank, then mounts it at `/var/lib/nagare` with `options = [ "defaults" "nofail" ]`. There is no
`resize2fs`, no `growfs`, and no auto-grow anywhere in `nixos/`, `scripts/` or `infra/` — so after
an operator increases `nagare:dataDiskSizeGb` (`infra/pulumi/index.ts:20`,
`src/components/NagarePerimeter.ts:72`) the underlying disk is larger while the filesystem on it is
unchanged, and the free space is invisible until someone resizes it by hand.

The entirety of the documentation is `docs/user/resizing-the-vm.md:173-174`:

> **Resizing the disks.** Growing `/var/lib/nagare` is a `dataDiskSizeGb` change plus an online
> filesystem grow — a separate operation from the machine type.

No command, no verification step, no note that the grow is online and safe, no statement of what
happens if it is skipped. Meanwhile the disk-pressure alert links to this section as remediation,
which makes the gap operationally live rather than merely untidy.

Two adjacent facts are worth recording in the same change. Shrinking is impossible: a size decrease
forces disk replacement, which the disk's `protect: true` (`NagarePerimeter.ts:73`) turns into a
failed plan — correct fail-closed behavior that should be documented rather than discovered.
And the boot disk's in-place grow behavior under the pinned provider is asserted by documentation
(`docs/user/reference.md:204`: "Increasing is supported; shrinking is not") but is not demonstrated
by any test, so it deserves the same verification.


## Requested change

- Automate the online grow in the NixOS module: after mounting `/var/lib/nagare`, grow the
  filesystem to fill the device if it is smaller. ext4 supports this online, so a host rebuild or
  reboot would absorb a disk increase with no operator action.
- If automation is rejected, document the exact procedure in `docs/user/resizing-the-vm.md`: the
  `dataDiskSizeGb` change, the preview expectation (an in-place disk update, not a replacement), the
  device path, the `resize2fs` invocation, and a `df -h` verification with expected output.
- Either way, state plainly that shrinking is impossible and that `protect: true` will fail such a
  plan.
- Make the disk-pressure alert's remediation link point at a procedure that exists, and say whether
  growing or pruning is the recommended first response.
- Give the boot disk the same treatment: confirm whether increasing `bootDiskSizeGb` is an in-place
  disk update or forces instance replacement under the pinned `@pulumi/gcp`, and document the
  answer rather than asserting it.


## Required verification

- A test or rehearsal proving that increasing `dataDiskSizeGb` produces an in-place disk update in
  the plan, never a replacement.
- Evidence from a live or local run that the filesystem reflects the new size afterwards — `df -h`
  before and after — whether by automation or by the documented manual step.
- A test proving that a decrease fails closed rather than destroying the disk.
- Equivalent evidence for the boot disk, or an explicit statement in the documentation that the
  behavior is unverified.


## Acceptance

An operator who receives the disk-pressure alert can follow its link to a procedure with real
commands, grow the data disk without downtime or improvisation, and verify the result — or finds
that the grow already happened by itself. Nothing in the storage documentation asserts behavior that
no test or recorded run supports.


## Non-goals

This request does not ask for multiple data disks, dynamic volume expansion for individual
application PVCs, a different storage class or provisioner, or moving k3s state onto the data disk.
It does not cover the VM machine-type resize, which has its own runbook, though that runbook's
unexercised status is worth resolving alongside this one.
