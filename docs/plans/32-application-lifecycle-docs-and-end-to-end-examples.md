---
id: 32
slug: application-lifecycle-docs-and-end-to-end-examples
title: "Application lifecycle docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# Application lifecycle docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the final child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It documents and demonstrates behavior
delivered by its sibling plans. It hard-depends on
`docs/plans/30-nagarectl-app-lifecycle-commands.md` (the `app` commands) and
`docs/plans/31-application-deployment-history-and-deployments-commands.md` (the `deployments` commands):
a docs plan must describe commands that actually work. It soft-depends on
`docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md` (the model
fields) so the config reference can document health checks, resource limits, and multiple domains; if
EP-29 has not landed, document the commands and add a short "coming with the extended model" note for
the new config fields, then fill it in once EP-29 merges.


## Purpose / Big Picture

Nagare's value is that an operator can run a whole personal PaaS from a typed config and one CLI. The
sibling plans added the missing day-2 surface — listing, inspecting, logging, restarting, stopping, and
deleting apps, plus a deployment history — but a capability nobody can find is a capability that does
not exist. This plan writes the user-facing documentation and a runnable example so an operator can go
from "I deployed an app" to "I operate an app" without reading Haskell source or this repo's plans.

After this plan, `docs/user/` contains a new guide, `docs/user/app-lifecycle.md`, that walks through the
`app` and `deployments` commands with real transcripts; the existing `docs/user/deploying-apps.md` links
to it and mentions the new lifecycle verbs; and `docs/user/config-reference.md` documents the new
`Deployment` fields (health check, resource limits, multiple domains). A runnable example app under
`cluster/examples/` (or an existing example, extended) demonstrates a config that declares a health
check, both resource requests and limits, and two domains, and a scripted end-to-end walk-through that
deploys it and exercises every lifecycle command.

You can see it working by following the guide top to bottom against a cluster: every command in it runs
and produces the shown output. The guide is the acceptance test.


## Progress

- [ ] M1: `docs/user/app-lifecycle.md` written and linked from `deploying-apps.md` and `README.md`.
- [ ] M2: `docs/user/config-reference.md` updated for health check, resource limits, multiple domains.
- [ ] M3: runnable example config + end-to-end walk-through verified against a cluster (or deferred with a note).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Put the lifecycle commands in a new `docs/user/app-lifecycle.md` rather than expanding
  `docs/user/deploying-apps.md` in place.
  Rationale: `deploying-apps.md` is the "first deploy" on-ramp; the lifecycle commands are a distinct
  day-2 topic with enough surface (eight commands) to warrant their own page. `deploying-apps.md` links
  to it, matching how `static-hosting.md` references related pages.
  Date: 2026-06-10


## Context and Orientation

This plan edits Markdown only, under `docs/user/`, plus possibly one example project under
`cluster/examples/`. No Haskell changes.

**The docs directory — `docs/user/`.** Existing pages include `getting-started.md`,
`deploying-apps.md`, `static-hosting.md`, `config-reference.md`, `reference.md`, `secrets.md`,
`observability.md`, `troubleshooting.md`, and `README.md` (the index). The house style, visible at the
top of `deploying-apps.md` and `static-hosting.md`:

- An H1 title (`# Deploying apps`).
- A short status box using a colored-circle emoji and plain-English status (e.g. "🟡 Works, but live
  end-to-end testing is pending").
- An intro paragraph naming the audience ("for **app developers**") and the promise.
- A fenced code block showing "one command does it", then progressive detail.
- `>` callout blocks linking to rationale or related pages.

Use two newlines after every heading. Every fenced block must carry a language tag (`bash`, `text`,
`haskell`, `yaml`). Match the existing voice: concise, second person, command-first.

**What the sibling plans deliver (the source of truth for what to document).**

- From `docs/plans/30-nagarectl-app-lifecycle-commands.md`: `nagarectl app list [-n NS] [--all]`,
  `app get NAME [-n NS] [--file F]`, `app logs NAME [--follow] [--tail N] [-n NS]`,
  `app restart NAME [-n NS]`, `app stop NAME [-n NS]`, `app delete NAME [-n NS] [--file F]`. Semantics:
  `list` shows Nagare-managed apps (label `nagare.dev/managed-by=nagarectl`; `--all` lists every Knative
  Service); `stop` makes the app cluster-local (public URL stops serving) and is reversed by `deploy`/
  `restart`; `restart` rolls a fresh revision; `delete` removes the Service, DomainMappings, and history.
- From `docs/plans/31-application-deployment-history-and-deployments-commands.md`: every successful
  `nagarectl deploy` records a deployment in `nagare-app-deployments-<app>`; `deployments list NAME`
  prints the history (newest-first, live one starred); `deployments logs NAME [DEPLOYMENT_ID]` streams
  the live or a specific past revision's logs; `nagarectl deploy` gained a `--source` provenance flag.
- From `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md`: the
  `Deployment` config gains an optional `healthCheck` (HTTP probe: path, port, scheme, timing, opt-in
  liveness/startup), resource *limits* alongside requests (via `cpuLimit`/`memoryLimit` on `Resources`),
  and `domains :: [DomainSpec]` (list with exactly one `canonical`) replacing the single
  `domain :: Maybe Domain`. The smart constructors are `mkHealthCheck`/`httpHealthCheck`, `mkDomains`,
  and the extended `Resources` literal.

**The config reference — `docs/user/config-reference.md`.** It documents the fields of a `Deployment`
config. You will add sections for the three new field groups with example Haskell snippets that
type-check against EP-29's API. Read the existing file first to match its per-field format.

**Examples — `cluster/examples/`.** Existing example projects (e.g. `sqlite-litestream`) show the
project layout: a `nagare/Config.hs` plus a `README.md`. You will add (or extend) an example whose
`Config.hs` declares the new fields, so the guide can reference a real, committed config.


## Plan of Work

### Milestone 1 — The lifecycle guide

Create `docs/user/app-lifecycle.md` in the house style. Structure:

1. Title + status box + one-paragraph intro ("Once an app is deployed, operate it without `kubectl`.").
2. A "Commands at a glance" fenced `text` block listing all eight commands.
3. One short section per command group with a real transcript:
   - **Listing and inspecting** (`app list`, `app get`) — show the table and the detail output from
     `docs/plans/30-...`'s Concrete Steps.
   - **Logs** (`app logs`, and the relationship to `deployments logs`) — `--follow`/`--tail`.
   - **Restart, stop, delete** — explain `stop` is recoverable (cluster-local) and `delete` is
     permanent and also removes deployment history; explain how to bring a stopped app back.
   - **Deployment history** (`deployments list`, `deployments logs`, the `--source` flag on `deploy`) —
     show the starred table and the id→revision log behavior, including the "revision garbage-collected"
     error.
4. A "How it works" callout: apps are Knative Services labeled `nagare.dev/managed-by: nagarectl`; logs
   come from the `user-container`; history lives in a per-app ConfigMap. Keep it brief and link to
   `reference.md`.

Link the new page: add a line to `docs/user/deploying-apps.md` (near the top or in a "Next steps"
section) pointing to `app-lifecycle.md`, and add it to the index in `docs/user/README.md`.

Acceptance: the page exists, every command shown matches the sibling plans' actual flags and output, and
all fenced blocks have language tags.

### Milestone 2 — Config reference for the new model fields

Update `docs/user/config-reference.md` with three new subsections, each with a type-checking Haskell
snippet:

- **Health checks** — a `httpHealthCheck "/healthz"` example and a fuller `mkHealthCheck` example
  turning on liveness/startup; note honestly that Knative's HTTP probe does not assert a status code
  (the `expectedStatus` field is documentation-only), matching EP-29's Decision Log.
- **Resource limits** — show a `Resources` literal (or the preset overlay) setting `cpuLimit`/
  `memoryLimit` alongside `cpu`/`memory`, and explain requests-vs-limits in one sentence.
- **Multiple domains** — show `mkDomains [("app.example.com", True), ("www.example.com", False)]` and
  explain the canonical marker drives the printed URL and that each domain becomes a DomainMapping; note
  that hard HTTP redirects to the canonical domain are not yet installed (EP-29 deferred them).

If EP-29 has not yet merged, add these subsections with a leading note "Available once the extended
application model lands (see docs/plans/29-…)" and verify the snippets compile once it does.

Acceptance: the snippets match EP-29's exported constructors and field names exactly.

### Milestone 3 — Runnable example and end-to-end walk-through

Add or extend an example under `cluster/examples/` (e.g. `cluster/examples/app-lifecycle-demo/`) with a
`nagare/Config.hs` that uses the `webService` preset and then sets a health check, resource limits, and
two domains via the EP-29 API, plus a `README.md` that scripts the full walk-through:

```bash
nagarectl deploy --source "$(git rev-parse --short HEAD)"
nagarectl app list
nagarectl app get <name>
nagarectl app logs <name> --tail 50
nagarectl deployments list <name>
nagarectl app restart <name>
nagarectl app stop <name>
nagarectl app restart <name>
nagarectl app delete <name>
```

Run it against a cluster, confirm each command behaves as documented, and paste the real transcript into
the guide (Milestone 1) and/or the example README as captured evidence. If no cluster is reachable in
the implementation environment, mark the example "verified by dry-run and unit tests; live run deferred"
and update the status box accordingly, mirroring how
`docs/masterplans/4-application-build-modes-for-nagare.md` recorded a deferred cluster step.

Acceptance: the example config loads (`nagarectl deploy --dry-run` succeeds and shows the probe/limits/
multiple-DomainMapping YAML), and the walk-through is captured.


## Concrete Steps

From the repo root:

```bash
# Verify the example config renders the new fields without a cluster:
cd cluster/examples/app-lifecycle-demo
nagarectl deploy --dry-run

# Check Markdown fenced blocks all have language tags (no bare ``` fences):
cd /Users/shinzui/Keikaku/bokuno/nagare
rg -n '^```$' docs/user/app-lifecycle.md docs/user/config-reference.md || echo "all fences tagged"
```

There is no separate doc build; the docs are read as Markdown in the repo. The "test" is that every
command in the guide runs and matches its shown output.


## Validation and Acceptance

1. `docs/user/app-lifecycle.md` exists, is linked from `deploying-apps.md` and `README.md`, and every
   command and transcript in it matches the actual behavior delivered by EP-30 and EP-31 (verified by
   running them, or by dry-run + unit tests with the live run deferred and noted).
2. `docs/user/config-reference.md` documents `healthCheck`, resource limits, and multiple domains with
   Haskell snippets that compile against EP-29's API.
3. The example config under `cluster/examples/` loads (`nagarectl deploy --dry-run`) and renders the new
   YAML blocks; the end-to-end walk-through is captured.
4. No bare ``` fences in the new/edited docs (every block has a language tag).


## Idempotence and Recovery

Editing Markdown and an example config is fully idempotent; re-running the dry-run or the walk-through
is safe. The end-to-end walk-through ends with `app delete`, which uses `--ignore-not-found`, so it can
be re-run cleanly. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

No code dependencies; this plan consumes the user-facing behavior of:

- `docs/plans/30-nagarectl-app-lifecycle-commands.md` — the `app list/get/logs/restart/stop/delete`
  commands and their flags/output.
- `docs/plans/31-application-deployment-history-and-deployments-commands.md` — the `deployments
  list/logs` commands, the `--source` flag on `deploy`, and the per-app history ConfigMap.
- `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md` — the
  `healthCheck`, resource-limit, and multiple-domain config fields and their smart constructors.

The only "interface" this plan must keep accurate is that documented commands, flags, and config field
names match what those plans shipped. Re-read their final Interfaces sections before writing, in case a
flag name changed during implementation.
