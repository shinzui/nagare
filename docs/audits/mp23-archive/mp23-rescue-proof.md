# MP-23 production operation-driver proof — 2026-09-29

The first architectural repair is implemented in production code. Apply and resume
now share the pure phase decision in `Nagare.Inventory.OperationStep` and its IO
interpreter in `Execute.hs`. The existing two-operation prune failure no longer
requires a temporary code substitution to reach recovery. This establishes the
execution/recovery part of the proposed rescue, not completion of MP-23.

## What changed

The whole-review live-preflight sweep and the old topological dispatch loop are
removed. Structural graph, adapter, native-member, and fence validation remain.
Only durable completion satisfies a dependency. Uncertain effects are recovered
before untouched work; safe retry still requires completed dependencies and live
preflight. All four recovery outcomes are explicit, with incomplete pattern matches
failing compilation. Unknown legacy operator-resolution markers stop instead of
silently becoming permission to execute. Review and journal formats are unchanged.

The CLI uses the same registry for apply, resume, and explicit recovery. Its prune
provider checks moved into the Job-creation preflight; a recovered completed or
terminal Job does not need the original pre-effect provider listing. The current
transaction's accepted prune scope is excluded from the set of earlier prunes when
checking a new submission. Exact native, source UID, and provider conditional-effect
checks remain in the existing adapter.

Retention admission still re-observes the original physical incarnation. The first
full regression run exposed a migration admission dependency on the old sweep:
`changed source incarnation refuses admission before advancing history` failed.
The fix preserves that specific source-binding check before ownership transfer,
using the existing `BackUpSource` adapter preflight contract, and never invokes it
as an up-front resume requirement. This check must not depend on destination-stage
effects. The final full suite passes, including migration interruption and source
identity refusal. No new workflow engine, persisted state, or historical rewrite
was introduced.

## Before and after, using the same history

The pre-change binary and repaired binary consumed copies of the same immutable
review and journal, transaction
`tx-f2ae688de99cee773253ae296a786fb09511d8b989bc6c424427471ac78e2941`.
[Before](mp23-rescue-results-2026-09-29/before-cli.json), ordinary resume refused at
the dependent Job-completion preflight. E10 separately exposed the terminal-pattern
exception behind that blocker. [After](mp23-rescue-results-2026-09-29/after-same-history-cli.json),
the production CLI produced these results:

| Recorded provider state / command | Result | Provider calls | Journal advancement |
|---|---|---:|---:|
| Absent original Job; object-store configuration deliberately missing; resume | Known-no-effect stop before a new submission | 4 reads, zero writes | 0 |
| Terminal failed Job; resume | Stable ambiguous result at the original create operation; no exception | 2 reads, zero writes | 0 |
| Exact failed Job; explicit abandonment | Abandoned, active transaction cleared; provider members remain unresolved | 2 reads, zero writes | 1 resolution |
| Changed source UID; resume / explicit abandonment | Stops / refuses unsupported recovery; original transaction remains active | 2 reads each, zero writes | 0 |
| Completed original Job; resume | Recovers original completion, runs dependent verification, converges | 8 reads, zero writes | 4 events |
| Running Job; resume, then a fresh process after provider completion | Stops, then converges without recreating the Job | 2 then 8 reads, zero writes | 0 then 4 |
| Resume after convergence | Returns convergence without provider access or head changes | 0 | 0 |

These eleven fresh CLI invocations took 0.030–0.429 seconds each on the local
recorders. They are not cloud latency measurements. The independently generated
repeat is retained in [fresh-fixture-cli.json](mp23-rescue-results-2026-09-29/fresh-fixture-cli.json).

## Regression evidence and reproduction

`InventoryTransactionSpec` also exercises a newly admitted, planner-produced
create/dependent-operation pair without synthesizing admission. Its trace is
exactly create preflight, create effect, original-effect recovery, dependent
preflight, dependent effect. A second resume adds no calls. Other assertions cover
terminal/unresolved outcomes, every persisted operation-state alternative, explicit
safe-retry markers, unknown markers, missing/duplicate/cyclic dependencies, and
completion proof requirements.

The final complete suite passes **935 tests** in **48.42 seconds**. Command audit,
both public entrypoint guard scripts, and the repository Haskell style check pass.
See [validation.txt](mp23-rescue-results-2026-09-29/validation.txt). F09/F12/F13 have a
production candidate and retained regression evidence; tracker status remains
Verifying for independent closure.

From the repository root:

```bash
(cd cli/nagarectl && cabal test nagarectl-test --enable-tests --test-show-details=direct)
(cd cli/nagarectl && cabal build exe:nagarectl test:nagarectl-test --enable-tests)
python3 scripts/test-inventory-operation-driver.py
bash scripts/test-managed-command-audit.sh
bash scripts/check-haskell-style.sh
```

The public fixture runner verifies the build before generating history. It isolates
configuration, kubeconfig, provider executables, and store roots; every provider
mutation is refused. Each CLI call has a 15-second timeout. It retains source and
binary hashes, before/after heads, output, and provider calls in the reported root.
An optional existing fixture-root argument repeats the same saved history.

## Bounds on this proof

The public history is synthetic already-admitted history built with real review
compilers and immutable store APIs. Provider observations are controlled responses;
no backup object or receipt is physically deleted, and no live cluster is used.
The absent-Job case proves the new-effect preflight still refuses missing required
configuration; it does not prove successful provider submission. Existing unit
regressions exercise adapter-proved safe retry.

A trial combining this scheduled-prune declaration with retirement of its required
source was rejected by composition as a dangling dependency before provider IO.
It was discarded rather than forcing an invalid review through the fixture. The
original fixture generator is unchanged. This does not establish the separate
retained-source CLI or receipt-only cleanup acceptance cases.

Selected-resource read isolation (F04/F10), complete cloud append cost (F06), and
native recovery/release acceptance remain open. The registry still contains other
workspace and historical-evidence setup that belongs to those follow-on repairs.
The proven conclusion is that replacing the phase boundary works for the fixed
consumer while preserving the existing suite. It does not establish that every
remaining feature or performance obligation is finished.
