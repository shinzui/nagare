---
id: 200
slug: make-gate-runs-immune-to-concurrent-sessions-and-stop-rebuilding-from-scratch
title: "Make gate runs immune to concurrent sessions and stop rebuilding from scratch"
kind: exec-plan
created_at: 2026-10-17T14:29:57Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-17T14:29:57Z
---

# Make gate runs immune to concurrent sessions and stop rebuilding from scratch

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence;
Decision Log holds dated decisions that change scope or design (CLAUDE.md, "Plans, evidence and
gates").


## Purpose / Big Picture

The operator, 2026-10-17: "everything is painful the gate the fast-gate … if another session is
working you can accidently break a gate run and it has to start over. It's really really bad",
and "this has been an ongoing struggle that cost me a month so far".

After this plan:

1. A gate run (`just gate-fast`, `just gate`, the post-land gate) builds and tests a **commit** in
   a worktree only the gate uses. Another session editing files, running `cabal build`, or
   committing in the shared checkout cannot turn a gate red or cost it its record.
2. Those gate worktrees are kept between runs, so each run compiles only what changed since the
   slot's previous run, instead of compiling `nagarectl` (413 modules) from nothing.
3. The post-land full gate does not repeat the work the landed commit's fast record already
   proved for the same tree. It runs the builder probe, the flake check and the realisation
   proof, and nothing local beyond that.
4. A local auth-plane image (`nagare-admin-api`, `nagare-access`, `shomei`, `en`) for a colima
   drill recompiles only the changed modules.

This plan changes no record format and no landing rule. `just land`, `gate verify`,
`gate landable`, carry-forward over inert documentation, and "a red post-land gate blocks the next
land" behave exactly as today.


## Progress

- [x] M1. Every gate run happens in a gate slot. `just gate-fast [REV]`, `just gate [REV]` and
  `just gate-post-land REV` check out the commit in a free slot (a kept, detached worktree under
  `${XDG_STATE_HOME:-~/.local/state}/nagare/gates/gate-slots/<n>/tree`, two slots) and run every
  step there. Harness sub-steps run the gate's own harness binary, and the `just` recipes get the
  harness from `nix build`, so no gate step runs `cabal` in the shared checkout. Pass when:
  (a) the interference drill (Validation) ends green with a fast record for the gated commit;
  (b) two concurrent `just gate-fast` runs on two commits both write green records, and a third
  waits for a slot; (c) a second `gate-fast` in a warm slot, one `nagarectl` module changed, has
  `nagarectl-build` at most 120 s (today's cold build in a fresh worktree is 500–630 s);
  (d) `just gate-post-land` of a docs-only commit over a running slot gate still reports
  "covered".
  - [x] (a) 2026-10-17, `8ab97b56`: `just gate-fast 332e7b09` took slot 1 (cold) and, while it
    compiled, the checkout it was started from had a tracked file edited, a `cabal build` of
    `nagare-dsl-test` and a commit made and reset. Green, fast record
    `gates/fast/332e7b0921fa4dc003e74e540876471e8b2afd8e.json`; `nagarectl-build` 568 s cold,
    wall 1,044 s.
  - [x] (c) 2026-10-17: probe commit `ecf83891` (one comment line in
    `cli/nagarectl/src/Nagare/Inventory/Components/AdminApi.hs`) in the warm slot 1:
    `nagarectl-build` 12.5 s, `nagare-dsl-build` 1.9 s, wall 309 s, of which `nagarectl-test`
    233 s. A change to an exported definition also recompiles its importers.
  - [x] (b) 2026-10-17: three `just gate-fast` runs on unlanded probe commits started within
    23 s. `7f7a1a7a` took slot 1 and `946275a6` slot 2, both green (`nagarectl-test` 350 s and
    339 s side by side); `015e9a79` printed "all 2 gate slots are busy; waiting" until slot 1
    was freed, then ran there green (`nagarectl-build` 8.4 s, `nagarectl-test` 187 s).
  - [x] (d) 2026-10-17: `262ac836` (this plan only) landed while the post-land full gate of
    `0ed88c6b` ran in slot 1; its post-land printed "covered by the full gate of 0ed88c6b … over
    1 inert paths; no full gate needed", and the `0ed88c6b` record ended green (wall 200 s).
- [x] M2. The full gate uses the fast record of the same tree. When the gated tree has a green
  fast record, the full gate skips its static and suite-build steps and copies that record's step
  results into the full record; with no fast record it runs them as today. Pass when: a post-land
  full gate of a `nagarectl` change has no local `nagarectl-build` step, its `gate: wall` is at
  most the flake check plus 90 s, `just gate-verify` accepts its record, and harness tests cover
  both branches.
  - [x] 2026-10-17, `fa3205be` and `0ed88c6b` (which also reuses a fast record carried forward
    over documentation commits): the post-land full gate of `5d0f1b16` (six `cli/nagarectl/`
    files) printed "the green fast record … covers this tree's static checks and suite builds",
    ran no local step, and was green with `nix-flake-check` 862.4 s and `gate: wall` 873 s;
    `just gate-verify 5d0f1b16` accepts it. Test: `FlakeCheckSpec` "a green fast record of the
    same tree stands in …" covers reuse and the four no-reuse cases.
- [x] M3. Local auth-plane image builds are incremental. In local mode
  `cluster/bootstrap/auth-images/build-local-image.sh` keeps each service's cabal build directory
  in a BuildKit cache mount, and builds with `--jobs=4`. Pass when: after a one-module change to
  `cli/nagarectl`, a second `nagare-admin-api` build on `nagare-mp23` is timed against the first,
  both times recorded here, and the new image passes `scripts/admin-api-drill.sh`.
  - [x] 2026-10-17, source `5bbc12f2`, arm64 on `nagare-mp23`: the first build, with an empty
    cache mount, compiled 400 modules in about 332 s, then failed to copy the binary because
    `cabal list-bin --builddir` also prints the source checkouts' "HEAD is now at" lines; `d70a12db`
    keeps its last line. With that fix, an unchanged rebuild took 27 s, and after a one-line change
    to `cli/nagarectl/src/Nagare/Inventory/Components/AdminApi.hs` the rebuild compiled one module
    and relinked in 28 s. That image (`nagare-admin-api@sha256:3de28047…`) passed
    `scripts/admin-api-drill.sh` on a fresh bootstrap (`NAGARE_DRILL_ADMIN_API=1`, packaged
    `nagarectl` of `5bbc12f2`; record `~/.local/state/nagare-drills/ep200-m3-20261017/evidence/admin-api-drill.json`).
- [x] M4. Only with the operator's yes (Decision Log, 2026-10-17): the flake check stops running
  the `nagarectl` suite on `aarch64-darwin`, which the fast gate ran on the same tree on the same
  system; `x86_64-linux` keeps its hermetic run. First measure the darwin suite's share of a
  post-land flake check from its log; pass when a full gate with this change is green, and its
  flake check time is recorded next to M2's.
  - [x] 2026-10-18, `36ea3e5c`: the darwin derivation skips its check phase. The flake log has no
    timestamps and interleaves both systems' suites, so the share was measured as the change
    itself. The post-land full gate was green (x86_64-linux 37/37, aarch64-darwin 38/38), with
    `nix-flake-check` 544.7 s and `gate: wall` 598 s, against M2's 862.4 s and 873 s; both
    rebuilt `nagarectl` on both systems.


## Surprises & Discoveries


## Decision Log

- 2026-10-17. Gates run on commits, never on the working tree. `just gate-fast` with uncommitted
  changes gates HEAD and says that the changes were not included. Today a dirty-tree fast gate
  writes no record anyway: 92 of the 260 gate runs from 2026-10-10 to 2026-10-17 left no record,
  41 of them complete fast gates. To check uncommitted work, run `cabal test` in your own
  checkout, or commit and gate.
- 2026-10-17. Two slots shared by every kind of gate, not one per session. Both suites run one
  process per core (EP-184), so a third concurrent gate only slows the other two. The cap of two
  replaces `gate-post-land`'s own two `gates/slots/<n>` locks. A gate that finds both slots busy
  waits and says so. Each slot holds about 7.7 GB of build output (today `cli/nagarectl`
  6.3 GB, `cli/nagare-dsl` 1.1 GB, `cli/nagare-harness` 0.3 GB), and the workstation disk is 97%
  full (140 GB free on 2026-10-17).
- 2026-10-17. The full gate trusts the fast record of the exact same tree. Landing already
  requires that record, so for a landed commit the post-land gate's local static checks, suite
  builds and record-pattern check ran on identical input and only repeat it. It is the
  `nagarectl-build` step, cold in a fresh worktree (500–630 s), that competes with the flake
  check and with the operator's sessions for the same cores.
- 2026-10-17. M4 waits for the operator. Dropping the darwin hermetic suite run changes what a
  green full gate proves; the operator owns the gate rules (decisions of 2026-10-10 and
  2026-10-11). Evidence so far: in the last 60 full records, `checks.aarch64-darwin.nagarectl-build-test`
  never failed without `checks.x86_64-linux.nagarectl-build-test` failing too (1a34de4d failed
  both on a test payload file missing from Nix; f8b1f408 failed on x86_64-linux only). The gap
  M4 would open: `cli/nagarectl/cabal.project` pins no `index-state` and has no freeze file, so
  the fast gate tests against Hackage-resolved versions, and the shipped darwin `nagarectl`
  (nixpkgs versions) would no longer be tested as built on darwin. The saving is unmeasured. If
  the x86_64-linux chain is the flake check's longest, M4 saves local CPU but no wall time.
  Decide after M2's numbers.
- 2026-10-18. The operator approved M4: the darwin hermetic `nagarectl` suite run is dropped.
- 2026-10-17. Not in this plan: EP-184's declined M3 (builder keep-awake) and M4 (deep tier and
  sweep in the gate) stay declined; the builder's lost runs are handled by the probe and retry
  that EP-184 landed.


## Outcomes & Retrospective


## Context and Orientation

**Where the time and the breakage come from (measured 2026-10-17 from the gate records in
`~/.local/state/nagare/gates/`).**

- Fast records: 4.5–7.5 minutes each, almost all in `nagarectl-test` (200–375 s).
- Full records: `nagarectl-build` 500–630 s and `nix-flake-check` 190–1,860 s. The full gate runs
  them at the same time (EP-184 M2), so its wall time is roughly the longer of the two. The long
  flake checks were the ones that competed with other gates and sessions for the workstation's
  10 cores.
- 260 gate runs from 2026-10-10 to 2026-10-17 (one log directory each, under `gates/logs/`): 143
  green records, 25 red records, 92 with no record (one of them still running). 18 of the 92
  ended inside the flake check, 8 of those with "interrupted by the user".

**Why another session can break a gate run.** `just gate-fast` runs
`cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- gate --fast` in the shared
checkout `/Users/shinzui/Keikaku/bokuno/nagare`, and every step runs there too
(`Nagare.Harness.Gate.fastSteps` in `cli/nagare-harness/src/Nagare/Harness/Gate.hs`; each `Step`'s
directory is relative to the repository root). The parallel sessions work in that same checkout
on `master`. Three things follow:

1. `runFastGate` writes a record only when `git status --porcelain --untracked-files=no` is empty
   before and after the run. Another session's edit to any tracked file during the run loses the
   record, and the run must be repeated.
2. The suites build into the shared `cli/nagarectl/dist-newstyle`. The comment on `fastSteps`
   says the config-loader tests "also fail during a concurrent cabal rebuild". So another
   session's `cabal build` turns a gate red.
3. The gate's sub-steps `mutations check` and `mutations patterns` run `cabal run` on the
   harness in the shared checkout (`harness` in `Gate.hs`). A harness source change committed in
   the shared checkout mid-run rebuilds the harness under the running gate.

`just gate-post-land` (in `justfile`) already avoids 1 and 2 by running in a throwaway worktree,
`gates/worktrees/<rev>`. But it creates a new worktree each time, so its `nagarectl-build` starts
cold, which is the 500–630 s above. `coveredRevision` in `Gate.hs` treats the existence of
`gates/worktrees/<rev>` as "a full gate of that revision is running".

**Records and rules that must not change.** Full records are `gates/<commit>.json` and fast
records are `gates/fast/<commit>.json` (`cli/nagare-harness/src/Nagare/Harness/Record.hs`).
`verifyRecord` in `cli/nagare-harness/src/Nagare/Harness/Verify.hs` checks commit, tree, green,
clean, builder probe and per-system realisation. It does not look at step names, so M2 needs no
change there. `.githooks/pre-push` accepts a push of landable commits and otherwise runs
`just gate-fast`.

**Local image builds.** `cluster/bootstrap/auth-images/build-local-image.sh` copies the working
tree into a temporary build context, writes a `cabal.project` for the service, and runs
`docker build` with `cluster/bootstrap/auth-images/Dockerfile.local-haskell`. That Dockerfile
cache-mounts only the cabal store (`/root/.cache/cabal`, `/root/.local/state/cabal`). The
project's own packages build into `dist-newstyle` inside the build layer, which every change
throws away, and `CABAL_BUILD_FLAGS` defaults to `--jobs=1`. That default dates from the first
builder (2026-06-24, `b0228020`), when the build VMs were small; `nagare-mp23` now has 6 CPUs and
12 GiB. Nix is not the fix for this loop. It caches whole packages, so a one-module change still
rebuilds all of `nagarectl`. The shipped derivations also run their test suites
(`nix/haskell-packages.nix`), and the workstation has no aarch64-linux builder for the `linux/arm64`
images colima runs.

**ADRs.** [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md):
the harness follows the production Haskell standard (package Prelude, strict fields, generic-lens
labels; `just haskell-style-check`).
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) is
unaffected. No ADR covers gate isolation; this plan does not need one.

