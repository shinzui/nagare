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
| [F49](#f49) | P1 | An out-of-band replacement of an accepted database is reported converged, and its new incarnation's receipts plan for ingestion | Verifying | EP-159 / EP-153 |
| [F50](mp23-archive/mp23-findings-closed.md#f50) | P2 | One transient failed gcloud read makes the state-bucket ownership guard stop a run | Closed | EP-156 |
| [F51](#f51) | P2 | Retirement retains an out-of-band replacement's identity instead of the accepted incarnation | Open | EP-153 / EP-159 |
| [F52](#f52) | P2 | Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges | Open | EP-153 |

Closed findings keep their full text, location, implementation updates and verification in [the closed-findings archive](mp23-archive/mp23-findings-closed.md). F01 and F11 retain their [earlier independent closure](mp23-archive/mp23-verification.md). F02, F03, F04, F05, F06, F07, F08 and F20 now have [2026-10-02 independent closure](mp23-independent-verification-2026-10-02.md). F34, F35, F36, F37, F38, F41 and F42 have 2026-10-04 independent closure on candidate `7596632c`, and F50 on candidate `847543896d07` ([records](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). Other entries retain their status shown above.

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

## F49

**An out-of-band replacement of an accepted database is reported converged, and its new incarnation's receipts plan for ingestion** — P1; **Verifying**; owners EP-159 / EP-153.

**Native evidence (2026-10-04, candidate `7596632c`, C2 context on cp3):** The EP-159 source-replacement drill ([procedure and results](mp23-implementer-results-2026-10-03/ep159-source-replacement-7596632c.json), implementer nagare-phase-b, commit `d19df6d1`) replaced the accepted throwaway database `personal/ep159-throwaway` out of band:
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
- **Implementer native evidence (2026-10-04, frozen candidate `84754389`, the C2 context on cp3; [record](mp23-implementer-results-2026-10-03/ep159-source-replacement-84754389.json)):**
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
- **Receipt C, native (2026-10-04, `84754389`, [record](mp23-implementer-results-2026-10-03/f49-receipt-c-84754389.json)):** a fresh throwaway was replaced out of band, and its 22:45Z backup Job (`43925446…`, UID taken from kubectl) wrote receipt C from the replacement.
  - `db backup-receipts f49c-throwaway --backup-id C --save-plan DIR` refused: exit 1, "scheduled receipt source is not the accepted database incarnation; it was replaced outside Nagare".
  - No review directory existed before or after, and the head was unchanged.
  - The incarnation records were unchanged, and status listed `replaced-incarnation` for exactly the throwaway's StatefulSet and PVC.

**Cleanup note:** `db retire ep159-throwaway` refuses with `dangling-reference` (receipt A's scope consumes the database's backup producer). The joint `inventory retire --scope standalone:database-ep159-throwaway --scope standalone:database-scheduled-receipt-personal-ep159-throwaway-42fee7bd-299e-47a7-90e4-fd726f5c9783 --out DIR` plans successfully (reviewer, read-only, head unchanged). That joint retire is the supported path for a database with ingested receipts.

**Verification (2026-10-04, nagare-reviewer, candidate `847543896d07`):** Source read (`38815245`, `84754389`). All 1,190 tests pass at the candidate. The reviewer's own mutations each fail exactly their regression: removing recording at convergence, disabling the status comparison, disabling the ingestion check, allowing a Proved rebind, and dropping StatefulSet selection ([mutations](mp23-independent-results-2026-10-04/candidate-84754389-mutations.txt)). Native read-only cross-checks: the C2 head records the eight incarnations of the platform `en-db` and `shomei-db` members, and they equal the live UIDs. The drill v2 record matches its raw outputs (`pending-evidence/ep159/`): B and restore A refused, listing and `--check-freshness` refused with F49's message, 7b verified A, and `replaced-incarnation` appeared for exactly the throwaway's StatefulSet and PVC. **Not yet closed:** receipt C, the case this finding was opened for, still has no native refusal. `db backup-receipts --backup-id C --save-plan` does not go through the listing's source check (`resolveScheduledSource`). It observes the live UIDs and relies only on the F49 check in `compileScheduledIngestScope`, which only the unit regression covers. Also, `receipt-C.txt` records "no receipt C appeared", although a 22:30Z Job succeeded; correct that record. **Next check:** a native C ingestion attempt on a fresh throwaway, taking the Job UID from `kubectl`, must refuse with no review saved and the head unchanged. Two defects in the fix's surroundings are opened separately: [F51](#f51) and [F52](#f52).

## F51

**Retirement retains an out-of-band replacement's identity instead of the accepted incarnation** — P2; **Open**; owners EP-153 / EP-159.

**Native evidence (2026-10-04, candidate `847543896d07`, C2 context on cp3; F49 drill v2, implementer nagare-phase-b, [results](mp23-implementer-results-2026-10-03/ep159-source-replacement-84754389.json)):** the throwaway's accepted incarnations were StatefulSet `770c18c5…` and PVC `241e2475…`. After the out-of-band replacement, status correctly reported `replaced-incarnation`. The joint `inventory retire` of the database and receipt A's scope then converged. Independent read of the head by nagare-reviewer: `retained` carries the *replacement* UIDs, StatefulSet `b131b5a7-779d-4f19-843e-3a5e78be5306` and PVC `4a6d653c-53fb-4630-99fc-902be522632d`. The `incarnations` entries for the throwaway were dropped.

**Cause (source):** `releaseClaimWith` drops incarnation records for retained members, "since `retained` carries their identity". But retirement records the identity it observes at retirement, not the recorded incarnation. A retirement review never compares the two.

**Why it matters:** this is the laundering ADR 22's F49 amendment rules out ("a later review never launders an object that replaced the accepted one outside Nagare"), only through retirement instead of update or verify. Retained history then names an object Nagare never accepted:
- a later reviewed collection would target the replacement;
- retained-data operations would treat the replacement PVC, possibly empty, as the retained data.

**Required repair/verification:** retirement of a member whose observed UID differs from its recorded incarnation must refuse, naming the member. Or it must retain the recorded incarnation and mark it absent or replaced, never the replacement's UID. Regression: retiring a scope with a replaced member never puts the replacement UID in `retained`. Native: on a throwaway, after an out-of-band replacement, the retirement refuses or retains the accepted identity.

**Operator decision (2026-10-04, in session nagare-phase-b):** deferred as a known limitation of this release, to be documented in ADR 22 and the release notes and fixed in a follow-up. It does not block MP-23 completion.

## F52

**Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges** — P2; **Open**; owner EP-153.

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
