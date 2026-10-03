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
---

# Complete verified isolated database and volume restore

This ExecPlan is a living document under [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02: the earlier dated checkpoints (including the full M1 data-fence construction history, native probe identifiers and the retired live-overwrite experiments) are preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file. The file slug predates the current title and is kept so existing links resolve.


## Purpose / Big Picture

After this plan, a Nagare operator can take an accepted backup of a PostgreSQL, Redis or ClickHouse database, or an accepted snapshot of an application volume, and restore it into a new isolated destination through one reviewed command. The destination is a distinct scratch database, a separate Redis instance, or a new PersistentVolumeClaim (PVC). The restore verifies the exact archive bytes and the known content before reporting success. The live source keeps running unchanged, and an interrupted restore can be resumed or explicitly abandoned without replaying a destructive step. This is the recovery path the company intranet needs before real data is admitted: a backup that has never been restored and checked is not evidence of recoverability.

Scope follows MP-23's supported release contract. Required: verified isolated restore for all three engines, volume restore to a new PVC, and the source preserved. Deferred: overwriting a live database or PVC, and automatic promotion or cutover. The `--into-live` routes refuse new admission. Live fences and live restores admitted before the 2026-09-28 reduction must remain recoverable through their recorded identity. Pointing an application at a restored destination is a separate, documented operator step, not part of this plan. Recovery-time targets are operator decision D4 in MP-23 and are not decided here.

To see it working, follow the public path in Concrete Steps. Back up a disposable database, change the source, restore with `db restore NAME BACKUP_ID --restore-id ID --save-plan DIR`, apply the review, and query the new destination. It returns the backed-up rows while the source still returns its changed rows.


## Progress

- [x] M1 — shared data fence accepted (2026-09-27). The fence is bound to saved reviews. On local k3s it proved writer exclusion for StatefulSet, Deployment, CronJob and active-Job writers; a fail-closed mount and route guard; exact-name and collection-delete guard authority; and durable interruption and recovery. Release happens only after real readback. Evidence: saved review `ec327465…` on disposable k3d `ep160-ex-23315` (30 fence tests), cross-engine mounted-Job exclusion on `ep160-ex-64754`, and the full 892-test suite at the acceptance boundary (implementer, snapshot). Recovery of already-admitted fences is preserved: ordinary resume refuses with `active-data-fence`, and the explicit decisions `continue-fenced-operation`, `verify-fenced-effect`, `recover-fenced-backup` and `forward-fenced-release` remain. Native terminal-loss and failed-SQL recovery of an admitted PostgreSQL live restore were shown locally on 2026-09-27 (implementer, snapshot).
- [x] Live overwrite deferred (2026-09-28; source confirmed at consolidation). `db restore --into-live` and `storage restore --into-live` refuse at the command, and a saved `RestoreLiveDatabase` review refuses admission with `deferred-operation` (`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`). `scripts/audit-managed-commands.py` and `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs` pin exactly these deferred routes.
- [x] Cloud isolated restore for all three engines from accepted GCS receipts (2026-10-02, independent). PostgreSQL: scheduled ([76628094](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-restore-76628094.json)), historical receipt after a schedule change ([ec2e1cd4](../audits/mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json)), and manual with the producer collected ([e6255e6f](../audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); F19 Closed). Redis and ClickHouse use authenticated known content with the source changed afterwards ([e6255e6f](../audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json)). The repaired ClickHouse consumer survives the transient post-RESTORE refusal (F22 Closed). Source and neighbor rows and UIDs were preserved in every run.
- [x] Local isolated restore for Redis, ClickHouse and a new PVC (2026-10-02, independent). The producers had been removed and the source was changed after backup; Redis and ClickHouse restored only the backed-up content, and the volume restore read the original SHA-256 from a distinct scratch PVC ([ec2e1cd4](../audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)). Local PostgreSQL isolated restore is implementer-only (2026-09-27/28, snapshot).
- [x] Cloud new-PVC volume restore (2026-10-02, independent): a manual GCS snapshot restored into a scratch PVC, verified read-only with the source Pod and PVC intact ([proof](../audits/mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json)).
- [x] Source-unavailable content drills for all engines and the volume (2026-10-02, independent). A fresh operator root with source Kubernetes access denied fetched accepted history and exact generations from GCS and restored known content into isolated containers ([PostgreSQL](../audits/mp23-independent-results-2026-10-02/source-unavailable-content-ec2e1cd4.json), [Redis/ClickHouse/volume](../audits/mp23-independent-results-2026-10-02/source-unavailable-engines-e6255e6f.json)). Separately encrypted credentials were decrypted from the fresh root ([credentials](../audits/mp23-independent-results-2026-10-02/encrypted-credential-recovery-ec2e1cd4.json)). Limits: these were manual drills, not a public command after a real outage, and no recovery time was recorded.
- [x] Interruption handling (mixed evidence; see the matrix). Independent: the six-scenario effectful restore pilot inside the 47-scenario `just test-inventory-effects` run covers lost write acknowledgement, failure before write, readiness timeout, changed source, and corrupt or missing download generations. Also independent: native ClickHouse terminal failure followed by explicit digest-bound abandonment ([ec2e1cd4](../audits/mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json)). Implementer native (2026-09-28): PostgreSQL partial `COPY` abandoned and restored fresh; ClickHouse lost acknowledgement; Redis destination-created resume; volume interruption at destination creation, mid-extraction and lost verification acknowledgement.
- [ ] Native refusal of a tampered accepted backup. For a database receipt and a volume snapshot whose stored bytes or object version/generation changed after acceptance, the restore refuses before any destination write, and history is unchanged. (MP-23 B2) Database part done natively (2026-10-03, implementer, cp3): a newer MinIO version at accepted Redis receipt `0841cd1d…`'s archive key made restore planning refuse with `accepted scheduled backup object version or bytes changed`. No review was saved, the store head was unchanged, the listing showed the receipt unresolved, and deleting exactly that version restored it ([record](../audits/mp23-implementer-results-2026-10-03/cp3-data-drills.json)). A review saved before such a tamper still downloads the pinned versions, which is correct. Volume part open: see Surprises (2026-10-03).
- [ ] Native refusal of a wrong-incarnation destination. A pre-existing or substituted destination (scratch database, Redis StatefulSet/PVC, or scratch PVC with a foreign UID) refuses at preflight and at execution with zero writes. (MP-23 B2) Native results (2026-10-03, implementer, cp3; [record](../audits/mp23-implementer-results-2026-10-03/cp3-data-drills.json)): a foreign PVC at the Redis scratch address before planning is refused with `adoption-required`, with no review saved. A foreign PVC created between plan and apply is refused at that operation's preflight, and the foreign object is untouched. But the earlier Service create had already run, and the transaction stayed active with no supported exit. That is [F35](../audits/mp23-findings.md#f35). It is resolved by removing the foreign object and resuming; the restore then converged in 31 s. This item closes only once F35 is repaired and the race is re-run.
- [ ] Redis interruption during RDB load in the init container, and a ClickHouse restore with a genuinely partial data effect, each recovered without replay. Alternatively, a recorded argument, accepted by the independent reviewer, that the existing runs cover these cases. (MP-23 B2)
- [ ] Manual cloud receipts for Redis and ClickHouse proved through restore (MP-23 B2). Decided 2026-10-03: prove them inside EP-156's bounded C3 sequence rather than narrowing the contract to scheduled-only.
- [ ] Independent local PostgreSQL isolated restore with known content and source preserved. (MP-23 C2)
- [ ] All of the above re-proved on the one frozen candidate in the EP-155 local and EP-156 cloud scenarios. (MP-23 C2, C3)
- [ ] For the data-protection gate (production use, not MP-23 completion): a documented, timed recovery procedure after source-cluster loss, measured against recovery-time targets once D4 sets them.


## Coverage Matrix

Status per engine and path. "I" means independently proved on a native system, "M" means implementer evidence only (in the snapshot unless linked), and "O" means open. Producer-side coverage is in EP-159.

| Source | Local isolated restore | Cloud isolated restore | Native tamper refusal | Wrong-incarnation destination | Interruption recovery | Source-unavailable drill |
|---|---|---|---|---|---|---|
| PostgreSQL | M | I [sgcs], [hist], [mgcs] | O (I in tests: corrupt/missing generation) | O | I model (pilot); M native partial `COPY` | I [supg] |
| Redis | I [local] | I [cloud] | O | M adapter test; native O | M destination-created only; mid-RDB-load O | I [sueng] |
| ClickHouse | I [local] | I [cloud] (F22 repaired) | O | O | I native terminal failure and abandon [chterm]; M lost acknowledgement; real partial effect O | I [sueng] |
| Volume (new PVC) | I [local] | I [vol] | O (M native unsafe-archive refusal) | M adapter test; native O | M at destination creation, mid-extraction and lost verification acknowledgement | I [sueng] |

Evidence keys: [sgcs] [scheduled GCS restore](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-restore-76628094.json); [hist] [historical receipt restore](../audits/mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json); [mgcs] [manual GCS recovery](../audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); [local] [local engine and volume recovery](../audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json); [cloud] [cloud engine recovery](../audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json); [vol] [cloud volume recovery](../audits/mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json); [chterm] [ClickHouse terminal recovery](../audits/mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json); [supg] [PostgreSQL source-unavailable](../audits/mp23-independent-results-2026-10-02/source-unavailable-content-ec2e1cd4.json); [sueng] [engines and volume source-unavailable](../audits/mp23-independent-results-2026-10-02/source-unavailable-engines-e6255e6f.json). The model and pilot evidence is the narrative in [the independent verification](../audits/mp23-independent-verification-2026-10-02.md). Independent evidence spans candidates `76628094`, `ec2e1cd4` and `e6255e6f`, so none of it is final-candidate acceptance yet. Volume content is bound to accepted archive hashes; observed generations are not accepted provider-version pins.


## Surprises & Discoveries

2026-10-03: Volume snapshot restores pin no object version, unlike scheduled database receipts. Planning reads only the completed snapshot Pod's receipt, and the restore Job compares the current archive and receipt hashes with the accepted checksum. So a tampered volume archive is caught only after the scratch PVC is created (no data is extracted), and the transaction then needs `abandon-partial-volume-restore`, which leaves an unresolved PVC. Meeting this plan's "refuses before any destination write" for volumes needs planning-time verification of the exact object versions, and pinned versions in the restore Job, mirroring the scheduled database path. A native drill was not run, to avoid leaving an unresolved PVC on cp3.

Earlier discoveries, including the full data-fence design findings, are in [the snapshot](../audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md).

2026-10-02 (F22, Closed): After a successful native ClickHouse `RESTORE`, the immediate existence query can hit a transient connection refusal. The Job then failed terminally even though the data was correct. The fix runs at most six bounded read-only verification attempts and keeps `RESTORE` outside the loop. A restore is never replayed after terminal failure; recovery is digest-bound abandonment.

2026-10-02 (F19, Closed): The rendered GCS download omitted `OBJECT_VERSION` and `RECEIPT_VERSION`. A recording adapter that marks Jobs complete cannot catch this kind of defect. The public fixtures now execute the actual rendered download script against strict recorders.

2026-10-02: The first cloud Redis seed omitted authentication. Redis returned `NOAUTH` with exit status zero, so that backup was empty and is excluded from content claims. Always verify the seeded value before backup.

2026-09-28: Killing the ClickHouse client during `RESTORE DATABASE` did not stop the server, which completed the full restore. A failed Job is therefore not proof of a partial effect, and the client kill only exercised lost acknowledgement. A genuinely partial ClickHouse effect still needs a different injection point.

2026-09-28: Kubernetes omits defaulted fields such as `volumeMount.readOnly: false`, `hostAliases: null` and `volumes: []` from observed objects. Observers must accept only those exact omitted defaults; anything broader would hide real drift.

2026-09-26: The legacy ClickHouse backup concatenated `FORMAT Native` streams without table identity, and the legacy Redis restore piped an RDB file through `redis-cli --pipe`. Neither could restore data. Restores now use ClickHouse's `BACKUP DATABASE … TO File` ZIP and an offline RDB load into a separate Redis instance.

2026-09-26/27 (M1): A `ReadWriteOnce` claim admitted a second Pod on the same node. Namespace deletion bypassed a PVC-only guard. ValidatingAdmissionPolicies cannot protect their own policy objects. Engine shutdown commands and settings such as `default_transaction_read_only` and `CLIENT PAUSE` do not by themselves prove exclusion. These findings shaped the fence and remain constraints on any future live-restore work.


## Decision Log

In-force decisions, condensed. Full verbatim entries are in [the snapshot](../audits/mp23-archive/plan-history/ep160-before-consolidation-2026-10-02.md).

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

Achieved as of 2026-10-02: the shared data fence (M1) is accepted, and live overwrite is deferred with recovery preserved. Every engine and the volume path has independent native isolated-restore evidence in the cloud, and every one except PostgreSQL has it locally; all have independent source-unavailable content drills. Remaining: native tamper and wrong-incarnation refusal, the Redis-load and partial-ClickHouse interruption cases (or an accepted coverage argument), the manual-cloud-receipt statement, independent local PostgreSQL, and final-candidate binding. M2 and M3 stay open until those pass.

Lesson: the plan kept live-overwrite requirements and "F19/F22 open" statements long after the scope reduction and the independent closures, which made the remaining work look larger and different from what it was. Reconcile Progress against the findings tracker at every handoff.


## Context and Orientation

An *isolated destination* is a newly declared target that cannot be the source: a scratch PostgreSQL or ClickHouse database with a reviewed name, a separate Redis Service/StatefulSet/PVC, or a new PVC. A *receipt* is the signed record of one backup's exact object and checksum; it is *accepted* once a reviewed scope has pinned its exact object versions (MinIO) or generations (GCS). EP-159 produces accepted scheduled receipts, and manual backups produce `verified-v1` receipts. PostgreSQL and ClickHouse scratch databases are created on the source's own database server under a distinct reviewed name, so the source server keeps serving throughout; Redis restores into a separate Service, StatefulSet and PVC. A *wrong-incarnation* destination is one whose physical identity (Kubernetes UID) differs from what the review declared or observed. A *data fence* (M1) is durable state in the inventory head, plus observed Kubernetes controls, that stops every writer to a live target during a live-data operation. In this release it protects only operations admitted before the reduction. A *review*, *scope* and *journal* are as in EP-159: an immutable saved plan, one owner's declared resources, and the private execution record.

The public restore planner is in `cli/nagarectl/app/Nagare/Cli/Data/Restore.hs`, reached from `cli/nagarectl/app/Nagare/Cli/Commands/Database.hs` (`db restore`) and `cli/nagarectl/app/Nagare/Cli/Commands/Storage.hs` (`storage restore`). Scopes are compiled by `compileManualRestoreScope` and `compileVolumeRestoreScope` in `cli/nagarectl/src/Nagare/Inventory/Restore.hs`. The native Jobs are rendered by `cli/nagarectl/src/Nagare/Database/Restore.hs` and `cli/nagarectl/src/Nagare/Storage/Restore.hs`. UID and receipt checks are enforced by `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs` and `KubernetesRuntime.hs`. Recovery decisions are parsed in `cli/nagarectl/src/Nagare/Inventory/Execute/Types.hs`, and deferred admission is refused in `Execute/Admission.hs`. The M1 fence is `cli/nagarectl/src/Nagare/Inventory/DataFence.hs` and `cli/nagarectl/src/Nagare/Inventory/DataFence/`. The retained live-restore recovery code is `cli/nagarectl/src/Nagare/Inventory/LiveRestore*.hs`. Supported engines are declared in `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`. Tests: `cli/nagarectl/test/DataFenceSpec.hs`, `cli/nagarectl/test/InventoryEffectfulSpec.hs` (restore pilot) and `cli/nagarectl/test/Nagare/Test/Backup/Restore.hs`. Native fence probes: `scripts/probe-ep160-native-exclusion.sh` and `scripts/probe-ep160-engine-shutdown.sh`.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires exact reviewed effects, separate desired, observed and historical state, and retained data by default, and it records the scope reduction. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) forbids pretending a data change has automatic rollback; that is why partial restores are abandoned rather than undone. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history out of payloads, and [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) guards every cloud path. Supported targets are local k3d/k3s (Colima profile `nagare-mp23-cp3`, one check at a time) and k3s on a NixOS VM in Compute Engine, never GKE.


