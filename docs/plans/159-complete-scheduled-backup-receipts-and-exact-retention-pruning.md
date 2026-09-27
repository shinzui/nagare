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

Native producer probe (2026-09-27): in the isolated EP-155 six-CPU v2 fixture `/tmp/nagare-mp23-ep155-23001-6cpu-v2`, a disposable Job triggered from the accepted PostgreSQL CronJob `nagare-dbbackup-mp23-pg-a` completed with physical UID `26057256-3a89-47bb-9283-b99e6444c0e9`. A separate read-only S3 HeadObject probe found its exact `databases/mp23-pg-a/<Job UID>.sql.gz` object at version `9245f0ea-d6ba-44e7-8f92-ca53d9c60e37`, length 398 bytes. After deleting only that test Job, a second probe returned the same object version and length; both probe Pods were removed. This proves the corrected key/upload and object survival for a template-triggered PostgreSQL Job. The run did not create a delegated receipt, ingest one into history, use an automatic CronJob firing, or restore bytes; those M1 and EP-160 obligations remain open.

Next producer increment (2026-09-27): reviewed schedules now write a distinct version-2 receipt at `<UID-keyed object>.receipt.json` only after exact stored-byte readback. It records checksum, physical Job UID, object address, and static database/namespace/engine/format/schedule/keep metadata, then checks the create-only receipt readback and leaves the receipt in the Pod termination message. Manual version-1 receipts and legacy self-pruning schedules retain their existing behavior. A shell fixture verified the version-2 body, exact checksum and address, termination copy, and duplicate-run refusal; the 34-test backup group passed. This producer output is not yet trusted inventory history: accepted schedule revision, source UIDs, dedicated delegation, public ingestion, post-cleanup authentication, and restore/prune consumers remain M1/M2 work.

Installed producer probe (2026-09-27): revision `70bab28c` saved and applied `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-b-scheduled-receipt-review` as transaction `tx-9fcc70a5d832ba91f898155ea8d57e1037bd507afac0da5ef6e0db2c9db7c382`. Its sole write updated app B's accepted CronJob; six other members verified, and both app Services kept their UID/generation/Ready revision. A disposable Job from that template completed with UID `b701989b-6f67-41fe-95e3-6ea0fd875d6a`. The v2 receipt named that UID and exact backup address with SHA-256 `8304e9c2e2ae18e50bbe272918a0720ca4a0a0bbe5072952ec45936c1ce8f7e8`. A separate MinIO read matched the stored backup checksum and receipt body, with backup version `9ceadaeb-c4d2-41ef-a1be-dc4d3c533ef0` and receipt version `630943ed-6e7d-48c9-87fb-27c70a4987ff`. After the test Job was deleted, both exact versions, receipt bytes, and checksum remained unchanged. The read-only probe Pods were removed. This is a template-triggered producer proof; automatic schedule firing, accepted delegation/source UID, reviewed ingestion, restore, and pruning remain open.


Source-incarnation increment (2026-09-27): a reviewed database bundle now declares a dedicated backup ServiceAccount, a Role limited to `get` on that database's named StatefulSet and PVC, and their RoleBinding before the CronJob. The schedule's Job uses that account to capture both source UIDs before dumping and rereads them after stored-byte verification. A changed UID prevents version-3 receipt publication. The DSL test and 34 selected backup tests passed; a shell test covers both matching and replaced sources. Version-2 objects remain untrusted legacy producer evidence. A receipt still lacks accepted schedule/source revision and post-cleanup delegation authentication, so this increment does not complete M1 or enable ingestion.

