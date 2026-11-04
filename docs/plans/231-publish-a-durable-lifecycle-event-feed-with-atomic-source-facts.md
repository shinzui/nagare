---
id: 231
slug: publish-a-durable-lifecycle-event-feed-with-atomic-source-facts
title: "Publish a durable lifecycle event feed with atomic source facts"
kind: exec-plan
created_at: 2026-10-31T14:21:30Z
intention: "intention_01m695aak2e4ebx7gw1pcvphvr"
master_plan: "docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-31T14:21:30Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T14:34:39Z
      mode: "other"
      note: "Completed initial planning draft and checked source commit, control history, dependencies, recovery and validation interfaces."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T15:01:10Z
      mode: "update"
      note: "Require transport-neutral delivery, isolated destination progress and a second-adapter proof for future Kafka publication; record ADR 33."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:35:44Z
      mode: "update"
      note: "Applied the 2026-11-04 review: convergence journal event instead of a second chain, Nagare.Events modules, /v1/events inspection routes, nagare-events in the nagare-api-server package and image, in-process receipt discovery with a five-minute default, request budget."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:35:44Z
      verdict: "changes-requested"
      note: "Architecture, API and cost review against the code: reuse the journal as the source chain, transport-neutral inspection routes, second executable in the existing service image, in-process receipt discovery, page and polling defaults, Nagare.Events namespace."
---

# Publish a durable lifecycle event feed with atomic source facts


## Purpose / Big Picture


Operators can list a durable, versioned history of lifecycle events through `nagarectl events list --contract 1` and the protected `GET /v1/events` endpoint. The same event keeps its identity across collection retries and worker restarts. This plan builds the storage and commit boundary used by deployment and backup producers; real domain coverage arrives in the dependent children. Its event envelope, identity, source checkpoints and feed position are transport-neutral: a future Kafka publisher and the initial webhook sender consume the same event without producer changes.


## Progress


- [ ] M1: A real inventory executor commits source reachability with final convergence; interrupted and lost-acknowledgment paths neither lose a successful fact nor announce an unsuccessful transaction.
- [ ] M2: Filesystem and conditional object-store materialization expose a deduplicated event prefix with resumable, bounded reads.
- [ ] M3: CLI, protected HTTP reads, generated schemas and client decoding expose the same versioned event contract.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-31: Add a digest-linked source chain committed with the final inventory head update, rather than projecting transaction success from journal detail. The existing journal completion happens before finalization and claim release.

2026-10-31: Keep event materialization and delivery state outside inventory authority, and keep the existing admin service read-only. No existing journal object is rewritten.

2026-10-31: Preserve one immutable transport-neutral envelope and separate feed position from event identity. Destination configuration, HTTP signatures and future Kafka topic/partition receipts are delivery concerns under [ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md).

2026-11-04: Reuse the inventory journal as the source chain. `appendEventAt` and `commitHead` already publish an immutable, digest-linked event and advance its tip, `headSequence`, in one conditional head replacement; `releaseClaimWith` is the only head replacement that appends nothing. One typed convergence event in that replacement supersedes the second chain and head field decided on 2026-10-31. Pages follow `Nagare.Api.Page`: 50 by default, 100 at most. Modules live under `Nagare.Events`, because `Nagare.Inventory.Lifecycle` already names operator lifecycle proposals.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)


## Context and Orientation


A source fact is a durable record of an operation outcome from which a public event can be reconstructed. A conditional write replaces a mutable object only if its previously read generation still matches; this is the store's concurrency primitive. A feed is an ordered sequence of visible event envelopes. A cursor is an opaque continuation token bound to one context, feed epoch and filter set.

