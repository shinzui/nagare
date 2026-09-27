---
id: 160
slug: complete-fenced-live-data-restore-across-supported-engines-and-volumes
title: "Complete fenced live data restore across supported engines and volumes"
kind: exec-plan
created_at: 2026-09-26T22:14:13Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T22:14:13Z
  revisions:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T04:11:42Z
      mode: "implement"
      note: "Started durable data-fence protocol and identified engine backup format gaps"
---

# Complete fenced live data restore across supported engines and volumes

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture


An operator can restore PostgreSQL, Redis, ClickHouse, and application volumes through reviewed operations, including an existing live target. Writers are stopped and their exclusion is proved before data changes; failure leaves a recoverable, visibly fenced target rather than silently reopening it.


## Progress


- [ ] M1: A shared durable data-fence contract binds exact target identities, excludes managed writers, survives process loss, and requires verified recovery before releasing admission.
- [ ] M2: Reviewed scratch and live-target restore work for PostgreSQL, Redis, and ClickHouse with integrity checks, explicit recovery, and wrong-incarnation refusal.
- [ ] M3: Reviewed live-target volume restore preserves exact PVC identity and writer exclusion, with content verification and interruption recovery.

Inherited: manual receipts and expiry validation, PostgreSQL scratch restore, and separate-PVC scratch volume restore are implemented. Live --into-live volume behavior was removed pending a safe replacement. These delivered scratch paths remain regression baselines, not new milestones.

2026-09-26 work in progress: the private head now carries a conditionally written data-fence record, normal planning/apply and store migration reject an active fence, and read-only status displays its phase and exact identities. `Nagare.Inventory.DataFence` reserves before invoking writer controls and keeps uncertain acquisition, data change, or release visible. Three focused recording-provider tests cover process reopening, target substitution, and lost release acknowledgement; the 15 selected restore tests and transaction selection pass. M1 remains open: no native Kubernetes/database control implements the provider callbacks yet, and no reviewed live restore invokes the fence.

2026-09-26 protocol correction: the fence record now optionally binds the exact active reviewed transaction. A transaction may acquire only its own fence under its executor claim and client identity; convergence cannot be journaled or clear that transaction while its fence remains. Focused cases cover mismatched transaction/client refusal, matching acquisition, and a reviewed transaction stopped before its convergence event while fenced. Standalone maintenance remains possible with no active transaction. This resolves the initial head-state conflict before any restore effect is wired.

2026-09-26 resume guard: ordinary transaction resume and adapter-recovery decisions now refuse while a data fence is active, including one linked to the same transaction. An explicit fence recovery path must observe the provider and clear the fence first; the reviewed transaction may then resume without blindly replaying a possibly completed restore. The focused test reopens the stopped transaction and checks that refusal.

2026-09-26 shared-history check: a recording-provider test now opens two inventory clients over one conditional object backend. The first persists a fence; the second reads the same phase and session and refuses a previously saved review without invoking its adapter. This exercises the cross-state-root store contract locally, but is not a live GCS bucket run.

2026-09-26 release-recovery correction: the provider now distinguishes fully released writers, definitely untouched writer controls, and partial release. A fresh process can resume the release only from the definitely untouched state; a partial release remains fenced for forward recovery. Focused tests cover an interruption before any release effect and a partial release without duplicate control calls. M1 still needs native implementations of these observations.

2026-09-26 native mount-guard renderer: `Nagare.Inventory.DataFence.MountGuard` now produces deterministic fail-closed `ValidatingAdmissionPolicy` and binding objects for an exact namespace/PVC UID. A Pod permit requires the authenticated controller principal and exact owner kind/name/UID. In a new disposable k3d v1.32.5 cluster, `k3d-nagare-data-fence-ep160b`, the generated policy denied an actual foreign Pod and a direct Pod spoofing the exact restore Job owner reference; the Job controller created its Pod and completed. StatefulSet release was denied until a permit for `system:serviceaccount:kube-system:statefulset-controller` and StatefulSet UID `4039f8e8-eeb1-494d-aebe-bb9b61174d9d` was added. The original StatefulSet then returned to one ready replica while a foreign mount remained denied. PVC UID was `6f04d8ec-3079-4111-a561-62f310dfe226`; generated policy UID was `ab79c7ab-4104-4701-aa08-83213a091985`. The dedicated cluster was deleted. This proves the generated policy on local k3s, but M1 remains open: reviewed native create/observe/drain/release controls, policy drift protection, engine-native writer checks, and supported-provider proof are not wired.