**Terms.** A *gate slot* is a directory the harness locks for one gate run: `lock/` (created with
`mkdir`, holding `pid` and `revision`) and `tree/`, a detached git worktree that is kept and
reused, with its `dist-newstyle` directories. The *interference drill* is the M1 acceptance run in
Validation.


## Plan of Work

**Ground rules for this plan's own work: don't break running gates.**

- Implement in a dedicated worktree, never in the shared checkout:
  `git worktree add --detach ../nagare-ep200 origin/master`. Commit there and land with
  `just land <rev>`, which pushes from any checkout. Never run `cabal` or `nix build` in the shared
  checkout.
- Never touch `gates/worktrees/*`, `gates/slots/*`, records or logs of a run you did not start,
  and never stop a process you did not start (kill only captured PIDs).
- Land M1 only when no gate is running: `gates/worktrees/` and `gates/slots/` are empty, and
  `ps -o pid,command -ax` shows no `nagare-harness … gate`. If one is running, wait for it. Its
  record is still valid afterwards, because the record format does not change.
- Each commit passes `just haskell-style-check` and `just gate-fast` under the flow it replaces;
  after M1 lands, landing exercises the new flow.

**M1, gate slots** (`cli/nagare-harness/src/Nagare/Harness/Gate.hs`, a new
`cli/nagare-harness/src/Nagare/Harness/Slot.hs`, `cli/nagare-harness/app/Main.hs`, `justfile`,
`.githooks/pre-push`, `nix/haskell-packages.nix`, `nix/packages.nix`).

