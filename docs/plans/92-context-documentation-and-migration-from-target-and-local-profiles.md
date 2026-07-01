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


## Context and Orientation

This plan edits Markdown only. The reader needs to know the documents involved, their
current framing, and the new contract they must be reconciled to. Everything below is
stated so a contributor with only this plan and the working tree can do the work.

### The context model this plan documents

The behavioral plans of MasterPlan 17 introduce a **context**: a named, fully-resolved
target bundle. Its fields (from
[MasterPlan 17 Integration Point 1](../masterplans/17-first-class-target-contexts-for-nagare.md))
are the existing `Nagare.Target.TargetProfile` bundle plus `mode` and a local object
store, namely: `project` (GCP project id), `region`, `zone`, `registryHost`,
`artifactRegistryId`, `imageBucket`, `backupBucket`, `baseDomain`, `instanceName`,
`targetPlatform`, `mode` (`cloud` or `local`), and `localObjectStore` (the MinIO
endpoint+bucket used only in local mode) — plus the location of that context's Pulumi
state.

The **store** is a user-level directory:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/
  contexts/
    <name>.env          # one flat `export VAR=value` file per context
  current-context       # a one-line file naming the default context
```

Each `<name>.env` uses the **same flat `export VAR=value` schema** as today's
`nagare.target.env` (cloud) and `nagare.local.env` (local) — deliberately, so bash can
`source` it without a YAML parser. The tracked
[`nagare.target.env.example`](../../nagare.target.env.example) and
[`nagare.local.env.example`](../../nagare.local.env.example) document that schema and
double as the per-context `.env` template: copying one into
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` (or running
`nagarectl context create`) yields a context.

**Selection and precedence** (MasterPlan 17 Integration Point 2), highest first:

1. an explicit `nagarectl --context <name>` flag, or the `NAGARE_CONTEXT` environment
   variable;
2. the `current-context` pointer file;
3. an in-repo `nagare.target.env` / `nagare.local.env` (back-compat with MasterPlan 12/16);
4. the built-in `tan-nb-exp` default.

Independently, **per-field environment variables still override** the chosen context's
values (`env > context > default`) — the historic "environment wins" semantics are
preserved.

The **CLI** (EP-88) adds the command group
`nagarectl context list|current|use|show|create|delete` and the global `--context` flag;
`nagarectl init` writes a *named context* rather than a bare `nagare.target.env`. The
**shell** (EP-89) makes `scripts/lib/target.sh` and `.envrc` resolve the active context
from the same store with the same precedence, so `NAGARE_CONTEXT=labs just smoke` targets
that context, and reworks the fail-closed guardrail `_require_target_project` to assert
against the **active context's** project (fail-closed in `mode=cloud`, stepping aside in
`mode=local`). **Pulumi** (EP-90) gives each context its own state location and replaces
the tracked `Pulumi.dev.yaml` with a per-context projection. **Manifests/Nix** (EP-91)
template the DNS-01 issuer project, the Service image refs, and the NixOS registry host
from the active context. The `mode=local` context **subsumes** MasterPlan 16's
`NAGARE_MODE=local` switch.

### The documents to reconcile and their current framing

- [`docs/user/README.md`](../user/README.md) — the operator index. Current framing: the
  opening lists the two operating targets as "Cloud mode, configured by
  `nagare.target.env`" and "Local mode, configured by `nagare.local.env` and
  `NAGARE_MODE=local`." It has an implementation-status **capability table** (rows like
  "Local development and testing", "Deploy CLI"), a **Read in this order** index, and a
  closing **"One target at a time — and it's yours to choose"** section that frames
  isolation around `nagare.target.env` and says local mode "intentionally steps aside only
  in that mode." No row or link mentions contexts yet.

- [`docs/user/getting-started.md`](../user/getting-started.md) — workstation setup. Current
  framing: a **"Project isolation"** section that describes `nagare.target.env`, the
  `.envrc` source-and-default snippet, and the `_require_target_project` guardrail; a
  **"Pulumi state is in-repo"** section; a **"The `justfile` is your control surface"**
  section; and a **"Where to go next"** section. It ends "**One target per checkout** — to
  point at a different GCP project, change the profile (or run `nagarectl init --force`),
  don't run two at once." That sentence is exactly what contexts change.

