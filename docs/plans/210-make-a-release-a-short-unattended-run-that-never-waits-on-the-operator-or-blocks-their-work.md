---
id: 210
slug: make-a-release-a-short-unattended-run-that-never-waits-on-the-operator-or-blocks-their-work
title: "Make a release a short unattended run that never waits on the operator or blocks their work"
kind: exec-plan
created_at: 2026-10-20T19:28:04Z
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-20T19:28:04Z
---

# Make a release a short unattended run that never waits on the operator or blocks their work

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It follows the operator's statement of 2026-10-20: releases are still too painful,
they take too long, and they have expensive mistakes.


## Purpose / Big Picture

A release today is a machine path of about an hour wrapped in hours of waiting and hand work, and
it holds every shared resource (both gate slots, the builder, the workstation, both checkouts)
while it runs, so the operator cannot work beside it. After this plan a release is: land the
version bump, run `just release-candidate X.Y.Z`, run `just release-publish X.Y.Z`. The candidate
run proves the three things a release proves (full gate, upgrade rehearsal, the intranet upgraded
on the candidate) and moves nothing else; it runs in its own worktrees and gate slot; nothing in
it waits for the operator; the operator's passkey login confirms the release afterwards. The
operator keeps landing and testing while it runs.

### Audit, 2026-10-20

Elapsed time from the `chore(release): prepare` commit to the GitHub publication, from the
commit's author date and the release's `publishedAt`:

| Release | Elapsed | Where the time went |
| --- | --- | --- |
| v0.6.0 | 1:04 | |
| v0.6.1 | 0:52 | |
| v0.6.2 | 3:27 | first candidate run failed on the Colima x86 cache probe |
| v0.6.3 | 1:14 | |
| v0.6.4 | 2:31 | three aborted candidate runs before the fourth passed |
| v0.6.5 | 1:02 | published, then failed on the intranet (F128) |
| v0.6.6 | 0:56 | |
| v0.7.0 | 5:17 | candidate ready 02:48, intranet upgraded 06:45 |
| v0.7.1 | 2:01 | |
| v0.8.0 | 8:06 | candidate ready 23:43, intranet upgraded 06:30 |

The v0.8.0 machine path, from the gate records and the run directory under
`~/.local/state/nagare/releases/v0.8.0/`:

| Step | Measured | Cause |
| --- | --- | --- |
| fast gate on the prepare commit `6a03edc8` | 938 s | `cabal build nagarectl-test` 545 s from scratch; a normal commit builds in 4 to 80 s |
| fast gate on the notes fix `a6004f22` | 913 s | the other gate slot rebuilt from scratch too |
| full gate on the candidate | 705 s | |
| `just release-candidate` | 29 min | the mutation sweep (189 records, 5,003 record-seconds on 4 workers) is the critical path; rehearsal 8 min, darwin attachments 1 min, x86 container 4 min, assembly under 1 min |
| intranet transition, by hand | about 15 min | host stage, 210 verifies and the stamp, empty plan, commit |
| `just release-publish` | 2 min | |

The same bump cost on v0.7.0 (`cf14893a`, 499 s build), v0.7.1 (`fe162dbf`, 525 s) and v0.9.0
(`e6314c40`, 549 s), and again on the first commit gated in the other slot after each bump
(`9d389cba` 548 s, `bc548f6e` 523 s). Every bump buys three or four from-scratch rebuilds.

Recorded mistakes, each costing a gate cycle, a run, a version or hours:

