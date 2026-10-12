# Publishing and recovering Nagare releases

This runbook is for maintainers. Nagare releases are immutable Nix flake tags; publication validates
and describes an existing tag but never creates a version commit, moves a tag, or operates a cluster.

## Prepare a candidate

1. Choose an unpadded semantic version `X.Y.Z` and update root `release.json`, all three Cabal package
   versions, the compatibility fixture in `cli/nagarectl/test/PlatformSpec.hs`, `CHANGELOG.md`, the
   README status, and `docs/releases/vX.Y.Z.md` in one Conventional Commit,
   `chore(release): prepare vX.Y.Z`.
2. Check the compatibility claims. `transitionsFrom` lists the releases an installed context may move
   from; it must include the release the intranet runs, and its newest entry is the release the
   upgrade rehearsal starts from. Do not claim rollback from a version unless the reverse transaction is tested and listed in
   `rollbackSupportedFrom`.
3. Run `./scripts/check-release.sh --version X.Y.Z --source-only` and `just docs-validate`, then
   `just gate-fast` and `just land <candidate>`. The land starts the candidate's full gate in the
   background.

## Prove and assemble the candidate

A release proves three things (operator, 2026-10-10): the release gate is green, the EP-172 upgrade
rehearsal on a disposable local context reads its seeded data back unchanged, and the real intranet
context upgrades to the candidate and passes the deploy-and-login check. A release counts when the
intranet runs it, not when a tag exists.

When the candidate's full gate is green, run on the aarch64-darwin workstation, with the builder up:

```bash
just release-candidate X.Y.Z            # the candidate is HEAD; --revision REV names another
```

It runs unattended up to the tag. Each step stops at its first failure and nothing is retried:

1. **Preflight.** `release.json` at the candidate says `X.Y.Z` and names both systems, the candidate
   is on `origin/master`, `vX.Y.Z` is not tagged, and the newest version in `transitionsFrom` is a
   published tag. That version is the rehearsal's source.
2. **Release gate.** `just gate-release <candidate>`: the gate record, the mutation sweep, then the
   deep tier if recovery-related code changed since the last green deep run. The deep tier fails
   only on a violation class the known-defect ledger does not list. Triage each one into a fix or a
   ledger entry, then run the command again.
3. **Upgrade rehearsal.** `just release-rehearse <candidate> <previous>` writes
   `docs/release-evidence/<candidate-40-character-revision>/transition-rehearsal.json`. Until
   MasterPlan 26 item 12 lands, the recipe only accepts a record that is already there: build the
   candidate's CLI (`nix build --no-link --print-out-paths .#nagarectl`) and the previous
   release's (`github:shinzui/nagare/vPREVIOUS#nagarectl`), run
   [`scripts/transition-rehearsal.sh`](../../scripts/transition-rehearsal.sh) inside `nix develop`
   with `NAGARE_REHEARSAL_SOURCE` and `NAGARE_REHEARSAL_TARGET` set to their `bin/nagarectl`,
   `DOCKER_HOST` and `NAGARE_REHEARSAL_IMAGE_DAEMON` set to a Docker daemon whose VM can resolve
   public names, `NAGARE_REHEARSAL_RESET=1` and a fresh `NAGARE_REHEARSAL_ROOT`, and copy its
   `evidence/transition-rehearsal.json` to that path.
4. **aarch64-darwin attachments.** [`scripts/release-native.sh`](../../scripts/release-native.sh)
   in a clean worktree of the candidate: the release gate's built checks (`check-release.sh`), the
   native output identities, and the clone-free rehearsal from an exact `git+file` revision in an
   isolated home.
5. **x86_64-linux attachments.** The x86 outputs are built on the builder and copied into a file
   cache under `~/.local/state/nagare/releases/x86-work`, which persists across releases. The
   Colima profile `nagare-c4-amd64` is started with 4 CPUs, 16 GiB, Rosetta and that directory as
   its only mount, and those settings are read back, because a restart can rewrite `colima.yaml`.
   The VM's resolver is set to public servers and checked. Then
   [`scripts/release-native-container.sh`](../../scripts/release-native-container.sh) runs the
   same native script in an amd64 `nixos/nix:2.35.2` container. If the profile is already running
   with other settings, the command refuses: stop the profile and run it again.
