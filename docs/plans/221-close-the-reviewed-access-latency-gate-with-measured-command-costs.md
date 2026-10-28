---
id: 221
slug: close-the-reviewed-access-latency-gate-with-measured-command-costs
title: "Close the reviewed access latency gate with measured command costs"
kind: exec-plan
created_at: 2026-10-28T19:18:09Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T19:18:09Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-28T21:13:15Z
      mode: "implement"
      note: "Prerequisites met after EP-217 M4"
---

# Close the reviewed access latency gate with measured command costs

This ExecPlan is a living document under
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md).
Update Progress with acceptance evidence and keep scope decisions in the Decision Log. Record
implementation friction through the exec-plan skill and distill durable changes into ADR 22.


## Purpose / Big Picture

The first performance work shipped, but a released team-membership plan still took 5.88 and
6.69 s against its under-5-s target. A warm apply took 10.70 s; an apply after a platform
transition took 111.85 s because a long journal suffix triggered a full download. EP-217 owns
that suffix defect. This plan owns the remaining command costs and final proof: a released
single-membership plan under 5 s and apply under 15 s at at least 100 scopes, with the same
bounds after 50 additional scopes and a bounded change in median time.

A warm cache means the command's already-accepted immutable members and a previously validated
journal prefix are available locally. It does not mean pre-running the measured mutation or
skipping ownership, head, owner-identity or journal checks. Cold-cache measurements remain
separate evidence; they cannot replace the warm-path gate or be silently counted as warm runs.


## Progress

- [x] M1: Command costs can be attributed to credential acquisition, bucket/project ownership,
  store opening, En setup/reads, immutable hydration and journal transfer. A controlled fixture
  proves logical calls, actual HTTP requests, downloaded objects/bytes and subprocess counts
  are distinct and correctly attributed, including a batch containing many events.
- [x] M2: Measured fixed costs are reduced while fresh ownership, frozen credentials, locked-head
  admission and owner UID rechecks still refuse the same unsafe cases. Start with overlapping
  the independent bucket/project ownership probes. Deterministic recording fakes prove the
  overlap and refusals; a representative reviewed membership path proves the integrated result.
  Record before/after phase costs and any evidence-driven further implementation decision.
- [ ] M3: The released five-sample membership benchmark passes under 5 s per plan and 15 s per
  apply at both scope sizes; growth stays within the defined median tolerance. Record the long-tail
  confirmation separately, all raw timings and transfer counts, and the release/fixture identity.
  MasterPlan 29's Progress links this evidence and closes its gate only when every criterion passes.

EP-217 is Complete (2026-10-28), so every hard prerequisite is met.

M1 evidence, 2026-10-28 (fixtures). `Store.Counters` keeps the logical counters and adds a
command trace: named phases (count and time) and wire transfers keyed by request kind (metadata,
media, listing, upload) and object class (control, scopes, reviews, native, journal, bucket,
other), with downloaded bodies and bytes. `NAGARE_TRACE=1` prints them as `nagarectl trace:
phases:` and `nagarectl trace: http:` lines beside the store lines. Phases recorded: `gcloud
credential helper`, `bucket ownership`, `project ownership`, `gcloud ownership read` (each
subprocess, so retries count), `transport setup`, `en forward`, `en request`, `owner read`,
`cluster guard`. No credential, header or body is traced. Tests: `InventoryGogolSpec` "a 100-event
journal batch is one logical remote get and 100 media downloads on the wire (EP-221)" (logical
`RemoteGet` +1; wire listing/journal 15 requests, media/journal 100 requests, 100 bodies, exact
bytes); `InventoryGcloudAuthSpec` "concurrent expiry performs one refresh" now also proves two
`gcloud credential helper` phases; `InventoryAccessSessionSpec` "one tuple's five phases" proves
`en forward` 1, `cluster guard` 1, `owner read` 6 per owner and `en request` equal to the En
calls the fake served. The released-command phase budget is taken with the packaged build below.

