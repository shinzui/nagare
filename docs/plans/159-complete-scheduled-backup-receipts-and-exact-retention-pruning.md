---
id: 159
slug: complete-scheduled-backup-receipts-and-exact-retention-pruning
title: "Complete scheduled backup receipts and exact retention pruning"
kind: exec-plan
created_at: 2026-09-26T22:14:13Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T22:14:13Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
---

# Complete scheduled backup receipts and exact retention pruning

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture


Every scheduled backup produces a durable, verifiable receipt for one exact object, and expired backups can be pruned through an explicit review without deleting unrelated or still-needed data. Backup success must remain provable after its Kubernetes Job is cleaned up.


## Progress


- [ ] M1: Scheduled PostgreSQL, Redis, and ClickHouse backups publish verifiable per-object receipts bound to accepted schedule/source identities and survive Job cleanup and interrupted uploads.
- [ ] M2: Reviewed retention pruning selects only exact eligible scheduled objects, preserves restore dependencies and neighbors, and handles partial deletion without blind replay.

Inherited: reviewed backup CronJobs upload and read back exact bytes without inline keep-last-N deletion. Manual backups already have stable identities, hash-checked receipts, expiry, and exact reviewed pruning. Scheduled receipt ingestion and retention pruning are the missing behavior.

First producer correction (2026-09-27): reviewed scheduled CronJobs now derive their object key from the Job controller UID exposed on the Pod, validate that identity in the upload shell, and use the existing provider-conditional create-only transfer before readback. This removes timestamp collision/overwrite from new reviewed schedules. The inherited self-pruning legacy renderer retains its prior timestamp behavior until a reviewed schedule update. `cabal test nagarectl-test --test-options='-p backup' --test-show-details=failures` passed after the MinIO shell fixture used an S3 prefix. This is only the key/transport part of M1: no durable delegated receipt, ingestion command, Job-cleanup proof, or restore consumer passed yet. M1/M2 remain open.


## Surprises & Discoveries

2026-09-27: The reviewed schedule still used a second-resolution timestamp and a normal copy, so concurrent/retried Jobs could address the same object. Kubernetes supplies the physical Job UID on controlled Pods as `batch.kubernetes.io/controller-uid`; the downward API projects that label into the upload container. The existing manual-backup conditional transport can then create the scheduled object without overwriting another run. This is the first producer correction under the existing scheduled-receipt acceptance, not a new retention policy.




## Decision Log


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.


## Outcomes & Retrospective





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership, exact reviewed effects, and full release acceptance despite this split. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A refusal protects an unfinished feature but cannot count as its completion.

cli/nagare-dsl/src/Nagare/Resource/Database.hs owns database declarations. cli/nagarectl/src/Nagare/Inventory/Database.hs binds their native members. cli/nagarectl/src/Nagare/Database/Backup.hs renders backend-specific backup Jobs; cli/nagarectl/src/Nagare/Inventory/Backup.hs exposes BackupSourceProof, receipt parsing, and manual backup compilation. cli/nagarectl/src/Nagare/Inventory/Prune.hs and cli/nagarectl/src/Nagare/Database/Prune.hs implement existing exact manual pruning. cli/nagarectl/src/Nagare/Cluster/GcsJob.hs supplies local object-store/GCS transport rendering. cli/nagarectl/src/Nagare/Inventory/TaskLifecycle.hs already suspends, retains, and collects schedules through separate reviews. Reuse these contracts instead of creating a scheduler or parallel receipt store.


## Plan of Work

**Cross-plan order.** This plan need not finish every engine before EP-160 starts M2. EP-159 owns the receipt envelope, scheduled delegation, and producer formats; EP-160 owns consuming each format and proving recovered content. For each engine, agree those concrete fields/procedures and run a producer/consumer roundtrip before expanding schedule variants. Preserve manual receipt compatibility. This is early verification of existing acceptance and does not make all of EP-160 a hard dependency of this plan.

**First implementation checkpoint (2026-09-27).** Prove one PostgreSQL scheduled Job → verified object/receipt → Job cleanup → public receipt ingestion path using the existing receipt/store/command service, then exercise its actual restore consumer with EP-160 M2 before extending receipt production to Redis and ClickHouse. The current `compileManualRestoreScope` expects an accepted backup scope containing one Job; merely parsing a scheduled receipt does not meet that consumer contract. Provide the compatible source binding rather than fabricating a surviving Job. Check restore/session dependency protection before finishing pruning. Engine formats and their real restore compatibility remain explicit acceptance, not an assumption from a successful upload. Reuse the same path and failure points for the other engines; do not build a parallel scheduler, receipt authority, or inventory. This orders the current M1/M2 work without dropping any engine, retention, interruption, or cloud assertion.


M1 extends the accepted CronJob declaration with bounded delegation: its controller may create backups only for that source, schedule revision, private storage capability, and dedicated object-key space. Give each execution a stable run identity tied to the actual Job incarnation; a timestamp alone is insufficient. The receipt identifies the accepted schedule revision, logical source resource, observed source incarnation, exact object key/version, stored-byte digest, engine/format, completion result, and explicit retention policy. Keep reusable credentials out of it. Reuse or version the manual receipt format compatibly; existing manual receipts must still decode and restore.

