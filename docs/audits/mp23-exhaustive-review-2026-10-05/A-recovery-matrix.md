# A — Recovery totality matrix (nagarectl inventory transactions)

Snapshot: `scratchpad/m1`, git `master` `09241d35`, package `cli/nagarectl`. Read-only source review; nothing was built or run.
Tracker: `docs/audits/mp23-findings.md` (F15–F63 open/verifying) and `docs/audits/mp23-archive/mp23-findings-closed.md`.
F64 and F65 exist only in the operator's uncommitted working tree (`/Users/shinzui/Keikaku/bokuno/nagare`, mutation diffs `F64-*`, `F65-*`); they are cited as `F64(wt)` / `F65(wt)` and are not in the snapshot.

## 1. File aliases (all under `cli/nagarectl/`)

| Alias | File |
|---|---|
| A | `src/Nagare/Inventory/Adapter.hs` |
| D | `src/Nagare/Inventory/Execute/Driver.hs` |
| R | `src/Nagare/Inventory/Execute/Recovery.hs` |
| RP | `src/Nagare/Inventory/Execute/RecoveryPolicy.hs` |
| FR | `src/Nagare/Inventory/Execute/FencedRecovery.hs` |
| CL | `src/Nagare/Inventory/Execute/Claims.hs` |
| TX | `src/Nagare/Inventory/Execute/Transaction.hs` |
| AD | `src/Nagare/Inventory/Execute/Admission.hs` |
| OS | `src/Nagare/Inventory/OperationStep.hs` |
| HI | `src/Nagare/Inventory/Plan/History.hs` |
| CH | `src/Nagare/Inventory/Plan/Changes.hs` |
| K | `src/Nagare/Inventory/Adapters/Kubernetes.hs` |
| KR | `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` |
| KM | `src/Nagare/Inventory/Adapters/KubernetesMigration.hs` |
| CO | `src/Nagare/Inventory/Collection/Adapter.hs` |
| MA / MF | `src/Nagare/Inventory/MaintenanceAdapter.hs` / `MaintenanceFence.hs` |
| LA / LF | `src/Nagare/Inventory/LiveRestoreAdapter.hs` / `LiveRestoreFence.hs` |
| HE / HER | `Adapters/Helm.hs` / `Adapters/HelmRuntime.hs` |
| PU / PUR | `Adapters/Pulumi.hs` / `Adapters/PulumiRuntime.hs` |
| VP / IP | `src/Nagare/Inventory/VmPower.hs` / `ImagePruneAdapter.hs` |
| FO / FOR | `Adapters/Foundation.hs` / `Adapters/FoundationRuntime.hs` |
| HO / HOR | `Adapters/Host.hs` / `Adapters/HostRuntime.hs` |
| AR / ARR | `Adapters/Artifact.hs` / `Adapters/ArtifactRuntime.hs` |
| CA / CAR | `Adapters/Cache.hs` / `Adapters/CacheRuntime.hs` |
| BR / BRR | `Adapters/Broker.hs` / `Adapters/BrokerRuntime.hs` |
| DN / DNR | `Adapters/Cdn.hs` (Google Cloud DNS) / `Adapters/CdnRuntime.hs` |
| CF / CFR | `Adapters/Cloudflare.hs` / `Adapters/CloudflareRuntime.hs` |
| CP | `src/Nagare/Inventory/CdnPurge.hs` |
| AC / ACR | `src/Nagare/Inventory/Access.hs` / `AccessRuntime.hs` |
| EX | `app/Nagare/Cli/Inventory/Execution.hs` (the single execution registry) |

## 2. Inventory of the space

### 2.1 Executors and installed adapters (EX:186-688)

`Executor` = `KubernetesExecutor | PulumiExecutor | CloudFoundationExecutor | HostExecutor | ArtifactExecutor | CacheExecutor | BrokerExecutor | HelmExecutor | CdnExecutor | AccessExecutor` (`nagare-dsl/src/Nagare/Resource/Inventory.hs:77`).

| Executor | Adapter stack at execution (outermost first) |
|---|---|
| Kubernetes | `kubernetesMigrationAdapter` (KM:76-84) → `liveRestoreRuntime` (LA) → `maintenanceAdapter` (MA:56-62) → prune-eligibility preflight wrapper (EX:583-600) → `mkKubernetesAdapterWithConfigurationObservation` / `…WithFieldTakeover` (K:145-171) **or** `controllerCollectionAdapter` (CO:31-40, collection-only reviews); fences `maintenance` and `live-restore` (EX:642-669); recovery capability `bootstrap-registry-credentials` (EX:670-679, cloud bootstrap payload only) |
| Pulumi | `withImagePrune` (IP:28-37) → `withVmPower` (VP:210-216) → `mkPulumiAdapter` (PU) |
| CloudFoundation | `mkFoundationAdapter` (FO:84-96) |
| Host | `mkHostAdapter` (HO:60-72); retained-only hosts use the manifest observer (`Command.hs:952-962`, never executes) |
| Artifact | `mkArtifactAdapter` (AR:53-65); retained-only artifacts use the manifest observer |
| Cache | `mkCacheAdapter` (CA:64-76) |
| Broker | `mkTopicAdapter` (BR:87-170) |
| Helm | `mkHelmAdapter` (HE:72-131) |
| Cdn | `cdnPurgeRuntime` (CP:110-131) → `CdnCombined` dispatch (`Adapters/CdnCombined.hs:20-66`) → Google DNS `mkDnsAdapter` (DN:95-153) or `mkCloudflareAdapter` (CF:142-224) |
| Access | `mkAccessAdapter` (AC:276-326) via `accessReviewAdapter`; access-only reviews get a one-adapter registry (EX:164-180) |
| (outside the journal) | `Adapters/GitHubRelease.hs` is a publication review, not an `Adapter` — N/A |

### 2.2 Actions (`OperationAction`, A:110-120)

`CreateResource`, `UpdateResource`, `VerifyResource`, `AdoptResource`, `RetireResource` (collection), `RunDeclaredOperation`, `OpenMaintenanceSession` (fenced), `RestoreLiveDatabase` (fenced), `MigrateResource {PrepareDestination, BackUpSource, FenceWriters, TransferState, VerifyDestination, SwitchConsumers, AdmitWrites, RetainSource}`.

### 2.3 Recovery decisions (A:156-173) and how the driver treats them (D:169-194)

