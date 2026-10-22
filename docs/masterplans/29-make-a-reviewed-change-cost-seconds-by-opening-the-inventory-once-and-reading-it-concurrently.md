---
id: 29
slug: make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently
title: "Make a reviewed change cost seconds by opening the inventory once and reading it concurrently"
kind: master-plan
created_at: 2026-10-22T20:22:15Z
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T20:22:15Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T21:29:32Z
      mode: "update"
      note: "Add held EP-216 (En through the API server's service proxy, trigger IR-1 in en); EnTransport seam ownership; tailnet exposure rejected"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T22:38:49Z
      mode: "implement"
      note: "EP-212 M1-M3 implemented; EP-213 and EP-214 merged onto it, fast gate green at db83d2b6"
---

# Make a reviewed change cost seconds by opening the inventory once and reading it concurrently

This MasterPlan is a living document. Progress holds the cross-plan gate with pass/fail evidence
and the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). The Exec-Plan Registry is the source of truth for child status.


## Vision & Scope

After this initiative, saving and applying one team membership or one site grant on the intranet
costs a few seconds each, and that cost does not grow with the number of scopes the context has
accepted. The trigger is
[BUG-8](../bug-reports/reviewed-access-change-reloads-inventory-history-sequentially.md): on
2026-10-22, thirteen `access team add-member` reviews took 26 minutes on the `tan-ng-labs`
intranet (context `intranet` on the operator's workstation), one `access grant --save-plan` took
28 s on under 5 s of CPU, and its `inventory apply` took 68 s. Its acceptance is adopted here: with
100 accepted scopes, `access team add-member --save-plan` completes in under 5 s and its apply in
under 15 s, and accepting 50 more scopes changes neither measurably.

The fix is to the shape of a `nagarectl` command, not to access. Every command that reads the
inventory benefits. A command opens its store once and proves bucket ownership once; it reads
`head.json` once and pins that head for the whole read; it loads the accepted history once from
that head and hands the loaded history to every consumer; when the digest cache is cold it reads
immutable members with bounded concurrency and one HTTPS round trip each; and a command that
talks to the context's En does so through one port-forward and one cluster guard. A mutation
still observes the head under its writer lock before every conditional write, and admission still
checks the review against that locked head; nothing in the ledger's safety contract
([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md),
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md))
changes.

### What the review found

The code review behind this plan (master `4e0efd38`, the files BUG-8 names unchanged since
v0.9.0) corrects the report's diagnosis in one place and confirms it elsewhere.

**Warm reads are already local.** `Nagare.Inventory.Store.readObjectUnlocked` serves every
immutable key (`scopes/`, `reviews/`, `native/`, `objects/`) from a digest-named cache under
`~/.cache/nagare/<context>/inventory-blobs` (`Nagare.Inventory.Store.Target.inventoryCacheRoot`)
and only fetches on a miss. On the operator's workstation the `intranet` cache holds 1,999 blobs
and gained 133 in the day of BUG-8's fifteen reviews, about nine per review, which is the new
scope, native and review objects of each review and not 86 scope reads per load. The report's
"86 sequential GETs per load" is the cold-cache cost: a new workstation, a cleared cache, a CI
runner or an in-cluster reader. It is worth fixing (EP-213) but it is not what the operator paid
on 2026-10-22.

**A plan opens the store twice and reads the head at least five times.**
`Nagare.Access.Reviewed.planRelationship` calls `Command.loadTargetSnapshotReadOnly` (one open,
one head read, one history load) and then `Command.planInventoryCandidateWith`, whose
`tryPrepareInventoryCandidateWithDeciderPayload` calls `openTargetStore` again and then
`initializeStore`, `seedInventoryHistory` and `loadInventoryPlanningHistory`, each of which
re-reads `head.json`, before `readStoreSnapshot` reads it once more. Each open runs a gcloud
session (`gcloud config config-helper`) and two ownership reads (`readProjectNumber` for the
bucket and the project, each retried with 0.5 s and 1 s pauses on non-numeric output), then
fetches `format.json`. EP-185's profile measured about 5 to 6 s per open on the intranet
([EP-185](../plans/185-make-inventory-status-answer-in-seconds.md), Decision Log, 2026-10-12);
BUG-8's wrapper saw exactly the six gcloud calls two opens produce.

