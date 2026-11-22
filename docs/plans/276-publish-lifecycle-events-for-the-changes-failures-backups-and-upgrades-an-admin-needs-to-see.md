---
id: 276
slug: publish-lifecycle-events-for-the-changes-failures-backups-and-upgrades-an-admin-needs-to-see
title: "Publish lifecycle events for the changes, failures, backups and upgrades an admin needs to see"
kind: exec-plan
created_at: 2026-11-22T04:06:01Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-22T04:06:01Z
---

# Publish lifecycle events for the changes, failures, backups and upgrades an admin needs to see

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A Nagare context today publishes three lifecycle events: `app.deployed`,
`database.backup.completed` and `database.backup.accepted`. An admin watching the feed
learns that something was deployed or backed up. They do not learn that a change failed and
is waiting for someone, that an app was stopped or deleted, that backups stopped arriving,
that a restore ran, or that the platform moved to a new release. The labs admin tool will
read the feed from the admin API (`GET /v1/events`) or from a webhook subscription, so it can
only show what Nagare publishes.

After this plan, the feed has ten more event types:
- `change.applied`: a reviewed inventory change converged. It says who applied it, where it
  came from, and which scopes it created, updated or retired.
- `change.failed`: an operation of a change failed or its outcome is unknown, so the change
  is stopped and waiting for a resume or a close.
- `change.closed`: an operator closed or abandoned a stopped change.
- `app.deleted`, `app.stopped` and `app.restarted`: an application, standalone service or
  site was retired, taken offline, or rolled to a fresh revision.
- `database.restored`: a reviewed restore of a backup into a scratch database converged.
- `database.backup.failed`: a scheduled backup run failed verification.
- `database.backup.freshness.changed`: a backup schedule's freshness grade moved between
  `fresh`, `deteriorating` and `breached`, against its signed recovery-point objective.
- `platform.upgraded`: the context finished moving to a new Nagare release.

`change.applied` is the catch-all. Every reviewed change an admin makes, including env,
secret, access, storage, schedule and CDN changes that have no type of their own, shows up
as one event. The named types exist so a webhook can subscribe to exactly the scenarios that
need a reaction.

To see it working, on a local context with the lifecycle worker enabled, deploy an app, make
a deploy fail and close it, stop, restart and delete the app, restore a backup, and run the
upgrade rehearsal. Then run `nagarectl events list --type change.failed` (or
`curl …/v1/events?type=…`) and find one event for each step, with the actor and the scope
it touched.


## Progress

- [ ] M1: `change.applied` is published for every converged reviewed change, with actor,
  source and per-scope classification. It can be read with `nagarectl events list`,
  `GET /v1/events` and a webhook subscription. OpenAPI and samples are regenerated.
- [ ] M2: `change.failed` and `change.closed` are published from the committed journal. No
  journal object the head does not commit becomes an event.
- [ ] M3: `app.deleted`, `app.stopped`, `app.restarted` and `database.restored` are
  published by release-time producers. A verification-only rerun publishes none of them.
- [ ] M4: `database.backup.failed` and `database.backup.freshness.changed` are published by
  the backup collector. A worker restart publishes neither twice.
- [ ] M5: `platform.upgraded` is published once per committed release transition, and not
  while the transition marker is still in the head.
- [ ] M6: Native confirmation on a disposable local context. Each scenario in Validation and
  Acceptance produces its event, readable through the admin API. The EP-172 rehearsal
  (`just release-rehearse`) reads its seeded data back unchanged and shows
  `platform.upgraded`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Add one generic `change.applied`, `change.failed` and `change.closed` family,
  plus a small set of named types for the most common scenarios. Do not add a named type for
  every command.
  Rationale: Every admin action in Nagare is a reviewed inventory transaction, so a generic
  event covers the long tail (env, secrets, access, storage, CDN, schedules) with one
  producer. Named types are kept for the scenarios a receiver must react to on their own.
  Failures get one generic type, not `app.deploy.failed`: the event's `resource.scope` already
  says which app failed.
  Date: 2026-11-21
