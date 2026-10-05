# E — Crash-point review of the inventory transaction store and journal

Snapshot: `m1` at master `09241d35` (clean), package `cli/nagarectl`. Source read only; no build, test run or native run. Paths below are relative to `cli/nagarectl/src/Nagare/Inventory/` unless they start with `app/` or `docs/`.

Classes: **SAFE** (a supported command reaches a consistent idle store; the path is cited) / **WEDGE** (no supported command reaches an idle store; manual or out-of-band repair needed) / **INCONSISTENT** (persisted state contradicts reality or another persisted record) / **UNKNOWN** (depends on provider behaviour or code not traced to the end).

"Lost ack" means the write landed but the caller saw `PutUnknown`/`StoreIoError`. "Refused" means it did not land (`PutNoEffect`, `PutPreconditionFailed`, transport error). "Read fails" means `GetUnknown`.

---

## 0. Store primitives: what a single write can leave behind

| Primitive | Semantics on the object backend (GCS: Gogol or gcloud) | Filesystem (local) backend | Retry behaviour |
|---|---|---|---|
| `publishIfAbsent` (Store.hs:701-720) | Read, then `IfAbsent` put. 412 or a transport error is reclassified by read-back (Gogol.hs:286-294, ObjectOps.hs:133-145): equal bytes count as written. | `doesPathExist`, then temp file + fsync + rename + dir fsync (Store.hs:1292-1297, FileIO.hs:24-43). | Idempotent for equal bytes. **But the read goes through the local digest cache first (Store.hs:1215-1232), so a cache hit skips the remote write (U4).** |
| `appendAtObservedHead` (Store.hs:736-747) | `IfAbsent` put at `journal/<headSequence>`, with no pre-read. | Same as above. | Not idempotent alone. A retry gets `StoreObjectConflict`. `appendEvent` turns that into orphan adoption (F38, Journal.hs:114-135). |
| Head CAS `replaceObservedHead` / `replaceHeadIfGenerationMatches` (Store.hs:772-813) | `IfGenerationMatches g` (or `IfAbsent`). A non-412 failure is read back. Equal bytes count as written. Otherwise `PutNoEffect` or `PutPreconditionFailed`. | Re-reads the head and compares it under an **in-process** MVar only, then renames (Store.hs:807-813). Across processes this is check-then-act. | The generation precondition makes a late-landing or replayed write harmless. Only `Journal.commitHead` (Journal.hs:166-180) re-reads and retries (3x); every other head writer reports one failure and stops (U8). |
| GCS get (Gogol.hs:242-269) | 404 is confirmed absent only by a full listing; anything else is `GetUnknown`. | `doesPathExist` + private-file read. | Callers never treat `GetUnknown` as absence. **SAFE.** |
| Late landing | A request that times out client-side (20 s, Gogol.hs:100,190) can commit server-side after read-back reported `PutNoEffect`. Head: harmless (CAS). Journal: becomes an orphan, which `appendEvent` adopts. Receipts: become visible later and help recovery. | n/a | **SAFE**, except where a release writer reports failure (U1). |

The journal object is always written before the head that commits it (Journal.hs:111-113). The head is advanced only after the journal put returns `Right`, or after the orphan at that sequence has been read (Journal.hs:113, 128). **So the head can never get ahead of the journal on either backend.** On the filesystem backend both writes are fsync-ordered (FileIO.hs:38-41).

---

## 1. Crash-point catalogue

### A. Plan / review publication (Command.hs:478-494, Plan/Publication.hs:67-84)

