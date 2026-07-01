---
id: 89
slug: shell-and-direnv-context-resolution-and-the-context-aware-guardrail
title: "Shell and direnv context resolution and the context-aware guardrail"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# Shell and direnv context resolution and the context-aware guardrail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today nagare resolves its deploy target — the GCP project, region, zone, registry, buckets,
apps domain, VM name, build platform, and cloud-vs-local mode — from process environment
variables that a single per-directory profile file populates: `nagare.target.env` for the cloud
target and `nagare.local.env` (with `NAGARE_MODE=local`) for local mode. Two shell surfaces read
those variables: `.envrc` (the direnv file at the repo root that exports the contract into every
shell you `cd` into) and `scripts/lib/target.sh` (the file that every operator script sources to
learn the target and to run the fail-closed "am I pointed at the right project?" guard). Because
the profile lives in the working directory, "a nagare target" is bound to a checkout: switching
targets means editing a file and re-running `direnv allow`, and running a second target means a
second clone.

The sibling plan `docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` (EP-87)
introduces **named target contexts** modeled on `kubectl` contexts. A **context** is a full target
bundle stored as one flat file of `export VAR=value` lines — the *same schema* as `nagare.target.env`
today — living in a user-level store at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`,
with a `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` file naming the default. EP-87
defines the resolution precedence, highest first: the `NAGARE_CONTEXT` environment variable, then the
`current-context` pointer, then an in-repo `nagare.target.env`/`nagare.local.env` (the historic
back-compat case), then the built-in `tan-nb-exp` default — with per-field environment variables still
overriding the chosen context's values (`env > context > default`).

After this plan, the **bash** side honors that same contract without a YAML parser. What an operator
gains, concretely:

- Running `nagarectl context use labs` (delivered by `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`,
  EP-88) writes the `current-context` pointer, and a shell in the repo picks up the `labs` target on
  the next directory entry or `direnv reload` — `echo $CLOUDSDK_CORE_PROJECT` shows the `labs`
  project, and unqualified `gcloud` acts on it. No file edit in the checkout.
- `NAGARE_CONTEXT=labs just smoke` runs the live smoke test against the `labs` target from any
  checkout, overriding whatever the current context is, with zero `cd` and zero file edit.
- The fail-closed project guardrail in `scripts/lib/target.sh` now asserts against the **active
  context's** project. A cloud context still refuses to run unless gcloud is pointed at that
  context's project; a local-mode context steps aside after checking the loopback invariants; and a
  checkout with nothing configured reproduces today's `tan-nb-exp` fail-closed behavior exactly.

You can see it working by sourcing `scripts/lib/target.sh` under different selectors and printing the
resolved values, and by watching the guardrail refuse or step aside. Concrete transcripts are in
Concrete Steps and Validation.

This plan owns **Integration Point 3** (the bash resolution contract) and **Integration Point 4**
(the context-aware fail-closed guardrail) from the MasterPlan
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`. It hard-depends on EP-87 for the
store layout, paths, and precedence. It does **not** add a `--context` flag — that is nagarectl's
surface, delivered by `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`
(EP-88). Bash selects a context purely through `NAGARE_CONTEXT`, the `current-context` pointer, and
the in-repo profile.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `scripts/lib/target.sh` gains a dependency-free bash context resolver `_nagare_resolve_context`
  that sources the right flat `.env` from the EP-87 store per the precedence
  `NAGARE_CONTEXT > current-context pointer > in-repo nagare.target.env/nagare.local.env > tan-nb-exp default`,
  preserving per-field `env > context > default` semantics, and exports the contract variables.
- [x] M1: `scripts/lib/target.sh` derives `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`/`TARGET_PLATFORM`
  and `NAGARE_SSH_USER` from the resolved active context; sourcing is idempotent.
- [x] M1: the resolver is the canonical producer of `NAGARE_CONTEXT` (re-exported as the resolved
  active-context name, `"default"` for in-repo/built-in) for `docs/plans/90-per-context-pulumi-state-and-config-projection.md`,
  and `NAGARE_REGISTRY_PREFIX` (mode-aware image-ref prefix) for `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`;
  a named-but-missing context is a hard error.
- [x] M2: `.envrc` resolves and sources the active context through the shared resolver FIRST (so
  `NAGARE_CONTEXT` is exported before the EP-90 Pulumi hand-off hook), preserving the `CLOUDSDK_*`
  exports, the local-mode overlay of `nagare.local.env`, `PULUMI_HOME`/`PULUMI_CONFIG_PASSPHRASE`, and
  `use flake`; `watch_file` makes direnv reload when `nagarectl context use` rewrites the pointer.
- [x] M3: `_require_target_project` asserts against the active context's project — fail-closed in a
  cloud context, steps aside (loopback invariants only) in a local context — replacing the
  `NAGARE_MODE=local` special-case with a context-`mode` branch.
- [x] Validation: cloud context/default resolution; local context step-aside; `NAGARE_CONTEXT=<name> just <recipe>`
  flows through; `scripts/live-smoke.sh`, `scripts/local-smoke.sh`, `scripts/live-test.sh`, `scripts/iap-ssh.sh`
  keep working unchanged.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (pre-implementation analysis): the flat context files use bare `export NAME=value`
  lines, so **sourcing a context file overwrites any same-named variable already in the
  environment.** That is the opposite of the `env > context` precedence the MasterPlan requires. To
  honor `env > context > default` in bash, the resolver must *snapshot* the canonical variables that
  are already set before sourcing, then re-export them afterward so the environment wins. This is
  documented in the Decision Log and implemented in `_nagare_resolve_context`.

- Discovery (pre-implementation analysis): `.envrc` (and, transitively, the scripts run inside a
  direnv shell) **exports the active context's contract variables**, e.g. `CLOUDSDK_CORE_PROJECT`.
  When you then run `NAGARE_CONTEXT=labs just smoke`, the script inherits the *current context's*
  exported `CLOUDSDK_CORE_PROJECT` as ambient state. A naive "env wins" would let that stale ambient
  value defeat the freshly selected `labs` context. The resolver therefore stamps a
  `NAGARE_RESOLVED_CONTEXT` marker recording which selection produced the exported contract; when the
  new selection differs from the marker, the inherited canonical variables are treated as a **stale
  projection** and cleared before the new context is sourced. See the Decision Log for the exact
  rule and the one documented edge case (selecting a different context *and* a manual per-field
  override in the same command).

- Discovery (superseded during implementation): the existing guard reads the effective project as
  `active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project ...)}"`. This means the guard
  *passes by construction whenever `CLOUDSDK_CORE_PROJECT` is exported* (because exporting it also
  makes gcloud use exactly that project). Today an in-repo profile's `export CLOUDSDK_CORE_PROJECT=…`
  line pins it and the guard passes; the guard's teeth are for the **unpinned** case (no profile,
  outside direnv, gcloud persisted config mismatched → refuse). To preserve that exact behavior the
  draft concluded that the resolver should not default-export `CLOUDSDK_CORE_PROJECT`; that was
  superseded by the MasterPlan correction and EP-87 parity. The implemented resolver exports the
  historic `tan-nb-exp` default so bash and Haskell resolve the same target bundle.

- Discovery (implementation): EP-87 treats a valid `current-context` pointer whose file is missing as a
  hard error. EP-89 follows that behavior instead of the draft's warning-and-fallthrough recovery path,
  so stale pointers cannot silently run scripts against `default`.

