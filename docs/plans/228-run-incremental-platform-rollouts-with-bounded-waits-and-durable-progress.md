---
id: 228
slug: run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress
title: "Run incremental platform rollouts with bounded waits and durable progress"
kind: exec-plan
created_at: 2026-10-29T14:39:34Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:39:34Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:44:53Z
      verdict: "comments"
      note: "Commit path, 12-stage bound, single resume and Python claims verified; release-intranet.sh has no just recipe; the M3 behavior-preserving port needs none of EP-225-227"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:45:25Z
      mode: "update"
      note: "Name the actual public recipes and script entry points"
---

# Run incremental platform rollouts with bounded waits and durable progress

This ExecPlan is a living document. Its completed behavior feeds EP-224's final native latency gate.


## Purpose / Big Picture


Turn platform transitions into resumable incremental rollouts. A developer sees the impact before
apply, preparation completes before disruptive activation, independent stateless workloads can
become ready together, and every wait has a deadline and visible progress. Successful operations
are not replayed after interruption. The Haskell release runner that EP-229 owns records every
attempt's progress and cost.

This is the integration of stable desired state, guarded observations and efficient durable proof.
It preserves reviewed plan/apply commands and the release recipes EP-229 moves to Haskell. Its
implementation gate is model/rehearsal correctness; EP-224 independently
closes the final intranet performance gate, so the dependency graph has no cycle.


## Progress


- [ ] M1: One unchanged scope and one changed Deployment pass a typed transition impact/phase path,
  with artifact preparation, explicit barriers and resumable finalization.
- [ ] M2: Independent stateless updates overlap readiness under a bounded coordinator; dependent,
  destructive, data, Helm and host work retain their required ordering and recovery.
- [ ] M3: The ported runner (EP-229) keeps a versioned run index with progress and cost for every
  attempt, reuses verified prepared material, resumes only under the recovery contract and stops
  a no-progress loop with its blocker.
- [ ] M4: Rehearsals and interpreter failure/compatibility cases cover no-op, changed, stuck and
  interrupted rollouts; artifact-ready latency evidence is ready for EP-224's intranet confirmation.


## Surprises & Discoveries


2026-10-29: `Commands/Transition.hs` delegates to bootstrap stage selection.
`Bootstrap/Sequence.hs` reloads the target snapshot and reconsiders cloud/host/platform stages on
each invocation. `release-intranet.sh` infers convergence from operations and non-stamp revision
movement and scrapes text for an ambiguous transaction ID. It automatically resumes once.
`runPlatformTransitionCommit` validates one head, writes the context pin, then locks and reads
another head before clearing the marker without repeating the full refusal check under that lock.
The pin/marker crash interval and concurrent admission therefore need explicit finalization tests.

`scripts/release-rehearse.sh` uses embedded Python for record and version checks and invokes
`scripts/transition-rehearsal.sh`. Adding trace shaping to those scripts would extend the existing
second implementation rather than enforce the Haskell tooling architecture.


## Decision Log


- 2026-10-29: Share pure composition and adapter behavior with bootstrap, but make rollout phases
  and impact explicit. Do not build a second set of provider mutation commands.
- 2026-10-29: Use one mutation-authority coordinator and at most four independent stateless
  effects awaiting readiness. Submission/receipt persistence is ordered; readiness may overlap.
  Do not blanket-parallelize arbitrary adapters.
- 2026-10-29: Port the release orchestration being extended to Haskell before adding cost/progress
  features. Remove embedded and transitively invoked transition-specific Python from that path.
  Later the same day the port became [EP-229](229-own-candidate-intranet-and-rehearsal-orchestration-in-haskell.md);
  this plan's M3 extends the ported runner and depends on it.
- 2026-10-29: Treat pin/marker finalization as a recoverable protocol; a filesystem pin and a remote
  head cannot be made atomic by a local lock or an optimistic second read.


## Outcomes & Retrospective


Planning only; existing rollout scripts and finalization behavior remain unchanged.


## Context and Orientation


`cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs` implements platform transition plan/commit.
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs` selects the next pending bootstrap stage;
`Bootstrap/Host.hs` builds host/kubeconfig changes; `Bootstrap/Platform.hs` compiles cluster scopes.
`cli/nagarectl/src/Nagare/Platform/Transition.hs` guards release pairs and transition ownership.
`cli/nagarectl/src/Nagare/Inventory/OperationStep.hs` selects operations from dependency state;
`Execute/Driver.hs` currently runs them one at a time, including readiness handling.

The dependency graph contains operations and the edges that require another operation's proof
before starting. A readiness barrier is a point that cannot complete until specified resources
prove their required health. A phase groups work with the same observation freshness and safety
boundary. Durable intent is a committed record that a provider effect may begin; a receipt proves
its outcome. Timeout or cancellation after submission is potentially ambiguous, not known-no-effect.

`cli/nagare-harness/app/Main.hs` is the maintainer CLI. `scripts/release-candidate.sh`,
`scripts/release-intranet.sh`, `scripts/release-rehearse.sh` and
`scripts/transition-rehearsal.sh` currently coordinate release/transition execution; EP-229 ports
them to `cli/nagare-harness/src/Nagare/Harness/Release/`, and this plan extends that port. The public
recipes are `just release-candidate` and `just release-rehearse`; `release-intranet.sh` is run by
`release-candidate.sh` or directly by the operator, and `transition-rehearsal.sh` by
`release-rehearse.sh`. `docs/runbooks/releases.md` describes operator use.
[ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
requires typed Haskell tools outside the payload. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires the final context pin to follow convergence. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
preserves self-reverting host activation. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md),
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
govern guarded writes, authoritative journal and exact recovery identities.


## Plan of Work


### M1 — Compile an explicit transition and close it safely


Add `cli/nagarectl/src/Nagare/Platform/Rollout.hs` for typed phase selection and impact summaries.
Reuse bootstrap compilers, EP-225's stable scope revisions and the current inventory command
context. Compute a content-addressed preparation manifest with per-component entries keyed by
deployment-significant payload content, consumed context inputs and adapter/tool identities.
Record the accepted-head binding separately for review admission; an unrelated head generation
must not invalidate every component's prepared artifact. Prepare needed Nix artifacts, image
publications and rendered chart/manifests once before the activation clock. A cache hit verifies
its complete inputs/digests; a changed consumed config, secret version, native input or tool
invalidates the affected entry and its dependent entries. Do not cache
live health across commands or retain plaintext secrets in public artifacts.

Distinguish unchanged deployment content, host-only change, cluster workload change, policy-only
change and a genuine migration. Preserve ordinary stage boundaries where cloud output, host
activation or kubeconfig change affects later inputs. Reopen live observation after those changes.
Reuse the loaded immutable inventory within a command, but conditionally recheck authoritative
state at admission and finalization. A new stage may reference prior prepared inputs by digest;
it must not silently apply against the previous stage's old head. Human and machine output show
why each scope/phase is selected and what remains. No-op replan means no required effects,
re-acceptances or incomplete validation, not simply an empty operations array.

Add a recoverable finalization record binding source/target payload, accepted/converged scope
vector, marker identity and intended context pin. Under the writer claim, re-observe and validate
the head and all finalization prerequisites; conditionally establish finalization ownership before
changing the local pin. Block conflicting admission while finalization is open. Write the context
file atomically, then close the transition with a conditional head update bound to the same record.
On restart, matching old/new pin and recorded intent determine a safe retry; a foreign pin or
changed scope vector refuses. Commit invoked after pin-write/before-marker-close must finish,
not become stuck on “already at target.” Never overwrite an unrelated transition or claim.
Version new head metadata explicitly if older writers would ignore it; EP-227's admission contract
must carry that incompatibility before any write. Keep host self-reversion and data rollback policy.

Test one unchanged scope and one changed Deployment through actual compile, saved review, apply,
interruption, replan and commit before adding other executor variants. Inject concurrent admission
between status gathering and lock acquisition, and crashes before/after finalization intent,
pin replacement and marker closure. No test may pass with the new pin and unrelated incomplete work.

### M2 — Overlap safe readiness without losing transaction authority


Extend the operation-step/driver contract with explicit adapter scheduling capabilities. The
default is exclusive. Initially opt in only stateless Kubernetes creates/updates whose exact
addresses, dependency closure and ownership are disjoint and whose recovery semantics are covered
by the fake API server. Namespace/CRD/controller establishment, Helm, host, Pulumi, replacement,
retirement, adoption, transfer, migrations and data-fenced operations remain barriers/exclusive.

Keep one coordinator for mutation intents and receipts through EP-227. Submit each ready effect
only after its intent commits. Once submission outcome and physical identity are durable, the
coordinator may submit another independent effect while the first awaits readiness. At most four
effects are outstanding. Workers observe readiness and send results; they never advance the head.
A dependent operation waits for completed proof, not merely API acceptance. Unknown submission
outcomes stop new submissions until reconciled; independent in-flight outcomes are collected and
journaled without guessing. Resume recovers each outstanding identity before new work.

Use EP-226's bounded read epochs for readiness and cancel them by deadline. Default readiness
deadline is 180 seconds per stateless workload and an overall rollout deadline of 600 seconds;
reviewed host/data operations can declare an explicit longer deadline with a visible reason.
Provider-request timeouts do not replace command/process deadlines. Stop spawning new work on
failure or user cancellation, account for all admitted in-flight effects, persist the stop and
print the transaction/recovery command. Progress updates at least every five seconds name phase,
completed/pending counts, current wait and elapsed/deadline, never secrets. A deadline failure
leaves the source release pin and enough evidence to resume or close.

Add `cli/nagarectl/test/PlatformRolloutSpec.hs`. With an injected clock, four independent
resources each ready after 30 seconds should finish the readiness interval near 30 seconds plus
bounded submissions, not 120 seconds. A four-node dependency chain must remain sequential.
Add shared-address, CRD/custom-resource, host/kubeconfig and data-fence examples that forbid
overlap. Preserve the existing single-operation path and benchmark application deploy as a
consumer of the same scheduler, so the root fix benefits developer changes as well as releases.

### M3 — Extend the ported runner with durable progress and cost


Starting from EP-229's Haskell runner under `cli/nagare-harness/src/Nagare/Harness/Release/`,
extend its versioned run index with the preparation manifest from M1, stage/review/transaction
IDs, attempt status and relative trace paths. Repeated stage requests reuse only immutable
prepared material after verification. A stopped apply resumes only when the existing recovery
contract permits it; avoid a blanket retry policy. A no-progress loop stops when its head, desired
vector and unresolved requirements repeat, with the concrete blocker, rather than exhausting
twelve indistinguishable stages. Progress output follows the M2 cadence for every attempt.

Call EP-224's cost collector on success and failure. Bind evidence to exact candidate revision,
source release, context profile and artifact identities. Run files survive interruption; final
record publication is atomic and never overwrites a prior passing result with a partial run.
Keep EP-229's command grammar and wrapper interfaces unchanged; when run index fields change,
bump its version explicitly and keep EP-224's collector reading every version it supports.

### M4 — Confirm the integrated release path


Run the production-interpreter matrix for unchanged platform, one stateless update, four
independent updates, dependency chain, host-only transition, Helm change and stopped readiness.
Add host and Helm command-boundary fake transports sufficient to exercise phase invalidation and
interruption; do not claim nonexistent full provider worlds. Confirm those boundaries in the
disposable native rehearsal and host integration environment before production use. The release
candidate must preserve workload/data sentinels and leave the expected pin/marker after resume.

Exercise candidate/intranet behavior through fake process transports and the real local
rehearsal; live intranet timing is EP-224 M3 and the Python-free proof is EP-229 M3. Record cold
preparation and warm activation separately without omitting the total. Update the release runbook,
help and ADRs 6/11/22 where the resulting contract changes.


## Concrete Steps


From the repository root, after adding and registering the named tests:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p PlatformRollout' --test-show-details=direct
cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-options='-p ReleaseTransition' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p TransitionCost' --test-show-details=direct
just haskell-style-check
just gate-fast <committed-candidate-revision>
just release-rehearse <candidate-revision> <previous-version>
```