**Every uncached GET is two HTTPS round trips, and absence is proved by listing.** The SDK
transport in `Nagare.Inventory.Store.Gogol` sends an object-metadata request and then a
generation-bound media download for every read, and on a 404 lists the prefix before reporting
absence. `publishIfAbsent` reads before it writes, so each new review, scope and native object
costs a metadata GET, an absence listing and a conditional PUT.

**`readStoreSnapshot` lists every object the context ever wrote.** `listObjectKeys` on the
GCS backend lists the whole prefix (every scope revision, review, native blob and journal event)
to compute `storeSnapshotReviewDigests`, but `prepareReviewWithPayloadIdentity` uses only
`storeSnapshotHead` (`Nagare/Inventory/Plan/Prepare.hs`, line 71). The listing grows with
history and is paged in thousands.

**An apply loads the history twice and re-opens En four times.**
`Nagare.Inventory.AccessRuntime.accessReviewAdapter` loads the history to bind accepted tuples,
and `Nagare.Inventory.Execute.Admission.retentionCoverage` loads it again, unconditionally, under
the writer lock. The access adapter's prepare, preflight, execute and verify phases each call
`accessInspect`, and each inspect runs the cluster guard (`kubectl config current-context` and
`kubectl get nodes`), two owner reads, a fresh `kubectl port-forward svc/en` (about 0.9 s) and
three En requests (`/v1/openapi.json`, `/v1/schema`, the relationship query). BUG-8 counted
twenty kubectl processes for one operation. Every journal append observes the head, writes the
event and compare-and-swaps the head.

**Growth comes from the model, and the model stays.**
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) makes every
relationship its own reviewed scope, so a context that uses teams adds a scope per membership.
After this initiative a scope costs one local cache read, so that growth is harmless into the
thousands; the model is not changed.

### Scope boundary

Included: the command-shape fix (EP-212), the store's cold-read and publish path (EP-213), the
En session (EP-214), and an optional multi-relationship review (EP-215). Excluded: the
one-scope-per-relationship model; the admin API's recorded reader, which already reads with
eight workers and a bounded decode cache (MasterPlan 28); the journal and head compare-and-swap
protocol; the legacy `NAGARE_INVENTORY_GCS_TRANSPORT=gcloud` transport beyond keeping its tests
green; and `inventory status` beyond what it inherits from one open and one load.


## Decomposition Strategy

The work splits by functional concern into three independent streams and one optional extension,
each with its own proof fixture.

EP-212 owns the command: one open, one ownership proof, one pinned head, one history load, the
history passed to every consumer, admission reusing it only while the locked head is the pinned
head, and the whole-prefix listing gone from planning. Its first milestone adds per-command
counters (store gets split into cached and remote, puts, lists, head reads, gcloud and kubectl
spawns, forwards, wall time) printed on stderr under `NAGARE_TRACE=1`, because BUG-8's apply
breakdown was never instrumented and this MasterPlan's gate is measured with those counters. Its
proof is a fake object store that counts operations per command path.

EP-213 owns the store's remote read and publish path: immutable members read through the digest
cache with bounded concurrency, one media round trip per immutable object verified by digest, and
a digest-named publish that attempts the conditional create before reading. Its proof is the
existing local GCS fixture in `cli/nagarectl/test/InventoryGogolSpec.hs`, which already counts
requests, media GETs and maximum in-flight downloads.

EP-214 owns the En session: one port-forward per command, the cluster guard once per command,
the capability and schema checks once per command, owner identity still checked at every phase
and before every write. Its proof is a transport seam the fake can count through, in the style
of `AccessOps`.

EP-215 lets one `add-member`, `remove-member`, `grant` or `revoke` review carry several
relationships, so onboarding five people to a team is one review instead of five. It is
independent of the speed fix and the operator may cancel it; it waits for EP-212 because both
rewrite `planRelationship`.

Alternatives considered. A process-wide memo of the gcloud session alone would remove three
gcloud calls per plan but leave the repeated head reads, the second format check, the listing and
the double history load; EP-212 threads the opened store and history through the command and
keeps a memo only as the backstop for paths that still open twice. One plan for everything was
rejected because the three fixtures and the three modules are disjoint and the streams can land
in any order. Bundling relationships into one scope to slow the growth was rejected because the
scope is the reviewed unit under ADR 29 and the fix removes the per-scope cost instead.

