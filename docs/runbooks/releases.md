# Publishing and recovering Nagare releases

This runbook is for maintainers. Nagare releases are immutable Nix flake tags; publication validates
and describes an existing tag but never creates a version commit, moves a tag, or operates a cluster.

## Prepare a candidate

1. Choose an unpadded semantic version `X.Y.Z` and update root `release.json`, all three Cabal package
   versions, the compatibility fixture in `cli/nagarectl/test/PlatformSpec.hs`, `CHANGELOG.md`, the
   README status, and `docs/releases/vX.Y.Z.md` in one Conventional Commit,
   `chore(release): prepare vX.Y.Z`.
2. Check the compatibility claims. `transitionsFrom` lists the releases an installed context may move
   from. Do not claim rollback from a version unless the reverse transaction is tested and listed in
   `rollbackSupportedFrom`.
3. Run `./scripts/check-release.sh --version X.Y.Z --source-only` and `just docs-validate`, then
   `just gate-fast` and `just land <candidate>`. The land starts the candidate's full gate in the
   background.

## Prove the candidate

A release proves three things (operator, 2026-10-10): the release gate is green, the EP-172 upgrade
rehearsal on a disposable local context reads its seeded data back unchanged, and the real intranet
context upgrades to the candidate and passes the deploy-and-login check. A release counts when the
intranet runs it, not when a tag exists.

1. **Release gate.** When the candidate's full gate is green, run `just gate-release <candidate>`. It
   runs the mutation sweep, then, if recovery-related code changed since the last green deep run, the
   deep tier, on the builder. The deep tier fails only on a violation class the known-defect ledger
   does not list. Triage each one into a fix or a ledger entry before going on.
2. **Upgrade rehearsal.** Build the candidate's CLI (`nix build --no-link --print-out-paths
   .#nagarectl`) and the previous release's (`nix build --no-link --print-out-paths
   github:shinzui/nagare/vPREVIOUS#nagarectl`). Then run
   [`scripts/transition-rehearsal.sh`](../../scripts/transition-rehearsal.sh) inside
   `nix develop` with `NAGARE_REHEARSAL_SOURCE` and `NAGARE_REHEARSAL_TARGET` set to their
   `bin/nagarectl`, `DOCKER_HOST` and `NAGARE_REHEARSAL_IMAGE_DAEMON` set to a Docker daemon whose
   VM can resolve public names, `NAGARE_REHEARSAL_RESET=1` and a fresh `NAGARE_REHEARSAL_ROOT`.
   It writes `evidence/transition-rehearsal.json` under that root. Commit that one file as
   `docs/release-evidence/<candidate-40-character-revision>/transition-rehearsal.json` after the
   candidate, and land it. Never change the candidate to embed evidence about itself.
3. **The intranet.** In the operator repository (`mori://tan/tan-ng-labs`), pin the Nagare flake
   input to the candidate's exact revision. Then follow the release notes' upgrade steps:
   `platform transition plan --out DIR`, `inventory apply DIR --yes`, and a new plan until the
   review has no operations, then `platform transition commit --yes`. Check `platform status` is exact, that protected sites
   still require login, and that the operator's passkey login works. The open transition binds the
   candidate's payload, which is derived from its revision. So once the intranet starts, the tag
   must go on that same commit; a fix found mid-transition goes into the next release.

## Build and assemble the attachments

Each system in `release.json` builds its own attachments from the candidate with
[`scripts/release-native.sh`](../../scripts/release-native.sh) `X.Y.Z OUTPUT_DIR`. The script runs
the release gate's built checks (`check-release.sh`), records the native output identities, and runs
the clone-free rehearsal from an exact `git+file` revision in an isolated home.

- **aarch64-darwin:** in a clean worktree of the candidate, run
  `scripts/release-native.sh X.Y.Z native/aarch64-darwin`.
- **x86_64-linux:** run the same script natively in an amd64 `nixos/nix` container, on a Colima
  profile with Rosetta and 16 GiB of memory whose VM can resolve public names. Prepare a work
  directory first: build the x86 outputs on the builder with `nix build --no-link
  --print-out-paths --max-jobs 0 .#packages.x86_64-linux.{nagarectl,nagare,nagare-platform,release-tools}`,
  copy them into a file cache with `nix copy --to file://WORK/cache`, and write the candidate to
  `WORK/candidate.bundle` with `git bundle create`. Then run:

  ```bash
  docker run --rm --platform linux/amd64 -v WORK:/work -v "$PWD/scripts:/scripts" nixos/nix:2.35.2 \
    bash /scripts/release-native-container.sh CANDIDATE_REVISION X.Y.Z
  ```

  Its attachments land in `WORK/out/x86_64-linux`.

Put both systems' outputs under one input root and assemble twice:

```bash
./scripts/assemble-release.sh \
  --version X.Y.Z \
  --input-root native \
  --transition-rehearsal docs/release-evidence/CANDIDATE_REVISION/transition-rehearsal.json \
  --output-dir dist
```

The two assemblies must be byte-identical, and `shasum -a 256 -c SHA256SUMS` must pass from inside
`dist`. Assembly and the publisher require every supported system's native output and clone-free
rehearsal, the platform metadata, and a rehearsal record bound to this candidate's version and
revision. That record must show a move from a release in `transitionsFrom`, the seeded row read back
unchanged, at least one transition review applied, and the CLI, payload, context and cluster ending
on the candidate with no open transaction. A record for another candidate or a changed outcome fails
even when the checksums were recomputed.

## Publish

Create the signed annotated tag on the candidate commit, verify it, and push only the tag:

```bash
git tag -s vX.Y.Z -m 'Nagare vX.Y.Z' CANDIDATE_REVISION
git push origin vX.Y.Z
```

When OpenPGP is unavailable but the maintainer already has a usable SSH signing key, use Git's SSH
backend: `git -c gpg.format=ssh -c user.signingkey=/path/to/key.pub tag -s ...`. Before pushing,
check that the ref is an annotated `tag`, resolves to the candidate, and has a good signature. SSH
verification needs an allowed-signers file outside the repository that maps the maintainer's email to
the public key, passed with `-c gpg.ssh.allowedSignersFile=...`. Never generate or register
credentials during a release, and never fall back to an unsigned tag.

From a checkout of the tag, publish with the candidate's own CLI:

```bash
nagarectl release publish --repo shinzui/nagare --version X.Y.Z --assets dist --yes
```

The publisher checks the tag and every attachment, creates the GitHub release from the reviewed
notes, and attaches:

- `nagare-release-X.Y.Z.json`;
- `nagare-vX.Y.Z.md`;
- `nix-output-x86_64-linux.json` and `nix-output-aarch64-darwin.json`;
- `clone-free-x86_64-linux.json` and `clone-free-aarch64-darwin.json`;
- `nagare-transition-rehearsal-vX.Y.Z.json`, the candidate-bound EP-172 rehearsal record;
- `nagare-platform-metadata-vX.Y.Z.json`, the candidate's `release.json`;
- `SHA256SUMS`.

If it stops with "created draft is not yet visible", run the same command again: a rerun completes
the draft, and it accepts an existing release only when every attachment is byte-identical. Then
verify the release page and the documented command
`nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json`, and switch the operator
repository's flake input from the revision to the tag, which resolves to the same commit.

## Broken release or failed publication

Never move, delete, or reuse a published tag, and never overwrite its attachments. These are the
reproducible identities of existing operator pins.

- If a gate fails before publication because the source is inconsistent, fix the source and choose a
  new version. Do not move the candidate tag after others may have fetched it.
- If only publication failed and the tagged source is unchanged, rerun `nagarectl release publish`.
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
