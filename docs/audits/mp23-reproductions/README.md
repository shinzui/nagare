# MP-23 audit reproductions

These are archived diagnostic probes, not the supported regression suite. Findings and closure are tracked in [mp23-findings.md](../mp23-findings.md). They run locally and do not contact providers.

- `HostAudit.hs` calls the actual host adapter with recording callbacks. Run from `cli/nagarectl` under its Cabal environment with the package common extensions (`GHC2024`, `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`) and `-isrc`.
- `StoreAudit.hs` calls the store/status code with an in-memory ObjectOps implementation. To expose the otherwise private appendEvent for this diagnostic, copy Execute.hs to a temporary module overlay and add appendEvent to its export list. Compile the overlay ahead of `src`; do not edit the production module. The original ad-hoc environment also needed temporary package-qualified `"memory"` imports for Data.ByteArray in four source modules because runghc exposed both memory and ram. The Cabal package already selects memory. The original overlay remains in the temporary directory recorded in the initial report.
- `AgeKeyRetryAudit.sh` preserves the pre-fix activate function with fake command boundaries. Set AUDIT_CALLS to a temporary output file, then invoke with bash. It demonstrates the original failure; rerun the equivalent scenario using the current function to verify a fix. Its `/nonexistent` paths and overridden bash/host_ssh prevent real transport invocation.

Retained outputs are in the tracker. New checked-in regression tests should exercise supported public paths; these archived probes do not replace them.

`HostTests.hs` runs the checked-in host regression group. `PutTests.hs` checks the exact-generation parser while compiling the current ObjectOps source. `HostIdentityTransportAudit.sh` records the post-fix physical-identity refusal. Commands/results/source hashes are in [the verification log](../mp23-verification.md).