| Decision | Resume (`ordinaryRecovery`) | Operator actions that accept it |
|---|---|---|
| `RecoveryProvedComplete` | journals `Completed`, continues (D:172-182) | `accept-adapter-proof` (R:573-581) |
| `RecoverySafeToRetry` | re-executes if unfenced and dependencies complete (D:183-187) | `retry-after-adapter-proof` (R:582-591, unfenced only) |
| `RecoveryAwaitingReadiness` | `continueReadiness` (D:270-320): only runs other untouched stateless Deployment creates, then stops | `stop-incomplete-application` as *unproved* landing (R:483); `recover-bootstrap-registry` (R:502-505) |
| `RecoveryLandedUnready` | stop (D:191) | `stop-incomplete-application` as proved landing (R:484) |
| `RecoveryTargetReplaced` | stop (D:192) | `stop-incomplete-application` (R:488) |
| `RecoveryTerminalFailure` | stop (D:193) | `abandon-partial-prune` (R:506-527, RP:64-106), `abandon-partial-volume-restore` (R:528-549, RP:108-174), `abandon-partial-database-restore` (R:550-572, RP:176-278) |
| `RecoveryUnresolved` | stop (D:194) | **none** |

Exits that do not start from a decision: `abandon-refused-operation` (R:287-303, 451-460, 601-626) for a `Pending` op with a fresh preflight refusal or a journalled `Failed KnownNoEffect`; fence-not-reserved retry (R:415-442); fenced actions `continue-fenced-operation` / `verify-fenced-effect` / `recover-fenced-backup` / `forward-fenced-release` (FR:96-321); rollback-resume (TX:248-263).

### 2.4 Exit codes used in the grid

| Code | Exit path | Head release |
|---|---|---|
| RES | `inventory resume` (TX:264-286 → D) | normal |
| ACC / RTY | accept-adapter-proof / retry-after-adapter-proof | normal (R:336-341) |
| ABR | abandon-refused-operation | `releaseAbortedClaim` (R:322-334 → CL:200-224) |
| APP / AVR / ADR | abandon-partial-prune / -volume-restore / -database-restore | `releaseAbortedClaim` |
| STOP | stop-incomplete-application, gated by `incompleteApplicationOnlyReview` (HI:288-444) | `releaseStoppedApplicationClaim` (CL:170-195) |
| BRR | recover-bootstrap-registry (R:145-234, D:199-264) | normal |
| FEN-C/V/B/F | fenced actions (FR) | `recover-fenced-backup` and release-forward close via `releaseAbortedClaim` (FR:231, 244, 290) |
| FNR | fence-not-reserved safe retry (R:415-442) | normal |

### 2.5 Verdict legend

- **E** EXIT: a supported reviewed exit exists (cited).
- **E†** EXIT through `releaseAbortedClaim`. The transaction ends, but see the hazard cells X14–X16: it can leave the store or another scope STUCK-IDLE.
- **T** EXIT after a transient condition clears (resume repeats the same proof; counted as EXIT).
- **W** WEDGE: the store keeps the active transaction and no supported action ends it.
- **S** STUCK-IDLE: the store is idle but the scope (or, marked *global*, every command) cannot move.
- **N** N/A: unreachable for this kind/action (reason in the note).

Outcome columns:
O1a adapter-side refusal (preflight or execute precondition, no effect) · O1b provider rejects the write (validation, quota, webhook, HTTP 4xx, tool error) · O2 not landed: lost acknowledgement, crash or lost claim after intent, before/without the write · O3 landed, acknowledgement lost or process killed after the write · O4 landed and Ready (normal completion, or verification read retried) · O5 landed but unready / never Ready · O6 landed, terminal failure · O7 target replaced out of band (new incarnation) · O8 target deleted out of band · O9 foreign field manager / foreign owner after intent · O10 partial effect · O11 transient read failure during observe/recover · O12 provider still running / timeout.

## 3. Driver-level cells (executor-independent)

| ID | Situation | Decision / state (cite) | Exit (cite) | Verdict | Tracker |
|---|---|---|---|---|---|
| X1 | Unfenced op, first attempt, preflight refuses | no event, `Pending` (D:371) | RES; ABR with fresh refusal (R:287-288, 612-616) | E† | F35 |
| X2 | Fenced op (`OpenMaintenanceSession`, `RestoreLiveDatabase`), first attempt, preflight refuses persistently | `Pending`, no head fence (fence starts after preflight, D:381) | ABR refused "a fenced operation cannot be abandoned" (R:452-453); STOP needs no fence selection (R:479); fenced actions need a head fence (R:276-282) | W | **new** |
| X3 | Retry of an adapter-proved safe retry refuses at preflight | journals `Failed KnownNoEffect` (D:356-370) | ABR (R:610-611) | E† | F57 |
| X4 | Unfenced execute returns `KnownNoEffect` | `Failed KnownNoEffect` (D:399-415) | RES; ABR (R:610-611) | E† | F37 |
| X5 | Fenced execute returns `KnownNoEffect` | `Ambiguous`, fence marked unresolved (D:400-402) | FEN-V / FEN-B per capability (rows K18, K19) | E | — |
| X6 | Fence acquisition or exclusion fails before effect | `Ambiguous` "data fence acquisition…" (D:383-391) | FNR (R:415-442) without head fence; FEN-C (FR:96-115) with one | E | — |
| X7 | Fenced op: intent recorded, then the claim is lost (D:377-379) or the process dies before `acquireDataFence` | `IntentRecorded`, no head fence, no `Ambiguous` event | FNR needs the last event `Ambiguous` with the fence prefix (R:418-427); RTY needs no fence selection (R:583); fenced actions need a head fence (R:276-282); ABR needs `Pending`/`KnownNoEffect` (R:295-298); maintenance recovery is always `Unresolved` (MA:229-236); live-restore recovery proves only a completed restore (LA:281-298) | W | **new** |
| X8 | Unfenced op: intent recorded, claim lost or crash before the write | `IntentRecorded` → adapter recovery sees "not landed" | column O2 of each adapter row | — | — |
| X9 | Verified effect, but the `Completed` append fails (D:463-464) | `IntentRecorded` → adapter sees "landed" | column O3 of each adapter row | — | — |
| X10 | Adapter identity/version or native bundle drift (D:153-161, 332-334) | `StoppedAmbiguous`, no event | rerun with the reviewed binary | N (environmental) | — |
| X11 | Fence capability changed between review and apply (D:335-344) | `StoppedFailed`, no event; ABR refused (R:384) | reviewed binary | N (environmental) | — |
| X12 | Head/journal write fails while converging (TX:134-148) | `fallbackResult` | RES re-runs convergence | E | F38 |
| X13 | Adapter answers `SafeToRetry` (no effect remains) but every retry ends `Ambiguous` again (deterministic provider rejection, an execute that cannot land, or a no-op stage whose verify cannot pass) | loop D:183-187 → D:416-425/433-442 | ABR admits only `Pending` or `Failed KnownNoEffect` (R:295-298); a proved-no-effect `Ambiguous` op has no abandon | W | **new** (general; instances below cite X13) |
| X14 | Any `releaseAbortedClaim` exit (ABR/APP/AVR/ADR/FEN-B/rollback-resume) on a review that carried retentions or migrations | CL:217-223 resets only `headAccepted := headConverged`; `headRetained` keeps the entries admission added (AD:226-230) | afterwards `loadInventoryHistory` refuses "active retained resource lacks a disjoint reviewed migration" (HI:172-189) for every plan/status; re-retirement also refused "retained resource already has a historical incarnation" (AD:141-143) | S (global) | **new** |
| X15 | Any `releaseAbortedClaim` exit while another scope is stopped-unconverged (accepted ≠ converged after STOP) | CL:222 reverts **every** scope's accepted revision, not just the aborted review's | the stopped scope loses its accepted revision; its created members become `unverified-owner` (CH:711-716); a never-converged scope vanishes from history with its PVC | S (other scope) | **new** |
| X16 | `releaseAbortedClaim` after earlier ops of the same review created objects at fixed addresses (application, site, database, task, broker scopes; not fresh-ID restores) | created objects carry the ownership stamp but are not accepted | planning refuses `unverified-owner` (CH:711-716); adoption accepts only unstamped objects (CH:717-720); no collection exists for unaccepted objects; runbook promises "a separate reviewed recovery" that does not exist (`docs/runbooks/inventory-operations.md:188-191`, R:625) | S (scope) | **new** |
| X17 | STOP requested on a review that changes more than one scope | — | `incompleteApplicationOnlyReview` requires exactly one changed scope (HI:396-397) | W when the landing never becomes Ready | **new** |