## Plan of Work

**M1 — Shared data fence (accepted).** No further work. Keep its regressions green, and keep admitted-fence recovery reachable while new live admission is refused.

**M2 — Isolated database restore.** The normal path is proved for all three engines. To finish, first add native tamper refusal. In a disposable context, accept a receipt, then replace the stored object with different bytes at the same key. For MinIO, write a new version; for GCS, write a new generation, cloud only with the operator's go-ahead. Show that `db restore` refuses at planning or in the download container before the destination is created, with history unchanged. Second, add native wrong-incarnation refusal. Pre-create a destination with the reviewed name but a foreign UID between planning and apply, and show that both preflight and execution refuse with zero writes. Third, for Redis, kill the init container mid-load, then show that resume or abandonment never accepts a half-loaded instance. For ClickHouse, find an injection point that leaves a genuinely partial scratch database without disturbing the source server, which hosts the scratch database; killing only the client is known not to work. If either case is impractical, write the coverage argument in Decision Log and have the independent reviewer accept or reject it. Fourth, either prove manual cloud receipts for Redis and ClickHouse or state scheduled-only coverage in the user docs and the coverage catalogue.

**M3 — New-PVC volume restore.** The normal and interruption paths are proved. To finish, add native tamper refusal (a changed snapshot archive object) and native wrong-incarnation refusal (a foreign scratch PVC). Do not add live PVC overwrite or mount cutover.

