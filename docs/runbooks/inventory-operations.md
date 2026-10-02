# Operate and recover a reviewed inventory

This runbook covers an inventory-admitted context. Its command interfaces and
retained-cloud measurements are established; the operator's complete run on the
fresh `f15-preview` context is still pending. That run must verify findings
[F14–F18](../audits/mp23-findings.md) before safe-use acceptance. Bootstrap success
alone does not establish that gate.

The current frozen operator is `4c4b667e867b0ed1a732fe9a0839f4a09bfa0f5c`.
Use `result-mp23-4c4b667e/bin/nagarectl` from the repository and check
`version --json` before a provider command. Preserve admitted payload
`nagare-0.4.0-d73c1dc4d379`; the operator revision is separate from that payload.
The original private root is `/tmp/nagare-mp23-fresh-credentials-20260930`;
the recovered second root is `/tmp/nagare-mp23-f15-second-root-71288437`.
Neither root is a substitute for shared GCS history.

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

Before an expensive native command on the frozen `f15-preview` fixture, bind
the CLI to the **accepted payload workspace**, not the changing source checkout
or the CLI wrapper's newer default payload. The preflight validates the actual
workspace assets locally, the executable revision, and the exact idle GCS head.
It takes about five seconds on this fixture and performs no provider mutation.
Run it again with the next review's accepted head generation and digest after
each completed transaction; do not replace those expected values with whatever
the current store happens to report.

```bash
export NAGARE_PLATFORM_ROOT="$XDG_STATE_HOME/nagare/$CONTEXT/platform/nagare-0.4.0-d73c1dc4d379-550cec502a657ad7"
scripts/inventory-candidate-preflight.sh \
  ./result-mp23-4c4b667e/bin/nagarectl "$NAGARE_PLATFORM_ROOT" \
  f15-preview tan-ng-labs 4c4b667e867b0ed1a732fe9a0839f4a09bfa0f5c \
  nagare-0.4.0-d73c1dc4d379 \
  550cec502a657ad7131343046c27ea4160b8282a4b50c0f0e8755b728f5be1bd \
  722 6ad148e41d8946716fe9289f5f22a6c503c30a37f651e26a3b6cb39344597158
```

The exact command above passed at idle generation 722 before the receipt-only
restore. It is a historical checkpoint and must refuse against the current
active generation 752. Do not replace its expected head with an observed value
to bypass that refusal. The current recovery checkpoint below is authoritative. The
preflight does not replace saved-review, operation-count, native UID, or
neighbor-revision checks before an apply.

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
[retained interruption/second-root proof](../audits/mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json)
uses candidate `2101b834` on `ep150-preview`, preserving payload `6082dbd6`.

| Command or boundary | Observed time |
| --- | ---: |
| Fresh operator root reads shared head | 4.836 s |
| Recover its accepted private kubeconfig | 18.747 s |
| Refuse another active executor | 11.295 s |
| Explicit takeover and original backup resume | 23.858 s |
| Save the two-operation backup review | 24.804 s |

The current frozen operator on fresh `f15-preview` also measures manual backup
planning at 20.019 seconds and apply at 79.941 seconds, isolated restore planning
at 20.992 seconds and apply at 36.096 seconds, foreign executor refusal at
14.090 seconds, and second-root explicit takeover/resume at 24.243 seconds.
The latter resumed the original third Job with its exact UID; no replacement Job
was created. These checks do not establish another engine or volume procedure.

The [fresh F15 stage report](../audits/mp23-native-bootstrap-results-2026-09-30/f15-cloud-sequence-rehearsal.json)
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
its nine database members remain retained. Knative Service collection is still
unaccepted: `Orphan` propagation leaves a terminating Service because the
Knative webhook rejects orphaned Route/Configuration objects. Never treat that
pending parent deletion as a collection tombstone. Eligible completed Job
collection remains accepted and preserves source data.
New custom interactive mutating maintenance and generalized scheduled pruning remain unavailable. Existing
admitted historical operations retain their evidence-bound recovery paths.

Real low-risk workloads remain gated on fresh-context operational evidence,
installed reviewed access, exact rehearsal cleanup and the operator's F14–F18
run. Full release acceptance additionally requires the remaining native-system,
feature and immutable-evidence gates in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md).

## New controller collection reviews — source candidate

The source candidate adds explicit descendant authority for future Knative Service
collection. It has passed local interpreter and public CLI fixtures; native
controller agreement is still pending. This option is unavailable on the frozen
operator above and cannot amend its already-issued review.

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
repeat DELETE to accelerate finalization. See the [proof and limitations](../audits/mp23-reviewed-controller-collection-proof.md).

## Current recovery checkpoint — 2026-10-02

Shared generation 752/sequence 673, digest
`28b5d60e438d80d7d8e9e4cf3b1156f4ed64637d772d73513e8baff864e7dc48`, keeps
transaction `tx-b6886179d40d4618442997221cc02ca986f142ccdeef1661448cfca627765472`
active at operation `op-396d4879c0759fe3f69b9852`, without claim, fence or migration.
The original Knative Service UID `80560c4d-6bd8-4fe4-9c55-e67620554924` remains
terminating with `orphan`; its retained entry is authoritative. Stop new
reviews, admission and blind resume. [F20](../audits/mp23-findings.md#f20) owns
the missing collection contract.

[The exception proposal](../audits/mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json)
records the parent UID/resourceVersion, sixteen controller descendants observed
across all listable namespace APIs and nine protected database incarnation UIDs.
It requests Background propagation instead of the original Orphan boundary;
that change can collect descendants, and the accepted Service declares no
controller delegation. Obtain explicit operator approval before broadening the
issued effect. Recheck every recorded guard immediately before any approved
forward recovery, then resume the original transaction only after exact parent
absence. No exception effect or finalizer patch has run. A one-off exception
does not establish future supported Knative collection. Kubernetes documents
[background cascading deletion](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
and [finalizer handling](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/).

The live server is `v1.35.8+k3s1`. Its UID/resourceVersion-bound Background DELETE
passed server-side dry-run with `dryRun=All` in both the body and URL; the parent
resourceVersion/finalizer and inventory head remained unchanged. This validates
request acceptance, not actual finalization. The upstream
[custom-resource storage strategy](https://github.com/kubernetes/kubernetes/blob/v1.35.8/staging/src/k8s.io/apiextensions-apiserver/pkg/registry/customresource/etcd.go)
uses the generic store without a graceful-delete strategy; its
[GC deletion path](https://github.com/kubernetes/kubernetes/blob/v1.35.8/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go)
can replace the GC policy through DeleteOptions here. An approved request would
let the API server adjust its GC finalizer as part of normal deletion; manual
finalizer edits remain excluded. Recheck observations after the request and stop
on any new controller/admission failure without inventing another effect.

Installed proof establishes reviewed application/configuration isolation and
HTTP access/grant/revoke recovery, shared-history resume/takeover and credential
recovery, verified GCS manual receipts and Job-free isolated PostgreSQL restore,
and exact completed-Job/history collection. Web cleanup, protected HTTPS/browser
login, separate failed-Job recovery and the operator's end-to-end F14–F18 check
remain open. General live overwrite/promotion, custom interactive mutating
maintenance, generalized scheduled pruning and admitted-context platform upgrades
remain deferred. Remaining engine/volume/CDN/command/native-system/release gates
retain their existing requirements. MP-23 steps 3/4 are incomplete and step 5
has not started. Independent tracker closure remains open for F02–F10 and
F12–F20.