## 4. Recovery totality grid

Each cell: verdict, deciding decision, cite. `ABR†` etc. means E† through that exit. Rows marked *(ctx)* split by scope context because the stop rule depends on it.

### 4.1 Kubernetes (ordinary adapter, K:173-490; transport KR:161-242)

| ID | Kind (context) | Action | O1a | O1b | O2 | O3 | O4 | O5 | O6 | O7 | O8 | O9 | O10 | O11 | O12 | Tracker |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| K1 | Namespace, ConfigMap, Secret, core Service, PVC, SA/RBAC, ResourceQuota, NetworkPolicy, CronJob, Trigger, other kinds without readiness | Create | E† PND→ABR [1] | W SR loop X13 [2] | E SR (K:333-334; deterministic absence KR:153,156) | E PC (K:312-314) | E | N [3] | N [3] | E PC on stamped replacement (F60 record); W UR if unstamped (K:384) | E SR→re-create | W UR (K:384) [4] | N | T UR (K:384) | N | F35, F60 |
| K2 | CRD, Certificate, ClusterIssuer (platform) | Create | E† [1] | W X13 [2] | E SR | E PC | E | W UR: kind not in AR list (K:355-360); STOP refuses Platform (HI:397) | N | E (F60) | E SR | W [4] | N | T | T UR until Ready | **new** |
| K3a | Deployment (application worker) | Create | E† [1] | W X13 | E SR | E PC | E | W: AR (K:350-362) → D:270-320 stops; STOP admits only KService/preview DomainMapping/standalone StatefulSet (HI:426-442) | N | E (F60) | E SR | W [4] | N | T | T rollout→AR→resume | **new** (F63-adjacent) |
| K3b | Deployment (platform bootstrap) | Create | E† [1] | W X13 | E SR | E PC | E | E via BRR only for cloud bootstrap with a registry-credential cause (EX:670-679, R:145-234, D:199-264); otherwise W (HI:397 Platform) | N | E (F60) | E SR | W [4] | N | T | T | F14, F15; **new** (non-registry cause) |
| K4a | StatefulSet (standalone database) | Create | E† [1] | W X13 | E SR | E PC | E | E STOP: AR (K:356-358) + HI:372-387, 437-440 (see follow-up F1) | N | E (F60) | E SR | W [4] | N | T | T | F59 |
| K4b | StatefulSet (application database) | Create | E† [1] | W X13 | E SR | E PC | E | W: STOP admits a StatefulSet only in a Standalone scope (HI:439-440) | N | E (F60) | E SR | W [4] | N | T | T | **new** |
| K4c | StatefulSet (broker with topics) | Create | E† [1] | W X13 | E SR | E PC | E | W: create path needs every op on KubernetesExecutor (HI:404) | N | E | E | W | N | T | T | F59 Gap B |
| K4d | StatefulSet (restore scratch, Redis) | Create | E† [1] | W X13 | E SR | E PC | E | W when unready without a container exit (unschedulable): AR, and STOP's create path needs all-`CreateResource` (HI:401-403) while `redisRestoreOnlyReview` allows `RunDeclaredOperation` (RP:276); ADR needs TF | E† TF via scratch probe (K:321-324, 346-349) → ADR (R:550-572, RP:237-278) | E | E | W | N | T | T | F36; **new** (unready-not-failed) |
| K5a | Knative Service (application) | Create | E† [1] | W X13 | E SR | E PC | E | E STOP create path (HI:400-424, 432-433) — W if the review also has a non-create companion (F65 wt), a non-Kubernetes op such as a topic Verify or CDN record (HI:404, CH:492-500), or changes two scopes (X17) | N | E: AR/PC on stamped replacement | E SR | W [4] | N | T | T | F16, F65(wt); **new** (non-K8s companion) |
| K5b | Knative Service (site, Standalone `site-*`) | Create | E† [1] | W X13 | E SR | E PC | E | W: KService admitted only for Application (HI:432-433); site scopes are Standalone (`Site.hs:928,1163,1210`) | N | E | E | W | N | T | T | **new** |
| K5c | Knative Service (site preview, `site-preview-*`) | Create | E† [1] | W X13 | E SR | E PC | E | W (as K5b; only the preview route is admitted, HI:434-436) | N | E | E | W | N | T | T | **new** (F29 covers the route) |
| K6a | DomainMapping (preview route) | Create | E† [1] | W X13 | E SR | E PC | E | E STOP (HI:434-436) | N | E | E | W | N | T | T | F29, F16 |
| K6b | DomainMapping (app or site custom domain) | Create | E† [1] | W X13 | E SR | E PC | E | W: non-preview DomainMapping refused (HI:434-436) | N | E | E | W | N | T | T | **new** |
| K7a | Job (scheduled prune) | Create | E† [1] | W X13 | E SR | E PC | E | T running→UR→resume | E† TF (K:374-383) → APP (RP:64-106) | E | E SR | W | E† APP | T | T | F09, F12, F13 |
| K7b | Job (volume restore) | Create | E† | W X13 | E SR | E PC | E | T | E† TF → AVR (RP:108-174) | E | E | W | E† AVR | T | T | — |
| K7c | Job (database restore, PostgreSQL) | Create | E† | W X13 | E SR | E PC | E | T | E† TF → ADR (RP:176-231) | E | E | W | E† ADR | T | T | F22 |
| K7d | Job (manual backup, `backup.id`) | Create | E† | W X13 | E SR | E PC + receipt (K:414-438); W UR if the receipt is permanently unreadable [5] | E | T | W: TF, no abandon shape (R:506-572) | E | E | W | W | T | T | **new** |
| K7e | Job (volume backup, `volume-backup.id`) | Create | E† | W X13 | E SR | E PC; W [5] | E | T | W (as K7d) | E | E | W | W | T | T | **new** |
| K7f | Job (manual prune, `prune.backup.scope`) | Create | E† | W X13 | E SR | E PC | E | T | W: APP requires `scheduled.prune.backup.scope` (RP:102-106) | E | E | W | W partial deletion | T | T | **new** |
| K7g | Job (volume prune) | Create | E† | W X13 | E SR | E PC | E | T | W (as K7f; `VolumePrune.hs:291-310`) | E | E | W | W | T | T | **new** |
| K7h | Job (scheduled ingest) | Create | E† | W X13 | E SR | E PC | E | T | W: no abandon shape | E | E | W | W | T | T | **new** |
| K7i | Job (task run, Standalone `task-run-*`, `TaskRun.hs:55`) | Create | E† | W X13 | E SR | E PC | E | T | W: no abandon shape; STOP needs AR | E | E | W | N | T | T | **new** |
| K7p | Any pinned data Job (backup, restore, prune, snapshot, volume restore/prune, ingest) | Create / RunDeclared | — | — | — | W if a pinned source changed after intent: pin check runs before classification (K:306-310, 439-489), so even a completed or failed Job is `Unresolved` and APP/AVR/ADR cannot see TF | — | — | — | W pinned source replaced | W pinned source deleted | W | — | T pinned source briefly NotReady (pin requires `KubernetesPresent`, K:484-489) | — | **new** |
| K8 | ConfigMap, Secret, core Service, PVC, Namespace, ResourceQuota, CronJob, NetworkPolicy | Update | E† PND (K:272-281) or KNE (foreign manager, KR:205-213; generated credential KR:208) | W X13 (unchanged before → SR) | E SR if the object is byte-identical; **W UR when only resourceVersion moved** (status/controller churn; full-state equality K:761-763 → K:384) | E PC | E | N | N | W UR (F56 is Knative-only, K:397-404) | W UR (K:384) | W UR (digest ≠ native) | N | T | N | F37; F64(wt) for O8; **new** for O2-churn and O7 |
| K9 | Deployment | Update | E† | W X13 | E SR / **W UR on status churn** | E PC | E | W UR (no Deployment branch) | N | W UR | W UR | W UR | N | T | T rollout → UR → resume | F63 (Deployment open); F64(wt); **new** (O2 churn, O7) |
| K10 | StatefulSet (database) | Update | E† | W X13 | E SR / W UR on churn | E PC | E | W UR | N | W UR | W UR | W UR | N | T | T | F63 (fixed only in wt); F64(wt); **new** (O2 churn, O7) |
| K11 | Knative Service (version-2 mutation; v3 takeover; v1 legacy) | Update | E† PND (configured identity changed) / KNE foreign manager | W X13 (v2 stable config unchanged → SR) | E SR (v2, K:333-334 with stable observation K:196-199); **W** for v1/v3 after status churn: NotReady→AR (K:363-373) but STOP needs `neverIntended` (HI:337), Present→UR | E PC | E | E LU (K:340-341) → STOP update path (HI:334-371) — W for a site Service (HI:336 Application only), a non-Kubernetes companion op (HI:341), a pending CronJob/DomainMapping/trigger/worker update companion (HI:353-367), or two changed scopes (X17) | N | E TR (K:342-345) → STOP (R:488); W for sites | W UR (K:384) | W: `confirmLandedUnready` refuses a foreign manager → UR (v2) or AR→STOP refused (v3) | N | T | T LU→resume when Ready | F54, F55, F56, F30, F37; F64(wt); **new** (site, non-K8s companion, v1/v3 churn) |
| K12 | Kinds outside `supportedUpdateAddress` (DomainMapping, Certificate, CRD, Job, RBAC, …) | Update | E† KNE (KR:202-204) | N | N | N | N | N | N | N | N | N | N | N | N | — |
| K13 | Any kind | Verify | E† PND/KNE (K:286-287) | N (no write) | E PC (unchanged) | E PC | E | E† prepare/preflight refuse NotReady except DomainMapping (K:529-549) | N | E† SR (K:339) → retry refused → KNE → ABR | E† (same) | E† (same) | N | T | N | F57 |
| K14 | Any kind | Adopt | E† PND | W X13 | E SR / W UR on churn | E PC | E | W UR: adopted readiness kind turns NotReady, no Adopt branch (K:333-384) | N | W UR | W UR (absent ≠ before Present) | W UR | N | T | T | **new** |
| K15 | Stateless namespaced kinds | Retire (collection) | E† PND/KNE | W X13 (delete refused by admission/webhook; before unchanged → SR) | E SR / W UR on churn (K:761-763) | E PC absent (K:778-800) | E | T finalizer pending → UR → resume; W if the finalizer never clears | N | W UR "remains present or was replaced" (K:804) | E PC | W UR (delete precondition fails, KR:192-201) | N | T | T `waitForCollection` timeout (KR:272-280) | **new** (O1b, O2 churn, O7, O9) |
| K16 | Knative Service / DomainMapping root | Retire via controller collection | E† | W X13 or UR | **W**: SR is converted to UR when the namespace graph changed (CO:156-163) | E PC + descendants gone (CO:146-155) | E | T descendants pending GC | N | W UR | E | W UR | N | T | T | F20 (closed); **new** (O2 graph change) |
| K17 | Job | RunDeclaredOperation | E† PND/KNE | N | E PC if complete | E PC | E | T running→UR | E†/W per shape exactly as K7a–K7i (TF K:374-383) | E | **W UR**: Job TTL-deleted or removed → absent, RunDeclared requires Present (K:728-734) | W | N | T | T | F13; **new** (O8) |
| K18 | Database maintenance session (fenced, `maintenance`) | OpenMaintenanceSession | **W** X2 (permanent refusal); T when refused only for lack of a TTY (MA:77-85) | E: KNE → fenced Ambiguous → FEN-V → resolve terminates clients → PC (MF:156-186) | E FEN-V | E FEN-V | E | N | N | **W**: database pod replaced during the session; resolve observes clients by the old pod UID → UR; no backup hook for FEN-B (MF factory `Nothing Nothing`); fence stays held | N | N | N | T | E FEN-V terminates lingering clients | **new**; also X7, and fence in `Acquiring/Excluded` whose preflight now refuses: only FEN-C accepts those phases (FR:96-115, 316-321) → W **new** |
| K19 | Live PostgreSQL restore (fenced, `live-restore`) | RestoreLiveDatabase | **W** X2 | E† FEN-B restores the recovery backup (FR:147-257, LF:182-195) | E† FEN-B | E FEN-V PC (LA:281-298) | E | N | **W** recovery backup cannot be restored/verified: FEN-B fails, writers stay excluded | W target pod/PVC replaced: `exactTarget` refuses (LA:129, 203) | N | N | E† FEN-B | T | T | F22 (adjacent); **new** (O6, O7, X2, X7) |

