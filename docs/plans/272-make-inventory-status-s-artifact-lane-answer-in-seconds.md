---
id: 272
slug: make-inventory-status-s-artifact-lane-answer-in-seconds
title: "Make inventory status's artifact lane answer in seconds"
kind: exec-plan
created_at: 2026-11-21T05:31:37Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-21T05:31:37Z
---

# Make inventory status's artifact lane answer in seconds

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10).


## Purpose / Big Picture

On 2026-11-20 `nagarectl --context intranet inventory status` on labs (the `intranet` context,
GCP project `tan-ng-labs`) took 334 s. Nearly all of that time went to observing about 129
accepted OCI image publications one after another, at about 2.6 s each. A read that long is
also *unusable*, not just slow. Any commit to the inventory during the read (a deployer such as
kotei-fa landing a deploy) makes status exit with `accepted inventory changed during status;
retry against the new head`, so on a busy context it rarely finishes.

After this plan, the artifact lane takes seconds. M1 runs the per-image observations eight at a
time (about 45 s). M2 has each transport run do the project guard and the registry login once and
then observe a batch of images (about 10 s). The operator sees it in the wall time of
`inventory status` on labs, and in status finishing between deploys.


## Progress

- [ ] M1: `observeResources` in `cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs`
  runs at most eight transport processes at once, keeps results in input order, and reports the
  first failing resource in input order, exactly as today. Pass: a new `InventoryArtifactSpec`
  case, "EP-272: artifact observation runs at most eight transports at once, in order". Its fake
  transport records the peak number in flight over 24 resources: peak is at most 8 and at least 2,
  results are in input order, and one failing member yields that member's error. `just
  gate-commit` is green.
- [ ] M2: the transport gains an `observe-batch` action. Its stdin is a JSON array of today's
  requests, and its stdout is a JSON array of today's observations in the same order. It runs
  `_require_target_project` once before any cloud read, and for cloud OCI members it runs
  `gcloud auth print-access-token | skopeo login` once per process. `observeResources` sends its
  requests as at most eight contiguous batches, run concurrently with M1's bound. Pass:
  `scripts/test-deployer-artifact-transport.sh` gains batch cases. A 3-member cloud batch makes
  exactly one `skopeo login` and three `skopeo inspect` calls and returns three observations in
  order. A batch whose second member has no `archive` does not inherit the first member's. An
  ownership-mismatched member yields `TransportOwnershipMismatch` without touching the registry.
  `scripts/test-inventory-transport-guards.sh` gains a case: a batch under a context whose
  project the guard refuses exits non-zero, with no `skopeo` call. The new `InventoryArtifactSpec`
  case shows 24 requests reach the fake transport in at most eight processes. `just gate-commit`
  is green.
- [ ] M3: native confirmation, read-only, on labs, with a development build of M2's commit. The
  pass line is `time nagarectl --context intranet inventory status >/dev/null` exiting 0 at
  under 60 s wall, against the 334 s baseline. Record the wall time and the artifact member count
  here. This is a read, so it needs no operator go-ahead, but a concurrent inventory commit can
  still void it: rerun when status reports the head changed.


## Surprises & Discoveries

(None yet.)


## Decision Log

- 2026-11-20: The operator asked for both changes in one plan: bounded concurrency (M1) and one
  guard plus login per transport run (M2). M1 lands alone first because it is a few lines and
  cuts most of the time. M2 changes the unit of concurrency from one request to one batch.
- 2026-11-20: The batch keeps the GCP guardrail exactly as strict. `_require_target_project`
  still runs in every transport process before that process's first cloud read, and a refusal
  still stops the process before any registry or `gcloud` read. Only how often it runs changes,
  from once per image to once per batch. `publish` is untouched and keeps one request per
  process.
- 2026-11-20: The batch is all or nothing, as `observeResources` already is (`sequence` over the
  members). A member's failure exits the batch non-zero with stderr naming the resource. No new
  per-member error type is added.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Inventory status** (`nagarectl inventory status`, implemented in
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs`) reads the accepted inventory and
then observes every accepted resource live. Each executor (Kubernetes, Helm, Pulumi, artifact,
host, cache, broker, CDN, access) is observed in its own concurrent lane (`runConcurrently` near
line 348, from EP-185 M4, `docs/plans/185-make-inventory-status-answer-in-seconds.md`). The
command therefore takes as long as its slowest lane.