For each new behavior, first add an effectful model scenario on the production path, then run the native check.


## Concrete Steps

Run from the repository root. A test pattern must select at least one test.

```bash
just test-inventory-effects
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p restore' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p "data fence"' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p incarnation' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
python3 scripts/audit-managed-commands.py
```

Public path against an explicitly selected disposable context:

```bash
nagarectl db restore "$DB" "$BACKUP_ID" --restore-id "$RID" --save-plan "$REVIEW"
nagarectl inventory apply "$REVIEW" --yes
nagarectl storage restore "$APP" "$VOLUME" "$SNAPSHOT_ID" --restore-id "$RID" --save-plan "$VOLUME_REVIEW"
nagarectl inventory apply "$VOLUME_REVIEW" --yes
nagarectl db restore "$DB" "$BACKUP_ID" --into-live --restore-id "$RID" --save-plan "$UNUSED_DIR"   # must refuse before any review
```

To recover an interrupted restore, resume the original transaction. If its Job failed terminally, use an exact decision file instead:

```json
{"version":1,"transaction":"tx-…","operation":"op-…","review":"<review digest>","action":"abandon-partial-database-restore"}
```

```bash
nagarectl inventory resume "$TRANSACTION" --yes
nagarectl inventory recover "$TRANSACTION" --operation "$OPERATION" --decision "$DECISION_FILE"
```