`cli/nagarectl/src/Nagare/Inventory/Journal.hs` defines immutable execution events: schema version 1, a sequence, the previous event's digest, transaction, operation, an `OperationState`, a timestamp, free-text detail and an optional physical identity; its decoder rejects unknown fields and versions. `cli/nagarectl/src/Nagare/Inventory/Execute/Journal.hs` commits each event in `appendEventAt`: it checks the executor claim, reads the previous event's digest, publishes `journal/<sequence>` if absent, then `commitHead` replaces the head with `headGeneration + 1` and `headSequence + 1`, rereading on an uncertain write to settle whether the replacement already committed and retrying a bounded number of times while the head is unchanged. The journal is therefore already an immutable, digest-linked chain whose tip lives in the head. `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`, `executeWithJournal`, appends transaction `Completed` before `finalizeCollections` and the final head replacement in `cli/nagarectl/src/Nagare/Inventory/Execute/Claims.hs`, `releaseClaimWith`, which clears the claim, records converged revisions and incarnations and calls `replaceObservedHead` directly, appending no event. A transaction can stop between these steps. `HeadManifest` in `cli/nagarectl/src/Nagare/Inventory/Store/Manifest.hs` accepts only wire version 1 and an exact key set; `Store.hs` and `Store/ObjectOps.hs` implement conditional persistence, `Store/Counters.hs` counts every store operation for tests and traces, and `Store/Migrate.hs` copies every member when a store moves. Inspection of that final boundary is required before changing its signature.

`cli/nagare-contract/src/Nagare/Contract/V1.hs` owns public documents; `cli/nagare-api/src/Nagare/Api/Routes.hs` owns routes. `cli/nagare-api-server/src/Nagare/Api/Server/Serve.hs` supplies bounded reads and response caching: representations are cached by route, arguments and the revision vector they depend on, every success carries a strong ETag and `Nagare-Head-Revision`, and a request runs under a ten-second deadline. Its recorded-state reader intentionally loads no journal/review history. `cli/nagare-api/src/Nagare/Api/Page.hs` defines the Relay `first`/`after`/`last`/`before` arguments, 50 by default and 100 at most. The admin API's store session, `cli/nagarectl/src/Nagare/Inventory/Store/Service.hs`, performs exact GETs only and refuses listings. The CLI reads GCS through the gogol transport by default (`Store/Remote.hs`), one HTTP request per object. Add a separate event reader rather than making ordinary scope/site requests hydrate source history. `docs/api/openapi.json` is the single generated API artifact. CLI parsing and dispatch live under `cli/nagarectl/app/Nagare/Cli/`; tests are assembled by `cli/nagarectl/test/Nagare/Test/Suite.hs`.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires a single inventory writer, committed authority and bounded reads. [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) requires strict typed records and explicit public facades. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires adversarial store/executor tests before native use. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) separates credentials and context state. This child has no hard dependency; its parent is `docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md`.


## Plan of Work


### M1 — Commit source facts with convergence


Create a public facade `cli/nagarectl/src/Nagare/Events/Source.hs` and private implementation modules under `Nagare.Events.Source.`, registering that prefix in the private list of `scripts/check-haskell-architecture.py`. Define opaque source identity and validated source-candidate types; a candidate includes event kind, resource identity, domain-specific whitelisted data and exact evidence references. Distinguish public event candidates from typed internal control facts used later for subscription revisions and replay authorization. EP-234 owns those control payloads; this child owns their durable dispatch/checkpoint mechanism, tested with a small control fixture. Internal controls never become public events and unsupported control versions stop the affected consumer without being silently acknowledged. Do not accept arbitrary serialized review/native values as public payload. Reuse the journal as the source chain instead of adding a second chain and head field. Publish one immutable, content-addressed facts object under the inventory prefix, carrying that transaction's candidate and control facts, transaction/review identity and capture time; then make `releaseClaimWith` append one typed convergence journal event naming the facts digest and review digest, through the same publish-then-commit path as `appendEventAt`, in the head replacement that clears the claim and records convergence. The journal sequence is the source checkpoint. A facts object no committed journal event names is an orphan, not an event source. The journal event schema gains this variant at schema version 2 and the head wire version advances to 2 inside the EP-172 StoreHead transition, so an older CLI refuses the store at head read with its existing message; no existing journal or head bytes change.

Prepare candidates under existing executor validation, and reject inappropriate pending/failed/closed outcomes. Do not introduce network callbacks or a second operation driver. A converged transaction with zero eligible facts appends its convergence event with no facts digest, so consumers advance past it; a stopped transaction appends nothing new here. `commitHead`'s settle-and-retry already covers an unknown final write; reuse it, and the orphan handling of `appendEventAt`, for a facts or journal object left by an interrupted release, and never rerun a proved provider effect to repair notification state. Facts objects are inventory members: `Store/Migrate.hs`, export, transfer and rebuild must carry them, and the recovery model's fault placements must cover the new write before the final head replacement. If M1's executor test shows the final replacement cannot carry a journal event, record why in the Decision Log before building a separate chain.

