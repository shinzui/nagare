---
type: Friction Entry
title: "just gate-fast without a revision gates master's HEAD from a worktree"
description: "From a git worktree, just gate-fast with no argument gated the main checkout's HEAD instead of the worktree's commit, and a parallel session's gate run was stopped to correct it."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-12T06:53:41Z"
frictionId: FRIC-12
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
affectedVersion: "unreleased"
plan: "docs/plans/259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md"
workaround: "pass the revision explicitly: just gate-fast <sha>"
---
# just gate-fast without a revision gates master's HEAD from a worktree

## Attempted

just gate-fast in .claude/worktrees/agent-a2aade2a7e94bc874 after committing EP-259 M1

## Encountered

the gate reported revision ac6f76cb (master HEAD), not the worktree commit c976957f; stopping it ended the main session's concurrent gate with signal 15

## Workaround

pass the revision explicitly: just gate-fast <sha>
