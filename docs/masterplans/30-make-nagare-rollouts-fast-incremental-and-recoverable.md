---
id: 30
slug: make-nagare-rollouts-fast-incremental-and-recoverable
title: "Make Nagare rollouts fast, incremental, and recoverable"
kind: master-plan
created_at: 2026-10-29T14:39:19Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:39:19Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T16:27:26Z
      mode: "update"
      note: "Add MasterPlan 29 follow-ups: gcloud ownership stall (EP-226 M4) and journal catch-up bound (EP-227 M2)"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:45:25Z
      mode: "update"
      note: "Apply review: EP-226 M4 freed from EP-224 M1 in registry and graph; Admission/Driver ordered ownership and test registration path added to Integration Points; MP-29 close reflected"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T19:47:51Z
      mode: "implement"
      note: "Registry: EP-226 M4, EP-224 M1, EP-225 M1-M2 landed; EP-229 merged complete"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-30T01:31:13Z
      mode: "implement"
      note: "EP-225 and EP-227 complete, EP-226 M1-M3, EP-227 M1 cancellation"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:44:53Z
      verdict: "changes-requested"
      note: "Decomposition sound and every source claim verified at HEAD; registry blocked EP-226 M4 behind EP-224 M1 against the Decision Log, Execute/Admission.hs and Driver.hs shared by EP-225/227/228 had no ordered owner, MP-29 sentence stale after its 2026-10-29 close"
---

# Make Nagare rollouts fast, incremental, and recoverable

This MasterPlan coordinates six living ExecPlans. Its registry owns child status; each child
owns implementation milestones. No performance improvement is claimed by this planning revision.


## Vision & Scope


A developer should be able to move an admitted Nagare context between releases in minutes,
understand what will change before applying it, and resume after interruption without repeating
successful effects. A release identity change must not turn hundreds of unchanged objects into
individual transactions. An actual application or platform change should pay for its changed
resources, required dependencies, and real provider waits, with bounded overhead.

The trigger is the 2026-10-29 v0.11.1 intranet transition: its second review contains 205 Kubernetes
verifications, five Helm verifications and one Kubernetes update. The original EP-224 proposed
call reductions but left semantic identity, verification persistence, stage coordination and
changed-rollout latency largely untouched. The user authorized this wider architectural repair,
including a MasterPlan, and explicitly requires no Python tooling.

The target architecture has five boundaries. A deterministic compiler distinguishes deployment
meaning from source provenance. A command session owns the selected inventory head and guarded
cluster connection. An observation epoch gathers bounded live reads for one phase. A transaction
coordinator commits proof and schedules effects through explicit dependencies. A typed Haskell
rollout runner coordinates reviews, resumptions, progress and release evidence. An epoch is a set
of observations collected during one bounded interval; it is not an atomic cluster snapshot.

Keep the existing reviewed-inventory model, exact identity checks, conditional writes, retention,
host self-reversion and authoritative remote store. This is not a replacement Kubernetes
controller, a distributed scheduler, or automatic rollback of durable data. Host, Helm, Pulumi,
database and destructive operations stay exclusive unless an adapter supplies and tests a
specific safe scheduling contract. Arbitrary provider downtime and cold compilation cannot be
made fast by suppressing readiness or narrowing the clock.

Acceptance has three distinct workloads. For an artifact-ready release whose deployment content
is unchanged, every stage plan must finish in under 60 seconds and the interval from starting the
operator candidate-pin update to successful transition commit must be under 300 seconds. A
ready-artifact single stateless workload update and a fixture of four independent stateless
updates must finish plan plus apply within 300 seconds when each provider becomes ready within
60 seconds. Within that interval Nagare-owned overhead is at most 60 seconds; readiness intervals
are measured as elapsed intervals, not summed concurrent worker time. With cold artifacts, report
the complete time including realization and transport separately, never claim the warm target
passed by discarding those costs. The runner prepares artifacts before the bounded activation
phase and reports preparation start to final commit as the end-to-end total.

Use five consecutive warm measurements, report all samples, median and maximum, and require every
sample to satisfy its applicable bound. Record at least one cold run. Provider-unavailable and
stuck-readiness runs must stop by their declared deadline with an actionable recovery identity;
they are failed samples, not removed outliers. EP-224 defines structural growth gates so an
accidentally fast workstation cannot hide work proportional to unrelated history. The initiative
remains open until native evidence passes, including the intranet; naming a blocker is not completion.


## Decomposition Strategy


Use six independently testable concerns: measurement, stable desired state, guarded live reads,
durable verification, incremental rollout execution, and Haskell ownership of the release
orchestration. EP-224 remains the entry point and owns the baseline and final regression gate.
Four children own the architectural changes, and EP-229 ports the release scripts, which needs
none of them and runs in parallel from the start. Keeping everything in EP-224 would obscure
persistent-state and cluster-session contracts; splitting each optimization into a plan would
obscure their common correctness boundaries.