The fake tests require no cloud writes and must select nonzero test groups. The last command uses
the existing public recipe, migrated internally to Haskell, in its documented disposable Colima
context. It must produce the normal transition rehearsal record plus typed run/cost evidence and
preserve the source sentinel. Normal release gating and operator-approved release procedures
govern the subsequent intranet run; this plan revision itself does not perform a rollout.


## Validation and Acceptance


M1 requires the representative production path and all pin/marker race windows. M2 requires
measured overlap for independent updates, strict ordering for dependent/exclusive work, bounded
wait/cancellation and recovery of every in-flight effect. M3 requires the versioned run index,
repeatable progress and cost records on success and failure, bounded resume and the no-progress
stop. M4 requires
compatibility and rehearsal proof for changed/no-op/host/Helm/stuck cases. The final performance
gate remains EP-224 M3; this child's completion cannot be reported as achieving intranet latency.


## Idempotence and Recovery


Run attempts are append-only records with stable review/transaction references. Restart never
reuses a live epoch or blindly replays a provider request. Prepared artifacts can be reused after
digest validation; mutation completion requires journal and provider proof. Finalization ownership
survives the local-pin/remote-marker crash interval and is resumed conditionally. A failed host
activation uses the existing self-reversion; data migrations retain explicit forward recovery.
Cancellation is not rollback. Old supported review and transaction formats remain executable
under their original serial semantics, or fail before mutation with an explicit compatibility error.


## Interfaces and Dependencies


Hard prerequisites are Complete [EP-225](225-keep-platform-revisions-stable-when-deployment-meaning-is-unchanged.md),
[EP-226](226-share-bounded-cluster-observations-through-a-guarded-command-session.md),
[EP-227](227-commit-verification-proofs-without-per-resource-remote-transactions.md),
[EP-229](229-own-candidate-intranet-and-rehearsal-orchestration-in-haskell.md) and
[EP-224 M2](224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md).
This plan owns rollout phase selection, scheduler integration, finalization metadata and the run
index, manifest, progress and cost extensions of the release runner. It consumes the shared trace,
semantic comparison, epoch, append and runner contracts without redefining them. Resolve dependency sources with Mori before using new APIs and verify
registry/upstream releases before choosing bounds. No new provider, database or daemon is assumed.
