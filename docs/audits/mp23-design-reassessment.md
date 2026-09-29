# MP-23 design reassessment — 2026-09-29

The operator requested this reassessment immediately, rather than waiting for more
repairs to reveal whether the design is viable. This assessment uses IR-24, ADR 22,
the current source, and the retained [E1–E10 experiments](mp23-operational-experiments.md).
It adds no cloud run and makes no implementation or release-readiness claim.

Subsequent implementation: [the production operation-driver proof](mp23-rescue-proof.md)
now establishes the fixed execution/recovery consumer and 935 passing regressions.
The assessment below records the decision made before that patch. Selected reads,
command cost, and the remaining native/history acceptance are still open.

## Verdict

The ownership model remains justified. The present execution/read orchestration
needs a bounded replacement. Continuing to patch each new command prerequisite
independently is an inadequate implementation strategy. A rewrite of Nagare, a
new controller, or replacement of its native tools is not justified by this evidence.

The original problem was overlapping ownership and non-resumable work across
native tools. Typed scopes, collision checks, immutable review, and durable
receipts address that problem directly. They do not require four different layers
to decide when a live check runs, or require a resource inspection to reconstruct
historical mutation plans. Those are implementation architecture defects.

The previous three-checkpoint recommendation understated this distinction. Its
checkpoints describe verification; they do not establish a coherent design. E3's
single-operation success was incorrectly generalized to the executor as a whole.
E10 disproved that inference. Passing E8/E9 also does not establish that adding a
lookup publication/rebuild subsystem is the least costly design.

## Causal diagnosis

| Design obligation | Current implementation | Consequence and evidence |
|---|---|---|
| One owner of operation phase ordering | Main.hs registry helpers run live checks; Execute.hs also preflights at admission, on resume, and immediately before effects | E3 moves one check and restores recovery; E10 finds the same ordering defect inside the executor. Fixing one caller cannot establish the contract. |
| Recovery is a total operation-state transition | `RecoveryDecision` has four alternatives; ordinary `recoverOrStop` handles three; explicit operator recovery uses another decision tree | E10 reaches a non-exhaustive match after removing the preceding blocker. Terminal outcome handling diverged across paths. |
| Resource evidence and execution evidence have separate jobs | `Status.loadNativeFor` searches all published reviews; `loadPublishedReview` expands every native member before selecting a resource | E2 adds 500 unnecessary reads; E6's review pointer still reads 50 unrelated siblings. The access pattern follows execution history rather than the question being answered. |
| Operational cost is part of the store contract | Primitive conditional writes pass while complete appends repeatedly discover the same head and invoke serial CLI transports | E1 measures 8/11 subprocesses per append. Logical store conformance never promised acceptable command latency. |
| Feature proof includes the real consumer | Completed foundations and single-adapter tests are treated as evidence for command composition | E4/E10 find failures before the intended target/recovery boundary despite passing primitive tests. More test count alone will not change this. |

These findings do not show corruption of the typed ownership model or justify
weakening physical identity, native digest, writer claim, or conditional-write
checks. They show that the implementation does not make its phase and dependency
rules explicit enough to maintain.

## Retain, replace, and stop

Retain the scope/resource identity and collision model; existing accepted/converged
semantics; immutable scopes, reviews, native members, and receipts; the journal's
wire format and history; conditional head writes and explicit takeover; and native
Pulumi, host, Kubernetes, Helm, and data adapters. Preserve supported behavior and
all already-admitted recovery routes. Seven completed children are not revoked,
but their completion cannot certify consumers they did not exercise.

Replace the shared dispatch path in `cli/nagarectl/src/Nagare/Inventory/Execute.hs`
and the execution-registry responsibilities in `cli/nagarectl/app/Main.hs` and
`cli/nagarectl/src/Nagare/Inventory/Command.hs`. This is one cohesive refactor of
existing orchestration, not another engine alongside it. Replace the read path in
`cli/nagarectl/src/Nagare/Inventory/Status.hs` with an explicit selected-resource
projection. Keep full review validation for admission and integrity inspection.

Stop adding feature variants and stop long native rehearsals while this replacement
is being implemented. Preserve ongoing evidence and histories. Existing support and
release gates remain requirements; this sequencing decision does not silently drop
features, restore legacy mutation bypasses, or mark unfinished work complete.

Remove mandatory rollout of the proposed mutable lookup sidecar/rebuild protocol
from the immediate recovery critical path. E8/E9 establish how that candidate could
behave, not that recovery should acquire another prerequisite. An evidence index may
be an acceleration mechanism, but its absence must not revoke an existing review's
recovery authority. A bounded explicit compatibility extraction may still be needed
for old records; it must not silently become a scan on every ordinary command.

## Replacement boundary

### One serial operation driver

Create a small internal module, for example
`cli/nagarectl/src/Nagare/Inventory/OperationStep.hs`, that converts the authenticated
review graph and validated journal into the next action. Keep deterministic serial
execution and the existing writer lock. This does not introduce a scheduler daemon,
parallel execution, or new persistent state.

The internal result is a finite alternative: finished, blocked with an exact reason,
recover this uncertain operation, or execute this dependency-ready operation. A
completed operation is skipped. An intent/ambiguous/partial-effect operation is
recovered before a later operation's live predicates can run. A terminal or unknown
outcome stops at its original operation. An untouched/known-no-effect operation may
execute only after its declared dependencies have completion proof. Operator
resolution records are interpreted explicitly; unknown legacy markers stop rather
than becoming success. Preserve specialized fence recovery obligations.

