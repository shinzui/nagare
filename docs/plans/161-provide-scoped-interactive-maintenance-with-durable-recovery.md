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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
---

# Provide scoped interactive maintenance with durable recovery

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture

**Cancelled/deferred from MP-23 by operator decision on 2026-09-28.** This plan no longer introduces interactive database shells or custom mutating exec/migration sessions as release requirements. Its filename, prior evidence, and delivered recovery code are retained for traceability. Existing statically declared reviewed hooks and read-only inventory inspection remain supported elsewhere. A provider-enforced read-only shell is not a replacement milestone here.

## Progress

**2026-09-28 scope decision.** [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) now retains the cross-tool journal/state, verified backups, and isolated restores while deferring general live overwrite, new interactive mutating maintenance, and generalized scheduled pruning. Historical findings below describe the earlier contract and retain their evidence; their superseded completion requirements do not add work back to this plan. Supported behavior still requires full proof.

Status is Cancelled in the parent registry. The unchecked original milestones below are historical uncompleted outcomes, not active work or claims of completion.


- [-] M1: Reviewed database shells and supported exec/migration entrypoints use an exact scoped maintenance receipt and the shared exclusion contract, preserving private credentials and rejecting concurrent mutation. {disposition=declined}
- [-] M2: Normal exit, nonzero exit, terminal loss, and operator-process death produce durable outcomes, re-observation, and explicit recovery of unresolved sessions without automatic replay. {disposition=declined}

Inherited: aggregate hooks already declare affected resources and reviewed per-tag Jobs. Database shell currently uses an imperative kubectl exec client and refuses after inventory initialization. The original proposal would replace that refusal with a supported reviewed session; that release obligation is now deferred. Recorded implementations below remain evidence, not a promise to admit new sessions.


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

The first process-death fixture used review `94cf3840e719a84d206c13a16c721b609389b70cde82af33cd6c4a490b1573f8` and session `mp23-death-1` on the same accepted Pod. After the fence entered `changing`, the terminal ran `SELECT pg_sleep(300);` and the operator process alone was killed. A fresh Pod-side query saw the marked backend active, while the durable fence remained `changing` and the journal had only `IntentRecorded` (sequence 611). A fresh `inventory resume --yes --take-over` refused with `active-data-fence` and did not execute the terminal again. The first explicit `verify-fenced-effect` attempt showed that terminating only the PostgreSQL backend is insufficient: orphaned `psql` reconnected under the same marker. The resolver now identifies the exact `psql` process by its `PGAPPNAME` entry in the pinned Pod's proc environment without printing credentials, sends TERM to that process, terminates any remaining marked backend, and requires all clients absent. Repeating the same explicit reviewed recovery completed at journal sequence 612; the policy and fence were removed, and a final `inventory resume --yes --take-over` converged. The focused test asserts that ordinary resume never calls the explicit resolver.

The nonzero-exit fixture used review `8dae4328596621c254ae9d619320f47b4a4cfdd11832bb7a6ff8ead016a1be60` and session `mp23-nonzero-1`. Inside its fenced terminal, `CREATE TABLE` and `INSERT` committed a known row; `SELECT` returned `1 | nonzero-recovery`. Terminating `psql` with SIGTERM made `kubectl exec` exit 143, which the journal retained in the ambiguous event at sequence 618 while the fence stayed `unresolved`. Explicit `verify-fenced-effect` re-observed and released the fence, wrote completion at sequence 619, and `inventory resume --yes` converged. A fresh Pod-side read after release still returned `1|nonzero-recovery`. This establishes a real mutating PostgreSQL shell and explicit nonzero/process-death recovery on local k3s. At this checkpoint, terminal-loss injection independent of process death, supported exec/migration entrypoints, Redis/ClickHouse sessions, concurrent-operation rejection, Pod replacement refusal, and complete M1/M2 acceptance were still open.

The local concurrency fixture on candidate `eb551890` saved review `f85efb1af0cab4a9161c9e8fc0e0ba5f7b8be7bac2682e43b5d224494f1ec263` at `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-a-maint-concurrency-review` and opened session `mp23-concurrent-1` on the accepted PostgreSQL Pod. While its terminal returned `SELECT 1`, a second `db shell` review for `mp23-concurrent-2` refused with `active-transaction` and `active-data-fence`. A separate disposable PostgreSQL Pod received `no response` from the database Service with the session policy in force. Public `inventory status --json` reported the session and a `changing` DataFence with recovery required. After `\q`, transaction `tx-f85efb1af0cab4a9161c9e8fc0e0ba5f7b8be7bac2682e43b5d224494f1ec263` converged; the test Pod and ingress policy were absent and the backup CronJob returned to `suspend: false`. This proves the competing reviewed shell and separate network client are excluded in the local fixture; deploy, restore, and pruning rejection still need their own asserted paths.