The Job creates objects without overwriting existing keys, checks stored bytes, and publishes completion evidence only after data verification. Add an explicit CLI receipt-ingestion/inspection path under db backup-receipts that verifies the accepted delegation and exact provider/Job evidence before incorporating an immutable receipt into inventory history. It must work after normal Job TTL cleanup using already-retained proof; an arbitrary object found under a prefix is not trusted history. Pin the source revision and UID at execution, account for schedule replacement and in-flight old Jobs, and reject changed sources or incomplete receipts. Handle object-created/receipt-missing and acknowledgement-loss cases explicitly. Future schedules must use the new contract through a reviewed CronJob update, including existing accepted schedules; the existing disable-backup-prune route is not by itself the migration.

M2 compiles a separate reviewed pruning operation from accepted receipts and the schedule's explicit retention policy. Preserve configured keep-last-N behavior by computing an exact candidate list from verified complete receipts at review time, with explicit finite expiry where supplied and retain-forever remaining protected. Revalidate policy revision and dependencies at apply. Partial listings, malformed receipts, unknown versions, or in-flight ingestion cannot authorize deletion. Block pruning while accepted or unresolved restore work references an object. Delete only reviewed object and receipt versions, using the existing version-conditional transport; prefix-wide deletion is forbidden. Record partial deletion and recover exact remaining members without changing the candidate list. Suspend and retire schedules through TaskLifecycle when requested; already-created backups remain visible and recoverable.

Extend cli/nagarectl/test/InventoryKubernetesSpec.hs and the existing object-store shell fixtures for scheduled executions, duplicate run IDs, old schedule Jobs, Job cleanup, tampering, unknown listings, active restore references, finite expiry, keep-last-N boundaries, and mid-prune failures. Targeted local object-store execution proves the receipt protocol; EP-155/156 incorporate it into complete local/GCS recovery.


## Concrete Steps


Run from the repository root in the existing development environment. A newly named test group must be registered and run at least one test; zero selected tests is not passing evidence. No provider mutation is part of these initial checks.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p backup' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p prune' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
bash scripts/test-application-entrypoint-guards.sh
```

Expected result: selected tests and build exit zero; refusal fixtures prove zero unintended effects. At a milestone boundary also run the affected full suite, `bash scripts/check-haskell-style.sh`, and, when user docs change, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`. Add exact public-command native fixture invocations with their saved review paths before recording acceptance.


Required new public interfaces are `db backup-receipts NAME --backup-id ID --save-plan DIR` for importing one completed delegated receipt and `db prune-scheduled-backups NAME --save-plan DIR` for exact policy-based pruning. A read-only `db backup-receipts NAME` lists accepted receipts and unresolved ingestion without writing. Implement them before the following fixture use:

```bash
nagarectl db backup-receipts "$DB" --backup-id "$BACKUP_ID" --save-plan "$RECEIPT_REVIEW"
nagarectl inventory apply "$RECEIPT_REVIEW" --yes
nagarectl db prune-scheduled-backups "$DB" --save-plan "$PRUNE_REVIEW"
```

DB and BACKUP_ID select the exact disposable source and delegated execution; directories are new per operation. The ingestion review binds the receipt object/version and accepted delegation before history changes. Inspect the exact prune members before applying that saved review. Never let list or plan implicitly delete objects. Schedule policy/source changes use a reviewed update through the existing database compiler.

## Validation and Acceptance


Trigger two executions of one reviewed schedule and obtain two independently verifiable backups with distinct physical run identities. Delete the completed Jobs through their allowed cleanup and prove the accepted receipts remain usable. Restore selection verifies receipt and current object bytes; an incomplete/tampered/foreign receipt never becomes a successful backup. Test all three supported engines' receipt production, not only PostgreSQL.

With retained, expired, newest-N, and restore-referenced objects sharing a storage prefix, review the exact prune list, apply it, and prove only eligible versions disappeared. Concurrent replacement, a changed retention policy, incomplete provider listing, and newly admitted restore dependency refuse. A partial delete records unresolved state, never successful cleanup. The public command harness must observe effects and history, not just compare rendered scripts.

Use focused tests while implementing one coherent milestone, then the affected full suite/build and documentation checks at its acceptance boundary. Repeat broad gates only after a relevant change or failure. Record the exact command, candidate revision, review/transaction IDs, fixture identity, result, and evidence location. Distinguish recording-provider tests from real provider evidence. Shared integration runs may supply the same assertion to several plans; do not wait for administrative plan closure to run them. Keep Progress checkboxes directly under Progress, without nested headings.


## Idempotence and Recovery


Use isolated test state and exact disposable resource identities. Retain the saved review, private native members, and journal after failure. Reuse an operation ID only with identical accepted intent; changed input requires a new review. Unknown provider results remain unresolved until observation proves what happened. No blind replay, broad prefix cleanup, history reset, or automatic data rollback is allowed. This plan authorizes implementation and its bounded verification, not a real release publication. Use Mori to locate dependency sources before relying on APIs, and verify authoritative releases before changing pins. Never inspect /nix/store.


## Interfaces and Dependencies


Completed [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) provide prerequisites. This plan owns the scheduled receipt extension, delegation, ingestion, and retention selection. [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) consumes the receipt selector and dependency rules and must not invent another backup format; existing manual receipts let restore work start before this plan finishes. [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) consumes backup/recovery references where maintenance requires them. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns global registration coverage, and [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md)/[EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) own combined native scenarios. Historical, uncalibrated estimate (not a current delivery forecast): 8–16 active hours, low confidence, excluding integration fixtures. Reforecast after one scheduled run proves durable ingestion after Job cleanup; missing object-version or controller-source evidence is a named design blocker.


## Revision Notes

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
