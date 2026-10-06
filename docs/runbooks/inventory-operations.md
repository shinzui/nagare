# Operate and recover a reviewed inventory

This runbook covers an inventory-admitted context. Complete its operational
checks against the selected release candidate and an eligible disposable context;
have an independent reviewer execute the technical procedures and record F14–F18
verification before safe-use acceptance. The operator retains the final production
go/no-go decision. Bootstrap alone does not
establish that gate. Other supported implementation and release work continues
while that review is pending.

**Prerelease fixture disposition — 2026-10-02.** `f15-preview` and operator
`4c4b667e` are retired from acceptance under [the operator decision](../audits/mp23-prerelease-fixture-disposition.md).
Do not use that context for production, resume its old transaction, wait for its
cascade exception, or keep its binary installed as a completion prerequisite.
The recorded private roots and failed review remain diagnostic evidence.
Installed `8a820ce8` has the latest bounded native controller proof in
`ep150-preview`; this does not establish full release acceptance. Select the
actual candidate and verify its version, context, payload and history bindings
before native work.

## Select the private context

Use the installed candidate and the context's private configuration, state and
cache roots. Set `CONTEXT`, `PROJECT`, `GCLOUD_CONFIGURATION` and `OPERATOR_ROOT`
to the selected eligible fixture and its actual private root. Prefer the existing
`ep150-preview` fixture where its accepted inputs fit the assertion; confirm its
current state rather than reusing a historical head value.

```bash
export XDG_CONFIG_HOME="$OPERATOR_ROOT/config"
export XDG_STATE_HOME="$OPERATOR_ROOT/state"
export XDG_CACHE_HOME="$OPERATOR_ROOT/cache"
export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_PROJECT="$PROJECT"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CONTEXT.yaml"
nagarectl --context "$CONTEXT" context guard
nagarectl --context "$CONTEXT" inventory store status --json
```

The selected context, project and store binding must agree. Keep the context's
mode-0600 kubeconfig private. A fresh workstation without that credential uses
`nagarectl --context "$CONTEXT" kubeconfig recover`; recovery checks the accepted
host and content rather than admitting new infrastructure. Supply the context
profile and the exact declared `hosts/$CONTEXT/host.nix`, `flake.nix` and
`flake.lock` inputs in the new config root; retain their accepted bytes. These
inputs describe the host and are separate from the private kubeconfig. Recovery
refuses an active transaction/claim/fence/migration and incomplete or changed
host inputs before materializing credentials. The installed `71288437` fresh-root
run recovered a mode-0600 kubeconfig in 10.347 seconds, reached the same Ready
node and left generation 479/sequence 458 unchanged. Do not copy a migration
marker or edit shared history to make discovery succeed. Use the actual NixOS/k3s
host; this runbook never selects a GKE cluster.

Before an expensive native command, bind the CLI to the context's accepted
payload workspace and the selected candidate's exact revision. Use
`scripts/inventory-candidate-preflight.sh` with the reviewed workspace digest,
payload identity and expected idle head generation/digest. Derive these from the
selected context's accepted evidence, not from the retired F15 example or a
changing source checkout. An unresolved active transaction requires that
context's supported recovery; do not overwrite expected values merely to pass
preflight. The retired F15 context is excluded from this workflow.

The preflight does not replace saved-review, operation-count, native-identity or
neighbor-revision checks before apply. It is a read-only check, not authority to
reuse another fixture's review.

## Apply a saved review

Save the command's `--save-plan` review or a platform bootstrap `plan --out` review
in a new directory. Planning does not authorize unrelated effects. Inspect its
public operations, target binding, barriers and revision changes:

```bash
jq '{context, payloadIdentity, baseRevisions, desiredRevisions, barriers,
     operations: [.operations[] | {operation, summary}]}' "$REVIEW/review.json"
nagarectl --context "$CONTEXT" inventory apply "$REVIEW" --yes
nagarectl --context "$CONTEXT" inventory store status --json
nagarectl --context "$CONTEXT" inventory explain "$RESOURCE_ID" --json
```

Apply must use the saved review and its private native members. Refuse changed
physical identities, stale scope revisions, unexpected replacements/deletions or
missing evidence. Keep the review, journal and any failed Job after a failure.
A lost response may follow a successful provider write; making a replacement
review is not recovery.

