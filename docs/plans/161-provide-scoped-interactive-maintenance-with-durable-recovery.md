---
id: 161
slug: provide-scoped-interactive-maintenance-with-durable-recovery
title: "Provide scoped interactive maintenance with durable recovery"
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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:04:28Z
      mode: "update"
      note: "Consume bounded EP-160 M1 and prohibit GKE dependencies."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T20:53:10Z
      mode: "implement"
      note: "Advance PostgreSQL online fence callbacks and verify native client exclusion"
---

# Provide scoped interactive maintenance with durable recovery

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture


Operators can open an interactive database shell or supported exec/migration session against an explicit owned resource set, with durable admission and recovery records. Concurrent managed mutation is excluded, sessions cannot silently outlive their authority, and exit triggers re-observation before normal work resumes.


## Progress


- [ ] M1: Reviewed database shells and supported exec/migration entrypoints use an exact scoped maintenance receipt and the shared exclusion contract, preserving private credentials and rejecting concurrent mutation.
- [ ] M2: Normal exit, nonzero exit, terminal loss, and operator-process death produce durable outcomes, re-observation, and explicit recovery of unresolved sessions without automatic replay.

Inherited: aggregate hooks already declare affected resources and reviewed per-tag Jobs. Database shell currently uses an imperative kubectl exec client and refuses after inventory initialization. This plan replaces that refusal with a supported reviewed session; it does not redo hook compilation.


## Surprises & Discoveries

2026-09-27: The plan formerly assumed the shared fence also supplied a usable native shell handoff. Source inspection shows its current Kubernetes policy is an offline data fence. A usable engine with one authorized client needs a distinct observed access policy under the same durable lifecycle. This unresolved implementation is owned here and must be tested before completing the rest of the session wrapper.

2026-09-27 handoff trace: the current `RunDeclaredOperation` adapter accepts only completed Kubernetes Jobs; `db shell` still calls direct `kubectl exec` and refuses owned data. A reviewed interactive session therefore needs a typed operation path through planning, adapter execution, journal verification, and recovery. A candidate PostgreSQL native policy keeps the exact accepted engine Pod running for an in-Pod Unix-socket client, drains other accepted writers and schedules, denies network ingress, and retains the admission/mount guard so a replacement cannot mount the PVC. It must pin the Pod UID and prove both the network exclusion and termination of a marked remote client before release. This is a design finding, not a passed fixture or accepted M1/M2 milestone; the next implementation must test the policy on the disposable k3s database before adopting it for the public command.

Native access-policy probe (2026-09-27): an isolated `ep161-maintenance-probe` namespace on the local k3s cluster ran two `postgres:18` Pods. Before an Ingress-denying NetworkPolicy selected the server, `pg_isready` from the client reached Pod IP `10.42.0.67:5432`; afterwards it returned no response. `pg_isready` through the server Pod's Unix socket still succeeded under the same policy. The repeatable `KUBECONFIG=/tmp/nagare-mp23-ep155-23001-6cpu-v2/config/nagare/kubeconfigs/local.yaml scripts/probe-ep161-maintenance-network.sh local` passed in a second disposable namespace with the same assertions and requested namespace cleanup. This proves the local CNI can support the proposed client-exclusion/authorized-local-client split. It does not prove exact accepted writer draining, policy-edit authority, durable review, Pod replacement safety, or parent-death recovery.

The same repeatable probe now starts a detached `psql` client with a unique `PGAPPNAME`, reads its backend PID through the server Pod's local socket after the invoking client has exited, terminates that PID with `pg_terminate_backend`, and confirms that the marker is gone. A rerun passed all checks and waited for disposable namespace deletion; a subsequent namespace listing contained no `nagare-ep161-network-*` namespace. Two intermediate runs exposed a Pod-ready/SQL-ready startup race, so both remote and local SQL readiness are polled before the policy and marked session checks. This establishes a viable PostgreSQL observation/termination primitive on local k3s. It still does not prove terminal parent-death handling, OS-client termination, the admission guard, or durable DataFence recovery, and does not complete M2.

