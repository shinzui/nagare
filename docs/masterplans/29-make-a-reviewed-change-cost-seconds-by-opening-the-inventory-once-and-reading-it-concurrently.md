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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-23T00:23:39Z
      mode: "update"
      note: "Added EP-217 and EP-218 at the operator's direction; both complete"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:28:11Z
      mode: "update"
      note: "Apply review: reopen EP-217, assign remaining latency and benchmark to new EP-221, reconcile scope, dependencies, ownership and growth acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:15:39Z
      verdict: "changes-requested"
      note: "Assign the failed latency gate to executable follow-up work; reconcile added scope and integration ownership; define growth metrics that distinguish local reads and actual remote transfers."
---

# Make a reviewed change cost seconds by opening the inventory once and reading it concurrently

This MasterPlan is a living document. Progress holds the cross-plan gate with pass/fail evidence
and the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). The Exec-Plan Registry is the source of truth for child status.


## Vision & Scope

After this initiative, saving and applying one team membership or one site grant on the intranet
costs a few seconds each, with no material growth over the specified 50-scope benchmark
increase. Local hydration and validation still grow with accepted history. The trigger is
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
Warm scopes require local reads and decoding, and the complete journal is still validated locally.
Those costs grow with history; the gate measures whether the specified 50-scope increase stays
within its wall-time tolerance. The model is not changed, and constant total work is not claimed.

### Scope boundary

Included: the command-shape fix (EP-212), concurrent immutable reads and publication (EP-213),
the command-scoped En session (EP-214), verified journal caching including long tails (EP-217),
concurrent status native evidence (EP-218), and the remaining fixed-cost reduction and release
benchmark (EP-221). EP-215 is an optional multi-relationship review. EP-216 is a held transport
replacement, outside the required latency gate until its upstream trigger is satisfied.

Excluded: changing the one-scope-per-relationship model; the admin API's recorded reader under
MasterPlan 28; changing the journal format, full-chain validation or head compare-and-swap
protocol; and optimizing the legacy `NAGARE_INVENTORY_GCS_TRANSPORT=gcloud` transport beyond
preserving its behavior. Journal reads and status native evidence are explicitly in scope; the
2026-10-22 expansion supersedes their original exclusions.


## Decomposition Strategy

The original three streams are complete. Two follow-on read paths were added after measurement;
EP-217 is reopened for its long-tail gap, and EP-221 owns the remaining latency acceptance.
Optional batching and the held service-proxy transport remain separate from that required work.

EP-212 owns the command: one open, one ownership proof, one pinned head, one history load, the
history passed to every consumer, admission reusing it only while the locked head is the pinned
head, and the whole-prefix listing gone from planning. Its first milestone adds per-command
counters (store gets split into cached and remote, puts, lists, head reads and wall time) printed
on stderr under `NAGARE_TRACE=1`. Subprocess and forward counts come from EP-185-style PATH
shims. The existing `remote gets` counter counts ObjectOps calls, including one call for a whole
journal batch; it is not an HTTP-request count. EP-221 adds transfer and phase attribution.
EP-212's proof is a fake object store that counts operations per command path.

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

EP-217 owns `readJournalCached`, its anchor and exact tail range, and full-chain validation
through every existing journal consumer. M1-M3 remain accepted historical evidence; M4 removes
the 64-event full-prefix fallback and proves the same behavior for short and long valid tails.

EP-218 owns `readImmutableObjectsEach` and `loadObservationNativeChecked`: bounded reads retain
each member's result so an invalid member cannot be hidden by a missing one. It is complete.

EP-221 owns attribution of the remaining fixed command costs, safe reductions that preserve
fresh ownership checks, and the reproducible 100-scope/50-more-scopes release benchmark. It starts
after EP-217 completes and is the owner of this MasterPlan's still-failing latency gate.

