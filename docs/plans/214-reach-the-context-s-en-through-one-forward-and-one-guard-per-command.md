---
id: 214
slug: reach-the-context-s-en-through-one-forward-and-one-guard-per-command
title: "Reach the context's En through one forward and one guard per command"
kind: exec-plan
created_at: 2026-10-22T20:22:26Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T20:22:26Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T21:29:32Z
      mode: "update"
      note: "Point the EnTransport seam at held EP-216"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T21:56:17Z
      mode: "implement"
      note: "Implement M1-M3 and the M4 user docs"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T23:20:31Z
      mode: "implement"
      note: "Merged onto EP-212; intranet M4 confirmation recorded"
---

# Reach the context's En through one forward and one guard per command

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md).


## Purpose / Big Picture

Every reviewed access relationship (a user's grant on a host, a team's grant, a team membership)
is written to and observed in En, the authorization service in the `nagare-system` namespace,
through a private `kubectl port-forward svc/en`. Today the forward lives for one call: the access
adapter's prepare, preflight, execute and verify phases each spawn a new forward (about 0.9 s),
re-run the cluster guard (`kubectl config current-context` and `kubectl get nodes`, about 0.3 s),
re-read both owner objects, and re-check En's capability (`/v1/openapi.json`) and, for team
relationships, its schema (`/v1/schema`) before the one query they came for. BUG-8 counted twenty
kubectl processes and about 9 s for one `inventory apply` of one tuple, and five for the plan.

After this plan a command opens one forward on first use and keeps it until the command ends,
runs the cluster guard once, checks capability and schema once, and still reads the owner
objects' UIDs at every phase and before every write, because that comparison is the safety
property that stops a write against a replaced auth service or route. An apply of one tuple
spawns one forward, one guard pair and eight owner reads; a plan spawns one forward, one guard
pair and two owner reads. `access check` and `access portal sync` use the same session.


## Progress

- [x] M1: An `EnSession` seam in `Nagare.Inventory.AccessRuntime`: one lazily opened forward per
  session, reopened only if its `kubectl` exited, closed when the session ends; the guard,
  capability and schema checks memoized per session. Pass: a fake transport and fake owner
  reader drive `mkAccessAdapter` through observe, prepare, preflight, execute and verify for one
  tuple and count forward opens 1, guard 1, capability 1, schema 1 (team tuple) or 0 (user
  tuple), owner reads 2 per phase, queries 5, writes 1 (`InventoryAccessSpec`).
  Evidence (e636ee02, `just gate-fast` green): `InventoryAccessSessionSpec` "one tuple's five
  phases share one forward, one guard and one capability check; owners are read every phase"
  passes for the user grant, the team membership and the team grant with exact counts: open 1,
  close 1, guard 1, capability 1, schema 0/1/1, queries 5, writes 1, owner reads 6 per owner
  object (five inspects plus the write's re-read: 12 for a grant, 6 for a membership, which has no
  route). The spec is a new module beside `InventoryAccessSpec`, which is near the 1000-line bound.
- [x] M2: Every command that reaches En runs inside one session: `access grant`, `access revoke`,
  `access team add-member`, `access team remove-member`, `access check`, `access portal sync`,
  `inventory apply`, `inventory resume`, `inventory status`. Pass: each CLI path creates the
  session at its command boundary with `bracket`, and a test that makes the action throw proves
  the forward process is terminated.
  Evidence (e636ee02): `withContextEnSession` wraps the four access plan commands and
  `access check` (`Nagare.Cli.Commands.Access`), `runInventoryApply` and `runInventoryResume`
  (`Nagare.Cli.Inventory.Workflow`, via `inventoryExecutionRegistryIn`); `inventory status` wraps
  its access lane in `withEnSession` with its own once-guard. `access portal sync` never reaches
  En and needs no session (Decision Log). "a session whose action throws stops its forward"
  (fake) and "kubectl's forward: a wrong first line is not ready; a thrown command terminates the
  process" (a `kubectl` PATH shim; `kill -0` on its PID fails after the session) pass.
