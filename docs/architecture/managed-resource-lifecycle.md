# Managed resource lifecycle

The accepted inventory names logical resources and their owning scopes. A provider object at
the same address is not ownership proof. `inventory status --json` reports an unstamped
Kubernetes object as `unowned` and an object stamped for another logical resource as
`foreign-owner`. An observation error is `unknown`, never confirmed absence.
The JSON report's `observationStartedAt` and `observedAt` bound the provider
reads; `missingProviderScopes` names any parts that could not be observed.
An adapter can report `immutable-replacement-required` when it proves that a
changed object cannot be updated in place. Status shows the physical identity
and observed digest, while ordinary planning refuses an update until a reviewed
replacement or migration path exists. The Kubernetes observer emits this
outcome when an explicitly declared `apps/v1` Deployment selector changes, or
when a StatefulSet's explicit selector, service name, volume claim templates,
or pod management policy change. Other immutable changes remain outside that
proved classification.

When a transaction is active, status and explain include `transactionStatus` with the
latest committed state of each journaled operation. `recoveryRequired` marks an
intent with no proven completion or an ambiguous effect. The summary validates the
committed journal and reports state names without provider error text or private
command output. The report rejects a concurrent head change and can be retried.
`inventory explain RESOURCE_ID --json` also includes `dependencyTrace`, following
transitive prerequisites to their composed declarations with owner scope and source.
For Kubernetes Jobs, CRDs, cert-manager Certificates and ClusterIssuers,
Knative Services, Deployments, and StatefulSets, status separately probes controller
conditions and reports health as `ready` or `not-ready` when the second read
still has the observed UID. Other kinds and failed or changed reads remain
`unknown`; a missing resource is `unavailable`.
An existing supported object whose controller condition is not ready remains
observable for configuration and ownership status. It reports `not-ready`
health, while reviewed execution still requires a ready completion proof.
Retained Kubernetes resources use the same separate health probe only when
their observed UID still matches the historical UID. A replacement at the
same address cannot lend readiness to the retained incarnation. Confirmed
absence reports health `unavailable`.
Status also includes the read-only `collectionAssessments` for retained
resources. Each assessment carries blockers and `deletionAuthorized: false`.
Explain shows the historical declaration's aliases, required conditions,
delegations, policies, and source alongside its dependency trace.

## Adoption review

Compile the complete candidate with `inventory compile`, then write a version 1 adoption
proposal. [The example](../../cli/nagarectl/test/fixtures/inventory/lifecycle/adopt.example.json)
shows its wire shape; a [legacy cache Service example](../../cli/nagarectl/test/fixtures/inventory/lifecycle/adopt-cache.example.json)
uses the same per-resource review. `candidate` is relative to the proposal file unless absolute. Its
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
The proved transfer route currently accepts Kubernetes resources and Helm
releases, and requires the executor, address, spec, aliases, policies,
delegations, and dependencies to remain equal. For Helm, the release must
still have its context and ResourceId stamp, unchanged native contract, and
the reviewed release revision; a changed revision refuses verification.
The review runs an incarnation-bound verification before the transfer can converge.
An unreviewed move between files or scopes is refused as `owner-transfer-required`.

## Retirement and migration

Run `nagarectl inventory retire --scope KIND:NAME --out REVIEW_DIRECTORY` to review
retention of an accepted scope. `KIND` is `platform`, `application`, `standalone`, or
`publication`; the [application example](../../cli/nagarectl/test/fixtures/inventory/lifecycle/retire-app.example.txt)
shows the review and apply commands. The current route accepts directly declared Kubernetes resources
and stamped Helm releases whose exact owned UIDs can be observed. It refuses if another scope still depends
on the retiring declarations or if a disappearing resource lacks the required
retention proof. A scope with observed controller children also refuses until
their claims can be retained as historical child entries. Apply the issued review with `inventory apply REVIEW_DIRECTORY
--yes`; apply checks those UIDs again under the writer lock and records each
incarnation against its old immutable scope revision. Retirement performs no provider delete or Helm upgrade.

