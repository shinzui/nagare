---
id: 224
slug: make-a-platform-transition-take-minutes-and-keep-its-cost-traced
title: "Make a platform transition take minutes and keep its cost traced"
kind: exec-plan
created_at: 2026-10-29T14:31:55Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-29T14:31:55Z
---

# Make a platform transition take minutes and keep its cost traced

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Moving the intranet to a new Nagare release is a reviewed platform transition: `nagarectl
platform transition plan` reviews every platform scope against the live cluster, `nagarectl
inventory apply` applies the review, and the loop repeats until a plan has no operations. On
2026-10-29 the v0.11.1 candidate, which changes no Kubernetes object the intranet runs, spent
most of its intranet step in this loop. The operator called it unusable. After this plan:

- a transition that changes no Kubernetes object takes a few minutes on the intranet: every stage's
  plan finishes in under 60 s, and the whole step from the candidate pin to `platform transition
  commit` takes under 5 minutes;
- every plan and apply can say where its time went. With `NAGARE_TRACE=1` the command prints, and
  with `NAGARE_TRACE_FILE=PATH` it writes as JSON, its kubectl calls by verb and purpose (cluster
  guard, object read, readiness, write, wait), its store transfers, and each operation's time by
  executor, action and phase;
- every release records its intranet transition cost next to its rehearsal record, and one command
  prints the trend across releases;
- a fixture test fixes the exact number of kubectl calls and store writes for a representative
  transition review. An improvement lowers the numbers in that test; a regression fails the fast
  gate. That is how the cost keeps falling instead of drifting back.

To see it: run `just release-candidate X.Y.Z` (or `platform transition plan` / `inventory apply`
with `NAGARE_TRACE=1`) and read `<run>/intranet-cost.json`, then run `scripts/transition-cost.py`
for the history.


## Progress

- [ ] M1: Cost attribution and the budget fixture. `NAGARE_TRACE=1` and `NAGARE_TRACE_FILE` report
  kubectl calls by verb and purpose and per-operation time by executor, action and phase.
  `release-intranet.sh` keeps each stage's trace file and writes `<run>/intranet-cost.json`;
  `release-candidate.sh` lands it beside the rehearsal record; `scripts/transition-cost.py`
  prints the history. A Kubernetes interpreter fixture (205 verifies, one update, one Helm verify)
  asserts the current exact counts. Pass: the fixture's counts equal a by-hand reading of today's
  code, and one traced transition (a local `just release-rehearse` run) shows the same per-operation
  counts.
- [ ] M2: One cluster guard per command, bound to the kubeconfig file it checked. Pass: the
  fixture shows one guard for a whole plan and one for a whole apply; changing the kubeconfig file
  between operations runs the guard again; a refusal is not remembered and refuses the same as today.
- [ ] M3: Plan observation reads each kind and namespace once. `platform transition plan` and
  `inventory plan` observe through EP-185's snapshot runtime (one `kubectl get` per kind and
  namespace, at most eight at a time). Pass: the fixture plan makes one read per kind and namespace;
  the same inputs give a byte-identical review with the snapshot and with single reads.
- [ ] M4: Verify-only operations cost one live read each, and their store writes are the minimum the
  journal needs. The change is chosen from M1's trace. Pass: lower fixture counts per verify
  operation; the recovery model and transaction tests are unchanged and green.
- [ ] M5: A release that changes no platform content re-accepts no Kubernetes scope. Find why
  v0.11.1 re-declared six scopes with 205 unchanged members, and remove the cause if the scope
  content is otherwise identical. Pass: a transition rehearsal between two such revisions plans no
  Kubernetes `VerifyResource` operation; a release that does change a member still verifies it.
- [ ] M6: Released on the intranet. A release containing M1-M5 records `intranet-cost.json` with
  every stage plan under 60 s and the transition step under 5 minutes, or the measured blocker and
  the next reduction.


## Surprises & Discoveries

