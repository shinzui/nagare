# MP-23 closed findings

Full text of closed MP-23 findings, moved unchanged from the [active tracker](../mp23-findings.md) on 2026-10-02 (only relative links were adjusted for the new location). The active tracker's register remains the index of every ID and status; a finding reopens there, not here. The original communication log and pre-fix reproductions follow the findings.

## F01

**Host execution mutates after observing a different VM or old closure** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Adapters/Host.hs; scripts/inventory-host-transport.sh.

**Audit evidence:** Actual HostAudit reproduction: all three mismatches previously invoked one mutation callback; after the implementation change all three refuse and invoke zero callbacks. Shell physical-ID guard source-inspected.

**Implementation update:** Commit `538b046d`: `Adapters/Host.hs` SHA-256 `9f5d28607bc60a384b7c8031b0c91d360b34817e96468a09b5f4686ec9a9e264`; `InventoryHostSpec.hs` `016bfbdfee91d6f8b281524e6c2b4dbcdcecc03eb67f4cefe156b31263e9d9dd`. `effect-time drift after preflight cannot run host activation` passed in the 38-test focused host run; the verifier's independent closure evidence is linked below.

**Required verification:** Run that checked-in regression; exercise the shell identity mismatch with a command recorder and prove no age-key install/host-switch occurs. Record revision or source hashes and results.

**Verification:** Independently closed; see [commands, results, and source hashes](mp23-verification.md). All seven checked-in host tests pass, including drift refusal; shell identity mismatch exits 2 with zero transport effects.

## F02

**Active transaction status still reads journal entries individually** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadActiveTransactionStatus.

**Audit evidence:** Actual StoreAudit: valid 50/500-event chains now give successful status with zero single reads and one batch each.

**Implementation update:** Commit `90e06e29`: `Status.hs` SHA-256 `6e16cf573810b7191ab040dbe7ba639160ab137f255901f9dfc5d1b6c2b9d85b`; `InventoryObjectOpsSpec.hs` `e264701f0b2cc9cd5ee3f1a5ba63f6b33bfbb143f49484218e42a20d53cc76ca`. `cabal test nagarectl-test --test-options=--pattern=object` passed 52 tests, including `active status verifies 50 and 500 chained events with one batch each` and gap rejection in the store test. Await independent verification; live timing is F06.

**Required verification:** Add or name a retained regression invoking loadActiveTransactionStatus at both sizes; preserve chain/gap rejection. The wider live timing gate belongs to F06/EP-156.

**Verification:** Independently Closed (2026-10-02). The retained status-caller regression passed at 50 and 500 committed events with zero single GETs and exactly one batch per prefix; a missing committed member still refuses. The independent 64-test object group passes. Live timing remains the separate F06 obligation. See [independent commands, limits and source hashes](../mp23-independent-verification-2026-10-02.md).

## F03

**Resume loads the same complete journal twice** — P2; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: resumeTransactionWithTakeover, executeWithJournal.

**Audit evidence:** Source trace: resume readJournal then execute readJournal. New executeWithJournal receives already validated events.

**Implementation update:** Commit `90e06e29`: `Execute.hs` SHA-256 `f85330076f5fd386ef572f0dd7a36690c5d3ee9323233e6096ccde2bb6f60f1d`. The object group passed `converged replay needs no provider registry or repeated journal pass` with one batch and `lost journal acknowledgement cannot duplicate an effect`. Commit `32c17c94` adds `active resume reads one journal batch and does not repeat proved effect`; `cabal test nagarectl-test --test-options=--pattern=proved` passed all five selected tests. Independent verification remains.

**Required verification:** Run a same-transaction resume with batch counts and retained operation receipts; require one prefix read and no repeated completed native effect.

**Verification:** Independently Closed (2026-10-02). The active original-transaction regression passed with exactly one journal batch and one total provider effect across interrupted apply/resume. Completed replay uses one batch without a registry; lost acknowledgements preserve no-duplicate behavior. The independent 64-test object group passes. See [independent commands, limits and source hashes](../mp23-independent-verification-2026-10-02.md).

## F04

**Native evidence loads every historical review and can repeat the scan** — P2; **Closed**; owner EP-156 / EP-153.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadNativeFor; cli/nagarectl/src/Nagare/Inventory/Plan.hs: loadPublishedReview.

**Audit evidence:** loadNativeFor expands every review and its scope/native members. Status invokes accepted and retained loaders. A cold cache makes historical review count a remote-I/O multiplier.

**Implementation update:** Commit `90e06e29`: `Status.hs` SHA-256 `6e16cf573810b7191ab040dbe7ba639160ab137f255901f9dfc5d1b6c2b9d85b` adds the empty-retained fast path. The object-group tests passed, but they do not measure unrelated review history; accepted and nonempty-retained scans remain unresolved.

**Implementation update (2026-09-29):** [Production proof and exact source hashes](mp23-selected-read-proof.md): status/explain now reads opaque digest-bound observation inputs, with two cold native GETs for two selected bindings independent of 0/500 reviews and 0/50 siblings. Empty legacy native requests use zero GETs/lists. New publications include raw observation bytes; explicit bounded materialization handles old stores without making it a recovery prerequisite. Full-suite and public corruption/legacy/retained tests pass. The [active-startup repair](mp23-active-startup-proof.md) additionally shares the validated command store and uses selected digest-bound source inputs. One corrupt unrelated archived review no longer blocks this modern-history recovery path. Remains Partial because a legacy missing-byte fallback still scans archives; materialization remains optional for recovery.

**Implementation update (2026-10-01, maintainability follow-through):** Successful legacy reconstruction now retains the selected, validated raw observation bytes in the existing optional private local content cache. A new command with that cache performs zero remote GETs and zero archive listings even after 500 unrelated corrupt reviews are added. Missing/corrupt cache files reconstruct from original evidence; an unwritable cache does not strand recovery. The reader refuses remote writes and preserves the exact head. All 14 selected-observation tests pass. A cold legacy root still needs original archive lookup unless explicit materialization has supplied the missing blobs; this compatibility limit and independent closure remain open. [Source-bound results](mp23-maintainability-performance.json).

**Required verification:** Hold current inventory fixed while increasing unrelated review history; record remote/member decode counts and cold/warm cost. Demonstrate selection of only necessary native evidence while preserving incarnation binding.

**Verification:** Independently Closed (2026-10-02) for the existing supported publication contract. The independent 35-test observation run includes two selected resources costing exactly two reads despite 500 unrelated reviews and 50 sibling natives; corrupt/missing selected bytes, incarnation-preserving reconstruction, fresh-command verified cache reuse and unwritable-cache recovery also pass. Modern publications supply digest-bound raw inputs. The preserved disposable-prerelease decision removes compatibility with obsolete missing-byte histories as a release gate; a cold legacy store may still scan its original archives, and that limit remains documented. No constant-total-scope-decode or cold-legacy-cost claim is made. See [independent evidence](../mp23-independent-verification-2026-10-02.md) and its retained observation output.

## F05

**New fresh-login checks can reuse an SSH multiplexed connection** — P1; **Closed**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: tailnet_fresh_closure, activate.

**Audit evidence:** New Tailnet calls omitted ControlMaster=no/ControlPath=none while the existing safe-switch verifier uses both.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression `scripts/test-inventory-host-transport.sh` SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed, capturing `ControlMaster=no` and `ControlPath=none` on both fresh-login paths. A real multiplexed-connection fixture remains for independent verification.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) reproduces a real control-master session falsely committing after key revocation: NIX_SSHOPTS preceded the mandatory no-multiplexing flags, and OpenSSH used its first values. Mandatory fresh options now precede ambient options. A real loopback sshd/master fixture proves all three production fresh-login paths reject the revoked key and accept restored authorization; safe-switch returns 4 without commit. Independent verification remains; this implementer does not close the finding.

**Required verification:** Capture argv for every call that contributes fresh-login proof and assert both options. Retain a regression with multiplexing configured; verify the proof comes from a new connection.

**Verification:** Independently Closed (2026-10-02). The real loopback sshd/control-master regression independently passes: the surviving master cannot authorize any of the three fresh-login paths after key revocation; restored authorization succeeds, safe-switch returns 4 without commit. The argv transport regression also passes. See [independent commands, limits and source hashes](../mp23-independent-verification-2026-10-02.md).

## F06

**Journal appends retain excessive serial cloud-command cost** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: appendEvent; cli/nagarectl/src/Nagare/Inventory/Store.hs; cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs.

**Audit evidence:** Measured actual appendEvent ObjectOps trace: noninitial event has five found GETs, two absent GETs, two PUTs. Original transport expands to 27 subprocesses/event; successful PUT fast path projects 21. No cloud-duration claim from these counts.

**Implementation update:** Commit `90e06e29`: `Store.hs` SHA-256 `93391593cd3eee4d59ac8e2d75ab661dfee52d90fa3ef1f5d504c4701ecfe6a2`, `ObjectOps.hs` `028959447fd85a512c6ef1c28cb5f9b31aeb4193ea624fc4202a7e1334d5eef8`, and `Execute.hs` `f85330076f5fd386ef572f0dd7a36690c5d3ee9323233e6096ccde2bb6f60f1d` batch replay, use the successful-upload generation, and append from the observed head. The object-group command passed `known-head journal append uses one conditional write without rediscovery` and the lost-ack case. A complete append subprocess trace and real cold/warm 50/500-event latency are still missing; the last real warm no-op was 41.04 seconds at 61 events.

**Implementation update (2026-09-29):** [Production append/command traces and source hashes](mp23-selected-read-proof.md) establish 5/8 subprocesses for actual complete append (previously 8/11), with a stale-provider-generation injection still refused. `ObservedHead` is opaque and store-bound. Resume reuses its validated head for journal loading; 12 full public no-op command cases now cost 12 subprocesses each (previously 15), independent of 50/500 events and 0/50/500 unrelated reviews. The 943-test suite includes provider-generation ABA, migrated-head refusal, takeover and lost-ack regressions. The [active-startup proof](mp23-active-startup-proof.md) now records the real factory, independent review/event scaling, and no-workspace recovery. Remaining head/claim transport, legacy archive cost, and real GCS latency still gate closure; status remains Partial.

**Claim/publication repair (2026-09-29):** [The public race and command proof](mp23-head-claims-proof.md) covers an intervening identical-head provider rewrite before acquisition. Claim/admission/release/finalization CAS now consumes the original observed generation. Explicit recovery also shares its first head with journal loading. Exact uncached publication lookup replaces execution-time archive listings; a valid local cache cannot authorize an unpublished review. F06 remains Partial pending full command-wide reuse and actual GCS latency.

**Retained replay proof (2026-09-29):** The [auth/replay checkpoint](mp23-auth-replay-proof.md) passes three cold/warm complete public no-op pairs on the original 61-event real-GCS transaction: cold 4.320–7.397 seconds, warm 3.905–4.708 seconds. Each cold run uses a new local root; no history is copied, no native executor runs, and the exact GCS head generation stays unchanged. A reproduced failed-refresh amplification bug is also fixed and the full 975-test suite passes. The historical 41.04-second retained warm failure is superseded for this candidate. F06 stays Partial for real 500-event replay, active append/provider timings and independent verification.

**500-event cloud repair (2026-09-29):** [The scaling proof](mp23-gcs-scale-proof.md) records the first warm failure at 12.783 seconds and a failing local HTTP test proving seven workers idle behind a slow eighth response. Eight persistent workers now share a queue, preserving exact-generation reads and the concurrency cap. Three real 500-event cold/warm pairs pass at 7.670–9.139 / 8.042–9.371 seconds, with isolated fetch/setup measurements. The same binary also passes retained 61-event pairs at 3.669–4.089 / 3.688–4.066 seconds. All 977 tests and exact generation cleanup pass. F06 remains Partial for active claim/append/finalization/provider timing and independent verification; the no-op scaling evidence is now established.

**Active driver measurement (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) completes original-transaction recovery in twelve public CLI loopback cases; lost write acknowledgements still converge and claim races refuse before provider work. Real GCS production-driver samples take 9.063/14.582 seconds including auth/setup at 50/500 events, with four chained publications and released claims. Journal replay takes 0.937/6.893 seconds; four journal writes total 0.340 seconds at either size. All 598 exact benchmark generations were cleaned; the retained head is unchanged. Provider observations in this cloud probe are synthetic. F06 stays Partial for complete public active cloud/provider cost and independent verification, not for the already measured isolated append/finalization or no-op gates.

**Implementation update (2026-10-01, maintainability follow-through):** The refactored public CLI passes 12 complete conditional-HTTP-recorder cases across 50/500 journal events, 0/50/500 unrelated reviews and cold/warm roots, with 29 subprocesses (5 initialization, 24 provider observations) in each case. Four lost-write-acknowledgement cases converge the original transaction; two identical-head/provider-generation races refuse before provider recovery. The saved-prune public recovery fixture also passes. Reports now bind every CLI, inventory-library and DSL source module, including extracted implementations. These are local recorder measurements; they preserve rather than replace the retained native GCS/cloud evidence. Native provider/store timing decomposition and independent closure remain open. [Source-bound results](mp23-maintainability-performance.json).

**Required verification:** Retain append and resume command-count regressions, preserve conditional writes/lost-ack recovery, then pass EP-156 cold/warm real GCS timing gate. Record append/provider/replay timings separately; no closure from one batched cp.

**Verification:** Independently Closed (2026-10-02). The finite real native production-driver measurement now separates registry construction (1.930s), one real GCS journal batch (6.244s), six individual journal PUTs (0.084–0.098s), their conditional head advances (0.097–0.140s), claim/finalization writes (0.102/0.165s), and real provider processes (58 kubectl calls totaling 19.323s, including one create and 9.949s completion wait). The instrumented production registry/driver restores known content and preserves 30 prior scopes, source A and neighbor B. This complements the retained three-pair 61/500-event cold/warm acceptance and independently passed conditional-write/lost-ack/replay regressions. Individual ObjectOps IO timings and provider sums are explicitly distinguished from whole-command elapsed time and installed binary execution; no disjoint decomposition is fabricated. See [independent evidence](../mp23-independent-verification-2026-10-02.md).

## F07

**Installed key with failed service activation cannot recover by retry** — P1; **Closed**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: activate; nixos/modules/nagare-host.nix: install_key.

**Audit evidence:** Extracted activate() with matching installed digest and unavailable Tailscale: two attempts each call status,status,IP then fail; neither reactivates. Helper preserves verified key before service restart.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed: same installed key plus failed service triggers one helper activation and a fresh login, a ready host triggers none, and a different key refuses. Independent full retry verification remains.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) executes the actual helper body and transport functions with simulated privileged/service/network boundaries. Separate sops and Tailscale failures after verified key persistence recover on the identical activation request without rewriting its inode/mtime/content. A ready retry skips delivery; a wrong installed key refuses. This exposed helper diagnostic stdout preceding transport JSON; delivery diagnostics now go to stderr and the regression parses the entire stdout as one committed JSON response. The new Nix host-transport-recovery check and 38 focused host tests pass. Real Linux services, saved-host-transaction CLI recovery and independent verification remain open.

**Required verification:** Simulate successful key persistence followed by sops/Tailscale failure, then retry the original operation. Prove activation resumes, no different key is written, fresh-login/readiness succeeds, and wrong keys still refuse.

**Verification:** Independently Closed (2026-10-02). Executing the actual helper/transport regression proves both injected post-persistence sops and Tailscale failures recover on the identical request: first exits 42/43, retry exits 0, one key write, unchanged inode/mtime/content, and wrong key exits 2. Fresh-login and transport argv regressions also pass. This closes the stated retry defect; final real-service/native release evidence remains separately required. See [independent verification](../mp23-independent-verification-2026-10-02.md).

## F08

**Unchanged host bootstrap depends on transient key-file environment and source root** — P2; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/app/Main.hs: buildHostStageCandidate.

**Audit evidence:** buildHostStageCandidate recomputes credential-bound spec/inputs from NAGARE_HOST_AGE_KEY_FILE and compares the entire scope. Removing the variable or moving hostRoot causes accepted-scope mismatch despite unchanged remote intent.

**Implementation update:** Commit `538b046d`: `Main.hs` SHA-256 `fd5d18972afe65e8368e97506a0d697424933ce48463b683436bbbf180314fb4` retains an accepted key digest and source binding when delivery-only environment is absent. `cabal build exe:nagarectl` passed; no public replan with the variable cleared or another operator root has passed, so this remains open.

**Native continuation repair (2026-09-29):** [The native checkpoint](mp23-native-bootstrap-proof.md) confirms fresh host login, then reproduces a further source dependency: bootstrap and build observation reevaluated mutable installation source after host acceptance. The repair preserves accepted host-input checks and observes the exact reviewed build output. The public bootstrap regression now rejects each changed host input and completes kubeconfig recovery and the 211-operation cluster review with Nix disabled after host acceptance. The next native run proved matching digests but rejected serialized input ordering; canonical scope comparison now passes an adversarial-order public fixture. The second-root attempt separately reproduced missing local-marker discovery of GCS history. Installed candidate `0870fa200d07` now replans without the delivery-key variable and completes the native kubeconfig transaction. F08 is Partial for second-root discovery/verification and independent closure.

**Fresh-root repair acceptance (2026-09-29):** Commits `27462937` and `6082dbd6` implement bound read-only GCS discovery, local Pulumi configuration restoration, explicit credential recovery and current-root read-only credential observation. [The installed proof](mp23-fresh-root-discovery-repair.md) uses candidate `6082dbd6aac0` from a never-used config/state/cache root without delivery-only key environment or copied marker/journal/credential. It recovers a matching private credential, reaches the same Ready node, and saves a 210-operation, zero-barrier review in 319.659 seconds under 360 seconds. No operations target the six accepted prerequisite scopes; shared head/global contexts are unchanged and no cluster apply runs. All 983 CLI tests and 36 public authority cases pass, with changed-host/credential refusals in the public regression. This implementing session accepts that consumer proof; F08 stays Partial pending independent closure and remaining recovery verification.

**Required verification:** After accepting a credential-bound host, clear delivery-only environment and replan; also use another operator root with identical host bytes. Require unchanged/verify-only result while intentional configuration or credential change still refuses/reviews correctly.

**Verification:** Independently Closed (2026-10-02). Installed ec2e1cd4 runs from a never-used config/state/cache root with the delivery-only key variable absent and byte-identical host inputs. Missing credential refuses in 46.167s; explicit recovery succeeds in 8.100s and reaches the original Ready node. The read-only cluster review finishes in 351.077s under the unchanged 360s bound, preserving all six accepted prerequisite revisions and proposing no host/cloud-foundation/Pulumi operations. Shared history and global contexts remain exact; no apply runs. The independently executed public bootstrap fixture also rejects changed host inputs and changed existing credential bytes. See [independent evidence](../mp23-independent-verification-2026-10-02.md).

## F09

**Scheduled-prune preflight prevents recovery after admission** — P1; **Closed**; owner EP-159 / EP-153.

**Locations:** cli/nagarectl/app/Main.hs: inventoryExecutionRegistry, verifyReviewedScheduledPruneProvider; cli/nagarectl/src/Nagare/Inventory/Command.hs: recoverInventoryWithFactory.

**Audit evidence:** Registry factory runs provider preflight before public resume/recover. Admission includes prune scope in headAccepted; guard therefore classifies its backup as pruned, excludes it, then requires it present. Partial deletion also violates original provider-list check.

**Implementation update:** Commit `538b046d`: `Main.hs` SHA-256 `fd5d18972afe65e8368e97506a0d697424933ce48463b683436bbbf180314fb4` skips the pre-admission provider listing during resume/recover and resolves an admitted prune's source through its exact retained owner, revision, Job ID, and physical identity when it is no longer accepted. `cabal build exe:nagarectl` and `cabal test nagarectl-test --test-options=--pattern=transactions` (38 passing) do not prove the public route. No cloud retry is authorized by these results. Add a public saved-review regression at both interruption points, then fix every registry and effect-time failure it exposes.

**Required verification:** Exercise public resume/recover for an already admitted original prune, both before effect and after deletion of one member. Prove exact terminal recovery remains reachable, no blind deletion retry, and new deferred admission still refuses.

**Verification:** Not closed. Awaiting the checks above.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.


**Independent checkpoint (2026-10-02):** The detached `e6255e6f` public driver
and new deferred-admission regression independently pass all 11 saved-history
commands plus the no-effects admission test. [Evidence](../mp23-independent-results-2026-10-02/operation-driver-e6255e6f.json).
The fixture models terminal partial-prune state without executing provider deletion.
The separate exact retained-source registry path remains to be independently
exercised before closing F09; no new scheduled-prune mutation is authorized.


**Independent current-contract closure (2026-10-02):** The remaining experiment
removes the source owner from synthetic accepted history and adds its exact retained
incarnation. All 11 public commands refuse `dangling-reference`, preserve the head,
and make zero provider calls because the still-accepted prune Job depends on that
source. [Negative fixture evidence](../mp23-independent-results-2026-10-02/invalid-retained-source-e6255e6f.json).
This is an invalid composition, not a reachable supported retained-source workflow.
Under the explicit disposable-prerelease decision, repairing such historical states
is not a release requirement. Independent saved-history recovery and deferred new
admission proofs above close F09 for the supported contract. No live prune support,
invalid-history repair, or new compatibility extension is claimed.

## F10

**Explaining one resource observes the whole context** — P2; **Closed**; owner EP-153.

**Locations:** cli/nagarectl/app/Main.hs: runInventoryStatus / InventoryExplain; cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs: observeKubernetesHealth.

**Audit evidence:** runInventoryStatus uses requested ID only after all adapter construction/observations/health/history. Invalid IDs also pay this cost. Kubernetes readiness repeats GETs for supported objects.

**Implementation update:** Sent to implementation session; no fix verified.

**Implementation update (2026-09-29):** [Public CLI proof and source hashes](mp23-selected-read-proof.md) show selected Kubernetes and Helm observation without a workspace, one selected provider call, no unrelated provider calls, early unknown-ID and foreign-context refusal, retained selection, and independence from 500 malformed reviews/missing sibling natives. Full dependency/consumer declarations remain available, and selected missing/corrupt bytes refuse before provider IO. Status is Verifying, not independently Closed; cloud timing and nonempty legacy execution lookup remain separate F06/F04 work.

**Required verification:** Record provider calls for one-resource explain and invalid ID; unrelated providers must receive none. Preserve dependency/consumer explanation and UID-bound health. Show call count does not grow with unrelated managed resources.

**Verification:** Not closed. Awaiting the checks above.


**Independent closure (2026-10-02):** The public selected-observation fixture
passes on a detached `e6255e6f` build at both 50 and 500 unrelated resources.
Selected Kubernetes and Helm reads issue one call each; unknown IDs, foreign
context, missing/corrupt selected bytes and malformed unrelated history refuse
or remain isolated as specified. Retained selection and explicit legacy
materialization also pass, with exact unchanged heads. [Call-count evidence](../mp23-independent-results-2026-10-02/selected-read-scaling-e6255e6f.json).
Together with the independently exercised native selected UID/health paths and
retained dependency observations above, this closes F10. No broad-context or
legacy cold-history cost claim is made.

## F11

**Conditional-upload optimization has ambiguous try exception type** — Build; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs: put.

**Audit evidence:** uploaded <- try (...) originally had only Right/wildcard patterns, leaving Exception e unconstrained.

**Implementation update:** Explicit Either IOException annotation now present in the working tree.

**Required verification:** Record a successful compile of the changed module plus the focused exact-created-generation tests. No separate regression is needed for this type-checking defect.

**Verification:** Independently closed; see [commands, results, and source hashes](mp23-verification.md). Current module compiled and all three exact-generation parser checks passed. This closes only the compilation defect, not F06 performance.

## F12

**A later operation’s preflight blocks recovery of its ambiguous prerequisite** — P1; **Closed**; owner EP-153 / EP-159.

**Location:** cli/nagarectl/src/Nagare/Inventory/Execute.hs, `resumeTransactionWithTakeover` and `preflightOperations`.

