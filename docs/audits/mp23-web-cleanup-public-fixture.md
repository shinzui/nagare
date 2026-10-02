# Public web cleanup fixture (2026-10-01)

Run `python3 scripts/test-web-cleanup-public.py` from the repository root. The fixture uses a disposable filesystem inventory history and a recording `kubectl` shim. It makes no cluster or cloud call.

Add `--nagarectl /absolute/path/to/nagarectl` to exercise an installed candidate.
The checkout's compiled Haskell library still seeds the disposable history;
the selected executable performs every public compile, review, and apply.

The seeded accepted Application scope has a Service, a legacy `Retain` release-history ConfigMap, and a DomainMapping. Both consumers retain their ordering edge to the Service. An independent accepted scope has a StatefulSet, PVC, and backup Job. The public commands complete these steps:

1. `inventory compile` and `inventory plan` produce exactly one ConfigMap `UpdateResource` operation for the policy transition to `DeleteWhenUnreferenced`; `inventory apply` converges it.
2. `inventory retire` and `inventory apply` remove the Application scope from accepted history with zero provider mutations.
3. `inventory collect` refuses the Service while both consumers remain, then refuses it again after release-history collection while DomainMapping remains. Both refusals leave the head bytes unchanged.
4. Separate saved collection reviews delete release history, DomainMapping, and Service in that order. Three tombstones retain their original UIDs. The independent data scope keeps its accepted revision and all three provider identities throughout. The final head has no active transaction and accepted equals converged.

The focused run passed in a disposable local context after adding a local kubeconfig fixture. This proves the public command, accepted-history, and conditional Kubernetes transport shape under recording shims. Native installed validation subsequently accepted the policy transition, effect-free retirement and history collection, then exposed [F20](mp23-findings.md#f20) at Knative Service collection. [The native evidence](mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json) retains that incomplete result.

The `--partial` mode keeps the database StatefulSet, PVC and backup Job in
the same accepted Application scope while retiring only its web members. It
compares all three data declarations at every stage, proves effect-free partial
retirement, keeps the dependency refusals and exact three collection tombstones,
and checks their provider identities/state unchanged. Both modes pass after
adding this case. The `--retain-data` mode also retires that whole scope without provider mutations,
retains its exact data incarnations, and collects only the web members. An
independent accepted platform neighbor remains unchanged in every mode. These
modes pass against installed `4c4b667e`; the native selection uses whole-scope
retirement, nine retained database members, and separate history/Service
collection. Application A stays accepted. This adds no new lifecycle behavior.

The `--knative --retain-data` mode uses a Knative Service and requires Background
propagation in its recording transport. Installed `4c4b667e` fails this
counterfactual at Service collection; it is a known failing regression, not a
supported cascade or descendant-authority implementation. Adding
`--expect-orphan-block` instead accepts the issued Orphan deletion and models a
pending finalizer. That mode passes by proving exactly one delete, the original
active transaction, no parent tombstone, the retained parent UID and unchanged
data/neighbor identities. It does not execute real controllers or establish
future collection authority. Each passing run saves `result.json` with the
installed version, public command results and final head in its printed artifact
directory.