- [`docs/user/onboarding-bring-your-own-project.md`](../user/onboarding-bring-your-own-project.md)
  — the zero-to-running runbook. Current framing: **Step 2 — `nagarectl init`** says init
  "writes the target profile" (`nagare.target.env`, nine export lines) and seeds Pulumi
  config; a closing **"Switching projects later"** section says re-run `nagarectl init
  --force` and "You do **not** run two targets at once — the guardrail enforces one active
  target per checkout." With contexts, `init` writes a *context* and the multi-instance
  story is contexts, not multiple checkouts.

- [`docs/user/local-development.md`](../user/local-development.md) — the local-mode runbook.
  Current framing: a cloud-vs-local table whose last row is "GCP project guardrail |
  bypassed only when `NAGARE_MODE=local`"; a **"Create the local target profile"** section
  that copies `nagare.local.env.example` to `nagare.local.env` and runs `export
  NAGARE_MODE=local; direnv allow`. With contexts, local mode is "a context with
  `mode=local`," selected like any other context.

- [`docs/user/reference.md`](../user/reference.md) — fixed identifiers + recipe table +
  Pulumi keys + command catalogues. Current framing: sections "Target profile variables
  (`nagare.target.env`)", "Local profile variables (`nagare.local.env`)", a `justfile`
  recipes table, "Pulumi config keys (`infra/pulumi/Pulumi.dev.yaml`)", and per-verb
  command tables (`site`, `broker`, `env`/`secret`, `storage`, `db`). There is **no**
  `nagarectl context` command table and no mention of the store paths.

- [`docs/user/access.md`](../user/access.md) — identity-aware access. Current framing:
  examples use the literal host `protected-hello.apps.example.com`. It has no profile
  variable references, but the public host derives from the active target's base domain
  (the recent `feat(access)` work derives the protected-hello public host from
  `NAGARE_BASE_DOMAIN`). It needs only a light note that the base domain now comes from the
  active context.

- [`CLAUDE.md`](../../CLAUDE.md) (project root) — the operating rules. Current framing: a
  **"GCP project isolation"** section that makes `nagare.target.env` canonical, lists the
  contract variables, describes `.envrc` sourcing the profile, the one-place guardrail
  `scripts/lib/target.sh`, the Pulumi projection, and a Decision-Log basis pointing at
  MasterPlan 12. A recent edit blessed `NAGARE_MODE=local` as a by-design bypass. With
  contexts this section must speak in terms of the **active context** and cite MasterPlan
  17.

### Conventions for the docs in this repo

Every operator page opens with a `> **Status:** …` badge (✅ Working / 🟡 In progress / 🔭
Planned / 🟢 Complete). Internal links are repository-relative Markdown links. Tables are
used liberally in this doc set (unlike ExecPlans, the user docs are table-first). New code
fences in the docs must carry a language tag.


## Plan of Work

The work is three milestones, each independently verifiable by reading the rendered
Markdown and clicking links. M1 creates the canonical runbook; M2 threads it into the
existing pages; M3 handles migration and the `CLAUDE.md` policy re-framing. Sequence M1
first because the other pages link to it.