1. v0.6.4 and v0.6.5 were published and then failed on the intranet (F125, F128, F129, F130):
   two burned versions and 29 hours (EP-201's purpose). EP-201 has no milestone ticked; since
   v0.7.0 the order is followed by hand and `release-publish` does not check it.
2. On 2026-10-17 three candidate runs died before the fourth passed: two refused by
   `gate-verify` (no full gate record on `477e4642` and `5d0f1b16`), one sweep killed by hand.
3. v0.6.1 shipped without Helm (F123), found on the intranet, worked around in the operator
   repository; v0.6.2 followed.
4. v0.7.1's rehearsal ran before the bump existed and refused ("already runs this payload's
   release").
5. v0.8.0's notes needed one wording fix after the bump (`a6004f22`); because `docs/releases/`
   is a gate-read tree (`contentReadDocuments` in
   `cli/nagare-harness/src/Nagare/Harness/CarryForward.hs`), that fix cost a second from-scratch
   fast gate and a second full gate, 27 minutes. The same on v0.9.0: a one-sentence notes fix
   needed its own fast gate of about 8 minutes, and rebasing it to land discarded that record,
   since records are keyed by commit and a notes change is not inert. The operator, 2026-10-20:
   "ridiculous that a note change takes so much time".
6. v0.9.0, today: the hand-run app-database smoke (`scripts/local-app-database-smoke.sh`, 820
   lines, about 15 min) failed on a name left by an earlier run and ran again; the fix's gate went
   red on the 1,000-line module limit and was re-gated; the operator's documentation-only push was
   refused by the pre-push hook (`e1ec6dc1`). The release session edited the operator's own
   checkout of `mori://tan/tan-ng-labs` in place (uncommitted pin and `Databases.hs` edits at
   12:20 while the operator worked there), and for the third release running the operator's
   config needed an edit because new DSL record fields break literal records (`700f6ad`, today).
7. Ten of the twelve ledger findings between v0.6.0 and v0.6.6 (F121 to F130) are release or
   transition machinery found on the intranet.

Causes:

1. The version is hand-written in eight checked places (`release.json`, six Cabal files, the
   `PlatformSpec.hs` fixture) and in the changelog, the notes, the README and five user docs: 19
   files in `e6314c40`. `cli/nagarectl/src/Nagare/Version.hs` reads `Paths_nagarectl`, so the
   bump changes six package ids and every build tree recompiles from scratch.
2. The notes and the changelog are gate inputs and live in the candidate commit, so a wording
   fix is a new candidate.
3. The sweep runs at release time on the critical path although nothing in it needs the
   candidate.
4. The intranet transition is a hand-run sequence in the operator's checkout that waits for a
   go-ahead and for the passkey login before the tag.
5. A release holds every shared resource at once: both gate slots, the builder for 25 minutes,
   the workstation (Colima 6 CPU and 12 GiB, the Apple container 4 CPU and 16 GiB, cabal) and
   both checkouts. A land on master between the candidate's preflight and its evidence land makes
   its last step fail ("does not descend from origin/master").
6. Steps outside the three proofs crept back in: the native smoke, README and user-doc version
   edits, the capabilities log, and a 213-line skill that still says three Cabal packages and
   "monitor GitHub publication".


## Progress

Ordered by payoff per effort.

- [ ] M1. The release path is the three proofs and nothing else. `docs/runbooks/releases.md`,
  `agents/skills/nagare-release/SKILL.md` and the Validation paragraph of the notes name the
  full gate, the upgrade rehearsal and the intranet on the candidate; the native app-database
  smoke, README and user-doc version edits and the capabilities-log line leave the release
  path. Pass: the runbook's "Prepare a candidate" lists the files M2 leaves, and the skill fits
  on one screen.
- [ ] M2. The notes are not a gate input. One file per release, `docs/releases/vX.Y.Z.md`, is
  the notes and the changelog entry; `docs/releases/` and `CHANGELOG.md` leave the carry-forward
  read set; `check-release.sh` reads the notes file alone. Pass: a notes-only commit after the
  bump lands with its ancestor's record (no gate), and `just release-candidate X.Y.Z --revision
  <that commit>` accepts it.
- [ ] M3. `release.json` is the only place the version is written. The six Cabal `version:`
  fields stay constant, `Nagare.Version` reports the version read from `release.json` at build
  time, the `PlatformSpec.hs` fixture reads it, the Nix package names take it from
  `release.json`, and `check-release.sh` drops the Cabal-equality rule. Pass: the prepare
  commit touches `release.json` and the notes; its fast gate record shows `nagarectl-build`
  under 60 s; `nagarectl version --json` and `nix build .#nagarectl` report and name X.Y.Z.
- [ ] M4. A release never blocks the operator. `release-candidate.sh` fetches again before it
  creates the evidence commit, so a land during the run does not fail it; the run touches no
  checkout but its own worktrees; the operator repository receives commits by explicit path
  (M5) and never an app-config edit. Pass: during a candidate run, `just land` of an unrelated
  documentation commit succeeds and the run still lands its record.
- [ ] M5. The intranet step is part of the candidate run and the tag requires it (finishes
  EP-201). `scripts/release-intranet.sh VERSION` pins the operator repository to the candidate
  revision, runs the transition until a plan has no operations, commits it, checks an exact
  platform status, a converged inventory and a 302 from the protected URL, and writes
  `<run>/intranet.json`; `release-publish.sh` refuses without a record for the run's revision
  and, after the tag, pins the tag. Pass: the next release's run directory holds `intranet.json`
  dated before the tag; the operator repository shows exactly two pin commits from the release.


## Decision Log

- Decision: The tag does not wait for the operator's passkey login, and the login is no longer a
  release step. The intranet record (exact platform status, converged inventory, the protected
  URL answering 302 to the login page) gates the tag. This replaces EP-201's `--login-confirmed`
  flag. Decided by the operator, 2026-10-20.
  Rationale: the last two releases spent 7 h and 4 h between "candidate ready" and the tag
  waiting for the operator, with bits that could no longer change. The login has passed on every
  release since v0.6.1; every intranet defect since then was transition machinery (F121 to
  F130), and the record's redirect check covers the gateway and auth path.
  Date: 2026-10-20
- Decision: The intranet transition is a step of `just release-candidate` under a standing
  go-ahead; a release asks for nothing per release. Decided by the operator, 2026-10-20.
  Rationale: the operator pre-approved the same bounded sequence for every release since v0.6.0
  and said not to re-ask for a class of action once approved (2026-10-09).
  Date: 2026-10-20
- Decision: The version has one source, `release.json`; Cabal package versions no longer change
  per release, and `check-release.sh` no longer compares them.
  Rationale: a Cabal version bump changes six package ids and costs a from-scratch rebuild in
  every build tree, measured at 499 to 549 s per gate slot per release.
  Date: 2026-10-20
- Decision: Release notes are not gate inputs. One notes file per release is also the changelog
  entry; `CHANGELOG.md` keeps only links.
  Rationale: a wording fix after the bump cost 27 minutes of gates on v0.8.0; nothing a gate runs
  reads the notes.
  Date: 2026-10-20
- Decision: The mutation sweep stays per release, inside the candidate run, as the 2026-10-10
  rule says. Moving it after every landed code commit was proposed and dropped by the operator,
  2026-10-20: about 25 builder-minutes per land, eight such lands on 2026-10-20, contending with
  other remote runs, to save 15 minutes of a run that no longer waits on anyone. If those
  minutes ever matter, the harness's incremental proof (`mutations prove --base`, records whose
  mutated files changed in the range) is the cheap next step, with the caveat that a test change
  can break a record it does not select.
  Date: 2026-10-20