- [x] M3: Failure behaviour unchanged. Pass: a session whose forward never becomes ready reports
  `en port-forward did not become ready`; a forward that dies between phases is reopened once and
  the phase succeeds; a capability or schema refusal is not memoized and the next phase re-asks;
  a missing `NAGARE_EN_API_KEY` still refuses before any process starts (`accessKeyRefusal`).
  Evidence (e636ee02): `InventoryAccessSessionSpec` "a forward that never becomes ready is
  reported and retried by the next phase" (opens 2, closes 0; also the real forwarder with a
  shim), "a forward that exits between phases is reopened once and the phase succeeds" (opens 2,
  closes 2, capability 1), "a refused capability or guard is not remembered" (guard 2,
  capability 2, opens 1), "a missing key refuses before any forward starts" (opens 0). All 19
  existing `reviewed access` tests and the full nagarectl suite pass unchanged.
- [x] M4: `docs/user/access.md` says the forward lasts the command, names the commands, and
  that owner UIDs are still read before every observation and write. On 2026-10-22, with the operator's go-ahead, a packaged build of `c9ebbb8b` ran a net-zero pair
  on the intranet: revoke, then grant back, of `user_01m4py1q2fesvbtd7xnxr7yede`'s direct grant on
  `keiro-docs.labs.topagentnetwork.net` (team `engineering`'s grant covered the host throughout;
  `access check` afterwards: allowed, grant generation 30). Converged `tx-5f35379e…` (revoke) and
  `tx-8a08c6a9…` (grant). A first revoke apply was refused `stale-head`/`stale-base` before
  admission with no effect: another writer advanced the head from 7247 to 7253 while it waited.
  Pass, from the EP-185-style kubectl PATH shim: each plan ran `kubectl` 7 times (1
  `port-forward`, 1 `config current-context`, 1 `get nodes`, 4 owner reads) and each apply 11
  times (1 `port-forward`, 1 `config current-context`, 1 `get nodes`, 8 owner reads).


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: Owner UIDs are still read at every phase and before every write. The comparison of
`accessPhysical` against the prepared `accessBefore` is what makes a write refuse when the auth
Deployment or the protected route was replaced out of band (F97, ADR 29). Two `kubectl get`
calls per phase stay; the forward, guard, capability and schema repetitions go.

2026-10-22: The session is created at the CLI command boundary and passed down, not inside the
adapter registry factory. The factory runs inside `planInventoryCandidateWith` and
`applyInventoryWithFactory` with no bracket, so only the command boundary can guarantee the
forward is terminated on every exit path.

2026-10-22: Memoize successes only. A refused guard, capability or schema check is reported and
re-asked by the next phase, so a transient refusal cannot poison a session.

2026-10-22: The capability and schema checks are remembered by `accessRuntimeOpsWith`, which
becomes `EnTransport -> ContextBinding -> IO AccessOps`, not by the session. `EnTransport` then
keeps exactly `withEn`, `readOwner` and `clusterGuard` for EP-216, and both implementations get
the memo. Each command builds one access adapter, so the count is the same as per session. The
session itself remembers the guard and keeps the forward.

2026-10-22: `access portal sync` gets no session: it never reaches En (its access executor is the
manifest adapter; it plans Kubernetes rollouts only). Callers outside the commands M2 lists
(`inventory plan` and every command that plans or converges through the shared registries) keep
one forward per call through `kubectlTransport`; `inventoryExecutionRegistryIn` takes the
session for `inventory apply` and `inventory resume`.

2026-10-22: A kept forward drains kubectl's output after the first line, so its per-connection
"Handling connection" lines cannot fill the pipe and stall kubectl during a long command.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

`cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs` holds the runtime. `withContextEn`
(line 292) checks `NAGARE_EN_API_KEY`, spawns `kubectl --context C -n nagare-system port-forward
svc/en :80 --address 127.0.0.1` (`openEnForward`), waits up to 15 s for the "Forwarding from"
line to learn the port (`parseEnForwardPort`), runs the action with an `EnCall`
(`ByteString -> Text -> Value -> IO (Either Text (Int, ByteString))`, built by `enRequest`), and
terminates the process (`closeEnForward`). `accessRuntimeOps` (line 162) builds the `AccessOps`
record the adapter uses: `accessInspect` runs `inspectOwners` (the guard, then one
`kubectl get ... -o json --request-timeout=10s` per owner object, checking the UID and the
`nagare.dev/*` annotations), then inside a fresh forward reads `/v1/openapi.json`, for a team
tuple `/v1/schema`, and finally queries the relationship; `accessWrite` re-reads the owners,
compares them to the prepared fact, and POSTs `/v1/relationships` inside another fresh forward.
`accessReviewAdapter` (line 367) builds the adapter for apply and resume from a review bundle.