Add the wire transition and fixtures: version 1 stores remain readable until the reviewed transition, and a version 1 CLI refuses a version 2 head. Do not change old canonical bytes or digests. Capture begins at that transition; do not invent events for historical successful transactions whose final convergence cannot be proved. Record the convergence event and the schema rule in an ADR following `agents/skills/exec-plan/ADR.md`.

The early integration test runs the existing executor with a small converging scope and a typed test candidate, then the materializer. Inject interruption after the facts upload, after the convergence journal object, after the final head replacement and on a lost acknowledgment, and assert with `Store/Counters.hs` that a transaction without facts adds no store write and one with facts adds exactly the facts object and its journal event. Only committed convergence yields one logical event, with a stable source identity. Also commit two internal control revisions before starting their fixture consumer and prove both remain reachable in order. Control consumers keep independent durable checkpoints so event publication cannot accidentally acknowledge a pending replay instruction. Accept this before implementing additional public surface area.

### M2 — Materialize a context-bound event feed


Create `cli/nagarectl/src/Nagare/Events/Store.hs`, `Materialize.hs` and `Read.hs` with memory, filesystem and generation-conditional object-store interpreters. Use a dedicated `lifecycle/v1/` prefix beside inventory, explicitly bound to context identity and project/store binding. The worker writes here without acquiring inventory mutation authority. Define one conditional feed head of constant size naming the visible sequence, digest, the journal-sequence and receipt checkpoints and immutable index roots. Store envelopes in immutable segment objects of bounded size, not one object per event, with the index mapping position to segment and offset, so a page of 50 reads the head, one index node and at most two segments, and a reader resuming after its checkpoint reads only new segments. Publish segments and index nodes before advancing the head. Commit the source checkpoint with the visible batch so a crash cannot acknowledge a fact without making its event visible. Concurrent materializers must settle the winner and retry safely. Readers use exact GETs and never list.

Use IDs derived from canonical versioned source keys plus stable context identity. Include `schemaVersion`, `id`, `type`, `context`, `resource`, `occurredAt`, `observedAt`, `publishedAt`, `evidence` and typed `data`. Publication position is separate from identity and remains available to delivery consumers as feed metadata. The canonical envelope and stable resource reference must be usable unchanged as an HTTP body or a future Kafka record value. Keep URLs, signing headers, broker/topic names, partition/offset receipts and destination retry state outside source facts and the public event envelope. A stable logical resource identity plus context must be available for future routing-key selection; do not use a mutable display name as its only identity. Initial typed payload alternatives cover `app.deployed`, `database.backup.completed` and `database.backup.accepted`; dependent children supply producers. Resource references distinguish scope/logical database identity, namespace and recorded incarnation. No credentials, environment variables, raw receipts, native manifests or signed object URLs enter an envelope.

Define publication order as feed order; late backup discovery need not match occurrence time. Keep an immutable index from source key to event ID and event position so repeated sources do not require a scan of all history. Materialization reads the inventory head once per cycle and then only `journal/` objects after its checkpoint up to `headSequence`, plus the facts objects they name; it never calls `readJournalAtHead` and tolerates orphan facts objects. Enforce batch and byte budgets, bounded request concurrency and cancellation. Keep all v1 history without automatic pruning. Unsupported versions, corrupt committed facts and broken bindings are typed errors, never silently skipped success.

### M3 — Expose history consistently


Add event DTOs in a focused module under `cli/nagare-contract/src/Nagare/Contract/`, keeping existing codecs stable and the package independent of inventory code. Add `events list` CLI parsing, dispatch and contract envelope; it reads published history and never materializes it on demand. Provide exact event-type and resource filters with `Nagare.Api.Page`'s arguments and limits: 50 by default, 100 at most. CLI uses `--first` and `--after`; HTTP uses the existing paginated connection conventions. Add `GET /v1/events` and `GET /v1/events/{eventId}` with the existing gateway grant, problem responses and conditional-read semantics, served through `Serve.hs`'s representation cache keyed by the feed head digest instead of the inventory revision, so an unchanged feed answers from cached bytes or `304`. An uninitialized event feed reports `events_not_enabled`, not an empty successful history.

