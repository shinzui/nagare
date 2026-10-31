# Nagare's public document contract

This directory is Nagare's machine-readable contract, version 1. `nagarectl` prints these documents
under `--contract 1`, and the read-only admin API serves the read documents' items. Clients such as
Kotei copy this directory at their pinned Nagare revision and validate against it.

- `openapi.json` is generated from the admin API's route types (`cli/nagare-api`) and the contract
  types (`cli/nagare-contract`). Never edit it by hand. Its `components.schemas` are JSON Schema 2020-12 (OpenAPI 3.1), so any standard validator
  or `openapi-hs`'s `validateJSON` can check a document against `#/components/schemas/<Name>`.
- `samples/` holds one golden document per shape, produced by the test suite from the real types
  and, for read documents, the real projection code.

Regenerate and review after changing a contract type, from the repository root:

```bash
cabal run --project-dir=cli/nagarectl nagare-api-openapi
git diff docs/api/openapi.json
```

`nagare-api-server-test` fails while the checked-in document differs from the generated one, and
`nagarectl-test` while a sample differs from what the code produces. Accept changed samples with tasty-golden's `--accept`
(`cabal test nagarectl-test --test-options='-p /Contract/ --accept'` from `cli/nagarectl`), then
review `git diff docs/api/samples`.

## Documents

| Document (`document`) | Schema | Class | Produced by |
|---|---|---|---|
| `inventory-status` | `InventoryStatusReport` | read | `nagarectl inventory status --contract 1 [--scope KIND:NAME]` |
| `publication-list` | `PublicationList` | read | `nagarectl inventory publications --contract 1` |
| `site-list` | `SiteList` | read | `nagarectl site list --contract 1` |
| (discovery) | `VersionInfo` | read | `nagarectl version --json` |
| `platform-versions` | `PlatformVersions` | read | `nagarectl platform versions --contract 1` and `GET /v1/platform/versions` |
| `transaction-outcome` | `TransactionOutcome` | operation | `nagarectl inventory apply|resume … --contract 1` |
| `saved-review` | `SavedReview` | operation | `nagarectl app deploy --save-plan DIR --contract 1` |
| `image-publication-result` | `ImagePublicationResult` | operation | `nagarectl app image-plan … --contract 1` |
| `site-publish-result` | `SitePublishResult` | operation | `nagarectl site publish … --contract 1` |
| `nix-cache-endpoint` | `NixCacheEndpoint` | operation | `nagarectl nix-cache forward --contract 1` |
| `nix-cache-push-result` | `NixCachePushResult` | operation | `nagarectl nix-cache push … --contract 1` |
| `deploy-preview` | `DeployPreview` | operation | `nagarectl app deploy --dry-run --contract 1` |

The item types `ScopeState`, `Finding` and `Publication` are shared by the CLI documents and the
admin API's paginated responses, so an item has one shape everywhere.

**Read documents** describe recorded state. They keep what the inventory store recorded (accepted
and converged scope revisions) apart from what a provider observed (`findings`), and say when an
observation is partial (`observationComplete: false`). Recorded convergence means a revision's
execution completed; it is not a live health check. Nothing in a read document needs operator
credentials to be meaningful. **Operation documents** describe a change; only the CLI emits them,
and the read-only API never will.

Every document except the discovery document carries `contractVersion: 1` and a constant
`document` member. `VersionInfo` lists the versions a build emits in `contracts` and describes the
binary, not what a context has installed.

## Platform versions

`platform-versions` reports what one context has installed and runs: the Nagare release its
cluster stamp records beside the build serving the admin API, the host's NixOS identity beside its
running kernel and k3s, every accepted platform component's declared version, chart and images
beside the image digests its pods run, and every managed database server's declared engine
version beside the version the server reports. A database server is any accepted StatefulSet
labelled with its engine, whether the platform, a shared standalone server or an application owns
it; it is listed once, under `databases`, never as a component, and never its tenant databases.
Instances and workloads are the pods the workload controls.

Every value is a fact: `value` (a string or `null`), `sourceKind` (`recorded` for written-down
state such as the stamp, an accepted declaration or the host identity ConfigMap; `observed` for
what a running provider answered), `source`, `observedAt` and `reason`. `observedAt` is when that
source was read or the read was attempted, never the request time. `reason` is set exactly when
`value` is `null`. Identity keys (`node`, `uid`, `scope`, `pod`, `podUid`) carry no envelope.
`workloads` and `instances` list every running pod, so a rollout shows each version it runs; a
declared engine version is the declared literal, such as the moving tag `18`.

The document is assembled from a snapshot that `nagarectl platform versions refresh` collects
(within 60 seconds) and that a converged `inventory apply` or `platform bootstrap apply` touching a
`platform:` or `standalone:` scope refreshes for up to 20 seconds. Observations are as of
`snapshot.completedAt`; there is no schedule and no freshness promise, so refresh before relying on
them. `snapshot.inventoryRevision` names the accepted head the declarations were read from. The
API never runs a provider. `nagare.comparison.state` is `different` when a known installed field
differs from the serving build, `unknown` when versions are equal but revision evidence is missing
on either side, and `match` otherwise. Through the CLI `servingBuild` is `null`, because the CLI is
not the serving binary. A host activated before its identity ConfigMap existed reports
`not_recorded` until its next `just host-switch`; an older stamp reports `payloadId` as
`not_recorded`.

