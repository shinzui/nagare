# nagare — operating rules

## Release goal

The operator's goal and its evidence-backed checklist are in
[`docs/releases/production-readiness-checklist.md`](docs/releases/production-readiness-checklist.md):
production use with a day-to-day reliable ledger, no data loss, safe node and database upgrades, and
safe continued development.

## GCP project isolation

This repository targets **one** GCP project at a time — but **which** project is
**configurable**, not hard-coded. The target (project, region, zone, and the
derived resource names) is the **active target context**: a named flat
`export VAR=value` bundle in
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, selected by
`nagarectl --context NAME`, `NAGARE_CONTEXT=NAME`, or
`nagarectl context use NAME`. The tracked `nagare.target.env.example` and
`nagare.local.env.example` document the same schema. `tan-nb-exp` is the
**default example, not a hard constraint**: with no context and no in-repo
profile present the defaults reproduce it, so the original setup is unchanged.

The single-project isolation guardrail is **preserved and still fail-closed** —
it now asserts against the **active cloud context's** project rather than the
literal `tan-nb-exp`. No script, command, or instruction may act on a project
other than the active context; that applies to reads (listing, describing,
querying) too. Switching targets means selecting a different context, not
editing a tracked file. The old in-repo `nagare.target.env` and
`nagare.local.env` files remain valid lower-precedence fallbacks for
back compatibility.

**A local context (`mode=local`) is a supported testing path where the GCP
guardrail steps aside by design** — and this does **not** weaken the rule above.
Local mode (MasterPlan 16; see [`docs/user/local-development.md`](docs/user/local-development.md))
points every primitive at loopback substitutes — a k3d cluster, a local registry,
MinIO instead of GCS — so there is **no GCP project to protect**. When
the active context has `mode=local`, `_require_target_project` steps aside
(after asserting the local target is genuinely loopback, never a real
`*.pkg.dev` registry or a non-loopback domain, so a misconfigured context cannot
silently disarm protection while pointing at GCP). When the active context has
`mode=cloud`, the guardrail stays fail-closed exactly as before. The local smoke
test `just local-smoke` relies on this branch; the cloud branch must never
become anything but fail-closed.

### How the policy is enforced

1. **The active context is canonical.** The canonical variables — read verbatim
   by every consumer — are `CLOUDSDK_CORE_PROJECT`,
   `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE` (the standard Cloud SDK
   names, so interactive `gcloud` and the Pulumi GCP provider honor them), plus
   `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID`,
   `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
   `NAGARE_INSTANCE_NAME`, `NAGARE_TARGET_PLATFORM`, `NAGARE_MODE`, `NAGARE_INGRESS`, and
   `NAGARE_LOCAL_OBJECT_STORE`, `NAGARE_INVENTORY_STORE`,
   `NAGARE_INVENTORY_STORE_URL`, and `NAGARE_BACKUP_RECOVERY_POINT`. Selection precedence: `--context` /
   `NAGARE_CONTEXT` > current-context pointer > in-repo profile > built-in
   default. Per-field precedence: environment > context/profile > default.

2. **`.envrc`** at the repo root resolves the active context and exports the
   `CLOUDSDK_*` / `NAGARE_*` contract, so any shell entered here makes the active
   project the default for unqualified `gcloud`. Run `direnv allow` once.

3. **The guardrail lives in one place:** `scripts/lib/target.sh`. Scripts
   `source` it and call `_require_target_project`, which refuses to run unless
   gcloud's active project equals the active cloud context's `TARGET_PROJECT`.
   This replaces the six-line preflight that used to be copy-pasted into every
   script. No code may weaken the fail-closed behavior; only the compared value
   is context-driven.

4. **Pulumi config is a derived projection** of the context (written at
   onboarding/context selection, not hand-edited). `.envrc` and the scripts
   never shell out to Pulumi to learn the target; they read the active context,
   which is instant and works before any stack exists.

5. **Pulumi state is isolated per context** via
   `PULUMI_BACKEND_URL=file://${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state`
   by default, or `gs://<project>-nagare-pulumi-state/nagare/<context>` when the
   context sets `NAGARE_PULUMI_BACKEND=gcs` (as `tan-nb-exp` does), with matching
   per-context `PULUMI_HOME`. The stack name is the context name, and generated
   `infra/pulumi/Pulumi.<context>.yaml` files are ignored. A shell loaded before a
   backend change keeps the old backend in its environment; reload it first.

6. **Operator material is not in this repository** (ADR 13). Contexts, host
   flakes, encrypted secrets, and sops recipients for a real installation live in
   the operator's private repository (for `tan-nb-exp`, `shinzui/nagare-ops`),
   symlinked into the XDG paths. Never commit operator secrets, recipients, keys,
   passphrases, or Pulumi state here.

## Host and cloud mutation rules

