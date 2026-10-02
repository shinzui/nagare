# MP-23: reviewed controller collection, local and native proof

Date: 2026-10-02. Baseline: `5c2d6d7e`. Implementation owner: [EP-153](../plans/153-close-managed-command-coverage-for-the-inventory-release.md). Native agreement: [EP-156](../plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md).

## Outcome and contract

`inventory collect --controller-descendants` now prepares an explicit Background
collection review for one retained Knative Service. The distinct adapter identity
`kubernetes-reviewed-controller-collection` prevents an ordinary adapter from
executing that review. Existing reviews keep their Orphan semantics. The initial
checkpoint was local only; the bounded native continuation below now proves the
new review on a separate disposable application, preserving frozen F15.

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

## Recorded native graph agreement (2026-10-02)

[EP-156](../plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md)
now validates the existing interpreter against the frozen
[Knative recording](mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json)
from `v1.35.8+k3s1`: sixteen descendants and seventy-five discovered namespaced
listable APIs. The original exception proposal is unchanged and remains
`awaiting-operator-approval`, with `providerMutationPerformed: false`.

The [derived fixture](../../cli/nagarectl/test/fixtures/inventory/knative-collection-native.json)
copies the complete API list and all sixteen recorded kind/API-version, name,
namespace, UID and owner-reference records, with the source SHA-256. Run
`python3 scripts/knative-collection-fixture.py --check` to detect drift against the
recording; omit `--check` only to regenerate the derived test file. The script
never modifies evidence or contacts a provider.

The recording contains metadata summaries, not complete raw responses. The test
wraps those summaries in Kubernetes object/list envelopes, supplies synthetic
resource versions, and rebases only the two root owner references to the existing
isolated `web` / `web-uid` parent. It preserves every descendant UID and transitive
edge, including the two EndpointSlice paths, ReplicaSet, Image, Ingress, Metric,
PodAutoscaler and ServerlessService. The recording contains no Pod descendant;
Pod behavior remains covered by the existing synthetic graph. Other API lists are
modeled empty except for the existing four protected fixture objects and a
synthetic ownerless PodMetrics response. These fixtures do not claim to replay
all native namespace contents or the nine native protected database members.
PodMetrics uses the standard timestamp/window/container shape described in the
[Kubernetes metrics documentation](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/).
List metadata and owner-reference interpretation were also checked in
`mori://codedownio/kubernetes-api/packages/kubernetes-api-1.35`; no dependency
bounds or versions changed.

[Eighteen production-path scenarios](../../cli/nagarectl/test/InventoryNativeCollectionSpec.hs)
reuse `collectionRequest`, `runKubectlWith`, the production planner/adapter and
filesystem journal, including the existing fresh-process resume probe. They
assert saved authority contains exactly sixteen descendant UIDs and all
seventy-five APIs; shared, non-controller, independently inventoried, unsupported
and cross-namespace descendants refuse review; partial discovery output with a
failed exit, one forbidden list, continuation tokens and malformed list metadata
cannot publish authority; changed discovery, ownership and unexpected descendants
refuse before DELETE. Recovery refuses incomplete discovery, newly reachable
transitive descendants and protected ownership drift. Two surviving deep
EndpointSlices keep the original transaction pending even after intermediate
owners disappear. Only explicit modeled cleanup permits its original tombstone;
protected objects stay byte-for-byte equal and completed replay makes no calls.

The tests demonstrated one production mismatch: an ownerless retained PVC with
missing UID metadata was silently discarded by the generic projection exception,
and the planner published an incomplete protected-object review. That regression
failed before the fix. `parseCollectionNode` now permits UID omission only for
ownerless, uninventoried `PodMetrics` from `pods.metrics.k8s.io`; incomplete
persisted or owned objects refuse. The sixteen recorded descendant kinds/edges
already fit the existing finite policy, so no controller authority was broadened.

The tests enforce these exact request budgets, with the complete API-list multiset
checked on every scan, including empty APIs:

