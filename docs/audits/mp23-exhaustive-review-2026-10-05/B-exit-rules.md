# B. Exit, stop, abandon and admission rules in Nagare's inventory transactions: one general replacement

Snapshot: `master` at `09241d35`, package `cli/nagarectl`. Paths below are relative to `cli/nagarectl/src/Nagare/Inventory/` unless stated. Line numbers are from the snapshot. F63, F64, F65 and F59 gap A exist only as uncommitted work in the live working tree. Those lines are marked **(WIP)**, and that tree was changing while this review was written.

Evidence labels: **observed** means read in source, a diff or the tracker. **Inferred** means reasoned from source without running it. Nothing was built or run.

---

## 1. Inventory of every rule that decides whether a stopped transaction can end or recover

### 1.1 The state machine these rules sit on

- The journal has six states per operation: `Pending | IntentRecorded | Completed digest | Failed (KnownNoEffect|PartialOrUnknown) | Ambiguous | OperatorResolved marker` (`Journal.hs:66-73`).
- `OperationStep.nextOperation` (`OperationStep.hs:51-65`) runs operations serially **in operation-ID (digest) order**. `operationPhase` (`:69-84`) maps:
  - `IntentRecorded`, `Ambiguous` and `PartialOrUnknown` to Recover;
  - `KnownNoEffect` and the two safe-retry markers to Execute;
  - any other marker to Blocked.

  Which companions are still `Pending` when an operation stalls therefore depends on digest order, not on the plan's dependency structure. This is the root reason the companion allowlists keep breaking (F55, F59 gap A, F65).
- The driver journals `IntentRecorded` before any effect (`Execute/Driver.hs:373`). Fence start (`:381`) and `adapterExecute` (`:397`) come after it. This is the one invariant that makes "never started ⇒ no effect" a generic proof.
- Two **terminal releases** exist, with different semantics:
  - `releaseStoppedApplicationClaim` (`Execute/Claims.hs:170-195`) clears the transaction and keeps `headAccepted` at the admitted desired revisions. `headConverged` is unchanged.
  - `releaseAbortedClaim` (`Execute/Claims.hs:200-225`) clears the transaction and sets **`headAccepted = headConverged` for the whole head** (`:222`). Admission's additions to `headRetained` are **not** undone.

### 1.2 Rule table

"Protects" uses four properties: **U** no unreviewed acceptance or convergence, **D** no data loss or orphaning, **I** incarnation respect (F49/F51), **R** no repeated proved effect.

