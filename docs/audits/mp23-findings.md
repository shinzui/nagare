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
| [F15](mp23-archive/mp23-findings-closed.md#f15) | P1 | Patched certificate controller lacks refreshed private-image credentials | Closed | EP-156 / EP-154 |
| [F16](mp23-archive/mp23-findings-closed.md#f16) | P1 | Unready application creation cannot yield to a corrected reviewed configuration | Closed | EP-153 / EP-156 |
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
| [F30](mp23-archive/mp23-findings-closed.md#f30) | P1 | Controller status churn strands admitted conditional Service correction | Closed | EP-153 / EP-156 |
| [F31](mp23-archive/mp23-findings-closed.md#f31) | P1 | Registry refresh cadence permits credentials to expire before its next run | Closed | EP-154 / EP-156 |
| [F32](mp23-archive/mp23-findings-closed.md#f32) | P1 | Image-cache cleanup selects an image used by active pod sandboxes | Closed | EP-153 / EP-156 |
| [F33](#f33) | P1 | Cloud collection does not recheck its reviewed physical incarnation before deletion | Verifying | EP-153 / EP-156 |
| [F34](mp23-archive/mp23-findings-closed.md#f34) | P1 | Kourier gateway rejects HTTPS listener updates on cp3, so new routes never become Ready | Closed | EP-155 / EP-153 |
| [F35](mp23-archive/mp23-findings-closed.md#f35) | P1 | Preflight refusal after admission strands the transaction with no supported exit | Closed | EP-153 / EP-160 |
| [F36](mp23-archive/mp23-findings-closed.md#f36) | P1 | A failed Redis scratch restore cannot be abandoned and wedges the store | Closed | EP-160 |
| [F37](mp23-archive/mp23-findings-closed.md#f37) | P1 | Configuration drift written by another field manager has no reviewed repair | Closed | EP-149 / EP-153 |
| [F38](mp23-archive/mp23-findings-closed.md#f38) | P2 | A failed GCS head advance after a published journal event stops ambiguous and discards the store error | Closed | EP-153 / EP-156 |
| [F39](mp23-archive/mp23-findings-closed.md#f39) | P1 | Staged cloud teardown cannot prepare any Pulumi operation on a real stack | Closed | EP-153 / EP-156 |
| [F40](#f40) | P1 | A real context cannot be retired: contribution targets, scope cycles and host or artifact members block every teardown | Partial | EP-153 / EP-156 |
| [F41](mp23-archive/mp23-findings-closed.md#f41) | P1 | A local node restart destroys every local backup, and local escrow verification needs the source cluster | Closed | EP-155 / EP-159 |
| [F42](mp23-archive/mp23-findings-closed.md#f42) | P1 | The managed-resource evidence assembler can never accept real runner output | Closed | EP-157 |
| [F43](mp23-archive/mp23-findings-closed.md#f43) | P1 | A fresh inventory context cannot enable the platform Google CDN backend, so B3 cannot run | Closed | EP-158 / EP-156 |
| [F44](mp23-archive/mp23-findings-closed.md#f44) | P1 | Inventory status on a cloud context never observes cloud-foundation members, so cloud runner evidence cannot assemble | Closed | EP-153 / EP-157 |
| [F45](mp23-archive/mp23-findings-closed.md#f45) | P1 | Reviewed Google CDN deploy on an inventory context cannot observe or apply its DNS record | Closed | EP-158 / EP-156 |
| [F46](mp23-archive/mp23-findings-closed.md#f46) | P1 | A retired site's edge DNS record can never be collected, because retained release history orders after it | Closed | EP-158 / EP-156 |
| [F47](mp23-archive/mp23-findings-closed.md#f47) | P2 | CDN platform outputs are read with the caller's Pulumi environment, not the active context's | Closed | EP-158 |
| [F48](#f48) | P2 | Inventory evidence names the manifest's payload without checking the payload the context runs | Open | MP-26 (EP-168 port) |
| [F49](mp23-archive/mp23-findings-closed.md#f49) | P1 | An out-of-band replacement of an accepted database is reported converged, and its new incarnation's receipts plan for ingestion | Closed | EP-159 / EP-153 |
| [F50](mp23-archive/mp23-findings-closed.md#f50) | P2 | One transient failed gcloud read makes the state-bucket ownership guard stop a run | Closed | EP-156 |
| [F51](mp23-archive/mp23-findings-closed.md#f51) | P2 | Retirement retains an out-of-band replacement's identity instead of the accepted incarnation | Closed | EP-153 / EP-159 |
| [F52](mp23-archive/mp23-findings-closed.md#f52) | P2 | Incarnation records are keyed by resource ID, so a reviewed address-changing migration reads as `replaced-incarnation` until it converges | Closed | EP-153 |
| [F53](mp23-archive/mp23-findings-closed.md#f53) | P1 | `nix flake check` fails at the candidate: sandbox-only test failures and stale check assertions | Closed | EP-154 |
| [F54](mp23-archive/mp23-findings-closed.md#f54) | P1 | A landed application Service update whose new revision never becomes Ready has no reviewed exit, so the store stays wedged | Closed | EP-153 / EP-156 |
| [F55](mp23-archive/mp23-findings-closed.md#f55) | P1 | A landed unready application update still has no exit when its review also updates its release history or verifies a member | Closed | EP-153 / EP-173 |
| [F56](mp23-archive/mp23-findings-closed.md#f56) | P1 | A landed application Service update whose Service is then replaced outside review has no exit | Closed | EP-153 / EP-173 |
| [F57](mp23-archive/mp23-findings-closed.md#f57) | P1 | A verification whose target is replaced after it ends ambiguous has no exit | Closed | EP-153 / EP-173 |
| [F58](mp23-archive/mp23-findings-closed.md#f58) | P2 | An application whose first deploy stopped unready cannot be retired, because a never-created member has nothing to retain | Closed | EP-153 / EP-173 |
| [F59](mp23-archive/mp23-findings-closed.md#f59) | P1 | A standalone database whose StatefulSet is created but never becomes Ready has no exit | Closed | EP-153 / EP-173 |
| [F60](mp23-archive/mp23-findings-closed.md#f60) | P2 | One out-of-band replacement between a create and convergence is recorded as the accepted incarnation (F49's fail-open recording, reachable with one fault) | Closed | EP-173 |
| [F61](mp23-archive/mp23-findings-closed.md#f61) | P1 | A reviewed PostgreSQL rename whose copy Job fails partway has no exit | Closed | EP-173 / EP-153 |
| [F62](mp23-archive/mp23-findings-closed.md#f62) | P2 | A reviewed rename copies from, and retains, a source replaced outside review | Closed | EP-153 / EP-173 |
| [F63](mp23-archive/mp23-findings-closed.md#f63) | P1 | A Deployment or database StatefulSet update that lands but never becomes Ready has no exit | Closed | EP-153 / EP-173 |
| [F64](mp23-archive/mp23-findings-closed.md#f64) | P1 | An intended update whose target is deleted outside review, and not recreated, has no exit | Closed | EP-153 / EP-173 |
| [F65](mp23-archive/mp23-findings-closed.md#f65) | P1 | The create-path stop refuses a review that recreates a deleted Service alongside its release-history update | Closed | EP-153 / EP-173 |
| [F66](mp23-archive/mp23-findings-closed.md#f66) | P1 | A create that finds an object not stamped as its own at its address settles unknown, so only an attested close can end it | Closed | EP-153 / EP-177 |
| [F69](mp23-archive/mp23-findings-closed.md#f69) | P1 | A Knative Service or DomainMapping reads ready from its previous generation's Ready=True before the controller has seen the new spec | Closed | EP-153 / EP-180 |
| [F70](mp23-archive/mp23-findings-closed.md#f70) | P1 | A worker Deployment whose update never becomes available reads as ready, so a broken rollout is recorded as complete | Closed | EP-153 / EP-180 |
| [F67](mp23-archive/mp23-findings-closed.md#f67) | P1 | An update refused after a status write, whose refusal's journal event is lost, settles unknown | Closed | EP-153 / EP-180 |
| [F71](mp23-archive/mp23-findings-closed.md#f71) | P2 | A Kubernetes write the API server definitively refused (409, 422, 404 and the other 4xx) is reported ambiguous | Closed | EP-153 / EP-180 |
| [F72](mp23-archive/mp23-findings-closed.md#f72) | P1 | The Kubernetes transport refuses a corrective update of an unready StatefulSet or Deployment as an unsupported precondition | Closed | EP-153 / EP-180 |
| [F68](mp23-archive/mp23-findings-closed.md#f68) | P1 | An update whose target is deleted and replaced by an object not stamped as its own settles unknown, so only an attested close can end it | Closed | EP-153 / EP-177 |
| [F73](mp23-archive/mp23-findings-closed.md#f73) | P1 | A Knative Service update that another write left unready is awaited as ours and settles as Landed | Closed | EP-180 |
| [F74](mp23-archive/mp23-findings-closed.md#f74) | P1 | A Kubernetes object being deleted is read as present | Closed | EP-180 |
| [F75](mp23-archive/mp23-findings-closed.md#f75) | P1 | A non-canonical resource quantity drifts forever | Closed | EP-180 |
| [F76](mp23-archive/mp23-findings-closed.md#f76) | P1 | The accepted-incarnation tests stopped running, and twelve mutation records passed vacuously | Closed | EP-180 / EP-177 |
| [F79](mp23-archive/mp23-findings-closed.md#f79) | P1 | Close drops a never-started member whose absence it cannot read, leaving it accepted with no exit | Closed | MP-23 (step 3d) |
| [F80](mp23-archive/mp23-findings-closed.md#f80) | P1 | The reviewed rebind cannot be issued for application or standalone-database members, so an unrecorded database never has its backups accepted again | Closed | nagare-fix (MP-23 step 5) |
| [F81](mp23-archive/mp23-findings-closed.md#f81) | P1 | A reviewed rename stopped by a source replaced outside review, or by a refused copy, had no exit, and close could accept it half done | Closed | nagare-fix (MP-23 step 5) |
| [F82](mp23-archive/mp23-findings-closed.md#f82) | P1 | The no-data-loss drill (checklist section 2) has no documented procedure: the guide places full restore after total cluster loss outside this release | Closed | nagare-fix (MP-23 step 5); rebuild-in-place: next MasterPlan |
| [F83](mp23-archive/mp23-findings-closed.md#f83) | P1 | A reviewed retirement whose review proves a Kubernetes member absent always refuses through the CLI | Closed | nagare-fix (follow-up candidate) |
| [F84](#f84) | P2 | An accepted access grant cannot be retired, so a full context holding one has no reviewed teardown | Deferred (next release) | nagare-fix |
| [F85](#f85) | P2 | The installed package needs host npm, so the clone-free rehearsal fails on x86_64-linux | Deferred (next release) | nagare-fix |
| [F86](#f86) | P1 | A review admits an in-place PostgreSQL major-version change, with no reviewed exit once applied | Closed | nagare-fix |
| [F87](#f87) | P2 | An application cannot drop one of its databases through review | Closed | nagare-fix |
| [F88](#f88) | P2 | A controller's status write refuses an in-sync reviewed update, and the refusal has no reason | Verifying | nagare-fix |
| [F89](#f89) | P3 | One failed GCS store read aborts a journal append and leaves the operation ambiguous | Deferred (next release) | nagare-fix |
| [F90](#f90) | P2 | The host transport ran the `nagarectl` first on PATH | Closed | nagare-fix |
| [F91](#f91) | P3 | After a closed failed host upgrade, `inventory status` refuses until the previous lock is restored | Deferred (next release) | nagare-fix |
| [F92](#f92) | P2 | `doctor` verifies every retained backup serially | Closed | nagare-fix |
| [F93](#f93) | P1 | A host upgrade with a bound age key strands its review's second activation operation | Closed | nagare-fix |
| [F94](#f94) | P3 | `inventory resume` stops "ambiguous" without the adapter's recovery reason | Deferred (next release) | nagare-fix |
| [F95](#f95) | P1 | A host upgrade that restarts `tailscaled` or the network ends its own activation session, never commits, and hangs the apply | Closed | nagare-fix |
| [F77](#f77) | P1 | A database volume claim deleted outside review while its pod runs stays Terminating, and every review of the database refuses until it goes | Deferred | deferral ledger (operator, 2026-10-07); next MasterPlan |
| [F78](#f78) | P2 | While a StatefulSet's own template never becomes Ready, every transaction stops at it, and independent members planned after it are never created until the template is corrected | Deferred | operator, 2026-10-07; next MasterPlan |

Closed findings keep their full text, location, implementation updates and verification in [the closed-findings archive](mp23-archive/mp23-findings-closed.md). F01 and F11 retain their [earlier independent closure](mp23-archive/mp23-verification.md). F02, F03, F04, F05, F06, F07, F08 and F20 now have [2026-10-02 independent closure](mp23-independent-verification-2026-10-02.md). F34, F35, F36, F37, F38, F41 and F42 have 2026-10-04 independent closure on candidate `7596632c`, and F49 and F50 on candidate `847543896d07` ([records](mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md)). F51, F53, F55–F61, F63–F76 and F79 have 2026-10-07 independent closure on candidate `96c1da11`, all on source except F53 and F76, which close on the gate itself ([record](mp23-independent-results-2026-10-07/README.md)). Other entries retain their status shown above.

**Exit change for open findings (2026-10-05, EP-175 M3; claude-opus-5-5).** [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) replaced every stop and abandon exit with `nagarectl inventory close`. The affected findings are F16, F54–F59 and F63–F65, plus the closed F35–F37. Their instance-level guards (the Application-only and StatefulSet-only stop rules, the companion rules F55 and F65, and the landed/replaced stop proofs) are deleted. Their mutation records are retired in [the mutation README](../../cli/nagarectl/test/mutations/README.md), which names the rule-level record that now pins each class. A verifier re-checking these findings should run the close path: each scenario's stop now ends with `inventory close`, keeping or reverting the changed scope by proof. Statuses are unchanged here; they are the verifier's to set.

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

**Independent verification (2026-10-07, nagare-verify; candidate `96c1da11`, code identical to `8824f469`; observed).** Every native pass so far is on `84754389`. The candidate changes 310 files under `cli/`, so the carry-over ruling does not apply. Stays Verifying until C3 on this candidate (staged teardown). The candidate's full gate is green ([record](mp23-independent-results-2026-10-07/gate-96c1da11.json)), and the mutation sweep at `8824f469` killed all 117 records ([results](mp23-independent-results-2026-10-07/mutation-sweep-8824f469.tsv)). Tests named here pass in that gate run ([lines](mp23-independent-results-2026-10-07/test-evidence-96c1da11.txt)). Summary: [2026-10-07 verification record](mp23-independent-results-2026-10-07/README.md).

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Stays Verifying, owed by the next release. The cloud-collection recheck runs only in a staged cloud teardown's collection stage. On both acceptance contexts that stage was unreachable: retiring every scope is blocked by F84, the access grant. Both contexts were disposed with exact-name provider deletes from their own stack exports (the 2026-10-03 precedent). Kubernetes collection with `--controller-descendants` passed natively on `mp23-c3j`.

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

**Independent verification (2026-10-08, nagare-verify; final candidate `3ae20f8c`; observed).** Stays Partial. The remainder (full-context VM collection) belongs to MasterPlan 25. Retiring every scope of a full context is additionally blocked by F84 (access grant retirement), which is fixed on `next-release` (`de7100f0`).

## F48

**Inventory evidence names the manifest's payload without checking the payload the context runs** — P2; **Open**; owner MP-26 (the EP-168 port of the runner and assembler).

**Implementer evidence (2026-10-04, claude-opus-5-5, C3 checkpoint `mp23-c3g`):** `scripts/assemble-managed-resource-evidence.sh` binds the runner's operator revision (`operator-version.json`) to the release manifest. It then copies the manifest's payload digest into `inventory-evidence.json` as the run's payload. Neither the runner (`scripts/rehearse-managed-resources.sh`) nor the assembler records or checks the payload the context actually runs. The rehearsal on `mp23-c3g` shows the gap: a candidate `471cb409` CLI runs against a context bootstrapped from, and still pinned to, the `7d486457` payload. It produces evidence the assembler would label with the `471cb409` payload.

**Required repair/verification:** the runner records `nagarectl platform root --json` (payload id, source revision, digest), and the assembler requires its revision to equal the manifest's. Prove it with real runner output for both cases: a matching run assembles and a mixed run is refused. ADR 24 freezes the shell tools and assigns feature work to their Haskell port, so this lands with the EP-168 port.

**Procedural guard until then:** each acceptance run bootstraps a fresh context from the candidate's own payload (runbook §6 step 0 and §7). The operator records `platform root --json` in the run root and confirms its `revision` equals the candidate before the runner's plan.

## F84

**An accepted access grant cannot be retired, so a full context holding one has no reviewed teardown** — P2; **Deferred (next release, operator 2026-10-08)**; owner nagare-fix (`next-release` `de7100f0`).

**Found by session mp23-c3i during the `mp23-c3i` staged teardown on `3ae20f8c` (2026-10-08; observed).** Retiring the application scopes refused with `dangling-reference` (the access grant is a dependency producer). Retiring all scopes jointly refused with `access resource is not declared`. The access adapter's observe (`Access.hs`) builds bindings only from the candidate's desired declarations, and its `selected` admits only create, update and verify. Disposable contexts were removed with exact-name provider deletes. Evidence: [c3i teardown](mp23-independent-results-2026-10-07/c3i-teardown/).

**Fix on `next-release`:** the adapters also bind the accepted tuples. A revoked grant is retained when its scope retires; a live one refuses with `access-grant-live`, so the operator revokes first. The revoke-first policy is a choice flagged for the operator.

## F85

**The installed `nagare` package needs host npm, so the clone-free rehearsal fails on x86_64-linux** — P2; **Deferred (next release, operator 2026-10-08)**; owner nagare-fix (`next-release` `6011d1ba`).

**Found by session mp23-c3i during C4 on `3ae20f8c` (2026-10-08; observed).** `operatorTools` (`nix/haskell-packages.nix`) ships Pulumi but not Node.js. `Runtime/Pulumi.hs` runs `npm ci`, so `local-up` fails with "Node.js and npm are required" on a host without npm. The darwin rehearsal passed because only part of the rehearsal isolates PATH. Evidence: [C4](mp23-independent-results-2026-10-07/c4-3ae20f8c/).

**Fix on `next-release`:** `context env` no longer runs `npm ci`, local mode installs nothing, `operatorTools` ship nodejs, and the clone-free rehearsal isolates every operator step's PATH.

## F86

**A review admits an in-place PostgreSQL major-version change; once applied, an application-owned database is down with no reviewed exit** — P1 (outage, no data loss); **Closed** (fixed in `4d6abd28`; verified natively on cp3 and on `mp23-c3l`); owner nagare-fix.

**Found by nagare-verify in the section 4 local rehearsal on `3ae20f8c` (2026-10-08; observed).** It ran on cp3, in the C2 context. Application `upg-app` owns `upg-pg` at `"17"`, holding 7 rows.
- Changing that database's version to `"18"` in the application config plans as a plain `UpdateResource` of `application:upg-app/upg-pg/statefulset` and its backup. There is no refusal and no warning.
- Applied, the pod restarts on `postgres:18`. It fails with `FATAL: database files are incompatible with server` ("initialized by PostgreSQL version 17"), and the apply stops `ambiguous`.
- The data files are untouched: PostgreSQL refuses to start rather than convert them.
- The runbook's F78 exit was then followed:
  - `inventory close` kept the scope;
  - the corrected review (`"17"`) completed, but the pod stayed on the stuck revision, and `close` kept the scope again;
  - `db restart upg-pg` refused with `generated native members overlap a supplied or contributed resource`, after reporting `rollout stuck on pod upg-pg-0 … proposing replace-stuck-pod`.
  So the reviewed exit exists only for standalone databases. The stuck state is kept on cp3 as the reproduction. No pod was deleted by hand.

**Expected:**
1. Planning refuses a major-version change of an existing PostgreSQL scope and points to the side-by-side procedure. Section 4's route is dump and restore into a new database.
2. An application-owned database stuck at a broken template has the same reviewed replace-stuck-pod exit as a standalone one.

**Fix (`4d6abd28`, nagare-fix): three defects, not two.**
1. **No planning guard.** `Nagare.Inventory.DatabaseEngine` compares the accepted and desired StatefulSet natives. It refuses an in-place engine change, and a PostgreSQL image change whose major differs or cannot be read, pointing to [Upgrade PostgreSQL to a new major version](../user/managed-databases.md#upgrade-postgresql-to-a-new-major-version). A minor change within one major still plans.
2. **`db restart` supplied every accepted native.** That overlapped the generated namespace, the backend map and the Shomei settings. It now supplies only the restarted scope's own non-contribution members.
3. **No reviewed replace-stuck-pod could ever be applied** (new; standalone or application, and the released `3ae20f8c` binary fails identically). `kubernetesSpecsFromReview` decoded every Kubernetes operation's native as a mutation. A `PodReplacement` has no `action`, so the apply failed with `Error in $: key "action" not found`. One accepted replacement review would also have broken every accepted-native load, in status and planning. EP-181's tests used test registries and never reached this loader. The loader now skips `ReplaceStuckPod`, and execution loads the unchanged member's accepted native.

Mutation records: `F86-postgres-major-unchecked`, `F86-restart-supplies-every-native`, `F86-review-loader-decodes-replacement`. `EP181-restart-ignores-stuck-pod` was regenerated and reproved with its own pattern.

**Native proof on cp3 (nagare-fix, re-checked read-only by nagare-verify, 2026-10-08).**
- Planning `config-inplace` refuses: "PostgreSQL upg-pg would change from postgres:17 to postgres:18 in place".
- The unchanged config still plans.
- Review `366999eb` (one `ReplaceStuckPod` and 19 `VerifyResource`) converged. `upg-pg-0` came back as a new pod (uid `31354dbd`) on postgres:17: Ready, 0 restarts, PostgreSQL 17.11, `hits` 7:7, store idle.

**Verification (nagare-verify, 2026-10-09, `mp23-c3l`, candidate `3b59bcb7`):** in the cloud section 4 drill, planning the in-place change of `upg-pg` from 17 to 18 refused with "PostgreSQL upg-pg would change from postgres:17 to postgres:18 in place …" and pointed to the side-by-side procedure ([section 4](mp23-independent-results-2026-10-07/section4-3b59bcb7/), `probe-inplace.txt`). The reviewed replace-stuck-pod exit was proven on cp3 (above).

## F87

**An application cannot drop one of its databases through review, so the old instance of a side-by-side upgrade can never be retired** — P2; **Closed** (fixed in `d459ba78`; verified on `mp23-c3l`); owner nagare-fix.

**Found by nagare-verify in the section 4 local rehearsal on `3ae20f8c` (2026-10-08; observed).** Application `upg2-app` declares `upg2-pg` (`"17"`) and `upg2-pg18` (`"18"`), and its service is bound to `upg2-pg18`, which is proven by a reviewed backup and isolated restore. A deploy whose config declares only `upg2-pg18` fails at planning:
- First `dangling-reference`, because the pre-upgrade manual backup and restore scopes consume the old database. That is correct, and the documented exit worked: `inventory retire` of both consumer scopes.
- Then `retirement-required` ("accepted resource is absent from desired inventory without a lifecycle decision") for all nine `application:upg2-app/upg2-pg/*` members.

`app deploy` has no option to record that decision. `db retire upg2-pg` refuses ("standalone scope is absent from accepted inventory history"). An application may bind only databases it declares (`Nagare/Dsl/Application.hs`, "declared databases"), so the procedure cannot use a standalone database either. The only reviewed route left retires the whole application.

**Fix (`d459ba78`, nagare-fix):** `app deploy … --save-plan DIR --retire-database NAME`, repeatable. It plans through the explicit-retirement path: every member of the application's accepted members whose logical key is NAME is retained, bound to its physical UID, and nothing is deleted. It refuses without `--save-plan`, for a name the config still declares, for a name with no accepted members, and for a repeated name. A member already confirmed absent cannot carry the approval (`invalid-retirement`), as on the explicit-retirement path. A read-only plan against the held `upg2-app` state retained exactly the nine `upg2-pg` members (review `e3f53ebd`).

**Expected:** a reviewed lifecycle decision for an application's removed database. One option is `app deploy … --retire-database NAME`, which retains every member, as `inventory retire` does, deletes nothing, and frees the binding.

**Verification (nagare-verify, 2026-10-09, `mp23-c3l`, candidate `3b59bcb7`):** in the cloud section 4 drill, after the consumer scopes were retired, `app deploy --retire-database upg-pg` planned and converged. It retained the old instance (StatefulSet and volume kept) and left the application on `upg-pg18` with every row (12:12) ([section 4](mp23-independent-results-2026-10-07/section4-3b59bcb7/), `review-v6-new-only.txt`).

## F88

**A reviewed update of a CronJob is refused when its controller writes status between planning and apply, and the refusal carries no reason** — P2; **Verifying** (fixed in `478e51de`, in final candidate `3b59bcb7`; interpreter tests pin it, and no native run has yet hit a status write inside the window); owner nagare-fix.

**Found by nagare-verify in C3 on `mp23-c3k`, candidate `3b78d905` (2026-10-08; observed).** In phase 3's application change, `deploy-a-c3b` was admitted at 22:15:31. It stopped at `UpdateResource application:scenario-a/scenario-pg/backup`, the `*/15` backup CronJob, with `KnownNoEffect "adapter preflight refused"`. `inventory resume` refused the same way. These were ruled out:
- the object's UID is unchanged;
- the only field managers are `nagare-inventory` (metadata and spec) and `k3s` (the status subresource);
- `verifyBackupSources` does not apply to updates.
The scheduled backup Job ran from 22:15:00 to 22:15:33, and k3s wrote the CronJob's status when it completed. The guard therefore falls back to the exact before-state (`requireWriteTarget` → `requireSameBefore`), and a status write changes that before-state. A review of a CronJob then applies only if no scheduled run falls between planning and apply. The same step converged on `3ae20f8c` (`mp23-c3j`) only because no run fell in its window. This is the F30 class (status-only churn strands an admitted correction), here for CronJobs.

A second defect: `Execute/Driver.hs:405` discards the adapter's reason on a first preflight refusal, so the operator sees no reason. F57 journals the reason only for a retried operation.

The transaction was closed with no effect (`inventory close`, every refused operation "never started"). The deploy was then planned and applied again, and the chain continued; evidence is in `c3-acceptance-3b78d905/`.

**Expected:**
- Status-subresource churn does not invalidate a reviewed update, and the guard rests on UID, owner and spec stamp, as `KubernetesProof.hs` intends.
- The preflight reason is kept and printed.
- An interpreter test covers a status write between planning and apply.

**Fix (`478e51de`, nagare-fix):** a controller's status write no longer invalidates an in-sync reviewed update, and a first preflight refusal now carries the adapter's reason. Interpreter tests cover both. On the final candidate, C3 on `mp23-c3l` applied the same application change on its first attempt ([C3](mp23-independent-results-2026-10-07/c3-acceptance-3b59bcb7/)). That run does not show whether a scheduled backup fell in the window, so the native run confirms only that nothing regressed. On `83124396` (`mp23-c3m`, 2026-10-09) the change again converged on its first apply, between 15:07:46 and 15:10:44. That window holds none of the `*/15` CronJob's scheduled runs, so F88 stays Verifying until a native run hits a status write inside the window ([C3](mp23-independent-results-2026-10-07/c3-acceptance-83124396/)).

## F89

**One failed read of the GCS inventory store aborts a journal append and leaves the operation ambiguous** — P3 (no data loss); **Deferred (next release, operator 2026-10-08)**; owner nagare-fix.

**Found by nagare-verify on `mp23-c3k`, candidate `3b78d905` (2026-10-08; observed twice).** Both stopped with `StoreIoError "inventory object metadata could not be read"`:
- bootstrap stage 3, at 20:27Z, during an expired gcloud reauthentication;
- `cleanup --images`, at 23:1xZ, with valid credentials, so a transient failure.
`inventory resume` converged both.

A third observation, on `mp23-c3l` and final candidate `3b59bcb7` (2026-10-09, section 3 drill A): `inventory close` failed once with `StoreIoError "inventory object generation could not be downloaded completely"`, with valid credentials. It wrote nothing (the head's sequence and generation were unchanged, and no claim was held). The same close, rerun, is the exit.

**Cause (nagare-fix, from the source).** In `Execute/Journal.hs` `appendEventAt`, only the final head write retries (`commitHead`). The reads before the conditional journal write have no retry: `observeHead`, the previous event read, and the put's failure readback. In `Store/Gogol.hs` `get`, any failed metadata call becomes `GetUnknown`.

**Proposed fix:** retry the whole append on `StoreIoError`, bounded, with a model test for a transient failure at each read placement.

**Deferral reasoning:**
- No data is lost: the journal stays consistent and resume recovers the operation.
- Touching the append path just before the final candidate would add risk to every rerun.
The operator deferred it to the next release (2026-10-08).

## F90

**The host transport ran whatever `nagarectl` was first on PATH, not the binary that started it** — P2; **Closed** (fixed in `b9e66e21`; verified on `mp23-c3l`); owner nagare-fix.

**Found by nagare-verify in the section 3 drill on `mp23-c3k`, candidate `3b78d905` (2026-10-08; observed).** The first reviewed `host apply` stopped ambiguous at activation with `host transport exited 1: … Invalid argument 'name'`. `scripts/host-switch.sh` calls bare `nagarectl host name` and `nagarectl inventory guard-legacy`, and `lib/host.sh` calls `nagarectl host path`. Those resolved to the operator's profile `nagarectl` 0.2.2. Nothing reached the host. The transaction closed with no effect through the new host settle ("the reviewed host runs its old closure … with no rollback timer armed"). The drill continued with the candidate's `bin` first on PATH.

**Fix:** the host runtime passes its own executable as `NAGARECTL`, with its directory first on the transport's PATH. The scripts call `"${NAGARECTL:-nagarectl}"`. Tests use a decoy `nagarectl` on PATH.

**Verification (nagare-verify, 2026-10-09, `mp23-c3l`, candidate `3b59bcb7`):** C3 and every section 3 host apply ran with the operator's own `PATH`, with no candidate-binary override, so a profile `nagarectl` 0.2.2 came first. The host transport's nested calls used the invoking binary: drill B's re-pin converged, and so did the reviewed `host stop` and `host start` ([section 3](mp23-independent-results-2026-10-07/section3-3b59bcb7/)).

## F91

**After a failed host upgrade is closed, `inventory status` refuses outright until the previous flake.lock is restored** — P3; **Deferred (next release, operator 2026-10-08, decided in nagare-fix's session)**; owner nagare-fix.

**Found by nagare-verify in section 3 drill A on `mp23-c3k` (2026-10-09; observed).** Close reverted the host scope to its base, but the operator's flake.lock was still re-pinned. Every `inventory status` then failed with `reviewed host inputs differ from the selected configuration or lock` (from `inventoryHostAdapter`), and so did `doctor`'s inventory checks. Restoring the previous lock clears it.

The procedure now says to restore the accepted lock first in the failed-upgrade exit. Reporting this as host-input drift instead of failing would change `inventory status` for every context. It is neither data loss nor blocking; the operator deferred it to the next release.

## F92

**`doctor` verifies every retained scheduled backup serially, so its run time grows without bound** — P2; **Closed** (fixed in `534ff1a1`; verified on `mp23-c3l`); owner nagare-fix.

**Found by nagare-verify on `mp23-c3k`, candidate `3b78d905` (2026-10-09; observed).** The section 3 baseline `doctor` hit a 600 s timeout with no output. Run alone, it finished in 16 min 9 s (exit 0, 29 checks), while 164 backup objects were retained after about 4 hours of `*/15` schedules across five databases. While it ran, its only child processes were serial `gcloud storage cp` and `storage objects describe` calls for every backup object and receipt. Scheduled pruning is not enforced, so retained backups only grow, and a context with months of hourly backups would take hours.

**Cause (nagare-fix):** `scheduledRecoveryPointProbes` in `Cli/Data/ScheduledReceipts.hs` runs the full `scheduledReceiptReport`, the code `db backup-receipts` uses, which downloads and verifies every candidate. It then reads only the freshness, which depends only on the newest verified recovery point.

**Fix (`534ff1a1`):** a freshness-only scan that walks backups newest-first and stops at the first object and receipt that verify, so one verified object is read per database.

**Verification (nagare-verify, 2026-10-09, `mp23-c3l`, candidate `3b59bcb7`):** `doctor` exited 0 in 110–119 s at each of the four section 3 states, with about 5 hours of `*/15` backups retained. On `3b78d905` it took 16 min 9 s ([section 3](mp23-independent-results-2026-10-07/section3-3b59bcb7/), `snap-*/doctor.txt`).

## F93

**A host upgrade on a context with a bound age key commits on the host, then strands its transaction on the review's second activation operation** — P1 (no data loss; blocks section 3); **Closed** (fixed in `f075df60`; verified on `mp23-c3l`); owner nagare-fix.

**Found by nagare-verify in section 3 drill B on `mp23-c3k`, candidate `3b78d905` (2026-10-09; observed).** The re-pin review `apply-b` (nixpkgs `b1b87598`) has two operations on `platform:host/nixos-system/system`:
- `UpdateResource` op-349a;
- `RunDeclaredOperation` op-1b84, which depends on op-349a.
Both carry a version-2 activation plan: the same old closure (`eaad089`), the same new closure (`b1b8759`), a required credential receipt, and each its own activation ID.
- op-349a activated: `switch-to-configuration test` ran 01:30:38–01:30:46. The fresh login passed, the switch committed at 01:30:49, and op-349a completed at 01:31:00.
- op-1b84 was then refused at preflight with no reason (F88's second defect). `preflightState` requires the plan's old closure or this plan's own commit, and the host is now committed to the new closure under op-349a's activation.
- `inventory resume` refused the same way. `inventory close` reported op-349a completed, op-1b84 never started, and the host scope kept with nothing converged.

The host itself is healthy on the new system: timer inactive, k3s active, node Ready, all pods Running. The plans are preserved in `s3/evidence` (blobs `88b65015…`, `4f903ba4…`).

**Expected:** a re-pin review on a host with a bound credential converges, with an interpreter test. The public fixture's re-pin has no bound age key, so it did not exercise this path.

**Fix (`f075df60`, nagare-fix):** the credential receipt is keyed by the reviewed activation, not by the operation that wrote it, so the review's second operation finds the committed activation and converges.

**Verification (nagare-verify, 2026-10-09, `mp23-c3l`, candidate `3b59bcb7`):** section 3 drill B's re-pin review on a host with a bound age key (`UpdateResource` plus `RunDeclaredOperation` on `platform:host/nixos-system/system`) converged in one apply ([section 3](mp23-independent-results-2026-10-07/section3-3b59bcb7/), timeline 07:33:33).

## F94

**`inventory resume` stops "ambiguous" without the adapter's recovery reason** — P3 (no data loss; the refusal itself is correct); **Deferred (next release, under the operator's overnight rule of 2026-10-08)**; owner nagare-fix.

**Found by nagare-verify in section 3 drill A on `mp23-c3l`, final candidate `3b59bcb7` (2026-10-09; observed).** The failed host upgrade was stopped mid-activation, and the on-host timer reverted it to the old closure. `inventory resume` then exited 1 with only `ambiguous tx-867b8bf0… at op-22a040a9…`. The host's recovery decision carries the reason and the exit ("the reviewed host runs its old closure … with no rollback timer armed; close the transaction and review the change again", `Adapters/Host.hs` `recoveryState`). The resume behaved as documented: it did not switch again, and it journaled nothing (the head's next sequence stayed at 826). `inventory close` was the documented next step.

**Cause:** `Execute/Driver.hs` maps every non-complete recovery decision (`RecoveryUnresolved`, `RecoveryLandedUnready`, `RecoveryTargetReplaced`, `RecoveryTerminalFailure`, and a `RecoverySafeToRetry` that is not allowed) to `StoppedAmbiguous transaction operation`, which drops the reason. This is the class of F88's second defect, on the resume path, and it affects every adapter.

**Expected:** `StoppedAmbiguous` carries the decision's reason, and `resume` prints it and the named exit.

Second observation (mp23-c3m, candidate `83124396`, bootstrap stage 7, 2026-10-09): `apply` also printed only `ambiguous tx-e5c3b77f… at op-18e0018d…`. The reason was only in the journal: the transport's fresh Tailnet login met Tailscale SSH's periodic re-authentication ("Tailscale SSH requires an additional check. To authenticate, visit …") and timed out. Nothing was activated (no rollback timer, no activation record, host on its initial system). The exit needs the operator to approve the check, which the message never tells them.

**Deferral reasoning:** the operator sees a refusal with no reason, but nothing is mutated. The host procedure (`day-2-host-changes.md`) already names close as the exit after a revert. Under the overnight rule (2026-10-08), non-critical findings are deferred and reported in the morning.

## F95

**A host upgrade that restarts `tailscaled` or the network ends its own activation session, so it can never commit, and the apply hangs** — P1 (no data loss; blocks section 3's k3s upgrade drill); **Closed** (fixed in `83124396`; natively verified by section 3 drill C on `mp23-c3m`); owner nagare-fix.

**Found by nagare-verify in section 3 drill C on `mp23-c3l`, final candidate `3b59bcb7` (2026-10-09; observed).** The reviewed re-pin to nixpkgs `e7439b6b` (k3s 1.35.8 → 1.36.4) planned and applied. On the host:
- 08:07:21: `switch-to-configuration test` started. It runs under `systemd-run --pipe --wait` inside the transport's SSH session (`nixos/lib/nagare-safe-activate.sh`), which reaches the host through Tailscale SSH.
- 08:07:38: the new system restarted `network-addresses-eth0`, `dhcpcd`, `sshd` and `tailscaled` (1.102.4 → 1.102.5). tailscaled logged "terminating SSH session … context canceled". The network was unreachable until DHCP renewed at 08:07:45.
- 08:07:45: `nagare-switch-activate.service` exited 101, which is Rust's panic exit code: the switch lost its piped output partway through.
- 08:08:54: k3s 1.36.4 started.
- Because the network was down when the session ended, the client never saw EOF. Its ssh has no `ServerAliveInterval`, so it waited indefinitely, the fresh-login check and commit never ran, and the apply hung.
- 08:17:31: the rollback timer reverted the host to the previous system, and k3s 1.35.8 started on the same datastore.

nagare-verify ended the hung ssh by its exact PID 22 minutes later, which is what a keepalive would have done. The apply then stopped `ambiguous`. The documented exit worked: resume refused without switching (F94: with no reason shown), `close` settled "no effect", and the previous lock was restored. Afterwards the data hash matched the pre-upgrade snapshot (`24467b7d`), all pods were running, and `doctor` exited 0 ([evidence](mp23-independent-results-2026-10-07/section3-3b59bcb7/)).

**Drill B shows the same mechanism.** Its switch also exited 101 at 07:32:44, after six seconds, when tailscaled 1.102.3 → 1.102.4 restarted. The network stayed up, so the client got EOF, the fresh login succeeded, and the commit ran. B therefore committed a system whose `switch-to-configuration` had been cut off. The reviewed reboot that followed activated it fully.

**Expected:**
- The activation does not depend on the session that the activation may restart. For example: start the switch as a detached transient unit with its output in the journal, then reconnect with fresh logins to read the unit's result before the commit.
- The transport's ssh has a keepalive, so a dead session fails within a bounded time instead of hanging the apply.
- An interpreter or script test kills the session during the switch.

**Fix (`83124396`, nagare-fix):** `nagare-safe-activate activate` starts the switch as a detached transient unit and returns at once. The client learns the result over fresh logins (`activation NEW`: running, done with its exit code, or unknown) and commits only after `DONE` and a fresh-login check. `commit` refuses while the unit runs. Every ssh of the client and transport has a keepalive. Tests: `nix/checks/scripts/test-host-switch-session-loss.sh` in the flake check, plus scenario 4 of the `host-switch-auto-rollback` NixOS VM test, which takes the network down and ends the deploy session mid-switch; that switch still committed ([VM log](mp23-independent-results-2026-10-07/f95-vm-test-83124396/vm-f95.log.gz)).

**Verification (nagare-verify, 2026-10-09, `mp23-c3m`, candidate `83124396`; observed):** section 3 drill C, the same re-pin to nixpkgs `e7439b6b` (k3s 1.35.8 → 1.36.4), committed on its first apply in 5 minutes. The host journal for the activation (`apply-c-host-journal.txt`) shows the following:
- 17:23:48: the switch started in its own transient unit.
- 17:24:05: the new system restarted the network units and `tailscaled`, as on `mp23-c3l`.
- 17:24:30: k3s 1.36.4 started.
- 17:24:31: `nagare-switch-activate.service` finished on its own, after 42 s.
- 17:24:36: the client read the result over a fresh login and committed, which disarmed the rollback timer.

After a reviewed cold reboot the host ran k3s 1.36.4 on kernel 6.18.55. The data hash was unchanged (`24467b7d`), no pod was left not running, and `doctor` exited 0 ([section 3](mp23-independent-results-2026-10-07/section3-83124396/)).

## F77

**A database volume claim deleted outside review while its pod runs stays Terminating, and every review of the database refuses until it goes** — P1; **Deferred**; owner: deferral ledger (operator, 2026-10-07). The reviewed exit belongs to the next MasterPlan.

**Found by EP-182's fast tier on the validated world (2026-10-06, nagare-first-principle, claude-opus-5-5).** This was the first run with a world that renders `pvc-protection`. The finding was proved by three single-fault schedules (observed).

**Semantics** ([RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md) U6; experiments E7 and E16 in [the k8s semantics audit](k8s-semantics-2026-10-06/results.md#e16)):
- A database's StatefulSet mounts its PVC by name (`Nagare/Dsl/Database/Render.hs`, `dbPvcName`). A DELETE of that PVC while the pod runs is held by the `kubernetes.io/pvc-protection` finalizer. The PVC stays, with its UID, a deletion timestamp and the finalizer, for as long as the pod runs. That can be indefinitely: nothing in Nagare ends the pod.
- While held, the pod keeps the data readable, and the scheduler refuses every new pod that names the claim.
- When the pod ends for any reason, the claim goes within seconds, before the StatefulSet's replacement pod can schedule. Under local-path's `Delete` reclaim policy, its volume and data go too. A volume patched to `Retain` first stays `Released`, and a recreated claim pinned to it mounts the original data.

**Schedules** (fast tier, `InventoryRecoveryModelSpec`, at EP-182 revision `12876d1b`):
- "create a database, then retire it", `Deleted` at `ObserveCall` 52, review `retire database`: `I1: planning refused` with `invalid-retirement`.
- "create a database, update its resources, then update it again", `Deleted` at `ObserveCall` 52, review `update database`: `I1: planning refused` with `observation-unavailable` naming `standalone:database-pg/pg/pvc`.
- The same scenario, `Deleted` at `ObserveCall` 66, review `create database`: the same refusal.

In each, the fault deletes the PVC between reviews, so no transaction is open. The refusal is at planning, and I1 finds no supported exit.

**Why there is no exit today.**
- **While the claim is held.** Planning reads a terminating object as `ObservationUnavailable` (F74's fix, G5), which `Plan/Changes.hs` turns into `observation-unavailable` for a deploy or update. A retirement needs an owned present member to retain (`invalid-retirement`, `Plan/Lifecycle.hs`). The adapter's reason ("being deleted … replan once it is gone") is dropped by planning, so the operator sees only "resource observation is unavailable".
- **After the claim goes.** Planning refuses `durable-resource-missing` for every review that keeps or retires the database. `inventory collect` covers only retained, present, stateless members. The reviewed way back is a rebind (ADR 27 §3) of a recreated, stamped claim.

**Why the model missed it before.** The old world deleted a PVC at once. That leads straight to `durable-resource-missing`, which the model rightly excuses as data lost outside review (`deletedDataRefusal`). EP-182's world holds a mounted claim as a real API server does.

**Exit for MP-23: a documented limit with a runbook.** The steps are in [A database volume claim deleted outside review (F77)](../runbooks/inventory-operations.md#a-database-volume-claim-deleted-outside-review-f77):
1. Set the volume to `Retain` at once.
2. Save the claim's stamped manifest.
3. Back up through the running pod. A backup Job cannot mount the claim, and the reviewed backup cannot be planned.
4. Delete the pod, so the claim goes.
5. Close any stopped transaction on the scope. Where close refuses only because an operation on the claim is unknown, this is ADR 26's attested close, which accepts nothing.
6. Recreate the claim from the manifest, pinned to the retained volume, as field manager `nagare-inventory`. If the volume is lost, recreate it empty and restore the dump with the engine's client.
7. Rebind the `replaced-incarnation` claim.

E16 verified steps 1, 2, 4 and 6 (and a file-level backup through the pod) on k3s v1.34.6. Steps 5 and 7 are the documented close and rebind procedures, not yet exercised end to end on this case.

**Ledger.** The three violations are listed in the recovery model's two-sided known-defect ledger (`cli/nagarectl/test/Nagare/Test/Model/KnownDefects.hs`) with this owner. The fast tier fails if the count changes or a new violation appears. The deep tier does not read the ledger and reports them.

**For the next MasterPlan.**
- A reviewed exit that plans the backup through the running pod, the release of the claim (the volume set to `Retain`, the pod deleted) and the rebind. Each step is guarded by the claim's UID and deletion timestamp.
- Planning carries the adapter's `ObservationUnavailable` reason into its refusal, and a terminating durable claim points at the runbook. Not done here: the refusal drops the reason today (`Plan/Changes.hs`, `observation-unavailable`), so a pointer in the adapter's message would not reach the operator.

**Verification.** None. Deferred findings are not closed; the ledger entry is removed when the reviewed exit lands.

## F78

**While a StatefulSet's own template never becomes Ready, every transaction stops at it, and independent members planned after it are never created until the template is corrected** — P2; **Deferred**; owner: next MasterPlan, "let a transaction continue independent operations past a stop" (operator, 2026-10-07).

**Found by EP-181's invariant I9 ("a correction converges") on EP-182's validated world (2026-10-07, claude-opus-5-5).**

**Schedules** (fast tier, `InventoryRecoveryModelSpec`, scenario "create a database, update its resources, update it again, then restart it"):
- `LandsUnready` at `MutateCall` 5, the StatefulSet's create;
- `LandsFailed` at `MutateCall` 5, the same write.

**Mechanism.**
- The create lands the database's StatefulSet with a template that never becomes Ready.
- The driver ends a transaction at its first stop (`StoppedAmbiguous`), so the create transaction stops at the StatefulSet. Its later operations never start, including those of members that do not depend on the StatefulSet: `backup-account`, then `backup-read-binding`, which is OrderedAfter it.
- Every later review of the database (the update, the correction, the restart) plans those creates again, sequenced after the StatefulSet's operation, and stops at the StatefulSet again.
- In this schedule the "correction" re-applies the faulted create template, so the StatefulSet never becomes Ready and those members never appear.
- With a template that does become Ready, the next transaction passes the StatefulSet and creates them.

**Excuses I9 already has, and why they do not cover this.**
- The StatefulSet itself is excused: its final template is the faulted one, matched by spec digest.
- `backup` is excused: it is absent, never started, and OrderedAfter the StatefulSet.
- `backup-account` has no OrderedAfter path to the StatefulSet. Only execution order keeps it back, and the operator decided not to excuse that.

**Ledger.** Both schedules are in the recovery model's known-defect ledger (`cli/nagarectl/test/Nagare/Test/Model/KnownDefects.hs`) under F78, with this owner.

**Operator view.** `inventory status` reports the missing members. The managed-databases guide says they appear in the first review after the database's template is corrected and lands Ready.

**For the next MasterPlan.** Let a transaction continue the operations that do not depend on a stopped one, so a broken workload no longer starves independent members.

