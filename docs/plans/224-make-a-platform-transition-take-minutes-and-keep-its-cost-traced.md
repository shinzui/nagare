---
id: 224
slug: make-a-platform-transition-take-minutes-and-keep-its-cost-traced
title: "Make a platform transition take minutes and keep its cost traced"
kind: exec-plan
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
created_at: 2026-10-29T14:31:55Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-29T14:31:55Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T14:58:45Z
      verdict: "changes-requested"
      note: "Architecture review found blanket bootstrap verification, source-sensitive scope revisions, an incorrect verify-path diagnosis, missing crash and changed-rollout gates, and Python tooling conflicting with ADR 24; applied through MasterPlan 30."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:44:53Z
      verdict: "comments"
      note: "Counters, tracePhase, invokeKubectl and review-count claims verified; test registration lives in test/Nagare/Test/Suite.hs and the harness cabal.project must gain the nagarectl package"
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T14:58:45Z
      mode: "update"
      note: "Make EP-224 the measurement and final acceptance child of MasterPlan 30; assign semantic identity, sessions, journal proof and rollout orchestration to EP-225–228, with Haskell-only tooling and a Rei intention."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:45:25Z
      mode: "update"
      note: "Correct the test registration path and state the harness cabal.project change the nagarectl dependency needs"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T19:47:51Z
      mode: "implement"
      note: "M1: versioned command trace and production-path baseline fixture"
---

# Make a platform transition take minutes and keep its cost traced

This ExecPlan is a living document. It is the measurement and final acceptance child of the
MasterPlan named in frontmatter. Implementation progress must remain distinct from planning work.


## Purpose / Big Picture


Make transition cost explainable and prevent latency from returning after the architecture is
fixed. A developer sees the changed scopes, provider work, readiness waits, store traffic and
elapsed time for both successful and stopped rollouts. A release carries comparable evidence and
fails the performance check when an applicable target regresses. The root fixes are owned by
EP-225 through EP-228; this plan measures them through production paths.

An unchanged-content, artifact-ready transition must plan each stage in under 60 seconds and
finish candidate-pin start through transition commit in under 300 seconds. A single stateless
update and four independent stateless updates must complete plan plus apply within 300 seconds
when provider readiness takes at most 60 seconds per resource, with at most 60 seconds of
Nagare-owned overhead. Measure preparation separately and also report the full end-to-end total.
No local timing fixture proves intranet performance. Five consecutive warm native samples must
all pass; report their median and maximum and at least one cold run. Provider failures remain
failed samples with their cause, not silently omitted observations.

New tooling is Haskell in the existing cabal workspace. The previously proposed
`scripts/transition-cost.py` is withdrawn. The intended reporting command is
`nagare-harness transition-cost history --root docs/release-evidence`; it is not implemented yet.


## Progress


- [x] M1: A versioned command trace and production-interpreter fixture distinguish logical calls,
  actual network traffic, critical-path duration and failure outcomes for no-op and changed work.
  Pass, 2026-10-29: `cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p
  TransitionCost'` runs nine cases in `cli/nagarectl/test/TransitionCostSpec.hs` (codec and
  unknown-schema refusal, uncovered time, thrown phase, overlapping operations, private
  `NAGARE_TRACE_FILE` on completion/failure/cancellation, snapshot reuse, denied guard, lost store
  reply, production plan/apply over the fake API server). Observed 206-member baseline: an
  unchanged plan reads 206 objects and plans nothing; a marker change plans 205 verifies and one
  update, reading each member twice (412) and 414 times on apply; one changed member still plans
  205 verifies, four plan 203 verifies and three updates. Codec:
  `cli/nagare-contract/src/Nagare/Contract/Trace.hs`; producer: `Nagare.Inventory.Trace`.
