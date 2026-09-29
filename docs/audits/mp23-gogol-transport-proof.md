# MP-23 pinned Gogol transport proof

The bounded experiment supports replacing repeated `gcloud` object reads with a
command-local Gogol client. It establishes SDK compatibility and a real read-path
speedup; the production ObjectOps backend is not switched by this checkpoint.

## Source and compatibility

The operator requested a current upstream source pin instead of waiting for a
release. Upstream's default branch is `main`, at
`881cd14c9844131b4a8d96ca1bbb2bd9a2409ed9`; `master` remains at the old 0.5.0
release, `4750be61b12982e07cc4910185874680524640e6`. The standalone
[prototype project](mp23-reproductions/gogol-transport/cabal.project) pins the
three packages from `mori://brendanhay/gogol/repos/gogol` to that exact `main`
commit. Registry and upstream tags were checked before selecting it. Hackage's
published versions were gogol/core 1.0.0.0 and storage 1.0.0; the source pin retains
those package versions. The consulted corpus's request, auth and core sources
match the pinned checkout.

The source pin still has stale dependency bounds. The probe narrowly relaxes
only Gogol's aeson, crypton, crypton-x509 and crypton-x509-store upper bounds, plus
gogol-core's aeson upper bound. [The compiled result](mp23-gogol-transport-results-2026-09-29/build.json)
uses GHC 9.12.4, aeson 2.3.2.0, crypton 1.1.5, crypton-x509 1.9.1 and
crypton-x509-store 1.9.0, matching Nagare's existing versions. No upstream source
patch or production dependency downgrade was needed. A separate joint dependency
solve with nagarectl, nagare-dsl, their tests and these SDK packages also passes;
that dry run is not a joint build or test result.

## Protocol checks

Eight offline checks compile and inspect the SDK's generated requests: encoded
object paths including reserved/Unicode characters, generation-bound media,
conditional create (`ifGenerationMatch=0`), exact-generation replacement,
prefix/page-token preservation, and explicit project attribution.

Gogol's `Capture Text` does not URL-encode the object path component. The probe
encodes that component exactly once. Query parameters and upload metadata retain
the unencoded logical object name. `userProject` supplies quota attribution;
it does not replace Nagare's context/project and bucket-ownership guards.

A read sends a metadata request, takes its provider generation, then downloads
that exact generation using the same manager. This uses the documented
[Cloud Storage generation selector](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/get).
It observes the version selected by the metadata read; a later conditional head
write must still use that observed generation. An intervening replacement must
never be silently adopted. Conditional-write request shape alone is not proof
of lost-acknowledgement or race handling.

## Read-only measured result

[The raw report](mp23-gogol-transport-results-2026-09-29/readonly.json) contains
three comparison rounds against the exact disposable
`gs://tan-ng-labs-ep150-pmkjjpp-state/inventory/head.json`, with explicit project
`tan-ng-labs`. No compile or test workload ran during this timing matrix.

| Measurement | Range | Median |
| --- | --- | --- |
| Existing describe/copy/describe protocol, one object read | 5.58–7.05 s | 5.72 s |
| Gogol first read with a new manager, excluding authentication | 0.26–0.33 s | 0.318 s |
| Gogol subsequent reads on the same manager, excluding authentication | 0.19–0.26 s | 0.197 s |
| Once-per-process gcloud token acquisition | 0.64–0.77 s | 0.682 s |

Including authentication, the entire SDK process performed **three** reads and
one deliberately rejected generation check in **1.43–1.76 seconds** per round.
Every one of the nine SDK reads matched provider generation `1790656456769847`,
1773 bytes, and SHA-256
`9eda5dc0872e74f8261e62af61efa758ce07ed0c161cc9e2e9d8a112b0a7bde7`.
All three mismatched-generation requests returned HTTP 412. Each process received
seven HTTP responses: six for the three metadata/media pairs and one refusal.

The first live attempt correctly completed those reads/refusal but failed the
probe's counter assertion: http-client invoked its request-modification hook
twice per request. The final probe counts actual responses and separately records
14 guard invocations. The corrected three-round matrix passes. The initial SDK
source download also failed once to connect; its retry succeeded. Neither issue
required a provider mutation or any weakening of the read checks.

The read-only executable restricts authenticated traffic to GET of that exact
object on `storage.googleapis.com:443`; redirects and automatic transport retries
are disabled. A token is passed privately through stdin, with no on-disk token,
ADC fallback or global context change. A 25-second process bound expires before
Gogol's token-file refresh interval. This proves only short-lived authentication,
not the long-running refresh contract. Object contents and credentials are absent
from committed reports. See the [reproduction instructions](mp23-reproductions/gogol-transport/README.md).

This is a small, real protocol comparison, not a statistical estimate of pure CLI
startup time: the old path also performs its own SDK setup and extra storage work.
It supports transport reuse as the next repair. It does not establish journal
replay cost, warm inventory-command latency, provider-write correctness, host
readiness, or a completed MP-23/EP-156 gate.

## Next implementation boundary

Implement Gogol behind the existing `ObjectOps` outcomes, retaining one manager
per command and the existing project, bucket, prefix and migration checks. Before
selecting it as the default, require offline provider-boundary tests for absent
versus forbidden/unknown, generation races, conditional create/CAS, malformed
responses, partial transfer, landed-write/lost-ack readback and pagination.
Preserve exact uncached publication authority and the claim ABA regression.

Journal loading must enumerate all pages and use bounded concurrent generation-
bound downloads, retaining complete-prefix/hash-chain validation; it must not
replace one bulk subprocess with 500 serial network reads. Measure the 50/500-event
public CLI cases before claiming improvement for a whole command. Establish
context-bound credential refresh without switching identities during long native
operations. Carry the same source pin and scoped bounds into Cabal and Nix at
production integration, then run the existing store and public-command suites.
These are implementation checks for replacing an existing transport, not new
feature scope. The host/native prerequisites and real transaction gates remain.