**The artifact lane** calls `adapterObserve` on the artifact adapter
(`cli/nagarectl/src/Nagare/Inventory/Adapters/Artifact.hs`). That is
`artifactObserveResources`, implemented by `observeResources` in
`cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs`:

```haskell
observeResources config resources = do
  observations <- traverse observe resources
  pure (sequence observations >>= observationSet)
```

Each `observe` calls `runTransport config "observe"`. That starts `bash
scripts/inventory-artifact-transport.sh observe` with one canonical JSON request on stdin
(`TransportRequest`: version, resource, kind, destination, expectedDigest, specDigest, archive,
plan) and reads one JSON observation from stdout (`TransportObservation`: `TransportMissing`,
`TransportPresent`, or `TransportOwnershipMismatch`). The environment carries
`NAGARE_INVENTORY_ADAPTER_CHILD=artifact`, without which the script refuses. Planning
(`cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs` near line 394) observes through the same
function, so reviews get faster too.

**The transport** `scripts/inventory-artifact-transport.sh` parses the single request into shell
globals (`version`, `kind`, `destination`, `expected`, `source_digest`, `archive`), sources
`scripts/lib/target.sh` to resolve the active context, and dispatches `observe()` on `kind`. For a
cloud `OciImageArtifact`, `observe_oci_image` runs `_require_target_project` (the fail-closed GCP
guard in `scripts/lib/target.sh`), checks the destination against `app_image_prefix`, makes a
private `mktemp -d` auth directory, runs `gcloud auth print-access-token | skopeo login`, and then
runs `skopeo inspect --format '{{.Digest}}'`. Starting bash, resolving the context, running the
guard, minting a token and logging in cost most of the 2.6 s. The inspect itself is a fraction of
a second. `observe_oci_image` is a subshell function `( … )`, so nothing it sets survives into
the next call.

