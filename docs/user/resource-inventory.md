---
type: Explanation
title: "Resource inventory and operation ledger"
description: "Understand scoped resource ownership, reviewed changes, live status, and recovery through Nagare's durable operation ledger."
docId: DOC-39
tags: [inventory, ownership, lifecycle, recovery, operations]
generated:
  by: process:codex
  at: 2026-10-09T14:24:33Z
---

# Resource inventory and operation ledger

Nagare keeps an inventory of the resources it manages in each
[context](contexts.md): cloud infrastructure, host configuration, Kubernetes
objects, databases, credentials, published artifacts, and release records.
Each resource has an owner, an identity, dependencies, and a lifecycle policy.
Before a change runs, Nagare checks those declarations together and prepares a
review. A durable operation ledger records what was attempted and what can be
proved complete, so an interrupted change can resume from its evidence.

For an operator, this answers four questions: what should exist, who owns it,
what is actually there, and what happened during the last change.

> **Status:** 🟡 **In progress.** The inventory, reviewed execution, status, and
> recovery paths are implemented. Full release acceptance remains governed by
> [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md).
> The first release covers fresh inventory-backed contexts. In-place platform
> version upgrades and automatic adoption of foreign resources are outside that
> release boundary.

## Inventory and ledger

The inventory describes desired resources. The ledger is the durable history
of reviewed changes and their execution. Live observations connect the two,
but each answers a different question:

| Record | What it tells you | What it does not establish |
| --- | --- | --- |
| Desired inventory | The declarations and revisions Nagare has accepted, including ownership and dependencies. | That every resource exists or is healthy. |
| Live observations | Whether a provider currently reports the expected object, configuration, identity, and readiness. | Permission to adopt, replace, or delete it. |
| Operation ledger | The saved review, operation intents, completion evidence, recovery decisions, and retained or collected identities. | That a previously successful workload is still healthy now. |

The ledger lives in the context's inventory store. Its current **head** points
to the accepted scope revisions and records active execution and lifecycle
state. Immutable members preserve declarations and reviews; the journal records
execution events. A saved review directory is one proposed change, while the
store preserves the context's continuing history.

Nagare continues to use native tools such as Pulumi, NixOS, Kubernetes, and
Helm. The inventory coordinates ownership and reviewed work across those tools.
Kubernetes controllers still reconcile their objects, and Pulumi still manages
its stack. Nagare does not continuously apply the whole inventory in a daemon.

## Independent scopes in one context

A **scope** is one owner's complete desired declaration, with its own revision.
Platform components and applications have separate scopes. Nagare composes
them into one context inventory to check their shared resource claims and
dependencies. Operators change the owning scopes; the combined inventory is
derived from them.

Suppose a context contains a platform foundation, application A, and application
B. Updating A changes its selected scopes while preserving B and the other
unselected scopes. A does not have to redeclare B's resources, and B's absence
from A's input does not retire it. Application releases can therefore proceed
without advancing the platform release.

An application may also request an authorized contribution to a shared
platform object, such as a namespace or access backend configuration. The
platform keeps ownership of that object. Composition includes the accepted
contributions and checks the application's permission to supply them. A review
can consequently include a shared configuration change as well as the
application's own objects.

The same typed declarations produce resource membership, native rendering,
review, and execution inputs. Nagare checks conflicting claims, missing
dependencies, cycles, and unauthorized contributions before admitting effects.
For example, two owners cannot independently claim the same Kubernetes Service
address. Controller-created children also have ownership boundaries; they are
not freely available for another scope to claim.

## Resource identity and dependencies

Each resource has a stable **logical ID** derived from its minting scope,
logical key, and role. Its **address** says where the provider object lives,
such as a Kubernetes kind, namespace, and name. Its **physical identity** names
one actual incarnation, such as a Kubernetes UID.

Deleting a PVC and creating another with the same name produces a different
incarnation. Matching names and ownership labels do not prove that it contains
the accepted data. Nagare records Kubernetes identities from reviewed write
results and compares them with live observations. A replacement is reported as
`replaced-incarnation`; a missing identity record is reported as `unrecorded`.
Operations involving data refuse these conditions until a supported reviewed
exit establishes the required authority.