Baseline subprocess timings, intranet (`tan-ng-labs`, clean `env -i`, read-only), three runs:
`gcloud config config-helper` 0.50-0.53 s; `storage buckets describe` 0.83-1.44 s; `projects
describe` 0.73-0.79 s; the two ownership reads one after the other 1.62-2.17 s, together
0.88-0.93 s.

M2 evidence, 2026-10-28. `Store.Remote.provenOwnership` runs the bucket and project reads with
`concurrently`, each keeping `readProjectNumber`'s retries, and returns
`bucketOwnershipVerdict` before any store is built; the SDK and legacy paths both use it.
`InventoryGcloudAuthSpec` "the bucket and project ownership reads overlap, and both must answer
and agree (EP-221)": with a barrier each read waits for the other, the pair succeeds in exactly 2
reads (a serial implementation, tried by hand, takes 3 and fails); a different, missing, empty or
malformed number refuses after the same retries (1 read for a number, 3 otherwise). Credential
identity and refresh tests are unchanged and green.

Re-measured, 2026-10-28, packaged build of `7624c5e4` (`nix build git+file://…?rev=…#nagarectl`),
clean `env -i` with `nagarectl context env`, read-only `NAGARE_TRACE=1 nagarectl --context
intranet inventory publications`, three runs: `gcloud sessions 1` 2.22 s (first, credential helper
1.08 s), then 1.23 s and 1.23 s, against 1.77-2.11 s in the released plans; phases `gcloud
credential helper` 0.44-0.45 s, `bucket ownership` 0.73-0.75 s and `project ownership` 0.74-0.75 s
overlapped (`gcloud ownership read 2`, 1.48 s summed), `transport setup` 0.03 s; store open 0.27 s
and head read 0.22-0.24 s, each a metadata and a media request (`http: metadata control 2, media
control 2 (2 bodies, 76813 bytes)`); wall 1.78-1.80 s warm.

Traced reviewed membership, 2026-10-28, operator go-ahead: the net-zero pair `access team
remove-member` then `add-member` of `user_01m4py1q2fesvbtd7xnxr7yede` in `engineering`, each
`--save-plan` and `inventory apply --yes` back to back, packaged build, clean `env -i`,
`NAGARE_TRACE=1`; `access check` on `keiro-docs.labs.topagentnetwork.net` answered `allowed`
before and after every pair. With `7624c5e4`: plans 4.94 s and 4.62 s (trace wall 4.89 and
4.57 s): gcloud session 1.20-1.22 s, store open, head and two reads 0.74-0.80 s (`http: metadata
control 3, media control 3 (3 bodies, 153555 bytes), upload reviews 1`), put 0.14-0.24 s, then
`cluster guard` 0.44-0.85 s, `en forward` 0.48-0.98 s, `en request 4` 0.48-0.49 s and `owner read
2` 0.31-0.33 s one after the other; five kubectl calls each. Applies 26.17 s and 10.35 s. The
first caught up 431 journal events written by other commands since 2026-10-23 (`media journal 431
(431 bodies, 165022 bytes)`; anchor and missing suffix only, EP-217 M4) and had one slow
`project ownership` read (4.94 s); the second `head reads 10` 2.34 s, `remote gets 22` 4.58 s,
`puts 10` 1.48 s, `media control 11 (11 bodies, 769747 bytes)`, `media journal 9`.

The En session's guard and forward started only after the store was open, so `93c67277` prepares
them while it opens: `AccessRuntime.prepareEnSession` runs the remembered guard, then opens the
forward through the session's own first-use path, and the session waits for it before release.
`InventoryAccessSessionSpec` "(EP-221)": the forward opens while the command has not reached en
and the command then shares the one guard and one forward (user and team bindings); a refused
guard or a missing or empty key opens no forward and first use asks the guard again; a command
that throws during preparation still stops the forward. A mutant that opens the forward after a
refused guard fails the second test. Access plans and `access check` use it; `Reviewed.accessAdapter`
sets `KUBECONFIG` only when the command has not already selected that file, so it never races the
prepared kubectl. Re-measured with the packaged `93c67277`, two more pairs: plans 5.89 s (first
run of the new binary; trace wall 4.18 s), 3.13 s, 3.59 s and 3.30 s, with guard and forward
summing 0.64-2.24 s and overlapping the store open; applies 11.74 s, 10.01 s, 10.43 s and 10.87
s; `access check` 2.12 s. Apply still opens its session lazily (decision below).


