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
| `transaction-outcome` | `TransactionOutcome` | operation | `nagarectl inventory apply|resume … --contract 1` |
| `saved-review` | `SavedReview` | operation | `nagarectl app deploy --save-plan DIR --contract 1` |
| `image-publication-result` | `ImagePublicationResult` | operation | `nagarectl app image-plan … --contract 1` |
| `site-publish-result` | `SitePublishResult` | operation | `nagarectl site publish … --contract 1` |
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
`Cache-Control: private, no-cache`; send it back in `If-None-Match` for a bodyless 304.

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