At a milestone boundary, also run the full suite, `just haskell-style-check` and, if docs changed, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`, one after another.


## Validation and Acceptance

M2 and M3 are accepted when, on one candidate, each engine and the volume path shows the following. Seed known content and back it up. Change the source, then restore into a reviewed isolated destination. The destination matches the backup while the source keeps its changed content and identity, and unrelated scope revisions stay fixed. Both manual and scheduled receipts must be exercised, or scheduled-only coverage must be stated, as the B2 item requires. Tampered archives, wrong-incarnation destinations, and missing or foreign receipts must refuse natively before destination writes. Interruption at destination creation, during restoration, and before recorded verification must recover or abandon from a fresh process without destructive replay. A zero exit code without a content query does not count. New `--into-live` admission must refuse at every route, and an admitted-fence recovery regression must still pass. Record the candidate revision, review and transaction IDs, source and destination UIDs, and the content observations.


## Idempotence and Recovery

Reviews are immutable, and a review whose Job already completed replays as verification only. Use a fresh restore ID and destination for every new attempt; never resume extraction or loading into a destination that was abandoned. Unknown provider results stay unresolved until observed. No blind replay, history reset, raw patch or source deletion is allowed. Failed destinations are retired through a separate reviewed change. Cloud mutations need the operator's go-ahead as one rehearsed, bounded sequence. Use `mori` for dependency sources, and never search `/nix/store`.


## Interfaces and Dependencies

Prerequisites [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md) and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) are complete. [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) produces the receipts this plan consumes, and manual receipts let restore work proceed independently. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns the deferred-route guards. EP-161 is Cancelled; its already-recorded maintenance sessions and fences stay recoverable, but no new maintenance consumer is needed. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) re-prove restore on the frozen candidate, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) assembles the evidence. Stable public interfaces: `db restore NAME BACKUP_ID --restore-id ID --save-plan DIR`, `storage restore APP VOLUME SNAPSHOT_ID --restore-id ID --save-plan DIR`, and the `inventory recover` decisions `abandon-partial-database-restore`, `abandon-partial-volume-restore`, `accept-adapter-proof` and the four fenced-operation decisions listed under M1.


## Revision Notes

2026-10-02: Consolidated with MP-23; title aligned with registry; history in the snapshot.
