# C — Physical identity and incarnation handling: exhaustive inventory

Snapshot: `m1` = master `09241d35` (read-only; no builds, no edits). Packages `cli/nagarectl` and `cli/nagare-dsl`. Paths are relative to `cli/` unless noted. Everything here is inferred from source unless marked otherwise. No test was run.

Method: every file that mentions `PhysicalIdentity`, `uid`, `physical`, `incarnation`, the `Observed*`/`ConfirmedAbsent` constructors, `headIncarnations`, `headRetained`, `headCollected` or `fencePhysical` (about 120 files) was read at each site. The review was split into four partitions (core, Kubernetes and migration, data plane, other executors). Their full per-site tables are Parts 0, A, B and C below; this front section consolidates them.

Source key: **(a)** recorded incarnation (`headIncarnations`, or `headRetained`/`headCollected` for non-accepted members); **(b)** fresh observation; **(c)** the create's own result; **(d)** identity carried by a review, proof, receipt or prepare-time pin (its origin is given per row).
Verdicts: **SAFE** (compared with the record, or the record is the source); **LAUNDER** (a fresh observation that could be an out-of-band replacement becomes accepted, retained, ingested, backed up, restored from or into, or fenced); **FAIL-OPEN** (no record exists, so anything passes).

## 1. Ground truths

1. **There is no (c) source anywhere.** `Journal.hs:69` `Completed !ContentDigest` and `Adapter.hs:150-154` `AdapterExecution` carry no identity. `KubernetesRuntime.hs:187-188,233` discards `kubectl create` output. `KubernetesMigration.hs:464-471,558` (`copySecret`) is a second create path that also discards output. `CloudflareRuntime.hs:200,217-223` ignores the POST's record ID.
2. **The record is narrow.** `Execute/Incarnations.hs:56-63` records only `KubernetesExecutor` members that are `Durable` or `apps/StatefulSet`. Everything else has no accepted-incarnation record.
3. **The record has four readers, three of them F49 or F51 additions:**
   - status: `Status.hs:304-315` and `:649-665`;
   - retention proofs: `Plan/Changes.hs:388`;
   - receipt listing, freshness and escrow: app `Data/ScheduledReceipts.hs:259-263`;
   - ingestion: `ScheduledIngest.hs:165-170` via app `Data/ScheduledReceipts.hs:551`.

   Each passes when there is no record (`maybe False` or `maybe True`, or `findWithDefault`). No adapter, migration planner, backup, restore, fence, maintenance or collection path reads it.
4. **The record has one writer, with one choke point.** `Execute/Transaction.hs:143-144` calls `convergedIncarnations`, which feeds `Claims.releaseClaimWith` (`Execute/Claims.hs:108-145`). Its value is a fresh observation at convergence (`Incarnations.hs:74-84`); an unavailable observation records nothing.
5. **Ownership is a copyable annotation stamp.** A same-name `kubectl create` from a saved object reads as `ObservedPresent newUid` (`Adapters/Kubernetes.hs:203-233`, `KubernetesRuntime.hs:557-609`). Every Kubernetes precondition UID is taken from a planning or prepare-time observation (`Adapters/Kubernetes.hs:241-244`, `validateBefore` `:529-575`). That catches a replacement during an operation, never one made before planning.

## 2. LAUNDER and FAIL-OPEN paths tagged with existing findings

