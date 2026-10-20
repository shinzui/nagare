---
name: nagare-release
description: Prepare, run, publish, or recover a Nagare platform release as an immutable Nix flake tag and GitHub Release. Use when a release must be cut, a candidate run or publication must be started or recovered, or a release's state must be read; do not use for application deployments or per-context platform upgrades outside a release.
metadata:
  display_name: "Nagare Release"
  short_description: "Prepare and publish Nagare platform releases"
  default_prompt: "Use $nagare-release to prepare and publish the next Nagare platform release."
---

# Nagare Release

Read `docs/runbooks/releases.md` first; it is the procedure, and this skill does not repeat it.

A release proves three things: the full gate is green, the upgrade rehearsal on a disposable local
context reads its seeded row back unchanged, and the intranet runs the candidate. Nothing else is a
release step: no native smokes, README or user-doc version edits, capability records or extra
validators.

1. **Prepare.** One commit, `chore(release): prepare vX.Y.Z`: `release.json` (`platformVersion`,
   `transitionsFrom`) and `docs/releases/vX.Y.Z.md` plus its link in `CHANGELOG.md`. Choose the
   version from the changes since the last tag; a pre-1.0 break needs the maintainer's decision.
   `just gate-fast && just land HEAD`.
2. **Candidate.** When the landed commit's full gate is green: `just release-candidate X.Y.Z`. It
   runs unattended, moves the intranet under the operator's standing go-ahead, and asks nothing.
3. **Publish.** `just release-publish X.Y.Z`: the signed tag, the push, the GitHub release, the
   public flake check, the tag pin in the operator repository.

The release boundary ([ADR 7](../../../docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md)):
a published tag and its attachments are never moved, reused or deleted. Before the tag, a failure
keeps the version: land the fix and run the candidate again with `--revision`. After it, an unsafe
release is marked **Deprecated** in its GitHub description and a fixed release follows.

When a step refuses, stop and report it with the run directory
(`~/.local/state/nagare/releases/vX.Y.Z/<time>/`) and the failing log; never work around a guard.