`cli/nagarectl/src/Nagare/Inventory/Access.hs` holds `mkAccessAdapter` (line 448): observe calls
`accessInspect` once per tuple; prepare, preflight, execute and verify each call it once more;
execute then calls `accessWrite`. That is five inspects and one write per tuple per apply, and
one inspect per plan. `AccessOps` is the existing seam the tests use
(`cli/nagarectl/test/InventoryAccessSpec.hs` builds `AccessOps { accessInspect = ..., accessWrite = ... }`
directly); this plan adds the seam one level down, so that `accessRuntimeOps` itself can be driven
by fakes.

Callers. `cli/nagarectl/src/Nagare/Access/Reviewed.hs`: `accessAdapter` (plan and status) builds
`accessRuntimeOps (headBinding ...) context selectedGuard`; `checkEffectiveAccess` and
`planPortalSync` call `withContextEn` directly. `cli/nagarectl/app/Nagare/Cli/Inventory/Execution.hs`:
`inventoryExecutionRegistry` calls `accessReviewAdapter` with `guardKubernetesContext active`
as the guard (`cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs`, which runs
`observeClusterGuard`: `kubectl config current-context` and `kubectl get nodes`).
`cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`: `runInventoryApply` and `runInventoryResume`
wrap that registry in `requireAccessKey`. `cli/nagarectl/app/Nagare/Cli/Commands/Access.hs`
dispatches `grant`, `revoke`, `team add-member`, `team remove-member`, `check` and `portal sync`.
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs` (line 335) builds the access adapter
for `inventory status`.

The user documentation is `docs/user/access.md` ("Teams" and the paragraph beginning "Reviewed
grants reach the context's En themselves, through a private port-forward to its Service that
lasts one call"). EP-185 (`docs/plans/185-make-inventory-status-answer-in-seconds.md`) ran the
cluster guard once per status run and is the precedent for memoizing it.

[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) is the access
model; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
puts the proof in fakes; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)
and `mori://shinzui/haskell-jitsurei/docs/core-standards` govern the Haskell.


## Plan of Work

M1 introduces the seam and the session. Define in `Nagare.Inventory.AccessRuntime`:

```haskell
data EnTransport = EnTransport
  { withEn :: !(forall a. (EnCall -> IO a) -> IO (Either Text a))
  , readOwner :: !(ManagedResource -> IO (Either Text Value))
  , clusterGuard :: !(IO (Either Text ()))
  }
```

`accessRuntimeOpsWith :: EnTransport -> ContextBinding -> AccessOps` builds the same `AccessOps`
as today from the transport, and `accessRuntimeOps` becomes
`accessRuntimeOpsWith (kubectlTransport kubectlContext guard)`. The session is
`withEnSession :: Text -> IO (Either Text ()) -> (EnTransport -> IO a) -> IO a`: it holds an
`MVar (Maybe Forward)`; `withEn` opens the forward on first use (same readiness wait and port
parsing as today), reuses it while `getProcessExitCode` is `Nothing`, reopens once if the process
has exited, and the bracket's release terminates whatever forward is open. Inside the session,
`clusterGuard`, the capability check and the schema check are memoized on success with one
`MVar` each (`Nothing` until a `Right`). `readOwner` is not memoized. `accessInspect` keeps its
order: owners, then capability, then schema for a team tuple, then the query; `accessWrite` keeps
its owner comparison before the POST.

M2 moves the session to the command boundary. `planAccess`, `planTeamAccess`, `planTeamMember`,
`checkEffectiveAccess` and `planPortalSync` in `Nagare.Access.Reviewed` take an `EnTransport`
(or open the session themselves at their top, since each is one command). `accessAdapter` and
`accessReviewAdapter` take the transport instead of a kubectl context and a guard.
`inventoryExecutionRegistry` receives it from `runInventoryApply` and `runInventoryResume`, which
wrap their body in `withEnSession`; `runInventoryStatus` does the same for its access lane. A
command with no access operations never opens a forward: the session is lazy, so this falls out.

