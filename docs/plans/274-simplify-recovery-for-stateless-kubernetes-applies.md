---
id: 274
slug: simplify-recovery-for-stateless-kubernetes-applies
title: "Simplify recovery for stateless Kubernetes applies"
kind: exec-plan
created_at: 2026-11-21T05:53:08Z
master_plan: "docs/masterplans/37-make-releases-routine-by-deleting-what-nagare-does-not-need.md"
provenance:
  created_by:
    model: "gpt-6.2-astra"
    harness: "codex-cli"
    at: 2026-11-21T05:53:08Z
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T05:58:44Z
      mode: "update"
      note: "Applied the parent review to D2 with whole-review eligibility, mixed-scope verification and two-client acceptance."
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T05:59:18Z
      verdict: "comments"
      note: "Author self-review against admission, driver, object-store and lifecycle paths. D2a is actionable. D2b depends on two releases, ledger dispositions and proof under overlapping writers."
---

# Simplify recovery for stateless Kubernetes applies

## Purpose / Big Picture

A slow Deployment rollout should be able to become Ready and finish the original review. Later, an
engineer whose ordinary stateless apply stops should be able to plan again while a colleague applies an
unrelated change in the same context. This plan has two releases of observation between the readiness fix
(D2a) and the change to the transaction contract (D2b).


## Progress

- [ ] D2a. A slow owned Deployment update finishes on readiness without a second write. A healthy
  unchanged stateless scope can recover convergence without one journal operation per member. A strict or
  mixed scope still requires its evidence.
- [ ] Release gate. Record two real releases running D2a, with their revisions, stateless rollout
  outcomes, and successful seeded-row rehearsal records. Record the disposition of the stateless findings
  before starting D2b.
- [ ] D2b. Two independent store clients demonstrate interruption, unrelated apply and safe replan. The
  review-level audit, concurrent-writer cases, lifecycle facts, existing transaction recovery and
  strict-path tests pass.


## Surprises & Discoveries

The Kubernetes adapter maps a matching Ready, NotReady or Failed object to the same planner result,
`ObservedPresent`. The executor's `continueReadiness` also returns `StoppedAmbiguous` when the waiting
operation is an update. Removing the adapter's Knative check alone would leave the original symptom in the
driver.


## Decision Log

2026-11-20. Choose the lighter execution path once for a whole eligible review. An eligible member inside
a mixed review follows the journalled execution of that review. This preserves dependency order, existing
data fences and one meaning for a completed review.

2026-11-20. Keep the persisted converged revision for consumers that need the last successful release.
Change the evidence that can advance it for an eligible scope. The lifecycle producer compares the
previous converged revision with the new one to identify a deployment or rollback.


## Outcomes & Retrospective

Implementation and the two release observations are pending.


## Context and Orientation

A review binds an actor, desired scope revisions, observed resources and permitted operations to one store
head. A scope groups resource declarations. The accepted revision says what Nagare is trying to install.
The converged revision says what finished. Admission currently advances accepted revisions and installs an
active transaction and executor claim in one conditional head write. A claim identifies the client
authorized to continue the transaction. An unresolved transaction blocks future admission for that
context.

Start in [Transaction.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs),
[Admission.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs) and
[Claims.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Claims.hs). The process lock is local to a
client on remote object stores. Conditional replacement of the observed head is the cross-machine
authority. A Kubernetes object has a physical UID, a resource version used for conditional writes, and
Nagare stamps identifying its owner and desired spec.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) separates desired
meaning, live health and mutation authority.
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) defines close for a stopped
transaction.
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
binds a write to the observed object.
[ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md) requires admission
to enforce the deployer's grant.
[ADR 39](../adr/0039-lifecycle-sources-are-committed-by-the-converged-release.md) makes a successful
release the source of deployment events. The D2b exception must preserve these consumers and the pin-last
transition in [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md).


## Plan of Work

### D2a. Recover the landed update and verify only what needs proof