This recorded-incarnation protection covers Kubernetes members. Other adapters
use their own provider evidence; the first release does not give every cloud,
host, topic, or artifact resource the same recorded identity guarantee. See the
[physical identity contract](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
for that boundary.

Keep explicit logical keys stable when changing display names. Changing a key
declares a new resource. A supported reviewed migration, such as a database
rename, can preserve logical identity while moving to a new address and
recording its destination incarnation. Editing a name alone does not authorize
that migration.

Dependencies distinguish consumption, readiness, and operation ordering. An
application can consume a database; an operation can wait for a service to be
ready; a later step can be ordered after an earlier one. Retained resources
continue to have dependencies, so a retired consumer may still prevent its
database, Service, or host from being collected. Deletion is not simply creation
order run backwards.

## From declaration to reviewed execution

An inventory change passes through these stages:

1. **Compile.** Compose the selected changes with the base scopes and validate
   the complete graph. The resulting candidate identifies the exact desired
   content and base revisions. Offline compilation contacts no provider and
   does not establish live ownership.
2. **Plan.** Compare the candidate with accepted history and provider
   observations. Save a review describing the operations, revision changes,
   native inputs, preconditions, and any barriers that require another review.
3. **Review.** Check the target context, selected scopes, dependencies, and
   proposed creation, adoption, update, migration, retention, or deletion.
4. **Apply.** Under the writer lock, recheck the store head, reservations, and
   live preconditions. Execute the saved operations in dependency order,
   journalling intent before effects and evidence afterwards.
5. **Observe.** Compare accepted and converged revisions with current resource
   identity, drift, and health.

A digest binds a candidate or review to exact content. A scope revision records
its position in history. Changing the saved bytes or using a review against
stale base revisions causes refusal; edit the declaration and prepare a new
review instead. A coherent compiled candidate alone is not authority to mutate
a provider.

An **accepted revision** is the desired revision admitted into history. A
**converged revision** records completion of its reviewed operations. They may
differ while execution is active or after a stopped transaction is closed.
Convergence also differs from current health: a workload can become unhealthy
after its deployment completed.

For example, after publishing an image through the
[reviewed image workflow](build-modes.md), save an application deployment review
in a new private directory. This example assumes the config needs no additional
database, volume, or credential bindings; use
[Deploying apps](deploying-apps.md) for those options. Set `CONTEXT`, `TAG`,
`IMAGE_RESOURCE_ID`, and `REVIEW` to your context, the published tag, its accepted
resource ID, and the new review directory:

```bash
nagarectl --context "$CONTEXT" app deploy -f nagare/Config.hs \
  --tag "$TAG" --image-resource "$IMAGE_RESOURCE_ID" --save-plan "$REVIEW"
jq '{context, payloadIdentity, baseRevisions, desiredRevisions, barriers,
     operations: [.operations[] | {operation, summary}]}' "$REVIEW/review.json"
nagarectl --context "$CONTEXT" inventory apply "$REVIEW" --yes
nagarectl --context "$CONTEXT" inventory status --json
```

Keep the complete review directory. Its private native members are required for
execution and recovery; the public `review.json` summary alone is insufficient.
Credentials remain private and are referenced rather than embedded in public
review or evidence.

## Inspecting ownership and status

Use these read-only commands against the selected context:

```bash
nagarectl --context "$CONTEXT" inventory store status --json
nagarectl --context "$CONTEXT" inventory status --json
nagarectl --context "$CONTEXT" inventory explain "$RESOURCE_ID" --json
```

`store status` shows the history binding, head digest and generation, active
transaction, and executor claim. `status` reports accepted and converged
revisions, live findings, retained members, and collection assessments.
`explain` narrows observation to one resource and exposes its owner,
dependencies, consumers, and lifecycle information. Copy `RESOURCE_ID` from
inventory output rather than substituting a provider name.

Read drift and health separately:

| Finding | Meaning and next step |
| --- | --- |
| `converged` | The observed configuration matches; inspect health separately. |
| `configuration-drift` | Replan the owning scope to review a repair. |
| `immutable-replacement-required` | An in-place update cannot make the requested change; a supported replacement or migration needs its own review. |
| `stuck-rollout` | The expected configuration has not become ready; inspect the workload and active transaction. |
| `missing` | Observation confirmed absence. Missing accepted durable data requires recovery rather than automatic recreation. |
| `replaced-incarnation` or `unrecorded` | Identity evidence does not establish the accepted object. Use the supported retirement or reviewed rebind procedure. |
| `unowned` or `foreign-owner` | Ownership does not match; deployment cannot silently take it over. |
| `unknown` | Observation could not establish the state. Restore access or investigate the reported reason. |

An authentication failure, timeout, or incomplete provider listing is not proof
of absence. See the [inventory operations runbook](../runbooks/inventory-operations.md)
for drift repair and identity recovery procedures.

## Interruptions and recovery

An apply coordinates multiple native systems; it cannot roll every completed
effect back as one atomic database transaction. A lost response may follow a
successful write. The journal preserves that uncertainty so recovery can
observe the original operation instead of blindly submitting it again.

Take the transaction ID from command output or `inventory store status`, retain
the original review, and resume:

```bash
nagarectl --context "$CONTEXT" inventory resume "$TRANSACTION" --yes
```

Resume skips work proved complete and checks uncertain operations through their
adapters. If it cannot establish a result, it stops with the evidence and reason
available. A replacement review is not a substitute for recovering the active
transaction.

If resume cannot make progress, `inventory close` can end a stopped transaction
after classifying its operations from proof. A changed scope with no effects
returns to the review's base revision; a scope with landed effects keeps its
desired revision so those resources remain owned. Close does not mutate
providers, claim convergence, or bind new incarnations. Unknown effects and
active data fences or migrations require their own recovery steps. The
[runbook](../runbooks/inventory-operations.md#close-a-stopped-transaction)
describes close, attestation, and migration exits.

## Where history lives and who may write

Local contexts use a private filesystem store under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/inventory`. Cloud contexts
can use the context's GCS state bucket alongside Pulumi state. Consult
[shared inventory history](contexts.md#shared-inventory-history-cloud-contexts)
to configure or migrate a store, and verify the selected backend with
`inventory store status`.

There is one writer per context. Conditional writes prevent another client
from overwriting the shared head, and an executor claim identifies the current
transaction's operator. The claim has no lease or automatic expiry. A second
workstation must first establish that the original executor and its child
processes have stopped, then explicitly resume with `--take-over`. Nagare does
not determine whether that executor is alive.

Preserve private configuration, credentials, reviews, and history when moving
workstations. Use supported store migration and export procedures. Editing the
head, deleting a claim, or restoring copies as independently writable stores
would bypass the coordination that protects ownership and deletion authority.

## Retirement and collection

Removing a scope from active desired state is **retirement**. Nagare retains
its resources and records their identities and policies. Physical deletion is
**collection**, a separate review of eligible retained resources.

First screen retained resources without authorizing deletion:

```bash
nagarectl --context "$CONTEXT" inventory gc --plan --out "$ASSESSMENT"
```

The assessment explains eligibility and blockers. When policy, dependencies,
identity, and adapter support permit collection, prepare a separate review:

```bash
nagarectl --context "$CONTEXT" inventory collect \
  --resource "$RESOURCE_ID" --out "$COLLECTION_REVIEW"
```

Inspect and apply it through the saved-review procedure. A confirmed deletion
leaves a tombstone in history. Omission from another scope's input, retirement,
and a collection assessment never authorize deletion on their own.

Data is retained by default. Retired database PVCs, credential Secrets, and
broker topics do not acquire deletion authority just because their application
is gone. Supported stateless companions collect in dependency order, and
retained consumers can block collection. Full-context physical teardown is
outside the first inventory release; cloud perimeter cleanup is staged and
bounded. Scheduled backup keep-N and expiry retention are also unenforced;
an expiry timestamp does not prove that an archive was deleted.

The ledger records backup and restore authority, but it does not contain the
database contents or replace off-cluster backups. Restores use isolated
destinations and preserve their source; automatic cutover and live overwrite
are deferred. Follow [Backups and disaster recovery](backups-and-disaster-recovery.md)
for protection and restore procedures, and the
[inventory operations runbook](../runbooks/inventory-operations.md) for execution
and recovery details.