The first provider piece, `MaintenanceNetwork`, rendered a session/Pod-UID-bound deny-ingress policy, rejected changed or terminating native objects, and used UID/resourceVersion preconditions on removal. Its focused maintenance test covered a lost create acknowledgement, unchanged replay, and refusal to delete a drifted policy. At that point the module was not yet attached to the DataFence callbacks or a public operation, so it did not advance either milestone by itself. EP-160 M1's accepted library command-service fixture remains valid; public live restore and interactive session registration belong to the still-open consumer outcomes.

The next contract slice adds a distinct `MaintainData` declared operation and `OpenMaintenanceSession` planned action. `compileMaintenanceScope` produces an operation-only scope over the existing accepted StatefulSet, with the exact source/PVC/Pod UIDs, source revision, recovery revision, and completed recovery Job identity in private overrides. It refuses a recovery reference from another source incarnation, a different cluster, or missing accepted native bytes. The existing Kubernetes adapter still refuses this new action, and no public command saves or applies it yet. This is planning groundwork; M1 and M2 remain open until the end-to-end native session and recovery fixture passes.

Planner tracing exposed a general operation-only scope omission: replacing such a scope selected no managed member, so its declared operation was silently dropped. The planner now selects affected members from the replaced scope for observation and emits the maintenance action. `MaintainData` is treated as a completed one-shot operation after convergence, so a later review of the same accepted scope cannot reopen its terminal. The focused fixture checks both initial planning and that non-replay condition.

The review and apply paths now explicitly require a saved DataFence record for `OpenMaintenanceSession`. A missing fence hook or a hook that declines this operation refuses review preparation; an admitted review without its fence record also refuses execution. This closes an otherwise unsafe generic fallback while the native maintenance fence and terminal adapter are being built. It is not evidence of a usable shell.

The PostgreSQL online fence now has native callbacks that keep the exact reviewed StatefulSet Pod alive, install the PVC mount admission guard and a Pod-UID-bound deny-ingress policy, stop reviewed clients/schedules, and require the original server Pod, sole PVC consumer, policy-edit denial, and drained PostgreSQL client backends before exclusion. NetworkPolicy ingress is additive, so the callback refuses another ingress policy in the namespace; it also refuses a host-network database Pod. SubjectAccessReview checks use Kubernetes's separate resource/subresource fields for Pod exec/attach/port-forward, and include controller-template changes that could create a host-network bypass. The local accepted `mp23-pg-b-0` Pod still matched its reviewed UID and selector labels. Its configured database role could query `pg_stat_activity`; a hard-coded `postgres` role did not exist, so the transport uses the Pod's injected role/database. The disposable k3s probe passed remote ingress denial, local socket access, count `0 → 1 → 0` across a marked client, and backend termination. These callbacks are not yet registered with the public review/apply registry or attached to a terminal adapter; M1/M2 remain open.

The affected `nagarectl-test` full suite passed after updating stale fixture counts for scheduled backup companion resources and the accepted application Secret channels. No public maintenance session was executed by that suite.

The Kubernetes fence adapter now exposes a separate maintenance capability whose replay reconstructs the online controls from a saved private Pod pin. It accepts only `OpenMaintenanceSession`; the ordinary offline restore capability remains separate. Production planning/execution registries still need to supply the source pin and recovery verifier, so this adapter capability alone does not admit a command.

Planning constructs its adapter registry before producing a proposal. The desired revision vector is nevertheless determined by the candidate, so `candidateDesiredRevisions` now supplies the same canonical vector that `planChanges` publishes. Production fence registration can use it at capture time and compare it with the saved review at replay; the maintenance source-native loader and public command remain the next integration step.