**Why it grew.** EP-185 measured the artifact lane on 2026-10-12, when the intranet had only a
handful of images. Since `aa564953` (2026-11-01, "publish release images into the context
registry") and app image publication, the intranet carries about 129 publication members. The
serial loop has been there since `4a322617` (2026-09-22).

**Precedent for the bound of eight.** `Nagare.Inventory.Store.readImmutableObjectsEach`
(`cli/nagarectl/src/Nagare/Inventory/Store.hs`, EP-218) reads in waves of eight, and
`Nagare.Inventory.KubernetesSnapshot` keeps at most eight grouped reads in flight with a `QSem`.

**Tests.** `cli/nagarectl/test/InventoryArtifactSpec.hs` drives `mkArtifactRuntimeOps` against a
fake transport executable written to a temporary directory (around lines 438–545). Script tests
run as Nix checks in `nix/checks/scripts.nix`: `scripts/test-deployer-artifact-transport.sh`
(recording fakes for `gcloud` and `skopeo`, and a throwaway context under `XDG_CONFIG_HOME`), and
`scripts/test-inventory-transport-guards.sh`.

**ADRs.** [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires the active-context project assertion on every cloud path, and `CLAUDE.md` extends it to
reads. M2 keeps it per process (see Decision Log).
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
fake-transport tests find the defects, and M3 only confirms. No ADR covers adapter concurrency.
None is needed, since this follows EP-185 and EP-218.


## Plan of Work

**M1.** In `observeResources`, replace `traverse observe resources` with an ordered bounded
concurrent map: `mapConcurrently` from `Control.Concurrent.Async` over the resources, each action
wrapped in `bracket_ (waitQSem sem) (signalQSem sem)` with a `QSem` of 8 created per call. Name
the width `artifactObserveWidth = 8`, with a comment citing EP-218. `mapConcurrently` keeps input
order, so `sequence` still returns the first failure in input order. `inspectRemote` and
`publishArtifact` stay as they are. In `InventoryArtifactSpec`, add the M1 case. Its fake
transport `mkdir`s a unique file under an `inflight` directory, counts the entries into a log,
sleeps 0.2 s, removes its entry, and echoes a `TransportMissing` observation. Read the peak from
the log. Run one more case with one member's request making the fake exit 1, and check the
`Left` names that member.

**M2, the script.** Move the per-request parse into a function `load_request REQUEST_JSON` that
*resets and then sets* every per-request global (`version`, `kind`, `destination`, `expected`,
`source_digest`, `archive`). Keep the validation it does today. Add a parent-shell helper
`ensure_registry_auth`. On its first call in the process it runs `_require_target_project`, makes
the private auth directory (removed by a top-level `trap … EXIT`) and logs in. After that it
returns at once. `observe_oci_image` calls it in cloud mode and uses the resulting authfile. Since
`observe_oci_image` is a subshell, the dispatcher calls `ensure_registry_auth` in the parent
before entering `observe` for a cloud `OciImageArtifact`. Keep the per-image ownership check
(`app_image_prefix`) and run it before the login, so a mismatched member never triggers one. Add
the action: `observe-batch` reads a JSON array, and for each element (`jq -c '.[]'`) calls
`load_request` and `observe`, collecting outputs. It prints one JSON array (`jq -s`). On a member
failure it prints `artifact <resource>: <stderr>` to stderr and exits with that member's status.
`observe` and `publish` keep their current one-request behavior through the same `load_request`.

**M2, Haskell.** Add `runTransportBatch :: ArtifactRuntimeConfig -> [TransportRequest] -> IO
(Either Text [TransportObservation])` beside `runTransportClassified`, reusing its environment and
`bash` invocation with action `observe-batch`. It fails if the response length differs from the
request length. `observeResources` validates that every resource has a spec (today's error,
first in order). It splits the requests into at most `artifactObserveWidth` contiguous chunks of
near-equal size, runs them with `mapConcurrently`, and zips each observation back to its
resource. Add the M2 Haskell case: the fake transport logs one line per invocation, and 24
requests produce at most 8 lines, every one `observe-batch`. Extend the two script tests as
Progress describes.

**M3.** Build and time it as Concrete Steps shows, and record the result.


## Concrete Steps

From the repository root `/Users/shinzui/Keikaku/bokuno/nagare`:

```bash
just gate-commit            # after each Haskell commit: style, build and tests of touched packages
bash scripts/test-deployer-artifact-transport.sh   # M2 script cases
bash scripts/test-inventory-transport-guards.sh    # M2 guard case
```

Expected tails:

```text
deployer artifact transport passed
```

Per landing, with a clean tree: `just gate-fast`, then `just land`.

M3, read-only against labs, from the operator's context directory so direnv loads the intranet
context, with the development build on `PATH` (`cabal list-bin nagarectl`):

```bash
cd /Users/shinzui/Keikaku/work/infrastructure/tan-ng-labs
time direnv exec . "$(cd /Users/shinzui/Keikaku/bokuno/nagare && cabal list-bin nagarectl)" \
  --context intranet inventory status >/dev/null
```

Commit messages follow Conventional Commits, for example `perf(artifact): observe artifacts
eight at a time`, with the trailer `ExecPlan: docs/plans/272-make-inventory-status-s-artifact-lane-answer-in-seconds.md`.


## Validation and Acceptance

Acceptance is the Progress pass lines. M1 and M2 are proved by the fake-transport and script
tests, and M3 confirms natively. Behavior that must not change: an unknown resource still yields
`artifact resource is absent from the execution specification: <id>`. An ownership mismatch is
still an `ObservationUnavailable` with the artifact ownership code. A guard refusal still fails
the observation before any registry read. `publish` still takes exactly one request.


## Idempotence and Recovery

Every step is a code change or a read. Observation never mutates, so the tests and M3 can be
rerun freely. If M3 regresses on labs, reverting M2's commit restores M1's behavior, and reverting
M1's restores today's. Neither touches inventory state.


## Interfaces and Dependencies

- `Control.Concurrent.Async.mapConcurrently` and `Control.Concurrent.QSem`, both already in
  nagarectl's dependencies.
- The transport contract in `scripts/inventory-artifact-transport.sh`: actions `observe`,
  `observe-batch` (new), and `publish`. `observe-batch` takes a JSON array of `TransportRequest`
  documents on stdin and prints a JSON array of `TransportObservation` documents.
- `Nagare.Inventory.Adapters.ArtifactRuntime.runTransportBatch` (new, module-internal).
- External tools the batch keeps using: `jq`, `gcloud`, and `skopeo`. A hosted deployer image
  has no `awk` and no `/usr/bin/env` (EP-248), so the script change uses neither.
