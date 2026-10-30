---
id: 226
slug: share-bounded-cluster-observations-through-a-guarded-command-session
title: "Share bounded cluster observations through a guarded command session"
kind: exec-plan
created_at: 2026-10-29T14:39:33Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:39:33Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T16:27:26Z
      mode: "update"
      note: "Add MasterPlan 29 follow-ups: gcloud ownership stall (EP-226 M4) and journal catch-up bound (EP-227 M2)"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:45:25Z
      mode: "update"
      note: "Interfaces: M4 has no prerequisite and may land first"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T19:47:52Z
      mode: "implement"
      note: "M4: per-project number cache, confirmed on the intranet"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-30T01:31:13Z
      mode: "implement"
      note: "M1 session, M2 planning epochs, M3 read limit and faults"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:44:53Z
      verdict: "changes-requested"
      note: "Snapshot, guard and ownership-read claims verified; Interfaces blocked M4 behind EP-224 M1 while M4 declares no prerequisite"
---

# Share bounded cluster observations through a guarded command session

This ExecPlan is a living document. Maintain its evidence independently of the parent registry.


## Purpose / Big Picture


Planning and validation should pay once for selecting and guarding a cluster, then read each
required resource group with bounded concurrency. Repeated adapter calls must not repeatedly
spawn `kubectl get nodes` or reread the same object in the same phase. Mutations and readiness
must still see fresh state. A wrong context, changed identity or unavailable API must fail
closed with a bounded number of requests and a useful explanation.


## Progress


- [x] M1: A command-scoped guarded cluster session binds actual requests to checked connection
  material and invalidates on identity changes; concurrent consumers perform one admission.
  Pass, 2026-10-29, `d59a85c2` (fast gate green): `-p ClusterSession`, nine cases over an
  injected kubectl and clock: 16 concurrent callers make one context read, one flatten and one
  node list; a request keeps naming the guarded bytes after the ambient kubeconfig changes;
  renewal after 60 s reuses unchanged bytes and admits changed bytes as a new generation; a node
  UID change under the same bytes refuses and keeps refusing until invalidation; an ambient
  context mismatch refuses before any flatten; a refused admission is not kept; a local session
  guards no host; inside a command requests name the private file (removed at the end) and a
  refusing session refuses the request. Merge and referenced-file semantics are kubectl's own
  (`config view --flatten --minify`, kubectl 1.37.0, checked by experiment: merged
  `KUBECONFIG` lists, embedded CA and key data, kept exec stanza, unknown context exits 1).
  Native, intranet, read-only: 20 guard calls made 1 admission and 19 reuses with 3 kubectl
  processes (0.48 s) instead of 40; an expected host of `wrong-host` refused.
- [x] M2: Planning/status and verify-only consumers use bounded observation epochs, with full
  address keys, bounded chunking/fallback and tested freshness boundaries.
  Pass, 2026-10-29, `6c350aab` (fast gate green). `KubernetesSnapshot` is the epoch: reads group
  by cluster, kind and namespace in chunks of 128 names or 32 KiB; a failed read retries once,
  then answers each member unavailable; an unrecognized answer falls back to at most eight single
  reads per epoch; several names without a List prove nothing; two clusters refuse; a changed
  session generation answers nothing (`-p "kubernetes snapshot"`). A plan's Kubernetes adapter
  (`kubernetesPlanningAdapter`, used by the CLI planning registry) begins an epoch over each batch
  it observes and answers its preparations from it; apply reads freshly. Equivalence: the sweep
  planned from the same head with single reads and with the epoch writes a byte-identical
  `review.json` (`-p "production path counts"`); drift, deletion and replacement after the plan
  still refuse. Planning the sweep: 2 transported reads for 206 members (was 412), 17 for 2,051
  (was 4,102). The fake API server now answers multi-name gets as kubectl 1.37 does on the
  intranet (a List of the found objects, empty when none, the object for one name); its
  single-name parse was the cause recorded under Surprises.
