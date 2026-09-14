---
title: "Replacement cutovers reserve rollback before write admission"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
  - docs/adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md
---

# ADR 19 — Replacement cutovers reserve rollback before write admission

## Status

Accepted, 2026-09-13. The provider-independent transaction, deadline, cutover, rollback,
reconciliation, and cleanup contracts are implemented by
[ExecPlan 127](../plans/127-execute-deadline-bound-cutover-rollback-cleanup-and-operator-drills.md).
The GCE, Kubernetes, rehearsal, and state-transfer adapters remain gated on that MasterPlan's
earlier child plans and their live evidence.

## Context

A replacement upgrade temporarily has two independent hosts and two independent copies of
application state. Nagare moves the existing reserved public address between them without a load
balancer or DNS change. The old copy is authoritative until the candidate is both publicly verified
and allowed to accept writes. After candidate write admission, moving traffic back can discard
writes that exist only on the candidate.

A wall-clock deadline is unsuitable for deciding whether another forward step is safe because the
system clock can jump. A total downtime budget is also not useful if forward work is allowed to
consume the time needed to restore the old service.

## Decision

The first successful denial of a production write starts a monotonic downtime deadline. The budget
is divided into a forward-work window, an explicit rollback reserve, and a safety margin. The
executor stops launching forward work when the monotonic time reaches the start of the reserved
recovery window, even though the total downtime budget has not expired.

Each external mutation is journaled twice: intent is persisted before the operation and observed
completion is persisted after it. After interruption, Nagare inspects authoritative address, power,
context, and write-gate state instead of blindly replaying the last command.

Candidate writes remain fenced through final state transfer, reserved-address movement, public
TLS/auth/routing/data verification, and atomic context promotion. Removing the candidate write gate
is the irreversible commit point. Command exit status is not authoritative at this boundary: Nagare
must observe the actual gate. If admission is observed, rollback is disabled even when the command
reported failure. Nagare fences further candidate writes and requires a planned recovery that
preserves candidate-only data.

Before that commit point, failure enters rollback. Rollback cancels forward work, fences the
candidate, restores the same reserved address to the old host, starts the old host if needed,
restores its recorded workload/schedule snapshot and context identity, and verifies the public path.
It continues after an SLO breach rather than abandoning recovery.

After commit, the former-active host is stopped but retained. Cleanup requires the exact
context/transaction confirmation token, healthy public service, retained backup/rehearsal evidence,
an elapsed retention gate (or explicit immediate override), and an exact match between every
resource and the transaction-owned manifest. Cleanup never deletes the reserved address, DNS, or
ordinary backups.

## Consequences

The requested downtime is an evidence-backed upper bound, not a promise independent of provider
availability. A prolonged GCP control-plane outage may breach the bound; the transaction reports
that breach while continuing recovery.

Provider adapters must expose observable, idempotent operations. A replacement command must remain
unavailable or fail closed until candidate provisioning, rehearsal/fence evidence, complete state
transfer, and live address-handoff measurements exist. This prevents a partial implementation from
quiescing production with no proven recovery path.

Retaining a stopped old host avoids compute charges but continues to incur disk cost. The retention
period is therefore visible and finalization is explicit.
