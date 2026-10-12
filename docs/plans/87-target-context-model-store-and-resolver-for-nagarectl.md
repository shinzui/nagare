---
id: 87
slug: target-context-model-store-and-resolver-for-nagarectl
title: "Target context model store and resolver for nagarectl"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# Target context model store and resolver for nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [87-target-context-model-store-and-resolver-for-nagarectl.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today the nagare command-line tool (`nagarectl`) figures out **which GCP project,
region, registry, buckets, apps domain, VM, build architecture, and cloud-vs-local
mode it is acting on** by reading process environment variables. Those variables are
populated, per working directory, from one git-ignored file: `nagare.target.env` for a
cloud target, or `nagare.local.env` together with `NAGARE_MODE=local` for local mode.
Because that file and the in-repo Pulumi state are keyed to the current directory, the
unit of "a nagare instance" is a *checkout*: to act on a second project you make a
second clone, or you edit the file and re-run `direnv allow`. There is no notion of a
*named, selectable target*.

This ExecPlan builds the foundation for **first-class, named target contexts** — the
same idea `kubectl` uses with `--context` and `kubectl config use-context`. A
**context** is a complete, named target bundle stored in a user-level directory; an
operator can keep many (for example a `tan-nb-exp` cloud context, a `labs` context on a
different project, and a `local` laptop context), mark one as the default, and later
select any of them per command. This plan is the **keystone** of MasterPlan
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`: it defines the context
*contract* — the data model, the on-disk store layout, and the resolution precedence —
that every sibling plan consumes. It does **not** add the `nagarectl context` commands
or the `--context` flag (that is `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`),
the shell/`direnv` reader (`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`),
the per-context Pulumi state (`docs/plans/90-per-context-pulumi-state-and-config-projection.md`),
or the manifest de-hardcoding (`docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`).
It builds only the Haskell model, the store path helpers, the context file reader, and
the **context-aware resolver** inside `cli/nagarectl/src/Nagare/Target.hs`.

What someone gains after this change: the single Haskell resolution point,
`Nagare.Target.resolveTargetProfile`, becomes context-aware. A new function
`resolveActiveContext :: Maybe Text -> IO TargetProfile` resolves the *active context*
following a precise precedence — an explicit context name (later fed by the `--context`
flag) or the `NAGARE_CONTEXT` environment variable, then the `current-context` pointer
file, then an in-repo `nagare.target.env`/`nagare.local.env` (back-compat with the
older single-profile model), then the built-in `tan-nb-exp` defaults — while keeping the
existing rule that **per-field environment variables still win** over the chosen
context. How to see it working: a new unit-test group exercises every precedence tier
(a stored context resolves; `NAGARE_CONTEXT` selects it; a per-field env var overrides
one of its values; with nothing configured the historic `tan-nb-exp` defaults still
appear; a `mode=local` context resolves to `Local`). The pre-existing back-compat tests
that assert "defaults reproduce the tan-nb-exp worked example" continue to pass
unchanged, proving the generalization did not regress the single-profile behavior.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1: Context model + store layout. Add `ContextName` (newtype + smart constructor
  `mkContextName`/accessor `contextNameText`) and the XDG-aware store-path helpers
  (`nagareConfigDir`, `contextsDir`, `contextFilePath`, `currentContextPath`) to
  `cli/nagarectl/src/Nagare/Target.hs`. Document the `.env` schema (one `export VAR=value`
  line per field, matching `nagare.target.env.example`). Reserve the Pulumi-state
  location as a `ContextName`-derived helper (`contextStateDirName`), deferring its path
  scheme to `docs/plans/90-per-context-pulumi-state-and-config-projection.md`. Completed
  2026-07-01.
- [x] M2: Context-aware resolver. Add the context file reader (`parseContextEnv`,
  `readContextMap`, `readCurrentContext`), the selection logic (`selectContextName`,
  `loadActiveContextMap`), the field resolver over a context map (`resolveProfileFrom`),
  and the public `resolveActiveContext :: Maybe Text -> IO TargetProfile`. Rework
  `resolveTargetProfile` to delegate (`resolveActiveContext Nothing`), preserving the
  env-override-then-default semantics and the registry/bucket derivations. Completed
  2026-07-01.
- [x] M3: Unit tests in `cli/nagarectl/test/Spec.hs` — precedence ordering, env overrides
  context, in-repo-profile back-compat, defaults-reproduce-tan-nb-exp (extend the
  existing assertions with store isolation), mode folding (a `mode=local` context resolves
  to `Local`), `parseContextEnv` parsing, and `Nagare.Init.renderTargetEnv` emitting
  `NAGARE_MODE`/`NAGARE_LOCAL_OBJECT_STORE` so local contexts round-trip through the flat
  file schema. Completed 2026-07-01.
- [x] `cd cli/nagarectl && cabal build -v0 exe:nagarectl` succeeds and `cabal test`
  passes with the extended and new groups green. Completed 2026-07-01.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `TargetProfile` record in `cli/nagarectl/src/Nagare/Target.hs` (lines ~53–88)
  **already carries every context field** the MasterPlan enumerates — `tpProject`,
  `tpRegion`, `tpZone`, `tpRegistryHost`, `tpArtifactRegistryId`, `tpImageBucket`,
  `tpBackupBucket`, `tpBaseDomain`, `tpInstanceName`, `tpTargetPlatform`, `tpMode`,
  `tpLocalObjectStore` — because MasterPlan 16 already added `tpMode`/`tpLocalObjectStore`.
  So "extend the `TargetProfile` record" is effectively a no-op here: EP-87 does **not**
  add a context field to the record. The only genuinely new surface is the *store*, the
  *reader*, and the *selection precedence* layered into resolution. This is recorded so a
  future contributor does not waste effort re-deriving fields that already exist.

- The `nagarectl-test` suite already had multiple groups that mutate process-global
  state (`System.Environment` and, for the new EP-87 coverage, the current working
  directory). Tasty runs tests in parallel by default, so adding the context tests exposed
  a pre-existing harness assumption: the full suite could race, making
  `resolveTargetProfile reads NAGARE_MODE` observe `Cloud` while another test was clearing
  the environment, and making `AppDeploySpec` look for fixtures from the temporary CWD.
  The test tree now uses top-level `localOption (NumThreads 1)`, which matches the suite's
  process-global style and makes the full run deterministic. Evidence: the first full
  `cabal test` failed with those two symptoms; after serializing the tree, all 339 tests
  passed; after the renderer round-trip assertion was added, all 340 tests passed. Date:
  2026-07-01.

## Decision Log

Record every decision made while working on the plan.

- Decision: a context's on-disk form is the **same flat `export VAR=value` file** the
  existing profiles already use (`nagare.target.env`/`nagare.local.env`), one file per
  context, **not** a YAML/kubeconfig document.
  Rationale: the contract has two consumers — Haskell (`Nagare.Target`) and bash
  (`.envrc`, `scripts/lib/target.sh`, consumed by sibling
  `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`).
  A flat `export` file is sourced directly by bash with **no YAML parser**, and the
  schema is identical to today's `nagare.target.env.example`, so an in-repo profile is
  still honored and nothing in MasterPlan 12/16 has to change. A YAML kubeconfig would
  force a parser into the dependency-free bash layer for no functional gain in v1.
  Date: 2026-06-30

- Decision: the store lives under **`${XDG_CONFIG_HOME:-$HOME/.config}/nagare`** — context
  files at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` and a
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` text file naming the default.
  Rationale: a *user-level* store (not per-checkout) is the whole point — one operator,
  many named targets, one checkout. XDG is the cross-tool convention and is trivially
  overridable in tests (set `XDG_CONFIG_HOME` to a temp dir for a hermetic store).
  Date: 2026-06-30

- Decision: the **selection precedence** (which bundle becomes the active context) is,
  highest first: an explicit context name argument (later the `--context` flag from
  sibling `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`) **or**
  the `NAGARE_CONTEXT` environment variable > the `current-context` pointer > an in-repo
  `./nagare.target.env` (overlaid by `./nagare.local.env` when local) > the built-in
  `tan-nb-exp` default. **Separately**, per-field environment variables
  (`CLOUDSDK_*`, `NAGARE_*`) override the chosen context's fields (`env > context >
  default`). The two are orthogonal: the first picks the *bundle*, the second lets a
  single variable win over that bundle, preserving today's "environment wins" rule.
  Rationale: this mirrors `kubectl` (`--context`/`KUBECONFIG`-style selection) while
  retaining the exact env-override semantics MasterPlan 12 shipped, so existing operators
  and `.envrc` exports keep behaving identically.
  Date: 2026-06-30

- Decision: a context name that is *explicitly* requested (argument, `NAGARE_CONTEXT`, or
  the `current-context` pointer) but whose file is **missing** is a hard error, not a
  silent fall-through to defaults.
  Rationale: silently targeting the `tan-nb-exp` default when the operator asked for
  `labs` could push changes at the wrong project. Failing loudly is the fail-closed
  direction the isolation policy (CLAUDE.md) demands. The fall-through tiers (in-repo
  profile, defaults) apply only when **no** context was selected at all.
  Date: 2026-06-30

- Decision: `mode` is **folded into the context** — a context whose `.env` contains
  `export NAGARE_MODE=local` (plus the local registry host, base domain, and object
  store) *is* MasterPlan 16's local profile. There is no separate "local context"
  type; `tpMode` is just another resolved field.
  Rationale: MasterPlan 17 explicitly subsumes the `NAGARE_MODE` + `nagare.local.env`
  pair into "a context with `mode=local`". Keeping `tpMode` a plain field means
  `storeBackendFor` and the existing local-mode machinery work unchanged.
  Date: 2026-06-30

- Decision: the per-context **Pulumi-state location** is *reserved here but not designed
  here*. EP-87 exposes only a name-deriving helper (`contextStateDirName :: ContextName ->
  Text`) and does **not** add a state field to `TargetProfile`. The actual backend path
  scheme, the `Pulumi.dev.yaml` projection, and the relocation are owned by sibling
  `docs/plans/90-per-context-pulumi-state-and-config-projection.md`.
  Rationale: the state location is derived from the *context name*, which is not a
  resolved env field, so it does not belong on the field-bundle record; and its concrete
  layout is EP-90's Integration Point 5, not EP-87's. Reserving the name now lets EP-90
  build on a stable hook without EP-87 over-reaching.
  Date: 2026-06-30

- Decision: keep `nagarectl-test` single-threaded with `localOption (NumThreads 1)`.
  Rationale: the existing suite already uses process-global environment variables in
  target, mode, and command-helper tests, and EP-87 adds temporary CWD changes to prove
  in-repo profile back-compat. Parallel execution makes those tests nondeterministic even
  when each individual case restores state correctly. Serial execution is the narrowest
  harness change that reflects how the tests are written; it does not change product
  behavior.
  Date: 2026-07-01

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-87 is complete. `cli/nagarectl/src/Nagare/Target.hs` now exports the context-name type,
XDG store helpers, context `.env` parser/readers, `resolveActiveContext :: Maybe Text -> IO
TargetProfile`, and a back-compatible `resolveTargetProfile` that delegates through the
context-aware resolver. `cli/nagarectl/src/Nagare/Init.hs` now renders the full context
schema, including `NAGARE_MODE` and `NAGARE_LOCAL_OBJECT_STORE`, so a local
`TargetProfile` can round-trip through the same flat file format. The implementation
preserves the historic default profile, per-field env overrides, derived registry/bucket
defaults, and local-mode object-store behavior while adding fail-closed named-context
selection.

Validation evidence from 2026-07-01:

```text
cd cli/nagarectl && cabal build -v0 exe:nagarectl
Result: exit 0; only pre-existing app/Main.hs name-shadowing warnings.

cd cli/nagarectl && cabal test --test-options='--pattern "EP-87"'
Result: 1 EP-87 test passed.

cd cli/nagarectl && cabal test
Result: all 340 tests passed.
```

No runtime store migration is included here; writing and managing context files remains
owned by `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`.