- [x] M3: Kubernetes, Helm and relevant access integration share sessions without caching writes
  or readiness across phases; adversarial guard and observation fixtures pass.
  Partial, 2026-10-29, `baa4076f` (fast gate green): Kubernetes runtime, Helm and access requests
  name the session's kubeconfig (M1); one process-wide limit of eight grouped reads covers every
  epoch; forbidden, throttled and unreachable reads are unavailable, never absent; the same name
  in two namespaces is answered per namespace; a KUBECONFIG change or host activation re-admits.
  Writes and readiness never read an epoch. Native, 2026-10-30: `just release-rehearse a5dd71e2
  v0.11.0` passed (sentinel read back, pin moved, replan empty). Its platform stage traced one
  guard admission per command; planning made 49 transported kubectl reads with 418 answered from
  epochs, 70 processes, 19 s; apply 54 transported, 416 reused, 75 processes, 13.4 s. The first
  native record (EP-224 M2) had 879 processes for that stage.
- [x] M4: Opening the inventory store proves bucket ownership without a per-command
  `gcloud projects describe`. The project number is immutable, so read it with the session's
  token or keep it per project; the bucket's owning number stays a live read and the comparison
  still fails closed. Independent of M1–M3. Pass: the ownership fixtures in
  `test/InventoryGcloudAuthSpec.hs` and the store ownership refusals pass unchanged, and a
  traced intranet command shows no `project ownership` gcloud subprocess.
  Pass, 2026-10-29, landed `ff2e12f2` (fast gate green): `Nagare.Inventory.Store.ProjectNumbers`
  keeps each project's number in `~/.cache/nagare/project-numbers/<project>` (0600); a
  remembered number that disagrees with the live bucket owner is reread before the verdict. The
  EP-221 overlap/refusal case runs unchanged and a new EP-226 M4 case covers recall, foreign and
  unreadable buckets, a wrong entry and unsafe IDs. Intranet `inventory store status`, traced
  twice: the first run read `project ownership` (0.91 s) and filled the cache; the second had no
  `project ownership` phase, two gcloud processes instead of three and 3.08 s wall instead of
  3.45 s. Evidence for the need:
  [`docs/audits/mp29-latency-2026-10-29/baseline.json`](../audits/mp29-latency-2026-10-29/baseline.json),
  where that read took 16.3 s and 14.9 s in two of ten commands instead of about 0.6 s.


## Surprises & Discoveries


- 2026-10-29: Answering planning's object reads from the existing grouped snapshot
  (`KubernetesSnapshot.snapshotRuntime`, used by status) is not equivalent. A review prepared from
  a list item binds bytes that differ from a later single-object read, so apply preflight refused
  every create with "Kubernetes object changed since review" (EP-224's production fixture, run
  after `28df690e`). M2 must make grouped answers equal to single reads, or bind preparation to
  identity and desired fields only, and prove that with the plan-equivalence test it already
  names, before any planning path uses grouped reads.

2026-10-29: `KubernetesSnapshot.hs` batches by kind and namespace, uses eight concurrent calls,
and falls back to one read per object for unrecognized batch failures. Its answers are keyed by
kubectl argument lists. The connection identity is not part of that map. `ClusterGuard.hs`
observes ambient kubeconfig with its own subprocesses, while ordinary transport passes an explicit
context. A memo keyed only by one kubeconfig file's digest does not bind a later subprocess to
the bytes that passed the guard, handle merged kubeconfig files, or cover referenced identity files.


## Decision Log


- 2026-10-29: Use one explicit session capability, not a process-global boolean or independent
  per-adapter memos. Successful guard reuse is confined to a stable identity generation.
- 2026-10-29: An epoch is phase-local evidence, not an atomic cluster snapshot. It cannot authorize
  a later write without fresh target checks and server-side preconditions.
- 2026-10-29: The command's sessions are installed once at dispatch (`withCommandScope`, beside
  the command trace) and found by Kubernetes context, not threaded through the ~20 registry
  constructors that take an `ActiveTarget`. Every request still uses exactly one session object
  per context, and outside a command the per-call guard remains, so the semantics match an
  explicit parameter without that churn. Delegated binding is kubectl's flatten, not a resolver
  of our own, so merge rules are never guessed.
- 2026-10-29: Keep kubectl behind the existing effect boundary initially. A direct client is not
  required to remove redundant process and request work; any later replacement needs measured
  justification and the same compatibility/conformance tests.


