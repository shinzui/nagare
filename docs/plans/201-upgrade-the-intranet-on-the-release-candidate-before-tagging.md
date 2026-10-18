---
id: 201
slug: upgrade-the-intranet-on-the-release-candidate-before-tagging
title: "Upgrade the intranet on the release candidate before tagging"
kind: exec-plan
created_at: 2026-10-18T18:49:01Z
intention: "intention_01m43gtzcvehkrgeas1j1v4077"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-18T18:49:01Z
---

# Upgrade the intranet on the release candidate before tagging

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A Nagare release counts when the work intranet runs it, not when a tag exists (operator,
2026-10-10). Today the order is reversed: `just release-candidate` proves a candidate on local
machines, `just release-publish` signs and publishes the tag, and only then does the operator
upgrade the intranet. Any defect that only the real intranet reveals therefore costs a whole
published release.

That is what happened while shipping the admin API (2026-10-17/18). v0.6.4 and v0.6.5 were
published and then failed on the intranet (F125, F128), and v0.6.6 was needed to finish (F128,
F129, F130). The 29 hours included two extra releases.

After this plan:
- The intranet is upgraded from the candidate's exact revision before anything is tagged.
- `just release-publish` refuses to tag a candidate unless the intranet runs that exact revision,
  with an exact platform status, converged inventory and a confirmed login.
- A defect found on the intranet costs a new candidate at the same version, which takes the open
  transition over. It does not cost a published release.

You can see it working on the next release: the sequence is candidate, intranet upgrade, intranet
record, publish. A publish attempted before the intranet record exists stops with a message
naming the missing record.


## Progress

- [ ] M1. `scripts/release-intranet-record.sh VERSION` (recipe `just release-intranet VERSION`),
  run from the operator shell of the release context, writes `<run>/intranet.json` for the latest
  candidate run of VERSION. It refuses, writing nothing, unless all of these hold:
  - the CLI, payload, host and cluster all report VERSION at the candidate's revision, and the
    platform status is `exact`;
  - the store has no active transaction or executor claim, and every accepted scope is converged;
  - the protected URL answers 302 to the login page;
  - the operator passes `--login-confirmed`.

  A test drives each refusal and the success path against canned `nagarectl` output.
- [ ] M2. `scripts/release-publish.sh` refuses before signing unless `<run>/intranet.json` exists,
  names the run's version and revision, and records an exact status and a confirmed login. A test
  covers a missing record, a record for another revision, and a valid record.
- [ ] M3. `docs/runbooks/releases.md` describes the order: candidate, intranet at the revision,
  intranet record, publish. It also covers the fix-forward loop: fix, a new candidate at the same
  version, the intranet plan with the new candidate superseding the open transition, a new record,
  then publish. Release notes no longer say the intranet upgrade follows publication.
  `mori://tan/tan-ng-labs` `docs/runbooks/operations.md` pins the candidate's revision for an
  upgrade (artifact-level URI pending).
- [ ] M4. The next release ships in this order. Its run directory holds `intranet.json` dated
  before the tag, and `git log` shows the tag on the revision the intranet ran.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The intranet record stays in the candidate's run directory
  (`~/.local/state/nagare/releases/vX.Y.Z/<time>/intranet.json`) and is never committed here.
  Rationale: it names the operator's context, hosts and users. ADR 13 keeps operator material out
  of this repository, and the published rehearsal record already proves the transition in public.
  Date: 2026-10-18
- Decision: No publish without an intranet record; there is no bypass flag.
  Rationale: a release counts only when the intranet runs it (operator, 2026-10-10). A bypass
  would restore the order that cost v0.6.4 and v0.6.5. A future second operator context can be
  named by `NAGARE_RELEASE_CONTEXT` without a bypass.
  Date: 2026-10-18
- Decision: A defect found on the intranet keeps the version. The fix lands, `just
  release-candidate X.Y.Z --revision NEW` runs again, and the new candidate supersedes the open
  transition.
  Rationale: nothing is tagged yet, so the version is not burned. Since v0.6.6, a payload moving
  the same pinned source may take over an idle open transition, whose first admitted stage
  retargets the marker (ADR 6, 2026-10-18 amendment).
  Date: 2026-10-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms used here:
- **Candidate:** a landed commit whose `release.json` names the next version and which
  `just release-candidate VERSION --revision REV` has proved.
- **Run directory:** where that command leaves its results, under
  `~/.local/state/nagare/releases/vVERSION/<UTC time>/`. A `latest` symlink points to the last
  completed run. The run holds `candidate.json` (`{version, revision, previous}`) and `dist/` (the
  release attachments).
