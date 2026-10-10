---
id: 184
slug: make-the-gates-wait-only-for-their-slowest-job-and-stop-losing-gate-runs-to-the-builder
title: "Make the gates wait only for their slowest job and stop losing gate runs to the builder"
kind: exec-plan
created_at: 2026-10-10T14:02:40Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-10T14:02:40Z
---

# Make the gates wait only for their slowest job and stop losing gate runs to the builder

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-10-10 a full gate (`just gate`) took about 55 minutes for one push batch, and two earlier
full gates that night were lost to the remote builder. The operator called this "very painful" and
asked for all three causes to be fixed (MasterPlan 26 finish-line item 9, added that day).

The time goes to three things, measured on the operator's workstation (10 cores):
- **The same test suite runs three times, one after another.** The full gate runs the fast gate's
  `cabal test nagarectl-test` locally (16–19 minutes). Only then does it start
  `nix flake check --all-systems`, which builds `nagarectl` for `aarch64-darwin` locally and for
  `x86_64-linux` on the remote builder. Each of those builds runs the whole suite again, because the
  shipped derivation runs its own tests (`nix/haskell-packages.nix`). The flake check took 29
  minutes.
- **The suite runs on one thread.** `cli/nagarectl/test/Nagare/Test/Suite.hs` wraps the whole tree
  in `localOption (NumThreads 1)`. EP-87 added that in 2026-07, when 340 tests raced on process
  environment variables and the working directory. The suite now has 1,455 tests, and seven of them
  take about 1,090 of its 1,168 seconds (gate log of 2026-10-10T10:42Z):

  | Test | Seconds |
  |---|---|
  | rename recovery model, F62 ("a source replaced outside review at any read of it…") | 487 |
  | recovery model harness self-test (EP-177) | 273 |
  | recovery model fast tier (12 explicit and 43 generated scenarios) | 129 |
  | snapshot search finds what the replay search finds (EP-179) | 93 |
  | GCS scheduled prune interrupted at every call | 49 |
  | rename recovery model, F52 | 27 |
  | MinIO scheduled prune interrupted at every call | 25 |

  Everything else, about 1,440 tests, takes about 80 seconds.
- **Gate runs are lost to the builder and redone from the start.** The full gate probes the
  builder first, then spends about 25 minutes on local steps while the builder sits idle. Its
  idle watchdog can stop the VM in that window. The proxy restarts a stopped VM only when gcloud
  can authenticate, and on 2026-10-10 it could not (`Reauthentication failed. cannot prompt during
  non-interactive execution`). The flake check then failed at minute 29 with
  `platform mismatch … Required system: 'x86_64-linux'`. An IAP connection drop
  (`Connection closed by UNKNOWN port 65535`) cost another whole run. Each failure meant
  re-running all 55 minutes.

After this plan:
- **The fast gate** (`just gate-fast`, run before every Haskell commit and by the pre-push hook)
  runs the suite in parallel, with the slow model tests split into shards. Its test step takes
  minutes, not 19 minutes.
- **The full gate** runs every distinct check once, and runs the local and remote work at the same
  time. Its wall time is close to its slowest single job, not the sum.
- **The full gate does not lose runs to the builder.** It refuses in seconds when gcloud cannot
  authenticate, keeps the builder awake while it runs, and retries a remote step once after a
  transport failure instead of failing the run.
- **Landing is one command.** The deep tier and the mutation sweep, when a change needs them, run
  inside the full gate alongside the flake check, and the gate record holds their results.

Nothing that a gate proves today is dropped. Every test, scenario, fault placement and mutation
record still runs at the same gate it runs at today ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).


## Progress

- [ ] M1. The suite runs in parallel. The tests that change process-global state run in one
  sequential group, and each slow model test is split into shards that cover exactly its current
  runs. Measured before and after; the fast gate's test step is at most 5 minutes on the
  workstation.
- [ ] M2. The full gate runs each check once and starts the remote work first, so local and
  remote work overlap. Measured before and after; its wall time is within 10% of its slowest
  single job.
- [ ] M3. The full gate does not lose a run to the builder: a gcloud preflight that makes a real
  API call, a keep-awake session for the length of the run, and one retry of a remote step after a
  transport failure. Each is shown working against an injected failure.
- [ ] M4. `just gate --deep auto --sweep` runs the deep tier (when `just recovery-changes` reports a
  recovery path) and the mutation sweep on the builder alongside the flake check, and records them.
  `just land` checks the recorded results.


## Surprises & Discoveries