## Resume the original transaction

Take the transaction ID from the command output or active shared-store status.
For an issued review it is `tx-` followed by that review's SHA-256, as recorded in
`review.sha256`. Use the original context and transaction:

```bash
nagarectl --context "$CONTEXT" inventory resume "$TRANSACTION" --yes
nagarectl --context "$CONTEXT" inventory store status --json
```

The driver observes uncertain operations and skips proved completed effects.
It checks each operation when its dependencies permit execution. An unresolved
effect or terminal failure stops with its original evidence available. Repeating
resume cannot turn an unknown result into permission for a blind retry.

## Take over after an operator crash

A crashed operator machine holds its executor claim until another operator takes
over explicitly. The claim does not expire simply because time passes. First
establish that the original executor has stopped, including its local child
processes, and inspect the shared transaction and claim. A provider Job may still
be running; resume observes that original Job rather than creating another one.
Do not take over while the original operator is still executing.

```bash
nagarectl --context "$CONTEXT" inventory store status --json
nagarectl --context "$CONTEXT" inventory resume "$TRANSACTION" --yes --take-over
```

Takeover retains the original review and operation IDs. It does not grant new
resource ownership or replace an active data fence. A foreign claim without
explicit takeover must refuse. Never remove a claim file or rewrite the head.

## Resolve an operation with adapter proof

When ordinary resume cannot prove a result, choose the supported recovery action
for that operation. A version-1 decision binds `transaction`, `operation`, `review`
and `action`. The review field is the exact saved review digest. Actions such as
`accept-adapter-proof` and `retry-after-adapter-proof` still require the adapter's
fresh identity-bound proof; a decision file cannot assert completion by itself.

```bash
nagarectl --context "$CONTEXT" inventory recover "$TRANSACTION" \
  --operation "$OPERATION" --decision "$PRIVATE_DECISION"
nagarectl --context "$CONTEXT" inventory store status --json
nagarectl --context "$CONTEXT" inventory resume "$TRANSACTION" --yes
```

## Close a stopped transaction

When resume stops and cannot make progress, close the transaction
([ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)). The review is the
saved review's SHA-256, as in `review.sha256`:

```bash
nagarectl --context "$CONTEXT" inventory close "$TRANSACTION" --review "$REVIEW_SHA256"
nagarectl --context "$CONTEXT" inventory store status --json
```

Close classifies every operation of the review from its journal or from the adapter's fresh
settlement:
- completed, never started, refused with no effect, reverted, or no effect;
- landed, target gone, or terminal partial;
- unknown.

It refuses, and changes nothing, in these cases:
- Any operation is unknown. The error names each one and what would resolve it. Investigate;
  never edit an object by hand to make close pass.
- Resume could still progress: a pending operation passes a fresh preflight, or the adapter
  proves an uncertain one complete or safe to retry. Run `inventory resume` first.
- A data fence or a migration is active. Those keep their own recovery phases.

Otherwise close publishes one record and writes one head. The transaction ends, nothing is
converged, and no incarnation is bound. Scopes the review did not change are untouched. Each
changed scope gets one of two dispositions:
- **Reverted.** Nothing in it took effect, so its accepted revision returns to the review's base
  and the review's own retained additions are removed.
- **Kept.** Something in it completed, landed or partially ran. It keeps the review's desired
  revision; its objects stay owned and unconverged, and the next review plans from them.

The record also lists the creates that never started and were confirmed absent at close. A later
review of the same accepted scope may create them.

Typical stops:
- **Unready Service.** A created or updated Service that never becomes Ready (F16, F54), for
  example a crash-looping revision. It landed, so close keeps the scope. Fix the configuration and
  publish a new review; it updates the same Service in place.
- **Replaced Service.** The Service was deleted and recreated outside review after the update
  landed (F56). The target is gone and close keeps the scope; the next review plans from the
  replacement.
- **Refused preflight.** An object appeared at an address the review creates (F35), or another
  field manager owns some of the object's fields (F37). The operation is refused with no effect.
  If the conflicting object is legitimately someone else's, do not delete it to make progress.