The stale-Pod fixture saved review `28d96882061d513162a22853f59d98ce62253a501cc6b5b66b78cdda305f5aed` at `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-a-maint-replacement-review` while database Pod UID was `c544f72c-6492-4cc9-92b9-9c551129e312`. Replacing only that disposable Pod produced UID `654cbd9c-c343-400b-8b40-a3d92fd03c66`; applying the saved review refused at admission with `Kubernetes object changed since review; replan before mutation`. The replacement Pod became Ready, and public status showed `dataFence: null` and `transactionStatus: null`. At this checkpoint, credential-access drift, independent terminal loss, other engines, and complete M1/M2 acceptance were still open.

Independent terminal-loss fixture (2026-09-27): candidate `5348d9e0` saved review `0f4965d99d6bcdb7e03588892efdbe8d03706af911081759b031ff8db771203e` at `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-a-maint-terminal-loss-review` for session `mp23-terminal-loss-1`. With `SELECT pg_sleep(300);` active, a HUP stopped only the local `kubectl exec` child while the operator process remained alive. The marked remote PostgreSQL backend, PID 581, stayed active. Journal sequence 631 recorded `Ambiguous` with the real terminal exit 1, and public status showed an `unresolved` DataFence and operation recovery required. Ordinary `inventory resume --yes --take-over` refused `active-data-fence`. The exact `verify-fenced-effect` decision at `/tmp/nagare-mp23-maint-terminal-loss-recovery.json` terminated and re-observed the marked client, completed the operation at sequence 632, and `inventory resume --yes --take-over` converged transaction `tx-0f4965d99d6bcdb7e03588892efdbe8d03706af911081759b031ff8db771203e` at sequence 633. Public status then showed no fence or transaction; the ingress policy was absent and the CronJob returned to `suspend: false`. This proves terminal transport loss separately from operator process death. Credential drift, complete conflicting deploy/restore/prune probes, Redis/ClickHouse sessions, and complete M1/M2 acceptance remain open.

Redis online-session checkpoint (2026-09-27): candidate `98d00da9` extended the existing maintenance proof with an engine token, preserving accepted PostgreSQL scopes that predate that field. The shared fence now selects an engine-specific client observer while retaining its exact StatefulSet, PVC, Pod UID, mount-guard, ingress-policy, and writer-drain checks. Redis uses an authenticated `CLIENT LIST` from the source Pod and requires the observing connection to be the sole client before release. Its interactive `redis-cli` carries the session marker in both the process environment and Redis client name; explicit recovery terminates only the marked process, then checks that no other client remains. The disposable `mp23-redis` Pod UID was `2965800b-4553-494b-9d7a-12dcc02bb61c`; accepted manual recovery backup `maintred1` converged as `tx-2685178bf39f64d5582a0bf7787efb1f5c89b849fb833908652eb240577e61fb` with completed Job UID `38464e5a-31c6-4d8b-9942-b6027e78d142`. Public `db shell mp23-redis -n personal --session-id redisone --recovery-backup maintred1 --save-plan /tmp/nagare-mp23-ep155-23001-6cpu-v2/redis-maint-review` saved review `57a99ef6d4745c0b7e4d0b28345b1933d8f265016b909f60a69fa18fe09efba0`. Its reviewed terminal read the source key, wrote and read `mp23:maintenance=redis-reviewed-v1`, and exited normally. `inventory apply` converged `tx-57a99ef6d4745c0b7e4d0b28345b1933d8f265016b909f60a69fa18fe09efba0`; the policy and public fence disappeared, and a fresh Pod-side read preserved the value.

