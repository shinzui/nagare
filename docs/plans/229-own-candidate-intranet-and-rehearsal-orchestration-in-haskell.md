---
id: 229
slug: own-candidate-intranet-and-rehearsal-orchestration-in-haskell
title: "Own candidate, intranet and rehearsal orchestration in Haskell"
kind: exec-plan
created_at: 2026-10-29T16:53:33Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-29T16:53:33Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T19:13:16Z
      mode: "implement"
      note: "Implemented M1-M3: Haskell release runner, plan summary and run index, Python-free rehearsal"
---

# Own candidate, intranet and rehearsal orchestration in Haskell

This ExecPlan is a living document. It is the release-runner child of the MasterPlan named in
frontmatter; Progress is its deliverable checklist and the Decision Log holds dated scope decisions.


## Purpose / Big Picture


After this change the four shell scripts that run a release (the candidate, the intranet move,
the upgrade rehearsal and the rehearsal's transition drill) are thin wrappers over one Haskell
program, `nagare-harness`, and the supported release path runs on a machine with no Python
interpreter. The operator still types `just release-candidate X.Y.Z` and
`just release-rehearse REV PREV`, gets the same records in the same places, and every decision
the scripts took by scraping text or by inline Python is a typed decision with a test. Nothing
about what a recipe is allowed to do changes; only where the logic lives.

This is [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
applied to the release path. It was split out of EP-228 on 2026-10-29 because the port needs none
of the rollout changes EP-225 to EP-227 make, so it runs now, in parallel; EP-228 M3 then extends
the ported runner with a preparation manifest, progress and cost records.


## Progress


- [x] M1: `nagare-harness release candidate`, `transition run`, `transition pin-tag` and
  `transition rehearse` reproduce the four scripts' behavior, proven by fixtures of recorded
  command order, and the scripts are argument-preserving `exec` wrappers; `just release-rehearse`
  on the disposable context writes the same transition-rehearsal record as before.
  Evidence (commit 4a3bb3e6): `ReleaseTransitionSpec` (28 cases, `-p ReleaseTransition`) passes,
  with the scripts' invocation orders for all four commands, the converged rule on the sanitized
  v0.11.1 intranet reviews (2, 211 and 0 operations; 1, 6 and 0 re-accepts), the twelve-stage
  bound, one resume of an ambiguous apply, `--rehearsal` landing nothing, pin-tag without a
  rollout and the eight intranet refusals; `just gate-fast 4a3bb3e6` green. `just
  release-rehearse ef5a537c 0.11.0` (the v0.11.1 move, through the ported drill on nagare-mp23)
  wrote a record byte-identical to the v0.11.1 release's apart from the sentinel timestamp.
- [x] M2: Every decision the scripts took from text (the ambiguous transaction ID, operation and
  re-acceptance counts, version and revision checks) is read from a typed outcome document
  through a version-one run index; no `jq`, `sed` or Python JSON decision remains on these paths.
  Evidence (commits 451dc528, 8e4e300a): `platform transition plan --summary`; the intranet and
  the drill's candidate loop decide from it and from `--contract 1` outcomes, and the fixtures
  check every index stage and attempt; `grep -E 'jq|sed -n|python'` over the four wrappers and
  `Release/*.hs` finds only comments; `just gate-fast` green on both commits. In the disposable
  rehearsal below the candidate's three transition stages (0, 214 and 0 operations; 1, 6 and 0
  re-accepts, the v0.11.1 shape) were decided from the candidate's summaries, and the drill
  index records each attempt's transaction and outcome.
- [x] M3: The release path runs with no Python executable: the rehearsal's empty environment no
  longer lists `python3`, the fake transport fails on any Python launch, and the runbook and
  ADR 24 describe the ported path.
  Evidence (commit 1025c156): `ReleaseTransitionSpec` (29 cases) passes with the Python detector
  on every fake call and the candidate fixtures under a PATH with no Python; `just
  release-rehearse 1025c156 0.11.0` passed on nagare-mp23 from the environment without
  `python3`, writing a record with the v0.11.1 record's shape (3 bootstrap reviews, 2
  transition reviews, 214 operations, sentinel read back). `docs/runbooks/releases.md` and the
  ADR 24 amendment name the harness commands. `just gate-release` still runs the repository's
  Python checks, which are outside this plan.


## Surprises & Discoveries


(None.)


## Decision Log


