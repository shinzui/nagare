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

For a transfer between known scopes, keep the same ResourceId in the new declaration,
select both the prior and next scopes in the compiled candidate, and set
`previousOwner` on that proposal resource to the exact prior ScopeId. The observed
object must already carry the same logical identity and desired native content.
The proved transfer route currently accepts Kubernetes resources only, and requires
the address, spec, aliases, policies, delegations, and dependencies to remain equal.
The review runs an incarnation-bound verification before the transfer can converge.
An unreviewed move between files or scopes is refused as `owner-transfer-required`.

## Retirement and migration

Retirement and collection currently refuse. The head must first retain historical physical
incarnations and deletion tombstones after an accepted scope disappears. A retirement
approval cannot be interpreted as deletion authority, and durable data requires backup and
recovery evidence. Migration also refuses until a reviewed prepare, seed, verify, switch,
write-admission, and recovery graph is available. These safeguards prevent a partial
implementation from deleting or reassigning data by name alone.
