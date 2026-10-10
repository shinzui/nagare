# Deep tier on d42913c9 (EP-183 integration tip), triaged 2026-10-10

`just gate-deep d42913c9` (16 shards on the remote builder, about six hours) exits 1, as a
monitoring tier does whenever it finds violations (ADR 25, 2026-10-07 amendment). Logs:
`~/.local/state/nagare/gates/logs/remote-d42913c9-20261010T145113Z/`.

Every violation falls in a class that fails closed: planning refuses, or a transaction stops with
a reviewed exit. No class accepts unreviewed state, drops data, or removes a recovery point. None
blocks the release; all go to the deferral ledger under the existing owners.

| Class | Scenarios | Triage |
|---|---|---|
| `I1` planning refused, `observation-unavailable` | database update/restart; namespace update | F77 (Terminating claim or object deleted outside review): deferred, deferral ledger |
| `I1` planning refused, `invalid-retirement` | database, namespace and DomainMapping retire | F77's shape for an object deleted outside review before its retirement: deferred |
| `I9` accepted but not converged | database update/restart; StatefulSet update | F78 (a never-Ready template stops the transaction): next MasterPlan |
| `I8` settles unknown, "Kubernetes object changed since review" | database scenarios, including the new EP-183 M4 rebuild | Pair faults only; the exit is a corrected review or an attested close |
| `I1` stopped ambiguous or executor interrupted | database scenarios, including the EP-183 M4 rebuild | Pair faults only; `inventory resume` or `close` is the exit |

Counts by scenario and violation start (fault ordinals and operation ids removed):

```text
   1653 scenario: create a database, update its resources, update it again, then restart it	violation: I1: planning refused (PlanError {planErrorCode = "observation-unavailable",
    837 scenario: kind ("","namespace"): update	violation: I1: planning refused (PlanError {planErrorCode = "observation-unavailable", planErrorMessage = "required resource obser
    758 scenario: create a database, update its resources, update it again, then restart it	violation: I9: the final step's scope ScopeId Standalone (Name "database-pg") ended ac
    684 scenario: create a database, then retire it	violation: I1: planning refused (PlanError {planErrorCode = "invalid-retirement", planErrorMessage = "retention needs a select
    584 scenario: kind ("apps","statefulset"): update	violation: I9: the final step's scope ScopeId Application (Name "model-web") ended accepted but not converged
    446 scenario: kind ("","namespace"): retire	violation: I1: planning refused (PlanError {planErrorCode = "invalid-retirement", planErrorMessage = "retention needs a selected s
     16 scenario: create a database, lose the cluster, then rebuild it (EP-183 M4)	violation: I8: op-X settles unknown: Kubernetes object changed since review; replan before muta
     12 scenario: create a database, update its resources, update it again, then restart it	violation: I1: stopped (ambiguous; operations: op-X VerifyResource standalone:database
     10 scenario: create a database, update its resources, update it again, then restart it	violation: I1: stopped (ambiguous; operations: op-X UpdateResource standalone:database
      8 scenario: create a database, update its resources, update it again, then restart it	violation: I8: op-X settles unknown: Kubernetes object changed since review; replan be
      8 scenario: create a database, then retire it	violation: I8: op-X settles unknown: Kubernetes object changed since review; replan before mutation (resolved by a corrected r
      8 scenario: create a database, then ingest a scheduled receipt	violation: I8: op-X settles unknown: Kubernetes object changed since review; replan before mutation (resolved
      7 scenario: kind ("serving.knative.dev","domainmapping"): retire	violation: I1: planning refused (PlanError {planErrorCode = "invalid-retirement", planErrorMessage = "reten
      6 scenario: create a database, lose the cluster, then rebuild it (EP-183 M4)	violation: I1: stopped (ambiguous; operations: op-X CreateResource standalone:database-pg/pg/cr
      4 scenario: create a database, then retire it	violation: I1: stopped (ambiguous; operations: op-X CreateResource standalone:database-pg/pg/credential; op-X CreateResource s
      4 scenario: create a database, then ingest a scheduled receipt	violation: I1: stopped (ambiguous; operations: op-X CreateResource standalone:database-pg/pg/credential; op-X
      2 scenario: create a database, then retire it	violation: I1: stopped (executor interrupted; operations: op-X CreateResource standalone:database-pg/pg/credential; op-X Creat
      2 scenario: create a database, then ingest a scheduled receipt	violation: I1: stopped (executor interrupted; operations: op-X CreateResource standalone:database-pg/pg/crede
      2 scenario: create a database, lose the cluster, then rebuild it (EP-183 M4)	violation: I1: stopped (executor interrupted; operations: op-X CreateResource standalone:databa
      1 scenario: create a database, update its resources, update it again, then restart it	violation: I1: stopped (executor interrupted; operations: op-X CreateResource standalo
      1 scenario: create a database, update its resources, update it again, then restart it	violation: I1: stopped (ambiguous; operations: op-X CreateResource standalone:database
```
