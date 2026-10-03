# MP-23: local F20 collection and recovery proof

Date: 2026-10-02. Baseline: `f6ccc2ab`. Owner: [EP-153](../../plans/153-close-managed-command-coverage-for-the-inventory-release.md); native agreement: [EP-156](../../plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md).

## Outcome

The next interpreter checkpoint is complete: eight local collection scenarios pass through the existing production planner, lifecycle decisions, immutable review, filesystem journal, Kubernetes adapter/runtime and Effectful request boundary. Together with the six restore scenarios, `just test-inventory-effects` passes 14 tests in 2.55 seconds. No production deletion behavior changes and no cloud operation occurs.

The important result is that F20 can now be exercised cheaply: DELETE acceptance with a blocked orphan finalizer remains unresolved, including after fresh-process recovery. A successful wait response alone cannot establish collection. The parent is not deleted twice; descendants and protected data are preserved. This is a regression proof of safe pending/recovery behavior, **not a fix or closure of F20**.

## Scenario and assertions

[The fixture](../../../cli/nagarectl/test/Nagare/Test/Effectful/CollectionFixture.hs) seeds an accepted Knative Service and three data members in the same application scope (StatefulSet, durable PVC, completed backup Job), plus an independent neighboring Service. It represents the checkpoint after release-history and DomainMapping collection. Production retirement retains the four application members without deletion. Production collection then reviews only the exact parent, which declares no descendant delegation.

[The persistent model](../../../cli/nagarectl/test/Nagare/Test/Effectful/CollectionModel.hs) accepts only the expected request shapes. The DELETE must contain the exact parent path, UID, resourceVersion and `Orphan` propagation policy. Acceptance changes the parent resourceVersion, adds a deletion timestamp and orphan finalizer, and preserves all child objects. Five representative Route/Configuration/Revision/Deployment/Pod nodes retain direct and transitive owner references; they are not a reproduction of all sixteen native descendants. A virtual 30-second wait returns immediately with a timeout while the parent remains present.

[The tests](../../../cli/nagarectl/test/InventoryEffectfulCollectionSpec.hs) cover:

- Accepted DELETE with blocked finalization: retained identities, accepted neighboring revisions and the original active transaction survive; no tombstone appears early.
- Lost DELETE acknowledgement: a fresh process observes the pending parent without issuing another DELETE.
- Failure before DELETE: recovery safely sends the original conditional request once.
- A dishonest successful wait response: final observation still prevents convergence while the parent exists.
- Replacement parent after interruption: its UID/native object is preserved; recovery stays unresolved.
- UID and resourceVersion races between observation and write: provider-side preconditions refuse the deletion; recovery does not retry with rewritten preconditions.
- An immediate-deletion counterfactual: the old simplistic model converges, but the shared pending-state assertion rejects it. This demonstrates why an immediate-success fixture cannot represent F20; it is not a mutation test of Kubernetes itself.

For eventual completion, an explicit external model event permits lawful orphaning. Only the direct parent owner references detach; child objects, labels, UIDs and transitive relationships survive. The original transaction then converges from its saved review in another OS process and records the original parent UID/review in its tombstone. Replaying the converged transaction performs no second DELETE. Data objects and their retained incarnation records remain exact throughout.

The fresh process reconstructs the parent from the review's historical scope revision and content-addressed native bytes. This bounded test loader is not the full public CLI adapter factory. Initial history is synthetic accepted evidence, not a claim that native resources were created. Fault injection models interruption at the request boundary; these tests do not send SIGKILL to an actual cloud command.

## Validation and limits

```bash
just test-inventory-effects
cabal test nagarectl-test --project-dir=cli/nagarectl --test-show-details=failures
python3 scripts/test-web-cleanup-public.py --knative --retain-data --expect-orphan-block
scripts/check-haskell-style.sh
python3 scripts/check-cli-architecture.py
```

The focused suite passes all 14 tests in 2.55 seconds. The full suite passes all 1,031 tests in 49.96 seconds; the final additional DELETE-attempt assertions are rechecked in the focused suite. The existing public CLI fixture also passes through the real subprocess interpreter and strict local kubectl shim, covering ordered history/route collection and the pending Service boundary. It does not contact Kubernetes. Haskell structural style and CLI architecture pass. The broad Haskell architecture check retains its two pre-existing test-file size failures; no limits are raised.

This proves the modeled safety and recovery contract. It does not execute Knative admission or garbage collection, establish native completion, authorize cascade, patch a finalizer, or repair the frozen transaction. The external model completion event assumes orphaning has become possible; that assumption is false at the currently documented live F20 boundary. Real component agreement and explicit reviewed descendant authority remain necessary for a supported cascade solution.

The next work is to define and implement review-bound descendant deletion authority for future supported Knative collection, using this fixture to prevent implicit broadening from Orphan to Background. Preserve the installed `4c4b667e` candidate and original pending transaction. The separate native exception still requires its existing operator approval.
