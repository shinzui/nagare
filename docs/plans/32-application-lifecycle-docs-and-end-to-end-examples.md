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

Full plan before trimming: [32-application-lifecycle-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1: `docs/user/app-lifecycle.md` written and linked from `deploying-apps.md` and `README.md`. (2026-06-09)
- [x] M2: `docs/user/config-reference.md` updated for health check, resource limits, multiple domains. (2026-06-09)
- [x] M3: runnable example config (`cluster/examples/app-lifecycle-demo/`) verified by `nagarectl deploy --dry-run`; live walk-through deferred (cluster powered down) with a note. (2026-06-09)

## Surprises & Discoveries

- **`deploying-apps.md` had drifted from the shipped model** and needed more than a
  link. Its "verbatim" `hello` config still showed `domain = Just dom'`, a
  two-field `Resources`, a bare `EnvLiteral`, and no `healthCheck`; its
  "byte-for-byte golden" Service YAML was missing the `labels` and `envFrom`
  blocks the renderer now emits (from EP-29's managed-by label and EP-25's env
  store). M1's link work therefore expanded to correcting the stale config block,
  the rendered YAML, the `env :: Map EnvName ScopedEnvVar` bullet, the singular
  `domain`→`domains` prose, and the URL section — so the page is truthful again.
  The corrected config matches `cluster/examples/hello-knative-service/nagare/Config.hs`
  and the YAML matches `cli/nagare-dsl/test/golden/hello.service.yaml`. (2026-06-09)

- **The example renders the canonical domain as the URL and one DomainMapping per
  domain, confirmed live by dry-run.** `nagarectl deploy --dry-run` on
  `app-lifecycle-demo` prints `URL: https://demo.example.com` (the canonical of
  two) and two DomainMapping documents (canonical first), plus the
  `readinessProbe`/`livenessProbe`/`startupProbe`, the `resources.limits` block,
  and the `nagare.dev/managed-by: nagarectl` label — matching the `rich.*` goldens.
  The dry-run also injects the `NAGARE_*` generated env vars (EP-26), which only
  appear on the deploy path, not in the pure `renderService` golden. (2026-06-09)

- **`nagarectl` is not on PATH; running the dry-run needs the cabal bin plus a GHC
  env file.** From `cli/nagarectl`, `cabal list-bin nagarectl` gives the binary,
  and the loader's child `runghc` needs `NAGARE_GHC_ENVIRONMENT` pointed at
  `cli/nagare-dsl/.ghc.environment.aarch64-darwin-9.12.3` to resolve `nagare-dsl`
  from the example directory — exactly the `--ghc-env` wrinkle `deploying-apps.md`
  documents. (2026-06-09)

## Decision Log

- Decision: Put the lifecycle commands in a new `docs/user/app-lifecycle.md` rather than expanding
  `docs/user/deploying-apps.md` in place.
  Rationale: `deploying-apps.md` is the "first deploy" on-ramp; the lifecycle commands are a distinct
  day-2 topic with enough surface (eight commands) to warrant their own page. `deploying-apps.md` links
  to it, matching how `static-hosting.md` references related pages.
  Date: 2026-06-10

- Decision: While adding the lifecycle link, also correct `deploying-apps.md`'s stale `hello` config and
  rendered Service YAML to match the shipped model, rather than leaving them inaccurate.
  Rationale: That page labels its config "verbatim" and its YAML "byte-for-byte the golden contract", but
  EP-29 (managed-by label, `domains`, resource limits, `healthCheck`) and EP-25 (`ScopedEnvVar`, the
  `envFrom` store) had silently invalidated both. A docs initiative whose acceptance is "every command and
  transcript matches actual behavior" cannot leave a sibling page asserting false byte-for-byte claims;
  the fix is small and verified against the current example file and golden.
  Date: 2026-06-09

- Decision: Verify the example with `nagarectl deploy --dry-run` and defer the live end-to-end walk-through,
  recording it as deferred in both the guide's status box and the example README.
  Rationale: `nagare-01` is powered down (the whole operator guide carries the same 🟡 caveat). The dry-run
  exercises the full render path — probes, limits, per-domain DomainMappings, the managed-by label, and the
  canonical URL — which is the part this plan documents; the live verbs read/patch cluster state and are
  honestly marked "intended behaviour" until the box is back up.
  Date: 2026-06-09

## Outcomes & Retrospective

All three milestones are complete; the initiative's docs-and-examples deliverable is done.

**What shipped.**

- `docs/user/app-lifecycle.md` — the new day-2 guide: a commands-at-a-glance block, one section per
  command group (list/get, logs, restart/stop/delete, deployment history) with transcripts copied from
  the shipped output formats (`formatAppList`, `printAppSummary`, `enrichFromConfig`,
  `formatReleasesTable`, and the exact stop/restart/delete/GC messages), and a "How it works" section
  (managed-by label, `user-container` logs, per-app history ConfigMap).
- `docs/user/config-reference.md` — the `Deployment` record updated to `domains :: [DomainSpec]`,
  `env :: Map EnvName ScopedEnvVar`, and `healthCheck`; new sections for `Resources` requests-and-limits,
  `HealthCheck`/`mkHealthCheck`/`httpHealthCheck` (with the documentation-only `expectedStatus` note), and
  `DomainSpec`/`mkDomains`/`canonicalDomain` (with the deferred-redirect note). All snippets use the exact
  exported constructors and field names.
- `cluster/examples/app-lifecycle-demo/` — a `nagare/Config.hs` (webService preset + health check + limits
  + two domains) and a `README.md` scripting the full walk-through. Verified by
  `nagarectl deploy --dry-run`, which renders all three probe blocks, `resources.limits`, the managed-by
  label, two DomainMappings, and `URL: https://demo.example.com`.
- Link wiring: `deploying-apps.md` (a "Next" pointer plus inline references) and `README.md` (an index
  sub-bullet under item 8) both link the new guide.

**What expanded beyond the plan.** Correcting the stale `hello` config and rendered YAML in
`deploying-apps.md` (see Surprises) — necessary to keep that page truthful after EP-29/EP-25, and within
the spirit of "docs match shipped behavior".

**Verification.** Live cluster run deferred (`nagare-01` down); the render path is proven by dry-run and by
the `nagare-dsl`/`nagarectl` golden + unit suites the siblings left green. Every fenced block in the
new/edited docs carries a language tag (checked: tagged-opening count equals closing-fence count per file).

**Follow-ups.** When `nagare-01` returns, run the `app-lifecycle-demo` walk-through end-to-end and paste a
real transcript into the guide and example README, flipping their status boxes from 🟡 to ✅. Hard HTTP
redirects to the canonical domain remain EP-29-deferred future work, noted in both the config reference and
the lifecycle guide.

The only "interface" this plan must keep accurate is that documented commands, flags, and config field
names match what those plans shipped. Re-read their final Interfaces sections before writing, in case a
flag name changed during implementation.
