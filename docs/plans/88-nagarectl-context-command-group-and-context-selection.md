---
id: 88
slug: nagarectl-context-command-group-and-context-selection
title: "nagarectl context command group and --context selection"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# nagarectl context command group and --context selection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [88-nagarectl-context-command-group-and-context-selection.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/88-nagarectl-context-command-group-and-context-selection.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today the `nagarectl` command-line tool resolves *where* it deploys — which Google
Cloud project, region, registry, buckets, apps domain, VM name, build platform, and
whether it is in cloud or local mode — from process environment variables that are
populated, per working directory, by a single git-ignored file (`nagare.target.env`
for a cloud target, or `nagare.local.env` with `NAGARE_MODE=local` for a local one).
To run a *second* target an operator needs a second checkout, or must edit that file
and re-run `direnv allow`. There is no concept of a named, selectable target.

After this plan an operator can keep **many named targets in one place and pick one
per command**, exactly the way `kubectl` works with contexts. Concretely, the
following becomes possible without leaving the current directory and without editing
any tracked or git-ignored file:

```text
$ nagarectl context create labs --project tan-ng-labs --base-domain labs.topagentnetwork.net
Wrote context 'labs' (~/.config/nagare/contexts/labs.env)

$ nagarectl context use labs
Switched to context 'labs'

$ nagarectl context list
CURRENT  NAME     PROJECT      BASE DOMAIN
*        labs     tan-ng-labs  labs.topagentnetwork.net
         default  tan-nb-exp   apps.example.com

$ nagarectl --context default deploy --dry-run     # one-off override, ignores current-context
... renders against project tan-nb-exp ...

$ nagarectl deploy --dry-run                        # uses the current context: labs
... renders against project tan-ng-labs ...
```

The user-visible behavior this plan delivers, and that the Validation section
proves, is: (1) a `nagarectl context` command group — `list`, `current`, `use`,
`show`, `create`, `delete` — that manages a user-level store of named target
bundles; (2) a global `--context <name>` flag (and the `NAGARE_CONTEXT` environment
variable) that selects, per command, which target *every* command
(`deploy`, `db`, `storage`, `app`, …) acts on; and (3) `nagarectl init` writing a
*named context* into that store and marking it current, while still writing a plain
`./nagare.target.env` when invoked without a name, so the existing single-target
workflow is unchanged.

This plan is the Haskell command-line surface of MasterPlan 17
(`docs/masterplans/17-first-class-target-contexts-for-nagare.md`). It is one of two
parallel "consumer" plans in Wave 2; the other, `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`,
does the equivalent for the bash scripts and is disjoint from this one (bash vs
Haskell, different files).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1 — `nagarectl context` command group (`list`/`current`/`use`/`show`/`create`/`delete`) implemented against EP-87's store; `context create` reuses the target-field derivations; behavioral tests for the round trip. Started and completed 2026-07-01.
- [x] M2 — global `--context <name>` flag added to the top-level parser and threaded into every command's target resolution via EP-87's `resolveActiveContext`; the build-context-dir override renamed to `--build-context`; `NAGARE_CONTEXT` honored through the resolver. Completed 2026-07-01.
- [x] M3 — `nagarectl init [NAME]` writes a named context into the store and marks it current when `NAME` is given; still writes `./nagare.target.env` when it is not; Pulumi seeding unchanged. Completed 2026-07-01.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- EP-87 landed the context type, store paths, parser, and resolver directly in `Nagare.Target`, not in a separate `Nagare.Target.Context` module. EP-88 therefore consumes and extends `Nagare.Target` with the small store mutation/list helpers it needs instead of introducing a second module.
- `test/fixtures/app-with-task/nagare/Config.hs` no longer compiles against the current `Deployment` record because it predates later required fields (`brokers`, `access`). Manual dry-run selector validation used the maintained `test/fixtures/app/kizashi/Config.hs` app fixture plus `cdn disable --dry-run` for visible project output.

## Decision Log

Record every decision made while working on the plan.

- Decision: the target-selection flag is a **global** `--context <name>` placed
  before the subcommand (kubectl-style: `nagarectl --context labs deploy`), not a
  per-subcommand flag.
  Rationale: MasterPlan 17's Vision specifies the kubectl model verbatim
  (`nagarectl --context labs deploy …`). A global flag means *every* command —
  current and future — gets selection for free, with no per-command wiring beyond
  passing one value to the resolver; a per-subcommand flag would have to be added to
  ~25 option parsers and is easy to forget on a new command. The single global flag
  also matches `NAGARE_CONTEXT` (one selection mechanism, two spellings) and matches
  EP-89's bash side, where the selection is process-wide.
  Date: 2026-06-30