### 4.2 KubernetesMigration (rename stages, KM:76-284)

Every migration review records migrated incarnations in `headRetained` at admission (AD:215-230), so **every** abandon exit of a rename lands in X14: global STUCK-IDLE. Those cells are marked S.

| ID | Stage / member | O1a | O1b | O2 | O3 | O4 | O5 | O6 | O7 | O8 | O9 | O10 | O11 | O12 | Tracker |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1 | PrepareDestination, credential / signing key (copy) | S (KNE/PND→ABR→X14) | W X13 (destination absent → SR, KM:267) | E SR | E PC (KM:268) | E | N | N | W UR: destination differs (KM:268) | E SR | W UR | N | T | N | F62 (source); **new** (X14, O7) |
| M2 | PrepareDestination, other members (base Create, KM:270) | S | W X13 | E SR | E PC | E | **W**: destination StatefulSet never Ready → AR; `continueReadiness` refuses non-create waiters (D:284-299); STOP refuses `MigrateResource` (HI:335, 403) | N | E (F60) | E SR | W | N | T | T | **new** |
| M3 | BackUpSource / RetainSource (no-op execute KM:224) | S (source changed → KNE KM:214) | N | E SR/PC (KM:284) | E PC | E | N | N | S: SR → retry refused → KNE → ABR → X14 | S (same) | S | N | T | N | F62; **new** (X14) |
| M4 | FenceWriters, volume / workload | S | W X13 | E SR (KM:275) | E PC (KM:274) | E | N | N | W UR: writer replaced → `writerOwned` fails (KM:275) | W UR | W | N | T | T writer pod still terminating → SR loop; W if it never stops | **new** |
| M5 | FenceWriters, schedule | S | W X13 | E SR (KM:280) | E PC (KM:279) | E | N | N | W UR (KM:280) | W UR | W | N | T | N | **new** |
| M6 | TransferState, volume (copy Job) | S | W X13 | E SR (KM:283) → re-run copy | E SR→re-run proves | E | N | W: failed copy → retry refuses inside the Job → Ambiguous (KM:221-223) → SR loop | E (copies a replacement — F62 harm, no wedge) | W | N | **W** partial copy: SR loop (X13) | T | T | F61, F62 |
| M7 | TransferState, credential / signing key | S | N | E PC/SR (KM:284) | E PC | E | N | N | W: verify fails → SR → no-op retry → loop (X13) | E | W | N | T | N | **new** (rare) |
| M8 | VerifyDestination / SwitchConsumers / AdmitWrites (no-op execute KM:224; verify KM:255-260) | S | N | E SR/PC | E PC | E | **W**: destination never Ready → SR (KM:284) → no-op retry → Ambiguous loop (X13) | N | W | W | W | N | T | T | **new** |

