---
title: "Read-only admin API and versioned CLI documents"
type: Capability
description: "Serve a context's recorded inventory state through a read-only HTTP API behind login, and print the CLI's machine outputs as a versioned document contract."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
capabilityId: CAP-25
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.6.4
packages:
  - nagare-api
  - nagare-api-server
  - nagare-contract
  - nagare-access
  - nagarectl
interface:
  - "https://admin.<base domain>/v1/"
  - "docs/api/openapi.json"
  - "Nagare.Contract.V1"
  - "nagarectl --contract 1"
  - "nagarectl site list"
  - "NAGARE_ADMIN_API_ENABLED"
requires:
  - CAP-18
  - CAP-21
evidence:
  - kind: module
    resource: cli/nagare-contract/src/Nagare/Contract/V1.hs
    proves: Version 1 of the document contract defines the inventory, publication, transaction outcome, review, image publication and deploy-preview documents.
  - kind: test
    resource: cli/nagare-api-server/test/Nagare/Api/Server/Test/Document.hs
    proves: The checked-in OpenAPI document equals the generated one, lists exactly the served operations, and declares every error as a problem document.
  - kind: test
    resource: cli/nagare-api-server/test/Nagare/Api/Server/Test/Serve.hs
    proves: The server reads the head and scope objects only, pages Relay connections without skips or repeats, and answers conditional requests with strong validators.
  - kind: test
    resource: cli/nagare-access/test/AdminApiGatewaySpec.hs
    proves: The gateway answers API paths, bearer requests and JSON-preferring clients with problem documents instead of a login redirect.
  - kind: test
    resource: cli/nagarectl/test/InventoryAdminApiSpec.hs
    proves: Local and cloud scopes bind the server on the mounted store or a private reader Secret, route the admin host as an API, and refuse unusable inputs before binding.
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/Contract.hs
    proves: Problem documents carry exactly the RFC 9457 members, every catalog code has one status and title, and every transaction result has its outcome document and exit code.
  - kind: example
    resource: cli/nagare-api-server/hurl/inventory.hurl
    proves: Executable HTTP requests exercise the served inventory routes.
  - kind: guide
    resource: docs/api/README.md
    proves: The documents, exit codes, problem codes, admin API and versioning rules are documented.
  - kind: guide
    resource: docs/runbooks/admin-api-reader.md
    proves: Enabling the dedicated read-only reader account for a cloud context is documented.
---

# Read-only admin API and versioned CLI documents

With `NAGARE_ADMIN_API_ENABLED=1`, a context serves `https://admin.<base domain>/v1/…`: the
inventory head, scopes, recorded sites, image publications and recorded grants. Every list is a
Relay connection, every success carries a strong `ETag`, and every error is an RFC 9457 problem.
The OpenAPI 3.1 document is checked in at `docs/api/openapi.json` and served at
`/v1/openapi.json`. The server reads only the inventory's head, format and scope objects and never
writes.

The hostname is protected by the shared enforcer from
[forward-auth route enforcement](forward-auth-route-enforcement.md) (CAP-18). A person's session
cookie or a Shomei service account's bearer token both work, and either needs an ordinary
`nagarectl access grant` on the hostname. The gateway answers API clients with problem documents,
not a login redirect. A cloud context reads its store through a dedicated read-only reader account
whose key lives in the context's sops secrets.

The CLI prints the same contract: `--contract 1` emits the versioned document for inventory status,
publications, transaction outcomes, saved reviews, image publications, deploy previews and
`site list`, with refusals as problem documents carrying stable codes and exit codes. The data
comes from the [typed resource inventory](typed-resource-inventories.md) (CAP-21).

## Limits

- The API is read-only. Changes still go through saved reviews and `inventory apply`.
- It reports recorded state, not live provider observations; `inventory status` remains the live
  check.
- It is opt-in per context, and a cloud context also needs the reader account enabled through a
  reviewed cloud stage.
- Only version 1 of the contract exists; fields outside the documented documents are not promised.