| Finding | Paths (Part/row → file:line) |
|---|---|
| **F60** (fresh observation recorded at convergence; no create identity) | 0.4.1 `Execute/Incarnations.hs:47-84` (Create → `Established`); 0.4.5 `:74-84` (an unavailable observation records nothing); 0.4.6 `:100-104` (a drifted object is bound); A33/A34 `KubernetesRuntime.hs:187-188,233,302-356` (output discarded; readiness waited for by name); A18/A23 `Adapters/Kubernetes.hs:296-314,805-812` (verify and recover accept any same-stamp object after a create); A21 `:414-438` (backup Job); A26 `:321-349` (scratch); A57–A63 `KubernetesMigration.hs:196-284,371-378,478-488` (rename destination never pinned; convergence binds whatever is live, also **F52**'s surviving mutant); C11 `CloudflareRuntime.hs:200,217-223` (stateless) |
| **F60 / F59** | A29 `Adapters/Kubernetes.hs:350-362`: `RecoveryAwaitingReadiness` treats any same-stamp StatefulSet as "the exact created workload". The follow-up review's Verify then binds it `Proved` into an empty record. |
| **F49 known limit** (unrecorded members pass; first Update/Verify binds) | 0.2.1 `Plan/Changes.hs:388` (fallback to the observed UID); 0.2.6 `Plan/Changes.hs:683-760`; 0.2.9 transfer `Plan/Lifecycle.hs:310-326`; 0.4.4 `Incarnations.hs` `Proved`; 0.6.1 `Status.hs:656`; S2/S5/S6/S8/S11 `ScheduledReceipts.hs:259-281,360-395`, `ScheduledIngest.hs:165-170,326-328`; R3 app `Data/Restore.hs:440-450`; L5 `LiveRestore.hs:620-633`; A9/A11/A37 (prepare preconditions from observation) |
| **F62** (rename source not compared with record) | 0.2.4 `Plan/Changes.hs:309-320`; 0.2.12 `Plan/Lifecycle.hs:240-261`; A48 `KubernetesMigration.hs:601-611`; A49 `Migration.hs:96-122` (canonical: `history` is in scope, `headIncarnations` unused); 0.3.4 `Execute/Admission.hs:216-226` (written to `headRetained`); 0.2.16 `Plan/Validation.hs:180-200`; A51/A53 inherit. **Writer variant not named in F62:** A52 `KubernetesMigration.hs:124,131,162` (writer StatefulSet UID from prepare, outside the stage digest, so a replaced writer is the one fenced). |
| **F52** | 0.6.4 `Status.hs:304-315` (comparison skipped for moved members during the transaction, including the source); 0.4.3 `Incarnations.hs:93-96` (destination bound from the convergence observation; no test asserts it, as the F52 verification notes) |
| **F51** (closed for recorded members) | Its harm persists for every unrecorded kind through the `findWithDefault` fallback at `Plan/Changes.hs:388`: hosts, Pulumi, broker topics, Cloudflare, Helm, and Kubernetes stateless members (C2). |
| **F33** (Verifying) | Residual C4 `CloudCollection.hs:191-229`: the stack `id` is name-shaped and read from unrefreshed state, so a same-name GCP recreation passes the recheck and is deleted. |
| **F57** class gap | C12 `Access.hs:318-325,376-385`: Access is missing from F57's executor list. This is a wedge, not a launder. |

## 3. Untagged (new) paths

Severity is my estimate. "Data" means a wrong recovery point, a wrong restore target, or data loss is reachable.

| ID | Sev | Path | Sites |
|---|---|---|---|
| **N1** | P2 (exit) | **Retirement of a replaced, recorded member is always refused at admission.** Since F51, the retention proof names the record (`Plan/Changes.hs:388`). Admission then requires `live == ObservedPresent (retentionPhysical proof)` (`Execute/Admission.hs:180-191`), so it refuses with a generic `retention-observation` and discards the reason (`:199`). This contradicts F51's implementation note ("Retirement is not refused") and ADR 22's documented exit, "retire and recreate the database" (`docs/adr/0022-…md:1626`). The recovery model cannot see it: `test/InventoryRecoveryModelSpec.hs:479-494` maps an admission refusal with no active transaction to `Done`. The F51 regression therefore passes because retirement never happens. Data stays safe, but a replaced database scope has no supported exit (no rebind, retire refused, collection needs `Stateless`). | 0.3.2 |
| **N2** | P2 (data) | **Nothing refuses work on a member whose live UID differs from its record.** Planning (`Plan/Changes.hs:683-760`) and prepare (`Adapters/Kubernetes.hs:241-244,529-575`) proceed. Update, Verify, maintenance, live restore and backups land on the replacement. The scope is marked converged (`Claims.hs:128-132`) while status says `replaced-incarnation`. | 0.2.6, A9, A11 |
| **N3** | P2 (data) | **Manual `db backup` source is pinned from a fresh observation and never compared with the record.** A backup of an empty replacement becomes an accepted recovery point. This is F49's harm through the manual path. | B1–B4 app `Data/Backup.hs:166-189`; `Backup.hs:104-146` |
| **N4** | P2 (data) | **Volume snapshot source PVC (Durable, recorded) is never compared.** | V1–V2 app `Commands/Storage.hs:279-300`; `Backup.hs:150-175,489-491` |
| **N5** | P2 (data/auth) | **The backup signing Secret (Durable, recorded, nagare-dsl `Resource/Database.hs:199`) is never compared** at listing, ingestion, escrow or live restore. The HMAC key is read by Secret name, unbound to the observed UID. | S3/S4/S9/S13/S14/L6 `ScheduledReceipts.hs:256,289,298-304,523-529`; `ScheduledIngest.hs:248-249,443-450`; app `Data/SigningKeyEscrow.hs:75-92`; `LiveRestore.hs:673-678` |
| **N6** | P1–P2 (data) | **Restore targets, scratch and live, are pinned from a fresh observation.** A live restore overwrites whatever is live. `LiveRestore.hs:459-473` compares two fresh observations, so a replacement made before both backups passes. | R2/R6/L1/L2/L4/L7 app `Data/Restore.hs:338-348,687-711,739-741` |
| **N7** | P2 (data) | **Data-fence capture binds fresh identity** (`DataFence/KubernetesCapture.hs:224`). `DataFence.hs:440-470` `validRequest` has the head in scope but never compares `fencePhysical` with `headIncarnations`. Every later fence check (`LiveRestoreFence.hs:128-131`, `MaintenanceFence.hs:114-117`) inherits it. This is the cheapest single point to close N6 and maintenance. | D1, D3 |
| **N8** | P2 | **Kubernetes collection's DELETE precondition is the prepare-time UID** (`KubernetesRuntime.hs:192-201`, `Collection/Adapter.hs:194-197`). It is never tied to the collection proof's retained UID, so it is F33's Kubernetes analogue: only Pulumi receives `runtimeCollectionPhysical` (app `Inventory/Execution.hs:213-224`, `Inventory/Adapters.hs:501-568`). The comment at `KubernetesReview.hs:46` ("loads their exact retained incarnation") is wrong: only the spec is loaded. Cloudflare has the same shape (C10 `Adapters/Cloudflare.hs:150-158`, stateless). | A35, A43, A72, C10 |
| **N9** | P2 | **Adopt and Update verification and recovery ignore `mutationBefore`'s UID** (`Adapters/Kubernetes.hs:805-812`, `:304-314`). Adoption's record is the convergence observation, not the reviewed `adoptionPhysical` (`Lifecycle.hs:97-111` vs `Incarnations.hs:94`). F60's five steps cover only creates. | A12, A18, A23, 0.4.2 |
| **N10** | P2 | **A stopped application leaves its created durable members unrecorded.** `releaseStoppedApplicationClaim` (`Claims.hs:170-195`) never binds, and the corrected review's Verify becomes their first, fresh binding. F60 is reached through the F16, F55 and F59 stops; F60 does not name this path. | 0.4.10 |
| **N11** | P3 | **`copySecret` is a second create path** (`KubernetesMigration.hs:464-471`) that F60's step 1 omits. | A59 |
| **N12** | P3 | **Manual and volume restore never compare the backup's source UID with the target** (`Restore.hs:283-300`, `VolumeRestore.hs:380-393,475-495`). This is asymmetric with the scheduled path. | R4, V5 |
| **N13** | latent | **`MaintenanceRequest` carries caller-supplied UIDs** (`Maintenance.hs:40-45`); only tests construct it today. | M1, M2 |
| **N14** | P2 | **A `retention = Delete` database's PVC and credential are `Stateless`** (nagare-dsl `Resource/Database.hs:87,95`), so they are unrecorded although they hold live, backed-up data. The F49 PVC check fails open for them; only the StatefulSet record remains. | §5 |
| **N15** | P2 | **Host VM:** the real numeric GCE ID is observed (`scripts/inventory-host-transport.sh:95-102`) but never recorded. A recreated VM reads converged, and the next activation targets it. | C1 `Adapters/HostRuntime.hs:79-135` |
| **N16** | P2 | **Pulumi observe and verify read unrefreshed state.** A GCP-side replacement is invisible. | C3 `Adapters/PulumiRuntime.hs:70-85,211-221` |
| **N17** | P2 | **GCS bucket and Pulumi stack identity is the name.** A recreated, empty backend bucket reads converged. | C5, C6 `Adapters/FoundationRuntime.hs:99-124,147-197,438-443` |
| **N18** | P2 | **Broker topics have no incarnation**, and the broker StatefulSet UID in the topic's identity is not checked against the StatefulSet record. A recreated, emptied topic reads converged. | C7 `Adapters/Broker.hs:139-187`, `BrokerRuntime.hs:147-164` |
| **N19** | P3 | **The Attic cache signing key is not identity.** A recreated cache with a new key reads converged. | C8 `Adapters/CacheRuntime.hs:66-71`, `Adapters/Cache.hs:105-131` |
| **N20** | P3 (low confidence) | **Artifact observation drops the content digest.** | C9 `Adapters/ArtifactRuntime.hs:174-178` |
| **N21** | P3 | **Status does not compare `ObservedReplacementRequired uid` with the record** (`Status.hs:668-674`), so a replaced member reports `immutable-replacement-required`. **Accepted-member health is probed on the replacement's UID** and overlaid on a `replaced-incarnation` finding (app `Commands/Inventory/Status.hs:355-368,405-412`), unlike retained health (`Status.hs:217-231`). | 0.6.2, 0.6.7 |
| **N22** | P3 | **The scheduled-prune in-flight check keys on the live CronJob UID** (app `Inventory/PruneEvidence.hs:172-179`), so Jobs of a replaced predecessor CronJob are invisible. | P4 |

Also observed: `ObservedChild … PhysicalIdentity` (nagare-dsl `Resource/Inventory.hs:153`) is never constructed in production (dormant). `classifyDrift` without records (`Status.hs:644-645`) has no production caller.

## 4. What the single structural fix closes

The fix is F60's five steps (UID captured from the create, carried in `AdapterExecution`, journalled in `Completed`, compared by verify and recovery, bound by `Incarnations` from the journal with a mismatch refused), plus "every consumer reads identity only through one checked accessor".

**F60's steps alone close:**
- F60 itself: 0.4.1, and A18, A23, A33 and A34 for creates;
- the A29 path to an empty record;
- the convergence fail-open for created members (0.4.5);
- the rename destination (A57–A63), which also gives F52's surviving mutant a check.

**Only if extended:**
- N11: `copySecret` must join step 1.
- N9: the adopt patch response and the Update before-UID must be journalled and bound; F60's text is create-only.
- N10: step 5 must also bind from the journal at `releaseStoppedApplicationClaim`, not only at convergence.

**The checked accessor does most of the remaining work, if it refuses on mismatch:**
- **Accepted-member identity:** F62 (0.2.4, A49) and its writer variant A52, N2, N3, N4, N5, N6, N7, N12, N13 and N21. Today every one of these paths reads no record at all.
- **N8:** only if the accessor also governs `headRetained` and the Kubernetes DELETE precondition is taken from it.

**It does not close the following:**
- **Members with no record from a Nagare create or adopt:** stores predating F49, bootstrap or legacy imports, and the `Proved` first binding (0.4.4). The accessor must then choose between fail-open, which keeps the launder, and fail-closed, which needs a reviewed "bind current object" operation that does not exist.
- **N1:** retirement of a replaced member needs an exit policy, either a reviewed rebind or retention that marks the recorded UID replaced. A stricter identity check makes N1 worse, not better. The model's `classify` must also stop treating admission refusals as `Done`.
- **Unrecorded kinds:** N14–N20 and the stateless Kubernetes kinds in §5. The record must widen, and each provider needs a real incarnation:
  - the GCE numeric ID;
  - the bucket's `projectNumber` and `timeCreated`;
  - the Attic public key;
  - a live describe or `pulumi refresh` instead of state.

  Topics may have no usable identity at all.
- **F52 address keying:** records stay keyed by resource ID only (`Store.hs:185`).
- **TOCTOU:** reads such as backup or copy Jobs reading a PVC, and Pulumi name-based deletes, have no provider CAS. Checks narrow the window but cannot remove it.
- **Wedges** (F57, C12) are exit defects, not identity defects.

## 5. Kinds with no identity record where replacement still matters

- **Kubernetes, unrecorded:**
  - the PVC and credential of a `retention = Delete` database (N14);
  - the backup CronJob, the receipt producer, whose UID is pinned fresh into ingestion (S9) and keys the prune in-flight check (N22);
  - backup, restore and prune Jobs: each Job UID becomes the backup ID and receipt anchor (B7, R5, L3, V4, V6, P1, P6). This is low harm because content is digest-bound.
  - the release-history ConfigMap, which holds release history;
  - the Services, NetworkPolicies and writers captured by fences, bound only within one fence (D2).
  - Knative Services and Deployments are harmless (F56 rationale).
- **Other executors:**
  - the Host VM, whose disk holds k3s state, local-path PVC data, host keys and the age key (N15);
  - Pulumi resources, including the collectible GCE instance, which is declared Stateless despite its disk (N16, C4);
  - GCS buckets, including the Pulumi backend bucket (N17);
  - the Pulumi stack (N17);
  - broker topics (N18);
  - the Attic signing key (N19);
  - artifacts (N20).
- **Harmless or content-checked:** Cloudflare and Google DNS, Helm releases, access tuples, enabled services.

---

# Per-site tables

> **Label mapping.** Partition tables use their own local N-labels; the global IDs in §3 supersede them. Part 0: local N1→N1, N2→N9, N3/N4→N21. Part A: local N1→N2, N2→N9, N3→N8, N4→N11. Part B and C labels are row IDs (B1…, S…, R…, L…, D…, M…, V…, P…, C1…C12) and map as listed in §3.

## Part 0 — Core: store, planning, admission, convergence, status (parent)

Paths relative to `cli/`. Source key: (a) recorded incarnation (`headIncarnations`) or retained/tombstone record; (b) fresh observation; (c) create's own result; (d) review-carried identity captured at planning.

### 0.1 Types and storage

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.1.1 | `nagare-dsl/src/Nagare/Resource/Types.hs:148-156` | `PhysicalIdentity` newtype; `mkPhysicalIdentity` only rejects empty/control chars | — | — | N/A (type) |
| 0.1.2 | `nagare-dsl/src/Nagare/Resource/Inventory.hs:153` | `ObservedChild … !PhysicalIdentity` declaration | — | — | N/A: never constructed in production (only pattern-matched at `Plan/Changes.hs:367`, `Execute/Admission.hs:308`, `Site.hs:1336`, `Application/Environment.hs:98`, app `Commands/Application.hs:505`). Dormant. |
| 0.1.3 | `nagare-dsl/src/Nagare/Resource/Inventory.hs:387-390`, `Plan/Types.hs:524-527` | `ClaimHolder` carries `retainedPhysical` for reserved claims | (a) retained | is the record | SAFE (identity only labels the reservation; `reserved-claim` check at `Inventory.hs:889` ignores it) |
| 0.1.4 | `Store.hs:125-131,256-280` | `RetainedIncarnation.retainedPhysical` (JSON `physical`) | written only by admission (0.3.4) | — | storage; see writers |
| 0.1.5 | `Store.hs:134-140,283-300` | `DeletionTombstone.tombstonePhysical` | copied from collection proof at `Execute/Transaction.hs:177-187` | — | storage |
| 0.1.6 | `Store.hs:159,330-417` | `DataFenceRecord.fencePhysical` | written by `DataFence/KubernetesCapture.hs:224` (Part B) | — | storage; see Part B |
| 0.1.7 | `Store.hs:185-187,451,477-478,513` | `headIncarnations :: Map ResourceId PhysicalIdentity` keyed by resource ID only (no address — F52 cause) | written only by `Claims.releaseClaimWith` | — | storage |
| 0.1.8 | `Journal.hs:69` | `Completed !ContentDigest` — no identity in the journal | — | — | confirms F60 premise: no (c) source exists |
| 0.1.9 | `Adapter.hs:150-154` | `AdapterExecution = AdapterEffectCompleted \| Failed \| Ambiguous` — carries no identity | — | — | confirms F60 premise |

### 0.2 Planning (review construction)

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.2.1 | `Plan/Changes.hs:384-388` `buildRetentionProofs` | Retention proof physical = `Map.findWithDefault physical resourceId headIncarnations` | (a) when recorded, else (b) | yes when a record exists (F51) | SAFE with record; **FAIL-OPEN** without (non-Kubernetes durable/identity members, stateless members, unrecorded Kubernetes members) — F49/F60 known limit |
| 0.2.2 | `Plan/Changes.hs:384` | requires `ObservedPresent` (not `Drifted`) to retain | (b) | — | N/A (shape) |
| 0.2.3 | `Plan/Changes.hs:391-410` `buildCollectionProofs` | collection proof only if live `ObservedPresent physical == retainedPhysical` | (a) retained vs (b) | yes | SAFE |
| 0.2.4 | `Plan/Changes.hs:309-320` `buildMigrationProofs` | `MigrationProof` physical = `validatedSourcePhysical` | (d) planning observation | **no** — never compared with `headIncarnations` | **LAUNDER** — F62 |
| 0.2.5 | `Plan/Changes.hs:328-340` `buildAbsenceProofs` | absence proof only for `ConfirmedAbsent` + stateless or never-started create | (b) absence | n/a (no identity) | SAFE (F58) |
| 0.2.6 | `Plan/Changes.hs:683-760` `classifyDesired` | accepted member `ObservedPresent/Drifted` of any UID → Verify/Update/no-op; never compared with record | (b) | no | SAFE for the record (Update/Verify bind only `Proved`, which never overwrites); **FAIL-OPEN** when no record (the Update/Verify becomes the first binding: F49 limit/F60). Note: a reviewed update is applied to, and its scope marked converged on, a replaced object without any planning signal. |
| 0.2.7 | `Plan/Changes.hs:710` | `ConfirmedAbsent` + no history → `CreateResource` | (b) | n/a | SAFE (creates nothing it trusts; record comes later — see 0.4.1) |
| 0.2.8 | `Plan/Changes.hs:717-719` | `ObservedUnowned` + `ApproveAdoption` → `AdoptResource` | (b) | n/a (no record by definition) | SAFE at planning (bound to digest of the observation, see 0.2.10) |
| 0.2.9 | `Plan/Changes.hs:700-702`, `Plan/Lifecycle.hs:310-326` | owner transfer → `VerifyResource`; requires `ObservedPresent _` of any UID | (b) | **no** | SAFE for record (`Proved` cannot overwrite; record keyed by resource ID survives the owner change); FAIL-OPEN if no record |
| 0.2.10 | `Lifecycle.hs:97-111` `decideAdoption` | operator's `adoptionPhysical` must equal fresh observation (`ObservedUnowned` or `ObservedPresent` for transfer) | (d) operator proposal vs (b) | not vs `headIncarnations` (transfer case) | SAFE at planning; the adopted UID is **not** what convergence records (0.4.2) |
| 0.2.11 | `Plan/Lifecycle.hs:141-150,290-303` | `lifecycleObservationDigest` binds decisions to the exact observation fact (incl. UID) | (b) | n/a | SAFE (staleness guard) |
| 0.2.12 | `Plan/Lifecycle.hs:156-173,240-261` | `migrationObservationDigest`; `sourceFact /= ObservedPresent validatedSourcePhysical` | (d)/(b) | **no** record comparison | **LAUNDER** — F62 |
| 0.2.13 | `Plan/Lifecycle.hs:327-341` | retirement requires `ObservedPresent _` of any UID, `notMember headRetained` | (b) | no (proof substitutes record, 0.2.1) | SAFE planning; but see 0.3.2 (admission then always refuses) |
| 0.2.14 | `Plan/Lifecycle.hs:342-356` | collection requires `physical == retainedPhysical` | (a) vs (b) | yes | SAFE |
| 0.2.15 | `Plan/Validation.hs:115-135,243-258` `verifyActiveReview` | active review retention/migration/collection proofs must equal `headRetained`/`headCollected` | (a) | yes | SAFE |
| 0.2.16 | `Plan/Validation.hs:143-178,180-200` | retention/absence/collection/migration review checks vs head | (a) retained/tombstone | retention/migration proof physical **not** compared with `headIncarnations` | SAFE for retention (planner used record); migration: F62 |
| 0.2.17 | `Plan/History.hs:135-185,236-250` | loads retained/collected; requires active-retained migration proof physical == retained physical | (a) | yes | SAFE (consistency) |

### 0.3 Admission

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.3.1 | `Execute/Admission.hs:137-150` | retention/migration proof base checks (owner, revision, not already retained/collected) | (a) | identity not compared with `headIncarnations` | SAFE given 0.2.1; migration F62 |
| 0.3.2 | `Execute/Admission.hs:180-191,199` | re-observes retained members; requires live `== ObservedPresent (retentionPhysical proof)`; refuses `retention-observation` with generic text (the `Left` reason is discarded at :199) | (b) vs proof | indirectly (proof = record) | SAFE for data, but **NEW (N1)**: since F51 the proof names the record, so retiring a member that was replaced *before planning* is **always refused at admission**. ADR 22 (`docs/adr/0022…md:1626`) documents "retire and recreate the database" as the exit, and F51's update says "Retirement is not refused". The recovery model cannot see it: `test/InventoryRecoveryModelSpec.hs:479-494` maps an admission refusal with no active transaction to `Done`. |
| 0.3.3 | `Execute/Admission.hs:192-195` | absence-proved members must still be `ConfirmedAbsent` | (b) | n/a | SAFE (F58) |
| 0.3.4 | `Execute/Admission.hs:200-230` | writes `headRetained` from retention proofs and migration proofs | (a) for retentions with record; (d) for migrations | migrations: **no** | retention SAFE/FAIL-OPEN per 0.2.1; migration **LAUNDER** — F62 |
| 0.3.5 | `Execute/Admission.hs:375-394` `migrationAdmissionChecks` | runs the BackUpSource adapter preflight under the lock (source identity recheck) | (d) vs (b) | no record | see Part A; F62 |
| 0.3.6 | `Execute/Admission.hs:280-365` `retentionCoverage` | `holdsNoData` from `Stateless` or never-started creates | — | n/a | SAFE (F58) |

### 0.4 Convergence binding

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.4.1 | `Execute/Incarnations.hs:47-84` `convergedIncarnations` (Create → `Established`) | binds the convergence observation's UID for created Kubernetes durable/StatefulSet members | **(b)** fresh, after effects | no — replaces any record | **LAUNDER** — F60 (one `Replaced` fault between create and convergence) |
| 0.4.2 | same, Adopt → `Established` | adoption establishes the convergence observation, not the reviewed `adoptionPhysical` (0.2.10) | (b) | no | **LAUNDER** — F60 class; adoption sub-case not named in F60 (**N2**) |
| 0.4.3 | same, `MigrateResource` → `Established` (`:93-96`) | migration destination bound from convergence observation | (b) | no (old record dropped first) | **LAUNDER** — F60 class / F52 (F52's survived mutant: nothing asserts the destination record) |
| 0.4.4 | same, Update/Verify → `Proved` | bound only if no record | (b) | yes (never overwrites) | SAFE with record; **FAIL-OPEN** without — F49 known limit / F60 |
| 0.4.5 | `Execute/Incarnations.hs:74-84` | `Left _` observation → `Map.empty`; member missing → nothing recorded; convergence still succeeds | — | — | **FAIL-OPEN** — F49 limit / F60 |
| 0.4.6 | `Execute/Incarnations.hs:100-104` `present` | `ObservedDrifted` at convergence is bound like `ObservedPresent` | (b) | no | minor: a member drifted at convergence is recorded (still FAIL-OPEN family, F60) |
| 0.4.7 | `Execute/Incarnations.hs:56-63` | only `KubernetesExecutor` members that are `Durable` or `apps/StatefulSet` are recorded | — | — | scope limit: every other kind is **FAIL-OPEN by design** (see §Unrecorded kinds) |
| 0.4.8 | `Execute/Incarnations.hs:110-115` `bindIncarnations` | Established overwrites, Proved inserts-if-absent | — | — | SAFE (the rule), feeds 0.4.1-0.4.4 |
| 0.4.9 | `Execute/Claims.hs:108-145` `releaseClaimWith` | drops migrated/retained/collected records then binds; scope marked converged irrespective of any record mismatch | (a)+(b) | partially | SAFE except via 0.4.1-0.4.5 |
| 0.4.10 | `Execute/Claims.hs:170-195` `releaseStoppedApplicationClaim` | stop leaves `headIncarnations` untouched; durable members created by the stopped review stay **unrecorded** | — | — | **FAIL-OPEN**: a later Verify/Update is their first (fresh) binding — F60/F49 limit, reached via F16/F55/F59 stops (not named in F60) |
| 0.4.11 | `Execute/Claims.hs:200-225` `releaseAbortedClaim` | rollback restores accepted map; incarnations/retained untouched | — | — | N/A for identity |
| 0.4.12 | `Execute/Transaction.hs:143-144` | the only call of `convergedIncarnations`/`releaseClaimWith` with bindings | — | — | single choke point (good for the structural fix) |
| 0.4.13 | `Execute/Transaction.hs:150-203` `finalizeCollections` | tombstone from collection proof only if proof == retained record | (a) | yes | SAFE |

### 0.5 Recovery decisions carrying physical

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.5.1 | `Execute/Recovery.hs:467-488` | stop marker digest over native bytes + UID from `RecoveryAwaitingReadiness`/`LandedUnready`/`TargetReplaced` | (b) via adapter | no, but accepts nothing | SAFE (marker only; no record written; scope keeps last accepted) |
| 0.5.2 | `Execute/Recovery.hs:506-560` | abandon terminal prune/volume-restore/database-restore Jobs: UID only in journal text | (b) | n/a | SAFE (text only) |
| 0.5.3 | `Execute/RecoveryPolicy.hs:139-140,209-210,265-266` | restore target StatefulSet/PVC UID fields named in recovery policy | see Part B | — | see Part B |

### 0.6 Status

| # | Site | What | Source | Compared with record? | Verdict |
|---|---|---|---|---|---|
| 0.6.1 | `Status.hs:649-665` `classifyDriftWith` | `ObservedPresent/Drifted` with UID ≠ record → `replaced-incarnation` | (a) vs (b) | yes | SAFE with record; **FAIL-OPEN** without (`:656` `maybe False`) — F49 limit |
| 0.6.2 | `Status.hs:668-674` | `ObservedReplacementRequired uid` is **not** compared with the record | (b) | no | minor **NEW (N3)**: a replaced member whose spec also needs replacement reports `immutable-replacement-required`, hiding `replaced-incarnation`; not converged, so no launder |
| 0.6.3 | `Status.hs:644-645` `classifyDrift` | record-less variant | — | — | exported, no production caller (only `classifyDriftWith` used, app `Commands/Inventory/Status.hs:414`) |
| 0.6.4 | `Status.hs:304-315` `statusIncarnations` | drops records of members moved by the active migration | (a) | skipped by design | FAIL-OPEN window by design (F52); also drops comparison for the migration **source** during the transaction |
| 0.6.5 | `Status.hs:174-211` `retainedFindings` | retained present/drifted/replacement-required only if UID == retained | (a) | yes | SAFE |
| 0.6.6 | `Status.hs:217-231` `retainedHealthTargets` | retained health probed only on the exact retained UID | (a) | yes | SAFE |
| 0.6.7 | app `Commands/Inventory/Status.hs:355-368,405-412` | health of an accepted member is probed on whatever UID is live and overlaid on the finding | (b) | no | minor **NEW (N4)**: a `replaced-incarnation` finding carries the replacement's readiness (`HealthReady`), unlike the retained path (0.6.6) which refuses to "lend" health. Cosmetic; category stays `replaced-incarnation`. |
| 0.6.8 | app `Commands/Inventory/Status.hs:329-350` | Helm health uses any observed physical | (b) | no record exists (Helm unrecorded) | FAIL-OPEN by design (unrecorded kind) |
| 0.6.9 | app `Commands/Inventory/Status.hs:116,432,606` | collected tombstone lookups | (a) | yes | SAFE |

## Partition A — Kubernetes adapter, runtime, collection, migration, preview cleanup

Snapshot: `m1` at master `09241d35`. Paths are relative to `cli/`. Source legend:
- **(a)** the recorded incarnation: `headIncarnations`, `headRetained`, a tombstone, a fence record, or a review-carried physical that was itself checked against the record.
- **(b)** a fresh observation.
- **(c)** the create's own result.
- **(d)** a review-carried physical captured at planning from an observation.

"Cmp rec?" asks whether the value is compared with `headIncarnations` (or with `headRetained` for collection) before it is trusted.

**Ground truths for this partition:**
- `AdapterExecution` (`nagarectl/src/Nagare/Inventory/Adapter.hs:150-154`) carries no physical identity, and `adapterVerify` returns only a `ContentDigest` (`Adapter.hs:183`). The interface has no channel for (c).
- No module in this partition reads `headIncarnations`. The only readers repo-wide are `Status.hs`, `Plan/Changes.hs:388`, the CLI `ScheduledReceipts.hs` and `Claims.hs`. So no adapter-level site here compares with the incarnation record. Every Kubernetes UID used for a precondition is a planning-time observation (d), or a fresh one (b).
- Ownership is the copyable annotation stamp (`nagare.dev/context-id`, `resource-id`, `spec-digest`). An out-of-band `kubectl create` from a saved object, as in the F49 drill, therefore reads as `ObservedPresent`.

## Observation and types

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A1 | `nagarectl/src/Nagare/Inventory/Adapter.hs:53-61` | `ResourceObservation` constructors carry `PhysicalIdentity` (`ObservedPresent`, `Drifted`, `ReplacementRequired`, `Unowned`, `Foreign`) | (b) | no, by design (the producer) | N/A as a producer. It is the raw input every LAUNDER below trusts. |
| A2 | `Adapter.hs:156-172` | `RecoveryAwaitingReadiness`, `LandedUnready`, `TargetReplaced` and `TerminalFailure` carry a physical | (b) | no | See A27-A33 |
| A3 | `Adapter.hs:150-154` | `AdapterExecution` has no identity field. `AdapterEffectCompleted` is nullary. | — | — | Root of F60: no (c) path exists. |
| A4 | `Adapter.hs:85-95` (`migrationObservationSet`) | pairs the source and destination observations | (b) | no | N/A (a container). It feeds A44. |
| A5 | `Adapters/Kubernetes.hs:203-233` `toObservation` | maps a `KubernetesState` to an observation. Ownership is `owner == Just resource` from the stamp; the UID is passed through. | (b) | no | Producer. A same-stamp replacement becomes `ObservedPresent uid'`. No comparison here; consumers must do it. |
| A6 | `Adapters/KubernetesRuntime.hs:557-609` `parseObservedWithConfiguration` | reads `metadata.uid` and `resourceVersion`. The owner comes from the annotations, and only when the context matches. | (b) | no | Producer. The stamp is copyable, so ownership does not prove the incarnation. |
| A7 | `KubernetesRuntime.hs:360-384` `observeKubernetesHealth` | a readiness probe bound to the caller's UID. It returns `Nothing` if the UID differs. | caller's (b) | n/a | SAFE: it never attaches readiness across incarnations. |
| A8 | `KubernetesRuntime.hs:413-425` `observeCacheClientOutput` | passes the observed UID through unchanged | (b) | no | N/A (a ConfigMap, stateless) |

## Prepare, preflight and execute (`Adapters/Kubernetes.hs`)

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A9 | `Kubernetes.hs:241-244` (`prepare`) | `before <- kubernetesObserve` becomes `mutationBefore`, the UID and resourceVersion precondition for every action | (d), a fresh observation at prepare time (`Plan/Prepare.hs:98`). It is a second observation, separate from the planner's `ObservationSet`. | **no** | **LAUNDER** for data-bearing members. An Update, Verify, OpenMaintenanceSession, RestoreLiveDatabase or RunDeclaredOperation on a StatefulSet or PVC that was replaced out of band before planning is prepared against the replacement's UID. The write is conditional on the replacement, so the review "lands" on an object Nagare never accepted. The record is not rebound for Update or Verify, because `Proved` never overwrites. A member with no record binds the replacement (F49 known limit). Tags: F49 limit, F60. The prepare-side refusal is NEW (see N1). |
| A10 | `Kubernetes.hs:256-271` `prepareTakeover` | the `FieldTakeover` physical is the fresh observation and must equal the live read's UID and revision | (b), checked against (b) | no | SAFE for internal consistency (the two reads agree). Inherits A9's laundering when the member was replaced before planning. |
| A11 | `Kubernetes.hs:529-575` `validateBefore` | accepts Update, Verify, Retire, Maintenance and LiveRestore when the owner stamp, revision and digest match. Adopt requires `owner == Nothing`. Create requires absence. | (d) | **no** | LAUNDER (same as A9). It checks the stamp and digest, never the incarnation. |
| A12 | `Kubernetes.hs:533-534` (Adopt) | adoption needs an unstamped object with the desired digest. The adopted UID is reviewed in `mutationBefore`. | (d) | no record exists by definition | FAIL-OPEN by design: adoption is the act that establishes identity. Its reviewed UID is not what gets recorded (see A50 and N2). |
| A13 | `Kubernetes.hs:272-281` `preflight` | requires `current == mutationBefore` (`requireSameBefore`) | (b) vs (d) | no | SAFE against a change since review. It does not catch a replacement made before planning. |
| A14 | `Kubernetes.hs:282-295` `execute` | the same comparison, then a conditional write. Version 2 substitutes `mutationBefore = current` (Knative only). | (b) vs (d) | no | SAFE (time-of-check). The v2 substitution covers a Knative Service only: stateless, no record. |
| A15 | `Kubernetes.hs:728-767` `requireSameBefore` | Verify compares the UID, owner and digest with `mutationBefore`. Other actions use full `KubernetesState` equality. v2 compares the configured (uid, owner, digest). | (d) | no | SAFE relative to review. It never relates to the record. |
| A16 | `Kubernetes.hs:885-899` `orTakeover` | the takeover's physical must equal `mutationBefore`'s UID and revision | (d) | no | SAFE (internal binding) |
| A17 | `Kubernetes.hs:439-489` `verifyBackupSources`/`checkOne` | the live source StatefulSet and PVC UIDs must equal the pins in the Job native (manual backup, restore target, prune, volume snapshot, volume restore, volume prune credential, scheduled ingest) | the pins are (d). For manual backup they come from the fresh observation in `app/Nagare/Cli/Data/Backup.hs:166-172`, not from `headIncarnations`. | **no** at this site | SAFE against a change after review. **LAUNDER** upstream: a manual backup of a replaced database pins the replacement's UIDs. Fork B owns the pin provenance. Scheduled ingest is guarded by F49's check in `ScheduledIngest`. |

## Verify and recovery (`Adapters/Kubernetes.hs`)

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A18 | `Kubernetes.hs:296-303` `verify`, then `completionProof` at `:805-812` | non-Retire actions accept any `KubernetesPresent` whose stamp owner and digest match. The UID goes into the proof digest but is **not compared** with `mutationBefore`, and not with (c) for a create. | (b) | **no** | **LAUNDER**. After a Create, a same-stamp replacement verifies as the created object (F60). After an Update or Adopt, the reviewed before-UID is available in `mutationBefore`, but verify ignores it (N2). |
| A19 | `Kubernetes.hs:773-777` `completionProof` (Verify) | goes through `requireSameBefore`, so the UID must equal `mutationBefore` | (d) | no | SAFE relative to review |
| A20 | `Kubernetes.hs:778-804` `completionProof` (Retire) | absence plus `removedPhysical` from `mutationBefore` | (d) | indirect (see A35) | SAFE if `mutationBefore` equals the retained UID (A35) |
| A21 | `Kubernetes.hs:414-438` `verifiedProof` with backup receipt | `readBackupReceipt resource physical`, where `physical` is the fresh UID of the completed backup Job | (b); the Job is the op's own create | no record for Jobs | FAIL-OPEN, low harm. The receipt is read from any same-stamp completed Job with the reviewed digest. The created Job's UID is not captured (F60 class: Jobs are not in F60's text). The receipt still has to pass the source pins and the expectation. |
| A22 | `KubernetesRuntime.hs:690-760` `readCompletedJobContainerMessage` and `completedJobContainerMessageFromPodList` | the Pod must be controller-owned by exactly the given Job UID | the caller's (b) | n/a | SAFE (binds the Pod to the Job incarnation passed in) |
| A23 | `Kubernetes.hs:304-314` `recover` gives `RecoveryProvedComplete` | if `completionProof` succeeds on the fresh object, the operation is proved complete | (b) | **no** | **LAUNDER** for Create (F60: a lost-ack create plus a replacement proves complete). Update and Adopt get the same treatment (N2). |
| A24 | `Kubernetes.hs:316, 333-334` | `requireSameBefore mutation before` gives `RecoverySafeToRetry` | (b) vs (d) | no | SAFE |
| A25 | `Kubernetes.hs:339` (F57) | Verify is always safe to retry | — | — | SAFE (no write) |
| A26 | `Kubernetes.hs:321-324, 346-349` scratch StatefulSet terminal failure | `scratchFailed resource physical` probe, then `RecoveryTerminalFailure physical` | (b); the scratch create's own object | no record (the scratch never converges) | FAIL-OPEN, low harm: the UID is not tied to the create (F60 class). The outcome is abandonment, so nothing is accepted. |
| A27 | `Kubernetes.hs:328-332, 340-341, 385-393` `landedUpdate` and `RecoveryLandedUnready` (F54) | the live UID must equal `mutationBefore`'s, plus `confirmLandedUnready` | (d) | no | N/A (Knative Service, stateless, no record). SAFE relative to review. |
| A28 | `Kubernetes.hs:342-345, 397-404` `replacedUpdateTarget`, then `RecoveryTargetReplaced` (F56) | the live UID differs from `mutationBefore` but carries the stamp | (b) | no | N/A (Knative only, stateless). The stop accepts nothing. F56: the class gap for `KubernetesAbsent` is noted there. |
| A29 | `Kubernetes.hs:350-362` `RecoveryAwaitingReadiness` for a created Deployment, StatefulSet, Knative Service or DomainMapping (F16 and F59) | the owner and digest match and the before state was absent. **Any** same-stamp object qualifies. | (b) | **no** (a create has no record yet) | **FAIL-OPEN.** For a database StatefulSet (F59), a replacement made after a lost-ack create is treated as "the exact created workload" (the comment at `:159` claims this). The stop accepts nothing, but a corrected follow-up review then plans Update or Verify on the replacement. Its convergence binds it `Proved` into an empty record, which launders it. Tags: F60, F59. |
| A30 | `Kubernetes.hs:363-373` `RecoveryAwaitingReadiness` for an unready Knative update | the UID equals `mutationBefore`'s | (d) | no | N/A (stateless) |
| A31 | `Kubernetes.hs:374-383` `RecoveryTerminalFailure` for a Job create or run | the owner and digest of a failed Job | (b) | no record | N/A (a Job; the result is a known failure only) |
| A32 | `KubernetesRuntime.hs:229-241` | after takeover, `confirmTakeoverSettled` requires the same UID | (d) | no | SAFE |

## Runtime transport (`Adapters/KubernetesRuntime.hs`)

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A33 | `KubernetesRuntime.hs:187-188` (Create) | `kubectl create -f -`. The output, which contains the server-assigned UID, is **discarded** at `:233` `Right (ExitSuccess, _, _)`. | none; (c) **not captured** | — | Confirms F60's premise: no create path captures the UID. |
| A34 | `KubernetesRuntime.hs:302-356` `waitForReadiness` | `rollout status` or `wait --for=condition` **by name**, not by UID | address only | no | **LAUNDER window** (F60): readiness of a replacement created during the wait is reported as the effect's completion. |
| A35 | `KubernetesRuntime.hs:192-201` (Retire, via `KubernetesCollection.hs:17-43`) | a DELETE with preconditions `{uid, resourceVersion}` from `mutationBefore` | (d) from the **prepare-time** observation (`Plan/Prepare.hs:98`) | **not compared** with `reviewCollections`' proof physical. That proof was checked against `headRetained` from a different, earlier planning observation (`Plan/Lifecycle.hs:346`, `Plan/Changes.hs:402`). Admission checks the proof against `headRetained` (`Execute/Transaction.hs:160-172`), never the adapter's precondition. | **NEW (N3), narrow.** If a replacement occurs between the planner's observation and the adapter's prepare in the same planning run, the review deletes the replacement while its proof names the retained object. This is the Kubernetes analogue of F33: Pulumi got `runtimeCollectionPhysical`, Kubernetes has no equivalent. |
| A36 | `KubernetesRuntime.hs:189-191, 1260-1327` `adoptionPatch` | a JSON Patch `test` on `/metadata/uid` and `resourceVersion` equal to `mutationBefore`'s, plus a live re-read | (d) | n/a (adoption) | SAFE at the effect. The adopted UID is exact. |
| A37 | `KubernetesRuntime.hs:205-226, 1239-1256` `applyRequest`/`addPreconditions` | server-side apply with `metadata.uid` and `resourceVersion` from `mutationBefore` | (d) | **no** | SAFE against a concurrent replacement. It LAUNDERS through A9 when the replacement predates planning. |
| A38 | `KubernetesRuntime.hs:1332-1362` `servicePortPatch` | tests the UID and revision | (d) | no | N/A (a Service, stateless) |
| A39 | `KubernetesRuntime.hs:1377-1380` `verifyLiveOwnership`, then `KubernetesConfiguration.hs:65-77` `confirmReviewedFieldTakeover` | the live UID and revision must equal the precondition | (d) | no | SAFE (time-of-check) |
| A40 | `KubernetesConfiguration.hs:83-87` `confirmTakeoverSettled` | the same UID after the forced write | (d) | no | SAFE |
| A41 | `KubernetesConfiguration.hs:94-114` `confirmLandedUnready` | ownership, UID and revision, plus generation | (b) agreeing with (b) | no | N/A (Knative) |
| A42 | `KubernetesConfiguration.hs:119-122` `liveIdentity` | extracts the UID and resourceVersion | (b) | — | helper |

## Controller collection (`Collection/*`)

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A43 | `Collection/Adapter.hs:50-57, 194-197` `prepare`/`identityOf` | the parent node in the namespace snapshot must equal `mutationBefore`'s UID and version | (d) vs (b) | the same gap as A35 (no comparison with the collection proof) | SAFE between observations. **N3** applies (prepare-time UID vs proof). Knative Service or DomainMapping only, both stateless. |
| A44 | `Collection/Adapter.hs:83-102` `decode` | the authority's parent UID must equal `mutationBefore` | (d) | — | SAFE (internal binding) |
| A45 | `Collection/Adapter.hs:103-109, 117-125` preflight and execute | `checkCollectionBefore`, then a DELETE with preconditions from the authority's root UID | (d) | — | SAFE (time-of-check) |
| A46 | `Collection/Adapter.hs:146-155`, `Collection/Authority.hs:202-215` `checkCollectionComplete` | the address and the UIDs of the parent and descendants must be absent. New children under those UIDs refuse. | (d) | — | SAFE: it detects a replacement at the same address as "remain present or were replaced". |
| A47 | `Collection/Authority.hs:29-130, 172-174`, `Collection/Runtime.hs:71-78` | builds the graph keyed by UID and ownerReferences | (b) | — | SAFE (a descendant graph, not member identity) |

## Migration (rename)

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A48 | `Adapters/KubernetesMigration.hs:601-611` `renameProposal` | the source physical is taken from `ObservedPresent value` in the planning `MigrationObservationSet` | (b) at planning | **no** | **LAUNDER, F62.** The rename copies from, and later retains, a replaced source. |
| A49 | `Migration.hs:96-122` `validateMigrationProposal.checked` | `sourceFact == ObservedPresent (migrationSourcePhysical target)` compares the proposal with the **same** observation. The function has `history` in scope but never consults `headIncarnations`. | (b) vs (b) | **no** | **LAUNDER, F62** (the canonical site). It produces `ValidatedMigration.validatedSourcePhysical` (`Migration/Types.hs:39`), which enters the stage digest (`Migration/Types.hs:48-56`). Admission then writes it into `headRetained` (parent partition, `Execute/Admission.hs:218`). |
| A50 | `Plan/MigrationObservation.hs:26-40` | observes the source and destination through separate registries | (b) | no | N/A (the producer for A48 and A49) |
| A51 | `KubernetesMigration.hs:123, 130, 136-141` `prepareStage` | re-observes the owned source and recomputes the stage digest with the fresh physical. A mismatch with the reviewed digest refuses. | (b) vs (d) | no | SAFE against a change since review. It inherits A49 (F62). |
| A52 | `KubernetesMigration.hs:124, 131, 162` `writerPhysical` | the writer StatefulSet's UID comes from a prepare-time observation. It is **not** in the stage digest and is not compared with the record, nor with the StatefulSet member's own `sourcePhysical`. | (b) | **no** | **LAUNDER**, F62 (writer variant). The fence and the scale-to-zero target a replaced writer, so the real writer of a replaced source is never fenced. F62's text names the source PVC or StatefulSet, not the separate writer binding. |
| A53 | `KubernetesMigration.hs:348-359` `sourceOwned`/`sourceValue` | the live source UID must equal `bundle.sourcePhysical` | (d) | no | SAFE relative to review. F62 upstream. |
| A54 | `KubernetesMigration.hs:380-385` `writerOwned` | the live writer UID must equal `writerPhysical` | (d) | no | SAFE relative to review |
| A55 | `KubernetesMigration.hs:404-428` `fenceWriter` | a merge patch with `metadata.uid` equal to `writerPhysical` | (d) | no | SAFE (conditional) |
| A56 | `KubernetesMigration.hs:433-455` `suspendSchedule` | a patch with `uid` equal to `sourcePhysical` (the CronJob) | (d) | no | SAFE relative to review. The CronJob is stateless. |
| A57 | `KubernetesMigration.hs:371-378` `destinationOwned` | checks the stamp and the destination spec digest only. The destination UID is **never pinned**. | (b) | no ((c) not captured) | **LAUNDER**, F60 (migration variant). The destination created at PrepareDestination is not identified, so TransferState, verification and SwitchConsumers can each act on a different incarnation of the destination. The convergence binding (`Execute/Incarnations.hs` with `migrates`, F52 fix) then records whatever is live. |
| A58 | `KubernetesMigration.hs:196-199, 211-212` PrepareDestination | delegates to the base create (A33): UID discarded | (c) not captured | — | F60 |
| A59 | `KubernetesMigration.hs:464-471` `copySecret` | its own `kubectl create` of the destination credential or signing key, with the **output discarded** (`kubectlWrite`, `:558`) | (c) not captured | — | F60. Note that F60's five-step design names only `KubernetesRuntime`'s create, apply and replace paths. This second create path also needs step 1. |
| A60 | `KubernetesMigration.hs:478-488` `secretCopied` | the destination's data must equal the source's. The proof includes the fresh `destinationPhysical`. | (b) | no | LAUNDER (A57 class): data equality is checked on whatever destination is live. |
| A61 | `KubernetesMigration.hs:238-242, 255-260` verify proofs | `destinationPhysical` is the fresh UID, embedded in the proof digest and not compared | (b) | no | LAUNDER (A57, F60) |
| A62 | `KubernetesMigration.hs:490-519` `runTransfer` | reads the transfer Job's UID after it finishes, binds the Pod message to it, and deletes it with a UID precondition | (b); the op's own Job | n/a | SAFE for an ephemeral Job. A Job name collision is guarded by the operation label. |
| A63 | `KubernetesMigration.hs:263-284` `recover` | PrepareDestination delegates to base recovery (A23 and A29). TransferState is unconditionally safe to retry (F61). | (b) | no | LAUNDER via A23 (F60) |
| A64 | `Migration/PostgresRename.hs` (whole file) | the transfer script compares destination and source contents. It uses no UIDs. | — | — | N/A |

## Preview cleanup

| # | Site | What | Source | Cmp rec? | Verdict |
|---|---|---|---|---|---|
| A65 | `PreviewCleanup.hs:77-103` `parsePreviewAge` | the UID and creationTimestamp of the live Knative Service | (b) | no record (stateless) | N/A. The age belongs to that exact incarnation. |
| A66 | `PreviewCleanup.hs:147-153` `validatePreviewIncarnations`, called from `app/Nagare/Cli/Runtime/PreviewCleanup.hs:70-84` | the planner's observation must equal `ObservedPresent uid` from the age read | (b) vs (b) | no record | SAFE for consistency. FAIL-OPEN with respect to identity: an out-of-band replacement Service carrying the stamp is aged and retired as the preview. A recreated object is younger, so a stale verdict is unlikely, and the harm is low. |
| A67 | `PreviewCleanup.hs:107-134` `eligiblePreviewCollections` | selects retained preview members structurally. The comment at `:105-106` defers the UID binding to the collection planner. | (a) `headRetained` via `historyRetained` | — | SAFE (structural selection). Execution is subject to A35 (N3). |
| A68 | `app/Nagare/Cli/Runtime/PreviewCleanup.hs:53-61` | plans the collection through `planInventoryCollectionWith` (`Lifecycle.hs:346` binds the retained UID) | (a) | yes, at planning | SAFE apart from N3 |

## App wiring

| # | Site | What | Verdict |
|---|---|---|---|
| A69 | `app/Nagare/Cli/Inventory/Adapters.hs:110, 173, 501-568` | passes `runtimeCollectionPhysical` (from `CloudHistory`, which comes from `headRetained`) to Pulumi only. Kubernetes gets `readBackupReceiptFromCompletedPod` (A21). | Confirms N3: Kubernetes has no equivalent of `runtimeCollectionPhysical`. |
| A70 | `app/Nagare/Cli/Inventory/Execution.hs:222-224, 516`; `Planning.hs:240-247, 302` | Cloud collection physical (a), F33. Kubernetes collection loads only the retained *spec*, never its UID. | as above |
| A71 | `app/Nagare/Cli/Inventory/Workflow.hs:195-215` `acceptedMigrationNative` | loads the accepted source native for the rename. It reads no identity. | N/A |
| A72 | `KubernetesReview.hs:40-49` | the comment says the execution factory loads collected members' "exact retained incarnation". In fact it loads only the retained spec (A70). | Misleading comment. Supports N3. |
| — | `KubernetesSources.hs`, `KubernetesTransport.hs`, `ObservationNative.hs`, `PreviewOwnership.hs` | no identity sites | — |

## LAUNDER and FAIL-OPEN summary (partition A)

| Rows | Path | Tag |
|---|---|---|
| A33, A34, A18, A23, A58, A59, A21 (Job), A26 | Create: no UID captured (c); readiness by name; verification and recovery accept any same-stamp object | **F60** (A59, `copySecret`'s second create path, is missing from F60's step 1) |
| A29 | `RecoveryAwaitingReadiness` for a created StatefulSet trusts any same-stamp object; the follow-up review then binds it `Proved` into an empty record | **F60 / F59** |
| A57, A60, A61, A63 | Migration destination never pinned across stages; convergence records the live destination | **F60** (migration variant), adjacent to **F52** |
| A48, A49, A51, A53 | Rename source physical from the planning observation, never compared with `headIncarnations`, then written to `headRetained` | **F62** |
| A52 | Rename writer UID: prepare-time, outside the stage digest, never compared with the record | **F62** (writer variant, not named in F62) |
| A9, A11, A37, A17 (pins) | Update, Verify, Maintenance, LiveRestore and RunDeclaredOperation preconditions come from the planning observation, never compared with `headIncarnations`. The reviewed write lands on a replacement; record-less members bind it. | **F49 known limit**. **N1** (new): no refusal at planning or prepare |
| A18, A23 (Update and Adopt), A12 | Verification and recovery ignore the reviewed before-UID that is already in `mutationBefore`. Adoption's record is bound from the convergence observation, not from the adopted UID. | **N2** (new, an F60 extension: F60's design covers only creates) |
| A35, A43 | Kubernetes collection's DELETE precondition is the adapter's prepare-time UID, never compared with the collection proof or `headRetained` | **N3** (new; the Kubernetes analogue of F33) |
| A66 | A preview Service (stateless, no record) can be retired, and later collected, as an out-of-band replacement | FAIL-OPEN, low (a stateless kind with no record) |

**New, untagged:**
- **N1.** Planning and prepare never refuse an Update, Verify, Maintenance, LiveRestore or manual-backup operation on a data-bearing member whose live UID differs from `headIncarnations`. Status reports `replaced-incarnation`, yet the plan proceeds.
- **N2.** Verification and recovery of Update and Adopt ignore `mutationBefore`'s UID. Adoption records the fresh convergence observation instead of the reviewed adopted UID.
- **N3.** The Kubernetes collection precondition UID is not tied to the collection proof.
- **N4.** `copySecret` (`KubernetesMigration.hs:470`) is a second create path that F60's design does not list.

## Partition B — data plane (backup, receipts, restore, fences, maintenance, prune, escrow)

Snapshot: master `09241d35`. Paths relative to `cli/`. `S` = `nagarectl/src/Nagare/Inventory/`, `A` = `nagarectl/app/Nagare/Cli/`.

Source codes: **(a)** recorded incarnation (`headIncarnations`, `headRetained`, `headCollected` tombstone); **(b)** fresh observation; **(c)** the create's own result; **(d)** identity carried in a receipt, scope override, Job annotation or proof (origin given).

"Record?" = compared against the recorded incarnation before being trusted.

Key fact for this partition: `headIncarnations` is read in exactly two places here, `A/Data/ScheduledReceipts.hs:259-263` (listing, freshness, escrow via `resolveScheduledSource`) and `:551` → `S/ScheduledIngest.hs:167-170` (ingestion). Both compare **only the StatefulSet and PVC**, and both use `maybe True`, so a missing record passes. No other data-plane path reads the record: manual backup, volume snapshot, scratch restore, live restore, data fences, maintenance, the signing Secret, and the volume-restore target. They pin a fresh observation, then later recheck live against that pin. This catches a replacement *during* the operation, but not one that happened *before* planning.

## 1. Manual (on-demand) database backup

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| B1 | `A/Data/Backup.hs:166-171` | `db backup` plan: observes StatefulSet + PVC, takes `ObservedPresent uid` as `statefulUid`/`pvcUid` | b | **No** (only "present, not drifted"; `headIncarnations` never consulted) | **LAUNDER** | **NEW** (F49 fixed only scheduled ingestion; manual backup source is the same harm: a backup of an out-of-band replacement, possibly empty, becomes an accepted recovery point) |
| B2 | `A/Data/Backup.hs:173-189` → `S/Backup.hs:84-85,264-270,365-379,454-466` | Writes the fresh UIDs into the review proof (`backup.source.*.uid` overrides) and Job annotations | b→d | No | LAUNDER (propagates B1) | NEW (same as B1) |
| B3 | `S/Backup.hs:104-121` `manualBackupSourceProof` | Parses the pins back from the reviewed scope at apply | d (origin B1) | No | propagates B1 | NEW |
| B4 | `A/Inventory/SourceEvidence.hs:323-388` `loadReviewedBackupSourceNative` (partition-adjacent) | At apply, checks source scope revision and member kinds only, not UIDs against the record | d | No | propagates B1 | NEW |
| B5 | `S/Backup.hs:127-146` `manualBackupJobSourcePins` → `S/Adapters/Kubernetes.hs:440-475` `verifyBackupSources` | Executor rechecks live UID == review pin before submitting or resuming the Job | b vs d | No (pin, not record) | SAFE for replacement after review. Inherits B1 for replacement before review | — |
| B6 | `nagarectl/src/Nagare/Database/Backup.hs:283-309` | Backup pod reads live StatefulSet/PVC UIDs into the receipt `source` | b (in-pod) → d | No | N/A here (receipt content). Consumers decide | — |
| B7 | `A/Data/ManualReceipt.hs:131-158`, `S/ManualReceipt.hs:30,134`, `S/ManualReceiptSource.hs:42-100` | Manual receipt record binds `backup.job.uid` to the freshly observed completed Job (owner stamp + digest) | b | No record exists (a Job is stateless; `Incarnations.hs` records only Durable + StatefulSet) | FAIL-OPEN (stateless, low harm: Job content is digest-bound) | NEW-minor (stateless class) |

## 2. Scheduled receipts: listing, freshness, ingestion, escrow

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| S1 | `A/Data/ScheduledReceipts.hs:249-256` `resolveScheduledSource` | Observes StatefulSet, PVC, CronJob, signing Secret | b | see S2 | — | — |
| S2 | `A/Data/ScheduledReceipts.hs:259-263` | F49 check: live StatefulSet/PVC == `headIncarnations` | a vs b | Yes, but `maybe True` | SAFE when recorded, **FAIL-OPEN** when not | F49 limit / F60 |
| S3 | `A/Data/ScheduledReceipts.hs:256,289` | Signing Secret UID: fresh, returned unchecked. The signing Secret **is Durable** (`nagare-dsl/src/Nagare/Resource/Database.hs:199`), so it has an incarnation record that is ignored | b | **No** | **LAUNDER** | **NEW** |
| S4 | `A/Data/ScheduledReceipts.hs:298-304` (report), `:523-529` (ingest plan) | HMAC key read by Secret name (`readSecretField`), not bound to the observed UID or the record | b (unbound) | No | **LAUNDER** (receipts are authenticated with a key from a possibly replaced Secret; also TOCTOU against S3) | **NEW** (with S3) |
| S5 | `A/Data/ScheduledReceipts.hs:269-281` + `S/BackupReceipt.hs:80-90,184-185,378-388` | Receipt expectation built from live UIDs; receipt `source` must equal them | b(S2-checked) vs d(B6) | Transitively, via S2 | SAFE / FAIL-OPEN as S2 | F49 / F60 |
| S6 | `A/Data/ScheduledReceipts.hs:360-395` | Freshness counts accepted receipts via `scheduledIngestEvidenceMatches` (`S/ScheduledIngest.hs:103-120`, no UIDs), and pending receipts via S5 | d | via S2 | SAFE / FAIL-OPEN as S2 | F49 / F60 |
| S7 | `A/Data/ScheduledReceipts.hs:499-505` | Ingest plan observes the four sources | b | see S8 | — | — |
| S8 | `S/ScheduledIngest.hs:165-170` (fed by `A/Data/ScheduledReceipts.hs:551`) | F49 ingestion guard: StatefulSet/PVC == record, `maybe True` | a vs b | Yes, fail-open | SAFE / **FAIL-OPEN** | F49 limit / **F60** (one fault records the replacement, after which this passes) |
| S9 | `S/ScheduledIngest.hs:56-57,248-249,307-309,443-450` | Schedule (CronJob) and signing Secret UIDs pinned into the ingestion scope and Job | b | **No** (signing Secret has a record; the CronJob is stateless and has none) | **LAUNDER** (signing) / FAIL-OPEN (CronJob, stateless) | **NEW** (signing, same as S3) |
| S10 | `S/ScheduledIngest.hs:182-197` | Receipt run ID (`jobUid`) == requested backup ID | d (provider receipt) | n/a | SAFE (self-consistency) | — |
| S11 | `S/ScheduledIngest.hs:326-328` | Ingested scope records `scheduled.backup.source.*.uid` = S8-checked live UIDs | a-checked b → d | via S8 | SAFE / FAIL-OPEN as S8 | F60 |
| S12 | `S/ScheduledIngest.hs:549-570` → `S/Adapters/Kubernetes.hs:446-475` | Executor rechecks the four pins == live at apply/resume | b vs d | No (pin) | SAFE for replacement after plan. Signing inherits S9 | — |
| S13 | `A/Data/SigningKeyEscrow.hs:75-92` | Escrow binds signing Secret UID + key (the UID re-read matches S3's fresh UID), plus StatefulSet/PVC from S2 | b | Signing: **No**. StatefulSet/PVC: S2 (fail-open) | **LAUNDER** (escrows a replaced signing key as the database's key) | **NEW** (with S3) |
| S14 | `S/SigningKeyEscrow.hs:36-38,88-90,138-139`; `A/Data/SigningKeyEscrow.hs:113-140` | Offline verification uses the escrow-carried identity | d (origin S13) | No | inherits S13 | NEW |
| S15 | `S/ScheduledStore.hs:165-196` `readSecretFieldWithUid` | Returns the Secret UID with the value (mechanism) | b | n/a | N/A (tool; only S13 uses the UID) | — |
| S16 | `S/ScheduledReceipt.hs:176` | Comment only | — | — | N/A | — |

## 3. Restore (scratch / isolated, scheduled and manual)

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| R1 | `A/Data/Restore.hs:282-310` | Manual-receipt restore: receipt's `backup.job.uid` must equal `headRetained` or `headCollected` physical for the backup Job | a | **Yes** | SAFE (the retained Job UID was itself bound by `buildRetentionProofs` from a fresh observation, since Jobs have no incarnation record; parent's partition) | — |
| R2 | `A/Data/Restore.hs:338-348` | Restore target StatefulSet/PVC UIDs from fresh observation | b | **No** | **LAUNDER** (target pinned to whatever is live; a replaced database is accepted as the restore target) | **NEW** |
| R3 | `A/Data/Restore.hs:440-450` | Scheduled path: ingested `scheduled.backup.source.*.uid` must equal the live target | d(S11) vs b | Transitive via S8 | SAFE / FAIL-OPEN as S8 (this is the "isolated restore of A refused" check from F49) | F49 / F60 |
| R4 | `S/Restore.hs:283-300` (manual path in `compileManualRestoreScope`) | Manual backup: compares receipt db/namespace/engine/id, **not** `backup.source.*.uid` against the live target or the record | d | **No** | **FAIL-OPEN** (asymmetric with R3: a manual backup of incarnation X restores against target Y without a check) | **NEW** (minor; together with B1, a backup of a replacement restores freely) |
| R5 | `A/Data/Restore.hs:370-378`, `:389-404` | Backup Job UID observed (owner stamp + digest) or read from the manual-receipt override | b / d | No record (Job is stateless) | FAIL-OPEN (stateless, low) | stateless class |
| R6 | `S/Restore.hs:62-63,70-89,460-462,728-732` | Target UIDs from R2 → scope overrides and Job annotations; `manualRestoreTargetProof` reparses them | b→d | No | propagates R2 | NEW |
| R7 | `S/Restore.hs:94-113` `manualRestoreJobTargetPins` → `S/Adapters/Kubernetes.hs:443-475` | Executor rechecks live == pins | b vs d | No | SAFE after plan. Inherits R2 | — |
| R8 | `S/Adapters/RestoreScratch.hs:27-34,74-103` | Scratch pod failure detection matched by the scratch StatefulSet's UID | b/d (scratch is a new object) | n/a | N/A (scratch object, not an accepted incarnation) | — |

## 4. Live restore (writes into the accepted database)

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| L1 | `A/Data/Restore.hs:338-348,739-741` | Live target StatefulSet/PVC from fresh observation (same code as R2) | b | **No** | **LAUNDER** (overwrites whatever object is live; data fence and proof inherit it) | **NEW** (same root as R2) |
| L2 | `A/Data/Restore.hs:687-711` | StatefulSet writer pin built from fresh `statefulUid`; Pod UID observed | b | No (Pod/StatefulSet: the StatefulSet has a record; Pods are not recorded) | inherits L1 | NEW |
| L3 | `A/Data/Restore.hs:607-620`, `S/LiveRestore.hs:62,73,560,752` | Recovery backup Job UID (owner stamp + digest) | b | No record (Job) | FAIL-OPEN (stateless, low) | stateless class |
| L4 | `S/LiveRestore.hs:459-473` | Source and recovery manual backups' `backup.source.*.uid` must equal live target UIDs (L1) | d(B2) vs b | **No**: both sides are fresh observations made at different times | Consistency only. Refuses a replacement *between* backup and restore. A replacement *before* both backups (B1) passes | NEW (rooted in B1/L1) |
| L5 | `S/LiveRestore.hs:620-633` | Scheduled backup: ingested source UIDs == live target | d(S11) vs b | Transitive via S8 | SAFE / FAIL-OPEN as S8 | F60 |
| L6 | `S/LiveRestore.hs:673-678,765-767` | `scheduled.backup.schedule.uid` / `signing.uid` from the ingested scope | d(S9) | No | inherits S9 | NEW (signing) |
| L7 | `S/LiveRestore.hs:178-181,391-394` | Proof fixes target StatefulSet/PVC/Pod UIDs (from L1) | d | No | inherits L1 | NEW |
| L8 | `S/LiveRestoreFence.hs:112,124-131,172` | Fence check: `fencePhysical[stateful/pvc]` == proof UIDs; network pin Pod UID | d vs b(fence capture) | No | Consistency of two fresh observations. SAFE against change between plan and fence; inherits L1 | NEW (same root) |
| L9 | `S/LiveRestoreAdapter.hs:73-146` | Executor `present`: live UID == proof UID for backup Jobs, CronJob, signing Secret, StatefulSet, PVC, Pod | b vs d | No | SAFE after plan. Inherits L1/S9 | — |
| L10 | `S/LiveRestorePostgres.hs:213-227`, `S/LiveRestoreAdapter.hs:250,292` | Pod UID unchanged before and after the change | b vs d | n/a (Pod) | SAFE (intra-operation) | — |

## 5. Data fences (`headDataFence.fencePhysical`)

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| D1 | `S/DataFence/KubernetesCapture.hs:111-165,224` | `fencePhysical` = live PVC claim UID + Service UID + writer UIDs captured now | b | **No** | **LAUNDER** (the fence binds the live object as "the" target; every later fence check compares against this) | **NEW** |
| D2 | `S/DataFence/KubernetesCapture.hs:286-297,362-477` | Service and writer (StatefulSet, Deployment, CronJob, completed Job) UIDs captured | b | No | N/A for laundering: exclusion must target live writers. Only the target StatefulSet/PVC matter (D1) | — |
| D3 | `S/DataFence.hs:440-470` `validRequest` | Acquisition validates context, accepted map, non-empty physical, writer sets. **Has `headValue` in scope but never compares `fencePhysical` with `headIncarnations`** | b | **No** | **LAUNDER** (single cheapest place to close D1/L1/maintenance) | **NEW** |
| D4 | `S/DataFence.hs:279-284,314-319,346-351,361-366` | Release, exclusion proof, data proof: re-observed physical == `fencePhysical` | b vs b(D1) | No | SAFE against change during the fence. Inherits D1 | — |
| D5 | `S/DataFence/KubernetesExclusion.hs:243-244,404,429,924-929` | Maintenance Pod pin; `observeFencePhysical` returns the record when checks pass | b vs d | No | SAFE (intra-operation) | — |
| D6 | `S/DataFence/KubernetesIntent.hs:62-124,167,187-199,209-263,300-330` | Raw intent cross-checks claim, writer, service and job UIDs against `fencePhysical` | d vs d(D1) | No | SAFE (consistency). Inherits D1 | — |
| D7 | `S/DataFence/MountGuard.hs:59-171,209-373`, `MountGuardRuntime.hs:361-730`, `StatefulWriter.hs:47-219`, `DeploymentWriter.hs:53-471`, `ScheduledWriter.hs:49-257`, `ServiceState.hs:40-118`, `CompletedJob.hs:37-199`, `DatabaseShutdown.hs:34-156`, `MaintenanceNetwork.hs:46-364` | UID validity, owner-reference matching, and admission-guard values pinned to the captured UIDs | d(D1/D2) vs b | No | SAFE (pin enforcement). N/A for laundering | — |
| D8 | `S/DataFence/MaintenancePostgres.hs:40-189`, `MaintenanceRedis.hs:38-142`, `MaintenanceClickHouse.hs:42-154` | Pod UID before == after the engine change | b vs b | n/a (Pod) | SAFE (intra-operation) | — |

## 6. Maintenance

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| M1 | `S/Maintenance.hs:40-45,61-69,100-108,294-305,346-372` | Request/proof carry target StatefulSet/PVC/Pod and recovery Job UIDs. **No production caller constructs `MaintenanceRequest`** (only `test/InventoryKubernetes*Spec.hs`) | d (caller-supplied) | No | FAIL-OPEN (latent; any future planner inherits the gap) | **NEW** (latent) |
| M2 | `S/Maintenance.hs:213-254` | Recovery backup `backup.source.*.uid` (or scheduled) == request target UIDs | d vs d | No | Consistency only, as L4 | NEW (latent) |
| M3 | `S/MaintenanceFence.hs:84,97-99,110-117,176-178,211-244` | `fencePhysical` == proof StatefulSet/PVC; Pod and network pins | d vs b(D1) | No | inherits D1 | NEW |
| M4 | `S/MaintenanceAdapter.hs:100-117,211-221` | Recovery Job UID == proof (owner stamp + digest); Pod UID | b vs d | No (Job) | SAFE (intra-operation) | — |

## 7. Volume snapshot / restore / prune (application volumes)

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| V1 | `A/Commands/Storage.hs:279-300` | `storage snapshot` plan: source PVC UID (and store credential) from fresh observation. The app volume PVC is Durable+Kubernetes, so it **has a record** | b | **No** | **LAUNDER** (snapshot of a replaced, possibly empty volume becomes an accepted recovery point) | **NEW** (volume analogue of B1) |
| V2 | `S/Backup.hs:489-491,599,647-654,719`; `S/Backup.hs:150-175` `volumeSnapshotJobSourcePins` | Pins into scope and Job; executor recheck (`S/Adapters/Kubernetes.hs:446`; `A/Inventory/SourceEvidence.hs:400-460` checks scope revision and pin agreement only) | b→d | No | propagates V1 / SAFE after plan | NEW |
| V3 | `A/Commands/Storage.hs:458-466,526` | `storage restore` plan: target PVC UID (accepted volume) fresh | b | No | LAUNDER-low (restore writes a separate scratch claim; the target pin only binds the review) | NEW-minor |
| V4 | `A/Commands/Storage.hs:487-498,522` | Snapshot Job UID (owner stamp + digest) | b | No record (Job) | FAIL-OPEN (stateless, low) | stateless class |
| V5 | `S/VolumeRestore.hs:51-57,64-97,380-393,475-495` | Pins into scope and Job; executor recheck. **No comparison of the snapshot's `volume-backup.source.pvc.uid` with the target or the record** | d | No | FAIL-OPEN (as R4) | NEW-minor |
| V6 | `A/Commands/Storage.hs:706-739`; `S/VolumePrune.hs:50-74,296-342` | Volume prune: snapshot Job UID + store-credential UID fresh | b | No record (Job / stateless Secret) | FAIL-OPEN (stateless, low) | stateless class |

## 8. Database backup prune (manual and scheduled)

| # | Site | What | Src | Record? | Verdict | Tag |
|---|---|---|---|---|---|---|
| P1 | `A/Data/Backup.hs:303-331` | Manual prune plan: backup Job UID (owner stamp + digest) → `pruneBackupUid` | b | No record (Job) | FAIL-OPEN (stateless, low) | stateless class |
| P2 | `S/Prune.hs:53,65-66,77-94,105-121,294,323` | Pins into scope and Job; parses back | d | — | propagates P1 | — |
| P3 | `A/Inventory/PruneEvidence.hs:392-412` | Resume after the backup scope is retired: `retainedPhysical == pruneSourceUid` | a | **Yes** | SAFE | — |
| P4 | `A/Inventory/PruneEvidence.hs:172-179`, `A/Data/ScheduleObservation.hs:18-51` | CronJob UID (owner stamp + digest) used to find in-flight producer Jobs by ownerReference | b | No record (CronJob stateless) | FAIL-OPEN-low: Jobs owned by a replaced CronJob's predecessor are invisible to the in-flight check | NEW-minor |
| P5 | `A/Inventory/PruneEvidence.hs:300-363` | Scheduled-prune recovery: failed Job UID == published review's | d vs b | n/a | SAFE | — |
| P6 | `A/Data/ScheduledPrune.hs:264-309,394,413`; `S/ScheduledPrune.hs:71,197,248-255,327-368,529-537,606-637` | Ingestion Job / failed Job UIDs (owner stamp + digest); backup ID must be a UUID | b / d | No record (Jobs) | FAIL-OPEN (stateless, low) | stateless class |

## 9. Not identity-bearing (checked, nothing to classify)

`S/BackupFreshness.hs`, `S/ScheduledGcs.hs`, `S/RestoreNative.hs`, `S/LiveRestoreSource.hs`, `S/DataService.hs`, `S/Database.hs`, `S/DataFence/GuardAuthority.hs`, `S/DataFence/VolumeState.hs`, `S/DataFence/WriterInventory.hs`, `A/Data/DatabaseRename.hs`, `A/Data/Lifecycle.hs`, `nagarectl/src/Nagare/Storage/Restore.hs` (comment at :162 only), `A/Parser/Data.hs` (help text :200,212,228,477).

## LAUNDER / FAIL-OPEN summary

| Class | Rows | Tag |
|---|---|---|
| Scheduled ingestion, listing, freshness and restore pass when no StatefulSet/PVC record exists | S2, S5, S6, S8, S11, R3, L5 | F49 known limit / **F60** |
| Manual DB backup source never compared with the record | B1-B4 (and L4, M2 consistency-only) | **NEW** |
| Volume snapshot source PVC never compared with the record | V1-V2 | **NEW** |
| Backup signing Secret (Durable, recorded) never compared at listing, ingestion, escrow, live restore; HMAC key read by name, unbound | S3, S4, S9, S13, S14, L6 | **NEW** |
| Restore target (scratch and live) pinned from a fresh observation | R2, R6, L1, L2, L7 | **NEW** |
| Data fence binds fresh target identity; `validRequest` ignores `headIncarnations` | D1, D3 (inherited by D4-D6, L8, M3) | **NEW** |
| Manual / volume restore does not compare the backup's source UID with the target | R4, V5 | **NEW-minor** |
| Maintenance request UIDs caller-supplied; no production planner | M1, M2 | **NEW (latent)** |
| Stateless Jobs, CronJobs and store Secrets have no record (fail-open by design; digest + owner stamp only) | B7, R5, L3, V4, V6, P1, P4, P6, S9 (CronJob) | stateless class (P4 NEW-minor) |

## Partition C: identity handling in the non-Kubernetes executors and cloud code

Snapshot: master `09241d35`, read-only. Paths are relative to `cli/`.
- `A/` = `nagarectl/src/Nagare/Inventory/Adapters/`
- `I/` = `nagarectl/src/Nagare/Inventory/`
- `C/` = `nagarectl/app/Nagare/Cli/`

Identity source codes:
- **(a)** recorded: `headRetained`, `headCollected` or `headIncarnations`.
- **(b)** fresh observation.
- **(c)** the create's own result.
- **(d)** a review- or prepare-carried physical identity captured at planning or preparation, then compared within the same transaction.

**Baseline fact.** `headIncarnations` holds only `KubernetesExecutor` members that are `Durable` or a StatefulSet (`I/Execute/Incarnations.hs`, the `durable` set). So *no executor in this partition has an accepted-incarnation record*. This has two consequences:
- `Status.classifyDriftWith` can only map an `ObservedPresent` of these members to `converged`.
- `buildRetentionProofs` (`I/Plan/Changes.hs:388`, `Map.findWithDefault physical …`) always falls back to the **observed** identity when these members are retired.

These two facts, combined with the per-adapter observations below, are why every "no record" row is FAIL-OPEN by design.

Verdicts:
- **SAFE**: compared with the record, the record is the source, or the identity is pinned within one transaction (d) and the risk ends there.
- **LAUNDER**: a fresh observation, which could be an out-of-band replacement, becomes accepted, retained, ingested or a restore source.
- **FAIL-OPEN**: no record exists, so anything passes.
- **N/A**: stateless; replacing it is harmless or detectable by content.

## 1. Cloudflare (DNS record, cache ruleset, zone TLS setting): `A/Cloudflare.hs`, `A/CloudflareRuntime.hs`

The physical identity is the provider record ID (`cloudflare:zone/Z/dns/<recordId>`) or ruleset ID, both real provider identities. For the TLS setting it is the name (`…/setting/ssl`). All three are stateless.

| Site | What it does | Src | Compared to record? | Verdict |
|---|---|---|---|---|
| `A/CloudflareRuntime.hs:108` | DNS physical from the listed record ID | b | — | producer |
| `A/CloudflareRuntime.hs:125` | Ruleset physical from the ruleset ID | b | — | producer |
| `A/CloudflareRuntime.hs:142` | TLS physical is a constant name | b | — | producer (identity = address) |
| `A/Cloudflare.hs:226-249` (`observe`) | `ObservedPresent physical` when the content equals the desired target. Any record ID passes. Not-accepted → `ObservedUnowned`; content drift → `ObservedDrifted` | b | no record exists | FAIL-OPEN (N/A: stateless; content-checked) |
| `A/Cloudflare.hs:150-158`, `304-318` (`preparePhysical`) | Prepare captures the live ID and version for update, retire, verify and adopt, checking content against the previous or desired declaration only | b→d | no | update/verify/adopt: N/A. Retire: see the next row |
| `A/Cloudflare.hs:150-158` + `I/Plan/Lifecycle.hs:342-346` (retire = collection) | Planning checks `physical == retainedPhysical`, but preparation **re-inspects** and stores that second observation as `cloudflarePlanPhysical`. `decodePlan` (`:339`) nulls physical before comparing, and admission (`I/Execute/Transaction.hs:160-169`) checks the proof, not the prepared ID. Nothing cross-checks the prepared ID against the retained one | b (2nd) | **no** (window between the planning observation and the prepare inspect in the same plan command) | SAFE-with-gap: F33-class for Cloudflare. **NEW (minor; stateless record)** |
| `A/Cloudflare.hs:161-163`, `322-327` (`checkBefore`) | Preflight and execute require the live ID and version to equal the prepared ones | d | vs prepare | SAFE (in-transaction) |
| `A/CloudflareRuntime.hs:178-202` (`submit`), `204-216` (`matchesBase`) | Conditional on the prepared ID and version; DELETE/PUT by the prepared ID (`:240-245`) | d | vs prepare | SAFE |
| `A/CloudflareRuntime.hs:200`, `217-223` (`matchesTarget`) | After a **create**, `maybe True` accepts **any** record ID with the target content. The POST response's record ID (c) is discarded | b | no (no c) | FAIL-OPEN, F60-class (create identity unused). N/A in practice: stateless |
| `A/Cloudflare.hs:178-194` (verify) | Create/update: any physical (`maybe True` when the plan has none) plus content. Verify/adopt: equals prepare | b/d | partial | N/A (stateless) |
| `A/Cloudflare.hs:195-223` (recover) | Retire: absent → proved. Verify/adopt/no-op update: requires the prepared ID and version, else `RecoveryUnresolved` | d | vs prepare | SAFE. Wedge on a replaced verify target: **F57 class gap (already listed)** |

## 2. Google Cloud DNS (edge DNS A record): `A/Cdn.hs`, `A/CdnRuntime.hs`, `A/CdnCombined.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/CdnRuntime.hs:78-91` | Physical = `dns:project/zone/host`, a name and not a provider ID | b | — | identity = address |
| `A/Cdn.hs:155-167` (`observe`) | Present or drifted, by content | b | no record | N/A (stateless; content-checked) |
| `A/Cdn.hs:108-125` (preflight/execute), `A/CdnRuntime.hs:99-111` | Cloud DNS change with exact `deletions` of the previous content: an atomic content CAS | d (content) | content | SAFE |
| `A/Cdn.hs:126-138` (verify), `139-152` (recover) | Content only; a replaced verify target → `RecoveryUnresolved` | b | content | N/A. Wedge: F57 class (listed) |
| `I/Plan/Lifecycle.hs:342-346` for `DnsRecord` collection | `physical == retainedPhysical`, trivially true for name-based IDs | a vs b | name-only | N/A (stateless) |
| `A/CdnCombined.hs:30-66` | Dispatches to Google or Cloudflare; no identity logic | — | — | N/A |

## 3. Host (NixOS VM activation): `A/Host.hs`, `A/HostRuntime.hs`, `scripts/inventory-host-transport.sh`

The physical identity is `gce://projects/P/zones/Z/instances/<numeric GCE id>` (`scripts/inventory-host-transport.sh:95-102`), a **real** provider incarnation.

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/HostRuntime.hs:79-99` (`observeResources`) | If the host is accepted, `ObservedPresent physical` for **whatever** instance ID the transport returns | b | **no record** | **FAIL-OPEN. NEW.** A VM recreated out of band (new boot disk) reads `converged` |
| `A/HostRuntime.hs:101-135` (`preparePlan`) | `hostPlanInstance` = the live instance at preparation | b→d | **no** (nothing recorded to compare) | **FAIL-OPEN. NEW.** The next reviewed activation silently targets a replacement VM |
| `A/Host.hs:81-94`, `139-155` (preflight/execute) | Live instance must equal `hostPlanInstance` | d | vs prepare | SAFE (F01's in-transaction bind) |
| `A/Host.hs:95-102` (verify), `103-105`/`157-167` (recover) | Committed only if the instance equals the plan's | d | vs prepare | SAFE |
| `A/HostRuntime.hs:150-160` (`runActivation`) | Transport-returned identity must equal the plan's | d | vs prepare | SAFE |
| `I/Plan/Lifecycle.hs:330-338` + `I/Plan/Changes.hs:388` | Host members are retained "as history only". The retained identity = the observed instance (no record) | b | no | **FAIL-OPEN. NEW** (F51's harm for hosts; F51's fix covers only recorded members) |
| `I/BootstrapRegistryRecovery.hs:220-224` (`committed`) | Recovery requires the host committed on `hostPlanInstance` | d | vs prepare | SAFE |
| `I/BootstrapRegistryTransport.hs:32-57` | Derives the VM name and Deployment UID for the remote script from plan or proof | d | — | SAFE |

**Data at risk on a replaced VM:** the k3s datastore, local-path PVC contents (database volumes live on the VM disk), SSH host keys and the sops age key. Kubernetes PVC and StatefulSet UIDs would change with a rebuilt cluster, so F49's records catch the *data* members. A replacement that keeps the cluster (for example a disk snapshot restored under a new instance) is invisible to inventory.

## 4. Pulumi (platform cloud: VM instance, address, network, firewall, subnetwork, DNS zone/recordset): `A/Pulumi.hs`, `A/PulumiRuntime.hs`, `I/CloudCollection.hs`, `C/Inventory/CloudHistory.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/PulumiRuntime.hs:272-291` (`decodePhysicalResources`) | Physical = the stack-export `id`, falling back to the **URN** when the ID is absent (`:289-290`). This is **Pulumi state, not the provider** | b (state) | — | producer. For GCE resources the ID is name-shaped (`projects/P/zones/Z/instances/NAME`) |
| `A/PulumiRuntime.hs:70-85` (`observeResources`) | `ObservedPresent physical` from state for any ID; absent if the URN is missing. **There is no refresh**, so an out-of-band delete/recreate in GCP is invisible | b (state) | no record | **FAIL-OPEN. NEW** (state-sourced observation) |
| `A/PulumiRuntime.hs:211-221` (verify, non-retire) | `pulumi preview --expect-no-changes` without `--refresh` compares the program with state, not the live provider | b (state) | no | FAIL-OPEN (NEW, same root cause) |
| `A/PulumiRuntime.hs:197-210` (verify retire), `223-228` (recover) | Absence in state proves the collection; otherwise `Unresolved` | b (state) | — | SAFE for state |
| `C/Inventory/CloudHistory.hs:95-102` | Collection identity is taken from `headRetained` / `headCollected` | a | record is the source | SAFE (F33) |
| `I/CloudCollection.hs:191-229` (`cloudCollectionPhysicalDigest`), used at `A/PulumiRuntime.hs:87-105` (prepare), `142-178` (`readIdentity` at preflight and before `up --plan`) and `A/Pulumi.hs:121-129` | Requires the stack entry `id` == retained identity, plus protection | a vs b(state) | yes | SAFE against the record. **Residual NEW (F33):** the IDs are name-shaped and read from unrefreshed state, so a same-name GCP recreation passes, and `up --plan` deletes it by name. The GCE numeric `instanceId` output is not compared |
| `I/Plan/Lifecycle.hs:332-336` + `I/Plan/Changes.hs:388` | Platform-cloud retirement retains the observed (state) ID; there is no incarnation record | b | no | FAIL-OPEN (F51 class for Pulumi). **NEW** |
| `I/CloudCollection.hs:157-184` | Refuses Pulumi protection and VM `deletionProtection` | b | — | SAFE (protection, not identity) |
| `C/Bootstrap/Cloud.hs:131-139` | Bootstrap checks that the URN is present in state (`decodePhysicalResources`); no identity comparison | b | no | N/A (presence only, pre-inventory) |

## 5. Cloud foundation (GCS buckets including the Pulumi backend bucket, enabled services, Pulumi stack): `A/Foundation.hs`, `A/FoundationRuntime.hs`, `I/Foundation.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/FoundationRuntime.hs:438-443` (`physicalBucket`) | Physical = `gs://NAME`, a name. The GCS bucket has no recorded generation or creation identity | b | — | identity = address |
| `A/FoundationRuntime.hs:99-124` (`inspectBucket`) | Owned (label) bucket → `FoundationPresent (gs://NAME)` | b | no | **FAIL-OPEN. NEW.** A deleted and recreated bucket with the nagare label reads `converged`. The backend bucket holds Pulumi state (and possibly the inventory store), which is data-bearing |
| `A/FoundationRuntime.hs:445-450`, `126-145` | Service physical = `gcp-service:P:S`, a name | b | — | N/A (stateless enablement) |
| `A/FoundationRuntime.hs:147-197`, `226-232` | Stack physical = `pulumi-stack:backend/stack`, a name. Presence comes from `stack ls` | b | no | FAIL-OPEN (name-only). **NEW** (a recreated empty stack reads converged if its config matches) |
| `A/Foundation.hs:113-124` (preflight/execute) | Content digest only | b | — | N/A |
| `A/Foundation.hs:125-133` (verify), `134-145` (recover) | Any physical with the target digest | b | no | FAIL-OPEN (name identity). Verify-mismatch wedge: F57 class (listed) |
| `A/Foundation.hs:147-154` (`toResourceObservation`) | Present or drifted by digest | b | no record | FAIL-OPEN (see above) |
| `I/Foundation.hs:96-130` | Builds targets from declarations; no identity | — | — | N/A |

## 6. Broker topics (Redpanda): `A/Broker.hs`, `A/BrokerRuntime.hs`, `nagare-dsl/src/Nagare/Resource/Broker.hs`

The DSL comment (`Broker.hs:24-26`) calls a topic "a durable logical resource".

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/BrokerRuntime.hs:147-164` (`brokerUid`) | Physical = `broker-statefulset://<live broker StatefulSet UID>/topic/NAME`. The topic itself has no incarnation identity; `rpk` exposes none | b | — | producer |
| `A/BrokerRuntime.hs:61-64` | Combines the live UID with the topic settings | b | — | — |
| `A/Broker.hs:172-187` (`observe`) | `ObservedPresent` for any physical whose settings match | b | **no**: no topic record, and the broker StatefulSet UID is **not** compared with the StatefulSet's own `headIncarnations` record | **FAIL-OPEN. NEW.** A topic deleted and recreated (all messages lost) reads `converged`. A replaced broker StatefulSet is caught only on the StatefulSet member, not on its topics |
| `A/Broker.hs:100-117` (preflight), `118-138` (execute) | Settings only; create requires absence | b | — | N/A |
| `A/Broker.hs:139-151` (verify) | Any physical with matching settings → proof | b | no | FAIL-OPEN (as observe) |
| `A/Broker.hs:152-170` (recover) | A verify with a settings mismatch → `Unresolved`. A create of a present topic → `Unresolved` ("cannot prove its creation incarnation"; a deliberate F60-style refusal) | b | — | SAFE (conservative). Verify wedge: F57 class (listed) |
| `I/Plan/Lifecycle.hs:330` + `I/Plan/Changes.hs:388` | Topic retirement retains the observed physical (no record) | b | no | FAIL-OPEN (F51 class for topics). **NEW** |

## 7. Attic binary cache: `A/Cache.hs`, `A/CacheRuntime.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/CacheRuntime.hs:150-175` | Physical = `attic://CTX/NAME`, a name. The **generated signing public key** is observed but not part of the identity | b | — | producer |
| `A/CacheRuntime.hs:66-71` (`observe`) | `ObservedPresent physical` regardless of the configuration digest **and the public key** | b | no | **FAIL-OPEN. NEW.** A recreated cache has a new keypair, and status still reports converged. Consumers' trusted public keys break, or a foreign key is trusted. The dropped digest is also a drift gap |
| `A/Cache.hs:105-115` (verify), `116-131` (recover) | Accepts any non-empty key with the configuration digest | b | no (key not recorded) | FAIL-OPEN (identity-bearing key). **NEW** |
| `A/Cache.hs:80-104` (preflight/execute) | Configuration digest only | b | — | N/A |

## 8. Artifacts (OCI, GCS image object, GCE image, kubeconfig, build job, local registry/cluster, builder, release payload): `A/Artifact.hs`, `A/ArtifactRuntime.hs`, `C/Bootstrap/Image.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/ArtifactRuntime.hs:186-199` (`expectedPhysical`) | Physical = prefix + destination, a name. The content digest is the real identity | — | — | — |
| `A/ArtifactRuntime.hs:174-178` (`toResourceObservation`) | `TransportPresent physical _` → `ObservedPresent physical`: **the digest is discarded**, so a destination whose content changed reads present | b | no | FAIL-OPEN for content drift (inferred: depends on whether the external transport reports a digest mismatch as `OwnershipMismatch`). **NEW (low confidence)** |
| `A/ArtifactRuntime.hs:72-85` | Kubeconfig projection: digest-checked, then `kubeconfig://path` | b | content | SAFE |
| `A/ArtifactRuntime.hs:133-142` (publish) | The returned physical must equal the expected name and digest | b | content | SAFE |
| `A/Artifact.hs:74-105`, `125-144` | Preflight, execute, verify and recover all digest-compare | b | content | SAFE (content-addressed) |
| `C/Bootstrap/Image.hs:312-320` | GCE image: name plus digest equality | b | content | SAFE |

## 9. Helm releases: `A/Helm.hs`, `A/HelmRuntime.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `A/HelmRuntime.hs:119-130`, `152-157` | Physical = the UID of the **current revision Secret** `sh.helm.release.v1.NAME.vN`. It changes on every upgrade, so it is a revision identity, not an incarnation | b | — | producer |
| `A/Helm.hs:134-149` (`observe`) | Present or drifted by digest and owner annotation | b | no record | FAIL-OPEN (N/A: chart-rendered, stateless) |
| `A/Helm.hs:81-100` (prepare), `101-115` (preflight/execute) | The whole `HelmState` (UID, revision, owner, digest) must equal the prepared state | d | vs prepare | SAFE |
| `A/Helm.hs:200-210` (`proof`), `116-130` (verify/recover) | Any physical with owner and digest | b | no | N/A |
| `A/Helm.hs:60-70` (`helmStateHealth`) | Second read must have the same revision UID as the classification read | b vs b | yes | SAFE (consistency) |
| retirement via `I/Plan/Changes.hs:388` | Retains the revision-Secret UID (observed) | b | no | N/A for data. Note: collection would refuse after any upgrade; that is conservative |

## 10. Access tuples (SpiceDB relationship gated by auth and route owners): `I/Access.hs`, `I/AccessRuntime.hs`

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `I/AccessRuntime.hs:165-225` | Physical = `access-owner://<auth UID>/<route UID>`, from live Kubernetes owners checked for annotations and digest | b | — | producer |
| `I/Access.hs:339-357` (`observe`) | Present or drifted by grant state | b | no record | N/A (stateless tuple) |
| `I/AccessRuntime.hs:146-152` (`accessWrite`), `I/Access.hs:302-317` | The owner UID must equal `accessBefore` | d | vs prepare | SAFE |
| `I/Access.hs:318-325`, `376-385` (`completion`) | Verify and recover require the owner UID == before, else `RecoveryUnresolved` | d | vs prepare | SAFE. **Untagged member of the F57 class:** a `VerifyResource` whose auth or route owner is replaced after an ambiguous verify wedges. F57's gap list omits Access |

## 11. Other in-partition sites

| Site | What it does | Src | Compared? | Verdict |
|---|---|---|---|---|
| `I/VmPower.hs:233-251` (prepare), `305-320` (inspect), `268-279` (receipt) | Numeric GCE `instanceId` pinned at preparation; later reads must match | b→d | vs prepare | SAFE (in-transaction). Not compared with any accepted host record (none exists) |
| `I/ImagePruneAdapter.hs:100-134`, `I/ImagePruneScript.hs:14`, `C/Inventory/ImagePrune.hs:71-127` | VM numeric `id` pinned at preparation; observation brackets before and after; removal rechecks | b→d | vs prepare | SAFE (in-transaction) |
| `I/BootstrapRegistryRecovery.hs:120-153`, `196-215` | Deployment UID from the Kubernetes adapter's `RecoveryAwaitingReadiness physical` (fresh; matched by owner stamp and digest, not the create's UID), then pinned in the proof | b→d | not vs the create's UID | SAFE within recovery. Origin is F60-class (stateless Deployment) |
| `I/CdnPurge.hs:120-130` | Purge recovery = verify, else `Unresolved` | — | — | no identity |
| `C/Inventory/SourceEvidence.hs:398-470` | Reopens the volume-Job pins (`I/Backup.hs:143-145` annotations) so the Kubernetes adapter can compare the live UIDs with the **pins**. Checks scope revisions, not `headIncarnations` | d | pin origin belongs to the data-plane partition | defer to partition B |
| `C/Inventory/PublicEvidence.hs:20-21` | Emits `fencePhysical` as evidence | a | — | N/A (read-only) |
| `nagarectl/src/Nagare/Context/Review.hs:184-185` | Checks that retained and collected are empty; no identity | a | — | N/A |
| `nagarectl/src/Nagare/Platform/Replacement.hs:135-150` | Legacy reviewed VM replacement transaction (old/candidate `hostResourceId`); does not feed inventory identity | — | — | N/A (outside inventory) |
| `I/Site.hs:1244`, `I/Application/Release.hs:134`, `I/TaskLifecycle.hs:2`, `I/Host.hs:57,104` | Comments, or address (not physical) construction | — | — | N/A |
| `I/Cloud.hs`, `I/Bootstrap.hs`, `I/Cache.hs`, `I/Foundation.hs` (beyond §5), `I/Artifact.hs`, `I/RegistryCredentials.hs`, `I/Cleanup.hs`, `I/ImagePrune.hs`, `I/Application.hs`, `I/Application/*` (except Release comment) | No physical-identity reads | — | — | — |
| `A/GitHubRelease.hs:224-231`, `241-246`, `265-271`, `300-325` | Release and asset provider IDs pinned within one publish or cleanup; the tag object is compared | b→d | vs the original read | SAFE (release tooling, not an inventory executor) |

