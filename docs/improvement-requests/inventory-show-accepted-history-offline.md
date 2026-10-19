---
type: Improvement Request
title: Add a read-only inventory show command that prints accepted history without contacting providers
description: Let an operator list the accepted scopes of the selected inventory store, local or GCS, and print one scope's accepted declaration, with no provider contact, no lock and no store write, instead of exporting the whole store or reading digest-named records by hand.
timestamp: "2026-10-19T20:44:04Z"
generated:
  by: process:claude-code
  at: "2026-10-19T20:44:04Z"
requestId: IR-34
status: proposed
origin: mori://shinzui/nagare
acceptanceCriteria:
  - id: AC-1
    statement: nagarectl inventory show, with no argument, lists every accepted scope in the selected store with its kind, name, revision generation and member count, reading only the store.
    verification: Run it on a local context with no kubeconfig and no platform workspace under the fake-command harness, and assert the listing and that no provider command was invoked.
  - id: AC-2
    statement: nagarectl inventory show KIND:NAME prints that scope's accepted declaration, and --json prints it in the store's wire form, so the output decodes to the ScopeDeclaration the store holds.
    verification: A round-trip test against the recorded store fixture under cli/nagarectl/test/fixtures/transition-0.4.0/store decodes the --json output and compares it with the scope record read directly from the store.
  - id: AC-3
    statement: The command prints no private native bytes, takes no store lock, writes nothing, and an unknown scope fails with a non-zero exit.
    verification: Compare inventory store status before and after a successful run and an unknown-scope run, and assert the head digest, generation, active transaction and executor claim are unchanged; assert that Secret-sensitivity members show only their digests.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T20:44:04Z"
    document_timestamp: "2026-10-19T20:44:04Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: >-
      Author review against the inventory CLI parser and dispatch, the shared inventory
      history documentation and the transition-0.4.0 store fixture; no independent
      verification attestation is claimed.
---

# Add a read-only `nagarectl inventory show`

**Authored by:** a `claude-code` session reviewing
[EP-204](../plans/204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md)
in `shinzui/nagare`.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.


## Why

Accepted inventory history is the authority for what a context holds
([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)).
Every command that reads it today does one of three things:

- `inventory status` and `inventory explain RESOURCE_ID` observe providers as well as the
  store, so they need the kubeconfig, the context guard and, for some executors, a platform
  workspace (`cli/nagarectl/app/Nagare/Cli/Dispatch.hs` dispatches `explain` to the status
  command with one resource selected).
- `inventory export --out DIR` copies the complete private store under lock.
- `db app-database list` and `inventory publications` show one domain's accepted members.

There is no way to ask the store alone which scopes are accepted and what one scope declares.
An operator who needs that during an upgrade or an incident reads digest-named JSON by hand:
`scopes/<sha256>.json` under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/inventory`
for a local store, or the same objects in the context's state bucket for a GCS store, after
locating the scope's current revision through the head manifest
(`cli/nagarectl/test/fixtures/transition-0.4.0/README.md` describes the layout).

The gap surfaced on 2026-10-19 while reviewing EP-204: the plan described capturing the
accepted `appdb-*` records for a release-transition fixture with `nagarectl inventory show`, a
command that does not exist. The plan now uses `inventory export` for that one-off, which is
enough for a fixture but not for an operator reading history under pressure.


## Requested change

- Add `nagarectl inventory show [KIND:NAME] [--json]`, read-only.
  - With no argument, list the accepted scopes: kind, name, revision generation and member
    count.
  - With a scope, print its accepted declaration: each member's identity, address, executor,
    spec, lifecycle, data policy, sensitivity and dependencies, the scope's declared
    operations, and its revision. `--json` emits the store's wire form.
  - Read the selected store, local or GCS, through the existing snapshot reader. Take no lock,
    write nothing, contact no provider, and require no kubeconfig or platform workspace.
  - Never print private native bytes. Secret-sensitivity members show only their digests.
- Document it beside `inventory explain` in `docs/user/contexts.md` ("Shared inventory
  history") and `docs/user/reference.md`, and add it to the command audit.


## Not requested

- Observation, which is `inventory explain`; a diff between two revisions; printing native
  bytes; editing history; an app-database projection (`db app-database list` already walks the
  `appdb-*` scopes and can grow `--json` on its own).
- An ExecPlan. This is one commit: a parser entry, a command over the existing snapshot
  reader, a round-trip test against the recorded store fixture, the docs lines and the audit
  line. It is built when an operator first needs it, not before.


## Prior evidence

- EP-204, Validation, "Transition": first named `nagarectl inventory show`; corrected to
  `inventory export` in commit 38fc25e5 on 2026-10-19.
- The inventory subcommands in `cli/nagarectl/app/Nagare/Cli/Parser/Inventory.hs`: compile,
  plan, adopt, rebuild, migrate, retire, gc, collect, apply, resume, recover, close, export,
  restore, status, publications, explain and store, none of which prints accepted history
  without a provider or a lock.
