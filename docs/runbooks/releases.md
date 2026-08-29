# Publishing and recovering Nagare releases

This runbook is for maintainers. Nagare releases are immutable Nix flake tags; publication validates
and describes an existing tag but never creates a version commit, moves a tag, or operates a cluster.

## Prepare a candidate

1. Choose an unpadded semantic version `X.Y.Z` and update root `release.json`, all three Cabal package
   versions, `CHANGELOG.md`, and `docs/releases/vX.Y.Z.md` in one reviewed Conventional Commit.
2. Verify compatibility metadata and migration/rollback claims. A release must not claim automated
   rollback from a version unless the reverse transaction is tested and listed in `release.json`.
3. On a clean committed candidate, run:

   ```bash
   ./scripts/check-release.sh --version X.Y.Z --json
   ./scripts/rehearse-clone-free-release.sh --version X.Y.Z
   nix flake check --print-build-logs
   ```

The first command checks source and built identities and writes deterministic attachments. The second
uses an exact `git+file` revision from outside the checkout with an isolated home/XDG tree. It covers
version, context, external typed configuration, payload resolution, host generation, and local/cloud
dry runs. CI repeats the rehearsal natively on every system in `release.json`.

## Rehearse CI without publishing

Run the GitHub `Release` workflow manually with the candidate version. Manual dispatch has read-only
repository permission, builds the Linux and Apple Silicon outputs, uploads one artifact per native
system, and cannot enter the publish job. Download the two artifacts and assemble them locally:

```bash
./scripts/assemble-release.sh \
  --version X.Y.Z \
  --input-root native-artifacts \
  --output-dir dist
```

Confirm the shared manifest and notes were byte-identical, both native output manifests are present,
and `sha256sum -c dist/SHA256SUMS` (or `shasum -a 256 -c`) succeeds.

## Publish

After review, a maintainer explicitly creates and pushes the signed annotated tag:

```bash
git tag -s vX.Y.Z -m 'Nagare vX.Y.Z'
git push origin vX.Y.Z
```

The default command uses Git's configured signing backend. When OpenPGP is unavailable but the
maintainer already has a usable SSH signing key, use Git's SSH backend for the tag instead:

```bash
git -c gpg.format=ssh -c user.signingkey=/path/to/key.pub \
  tag -s vX.Y.Z -m 'Nagare vX.Y.Z'
```

Before pushing, verify that the ref is an annotated `tag`, resolves to the reviewed commit, and has a
good signature. SSH verification requires an allowed-signers file that maps the maintainer's email to
the existing public key; create it outside the repository and pass it with
`-c gpg.ssh.allowedSignersFile=/path/to/allowed_signers`. Do not generate or register credentials as
part of a release run, and never fall back to an unsigned tag.

The tag workflow reruns the normal flake checks, release gate, native builds, and clone-free rehearsal.
Only its final job receives `contents: write`. It creates the GitHub release from the reviewed notes
and attaches:

- `nagare-release-X.Y.Z.json`;
- `nagare-vX.Y.Z.md`;
- `nix-output-x86_64-linux.json` and `nix-output-aarch64-darwin.json`;
- `clone-free-x86_64-linux.json` and `clone-free-aarch64-darwin.json`;
- `SHA256SUMS`.

Verify the release page, checksums, manifest revision, native systems, and the documented command
`nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json`. A rerun accepts an existing
release only when every attachment is byte-identical; any difference requires investigation and a
new semantic version.

## Broken release or failed publication

Never move, delete, or reuse a published tag, and never overwrite its attachments. These are the
reproducible identities of existing operator pins.

- If CI fails before publication because source is inconsistent, fix the source and choose a new
  version. Do not move the candidate tag after others may have fetched it.
- If only external CI infrastructure failed and the tagged source is unchanged, rerun the workflow.
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