1. `Nagare.Harness.Slot`: `withSlot :: Text -> (FilePath -> IO a) -> IO a`. It takes the first
   free slot of `gate-slots/1` and `gate-slots/2`: a `mkdir` of `lock/`, a stale lock (dead pid)
   is cleared, and with no free slot it prints a waiting line every 60 s. It then runs
   `git worktree add --detach tree <rev>` the first time, or `git -C tree checkout --detach --force
   <rev>` and `git -C tree clean -ffdx -e dist-newstyle -e '.ghc.environment.*'` on reuse. It
   calls the action with the tree path and removes `lock/` on exit, including on exceptions.
2. `gate --fast` and `gate --full` take `--revision REV` (default `HEAD`), resolve it to a commit
   in the shared checkout, and run inside `withSlot`. `runFastGate`'s before/after tracked-change
   check stays, now against the slot tree. With uncommitted changes in the shared checkout, print
   one line saying HEAD is gated without them.
3. `harness` steps run `getExecutablePath` instead of `cabal run --project-dir=cli/nagare-harness`.
4. `nix/haskell-packages.nix` gains an unchecked `nagare-harness` (tests stay in the existing
   `nagare-harness-build-test` check), exposed as `packages.nagare-harness` in `nix/packages.nix`.
   The `gate-fast`, `gate`, `gate-verify`, `gate-landable` recipes run
   `"$(nix build --no-link --print-out-paths .#nagare-harness)"/bin/nagare-harness`. The Nix
   store is safe under concurrent builds; the shared `cli/nagare-harness/dist-newstyle` is not.