2026-10-29, v0.11.1 candidate `ef5a537c` on the intranet (`~/.local/state/nagare/releases/v0.11.1/
20261029T140458Z/intranet/`). Stage 1 (host only) planned 2 operations. Stage 2's plan took
about 3.5 minutes and produced 211 operations: 205 Kubernetes `VerifyResource`, 5 Helm
`VerifyResource` and 1 Kubernetes `UpdateResource`. That's 58 serving, 49 cert-manager, 31 auth, 25
observability-vmks, 13 kourier, 11 net-certmanager and a few others, all in the six scopes the stage
re-accepts. Process samples of the plan and the apply showed one `kubectl` process at a time, about
two per second, with `kubectl get nodes` (the cluster guard) before most object reads: 17 of 42
calls in a 20-second sample of the apply. A verify-only operation read its object twice, each read
behind its own guard. Earlier on 2026-10-28, `NAGARE_TRACE=1` on one access-membership apply
showed `head reads 10` and `puts 10` for one operation (about 4 s of store I/O), so per-operation
journal writes also need attribution before a fix is chosen.


## Decision Log

- Decision: A standalone plan, not a child of MasterPlan 29.
  Rationale: MasterPlan 29's gate is a single access-membership change. This is the platform
  transition path, which no plan measured. It reuses MasterPlan 29's command trace
  (`Store.Counters`) and EP-185's snapshot reads.
  Date: 2026-10-29

- Decision: Measure first, and fix the budget in a test before any optimization.
  Rationale: the operator asked for a plan that helps trace and keep improving. The fixture's exact
  counts work as a ratchet: they only go down, as `scripts/check-haskell-architecture.py` does for
  module sizes. The release record keeps the real wall times per release.
  Date: 2026-10-29

- Decision: The cluster guard runs once per command and is bound to the kubeconfig file's path and
  content digest; any change runs it again, and a refusal is never remembered.
  Rationale: EP-214 already made access commands guard once per command. Every Kubernetes write still
  carries its UID and resourceVersion preconditions, and every call names `--context` explicitly. What
  the repeated guard protects against is the kubeconfig changing during a command, and the digest
  check catches that without a cluster round trip. ADR 18's "apply reruns the cluster guard before
  mutation" still holds per command.
  Date: 2026-10-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms used here:

- A **platform transition** moves a context (here the work intranet, context `intranet`, GCP project
  `tan-ng-labs`) from one Nagare release to another. `scripts/release-intranet.sh`, run by `just
  release-candidate`, pins the operator repository (`mori://tan/tan-ng-labs`) to the candidate,
  then loops `nagarectl platform transition plan --out DIR` and `nagarectl inventory apply DIR
  --yes` until a plan has no operations, then runs `platform transition commit`. Each loop pass is a
  **stage**. Stage reviews and logs go to `~/.local/state/nagare/releases/vX.Y.Z/<time>/intranet/`.
- A **review** (`review.json`) lists **operations**. Each names an **executor** (Kubernetes, Helm,
  Pulumi, host, …) and an **action** (`CreateResource`, `UpdateResource`, `VerifyResource`,
  `RetireResource`, …). `VerifyResource` proves an unchanged accepted member is still live as
  declared, so its scope can be re-accepted under a new revision.
- The **executor driver**, `cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs`
  (`runOperationsWith`), runs operations one at a time. Each operation goes through the adapter's
  prepare, preflight, execute and verify phases, and the driver journals its progress to the
  inventory store (GCS for the intranet) between them.
- The **cluster guard** proves that the ambient kubeconfig's current context is the selected context
  and that its node is the context's host (`cli/nagarectl/src/Nagare/Ops/ClusterGuard.hs`,
  `observeClusterGuard`: `kubectl config current-context` and `kubectl get nodes`). The CLI builds it
  in `cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs` (`guardKubernetesContext`) and hands it to the
  Kubernetes runtime as `runtimeGuard` in `KubernetesRuntimeConfig`
  (`cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs`).