The first public PostgreSQL session now runs through `db shell NAME --session-id ID --recovery-backup ID --save-plan DIR`, a saved maintenance fence, `inventory apply`/`inventory recover`, and the shared transaction journal. The isolated local k3s fixture used accepted `application:mp23-app-a` database `mp23-pg-a`, its accepted manual backup `mp23-a-seed-1`, and Pod UID `c544f72c-6492-4cc9-92b9-9c551129e312`. Review `460beebfb1fe10e8b22bbaf412f8e8d94e1e6259118666de7256acb728916997` bound one `OpenMaintenanceSession` to the StatefulSet and PVC, source/recovery revisions, completed backup Job UID and receipt digest, and a separate post-session verification. Its first apply exposed an unreserved fence-start failure. Reviewed `retry-after-adapter-proof` recovery used the journal's fence-start event and absence of a durable reservation; after native policy fixes, the fence persisted in `acquiring` and was continued through the explicit `continue-fenced-operation` recovery action. Inside the fenced terminal, `SELECT current_database(), 1 AS maintenance_probe;` returned `mp23_pg_a | 1`. The session exited normally, journal sequence 606 recorded `Completed` with content digest `c820f7a0877ae308984bfc6b6a4f45c79b5a32a63feaad36fccd252ec77ad633`, the ingress policy and DataFence were absent after release, and `inventory resume ... --yes` converged the transaction. This is the first accepted native interactive-shell checkpoint, not M1/M2 completion: supported exec/migration entrypoints, nonzero/terminal-loss/process-death recovery, and fresh-process marked-client termination remain to be proved.

The native fixture also exposed two normalization boundaries. Kubernetes omits an empty `NetworkPolicy.spec.ingress` list while preserving default-deny Ingress semantics; the validator now accepts that exact omission but still rejects an allowing rule. Volume observation reports Pod consumers as `name/UID`; online exclusion now checks the full pinned identity. Network-policy edit reviews cover accepted workloads in the database namespace and declared route-dependent clients, while treating unrelated platform controllers as trusted; a cert-manager controller's unrelated Pod-creation authority no longer blocks this scoped fixture. The offline restore discovery rule is unchanged, and direct PVC mounts remain refusal cases for online maintenance.





## Decision Log

2026-09-27: Consume EP-160’s corrected finite M1 contract without waiting for M2/M3 or EP-156. Preserve the operator’s explicit no-GKE boundary.


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.


## Outcomes & Retrospective





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership, exact reviewed effects, and full release acceptance despite this split. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A refusal protects an unfinished feature but cannot count as its completion.

cli/nagarectl/src/Nagare/Database/Shell.hs contains runDbShell and per-engine client commands. cli/nagarectl/app/Main.hs guards DbShell and registers operational entrypoints. cli/nagarectl/src/Nagare/Inventory/Application.hs and cli/nagarectl/src/Nagare/Inventory/TaskRun.hs provide existing affected-resource and one-off execution patterns. cli/nagarectl/src/Nagare/Inventory/Execute.hs and cli/nagarectl/src/Nagare/Inventory/Store/Object.hs supply durable execution and remote writer ownership. New cli/nagarectl/src/Nagare/Inventory/Maintenance.hs owns session handling; cli/nagarectl/src/Nagare/Inventory/DataFence.hs, implemented by EP-160, owns the shared exclusion state machine.

A maintenance receipt states who/what was authorized to open a session, the exact accepted resource and provider identities, start/end or unresolved state, exit status, recovery references, and subsequent observations. It does not claim the contents of an interactive shell were statically reviewed. Do not record keystrokes, passwords, or raw terminal output in public evidence.


## Plan of Work

**Scheduling correction.** Begin the representative PostgreSQL maintenance/session-recovery fixture after EP-160 M1 and its first demonstrated authorized-engine handoff in M2; do not wait for all Redis/ClickHouse restore variants or volume M3. An existing verified manual recovery receipt can support that first fixture. This tests the shared interface early enough to correct it before multiplying implementations. Remaining engines, scheduled recovery references, and complete session acceptance still belong here.

