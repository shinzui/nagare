---
type: Friction Entry
title: "gate-commit selects no test for a group name with parentheses"
description: "scripts/gate-commit.sh turned every non-alphanumeric character of a test group name into '.', but tasty's /…/ pattern is a substring match, so a group such as 'release-only hook in the model world (EP-269)' selected nothing and the gate failed."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T22:18:50Z"
frictionId: FRIC-18
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/270-plan-application-reviews-after-a-failed-release-hook-is-closed.md"
workaround: "Fixed in the same commit: keep the name verbatim and cut only at '/'"
---
# gate-commit selects no test for a group name with parentheses

## Attempted

just gate-commit on the BUG-10 fix

## Encountered

nagarectl-test: the pattern selects no test: /release-only hook in the model world .EP-269./

```text
list-tests with /EP.269/ lists 0 tests; with /world (EP-269)/ it lists 5
```

## Workaround

Fixed in the same commit: keep the name verbatim and cut only at '/'