- 2026-10-29: Created by splitting EP-228 M3 and M4's port work out (MasterPlan 30 Decision Log,
  same date). Port existing behavior first and prove it equal; add nothing to what a recipe
  authorizes. EP-228 M3 adds the manifest, progress and cost features on top, so this plan never
  waits for EP-225 to EP-227.
- 2026-10-29: Keep the public entry points exactly: the `just` recipes, the scripts' names and
  argument grammars, the record locations and `NAGARE_RELEASE_REHEARSAL_RECORD`. A wrapper only
  `exec`s the harness with its arguments.
- 2026-10-29: The harness may depend on `nagare-contract` (EP-224 adds it for the trace codec)
  but never on the nagarectl library; typed outcomes come from small additive nagarectl output.
- 2026-10-29 (M1): The harness commands take the scripts' own grammars so each wrapper is a bare
  `exec scripts/harness.sh … "$@"`: `release candidate VERSION [--revision REV] [--rehearsal]`,
  `transition run VERSION [--run DIR] [--context NAME] [--revision REV] [--pin-tag]` (with
  `--pin-tag` it is `transition pin-tag`; `--context` defaults to `NAGARE_RELEASE_CONTEXT`, else
  `intranet`, and `--revision` only refuses a run for another revision),
  `transition pin-tag VERSION [--run DIR] [--context NAME]`,
  `transition rehearse REV PREV_VERSION [--run DIR]`, and `transition drill` for
  `scripts/transition-rehearsal.sh`, configured by its `NAGARE_REHEARSAL_*` variables. Usage
  errors exit 2 for every harness command, as the scripts' did.
- 2026-10-29 (M1): `transition rehearse` starts the drill as `nagare-harness transition drill`
  with exactly the old `env -i` variables and tees its output to `rehearsal.log`, so the drill
  still runs from the empty environment. Every invocation resolves its program on the child's
  PATH, not the harness's. The drill's `docker save | docker load` of a missing pinned image is
  `docker save -o` and `docker load -i` through a file in the root.
- 2026-10-29 (M1): `scripts/audit-managed-commands.py` registers the drill and intranet entry
  points at their Haskell modules (a data-only edit of the frozen audit). The intranet cases of
  `scripts/test-release-intranet.sh` moved to `ReleaseTransitionSpec`; the script keeps only
  release-publish's intranet precondition, which this plan does not port.
- 2026-10-29 (M2): The apply outcome needs no nagarectl change: `inventory apply` and `inventory
  resume` already print a `transaction-outcome` document under `--contract 1` (EP-192) with the
  transaction, operation and `StoppedAmbiguous` reason. The one nagarectl addition is
  `platform transition plan --summary FILE`, which writes a `TransitionPlanSummary`
  (`cli/nagare-contract/src/Nagare/Contract/Release.hs`, outside the public `--contract 1`
  documents and the OpenAPI schema; the review directory itself must hold only its three
  members). The harness decodes it, `TransactionOutcome` and `VersionInfo` from
  `nagare-contract`.
- 2026-10-29 (M2): A published source release cannot gain new output. The drill's bootstrap
  loop on the source therefore decodes the source's `review.json` in the harness and reads its
  `platform bootstrap apply` stop from the human `ambiguous TX at OP` line, in Haskell; the
  candidate's bootstrap replan decodes its `review.json` the same way. Every candidate-side
  decision reads a nagarectl document.
- 2026-10-29 (M2): The run index is one file per command run, rewritten after every step,
  stage and attempt: `<run>/index.json` (candidate), `<run>/intranet-index.json` (intranet),
  `<work>/index.json` (rehearsal) and `<work>/run/index.json` (drill). The candidate passes the
  rehearsal a fresh `/private/tmp/nagare-release-rehearse.XXXXXX` work directory with `--run`,
  so it can name the rehearsal's index as a child; the drill root stays under `/private/tmp`.
  `transition pin-tag` writes none: it has no stage.


## Outcomes & Retrospective


(Not used; operator decision 2026-10-10.)


## Context and Orientation