- **Refused verification.** A verification stopped ambiguous because its target was replaced
  just after it ran (F57). Resume retries it, since a verification writes nothing; a refused retry
  is journalled with no effect, and close then accepts it.
- **Terminal Job.** A scratch restore or scheduled prune Job ended terminally. It is terminal
  partial and close keeps the scope. The partial scratch database or PVC remains for a separate
  reviewed recovery; the live source is not restored automatically.

Close is idempotent. If its head write did not land, run the same command again; it only
completes the release. A closed transaction is final: resume reports it closed, and `inventory
recover` refuses any other decision for it. Add `--take-over` only after establishing that the
original executor stopped.

Version-1 decision files naming `stop-incomplete-application`, `abandon-refused-operation`,
`abandon-partial-prune`, `abandon-partial-volume-restore` or `abandon-partial-database-restore`
are aliases of close. Their operation must belong to the transaction's review.

Before ADR 26 these exits behaved differently: an abandon returned the scope to its last
converged revision and dropped completed effects from ownership. Close keeps a scope in which
anything took effect, and reverts to the review's base rather than to the converged revision.

## Other recovery decisions

If recovery also needs takeover, add `--take-over` after establishing that the
original executor stopped. For an existing bootstrap private
image credential failure, `inventory registry-recovery-plan "$TRANSACTION"
--operation "$OPERATION" --out "$PRIVATE_DECISION"` prepares its bounded proof.
Apply that exact decision through `inventory recover`; do not patch a Secret,
ServiceAccount or host unit outside its accepted authority.

Private exports made with `inventory export --out "$PRIVATE_EXPORT"` contain
reviewed native material and may contain credentials. Keep them private. Generated
Kubernetes passwords, authentication keys and backup signing keys are absent from
their reviewed templates; preserve those live values separately in the encrypted
off-cluster recovery archive. Export is evidence preservation, not permission to
replace live shared history with an older copy. See the
[recovery-material requirement](../user/backups-and-disaster-recovery.md).

## Repair configuration drift

`inventory status --json` reports a changed accepted object as
`configuration-drift`, separate from `retained-orphan`, `unowned` and the other
categories. The repair is an ordinary reviewed replan of the owning scope, for
example the same `app deploy --save-plan` that created it. When Nagare's field
manager (`nagare-inventory`) still owns every non-status field, that update
restores the reviewed bytes.

An edit made with `kubectl edit`, `kubectl patch` or another tool leaves that
tool as the field manager of what it changed. The update then stops with
`KnownNoEffect "Kubernetes object has fields managed by another writer: …"`
before any write. Close the stopped transaction with `inventory close` (see above), then decide whether Nagare should take those fields back. To take
them back, save the repair with the explicit opt-in:

```bash
nagarectl --context "$CONTEXT" app deploy -f "$CONFIG" --save-plan "$REVIEW" \
  --take-over-fields  # plus the deploy's usual reviewed inputs
nagarectl --context "$CONTEXT" inventory apply "$REVIEW" --yes
```

Planning reads the object's managed fields and records the exact foreign entries
(manager, operation and fields, without timestamps) together with the object's
UID and resourceVersion. The review summary names the managers it will take over
from. Apply proceeds only while the object has the same UID and resourceVersion
and every live foreign entry is one of the recorded ones; a new manager, or the
same manager owning different fields, refuses before writing. The write is
Nagare's usual forced server-side apply of the reviewed object. Afterwards the
object must have no foreign owner of a non-status field left; if one remains (it
owns fields the declaration does not set), the operation stops ambiguous rather
than reporting success. Without `--take-over-fields` the refusal stays, and
objects without foreign managers plan exactly as before. Saved reviews from
earlier releases keep their strict semantics. `inventory plan` does not yet accept
the opt-in (finding F37).

## Synchronize a newly protected backend

After applying a reviewed application that adds or removes a protected host,
review and apply `access portal sync`. The backend map and Shomei settings come
from all accepted contributions; synchronization rolls the accepted Shomei and
access-enforcer workloads after those maps. Both processes load their settings at
startup. The rollout preserves their images and names; it does not upgrade the
admitted platform payload.

```bash
nagarectl --context "$CONTEXT" access portal sync --save-plan "$SYNC_REVIEW"
nagarectl --context "$CONTEXT" inventory apply "$SYNC_REVIEW" --yes
```