The relevant existing decisions are [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
(release identities and final pin), [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
(host activation), [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
(fresh guarded apply), [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
(typed composition, revisions and conditional journal), [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
(Haskell tools and thin shell), [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
(real production interpreters and current fast-tier gate), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)
(effect-free verification and per-operation recovery), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
(physical identity). Their safety obligations remain; ADR 22 gains the architectural direction
in this planning change, explicitly distinguished from implementation.

[MasterPlan 29](29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md)
already owns common store opening, immutable reads and reviewed-access latency. Reuse its
`Command.Open` and tracing work, preserve its access benchmarks, and do not create a competing
store session. MP-29 closed on 2026-10-29 with EP-221 M3 accepted at reduced scope; its two
fixable follow-ups are owned here by EP-226 M4 and EP-227 M2, and nothing here reopens its gate.
This initiative owns platform transition and shared rollout execution. It has no whole-plan
dependency on MP-29.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-224 | Transition cost, fixtures and final latency gate | [224](../plans/224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md) | M3 requires EP-225–229 Complete | MP-29 tracing | In Progress (M1–M2 done) |
| EP-225 | Stable deployment meaning and incremental reviews | [225](../plans/225-keep-platform-revisions-stable-when-deployment-meaning-is-unchanged.md) | EP-224 M1 | None | Complete |
| EP-226 | Guarded command sessions and bounded observation epochs | [226](../plans/226-share-bounded-cluster-observations-through-a-guarded-command-session.md) | EP-224 M1 for M1–M3; none for M4 | EP-225 | Complete |
| EP-227 | Durable batched verification with per-operation recovery | [227](../plans/227-commit-verification-proofs-without-per-resource-remote-transactions.md) | EP-224 M1; EP-225 M2 and EP-226 M1–M2 before its M2 | None | Complete (M1 cancelled) |
| EP-228 | Incremental rollout coordinator and Haskell release runner | [228](../plans/228-run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress.md) | EP-225, EP-226, EP-227 and EP-229 Complete; EP-224 M2 | None | In Progress (M2 done) |
| EP-229 | Haskell ownership of candidate, intranet and rehearsal orchestration | [229](../plans/229-own-candidate-intranet-and-rehearsal-orchestration-in-haskell.md) | None | EP-224 M2 reads its run index | Complete |


## Dependency Graph


The default implementation order is EP-224 M1–M2, EP-225, EP-226, EP-227, EP-228, then EP-224 M3;
EP-229 has no prerequisite, runs beside that sequence and finishes before EP-228 M3.
EP-224 M1 supplies trace types and a baseline fixture, not the final performance proof. Its M2
supplies the Haskell cost-record consumer before the release runner exists, using real captured
command output. This milestone ordering prevents a cycle between measurement and final rollout.

EP-225 and EP-226 can be developed independently after the baseline, and EP-226 M4 has no
prerequisite at all, so it may land before EP-224 M1. EP-227 M1 can establish the
append protocol before the session is integrated; its M2 consumes EP-226's accepted guarded
epoch and bounded read interface, plus EP-225 M2's accepted validation contract. EP-228 consumes complete semantic, session and journal behavior,
not speculative copies of their types. Its first integration check moves one unchanged scope and
one changed Deployment through the real plan/apply/resume path before extending host or Helm
variants. Final EP-224 M3 consumes the completed runner, EP-229's
Python-free release path and all four architectural children.


## Integration Points


**Cost model, owned by EP-224.** Extend
`cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs`, put the versioned trace codec in
`cli/nagare-contract/src/Nagare/Contract/Trace.hs` (the small schema package nagarectl already
depends on, so the harness never links the nagarectl library) and add the producer under
`cli/nagarectl/src/Nagare/Inventory/Trace.hs`. Count actual transport requests separately from
logical reads and cache hits. Carry explicit command, stage, epoch, operation and attempt IDs;
a mutable global “current operation” is invalid when reads overlap. The other children emit
events through this interface; EP-228 owns orchestration, not another trace schema. The harness
uses that codec from `nagare-contract` rather than copying JSON assumptions, and reads operation
counts from the trace rather than decoding review JSON.

**Desired state and review contract, owned by EP-225.** Add a typed deployment-meaning projection
and explicit platform validation requirements to planning. Preserve accepted scope bytes when
only diagnostic provenance differs. Release provenance is recorded separately. A validation
requirement proves that a set of already accepted resources still satisfies ownership, identity,
desired fields and readiness; it does not authorize a write. EP-227 consumes these requirements
as batched proof obligations; EP-228 consumes the resulting impact graph. The platform stamp
depends on both required proofs and changed operations. It cannot be published on old health
evidence merely because semantic hashes match.

**Connection and observation contract, owned by EP-226.** One guarded cluster session per command
and identity generation, shared across Kubernetes, Helm and access consumers that use the same
cluster. Changes to kubeconfig, referenced identity material, selected host or cluster replacement
invalidate it. Read epochs are keyed by cluster identity, full API resource address and phase;
they never cross writes, host activation, credentials changes or process restarts. EP-227 consumes
a fresh verification epoch; EP-228 creates new readiness epochs after submission. The existing
inventory command context remains the store-opening authority.

**Transaction authority, owned by EP-227.** One coordinator retains the writer claim and advances
the journal head conditionally. Batch read-only proofs without losing per-operation receipts or
the existing event decoder. Version-one journal events may be uploaded concurrently, but only a
contiguous validated prefix becomes committed by a conditional head update. This reduces serial
round trips, not the obligation to retain evidence. EP-228 submits mutation intents and receipts
through the same coordinator; no worker writes the head independently.

**Execution path, edited in order.** `cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`
and `Execute/Driver.hs` are changed by three children: EP-225 M2 adds the serial validation
consumer at apply admission, EP-227 then replaces that consumer with the append coordinator and
read-only proof path under the same `ValidationRequirement` contract, and EP-228 M2 last adds
scheduling capabilities to the driver. Each later child extends the accepted code of the earlier
one; none adds a second head writer or a second validation contract. The producer/consumer check
for this handoff is EP-227 M2 running EP-225 M3's saved-review fixture with zero per-member
operations and the same refusals. New test modules are registered in
`cli/nagarectl/test/Nagare/Test/Suite.hs` and `cli/nagarectl/nagarectl.cabal`; the two-line
`cli/nagarectl/test/Spec.hs` only calls the suite.

**Scheduling and rollout integration, owned by EP-228.** Own
`cli/nagarectl/src/Nagare/Inventory/OperationStep.hs`, driver scheduling changes after EP-227,
`cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs`, bootstrap sequencing integration and the
run index, manifest, progress and cost extensions of the Haskell release runner. EP-225 owns
declaration selection in `Bootstrap/Platform.hs`; EP-226 owns runtime construction in CLI
inventory adapters; EP-224 only adds instrumentation hooks there. Shared edits to adapter
interfaces, cabal module lists and test registration follow that order.

**Release runner, owned by EP-229.** Own `cli/nagare-harness/src/Nagare/Harness/Release/` and
the harness command grammar `release candidate`, `transition run`, `transition pin-tag` and
`transition rehearse`; turn `scripts/release-candidate.sh`, `scripts/release-intranet.sh`,
`scripts/release-rehearse.sh` and `scripts/transition-rehearsal.sh` into argument-preserving
`exec` wrappers; replace text scraping and jq/Python decisions with typed outcome documents; and
prove the supported release path runs with no Python executable, including transitively invoked
transition-specific helpers. Its only nagarectl change is additive machine output for the plan
summary and apply outcome, in files EP-228 owns, landed first. EP-228 M3 and EP-224 M2 consume
its versioned run index; neither redefines it. Existing unrelated Python migration is outside this initiative, and no new Python
tool is introduced.

**Compatibility and cutover.** EP-225 owns review version negotiation if adding validation
requirements changes the wire. EP-227 owns journal compatibility. EP-228 owns transition-finalize
recovery and stage records. Before changing any wire, capture a previous supported release fixture,
prove the new reader handles it, and make old readers refuse new unsupported writes. Open old
transactions retain their original adapter versions and serial semantics until resolved. A newer
review is generated only from an idle head; never rewrite an admitted review to fit a new scheduler.


## Progress


2026-10-29: landed EP-226 M4, EP-224 M1–M2 (trace, baseline fixture, cost collector), EP-225
M1–M2 (retained revisions; the bootstrap sweep is admission validations, not journaled verifies)
and EP-229 (Haskell release runner, run index, no Python). The disposable v0.11.0 rehearsal of
`842cd70c` passes with an 83 s traced activation. EP-225 is complete (`b611127d`): a release moved
to another workspace selects only its stamp and keeps every scope revision. EP-226 M1 guards a
command once and binds its requests to the guarded kubeconfig (`d59a85c2`); M2 plans from one
grouped epoch per batch (sweep planning: 2 transported reads for 206 members, was 412). EP-227 is
complete: admission proves validations from one fresh epoch (sweep apply: 6 reads, was 414), and
its batched journal protocol was cancelled. EP-226 is complete: the native rehearsal of `a5dd71e2`
passed, its platform stage at about 70 processes per command (879 before). EP-228 M2 overlaps up
to four independent stateless updates' readiness. Next: EP-228 M1, M3, M4, then EP-224 M3.
Final
acceptance includes unchanged and changed rollouts, recovery, growth limits, Python-free release
tooling and five warm intranet measurements.


## Surprises & Discoveries


The first native cost record (local rehearsal, 2026-10-29) shows the sweep stage spending 879
external processes on 839 Kubernetes requests: one kubectl process per read. EP-226 should treat
process count as a first-class cost beside request count; grouping reads (its M2) removes both, and
its Surprises record why the existing status snapshot cannot be reused for planning as is.

At source revision `5c57e81785cd04d03dee424e7b70966987b9814b`,
`Inventory/Plan/Changes.hs` sets `bootstrapReview` when a selected generated marker is not settled,
then emits `VerifyResource` for unchanged Kubernetes and Helm members. Thus source-path churn is
not the only cause. `Bootstrap/Platform.hs` and `bootstrapPreservedScopeVectorDigest` compare full
canonical scope bytes; `sameDeclarationsModuloSource` is used by the local substrate path only.

`Inventory/Execute/Driver.hs` already skips `adapterExecute` for `VerifyResource`, as ADR 26
requires. Duplicate reads arise in preflight and verification, with possible readiness reads,
not from executing and then verifying the resource. The original plan's suggested execute-read
reuse targeted a phase that the production driver does not run.

`KubernetesSnapshot.hs` falls back to single reads on unhandled batch failures and groups requests
without an explicit cluster identity in the grouping key. It is a starting point, not a complete
freshness or error budget. The old plan's “one guard per command” and “plus two guards” acceptance
also conflicted. Count guard admissions separately from their subprocesses and identity renewals.

The stage-2 saved review was read locally and confirms 205 Kubernetes verifies, five Helm verifies
and one update. Historical timing and process-sample claims in EP-224 remain reported incident
evidence; this review did not execute the transition or establish a new latency baseline.


- 2026-10-29 (EP-226 M2): the fake API server parsed only single-name `get`, so a grouped read
  returned the first object alone and every other name read as absent; that, not list-item bytes,
  made apply refuse the earlier grouped-planning attempt. kubectl 1.37 on the intranet answers
  several names with a List of the found objects. Fakes of a transport must cover each argument
  form the runtime sends; ADR 25's rule that fakes agree with recorded native semantics applies.


## Decision Log


- 2026-10-29: Expand EP-224 into this MasterPlan at the user's request. Root repairs must cover
  semantic change selection, live observation, persistence and changed-rollout execution; a trace
  dashboard or a single successful no-op run cannot close the initiative.
- 2026-10-29: Keep authoritative history and fresh live proof distinct. Semantic equivalence
  retains a revision; it does not assert live health. Batch that proof instead of omitting it.
- 2026-10-29: Preserve serialized authority for writes while overlapping safe observation and
  independent readiness. Blanket parallel execution risks shared resources and recovery; a daemon
  or transport rewrite is not a prerequisite for removing structural work.
- 2026-10-29: Require Haskell for rollout, evidence and history tooling. Shell is process glue only;
  the changed release path must run with Python absent, honoring the user's explicit constraint.
- 2026-10-29: Take two fixable costs found by MasterPlan 29's closing benchmark. EP-226 M4 removes
  the per-command `gcloud projects describe` ownership read, which stalled about 15 s in two of ten
  reviewed commands; it has no dependency and may land first. EP-227 M2 now also requires that the
  journal tail the next command catches up after a transition does not grow with verified resources
  (429 events and 22 s after v0.11.1).
- 2026-10-29: Split the Haskell port of the release orchestration out of EP-228 into EP-229. The
  port of the four scripts (624 lines of shell, Python in two of them) needs none of EP-225–227,
  so it no longer waits for them; EP-228 M3 extends the ported runner and depends on EP-229.
- 2026-10-29: Cancel EP-227 M1 (batched journal append) and its proof capsule. After EP-225 M2
  no unchanged member's verification is journaled (4 journal events per sweep at 205 and 2,050
  members), so nothing per-resource is left to batch; EP-228 uses the driver's serial append as
  the one coordinator. ADR 22's amendment records the withdrawal.
- 2026-10-29: The versioned trace codec lives in `nagare-contract`, not the nagarectl library, so
  the harness's standalone build stays fast; the trace carries operation counts by action and
  executor so the cost collector never decodes review JSON.


## Outcomes & Retrospective


The planning review replaced a six-step optimization list with five linked implementation plans,
an explicit compatibility contract and measurable whole-rollout gates. Runtime improvements,
release confirmation and friction triage remain unimplemented. Distill observed implementation
lessons into the cited ADRs before marking this MasterPlan complete.
