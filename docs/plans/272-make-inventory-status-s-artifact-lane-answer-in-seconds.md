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
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-21T05:55:10Z
      verdict: "changes-requested"
      note: "M2 could bypass the guard under suppressed errexit and reordered guard and ownership check; M3 ran the old script; existing fakes unaccounted for"
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-21T05:55:10Z
      mode: "update"
      note: "Applied the review: guard order and errexit rule for the batch, test cases reshaped, M3 runs M2's script"
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
  requests, and its stdout is a JSON array of today's observations in the same order. Per process
  it runs `_require_target_project` once, before its first cloud OCI member's ownership check, and
  `gcloud auth print-access-token | skopeo login` once, before its first registry read.
  `observeResources` sends its requests as at most eight contiguous batches, run concurrently.
  Pass: `scripts/test-deployer-artifact-transport.sh` gains batch cases. A 3-member cloud batch
  with three different destinations makes exactly one `skopeo login` and three `skopeo inspect`
  calls, one per destination in request order, and returns three observations in order. A batch
  of only ownership-mismatched members yields `TransportOwnershipMismatch` for each with no
  `skopeo` call. A batch run with an ambient `CLOUDSDK_CORE_PROJECT` that differs from the
  context's project exits non-zero with the guard's refusal on stderr and no `skopeo` call. A
  batch whose second member fails exits non-zero, prints no observation array, and names that
  member's resource on stderr. In `InventoryArtifactSpec`, M1's case now shows 24 requests
  reaching the fake transport in at most eight processes, every one `observe-batch`, and the
  existing fake transports answer both actions. `just gate-commit` is green.
- [ ] M3: native confirmation, read-only, on labs, with a development build of M2's commit
  running M2's transport script (see Concrete Steps: status runs the script from the context's
  prepared platform workspace, not from the checkout). The pass line is `time nagarectl --context
  intranet inventory status >/dev/null` exiting 0 at under 60 s wall, against the 334 s baseline.
  Record the wall time and the artifact member count here. The status read itself needs no
  operator go-ahead, but a concurrent inventory commit can still void it: rerun when status
  reports the head changed.


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
- 2026-11-20 (review): The order of a cloud OCI observation stays guard, then ownership check,
  then login, as `observe_oci_image` has it today. The first draft put the guard and the login in
  one helper and the ownership check before it, which would have let a mismatched member answer
  under a refusing guard. The guard and the login are now two once-per-process steps.
- 2026-11-20 (review): The batch loop runs each member's `observe` as a plain statement, never
  inside `if`, `||`, `&&`, `!` or `$(…)`. `_require_target_project` and `load_local_substrate`
  refuse with `return 1`, which stops the script only through `set -e`, and bash ignores `set -e`
  in those contexts. Captured there, a refused guard would be followed by a login and an inspect.
  The guard call also carries an explicit `|| exit 1`.