Verify actual request behavior separately from DomainMapping readiness. A new
protected host must no longer return “no backend configured”; document requests
redirect to sign-in and API requests return 401. Browser authentication additionally
needs working HTTPS because its session cookies are Secure. The current fresh
fixture has no HTTPS listener, so browser sign-in is unaccepted even if the HTTP
route and En grant/revoke checks pass.

The bounded native access proof uses the stable endpoint
`http://127.0.0.1:19463`. Its fault-injection proxy has stopped; a direct local En
port-forward can expose that same endpoint for ordinary inspection. Keep that URL
for its accepted relationship scope. Use the context's private read-write key
through environment input, never in command arguments or a saved review.

## Known cloud timings

These are observed installed-command times, not service-level promises. The
[retained interruption/second-root proof](../audits/mp23-archive/mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json)
uses candidate `2101b834` on `ep150-preview`, preserving payload `6082dbd6`.

| Command or boundary | Observed time |
| --- | ---: |
| Fresh operator root reads shared head | 4.836 s |
| Recover its accepted private kubeconfig | 18.747 s |
| Refuse another active executor | 11.295 s |
| Explicit takeover and original backup resume | 23.858 s |
| Save the two-operation backup review | 24.804 s |

The historical `4c4b667e` run on now-retired `f15-preview` measured manual backup
planning at 20.019 seconds and apply at 79.941 seconds, isolated restore planning
at 20.992 seconds and apply at 36.096 seconds, foreign executor refusal at
14.090 seconds, and second-root explicit takeover/resume at 24.243 seconds.
The latter resumed the original third Job with its exact UID; no replacement Job
was created. These checks do not establish another engine or volume procedure.

The [fresh F15 stage report](../audits/mp23-archive/mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json)
separately records original-payload image publication (249.546 s), image binding
(37.798 s), VM creation (51.569 s), guarded host operations (86.780 s), and private
kubeconfig installation (13.778 s). Fresh cluster convergence passed in 1,284.026
seconds on `71288437`: 22 exact scopes converged with 31 Ready workloads and two
Succeeded migration Pods. The expired boot registry token returned 401, the timer
refreshed all three owned Secrets, and an authenticated native re-pull passed
without a k3s restart or cache eviction. These accepted checks are preserved across
the narrowly changed operator candidate. Check measured provider work and journal
progress before interpreting a long command as an operator crash.

## Supported recovery and remaining constraints

Scheduled backup keep-N/expiry retention is unenforced. Archives grow until a
supported separately reviewed disposal is applied; a receipt or expiry timestamp
does not prove deletion. Manual backup pruning and snapshot pruning bind exact
accepted receipts, object versions and dependencies. Retained data and unresolved
operations block disposal. Read the [backup procedures](../user/backups-and-disaster-recovery.md)
before selecting any archive for deletion.

MP-23 does not support an in-place platform-version upgrade after inventory
admission. Preserve the accepted payload during maintenance and recovery.
Database and volume restores use isolated destinations; they do not provide an
automatic application cutover or live overwrite. The PostgreSQL procedure creates a
new logical database within the accepted PostgreSQL instance/PVC; it does not
provision a separate instance or storage volume. The bounded fixture restore name
is `mp23-f15-pg-a_restore_mp23f15pgav1`, and the original database remains intact.
The installed receipt-only path now accepts a reviewed `verified-v1` manual
record with exact GCS object/receipt generations and hashes. Its producer Job
may be collected only in a separate UID-bound review. A new isolated restore
then rechecks the pinned stored bytes without reading the removed Job/Pod.
`mp23f15pgav3` returns the original backed-up row after primary Job collection.
Keep the accepted receipt record, original collection tombstone and both GCS
objects. Failed `mp23f15pgav2` never started PostgreSQL; its failed Job remains
preserved for separate reviewed recovery.