A release is prepared by `scripts/release-candidate.sh` (157 lines;
`just release-candidate VERSION [--revision REV] [--rehearsal]`). In a worktree of the candidate
revision it starts `just gate-release` in the background, runs `scripts/release-rehearse.sh` for
the upgrade rehearsal, builds the aarch64-darwin attachments with `scripts/release-native.sh` and
the x86_64-linux ones in a container with `scripts/release-native-container.sh`, assembles the
release twice with `scripts/assemble-release.sh` and requires identical bytes, waits for the gate,
moves the intranet with `scripts/release-intranet.sh`, and commits the rehearsal record on
`origin/master` in an evidence worktree with `just land`. `--rehearsal` runs every step but lands
nothing. `just release-publish VERSION` takes the run from there and is not part of this plan.

`scripts/release-intranet.sh` (185 lines; `VERSION [--run DIR] [--pin-tag]`) pins the operator
repository's flake input to the candidate revision, checks `nagarectl version --json` and that the
store has no active transaction, then loops at most 12 stages: `platform transition plan`, count
operations and re-accepted scope revisions from `review.json` with `jq` (the bootstrap stamp does
not count), stop when both are zero, otherwise `inventory apply --yes`. If the apply fails it
scrapes `ambiguous tx-… at` from the log and resumes that transaction once; the message is
rendered from `StoppedAmbiguous` in `cli/nagarectl/src/Nagare/Inventory/Command.hs`. It then
commits the transition, requires exact platform status, and writes the intranet record.
`--pin-tag` pins the published tag without repeating the rollout.

`scripts/release-rehearse.sh` (82 lines; `just release-rehearse REV PREV`) builds the previous
release's packaged nagarectl and the candidate's, prepares the Colima profile `nagare-mp23`, and
runs `scripts/transition-rehearsal.sh` from an empty environment whose PATH holds only listed
nixpkgs tools and no Helm. It writes `docs/release-evidence/<rev>/transition-rehearsal.json` or
`NAGARE_RELEASE_REHEARSAL_RECORD`, keeping an existing green record. Its Python is the inline
record check at line 28, the `version --json` revision check at line 64 and `python3` in the
empty environment's tool list at line 57.

`scripts/transition-rehearsal.sh` (200 lines; EP-172 M3) moves a disposable local context from
the source release to the candidate on a disposable Docker daemon, seeds a database row and reads
it back after the move, with `STAGES_MAX=12` and the same converged rule. Its Python is
`operations()` and `reaccepts()` over `review.json` at lines 33 and 36, the source version read at
line 141 and the record writer at line 182. The helpers the four scripts invoke
(`release-native.sh`, `release-native-container.sh`, `assemble-release.sh`) contain no Python and
are not ported.

`cli/nagare-harness/app/Main.hs` is the maintainer CLI (optparse-applicative `hsubparser` with
`gate`, `fixture-smoke`, `mutations` and `route-check`). `cli/nagare-harness/src/Nagare/Harness/Step.hs`
runs one external command as a `Step` (name, directory, program, arguments) and returns a
`StepResult`; `Nagare/Harness/Record.hs` decodes gate records and has no type for the
transition-rehearsal or intranet records yet. The harness builds from
`cli/nagare-harness/cabal.project`, which lists only itself; EP-224 adds `../nagare-contract` for
the trace codec, and this plan must not add the nagarectl library. Tests are assembled in
`cli/nagare-harness/test/Spec.hs` and registered in `cli/nagare-harness/nagare-harness.cabal`.

A typed outcome document is JSON that nagarectl prints or writes and a Haskell record decodes;
`version --json`, `platform root --json` and `inventory store status --json` exist today, and a
saved review is `review.json` under the `--out` directory. The run index is one JSON file per
release run naming the candidate, revisions, each stage's review directory, transaction ID,
attempt status and record paths. EP-228 M3 later adds the preparation manifest and trace paths
to it, and EP-224 M2's cost collector reads it.

