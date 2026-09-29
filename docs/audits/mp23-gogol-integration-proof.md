# MP-23 Gogol ObjectOps integration proof

The pinned SDK now has a production-library `ObjectOps` adapter in
[Store/Gogol.hs](../../cli/nagarectl/src/Nagare/Inventory/Store/Gogol.hs). The CLI
still selects the existing gcloud backend. This checkpoint establishes the
transport/store contract before changing command authentication and selection.

## Implementation

Cabal and Nix both pin `mori://brendanhay/gogol/repos/gogol` at
`881cd14c9844131b4a8d96ca1bbb2bd9a2409ed9`, the current upstream `main` revision
selected in [the preceding experiment](mp23-gogol-transport-proof.md). The five
scoped upper-bound relaxations are identical in the two builds: gogol's aeson,
crypton, crypton-x509 and crypton-x509-store, and gogol-core's aeson. Nagare's
existing dependency versions remain in use; no global relaxation is introduced.
The Cabal manifest also receives its required formatter's module ordering.

The constructor takes explicit credentials, project and private GCS prefix. It
validates the location before auth IO, creates one reusable HTTP manager, and
performs no ambient credential discovery. Request redirects and automatic HTTP
retries are disabled. Auth initialization and individual SDK operations have
20-second bounds; these are not an overall command or pagination budget. SDK
exceptions are reduced to status-only internal failures so requests, credentials
and private response bodies are not emitted. Cancellation is not swallowed.

GET validates object identity and size, then downloads the observed provider
generation. Only a metadata 404 followed by a successful complete prefix listing
can prove absence. Incomplete or forbidden reads remain unknown. Conditional
creates use generation zero; replacements use the exact supplied provider
generation. A definite CAS 412 remains a conflict even if a competing write used
identical bytes. Failed or malformed acknowledgements use fresh readback and the
existing outcome classifier, without retrying the write.

Journal loading consumes every listing page before downloading. It rejects
foreign/duplicate names and invalid/repeated continuation tokens. Listing metadata
supplies generations, so each journal object needs one media request. Downloads
run in windows of eight workers. Any failed download rejects the batch; the
existing store still validates the committed journal prefix and hash chain.
No review, head, transaction, journal or migration schema changes.

## Verification

[InventoryGogolSpec.hs](../../cli/nagarectl/test/InventoryGogolSpec.hs) sends real SDK
requests to loopback WAI storage/OAuth servers. It does not mock the SDK itself
and uses no operator credentials or Google endpoint. Thirteen cases cover:

- Existing store contract and an ambiguous active transaction resumed to completion
  with exactly one native effect, including failed storage-write acknowledgements.
- Reserved/Unicode key encoding, exact-generation reads and conditional writes.
- Missing versus forbidden/unknown, malformed metadata, partial media and redirects.
- Idempotent create, conflicting create, and identical-byte generation races.
- Landed write/readback and unreadable readback, without retries or private diagnostics.
- Complete pagination of 50/500 entries, exactly one media request per entry plus
  one request per seven-item fixture page, with concurrency greater than one and
  no more than eight in each case.
- Repeated continuation tokens, duplicate/foreign pages, and pre-HTTP key/generation refusal.
- Immediate expiry followed by SDK refresh using the originally loaded user
  credentials after the credential file changes to another client.

The last case establishes refresh for explicit `authorized_user` credentials,
including compatibility with Nagare's JSON/crypto dependency versions. It does
not select the account for a real CLI command or prove service-account,
impersonation, token-file or workload-identity authentication modes.

[The full suite](mp23-gogol-integration-results-2026-09-29/full-tests.txt) contains
967 passing tests, including all 13 new SDK cases and the existing
claim/publication/hash-chain/recovery regressions. [The legacy public CLI matrix](mp23-gogol-integration-results-2026-09-29/legacy-cli.json)
passes all 11 cases against the existing backend with the new dependency graph;
it is not evidence of SDK command-factory adoption.
[The validation record](mp23-gogol-integration-results-2026-09-29/checks.json)
records the joint CLI/test build, source/manifest checks, command audit and Nix
derivation evaluation. A full Nix package build has not been performed.
[Source and binary hashes](mp23-gogol-integration-results-2026-09-29/source-hashes.json)
bind this candidate. These are correctness and request-count results, not a
whole-command latency benchmark.

## Remaining adoption boundary

Integrate one SDK environment through the real command store factory after
selecting explicit credentials that preserve the chosen gcloud account and any
supported credential override or impersonation. Unsupported modes must refuse
early. Do not silently choose ambient ADC merely because it authenticates.
Retain project/bucket ownership checks, private prefix and migration binding.

Then run public store migration and saved-transaction checks through the SDK and
measure cold/warm 50/500-event CLI paths. The previous real read-only timing
comparison remains applicable as motivation, but cannot stand in for this
complete-command evidence. Verify the final Nix build before release. Host/native
prerequisites and real conditional-write/recovery rehearsal remain open; no cloud
writes or global context changes occurred here, and MP-23/EP-156 are not complete.

## Reproduction

From `cli/nagarectl`:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
```

For the bounded SDK group, use the built test executable with
`--pattern Gogol --timeout 30s`. The raw full-suite result was produced by running
the built test executable with `--timeout 120s` from that same directory.
From the repository root:

```bash
bash scripts/check-haskell-style.sh
cabal-gild --mode check --input cli/nagarectl/nagarectl.cabal
python3 scripts/audit-managed-commands.py
nix eval --raw .#packages.aarch64-darwin.nagarectl.drvPath
```

The legacy CLI command is `MP23_LEGACY_OBSERVATION=1 python3
scripts/test-inventory-operation-driver.py`; it creates its own local fixture
when no fixture directory is supplied. The retained run reused the prior
synthetic prune fixture and refused all real provider effects.