- Decision: The native app-database smoke is EP-202's proof, run when app-database code changes,
  not a release proof (ADR 25; the three-proof rule of 2026-10-10).
  Rationale: it ran twice today, 15 minutes each, and failed on leftover state, for a release
  whose code it had already proved.
  Date: 2026-10-20
- Decision: EP-201's M1 to M4 fold into M5 here; EP-201 is superseded.
  Rationale: one plan for the release path.
  Date: 2026-10-20


## Context and Orientation

Terms:

- **The three proofs** (operator, 2026-10-10): a release proves a green full gate, the EP-172
  upgrade rehearsal on a disposable local context reading its seeded row back unchanged, and the
  real intranet upgraded to the candidate with the deploy-and-login check passing. A release
  counts when the intranet runs it.
- **Candidate run:** `just release-candidate X.Y.Z` (`scripts/release-candidate.sh`): preflight,
  `just gate-release` in the background (gate record lookup, then the sweep unless an ancestor's
  clean sweep covers the range), `just release-rehearse` (`scripts/release-rehearse.sh` and
  `scripts/transition-rehearsal.sh` on Colima profile `nagare-mp23`), aarch64-darwin attachments
  from a worktree (`scripts/release-native.sh`), x86_64-linux attachments in an amd64 Apple
  container (`scripts/release-native-container.sh`), two byte-identical assemblies
  (`scripts/assemble-release.sh`), then the rehearsal record committed on `origin/master` and
  landed with `just land`. Runs live under `~/.local/state/nagare/releases/vX.Y.Z/<time>/`.
- **Publish:** `just release-publish X.Y.Z` (`scripts/release-publish.sh`): SSH-signed annotated
  tag on the run's revision, push of the tag only, `nagarectl release publish` from a checkout of
  the tag, public flake check.
- **Gate records and carry-forward:** `cli/nagare-harness` writes a fast or full record per
  commit under `~/.local/state/nagare/gates/`; a commit whose diff from its gated ancestor is
  inert documentation inherits that record (`Nagare.Harness.CarryForward`). The read set that
  defeats carry-forward is `contentReadDocuments`, `readTrees` and `shippedDocuments` there.
- **Gate slots:** two kept worktrees under `~/.local/state/nagare/gates/gate-slots/` with their
  own `dist-newstyle` (`Nagare.Harness.Slot`); a gate compiles only what changed since the slot's
  last run, which is why a package-id change costs a full rebuild in each slot.