The IO interpreter is the sole caller of operation-time preflight and mutation.
Apply and resume both enter this driver after their different authority checks.
Whole-review validation verifies structure, membership, versions, capabilities,
native digests, and base/claim requirements; it does not ask a future operation to
satisfy live conditions that a predecessor is supposed to establish. Keep any
necessary pre-admission observations limited to checks that really must precede
admission, such as reviewed ownership/retention proof. Classify every moved check;
do not blanket-delete admission checks to make the fixture pass.

Handle every `RecoveryDecision` constructor explicitly. Terminal failure returns a
stable stopped result with physical identity and the available operator action;
it never becomes automatic retry, convergence, or an exception. The explicit
operator command continues to require independently checked provider proof.
Per-operation preflight and effect-time conditional guards still run immediately
before every permitted mutation. Exhaustiveness warnings must fail compilation
for this transition module and its recovery interpretation, without adding a
repository-wide warnings migration.

### Immutable construction; phase-specific live checks

A registry constructs the selected adapters from validated immutable inputs. It may
load pinned files but performs no provider observations whose meaning depends on
whether an operation has already happened. Move such checks into the appropriate
adapter phase and identify that phase in the code. Shared identity/context checks
remain mandatory at the actual provider boundary.

Execution inputs must identify their exact historical source, not find whichever
scope happens to be currently accepted after admission changes the head. Reuse the
review's base/desired scope references, native members, retained-incarnation records,
and existing source/UID pins. Add a pinned input reference only where those are
insufficient; version that extension, and retain a verified legacy reader. Do not
rewrite old reviews, infer authority from provider labels, or require a successful
new-admission predicate to recover an old transaction.

Only selected executors may require a payload workspace, host environment, or
provider client. A required immutable asset must fail with its specific missing or
mismatched identity before expensive work. Do not silently substitute today's
workspace for the reviewed payload.

### A resource read view and a store cursor

Status/explain first selects accepted/retained declarations and the necessary
related resources. It then reads validated native observation inputs for those
bindings. It must not construct a mutation registry. The E6 selected-member
reconstruction establishes a usable direction; implement it as a distinct read
value that cannot be admitted as a fabricated `ReviewBundle`.

For digest-bound resource types, evaluate storing the already-validated native
observation bytes by their content digest during review publication, separately
from the operation's stamped mutation envelope. For generated declarations without
a native digest, preserve exact declaration/contribution reconstruction. This is a
format choice to resolve in the bounded EP-156 implementation, not a newly proven
schema or a reason to add a general indexing service. Selected corrupt original
bytes must fail. Persisted references, reconstruction, and optional caches must
remain subordinate to accepted/retained ownership authority.

Keep the previously tested observed-head optimization, but make one validated
journal/head read feed the command's operation driver. Appends carry their observed
provider generation and previous-event digest through conditional advancement;
they cannot use an unvalidated mutable cache. Existing lost-ack, claim, takeover,
and hash-chain obligations remain. Count the complete command; a shorter helper
trace is not its performance acceptance.

## Alternatives and decision

| Option | Assessment |
|---|---|
| Keep patching factories, global preflight, and each recovery branch independently | Reject as the primary strategy. It leaves phase ownership distributed and predicts the same class of failure recurring. An urgent narrow compatibility fix can still precede the refactor. |
| Replace orchestration/read boundaries while retaining models, formats, adapters, and history | Recommended. It targets every reproduced mechanism and limits compatibility risk. It also permits reuse of the existing fixtures as executable acceptance. |
| Restart Nagare or immediately move the remaining work to another controller/workflow system | No evidence that this is a quicker exit. It introduces ownership/history migration and does not establish Nagare's exact data-recovery behavior. External-tool evaluation remains separate; no replacement is selected here. |

The recommendation is a bounded architectural repair, not a promise about calendar
time. Do not give another multi-day completion forecast from the current test count.
The current release contract is still substantial; this work alone does not finish
packaging, cloud proof, or all supported data features.

## Concrete implementation handoff and stopping rule

EP-153 owns the operation driver and registry boundary. EP-159 supplies the existing
E10 two-operation fixture as its consumer, plus source/retained-history cases.
First produce one production patch that passes that fixed fixture with absent,
completed, terminal-failed, interrupted, and changed-source outcomes. The patch must
remove the duplicate live-dispatch path and preserve old review/journal decoding.
Do not start a new matrix of engine variants before that patch is reviewable.

EP-156 then owns the selected read projection and command-scoped store cursor;
EP-153 supplies the known/unknown-target public consumers. E1/E2/E6 and the existing
lost-ack/takeover checks supply acceptance. The earlier index protocol is retained
as experimental evidence, with mandatory rollout superseded by this reassessment.

A fresh CLI process must recover the original transaction using immutable history
without regenerating its native plan. The fixed workflow's provider calls and
history reads must be attributable to selected inputs and required operation
steps. Existing real-cloud latency targets still apply before cloud expansion.

If this bounded replacement cannot support the fixed existing contract without a
new persistent workflow engine, rewriting old admitted history, or another layer
of feature-specific scheduler exceptions, report that exact contradiction and stop
expanding the design. Present a concrete scope/replacement choice to the operator
instead of adding another framework or silently weakening acceptance. No such
contradiction has yet been established; equally, the replacement is not yet proven.
