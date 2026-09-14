---
type: Improvement Request
title: Let infra-up apply a reviewed plan non-interactively, behind the guards
description: The infra-up recipe ends in a bare pulumi up, so a non-TTY shell stops at Pulumi's prompt, and the only workaround, PULUMI_SKIP_CONFIRMATIONS, applies a recomputed plan rather than the one the operator reviewed.
timestamp: "2026-09-14T14:12:41Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:04:28Z"
requestId: IR-15
status: completed
acceptedAt: "2026-09-14T04:26:09Z"
completedAt: "2026-09-14T14:12:41Z"
resolution: "ExecPlan 136 added a private immutable bundle containing Pulumi's saved plan, a redacted operation review, and Nagare context/project/stack/backend/payload/program/config/version bindings. Guarded apply verifies every member and binding before pulumi up --plan --yes --non-interactive, with no second preview; upgrades retain the same bundle across resume. A separate guarded destroy command owns teardown. Pure and clone-free fake-Pulumi tests cover mismatches, tampering, exact argv, and no-preview apply. ADR 18 records the constrained-not-atomic execution boundary."
targetPlan: docs/plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md
origin: mori://shinzui/nagare
---

# Improvement Request: a non-interactive infra-up that applies the reviewed plan

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.2`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by
[ExecPlan 136](../plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md); the
retained reviewed-plan boundary is recorded in
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md).
**Created:** 2026-09-14.


## Why

The first `nagare infra-up` for the `labs` context ran from an agent shell with no TTY. The
recipe's final `pulumi up` would have stopped at Pulumi's confirmation prompt, and nagare offers no
flag for that case. The operator ran `PULUMI_SKIP_CONFIRMATIONS=true nagare infra-up`. That kept the
platform, context and infra guards, but it skips only the prompt: `pulumi up` computes a fresh plan
and applies it. That plan is not the one the operator reviewed.

The difference showed up at once. The reviewed `nagare infra-preview` named the Cloud DNS zone
`nagare-zone-0a61523`; the applied update created `nagare-zone-89da8ae`, because the auto-name suffix
is recomputed on every run. Here it was harmless (29 creates on a fresh stack, same shape). On a
stack with live resources, though, the gap between "the preview I read" and "the update that ran" is
exactly where a surprise gets in, and the infra guard does not close it: it runs its own
`pulumi preview --json` (`cli/nagarectl/app/Main.hs:2959` at `v0.2.2`), which is a third, separate
computation.


## What is missing

- The `infra-up` recipe (`justfile:58-62` at `v0.2.2`) is `nagarectl platform guard`,
  `nagarectl context guard`, `nagarectl infra guard`, then `cd infra/pulumi && pulumi up`, with no
  `--yes`, no `--non-interactive` and no saved plan.
- The upgrade path already runs non-interactively: its `PulumiApply` phase re-runs the guards and
  then `pulumi up --yes --non-interactive` (`Main.hs:2676-2682`). It applies a re-preview too
  (`Main.hs:2674`, "apply re-previews"), so it has the same reviewed-versus-applied gap.
- There is no `infra-destroy` recipe; the comment at `justfile:70-74` points to a manual
  `pulumi destroy`, which is interactive and unguarded by nagare.
- The user docs never mention running `infra-up` without a TTY.


## Requested change

- A two-step path: `nagare infra-preview --save-plan FILE` writes a Pulumi update plan
  (`pulumi preview --save-plan`), and `nagare infra-up --plan FILE` runs the three guards against
  that same file and then `pulumi up --yes --non-interactive --plan FILE`. Pulumi then refuses any
  step not in the reviewed plan. Ideally the infra guard classifies the saved plan's steps rather
  than a separate preview.
- If the saved-plan path is not taken, at least a documented `--yes` for `infra-up` that passes
  `--yes --non-interactive` after the guards, with the docs stating plainly that it applies a
  recomputed plan.
- Apply the same reviewed-plan approach to the upgrade `PulumiApply` phase, and document how to run a
  full teardown (the manual `pulumi destroy`) behind the context guard.
- Document the non-interactive mode in `docs/user/provisioning-with-pulumi.md` and in the
  bring-your-own-project onboarding guide.


## Required verification

- A launcher or recipe test showing `infra-up --plan FILE` runs all three guards before
  `pulumi up`, and passes `--plan FILE --yes --non-interactive`.
- A test (fake Pulumi) showing that a plan file from a different stack or context is refused.


## Acceptance

An operator or CI job can review a saved `infra-preview` plan and apply exactly that plan with no
TTY, without setting any Pulumi environment variable by hand, and every guard still runs first.


## Non-goals

Weakening or bypassing any guard, or making `infra-up` non-interactive by default.