Relevant durable context: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
owns the store contract (immutable digest-named members, a canonical head, conditional writes)
and is amended by EP-212 with the one-open, one-pinned-head rule;
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) keeps the
bucket-ownership proof on every command (once, never skipped);
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) puts the
proof in fakes and fixtures and leaves the intranet run to confirm;
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
constrain admission, which must keep deciding from the head it holds under the lock;
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) is the access model
that stays; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) binds the
Haskell to `mori://shinzui/haskell-jitsurei/docs/core-standards`. EP-185's Decision Log holds the
only prior measurement of the store open on the intranet.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 212 | Open the inventory store once per command and load its history once | [EP-212](../plans/212-open-the-inventory-store-once-per-command-and-load-its-history-once.md) | None | None | In Progress |
| 213 | Read immutable inventory members concurrently in one round trip each | [EP-213](../plans/213-read-immutable-inventory-members-concurrently-in-one-round-trip-each.md) | None | EP-212 M1 counters for its intranet confirmation | In Progress |
| 214 | Reach the context's En through one forward and one guard per command | [EP-214](../plans/214-reach-the-context-s-en-through-one-forward-and-one-guard-per-command.md) | None | EP-212 M1 counters for its intranet confirmation | In Progress |
| 215 | Let one access review carry several memberships or grants | [EP-215](../plans/215-let-one-access-review-carry-several-memberships-or-grants.md) | EP-212 | EP-214 | Not Started |
| 216 | Reach En through the API server's service proxy instead of a port-forward | [EP-216](../plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward.md) | EP-214; trigger: En accepts `X-En-Api-Key` (`mori://shinzui/en/okf/improvement-requests/concepts/IR-1`), pinned and rolled | None | Held |

Status values: Not Started, In Progress, Complete, Cancelled, Held.


## Dependency Graph

EP-212, EP-213 and EP-214 start together and land in any order. EP-212 M1 (the counters) is the
first thing to land because the other two use it to attribute their intranet confirmation, but
neither needs it to implement or to prove itself against its fixture. EP-215 waits for EP-212
to complete: both change `planRelationship` in `cli/nagarectl/src/Nagare/Access/Reviewed.hs`,
EP-212 to take the opened store and pinned history, EP-215 to compile a non-empty list of scopes.
The cross-plan gate in Progress runs once EP-212, EP-213 and EP-214 are in a release the intranet
runs.

EP-216 is held. It replaces EP-214's kubectl transport behind the same `EnTransport` seam with
plain HTTPS to the API server's service proxy, and can start only when an En release that accepts
`X-En-Api-Key` (IR-1 in `mori://shinzui/en`) is pinned by the auth plane and rolled onto the
context. It is not part of the gate.


## Integration Points

**Store opening — EP-212 owns.** `Nagare.Inventory.Store`, `Nagare.Inventory.Store.Target`,
`Nagare.Inventory.Store.Remote` and `Nagare.Inventory.Command.openTargetStore`. EP-212 decides
how an opened store and its gcloud session live for the command and how a second open in the same
process becomes a local check. EP-213 adds read and publish functions to `Nagare.Inventory.Store`
and must not change the open path or the `Backend` constructor; its worker bound is a constant,
like the journal batch's eight workers in `Nagare.Inventory.Store.Gogol`.

**History loading — split by line.** In `cli/nagarectl/src/Nagare/Inventory/Plan/History.hs`,
EP-212 owns the entry points: it adds `loadInventoryHistoryAt`, which takes an already-read
`HeadManifest` and never reads the head, and makes `seedInventoryHistory` and
`loadInventoryPlanningHistory` take the head too. EP-213 owns the member reads inside the loader:
the four sequential `traverse` calls over accepted, retained, collected and migration members
become one bounded concurrent read of the needed immutable keys through the new store function.
Neither plan edits the other's lines; the representative check is `InventoryTransactionSpec` and
`InventoryAccessSpec` passing with both changes applied.

**Access adapter construction — split by argument.** `Nagare.Inventory.AccessRuntime.accessReviewAdapter`
and `Nagare.Access.Reviewed.accessAdapter` both load the history and both build
`accessRuntimeOps`. EP-212 changes where the history comes from (a parameter, not a load);
EP-214 changes what `accessRuntimeOps` is built from (a command-scoped En session and a memoized
guard). The existing `InventoryAccessSpec` plan and apply tests are the shared check.