6. **Assembly.** [`scripts/assemble-release.sh`](../../scripts/assemble-release.sh) runs twice. The
   two outputs must be byte-identical, and `SHA256SUMS` must verify. Assembly requires every
   supported system's native output and clone-free rehearsal, the platform metadata, and a
   rehearsal record bound to this candidate's version and revision. That record must show a move
   from a release in `transitionsFrom`, the seeded row read back unchanged, at least one transition
   review applied, and the CLI, payload, context and cluster ending on the candidate with no open
   transaction. A record for another candidate, or a changed outcome, fails even when the checksums
   were recomputed.
7. **Evidence.** The rehearsal record is committed on top of `origin/master` and landed with
   `just land`. It is inert documentation, so it carries the gated ancestor's record. The candidate
   never embeds evidence about itself.

Each run lives in `~/.local/state/nagare/releases/vX.Y.Z/<time>/`, with the attachments in `dist/`;
`latest` points to the last completed run. `--rehearsal` runs every step for a tagged or unreleased
revision, lands nothing and never moves `latest`, so `release-publish` cannot use it.

## The intranet

Choosing when the intranet upgrades stays manual. In the operator repository
(`mori://tan/tan-ng-labs`), pin the Nagare flake input to the candidate's exact revision. Then follow
the release notes' upgrade steps: `platform transition plan --out DIR`, `inventory apply DIR --yes`,
and a new plan until the review has no operations, then `platform transition commit --yes`. Check
`platform status` is exact, that protected sites still require login, and that the operator's
passkey login works. The open transition binds the candidate's payload, which is derived from its
revision. So once the intranet starts, the tag must go on that same commit; a fix found
mid-transition goes into the next release.

## Publish

```bash
just release-publish X.Y.Z
```

It publishes the `latest` run of `just release-candidate X.Y.Z`. Each step stops at its first
failure:

1. **Preflight.** `SHA256SUMS` verifies in the run's `dist/`, and the landed rehearsal record on
   `origin/master` is byte-identical to the assembled one.
2. **Tag.** An annotated tag `vX.Y.Z` on the candidate, signed with Git's SSH backend and the
   maintainer's key (`~/.ssh/id_ed25519.pub`, or `NAGARE_RELEASE_SIGNING_KEY`). Signing stays with
   the maintainer: the key's passphrase or agent is theirs. The tag must resolve to the candidate and
   verify against a throwaway allowed-signers file that maps `git config user.email` to that key.
   Never generate or register credentials during a release, and never fall back to an unsigned tag.
3. **Push.** Only the tag goes to `origin`.
4. **Publication.** From a checkout of the tag, the candidate's own CLI runs
   `nagarectl release publish --repo shinzui/nagare --version X.Y.Z --assets DIST --yes`. When it
   stops with "created draft is not yet visible", it is run again, up to five times: a rerun
   completes the draft, and it accepts an existing release only when every attachment is
   byte-identical. Any other failure stops.
5. **Public flake.** `nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json` must report
   `X.Y.Z` at the candidate revision.

A rerun after a failure accepts the tag it already made, locally and on `origin`, as long as it is
the same signed object on the candidate. Afterwards, switch the operator repository's flake input
from the revision to the tag, which resolves to the same commit.

The publisher checks the tag and every attachment, creates the GitHub release from the reviewed
notes, and attaches:

- `nagare-release-X.Y.Z.json`;
- `nagare-vX.Y.Z.md`;
- `nix-output-x86_64-linux.json` and `nix-output-aarch64-darwin.json`;
- `clone-free-x86_64-linux.json` and `clone-free-aarch64-darwin.json`;
- `nagare-transition-rehearsal-vX.Y.Z.json`, the candidate-bound EP-172 rehearsal record;
- `nagare-platform-metadata-vX.Y.Z.json`, the candidate's `release.json`;
- `SHA256SUMS`.

## Broken release or failed publication

Never move, delete, or reuse a published tag, and never overwrite its attachments. These are the
reproducible identities of existing operator pins.

- If a gate fails before publication because the source is inconsistent, fix the source and choose a
  new version. Do not move the candidate tag after others may have fetched it.
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

Publication itself never changes a context or cluster. This boundary is recorded in
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md).
