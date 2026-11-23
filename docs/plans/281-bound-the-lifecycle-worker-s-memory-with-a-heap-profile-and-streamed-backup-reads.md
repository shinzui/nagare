---
id: 281
slug: bound-the-lifecycle-worker-s-memory-with-a-heap-profile-and-streamed-backup-reads
title: "Bound the lifecycle worker's memory with a heap profile and streamed backup reads"
kind: exec-plan
created_at: 2026-11-23T20:33:04Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-23T20:33:04Z
---

# Bound the lifecycle worker's memory with a heap profile and streamed backup reads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

The lifecycle event worker (`nagare-events`, `cli/nagare-api-server/app/Events.hs`) publishes a
context's change and backup events. On 2026-11-23, during the v0.28.0 rollout, the work intranet's
worker (`mori://tan/tan-ng-labs`, context `intranet`) was OOM-killed in a loop, first at its 512Mi
limit and then at 2Gi. Two causes were found and fixed in v0.28.0:

1. `gogolVersionedReader`'s `readAt` (`cli/nagare-core/src/Nagare/Inventory/Store/Gogol.hs`)
   downloaded each backup archive with `G.sinkLBS` before writing it to scratch. The collector
   verifies up to four archives at a time and the intranet's app-database archives reach 999 MiB.
   The body now streams to the file. After the fix the worker held about 72Mi.
2. Schedule history (`cli/nagare-core/src/Nagare/Inventory/ScheduleHistory.hs`) decoded every
   converged review (804 reviews, 73 MB of JSON) and held them together. It now keeps only each
   review's desired revisions.

The operator asked for a proper investigation (2026-11-23: "we must have a space leak"). After this
plan, the worker's memory is bounded by its budgets, not by the size of the context's history: a
heap profile on a copy of the intranet's journal and backup listing shows a flat working set, the
remaining whole-body reads use streamly, the Nagare standard for streaming (operator, 2026-11-23),
and the worker's limit goes back to a small fixed value.


## Progress

- [ ] M1: a reproducible heap profile of one activation and three collection cycles against a
  local copy of the intranet journal, reviews and a synthetic 1 GiB archive, with the profile and
  the peak recorded here.
- [ ] M2: the S3 versioned reader (`cli/nagare-core/src/Nagare/Inventory/Store/S3.hs`, `readAt`)
  and any other whole-body archive read found by M1 stream with streamly; the listing in
  `listRoots` (`cli/nagare-core/src/Nagare/Events/BackupCollector.hs`) no longer holds every
  object of every key-space root at once if M1 shows it matters.
- [ ] M3: the cloud worker's limit in `cluster/bootstrap/lifecycle-events/lifecycle-events-cloud.yaml.tmpl`
  returns from 2Gi to a value M1's peak justifies, with the local template kept equal; landed with
  the full gate green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use streamly for Nagare's own streaming code; consume gogol's conduit `Stream` only at
  the gogol call site.
  Rationale: streamly is the operator's standard (2026-11-23). Gogol's download API returns a
  conduit stream, so draining it into a file with conduit's `sinkFile` needs no adapter.
  Date: 2026-11-23.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The worker runs `activate` once, then a loop of `sourceCycle` (feed materialization) and
`receiptCycle` (backup collection) in `cli/nagare-api-server/src/Nagare/Api/Events/Worker.hs`.
`receiptCycle` re-resolves every backup schedule (`loadBackupSchedules`, which reads the whole
journal) whenever the inventory head moves, then `collectOnce` lists each key-space root of the
backup bucket and verifies new runs within `defaultCollectBudget` (64 runs, 256 MiB, four at a
time). The intranet's numbers on 2026-11-23: 12,648 journal events (5 MB), 804 reviews (73 MB),
47,922 backup objects growing by about 1,250 a day, archives up to 999 MiB.

No ADR covers worker memory. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
applies: the profile is the finding, a native run only confirms.


## Plan of Work

M1. Build `nagare-events` with profiling (`-prof -fprof-auto` through a local cabal project
override, never a release build), point it at a local filesystem copy of the intranet's inventory
store and a MinIO bucket holding the listing's keys with small objects plus one 1 GiB archive, run
with `+RTS -hT -i0.5`, and record the peak and the top retainers. M2 follows the profile. M3 sets
the limit.


## Concrete Steps

Recorded when M1 runs.


## Validation and Acceptance

M1 is accepted when the profile file and its peak are recorded in this plan. M2 is accepted when
a test streams a fixture archive larger than a chosen heap bound through each reader and the
profile repeated after the change stays within the bound. M3 is accepted when the worker on the
intranet runs a day at the new limit without a restart.


## Idempotence and Recovery

Profiling runs locally against copies; nothing touches a live context until M3's reviewed
bootstrap, which can be reverted by restoring the previous limit.


## Interfaces and Dependencies

`streamly` and `streamly-core` (`mori://composewell/streamly`) are new dependencies of
`nagare-core` in M2.