Native source-bound probe (2026-09-27): an installed candidate updated app B through a saved review with three dedicated-reader creations, one CronJob update, and an unchanged-byte release-history dependency update. `kubectl auth can-i` confirmed the account can get app B's two exact source objects and cannot get app A's corresponding objects. The first template-triggered Job, UID `acd5bf2f-9b57-428e-9495-7fa776e53d50`, exposed that the MinIO upload image lacks `cmp`: it uploaded backup version `e0cc4812-15f1-4cf6-840a-b3808d3852a3` (629 bytes), failed before receipt creation, and retried without overwriting. A separate read confirmed the receipt was absent. The comparison now uses the image's existing SHA-256 tool. The failed Job and probe Pod were deleted; the orphaned object remains for the required interrupted-upload treatment.

The corrected reviewed CronJob then completed a template-triggered Job with UID `24c67f98-547b-4735-9413-328a9564f9d3`. Its version-3 receipt pins StatefulSet UID `bb905792-cc6f-48d7-b873-4687ae6bc1e5` and PVC UID `d29e9704-10c5-425a-8f28-e8f2971d3893`, matching live source observations. A separate read found backup version `02f95c28-9542-4bee-ad03-646d5d6b582b` and receipt version `6a8f4de7-c293-4cc6-978d-524b19b0b867`; the receipt and stored backup independently matched SHA-256 `cd8b61aba90d4f70a40812f7cb9e6229b09c615aaaa2724af79a7d1bc99ee1d3`. After deleting the Job, another probe returned the same versions, receipt bytes, and checksum. Both read-only probe Pods were removed. Public ingestion, authenticated delegation, scheduled restore, automatic firing, and pruning remain open.

Signing increment (2026-09-27): reviewed retained databases now declare a create-only, retained signing-key Secret in their own scope. The guarded Kubernetes executor generates 32 random bytes as lowercase hex at mutation time; only the upload container receives the key through a Secret reference. A version-4 receipt wraps a canonical payload containing Job UID, exact object, checksum, source UIDs, and a schedule-template revision in an HMAC-SHA-256 envelope. A pure parser checks the HMAC, exact receipt/object key, accepted static metadata digest, and source UIDs before returning a candidate; it does not accept or restore the candidate without provider-version/byte checks. Manual version-1 receipts remain unchanged. Focused tests cover a valid signed receipt and wrong key/address/source, and the generated Secret's closed template and private data shape. The key is not in the receipt, review, or public output.

Native signed producer proof (2026-09-27): saved review `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-b-signed-review` converged as `tx-eaf54d6f865f5bca57f17b3e7a9e661f7c0f536ead839f3d43b22fdd41a52301`, creating only app B's signing Secret and updating its CronJob plus the unchanged-byte release-history dependency. The Secret UID was `ac503b79-ff4f-4c7d-8c2f-29f5224b6429`, with one private `HMAC_KEY` field; the backup ServiceAccount was denied API `get` on that Secret. A template-triggered Job with UID `d11f1c6f-9a6a-420a-9df3-e39695abc67e` completed. Its exact backup version `5999f02f-67a5-4f46-a69a-757ea15fef0e` and receipt version `d860f36c-dc64-4910-ac69-e1b8d2206fa4` produced stored-byte SHA-256 `88699954b52434285d838f24b841d76efed8344a548ff02242aaeb0e3b9291d4`. A separate read found the stored receipt identical to the Job termination message; its HMAC verified against the Secret without printing the key, and its static metadata equaled the accepted CronJob environment. After Job cleanup, another probe returned the same versions, bytes, and checksum. Both probe Pods were removed. This is authenticated producer evidence, not an accepted receipt: reviewed public ingestion, exact provider-version binding, source/schedule history handling, restore, automatic schedule firing, and pruning remain open.

Ingestion preparation (2026-09-27): a read-only host-side MinIO probe used Kubernetes port-forward and curl SigV4 to fetch both exact v4 object versions after the producer Job and probe Pods were gone. The receipt was byte-identical to the retained copy and the backup SHA-256 remained `88699954b52434285d838f24b841d76efed8344a548ff02242aaeb0e3b9291d4`; the port-forward was closed. A pure guard now derives the permitted object prefix, format, signing Secret reference, Job UID field source, and canonical metadata digest from the accepted CronJob's private native bytes. It refuses a different backend or source name. This still does not ingest the receipt: the public read-only listing, provider-version-bound review/apply, and retained history record remain to implement.

