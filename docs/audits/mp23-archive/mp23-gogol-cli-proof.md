# MP-23 Gogol command integration proof

GCS inventory commands now select the SDK by default. The shared
[remote factory](../../../cli/nagarectl/src/Nagare/Inventory/Store/Remote.hs) serves
ordinary reads/writes and migration dry runs; stored context/project, bucket
ownership, private prefix and history binding checks remain in place. The
[operator runbook](../../runbooks/inventory-gcs-transport.md) describes authentication
and the explicit `NAGARE_INVENTORY_GCS_TRANSPORT=gcloud` compatibility switch.
No stored format changes or history migration are required for this adoption.

## Credential selection and lifecycle

[The credential bridge](../../../cli/nagarectl/src/Nagare/Inventory/Store/GcloudAuth.hs)
uses gcloud's structured config-helper response, including real token expiry.
It captures the account, named configuration, impersonation setting, project and
Storage endpoint. Explicit account/configuration/impersonation selections must
agree with the response. Ownership probes and refresh use that captured context;
refresh cannot silently adopt another account or impersonated identity. It never
reads ADC or gcloud's credential database and changes no global context.

The in-memory cache refreshes with 60 seconds of remaining validity and serializes
refresh across downloads. Five focused tests cover reuse, explicit-selection
mismatch, 16 concurrent requests sharing one refresh, identity changes, expired or
malformed responses, and unsupported credential overrides. Processes have a
15-second bound; the existing SDK operations retain their total 20-second bound.
Errors do not include credential responses or private subprocess diagnostics.

The pinned SDK has no callback credential constructor. Each bounded request gets
a fresh auth environment through a private, immediately removed token file, while
all requests share one HTTP manager and the same token cache. Its SDK 60-second
token lifetime exceeds the whole request budget. This replaces the earlier
one-environment assumption without adding background refresh threads, persistent
token files, ambient ADC, or an SDK source fork. All 13 transport/store HTTP tests
now exercise this bridge, including 500 downloads and original-transaction recovery.

## Experiment that changed the implementation

The first live read-only CLI attempt stopped at bucket ownership: the project
probe succeeded, but the bucket probe could not resolve its endpoint. A controlled
[endpoint experiment](mp23-gogol-cli-results-2026-09-29/endpoint-experiment.json)
confirmed that exporting an empty `CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE` causes
gcloud to fail; setting its documented default URL returns the expected project
number. An unset endpoint is now captured as that explicit default, with a
regression assertion. Empty optional credential overrides were not the cause.

The diagnostic's initial resource argument also lacked the required
`scope/key/role` shape. The final reproduction uses a valid, absent resource ID.
Neither failure caused a cloud mutation or prompted a native retry.

## Public command evidence

The [no-op matrix](mp23-gogol-cli-results-2026-09-29/noop.json) and
[active matrix](mp23-gogol-cli-results-2026-09-29/active.json) run the actual built
CLI with its default backend against a loopback Storage server, independently
varying 50/500 journal events and 0/50/500 unrelated reviews, cold and warm.
The only accepted token is synthetic. The server validates generation-bound
media and conditional uploads; native-provider recorders refuse mutations.

| Complete command | Before SDK | SDK default |
| --- | ---: | ---: |
| No-op resume, gcloud processes | 12 | 3 |
| Active resume, all provider processes, cold/warm | 53 / 32 | 9 / 9 |
| Active resume, gcloud processes, cold/warm | 47 / 26 | 3 / 3 |

Those three processes are one credential-helper invocation and two ownership
probes. Active resume retains six Kubernetes observations. Object work is HTTP:
all pages are consumed, every journal entry is fetched at its listed generation,
and the existing committed-prefix/hash-chain validator still runs. Concurrency
is bounded at eight downloads. No per-entry metadata or gcloud process is hidden
in the batch. There is no unrelated-review listing in these active paths.
These are request-count results; loopback elapsed times are not GCS latency.

[Both public stale-claim cases](mp23-gogol-cli-results-2026-09-29/race.json) inject
an identical-byte head replacement at a newer provider generation after the
original authority read. Acquisition refuses before provider recovery, retaining
the original logical head. [Ten migration/refusal cases](mp23-gogol-cli-results-2026-09-29/migration.json)
cover read-only dry runs, local-to-GCS migration with every upload acknowledgement
lost, GCS replay, foreign project/bucket, unsupported credential override,
forbidden reads, GCS-to-local return and local replay. Journal bytes survive the
round trip; source histories retain their migration markers. No real provider
write occurs in these tests.

The [real read-only CLI probe](mp23-gogol-cli-results-2026-09-29/readonly.json)
loads retained `ep150-preview` history in `tan-ng-labs`, then reaches the expected
absent-resource refusal before native observation. It uses an isolated local
state/cache root and the named gcloud configuration. Cold and warm results and
before/after head generation are recorded; the head is unchanged. This proves
real credential, ownership, transport and history integration. It is not a
successful native apply, a timed real no-op resume, or a real 500-event GCS replay.

## Validation and remaining work

[The full suite](mp23-gogol-cli-results-2026-09-29/full-tests.txt) and
[11 legacy CLI recovery cases](mp23-gogol-cli-results-2026-09-29/legacy-cli.json)
pass. The [explicit gcloud fallback matrix](mp23-gogol-cli-results-2026-09-29/fallback.json)
still passes at 12 processes. [Checks](mp23-gogol-cli-results-2026-09-29/checks.json)
record the joint build, formatting/style, command registration audit and Nix
derivation evaluation. [Hashes](mp23-gogol-cli-results-2026-09-29/source-hashes.json)
bind the final source and binaries. A full Nix package build remains unverified.

F06 remains partial until the complete retained GCS replay/second-root budgets
pass. The SDK removes the demonstrated process multiplier; it does not waive
host login, closure, age-key recovery or the other native/cloud transaction gates.
The prior library and protocol proofs remain credited. MP-23 and EP-156 stay open.

## Reproduction

From `cli/nagarectl`, build the CLI/test targets together and run the test suite:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
```

From the repository root, with the synthetic prune fixture created by
`docs/audits/mp23-reproductions/run-operational-cost.py prune-fixture`:

```bash
MP23_SDK=1 python3 scripts/test-inventory-command-cost.py
MP23_SDK=1 python3 scripts/test-inventory-active-command-cost.py <fixture-directory>
MP23_SDK=1 MP23_CLAIM_RACE=acquire python3 scripts/test-inventory-active-command-cost.py <fixture-directory>
python3 scripts/test-inventory-sdk-migration.py
python3 scripts/test-inventory-command-cost.py
MP23_LEGACY_OBSERVATION=1 python3 scripts/test-inventory-operation-driver.py <fixture-directory>
```

`MP23_SDK=1` changes the recorder to HTTP and leaves the transport selector unset,
thereby testing the production default. Without it, the two cost scripts select
the legacy transport explicitly. The optional real read-only command is
`python3 scripts/test-inventory-sdk-readonly.py`; it has per-process bounds and
requires the retained disposable fixture and its existing credentials. It never
runs resume/apply or switches a global context.