### 4.3 Other executors

| ID | Executor / kind | Action | O1a | O1b | O2 | O3 | O4 | O5 | O6 | O7 | O8 | O9 | O10 | O11 | O12 | Tracker |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| H1 | Helm release | Create | E† PND/KNE (HE:101-111) | W: install fails → release `failed` → `HelmUnready` (HER:129-130) → UR (HE:129); absent → SR loop (X13) | E SR (HE:128; deterministic absence HER:104) | E PC | E | **W** UR: status ≠ `deployed` | W UR | E PC (proof ignores UID, HE:200-205) | E SR | W UR (HelmForeign) | W UR partial install | T | T; **W** if Helm dies leaving `pending-install` | **new** |
| H2 | Helm release | Update | E† | W UR (failed upgrade) | E SR (HE:128) | E PC | E | W UR | W UR | W UR | W UR | W UR | W UR | T | T / W (`pending-upgrade`) | **new** |
| H3 | Helm release | Verify | E† | N | E SR | E PC | E | N | N | W UR (changed release) | W UR | W UR | N | T | N | F57 class (Helm not listed) |
| P1 | Pulumi saved plan | Create / Update | E† PND (PU:115-120) / KNE (PUR:183) | **W**: any `pulumi up` failure → Ambiguous (PUR:193) → UR unless preview converges (PUR:223-228) | **W** UR (never SR) | E PC (`preview --expect-no-changes`, PUR:211-221) | E | N | W | W UR (diff/replace) | W UR | N (identity guard) | **W** UR (partial apply, pending operations) | T | T lock held → UR → resume | **new** |
| P2 | Pulumi saved plan | Retire (collection) | E† KNE (PU:124-128, F33 recheck) | W UR (still present, PUR:196-210) | W UR | E PC | E | N | W | W UR | E PC | N | W UR | T | T | F33; **new** |
| P3 | Pulumi | Verify | E† | N | E PC | E PC | E | N | N | W UR (drift) | W UR | N | N | T | N | F57 class (Pulumi not listed); F39 |
| P4 | VM power (RunDeclared, VP) | RunDeclared | E† KNE (VP:321-327) | W UR: verify-only recovery (VP:212-215, 331-335) | **W** UR | E PC | E | N | W (VM never reaches target state) | W UR (instance changed) | W | N | N | T | T transition pending | **new** |
| P5 | Image-cache prune (RunDeclared, IP) | RunDeclared | E† KNE (IP:135-142) | W UR (IP:33-36, 146-150) | **W** UR | E PC | E | N | N | W UR (VM incarnation changed) | N | W UR (image became pinned/in use) | N | T | N | **new** |
| F1 | Cloud foundation (bucket / service / stack) | Create | E† PND/KNE (FO:113-121, 192-202) | W: absent → SR loop (X13); present partial → UR | E SR (FO:142) | E PC | E | N | N | N | E SR | W UR (FO:143) | **W** UR: bucket created but update/IAM not applied, or stack init without config (FO:145) | T | N | **new** |
| F2 | Cloud foundation | Update | E† | W UR | **W** UR: unlanded update observes the old digest (FO:145) | E PC | E | N | N | N | W UR (absent, FO:142 Create-only) | W UR | W UR | T | N | **new** |
| F3 | Cloud foundation | Verify / Adopt | E† | N | E PC | E PC | E | N | N | W UR | W UR | W UR | N | T | N | F57 class gap (Foundation listed) |
| HO1 | NixOS host activation (HO) | Update (activate) | E† PND (HO:139-155); transport Reverted/Before → KNE (HOR:160) | E† KNE (HOR:160) | E SR (Before/Reverted, HO:161-164) | E PC (Committed, HO:159-160) | E | T timer armed → UR (HO:165) → resume | E† when the transport reports the revert; **W** when every activation loses its transport (HOR:154) → SR loop (X13) | **W** UR instance changed (HO:167) | **W** UR host absent (HOR:146) | **W** UR closure switched outside review (HO:167) | N | T unreachable (HO:166) | T | **new** |
| AR1 | Artifact publication | Create / Update | E† PND (AR:128-135) / KNE (AR:84-86) | W X13 (missing → SR, AR:141) | E SR | E PC (AR:139-140) | E | N | N | W UR different digest (AR:142) | E SR | W UR ownership mismatch (AR:143) | N (content-addressed) | T | N | **new** |
| AR2 | Artifact publication | Verify | E† | note [6] | as AR1 | E PC | E | N | N | W UR | E SR (but execute may publish, [6]) | W UR | N | T | N | F57 class (Artifact not listed) |
| C1 | Attic cache | Create | E† PND/KNE (CA:82-104) | W: missing → SR loop; partial → UR | E SR (CA:126) | E PC (CA:124-125) | E | N | N | N | E SR | W UR foreign (CA:129) | **W** UR created without key/config (CA:128) | T | N | **new** |
| C2 | Attic cache | Update / RunDeclared | E† | W UR | **W** UR: unlanded configure sees the old config (CA:128) | E PC | E | N | N | N | W UR (CA:127) | W UR | W UR | T | N | **new** |
| B1 | Redpanda topic | Create | E† PND (BR:100-117) / KNE (BR:126) | W X13 (missing → SR, BR:158) | E SR | **W** UR "rpk cannot prove its creation incarnation" (BR:166) | E (inline verify) | N | N | W | E SR | N | N | T | N | **new** |
| B2 | Redpanda topic | Update (retention) | E† KNE (BR:137) | **W** UR (BR:159-161) | **W** UR | **W** UR | E | N | N | W | W | N | N | **W** (BR:160 precedes the unavailable case) | N | **new** |
| B3 | Redpanda topic | Verify | E† | N | E PC | E PC (BR:162-165) | E | N | N | W UR (BR:166) | W UR (BR:168) | N | N | T | N | F57 class gap (Broker listed) |
| D1 | Google Cloud DNS A record | Create | E† PND / KNE auth (DNR:169-177) | **W**: HTTP non-2xx → Ambiguous (DNR:206-210) → UR (DN:151) | **W** UR (missing is never SR) | **W** UR (Create not in DN:146-149) | E | N | N | W | W | W | N | **W** (no Create outcome ever resolves) | W change pending (DNR:212-213) → UR | **new** |
| D2 | Google Cloud DNS | Update | E† | W UR | W UR | W UR | E | N | N | W | W | W | N | W | W | **new** |
| D3 | Google Cloud DNS | Retire | E† | W UR | **W** UR (still present) | E PC (DN:145) | E | N | N | W | E PC | W | N | T | W | **new** |
| D4 | Google Cloud DNS | Verify (and no-op Update) | E† | N | E PC | E PC (DN:146-149) | E | N | N | W UR | W UR | W UR | N | T | N | F57 class gap (CDN listed) |
| CF1 | Cloudflare DNS record / ruleset / zone TLS | Create | E† PND/KNE (CF:161-169, CFR:180-190) | **W** Ambiguous (CFR:194-202) → UR (CF:219-223) | **W** UR | **W** UR | E | N | N | W | W | W | N | W | N | **new** |
| CF2 | Cloudflare | Update | E† | W | W | W | E | N | N | W | W | W | N | W | N | **new** |
| CF3 | Cloudflare | Retire | E† | W UR (CF:203) | **W** UR | E PC (CF:202) | E | N | N | W | E | W | N | T | N | **new** |
| CF4 | Cloudflare | Verify / Adopt / no-op Update | E† | N | E PC (CF:205-215) | E PC | E | N | N | W UR (CF:217) | W | W | N | T | N | F57 class gap (Cloudflare listed) |
| CP1 | CDN cache purge (RunDeclared) | RunDeclared | E† PND/KNE (CP:162-176) | **W** UR: no receipt (CP:125-130, 145-160) | **W** UR | **W** UR when the receipt write failed after provider acceptance (CP:189-190) | E | N | N | N | N | N | N | T | N | F21 (closed, no-replay by design); **new** (no exit) |
| AC1 | Access tuple (grant / revoke) | Create / Update | E† KNE incl. HTTP 412 (ACR:149-157, AC:303-317) | **W** UR (ACR:162 → AC:321-325) | **W** UR | E PC (AC:379-385) | E | N | N | W UR (holder UID changed, AC:381) | W | W | N | T | N | **new** |
| AC2 | Access tuple | Verify | E† | N | E PC | E PC | E | N | N | W UR | W UR | W UR | N | T | N | F57 class (Access not listed) |
| MO | Manifest-only observer (retained host/artifact) | any | N: never executes (`Command.hs:952-962`) | | | | | | | | | | | | | — |
| GH | GitHubRelease publication | — | N: not an inventory `Adapter`; outside the journal | | | | | | | | | | | | | — |