## Outcomes & Retrospective


A command guards its cluster once and every request uses the kubeconfig the guard checked; plans
and admissions read through grouped epochs whose answers equal single reads. Native cost of the
platform stage fell from 879 processes to about 70 per command. The remaining planning time is
not Kubernetes reads (19 s with 49 of them); EP-224 M3 measures where it goes. ADR 18 and ADR 22
carry the durable context.


## Context and Orientation


`cli/nagarectl/app/Nagare/Cli/Runtime/Cluster.hs` constructs `guardKubernetesContext` and access
sessions. `cli/nagarectl/src/Nagare/Ops/ClusterGuard.hs` verifies current context and expected
server-node name. `cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs` contains
`KubernetesRuntimeConfig`, `invokeKubectl` and the fake/real interpreters. The runtime in
`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` performs object observation,
guarding and writes; `KubernetesSnapshot.hs` supplies grouped status reads.

`cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs`,
`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`, and
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs` assemble consumers.
`cli/nagarectl/src/Nagare/Inventory/Adapters/HelmRuntime.hs` and
`cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs` also contact the selected cluster.
`cli/nagarectl/src/Nagare/Inventory/Command/Open.hs` owns inventory opening; use its existing
command lifetime rather than opening another store for each session consumer.

[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) requires
guarded apply and stale-evidence refusal. [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
requires physical UID checks. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
requires fake API behavior to agree with recorded native semantics. None permits assuming all
objects returned by separate reads existed at one instant.


## Plan of Work


### M1 — Bind a session to what was actually guarded


Add `cli/nagarectl/src/Nagare/Inventory/ClusterSession.hs`. The bracketed session owns selected
context, expected host, endpoint/trust identity, kubeconfig dependency fingerprint, a private
resolved connection configuration and a synchronized guard result. Bind both the guard and all
subsequent kubectl/Helm requests explicitly to that private configuration. Preserve the current
ambient-context mismatch refusal before capturing it; do not silently correct a wrong selection.
Resolve supported merged kubeconfig inputs and referenced CA/client credential files. The session
must not serialize tokens into traces. Use private temporary permissions and clean up normally.

An external auth plugin remains an auth provider, not stable credential bytes; bind its
configuration and endpoint/trust selection, permit credential refresh, and renew the guard when
identity-affecting configuration changes. If a supported input cannot be bound safely, retain
the conservative fresh-guard path with a visible reason and tests; do not silently reuse proof.
Use Mori to locate kubectl/client-go configuration semantics before implementing this resolver;
consult authoritative upstream documentation if the corpus lacks it. Do not guess merge rules.

Before use, compare the selected target and configuration dependencies with the captured
generation. A change invalidates the observation cache and requires a new guarded session before
another write; one concurrent initializer performs the check. A failed guard is never cached as
success. Host activation, kubeconfig projection, detected server/node replacement and process
restart always create a new generation. For long commands, renew the live identity check at each
mutation/readiness wave boundary and at least every 60 seconds; one short read-only command needs
one admission, not one per object. Include server node UID in the guarded identity so replacement
under the same hostname is detectable. This is not a new trust root against cluster administrators.

Test multiple callers, merged files, symlinks/replacement, referenced CA changes, ambient mismatch,
expected-host changes, renewal, guard refusal and a config swap between capture and subprocess
dispatch. A request must either use the exact captured identity or refuse; hashing the ambient
file and then using its mutable path is not sufficient. Amend ADR 18 when the implementation proves
these bindings, rather than asserting that memoization alone satisfies it.

### M2 — Gather bounded evidence for one phase


Extend `KubernetesSnapshot.hs` into an explicit `ObservationEpoch` interface keyed by session
generation, API group/version/resource, namespace and name. Distinguish missing objects from
unavailable reads. Capture UID, resourceVersion, generation, desired-field evidence and readiness
from the same returned object where its kind semantics permit it. Preserve separate additional
reads for health requiring child objects and count them honestly.

Group requested named resources; chunk at 128 names or 32 KiB encoded arguments, whichever comes
first, with at most eight active requests. Deduplicate addresses and reject cross-cluster mixing.
A failed multi-name read must not fan out into thousands of single calls: allow one bounded retry
for a transient error, then return explicit unavailable evidence. Retain only documented,
tested fallback for an unsupported response shape, capped at eight single-object requests per
epoch; excess fails with context. Unknown resource kinds and absent objects keep their distinct
semantics. A malformed/truncated response cannot prove absence. Record retries and fallback.

Route inventory planning, transition planning and status through this API after computing their
observation requirements. Bind plan equivalence to the same injected clock, input history and
fake cluster; compare canonical review meaning and operation order, ignoring only documented
timestamps, trace IDs and publication paths. “Byte identical” is only meaningful when those
inputs are fixed. Add `cli/nagarectl/test/ClusterSessionSpec.hs` and extend
`cli/nagarectl/test/InventoryKubernetesSnapshotSpec.hs`.

Fresh verification starts a new apply epoch; it never reuses a saved plan epoch. End the epoch
before any mutation whose result or dependencies it covers. Readiness polling starts subsequent
epochs and never uses the pre-write object. ResourceVersion preconditions remain on every write;
grouped observation is not a substitute. EP-227 receives both the evidence and its epoch binding.

### M3 — Integrate every relevant consumer


Pass the same session through CLI registry construction, Helm runtime and access transport instead
of rebuilding guards in adapters. Audit direct subprocess calls in these paths and attribute each
one. Do not cache a Helm mutation or provider process result merely because its input repeats.
Bound concurrency globally within the command so nested adapters do not each allocate eight
independent workers. Preserve read-only interpreter injection and cleanup on async cancellation.

The integration fixture must exercise one transition plan, one apply verification epoch, a real
fake-server mutation and its post-write readiness. A new object version between phases must be
observed. Context/host changes between waves must invalidate the session. Forbidden reads, 429,
API unavailability, wrong kind, malformed JSON and duplicate names in different namespaces must
not yield healthy evidence or uncontrolled fallback. Add a bounded native session/snapshot
roundtrip in the disposable rehearsal to confirm actual kubectl configuration behavior.


## Concrete Steps


From the repository root after test registration:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p ClusterSession' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p snapshot' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p TransitionCost' --test-show-details=direct
just haskell-style-check
```

