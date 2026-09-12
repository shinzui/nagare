---
title: "Platform data-disk capacity is forward-only and grows itself"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/111-automate-and-document-growing-the-data-disk.md
  - docs/plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
  - docs/adr/0011-host-activation-is-guarded-and-self-reverting.md
---

# ADR 12 — Platform data-disk capacity is forward-only and grows itself

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 111](../plans/111-automate-and-document-growing-the-data-disk.md) and
[ExecPlan 114](../plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md),
which close [IR-5](../improvement-requests/data-disk-grow-procedure.md).

## Context

A Nagare host keeps everything an operator cannot afford to lose on one Google Persistent Disk,
mounted at `/var/lib/nagare`: app volumes, observability stores, database data, and local backups.
Its size is `nagare:dataDiskSizeGb`. Making the disk bigger does not make the ext4 filesystem on it
bigger. Before this decision nothing grew the filesystem, and nothing documented how.

Evidence gathered while delivering IR-5 shaped the decision:

- A Persistent Disk cannot shrink. A smaller `dataDiskSizeGb` plans a delete-and-recreate of the
  disk. With `protect: true` in the stack **state**, Pulumi refuses (`unable to replace resource ...
  marked for protection`). Before a `pulumi up` has written the flag, the same preview is a plain
  replacement with no error.
- A larger `dataDiskSizeGb` is an in-place update (`~ size: 100 => 110`).
- `bootDiskSizeGb` lives in the instance's create-time `bootDisk.initializeParams`, so changing it
  plans a replacement of the whole instance, not a grow.
- NixOS `fileSystems.<mount>.autoResize` adds `x-systemd.growfs`, but a platform oneshot ordered
  before the mount with default dependencies (`After=basic.target`) closes an ordering cycle
  through `local-fs.target`. systemd resolves it by deleting the grow job, silently. The live host
  logged `Job systemd-growfs@var-lib-nagare.service/start deleted to break ordering cycle`.
- `systemd-growfs@.service` is `RemainAfterExit`, so after its boot-time run `systemctl start` is a
  no-op that exits 0.

## Decision

Data-disk capacity is **forward-only**, and the platform enforces rather than merely documents
that:

1. The data disk is declared `protect: true`, so a shrink fails closed once the stack has been
   applied. Operators are told that protection takes effect only after a `pulumi up`.
2. The `/var/lib/nagare` mount carries `autoResize = true`. The filesystem grows to its device on
   every mount, which covers every boot. On a running host the documented one-command grow is
   `sudo systemctl restart systemd-growfs@var-lib-nagare.service`, never `start`.
3. Any platform unit ordered before a local mount that has `x-systemd.growfs` must set
   `DefaultDependencies = false`. It orders itself explicitly after `local-fs-pre.target` and after
   the device unit it needs, and `conflicts = [ "shutdown.target" ]`. The `data-disk-auto-grow`
   evaluation check asserts this for `format-nagare-data`. The `data-disk-online-grow` VM test
   proves a blank-disk format, a grow on reboot, and a grow on a running machine, with no ordering
   cycle in the journal.
4. The boot disk is not resized in place. `bootDiskSizeGb` is documented as a create-time setting.

## Consequences

Growing storage is one config change, `just infra-up`, and either a reboot or one command. The
procedure is in `docs/user/resizing-the-vm.md#growing-the-data-disk`, and the `DiskUsageHigh` alert
points at it. A grow is permanent and costs money every month, so the alert and docs tell operators
to find the consumer first.

An `nixos/` change that orders something before a local mount must pass the evaluation check and
the VM test. Removing either `autoResize` or the dependency edges fails
`nix build .#checks.x86_64-linux.data-disk-auto-grow`.

Reclaiming space means moving data to a new, smaller disk by hand. That is a deliberate migration,
not a config edit.