- Observation (planning, 2026-10-10): the in-repo builder template
  (`scripts/nix-builder-startup.sh.tpl`) arms the idle watchdog with a 30-minute boot grace and a
  15-minute timer. The gate's own comment (`cli/nagare-harness/src/Nagare/Harness/Gate.hs`, in
  `runFullGate`) says the VM stops after about nine idle minutes. The running builder is configured
  in the operator's dotfiles (`nix-builder-x86`), so the effective timing must be read there or
  measured, not assumed.


## Decision Log

- Decision: Parallelise and shard the slow tests rather than moving any of them out of the fast
  tier.
  Rationale: ADR 25's 2026-10-07 amendment makes the fast tier, including the harness self-test,
  part of the release gate. Moving tests to the deep tier would weaken that gate.
  Date: 2026-10-10

- Decision: The full gate runs each distinct check once. The local `cabal` build and test steps
  are dropped from the full gate when the flake check's `aarch64-darwin` derivation runs the same
  suite, unless M2's measurement shows that running both at once is faster.
  Rationale: the darwin flake derivation runs the same tests on the same platform, built
  hermetically. Running both proves nothing extra.
  Date: 2026-10-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms used here:
- **Fast gate**: `just gate-fast`, which runs
  `nagare-harness gate --fast`. Its steps are `fastSteps` in
  `cli/nagare-harness/src/Nagare/Harness/Gate.hs`: the style check, the architecture and command
  audit, the registry-credential test, the mutation-record check, the `nagarectl` and `nagare-dsl`
  builds, the mutation-pattern check, and both suites. They run serially and stop at the first
  failure. The pre-push hook (`.githooks/pre-push`) runs it unless every pushed commit has a green
  full-gate record.