- 2026-11-20 (review): The `archive` inheritance case is dropped. No OCI observation reads
  `archive`, so it could only be shown through a local-substrate fixture with a fake `k3d`. The
  per-destination `skopeo inspect` assertion shows that each member's request is reloaded. The
  batch guard-refusal case goes in `scripts/test-deployer-artifact-transport.sh`, which already
  has the context and the recording fakes, not in `scripts/test-inventory-transport-guards.sh`.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Inventory status** (`nagarectl inventory status`, implemented in
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs`) reads the accepted inventory and
then observes every accepted resource live. Each executor (Kubernetes, Helm, Pulumi, artifact,
host, cache, broker, CDN, access) is observed in its own concurrent lane (`runConcurrently` near
line 359, from EP-185 M4, `docs/plans/185-make-inventory-status-answer-in-seconds.md`). The
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
the next call. Its `trap … EXIT`, which removes the auth directory, is the only reason it is a
subshell.

**How the script stops on a refusal.** The script runs under `set -euo pipefail`.
`_require_target_project` and `load_local_substrate` print a reason and `return 1`. The script
stops there only because `set -e` is in effect at the call. Bash ignores `set -e` for everything
run inside an `if` condition, a `||` or `&&` list, a `!`, and (without `inherit_errexit`) a
command substitution.

**Other callers of `observe`.** `inspectRemote` in `ArtifactRuntime.hs` and
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Image.hs` (near line 281) send one request to `observe`,
and `publish` ends by calling `observe`. All three keep the one-request contract.

**Which copy of the script runs.** `runtimeArtifactExecutable` is `scripts/inventory-artifact-transport.sh`
under the context's platform workspace (`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` near
line 482). That workspace is a copy of the platform payload under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/<payloadId>-<digest>`. Status
finds it with `findPlatformWorkspace` (`cli/nagarectl/src/Nagare/Platform/Workspace.hs`) and never
creates it. The binary and the script therefore always come from the same payload, so a new
binary never meets a script without `observe-batch`.

**Why it grew.** EP-185 measured the artifact lane on 2026-10-12, when the intranet had only a
handful of images. Since `aa564953` (2026-11-01, "publish release images into the context
registry") and app image publication, the intranet carries about 129 publication members. The
serial loop has been there since `4a322617` (2026-09-22).

**Precedent for the bound of eight.** `Nagare.Inventory.Store.readImmutableObjectsEach`
(`cli/nagarectl/src/Nagare/Inventory/Store.hs`, EP-218) reads in waves of eight, and
`Nagare.Inventory.KubernetesSnapshot` keeps at most eight grouped reads in flight with a `QSem`.

**Tests.** `cli/nagarectl/test/InventoryArtifactSpec.hs` drives `mkArtifactRuntimeOps` against a
fake transport executable written to a temporary directory (around lines 438–545). Three fakes
there answer `observeResources` today with one observation whatever the action is: the two inline
ones at "build observe and publish require outer protocol v2" and "subprocess runtime binds the
reviewed destination and digest", and `withStatefulTransport`. Script tests
run as Nix checks in `nix/checks/scripts.nix`: `scripts/test-deployer-artifact-transport.sh`
(recording fakes for `gcloud` and `skopeo`, a throwaway context under `XDG_CONFIG_HOME` that
declares project `proj`, and a `run` helper that takes extra `VAR=value` environment), and
`scripts/test-inventory-transport-guards.sh`, which has no fakes and no context.

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

**M2, the script.** Accept `observe-batch` in the action check. Move the per-request parse and
validation into a function `load_request REQUEST_JSON` that assigns every per-request global
(`version`, `kind`, `destination`, `expected`, `source_digest`, `archive`) on each call. `observe`
and `publish` call it once with stdin, as today.

Make `observe_oci_image` an ordinary `{ … }` function with the same `local`s, and move its
cleanup to one top-level `trap … EXIT` that removes a process-level private directory when one
was made. Its cloud branch becomes three steps in today's order:

1. `require_guard_once`: the first call in the process runs `_require_target_project || exit 1`
   and records that it passed. Later calls return at once.
2. The per-image `app_image_prefix` check, unchanged. A mismatch emits
   `TransportOwnershipMismatch` and returns.
3. `registry_authfile_once`: the first call makes the private directory (mode 700) and runs
   `gcloud auth print-access-token | skopeo login … || exit 1`. Later calls reuse the authfile.

The local branch is unchanged. A single `observe` and the `observe` at the end of `publish` go
through the same three steps, once each, so their behavior does not change.

`observe-batch` reads stdin, checks it is a JSON array (`jq -e 'type == "array"'`, else exit 2),
and reads the members with `jq -c '.[]'` on file descriptor 3, so a member's command cannot
consume the list. For each member it calls `load_request`, records the member's `resource`, and
runs `observe >>"${private_dir}/observations"` as a plain statement (Decision Log, 2026-11-20).
After the last member it prints `jq -sc . "${private_dir}/observations"`. An empty array prints
`[]`. A member's failure ends the script through `set -e` with that member's status. The member's
own stderr has already passed through, and the `EXIT` trap adds `artifact <resource>: observation
failed` when the status is non-zero and a member was in progress. Nothing is printed on stdout in
that case.

**M2, Haskell.** Add `runTransportBatch :: ArtifactRuntimeConfig -> [TransportRequest] -> IO
(Either Text [TransportObservation])` beside `runTransportClassified`, sharing its environment and
`bash` invocation (factor those into one helper) with action `observe-batch`. It fails if the
response length differs from the request length. `observeResources` first checks that every
resource has a spec (today's error, first in input order). With no resources it starts no process.
Otherwise it splits the requests into at most `artifactObserveWidth` contiguous chunks of
near-equal size, runs them with `mapConcurrently`, and zips each observation back to its resource.
The chunk count is the bound, so M1's `QSem` is removed. `sequence` over the chunk results gives
the first failing chunk in input order, and the script gives the first failing member in it.

Tests. Change the three existing fakes named in Context so that `observe-batch` prints their
observation inside a one-element array (each is used with one resource). Change M1's fake to
answer `observe-batch` with one `TransportMissing` per request (`jq length` of stdin) and to log
one line per invocation with its action. The assertions become: at most 8 lines, every one
`observe-batch`, peak in flight at least 2, results in input order. The failing-member case makes
the fake exit 1 when its batch contains that resource. Add the script cases Progress lists to
`scripts/test-deployer-artifact-transport.sh` with a `run_batch` helper beside `run` that builds
the array with `jq`. The guard case passes `CLOUDSDK_CORE_PROJECT=other` through the helper, which
makes `_require_target_project` refuse with "does not match the active context's declared
project".

**M3.** Build and time it as Concrete Steps shows, and record the result.


## Concrete Steps

From the repository root `/Users/shinzui/Keikaku/bokuno/nagare`:

```bash
just gate-commit            # after each Haskell commit: style, build and tests of touched packages
bash scripts/test-deployer-artifact-transport.sh   # M2 script cases, guard refusal included
```

Expected tails:

```text
deployer artifact transport passed
```

Per landing, with a clean tree: `just gate-fast`, then `just land`.

M3, against labs, from the operator's context directory so direnv loads the intranet context.
The development binary takes its payload from `NAGARE_PLATFORM_ROOT`, here the checkout at M2's
commit:

```bash
cd /Users/shinzui/Keikaku/work/infrastructure/tan-ng-labs
export NAGARE_PLATFORM_ROOT=/Users/shinzui/Keikaku/bokuno/nagare
time direnv exec . "$(cd "$NAGARE_PLATFORM_ROOT" && cabal list-bin nagarectl)" \
  --context intranet inventory status >/dev/null
