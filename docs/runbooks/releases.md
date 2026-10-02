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
dry runs. It also copies the documented `nix shell ...#nagare -c nagarectl platform upgrade` shape
into an environment with no ambient Pulumi, verifies the release supplies its operator tools, and
records a mutation-free reviewed preview. CI repeats the rehearsal natively on every system in
`release.json`.

## Rehearse CI without publishing

Seal the candidate commit before collecting local/cloud inventory evidence. Save only public
projected evidence under `docs/release-evidence/<candidate-40-character-revision>/`: `coverage.json`
and `local/` plus `cloud/`, each containing `target.json`, `<mode>-health.json`, and
`inventory-evidence.json`. Commit these results after the candidate; do not modify the candidate to
embed evidence about itself. Private exports, credentials and native plans remain outside this tree.

Run the GitHub `Release` workflow manually with the candidate version, `candidate_revision` and
`evidence_revision`, both exact 40-character commits. The evidence commit supplies the public tree;
all native builds and rehearsals use the candidate commit. Manual dispatch has read-only repository
permission and cannot enter the publish job. Omitting the evidence revision permits native artifact
collection but makes final assembly fail. Download the two native artifacts and assemble them locally:

```bash
./scripts/assemble-release.sh \
  --version X.Y.Z \
  --input-root native-artifacts \
  --inventory-evidence docs/release-evidence/CANDIDATE_REVISION \
  --output-dir dist
```

Confirm the shared manifest and notes were byte-identical, both native output manifests are present,
and checksums pass from inside `dist` (`sha256sum -c SHA256SUMS`, or `shasum -a 256 -c`).
Assembly and the checked publisher require a complete inventory index, its public input files,
exact supported/deferred command coverage, full native rehearsals, and both scenario modes bound to
the candidate payloads. The health assertions cover collision/adoption, drift, convergence/removal,
owner preservation, secret-read refusal, interrupted recovery, each supported database engine and
volume backup/restore, source-unavailable recovery, freshness, retained data and access. Local proof
also covers retained PostgreSQL rename; cloud proof covers shared-history takeover and Google CDN.
Reuse of engine evidence follows the scenario plans' declared transport boundary; an assertion must
point to actual accepted proof. Missing assertions or changed identities fail even when checksums
have been recomputed. A healthy fixture alone is insufficient.

Foundation release acceptance does not approve critical intranet adoption: that also requires the
supported inventory upgrade/recovery gate, the agreed one-hour recovery-point objective, and agreed
recovery-time and retention targets. Preserve those limits in the production handoff.

## Publish

After review and explicit publication authorization, configure repository variable
`NAGARE_INVENTORY_EVIDENCE_REVISION` to the exact reviewed evidence commit. From the sealed candidate
commit, a maintainer explicitly creates and pushes the signed annotated tag:

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
- `nagare-inventory-evidence-vX.Y.Z.json`, the candidate-bound aggregate index;
- `nagare-platform-metadata-vX.Y.Z.json`, `inventory-coverage.json`, and both scenarios’
  `inventory-{local,cloud}-{target,health,evidence}.json` public inputs;
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