**Evidence:** [E10](mp23-operational-experiments.md#e10--the-real-partial-prune-command-reveals-two-more-executor-defects) runs the unmodified public CLI and the actual executor against a two-operation admitted scheduled-prune review. The create operation is ambiguous and its later declared completion operation fails preflight first. Instrumentation records zero adapter recovery calls and zero effects. Temporarily skipping only the up-front resume preflight reaches recovery. The earlier single-operation E3 result did not cover this dependency.

**Required implementation/verification:** Split whole-review structural checks from live operation preconditions. Preserve exact adapter/native/fence validation and run live checks when an operation's dependencies allow it to execute. Add the two-operation fixture to the production suite: failed, absent, and completed prerequisite states; no repeated partial effect; successful prior completion permits the dependent verification; changed source UID refuses. Preserve explicit operator recovery. Independently rerun the public fixture before closure.

**Original E10 evidence:** The diagnostic counterfactual and hashes remain retained; see the production update below for the subsequent fix.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.


**Independent closure (2026-10-02):** A detached `e6255e6f` build independently
passes the actual public CLI two-operation saved-review driver: absent, failed,
running and completed prerequisites; explicit terminal recovery; changed source
UID refusal; and fresh-process completion replay. All 11 commands preserve the
expected active/history state and issue only recorded GETs. Failed recovery stops
ambiguously without exception or resend; completed prerequisites permit dependent
verification. New scheduled-prune admission independently refuses before effects.
[Candidate-bound results and probe binding](../mp23-independent-results-2026-10-02/operation-driver-e6255e6f.json).
This closes F12 for the supported recovery contract. Synthetic admitted history
and provider recorders do not establish live pruning or retained-source cleanup.

## F13

**Ordinary executor recovery has no terminal-failure branch** — P1; **Closed**; owner EP-153 / EP-159.

**Location:** cli/nagarectl/src/Nagare/Inventory/Execute.hs, `executeOperations`'s `recoverOrStop` decision match.

**Evidence:** E10's controlled removal of the premature preflight invokes the actual Kubernetes adapter once and then throws `Non-exhaustive patterns in case` on `RecoveryTerminalFailure`. Effects remain zero. Adding an explicit stop branch in the temporary source copy returns `StoppedAmbiguous` without replay. The explicit `inventory recover` route already handles the same terminal result; this finding concerns ordinary resume.

**Required implementation/verification:** Handle all four `RecoveryDecision` constructors explicitly. A terminal failure must produce a stable stopped result with the original review/transaction available for the named operator action, never an automatic replay, completion, or exception. Port the reproducer into a regression that asserts no effects and preserves active history; prove the public explicit recovery still works and rejects a changed source UID. The counterfactual is not a production patch.

**Verification:** Independent closure remains pending; the production candidate and regression evidence are recorded below.

**Production rescue update (2026-09-29):** The shared driver and unified CLI registry are implemented. [The retained production proof](mp23-rescue-proof.md) includes same-history before/after CLI results, completed/interrupted/terminal/changed-source cases, zero provider mutations, and 935 passing tests. Original history and source checks remain. Status is Verifying; this implementing session does not independently close the finding. Real deletion, receipt-only cleanup, and separate retained-source CLI cases are not claimed.


**Independent closure (2026-10-02):** A detached `e6255e6f` build independently
passes the actual public CLI two-operation saved-review driver: absent, failed,
running and completed prerequisites; explicit terminal recovery; changed source
UID refusal; and fresh-process completion replay. All 11 commands preserve the
expected active/history state and issue only recorded GETs. Failed recovery stops
ambiguously without exception or resend; completed prerequisites permit dependent
verification. New scheduled-prune admission independently refuses before effects.
[Candidate-bound results and probe binding](../mp23-independent-results-2026-10-02/operation-driver-e6255e6f.json).
This closes F13 for the supported recovery contract. Synthetic admitted history
and provider recorders do not establish live pruning or retained-source cleanup.

## F14

**Initial Knative activator readiness blocks its uncreated autoscaler** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs; Adapters/Kubernetes.hs; Execute.hs.

**Native evidence:** Installed candidate `6082dbd6aac0` admitted the original 210-operation review, then created activator before autoscaler. Activator's running pod cannot pass its healthcheck because the autoscaler websocket is unavailable; autoscaler's Service exists but its Deployment has not been created. Diagnosis occurred before the fifteen-minute checkpoint. The bounded rollout wait stopped naturally, retaining the original ambiguous transaction at shared generation 416 with no executor claim/fence. See [the continuation report](mp23-cloud-continuation-2026-09-30.md).

**Implementation update:** The candidate adds the autoscaler predecessor to pinned and configured Serving declarations. A new typed awaiting-readiness recovery result requires exact owned created Deployment bytes and an original absent precondition. The shared driver permits only an untouched, unfenced, dependency-ready stateless Deployment create from the same review, refusing other uncertain/blocked operations, durable members and non-Deployment effects. Each completion returns to fresh guarded recovery; only real readiness can complete the waiting operation. All 987 CLI tests pass, including `Knative activator waits for autoscaler readiness in pinned and configured inputs`, `only an exact created Deployment can await readiness during recovery`, `resume creates an independent Deployment while exact predecessor waits for readiness`, and `readiness continuation refuses dependent, durable and non-Deployment creates`.

**Required verification:** Independently run the named tests and inspect foreign/digest/failed-workload, data/fence, dependency and other-uncertain refusals. Install the candidate and resume this original cloud transaction without review/history rewrites; require autoscaler and activator Ready with exact original identities and no repeated completed effect. Retain redacted native evidence and source identities.

**Native implementation continuation:** Installed revision `0c757b7410b3cdf14cdaa026cd2ca9b6f6427de2` resumes the original transaction and creates the original-review webhook/controller/autoscaler Deployments. They become Ready. The original activator Deployment and pod UIDs remain exact; its normal container restart leaves it Ready. The second resume records its adapter completion at sequence 372, then proceeds to the private certificate controller. The transaction stops there on an independent image credential failure (F15), at generation 469 with no claim/fence. See [the redacted native continuation](mp23-native-bootstrap-results-2026-09-30/readiness-continuation.json).

**Verification:** Not closed. Installed/native readiness recovery is now retained; independent closure remains required. The subsequent installed registry recovery resumes the same original transaction to full bootstrap convergence; steady credential coverage and independent F15 closure remain open.

**Implementation update (2026-09-30):** The [installed local candidate gate](mp23-native-bootstrap-results-2026-09-30/local-platform-candidate-705716b7.json) runs full native bootstrap with CLI/payload `705716b7`, rather than only the recording marker fixture. Autoscaler is Ready before activator, all 217 platform operations converge through the public driver, all 19 scopes are idle/converged, and the final marker names the candidate. A transient certificate readiness result settles through resume of the retained transaction. An unchanged replan contains 213 verification-only operations and no barriers. This proves the corrected fresh-bootstrap order locally; F14 safe-use Verification remains the operator's end-to-end runbook on `f15-preview`.


**Independent closure (2026-10-02):** Ten current candidate readiness/registry/
stopped-driver regressions pass. Read-only active ep150 observation independently
confirms the original activator, autoscaler, controller and webhook Deployment
UIDs, generation one, all Ready. The original immutable review digest and committed
activator completion at sequence 372 are verified from GCS. Installed `e6255e6f`
replays the original completed transaction in 13.054s and returns convergence
with exact unchanged shared head. [Original-history/native proof](../mp23-independent-results-2026-10-02/readiness-original-history-e6255e6f.json).
This closes F14 using independently reobserved completed outcomes and current
executable regression/replay. The initial interrupted resume remains historical
native evidence; no review/history rewrite or second bootstrap is claimed.

## F17

**Effect-free retirement discards required native identity observations** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence:** Installed `2101b834882a31a77036103b00c03b9a9cc07019` saves Application C retirement review `164d1a480405e5a2274b5f0e6fca564bf765cf428076b71e0eb963da4d624ace` in 21.180 seconds. It has zero mutation operations and exactly two retention proofs, bound to the accepted Service and release-history UIDs. Public apply refuses after 4.810 seconds with `retention-observation`; the exact generation 698/sequence 615 head remains unchanged. No transaction or deletion is admitted.

**Implementation update:** The runtime already loads the retained resources' accepted immutable native inputs, but then restricts them to mutation-operation IDs. A zero-operation retirement therefore constructs blocked observation adapters. Preserve the exact retained Kubernetes and Helm input keys alongside selected operation/source keys; do not broaden the input set beyond the immutable review's retention/collection members. The source CLI builds; six focused retained regressions pass (4.15 seconds), along with structural style and command registration. A development-binary public-path diagnostic refuses an injected foreign UID in 10.201 seconds and preserves the exact head, then admits the original saved retirement review in 14.013 seconds. All other 28 accepted/converged revisions, application/database/PVC UIDs and data remain exact at generation 702/sequence 617. The Service and release-history object stay retained. [Exact source and native diagnostic evidence](mp23-native-bootstrap-results-2026-09-30/retirement-runtime-selection-candidate.json) is retained. Subsequent Service collection refuses its known retained release-history dependency; no delete or review is published. Immutable installed verification and eligible collection proof remain open.

**Installed follow-up:** Immutable `8482c2f2` passes its installed bootstrap fixture. Its exact no-operation retirement refuses a changed observed completed-backup Job UID without changing history, then accepts the original review while preserving the Job. A separate reviewed collection removes only that eligible Job. All other 27 scope revisions, application/database/PVC identities, data and backup receipt survive; the two Application C retained incarnations stay unchanged. [Installed retirement and collection proof](mp23-native-bootstrap-results-2026-09-30/cloud-installed-retirement-and-collection.json) records the idle generation 713/sequence 623 checkpoint. Helm-native and independent closure remain pending.

**Required verification:** Through the public apply path, prove the original saved retirement review reobserves both retained UIDs, refuses a foreign observed UID without changing the head, and admits unchanged exact identities. Preserve all other accepted/converged revisions, data, and native objects; retirement does not delete them. Prove subsequent collection separately. Record source hashes and executable-build identity, and repeat on the immutable installed candidate before independent closure.

**Verification:** Independent closure remains pending.


**Independent closure (2026-10-02):** Earlier independent real-store Kubernetes
retirement/collection is complemented by an installed `e6255e6f` public Helm
retirement against a disposable copy of cp3 inventory. Its zero-operation review
reobserves the actual stamped Helm release/Secret UID. An injected foreign UID
refuses without a copied-head change; the same saved review then retains the
original exact UID. Every provider call is read-only; the real cp3 head, live
release revision and all objects remain unchanged. [Helm runtime proof](../mp23-independent-results-2026-10-02/helm-retirement-copy-e6255e6f.json).
The copied bootstrap stamp is retired first to preserve its dependency invariant.
Only copied history records Helm retirement; no live uninstall/collection is
claimed. These complementary public runtime boundaries close F17.

## F18

**Initial GCS foundation transaction cannot resume its local journal** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence:** Immutable `d73c1dc4d3790c980be877f42cb68ea32b7575bd` plans the disposable `f15-preview` foundation review `03deb235a67fd7576e66248c1867ba317ced759d60d3dff1394a1b747d6aa6c5`. Apply creates and verifies only its new state bucket, then stops before the Pulumi stack mutation with `KnownNoEffect "adapter preflight refused"`. The local generation 6/sequence 3 head retains the exact original transaction, without a claim or migration. Generic public resume refuses in 0.156 seconds with `local inventory history exists; migrate it before selecting the GCS store`. Store status also refuses the uninitialized remote prefix. A later exact read-only Pulumi stack listing succeeds; the original transient preflight cause remains unproved. No VM or subsequent platform resource has been created.

**Implementation update:** The candidate routes public resume through read-only foundation authority discovery. Remote ownership, complete prefix, context/project and migration guards remain authoritative. A local fallback requires the exact active transaction and published payload-bound initial review: empty base, exactly `platform:cloud-foundation`, unchanged accepted revision vector, and only foundation executor operations. Other local histories refuse. Resume retains its existing immutable-input and execution checks; migration occurs only after convergence. The complete source CLI bootstrap fixture passes, including stopped initial GCS recovery with one bucket creation, one stack initialization and preserved migrated journal, plus a legitimate unrelated active transaction refusal with exact unchanged head and no Pulumi call. Immutable `d73c1dc4` fails the new regression at the original migration refusal, confirming the consumer counterfactual. Source CLI compilation and structural style pass. [Exact candidate identities and evidence](mp23-native-bootstrap-results-2026-09-30/foundation-initial-gcs-recovery-candidate.json) are retained. Installed native recovery verification remains pending.

**Installed follow-up:** Immutable `cf269e72` builds and passes the complete installed CLI bootstrap fixture. With the original `d73c1dc4` payload and review selected, native resume converges in 38.282 seconds and migrates to the configured GCS prefix. The idle shared generation 11/sequence 6 head has its sole foundation scope accepted and converged, without claim or fence. Public export proves the unchanged original review and all three original journal entries migrated byte for byte. The complete journal has one bucket-create intent and one stack-create intent; the completed original bucket operation is not replayed. [Installed native proof](mp23-native-bootstrap-results-2026-09-30/cloud-initial-gcs-foundation-recovery.json) retains the exact boundaries. The operator-requested stopping point is reached before VM creation. Independent closure and fresh-host steady credential acceptance remain open.

**Required verification:** Reproduce a stopped first bootstrap configured for GCS, resume its original review without repeated bucket creation, and preserve the complete original journal during migration after convergence. Refuse a legitimate unrelated local active transaction without changing its head or invoking its provider. Verify the immutable installed operator against the original native transaction and retain exact source/build/evidence identities. Independent closure remains required.


**Independent current-contract closure (2026-10-02):** Installed `e6255e6f`
independently passes the complete public foundation interruption/resume fixture,
including exact original journal migration, no repeated bucket creation, and
unrelated-active-history refusal. Independent audit of the retained native proof
checks original review/export equality, all three original journal hashes, six
contiguous final events, one intent per mutation and idle accepted/converged
ownership. [Evidence and boundaries](../mp23-independent-results-2026-10-02/foundation-historical-audit-e6255e6f.json).
The original native recovery was executed by the implementing session; it is
audited historical evidence, not a newly repeated native drill. Under the explicit
disposable-fixture decision, retired F15 is not accessed, resumed or modified.
Current independent executable proof and retained native outcome close F18;
fresh-host credential acceptance remains a distinct F15 gate.

## F19

**Rendered pinned GCS restore omits download generations** — P1; **Closed**; owners EP-160 / EP-156.

**Native evidence:** Installed `8b6cb730` accepts the primary manual receipt and separately collects its Job. The Job-free `mp23f15pgav2` review creates Job UID `6406eaef-6d37-482c-aea6-504d4ab21102`, but `download` fails because the receipt address ends in `#`: the rendered environment omits both pinned generations. PostgreSQL never starts. Exact terminal recovery preserves the failed Job and returns history to idle generation 722/sequence 654. [Evidence](../mp23-native-bootstrap-results-2026-10-02/f15-receipt-collection-and-download-failure.json) includes exact review/source identities.

**Implementation update:** Add both version variables for GCS verified sources. Strengthen the public GCS fixture to execute the rendered init-container script with only its declared environment, strict generation-qualified GCloud copies, actual receipt/archive hashes and a valid gzip SQL archive. Installed `8b6cb730` fails the new public regression; the source fix passes and verifies decompressed SQL. Both receipt fixtures, web cleanup fixture, all 1,017 CLI tests (54.00 seconds), compilation and Haskell style pass. Installed repair, native restored rows and independent closure remain pending. The fixture still does not execute PostgreSQL. Terminal abandonment preserves the failed native Job without making it an accepted/retained member; cleanup remains separately reviewed work.

**Installed follow-up:** Installed `4c4b667e` passes its local 213-verification gate and rendered GCS fixture. Job-free native restore converges in 34.101 seconds with completed UID `13f19521-86a2-4389-9b47-5e652769ec62` and the backed-up row. Source/neighbor rows and original physical identities remain exact; v2 database is absent and failed Job preserved. [Proof](../mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json) separates this accepted restore from F20. Independent F19 closure stays open.

**Required verification:** Verify the new immutable installed candidate and local gate, then restore from the same accepted GCS versions after producer Job removal into a fresh isolated destination. Check known backed-up rows, later live source/neighbor rows and unchanged physical UIDs. Preserve the prior failed Job and original history. Independent verification is required for closure.


**Independent closure (2026-10-02):** Installed `e6255e6f` passes its cp3 gate
and the public GCS rendered-download regression. On the eligible ep150 fixture,
a new disposable manual backup is independently accepted as a durable receipt,
its exact producer Job is publicly collected, and a fresh isolated restore then
completes with that Job absent. The actual init environment pins both accepted
GCS generations. Authenticated queries verify the known backed-up row and exact
unchanged source/neighbor rows and Pod identities; all 43 prior scope revisions
remain exact. [Independent native proof](../mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json).
F19 is Closed for the supported contract. The retired F15 fixture and original
failed Job/history were neither accessed nor modified; the disposable-fixture
decision is preserved. This is isolated recovery, not live-target cutover.

## F20

**Current disposition (2026-10-02):** Independent candidate-bound verification is complete; status is Closed. Earlier Open/frozen statements below are dated observations. The old F15 exception is withdrawn from the work queue; preserve its proposal only as diagnostic history.

**Knative collection cannot orphan controller descendants** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence:** Installed `4c4b667e` changes only Application B's history lifecycle, retires eleven exact incarnations without mutation, proves premature Service collection refuses without changing the head, then collects history separately. Review `b6886179d40d4618442997221cc02ca986f142ccdeef1661448cfca627765472` issues its conditional Service deletion once but stops ambiguous after 45.124 seconds. UID `80560c4d-6bd8-4fe4-9c55-e67620554924` remains terminating with finalizer `orphan`. k3s logs show garbage collection cannot orphan its Route/Configuration: Knative validation refuses missing `metadata.labels.serving.knative.dev/service`. Generation 752/sequence 673 keeps the original transaction, no claim/fence and nine retained B database incarnations. Source/neighbor rows and UIDs remain exact. [Evidence](../mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json) also records the earlier helper guard failure/reconciliation.

**Implementation update:** The public `--knative --retain-data` fixture fails on the installed candidate at Service collection. Adding `--expect-orphan-block` models accepted deletion with a pending finalizer and passes, preserving the original transaction and retained Service/data UIDs plus an independent neighbor. No production cascade fix is claimed. The Service declares no controller delegation; changing Orphan to Background would broaden deletion authority. [The unexecuted exception proposal](../mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json) binds exact head/review/operation, parent UID/resourceVersion, sixteen descendants across all listable namespace APIs and nine protected database UIDs. No finalizer patch, blind resume, new build/admission or history reset followed the failure.

**Local interpreter evidence (2026-10-02):** [Eight F20 scenarios](mp23-effectful-collection-proof.md) now use the real planner, lifecycle review, filesystem journal and Kubernetes runtime with persistent parent/descendant state. They prove pending-finalizer recovery without a duplicate DELETE, exact UID/version races, preserved data, and no false convergence from wait success. The combined 14-test interpreter suite takes 2.55 seconds. The existing public pending-Knative fixture passes through real subprocess execution with local shims. Eventual orphan completion is an explicit modeled external event, not a live workaround. No cascade policy changes; F20 remains Open.

**Reviewed source contract (2026-10-02):** [The new local checkpoint](mp23-reviewed-controller-collection-proof.md) adds explicit `--controller-descendants` authority, a distinct adapter identity and descendant-aware recovery. Eleven new scenarios bring the focused suite to 25 passing tests in 3.79 seconds; all 1,042 CLI tests and both public Knative variants pass. Existing reviews keep Orphan semantics. The Background grant covers dynamic exclusive descendants; namespace observations are not atomic deletion bounds and assume trusted controllers/writers. F20 stays Open until native agreement and independent verification; the frozen transaction is unchanged.

**Recorded agreement (2026-10-02):** [Eighteen additional production-path scenarios](mp23-reviewed-controller-collection-proof.md#recorded-native-graph-agreement-2026-10-02) consume sixteen recorded descendants and seventy-five discovered APIs through the same interpreter. They expose and fix silent omission of persisted objects without UIDs, cover ownership/completeness/unexpected-descendant refusals and fresh-process recovery, and enforce 78/233/78/0 kubectl-call budgets for prepare/pending apply/resume/terminal replay. The combined interpreter suite passes 43 tests. This is metadata/model agreement, not native GC or independent closure; F20 remains Open and the frozen exception remains unexecuted.

**New-review native agreement (2026-10-02):** [Installed `8a820ce8` now passes the bounded native proof](mp23-reviewed-controller-collection-proof.md#native-controller-and-recovery-agreement--2026-10-02) on a separate disposable ep150 Service. Three real-response mismatches were reproduced/fixed locally; all 1,064 CLI tests pass. All 75 APIs bind 17 descendants and 41 protected objects. Interruption after the accepted Background DELETE preserves the original transaction; pending resume correctly refuses while the Pod completes its normal 300-second grace, final resume converges without a duplicate DELETE, and terminal replay uses zero kubectl calls. All 125 original identities, both database rows and 27 original revisions remain exact. Frozen F15 head remains byte-identical; its cascade exception is neither authorized nor executed. This supplies native agreement for new reviews, not independent closure or native same-scope retained-database coverage.

**Required verification (revised 2026-10-02):** Independently verify corrected reviewed descendant collection, accepted-response interruption, original-transaction recovery without duplicate DELETE, and retained-data preservation on the candidate. Retain the existing separate native proof and finish its missing same-scope retained-database assertion. Under [the operator disposition](../mp23-prerelease-fixture-disposition.md), the old F15 transaction is retired from acceptance: its cascade exception, recovery and teardown are not closure requirements. This is a scope disposition of a development attempt, not successful recovery or independent closure of the product defect.

**Recovery request validation:** Live server `v1.35.8+k3s1` accepts the exact UID/resourceVersion-bound Background DELETE with server-side `dryRun=All`; parent UID/resourceVersion/orphan finalizer and the head remain unchanged. The exception review records upstream custom-resource/generic-store sources and this dry-run. The request lets the API server adjust its GC finalizer; it excludes manual finalizer patches. Dry-run acceptance does not prove actual parent/descendant finalization, and no exception mutation has run.

**Independent verification (2026-10-02):** Installed `8a820ce8` independently passes the complete same-scope native scenario on eligible `ep150-preview`: exact policy review, foreign-UID retirement refusal, effect-free retirement of eleven members, separate history collection, one reviewed Background parent DELETE interrupted after server acceptance, fresh-process original-transaction recovery with no repeated DELETE, and zero-kubectl terminal replay. All 75 APIs are observed; parent and sixteen descendants are absent; 35 protected objects and all nine retained same-scope database resources survive. The source and retained-database rows remain exact, and 26 unselected revisions remain unchanged. Final generation 767/sequence 653 is idle. An additional uninventoried ownerless Endpoints sharing a reviewed descendant Service name disappeared; the proof does not claim an atomic namespace UID boundary. Same-root recovery is not a foreign-client takeover claim. Earlier pending-GC native proof plus independently rerun 47 interpreter scenarios retain that boundary. Retired F15 was never accessed. [Independent proof and limits](../mp23-independent-verification-2026-10-02.md), [redacted native evidence](../mp23-independent-results-2026-10-02/native-same-scope-collection.json). Final release-candidate binding remains a separate EP-157 gate.

## F21

**HTTP redirect automatically resubmits reviewed CDN purge** — P1; **Closed**; owner EP-158.

**Location:** `Nagare.Cdn.Cloudflare.cfRequestWithStatus`.

**Independent evidence (2026-10-02):** The actual built public CLI is run through
an isolated TLS recording proxy. A 307 response from the exact purge endpoint
with a same-endpoint Location causes two identical POST requests for one reviewed
intent; `inventory apply` exits zero. The request retains http-client's default
redirect allowance, so this resend bypasses the journal's unresolved-response
recovery. [Source-bound reproduction](../mp23-independent-results-2026-10-02/cdn-purge-redirect-before.json).
The normal public purge fixture and a separate extension checking changed whole-zone
ruleset ID/version both pass. This finding concerns transport-level resend.

**Required implementation/verification:** Disable automatic redirects for reviewed
mutations. Independently rerun the actual public CLI with 307 at the purge endpoint:
only one POST may occur, acceptance remains unresolved, and fresh-process resume
must refuse without another POST. Retain successful host/path/whole-zone acceptance,
identity-change refusals and durable-receipt replay proofs.

**Independent verification (2026-10-02):** The corrected transport sets
`redirectCount = 0`. The public regression with `--ambiguous-response redirect`
independently passes: exactly one POST for the redirected intent, apply stops
unresolved, and a fresh CLI resume stops without another POST. Ordinary path,
host and explicit whole-zone requests each receive one acceptance; their durable
receipt replays do not resend. Separate adversarial ruleset ID/version checks
also refuse before a whole-zone request. [Corrected source/binary proof](../mp23-independent-results-2026-10-02/cdn-purge-redirect-after.json).
This closes the transport finding on the built source; final installed release
candidate binding remains a separate acceptance gate.

## F22

**ClickHouse restore fails after a transient read-only verification refusal** — P1; **Closed**; owner EP-160.

**Location:** `Nagare.Database.Restore.verifiedRestoreShell` ClickHouse branch.

**Independent native evidence (2026-10-02):** Installed ec2e1cd4 ingests a genuine
automatic signed-v5 GCS receipt after producer cleanup. Its isolated restore
prints `RESTORED`, then the immediate database-existence SELECT fails with
connection refused. The Job becomes terminal Failed. An independent authenticated
query confirms the exact backed-up row in the scratch database and both rows
in the later live source; the source Pod UID is unchanged with zero restarts.
The exact cause of the transient connection gap is not established.
The bounded caller stops at 240s; original-transaction resume stops stably ambiguous
without replay or exception. Digest-bound `abandon-partial-database-restore`
succeeds, preserving the failed Job, archive and scratch database.
[Candidate, receipt-consumer review, physical identities and outputs](../mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json).

**Required implementation/verification:** Bound and retry only the post-RESTORE
read-only verification, with per-query timeouts. RESTORE must execute once; exhausted
verification must preserve archive/database and fail. Independently test transient
and permanent query failures, then consume the same accepted exact GCS receipt
into a new isolated destination with a repaired installed candidate and verify
known content plus preserved source/neighbor/failed-attempt identities.

**Independent source verification (2026-10-02):** Revision `e6255e6f` executes
RESTORE once and bounds six read-only SELECT attempts with per-query timeouts
and two-second delays. The accepted native 25.8 client independently accepts
all four timeout flags. Six focused rendered-shell/contract tests independently
pass in 1.67s, including transient success, persistent refusal, missing database,
failed RESTORE and archive-preserving replay refusal.

**Independent native closure (2026-10-02):** The immutable installed `e6255e6f`
passes the cp3 gate, then restores the same accepted exact GCS receipt into a new
isolated destination. The real Job prints RESTORED once, encounters another
connection refusal on its first verification query, and completes through the
bounded read-only retry. Known-content queries verify the original row; the live
source retains both rows. All 42 prior scope revisions, neighboring PostgreSQL
Pod identities/rows, and the original failed Job/database are preserved.
[Installed native before/after evidence](../mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json).
F22 is Closed; final release-candidate binding remains a separate gate.

## F23

**Credential review can delegate to an older receipt-unaware host transport** — P1; **Closed**; owners EP-153 / EP-154.

**Independent source evidence (2026-10-02):** Revision `c4d219e4` correctly
binds explicit and inherited key files to v2 receipt-required plans when its
new shell is selected. However, planning and execution select the host transport
from the accepted payload workspace. Active ep150 preserves its `6082dbd6`
payload, whose shell emits ordinary HostTransportPrepared and ignores credential
receipt authority. The new runtime accepts that response as v1; its transport
request version also remains one for saved v2 plan inspection/activation.
An older shell can therefore miss the new receipt check. This is a source-bound
compatibility finding; no credential mutation was attempted on the fixture.

**Required repair/verification:** Use an explicit versioned transport request for
credential-required preparation and every v2 plan inspection/activation. An older
shell must refuse before provider work. The new shell must derive required
credential semantics from that protocol, refuse legacy prepared responses, and
preserve old v1 plan behavior. Independently run changed/stale payload refusal,
service-failure/retry, inherited-key review and current-v2 success regressions.
No in-place payload upgrade or old-payload credential authority is implied.

**Independent closure (2026-10-02):** Repair `1b0d5a61` passes the exact
outer-version runtime regression for prepare, inspect and activate, including
legacy-response downgrade refusal. The actual accepted `6082dbd6` payload shell
independently refuses all three protocol-v2 actions before target sourcing or
provider work. The extracted current preparation function emits credential
authority with protocol v2 alone, without an environment marker and even when
the key already matches. Six real helper/transport service-failure retries and
the existing transport identity/fresh-login fixture pass independently; the
installed c4 public regression covers explicit and inherited key review.
[F23 evidence](../mp23-independent-results-2026-10-02/host-protocol-f23-1b0d5a61.json).
No native new credential activation on the legacy payload is claimed; fresh
host timer/expiry acceptance remains F15.

## F24

**Host image planning can start a stopped builder** — P1; **Closed**; owners EP-153 / EP-154.

**Independent source/reproduction evidence (2026-10-02):** The new reviewed
`host image` entrypoint reuses `buildImageBuildStageCandidate`. For an accepted
build this calls `upload-images.sh --inspect-build`, whose `build_present` probe
uses SSH through `nix-builder-proxy.sh`. That proxy starts a stopped Compute
instance before opening the tunnel. A saved-plan command can therefore perform
a provider mutation before a new review is applied. This path also exists in
bootstrap image planning. [The actual-script recorder reproduction](../mp23-independent-results-2026-10-02/image-plan-builder-start-reproduction.json)
observes describe followed by start; it performs no real provider call. The
authorized fresh image apply already permits its existing builder to start and
is not a plan-only verification of this boundary.

**Required repair/verification:** Make image inspection use a read-only builder
transport: stopped or inaccessible builders must not be started by planning.
Retain explicit start capability for authorized build execution. Independently
exercise the actual script path and public image planning, including stopped and
running builders, unchanged completion, and failure before a saved review.
Preserve the immutable host lock-file inputs during image evaluation.

**Independent closure (2026-10-02):** The actual public CLI now reaches the
read-only proxy and refuses a stopped builder after exactly one describe, before
saving a review and with exact head bytes unchanged. The actual upload script
distinguishes unavailable transport from confirmed absence; both image evaluation
and build preserve the lock file. Exact outer-version observe/publish regressions
pass. Both retained 390 and 6082 payload scripts independently refuse the new
inspection flag and BuildJob protocol before target/provider access. The complete
public foundation/image fixture independently passes publication, lost-ack
recovery and repeat verification. [Source-bound closure evidence](../mp23-independent-results-2026-10-02/image-plan-readonly-f24.json)
records the exact executable and source hashes. It does not claim a native fresh
payload build with the repair; old accepted payloads refuse the new image probe
rather than silently retaining its former start behavior.

## F25

**Reviewed context control rejects supported builder transport inputs** — P2; **Closed**; owner EP-153.

**Independent installed evidence (2026-10-02):** Candidate `caa37d19` passes
the installed cp3 gate and public profile fixture. On a fresh operator root
containing the exact copied ep150 profile, `context delete --save-plan` refuses
with “context review refuses unrecognized profile fields”. The original profile
contains supported `NAGARE_BUILDER_PROJECT`, `NAGARE_BUILDER_ZONE`,
`NAGARE_BUILDER_INSTANCE`, `NIX_BUILDER_SSH_KEY` and
`NIX_BUILDER_HOST_KEY_B64` settings. No review, profile removal, original-root
change or remote-head change occurred. The fields were not stripped to force
acceptance. [The refusal proof](../mp23-independent-results-2026-10-02/context-native-transport-refusal-caa37d19.json)
records only input names and hashes.

**Required repair/verification:** Preserve the known supported builder transport
inputs as immutable local profile authority through update, removal and restore,
using canonical quoted replacement bytes. Refuse changes to those values and
unrecognized fields. Independently execute the actual accepted GCS-authority
roundtrip from the new operator root, checking exact original profile and remote
head bytes throughout.

**Independent native closure (2026-10-02):** The corrected source executable
completes the real GCS-authority update, return, removal and original-review
restore from the isolated operator root. All five transport inputs survive;
the original operator profile and exact remote head bytes remain unchanged.
The public field-preservation regression and negative strip/change cases pass.
[Exact native roundtrip and executable/source binding](../mp23-independent-results-2026-10-02/context-gcs-original-restore-f26-fixed.json).
Immutable final-candidate binding remains a separate release gate.

## F26

**Removed GCS context cannot restore its retained authority** — P1; **Closed**; owner EP-153.

**Independent native evidence (2026-10-02):** The F25 source repair permits a
fresh copied ep150 profile to review/apply an operational input update, return
to the original values, and complete reviewed removal while retaining all five
existing builder transport inputs. Every step preserves the original operator
profile and native remote head. The subsequent original-review restore refuses:
`StoreConditionFailed` reports the removed local context file is missing.
`openTargetStoreReadOnly` calls `openRemoteStore`, which still requires
`readContextProfile` even when restore supplies the validated retained original
profile. The isolated root remains removed with its original review, marker and
completion receipts intact. [Native refusal evidence](../mp23-independent-results-2026-10-02/context-gcs-restore-refusal-f26.json).

**Required repair/verification:** Read the original GCS authority through a narrow
validated removal-review capability without requiring the deleted profile. Keep
project, bucket ownership, binding, migration and exact local path checks. Resume
this original removal review to restore exact saved profile bytes, then verify
completed removal/restore replay without remote writes or changes to the original
operator root. Do not reconstruct the file manually before verification.

**Independent native closure (2026-10-02):** The narrow retained-authority opener
recovers the same failed removal review in 3.968 seconds, restoring the exact
saved profile bytes without manual file reconstruction. Replaying the completed
removal keeps the restored file; restore replay is idempotent. Remote head and
original-root profile bytes remain exact. [Recovery proof](../mp23-independent-results-2026-10-02/context-gcs-original-restore-f26-fixed.json)
binds the frozen executable and reviewed source hashes; immutable final-candidate
binding remains a separate release gate.

## F27

**Credential streaming loses argument boundaries at the real SSH transport** — P1; **Closed**; owners EP-153 / EP-154.

**Independent installed native evidence (2026-10-02):** Fresh immutable `3905012e`
bootstrap successfully creates the isolated image and VM, then the original
receipt-required credential apply stops Ambiguous. `iap-ssh.sh send-file` forwards
multiple argv values directly to OpenSSH. Its remote shell joins the multiline
`bash -c` script and drops the empty previous-key argument, producing “option
requires an argument” and “$1: unbound variable”. A read-only native check proves
the age key remains missing, no credential receipt exists, and the authentication
input was not delivered. The original review, active transaction, VM and payload
remain unchanged. [Exact native finding](../mp23-independent-results-2026-10-02/host-send-file-ssh-quoting-f27.json).

**Required repair/verification:** Serialize the send-file argv contract into one
correctly quoted remote command, preserving empty values, multiline scripts and
stdin streaming. Exercise actual OpenSSH remote-shell joining rather than a
direct argv-execution stub. Version the credential transport so older payloads
refuse before effects. Preserve the failed disposable fixture without patching
its accepted payload; complete native credential acceptance on a new fixture
from the corrected immutable candidate.

**Independent repair verification (2026-10-02):** Source `762657ed` passes
the real sender's SSH-shell serialization test and all six service-failure/retry
cases. The exact retained 390 payload independently refuses protocol v3 for
prepare, inspect and activate before target sourcing or provider access.
[Protocol and regression evidence](../mp23-independent-results-2026-10-02/host-f27-legacy-v3-refusal.json).
Installed 762 passes the cp3 gate. Native credential acceptance remains pending
on the new isolated `mp23-host-fixed` fixture; F27 remains Verifying.

**Independent installed native closure (2026-10-02):** A new isolated fixture
built and booted the immutable 762 payload, preserving the failed 390 fixture.
The original receipt-required review then converged through the real IAP/SSH
sender in 113.582 seconds. Both exact plan-bound receipts match the fresh key;
read-only native verification proves root-owned mode 0400 and active SOPS,
Tailscale, k3s and registry pull-Secret timer. All five accepted scopes converge
at generation 47/sequence 32 with no active transaction. The single-use auth
input was consumed only by this corrected host. [Installed native proof](../mp23-independent-results-2026-10-02/host-fixed-762657ed-native-credential-f27.json).
This closes F27; automatic credential-expiry/re-pull acceptance remains F15.

## F28

**Release cleanup omits native evidence for adjacent scope members** — P1; **Closed**; owner EP-153.

**Independent native evidence (2026-10-02):** A typed reviewed disposable scope
creates a four-entry release-history ConfigMap and an adjacent sentinel ConfigMap
in the existing cp3 namespace. The public cleanup plan then refuses “Kubernetes
declaration lacks a packaged document source”, before saving a review or changing
the head. Cleanup supplies only selected history-member native bytes, while
ReplaceScope requires Verify observations of adjacent members. Generated
application Service/PVC members have the same boundary. [Exact native reproduction](../mp23-independent-results-2026-10-02/release-cleanup-adjacent-native-f28.json).

**Required repair/verification:** Supply digest-bound accepted native evidence
for exactly the planner-selected members, preserving generated contribution
ownership and preparation guards. Resume public planning on this unchanged
fixture; verify only history updates, current/most-recent retention, unchanged
adjacent identity/content and unselected scope revisions, and effect-free replay.

**Independent native closure (2026-10-02):** The corrected public cleanup
reviews and applies exactly one history ConfigMap update on the same fixture.
It retains r4 and current r1, preserves the history UID, all four other namespace
ConfigMaps, and all 29 unselected scope revisions. Completed transaction resume
adds no provider effect; a fresh public cleanup review has zero operations and
applies successfully with exact native bytes preserved. [Native closure proof](../mp23-independent-results-2026-10-02/release-cleanup-native-f28-fixed.json)
binds the frozen executable; final immutable release binding remains separate.

## F29

**Admitted preview route failure lacks a bounded configuration correction** — P1; **Closed**; owner EP-153.

**Independent native evidence (2026-10-02):** The disposable typed preview
fixture accidentally uses the Service's automatic hostname as its DomainMapping
alias. Its Service becomes Ready and durable PVC becomes Bound, but the route
reports DomainConflict and its create transaction stops Ambiguous. The existing
stop-incomplete-application proof only supports an Application scope with a
failing Service create. It cannot safely release this exact standalone preview
route for correction. This begins with an independent fixture-input mistake,
not a defect in route rendering; the missing bounded recovery path affects the
new supported preview lifecycle. [Exact diagnostic proof](../mp23-independent-results-2026-10-02/preview-domainmapping-correction-f29.json).

**Required repair/verification:** Validate the complete original preview contract,
one owned stateless DomainMapping create and settled companion effects before
allowing a stop without convergence. Preserve original accepted ownership and
all durable data. Independently correct only the Service visibility label through
a new conditional inventory review, leaving route/PVC identities, bytes and
dependencies unchanged; resume ordinary native preview cleanup afterward.
No generic arbitrary abandonment, raw provider patch or history reset is allowed.

**Independent native closure (2026-10-02):** Source b805d64a was frozen and
executed against the exact original transaction. Its bounded stop preserved both
accepted and converged vectors without asserting convergence. The subsequent
review changed only the Service visibility label, with route and volume Verify
operations. Both Service and DomainMapping became Ready while retaining their
UIDs; the durable PVC UID and known file contents stayed unchanged. All 30
unselected scope revisions remained exact, and all 31 scopes converged. Public
preview cleanup then resumed successfully with a zero-provider-operation
retirement review retaining all three native objects. The linked diagnostic proof
now includes the repair executable hash and exact correction review. Final
immutable release binding remains a separate acceptance gate.

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

Initial ad-hoc reproduction sources are archived under [mp23-reproductions](../mp23-reproductions/README.md). Product regression tests listed above remain the closure requirements.

## Original tracker preface

The preface of the tracker before the 2026-10-02 split, unchanged except for relative links.

This is the authoritative handoff for implementation findings sent by the audit session. Read it alongside [MP-23](../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). The detailed initial reasoning is in [the audit report](mp23-initial-audit.md); that report is a historical snapshot, while this tracker owns current status.

[The 2026-09-29 operational experiments](mp23-operational-experiments.md) add
source-bound append counts, cold/warm unrelated-history measurements, a controlled
command-factory recovery comparison, and the public unknown-target reproduction.
They update implementation ordering in MP-23/EP-153/156/159 without changing this
tracker's closure statuses. In particular, the synthetic recovery comparison does
not close F09, and the head-snapshot prototype does not close F06.

Implementation owner: existing session `01a0e893-337f-7b82-ac5d-16f41bf5ce21` (Implement typed resource inventories). Independent verifier and tracker steward: session `01a0eb5e-6e5a-7be3-8812-e04e2638bde9` (Review plan and logs). Child ownership below survives either session ending.

## F34

**Kourier gateway rejects HTTPS listener updates on cp3, so new routes never become Ready** — P1; **Closed**; owners EP-155 / EP-153.

**Observation (2026-10-02, implementation session claude-opus-5-5, read-only):** On local context `local` (Colima `nagare-mp23-cp3`, k3s v1.34.6), `net-kourier-controller` logs `Error pushing snapshot to gateway: … listener_8443 … listener_9443: multiple filter chains with overlapping matching rules` every ~0.3 s: 3,664 occurrences between 03:44:24Z and 04:02:42Z, continuous, with earlier logs rotated. Every Kubernetes Ingress reconciles, but the gateway refuses each new snapshot. The F30 Service's KIngress stays `LoadBalancerReady=Unknown`, while existing routes (`nagare-access`, `mp23-independent-volume`, `mp23-cleanup-pr-review`) stay Ready. Two ingresses, `mp23-correction-proof` (Ingress created 03:08:34Z) and `mp23-independent-volume`, terminate TLS with the same namespace wildcard secret `personal/personal.127-0-0-1.sslip.io` (`*.personal.127-0-0-1.sslip.io`). That is the leading hypothesis for the overlapping filter chains, but it is not confirmed: Kourier source was not available for inspection. This blocks MP-23 A4 (F30 terminal state) and any new local route, so EP-155 C2 too.

**Required diagnosis/repair:** Write the recovery as an ExecPlan step with pass/fail gates before any cluster change. Confirm from the Kourier/Envoy configuration which filter chains overlap. Decide whether Nagare's route/TLS rendering (ADR 20) produces the overlap for any second wildcard-TLS Service in a namespace; if so, it is a product defect needing a source fix and a local regression. Otherwise identify the fixture state that caused it. Do not patch Kourier objects, delete the shared certificate or reset history. After repair, resume the preserved F30 transaction through the public path.

**Implementation update (2026-10-02, `beca6886`; claude-opus-5-5):** Root cause confirmed from Envoy's admin `config_dump`. The rejected listener put `mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` in two filter chains: the wildcard-secret group and its own chain. The host belonged to KIngress `e11d734a…` and KCertificate `8255d8d4…`, both ownerless. The KIngress's `serving.knative.dev/domainMappingUID` label equals the tombstone physical identity of collected DomainMapping `standalone:site-preview-mp23-cleanup-pr-review/route/route`, and it routed to the deleted preview Service. Product cause: reviewed collection deleted DomainMappings with `propagationPolicy: Orphan`, and Knative, unlike for a Service, does not block orphaning a DomainMapping's children. Fix: DomainMappings are collected only through the controller-descendant authority, now extended to the net-certmanager chain. Preview cleanup selects it, a plain review refuses, and `collectionDeleteRequest` refuses an older saved Orphan review (ADR 22 amendment). Three authority regressions, the updated request test, all 1,132 `nagarectl` tests, all six public web-cleanup variants (now with a route certificate child and a refused plain route collection) and the style gate pass. Fixture repair (EP-155 step 2, written before acting): two UID/resourceVersion-preconditioned Background DELETEs of exactly those orphans, after rechecking ownership, label, absent Service and identity. The shared wildcard certificate, the unowned TLS Secret, Kourier objects and history were left untouched. Within 20 s both listeners had no `error_state`, `mp23-correction-proof` was `Ready=True`, prior routes stayed Ready, and the cert-manager chain was garbage-collected. Remaining: independent verification, and a native reviewed DomainMapping collection through the new authority on a candidate.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read (`beca6886`). The authority regressions cannot compile on the parent. An Orphan-refusal mutation survives because the same fix also removed DomainMapping from `collectionPathPrefix` (a redundant guard). Closure rests on native evidence from the acceptance C2 ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)):
- preview cleanup retired DomainMapping `b3438290` with Background collection of its descendants ("observed 4");
- both KIngresses and the Certificate were gone afterwards, and the neighbouring DomainMapping `1ad1693c` was unchanged;
- the repeat plan created no review;
- live, `net-kourier-controller` logged no overlap or snapshot error in 3 h, and all six KIngresses were Ready.
The stated failure is corrected. **Closed.**

## F35

**Preflight refusal after admission strands the transaction with no supported exit** — P1; **Closed**; owners EP-153 / EP-160.

**Implementer native evidence (2026-10-03, nagare-f3, development binary at `66afd6a6`+, cp3):** A reviewed isolated Redis restore (`f3race`, review `27d8b8ed…`, five operations) was saved. An unowned PVC was then created at its planned scratch PVC address. `inventory apply --yes` exited 1 in 2 s. The first operation had already created Service `mp23-independent-redis-restore-f3race`, then the PVC operation stopped with `KnownNoEffect "adapter preflight refused"`, leaving `tx-27d8b8ed…` active on the `local` store. While the foreign PVC existed, `inventory resume` repeated the refusal, and `inventory recover` (action `abandon-partial-database-restore`) refused with `recovery-state: operation has no uncertain effect to resolve`. Planning any other review is blocked while the transaction is active. The only exit was deleting the conflicting object out of band; the same resume then converged in 31 s. [Raw record](../mp23-implementer-results-2026-10-03/cp3-data-drills.json).

**Cause (source):** `Nagare.Inventory.Execute.Driver.executePrepared` returns `StoppedFailed … KnownNoEffect` on a preflight refusal without journalling. `Execute.Transaction` then calls `releaseClaim … Nothing`, which keeps `headActiveTransaction`. `Execute.RecoveryPolicy` offers decisions only for uncertain effects and three restore- or prune-specific abandonments. Admission runs adapter preflight only for migration sources (`Execute/Admission.hs`). F30 fixed one instance (status-only churn) narrowly; this is the general class.

**Required repair/verification:** Give an admitted transaction that stopped at a `KnownNoEffect` preflight refusal a reviewed, bounded exit that does not require deleting an object the operator may not own. It must keep completed effects' exact identities in history as unaccepted or retained objects and must never claim convergence. Alternatively, or in addition, check create-target absence and other cheap live preconditions for every operation at admission, so such a review is refused before it becomes active. Regression: an object appears at a later operation's address after admission, and the transaction then reaches an explicit terminal state through the public path, with the store usable and the earlier effect's identity recorded. Independently re-run the native race.

**Implementation update (2026-10-03, `570467f0`; claude-opus-5-5):** New recovery decision `abandon-refused-operation`. It requires the active transaction, no data fence, no recorded intent for the selected operation, and no other operation in an uncertain state. It reruns the same adapter preflight under the lock and ends the transaction only on a current refusal, through the existing aborted-claim release. A passing preflight answers "resume the transaction instead". Completed earlier effects keep their journal identities and are not accepted, matching the existing abandonments. `test/InventoryRefusedPreflightRecoverySpec.hs` covers four variants: abandonment with the object still present and the store reusable, a passing preflight refused and then a converging resume, a completed operation refused, and an earlier ambiguous effect refused. All 1,154 tests, the style gate and the architecture check pass; `docs/runbooks/inventory-operations.md` documents the action. Native re-run on cp3 (development binary, same claim protocol): the foreign PVC (`be75172b…`) made the stopped transaction `tx-4d66348e…` end through the new decision. The store went idle, the foreign PVC's UID was untouched, and a new restore plan succeeded immediately ([record](../mp23-implementer-results-2026-10-03/cp3-data-drills.json)). The admission-time absence check was not added. Remaining: independent review and an independent native race run.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read (`570467f0`, `d9aed800`). The regressions pass. A mutation of the other-uncertain-operation guard fails the EarlierUncertain variant ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). The reviewer re-ran the native race on the C2 context under the cp3 claim ([record](../mp23-independent-results-2026-10-04/f35-native-race-7596632c.json)):
- an unowned PVC at the reviewed scratch address stopped `tx-9f285d75…` with `KnownNoEffect "adapter preflight refused"`;
- resume repeated the refusal, and other planning was blocked (`active-transaction`);
- `abandon-refused-operation` ended it on a fresh preflight refusal, leaving the head idle (generation 1526) and the restore scope unaccepted;
- the foreign PVC kept UID `0fa935b8` and resourceVersion 41629, and a new review saved immediately.
**Closed.** The admission-time absence check remains unimplemented, as the implementer recorded.

**Implementation update (2026-10-05, EP-175 M3; claude-opus-5-5):** [ADR 26](../../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and EP-175 M3 replaced this exit with `nagarectl inventory close`. `abandon-refused-operation` is now an alias of close, and its guards are deleted (mutation records F35 and F37 are retired). Behaviour change: a refused operation classes as refused with no effect. If nothing else in its scope took effect, the scope reverts to the review's base, not to the last converged revision. A scope in which an earlier operation completed is kept at its desired revision, so the completed objects stay owned (hazard H2). The other conditions still hold through close's rule: resume must be unable to progress, and nothing may be unknown. Regressions: `InventoryRefusedPreflightRecoverySpec` and "closing a refused update keeps a created member owned and admits no update as never-started (H2) " in `InventoryCloseSpec`. Status is the verifier's to set.

## F36

**A failed Redis scratch restore cannot be abandoned and wedges the store** — P1; **Closed**; owner EP-160.

**Implementer source evidence (2026-10-03, claude-opus-5-5):** A Redis isolated restore creates a scratch Service, PVC, StatefulSet and verify Job. If the StatefulSet's `download` init container fails, its pod never becomes Ready and apply stops ambiguous after the readiness wait. Examples are a pinned version that becomes unreadable after review, or an RDB load failure. On `inventory recover`, `Adapters/Kubernetes.hs` returned `RecoveryUnresolved` for any NotReady StatefulSet (terminal failure was proved only for Jobs), and `Execute/RecoveryPolicy.databaseRestoreOnlyReview` accepted only Job-only reviews. Neither resume nor recover could end the transaction. The trace comes from the 2026-10-03 restore-path research for the cp3 drills; no native reproduction was run, because forcing it destroys a backup's pinned version.

**Implementation update (2026-10-03, `6d7951c9`; claude-opus-5-5):** Kubernetes recovery asks a new runtime probe (`Nagare.Inventory.Adapters.RestoreScratch.restoreScratchPodFailed`) whether a pod controlled by the exact scratch StatefulSet UID has a container that exited non-zero, now or before a restart. Only StatefulSets labelled `nagare.dev/restore-scratch` qualify. A proven failure becomes `RecoveryTerminalFailure`, and `abandon-partial-database-restore` also accepts an exact Redis restore-only review (`redisRestoreOnlyReview`). The scratch objects stay unaccepted for separate reviewed recovery. `test/InventoryRedisRestoreRecoverySpec.hs` covers the pod-list cases (owned failure, success, foreign owner, empty and malformed lists), the abandonment, and the refusal of a review with an extra member. All 1,165 tests and the gates pass. Remaining: a native run on a disposable context (C2) that removes a throwaway backup's pinned version after review, plus independent review.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint on a fresh cp3 context; nagare-phase-b):** Throwaway backup `c2f36` of `scenario-redis`; restore review `3a34ab21…` saved; exactly the pinned archive version `80ab0c9b…` deleted with a throwaway `nagare-mc` Pod. Apply stopped ambiguous after 5 min with the scratch StatefulSet's `download` init container in CrashLoopBackOff (`HeadObject … 404`). `inventory recover … abandon-partial-database-restore` closed the transaction; the scratch Service, PVC and StatefulSet stayed unaccepted and the store went idle with accepted equal to converged ([record](../mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json)). Remaining: independent review.

**Acceptance C2 on `14071e58` (2026-10-03, nagare-phase-b):** Reproduced natively on the frozen candidate: the pinned-version deletion again ended in `abandon-partial-database-restore` with the store idle ([record](../mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read (`6d7951c9`). The owner-UID mutation fails the pod-list regression ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). C2 native evidence: pinned version `f86d4522` removed, the apply stopped ambiguous with a download 404, and `abandon-partial-database-restore` closed it. Independent live read: the journal of `tx-99394208…` holds seq 1333 Ambiguous and seq 1334 OperatorResolved for StatefulSet `88ee069d`; the scratch objects remain unaccepted; the head is idle ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)). **Closed.**

**Implementation update (2026-10-05, EP-175 M3; claude-opus-5-5):** [ADR 26](../../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and EP-175 M3 replaced this exit with `nagarectl inventory close`. `abandon-partial-database-restore` is an alias of close. A failed scratch StatefulSet settles as terminal partial, and close keeps the restore scope at its desired revision with the scratch objects owned. Previously the scope reverted to its converged revision and the scratch objects were left unaccepted. The scheduled-prune and volume-restore abandons changed the same way. Regression: `InventoryRedisRestoreRecoverySpec`. Status is the verifier's to set.

## F37

**Configuration drift written by another field manager has no reviewed repair** — P1; **Closed**; owners EP-149 / EP-153.

**Implementer native evidence (2026-10-03, nagare-phase-b, candidate `db808a74`, disposable C2 context on cp3):** For the EP-155 `drift-classification` check, application B's Knative Service (`personal/scenario-b`, UID `7dde1aa3…`) was edited with `kubectl patch`, changing `autoscaling.knative.dev/max-scale` from `3` to `5`. `inventory status --json` classified this correctly: exactly one `configuration-drift` finding for `application:scenario-b/scenario-b/service`, distinct from the `retained-orphan` members of the retired `scenario-retire` database. The repair was the same reviewed `app deploy` as the original deploy. It saved review `a248f688…` with two operations (`UpdateResource` on the Service, `VerifyResource` on topic `jobs`). Apply stopped at `op-7cba97a4…` with `KnownNoEffect "Kubernetes object has fields managed by another writer: kubectl-patch"`. No provider write occurred; the UID and the edited value were unchanged.

The transaction then had no supported exit. `inventory recover … abandon-refused-operation` refused with `recovery-state: operation has no uncertain effect to resolve`, and `inventory resume` repeated the same refusal. `tx-a248f688…` stays active (`resume-required`), so every other plan on the store is blocked. The only exit would be removing the foreign manager out of band, which the C2 rules forbid as manufacturing a result. Evidence is in `checks/drift-classification/{status-drift.json,repair-refused.json}` under the C2 evidence directory, to be archived with the C2 results.

**Cause (source):** `Nagare.Inventory.KubernetesConfiguration.confirmInventoryFieldOwnershipFor` refuses an update when any non-status `managedFields` entry belongs to a manager other than `nagare-inventory`, except the PVC and Deployment controller paths in `expectedControllerFields`. Field-manager conflicts are not checked at planning, so a review that cannot apply is saved and admitted. After intent is recorded, the refusal leaves the operation `Failed (KnownNoEffect)`. `Execute.RecoveryPolicy.recoverableState` excludes that state for every decision, and the F35 decision `abandon-refused-operation` (`570467f0`) admits only an operation with no recorded intent (`Execute/Recovery.hs`). F35 closed the preflight form of this class; this is the apply-time form.

**Why it matters:** IR-24's required verification asks that drift fixtures distinguish *repairable* configuration drift, missing resources, foreign ownership and the other categories (IR-24 case 5). Classification works, but the most ordinary drift, an operator's `kubectl edit` or `kubectl patch`, cannot be repaired through a review. Planning a repair also wedges the store.

**Required repair/verification:** Give drift owned by another field manager a reviewed path: either an explicit reviewed field-ownership takeover bound to the observed managers and resourceVersion, or a planning-time refusal that names the foreign manager and the fields before any review is saved. Separately, give an admitted operation that ended `Failed (KnownNoEffect)`, whose effect is proved absent, a bounded terminal exit that keeps completed effects unaccepted and never claims convergence. Regression: a foreign-manager edit on an accepted Service is repaired, or refused at planning, with no active transaction left behind. Independently re-run the C2 drift check on the resulting candidate. Product direction (takeover versus classification plus refusal as the contract) is with the operator (2026-10-03).

**Implementation update (2026-10-03, `d9aed800` and `1df735a6`; claude-opus-5-5, nagare-phase-b):** Operator decision relayed by nagare-f3: add a reviewed takeover. (A) `d9aed800` (EP-153): `abandon-refused-operation` also ends an operation whose latest state is `Failed (KnownNoEffect)`. The journal is the no-effect proof, so no fresh preflight refusal is required. Pending operations keep that requirement, and the no-data-fence and no-other-uncertain-operation guards are unchanged (`Execute/Recovery.hs`; new variant `ExecuteRefusal` in `test/InventoryRefusedPreflightRecoverySpec.hs`). (B) `1df735a6` (EP-149): `app deploy --save-plan --take-over-fields` makes the Kubernetes adapter record the exact foreign managed-field entries (without timestamps), UID and resourceVersion of a drifted object in a version-3 mutation (`FieldTakeover`). The transport accepts a live foreign entry only if the review recorded it, with the same UID and resourceVersion, then runs the usual forced server-side apply. Afterwards it requires that no foreign non-status owner remain, otherwise the operation stops ambiguous (`KubernetesConfiguration.confirmReviewedFieldTakeover`, `confirmTakeoverSettled`). Without the opt-in, planning and the refusal are unchanged; versions 1 and 2 keep their bytes; `ObservationNative` accepts the version-3 envelope. `test/InventoryKubernetesFieldTakeoverSpec.hs` drives the production transport over a modelled kubectl in seven cases: refusal without the opt-in, a successful takeover, a new foreign manager, a changed UID or resourceVersion, leftover foreign fields, an object moving during preparation, and tampered bindings. All 1,173 `nagarectl` tests, `just haskell-style-check`, `scripts/check-haskell-architecture.py`, `scripts/check-cli-architecture.py` and `scripts/test-managed-command-audit.sh` pass. The runbook gains "Repair configuration drift". Limitations: `inventory plan` does not take the opt-in yet; a planning-time refusal naming the foreign fields was not added. Remaining: a candidate build, then the native C2 drift check (close `tx-a248…` through (A) on the old store, then the takeover repair on a fresh store), and independent review.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint; nagare-phase-b):** On a fresh context, a `kubectl patch` of application B's max-scale showed as exactly one `configuration-drift` finding, distinct from nine `retained-orphan` members. The ordinary replan (`fe6f6637…`) stopped `KnownNoEffect … kubectl-patch`, and `abandon-refused-operation` closed it (fix A). The `--take-over-fields` replan (`ee8a4049…`, summary "takes over fields from kubectl-patch") converged: same Service UID, max-scale back to 3, managed fields now only `nagare-inventory` plus the controller's status entry, and all 278 findings converged ([record](../mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json)). Remaining: independent review and the acceptance C2 on the next candidate.

**Acceptance C2 on `14071e58` (2026-10-03, nagare-phase-b):** Reproduced natively on the frozen candidate: the strict replan refused `kubectl-patch`, `abandon-refused-operation` closed it, and the `--take-over-fields` replan restored max-scale 3 under the same UID with `nagare-inventory` as the sole manager ([record](../mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read (`d9aed800`, `1df735a6`). The refusals precede any write, and the takeover's forced apply carries UID and resourceVersion preconditions. Without `d9aed800`, the ExecuteRefusal variant fails with the native `recovery-state` wedge. The settled, binding and identity mutations of `1df735a6` fail 1/7, 2/7 and 1/7 ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). C2 native evidence: the strict replan stopped on `kubectl-patch` and was closed with `abandon-refused-operation`, and the takeover converged. Independent live read: ksvc `scenario-b` keeps UID `2ae59e2c`, max-scale is 3, and the managers are only `nagare-inventory` and the controller status ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)). **Closed.** The planning-time refusal and `inventory plan` opt-in remain unimplemented, as recorded.

**Implementation update (2026-10-05, EP-175 M3; claude-opus-5-5):** The stopped drift update now ends with `inventory close` ([ADR 26](../../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and EP-175 M3 replaced this exit with `nagarectl inventory close`); the runbook's drift section says so. The field-ownership takeover is unchanged.

## F38

**A failed GCS head advance after a published journal event stops ambiguous and discards the store error** — P2; **Closed**; owners EP-153 / EP-156.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `db808a74`, checkpoint C3 context `mp23-c3` in `tan-ng-labs`):** The cluster-stage apply (review `58266a9b…`, 210 operations) stopped after 241 s with `ambiguous tx-58266a9b… at op-60773165…`, a `CreateResource` for ClusterRoleBinding `cert-manager-controller-approve:cert-manager-io`. The object existed, created by `nagare-inventory` at 20:38:07Z. The GCS store held `journal/00000000000000000143.json` recording that operation as `Completed` at 20:38:08Z with an intact hash chain. But `head.json` stayed at `sequence` 143, which is the next sequence to write, and its executor claim was released. So the event was published, but the head compare-and-swap that commits it failed. `inventory status` correctly reported the operation as `intent-recorded`, because the event at 143 is not yet committed. Neither stdout nor stderr carried the store error.

**Cause (source):** `Execute/Journal.appendEvent` writes the journal object (`appendAtObservedHead`), then advances the head through `replaceObservedHead` with the observed provider generation. Any `Left` there, whether `PutPreconditionFailed`, `PutNoEffect` or `PutUnknown`, reaches the driver as `Left _ -> StoppedAmbiguous` (`Execute/Driver.hs`), and the reason is dropped. No claim-renewal writer exists, so a concurrent head write by this client is not the explanation. The provider outcome is unknown.

**Recovery observed:** This was safe in this case. `inventory resume` re-ran Kubernetes recovery, whose completion proof digests only the operation, resource, physical UID and desired digest. That reproduced the orphan's proof exactly, so `appendEvent`'s conflict path accepted the existing event (`sameEventMeaning`) and advanced the head. The orphan kept its original timestamp, and the transaction continued from sequence 144. An adapter whose recovery proof differs from its execution receipt would instead hit `StoreObjectConflict` at the orphan's sequence on every later append, and wedge the store.

**Required repair/verification:**
- Carry the store error into the stopped result and the command's stderr, so an operator can tell a precondition failure from a transport failure.
- After a failed head advance, reread the head once. If it already names the event, return success. If it is unchanged and the claim is still held, retry the conditional head write a bounded number of times before stopping.
- Make orphan adoption independent of proof equality. For example, compare against the orphan's journal state and adopt it when the recovering adapter independently proves the same completion. Or give an explicit reviewed exit for an uncommitted orphan event.
- Regression: a fake object store fails the head write once after the journal write. Two outcomes must be covered: the transaction continues, or it stops with the reported reason, and resume converges with no wedge, including for an adapter whose recovery proof differs from its execution receipt.

**Implementation update (2026-10-04, claude-opus-5-5, nagare-phase-b; the operator decided to fix F38 before the release):** All changes are in `Execute/Journal.appendEvent`.
- **Bounded head retry.** After a failed head write, the head is reread.
  - If it already holds the replacement, the write landed despite an unknown outcome, and the append succeeds.
  - If it is unchanged, and so still carries this executor's claim, the conditional write is retried with the fresh provider generation, up to 3 times with 250/500/750 ms backoff.
  - Otherwise the original store error is returned.
- **Orphan adoption independent of proof equality.** An event already published at the head's next sequence is checked: same sequence, previous digest and transaction means it is an uncommitted orphan of this chain. Such an orphan is first committed as history.
  - If it has the same meaning as the new event, or both are `Completed` for the same operation (even with different receipt digests), the orphan and its original receipt are kept.
  - Otherwise the new event is appended after it, with a bounded budget.
  - An orphan from another transaction, or with a different chain position, is still refused with `StoreObjectConflict`.
  - The journal validator checks only sequence and chain, and an operation's state is its latest event, so committing a same-transaction orphan is safe history.
- **Store error reporting.** A failed append now prints the store's own error on stderr, with the transaction and operation, for example `nagarectl: inventory journal append for tx-… at op-… failed: StoreIoError "…"`. The `StoppedAmbiguous` result still carries no reason: adding a field would change about 80 constructor sites for no additional operator information, since the CLI already prints stderr.
- **Regressions:** `test/InventoryJournalHeadAdvanceSpec.hs`, on a fake object store whose head write fails right after a `Completed` event is published:
  - a refused head write is retried and converges;
  - a head write that landed with a lost acknowledgement is read back and converges;
  - a persistent failure (4 attempts) stops ambiguous, then resume, with a recovery proof that differs from the execution receipt, converges with one completion per operation and keeps the orphan's original receipt.

  All three fail on the previous `Journal.hs`: each stops ambiguous, and the third wedges at resume. All 1,184 nagarectl tests, `just haskell-style-check` and `check-haskell-architecture.py` pass.

  **Verification still required:** an independent check. A native injected GCS head failure is not practical on a real bucket; the regressions use the production `ObjectBackend` code path over fake object operations.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read: the claim is checked before publishing; orphan adoption requires the same transaction, sequence and previous digest; the retry compares whole manifests, including generation, so there is no ABA. All three regressions fail individually without the fix, the third wedging at resume, and pass at the candidate ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). **Deviation accepted:** the store error is printed on stderr but not carried in `StoppedAmbiguous`. The constructor has 79 sites, and the CLI prints stderr at the failure point, so the operator can tell a precondition failure from a transport failure. **Limit:** no native GCS head failure was injected; the regressions drive the production `ObjectBackend` over fake object operations. **Closed.**

## F41

**A local node restart destroys every local backup, and local escrow verification needs the source cluster** — P1; **Closed**; owners EP-155 / EP-159.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint; nagare-phase-b):** For `source-unavailable-recovery` (operator decision (a): escrow, stop the k3d server, copy the MinIO data, disposable MinIO, `db verify-escrowed-backup`, disposable PostgreSQL restore), the escrow and an online `verify-escrowed-backup` passed (job `37ae52ab…`, object version `2d7ffc36…`). After `docker stop k3d-nagare-local-server-0`, the MinIO pod's `emptyDir` directory no longer existed in the node's kubelet volume and every remaining `emptyDir` was empty. After `docker start`, MinIO came back as a new pod with no buckets: every local backup, receipt and snapshot was gone and `nagare-backups` was absent. The store was never mutated (generation 1025, idle). A read-only platform bootstrap plan does not see the missing bucket (its Job is still complete), so no reviewed repair exists. Separately, local `verify-escrowed-backup` reads MinIO credentials from a cluster Secret and opens a kubectl port-forward (`ScheduledStore.withLocalObjectStore`), so it cannot read an offline copy, contrary to the user documentation. [Attempt record](../mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json).

**Cause (source):** `cluster/local/minio/minio.yaml` mounted the bucket on an `emptyDir` by an EP-100 decision (local mode as a disposable GCS stand-in). That choice predates local mode carrying release evidence for backups, restores and recovery.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b; decision relayed by nagare-f3):** (a) Local MinIO keeps the bucket on a `minio-data` PersistentVolumeClaim (`local-path`, 2Gi) with a `Recreate` Deployment strategy; the reviewed `local-object-store` scope orders the Deployment after the claim and pins the new manifest digest. The local-path volume lives in the k3d node's `/var/lib/rancher/k3s` volume, so it survives a pod restart and a node `docker stop`/`start`, and `k3d cluster delete` (`just local-down`, the C2 teardown) removes it with the node. This supersedes the EP-100 `emptyDir` decision (EP-155 Decision Log). (b) `db verify-escrowed-backup` gains `--offline-object-store URL` and `--offline-credentials FILE` for local mode: only a loopback `http://127.0.0.1:PORT` or `http://localhost:PORT` origin is accepted; the credentials come from a file that must not be group- or other-readable, with exactly `AWS_ACCESS_KEY_ID=` and `AWS_SECRET_ACCESS_KEY=` lines, and reach curl only through its stdin configuration. Exact-version, signature and checksum checks are unchanged. The user documentation now states that local mode reads through the cluster by default. Regressions: the local object-store scope test asserts the claim, the claim mount without `emptyDir`, and the ordering; a parser test covers loopback-only origins and strict credential files. Remaining: the acceptance C2 on the next candidate proves source-unavailable recovery natively with a live copy of the bucket served offline, then independent review.

**Implementer native evidence on the frozen candidate (2026-10-03, `14071e58`, acceptance C2; nagare-phase-b):** The fresh platform review created `minio-data` (Bound on local-path, `Recreate` strategy). For source-unavailable recovery, the escrow and an online `verify-escrowed-backup` of scheduled job `b8fa6642…` passed (object version `7afd20b7…`, recovery point 23:45:01Z). A live tar of the MinIO volume was copied out, then `docker stop` made the API unreachable. A disposable MinIO on `127.0.0.1:19000` served the copy, and `verify-escrowed-backup --offline-object-store … --offline-credentials …` passed with the identical version, receipt and checksum. That exact archive restored rows 1-3 into a disposable PostgreSQL with zero errors. After `docker start` the bucket was intact (the online verification read the same version, freshness healthy) and the store was unchanged and idle ([record](../mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)). Remaining: independent review.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. The offline origin is loopback-only and the credentials reach curl through stdin. Without the fix, the MinIO scope regression fails (no PVC), and a loopback mutation fails the parser regression ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). C2 native evidence ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)): the offline verification ran during the 17:39:03Z–17:39:21Z node stop with the same object version, receipt and sha256, the archive restored rows 1–3, and the bucket survived the restart. Live: `minio` uses Recreate on PVC `minio-data` (Bound, local-path), and the C2 offline credential file is mode 0600. **Closed.** The credential-file mode check has no unit test; recommended.


