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

The focused run passed in a disposable local context after adding a local kubeconfig fixture. This proves the public command, accepted-history, and conditional Kubernetes transport shape under recording shims. It does not prove the frozen native candidate's policy transition or web deletion. That candidate still declares `Retain`; its installed validation remains behind the selected GCloud account's interactive reauthentication and exact read-only preflight. Do not start another build or cloud effect from this local result alone.