2026-09-26 native identity-guard extension: a second disposable `k3d-nagare-data-fence-ep160c` cluster exposed a deletion bypass: a PVC UPDATE/DELETE policy denied direct claim mutation, but `kubectl delete namespace ep160-fence-probe --dry-run=server` still succeeded. The renderer now also emits fail-closed PV UPDATE/DELETE and Namespace DELETE policies. Against PVC UID `3f6c6ef8-6920-488e-ad49-cf55591b3f40` and bound PV UID `6dcff572-9caa-48a9-8f77-bc6d29da7650`, generated policies denied server-dry-run PVC update/delete, PV update/delete, and namespace delete. The cluster was deleted. These guards have no native lifecycle integration yet and cannot themselves prevent an authorized actor from changing the policies or bindings; provider observation and RBAC boundaries remain necessary.

2026-09-26 reviewed-runner integration: an adapter can register a pure optional fence selector. A saved review now binds its capability and the canonical digest of the complete private fence request, plus a separate public fence summary. Admission refuses a missing capability or changed target identity before native effects. The transaction runner acquires and proves exclusion before an adapter effect, verifies data and releases writers before journaling completion, and leaves an ambiguous effect visibly fenced; focused recording-provider tests cover the successful sequence, capability/target substitution, and lost effect acknowledgement. This is the generic runner contract only. No production Kubernetes adapter registers native fence controls yet, so M1 remains open.

2026-09-26 native guard lifecycle: `Nagare.Inventory.DataFence.MountGuardRuntime` installs the four policy/binding pairs through an explicit, guarded Kubernetes context, refuses a preexisting policy with changed spec or identity annotations, and reobserves all eight objects plus a server-side foreign-Pod admission denial. A restart recording-transport test covers partial installation and policy drift. In disposable `k3d-nagare-ep160-runtime` (k3s v1.32.5), the first observer correctly refused Kubernetes-defaulted policy specs; the renderer was corrected to state those defaults explicitly, after which install and observed denial succeeded. Patching the Pod policy expression to `true` made a new process refuse installation and report false observation. The cluster was deleted. This is native mount-admission evidence only: RBAC against guard changes, writer/attachment drain, database controls, and production adapter registration remain open for M1.