- Decision: The three existing payloads stay byte-for-byte unchanged. Actor and source go
  only on `change.applied`, `change.failed` and `change.closed`. A consumer joins them to
  `app.deployed` through the shared `transaction` field.
  Rationale: The payload codecs reject unknown fields (`strictOptions` in
  `cli/nagare-core/src/Nagare/Events/Source/Facts.hs`). A new field would make an older worker
  refuse facts and envelopes it reads today, and it would change published bytes.
  Date: 2026-11-21
- Decision: `change.applied` is produced at release by a built-in producer, not derived by
  the worker. As a result, every converged transaction now writes one facts object and one
  convergence journal event. Before, only transactions that had facts wrote them.
  Rationale: ADR 39 commits facts in the same head replacement that records convergence. That
  is the only way an event is announced exactly when a change converged. A transaction with no
  facts leaves no convergence event the worker could find. The cost is one extra object and
  one journal event per transaction, with no extra head write. A transaction that already has
  facts (a deploy, a backup ingestion) adds no journal event, because `change.applied` joins
  its existing facts object. Only transactions with no facts today (env, secret, access,
  storage, stop or restart) gain one event, of about 400 bytes. The local store `kotei-plan84`
  had 497 events over 10 transactions, at least 4 per transaction. Since EP-217 the CLI
  caches committed journal events and fetches only new ones, so each extra event is
  downloaded once. The operator accepted this cost over a worker-derived `change.applied`,
  which could announce a change that did not converge (2026-11-21).
  Date: 2026-11-21
- Decision: `change.failed` and `change.closed` are derived by the worker from committed
  journal events (`Failed`, `Ambiguous`, and the close and abandon `OperatorResolved` markers),
  together with the review the transaction ID names. The executor's failure path is not
  changed.
  Rationale: Each failure event is already committed by the same conditional head
  replacement that every `appendEvent` performs. The worker already reads the journal suffix
  and is allowed to read `reviews/`. Changing the executor's failure path would put new code
  on the path that protects data when it is most at risk.
  Date: 2026-11-21
- Decision: `platform.upgraded` is observed by the worker. The worker publishes it when the
  release it runs differs from the release recorded in its own state, and the inventory head
  is idle with no transition marker. The transition commit is not changed.
  Rationale: The commit (`cli/nagarectl/src/Nagare/Platform/Finalize.hs`) only replaces the
  head and writes the local pin file. It appends no journal event, and adding one would
  change the journal and head wire inside the transition protocol. The marker is cleared only
  at the commit's last step, so "new release running and no marker" means the transition
  committed.
  Date: 2026-11-21
- Decision: New types are forward-only. A worker from a release without them refuses facts
  or envelopes that carry them, and stops at that position without skipping anything. It
  resumes once the context runs the new worker.
  Rationale: This matches release transitions, which only move forward. Existing webhook
  subscriptions name exact types, so no existing receiver is sent a new type unless an
  operator adds it.
  Date: 2026-11-21
- Decision: Runtime health (crashing pods, certificate expiry, disk pressure, node down)
  and preview deployments stay out of scope.
  Rationale: Lifecycle events record what Nagare did and proved, as MasterPlan 31 defined
  them. Continuous health belongs to the observability stack's alerts
  (`docs/user/observability.md`). Previews are high-volume and were excluded by MasterPlan 31.
  The admin tool can add them later as their own types.
  Date: 2026-11-21


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**What a lifecycle event is.** An event is an immutable JSON document with a stable ID
(`ev-` followed by 32 hexadecimal digits), a `type`, the `resource` it is about (a scope such
as `application:notes`, an optional member, a namespace), times, digest-bound `evidence`, and a
type-specific `data` payload. The public shape is `LifecycleEvent` in
`cli/nagare-contract/src/Nagare/Contract/Events.hs`. The internal shape is `Envelope` in
`cli/nagare-core/src/Nagare/Events/Envelope.hs`. The ID is derived from the context and a
*source key*, a stable string that names one fact. For example,
`deploymentKey` in `cli/nagarectl/src/Nagare/Events/Deployment.hs` builds
`app.deployed:<transaction>:<scope>`. Publishing the same fact again yields the same ID, so the
feed never holds it twice and a receiver can deduplicate on it.

**Where events come from today. There are two sources.**

