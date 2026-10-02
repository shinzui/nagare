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

[The 2026-10-02 prerelease fixture disposition](mp23-prerelease-fixture-disposition.md) removes recovery of retired development attempts from acceptance. Findings still require verification of the supported candidate behavior; retiring a fixture does not close a product defect. Historical exact-fixture verification instructions may be fulfilled by equivalent candidate-bound scenarios without reviving retired state.

- IDs never change or disappear. Include IDs in implementation handoffs and fix descriptions. New findings get the next ID.
- `Open`: fix not established. `Partial`: some cause remains. `Verifying`: a candidate fix exists but closure evidence is incomplete. `Closed`: an independent check proves the stated failure corrected and the required regression evidence is retained. Reopen on failed verification.
- The implementation session updates each **Implementation update** with revision (or exact working-tree source hashes), change, named test/command, result, and remaining limitations. It must not overwrite the auditor's evidence or close its own finding.
- The verifier updates status and **Verification** after checking the affected path. A sent message, acknowledged finding, source edit, test count, or passing unrelated suite is not closure.
- Before advancing an affected native rehearsal, reconcile its P1 findings. Scope reductions do not waive recovery for already-admitted operations. Deferral/dispute requires an explicit reason recorded here; do not silently omit the issue.
- At every handoff, state IDs still Open/Partial/Verifying and the next required check.
- Safe-use verification policy (operator instruction, 2026-10-02): an independent reviewer executes the technical runbook on the selected eligible candidate context and records results here, including F14–F18 and cloud operational checks. Operator-run technical verification is no longer a gate. Ask the operator only for genuinely unavailable access, product-scope decisions, actions outside existing authorization, and final production go/no-go. Release acceptance keeps the closure rule above for every remaining finding.
 Link durable evidence in the repository; temporary reproduction paths are supplemental. If sessions end, the next implementer reads this file through the MP-23 entrypoint.

## Status register

