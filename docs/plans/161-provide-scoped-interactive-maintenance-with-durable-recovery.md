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





## Decision Log


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.


## Outcomes & Retrospective





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership, exact reviewed effects, and full release acceptance despite this split. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A refusal protects an unfinished feature but cannot count as its completion.

cli/nagarectl/src/Nagare/Database/Shell.hs contains runDbShell and per-engine client commands. cli/nagarectl/app/Main.hs guards DbShell and registers operational entrypoints. cli/nagarectl/src/Nagare/Inventory/Application.hs and cli/nagarectl/src/Nagare/Inventory/TaskRun.hs provide existing affected-resource and one-off execution patterns. cli/nagarectl/src/Nagare/Inventory/Execute.hs and cli/nagarectl/src/Nagare/Inventory/Store/Object.hs supply durable execution and remote writer ownership. New cli/nagarectl/src/Nagare/Inventory/Maintenance.hs owns session handling; cli/nagarectl/src/Nagare/Inventory/DataFence.hs, implemented by EP-160, owns the shared exclusion state machine.

A maintenance receipt states who/what was authorized to open a session, the exact accepted resource and provider identities, start/end or unresolved state, exit status, recovery references, and subsequent observations. It does not claim the contents of an interactive shell were statically reviewed. Do not record keystrokes, passwords, or raw terminal output in public evidence.


## Plan of Work


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


Completed [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) provide prerequisites. [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) owns DataFence and the mandatory M1 integration handoff: maintenance fixture and UI work may start against its agreed contract, but live admission cannot ship before that contract's exclusion/recovery proof passes. This is an integration dependency, not a hard requirement to finish every restore engine first. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns the finite entrypoint audit; [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) supplies scheduled recovery references where selected. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md)/[EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) integrate native sessions and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) gates readiness. Initial estimate: 8–16 active hours after the shared fence contract is available, low confidence, excluding integrated runs. Reforecast after the first pseudo-terminal/process-death probe; inability to identify a surviving remote client is an unresolved implementation requirement.
