# MP-23 audit reproductions

The current production-driver regression is
`python3 scripts/test-inventory-operation-driver.py` after building
`exe:nagarectl test:nagarectl-test --enable-tests` in `cli/nagarectl`.
See [the production proof](../mp23-archive/mp23-rescue-proof.md) for commands and retained results.
The E1–E10 programs below are source-bound diagnostic evidence from the recorded
pre-repair revision. In particular, `PruneBoundary.py` and the `prune-executor-cf` /
`prune-executor-fixed` modes expect the old failing branch; they are not post-repair
regression commands. Their original outputs and hashes remain retained.


These are archived diagnostic probes, not the supported regression suite. Findings and closure are tracked in [mp23-findings.md](../mp23-findings.md). They run locally and do not contact providers.

The reproducible [2026-09-29 operational experiments](../mp23-archive/mp23-operational-experiments.md)
run with `python3 docs/audits/mp23-reproductions/run-operational-cost.py` from the
repository root. The runner prepares its own temporary source overlay, records
hashes, and executes `OperationalCost.hs`, `RecoveryBoundary.hs`, and five existing
replay checks through `ReplayChecks.hs`. `NativeEvidence.hs` exercises candidate
lookup and selected-member reconstruction with actual prepared Kubernetes/Helm
reviews. Run just that bounded spike with
`python3 docs/audits/mp23-reproductions/run-operational-cost.py native`.
Its temporary overlay also exposes `sameNativeBinding` and the `ReviewBundle`
constructor; the projected bundle is diagnostic-only and must never reach admission.
The production implementation needs a separate opaque evidence type. `fake-gcloud.py` is a local recording
transport and never forwards to real gcloud. `ExplainBoundary.py` exercises the
built public CLI with isolated state and refusing provider executables. Retained
results and limits are linked from the report; these are diagnostic probes, not
claims that the described production repairs have shipped.

- `HostAudit.hs` calls the actual host adapter with recording callbacks. Run from `cli/nagarectl` under its Cabal environment with the package common extensions (`GHC2024`, `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`) and `-isrc`.
- `StoreAudit.hs` calls the store/status code with an in-memory ObjectOps implementation. To expose the otherwise private appendEvent for this diagnostic, copy Execute.hs to a temporary module overlay and add appendEvent to its export list. Compile the overlay ahead of `src`; do not edit the production module. The original ad-hoc environment also needed temporary package-qualified `"memory"` imports for Data.ByteArray in four source modules because runghc exposed both memory and ram. The Cabal package already selects memory. The original overlay remains in the temporary directory recorded in the initial report.
- `AgeKeyRetryAudit.sh` preserves the pre-fix activate function with fake command boundaries. Set AUDIT_CALLS to a temporary output file, then invoke with bash. It demonstrates the original failure; rerun the equivalent scenario using the current function to verify a fix. Its `/nonexistent` paths and overridden bash/host_ssh prevent real transport invocation.

Retained outputs are in the tracker. New checked-in regression tests should exercise supported public paths; these archived probes do not replace them.

`HostTests.hs` runs the checked-in host regression group. `PutTests.hs` checks the exact-generation parser while compiling the current ObjectOps source. `HostIdentityTransportAudit.sh` records the post-fix physical-identity refusal. Commands/results/source hashes are in [the verification log](../mp23-archive/mp23-verification.md).

Follow-up probes from E8–E10:

- `run-operational-cost.py protocol` tests checked publication, six write-failure/acknowledgement boundaries, concurrent sidecar writers, and real export/restore with a bounded persisted rebuild cursor.
- `PruneBoundary.py` generates synthetic admitted history and invokes the actual built CLI with provider recorders. It requires an up-to-date CLI; run `cabal build exe:nagarectl` from `cli/nagarectl` first. Each CLI call has a 15-second deadline. Provider writes are refused.
- `run-operational-cost.py prune-executor prune-executor-cf prune-executor-fixed` compares the production executor, temporary removal of its up-front resume preflight, and that same counterfactual plus explicit terminal-failure handling. All use the actual two-operation prune review and Kubernetes adapter. The latter two alter **temporary source copies only**, are diagnostic, and must not be copied as production fixes. Production needs structural validation and dependency-ready live checks.

Each source probe has a 90-second deadline including compilation. Passing diagnostic assertions may deliberately confirm a current failure; they do not mean the corresponding product behavior is repaired.