- Discovery (pre-implementation analysis): `NAGARE_CONTEXT` is reused as **both the input selector and
  the resolved-name output** (the sibling plans key Pulumi state off the resolved name). Because
  `.envrc` re-exports it, a script sourced inside a direnv shell inherits `NAGARE_CONTEXT=<resolved
  name>` — and for the in-repo/built-in case that name is `"default"`, which has no context file. A
  naive "explicit name with no file is a hard error" rule would then reject the echoed value on every
  re-source. The resolver reserves `"default"` as the name meaning "no explicit context" so it routes
  back through the pointer/in-repo chain instead of erroring, keeping re-sourcing idempotent while
  still hard-erroring on a genuinely missing named context.

(No runtime surprises yet — implementation not started.)


## Decision Log

Record every decision made while working on the plan.

- Decision: bash reads the **same flat `export VAR=value` store** EP-87 defines, with **no parser**.
  `scripts/lib/target.sh` and `.envrc` source the selected `.env` file directly, exactly as they
  already source `nagare.target.env`.
  Rationale: the MasterPlan's central design decision is that contexts are a backward-compatible
  generalization retaining the flat format precisely so bash needs no YAML parser. Sourcing is the
  cheapest, most faithful way to keep a single resolution behavior across the Haskell resolver
  (EP-87) and the shell.
  Date: 2026-06-30

- Decision: `NAGARE_CONTEXT` is the **bash selector**. There is no `--context` flag on the shell
  side; that belongs to nagarectl (EP-88). Bash selects a context via, highest precedence first,
  `NAGARE_CONTEXT`, then the `current-context` pointer, then an in-repo
  `nagare.target.env`/`nagare.local.env`, then the built-in `tan-nb-exp` default.
  Rationale: the shell surfaces (`.envrc`, `target.sh`, the justfile, the scripts) select targets
  through the environment, not through argument parsing. Reusing `NAGARE_CONTEXT` keeps
  `NAGARE_CONTEXT=labs just smoke` and `NAGARE_CONTEXT=labs scripts/live-smoke.sh` working with no
  per-recipe wiring. This is exactly Integration Point 2's precedence, re-implemented in bash so no
  consumer re-derives the order.
  Date: 2026-06-30

- Decision: honor `env > context > default` per field by **snapshotting the canonical variables
  before sourcing the context file and re-exporting them afterward**, and by clearing a **stale
  context projection** first. The resolver stamps `NAGARE_RESOLVED_CONTEXT=<selection-key>`; on a
  later resolution, if the incoming selection differs from that marker, the inherited canonical
  variables are a stale projection of the previously active context and are unset before the new
  context is sourced.
  Rationale: bare `export` lines overwrite the environment, which inverts the required precedence, so
  a snapshot is needed to make the environment win. The stale-projection rule is needed because
  `.envrc` exports the active context's contract, and without it `NAGARE_CONTEXT=labs just smoke`
  from a shell whose current context is `prod` would resolve to `prod`'s project. The one lossy edge
  case — selecting a *different* context *and* setting a genuine manual per-field override
  (e.g. `CLOUDSDK_CORE_PROJECT=zzz NAGARE_CONTEXT=labs …`) in the same command from a shell already
  projecting a third context — is accepted and documented: the manual override is indistinguishable
  from the stale projection and is discarded with it. A per-field override is honored whenever the
  selection is unchanged or no different context is projected. This matches the Haskell resolver's
  observable precedence for every non-pathological case.
  Date: 2026-06-30

- Decision: the **fail-closed guardrail asserts over the active context's project**, and its cloud
  branch keeps today's comparison expression verbatim — the only change is that `TARGET_PROJECT` now
  comes from the resolved active context. The resolver default-exports `CLOUDSDK_CORE_PROJECT` in the
  built-in default branch to match EP-87 and `.envrc` back-compat: unqualified `gcloud` sees the same
  `tan-nb-exp` target bundle as `nagarectl`.
  Rationale: Integration Point 4 mandates "the cloud branch must never become anything but
  fail-closed; the only change is that the compared project now comes from the active context." A
  context (like a profile) that pins `CLOUDSDK_CORE_PROJECT` makes gcloud use exactly that project, so
  the guard passing is the *safe* outcome — gcloud cannot act on any other project unless the operator
  changes the environment after sourcing.
  Date: 2026-06-30; updated 2026-07-01

- Decision: fold MasterPlan 16's `NAGARE_MODE=local` special-case into a **context-`mode` branch**.
  A local context is one whose `.env` sets `NAGARE_MODE=local`; after resolution the existing
  `if [ "${NAGARE_MODE:-}" = "local" ]` check reads the context's mode, so the guard steps aside for
  local contexts after asserting the loopback invariants (`NAGARE_BASE_DOMAIN` is an
  `sslip.io`/`nip.io`/`127-0-0-1` wildcard; `NAGARE_REGISTRY_HOST` is not a `*.pkg.dev` Artifact
  Registry host). No code path weakens the cloud fail-closed behavior.
  Rationale: MasterPlan 16 already routes local mode through `NAGARE_MODE`; folding it into the
  context keeps a single mechanism and preserves the loopback safety check.
  Date: 2026-06-30

- Decision: per-context **Pulumi state** is out of scope for this plan; it belongs to
  `docs/plans/90-per-context-pulumi-state-and-config-projection.md` (EP-90). `.envrc` resolves the
  active context **first** (so `NAGARE_CONTEXT` is exported), then reaches a clearly marked EP-90
  hand-off hook above the `PULUMI_HOME`/`PULUMI_CONFIG_PASSPHRASE` exports. EP-90 will place its
  per-context Pulumi env derivation (`PULUMI_BACKEND_URL`/`PULUMI_HOME` + `pulumi stack select`, keyed
  off `NAGARE_CONTEXT`) at that hook.
  Rationale: the MasterPlan assigns per-context Pulumi state to EP-90 (Integration Point 5). EP-89 owns
  context resolution and guarantees `NAGARE_CONTEXT` is resolved and exported before the hand-off; EP-90
  owns the Pulumi env derivation that reads it. Fixing the ordering now prevents EP-90 from reading an
  unresolved `NAGARE_CONTEXT`.
  Date: 2026-06-30

- Decision: EP-89 is the **canonical producer of `NAGARE_CONTEXT` as the resolved active-context
  NAME**. The resolver captures the incoming value as the *request*, resolves it through the precedence
  chain, then re-exports `NAGARE_CONTEXT` as the resolved name — a store context's `<name>`, or the
  reserved `"default"` for the in-repo/built-in chain (never empty). A named-but-missing context is a
  HARD ERROR (mirrors EP-87); the reserved `"default"` is exempt so the re-exported value can be safely
  re-sourced by a script running inside a direnv shell.
  Rationale: `docs/plans/90-per-context-pulumi-state-and-config-projection.md` keys the per-context
  Pulumi backend directory and stack name off `NAGARE_CONTEXT`, so it must always hold a stable,
  non-empty name. Reusing the same variable for input and resolved output (rather than adding a new
  name) keeps `NAGARE_CONTEXT=labs just smoke` and the exported result symmetric, and the reserved
  `"default"` handling makes re-sourcing idempotent instead of a hard error. `NAGARE_ACTIVE_CONTEXT`
  remains as a readable mirror; `NAGARE_ACTIVE_CONTEXT_FILE` carries the sourced path.
  Date: 2026-06-30