- **The intranet:** the operator's production context, named `intranet`. Its private operator
  repository is `mori://tan/tan-ng-labs`, which pins Nagare through its `flake.nix` input
  `inputs.nagare.url`.
- **Transition:** the staged, reviewed move of a context from its pinned release to the running
  CLI's release: `nagarectl platform transition plan --out DIR`, `nagarectl inventory apply DIR
  --yes` until a plan has no mutation, then `nagarectl platform transition commit --yes`, which
  writes the pin last. While a transition is open, a marker in the inventory head names its
  target payload. The payload id is derived from the revision, so a candidate and its later tag
  on the same commit are one payload.

Files involved:
- `scripts/release-candidate.sh`: the unattended candidate run. Its preflight requires `vVERSION`
  to be untagged and the newest `transitionsFrom` entry to be a published tag. It runs the release
  gate, `just release-rehearse` (the disposable local rehearsal, EP-172), both systems' native
  attachments and two byte-identical assemblies. It lands
  `docs/release-evidence/<rev>/transition-rehearsal.json` and points `latest` at the run. It does
  not touch the intranet and needs no change here.
- `scripts/release-publish.sh`: signs `vVERSION` on the run's revision, pushes the tag, publishes
  with the candidate's CLI and checks the public flake. Its preflight today checks only
  `dist/SHA256SUMS` and the landed rehearsal record. M2 adds the intranet check there.
- `Justfile`: recipes `release-candidate`, `release-publish` and `release-rehearse`. M1 adds
  `release-intranet`.
- `scripts/audit-managed-commands.py`: every `just` recipe must appear in `RECIPES`, and every
  script that runs mutating `nagarectl` commands must be registered. The new recipe only reads, so
  it goes in `read`, and its script reads only `nagarectl version`, `platform status --json` and
  `inventory status --json`.
- `scripts/test-release.sh`: bash tests of the release scripts, run by the flake check. M1 and M2
  add their cases there, or in a sibling `scripts/test-release-intranet.sh` registered the same
  way.
- `docs/runbooks/releases.md`: its "The intranet" section already allows pinning the candidate's
  revision before the tag. Its publish section ends with "switch the operator repository's flake
  input from the revision to the tag".

Commands whose JSON the record reads:
- `nagarectl platform status --json` prints `compatibility` and an `identities` object with
  `{version, revision}` for `cli`, `payload`, `host`, `cluster` and `context` (the context carries
  only a version).
- `nagarectl inventory status --json` prints `accepted` and `converged` lists of
  `{scope:{kind,name}, revision:{generation,digest}}`, `activeTransaction`, and `findings`.
- `nagarectl version --json` prints `{version, revision}`.

Relevant ADRs:
- [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md): releases are
  immutable, maintainer-signed tags, and published tags and attachments are never moved. This plan
  keeps that; it only adds a precondition before tagging.
- [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
  amendment 2026-10-18: a newer payload moving the same pinned source may supersede an idle open
  transition, and commit requires the marker's own payload. That rule makes the fix-forward loop
  possible.
- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
  operator material stays in the private operator repository, hence the run-directory record.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): native
  runs only confirm. This plan does not replace finding defects offline; it limits what an
  intranet-only defect costs.


## Plan of Work

**M1, the intranet record.** Write `scripts/release-intranet-record.sh` in the style of
`scripts/release-publish.sh` (`set -euo pipefail`, `die`, `step`). It takes `VERSION`,
`--protected-url URL` (default `https://protected-hello.$NAGARE_BASE_DOMAIN/`) and
`--login-confirmed`.

The script:
1. Resolves `~/.local/state/nagare/releases/vVERSION/latest/candidate.json` and reads `revision`.
2. Requires `NAGARE_CONTEXT` to be set, the context to be cloud mode, and
   `nagarectl version --json` to report VERSION at that revision. That last check means the
   operator shell runs the candidate.
3. Runs `nagarectl platform status --json` and requires `compatibility == "exact"`, and
   `identities.{cli,payload,host,cluster}.version == VERSION` and `.revision == revision`.
4. Runs `nagarectl inventory status --json` and requires a null `activeTransaction` and every
   accepted scope converged at the same revision.
5. Requires `curl` on the protected URL to answer 302 with a `Location` on the login path.
6. Requires `--login-confirmed`.
7. Writes `intranet.json` atomically:

   ```text
   {version, revision, context, checkedAt, status:<platform status JSON>,
    inventory:{scopes, converged:true}, protected:{url, status, location}, loginConfirmed:true}
   ```

Add the recipe

```text
release-intranet version *args:
    scripts/release-intranet-record.sh {{version}} {{args}}
```

