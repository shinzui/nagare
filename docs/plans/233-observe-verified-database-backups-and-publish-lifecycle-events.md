---
id: 233
slug: observe-verified-database-backups-and-publish-lifecycle-events
title: "Observe verified database backups and publish lifecycle events"
kind: exec-plan
created_at: 2026-10-31T14:21:30Z
intention: "intention_01m695aak2e4ebx7gw1pcvphvr"
master_plan: "docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-31T14:21:30Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T14:34:39Z
      mode: "other"
      note: "Completed initial planning draft and checked source commit, control history, dependencies, recovery and validation interfaces."
---

# Observe verified database backups and publish lifecycle events


## Purpose / Big Picture


Consumers learn when Nagare has verified a database backup even when no operator is running the CLI. They can distinguish that event from the later reviewed acceptance of the backup as a recovery point. A backup notification identifies exact stored versions and source lineage; it never authorizes restore, ingestion or deletion.


## Progress


- [ ] M1: One unattended managed PostgreSQL scheduled receipt passes the real verifier and appears once as `database.backup.completed`, including after collector restart.
- [ ] M2: Scheduled Redis/ClickHouse and app-database producers, plus reviewed manual database backups, produce completion events under the same identity and verification rules.
- [ ] M3: Reviewed backup acceptance emits a separate durable event; bounded collection, activation, delayed discovery and failure diagnostics are demonstrated.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-31: Separate read-only completion observation from reviewed acceptance. The background collector may verify bytes and publish notification facts but cannot ingest receipts, prune archives, run a backup or change inventory authority.

2026-10-31: Identify a backup by logical source/recorded lineage, producer run ID and exact archive/receipt versions, independent of discovery path and current database display name.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)


## Context and Orientation


A backup receipt is authenticated metadata describing a stored archive and its source. Verification checks receipt authentication, exact source/schedule identity, archive bytes and provider versions. A recovery point is a backup admitted through a converged reviewed ingestion, with authority to participate in later restore/prune planning. Observation alone is not acceptance.

`cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs` decodes and authenticates manual and scheduled receipts. `ScheduledReceipt.hs`, `ScheduledStore.hs` and `ScheduledGcs.hs` provide the existing evidence/provider paths. `ScheduledIngest.hs` compiles verified scheduled runs into reviewed ingestion Jobs; `ManualReceipt.hs` creates durable Job-free manual receipt records. `ScheduledStatus.hs` finds accepted managed database, application-volume and app-database schedules. The new collector selects only the database and app-database kinds. `AppDatabaseBackup.hs` and `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs` handle app-database-specific bindings. `docs/user/backups-and-disaster-recovery.md` describes verified candidates, unresolved objects and accepted receipts.

Scheduled producers upload and authenticate independently of the CLI. Their Kubernetes Job may already have been collected when Nagare discovers a durable receipt. This is why journal-only projection cannot provide prompt completion events. Reuse the existing archive/receipt verification code and exact identity accessors; do not create a weaker HMAC-only notification verifier. Verification may include expensive archive reads and needs independent concurrency/bandwidth limits.

[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) requires recorded source incarnation and rejects same-name replacements. [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md) retains reviewed retention and single-node operation. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) retains the cross-tool journal and reviewed recovery authority. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires adversarial provider worlds. The hard prerequisite is the complete source/feed implementation in `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md`.


## Plan of Work


### M1 — A real scheduled backup to a durable notification


Add `cli/nagarectl/src/Nagare/Lifecycle/Backup.hs` for pure event construction and `BackupCollector.hs` for bounded collection over injected inventory/object-store/receipt-verifier operations. Enumerate database schedules from a checked context snapshot. Pin each schedule's accepted revision and recorded source/PVC incarnation and use retained accepted schedule history where a receipt belongs to an earlier schedule version. Discover complete archive/receipt pairs and invoke the existing verifier at exact MinIO versions or GCS generations. A receipt without an archive, invalid signature, mismatched identity, changed stored bytes, wrong schedule lineage or unresolved provider result creates a diagnostic, not an event.

First prove one PostgreSQL run by executing the real verifier against faultable provider interpreters and feeding its validated result through EP-231's source-key/materialization interface. Once verified, persist a digest-bound verification observation in the lifecycle prefix before advancing any discovery checkpoint. A crash after verification but before publication can recover from that immutable observation without assuming the archive remains available forever. Orphan observations not committed by their observation head remain invisible. Observation time is distinct from signed recovery-point time and receipt completion time. Missing completion time stays unknown; never label the dump's recovery-point timestamp as its finish time.

The collector has read authority over backup/provider data and writes notification state only. No inventory writer claim, `inventory apply`, backup Job creation, restore or prune action is available through its capability record. Expose a one-cycle command `nagarectl events collect-backups --once` for disposable fixtures and operator diagnostics; it requires notification-store write capability explicitly and does not run as a side effect of `events list` or any admin read route.

### M2 — Database variants and manual backups


Extend the same collector to managed Redis and ClickHouse schedules and app-database schedules across supported engines. Preserve each existing format, source/schedule binding and signing-key rule. Share verification and candidate construction with reviewed manual database backup completion. A manual backup's executor source fact is eligible only after the operation's exact Job/Pod receipt and stored archive checks passed and final transaction convergence committed. A failed or ambiguous manual backup cannot use Kubernetes Job success alone as proof.

