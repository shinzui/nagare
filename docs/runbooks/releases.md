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
# 1. the bump: release.json (version, then the images) and docs/releases/vX.Y.Z.md, one commit
scripts/harness.sh release images prepare
just gate-fast && just land HEAD
# 2. on a workstation with Colima (or an empty Docker daemon) and the x86_64-linux builder
just release-candidate X.Y.Z      # --revision REV names another candidate
# 3.
just release-publish X.Y.Z
```

Each step of the candidate can run alone and a rerun continues where the run stopped, so a step that
fails is fixed and rerun without repeating the steps before it. The run works in its own worktree,
so the operator keeps working and landing beside it.

## Prepare a candidate

Choose an unpadded semantic version `X.Y.Z` and commit `chore(release): prepare vX.Y.Z` with two
files:

- `release.json`: `platformVersion`, and `transitionsFrom`, the releases an installed context may
  move from. It must include the release the intranet runs; its newest entry is the release the
  rehearsal starts from. Claim rollback in `rollbackSupportedFrom` only for a tested reverse
  transaction. Then `releaseImages`, the service images and the tunnel connector (EP-237): set the version first and
  run `scripts/harness.sh release images prepare` on that tree. It builds the En, Shōmei,
  nagare-access and admin API images on the x86_64-linux builder
  (`.#packages.x86_64-linux.release-image-*`, from [`nix/release-images.nix`](../../nix/release-images.nix))
  and writes each image's manifest digest and OCI layout store path into the file;
  `.#packages.x86_64-linux.release-images-check` fails while the file and the images disagree.
  Any later change to the Haskell sources or the auth pins needs prepare again before the candidate
  runs. The images are not in the payload: both systems' payloads carry the digests in their copy
  of `release.json`, and each context publishes the images into its own registry when it upgrades.
  An image whose inputs did not change keeps its digest, so an upgrade leaves it alone; the admin
  API links `nagare-core`, not `nagarectl`, so a CLI-only change leaves it alone too.
- `docs/releases/vX.Y.Z.md`: the notes, beginning `# Nagare X.Y.Z`, and the changelog entry
  (add its link to `CHANGELOG.md`). Validation is one sentence: the three proofs passed.

`release.json` is the only place the version is written: `nagarectl` embeds it at compile time and
the Cabal package versions stay `0.0.0`. The notes are not a gate input, so a wording fix after the
bump lands with its ancestor's gate record and `release-candidate --revision` accepts it.

## The candidate run

`just release-candidate X.Y.Z` runs up to the tag. It is `nagare-harness release candidate`
([`Release/Candidate.hs`](../../cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs));
`scripts/release-candidate.sh`, `release-rehearse.sh`, `transition-rehearsal.sh` and
`release-intranet.sh` only `exec` harness commands, and no step starts a Python interpreter. Every
decision reads a document nagarectl writes.

A run belongs to one version and revision: `~/.local/state/nagare/releases/vX.Y.Z/<revision>/`, or
`--run DIR`. Its first act is to write `candidate.json` (version, revision and the previous release),
and a run directory that names another candidate refuses. A rerun keeps every step whose result the
run already holds and runs the rest; `index.json` lists each invocation's steps as `passed`,
`failed` or `kept`. The steps, each stopping at its first failure:

1. **Preflight.** `release.json` at the candidate says `X.Y.Z`, the notes begin `# Nagare X.Y.Z`,
   the candidate is on `origin/master`, `vX.Y.Z` is not tagged, and the newest version in
   `transitionsFrom` is a published tag. A release with images also needs `CACHIX_AUTH_TOKEN`, and
   refuses while the operator shell still exports `NAGARE_AUTH_EN_IMAGE`, `NAGARE_AUTH_SHOMEI_IMAGE`,
   `NAGARE_AUTH_ACCESS_IMAGE` or `NAGARE_ADMIN_API_IMAGE`, because that pin would stop the intranet
   step after the transition applied.
