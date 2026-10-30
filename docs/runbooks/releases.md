# Publishing and recovering Nagare releases

This runbook is for maintainers. Nagare releases are immutable Nix flake tags; publication validates
and describes an existing tag but never creates a version commit or moves a tag. The intranet moves
to the candidate before the tag exists.

## A release

A release proves three things (operator, 2026-10-10): the full gate is green, the EP-172 upgrade
rehearsal on a disposable local context reads its seeded row back unchanged, and the intranet
runs the candidate. A release counts when the intranet runs it, not when a tag exists. Nothing
else is a release step.

```bash
# 1. the bump: release.json and docs/releases/vX.Y.Z.md, one commit
just gate-fast && just land HEAD
# 2. when the landed commit's full gate is green, on the aarch64-darwin workstation
just release-candidate X.Y.Z      # --revision REV names another candidate
# 3.
just release-publish X.Y.Z
```

Nothing in it waits for the operator, and it runs in its own worktrees, so the operator keeps
working and landing beside it.

## Prepare a candidate

Choose an unpadded semantic version `X.Y.Z` and commit `chore(release): prepare vX.Y.Z` with two
files:

- `release.json`: `platformVersion`, and `transitionsFrom`, the releases an installed context may
  move from. It must include the release the intranet runs; its newest entry is the release the
  rehearsal starts from. Claim rollback in `rollbackSupportedFrom` only for a tested reverse
  transaction.
- `docs/releases/vX.Y.Z.md`: the notes, beginning `# Nagare X.Y.Z`, and the changelog entry
  (add its link to `CHANGELOG.md`). Validation is one sentence: the three proofs passed.

`release.json` is the only place the version is written: `nagarectl` embeds it at compile time and
the Cabal package versions stay `0.0.0`. The notes are not a gate input, so a wording fix after the
bump lands with its ancestor's gate record and `release-candidate --revision` accepts it.

## The candidate run