1. *Release-time producers.* Every admin action in Nagare (deploy, stop, restart, delete,
   restore, env or secret change, platform bootstrap) is a *reviewed inventory transaction*. A
   saved review is applied by the executor, whose operations are journaled, and the
   transaction *converges* when every operation completed. At convergence,
   `releaseConverged` in `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs` calls
   `convergedSourceFacts` in `cli/nagarectl/src/Nagare/Inventory/Execute/Sources.hs`. That
   function runs every `SourceProducer` (listed in `builtinProducers`: deployment, backup
   acceptance, subscription controls) over a `SourceInput` that describes the transaction.
   `SourceInput` holds the review digest, the base, desired and previously converged scope
   revisions, the operations and their resources, this transaction's journal events, and the
   native bytes of the members a producer asked for through `wants`. The candidates are
   assembled into an immutable *facts object* (`facts/<digest>.json`), and one convergence
   journal event naming it is appended in the same head write that clears the executor's
   claim. [ADR 39](../adr/0039-lifecycle-sources-are-committed-by-the-converged-release.md)
   records this rule. A producer is pure. If facts cannot be built, the release stops and the
   transaction stays resumable, so a producer that errors on some review would block every
   change. New producers must be total over any review.

2. *Worker observations.* The lifecycle worker `nagare-events`
   (`cli/nagare-api-server/app/Events.hs`) runs in `nagare-system`. Its backup collector
   (`cli/nagare-core/src/Nagare/Events/BackupCollector.hs`) lists the backup bucket, verifies
   each scheduled run's archive and signed receipt, and commits completion candidates to its
   own observation chain (`cli/nagare-core/src/Nagare/Events/Receipts.hs`). A run that fails
   verification is kept as pending with a reason (`collectOnce`, the `failed` list) and is
   never published.

**How sources become the feed.** `materializeOnce` in
`cli/nagare-core/src/Nagare/Events/Materialize.hs` reads, once per cycle, the inventory head,
the journal suffix after its checkpoint (through `readSourceChain` in
`cli/nagare-core/src/Nagare/Events/Source/Chain.hs`), the facts objects those events name, and
the collector's observations. It then publishes envelopes and advances the feed head and its
checkpoint in one conditional write. Today `readSourceChain` only yields convergence events
that carry facts. Delivery (`cli/nagare-core/src/Nagare/Events/Delivery.hs`,
`Subscription.hs`) matches envelopes to subscriptions by an exact set of `EventKind`s.

**The type list in code.** `EventKind`, `EventPayload`, `payloadKind`, the payload records
and their JSON instances live in `cli/nagare-core/src/Nagare/Events/Source/Facts.hs`.
`EventCandidate`'s `FromJSON` and `Envelope`'s `ToJSON`/`FromJSON` switch on the kind. The CLI's
`--type` and the API's `type=` parse through `parseEventKind`, so they accept a new kind
without further change. The OpenAPI description of `LifecycleEvent` in
`cli/nagare-contract/src/Nagare/Contract/Events.hs` lists the types by name and must be
updated. `docs/api/openapi.json` is generated (see `docs/api/README.md`) and
`docs/user/lifecycle-events.md` documents the types for users.

**Facts a new producer needs that already exist.** A transaction ID is `tx-` followed by its
review digest (`reviewDigestOf` in `cli/nagarectl/src/Nagare/Inventory/Execute/Close.hs`), so
the review of any journal event is `reviews/<digest>` (`reviewKey` in
`cli/nagare-core/src/Nagare/Inventory/Store.hs`). The review document `ReviewDocument` in
`cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs` carries `reviewActor` (an operator, maybe
named, or a named deployer), `reviewSource` (repository, commit, CI run), `reviewOperations`
(each with its planned operation, adapter, and a `reviewPublicSummary`), `reviewRetentions`,
`reviewCollections`, and base and desired revisions. A retired scope is in the base revisions
but not converged afterwards, and its members are retained. `Actor` and `ReviewSource` are in
`cli/nagare-core/src/Nagare/Inventory/Actor.hs`. Stop and restart compile, in
`cli/nagarectl/src/Nagare/Inventory/Application/Policy.hs`, to a Service whose
`networking.knative.dev/visibility` label is `cluster-local` (stop) or whose
`nagare.dev/restartedAt` annotation has a new stamp (restart). Backup freshness grading
already exists as `backupFreshness` in `cli/nagare-core/src/Nagare/Inventory/BackupFreshness.hs`.
It returns `Fresh`, `Deteriorating`, `Breached`, `NoRecoveryPoint` or `FutureRecoveryPoint`
against the signed `hourly` or `daily` objective. A release transition's state is the head's
`headTransition` marker (`TransitionMarker` in
`cli/nagare-core/src/Nagare/Inventory/Store/Manifest.hs`). The worker may read the whole
inventory prefix and write only `lifecycle/v1/` (`docs/runbooks/lifecycle-worker-key.md`).