Redis terminal-loss recovery (2026-09-27): review `d9cb7f4f4d4e8b007f8556cfb0738441ebfc70e076b10cd611126c5790016e36` opened session `redisloss` against the same accepted Pod and backup. The terminal wrote `mp23:maintenance-loss=redis-loss-v1`; an external `CLIENT LIST` saw `name=nagare-maintenance-redisloss`. HUP to only the local `kubectl exec` process produced `ambiguous tx-d9cb7f4f4d4e8b007f8556cfb0738441ebfc70e076b10cd611126c5790016e36 at op-8f778c4c542787f8198a9f1b`, while the named Redis client survived. Ordinary `inventory resume --yes --take-over` refused `active-data-fence`. The exact `verify-fenced-effect` decision in `/tmp/nagare-mp23-redis-maint-loss-recovery.json` stopped that marked process, observed only its own client, and completed reviewed recovery. `inventory resume --yes --take-over` then converged the transaction. A fresh Pod-side read still returned `redis-loss-v1`; the maintenance policy was absent, the backup CronJob returned to `suspend: false`, and public status had no active transaction or fence. Redis operator-process death, credential drift, remaining conflicting command probes, ClickHouse maintenance, and whole M1/M2 acceptance remain open.

ClickHouse online-session checkpoint (2026-09-27): the local 25.8 source `mp23-clickhouse` had accepted Pod UID `b0b6970b-966e-4612-b22c-7c344460813b`, completed manual backup `zipone` Job UID `8a2e3000-1ebe-4be5-9841-72ec16e0f81e`, and completed scratch-restore Job UID `51743343-a6c9-4ae5-8bbc-ee2165604362`. Both Jobs retain terminal Pods that still name the source PVC. The fence now pins each Job UID and spec digest, requires `Complete=True`, no active Job, and only terminal owned Pods, then compares the PVC consumer set with the source Pod plus exactly those terminal Pods under the mount guard. An active, replaced, or changed Job refuses. ClickHouse client observation uses the five server connection metrics; the in-Pod observer is the sole TCP connection before entry and after exit. Public `db shell mp23-clickhouse --session-id chone --recovery-backup zipone --save-plan /tmp/nagare-mp23-ep155-23001-6cpu-v2/clickhouse-maint-review` saved review `e9eb48fb34c1c9fc4b1254efea06c1ee2e5b5d10f46d53b0eeb77cb4c37a95c4`. Its first apply recorded an ambiguous fence acquisition because the volume observer counted the terminal Job Pods. After the exact-consumer check was implemented, reviewed `continue-fenced-operation` recovery of `op-ef1f5be05000a5c5bad8ee83` opened the terminal. It wrote and read `(230161, clickhouse-maintenance-reviewed-v1)`, then exited normally. The recovery completed, `inventory resume --yes` converged `tx-e9eb48fb34c1c9fc4b1254efea06c1ee2e5b5d10f46d53b0eeb77cb4c37a95c4`, the row persisted, the backup CronJob returned to `suspend: false`, and public status showed no fence or transaction.

ClickHouse terminal-loss recovery (2026-09-27): review `81687470c44b6c975e3ded0ab7141e2434e2df14caff86334d21d13059198ce5` opened session `chloss` on the same accepted source and backup. Its terminal wrote and read `(230162, clickhouse-maintenance-loss-v1)`. HUP to only the local `kubectl exec` child left a marked `clickhouse-clie` process in the source Pod; apply recorded `ambiguous tx-81687470c44b6c975e3ded0ab7141e2434e2df14caff86334d21d13059198ce5 at op-5abc24176925036752b19877`. Public status showed an unresolved fence and ordinary resume refused `active-data-fence`. Exact `verify-fenced-effect` recovery from `/tmp/nagare-mp23-ch-maint-loss-recovery.json` terminated that marked process, re-observed the server's client count, and released the fence. `inventory resume --yes` converged; the inserted row persisted and no marked process or fence remained. This completes native normal-exit and terminal-loss session probes for all three engines, while ClickHouse nonzero/process-death, credential drift, supported exec/migration entrypoints, remaining competing-operation probes, and M1/M2 acceptance remain open.





The Redis checkpoint passed the 907-test `nagarectl-test` suite, two focused maintenance tests, executable build, Haskell style gate, and strict user-documentation validation.

The ClickHouse checkpoint passed the 908-test `nagarectl-test` suite, executable build, Haskell style gate, strict user-documentation validation, and `git diff --check`.

## Decision Log

2026-09-28: Cancel this child as an active MP-23 release workstream under the operator-approved scope reduction. Keep delivered code/evidence and recovery of existing sessions; EP-153 guards new deferred admissions. Earlier expansion and sequencing decisions are historical and superseded.

2026-09-27: Consume EP-160’s corrected finite M1 contract without waiting for M2/M3 or EP-156. Preserve the operator’s explicit no-GKE boundary.


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.


## Outcomes & Retrospective