## LAUNDER / FAIL-OPEN summary (partition C)

No site in this partition **LAUNDERs into an incarnation record**, because none is written for these executors. Every gap is FAIL-OPEN from the missing record. Several of them feed retained history, which is F51's harm without F51's fix.

| # | Site | Kind | Tag |
|---|---|---|---|
| C1 | `A/HostRuntime.hs:79-99` observe, `:101-135` prepare | VM with a real GCE ID, never recorded: status converged, and the next activation targets a replacement | **NEW** |
| C2 | Host/Pulumi/Broker/Cloudflare/Helm retirement via `I/Plan/Changes.hs:388` fallback | Retains the observed ID for every non-recorded executor | F51 class (F51 closed for recorded members only); **NEW** for these executors |
| C3 | `A/PulumiRuntime.hs:70-85`, `:211-221` | Observation and verify read unrefreshed Pulumi state; GCP-side replacement is invisible | **NEW** |
| C4 | `I/CloudCollection.hs:191-229` | F33's recheck compares name-shaped state IDs; a same-name GCP recreation passes and is deleted | **F33 residual (NEW observation)** |
| C5 | `A/FoundationRuntime.hs:99-124`, `438-443` | GCS bucket identity = name; a recreated (emptied) backend bucket reads converged | **NEW** |
| C6 | `A/FoundationRuntime.hs:147-197`, `226-232` | Pulumi stack identity = name | **NEW** (low) |
| C7 | `A/Broker.hs:172-187`, `139-151`; `A/BrokerRuntime.hs:147-164` | A topic has no incarnation; a recreated topic (data lost) reads converged; the broker STS UID is not cross-checked with the STS record | **NEW** |
| C8 | `A/CacheRuntime.hs:66-71`, `A/Cache.hs:105-131` | Attic signing key not recorded; a recreated cache with a new key reads converged | **NEW** |
| C9 | `A/ArtifactRuntime.hs:174-178` | Observation drops the content digest | **NEW** (low confidence, transport-dependent) |
| C10 | `A/Cloudflare.hs:150-158` vs `I/Plan/Lifecycle.hs:342-346` | The collection's prepared record ID is a second observation, not checked against the retained ID | **NEW** (minor, stateless) |
| C11 | `A/CloudflareRuntime.hs:200`, `217-223` | Create completion accepts any record ID; the POST's returned ID (c) is unused | F60 class (stateless) |
| C12 | `I/Access.hs:318-325`, `376-385` | Verify recovery wedges when an owner UID changes | **F57 class gap**: Access is not in F57's executor list |