Start with the v0.24.1 shape in
[InventoryKubernetesRecoverySpec.hs](../../cli/nagarectl/test/InventoryKubernetesRecoverySpec.hs). Prepare
a Deployment update, return a timeout after its write lands, observe the reviewed UID, owner and new
digest while NotReady, then make it Ready. In
[Kubernetes.hs](../../cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs) recognize only the
eligible update after the existing exact-object and digest checks. In
[Driver.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs) and
[Recovery.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Recovery.hs) handle the bounded wait and
subsequent resume. Exercise the public apply/resume path. Expect one mutation, a distinct waiting outcome
if the time budget expires, and completion when Ready. A changed UID, owner or another writer's digest
must still refuse. Dependents wait until their prerequisite is Ready.

In [Changes.hs](../../cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs) narrow the branch that emits
`VerifyResource` for every unchanged member of an unconverged scope. Consider a scope for lighter proof
only if all its managed members meet the stateless kind and policy boundary below, and all required
operations and health checks are accounted for. Use the existing review validations and fresh admission
observation for members removed from the operation list. Supply fresh positive health evidence for
readiness-bearing kinds. A matching digest on a failed or unready Deployment cannot advance convergence.
Keep missing or foreign objects, failed observations and drift visible. Preserve bootstrap validations and
required-topic verification.

Use the result for that selected scope in `reverifiedScopes` and conditional claim release. Keep the
strict proof for a scope containing a durable or otherwise excluded resource.
[Transition.hs](../../cli/nagarectl/src/Nagare/Platform/Transition.hs) and the release harness must still
refuse to commit an unproved moved scope. Keep artifact verification from commit `4fe9b48b` wherever the
artifact executor can still receive `VerifyResource`. Test a stopped mixed scope containing an artifact
and an ineligible Kubernetes member, an all-eligible scope and a second untouched scope. Only a freshly
proved selected scope advances; the resulting replan has no redundant operations.

### Release observation and ledger decision

Identify the two D2a release records and the actual stateless operations observed. A CLI-only release with
zero operations provides no rollout evidence. Confirm the rehearsal's seeded and read-back values match.
Retain the specific slow-update regression even when both releases were uneventful. Consult
[the findings ledger](../audits/mp23-findings.md), especially F37, F56, F64, F73 and F130. F73 already
describes an unready Knative update wrongly attributed to the review. For each affected guarantee record
whether the instance is excluded, covered by the new path or deliberately relinquished under the
operator's stated scope. Capture the decision here before D5 retires the ledger.

### D2b. Admit and audit an eligible review once

At the normal apply entry point reuse the existing context, stale-head, base, ownership, delegation,
transition, fence and active-transaction checks. Derive eligibility from the reviewed operations and
declarations.
[KubernetesApplication.hs](../../cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesApplication.hs)
admits a single-resource Kubernetes create or update of a stateless Deployment, Knative Service, Service,
ConfigMap or Secret for overlapping readiness. Require that shape for every mutation. Exclude credentials,
protected data operations, special recovery actions, adoption, takeover, retirement, replacements and
changes affecting data fences or strict dependencies. Verify the complete review including scope changes
and required validations. If eligibility or credential provenance cannot be determined, run the existing
strict path for the entire review. A transaction already admitted always uses the protocol recorded for
it.

Prove the review-level admission and retry on the object-store interpreter before enabling it in
production. Use one conditional admission against the reviewed head to record the actor, review digest and
accepted intent. Keep audit attribution distinct from a claim of successful rollout. An eligible
interruption must leave no persistent context-wide active transaction. Apply in dependency order with
conditional creates and updates bound to the reviewed owner and object. Reuse the strict Kubernetes
writer's UID/resource-version protection at the actual write. Avoid forcing foreign fields. A partial
apply is retried by freshly planning the same desired configuration against the current head and live
objects. Reapplying a stale saved review must refuse.