[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) keeps
the context pin last, [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
keeps host activation self-reverting and [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
keeps apply guarded; the port preserves the order and refusals the scripts implement.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the fake
process transport is where defects are found; the disposable rehearsal only confirms.


## Plan of Work


### M1 — Port the behavior and wrap the scripts


Add `cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs`, `Release/Intranet.hs`,
`Release/Rehearse.hs` and `Release/TransitionDrill.hs`, one per script, over a process boundary
`Nagare.Harness.Release.Process` that runs every external command through an injectable
interpreter built on `Step`, so a test records each invocation (program, arguments, directory,
environment variable names, never values). Port each script step for step: same guards, same
candidate identity and clean pin-file checks, same background gate, same worktrees, same
stop-at-first-failure, same step lines on stdout, same record locations. Register the commands in
`Main.hs` as `release candidate VERSION [--revision REV] [--rehearsal]`,
`transition run --context NAME --version VERSION --revision REV --run DIR`,
`transition pin-tag --context NAME --version VERSION --run DIR` and
`transition rehearse --revision REV --previous VERSION --run DIR`.

Then replace each script's body with `exec` of the harness command with its arguments, resolving
the harness the way the `just` recipes do; keep the file names and usage comments so `justfile`,
the runbook and `release-publish.sh` keep working. Add
`cli/nagare-harness/test/ReleaseTransitionSpec.hs`: for each command a recorded fake transport
proves the invocation order equals the script's (take the expected order from the script before
deleting its logic), the converged rule (operations and non-stamp re-acceptances both zero), the
twelve-stage bound, the single resume on an ambiguous apply, `--rehearsal` landing nothing and
`--pin-tag` not re-running the rollout. Derive a sanitized fixture from the recorded v0.11.1 run
under `~/.local/state/nagare/releases/`; commit no private contents.

### M2 — Decide from typed documents, not text


Give the two text decisions a document. Add an additive machine-readable summary to
`platform transition plan` (operation count by action, non-stamp re-accepted scope count, the
review path) and a machine-readable stop outcome for `inventory apply` carrying the transaction
ID and the `StoppedAmbiguous` reason; both are small additions in files EP-228 owns
(`cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs` and the apply command), so land them first
and keep them additive. Decode `version --json` and `platform root --json` with harness records.
Write the version-one run index after every stage and attempt. Remove the `jq`, `sed -n` and
`python3` decisions from the four paths; `jq` may remain only in `release-publish.sh`, which this
plan does not touch.

### M3 — Prove the path has no Python


Remove `python3` from the rehearsal's empty-environment tool list so the disposable rehearsal is
itself the proof. In `ReleaseTransitionSpec` the fake transport fails on any program named
`python`, `python3` or an absolute interpreter path, and the candidate fixture runs under a PATH
with no Python. Delete the shell logic the wrappers replaced, update `docs/runbooks/releases.md`
(its steps name the scripts) and the harness help, and amend ADR 24 with the ported path.


## Concrete Steps


From the repository root:

```bash
cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-options='-p ReleaseTransition' --test-show-details=direct
just haskell-style-check
just gate-fast <committed-revision>
just release-rehearse <candidate-revision> <previous-version>
just release-candidate <version> --revision <committed-revision> --rehearsal
```

The first command must select a nonzero test group. `just release-rehearse` is the disposable
native confirmation on the Colima profile `nagare-mp23` and mutates no cloud resource.
`just release-candidate … --rehearsal` runs every candidate step, lands nothing, needs the remote
builder and takes the gate's time, so run it once per milestone. Neither touches the intranet; an
intranet move stays under the release runbook and the operator's go-ahead.


## Validation and Acceptance


M1: fixture invocation orders equal the scripts', and the disposable rehearsal record has the same
shape and sentinel handling as before. M2: no `jq`, `sed -n` or `python3` decision remains in the
four scripts or the harness release modules, and the ambiguous-apply fixture resumes from the
decoded transaction ID. M3: the rehearsal passes with no `python3` in its environment, the fake
transport's Python detector stays silent through the candidate fixture, and the runbook names the
harness commands. A candidate run that reaches the intranet is release work under the runbook,
not this plan's acceptance.


## Idempotence and Recovery


The wrappers and commands keep the scripts' stop-at-first-failure behavior; nothing is retried
except the single resume of an ambiguous apply, exactly as today. Run directories are per attempt,
and a green rehearsal record is never overwritten. Re-running a wrapper with the same arguments
repeats the same steps against the same run directory. Reverting is a `git revert` of the port
commits; the scripts' previous bodies stay in history, and no record format changes here.


## Interfaces and Dependencies


No hard prerequisite. This plan owns `cli/nagare-harness/src/Nagare/Harness/Release/`, the harness
command grammar above, the four wrappers and the version-one run index.
[EP-228](228-run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress.md) M3
extends the run index with the preparation manifest, progress and cost and depends on this plan
being Complete; [EP-224](224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md)
M2 reads the run index for its cost collector. The only nagarectl change is the additive plan
summary and apply outcome of M2, in files EP-228 owns. Read optparse-applicative and aeson sources
through Mori before choosing APIs; no new dependency is prescribed.