### 4.4 Follow-up cells after an exit (reachability of the next review)

| ID | After | Next step | Verdict | Cite | Tracker |
|---|---|---|---|---|---|
| F1 | STOP of a standalone database while a durable create (e.g. `backup-signing-key`) never started | corrected review or retirement | S: never-started creates are derived only for Application scopes | HI:496; CH:724-743 | F59 Gap A |
| F2 | STOP of an unready StatefulSet/Deployment create | corrected review must update an unready object | S: Update of a NotReady object is admitted only for a Knative Service | K:535-540 | F63 (StatefulSet fixed only in wt) |
| F3 | STOP of an unready Knative Service / preview route | unchanged replan | E: refused by design; a corrected (changed) review updates it | K:536-540; HI:334-371 | F16, F30 |
| F4 | STOP of a first deploy whose release history was never created | retirement | E: absence proof for never-created stateless members | CH:759-766 (`buildAbsenceProofs`) | F58 |
| F5 | ABR / APP / AVR / ADR / FEN-B with earlier creates | replan same scope | S | X16 | **new** |
| F6 | any `releaseAbortedClaim` on a review with retentions or migrations | any later command | S (global) | X14 | **new** |
| F7 | any `releaseAbortedClaim` while another scope is stopped | replan that scope | S | X15 | **new** |
| F8 | APP / AVR / ADR (fresh-ID restores and prunes) | new restore with a fresh ID | E (scratch objects leak, never collectable) | R:538, 561; `Command.hs:625-627` | F35, F36 |
| F9 | abandoned rename after PrepareDestination | re-plan the rename | S: destination address occupied (KM:133) — and X14 | KM:133 | **new** (F62-adjacent) |
| F10 | retirement of a full cloud context | collect VM / buckets | S: retained consumers pin producers; no host/artifact collection | `mp23-findings.md` F40 | F40 |

