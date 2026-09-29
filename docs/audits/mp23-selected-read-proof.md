# MP-23 selected observation and store-cost production proof

2026-09-29. This implements the next repairs after `ebe91b7d`, under EP-153 and
EP-156. Source identities, complete test output, CLI reports, and transport traces
are retained in [the evidence directory](mp23-selected-read-results-2026-09-29/).
The tested final executable SHA-256 is
`bc1a46b08fcb4c879302051d46a5ff95a65372c6917d19e0865b15b3cb24a79f`;
[the source manifest](mp23-selected-read-results-2026-09-29/source-hashes.json)
binds the implementation and reproductions.

## Repairs and measured behavior

| Boundary | Previous behavior | Production result |
|---|---|---|
| Unknown explain target | Historical reviews and workspace setup before identity lookup | Refuses before native/workspace/provider setup, including with 500 malformed unrelated reviews |
| Two selected native bindings | Whole-review lookup/reconstruction amplified with siblings; historical scan amplified with unrelated reviews | Exactly two cold native GETs and zero lists at 0/500 unrelated reviews and 0/50 siblings |
| Empty native request | 1/51/501 cold GETs at 0/50/500 unrelated reviews | Zero GETs and zero lists, including the legacy execution-native helper |
| Selected Kubernetes/Helm explain | Observes the entire context and requires a workspace | One selected provider call, zero unrelated provider calls, no workspace needed in the absent-resource fixture |
| Complete journal append | 8 subprocesses for the initial event, 11 thereafter | 5 then 8; concurrent provider-generation replacement still refuses |
| Complete public no-op resume | 15 transport subprocesses | 12, unchanged across 50/500 events, 0/50/500 unrelated reviews, and cold/warm roots; exactly one journal batch |

`ObservationNative` is an opaque read-only result, separate from `ReviewBundle`.
Validated accepted/retained declarations provide authority. Their content digests
name unstamped Kubernetes bytes and Helm contracts directly. New review publication
adds those bytes to the existing private content store while preserving original
mutation envelopes and review hashes. Selected bytes are checked against their
content digest and declaration; source-only metadata changes rebind correctly.
Closed generated Namespace, backend-map, and Shomei contributions reconstruct
exactly without stored native payloads. No mutable index, admission projection,
or new head schema is introduced.

Status/explain selects before constructing provider adapters. It retains the full
validated graph for dependency and consumer explanations. Kubernetes and Helm
observation does not load execution payload files. Missing/corrupt selected bytes
fail before provider IO; missing unrelated native members and malformed unrelated
reviews do not block inspection. Original full-review validation remains on
admission, execution, export, and explicit historical extraction paths.

`ObservedHead` privately binds a validated head to its store and exact provider
generation. Append uses that token for compare-and-swap, eliminating rediscovery.
Tests reject reuse, identical bytes rewritten under a new provider generation,
intervening local changes, and migrated-head writes. Existing takeover, lost-ack,
hash-chain, conflict, and recovery tests remain green. Resume now loads the journal
prefix from its already observed head. It still checks a fresh head after registry
construction and retains writer-claim checks.

## Public compatibility and scale proof

[The CLI fixture](mp23-selected-read-results-2026-09-29/selected-cli.json) executes
14 commands against real prepared Kubernetes/Helm envelopes and synthetic accepted
history. Provider recorders allow observation and reject mutations. It covers
known and unknown identities, retained selection, foreign context, missing sibling
payloads, corrupt/missing selected bytes, and historical materialization. Every
command preserves the inventory head.

`inventory store materialize-native --limit 1` processes one of two original
reviews, prints progress and its continuation digest, then a new process resumes
with `--after`. Repeating a batch is idempotent. Only immutable observation copies
are added; no provider command occurs. The explicit limit is a review count,
not a byte limit. A missing observation never starts this extraction implicitly.

[The larger fixture](mp23-selected-read-results-2026-09-29/selected-large-cli.json)
repeats all 14 commands with 500 Kubernetes siblings plus the two selected bindings.
Its accepted scope is **290,677 bytes**. Initial Kubernetes/Helm explains took
0.581/0.232 seconds locally; selected explain with 500 malformed unrelated reviews
took 0.095 seconds and one provider call. These are whole-command times, including
scope decoding and recorded provider startup, not isolated decoder timings or GCS
latency. The accepted scope still must be decoded; total CPU/bytes are not claimed
constant.

[The saved recovery regression](mp23-selected-read-results-2026-09-29/legacy-recovery-cli.json)
removes every newly materialized observation copy from each disposable history,
while preserving its private mutation envelopes. The original transaction
`tx-f2ae688de99cee773253ae296a786fb09511d8b989bc6c424427471ac78e2941`
still passes all 11 before-effect, terminal/abandonment, changed-source,
completed/interrupted, and no-op cases. No provider mutation runs. Old admitted
recovery therefore has no materialization prerequisite.

[Append traces](mp23-selected-read-results-2026-09-29/append.txt) exercise the actual
`Execute.appendEvent` through recording gcloud transport, including a concurrent
head replacement. The [complete-command before](mp23-selected-read-results-2026-09-29/command-before.json)
and [after](mp23-selected-read-results-2026-09-29/command-after.json) reports capture
12 public no-op resumes each. The final 12 calls comprise two bucket/project
checks, a format read (three subprocesses), two head reads (six subprocesses),
and one journal batch. The recorder rejects every write. These synthetic
converged histories measure command composition, not cloud reliability.

## Validation and reproduction

The complete suite passes **943 tests in 44.48 seconds**. The managed-command audit
passes with **139 routes, 34 recipes, 26 library calls**, including the new bounded
materialization route. Both entrypoint guard suites, Haskell style, and strict
user/guide validation pass. Run Cabal commands sequentially from `cli/nagarectl`;
run the Python scripts from the repository root.

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
```

```bash
python3 scripts/test-inventory-command-cost.py
python3 scripts/test-inventory-selected-observation.py
MP23_OBSERVATION_SIBLINGS=500 python3 scripts/test-inventory-selected-observation.py
python3 docs/audits/mp23-reproductions/run-operational-cost.py transport history
```

After interpreted fixtures, restore the same Cabal configuration with the build
command above before the driver's freshness check:

```bash
MP23_LEGACY_OBSERVATION=1 python3 scripts/test-inventory-operation-driver.py
bash scripts/test-managed-command-audit.sh
bash scripts/check-haskell-style.sh
just user-documentation-validate
```

## Remaining boundary

F10 is Verifying, pending independent closure. F04 remains Partial: nonempty
legacy execution-native helpers still reconstruct historical reviews; the selected
status/explain path is fixed. F06 remains Partial: complete active-command
registry/startup cost, command-wide journal cursor work if measurement warrants it,
and real GCS latency are still open. The no-op fixture deliberately skips an active
registry, while the saved active recovery fixture uses local history; those proofs
must not be combined into an unmeasured cloud claim. Physical prune deletion,
receipt-only cleanup, separate retained-source recovery, and the existing host
prerequisites retain their previous acceptance gates. No live cloud operation was
performed for this checkpoint.