- Decision: rename the existing deploy/worker/app-deploy build-context-directory
  override from `--context`/`-c` to **`--build-context`** (retaining `-c`), freeing
  the long name `--context` for target selection.
  Rationale: `deploy`, `worker deploy`, and `app deploy` already define
  `--context`/`-c` meaning "override the Docker/nixpacks *build context directory*"
  (`cli/nagarectl/app/Main.hs`, `deployOptsParser`/`appDeployOptsParser`/
  `workerDeployOptsParser`). Reusing the same long name for a global *target*
  selector would let `nagarectl deploy --context labs` silently bind `labs` to the
  build directory and deploy to the wrong place — a dangerous footgun. Renaming the
  lesser-used build override is a small, documented breaking change justified by the
  MasterPlan making `--context` the central selection verb. The short `-c` stays on
  `--build-context` to limit muscle-memory breakage; the global target selector has
  no short form.
  Date: 2026-06-30

- Decision: thread the explicit `--context` flag *value* into each command's call to
  EP-87's `resolveActiveContext`, rather than mutating the process environment
  (e.g. `setenv NAGARE_CONTEXT`) at startup.
  Rationale: explicit threading keeps the precedence honest and local — an explicit
  `--context labs` outranks an ambient `NAGARE_CONTEXT=other` because it is passed as
  the highest-precedence argument, with no global mutation that other code (or tests)
  could observe. It also makes the data flow visible and unit-testable. The
  prompt-level requirement ("each handler that calls `resolveTargetProfile` must
  instead call `resolveActiveContext` with the flag value") is satisfied directly.
  Date: 2026-06-30

- Decision: `nagarectl init [NAME]` writes a *named context* into the EP-87 store
  (and marks it current) when `NAME` is supplied, and writes the legacy
  `./nagare.target.env` when it is not. `nagarectl context create NAME` is the
  lighter-weight sibling that only writes the context file (no preflight, no API
  enable, no Pulumi seed).
  Rationale: MasterPlan 17 requires `init` to produce a context, but the existing
  single-profile workflow (write `./nagare.target.env`, then `just infra-up`) must
  keep working byte-for-byte when no name is given (back-compat is a MasterPlan
  guarantee). Splitting "full onboarding" (`init`) from "just record a target"
  (`context create`) mirrors how operators actually work: onboarding a brand-new GCP
  project is rare and side-effecting; adding another context for an existing project
  is frequent and side-effect-free.
  Date: 2026-06-30

- Decision: reuse EP-87's store helpers in `Nagare.Target` and EP-87's
  `resolveActiveContext`/renderer rather than re-implement any store or resolution
  logic in the CLI.
  Rationale: EP-87 is the single source of truth for the context model, the store
  layout, the `current-context` pointer, and the resolution precedence (MasterPlan 17
  Integration Points 1 and 2). EP-88 is a pure consumer: it reads/writes the store
  and calls the resolver. Re-deriving any of that here would fork the contract and
  break the shared behavior EP-89 also depends on.
  Date: 2026-06-30

- Decision: deleting the current context clears the `current-context` pointer instead
  of leaving it dangling.
  Rationale: EP-87 deliberately fails closed for a selected context whose file is
  missing. A dangling pointer would make later commands fail until the operator
  manually edits the store. Clearing the pointer after deleting the current context
  preserves the fail-closed behavior for explicit missing selections while letting
  ordinary resolution fall through to the in-repo profile or built-in default.
  Date: 2026-07-01

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-88 is complete. `nagarectl context list|current|use|show|create|delete` manages the EP-87 store; `context create` derives omitted fields without reading ambient target environment variables; deleting the current context clears the pointer. `nagarectl --context NAME ...` is accepted as a global selector and is threaded into the CLI handlers and library entry points that resolve target-dependent behavior. The old build-context long option is now `--build-context` while retaining `-c`. `nagarectl init NAME` writes a named context and sets it current; unnamed `init` still writes `./nagare.target.env`.

Validation completed 2026-07-01:

- `cd cli/nagarectl && cabal build -v0 exe:nagarectl` passed.
- `cd cli/nagarectl && cabal test -v0` passed: 341 tests.
- Manual temporary-store transcript passed for `context create`, `context show`, `init NAME --skip-preflight --skip-enable --skip-seed`, `context list`, and `--context labs cdn disable ... --dry-run` printing `--project=tan-ng-labs`.