| # | Interrupt point | Persisted state | Next command | Class |
|---|---|---|---|---|
| A1 | During `initializeStore` / `format.json` creation (Store.hs:574-602, 612-625) | `format.json` and/or head may exist, possibly with a lost ack | A re-run of `plan` re-reads and accepts an equal binding (Store.hs:594-598, 617-620) | SAFE |
| A2 | `seedInventoryHistory` head write (Plan/History.hs:572-610), run by every `plan` **without the process lock** | Head generation +1 with accepted = converged = reconstructed base. This write happens on **every plan while `headAccepted` is empty**, even when there is nothing to seed. | Re-run: a non-empty accepted map returns early. | SAFE for a lost ack. **INCONSISTENT risk (U5):** the write ignores `headActiveTransaction` and the executor claim. During an admitted review whose desired set is empty (retire-all teardown, F40), a concurrent `plan` overwrites `headConverged` with the reconstructed base, which may be `{}`. A later `releaseAbortedClaim` then restores accepted from that wiped map. On the filesystem backend the head write is not atomic across processes (Store.hs:807-813), so it can overwrite a concurrent admission. |
| A3 | Between scope, native and observation member publication and the review document (Publication.hs:69-84) | Unreferenced immutable members | Apply refuses (`loadPublishedReview` reports a missing review). Re-plan republishes idempotently. | SAFE (garbage only) |
| A4 | Public review directory write (Publication.hs:151-169) | `.inventory-review-*` temp directory | Temp directory plus rename is atomic | SAFE |
| A5 | Any member skipped because of a local cache hit (Store.hs:712 → 1215-1232) | Remote lacks the member; this host still "sees" it | Other hosts, `export` and a restored copy report "published review member is missing" | **INCONSISTENT (U4)** |
| A6 | Review becomes stale because any head write bumps the generation (A2's seed, a claim write) | n/a | Admission reports `stale-head` (Admission.hs:133); re-plan | SAFE |

### B. Admission (Execute/Admission.hs:116-241)

| # | Point | Persisted state | Next command | Class |
|---|---|---|---|---|
| B1 | Before the activation CAS (static checks, retention re-observation; Admission.hs:126-200) | Nothing | Re-apply | SAFE |
| B2 | Activation CAS lost ack (Admission.hs:234-236) | Head: active tx, claim (own client, epoch 1), `accepted := desired`, retentions and migrations added to `headRetained`. No journal event. The command reports `head-condition`. | Re-apply refuses (`stale-head` / `active-transaction`, Admission.hs:133-135). `status` shows the active tx. `resume tx-…` acquires the claim (same client) and passes `verifyActiveReview` (Validation.hs:105-139) and runs. | SAFE (resume) |
| B3 | Activation refused | Unchanged | Re-apply | SAFE |
| B4 | After activation, the "admitted" event append fails or the process dies (Admission.hs:238-241) | Head is active. The event may exist as an orphan at `headSequence`. | `resume` adopts the orphan on its first append (same tx, same sequence and previous digest; Journal.hs:140-143) | SAFE (F38) |

### C. Claims and locks (Execute/Claims.hs, Store.hs:851-883)

| # | Point | Persisted state | Next command | Class |
|---|---|---|---|---|
| C1 | Process dies while holding `process.lock` / `inventory-remote.lock` | Lock file only. The `flock`/OFD lock is released by the kernel. | The next command acquires it | SAFE (no stale-lock problem; no clock use) |
| C2 | Dies holding the executor claim | `headExecutorClaim` = own client | The same client resumes or recovers without takeover (Claims.hs:89-97). Another host needs `--take-over` (app/Nagare/Cli/Parser/Inventory.hs:81,102; no help text). | SAFE (stale-claim recovery is explicit; there is no lease, so no clock assumption) |
| C3 | `acquireResumeClaim` lost ack (Claims.hs:96) | Claim epoch +1, own client | Re-run (same client) | SAFE |
| C4 | `releaseClaim` (claim only) refused or lost ack | The `Bool` is discarded at Transaction.hs:121,130,147. The claim stays with the own client. | Resume or recover by the same client | SAFE. Another host needs takeover. |
| C5 | `releaseClaimWith` (convergence) refused (Claims.hs:108-145) | Active tx, `transaction converged` event committed | `resume` re-runs: ops Finished → another converged event → `finalizeCollections` (idempotent) → release (Transaction.hs:128-145) | SAFE (duplicate converged events; widens F60) |
| C6 | `releaseClaimWith` lost ack | Idle head, converged | `resume` reports Converged via `transactionConverged` (Transaction.hs:242-244, Journal.hs:239-240; detail-text match) | SAFE |
| C7 | `releaseStoppedApplicationClaim` refused or crash (Claims.hs:170-195) | Stop marker committed, head still active | Re-run of `recover … stop-incomplete-application`: `savedStop` returns "claim settlement only" (Recovery.hs:470-501, 319-320) | SAFE |
| C8 | **`releaseAbortedClaim` refused or crash after an `abandoned-*` event (Claims.hs:200-225; Recovery.hs:322-334)** | Journal: `OperatorResolved "abandoned-refused-operation"` (or `abandoned-terminal-scheduled-prune` / `-volume-restore` / `-database-restore`) committed. Head: active tx, claim held. | Re-running the abandon refuses: the state is not recoverable, not Pending and not KnownNoEffect (Recovery.hs:285-298; RecoveryPolicy.hs:299-308). `resume` reaches OperationStep.hs:84 `Blocked` → `StoppedFailed`. Apply refuses `active-transaction`. No other action matches. | **WEDGE (U1)** |
| C9 | `releaseAbortedClaim` after a `fenced-recovery-proved` event (FencedRecovery.hs:231,244,290) | Proof committed, head active | `resume` takes the `rollbackProvedOperation` path → `releaseAbortedClaim` (Transaction.hs:248-263) | SAFE |
| C10 | `releaseAbortedClaim` succeeds | `accepted := converged`, but **`headRetained` keeps the retention and migration entries that admission added** (Claims.hs:217-223 vs Admission.hs:204-230) | Later retirement of that resource refuses `retention-history` (Admission.hs:141-144); a re-run migration refuses `migration-base` (Admission.hs:145-151) | **INCONSISTENT (U3)** |

### D. Per-operation driver (Execute/Driver.hs:329-465)

| # | Point | Persisted state | Next command | Class |
|---|---|---|---|---|
| D1 | Before preflight | op Pending | `resume` re-executes | SAFE |
| D2 | Preflight refuses on a Pending op (Driver.hs:371) | Nothing journalled; claim released (Transaction.hs:130) | `resume` re-preflights; `recover … abandon-refused-operation` with a fresh refusal (Recovery.hs:601-626) | SAFE (F35); C8 applies to the release |
| D3 | Preflight refuses on a safe retry (Driver.hs:357-370) | `Failed (KnownNoEffect)` | Abandon allowed by `knownNoEffect` (Recovery.hs:291-292) | SAFE (F57) |
| D4 | Intent journal object written, head CAS fails or crash (Driver.hs:373) | Orphan IntentRecorded; the committed state says Pending | `resume` → preflight → intent append → same meaning, so the orphan is adopted (Journal.hs:132) → execute | SAFE (F38) |
| D5 | Intent committed; crash before `adapterExecute` or claim check (Driver.hs:377-379) | IntentRecorded | `resume` → `adapterRecover` → SafeToRetry only on exact pre-state (Kubernetes.hs:332-334) | SAFE (adapter-dependent, §M) |
| D6 | During `adapterExecute` | IntentRecorded, effect unknown | Adapter recovery decides; F30/F54–F57/F59/F61/F63 cover the known no-exit decisions | SAFE / WEDGE per adapter (F59 Partial, F61, F63 Open) |
| D7 | Effect done; crash before verify or before the Completed append (Driver.hs:426-465) | IntentRecorded | `adapterRecover` proves completion → Completed (Driver.hs:172-182). F38 adoption also accepts differing receipts (Journal.hs:151-156). | SAFE |
| D8 | `AdapterEffectFailed KnownNoEffect` append fails | Orphan or IntentRecorded | Recover → SafeToRetry | SAFE |
| D9 | Verified, Completed append fails | Orphan Completed | Adopted by `sameCompletion` | SAFE (F38) |
| D10 | `executorStillClaimed` false after a takeover (Driver.hs:377-379) | IntentRecorded by the old executor | The new owner recovers | SAFE, with the concurrency caveat in §N |

### E. Journal append and head advance (Execute/Journal.hs)

| # | Point | Persisted state | Next | Class |
|---|---|---|---|---|
| E1 | `observeHead` read fails (Journal.hs:87-89) | Nothing | Retry | SAFE |
| E2 | Journal put refused (Journal.hs:136) | Nothing, or a late landing → orphan | Same-tx adoption | SAFE |
| E3 | Journal put lost ack | Orphan, head unchanged, `Left` returned | Same-tx adoption | SAFE |
| E4 | Head CAS refused, then retried 3x (250/500/750 ms) while the re-read head equals the observed manifest (Journal.hs:166-180) | — | — | SAFE (F38) |
| E5 | Head CAS lost ack | Re-read finds the replacement → success | — | SAFE (F38) |
| E6 | Orphan from **another** transaction at `headSequence` (Journal.hs:122) | — | `StoreObjectConflict` forever | Not reachable: every path that ends a transaction does so only after a successful append (Transaction.hs:135-145; Recovery.hs:317-342; FencedRecovery.hs:212-244). SAFE as traced. |
| E7 | Orphan with a different meaning from the same tx | Committed as history; the new event goes after it (budget 2) | — | SAFE (F38). The latest event defines op state; adopting a stale IntentRecorded only adds a recovery step. |
| E8 | `readJournalPrefix` (Store.hs:1251-1272; Gogol batch 295-324) | Partial download is never returned | — | SAFE (F02/F06) |

### F. Convergence, collection, incarnation binding (Execute/Transaction.hs:128-203, Execute/Incarnations.hs)

| # | Point | Persisted state | Next | Class |
|---|---|---|---|---|
| F1 | After all ops Completed, before the `transaction converged` append | Active | `resume` → OperationsFinished → append | SAFE |
| F2 | After the converged event, before `finalizeCollections` | Active, `headRetained` still holds the deleted members | `resume` → `finalizeCollections` (proofs match retained or own tombstone, Transaction.hs:160-171) | SAFE |
| F3 | `finalizeCollections` CAS lost ack | Tombstones written, `Bool` False → fallback | `resume`: `collected` filter is empty → True (Transaction.hs:185-199) | SAFE |
| F4 | `convergedIncarnations` observation fails or is delayed (Incarnations.hs:47-80) | Records nothing (fail-open). After a crash, `resume` observes at a **later** time. | — | INCONSISTENT window (F60, Deferred). The crash/resume path widens F60's replacement window. |
| F5 | Data fence present at convergence (Transaction.hs:134, Claims.hs:120) | Claim released, active | Fenced recovery | SAFE |
| F6 | Cloud collection deletes without re-checking the incarnation | — | — | F33 (Verifying) |

### G. Review barriers (Transaction.hs:117-122)

| G1 | A review with `reviewBarriers` passes admission: `validateOperationInputs` skips barrier ops (Execute/Inputs.hs:70). Accepted is advanced, then the review pauses and releases the claim. `resume` pauses again, forever. The `preparedFor` failure blocks every recovery action. | **WEDGE (latent, U9).** No production adapter constructs `PreparationBlocked` today (only `Plan/Prepare.hs:100` matches it), so this is unreachable now. |
|---|---|---|

### H. Operator recovery (Execute/Recovery.hs:245-646)

| # | Action | Crash after event, before release | Class |
|---|---|---|---|
| H1 | `accept-adapter-proof`, `retry-after-adapter-proof`, `fence-not-reserved-safe-retry` | Event committed. `releaseClaim` (claim only). `resume` continues: Completed, or the `OperationStep` allowlist reports Execute (OperationStep.hs:80-82). | SAFE |
| H2 | `stop-incomplete-application` | See C7 | SAFE |
| H3 | `abandon-refused-operation`, `abandon-partial-{prune,volume-restore,database-restore}` | See C8 | **WEDGE (U1)** |
| H4 | `recover-bootstrap-registry` intent → execute → proved (Driver.hs:228-263) | Intent marker → `Blocked` until the same `RecoverBootstrapRegistry native`. Re-running replays the registry refresh and k3s restart, which are idempotent by design. | SAFE |
| H5 | `prepare-registry-recovery` publishes a native member without the lock (Recovery.hs:213-230) | Immutable member plus local O_EXCL decision file | SAFE |
| H6 | Recovery claim acquired, then inspection fails (Recovery.hs:313-341) | `releaseClaim`; a lost release leaves the claim with the own client | SAFE |

### I. Data fence (DataFence.hs; FencedRecovery.hs). Reachable only for already-admitted live restores or maintenance sessions: admission defers new ones (Admission.hs:128-132).

| # | Point | Persisted | Next | Class |
|---|---|---|---|---|
| I1 | Reservation CAS refused (DataFence.hs:95) | No fence; `Ambiguous "data fence acquisition…"` | `retry-after-adapter-proof` → `fence-not-reserved-safe-retry` (Recovery.hs:416-442) | SAFE |
| I2 | Reservation lost ack, or crash after reservation | Fence `Acquiring` | `continue-fenced-operation` → `resumeDataFenceAcquisition` (FencedRecovery.hs:93-117) | SAFE |
| I3 | Any `transition` / `writeHead` (DataFence.hs:384-447) refused or lost ack | Phase unchanged, or advanced unacknowledged. No retry or read-back (U8). | Phase-matched recovery action | SAFE (by phase tables) |
| I4 | During the data effect (`Changing`) | `Changing` / `Unresolved` | `verify-fenced-effect` / `recover-fenced-backup` | SAFE (adapter-dependent) |
| I5 | `Releasing`, writers partly restored | `Releasing` | `verify-fenced-effect` → `finishRelease`; `forward-fenced-release` | SAFE |
| I6 | **Fence cleared (DataFence.hs:340), crash before the Completed append (Driver.hs:455-465, FencedRecovery.hs:421-428)** | No fence; op IntentRecorded or Ambiguous; writers resumed | Fenced actions refuse "no active data fence" (Recovery.hs:276-282). `resume` or `accept-adapter-proof` needs `LiveRestoreAdapter.recover` (LiveRestoreAdapter.hs:281-298) to re-verify restored content **after writers resumed**. | UNKNOWN: if live writes change the verified content, this is a WEDGE |

### J. Store migration (Store.hs:955-1148; Command.hs:791-879)

| # | Point | Persisted | Next | Class |
|---|---|---|---|---|
| J1 | Copying members | Partial immutable copies | Re-run: `publishMigrationMember` is idempotent (Store.hs:1083-1090) | SAFE |
| J2 | Staged destination head written (marker → source) | Source still active; destination inert (`mutableHeadAllowed`, Store.hs:815-823) | A GCS-selected command refuses "migrate it first" (Command.hs:717). Re-run migrate re-stages (Store.hs:1114-1117). | SAFE |
| J3 | Source tombstoned (Store.hs:1027-1034), destination not yet activated | Both refuse mutation | Re-run migrate → `activateMigrationHead` (Store.hs:984-992) | SAFE |
| J4 | Activation lost ack | Destination active | Re-run: digest equality (Store.hs:1132-1136) | SAFE |
| J5 | After success, before the profile switch | Old profile points at the tombstone | Commands say "reload"; re-running migrate is idempotent | SAFE (F18 closed covers foundation selection) |

### K. Export and restore (Store.hs:885-950; Command.hs:641-695)

| K1 | Export lists keys, then reads members (Store.hs:888-893). It runs under the per-host lock only, does not refuse an active transaction, and does not check head/journal completeness. A writer on another host between the listing and the `head.json` read produces a backup whose head names journal objects that were never listed. | **INCONSISTENT (U6)** |
|---|---|---|
| K2 | Restore writes members one by one into an empty local store, in sorted order, so `head.json` comes before `journal/` (Store.hs:948-950). A crash leaves a head without its journal. Every command fails "committed journal event is missing", and re-running restore refuses "requires an empty inventory store" (Store.hs:926). | **WEDGE (U6)**: manual deletion of the partial local store |

### L. Object-store open and foundation selection

| L1 | `selectFoundationStore` (Command.hs:730-790) is read-only and bounded (60 s). Unknown remote state refuses. | SAFE (F18, F50 closed) |
|---|---|---|

### M. Retry idempotence of effects (does a retry repeat a proved effect?)

| Adapter | Retry condition | Verdict |
|---|---|---|
| Kubernetes create/update/delete (Adapters/Kubernetes.hs:304-384) | SafeToRetry only if the live object equals `mutationBefore` exactly. Execution is conditional (`kubernetesMutateConditional`). | No repeat. Status churn defeats the equality (F30); deletion with finalizers stays Unresolved until it finishes. |
| Migration secret copy (KubernetesMigration.hs:263-269) | Only when the destination is absent | No repeat |
| Migration writer fence / schedule suspend (KubernetesMigration.hs:271-280) | Only when not yet fenced; scaling to zero is idempotent | No repeat |
| Migration copy Job (KubernetesMigration.hs:283, 486-516) | Unconditional SafeToRetry. An existing Job with the operation label is reused. A completed copy re-runs and verifies equality. | No duplicate copy. A partial copy refuses forever (F61). The source can be replaced (F62). |
| CDN purge (CdnPurge.hs:125-130, 163-190) | Never resubmitted; requires the receipt | No repeat, but **an accepted purge whose receipt write was lost has no exit (U2)** |
| VM power (VmPower.hs:210-216, 320-345) | Never resubmitted when the VM is still in the before-state | No repeat, but **a lost or refused submit has no in-product exit; it needs an out-of-band power change (U2)** |
| Host (Host.hs:162-164) | Same instance and old closure | No repeat (F01) |
| Broker topic / Foundation / Cache / Artifact create (Broker.hs:158, Foundation.hs:142, Cache.hs:126, Artifact.hs:141) | Observed "missing" | UNKNOWN. Correct only with read-after-write consistency and no orphaned provider operation (for example, a Pulumi update left running by a killed CLI). |
| Bootstrap registry recovery (Driver.hs:199-264) | Deliberate replay of the refresh and restart | Idempotent by design |

Store writes: `publishIfAbsent`, migration members and head installs are idempotent. Journal appends become idempotent through F38 adoption. Head writes are generation-guarded. **Restore is not idempotent (K2).**

---

## N. Concurrency

- **Same host, same context.** Mutating commands take a non-blocking `flock` (Store.hs:851-883): `apply`, `resume`, `recover`, `migrate`, `export`, `restore` and `materialize-native`. A second one fails `StoreBusy` immediately. `plan` and `status` do **not** take the lock. `plan` still writes the head (A2's seed, `initializeStore`). On GCS that is a CAS. On the filesystem backend it is a cross-process check-then-act (Store.hs:807-813): **U5**.
- **Different hosts.** Exclusion comes only from executor claims and the head CAS. Admission CAS losers get `head-condition`. Resume and recover refuse a foreign claim without `--take-over`.
- **Takeover has no liveness check and no lease (U7).** `claimEpoch` is incremented (Claims.hs:94) but is checked nowhere and never passed to adapters. `appendEvent` checks only client and transaction (Journal.hs:94-102). The original executor's claim check is a time-of-check/time-of-use gap before `adapterExecute` (Driver.hs:377-397). A takeover while the old process is alive can therefore run the same op twice. Kubernetes conditional mutation refuses the second write; CDN purge and VM power submission are not conditional. The old executor's in-flight journal object then becomes a same-tx orphan that the new owner adopts (Journal.hs:140-143).
- **Two hosts with the same `inventory-client-id`** (copied or restored state directory; Store/Target.hs:150-183) bypass both the per-host lock and the claim check: concurrent resumes interleave appends. **U7.**
- **Clocks.** Timestamps (`claimTimestamp`, `fenceAcquiredAt`, `retainedAt`, event times) are informational only. No staleness or ordering decision reads them. **No clock assumption.**
- **Stale locks.** Kernel-released. Stale claims need explicit action (C2).

---

## O. Findings

### Tagged (tracker IDs)
- **F38** (Closed) — confirmed in source: bounded head retry plus same-tx orphan adoption (Journal.hs:84-180) makes E2–E7 and D4/D7–D9 SAFE. Residual: the retry and read-back exist only in `commitHead`. Every other head writer lacks them (U8) and discards the `StoreError` without the stderr report F38 required for appends.
- **F02 / F06** (Closed) — batch journal prefix read and append without a head re-read (Store.hs:1251-1272, 736-747). SAFE.
- **F35 / F57** (Closed) — refused-preflight exits D2/D3. Their release step is U1.
- **F36 / F13 / F12 / F09** (Closed) — terminal-restore and terminal-prune abandon exits. Their release step is U1.
- **F30** (Verifying) — status churn defeats Kubernetes `requireSameBefore`, so the conditional retry is never proved safe (§M).
- **F54–F57** (Verifying/Closed), **F59** (Partial), **F63** (Open) — adapter recovery decisions with no exit (D6).
- **F60** (Deferred) — fail-open incarnation recording. A crash before release plus `resume` widens the window (F4).
- **F61 / F62** (Open) — copy Job partial copy / replaced source (§M).
- **F33** (Verifying) — cloud collection has no pre-delete incarnation check (F6).
- **F40** (Partial) — retire-all reviews make A2/U5 and U3 reachable.
- **F18 / F50** (Closed) — store selection (L1).
- **F21** (Closed) — CDN purge is never replayed. Its unresolved state has no exit (U2).
- F64/F65 appear only as untracked mutation diffs in the live working tree, not in the snapshot tracker. Not assessed.

### Untagged
- **U1 (P1, WEDGE).** An abandon is journalled before its head release. If `releaseAbortedClaim` is refused, loses its ack without landing, or the process dies, the store is wedged: re-running the abandon is refused, `resume` blocks, and apply refuses (Recovery.hs:285-298, 322-334; Claims.hs:200-225; OperationStep.hs:84). Applies to all four abandon actions. Stop (C7) and fenced backup (C9) have re-entry paths; abandon has none. Fix shape: treat an `abandoned-*` marker like `rollbackProof` in `resume`, or accept a repeated abandon that only settles the claim.
- **U2 (P1/P2, WEDGE).** An `OperatorRecovery` one-shot that is unresolved has no reviewed exit. CDN purge recovery requires a receipt that only `execute` writes (CdnPurge.hs:125-130, 185-190). VM power needs an out-of-band state change (VmPower.hs:333-345). No `RecoveryAction` covers "unresolved one-shot, abandon".
- **U3 (P2, INCONSISTENT).** `releaseAbortedClaim` reverts `accepted` but not the `headRetained` entries that admission added (Claims.hs:217-223). The resource ends up both accepted and retained, which later blocks its retirement (`retention-history`) and a migration re-run (`migration-base`).
- **U4 (P2, INCONSISTENT).** `publishIfAbsent` accepts a local digest-cache hit as remote publication (Store.hs:712, 1215-1232). The status legacy path caches unpublished observation bytes (Status.hs:524, Store.hs:1203-1206), so `plan` and `materialize-native` silently skip publishing them. The cache is keyed only by context name (Store/Target.hs:127-133), so a recreated context or a changed URL can skip scope and native members. Other hosts, exports and restored copies then lack members. This contradicts the invariant stated at Store.hs:684-685.
- **U5 (P3, INCONSISTENT).** The `seedInventoryHistory` head write is lock-free, ignores active transactions, and runs on every plan while accepted is empty. On the filesystem backend it is not atomic across processes (A2).
- **U6 (P3).** Export is not snapshot-consistent and accepts an active transaction (K1). Restore is non-atomic, so a crash needs a manual `rm` (K2). It could stage and rename, as export does.
- **U7 (P2).** Takeover has no liveness check or fencing token, and a duplicated client id defeats exclusion (§N).
- **U8 (P3).** Only `commitHead` retries or re-reads. Release, finalize and fence writers (Claims.hs:144,188,224; Transaction.hs:201; DataFence.hs:427-447) report a bare `False`/`Left`. This is usually recovered through `resume`; it is the cause of U1.
- **U9 (latent).** An admitted review with a barrier pauses forever (G1).
- **I6 (UNKNOWN).** A crash after fence release and before Completed relies on re-verification against data that live writers can change.

### Not covered
Adapters' provider-side consistency (Pulumi, broker, artifact, Cloudflare DNS). The scheduled/backup receipt stores (a separate bucket). The DataFence/Kubernetes capture internals. No model or test was executed. The deep-tier store-fault sweep (`test/InventoryRecoveryModelSpec.hs:122-136`) might exercise U1 if fault ordinals reach the abandon release. Not checked.
