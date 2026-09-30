# MP-23 audit findings tracker

This is the authoritative handoff for implementation findings sent by the audit session. Read it alongside [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). The detailed initial reasoning is in [the audit report](mp23-initial-audit.md); that report is a historical snapshot, while this tracker owns current status.

[The 2026-09-29 operational experiments](mp23-operational-experiments.md) add
source-bound append counts, cold/warm unrelated-history measurements, a controlled
command-factory recovery comparison, and the public unknown-target reproduction.
They update implementation ordering in MP-23/EP-153/156/159 without changing this
tracker's closure statuses. In particular, the synthetic recovery comparison does
not close F09, and the head-snapshot prototype does not close F06.

Implementation owner: existing session `01a0e893-337f-7b82-ac5d-16f41bf5ce21` (Implement typed resource inventories). Independent verifier and tracker steward: session `01a0eb5e-6e5a-7be3-8812-e04e2638bde9` (Review plan and logs). Child ownership below survives either session ending.

## Update and closure rules

- IDs never change or disappear. Include IDs in implementation handoffs and fix descriptions. New findings get the next ID.
- `Open`: fix not established. `Partial`: some cause remains. `Verifying`: a candidate fix exists but closure evidence is incomplete. `Closed`: an independent check proves the stated failure corrected and the required regression evidence is retained. Reopen on failed verification.
- The implementation session updates each **Implementation update** with revision (or exact working-tree source hashes), change, named test/command, result, and remaining limitations. It must not overwrite the auditor's evidence or close its own finding.
- The verifier updates status and **Verification** after checking the affected path. A sent message, acknowledged finding, source edit, test count, or passing unrelated suite is not closure.
- Before advancing an affected native rehearsal, reconcile its P1 findings. Scope reductions do not waive recovery for already-admitted operations. Deferral/dispute requires an explicit reason recorded here; do not silently omit the issue.
- At every handoff, state IDs still Open/Partial/Verifying and the next required check. Link durable evidence in the repository; temporary reproduction paths are supplemental. If sessions end, the next implementer reads this file through the MP-23 entrypoint.

## Status register

