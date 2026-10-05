# D. EP-173 interpreter/model coverage review

Snapshot: `m1` at master `09241d35`, package `cli/nagarectl`. All paths below are relative to
`cli/nagarectl/` unless they start with `docs/`. Nothing was built or run. Every claim comes from
reading the source. Coverage cells are judgments made against that source, using the method in §2.

Context outside the snapshot: the live working tree (git status at session start) holds uncommitted
work on several of the gaps below. It adds mutation diffs `F61-transfer-redoes-incomplete-copy`,
`F63-*` (StatefulSet update and readiness), `F64-deleted-*` (out-of-band deletion) and
`F65-create-stop-companions`, plus `test/InventoryTransferScriptSpec.hs`, and it edits
`World/Adversary.hs` and `World/Kubernetes.hs`. None of that is counted here.

---

## 1. Inventory

### 1.1 Worlds

| World | File | Seam replaced | What it models |
|---|---|---|---|
| Kubernetes API world | `test/Nagare/Test/World/Kubernetes.hs` | `KubernetesAdapterOps` (observe and conditional mutate), `World/Kubernetes.hs:102-108` | Objects with uid, owner stamp, generation, resourceVersion, digest, foreign-manager flag and readiness (`:41-51`). A UID+resourceVersion conditional write (`:234-244`). Readiness only for KService, Deployment, StatefulSet, DomainMapping and Job (`:284-289`); only a Job can fail (`:252`). A stable configuration observation for version-2 KService updates (`:119-124`). A managed-fields live reader for F54 (`:293-318`). Write counting for I4 (`:277`). |
| Adversary | `test/Nagare/Test/World/Adversary.hs` | none (a scheduler) | 14 faults (`:39-71`), each fired at the n-th call of Mutate, Observe, StorePut or StoreGet (`:25-37`, `:74-83`). Transient or persistent (`:90-98`). Store calls count only once setup is done (`:116`). |
| Faulting store | `test/Nagare/Test/World/Store.hs` | `ObjectOps` over `fakeObjectOps` | `PutRefused` returns `PutUnknown` with no write. `PutLandedUnacknowledged` writes, then returns `PutUnknown`. `GetFailedOnce` returns `GetUnknown` (`:14-30`). All three are transient only. |
| Rename kubectl world | `test/InventoryPostgresRenameSpec.hs:289-470` | the `kubectl` interpreter beneath the real `KubernetesRuntime` | create, patch (UID+RV precondition), `delete --raw` with UID precondition, and transfer Jobs that copy volumes and count destination writes (`:410-455`). `wait` and `rollout status` always succeed (`:384-385`), so nothing is ever unready. |
| Effectful restore world | `test/Nagare/Test/Effectful/Model.hs:44` | process IO under the real restore runtime | Faults `BeforeWrite`, `AfterWrite` and `WaitTimeout`, with virtual time. |
| Effectful collection world | `test/Nagare/Test/Effectful/CollectionModel.hs:37` | process IO under the real collection runtime | 14 faults: BeforeDelete, LostDeleteAck, LyingWait, ImmediateDeletion, RaceUid/RaceVersion, Cascade, CascadeLostAck, IncompleteList, DiscoveryFailure, ListFailure, MalformedList, ListWarning. |

No other worlds exist: Pulumi, CloudFoundation, Host, Artifact, Cache, Broker, Helm, CDN DNS,
Cloudflare, Access, VmPower, ImagePrune and CdnPurge have none. Several of these take injected ops
records (for example `TopicAdapterOps` and the GitHubRelease ops), so hand-written fakes exist in
point specs, but no model drives them.

### 1.2 Adversary faults (`World/Adversary.hs:39-71`)

`LostAcknowledgement`, `RefusedBeforeEffect`, `LandsUnready`*, `LandsFailed`*, `StatusChurn`,
`ForeignManager`*, `Interrupt`, `ChurnAlways`*, `ForeignObject`*, `Replaced`*,
`TransientReadFailure`, `PutRefused`, `PutLandedUnacknowledged`, `GetFailedOnce`.
(* marks a persistent fault.)

