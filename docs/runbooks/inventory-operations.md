# Operate and recover a reviewed inventory

This runbook covers an inventory-admitted context. Its command interfaces and
retained-cloud measurements are established; the operator's complete run on the
fresh `f15-preview` context is still pending. That run must verify findings
[F14–F18](../audits/mp23-findings.md) before safe-use acceptance. Bootstrap success
alone does not establish that gate.

## Select the private context

Use the installed candidate and the context's private configuration, state and
cache roots. Set `CONTEXT`, `PROJECT`, `GCLOUD_CONFIGURATION` and `OPERATOR_ROOT`
to the intended fixture. For the current fresh rehearsal these are `f15-preview`,
`tan-ng-labs`, `labs`, and the retained private rehearsal root.

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

If recovery also needs takeover, add `--take-over` after establishing that the
original executor stopped. Supported terminal scratch-restore abandonment leaves
the partial scratch database/PVC available for a separate reviewed recovery; it
does not restore the live source automatically. For an existing bootstrap private
image credential failure, `inventory registry-recovery-plan "$TRANSACTION"
--operation "$OPERATION" --out "$PRIVATE_DECISION"` prepares its bounded proof.
Apply that exact decision through `inventory recover`; do not patch a Secret,
ServiceAccount or host unit outside its accepted authority.

Private exports made with `inventory export --out "$PRIVATE_EXPORT"` contain
native credentials and recovery material. Keep them private. Export is evidence
preservation, not permission to replace live shared history with an older copy.

## Known cloud timings

These are observed installed-command times, not service-level promises. The
[retained interruption/second-root proof](../audits/mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json)
uses candidate `2101b834` on `ep150-preview`, preserving payload `6082dbd6`.

| Command or boundary | Observed time |
| --- | ---: |
| Fresh operator root reads shared head | 4.836 s |
| Recover its accepted private kubeconfig | 18.747 s |
| Refuse another active executor | 11.295 s |
| Explicit takeover and original backup resume | 23.858 s |
| Save the two-operation backup review | 24.804 s |

The [fresh F15 stage report](../audits/mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json)
separately records original-payload image publication (249.546 s), image binding
(37.798 s), VM creation (51.569 s), guarded host operations (86.780 s), and private
kubeconfig installation (13.778 s). Cluster convergence and credential
expiry/re-pull on this fresh context are pending. Check measured provider work
and journal progress before interpreting a long command as an operator crash.

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
automatic application cutover or live overwrite. New custom interactive mutating
maintenance and generalized scheduled pruning remain unavailable. Existing
admitted historical operations retain their evidence-bound recovery paths.

Real low-risk workloads remain gated on fresh-context operational evidence,
installed reviewed access, exact rehearsal cleanup and the operator's F14–F18
run. Full release acceptance additionally requires the remaining native-system,
feature and immutable-evidence gates in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md).