- **Full gate**: `just gate`, which runs `nagare-harness gate --full` (`runFullGate` in the same
  module). It requires a clean tree, probes each remote system's builder with a salted trivial
  derivation (`probeStep`), runs the fast gate's steps, then `nix flake check --all-systems
  --print-build-logs` (`flakeCheckStep`), then proves every check attribute of each system realised
  (`realise`), and writes a JSON record under `$XDG_STATE_HOME/nagare/gates/<commit>.json`
  (`cli/nagare-harness/src/Nagare/Harness/Record.hs`). `just gate-verify REV` checks that record,
  or a record carried forward over inert documentation (`Nagare.Harness.CarryForward`).
- **Remote builder**: the GCE VM `nix-builder-x86`, reached over IAP by
  `scripts/nix-builder-proxy.sh`, which starts the VM when it is stopped (for a build, not for a
  read-only observation). Its idle watchdog (`idle-shutdown.sh` in
  `scripts/nix-builder-startup.sh.tpl`) stops the VM when no SSH session on port 22 is established,
  no `nix-store --serve` runs, and the nix-daemon has no build children.
- **Deep tier**: `just gate-deep REV`, which runs the recovery model's `/deep tier/` test pattern as
  16 shards on the builder through `just test-remote` and `nix/test-runs.nix`. Each shard sets
  `NAGARE_RECOVERY_MODEL_SHARD=i/n` (parsed in `cli/nagarectl/test/Nagare/Test/Model/Tier.hs`).
  `just recovery-changes BASE` lists changed recovery-related paths.
- **Mutation sweep**: `just mutation-sweep REV`, which proves on the builder that every record in
  `cli/nagarectl/test/mutations/records.json` still fails its tests.
- **`just land REV`**: verifies the gate record and pushes `REV` to `origin/master`. It is the only
  path to `origin/master`.

The test suite's entry point is `cli/nagarectl/test/Spec.hs`, which calls `main` in
`cli/nagarectl/test/Nagare/Test/Suite.hs`. That `main` first handles several probe modes selected
by environment variables (collection resume, effectful resume, inventory lock hold), in which the
test binary re-executes itself as a child process; the tree runs under `localOption (NumThreads 1)`.
The test component is built `-threaded` (common stanza of `cli/nagarectl/nagarectl.cabal`) but has
no `-with-rtsopts=-N`, so even without the `NumThreads 1` option it would use one capability.

Test modules that change process-global state (environment variables or the working directory),
found by searching for `setEnv`, `unsetEnv`, `setCurrentDirectory` and `withCurrentDirectory` under
`cli/nagarectl/test/`: `AppDeploySpec.hs`, `HostSpec.hs`, `InventoryMigrationSpec.hs`,
`InventoryPostgresRenameSpec.hs`, `InventoryRenameCommandSpec.hs`, `InventorySpec.hs`,
`PlatformSpec.hs`, and the helpers `Nagare/Test/Context.hs`, `Nagare/Test/Init.hs` and
`Nagare/Test/Support/Environment.hs`. Any test that calls those helpers counts too. Tests that run
external processes or write fixed paths may also conflict and must be found by running the
parallel suite repeatedly (M1).

Relevant ADRs:
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): what
  each gate must prove. Every commit and release runs the fast tier, including the harness
  self-test, and the release gate needs a green full-gate record and a zero-survivor mutation
  sweep. The deep tier runs per release as monitoring, and a recovery-related change needs a deep
  run and a triage record. The 2026-10-09 amendment lets documentation-only commits carry a record
  forward. This plan changes how fast the gates run, not what they prove.
- [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md):
  harness code is Haskell under the production standard.

Plans this builds on, all complete: `docs/plans/174-gate-every-commit-before-any-native-run.md`
(the gates and records), `docs/plans/178-make-the-flake-check-build-each-haskell-package-once.md`
(one flake build per package), `docs/plans/179-bring-the-recovery-model-deep-tier-within-an-hour.md`
(deep-tier sharding).


## Plan of Work

**Milestone 1: a parallel suite.** Measure first: run the suite with tasty's per-test timings and
record the ten slowest tests and the total in this plan. Then:
1. Collect every test that changes process-global state, or calls a helper that does, into one
   top-level group that runs sequentially (tasty's `sequentialTestGroup` with `AllFinish`, or
   `localOption (NumThreads 1)` on that group alone). Keep the probe modes in `main` unchanged.
2. Remove the tree-wide `NumThreads 1` and add `-with-rtsopts=-N` to the `nagarectl-test`
   component (not to the library or the CLI).
3. Split each test in the table above into shards that tasty can schedule on separate cores. The
   recovery model already shards its deep tier by `i/n` (`Nagare.Test.Model.Tier`); give the fast
   tier, the harness self-test, the snapshot check and the rename model the same pure shard
   selection, as several `testCase`s per test, each running one shard. The prune-interruption
   sweeps in `Nagare.Database.Backup` tests can be split by interruption point the same way.
   Each shard must report its run count, and a test checks that the shards' counts add up to the
   unsharded count. That proves the split covers exactly the same runs.
4. Every mutation record whose test pattern names a split test is updated to the new names and
   proved with its exact pattern (`cli/nagarectl/test/mutations/records.json`).
5. Run the parallel suite ten times in a row. Any failure that does not reproduce serially is a
   shared-state conflict; move that test into the sequential group, and record it under Surprises.

**Milestone 2: each check once, local and remote at the same time.** Measure the current full
gate step by step from its log first. Then restructure `runFullGate`:
1. Run the seconds-long static checks and the builder probe first, as today.
2. Start `nix flake check --all-systems` right after them, so the remote `x86_64-linux` builds
   start at minute one.
3. Drop the `cabal` build and test steps from the full gate, because the `aarch64-darwin` flake
   derivation runs the same suite. The mutation-pattern check needs a built test binary; point it
   at the flake-built `nagarectl` test binary, or keep only the `cabal build` and run it
   alongside the flake check. Choose by measurement, and record the choice in the Decision Log.
4. Keep the realisation proof and the record format. Add each step's start and end time to the
   record so the overlap is visible.
The fast gate is unchanged in this milestone: it is the pre-push check and has no remote work.

**Milestone 3: no lost runs.** In `runFullGate`, before anything else:
1. **gcloud preflight.** When a remote system is required, run a real read through the builder's
   gcloud configuration (`gcloud compute instances describe` of the builder with the configured
   project and zone). Do not use `gcloud auth print-access-token`, which passed on a cached token
   on 2026-10-10 while every API call failed. On failure, refuse within seconds and print the exact
   login command for that configuration.
2. **Keep awake.** Hold one SSH session to the builder, through the same proxy, open for the whole
   run and close it at the end, including on failure or interruption (`bracket`). The watchdog
   counts established port-22 sessions, so the VM cannot be stopped mid-gate.
3. **One retry for transport failures.** When a remote step fails and its log matches a
   transport-failure signature (an SSH connection closed or reset, "server not responding", or a
   `platform mismatch` for a system that has a configured builder), re-probe the builder,
   restarting it through the proxy if it is stopped, and rerun that step once. The Nix store
   keeps what already built, so the retry costs only what was missing. Record the retry and its
   reason in the gate record. A second failure fails the gate. Any failure that matches no
   signature fails the gate at once, exactly as today.
Each part gets a test in `cli/nagare-harness` with a recording fake for the processes it runs:
a refused preflight, a keep-awake session that is closed on an exception, a retried transport
failure, and an unretried test failure.

**Milestone 4: one landing command.** Add `--deep auto|always|never` and `--sweep` to
`nagare-harness gate --full`, and pass them through `just gate`. With `--deep auto`, the gate runs
`just recovery-changes` against `origin/master` and runs the deep tier when it reports a path. The
deep tier and the sweep start on the builder at the same time as the flake check. Their results
(pass or fail, shard logs, the sweep's survivor count) go into the gate record. `just land` refuses
a revision whose record lacks a deep-tier result when `recovery-changes` reports a path, or lacks a
zero-survivor sweep. The standalone `just gate-deep` and `just mutation-sweep` recipes stay for
ad-hoc use. If running these alongside the flake check makes the full gate slower than running them
afterwards (they share the builder's 16 cores), run them after the flake check inside the same
command and record that measurement.


## Concrete Steps

Measure the suite before M1 (from `cli/nagarectl`):

```bash
cabal test nagarectl-test --test-show-details=direct 2>&1 | tee /tmp/suite-before.log
grep -E 'OK \(([0-9]{2,}|[5-9])\.[0-9]+s\)' /tmp/suite-before.log
```

Expected before M1: `All 1455 tests passed (1168.71s)` or similar, with the seven tests in the
table above as the only ones over five seconds.

After M1, the same command, then ten repeats:

```bash
for i in $(seq 1 10); do cabal test nagarectl-test || break; done
```

Measure the full gate before and after M2 (from the repository root, clean tree):

```bash
just gate
cat "${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/$(git rev-parse HEAD).json"
```

M3's injected failures, with the builder configured:
- revoke gcloud credentials for the builder configuration (or point it at a configuration with
  none) and run `just gate`: it refuses within a minute and prints the login command;
- stop the builder VM while the flake check runs: the gate re-probes, the proxy restarts the VM,
  and the record shows one retry.


## Validation and Acceptance

- **M1** is accepted when:
  - the suite's test count is unchanged apart from the split shards, and each split test's shards
    report run counts that add up to the unsharded count (a checked test);
  - ten consecutive parallel runs pass;
  - every mutation record still kills its mutant with its exact pattern, and
    `just mutation-sweep` has zero survivors;
  - `cabal test nagarectl-test` takes at most 5 minutes on the operator's workstation, with the
    before and after times recorded here.
- **M2** is accepted when a green full gate's record shows the flake check starting within two
  minutes of the gate's start and no duplicate run of the suite on the local system, and the gate's
  wall time is within 10% of its slowest single step. Record the before and after wall times.
- **M3** is accepted when the harness tests pass for all four cases and the two injected failures
  above behave as described, with the gate logs kept in this plan's Outcomes.
- **M4** is accepted when one `just gate --deep auto --sweep` on a recovery-related change records
  a deep-tier result and a zero-survivor sweep, and `just land` refuses the same revision gated
  without them.

Required acceptance is the four milestones. Moving the local Haskell build to the remote builder
or adding a second builder is out of scope.


## Idempotence and Recovery

All changes are to test code and the gate harness, and every step can be repeated. A gate run that
fails or is interrupted leaves its logs and, when it got that far, a red record; rerunning
`just gate` on the same commit replaces the record. The keep-awake session is closed by `bracket`
on every exit path. If it ever leaks, the watchdog only stops the VM later than usual, and the
session can be ended by its exact PID. If the parallel suite shows a flaky conflict after landing,
the sequential group is the fix, and putting back the tree-wide `NumThreads 1` is the safe
fallback.


## Interfaces and Dependencies

- `cli/nagare-harness/src/Nagare/Harness/Gate.hs`: `runFullGate`, `fastSteps`, `flakeCheckStep`,
  `probeStep`. M2 and M3 change the step sequencing; `Nagare.Harness.Step` gains a way to run steps
  concurrently and to retry one.
- `cli/nagare-harness/src/Nagare/Harness/Record.hs`: the gate record gains step timings, retries,
  and (M4) deep-tier and sweep results. `Nagare.Harness.Verify` and `just land` read them. Older
  records without the new fields stay valid for `gate verify`, since they gate past commits.
- `cli/nagarectl/test/Nagare/Test/Suite.hs` and `cli/nagarectl/nagarectl.cabal`: the parallel tree
  and `-with-rtsopts=-N`.
- `cli/nagarectl/test/Nagare/Test/Model/Tier.hs`: the pure shard selection that M1 reuses for the
  fast tier.
- `cli/nagarectl/test/mutations/records.json`: patterns of records whose test names change.
- Library: `tasty` (`sequentialTestGroup`, `NumThreads`, `DependencyType`); check the version in
  the build plan supports `sequentialTestGroup` (tasty 1.5 or later), using `mori` to read its
  source.

This plan has no hard dependency on another child of MasterPlan 26. It touches the recovery-model
test files that EP-173 (`docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md`)
also changes, so whoever lands second rebases. It should go first among the remaining lane A work,
because it shortens every other plan's gates.