- [x] M2: A Haskell cost-record producer, validator and history command consume actual CLI output,
  enforce structural budgets and retain failed/incomplete attempts without exposing secrets.
  Pass, 2026-10-29 (landed `6cb6868d`, `28df690e`, `93976286`): the runner gives every candidate
  plan, apply and resume a `NAGARE_TRACE_FILE` and records it on the run index;
  `nagare-harness transition-cost fixture|collect|check|history` (harness `-p TransitionCost`,
  five cases). The structural case (`-p "/journal writes do not grow/"`) holds a marker sweep at
  0 verifies and 4 journal events for 205 and 2,050 members, unchanged beside 50 unrelated
  scopes. Native: the disposable v0.11.0 → `842cd70c` rehearsal collected with no trace missing
  and passed: stage 2 planned and executed 1 update and 213 validations (plan 31.7 s, apply
  28.6 s, 839 Kubernetes requests, 879 external processes), stage 3 replanned to nothing in
  18.9 s; activation 83 s, end-to-end 498 s. A failed run collects as failed.
- [ ] M3: Completed architectural children pass the interpreter, compatibility, growth and native
  latency matrix, with evidence bound to the final candidate and no Python in the rollout path.
  Local pass, 2026-10-30: five warm rehearsal samples of `597c9662`, all passed
  (`docs/release-evidence/597c9662e3f436f0383c8af466d9961775c4d70e/transition-cost-1..5.json`;
  activation 48.6–56.6 s, slowest plan 21.1 s). Intranet fail, 2026-10-30: the v0.12.0 candidate
  `91d54e06` moved the intranet in 7.6 min (v0.11.1: about 16 min), but
  `docs/release-evidence/91d54e06a4d1696f01adfe10b2046736a49e0611/intranet-cost.json` fails: stage
  plans 89.1/64.6/44.5 s (limit 60), activation 315.4 s (limit 300). Stage 1's plan spends 70.4 s
  preparing the new candidate workspace (Pulumi Node dependencies), so it is not artifact-ready;
  stages 2–3 spend 25.1/23.2 s observing the remote cluster.
  Intranet fail, 2026-10-30: v0.12.1 (`f116da4a`, fixes in `e5abae3e`) plans within budget
  (`docs/release-evidence/f116da4a3df3ae9941aaa12d8d999e4d9893d147/intranet-cost.json`: 14.8 s
  after 56.6 s artifact preparation, 37.6 s, 22.2 s) but activation is 325.5 s of 300: stage 1's
  first host preflight (GCE describe and SSH reads over IAP, unchanged code) took 86.1 s against
  10.1 s in v0.12.0, and the host transport keeps no stderr to say why.

2026-10-29 handoff: the original plan was authored by `claude-opus-5-5` and had no recorded reviews.
This architecture review corrects source claims and distributes its former M2–M5 across four new
children. None of the original implementation milestones was complete or has been counted as done.


## Surprises & Discoveries


The reported v0.11.1 candidate incident used revision `ef5a537c` and local run directory
`~/.local/state/nagare/releases/v0.11.1/20261029T140458Z/intranet/`. Stage 1 reportedly had two
operations; stage 2 reportedly planned for about 3.5 minutes. This review read stage 2's saved
`review.json` and confirmed 211 operations: 205 Kubernetes `VerifyResource`, five Helm
`VerifyResource`, and one Kubernetes `UpdateResource`. Earlier reports sampled repeated
`kubectl get nodes` and ten head reads/ten puts for a single access apply. Those timings and
counts are incident leads, not a measured baseline for this fixture.

The 2026-10-29 source review at `5c57e81785cd04d03dee424e7b70966987b9814b` found that the driver
already bypasses `adapterExecute` for `VerifyResource`; preflight and verification each observe.
A changed bootstrap marker triggers broad verifies in `Plan/Changes.hs`, independently of
source-location churn. `Bootstrap/Platform.hs` still compares canonical scope bytes including
provenance. The original plan therefore understated the causal work and misidentified one read.

`Store/Counters.hs` currently has process-global aggregate phase and wire counters; `tracePhase`
does not record a phase that throws. `invokeKubectl` can invoke an in-memory interpreter, so
counting every call there as a remote request would count snapshot hits as network traffic.
Existing release/rehearsal scripts also contain embedded Python, contrary to the target tooling
contract. A local rehearsal currently writes a transition rehearsal record, not an intranet cost
record at the glob the old plan specified.


## Decision Log


- 2026-10-29: Supersede the standalone-plan decision with MasterPlan 30. The user authorized
  architectural expansion, and the source review requires independent semantic, session, journal
  and coordinator contracts.
