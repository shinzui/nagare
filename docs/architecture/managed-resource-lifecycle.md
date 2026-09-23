# Managed resource lifecycle

The accepted inventory names logical resources and their owning scopes. A provider object at
the same address is not ownership proof. `inventory status --json` reports an unstamped
Kubernetes object as `unowned` and an object stamped for another logical resource as
`foreign-owner`. An observation error is `unknown`, never confirmed absence.

When a transaction is active, status and explain include `transactionStatus` with the
latest committed state of each journaled operation. `recoveryRequired` marks an
intent with no proven completion or an ambiguous effect. The summary validates the
committed journal and reports state names without provider error text or private
command output. The report rejects a concurrent head change and can be retried.
`inventory explain RESOURCE_ID --json` also includes `dependencyTrace`, following
transitive prerequisites to their composed declarations with owner scope and source.
For Kubernetes Jobs, CRDs, cert-manager Certificates and ClusterIssuers,
Knative Services, and Deployments, status separately probes controller
conditions and reports health as `ready` or `not-ready` when the second read
still has the observed UID. Other kinds and failed or changed reads remain
`unknown`; a missing resource is `unavailable`.

## Adoption review

Compile the complete candidate with `inventory compile`, then write a version 1 adoption
proposal. [The example](../../cli/nagarectl/test/fixtures/inventory/lifecycle/adopt.example.json)
shows its wire shape. `candidate` is relative to the proposal file unless absolute. Its
`binding` must equal the candidate's context/project; each resource must name the exact
composed provider address and a freshly observed physical identity. It does not repeat the
desired specification, owner, dependencies, or data policy.

Run `nagarectl inventory adopt --input PROPOSAL.json --out REVIEW_DIRECTORY`. This observes
all candidate and historical resources before issuing a normal immutable review. The
proposal's selected objects must still be unowned at their exact incarnation. Other
resources in the same candidate may be ordinary creates or updates. Apply the review with
`nagarectl inventory apply REVIEW_DIRECTORY --yes`. For Kubernetes, the initial adoption
path supports an object whose desired fields already match the declaration. The adapter
stamps only Nagare's reserved annotations using one UID and resourceVersion tested JSON
Patch. A changed object or owner refuses; a failed acknowledgement requires the ordinary
journal recovery path. Preparing the review does not write to the managed object.
An existing inventory stamp without accepted ownership history cannot be adopted through
this route, even when its logical identity appears to match.

For a transfer between known scopes, keep the same ResourceId in the new declaration,
select both the prior and next scopes in the compiled candidate, and set
`previousOwner` on that proposal resource to the exact prior ScopeId. The observed
object must already carry the same logical identity and desired native content.
The proved transfer route currently accepts Kubernetes resources only, and requires
the address, spec, aliases, policies, delegations, and dependencies to remain equal.
The review runs an incarnation-bound verification before the transfer can converge.
An unreviewed move between files or scopes is refused as `owner-transfer-required`.

## Retirement and migration

Run `nagarectl inventory retire --scope KIND:NAME --out REVIEW_DIRECTORY` to review
retention of an accepted scope. `KIND` is `platform`, `application`, `standalone`, or
`publication`. The current route accepts directly declared Kubernetes resources
whose exact owned UIDs can be observed. It refuses if another scope still depends
on the retiring declarations or if a disappearing resource lacks the required
retention proof. A scope with observed controller children also refuses until
their claims can be retained as historical child entries. Apply the issued review with `inventory apply REVIEW_DIRECTORY
--yes`; apply checks those UIDs again under the writer lock and records each
incarnation against its old immutable scope revision. No Kubernetes delete is run.

The retained objects keep their provider addresses reserved. `inventory status
--json` and `inventory explain RESOURCE_ID --json` observe them through the native
bytes in their original accepted review and distinguish the retained UID from a
replacement, absence, foreign ownership, or an unavailable provider. These
observations do not grant collection authority. Explain includes consumers
among both active and retained declarations, so retiring two related resources
does not erase their dependency relationship. A retained resource's own
`dependencyTrace` also follows those historical declarations to their owners.

The first collection route accepts only retained stateless namespaced ConfigMaps
whose lifecycle policy is `DeleteWhenUnreferenced`, whose exact stamped UID is
present, and whose active and retained consumers are absent. Run `nagarectl
inventory collect --resource RESOURCE_ID --out REVIEW_DIRECTORY`, inspect the
ordinary review, then apply it. Admission checks the reviewed Kubernetes
resourceVersion and UID again. The DELETE request carries both as server-side
preconditions and uses orphan propagation; the adapter verifies confirmed
absence before the context head drops the retained claim and records a tombstone
bound to the review digest. A replacement or changed object refuses. A resumed
transaction can finish an already verified tombstone without deleting again.
Status lists collected tombstones, and `inventory explain RESOURCE_ID --json`
returns the collection record after the retained entry leaves the catalogue.

Collection of durable data, controller children, other Kubernetes kinds, and
other executors still refuses until their dependency, backup, recovery, and
deletion contracts are proved. Migration also refuses until a reviewed prepare,
seed, verify, switch, write-admission, and recovery graph is available.

`nagarectl inventory gc --plan --out DIRECTORY` writes a read-only
`collection-plan.json`. Each retained resource has a candidate flag and reasons
for any current refusal, including retention policy, durable recovery evidence,
dependent consumers, an unverified physical identity, or an active transaction.
The report records `deletionAuthorized: false`; a candidate still needs the
separate reviewed `inventory collect` transaction before any object can be
deleted. The executor may refuse a candidate that has no proved collection
transport for its kind or provider.

## Operator recovery

For an active transaction with an uncertain operation, inspect `inventory status
--json` and the private provider evidence, then write a version 1 decision file:

```json
{
  "version": 1,
  "transaction": "tx-REVIEW_DIGEST",
  "operation": "op-OPERATION_ID",
  "review": "REVIEW_DIGEST",
  "action": "accept-adapter-proof"
}
```

Use the exact transaction, operation, and review digest from the issued review
and journal. `action` is either `accept-adapter-proof` or
`retry-after-adapter-proof`. Run `nagarectl inventory recover TRANSACTION
--operation OPERATION --decision FILE`, then `nagarectl inventory resume
TRANSACTION --yes`. The recovery command records a journal decision under the
writer lock only when the issued adapter independently proves completion or
safe retry from current provider state. It refuses a mismatched file, an
inactive transaction, an already resolved operation, changed adapter identity,
and any unresolved or contrary adapter result. A decision file cannot supply
its own completion proof or override the adapter.