| ID | Priority | Finding | Status | Child owner |
|---|---|---|---|---|
| [F01](#f01) | P1 | Host execution mutates after observing a different VM or old closure | Closed | EP-156 |
| [F02](#f02) | P1 | Active transaction status still reads journal entries individually | Verifying | EP-156 |
| [F03](#f03) | P2 | Resume loads the same complete journal twice | Verifying | EP-156 |
| [F04](#f04) | P2 | Native evidence loads every historical review and can repeat the scan | Partial | EP-156 / EP-153 |
| [F05](#f05) | P1 | New fresh-login checks can reuse an SSH multiplexed connection | Verifying | EP-156 |
| [F06](#f06) | P1 | Journal appends retain excessive serial cloud-command cost | Partial | EP-156 |
| [F07](#f07) | P1 | Installed key with failed service activation cannot recover by retry | Verifying | EP-156 |
| [F08](#f08) | P2 | Unchanged host bootstrap depends on transient key-file environment and source root | Partial | EP-156 |
| [F09](#f09) | P1 | Scheduled-prune preflight prevents recovery after admission | Verifying | EP-159 / EP-153 |
| [F10](#f10) | P2 | Explaining one resource observes the whole context | Verifying | EP-153 |
| [F11](#f11) | Build | Conditional-upload optimization has ambiguous try exception type | Closed | EP-156 |
| [F12](#f12) | P1 | A later operation’s preflight blocks recovery of its ambiguous prerequisite | Verifying | EP-153 / EP-159 |
| [F13](#f13) | P1 | Ordinary executor recovery has no terminal-failure branch | Verifying | EP-153 / EP-159 |

F01 and F11 are independently Closed with [retained verification and source identities](mp23-verification.md). F02 has passing local call-count evidence but still needs its retained status-caller regression. All other entries remain Open, Partial, or Verifying as shown.

## F01

**Host execution mutates after observing a different VM or old closure** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Adapters/Host.hs; scripts/inventory-host-transport.sh.

**Audit evidence:** Actual HostAudit reproduction: all three mismatches previously invoked one mutation callback; after the implementation change all three refuse and invoke zero callbacks. Shell physical-ID guard source-inspected.

**Implementation update:** Commit `538b046d`: `Adapters/Host.hs` SHA-256 `9f5d28607bc60a384b7c8031b0c91d360b34817e96468a09b5f4686ec9a9e264`; `InventoryHostSpec.hs` `016bfbdfee91d6f8b281524e6c2b4dbcdcecc03eb67f4cefe156b31263e9d9dd`. `effect-time drift after preflight cannot run host activation` passed in the 38-test focused host run; the verifier's independent closure evidence is linked below.

**Required verification:** Run that checked-in regression; exercise the shell identity mismatch with a command recorder and prove no age-key install/host-switch occurs. Record revision or source hashes and results.

**Verification:** Independently closed; see [commands, results, and source hashes](mp23-verification.md). All seven checked-in host tests pass, including drift refusal; shell identity mismatch exits 2 with zero transport effects.

## F02

**Active transaction status still reads journal entries individually** — P1; **Verifying**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadActiveTransactionStatus.

**Audit evidence:** Actual StoreAudit: valid 50/500-event chains now give successful status with zero single reads and one batch each.

**Implementation update:** Commit `90e06e29`: `Status.hs` SHA-256 `6e16cf573810b7191ab040dbe7ba639160ab137f255901f9dfc5d1b6c2b9d85b`; `InventoryObjectOpsSpec.hs` `e264701f0b2cc9cd5ee3f1a5ba63f6b33bfbb143f49484218e42a20d53cc76ca`. `cabal test nagarectl-test --test-options=--pattern=object` passed 52 tests, including `active status verifies 50 and 500 chained events with one batch each` and gap rejection in the store test. Await independent verification; live timing is F06.

**Required verification:** Add or name a retained regression invoking loadActiveTransactionStatus at both sizes; preserve chain/gap rejection. The wider live timing gate belongs to F06/EP-156.

**Verification:** Not closed. Independent local reproduction passes after the fix; see audit evidence. Remaining closure checks above are pending.

## F03

**Resume loads the same complete journal twice** — P2; **Verifying**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: resumeTransactionWithTakeover, executeWithJournal.

**Audit evidence:** Source trace: resume readJournal then execute readJournal. New executeWithJournal receives already validated events.

**Implementation update:** Commit `90e06e29`: `Execute.hs` SHA-256 `f85330076f5fd386ef572f0dd7a36690c5d3ee9323233e6096ccde2bb6f60f1d`. The object group passed `converged replay needs no provider registry or repeated journal pass` with one batch and `lost journal acknowledgement cannot duplicate an effect`. Commit `32c17c94` adds `active resume reads one journal batch and does not repeat proved effect`; `cabal test nagarectl-test --test-options=--pattern=proved` passed all five selected tests. Independent verification remains.

**Required verification:** Run a same-transaction resume with batch counts and retained operation receipts; require one prefix read and no repeated completed native effect.

**Verification:** Not closed. Awaiting the checks above.

## F04

**Native evidence loads every historical review and can repeat the scan** — P2; **Partial**; owner EP-156 / EP-153.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadNativeFor; cli/nagarectl/src/Nagare/Inventory/Plan.hs: loadPublishedReview.

**Audit evidence:** loadNativeFor expands every review and its scope/native members. Status invokes accepted and retained loaders. A cold cache makes historical review count a remote-I/O multiplier.

**Implementation update:** Commit `90e06e29`: `Status.hs` SHA-256 `6e16cf573810b7191ab040dbe7ba639160ab137f255901f9dfc5d1b6c2b9d85b` adds the empty-retained fast path. The object-group tests passed, but they do not measure unrelated review history; accepted and nonempty-retained scans remain unresolved.

**Implementation update (2026-09-29):** [Production proof and exact source hashes](mp23-selected-read-proof.md): status/explain now reads opaque digest-bound observation inputs, with two cold native GETs for two selected bindings independent of 0/500 reviews and 0/50 siblings. Empty legacy native requests use zero GETs/lists. New publications include raw observation bytes; explicit bounded materialization handles old stores without making it a recovery prerequisite. Full-suite and public corruption/legacy/retained tests pass. The [active-startup repair](mp23-active-startup-proof.md) additionally shares the validated command store and uses selected digest-bound source inputs. One corrupt unrelated archived review no longer blocks this modern-history recovery path. Remains Partial because a legacy missing-byte fallback still scans archives; materialization remains optional for recovery.

**Required verification:** Hold current inventory fixed while increasing unrelated review history; record remote/member decode counts and cold/warm cost. Demonstrate selection of only necessary native evidence while preserving incarnation binding.

**Verification:** Not closed. Awaiting the checks above.

## F05

**New fresh-login checks can reuse an SSH multiplexed connection** — P1; **Verifying**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: tailnet_fresh_closure, activate.

**Audit evidence:** New Tailnet calls omitted ControlMaster=no/ControlPath=none while the existing safe-switch verifier uses both.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression `scripts/test-inventory-host-transport.sh` SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed, capturing `ControlMaster=no` and `ControlPath=none` on both fresh-login paths. A real multiplexed-connection fixture remains for independent verification.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) reproduces a real control-master session falsely committing after key revocation: NIX_SSHOPTS preceded the mandatory no-multiplexing flags, and OpenSSH used its first values. Mandatory fresh options now precede ambient options. A real loopback sshd/master fixture proves all three production fresh-login paths reject the revoked key and accept restored authorization; safe-switch returns 4 without commit. Independent verification remains; this implementer does not close the finding.

**Required verification:** Capture argv for every call that contributes fresh-login proof and assert both options. Retain a regression with multiplexing configured; verify the proof comes from a new connection.

**Verification:** Not closed. Awaiting the checks above.

## F06

**Journal appends retain excessive serial cloud-command cost** — P1; **Partial**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: appendEvent; cli/nagarectl/src/Nagare/Inventory/Store.hs; cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs.

**Audit evidence:** Measured actual appendEvent ObjectOps trace: noninitial event has five found GETs, two absent GETs, two PUTs. Original transport expands to 27 subprocesses/event; successful PUT fast path projects 21. No cloud-duration claim from these counts.

**Implementation update:** Commit `90e06e29`: `Store.hs` SHA-256 `93391593cd3eee4d59ac8e2d75ab661dfee52d90fa3ef1f5d504c4701ecfe6a2`, `ObjectOps.hs` `028959447fd85a512c6ef1c28cb5f9b31aeb4193ea624fc4202a7e1334d5eef8`, and `Execute.hs` `f85330076f5fd386ef572f0dd7a36690c5d3ee9323233e6096ccde2bb6f60f1d` batch replay, use the successful-upload generation, and append from the observed head. The object-group command passed `known-head journal append uses one conditional write without rediscovery` and the lost-ack case. A complete append subprocess trace and real cold/warm 50/500-event latency are still missing; the last real warm no-op was 41.04 seconds at 61 events.

**Implementation update (2026-09-29):** [Production append/command traces and source hashes](mp23-selected-read-proof.md) establish 5/8 subprocesses for actual complete append (previously 8/11), with a stale-provider-generation injection still refused. `ObservedHead` is opaque and store-bound. Resume reuses its validated head for journal loading; 12 full public no-op command cases now cost 12 subprocesses each (previously 15), independent of 50/500 events and 0/50/500 unrelated reviews. The 943-test suite includes provider-generation ABA, migrated-head refusal, takeover and lost-ack regressions. The [active-startup proof](mp23-active-startup-proof.md) now records the real factory, independent review/event scaling, and no-workspace recovery. Remaining head/claim transport, legacy archive cost, and real GCS latency still gate closure; status remains Partial.

**Claim/publication repair (2026-09-29):** [The public race and command proof](mp23-head-claims-proof.md) covers an intervening identical-head provider rewrite before acquisition. Claim/admission/release/finalization CAS now consumes the original observed generation. Explicit recovery also shares its first head with journal loading. Exact uncached publication lookup replaces execution-time archive listings; a valid local cache cannot authorize an unpublished review. F06 remains Partial pending full command-wide reuse and actual GCS latency.

**Retained replay proof (2026-09-29):** The [auth/replay checkpoint](mp23-auth-replay-proof.md) passes three cold/warm complete public no-op pairs on the original 61-event real-GCS transaction: cold 4.320–7.397 seconds, warm 3.905–4.708 seconds. Each cold run uses a new local root; no history is copied, no native executor runs, and the exact GCS head generation stays unchanged. A reproduced failed-refresh amplification bug is also fixed and the full 975-test suite passes. The historical 41.04-second retained warm failure is superseded for this candidate. F06 stays Partial for real 500-event replay, active append/provider timings and independent verification.

**500-event cloud repair (2026-09-29):** [The scaling proof](mp23-gcs-scale-proof.md) records the first warm failure at 12.783 seconds and a failing local HTTP test proving seven workers idle behind a slow eighth response. Eight persistent workers now share a queue, preserving exact-generation reads and the concurrency cap. Three real 500-event cold/warm pairs pass at 7.670–9.139 / 8.042–9.371 seconds, with isolated fetch/setup measurements. The same binary also passes retained 61-event pairs at 3.669–4.089 / 3.688–4.066 seconds. All 977 tests and exact generation cleanup pass. F06 remains Partial for active claim/append/finalization/provider timing and independent verification; the no-op scaling evidence is now established.

**Active driver measurement (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) completes original-transaction recovery in twelve public CLI loopback cases; lost write acknowledgements still converge and claim races refuse before provider work. Real GCS production-driver samples take 9.063/14.582 seconds including auth/setup at 50/500 events, with four chained publications and released claims. Journal replay takes 0.937/6.893 seconds; four journal writes total 0.340 seconds at either size. All 598 exact benchmark generations were cleaned; the retained head is unchanged. Provider observations in this cloud probe are synthetic. F06 stays Partial for complete public active cloud/provider cost and independent verification, not for the already measured isolated append/finalization or no-op gates.

**Required verification:** Retain append and resume command-count regressions, preserve conditional writes/lost-ack recovery, then pass EP-156 cold/warm real GCS timing gate. Record append/provider/replay timings separately; no closure from one batched cp.

**Verification:** Not closed. Awaiting the checks above.

## F07

**Installed key with failed service activation cannot recover by retry** — P1; **Verifying**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: activate; nixos/modules/nagare-host.nix: install_key.

**Audit evidence:** Extracted activate() with matching installed digest and unavailable Tailscale: two attempts each call status,status,IP then fail; neither reactivates. Helper preserves verified key before service restart.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed: same installed key plus failed service triggers one helper activation and a fresh login, a ready host triggers none, and a different key refuses. Independent full retry verification remains.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) executes the actual helper body and transport functions with simulated privileged/service/network boundaries. Separate sops and Tailscale failures after verified key persistence recover on the identical activation request without rewriting its inode/mtime/content. A ready retry skips delivery; a wrong installed key refuses. This exposed helper diagnostic stdout preceding transport JSON; delivery diagnostics now go to stderr and the regression parses the entire stdout as one committed JSON response. The new Nix host-transport-recovery check and 38 focused host tests pass. Real Linux services, saved-host-transaction CLI recovery and independent verification remain open.

**Required verification:** Simulate successful key persistence followed by sops/Tailscale failure, then retry the original operation. Prove activation resumes, no different key is written, fresh-login/readiness succeeds, and wrong keys still refuse.

**Verification:** Not closed. Awaiting the checks above.

## F08

**Unchanged host bootstrap depends on transient key-file environment and source root** — P2; **Partial**; owner EP-156.

**Locations:** cli/nagarectl/app/Main.hs: buildHostStageCandidate.

**Audit evidence:** buildHostStageCandidate recomputes credential-bound spec/inputs from NAGARE_HOST_AGE_KEY_FILE and compares the entire scope. Removing the variable or moving hostRoot causes accepted-scope mismatch despite unchanged remote intent.

**Implementation update:** Commit `538b046d`: `Main.hs` SHA-256 `fd5d18972afe65e8368e97506a0d697424933ce48463b683436bbbf180314fb4` retains an accepted key digest and source binding when delivery-only environment is absent. `cabal build exe:nagarectl` passed; no public replan with the variable cleared or another operator root has passed, so this remains open.

**Native continuation repair (2026-09-29):** [The native checkpoint](mp23-native-bootstrap-proof.md) confirms fresh host login, then reproduces a further source dependency: bootstrap and build observation reevaluated mutable installation source after host acceptance. The repair preserves accepted host-input checks and observes the exact reviewed build output. The public bootstrap regression now rejects each changed host input and completes kubeconfig recovery and the 211-operation cluster review with Nix disabled after host acceptance. The next native run proved matching digests but rejected serialized input ordering; canonical scope comparison now passes an adversarial-order public fixture. The second-root attempt separately reproduced missing local-marker discovery of GCS history. Installed candidate `0870fa200d07` now replans without the delivery-key variable and completes the native kubeconfig transaction. F08 is Partial for second-root discovery/verification and independent closure.

**Required verification:** After accepting a credential-bound host, clear delivery-only environment and replan; also use another operator root with identical host bytes. Require unchanged/verify-only result while intentional configuration or credential change still refuses/reviews correctly.

**Verification:** Not closed. Awaiting the checks above.

## F09

**Scheduled-prune preflight prevents recovery after admission** — P1; **Verifying**; owner EP-159 / EP-153.

**Locations:** cli/nagarectl/app/Main.hs: inventoryExecutionRegistry, verifyReviewedScheduledPruneProvider; cli/nagarectl/src/Nagare/Inventory/Command.hs: recoverInventoryWithFactory.

**Audit evidence:** Registry factory runs provider preflight before public resume/recover. Admission includes prune scope in headAccepted; guard therefore classifies its backup as pruned, excludes it, then requires it present. Partial deletion also violates original provider-list check.

**Implementation update:** Commit `538b046d`: `Main.hs` SHA-256 `fd5d18972afe65e8368e97506a0d697424933ce48463b683436bbbf180314fb4` skips the pre-admission provider listing during resume/recover and resolves an admitted prune's source through its exact retained owner, revision, Job ID, and physical identity when it is no longer accepted. `cabal build exe:nagarectl` and `cabal test nagarectl-test --test-options=--pattern=transactions` (38 passing) do not prove the public route. No cloud retry is authorized by these results. Add a public saved-review regression at both interruption points, then fix every registry and effect-time failure it exposes.

**Required verification:** Exercise public resume/recover for an already admitted original prune, both before effect and after deletion of one member. Prove exact terminal recovery remains reachable, no blind deletion retry, and new deferred admission still refuses.

**Verification:** Not closed. Awaiting the checks above.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.

## F10

**Explaining one resource observes the whole context** — P2; **Verifying**; owner EP-153.

**Locations:** cli/nagarectl/app/Main.hs: runInventoryStatus / InventoryExplain; cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs: observeKubernetesHealth.

**Audit evidence:** runInventoryStatus uses requested ID only after all adapter construction/observations/health/history. Invalid IDs also pay this cost. Kubernetes readiness repeats GETs for supported objects.

**Implementation update:** Sent to implementation session; no fix verified.

**Implementation update (2026-09-29):** [Public CLI proof and source hashes](mp23-selected-read-proof.md) show selected Kubernetes and Helm observation without a workspace, one selected provider call, no unrelated provider calls, early unknown-ID and foreign-context refusal, retained selection, and independence from 500 malformed reviews/missing sibling natives. Full dependency/consumer declarations remain available, and selected missing/corrupt bytes refuse before provider IO. Status is Verifying, not independently Closed; cloud timing and nonempty legacy execution lookup remain separate F06/F04 work.

**Required verification:** Record provider calls for one-resource explain and invalid ID; unrelated providers must receive none. Preserve dependency/consumer explanation and UID-bound health. Show call count does not grow with unrelated managed resources.

**Verification:** Not closed. Awaiting the checks above.

## F11

**Conditional-upload optimization has ambiguous try exception type** — Build; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs: put.

**Audit evidence:** uploaded <- try (...) originally had only Right/wildcard patterns, leaving Exception e unconstrained.

**Implementation update:** Explicit Either IOException annotation now present in the working tree.

**Required verification:** Record a successful compile of the changed module plus the focused exact-created-generation tests. No separate regression is needed for this type-checking defect.

**Verification:** Independently closed; see [commands, results, and source hashes](mp23-verification.md). Current module compiled and all three exact-generation parser checks passed. This closes only the compilation defect, not F06 performance.

## Communication log

- Audit session sent source findings and subsequent reproduction results directly to implementation session using `send_message_to_thread`; calls returned success. Delivery is established, acknowledgement of every finding is not assumed.
- Follow-up messages reported independently passing host mismatch cases and 50/500-event status batching, and identified partial remaining costs after the new PUT fast path.
- Tracker creation message sent with IDs F01–F11 and a request to acknowledge ownership and record fixes/evidence here. Explicit full-ledger acknowledgement remains pending.
- Independent verification closed F01 and F11; results/source identities are retained in mp23-verification.md and sent to the implementation session.

## Retained local evidence

Host mismatch reproduction, before fix: initial preflight succeeds; changed VM/closure causes a fresh preflight refusal; execution nevertheless returns Completed and invokes the mutation callback once. Cases: replacement Before state, changed old closure, replacement Committed state.

After fix, all three return `AdapterEffectFailed (KnownNoEffect ...)` and invoke zero callbacks.

Status replay after fix:

```text
(active status, 50, success=True, individualGETs=0, batches=1)
(active status, 500, success=True, individualGETs=0, batches=1)
```

Noninitial append, actual ObjectOps trace (prior to subsequent transport optimization):

```text
GET head.json found
GET previous journal event found
GET next journal event absent
GET head.json found
GET next journal event absent
PUT next journal event
GET head.json found
GET head.json found
PUT head.json
```

Transport expansion: five found reads × three subprocesses, two absent reads × two, two uploads with read-back × four = 27. New successful-upload acknowledgement path projects 21; that is not a measured latency or final performance acceptance.

Installed-key recovery before fix, attempts 1 and 2:

```text
exit=1
sudo /run/current-system/sw/bin/nagare-host-age-key status
sudo /run/current-system/sw/bin/nagare-host-age-key status
tailscale ip -4
(no helper activation call)
```

Initial ad-hoc reproduction sources are archived under [mp23-reproductions](mp23-reproductions/README.md). Product regression tests listed above remain the closure requirements.

## F12

**A later operation’s preflight blocks recovery of its ambiguous prerequisite** — P1; **Verifying**; owner EP-153 / EP-159.

**Location:** cli/nagarectl/src/Nagare/Inventory/Execute.hs, `resumeTransactionWithTakeover` and `preflightOperations`.

**Evidence:** [E10](mp23-operational-experiments.md#e10--the-real-partial-prune-command-reveals-two-more-executor-defects) runs the unmodified public CLI and the actual executor against a two-operation admitted scheduled-prune review. The create operation is ambiguous and its later declared completion operation fails preflight first. Instrumentation records zero adapter recovery calls and zero effects. Temporarily skipping only the up-front resume preflight reaches recovery. The earlier single-operation E3 result did not cover this dependency.

**Required implementation/verification:** Split whole-review structural checks from live operation preconditions. Preserve exact adapter/native/fence validation and run live checks when an operation's dependencies allow it to execute. Add the two-operation fixture to the production suite: failed, absent, and completed prerequisite states; no repeated partial effect; successful prior completion permits the dependent verification; changed source UID refuses. Preserve explicit operator recovery. Independently rerun the public fixture before closure.

**Original E10 evidence:** The diagnostic counterfactual and hashes remain retained; see the production update below for the subsequent fix.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.

## F13

**Ordinary executor recovery has no terminal-failure branch** — P1; **Verifying**; owner EP-153 / EP-159.

**Location:** cli/nagarectl/src/Nagare/Inventory/Execute.hs, `executeOperations`'s `recoverOrStop` decision match.

**Evidence:** E10's controlled removal of the premature preflight invokes the actual Kubernetes adapter once and then throws `Non-exhaustive patterns in case` on `RecoveryTerminalFailure`. Effects remain zero. Adding an explicit stop branch in the temporary source copy returns `StoppedAmbiguous` without replay. The explicit `inventory recover` route already handles the same terminal result; this finding concerns ordinary resume.

**Required implementation/verification:** Handle all four `RecoveryDecision` constructors explicitly. A terminal failure must produce a stable stopped result with the original review/transaction available for the named operator action, never an automatic replay, completion, or exception. Port the reproducer into a regression that asserts no effects and preserves active history; prove the public explicit recovery still works and rejects a changed source UID. The counterfactual is not a production patch.

**Verification:** Independent closure remains pending; the production candidate and regression evidence are recorded below.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.