### Identity-bearing kinds with no incarnation record (FAIL-OPEN by design)

- **Host VM** (HostExecutor). Real numeric GCE ID; the disk holds k3s state, local-path PVC data, host keys and the age key.
- **Pulumi platform cloud resources** (GCE instance, which is *collectible* and declared Stateless; address; network; DNS zone). IDs are name-shaped and come from unrefreshed state.
- **GCS buckets** (Foundation `GlobalBucket`, including the Pulumi backend bucket). Data-bearing; identity is the name.
- **Pulumi stack** (Foundation). Identity is the name.
- **Broker topics.** Durable messages; no topic incarnation at all.
- **Attic cache.** The generated signing keypair is identity-bearing.
- **Artifacts.** Content-addressed, so mostly safe, but observation drops the digest (C9).

Stateless, so replacement is harmless or content-checked: Cloudflare DNS, ruleset and TLS; Google Cloud DNS; Helm releases (revision-UID identity); access tuples; enabled services.

### What the F60 structural fix would and would not close here

- **Would close:** nothing in this partition directly. F60 binds identity from the Kubernetes create's completion and records only Kubernetes durable or StatefulSet members.
- **"One checked accessor" would close:** C2 for any executor whose record exists. That needs the record set widened beyond `KubernetesExecutor`.
- **Would not close:**
  - C1, C3–C9 need a per-executor provider incarnation that is actually captured: the GCE numeric ID from the create or describe call, GCS bucket `projectNumber` plus `timeCreated` or generation, the Attic public key, a topic creation fingerprint (Redpanda has no topic UUID via `rpk`, so possibly none), and `pulumi refresh` or live describe instead of state.
  - C4 additionally needs the collection recheck to compare a provider-generated ID (for example the GCE `instanceId` output), not the state `id`.
  - C12 is a wedge, not an identity defect.