- 2026-10-29: Measure one representative real path before optimizing, then keep operation-count
  bounds and native latency gates. Do not demand that every counter only decrease: a justified
  safety check can increase one count while reducing total cost, with reviewed budget rationale.
- 2026-10-29: Replace the proposed Python report with typed Haskell tooling under ADR 24 and the
  user's instruction. The runner port belongs to EP-228; this plan owns its record schema.
- 2026-10-29: Failure, cold preparation, retries and time waiting on the provider are first-class
  measurements. Partial records never count as passing evidence.
- 2026-10-29: M1's production fixture uses Kubernetes members only. Helm verifies run the same
  driver path through another adapter, and the fake world has no Helm server; Helm counts are
  measured natively and enter the structural fixtures when EP-226 M3 shares its session.
- 2026-10-29: The request-chunking and journal-history budgets are asserted where their
  behavior is built: EP-226 M2 (grouped reads at 128 names) and EP-227 M2 (a catch-up tail that
  does not grow with history). Asserting them here first would only record today's linear cost.
  Stages the published source release runs carry no trace and are setup, not measurements.
- 2026-10-29: The fixture's rows assert today's costs, including the full re-verify a single
  change causes while a scope's bootstrap marker is unsettled. EP-225 and EP-227 lower these rows
  deliberately; they are not budgets.
- 2026-10-30 (operator: fix the intranet miss under EP-224): one plan prepares the host
  closure once, traced as `artifact preparation`; a plan's 60 s budget excludes it, as this plan's
  "artifact-ready" target says, and activation's 300 s includes it. Executors and Helm releases
  observe concurrently, and a command opens each remote store once. One intranet sample per
  release counts toward the five.


## Outcomes & Retrospective


Planning revision only. The architecture has been reviewed and implementation ownership assigned;
no runtime optimization or performance gate has yet been demonstrated.


## Context and Orientation


A scope is an independently accepted group of declared resources. A review binds the desired
scope revisions, planned operations and live evidence to an inventory head. The head is the
mutable pointer to committed immutable state; conditional replacement prevents two writers
from committing against the same old state. The journal records each operation's outcome.

`cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs` calls
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs` to plan the next stage and commits the
context pin after convergence. `scripts/release-intranet.sh` pins the operator input, loops
plan/apply, also applies declaration-only changes, then commits the transition. It stops only
when both operation count and non-stamp re-acceptance count are zero, not merely on zero operations.
The operator project is `mori://tan/tan-ng-labs`; no private contents belong in public evidence.

`cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs` measures logical store work and actual
HTTP request classes. `cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs` is the
injectable Kubernetes request boundary. `cli/nagarectl/src/Nagare/Ops/ClusterGuard.hs` currently
launches its own kubectl calls. `cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs` owns
operation execution and `cli/nagarectl/src/Nagare/Inventory/Execute/Journal.hs` appends events.
`cli/nagarectl/src/Nagare/Inventory/KubernetesSnapshot.hs` currently batches status reads.