There is no fault for out-of-band deletion, partial effect, a crash at a store/journal boundary, a
persistent store outage, executor-claim loss, or a provider that replaces an object on update
(`KubernetesReplacementRequired` is never produced).

**`LandsFailed` does nothing in the main model.** Only an address of kind `job` becomes
`FailedReadiness` (`World/Kubernetes.hs:252`), and no scenario declares a Job. Every
`LandsFailed` placement therefore runs as fault-free.

### 1.3 Scenarios

`InventoryRecoveryModelSpec.hs:83-92` defines seven scenarios, all on a single Kubernetes executor:

1. create (KService + release-history ConfigMap)
2. create then good update (the **only** scenario the fast tier sweeps store faults on, `:117-125`)
3. bad update, then corrected update, with history unchanged
4. the same, with history following the release
5. the same, with a durable PVC
6. create with a PVC, then `RetireScope RetainResources`. Retention is head-only; no `RetireResource` operation is planned (`Lifecycle.hs:129-145`).
7. create a standalone Postgres database (credential Secret, PVC, ConfigMap, Service, StatefulSet, backup CronJob, SA/Role/RoleBinding, signing Secret), then plan scheduled receipt ingestion (`:352-424`)

`InventoryRenameRecoveryModelSpec.hs:49-58` adds the reviewed Postgres rename (8 `MigrateResource`
stages per member). It applies one of three faults (`RefusedWrite`, `LostAcknowledgement`,
`InterruptedAfterWrite`, `:62-69`) at every `kubectl` write.

Exit search (`InventoryRecoveryModelSpec.hs:506-618`):
- Moves are Resume plus 11 `RecoveryAction`s per open operation, searched depth-first to depth 4, with every node a fresh replay.
- The plan's third exit, "a new corrected review planned from the current history" (`docs/plans/173-…md` §M1), is **not** among the moves. Corrected reviews appear only as scripted scenario steps.
- `RecoverBootstrapRegistry` is not tried.

The rename exit search is shallower (`InventoryRenameRecoveryModelSpec.hs:113-156`): three resumes, then each action followed by one resume.

### 1.4 Invariants as implemented

| Inv | Plan text | Code | Gap |
|---|---|---|---|
| I1 exit | some exit reaches an idle head | `runScenario` `:180-190`; rename `:152-156` | none |
| I2 nothing unreviewed accepted | accepted revisions move only to completed reviews; converged means reviewed digest **and recorded UID** and Ready | `checkInvariants` `:646-656` checks only digest and Ready for newly converged revisions | The accepted-revision clause and the UID clause are not checked (I3 covers the UID partly, through status). |
| I3 incarnation | status, receipt ingestion, retention, rename | status `:675-700` (production `classifyDriftWith`/`statusIncarnations`); retention `:660-670`; receipt `:399-419` with an explicit F60 tolerance; rename `:115-131`, `:176` | The receipt clause runs only in scenario 7. |
| I4 at most once | no double write after proof | `effectiveWrites` > 1 per OperationId, `:646`; rename: destination written once, `:178` | Counts world writes only. |
| I5 store | head recoverable, journal chain valid | `storeConsistent` `:624-636`, at scenario end only | not checked at intermediate stops |
| I6 transient | one transient read never strands a run | no separate assertion; subsumed by I1 under `TransientReadFailure` | — |
| I7 liveness | churn alone needs no exit | `:176-179` | only for schedules made purely of `ChurnAlways` |

### 1.5 Tiers

- Fast tier (`:59`): every single placement of every fault at every boundary counted in the fault-free run, with store faults on scenario 2 only. It runs in the ordinary suite (`test/Nagare/Test/Suite.hs:201-202`), about 69 s according to the EP-173 progress notes.
- Deep tier (`:60-62`): every ordered pair, gated on `NAGARE_RECOVERY_MODEL_DEEP=1`. **No `just` recipe or script sets it**: grepping `justfile*` and `scripts/` finds nothing, so the deep tier never runs in any gate.