**Resolve the native handoff first (2026-09-27).** The current `DataFence/KubernetesExclusion.hs` provider shuts down the database, requires zero StatefulSet replicas, no Service endpoints, and no PVC consumers. A database shell cannot use that acquired state as if the original engine were still reachable. Reuse the durable `DataFence` reservation, immutable review, recovery phases, and guarded release; implement an operation-specific maintenance access policy in this plan. Prove a running engine on the exact accepted data identity, the sole authorized session's access, exclusion of ordinary clients/schedules/controllers, and observation/termination of any surviving authorized process before release. A transient engine, if required by the chosen protocol, must be declared and identity-bound before mutation. Restarting ordinary writers or removing the guards just to open the terminal is not a valid handoff.

Before implementing all terminal/process helpers, drive one real PostgreSQL public saved-session → authorized client → known data change → client termination → re-observation → release fixture. Inject parent death while the remote client survives and recover that same session. State the concrete permitted engine/client and observation mechanism alongside this fixture; then extend the working protocol to Redis and ClickHouse. Reuse native controls where their preconditions fit. Do not add a generic security framework, a second lock, or a parallel session database. Required shared callback extensions belong to this consuming outcome and preserve EP-160 M1's accepted semantics; this is not permission to reopen M1 or demand that it implement maintenance.


M1 adds an explicit saved-review/session identity to db shell and each existing exec-like or user-supplied migration route enumerated by EP-153. Bind context, accepted resource set, native workload identity, client mode, and recovery preconditions before starting the subprocess. Mutating interactive database sessions require the shared fence and an adequate pre-change recovery reference; classify the session as potentially mutating unless a provider-enforced read-only mode is proved. The one authorized session receives access while other managed writers remain excluded. A changed or foreign Pod cannot replace the reviewed target silently. Use the shared durable context writer exclusion, even though this conservatively blocks unrelated managed mutation for the session duration; narrower concurrent writer scheduling is outside this plan. Do not invent a maintenance-specific lock or liveness timeout.

Keep subprocess and terminal credentials private, including engine clients that accept passwords in arguments. Resolve private access through the existing accepted credential binding without exposing it in public review or logs. Record session start before admitting the terminal. The reviewed per-tag hook path remains valid for statically declared jobs; unknown affected resources or unrestricted migrations refuse until explicitly scoped. Add public inspection/recovery commands for the retained session record and document exact invocation syntax with the implementation.

M2 handles normal exit, nonzero exit, signals, lost terminal, and process death. On ordinary completion, record the exit result, observe the same target incarnation and affected resources, verify the recovery/release criteria, and release through DataFence. A client exit code of zero alone is insufficient; an unknown schema change is not automatically reversible. If the parent dies, a remote interactive process might still run: preserve the active receipt and writer claim, prove that exact client is gone or explicitly terminate it through reviewed recovery, then re-observe before release. Session recovery never reruns arbitrary interactive commands. The existing explicit GCS writer takeover does not itself certify a session ended or permit clearing its fence.

Extend cli/nagarectl/test/InventoryTransactionSpec.hs and add cli/nagarectl/test/InventoryMaintenanceSpec.hs with Cabal/Spec registration. A pseudo-terminal fixture must drive the actual CLI, manipulate known disposable data, and test signals and a surviving child. Exercise local store and shared-store conflict behavior. EP-155/156 incorporate the native session and subsequent clean managed operation without duplicating its state machine.


## Concrete Steps


Run from the repository root in the existing development environment. A newly named test group must be registered and run at least one test; zero selected tests is not passing evidence. No provider mutation is part of these initial checks.

```bash
# New maintenance group, required before milestone acceptance:
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p maintenance' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p transaction' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
bash scripts/test-application-entrypoint-guards.sh
```