Alternatives considered. A process-wide memo of the gcloud session alone would remove three
gcloud calls per plan but leave the repeated head reads, the second format check, the listing and
the double history load; EP-212 threads the opened store and history through the command and
does not add a process-wide credential memo. Other command paths keep their existing shape.
The three initial streams had distinct proofs and could land in either order after reconciling
the shared history and adapter interfaces. Bundling relationships into one scope was rejected
because the scope is the reviewed unit under ADR 29; this work reduces repeated setup and remote
reads while retaining per-scope local work.

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
| 212 | Open the inventory store once per command and load its history once | [EP-212](../plans/212-open-the-inventory-store-once-per-command-and-load-its-history-once.md) | None | None | Complete |
| 213 | Read immutable inventory members concurrently in one round trip each | [EP-213](../plans/213-read-immutable-inventory-members-concurrently-in-one-round-trip-each.md) | None | EP-212 M1 counters for its intranet confirmation | Complete |
| 214 | Reach the context's En through one forward and one guard per command | [EP-214](../plans/214-reach-the-context-s-en-through-one-forward-and-one-guard-per-command.md) | None | EP-212 M1 counters for its intranet confirmation | Complete |
| 215 | Let one access review carry several memberships or grants | [EP-215](../plans/215-let-one-access-review-carry-several-memberships-or-grants.md) | EP-212 | EP-214 | Not Started |
| 216 | Reach En through the API server's service proxy instead of a port-forward | [EP-216](../plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward.md) | EP-214; trigger: En accepts `X-En-Api-Key` (`mori://shinzui/en/okf/improvement-requests/concepts/IR-1`), pinned and rolled | None | Held |
| 217 | Serve the committed journal from a verified local copy and fetch only its new tail | [EP-217](../plans/217-serve-the-committed-journal-from-a-verified-local-copy-and-fetch-only-its-new-tail.md) | EP-212, EP-213 | None | In Progress |
| 218 | Read inventory status native evidence concurrently | [EP-218](../plans/218-read-inventory-status-native-evidence-concurrently.md) | EP-213 | None | Complete |
| 221 | Close the reviewed access latency gate with measured command costs | [EP-221](../plans/221-close-the-reviewed-access-latency-gate-with-measured-command-costs.md) | EP-212, EP-213, EP-214, EP-217, EP-218 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled, Held.


## Dependency Graph

EP-212, EP-213 and EP-214 were implemented as independent streams; their integration is accepted.
EP-217 depends on the completed EP-212 and EP-213, and EP-218 depends on the completed EP-213.
EP-217 M1-M3 are implemented, but its long-tail acceptance in M4 is outstanding. The required
execution order now is EP-217 M4, then EP-221 M1-M3. EP-221's whole-child prerequisites include
EP-217 Complete; its final milestone owns the release and growth gate described in Progress.

EP-215 depends on EP-212 Complete because it extends the accepted `planRelationship` planner;
it benefits from EP-214's session but is optional and does not displace the required sequence.

EP-216 remains held behind EP-214 Complete and an En release that accepts `X-En-Api-Key`
(`mori://shinzui/en/okf/improvement-requests/concepts/IR-1`), pinned by the auth plane and rolled
onto the context. It replaces all context En transport construction sites, including callers
outside command sessions. It is not a prerequisite for EP-221; if fixed-cost evidence requires
it, revise this graph explicitly and keep the latency gate open rather than silently waiting for
an optional upstream change.


## Integration Points

**Store opening — EP-212 defines; EP-221 extends cost attribution.**
`Nagare.Inventory.Command.Open`, `Store.Target`, `Store.Remote` and `Store.GcloudAuth` own the
opened store and frozen command identity. EP-212's `OpenedInventory` contains `inventoryStore`,
`pinnedHead` and `loadedHistory`; it is not a process-wide memo. EP-221 may reduce measured
opening costs while retaining fresh ownership proof and the existing credential contract.

**History loading — EP-212 defines entry points; EP-213 owns member reads.**
`Nagare.Inventory.Plan.History.loadInventoryHistoryAt` accepts the pinned head;
`seedInventoryHistoryAt` and `loadInventoryPlanningHistoryFrom` reuse existing state. Original
wrappers remain available. EP-213's `readImmutableObjects` hydrates the members in waves of
eight. `InventoryTransactionSpec` and `InventoryAccessSpec` are the shared consumer checks.

**Access adapter construction — EP-212 owns history; EP-214 owns transport.**
`accessReviewAdapter` takes `ReviewInventory`, containing an opened store and optional pinned
history, plus `EnTransport`; `accessAdapter` takes the loaded `InventoryHistory` and transport.
`accessRuntimeOpsWith` returns `IO AccessOps`. Recovery paths without pinned history load as
before. `InventoryAccessSpec` and `InventoryAccessSessionSpec` exercise the combined contract.