## Surprises & Discoveries

The existing `GcloudSession` timer in `Store.Target` wraps all of `remoteObjectOps`, which
includes credential acquisition, two ownership probes and transport construction. Its 1.77-2.11 s
release measurements do not isolate the credential helper. Likewise `RemoteGet` counts one
`getObjects` call for an arbitrarily large batch. M1 must resolve both before choosing a
credential optimization. No cross-command credential or ownership cache is justified by those
aggregated numbers.


## Decision Log

2026-10-28: Keep EP-212/213/214/218 Complete and add one follow-up child for the unowned latency
gate. EP-217 fixes the journal algorithm; this child owns command attribution, safe fixed-cost
reduction and end-to-end acceptance. EP-215's multi-subject feature and EP-216's upstream-dependent
proxy are not prerequisites. The five-second target is unchanged.

2026-10-28: Compare five successful samples of the same actual membership addition at each
scope size, keep every sample below the original thresholds, and allow growth of the median by
at most max(0.25 s, 5% of baseline median). Local cached reads and full-chain validation may grow;
remote reads of unchanged immutable members must not. These are finite benchmark criteria, not
a claim that all work is constant for arbitrarily large histories.


2026-10-28: M2's second reduction prepares the En session (guard, then forward) while the
store opens, chosen from the traced membership plan, where they ran after it for 0.9-1.8 s. Only
commands that always reach en prepare it: access plans and `access check`. `inventory apply` keeps
opening its session on first use, because most applies have no access operation and their warm
membership apply is 10.0-10.9 s against 15 s. M2 is complete; M3 remains.


## Outcomes & Retrospective

Pending implementation. Preserve failures as evidence and keep this child open until the
released-command and growth criteria pass. Completing attribution or fixtures alone is not
completion of the latency objective.


## Context and Orientation

`cli/nagarectl/src/Nagare/Access/Reviewed.hs` plans one relationship through
`Command.openInventoryForPlanning` and `planInventoryCandidateLoaded`, sharing an opened store,
pinned head and loaded history. `cli/nagarectl/src/Nagare/Inventory/Command.hs` applies with a
`ReviewInventory` and `applyReviewedWithHistory`; `Execute/Admission.hs` only reuses history under
an equal locked head. Those are the accepted EP-212 guarantees.

`cli/nagarectl/src/Nagare/Inventory/Store/Target.hs` times `remoteObjectOps` as `GcloudSession`.
`Store/Remote.hs` calls `newGcloudSession`, then sequentially calls `readProjectNumber` for the
bucket and project via the session's frozen `sessionCapture`. `Store/GcloudAuth.hs` takes a fresh
helper snapshot, preserves account/project/impersonation/endpoint identity, and serializes token
refresh inside that command. `Nagare.Ops.PulumiBackend.readProjectNumber` owns bounded retries
and `bucketOwnershipVerdict` refuses missing, nonnumeric or different owners. This plan changes
ordinary SDK store opening only; discovery, bootstrap and the legacy transport retain their
existing authority and behavior.

`cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs` and `Store.hs` count logical ObjectOps
calls. `Store/Gogol.hs` performs HTTP reads, downloads and batch worker operations. Its tests in
`cli/nagarectl/test/InventoryGogolSpec.hs` already count requests and in-flight downloads.
`InventoryStoreOnceSpec.hs` proves opens/history/admission and journal cache behavior.
`InventoryGcloudAuthSpec.hs` supplies the credential runner/clock seam. Confirm actual test
names before constructing focused Tasty patterns; an empty test selection is not evidence.

`cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs` holds `EnTransport`, `withEnSession`,
`accessRuntimeOpsWith` and the per-phase owner checks. `InventoryAccessSessionSpec.hs` proves
one session and repeated owner reads. `cli/nagarectl/test/Nagare/Test/ContractCommands.hs` is the
representative plan/apply fixture. `docs/plans/185-make-inventory-status-answer-in-seconds.md`
describes subprocess PATH shims; these log command categories/times without secrets.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires
pinned history and full journal validation. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires fresh ownership proof. [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)
and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
keep recovery and identity checks intact. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
puts the first proof in interpreters/fixtures; the intranet confirms. Haskell follows
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md).