Before starting, **re-read the four behavioral plans on disk** to catch any command-name
or path drift from the MasterPlan contract:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
sed -n '1,80p' docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md
sed -n '1,80p' docs/plans/88-nagarectl-context-command-group-and-context-selection.md
sed -n '1,80p' docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md
sed -n '1,80p' docs/plans/90-per-context-pulumi-state-and-config-projection.md
```

If any of those fix a different spelling for a command, flag name, or store path than the
MasterPlan Integration Points, the **plan-on-disk wins** for the concrete spelling; record
the divergence in Surprises & Discoveries and adjust the doc edits accordingly.

### Milestone M1 — the `docs/user/contexts.md` runbook

Scope: write a brand-new page `docs/user/contexts.md` that is the canonical, self-contained
explanation of target contexts. At the end of this milestone the file exists, opens with a
status badge (`🟡 In progress` until the behavioral plans land live; or `🟢` once they do —
choose to match the README capability table at edit time), and covers, in this order:

1. **What a context is** — a named target bundle (list the fields from Context and
   Orientation in plain language), analogized to a `kubectl` context.
2. **The store layout** — the `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`
   files and the `current-context` pointer, shown as a directory tree fence, noting the
   flat `export VAR=value` schema is the same as the example profile files.
3. **The `nagarectl context` commands** — a table of
   `list|current|use|show|create|delete` with one-line effects.
4. **Selecting a context** — `nagarectl --context <name>`, the `NAGARE_CONTEXT`
   environment variable, and `nagarectl context use <name>` (set the current context); the
   four-rung precedence as a numbered list, plus the per-field `env > context > default`
   override note.
5. **Cloud vs local is just `mode`** — a `mode=cloud` context is a former
   `nagare.target.env`; a `mode=local` context is a former `nagare.local.env` +
   `NAGARE_MODE=local`. The guardrail fail-closes for cloud contexts and steps aside for
   local ones.
6. **A worked multi-instance example** — create a `labs` cloud context on a non-`tan-nb-exp`
   project for `labs.topagentnetwork.net`, a `local` context, list/switch between them, and
   `nagarectl --context labs deploy …`. Show the commands and the expected `context list`
   output.
7. **Per-context Pulumi state** — each context owns its own state location, so two contexts
   never collide; `nagarectl init`/`context use` regenerate the per-context Pulumi config
   projection (cross-link to provisioning).
8. **Troubleshooting** — "no current context", "context not found", "guardrail refuses:
   active project ≠ context project", and "I edited an in-repo profile but a context is
   overriding it" (precedence reminder).

Acceptance: the file renders, every cross-link target exists, and a reader can follow the
worked example end-to-end conceptually. Verify links with the grep loop in Validation.

### Milestone M2 — reconcile the existing pages

Scope: thread contexts into the five existing operator pages plus `access.md`. At the end,
each page describes contexts as the primary mechanism, links to `contexts.md`, and the
single-profile model is presented as a back-compatible special case. No page contradicts
`contexts.md`.

- `README.md`: add a **"Target contexts"** row to the capability table (mapped to MP-17,
  status matching `contexts.md`); add `contexts.md` to the **Read in this order** list (a
  natural spot is right after Getting started / before Provisioning, since contexts are
  chosen before you provision); and update the closing **"One target at a time"** section
  so it frames selection as the active context (cloud fail-closes, local steps aside,
  switch by `context use`, not by editing a file), while still noting an in-repo profile and
  the `tan-nb-exp` default remain the back-compat fallback. Update the two bullet items at
  the very top (the cloud/local "configured by …" descriptions) to mention contexts.
- `getting-started.md`: in **"Project isolation"** keep the `.envrc`/guardrail explanation
  but add that the resolved target is the **active context** (precedence env > context >
  in-repo profile > default), and soften the closing "**One target per checkout**"
  sentence to "switch contexts with `nagarectl context use`, no second checkout needed,"
  cross-linking `contexts.md`. In **"The `justfile` is your control surface"** note that
  recipes honor `NAGARE_CONTEXT` (e.g. `NAGARE_CONTEXT=labs just smoke`). In **"Where to go
  next"** add a short pointer to `contexts.md` for running multiple targets.
- `onboarding-bring-your-own-project.md`: in **Step 2 — `nagarectl init`** state that init
  writes a **named context** (the same nine variables, now stored as a context) and seeds
  that context's Pulumi projection; keep the literal example. Replace the closing
  **"Switching projects later"** section's "one active target per checkout" with the
  contexts story: create a second context (`nagarectl init --context <name> …` or
  `nagarectl context create`) and select it with `--context`/`context use` — no second
  checkout — cross-linking `contexts.md`. Preserve the back-compat note that `nagarectl init
  --force` rewriting an in-repo profile still works.
- `local-development.md`: reframe **"Create the local target profile"** as "create a local
  context" — show both the `nagarectl context create --mode local …` path and the
  back-compat `cp nagare.local.env.example nagare.local.env` + in-repo path; update the
  cloud-vs-local table's guardrail row from "bypassed only when `NAGARE_MODE=local`" to
  "steps aside for a `mode=local` context"; note that selecting the local context is
  `nagarectl context use local` / `NAGARE_CONTEXT=local` rather than `export
  NAGARE_MODE=local`. Cross-link `contexts.md`.
- `reference.md`: add a **"`nagarectl context` commands"** table (the six verbs); add a
  **"Context store"** note giving the `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/`
  + `current-context` paths and the flat-`.env` schema; add the global `--context` flag and
  `NAGARE_CONTEXT` to the relevant places; note the Pulumi config keys are now a per-context
  projection (state location is per-context). Keep the existing profile-variable tables
  (they document the per-context `.env` schema) but retitle/annotate them as "context `.env`
  variables (also the in-repo `nagare.target.env`/`nagare.local.env` schema)."
- `access.md`: add a one-sentence note where the host appears that
  `protected-hello.<base-domain>` derives the base domain from the **active context** (so a
  `labs` context yields `protected-hello.labs.topagentnetwork.net`). No structural change.

Acceptance: each edited page links to `contexts.md`, the capability table has the new row,
and no page still says "one target per checkout" as the *only* option.

### Milestone M3 — migration and the `CLAUDE.md` policy re-framing

Scope: document the migration from profile files to contexts (in `contexts.md`, as a
**"Migrating from `nagare.target.env`/`nagare.local.env`"** section), and re-express
`CLAUDE.md`'s isolation section over the active context. At the end, an operator with an
existing profile has an ordered path to a named context, the back-compat guarantees are
stated, and the repo's operating rules match the shipped mechanism.

The migration section (in `contexts.md`) gives, as an ordered procedure:

1. Confirm your current profile resolves (it still does — back-compat rung 3).
2. Pick a context name (e.g. `prod`, `labs`, `local`).
3. Either run `nagarectl context create <name>` from the existing environment, or copy the
   profile file verbatim:
   `cp nagare.target.env "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env"`
   (and the local profile likewise for a `mode=local` context — adding the `mode=local`
   line if the example didn't carry it).
4. `nagarectl context use <name>` to make it current; verify with `nagarectl context
   current` and `nagarectl context show <name>`.
5. (Optional) once satisfied, you may remove the in-repo profile, but you are not required
   to — it remains a valid lower-precedence fallback.

State explicitly: **nothing breaks if you do nothing** — an in-repo `nagare.target.env` is
still honored, and an operator with neither a context nor a profile still gets the
historic `tan-nb-exp` defaults.

For `CLAUDE.md`: rewrite the **"GCP project isolation"** section so that (a) the canonical
target is the **active context** resolved with precedence environment > context > in-repo
profile > built-in default; (b) the guardrail in `scripts/lib/target.sh`'s
`_require_target_project` fail-closes against the active **cloud** context's project and a
**local** context (`mode=local`) steps aside — replacing the `NAGARE_MODE=local`
by-design-bypass wording with the context-`mode` branch; (c) switching targets means
selecting a different context, not editing a file (though editing an in-repo profile still
works as the back-compat path); and (d) the Decision-Log basis now also cites MasterPlan 17
as the decision that authorizes the contexts model and supersedes the single-profile
framing of MasterPlan 12. The **fail-closed cloud guarantee must remain verbatim in
spirit** — only the source of the compared project changes.

Acceptance: `CLAUDE.md` no longer frames isolation solely around `nagare.target.env`; it
reads "active context" with the cloud-fail-closed / local-steps-aside branch and cites
MasterPlan 17; the migration section in `contexts.md` is a runnable ordered procedure.


## Concrete Steps

All commands run from the repo root, `/Users/shinzui/Keikaku/bokuno/nagare`. Edits are
made with your editor; the `$EDITOR <path>` lines below name the file and the change. After
the edits, run the link-check in Validation.

### M1 — create the runbook

```bash
$EDITOR docs/user/contexts.md
# NEW FILE. Open with `> **Status:** …` (match README capability-table status).
# Sections in order: What a context is; The context store (dir-tree fence with
# ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env + current-context);
# The `nagarectl context` commands (table: list|current|use|show|create|delete);
# Selecting a context (--context / NAGARE_CONTEXT / context use; four-rung precedence;
# env > context > default override note); Cloud vs local is just `mode`; Worked
# multi-instance example (labs cloud on a non-tan-nb-exp project for
# labs.topagentnetwork.net, plus a local context; `context list` expected output;
# `nagarectl --context labs deploy …`); Per-context Pulumi state (cross-link
# provisioning-with-pulumi.md); Migrating from nagare.target.env/nagare.local.env
# (the M3 ordered procedure); Troubleshooting. Cross-link CLAUDE.md, getting-started.md,
# onboarding-bring-your-own-project.md, local-development.md, reference.md, and
# masterplans/17-first-class-target-contexts-for-nagare.md. Language tags on every fence.
```

A representative directory-tree fence to include:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/
  contexts/
    prod.env      # mode=cloud, project=tan-nb-exp, baseDomain=apps.example.com
    labs.env      # mode=cloud, project=<your-labs-project>, baseDomain=labs.topagentnetwork.net
    local.env     # mode=local, registryHost=k3d-registry.localhost:5000
  current-context # one line, e.g. "prod"
```

