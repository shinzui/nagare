# MP-23 audit findings tracker

This is the authoritative list of implementation findings for [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). The register below lists every finding ID; this file carries the full text only for findings that are still Open or Verifying. Closed findings, the original communication log and retained pre-fix reproductions are in [the closed-findings archive](mp23-archive/mp23-findings-closed.md). The [initial audit report](mp23-archive/mp23-initial-audit.md) and other superseded audit documents are indexed in [the archive README](mp23-archive/README.md).

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
| [F01](mp23-archive/mp23-findings-closed.md#f01) | P1 | Host execution mutates after observing a different VM or old closure | Closed | EP-156 |
| [F02](mp23-archive/mp23-findings-closed.md#f02) | P1 | Active transaction status still reads journal entries individually | Closed | EP-156 |
| [F03](mp23-archive/mp23-findings-closed.md#f03) | P2 | Resume loads the same complete journal twice | Closed | EP-156 |
| [F04](mp23-archive/mp23-findings-closed.md#f04) | P2 | Native evidence loads every historical review and can repeat the scan | Closed | EP-156 / EP-153 |
| [F05](mp23-archive/mp23-findings-closed.md#f05) | P1 | New fresh-login checks can reuse an SSH multiplexed connection | Closed | EP-156 |
| [F06](mp23-archive/mp23-findings-closed.md#f06) | P1 | Journal appends retain excessive serial cloud-command cost | Closed | EP-156 |
| [F07](mp23-archive/mp23-findings-closed.md#f07) | P1 | Installed key with failed service activation cannot recover by retry | Closed | EP-156 |
| [F08](mp23-archive/mp23-findings-closed.md#f08) | P2 | Unchanged host bootstrap depends on transient key-file environment and source root | Closed | EP-156 |
| [F09](mp23-archive/mp23-findings-closed.md#f09) | P1 | Scheduled-prune preflight prevents recovery after admission | Closed | EP-159 / EP-153 |
| [F10](mp23-archive/mp23-findings-closed.md#f10) | P2 | Explaining one resource observes the whole context | Closed | EP-153 |
| [F11](mp23-archive/mp23-findings-closed.md#f11) | Build | Conditional-upload optimization has ambiguous try exception type | Closed | EP-156 |
| [F12](mp23-archive/mp23-findings-closed.md#f12) | P1 | A later operation’s preflight blocks recovery of its ambiguous prerequisite | Closed | EP-153 / EP-159 |
| [F13](mp23-archive/mp23-findings-closed.md#f13) | P1 | Ordinary executor recovery has no terminal-failure branch | Closed | EP-153 / EP-159 |
| [F14](mp23-archive/mp23-findings-closed.md#f14) | P1 | Initial Knative activator readiness blocks its uncreated autoscaler | Closed | EP-156 |
| [F15](#f15) | P1 | Patched certificate controller lacks refreshed private-image credentials | Verifying | EP-156 / EP-154 |
| [F16](#f16) | P1 | Unready application creation cannot yield to a corrected reviewed configuration | Verifying | EP-153 / EP-156 |
| [F17](mp23-archive/mp23-findings-closed.md#f17) | P1 | Effect-free retirement discards required native identity observations | Closed | EP-153 / EP-156 |
| [F18](mp23-archive/mp23-findings-closed.md#f18) | P1 | Initial GCS foundation transaction cannot resume its local journal | Closed | EP-153 / EP-156 |
| [F19](mp23-archive/mp23-findings-closed.md#f19) | P1 | Rendered pinned GCS restore omits download generations | Closed | EP-160 / EP-156 |
| [F20](mp23-archive/mp23-findings-closed.md#f20) | P1 | Knative collection cannot orphan controller descendants | Closed | EP-153 / EP-156 |
| [F21](mp23-archive/mp23-findings-closed.md#f21) | P1 | HTTP redirect automatically resubmits reviewed CDN purge | Closed | EP-158 |
| [F22](mp23-archive/mp23-findings-closed.md#f22) | P1 | ClickHouse restore fails after a transient read-only verification refusal | Closed | EP-160 |
| [F23](mp23-archive/mp23-findings-closed.md#f23) | P1 | Credential review can delegate to an older receipt-unaware host transport | Closed | EP-153 / EP-154 |
| [F24](mp23-archive/mp23-findings-closed.md#f24) | P1 | Host image planning can start a stopped builder | Closed | EP-153 / EP-154 |
| [F25](mp23-archive/mp23-findings-closed.md#f25) | P2 | Reviewed context control rejects supported builder transport inputs | Closed | EP-153 |
| [F26](mp23-archive/mp23-findings-closed.md#f26) | P1 | Removed GCS context cannot restore its retained authority | Closed | EP-153 |
| [F27](mp23-archive/mp23-findings-closed.md#f27) | P1 | Credential streaming loses argument boundaries at the real SSH transport | Closed | EP-153 / EP-154 |
| [F28](mp23-archive/mp23-findings-closed.md#f28) | P1 | Release cleanup omits native evidence for adjacent scope members | Closed | EP-153 |
| [F29](mp23-archive/mp23-findings-closed.md#f29) | P1 | Admitted preview route failure lacks a bounded configuration correction | Closed | EP-153 |
| [F30](#f30) | P1 | Controller status churn strands admitted conditional Service correction | Verifying | EP-153 / EP-156 |
| [F31](#f31) | P1 | Registry refresh cadence permits credentials to expire before its next run | Verifying | EP-154 / EP-156 |
| [F32](#f32) | P1 | Image-cache cleanup selects an image used by active pod sandboxes | Verifying | EP-153 / EP-156 |
| [F33](#f33) | P1 | Cloud collection does not recheck its reviewed physical incarnation before deletion | Verifying | EP-153 / EP-156 |
| [F34](mp23-archive/mp23-findings-closed.md#f34) | P1 | Kourier gateway rejects HTTPS listener updates on cp3, so new routes never become Ready | Closed | EP-155 / EP-153 |
| [F35](mp23-archive/mp23-findings-closed.md#f35) | P1 | Preflight refusal after admission strands the transaction with no supported exit | Closed | EP-153 / EP-160 |
| [F36](mp23-archive/mp23-findings-closed.md#f36) | P1 | A failed Redis scratch restore cannot be abandoned and wedges the store | Closed | EP-160 |
| [F37](mp23-archive/mp23-findings-closed.md#f37) | P1 | Configuration drift written by another field manager has no reviewed repair | Closed | EP-149 / EP-153 |
| [F38](mp23-archive/mp23-findings-closed.md#f38) | P2 | A failed GCS head advance after a published journal event stops ambiguous and discards the store error | Closed | EP-153 / EP-156 |
| [F39](#f39) | P1 | Staged cloud teardown cannot prepare any Pulumi operation on a real stack | Verifying | EP-153 / EP-156 |
| [F40](#f40) | P1 | A real context cannot be retired: contribution targets, scope cycles and host or artifact members block every teardown | Partial | EP-153 / EP-156 |
| [F41](mp23-archive/mp23-findings-closed.md#f41) | P1 | A local node restart destroys every local backup, and local escrow verification needs the source cluster | Closed | EP-155 / EP-159 |
| [F42](mp23-archive/mp23-findings-closed.md#f42) | P1 | The managed-resource evidence assembler can never accept real runner output | Closed | EP-157 |
| [F43](#f43) | P1 | A fresh inventory context cannot enable the platform Google CDN backend, so B3 cannot run | Verifying | EP-158 / EP-156 |
| [F44](#f44) | P1 | Inventory status on a cloud context never observes cloud-foundation members, so cloud runner evidence cannot assemble | Verifying | EP-153 / EP-157 |
| [F45](#f45) | P1 | Reviewed Google CDN deploy on an inventory context cannot observe or apply its DNS record | Verifying | EP-158 / EP-156 |
| [F46](#f46) | P1 | A retired site's edge DNS record can never be collected, because retained release history orders after it | Verifying | EP-158 / EP-156 |
| [F47](#f47) | P2 | CDN platform outputs are read with the caller's Pulumi environment, not the active context's | Verifying | EP-158 |
| [F48](#f48) | P2 | Inventory evidence names the manifest's payload without checking the payload the context runs | Open | MP-26 (EP-168 port) |
| [F49](mp23-archive/mp23-findings-closed.md#f49) | P1 | An out-of-band replacement of an accepted database is reported converged, and its new incarnation's receipts plan for ingestion | Closed | EP-159 / EP-153 |
| [F50](mp23-archive/mp23-findings-closed.md#f50) | P2 | One transient failed gcloud read makes the state-bucket ownership guard stop a run | Closed | EP-156 |
| [F51](mp23-archive/mp23-findings-closed.md#f51) | P2 | Retirement retains an out-of-band replacement's identity instead of the accepted incarnation | Verifying (reopened 2026-10-05) | EP-153 / EP-159 |
| [F52](#f52) | P2 | Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges | Verifying | EP-153 |
| [F53](#f53) | P1 | `nix flake check` fails at the candidate: sandbox-only test failures and stale check assertions | Verifying | EP-154 |
| [F54](mp23-archive/mp23-findings-closed.md#f54) | P1 | A landed application Service update whose new revision never becomes Ready has no reviewed exit, so the store stays wedged | Closed | EP-153 / EP-156 |
| [F55](#f55) | P1 | A landed unready application update still has no exit when its review also updates its release history or verifies a member | Verifying | EP-153 / EP-173 |
| [F56](#f56) | P1 | A landed application Service update whose Service is then replaced outside review has no exit | Verifying | EP-153 / EP-173 |
| [F57](#f57) | P1 | A verification whose target is replaced after it ends ambiguous has no exit | Verifying | EP-153 / EP-173 |
| [F58](#f58) | P2 | An application whose first deploy stopped unready cannot be retired, because a never-created member has nothing to retain | Verifying | EP-153 / EP-173 |
| [F59](#f59) | P1 | A standalone database whose StatefulSet is created but never becomes Ready has no exit | Partial | EP-153 / EP-173 |
| [F60](#f60) | P2 | One out-of-band replacement between a create and convergence is recorded as the accepted incarnation (F49's fail-open recording, reachable with one fault) | Open (ADR 27) | EP-173 |
| [F61](#f61) | P1 | A reviewed PostgreSQL rename whose copy Job fails partway has no exit | Open | EP-173 / EP-153 |
| [F62](#f62) | P2 | A reviewed rename copies from, and retains, a source replaced outside review | Open | EP-153 / EP-173 |
| [F63](#f63) | P1 | A Deployment or database StatefulSet update that lands but never becomes Ready has no exit | Open | EP-153 / EP-173 |
| [F64](#f64) | P1 | An intended update whose target is deleted outside review, and not recreated, has no exit | Verifying | EP-153 / EP-173 |
| [F65](#f65) | P1 | The create-path stop refuses a review that recreates a deleted Service alongside its release-history update | Verifying | EP-153 / EP-173 |
| [F66](#f66) | P1 | A create that finds an object not stamped as its own at its address settles unknown, so only an attested close can end it | Verifying | EP-153 / EP-177 |
| [F69](#f69) | P1 | A Knative Service or DomainMapping reads ready from its previous generation's Ready=True before the controller has seen the new spec | Verifying | EP-153 / EP-180 |
| [F70](#f70) | P1 | A worker Deployment whose update never becomes available reads as ready, so a broken rollout is recorded as complete | Verifying | EP-153 / EP-180 |
| [F67](#f67) | P1 | An update refused after a status write, whose refusal's journal event is lost, settles unknown | Verifying | EP-153 / EP-180 |
| [F71](#f71) | P2 | A Kubernetes write the API server definitively refused (409, 422, 404 and the other 4xx) is reported ambiguous | Verifying | EP-153 / EP-180 |
| [F72](#f72) | P1 | The Kubernetes transport refuses a corrective update of an unready StatefulSet or Deployment as an unsupported precondition | Verifying | EP-153 / EP-180 |
| [F68](#f68) | P1 | An update whose target is deleted and replaced by an object not stamped as its own settles unknown, so only an attested close can end it | Verifying | EP-153 / EP-177 |

Closed findings keep their full text, location, implementation updates and verification in [the closed-findings archive](mp23-archive/mp23-findings-closed.md). F01 and F11 retain their [earlier independent closure](mp23-archive/mp23-verification.md). F02, F03, F04, F05, F06, F07, F08 and F20 now have [2026-10-02 independent closure](mp23-independent-verification-2026-10-02.md). F34, F35, F36, F37, F38, F41 and F42 have 2026-10-04 independent closure on candidate `7596632c`, and F49 and F50 on candidate `847543896d07` ([records](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Other entries retain their status shown above.

**Exit change for open findings (2026-10-05, EP-175 M3; claude-opus-5-5).** [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) replaced every stop and abandon exit with `nagarectl inventory close`. The affected findings are F16, F54–F59 and F63–F65, plus the closed F35–F37. Their instance-level guards (the Application-only and StatefulSet-only stop rules, the companion rules F55 and F65, and the landed/replaced stop proofs) are deleted. Their mutation records are retired in [the mutation README](../../cli/nagarectl/test/mutations/README.md), which names the rule-level record that now pins each class. A verifier re-checking these findings should run the close path: each scenario's stop now ends with `inventory close`, keeping or reverting the changed scope by proof. Statuses are unchanged here; they are the verifier's to set.

## F15

**Implementation update (2026-09-30, F15 pre-review boundary):** Installed CLI `705716b7` passes the full native local platform-bootstrap gate and preserves the retained F15 `d73c1dc4` payload identity. Its prerequisite public shared-store status refuses with `StoreConditionFailed "gcloud credential or ownership command failed or timed out"` under configuration `labs`; cloud preparation stops at the guard, before a VM review or mutation. Restore that successful guarded read before the bounded cloud rehearsal. This supplies no new credential-expiry/re-pull evidence; operator Verification remains pending.

**Patched certificate controller lacks refreshed private-image credentials** — P1; **Verifying**; owners EP-156 / EP-154.

**Locations:** nixos/hosts/nagare-01/registries.nix; bootstrap private certificate-controller Deployment and ServiceAccount declarations.

**Native evidence:** The original saved bootstrap creates `net-certmanager-controller` in `knative-serving`; its private Artifact Registry image receives a 401 token response. The accepted host supplies boot-only k3s registry credentials, which have expired. Its recurring Secret policy covers `personal` and `nagare-system` default ServiceAccounts; this controller uses the `knative-serving` controller account. The bounded rollout stops naturally after 436.558 seconds. Shared generation 469 retains the same original transaction with no claim/fence. Serving and public-image certificate webhook workloads are Ready.

**Implementation update:** A bounded explicit registry recovery candidate passes all 992 CLI tests, the public foundation/bootstrap regression, registration/injected-mutation audit and structural style checks. Named regressions include `bounded registry recovery journals intent and requires actual workload readiness`, `registry recovery binds completed host history and original private Deployment`, `registry unit recovery preserves landed phases across expiry and settles ready workloads`, and strict intent/receipt parsing. It saves the original Deployment/host/unit proof separately, journals intent before replaying only the accepted registry bootstrap unit and k3s service, and retains independent Deployment readiness as the completion criterion. Installed `39842f8058bdaaf94819365b1f2511a3a7147246` runs this public recovery in 101.552 seconds and proves the original Deployment/pod Ready. Public original-review resume converges in 230.454 seconds at generation 549, with no active transaction, claim, fence or migration; all accepted/prerequisite revisions remain exact. [Retained redacted proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/registry-recovery.json) binds both journal events and actual workload readiness. No new Secret/ServiceAccount authority is introduced. This preserves the original payload version and review. The final 992-test recheck also proves exact-capsule settlement after lost acknowledgement/readiness, refuses ordinary proof bypass, and retains completed unit evidence after credential expiry. Native locking and quiescent unit jobs bound uncertain host execution. Steady private platform credential coverage still needs a typed ownership/delegation contract and installed acceptance before safe use.

**Implementation update (2026-09-30):** EP-153 moves the registry-recovery mutation into the shared `runOperations` driver. The driver owns intent journaling, claim recheck, recovery-capability execution, and exact receipt settlement; preparation remains read-only. The unchanged retained F15 recording-adapter regressions pass, as do the focused registry suite, all 1,001 `nagarectl` tests, executable build, entrypoint-guard script, structural style, and all 460 `nagare-dsl` tests. The entrypoint guard now covers legacy `platform upgrade --apply --resume missing --yes` and refuses the inventory-admitted context before any upgrade/provider action. This source repair does not verify installed controller credential expiry or re-pull.

**Steady credential source candidate (2026-09-30):** Fresh generated hosts reserve the exact three pull Secret addresses; the Serving controller account binds its calculated resource identity and a typed host-only refresh grant. The actual timer checks that static grant and both native owner identities, uses resource-version conditions, and refuses foreign credentials or pull references. Legacy accepted hosts stay legacy. All 1,001 CLI tests pass (48.80 seconds); the rendered timer regression passes owned create/refresh, six foreign/race refusals and legacy policy, and fails against the original source with `controller credential target missing`. The CLI executable build, public foundation/bootstrap regression, structural style, command audit, Cabal formatting, host options and NixOS registry assertions pass. [Exact source hashes and verification boundaries](mp23-archive/mp23-native-bootstrap-results-2026-09-30/registry-credential-delegation-candidate.json) are retained. Installed fresh-host expiry and re-pull proof remains pending; the existing cloud host/payload have not been changed or upgraded. This source candidate does not close F15 or establish safe use.

**Native fresh-host verification (2026-10-01):** Installed `71288437` converges the original fresh `f15-preview` cluster review with the admitted `d73c1dc4` payload. Its actual timer creates the three exact owned pull Secrets, validates and updates the typed Serving account, and the original private certificate controller performs an uncached pull and becomes Ready after its boot credential expired. A guarded native containerd re-pull of that same cached image refuses without the refreshed Secret and succeeds with the exact owned Secret. VM, closure, node, account, Secret and Deployment identities are checked; k3s invocation, original Deployment and shared head stay unchanged. [Redacted native evidence](mp23-archive/mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json) retains the timer, registry response and pull-event boundaries. Native implementation proof is accepted; the operator runbook verification and independent release closure remain pending.

**Required verification:** Exercise source drift, foreign VM/closure/node/boot/workload, malformed or changed recovery proof, lost acknowledgement and partial-unit replay with zero repeated proved phases. Verify the installed original-transaction path and real image readiness without raw provider repair or review reset. Prove future credential expiry/re-pull coverage before initial safe-use acceptance.

**Verification:** Source regressions and installed original-transaction recovery/bootstrap convergence are retained; steady credential refresh/re-pull coverage remains open. Independent closure is required.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** No source change in phase 1. Native closure is the phase-3 C3 run: a genuine credential refresh and a private pull after the boot credential expired. Next check: phase 3a.

## F16

**Unready application creation cannot yield to a corrected reviewed configuration** — P1; **Verifying**; owners EP-153 / EP-156.

**Native evidence:** The cloud fixture has 2 CPUs, with 1,785m allocated after full bootstrap. Application A's default web pod requests 275m and cannot schedule, although its PostgreSQL pod is Ready and its retained PVC is Bound. Public saved apply stops after 365.186 seconds at `op-711f755156b69c10be13390c`. Generation 576 keeps the original application transaction without claim, fence or migration. Its review targets only its 11 owned resources; [redacted evidence](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-capacity.json) preserves the review, identity and failure. No raw resize, patch, restart, review rewrite or history reset occurred.

**Implementation update:** A guarded `stop-incomplete-application` decision requires one changed Application scope, only unfenced owned Kubernetes creates, an originally absent stateless Knative Service proved owned and unchanged but unready, and no other uncertain operation. It journals selection before clearing the active transaction, retaining admitted ownership and prior converged revisions. It never completes the workload or rolls ownership back away from created retained data. The same decision settles a lost head acknowledgement without provider IO; ordinary proof cannot bypass a pending stop. A new application review can correct resource configuration. Knative conditional updates retain UID/resourceVersion and exclusive non-status ownership checks; installed update proof remains pending.

**Required verification:** Preserve unselected stopped applications' prior converged revisions when another scope completes. Prove created retained-data ownership survives stopping, foreign/durable/changed-native and multiple-uncertain refusals, exact decision replay after lost acknowledgement, and installed stop followed by a new corrected review. Require the same Service/PVC/database identities, Ready application and no platform revision change. Prove the Knative conditional update and unchanged replay through the public installed path.

**Verification:** The installed `0f6fa7db` stop passes in 12.441 seconds: all 24 accepted and 23 converged revisions and the original Service/PostgreSQL/PVC UIDs are preserved; generation 579 is idle. The corrected plan then refuses in 17.365 seconds at the original never-created backup signing key. [Redacted evidence](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-stop-and-replan.json) retains this consumer result. The follow-up repair derives never-started create proof from the original immutable stopped review and validated committed journal, only for planning that selects its unchanged unconverged application revision. Previously completed, uncertain, changed and foreign durable members still refuse; ordinary inspection and unrelated planning do not scan execution history. The final CLI suite passes all 997 tests in 52.48 seconds, covering never-started creation, completed data refusal, later uncertain intent, foreign ownership, changed declaration, superseded revision, missing committed journal and inspection/unrelated planning isolation. Structural style and the managed-command audit pass. The installed public bootstrap fixture passes. Installed `49db2199` saves the corrected Application A review in 42.372 seconds and converges in 63.123 seconds: same Service/PostgreSQL/PVC UIDs, Ready Service, expected HTTP body and preserved seeded row. Only its accepted revision changes, with all 24 scopes converged at generation 605/sequence 539. [Redacted native proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-correction.json) retains the original NotReady UID/resourceVersion precondition and actual consumer results. A follow-up real-planner regression reproduces a convergence leak: completing another application incorrectly marks a stopped, unready application converged. The repair advances only revisions changed by the completing review and removes retired scopes; it preserves unselected prior convergence. The eight focused regression cases and all 998 CLI tests now pass (60.14 seconds); structural Haskell style passes. Installed `eb582eb0` builds successfully. A second regression exposes unchanged stopped members being omitted while remaining creates complete; selected unconverged scopes now require fresh verification for unchanged managed members. Native preparation still refuses NotReady verification, while a corrected Knative configuration uses its guarded update. All 998 tests pass after this extension in 67.46 seconds, and structural style passes. Final installed validation and independent closure remain open.

**Installed follow-up:** Immutable `2101b834` builds on aarch64-darwin and passes the installed public foundation/bootstrap fixture. Its [cloud interruption and second-root proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json) preserves every prior accepted owner and all application/database identities while recovering a separate backup without repeating its create. Its [installed stopped-readiness proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/cloud-stopped-notready-verification.json) now confirms unchanged NotReady replan refusal without a review or head change, followed by a corrected conditional update retaining the Service UID. All 29 scopes converge at generation 698/sequence 615; original application/database/PVC identities and data remain intact. Independent F16 closure remains open.

**Implementation update (2026-09-30):** EP-153 adds a bounded fixed-seed in-memory driver model to the ordinary `nagarectl-test` suite. Planner-produced create/update/selected-unconverged-verification/retention-retirement reviews across two Application scopes interrupt each provider-effect boundary and resume with recording-adapter proof; stale conditional writes refuse without mutating the head, and a foreign executor claim requires explicit takeover. The model checks no duplicate effect, selected-only revision completion, accepted/converged consistency, monotonic head/journal state, and finite ambiguity recovery. Its stopped-scope assertion rejects the `eb582eb0` convergence leak; its unchanged selected member assertion rejects the `7c957c02` readiness-verification leak. The focused model test and all 1,002 CLI tests pass; structural style passes. This is source-only evidence and does not replace the operator's F16 runbook verification on `f15-preview`.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** All fix diffs read. Without the fix, `eb582eb0` fails (the convergence leak), `7c957c02` fails ("unchanged stopped workload lacks fresh readiness proof"), and a stop-guard mutation of `0f6fa7db` fails "refuses foreign scope". `49db2199` fails only to compile on its parent (new API). All pass at the candidate, in a full suite of 1,184 tests ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Source verified. Next check: native application change and recovery on the acceptance C3 (phase 3a).

## F30

**Controller status churn strands admitted conditional Service correction** — P1; **Verifying**; owners EP-153 / EP-156.

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
attempted for the correction. [Exact native evidence](mp23-independent-results-2026-10-02/application-status-race-f30.json).

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
closure remains pending. [Exact stopped state](mp23-independent-results-2026-10-02/application-status-race-f30-handoff.json).

**Implementation update (2026-10-02, MP-23 A4 resume attempt; claude-opus-5-5):** With no live executor process and the store still at generation 9314 with the original claim, the admitting binary (`ab3aabf7…`, same isolated operator root) ran the public `inventory resume tx-b4da295e… --yes`. It exited 1 after 3 s with `ambiguous … at op-fed6a9432af7669b7446f230` and wrote no provider effect. That is the driver's correct refusal to retry an unproved update. Read-only observation: the Service keeps UID `470ff139…` at generation/observedGeneration 2; ConfigurationsReady is True; revision 00002 is Running 2/2; Ready/RoutesReady are Unknown ("Waiting for load balancer to be ready"). The cause is [F34](mp23-archive/mp23-findings-closed.md#f34), not the F30 repair. Following the stop rule, no `inventory recover`, takeover, patch or rollback was attempted, and the transaction remains preserved. Private record: `/tmp/mp23-independent-application-correction/a4-resume-refusal.json`. Next: diagnose and repair F34 under a written recovery plan, then resume the same transaction and verify identities, the known row and replay.

**Implementation update (2026-10-02, A4 terminal state; claude-opus-5-5):** After the F34 repair, the same public `inventory resume tx-b4da295e… --yes`, with the same admitting binary and root, exited 0 in 3 s (`converged`). Store status shows no active transaction or claim (generation 9322). Service `470ff139…` (generation 2, Ready), StatefulSet `03a23352…` and PVC `15138d3a…` are unchanged, and `select id, value from mp23_correction_probe` returns `1|mp23-original-data-before-correction`. An unchanged `app deploy … --save-plan` replan with the scope's recorded tag, image resource and recovery binding produced review `701d1306…` with zero operations. No rollback, patch or history reset occurred. Private record: `/tmp/mp23-independent-application-correction/a4-f34-recovery.json`. F30 and F16 now await independent verification.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** `52432400` fails on its parent ("observation Kubernetes envelope differs from reviewed operation"). `95b58a24` fails only to compile there (new module). Both pass at the candidate ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). The A4 terminal resume records (`/tmp/mp23-independent-application-correction/a4-*.json`) agree with the updates above: converged, the same Service/StatefulSet/PVC UIDs, the known row, a zero-operation replan. But they were written by the implementer with development binary `ab3aabf7` and are retained only in `/tmp`; archive them under `docs/audits/`. Status set to Verifying. Next check: native application change and recovery on the acceptance C3 (phase 3a).

**Version 2 removed (2026-10-06, EP-180 M5b; claude-opus-5-5):** The status-stable version-2 observation this entry introduced for Knative Service updates is deleted. Every update now follows G6's single discipline (RES-4 U3, U10): it is guarded by the reviewed UID, this member's ownership and its before-state stamp, which status writes never change, and it writes with a fresh resourceVersion. A status-only transition like this entry's RevisionFailed therefore no longer refuses an admitted correction, for any kind. Saved version-2 reviews are refused, since Nagare has no installation to keep compatible. Deleting version 2 exposed F73.

## F31

**Registry refresh cadence permits credentials to expire before its next run** — P1; **Verifying**; owners EP-154 / EP-156.

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
that expires before the next run. [Native timer and credential evidence](mp23-independent-results-2026-10-02/registry-timer-expiry-gap-f31.json).

**Required repair/verification:** Align automatic refresh cadence, lifetime checks
and scheduling margin with metadata-token caching. Independently prove a genuine
automatic replacement before the previous credentials expire, then authenticate
the exact private controller image after the original boot credential expires.
Preserve typed Secret/account ownership, exact conditional writes, and the
immutable/disposable fixture decision. Do not manually start the refresh unit or
patch credentials to manufacture the acceptance result. F15 remains Verifying.

**Implementation update (2026-10-02, `ebe9d3a7`; claude-opus-5-5):** `nixos/hosts/nagare-01/registries.nix` now runs the pull-Secret timer every 120 s (`AccuracySec` 5 s) with a 60 s `TimeoutStartSec`. A module assertion requires interval + accuracy + timeout < 300 s, the minimum `expires_in` the script accepts, which is the metadata cache floor. An unchanged token and current ServiceAccount cause no Kubernetes write (compared on stdin; the token never enters argv), and a rotated token keeps the resourceVersion-conditional replace. `python3 scripts/test-registry-credential-delegation.py` passes the cadence invariant, create, no-op, rotation, ≤300 s refusal, six foreign/race refusals and the legacy policy. It fails against the previous module. `nix eval` of the `nagare-01` toplevel drv succeeds. Remaining: an installed fresh-host observation of an automatic replacement before expiry and an expired-boot-credential private pull (EP-156 C3); independent closure.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** `python3 scripts/test-registry-credential-delegation.py` passes at the candidate. With the previous module it fails: there the cadence was 30 minutes and any token with more than 300 s left was accepted ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: in phase 3a, read the controller timeline for a refresh before expiry.

## F32

**Image-cache cleanup selects an image used by active pod sandboxes** — P1; **Verifying**; owners EP-153 / EP-156.

**Independent installed native evidence (2026-10-02):** Installed b805 prepares
two exact cache deletions on the fixed 762 host, including the full image ID for
`rancher/mirrored-pause:3.10.2`. The runtime reports `pinned=false`, but independent
`crictl inspectp` and containerd container inspection show a Ready sandbox uses
that exact image alias. Thirty-five sandboxes exist. The production capture only
lists ordinary containers with `crictl ps -a`, omitting sandbox image references.
No apply occurred; the original review and idle head remain preserved.
[Native review and sandbox evidence](mp23-independent-results-2026-10-02/image-prune-sandbox-f32.json).

**Required repair/verification:** Resolve and protect exact image IDs referenced
by Ready and retained stopped sandboxes, and fail closed when required sandbox
observations are missing or ambiguous. Account for the configured runtime sandbox
image rather than relying solely on the reported pinned flag. Exercise the actual
production script with sandbox-only use and inspection failure, then independently
prepare and execute a fresh installed native review that excludes those protected
images. Prove ordinary unused-image deletion, workload preservation and durable
one-shot replay behavior. Do not apply the unsafe saved review.

**Implementation update (2026-10-02, `c2dc2bb1`; claude-opus-5-5):** The production script (`cli/nagarectl/src/Nagare/Inventory/ImagePruneScript.hs`) adds every pod sandbox's image (`crictl pods -o json`, then `crictl inspectp -o json` `.info.image`, for Ready and NotReady sandboxes) and the configured sandbox image (`pinned_images` `sandbox` or legacy `sandbox_image` in `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`) to the resolved used set that both inspection and removal protect. A failed listing or inspection, a missing image field, or an absent or ambiguous configured image refuses the capture. Read-only observation on local k3s v1.34.6 (cp3) confirmed `crictl info` lacks the sandbox image, `inspectp` reports `.info.image`, and the pause image is `pinned=false`. `python3 scripts/test-image-prune-protocol.py` passes 23 cases (was 10), including sandbox-only, configured-only, seven fail-closed observations, ordinary deletion beside protected sandboxes, and inspection reporting sandbox images as used. The first sandbox case fails against the previous script. Remaining: a fresh installed native review that excludes protected images and deletes an ordinary unused one, with one-shot replay; independent closure.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The production script protects every pod sandbox image, Ready or NotReady, plus the configured sandbox image. A failed or ambiguous observation refuses the capture. `test-image-prune-protocol.py` passes 23/23 at the candidate; with the previous script, the first sandbox case fails ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Status set to Verifying. Next check: the reviewed GCE-image cleanup in phase 3a.

## F33

**Cloud collection does not recheck its reviewed physical incarnation before deletion** — P1; **Verifying**; owners EP-153 / EP-156.

**Independent source evidence (2026-10-02):** The collection planner checks the
retained physical identity, and native preparation checks protection. Pulumi
preflight subsequently compares only context, program, configuration and tool
identity; execution sends the saved plan without a fresh resource check. Admission
reobserves retirement proofs, but not collection proofs. A same-URN replacement
between review and apply can therefore escape the retained-incarnation boundary.
Pulumi's saved deletion constraints bind the URN and operation class rather than
an atomic physical-ID condition; see canonical project
`mori://pulumi/pulumi/repos/pulumi`, `pkg/resource/deploy/plan.go` and
`pkg/resource/deploy/step_generator.go` (artifact-level URI pending). No native
teardown was attempted.

**Required repair/verification:** Bind the exact selected native stack entry and
protection state into collection evidence, and recheck both during preflight and
immediately before saved-plan execution. Refuse changed ID, protection, and
relevant entry contents, including a change between preflight and execution.
Preserve ordinary-operation compatibility. Document that these checks do not
create atomic provider CAS against arbitrary external writers. Independently
verify the regression and a fresh disposable native collection before closure.

**Implementation update (2026-10-02, `e1371442`; claude-opus-5-5):** This completes the `27bb0cd4` checkpoint. `cloudCollectionPhysicalDigest` now takes the retained physical identity of each selected URN from inventory history (`CloudHistory.cloudCollectingPhysical`, passed as `PulumiRuntimeConfig.runtimeCollectionPhysical`; admission already checks the review's collection proof against the head). Preparation (before `pulumi preview`), preflight and the check immediately before `pulumi up --plan` require each selected stack entry's `id` to equal that identity, beside the existing protection and entry binding. Regression `collection rechecks exact incarnation and native protection immediately before effect` covers a replacement before preparation, a missing retained identity, and changed ID or protection between preflight and execution. Each refuses before preview or up. All 1,129 `nagarectl` tests pass. The code comment records that these are fresh guards, not provider CAS. Remaining: independent review and a fresh disposable native collection.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The recheck runs at preparation, at preflight, and in the identity reread immediately before `pulumi up --plan`, because collection is a `RetireResource`. With the ID comparison disabled, the regression fails ("replacement incarnation was prepared") ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Status set to Verifying. Next check: native exact collection in phase 3a and the teardown leaf collections in 3b.

**Brief deviation, pending reviewer write-up (2026-10-04; transcribed 2026-10-05 by nagare-84 from the nagare-reviewer and nagare-f3 session logs):** The independent review brief mapped F33 to phase 3a's image cleanup, and that mapping was wrong. At 19:58Z nagare-f3 corrected it: `cleanup --images` prunes the VM's container image cache (F32) and never runs a cloud collection. At 19:58:34Z the reviewer confirmed the correction in source. F33's native check therefore belongs entirely to phase 3b, in the teardown's reviewed leaf collections, with the evidence nagare-f3 agreed to export: each leaf's review and digest, plan and apply logs with preflight and execution results, the converged transaction, and the selected stack entry's URN, provider ID and protection before and after. The reviewer said it would record this deviation in its phase 3 results, and `phase3a-c3-mp23-c3i.json` does not yet contain it.

## F39

**Staged cloud teardown cannot prepare any Pulumi operation on a real stack** — P1; **Verifying**; owners EP-153 / EP-156.

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

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. The regression fails without the fix with the native `PulumiResourceStepMissing` ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the staged retirement records from the acceptance C3 teardown (phase 3b).

## F40

**A real context cannot be retired: contribution targets, scope cycles and host or artifact members block every teardown** — P1; **Partial**; owners EP-153 / EP-156.

**Implementer native evidence (2026-10-03, claude-opus-5-5, checkpoint C3 context `mp23-c3`, development build of `24320d82`+):** After the F39 fix, teardown stage 1 (cloud policy, 14 `VerifyResource`) converged. Stage 2, the cloud scope retirement, refused with `dangling-reference`, because every platform scope still consumes cloud resources. Retiring the platform scopes one at a time through `inventory retire` hit four defects in turn:

1. `auth` refused with `retained or retiring resource lacks immutable native evidence`. A diagnostic build named the missing members: `platform:auth/auth/object-4eecf2a0…` (ConfigMap `nagare-access-backends`) and `platform:auth/auth/shomei-settings`. Both are composed contribution targets with a typed spec (`BackendMapSpec`, `ShomeiSettingsSpec`) whose bytes no review stores.
2. Once natives were supplied, planning refused with `retirement-required` for the same two members, and admission refused with `retention-coverage`. Retirement decisions (`Lifecycle.decideRetirement`) and retention proofs (`Plan/Changes.buildRetentionProofs`) enumerated raw scope bundles, while admission counts removed members over composed history.
3. Apply then refused in `CdnHistory.reviewedHistoricalCdn` with `historical CDN resource is absent or ambiguous`. That function looks up every retention proof in the owner's raw bundles before filtering to CDN.
4. After `auth` retired, every later command on the store refused while loading history: `StoreInvalidObject "scopes/0627…json" "retained resource declaration is missing"`. `Plan/History.loadRetained` rebuilds a retained member from the owner's raw bundles only. The development fix below repaired the store, and status then reported 171 resources and 68 retained.

Two structural limits followed:

- **Scope cycles.** Serving, Kourier and the net-certmanager scope consume each other (for example, 745 Serving references from Kourier and 576 from net-certmanager, plus 7 the other way). The CLI accepted one `--scope`, so no order could retire them.
- **Unsupported member types.** `host` (NixOS system), `kubeconfig`, `net-controller-image`, `host-image` (GCE image) and `host-image-build` refuse with `invalid-retirement`. Retention supports only Kubernetes, Helm, broker, CDN and platform cloud members. `host`, `host-image` and `host-image-build` consume the cloud scope, so the cloud retirement, and every VM or bucket collection after it, cannot be reviewed. The runbook's teardown acceptance was written for a perimeter-only context; a full context was never exercised.

**Implementation update (2026-10-03; claude-opus-5-5), the Kubernetes part:**
- `Status.loadNativeFor` compiles contributed namespace, backend-map and Shomei natives from the composed accepted or retained typed spec, beside stored review evidence.
- `decideRetirement` and `buildRetentionProofs` use composed history, matching admission.
- `reviewedHistoricalCdn` skips a retention that is not a raw member of the owner scope (it cannot be a CDN record) and still refuses an ambiguous match.
- `loadRetained` falls back to composing the owner scope alone. Consumers that contribute to a target retire before its owner, so this reproduces the retained member.
- `inventory retire` takes repeated `--scope`, so mutually dependent scopes retire in one review.
- New regression `test/InventoryContributionRetirementSpec.hs` (`scope retirement retains its composed contribution target and reloads it (F40)`). It fails on the committed code with the native `retirement-required` for the same resource ID.
- All 1,175 tests, `just haskell-style-check` and both architecture checks pass.
- Native: on `mp23-c3` the development build retired, store-only, the stamp, all observability scopes, `auth` (31 retentions, including both contributed targets), `foundation`, and then `cert-manager`, `certificate-issuer`, `kourier`, `net-certmanager` and `serving` together (132 retentions, no operations, 42 s).

**Implementation update 2 (2026-10-03; claude-opus-5-5), host, artifact and cloud retention:**
- `Plan/Lifecycle` accepts host and artifact members for retirement as history only; no collection supports them.
- Execution observes retiring host and artifact members with the accepted-manifest observer, which can't prepare or execute. Its Kubernetes and Helm native-evidence check excludes them.
- A cloud retirement now installs the Pulumi observer and Pulumi environment: its retained members count as selected even though the review has no operations. Before this, admission refused with `retention-observation`.
- New regression: `scope retirement retains a host system as history (F40)`.
- All 1,176 tests and every gate pass.
- Native: `host`, `kubeconfig`, `net-controller-image`, `host-image` and `host-image-build` retired together (5 retentions, 16 s). Then teardown stage 2 retired the cloud scope (26 retentions, `tx-705bf20b…`).

**Remaining, a design gap:** Staged collection then reports `No eligible cloud collection; 26 protected or dependency-blocked members remain retained`. The `inventory gc --plan` assessment gives two reasons for every cloud member:
- `dependent-consumers`: retained consumers block their producers. The retained `bootstrap-stamp` ConfigMap consumes every cloud member; the retained host system consumes the VM; Pulumi ordering makes even `nagare-apex` depend on the VM and firewalls.
- `exact-incarnation-not-present`: observation was `unknown`, so the gc assessment also lacks a Pulumi observer for retained cloud members.

Kubernetes members can be collected one review at a time, but host and artifact members have no collection at all. So the VM, image and buckets they consume never become eligible. A full context still cannot be torn down through reviews; it needs a way to collect a VM's workloads along with it (operator decision pending). Independent review is also needed.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Both in-scope regressions fail without their fixes with the native errors (`retirement-required`, `invalid-retirement` for the host system) ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). The remainder (retained consumers pin the VM; the collection assessment lacks a retained-cloud observer; protected data has no reviewed deletion) is exactly MasterPlan 25's three obstacles, so only that remainder is left. Stays **Partial** by operator decision. Next check: native retirement in the acceptance C3 teardown (phase 3b).

## F43

**A fresh inventory context cannot enable the platform Google CDN backend, so B3 cannot run** — P1; **Verifying**; owners EP-158 / EP-156.

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

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read; `scripts/lib/target.sh` only adds validation and the guardrail is unchanged. The catalog-admission mutation fails, and the eight Pulumi program tests pass ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: native B3 on the acceptance C3 (phase 3a).

## F44

**Inventory status on a cloud context never observes cloud-foundation members, so cloud runner evidence cannot assemble** — P1; **Verifying**; owners EP-153 / EP-157.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `14071e58`, C3 checkpoint `mp23-c3f`):** On the converged cloud context, `inventory status --json` reports `observationComplete: false` and `missingProviders: ["CloudFoundationExecutor"]`. The two foundation members (`platform:cloud-foundation/pulumi-stack/mp23-c3f` and the state bucket) are `unknown` with "provider observation is unavailable". The same was visible on the `db808a74` checkpoint ("unavailable providers: [CloudFoundationExecutor]"). The evidence assembler requires the runner's final observation to be complete with no missing providers (F42 keeps that check). So no cloud run can produce `inventory-evidence.json`, even with every other provider configured.

**Required repair/verification:**
- Install the CloudFoundation observer in the status and observation registry for cloud contexts: a read-only bucket and stack check through the same guarded path the foundation adapter uses.
- Regression: status on a cloud fixture is complete.
- Native: the C3 runner's final observation is complete.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b):** `inventory status` now builds the cloud-foundation adapter whenever accepted members use `CloudFoundationExecutor`, with the same `inventoryFoundationAdapter` path planning and execution use: the full accepted declarations, the selected member IDs, the platform workspace, the backend and inventory bucket checks. It observes through the adapter's read-only `foundationInspect` (bucket and stack describe), adds those facts to the observation set, and lists the adapter among the providers. To stop a future executor from being silently unobserved, `Executor` derives `Enum`/`Bounded`, `Nagare.Inventory.Status.missingStatusObservers` returns every executor without an observer, and status refuses to run if any is missing. Regression: `test/InventoryObservationSpec.hs` "inventory status must register an observer for every executor (F44)" fails for the pre-F44 observer set and passes with the cloud-foundation observer. This is a structural regression, not an end-to-end status run on a cloud fixture; the native check on `mp23-c3f` remains the proof that the final observation is complete. Gates: in a clean worktree at HEAD plus only these changes, all 1,178 `nagarectl` tests pass except the 18 that compile fixture configs, which fail there for want of a GHC package environment and pass in the main tree; the new test passes; fourmolu and both architecture checks pass.

**Native verification (2026-10-03, nagare-f3 on the C3 checkpoint `mp23-c3f`, HEAD `9c831749` built into a separate build directory; recorded by nagare-phase-b):** `inventory status --json` reported `observationComplete: true` and `missingProviders: []`, listed the `gcloud-foundation` provider beside the Kubernetes, Helm, Pulumi, artifact, host, manifest and Redpanda providers, and classified all 306 findings `converged`, including the Pulumi stack and the state bucket. Evidence: `/private/tmp/nagare-mp23-c3f/pending-evidence/f44-status/status.json; summary archived in [the C3 checkpoint record](mp23-implementer-results-2026-10-03/c3-checkpoint-14071e58.json)` (to be archived with the C3 results). Remaining: the final candidate's C3 runner observation and independent review.

**Cloud rehearsal (status completeness) (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3g`):** a nix build of `471cb409` (F45–F47) ran the cloud runner (`scripts/rehearse-gcp-inventory-release.sh --candidate`) on the checkpoint context, which runs the `7d486457` payload. Plan, apply and verify ran back to back: one `CreateResource` of `runner-probe`, verify killed before its marker and re-run to `verified`, a zero-operation no-op review, and a final observation with `observationComplete: true` and `missingProviders: []`. All 17 cloud assertions recorded and finalized. `scripts/assemble-managed-resource-evidence.sh` then assembled `inventory-evidence.json`, the first cloud assembly. This is pipeline evidence, not acceptance: the evidence is labelled with the `471cb409` payload although the context runs `7d486457` ([F48](#f48)). Two helper defects were found and fixed on the way (`4ad4392a`, `e41b1cab`). The cloud wrapper cannot forward `--private-store-export`, so the private export was taken right after verify with the head unchanged (generation 940, sequence 809).

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The regression is structural: it compares `missingStatusObservers` with a list, not the executable's real observer registry (`app/Nagare/Cli/Commands/Inventory/Status.hs`), so only native evidence proves the behaviour ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the acceptance C3 runner's final observation is complete (phase 3a).

## F45

**Reviewed Google CDN deploy on an inventory context cannot observe or apply its DNS record** — P1; **Verifying**; owners EP-158 / EP-156.

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

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read: the apex guard stays fail-closed on a failed `apexIp` read. The role-binding regression fails without the fix ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: the native B3 CDN cycle on the acceptance C3 (phase 3a).

## F46

**A retired site's edge DNS record can never be collected, because retained release history orders after it** — P1; **Verifying**; owners EP-158 / EP-156.

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

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** The `AppDeploySpec` and `SiteInventory/Server` regressions fail without the fix ([phase-1 record](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Next check: native B3 including collection on the acceptance C3 (phase 3a).

## F47

**CDN platform outputs are read with the caller's Pulumi environment, not the active context's** — P2; **Verifying**; owner EP-158.

**Implementer native evidence (2026-10-04, claude-opus-5-5, `mp23-c3g`):** The CDN binding for `site deploy`/`app deploy` (`app/Nagare/Cli/Application/Cdn.hs`) and the DNS adapter run the project guard's `pulumi config` probe and read the platform outputs with a bare `pulumi -C <dir> stack output` (`Nagare.Ops.Pulumi.stackOutput`). They inherit the caller's `PULUMI_BACKEND_URL`, `PULUMI_HOME` and passphrase rather than exporting the active context's. In a clean `env -i` runner without the Pulumi variables, a CDN deploy plan refused with "no stack named 'mp23-c3g' found". It worked only after the wrapper exported `nagarectl context env`'s Pulumi variables.

**Required repair/verification:** read the outputs through the context-derived Pulumi runtime used by the cloud teardown and bootstrap paths (`prepareInfraTargetWithPulumi`). Then prove a CDN deploy plan in a clean environment that sets only the context selection.

**Implementation update (2026-10-04; claude-opus-5-5):** Both paths now call `ensurePulumiInWorkspaceWithDependencies False False False` before the guard. It exports the context's backend, home, passphrase file and stack, and selects the existing stack without installing dependencies or creating a missing stack. **Native:** with the development CLI, in the same clean runner without any Pulumi variable, the `scenario-cdn3` deploy plan now succeeds and observes its DNS record as missing (`review Cloud DNS A record … -> 34.36.179.6`). It was planned only, never applied. Before the change, the same command refused as above (`pending-evidence/f47/bare-before.log`, `bare-after.log` in the operator root). No unit regression: the change is environment preparation in the executable's `app/` modules.

**Verification (2026-10-04, nagare-reviewer, candidate `7596632c`):** Source read. There is no unit test, by design. Next check: in phase 3a, a CDN deploy plan in the clean runner on the acceptance C3.

## F48

**Inventory evidence names the manifest's payload without checking the payload the context runs** — P2; **Open**; owner MP-26 (the EP-168 port of the runner and assembler).

**Implementer evidence (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3g`):** `scripts/assemble-managed-resource-evidence.sh` binds the runner's operator revision (`operator-version.json`) to the release manifest. It then copies the manifest's payload digest into `inventory-evidence.json` as the run's payload. Neither the runner (`scripts/rehearse-managed-resources.sh`) nor the assembler records or checks the payload the context actually runs. The rehearsal on `mp23-c3g` shows the gap: a candidate `471cb409` CLI runs against a context bootstrapped from, and still pinned to, the `7d486457` payload. It produces evidence the assembler would label with the `471cb409` payload.

**Required repair/verification:** the runner records `nagarectl platform root --json` (payload id, source revision, digest), and the assembler requires its revision to equal the manifest's. Prove it with real runner output for both cases: a matching run assembles and a mixed run is refused. ADR 24 freezes the shell tools and assigns feature work to their Haskell port, so this lands with the EP-168 port.

**Procedural guard until then:** each acceptance run bootstraps a fresh context from the candidate's own payload (runbook §6 step 0 and §7). The operator records `platform root --json` in the run root and confirms its `revision` equals the candidate before the runner's plan.

## F52

**Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges** — P2; **Verifying**; owner EP-153.

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

**Operator decision (2026-10-04, superseding the deferral above; [retrospective](mp23-engineering-retrospective-2026-10-04.md) §6):**
- Un-deferred. Fix it in MP-23. It blocks MP-23 completion.
- The fix lands with a class-level interpreter regression under [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), [EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) M2's incarnation invariant. The regression must fail on the pre-fix source.
**Implementation update (2026-10-05; claude-opus-5-5):**
- **During the transaction.** `statusIncarnations` (`src/Nagare/Inventory/Status.hs`) drops the records of members that the active transaction's reviewed migration moves. `inventory status` and the recovery model both use it. Admission makes the desired revision accepted, so status observes the new address. The old record describes the previous address and cannot be compared there.
- **At convergence.** A `MigrateResource` destination is the member's new object. `convergedIncarnations` binds it as `Established`. `releaseClaimWith` drops migrated, retained and collected members' earlier records before binding, not after. Before this change, a renamed member, retained under the same resource ID, ended unrecorded. Now its new object is recorded. If the convergence observation is unavailable, the member stays unrecorded, never stale.
- **Regression:** `test/InventoryPostgresRenameSpec.hs`, "status never reports a renamed member as replaced, at any step (F52)". The reviewed rename runs with the old members' incarnations recorded. Status is computed as `inventory status` computes it after every Kubernetes request.
  - Without the status change, it reports `replaced-incarnation` for the moved members mid-transaction.
  - Without the convergence change, no new object is recorded.
  - With both, the run converges with no `replaced-incarnation` at any step, and every record names a new object.

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F52-status-compares-migrated-records.diff` (existing record) fails both "status never reports a renamed member as replaced, at any step (F52)" and the rename recovery model ("I3: status reports renamed members as replaced …"). The status half is proven, with class-level coverage: the rename model checks I3 at every stop, under every write fault.
- **Survived:** a mutant that stops a migration from establishing its destination's record (`Execute/Incarnations.hs`, `establishes … || migrates action` disabled) passes every F52 test and the whole recovery model. Nothing checks that the renamed members' new objects are recorded at convergence. The model's final checks pass with an empty record map.
- **Stays Verifying.** Needed: a regression that fails on that mutant (assert the renamed members' records name the new objects after convergence), and ideally a fault on the convergence observation in the rename model. The entry should also name the rename recovery model and I3 as its covering invariant.

## F53

**`nix flake check` fails at the candidate: sandbox-only test failures and stale check assertions** — P1 (the C4 gate requires a green flake check); **Verifying**; owner EP-154.

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

**Independent verdict, pending reviewer write-up (2026-10-05; transcribed by nagare-84 from nagare-reviewer's session at 00:54:21Z):** "I counted the new all-systems log myself: aarch64-darwin 36 passed and 0 failed, x86_64-linux 35 passed and 0 failed, with no build errors. The Linux checks ran through `ssh://builder@nix-gcp-builder`. So F53's `nix flake check` fix holds on both systems at `b74b7e49`." The reviewer noted that the log does not print its revision, so it relied on nagare-f3's statement that the run used the clean candidate worktree. This came after the reviewer had rejected an earlier "35/35 x86_64-linux" claim taken from the shared tree, in which every Linux check had failed because the builder refused connections. The status stays Verifying until the reviewer writes its own closure. [EP-174](../plans/174-gate-every-commit-before-any-native-run.md)'s full gate now makes that claim checkable: a salted builder probe plus a revision-bound record.

## F55

**A landed unready application update still has no exit when its review also updates its release history or verifies a member** — P1; **Verifying**; owners EP-153 / EP-173.

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

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F55a-companion-rule-create-configmap-only.diff` (the original create-only ConfigMap rule) and `F55b-companion-rule-no-verify.diff` (verifies not admitted) each fail the recovery model with I1 in the history-follows and durable-volume scenarios. `F55c-replan-any-never-started.diff` (any never-started operation may be replanned as a create) fails "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)".
- **Class gap (inferred from source):** real application scopes also carry task CronJobs, DomainMappings and broker triggers. A never-started update of one of these that the digest order puts after the Service is refused by the companion rule (`Plan/History.hs`), and the transaction wedges again. The model's scenarios contain only the Service, the history ConfigMap and a PVC.
- **Stays Verifying.** Needed: a model scenario whose release also changes a task CronJob and a DomainMapping (or a written proof that such companions always run before the Service), under `LandsUnready`.

## F56

**A landed application Service update whose Service is then replaced outside review has no exit** — P1; **Verifying**; owners EP-153 / EP-173.

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

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F56-target-replaced-recovery.diff` (no `RecoveryTargetReplaced`) and `F56-stop-accepts-replaced.diff` (the stop does not accept it) each fail the recovery model with I1 under `Replaced`.
- **Class gap (inferred from source):** an out-of-band deletion without recreation (`KubernetesAbsent`) also makes the conditional write impossible, but it falls to `RecoveryUnresolved` (`Adapters/Kubernetes.hs`). The worlds have no deletion fault.
- **Stays Verifying.** Needed: a `Deleted` world fault, and either a fix or a new finding for what it shows.

## F57

**A verification whose target is replaced after it ends ambiguous has no exit** — P1; **Verifying**; owners EP-153 / EP-173.

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

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F57a-verify-safe-to-retry.diff` (a verify's recovery is no longer safe-to-retry) and `F57b-journal-no-effect-refusal.diff` (a refused retry is not journalled as a no-effect failure) each fail the recovery model with I1 under `Replaced`.
- **Class gap (inferred from source):** every executor's verify writes nothing, yet Broker, CDN, Cloudflare and Foundation recovery return `RecoveryUnresolved` on a mismatch, which is the same wedge. The fix is Kubernetes-only, and those executors have no world until EP-173 M4.
- **Stays Verifying.** Needed: a generic fix keyed on `VerifyResource` (in recovery or the driver) with a generic-adapter regression. The other route is for the operator to scope the other executors to EP-173 M4 explicitly; that is a deferral and needs the ledger.

## F58

**An application whose first deploy stopped unready cannot be retired, because a never-created member has nothing to retain** — P2 (no wedge: the store stays idle, but the application can be deleted only by first shipping a working image); **Verifying**; owners EP-153 / EP-173.

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

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F58-absence-proof-holds-no-data.diff` and `F58-admission-absence-recheck.diff` (existing records) each fail their focused regressions in "application update recovery".
- **Data safety (source review):** only `ConfirmedAbsent` members that are stateless or whose create never started (every journal event `Pending`) get an absence proof. Lost-acknowledgement creates cannot qualify, proofs are bound to the accepted revision, and nothing in retirement deletes an absent member.
- **Gap:** admission's own `holdsNoData` check (`Execute/Admission.hs`) has no regression; the recorded mutation reverts only the planning side.
- **Stays Verifying.** Needed: a regression in which a review carries an absence proof for a durable volume and admission refuses it, plus a mutation of the admission check that makes it fail.

**Implementation update, admission regression (2026-10-05; claude-opus-5-5; item 9 of nagare-84's review):** `test/InventoryApplicationUpdateRecoverySpec.hs`, "admission refuses an absence proof for a member that holds data (F58)". A saved retirement review is edited on disk, as an operator could edit it: the durable volume's retention proof becomes an absence proof, and the bundle is reloaded through `loadReviewBundle`, published and verified. With the volume absent, admission must refuse with `retention-coverage`, and accepted history must keep the scope. Mutation `test/mutations/F58-admission-holds-no-data.diff` (drop the no-data condition in `retentionCoverage`) makes it fail (see the README row).

## F59

**A standalone database whose StatefulSet is created but never becomes Ready has no exit** — P1 (a stuck state: every later plan on the context is refused); **Partial** (reopened 2026-10-05 by independent verification); owners EP-153 / EP-173.

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

**Independent verification (2026-10-05, nagare-84 as reviewer; master `efa687b3`; observed unless marked inferred).** Mutation runs, each a scratch-worktree build plus the named tests; the diffs are in [`cli/nagarectl/test/mutations/`](../../cli/nagarectl/test/mutations/README.md):
- `F59-statefulset-create-awaits-readiness.diff`, `F59-standalone-statefulset-stop.diff` and `F59-statefulset-pending-companions.diff` (existing records) each fail the recovery model with one I1 violation under `LandsUnready` on the database StatefulSet create. The stop itself is sound: the StatefulSet mounts the separately created, retained PVC by claim name, and the stop accepts nothing.
- **Gap A (inferred from source, model reproduction requested):** `loadUnstartedApplicationCreates` (`Plan/History.hs`) computes never-started creates only for `Application` scopes. After a database stop with `backup-signing-key` still `Pending`, both a corrected review and retirement refuse with `durable-resource-missing`. The operation order follows the operation-ID digest, so this depends on the database name. The store stays idle but the database scope cannot move, so the follow-up exit the fix promises is broken for those names.
- **Gap B (inferred):** a broker StatefulSet with topics under `LandsUnready` has no exit, because the create path requires every operation to use `KubernetesExecutor` and topics use `BrokerExecutor`.
- **Reopened as Partial.** Needed: a post-stop corrected-review or retire step in the database scenario, on a fixture whose signing-key create is unstarted at the stall (it should fail on HEAD); a broker scenario under `LandsUnready`; and fixes for both.

**Implementation update, gap A (2026-10-05; claude-opus-5-5):**
- **Reproduced on HEAD `ab3d5bdc` (observed).** The recovery model's new scenario "create a database, then retire it" runs under `LandsUnready` on the StatefulSet create, followed by the F59 stop. Retirement then refuses at planning with `durable-resource-missing` on `standalone:database-pg/pg/backup-signing-key`, the never-started create.
- **Fix.** `loadUnstartedApplicationCreates` (`Plan/History.hs`) also computes never-started creates for standalone scopes, so a stopped database's unstarted members retire as F58 absences.
- **Mutation.** `test/mutations/F59-standalone-unstarted-creates.diff`.
- **Not started:** gap B (brokers) is held by the operator's instruction of 2026-10-05.

## F60

**One out-of-band replacement between a create and convergence is recorded as the accepted incarnation** — P2; **Open** (scheduled by [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md), operator decision 2026-10-05); owner EP-173.

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

## F61

**A reviewed PostgreSQL rename whose copy Job fails partway has no exit** — P1; **Open**; owner EP-173 / EP-153.

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

## F62

**A reviewed rename copies from, and retains, a source replaced outside review** — P2; **Open**; owner EP-153 / EP-173.

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

## F63

**A Deployment or database StatefulSet update that lands but never becomes Ready has no exit** — P1; **Open**; owner EP-153 / EP-173.

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
- **Worker Deployments are not fixed.** The fix was written and is held, uncommitted, in [`mp23-held-work/`](mp23-held-work/README.md). The fault-free worker scenario fails I1 on HEAD (observed). With the held patch the fault sweep still shows nine worker wedges.
- **Worker Deployments, fixed (2026-10-06, EP-180 M1; observed).** The held patch predates ADR 26 and was not used.
  - What failed: the generated scenario `kind ("apps","deployment"): update` under `(MutateCall 3, LandsUnready)`. The Deployment's create landed unready and was closed. The corrected review was then refused at planning ("required condition is not ready"), reported as "I1: planning refused".
  - The fix: `validateBefore` (`Adapters/Kubernetes.hs`) admits an update of an owned, unready Deployment, as it does for a StatefulSet. A Deployment rollout replaces stuck pods (RES-4 §2), so a correction takes effect.
  - The pinned test "a corrective update of an unready Deployment plans and closes" now exits `[[Close]]`.
  - Mutation: `test/mutations/F63-deployment-correction-refused.diff`.
  - A landed-unready proof for Deployments in `recover` was not added. Close already classes the exactly landed, unready update as `Landed` through settlement.
  - The StatefulSet half needs RES-4's G3 (EP-181): a StatefulSet correction does not replace a stuck pod.
- **World fidelity, for review (inferred):** the world now restricts persistent status churn to Knative Services. A settled StatefulSet's status changes only when its pods change. Without this restriction, the StatefulSet update gave 75 I7 violations (each needing `abandon-refused-operation`).

## F64

**An intended update whose target is deleted outside review, and not recreated, has no exit** — P1; **Verifying**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5)**, with a new world fault `Deleted`: an owned object deleted out of band at an observation boundary, never recreated. This is item 5 of nagare-84's review. Reproduced on HEAD `ab3d5bdc` (observed): I1 in "create then good update", in the bad-update scenarios and in the database update scenario. The target was the release-history ConfigMap, the Service or the database StatefulSet. Recovery reported `RecoveryUnresolved`, and every exit refused.

**Fix.** An intended update whose owned target is gone answers `RecoverySafeToRetry` (`Adapters/Kubernetes.hs`). The retry's preflight refuses the absent object before any effect, the driver journals the no-effect refusal (F57), and `abandon-refused-operation` ends the transaction. A corrected review then recreates the stateless member.

A dedicated stop-only decision for Services and StatefulSets was written first. Its mutation survived, because the retry-then-abandon exit already covers those kinds. So it was removed to keep one rule.

**Mutation.** `test/mutations/F64-deleted-update-target-retry.diff`.

**Model changes made alongside, for review (each a relaxation; observed reasons):**
- **I4** counts writes per transaction, and the deleted object's write no longer counts. A later review reuses deterministic operation IDs, and rewriting an object deleted out of band is not a repeated effect.
- **I2** skips members deleted out of band after verification.
- **A planning refusal** of `durable-resource-missing` that names only members deleted out of band ends the scenario as expected. Data loss needs reviewed recovery or collection.

## F65

**The create-path stop refuses a review that recreates a deleted Service alongside its release-history update** — P1; **Verifying**; owners EP-153 / EP-173.

**Found by the EP-173 recovery model (2026-10-05, claude-opus-5-5)** under `Deleted`, observed on the F64-repaired tree. The Service is deleted out of band, so the next review plans `CreateResource` for it and `UpdateResource` for its release history. If the new revision is unready, F16's create-path stop refuses, because that path required every operation to be a create. The result is I1 in the bad-update scenarios.

**Fix.** F55's never-started-companion rule (`neverStartedCompanion`, `Plan/History.hs`) is shared by the update path and the create path. A never-started verify, or a never-started create or update of a stateless ConfigMap ordered after the stopped Service, is admitted on both paths.

**Mutation.** `test/mutations/F65-create-stop-companions.diff`.


## F66

**A create that finds an object not stamped as its own at its address settles unknown, so only an attested close can end it** — P1; **Verifying**; owners EP-153 / EP-177.

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

## F67

**An update refused after a status write, whose refusal's journal event is lost, settles unknown** — P1; **Verifying**; owners EP-153 / EP-180.

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

## F68

**An update whose target is deleted and replaced by an object not stamped as its own settles unknown, so only an attested close can end it** — P1; **Verifying**; owners EP-153 / EP-177.

**Found by the EP-177 five-scenario deep reruns on the remote builder (2026-10-06, claude-opus-5-5)**, classified locally (observed). In "create then good update" under `[(Observe 17, Deleted), (Observe 18, ForeignObject)]`, the Knative Service that the v2 update targets is deleted outside review. An object without this member's stamp then appears at its address. Settlement answered `SettledUnknown "Knative Service configuration or ownership changed since review"`, so close refused with `unknown-operation`.

**Why the class is provable.** It is F66's rule for updates. An update is conditional on the reviewed UID and stamps what it writes as this member's. An object at the address with another UID and without this member's stamp therefore proves the update's write is not live there. The write either never landed, or landed on the reviewed object, which is gone. That is ADR 26's `TargetGone` ("the reviewed object was replaced or deleted outside review"). The found UID is evidence only and is never bound (ADR 27 §1).

**Fix.** `settleMutation` (`Adapters/KubernetesProof.hs`) generalises F66's predicate. An object not stamped as this member at the address of a create over an absent before-state, or of an update whose reviewed UID differs from the found one, settles as `SettledTargetGone` with the found UID. Two cases keep their existing classes:
- an object with another UID that carries this member's stamp stays the F56 replacement path;
- an object with the reviewed UID is never gone, whatever its stamp now.

**Tests.**
- "an update whose target is replaced by an object not stamped as its own settles as target gone (F68)", in `InventorySettleSpec`.
- The schedule above, in the recovery model's "create-scenario fault pairs that had no exit now have one (EP-177, F66)".

**Mutation.** `test/mutations/F68-update-over-foreign-object-settles-unknown.diff`. F66's record is regenerated for the shared predicate.

## F69

**A Knative Service or DomainMapping reads ready from its previous generation's Ready=True before the controller has seen the new spec** — P1; **Verifying**; owners EP-153 / EP-180.

**Found by review of the readiness predicates (2026-10-06, claude-opus-5-5; inferred), and validated by RES-4 experiment E4 on k3s 1.34 with Knative 1.22 (observed).** After a spec write, Knative keeps the previous generation's `Ready=True` until its controller observes the new spec (`observedGeneration < generation`). It then reports `Ready=Unknown` at the new generation before it becomes `True`.

`knativeReady` (`Adapters/KubernetesReadiness.hs`, previously `Adapters/KubernetesRuntime.hs`) checked only the `Ready` condition. So right after an update, the old revision's readiness satisfied the readiness wait, and a bad image could be recorded as converged. It is used for both the Knative Service and the DomainMapping. This is a wrong success, but in a narrow window: an interrupt or verify within seconds of the write, or a lagging controller.

**Fix.** Ready requires `status.observedGeneration == metadata.generation` as well as `Ready=True` (RES-4 §2, U9). That is the same generation discipline `deploymentAvailable` and `statefulSetReady` already apply.

**Tests.** "a Knative Service or DomainMapping is ready only at the observed generation (F69)", in `InventoryKubernetesReadinessSpec`. The DomainMapping-conflict fixture in `InventoryKubernetesSpec` lacked both generation fields, which every real object carries, and was completed.

**Model.** The model test comes with EP-182's `ControllerLag` fault, once the world's readiness runs through the production parser.

**Documented limit.** `certificateReady` (cert-manager's `Certificate` and `ClusterIssuer`) has the same shape. cert-manager is a platform kind outside release line (b), so it is left as is.

**Mutation.** `test/mutations/F69-knative-ready-ignores-generation.diff` drops the generation check, and the test fails.

## F70

**A worker Deployment whose update never becomes available reads as ready, so a broken rollout is recorded as complete** — P1; **Verifying**; owners EP-153 / EP-180.

**Found by the RES-4 validation of Kubernetes semantics (2026-10-06, nagare-first-principle, experiment E5 on k3s 1.34; observed).** During a bad-image or crash-looping update of a one-replica Deployment, the old ReplicaSet keeps `Available=True`, because maxUnavailable rounds to 0. The controller has also observed the new generation. That stays true after `Progressing=False/ProgressDeadlineExceeded`.

`deploymentAvailable` (`Adapters/KubernetesReadiness.hs`, previously `Adapters/KubernetesRuntime.hs`) treated `Available=True ∧ observedGeneration == generation` as ready. So such a Deployment observed as `KubernetesPresent`. `recover` then returned `RecoveryProvedComplete` for the broken update, and plans saw the member converged. This is a wrong success: a broken state recorded as converged.

**Fix.** Readiness is the rule `kubectl rollout status` applies (RES-4 §2, U9): `observedGeneration == generation ∧ updatedReplicas == spec.replicas ∧ status.replicas == updatedReplicas ∧ availableReplicas == updatedReplicas`, with `spec.replicas` defaulting to 1. `ProgressDeadlineExceeded` is not terminal, so the Deployment stays not ready, and the update is landed.

**Tests.** "a Deployment is ready only when its rollout is complete, as kubectl rollout status judges it (F70)", in the new `InventoryKubernetesReadinessSpec`. It covers mid-rollout, past the progress deadline, rolled out, one generation behind, and an unavailable updated replica. The earlier assertions in `InventoryKubernetesSpec` that read `Available=True` as ready moved there and were corrected.

**Model.** The recovery model's world decides readiness from its own state, not through this predicate, so it cannot see F70. EP-182 routes the world's readiness through the production parser.

**Mutation.** `test/mutations/F70-deployment-ready-ignores-rollout.diff` reduces the rule to the observed generation, and the test fails.

## F71

**A Kubernetes write the API server definitively refused (409, 422, 404 and the other 4xx) is reported ambiguous** — P2; **Verifying**; owners EP-153 / EP-180.

**Found by RES-4's gap analysis (G4; 2026-10-06, nagare-first-principle; experiments E1, E3, E8 and E13 on k3s 1.34; observed).**
- **What happened.** The Kubernetes runtime mapped every non-zero `kubectl` exit to `AdapterEffectAmbiguous`, including the API server's definitive refusals. RES-4 U4: every 4xx refusal left the object unchanged.
- **The consequence.** A refused write needed a re-observation and a settlement it did not need, and with G6's status churn it could end Unknown.
- **The model never saw it.** The world returns `KnownNoEffect` for the same refusals, so the model never exercised the real path.

**Fix.** `kubectlRefusal` (`Adapters/KubernetesProof.hs`) maps the server's definitive answers to `KnownNoEffect`. Those answers are `Error from server (Conflict|Invalid|AlreadyExists|NotFound|Forbidden|BadRequest)`, `error: Operation cannot be fulfilled`, and a server-side-apply field conflict (`error: Apply failed with`, a 409; E13). Transport failures, timeouts and 5xx (`InternalError`, `ServiceUnavailable`, `Timeout`) stay ambiguous, because only they can hide a committed write. The runtime's failed-write branch applies it.

**Tests.**
- "a write the API server refused with a 4xx answer had no effect; only a missing answer is ambiguous (G4)", in `InventorySettleSpec`. It failed first against a stub.
- "an update the API server refuses with a 4xx is a known no effect; a lost connection stays ambiguous (G4)", in `InventoryKubernetesFieldTakeoverSpec`, through the fake kubectl interpreter. The wiring existed before this test, so its failing side is shown by the wiring record below.

**Mutations.** `test/mutations/G4-kubectl-refusal-ignored.diff` makes the classifier answer nothing, and both tests fail. `test/mutations/G4-runtime-refusal-ambiguous.diff` drops the runtime branch, and the wiring test fails.

## F72

**The Kubernetes transport refuses a corrective update of an unready StatefulSet or Deployment as an unsupported precondition** — P1; **Verifying**; owners EP-153 / EP-180.

**Found while building EP-180 M5 (2026-10-06, claude-opus-5-5); proved by a transport test through the fake kubectl interpreter (observed).**
- **The gap.** A corrective update of an unready object carries a `KubernetesNotReady` precondition. F63 admits one for StatefulSets, and EP-180 M1 for Deployments. The runtime's write path accepted only `KubernetesPresent` for an update, converting `NotReady` only for a Knative Service. So in production the correction was refused before reaching the API server, with "Kubernetes transport received an unsupported action or precondition".
- **Why the model missed it.** The recovery model's world implements its own writes rather than running the runtime's transport, so it passed F63's correction scenarios.

**Fix.** An update with a `NotReady` precondition is written like any other. G6's guard is its UID, its before-state stamp and its field owners, read live, so readiness has no part in the precondition. The transport still waits for readiness after the write.

**Tests.** "a corrective update of an unready object reaches the API server (F63, M1)", in `InventoryKubernetesFieldTakeoverSpec`. It failed with exactly that refusal.

**Mutation.** `test/mutations/F72-unready-update-unsupported.diff`.

**Model.** EP-182's world runs behind the production kubectl interpreter, so the model will exercise this path.

## F73

**A Knative Service update that another write left unready is awaited as ours and settles as Landed** — P1; **Verifying**; owners EP-180.

**Found before EP-180 M5b (2026-10-06, claude-opus-5-5); proved by an adapter test on the version-1 adapter (observed).**
- **The gap.** Recovery of a version-1 or version-3 update to a Knative Service returned `RecoveryAwaitingReadiness` for any owned, unready object on the reviewed UID, whatever its digest. Settle maps that decision to `SettledLanded`. So if another write of this member's left the object unready, this update was claimed landed when its write was not live.
- **Exposure.** Production Knative updates were version 2, which the arm excludes, so only a reviewed field takeover (version 3) reached it. M5b deletes version 2 and makes every Knative update version 1, so it would have become the default path. Version 2 was hiding this defect.

**Fix.** The arm also requires the reviewed digest. RES-4 U3: the stamp is written in the same atomic write as the spec, and the adapter reports the reviewed digest only while the stamp and the desired fields both match. That holds exactly while this update is live, through any status churn.

**Tests.** "a Knative Service update awaits readiness only while its own write is live (F73)", in `InventoryKnativeServiceUpdateSpec` (named `InventoryKubernetesConfigurationSpec` until M5b). It failed with `RecoveryAwaitingReadiness`.

**Mutation.** `test/mutations/F73-awaiting-readiness-ignores-digest.diff`.

**Model.** The recovery model's world observed Knative updates through the stable version-2 observation, so it never reached this arm. After M5b it does.

## F74

**A Kubernetes object being deleted is read as present** — P1; **Verifying**; owners EP-180.

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

