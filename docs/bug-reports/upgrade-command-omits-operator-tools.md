---
type: Bug Report
title: The documented release-upgrade command omits the operator toolchain
description: >-
  The 0.3.0 upgrade runbook invokes the target release through #nagarectl, whose
  unwrapped CLI cannot find Pulumi, so a cloud upgrade fails before preview.
generated:
  by: process:openai-codex
  at: "2026-09-15T13:52:11Z"
bugId: BUG-1
status: confirmed
severity: degraded
origin: mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use
affects: mori://shinzui/nagare/packages/nagarectl
capability: mori://shinzui/nagare/okf/capabilities/concepts/CAP-19
affectedVersion: 0.3.0
environment: macOS operator workstation with Nix and no ambient Pulumi
observed: >-
  The exact documented nix run command fails with "pulumi was not found on PATH"
  while reading gcp:project, before the reviewed infrastructure preview.
expected: >-
  The Upgrades guide's clone-free target-release command reaches preview with the
  release-pinned operator tools, as promised by CAP-19.
reproduction:
  - Use a workstation PATH that contains Nix but no Pulumi binaries.
  - Follow docs/user/upgrades.md with TARGET_NAGARE set to github:shinzui/nagare/v0.3.0.
  - Run nix run "${TARGET_NAGARE}#nagarectl" -- platform upgrade --to 0.3.0 --dry-run --json.
  - Observe that the command stops before preview because Pulumi is absent.
workaround: >-
  Run nagarectl inside nix shell github:shinzui/nagare/v0.3.0#nagare so the
  release-pinned Pulumi and language host are present.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-15T13:52:11Z"
    document_timestamp: "2026-09-15T13:52:11Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Reviewed against the published 0.3.0 upgrade guide, the released flake
      outputs, and the live failing and successful invocations recorded by tan-ng-labs.
---

# The documented release-upgrade command omits the operator toolchain

`docs/user/upgrades.md` selects the immutable target release correctly but runs the application-only
`#nagarectl` output. That output has no Pulumi on `PATH`; `nagarectl version --tools` confirms the
missing dependency and the cloud preflight fails before an infrastructure plan exists. Running the
same CLI inside the release's complete `#nagare` shell exposes Pulumi 3.255.0 and succeeds.

The fix should provide and document one clone-free target-release invocation for planning, status,
apply, resume, and rollback that carries the tested operator toolchain. A regression should execute
the copied command in an isolated environment with no ambient Pulumi and prove it completes preview.
