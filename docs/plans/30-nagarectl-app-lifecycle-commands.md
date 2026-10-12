---
id: 30
slug: nagarectl-app-lifecycle-commands
title: "nagarectl app lifecycle commands"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# nagarectl app lifecycle commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It is self-contained: you can
implement it without reading the MasterPlan or any sibling plan. It introduces a new module
(`Nagare.App`) whose helpers a sibling plan
(`docs/plans/31-application-deployment-history-and-deployments-commands.md`) also reuses — that
relationship is noted but creates no dependency in this direction; this plan stands alone.

Full plan before trimming: [30-nagarectl-app-lifecycle-commands.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/30-nagarectl-app-lifecycle-commands.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today `nagarectl` can only *create* an application. `nagarectl deploy` builds, pushes, applies a
Knative Service, waits for readiness, and prints a URL — and then there is nothing more the tool can
do. To see which apps exist, inspect one, read its logs, restart it, take it offline, or remove it, an
operator must drop to raw `kubectl` and know the Knative resource names by heart. This plan closes that
gap with six lifecycle commands under a new `app` namespace:

```text
nagarectl app list
nagarectl app get NAME
nagarectl app logs NAME [--follow]
nagarectl app restart NAME
nagarectl app stop NAME
nagarectl app delete NAME
```

After this plan, an operator can run `nagarectl app list` and see every Nagare-managed application in
a namespace with its URL and readiness; `nagarectl app get notes` to see one app's image, latest
revision, URL, and ready state; `nagarectl app logs notes --follow` to tail the running container's
logs; `nagarectl app restart notes` to roll a fresh revision; `nagarectl app stop notes` to take it
offline (recoverably); and `nagarectl app delete notes` to remove the Service, its DomainMappings, and
its deployment-history record. All of it goes through the same `kubectl` shell-out machinery the rest
of `nagarectl` already uses, so it works against the same cluster `nagarectl deploy` targets.

You can see it working end-to-end: deploy an app with `nagarectl deploy`, then `nagarectl app list`
shows it, `nagarectl app get NAME` describes it, `nagarectl app logs NAME` prints its logs,
`nagarectl app stop NAME` makes its URL stop serving, and `nagarectl app delete NAME` removes it so a
subsequent `app list` no longer shows it.

## Progress

- [x] M1: `Nagare.App` module with `appIdentityOrDie`, `streamServiceLogs`, and the pure helpers; added to the cabal library; unit tests for the pure helpers. (2026-06-10)
- [x] M2: `app list` and `app get` wired into the CLI parser; handlers implemented (`runAppList`/`runAppGet`/`printAppSummary`/`enrichFromConfig`); `--help` surfaces verified. (2026-06-10)
- [x] M3: `app logs [--follow]`, `app restart`, `app stop`, `app delete` wired; handlers implemented; `--help` surfaces verified. (2026-06-10)
- [x] M4: `nagarectl-test` green (102 tests); `--help` transcripts captured below; live cluster run deferred (no cluster mutated during implementation), as M4 permits. (2026-06-10)

## Surprises & Discoveries

- **`appIdentityOrDie` already existed in `cli/nagarectl/app/Main.hs`** before this plan started —
  EP-25 (env/secret, MasterPlan 5) added it as a *site-aware* resolver: it tries the Deployment
  loader and falls back to the site loader on `Load.UnexpectedKind`, so `env`/`secret` commands work
  on app, static-site, and server-site configs. The IP2 contract, however, specifies a
  *Deployment-only* `appIdentityOrDie` living in the new `Nagare.App` module. To satisfy both without
  a name clash, the pre-existing Main-local function was **renamed to `configIdentityOrDie`** (its
  behaviour unchanged; it is the more accurate name — it resolves identity from a config of *any*
  kind) and the IP2 `Nagare.App.appIdentityOrDie` was added fresh. `Nagare.App` is the canonical home
  for the Deployment-only helper that EP-31's `deployments` commands consume. (2026-06-10)

- **The `app` commands need no config file.** Lifecycle operations target a *deployed* app by name +
  namespace and read live Knative state via `kubectl`, so they compile and run with no DSL dependency
  beyond `appDomains`/`extractAppSummary`. The only config touch points are the optional `--file`
  enrichment in `app get` (EP-29's domains/health/limits) and `--file` domain discovery in
  `app delete` — both guarded by `doesFileExist` and silently skipped when absent. This confirms the
  MasterPlan's "soft, not hard" EP-29 dependency: EP-30 is fully functional without EP-29, gaining
  only richer `app get` output and label-filtered `app list` once EP-29's label is present (it now is).
  (2026-06-10)

- **Live cluster run deferred.** Implementing this plan does not require mutating the cluster, and
  creating real Knative Services / DomainMappings in `tan-nb-exp` is an outward-facing action outside
  the scope of "implement the plan". Per M4's explicit provision (mirroring
  `docs/masterplans/4-application-build-modes-for-nagare.md`), the `kubectl` paths are validated by
  the pure-helper unit tests (arg builders, JSON extractors, formatters) and `--help`/argument
  inspection; the end-to-end live transcript is left for a follow-up against a reachable cluster.
  (2026-06-10)

## Decision Log

- Decision: `app stop` takes the app offline by making the Knative Service cluster-local in a
  recoverable way. Concretely, implement stop as `kubectl patch ksvc <name> -n <ns> --type=merge` to
  add the label `networking.knative.dev/visibility: cluster-local` (which removes the public route so
  the public URL stops serving) — and document that `nagarectl deploy` or `nagarectl app restart NAME`
  restores public serving (the renderer re-applies a Service without that label; `restartApp` also
  strips it). If, during implementation, the `cluster-local` label proves unsuitable on this
  single-node Kourier setup, fall back to deleting the Service while preserving the deployment-history
  ConfigMap (so the app still appears in `deployments list` and can be re-deployed). Record the final
  mechanism here when chosen.
  Rationale: Knative has no native pause. The MasterPlan fixes the *semantics* — offline but
  recoverable, history preserved — and leaves the exact `kubectl` mechanism to this plan. The
  `cluster-local` label is the least destructive way to stop public traffic without losing the Service.
  Date: 2026-06-10

- Decision: `app restart` forces a new revision by patching a Nagare-owned annotation
  (`nagare.dev/restartedAt`) on the Service's `spec.template.metadata.annotations`, which Knative
  treats as a template change and rolls a fresh revision. The annotation value is a timestamp string
  supplied by the caller (computed via `Nagare.Image.computeTag`, which already yields a UTC
  `YYYYMMDD-HHMMSS` string) so the function stays free of hidden clock calls.
  Rationale: Annotating the template is the standard, side-effect-free way to force a Knative rollout
  without changing the image or rebuilding. Using the existing `computeTag` keeps timestamp formatting
  consistent with the rest of the tool.
  Date: 2026-06-10

- Decision: `app list` filters Knative Services by the label `nagare.dev/managed-by=nagarectl` (stamped
  by the renderer in `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md`).
  When run against a cluster whose Services predate that label, the filter yields nothing; `app list`
  therefore accepts `--all` to list every Knative Service in the namespace unfiltered, and prints a
  one-line note when the filtered list is empty suggesting `--all`.
  Rationale: The label is the clean way to distinguish Nagare apps from other Knative workloads, but
  the command must remain useful before every app has been re-deployed with the label.
  Date: 2026-06-10

- Decision: Every `app NAME` command takes a required positional `NAME` and an optional `-n/--namespace`
  (default `personal`); it does *not* require a config file in the working directory. A `--file` config
  is accepted only where it adds value (e.g. `app get` enriching output with configured fields, or
  `app delete` reading the declared domains).
  Rationale: Lifecycle operations target a *deployed* app by name; requiring a `Config.hs` to act on a
  live app would be friction. Defaulting the namespace to `personal` matches `defaultNamespace` in the
  DSL.
  Date: 2026-06-10

- Decision: Place the IP2 `appIdentityOrDie` (Deployment-only) in `Nagare.App`, and rename the
  pre-existing site-aware resolver in `cli/nagarectl/app/Main.hs` (added by EP-25) to
  `configIdentityOrDie`. The `app` handlers do not call either (they take `NAME` positionally); the
  Deployment-only helper exists in `Nagare.App` for the sibling `deployments` commands (EP-31) per the
  IP2 contract.
  Rationale: The contract fixes the name `appIdentityOrDie` and its Deployment-only behaviour in
  `Nagare.App`; the env/secret path genuinely needs the site fallback, so the two cannot be the same
  function. Renaming the env/secret one to `configIdentityOrDie` frees the contract name and is the
  more accurate description (it resolves identity from a config of any kind). See Surprises.
  Date: 2026-06-10

- Decision: Keep the `app stop` mechanism as the `networking.knative.dev/visibility: cluster-local`
  label patch (the MasterPlan's recoverable-offline semantics), and `app restart`'s
  `nagare.dev/restartedAt` annotation that also clears that label (a `null` in the merge patch). The
  exact cluster-local label key was *not* confirmed against a live single-node Kourier cluster during
  implementation (no cluster was mutated); the documented fallback (delete the Service while keeping
  the history ConfigMap) remains available if the label proves unsuitable. The patch JSON and the
  label-clearing `null` are unit-tested via `restartPatch`.
  Rationale: M4's live run is deferred (see Surprises); the mechanism is implemented and unit-tested
  at the arg/patch level, and the MasterPlan-fixed semantics are preserved. A future live run confirms
  or triggers the documented fallback without changing the command surface.
  Date: 2026-06-10

## Outcomes & Retrospective

Completed 2026-06-10. `cli/nagarectl` builds and `nagarectl-test` is green (102 tests).

What exists now that did not before:

- `cli/nagarectl/src/Nagare/App.hs` — the `Nagare.App` library module (IP2): `appIdentityOrDie`
  (Deployment identity), `LogTarget`/`streamServiceLogs`/`logArgs` (kubectl log streaming),
  `AppSummary` + `listAppSummaries`/`getAppSummary`/`listManagedApps` (live-state queries) with the
  pure extractors `extractAppSummary`/`extractAppSummaries`/`extractDomainsFor`/`parseServiceNames`/
  `formatAppList`, and the lifecycle ops `restartApp`/`restartPatch`/`stopApp`/`deleteApp`/
  `appDomains`. Registered in `nagarectl.cabal`.
- Six new CLI commands under `nagarectl app`: `list` (label-filtered, `--all` to widen), `get`
  (live state + optional EP-29 config enrichment), `logs` (`--follow`/`--tail`), `restart`
  (annotation bump + label clear + wait), `stop` (cluster-local label), `delete` (Service +
  DomainMappings + history ConfigMap).
- 13 new unit tests for the pure helpers (arg builders, JSON extractors, patch JSON, formatter).

Verification: `cabal test` green; `--help` transcripts for every subcommand captured in Concrete
Steps. The live cluster lifecycle run is deferred (no cluster mutated) per M4.

Notes for downstream:

- EP-31 (`docs/plans/31-application-deployment-history-and-deployments-commands.md`) reuses
  `Nagare.App.streamServiceLogs` (passing `ltRevision`) and `appIdentityOrDie`, and must delete its
  history ConfigMap under the name `nagare-app-deployments-<app>` (which `deleteApp` already removes
  with `--ignore-not-found`).
- The env/secret site-aware identity resolver was renamed `appIdentityOrDie → configIdentityOrDie`
  in `app/Main.hs`; future edits to env/secret should use `configIdentityOrDie`, and the
  Deployment-only `Nagare.App.appIdentityOrDie` for app/deployments paths.