A representative worked-example transcript to include (illustrative output):

```bash
nagarectl context create labs --mode cloud --project your-labs-project \
  --region us-west1 --zone us-west1-a --base-domain labs.topagentnetwork.net
nagarectl context create local --mode local
nagarectl context list
# NAME    MODE   PROJECT             BASE DOMAIN
# prod*   cloud  tan-nb-exp          apps.example.com
# labs    cloud  your-labs-project   labs.topagentnetwork.net
# local   local  -                   127-0-0-1.sslip.io
nagarectl --context labs deploy -f nagare/Config.hs
```

> Note: confirm the exact `nagarectl context create` flag spellings against
> `docs/plans/88-nagarectl-context-command-group-and-context-selection.md` before
> finalizing (see the re-read step in Plan of Work). If EP-88 fixes different flags, use
> those and note the change in Surprises & Discoveries.

### M2 — reconcile the existing pages

```bash
$EDITOR docs/user/README.md
# - Top bullets: mention contexts in the cloud/local "configured by …" lines.
# - Capability table: add a "Target contexts" row → MP-17, status matching contexts.md.
# - Read-in-this-order: add a link to contexts.md (after Getting started).
# - "One target at a time" closing section: reframe to the active context — cloud
#   fail-closes, local steps aside, switch via `nagarectl context use`; keep the in-repo
#   profile + tan-nb-exp default as the back-compat fallback; cite MasterPlan 17.

$EDITOR docs/user/getting-started.md
# - "Project isolation": add that the resolved target is the active context with
#   precedence env > context > in-repo profile > default; link contexts.md.
# - Soften the "One target per checkout" sentence to "switch contexts with
#   `nagarectl context use`, no second checkout."
# - "The justfile is your control surface": note recipes honor NAGARE_CONTEXT
#   (NAGARE_CONTEXT=labs just smoke).
# - "Where to go next": add a pointer to contexts.md for multiple targets.

$EDITOR docs/user/onboarding-bring-your-own-project.md
# - Step 2 (`nagarectl init`): state init writes a NAMED CONTEXT (same nine vars) and
#   seeds that context's Pulumi projection; keep the literal example block.
# - "Switching projects later": replace "one active target per checkout" with the
#   contexts story (second context via init/context create + `--context`/`context use`,
#   no second checkout); keep `nagarectl init --force` as the in-repo back-compat path;
#   link contexts.md.

$EDITOR docs/user/local-development.md
# - cloud-vs-local table: guardrail row → "steps aside for a `mode=local` context".
# - "Create the local target profile": reframe as "create a local context"; show both
#   `nagarectl context create local --mode local` and the back-compat `cp
#   nagare.local.env.example nagare.local.env` in-repo path; selecting it is
#   `nagarectl context use local` / NAGARE_CONTEXT=local, not `export NAGARE_MODE=local`.
# - link contexts.md.

