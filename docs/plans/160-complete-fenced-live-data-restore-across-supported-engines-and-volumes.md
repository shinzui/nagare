---
id: 160
slug: complete-fenced-live-data-restore-across-supported-engines-and-volumes
title: "Complete verified isolated database and volume restore"
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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T04:11:42Z
      mode: "implement"
      note: "Started durable data-fence protocol and identified engine backup format gaps"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:04:28Z
      mode: "update"
      note: "Prohibit GKE, correct finite M1 closure criteria, and record execution audit limitations."
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T13:52:50Z
      mode: "implement"
      note: "Implement and verify M1 saved-review Kubernetes fence registration and durable recovery"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T23:06:39Z
      mode: "implement"
      note: "Prove second accepted PostgreSQL scheduled receipt through a real scratch restore and content check"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:48:42Z
      mode: "implement"
      note: "Reconcile isolated restore source-preservation evidence on the retained local fixture"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T05:55:39Z
      mode: "implement"
      note: "Record local manual receipt and Job-free restore checkpoint"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-02T13:14:42Z
      mode: "implement"
      note: "Repair pinned GCS restore download environment from native failure and execute rendered script in public fixture"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T14:57:48Z
      mode: "implement"
      note: "Validate persistent interpreter restore and rendered-script counterfactuals"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T19:46:21Z
      mode: "implement"
      note: "Consume exact-generation scheduled GCS receipts and preserve historical accepted restore authority"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T14:47:59Z
      mode: "implement"
      note: "Native cp3 tamper and wrong-destination drills; F35; volume tamper gap"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T17:54:33Z
      mode: "implement"
      note: "B2 volume: planning-time object verification, pinned restore download, verification manifest, cp3 tamper drill"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T18:03:23Z
      mode: "implement"
      note: "F36 Redis scratch restore abandonment and B2 recovery argument"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T20:36:19Z
      mode: "implement"
      note: "F37: execute-time no-effect abandonment (d9aed800), reviewed field takeover (1df735a6); C2 adoption/drift/storage notes"
---

# Complete verified isolated database and volume restore