Expected result: selected tests and build exit zero; refusal fixtures prove zero unintended effects. At a milestone boundary also run the affected full suite, `bash scripts/check-haskell-style.sh`, and, when user docs change, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`. Add exact public-command native fixture invocations with their saved review paths before recording acceptance.


Add the required saved-session form below, preserving the existing database selection syntax. SESSION_ID is a stable operator-supplied ID, RECOVERY_ID identifies an accepted recovery artifact, and REVIEW is a new directory in isolated fixture state:

```bash
nagarectl db shell "$DB" --session-id "$SESSION_ID" --recovery-backup "$RECOVERY_ID" --save-plan "$REVIEW"
nagarectl inventory apply "$REVIEW" --yes
```

The first command saves intent without opening a terminal. Applying that exact review attaches the engine client to the operator's terminal inside the admitted maintenance operation; non-interactive invocation refuses before entry unless an explicitly supported reviewed command mode was selected. Inventory status exposes the active session ID and unresolved outcome. Extend the existing explicit recovery command boundary for session termination/re-observation; it must never silently reopen or replay the terminal.

## Validation and Acceptance


Open a reviewed shell into an accepted disposable database, change a known row/key, close it, and show a durable session receipt plus re-observation. Repeat the usable client path for PostgreSQL, Redis, and ClickHouse. A second operator cannot deploy, restore, prune recovery data, or open another conflicting session while it is active. Replacing the target Pod or losing credential access refuses before entry; no credential canary appears in public output.

Interrupt a terminal and kill the parent while its remote client remains alive. A fresh CLI must report unresolved maintenance, preserve writer exclusion, and require proof of client termination and target re-observation before accepting another operation. Nonzero exit also records the real outcome; neither success nor automatic rollback is fabricated. A native session proof may share EP-155's fixture, but fixture tests that merely launch a fake command cannot satisfy the usable database-shell outcome.

Use focused tests while implementing one coherent milestone, then the affected full suite/build and documentation checks at its acceptance boundary. Repeat broad gates only after a relevant change or failure. Record the exact command, candidate revision, review/transaction IDs, fixture identity, result, and evidence location. Distinguish recording-provider tests from real provider evidence. Shared integration runs may supply the same assertion to several plans; do not wait for administrative plan closure to run them. Keep Progress checkboxes directly under Progress, without nested headings.


## Idempotence and Recovery


Use isolated test state and exact disposable resource identities. Retain the saved review, private native members, and journal after failure. Reuse an operation ID only with identical accepted intent; changed input requires a new review. Unknown provider results remain unresolved until observation proves what happened. No blind replay, broad prefix cleanup, history reset, or automatic data rollback is allowed. This plan authorizes implementation and its bounded verification, not a real release publication. Use Mori to locate dependency sources before relying on APIs, and verify authoritative releases before changing pins. Never inspect /nix/store.


## Interfaces and Dependencies

The corrected EP-160 M1 handoff is its six shared-contract closure criteria on local k3s, not complete engine restore or cloud integration. Consume that fence after its acceptance; do not add a GKE provider, credential, or validation dependency. GKE use and provisioning are explicitly prohibited. Actual GCP/NixOS/k3s integration remains EP-156.


Completed [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) provide prerequisites. [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) owns DataFence and the mandatory M1 integration handoff: maintenance fixture and UI work may start against its agreed contract, but live admission cannot ship before that contract's exclusion/recovery proof passes. This is an integration dependency, not a hard requirement to finish every restore engine first. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns the finite entrypoint audit; [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) supplies scheduled recovery references where selected. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md)/[EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) integrate native sessions and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) gates readiness. Historical, uncalibrated estimate (not a current delivery forecast): 8–16 active hours after the shared fence contract is available, low confidence, excluding integrated runs. Reforecast after the first pseudo-terminal/process-death probe; inability to identify a surviving remote client is an unresolved implementation requirement.


## Revision Notes

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