- The **Kubernetes runtime**, `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`,
  talks to the cluster with one `kubectl` subprocess per request (`invokeKubectl` through the
  `Kubectl` effect in `KubernetesTransport.hs`). Its `observe` and `mutate` both call `runtimeGuard`
  first; a comment above `observeKubernetesBatchWithGuard` says each effect path keeps its own fresh
  guard. The phase logic for each action is in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`. For `VerifyResource`, `execute` reads
  the object (`observeMutation`), checks UID, owner and digest, and completes without writing;
  `verify` reads it again.
- The **snapshot runtime** (EP-185, `docs/plans/185-make-inventory-status-answer-in-seconds.md`)
  is in `cli/nagarectl/src/Nagare/Inventory/KubernetesSnapshot.hs`. `snapshotRuntime` reads a run's
  objects with one `kubectl get KIND NAME… -n NS -o json --ignore-not-found` per kind and namespace,
  at most eight at a time, and answers the single-object reads from it. Only `inventory status` uses
  it (`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs`). It serves read-only runs only,
  because it never sees the run's own writes.
- The **command trace** (MasterPlan 29, EP-221,
  `docs/plans/221-close-the-reviewed-access-latency-gate-with-measured-command-costs.md`) is in
  `cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs`. `tracePhase NAME action` times a named
  phase, `traceWire` counts store requests by kind and object class, and `withStoreTrace` prints
  `nagarectl trace:` lines when `NAGARE_TRACE=1`.

Relevant ADRs:

- [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md): the
  upgrade transaction is as guarded as the recipes it replaced. Kubernetes apply reruns the cluster
  guard and rejects wrong-context or stale evidence before mutation. M2 keeps that per command and
  amends this ADR with the kubeconfig binding.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): scopes,
  reviews, the journal, and re-acceptance of scopes. M4 and M5 must keep its rules: a re-accepted
  member is proved live; the journal records every operation's outcome.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
  are found with effect interpreters, and native runs only confirm. M1's fixture is a `Kubectl`
  interpreter plus a fake object store; the intranet only confirms.
- [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): a stopped transaction
  closes by per-operation proof. M4 must not reduce what the journal needs for that proof.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  physical identity (UID) checks stay on every write.


## Plan of Work

**M1, attribution and the budget fixture.** Extend `CommandTrace` in
`cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs` with:

- kubectl requests keyed by verb (`get`, `apply`, `create`, `patch`, `delete`, `wait`, `config`)
  and purpose (`guard`, `observe`, `readiness`, `ownership`, `write`, `wait`);
- per-operation records: executor, action and per-phase durations, plus the store requests made
  while that operation was current.

Count kubectl requests at the single `invokeKubectl` boundary and in `observeClusterGuard`, with the
purpose passed by the caller; that keeps them in one place. Add `NAGARE_TRACE_FILE=PATH`, which
writes the whole trace as one JSON document when the command ends, whatever its outcome. The
printed lines stay as they are, plus one `nagarectl trace: kubectl:` line and a per-executor summary
line.

In `scripts/release-intranet.sh`, set `NAGARE_TRACE_FILE=$review.plan.trace.json` and
`$review.apply.trace.json` for each stage. At the end, write `$run/intranet-cost.json`: per stage,
wall time, operation counts by executor and action, kubectl calls by purpose, and store
puts/reads. `scripts/release-candidate.sh`'s evidence step already lands
`docs/release-evidence/<rev>/transition-rehearsal.json`; it lands `intranet-cost.json` beside it in
the same commit. `scripts/transition-cost.py` reads every `docs/release-evidence/*/intranet-cost.json`
and prints one row per release: release, stages, operations, transition wall time, slowest stage,
kubectl calls, store writes.

Build the fixture in a new `cli/nagarectl/test/TransitionCostSpec.hs`. Assemble a review like stage
2 (205 Kubernetes verifies across several kinds and namespaces, one update, one Helm verify).
Execute it through the real driver against a `Kubectl` interpreter (`runKubectlWith`) that answers
from an in-memory cluster and a fake guard, and against the existing fake object store. Assert the
exact trace counts: guards, kubectl calls by purpose, store puts. These numbers are the budget.
Each later milestone lowers them in the same commit as its fix. Also run the fixture's plan side
through `platform transition plan`'s observation entry point with the same cluster, and fix the
plan's counts too.

**M2, one guard per command.** In `cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs`, wrap
`guardKubernetesContext` in a per-command memo:

- it records the kubeconfig path and the SHA-256 of its bytes at the moment the guard passed;
- before each later use it re-reads and hashes the file (no cluster round trip) and runs the guard
  again if either differs;
- a refusal is not stored.

Every `KubernetesRuntimeConfig` built in one command shares the memo. Remove the per-effect
re-guard comment and behavior in `KubernetesRuntime.hs`, and keep `observeKubernetesBatchWithGuard`'s
before/after pair for read-only batches. Add an amendment to ADR 18 recording the binding.

**M3, batched plan reads.** Route the plan's Kubernetes observation through
`KubernetesSnapshot.snapshotRuntime` over the addresses the plan will observe, as `inventory status`
does. The plan never writes, so the snapshot is valid for the whole plan. Readiness reads
(`observeKubernetesHealth`) are answered from the same snapshot. The equivalence test builds the
same review with and without the snapshot against one fake cluster and compares the bytes.

**M4, verify-only operations.** Use M1's trace to pick the smallest change that removes repeated
work without weakening proof. The expected candidates, in order:

- `VerifyResource`'s `execute` and `verify` read the same object back to back with no write between,
  so the verify phase can reuse the execute phase's read;
- a run of consecutive verify-only operations with no pending writes can be read as one fresh
  snapshot taken when the run starts;
- verify-only operations can journal their outcomes in fewer store writes, if ADR 26's per-operation
  proof still holds.

Any change to journaling needs the recovery model tests and a Decision Log entry. Lower the fixture
counts in the same commit.

**M5, unnecessary re-acceptance.** Diff the stage-2 review's `baseRevisions` against its
`desiredRevisions` for the six scopes, and find which declaration bytes changed between v0.11.0
and v0.11.1 (for example a payload version or identity embedded in a scope). If the change carries
no cluster meaning, stop embedding it in the scope, so an unchanged scope keeps its revision. If it
does carry meaning, record that, and the verifies stay, at M4's cost. Prove it with `just
release-rehearse` between two revisions that differ only in non-platform files.

**M6, intranet confirmation.** Release through the normal workflow. `intranet-cost.json` from that
release is the evidence, and `scripts/transition-cost.py` shows the before (v0.11.1) and after.


## Concrete Steps

From the repository root:

```bash
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/TransitionCost/||/Kubernetes/||/inventory/"' --test-show-details=direct
just gate-fast
```

A traced local transition (disposable Colima context, no cloud), after M1:

```bash
just release-rehearse <candidate-rev> <previous-release-tag>
jq '.stages[] | {stage, planSeconds, applySeconds, kubectl}' ~/.local/state/nagare/releases/rehearse/*/intranet-cost.json
```

A traced intranet command, for one plan only (it publishes a review, so it needs the operator's
go-ahead):

```bash
NAGARE_TRACE=1 NAGARE_TRACE_FILE=/tmp/plan.trace.json nagarectl --context intranet platform transition plan --out /tmp/stage
```

The cost history after any release:

```bash
scripts/transition-cost.py
```

Expected shape (numbers illustrative):

```text
release  stages  ops  transition  slowest-stage  kubectl  store-writes
0.11.1   3       213  21m40s      stage-2 apply  1900     2150
0.12.0   3       8    3m10s       stage-1 apply  60       90
```


## Validation and Acceptance

- The M1 fixture passes with the current counts before any optimization. Each of M2-M5 lowers
  specific numbers in it, and each commit says which.
- M2: one guard per plan and per apply in the fixture. Rewriting the kubeconfig file mid-apply
  produces a second guard. A refusing guard refuses the next operation exactly as today.
- M3: the plan's kubectl calls equal the number of (kind, namespace) groups plus two guards, with at
  most eight in flight. The reviews are byte-identical.
- M4: verify-only operations make one live read each in the fixture. The recovery model, transaction
  and close tests pass unchanged.
- M5: a rehearsal between revisions with identical platform content plans no Kubernetes verify.
- M6: on the intranet, with a release that changes no Kubernetes object, every stage plan takes
  under 60 s and the step from pin to commit under 5 minutes, as recorded in `intranet-cost.json`.
  If not, the record names the slowest phase and this plan stays open with the next reduction.


## Idempotence and Recovery

Tracing is read-only and writes only the named trace file. Fixtures use interpreters and a fake
store. A failed transition apply follows the existing path: `release-intranet.sh` resumes an
ambiguous stop once, otherwise `nagarectl inventory resume TX` or the close workflow per ADR 26.
None of these changes alter a review's format or the journal's on-disk format, so a candidate that
fails can be replaced by `release-candidate --revision` as usual.


## Interfaces and Dependencies

- `Nagare.Inventory.Store.Counters`: `CommandTrace` gains kubectl and per-operation fields, and a
  JSON encoding written by `NAGARE_TRACE_FILE`.
- `Nagare.Inventory.KubernetesTransport`: `invokeKubectl` records each request with its purpose.
- `Nagare.Cli.Runtime.Cluster`: the per-command guard memo, shared by every runtime in a command.
- `Nagare.Inventory.KubernetesSnapshot.snapshotRuntime`: reused for plan observation.
- `scripts/release-intranet.sh`, `scripts/release-candidate.sh`: trace files and
  `intranet-cost.json` as outputs of the existing steps; no new release step.
- New: `cli/nagarectl/test/TransitionCostSpec.hs`, `scripts/transition-cost.py`.
