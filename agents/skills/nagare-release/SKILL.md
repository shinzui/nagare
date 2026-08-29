---
name: nagare-release
description: Prepare, audit, rehearse, publish, or recover a Nagare platform release as an immutable Nix flake tag and GitHub Release. Use when release work must keep Nagare's Haskell packages, Nix payload, Pulumi/NixOS/cluster assets, compatibility metadata, documentation, native-system evidence, and release notes consistent; do not use for application deployments or per-context platform upgrades.
metadata:
  display_name: "Nagare Release"
  short_description: "Prepare and publish Nagare platform releases"
  default_prompt: "Use $nagare-release to prepare and validate the next Nagare platform release."
---

# Nagare Release

Treat a Nagare release as one versioned platform distribution, not as a Hackage upload or a release
of `nagarectl` alone. The public identity is an immutable `vX.Y.Z` Git tag consumed through Nix. It
selects a matching CLI, typed-config runtime, operator launcher, and platform payload.

## Read the current contract

Before release work, read these repository-owned sources instead of relying on this skill for values
that may drift:

- `docs/runbooks/releases.md` for the maintainer procedure and recovery rules.
- `release.json` for the platform version, schema versions, supported systems, and rollback claims.
- `.github/workflows/release.yml` for the native build matrix, attachment set, and publication
  permissions.
- `scripts/check-release.sh`, `scripts/rehearse-clone-free-release.sh`, and
  `scripts/assemble-release.sh` for executable release invariants.
- `nix/platform-package.nix` and `nix/haskell-packages.nix` when the packaged closure or output names
  matter.

For publication or recovery, also read
`docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md`. Read
`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md` and
`docs/user/upgrades.md` when compatibility, adoption, migrations, or rollback claims are involved.

Use Mori to refresh the project inventory:

```bash
mori registry show shinzui/nagare --full
mori registry docs shinzui/nagare
```

For a changed dependency pin or compatibility workaround, use Mori to inspect its registered source
and documentation, then verify the current release against the authoritative package registry and
upstream release tags before choosing bounds or pins.

## Preserve the release boundary

- Publication validates and describes an existing candidate commit and tag. It does not choose a
  live context, run an upgrade transaction, apply Pulumi, switch a NixOS host, bootstrap Kubernetes,
  deploy an application, or restore data.
- Nagare's supported distribution channel is Nix-by-tag. The Cabal versions are consistency inputs;
  do not upload the Haskell packages to Hackage unless the user separately defines and authorizes a
  Hackage distribution contract.
- `release.json` is the source of truth for the platform version. The release gate requires it to
  match all three Cabal packages, the built CLI, packaged payload, compatibility fixture, changelog,
  and release notes.
- Nix injects the exact clean Git revision into built artifacts. Do not hand-write a source revision
  or release payload ID that should be derived during the build.
- A release is immutable after publication. Never move, reuse, or delete a published tag, and never
  replace different attachments under the same version.

## Select the operating phase

Determine whether the user wants an audit, candidate preparation, CI rehearsal, publication, or
recovery. Do only the requested phase and its safe prerequisites. When the user explicitly asks to
release or publish a version, treat that as one end-to-end operation: audit and prepare the candidate,
commit release fixes, run local and native gates, assemble evidence, create and push the signed tag,
monitor GitHub publication, and verify the public flake and attachments.

Do not pause an end-to-end release for routine confirmation between those stages. Keep the user
informed through concise progress updates and continue until the release is verified. Stop only for
a failed release gate, missing credentials or signing capability, conflicting immutable tag/release
state, an unresolved version or compatibility decision, unrelated worktree changes that cannot be
preserved, or another condition that makes publication unsafe. Diagnose a failed gate and prepare a
focused fix when it remains within the authorized release scope; do not bypass the gate.

- Read-only audits may run in a dirty worktree. Record pre-existing changes and do not attribute them
  to the release.
- Candidate preparation may edit release-owned files, but preserve unrelated user changes. Never
  stash, reset, discard, or fold unrelated edits into the release commit.
- A full rehearsal requires a clean, committed candidate so the revision is exact.
- Manual workflow dispatch, tag creation, tag push, release-description edits, and live smoke tests
  are external mutations. An explicit request to release or publish authorizes the normal mutations
  required by this runbook; a request only to audit, prepare, or rehearse does not.
- Tag creation is a deliberate maintainer action. Do not infer permission to sign or push a tag from
  a request to audit, prepare, or rehearse, but continue through it without another confirmation in
  an explicitly requested end-to-end release.

## Audit the candidate

Inspect the working tree, current branch, tags, GitHub releases, and changes since the last published
tag. If there is no published tag, treat the existing version marked `Unreleased` as the first
candidate; do not automatically bump it merely because no prior tag exists.

Analyze user-visible and operational changes across the whole platform:

1. `cli/nagare-dsl`, `cli/nagarectl`, and `cli/nagare-access`, including public config types and
   command behavior.
2. `infra/pulumi`, Nix inputs/outputs, `nixos`, host-generation behavior, and operator recipes.
3. `cluster/bootstrap`, `cluster/observability`, images, manifests, database migrations, secrets
   contracts, and bundled examples.
4. Payload schemas, context/host/cluster version identities, supported systems, and upgrade or
   rollback behavior.