### 4.5 Notes

1. O1a for every row: preflight refusal on a first attempt stays `Pending` (D:371) → resume or ABR (R:612-616); an execute-time refusal is journalled `Failed KnownNoEffect` (D:399-415) → ABR (R:610-611). Both release through `releaseAbortedClaim`, so X14–X16 apply.
2. O1b for Kubernetes: any non-zero `kubectl` exit is `AdapterEffectAmbiguous` (KR:242), never `KnownNoEffect`. When the object is unchanged, recovery answers `SafeToRetry` (K:333-334), resume resubmits, and a deterministic rejection (invalid spec, quota, admission webhook) repeats forever: X13.
3. Only Job, CRD, Certificate, ClusterIssuer, Knative Service, DomainMapping, Deployment and StatefulSet have readiness (KR:614-625); other kinds are always Present.
4. O9 for Create/Adopt: a foreign edit after the object lands changes its digest; no recovery branch covers a drifted Create/Adopt (K:333-384) → UR.
5. K7d/K7e: completion requires reading the receipt from the completed pod (K:420-438). A pod garbage-collected after success leaves `Unresolved` permanently.
6. AR2: `executePlan` ignores the action and publishes when the artifact is missing (AR:77-86); a Verify can therefore write. Not a wedge by itself.

## 5. Counts

Tallied by script over every outcome cell of the grids in §4.1–4.3 (73 rows × 13 outcomes = 949 cells, minus 8 "—" cells in K7p and 2 reference-only cells in AR2 = 939 counted; rows MO and GH excluded), plus the 17 driver cells X1–X17 (X8 and X9 are pointers to the O2/O3 columns; X10 and X11 are N/A) and the 10 follow-up cells F1–F10. A mixed cell (for example "E SR / W UR on churn", or "E … ; W for sites") is counted under its worst verdict.

| Verdict | Grid §4.1–4.3 | Driver X | Follow-up F | Total |
|---|---|---|---|---|
| EXIT (E, E†, T) | 437 | 6 | 3 | **446** |
| WEDGE | 277 | 4 | 0 | **281** |
| STUCK-IDLE | 11 | 3 | 7 | **21** |
| N/A | 214 | 2 | 0 | 216 |

Tracking:
- **WEDGE, tracked: 33.** K4c-O5 (F59 Gap B); K5a-O5 (F65 wt); K8/K9/K10/K11-O8 (F64 wt); K9/K10-O5 (F63); K11-O5 (F55 class gap); K11-O9 (F56 note); M6-O6/O10 (F61); every W of F3, B3, D4, CF4 (F57 class gap as listed) and of H3, P3, AR2, AC2 (same F57 class, executors not listed).
- **WEDGE, untracked: 248** (244 grid cells + X2, X7, X13, X17). Every O1b "W X13" cell and every O9 W cell is untracked, even in rows that carry a tracker ID for another column.
- **STUCK-IDLE, tracked: 3** (F1 = F59 Gap A, F2 = F63, F10 = F40). **Untracked: 18** (X14–X16, F5, F6, F7, F9, and the 11 M-row abandon cells, which are instances of X14).
- E† cells are exits, but each one is exposed to X14–X16.

## 6. Untracked WEDGE and STUCK-IDLE cells (unknown remaining defects)

Grouped by the code location that decides them.

**Driver / exit policy**
- U1 X13: `SafeToRetry` followed by a deterministic `Ambiguous` retry loops forever; ABR requires `Pending` or `Failed KnownNoEffect` (R:295-298). Instances: every O1b "W X13" cell (Kubernetes create/update/delete rejected by the API server, KR:242), H1, F1, AR1, C1, B1, HO1-O6, M4/M6/M7/M8.
- U2 X2: fenced op with a persistent preflight refusal — ABR refuses fenced ops (R:452-453).
- U3 X7: fenced op with intent recorded but no fence reserved (lost claim D:377-379 or crash) — FNR keys on an `Ambiguous` event detail prefix (R:418-427).
- U4 K18: maintenance fence held after the database pod is replaced, or fence in `Acquiring/Excluded` with a now-refusing preflight (FR:96-115, 316-321).
- U5 K19-O6/O7: live restore whose recovery backup cannot be restored, or whose target was replaced — writers stay excluded.
- U6 X17: STOP refuses any review that changed more than one scope (HI:396-397).