2. **Landing check.** `just gate-verify <candidate>`: the landed commit's green full-gate record. On
   a machine without that record the candidate runs `just gate <candidate>` itself, in the
   background beside steps 3 and 4, and waits for a green record before the intranet. The mutation
   sweep and the deep tier are not release steps (operator, 2026-11-20).
3. **Release images** (EP-237), when `release.json` names them: the layouts are built from the
   candidate on the builder and must have the digests and store paths its `release.json` names, or
   the run refuses before anything is pushed. They are pushed to `shinzui.cachix.org` and read back.
   `images/release-images.json` is the receipt; a rerun keeps it.
4. **Upgrade rehearsal** (log `rehearsal.log`). `nagare-harness transition rehearse` builds the
   previous release's packaged `nagarectl` and the candidate's and runs the transition drill
   ([`scripts/transition-rehearsal.sh`](../../scripts/transition-rehearsal.sh)) from an empty
   environment whose PATH has no Helm and no Python. It creates a Colima profile for the run
   (`nagare-rehearsal-<time>`, with Rosetta and answering resolvers) and deletes it afterwards,
   whatever the outcome; `NAGARE_REHEARSAL_DOCKER_HOST` names an empty daemon to use instead, which
   it never deletes. The drill refuses a daemon that already holds a k3d cluster or registry
   forward, publishes the local MinIO images with
   [`scripts/publish-local-minio-images.sh`](../../scripts/publish-local-minio-images.sh) into its
   own registry, and forwards that registry on the first free loopback port from 15213. The record
   `transition-rehearsal.json` names the candidate and the release it moved from; a rerun keeps it.
