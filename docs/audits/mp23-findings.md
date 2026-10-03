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
| [F30](#f30) | P1 | Controller status churn strands admitted conditional Service correction | Open | EP-153 / EP-156 |
| [F31](#f31) | P1 | Registry refresh cadence permits credentials to expire before its next run | Open | EP-154 / EP-156 |
| [F32](#f32) | P1 | Image-cache cleanup selects an image used by active pod sandboxes | Open | EP-153 / EP-156 |
| [F33](#f33) | P1 | Cloud collection does not recheck its reviewed physical incarnation before deletion | Open | EP-153 / EP-156 |

Closed findings keep their full text, location, implementation updates and verification in [the closed-findings archive](mp23-archive/mp23-findings-closed.md). F01 and F11 retain their [earlier independent closure](mp23-archive/mp23-verification.md). F02, F03, F04, F05, F06, F07, F08 and F20 now have [2026-10-02 independent closure](mp23-independent-verification-2026-10-02.md). Other entries retain their status shown above.

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

## F16

**Unready application creation cannot yield to a corrected reviewed configuration** — P1; **Verifying**; owners EP-153 / EP-156.

**Native evidence:** The cloud fixture has 2 CPUs, with 1,785m allocated after full bootstrap. Application A's default web pod requests 275m and cannot schedule, although its PostgreSQL pod is Ready and its retained PVC is Bound. Public saved apply stops after 365.186 seconds at `op-711f755156b69c10be13390c`. Generation 576 keeps the original application transaction without claim, fence or migration. Its review targets only its 11 owned resources; [redacted evidence](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-capacity.json) preserves the review, identity and failure. No raw resize, patch, restart, review rewrite or history reset occurred.

**Implementation update:** A guarded `stop-incomplete-application` decision requires one changed Application scope, only unfenced owned Kubernetes creates, an originally absent stateless Knative Service proved owned and unchanged but unready, and no other uncertain operation. It journals selection before clearing the active transaction, retaining admitted ownership and prior converged revisions. It never completes the workload or rolls ownership back away from created retained data. The same decision settles a lost head acknowledgement without provider IO; ordinary proof cannot bypass a pending stop. A new application review can correct resource configuration. Knative conditional updates retain UID/resourceVersion and exclusive non-status ownership checks; installed update proof remains pending.

**Required verification:** Preserve unselected stopped applications' prior converged revisions when another scope completes. Prove created retained-data ownership survives stopping, foreign/durable/changed-native and multiple-uncertain refusals, exact decision replay after lost acknowledgement, and installed stop followed by a new corrected review. Require the same Service/PVC/database identities, Ready application and no platform revision change. Prove the Knative conditional update and unchanged replay through the public installed path.

**Verification:** The installed `0f6fa7db` stop passes in 12.441 seconds: all 24 accepted and 23 converged revisions and the original Service/PostgreSQL/PVC UIDs are preserved; generation 579 is idle. The corrected plan then refuses in 17.365 seconds at the original never-created backup signing key. [Redacted evidence](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-stop-and-replan.json) retains this consumer result. The follow-up repair derives never-started create proof from the original immutable stopped review and validated committed journal, only for planning that selects its unchanged unconverged application revision. Previously completed, uncertain, changed and foreign durable members still refuse; ordinary inspection and unrelated planning do not scan execution history. The final CLI suite passes all 997 tests in 52.48 seconds, covering never-started creation, completed data refusal, later uncertain intent, foreign ownership, changed declaration, superseded revision, missing committed journal and inspection/unrelated planning isolation. Structural style and the managed-command audit pass. The installed public bootstrap fixture passes. Installed `49db2199` saves the corrected Application A review in 42.372 seconds and converges in 63.123 seconds: same Service/PostgreSQL/PVC UIDs, Ready Service, expected HTTP body and preserved seeded row. Only its accepted revision changes, with all 24 scopes converged at generation 605/sequence 539. [Redacted native proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/application-correction.json) retains the original NotReady UID/resourceVersion precondition and actual consumer results. A follow-up real-planner regression reproduces a convergence leak: completing another application incorrectly marks a stopped, unready application converged. The repair advances only revisions changed by the completing review and removes retired scopes; it preserves unselected prior convergence. The eight focused regression cases and all 998 CLI tests now pass (60.14 seconds); structural Haskell style passes. Installed `eb582eb0` builds successfully. A second regression exposes unchanged stopped members being omitted while remaining creates complete; selected unconverged scopes now require fresh verification for unchanged managed members. Native preparation still refuses NotReady verification, while a corrected Knative configuration uses its guarded update. All 998 tests pass after this extension in 67.46 seconds, and structural style passes. Final installed validation and independent closure remain open.

**Installed follow-up:** Immutable `2101b834` builds on aarch64-darwin and passes the installed public foundation/bootstrap fixture. Its [cloud interruption and second-root proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json) preserves every prior accepted owner and all application/database identities while recovering a separate backup without repeating its create. Its [installed stopped-readiness proof](mp23-archive/mp23-native-bootstrap-results-2026-09-30/cloud-stopped-notready-verification.json) now confirms unchanged NotReady replan refusal without a review or head change, followed by a corrected conditional update retaining the Service UID. All 29 scopes converge at generation 698/sequence 615; original application/database/PVC identities and data remain intact. Independent F16 closure remains open.

**Implementation update (2026-09-30):** EP-153 adds a bounded fixed-seed in-memory driver model to the ordinary `nagarectl-test` suite. Planner-produced create/update/selected-unconverged-verification/retention-retirement reviews across two Application scopes interrupt each provider-effect boundary and resume with recording-adapter proof; stale conditional writes refuse without mutating the head, and a foreign executor claim requires explicit takeover. The model checks no duplicate effect, selected-only revision completion, accepted/converged consistency, monotonic head/journal state, and finite ambiguity recovery. Its stopped-scope assertion rejects the `eb582eb0` convergence leak; its unchanged selected member assertion rejects the `7c957c02` readiness-verification leak. The focused model test and all 1,002 CLI tests pass; structural style passes. This is source-only evidence and does not replace the operator's F16 runbook verification on `f15-preview`.

## F30

**Controller status churn strands admitted conditional Service correction** — P1; **Open**; owners EP-153 / EP-156.

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

## F31

**Registry refresh cadence permits credentials to expire before its next run** — P1; **Open**; owners EP-154 / EP-156.

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

## F32

**Image-cache cleanup selects an image used by active pod sandboxes** — P1; **Open**; owners EP-153 / EP-156.

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

## F33

**Cloud collection does not recheck its reviewed physical incarnation before deletion** — P1; **Open**; owners EP-153 / EP-156.

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