**Re-verification on candidate `847543896d07` (2026-10-04, nagare-reviewer):** follow-up `27798465` moves the credential read to `ScheduledStore.readOfflineCredentials` over `Store.FileIO.readPrivateFile`, which now also refuses a symlink. Its regression ("offline credentials are read only from a private regular file") fails under a plain-read mutation ([mutations](../mp23-independent-results-2026-10-04/candidate-84754389-mutations.txt)). The closure stands.
## F42

**The managed-resource evidence assembler can never accept real runner output** — P1; **Closed**; owner EP-157.

**Implementer native evidence (2026-10-03, candidate `14071e58`, acceptance C2 runner; nagare-phase-b):** `scripts/assemble-managed-resource-evidence.sh` refused the runner rehearsal `c2-14071e58-runner` (one `CreateResource` of `runner-probe`, a verified zero-operation replan) with "initial review has no bound operations". The check required `review.candidateDigest` to equal the SHA-256 of `candidate.json`, and the no-op check required the no-op review's `candidateDigest` to equal `run.json`'s `verificationCandidateDigest`. Those are different digests: a review's `candidateDigest` is the planner's proposal digest over binding, base, desired revisions and changes (`Plan/Changes.hs`), while `candidate.json` and `candidate.sha256` are the compile manifest (`Command.hs`). The checks could pass only against hand-made fixtures, and the operations message hid the mismatch.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b; decision relayed by nagare-f3):** The initial review is bound to the compiled candidate through its desired scope revisions: every desired scope, content digest and generation in `review.desiredRevisions` must equal `candidate.json`'s desired scopes and generations. The no-op review must have no operations and its desired scopes and content digests must equal the final observation's accepted revisions (an unchanged replacement still advances a generation). Each condition has its own refusal message. `scripts/test-managed-resource-evidence.sh` now uses real nagarectl shapes, adds refusals for each new condition, and replays real runner output from `fixtures/managed-resource-evidence/c2-14071e58-runner`: both reviews bind, and the run's incomplete final observation still refuses. The assembler ships in the payload, so the fix needs the next candidate. Remaining for a complete local assembly, all outside this finding: the runner must observe every provider (the C2 runner ran without the en endpoint, so `AccessExecutor` was unobserved); the coverage audit at `14071e58` is itself incomplete (`Command.Cleanup` and `InfraCommand.InfraDestroy` pending, `infra-destroy` recipe pending, one catalogue row incomplete); and the release manifest input is the release build manifest, not the payload's `release.json`.

**Cloud rehearsal (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3g`):** a nix build of `471cb409` (F45–F47) ran the cloud runner (`scripts/rehearse-gcp-inventory-release.sh --candidate`) on the checkpoint context, which runs the `7d486457` payload. Plan, apply and verify ran back to back: one `CreateResource` of `runner-probe`, verify killed before its marker and re-run to `verified`, a zero-operation no-op review, and a final observation with `observationComplete: true` and `missingProviders: []`. All 17 cloud assertions recorded and finalized. `scripts/assemble-managed-resource-evidence.sh` then assembled `inventory-evidence.json`, the first cloud assembly. This is pipeline evidence, not acceptance: the evidence is labelled with the `471cb409` payload although the context runs `7d486457` ([F48](../mp23-findings.md#f48)). Two helper defects were found and fixed on the way (`4ad4392a`, `e41b1cab`). The cloud wrapper cannot forward `--private-store-export`, so the private export was taken right after verify with the head unchanged (generation 940, sequence 809).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. The fixture replay fails on the parent assembler with the native refusal, and both helper regressions fail on their parents ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Natively, the reviewer re-assembled the acceptance C2 evidence from a scratch copy, with the release manifest and coverage result, and got output identical to the recorded `inventory-evidence.json` ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)). **Closed.** Cloud assembly is checked again in phase 3.

## F50

**One transient failed gcloud read makes the state-bucket ownership guard stop a run** — P2; **Closed**; owner EP-156.

**Implementer native evidence (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3h`, candidate `7596632c`):** In scenario phase 3, the reviewed `db restore scenario-pg c3gpg1 --restore-id c3gpgr1` plan refused before any review: `StoreConditionFailed "refusing: gs://tan-ng-labs-c3-1007-pmkjjpp-state is owned by project number '<unknown>', not the target project 'tan-ng-labs' (number '882581411903')…"`. The guard (`Nagare.Ops.PulumiBackend.bucketOwnershipVerdict`) read the bucket's project number with `gcloud storage buckets describe … --raw --format=value(projectNumber)` and got nothing. Right after, the same command returned `882581411903` three times in a row. The store was idle (generation 713, sequence 648, no transaction or claim), and nothing had been planned or changed.

**Assessment:** the guard behaved correctly. An absent number fails closed, and must never mean "continue". The cost is operational: one failed read ends a multi-hour run, and its refusal message ("choose a state bucket name that is unique…") points the operator at a name collision that does not exist.

**Required repair/verification:**
- Retry the two project-number reads a bounded number of times, say 3 with short backoff, inside the guard. A mismatch or missing number after the retries still refuses.
- Phrase the refusal differently for "could not read" and "read a different number".
- Regression with a fake gcloud that fails once and then answers.

**Operator decision (2026-10-04):** re-run from the refused step on the checkpoint; the re-run used the same guard.

**Implementation update (2026-10-04; claude-opus-5-5):**
- `Nagare.Ops.PulumiBackend.readProjectNumber` retries a missing or non-numeric project-number answer, up to three attempts in all, with 0.5 s and 1 s pauses.
- The bootstrap ownership assertion and the inventory store's ownership checks (`Nagare.Inventory.Store.Remote`, for both the gcloud and SDK transports, and the discovery read of the target number) use it.
- A number still missing after the last attempt refuses as before, now with its own message: "could not read the owning project number … after 3 attempts; ownership is never assumed". A different number keeps the name-collision message.
- **Regression:** `test/Nagare/Test/Pulumi.hs`, "one failed project-number read is retried before the guard refuses (F50)": a fake gcloud fails once and then answers, and a persistent failure still returns nothing after exactly three calls. The verdict test checks the new wording.
- **Gates:** all 1,189 tests, the style gate and both architecture checks pass.
- `FoundationRuntime`'s own observation reads are unchanged; they report unavailable rather than refusing a run.