Confirm the requested groups select tests. A stable short plan reports one guard admission,
physical reads equal to its bounded request groups plus guard requests, zero cache-hit transport
calls, and no more than eight requests in flight. After committing, use `just gate-fast <revision>`.
The disposable native confirmation belongs to the release rehearsal; no intranet mutation is
needed to implement these tests.


## Validation and Acceptance


M1 passes the connection/configuration race matrix and synchronized admission count. M2 passes
single/grouped observation equivalence, chunk/fallback budgets and fresh post-write reads. M3
passes production consumer integration, session invalidation and native config binding. Scaling
from 205 to 2,050 members grows by groups/chunks and bytes, not by guard calls. Apply preconditions,
UID/ownership refusal and readiness semantics must pass existing recovery regressions unchanged
unless a documented stronger assertion requires an explicit test extension.


## Idempotence and Recovery


Sessions and epochs are ephemeral. On restart reacquire configuration and guard; never persist a
“guard passed” token as future authority. Cancellation drains or cancels workers, removes private
temporary connection files and leaves provider mutation recovery to the transaction journal.
A refused refresh cannot fall back to an old successful session. No write is retried solely because
a transport timeout occurred; only the existing adapter recovery proof authorizes retry.


## Interfaces and Dependencies


Hard prerequisite for M1–M3: [EP-224 M1](224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md);
M4 has none and may land first.
This plan owns `ClusterSession`, `ObservationEpoch`, transport identity binding and concurrency
limits. [EP-225](225-keep-platform-revisions-stable-when-deployment-meaning-is-unchanged.md)
supplies validation requirements but does not block this plan's standalone fixtures.
[EP-227](227-commit-verification-proofs-without-per-resource-remote-transactions.md) M2 requires
this plan's M1–M2 evidence. EP-228 consumes complete session invalidation and readiness support.
Do not add or pin a client library from memory; inspect Mori sources and verify authoritative
released versions before any dependency change.
