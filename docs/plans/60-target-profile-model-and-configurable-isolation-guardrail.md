---
id: 60
slug: target-profile-model-and-configurable-isolation-guardrail
title: "Target profile model and configurable isolation guardrail"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# Target profile model and configurable isolation guardrail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [60-target-profile-model-and-configurable-isolation-guardrail.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today **nagare** — a single-node personal Platform-as-a-Service running on one Google Cloud
virtual machine — is welded to exactly one Google Cloud Platform (GCP) project, `tan-nb-exp`,
in region `us-west1`, zone `us-west1-a`. That binding is not one configuration value; it is a
hard-coded literal copy-pasted into the repo-root `.envrc`, into a six-line "refuse to run unless
the active project is `tan-nb-exp`" guard at the top of every shell script under `scripts/`, and
the project's `CLAUDE.md` declares the single-project binding an immutable policy. There is no
supported way for a second person — or the same person with a second GCP project — to point
nagare at their own account without editing tracked source files.

This ExecPlan lays the **foundation** that makes the GCP target configurable. It does exactly two
user-visible things and nothing more (the larger consumer rewrites belong to later plans, see
"Context and Orientation"):

1. It defines the **target profile**: a single, git-ignored file `nagare.target.env` at the
   repository root that holds the operator's GCP target — project, region, zone, and the derived
   names (Artifact Registry host and id, image bucket, backup bucket, base domain, instance name)
   — as plain `export VAR=value` shell lines. A tracked `nagare.target.env.example` documents the
   schema and ships the current `tan-nb-exp` values as the worked example, so an operator who does
   nothing keeps today's behavior, and a new operator copies the example and edits one project id.

2. It makes the **isolation guardrail configurable while keeping it fail-closed**. A single new
   sourced helper, `scripts/lib/target.sh`, loads the profile (if present), sets
   `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE` (falling back to the `tan-nb-exp`/`us-west1`/
   `us-west1-a` defaults), and exposes one function `_require_target_project` that refuses to run
   unless gcloud's active project equals the configured `TARGET_PROJECT`. This replaces the
   six-line preflight currently duplicated in every script. The guardrail is **not weakened** — it
   still aborts on a mismatch — it now asserts against the *configured* project rather than the
   literal `tan-nb-exp`.

After this change an operator can do the following, and *see* it working without any cloud call:

- Run `direnv allow` in a fresh checkout with no profile file present, then
  `echo $CLOUDSDK_CORE_PROJECT` prints `tan-nb-exp` — today's behavior is preserved by the
  fallback defaults.
- Copy `nagare.target.env.example` to `nagare.target.env`, change `CLOUDSDK_CORE_PROJECT` to (say)
  `acme-prod`, re-enter the directory, and `echo $CLOUDSDK_CORE_PROJECT` now prints `acme-prod`;
  a script that sources `scripts/lib/target.sh` reports `TARGET_PROJECT=acme-prod`.
- With the profile pointing at `acme-prod` but gcloud's active project left at something else,
  any script sourcing the helper **fails closed** with a clear message and a fix hint, exactly as
  before — proving the guardrail still bites, now against the configured project.

This plan is deliberately small and sharply specified because every later plan in MasterPlan 12
(`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`) consumes the variable
names and the helper contract it fixes here. It writes no Haskell, touches no Pulumi program, and
makes no cloud call.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 — Create the tracked schema file `nagare.target.env.example` at the repo root with the
      nine canonical `export VAR=value` lines (carrying the `tan-nb-exp` worked example) and
      explanatory comments. (2026-06-10)
- [x] M1.2 — Add `nagare.target.env` (the real, per-operator profile) to `.gitignore`. (2026-06-10)
- [x] M1.3 — Create `scripts/lib/target.sh`: a sourced helper that computes the repo root from its
      own path, loads `nagare.target.env` if present, sets `TARGET_PROJECT`/`TARGET_REGION`/
      `TARGET_ZONE` with `tan-nb-exp`/`us-west1`/`us-west1-a` fallbacks, and defines the
      fail-closed `_require_target_project` preflight. (2026-06-10)
- [x] M1.4 — Verify M1 with `bash`: sourcing the helper with no profile yields the defaults;
      copying the example and editing the project changes `TARGET_PROJECT`; a forced active-project
      mismatch makes `_require_target_project` exit non-zero with the fix message. All three
      transcripts matched. (2026-06-10)
- [x] M2.1 — Rewrite `.envrc` to `source_env`/source the profile then export
      `CLOUDSDK_CORE_PROJECT`/`REGION`/`ZONE` with `${VAR:-default}` fallbacks, preserving the
      Pulumi exports and `use flake`. (2026-06-10)