M3 is the failure-behaviour proof listed in Progress, written against the fake transport: a
`withEn` that returns `Left "en port-forward did not become ready"`, a forward that "dies" after
the second phase (the fake flips a flag so the next `withEn` reopens and counts two opens), and a
capability check that fails once then succeeds (two capability calls counted).

M4 updates `docs/user/access.md` and records the intranet confirmation with EP-212's.


## Concrete Steps

From the repository root after every Haskell change:

```bash
just haskell-style-check
just gate-fast
```

Focused suites while iterating:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/Access/"' --test-show-details=direct
```

For the intranet confirmation, put the EP-185 PATH shim for `kubectl` first on `PATH`, export the
read-write En key as the operator does today, and run one grant plan and its apply with
`NAGARE_TRACE=1`; count `port-forward` and `get nodes` lines in the shim log. The apply is a cloud
mutation: ask the operator once, for this pair together with EP-212's confirmation pair.

Commit message shape:

```text
perf(access): keep one en forward and one cluster guard for the whole command

MasterPlan: docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md
ExecPlan: docs/plans/214-reach-the-context-s-en-through-one-forward-and-one-guard-per-command.md
```


## Validation and Acceptance

- `InventoryAccessSpec`: driving `mkAccessAdapter` built from `accessRuntimeOpsWith` and a
  counting fake transport through one tuple's observe, prepare, preflight, execute and verify
  gives forward opens 1, guard 1, capability 1, schema 1 for a team tuple and 0 for a user tuple,
  owner reads 10 (two per inspect), queries 5, writes 1. Today's code would give 5 forwards and 5
  guards.
- The same test with the fake forward "exited" after preflight gives forward opens 2 and the same
  outcome.
- A fake whose capability check fails on the first call gives capability calls 2 and a prepare
  refusal followed by success.
- A session whose action throws leaves no running forward (the fake records close).
- Existing tests in `InventoryAccessSpec`, `AccessCheckSpec`, `AccessGrantsSpec` and
  `InventoryTransactionSpec` pass unchanged; `just gate-fast` is green.
- Intranet: the shim log for one plan shows one `port-forward` and one `get nodes`; for one apply
  of one tuple, one `port-forward`, one `get nodes` and eight owner `get` calls.


## Idempotence and Recovery

The forward is a local process with no state in the cluster or the store; killing it or losing
it mid-command is already handled by the adapter's per-phase re-observation (a lost response is
`AdapterEffectAmbiguous`, resumed by `inventory resume`). Reverting the landed commit restores one
forward per call. No data moves.


## Interfaces and Dependencies

```haskell
-- cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs
type EnCall = ByteString -> Text -> Value -> IO (Either Text (Int, ByteString))   -- unchanged
data EnTransport = EnTransport
  { withEn :: !(forall a. (EnCall -> IO a) -> IO (Either Text a))
  , readOwner :: !(ManagedResource -> IO (Either Text Value))
  , clusterGuard :: !(IO (Either Text ()))
  }
withEnSession :: Text -> IO (Either Text ()) -> (EnTransport -> IO a) -> IO a
withEnSessionUsing :: EnForwarder forward -> (ManagedResource -> IO (Either Text Value)) -> IO (Either Text ()) -> (EnTransport -> IO a) -> IO a
kubectlTransport :: Text -> IO (Either Text ()) -> EnTransport   -- one forward per call
accessRuntimeOpsWith :: EnTransport -> ContextBinding -> IO AccessOps
accessReviewAdapter :: InventoryStore -> ContextBinding -> EnTransport -> ReviewBundle -> IO (Either Text Adapter)
-- cli/nagarectl/src/Nagare/Access/Reviewed.hs
accessAdapter :: ActiveTarget -> EnTransport -> [Declaration] -> InventoryHistory -> IO Adapter
-- EP-212 changes this function's history source at the same time; coordinate the one signature.
```

EP-216 (held) later implements `EnTransport` over the API server's service proxy and deletes
`openEnForward`; keep the seam's shape stable for it.

No hard dependency. EP-212 edits `accessReviewAdapter` and `accessAdapter` too (it passes the
loaded history in instead of loading it); whichever lands second rebases onto the other's
signature. EP-215 observes several tuples per plan and benefits from one forward but does not
need it.
