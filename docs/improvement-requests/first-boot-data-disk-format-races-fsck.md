---
type: Improvement Request
title: Stop the first-boot data-disk format from racing systemd-fsck and leaving k3s failed
description: On a fresh v0.2.2 host, format-nagare-data's mkfs hit "Device or resource busy" because systemd-fsck opened the same device, so the first mount failed and k3s stayed dead even though a retry one second later formatted and mounted the disk.
timestamp: "2026-09-14T04:26:09Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-19
status: accepted
acceptedAt: "2026-09-14T04:26:09Z"
targetPlan: docs/plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md
origin: mori://shinzui/nagare
---

# Improvement Request: make the first-boot data-disk format reliable

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted for implementation by
[ExecPlan 137](../plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md).
**Created:** 2026-09-14.


## Why

The first boot of the brand-new `labs` host (image `nagare-image-f9p6raz75qjf`, `v0.2.2`) left k3s
dead. The previous-boot journal shows the cause:

```text
02:30:56.506019 systemd[1]: Starting Format the Nagare data disk on first boot if it is blank...
02:30:56.536056 systemd[1]: Starting File System Check on /dev/disk/by-id/google-nagare-data...
02:30:56.546424 format-nagare-data-start[513]: no filesystem on /dev/disk/by-id/google-nagare-data; creating ext4
02:30:56.574006 format-nagare-data-start[516]: /dev/disk/by-id/google-nagare-data: Device or resource busy while setting up superblock
02:30:56.577076 systemd[1]: Failed to start Format the Nagare data disk on first boot if it is blank.
02:30:56.670805 systemd[1]: Failed to mount /var/lib/nagare.
02:30:56     systemd[1]: Dependency failed for k3s service.
02:30:56     systemd[1]: Dependency failed for Create the /var/lib/nagare subdirectory layout (IP-3).
02:30:57.888953 systemd[1]: Finished Format the Nagare data disk on first boot if it is blank.
02:30:57.929361 systemd[1]: Mounted /var/lib/nagare.
```

`systemd-fsck@dev-disk-by\x2did-google\x2dnagare\x2ddata.service` opened the device 30 ms after
`format-nagare-data` started, and `mkfs.ext4` failed. Something re-triggered the mount a second later,
the format succeeded and the disk mounted, but `k3s.service` and `nagare-data-layout.service` had
already failed their dependency and nothing restarts them. The node only came up after a reboot.

`nixos/hosts/nagare-01/storage.nix` at `v0.2.2` orders `format-nagare-data` after
`local-fs-pre.target` and the device unit, and before `var-lib-nagare.mount`, but not before the fsck
unit that the mount pulls in. EP-114 removed default dependencies to break an ordering cycle, which
also removed the implicit ordering that previously kept these apart. The `data-disk-online-grow` VM
test formats a blank disk successfully, so the race does not reproduce there reliably.


## Requested change

- Order `format-nagare-data` before
  `systemd-fsck@${utils.escapeSystemdPath dataDiskDevice}.service` as well as the mount, keeping
  default dependencies off so the EP-114 cycle stays broken.
- Consider making the k3s dependency tolerate a late mount, for example ordering k3s after
  `var-lib-nagare.mount` with `Requires` plus a `Restart=on-failure` on the layout unit, so a
  transient first-boot failure does not require a reboot.
- Add an evaluation check that the format unit is ordered before the fsck unit.


## Required verification

- The evaluation check above.
- A first-boot VM test run repeated enough times to show the blank-disk path never reports
  `Device or resource busy` and k3s reaches active on the first boot.


## Acceptance

A newly created cloud host with a blank data disk reaches `kubectl get nodes` `Ready` on its first
boot, with no reboot.


## Non-goals

Changing the filesystem type, the growfs behaviour, or the forward-only disk-capacity decision (ADR 12).