| `reason` | Meaning |
|---|---|
| `not_recorded` | The source exists but never recorded this value (a legacy stamp's payload ID, a host without its identity ConfigMap) |
| `not_applicable` | The value does not apply (NixOS facts of a non-NixOS node, a chart version of a plain workload) |
| `unreadable` | The source could not be read or parsed |
| `denied` | The source refused the read |
| `probe_failed` | The engine's version statement failed or answered nothing recognizable, or the pod was not running |
| `probe_unsupported` | The engine or the accepted member's shape is not one the collector reads; it is reported, never dropped |
| `identity_changed` | The pod was replaced while it was probed |
| `collection_deadline` | The read could not start or finish within the collection budget |
| `inventory_changed` | The accepted head changed during collection twice; the sections are empty |
| `snapshot_missing` | No snapshot has been published |
| `snapshot_invalid` | The snapshot is malformed or of an unknown snapshot schema |
| `snapshot_oversized` | The snapshot is over 1 MiB |
| `snapshot_foreign` | The snapshot is bound to another context or project |
| `snapshot_unavailable` | The store read or its ownership check failed, or ran out of the request deadline |

A `snapshot_*` reason sets `snapshot.available: false`, empties the sections and fills
`hostsReason`, `componentsReason` and `databasesReason`; the response is still a 200 with the
serving build. A section reason without an unavailable snapshot means only that section could not
be read; an available empty list means there is nothing to report. A new reason is an additive
catalog entry, as a problem code is.

## Exit codes

Under `--contract 1`, stdout holds exactly one document and human progress lines go to stderr.

| Exit | Meaning |
|---|---|
| 0 | the document describes success: a read document, a saved review, a preview, or `converged` |
| 2 | `refused`: nothing was touched; the problem says why |
| 3 | `paused` at review barriers |
| 4 | `stopped` with a classified failure |
| 5 | `ambiguous`: the outcome cannot be proved; `detail` says what to do |
| 6 | `closed` |
| 7 | `interrupted` after execution began; read `inventory status` or run `inventory resume` |

A read command refuses with a bare `ProblemDetails` document. An operation command refuses with a
`transaction-outcome` whose `outcome` is `refused` and whose `problem` says why, so a client tells
the two apart by `document`. Without `--contract`, every command keeps its human output and exits
0 or 1.

## Problems

Every refusal is an RFC 9457 problem document (`ProblemDetails`): a read command prints it as its
document, a `refused` transaction outcome carries it as `problem`, and the admin API answers it as
`application/problem+json`. `type` is always `about:blank`, so `title` is the HTTP status phrase;
branch on `code`, never on `title` or `detail`. `status` is the HTTP status the API answers with;
the CLI keeps its exit codes and ignores it. `retryable` is true only when the unchanged request
can succeed later. The access gateway adds the optional extension members `error` and `login`.

| `code` | `status` | `retryable` |
|---|---|---|
| `unknown_scope` | 404 | false |
| `unsupported_contract_version` | 400 | false |
| `wrong_context` | 409 | false |
| `review_changed` | 409 | false |
| `admission_refused` | 409 | false |
| `store_unavailable` | 503 | true |
| `reauthentication_required` | 503 | false |
| `workspace_not_prepared` | 409 | false |
| `unclassified` | 500 | false |
| `bad_request` | 400 | false |
| `invalid_page` | 400 | false |
| `invalid_cursor` | 400 | false |
| `not_found` | 404 | false |
| `method_not_allowed` | 405 | false |
| `not_acceptable` | 406 | false |
| `internal_error` | 500 | false |
| `store_timeout` | 503 | true |
| `store_invalid` | 503 | false |
| `store_credentials_unavailable` | 503 | true |
| `server_busy` | 503 | true |
| `unauthenticated` | 401 | false |
| `forbidden` | 403 | false |
| `authorization_unavailable` | 503 | true |
| `authentication_unavailable` | 503 | true |
| `upstream_unavailable` | 502 | true |
| `upstream_timeout` | 504 | true |

`unclassified` carries any CLI refusal not yet given its own code, with the CLI's existing message
in `detail`. The admin API's own codes follow it: `server_busy` carries `Retry-After`, and every
error response is `Cache-Control: no-store`. The access gateway's codes come last: it answers them
on the admin host's `/v1` paths before the server is reached, a 401 with `WWW-Authenticate: Bearer`
and, for compatibility, the `error` and `login` members. A new code is an additive catalog entry.

## The admin API

`https://admin.<base domain>/v1/…` serves the read documents' items to a signed-in person (session
cookie) or a Shomei service account (bearer token) with a grant on that hostname. Lists are Relay
connections (`first`/`after`, `last`/`before`; 50 by default, at most 100; an invalid page is a
problem, not a clamp). A cursor is bound to its context, list and filters; across head changes the
next page is the items after the cursor in the new head, so compare `Nagare-Head-Revision` and
restart for a consistent walk. Every 200 carries a strong `ETag` of its exact bytes and
`Cache-Control: private, no-cache`; send it back in `If-None-Match` for a bodyless 304. Its build
routes, `/v1/platform/version` (the serving binary) and `/v1/platform/versions` (installed beside
serving, see [Platform versions](#platform-versions)), carry no `Nagare-Head-Revision`.

## Versioning

- An additive change keeps major version 1: a new optional field, a new document, a new problem
  code.
- A new enum value (`outcome`, `failureClass`, `category`, `health`) is additive only when version
  1 defines a decoding rule for unknown values and both sides prove it. Version 1 defines none, so
  a new enum value is version 2.
- Any other change to an existing field or document is version 2. `nagarectl` then keeps emitting
  version 1 behind `--contract 1` for at least one release. This rule is not implemented until a
  version 2 exists.
- Every new field or enum value gets a golden sample in the same change.
