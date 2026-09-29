# MP-23 audit findings tracker

This is the authoritative handoff for implementation findings sent by the audit session. Read it alongside [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). The detailed initial reasoning is in [the audit report](mp23-initial-audit.md); that report is a historical snapshot, while this tracker owns current status.

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
| [F08](#f08) | P2 | Unchanged host bootstrap depends on transient key-file environment and source root | Open | EP-156 |
| [F09](#f09) | P1 | Scheduled-prune preflight prevents recovery after admission | Open | EP-159 / EP-153 |
| [F10](#f10) | P2 | Explaining one resource observes the whole context | Open | EP-153 |
| [F11](#f11) | Build | Conditional-upload optimization has ambiguous try exception type | Closed | EP-156 |

F01 and F11 are independently Closed with [retained verification and source identities](mp23-verification.md). F02 has passing local call-count evidence but still needs its retained status-caller regression. All other entries remain Open, Partial, or Verifying as shown.

## F01

**Host execution mutates after observing a different VM or old closure** — P1; **Closed**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Adapters/Host.hs; scripts/inventory-host-transport.sh.

**Audit evidence:** Actual HostAudit reproduction: all three mismatches previously invoked one mutation callback; after the implementation change all three refuse and invoke zero callbacks. Shell physical-ID guard source-inspected.

**Implementation update:** Changed in the working tree; InventoryHostSpec now includes `effect-time drift after preflight cannot run host activation`.

**Required verification:** Run that checked-in regression; exercise the shell identity mismatch with a command recorder and prove no age-key install/host-switch occurs. Record revision or source hashes and results.

**Verification:** Independently closed; see [commands, results, and source hashes](mp23-verification.md). All seven checked-in host tests pass, including drift refusal; shell identity mismatch exits 2 with zero transport effects.

## F02

**Active transaction status still reads journal entries individually** — P1; **Verifying**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadActiveTransactionStatus.

**Audit evidence:** Actual StoreAudit: valid 50/500-event chains now give successful status with zero single reads and one batch each.

**Implementation update:** Changed to readJournalPrefix in the working tree. Existing batch test exercises the store primitive, not this status caller.

**Required verification:** Add or name a retained regression invoking loadActiveTransactionStatus at both sizes; preserve chain/gap rejection. The wider live timing gate belongs to F06/EP-156.

**Verification:** Not closed. Independent local reproduction passes after the fix; see audit evidence. Remaining closure checks above are pending.

## F03

**Resume loads the same complete journal twice** — P2; **Verifying**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: resumeTransactionWithTakeover, executeWithJournal.

**Audit evidence:** Source trace: resume readJournal then execute readJournal. New executeWithJournal receives already validated events.

**Implementation update:** Fix source-inspected, not independently exercised through complete resume yet.

**Required verification:** Run a same-transaction resume with batch counts and retained operation receipts; require one prefix read and no repeated completed native effect.

**Verification:** Not closed. Awaiting the checks above.

## F04

**Native evidence loads every historical review and can repeat the scan** — P2; **Partial**; owner EP-156 / EP-153.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Status.hs: loadNativeFor; cli/nagarectl/src/Nagare/Inventory/Plan.hs: loadPublishedReview.

**Audit evidence:** loadNativeFor expands every review and its scope/native members. Status invokes accepted and retained loaders. A cold cache makes historical review count a remote-I/O multiplier.

**Implementation update:** Empty-retained fast path added. Accepted scan and nonempty-retained duplicate work remain.

**Required verification:** Hold current inventory fixed while increasing unrelated review history; record remote/member decode counts and cold/warm cost. Demonstrate selection of only necessary native evidence while preserving incarnation binding.

**Verification:** Not closed. Awaiting the checks above.

## F05

**New fresh-login checks can reuse an SSH multiplexed connection** — P1; **Verifying**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: tailnet_fresh_closure, activate.

**Audit evidence:** New Tailnet calls omitted ControlMaster=no/ControlPath=none while the existing safe-switch verifier uses both.

**Implementation update:** Both options now present in the working tree; source-inspected only.

**Required verification:** Capture argv for every call that contributes fresh-login proof and assert both options. Retain a regression with multiplexing configured; verify the proof comes from a new connection.

**Verification:** Not closed. Awaiting the checks above.

## F06

**Journal appends retain excessive serial cloud-command cost** — P1; **Partial**; owner EP-156.

**Locations:** cli/nagarectl/src/Nagare/Inventory/Execute.hs: appendEvent; cli/nagarectl/src/Nagare/Inventory/Store.hs; cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs.

**Audit evidence:** Measured actual appendEvent ObjectOps trace: noninitial event has five found GETs, two absent GETs, two PUTs. Original transport expands to 27 subprocesses/event; successful PUT fast path projects 21. No cloud-duration claim from these counts.

**Implementation update:** Successful conditional-upload acknowledgement optimization underway; redundant head/absence reads and full-prefix listing remain.

**Required verification:** Retain append and resume command-count regressions, preserve conditional writes/lost-ack recovery, then pass EP-156 cold/warm real GCS timing gate. Record append/provider/replay timings separately; no closure from one batched cp.

**Verification:** Not closed. Awaiting the checks above.

## F07

**Installed key with failed service activation cannot recover by retry** — P1; **Verifying**; owner EP-156.

**Locations:** scripts/inventory-host-transport.sh: activate; nixos/modules/nagare-host.nix: install_key.

**Audit evidence:** Extracted activate() with matching installed digest and unavailable Tailscale: two attempts each call status,status,IP then fail; neither reactivates. Helper preserves verified key before service restart.

**Implementation update:** Working tree now retries same-key helper when Tailscale IP check fails; independent post-fix reproduction pending.

**Required verification:** Simulate successful key persistence followed by sops/Tailscale failure, then retry the original operation. Prove activation resumes, no different key is written, fresh-login/readiness succeeds, and wrong keys still refuse.

**Verification:** Not closed. Awaiting the checks above.

## F08

**Unchanged host bootstrap depends on transient key-file environment and source root** — P2; **Open**; owner EP-156.

**Locations:** cli/nagarectl/app/Main.hs: buildHostStageCandidate.

**Audit evidence:** buildHostStageCandidate recomputes credential-bound spec/inputs from NAGARE_HOST_AGE_KEY_FILE and compares the entire scope. Removing the variable or moving hostRoot causes accepted-scope mismatch despite unchanged remote intent.

**Implementation update:** Sent to implementation session; no fix verified.

**Required verification:** After accepting a credential-bound host, clear delivery-only environment and replan; also use another operator root with identical host bytes. Require unchanged/verify-only result while intentional configuration or credential change still refuses/reviews correctly.

**Verification:** Not closed. Awaiting the checks above.

## F09

**Scheduled-prune preflight prevents recovery after admission** — P1; **Open**; owner EP-159 / EP-153.

**Locations:** cli/nagarectl/app/Main.hs: inventoryExecutionRegistry, verifyReviewedScheduledPruneProvider; cli/nagarectl/src/Nagare/Inventory/Command.hs: recoverInventoryWithFactory.

**Audit evidence:** Registry factory runs provider preflight before public resume/recover. Admission includes prune scope in headAccepted; guard therefore classifies its backup as pruned, excludes it, then requires it present. Partial deletion also violates original provider-list check.

**Implementation update:** Sent with full call-chain evidence. Applies to retained recovery even while new scheduled prune is deferred.

**Required verification:** Exercise public resume/recover for an already admitted original prune, both before effect and after deletion of one member. Prove exact terminal recovery remains reachable, no blind deletion retry, and new deferred admission still refuses.

**Verification:** Not closed. Awaiting the checks above.

## F10

**Explaining one resource observes the whole context** — P2; **Open**; owner EP-153.

**Locations:** cli/nagarectl/app/Main.hs: runInventoryStatus / InventoryExplain; cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs: observeKubernetesHealth.

**Audit evidence:** runInventoryStatus uses requested ID only after all adapter construction/observations/health/history. Invalid IDs also pay this cost. Kubernetes readiness repeats GETs for supported objects.

**Implementation update:** Sent to implementation session; no fix verified.

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