**Head release (`releaseAbortedClaim`, CL:200-224)**
- U7 X14 (global STUCK-IDLE): reverts `headAccepted` but keeps retained/migrated incarnations from admission (AD:226-230) → `loadInventoryHistory` refuses (HI:172-189). Reached by abandoning any review with retentions (an app deploy that removes a member) and by every abandoned rename.
- U8 X15: reverts every stopped scope's accepted revision, not just the aborted review's (CL:222).
- U9 X16: earlier creates become stamped-but-unaccepted → `unverified-owner` forever (CH:711-716); the promised "separate reviewed recovery" does not exist.

**Stop rule (`incompleteApplicationOnlyReview`, HI:288-444)**
- U10 K5b/K5c/K11 for sites: Knative Service create/update in a Standalone site scope (HI:336, 432-433).
- U11 K5a/K11: application review carrying a non-Kubernetes op (topic `VerifyResource` from `requiredTopics`, CH:492-500; CDN DNS record) — HI:341, 404.
- U12 K6b: non-preview DomainMapping create (HI:434-436).
- U13 K3a/K3b/K2: Deployment, Certificate, ClusterIssuer, CRD creates that never become Ready (application workers and platform scopes, except the F15 registry cause).
- U14 K4b: application-scope database StatefulSet create (HI:439-440 Standalone only).
- U15 K4d, M2: unready-without-failure restore scratch and rename destination StatefulSets (STOP needs all-create reviews; `continueReadiness` only for Deployments, D:284-299).

**Kubernetes adapter recovery (K:304-384)**
- U16 K8/K9/K10/K14/K15 O2: an unlanded update/adopt/delete whose object's resourceVersion moved (status or controller churn) → full-state equality (K:761-763) → UR.
- U17 K8/K9/K10/K14/K15 O7: replaced target for non-Knative kinds (F56 is Knative-only).
- U18 K1–K6/K14 O9: foreign edit after a create/adopt lands → UR (apply-time F37 class).
- U19 K7d–K7i O6: failed Job with no abandon shape: manual backup, volume backup, manual prune, volume prune (APP needs `scheduled.prune.backup.scope`, RP:102-106), scheduled ingest, task run.
- U20 K7p: pin check before classification (K:306-310) — a changed pinned source makes even a finished Job `Unresolved` and hides TF from APP/AVR/ADR.
- U21 K7d/K7e O3: receipt unreadable after a successful backup Job.
- U22 K14 O5/O8, K16 O2 (SR converted to UR when the namespace graph changed, CO:161), K17 O8 (Job TTL-deleted before RunDeclared).

**Provider adapters whose recovery never answers SafeToRetry for "not landed"**
- U23 Pulumi P1/P2 (PUR:193, 223-228), VM power P4, image prune P5.
- U24 Google DNS D1–D3 (DN:139-152), Cloudflare CF1–CF3 (CF:195-223), CDN purge CP1 (CP:125-130).
- U25 Broker B1-O3 (BR:166), B2 all outcomes (BR:159-161).
- U26 Cache C1-O10, C2 (CA:118-131); Foundation F1-O10, F2 (FO:134-145).
- U27 Helm H1/H2 unready, failed or partial releases (HE:121-130, HER:129-130).
- U28 Host HO1 O7/O8/O9 (HO:157-167).
- U29 Access AC1 O1b/O2/O7 (AC:321-325).
- U30 F57 class beyond its listed executors: Helm H3, Pulumi P3, Artifact AR2, Access AC2.

**Migration**
- U31 M1/M4/M5 O7 (destination or writer replaced → UR), M8 destination never Ready (no-op retry loop).

## 7. Where exits are decided (candidates for one general rule)

| # | Location | What it decides |
|---|---|---|
| 1 | D:169-194 (`ordinaryRecovery`) | which decisions resume may act on; four decisions just stop |
| 2 | D:270-320 (`continueReadiness`) | readiness waits: only stateless Deployment creates may proceed |
| 3 | D:353-371 | whether a refusal is journalled (`KnownNoEffect`) or left `Pending` |
| 4 | R:283-311 | state gate for every operator action (`recoverableState` RP:299-308; ABR state rule R:295-303) |
| 5 | R:415-460 | fence-specific gates: FNR detail-prefix match; fenced ABR refusal (R:452-453) |
| 6 | R:477-592 | the action × decision table (STOP, APP/AVR/ADR, ACC, RTY, BRR) |
| 7 | RP:64-278 | review-shape predicates for the three terminal-failure abandons |
| 8 | HI:288-444 | STOP shape rule (scope kind, executor, member kind, companion rule, single changed scope) |
| 9 | HI:473-568 | never-started-create proof (Application only) for the follow-up review |
| 10 | FR:91-321 | fence phase × action table |
| 11 | CL:170-224 | what each exit leaves in the head (abort resets only `headAccepted`) |
| 12 | Each adapter's `adapterRecover` (K:304-384, KM:262-284, CO:156-163, HE:121-130, PUR:223-228, VP:212-215, IP:33-36, FO:134-145, HO:157-167, AR:137-144, CA:118-131, BR:152-169, DN:139-152, CF:195-223, CP:125-130, AC:321-325, MA:229-236, MF:156-186, LA:281-298) | mapping provider facts to decisions |
| 13 | CH:707-758 (`classifyDesired`) | whether the post-exit state is plannable (`unverified-owner`, `durable-resource-missing`, NotReady refusals) |

A general rule could replace rows 4–8: each adapter returns a typed *settlement* — {proved effect E, proved no effect, landed-but-unaccepted with identity, unknown} — and the driver offers exactly two kernel exits for any non-unknown settlement: *complete* (effect proved) and *end without convergence* (effect proved absent, or present with a recorded identity that the head keeps as owned-unaccepted). That exit must restore only the aborted review's own scopes, and revert its own retentions and migrations (fixing X14–X16). Only `unknown` should wedge, and it should be produced only when the provider truly cannot be read. Today most adapters return `Unresolved` for "proved not landed" (the U23–U29 group). Most WEDGE cells above come from those adapters plus the shape predicates in rows 7–8.
