---
id: 159
slug: complete-scheduled-backup-receipts-and-exact-retention-pruning
title: "Complete scheduled receipts and explicit retention limits"
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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T23:06:33Z
      mode: "implement"
      note: "Prove second independent PostgreSQL scheduled receipt after Job cleanup and its real scratch restore consumer"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:36:18Z
      mode: "implement"
      note: "Expose unenforced scheduled retention in public receipt and status views"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T15:00:50Z
      mode: "update"
      note: "Revise command-boundary repair work from retained append, history, recovery, and public CLI experiments"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T05:55:39Z
      mode: "implement"
      note: "Record local manual receipt and Job-free restore checkpoint"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T19:17:04Z
      mode: "implement"
      note: "Enable exact-generation GCS scheduled receipt inspection and reviewed ingestion; retain native acceptance gaps"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:06:56Z
      mode: "implement"
      note: "Correct stale GCS ingestion statement in backups guide (B1)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T13:56:59Z
      mode: "implement"
      note: "D1 pending-upload freshness and signing-key escrow, D6 configurable objective, D2 volume scope"
---

# Complete scheduled receipts and explicit retention limits

This ExecPlan is a living document under [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02: the earlier dated checkpoints, transaction and object identifiers, and full decision history are preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep159-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file. The file slug predates the current title and is kept so existing links resolve.


## Purpose / Big Picture

After this plan, a Nagare operator can rely on scheduled database backups as firmly as on manual ones. Every automatic run of a reviewed backup schedule writes exactly one immutable archive and one signed receipt to off-cluster object storage — MinIO for local contexts, Google Cloud Storage (GCS) for cloud contexts. The operator can list those runs after Kubernetes has deleted the producing Job, accept one into inventory history through a reviewed change, and later restore exactly that accepted archive (restore is [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md)). The operator can also ask how old the newest accepted recovery point is, and is told plainly that scheduled backups are kept indefinitely because keep-N pruning and expiry are not enforced in this release.

This matters because the operator intends to host critical company intranet tooling on Nagare. MP-23's data-protection gate, which governs production use and is separate from MP-23 completion, requires off-cluster backups that meet a one-hour recovery-point objective (RPO) after total cluster loss. The RPO is the maximum tolerated data loss, measured from the latest usable off-cluster recovery point and including upload, verification and retry delays. This plan supplies the producer side and the freshness measurement. Three questions are pending operator decisions in MP-23 and are not decided here: D1, whether and how the RPO must hold without an operator accepting receipts; D2, whether volumes get a scheduled producer or are scoped out of the RPO; and D4, the recovery-time and retention targets.

Scope follows MP-23's supported release contract. Required: native backup formats, exact verified manual and scheduled receipts, survival after Job cleanup, and real MinIO (local) and GCS (cloud) proof. Deferred: scheduled keep-N pruning and automatic expiry. Retention must be visibly reported as unenforced, new scheduled-prune admission must refuse before any effect, and partial prunes admitted before the reduction must stay recoverable.


## Progress

- [x] Signed, identity-bound scheduled producer (2026-10-02). New reviewed schedules run every 15 minutes and write a create-only object keyed by the Job's controller UID. They publish a version-5 receipt only after stored-byte readback; the receipt is HMAC-signed and binds source StatefulSet/PVC UIDs plus a timestamp taken before the dump. A reviewed `db disable-backup-prune` transition moves accepted signed-v4 daily schedules to v5 and changes only the CronJob. Independent: the local gate at `76628094` updates exactly the two platform CronJobs ([local proof](../audits/mp23-independent-results-2026-10-02/local-platform-candidate-76628094.json)), and cloud review `e7c04597…` at `ec2e1cd4` contains one CronJob Update ([v5 proof](../audits/mp23-independent-results-2026-10-02/scheduled-v5-freshness-ec2e1cd4.json)).
- [x] Reviewed ingestion after Job cleanup on MinIO and GCS (2026-10-02). `db backup-receipts NAME --backup-id ID --save-plan DIR` rereads exact object versions or generations, checks receipt authentication and archive hashes, and adds one independent scope. Independent: GCS ingestion with the producer Job and Pod removed, an unchanged review digest, and 26 prior revisions preserved ([a027d1f6](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-ingestion-a027d1f6.json)). Local Redis and ClickHouse ingestion after producer removal ([ec2e1cd4](../audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)). Cloud Redis and ClickHouse ([e6255e6f](../audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json)).
- [x] Historical accepted receipts stay valid after a schedule change (2026-10-02). They are verified against their immutable accepted digest, not the current CronJob metadata. Independent: an accepted v4 receipt restores after the v5 policy update, while unaccepted old-schedule runs stay unresolved ([proof](../audits/mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json)).
- [x] Genuine automatic run and freshness check (2026-10-02). The CronJob controller fired at 20:15:00Z, and `--check-freshness` exited 1 while the run was unaccepted, then 0 with `healthy; age=646s` after reviewed acceptance ([proof](../audits/mp23-independent-results-2026-10-02/scheduled-v5-freshness-ec2e1cd4.json), which records `automaticIngestionClaimed: false`). Local Redis/ClickHouse reported healthy at 515s. Cloud Redis warned at 1806s while a newer verified upload was still awaiting acceptance.
- [x] Interrupted upload cannot appear recoverable (2026-10-02, tests). A failed stored-byte readback yields no receipt, and a retry refuses to overwrite the orphan object ([independent regression](../audits/mp23-independent-results-2026-10-02/interrupted-upload-regression.txt)). Exact-generation verification rejects changed bytes, foreign identity and invalid HMAC ([independent tests](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-tests.txt)). Native orphan objects are listed as unresolved (implementer, 2026-09-27, snapshot).
- [x] Manual receipt compatibility (2026-10-02). A `verified-v1` manual receipt record pins the completed Job, producer revision and exact provider versions, so the Job can be collected separately. Independent: a producer-free GCS restore after reviewed collection ([e6255e6f](../audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); F19 Closed).
- [x] Retention boundary and deferred pruning (2026-10-02). `db backup-receipts` prints `keep=N and expiry are unenforced; backups are retained by default`. New `db prune-scheduled-backups` admission refuses before effects (independent, [operation driver](../audits/mp23-independent-results-2026-10-02/operation-driver-e6255e6f.json)). Recovery of an already-admitted partial prune (`abandon-partial-prune`, `db recover-scheduled-prune`) was proved natively on local MinIO by the implementer (2026-09-28, snapshot). F09 is Closed against the supported contract ([boundary](../audits/mp23-independent-results-2026-10-02/invalid-retained-source-e6255e6f.json)).
- [x] Recovery-point objective holds unattended (2026-10-03, implementer, D1). Verified uploads awaiting ingestion now count toward freshness after their exact bytes, HMAC and current source UIDs are rechecked, and output names a pending newest point. Accepted receipts remain the only restore authority. Native read-only run on cp3 with the development binary: all five `recovery point` rows in `server status` changed from breached or no-point to `healthy; age≈330s; objective=hourly; newest point is verified and awaits reviewed ingestion`. Independent verification and final-candidate proof (C2, C3) remain. (MP-23 B1)
- [x] Signing-key escrow and offline verification (2026-10-03, implementer, D1). `db escrow-signing-key` writes a create-only, sops-encrypted escrow bound to the observed Secret/StatefulSet/PVC UIDs; plaintext only on stdin, round-trip decryption checked, rerun is a no-op, a different escrow refuses. `db verify-escrowed-backup` verifies a receipt and archive with only the escrow and the object store. Native on cp3 (scratch escrow, temporary age key): escrow written mode 0600 with every value encrypted; rerun no-op; Redis backup `ff82815f…` verified with exact MinIO versions and its recovery point; the wrong database and an absent backup refused. Three pure tests. Independent verification and a GCS-backed check (C3) remain.
- [x] Configurable objective (2026-10-03, implementer, D6). `NAGARE_BACKUP_RECOVERY_POINT=hourly|daily` per context; the preset sets the CronJob cadence and is written into the signed receipt metadata (hourly bytes unchanged), and freshness grades against the accepted CronJob's objective. `db disable-backup-prune` treats the other preset's current schedule as a known earlier schedule, so a change is a CronJob-only review. Tests: daily thresholds, schedule/metadata binding and cadence refusal, hourly↔daily transition. A native daily-schedule review on a candidate remains (C2).
- [x] Freshness appears on an operational surface (2026-10-02). `server status` and `doctor` report the `BackupFreshness` result (warning at 30 minutes, unhealthy at one hour) instead of the old object-timestamp probe. Each accepted scheduled database backup gets a `recovery point` row from `scheduledReceiptReport`, the same verifier as `db backup-receipts`; unobservable sources are UNKNOWN; doctor gives an ingestion remediation. Native read-only run on cp3: five rows, two breached at ~28,200 s and three with no verified timestamped point. That is the D1 gap, now visible. 1,133 tests pass. (MP-23 B1)
- [x] Volume recovery-point bound settled under D2 (2026-10-03): volumes are outside the objective; `docs/user/backups-and-disaster-recovery.md` states it, status does not grade volumes, and EP-157 reports it as an unmet production target. (MP-23 B1, D2)
- [ ] Source replacement: after a database's StatefulSet is replaced (new UID), new runs ingest under the new source identity, runs from the old incarnation stay restorable only through their accepted digest, and a restore from each is shown. (MP-23 B1)
- [x] `inventory status` shows `scheduledRetention` as `retain-by-default` / `keepAndExpiry: unenforced` for accepted signed schedules (2026-10-03, implementer). The public check found it always empty: selection matched the signing Secret on API group `v1`, but core-group addresses carry the empty group. The fix moves selection to `Nagare.Inventory.Status.signedScheduledBackups`, with a regression over a compiled database bundle. On cp3 (read-only, development binary) all five signed schedules are now listed, and the human summary says keep/expiry are unenforced. Re-proof on the final candidate is part of C2. (MP-23 B1)
- [x] Orphaned uploads have a public disposition (2026-10-03, operator decision): they stay permanently unresolved. `docs/user/backups-and-disaster-recovery.md` states that archives without receipts, receipts without archives and unrecognized keys are listed as unresolved. It also states that they are never ingested, counted toward freshness, restored or deleted by Nagare, that their storage is the operator's responsibility, and that any removal is an out-of-band exact-version provider action. No reviewed resolution command was added.
- [x] User documentation matches evidence for GCS scheduled ingestion (2026-10-02): `docs/user/backups-and-disaster-recovery.md` now cites the installed cloud ingestion and restore evidence and states that it predates the final candidate. (MP-23 B1)
- [ ] All of the above re-proved on the one frozen candidate in the EP-155 local and EP-156 cloud scenarios. (MP-23 C2, C3)


## Coverage Matrix

Status per engine and path. "I" means independently proved on a native system, "M" means implementer evidence only (in the snapshot unless linked), and "O" means open. Restore-side coverage is in EP-160.

| Source | Local manual receipt | Local scheduled receipt | Cloud manual receipt | Cloud scheduled receipt | Observed freshness | Corrupt / incomplete-upload refusal |
|---|---|---|---|---|---|---|
| PostgreSQL | M | M (automatic firing 2026-09-28) | I [mgcs] | I [ingest], [v5] | I healthy 646s [v5] | tests I [tests], [upload]; native O |
| Redis | O | I [local] | O | I [cloud] | I healthy 515s [local]; warning 1806s [cloud] | ingestion verifier tests I; native O |
| ClickHouse | M | I [local] | O | I [cloud] | I healthy 515s [local] | ingestion verifier tests I; native O |
| Volume (snapshot) | I [local] | O — no scheduled volume producer (D2) | I [vol] | O (D2) | none | archive SHA-256 checked; provider-version pins not claimed; tamper O |

Evidence keys: [mgcs] [manual GCS recovery](../audits/mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json); [ingest] [GCS ingestion](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-ingestion-a027d1f6.json); [v5] [automatic v5 and freshness](../audits/mp23-independent-results-2026-10-02/scheduled-v5-freshness-ec2e1cd4.json); [local] [local engine and volume recovery](../audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json); [cloud] [cloud engine recovery](../audits/mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json); [vol] [cloud volume recovery](../audits/mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json); [tests] [scheduled GCS tests](../audits/mp23-independent-results-2026-10-02/scheduled-gcs-tests.txt); [upload] [interrupted upload](../audits/mp23-independent-results-2026-10-02/interrupted-upload-regression.txt). Independent evidence spans candidates `a027d1f6`, `76628094`, `ec2e1cd4` and `e6255e6f`. None of it is final-candidate acceptance yet. The first cloud Redis receipt is excluded from all claims because its seed failed authentication (see Surprises).


## Surprises & Discoveries

Earlier and superseded discoveries are in [the snapshot](../audits/mp23-archive/plan-history/ep159-before-consolidation-2026-10-02.md).

2026-10-02: Freshness is computed correctly but does not hold without an operator. Only receipts accepted through a reviewed change count toward it. In the cloud Redis run, the check warned at 1806s while a newer verified upload was waiting for acceptance. Production uploads therefore do not by themselves keep a context healthy; this is decision D1.

2026-10-02: Generated database, authentication, HMAC and local object-store credentials are absent from reviewed templates and inventory exports by design. Recovery after source-cluster loss therefore also needs a separately encrypted off-cluster credential archive. The independent drill used one ([evidence](../audits/mp23-independent-results-2026-10-02/encrypted-credential-recovery-ec2e1cd4.json)), but no automatic secret-backup facility exists.

2026-10-02: `gcloud storage ls --json` exits 1 for an empty prefix. `gcloud storage objects list --raw --format=json` returns an empty array with exit 0 and complete metadata, including decimal-string generations. The provider timestamp may use `+00:00` instead of `Z`, so the parser accepts both forms.

2026-09-28: A retention prune Job mistook the sibling receipt key for the backup key and stopped after deleting only the backup version. The immutable failed review could not be replayed with the fix. A reviewed receipt-only recovery (`db recover-scheduled-prune`) bound to the original transaction was needed. This is why recovery of already-admitted partial prunes stays supported while new pruning is deferred.

2026-09-27: The old renderer named objects by second-resolution timestamp, so concurrent or retried Jobs could collide. Kubernetes projects the Job controller UID onto its Pods as label `batch.kubernetes.io/controller-uid`, which the downward API exposes to the upload container. The MinIO upload image lacks `cmp`, so byte comparison uses SHA-256.


## Decision Log

In-force decisions, condensed. Full verbatim entries are in [the snapshot](../audits/mp23-archive/plan-history/ep159-before-consolidation-2026-10-02.md).

2026-10-03 (operator): Orphaned uploads stay permanently unresolved and documented, with no reviewed resolution command. Rationale: this is cheaper, it matches the deferred-pruning reduction, and the objects can never authorize restore or freshness.

2026-10-03 (operator, MP-23 D1/D2/D6): Freshness counts verified pending uploads and the signing key is escrowed off-cluster; volumes are outside the objective; the objective is a per-context `hourly`/`daily` preset bound into the signed schedule metadata. This supersedes the 2026-10-02 entries below that say only accepted receipts count and that the objective is fixed at one hour. See ADR 22 (2026-10-03 amendment).

2026-10-02 (consolidation): Rewrite this plan as a current-state document aligned with MP-23 and rename the title to match the registry. No scope or acceptance criterion changes.

2026-10-02: Production use of real company data requires MP-23's data-protection gate: a one-hour RPO after total cluster loss, measured from the latest usable off-cluster recovery point including upload and verification lag. Unattended RPO (D1), volume RPO (D2), and recovery-time and retention targets (D4) are operator decisions. This plan implements whichever option is chosen and does not pre-empt them.

2026-10-02: Schedules run every 15 minutes and emit v5 receipts with a signed pre-dump UTC timestamp. Freshness warns at 1800s and breaches at 3600s. Only freshly verified accepted receipts count, so an unaccepted candidate cannot make the check healthy. Version-4 receipts stay restorable but cannot establish freshness. The 15-minute cadence leaves retry margin; it is not a continuous-recovery guarantee.

2026-10-02: An accepted receipt is re-verified against its immutable accepted digest and exact provider versions. Later schedule or signing-key changes do not invalidate it. Unaccepted runs must still match the current signed schedule and source.

2026-09-29: Explicit abandonment of a failed admitted operation is an inactive, unresolved-provider outcome. It is never convergence and never permission to replay.

2026-09-28 (operator-approved reduction): Scheduled backups are retained by default. Configured keep-N and expiry are reported as unenforced in listing, review confirmation, status and user docs. New scheduled-prune admission refuses at every entrypoint (EP-153 owns the guard). Recovery of already-admitted partial prunes is kept and must start from the original transaction and exact remaining versions. No object-store lifecycle rule may delete referenced recovery data. Existing exact manual pruning remains only for its supported receipt forms, and a scheduled receipt must not be relabelled as manual to bypass the exclusion.

2026-09-27: The producer contract is a create-only object keyed by Job UID; a receipt only after stored-byte readback; source StatefulSet/PVC UIDs captured before the dump and rechecked after; an HMAC signing key in a retained, create-only Secret visible only to the upload container; and ingestion through an independent reviewed scope that never trusts an arbitrary object under a prefix.

2026-09-26: This plan took over an unfinished outcome of [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Delivered behavior is preserved.


## Outcomes & Retrospective

Achieved as of 2026-10-02: the scheduled producer, signed receipts with recovery-point timestamps, MinIO and GCS ingestion after Job cleanup, historical receipt validity across schedule changes, the freshness computation, and the retain-by-default boundary are implemented. Each has independent native evidence for at least one engine in each provider, and all three engines are independently proved for cloud scheduled receipts. Remaining: the open Progress items, chiefly unattended RPO (D1), an operational freshness surface, the volume decision (D2), source-replacement ingestion, and final-candidate binding.

Lesson: the plan accumulated dated checkpoints faster than they were reconciled, so it kept describing GCS, monitoring and source-unavailable recovery as unproved after independent evidence existed. Record each result once, as a Progress item with its evidence link.


## Context and Orientation

A *scope* is one owner's declared set of resources with its own revision. A *review* is an immutable saved plan (`--save-plan DIR`) of exact intended effects; `nagarectl inventory apply DIR --yes` executes it. The private *journal* records execution, and accepted history lives in the context's inventory store: the filesystem locally, or the context's GCS state bucket in the cloud. A *physical identity* is one real incarnation, such as a Kubernetes UID or a storage object version (MinIO) or generation (GCS); names alone never authorize anything. A *receipt* is a small JSON document written beside a backup archive that names the producing Job UID, object address, checksum, source UIDs and, from version 5, the recovery-point timestamp, all wrapped in an HMAC-SHA-256 envelope. A receipt is *accepted* only after a reviewed ingestion scope has pinned its exact object and receipt versions. *Freshness* is the age of the newest accepted, freshly re-verified recovery point.

Database declarations are in `cli/nagare-dsl/src/Nagare/Resource/Database.hs`. Backup Job and CronJob shell scripts are rendered by `cli/nagarectl/src/Nagare/Database/Backup.hs`, and object-store transport by `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`. Receipt parsing and verification are in `cli/nagarectl/src/Nagare/Inventory/Backup.hs` and `cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs`. The freshness rule is `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs`. The public commands are `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs` (listing, `--check-freshness`, ingestion review), `ScheduleObservation.hs`, `ManualReceipt.hs` and `ScheduledPrune.hs` in the same directory. Deferred-operation admission refusal is in `cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`, and `scripts/audit-managed-commands.py` pins which routes are deferred or recovery-only. The `scheduledRetention` status field is emitted by `cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs`. The old backup probe used by `server status` and `doctor` is in `cli/nagarectl/src/Nagare/Ops/Probe.hs` and `cli/nagarectl/src/Nagare/Ops/Doctor.hs`; it reads object timestamps, not accepted receipts. Tests are in `cli/nagarectl/test/Nagare/Test/Backup/` (`Scheduled.hs`, `Prune.hs`, `Upload.hs`). User documentation is `docs/user/backups-and-disaster-recovery.md`.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent scopes, exact reviewed effects and immutable history, and records the 2026-09-28 scope reduction. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires the active-context project guard on every cloud path. Nagare never uses GKE: the supported targets are local k3d/k3s and k3s on a NixOS VM in Compute Engine. Local checks use only the `nagare-mp23-cp3` Colima profile, run one at a time.


## Plan of Work

**M1 — Scheduled receipts.** The producer, ingestion, historical-receipt and interrupted-upload behavior is in place (see Progress). The remaining M1 work starts with source replacement. Using a disposable database, replace its StatefulSet through a reviewed change and confirm that unaccepted old-incarnation runs stay unresolved. Then confirm that previously accepted runs still restore through their accepted digest and that new runs ingest under the new UIDs. Next, give orphaned objects a public disposition. Prefer a reviewed exact-version resolution that reuses the conditional-deletion pattern of `db recover-scheduled-prune`, never a prefix cleanup. If the operator prefers to leave orphans in place, document them as permanently unresolved instead.

**M2 — Explicit retention limits.** Pruning stays deferred. The only remaining M2 assertion is public: run `inventory status` on a candidate whose workspace matches its payload and observe `scheduledRetention`. Do not add new pruning, lifecycle rules or keep-N selection.

**B1 recovery-point work (not a numbered milestone).** D1, D2 and D6 are implemented, and the public `scheduledRetention` check is fixed (see Progress). What remains is source-replacement ingestion and native proof on the frozen candidate: a daily-objective schedule review, pending-point freshness, and an escrowed verification against GCS.


## Concrete Steps

Run from the repository root. A test pattern must select at least one test; zero selected tests is not a pass.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p backup' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p freshness' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p prune' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
nagarectl_bin="$(cd cli/nagarectl && cabal list-bin exe:nagarectl)"
bash scripts/test-application-entrypoint-guards.sh "$nagarectl_bin"
python3 scripts/audit-managed-commands.py
```

Public operator path against an explicitly selected disposable context (cloud contexts pass the ADR 9 guard first):

```bash
nagarectl db backup-receipts "$DB"                                  # accepted / verified-pending / unresolved
nagarectl db backup-receipts "$DB" --backup-id "$JOB_UID" --save-plan "$REVIEW"
nagarectl inventory apply "$REVIEW" --yes
nagarectl db backup-receipts "$DB" --check-freshness                # exit 0 only when healthy
nagarectl db prune-scheduled-backups "$DB" --save-plan "$PRUNE_DIR" # must refuse, no effects
```

Each review directory is new. At a milestone boundary, also run the full `nagarectl-test` suite, then `just haskell-style-check`, then, if user docs changed, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`. Run the two Haskell suites one after the other, never in parallel.


## Validation and Acceptance

M1 is accepted when, on one candidate and for every engine, two genuine automatic runs of one reviewed schedule each produce a distinct Job UID, object and receipt. Both must survive Job cleanup, ingest through review and feed an EP-160 content-checked restore. Changed, foreign or receipt-less objects must never be listed as accepted, and the source-replacement case must behave as described in Plan of Work. M2 is accepted when listing, review confirmation, `inventory status` and the user docs all report retention as unenforced; when new scheduled-prune commands and saved reviews refuse before effects; and when existing partial-prune recovery regressions still pass. The B1 items are accepted when an unattended context behaves as D1 specifies for at least one hour, and when `server status` shows a warning before the hour and unhealthy at breach. Record the candidate revision, review and transaction IDs, and the evidence location. Recording-provider tests do not substitute for native evidence.


## Idempotence and Recovery

All reviews are immutable, so re-running a listing or a plan never mutates anything. Reuse an operation ID only with identical intent; changed input needs a new review. An unknown provider result stays unresolved until observation proves what happened. Never blindly replay, prefix-delete, reset history or manually patch an object to manufacture a result; recover an admitted transaction through its recorded identity (`inventory resume`, `inventory recover`). Cloud mutations need the operator's go-ahead as one rehearsed, bounded sequence. Use `mori` to locate dependency sources, and never search `/nix/store`.


## Interfaces and Dependencies

Prerequisites [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md) and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) are complete. This plan owns the receipt envelope (v4 and v5), the scheduled producer and its delegation, the ingestion commands, freshness, and retention reporting. [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) consumes accepted receipts and must not invent another format. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns deferred-route guards and the coverage catalogue. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) re-prove this on the frozen candidate, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) assembles the evidence. Stable public interfaces: `db backup-receipts NAME [--check-freshness]`, `db backup-receipts NAME --backup-id ID --save-plan DIR`, `db disable-backup-prune NAME --save-plan DIR`, `db recover-scheduled-prune` (recovery only), and the `scheduledRetention` field of `inventory status`.


## Revision Notes

2026-10-02: Consolidated with MP-23; title aligned with registry; history in the snapshot.