Scope retirement retains resources; collection is a separate reviewed command.
Release-history ConfigMaps keep their web dependency edges. A saved policy
review can change a legacy stateless history member to `DeleteWhenUnreferenced`;
retirement retains objects, and a separate history collection must precede
Service collection. Application B's exact history collection is accepted, and
its nine database members remain retained. The retired F15 Orphan review left a terminating Service because the Knative
webhook rejected orphaned Route/Configuration objects. Its record remains a
failure; current collection uses explicitly reviewed descendant authority below. Eligible completed Job
collection remains accepted and preserves source data.
New custom interactive mutating maintenance and generalized scheduled pruning remain unavailable. Existing
admitted historical operations retain their evidence-bound recovery paths.

Real low-risk workloads remain gated on fresh-context operational evidence,
installed reviewed access, exact rehearsal cleanup and independent F14–F18 runbook execution. Full release acceptance additionally requires the remaining native-system,
feature and immutable-evidence gates in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md).

## Reviewed controller collection

Explicit descendant authority for Knative Service collection has local interpreter,
public CLI and bounded native proof on installed `8a820ce8`. Independent F20
verification and native same-scope retained-data coverage remain. The option
cannot amend an already-issued Orphan review.

After normal dependency checks and retirement, prepare a separate review for one
eligible Service:

```bash
nagarectl --context "$CONTEXT" inventory collect --resource "$RESOURCE_ID" \
  --controller-descendants --out "$REVIEW"
```

Inspect its summary before applying through the normal saved-review procedure.
It authorizes Background GC of exclusive controller descendants, including later
children. A graph snapshot does not restrict Kubernetes GC to an atomic fixed UID
list; this assumes trusted controllers and namespace writers. Preparation requires
complete API discovery/list access and refuses unsupported or independently owned
children. Missing access or incomplete lists are errors, not evidence of absence.

Apply can remain unresolved after the parent disappears. Resume the original
transaction: completion also checks recorded descendants, observed new reachable
children and protected inventory identities. Do not issue a replacement review or
repeat DELETE to accelerate finalization. See the [proof and limitations](../audits/mp23-archive/mp23-reviewed-controller-collection-proof.md).

## Retired prerelease checkpoint — not a recovery task

The [fixture disposition](../audits/mp23-prerelease-fixture-disposition.md) records
F15 generation 752/sequence 673 and its unresolved transaction. Its exception
proposal is withdrawn from execution. No successful recovery, finalizer change,
history reset or physical teardown is claimed. EP-156 owns non-blocking scoped
teardown after checking actual ownership and preserving private diagnostics.
These resources do not have to be recovered to complete this runbook elsewhere.

Installed historical proof establishes application/configuration isolation,
HTTP access/grant/revoke recovery, shared-history resume/takeover and credential
recovery, verified GCS manual receipts and Job-free isolated PostgreSQL restore,
and completed-Job/history collection. The corrected candidate also has bounded
native controller collection and interruption/recovery proof. Reuse evidence
only where its candidate and input bindings remain applicable.

Finish candidate-bound retained-data collection coverage, protected HTTPS/browser
support disposition, and independent F14–F18 runbook execution. Remaining
engine/volume/CDN/command/native-system/release requirements remain. General live
overwrite/promotion, custom interactive mutating maintenance, generalized
scheduled pruning and admitted-context platform upgrades stay deferred.
Safe-use acceptance is pending; remaining implementation continues through
steps 5–6 without waiting for recovery of the retired fixture.


## Staged cloud teardown acceptance

Use a new disposable current-payload perimeter for this proof. Preserve the accepted host/application
fixtures and their retained diagnostic transactions. Save and apply `infra destroy --save-plan DIR`
stages separately: policy verification, retained retirement, then exact leaf collection. Record
accepted revisions and native IDs before each stage. Policy and retirement must send no native
mutation. Each collection must contain exactly one selected delete and an immutable saved Pulumi
plan; all other native registrations, retained dependencies, durable disks, backup/image buckets,
credentials, IAM, foundation, provider and stack authority remain unchanged. Repeat until no eligible
leaf remains, then verify the reported retained set rather than asserting total deletion.

Test old-payload refusal, unresolved/protected VM refusal, an active or retained dependency refusal,
and component omission with an unselected child. Simulate acknowledgement loss after one exact
collection, then resume the original review: prove absence with no second delete. Repeating an
already completed review must preserve later state. Later collection plans must omit earlier tombstones
without recreating them. Candidate-bound independent native acceptance is required before marking
this command's coverage complete.
