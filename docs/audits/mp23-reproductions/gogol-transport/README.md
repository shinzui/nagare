# Pinned Gogol transport experiment

This standalone package tests the SDK before changing Nagare's production backend.
It pins all three Gogol packages to upstream `main` commit
`881cd14c9844131b4a8d96ca1bbb2bd9a2409ed9`. Upstream `master` still points to
`4750be61b12982e07cc4910185874680524640e6`, the historical 0.5.0 release.
Source ownership: `mori://brendanhay/gogol/repos/gogol`.

Run from this directory:

```bash
cabal build
cabal run gogol-transport-probe -- wire
python3 run.py "$(cabal list-bin exe:gogol-transport-probe)"
```

The last command requires the operator's existing gcloud access to the retained
disposable `tan-ng-labs-ep150-pmkjjpp-state` bucket. It performs three repetitions
of the production describe/copy/describe protocol and compares each with three
SDK reads of the same exact `inventory/head.json`. Each SDK read retrieves
metadata and downloads that exact generation. Every result must have identical
generation, length, and SHA-256. One wrong-generation metadata GET must return
412 per repetition. No object body is printed or retained in the report.

The Python runner sanitizes inherited cloud/context variables and passes the
explicit project. One gcloud token per repetition is sent privately through the
child's stdin. Gogol's token-file constructor reads `/dev/stdin`; no credential is
written to disk. The SDK's 25-second whole-process limit is shorter than its
60-second token-file reread interval. This is deliberately a short-lived probe,
**not production token refresh**. Authenticated requests are confined by the HTTP
manager to GET of that exact object on `storage.googleapis.com:443`, with a
five-second response timeout, no redirects and no automatic transport retries.
The runner imposes a second 30-second process limit. Baseline gcloud commands
have individual 20-second limits. No global context is changed.

`wire` is offline. It compiles and checks generated request shapes for encoded
object paths, generation-bound media, conditional create/replacement, prefix/page
token and project attribution. These checks do not prove provider write behavior,
absence classification, ambiguous acknowledgements, or pagination traversal.

The scoped `allow-newer` entries are compatibility experiments against Nagare's
existing aeson, crypton and certificate-library versions; they are not blanket
relaxations. A source pin alone does not fix upstream's stale dependency bounds.
Production adoption also needs the matching Nix source pin, full store conformance,
long-running authentication/refresh, bounded journal downloads, and public CLI
regressions. Keep the existing backend until those checks pass.