$EDITOR docs/user/reference.md
# - Add a "`nagarectl context` commands" table (list|current|use|show|create|delete).
# - Add a "Context store" note: ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env
#   + current-context; flat `export VAR=value` schema.
# - Note the global `--context` flag and NAGARE_CONTEXT; Pulumi config keys are now a
#   per-context projection with a per-context state location.
# - Retitle/annotate the two profile-variable tables as "context `.env` variables (also
#   the in-repo nagare.target.env/nagare.local.env schema)".

$EDITOR docs/user/access.md
# - Add one sentence where protected-hello.apps.example.com appears: the base domain
#   derives from the ACTIVE CONTEXT (a `labs` context yields
#   protected-hello.labs.topagentnetwork.net).
```

### M3 — migration + CLAUDE.md

```bash
$EDITOR docs/user/contexts.md
# - Add/confirm the "Migrating from nagare.target.env/nagare.local.env" section: the
#   ordered procedure (resolves today → pick a name → `context create` OR copy the
#   profile into contexts/<name>.env → `context use` → verify with `context current`
#   /`context show` → optional removal). State the nothing-breaks-if-you-do-nothing
#   guarantee (in-repo profile honored; no context + no profile → tan-nb-exp default).

$EDITOR CLAUDE.md
# Rewrite the "GCP project isolation" section to speak in terms of the ACTIVE CONTEXT:
# - canonical target = active context; precedence environment > context > in-repo
#   profile > built-in default.
# - guardrail in scripts/lib/target.sh `_require_target_project` fail-closes against the
#   active CLOUD context's project; a LOCAL (mode=local) context steps aside — replacing
#   the NAGARE_MODE=local bypass wording with a context-`mode` branch.
# - switching targets = selecting a different context (in-repo profile edit still works
#   as back-compat).
# - Decision Log basis: also cite docs/masterplans/17-first-class-target-contexts-for-nagare.md
#   as superseding the single-profile framing of MasterPlan 12.
# - KEEP the fail-closed cloud guarantee verbatim in spirit; only the source of the
#   compared project changes.
```

Expected `git status` after all edits (one new file, six modified):

```text
On branch master
Changes not staged for commit:
  modified:   CLAUDE.md
  modified:   docs/user/README.md
  modified:   docs/user/access.md
  modified:   docs/user/getting-started.md
  modified:   docs/user/local-development.md
  modified:   docs/user/onboarding-bring-your-own-project.md
  modified:   docs/user/reference.md

