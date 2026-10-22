---
type: Bug Report
title: A one-tuple access change takes about two minutes because every plan reloads the whole inventory history one object at a time
description: Saving and applying one team membership or site grant reads every accepted scope from the GCS inventory store with sequential GETs, twice per plan and again during apply, so routine access changes take about 100 seconds each and grow slower with every scope the context accepts.
generated:
  by: process:claude-code
  at: "2026-10-22T20:05:00Z"
bugId: BUG-8
status: reported
severity: degraded
origin: mori://tan/tan-ng-labs
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: 0.9.0
environment: >-
  tan-ng-labs intranet context on Nagare 0.9.0 (CLI, payload, host and
  cluster), GCS inventory store gs://tan-ng-labs-intranet-cblovqm-state/inventory
  with 86 accepted scopes (24 of them access relationships), operator on a
  macOS workstation in us-west reaching the cluster through kubectl.
observed: >-
  Creating three teams with 13 memberships (`access team add-member`, each
  saved and applied as its own review) took 26 minutes, about two minutes per
  membership. One `access grant --host HOST --team TEAM --save-plan DIR` took
  27 to 28 seconds of wall time on under 5 seconds of CPU; its `inventory apply`
  took 68 seconds. Each operation changes one En tuple.
expected: >-
  Team membership and site grants are the routine way to manage who can reach a
  protected site (docs/user/access.md, "Teams"). A review that changes one
  relationship should cost a few seconds, independent of how many unrelated
  scopes the context has accepted, so that onboarding a handful of people is
  not a half-hour operation.
workaround: >-
  Script the plan-and-apply loop and run it unattended; each change still takes
  about two minutes, but no operator attention is needed while it runs.
reproduction:
  - On a context with a GCS inventory store and a few dozen accepted scopes, export NAGARE_EN_API_KEY.
  - "Run `time nagarectl access team add-member --team t --user EMAIL --save-plan DIR` and note wall time far above user+sys time (here 25.5 s real, 3.8 s user, 1.1 s sys)."
  - Put a logging wrapper named `kubectl` and one named `gcloud` ahead of the real binaries on PATH and repeat; the subprocesses account for only about 6 of the 27 seconds.
  - "Run `nagarectl inventory apply DIR --yes` and observe about 70 seconds for the single operation."
  - Accept another access relationship and repeat; every plan reads one more scope object.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-22T20:05:00Z"
    document_timestamp: "2026-10-22T20:05:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.9.0 source (e6314c40; the files named in the
      body are unchanged on master 438458dd) and timings taken on the tan-ng-labs
      intranet with wrapped kubectl and gcloud. The apply breakdown is not
      instrumented. No independent verification attestation is claimed.
---

# A one-tuple access change takes about two minutes because every plan reloads the whole inventory history one object at a time

**Reported by:** a `claude-code` session operating the `mori://tan/tan-ng-labs` intranet
(runbook `docs/runbooks/operations.md` in that project; artifact-level URI pending) on Nagare
v0.9.0 (`e6314c408b747befd8af2329c2eebfa46563d76b`).


## What happens

On 2026-10-22 the operator created three teams and granted one of them the portal:

```text
13 x  access team add-member … --save-plan DIR ; inventory apply DIR --yes   19:29 → 19:55 UTC  (26 min)
 1 x  access grant --host labs.topagentnetwork.net --team tan --save-plan DIR   28 s
 1 x  inventory apply DIR --yes                                                  68 s
```

A re-plan of the same grant (no operations) was timed with `/usr/bin/time -l`: 25.5 s real, 3.8 s
user, 1.1 s sys. The process is waiting, not computing. With logging wrappers for `kubectl` and
`gcloud` on PATH, a 27.3 s plan broke down as:

```text
gcloud   6 calls  3.8 s   storage buckets describe ×2, projects describe ×2, config config-helper ×2
kubectl  5 calls  1.7 s   port-forward svc/en, get domainmapping, get nodes, get service en, config current-context
CPU               ~5 s
unaccounted      ~17 s    in-process HTTPS to the GCS inventory store
```