2026-09-26 exact volume observation: `Nagare.Inventory.DataFence.VolumeState` now rechecks the PVC/PV names and UIDs, Bound status, claim reference, access mode, and exact CSI handle or local path and node affinity. It counts any remaining Pod with the PVC and any VolumeAttachment intent for the PV, including an attachment that reports detached. Guard observation brackets these reads; a missing or changed guard returns no exclusion proof. Focused tests cover replaced PVC, changed CSI handle/local node, Pod and attachment consumers, and guard loss during observation. In disposable `k3d-nagare-ep160-volume` (k3s v1.32.5), the guarded observer saw an existing writer Pod on local-path PVC UID `3daa00c7-fb13-46da-a9ea-3824da1777f9`, PV UID `76342d7b-7c75-4a20-8443-2dc76f1a8e25`, and then no consumers after the Pod was deleted. The first guard check after creation returned false while admission propagated; a later check proved denial. The cluster was deleted. Kubernetes documents that `ReadWriteOnce` can still admit multiple Pods on one node and that VolumeAttachment represents attach intent ([Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/), [VolumeAttachment API](https://kubernetes.io/docs/reference/kubernetes-api/storage/volume-attachment-v1/)). M1 still needs controller quiescence, admission drift authority boundaries, database write exclusion, and production registry wiring.

2026-09-26 StatefulSet writer control: `Nagare.Inventory.DataFence.StatefulWriter` now binds exact namespace/name/UID and saved replica intent, issues API-server JSON Patch tests for UID, resourceVersion, and current replicas before scaling, and separately observes controller generation and zero-replica convergence. Release refuses while zero-replica convergence is incomplete and distinguishes still excluded, partial release, and fully ready saved intent. A recording transport covers lost patch acknowledgement, restart, premature release refusal, and replaced UID. On disposable `k3d-nagare-ep160-writer` (k3s v1.32.5), the conditional stop of StatefulSet UID `e78c4705-be93-4cf8-8d84-cb5827e044b7` succeeded; three seconds later the controller was still draining, so release was refused. After the Pod drained, observation proved zero replicas, restoration succeeded, and the original ready replica returned. The cluster was deleted. This control is not registered as a production fence provider and does not cover Deployment/CronJob clients or database-native exclusion, so M1 remains open.

2026-09-26 accepted writer discovery: `Nagare.Inventory.DataFence.WriterInventory` now walks accepted dependency edges from the exact target and scans immutable native Pod templates for a direct PVC mount. It names Kubernetes writer candidates, refuses malformed/missing native evidence, and refuses a discovered Deployment, CronJob, Job, DaemonSet, Helm release, or other unsupported controller until a real stop control exists. A focused fixture finds a database-dependent Deployment and an independently mounted Job while leaving an unrelated Deployment untouched. This is the reviewed candidate set only; it has not been wired to native provider callbacks or proved exhaustive for every service route and external client, so M1 remains open.

2026-09-26 native probe: a dedicated `k3d-nagare-data-fence-ep160` cluster (k3s v1.32.5) used namespace `ep160-fence-probe`, StatefulSet UID `dbe60801-35ee-42ff-b9bc-e645b06816d7`, and PVC UID `1bfb6d23-1aea-4582-bc18-d951e7258a27`. A JSON Patch testing the StatefulSet UID and resourceVersion then setting replicas to zero was accepted once; the same stale patch was rejected. After its Pod was observed deleted, a separate Pod mounted the same `ReadWriteOnce` PVC and wrote `foreign` to its file. A fail-closed `ValidatingAdmissionPolicy` denied that new mount. An exception based only on the restore Job owner reference was spoofable; combining the exact suspended Job UID with the authenticated `system:serviceaccount:kube-system:job-controller` principal denied the spoof and allowed the Job Pod to complete and read `foreign`. These are direct k3s observations from temporary manifests under `/tmp/nagare-ep160-*`, not a public reviewed-command fixture or proof for GKE. The disposable cluster was deleted after the probe.


## Surprises & Discoveries


2026-09-26: `cli/nagarectl/src/Nagare/Database/Backup.hs` currently concatenates ClickHouse `FORMAT Native` table streams without table names or DDL. The legacy ClickHouse restore renderer only creates a database, so those bytes cannot establish a restored table set. The Redis backup is a whole-instance RDB; the legacy preview's `redis-cli --pipe` cannot load that format and masks a failed command. Both require distinct, verified native procedures before M2 can be accepted. See [ClickHouse's Native format explanation](https://clickhouse.com/resources/engineering/read-clickhouse-native-file) and [Redis persistence documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/).

2026-09-26: The local-path `ReadWriteOnce` claim admitted a second same-node Pod after the managed writer stopped. An admission rule that permits a Pod by copying its Job owner UID also admits a spoof from a direct Pod creator. The actual k3s Job controller principal is a service account, not `system:kube-controller-manager`; a tested rule required both that principal and the exact suspended Job UID. This needs provider-version and managed-policy drift checks before it becomes a production fence. Kubernetes documents `ValidatingAdmissionPolicy` as stable from v1.30 and exposes `request.userInfo` to its CEL rules: [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/).




## Decision Log


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.

2026-09-26: Version the ClickHouse backup format so a restore can recover table identity and schema, and refuse older content-only receipts for reviewed restore. Redis RDB restore must load offline into a stopped instance with exact PVC and writer-exclusion proof; a network client command is not sufficient. This follows from the existing backup bytes and keeps unknown data effects fenced.

2026-09-26: An exact, fail-closed Pod admission guard is required for a live PVC while recovery is active; `ReadWriteOnce` and a scaled-down StatefulSet do not close the mount race. The native probe supports a policy tied to target namespace/PVC and an explicitly suspended restore Job's UID plus controller principal. Treat that mechanism as a candidate until its policy and binding are themselves reviewed, observed, protected against drift, and shown to work on every supported Kubernetes provider. Reforecast M1–M3 at 24–48 active hours, low confidence, after this mount-control discovery.

2026-09-26: A live restore fence must coexist with its own reviewed inventory transaction, while blocking all other transactions. Bind it to the active transaction and keep that transaction unresolved until the fence is verified and released. A standalone fence with no transaction remains available to maintenance. The first draft's mutual exclusion would have made reviewed restore unreachable.

2026-09-26: A persisted `FenceReleasing` phase can precede any native release effect if the process dies at that boundary. Recovery may reissue writer restoration only after the provider proves no release effect started; if controls changed partly, keep the fence unresolved. A Boolean "released" observation lacked the information needed to distinguish these cases.

2026-09-26: Keep the PVC mount guard active while releasing a StatefulSet writer. Its Pod may be admitted only under a separately reviewed permit binding the authenticated StatefulSet controller principal and exact StatefulSet UID; deleting the guard before writer restoration would open a foreign-mount race during an uncertain release. Controller principals are provider facts to probe, not constants inferred from owner references.

2026-09-26: A complete Kubernetes volume fence must protect the Pod mount path, PVC, bound PV, and namespace deletion path. A PVC-only admission rule did not block namespace deletion in a server dry-run. The bound PV UID and volume handle must be observed as part of the exact physical target before any data effect.

2026-09-26: Bind the entire private fence intent to the immutable review with a canonical digest, independently of the adapter capability identity. A capability label alone would allow an apply-time hook to substitute target UIDs or recovery artifacts while still matching the saved review. Keep the human-readable fence summary separate from the adapter's prepared input so adding review text cannot change provider behavior.


## Outcomes & Retrospective





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership, exact reviewed effects, and full release acceptance despite this split. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A refusal protects an unfinished feature but cannot count as its completion.

cli/nagarectl/src/Nagare/Inventory/Restore.hs provides ManualRestoreRequest, compileManualRestoreScope, and compileVolumeRestoreScope. cli/nagarectl/src/Nagare/Database/Restore.hs and cli/nagarectl/src/Nagare/Storage/Restore.hs render the current bounded native restore Jobs. cli/nagarectl/src/Nagare/Inventory/Backup.hs parses checked receipts; cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs and cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs enforce native UID and receipt checks. cli/nagare-dsl/src/Nagare/Dsl/Database.hs defines the three supported engines. Existing scratch restore does not establish an exclusive live-target fence.

A data fence is durable permission state plus observed provider controls that prevent writers from changing a selected target during recovery. The inventory writer lock serializes CLI transactions; it does not stop applications, CronJobs, interactive clients, or already-running Pods. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) requires a recovery position before write admission and forbids pretending an irreversible schema/data change has automatic rollback. Reuse that safety principle without depending on completion of the separate replacement-upgrade initiative.


## Plan of Work


M1 owns the shared implementation in new cli/nagarectl/src/Nagare/Inventory/DataFence.hs and any required typed additions in cli/nagare-dsl/src/Nagare/Resource. The durable fence record binds context, operation/session ID, accepted scope revisions, exact StatefulSet/PVC identities, complete affected-resource set, recovery artifact references, saved writer configuration, and current phase. Phases distinguish acquisition, proved exclusion, active data change, verification, release, and unresolved recovery. Persist transitions through the existing store and journal under their lock; do not add a second session database, TTL auto-unlock, or daemon. Command admission and prune checks must reject conflicting work while the record is active, including after process death and from another state root using GCS history.

Before mutation, enumerate accepted workloads, schedules, hooks, and other managed clients that can write the target. Apply reviewed controls to stop/quiesce them, drain in-flight work, and prevent controller recreation or new connections. Database-native connection/write exclusion and workload/network controls must be established from observed provider facts; a CLI lock, scale-to-zero request without observation, or an advisory database lock is not enough. Volume recovery must account for every mounted writer and attachment. Preserve original writer configuration for a separately verified release. Unsupported or unknown writer control refuses before data mutation and remains an explicit unfulfilled case, not a completed live restore. Fence acquisition may remain in progress across bounded reviews where new provider facts are required. Define and test recovery after each transition before adding engine effects. Expose opaque acquire/verify/recover/release operations consumed by maintenance; callers cannot fabricate a fence proof.

M2 extends the current saved-review restore command and Jobs to PostgreSQL, Redis, and ClickHouse, including their scratch isolation and live-target modes. Bind the exact backup receipt, current object version/digest, accepted target revision and physical identities, engine/format compatibility, and recovery requirements. Require a verified pre-change backup or a still-valid rollback target before overwriting live data. Reuse the existing manual source first; consume EP-159 scheduled receipts through the same verified selector once available. Engine-specific restore execution must stay inside the proved fence, verify known content and engine health, and only then permit an explicit release that restores prior writer intent. A changed target, expired or corrupt source, failed restore, lost response, or incomplete verification keeps the fence and requires forward recovery. Do not drop/recreate an uncertain database merely to retry. The distinct engine procedures and their postconditions belong in fixtures and user docs, not a generic success-on-Job-exit rule.

M3 restores into an exact accepted live PVC with all writers stopped and attachment state verified. Reuse the existing archive/receipt checks and scratch restore when preparing recovery. Capture the pre-change recovery position, validate archive entries before extraction, and compare known file content after restore. Do not reinterpret a new scratch PVC as successful live-target restoration. Preserve target identity and any retained source/recovery data. A partial extraction remains fenced until an explicit reviewed recovery and verification succeeds.

Extend cli/nagarectl/test/InventoryTransactionSpec.hs and cli/nagarectl/test/InventoryKubernetesSpec.hs, adding a focused DataFenceSpec.hs test group and Cabal/Spec registration. Test each transition with injected failure, live and scheduled writer interference, second-process admission, and source/target substitution. Each engine and live volume need targeted native content/recovery proof. EP-155/156 may provide those runs without a closure prerequisite; final acceptance cannot use recording-only restore success.


## Concrete Steps


Run from the repository root in the existing development environment. A newly named test group must be registered and run at least one test; zero selected tests is not passing evidence. No provider mutation is part of these initial checks.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p restore' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p transaction' --test-show-details=failures)
# New DataFenceSpec group, required before milestone M1 acceptance:
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p "data fence"' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
```

Expected result: selected tests and build exit zero; refusal fixtures prove zero unintended effects. At a milestone boundary also run the affected full suite, `bash scripts/check-haskell-style.sh`, and, when user docs change, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`. Add exact public-command native fixture invocations with their saved review paths before recording acceptance.


