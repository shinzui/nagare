---
type: Friction Entry
title: "The fast gate checks the last commit and ignores uncommitted work"
description: "just gate-fast defaults to HEAD, so running it before committing spends minutes gating the previous revision while appearing to check the change."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-10T00:27:19Z"
frictionId: FRIC-5
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/239-deliver-rotated-session-cookies-before-waiting-on-the-upstream.md"
workaround: "Commit first, then pass the commit to just gate-fast"
---
# The fast gate checks the last commit and ignores uncommitted work

## Attempted

Run the per-commit gate on a finished M1 before committing it

## Encountered

The gate ran for ten minutes against revision 22994ef4 and said nothing about the uncommitted working tree

## Workaround

Commit first, then pass the commit to just gate-fast
