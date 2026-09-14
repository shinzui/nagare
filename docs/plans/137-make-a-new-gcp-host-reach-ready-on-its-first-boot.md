---
id: 137
slug: make-a-new-gcp-host-reach-ready-on-its-first-boot
title: "Make a new GCP host reach Ready on its first boot"
kind: exec-plan
created_at: 2026-09-14T04:16:15Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:15Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:42:49Z
      mode: "implement"
      note: "Implemented EP-4 graph and repeated first-boot test coverage"
---

# Make a new GCP host reach Ready on its first boot

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A brand-new Nagare GCP host with a blank persistent data disk formats and mounts that disk before
systemd-fsck can open it, creates the required data layout, and starts k3s successfully on its first
boot. No reboot or manual unit restart is needed. Evaluation checks lock the systemd ordering, and
a repeated NixOS VM test proves the race is gone and the node becomes Ready. This plan implements
IR-19 and integrates—but does not duplicate—the age-key handoff in independent ExecPlan 133.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T14:42:25Z) Encode format-before-fsck ordering and a recoverable layout/k3s
  dependency chain.
- [x] (2026-09-14T14:42:25Z) Add evaluation assertions and five independent blank-disk first-boot
  VM samples behind one aggregate check.
- [ ] Run the five-sample aggregate and existing online-growth VM checks on an available
  x86_64-linux NixOS-test builder; evaluation passes, but the configured builder is unreachable.
- [ ] Reconcile with ExecPlan 133 and prove the complete new-host service sequence.
- [ ] Update host boot docs, complete IR-19, and run nested plus root flake gates.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: neither the legacy `ssh://builder@nix-gcp-builder` route nor the active context's
  project-confined builder route can currently execute an x86_64-linux check from this workstation.
  Evidence: `nix flake check ./nixos --no-build --all-systems` passed every nested output. The
  legacy build failed to connect, and the guarded `tan-ng-labs/us-west1-a/nix-builder-x86` route
  then refused before starting the VM because gcloud could not refresh credentials non-interactively
  and requested `gcloud auth login`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Order `format-nagare-data.service` before the escaped systemd-fsck unit and the mount,
  while retaining `DefaultDependencies=false`.
  Rationale: The observed race is concurrent access to the same blank block device. Restoring broad
  default dependencies would reintroduce the cycle previously removed; the narrow edge serializes
  only the contending units.
  Date: 2026-09-14.

- Decision: Make layout and k3s recover after a transient mount failure without weakening their
  requirement on the mounted data disk.
  Rationale: k3s must never write state to the boot disk at an unmounted path. Recovery should
  restart the dependent units after a late successful mount, not turn the mount into an optional
  prerequisite.
  Date: 2026-09-14.

- Decision: Parameterize multiple VM derivations for repeated first-boot evidence rather than loop
  over one already-formatted disk.
  Rationale: The race exists only during the initial blank-device dependency graph. Each repetition
  must start from an independent blank disk and boot.
  Date: 2026-09-14.

- Decision: Keep ADR 12's forward-only ext4 growth policy unchanged.
  Rationale: This plan fixes service ordering, not filesystem type, resize behavior, or capacity
  policy. Amend the ADR only if implementation changes that durable rule.
  Date: 2026-09-14.

- Decision: Make `k3s.service` wanted by `var-lib-nagare.mount` while retaining its hard
  `Requires=` and `After=` relationships on both the mount and layout service.
  Rationale: A fresh mount transaction then retries layout and k3s declaratively after a transient
  failure. This avoids a helper that invokes `systemctl` from inside a service and still prevents
  k3s from writing to the boot disk through an unmounted path.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

[IR-19](../improvement-requests/first-boot-data-disk-format-races-fsck.md) contains the observed
journal: `format-nagare-data` and `systemd-fsck@...` started within milliseconds, `mkfs.ext4`
reported `Device or resource busy`, the mount failed, and k3s remained dependency-failed even though
a later mount retry succeeded.

`nixos/hosts/nagare-01/storage.nix` defines the device path
`/dev/disk/by-id/google-nagare-data`, `format-nagare-data.service`, the `/var/lib/nagare` mount, and
`nagare-data-layout.service`. Formatting runs only when `blkid` finds no filesystem. The format unit
has `DefaultDependencies=false`, follows the device and `local-fs-pre.target`, and precedes the
mount, but it does not precede the systemd-fsck instance generated for that mount.

`nixos/hosts/nagare-01/k3s.nix` orders and requires k3s after both
`var-lib-nagare.mount` and `nagare-data-layout.service`. This correctly prevents state from falling
through to the boot disk, but a one-time dependency failure is not automatically retried after the
mount later succeeds. `nixos/flake.nix` has `data-disk-auto-grow` evaluation assertions and a
`data-disk-online-grow` VM test. That test exercises one successful blank format and later growth;
it does not repeatedly exercise the boot race or require Kubernetes node readiness.

Independent [ExecPlan 133](133-deliver-the-host-age-key-after-first-boot.md) changes the same host
boot surface so sops secrets and Tailscale can recover after post-boot age-key delivery. This plan
must preserve its service ordering and run a composed test after both changes. It must not reparent
or change that plan's intention.

[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) governs the generated
host. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) governs activation
safety. [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) requires the ext4 data
disk to grow forward-only and online. No cross-repository dependency or ADR is needed.


## Plan of Work

### Milestone 1: serialize blank-disk consumers