Keep the current restore commands and implement their reviewed live-target mode. The new `--recovery-backup` input names a verified pre-change recovery artifact distinct from the selected restore source, unless the accepted recovery policy proves the same artifact is sufficient. The following are required interfaces after implementation, against an explicitly selected disposable context:

```bash
nagarectl db restore "$DB" "$BACKUP_ID" --restore-id restore-fixture-1 --into-live --recovery-backup "$RECOVERY_ID" --save-plan "$REVIEW"
nagarectl storage restore "$APP" "$VOLUME" "$BACKUP_ID" --restore-id volume-fixture-1 --into-live --recovery-backup "$RECOVERY_ID" --save-plan "$VOLUME_REVIEW"
```

Use a separate review for each fixture. Planning must display source, target, affected writers, recovery reference, and fence/release steps without mutating them. Apply only the inspected saved review with `nagarectl inventory apply "$REVIEW" --yes`; any required staged follow-up review is explicitly linked to the same recovery identity. Read-only inventory status reports an active/unresolved fence. Recovery and fence release use the existing explicit recovery/review boundary, with exact syntax documented when that integration is implemented.

## Validation and Acceptance


Use disposable databases containing known rows/keys and a PVC containing known files. Back up, change the live content, acquire a reviewed fence, restore, and prove the backed-up content and expected native identity before reopening writers. Run this for all three engines and the volume path. Prove a competing writer cannot write during recovery, and that unrelated application and platform revisions remain fixed. Scratch restores must remain isolated from their source.