2026-09-28: Cancelled, not Complete. Prior experiments demonstrated parts of native maintenance but do not require completing a general session manager. Recovery compatibility is retained explicitly rather than discarding unresolved state.





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), including its 2026-09-28 scope amendment, requires independent ownership, exact reviewed effects, and full evidence for the revised supported contract. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A supported feature cannot close through refusal alone; an explicitly deferred route requires a tested admission guard and recovery compatibility, not a claim of implementation.

cli/nagarectl/src/Nagare/Database/Shell.hs contains runDbShell and per-engine client commands. cli/nagarectl/app/Main.hs guards DbShell and registers operational entrypoints. cli/nagarectl/src/Nagare/Inventory/Application.hs and cli/nagarectl/src/Nagare/Inventory/TaskRun.hs provide existing affected-resource and one-off execution patterns. cli/nagarectl/src/Nagare/Inventory/Execute.hs and cli/nagarectl/src/Nagare/Inventory/Store/Object.hs supply durable execution and remote writer ownership. New cli/nagarectl/src/Nagare/Inventory/Maintenance.hs owns session handling; cli/nagarectl/src/Nagare/Inventory/DataFence.hs, implemented by EP-160, owns the shared exclusion state machine.

A maintenance receipt states who/what was authorized to open a session, the exact accepted resource and provider identities, start/end or unresolved state, exit status, recovery references, and subsequent observations. It does not claim the contents of an interactive shell were statically reviewed. Do not record keystrokes, passwords, or raw terminal output in public evidence.


## Plan of Work

No new implementation is scheduled under this cancelled child. Do not continue all-engine session expansion, terminal tooling, or process-policy generalization to close MP-23.

[EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns the finite withdrawal work: mark new custom interactive mutating maintenance and unscoped exec/migration routes deferred, reject their command/library/recipe and unexecuted saved-review admission before effects, and document that boundary. Preserve existing reviewed static hooks. No unsupported route may silently fall back to imperative exec.

Keep inspection and evidence-bound recovery of already-admitted sessions. A surviving client must still be observed/terminated under the existing reviewed protocol before writer claims or fences are released; never replay arbitrary interactive commands or clear an unresolved record because this child was cancelled. [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md)'s accepted shared fence remains authoritative. EP-155/156 cover retained recovery compatibility as applicable, without requiring a new maintenance session for every engine or provider.

Any future maintenance feature needs an explicit product decision and bounded native authority/recovery contract. External-tool evaluation in EP-163 may examine available native controls; it neither reactivates this child nor promises a generic interactive session manager.

## Concrete Steps

There are no new feature steps under this cancelled child. EP-153 must add/refine admission-refusal and previously admitted session-recovery fixtures through the existing command test harness. Use retained private reviews and disposable historical session fixtures; do not launch new live sessions merely to complete this historical plan. Record resulting proof in EP-153 and the integrated evidence owners. Preserve all earlier observations in Surprises & Discoveries.

## Validation and Acceptance

Cancellation is a scope decision, not implementation acceptance. EP-153's release acceptance requires that new deferred sessions refuse before effects, static reviewed hooks and read-only inspection still work, and existing sessions cannot be stranded or automatically replayed. An unresolved surviving process continues to block conflicting mutation until evidence-bound recovery succeeds. Existing native tests and receipts may prove these regressions where their inputs still apply. No all-engine new-session or terminal-loss feature matrix is required from this child.

## Idempotence and Recovery


Use isolated test state and exact disposable resource identities. Retain the saved review, private native members, and journal after failure. Reuse an operation ID only with identical accepted intent; changed input requires a new review. Unknown provider results remain unresolved until observation proves what happened. No blind replay, broad prefix cleanup, history reset, or automatic data rollback is allowed. This plan authorizes implementation and its bounded verification, not a real release publication. Use Mori to locate dependency sources before relying on APIs, and verify authoritative releases before changing pins. Never inspect /nix/store.


## Interfaces and Dependencies

This child is Cancelled and no active MP-23 child depends on its completion. EP-153 owns deferred-admission guards and retained session-recovery compatibility; EP-160 owns the accepted shared fence; EP-155/156 supply relevant local/GCS recovery evidence; EP-157 verifies the declared release boundary. Preserve private history and existing backup references. No GKE, new messaging engine, new session store, or external tool is introduced by this decision.

## Revision Notes

2026-09-28: Cancel new interactive-maintenance delivery; transfer only deferred-route guards and existing recovery compatibility to EP-153.

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