**Admission reuse — EP-212 owns.** `admitWithHistory` reuses history only when its head equals
the head observed under the writer lock; otherwise it loads at that locked head. ADR 22 records
this rule. Neither performance follow-up may weaken it or the conditional-write checks.

**Store counters — EP-212 defines; EP-221 owns extensions.** `Store.Counters` and the counting
`ObjectOps` wrapper retain logical operation counts. EP-221 adds separately named HTTP request,
downloaded-object/byte and phase measurements; it must not relabel a batch as one object.
Subprocess counts use recording runners or PATH shims. EP-217 proves exact journal keys fetched
in its own fixture before EP-221 integrates transport-level attribution.

**Journal cache — EP-217 owns.** `Store.readJournalCached`, its cache files and anchor policy
remain under EP-217. It consumes EP-213's `getImmutableObject` and eight-read bound. M4 fetches
only the exact missing suffix for every valid anchor, with no long-tail full-prefix fallback;
the cold/unanchored path and every reader's chain validation stay intact. The early consumer
proof is `InventoryStoreOnceSpec` through `readJournalPrefix` and `validateJournal`, followed
by the recovery model and `InventoryGogolSpec` counting actual downloads. EP-221 consumes this
accepted behavior and adds the end-to-end release measurements.

**Native evidence — EP-218 owns.** `Store.readImmutableObjectsEach` and
`ObservationNative.loadObservationNativeChecked` share EP-213's cache and concurrency bound,
but retain per-key outcomes rather than stopping at the first failed wave. Missing evidence may
select the legacy reader; invalid evidence must refuse. `InventoryImmutableReadSpec` and native
observation tests are the shared checks. EP-221 must preserve these semantics.

**En transport — EP-214 defines; EP-216 replaces every constructor path.** `EnTransport`
keeps `withEn`, `readOwner` and `clusterGuard`. EP-216 owns migration of `Runtime.Cluster`,
`Commands.Access`, `Commands.Inventory.Status`, `Inventory.Workflow`, `Inventory.Planning` and
`Inventory.Execution`, including the latter modules' `kubectlTransport` fallback. It removes
port-forwards only after all callers use the proxy; owner reads and guards still run through
kubectl. EP-221 measures the current session and does not assume EP-216 has landed.

**Planner and durable context.** EP-212 defines `planRelationship`; EP-215 extends it to several
scopes. EP-221 keeps the single-relationship benchmark. EP-217 owns ADR 22's journal-read rule;
EP-221 records any further durable cost/authority decisions there. EP-216 updates ADR 29 when
its transport lands. ADR 29's one-scope-per-relationship model stays unchanged.


## Progress

EP-212, EP-213, EP-214 and EP-218 are Complete. EP-217 is In Progress again: its original
M1-M3 shipped, but M4 must remove the long-tail cliff. EP-221 is Not Started, blocked on EP-217
Complete, and owns closure of the latency gate. EP-215 is optional and not started; EP-216 is
held. No new benchmark or implementation success is claimed by the 2026-10-28 plan update.

Historical evidence: the initial five implemented children were on master at `98886b22`.
Pre-release measurement on the intranet, 2026-10-22, packaged build of
`98886b22` with a warm cache and journal copy, a net-zero revoke and grant of one direct access
grant: plans 7.31 s and 5.46 s (`store opens 1, head reads 1, history loads 1, remote gets 3,
puts 1, listings 0`; about 2 to 3 s of each is the gcloud session), applies 11.80 s and 10.85 s
(`history loads 1, remote gets 38 and 22, cached gets about 7,300, listings 0`), one En
port-forward and one guard pair each. Before: 43.2 s and 67.2 s. The gate below is judged once a
release containing these runs on the intranet:

- [ ] EP-221 M3: on a released build containing the required children, a single team-membership
  plan takes under 5 s and its apply under 15 s at a baseline of at least 100 accepted scopes.
  Repeat after at least 50 additional accepted scopes. For each size, measure five actual
  `add-member` plan/apply samples using a controlled membership removed between samples, after
  one untimed warm-up pair. Keep the machine, release, context, operation and cache policy fixed;
  record all raw times, scope/journal sizes and competing work. Every measured sample must meet
  its threshold. The grown-state median may exceed baseline by at most the larger of 0.25 s or
  5% of baseline median; report the range too. Failed or stale-head runs are reported separately
  and repeated after quiescence, never silently discarded. EP-221 owns a machine-readable result
  artifact and a summary here.

  For the repeated operation, store opens = 1, gcloud sessions = 1, plan head reads = 1,
  history loads = 1 and inventory listings = 0 remain invariant. Check apply head reads/puts
  against the same operation's baseline rather than imposing the plan's head-read count.
  Separately record actual HTTP requests, journal keys/bytes downloaded, subprocesses and
  forward opens. Warm immutable-member downloads stay zero for unchanged members; journal
  downloads are one anchor plus the missing suffix, independent of cached-prefix length.
  Cached reads, decoding and full-chain validation may grow and are reported, not required to
  be constant. Cold-cache results and long-tail results are reported separately, with EP-217's
  64/65-event fixture proving that no full-prefix download is hidden by an ObjectOps batch count.

  First measurement, 2026-10-23, the intranet on the published v0.10.0 (`16f0d7be`), released
  `nagarectl`, `access team remove-member` then `add-member` back of `user_01m4py1q2fesvbtd7xnxr7yede`
  in `engineering` (net zero; that user's direct keiro-docs grant covers the team's host).
  Plans: 5.88 s and 6.69 s (`store opens 1, gcloud sessions 1 (1.77 s, 2.11 s), head reads 1,
  history loads 1, remote gets 5, cached gets 193, puts 3, listings 0`): **fails** the 5 s bound.
  Applies: `tx-168063db…` 111.85 s, the first apply after the release's own transition appended
  more than 64 journal events, so it read the whole journal once (`remote gets 21 (89.58 s)`,
  gcloud 17.43 s while publication ran beside it); `tx-1ec057f1…` 10.70 s (`remote gets 24
  (4.58 s), cached gets 7822, listings 0`): passes the 15 s bound on a current journal copy. The
  50-more-scopes pair is not run. EP-221 owns the fixed-cost failure and rerun; EP-217 M4 owns
  the long-tail failure. These measurements remain failures, not acceptance of the revised gate.


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

2026-10-22: The intranet confirmation (EP-212 M4, EP-214 M4) shows the apply is not bounded by
anything this MasterPlan changed. `Nagare.Inventory.Execute.Transaction` reads the whole journal
(`readJournal`, about 6,900 events through the batch transport) on every apply; the remote gets
of one apply summed to about 60 s of its 67 s. Each command also spends 2 to 3 s creating its
gcloud session. The journal is excluded from this MasterPlan's scope, so the gate's 15 s apply
needs a scope decision before it can be met.

2026-10-22: Scope expanded by the operator after the intranet confirmation. EP-217 serves the
committed journal from a verified local copy and fetches only the new tail (approach A: the chain
is still validated in full; the copy is anchored by one read of its newest event). EP-218 reads
`inventory status`'s native evidence concurrently instead of deferring it. Both build on EP-213's
reads; the gate is measured after them.

2026-10-22: After EP-217 and EP-218 the plan's remaining fixed cost is the gcloud session
(2 to 3 s per command, `Nagare.Inventory.Store.GcloudAuth.newGcloudSession` and the two
ownership reads). It is not addressed here; the plan threshold of 5 s is judged after release.

2026-10-22: EP-215 is optional. It changes what one review may carry, not how fast a review is.
It is listed because it turns a five-person onboarding into one review; the operator may cancel
it without affecting the gate.


2026-10-28 revision: Applied the plan review. Reopened EP-217 for exact suffix reads at every
valid-anchor tail length, added EP-221 as owner of fixed-cost reduction and release acceptance,
and reconciled scope, dependencies and shared interfaces with EP-217/218. The growth gate now
separates invariant command/remote-work counts from growing local work and defines five-sample
thresholds and a median tolerance. EP-216 must migrate all transport callers and retain owner
and guard subprocesses. Existing completed evidence and the optional/held boundaries remain.
The original statement that the remaining fixed cost is unowned is superseded by EP-221.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)