- **The sweep:** `just mutation-sweep` (`Nagare.Harness.Mutation.sweepRecords`) builds every
  mutation record at a revision on the builder in one derivation and requires each to fail its
  tests. `just gate-release` skips it when nothing under `cli`, `nix`, `flake.*` or
  `cabal.project*` changed since the nearest ancestor with a clean sweep, apart from the
  platform version. Sweep bases are recorded under `~/.local/state/nagare/gates/sweep/`.
- **The intranet:** the operator's context `intranet` in `mori://tan/tan-ng-labs`, which pins
  Nagare through `inputs.nagare.url` in `flake.nix` and `hosts/intranet/flake.nix`. An upgrade is
  `platform transition plan --out DIR`, `inventory apply DIR --yes` until a plan has no
  operations, then `platform transition commit --yes`. Reviews are kept under
  `~/.local/state/nagare/intranet/reviews/`. Known-good invocation: run `nagarectl` through the
  operator repository's dev shell (`direnv exec <repo> nagarectl ...`) with `gcloud` on `PATH`.

Files this plan changes: `release.json`, the six `cli/*/*.cabal` files,
`cli/nagarectl/src/Nagare/Version.hs`, `cli/nagarectl/test/PlatformSpec.hs`,
`nix/haskell-packages.nix`, `nix/platform-package.nix`, `scripts/check-release.sh`,
`scripts/release-candidate.sh`, `scripts/release-publish.sh`, a new
`scripts/release-intranet.sh`, `cli/nagare-harness/src/Nagare/Harness/CarryForward.hs`,
`justfile`,
`scripts/audit-managed-commands.py` (every recipe and mutating script is registered),
`docs/runbooks/releases.md`, `agents/skills/nagare-release/SKILL.md`, `CHANGELOG.md`,
`docs/releases/`, `docs/plans/201-*.md` (superseded note).

ADRs: [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable
signed tags; publication validates an existing tag) is kept. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
(the 2026-10-18 amendment lets a newer payload on the same source supersede an idle open
transition) makes the fix-forward loop in M5 possible. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps the intranet record out of this repository. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
is the basis for M1's removal of the native smoke from the release path.


## Plan of Work

**M1, the three proofs only.** Rewrite `docs/runbooks/releases.md` "Prepare a candidate" to the
two files of M2 and M3 and the commands `just release-candidate` and `just release-publish`; drop
the hand-run smoke, README status, user-doc version lines and the capabilities log from the
release. Cut `agents/skills/nagare-release/SKILL.md` to: read the runbook, the three proofs, the
release boundary (ADR 7), the two commands, recovery. Remove "three Cabal packages", "GitHub
native runner matrix", "monitor GitHub publication" and the `okf`/`mori` validation list. The
notes' Validation paragraph becomes one sentence naming the three proofs.

**M2, notes outside the gate.** The one gate reader of the notes is `scripts/test-release.sh`
(a flake check), which copies the repository's own `CHANGELOG.md` and `docs/releases/vX.Y.Z.md`
into its fixture (lines 27 to 30); give it fixture notes of its own so no check reads the real
ones. Then in `CarryForward.hs` remove `docs/releases/` from `contentReadDocuments` and
`readTrees` and add `CHANGELOG.md` to `inertFiles`; `check-release.sh` keeps reading the notes,
but it runs in the candidate pipeline on the candidate revision, not in a gate. Make
`check-release.sh` require `docs/releases/vX.Y.Z.md` beginning with `# Nagare X.Y.Z` and stop
requiring a `[X.Y.Z]` changelog entry; `CHANGELOG.md` becomes a list of links to the notes. A
notes commit after the bump then lands by carry-forward and `release-candidate --revision`
accepts it because it descends from the gated bump (the gate record lookup already accepts
carried-forward records). Because the notes become inert, a rebase of a notes commit keeps its
ancestor's record too. The more general mechanism raised on 2026-10-20, rerunning only the
checks that read a changed tree instead of the suites, is not needed while nothing in a gate
reads the notes; `check-release.sh --source-only` reads them in seconds in the candidate
pipeline.

**M3, one version source.** `Nagare.Version` embeds the `platformVersion` of `release.json` at
compile time (Template Haskell with `addDependentFile`, so only that module recompiles on a
bump; in Nix the package source already receives a copy of `release.json`, see
`nix/haskell-packages.nix`, and the Cabal build reads the repository file through
`extra-source-files` or a tracked relative link). Set every `cli/*/*.cabal` `version:` to a
constant and leave it. `nix/haskell-packages.nix` names `nagarectl-X.Y.Z`,
`nagare-operator-nagarectl-X.Y.Z` and `nagare-X.Y.Z` from `release.json`;
`nix/platform-package.nix` already reads it. `cli/nagarectl/test/PlatformSpec.hs` builds its
fixture from the embedded version instead of a literal. `check-release.sh` drops the Cabal
comparison (lines 142 to 145) and keeps the built-CLI and payload comparisons.