Untracked files:
  docs/user/contexts.md
```


## Validation and Acceptance

Because this plan ships documentation, acceptance is "the docs are accurate, complete, and
navigable." Run these checks from the repo root.

**1. Every internal link in the touched docs resolves.** Extract relative Markdown link
targets from each edited file and confirm the file exists:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
for f in docs/user/contexts.md docs/user/README.md docs/user/getting-started.md \
         docs/user/onboarding-bring-your-own-project.md docs/user/local-development.md \
         docs/user/reference.md docs/user/access.md CLAUDE.md; do
  grep -oE ']\(([^)]+)\)' "$f" | sed -E 's/^\]\(//; s/\)$//' | while read -r link; do
    case "$link" in
      http*|\#*) continue ;;                      # skip external + same-page anchors
    esac
    target="${link%%#*}"                          # strip any #anchor
    dir="$(dirname "$f")"
    [ -e "$dir/$target" ] || echo "BROKEN: $f -> $link"
  done
done
echo "link check done"
```

Expected: the only line printed is `link check done` (no `BROKEN:` lines).

**2. The contexts page covers the contract.** Confirm the runbook names every required
concept:

```bash
for kw in "current-context" "XDG_CONFIG_HOME" "NAGARE_CONTEXT" "--context" \
          "context use" "context list" "mode=local" "labs" "precedence" "Migrating"; do
  grep -q "$kw" docs/user/contexts.md && echo "ok: $kw" || echo "MISSING: $kw"
done
```

Expected: all `ok:` lines, no `MISSING:`.

**3. The capability table gained a contexts row and the index links the page.**

```bash
grep -q "Target contexts" docs/user/README.md && echo "ok: capability row" || echo "MISSING row"
grep -q "contexts.md" docs/user/README.md && echo "ok: index link" || echo "MISSING index link"
```

**4. `CLAUDE.md` is re-framed.** It should reference the active context and MasterPlan 17,
and no longer present `NAGARE_MODE=local` as the bypass:

```bash
grep -q "active context" CLAUDE.md && echo "ok: active-context framing" || echo "MISSING framing"
grep -q "17-first-class-target-contexts-for-nagare" CLAUDE.md && echo "ok: MP-17 cite" || echo "MISSING MP-17"
grep -q "fail-clos" CLAUDE.md && echo "ok: fail-closed retained" || echo "MISSING fail-closed"
```

Expected: three `ok:` lines.

**5. End-to-end reader test (manual).** Read, in order, `README.md` → `getting-started.md`
→ `contexts.md`, and confirm a newcomer could: (a) understand a context is a named bundle
in `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/`; (b) create a `labs` cloud context
and a `local` context; (c) select either with `--context`/`NAGARE_CONTEXT`/`context use`;
(d) understand cloud fail-closes and local steps aside; and (e) deploy with `nagarectl
--context labs deploy …` — all without editing a file or making a second checkout. This is
the behavioral acceptance for the whole plan: fresh checkout → multiple contexts → deploy,
using only the docs.

