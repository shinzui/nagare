# MP-23 implementation audit

Audit of working tree based on `9bb44baf`, including concurrent uncommitted changes. Findings were sent directly to the active implementation session as they were established. This is a focused audit of store I/O, transaction execution/recovery, host bootstrap, and status; it is not certification of every MP-23 module.

No cloud mutations or deployment rehearsals were run by this audit. Production source was not edited here. Reproductions use actual Haskell functions with in-memory object effects or the actual shell activation function with command fakes.

## Open findings

### P1 — Scheduled-prune admission preflight blocks recovery of admitted transactions

Locations: `cli/nagarectl/app/Main.hs`, `inventoryExecutionRegistry` (~6551), `verifyReviewedScheduledPruneProvider` (~6981); `cli/nagarectl/src/Nagare/Inventory/Command.hs`, `recoverInventoryWithFactory` (~499); `cli/nagarectl/src/Nagare/Inventory/Execute.hs`, `admit` (~194).

The registry factory runs the new provider preflight for apply, resume, and explicit recovery before the generic transaction code can examine operation state. Admission has already added the prune scope to `headAccepted`. The preflight constructs `pruned` from those accepted scopes and removes that backup from `backups`, then requires the selected backup to be in `backups`. This contradicts itself on resume of the admitted prune. A partial deletion additionally fails the complete original provider listing and version checks. The original transaction therefore cannot reach `AbandonPartialPrune` through the public recovery route.

Evidence: traced the real factory, admission, and recovery call chain and predicates. No live prune was run. This affects the retained recovery contract even though new scheduled-prune admission is deferred.

Correction: put pre-effect validation at the state-aware execution boundary; distinguish admission from completed/ambiguous-operation recovery. Require a public-route regression beginning with an admitted, interrupted original prune, including both no effect and a partially deleted pair.

### P1 — Matching installed age key can strand service-activation recovery

Locations: `scripts/inventory-host-transport.sh`, `activate` (~203–216); `nixos/modules/nagare-host.nix`, helper `install_key` (~149–155).

The helper marks the key verified and stops removing it on failure before restarting sops and Tailscale. If restart fails or execution is interrupted there, the installed digest is correct but the host is not enrolled. Transport retry sees the matching digest, skips the helper, and only requests the Tailscale address. It never retries the failed activation phase.

Evidence: `AgeKeyRetryAudit.sh` extracts the current activation function. With a matching ready key and unavailable Tailscale address, two invocations both exit 1 and call exactly `status`, `status`, `tailscale ip -4`; neither invokes reactivation. No provider calls occur in this reproduction.

Correction: explicitly recover activation after matching-key installation, with service/readiness evidence. The helper's same-key install path already avoids rewriting the key and does activate services. Test failure after key persistence and before service activation, followed by public same-transaction recovery.

### P1 — Journal writes retain large serial subprocess overhead after replay batching

Locations: `cli/nagarectl/src/Nagare/Inventory/Execute.hs`, `appendEvent` (~1154); `Store.hs`, `publishIfAbsent`, `replaceHeadIfGenerationMatches`, `replaceObjectHead`; `Store/ObjectOps.hs`, `get` and `put` (~165–199).

A normal noninitial append calls five GETs of present objects, two GETs of absent objects, and two PUTs. Present-object GET performs describe/download/describe; absence performs describe plus a listing of the entire prefix. The two absent reads duplicate the same next-event check. Head bytes are also re-read several times.

Evidence: `StoreAudit.hs` instruments ObjectOps while running the actual `appendEvent` body, exposed only in a temporary copy's export list. It records six GETs/two PUTs for the initial event and seven GETs/two PUTs for the next event. In the original read-back transport that expands to 24 and 27 gcloud subprocesses, respectively. An ordinary operation needs intent plus completion records, before counting provider execution and additional claim checks.

The implementation session subsequently began optimizing successful PUT acknowledgements. If the new generation parser succeeds, the same noninitial append still expands to 21 subprocesses. That is a source-derived count, not a measured cloud duration. The source under audit still retains the redundant GETs.

Correction: carry the observed head bytes and provider generation into conditional replacement, remove duplicated absence reads while retaining conditional creation, avoid whole-prefix absence listings where an authoritative object result is available, and reuse validated immutable journal data. Keep ambiguous-upload read-back. Measure append latency and command counts in addition to replay startup.

### P2 — Native-evidence loading scales with all historical reviews

Locations: `cli/nagarectl/src/Nagare/Inventory/Status.hs`, `loadNativeFor` (~345–355); `Plan.hs`, `loadPublishedReview` (~1429–1458); `app/Main.hs`, `runInventoryStatus` (~5948).