**Relevant ADRs.**
[ADR 39](../adr/0039-lifecycle-sources-are-committed-by-the-converged-release.md): release-time
facts are committed in the head replacement that records convergence, and the journal sequence
is every consumer's checkpoint. This plan adds a second committed-source class, journal failure
and close events, and the ADR is amended at completion.
[ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md):
delivery is transport-neutral. New types need no delivery or route change.
[ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md):
the hourly and daily recovery-point objectives that freshness grades against.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
are found by offline tests, and the native run in M6 only confirms. MasterPlan 31
(`docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md`)
built the feed and said new types are added "through typed producers with explicit
guarantees". This plan follows that rule.


## Plan of Work

Each milestone adds its kinds end to end: the `EventKind` constructor and wire name, a strict
payload record with JSON instances, the cases in `payloadKind`, `EventCandidate` and
`Envelope`, the producer or observer, tests, the OpenAPI description, the `--type` help text
of `events list` and `events webhook create` in `cli/nagarectl/app/Nagare/Cli/Parser/Events.hs`
(which lists the types by name), the regenerated
`docs/api/openapi.json` and samples, and a section in `docs/user/lifecycle-events.md`. Every
payload records what the event guarantees in its Haddock, as `AppDeployment` does.

**M1 — `change.applied`.** Extend `SourceInput` (in `Facts.hs`) with the review's actor,
source, retentions and collections, and a per-operation view: operation ID, action, adapter
identity, public summary and resources. Fill these in `convergedSourceFacts`. Add
`cli/nagarectl/src/Nagare/Events/Change.hs` with `changeProducer`, and register it in
`builtinProducers`. It emits exactly one candidate per converged transaction, keyed
`change.applied:<transaction>`, about the transaction's primary scope. That is the single
changed scope, or the `Platform` scope when several changed, with every changed scope also
listed in the payload. The payload `ChangeApplied` holds `transaction`, `review`, `actor`
(`{kind: operator|deployer, name}`), `source` (repository, revision and run, each nullable),
`scopes` (a list of `{scope, change: created|updated|retired, from, to}`, where `from` and `to`
are scope revisions or null), and `operations` (count by action). A scope is `created` when it
had no converged revision before, `retired` when the review retires it, and `updated`
otherwise. The producer reads no member bytes and no scope, so it cannot fail on input. Tests
in `cli/nagarectl/test/EventsChangeSpec.hs` follow `EventsDeploymentSpec.hs`. A deploy yields
one `change.applied` beside its `app.deployed`. A resumed transaction yields the same key
once. A verification-only rerun still yields `change.applied`, because a converged change
happened. A deployer-applied review carries the deployer's name.

**M2 — `change.failed` and `change.closed`.** Extend `readSourceChain` in `Chain.hs` to also
yield committed journal events whose state is `Failed`, `Ambiguous`, or an `OperatorResolved`
close or abandon marker (`closedMarker` and `abandonedMarker` in
`cli/nagarectl/src/Nagare/Inventory/Execute/Close.hs`; move the marker prefixes to
`nagare-core` if the worker cannot import them). An event at a sequence at or below the head's
`headSequence`, linked by digest to the checkpoint, is committed. Unlike convergence, no
"next event" rule is needed. `materializeOnce` reads the review the transaction ID names, at
most once per transaction per cycle, and builds the candidate in a new
`cli/nagare-core/src/Nagare/Events/Change.hs`. `change.failed` (key
`change.failed:<transaction>:<journal sequence>`) carries `transaction`, `review`, `actor`,
`source`, `operation`, the operation's resources and owning scope, `outcome`
(`failed-no-effect`, `failed-partial-or-unknown` or `ambiguous`), the journal's detail text,
and `next: resume-or-close`. `change.closed` (key `change.closed:<transaction>`) carries
`transaction`, `review`, `how` (`closed` or `abandoned`) and the close record digest when
there is one. Tests use the faultable store fixture of `EventsSourceSpec.hs` to show that a
failed apply publishes one `change.failed`, that resuming to convergence then publishes
`change.applied`, and that a close publishes `change.closed`. A journal object written at the
head's next sequence whose head write failed publishes nothing until a later head commits it.
The review read must fit the existing per-cycle request budget in Materialize, which counts
journal events read. Count a review read against it.