Exact-provider reader (2026-09-27): the Haskell candidate path now opens a bounded local port-forward, reads the MinIO credential Secret only in the operator process, passes SigV4 credentials to curl on stdin, and fetches both current and version-selected copies of the receipt and backup into scratch files. It requires identical receipt bytes, both version IDs and lengths, a valid HMAC against the accepted signing Secret, accepted source/schedule metadata, and a fresh backup SHA-256. A live read after producer Job cleanup returned backup version `5999f02f-67a5-4f46-a69a-757ea15fef0e`, receipt version `d860f36c-dc64-4910-ac69-e1b8d2206fa4`, lengths 627/669, and checksum `88699954b52434285d838f24b841d76efed8344a548ff02242aaeb0e3b9291d4`. The retained receipt-missing orphan was refused, as was a wrong signing key. A fake-reader test rejects changed bytes at an exact receipt version; 37 focused backup tests passed. This returns candidate evidence only; the reviewed ingestion Job/history and cloud provider reader remain open.

First public ingestion (2026-09-27): `db backup-receipts mp23-pg-b -n personal --backup-id d11f1c6f-9a6a-420a-9df3-e39695abc67e --save-plan /tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-b-receipt-review` saved an independent scope with exactly one Job creation and one declared verification operation. Its guarded apply converged as `tx-d95aded479f0f4b69243f138941b68b3c83332a614b535c94f50b5cca061100b`. The Job UID `3f95a47e-6644-4269-837b-0745a15d69c2` completed with a terminal proof of the exact backup/receipt versions and checksum above, reread from MinIO after the producer Job had been deleted. Apply reconstructed the four accepted source native members from the pinned database scope revision and checked their current UIDs, ownership, readiness, and bytes before submit and verify. `db backup-receipts mp23-pg-b -n personal` listed the accepted receipt scope. The interrupted-upload orphan refused review because its receipt was absent. An unchanged replan initially exposed noncanonical dependency/input ordering in the compiler; after sorting those lists, a replay review applied without replacing or rerunning the completed Job (same UID, one success). This is the PostgreSQL local ingestion checkpoint. The read-only listing still needs unresolved provider discovery, historical schedule-revision handling, GCS exact-generation support, and the EP-160 restore consumer before M1 is complete; Redis/ClickHouse and pruning remain open.

PostgreSQL consumer handoff (2026-09-27): EP-160 selected that accepted receipt through the public `db restore` command and applied a reviewed scratch Job after the original producer Job had been deleted. The download init container requested the two accepted MinIO versions, checked returned version IDs and hashes, and the restore container loaded table `mp23_fixture` with row `(1, scheduled-v2)` into `mp23-pg-b_restore_schedv4`, matching the source. This closes the first local producer/ingestion/restore-content roundtrip, but not all of M1: the unresolved-listing, old schedule, automatic firing, GCS, Redis, and ClickHouse cases remain.

Read-only provider discovery (2026-09-27): `db backup-receipts mp23-pg-b -n personal` now lists the current schedule's exact MinIO prefix and compares every object/receipt pair with accepted ingestion scopes. A truncated page, count mismatch, duplicate key, or malformed key refuses the listing. It rechecks complete pairs through the signed exact-version reader, reports verified but unaccepted receipts, and surfaces incomplete or invalid pairs without importing them. The native fixture listed the accepted v4 run `d11f1c6f-9a6a-420a-9df3-e39695abc67e`, the receipt-missing interrupted upload `acd5bf2f-9b57-428e-9495-7fa776e53d50`, and two earlier invalid receipt envelopes as unresolved. Historical schedule revisions and GCS remain open, as do automatic firing, the other engines, and exact pruning.

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
