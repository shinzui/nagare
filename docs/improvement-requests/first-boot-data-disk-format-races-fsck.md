---
type: Improvement Request
title: Stop the first-boot data-disk format from racing systemd-fsck and leaving k3s failed
description: On a fresh v0.2.2 host, format-nagare-data's mkfs hit "Device or resource busy" because systemd-fsck opened the same device, so the first mount failed and k3s stayed dead even though a retry one second later formatted and mounted the disk.
timestamp: "2026-09-14T15:22:49Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-19
status: completed
acceptedAt: "2026-09-14T04:26:09Z"
completedAt: "2026-09-14T15:22:49Z"
resolution: "ExecPlan 137 orders format-nagare-data before the escaped systemd-fsck instance and the mount while retaining DefaultDependencies=false. The mount now wants k3s, whose hard mount and layout requirements remain, so a recovered mount retries the chain without a reboot. Exact evaluation assertions pass; five independent blank-disk NixOS VMs each reached exactly one Ready node in the original boot, rejected Device or resource busy and relevant failed units, and recovered layout/k3s from a mount-only restart without changing boot ID. The existing online-growth VM regression also passes."
targetPlan: docs/plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-14T14:45:36Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against ExecPlan 137, the current storage and first-boot
      test surfaces, and MasterPlan 22's In Progress registry state; implementation
      has started but no completion evidence exists, so in-progress and Nagare fit are accurate.
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T15:22:49Z"
    document_timestamp: "2026-09-14T15:22:49Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Reviewed the implemented systemd graph, exact evaluation assertions, five independent
      blank-disk VM results, same-boot mount recovery, online-growth regression, and updated
      operator documentation; the request's Ready-without-reboot acceptance is satisfied.
verified:
  by: process:openai-codex
  at: "2026-09-14T15:22:49Z"
---

# Improvement Request: make the first-boot data-disk format reliable

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by
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


## Resolution

`format-nagare-data.service` now runs before the generated fsck instance and the mount, without
restoring the default dependencies that previously caused the growfs ordering cycle. The mount
wants k3s while k3s retains hard requirements on the mount and layout, so a successful mount retry
reconstructs the dependent transaction safely.

The `data-disk-auto-grow` evaluation check locks the exact edges. The
`data-disk-first-boot` aggregate ran five independent blank-disk VMs; every sample formatted ext4,
mounted the intended device, created the layout, reached exactly one `Ready` node without a reboot,
rejected the original busy error and relevant failed units, and recovered layout plus k3s after a
mount-only restart under the same boot ID. The existing `data-disk-online-grow` VM regression also
passes, preserving ADR 12's forward-only growth behavior.