**M3 — app and restore events.** Add release-time producers next to `deploymentProducer`.
`app.deleted` (key `app.deleted:<transaction>:<scope>`) fires for a release subject
(application, standalone service or production site, reusing `subjectOf` from
`Deployment.hs`) whose scope this transaction retired. It carries the last release and the
retained members' count. `app.stopped` and `app.restarted` read the Service member's desired
and previous bytes through `wants`. A stop is the visibility label added. A restart is a
changed `nagare.dev/restartedAt` stamp. A change that also moves the release is reported only
as `app.deployed`. `database.restored` fires for a converged transaction whose operations
include a scratch restore (`cli/nagarectl/src/Nagare/Inventory/Adapters/RestoreScratch.hs`).
It carries the source database, backup ID, restore ID and the scratch target. Each producer
gets a unit test, plus a test that a verification-only rerun yields none.

**M4 — backup failure and freshness.** In `BackupCollector.hs`, publish
`database.backup.failed` (key `database.backup.failed:<schedule>:<run>`) for a run whose
verification failed with a terminal reason: a bad signature, a source that is not the
recorded incarnation, or changed bytes. "The receipt has no backup object" is not terminal,
because the upload may still be in progress, and a run that never completes is reported by
freshness instead. Add each schedule's last published grade to the collector state, committed
in the same conditional write as its observations. After each cycle, grade each schedule with
`backupFreshness`. On a change from the recorded grade, publish
`database.backup.freshness.changed` (key
`database.backup.freshness:<schedule>:<grade>:<newest recovery point or none>`) with `from`,
`to`, `objective` and `newestRecoveryPoint`. The first grade of a schedule is recorded without
an event. Tests drive the collector's existing fake `CollectorOps` through fresh, then a stop
in uploads past both thresholds, then a new upload. They expect exactly the transitions
`fresh→deteriorating`, `deteriorating→breached` and `breached→fresh`, and a restart between
cycles repeats none.

**M5 — `platform.upgraded`.** Add the running release to the worker's feed-side state (beside
the feed head in `cli/nagare-core/src/Nagare/Events/Store.hs`). The release is the payload
version the worker is built from, the same identity `nagarectl platform status` reports as
the payload (see `cli/nagarectl/src/Nagare/Platform/Status.hs`). Pass it into the worker from
`cli/nagare-api-server/app/Events.hs`. In a cycle where the recorded release differs from the
running one and the inventory head has no active transaction and no `headTransition`, publish
`platform.upgraded` (key `platform.upgraded:<from>:<to>`, scope `Platform`) with `from` and
`to`, and record the new release in the same write. The first cycle with no recorded release
only records it. A cycle that sees the marker waits. Tests: marker present means no event;
marker cleared means one event; a restart means none again.

**M6 — native confirmation.** On a disposable local context created with
`--enable-lifecycle-events --enable-lifecycle-delivery`, run the scenarios in Validation and
Acceptance. Read every event through the admin API and through a webhook subscription that
names all thirteen types, pointed at
`cluster/examples/lifecycle-webhook-receiver/Receiver.hs`. Then run `just release-rehearse`
from the latest release to this revision. It must read its seeded data back unchanged, and
the moved context's feed must hold `platform.upgraded` and the events seeded before the move,
unchanged. At completion, amend ADR 39 with the journal-derived source class and the change
that every converged transaction now writes facts, and update
`docs/user/lifecycle-events.md`'s type table.


## Concrete Steps

Work from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. During a milestone, run
the touched test groups directly:

```bash
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Events/'
cd cli/nagare-api-server && cabal test nagare-api-server-test
```

