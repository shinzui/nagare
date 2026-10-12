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
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T18:55:58Z
      mode: "implement"
      note: "Completed EP-4 composition with the post-boot age-key handoff"
---

# Make a new GCP host reach Ready on its first boot

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] (2026-09-14T15:22:44Z) Run the five-sample aggregate and existing online-growth VM checks on
  an x86_64-linux NixOS-test builder.
- [x] (2026-09-14T18:55:31Z) Reconcile with ExecPlan 133 and prove the complete new-host service
  sequence in one VM boot: blank-disk mount and a Ready k3s node precede age-key delivery, then
  sops activation and Tailscale autoconnect recover without changing boot ID.
- [x] (2026-09-14T18:59:20Z) Pass nested Nix evaluation, documentation profiles, strict
  improvement-request validation, all 527 Haskell tests, and all 29 buildable native flake checks.
- [x] (2026-09-14T15:22:49Z) Update the storage/Ready portions of the host boot docs, complete
  IR-19, and run nested plus root flake gates. Keep the age-key instructions unchanged until
  ExecPlan 133 supplies its post-boot handoff.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: the initial builder block was transient, but the active `labs` context and the
  workstation's legacy Nix builder are different resources.
  Evidence: after interactive gcloud login, `scripts/upload-images.sh --dry-run` correctly selected
  `tan-ng-labs/us-west1-a/nix-builder-x86`, which does not exist. The existing
  `tan-nb-exp/us-west1-a/nix-builder-x86` daemon route ran the NixOS tests. Its idle shutdown
  interrupted the first online-growth attempt; restarting that instance and retrying produced a
  passing test rather than an assertion failure.

- Observation: `systemd-analyze verify` needs the generated unit fragment paths in a NixOS VM, not
  the four bare unit names.
  Evidence: the first aggregate attempt reached a Ready node and then reported
  `Unit var-lib-nagare.mount not found` from the verifier. Resolving every `FragmentPath` through
  `systemctl show` made the verifier pass in all five samples.

- Observation: importing the complete host module into a NixOS VM is not enough to exercise its
  data filesystem because `qemu-vm.nix` replaces `fileSystems` with `virtualisation.fileSystems`.
  Evidence: the composed check restored the evaluated shipped `/var/lib/nagare` definition and
  attached a blank `/dev/vdb`; the resulting VM formatted ext4, reached one Ready k3s node before
  age-key delivery, and completed Tailscale recovery under the same boot ID in 73.32 seconds.

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

- Decision: strengthen ExecPlan 133's existing `host-age-key-delivery` VM check into the composed
  host lifecycle proof instead of adding a second overlapping test.
  Rationale: that check already imports the shipped Nagare host module and owns the missing-key to
  Tailscale-ready transition. Restoring the shipped data filesystem and asserting k3s readiness
  before delivery proves the integration boundary without duplicating either subsystem's fixture.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

EP-4 is complete. The formatter is serialized ahead of the exact fsck
instance and the mount, while the mount can reconstruct the hard layout/k3s dependency chain after
a transient failure. Exact evaluation checks pass. Five independent blank-disk VM derivations each
created ext4 on the intended device, created the layout on that mount, reached exactly one Ready
node, rejected the original busy error and relevant failed units, and recovered from a mount-only
restart without changing boot ID. The existing online-growth regression and the nested/root flake
gates pass, and IR-19 is completed.

Independent [ExecPlan 133](133-deliver-the-host-age-key-after-first-boot.md) is also complete. Its
`host-age-key-delivery` VM check now carries the composed proof: a fresh blank disk formats and
mounts, the layout and one k3s node become Ready while the age key remains missing, delivery
activates sops and Tailscale, and the boot ID does not change. The composed run passed in 73.32
seconds. ADR 12 remains unchanged because filesystem type, growth, and forward-only capacity policy
did not change; the test composition adds evidence rather than a new durable architecture rule. The
closing pass also completed nested Nix evaluation, documentation profiles, strict improvement-
request validation, all 527 Haskell tests, and all 29 buildable native flake checks.