5. `gate-post-land REV` becomes `nagare-harness gate post-land --revision REV`, which runs
   `covered` and then the full gate in a slot. Delete the recipe's worktree and `gates/slots`
   shell code. `coveredRevision` reads "running" from the slot locks' `revision` files instead of
   from `gates/worktrees/<rev>`.
6. `.githooks/pre-push` runs `just gate-fast "$local_sha"` for each pushed commit that is not
   landable, instead of gating the working tree.
7. Register any changed recipes in the managed-command audit
   (`scripts/test-managed-command-audit.sh` fails until they are).

**M2, the full gate reuses the fast record** (`Gate.hs`). In `runFullGate`, after the probes,
`readFastRecord commitId`. If the record is green and its tree equals the commit's tree, run
`fullCheckPlan` with `static = []` and `suite = []`, and put the fast record's `steps` into the
full record's `steps` (their `logPath`s still point at the fast run's logs). Otherwise run
today's plan. Add harness tests (`cli/nagare-harness/test/Spec.hs`) for both branches with a stub
check plan, in the style of `FlakeCheckSpec`.

**M3, incremental local images** (`cluster/bootstrap/auth-images/Dockerfile.local-haskell`,
`build-local-image.sh`). Add `--mount=type=cache,target=/cache/dist,sharing=locked` to the build
`RUN` and pass `--builddir=/cache/dist/<service>` to both `cabal build` and `cabal list-bin`
(through a new `CABAL_BUILDDIR` build arg, so the cloud-build and k3s-import paths keep their
current behaviour when it is empty). In local mode default `CABAL_BUILD_FLAGS` to `--jobs=4`. GHC
decides what to recompile by source hash, so the fresh copy of the tree on each run does not
force a full rebuild. Do not run M3's timings while another session's drill uses `nagare-mp23`
(`docker ps` on that daemon shows its k3d containers).