`just release-candidate X.Y.Z` runs unattended up to the tag. Each step stops at its first failure
and nothing is retried. The run is `nagare-harness release candidate`
([`Release/Candidate.hs`](../../cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs), EP-229);
`scripts/release-candidate.sh`, `release-rehearse.sh`, `transition-rehearsal.sh` and
`release-intranet.sh` only `exec` the harness commands with their arguments, and no step of the run
starts a Python interpreter. Every decision reads a document nagarectl writes, and each command keeps
a version-one run index (`index.json` in the run directory, `intranet-index.json` beside it, and one
in the rehearsal's work directory) that names every step, reviewed stage and apply attempt:

1. **Preflight.** `release.json` at the candidate says `X.Y.Z` and names both systems, the candidate
   is on `origin/master`, `vX.Y.Z` is not tagged, and the newest version in `transitionsFrom` is a
   published tag. Then a worktree of the candidate is made in the run directory; every later step
   runs from it.
2. **Release gate.** `just gate-release <candidate>` in the background: the gate record, then the
   mutation sweep of the records whose patched files changed since the nearest ancestor's clean
   sweep (every record when there is none), skipped when nothing it builds changed.
3. **Upgrade rehearsal**, in the background beside steps 4 and 5 (log `rehearsal.log`; assembly
   waits for its record). `nagare-harness transition rehearse` (`scripts/release-rehearse.sh`)
   builds the previous release's packaged `nagarectl` and the candidate's and runs the transition
   drill, `nagare-harness transition drill` ([`scripts/transition-rehearsal.sh`](../../scripts/transition-rehearsal.sh)),
   on the Colima profile `nagare-mp23` from an empty environment whose PATH has no Helm and no
   Python. The candidate's stages are decided from `platform transition plan --summary` and the
   `--contract 1` outcome of each apply. The record goes into the run directory.
4. **aarch64-darwin attachments.** [`scripts/release-native.sh`](../../scripts/release-native.sh):
   `check-release.sh`'s built checks, the native output identities, and the clone-free rehearsal.
5. **x86_64-linux attachments.** The x86 outputs are built on the builder into a file cache under
   `~/.local/state/nagare/releases/x86-work`, then
   [`scripts/release-native-container.sh`](../../scripts/release-native-container.sh) runs the
   native script in an amd64 `nixos/nix:2.35.2` Apple container.
6. **Assembly.** [`scripts/assemble-release.sh`](../../scripts/assemble-release.sh) twice; the
   outputs must be byte-identical and bound to the rehearsal record of this candidate.
7. **The intranet**, once the release gate is green, under the operator's standing go-ahead.
   `nagare-harness transition run` ([`scripts/release-intranet.sh`](../../scripts/release-intranet.sh))
   pins the operator repository
   (`mori://tan/tan-ng-labs`, or `NAGARE_RELEASE_OPERATOR_REPO`) to the candidate revision, plans
   and applies the platform transition through that repository's dev shell until a plan has no
   operations, resuming an ambiguous stop once, and commits the transition. It requires an exact
   platform status on the candidate, every accepted scope converged and the protected URL
   answering 302 to the login page. Then it commits the pin files by path,
   `feat(nagare): upgrade the intranet to the vX.Y.Z candidate`, and writes
   `<run>/intranet.json`. It never edits app config: a config the candidate does not compile stops
   the plan with the compiler's message, and the fix is the operator's.
8. **Evidence.** It fetches `origin/master` again, commits the rehearsal record there as
   `docs/release-evidence/<candidate>/transition-rehearsal.json` and lands it with `just land`.

Each run lives in `~/.local/state/nagare/releases/vX.Y.Z/<time>/`, with the attachments in `dist/`;
`latest` points to the last completed run. `--rehearsal` runs steps 1 to 6 for a tagged or
unreleased revision, leaves the intranet alone, lands nothing and never moves `latest`.

**A defect found on the intranet keeps the version.** Land the fix and run
`just release-candidate X.Y.Z --revision NEW`: nothing is tagged yet, and the new candidate's plan
supersedes the idle open transition ([ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
2026-10-18 amendment). If a transaction is still active, the intranet step refuses; resume or close
it with the candidate that opened it first.

## Publish

`just release-publish X.Y.Z` publishes the `latest` run. Each step stops at its first failure:

1. **Preflight.** The run's `intranet.json` names this version and revision with an exact status,
   `SHA256SUMS` verifies in `dist/`, and the landed rehearsal record is byte-identical to the
   assembled one.
2. **Tag.** An annotated tag `vX.Y.Z` on the candidate, signed with Git's SSH backend and the
   maintainer's key (`~/.ssh/id_ed25519.pub`, or `NAGARE_RELEASE_SIGNING_KEY`), verified against a
   throwaway allowed-signers file. Never generate or register credentials during a release, and
   never fall back to an unsigned tag.
3. **Push.** Only the tag goes to `origin`.
4. **Publication.** From a checkout of the tag, the candidate's own CLI runs
   `nagarectl release publish --repo shinzui/nagare --version X.Y.Z --assets DIST --yes`, again up
   to five times while it reports "created draft is not yet visible".
5. **Public flake.** `nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json` reports
   `X.Y.Z` at the candidate revision.
6. **The tag pin.** The operator repository's input moves from the revision to the tag, which
   resolves to the same commit: `chore(nagare): pin the intranet to the published vX.Y.Z tag`,
   `flake.nix` and `flake.lock` only.

A rerun after a failure accepts the tag it already made, locally and on `origin`, as long as it is
the same signed object on the candidate. The operator's passkey login is not a release step; it
confirms the release afterwards.

The attachments are `nagare-release-X.Y.Z.json`, `nagare-vX.Y.Z.md`, one `nix-output-<system>.json`
and one `clone-free-<system>.json` per supported system,
`nagare-transition-rehearsal-vX.Y.Z.json`, `nagare-platform-metadata-vX.Y.Z.json` (the candidate's
`release.json`) and `SHA256SUMS`.

## Broken release or failed publication

Never move, delete, or reuse a published tag, and never overwrite its attachments. These are the
reproducible identities of existing operator pins.

- If anything fails before the tag, land the fix and run the candidate again at the same version.
- If only publication failed and the tagged source is unchanged, rerun `just release-publish X.Y.Z`.
- If a published release is unsafe, edit its GitHub release description to lead with
  **Deprecated**, explain the impact, and point to the retained prior version or a fixed later
  release. Do not describe this as deleting or yanking the Nix input.
- Operators remain pinned until they deliberately select another tagged CLI and complete the staged
  [per-context upgrade](../user/upgrades.md). An incomplete transaction leaves the old context pin
  intact and is resumed by transaction identifier.
- Automated rollback is used only when target metadata permits it and the old payload workspace is
  retained. Stateful recovery follows the [disaster-recovery runbook](disaster-recovery.md); release
  selection does not restore application data.

Publication itself never changes a context or cluster; the candidate run moves the intranet before
it. This boundary is recorded in
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md).