After changing a payload or the `LifecycleEvent` description, regenerate the contract and
accept the samples, then review both diffs:

```bash
cabal run --project-dir=cli/nagarectl nagare-api-openapi
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Contract/ --accept'
git diff docs/api/openapi.json docs/api/samples
```

Per Haskell commit, run `just haskell-style-check` and `just gate-commit`. M1 to M3 touch the
executor's release path (`Sources.hs`), and M2 touches the source chain, so run
`just mutation-check HEAD <base>` before landing them. Its existing EP-232 records
(`cli/nagarectl/test/mutations/EP232-*.diff`) must still be killed. To land a milestone, run
`just gate-fast` on a clean tree, then `just land <rev>`.

A local check of the feed after a scenario:

```bash
nagarectl events list --type change.applied --type change.failed --json | jq '.events[] | {type: .event.type, scope: .event.resource.scope, data: .event.data}'
```

```text
{"type":"change.failed","scope":{"kind":"Application","name":"notes"},"data":{"outcome":"failed-partial-or-unknown","next":"resume-or-close", ...}}
{"type":"change.applied","scope":{"kind":"Application","name":"notes"},"data":{"actor":{"kind":"operator","name":null}, ...}}
```


## Validation and Acceptance

Each milestone is accepted by its unit tests: they fail before the change and pass after,
and they are named in the milestone above. M6 is accepted when, on one disposable local
context, each scenario below produces exactly the listed events. Each must be readable with
`GET /v1/events?type=…` through the admin API and must arrive, signed, at the example
receiver.

A deploy of a new release gives `app.deployed` and `change.applied`. An apply interrupted by a
failing hook gives `change.failed`. Resuming it gives `change.applied`. Closing a second such
failure instead gives `change.closed`. `app stop` gives `app.stopped` and `change.applied`.
`app restart` gives `app.restarted` and `change.applied`. `app delete` with its saved review
applied gives `app.deleted` and `change.applied`. An env change gives only `change.applied`, and
its `scopes` names the app. `db restore` into a scratch database gives `database.restored`.
A backup whose receipt is tampered with gives `database.backup.failed`. Pausing the backup
CronJob past the hourly thresholds gives two `database.backup.freshness.changed` events, and
resuming it gives one more. `just release-rehearse` ends with one `platform.upgraded`. Running
any scenario's command again with nothing to change, or restarting the worker, adds no event
with a new ID.

The labs admin tool is out of this repository. It is ready to integrate when the events
above are listed by `GET /v1/events` and their `data` matches the OpenAPI schema in
`docs/api/openapi.json`.


## Idempotence and Recovery

Every new event's ID comes from its source key, so a retried release, a resumed transaction, a
restarted worker or a replayed cycle publishes nothing new. The tests in M1 to M5 assert
this. Producers are pure and read nothing they cannot already read, so a release that fails
to build facts leaves the transaction resumable, exactly as today. The worker stops at a
journal position it cannot decode and does not skip it. A worker from an earlier release
therefore pauses the feed until the context runs the new worker, and then catches up. No
step deletes or rewrites existing journal, facts, envelope or delivery bytes. A bad milestone
is reverted with `git revert` before the next land. Events it already published on a test
context stay valid history, because readers of later releases still decode every kind.


## Interfaces and Dependencies

No new library. The new kinds and payload records are added to
`Nagare.Events.Source.Facts` (`EventKind`: `ChangeApplied`, `ChangeFailed`, `ChangeClosed`,
`AppDeleted`, `AppStopped`, `AppRestarted`, `DatabaseRestored`, `DatabaseBackupFailed`,
`DatabaseBackupFreshnessChanged`, `PlatformUpgraded`). The wire names are the dotted ones in
Purpose. The labs admin tool and any receiver depend on the wire names, the stable `id`, the
shared `transaction` field that joins events of one change, and the `data` schemas published in
`docs/api/openapi.json`. Once published, a payload field is never removed or renamed. A later
change adds a new type instead. `SourceInput` gains fields in M1. Its only constructor is
`convergedSourceFacts` in `cli/nagarectl/src/Nagare/Inventory/Execute/Sources.hs`, plus the
test fixtures in `cli/nagarectl/test/EventsSourceSpec.hs` and `EventsBackupSpec.hs`.