| # | Rule (file:line) | Exact condition | Admits | Excludes | Origin | Protects |
|---|---|---|---|---|---|---|
| R1 | Recovery gate, `Execute/Recovery.hs:271-311` | active tx; fence vs `fencedAction` (`:273-282`); review digest = tx (`:283`); op state `recoverableState` (`RecoveryPolicy.hs:299-308`), **or** `StopIncompleteApplication`/`AbandonRefusedOperation` on `Pending` (`:287-288`), **or** `AbandonRefusedOperation` on `Failed KnownNoEffect` (`:291-292`); abandon only if no other op is recoverable (`:299-303`); a saved bootstrap marker or stop marker forces its own action (`:304-311`) | the per-action state matrix | completed ops; abandon with any other uncertain op; skipping a saved stop or bootstrap intent | 9a0541ee (F12/F13 era), 0f6fa7db (F16), 570467f0 (F35), d9aed800 (F37) | U, R |
| R2 | `AcceptAdapterProof`, `Recovery.hs:573-581` | adapter returns `RecoveryProvedComplete` | journals `Completed`; the tx stays active (`releaseClaim … Nothing`, `:341`) | everything else | 9a0541ee | U, R |
| R3 | `RetryAfterAdapterProof`, `Recovery.hs:582-591` and `:415-442` | `RecoverySafeToRetry` with no fence, or an unreserved fence start (`"data fence acquisition or exclusion is unresolved"` prefix) | marker `adapter-proved-safe-retry` / `fence-not-reserved-safe-retry`, which become Execute in `operationPhase` (`OperationStep.hs:80-82`) | fenced ops | 9a0541ee, 29aa4dc1 | R |
| R4 | Ordinary resume recovery, `Driver.hs:169-194` | `ProvedComplete` journals `Completed`; `SafeToRetry` re-executes if unfenced and dependencies are complete (`:183-186`); `AwaitingReadiness` continues readiness; `LandedUnready`, `TargetReplaced`, `TerminalFailure` and `Unresolved` stop ambiguous (`:191-194`) | progress only | n/a | F13 (`ebe91b7d`), F54, F56 | R |
| R5 | `continueReadiness`, `Driver.hs:270-320` | the waiting op **and** each candidate are an unfenced Kubernetes **create** of a **stateless Deployment** (`:284-299`), untouched, with dependencies complete | other Deployment creates while one waits | every other kind, durable members, updates | F14 (0c757b74) | R, D |
| R6 | Retried-preflight journalling, `Driver.hs:356-371` | preflight refuses an op whose state is not `Pending` (a proved-safe retry) | journals `Failed (KnownNoEffect "adapter preflight refused: …")`, so R9 can end it | first attempts (no journal entry, so F35's fresh-preflight branch applies) | F57 (42ce5d54) | U |
| R7 | `StopIncompleteApplication`, `Recovery.hs:477-501` | no fence selection; the decision is a saved stop marker, or `AwaitingReadiness` (Unproved), `LandedUnready` or `TargetReplaced` (Proved) (`:480-489`, WIP adds `TargetDeleted` at live `:490-492`); **and** `incompleteApplicationOnlyReview` (R8) | appends `stopped-incomplete-application:<digest>`, then `releaseStoppedApplicationClaim` (`:319-320`) | everything R8 excludes | F16 (0f6fa7db), widened by F29, F30, F54, F56, F59, F63–F65 | U, D |
| R8 | `incompleteApplicationOnlyReview`, `Plan/History.hs:288-444` | see §1.3. It is the main allowlist. | | | F16 → F65 | U, D |
| R9 | `AbandonRefusedOperation`, `Recovery.hs:450-460` and `:601-626` | no fence selection; state `Failed KnownNoEffect` (journal is the proof, `:610-611`) **or** `Pending` with a **fresh** preflight refusal under the lock (`:613-616`); no other recoverable op (R1); then `releaseAbortedClaim` (`:324-334`) | ends the tx; scope "returns to its last converged revision" | a passing preflight ("resume instead"); fenced ops; other uncertain ops | F35 (570467f0), F37 (d9aed800), F57 feeds it | U, R (D is weakened, see H1–H3) |
| R10 | `AbandonPartialPrune`, `Recovery.hs:506-527` + `scheduledPruneOnlyReview` (`RecoveryPolicy.hs:64-106`) | `RecoveryTerminalFailure` **and** the review is exactly 2 ops `{Create, RunDeclared}` on one resource in a scope carrying override `scheduled.prune.backup.scope` | `abandoned-terminal-scheduled-prune`, `releaseAbortedClaim` | any other shape | F09/F13 (d16d0094) | U |
| R11 | `AbandonPartialVolumeRestore`, `:528-549` + `volumeRestoreOnlyReview` (`RecoveryPolicy.hs:108-174`) | terminal failure; exactly 3 ops (2 creates + 1 run); a `/job` and a `/pvc` suffix; 4 named overrides `volume-restore.*`; scope has exactly 2 managed members | abandons; scratch PVC is left unaccepted | any other shape | 303a7269 | U |
| R12 | `AbandonPartialDatabaseRestore`, `:550-572` + `databaseRestoreOnlyReview` (`RecoveryPolicy.hs:176-231`) **or** `redisRestoreOnlyReview` (`:237-278`) | terminal failure; Postgres: 2 ops on one `/job`, 5 `restore.*` overrides; Redis: selected op is a create of role `statefulset`, scope roles exactly `{service,pvc,statefulset,job}`, ≤ 5 ops, all Create/Run | abandons | any other shape | b3e5e7f9; F36 (6d7951c9) | U |
| R13 | Fenced recovery, `Execute/FencedRecovery.hs:91-325` | phase-matched actions: `ContinueFencedOperation` (Acquiring/Excluded), `VerifyFencedEffect`, `RecoverFencedBackup` (restore + verify the backup, then `releaseAbortedClaim` at `:231`, `:244`, `:290`), `ForwardFencedRelease` | data-fence state machine | rollback when the review has other mutating ops (`Recovery.hs:388-402`) | 52e79ca8, 29aa4dc1 | D, R |
| R14 | `RecoverBootstrapRegistry`, `Recovery.hs:145-234`, `Driver.hs:199-264` | an exact saved host/Deployment proof; `AwaitingReadiness` or `ProvedComplete` | bounded progress | anything else | F15 (1af2e317) | R |
| R15 | Kubernetes recovery classification, `Adapters/Kubernetes.hs:304-413` | per state: | | | | |
| | R15a `:339` | `VerifyResource` whose before-state changed → `SafeToRetry` | | Kubernetes only | F57 | U |
| | R15b `:340-341` + `landedUpdate :385-393` | **Knative Service** update; same UID and owner as before; reviewed digest; `confirmLandedUnready` → `LandedUnready` | | Deployment, StatefulSet (F63 WIP widens to `workloadAddress`) | F54 | U |
| | R15c `:342-345` + `replacedUpdateTarget :397-404` | **Knative Service** update; owner stamp, different UID → `TargetReplaced` | | other kinds; deletion (F64 WIP adds `TargetDeleted`, live `:346-351`, `:413-423`) | F56 | U, I |
| | R15d `:346-349` | restore-scratch StatefulSet create with a proved failed pod → `TerminalFailure` | | | F36 | U |
| | R15e `:350-362` | create, before Absent, exact owner and digest, kind ∈ {**deployment, statefulset, service, domainmapping**} → `AwaitingReadiness` | | other kinds | F14, F16, F29, F59 | U |
| | R15f `:363-373` | version 1/3 **Knative** update, same UID → `AwaitingReadiness` | | | F30 (95b58a24) | U |
| | R15g `:374-383` | `batch/job` failed, exact owner and digest → `TerminalFailure` | | | F09/F13 | U |
| R16 | Other adapters' `recover` (`Adapters/{Broker,Cache,Cdn,Cloudflare,Foundation,Artifact,Helm,Host,KubernetesMigration}.hs`) | mostly `ProvedComplete`, `SafeToRetry` if the create target is missing (`Broker.hs:158`, `Cache.hs:126`, `Foundation.hs:142`, `Artifact.hs:141`) or the before-state is unchanged (`Helm.hs:128`, `Host.hs:162-164`), else `Unresolved`. `KubernetesMigration.hs:283` returns `SafeToRetry` **unconditionally** for `TransferState`. | | verify mismatch → `Unresolved` (F57 class gap) | various | |
| R17 | `loadUnstartedApplicationCreates`, `Plan/History.hs:473-568` | head idle; owner selected **and `scopeKind == Application`** (`:496`; WIP adds Standalone at live `:508`) and unconverged; a stop event's review must have the same binding and changed ⊆ incomplete, current revision, `validStop` = R8 with `LandedUpdateUnproved` (`:534-539`), no barriers (`:549-554`) | `CreateResource` ops (`:563`, F55 filter) whose events are all `Pending` (`:540-546`) | update and verify ops; durable members ever touched | F16 (49db2199), F55 (5ac857d0), F58 (b244b125) | D |
| R18 | `loadInventoryPlanningHistory`, `Plan/History.hs:450-471` | computes R17 for `ReplaceScope` **and** `RetireScope` owners (`:462-471`) | | | F58 | D |
| R19 | Planning per member, `Plan/Changes.hs:710-740` | an absent durable member is re-created only if it is in R17's set and `sameManaged` (`:724-740`); otherwise `durable-resource-missing` | | | F16, F55 | D |
| R20 | `buildAbsenceProofs`, `Plan/Changes.hs:328-341`; `retireError :760-766` | a removed member, `ConfirmedAbsent`, and `Stateless` **or** in R17's set | absence proof instead of retention | absent durable member not in the set | F58 | D |
| R21 | Admission `retentionCoverage`, `Execute/Admission.hs:280-362`; recheck `:192-195` | exactly one retention or absence proof per removed member (`:340-344`); absence only if `holdsNoData` (Stateless or R17, `:318-323`, `:345-351`); absent members re-observed absent at admission | | | F58 | D |
| R22 | `unconvergedSelectedScopeIds`, `Plan/Changes.hs:484`, `:751` | a selected unconverged scope verifies unchanged members | follow-up after a stop | | F16 (7c957c02) | U |
| R23 | `convergedSelectedScopes`, `Execute/Claims.hs:149-165` | completion converges only changed scopes | | a stopped scope never converges as a side effect | F16 (eb582eb0) | U |

### 1.3 Anatomy of R8 (`Plan/History.hs:288-444`)

R8 holds only when **exactly one scope changed** (`:396-397`), of kind Application or Standalone, and either branch holds.

**Update path (`pendingUpdate`, `:334-371`).**
- The selected op is `UpdateResource` in an **Application** scope (`:336`; WIP adds a Standalone StatefulSet at live `:336-337`).
- The selected op is never intended (`neverIntended`, `:319`) or has a landed proof with only `IntentRecorded`/`Ambiguous` (`:322`, `:337`).
- Every op is Kubernetes, unfenced and owned (`:341-343`).
- Every other op is `Completed`, or `Pending` and never intended **and** either:
  - a `VerifyResource` of any member, or
  - a `Create`/`Update` of a **Stateless ConfigMap** with `OrderedAfter` the selected resource (`:353-367`; WIP extracts this as `neverStartedCompanion`, live `:359-373`).

**Create path (`:400-425`).**
- Every op is a Kubernetes create, unfenced and owned (`:403-406`). WIP F65 also admits never-started companions, live `:405-413`.
- Companions are `otherSettled` (`Pending` or `Completed`, `:312-318`) **only** for Application scopes or a selected Standalone StatefulSet (`:412-413`); otherwise every other op must be `Completed` (`:415-422`).

**Selected member (`:426-441`).** It must be `Stateless` and one of:
- Application → Knative `service`;
- Standalone → a `domainmapping` that `previewScopeMembers` proves is the preview route (F29);
- Standalone → `apps/statefulset` (F59).

WIP adds an Application `deployment` update, live `:450-452`.

---

## 2. The pattern: allowlists that each finding widened

Counting the gates that decide "this transaction may end" (R7–R12, R17, R20, R21) and the classifiers that feed them (R15a–g):

- **Per scope kind:** Application (`History.hs:336, 412, 433, 496`), Standalone (`:373, 397, 440`), plus the preview contract (`:434`). Override keys mark restore and prune scopes (`RecoveryPolicy.hs:104, 138-141, 206-210, 262-266`).
- **Per resource kind:**
  - Knative service (`History.hs:432`; `Kubernetes.hs:359, 366, 387, 399`);
  - domainmapping (`History.hs:434`; `Kubernetes.hs:359`);
  - statefulset (`History.hs:381, 440`; `Kubernetes.hs:358, 411`);
  - deployment (`Kubernetes.hs:358`; `Driver.hs:297`; WIP `History.hs` live `:452`);
  - configmap (`History.hs:364`);
  - batch/job (`Kubernetes.hs:378`);
  - resource-ID suffixes `/job`, `/pvc` and role `statefulset` (`RecoveryPolicy.hs:167-168, 227, 252-256`).
- **Per action:** Update-only (`History.hs:335`), Create-only (`:403`), Verify (`:361`), Create/Update (`:362`), Create-only for R17 (`:563`).
- **Per executor:** `KubernetesExecutor` (`History.hs:341, 404`; `Driver.hs:288`). This is why broker topics wedge (F59 gap B).
- **Per situation:**
  - never-intended vs landed (`History.hs:337`);
  - `otherSettled` vs Completed-only (`:412-423`);
  - `OrderedAfter` (`:365`);
  - exact op counts (`RecoveryPolicy.hs:98, 163-165, 223, 274`);
  - fresh-preflight vs journalled refusal (`Recovery.hs:610-616`).

That makes roughly **10 independent exit predicates and about 35 literal allowlist entries**. Each one encodes "this operation had no effect" or "this operation's effect is settled" indirectly, through the review's shape, instead of asking the operation's own proof.

### How each finding widened them

| Finding | Commit | Widening |
|---|---|---|
| F09/F13 | d16d0094 | new exit R10 (prune shape) + R15g |
| restore | 303a7269, b3e5e7f9 | new exits R11, R12 (shape predicates) |
| F14 | 0c757b74 | R15e (Deployment) + R5 (Deployment-only continuation) |
| **F16** | 0f6fa7db, 49db2199 | new exit R7/R8 (Application, Knative create, `otherSettled`), new release semantics, R17 (Application only) |
| F29 | b805d64a | R8 + Standalone preview DomainMapping branch; R15e + domainmapping |
| F30 | 95b58a24 | R8 + never-intended Update path; companion = never-intended ConfigMap create ordered after; R15f |
| **F35** | 570467f0 | new exit R9 (Pending + fresh preflight), using `releaseAbortedClaim` |
| F36 | 6d7951c9 | R12 + `redisRestoreOnlyReview`; R15d |
| **F37** | d9aed800 | R9 + `Failed KnownNoEffect` |
| **F54** | 96d38d67 | R15b (Knative only) + `LandedUpdateProof` + landed branch in R8 |
| **F55** | 5ac857d0 | companion + any Verify + ConfigMap Update; R17 restricted to Create |
| **F56** | 42ce5d54 | R15c (Knative only) + R7 accepts it |
| **F57** | 42ce5d54 | R15a (Kubernetes only) + R6 |
| **F58** | b244b125 | R18 (retiring scopes), R20, R21 |
| **F59** | 1f8eee5e | R15e + statefulset; R8 + Standalone StatefulSet create, `otherSettled` widened |
| **F63** (WIP) | — | R15b → `workloadAddress`; R8 update path + Standalone StatefulSet, + Application Deployment; `validateBefore` admits an Update of a NotReady workload |
| **F64** (WIP) | — | new `RecoveryTargetDeleted` (Knative/workload); any other owned deleted update → `SafeToRetry`; R7 accepts it |
| **F65** (WIP) | — | R8 create path admits never-started companions |
| F59 gap A (WIP) | — | R17 + Standalone |

Each independent review then found the **sibling** the allowlist missed:
- F55's class gap: CronJobs, DomainMappings and broker triggers as companions.
- F56's: deletion (now F64).
- F57's: Broker, CDN, Cloudflare and Foundation verifies.
- F59 gaps A and B: Standalone never-started set; broker topics under `BrokerExecutor`.
- F54's: other workload kinds (now F63).

The model keeps finding these because the predicate space (scope kind × resource kind × action × executor × journal state × digest-order position) is a product, while each fix adds one point in it.

### 2.1 Hazards in the current exits (inferred; reproduction needed before filing)

**H1 — abandon disowns unrelated stopped scopes.**
- `releaseAbortedClaim` sets `headAccepted = headConverged` for **every** scope (`Claims.hs:222`), not just the abandoned review's changed scopes.
- After an F16/F54/F59 stop, scope A has accepted ≠ converged; on a first deploy, A is absent from converged.
- Any later `abandon-refused-operation` (R9), `abandon-partial-*` (R10–R12) or `recover-fenced-backup` (R13) on any transaction reverts A. If that transaction is A's own correction, A's created members (including F16's PVC with the seeded row) are no longer accepted.
- The next plan then refuses each of them `unverified-owner` (`Plan/Changes.hs:711-716`). Adoption covers only unstamped objects (`:717-720`), so the scope has no exit and the data is orphaned.

**H2 — abandon orphans its own completed creates.**
- This is documented ("completed earlier effects remain unaccepted until a separate reviewed recovery", `Recovery.hs:625`; runbook lines 186-190).
- No reviewed recovery exists for stamped but unaccepted objects. The same `unverified-owner` refusal applies when the same scope is replanned. F35's native run escaped this only because the restore used a fresh ID.

**H3 — abandon after a member removal can make the head unloadable.**
- Admission moves removed members into `headRetained` (`Admission.hs:204-214, 230`).
- `releaseAbortedClaim` reverts accepted but leaves `headRetained`.
- If the review also removed a member, as an ordinary `app deploy` that drops a member with an approved retention does, and any op is then refused, for example a foreign field manager (F37), the abandon re-activates a scope whose member is also retained.
- `loadInventoryHistory` then fails every load with "active retained resource lacks a disjoint reviewed migration" (`Plan/History.hs:168-189`).

**H4 — "verify writes nothing" is not universal.**
- `Host.executePlan` runs `hostRunActivation` for any action, `VerifyResource` included, when the state is before-activation at the expected closure (`Adapters/Host.hs:84-94`, `:139-154`).
- Foundation's verify is safe: `preflightState` refuses a digest mismatch, `Foundation.hs:193-202`.
- A generic F57 fix must therefore be enforced by the driver, not assumed.

---

## 3. A general proof-based exit: `close-transaction`

### 3.1 Per-operation proof classes

For an active transaction T with review R (base revisions B, desired revisions D) and journal J, every operation `o` gets exactly one class. The driver computes it in this order, and the first match wins.

| Class | Source of proof | Meaning |
|---|---|---|
| **Completed(p)** | J holds `Completed p` | effect proved; already durable |
| **NeverStarted** | J has no `IntentRecorded`, `Ambiguous`, `Failed`, intent-carrying `OperatorResolved` (`bootstrap-registry-intent:`, `fence-*`, `adapter-proved-safe-retry`) or `Completed` event for `o` | no effect, by the intent-before-effect invariant (`Driver.hs:373` precedes `:381` and `:397`) |
| **Refused** | latest J state is `Failed (KnownNoEffect _)` | adapter guaranteed a pre-effect refusal |
| **Reverted(p)** | J holds `fenced-recovery-proved:p` and the fence recovered | effect undone with a verified backup |
| **NoEffect(e)** | `plannedAction o == VerifyResource` (driver-enforced: no `adapterExecute` for verifies, §3.3 O6), **or** `adapterSettle` returns `NoEffectProved e` | nothing written |
| **Landed(phys, e)** | `adapterSettle` → `Landed` | the exact reviewed effect is on the exact reviewed incarnation; the completion criterion (readiness) is not met |
| **TargetGone(mphys)** | `adapterSettle` → `TargetGone` | the conditional write's precondition can no longer match any live object (deleted, or replaced under another UID). Nothing of ours is live. |
| **TerminalPartial(phys)** | `adapterSettle` → `TerminalPartial` | a run-to-completion effect of the reviewed object ended terminally (failed Job, failed scratch pod); its residue is identifiable |
| **Unknown(reason, resolvesBy)** | anything else | blocks; `resolvesBy` must name the observation or event that will reduce it |

`adapterSettle :: PlannedOperation -> PreparedNative -> IO Settlement` replaces the stop-only constructors of `RecoveryDecision`:
- `LandedUnready`, `TargetReplaced`, `TargetDeleted` and `TerminalFailure` become `Settlement` cases.
- `AwaitingReadiness` for a create becomes `Landed`.
- A default `settleFromRecover` derives `Completed` from `ProvedComplete` and everything else as `Unknown`, so adapters can opt in one at a time.

### 3.2 The rule

**CLOSE(T).** The operator names a transaction, not an operation. CLOSE is admissible iff:

1. **Authority.** T is the active transaction; there is no data fence (`headDataFence`) and no migration (`headMigration`), and no migration stage op has recorded intent. The fenced and migration state machines stay separate, and their terminal step calls CLOSE. The adapter identity and version match the review. CLOSE runs under the process lock and the resume claim, as today.
2. **Stuck (liveness, not safety).** Resume cannot progress now:
   - no `Pending` op with complete dependencies passes a fresh preflight; and
   - no recoverable op's adapter returns `ProvedComplete`, or `SafeToRetry` with dependencies complete.

   This keeps today's "resume instead" behaviour (`Recovery.hs:615`) and the F29 requirement of no arbitrary abandonment.
3. **Classified.** No operation is `Unknown`.

**Effects.** There is one journal append, then one conditional head write, and **no provider write**.

- **E1.** Publish a close record. It holds the per-op class and evidence, the per-scope disposition, and the never-started set N(T) defined below. Append `OperatorResolved "closed:<record-digest>"` to the transaction. A replay finds the event and goes straight to E2, generalizing the saved-stop replay in `Recovery.hs:470-471` and `:491-492`.
- **E2.** Head:
  - clear `activeTransaction` and the claim;
  - **`headConverged` unchanged**;
  - **`headIncarnations` unchanged**;
  - **untouched for every scope R did not change**;
  - for each scope S with `B[S] ≠ D[S]`:
    - **Revert**, if every op whose resources S owns is `NeverStarted`, `Refused`, `NoEffect` or `Reverted`: `accepted[S] := B[S]` (the review's base, **not** `headConverged`), and remove from `headRetained` exactly the keys this review's retentions and migrations added for S.
    - **Keep**, otherwise (any `Completed`, `Landed`, `TargetGone` or `TerminalPartial`): `accepted[S] := D[S]`. Ownership of everything created or landed is retained.

  The rule is "a close never disowns and never resurrects". Revert happens only when no object the review could have created exists because of it, and it undoes admission's retained moves together with the revision. This fixes H1 (per-scope, base not converged), H2 (Keep when anything landed) and H3 (`headRetained` undone with the revert).

**Never-started set.** N(T) = { m : op `o`, `plannedAction o == CreateResource`, class ∈ {`NeverStarted`, `Refused`}, `m ∈ resources o`, and the adapter observes m **ConfirmedAbsent at close** }.
- It is valid while `headAccepted[owner m] == D[owner m]`. Every scope kind is covered, which fixes F59 gap A.
- Only creates qualify, which keeps F55's filter: a member that was only verified or updated and later goes absent stays `durable-resource-missing`.
- The absence observation at close excludes members that another member's controller created (O8) or that something out of band created.
- R17 becomes "read the latest close record whose D matches the accepted revision". The re-validation through R8 (`History.hs:534-539`) disappears.
- A later Revert of the next transaction restores `accepted[S] = D(T)`, which re-validates N(T) automatically.

**Follow-up exits CLOSE guarantees.** The store is idle, so any review can be planned. For a Keep scope S:
- **Correct.** A present owned member plans a verify or update. That includes an update of an owned NotReady object of any kind the adapter can classify `Landed`, which generalizes WIP `validateBefore`. An absent member in N(T) plans a create. An absent stateless member plans a create. An absent durable member outside N(T) refuses `durable-resource-missing` (`Changes.hs:735-740`), unchanged: that data loss was not caused by the close. A `TargetGone` member plans from the live replacement (F56 semantics); if it is data-bearing, F49's `replaced-incarnation` and ingestion refusals still apply. R22 keeps verifying unchanged members.
- **Retire.** A present member gets a retention proof naming its recorded incarnation (F51). An absent stateless member, or a member in N(T), gets an absence proof. Admission's `holdsNoData` (`Admission.hs:318-323`) reads the same N(T).
- **Revert scopes.** These are as if R had never been admitted.

### 3.3 Per-adapter obligations (the contract `adapterSettle` must meet)

- **O1 Totality.** For every provider state reachable from the reviewed before-state, `adapterSettle` returns a non-`Unknown` class. "Reachable" means this op's effect, any prefix of it, a lost acknowledgement, and foreign edits, replacement or deletion. `Unknown` is allowed only when the provider is unobservable or the effect may still be in flight (a running Job, an armed host rollback timer), and it must carry `resolvesBy`. This is testable per adapter: a property over the adversary's fault set, the EP-173 worlds generalized, asserting `Unknown ⇒ unobservable ∨ in-flight`.
- **O2 NoEffectProved.** Only when the observation proves every address the op could write is still in its reviewed before-state (identity and version). `SafeToRetry` is **not** `NoEffect`: `KubernetesMigration.hs:283` (TransferState) must stay `Unknown(retrySafe)`, which is exactly F61's hazard.
- **O3 Landed(phys).**
  - For an update, the live object has the reviewed before-UID and owner. For a create, it carries the owner stamp and the reviewed digest with an Absent before-state.
  - The reviewed spec digest holds, the controller has observed the generation, and no foreign non-status field owner exists.
  - The completion criterion is unmet, judged by kind: conditions for Knative, replica counts for Deployment and StatefulSet (WIP `KubernetesConfiguration.hs` live `:104-121`).

  This is F54's proof stated once for every kind.
- **O4 TargetGone(mphys).** Only when the conditional write's precondition (UID or resourceVersion) cannot match: absent, or present under another UID with the member's stamp. The live identity goes only into the close record as evidence. **It is never bound as an incarnation.**
- **O5 TerminalPartial(phys).** Only for a run-to-completion object of the reviewed review (owner UID) whose failure is terminal: R15d and R15g, generalized.
- **O6 Verify writes nothing.** The driver skips `adapterExecute` for `VerifyResource`; verification is only `adapterVerify`. Without this, H4 makes the generic `NoEffect` unsound for Host.
- **O7 Intent before effect.** No adapter, recovery capability or fence writes before the driver's intent event. This should be a model invariant: no provider write without a prior intent event for that op.
- **O8 Controller-derived members.** A member that another member's controller can create, for example through a `volumeClaimTemplate`, enters N(T) only when it is observed absent at close.

### 3.4 Safety argument

- **U (I2).** CLOSE never advances `headConverged`. `headAccepted` only takes D (reviewed) or B (previously accepted). No incarnation is bound at close. `Landed` effects are recorded as landed and not converged; the next review must prove them through R22 verifies.
- **D.**
  - No provider write occurs.
  - Revert is restricted to scopes where no op had any effect, so no object of ours can be disowned. Revert also removes the review's own `headRetained` additions, so no member can be simultaneously active and retained.
  - Keep retains ownership of every created or landed member, data-bearing ones included.
  - A durable member becomes re-creatable only if its create provably never started **and** it was absent at close.
- **I.** No binding happens at close. Existing records are untouched. A `TargetGone` replacement is evidence only. F49 status and ingestion and F51 retention keep comparing against records.
- **R (I4).** No writes, so there is no repeat. `Completed` ops keep their proofs. A later review plans from live observation: a landed spec equal to the new desired spec plans a verify, not a write.
- **Liveness (I1).** If every adapter meets O1, every stopped transaction admits CLOSE once its provider is observable and nothing is in flight. The model's exit search becomes "CLOSE or Resume" instead of 11 actions.

---

## 4. Checking the general rule against every finding

| Finding | Classes at the stall | CLOSE result | Same as today? | Unsafe admission? |
|---|---|---|---|---|
| F16 | Service create `Landed`; PostgreSQL and PVC `Completed`; signing key `NeverStarted` | Keep; N(T) = {signing key} | yes | no |
| F29 | DomainMapping create `Landed`; Service and PVC `Completed` | Keep; the `previewScopeMembers` proof is no longer needed | yes | no |
| F30 | Service update `NeverStarted` (preflight refused); ConfigMap create `NeverStarted`; backup create `Completed` | Keep | yes; no "ordered after" requirement | no |
| F35 | restore Service `Completed`; PVC `NeverStarted` + fresh refusal (stuck) | Keep: scratch Service stays owned, retire later | **changed**: today it orphans the object (H2) | no |
| F36 | scratch StatefulSet `TerminalPartial`/`Landed`; Service and PVC `Completed`; Job `NeverStarted` | Keep, no shape predicate | **changed**: scratch objects stay owned instead of orphaned | no |
| F37 | Service update `Refused`; topic verify `NoEffect` | Revert to B | yes; and if a create had completed, Keep fixes H2/H3 | no |
| F49 / F51 | — | no incarnation binding or retention at close | — | no laundering |
| F54 | Service update `Landed` | Keep | yes | no |
| F55 | companions `NeverStarted` (any action, kind, order) | Keep; a durable verify stays outside N(T) | covers the class gap (CronJob, DomainMapping, triggers) | no |
| F56 | `TargetGone(new UID)` | Keep; replacement recorded as evidence only | yes | no |
| F57 | verify `NoEffect` (any executor, with O6) | Revert or Keep by the other ops | covers the class gap (Broker, CDN, Cloudflare, Foundation) | no, given O6 (H4) |
| F58 | — | N(T) read by absence proofs and admission | yes | no |
| F59 | StatefulSet create `Landed`; signing key and schedule `NeverStarted` | Keep; N(T) covers Standalone (**gap A**); broker topics `NeverStarted` regardless of executor (**gap B**, if the broker StatefulSet's create classifies `Landed`) | widens | no |
| F63 | Deployment or StatefulSet update `Landed` (O3 by replica counts) | Keep | yes, without History changes | no |
| F64 | `TargetGone(Nothing)` | Keep | yes | no |
| F65 | create path, companion update `NeverStarted` | Keep | yes | no |
| F09/F13 prune | Job `TerminalPartial` | Keep | **changed** (today it reverts) | no; partial deletions are recorded, not accepted |
| F14 / F15 | progress rules (R5, R14), not exits | unchanged | — | — |

**Not covered by CLOSE:**
- **F60.** Incarnation binding at convergence from the create's own UID. CLOSE deliberately binds nothing, so it inherits the fail-open limit for data-bearing creates that complete in a closed transaction.
- **F61.** A partial rename transfer. Migrations are excluded (writers are fenced, so closing would leave consumers switched off). That needs a forward exit or an idempotent transfer (WIP's marker file).
- **F62.** Planning-time source identity; not an exit question.
- **Unobservable providers and in-flight effects.** These stay blocked by design (`Unknown` with `resolvesBy`).
- **Fenced live restores.** They keep the R13 phase machine; only its final `releaseAbortedClaim` becomes CLOSE.
- **R5 `continueReadiness`.** It is still a Deployment-only progress allowlist; generalizing it is separate work.

**Behaviour changes that need an operator decision:** F35, F36 and prune move from "revert accepted and orphan the residue" to "keep the scope accepted but unconverged; retire to clean it". F29's "no generic arbitrary abandonment" is honoured by precondition 2 ("stuck") and precondition 3 (classified).

---

## 5. Change size and deletions

| Area | Delete | Add / change |
|---|---|---|
| `Plan/History.hs` | `incompleteApplicationOnlyReview` + `LandedUpdateProof` (`:279-444`, ~166 lines); R17's stop re-validation (`:491-568`, ~75) | ~45 lines reading close records |
| `Execute/RecoveryPolicy.hs` | 4 `*OnlyReview` predicates (`:64-278`, ~215) | `recoverableState` gains `closed:` |
| `Execute/Recovery.hs` | stop branch, 3 `AbandonPartial*` branches, `abandonRefused` (`:470-572`, `:593-626`, ~140) and gate clauses `:287-311` (~20) | `closeTransaction` with classifier, stuck check and record (~150) |
| `Execute/Claims.hs` | `releaseStoppedApplicationClaim`, `releaseAbortedClaim` (`:170-225`, ~56) | `releaseClosedClaim` per scope with retained undo (~55) |
| `Execute/FencedRecovery.hs` | — | 3 call sites switch to CLOSE (~10) |
| `Execute/Driver.hs` | stop-only constructor arms | skip execute for verifies (O6), settle mapping (~20) |
| `Execute/Types.hs` | 5 actions merge into `close-transaction` (old names kept as parse aliases) | ~15 |
| `Adapter.hs` | stop-only `RecoveryDecision` cases | `Settlement` type, `adapterSettle` + default (~45) |
| `Adapters/Kubernetes.hs` | `:304-413` restructured | total `settle` across kinds (~+120/−100) |
| ~15 other adapters | — | `settle` or the default (~5–25 lines each, ~150) |
| `Admission.hs`, `Plan/Changes.hs`, `Plan/Types.hs` | — | N(T) source swap (~20) |
| Tests | `InventoryLandedUpdateStopSpec` (333), `InventoryRefusedPreflightRecoverySpec` (163), `InventoryRedisRestoreRecoverySpec` (179), `InventoryPreviewRecoverySpec` (152), `InventoryApplicationUpdateRecoverySpec` (330): rewrite assertions to CLOSE (~400 lines changed) | model `recoveryActions` → `Resume` + `CloseTransaction`; O1 property per adapter (~200); H1–H3 regressions (~150) |
| Mutation records | about 15 F54–F65 diffs become obsolete | ~6 rule-level mutants: Unknown does not block; revert to converged; revert without retained undo; N(T) admits updates; skip the at-close absence check; bind incarnation at close |
| Docs | runbook §recovery (lines ~140-240) rewritten | ADR 22 amendment or a new ADR, tracker entries |

**Totals:** about 25 files. Source is roughly −800 / +650 lines. Tests change by about 750 lines. That is about 2–3 implementer days, plus an operator decision on the F35/F36/prune semantics change. Before the redesign, the H1–H3 hazards should each be reproduced in the recovery model:
- H1: stop, then an abandoned correction;
- H2: replan the same scope after abandon;
- H3: a member-removing deploy with a foreign-manager refusal.
