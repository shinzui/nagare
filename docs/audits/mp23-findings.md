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
| [F34](#f34) | P1 | Kourier gateway rejects HTTPS listener updates on cp3, so new routes never become Ready | Open | EP-155 / EP-153 |
| [F35](#f35) | P1 | Preflight refusal after admission strands the transaction with no supported exit | Verifying | EP-153 / EP-160 |
| [F36](#f36) | P1 | A failed Redis scratch restore cannot be abandoned and wedges the store | Verifying | EP-160 |
| [F37](#f37) | P1 | Configuration drift written by another field manager has no reviewed repair | Verifying | EP-149 / EP-153 |
| [F38](#f38) | P2 | A failed GCS head advance after a published journal event stops ambiguous and discards the store error | Open | EP-153 / EP-156 |
| [F39](#f39) | P1 | Staged cloud teardown cannot prepare any Pulumi operation on a real stack | Verifying | EP-153 / EP-156 |
| [F40](#f40) | P1 | A real context cannot be retired: contribution targets, scope cycles and host or artifact members block every teardown | Partial | EP-153 / EP-156 |
| [F41](#f41) | P1 | A local node restart destroys every local backup, and local escrow verification needs the source cluster | Verifying | EP-155 / EP-159 |
| [F42](#f42) | P1 | The managed-resource evidence assembler can never accept real runner output | Verifying | EP-157 |

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

**Implementation update (2026-10-02, MP-23 A4 resume attempt; claude-opus-5-5):** With no live executor process and the store still at generation 9314 with the original claim, the admitting binary (`ab3aabf7…`, same isolated operator root) ran the public `inventory resume tx-b4da295e… --yes`. It exited 1 after 3 s with `ambiguous … at op-fed6a9432af7669b7446f230` and wrote no provider effect. That is the driver's correct refusal to retry an unproved update. Read-only observation: the Service keeps UID `470ff139…` at generation/observedGeneration 2; ConfigurationsReady is True; revision 00002 is Running 2/2; Ready/RoutesReady are Unknown ("Waiting for load balancer to be ready"). The cause is [F34](#f34), not the F30 repair. Following the stop rule, no `inventory recover`, takeover, patch or rollback was attempted, and the transaction remains preserved. Private record: `/tmp/mp23-independent-application-correction/a4-resume-refusal.json`. Next: diagnose and repair F34 under a written recovery plan, then resume the same transaction and verify identities, the known row and replay.

**Implementation update (2026-10-02, A4 terminal state; claude-opus-5-5):** After the F34 repair, the same public `inventory resume tx-b4da295e… --yes`, with the same admitting binary and root, exited 0 in 3 s (`converged`). Store status shows no active transaction or claim (generation 9322). Service `470ff139…` (generation 2, Ready), StatefulSet `03a23352…` and PVC `15138d3a…` are unchanged, and `select id, value from mp23_correction_probe` returns `1|mp23-original-data-before-correction`. An unchanged `app deploy … --save-plan` replan with the scope's recorded tag, image resource and recovery binding produced review `701d1306…` with zero operations. No rollback, patch or history reset occurred. Private record: `/tmp/mp23-independent-application-correction/a4-f34-recovery.json`. F30 and F16 now await independent verification.

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

**Implementation update (2026-10-02, `ebe9d3a7`; claude-opus-5-5):** `nixos/hosts/nagare-01/registries.nix` now runs the pull-Secret timer every 120 s (`AccuracySec` 5 s) with a 60 s `TimeoutStartSec`. A module assertion requires interval + accuracy + timeout < 300 s, the minimum `expires_in` the script accepts, which is the metadata cache floor. An unchanged token and current ServiceAccount cause no Kubernetes write (compared on stdin; the token never enters argv), and a rotated token keeps the resourceVersion-conditional replace. `python3 scripts/test-registry-credential-delegation.py` passes the cadence invariant, create, no-op, rotation, ≤300 s refusal, six foreign/race refusals and the legacy policy. It fails against the previous module. `nix eval` of the `nagare-01` toplevel drv succeeds. Remaining: an installed fresh-host observation of an automatic replacement before expiry and an expired-boot-credential private pull (EP-156 C3); independent closure.

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

**Implementation update (2026-10-02, `c2dc2bb1`; claude-opus-5-5):** The production script (`cli/nagarectl/src/Nagare/Inventory/ImagePruneScript.hs`) adds every pod sandbox's image (`crictl pods -o json`, then `crictl inspectp -o json` `.info.image`, for Ready and NotReady sandboxes) and the configured sandbox image (`pinned_images` `sandbox` or legacy `sandbox_image` in `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`) to the resolved used set that both inspection and removal protect. A failed listing or inspection, a missing image field, or an absent or ambiguous configured image refuses the capture. Read-only observation on local k3s v1.34.6 (cp3) confirmed `crictl info` lacks the sandbox image, `inspectp` reports `.info.image`, and the pause image is `pinned=false`. `python3 scripts/test-image-prune-protocol.py` passes 23 cases (was 10), including sandbox-only, configured-only, seven fail-closed observations, ordinary deletion beside protected sandboxes, and inspection reporting sandbox images as used. The first sandbox case fails against the previous script. Remaining: a fresh installed native review that excludes protected images and deletes an ordinary unused one, with one-shot replay; independent closure.

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

**Implementation update (2026-10-02, `e1371442`; claude-opus-5-5):** This completes the `27bb0cd4` checkpoint. `cloudCollectionPhysicalDigest` now takes the retained physical identity of each selected URN from inventory history (`CloudHistory.cloudCollectingPhysical`, passed as `PulumiRuntimeConfig.runtimeCollectionPhysical`; admission already checks the review's collection proof against the head). Preparation (before `pulumi preview`), preflight and the check immediately before `pulumi up --plan` require each selected stack entry's `id` to equal that identity, beside the existing protection and entry binding. Regression `collection rechecks exact incarnation and native protection immediately before effect` covers a replacement before preparation, a missing retained identity, and changed ID or protection between preflight and execution. Each refuses before preview or up. All 1,129 `nagarectl` tests pass. The code comment records that these are fresh guards, not provider CAS. Remaining: independent review and a fresh disposable native collection.

## F34

**Kourier gateway rejects HTTPS listener updates on cp3, so new routes never become Ready** — P1; **Open**; owners EP-155 / EP-153.

**Observation (2026-10-02, implementation session claude-opus-5-5, read-only):** On local context `local` (Colima `nagare-mp23-cp3`, k3s v1.34.6), `net-kourier-controller` logs `Error pushing snapshot to gateway: … listener_8443 … listener_9443: multiple filter chains with overlapping matching rules` every ~0.3 s: 3,664 occurrences between 03:44:24Z and 04:02:42Z, continuous, with earlier logs rotated. Every Kubernetes Ingress reconciles, but the gateway refuses each new snapshot. The F30 Service's KIngress stays `LoadBalancerReady=Unknown`, while existing routes (`nagare-access`, `mp23-independent-volume`, `mp23-cleanup-pr-review`) stay Ready. Two ingresses, `mp23-correction-proof` (Ingress created 03:08:34Z) and `mp23-independent-volume`, terminate TLS with the same namespace wildcard secret `personal/personal.127-0-0-1.sslip.io` (`*.personal.127-0-0-1.sslip.io`). That is the leading hypothesis for the overlapping filter chains, but it is not confirmed: Kourier source was not available for inspection. This blocks MP-23 A4 (F30 terminal state) and any new local route, so EP-155 C2 too.

**Required diagnosis/repair:** Write the recovery as an ExecPlan step with pass/fail gates before any cluster change. Confirm from the Kourier/Envoy configuration which filter chains overlap. Decide whether Nagare's route/TLS rendering (ADR 20) produces the overlap for any second wildcard-TLS Service in a namespace; if so, it is a product defect needing a source fix and a local regression. Otherwise identify the fixture state that caused it. Do not patch Kourier objects, delete the shared certificate or reset history. After repair, resume the preserved F30 transaction through the public path.

**Implementation update (2026-10-02, `beca6886`; claude-opus-5-5):** Root cause confirmed from Envoy's admin `config_dump`. The rejected listener put `mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` in two filter chains: the wildcard-secret group and its own chain. The host belonged to KIngress `e11d734a…` and KCertificate `8255d8d4…`, both ownerless. The KIngress's `serving.knative.dev/domainMappingUID` label equals the tombstone physical identity of collected DomainMapping `standalone:site-preview-mp23-cleanup-pr-review/route/route`, and it routed to the deleted preview Service. Product cause: reviewed collection deleted DomainMappings with `propagationPolicy: Orphan`, and Knative, unlike for a Service, does not block orphaning a DomainMapping's children. Fix: DomainMappings are collected only through the controller-descendant authority, now extended to the net-certmanager chain. Preview cleanup selects it, a plain review refuses, and `collectionDeleteRequest` refuses an older saved Orphan review (ADR 22 amendment). Three authority regressions, the updated request test, all 1,132 `nagarectl` tests, all six public web-cleanup variants (now with a route certificate child and a refused plain route collection) and the style gate pass. Fixture repair (EP-155 step 2, written before acting): two UID/resourceVersion-preconditioned Background DELETEs of exactly those orphans, after rechecking ownership, label, absent Service and identity. The shared wildcard certificate, the unowned TLS Secret, Kourier objects and history were left untouched. Within 20 s both listeners had no `error_state`, `mp23-correction-proof` was `Ready=True`, prior routes stayed Ready, and the cert-manager chain was garbage-collected. Remaining: independent verification, and a native reviewed DomainMapping collection through the new authority on a candidate.

## F35

**Preflight refusal after admission strands the transaction with no supported exit** — P1; **Verifying**; owners EP-153 / EP-160.

**Implementer native evidence (2026-10-03, nagare-f3, development binary at `66afd6a6`+, cp3):** A reviewed isolated Redis restore (`f3race`, review `27d8b8ed…`, five operations) was saved. An unowned PVC was then created at its planned scratch PVC address. `inventory apply --yes` exited 1 in 2 s. The first operation had already created Service `mp23-independent-redis-restore-f3race`, then the PVC operation stopped with `KnownNoEffect "adapter preflight refused"`, leaving `tx-27d8b8ed…` active on the `local` store. While the foreign PVC existed, `inventory resume` repeated the refusal, and `inventory recover` (action `abandon-partial-database-restore`) refused with `recovery-state: operation has no uncertain effect to resolve`. Planning any other review is blocked while the transaction is active. The only exit was deleting the conflicting object out of band; the same resume then converged in 31 s. [Raw record](mp23-implementer-results-2026-10-03/cp3-data-drills.json).

**Cause (source):** `Nagare.Inventory.Execute.Driver.executePrepared` returns `StoppedFailed … KnownNoEffect` on a preflight refusal without journalling. `Execute.Transaction` then calls `releaseClaim … Nothing`, which keeps `headActiveTransaction`. `Execute.RecoveryPolicy` offers decisions only for uncertain effects and three restore- or prune-specific abandonments. Admission runs adapter preflight only for migration sources (`Execute/Admission.hs`). F30 fixed one instance (status-only churn) narrowly; this is the general class.

**Required repair/verification:** Give an admitted transaction that stopped at a `KnownNoEffect` preflight refusal a reviewed, bounded exit that does not require deleting an object the operator may not own. It must keep completed effects' exact identities in history as unaccepted or retained objects and must never claim convergence. Alternatively, or in addition, check create-target absence and other cheap live preconditions for every operation at admission, so such a review is refused before it becomes active. Regression: an object appears at a later operation's address after admission, and the transaction then reaches an explicit terminal state through the public path, with the store usable and the earlier effect's identity recorded. Independently re-run the native race.

**Implementation update (2026-10-03, `570467f0`; claude-opus-5-5):** New recovery decision `abandon-refused-operation`. It requires the active transaction, no data fence, no recorded intent for the selected operation, and no other operation in an uncertain state. It reruns the same adapter preflight under the lock and ends the transaction only on a current refusal, through the existing aborted-claim release. A passing preflight answers "resume the transaction instead". Completed earlier effects keep their journal identities and are not accepted, matching the existing abandonments. `test/InventoryRefusedPreflightRecoverySpec.hs` covers four variants: abandonment with the object still present and the store reusable, a passing preflight refused and then a converging resume, a completed operation refused, and an earlier ambiguous effect refused. All 1,154 tests, the style gate and the architecture check pass; `docs/runbooks/inventory-operations.md` documents the action. Native re-run on cp3 (development binary, same claim protocol): the foreign PVC (`be75172b…`) made the stopped transaction `tx-4d66348e…` end through the new decision. The store went idle, the foreign PVC's UID was untouched, and a new restore plan succeeded immediately ([record](mp23-implementer-results-2026-10-03/cp3-data-drills.json)). The admission-time absence check was not added. Remaining: independent review and an independent native race run.

## F36

**A failed Redis scratch restore cannot be abandoned and wedges the store** — P1; **Verifying**; owner EP-160.

**Implementer source evidence (2026-10-03, claude-opus-5-5):** A Redis isolated restore creates a scratch Service, PVC, StatefulSet and verify Job. If the StatefulSet's `download` init container fails, its pod never becomes Ready and apply stops ambiguous after the readiness wait. Examples are a pinned version that becomes unreadable after review, or an RDB load failure. On `inventory recover`, `Adapters/Kubernetes.hs` returned `RecoveryUnresolved` for any NotReady StatefulSet (terminal failure was proved only for Jobs), and `Execute/RecoveryPolicy.databaseRestoreOnlyReview` accepted only Job-only reviews. Neither resume nor recover could end the transaction. The trace comes from the 2026-10-03 restore-path research for the cp3 drills; no native reproduction was run, because forcing it destroys a backup's pinned version.

**Implementation update (2026-10-03, `6d7951c9`; claude-opus-5-5):** Kubernetes recovery asks a new runtime probe (`Nagare.Inventory.Adapters.RestoreScratch.restoreScratchPodFailed`) whether a pod controlled by the exact scratch StatefulSet UID has a container that exited non-zero, now or before a restart. Only StatefulSets labelled `nagare.dev/restore-scratch` qualify. A proven failure becomes `RecoveryTerminalFailure`, and `abandon-partial-database-restore` also accepts an exact Redis restore-only review (`redisRestoreOnlyReview`). The scratch objects stay unaccepted for separate reviewed recovery. `test/InventoryRedisRestoreRecoverySpec.hs` covers the pod-list cases (owned failure, success, foreign owner, empty and malformed lists), the abandonment, and the refusal of a review with an extra member. All 1,165 tests and the gates pass. Remaining: a native run on a disposable context (C2) that removes a throwaway backup's pinned version after review, plus independent review.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint on a fresh cp3 context; nagare-phase-b):** Throwaway backup `c2f36` of `scenario-redis`; restore review `3a34ab21…` saved; exactly the pinned archive version `80ab0c9b…` deleted with a throwaway `nagare-mc` Pod. Apply stopped ambiguous after 5 min with the scratch StatefulSet's `download` init container in CrashLoopBackOff (`HeadObject … 404`). `inventory recover … abandon-partial-database-restore` closed the transaction; the scratch Service, PVC and StatefulSet stayed unaccepted and the store went idle with accepted equal to converged ([record](mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json)). Remaining: independent review.

**Acceptance C2 on `14071e58` (2026-10-03, nagare-phase-b):** Reproduced natively on the frozen candidate: the pinned-version deletion again ended in `abandon-partial-database-restore` with the store idle ([record](mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)).

## F37

**Configuration drift written by another field manager has no reviewed repair** — P1; **Verifying**; owners EP-149 / EP-153.

**Implementer native evidence (2026-10-03, nagare-phase-b, candidate `db808a74`, disposable C2 context on cp3):** For the EP-155 `drift-classification` check, application B's Knative Service (`personal/scenario-b`, UID `7dde1aa3…`) was edited with `kubectl patch`, changing `autoscaling.knative.dev/max-scale` from `3` to `5`. `inventory status --json` classified this correctly: exactly one `configuration-drift` finding for `application:scenario-b/scenario-b/service`, distinct from the `retained-orphan` members of the retired `scenario-retire` database. The repair was the same reviewed `app deploy` as the original deploy. It saved review `a248f688…` with two operations (`UpdateResource` on the Service, `VerifyResource` on topic `jobs`). Apply stopped at `op-7cba97a4…` with `KnownNoEffect "Kubernetes object has fields managed by another writer: kubectl-patch"`. No provider write occurred; the UID and the edited value were unchanged.

The transaction then had no supported exit. `inventory recover … abandon-refused-operation` refused with `recovery-state: operation has no uncertain effect to resolve`, and `inventory resume` repeated the same refusal. `tx-a248f688…` stays active (`resume-required`), so every other plan on the store is blocked. The only exit would be removing the foreign manager out of band, which the C2 rules forbid as manufacturing a result. Evidence is in `checks/drift-classification/{status-drift.json,repair-refused.json}` under the C2 evidence directory, to be archived with the C2 results.

**Cause (source):** `Nagare.Inventory.KubernetesConfiguration.confirmInventoryFieldOwnershipFor` refuses an update when any non-status `managedFields` entry belongs to a manager other than `nagare-inventory`, except the PVC and Deployment controller paths in `expectedControllerFields`. Field-manager conflicts are not checked at planning, so a review that cannot apply is saved and admitted. After intent is recorded, the refusal leaves the operation `Failed (KnownNoEffect)`. `Execute.RecoveryPolicy.recoverableState` excludes that state for every decision, and the F35 decision `abandon-refused-operation` (`570467f0`) admits only an operation with no recorded intent (`Execute/Recovery.hs`). F35 closed the preflight form of this class; this is the apply-time form.

**Why it matters:** IR-24's required verification asks that drift fixtures distinguish *repairable* configuration drift, missing resources, foreign ownership and the other categories (IR-24 case 5). Classification works, but the most ordinary drift, an operator's `kubectl edit` or `kubectl patch`, cannot be repaired through a review. Planning a repair also wedges the store.

**Required repair/verification:** Give drift owned by another field manager a reviewed path: either an explicit reviewed field-ownership takeover bound to the observed managers and resourceVersion, or a planning-time refusal that names the foreign manager and the fields before any review is saved. Separately, give an admitted operation that ended `Failed (KnownNoEffect)`, whose effect is proved absent, a bounded terminal exit that keeps completed effects unaccepted and never claims convergence. Regression: a foreign-manager edit on an accepted Service is repaired, or refused at planning, with no active transaction left behind. Independently re-run the C2 drift check on the resulting candidate. Product direction (takeover versus classification plus refusal as the contract) is with the operator (2026-10-03).

**Implementation update (2026-10-03, `d9aed800` and `1df735a6`; claude-opus-5-5, nagare-phase-b):** Operator decision relayed by nagare-f3: add a reviewed takeover. (A) `d9aed800` (EP-153): `abandon-refused-operation` also ends an operation whose latest state is `Failed (KnownNoEffect)`. The journal is the no-effect proof, so no fresh preflight refusal is required. Pending operations keep that requirement, and the no-data-fence and no-other-uncertain-operation guards are unchanged (`Execute/Recovery.hs`; new variant `ExecuteRefusal` in `test/InventoryRefusedPreflightRecoverySpec.hs`). (B) `1df735a6` (EP-149): `app deploy --save-plan --take-over-fields` makes the Kubernetes adapter record the exact foreign managed-field entries (without timestamps), UID and resourceVersion of a drifted object in a version-3 mutation (`FieldTakeover`). The transport accepts a live foreign entry only if the review recorded it, with the same UID and resourceVersion, then runs the usual forced server-side apply. Afterwards it requires that no foreign non-status owner remain, otherwise the operation stops ambiguous (`KubernetesConfiguration.confirmReviewedFieldTakeover`, `confirmTakeoverSettled`). Without the opt-in, planning and the refusal are unchanged; versions 1 and 2 keep their bytes; `ObservationNative` accepts the version-3 envelope. `test/InventoryKubernetesFieldTakeoverSpec.hs` drives the production transport over a modelled kubectl in seven cases: refusal without the opt-in, a successful takeover, a new foreign manager, a changed UID or resourceVersion, leftover foreign fields, an object moving during preparation, and tampered bindings. All 1,173 `nagarectl` tests, `just haskell-style-check`, `scripts/check-haskell-architecture.py`, `scripts/check-cli-architecture.py` and `scripts/test-managed-command-audit.sh` pass. The runbook gains "Repair configuration drift". Limitations: `inventory plan` does not take the opt-in yet; a planning-time refusal naming the foreign fields was not added. Remaining: a candidate build, then the native C2 drift check (close `tx-a248…` through (A) on the old store, then the takeover repair on a fresh store), and independent review.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint; nagare-phase-b):** On a fresh context, a `kubectl patch` of application B's max-scale showed as exactly one `configuration-drift` finding, distinct from nine `retained-orphan` members. The ordinary replan (`fe6f6637…`) stopped `KnownNoEffect … kubectl-patch`, and `abandon-refused-operation` closed it (fix A). The `--take-over-fields` replan (`ee8a4049…`, summary "takes over fields from kubectl-patch") converged: same Service UID, max-scale back to 3, managed fields now only `nagare-inventory` plus the controller's status entry, and all 278 findings converged ([record](mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json)). Remaining: independent review and the acceptance C2 on the next candidate.

**Acceptance C2 on `14071e58` (2026-10-03, nagare-phase-b):** Reproduced natively on the frozen candidate: the strict replan refused `kubectl-patch`, `abandon-refused-operation` closed it, and the `--take-over-fields` replan restored max-scale 3 under the same UID with `nagare-inventory` as the sole manager ([record](mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)).

## F38

**A failed GCS head advance after a published journal event stops ambiguous and discards the store error** — P2; **Open**; owners EP-153 / EP-156.

**Implementer native evidence (2026-10-03, claude-opus-5-5, candidate `db808a74`, checkpoint C3 context `mp23-c3` in `tan-ng-labs`):** The cluster-stage apply (review `58266a9b…`, 210 operations) stopped after 241 s with `ambiguous tx-58266a9b… at op-60773165…`, a `CreateResource` for ClusterRoleBinding `cert-manager-controller-approve:cert-manager-io`. The object existed, created by `nagare-inventory` at 20:38:07Z. The GCS store held `journal/00000000000000000143.json` recording that operation as `Completed` at 20:38:08Z with an intact hash chain. But `head.json` stayed at `sequence` 143, which is the next sequence to write, and its executor claim was released. So the event was published, but the head compare-and-swap that commits it failed. `inventory status` correctly reported the operation as `intent-recorded`, because the event at 143 is not yet committed. Neither stdout nor stderr carried the store error.

**Cause (source):** `Execute/Journal.appendEvent` writes the journal object (`appendAtObservedHead`), then advances the head through `replaceObservedHead` with the observed provider generation. Any `Left` there, whether `PutPreconditionFailed`, `PutNoEffect` or `PutUnknown`, reaches the driver as `Left _ -> StoppedAmbiguous` (`Execute/Driver.hs`), and the reason is dropped. No claim-renewal writer exists, so a concurrent head write by this client is not the explanation. The provider outcome is unknown.

**Recovery observed:** This was safe in this case. `inventory resume` re-ran Kubernetes recovery, whose completion proof digests only the operation, resource, physical UID and desired digest. That reproduced the orphan's proof exactly, so `appendEvent`'s conflict path accepted the existing event (`sameEventMeaning`) and advanced the head. The orphan kept its original timestamp, and the transaction continued from sequence 144. An adapter whose recovery proof differs from its execution receipt would instead hit `StoreObjectConflict` at the orphan's sequence on every later append, and wedge the store.

**Required repair/verification:**
- Carry the store error into the stopped result and the command's stderr, so an operator can tell a precondition failure from a transport failure.
- After a failed head advance, reread the head once. If it already names the event, return success. If it is unchanged and the claim is still held, retry the conditional head write a bounded number of times before stopping.
- Make orphan adoption independent of proof equality. For example, compare against the orphan's journal state and adopt it when the recovering adapter independently proves the same completion. Or give an explicit reviewed exit for an uncommitted orphan event.
- Regression: a fake object store fails the head write once after the journal write. Two outcomes must be covered: the transaction continues, or it stops with the reported reason, and resume converges with no wedge, including for an adapter whose recovery proof differs from its execution receipt.

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

## F41

**A local node restart destroys every local backup, and local escrow verification needs the source cluster** — P1; **Verifying**; owners EP-155 / EP-159.

**Implementer native evidence (2026-10-03, candidate `44ff0fd7`, C2 checkpoint; nagare-phase-b):** For `source-unavailable-recovery` (operator decision (a): escrow, stop the k3d server, copy the MinIO data, disposable MinIO, `db verify-escrowed-backup`, disposable PostgreSQL restore), the escrow and an online `verify-escrowed-backup` passed (job `37ae52ab…`, object version `2d7ffc36…`). After `docker stop k3d-nagare-local-server-0`, the MinIO pod's `emptyDir` directory no longer existed in the node's kubelet volume and every remaining `emptyDir` was empty. After `docker start`, MinIO came back as a new pod with no buckets: every local backup, receipt and snapshot was gone and `nagare-backups` was absent. The store was never mutated (generation 1025, idle). A read-only platform bootstrap plan does not see the missing bucket (its Job is still complete), so no reviewed repair exists. Separately, local `verify-escrowed-backup` reads MinIO credentials from a cluster Secret and opens a kubectl port-forward (`ScheduledStore.withLocalObjectStore`), so it cannot read an offline copy, contrary to the user documentation. [Attempt record](mp23-implementer-results-2026-10-03/c2-checkpoint-44ff0fd7.json).

**Cause (source):** `cluster/local/minio/minio.yaml` mounted the bucket on an `emptyDir` by an EP-100 decision (local mode as a disposable GCS stand-in). That choice predates local mode carrying release evidence for backups, restores and recovery.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b; decision relayed by nagare-f3):** (a) Local MinIO keeps the bucket on a `minio-data` PersistentVolumeClaim (`local-path`, 2Gi) with a `Recreate` Deployment strategy; the reviewed `local-object-store` scope orders the Deployment after the claim and pins the new manifest digest. The local-path volume lives in the k3d node's `/var/lib/rancher/k3s` volume, so it survives a pod restart and a node `docker stop`/`start`, and `k3d cluster delete` (`just local-down`, the C2 teardown) removes it with the node. This supersedes the EP-100 `emptyDir` decision (EP-155 Decision Log). (b) `db verify-escrowed-backup` gains `--offline-object-store URL` and `--offline-credentials FILE` for local mode: only a loopback `http://127.0.0.1:PORT` or `http://localhost:PORT` origin is accepted; the credentials come from a file that must not be group- or other-readable, with exactly `AWS_ACCESS_KEY_ID=` and `AWS_SECRET_ACCESS_KEY=` lines, and reach curl only through its stdin configuration. Exact-version, signature and checksum checks are unchanged. The user documentation now states that local mode reads through the cluster by default. Regressions: the local object-store scope test asserts the claim, the claim mount without `emptyDir`, and the ordering; a parser test covers loopback-only origins and strict credential files. Remaining: the acceptance C2 on the next candidate proves source-unavailable recovery natively with a live copy of the bucket served offline, then independent review.

**Implementer native evidence on the frozen candidate (2026-10-03, `14071e58`, acceptance C2; nagare-phase-b):** The fresh platform review created `minio-data` (Bound on local-path, `Recreate` strategy). For source-unavailable recovery, the escrow and an online `verify-escrowed-backup` of scheduled job `b8fa6642…` passed (object version `7afd20b7…`, recovery point 23:45:01Z). A live tar of the MinIO volume was copied out, then `docker stop` made the API unreachable. A disposable MinIO on `127.0.0.1:19000` served the copy, and `verify-escrowed-backup --offline-object-store … --offline-credentials …` passed with the identical version, receipt and checksum. That exact archive restored rows 1-3 into a disposable PostgreSQL with zero errors. After `docker start` the bucket was intact (the online verification read the same version, freshness healthy) and the store was unchanged and idle ([record](mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json)). Remaining: independent review.

## F42

**The managed-resource evidence assembler can never accept real runner output** — P1; **Verifying**; owner EP-157.

**Implementer native evidence (2026-10-03, candidate `14071e58`, acceptance C2 runner; nagare-phase-b):** `scripts/assemble-managed-resource-evidence.sh` refused the runner rehearsal `c2-14071e58-runner` (one `CreateResource` of `runner-probe`, a verified zero-operation replan) with "initial review has no bound operations". The check required `review.candidateDigest` to equal the SHA-256 of `candidate.json`, and the no-op check required the no-op review's `candidateDigest` to equal `run.json`'s `verificationCandidateDigest`. Those are different digests: a review's `candidateDigest` is the planner's proposal digest over binding, base, desired revisions and changes (`Plan/Changes.hs`), while `candidate.json` and `candidate.sha256` are the compile manifest (`Command.hs`). The checks could pass only against hand-made fixtures, and the operations message hid the mismatch.

**Implementation update (2026-10-03; claude-opus-5-5, nagare-phase-b; decision relayed by nagare-f3):** The initial review is bound to the compiled candidate through its desired scope revisions: every desired scope, content digest and generation in `review.desiredRevisions` must equal `candidate.json`'s desired scopes and generations. The no-op review must have no operations and its desired scopes and content digests must equal the final observation's accepted revisions (an unchanged replacement still advances a generation). Each condition has its own refusal message. `scripts/test-managed-resource-evidence.sh` now uses real nagarectl shapes, adds refusals for each new condition, and replays real runner output from `fixtures/managed-resource-evidence/c2-14071e58-runner`: both reviews bind, and the run's incomplete final observation still refuses. The assembler ships in the payload, so the fix needs the next candidate. Remaining for a complete local assembly, all outside this finding: the runner must observe every provider (the C2 runner ran without the en endpoint, so `AccessExecutor` was unobserved); the coverage audit at `14071e58` is itself incomplete (`Command.Cleanup` and `InfraCommand.InfraDestroy` pending, `infra-destroy` recipe pending, one catalogue row incomplete); and the release manifest input is the release build manifest, not the payload's `release.json`.