This ExecPlan is a living document under [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02: the earlier dated checkpoints (including the full M1 data-fence construction history, native probe identifiers and the retired live-overwrite experiments) are preserved verbatim in [the pre-consolidation snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file. The file slug predates the current title and is kept so existing links resolve.

Full plan before trimming: [160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, a Nagare operator can take an accepted backup of a PostgreSQL, Redis or ClickHouse database, or an accepted snapshot of an application volume, and restore it into a new isolated destination through one reviewed command. The destination is a distinct scratch database, a separate Redis instance, or a new PersistentVolumeClaim (PVC). The restore verifies the exact archive bytes and the known content before reporting success. The live source keeps running unchanged, and an interrupted restore can be resumed or explicitly abandoned without replaying a destructive step. This is the recovery path the company intranet needs before real data is admitted: a backup that has never been restored and checked is not evidence of recoverability.

Scope follows MP-23's supported release contract. Required: verified isolated restore for all three engines, volume restore to a new PVC, and the source preserved. Deferred: overwriting a live database or PVC, and automatic promotion or cutover. The `--into-live` routes refuse new admission. Live fences and live restores admitted before the 2026-09-28 reduction must remain recoverable through their recorded identity. Pointing an application at a restored destination is a separate, documented operator step, not part of this plan. Recovery-time targets are operator decision D4 in MP-23 and are not decided here.

To see it working, follow the public path in Concrete Steps. Back up a disposable database, change the source, restore with `db restore NAME BACKUP_ID --restore-id ID --save-plan DIR`, apply the review, and query the new destination. It returns the backed-up rows while the source still returns its changed rows.

## Progress

- [x] M1 — shared data fence accepted (2026-09-27). The fence is bound to saved reviews. On local k3s it proved writer exclusion for StatefulSet, Deployment, CronJob and active-Job writers; a fail-closed mount and route guard; exact-name and collection-delete guard authority; and durable interruption and recovery. Release happens only after real readback. Evidence: saved review `ec327465…` on disposable k3d `ep160-ex-23315` (30 fence tests), cross-engine mounted-Job exclusion on `ep160-ex-64754`, and the full 892-test suite at the acceptance boundary (implementer, snapshot). Recovery of already-admitted fences is preserved: ordinary resume refuses with `active-data-fence`, and the explicit decisions `continue-fenced-operation`, `verify-fenced-effect`, `recover-fenced-backup` and `forward-fenced-release` remain. Native terminal-loss and failed-SQL recovery of an admitted PostgreSQL live restore were shown locally on 2026-09-27 (implementer, snapshot).
- [x] Live overwrite deferred (2026-09-28; source confirmed at consolidation). `db restore --into-live` and `storage restore --into-live` refuse at the command, and a saved `RestoreLiveDatabase` review refuses admission with `deferred-operation` (`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`). `scripts/audit-managed-commands.py` and `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs` pin exactly these deferred routes.
- [x] Cloud isolated restore for all three engines from accepted GCS receipts (2026-10-02, independent). PostgreSQL: scheduled ([76628094](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/scheduled-gcs-restore-76628094.json)), historical receipt after a schedule change ([ec2e1cd4](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json)), and manual with the producer collected ([e6255e6f](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); F19 Closed). Redis and ClickHouse use authenticated known content with the source changed afterwards ([e6255e6f](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json)). The repaired ClickHouse consumer survives the transient post-RESTORE refusal (F22 Closed). Source and neighbor rows and UIDs were preserved in every run.
- [x] Local isolated restore for Redis, ClickHouse and a new PVC (2026-10-02, independent). The producers had been removed and the source was changed after backup; Redis and ClickHouse restored only the backed-up content, and the volume restore read the original SHA-256 from a distinct scratch PVC ([ec2e1cd4](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)). Local PostgreSQL isolated restore is implementer-only (2026-09-27/28, snapshot).
- [x] Cloud new-PVC volume restore (2026-10-02, independent): a manual GCS snapshot restored into a scratch PVC, verified read-only with the source Pod and PVC intact ([proof](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json)).
- [x] Source-unavailable content drills for all engines and the volume (2026-10-02, independent). A fresh operator root with source Kubernetes access denied fetched accepted history and exact generations from GCS and restored known content into isolated containers ([PostgreSQL](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/source-unavailable-content-ec2e1cd4.json), [Redis/ClickHouse/volume](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/source-unavailable-engines-e6255e6f.json)). Separately encrypted credentials were decrypted from the fresh root ([credentials](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/encrypted-credential-recovery-ec2e1cd4.json)). Limits: these were manual drills, not a public command after a real outage, and no recovery time was recorded.
- [x] Interruption handling (mixed evidence; see the matrix). Independent: the six-scenario effectful restore pilot inside the 47-scenario `just test-inventory-effects` run covers lost write acknowledgement, failure before write, readiness timeout, changed source, and corrupt or missing download generations. Also independent: native ClickHouse terminal failure followed by explicit digest-bound abandonment ([ec2e1cd4](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json)). Implementer native (2026-09-28): PostgreSQL partial `COPY` abandoned and restored fresh; ClickHouse lost acknowledgement; Redis destination-created resume; volume interruption at destination creation, mid-extraction and lost verification acknowledgement.
- [x] Native refusal of a tampered accepted backup. For a database receipt and a volume snapshot whose stored bytes or object version/generation changed after acceptance, the restore refuses before any destination write, and history is unchanged. (MP-23 B2) Database part done natively (2026-10-03, implementer, cp3): a newer MinIO version at accepted Redis receipt `0841cd1d…`'s archive key made restore planning refuse with `accepted scheduled backup object version or bytes changed`. No review was saved, the store head was unchanged, the listing showed the receipt unresolved, and deleting exactly that version restored it ([record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/cp3-data-drills.json)). A review saved before such a tamper still downloads the pinned versions, which is correct. Volume part open: see Surprises (2026-10-03). Volume part done natively (2026-10-03, implementer, cp3, `fc8cba5b`). Restore planning now reads the stored receipt and archive, requires the receipt to equal the accepted Pod receipt and the archive to hash to its checksum, re-reads each exact version, and pins both versions in the review. The restore Job downloads only those versions and prints a verification manifest. Native results ([record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/cp3-volume-tamper-fc8cba5b.json)):
  - With a newer MinIO version at snapshot `indvolv1`'s archive key, planning refused with `stored volume archive differs from the accepted receipt checksum`. No review or scratch object was created.
  - A review pinned before a second tamper restored the original `acceptance.txt` (SHA-256 of `independent-volume-v1\n`) while the tamper was current.
  - Both tamper versions were then deleted by exact ID.

  `InventoryVolumeRestorePinSpec` covers the refusals, a race between the current and exact reads, pinned rendering for MinIO and GCS, and unchanged unpinned bytes.
- [x] Native refusal of a wrong-incarnation destination. A pre-existing or substituted destination (scratch database, Redis StatefulSet/PVC, or scratch PVC with a foreign UID) refuses at preflight and at execution with zero writes. (MP-23 B2) Native results (2026-10-03, implementer, cp3; [record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-implementer-results-2026-10-03/cp3-data-drills.json)): a foreign PVC at the Redis scratch address before planning is refused with `adoption-required`, with no review saved. A foreign PVC created between plan and apply is refused at that operation's preflight, and the foreign object is untouched. But the earlier Service create had already run, and the transaction stayed active with no supported exit. That is [F35](../audits/mp23-findings.md#f35). It is resolved by removing the foreign object and resuming; the restore then converged in 31 s. This item closes only once F35 is repaired and the race is re-run. (2026-10-09: F35 is Closed, and C2 re-ran the race on `83124396`.
  - A foreign PVC created at the Redis scratch address between plan and apply was refused at preflight, left with its UID and resourceVersion unchanged, and the review ended through `abandon-refused-operation` ([redis](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/local/checks/redis-backup-restore/wrong-incarnation-redis.json)).
  - A pre-existing scratch PostgreSQL database was refused by the restore Job with its content unchanged, and closed through `abandon-partial-database-restore` ([postgresql](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/local/checks/postgresql-backup-restore/wrong-incarnation-postgresql.json)).
  - An unowned PVC present before planning was refused with `adoption-required`, with no review saved and no store change, locally and in the cloud (`adoption` in both runs).
  - Not run natively: a ClickHouse destination or a volume scratch PVC with a foreign UID. The adapter tests cover them.)
- [x] Redis interruption during RDB load in the init container, and a ClickHouse restore with a genuinely partial data effect, each recovered without replay. Alternatively, a recorded argument, accepted by the independent reviewer, that the existing runs cover these cases. (MP-23 B2) Argument and fix (2026-10-03, implementer), pending reviewer acceptance. (1) Interruption alone: the scratch StatefulSet restarts the `download` init container, and resume rereads the pinned versions and converges without a second scratch target; the existing "Redis destination-created resume" run (2026-09-28) covers this. (2) Terminal Redis load failure used to wedge the store; it is now abandonable (F36, `6d7951c9`), with native proof on the C2 fresh context. (3) A partial ClickHouse effect is a restore Job failure, covered by the independently verified terminal abandonment ([F22, ec2e1cd4](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json)). **Reviewer verdict (2026-10-04, nagare-reviewer, candidate `7596632c`): argument accepted, with a correction to (1).** A kill during the download init container leaves partial files on the PVC-backed `/dump`. The restarted init container then fails (`test ! -e /dump/backup.gz && test ! -e /dump/backup.rdb`), so that case ends in a proved terminal failure and F36 abandonment, not resume convergence. A kill after the completion marker converges. In every case, `redis-check-rdb` validates the file before the server starts, the verify Job requires `loading:0`, and restore Jobs have `backoffLimit: 0`. So a half-loaded instance cannot be accepted, and a partial ClickHouse effect fails its Job and ends in the independently verified F22 abandonment. F36 was closed on the acceptance C2 ([phase-1 record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)).
- [x] Manual cloud receipts for Redis and ClickHouse proved through restore (MP-23 B2). Decided 2026-10-03: prove them inside EP-156's bounded C3 sequence rather than narrowing the contract to scheduled-only. (2026-10-09: on `83124396` in C3, `db backup scenario-redis` and `db backup scenario-ch` wrote manual GCS backups. Reviewed `db restore` brought back the known keys into a scratch StatefulSet and the known rows into a scratch database ([redis](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/checks/redis-backup-restore/result.json), [clickhouse](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/checks/clickhouse-backup-restore/result.json)).)
- [x] Independent local PostgreSQL isolated restore with known content and source preserved. (MP-23 C2) (2026-10-09: nagare-verify, C2 on `83124396`. A reviewed manual MinIO backup of `scenario-pg` restored exactly the seeded rows into an isolated scratch database, while the source kept its later row ([evidence](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/local/checks/postgresql-backup-restore)).)
- [x] All of the above re-proved on the one frozen candidate in the EP-155 local and EP-156 cloud scenarios. (MP-23 C2, C3) (2026-10-09, for the paths C2 and C3 exercise on `83124396`: isolated restore of PostgreSQL, Redis and ClickHouse, and a new-PVC volume restore, both locally and in the cloud, each with the source changed after backup. Also the wrong-incarnation refusals above, and source-unavailable recovery from escrow and the object store in both runs. [C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396), [C3](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396).)
  - Superseded (2026-10-09): native tamper refusal and the interruption cases were not re-run on `83124396`. They rest on the implementer's cp3 runs and the independent evidence above, and on tests in the green gate ([gate](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/gate-83124396.json)). The 2026-10-07 operator decision made the production-readiness checklist MP-23's fixed acceptance. For data, that checklist requires the section 2 drill, which passed.
- [x] For the data-protection gate (production use, not MP-23 completion): a documented, timed recovery procedure after source-cluster loss, measured against recovery-time targets once D4 sets them. (2026-10-09: covered by checklist section 2's drill on `mp23-c3j`. The procedure is documented (F82 Closed). The VM, data disk and snapshots were deleted, and the newest post-seed backup was verified with only escrow and GCS. It was restored into PostgreSQL 18 with 4 of 4 rows matching; recovery took 20 s ([drill](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/)). D4 has set no recovery-time target, so the time is recorded, not graded. The release notes list D4 as unmet.)

## Coverage Matrix

Status per engine and path. "I" means independently proved on a native system, "M" means implementer evidence only (in the snapshot unless linked), and "O" means open. Producer-side coverage is in EP-159.

| Source | Local isolated restore | Cloud isolated restore | Native tamper refusal | Wrong-incarnation destination | Interruption recovery | Source-unavailable drill |
|---|---|---|---|---|---|---|
| PostgreSQL | M | I [sgcs], [hist], [mgcs] | O (I in tests: corrupt/missing generation) | O | I model (pilot); M native partial `COPY` | I [supg] |
| Redis | I [local] | I [cloud] | O | M adapter test; native O | M destination-created only; mid-RDB-load O | I [sueng] |
| ClickHouse | I [local] | I [cloud] (F22 repaired) | O | O | I native terminal failure and abandon [chterm]; M lost acknowledgement; real partial effect O | I [sueng] |
| Volume (new PVC) | I [local] | I [vol] | O (M native unsafe-archive refusal) | M adapter test; native O | M at destination creation, mid-extraction and lost verification acknowledgement | I [sueng] |

Evidence keys: [sgcs] [scheduled GCS restore](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/scheduled-gcs-restore-76628094.json); [hist] [historical receipt restore](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json); [mgcs] [manual GCS recovery](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); [local] [local engine and volume recovery](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json); [cloud] [cloud engine recovery](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json); [vol] [cloud volume recovery](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json); [chterm] [ClickHouse terminal recovery](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json); [supg] [PostgreSQL source-unavailable](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/source-unavailable-content-ec2e1cd4.json); [sueng] [engines and volume source-unavailable](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/source-unavailable-engines-e6255e6f.json). The model and pilot evidence is the narrative in [the independent verification](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-verification-2026-10-02.md). Independent evidence spans candidates `76628094`, `ec2e1cd4` and `e6255e6f`, so none of it is final-candidate acceptance yet. Volume content is bound to accepted archive hashes; observed generations are not accepted provider-version pins.

## Surprises & Discoveries

2026-10-03 (C2 limitation, candidate `db808a74`): `storage snapshot` and `storage restore` load the config with the `Deployment` emitter. An `Application` config, like the scenario fixture's `apps/scenario-a`, is refused with "config emitted a 'Application' but 'Deployment' was expected", even though `app deploy` accepts it. The C2 volume check used a projection of the fixture config that calls `emitDeployment` on the application's service; the projection is archived with the evidence (`checks/volume-backup-restore/projection-Config.hs`). The restore itself passed: the Job's manifest line proved `scenario-known.txt` at its seeded SHA-256 while the source kept a later change. Open limitation: the storage commands should accept the same Application configs as `app deploy`.

2026-10-03 (resolved in `fc8cba5b`; see Progress): Volume snapshot restores pinned no object version, unlike scheduled database receipts. Planning reads only the completed snapshot Pod's receipt, and the restore Job compares the current archive and receipt hashes with the accepted checksum. So a tampered volume archive is caught only after the scratch PVC is created (no data is extracted), and the transaction then needs `abandon-partial-volume-restore`, which leaves an unresolved PVC. Meeting this plan's "refuses before any destination write" for volumes needs planning-time verification of the exact object versions, and pinned versions in the restore Job, mirroring the scheduled database path. A native drill was not run, to avoid leaving an unresolved PVC on cp3.

Earlier discoveries, including the full data-fence design findings, are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md).

2026-10-02 (F22, Closed): After a successful native ClickHouse `RESTORE`, the immediate existence query can hit a transient connection refusal. The Job then failed terminally even though the data was correct. The fix runs at most six bounded read-only verification attempts and keeps `RESTORE` outside the loop. A restore is never replayed after terminal failure; recovery is digest-bound abandonment.

2026-10-02 (F19, Closed): The rendered GCS download omitted `OBJECT_VERSION` and `RECEIPT_VERSION`. A recording adapter that marks Jobs complete cannot catch this kind of defect. The public fixtures now execute the actual rendered download script against strict recorders.

2026-10-02: The first cloud Redis seed omitted authentication. Redis returned `NOAUTH` with exit status zero, so that backup was empty and is excluded from content claims. Always verify the seeded value before backup.

2026-09-28: Killing the ClickHouse client during `RESTORE DATABASE` did not stop the server, which completed the full restore. A failed Job is therefore not proof of a partial effect, and the client kill only exercised lost acknowledgement. A genuinely partial ClickHouse effect still needs a different injection point.

2026-09-28: Kubernetes omits defaulted fields such as `volumeMount.readOnly: false`, `hostAliases: null` and `volumes: []` from observed objects. Observers must accept only those exact omitted defaults; anything broader would hide real drift.

2026-09-26: The legacy ClickHouse backup concatenated `FORMAT Native` streams without table identity, and the legacy Redis restore piped an RDB file through `redis-cli --pipe`. Neither could restore data. Restores now use ClickHouse's `BACKUP DATABASE … TO File` ZIP and an offline RDB load into a separate Redis instance.

2026-09-26/27 (M1): A `ReadWriteOnce` claim admitted a second Pod on the same node. Namespace deletion bypassed a PVC-only guard. ValidatingAdmissionPolicies cannot protect their own policy objects. Engine shutdown commands and settings such as `default_transaction_read_only` and `CLIENT PAUSE` do not by themselves prove exclusion. These findings shaped the fence and remain constraints on any future live-restore work.

## Decision Log

In-force decisions, condensed. Full verbatim entries are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md).

2026-10-03 (B2 volume pins): Volume restores now verify and pin the exact stored objects at planning, as scheduled database restores do. Planning refuses unless the current receipt equals the accepted snapshot Pod receipt and the current archive hashes to the receipt's checksum, each confirmed by a re-read at the exact version. A tampered snapshot is refused rather than restored from an older verified version, because silently skipping a newer object would hide the tampering. The restore Job downloads the pinned versions (MinIO `get-object --version-id` with a VersionId assertion, GCS `URL#GENERATION`). A pinned Job prints `NAGARE_VOLUME_RESTORE_FILE`/`NAGARE_VOLUME_RESTORE_MANIFEST` lines after extraction, so smoke checks can read restored content without mounting the scratch claim. Unpinned rendering keeps its original bytes, so earlier saved reviews stay valid.

2026-10-02 (consolidation): Rewrite this plan as a current-state document aligned with MP-23, rename the title to match the registry, and drop live-overwrite obligations that the 2026-09-28 reduction deferred. M1 stays accepted. No other acceptance changes.

2026-10-02: Production data requires MP-23's data-protection gate, including verified restored content, a documented and timed recovery procedure, and credentials recoverable without the original cluster or operator root. Recovery-time targets are D4. Any route back to service after an isolated restore is a documented operator step, not automatic cutover.

2026-10-02: Before another native candidate, extend the production compiler, adapter and driver path with an effectful model scenario for each affected restore behavior (`just test-inventory-effects`). Generated scripts are executed against strict local tools. Synthetic Job completion never counts as content proof.

2026-10-02: A restore from an accepted receipt verifies against that receipt's immutable accepted digest and exact versions, not against the current schedule or signing policy.

2026-09-28 (operator-approved reduction): M2 and M3 are narrowed to isolated database destinations and new-PVC recovery. Live overwrite and automatic promotion are deferred, and new admission is refused at every entrypoint (EP-153 owns the guard). Admitted live fences and live restores keep their recovery decisions. A historical review must never be turned into a new live restore.

2026-09-28: A terminally failed restore Job is closed with `abandon-partial-database-restore` or `abandon-partial-volume-restore`. Each requires the exact saved review and adapter-proved terminal failure, and neither ever accepts the partial destination. Recovery is a fresh restore ID and destination. The failed Job and destination are kept for separate reviewed cleanup.

2026-09-27: M1 is bounded by six criteria: reviewed production integration, observed local writer exclusion, a concrete authority boundary, durable failure and recovery, real verification before release, and reviewable evidence. Cloud fence integration belongs to EP-156. Cluster administrators are trusted. Apply always uses the saved private fence record and never recaptures it. Nagare never uses GKE.

2026-09-26: Engine formats: ClickHouse uses its native database ZIP, Redis uses an offline RDB load into a separate instance, and older content-only ClickHouse receipts are refused for reviewed restore.

2026-09-26: This plan took over an unfinished outcome of [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Delivered behavior is preserved.

## Outcomes & Retrospective

**Status (2026-10-09): Complete.** v0.4.0 (`83124396`) ships verified isolated restore for PostgreSQL, Redis and ClickHouse and new-PVC volume restore, from manual and scheduled receipts on MinIO and GCS.
- **Refusals.** A changed archive and a wrong-incarnation destination are refused. Live overwrite stays deferred, and recovery of already-admitted fences is preserved.
- **Proof.** C2 and C3 re-proved every engine and the volume path on the final candidate. Checklist section 2 drilled restore after total cluster loss, timed at 20 s.
- **Moved.** Recovery-time targets (D4) are an unmet production target in the release notes. Rebuilding in place with live service is the next MasterPlan's work, as the checklist records.
- **Open limitation, no owner yet.** `storage snapshot` and `storage restore` still refuse `Application` configs. C2 on `83124396` again used the archived `projection-Config.hs` (Surprises, 2026-10-03).
- **Lesson.** Wrong-incarnation races are cheap to stage inside a scenario run. Running them there, beside the content checks, turned F35 from a cp3 one-off into evidence on the final candidate.

Earlier, as of 2026-10-02: the shared data fence (M1) is accepted, and live overwrite is deferred with recovery preserved. Every engine and the volume path has independent native isolated-restore evidence in the cloud, and every one except PostgreSQL has it locally; all have independent source-unavailable content drills. Remaining: native tamper and wrong-incarnation refusal, the Redis-load and partial-ClickHouse interruption cases (or an accepted coverage argument), the manual-cloud-receipt statement, independent local PostgreSQL, and final-candidate binding. M2 and M3 stay open until those pass.

Lesson: the plan kept live-overwrite requirements and "F19/F22 open" statements long after the scope reduction and the independent closures, which made the remaining work look larger and different from what it was. Reconcile Progress against the findings tracker at every handoff.