**6. Cross-check against the shipped behavioral plans.** After EP-87…EP-91 are complete,
re-read their Outcomes sections and confirm the doc command spellings, flags, and store
paths still match; fix any drift and note it in Surprises & Discoveries. (This plan
soft-depends on those five and is finalized last precisely so the runbook matches what
shipped.)


## Idempotence and Recovery

Every change here is **additive Markdown**: a new page plus edits that insert
context-aware framing alongside the existing profile text. Re-running an edit (re-applying
the same insertion) is safe — Markdown has no build step and no state; the worst case from
a double-apply is a duplicated paragraph, visible on read and trivially removed. Nothing in
this plan deletes operator data, touches code, or runs against a live project.

If a doc edit goes wrong, recover with git: `git checkout -- <path>` restores a tracked
file, and `rm docs/user/contexts.md` removes the new page. Because the example schema files
(`nagare.target.env.example`, `nagare.local.env.example`) and all code are explicitly out
of scope, there is no migration to roll back — an operator's existing in-repo profile keeps
working regardless of whether these docs are present, by the back-compat precedence rung.

The plan can be implemented in any order across M1/M2/M3, but M1 first is preferred because
M2's links point at `contexts.md`; if M2 is done first, the link-check in Validation will
report `BROKEN` until M1 lands, which is the intended signal, not a failure.


## Interfaces and Dependencies

This plan produces a **documentation set**, not code. The "interfaces" are the pages and
their cross-links; the "dependencies" are the behavioral plans whose delivered behavior the
docs describe.

The doc set after this plan:

- **New:** `docs/user/contexts.md` — the canonical target-contexts runbook (store layout,
  `nagarectl context` commands, `--context`/`NAGARE_CONTEXT`, precedence, worked
  multi-instance example, per-context Pulumi state, migration, troubleshooting).
- **Edited:** `docs/user/README.md` (capability row + index link + reframed
  "one target" section), `docs/user/getting-started.md` (active-context isolation +
  `NAGARE_CONTEXT` recipes + next-steps pointer),
  `docs/user/onboarding-bring-your-own-project.md` (`init` writes a context; multi-instance
  via contexts), `docs/user/local-development.md` (local = a `mode=local` context),
  `docs/user/reference.md` (the `nagarectl context` table + store paths + projection note),
  `docs/user/access.md` (base domain from the active context), and `CLAUDE.md` (isolation
  re-expressed over the active context, citing MasterPlan 17).

Cross-link graph (every arrow is a link this plan must create or keep resolving):
`README.md` → `contexts.md`; `getting-started.md` ↔ `contexts.md`; `onboarding-bring-your-own-project.md`
→ `contexts.md`; `local-development.md` → `contexts.md`; `reference.md` → `contexts.md`;
`contexts.md` → `CLAUDE.md`, `getting-started.md`, `provisioning-with-pulumi.md`,
`onboarding-bring-your-own-project.md`, `local-development.md`, `reference.md`, and
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`.

Dependencies (soft — docs describe delivered behavior; this plan is sequenced last and has
no hard code dependency, per
[MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md)):

- **EP-87**
  ([`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md`](87-target-context-model-store-and-resolver-for-nagarectl.md))
  — the context model, store layout, `current-context` pointer, and resolution precedence
  documented here.
- **EP-88**
  ([`docs/plans/88-nagarectl-context-command-group-and-context-selection.md`](88-nagarectl-context-command-group-and-context-selection.md))
  — the `nagarectl context` command group, the `--context` flag, and `init` writing a
  context; the source of truth for the exact command/flag spellings in `contexts.md` and
  `reference.md`.
- **EP-89**
  ([`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`](89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md))
  — `NAGARE_CONTEXT`-aware shell/`justfile` resolution and the context-aware guardrail
  documented in `getting-started.md`, `local-development.md`, and `CLAUDE.md`.
- **EP-90**
  ([`docs/plans/90-per-context-pulumi-state-and-config-projection.md`](90-per-context-pulumi-state-and-config-projection.md))
  — per-context Pulumi state and the config projection, documented in the `contexts.md`
  "Per-context Pulumi state" section and the `reference.md` projection note.
- **EP-91**
  ([`docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`](91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md))
  — manifests/Nix rendering from the active context, the basis for the `access.md`
  base-domain note.

No new libraries, services, or types are introduced by this plan. The only tools used are a
text editor and `grep`/`git` for the link and content checks above.