The event feed has its own revision header, `Nagare-Events-Revision`, and ETag; it is not an atomic snapshot with the inventory head. Cursors bind context, epoch, filter set and pinned publication upper bound, allowing a traversal to finish while new events arrive. Return a typed invalid-cursor problem for mismatches. New traversals can poll after the last seen position using a separately documented continuation mode that captures a fresh upper bound; never strand a tailing client behind a permanently pinned bound. Extend generated OpenAPI, samples, Hurl and compiled-client tests. These routes use only the read-only event store and keep ordinary inventory routes unchanged.


## Concrete Steps


Run from the repository root. Before selecting or changing dependency APIs, use `mori registry search`, `mori registry show --full` and `mori registry docs`, then inspect the located source. Check the authoritative registry and upstream release tags before choosing bounds. This plan selects no new library or pin.

```bash
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Events[.](Source|Store|Read)/' --test-show-details=direct
cabal test nagare-api-server-test --project-dir=cli/nagarectl --test-show-details=direct
just api-hurl
```

Create domain test groups named `Events.Source`, `Events.Store` and `Events.Read` so the focused command actually selects tests. Expected result: zero test failures, a nonempty selected test count, and Hurl validates event paging, unknown IDs, conditional responses and binding failures. Update the project's existing OpenAPI generation/equality test rather than hand-editing generated JSON.

After seeding a local fixture event feed, the following new command must return a contract-1 list containing the expected stable event ID, without initializing or mutating the store:

```bash
cabal run nagarectl --project-dir=cli/nagarectl -- events list --first 1 --contract 1
```

The fixture setup and context environment must be supplied by the test harness and documented with the implementation; this is not an instruction to read or initialize an operator's active context.


## Validation and Acceptance


Demonstrate the executor-to-source-to-feed path, not only codec roundtrips. Source upload without final convergence produces no public event. A successful final write with a lost acknowledgment still produces exactly one logical event after materialization, even after restart and a newer inventory transaction. No-op/recovery paths preserve source reachability. A partial batch, conflicting head write, transient read error, missing immutable object and corrupt chain either recover from authoritative state or yield a visible typed error without advancing past missing events.

Prove memory/filesystem/object-store behavior with the same fault scenarios. Seed 10,000 events; fetching a late 50-item page reads the head, one index node and at most two segments, and materializing one additional source reads the inventory head, the journal suffix and its facts object, not every old envelope, journal event or review. Assert request/object/byte counts with `Store/Counters.hs`, and preserve the admin API's ten-second deadline and existing response budgets. CLI, HTTP and generated client agree on ID, resource and payload. Wrong-context/corrupt cursors fail; exact resource/type filters neither omit matches nor leak unmatched data. No production deployment is needed to accept this child. Test that two independent readers can resume from different positions over the same feed and observe identical event IDs and canonical envelope bytes. Advancing or failing one reader never advances the other or mutates an event. No delivery namespace, HTTP or Kafka dependency is introduced into source/materialization APIs.


## Idempotence and Recovery


Every source/event object is immutable and published conditionally. Resume from committed heads, verify object hashes and settle uncertain writes; leave unreachable objects harmless. A failed notification prefix never changes inventory ownership or reruns a provider effect. Format enablement is explicit and versioned; refuse an incompatible downgrade. Disable materialization to stop publication while retaining committed source facts for later catch-up. Do not delete facts, reset epochs or reseed a live feed to make a test pass.


## Interfaces and Dependencies


EP-231 owns the `Nagare.Events.Source`, `Store`, `Materialize` and `Read` facades; source-key encoding; the convergence journal event, facts object and wire transition; public event DTOs; event-store conditional operations; and feed read routes. EP-232 and EP-233 consume validated candidate constructors. EP-233 also submits independently verified receipt facts with deterministic keys. EP-234 consumes visible feed pages and owns transport-neutral destination/subscription state, independent progress and adapter outcomes. It cannot change the source/feed format to accommodate webhook or Kafka configuration. [ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md) requires that later Kafka publication extend delivery only, preserving domain source producers and the immutable event contract. EP-235 supplies worker credentials and invokes these facades. Consumers must not inspect free-text journal detail or bypass typed validation. This child is the hard prerequisite for `docs/plans/232-record-successful-application-deployments-as-lifecycle-events.md`, `docs/plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md` and `docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md`.