The retained objects keep their provider addresses reserved. `inventory status
--json` and `inventory explain RESOURCE_ID --json` observe them through the native
bytes in their original accepted review and distinguish the retained UID from a
replacement, absence, foreign ownership, or an unavailable provider. These
observations do not grant collection authority. Explain includes consumers
among both active and retained declarations, so retiring two related resources
does not erase their dependency relationship. A retained resource's own
`dependencyTrace` also follows those historical declarations to their owners.

A pending Helm release with a valid Nagare owner stamp remains an owned
observation. Its unready status blocks reviewed verification; it is not reported
as foreign ownership. Status checks the release again and reports `ready` or
`not-ready` only when the second read has the same revision Secret UID and
logical owner. A changed or unavailable second read leaves health `unknown`.
A malformed Helm status response is unavailable, while a readable release with
a missing or mismatched owner stamp is foreign.

The collection route accepts retained stateless namespaced ConfigMaps, Services,
and CronJobs whose lifecycle policy is `DeleteWhenUnreferenced`, whose exact
stamped UID is
present, and whose active and retained consumers are absent. Run `nagarectl
inventory collect --resource RESOURCE_ID --out REVIEW_DIRECTORY`, inspect the
ordinary review, then apply it. Repeat `--resource` to collect several retained
members in one reviewed transaction; each member keeps its own identity and
preconditions. Admission checks the reviewed Kubernetes resourceVersion and UID
again. The DELETE request carries both as server-side preconditions and uses
orphan propagation; the adapter verifies confirmed
absence after a bounded deletion wait before the context head drops the
retained claim and records a tombstone
bound to the review digest. A replacement or changed object refuses. A resumed
transaction can finish an already verified tombstone without deleting again.
Status lists collected tombstones, and `inventory explain RESOURCE_ID --json`
returns the collection record after the retained entry leaves the catalogue.

Collection of durable data, controller children, other Kubernetes kinds, and
other executors still refuses until their dependency, backup, recovery, and
deletion contracts are proved. Collection of a retained migration source also
refuses while the same logical ID has an active incarnation.

Changing an accepted ResourceId's provider address or executor requires
`inventory migrate --input PROPOSAL.json --out REVIEW_DIRECTORY`. The
[version 1 database Service rename example](../../cli/nagarectl/test/fixtures/inventory/lifecycle/migrate.example.json)
shows the source address and UID, destination address and absence proof, and
data contract. The candidate supplies the desired declaration; the input does
not repeat it. The command observes source and destination through separate
provider bindings, validates both facts against accepted history, and plans
eight ordered stages: prepare destination, back up source, fence writers,
transfer state, verify destination, switch consumers, admit writes, and retain
source. The immutable review binds the old and new addresses, old scope
revision and UID, destination absence, and stateless or durable contract.
Durable input must name backup, compatibility, fence, and recovery evidence
digests; the adapter must verify what those digests attest before issuing a
review. Generic recording-adapter tests prove execution and recovery after an
interruption at each stage. The head then holds the destination as active and
the source as a retained physical incarnation with a separate address claim.
Status observes each incarnation through its own immutable native evidence.
Production provider adapters do not yet implement the eight stage contract,
so a real migration proposal refuses during native preparation. Ordinary
`inventory plan` continues to return `migration-review-required` for the
address or executor change.

`nagarectl inventory gc --plan --out DIRECTORY` writes a read-only
`collection-plan.json`. Each retained resource has a candidate flag and reasons
for any current refusal, including retention policy, durable recovery evidence,
dependent consumers, an unverified physical identity, an unsupported conditional
collection transport, or an active transaction.
The report records `deletionAuthorized: false`; a candidate still needs the
separate reviewed `inventory collect` transaction before any object can be
deleted. The current executor supports stateless namespaced ConfigMaps,
Services, and CronJobs with `DeleteWhenUnreferenced`; other kinds and providers
carry an explicit transport
blocker in this assessment.

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