The unaccounted time is the inventory history. `loadInventoryHistory`
(`cli/nagarectl/src/Nagare/Inventory/Plan/History.hs`) reads one object per accepted scope, plus
one per retained and collected resource, with `traverse`, so the GETs run one after another:

```haskell
loaded <- traverse (loadScope store) (Map.toAscList (headAccepted headValue))
```

The intranet's `head.json` lists 86 accepted scopes. A single scope-object GET from the
operator's workstation takes 0.12 to 0.21 s (curl, 8 samples, mean 0.15 s), so one history load
costs roughly 9 to 13 s.

A reviewed access plan loads the history twice and opens the store twice:

1. `planRelationship` (`Nagare/Access/Reviewed.hs`) calls `Command.loadTargetSnapshotReadOnly`,
   which opens the store read-only and runs `loadInventoryHistory`.
2. It then calls `planInventoryCandidateWith`, whose
   `tryPrepareInventoryCandidateWithDeciderPayload` (`Nagare/Inventory/Command.hs`) calls
   `openTargetStore` again, then `seedInventoryHistory` and `loadInventoryPlanningHistory`.

Each store open shells out to `gcloud` three times (bucket describe, project number, access
token), which accounts for the six `gcloud` calls.

`inventory apply` took 68 s for one operation, of which kubectl was 9 s (20 calls: four
`accessInspect` rounds, each a fresh `kubectl port-forward svc/en` of about 0.9 s plus
`get domainmapping`, `get nodes` and `get service en`). The rest was not instrumented. It is
consistent with the store being opened and the history reloaded during admission, execution and
close, but the reporter did not confirm which phases do so.

### Why it grows

Every reviewed relationship is its own scope ("Every reviewed relationship is one independent
scope", `Nagare/Access/Reviewed.hs`). The 15 relationships made on 2026-10-22 raised the
context's accepted access scopes from 9 to 24. Each one adds another sequential GET to every later
history load, for every command that loads history, not only access commands. A team of a few
dozen people over a few sites will add hundreds of scopes.

The planner itself is not the bottleneck: it observes only the touched binding. The observation
is serial and opens a new port-forward per `accessInspect` (`withContextEn`, "The forward lives
for one call"). This costs about 1 s per inspect, minor next to the history loads.


## Consequences

- **Routine onboarding takes half an hour.** Adding five people to three teams is 13 reviews at
  about 2 minutes each. Revoking someone from every team costs the same.
- **It gets worse with use.** Access relationships are the fastest-growing scope kind on a
  context that uses teams, and each one slows every later plan and apply on that context.
- **Operators batch or bypass.** The cost pushes toward fewer, larger changes, or toward scripts
  that run unattended. Both weaken the per-change review the commands exist to provide.


## Expected

A one-relationship review should cost a few seconds, and its cost should not grow with the
number of unrelated accepted scopes.

Possible directions, for the owning repository to choose:

- Fetch accepted scope objects concurrently, with bounded parallelism. Scope objects are
  content-addressed and immutable, so ordering does not matter. This alone should take a load
  from roughly 13 s to under 1 s.
- Load the history once per command. `planRelationship` already has the snapshot when it calls
  `planInventoryCandidateWith`. Open the store once per command too, so `gcloud` runs once.
- Cache scope objects locally by digest, which is safe because they are immutable. Only
  `head.json` must be read fresh.
- Optionally, let one review carry several memberships or grants, such as `add-member` with
  repeated `--user`, so onboarding is one review instead of N.
- Reuse one en port-forward across the `accessInspect` calls of a command.

Acceptance: on a context with 100 accepted scopes, `access team add-member --save-plan` completes
in under 5 s and its apply in under 15 s, and adding 50 more scopes does not measurably change
either.


## Current state on the reporter's cluster

All 14 changes converged. Teams `core-tan`, `engineering` and `tan` exist on the intranet, and
`tan` holds the viewer grant on `labs.topagentnetwork.net`. Nothing is stuck.