`cli/nagare-harness/app/Main.hs` and `cli/nagare-harness/nagare-harness.cabal` host maintainer
commands outside the platform payload. The versioned trace codec lives in
`cli/nagare-contract/src/Nagare/Contract/Trace.hs`, the small schema package nagarectl already
depends on; the harness adds `../nagare-contract` to `cli/nagare-harness/cabal.project` and
`nagare-contract` to its build-depends, never the nagarectl library, so the pre-push harness build
stays fast. The trace carries operation counts by action and executor, so the collector never
decodes review JSON. Register new
nagarectl test modules in `cli/nagarectl/test/Nagare/Test/Suite.hs` (the two-line `test/Spec.hs`
only calls it) and `cli/nagarectl/nagarectl.cabal`; harness tests are assembled directly in
`cli/nagare-harness/test/Spec.hs` and the harness cabal file.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) preserves
review and journal authority. [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
requires Haskell tooling. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
requires production interpreters and currently uses the fast model tier; native runs confirm.
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
prohibit replacing recovery evidence with performance assertions.


## Plan of Work


### M1 — Trace the work that really happens


Extend counters, define the versioned JSON codec in `cli/nagare-contract/src/Nagare/Contract/Trace.hs`
and add the producer `cli/nagarectl/src/Nagare/Inventory/Trace.hs` that fills it. `nagare-contract`
has no test suite, so the codec's round-trip tests live in the nagarectl and harness specs below.
Use monotonic elapsed time and explicit span identities with parent command, stage, operation,
epoch and attempt. Capture result class, retries, queue time, provider wait, cache hit, bytes,
store metadata/media/uploads, external-process count and actual Kubernetes requests by purpose.
Preserve existing human trace lines. `NAGARE_TRACE_FILE` alone enables collection. Flush a private,
atomic JSON file on normal completion, handled failure and cancellation; a hard kill may leave
no final file and must be reported as incomplete by the runner. Trace failures must not mask an
operation's real result. Do not store native bodies, credentials, kubeconfig contents or raw argv.

Instrument the actual interpreter/transport dispatch as well as logical observation. A snapshot
hit increments reuse, not network. Route guard subprocess attribution through the same recorder
without double counting. Measure runtime setup, inventory opening, compilation/rendering,
planning, publication, admission, proof, effects, readiness and finalization. Sum neither nested
spans nor concurrent durations as elapsed wall time. Explicitly include unclassified elapsed
time and make uncovered phases visible.

Add `cli/nagarectl/test/TransitionCostSpec.hs` using the production planner, adapter registry,
driver, fake API server and fault-capable object store. Start with the confirmed 205 Kubernetes
verifies, five Helm verifies and one update, then separate unchanged, one-change, four-independent-
change and interrupted scenarios. Retain a compact sanitized fixture generated from real review
output. Do not dump the private review bundle. Assert baseline exact counts only after observing
this path; no hand-guessed numbers. A clock/interpreter with deterministic delays proves that
the critical path and concurrent attribution are correct without slow sleeps. Acceptance includes
a thrown phase, denied guard, a cache hit, lost store reply and two overlapping operations.

### M2 — Turn traces into durable budgets


Add `cli/nagare-harness/src/Nagare/Harness/TransitionCost.hs` and
`cli/nagare-harness/test/TransitionCostSpec.hs`. Implement `transition-cost fixture --out DIR`
to export a sanitized codec fixture for the collector examples, `transition-cost collect --run DIR
--out FILE`, `transition-cost check --record FILE`, and `transition-cost history --root DIR`.
EP-229's versioned run index supplies stable relative trace paths, source/target revisions,
environment, candidate and artifact identities, stage/attempt IDs and start/end outcomes. Collection
must work on records produced by actual CLI invocations, including failure and resume, before
EP-228 M3 uses it.
Output `schemaVersion`, measurement profile, sample IDs, command/stage intervals, preparation and
activation totals, operations by action/executor, physical requests, reuse, retries and budget
results. Unknown schema versions refuse; absent traces are incomplete; local rehearsal and
intranet profiles are never conflated. Atomic failure records coexist with the last passing record.

The structural suite uses 205 and 2,050 unchanged members with fixed kind/namespace distribution,
then increases that distribution and tests request chunking separately. Also add 50 unrelated
application scopes and grow journal history from 100 to 10,000 events. A no-op release creates no
per-member verify operations or per-member journal writes; its live platform proof may scale by
bounded observation groups and bytes. A one-member change creates no unrelated mutation or
re-acceptance. Journal control-plane round trips for V required verifies scale with chunks of
64, not V; immutable event bytes/uploads may remain linear. Unrelated scopes add zero provider
calls or warm remote immutable reads. Record local hydration CPU and bytes instead of asserting
constant total CPU. Warm historical journal transfers must not grow with untouched old history;
cold transfers remain explicit. Retain MP-29's reviewed-access checks.

Budget constants live with fixtures and have a rationale. Planned limits are one guard admission
per stable session generation, at most eight concurrent Kubernetes reads, at most four concurrently
waiting independent stateless effects, and bounded retries. Count the guard's subprocesses
separately. Wire-level failures have their own request/retry limits, not the happy-path budget.

### M3 — Close the rollout performance gate


After EP-225–228 are Complete, run the packaged previous-release to candidate rehearsal and the
native matrix specified in Purpose. Reuse immutable artifact preparation across warm samples,
but create a valid source context for each transition; a second “already at target” invocation is
not another successful sample. Keep data sentinels and exact source/target identities. Record the
operator workstation, context, object counts, store backend, artifact/cache state and provider
latency. Publish sanitized `transition-cost.json` for local confirmation and `intranet-cost.json`
beside `docs/release-evidence/<candidate-revision>/transition-rehearsal.json` through the normal
release evidence path. Historical v0.11.1 values remain unknown where no trace exists.

Confirm EP-229's Python-free proof on the final candidate. Verify the user sees a stage/progress
update at least every five seconds while waiting and an exact resume/close command on interruption.
Budget failure keeps this plan and its parent open with a measured next fix. Neither a passing
fixture nor “slowest phase identified” substitutes for the native latency requirement.


## Concrete Steps


From the repository root, after adding the named tests and commands:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p TransitionCost' --test-show-details=direct
cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-options='-p TransitionCost' --test-show-details=direct
cabal run --project-dir=cli/nagare-harness nagare-harness -- transition-cost fixture --out /tmp/nagare-transition-run
cabal run --project-dir=cli/nagare-harness nagare-harness -- transition-cost collect --run /tmp/nagare-transition-run --out /tmp/nagare-transition-cost.json
cabal run --project-dir=cli/nagare-harness nagare-harness -- transition-cost check --record /tmp/nagare-transition-cost.json
cabal run --project-dir=cli/nagare-harness nagare-harness -- transition-cost history --root docs/release-evidence
```

The fixture command creates `/tmp/nagare-transition-run` from the same sanitized sample used by
the codec tests; it refuses an incompatible existing run directory. It makes the collect example
reproducible, but synthetic fixture output is never eligible for native acceptance.
Expected output distinguishes `passed`, `failed` and `incomplete`, includes sample counts, and
returns nonzero for failed/incomplete checks. No illustrative timing is presented as a result.

For native confirmation, substitute the actual revision and previous version:

```bash
just release-rehearse <candidate-revision> <previous-version>
just haskell-style-check
just gate-fast <committed-candidate-revision>
```

EP-229 preserves this recipe while moving its logic to Haskell. A committed-candidate gate checks
that revision, not uncommitted edits. Use the normal release runbook for an intranet candidate;
this planning task does not run one. Do not search or read `/nix/store` to inspect dependencies.


## Validation and Acceptance


M1 passes when counts come from the production path, interpreter timing catches missing/overlapping
spans, exceptions leave an honest record, and private bytes never appear. M2 passes when real
command records round-trip, history rejects incompatible profiles, structural growth budgets
fail deliberately regressed fixtures, and missing evidence cannot yield green. M3 requires all
five warm samples for each native workload, a cold report, bounded failure recovery, the final
candidate's release gates and Python-free execution. Preserve source output used to establish
each assertion and document any environment-specific limitation without weakening the gate.


## Idempotence and Recovery


Use a new run/attempt directory for each invocation. Never overwrite accepted evidence on retry.
Records are observations, not permission to replay a provider mutation. Resume uses the existing
transaction identity and authoritative journal; the cost collector merely links attempts.
Redact evidence before committing it. Keep original failed traces locally. No fixture contacts
the intranet or changes its pin.


## Interfaces and Dependencies


This plan owns the trace codec and harness cost schema. The hard dependency for M3 is completion
of [EP-225](225-keep-platform-revisions-stable-when-deployment-meaning-is-unchanged.md),
[EP-226](226-share-bounded-cluster-observations-through-a-guarded-command-session.md),
[EP-227](227-commit-verification-proofs-without-per-resource-remote-transactions.md),
[EP-228](228-run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress.md) and
[EP-229](229-own-candidate-intranet-and-rehearsal-orchestration-in-haskell.md).
M1 and M2 have no such dependency and unblock those children. Reuse existing Haskell dependencies;
before selecting any new API or bounds, discover source with Mori and verify released versions
against upstream and the authoritative package registry.

Revision note, 2026-10-29: replaced the standalone optimization sequence with the measurement
child of MasterPlan 30, corrected the verify path and rehearsal assumptions, added changed-rollout,
growth, failure and compatibility gates, and removed the Python tooling proposal.