| ID | Priority | Finding | Status | Child owner |
|---|---|---|---|---|
| [F01](#f01) | P1 | Host execution mutates after observing a different VM or old closure | Closed | EP-156 |
| [F02](#f02) | P1 | Active transaction status still reads journal entries individually | Closed | EP-156 |
| [F03](#f03) | P2 | Resume loads the same complete journal twice | Closed | EP-156 |
| [F04](#f04) | P2 | Native evidence loads every historical review and can repeat the scan | Partial | EP-156 / EP-153 |
| [F05](#f05) | P1 | New fresh-login checks can reuse an SSH multiplexed connection | Closed | EP-156 |
| [F06](#f06) | P1 | Journal appends retain excessive serial cloud-command cost | Partial | EP-156 |
| [F07](#f07) | P1 | Installed key with failed service activation cannot recover by retry | Closed | EP-156 |
| [F08](#f08) | P2 | Unchanged host bootstrap depends on transient key-file environment and source root | Partial | EP-156 |
| [F09](#f09) | P1 | Scheduled-prune preflight prevents recovery after admission | Verifying | EP-159 / EP-153 |
| [F10](#f10) | P2 | Explaining one resource observes the whole context | Verifying | EP-153 |
| [F11](#f11) | Build | Conditional-upload optimization has ambiguous try exception type | Closed | EP-156 |
| [F12](#f12) | P1 | A later operation’s preflight blocks recovery of its ambiguous prerequisite | Verifying | EP-153 / EP-159 |
| [F13](#f13) | P1 | Ordinary executor recovery has no terminal-failure branch | Verifying | EP-153 / EP-159 |
| [F14](#f14) | P1 | Initial Knative activator readiness blocks its uncreated autoscaler | Verifying | EP-156 |
| [F15](#f15) | P1 | Patched certificate controller lacks refreshed private-image credentials | Verifying | EP-156 / EP-154 |
| [F16](#f16) | P1 | Unready application creation cannot yield to a corrected reviewed configuration | Verifying | EP-153 / EP-156 |
| [F17](#f17) | P1 | Effect-free retirement discards required native identity observations | Verifying | EP-153 / EP-156 |
| [F18](#f18) | P1 | Initial GCS foundation transaction cannot resume its local journal | Verifying | EP-153 / EP-156 |
| [F19](#f19) | P1 | Rendered pinned GCS restore omits download generations | Verifying | EP-160 / EP-156 |
| [F20](#f20) | P1 | Knative collection cannot orphan controller descendants | Closed | EP-153 / EP-156 |

F01 and F11 retain their [earlier independent closure](mp23-verification.md). F02, F03, F05, F07 and F20 now have [2026-10-02 independent closure](mp23-independent-verification-2026-10-02.md). Other entries retain their status shown above.

## F20

**Current disposition (2026-10-02):** Independent candidate-bound verification is complete; status is Closed. Earlier Open/frozen statements below are dated observations. The old F15 exception is withdrawn from the work queue; preserve its proposal only as diagnostic history.

**Knative collection cannot orphan controller descendants** — P1; **Closed**; owners EP-153 / EP-156.

**Native evidence:** Installed `4c4b667e` changes only Application B's history lifecycle, retires eleven exact incarnations without mutation, proves premature Service collection refuses without changing the head, then collects history separately. Review `b6886179d40d4618442997221cc02ca986f142ccdeef1661448cfca627765472` issues its conditional Service deletion once but stops ambiguous after 45.124 seconds. UID `80560c4d-6bd8-4fe4-9c55-e67620554924` remains terminating with finalizer `orphan`. k3s logs show garbage collection cannot orphan its Route/Configuration: Knative validation refuses missing `metadata.labels.serving.knative.dev/service`. Generation 752/sequence 673 keeps the original transaction, no claim/fence and nine retained B database incarnations. Source/neighbor rows and UIDs remain exact. [Evidence](mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json) also records the earlier helper guard failure/reconciliation.

**Implementation update:** The public `--knative --retain-data` fixture fails on the installed candidate at Service collection. Adding `--expect-orphan-block` models accepted deletion with a pending finalizer and passes, preserving the original transaction and retained Service/data UIDs plus an independent neighbor. No production cascade fix is claimed. The Service declares no controller delegation; changing Orphan to Background would broaden deletion authority. [The unexecuted exception proposal](mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json) binds exact head/review/operation, parent UID/resourceVersion, sixteen descendants across all listable namespace APIs and nine protected database UIDs. No finalizer patch, blind resume, new build/admission or history reset followed the failure.

**Local interpreter evidence (2026-10-02):** [Eight F20 scenarios](mp23-effectful-collection-proof.md) now use the real planner, lifecycle review, filesystem journal and Kubernetes runtime with persistent parent/descendant state. They prove pending-finalizer recovery without a duplicate DELETE, exact UID/version races, preserved data, and no false convergence from wait success. The combined 14-test interpreter suite takes 2.55 seconds. The existing public pending-Knative fixture passes through real subprocess execution with local shims. Eventual orphan completion is an explicit modeled external event, not a live workaround. No cascade policy changes; F20 remains Open.

**Reviewed source contract (2026-10-02):** [The new local checkpoint](mp23-reviewed-controller-collection-proof.md) adds explicit `--controller-descendants` authority, a distinct adapter identity and descendant-aware recovery. Eleven new scenarios bring the focused suite to 25 passing tests in 3.79 seconds; all 1,042 CLI tests and both public Knative variants pass. Existing reviews keep Orphan semantics. The Background grant covers dynamic exclusive descendants; namespace observations are not atomic deletion bounds and assume trusted controllers/writers. F20 stays Open until native agreement and independent verification; the frozen transaction is unchanged.

**Recorded agreement (2026-10-02):** [Eighteen additional production-path scenarios](mp23-reviewed-controller-collection-proof.md#recorded-native-graph-agreement-2026-10-02) consume sixteen recorded descendants and seventy-five discovered APIs through the same interpreter. They expose and fix silent omission of persisted objects without UIDs, cover ownership/completeness/unexpected-descendant refusals and fresh-process recovery, and enforce 78/233/78/0 kubectl-call budgets for prepare/pending apply/resume/terminal replay. The combined interpreter suite passes 43 tests. This is metadata/model agreement, not native GC or independent closure; F20 remains Open and the frozen exception remains unexecuted.

**New-review native agreement (2026-10-02):** [Installed `8a820ce8` now passes the bounded native proof](mp23-reviewed-controller-collection-proof.md#native-controller-and-recovery-agreement--2026-10-02) on a separate disposable ep150 Service. Three real-response mismatches were reproduced/fixed locally; all 1,064 CLI tests pass. All 75 APIs bind 17 descendants and 41 protected objects. Interruption after the accepted Background DELETE preserves the original transaction; pending resume correctly refuses while the Pod completes its normal 300-second grace, final resume converges without a duplicate DELETE, and terminal replay uses zero kubectl calls. All 125 original identities, both database rows and 27 original revisions remain exact. Frozen F15 head remains byte-identical; its cascade exception is neither authorized nor executed. This supplies native agreement for new reviews, not independent closure or native same-scope retained-database coverage.

**Required verification (revised 2026-10-02):** Independently verify corrected reviewed descendant collection, accepted-response interruption, original-transaction recovery without duplicate DELETE, and retained-data preservation on the candidate. Retain the existing separate native proof and finish its missing same-scope retained-database assertion. Under [the operator disposition](mp23-prerelease-fixture-disposition.md), the old F15 transaction is retired from acceptance: its cascade exception, recovery and teardown are not closure requirements. This is a scope disposition of a development attempt, not successful recovery or independent closure of the product defect.

**Recovery request validation:** Live server `v1.35.8+k3s1` accepts the exact UID/resourceVersion-bound Background DELETE with server-side `dryRun=All`; parent UID/resourceVersion/orphan finalizer and the head remain unchanged. The exception review records upstream custom-resource/generic-store sources and this dry-run. The request lets the API server adjust its GC finalizer; it excludes manual finalizer patches. Dry-run acceptance does not prove actual parent/descendant finalization, and no exception mutation has run.

**Independent verification (2026-10-02):** Installed `8a820ce8` independently passes the complete same-scope native scenario on eligible `ep150-preview`: exact policy review, foreign-UID retirement refusal, effect-free retirement of eleven members, separate history collection, one reviewed Background parent DELETE interrupted after server acceptance, fresh-process original-transaction recovery with no repeated DELETE, and zero-kubectl terminal replay. All 75 APIs are observed; parent and sixteen descendants are absent; 35 protected objects and all nine retained same-scope database resources survive. The source and retained-database rows remain exact, and 26 unselected revisions remain unchanged. Final generation 767/sequence 653 is idle. An additional uninventoried ownerless Endpoints sharing a reviewed descendant Service name disappeared; the proof does not claim an atomic namespace UID boundary. Same-root recovery is not a foreign-client takeover claim. Earlier pending-GC native proof plus independently rerun 47 interpreter scenarios retain that boundary. Retired F15 was never accessed. [Independent proof and limits](mp23-independent-verification-2026-10-02.md), [redacted native evidence](mp23-independent-results-2026-10-02/native-same-scope-collection.json). Final release-candidate binding remains a separate EP-157 gate.

## F19

**Rendered pinned GCS restore omits download generations** — P1; **Verifying**; owners EP-160 / EP-156.

**Native evidence:** Installed `8b6cb730` accepts the primary manual receipt and separately collects its Job. The Job-free `mp23f15pgav2` review creates Job UID `6406eaef-6d37-482c-aea6-504d4ab21102`, but `download` fails because the receipt address ends in `#`: the rendered environment omits both pinned generations. PostgreSQL never starts. Exact terminal recovery preserves the failed Job and returns history to idle generation 722/sequence 654. [Evidence](mp23-native-bootstrap-results-2026-10-02/f15-receipt-collection-and-download-failure.json) includes exact review/source identities.

**Implementation update:** Add both version variables for GCS verified sources. Strengthen the public GCS fixture to execute the rendered init-container script with only its declared environment, strict generation-qualified GCloud copies, actual receipt/archive hashes and a valid gzip SQL archive. Installed `8b6cb730` fails the new public regression; the source fix passes and verifies decompressed SQL. Both receipt fixtures, web cleanup fixture, all 1,017 CLI tests (54.00 seconds), compilation and Haskell style pass. Installed repair, native restored rows and independent closure remain pending. The fixture still does not execute PostgreSQL. Terminal abandonment preserves the failed native Job without making it an accepted/retained member; cleanup remains separately reviewed work.

**Installed follow-up:** Installed `4c4b667e` passes its local 213-verification gate and rendered GCS fixture. Job-free native restore converges in 34.101 seconds with completed UID `13f19521-86a2-4389-9b47-5e652769ec62` and the backed-up row. Source/neighbor rows and original physical identities remain exact; v2 database is absent and failed Job preserved. [Proof](mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json) separates this accepted restore from F20. Independent F19 closure stays open.

**Required verification:** Verify the new immutable installed candidate and local gate, then restore from the same accepted GCS versions after producer Job removal into a fresh isolated destination. Check known backed-up rows, later live source/neighbor rows and unchanged physical UIDs. Preserve the prior failed Job and original history. Independent verification is required for closure.

## F18

**Initial GCS foundation transaction cannot resume its local journal** — P1; **Verifying**; owners EP-153 / EP-156.

**Native evidence:** Immutable `d73c1dc4d3790c980be877f42cb68ea32b7575bd` plans the disposable `f15-preview` foundation review `03deb235a67fd7576e66248c1867ba317ced759d60d3dff1394a1b747d6aa6c5`. Apply creates and verifies only its new state bucket, then stops before the Pulumi stack mutation with `KnownNoEffect "adapter preflight refused"`. The local generation 6/sequence 3 head retains the exact original transaction, without a claim or migration. Generic public resume refuses in 0.156 seconds with `local inventory history exists; migrate it before selecting the GCS store`. Store status also refuses the uninitialized remote prefix. A later exact read-only Pulumi stack listing succeeds; the original transient preflight cause remains unproved. No VM or subsequent platform resource has been created.

**Implementation update:** The candidate routes public resume through read-only foundation authority discovery. Remote ownership, complete prefix, context/project and migration guards remain authoritative. A local fallback requires the exact active transaction and published payload-bound initial review: empty base, exactly `platform:cloud-foundation`, unchanged accepted revision vector, and only foundation executor operations. Other local histories refuse. Resume retains its existing immutable-input and execution checks; migration occurs only after convergence. The complete source CLI bootstrap fixture passes, including stopped initial GCS recovery with one bucket creation, one stack initialization and preserved migrated journal, plus a legitimate unrelated active transaction refusal with exact unchanged head and no Pulumi call. Immutable `d73c1dc4` fails the new regression at the original migration refusal, confirming the consumer counterfactual. Source CLI compilation and structural style pass. [Exact candidate identities and evidence](mp23-native-bootstrap-results-2026-09-30/foundation-initial-gcs-recovery-candidate.json) are retained. Installed native recovery verification remains pending.

**Installed follow-up:** Immutable `cf269e72` builds and passes the complete installed CLI bootstrap fixture. With the original `d73c1dc4` payload and review selected, native resume converges in 38.282 seconds and migrates to the configured GCS prefix. The idle shared generation 11/sequence 6 head has its sole foundation scope accepted and converged, without claim or fence. Public export proves the unchanged original review and all three original journal entries migrated byte for byte. The complete journal has one bucket-create intent and one stack-create intent; the completed original bucket operation is not replayed. [Installed native proof](mp23-native-bootstrap-results-2026-09-30/cloud-initial-gcs-foundation-recovery.json) retains the exact boundaries. The operator-requested stopping point is reached before VM creation. Independent closure and fresh-host steady credential acceptance remain open.

**Required verification:** Reproduce a stopped first bootstrap configured for GCS, resume its original review without repeated bucket creation, and preserve the complete original journal during migration after convergence. Refuse a legitimate unrelated local active transaction without changing its head or invoking its provider. Verify the immutable installed operator against the original native transaction and retain exact source/build/evidence identities. Independent closure remains required.

## F17

**Effect-free retirement discards required native identity observations** — P1; **Verifying**; owners EP-153 / EP-156.

**Native evidence:** Installed `2101b834882a31a77036103b00c03b9a9cc07019` saves Application C retirement review `164d1a480405e5a2274b5f0e6fca564bf765cf428076b71e0eb963da4d624ace` in 21.180 seconds. It has zero mutation operations and exactly two retention proofs, bound to the accepted Service and release-history UIDs. Public apply refuses after 4.810 seconds with `retention-observation`; the exact generation 698/sequence 615 head remains unchanged. No transaction or deletion is admitted.

**Implementation update:** The runtime already loads the retained resources' accepted immutable native inputs, but then restricts them to mutation-operation IDs. A zero-operation retirement therefore constructs blocked observation adapters. Preserve the exact retained Kubernetes and Helm input keys alongside selected operation/source keys; do not broaden the input set beyond the immutable review's retention/collection members. The source CLI builds; six focused retained regressions pass (4.15 seconds), along with structural style and command registration. A development-binary public-path diagnostic refuses an injected foreign UID in 10.201 seconds and preserves the exact head, then admits the original saved retirement review in 14.013 seconds. All other 28 accepted/converged revisions, application/database/PVC UIDs and data remain exact at generation 702/sequence 617. The Service and release-history object stay retained. [Exact source and native diagnostic evidence](mp23-native-bootstrap-results-2026-09-30/retirement-runtime-selection-candidate.json) is retained. Subsequent Service collection refuses its known retained release-history dependency; no delete or review is published. Immutable installed verification and eligible collection proof remain open.

**Installed follow-up:** Immutable `8482c2f2` passes its installed bootstrap fixture. Its exact no-operation retirement refuses a changed observed completed-backup Job UID without changing history, then accepts the original review while preserving the Job. A separate reviewed collection removes only that eligible Job. All other 27 scope revisions, application/database/PVC identities, data and backup receipt survive; the two Application C retained incarnations stay unchanged. [Installed retirement and collection proof](mp23-native-bootstrap-results-2026-09-30/cloud-installed-retirement-and-collection.json) records the idle generation 713/sequence 623 checkpoint. Helm-native and independent closure remain pending.

**Required verification:** Through the public apply path, prove the original saved retirement review reobserves both retained UIDs, refuses a foreign observed UID without changing the head, and admits unchanged exact identities. Preserve all other accepted/converged revisions, data, and native objects; retirement does not delete them. Prove subsequent collection separately. Record source hashes and executable-build identity, and repeat on the immutable installed candidate before independent closure.

**Verification:** Independent closure remains pending.

## F16

**Unready application creation cannot yield to a corrected reviewed configuration** — P1; **Verifying**; owners EP-153 / EP-156.

**Native evidence:** The cloud fixture has 2 CPUs, with 1,785m allocated after full bootstrap. Application A's default web pod requests 275m and cannot schedule, although its PostgreSQL pod is Ready and its retained PVC is Bound. Public saved apply stops after 365.186 seconds at `op-711f755156b69c10be13390c`. Generation 576 keeps the original application transaction without claim, fence or migration. Its review targets only its 11 owned resources; [redacted evidence](mp23-native-bootstrap-results-2026-09-30/application-capacity.json) preserves the review, identity and failure. No raw resize, patch, restart, review rewrite or history reset occurred.

**Implementation update:** A guarded `stop-incomplete-application` decision requires one changed Application scope, only unfenced owned Kubernetes creates, an originally absent stateless Knative Service proved owned and unchanged but unready, and no other uncertain operation. It journals selection before clearing the active transaction, retaining admitted ownership and prior converged revisions. It never completes the workload or rolls ownership back away from created retained data. The same decision settles a lost head acknowledgement without provider IO; ordinary proof cannot bypass a pending stop. A new application review can correct resource configuration. Knative conditional updates retain UID/resourceVersion and exclusive non-status ownership checks; installed update proof remains pending.

**Required verification:** Preserve unselected stopped applications' prior converged revisions when another scope completes. Prove created retained-data ownership survives stopping, foreign/durable/changed-native and multiple-uncertain refusals, exact decision replay after lost acknowledgement, and installed stop followed by a new corrected review. Require the same Service/PVC/database identities, Ready application and no platform revision change. Prove the Knative conditional update and unchanged replay through the public installed path.

**Verification:** The installed `0f6fa7db` stop passes in 12.441 seconds: all 24 accepted and 23 converged revisions and the original Service/PostgreSQL/PVC UIDs are preserved; generation 579 is idle. The corrected plan then refuses in 17.365 seconds at the original never-created backup signing key. [Redacted evidence](mp23-native-bootstrap-results-2026-09-30/application-stop-and-replan.json) retains this consumer result. The follow-up repair derives never-started create proof from the original immutable stopped review and validated committed journal, only for planning that selects its unchanged unconverged application revision. Previously completed, uncertain, changed and foreign durable members still refuse; ordinary inspection and unrelated planning do not scan execution history. The final CLI suite passes all 997 tests in 52.48 seconds, covering never-started creation, completed data refusal, later uncertain intent, foreign ownership, changed declaration, superseded revision, missing committed journal and inspection/unrelated planning isolation. Structural style and the managed-command audit pass. The installed public bootstrap fixture passes. Installed `49db2199` saves the corrected Application A review in 42.372 seconds and converges in 63.123 seconds: same Service/PostgreSQL/PVC UIDs, Ready Service, expected HTTP body and preserved seeded row. Only its accepted revision changes, with all 24 scopes converged at generation 605/sequence 539. [Redacted native proof](mp23-native-bootstrap-results-2026-09-30/application-correction.json) retains the original NotReady UID/resourceVersion precondition and actual consumer results. A follow-up real-planner regression reproduces a convergence leak: completing another application incorrectly marks a stopped, unready application converged. The repair advances only revisions changed by the completing review and removes retired scopes; it preserves unselected prior convergence. The eight focused regression cases and all 998 CLI tests now pass (60.14 seconds); structural Haskell style passes. Installed `eb582eb0` builds successfully. A second regression exposes unchanged stopped members being omitted while remaining creates complete; selected unconverged scopes now require fresh verification for unchanged managed members. Native preparation still refuses NotReady verification, while a corrected Knative configuration uses its guarded update. All 998 tests pass after this extension in 67.46 seconds, and structural style passes. Final installed validation and independent closure remain open.

**Installed follow-up:** Immutable `2101b834` builds on aarch64-darwin and passes the installed public foundation/bootstrap fixture. Its [cloud interruption and second-root proof](mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json) preserves every prior accepted owner and all application/database identities while recovering a separate backup without repeating its create. Its [installed stopped-readiness proof](mp23-native-bootstrap-results-2026-09-30/cloud-stopped-notready-verification.json) now confirms unchanged NotReady replan refusal without a review or head change, followed by a corrected conditional update retaining the Service UID. All 29 scopes converge at generation 698/sequence 615; original application/database/PVC identities and data remain intact. Independent F16 closure remains open.

**Implementation update (2026-09-30):** EP-153 adds a bounded fixed-seed in-memory driver model to the ordinary `nagarectl-test` suite. Planner-produced create/update/selected-unconverged-verification/retention-retirement reviews across two Application scopes interrupt each provider-effect boundary and resume with recording-adapter proof; stale conditional writes refuse without mutating the head, and a foreign executor claim requires explicit takeover. The model checks no duplicate effect, selected-only revision completion, accepted/converged consistency, monotonic head/journal state, and finite ambiguity recovery. Its stopped-scope assertion rejects the `eb582eb0` convergence leak; its unchanged selected member assertion rejects the `7c957c02` readiness-verification leak. The focused model test and all 1,002 CLI tests pass; structural style passes. This is source-only evidence and does not replace the operator's F16 runbook verification on `f15-preview`.

## F14

**Initial Knative activator readiness blocks its uncreated autoscaler** — P1; **Verifying**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs; Adapters/Kubernetes.hs; Execute.hs.

**Native evidence:** Installed candidate `6082dbd6aac0` admitted the original 210-operation review, then created activator before autoscaler. Activator's running pod cannot pass its healthcheck because the autoscaler websocket is unavailable; autoscaler's Service exists but its Deployment has not been created. Diagnosis occurred before the fifteen-minute checkpoint. The bounded rollout wait stopped naturally, retaining the original ambiguous transaction at shared generation 416 with no executor claim/fence. See [the continuation report](mp23-cloud-continuation-2026-09-30.md).

**Implementation update:** The candidate adds the autoscaler predecessor to pinned and configured Serving declarations. A new typed awaiting-readiness recovery result requires exact owned created Deployment bytes and an original absent precondition. The shared driver permits only an untouched, unfenced, dependency-ready stateless Deployment create from the same review, refusing other uncertain/blocked operations, durable members and non-Deployment effects. Each completion returns to fresh guarded recovery; only real readiness can complete the waiting operation. All 987 CLI tests pass, including `Knative activator waits for autoscaler readiness in pinned and configured inputs`, `only an exact created Deployment can await readiness during recovery`, `resume creates an independent Deployment while exact predecessor waits for readiness`, and `readiness continuation refuses dependent, durable and non-Deployment creates`.

**Required verification:** Independently run the named tests and inspect foreign/digest/failed-workload, data/fence, dependency and other-uncertain refusals. Install the candidate and resume this original cloud transaction without review/history rewrites; require autoscaler and activator Ready with exact original identities and no repeated completed effect. Retain redacted native evidence and source identities.

**Native implementation continuation:** Installed revision `0c757b7410b3cdf14cdaa026cd2ca9b6f6427de2` resumes the original transaction and creates the original-review webhook/controller/autoscaler Deployments. They become Ready. The original activator Deployment and pod UIDs remain exact; its normal container restart leaves it Ready. The second resume records its adapter completion at sequence 372, then proceeds to the private certificate controller. The transaction stops there on an independent image credential failure (F15), at generation 469 with no claim/fence. See [the redacted native continuation](mp23-native-bootstrap-results-2026-09-30/readiness-continuation.json).

**Verification:** Not closed. Installed/native readiness recovery is now retained; independent closure remains required. The subsequent installed registry recovery resumes the same original transaction to full bootstrap convergence; steady credential coverage and independent F15 closure remain open.

**Implementation update (2026-09-30):** The [installed local candidate gate](mp23-native-bootstrap-results-2026-09-30/local-platform-candidate-705716b7.json) runs full native bootstrap with CLI/payload `705716b7`, rather than only the recording marker fixture. Autoscaler is Ready before activator, all 217 platform operations converge through the public driver, all 19 scopes are idle/converged, and the final marker names the candidate. A transient certificate readiness result settles through resume of the retained transaction. An unchanged replan contains 213 verification-only operations and no barriers. This proves the corrected fresh-bootstrap order locally; F14 safe-use Verification remains the operator's end-to-end runbook on `f15-preview`.

## F15

**Implementation update (2026-09-30, F15 pre-review boundary):** Installed CLI `705716b7` passes the full native local platform-bootstrap gate and preserves the retained F15 `d73c1dc4` payload identity. Its prerequisite public shared-store status refuses with `StoreConditionFailed "gcloud credential or ownership command failed or timed out"` under configuration `labs`; cloud preparation stops at the guard, before a VM review or mutation. Restore that successful guarded read before the bounded cloud rehearsal. This supplies no new credential-expiry/re-pull evidence; operator Verification remains pending.

**Patched certificate controller lacks refreshed private-image credentials** — P1; **Verifying**; owners EP-156 / EP-154.

**Locations:** nixos/hosts/nagare-01/registries.nix; bootstrap private certificate-controller Deployment and ServiceAccount declarations.

**Native evidence:** The original saved bootstrap creates `net-certmanager-controller` in `knative-serving`; its private Artifact Registry image receives a 401 token response. The accepted host supplies boot-only k3s registry credentials, which have expired. Its recurring Secret policy covers `personal` and `nagare-system` default ServiceAccounts; this controller uses the `knative-serving` controller account. The bounded rollout stops naturally after 436.558 seconds. Shared generation 469 retains the same original transaction with no claim/fence. Serving and public-image certificate webhook workloads are Ready.

**Implementation update:** A bounded explicit registry recovery candidate passes all 992 CLI tests, the public foundation/bootstrap regression, registration/injected-mutation audit and structural style checks. Named regressions include `bounded registry recovery journals intent and requires actual workload readiness`, `registry recovery binds completed host history and original private Deployment`, `registry unit recovery preserves landed phases across expiry and settles ready workloads`, and strict intent/receipt parsing. It saves the original Deployment/host/unit proof separately, journals intent before replaying only the accepted registry bootstrap unit and k3s service, and retains independent Deployment readiness as the completion criterion. Installed `39842f8058bdaaf94819365b1f2511a3a7147246` runs this public recovery in 101.552 seconds and proves the original Deployment/pod Ready. Public original-review resume converges in 230.454 seconds at generation 549, with no active transaction, claim, fence or migration; all accepted/prerequisite revisions remain exact. [Retained redacted proof](mp23-native-bootstrap-results-2026-09-30/registry-recovery.json) binds both journal events and actual workload readiness. No new Secret/ServiceAccount authority is introduced. This preserves the original payload version and review. The final 992-test recheck also proves exact-capsule settlement after lost acknowledgement/readiness, refuses ordinary proof bypass, and retains completed unit evidence after credential expiry. Native locking and quiescent unit jobs bound uncertain host execution. Steady private platform credential coverage still needs a typed ownership/delegation contract and installed acceptance before safe use.

**Implementation update (2026-09-30):** EP-153 moves the registry-recovery mutation into the shared `runOperations` driver. The driver owns intent journaling, claim recheck, recovery-capability execution, and exact receipt settlement; preparation remains read-only. The unchanged retained F15 recording-adapter regressions pass, as do the focused registry suite, all 1,001 `nagarectl` tests, executable build, entrypoint-guard script, structural style, and all 460 `nagare-dsl` tests. The entrypoint guard now covers legacy `platform upgrade --apply --resume missing --yes` and refuses the inventory-admitted context before any upgrade/provider action. This source repair does not verify installed controller credential expiry or re-pull.

**Steady credential source candidate (2026-09-30):** Fresh generated hosts reserve the exact three pull Secret addresses; the Serving controller account binds its calculated resource identity and a typed host-only refresh grant. The actual timer checks that static grant and both native owner identities, uses resource-version conditions, and refuses foreign credentials or pull references. Legacy accepted hosts stay legacy. All 1,001 CLI tests pass (48.80 seconds); the rendered timer regression passes owned create/refresh, six foreign/race refusals and legacy policy, and fails against the original source with `controller credential target missing`. The CLI executable build, public foundation/bootstrap regression, structural style, command audit, Cabal formatting, host options and NixOS registry assertions pass. [Exact source hashes and verification boundaries](mp23-native-bootstrap-results-2026-09-30/registry-credential-delegation-candidate.json) are retained. Installed fresh-host expiry and re-pull proof remains pending; the existing cloud host/payload have not been changed or upgraded. This source candidate does not close F15 or establish safe use.

**Native fresh-host verification (2026-10-01):** Installed `71288437` converges the original fresh `f15-preview` cluster review with the admitted `d73c1dc4` payload. Its actual timer creates the three exact owned pull Secrets, validates and updates the typed Serving account, and the original private certificate controller performs an uncached pull and becomes Ready after its boot credential expired. A guarded native containerd re-pull of that same cached image refuses without the refreshed Secret and succeeds with the exact owned Secret. VM, closure, node, account, Secret and Deployment identities are checked; k3s invocation, original Deployment and shared head stay unchanged. [Redacted native evidence](mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json) retains the timer, registry response and pull-event boundaries. Native implementation proof is accepted; the operator runbook verification and independent release closure remain pending.

**Required verification:** Exercise source drift, foreign VM/closure/node/boot/workload, malformed or changed recovery proof, lost acknowledgement and partial-unit replay with zero repeated proved phases. Verify the installed original-transaction path and real image readiness without raw provider repair or review reset. Prove future credential expiry/re-pull coverage before initial safe-use acceptance.

**Verification:** Source regressions and installed original-transaction recovery/bootstrap convergence are retained; steady credential refresh/re-pull coverage remains open. Independent closure is required.

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

**Verification:** Independently Closed (2026-10-02). The retained status-caller regression passed at 50 and 500 committed events with zero single GETs and exactly one batch per prefix; a missing committed member still refuses. The independent 64-test object group passes. Live timing remains the separate F06 obligation. See [independent commands, limits and source hashes](mp23-independent-verification-2026-10-02.md).

## F03

**Resume loads the same complete journal twice** — P2; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: resumeTransactionWithTakeover, executeWithJournal.

**Audit evidence:** Source trace: resume readJournal then execute readJournal. New executeWithJournal receives already validated events.

**Implementation update:** Commit `90e06e29`: `Execute.hs` SHA-256 `f85330076f5fd386ef572f0dd7a36690c5d3ee9323233e6096ccde2bb6f60f1d`. The object group passed `converged replay needs no provider registry or repeated journal pass` with one batch and `lost journal acknowledgement cannot duplicate an effect`. Commit `32c17c94` adds `active resume reads one journal batch and does not repeat proved effect`; `cabal test nagarectl-test --test-options=--pattern=proved` passed all five selected tests. Independent verification remains.

**Required verification:** Run a same-transaction resume with batch counts and retained operation receipts; require one prefix read and no repeated completed native effect.

**Verification:** Independently Closed (2026-10-02). The active original-transaction regression passed with exactly one journal batch and one total provider effect across interrupted apply/resume. Completed replay uses one batch without a registry; lost acknowledgements preserve no-duplicate behavior. The independent 64-test object group passes. See [independent commands, limits and source hashes](mp23-independent-verification-2026-10-02.md).

## F04

**Native evidence loads every historical review and can repeat the scan** — P2; **Closed**; owner EP-156 / EP-153.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadNativeFor; cli/nagarectl/src/Nagare/Inventory/Plan.hs: loadPublishedReview.

**Audit evidence:** loadNativeFor expands every review and its scope/native members. Status invokes accepted and retained loaders. A cold cache makes historical review count a remote-I/O multiplier.

**Implementation update:** Commit `90e06e29`: `Status.hs` SHA-256 `6e16cf573810b7191ab040dbe7ba639160ab137f255901f9dfc5d1b6c2b9d85b` adds the empty-retained fast path. The object-group tests passed, but they do not measure unrelated review history; accepted and nonempty-retained scans remain unresolved.

**Implementation update (2026-09-29):** [Production proof and exact source hashes](mp23-selected-read-proof.md): status/explain now reads opaque digest-bound observation inputs, with two cold native GETs for two selected bindings independent of 0/500 reviews and 0/50 siblings. Empty legacy native requests use zero GETs/lists. New publications include raw observation bytes; explicit bounded materialization handles old stores without making it a recovery prerequisite. Full-suite and public corruption/legacy/retained tests pass. The [active-startup repair](mp23-active-startup-proof.md) additionally shares the validated command store and uses selected digest-bound source inputs. One corrupt unrelated archived review no longer blocks this modern-history recovery path. Remains Partial because a legacy missing-byte fallback still scans archives; materialization remains optional for recovery.

**Implementation update (2026-10-01, maintainability follow-through):** Successful legacy reconstruction now retains the selected, validated raw observation bytes in the existing optional private local content cache. A new command with that cache performs zero remote GETs and zero archive listings even after 500 unrelated corrupt reviews are added. Missing/corrupt cache files reconstruct from original evidence; an unwritable cache does not strand recovery. The reader refuses remote writes and preserves the exact head. All 14 selected-observation tests pass. A cold legacy root still needs original archive lookup unless explicit materialization has supplied the missing blobs; this compatibility limit and independent closure remain open. [Source-bound results](mp23-maintainability-performance.json).

**Required verification:** Hold current inventory fixed while increasing unrelated review history; record remote/member decode counts and cold/warm cost. Demonstrate selection of only necessary native evidence while preserving incarnation binding.

**Verification:** Independently Closed (2026-10-02) for the existing supported publication contract. The independent 35-test observation run includes two selected resources costing exactly two reads despite 500 unrelated reviews and 50 sibling natives; corrupt/missing selected bytes, incarnation-preserving reconstruction, fresh-command verified cache reuse and unwritable-cache recovery also pass. Modern publications supply digest-bound raw inputs. The preserved disposable-prerelease decision removes compatibility with obsolete missing-byte histories as a release gate; a cold legacy store may still scan its original archives, and that limit remains documented. No constant-total-scope-decode or cold-legacy-cost claim is made. See [independent evidence](mp23-independent-verification-2026-10-02.md) and its retained observation output.

## F05

**New fresh-login checks can reuse an SSH multiplexed connection** — P1; **Closed**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: tailnet_fresh_closure, activate.

**Audit evidence:** New Tailnet calls omitted ControlMaster=no/ControlPath=none while the existing safe-switch verifier uses both.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression `scripts/test-inventory-host-transport.sh` SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed, capturing `ControlMaster=no` and `ControlPath=none` on both fresh-login paths. A real multiplexed-connection fixture remains for independent verification.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) reproduces a real control-master session falsely committing after key revocation: NIX_SSHOPTS preceded the mandatory no-multiplexing flags, and OpenSSH used its first values. Mandatory fresh options now precede ambient options. A real loopback sshd/master fixture proves all three production fresh-login paths reject the revoked key and accept restored authorization; safe-switch returns 4 without commit. Independent verification remains; this implementer does not close the finding.

**Required verification:** Capture argv for every call that contributes fresh-login proof and assert both options. Retain a regression with multiplexing configured; verify the proof comes from a new connection.

**Verification:** Independently Closed (2026-10-02). The real loopback sshd/control-master regression independently passes: the surviving master cannot authorize any of the three fresh-login paths after key revocation; restored authorization succeeds, safe-switch returns 4 without commit. The argv transport regression also passes. See [independent commands, limits and source hashes](mp23-independent-verification-2026-10-02.md).

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

**Implementation update (2026-10-01, maintainability follow-through):** The refactored public CLI passes 12 complete conditional-HTTP-recorder cases across 50/500 journal events, 0/50/500 unrelated reviews and cold/warm roots, with 29 subprocesses (5 initialization, 24 provider observations) in each case. Four lost-write-acknowledgement cases converge the original transaction; two identical-head/provider-generation races refuse before provider recovery. The saved-prune public recovery fixture also passes. Reports now bind every CLI, inventory-library and DSL source module, including extracted implementations. These are local recorder measurements; they preserve rather than replace the retained native GCS/cloud evidence. Native provider/store timing decomposition and independent closure remain open. [Source-bound results](mp23-maintainability-performance.json).

**Required verification:** Retain append and resume command-count regressions, preserve conditional writes/lost-ack recovery, then pass EP-156 cold/warm real GCS timing gate. Record append/provider/replay timings separately; no closure from one batched cp.

**Verification:** Not closed. Awaiting the checks above.

## F07

**Installed key with failed service activation cannot recover by retry** — P1; **Closed**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: activate; nixos/modules/nagare-host.nix: install_key.

**Audit evidence:** Extracted activate() with matching installed digest and unavailable Tailscale: two attempts each call status,status,IP then fail; neither reactivates. Helper preserves verified key before service restart.

**Implementation update:** Commit `538b046d`: transport SHA-256 `76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52`; shell regression SHA-256 `aaa4558673486d1f7ed6a09fd7611810d73c03e54b70486714ceb70aac6caaa7`. `bash scripts/test-inventory-host-transport.sh` passed: same installed key plus failed service triggers one helper activation and a fresh login, a ready host triggers none, and a different key refuses. Independent full retry verification remains.

**Additional implementation evidence (2026-09-29):** The [active/host proof](mp23-active-host-proof.md) executes the actual helper body and transport functions with simulated privileged/service/network boundaries. Separate sops and Tailscale failures after verified key persistence recover on the identical activation request without rewriting its inode/mtime/content. A ready retry skips delivery; a wrong installed key refuses. This exposed helper diagnostic stdout preceding transport JSON; delivery diagnostics now go to stderr and the regression parses the entire stdout as one committed JSON response. The new Nix host-transport-recovery check and 38 focused host tests pass. Real Linux services, saved-host-transaction CLI recovery and independent verification remain open.

**Required verification:** Simulate successful key persistence followed by sops/Tailscale failure, then retry the original operation. Prove activation resumes, no different key is written, fresh-login/readiness succeeds, and wrong keys still refuse.

**Verification:** Independently Closed (2026-10-02). Executing the actual helper/transport regression proves both injected post-persistence sops and Tailscale failures recover on the identical request: first exits 42/43, retry exits 0, one key write, unchanged inode/mtime/content, and wrong key exits 2. Fresh-login and transport argv regressions also pass. This closes the stated retry defect; final real-service/native release evidence remains separately required. See [independent verification](mp23-independent-verification-2026-10-02.md).

## F08

**Unchanged host bootstrap depends on transient key-file environment and source root** — P2; **Partial**; owner EP-156.

**Locations:** cli/nagarectl/app/Main.hs: buildHostStageCandidate.

**Audit evidence:** buildHostStageCandidate recomputes credential-bound spec/inputs from NAGARE_HOST_AGE_KEY_FILE and compares the entire scope. Removing the variable or moving hostRoot causes accepted-scope mismatch despite unchanged remote intent.

**Implementation update:** Commit `538b046d`: `Main.hs` SHA-256 `fd5d18972afe65e8368e97506a0d697424933ce48463b683436bbbf180314fb4` retains an accepted key digest and source binding when delivery-only environment is absent. `cabal build exe:nagarectl` passed; no public replan with the variable cleared or another operator root has passed, so this remains open.

**Native continuation repair (2026-09-29):** [The native checkpoint](mp23-native-bootstrap-proof.md) confirms fresh host login, then reproduces a further source dependency: bootstrap and build observation reevaluated mutable installation source after host acceptance. The repair preserves accepted host-input checks and observes the exact reviewed build output. The public bootstrap regression now rejects each changed host input and completes kubeconfig recovery and the 211-operation cluster review with Nix disabled after host acceptance. The next native run proved matching digests but rejected serialized input ordering; canonical scope comparison now passes an adversarial-order public fixture. The second-root attempt separately reproduced missing local-marker discovery of GCS history. Installed candidate `0870fa200d07` now replans without the delivery-key variable and completes the native kubeconfig transaction. F08 is Partial for second-root discovery/verification and independent closure.

**Fresh-root repair acceptance (2026-09-29):** Commits `27462937` and `6082dbd6` implement bound read-only GCS discovery, local Pulumi configuration restoration, explicit credential recovery and current-root read-only credential observation. [The installed proof](mp23-fresh-root-discovery-repair.md) uses candidate `6082dbd6aac0` from a never-used config/state/cache root without delivery-only key environment or copied marker/journal/credential. It recovers a matching private credential, reaches the same Ready node, and saves a 210-operation, zero-barrier review in 319.659 seconds under 360 seconds. No operations target the six accepted prerequisite scopes; shared head/global contexts are unchanged and no cluster apply runs. All 983 CLI tests and 36 public authority cases pass, with changed-host/credential refusals in the public regression. This implementing session accepts that consumer proof; F08 stays Partial pending independent closure and remaining recovery verification.

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