**M4, operator decision first.** Read the newest post-land `nix-flake-check.log` and find when
`checks.aarch64-darwin` `nagarectl` started and finished testing. Report the share to the
operator with M2's numbers. Only on a yes, make the darwin `nagarectl` derivation in
`nix/haskell-packages.nix` skip its check phase (`hl.dontCheck` on `aarch64-darwin` only), and
keep the `x86_64-linux` run.


## Concrete Steps

From the EP-200 worktree (`../nagare-ep200`):

```bash
cabal build --project-dir=cli/nagare-harness nagare-harness nagare-harness-test
cabal test --project-dir=cli/nagare-harness nagare-harness-test
just haskell-style-check
nix build --no-link --print-out-paths .#nagare-harness
just gate-fast            # runs in gate-slots/<n>/tree, prints the slot it took
```

Expected new output lines from `just gate-fast`:

```text
gate: slot 1, revision <40-hex commit>, worktree ~/.local/state/nagare/gates/gate-slots/1/tree
gate: fast gate green
gate: fast record ~/.local/state/nagare/gates/fast/<commit>.json (green)
```


## Validation and Acceptance

**Interference drill (M1 a).** In the shared checkout, start `just gate-fast` on a commit C.
While `nagarectl-build` or `nagarectl-test` runs, from a second shell in the shared checkout:
edit a tracked file (do not commit it), run `cabal build nagarectl-test` in `cli/nagarectl`, then
revert the edit. Pass: the gate prints `fast gate green` and writes `gates/fast/C.json`, green, for
C's tree. Record the gate's log directory here.

**Concurrency (M1 b).** Two shells, `just gate-fast A` and `just gate-fast B` for two commits
started together, then a third `just gate-fast` that prints the waiting line until one finishes.
Pass: green records for A and B.

**Incremental (M1 c, M2).** Record `nagarectl-build` seconds from the second run's fast record,
and `gate: wall` and `nix-flake-check` seconds from the next post-land gate's log.

**Docs-only coverage (M1 d).** Land a docs-only commit while the previous commit's post-land gate
runs in a slot. Pass: its post-land log says `covered by the full gate of <prev>`.


## Idempotence and Recovery

A slot's `tree/` is disposable. If a slot misbehaves, delete it (`git worktree remove --force
<slot>/tree`, then `rm -rf <slot>`) only after its `lock/pid` is dead; the next run recreates it
cold. Reverting M1 is one revert commit: records written by slot gates verify under the old
harness, because the record format does not change.


## Interfaces and Dependencies

- `nagare-harness gate fast|full [--revision REV]`, `gate post-land --revision REV` (new);
  `gate verify`, `gate landable`, `gate covered` unchanged.
- `Nagare.Harness.Slot.withSlot :: Text -> (FilePath -> IO a) -> IO a`.
- Flake output `packages.<system>.nagare-harness` (new, unchecked).
- Dockerfile build arg `CABAL_BUILDDIR` (new, optional).