Native evidence loading enumerates every published review, then loads every referenced scope and private native bundle before selecting current/retained bindings. Old and unaccepted reviews are included. Cache hits save transfers but still read, hash, decode, and expand history. A cold second workstation performs serial remote fetches proportional to historical review contents. Status called this twice, for accepted and retained resources.

Partial correction observed during audit: `loadRetainedNative` now returns immediately when there are no retained resources. The accepted scan and the second scan when retained resources exist remain.

Correction: index accepted/retained resource incarnations to authoritative native evidence; at minimum select relevant review documents before loading their members and share decoded data between both consumers. Benchmark growing review counts while keeping the current inventory fixed, including a cold cache.

### P2 — An unchanged bootstrap depends on a transient key-file environment variable

Location: `cli/nagarectl/app/Main.hs`, `buildHostStageCandidate` (~5553–5595).

Every bootstrap plan reconstructs the host scope from `NAGARE_HOST_AGE_KEY_FILE`. If the host was accepted with a credential digest, unsetting this variable after successful delivery produces `Nothing`, changes both desired spec digest and declared operation inputs, and fails equality against the accepted scope. An absent local key file also fails before recognizing that the host stage is already accepted. The equality includes an absolute `hostRoot` source location, so another operator root can fail despite identical configuration bytes.

Evidence: traced reconstruction, its caller before kubeconfig/cluster planning, and the explicit `prior /= scope` refusal. No live rerun attempted.

Correction: preserve accepted credential binding and stable source identity when inputs have not intentionally changed. Require plaintext key availability only for operations that need to transfer it. Check unchanged replanning after clearing the delivery environment and from another operator root.

### P2 — Explaining one resource performs whole-context observation

Location: `cli/nagarectl/app/Main.hs`, `runInventoryStatus` (~5934–6200), called by `InventoryExplain`; `Adapters/Kubernetes.hs`, `observeAll`; `Adapters/KubernetesRuntime.hs`, `observeKubernetesHealth` (~278).

The requested resource ID is not parsed/used until after all native evidence is loaded, all provider adapters are constructed, all resources are observed, health is probed, and transaction status is loaded. A single-resource explanation, including an invalid ID, pays for unrelated host/cloud/cluster work. Kubernetes observation traverses resources serially; readiness then repeats GETs and context guards for supported resources. Unrelated adapter construction failures can prevent explaining the selected resource.

Correction: validate the requested ID first; restrict provider work to the requested resource and necessary live dependencies. Keep graph-only dependency/consumer information pure. Reuse the same UID-bound observation payload for readiness, or batch selected observations while preserving identity checks.

## Findings corrected concurrently

- **P1 host mutation despite changed identity/closure:** `Adapters/Host.hs` re-inspected immediately before execution but fell through to `hostRunActivation` for mismatched identities/closures. `HostAudit.hs` first reproduced three cases with successful initial preflight, rejected later preflight, and one mutation callback nevertheless. After the other session's fix, all three return `KnownNoEffect` and invoke zero mutation callbacks. The shell transport also now compares the observed physical identity to `plan.instance` before credential placement. Shell guard was source-inspected, not live-tested.
- **Active status retained per-event replay:** `Status.loadActiveTransactionStatus` still used individual object reads after execution gained batching. The other session corrected it. `StoreAudit.hs` now validates real 50/500-event chains using zero individual GETs and one batch each.
- **Resume replayed the same journal twice:** resume loaded history and then `execute` loaded it again. The current diff passes the validated events to `executeWithJournal`; source-verified, not separately instrumented.
- **Fresh-login proof could reuse SSH multiplexing:** the new Tailnet SSH calls omitted the no-multiplexing options used by the existing safe-switch client. The current diff now supplies `ControlMaster=no` and `ControlPath=none`. Source-verified.

## Reproduction notes

Artifacts in this directory: `HostAudit.hs`, `StoreAudit.hs`, `AgeKeyRetryAudit.sh`, and `age-key-retry-{1,2}.log`.

Run Haskell probes from `cli/nagarectl` with its existing Cabal environment and common language extensions. StoreAudit uses a temporary export-only copy of Execute.hs to expose appendEvent. Temporary copies of four modules qualify `Data.ByteArray` imports with the package already selected by nagarectl.cabal (`memory`) because the ad-hoc runghc environment exposes both memory and ram. These copies do not change application logic and are outside the repository. The shell probe replaces all provider/mutation boundaries with local functions.

The implementation is changing concurrently. Revalidate the named code paths after repair; historical counts above are explicitly tied to the transport version measured/inspected. Cloud latency and full release acceptance remain unproved by this audit.

Audit report written 2026-09-29T04:42:21.179517+00:00