**Admission reuse rule — EP-212 owns, ADR 22 records.** `Nagare.Inventory.Execute.Admission.admit`
may reuse a history loaded before the writer lock only when the head observed under the lock is
byte-identical to the head that history was loaded from; otherwise it reloads at the locked head.
This rule is the durable context EP-212 writes into ADR 22 when it lands, together with EP-213's
read rule once EP-213 lands.

**Counters — EP-212 owns.** A counting `ObjectOps` wrapper and a subprocess counter, summarized
on stderr under `NAGARE_TRACE=1`. EP-213 and EP-214 cite those lines as their live evidence; their
fixture-level proofs use the counters the fixtures already have.

**`EnTransport` seam — EP-214 owns, EP-216 implements.** EP-214 defines `EnTransport`
(`withEn`, `readOwner`, `clusterGuard`) and the command-boundary session; EP-216 adds a second
implementation over the API server's service proxy and removes the kubectl one. Neither changes
the adapter above the seam.

**`planRelationship` — EP-212 then EP-215.** EP-212 lands its signature first; EP-215 extends it
to a `NonEmpty` of compiled scopes.

Deliberate exclusion worth recording: ADR 29 §5 (one scope per relationship) is unchanged by this
initiative. The MasterPlan's Decision Log holds that decision; no ADR change is needed for it.


## Progress

EP-212 M1–M3, EP-213 M1–M4 and EP-214 M1–M3 are implemented, merged and fast-gate green together
(`db83d2b6`). Each child's remaining milestone is its intranet confirmation (EP-212 M4, EP-213 M5,
EP-214 M4), which keeps all three In Progress; EP-215 waits for EP-212 to complete. The one
cross-plan gate:

- [ ] On the intranet, after EP-212, EP-213 and EP-214 are in the release it runs:
  `nagarectl access team add-member --team T --user U --save-plan DIR` completes in under 5 s and
  `nagarectl inventory apply DIR --yes` in under 15 s, each with its `NAGARE_TRACE=1` summary
  recorded here, and a second pair after the context has accepted at least 50 more scopes shows
  the same counts and no measurable change in wall time.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: Fix the command shape, not the model. BUG-8's cost is one store open per phase,
one head read per consumer, one whole-prefix listing per plan, one port-forward and guard per
En call, and two round trips per cold read. ADR 29's one-scope-per-relationship stays; after the
fix a scope is one local cache read.

2026-10-22: The report's primary diagnosis is corrected. The digest cache under
`~/.cache/nagare/<context>/inventory-blobs` already makes warm scope reads local (1,999 blobs on
the operator's workstation, 133 added over the day's fifteen reviews). Concurrent cold reads stay
in scope as EP-213, with the cold cache named as the case they fix.

2026-10-22: Measure before and after with counters in the command (EP-212 M1), because the
apply breakdown was never instrumented and the gate is a measured number. Fakes and fixtures
prove the counts (ADR 25); the intranet run confirms. The confirming apply is a real reviewed
change on the intranet and needs the operator's go-ahead once.

2026-10-22: En stays behind the API server; the forward goes later, not onto the tailnet. A
read-only probe showed the API server's service proxy reaches En in 0.10 to 0.12 s with the
kubeconfig's client certificate, but the API server deletes `Authorization` after authenticating,
and En reads its key only from that header. IR-1 in `mori://shinzui/en` asks for `X-En-Api-Key`;
EP-216 is held behind it. Exposing En on the tailnet (hostPort, subnet route or Tailscale
operator) was rejected: `tailscale0` is fully trusted by the host firewall, so En's write API
would be gated by its key alone. EP-214 stays as written.

2026-10-22: The three streams were implemented in parallel and merged in the order EP-212,
EP-214, EP-213. `Nagare.Test.Suite` sits at its 300-line limit, so EP-214's session tests run
under the existing `Nagare.Access` group and EP-213's and EP-212's store tests share an
"inventory object store" group. The recovery model's pinned admission faults are at store reads
11 and 12 on the merged code, confirmed by logging the key at each counted read.

2026-10-22: EP-215 is optional. It changes what one review may carry, not how fast a review is.
It is listed because it turns a five-person onboarding into one review; the operator may cancel
it without affecting the gate.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)