**Verification (2026-10-04, nagare-reviewer, candidate `847543896d07`):** Source read: the retry is bounded at 3 attempts, and a number still missing afterwards refuses with its own message, so the guard is still fail-closed. The regression passes, and a mutation removing the retry fails it ([mutations](../mp23-independent-results-2026-10-04/candidate-84754389-mutations.txt)). **Closed.**

## F49

**An out-of-band replacement of an accepted database is reported converged, and its new incarnation's receipts plan for ingestion** — P1; **Closed**; owners EP-159 / EP-153.

**Native evidence (2026-10-04, candidate `7596632c`, C2 context on cp3):** The EP-159 source-replacement drill ([procedure and results](../mp23-implementer-results-2026-10-03/ep159-source-replacement-7596632c.json), implementer nagare-phase-b, commit `d19df6d1`) replaced the accepted throwaway database `personal/ep159-throwaway` out of band:
- StatefulSet `aa482c54…` became `ffd8af26…`, and PVC `8ab1d859…` became `51889c7f…`. The deletes were preconditioned raw DELETEs, followed by `kubectl create` from the saved objects, which carry the original `nagare.dev` identity annotations.
- The replacement destroyed the data. Independent read by nagare-reviewer after the claim was released: in the live database, `to_regclass('public.ep159_known')` is null.
- `inventory status --json` nevertheless classifies all ten throwaway members, StatefulSet and PVC included, as `converged`.
- Receipt B, a pending pre-replacement receipt, is refused at planning, and isolated restore of the ingested receipt A is refused. Both are correct.
- But receipt C, written by the replaced (empty) incarnation, saves an ingestion review (`db backup-receipts ep159-throwaway --backup-id C --save-plan`, exit 0, review `c79b06dc…`). It was not applied, so the apply-time behaviour is unverified.
- Independent read of the head: the accepted throwaway scopes are exactly the database and receipt A; C was not ingested. The head is idle at generation 1510, sequence 1387.

**Cause (source, reviewer read):**
- `Nagare.Inventory.Status.classifyDrift` maps every `ObservedPresent uid` of an accepted member to `Converged` without comparing `uid` with the member's accepted incarnation. Retained members are compared (`retainedPhysical`, `Status.hs` around line 193).
- Receipt ingestion builds its expectation from the live source's StatefulSet and PVC UIDs (`ScheduledIngest`, `scheduledReceiptExpectationFromCronJob`), not from the UIDs accepted for the database. A receipt from a same-name replacement therefore matches.

**Why it matters:** after a source is destroyed and recreated out of band, the operator surface reports it healthy. Backups of the new, empty incarnation can become recovery points, freshness can turn healthy, and the earlier good receipts stay refused for isolated restore. This contradicts EP-159's re-scoped claim that "out-of-band replacement refuses ingestion and isolated restore".

**Required repair/verification:**
- Bind accepted stateful members, at least database StatefulSets and PVCs, to their accepted physical incarnation. Status must report a same-name replacement (for example as `foreign-owner`, `replacement-required` or a dedicated category), never `converged`.
- Refuse receipt ingestion whose source UIDs differ from the accepted incarnation, not only from the live one.
- Regression: a fake observation with the accepted annotations but a new UID is not `converged`, and ingestion of a receipt naming that new UID refuses at planning.
- Native: rerun the EP-159 drill on a fresh throwaway database, taking the signing-key escrow **before** the replacement, so that step 7b (escrowed verification of A) is also evidenced. Show that C's ingestion refuses and that status reports the replacement.
- Whether this blocks the MP-23 release is the operator's decision.