### 1.6 What is production and what is a stub

| Production under the model | Replaced or stubbed |
|---|---|
| `composeInventory`, `loadInventoryPlanningHistory`, `observationRequirements`, `observeWithRegistry`, `planChanges`, `decideRetirement`, `prepareReview`, `publishReview`, `verifyReview` (`:456-477`); `applyReviewed`, `resumeTransaction`, `recordOperatorRecovery` (driver, admission, journal, recovery policy); `mkKubernetesAdapterWithConfigurationObservation` (all of the adapter's prepare, preflight, execute, verify and recover logic); `Status.classifyDriftWith`/`statusIncarnations`; `compileScheduledIngestScope`; the store over a fake `ObjectOps` | **The production `KubernetesRuntime` (1,398 lines)**: kubectl conditional apply, readiness waits (`KubernetesRuntime.hs:302-345`), observation classification including ReplacementRequired/Failed (`:590-610`). The world implements `KubernetesAdapterOps` directly. **The registry is test-local** (`InventoryRecoveryModelSpec.hs:784-786`; M3 is not done, and `src/Nagare/Inventory/Registry.hs` does not exist). The backup-receipt reader and scratch-failure probe are stubbed (`World/Kubernetes.hs:96-97`). The takeover constructor is not used, so v3 takeover is never prepared. There is no `withAdapterRecovery` (production adds it at `app/Nagare/Cli/Inventory/Execution.hs:676`) and no data fences, so the four fenced recovery actions are tried and always refused, and `Execute/FencedRecovery.hs` has zero model coverage. |

The rename model is the one place where the **real `KubernetesRuntime`** runs under faults
(`InventoryPostgresRenameSpec.hs:543-590`). The effectful specs (`InventoryEffectfulSpec.hs:44-49`,
`InventoryEffectfulCollectionSpec.hs:42-49`, `InventoryControllerCollectionSpec.hs:30-40`,
`InventoryNativeCollectionSpec.hs:31-52`) also run real runtimes, but they are hand-enumerated
point tests with no exit search or invariant sweep.

### 1.7 Harness soundness issues

1. **`ForeignObject` masks every planning refusal in its schedule** (`InventoryRecoveryModelSpec.hs:235-240`). If any fault in the schedule is `ForeignObject`, a planning refusal at any step ends the scenario as success, including refusals unrelated to the foreign object. In the deep tier this silences the second fault of every pair that includes `ForeignObject`.
2. Store faults are swept on one scenario in the fast tier. The StatefulSet, PVC, Verify and Retain rows therefore get store faults only in the deep tier, which never runs.
3. `retryingStoreFaults` (`:427-436`) and `tryMove` (`:540-550`) retry once whenever any fault fired. That is correct for transient faults, but it can hide a command that fails for a different reason in the same window.
4. The world's `hasReadiness` (`World/Kubernetes.hs:284-289`) omits CRD, Certificate and ClusterIssuer, which production waits on (`KubernetesRuntime.hs:385-394`).

---

## 2. Coverage matrix

**Rows.** Each row is an (executor/kind × action) pair that exists in production. The rows were
enumerated from:
- the `Executor` enum (`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs:77`)
- `OperationAction` (`src/Nagare/Inventory/Adapter.hs:110-119`)
- each adapter's action allowlist: `Kubernetes.hs:494-506`, `Foundation.hs:166`, `HostRuntime.hs:103`, `ArtifactRuntime.hs:105`, `Cache.hs:143`, `Broker.hs:106-128`, `Helm.hs:153`, `Cdn.hs:120-124`, `Cloudflare.hs:171-176`, `Pulumi.hs:106,124,194-196`, `Access.hs:335`, `VmPower.hs:198-218`, `CdnPurge.hs:133`, `ImagePruneAdapter.hs:39`, `Collection/Adapter.hs:75-80`, `KubernetesMigration.hs:88-92`
- the planner's emission points (`Plan/Changes.hs:530,656-659,703-770`)

**Columns.**

| Code | Fault |
|---|---|
| R | refused before effect |
| L | lost ack |
| I | interrupted after write |
| U | lands unready |
| F | lands failed |
| Rp | replaced out of band |
| D | deleted out of band |
| Fo | foreign owner/manager |
| Pa | partial effect |
| T | transient observe failure |
| SP | store PutRefused |
| SU | store PutLandedUnacknowledged |
| SG | store GetFails |
| CJ | crash at a store/journal boundary (process death after `IntentRecorded` before the call, or after a completion put before the head advance) |

**Cell values.**

| Value | Meaning |
|---|---|
| **C** | swept by the fast-tier model with invariants |
| **Cd** | swept by the deep tier only |
| **P** | a hand-written point test exists, with no sweep or exit-search invariant |
| **N** | reachable but not modelled |
| – | unreachable for this row (for example, no write, no readiness concept, or a single-object atomic write for Pa) |

Interrupt (I) means the process dies after the provider write lands and before the result is
journalled (`Adversary.Interrupt`, `World/Kubernetes.hs:226`). CJ is the distinct case of death at a
store/journal boundary.

### 2.1 Kubernetes executor

| # | Row | R | L | I | U | F | Rp | D | Fo | Pa | T | SP | SU | SG | CJ | reach | C(+Cd) | P |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| K1 | Create KService (sc.1-6) | C | C | C | C (F16) | – | C (F60 tol.) | N | C (F35) | – | C | C | C | C | N | 12 | 10 | 0 |
| K2 | Create StatefulSet (sc.7) | C | C | C | C (F59) | – | C (I3 receipt) | N | C | – | C | Cd | Cd | Cd | N | 12 | 10 | 0 |
| K3 | Create ConfigMap/Secret/Service/CronJob/RBAC | C | C | C | – | – | C | N | C | – | C | C | C | C | N | 11 | 9 | 0 |
| K4 | Create durable PVC/credential | C | C | C | – | – | C (F49) | N | C | – | C | Cd | Cd | Cd | N | 11 | 9 | 0 |
| K5 | Create Deployment/DomainMapping/Certificate/CRD | N | N | N | P¹ | – | N | N | N | – | N | N | N | N | N | 12 | 0 | 1 |
| K6 | Create Job / RunDeclaredOperation (backup, restore, prune, ingest, migration Jobs) | P² | P² | N | P² | P³ | P² | N | N | – | N | N | N | N | N | 12 | 0 | 5 |
| K7 | Update KService (v1/v2) | C | C | C | C (F54) | – | C (F56/57) | N | C (F37) | – | C | C | C | C | N | 12 | 10 | 0 |
| K8 | Update ConfigMap (history) | C | C | C | – | – | C | N | C | – | C | C | C | C | N | 11 | 9 | 0 |
| K9 | Update StatefulSet/Deployment/Secret/PVC/CronJob/NetworkPolicy/Namespace/Quota (`KubernetesRuntime.hs:286-299`) | N | N | N | N | – | N | N | N | – | N | N | N | N | N | 12 | 0 | 0 |
| K10 | Update with reviewed field takeover (v3) | N | N | N | N | – | P⁴ | N | P⁴ | – | N | N | N | N | N | 12 | 0 | 2 |
| K11 | Verify | – | – | – | N | – | C (F57) | N | N | – | C | Cd | Cd | Cd | N | 9 | 5 | 0 |
| K12 | Adopt | N | N | N | N | – | N | N | P⁵ | – | N | N | N | N | N | 12 | 0 | 1 |
| K13 | RetireScope RetainResources (head-only) | – | – | – | – | – | C (F51) | P⁶ | N | – | C | Cd | Cd | Cd | N | 8 | 5 | 1 |
| K14 | RetireResource collection (ordinary + controller cascade) | P⁷ | P⁷ | P⁷ | P⁷ | – | P⁷ | P⁷ | P⁷ | P⁷ | P⁷ | N | N | N | N | 13 | 0 | 9 |
| K15 | OpenMaintenanceSession (new admissions deferred, `Admission.hs:128`) | N | P⁸ | N | N | – | N | N | N | N | N | N | N | N | N | 13 | 0 | 1 |
| K16 | RestoreLiveDatabase (deferred) | N | N | N | N | – | N | N | N | N | N | N | N | N | N | 13 | 0 | 0 |
| K17 | MigrateResource (Postgres rename, 8 stages) | C | C | C | N | N | N | N | N | N (F61 WIP) | N | N | N | N | N | 14 | 3 | 0 |
| | **Kubernetes total** | | | | | | | | | | | | | | | **199** | **70** (58 fast) | **20** |

Notes:
1. `InventoryKubernetesSpec.hs:392`
2. `InventoryEffectfulSpec.hs:44-47` (BeforeWrite, AfterWrite, WaitTimeout, changed source identity)
3. `InventoryTransactionSpec.hs:2604`, `InventoryRedisRestoreRecoverySpec.hs:111`
4. `InventoryKubernetesFieldTakeoverSpec.hs:61,70`
5. `InventoryKubernetesSpec.hs:527`
6. `InventoryApplicationUpdateRecoverySpec.hs:34`
7. `InventoryEffectfulCollectionSpec.hs:42-49`, `InventoryControllerCollectionSpec.hs:30-40`, `InventoryNativeCollectionSpec.hs:31-52`
8. `InventoryMaintenanceSpec.hs:18`

Outside the counts: scheduled receipt ingestion (a planning flow, not an action) is C for Rp and T
(the I3 receipt clause, F49), Cd for SG, and N for D and Fo.

### 2.2 Executors with no world

Every cell in these rows is N except the P cells listed.

| Row | reach | P cells (point tests) |
|---|---|---|
| Pulumi Create/Import | 12 | R (`InventoryCloudSpec.hs:122,157`) |
| Pulumi Update | 12 | – |
| Pulumi Retire/collection | 12 | L, Rp (`InventoryCloudCollectionSpec.hs:109,180`) |
| Pulumi Verify | 8 | – |
| CloudFoundation Create/Update/Adopt (gcloud) | 11 | L (`InventoryFoundationSpec.hs:288`); Fo, T (`:355`). The F50 transient-read guard waits for M4. |
| CloudFoundation Verify | 8 | – |
| Host activation Create/Update | 12 | R (`InventoryHostSpec.hs:159`); I, F (`:168`); Rp (`:176`) |
| Host Verify/RunDeclared | 8 | – |
| Artifact publish (Create/Update/RunDeclared) | 12 | L (`InventoryArtifactSpec.hs:333`); Fo (`:343`); D (`:353`) |
| Cache (Create/Update/RunDeclared) | 11 | L (`InventoryCacheSpec.hs:189`); Fo, T (`:279`) |
| Broker topic Create/Update | 11 | Fo, L (`InventoryApplicationSpec.hs:~950-1005`) |
| Broker Verify | 8 | – |
| Helm Create/Update | 14 | Rp (`InventoryObservabilitySpec.hs:552`); Fo (`:605`); U (`:658`) |
| Helm Verify | 8 | – |
| CDN DNS Create/Update/Retire | 11 | T (`InventoryCdnSpec.hs:251`) |
| Cloudflare Create/Update/Retire/Adopt | 11 | Rp/stale (`InventoryCloudflareSpec.hs:47`) |
| CdnPurge RunDeclared | 11 | L (`InventoryCdnPurgeSpec.hs:26,34`); Rp (`:50`); SU-like receipt (`:42`) |
| Access grant Create/Update/Verify | 11 | L, Fo (`InventoryAccessSpec.hs:148`); Rp (`:172`); T (`:115`) |
| VmPower RunDeclared | 12 | L (`InventoryVmPowerSpec.hs:27`); Fo (`:46`); Pa (`:58`); receipt ack (`:82`) |
| ImagePrune RunDeclared | 12 | L (`InventoryImagePruneSpec.hs:32`); I (`:46`); Rp (`:54`); D (`:70`) |
| **Non-Kubernetes total** | **215** | **C 0, P 38** |

GitHubRelease publication (`Adapters/GitHubRelease.hs`) is release tooling outside `Executor`. It has
P coverage for I, T and Pa (`InventoryPublicationSpec.hs:42,105,148`).

### 2.3 Totals

| | cells | share of 414 reachable |
|---|---|---|
| **C** (any tier) | 70 | **16.9%** |
| C, fast tier only (the gated number) | 58 | 14.0% |
| P (point tests only) | 58 | 14.0% |
| **N** (not modelled) | 286 | **69.1%** |

- Within the Kubernetes executor: 70/199 = 35%.
- Within the eight rows the model actually exercises (K1-K4, K7, K8, K11, K13): 70/86 = 81%. The misses there are D, CJ, and Verify-U/Fo.

### 2.4 Biggest uncovered areas, by risk

1. **Data Jobs and declared operations (K6) and fenced data operations (K15/K16, `FencedRecovery.hs`).** Backup, restore, prune and ingest Jobs are where data is destroyed, and they have no model. `LandsFailed` is dead code in the model, and the four fenced recovery actions always refuse.
2. **Application Deployments (K5).** This gap probably hides a live defect. I have not verified it, because nothing was run.
   - `RecoveryAwaitingReadiness` admits a created Deployment (`Kubernetes.hs:358`), and `continueReadiness` exists only for Deployments (`Driver.hs:284-317`).
   - But `StopIncompleteApplication` admits only an Application's KService, a preview DomainMapping, or a Standalone StatefulSet (`Plan/History.hs:425-441`).
   - So an application whose worker Deployment create never becomes Ready resumes to ambiguous and has no admitted stop. That is the same I1 shape as F16 and F59.
   - The way to check is to add a Deployment member to scenario 1.
3. **Out-of-band deletion (D column, 0 C cells)** and **crash at a journal/store boundary (CJ column, 0 C cells).** Uncommitted F64 work is starting on D.
4. **Migration (K17).** It has only 3 of 14 faults: no transient read, store, unready transfer, partial copy (F61 WIP) or replaced source.
5. **The whole non-Kubernetes estate (215 cells, 0 C).** That is Pulumi, cloud foundation (F50 is blocked on this), Helm and Host, with partial-effect worlds needed for each, plus nine simple single-object providers.
6. **Collection (K14).** It is well point-tested, but it never runs under the exit search or invariants, and store faults are N.
7. **Kubernetes updates of anything except KService and ConfigMap (K9)**, field-takeover execution (K10), and Adopt (K12).

---

## 3. Mutation records (`test/mutations/README.md`)

### 3.1 Pinned guards (23 diffs)

| Area | Guard (diff) | Location |
|---|---|---|
| Recovery | F16 unready-create stop | `Execute/Recovery.hs:480` |
| | F56 stop accepts replaced | `:485` |
| | F35/F37 abandon after fresh or journalled refusal | `:603-605` |
| Kubernetes adapter | F30 v2 write uses the current state | `Kubernetes.hs:295` |
| | F57a verify safe-to-retry | `:339` |
| | F54 landed-unready | `:341` |
| | F56 target replaced | `:342-345` |
| | F59 StatefulSet awaits readiness | `:358` |
| Journal | F38 head retry and orphan adoption | `Execute/Journal.hs:130,170` |
| Driver | F57b journal no-effect refusal | `Execute/Driver.hs:357-370` |
| Admission | F58 absence recheck | `Execute/Admission.hs:193` |
| Planning history | F54/F55a/F55b/F59 stop rules | `Plan/History.hs:334,358,409,437` |
| | F55c unstarted creates | `:560` |
| Planning changes | F51 retention proof | `Plan/Changes.hs:385` |
| | F58 absence proof | `:334` |
| Status and ingestion | F49 status | `Status.hs:639` |
| | F49 ingestion | `ScheduledIngest.hs:164` |
| | F52 status of migrated records | `Status.hs:312` |

Known gaps already recorded in the README:
- the F52 convergence half (`Execute/Incarnations.hs` `establishes`) survives every test (`README.md:43-46`)
- F50 is unreachable (`:48-50`)
- the two F58 records are caught only by focused regressions, not by the model

### 3.2 Major guards with no mutation record

All 23 records target Kubernetes, the store or planning. **No guard in any non-Kubernetes adapter is
pinned.**

- **Kubernetes adapter (`Adapters/Kubernetes.hs`)**
  - v1 exact-precondition compare: `requireSameBefore` `:761-763`. This is the central conditional-write guard; F30 pins only the v2 path.
  - Verify identity check: `:736-754`.
  - `validateBefore` refusals: `:529-575`, for example create needing confirmed absence (`:567`) and update needing an owner stamp (`:569`).
  - Review-tamper bindings: `decodeMutation` `:659-672`, `orTakeover` `:885-899`, `prepareTakeover` move check `:256-271`.
  - Reserved-annotation stamping: `:686-693` and `:713-720`.
  - `buildMutation` checks for status-free, canonical, spec-digest and controller-claim content: `:581-632`.
  - **Data-Job source incarnation pins: `verifyBackupSources` `:439-489`.**
  - Job and scratch `RecoveryTerminalFailure`: `:346-349`, `:374-383`.
  - KService update awaiting readiness: `:363-373`.
  - Retire completion needs a present-before state: `:778-804`.
  - Single-spec executor and action allowlist: `:491-527`.
- **Driver (`Execute/Driver.hs`)**
  - SafeToRetry only when unfenced and dependencies are complete: `:183-187`.
  - The Deployment-only `continueReadiness`: `:284-317`.
  - **Executor-claim recheck before the effect: `:377-379`.**
  - Fence-aware Failed-vs-Ambiguous classification: `:401-404`.
  - Verify failure after a completed effect becomes Ambiguous: `:433-442`.
  - Adapter identity/version check: `:157-159`.
- **Recovery (`Execute/Recovery.hs`)**
  - Fenced abandon refusal: `:451-453`.
  - "preflight passes now; resume": `:615`.
  - Abandon prerequisites: `:298-311`.
  - Adapter-version check: `:382`.
  - `AbandonPartial*` scope predicates: `:496-570`, using `RecoveryPolicy.hs:64,108`.
  - `RetryAfterAdapterProof` needs no fence: `:582-591`.
  - Inactive-transaction, data-fence and review-digest checks: `:272-284`.
- **Admission (`Execute/Admission.hs`)**
  - context-binding, stale-head, stale-base and active-transaction: `:127-135`.
  - retention-history and migration-base: `:141-150`.
  - **Retained-incarnation re-observation at admission, the admission half of F51: `:~186-193`.**
- **Planning (`Plan/Changes.hs`)**
  - foreign, unowned and unverified-owner refusals: `:710-722`.
  - durable-resource-missing: `:731-742`, `:762-765`.
  - replacement-review-required: `:745-746`.
  - retained and collected reactivation: `:277-282`.
  - collection-proof: `:410`.
  - job-revision-required: `:683-692`.
- **Other adapters (none pinned)**
  - Broker create-on-existing: `Broker.hs:115`.
  - Cache present-on-create: `Cache.hs:103`.
  - CDN DNS exact-old match: `Cdn.hs:134`, `CdnRuntime.hs:246`.
  - Cloudflare target match: `CloudflareRuntime.hs:206-220`.
  - Artifact consumer completeness: `Artifact.hs:114`.
  - Foundation recovery: `Foundation.hs:142,198-201`.
  - Host plan validation: `Host.hs:109-118`.
  - Pulumi action match: `Pulumi.hs:194-196`.
  - Controller collection RetireResource-only: `Collection/Adapter.hs:75-80`.
  - Access tuple guards: `Access.hs:358-360`.

The bold items guard data or concurrency. The model as built cannot reach most of them, because it
has no Jobs, no concurrent executor and no admission-time replacement. A mutation record for them
first needs the matching world feature.

---

## 4. Recommendation: make coverage systematic

The model is strong for what it encodes: real planner, driver and adapter, a real exit search, and it
found F55-F59. The problem is that each row was added by hand when a finding pointed there. Invert
that: **declare each kind's world behaviour in a table, and generate the scenario × fault × invariant
product from it.** A new adapter or kind then cannot ship without its row.

1. **Kind table.** Add `test/Nagare/Test/World/Kinds.hs` with one entry per (executor, kind):
   - the actions it supports, cross-checked against the adapter allowlist
   - readiness (`None | CanBeUnready | CanFail`)
   - atomicity (`Atomic | Steps n`), which decides whether Pa is applicable
   - identity (`Uid | NameOnly`)
   - a minimal fixture scope
   - the provider-ops interpreter over a shared world

   An `applicable :: Kind -> Action -> Fault -> Bool` derived from the table replaces the hand-picked scenarios. The "–" cells in §2 become computed, not argued.
2. **Generated scenarios.** For each (kind, action), generate:
   - setup review → action review → corrected/follow-up review
   - a retire/collect where the kind supports it
   - combined-executor scopes (app + DNS + Access + Broker) to cover cross-adapter ordering

   Keep the existing exit search and I1-I7 unchanged, and add the missing pieces of I2 (UID, and the accepted-revision clause).
3. **A generic versioned-object world.** Its operations are a conditional write on (uid, version), readiness, owner stamp and multi-step effects. Each non-Kubernetes world becomes a thin mapping onto the ops records the adapters already take (`TopicAdapterOps`, cache, DNS, Cloudflare, Access, VmPower, ImagePrune, Artifact, foundation). Pulumi, Helm, Host and migration get `Steps n` worlds for partial effect.
4. **New faults.**
   - `Deleted` (out-of-band delete)
   - `CrashAtStore` (throw `Interrupted` at a StorePut boundary, before or after landing)
   - `ClaimLost` (a second executor steals the claim)
   - `PersistentStoreOutage`
   - `ReplacementRequired`

   Also make `LandsFailed` live by adding Job fixtures, and add a fenced-kind fixture so the four fenced recovery actions can succeed.
5. **Totality gates.** These follow the F44 observer-totality pattern.
   - One test fails if any `Executor` constructor (`[minBound..maxBound]`, which already derives Enum/Bounded) or any action admitted by an adapter allowlist lacks a table row.
   - The architecture check fails on a new `Adapters/*.hs` with no world.
   - Finish M3, the production registry builder, so the model runs production wiring.
6. **Harness fixes.**
   - Scope the `ForeignObject` refusal exemption to the step and resource the fault touched (`InventoryRecoveryModelSpec.hs:235-240`).
   - Add the "corrected review" exit move.
   - Wire the deep tier into a nightly or `just gate-deep` run on the remote builder (no GitHub Actions).
   - Sample the fast tier as one fault per (kind, action, fault) at a representative boundary, and keep the full placement sweep for the deep tier, to hold about 60 s.
7. **Mutation records as data.** Every guard listed in §3.2 that becomes reachable gets a diff. Add a script that applies each diff in a scratch worktree and asserts the model fails; it can run in the deep tier.

**Effort estimate** (engineer-days):

| Item | Days |
|---|---|
| Generic harness and kind table | 3-4 |
| Generic world and Kubernetes completion (Deployment, DomainMapping, Job, Certificate, Adopt, collection, takeover, Deleted/CrashAtStore/ClaimLost) | 4-5 |
| Ten simple provider worlds (0.5-1 day each) | 6-9 |
| Multi-step worlds: Pulumi, Helm, Host, migration and fenced data ops (2-3 days each) | 8-12 |
| Totality gate and M3 registry | 2-3 |
| Tiering, deep-tier gate and mutation-runner script | 2 |
| **Total** | **≈25-35 days (5-7 weeks)** |

Suggested staging: phase 1 is the harness, the Kubernetes completion, and the CJ/D faults, about 2
weeks. On my cell weights it would roughly double C coverage, and it targets the riskiest rows (data
Jobs, Deployments, deletion, crash).