Kill the operator or lose the acknowledgement at fence acquisition, after data mutation, during verification, and before release. A fresh process must see the exact unresolved record, refuse conflicting apply/prune/maintenance, and recover without a second destructive restore. Missing or wrong-incarnation backups, changed PVC/StatefulSet identity, failed client drain, foreign mounts, and corrupt archives refuse safely. Restore success requires verified data and the recorded writer-release outcome; no unknown effect can be reported as completed.

Use focused tests while implementing one coherent milestone, then the affected full suite/build and documentation checks at its acceptance boundary. Repeat broad gates only after a relevant change or failure. Record the exact command, candidate revision, review/transaction IDs, fixture identity, result, and evidence location. Distinguish recording-provider tests from real provider evidence. Shared integration runs may supply the same assertion to several plans; do not wait for administrative plan closure to run them. Keep Progress checkboxes directly under Progress, without nested headings.


## Idempotence and Recovery


Use isolated test state and exact disposable resource identities. Retain the saved review, private native members, and journal after failure. Reuse an operation ID only with identical accepted intent; changed input requires a new review. Unknown provider results remain unresolved until observation proves what happened. No blind replay, broad prefix cleanup, history reset, or automatic data rollback is allowed. This plan authorizes implementation and its bounded verification, not a real release publication. Use Mori to locate dependency sources before relying on APIs, and verify authoritative releases before changing pins. Never inspect /nix/store.


## Interfaces and Dependencies


Completed [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) are hard prerequisites. Own DataFence.hs and its store/admission protocol. [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) owns interactive session handling and consumes this fence; agree the opaque contract at M1 and do not require the entire restore plan to close before maintenance starts. [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) owns scheduled receipt production; manual receipts allow independent restore development. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) audits all entrypoints for fence admission. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md)/[EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) supply reusable integrated proof, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) keeps the complete release gate. Initial estimate: 16–32 active hours, low confidence, excluding shared integration runs. Reforecast immediately after M1's native exclusion probe for the three engines and mounted PVCs; this is the largest design risk, not permission to ship unsupported restore modes.
