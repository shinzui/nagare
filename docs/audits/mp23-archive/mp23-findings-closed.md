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

## F36

**A failed Redis scratch restore cannot be abandoned and wedges the store** — P1; **Closed**; owner EP-160.

**Implementer source evidence (2026-10-03, claude-opus-5-5):** A Redis isolated restore creates a scratch Service, PVC, StatefulSet and verify Job. If the StatefulSet's `download` init container fails, its pod never becomes Ready and apply stops ambiguous after the readiness wait. Examples are a pinned version that becomes unreadable after review, or an RDB load failure. On `inventory recover`, `Adapters/Kubernetes.hs` returned `RecoveryUnresolved` for any NotReady StatefulSet (terminal failure was proved only for Jobs), and `Execute/RecoveryPolicy.databaseRestoreOnlyReview` accepted only Job-only reviews. Neither resume nor recover could end the transaction. The trace comes from the 2026-10-03 restore-path research for the cp3 drills; no native reproduction was run, because forcing it destroys a backup's pinned version.

**Implementation update (2026-10-03, `6d7951c9`; claude-opus-5-5):** Kubernetes recovery asks a new runtime probe (`Nagare.Inventory.Adapters.RestoreScratch.restoreScratchPodFailed`) whether a pod controlled by the exact scratch StatefulSet UID has a container that exited non-zero, now or before a restart. Only StatefulSets labelled `nagare.dev/restore-scratch` qualify. A proven failure becomes `RecoveryTerminalFailure`, and `abandon-partial-database-restore` also accepts an exact Redis restore-only review (`redisRestoreOnlyReview`). The scratch objects stay unaccepted for separate reviewed recovery. `test/InventoryRedisRestoreRecoverySpec.hs` covers the pod-list cases (owned failure, success, foreign owner, empty and malformed lists), the abandonment, and the refusal of a review with an extra member. All 1,165 tests and the gates pass. Remaining: a native run on a disposable context (C2) that removes a throwaway backup's pinned version after review, plus independent review.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint on a fresh cp3 context; nagare-phase-b):** Throwaway backup `c2f36` of `scenario-redis`; restore review `3a34ab21…` saved; exactly the pinned archive version `80ab0c9b…` deleted with a throwaway `nagare-mc` Pod. Apply stopped ambiguous after 5 min with the scratch StatefulSet's `download` init container in CrashLoopBackOff (`HeadObject … 404`). `inventory recover … abandon-partial-database-restore` closed the transaction; the scratch Service, PVC and StatefulSet stayed unaccepted and the store went idle with accepted equal to converged ([record](../mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json)). Remaining: independent review.

**Acceptance C2 on `14071e58` (2026-10-03, nagare-phase-b):** Reproduced natively on the frozen candidate: the pinned-version deletion again ended in `abandon-partial-database-restore` with the store idle ([record](../mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read (`6d7951c9`). The owner-UID mutation fails the pod-list regression ([phase-1 record](../mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). C2 native evidence: pinned version `f86d4522` removed, the apply stopped ambiguous with a download 404, and `abandon-partial-database-restore` closed it. Independent live read: the journal of `tx-99394208…` holds seq 1333 Ambiguous and seq 1334 OperatorResolved for StatefulSet `88ee069d`; the scratch objects remain unaccepted; the head is idle ([C2 evidence review](../mp23-independent-results-2026-10-04/c2-evidence-review-7596632c.json)). **Closed.**

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