5. **The intranet**, under the operator's standing go-ahead. `nagare-harness transition run`
   ([`scripts/release-intranet.sh`](../../scripts/release-intranet.sh)) pins the operator
   repository (`mori://tan/tan-ng-labs`, or `NAGARE_RELEASE_OPERATOR_REPO`) to the candidate
   revision, plans and applies the platform transition through that repository's dev shell until a
   plan has no operations, resuming an ambiguous stop once, and commits the transition. A rerun
   first resumes the transaction the run left open, so recovery from a stop is the same command
   again. It requires an exact platform status on the candidate, every accepted scope converged and
   the protected URL answering 302 to the login page. An application's own scope or deploy hook
   scope (`Standalone/app-hook-…`) that has not converged is reported and does not block. Then it commits the pin files by path,
   `feat(nagare): upgrade the intranet to the vX.Y.Z candidate`, and writes `intranet.json`. It
   records the git blob of every pin file it changes in `intranet/pins.json`; a rerun continues
   only while each changed pin file holds what the run left, and any other change (an edit beside
   the pin in `flake.nix`, say) refuses, naming the file, and stays in the working tree. It never
   edits app config: a config the candidate does not compile stops the plan with the compiler's
   message, and the fix is the operator's. It never takes over fields either: when a platform
   object was changed by hand (`kubectl patch`, `edit`, `annotate`), the first plan refuses,
   naming each object, writer and field, before any stage is applied. Declare the change, or
   rerun with `just release-candidate X.Y.Z --take-over-fields`, which plans every stage with
   that opt-in and records it in each stage's entry of `intranet-index.json`; see
   [Repair configuration drift](inventory-operations.md#repair-configuration-drift).

`--rehearsal` runs steps 1 to 4 for a tagged or unreleased revision in
`releases/vX.Y.Z/rehearsal-<revision>/` and leaves the intranet alone.

**A defect found on the intranet keeps the version.** Land the fix and run
`just release-candidate X.Y.Z --revision NEW`: nothing is tagged yet, the new revision gets its own
run, and its plan supersedes the idle open transition ([ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
2026-10-18 amendment). If a transaction is still active, the intranet step refuses; resume or close
it with the candidate that opened it first.

## Publish

`just release-publish X.Y.Z` is `nagare-harness release publish`
([`Release/Publish.hs`](../../cli/nagare-harness/src/Nagare/Harness/Release/Publish.hs)). It
publishes the tagged commit's run, or the only run of this version that moved the intranet, or
`--run DIR`. Each step stops at its first failure:

1. **Proofs, before anything is written.** `candidate.json` names this version; the candidate is on
   `origin/master`; `release.json` at the candidate says `X.Y.Z` and accepts the previous release,
   which is a published tag; `transition-rehearsal.json` moved that release to this revision and
   read its seeded row back; `intranet.json` shows the context exact on this version and revision;
   the notes begin `# Nagare X.Y.Z`; the signing key exists. Each image is pinned in the cache as
   `nagare-vX.Y.Z-<image>`, so garbage collection never evicts a released image.
2. **Tag.** An annotated tag `vX.Y.Z` on the candidate, signed with Git's SSH backend and the
   maintainer's key (`~/.ssh/id_ed25519.pub`, or `NAGARE_RELEASE_SIGNING_KEY`), verified against an
   allowed-signers file in the run. Never generate or register credentials during a release, and
   never fall back to an unsigned tag.
3. **Review.** From a checkout of the tag, the candidate's own CLI runs
   `nagarectl release publish --repo shinzui/nagare --version X.Y.Z --assets <run>/assets` without
   `--yes`: it validates the rehearsal record against the tag's `release.json` and prints the
   reviewed bytes. A refusal stops here, before the tag leaves the machine.
4. **Push.** Only the tag goes to `origin`.
5. **Publication.** The same command with `--yes`, again up to five times while it reports
   "created draft is not yet visible".
6. **Public flake.** `nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json` reports
   `X.Y.Z` at the candidate revision.
7. **The tag pin.** The operator repository's input moves from the revision to the tag, which
   resolves to the same commit: `chore(nagare): pin the intranet to the published vX.Y.Z tag`,
   `flake.nix` and `flake.lock` only.

A rerun after a failure accepts the tag it already made, locally and on `origin`, as long as it is
the same signed object on the candidate. The operator's passkey login is not a release step; it
confirms the release afterwards.

A release is its signed tag and two attachments: the notes, `nagare-vX.Y.Z.md`, and the rehearsal
record, `nagare-transition-rehearsal-vX.Y.Z.json`. The release description binds both by digest.

## Broken release or failed publication

Never move, delete, or reuse a published tag, and never overwrite its attachments. These are the
reproducible identities of existing operator pins.

- If a step fails for a reason outside the candidate, fix it and rerun the same command: the run
  keeps the steps it finished.
- If the candidate itself is wrong, land the fix and run the candidate again at the same version.
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

## Images and the cache

Nothing is published to GitHub. Export `CACHIX_AUTH_TOKEN` for `shinzui.cachix.org` before a candidate
that names images; the harness never reads, passes or records it. The cache is public, so an image
must hold no secret. Operators need no credential or cache configuration to fetch: `nagarectl` fetches
a layout into a private store only when the context's registry lacks that image, then checks it
against the reviewed digest. A cache miss or a wrong layout refuses before any registry change and
never compiles.

The transition rehearsal runs these linux/amd64 images, so its Colima profile is created with
Rosetta; a daemon named by `NAGARE_REHEARSAL_DOCKER_HOST` needs amd64 emulation that is not qemu.
Under qemu the Shōmei migration exceeds its 128 MiB limit (it peaks near 21 MiB natively) and the
rehearsal stops at that Job.

For an unreleased candidate, the auth images can still be built
with `cluster/bootstrap/auth-images/build-local-image.sh` (Cloud Build in a cloud context) and named
with the override variables in [cluster bootstrap](../user/cluster-bootstrap.md).

Publication itself never changes a context or cluster; the candidate run moves the intranet before
it. This boundary is recorded in
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md).