```

The checkout's payload digest differs from the installed release's, so the first run is expected
to stop with:

```text
the platform workspace for this context is not prepared: …; a planning command such as `nagarectl inventory plan` or `nagarectl platform upgrade` prepares it
```

Status never prepares a workspace. Stop there and ask the operator how to prepare it: a planning
command prepares the workspace but may also write a review to the context's inventory store,
which is not a read. Once it is prepared, confirm the script is M2's before timing:

```bash
grep -c observe-batch ~/.local/state/nagare/intranet/platform/*/scripts/inventory-artifact-transport.sh
```

Commit messages follow Conventional Commits, for example `perf(artifact): observe artifacts
eight at a time`, with the trailer `ExecPlan: docs/plans/272-make-inventory-status-s-artifact-lane-answer-in-seconds.md`.


## Validation and Acceptance

Acceptance is the Progress pass lines. M1 and M2 are proved by the fake-transport and script
tests, and M3 confirms natively. Behavior that must not change: an unknown resource still yields
`artifact resource is absent from the execution specification: <id>`. An ownership mismatch is
still an `ObservationUnavailable` with the artifact ownership code. A guard refusal still fails
the observation before any registry read, for a single `observe` and for every member of a batch,
including a member whose destination would fail the ownership check. A single `observe` and
`publish` still take exactly one request and print one observation.


## Idempotence and Recovery

Every step is a code change or a read. Observation never mutates, so the tests and M3 can be
rerun freely. If M3 regresses on labs, reverting M2's commit restores M1's behavior, and reverting
M1's restores today's. Neither touches inventory state.


## Interfaces and Dependencies

- `Control.Concurrent.Async.mapConcurrently` and `Control.Concurrent.QSem`, both already in
  nagarectl's dependencies.
- The transport contract in `scripts/inventory-artifact-transport.sh`: actions `observe`,
  `observe-batch` (new), and `publish`. `observe-batch` takes a JSON array of `TransportRequest`
  documents on stdin and prints a JSON array of `TransportObservation` documents of the same
  length and order, or exits non-zero and prints no array.
- `Nagare.Inventory.Adapters.ArtifactRuntime.runTransportBatch` (new, module-internal).
- External tools the batch keeps using: `jq`, `gcloud`, and `skopeo`. A hosted deployer image
  has no `awk` and no `/usr/bin/env` (EP-248), so the script change uses neither.