**Implementation update (2026-10-04, claude-opus-5-5, nagare-phase-b; the operator decided to fix F49 before the release):**
- **The record.** The head gains `incarnations`: the provider UID of each data-bearing Kubernetes member that a converged review created, adopted, updated or verified (`Execute/Incarnations`, recorded in `Claims.releaseClaimWith`).
  - Data-bearing means durable members (a database's PVC and credential) and StatefulSets.
  - The first commit (`38815245`) bound only durable members, which left the stateless StatefulSet unbound. The independent source review caught this, and the follow-up commit binds StatefulSets too, as the required repair asked ("at least StatefulSets and PVCs").
  - A create or adoption establishes the record.
  - An update or verification binds only a missing record, so a later review never launders a replacement.
  - Retained and collected members drop their record.
  - The field is omitted when empty, so existing heads keep their bytes.
- **Status.** `Status.classifyDriftWith` reports `replaced-incarnation` (never `converged`) when the observed UID differs from the record.
- **Ingestion.** `ScheduledIngest.compileScheduledIngestScope` refuses with "scheduled receipt source is not the accepted database incarnation; it was replaced outside Nagare" when the live StatefulSet or PVC differs from the record.
- **Listing and freshness.** `db backup-receipts`, including `--check-freshness`, refuse to grade a replaced source with the same message.
- **ADR 22** is amended.
- **Regressions:** `test/InventoryIncarnationSpec.hs`.
  - Convergence records a created durable member, then a reviewed update of a replacement object leaves the record unchanged.
  - Convergence records a StatefulSet, which is stateless.
  - Status classifies a different UID as `replaced-incarnation`, the same UID as `converged`, and no record as `converged`.
  - Ingestion refuses a replaced StatefulSet or PVC, but not the recorded incarnation or a store without a record.

  The tests use the new API, so each guard was checked by mutation: removing the convergence recording, the status comparison, the ingestion comparison or the never-rebind rule fails exactly its regression. All 1,187 nagarectl tests, the style check and the architecture check pass.
- **Known limits (from the independent source review), recorded in ADR 22:**
  - Recording is fail-open. An unavailable observation at convergence records nothing, and the next update or verification binds the live object.
  - Members without a record pass status and ingestion as before.
  - Binding from the journal's completion identity is follow-up work.
- **Native rerun still required:** the EP-159 drill on a fresh throwaway, with the escrow taken before the replacement, showing C's ingestion refused, status `replaced-incarnation`, and 7b evidenced.
- **Implementer native evidence (2026-10-04, frozen candidate `84754389`, the C2 context on cp3; [record](../mp23-implementer-results-2026-10-03/ep159-source-replacement-84754389.json)):**
  - Before the replacement, the head's incarnations equalled the live StatefulSet and PVC UIDs (the StatefulSet is bound).
  - After the out-of-band replacement, status reported `replaced-incarnation` for exactly the throwaway's StatefulSet and PVC. The C2 run on this context had shown zero such findings after C1 and before the runner.
  - Ingesting pending receipt B and restoring ingested receipt A both refused.
  - `db backup-receipts` listing and `--check-freshness` refused the replaced source with F49's message.
  - With the escrow taken before the replacement, A verified (7b).
  - The incarnation records were unchanged through every refusal.
  - The joint retire of the database and receipt scopes converged, the store is idle, and no other object changed.
- **Gaps in that native run:**
  - Receipt C, written by the replacement at 22:30Z (Job `6360c2ef…`), was not attempted. The driver discovered receipts through the listing, which now refuses the replaced source. The unit regression covers C's ingestion refusal.
  - Retirement retained the replacement's UIDs (StatefulSet `b131b5a7…`, PVC `4a6d653c…`), not the recorded incarnation, because retirement binds what it observes. A later collection would target the replacement.
- **Receipt C, native (2026-10-04, `84754389`, [record](../mp23-implementer-results-2026-10-03/f49-receipt-c-84754389.json)):** a fresh throwaway was replaced out of band, and its 22:45Z backup Job (`43925446…`, UID taken from kubectl) wrote receipt C from the replacement.
  - `db backup-receipts f49c-throwaway --backup-id C --save-plan DIR` refused: exit 1, "scheduled receipt source is not the accepted database incarnation; it was replaced outside Nagare".
  - No review directory existed before or after, and the head was unchanged.
  - The incarnation records were unchanged, and status listed `replaced-incarnation` for exactly the throwaway's StatefulSet and PVC.

**Cleanup note:** `db retire ep159-throwaway` refuses with `dangling-reference` (receipt A's scope consumes the database's backup producer). The joint `inventory retire --scope standalone:database-ep159-throwaway --scope standalone:database-scheduled-receipt-personal-ep159-throwaway-42fee7bd-299e-47a7-90e4-fd726f5c9783 --out DIR` plans successfully (reviewer, read-only, head unchanged). That joint retire is the supported path for a database with ingested receipts.

**Verification (2026-10-04, nagare-reviewer, candidate `847543896d07`):** Source read (`38815245`, `84754389`). All 1,190 tests pass at the candidate. The reviewer's own mutations each fail exactly their regression: removing recording at convergence, disabling the status comparison, disabling the ingestion check, allowing a Proved rebind, and dropping StatefulSet selection ([mutations](../mp23-independent-results-2026-10-04/candidate-84754389-mutations.txt)). Native read-only cross-checks: the C2 head records the eight incarnations of the platform `en-db` and `shomei-db` members, and they equal the live UIDs. The drill v2 record matches its raw outputs (`pending-evidence/ep159/`): B and restore A refused, listing and `--check-freshness` refused with F49's message, 7b verified A, and `replaced-incarnation` appeared for exactly the throwaway's StatefulSet and PVC. **Not yet closed:** receipt C, the case this finding was opened for, still has no native refusal. `db backup-receipts --backup-id C --save-plan` does not go through the listing's source check (`resolveScheduledSource`). It observes the live UIDs and relies only on the F49 check in `compileScheduledIngestScope`, which only the unit regression covers. Also, `receipt-C.txt` records "no receipt C appeared", although a 22:30Z Job succeeded; correct that record. **Next check:** a native C ingestion attempt on a fresh throwaway, taking the Job UID from `kubectl`, must refuse with no review saved and the head unchanged. Two defects in the fix's surroundings are opened separately: [F51](../mp23-findings.md#f51) and [F52](../mp23-findings.md#f52).

**Verification, closure (2026-10-04, nagare-reviewer, candidate `847543896d07`):** the remaining check was the native receipt-C refusal (implementer nagare-phase-b, [record](../mp23-implementer-results-2026-10-03/f49-receipt-c-84754389.json), `cbe259f1`). The reviewer checked it against the raw files (`pending-evidence/f49-receipt-c/`) and the live cluster, read-only:
- On the fresh throwaway `f49c-throwaway`, the recorded incarnations equalled the old UIDs: StatefulSet `713e633f…`, PVC `4a37029b…`.
- The deletes were preconditioned on exactly those UIDs (resourceVersions 22406 and 22390). The replacements `109dffa3…` and `d419be3c…` were created at 22:44:15Z and are live.
- Status listed `replaced-incarnation` for exactly the throwaway's `pvc` and `statefulset`.
- Receipt C's Job `43925446-b0c8-42a4-bfa1-96df8ae0154f` was created at 22:45:00Z, after the replacement, and succeeded. It is therefore a backup of the replaced incarnation.
- `db backup-receipts f49c-throwaway --backup-id 43925446… --save-plan DIR` exited 1 with `invalid-scheduled-ingest` "scheduled receipt source is not the accepted database incarnation; it was replaced outside Nagare". The save directory was absent before and after, and the head stayed at generation 1520, sequence 1397.
- The incarnations were unchanged after the attempt. The store is idle (generation 1524, sequence 1399).
With the drill v2 results above and the reviewer's mutations, every part of the stated failure is corrected natively: status reports the replacement, and receipts from the replaced incarnation do not ingest, list or count toward freshness. **Closed.** The fail-open recording limits are documented in ADR 22. The adjacent defects [F51](../mp23-findings.md#f51) and [F52](../mp23-findings.md#f52) stay Open, deferred by operator decision.

## F51

**Retirement retains an out-of-band replacement's identity instead of the accepted incarnation** — P2; **Closed**; owners EP-153 / EP-159.

**Native evidence (2026-10-04, candidate `847543896d07`, C2 context on cp3; F49 drill v2, implementer nagare-phase-b, [results](../mp23-implementer-results-2026-10-03/ep159-source-replacement-84754389.json)):** the throwaway's accepted incarnations were StatefulSet `770c18c5…` and PVC `241e2475…`. After the out-of-band replacement, status correctly reported `replaced-incarnation`. The joint `inventory retire` of the database and receipt A's scope then converged. Independent read of the head by nagare-reviewer: `retained` carries the *replacement* UIDs, StatefulSet `b131b5a7-779d-4f19-843e-3a5e78be5306` and PVC `4a6d653c-53fb-4630-99fc-902be522632d`. The `incarnations` entries for the throwaway were dropped.

**Cause (source):** `releaseClaimWith` drops incarnation records for retained members, "since `retained` carries their identity". But retirement records the identity it observes at retirement, not the recorded incarnation. A retirement review never compares the two.

**Why it matters:** this is the laundering ADR 22's F49 amendment rules out ("a later review never launders an object that replaced the accepted one outside Nagare"), only through retirement instead of update or verify. Retained history then names an object Nagare never accepted:
- a later reviewed collection would target the replacement;
- retained-data operations would treat the replacement PVC, possibly empty, as the retained data.

**Required repair/verification:** retirement of a member whose observed UID differs from its recorded incarnation must refuse, naming the member. Or it must retain the recorded incarnation and mark it absent or replaced, never the replacement's UID. Regression: retiring a scope with a replaced member never puts the replacement UID in `retained`. Native: on a throwaway, after an out-of-band replacement, the retirement refuses or retains the accepted identity.

**Operator decision (2026-10-04, in session nagare-phase-b):** deferred as a known limitation of this release, to be documented in ADR 22 and the release notes and fixed in a follow-up. It does not block MP-23 completion.

**Operator decision (2026-10-04, superseding the deferral above; [retrospective](../mp23-engineering-retrospective-2026-10-04.md) §6):**
- Un-deferred. Fix it in MP-23. It blocks MP-23 completion.
- The fix lands with a class-level interpreter regression under [ADR 25](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), [EP-173](../../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) M2's incarnation invariant. The regression must fail on the pre-fix source.
**Implementation update (2026-10-05; claude-opus-5-5):**
- A retention proof (`buildRetentionProofs` in `src/Nagare/Inventory/Plan/Changes.hs`) now names the member's recorded incarnation when the head has one, and the observed object only when it has none. Retained history therefore never names an object that replaced the accepted one outside review.
- Retirement is not refused. ADR 22's documented exit for a replaced database is to retire and recreate it, and a refusal would remove that exit.
- Consumers of retained history already compare a retained UID with the live object:
  - status reports the replacement as `replaced-incarnation`;
  - a reviewed collection refuses it;
  - retained-data operations refuse it.
- **Regression:** EP-173's recovery model, scenario "create with a durable volume, then retire". I3's retirement clause requires every retained entry to carry the member's last recorded incarnation. On the pre-fix source, the model fails under `Replaced` on the PVC before retirement ("retirement retained …/uploads/pvc under a UID other than its accepted incarnation"). With the fix it passes.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F51-retention-proof-uses-observed.diff` (the retention proof takes the observed UID again, `Plan/Changes.hs` `buildRetentionProofs`) fails the recovery model's fast tier: "I3: retirement retained application:model-web/uploads/pvc under a UID other than its accepted incarnation", under `Replaced` at observation boundaries in "create with a durable volume, then retire".
- **Class coverage (ADR 25):** the recovery model's retire scenario with the `Replaced` fault at every observe boundary, invariant I3 (retirement clause). Every retention proof is built by `buildRetentionProofs`, which retirement and scope replacement share.
- **Why the interpreters missed it before:** no world produced a replaced object until EP-173 M2 added the `Replaced` fault.
- **Closed** for the stated failure (retirement). The same harm reached through a migration's source, where a rename copies from and retains a replaced source, is a separate code path and is opened as [F62](../mp23-findings.md#f62).

**Reopened (2026-10-05, nagare-84, the same reviewer who closed it earlier that day):**
- The exhaustive review ([C, N1](../mp23-exhaustive-review-2026-10-05/C-identity.md)) shows that the fix makes admission refuse to retire a member replaced before planning.
  - The retention proof now names the record (`Plan/Changes.hs:388`).
  - Admission requires the live object to equal it (`Execute/Admission.hs:180-199`) and refuses with a generic `retention-observation`.
- That contradicts this finding's own "retirement is not refused" and ADR 22's documented exit, "retire and recreate the database".
- The recovery model hid it: `test/InventoryRecoveryModelSpec.hs:479-494` counts an admission refusal with no active transaction as `Done`, so the retire scenario passes without retirement running.
- The caught mutant shows that the guard is pinned, not that the exit works. Data stays safe, but a replaced database scope has no supported exit.
- **Needed:**
  - a reviewed rebind or a retention that marks the record replaced ([PROPOSAL D2](../mp23-exhaustive-review-2026-10-05/PROPOSAL.md));
  - the model must stop counting admission refusals as `Done`;
  - a regression in which retirement of a replaced member actually completes.

**Implementation note (2026-10-05, EP-175 M3; claude-opus-5-5):** The recovery model's harness no longer counts an admission refusal as `Done`. It carries one named tolerance for this finding, N1 (`InventoryRecoveryModelSpec.hs`, the retire scenario under `Replaced`). EP-176 M3 removes that tolerance when ADR 27's reviewed rebind lands; until then this finding stays reopened.

**Implementation update (2026-10-05, EP-176 M3; claude-opus-5-5):** N1 is fixed.
- **Retirement.** Retiring a member that was replaced outside review keeps the record in the retention proof and names the live replacement (`retentionReplacedBy`). Admission verifies that the reviewed replacement is still live, and the retained incarnation keeps the record with `replacedBy` beside it. Retained history never names the replacement as the accepted object, and the retirement no longer has to be refused.
- **Recovery model.** The N1 tolerance is removed. A replacement made after review is still refused at admission; the model takes that exit with a fresh review, which then names the replacement and retires.
- **Mutation record.** `ADR27-N1-replaced-retirement-unnamed` (the proof stops naming the replacement) fails the fast tier with 36 violations.

Status is the verifier's to set.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source (ADR 25). Test: "a reviewed rebind records a replacement, after which it is the accepted incarnation (ADR 27 §3)". Killed: `F51-retention-proof-uses-observed`, `ADR27-N1-replaced-retirement-unnamed`, `ADR27-rebind-not-bound`, `ADR27-rebind-of-recorded-object`, `ADR27-rebind-unverified-at-admission`. The fast tier injects `Replaced`. ADR 25's interpreter-first rule supersedes the earlier request for a native throwaway drill. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F54

**A landed application Service update whose new revision never becomes Ready has no reviewed exit, so the store stays wedged** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence (2026-10-04/05, nagare-reviewer, phase 3a on the acceptance C3 `mp23-c3i`, candidate `847543896d07`, operator-approved bounded sequence):**
- A throwaway application `rvf16` (scope `application:rvf16`: PostgreSQL `rvf16-pg` plus a web Service with a 64-CPU request) was created with review `22572096…`. Apply stopped ambiguous after 354 s at the never-ready Service create.
- `stop-incomplete-application` ended it in 11 s. Ownership was retained: Service `442ecbcb…`, StatefulSet `308a3ea3…`, PVC `6df5e086…`. A known row was written.
- The corrected review `44577a2c…` (100m CPU) was saved: 3 never-started creates, 1 conditional Service update and verifies. Its apply was killed with SIGKILL after 15 s, and `inventory resume` ran 346 s.
- The conditional update **landed on the original Service UID** (generation 2 observed). But revision `rvf16-00002` crash-loops: the borrowed `scenario-b` image needs `REDIS_URL`, a reviewer fixture error, standing in for any bad application change. The resume stopped `ambiguous … at op-7a4cc6b7364a9ad834f551a9`.
- `inventory recover … stop-incomplete-application` for that operation refused with `unsupported-recovery: adapter did not prove the operator's requested action`.
- `tx-44577a2c…` stays active (generation 964), and every other plan on the store is refused. No out-of-band repair was made, per the stop rule.

**Cause (source, reviewer read):** `Plan/History.incompleteApplicationOnlyReview` admits a stop of an `UpdateResource` only when the update was never intended (`neverIntended`). That is F30's never-started branch; F16's branch covers unready creates. Once a Service update has landed, adapter recovery reports `RecoveryAwaitingReadiness`. Resume can only wait again. `abandon-refused-operation` needs a pending or `Failed (KnownNoEffect)` state. No decision can end the transaction while the new revision cannot become Ready. Only an unreviewed edit of the live Service, or the application becoming Ready by itself, can release the store.

**Why it matters:** a bad application change (a crashing image, missing configuration, a failing readiness probe) is the most ordinary failure an operator meets. It blocks the whole context's inventory, including other applications, backups, restores and staged teardown, until someone writes to the cluster outside review. This is the update counterpart of F16.

**Required repair/verification:**
- Give a landed but unready application Service update a reviewed, bounded exit. For example, extend `stop-incomplete-application` to an intended update whose landed object the adapter proves is exactly the reviewed one (UID, generation, the reviewed spec digest and exclusive ownership) and unready. It must keep the scope at its last converged revision, record the landed incarnation, never claim convergence, and let a new corrected review update the same Service.
- Regression: an update that lands and never becomes Ready can be stopped, and a corrected review then converges on the same UID with the data preserved.
- Native: repeat this sequence on a fresh candidate context: create, stop, a bad correction, stop, a good correction that converges with the same Service, StatefulSet and PVC UIDs and the known row.

**Current state of `mp23-c3i`:** the transaction is active and claim-free. Data and ownership are intact: the known row `1|rvf16-d747f5b7-before-correction` was written to `rvf16-pg`. The operator decides how the context continues (see the reviewer's report).

**Implementation update (2026-10-04, nagare-phase-b; operator decision: fix before release):** `stop-incomplete-application` now accepts an intended Service update when the adapter proves the landing exactly.
- **Adapter:** recovery returns the stop-only decision `RecoveryLandedUnready` for an `UpdateResource` on a Knative Service only when all of these hold:
  - the observed object has the reviewed before-state's UID and owner;
  - its digest is the reviewed spec digest;
  - a guarded live read with managed fields (`confirmLandedUnready`) shows the same UID and resourceVersion;
  - `generation` equals `status.observedGeneration`;
  - no writer other than `nagare-inventory` owns a non-status field;
  - Ready is not True.

  The production adapter receives the live reader. Without it, nothing is proved.
- **Review check:** `Plan/History.incompleteApplicationOnlyReview` takes a `LandedUpdateProof`. With the proof, the selected update's journal may hold only `IntentRecorded`, `Ambiguous` and the stop marker. Companions must still be Completed, or never-intended ConfigMap creates ordered after the Service. A weaker `RecoveryAwaitingReadiness` for an intended update still refuses.
- **Resume** still stops ambiguous at a landed update.
- **The stop** keeps admitted ownership and the prior converged revision. A corrected review then updates the same Service in place.
- **Regressions:** `test/InventoryLandedUpdateStopSpec.hs`.
  - The adapter proof refuses eight cases: changed spec, replaced object, unowned, another owner, foreign field owner, unobserved generation, moved between reads, Ready.
  - A landed update stops with head accepted/converged unchanged; the corrected review plans `UpdateResource` on the same Service plus the never-started ConfigMap create, and converges.
  - An extra uncertain companion, a missing landing proof, or a weaker readiness decision each refuses.
- **Mutation proof:** removing each guard fails a named test. The one equivalent mutant is the adapter's `owner == mutationResource` check, which `previousOwner == owner` implies because the reviewed before-state is owned by this resource; it is kept as defence in depth.
- **Not changed:** the planning-history proof of never-started members. It releases only durable members, and an update stop's companions are stateless.
- [ADR 22](../../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) and the [inventory runbook](../../runbooks/inventory-operations.md) record the boundary.

Native proof on `mp23-c3i` awaits the operator's approval of the bounded sequence:
1. stop `tx-44577a2c…` with the fixed CLI;
2. apply a corrected rvf16 review (literal `REDIS_URL`) and check Service `442ecbcb…`, StatefulSet `308a3ea3…` and PVC `6df5e086…` plus the known row;
3. confirm a zero-operation replan.

**Verification, source and interpreter level (2026-10-05, nagare-reviewer, `96d38d67`):** native work is on hold by operator decision (nagare-9's proposal). The diff was read in a private worktree.
- **Adapter:** `RecoveryLandedUnready` needs all of: the before-UID and owner, the reviewed spec digest, a live read with managed fields at the same UID and resourceVersion, generation equal to observedGeneration, no foreign non-status manager, and Ready not True.
- **History:** admits an intended update only with that proof, and only in `IntentRecorded` or `Ambiguous`.
- **Driver:** resume still stops ambiguous.
- **Tests:** all 1,193 tests pass, including the three `InventoryLandedUpdateStopSpec` cases.
- **Reviewer mutations:** removing History's landed admission fails 2 tests. Disabling the generation, Ready, ownership, spec-digest or before-UID check each fails the adapter-proof test.
- **Two mutants survive, as test gaps rather than defects:**
  - letting History accept any state for the landed update. The recovery-state gate in `Recovery.hs` likely already refuses completed or failed operations, so this is untested defence in depth.
  - making the driver treat `RecoveryLandedUnready` as "continue" (`pure Nothing`). No regression proves that resume of a landed, unready update stops ambiguous without a second write.
- **Requested:** a regression for the resume behaviour, and one for a completed update refusing the stop.
- **Next check:** the native stop and corrected convergence on `mp23-c3i` (`tx-44577a2c…`), once the operator lifts the native hold. EP-173's stuck-state model should also cover this class.

**Reviewer read of the native run (2026-10-05, nagare-reviewer):** nagare-phase-b ran the native F54 sequence on `mp23-c3i` under an operator approval given in its session before the native hold reached it. The CLI was frozen `96d38d67` with the platform root pinned to the `847543896d07` workspace.
- (a) The stop of `tx-44577a2c…` at `op-7a4cc6b7…` succeeded.
- (b) The corrected review converged as `tx-5160965a…`.
- (c) A replan had 0 operations.
The reviewer's independent read-only check afterwards:
- Service `442ecbcb-9b03-41af-9543-0e293089585e` at generation 3, observed 3, Ready True, latest ready revision `rvf16-00003`. Managers are only `nagare-inventory` (Apply, Update) and `controller` (status).
- StatefulSet `308a3ea3-2cd2-4942-98df-a6ecce29ec62` and PVC `6df5e086-0b2b-419c-a633-10ac9f484e48` are unchanged, and `rv_known` returns `1|rvf16-d747f5b7-before-correction`.
- The store is idle at generation 993.
So the stated failure is corrected natively, and the store is no longer wedged. **F54 stays Verifying** until both of these exist: the operator's model-first rule (EP-173 M1–M2 stuck-state model, dad4d632), and the two regressions for the surviving mutants, which nagare-phase-b is adding.

**Reviewer re-check of the regression gaps (2026-10-05, `d58218d0`, test-only):** all 1,194 tests pass. Both previously surviving mutants now fail a named regression:
- the driver's `RecoveryLandedUnready _ -> pure Nothing` fails "resume of a landed unready update stops ambiguous without a second write";
- History's `landedUpdate = onlyStates (const True)` fails "landed update stop refuses an extra uncertain operation and an unproved landing".
Every F54 guard is now pinned by a regression. F54 stays Verifying only for the operator's model-first rule (the EP-173 M1–M2 stuck-state model).

**Archived raw evidence (2026-10-05, nagare-84):** the phase-3a sequence that wedged `mp23-c3i` is in [`phase3a-seq-mp23-c3i/`](../mp23-independent-results-2026-10-04/phase3a-seq-mp23-c3i/README.md). nagare-phase-b's native F54 run (driver, step logs, reviews, status before and after) is in [`f54-native-mp23-c3i/`](../mp23-implementer-results-2026-10-03/f54-native-mp23-c3i/README.md).

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F54-landed-unready-recovery.diff` (the adapter no longer answers `RecoveryLandedUnready`) and `F54-stop-admits-landed-update.diff` (the stop admits only never-intended updates) each fail the recovery model with "I1: stopped (ambiguous) with no supported exit" in the bad-update scenarios, with no injected fault needed.
- **Class coverage:** the three bad-update scenarios plus `LandsUnready` at every write, invariants I1, I2 and I4. This meets the operator's model-first rule (EP-173 M1–M2). The native correction on `mp23-c3i` and `d58218d0`'s regressions confirm it.
- **Why the interpreters missed it before:** the in-memory driver never modelled "update lands, never becomes Ready".
- **Closed.** A non-Knative update that lands unready (a Deployment or a database StatefulSet) still answers `RecoveryUnresolved` (`Adapters/Kubernetes.hs`, `landedUpdate` is Knative-only). That is outside this finding's stated scope and is opened as [F63](../mp23-findings.md#f63).

## F53

**`nix flake check` fails at the candidate: sandbox-only test failures and stale check assertions** — P1 (the C4 gate requires a green flake check); **Closed**; owner EP-154.

**Implementer evidence (2026-10-04, claude-opus-5-5, C4 on candidate `84754389`):** The aarch64-darwin clone-free rehearsal passed, `typed-config` included. `nix flake check` failed 5 of 46 aarch64-darwin checks, and `--all-systems` failed 2 more on x86_64-linux. Every failure was in the check harness, not in shipped behavior:
- `nagarectl-build-test`, darwin: 8 of 1,190 tests failed only in the sandbox, because `jq`, `python3` and `shasum` were missing from the test PATH. All 1,190 pass outside it.
- `upload-images-builder-confinement`: `shasum` was missing.
- `managed-command-audit`: the CLI architecture test and the command-audit fixture copy the read-only sandbox sources and then edit them (`PermissionError`).
- `gcp-bootstrap-rehearsal`: stale assertions. The host-image dry run no longer names `scripts/upload-images.sh` (reviewed image publication, `c352cfec`), and the bootstrap and TLS recipes run `scripts/run-reviewed-bootstrap.sh`.
- `cluster-bootstrap-defaults`: a stale path. The ACME URLs moved into `Nagare/Target/Acme.hs` in the F43 split (`0c6ad875`), and a test helper (`test/Nagare/Test/Init.hs`) also names them.
- x86_64-linux `nagarectl-build-test` (7 tests) and `host-transport-recovery`: scripts generated at test time used `#!/usr/bin/env …` or `/bin/bash` and `/bin/cat`, and a Linux build sandbox has neither. This included the payload's Helm capture plugin read from the source tree.

Nothing had run the flake check for many commits, so earlier candidates carried most of these failures.

**Operator decision (2026-10-04):** fix now, with a new candidate. `84754389` becomes non-final, and its runs (C1, C2 and the `mp23-c3i` C3) become checkpoints.

**Implementation update (2026-10-04; claude-opus-5-5):**
- The sandbox gets `jq`, `python3` and `perl` (for `shasum`) for the CLI tests, and `perl` for the upload-images test.
- Both fixture copies are made writable.
- The stale assertions are updated to the reviewed recipes.
- The ACME check names `Target/Acme.hs` and allows `test/Nagare/Test/Init.hs`.
- The CLI tests read a source copy whose `cluster/` scripts are shebang-patched (`sourceForTests`).
- The fake Pulumi scripts use `#!/bin/sh`; the registry SSH fixture finds `cat` and `bash` on PATH; the image-prune fake `k3s` uses the running interpreter.
- No file under `cli/*/src`, `cli/*/app`, `cluster/`, `infra/` or `nixos/` changed.
- **Gates:** `nix flake check --all-systems` passes with 36/36 aarch64-darwin and 35/35 x86_64-linux checks. All 1,190 tests, the style gate, both architecture checks and the command audit pass locally.

**Independent verdict, pending reviewer write-up (2026-10-05; transcribed by nagare-84 from nagare-reviewer's session at 00:54:21Z):** "I counted the new all-systems log myself: aarch64-darwin 36 passed and 0 failed, x86_64-linux 35 passed and 0 failed, with no build errors. The Linux checks ran through `ssh://builder@nix-gcp-builder`. So F53's `nix flake check` fix holds on both systems at `b74b7e49`." The reviewer noted that the log does not print its revision, so it relied on nagare-f3's statement that the run used the clean candidate worktree. This came after the reviewer had rejected an earlier "35/35 x86_64-linux" claim taken from the shared tree, in which every Linux check had failed because the builder refused connections. The status stays Verifying until the reviewer writes its own closure. [EP-174](../../plans/174-gate-every-commit-before-any-native-run.md)'s full gate now makes that claim checkable: a salted builder probe plus a revision-bound record.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed. The candidate's `nix flake check --all-systems` realised every check, 37/37 aarch64-darwin and 36/36 x86_64-linux, with 0 failures. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F55

**A landed unready application update still has no exit when its review also updates its release history or verifies a member** — P1; **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5) on the F54-repaired source (`96d38d67`), in under a second, with no native run.** The model runs real planning, the driver, the recovery policy and the Kubernetes adapter over an in-memory API server with an adversary (`cli/nagarectl/test/InventoryRecoveryModelSpec.hs`). Its scenario "create, bad update, corrected update (history follows the release)" fails invariant I1, a stopped transaction with no supported exit, even with no injected fault:
- The adapter proves the landing (`RecoveryLandedUnready`).
- `stop-incomplete-application` is still refused ("adapter did not prove the operator's requested action"), and resume and every other recovery action are refused too.

**Cause (source):** `incompleteApplicationOnlyReview` (`src/Nagare/Inventory/Plan/History.hs`) admitted a never-started companion only as a `CreateResource` of a stateless ConfigMap. The rule came from the F30 never-started path, and F54 reused it. Three real reviews break it:
- An ordinary application update rewrites its release-history ConfigMap on every deploy (an `UpdateResource` ordered after the Service; `addRelease` in `Application/Release.hs`).
- A corrected review after a stop verifies unchanged members (a `VerifyResource`), so a second unready landing also wedged.
- An independent durable member's verify can still be pending when the Service lands. The F54 native run on `mp23-c3i` escaped all three only because its release history had never been created.

**Implementation update (2026-10-05; claude-opus-5-5, reviewed in outline by nagare-phase-b):**
- A never-intended companion may verify any member of the scope, durable ones included. It may create or update only a stateless ConfigMap explicitly ordered after the stopped Service. A companion with no recorded intent had no effect.
- The never-started-member set that lets a later plan recreate a `ConfirmedAbsent` durable member (`loadUnstartedApplicationCreates`) is restricted to `CreateResource` operations. A durable member that a stopped review only verified or updated, and that is later absent, stays a `durable-resource-missing` refusal; it is never replanned as a fresh create. The hazard is reachable, so the filter is a required part of the fix (nagare-phase-b's review). A legacy (version 1) or takeover (version 3) Service update can be refused at preflight and never intended. After status-only churn the adapter reports `RecoveryAwaitingReadiness`, so F30's never-started stop accepts it. F55 lets that review carry a never-started durable verify. Without the filter, a later plan would replan the deleted volume as a fresh, empty create.
- The F30 refusals stay: an intended companion, and a never-started create of another kind (a Secret).
- **Regression:** the recovery model's fast tier covers five scenarios, including history-follows and an independent durable volume, under every single fault at every Kubernetes write boundary. It fails on the old rule: one fault-free violation, plus the good update and corrected update under `LandsUnready`. It passes with the fix. Refusing durable verifies again makes the durable-volume scenario fail twice, so that admission is needed.
- **Hazard regression:** `test/InventoryApplicationUpdateRecoverySpec.hs`, "a durable member only verified by a stopped update is never replanned as a fresh create (F55)". Two never-intended updates are stopped; the second review verifies the durable volume, which stays pending. The volume is then deleted out of band. Without the filter, planning returns `CreateResource` for the volume and the test fails. With the filter it refuses `durable-resource-missing`.
- The existing F30 companion test still passes unchanged.
- **Gates:** all 1,196 `nagarectl` tests, the style gate and the architecture check pass. ADR 22 and `docs/runbooks/inventory-operations.md` state the new companion rule.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F55a-companion-rule-create-configmap-only.diff` (the original create-only ConfigMap rule) and `F55b-companion-rule-no-verify.diff` (verifies not admitted) each fail the recovery model with I1 in the history-follows and durable-volume scenarios. `F55c-replan-any-never-started.diff` (any never-started operation may be replanned as a create) fails "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)".
- **Class gap (inferred from source):** real application scopes also carry task CronJobs, DomainMappings and broker triggers. A never-started update of one of these that the digest order puts after the Service is refused by the companion rule (`Plan/History.hs`), and the transaction wedges again. The model's scenarios contain only the Service, the history ConfigMap and a PVC.
- **Stays Verifying.** Needed: a model scenario whose release also changes a task CronJob and a DomainMapping (or a written proof that such companions always run before the Service), under `LandsUnready`.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)". Killed: `ADR26-close-reverts-to-converged`, `ADR26-close-ignores-unknown`, `ADR26-never-started-admits-updates`. ADR 26 deleted the companion rule this finding named, so its CronJob gap is moot. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F56

**A landed application Service update whose Service is then replaced outside review has no exit** — P1; **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5) when M2 added the `Replaced` fault, with no native run.** In every bad-update scenario, the reviewed write lands on the Service. The Service is then deleted and recreated outside review (an operator's `kubectl replace --force`) before Nagare observes readiness. The transaction stops ambiguous, and every exit is refused (invariant I1, six violations):
- Resume makes no progress.
- `stop-incomplete-application` needs F54's landed proof, which requires the reviewed UID, so the adapter cannot prove it.
- `abandon-refused-operation` needs a no-effect refusal, and this operation's intent was recorded.

`docs/runbooks/inventory-operations.md` documented this refusal ("the Service was edited or replaced outside review … investigate"), but no supported command ends the transaction afterwards.

**Implementation update (2026-10-05; claude-opus-5-5):**
- The Kubernetes adapter's recovery returns a new decision, `RecoveryTargetReplaced`, for an intended Knative Service update when the live object carries the member's ownership stamp but a different UID than the reviewed before-state. The conditional write was keyed on the old UID, so it can no longer land. Nothing proves that the replacement holds the write.
- Resume still stops ambiguous on it. Only `stop-incomplete-application` accepts it, under F55's companion rules for a settled intended update. The stop marker records the replacement's UID, and the stop accepts nothing: the scope keeps its last accepted revision. A new review then plans from the live replacement, as it would if the replacement had happened while the scope was idle.
- A Knative Service is stateless and has no incarnation record, so stopping launders no identity. Data-bearing members keep F49's rules.
- An edited Service, one with a foreign field manager, is still refused.
- **Regression:** the recovery model's fast tier. Without the fix it fails I1 under `Replaced` at the observation after the bad Service write in all three bad-update scenarios. With the fix it passes. `test/InventoryLandedUpdateStopSpec.hs` now expects `RecoveryTargetReplaced` for a replaced object, and still expects every other case to be refused.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F56-target-replaced-recovery.diff` (no `RecoveryTargetReplaced`) and `F56-stop-accepts-replaced.diff` (the stop does not accept it) each fail the recovery model with I1 under `Replaced`.
- **Class gap (inferred from source):** an out-of-band deletion without recreation (`KubernetesAbsent`) also makes the conditional write impossible, but it falls to `RecoveryUnresolved` (`Adapters/Kubernetes.hs`). The worlds have no deletion fault.
- **Stays Verifying.** Needed: a `Deleted` world fault, and either a fix or a new finding for what it shows.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "an update whose target was replaced settles as target gone (F56's deleted answer)". Killed: `ADR26-O1-kubernetes-settle-unknown`, `ADR27-N9-update-proof-accepts-replacement`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F57

**A verification whose target is replaced after it ends ambiguous has no exit** — P1; **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5) with the `Replaced` fault.** A corrected review verifies an unchanged member, such as the release-history ConfigMap. The member is replaced between the verification's execution and its completion read, so the verification ends ambiguous (two violations). From then on:
- Recovery reports `RecoveryUnresolved`, because the before-state's UID changed.
- Resume makes no progress.
- `abandon-refused-operation` refuses an operation whose intent was recorded unless its refusal was journalled.

A `VerifyResource` never writes, so this operation certainly had no effect, yet no command can end it.

**Implementation update (2026-10-05; claude-opus-5-5):**
- The Kubernetes adapter's recovery of a `VerifyResource` whose proof fails returns `RecoverySafeToRetry`, because a verification writes nothing.
- When the driver retries an operation that already had recorded intent (a retry the adapter proved safe) and the retry's preflight refuses, the driver now journals `Failed (KnownNoEffect "adapter preflight refused: …")` instead of returning without an event. The adapter has already proved the earlier attempt had no effect, and the refusal comes before any new effect, so the record is accurate. `abandon-refused-operation` then ends the transaction under F37's rule. A first attempt at a never-intended operation is unchanged: it journals nothing, and F35's fresh-preflight rule applies.
- **Regression:** the recovery model's fast tier. With only F56 it still fails I1 for the corrected review in the history-unchanged and durable-volume scenarios. With F57 it passes. `test/InventoryKubernetesSpec.hs` now expects a replaced verification target to recover as a safe retry, never as proved complete, and its preflight still refuses.

**Gates (F56 and F57):** all 1,197 `nagarectl` tests pass.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F57a-verify-safe-to-retry.diff` (a verify's recovery is no longer safe-to-retry) and `F57b-journal-no-effect-refusal.diff` (a refused retry is not journalled as a no-effect failure) each fail the recovery model with I1 under `Replaced`.
- **Class gap (inferred from source):** every executor's verify writes nothing, yet Broker, CDN, Cloudflare and Foundation recovery return `RecoveryUnresolved` on a mismatch, which is the same wedge. The fix is Kubernetes-only, and those executors have no world until EP-173 M4.
- **Stays Verifying.** Needed: a generic fix keyed on `VerifyResource` (in recovery or the driver) with a generic-adapter regression. The other route is for the operator to scope the other executors to EP-173 M4 explicitly; that is a deferral and needs the ledger.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source for Kubernetes. Tests: "a retry the adapter proved safe that preflight then refuses is journalled as failed with no effect (F57)" and "the driver never executes a verification (O6)". Killed: `F57b-journal-no-effect-refusal`, `ADR26-O6-verify-executes`, `M9-verify-guard-compares-resource-version`, `B7-i8-asks-adapter-for-verify`. Non-Kubernetes verifies are a documented limit of release line (b). The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F58

**An application whose first deploy stopped unready cannot be retired, because a never-created member has nothing to retain** — P2 (no wedge: the store stays idle, but the application can be deleted only by first shipping a working image); **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5), in its new retire scenario, with no native run.** In "create with a durable volume, then retire", under `LandsUnready` on the first deploy's Service create, the deploy stops through F16's reviewed stop. Its release-history ConfigMap was admitted but never created. Retiring the scope then refuses at planning:

```text
invalid-retirement: retention needs a selected scope replacement or retirement that removes an owned present … declaration
  [application:model-web/history/resource]
```

**Cause (source):** retirement (`decideRetirement`, `buildRetentionProofs`) requires a retention proof for every member the retiring scope removes, and a retention proof names a present object. A member that is confirmed absent has none, so no lifecycle decision can cover it.

**Operator decision (2026-10-05, in session nagare-f3):** fix now in MP-23.

**Implementation update (2026-10-05; claude-opus-5-5, sessions nagare-f3 and its continuation):**
- **Absence proofs.** A retirement or scope replacement now records each removed member that is `ConfirmedAbsent` and holds no data as an `AbsenceProof` (owner, accepted revision, absence evidence) instead of a retention proof (`buildAbsenceProofs`, `src/Nagare/Inventory/Plan/Changes.hs`). "Holds no data" means a `Stateless` member, or a durable member whose create never started in a stopped application review (`historyUnstartedCreates`, now also computed for retiring scopes in `loadInventoryPlanningHistory`).
- **Missing data refuses by name.** A removed durable member that is absent and was not a never-started create refuses as `durable-resource-missing` unless the review approves its collection. Retirement never silently drops data that once existed.
- **Review and validation.** The review document carries `absences` (optional field, schema version unchanged). `verifyReview` requires each proof to name the accepted owner revision, and refuses a member that is both absent and retained or retention-proved.
- **Admission.** `retentionCoverage` accepts a removed member with exactly one retention or absence proof, and only for a member that holds no data under accepted history. Admission re-observes absence-proved members with the retained ones and refuses (`retention-observation`) if any is present or unobserved.
- **Regressions** (each fails without its guard, per ADR 25):
  - the recovery model's retire scenario (fast tier): on the pre-fix source it fails with the `invalid-retirement` refusal above (1 violation); with the fix it passes;
  - `test/InventoryApplicationUpdateRecoverySpec.hs`, "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)": a durable volume deleted out of band refuses retirement as `durable-resource-missing`. Mutation `test/mutations/F58-absence-proof-holds-no-data.diff` (drop the no-data condition) makes it fail;
  - `test/InventoryApplicationUpdateRecoverySpec.hs`, "retirement drops a confirmed-absent stateless member only while it stays absent (F58)": an absent member that reappears after review is refused at admission, and the same review is admitted once it is absent again. Mutation `test/mutations/F58-admission-absence-recheck.diff` (skip the recheck) makes it fail, with the reappeared member dropped and the transaction converged.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F58-absence-proof-holds-no-data.diff` and `F58-admission-absence-recheck.diff` (existing records) each fail their focused regressions in "application update recovery".
- **Data safety (source review):** only `ConfirmedAbsent` members that are stateless or whose create never started (every journal event `Pending`) get an absence proof. Lost-acknowledgement creates cannot qualify, proofs are bound to the accepted revision, and nothing in retirement deletes an absent member.
- **Gap:** admission's own `holdsNoData` check (`Execute/Admission.hs`) has no regression; the recorded mutation reverts only the planning side.
- **Stays Verifying.** Needed: a regression in which a review carries an absence proof for a durable volume and admission refuses it, plus a mutation of the admission check that makes it fail.

**Implementation update, admission regression (2026-10-05; claude-opus-5-5; item 9 of nagare-84's review):** `test/InventoryApplicationUpdateRecoverySpec.hs`, "admission refuses an absence proof for a member that holds data (F58)". A saved retirement review is edited on disk, as an operator could edit it: the durable volume's retention proof becomes an absence proof, and the bundle is reloaded through `loadReviewBundle`, published and verified. With the volume absent, admission must refuse with `retention-coverage`, and accepted history must keep the scope. Mutation `test/mutations/F58-admission-holds-no-data.diff` (drop the no-data condition in `retentionCoverage`) makes it fail (see the README row).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Three F58 tests pass. Killed: `F58-absence-proof-holds-no-data`, `F58-admission-absence-recheck`, `F58-admission-holds-no-data`. This fills the admission gap named under "Stays Verifying". The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-07, nagare-verify; observed).** Reopened (Verifying). F83 shows that a retirement's absence proof always refuses through the CLI, so this fix, a retirement with absence proofs, has only been proved with a test registry that observes everything. It closes again when F83's CLI-path test for a stopped first deploy, then close and retire, passes, and when the final C2 confirms it.

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; with F83).** The CLI's execution registry now binds the members a retirement proves absent (`Status.loadAbsenceNative`), so this fix's admission recheck works through `inventory apply`. The recovery model's retirements now apply through the registry the command builds (`retirementRegistryFor`). Under `F83-absences-unbound-at-admission`, the fast tier fails F58's own class: an application or database whose first deploy stopped, closed and then retired, refused `retention-observation` at admission.

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed again. The F83 fix (`0d828d50`) binds a retirement's absence proofs for admission, and the recovery model now retires through a registry shaped like the CLI's. Natively, close-kept scopes retired with absence proofs through the CLI in C2. Evidence: [C2 evidence](../mp23-independent-results-2026-10-07/c2-acceptance-3ae20f8c/) (`retire-kept.log`).


## F59

**A standalone database whose StatefulSet is created but never becomes Ready has no exit** — P1 (a stuck state: every later plan on the context is refused); **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5) with no native run.** The new scenario "create a database, then ingest a scheduled receipt" reviews a standalone PostgreSQL database, compiled by `compileStandaloneDatabase`. Under `LandsUnready` on its fifth Kubernetes write, the StatefulSet create, the create lands and the pod never becomes Ready. This is what an unschedulable pod, an image pull failure or a crash loop looks like. The transaction then stops ambiguous, and every exit refuses:
- resume makes no progress;
- `stop-incomplete-application` answers "adapter did not prove the operator's requested action";
- `abandon-refused-operation` answers "resolve every uncertain operation before abandoning a refused one".

**Cause (source):** F16's reviewed stop never covered data services.
- The Kubernetes adapter's recovery (`src/Nagare/Inventory/Adapters/Kubernetes.hs`) answered `RecoveryAwaitingReadiness` for an unready create only of a Deployment, a Knative Service or a DomainMapping. An unready StatefulSet create was unresolved.
- The stop rule (`incompleteApplicationOnlyReview`, `src/Nagare/Inventory/Plan/History.hs`) admitted on its create path only an application's Knative Service or a preview DomainMapping. In a standalone scope it also required every other operation to be Completed. A database's later creates (its schedule, signing key and companions) are still never-started when its StatefulSet stalls.

**Operator decision (2026-10-05):** fix now in MP-23.

**Implementation update (2026-10-05; claude-opus-5-5):**
- The adapter answers `RecoveryAwaitingReadiness` for an unready created StatefulSet whose owner stamp and digest are the reviewed create's.
- The stop admits a standalone scope's stateless StatefulSet create. Never-started companions are admitted for it exactly as for an application. A data fence still refuses, as does any companion with recorded intent.
- The stop accepts nothing. The scope keeps its accepted revision without convergence, so a corrected review, or a retirement (F58 drops never-created members), can follow.
- The StatefulSet holds no data. The database's PVC is a separate durable member, and a later review never replans it as a fresh create unless its create never started (F55's filter).
- **Regression:** the recovery model's fast tier. It fails before the fix with the I1 stop above. Each guard has a recorded mutation (`test/mutations/F59-*.diff`).

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F59-statefulset-create-awaits-readiness.diff`, `F59-standalone-statefulset-stop.diff` and `F59-statefulset-pending-companions.diff` (existing records) each fail the recovery model with one I1 violation under `LandsUnready` on the database StatefulSet create. The stop itself is sound: the StatefulSet mounts the separately created, retained PVC by claim name, and the stop accepts nothing.
- **Gap A (inferred from source, model reproduction requested):** `loadUnstartedApplicationCreates` (`Plan/History.hs`) computes never-started creates only for `Application` scopes. After a database stop with `backup-signing-key` still `Pending`, both a corrected review and retirement refuse with `durable-resource-missing`. The operation order follows the operation-ID digest, so this depends on the database name. The store stays idle but the database scope cannot move, so the follow-up exit the fix promises is broken for those names.
- **Gap B (inferred):** a broker StatefulSet with topics under `LandsUnready` has no exit, because the create path requires every operation to use `KubernetesExecutor` and topics use `BrokerExecutor`.
- **Reopened as Partial.** Needed: a post-stop corrected-review or retire step in the database scenario, on a fixture whose signing-key create is unstarted at the stall (it should fail on HEAD); a broker scenario under `LandsUnready`; and fixes for both.

**Implementation update, gap A (2026-10-05; claude-opus-5-5):**
- **Reproduced on HEAD `ab3d5bdc` (observed).** The recovery model's new scenario "create a database, then retire it" runs under `LandsUnready` on the StatefulSet create, followed by the F59 stop. Retirement then refuses at planning with `durable-resource-missing` on `standalone:database-pg/pg/backup-signing-key`, the never-started create.
- **Fix.** `loadUnstartedApplicationCreates` (`Plan/History.hs`) also computes never-started creates for standalone scopes, so a stopped database's unstarted members retire as F58 absences.
- **Mutation.** `test/mutations/F59-standalone-unstarted-creates.diff`.
- **Not started:** gap B (brokers) is held by the operator's instruction of 2026-10-05.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed for gap A on source. Test: "a created StatefulSet that is not yet ready settles as landed (F59's deleted answer)". Killed: `F59-standalone-unstarted-creates`. Gap B, the broker, is a documented limit of release line (b) ("F59's broker gap"). The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F60

**One out-of-band replacement between a create and convergence is recorded as the accepted incarnation** — P2; **Closed**, operator decision 2026-10-05); owner EP-173.

**Found by the EP-173 recovery model (2026-10-05)** in the same database scenario. Its new I3 receipt clause plans scheduled-receipt ingestion the way `db backup-receipts` does. Under one `Replaced` fault at a Kubernetes observation between the StatefulSet's or PVC's create and the convergence observation, convergence records the replacement as the accepted incarnation. A receipt taken from the replacement then compiles for ingestion, and F49's guard passes because the record names the replacement.

**Ledger:** this is the F49 limit already on the retrospective's deferral ledger: incarnation recording is fail-open, and the record comes from a fresh observation at convergence, not from the execution receipt. It is listed in ADR 22 "Known limits". The model shows a single fault reaches it.

**Operator decision (2026-10-05):** keep it as a documented limit. The fix, binding established records from the create's own completion identity, remains the follow-up work ADR 22 names. The recovery model names it as an explicit tolerance: the I3 receipt clause exempts only a replacement that the head itself records as the accepted incarnation. A receipt from a replacement the head does not record must still refuse, and the `F49-ingestion-ignores-incarnation` mutation proves the model checks that.

**Operator decision, superseding the deferral (2026-10-05, in session nagare-84):** "ok fix it in MP-23 unless it's going to take hours". The earlier deferral was recommended without the deferral ledger that ADR 25 decision 7 requires. With the ledger shown, the operator un-deferred it.
- **Fix:** bind each established incarnation from the create's own completion identity, the UID the API server returned for the reviewed create. Refuse convergence, or stop with a reviewed exit, when the live object observed at convergence differs. Do not record a fresh observation.
- **Coverage:** remove the recovery model's F60 tolerance from the I3 receipt clause, so a `Replaced` fault between create and convergence must no longer launder the replacement. Add a mutation record that restores observation-based recording.
- **Time box:** if the implementer estimates the fix at more than about two hours, report the estimate to the operator before going further.

**Implementer estimate (2026-10-05, nagare): 4–6 hours, above the operator's two-hour condition, so not implemented.** No layer captures the UID the API server returns for a reviewed create today, and verification re-observes, so a replacement before verification is already invisible. Binding the record from the create's own identity needs five changes:
1. `KubernetesRuntime` parses the UID from `kubectl create -o json` and from the apply and replace paths.
2. `AdapterExecution` carries it, which is a type change across adapters.
3. The journal records it in the `Completed` event, a schema change that needs compatibility with journals already written.
4. Verification and recovery compare it, with a reviewed exit for a create whose target was replaced (a sibling of F56).
5. `Incarnations` binds from the journal and refuses a mismatch at convergence.

That design is also what this finding's follow-up work needs. The model's F60 tolerance stays until it lands. **Status:** deferred under the operator's stated condition ("fix it in MP-23 unless it's going to take hours"). It returns to Open if the operator schedules the work.

**Operator decision (2026-10-05): "approve all six, go with release line b".** The exhaustive review's D2 schedules this fix as ADR 27, together with the checked identity accessor and a reviewed rebind. It is step 2 of MP-23's release-line plan.

**Implementation update (2026-10-05, EP-176 M1; claude-opus-5-5):**
- **Fix.** Every Kubernetes write now runs with `-o json`, and the UID the API server returns is journalled on the event that ends the operation (`JournalEvent.physical`). Convergence binds that identity (`Execute/Incarnations.hs`) instead of observing members afterwards. A replacement made between the create and convergence therefore stays a replacement: status reports it as `replaced-incarnation`, and ingestion refuses its receipts.
- **Coverage.** The recovery model's F60 tolerance in the I3 receipt clause is removed, and the fast tier passes with it gone. Focused regression: "convergence binds the object the create returned, not one that replaced it before convergence (F60)" in `InventoryIncarnationSpec`.
- **Mutation records.**
  - `ADR27-F60-binds-from-observation` (observation-based binding restored) fails that test, and the fast tier reports 4 violations.
  - `ADR27-driver-drops-returned-identity` fails as well.
  - `ADR27-runtime-ignores-returned-uid` fails as well.
- **Remaining.** A create whose write response was lost has no returned identity, so its member is `unrecorded`. EP-176 M2's checked accessor refuses such a member where data is at stake. Status is the verifier's to set.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "convergence binds the object the create returned, not one that replaced it before convergence (F60)". Killed: `ADR27-F60-binds-from-observation`, `ADR27-driver-drops-returned-identity`, `ADR27-runtime-ignores-returned-uid`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F61

**A reviewed PostgreSQL rename whose copy Job fails partway has no exit** — P1; **Closed**; owner EP-173 / EP-153.

**Found by independent review (2026-10-05, nagare-84; inferred from source, model reproduction requested).**
- The rename recovery model's `runJob` is atomic: a fault either copies everything or writes nothing. A real copy Job that dies mid-copy (full disk, eviction, a lost node; `backoffLimit: 0`) leaves the destination non-empty and different from the source.
- Every retry then fails "destination volume is not empty and differs from the source" (`Migration/PostgresRename.hs`, the transfer script).
- Recovery for the transfer is unconditionally `RecoverySafeToRetry` (`Adapters/KubernetesMigration.hs`), and no reviewed action clears the destination volume.
- Data is safe: the source is fenced and mounted read-only, and verification can never pass. But the transaction has no exit.
- nagare's I4 relaxation (EP-173 Decision Log) is sound for the three faults modelled so far, refused, lost acknowledgement and interrupted, and not beyond them.

**Required:**
- a `PartialCopy` fault in the rename world (a strict prefix written, then a failed Job, with and without a termination message), which should fail I1 on HEAD;
- a reviewed exit for a partially written destination, for example abandoning the partial transfer after proving the destination volume has no other users, then recreating or wiping it before a retry;
- a mutation record.

**Implementation update (2026-10-05; claude-opus-5-5).** The fix was completed before the operator's hold. It is committed separately, so it can be reverted on its own if the structural proposal replaces it.
- **Reproduced on HEAD `ab3d5bdc` (observed).** The rename recovery model has a new `PartialCopy` fault: the first copy into an empty destination writes partial data and fails. The model reports "I1: the rename stopped with no supported exit; open operations [op-44817955d08dd1e54c34d829]".
- **Fix.** The transfer script (`Migration/PostgresRename.hs`) marks the destination `.nagare-transfer-incomplete` before copying and removes the mark only after the whole copy succeeds. A copy that finds the mark clears the partial data and copies again. A non-empty destination without the mark still refuses.
- **Why the clearing is safe (inferred from the review's stage order):**
  - the destination is created by this transaction after planning proved it absent;
  - only Nagare's copy writes the mark;
  - the new writer is ordered after the transfer stage.
- **Regressions:**
  - the rename recovery model, with `PartialCopy` and the world modelling the mark;
  - `test/InventoryTransferScriptSpec.hs`, which runs the real script under `bash` on temporary volumes: an empty destination is copied, a marked partial one is redone, an unmarked differing one is refused, and verification refuses a destination that is still marked.
- **Mutation.** `test/mutations/F61-transfer-redoes-incomplete-copy.diff`.

**Implementation update, reviewer's conditions (2026-10-05; claude-opus-5-5; EP-175 M2):** the
mark now carries the transaction and operation (`TRANSFER_MARK`, which `runTransfer` sets from the
active transaction). A redo requires that exact mark. The transfer preflight refuses while any pod
other than this migration's transfer Jobs mounts the destination claim. The destination's identity
is still its stamped, reviewed claim name; its recorded UID arrives with EP-176. ADR 26 §4 now
describes this mark-bound redo.
- **Tests:** `test/InventoryTransferScriptSpec.hs` adds "a copy refuses a destination another
  migration's copy left marked". `test/InventoryPostgresRenameSpec.hs` adds "a transfer refuses
  while another pod mounts the destination (F61)".
- **Mutations:** `F61-transfer-mark-ignores-owner` and `F61-transfer-ignores-mounts`, plus the
  regenerated `F61-transfer-redoes-incomplete-copy`.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. The rename transfer tests pass, including "a transfer refuses while another pod mounts the destination (F61)". Killed: `F61-transfer-ignores-mounts`, `F61-transfer-mark-ignores-owner`, `F61-transfer-redoes-incomplete-copy`. MP-23's separate item, confirming the relaxed I4, stays open. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F63

**A Deployment or database StatefulSet update that lands but never becomes Ready has no exit** — P1; **Closed**; owner EP-153 / EP-173.

**Found by independent review of F54 (2026-10-05, nagare-84; inferred from source, model reproduction requested).**
- F54's landed-update stop is Knative-only: `landedUpdate` and `confirmLandedUnready` in `Adapters/Kubernetes.hs` and `KubernetesConfiguration.hs`.
- An `UpdateResource` on a worker Deployment or a database StatefulSet that lands unready answers `RecoveryUnresolved`. That is the same wedge F54 fixed for Services.
- The model has no update scenario for those kinds.

**Required:**
- a "worker update lands unready" scenario and a "database update lands unready" scenario under `LandsUnready`, which should fail I1 on HEAD;
- a reviewed exit for each;
- mutation records.

**Implementation update, database StatefulSets (2026-10-05; claude-opus-5-5):**
- **Reproduced on HEAD `ab3d5bdc` (observed).** The model's new scenario "create a database, update its resources, then update it again" fails two ways:
  - I1 under `LandsUnready` on the StatefulSet update, and on its corrected update;
  - after an F59 stop, the corrected update is refused at prepare: "Kubernetes object is present but its required condition is not ready".
- **Fix:**
  - the adapter proves a landed, unready StatefulSet update with `confirmLandedUnready`, judging readiness by `readyReplicas` against `spec.replicas`;
  - the stop admits that update in a standalone scope;
  - prepare lets a corrective review update an owned, unready StatefulSet.
- **Mutations.** `test/mutations/F63-*.diff`, four records.
- **Worker Deployments are not fixed.** The fix was written and is held, uncommitted, in [`mp23-held-work/`](../mp23-held-work/README.md). The fault-free worker scenario fails I1 on HEAD (observed). With the held patch the fault sweep still shows nine worker wedges.
- **Worker Deployments, fixed (2026-10-06, EP-180 M1; observed).** The held patch predates ADR 26 and was not used.
  - What failed: the generated scenario `kind ("apps","deployment"): update` under `(MutateCall 3, LandsUnready)`. The Deployment's create landed unready and was closed. The corrected review was then refused at planning ("required condition is not ready"), reported as "I1: planning refused".
  - The fix: `validateBefore` (`Adapters/Kubernetes.hs`) admits an update of an owned, unready Deployment, as it does for a StatefulSet. A Deployment rollout replaces stuck pods (RES-4 §2), so a correction takes effect.
  - The pinned test "a corrective update of an unready Deployment plans and closes" now exits `[[Close]]`.
  - Mutation: `test/mutations/F63-deployment-correction-refused.diff`.
  - A landed-unready proof for Deployments in `recover` was not added. Close already classes the exactly landed, unready update as `Landed` through settlement.
  - The StatefulSet half needs RES-4's G3 (EP-181): a StatefulSet correction does not replace a stuck pod.
- **World fidelity, for review (inferred):** the world now restricts persistent status churn to Knative Services. A settled StatefulSet's status changes only when its pods change. Without this restriction, the StatefulSet update gave 75 I7 violations (each needing `abandon-refused-operation`).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Tests: "a corrective update of an unready object reaches the API server (F63, M1)" and "a corrective update of an unready Deployment plans and closes (EP-180, F63's worker half)". Killed: `F63-correct-unready-statefulset`, `F63-deployment-correction-refused`, `F72-unready-update-unsupported`, `EP181-model-correction-never-replaced`. EP-181 delivered the StatefulSet half's G3. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F64

**An intended update whose target is deleted outside review, and not recreated, has no exit** — P1; **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5)**, with a new world fault `Deleted`: an owned object deleted out of band at an observation boundary, never recreated. This is item 5 of nagare-84's review. Reproduced on HEAD `ab3d5bdc` (observed): I1 in "create then good update", in the bad-update scenarios and in the database update scenario. The target was the release-history ConfigMap, the Service or the database StatefulSet. Recovery reported `RecoveryUnresolved`, and every exit refused.

**Fix.** An intended update whose owned target is gone answers `RecoverySafeToRetry` (`Adapters/Kubernetes.hs`). The retry's preflight refuses the absent object before any effect, the driver journals the no-effect refusal (F57), and `abandon-refused-operation` ends the transaction. A corrected review then recreates the stateless member.

A dedicated stop-only decision for Services and StatefulSets was written first. Its mutation survived, because the retry-then-abandon exit already covers those kinds. So it was removed to keep one rule.

**Mutation.** `test/mutations/F64-deleted-update-target-retry.diff`.

**Model changes made alongside, for review (each a relaxation; observed reasons):**
- **I4** counts writes per transaction, and the deleted object's write no longer counts. A later review reuses deterministic operation IDs, and rewriting an object deleted out of band is not a repeated effect.
- **I2** skips members deleted out of band after verification.
- **A planning refusal** of `durable-resource-missing` that names only members deleted out of band ends the scenario as expected. Data loss needs reviewed recovery or collection.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "an owned update target deleted outside review settles as target gone (F64's deleted answer)". The fast tier passes with the `Deleted` fault at every placement. The old record is retired, and no rule-level record names F64. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F65

**The create-path stop refuses a review that recreates a deleted Service alongside its release-history update** — P1; **Closed**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5)** under `Deleted`, observed on the F64-repaired tree. The Service is deleted out of band, so the next review plans `CreateResource` for it and `UpdateResource` for its release history. If the new revision is unready, F16's create-path stop refuses, because that path required every operation to be a create. The result is I1 in the bad-update scenarios.

**Fix.** F55's never-started-companion rule (`neverStartedCompanion`, `Plan/History.hs`) is shared by the update path and the create path. A never-started verify, or a never-started create or update of a stateless ConfigMap ordered after the stopped Service, is admitted on both paths.

**Mutation.** `test/mutations/F65-create-stop-companions.diff`.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source, weakly. ADR 26 deleted the companion rule. The case is covered only by the fast tier and the `ADR26-close-*` records, because the focused test EP-175 promised does not exist. That is proposed for the deferral ledger. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F66

**A create that finds an object not stamped as its own at its address settles unknown, so only an attested close can end it** — P1; **Closed**; owners EP-153 / EP-177.

**Found by the EP-177 recovery model's deep tier (2026-10-06, claude-opus-5-5).** The "create" scenario was rerun alone as deep shard 0/52 at `a4d84543` (log `deep-create-shard0of52-a4d84543.log`, observed). There, a `ForeignObject` fault puts an unowned object at a create's address. A second fault then stops the transaction:
- a store fault (`PutRefused`, `PutLandedUnacknowledged` or `GetFailedOnce`);
- a crash at a store write (`CrashBeforeStorePut` or `CrashAfterStorePut`);
- or `ClaimLost`.

`Deleted` followed by `ForeignObject` reaches the same state after the create has landed. The Kubernetes adapter settled the create as `SettledUnknown "Kubernetes object changed since review; replan before mutation"`, so close refused with `unknown-operation`. The only exit left was the attested close, which ADR 26 §5 reserves for outcomes an adapter cannot prove. This one cause accounted for 36 of the scenario's 67 violations: 16 I8 and 20 I1. The other 31 were harness gaps, recorded in EP-177's Surprises.

**Why the class is provable.**
- Nagare creates a Kubernetes object only on an empty address (`kubectl create`).
- Every object a review writes carries the reserved `nagare.dev/context-id` and `nagare.dev/resource-id` stamp of its member.
- So an object at the address without this member's stamp (unstamped, or stamped for another member) proves the create's write is not live there. Either the write never landed, or it landed and was replaced outside review.

The class is not `NoEffect`. The absent before-state has changed, and in the `Deleted`-then-`ForeignObject` schedules the create had landed. It is ADR 26's `TargetGone` ("replaced … outside review"), the class ADR 27 §1 also gives a live object that differs from the record. The found UID is evidence only and is never bound.

**Whether the foreign object should block close (checked against ADR 26 §2 and ADR 27 §1–3; inferred).** It should not:
- Close writes nothing, binds no incarnation and converges nothing.
- `TargetGone` is not a no-effect class, so the scope keeps its desired revision rather than reverting.
- The next plan observes the unowned object at a planned address and refuses, as it already does for a `ForeignObject` fault before any transaction. That refusal is where the operator resolves the foreign object.
- ADR 27's rebind does not apply, because it records a replacement that carries the member's own stamp.

**Fix.** `settleMutation` (`Adapters/Kubernetes.hs`) now handles a create whose reviewed before-state was absent. If its address holds an object not stamped as this member, the create settles as `SettledTargetGone` with that object's UID. An object with this member's own stamp but other content stays `Unknown`, because it may be the create's own write edited out of band.

**Tests.**
- "a create that finds an object not stamped as its own settles as target gone (F66)", in `InventorySettleSpec`.
- The recovery model's "create-scenario fault pairs that had no exit now have one (EP-177, F66)", which closes three of the logged schedules, one of them after `ClaimLost`.

**Mutation.** `test/mutations/F66-create-over-foreign-object-settles-unknown.diff`.

**Rehearsal (observed, 2026-10-06).** Shard 0/52 ("create") was rerun with this fix and the three EP-177 harness fixes. It reported `recovery-model: [1/1] create: done in 722s, 0 violation(s)`, down from 67.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "a create that finds an object not stamped as its own settles as target gone (F66)". Killed: `F66-create-over-foreign-object-settles-unknown`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F67

**An update refused after a status write, whose refusal's journal event is lost, settles unknown** — P1; **Closed**; owners EP-153 / EP-180.

**Found by the EP-177 five-scenario deep reruns (2026-10-06, claude-opus-5-5; observed).**
- **How it happens.** A controller's status write moves an object's resourceVersion just before Nagare's update (`StatusChurn`). The update is conditional on the reviewed resourceVersion, so it is refused with no effect. A store fault then loses that refusal's journal event.
- **What it led to.** Recovery compared the before-state exactly, resourceVersion included, so settlement was `Unknown` and only the attested close remained.
- **Where it was seen.** The database StatefulSet update, at `(Mutate 10, StatusChurn) + (StorePut 72, PutRefused)` and `(11, 84)`, and the generated Deployment update at `(5, 44)`, both in release line (b). These ordinals are from when the world churned status only on kinds with a status subresource (EP-177).

**First design, dropped.** A configuration-digest mutation version 4 recorded the stable configuration at review. It was replaced before landing by RES-4 §5.1's stamp proof.
- It needed an extra observation at prepare, which shifted the model's ordinals and made a pin vacuous.
- It could not settle reviews made before it.
- It became Unknown on any controller metadata write.

**Fix (EP-180 M3).**
- Nagare writes its `nagare.dev/spec-digest` stamp in the same atomic write as the spec it describes (RES-4 U3). On the reviewed UID, the stamp therefore says which of Nagare's writes is live, whatever status or controller metadata did meanwhile.
- Every observation now returns the stamp from the same read (`kubernetesObserveStamped`).
- Prepare records `beforeStamp`, the stamp the before-state carried, as a required field of every update mutation.
- After the exact before-state row, `settleMutation` (`Adapters/KubernetesProof.hs`) classes an update observed on the reviewed UID, with this member's ownership:
  - a live stamp equal to `beforeStamp` → `NoEffect`;
  - a live stamp equal to the reviewed digest → `Landed`;
  - anything else falls to the existing rows (F68's target gone, landed by digest, unknown).
- A drift repair, whose before stamp already was the reviewed digest, proves nothing by stamp, and the fields-match rows decide.
- A stamp rolled back to the before digest after Nagare's write reads as `NoEffect`. ADR 26's no effect is "a proved, unchanged before-state", which holds now. Close then reverts the scope only if nothing else in it took effect, to a base that matches what is live.

**Compatibility.** None, by operator ruling: Nagare is not yet used anywhere. An update mutation without `beforeStamp` does not decode, and disposable stores are rebuilt.

**Tests.** "an update settles by the stamp on the reviewed object, whatever its resourceVersion (F67)", in `InventorySettleSpec`. It covers the before stamp, the reviewed stamp, another stamp, no stamp, a rollback, a drift repair, an unstamped replacement, and an update without `beforeStamp` failing to decode. It failed before the row was added.

**Model.** The world reads no stamps until EP-182 renders realistic objects. The three model schedules above become EP-182's acceptance test.

**Mutation.** `test/mutations/F67-settle-ignores-stamp.diff` disables the stamp row, and the test fails.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Killed: `F67-settle-ignores-stamp`, `G6-repair-proves-by-stamp`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F68

**An update whose target is deleted and replaced by an object not stamped as its own settles unknown, so only an attested close can end it** — P1; **Closed**; owners EP-153 / EP-177.

**Found by the EP-177 five-scenario deep reruns on the remote builder (2026-10-06, claude-opus-5-5)**, classified locally (observed). In "create then good update" under `[(Observe 17, Deleted), (Observe 18, ForeignObject)]`, the Knative Service that the v2 update targets is deleted outside review. An object without this member's stamp then appears at its address. Settlement answered `SettledUnknown "Knative Service configuration or ownership changed since review"`, so close refused with `unknown-operation`.

**Why the class is provable.** It is F66's rule for updates. An update is conditional on the reviewed UID and stamps what it writes as this member's. An object at the address with another UID and without this member's stamp therefore proves the update's write is not live there. The write either never landed, or landed on the reviewed object, which is gone. That is ADR 26's `TargetGone` ("the reviewed object was replaced or deleted outside review"). The found UID is evidence only and is never bound (ADR 27 §1).

**Fix.** `settleMutation` (`Adapters/KubernetesProof.hs`) generalises F66's predicate. An object not stamped as this member at the address of a create over an absent before-state, or of an update whose reviewed UID differs from the found one, settles as `SettledTargetGone` with the found UID. Two cases keep their existing classes:
- an object with another UID that carries this member's stamp stays the F56 replacement path;
- an object with the reviewed UID is never gone, whatever its stamp now.

**Tests.**
- "an update whose target is replaced by an object not stamped as its own settles as target gone (F68)", in `InventorySettleSpec`.
- The schedule above, in the recovery model's "create-scenario fault pairs that had no exit now have one (EP-177, F66)".

**Mutation.** `test/mutations/F68-update-over-foreign-object-settles-unknown.diff`. F66's record is regenerated for the shared predicate.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "an update whose target is replaced by an object not stamped as its own settles as target gone (F68)". Killed: `F68-update-over-foreign-object-settles-unknown`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F69

**A Knative Service or DomainMapping reads ready from its previous generation's Ready=True before the controller has seen the new spec** — P1; **Closed**; owners EP-153 / EP-180.

**Found by review of the readiness predicates (2026-10-06, claude-opus-5-5; inferred), and validated by RES-4 experiment E4 on k3s 1.34 with Knative 1.22 (observed).** After a spec write, Knative keeps the previous generation's `Ready=True` until its controller observes the new spec (`observedGeneration < generation`). It then reports `Ready=Unknown` at the new generation before it becomes `True`.

`knativeReady` (`Adapters/KubernetesReadiness.hs`, previously `Adapters/KubernetesRuntime.hs`) checked only the `Ready` condition. So right after an update, the old revision's readiness satisfied the readiness wait, and a bad image could be recorded as converged. It is used for both the Knative Service and the DomainMapping. This is a wrong success, but in a narrow window: an interrupt or verify within seconds of the write, or a lagging controller.

**Fix.** Ready requires `status.observedGeneration == metadata.generation` as well as `Ready=True` (RES-4 §2, U9). That is the same generation discipline `deploymentAvailable` and `statefulSetReady` already apply.

**Tests.** "a Knative Service or DomainMapping is ready only at the observed generation (F69)", in `InventoryKubernetesReadinessSpec`. The DomainMapping-conflict fixture in `InventoryKubernetesSpec` lacked both generation fields, which every real object carries, and was completed.

**Model.** The model test comes with EP-182's `ControllerLag` fault, once the world's readiness runs through the production parser.

**Documented limit.** `certificateReady` (cert-manager's `Certificate` and `ClusterIssuer`) has the same shape. cert-manager is a platform kind outside release line (b), so it is left as is.

**Mutation.** `test/mutations/F69-knative-ready-ignores-generation.diff` drops the generation check, and the test fails.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "a Knative Service or DomainMapping is ready only at the observed generation (F69)". Killed: `F69-knative-ready-ignores-generation`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F70

**A worker Deployment whose update never becomes available reads as ready, so a broken rollout is recorded as complete** — P1; **Closed**; owners EP-153 / EP-180.

**Found by the RES-4 validation of Kubernetes semantics (2026-10-06, nagare-first-principle, experiment E5 on k3s 1.34; observed).** During a bad-image or crash-looping update of a one-replica Deployment, the old ReplicaSet keeps `Available=True`, because maxUnavailable rounds to 0. The controller has also observed the new generation. That stays true after `Progressing=False/ProgressDeadlineExceeded`.

`deploymentAvailable` (`Adapters/KubernetesReadiness.hs`, previously `Adapters/KubernetesRuntime.hs`) treated `Available=True ∧ observedGeneration == generation` as ready. So such a Deployment observed as `KubernetesPresent`. `recover` then returned `RecoveryProvedComplete` for the broken update, and plans saw the member converged. This is a wrong success: a broken state recorded as converged.

**Fix.** Readiness is the rule `kubectl rollout status` applies (RES-4 §2, U9): `observedGeneration == generation ∧ updatedReplicas == spec.replicas ∧ status.replicas == updatedReplicas ∧ availableReplicas == updatedReplicas`, with `spec.replicas` defaulting to 1. `ProgressDeadlineExceeded` is not terminal, so the Deployment stays not ready, and the update is landed.

**Tests.** "a Deployment is ready only when its rollout is complete, as kubectl rollout status judges it (F70)", in the new `InventoryKubernetesReadinessSpec`. It covers mid-rollout, past the progress deadline, rolled out, one generation behind, and an unavailable updated replica. The earlier assertions in `InventoryKubernetesSpec` that read `Available=True` as ready moved there and were corrected.

**Model.** The recovery model's world decides readiness from its own state, not through this predicate, so it cannot see F70. EP-182 routes the world's readiness through the production parser.

**Mutation.** `test/mutations/F70-deployment-ready-ignores-rollout.diff` reduces the rule to the observed generation, and the test fails.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "a Deployment is ready only when its rollout is complete, as kubectl rollout status judges it (F70)". Killed: `F70-deployment-ready-ignores-rollout`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F71

**A Kubernetes write the API server definitively refused (409, 422, 404 and the other 4xx) is reported ambiguous** — P2; **Closed**; owners EP-153 / EP-180.

**Found by RES-4's gap analysis (G4; 2026-10-06, nagare-first-principle; experiments E1, E3, E8 and E13 on k3s 1.34; observed).**
- **What happened.** The Kubernetes runtime mapped every non-zero `kubectl` exit to `AdapterEffectAmbiguous`, including the API server's definitive refusals. RES-4 U4: every 4xx refusal left the object unchanged.
- **The consequence.** A refused write needed a re-observation and a settlement it did not need, and with G6's status churn it could end Unknown.
- **The model never saw it.** The world returns `KnownNoEffect` for the same refusals, so the model never exercised the real path.

**Fix.** `kubectlRefusal` (`Adapters/KubernetesProof.hs`) maps the server's definitive answers to `KnownNoEffect`. Those answers are `Error from server (Conflict|Invalid|AlreadyExists|NotFound|Forbidden|BadRequest)`, `error: Operation cannot be fulfilled`, and a server-side-apply field conflict (`error: Apply failed with`, a 409; E13). Transport failures, timeouts and 5xx (`InternalError`, `ServiceUnavailable`, `Timeout`) stay ambiguous, because only they can hide a committed write. The runtime's failed-write branch applies it.

**Tests.**
- "a write the API server refused with a 4xx answer had no effect; only a missing answer is ambiguous (G4)", in `InventorySettleSpec`. It failed first against a stub.
- "an update the API server refuses with a 4xx is a known no effect; a lost connection stays ambiguous (G4)", in `InventoryKubernetesFieldTakeoverSpec`, through the fake kubectl interpreter. The wiring existed before this test, so its failing side is shown by the wiring record below.

**Mutations.** `test/mutations/G4-kubectl-refusal-ignored.diff` makes the classifier answer nothing, and both tests fail. `test/mutations/G4-runtime-refusal-ambiguous.diff` drops the runtime branch, and the wiring test fails.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Test: "a write the API server refused with a 4xx answer had no effect; only a missing answer is ambiguous (G4)". Killed: `G4-kubectl-refusal-ignored`, `G4-runtime-refusal-ambiguous`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F72

**The Kubernetes transport refuses a corrective update of an unready StatefulSet or Deployment as an unsupported precondition** — P1; **Closed**; owners EP-153 / EP-180.

**Found while building EP-180 M5 (2026-10-06, claude-opus-5-5); proved by a transport test through the fake kubectl interpreter (observed).**
- **The gap.** A corrective update of an unready object carries a `KubernetesNotReady` precondition. F63 admits one for StatefulSets, and EP-180 M1 for Deployments. The runtime's write path accepted only `KubernetesPresent` for an update, converting `NotReady` only for a Knative Service. So in production the correction was refused before reaching the API server, with "Kubernetes transport received an unsupported action or precondition".
- **Why the model missed it.** The recovery model's world implements its own writes rather than running the runtime's transport, so it passed F63's correction scenarios.

**Fix.** An update with a `NotReady` precondition is written like any other. G6's guard is its UID, its before-state stamp and its field owners, read live, so readiness has no part in the precondition. The transport still waits for readiness after the write.

**Tests.** "a corrective update of an unready object reaches the API server (F63, M1)", in `InventoryKubernetesFieldTakeoverSpec`. It failed with exactly that refusal.

**Mutation.** `test/mutations/F72-unready-update-unsupported.diff`.

**Model.** EP-182's world runs behind the production kubectl interpreter, so the model will exercise this path.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Killed: `F72-unready-update-unsupported`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F73

**A Knative Service update that another write left unready is awaited as ours and settles as Landed** — P1; **Closed**; owners EP-180.

**Found before EP-180 M5b (2026-10-06, claude-opus-5-5); proved by an adapter test on the version-1 adapter (observed).**
- **The gap.** Recovery of a version-1 or version-3 update to a Knative Service returned `RecoveryAwaitingReadiness` for any owned, unready object on the reviewed UID, whatever its digest. Settle maps that decision to `SettledLanded`. So if another write of this member's left the object unready, this update was claimed landed when its write was not live.
- **Exposure.** Production Knative updates were version 2, which the arm excludes, so only a reviewed field takeover (version 3) reached it. M5b deletes version 2 and makes every Knative update version 1, so it would have become the default path. Version 2 was hiding this defect.

**Fix.** The arm also requires the reviewed digest. RES-4 U3: the stamp is written in the same atomic write as the spec, and the adapter reports the reviewed digest only while the stamp and the desired fields both match. That holds exactly while this update is live, through any status churn.

**Tests.** "a Knative Service update awaits readiness only while its own write is live (F73)", in `InventoryKnativeServiceUpdateSpec` (named `InventoryKubernetesConfigurationSpec` until M5b). It failed with `RecoveryAwaitingReadiness`.

**Mutation.** `test/mutations/F73-awaiting-readiness-ignores-digest.diff`.

**Model.** The recovery model's world observed Knative updates through the stable version-2 observation, so it never reached this arm. After M5b it does.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Its named test passes. Killed: `F73-awaiting-readiness-ignores-digest`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F74

**A Kubernetes object being deleted is read as present** — P1; **Closed**; owners EP-180.

**Found by RES-4's gap analysis (G5; 2026-10-06, nagare-first-principle; experiments E7 and E12); fixed in EP-180 M6 (claude-opus-5-5).**
- **The gap.** A DELETE that finalizers hold (RES-4 U6) leaves the object in place with its UID, a new resourceVersion and a deletion timestamp. Examples are a PVC mounted by a pod, an Orphan-deleted Knative Service and a Namespace. The runtime parser ignored the timestamp, so the object was Present.
- **Consequences.**
  - Verify and convergence could accept a member that is being deleted (wrong success).
  - A retire whose DELETE was accepted settled Unknown instead of Landed.
  - A create or update whose target was being deleted outside review could be settled by its stamp, as if it were the live target.

**Fix.**
- The parser classifies a set `metadata.deletionTimestamp` as the new state `KubernetesTerminating uid resourceVersion owner digest`. It is a constructor, so every consumer must decide what it means; EP-181 uses it for pods.
- Planning observes the object as unavailable ("being deleted"), so a plan waits until it is gone.
- Settlement follows RES-4 §3. A create or update whose object is terminating is TargetGone, whatever its stamp says. A retire whose reviewed object is terminating is Landed.
- The write guard and completion proof never accept a terminating object.
- Every consumer outside the adapter matches only Present, so a terminating object falls to their existing refusals.

**Tests.** `InventoryKubernetesTerminatingSpec` ("terminating Kubernetes objects (G5)").

**Mutation.** `test/mutations/G5-parser-ignores-deletion.diff`, `G5-settle-ignores-terminating.diff`, `G5-planning-reads-terminating-present.diff`.

**Model.** The recovery model's world has no finalizers. EP-182's world renders deletion timestamps and finalizers, and the production parser classifies them.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. The `InventoryKubernetesTerminatingSpec` tests pass. Killed: `G5-parser-ignores-deletion`, `G5-settle-ignores-terminating`, `G5-planning-reads-terminating-present`, `G5-retire-deletes-terminating`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F75

**A non-canonical resource quantity drifts forever** — P1; **Closed**; owners EP-180.

**Found by RES-4's gap analysis (G7; 2026-10-06, nagare-first-principle; experiments E11 and E15); fixed in EP-180 M7 (claude-opus-5-5).**
- **The gap.** The API server stores a resource list's quantities in canonical form: `1024Mi` becomes `1Gi`, `1000m` becomes `1`, `1.5` becomes `1500m`. `desiredFieldsMatch` normalised CPU only, and `mkQuantity` kept the text the user wrote. A declared `1024Mi` of memory or storage therefore never matched what the server stored. The update never verified, and the landed proof could not match: a wedge on every deploy.
- **Evidence corrected the source reading.** Rules taken from apimachinery's source alone got two of E15's rows wrong. On admission a resource list is rounded up to milli (`0.1m` is stored as `1m`), and text the parser keeps as written stays (`1500e0`).

**Fix.**
- `Nagare.Dsl.Quantity.canonicalQuantity` (nagare-dsl) holds the rule in one place. It cites `k8s.io/apimachinery` v0.32.3 `pkg/api/resource` (`ParseQuantity`'s kept text, `RoundUp`, `CanonicalizeBytes`) and E15's recorded output (`docs/audits/k8s-semantics-2026-10-06/experiments/e15.out`).
- `mkQuantity` emits the canonical form.
- `desiredFieldsMatch` compares every `resources.{limits,requests}.*` and `spec.hard.*` value in it, replacing the CPU-only millicore rule. Every other string keeps exact equality.

**Tests.** `QuantitySpec` (nagare-dsl): every E11 and E15 row, plus rules E15 did not record. `InventoryKubernetesFieldsSpec`: container memory and CPU, PVC storage and ResourceQuota hard limits match across spellings; a different quantity and ConfigMap data do not.

**Mutation.** `G7-resource-quantities-compare-exactly`, `G7-dsl-emits-spelling-as-written`, `G7-no-milli-rounding`, `G7-written-text-not-kept`.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. The `QuantitySpec` tests (`nagare-dsl`, 466 passed) and the field tests pass. Killed: `G7-resource-quantities-compare-exactly`, `G7-dsl-emits-spelling-as-written`, `G7-no-milli-rounding`, `G7-written-text-not-kept`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F76

**The accepted-incarnation tests stopped running, and twelve mutation records passed vacuously** — P1; **Closed**; owners EP-180 (M8) / EP-177.

**Found while building EP-180 M8's record manifest (2026-10-06, claude-opus-5-5); proved by `--list-tests` (observed).**
- **The defect.** nagare's EP-177 M1 commit (`cb076214`, "a kind table with a totality test against the adapter", 2026-10-05) replaced the line `, inventoryIncarnationTests` in `test/Nagare/Test/Suite.hs`'s test list with `, inventoryKindTotalityTests`, where it should have added the new line beside it. The import stayed, and an unused import is only a warning, so the "accepted incarnations (F49)" group stopped running and nothing noticed.
- **Impact.** Ten tests were dark for about a day: F49, F60, ADR 27 N3, N6, N7 and N21, the §3 rebind, the returned identity and the ingestion source. Twelve mutation records name them (ADR27-F60, -N3, -N5, -N6, -N7, -N21, -accessor-reads-unrecorded-as-match, -driver-drops-returned-identity, -runtime-ignores-returned-uid and the three rebind records), so those records passed vacuously.
- **Found by.** `records.json`'s pattern for each of the twelve selected no test.

**Fix.**
- The list entry is restored. All ten tests pass, so nothing regressed while they were dark.
- Every suite's top-level list (`nagarectl`'s `Suite.hs`, and `nagare-dsl`'s and `nagare-harness`'s `Spec.hs`) is compiled with `-Werror=unused-imports`. A group that is imported but missing from the list no longer compiles.
- The fast gate's `mutation-patterns` step fails when any record's pattern selects no test of its built suite.

**Tests.** The ten restored tests. `mutations patterns` reports a pattern that selects nothing, and `mutations check` reports a record missing from the manifest; both were tried against a corrupted manifest.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed. The incarnation group runs in the candidate's suite, and the gate's `mutation-patterns` step passes, so every record selects a test. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F79

**Close drops a never-started member whose absence it cannot read, leaving it accepted with no exit** — P1; **Closed**; owners MP-23 (step 3d).

**Found by the step-3d deep run (session nagare, `341b01bc`); reproduced by a recovery-model pin and a close unit test (observed).**
- **The defect.** `neverStartedAbsent` in `Execute/Close.hs` admitted a never-started or refused create to the never-started set only when observed `ConfirmedAbsent`. A failed read, a missing adapter or `ObservationUnavailable` silently dropped the member, and close finalised anyway.
- **Consequence.** The member (here the database's `backup-signing-key`) stayed accepted with no object. Every later keep or retire review refused `durable-resource-missing`, and a redeploy refused too, because the planner recreates only never-started-set members (R19). A closed transaction is final, so there was no exit.
- **Schedule.** "create a database, then retire it", with `LandsFailed` or `LandsUnready` at write 5 and `TransientReadFailure` at observation 41: I1.

**Fix (ADR 26: missing access is an error, not evidence).** Close refuses with `absence-unconfirmed`, naming each member and the reason its absence could not be read. The transaction stays open, so the operator closes again once the read succeeds; the member is never dropped. A definite observation of a present object still keeps the member out of the set, as before.

**Tests.**
- "close refuses, retryably, while a never-started create's absence cannot be confirmed (F79)": an unavailable observation and a failed read each refuse, and a confirmed read closes with both creates never-started.
- "close refuses while a never-started member's absence cannot be read, and closing again ends it (F79)": the model pin; both schedules exit `[[Close]]`.
- The landed-close test had expected the silent drop. Its close now confirms absence, and the member is never-started.

**Mutation.** `test/mutations/F79-close-drops-unconfirmed-absence.diff` reproduces the original I1.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Closed on source. Tests: "close refuses, retryably, while a never-started create's absence cannot be confirmed (F79)" and the model pin "close refuses while a never-started member's absence cannot be read, and closing again ends it (F79)". Killed: `F79-close-drops-unconfirmed-absence`, `ADR26-never-started-skips-absence`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

## F52

**Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges** — P2; **Closed**; owner EP-153.

**Native evidence (2026-10-04, candidate `847543896d07`, acceptance C2 on cp3, nagare-phase-b's `retained-postgresql-rename` interruption):** during the reviewed rename `scenario-rename-src` → `scenario-renamed`, interrupted at its copy Job (`tx-c1e805c8…` active), `inventory status --json` (`pending-evidence/interrupted-recovery/migration-status.json`, 14:27:44 PDT) reported `replaced-incarnation` for three members:

| Member of `database-scenario-rename-src` | Observed (the new `scenario-renamed` object) | Recorded (inferred: the pre-rename `scenario-rename-src` object; heads are not versioned locally) |
| --- | --- | --- |
| `pvc` | `945cb425…` | `85240ad1…` |
| `credential` | `c1c2a1f2…` | `834c72f5…` |
| `backup-signing-key` | `fbb46d3e…` | `230dbec0…` |

After convergence, the creates re-established the records and status reported `converged` (`pending-evidence/status-adopt.json`). The C2 driver's "zero `replaced-incarnation`" assertions ran only after C1 and before the runner, so they did not cover this window.

**Cause (source):** `headIncarnations` is a map from resource ID to physical identity, with no provider address. Status compares the object it observes at a member's current declared address with an incarnation recorded at the member's previous address.

**Why it matters:** a reviewed, in-progress migration is reported as an out-of-band replacement, which is the signal F49 reserves for data loss. Under the fail-open recording limit, a migration whose convergence observation fails would leave a stale record. The renamed database would then read `replaced-incarnation` permanently, and its receipts would refuse ingestion with no reviewed way to rebind.

**Required repair/verification:** bind each record to the provider address it was observed at, and compare only at the same address. Or skip the comparison for members selected by the active transaction. Regression: a member whose declared address changed in a reviewed migration is never `replaced-incarnation`, mid-transaction or after a failed convergence observation. Native: the next acceptance C2's status during the interrupted rename shows no `replaced-incarnation`.

**Operator decision (2026-10-04, in session nagare-phase-b):** deferred as a known limitation of this release, to be documented in ADR 22 and the release notes and fixed in a follow-up. It does not block MP-23 completion.

**Operator decision (2026-10-04, superseding the deferral above; [retrospective](../mp23-engineering-retrospective-2026-10-04.md) §6):**
- Un-deferred. Fix it in MP-23. It blocks MP-23 completion.
- The fix lands with a class-level interpreter regression under [ADR 25](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), [EP-173](../../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) M2's incarnation invariant. The regression must fail on the pre-fix source.
**Implementation update (2026-10-05; claude-opus-5-5):**
- **During the transaction.** `statusIncarnations` (`src/Nagare/Inventory/Status.hs`) drops the records of members that the active transaction's reviewed migration moves. `inventory status` and the recovery model both use it. Admission makes the desired revision accepted, so status observes the new address. The old record describes the previous address and cannot be compared there.
- **At convergence.** A `MigrateResource` destination is the member's new object. `convergedIncarnations` binds it as `Established`. `releaseClaimWith` drops migrated, retained and collected members' earlier records before binding, not after. Before this change, a renamed member, retained under the same resource ID, ended unrecorded. Now its new object is recorded. If the convergence observation is unavailable, the member stays unrecorded, never stale.
- **Regression:** `test/InventoryPostgresRenameSpec.hs`, "status never reports a renamed member as replaced, at any step (F52)". The reviewed rename runs with the old members' incarnations recorded. Status is computed as `inventory status` computes it after every Kubernetes request.
  - Without the status change, it reports `replaced-incarnation` for the moved members mid-transaction.
  - Without the convergence change, no new object is recorded.
  - With both, the run converges with no `replaced-incarnation` at any step, and every record names a new object.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../../cli/nagarectl/test/mutations/README.md):
- `F52-status-compares-migrated-records.diff` (existing record) fails both "status never reports a renamed member as replaced, at any step (F52)" and the rename recovery model ("I3: status reports renamed members as replaced …"). The status half is proven, with class-level coverage: the rename model checks I3 at every stop, under every write fault.
- **Survived:** a mutant that stops a migration from establishing its destination's record (`Execute/Incarnations.hs`, `establishes … || migrates action` disabled) passes every F52 test and the whole recovery model. Nothing checks that the renamed members' new objects are recorded at convergence. The model's final checks pass with an empty record map.
- **Stays Verifying.** Needed: a regression that fails on that mutant (assert the renamed members' records name the new objects after convergence), and ideally a fault on the convergence observation in the rename model. The entry should also name the rename recovery model and I3 as its covering invariant.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Stays Verifying. The status half is proven. The convergence half still has the surviving mutant (`establishes` with `migrates action` disabled), so the regression and record were sent to session nagare-fix. Native confirmation is this candidate's C2 interrupted rename showing no `replaced-incarnation`. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Native reproduction (2026-10-07, nagare-verify; candidate `96c1da11`, C2 checkpoint; observed).** The convergence half fails natively, not only under the mutant. A reviewed `db rename postgres scenario-rename-src scenario-renamed` was SIGKILLed when its copy Job appeared and then resumed to convergence. `inventory status` then reported all 9 renamed members as `unrecorded`: statefulset, pvc, credential, service, backup, backup-account, backup-read-binding, backup-read-role and backup-signing-key. For every one of them the transaction's `MigrateResource` `Completed` event carries a `physical` UID equal to the live object, so convergence bound none of the recorded identities ([status](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/status-unrecorded.json), [journal completions](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/rename-journal-completions.json)). The renamed database's backups therefore refuse, and F80 removes the documented exit. The source fix was sent to session nagare-fix. Stays Verifying until it lands and the next C2 rename shows its members recorded.

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).** The native failure has two causes in the convergence half. Both are fixed.
- **A later review drops the renamed records (the native cause).** `releaseClaimWith` (`Execute/Claims.hs`) dropped the record of every member in `headRetained` and `headCollected` on every converged review. A rename retains its source under the renamed members' own resource IDs, so the first converged review after any rename (here the restores phase's) wiped all nine records. It now drops only the members this review migrated, retained or collected (`reviewMigrations`, `reviewRetentions`, `reviewCollections`). Reproduced on master by "a later converged review keeps the renamed members' records (F52)": the records were `{}` after one unrelated review.
- **The convergence observation never bound anything.** `migrationDestinations` (`Execute/Incarnations.hs`) listed each data-bearing member once per migration stage, and the observation refuses a repeated resource ("duplicate resource observation"). So after a lost create response the PVC, StatefulSet, credential or signing key stayed unrecorded, although the observation should record them. The members are now listed once. Found with the rename model's new F52 check (below).
- **Regressions.**
  - "status never reports a renamed member as replaced, at any step (F52)" now asserts that the records equal the UID of each member's object at its new address, not just "non-empty, not old". It fails on the surviving mutant with records `{}`.
  - "a later converged review keeps the renamed members' records (F52)".
  - The rename recovery model, under every write fault: after convergence, one more converged review of the renamed database; then no record names an object other than the member's new one, and every data-bearing member (claim, writer, credential, signing key) is recorded. A lost response leaves a non-data member such as the Service unrecorded, by ADR 27 §1. Its exit is the rebind (F80).
- **Mutation records** (each proved locally against its pattern; the sweep result is in the hand-off): `F52-migration-destination-not-established` (the old survivor; its note is removed from the mutations README), `F52-release-drops-every-retained-record` and `F52-convergence-observation-repeats-members`.
- **Not covered here.** An uninterrupted rename and an interrupted one both converge with every record (the model covers both orders). The native confirmation is the next C2.

**Independent verification (2026-10-07, nagare-verify; observed).** Closed. The source fix is in `a7958867` ("a later converged review keeps the renamed members' records (F52)" and the strengthened status test; records `F52-migration-destination-not-established`, `F52-release-drops-every-retained-record` and `F52-convergence-observation-repeats-members`; the sweep at `a7958867` killed all 122 records). Natively, the C2 run on `a7958867` killed its rename at the copy Job and resumed it. Afterwards no renamed member was unrecorded or replaced: status before the rebind check counted only the one designed lost-create-response member and the drill's planted replacement ([counts](../mp23-independent-results-2026-10-07/c2-discovery-a7958867/status-before-rebind.json)). The run finalized all 16 assertions ([summary](../mp23-independent-results-2026-10-07/c2-discovery-a7958867/local-health-summary.json)).

## F62

**A reviewed rename copies from, and retains, a source replaced outside review** — P2; **Closed**; owner EP-153 / EP-173.

**Found by independent review (2026-10-05, nagare-84; inferred from source, model reproduction requested).**
- A migration's source physical identity comes from the planning observation (`Plan/Migration.hs` → `Lifecycle.hs` → `Plan/Changes.hs` `validatedSourcePhysical` → `headRetained`). It is never compared with the member's recorded incarnation.
- If the source PVC or StatefulSet was replaced outside review, the reviewed rename copies from the replacement, possibly an empty volume, and puts the replacement's UID into retained history.
- That is F51's harm through migration instead of retirement. No model injects `Replaced` on a rename source.

**Required:**
- `Replaced` on the rename source in the rename recovery model, which should fail I3 on HEAD;
- refusing a migration whose source is not the recorded incarnation;
- a mutation record.

**Implementation update (2026-10-05, EP-176 M2; claude-opus-5-5):**
- **Source.** The migration validator (`Migration.hs`, `validateMigrationInput`) now reads each source through the checked accessor. A durable source must be its recorded incarnation, and no source may be a replacement of a recorded one. Otherwise planning refuses with `migration-source-incarnation`.
- **Writer (A52).** The writer StatefulSet that prepare reads and fences is checked against its record too. This closes the window between the planner's observation and prepare's re-read.
- **Regressions.**
  - "a rename refuses a source replaced outside Nagare, at planning (F62)";
  - "a rename refuses a writer replaced between planning's reads (ADR 27, A52)";
  - mutation records `ADR27-F62-migration-source-unchecked` and `ADR27-A52-writer-unchecked`, each failing its test.
- **Fixtures.** The rename fixtures now record the old members' incarnations by default, as a converged create does.
- **Not done.** The rename recovery model has no `Replaced` fault on the source yet, so the refusal is pinned by the focused test only. Status is the verifier's to set.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Status moves from Open to Verifying. The planning refusal is pinned by "a rename refuses a source replaced outside Nagare, at planning (F62)". Killed: `ADR27-F62-migration-source-unchecked`, `ADR27-A52-writer-unchecked`. The required `Replaced` fault on the rename source in the rename recovery model is not done, and was sent to session nagare-fix. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).** The rename recovery model now injects `Replaced` on the rename source's claim or writer at each of its 124 reads, with the replacement volume either empty or holding other data. The exits are status, a reviewed rebind (ADR 27 §3) and the rename again. A replacement before admission refuses at planning (`migration-source-incarnation`), and the rebind then the rename converges, copying only the data the rebind's review accepted (the final check compares the copied data with it). Replacements after admission found F81, fixed in the same commit except its pinned E2 and E3.

**Independent verification (2026-10-07, nagare-verify; observed).** Closed. The planning refusal is pinned ("a rename refuses a source replaced outside Nagare, at planning (F62)"; `ADR27-F62-migration-source-unchecked` killed). The required model fault now exists: the rename recovery model injects `Replaced` on the source at each of its 124 reads, with an empty volume or other data. The exit classes it found are F81, fixed in `2df33205` except the pinned E2 and E3 (the follow-up candidate) and D1 (deferral ledger, manual runbook exit).

## F80

**The reviewed rebind cannot be issued for application or standalone-database members, so an unrecorded database never has its backups accepted again** — P1; **Closed**; owner session nagare-fix (MP-23 step 5).

**Found by the independent C2 checkpoint (2026-10-07, nagare-verify, candidate `96c1da11`; observed).**
- **How a database becomes unrecorded.**
  - By design (ADR 27 §1), a create whose response is lost records no identity. Here `app deploy` of scenario-a was SIGKILLed 1 s after the `scenario-pg` StatefulSet create's intent (journal seq 988). Resume's adapter recovery proved completion (seq 989) with no `physical`, so the StatefulSet stayed `unrecorded` ([journal](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/deploy-a-statefulset-journal.json)). One lost acknowledgement, a single fault, is enough.
  - F52's convergence defect leaves every renamed member unrecorded.
- **What refuses.** An unrecorded member refuses backups, snapshots and restores, receipt listing and ingestion, data fences, rename and collection ([runbook](../../runbooks/inventory-operations.md#replaced-and-unrecorded-members)). Here `db backup scenario-pg` refused at planning with `invalid-manual-backup`: "the backup source StatefulSet 716f7737… has no recorded incarnation; a reviewed rebind records it before its data is used" ([log](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/restores.log)).
- **The documented exit fails.** The runbook's rebind (an adoption input with `"rebind": true`, issued by `inventory adopt`) refuses before any review for both affected scopes, Application:scenario-a and Standalone:database-scenario-rename-src. The command path was `inventory export` → `scripts/unchanged-inventory-candidate.py` → `inventory compile` (succeeds) → `inventory adopt`, which answered `Kubernetes declaration lacks a packaged document source` (`src/Nagare/Inventory/KubernetesSources.hs`, `loadKubernetesSources`). Application- and database-composed declarations have no packaged `#document[` source ([driver](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/rebind-unrecorded.sh), [adopt logs](../mp23-independent-results-2026-10-07/c2-checkpoint-96c1da11/)).
- **Why tests missed it.** The rebind is tested only at the decision layer (`decideAdoption`, "a reviewed rebind records a replacement, after which it is the accepted incarnation (ADR 27 §3)"). The recovery model counts a rebind as a supported exit, but no test issues one through the CLI for an application or database scope.

