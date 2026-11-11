---
type: Friction Entry
title: "Linux host-tool assumptions in the deploy path surfaced one per 10-minute image build"
description: "The in-cluster deployer rehearsal found shasum in nagarectl, a #!/usr/bin/env shebang, docker exec, shasum and awk in the artifact transport one at a time, and each fix cost a full aarch64-linux image build in the Apple container."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-11T17:08:50Z"
frictionId: FRIC-11
status: "resolved"
impact: slowdown
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/inventory-artifact-transport.sh"
affectedVersion: "unreleased"
plan: "docs/plans/248-issue-least-privilege-credentials-to-a-delegated-deployer.md"
workaround: "Fixed each in code; for script-only defects a payload copy under NAGARE_PLATFORM_ROOT inside the running Pod would have skipped the rebuild"
resolution: "Fixed in aa0987b1, 877f919a, cb7f8d2e, e1d75f42 and c2256182: in-process hashing, bash on PATH, skopeo inside the cluster, coreutils hashing, and skopeo and jq in the package."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-11T17:27:15Z"
    change: "Status set to resolved."
---
# Linux host-tool assumptions in the deploy path surfaced one per 10-minute image build

## Attempted

docs/audits/ep248-local-confirmation-2026-11-11/scripts/p4.sh: app image-plan inside the deployer Pod

## Encountered

shasum: posix_spawnp does not exist; inventory-artifact-transport.sh: does not exist (shebang); docker: command not found; invalid artifact transport response (empty digest from shasum|awk)

## Workaround

Fixed each in code; for script-only defects a payload copy under NAGARE_PLATFORM_ROOT inside the running Pod would have skipped the rebuild