In `nixos/hosts/nagare-01/storage.nix`, compute the fsck unit with
`utils.escapeSystemdPath dataDiskDevice` and add it to `format-nagare-data.before` alongside the
mount. Preserve the current device requirement, local-fs-pre ordering, blank-device check,
idempotent existing-filesystem path, and `DefaultDependencies=false`. Do not add an fsck bypass or
format a nonblank device.

Review the generated unit graph with `systemd-analyze verify` in the VM. Make
`nagare-data-layout.service` restartable after a transient dependency failure and ensure k3s is
started or restarted only after the mount and layout are active. A small path-triggered recovery
unit may start the layout and k3s after `var-lib-nagare.mount` becomes active; alternatively encode
`Restart=on-failure` where systemd applies it reliably to the oneshot. The accepted design must keep
hard `Requires`/`RequiresMountsFor` protection so k3s cannot use an unmounted directory.

### Milestone 2: lock the graph and reproduce first boot repeatedly

Extend `data-disk-auto-grow` in `nixos/flake.nix` to assert the exact escaped fsck unit appears in
the format unit's `before`, the mount remains ordered after formatting, and k3s still requires the
mount/layout. Add `nixos/tests/data-disk-first-boot.nix` as a parameterized
`pkgs.testers.runNixOSTest`. Each test instance starts with a separate blank disk, boots once, waits
for the mount and k3s, and runs `kubectl get nodes` until the only node is Ready. Assert filesystem
type ext4, expected mount source, required directories on that mount, no `Device or resource busy`
or failed format/fsck unit in the journal, and no reboot.

Instantiate at least five uniquely named test derivations in `nixos/flake.nix` so Nix cannot reuse
one execution as five samples. Add one aggregate check that depends on them. Also preserve the
existing online-growth test and its data canary.

### Milestone 3: integrate the complete host sequence

After ExecPlan 133 is implemented, run its age-key delivery VM check alongside the new storage
checks and add one composed assertion if service overrides would otherwise hide an ordering issue.
The composed lifecycle is: blank disk formats and mounts, layout becomes ready, k3s reaches active,
the missing age key is reported without interactive Tailscale login, the key is delivered, secrets
activate, and Tailscale can start. Storage readiness must not depend on the secret handoff.

### Milestone 4: publish and close

Update `docs/user/host-image-and-boot.md`, `docs/user/provisioning-with-pulumi.md`, and the focused
onboarding section to state that the first boot formats the data disk and reaches k3s Ready without
a reboot, while Tailscale readiness follows the age-key handoff. Update `CHANGELOG.md`, complete
IR-19 with observed evidence, append the bundle log, and run nested and root flake gates. Revisit
ADRs 11 and 12 only if the final unit design changes their durable claims.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`.

```bash
nix flake check ./nixos --no-build --all-systems
nix build ./nixos#checks.x86_64-linux.data-disk-first-boot --print-build-logs
nix build ./nixos#checks.x86_64-linux.data-disk-online-grow --print-build-logs
```

If the aggregate check uses a different generated attribute, list it with
`nix flake show ./nixos` and record the exact name here. The VM log must show one boot, an active
mount and k3s, and a Ready node; it must not contain `Device or resource busy`.

```bash
nix build ./nixos#checks.x86_64-linux.host-age-key-delivery --print-build-logs
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
nix flake check --print-build-logs
```


## Validation and Acceptance

Evaluation must show `format-nagare-data.service` before both the escaped fsck unit and
`var-lib-nagare.mount`, with k3s still requiring the mount and layout. Each of at least five
independent blank-disk VMs must boot once, create ext4 on the intended device, mount it at
`/var/lib/nagare`, create the layout on that filesystem, start k3s, and report exactly one Ready
node. Journals must contain neither the original busy error nor a failed format/fsck/mount/layout/k3s
unit. The existing growth test must retain its canary across resize.

The composed ExecPlan 133 test must prove that storage and k3s do not wait for a not-yet-delivered
age key, while secret/Tailscale recovery succeeds after delivery. On the next authorized fresh GCP
host, `kubectl get nodes` must reach Ready during the first boot ID with no operator reboot.


## Idempotence and Recovery

Formatting remains guarded by `blkid`: after a filesystem exists, rerunning the service is a no-op.
Mount, layout, and k3s starts are convergent. Never retry formatting by forcing `mkfs`; inspect
`lsblk`, `blkid`, unit status, and the journal first. If a transient mount failure occurs despite the
ordering, starting the mount should trigger the bounded recovery path for layout/k3s without a
reboot. If the device contains an unexpected filesystem or data, stop and recover manually rather
than changing the blank-disk predicate.


## Interfaces and Dependencies

The primary interface is the NixOS systemd graph in `nixos/hosts/nagare-01/storage.nix` and
`nixos/hosts/nagare-01/k3s.nix`:

```text
format-nagare-data.service
  Before=systemd-fsck@<escaped-device>.service var-lib-nagare.mount
var-lib-nagare.mount
  before/requires nagare-data-layout.service and k3s.service
```

Use NixOS `utils.escapeSystemdPath`, systemd unit relationships, e2fsprogs, k3s, and the existing
NixOS test framework. Do not add another filesystem or external service. ExecPlan 133 is an external
integration dependency; EP-6 consumes the Ready-node behavior.


Revision note (2026-09-14): Added the format-before-fsck edge, declarative mount-triggered k3s
recovery, exact graph assertions, and a five-sample first-boot VM aggregate. Nested flake evaluation
passes; executing the Linux VM checks awaits an available x86_64-linux builder.