**Impact.** With no executable exit, an unrecorded database's scheduled receipts are never ingested and manual backups never plan. Its off-cluster recovery points stop until the database is rebuilt. ADR 27 §3 says "refusal without an exit is not acceptable". This blocks the data-protection gate and the C2 restores phase.

**Required.** An operator-reachable rebind for application and standalone-database members, proved through the CLI command path for a lost-create-response StatefulSet and a renamed member, with a mutation record. The implementer may also consider whether an adapter recovery that proves completion by the reviewed stamp should record the observed identity, so a lost response needs no rebind; that is a design question for the operator.

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).** The rebind failed in two places, at planning and at apply.
- **Planning.** The CLI's planning registry read every selected Kubernetes member without domain-compiler bytes from a packaged `#document[` source. A new library function, `Status.loadKubernetesMembers`, still does that for packaged members. A generated member (an application's or a database's) is accepted only unchanged from its accepted declaration, and takes the bytes its accepted revision recorded, validated as supplied members are. A changed generated member still refuses. `app/Nagare/Cli/Inventory/Planning.hs` calls it.
- **Apply.** A rebind writes nothing, so its review carries no native bytes for its members, and admission's reverification ("the object a rebind records changed since review") could not observe them. `Status.loadRebindNative` loads the rebound Kubernetes members' accepted bytes, and `app/Nagare/Cli/Inventory/Execution.hs` binds them.
- **Regression.** "the adopt command issues a reviewed rebind for a database's replaced and unrecorded members (F80)", in `InventoryPostgresRenameSpec`. After a reviewed rename converges, the claim is replaced outside review and the Service's record is lost, as a lost create response leaves it. The test then follows the documented path: an unchanged compiled candidate, a `"rebind": true` proposal, `planInventoryAdoptionWith` against the target's store with the command's member resolution, and apply from the published review alone. Status then reports nothing replaced, and every record names its live object.
- **Mutation records**: `F80-generated-member-needs-packaged-source` (the test fails with the native message) and `F80-rebind-members-unbound-at-admission`.
- **Limits.**
  - The test covers a standalone database. An application scope's members take the same path (generated, unchanged, accepted bytes), but no test drives an application's rebind; the next C2 confirms scenario-a.
  - The two `app/` call sites are one line each and are not unit-tested.
  - Proposed deferral (for the operator, not done): an adapter recovery that proves a lost create by its reviewed stamp could record the observed identity, so a lost response needs no rebind.

