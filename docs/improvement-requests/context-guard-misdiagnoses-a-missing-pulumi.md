---
type: Improvement Request
title: Make the context guard report a missing or failing pulumi instead of an unprojected stack
description: With pulumi absent from PATH the guard refuses with "declares no gcp:project" and advises context use, even though the stack config declares the right project.
timestamp: "2026-09-14T02:39:24Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-9
status: completed
acceptedAt: "2026-09-14T02:10:44Z"
completedAt: "2026-09-14T02:39:24Z"
resolution: "ExecPlan 129 replaced the nullable stack-project probe with typed found, missing, tool-not-found, command-failed, start-failed, and invalid-output observations. The guard now runs pulumi config --json, preserves exit status and stderr, names the resolved stack/backend in every refusal, emits standalone JSON failures, and has 15 focused unit cases plus passing hermetic missing-tool and fake-Pulumi command checks. ADR 9 records the durable diagnostic contract."
targetPlan: docs/plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md
origin: mori://shinzui/nagare
---

# Improvement Request: make the context guard report why it could not read the stack project

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by [ExecPlan 129](../plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md);
the durable diagnostic contract is recorded in
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md).
**Created:** 2026-09-13.


## Why

After the stack config `~/.config/nagare/pulumi/Pulumi.labs.yaml` had been seeded with
`gcp:project: tan-ng-labs`, `nagarectl context guard` run from a shell without `pulumi` printed:

```text
nagarectl: refusing to run: Pulumi stack 'labs' declares no gcp:project, so the next Pulumi operation's target project is unknown.
fix: re-project the stack config with 'nagarectl context use labs'.
```

The same command with `pulumi` on `PATH` printed
`context guard: labs confined to project tan-ng-labs (stack labs)`. Refusing was correct; the stated
reason and fix were not. An operator following the advice re-seeds a stack that is already correct
and still gets refused, and in a safety guard a misleading reason erodes trust in the true ones.


## What is missing

`runContextGuard` gathers the stack project with `captureTrimmed "pulumi" ["-C", …, "config", "get",
"gcp:project", "--stack", …]` (`cli/nagarectl/app/Main.hs:3232-3235`). `captureTrimmed` maps through
`captureTool` (`Main.hs:3249`), which turns both an `IOException` (binary not found) and any non-zero
exit into `Nothing` (`cli/nagarectl/src/Nagare/Ops/Probe.hs:134-142`). `projectGuardVerdict` then
reports every `Nothing` as "declares no gcp:project"
(`cli/nagarectl/src/Nagare/Ops/ContextGuard.hs:63-69`). Backend authentication failures, a locked
state, or a wrong `PULUMI_BACKEND_URL` would be misreported the same way.


## Requested change

- Distinguish "tool not found", "pulumi exited non-zero (with its stderr)" and "key genuinely
  absent", and give each its own refusal text and fix. All three still refuse.
- Include the resolved `PULUMI_BACKEND_URL` and stack in the refusal, and in `--json` output.


## Required verification

- Unit tests for the verdict on each of the three cases.
- A hermetic command test with no `pulumi` on `PATH` asserting the "not found" refusal.


## Acceptance

Every guard refusal names the actual cause, and following its fix makes the guard accept.


## Non-goals

Relaxing the guard in any case; it must continue to fail closed.