to `Justfile`, with a comment, and register it under `read` in
`scripts/audit-managed-commands.py`. The recipe runs from the nagare checkout, but its environment
must be the operator shell: run it as `bash <nagare>/scripts/release-intranet-record.sh` from that
shell, or with the operator's context selected.

Tests: put a fake `nagarectl` and `curl` on `PATH`, printing canned JSON from
`scripts/test-fixtures/release-intranet/`. Cover each refusal (revision mismatch, minor-skew
status, an active transaction, an unconverged scope, a 200 instead of 302, missing
`--login-confirmed`) and the success path. Check that a refusal writes no file.

**M2, publish refuses without it.** In `scripts/release-publish.sh`, after the rehearsal-record
check and before step 1, require `$run/intranet.json`. Its `version` and `revision` must equal
the run's, `status.compatibility` must be `exact`, and `loginConfirmed` must be true. Otherwise
fail with:

```text
release-publish: no intranet record for <rev>; upgrade the intranet to this revision and run just release-intranet VERSION from its operator shell
```

Tests: run the preflight against a temporary run directory. Factor the check into a function in
`scripts/lib/release.sh` so the test calls it without signing anything.

**M3, documentation.** Rewrite the order in `docs/runbooks/releases.md`. Move "The intranet"
between "Prove and assemble the candidate" and "Publish", and add the fix-forward loop:
1. Land the fix with its gates.
2. Run `just release-candidate X.Y.Z --revision NEW`; the same version is fine.
3. Re-pin the operator repository to NEW.
4. `platform transition plan`, which supersedes the open transition when the store is idle. If a
   transaction is open, close or resume it with the old candidate's CLI first.
5. Run the record again, then publish.

Change the "Validation" paragraph template in `docs/releases/` notes going forward to "the work
intranet ran this candidate before the tag". In `mori://tan/tan-ng-labs`, change
`docs/runbooks/operations.md`'s upgrade section to pin `github:shinzui/nagare/<revision>` for the
candidate and switch to the tag after publication.

**M4, the next release.** No new code: the acceptance is that the next release follows the order.


## Concrete Steps

From the nagare checkout, after M1–M2 land:

```bash
just release-candidate 0.6.7                     # unchanged; ends "ready for the intranet"
```

In `mori://tan/tan-ng-labs`, pin the candidate revision and upgrade:

```bash
sed -i 's|github:shinzui/nagare/v[0-9.]*|github:shinzui/nagare/<rev>|' flake.nix
nix flake update nagare
nagarectl platform transition plan --out ~/.local/state/nagare/intranet/reviews/t-1
nagarectl inventory apply ~/.local/state/nagare/intranet/reviews/t-1 --yes   # repeat plan/apply
nagarectl platform transition commit --yes
```

The operator signs in to a protected site, then, from the same shell:

```bash
bash ~/Keikaku/bokuno/nagare/scripts/release-intranet-record.sh 0.6.7 --login-confirmed
```

Expected output:

```text
release-intranet: intranet at 0.6.7 (<rev>), exact; 36 scopes converged; protected-hello 302 to login
release-intranet: recorded ~/.local/state/nagare/releases/v0.6.7/<time>/intranet.json
```

Back in the nagare checkout:

```bash
just release-publish 0.6.7
```

Run before the record exists, it stops at the M2 message and tags nothing.


## Validation and Acceptance

- `bash scripts/test-release.sh` (or the sibling intranet test) passes. A deliberately broken
  check fails it, for example accepting a mismatched revision.
- `just gate-fast` and the full gate pass, including `managed-command-audit` and
  `shellcheck-scripts`.
- On the next real release:
  - `just release-publish` refuses before `intranet.json` exists (no tag is created), and succeeds
    after.
  - The tag resolves to the revision recorded in `intranet.json`.
  - `nagarectl platform status` on the intranet reports `exact` at the tagged version.


## Idempotence and Recovery

The record script only reads, and it overwrites `intranet.json` atomically, so rerunning it is
safe. A refused publish has created nothing. If the intranet stops mid-transition on a candidate,
these are the exits, in order:
1. `inventory resume` or `inventory close` with that candidate's CLI.
2. A new candidate superseding the transition once the store is idle.

The tag is never created until the record passes, so no published release needs recovering.


## Interfaces and Dependencies

`intranet.json` (in the run directory) is the only new interface, and `release-publish.sh` reads
it. Its fields are `version`, `revision`, `context`, `checkedAt`, `status` (the verbatim
`platform status --json`), `inventory.converged`, `protected.{url,status,location}` and
`loginConfirmed`.

The plan depends on v0.6.6's transition supersede (F130) for the fix-forward loop, on `jq` and
`curl` in the operator shell, and on the operator repository accepting a revision-pinned flake
input.