**Verification.** Pending the fix and a C2 on the new candidate.

**Independent verification (2026-10-07, nagare-verify; observed).** Closed. The source fix is in `a7958867` ("the adopt command issues a reviewed rebind for a database's replaced and unrecorded members (F80)"; records `F80-generated-member-needs-packaged-source` and `F80-rebind-members-unbound-at-admission`). Natively, on `a7958867` C2, an application-scope member (scenario-a's backup-read Role) was replaced with `kubectl replace --force`. Status reported it as `replaced-incarnation`. The documented rebind, issued through `inventory adopt` for Application:scenario-a, converged and recorded it together with the lost-create-response StatefulSet. Status then counted 279 converged and 0 replaced or unrecorded ([log](../mp23-independent-results-2026-10-07/c2-discovery-a7958867/rebind-check.log), [after](../mp23-independent-results-2026-10-07/c2-discovery-a7958867/status-after-rebind.json)).

## F15

**Implementation update (2026-09-30, F15 pre-review boundary):** Installed CLI `705716b7` passes the full native local platform-bootstrap gate and preserves the retained F15 `d73c1dc4` payload identity. Its prerequisite public shared-store status refuses with `StoreConditionFailed "gcloud credential or ownership command failed or timed out"` under configuration `labs`; cloud preparation stops at the guard, before a VM review or mutation. Restore that successful guarded read before the bounded cloud rehearsal. This supplies no new credential-expiry/re-pull evidence; operator Verification remains pending.

**Patched certificate controller lacks refreshed private-image credentials** — P1; **Closed**; owners EP-156 / EP-154.

**Locations:** nixos/hosts/nagare-01/registries.nix; bootstrap private certificate-controller Deployment and ServiceAccount declarations.

**Native evidence:** The original saved bootstrap creates `net-certmanager-controller` in `knative-serving`; its private Artifact Registry image receives a 401 token response. The accepted host supplies boot-only k3s registry credentials, which have expired. Its recurring Secret policy covers `personal` and `nagare-system` default ServiceAccounts; this controller uses the `knative-serving` controller account. The bounded rollout stops naturally after 436.558 seconds. Shared generation 469 retains the same original transaction with no claim/fence. Serving and public-image certificate webhook workloads are Ready.

**Implementation update:** A bounded explicit registry recovery candidate passes all 992 CLI tests, the public foundation/bootstrap regression, registration/injected-mutation audit and structural style checks. Named regressions include `bounded registry recovery journals intent and requires actual workload readiness`, `registry recovery binds completed host history and original private Deployment`, `registry unit recovery preserves landed phases across expiry and settles ready workloads`, and strict intent/receipt parsing. It saves the original Deployment/host/unit proof separately, journals intent before replaying only the accepted registry bootstrap unit and k3s service, and retains independent Deployment readiness as the completion criterion. Installed `39842f8058bdaaf94819365b1f2511a3a7147246` runs this public recovery in 101.552 seconds and proves the original Deployment/pod Ready. Public original-review resume converges in 230.454 seconds at generation 549, with no active transaction, claim, fence or migration; all accepted/prerequisite revisions remain exact. [Retained redacted proof](mp23-native-bootstrap-results-2026-09-30/registry-recovery.json) binds both journal events and actual workload readiness. No new Secret/ServiceAccount authority is introduced. This preserves the original payload version and review. The final 992-test recheck also proves exact-capsule settlement after lost acknowledgement/readiness, refuses ordinary proof bypass, and retains completed unit evidence after credential expiry. Native locking and quiescent unit jobs bound uncertain host execution. Steady private platform credential coverage still needs a typed ownership/delegation contract and installed acceptance before safe use.

**Implementation update (2026-09-30):** EP-153 moves the registry-recovery mutation into the shared `runOperations` driver. The driver owns intent journaling, claim recheck, recovery-capability execution, and exact receipt settlement; preparation remains read-only. The unchanged retained F15 recording-adapter regressions pass, as do the focused registry suite, all 1,001 `nagarectl` tests, executable build, entrypoint-guard script, structural style, and all 460 `nagare-dsl` tests. The entrypoint guard now covers legacy `platform upgrade --apply --resume missing --yes` and refuses the inventory-admitted context before any upgrade/provider action. This source repair does not verify installed controller credential expiry or re-pull.

**Steady credential source candidate (2026-09-30):** Fresh generated hosts reserve the exact three pull Secret addresses; the Serving controller account binds its calculated resource identity and a typed host-only refresh grant. The actual timer checks that static grant and both native owner identities, uses resource-version conditions, and refuses foreign credentials or pull references. Legacy accepted hosts stay legacy. All 1,001 CLI tests pass (48.80 seconds); the rendered timer regression passes owned create/refresh, six foreign/race refusals and legacy policy, and fails against the original source with `controller credential target missing`. The CLI executable build, public foundation/bootstrap regression, structural style, command audit, Cabal formatting, host options and NixOS registry assertions pass. [Exact source hashes and verification boundaries](mp23-native-bootstrap-results-2026-09-30/registry-credential-delegation-candidate.json) are retained. Installed fresh-host expiry and re-pull proof remains pending; the existing cloud host/payload have not been changed or upgraded. This source candidate does not close F15 or establish safe use.

**Native fresh-host verification (2026-10-01):** Installed `71288437` converges the original fresh `f15-preview` cluster review with the admitted `d73c1dc4` payload. Its actual timer creates the three exact owned pull Secrets, validates and updates the typed Serving account, and the original private certificate controller performs an uncached pull and becomes Ready after its boot credential expired. A guarded native containerd re-pull of that same cached image refuses without the refreshed Secret and succeeds with the exact owned Secret. VM, closure, node, account, Secret and Deployment identities are checked; k3s invocation, original Deployment and shared head stay unchanged. [Redacted native evidence](mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json) retains the timer, registry response and pull-event boundaries. Native implementation proof is accepted; the operator runbook verification and independent release closure remain pending.

**Required verification:** Exercise source drift, foreign VM/closure/node/boot/workload, malformed or changed recovery proof, lost acknowledgement and partial-unit replay with zero repeated proved phases. Verify the installed original-transaction path and real image readiness without raw provider repair or review reset. Prove future credential expiry/re-pull coverage before initial safe-use acceptance.

**Verification:** Source regressions and installed original-transaction recovery/bootstrap convergence are retained; steady credential refresh/re-pull coverage remains open. Independent closure is required.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** No source change in phase 1. Native closure is the phase-3 C3 run: a genuine credential refresh and a private pull after the boot credential expired. Next check: phase 3a.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. C3 on fresh context `mp23-c3j` (`c3-1009`), bootstrapped from the candidate's own payload. The private net-certmanager controller pulled its image and became Ready. After the boot credential expired, 7 private pulls had 0 failures, and all 3 owned pull Secrets had been rewritten since boot. Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/) (`f15.sh` and `f15-late.sh` steps in `chain.log`).


## F31

**Registry refresh cadence permits credentials to expire before its next run** — P1; **Closed**; owners EP-154 / EP-156.

**Independent installed native evidence (2026-10-02):** The fresh immutable 762
host and full cluster converge, with all three exact host-owned pull Secrets, the
Serving account grant, and all 33 Pods Ready/Succeeded. Its automatic timer ran
successfully at 02:22:18 UTC, yet every current credential expires at 02:50:10.
The native 30-minute timer next deadline is approximately 02:52:18, leaving at
least 128 seconds after expiry before the next scheduled refresh. A successful
metadata request reused the cached boot token. [Google's documented metadata
cache behavior](https://docs.cloud.google.com/compute/docs/access/authenticate-workloads)
retains a token until five minutes of remaining lifetime; the current validation
accepts any lifetime above 300 seconds. Thus a healthy refresh can install a token
that expires before the next run. [Native timer and credential evidence](../mp23-independent-results-2026-10-02/registry-timer-expiry-gap-f31.json).

**Required repair/verification:** Align automatic refresh cadence, lifetime checks
and scheduling margin with metadata-token caching. Independently prove a genuine
automatic replacement before the previous credentials expire, then authenticate
the exact private controller image after the original boot credential expires.
Preserve typed Secret/account ownership, exact conditional writes, and the
immutable/disposable fixture decision. Do not manually start the refresh unit or
patch credentials to manufacture the acceptance result. F15 remains Verifying.

**Implementation update (2026-10-02, `ebe9d3a7`; claude-opus-5-5):** `nixos/hosts/nagare-01/registries.nix` now runs the pull-Secret timer every 120 s (`AccuracySec` 5 s) with a 60 s `TimeoutStartSec`. A module assertion requires interval + accuracy + timeout < 300 s, the minimum `expires_in` the script accepts, which is the metadata cache floor. An unchanged token and current ServiceAccount cause no Kubernetes write (compared on stdin; the token never enters argv), and a rotated token keeps the resourceVersion-conditional replace. `python3 scripts/test-registry-credential-delegation.py` passes the cadence invariant, create, no-op, rotation, ≤300 s refusal, six foreign/race refusals and the legacy policy. It fails against the previous module. `nix eval` of the `nagare-01` toplevel drv succeeds. Remaining: an installed fresh-host observation of an automatic replacement before expiry and an expired-boot-credential private pull (EP-156 C3); independent closure.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** `python3 scripts/test-registry-credential-delegation.py` passes at the candidate. With the previous module it fails: there the cadence was 30 minutes and any token with more than 300 s left was accepted ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: in phase 3a, read the controller timeline for a refresh before expiry.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. On `mp23-c3j`, all three `nagare-registry-pull` Secrets were rewritten by the timer after boot, and 7 private pulls after expiry had 0 failures. The regression script passes at the candidate. Wiring it into the gate is done on `next-release` (`e96fee1a`). Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F32

**Image-cache cleanup selects an image used by active pod sandboxes** — P1; **Closed**; owners EP-153 / EP-156.

**Independent installed native evidence (2026-10-02):** Installed b805 prepares
two exact cache deletions on the fixed 762 host, including the full image ID for
`rancher/mirrored-pause:3.10.2`. The runtime reports `pinned=false`, but independent
`crictl inspectp` and containerd container inspection show a Ready sandbox uses
that exact image alias. Thirty-five sandboxes exist. The production capture only
lists ordinary containers with `crictl ps -a`, omitting sandbox image references.
No apply occurred; the original review and idle head remain preserved.
[Native review and sandbox evidence](../mp23-independent-results-2026-10-02/image-prune-sandbox-f32.json).

**Required repair/verification:** Resolve and protect exact image IDs referenced
by Ready and retained stopped sandboxes, and fail closed when required sandbox
observations are missing or ambiguous. Account for the configured runtime sandbox
image rather than relying solely on the reported pinned flag. Exercise the actual
production script with sandbox-only use and inspection failure, then independently
prepare and execute a fresh installed native review that excludes those protected
images. Prove ordinary unused-image deletion, workload preservation and durable
one-shot replay behavior. Do not apply the unsafe saved review.

**Implementation update (2026-10-02, `c2dc2bb1`; claude-opus-5-5):** The production script (`cli/nagarectl/src/Nagare/Inventory/ImagePruneScript.hs`) adds every pod sandbox's image (`crictl pods -o json`, then `crictl inspectp -o json` `.info.image`, for Ready and NotReady sandboxes) and the configured sandbox image (`pinned_images` `sandbox` or legacy `sandbox_image` in `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`) to the resolved used set that both inspection and removal protect. A failed listing or inspection, a missing image field, or an absent or ambiguous configured image refuses the capture. Read-only observation on local k3s v1.34.6 (cp3) confirmed `crictl info` lacks the sandbox image, `inspectp` reports `.info.image`, and the pause image is `pinned=false`. `python3 scripts/test-image-prune-protocol.py` passes 23 cases (was 10), including sandbox-only, configured-only, seven fail-closed observations, ordinary deletion beside protected sandboxes, and inspection reporting sandbox images as used. The first sandbox case fails against the previous script. Remaining: a fresh installed native review that excludes protected images and deletes an ordinary unused one, with one-shot replay; independent closure.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The production script protects every pod sandbox image, Ready or NotReady, plus the configured sandbox image. A failed or ambiguous observation refuses the capture. `test-image-prune-protocol.py` passes 23/23 at the candidate; with the previous script, the first sandbox case fails ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Status set to Verifying. Next check: the reviewed GCE-image cleanup in phase 3a.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The reviewed image-cache cleanup on `mp23-c3j` removed 3 images with 0 pull or sandbox warnings. 68 pods stayed Ready, and a same-request replan had 0 operations. Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/) (`image-cleanup.sh`).


## F16

**Unready application creation cannot yield to a corrected reviewed configuration** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence:** The cloud fixture has 2 CPUs, with 1,785m allocated after full bootstrap. Application A's default web pod requests 275m and cannot schedule, although its PostgreSQL pod is Ready and its retained PVC is Bound. Public saved apply stops after 365.186 seconds at `op-711f755156b69c10be13390c`. Generation 576 keeps the original application transaction without claim, fence or migration. Its review targets only its 11 owned resources; [redacted evidence](mp23-native-bootstrap-results-2026-09-30/application-capacity.json) preserves the review, identity and failure. No raw resize, patch, restart, review rewrite or history reset occurred.

**Implementation update:** A guarded `stop-incomplete-application` decision requires one changed Application scope, only unfenced owned Kubernetes creates, an originally absent stateless Knative Service proved owned and unchanged but unready, and no other uncertain operation. It journals selection before clearing the active transaction, retaining admitted ownership and prior converged revisions. It never completes the workload or rolls ownership back away from created retained data. The same decision settles a lost head acknowledgement without provider IO; ordinary proof cannot bypass a pending stop. A new application review can correct resource configuration. Knative conditional updates retain UID/resourceVersion and exclusive non-status ownership checks; installed update proof remains pending.

**Required verification:** Preserve unselected stopped applications' prior converged revisions when another scope completes. Prove created retained-data ownership survives stopping, foreign/durable/changed-native and multiple-uncertain refusals, exact decision replay after lost acknowledgement, and installed stop followed by a new corrected review. Require the same Service/PVC/database identities, Ready application and no platform revision change. Prove the Knative conditional update and unchanged replay through the public installed path.

**Verification:** The installed `0f6fa7db` stop passes in 12.441 seconds: all 24 accepted and 23 converged revisions and the original Service/PostgreSQL/PVC UIDs are preserved; generation 579 is idle. The corrected plan then refuses in 17.365 seconds at the original never-created backup signing key. [Redacted evidence](mp23-native-bootstrap-results-2026-09-30/application-stop-and-replan.json) retains this consumer result. The follow-up repair derives never-started create proof from the original immutable stopped review and validated committed journal, only for planning that selects its unchanged unconverged application revision. Previously completed, uncertain, changed and foreign durable members still refuse; ordinary inspection and unrelated planning do not scan execution history. The final CLI suite passes all 997 tests in 52.48 seconds, covering never-started creation, completed data refusal, later uncertain intent, foreign ownership, changed declaration, superseded revision, missing committed journal and inspection/unrelated planning isolation. Structural style and the managed-command audit pass. The installed public bootstrap fixture passes. Installed `49db2199` saves the corrected Application A review in 42.372 seconds and converges in 63.123 seconds: same Service/PostgreSQL/PVC UIDs, Ready Service, expected HTTP body and preserved seeded row. Only its accepted revision changes, with all 24 scopes converged at generation 605/sequence 539. [Redacted native proof](mp23-native-bootstrap-results-2026-09-30/application-correction.json) retains the original NotReady UID/resourceVersion precondition and actual consumer results. A follow-up real-planner regression reproduces a convergence leak: completing another application incorrectly marks a stopped, unready application converged. The repair advances only revisions changed by the completing review and removes retired scopes; it preserves unselected prior convergence. The eight focused regression cases and all 998 CLI tests now pass (60.14 seconds); structural Haskell style passes. Installed `eb582eb0` builds successfully. A second regression exposes unchanged stopped members being omitted while remaining creates complete; selected unconverged scopes now require fresh verification for unchanged managed members. Native preparation still refuses NotReady verification, while a corrected Knative configuration uses its guarded update. All 998 tests pass after this extension in 67.46 seconds, and structural style passes. Final installed validation and independent closure remain open.

**Installed follow-up:** Immutable `2101b834` builds on aarch64-darwin and passes the installed public foundation/bootstrap fixture. Its [cloud interruption and second-root proof](mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json) preserves every prior accepted owner and all application/database identities while recovering a separate backup without repeating its create. Its [installed stopped-readiness proof](mp23-native-bootstrap-results-2026-09-30/cloud-stopped-notready-verification.json) now confirms unchanged NotReady replan refusal without a review or head change, followed by a corrected conditional update retaining the Service UID. All 29 scopes converge at generation 698/sequence 615; original application/database/PVC identities and data remain intact. Independent F16 closure remains open.

**Implementation update (2026-09-30):** EP-153 adds a bounded fixed-seed in-memory driver model to the ordinary `nagarectl-test` suite. Planner-produced create/update/selected-unconverged-verification/retention-retirement reviews across two Application scopes interrupt each provider-effect boundary and resume with recording-adapter proof; stale conditional writes refuse without mutating the head, and a foreign executor claim requires explicit takeover. The model checks no duplicate effect, selected-only revision completion, accepted/converged consistency, monotonic head/journal state, and finite ambiguity recovery. Its stopped-scope assertion rejects the `eb582eb0` convergence leak; its unchanged selected member assertion rejects the `7c957c02` readiness-verification leak. The focused model test and all 1,002 CLI tests pass; structural style passes. This is source-only evidence and does not replace the operator's F16 runbook verification on `f15-preview`.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** All fix diffs read. Without the fix, `eb582eb0` fails (the convergence leak), `7c957c02` fails ("unchanged stopped workload lacks fresh readiness proof"), and a stop-guard mutation of `0f6fa7db` fails "refuses foreign scope". `49db2199` fails only to compile on its parent (new API). All pass at the candidate, in a full suite of 1,184 tests ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Source verified. Next check: native application change and recovery on the acceptance C3 (phase 3a).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Source is done: ADR 26 close plus the fast tier. Stays Verifying until native confirmation on this candidate (C2 or C3). The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The runbook execution on `mp23-c3j` stopped an application update that landed but never became Ready (an unschedulable 64-CPU request). `inventory close` kept the scope at the review's desired revision, and a corrected review converged with the same Service UID, Ready. The create variant shares the close path and is covered by the recovery model's fast tier. Evidence: [runbook execution](../mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/) (`close-stopped-transaction`).


## F30

**Controller status churn strands admitted conditional Service correction** — P1; **Closed**; owners EP-153 / EP-156.

**Independent installed native evidence (2026-10-02):** A fresh public Application
review creates its PostgreSQL/PVC and an intentionally unschedulable Service.
Exact stop preserves ownership; an unchanged replan refuses NotReady, and an
unrelated scope completes without falsely converging the application. Its
corrected review then completes the original unfinished backup create but refuses
the conditional Service update: Knative's status-only RevisionFailed transition
changes resourceVersion after planning. UID, generation, spec, labels, annotations,
finalizers, deletion timestamp and owner references remain exact. The existing
strict saved-state preflight says to replan, but the admitted transaction cannot
replan, and ordinary resume repeats the same refusal. No provider write was
attempted for the correction. [Exact native evidence](../mp23-independent-results-2026-10-02/application-status-race-f30.json).

**Required repair/verification:** Preserve the original review and transaction.
Preserve legacy full-object observation semantics; the old digest cannot prove a
status-only refresh. Stop only this never-intended owned Service Update and its
never-intended dependent release-history Create, with completed companions and
unchanged accepted/converged vectors. Fresh reviews may use a versioned
status-stable observation retaining spec/ownership/identity authority and a fresh
atomic UID/resourceVersion write precondition. Refuse changed desired fields,
foreign ownership, deletion, replacement and any prior selected intent; test a
race after refresh. Execute the fresh correction, prove the same Service/database/
PVC identities and known row, and complete independent F16 verification. No generic precondition
relaxation, history reset or raw patch is authorized.

**Stopped handoff (2026-10-02):** The independently executed bounded stop
succeeded and preserved all ownership/convergence/retention vectors. Source fixes
`95b58a24` and `52432400` then prepared a version-2 update with one dependent
ConfigMap create, nine verifies, and all 31 unrelated scopes preserved. The
conditional Service update landed on its original UID; generation 2 was observed
and ConfigurationsReady became True, while route/load-balancer readiness remained
Unknown. At the user's instruction, only the waiting CLI was interrupted after
183.115 seconds. No rollback or provider patch occurred. The original new
transaction remains preserved; final data/replay checks were not run. F30 native
closure remains pending. [Exact stopped state](../mp23-independent-results-2026-10-02/application-status-race-f30-handoff.json).

**Implementation update (2026-10-02, MP-23 A4 resume attempt; claude-opus-5-5):** With no live executor process and the store still at generation 9314 with the original claim, the admitting binary (`ab3aabf7…`, same isolated operator root) ran the public `inventory resume tx-b4da295e… --yes`. It exited 1 after 3 s with `ambiguous … at op-fed6a9432af7669b7446f230` and wrote no provider effect. That is the driver's correct refusal to retry an unproved update. Read-only observation: the Service keeps UID `470ff139…` at generation/observedGeneration 2; ConfigurationsReady is True; revision 00002 is Running 2/2; Ready/RoutesReady are Unknown ("Waiting for load balancer to be ready"). The cause is [F34](mp23-findings-closed.md#f34), not the F30 repair. Following the stop rule, no `inventory recover`, takeover, patch or rollback was attempted, and the transaction remains preserved. Private record: `/tmp/mp23-independent-application-correction/a4-resume-refusal.json`. Next: diagnose and repair F34 under a written recovery plan, then resume the same transaction and verify identities, the known row and replay.

**Implementation update (2026-10-02, A4 terminal state; claude-opus-5-5):** After the F34 repair, the same public `inventory resume tx-b4da295e… --yes`, with the same admitting binary and root, exited 0 in 3 s (`converged`). Store status shows no active transaction or claim (generation 9322). Service `470ff139…` (generation 2, Ready), StatefulSet `03a23352…` and PVC `15138d3a…` are unchanged, and `select id, value from mp23_correction_probe` returns `1|mp23-original-data-before-correction`. An unchanged `app deploy … --save-plan` replan with the scope's recorded tag, image resource and recovery binding produced review `701d1306…` with zero operations. No rollback, patch or history reset occurred. Private record: `/tmp/mp23-independent-application-correction/a4-f34-recovery.json`. F30 and F16 now await independent verification.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** `52432400` fails on its parent ("observation Kubernetes envelope differs from reviewed operation"). `95b58a24` fails only to compile there (new module). Both pass at the candidate ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). The A4 terminal resume records (`/tmp/mp23-independent-application-correction/a4-*.json`) agree with the updates above: converged, the same Service/StatefulSet/PVC UIDs, the known row, a zero-operation replan. But they were written by the implementer with development binary `ab3aabf7` and are retained only in `/tmp`; archive them under `docs/audits/`. Status set to Verifying. Next check: native application change and recovery on the acceptance C3 (phase 3a).

**Version 2 removed (2026-10-06, EP-180 M5b; claude-opus-5-5):** The status-stable version-2 observation this entry introduced for Knative Service updates is deleted. Every update now follows G6's single discipline (RES-4 U3, U10): it is guarded by the reviewed UID, this member's ownership and its before-state stamp, which status writes never change, and it writes with a fresh resourceVersion. A status-only transition like this entry's RevisionFailed therefore no longer refuses an admitted correction, for any kind. Saved version-2 reviews are refused, since Nagare has no installation to keep compatible. Deleting version 2 exposed F73.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Source is done: the G6 guard; killed `G6-write-guard-compares-whole-state` and `G6-retire-stale-precondition`. The A4 native records were never archived. Stays Verifying until this candidate's native run. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. On `mp23-c3j`, a corrective Knative Service update converged through the G6 guard under live controller status churn: the runbook's corrected review and C3's drift `--take-over-fields` repair both converged. Evidence: [runbook execution](../mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/), [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F39

**Staged cloud teardown cannot prepare any Pulumi operation on a real stack** — P1; **Closed**; owners EP-153 / EP-156.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `db808a74`, checkpoint C3 context `mp23-c3` in `tan-ng-labs`):** This is the first native run of staged teardown; F33 records that none had been attempted. In the clean `env -i` operator wrapper the runbook prescribes, `infra destroy --save-plan` refused before saving a review. Every one of the 14 cloud operations failed in `PrepareRefused` with `passphrase must be set with PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE`. The planner was then given the context's own documented exports (`PULUMI_HOME`, `PULUMI_BACKEND_URL`, `PULUMI_CONFIG_PASSPHRASE_FILE`, `NAGARE_PULUMI_STACK`, as printed by `nagarectl context env`). Every operation then refused with `PulumiResourceStepMissing`. A manual targeted `pulumi preview --json` of `nagare-apex` (Pulumi v3.255.0) returned only the implicit stack step. The same command with `--show-sames` returned `same` steps.

**Cause (source):**
- `Runtime/CloudTeardown.saveReviewedCloudTeardown` resolved the workspace with `resolvePlatformWorkspace`, so the Pulumi home, backend and passphrase file were never set. `inventory apply` and bootstrap get them through `Platform/InfrastructureReview.prepareInfraTargetWithPulumi`.
- `Adapters/PulumiRuntime.prepareUnprotectedPlan` ran the saved-plan preview without `--show-sames`. `Adapters/Pulumi.validatePulumiPreparation` requires a step for every selected resource, so any Pulumi operation with no native change (verify-only, policy-only) could never prepare.
- Both defects are present unchanged in candidate `44ff0fd7`.

**Why it matters:** S9 of the C3 sequence, and any operator teardown of a cloud context, cannot start. A reviewed `VerifyResource` over cloud resources in any other review fails the same way.

**Implementation update (2026-10-03; claude-opus-5-5):**
- Teardown planning now calls `prepareInfraTargetWithPulumi True`. That is the same ADC check, reviewed Pulumi selection and project guard as inventory apply, and it doesn't probe the guest being torn down.
- The adapter preview passes `--show-sames`.
- New regression in `test/InventoryCloudSpec.hs`: `an unchanged targeted Pulumi resource prepares from its same step (F39)`. A fake Pulumi omits `same` steps unless `--show-sames` is passed, matching the native behaviour above. Without the fix the test fails with the native `PulumiResourceStepMissing`.
- All 1,174 `nagarectl` tests pass, as do `just haskell-style-check`, `scripts/check-haskell-architecture.py`, `scripts/check-cli-architecture.py` and `scripts/test-managed-command-audit.sh`.
- Native check: the development build, in the clean wrapper without the Pulumi exports, saved the stage-1 teardown policy review on `mp23-c3` (14 `VerifyResource` operations, 89 s).

Remaining: the rest of the staged teardown on the checkpoint, then the final candidate's C3 teardown and independent review.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. The regression fails without the fix with the native `PulumiResourceStepMissing` ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the staged retirement records from the acceptance C3 teardown (phase 3b).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate (staged teardown). The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The `mp23-c3i` staged teardown stage 1 (`infra destroy --save-plan`, 14 VerifyResource on stack `mp23-c3i`) planned and converged with the candidate CLI (`tx-db7c0ef2…`, session mp23-c3i, 2026-10-08). Evidence: [c3i teardown](../mp23-independent-results-2026-10-07/c3i-teardown/).


## F43

**A fresh inventory context cannot enable the platform Google CDN backend, so B3 cannot run** — P1; **Closed**; owners EP-158 / EP-156.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `14071e58`, C3 checkpoint `mp23-c3f`):** B3 and the cloud gate's `google-cdn` check require a Google CDN host record created by reviewed application deploy. The CDN guide (`docs/user/cdn.md`) requires the platform BackendService to be accepted in inventory first. On the fresh context, `nagare:enableCdn: "true"` was added to the context's Pulumi stack config. Then:
- `platform bootstrap plan` returned 206 `VerifyResource` operations and no cloud change.
- `infra preview --save-plan` produced a legacy Pulumi bundle with 12 CDN creates and an apex update.
- `infra apply --plan` refused it: "this context has resource inventory history … legacy infra apply cannot safely mutate it".

No CDN resource was created, and the edit was reverted.

**Cause (source):** `nagare:enableCdn` is not a field of the context profile (`Nagare.Target`; `context create` has no CDN option), so the stack-config projection never carries it. The cloud resource catalog that bootstrap admits (`infra/pulumi/resource-catalog.json`, read by `Bootstrap/Cloud.hs`) has `foundationManaged`, `imageEnabled` and `nixCacheEnabled` sections but no CDN entries. A CDN-enabled stack would also differ from the accepted cloud scope. `infra preview --inventory` needs a compiled cloud candidate that no command produces.

**Required repair/verification:** Either add a typed context flag (for example `context create --enable-cdn`), projected to `nagare:enableCdn`, plus a `cdnEnabled` catalog section admitted by the cloud bootstrap stage (the Nix-cache flag is the precedent), so the platform BackendService becomes an accepted cloud member through a reviewed stage. Or record by operator decision that Google CDN is not supported on inventory contexts in this release, and remove `google-cdn` from the cloud gate. Then run B3 natively.

**Implementation update (2026-10-04; claude-opus-5-5):** Operator decision: implement. The change:
- **Context flag.** A typed, cloud-only context flag `NAGARE_CDN_ENABLED` (`context create --enable-cdn/--disable-cdn`; local contexts refuse it) projects `nagare:enableCdn: "true"` and `nagare:cdnApex: "false"` into the stack config. The keys are absent when the flag is off, so existing stacks keep their bytes.
- **Program.** It reads `nagare:cdnApex` (default `true`) and moves the apex to the CDN only when it is true. An inventory context therefore creates the 12 load-balancer resources without touching the apex or the firewalls; application hostnames opt in with `--cdn-backend-resource`.
- **Catalog.** `infra/pulumi/resource-catalog.json` gains a `cdnEnabled` section (layers 6–11, after the VM). `selectedCloudCatalog` admits it only with the image-enabled VM, so on a fresh context the CDN lands in the VM stage and on an existing context it gets its own reviewed stage.
- **Regressions.**
  - `resourceProgramParity` proves that the catalog section equals exactly what the legacy-certificate CDN adds to the image topology.
  - The new `perimeterCdnApex` program test proves the apex stays on the VM with `cdnApex: false` and moves by default.
  - Haskell tests cover catalog admission (`CDN catalog entries are admitted only with the image-enabled VM (F43)`) and the profile (`Google CDN is cloud-only, round-trips, and seeds the apex-preserving keys (F43)`).
- **Native read-only check.** Previewing the new program against the real `mp23-c3f` stack with these keys shows exactly 12 creates and no other change.
- **Gates.** All 1,180 `nagarectl` tests, the eight Pulumi program tests, the style gate and both architecture checks pass. `Nagare.Target.Acme` was split from `Target.hs` to stay under its size cap.
- **Limitation.** Only the `legacy` certificate mode is in the catalog.

Remaining: native B3 on the next candidate's fresh context (created with `--enable-cdn`), and independent review.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read; `scripts/lib/target.sh` only adds validation and the guardrail is unchanged. The catalog-admission mutation fails, and the eight Pulumi program tests pass ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: native B3 on the acceptance C3 (phase 3a).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. B3 on `mp23-c3j` (`--enable-cdn` context): the platform Google CDN backend was enabled and a site was deployed behind it. Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/) (`google-cdn` assertion).


## F44

**Inventory status on a cloud context never observes cloud-foundation members, so cloud runner evidence cannot assemble** — P1; **Closed**; owners EP-153 / EP-157.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `14071e58`, C3 checkpoint `mp23-c3f`):** On the converged cloud context, `inventory status --json` reports `observationComplete: false` and `missingProviders: ["CloudFoundationExecutor"]`. The two foundation members (`platform:cloud-foundation/pulumi-stack/mp23-c3f` and the state bucket) are `unknown` with "provider observation is unavailable". The same was visible on the `db808a74` checkpoint ("unavailable providers: [CloudFoundationExecutor]"). The evidence assembler requires the runner's final observation to be complete with no missing providers (F42 keeps that check). So no cloud run can produce `inventory-evidence.json`, even with every other provider configured.