- [x] M2.2 — Rewrite the "GCP project isolation" section of `CLAUDE.md` to the configurable model
      and cite MasterPlan 12 as the Decision-Log entry the old policy required. (2026-06-10)
- [x] M2.3 — Update the justfile header comment (line ~5) to describe the configurable target. (2026-06-10)
- [x] M2.4 — Verify M2: `direnv allow` then `echo $CLOUDSDK_CORE_PROJECT` is `tan-nb-exp` with no
      profile; a profile with a different project flips the exported env var on re-entry. Both
      `direnv exec` transcripts matched (`tan-nb-exp` default, `acme-prod` with profile). (2026-06-10)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The verification commands (Steps 4 and 8) use BSD `sed -i ''`, but this checkout's dev shell
  provides **GNU sed** on `PATH` (via the Nix flake), where `sed -i ''` treats `''` as a filename and
  fails (`sed: can't read s/...`). The behavior under test is unaffected — the override path works
  identically. For verification, use a non-in-place form instead, e.g.
  `sed 's/^export CLOUDSDK_CORE_PROJECT=.*/export CLOUDSDK_CORE_PROJECT=acme-prod/' nagare.target.env.example > nagare.target.env`.
  This is a test-harness detail only; no shipped file uses `sed -i`. (2026-06-10)

## Decision Log

Record every decision made while working on the plan.

- Decision: the canonical contract file is exactly `nagare.target.env` (a sequence of
  `export VAR=value` lines), tracked-example `nagare.target.env.example`; we do not also introduce
  a `.envrc.local` mechanism.
  Rationale: MasterPlan 12 Integration Point 1 fixes `nagare.target.env` as the single source of
  truth and every consumer (`.envrc`, `scripts/lib/target.sh`, `nagarectl`) reads the same file. A
  second optional include path would add a precedence question for no benefit; keep it one file.
  Date: 2026-06-10

- Decision: `.envrc` sources the profile and exports the three `CLOUDSDK_*` variables with
  `${VAR:-default}` fallbacks; it does NOT shell out to `pulumi config`.
  Rationale: MasterPlan 12 Decision Log — the target profile is canonical and Pulumi config is a
  derived projection written later by EP-63. Sourcing a plain env file is instant and works before
  any Pulumi stack exists (avoiding an onboarding chicken-and-egg). `.envrc` must stay fast on
  every `cd` into the repo.
  Date: 2026-06-10

- Decision: the first three variable names are the standard Cloud SDK ones
  (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`).
  Rationale: those env vars are honored by interactive `gcloud` and by the Pulumi GCP provider
  directly, so exporting them makes the target take effect for unqualified `gcloud` calls and for
  Pulumi without extra plumbing (MasterPlan 12 Integration Point 1).
  Date: 2026-06-10

- Decision: the guardrail stays fail-closed; only the compared value becomes configurable.
  `_require_target_project` aborts unless the active project equals `$TARGET_PROJECT`.
  Rationale: MasterPlan 12 Decision Log and Integration Point 2 — "keep the single-project
  isolation guardrail, made configurable," not relaxed to per-command. Centralizing it in one
  sourced helper removes six duplicated lines per script and guarantees one enforcement path.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-60 delivered the target-profile contract and the configurable isolation guardrail exactly as
scoped. Both milestones are complete and all four acceptance criteria (A1–A4) were verified by
observable behavior, not file presence:

- **A1** — with no profile, `direnv` and the helper both report `tan-nb-exp` (defaults preserve
  today's behavior).
- **A2** — a `nagare.target.env` with `CLOUDSDK_CORE_PROJECT=acme-prod` flips both the shell
  environment (`direnv exec`) and the guardrail's `TARGET_PROJECT`.
- **A3** — the guardrail still fails closed: forcing a mismatched active project makes
  `_require_target_project` print the refusal/fix message to stderr and return `1`.
- **A4** — `nagare.target.env` is git-ignored (`git check-ignore` echoes the path); only the
  tracked `nagare.target.env.example` and `scripts/lib/target.sh` were added.

Result vs. purpose: the GCP target is now a single git-ignored file with a tracked schema, the
guardrail is centralized in one sourced helper, and `tan-nb-exp` is a default example rather than a
hard constraint — the exact foundation EP-61/EP-62/EP-63/EP-64 consume. No Haskell, Pulumi, or cloud
call was touched, keeping the plan small as intended.

Lessons: (1) the dev shell ships GNU sed, so the plan's BSD `sed -i ''` verification form fails —
use a non-in-place redirect for the test (no shipped file uses `sed -i`). (2) Verify each downstream
plan's claimed hard-coded sites against the live files before treating them as work (echoes the
MasterPlan's `.tpl` correction).