**M4, never block the operator.** In `release-candidate.sh` step 6, `git fetch -q origin master`
before `git worktree add --detach "$evidence" origin/master`, so the record goes on the current
master and `just land` accepts it. Keep every other action in the run's worktrees. The operator
repository is touched only by M5's script, with `git add` by explicit path.

**M5, the intranet step and the tag.** Write `scripts/release-intranet.sh VERSION` in the style
of `release-publish.sh`. It reads `<run>/candidate.json` of the latest run (or the run named by
`--run`), requires the operator repository at `NAGARE_RELEASE_OPERATOR_REPO` (default: the path
Mori registers for `tan/tan-ng-labs`) with a clean tree for the pin files, and then, through that
repository's dev shell:

1. sets `inputs.nagare.url` to `github:shinzui/nagare/<revision>` in `flake.nix`, runs
   `nix flake update nagare`, lets `nagarectl` regenerate `hosts/intranet/flake.nix` as today, and
   commits those files by path as `feat(nagare): upgrade the intranet to the vX.Y.Z candidate`;
   an operator-config compile failure stops here with the compiler's message (the fix is the
   operator's; the run does not edit app config);
2. plans and applies until a plan has no operations, resuming an ambiguous stop once by
   transaction id as the runbook describes, then commits the transition;
3. requires `platform status --json` exact with every identity at VERSION and the revision,
   `inventory status --json` with no active transaction and every accepted scope converged, and
   the protected URL answering 302 with a `Location` on the login path;
4. writes `<run>/intranet.json` atomically with `{version, revision, context, checkedAt,
   status, inventory, protected}`.

`release-candidate.sh` calls it after assembly (the rehearsal has proved the transition on a
local context by then, so the intranet is the second context to move). `release-publish.sh`
requires `intranet.json` for the run's revision before signing, and after the public flake check
commits `chore(nagare): pin the intranet to the published vX.Y.Z tag` in the operator
repository. A defect found on the intranet keeps the version: land the fix, run
`just release-candidate X.Y.Z --revision NEW`, and the new candidate supersedes the idle open
transition (ADR 6 amendment). The flag `--login-confirmed` from EP-201 is not implemented
(Decision Log). Register the recipe and the script in `scripts/audit-managed-commands.py`;
drive each refusal with a fake `nagarectl` on `PATH` in `scripts/test-release.sh`.


## Concrete Steps

From the repository root, per Haskell commit: `just haskell-style-check`, then
`just gate-fast`, then `just land <commit>`. M5's script is rehearsed on the release-rehearsal
`transition` context (Colima `nagare-mp23`) before it runs on the intranet.

The release after this plan:

```bash
# land the bump: release.json and docs/releases/vX.Y.Z.md
just gate-fast && just land HEAD
# when the post-land full gate is green
just release-candidate X.Y.Z      # rehearsal, attachments, assembly, the intranet, the record
just release-publish X.Y.Z        # tag, push, publish, public flake, pin the tag
```

Expected: the candidate run ends `vX.Y.Z is ready to publish` within the time of its longest
step, the sweep, and `release-publish` ends `vX.Y.Z is published`.


## Validation and Acceptance

Each milestone's pass condition is in Progress. The plan is complete when one release ships
through the new path with: the prepare commit touching two files, its fast gate building
`nagarectl-test` incrementally, no gate on a notes fix, the operator landing an unrelated commit
during the run without failing it, and `intranet.json` dated before the tag.


## Idempotence and Recovery

`release-intranet.sh` only pins, plans, applies and reads; rerunning it on a context already on
the candidate plans zero operations and rewrites the record. A refused publish creates nothing.
The fix-forward loop keeps the version: nothing is tagged until the intranet runs the revision.


## Interfaces and Dependencies

`intranet.json` in the run directory is the one new interface, read by `release-publish.sh`.
`NAGARE_RELEASE_OPERATOR_REPO` names the operator repository. The embedded version in
`Nagare.Version` is read by `nagarectl version`, the platform status identities and
`check-release.sh`'s built checks; nothing else changes shape. M5 depends on ADR 6's supersede
rule (v0.6.6, F130).