**Required repair/verification:**
- Install the CloudFoundation observer in the status and observation registry for cloud contexts: a read-only bucket and stack check through the same guarded path the foundation adapter uses.
- Regression: status on a cloud fixture is complete.
- Native: the C3 runner's final observation is complete.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b):** `inventory status` now builds the cloud-foundation adapter whenever accepted members use `CloudFoundationExecutor`, with the same `inventoryFoundationAdapter` path planning and execution use: the full accepted declarations, the selected member IDs, the platform workspace, the backend and inventory bucket checks. It observes through the adapter's read-only `foundationInspect` (bucket and stack describe), adds those facts to the observation set, and lists the adapter among the providers. To stop a future executor from being silently unobserved, `Executor` derives `Enum`/`Bounded`, `Nagare.Inventory.Status.missingStatusObservers` returns every executor without an observer, and status refuses to run if any is missing. Regression: `test/InventoryObservationSpec.hs` "inventory status must register an observer for every executor (F44)" fails for the pre-F44 observer set and passes with the cloud-foundation observer. This is a structural regression, not an end-to-end status run on a cloud fixture; the native check on `mp23-c3f` remains the proof that the final observation is complete. Gates: in a clean worktree at HEAD plus only these changes, all 1,178 `nagarectl` tests pass except the 18 that compile fixture configs, which fail there for want of a GHC package environment and pass in the main tree; the new test passes; fourmolu and both architecture checks pass.

**Native verification (2026-10-03, nagare-f3 on the C3 checkpoint `mp23-c3f`, HEAD `9c831749` built into a separate build directory; recorded by nagare-phase-b):** `inventory status --json` reported `observationComplete: true` and `missingProviders: []`, listed the `gcloud-foundation` provider beside the Kubernetes, Helm, Pulumi, artifact, host, manifest and Redpanda providers, and classified all 306 findings `converged`, including the Pulumi stack and the state bucket. Evidence: `/private/tmp/nagare-mp23-c3f/pending-evidence/f44-status/status.json; summary archived in [the C3 checkpoint record](../mp23-implementer-results-2026-10-03/c3-checkpoint-14071e58.json)` (to be archived with the C3 results). Remaining: the final candidate's C3 runner observation and independent review.

**Cloud rehearsal (status completeness) (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3g`):** a nix build of `471cb409` (F45–F47) ran the cloud runner (`scripts/rehearse-gcp-inventory-release.sh --candidate`) on the checkpoint context, which runs the `7d486457` payload. Plan, apply and verify ran back to back: one `CreateResource` of `runner-probe`, verify killed before its marker and re-run to `verified`, a zero-operation no-op review, and a final observation with `observationComplete: true` and `missingProviders: []`. All 17 cloud assertions recorded and finalized. `scripts/assemble-managed-resource-evidence.sh` then assembled `inventory-evidence.json`, the first cloud assembly. This is pipeline evidence, not acceptance: the evidence is labelled with the `471cb409` payload although the context runs `7d486457` ([F48](../mp23-findings.md#f48)). Two helper defects were found and fixed on the way (`4ad4392a`, `e41b1cab`). The cloud wrapper cannot forward `--private-store-export`, so the private export was taken right after verify with the head unchanged (generation 940, sequence 809).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The regression is structural: it compares `missingStatusObservers` with a list, not the executable's real observer registry (`app/Nagare/Cli/Commands/Inventory/Status.hs`), so only native evidence proves the behaviour ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the acceptance C3 runner's final observation is complete (phase 3a).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The C3 runner's final observation on `mp23-c3j` is complete with no missing providers, including the cloud foundation, and the inventory evidence assembled (run `7c8dbfbc…`). Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F45

**Reviewed Google CDN deploy on an inventory context cannot observe or apply its DNS record** — P1; **Closed**; owners EP-158 / EP-156.

**Implementer native evidence (2026-10-04, claude-opus-5-5, candidate `7d486457`, final C3 context `mp23-c3g`):** B3 deployed the `scenario-cdn` server site (fixture `fixtures/inventory-release/gcp/apps/scenario-cdn`) with `--cdn-backend-resource platform:cloud/nagare-cdn-backend/nagare-cdn-backend` on a context created with `--enable-cdn`. Three defects stopped it in turn:
- **(a) Observation unavailable.** The DNS adapter's guard required the apex record to point at the CDN global IP. F43 keeps the apex on the VM for an inventory context (`nagare:cdnApex: "false"`), so the guard always refused and the planner reported the record's observation as unavailable, although the exact `gcloud dns record-sets list` returned `[]` (missing).
- **(b) Apply refused before any DNS change:** "DNS resource lacks its exact hostname, domain, or Pulumi backend dependency". Execution built the DNS bindings from the review's selected declarations only. The record's backend producer lives in the accepted platform `cloud` scope, which the site review does not select.
- **(c) Positional binding.** `dnsSpecsFromDeclarations` expected the record's two `OrderedAfter` producers in the order `[domain, backend]`. Canonical scope encoding sorts dependencies, so an accepted record arrives in either order.

**Implementation update (2026-10-04; claude-opus-5-5):**
- (a) The guard reads the program's published `apexIp` output (`infra/pulumi/index.ts`; the VM IP when `cdnApex` is false, the CDN IP otherwise) and falls back to the CDN IP only for older stacks without that output (`app/Nagare/Cli/Inventory/Adapters.hs`). A failed read still compares against the CDN IP, so the guard stays fail-closed.
- (b) When a review contains DNS records, execution binds them against the review's declarations unioned with the accepted history's declarations (`app/Nagare/Cli/Inventory/Execution.hs`). The review still decides what changes; history only supplies the producers.
- (c) The binding matches producers by role: exactly two producers, exactly one Knative DomainMapping for the record's host with the same owner, and exactly one Pulumi member (`src/Nagare/Inventory/Adapters/Cdn.hs`).
- **Regression:** `test/InventoryCdnSpec.hs` "DNS binding matches producers by role after canonical dependency sorting (F45)" fails on the old positional binding and passes now. It also proves that a record without its Pulumi backend producer still does not bind. (a) and (b) live in the executable's `app/` modules, which the test suite cannot import; their proof is native.
- **Native (development CLI built from these changes, platform root pinned to the accepted `7d486457` payload):** on `mp23-c3g` the `scenario-cdn` deploy converged with the host record on the CDN IP `34.36.179.6`; the apex and wildcard records were unchanged. A reviewed `cdn disable` converged with the record back on the VM origin `136.118.42.29`. Retirement converged with the record retained. Collection was then blocked by F46.

**Checkpoint note:** with the 7d486457 CLI, `inventory status` on `mp23-c3g` listed `CdnExecutor` among the missing providers while the context held the retained CDN record (defect (a)). The `471cb409` build observes it, and the cloud runner's final observation is complete.

Remaining: B3 and the `google-cdn` check on the next frozen candidate, and independent review.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read: the apex guard stays fail-closed on a failed `apexIp` read. The role-binding regression fails without the fix ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the native B3 CDN cycle on the acceptance C3 (phase 3a).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. B3 on `mp23-c3j`: the site's DNS record moved to the CDN address, back to the origin on disable, was retained on retirement, and was collected. Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F46

**A retired site's edge DNS record can never be collected, because retained release history orders after it** — P1; **Closed**; owners EP-158 / EP-156.

**Implementer native evidence (2026-10-04, claude-opus-5-5, final C3 context `mp23-c3g`):** After F45, the reviewed collection of the retained record `standalone:site-scenario-cdn/scenario-cdn.c3-1005.labs.topagentnetwork.net/dns-a` refused with `invalid-collection`. `inventory gc --plan` named the consumer: `standalone:site-scenario-cdn/release-history/configmap`. The release-history ConfigMap has lifecycle `Retain` by design, so it is never collected, and its dependencies included `OrderedAfter` the DNS record. That edge therefore blocks the record forever.

**Cause (source):** The server and static site compiler (`src/Nagare/Inventory/Site.hs`) ordered release history after every managed member of the CDN bundles. The application compiler (`src/Nagare/Inventory/Application/Release.hs`) ordered it after every prior bundle member, CDN records included. History does not read DNS; the edge was only ordering.

**Implementation update (2026-10-04; claude-opus-5-5):**
- Site release history no longer orders after CDN bundle members. Both DNS compilers (`Nagare.Resource.Cdn` in `nagare-dsl`) emit only `CdnExecutor` members.
- Application release history skips `CdnExecutor` members.
- **Regressions:** `test/Nagare/Test/SiteInventory/Server.hs` (Cloudflare server site) and `test/AppDeploySpec.hs` (Google CDN application) assert that no member orders after the edge record. Both fail on the old compilers and pass now.
- **Native (development CLI):** on `mp23-c3g` a fresh site `scenario-cdn2` (the retired `scenario-cdn` cannot be redeployed while its retained claims hold its addresses) ran the whole B3 cycle with exact zone listings after each step. Its history depended only on the namespace, image, domain mapping and service. The steps:
  - deploy: the record was on the CDN IP;
  - disable: the record was on the VM origin;
  - retire: the record was retained;
  - **collect** converged (`tx-e9cf9746…`) and the record was gone.
- **Limitation:** histories accepted before this change keep the edge. On `mp23-c3g` the original `scenario-cdn` record stays retained until the context's perimeter teardown deletes the zone.

Remaining: B3 including collection on the next frozen candidate, and independent review.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The `AppDeploySpec` and `SiteInventory/Server` regressions fail without the fix ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: native B3 including collection on the acceptance C3 (phase 3a).

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. B3 on `mp23-c3j`: the retired site's edge DNS record was collected after retention (`absentAfterCollect: true`). Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F47

**CDN platform outputs are read with the caller's Pulumi environment, not the active context's** — P2; **Closed**; owner EP-158.

**Implementer native evidence (2026-10-04, claude-opus-5-5, `mp23-c3g`):** The CDN binding for `site deploy`/`app deploy` (`app/Nagare/Cli/Application/Cdn.hs`) and the DNS adapter run the project guard's `pulumi config` probe and read the platform outputs with a bare `pulumi -C <dir> stack output` (`Nagare.Ops.Pulumi.stackOutput`). They inherit the caller's `PULUMI_BACKEND_URL`, `PULUMI_HOME` and passphrase rather than exporting the active context's. In a clean `env -i` runner without the Pulumi variables, a CDN deploy plan refused with "no stack named 'mp23-c3g' found". It worked only after the wrapper exported `nagarectl context env`'s Pulumi variables.

**Required repair/verification:** read the outputs through the context-derived Pulumi runtime used by the cloud teardown and bootstrap paths (`prepareInfraTargetWithPulumi`). Then prove a CDN deploy plan in a clean environment that sets only the context selection.

**Implementation update (2026-10-04; claude-opus-5-5):** Both paths now call `ensurePulumiInWorkspaceWithDependencies False False False` before the guard. It exports the context's backend, home, passphrase file and stack, and selects the existing stack without installing dependencies or creating a missing stack. **Native:** with the development CLI, in the same clean runner without any Pulumi variable, the `scenario-cdn3` deploy plan now succeeds and observes its DNS record as missing (`review Cloud DNS A record … -> 34.36.179.6`). It was planned only, never applied. Before the change, the same command refused as above (`pending-evidence/f47/bare-before.log`, `bare-after.log` in the operator root). No unit regression: the change is environment preparation in the executable's `app/` modules.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. There is no unit test, by design. Next check: in phase 3a, a CDN deploy plan in the clean runner on the acceptance C3.

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate. The candidate's full gate is green ([record](../mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](../mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](../mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](../mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. B3's CDN plan on `mp23-c3j` read the platform outputs with the context's Pulumi environment, from the isolated operator root. Evidence: [C3 evidence](../mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/).


## F81

**A reviewed rename stopped by a source replaced outside review, or by a refused copy, had no exit, and close could accept it half done** — P1; **Closed**; owner session nagare-fix (MP-23 step 5).

**Found by the F62 rename model (2026-10-07, session nagare-fix, at `a7958867`; observed).** The model replaces the rename source's claim or writer outside review at each of its 124 reads, with an empty volume or another volume's data, and its exits are status, a reviewed rebind (ADR 27 §3) and the rename again. Classes (characterised with nagare-verify):
- **Close accepted a half-done rename.** A stage preflight refused the replaced source and resume refused the same way; close then ended the transaction and kept the renamed scope, because some destination creates had landed. The members' records named the old objects while status observed the new ones (status reported destination objects as replaced), and the never-started destination claim and credential left `durable-resource-missing` on every later review.
- **A fenced writer had no release.** A rename stopped after its fence stage left the old writer at zero replicas under `nagare.dev/migration-fence`, which parses as its retained incarnation, so no review released it.
- **Definite failures were ambiguous.** A 4xx refusal of a stage write and a transfer the copy script refused ("source volume is empty") were classed ambiguous or safe to retry, so resume retried forever and close refused.

**Fix (this commit).**
- `inventory abandon-migration TX --review DIGEST` (`Execute/Abandon.hs`): refused once the destination's own writer may have started (`migration-past-return`). Otherwise it releases this operation's writer fence and backup-schedule suspension, preconditioned on the reviewed incarnation's UID and resourceVersion (`kubernetesMigrationExit`). An object the stage never fenced, or a replacement of it, is left as it is. It then marks unfinished stages abandoned and ends the transaction through close's record. It deletes nothing and is re-enterable.
- Close reverts every scope of a migration that did not complete all its stages, and refuses `migration-fenced` while a fence stage ran and the migration has not finished.
- A stage write refused with a 4xx (G4) is a refusal with no effect; a transfer Job's own Pod (controlled by the Job's UID) that ended Failed with the script's message is a definite failure. Anything unobserved stays ambiguous.
- The rename test world answers refusals as the API server does (`Error from server (Conflict|AlreadyExists|NotFound)`, RES-4 U4).

**Tests.**
- The F62 rename model ("a source replaced outside review at any read of it is never copied unreviewed, and rebind then rename is its exit (F62)"): resume, close, then abandon; a database that was not renamed never keeps a fenced writer or a suspended backup schedule. A rebound empty source cannot be renamed (the copy script refuses it), and its clean abandon is the exit.
- "abandon-migration releases a rename's fence after its copy is refused, and accepts and deletes nothing (F81)": the CLI path on the target store.
- "abandon-migration leaves a writer it did not fence as it is, so a replacement is never released (F81)".
- "a stage write the API server refuses with a 4xx stops the rename with no effect, not ambiguous (F81, G4)".
- The write-fault rename model (kill at the copy Job, then resume) stays green.

**Mutation records.** `F81-close-accepts-incomplete-migration`, `F81-close-ends-fenced-migration`, `F81-failed-transfer-ambiguous`, `F81-release-ignores-incarnation` and `F81-stage-refusal-ambiguous`, each failing its focused test. The F62 model alone does not kill the last one, because abandon-migration also ends an ambiguous stage; the first sweep showed that.

**Pinned, pending the follow-up candidate (operator, 2026-10-07: land now, fix next).**
- **E2**, reads 102, 103, 104, 106 and 111, both variants: the writer is replaced around its fence by a copy carrying this operation's fence. Abandon releases only the reviewed incarnation, so the replacement stays fenced. Planned exit: after abandon, the documented rebind records the replacement, then a reviewed release of the fence naming this operation on the recorded writer.
- **E3**, reads 112–124, both variants: the source is replaced after the destination writer's creation began. Abandon refuses past that point, and the remaining stages still require the source incarnation. Planned exit: after the transfer verified, the remaining stages no longer require the source, and RetainSource retains what is present.

**Deferral candidate D1 (operator decision pending).** After an abandoned or reverted rename, the destination objects its completed stages created block the next rename to that name ("rename destination address is not confirmed absent"). The old database is accepted, running and backed up. Schedules: reads 93–101, 105 and 107–110, both variants (28 schedules, pinned as `d1Schedules`). Manual exit: [inventory-operations](../../runbooks/inventory-operations.md#leftover-destination-objects-block-the-next-rename-d1-deferred).

**Independent verification (2026-10-07, nagare-verify; observed).** Fix landed in `2df33205`: green gate, and a sweep of 127 killed with 0 surviving. The landed parts are abandon-migration, the close revert of an incomplete migration, the `migration-fenced` refusal, and the definite-failure classes. E2 (a writer replaced by a copy carrying this operation's fence) and E3 (the source replaced after the destination writer's creation began) are pinned and owed by the follow-up candidate, by operator decision (2026-10-07). D1 goes to the deferral ledger with its manual runbook exit. Stays Verifying until E2 and E3 land and the final C2 confirms a normal rename natively.

**Implementation update, E2 and E3 (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).** Both pins are removed; the F62 rename model has no violation outside D1.
- **E2.** abandon-migration releases a fence on the writer's *recorded* incarnation, which is the reviewed one until a reviewed rebind records a replacement. Run again after its close, it releases a fence that still names this migration on that recorded writer. It never trusts a copied annotation on an unrecorded object: "abandon-migration leaves a writer it did not fence as it is" still holds. The model's exit is status, rebind, abandon-migration again, then the rename.
- **E3.** RetainSource retains the source present under this context's stamp, a replacement included, and a writer or schedule that is either this migration's fenced one or a replacement; status reports a replacement truthfully. The destination writer's create accepts a stamped source too. Stages that protect the copy (BackUpSource, FenceWriters, TransferState) still require the reviewed incarnation.
- **The point of no return** is now the destination writer's SwitchConsumers, AdmitWrites or RetainSource stage, not its creation. Within a migration no consumer is switched before those, so the destination holds only the copy. The model showed the old cutoff stranding a rename whose destination writer was created before the volume's transfer (reads 111–120); those now end by abandon-migration.
- **D1** grows to reads 93–107 and 111–120, both variants (50 schedules): each such rename ends abandoned or reverted with the old database running and its leftover destination objects in place.
- **Records:** `F81-E2-release-ignores-record`, `F81-E2-no-release-after-close`, `F81-E3-retention-requires-source-incarnation` and `F81-abandon-cutoff-at-destination-writer`, each through the F62 model.

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The source fix is in `2df33205` and `3ae20f8c` (E2, E3), with the F62 rename model green except the pinned D1 schedules. Natively, the runbook execution on `mp23-c3j` renamed a disposable PostgreSQL, killed it at its copy Job, and ran `inventory abandon-migration`. The writer went from replicas 0 under the fence back to 1, unfenced, with the same UID, and the seeded row was intact. The four leftover destination objects remain (D1, deferral ledger, manual runbook exit). C2 and C3 renames converged with their members recorded. Evidence: [runbook execution](../mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/) (`abandon-migration`).


## F82

**The no-data-loss drill (checklist section 2) has no documented procedure: the guide places full restore after total cluster loss outside this release** — P1 (it blocks section 2, before real company data); **Closed**; owner session nagare-fix (MP-23 step 5).

**Found by the independent verification (2026-10-07, nagare-verify; observed in the docs at `a7958867`).**
- `docs/user/backups-and-disaster-recovery.md` says "A full restore after total cluster loss remains outside this release's accepted evidence".
- The same guide's "disaster-recovery runbook (target)" is the pre-inventory `nagare-01` flow (`pulumi up`, `just cluster-bootstrap`).
- The checklist's drill needs a documented procedure: real data in an application and a database; destroy the cluster; restore from the off-cluster backups; verify the content; record the time.

**Operator decision (2026-10-07, asked by nagare-verify):** scope A now, scope B to the next MasterPlan.
- **A, this release.** A documented, timed drill that restores from the off-cluster backups into disposable engines and verifies the content. It is built from what already exists:
  - the C2 and C3 source-unavailable drills (`phase3-su.sh`, `su-drill.sh`);
  - `db escrow-signing-key`;
  - `db verify-escrowed-backup` with `--escrow` and the object store only (F41);
  - an exact archive restored into a disposable PostgreSQL, with the rows compared.

  The operator rejected a multi-day plan, so A is a docs rewrite of the DR procedure plus the cloud drill run by the verifier. It adds no new command.

  Volumes are outside the recovery objective by decision D2 (2026-10-03). Recovering data needs the escrowed key, the age key and the backup bucket, all kept in the private operator repository (ADR 13); generated service passwords are not needed to restore a dump into a new engine.
- **B, deferred to the next MasterPlan: a reviewed rebuild of the same context with restore into it ("usable service").** It needs:
  - an exit for an accepted durable member that is absent (`durable-resource-missing` refuses even `platform bootstrap` on a rebuilt cluster);
  - restore authority across incarnations (ADR 27 N12);
  - restore and ingestion without live producer Jobs;
  - credential re-supply at create;
  - promotion of a scratch restore to live (EP-160's deferred `--into-live`).

  Until then, "usable service after total loss" is a documented limit.

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).** Scope A's docs:
- `docs/user/backups-and-disaster-recovery.md`: "Total cluster loss: recover the data" replaces the pre-inventory "disaster-recovery runbook (target)" and "Drill it". It covers the prerequisites (hourly objective, escrow per database, private material off the machine); detection (`server status`, `doctor`, `db backup-receipts --check-freshness`); and recovery from a fresh operator root: `db verify-escrowed-backup --escrow` against the bucket (or `--offline-object-store` in local mode), fetching the exact archive version, checking its SHA-256, restoring into a disposable engine, comparing the content and recording the times. It states the known limit: no reviewed rebuild-in-place with live service. "Rebuilding the host" keeps the VM and disk guidance. The recovery-archive paragraph now names the three things data recovery needs, kept in the private operator repository.
- `docs/runbooks/disaster-recovery.md`: its pre-inventory rebuild sequence is replaced by a pointer to that procedure and the limit, and its freshness note now describes receipt-graded freshness.
- Left for the verifier: the escrow section's sentence placing full restore outside this release's accepted evidence, to be edited with the cloud drill's evidence.

**Verification.** Pending the procedure docs and the section-2 drill on the C3 cloud context.

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed (scope A, operator 2026-10-07). The section-2 drill on `mp23-c3j` followed the documented total-loss procedure. The VM, data disk and snapshots were deleted. A fresh operator root holding only the context profile, the escrow files and the sops rules verified the newest post-seed backup with escrow and GCS alone, fetched its exact generation (SHA-256 matched) and restored it into a disposable PostgreSQL 18 with `ON_ERROR_STOP=1`. All 4 rows, including the seeded one, matched. Recovery took 20 s. Scope B (rebuild in place) belongs to the next MasterPlan. Evidence: [section-2 drill](../mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/).


## F83

**A reviewed retirement whose review proves a Kubernetes member absent always refuses through the CLI, so close-kept scopes and stopped first deploys cannot be retired** — P1; **Closed**; owner session nagare-fix (MP-23 step 5, follow-up candidate).

**Found by the C2 discovery run on `a7958867` (2026-10-07, nagare-verify; observed). Root cause by nagare-fix (read-only, from the same evidence).**
- **Observed.** After the F36 drill, close kept the scratch Redis restore scope `database-restore-personal-scenario-redis-c2f36r`, as ADR 26 says. `inventory retire --scope standalone:…-c2f36r` planned retentions for the live service, pvc and statefulset, and an absence proof for the missing job. `inventory apply` then refused at admission with `retention-observation`: "a reviewed incarnation could not be reverified: a resource reviewed as absent is present or unobserved" ([log](../mp23-independent-results-2026-10-07/c2-discovery-a7958867/f83-retire-database-restore-personal-scenario-redis-c2f36r.log)). The rebind route is no exit either: its review re-plans the unconverged scope, and prepare refuses the not-ready StatefulSet.
- **Cause.** The CLI execution registry (`app/Nagare/Cli/Inventory/Execution.hs`) binds native bytes for retentions, collections and rebinds, never for the review's absences. Admission re-observes an absence through that registry, gets `ObservationUnavailable`, and refuses. This holds for every Kubernetes absence proof applied through the CLI.
- **Consequence.** F58's fix, the retirement of an application whose first deploy stopped unready, has never worked through the CLI. Its tests use a registry that observes everything. Close-kept scopes cannot be retired, which blocks C2's evidence assembly (accepted must equal converged) and every staged teardown that retires all scopes.
- **Fix plan (nagare-fix).** Bind absences in the execution registry (`Status.loadAbsenceNative`). Make the recovery model apply retirements through a registry shaped like the CLI's, which is the class-level reason both were missed. Add tests through the CLI execution path: a terminal-partial scratch restore, then close, retire and collect; and F58's stopped first deploy, then close and retire. One mutation record must fail all of them.

**Implementation update (2026-10-07, session nagare-fix; claude-opus-5-5; landed in the commit that adds this entry).**
- **Fix.** `Status.loadAbsenceNative` loads the accepted native bytes of every Kubernetes member a review proves absent, and `inventory apply`'s execution registry binds them (`app/Nagare/Cli/Inventory/Execution.hs`), as it already did for retained, collected and rebound members. Admission's absence recheck now observes those members through the production adapter: absent passes, present or unobserved refuses as before.
- **Other fields.** Admission observes exactly four review fields through the registry: retentions, collections, rebinds and absences. Absences were the only one the CLI did not bind. Migrations are checked statically at admission, and their stages observe through their own bundles; barriers observe nothing.
- **Why the model missed it, and the class-level regression.** The recovery model applied every review through a registry that bound all of the scope's members, more than the command binds. Its retirements (`retireAndApply`, `scopeRetireAndApply`) now apply through `retirementRegistryFor`, which binds only what `inventory apply` binds for a retirement: the retained, rebound and absent members from their accepted bytes (`test/Nagare/Test/Model/Run.hs`).
- **Mutation record.** `F83-absences-unbound-at-admission` binds no absent member. The fast tier then fails with 6 violations, each `admission refused: retention-observation`, the native refusal. The schedules are F58's class: "create with a durable volume, then retire" and "create a database, then retire it", with `LandsUnready`, `LandsFailed` or `ControllerLag` on the first deploy's create, so the first deploy stops, closes, and the retirement proves its never-started members absent.
- **Limit.** No test drives the scratch-restore scope itself (terminal partial, close, retire, collect). Its retirement reaches the same path: an absence proof for the Job, admitted through `loadAbsenceNative`. The next C2 confirms it natively.

**Verification.** Pending the follow-up candidate and its C2.

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Closed. The source fix is in `0d828d50`. Natively, C2 on `3ae20f8c` retired all three close-kept scratch-restore scopes directly: `c2pgr2` (1 retained), `c2f36r` (3 retained, 1 absence proof) and `c2redr2` (1 retained, 3 absence proofs), leaving accepted equal to converged (45). On `mp23-c3j` the runbook's joint retirement of application B with its Redis backup and restore scopes converged too. Evidence: [C2 evidence](../mp23-independent-results-2026-10-07/c2-acceptance-3ae20f8c/) (`retire-kept.log`).