| Phase | Discovery calls | Namespace lists | Parent GETs | DELETE | Wait | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Prepare/publish collection review | 1 | 75 | 2 | 0 | 0 | 78 |
| Apply, accepted parent DELETE with descendants pending | 3 | 225 | 3 | 1 | 1 | 233 |
| Each pending/partial/final-cleanup resume | 1 | 75 | 2 | 0 | 0 | 78 |
| Already completed transaction replay | 0 | 0 | 0 | 0 | 0 | 0 |

The three apply scans are admission preflight, execution preflight and completion
verification. These are calls at the kubectl interpreter boundary, not counts of
HTTP requests made internally by kubectl discovery or pagination. Native elapsed
time and actual controller/GC cost remain unmeasured by this fixture. Failed
preparation is bounded at 78 calls (three for failed API discovery); refused
preflight and unresolved recovery are also bounded at 78. There is exactly one
parent UID/resourceVersion-conditional Background DELETE across the successful
review/recovery lifecycle, no child DELETE, no finalizer patch and no cloud call.

```bash
python3 scripts/knative-collection-fixture.py --check
just test-inventory-effects
cabal test nagarectl-test --project-dir=cli/nagarectl --test-show-details=failures
```

The focused suite passes all 43 interpreter tests in 6.92 seconds, excluding
compilation; the full CLI suite passes all 1,060 tests in 54.70 seconds. The
executable builds and both public Knative CLI variants pass again with local
subprocess shims, including old-review Orphan behavior. Fixture
consistency, Fourmolu, Cabal formatting, structural Haskell style and CLI
architecture pass. The broad Haskell architecture gate still rejects the same
unchanged `AppDeploySpec.hs` and `InventoryKubernetesSpec.hs` line limits recorded
above. The existing `just test-inventory-effects` entrypoint now checks fixture
drift before running the interpreter suite. This accepts recorded metadata
agreement and bounded local behavior;
it does not prove live admission, controller reconciliation, garbage collection,
protected database contents, or complete raw native response compatibility.

## Native response preparation (2026-10-02)

The authorized next native proof uses the separate idle `ep150-preview` context,
leaving frozen `f15-preview` untouched. A read-only scan with checksum-verified
kubectl `v1.35.8` against `v1.35.8+k3s1` observed 75 APIs in 26.1 seconds.
[Redacted response evidence](mp23-native-bootstrap-results-2026-10-02/knative-controller-collection-preflight.json)
exposed two omissions in the earlier metadata summary/model: successful Endpoints
lists emit a deprecation warning on stderr, and Knative propagates the parent's
inventory annotations to Configuration, Route, Ingress and the Route's core
Service. Both failed the new/strengthened production-path regressions before
repair. Successful exit status plus parsed list/continuation metadata now governs
list completeness; failed discovery and malformed/incomplete lists still refuse.
An exclusive supported descendant may carry its parent's exact inventory resource
ID; a different ID, shared edge or non-controller edge still refuses. The
sixteen-descendant fixture now includes the four observed annotation propagation
shapes. All 1,061 CLI tests pass after these repairs. Native mutation, actual GC
and interrupted-transaction proof are the next step, not results of this scan.

## Native Event aliases

Creating the disposable `mp23-gc-native` application on the separate
`ep150-preview` context exposed twenty Events through both `events` and
`events.events.k8s.io`, with the same persisted UIDs. The new
[metadata fixture](../../cli/nagarectl/test/fixtures/inventory/knative-event-aliases.json)
retains one actual pair. Its production-path regression initially failed with
`duplicate observed UID`. Complete namespace discovery now coalesces only this
known Event API pair when name, namespace, kind and ownership agree, preferring
the grouped API address. Resource versions may advance between reads. Both API
lists remain mandatory and counted in the 75-API budget; conflicting metadata
and duplicate UIDs outside this pair refuse authority. Events remain unsupported
as collection descendants. Separate refusal regressions cover both cases. All
1,064 CLI tests pass after the repair; fixture regeneration, CLI architecture
and Haskell style checks also pass.

## Native controller and recovery agreement — 2026-10-02

