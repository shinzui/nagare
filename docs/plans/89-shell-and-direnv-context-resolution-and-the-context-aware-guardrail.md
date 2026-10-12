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

Full plan before trimming: [89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