- Decision: EP-89 is the **canonical producer of `NAGARE_REGISTRY_PREFIX`**, a mode-aware image-ref
  prefix. Cloud (`mode != local`): `<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>`,
  defaulting to `us-west1-docker.pkg.dev/tan-nb-exp/nagare` (today's hardcode). Local
  (`mode == local`): the flat local-registry host, defaulting to `k3d-registry.localhost:5000`. It is
  recomputed on every resolution, never inherited.
  Rationale: `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`
  substitutes this prefix into the auth-plane and `nagared` Service image refs
  (`<prefix>/<svc>:<tag>`). Computing it once in the bash resolver (the single place that knows the
  resolved mode + host + project) means EP-91's rendering reads one variable instead of re-deriving the
  cloud-vs-local shape. Recomputing (not inheriting) prevents a cloud→local (or context→context) switch
  from leaking a stale registry into a rendered manifest.
  Date: 2026-06-30

- Decision: shell tests **pin `XDG_CONFIG_HOME` to a temp directory and clear `NAGARE_CONTEXT`**
  (identical isolation to EP-87) so a real `~/.config/nagare` store and any ambient selection cannot
  perturb them.
  Rationale: the store path is `${XDG_CONFIG_HOME:-$HOME/.config}/nagare`; without pinning it a
  developer's real contexts would change test outcomes, and an inherited `NAGARE_CONTEXT` would shadow
  the pointer/in-repo/default branches under test. This matches EP-87's test isolation so both layers'
  suites behave identically.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-89 is complete. `scripts/lib/target.sh` now resolves active contexts from the EP-87 store, exports
the canonical target contract plus `NAGARE_CONTEXT`, `NAGARE_ACTIVE_CONTEXT_FILE`, and
`NAGARE_REGISTRY_PREFIX`, and keeps the local-mode guardrail branch as a context-mode check. `.envrc`
uses the shared resolver, watches the current pointer and active profile files, and leaves the EP-90
Pulumi hand-off in place.

Validation completed 2026-07-01:

- `bash -n scripts/lib/target.sh .envrc` and syntax checks for the scripts that source `target.sh`
  passed.
- Temporary-store transcripts passed for explicit `NAGARE_CONTEXT`, current-context pointer,
  per-field env override, stale projection clearing, local context guard step-aside, missing explicit
  context hard error, and stale current-context hard error.
- Stubbed `.envrc` sourcing resolved a pointer-selected context and preserved `PULUMI_HOME`.
- `NAGARE_CONTEXT=labs just --dry-run smoke` still expands to `scripts/live-smoke.sh`, proving the
  justfile handoff remains unchanged.


## Context and Orientation

This section assumes no prior knowledge of the repository. It names every file and term you need.

**direnv and `.envrc`.** `direnv` is a shell extension that, whenever you `cd` into a directory,
sources a file named `.envrc` found there (once you have approved it with `direnv allow`) and applies
the environment changes it makes to your interactive shell. Leaving the directory reverts them.
`.envrc` at the repo root
(`/Users/shinzui/Keikaku/bokuno/nagare/.envrc`) is written in bash and uses a few direnv library
functions: `source_env <file>` (source a file and record it so direnv reloads when it changes),
`watch_file <path>` (reload the shell when that path changes, even if it does not exist yet), and
`use flake` (load the project's Nix flake dev shell onto `PATH`). Today `.envrc`:

```bash
[ -f "$PWD/nagare.target.env" ] && source_env "$PWD/nagare.target.env"
export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"

if [ "${NAGARE_MODE:-}" = "local" ] && [ -f "$PWD/nagare.local.env" ]; then
  source_env "$PWD/nagare.local.env"
elif [ -f "$PWD/nagare.local.env" ] && grep -q '^export NAGARE_MODE=local' "$PWD/nagare.local.env"; then
  source_env "$PWD/nagare.local.env"
fi

export PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"
export PULUMI_CONFIG_PASSPHRASE=""
use flake
```

**`scripts/lib/target.sh`.** This is the single file every operator script *sources* (never executes)
to learn the target and to run the fail-closed project guard. Its current shape:

- It resolves `NAGARE_REPO_ROOT` from its own path (`${BASH_SOURCE[0]}`), independent of the caller's
  working directory.
- If `${NAGARE_REPO_ROOT}/nagare.target.env` exists, it sources it (`. "$file"`), which sets and
  exports whatever variables that profile declares.
- It derives shell variables `TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"`,
  `TARGET_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"`,
  `TARGET_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"`,
  `TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"`, and exports
  `NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"`.
- It defines `_require_target_project`, the guard. In local mode (`NAGARE_MODE=local`) it asserts the
  loopback invariants and returns 0 (steps aside). Otherwise it refuses to proceed unless gcloud's
  effective project — `${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}`
  — equals `TARGET_PROJECT`.

The scripts that source it and call the guard are `scripts/iap-ssh.sh` (line 44–45),
`scripts/live-test.sh` (line 22–23), `scripts/live-smoke.sh` (line 20–21), and `scripts/local-smoke.sh`
(line 19 + line 32). All of them read exported variables such as `NAGARE_REPO_ROOT`, `TARGET_ZONE`,
`NAGARE_INSTANCE_NAME`, `NAGARE_BASE_DOMAIN`, and `NAGARE_SSH_USER` — they never re-derive the target,
they consume what `target.sh` produced.

**The justfile.** `/Users/shinzui/Keikaku/bokuno/nagare/justfile` has recipes that either call the
scripts (`smoke` → `scripts/live-smoke.sh`, `local-smoke` → `scripts/local-smoke.sh`, `live-test` →
`scripts/live-test.sh`) or read the contract variables directly with defaults, e.g.
`${NAGARE_BASE_DOMAIN:?…}` and `${NAGARE_REGISTRY_HOST:-k3d-registry.localhost:5000}` in
`local-bootstrap`. Because recipes read the *environment*, once `.envrc`/`target.sh` export the active
context, the recipes pick it up with no change to how they read it. `just` runs recipes in a shell
that inherits the direnv-exported environment, so `NAGARE_CONTEXT=labs just smoke` passes
`NAGARE_CONTEXT=labs` into that shell, and the script it invokes re-resolves through `target.sh`.

**The EP-87 store (assumed delivered).** From
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md`:

- Contexts live at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`. Each file is a flat
  list of `export VAR=value` lines using the **same schema** as `nagare.target.env`
  (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`, `NAGARE_REGISTRY_HOST`,
  `NAGARE_ARTIFACT_REGISTRY_ID`, `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
  `NAGARE_INSTANCE_NAME`, `NAGARE_TARGET_PLATFORM`, `NAGARE_SSH_USER`) plus `NAGARE_MODE` and, for
  local contexts, `NAGARE_LOCAL_OBJECT_STORE`.
- `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` is a one-line file naming the default
  context.
- Precedence: `NAGARE_CONTEXT` > `current-context` pointer > in-repo `nagare.target.env`/`nagare.local.env`
  > `tan-nb-exp` default, with per-field environment overrides on top (`env > context > default`).

This plan implements the identical precedence in bash. If EP-87 is not yet merged when you implement
this plan, you can still build and test M1/M3 by creating the store directory and files by hand — the
Concrete Steps show exactly how.

**Terms defined.** *Context*: a named target bundle stored as a flat `.env` file. *Active context*:
the one selected by the precedence rules for the current command. *Contract variables*: the
`CLOUDSDK_*` and `NAGARE_*` variables a context provides. *Stale projection*: contract variables
exported by a previously active context that a fresh selection must not mistake for user overrides.
*Fail-closed*: the guard refuses to run rather than risk acting on the wrong project.


## Plan of Work

The work is three independent, individually verifiable milestones. M1 builds the bash resolver inside
`scripts/lib/target.sh` and rewires the top of that file to use it. M2 rewrites `.envrc` to resolve
the active context through the same resolver. M3 reworks the guardrail. Each milestone is described
below with the exact file, location, and change.

### Milestone M1 — a dependency-free bash context resolver in `scripts/lib/target.sh`

Scope: add a function `_nagare_resolve_context` to `scripts/lib/target.sh` that implements Integration
Point 2's precedence in bash, sourcing the correct flat `.env` file and exporting the contract with
`env > context > default` semantics. Rewire the top of the file (currently lines 21–40) to call it and
derive `TARGET_*`. At the end of M1, sourcing `scripts/lib/target.sh` with `NAGARE_CONTEXT=<name>` set,
or with a `current-context` pointer present, or with an in-repo profile, or with nothing, resolves the
matching target and exports the contract; sourcing twice is a no-op.

Insert, near the top of `scripts/lib/target.sh` (after `NAGARE_REPO_ROOT` is computed, replacing the
current lines 21–40 that source `nagare.target.env` and derive `TARGET_*`), the canonical variable
list and the resolver:

```bash
# The canonical contract variables a context provides. Order does not matter.
# NAGARE_CONTEXT is handled separately: it is BOTH the input selector AND, after
# resolution, the exported resolved active-context NAME — so it is not listed here.
_NAGARE_CONTEXT_VARS=(
  CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_COMPUTE_ZONE
  NAGARE_REGISTRY_HOST NAGARE_ARTIFACT_REGISTRY_ID
  NAGARE_IMAGE_BUCKET NAGARE_BACKUP_BUCKET NAGARE_BASE_DOMAIN
  NAGARE_INSTANCE_NAME NAGARE_TARGET_PLATFORM NAGARE_SSH_USER
  NAGARE_MODE NAGARE_LOCAL_OBJECT_STORE
)

# Resolve the ACTIVE CONTEXT and export its contract, honoring the EP-87
# precedence (NAGARE_CONTEXT > current-context pointer > in-repo profile >
# tan-nb-exp default) with per-field env > context > default.
#
# Canonical exports this function PRODUCES (consumed by the sibling plans):
#   NAGARE_CONTEXT          the RESOLVED active-context NAME (never empty:
#                           <name> for a store context, else the reserved
#                           "default" for the in-repo/built-in chain).
#                           docs/plans/90-per-context-pulumi-state-and-config-projection.md
#                           keys the per-context Pulumi backend dir + stack name off it.
#   NAGARE_REGISTRY_PREFIX  the mode-aware image-ref prefix (step 9). Cloud:
#                           <host>/<project>/<registry-id>. Local: the flat
#                           local-registry host.
#                           docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md
#                           substitutes it into the auth-plane/nagared Service image refs.
#   NAGARE_ACTIVE_CONTEXT_FILE  the sourced context/profile file path ("" for default).
#   NAGARE_RESOLVED_CONTEXT internal marker used to detect a stale projection.
_nagare_resolve_context() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nagare"
  local ctxdir="${cfg}/contexts" ptrfile="${cfg}/current-context"
  local selkey="" file="" name="" overlay="" ptr=""

  # Snapshot the INCOMING request at entry. On a re-source (e.g. a script run in
  # a shell where .envrc already exported the resolved NAGARE_CONTEXT name), this
  # is the echoed resolved name, which must not be mistaken for a fresh request.
  local requested="${NAGARE_CONTEXT:-}"

  # 1) Explicit context selection by name. A named-but-missing context is a HARD
  #    ERROR (mirrors EP-87). The reserved name "default" is NOT a hard error: it
  #    means "no explicit context" and falls through to the chain below, so that
  #    the resolved NAGARE_CONTEXT="default" we export can be safely re-sourced.
  if [ -n "${requested}" ] && [ -f "${ctxdir}/${requested}.env" ]; then
    name="${requested}"; file="${ctxdir}/${requested}.env"; selkey="ctx:${requested}"
  elif [ -n "${requested}" ] && [ "${requested}" != "default" ]; then
    echo "nagare: no such context '${requested}' (looked in ${ctxdir})" >&2
    return 1
  fi

  # 2) No explicit store context -> the current-context pointer.
  if [ -z "${selkey}" ] && [ -f "${ptrfile}" ] && ptr="$(tr -d '[:space:]' < "${ptrfile}")" && [ -n "${ptr}" ]; then
    if [ -f "${ctxdir}/${ptr}.env" ]; then
      name="${ptr}"; file="${ctxdir}/${ptr}.env"; selkey="ctx:${ptr}"
    else
      echo "nagare: current-context '${ptr}' has no file ${ctxdir}/${ptr}.env" >&2
      return 1
    fi
  fi

  # 3) Still nothing -> in-repo back-compat (MasterPlan 12/16) or built-in default.
  #    The resolved NAME for this whole chain is the reserved "default".
  if [ -z "${selkey}" ]; then
    local tgt="${NAGARE_REPO_ROOT}/nagare.target.env"
    local loc="${NAGARE_REPO_ROOT}/nagare.local.env"
    if [ -f "${tgt}" ] || [ -f "${loc}" ]; then
      selkey=":inrepo:"
      [ -f "${tgt}" ] && file="${tgt}"
      # Local overlay when local mode is selected in the env or declared in the file.
      if [ "${NAGARE_MODE:-}" = "local" ] || { [ -f "${loc}" ] && grep -q '^export NAGARE_MODE=local' "${loc}"; }; then
        overlay="${loc}"
      fi
    else
      selkey=":default:"
    fi
    name="default"
  fi

  # 4) If the environment already carries a DIFFERENT context's projection
  #    (exported by .envrc / an outer shell), clear it so the new context wins.
  if [ -n "${NAGARE_RESOLVED_CONTEXT:-}" ] && [ "${NAGARE_RESOLVED_CONTEXT}" != "${selkey}" ]; then
    local v; for v in "${_NAGARE_CONTEXT_VARS[@]}"; do unset "${v}"; done
  fi

  # 5) Snapshot remaining canonical vars (genuine env overrides, or this
  #    context's own values on a re-source) so the environment wins over the file.
  local _snap=() v
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    [ -n "${!v+x}" ] && _snap+=("${v}=${!v}")
  done

  # 6) Source the selected context (bare `export` lines), then any local overlay.
  [ -n "${file}" ] && [ -f "${file}" ] && . "${file}"
  [ -n "${overlay}" ] && [ -f "${overlay}" ] && . "${overlay}"

  # 7) Re-export the snapshot: env > context.
  local kv
  for kv in "${_snap[@]+"${_snap[@]}"}"; do export "${kv?}"; done

  # 8) Apply the historic tan-nb-exp defaults for still-unset fields, and export.
  #    This matches EP-87/Haskell resolution and the old .envrc behavior: an
  #    unqualified shell carries the original default target bundle.
  export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
  export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
  export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
  export NAGARE_TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"
  export NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"

  # 9) Derive the mode-aware registry PREFIX (canonical producer for EP-91).
  #    NAGARE_REGISTRY_PREFIX is always recomputed here (never inherited), so a
  #    context switch cannot leak a stale prefix.
  if [ "${NAGARE_MODE:-}" = "local" ]; then
    export NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_HOST:-k3d-registry.localhost:5000}"
  else
    export NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}/${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}/${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
  fi

  # 10) Record the selection and expose the RESOLVED context to consumers.
  #     NAGARE_CONTEXT is re-exported as the resolved NAME (canonical for EP-90).
  export NAGARE_RESOLVED_CONTEXT="${selkey}"
  export NAGARE_CONTEXT="${name}"
  NAGARE_ACTIVE_CONTEXT="${name}"
  NAGARE_ACTIVE_CONTEXT_FILE="${file}"
  export NAGARE_ACTIVE_CONTEXT NAGARE_ACTIVE_CONTEXT_FILE
}
```

Then, immediately after the function, replace the old `TARGET_*` derivation with a call to the
resolver followed by the same derivation (now reading the resolved values):

```bash
if ! _nagare_resolve_context; then
  # A bad NAGARE_CONTEXT is a hard error. Return when sourced, exit if executed.
  return 1 2>/dev/null || exit 1
fi

TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
TARGET_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
TARGET_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"
# NAGARE_SSH_USER is already exported by the resolver.
```

Notes on why this is correct and safe:

- Sourcing a context file with bare `export` lines sets the contract; the snapshot (step 5) and
  re-export (step 7) make any pre-existing environment value win, giving `env > context`.
- The stale-projection clear (step 4) is what makes `NAGARE_CONTEXT=labs just smoke` resolve to `labs`
  even though the surrounding direnv shell exported the current context's `CLOUDSDK_CORE_PROJECT`.
- `NAGARE_CONTEXT` is captured once at entry as `requested` and re-exported at the end as the resolved
  name (step 10). The re-export is safe to re-source because a store context's name has a matching file
  (loaded again identically) and the in-repo/built-in name is the reserved `"default"`, which step 1
  routes back through the pointer/in-repo chain rather than treating as a missing context. This is why
  a script run inside a direnv shell — which inherits `NAGARE_CONTEXT=<resolved name>` — re-resolves to
  the same target rather than hard-erroring.
- `NAGARE_REGISTRY_PREFIX` (step 9) is always recomputed from the resolved `NAGARE_MODE`/host/project,
  never inherited, so switching contexts (or from cloud to local) cannot leak a stale prefix into the
  Service image refs `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`
  renders.
- `${_snap[@]+"${_snap[@]}"}` is the array expansion that is safe under `set -u` when the array is
  empty (the scripts run with `set -euo pipefail`); the flake dev shell provides bash 5, but this
  form is also safe on macOS's system bash 3.2.
- `_require_target_project` is unchanged in this milestone; M3 reworks it. But because `TARGET_PROJECT`
  now comes from the resolved context, the guard already asserts over the active context's project as
  soon as M1 lands.

### Milestone M2 — `.envrc` resolves the active context through the shared resolver

Scope: rewrite `.envrc` so a shell entered in the repo reflects the active context
(`NAGARE_CONTEXT` or the `current-context` pointer, else the in-repo profile, else default), using the
*same* resolver as the scripts, and reload when `nagarectl context use` changes the pointer. Preserve
the `CLOUDSDK_*` exports, the local-mode overlay of `nagare.local.env`, `PULUMI_HOME`/
`PULUMI_CONFIG_PASSPHRASE`, and `use flake`.

Replace the top of `.envrc` (the `source_env nagare.target.env` line, the three `CLOUDSDK_*` default
exports, and the `nagare.local.env` local-mode block) with a single call into the shared resolver, and
add `watch_file` directives so direnv reloads on selection changes:

```bash
# Resolve and export the ACTIVE CONTEXT's contract (EP-89, Integration Point 3).
# scripts/lib/target.sh is the single resolver: it honors NAGARE_CONTEXT >
# current-context pointer > in-repo nagare.target.env/nagare.local.env >
# tan-nb-exp default, applies env > context > default per field, and exports
# CLOUDSDK_* + NAGARE_*. Sourcing it does NOT touch gcloud (the guard is only a
# function definition), so it is safe here.
source "$PWD/scripts/lib/target.sh"

# Reload this shell when the selection changes, so `nagarectl context use <name>`
# (which rewrites current-context) is reflected here, and editing the in-repo
# profile or the active context file re-resolves. watch_file is fine on paths
# that do not exist yet (direnv reloads when they appear).
_nagare_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/nagare"
watch_file "${_nagare_cfg}/current-context"
[ -n "${NAGARE_ACTIVE_CONTEXT_FILE:-}" ] && watch_file "${NAGARE_ACTIVE_CONTEXT_FILE}"
[ -f "$PWD/nagare.target.env" ] && watch_file "$PWD/nagare.target.env"
[ -f "$PWD/nagare.local.env" ] && watch_file "$PWD/nagare.local.env"
```

Ordering matters. The resolver runs FIRST (the `source` line above), so `NAGARE_CONTEXT` holds the
resolved active-context name before any later `.envrc` line reads it. In particular, the per-context
Pulumi wiring that `docs/plans/90-per-context-pulumi-state-and-config-projection.md` (EP-90) adds —
deriving `PULUMI_BACKEND_URL`/`PULUMI_HOME` and running `pulumi stack select` keyed off
`NAGARE_CONTEXT` — must be placed at the marked hand-off hook below, after this point. EP-89 owns
context resolution and guarantees `NAGARE_CONTEXT` is resolved and exported here; EP-90 owns the Pulumi
env derivation that reads it. Keep the rest of `.envrc` as-is, and add the hand-off hook above the
Pulumi exports:

```bash
# --- EP-90 hand-off: per-context Pulumi env is derived HERE ---
# NAGARE_CONTEXT is already resolved+exported above (EP-89). EP-90
# (docs/plans/90-per-context-pulumi-state-and-config-projection.md) will set
# PULUMI_BACKEND_URL/PULUMI_HOME per-context and `pulumi stack select` from
# NAGARE_CONTEXT here. Until EP-90 lands, the single in-repo file backend stands.
export PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"
export PULUMI_CONFIG_PASSPHRASE=""

use flake
```

Why this is faithful:

- `source "$PWD/scripts/lib/target.sh"` runs `_nagare_resolve_context`, which sources the selected
  context/profile and exports the contract — subsuming the old `source_env nagare.target.env` line and
  the old local-mode `nagare.local.env` block (the resolver overlays `nagare.local.env` when local
  mode is selected, exactly as before). The three explicit `CLOUDSDK_*` default exports are subsumed
  by the resolver's step 8 (region/zone) and by `TARGET_*` derivation (project); `CLOUDSDK_CORE_PROJECT`
  is intentionally left unpinned in the bare-default case, a deliberate change discussed in the
  Decision Log.
- The switch from `source_env` to `source` plus explicit `watch_file` is necessary because the
  resolved file may live in the user-level store (outside the repo) and the *selection* itself
  (`current-context`) is a file direnv must watch to reload after `nagarectl context use`.

### Milestone M3 — context-aware fail-closed guardrail

Scope: rework `_require_target_project` in `scripts/lib/target.sh` so the local/cloud branch is driven
by the **active context's mode** and the cloud branch compares against the **active context's
project**. The cloud branch keeps its exact comparison; only the source of `TARGET_PROJECT` changes
(already true after M1). Rewrite the comments to describe the context model. The function body:

```bash
# Fail-closed preflight over the ACTIVE CONTEXT (Integration Point 4). Call once,
# after sourcing this file, in any script that talks to GCP.
_require_target_project() {
  # Local context (mode=local): there is no GCP project to protect, so the GCP
  # guardrail steps aside — but assert the target is genuinely loopback so a
  # misconfigured local context cannot silently point at real cloud resources.
  # NAGARE_MODE is set by the active context's .env (or an in-repo nagare.local.env).
  if [ "${NAGARE_MODE:-}" = "local" ]; then
    case "${NAGARE_BASE_DOMAIN:-}" in
      *sslip.io|*nip.io|*127.0.0.1*|*127-0-0-1*) : ;;
      *)
        echo "refusing local run: active context is mode=local but NAGARE_BASE_DOMAIN='${NAGARE_BASE_DOMAIN:-<unset>}' is not a loopback wildcard." >&2
        return 1 ;;
    esac
    case "${NAGARE_REGISTRY_HOST:-}" in
      *.pkg.dev|*.pkg.dev:*)
        echo "refusing local run: active context is mode=local but NAGARE_REGISTRY_HOST='${NAGARE_REGISTRY_HOST}' is an Artifact Registry host." >&2
        return 1 ;;
    esac
    return 0
  fi

  # Cloud context (fail-closed): abort unless gcloud's effective project equals
  # the active context's project. TARGET_PROJECT is derived from the resolved
  # context, so this compares against the active context (Integration Point 4).
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
    echo "refusing to run: gcloud active project is '${active:-<unset>}', expected '${TARGET_PROJECT}' (active context: ${NAGARE_CONTEXT:-default})." >&2
    echo "fix: select the right context (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>')," >&2
    echo "     run 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=${TARGET_PROJECT}'." >&2
    return 1
  fi
}
```

The cloud comparison line is byte-for-byte the same logic as today; the only substantive change is
that `TARGET_PROJECT` and `NAGARE_MODE` now come from the resolved active context, and the messages
name the active context. This satisfies Integration Point 4: the cloud branch is still fail-closed,
and the compared project comes from the active context.

### How the milestones compose

After M1 the scripts resolve contexts and the guard already asserts over the active context. After M2
interactive shells and the justfile reflect the active context. M3 makes the guard's messages and mode
branch context-native. The scripts (`scripts/live-smoke.sh`, `scripts/local-smoke.sh`,
`scripts/live-test.sh`, `scripts/iap-ssh.sh`) and the justfile need **no edits** — they consume the
exported contract exactly as before.


## Concrete Steps

Run everything from the repo root, `/Users/shinzui/Keikaku/bokuno/nagare`, inside the flake dev shell.
These steps show how to build a throwaway store and exercise every precedence branch. They are
non-destructive: like EP-87's suite, they **pin `XDG_CONFIG_HOME` to a temp directory and clear
`NAGARE_CONTEXT`** so your real `~/.config/nagare` store and any ambient selection cannot perturb them.
Whenever a step exercises the pointer, in-repo, or default branch (not an explicit `NAGARE_CONTEXT`),
it clears `NAGARE_CONTEXT` first (shown as `env -u NAGARE_CONTEXT` or `unset NAGARE_CONTEXT`).

### Step 0 — a scratch store you control

```bash
export XDG_CONFIG_HOME="$(mktemp -d)/config"
unset NAGARE_CONTEXT NAGARE_RESOLVED_CONTEXT   # clear any ambient selection
mkdir -p "${XDG_CONFIG_HOME}/nagare/contexts"

cat > "${XDG_CONFIG_HOME}/nagare/contexts/labs.env" <<'EOF'
export CLOUDSDK_CORE_PROJECT=labs-topagent
export CLOUDSDK_COMPUTE_REGION=us-central1
export CLOUDSDK_COMPUTE_ZONE=us-central1-a
export NAGARE_REGISTRY_HOST=us-central1-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_BASE_DOMAIN=labs.topagentnetwork.net
export NAGARE_INSTANCE_NAME=nagare-labs
export NAGARE_MODE=cloud
EOF

cat > "${XDG_CONFIG_HOME}/nagare/contexts/laptop.env" <<'EOF'
export NAGARE_MODE=local
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_TARGET_PLATFORM=linux/arm64
export NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
EOF
```

### Step 1 — select a cloud context via `NAGARE_CONTEXT`

```bash
NAGARE_CONTEXT=labs bash -c 'source scripts/lib/target.sh; echo "$TARGET_PROJECT $TARGET_REGION $NAGARE_BASE_DOMAIN $NAGARE_ACTIVE_CONTEXT"'
```

Expected:

```text
labs-topagent us-central1 labs.topagentnetwork.net labs
```

### Step 2 — select via the `current-context` pointer

```bash
printf 'labs\n' > "${XDG_CONFIG_HOME}/nagare/current-context"
env -u NAGARE_CONTEXT bash -c 'source scripts/lib/target.sh; echo "$TARGET_PROJECT (via pointer=$NAGARE_CONTEXT)"'
```

Expected (the resolver re-exports `NAGARE_CONTEXT` as the resolved name):

```text
labs-topagent (via pointer=labs)
```

### Step 3 — `NAGARE_CONTEXT` overrides the pointer

```bash
NAGARE_CONTEXT=laptop bash -c 'source scripts/lib/target.sh; echo "$NAGARE_ACTIVE_CONTEXT $NAGARE_MODE $NAGARE_BASE_DOMAIN"'
```

Expected:

```text
laptop local 127-0-0-1.sslip.io
```

### Step 4 — a stale projection does not defeat a fresh selection

Simulate a direnv shell already projecting `labs`, then run a command selecting `laptop`:

```bash
bash -c '
  export NAGARE_RESOLVED_CONTEXT=ctx:labs
  export CLOUDSDK_CORE_PROJECT=labs-topagent   # ambient projection of labs
  NAGARE_CONTEXT=laptop
  export NAGARE_CONTEXT
  source scripts/lib/target.sh
  echo "$NAGARE_ACTIVE_CONTEXT $NAGARE_MODE ${CLOUDSDK_CORE_PROJECT:-<unset>}"
'
```

Expected (the stale `labs-topagent` was cleared; `laptop` is local and sets no project):

```text
laptop local <unset>
```

### Step 5 — a genuine per-field env override wins (`env > context`)

```bash
CLOUDSDK_CORE_PROJECT=override-proj NAGARE_CONTEXT=labs \
  bash -c 'source scripts/lib/target.sh; echo "$TARGET_PROJECT"'
```

Expected (no stale marker present, so the explicit override is honored over `labs`'s project):

```text
override-proj
```

### Step 5b — the canonical derived exports (`NAGARE_CONTEXT` name + `NAGARE_REGISTRY_PREFIX`)

These two exports are what the de-hardcoding siblings consume:
`docs/plans/90-per-context-pulumi-state-and-config-projection.md` reads the resolved `NAGARE_CONTEXT`
name; `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md` reads
`NAGARE_REGISTRY_PREFIX`. Cloud context:

```bash
NAGARE_CONTEXT=labs bash -c 'source scripts/lib/target.sh; echo "$NAGARE_CONTEXT | $NAGARE_REGISTRY_PREFIX"'
```

Expected (cloud prefix is `<host>/<project>/<registry-id>`):

```text
labs | us-central1-docker.pkg.dev/labs-topagent/nagare
```

Local context (flat local-registry host, no project/repo nesting):

```bash
NAGARE_CONTEXT=laptop bash -c 'source scripts/lib/target.sh; echo "$NAGARE_CONTEXT | $NAGARE_REGISTRY_PREFIX"'
```

Expected:

```text
laptop | k3d-registry.localhost:5000
```

In-repo/default (resolved name is the reserved `default`):

```bash
env -u NAGARE_CONTEXT XDG_CONFIG_HOME="$(mktemp -d)" \
  bash -c 'cd /Users/shinzui/Keikaku/bokuno/nagare; unset CLOUDSDK_CORE_PROJECT NAGARE_REGISTRY_HOST; source scripts/lib/target.sh; echo "$NAGARE_CONTEXT | $NAGARE_REGISTRY_PREFIX"'
```

Expected (no in-repo `nagare.target.env`; the built-in defaults reproduce today's cloud hardcode):

```text
default | us-west1-docker.pkg.dev/tan-nb-exp/nagare
```

### Step 6 — nothing configured reproduces the `tan-nb-exp` default

```bash
env -u NAGARE_CONTEXT XDG_CONFIG_HOME="$(mktemp -d)" \
  bash -c 'cd /Users/shinzui/Keikaku/bokuno/nagare; unset CLOUDSDK_CORE_PROJECT; source scripts/lib/target.sh; echo "$TARGET_PROJECT $TARGET_REGION $TARGET_ZONE"'
```

Expected (no store, and if there is no in-repo `nagare.target.env`, the historic defaults apply):

```text
tan-nb-exp us-west1 us-west1-a
```

### Step 7 — the guardrail refuses when gcloud is mismatched (cloud, unpinned)

```bash
env -u NAGARE_CONTEXT XDG_CONFIG_HOME="$(mktemp -d)" \
  bash -c 'cd /Users/shinzui/Keikaku/bokuno/nagare; unset CLOUDSDK_CORE_PROJECT; source scripts/lib/target.sh; _require_target_project; echo "rc=$?"'
```

Expected when `gcloud config get-value project` is not `tan-nb-exp` (and no in-repo profile pins it):

```text
refusing to run: gcloud active project is '<something-else>', expected 'tan-nb-exp' (active context: default).
fix: select the right context (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>'),
     run 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=tan-nb-exp'.
rc=1
```

### Step 8 — the guardrail steps aside for a local context

```bash
NAGARE_CONTEXT=laptop bash -c 'source scripts/lib/target.sh; _require_target_project; echo "rc=$? (local step-aside)"'
```

Expected:

```text
rc=0 (local step-aside)
```

### Step 9 — a misconfigured local context is refused (loopback invariant)

```bash
cat > "${XDG_CONFIG_HOME}/nagare/contexts/bad-local.env" <<'EOF'
export NAGARE_MODE=local
export NAGARE_BASE_DOMAIN=apps.example.com
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev
EOF
NAGARE_CONTEXT=bad-local bash -c 'source scripts/lib/target.sh; _require_target_project; echo "rc=$?"'
```

Expected:

```text
refusing local run: active context is mode=local but NAGARE_BASE_DOMAIN='apps.example.com' is not a loopback wildcard.
rc=1
```

### Step 10 — the justfile flows the context through

With `labs` as the current context (Step 2), a live smoke run targets `labs`; overriding on the
command line targets `laptop`:

```bash
NAGARE_CONTEXT=labs just --dry-run smoke     # shows scripts/live-smoke.sh will run
# and inside that script, TARGET_PROJECT resolves to labs-topagent
```

Because `just smoke` invokes `scripts/live-smoke.sh`, which sources `scripts/lib/target.sh`, the
`NAGARE_CONTEXT` in the environment flows straight through with no per-recipe change. (A full `just
smoke` needs a live VM + GCP credentials and is not part of this validation; the dry run plus Step 1
prove the wiring.)

### Step 11 — direnv reflects `nagarectl context use`

In an interactive shell in the repo (with `.envrc` from M2 approved):

```bash
nagarectl context use laptop     # rewrites ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context
# direnv notices the watched current-context file changed and reloads:
echo "$NAGARE_ACTIVE_CONTEXT $NAGARE_MODE"
```

Expected:

```text
laptop local
```

(`nagarectl context use` is delivered by
`docs/plans/88-nagarectl-context-command-group-and-context-selection.md`; on the bash side, the
`watch_file` added in M2 is what makes the reload happen.)


## Validation and Acceptance

Acceptance is behavioral. Each item below is a specific input and the output to observe; all are
covered by the Concrete Steps.

- **Cloud context selection.** `NAGARE_CONTEXT=labs bash -c 'source scripts/lib/target.sh; echo
  $TARGET_PROJECT'` prints `labs-topagent` (Step 1). The pointer path prints the same when
  `current-context` names `labs` and `NAGARE_CONTEXT` is unset (Step 2).
- **Precedence.** `NAGARE_CONTEXT` overrides the pointer (Step 3). A genuine per-field override wins
  over the context (Step 5). A stale projection from another context is cleared, so the fresh
  selection is honored (Step 4).
- **Default unchanged.** With no store and no in-repo profile, `TARGET_PROJECT/REGION/ZONE` are
  `tan-nb-exp/us-west1/us-west1-a` (Step 6), and `_require_target_project` fails closed when gcloud's
  configured project differs (Step 7). This is the "nothing set reproduces today's behavior"
  guarantee.
- **Cloud fail-closed over the active context.** Point at a cloud context whose project is unpinned in
  the environment and whose gcloud config differs → refusal naming the active context (Step 7 pattern,
  generalized: the compared value is `TARGET_PROJECT`, which is the active context's project).
- **Local step-aside.** A `mode=local` context returns rc=0 from the guard (Step 8); a `mode=local`
  context with a non-loopback domain or an Artifact Registry host is refused (Step 9).
- **Justfile / scripts unchanged.** `NAGARE_CONTEXT=labs just --dry-run smoke` (Step 10) shows the
  recipe unchanged; the scripts source `target.sh` and inherit the resolved contract.
- **direnv reflects the pointer.** After `nagarectl context use laptop`, the shell's
  `NAGARE_ACTIVE_CONTEXT` is `laptop` (Step 11), via the `watch_file` reload.

Regression check for the existing scripts. Confirm each still sources cleanly and the guard behaves:

```bash
bash -n scripts/lib/target.sh && echo "target.sh parses"
for s in scripts/live-smoke.sh scripts/local-smoke.sh scripts/live-test.sh scripts/iap-ssh.sh; do
  bash -n "$s" && echo "$s parses"
done
```

`scripts/local-smoke.sh` sets `export NAGARE_MODE=local` before sourcing `target.sh`; with no store
selection it resolves the in-repo `nagare.local.env` overlay and the guard steps aside — its own
fallback block (which sources `nagare.local.env`/`.example` only when `NAGARE_BASE_DOMAIN` is unset)
remains correct and idempotent because the resolver already populates those variables. Run it end to
end (needs Docker) with `just local-smoke` and confirm `local smoke: OK`.


## Idempotence and Recovery

Sourcing `scripts/lib/target.sh` is idempotent. On a second source in the same process the selection
key equals the recorded `NAGARE_RESOLVED_CONTEXT` marker, so step 4 does not clear anything; the
snapshot in step 5 captures the already-exported context values, sourcing re-sets them to the same
values, and the re-export restores them — the environment is unchanged. The re-exported
`NAGARE_CONTEXT` (a resolved name, or the reserved `default`) is re-read as the request and resolves to
the same target, so re-sourcing does not hard-error. direnv re-evaluates `.envrc`
on every `cd` and on watched-file changes; because the resolver is idempotent, repeated evaluation is
stable.

Recovery paths:

- **Wrong context stuck in a shell.** `unset NAGARE_CONTEXT NAGARE_RESOLVED_CONTEXT; direnv reload`
  (or leave and re-enter the directory) re-resolves from the pointer/in-repo profile.
- **Dangling `current-context`.** If the pointer names a context whose file was deleted, the resolver
  fails hard, matching EP-87. Fix by `nagarectl context use <existing>` or removing the pointer.
- **Bad `NAGARE_CONTEXT`.** An explicit `NAGARE_CONTEXT` naming a missing context is a hard error
  (nonzero return, clear message) so a script does not silently run against the default. Unset it or
  correct the name.
- **Reverting.** The change is confined to `scripts/lib/target.sh` and `.envrc`; `git checkout --
  scripts/lib/target.sh .envrc` restores the pre-context behavior. No data or state is migrated, so
  there is nothing to roll back beyond the two files.


## Interfaces and Dependencies

**Depends on** `docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` (EP-87) for:
the store directory `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, the
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` pointer, the flat `export VAR=value` schema
(identical to `nagare.target.env`), and the precedence
`NAGARE_CONTEXT > pointer > in-repo profile > default` with per-field `env > context > default`.

**Coordinates with** `docs/plans/88-nagarectl-context-command-group-and-context-selection.md` (EP-88):
EP-88 owns `nagarectl context use|list|current|show|create|delete` and the `--context` flag. This plan
provides the bash counterpart: `nagarectl context use` writes the pointer that M2's `watch_file`
watches. There is no `--context` on the bash side.

**Coordinates with** `docs/plans/90-per-context-pulumi-state-and-config-projection.md` (EP-90): M2
resolves the context first (exporting the resolved `NAGARE_CONTEXT`), then reaches a marked EP-90
hand-off hook above the Pulumi exports; EP-90 will make the Pulumi backend per-context, keying
`PULUMI_BACKEND_URL`/`PULUMI_HOME` and `pulumi stack select` off `NAGARE_CONTEXT` at that hook. This
plan produces `NAGARE_CONTEXT` but does not relocate Pulumi state.

**Consumed by** the justfile, `scripts/*.sh`, and
`docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md` (EP-91):
they read the exported contract (`CLOUDSDK_*`, `NAGARE_*`) with no change to how they read it. EP-91's
`cluster-bootstrap`-style rendering substitutes this plan's canonical `NAGARE_REGISTRY_PREFIX` into the
Service image refs and otherwise resolves the active context through this bash layer.

**Interfaces this plan establishes** (the bash resolution contract, Integration Point 3). At the end
of the milestones, `scripts/lib/target.sh` exposes, when sourced:

- Function `_nagare_resolve_context` — resolves and exports the active context per the precedence
  above; re-exports `NAGARE_CONTEXT` as the resolved active-context name (a store `<name>` or the
  reserved `default`), sets `NAGARE_ACTIVE_CONTEXT` (a readable mirror of the same name),
  `NAGARE_ACTIVE_CONTEXT_FILE` (the sourced file path; empty for the built-in default),
  `NAGARE_REGISTRY_PREFIX` (see below), and the internal marker `NAGARE_RESOLVED_CONTEXT`
  (`ctx:<name>`, `:inrepo:`, or `:default:`). Returns nonzero only when an explicit `NAGARE_CONTEXT`
  names a nonexistent context (the reserved `default` is exempt).
- Function `_require_target_project` — the fail-closed guard over the active context: steps aside for
  `NAGARE_MODE=local` contexts after asserting the loopback invariants, else refuses unless gcloud's
  effective project equals `TARGET_PROJECT` (the active context's project). Returns nonzero on
  refusal.
- Shell variables `TARGET_PROJECT`, `TARGET_REGION`, `TARGET_ZONE`, `TARGET_PLATFORM`, and the array
  `_NAGARE_CONTEXT_VARS`, plus the exported contract variables the active context provided.
- **Canonical derived exports (consumed by the de-hardcoding siblings):**
  - `NAGARE_CONTEXT` — the resolved active-context **name**, never empty. Canonical for
    `docs/plans/90-per-context-pulumi-state-and-config-projection.md`, which keys the per-context
    Pulumi backend directory + stack name off it.
  - `NAGARE_REGISTRY_PREFIX` — mode-aware image-ref prefix, recomputed every resolution. Cloud:
    `<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>` (default
    `us-west1-docker.pkg.dev/tan-nb-exp/nagare`). Local: the flat local-registry host (default
    `k3d-registry.localhost:5000`). Canonical for
    `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`, which
    substitutes it into the auth-plane/`nagared` Service image refs.
- Exported: `NAGARE_SSH_USER` (default `deploy`), `CLOUDSDK_CORE_PROJECT`,
  `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`,
  `NAGARE_TARGET_PLATFORM` (defaults applied), `NAGARE_CONTEXT`, `NAGARE_ACTIVE_CONTEXT`,
  `NAGARE_ACTIVE_CONTEXT_FILE`, `NAGARE_REGISTRY_PREFIX`, `NAGARE_RESOLVED_CONTEXT`, and the remaining
  `NAGARE_*` contract variables.

`.envrc` exposes, to any shell entered in the repo: the exported active-context contract (via
`source scripts/lib/target.sh`), `PULUMI_HOME`, `PULUMI_CONFIG_PASSPHRASE`, and the flake dev shell
(`use flake`), and reloads on changes to `current-context`, the active context file, and the in-repo
profiles.

No new external libraries or services are introduced; the resolver is pure bash (bash 3.2-compatible
array expansions, `tr`, `grep`) and reuses only what direnv already provides (`watch_file`,
`use flake`).


## Revision History

- 2026-06-30 — Initial authored plan (planning only; no source edited). Establishes the bash context
  resolver (`_nagare_resolve_context`), the `.envrc` rewrite, and the context-aware guardrail rework,
  fulfilling Integration Points 3 and 4 of
  `docs/masterplans/17-first-class-target-contexts-for-nagare.md`. Records the key decisions: bash
  reads the same flat store with no parser; env-wins via snapshot with a stale-projection marker; the
  guard asserts over the active context's project; `NAGARE_MODE=local` folded into a context-`mode`
  branch.

- 2026-06-30 — Cross-plan reconciliation (locked with siblings EP-87/EP-90/EP-91). Made the resolver
  the canonical producer of two derived exports the de-hardcoding plans consume: `NAGARE_CONTEXT`
  re-exported as the resolved active-context **name** (reserved `default` for the in-repo/built-in
  chain; a named-but-missing context is a hard error mirroring EP-87) for EP-90's per-context Pulumi
  keying, and `NAGARE_REGISTRY_PREFIX` (mode-aware image-ref prefix) for EP-91's Service image-ref
  substitution. Reworked the resolver to capture the incoming `NAGARE_CONTEXT` request at entry and
  re-export the resolved name (idempotent under re-source via the reserved `default`). Fixed `.envrc`
  ordering so the context resolves before a marked EP-90 Pulumi hand-off hook. Pinned the test
  isolation (temp `XDG_CONFIG_HOME` + cleared `NAGARE_CONTEXT`) to match EP-87. Why: these were locked
  while drafting so EP-89 is consistent with its siblings and each canonical export has exactly one
  producer.

Commit trailers to use when landing changes under this plan:

```text
MasterPlan: docs/masterplans/17-first-class-target-contexts-for-nagare.md
ExecPlan: docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md
Intention: intention_01kwdepj5gey18qqy0pjjx3mep
```