5. User docs, runbooks, capability records, installation examples, and known limitations.

Classify compatibility and operational risk rather than inferring the bump solely from Conventional
Commit prefixes. Honor a user-selected version. Otherwise propose an unpadded SemVer `X.Y.Z` from
the diff and explain breaking changes, new capabilities, fixes, migrations, and unverified surfaces.
For a pre-1.0 breaking change, surface the break explicitly and obtain the maintainer's version
decision instead of silently treating it as a patch.

## Prepare one coherent candidate

Update the sources required by the current gate and the actual change set:

- Set `platformVersion` in `release.json` and the `version:` field in
  `cli/nagare-dsl/nagare-dsl.cabal`, `cli/nagarectl/nagarectl.cabal`, and
  `cli/nagare-access/nagare-access.cabal` to the same `X.Y.Z`.
- Cut the `CHANGELOG.md` entry with the release date and write
  `docs/releases/vX.Y.Z.md` for operators. Cover highlights, installation, supported systems,
  prerequisites, compatibility, migrations, rollback limits, known issues, and validation gaps.
- Update the version-specific compatibility fixture required by `scripts/check-release.sh` and any
  tests or generated host metadata affected by a schema change. Change schema-version fields only
  for an actual schema change.
- Review version-specific claims throughout `README.md`, `docs/user`, `docs/runbooks`, and
  `docs/capabilities`. Preserve historical `since` values; assign `X.Y.Z` only to capabilities first
  shipped in this release. Do not mechanically replace every older example version.
- Add a version to `rollbackSupportedFrom` only when the reverse release-selection transaction is
  tested and the notes explain what it does not restore. Release selection never restores
  application data.
- Keep `supportedSystems`, the flake outputs, the GitHub native runner matrix, assembly checks, and
  attachment names aligned. Adding a system requires native or trusted-runner evidence.

Before committing, run the source-only consistency check and the relevant documentation validators:

```bash
./scripts/check-release.sh --version X.Y.Z --source-only
just docs-validate
okf validate docs/capabilities --strict \
  --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities --json >/dev/null
mori validate
```

Show the proposed version, release notes, compatibility/rollback claims, and focused diff to the
user before making the candidate commit unless their request already approved those exact choices.
During an explicitly requested end-to-end release, present this as a progress update and continue
without pausing unless the change requires an unresolved version, compatibility, or scope decision.
Use one reviewed Conventional Commit, normally `chore(release): prepare vX.Y.Z`. Do not include
unrelated worktree changes.

## Validate a committed candidate

On a clean candidate commit, run the repository's exact gates:

```bash
nix flake check --print-build-logs
./scripts/check-release.sh --version X.Y.Z --json
./scripts/rehearse-clone-free-release.sh --version X.Y.Z
```

The local rehearsal proves only the current system. Require the GitHub `Release` workflow's manual,
non-publishing dispatch to pass for every system declared in `release.json`, then assemble and verify
the downloaded native artifacts as described in `docs/runbooks/releases.md`. Also require the normal
CI jobs for the candidate commit, including the separate `nagare-access` compatibility check.

Scale extra evidence to the diff:

- For typed config, rendering, build, or local bootstrap changes, run the relevant local smoke path
  when its prerequisites are available.
- For Pulumi, NixOS, cloud bootstrap, auth/data migrations, persistence, or disaster-recovery changes,
  prefer a disposable target rehearsal and verify backups or migration preconditions. Never select a
  live target implicitly.
- If a meaningful path cannot be exercised, record the gap and operational consequence in the
  release notes rather than claiming it passed.

Stop on any failed gate. Fixing a release inconsistency creates a new candidate commit; it never
justifies bypassing a check.

## Publish only an exact reviewed candidate

Immediately before publication, confirm the version, clean HEAD revision, candidate CI results,
release notes, supported-system evidence, and authorization to sign and push the tag. An explicit
request to release or publish supplies that authorization for the end-to-end workflow.
Then follow the runbook's exact signed annotated tag command and push only `vX.Y.Z` to `origin`.

Do not run a separate `gh release create`: the tag-triggered workflow reruns the gates and creates the
GitHub Release with minimal write permission. Monitor it through completion and verify:

- `nagare-release-X.Y.Z.json` names the tag, exact revision, and every supported system.
- `nagare-vX.Y.Z.md`, one native Nix output manifest and one clone-free rehearsal manifest per
  supported system, and `SHA256SUMS` are present.
- Every checksum passes and the attachments are the deterministic set assembled by the workflow.
- `nix run github:shinzui/nagare/vX.Y.Z#nagarectl -- version --json` reports the expected version and
  revision without a checkout.

Publication itself must leave every Nagare context and cluster unchanged.

## Recover without rewriting history

- If validation fails before publication, fix the source and choose a new version if the tag may
  already have been fetched. Do not move the candidate tag.
- If only external CI infrastructure failed and tagged source is unchanged, rerun the workflow.
- If an already published release is unsafe, mark its GitHub description `Deprecated`, explain the
  impact, and point to a retained prior or fixed later version. Keep the tag and assets intact.
- Direct operators to the staged per-context upgrade/rollback and disaster-recovery runbooks. Do not
  imply that selecting another release reverses stateful data changes.
