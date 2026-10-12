---
id: 92
slug: context-documentation-and-migration-from-target-and-local-profiles
title: "Context documentation and migration from target and local profiles"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# Context documentation and migration from target and local profiles

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [92-context-documentation-and-migration-from-target-and-local-profiles.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/92-context-documentation-and-migration-from-target-and-local-profiles.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today, an operator who wants to run two nagare instances — say a production cloud
target on the GCP project `tan-nb-exp` and a second `labs` target on a different
project serving `labs.topagentnetwork.net`, or a laptop-only local target — has to
keep **one working-directory per target**. Each checkout carries its own git-ignored
profile file (`nagare.target.env` for a cloud target, or `nagare.local.env` plus
`NAGARE_MODE=local` for a local target), and switching means editing a file and
re-running `direnv allow`. There is no way to name a target and pick it per command.

The sibling behavioral plans of this initiative
([`docs/masterplans/17-first-class-target-contexts-for-nagare.md`](../masterplans/17-first-class-target-contexts-for-nagare.md))
change that: nagare gains **first-class target contexts** modeled on
`kubectl`/kubeconfig. A "context" is a named, fully-resolved target bundle stored in a
user-level directory; one is marked the **current context**; and any command can
select a context with `nagarectl --context <name>` or the `NAGARE_CONTEXT` environment
variable. After this initiative an operator runs `nagarectl --context labs deploy …`
without leaving the current directory or touching a file.

This ExecPlan is the **documentation-and-migration layer** of that initiative (child
EP-92 of MasterPlan 17). It does **not** ship code; it makes the operator
documentation describe the contexts feature truthfully and gives operators a concrete,
ordered path from the old per-directory profile files to named contexts. Concretely,
after this plan:

- A new runbook, `docs/user/contexts.md`, explains what a context is, where the store
  lives, the `nagarectl context list|current|use|show|create|delete` commands, the
  `--context`/`NAGARE_CONTEXT` selection, the precedence, a worked multi-instance
  example (a cloud `labs` context contrasted with a `local` context), how cloud-vs-local
  is just the `mode` field, per-context Pulumi state, and troubleshooting.
- The existing operator docs — [`docs/user/README.md`](../user/README.md),
  [`docs/user/getting-started.md`](../user/getting-started.md),
  [`docs/user/onboarding-bring-your-own-project.md`](../user/onboarding-bring-your-own-project.md),
  [`docs/user/local-development.md`](../user/local-development.md),
  [`docs/user/reference.md`](../user/reference.md), and the project-root
  [`CLAUDE.md`](../../CLAUDE.md) — are reconciled so they describe contexts as the
  primary mechanism, with the single-profile model preserved as a back-compatible
  special case.
- A migration section documents, step by step, how to copy an existing
  `nagare.target.env`/`nagare.local.env` into a named context (or recreate it with
  `nagarectl context create`), and states plainly that an in-repo profile **still works
  unchanged** and that doing nothing still reproduces the historic `tan-nb-exp` setup.

The observable outcome: a reader with only a fresh checkout and these docs can go from
zero to **two distinct contexts** (e.g. `labs` cloud + `local`) and deploy to either by
name, and every internal documentation link resolves.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: New runbook `docs/user/contexts.md` written — what a context is, store layout +
  `current-context`, the `nagarectl context` command group, `--context`/`NAGARE_CONTEXT`,
  the precedence, a worked `labs`-vs-`local` multi-instance example, cloud-vs-local as
  `mode`, per-context Pulumi state, migration, and troubleshooting. Completed 2026-07-01.
- [x] M2: Existing docs reconciled — `getting-started.md` ("Where to go next" +
  control-surface), `onboarding-bring-your-own-project.md` (init creates a context;
  multi-instance via contexts), `local-development.md` (local = a `mode=local` context),
  `reference.md` (add the `nagarectl context …` commands + recipes/keys), `README.md`
  (capability table gets a "Target contexts" row + Read-in-this-order link),
  `access.md` (note the public host derives from the active context's base domain), plus
  related Pulumi/DR/build-flag references found during validation. Completed 2026-07-01.
- [x] M3: Migration + back-compat — the ordered `nagare.target.env`/`nagare.local.env`
  → named-context migration documented; the "in-repo profile still works / nothing-set
  still reproduces `tan-nb-exp`" guarantee stated; `CLAUDE.md`'s isolation section
  re-expressed over the **active context** without weakening the fail-closed cloud
  guarantee. Completed 2026-07-01.
- [x] Validation: every new/edited internal link resolves; a reader can go fresh checkout
  → two contexts → deploy using only the docs. Completed 2026-07-01.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The behavioral sibling plans (EP-87…EP-91) define the contract this plan documents, but
  several are still at skeleton stage on disk at drafting time (their command spellings and
  store paths are fixed by the MasterPlan's Integration Points, not yet by their own prose).
  This plan therefore documents the **contract as fixed in
  [MasterPlan 17 Integration Points 1–6](../masterplans/17-first-class-target-contexts-for-nagare.md)**,
  and the Concrete Steps below instruct re-reading the four behavioral plans for any
  command-name or path drift before finalizing. Evidence: at drafting,
  `grep -nE "context (list|current|use|show|create|delete)" docs/plans/88-*.md` returns
  only the title line, confirming EP-88's body is not yet fleshed out.

- During final reconciliation, the stale context-model prose extended beyond the original
  M2 file list. `docs/user/provisioning-with-pulumi.md`,
  `docs/user/backups-and-disaster-recovery.md`, `docs/runbooks/disaster-recovery.md`,
  `docs/user/deploying-apps.md`, `docs/user/build-modes.md`,
  `docs/user/config-reference.md`, `docs/user/workers.md`,
  `docs/user/managed-databases.md`, `docs/user/cluster-bootstrap.md`, and
  `docs/user/troubleshooting.md` also had user-facing references to `Pulumi.dev.yaml`,
  in-repo Pulumi state, the old `--context` build-directory flag, or local-mode/profile
  wording that would contradict EP-87…EP-91. Those were updated as part of M2 so the user
  guide is internally consistent. Evidence: the final stale-reference check over
  `docs/user`, `docs/runbooks`, and `CLAUDE.md` leaves only the intentional
  "tracked `Pulumi.dev.yaml` has been removed" note in `docs/user/contexts.md`.

## Decision Log

Record every decision made while working on the plan.

- Decision: ship contexts as a **new standalone runbook** `docs/user/contexts.md` rather
  than folding the material into `getting-started.md`.
  Rationale: contexts are a cross-cutting capability (CLI, shell, Pulumi, manifests) that
  the onboarding, local-development, and reference pages all need to link to from one
  canonical place; `getting-started.md` is deliberately a short "set up your workstation
  once" page and would bloat past its purpose. A dedicated page also mirrors how the rest
  of the guide is organized (one capability, one page) and gives the `README.md`
  Read-in-this-order index a single anchor. `getting-started.md` keeps a short pointer to
  it.
  Date: 2026-06-30

- Decision: re-express `CLAUDE.md`'s "GCP project isolation" section over the **active
  context** without weakening the fail-closed cloud guarantee — the guardrail fail-closes
  against the active *cloud* context's project; a *local* context (`mode=local`) steps
  aside; switching contexts (not editing a file) is the supported way to change target;
  precedence becomes environment > context > default.
  Rationale: MasterPlan 17 generalizes MasterPlan 12's single-profile model and subsumes
  MasterPlan 16's `NAGARE_MODE=local` into a context's `mode` field (Integration Points 2
  and 4). The repo's operating rules must describe the mechanism that now ships. The
  fail-closed cloud branch is unchanged in substance — only the *source* of the compared
  project moves from "the in-repo profile" to "the active context's project." The in-repo
  profile path is retained as a documented back-compat fallback so the existing guarantee
  ("nothing-set reproduces `tan-nb-exp`") still holds.
  Date: 2026-06-30

- Decision: the migration is **additive and non-destructive** — it documents copying an
  existing profile into a context (or recreating it with `nagarectl context create`),
  explicitly states the in-repo `nagare.target.env`/`nagare.local.env` still resolves
  unchanged (back-compat precedence rung), and never instructs deleting a profile as a
  required step.
  Rationale: MasterPlan 17's central design decision is that contexts are a
  backward-compatible generalization, not a rewrite. The docs must not imply operators are
  forced to migrate; an operator who does nothing keeps today's behavior. Telling people to
  delete their working profile would manufacture risk for no benefit.
  Date: 2026-06-30

- Decision: scope this plan to **operator documentation only** (the `docs/user/*` set plus
  `CLAUDE.md`); do not touch the `nagare.target.env.example` / `nagare.local.env.example`
  schema files or any code.
  Rationale: the example files are owned by EP-87 (the context contract) — the store's
  per-context `.env` schema is the same flat `export VAR=value` format those examples
  already document. EP-92 references them as the per-context schema; changing them is
  EP-87's job. Keeping EP-92 docs-only keeps its soft-dependency on the behavioral plans
  clean and lets it be finalized last without code conflicts.
  Date: 2026-06-30

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-92 is complete. The operator guide now has a canonical
[`docs/user/contexts.md`](../user/contexts.md) runbook covering the context store,
selection precedence, `nagarectl context` commands, cloud-vs-local mode, a worked
`labs` + `local` example, per-context Pulumi state, cluster/host rendering, migration
from old profile files, and troubleshooting. The main operator pages now describe the
active context as the primary target-selection mechanism while keeping the old
`nagare.target.env`/`nagare.local.env` files as documented back-compatible fallbacks.
`CLAUDE.md` now expresses isolation over the active context and keeps the cloud branch
fail-closed.

Validation completed 2026-07-01:

```text
Internal link check over all edited docs: link check done, no BROKEN lines.
Required contexts.md keyword check: all ok (current-context, XDG_CONFIG_HOME,
NAGARE_CONTEXT, --context, context use, context list, mode=local, labs, precedence,
Migrating).
README capability/index checks: ok.
CLAUDE.md active-context/MP-17/fail-closed checks: ok.
Stale-reference check: no old Pulumi path or old build-context flag hits; only the
intentional contexts.md note that the tracked Pulumi.dev.yaml has been removed.
```