## Plan of Work

M1 adds attributable measurements without changing behavior. Preserve the logical store counters
and label them as such. Add distinct per-command measurements for helper acquisition, each
ownership probe including retries, transport setup and En operations. At the SDK request/download
boundary count actual HTTP attempts, successfully downloaded objects and body bytes; classify
journal transfers separately from head/format metadata, scope members and native members. Use
monotonic elapsed time, concurrency-safe accumulation and no credentials, headers or object
contents in trace output. Count each wire attempt once; do not add logical-wrapper totals to
HTTP totals. Aggregate measurements from worker requests into the command summary even when the
logical caller made one batch request. Keep stdout and saved review bytes unchanged.

Use the Gogol fixture to request a batch of 100 known events and show one logical batch with
100 event-body downloads plus its separately counted listing/metadata requests. Use fake clocks
and recording subprocess runners for phase attribution, including retry/failure paths. Run one
representative membership plan/apply through the fixtures before broadening counters to less
relevant paths. Record a phase budget using the released reproduction; do not infer helper cost
from the old combined timer.

M2 first overlaps the two independent `readProjectNumber` calls in the SDK branch of
`Store.Remote.remoteObjectOps`, after the single frozen credential session exists. Introduce a
small injectable ownership helper using the existing capture/pause functions. Both probes must
finish and pass `bucketOwnershipVerdict` before constructing an operational store or doing any
object mutation. Preserve their bounded retries, failure messages and the session's environment.
A barrier-based fake proves both probes can start before either finishes; no fragile wall-time
assertion is needed. Wrong, missing, malformed, timed-out or changing ownership answers must
still refuse with no object writes. Token refresh and explicitly selected identity tests remain
green. This plan does not inspect gcloud's credential database or persist identity/ownership
answers across commands.

Re-measure the same path. If the independent-probe overlap is insufficient, use M1's measured
critical path to choose and document the next reduction within the existing store/En session
boundaries, with a representative producer/consumer proof before expansion. Do not remove an
ownership or owner UID read merely because it dominates time. A different credential authority,
new cross-command cache, or dependency on held EP-216 requires an explicit plan/ADR revision;
leave the gate open with the measured blocker rather than relaxing the target or claiming the
first optimization is sufficient. This decision boundary is necessary because the present
aggregate timer does not establish which remaining phase dominates.

M3 adds a reproducible benchmark runner under `scripts/benchmark-reviewed-access.py` and a
result artifact under `docs/audits/mp29-latency/`. Keep scenario identity, sample times, command
counts, actual transfers, release revision, cache state, scope count, journal prefix/tail lengths
and competing-work notes in machine-readable output. The runner takes explicit context, team,
user and output-directory arguments, refuses incomplete setup, and never provisions arbitrary
users or grants as a side effect. The real reviewed mutation uses the operator-authorized
benchmark membership and restores its baseline between samples. A failed apply stops sampling
and reports the transaction to resume; it does not attempt blind cleanup of a stopped transaction.

Use at least 100 accepted scopes for baseline, warm the accepted immutable members and journal
copy with one untimed plan/apply pair, then measure five actual add-member plan/apply pairs.
Remove the benchmark membership between pairs using normal reviewed operations; exclude those
cleanup timings but retain their traces. After at least 50 additional legitimate or explicitly
authorized fixture scopes have been accepted, repeat with the same machine, release, context,
operation and warm-cache policy. Record the precise counts; do not fabricate production scopes
just to finish the test. If the second population is not available, the gate remains pending.
Also confirm an anchored suffix above 64 events on the released path using a preserved valid
cache snapshot or a real transition; report exact tail size and transfer counts separately.
Never edit remote journal events to manufacture this scenario.


## Concrete Steps

From the repository root, inspect the current code and run focused suites as changes land:

```bash
rg -n 'remoteObjectOps|readProjectNumber|GcloudSession|countedOps' cli/nagarectl/src/Nagare/Inventory/Store
just haskell-style-check
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/inventory/||/access/"' --test-show-details=direct
just gate-fast
```

For each authorized live sample, use a fresh review directory and the released binary. Replace
the explicit example arguments with the recorded benchmark fixture; inspect the saved review
before apply. The benchmark runner automates this sequence only for the selected fixture:

```bash
NAGARE_TRACE=1 nagarectl --context intranet access team add-member --team BENCHMARK_TEAM --user BENCHMARK_USER --save-plan SAMPLE_DIR
NAGARE_TRACE=1 nagarectl --context intranet inventory apply SAMPLE_DIR --yes
```

Use the repository release workflow to get the candidate onto the intranet; release publication
is a separate authorized operation, not an implicit effect of the benchmark script. Record both
the pre-release measurements and subsequent released measurements without conflating them.


## Validation and Acceptance

M1's fake and HTTP fixtures distinguish logical calls, actual attempts and bytes. M2 proves
overlapping ownership reads and unchanged refusals; the representative membership plan/apply,
credential tests, access-session tests, recovery model and `just gate-fast` pass.

For M3, every one of the five measured plans at each scope size is under 5 s and every apply
under 15 s. Report all values, medians and ranges. The grown-state median for each command must
be no more than baseline median plus max(0.25 s, 5% of baseline median). Record stale-head or
failed runs separately, repeat after quiescence, and never silently remove slow successes.
Run without concurrent release/build work; if that condition is violated, retain the run and
label a fresh complete set rather than selecting favorable individual samples.

For the same membership operation at both sizes, require one store open, one credential session,
one plan head read, one history load and zero inventory listings. Compare apply head reads and
puts against the same operation's baseline. Require one forward and one cluster guard per
command on EP-214's transport; if a separately accepted EP-216 has landed, record zero forwards
and explain that environment change before comparing runs. Report owner reads without removing
the per-phase checks. Unchanged immutable members cause no remote download, and a valid journal
prefix costs one anchor plus the exact missing suffix. Cached reads, decoding, chain validation
and tail size are reported separately and need not be constant. Cold-cache performance is not
part of this warm-cache threshold, and any large-tail timing is explicitly labeled with its size.

Update the MasterPlan's gate with the result artifact, release and verdict. If any threshold,
growth criterion or prerequisite is unmet, leave M3 and the MasterPlan gate open with the next
concrete action. Do not substitute successful fixture counts for released wall-time acceptance.


## Idempotence and Recovery

Tracing and fixture runs are read-only or use disposable stores. Preserve the operator's normal
cache; cold experiments use a temporary `XDG_CACHE_HOME`. Live membership samples publish and
apply ordinary immutable reviews. On a stale review re-plan; on a stopped transaction follow
`inventory resume`/the existing reviewed recovery workflow before another sample. Store raw
results even on failure and restore the benchmark membership only through reviewed operations.
No cache-file or remote-head editing is allowed as benchmark cleanup.


## Interfaces and Dependencies

Hard dependencies are Complete
[EP-212](212-open-the-inventory-store-once-per-command-and-load-its-history-once.md),
[EP-213](213-read-immutable-inventory-members-concurrently-in-one-round-trip-each.md),
[EP-214](214-reach-the-context-s-en-through-one-forward-and-one-guard-per-command.md),
[EP-217](217-serve-the-committed-journal-from-a-verified-local-copy-and-fetch-only-its-new-tail.md)
and [EP-218](218-read-inventory-status-native-evidence-concurrently.md). Their artifacts are the
opened/pinned store, bounded reads, command En session, exact anchored journal suffix and native
reader. EP-217 M4 is accepted.

This child owns extensions to `Store.Counters`/SDK transfer attribution and the benchmark
artifact schema, preserving logical-counter meanings. EP-217 owns the journal read algorithm;
EP-214 owns the `EnTransport` contract; optional EP-216 owns its replacement. No new dependency
or version pin is selected here. If implementation needs a dependency API, locate its source
through Mori and verify upstream releases before choosing bounds, following repository policy.