- Host configuration changes go **only** through `just host-switch`, which verifies SSH access
  with a fresh login and reverts itself otherwise (ExecPlan 115, ADR 11). Never run
  `nixos-rebuild switch|boot|test`, `switch-to-configuration`, or edit the system profile
  directly. The in-repo `nixos#nagare-01` is an evaluation fixture and refuses activation.
- **When any guard, check, or script refuses, stop and report to the user.** Do not work around
  it, and do not chain speculative recovery actions against a host you cannot observe. Write the
  recovery as an ExecPlan with pass/fail gates first.
- GCE startup scripts do not run on Nagare's NixOS image. Never use them for recovery.
- Cloud-mutating commands need the operator's go-ahead. Rehearse them first, then ask once for a
  bounded sequence rather than per command. No Claude Code hook enforces this; the agent guard was
  removed on 2026-09-13 (ADR 11 amendment).

## Plans, evidence and gates (operator decision, 2026-10-10)

The requirement, in the operator's words: developers can deploy and log in to the intranet, and the
operator can change and upgrade Nagare without losing data. A release counts when the intranet runs
on it, not when a tag exists. Work is judged by which of those two it moves.

These rules override the defaults of the `exec-plan`, `master-plan` and `nagare-release` skills,
which defer to the user's scope:

- **A plan is a deliverable checklist plus a decision log.** Progress holds the deliverables with
  pass/fail evidence. Decision Log holds decisions that change scope or design, dated. Do not write
  compatibility tables, per-commit progress narration or revision notes. A Surprises & Discoveries
  entry is allowed only when a finding changed the plan or a decision: a few lines with its
  evidence. Outcomes & Retrospective is one paragraph at completion stating what was achieved, what
  remains and what moves to an ADR (operator decision, 2026-10-29; the 2026-10-10 rule had banned
  both and left lessons with no home in the repository). ADRs stay for real architecture changes.
  The `MasterPlan:` and `ExecPlan:` trailers are optional; the `Intention:` trailer is not used.
- **Never answer a mistake with a new check, script, rule, runbook item or plan.** Fix it in one
  line and keep working. Prefer removing a step to adding one.
- **Size the ceremony to the risk** (operator, 2026-11-17; MasterPlan 37, 2026-11-20). A change
  needs a unit test, plus a native confirmation only when native behaviour changes. An ExecPlan is
  required only for multi-day or data-risk work. Everything that guards data loss and the GCP
  guardrail's fail-closed behaviour stays exactly as strict.
- **Per Haskell commit:** `just gate-commit`: the style check, then a build and the tests of only
  the touched packages, in nagarectl's suite only the test groups the change reaches (operator,
  2026-11-17). **Per landing:** `just gate-fast` with no uncommitted changes, then `just land`,
  which starts the full gate on the landed commit in the background; a red full gate blocks the
  next land until a fully gated fix lands (operator decision, 2026-10-11). **Per release:** the
  candidate's landed full-gate record, or that full gate run by the candidate; the mutation sweep
  and the deep tier are not release steps (operator, 2026-11-20). A docs-only commit carries its
  gated ancestor's record forward.
- **Mutation sweep: run it when the change calls for it** (operator, 2026-11-21). Before landing a
  change to code that guards data or recovery (planner, executor, journal, proofs, adapters,
  admission, transitions) or to a test a mutation record names, run `just mutation-check REV BASE`.
  It proves only the records whose files the range touched; if it selects none, there is nothing to
  run. After a broad refactor of those areas, run `just mutation-sweep REV` over every record. Skip
  it for docs, release tooling and code no record touches. A surviving record means a test no longer
  catches a known bug: fix the test before landing. The recovery
  model's deep tier, `just gate-deep REV`, takes about 8 hours: it is a manual tool for recovery work,
  never a landing or release step (ADR 25).
- **Releases after v0.5.0 prove three things:** the full gate is green, the EP-172 upgrade
  rehearsal on a disposable local context reads the seeded data back unchanged, and the real
  intranet context upgrades and passes the deploy-and-login check. No per-release local and cloud
  evidence chain is re-run.
## Git conventions

- **Conventional Commits.** Every commit message follows the Conventional
  Commits specification: a type prefix such as `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, or `chore:`, optionally with a scope
  (e.g. `feat(infra): ...`), and a `!` or `BREAKING CHANGE:` footer for
  breaking changes.

- **No feature branches by default.** Commit directly to the current
  branch unless explicitly asked to create a new branch.

## Haskell conventions

Production Haskell follows [ADR 16](docs/adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)
and the canonical `haskell-jitsurei` standards at
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. Use the package Prelude, postpositive
`qualified`, strict unprefixed project-owned record fields, explicit deriving strategies, and
generic-lens labels for project-owned record access and updates. Every `data` record field has an
explicit `!`; only `newtype` fields omit it because GHC rejects a strictness annotation there.
Import `Data.Generics.Labels ()` only in modules that use those labels; `PackageImports` belongs
only in package Prelude modules. Run `just haskell-style-check` before committing Haskell changes.