Inject process loss immediately before and after each provider write and before convergence. Use separate
clients sharing one conditional store. Interleave a second, overlapping review after the first client has
validated but before its provider write, including when the second client observes no change. Prove the
older client cannot overwrite a newer accepted decision or write a foreign object. A local lock or a head
read followed by an unconditional provider write cannot prove this. Treat this as the bounded design
experiment for D2b. If the existing preconditions cannot establish that ordering, retain the D2a
implementation, record the failing interleaving and revisit the execution design before switching
admission. Do not delete the working recovery path on the strength of a serial test.

Complete an eligible apply only after fresh health and a conditional store commit that preserves any
unrelated changes since admission. Reuse
[Sources.hs](../../cli/nagarectl/src/Nagare/Inventory/Execute/Sources.hs) and the committed lifecycle-fact
semantics. An interrupted apply emits no success fact, a successful deploy or rollback emits its expected
fact once and the consumer can resume from its checkpoint. If release facts cannot yet be produced safely
for a class of review, keep that class strict. Preserve supported old transactions and older-reader
refusal for any new persisted representation. Remove stateless-only stop states, replay rules and tests
after demonstrating these exits. Retain shared constructors and recovery evidence required by strict
callers. Report actual source and test deltas against the master plan's estimates.


## Concrete Steps

From the repository root use the existing development shell and test suites. The first command exercises
the adapter cases during development. Run the full relevant suites for each accepted milestone.

```bash
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p recovery' --test-show-details=direct
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-show-details=direct
nix develop -c cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-show-details=direct
```

Extend the existing inventory close, application update recovery, artifact, lifecycle and transition tests
around the real planner and driver. Use
[the remote-store test world](../../cli/nagarectl/test/Nagare/Test/World/ObjectStore.hs) for distinct
clients. For the release observations, use the candidate and intranet records for two authorized releases
under the repository's [release runbook](../runbooks/releases.md).


## Validation and Acceptance

For D2a, demonstrate the slow Deployment, foreign-write refusal, mixed scope and healthy all-stateless
replan through the normal planner and executor. The release transition must refuse a failed workload even
when its stamp matches. Record the release tags and results separately from suite success.

For D2b use two deployers on the same test context, with unrelated declared applications A and B. Save and
apply A's review, interrupt it after the first conditional write, and then have B plan against the
advanced head and apply its review. B succeeds without taking over or closing A. Replan A and finish it.
Verify both final deployments, actor/review attribution, event delivery, and the absence of a global
active transaction after the stop. Repeat with a stale B review, a revoked delegation, a replaced UID, a
conflicting live writer and a mixed Deployment/PVC review. Each must produce the prescribed refusal or
strict recovery behavior, even when the clients have independent process locks.


## Idempotence and Recovery

Run the two-client case with each engineer's own CLI, credentials, app configuration and empty review
directory, both pointing at the same disposable context. Use two ordinary changes known to produce only
eligible operations. From each application checkout, set `CONTEXT`, `CONFIG` and `REVIEW` to that
engineer's test inputs and run these commands.

```bash
nagarectl --context "$CONTEXT" app deploy -f "$CONFIG" --save-plan "$REVIEW"
nagarectl --context "$CONTEXT" inventory apply "$REVIEW" --yes
nagarectl --context "$CONTEXT" inventory store status --json
```

After A's interrupted write, B's fresh plan and apply must succeed and the shared head must report no
active transaction. Repeat A's planning command into a fresh directory to reconcile the partial change.
Use interpreter fault injection to reproduce exact crash points before repeating the interaction on the
disposable context.

Keep D2a independently releasable. Restart an existing journalled transaction by its original ID with its
supported resume or close command. On the new path replan after a stop and reuse observed effects. Never
infer completion from admission, elapsed time, or a matching stamp alone. Exercise interruption and retry
from stores created by the previous supported release before removing a decoder or a settlement case.


## Interfaces and Dependencies

D2a has no implementation dependency on D1 or D3. Its release observations may use the existing pipeline
or the revised one. D2b starts only after both D2a releases and the ledger decision. D1 owns
installed-content identity, D3 owns the rehearsal and public release record, and this plan owns the
convergence result they consume. D4 must check shared recovery callers with this plan before deleting
their adapters. D5 may archive the findings ledger after this plan records its decision.