Use a normalized backup identity including context, logical database/source lineage, run ID and pinned archive/receipt versions. Do not include collection time, current display name, current schedule revision or discovery route in its stable key. Preserve reviewed historical source lineage across rename/rebuild; report a replaced unrecorded source as unresolved. Manual and scheduled key spaces are explicit, so coincident run strings cannot collide. If both direct manual execution and later receipt discovery encounter the same backup, they resolve to the same completion event ID. Store enough verified public metadata to read the event after Job cleanup; never expose raw receipts, signing keys, passwords, object credentials or signed download URLs.

### M3 — Acceptance events and bounded unattended collection


Integrate a typed `database.backup.accepted` producer with EP-231's atomic final-convergence source records for scheduled ingestion and durable manual receipt acceptance. The event identifies the normalized backup ID, its completion event ID when known, the accepted receipt scope/revision, transaction/review and recovery-point metadata. Acceptance never emits at save-plan or admission. Repeated receipt verification or a later no-op review must not produce another acceptance event for the same receipt identity. A reviewed bulk ingestion emits one acceptance event per new backup. Completion and acceptance may be discovered in either order; cross-references use deterministic IDs without claiming feed-order causality. Acceptance also supplies the original verified completion fact when that backup has not yet been observed, using the same key to avoid duplicates.

Persist per-schedule discovery continuation and bounded outstanding candidates. Do not advance past an unresolved candidate as if verified; quarantine its identity and reason durably while letting later runs progress. A lexicographic object-name cursor alone is insufficient because delayed receipts can appear behind it. Use paginated discovery with a retained rescan window and a resumable full reconciliation sweep so late objects are eventually considered. Keep verifications cached by exact immutable archive/receipt version plus verifier/schema and signing-key identity; do not redownload every old archive on every poll. Invalidate authority if binding, lineage or verifier requirements change.

At reviewed activation, pin the schedule set and a baseline of existing provider versions; preexisting runs are not sent as new completion notifications. Receipts created after that baseline are discovered, including archives pending at activation whose receipts arrive later. Runs created while the collector is down must be caught up after restart. Explicit historical notification backfill is outside v1; accepted old recovery points may still create acceptance events when newly ingested after activation. Document that deletion by an external actor before verification can prevent a completion event: notification is not a guarantee of observing arbitrary external changes. Collector errors and oldest unverified candidate age must be visible.

Use a default 30-second polling interval, four concurrent verification tasks and configurable byte/work budgets. On a healthy fixture with one small run, publish within two polling intervals after verification inputs are available; total latency includes archive verification and backlog. Add a virtual clock to tests instead of sleeping. Existing backup schedules, ingestion reviews and pruning policy stay unchanged.


## Concrete Steps


From the repository root, after EP-231 is Complete, locate dependency code through Mori before using APIs, and verify current registry releases/tags before any bound change. This plan adds no engine, broker or backup-tool dependency.

```bash
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Lifecycle.Backup/' --test-show-details=direct
```

Create a nonempty `Lifecycle.Backup` test group that drives the real existing receipt parser/verifier through filesystem and object-store interpreters and the real materializer. After the fixture harness exports an isolated context and seeds one completed backup, run the new commands:

```bash
cabal run nagarectl --project-dir=cli/nagarectl -- events collect-backups --once
cabal run nagarectl --project-dir=cli/nagarectl -- events list --type database.backup.completed --contract 1
```

Expected output: one completion event for the seeded exact versions and a collection summary naming verified/pending/error counts. Repeat collection: no new completion event. Execute reviewed receipt-ingestion workflow in the fixture and observe one `database.backup.accepted` event. The implementation must document exact fixture setup and avoid an implicit operator context.


## Validation and Acceptance


Prove PostgreSQL end to end before expanding variants. Cover all supported managed database and app-database producer formats, manual completion, bulk scheduled acceptance and durable manual receipt acceptance. Test signature failure, replaced PVC/StatefulSet, wrong schedule history, missing archive, changed generation/version, truncated archive, listing pagination, delayed receipt behind the scan cursor, Job disappearance, transient errors, collector death between durable writes and overlapping collectors. Neither collection nor event publication mutates the inventory head or provider archive/receipt objects.

Seed a history of 1,000 verified runs and introduce one new run. Subsequent cycles may scan metadata/index pages within declared budgets, but archive verification reads only newly unverified versions; assert byte/object counts. One permanently invalid old object does not starve later valid backups. A restart catches up runs completed during downtime and preserves completion IDs. Source lineage and exact provider versions distinguish same-name replacements and rebuilt databases. Verify completion and acceptance can appear in either publication order and still refer to the same backup. API/CLI payloads contain no secret material. EP-235 owns live scheduled execution and latency confirmation.


## Idempotence and Recovery


Persist verified observations before marking collection progress and commit event/checkpoint changes through EP-231's protocol. Restart/retry from the authoritative checkpoint; duplicate reads are safe. Keep unresolved candidates diagnostic and retryable with backoff, without marking them completed. Pausing notification collection does not pause backups. Do not change backup retention or grant restore authority to repair notification state. Reviewed acceptance remains entirely in the inventory executor. A lost event-store write acknowledgment is settled by reread, never by creating a new backup ID.


## Interfaces and Dependencies


Hard dependency: all of `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md`. This child owns normalized backup keys, completion/acceptance payload construction, receipt-observation persistence, polling/budget semantics and read-only collector operations. It consumes shared source facts and materialization and reuses existing verified receipt accessors. `docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md` can consume fixture backup events independently and later verifies the real payload. `docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md` depends on this whole child and owns credential installation, the long-running scheduler and native proof. Application-volume events are outside this child even though the existing schedule classifier also knows volume schedules.
