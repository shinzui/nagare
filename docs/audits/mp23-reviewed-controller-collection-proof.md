# MP-23: reviewed controller collection, local proof

Date: 2026-10-02. Baseline: `5c2d6d7e`. Implementation owner: [EP-153](../plans/153-close-managed-command-coverage-for-the-inventory-release.md). Native agreement: [EP-156](../plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md).

## Outcome and contract

`inventory collect --controller-descendants` now prepares an explicit Background
collection review for one retained Knative Service. The distinct adapter identity
`kubernetes-reviewed-controller-collection` prevents an ordinary adapter from
executing that review. Existing reviews keep their Orphan semantics. No cloud
operation or installed-candidate change was made.

[Authority](../../cli/nagarectl/src/Nagare/Inventory/Collection/Authority.hs),
[observation](../../cli/nagarectl/src/Nagare/Inventory/Collection/Runtime.hs) and
[execution](../../cli/nagarectl/src/Nagare/Inventory/Collection/Adapter.hs) have
separate responsibilities. Planning discovers all listable namespaced APIs and
requires successful, complete namespace lists. It retains metadata only, binds
the exact parent UID/resourceVersion, accepts a finite supported set of exclusive
controller descendants, and rejects shared, non-controller or independently
inventoried children. Independently inventoried objects outside that graph are
protected by saved identity/ownership evidence. Unrelated unowned ephemeral
objects are not frozen by the review.

Preflight repeats discovery and checks the parent, descendant graph and protected
objects. Descendant/protected status-only resourceVersion changes do not invalidate
the review. The only write is a parent UID/resourceVersion-conditional Background
DELETE. No child is deleted directly and no finalizer is patched. An uncertain
reply or incomplete cleanup retains the original transaction for recovery.
Parent absence alone cannot write the collection tombstone: recorded descendant
addresses/UIDs must also be absent, newly observed descendants reachable from
saved UIDs must be absent, and protected identities/ownership must still match.

## What the grant does and does not guarantee

The public summary explicitly grants Background garbage collection of exclusive
controller descendants, including later-created descendants. The observed graph
is evidence, **not an atomic exact-UID deletion set**. Kubernetes only conditions
the parent DELETE; it does not atomically fence descendant creation or changes to
owner references. Background GC can affect an object attached after preflight.
This contract assumes trusted supported controllers and namespace writers; it
does not sandbox garbage collection against hostile ownership changes.

Namespace lists are also not a cross-resource snapshot. Recovery detects saved
members and newly observed reachable descendants, but cannot prove absence of an
unobserved new chain whose intermediate owner disappeared before observation.
Provider/controller agreement remains necessary. If the required product
contract becomes an exact immutable descendant set or protection against arbitrary
concurrent ownership changes, this implementation is insufficient; that requires
a different coordination/deletion protocol.

The contract follows Kubernetes [garbage-collection semantics](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
and the DeleteOptions/ownerReferences definitions in
`mori://codedownio/kubernetes-api/packages/kubernetes-api-1.35`. It is not a
reinterpretation of inventory field-reconciliation `Delegation`.

## Executable evidence

[Eleven new scenarios](../../cli/nagarectl/test/InventoryControllerCollectionSpec.hs)
exercise the production planner, immutable review, filesystem journal and adapter
through the existing Effectful request interpreter. They cover parent absence
with surviving descendants, partial cleanup, lost acknowledgement, fresh-process
recovery, owner changes, a new child before deletion, protected UID changes before
and after deletion, incomplete listing, independently managed children, ordinary
adapter rejection, a newly observed child after deletion, and permitted status
version churn. Several assertions share a scenario. Recovery converges only after
modeled cleanup, with the original review/tombstone and exactly one DELETE attempt.

The public CLI fixture separately runs planning, apply and resume as real
subprocesses with strict local kubectl shims. Parent deletion leaves children
present, the first resume stays unresolved, and a later resume converges after an
explicit modeled GC event. Both resumes issue no DELETE. Retained data and
neighbor identities survive. This also tests public adapter selection and saved
review reconstruction, which the focused fixture's bounded registry does not.

```bash
just test-inventory-effects
cabal test nagarectl-test --project-dir=cli/nagarectl --test-show-details=failures
python3 scripts/test-web-cleanup-public.py --knative --retain-data
python3 scripts/test-web-cleanup-public.py --knative --retain-data --expect-orphan-block
bash scripts/check-haskell-style.sh
python3 scripts/check-cli-architecture.py
```

The combined interpreter suite passes 25 tests in 3.79 seconds, excluding
compilation. The full suite passes 1,042 tests in 112.46 seconds in this run
(other local build/test processes were running concurrently). Both public CLI
variants pass. The executable and test suite build; Fourmolu, Cabal formatting,
structural Haskell style and CLI architecture pass. The broad Haskell architecture
gate still rejects the two unchanged oversized test files, `AppDeploySpec.hs`
(2,496 against 2,491) and `InventoryKubernetesSpec.hs` (4,235 against 3,851).
Consequently the aggregate managed-command audit stops at that existing gate;
no limits were raised. The direct command-registration audit passes after adding
the prior checkpoint's `test-inventory-effects` recipe to its registry.

## Remaining acceptance

F20 remains Open for native agreement and independent verification. Models do
not execute admission, Knative controllers or Kubernetes GC. Next, compare the
discovered graph and request/response shapes against the supported native versions,
then use one newly issued disposable collection review to prove actual descendant
cleanup, unchanged retained data and original-transaction recovery. Measure the
complete discovery/list cost separately from DELETE/finalization. On a mismatch,
capture and reproduce that boundary locally before another installed attempt.

The frozen `4c4b667e` candidate and old generation-752/sequence-673 transaction
remain untouched. Its separately proposed cascade exception still requires its
existing operator approval; this new review format cannot authorize or execute
that exception retrospectively. No native/release gate closes here.