[The redacted native proof](mp23-native-bootstrap-results-2026-10-02/knative-controller-collection-native.json)
records installed `8a820ce8` on the separate existing `ep150-preview` Compute
Engine/NixOS/k3s `v1.35.8+k3s1` context, using checksum-verified kubectl `v1.35.8`.
It passed the installed public Knative fixture and the
[local platform gate](mp23-native-bootstrap-results-2026-10-02/local-platform-candidate-8a820ce8.json):
213 verification operations, 19 unchanged scope contents, and 37 Ready/completed
Pods. This validates the installed operator against the retained accepted local
payload, not fresh candidate-payload creation.

The disposable `mp23-gc-native` application was created with minimum scale one,
retired, and its release history collected under exact separate reviews using
`1033ec53`. The new controller review
`6bc9ae1a81b7b6ccbfabfece05260ecc5ac144f31dd53d0c1823c0ee15a16686`
then bound 17 real descendants, 41 protected inventoried objects and all 75 APIs.
The extra descendant relative to the older sixteen-node recording is a running
Pod. No database was created by this disposable application.

A pass-through recorder executed the real UID/resourceVersion-conditional
Background DELETE, recorded server acceptance, then withheld its genuine reply.
The orchestrator sent SIGINT to the CLI process group before that reply reached
the interpreter. After proving the process had exited, a fresh CLI explicitly
took over the same transaction. Parent absence did not falsely converge: the
first resume stayed ambiguous with one Pod inside its normal 300-second
termination grace, no Service tombstone and all protected identities present.
The normal Pod deletion was observed 301.238 seconds after the accepted request.
A second resume of the original transaction verified the complete namespace and
converged. No child DELETE, finalizer patch or repeated parent DELETE occurred.

| Command | Collection kubectl calls | Cluster-guard calls | Complete 75-API scans | Wall seconds |
| --- | ---: | ---: | ---: | ---: |
| Prepare | 78 | 8 | 1 | 67.497 |
| Apply, interrupted after accepted DELETE | 155 | 12 | 2 | 90.482 |
| Pending resume with explicit takeover | 78 | 8 | 1 | 52.072 |
| Final resume | 78 | 8 | 1 | 56.136 |
| Terminal replay | 0 | 0 | 0 | 13.226 |

Each scan includes discovery and every API list; the first scan's list calls
cost 29.586 seconds. Server acceptance of the DELETE took 0.173 seconds, distinct
from the Pod's grace period and final completeness verification. The interrupted
155-call prefix ends before wait/verification; the modeled full pending-apply
budget remains 233. Cluster guards account for the extra context/node commands
outside the interpreter fixture's constant guard. GCS inventory calls are not
separately counted. The extra diagnostic Pod watch and final read-only scan are
separate from these public-command counts.

A final 75-API scan independently checked the command's result: parent and all
17 descendants absent, no newly reachable descendants, all 125 original object
identities/ownership records unchanged, including 41 inventoried objects. Source
`mp23-pg-a` still contains `1|mp23-after-backup`; neighbor `mp23-pg-b` still contains
`1|mp23-untouched-app-b`. All 27 original accepted/converged revisions, original
retentions and original tombstones remain exact. Only the disposable history and
Service tombstones were added. Head generation 742/sequence 639 is idle. Terminal
replay made zero kubectl calls and left that head unchanged.

## Remaining acceptance

The bounded new-review native assertion is complete. F20 remains Open for
independent verification and disposition of its separately frozen old
transaction. This is implementer-supplied proof on the declared controller
versions, with existing database neighbors preserved; it does not claim native
same-scope retained-database coverage or an atomic graph deletion boundary.

Frozen `f15-preview`, candidate `4c4b667e`, generation 752/sequence 673 and original
transaction `tx-b6886179d40d4618442997221cc02ca986f142ccdeef1661448cfca627765472`
remain byte-identical at the head. Its cascade exception was neither authorized
nor executed. No old review was rewritten, no frozen transaction was resumed,
and no final native/release gate closes from this bounded proof.
