---
id: 12
slug: bring-your-own-gcp-project-onboarding-for-nagare
title: "Bring-your-own GCP project onboarding for nagare"
kind: master-plan
created_at: 2026-06-10T21:59:26Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
---

# Bring-your-own GCP project onboarding for nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today **nagare** is welded to one Google Cloud Platform (GCP) project, `tan-nb-exp`, in region
`us-west1`, zone `us-west1-a`. That binding is not a single config value — it is spread across the
repo-root `.envrc`, eight shell scripts under `scripts/`, the Haskell command-line tool `nagarectl`
(six literal `tan-nb-exp` references plus a hard-coded Artifact Registry host and hard-coded
region/zone/bucket defaults), and the deployment DSL (each example app's `nagare/Config.hs` bakes the
full image path `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>`). The project's own `CLAUDE.md`
declares this single-project binding a hard policy and forbids pointing any command at another project
without a Decision Log entry first. As a result there is no supported way for a second person — or the
same person with a second project — to stand nagare up on their own GCP account.

After this initiative is complete, a new operator can take a clean GCP project and a domain and bring
nagare up on it end to end, without editing any tracked source file to replace `tan-nb-exp`. Concretely:
they run `nagarectl init`, which checks that they are authenticated to gcloud, checks that their account
holds the IAM roles needed to provision, prompts for their project / region / zone / base domain, writes
a single git-ignored **target profile** file (`nagare.target.env`), enables the required GCP service
APIs, and seeds the Pulumi stack configuration from that profile. From there the existing provisioning
path — `just infra-up`, build and register the NixOS image, boot the VM, bootstrap the cluster — works
unchanged because every layer now reads its GCP target from the profile instead of from a literal. The
single-project isolation guardrail is preserved, not removed: every script and the CLI still refuse to
act if gcloud's active project does not match the configured target — they now assert against the
operator's configured project rather than against the literal `tan-nb-exp`.

The unifying concept is the **target profile**: one git-ignored file, `nagare.target.env`, that holds
the operator's GCP target (project, region, zone, Artifact Registry host, image and backup bucket names,
base domain, instance name) as `export`ed shell variables. It is the single source of truth. `.envrc`
sources it; `scripts/lib/target.sh` sources it; `nagarectl` reads it from the process environment; and
the Pulumi stack configuration is a **derived projection** of it, written once at onboarding by
`nagarectl init` (and re-syncable) rather than hand-edited. A tracked `nagare.target.env.example`
documents the schema and ships the `tan-nb-exp` values as the worked example so the existing operator's
workflow is unchanged (they copy the example, or keep their existing profile).

In scope: making `tan-nb-exp`/`us-west1`/`us-west1-a` and all derived names configurable from the target
profile across `.envrc`, every `scripts/` file, `nagarectl`, and the DSL image-reference construction;
a configurable-but-still-enforced isolation guardrail; codifying GCP service-API enablement (today a
documented-but-manual step that bit the original bootstrap); the `nagarectl init` guided onboarding
command with gcloud-auth and operator-IAM preflight checks; and a complete "bring your own project"
documentation set including the GCP prerequisites (auth, IAM roles, project creation, API enablement)
that the current docs omit.

Explicitly out of scope: **simultaneous multi-project / multi-tenant operation** from one checkout — the
guardrail keeps one active target per checkout (the operator chose "keep the single-project isolation
guardrail, made configurable", not "relax to per-command"); switching projects means changing the
profile, not running two at once. Also out of scope: changing what gets provisioned (the GCP resource
topology, the NixOS host design, the cluster stack) — this initiative changes *where* and *for whom*
nagare deploys, never *what* it deploys. Hosting nagare's container images on a public registry, or any
non-GCP cloud, is likewise out of scope.


## Decomposition Strategy

The initiative was decomposed by **functional concern and ownership layer**, matching the layers the
`tan-nb-exp` binding actually runs through, because each layer reads configuration through a different
mechanism (shell `export`s, sourced bash, Haskell environment/flag parsing, Pulumi config, prose docs)
and each ends in an independently verifiable behavior. Five child plans result, within the recommended
two-to-seven range, grouped into four implementation waves.

The keystone is a single foundational plan (**EP-60**) that defines the **target profile contract** —
the `nagare.target.env` schema, its `.example`, the precedence rules, and the configurable guardrail
helper `scripts/lib/target.sh` — and rewrites `.envrc` to source it. Everything else consumes that
contract, so it must come first and it is deliberately small and sharply specified. The two large
consumer layers, **EP-61** (shell scripts) and **EP-62** (the Haskell CLI and the DSL image refs), are
independent of each other and can be built in parallel once the contract exists: they touch disjoint
files (bash under `scripts/` versus Haskell under `cli/`) and share nothing but the variable names
EP-60 fixes. **EP-63** builds the product surface — the `nagarectl init` onboarding command and the
codified GCP API enablement — and depends on EP-62 because `init` is a `nagarectl` subcommand that
reuses EP-62's target-resolution types. **EP-64** is the documentation layer; it can be drafted early
but is finalized last because it documents the behavior the other four plans deliver.

A central design decision shaping the boundaries: the **target profile is canonical and the Pulumi stack
config is a derived projection of it** (see Decision Log). This was chosen over making Pulumi config the
single source of truth because `.envrc` runs on every shell entry and every script preflight needs the
target — resolving those by shelling out to `pulumi config get` would add multi-second latency to every
`cd` into the repo and would fail before the stack is initialized (a chicken-and-egg during onboarding),
whereas sourcing a plain env file is instant and self-contained. It keeps the CLI's day-to-day ops
commands (`status`, `doctor`, `db`, `cdn`) decoupled from a working local Pulumi state. The one command
permitted to drive Pulumi is `nagarectl init` (a deliberate one-time bootstrap that writes the env file
and seeds the stack), which is why the onboarding surface lives in EP-63 next to the API-enablement
work rather than being smeared across the consumer plans.

Alternatives considered and rejected. **One mega-plan**: rejected — the work spans bash, Haskell, Pulumi
TypeScript, and docs across well over ten files in unrelated toolchains; it could not be verified
incrementally. **Splitting the CLI plan from the DSL image-ref plan**: rejected — the registry host the
DSL needs and the registry host the CLI's `Image`/`Status` modules need are the same value derived the
same way; splitting them would create one integration point for one shared derivation with no gain in
verifiability, so they are one plan (EP-62) with separate milestones. **Folding API enablement into the
foundation plan (EP-60)**: rejected — API enablement is a GCP-side provisioning concern that belongs
with the onboarding command and Pulumi (`gcp.projects.Service`), and EP-60 is intentionally limited to
the profile contract and the guardrail so it stays small and unblocks the parallel consumers fast.
**Making `nagarectl init` just a `just` target over scripts**: considered; the operator chose a
first-class `nagarectl init` command for a testable, guided UX, so the orchestration lives in Haskell
(EP-63) while still shelling out to the codified API-enablement step.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 60 | Target profile model and configurable isolation guardrail | docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md | None | None | Complete |
| 61 | Parameterize shell scripts and .envrc to the target profile | docs/plans/61-parameterize-shell-scripts-and-envrc-to-the-target-profile.md | EP-60 | None | Complete |
| 62 | Parameterize nagarectl and the DSL image refs to the target profile | docs/plans/62-parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile.md | EP-60 | None | Not Started |
| 63 | GCP bootstrap automation and nagarectl init onboarding command | docs/plans/63-gcp-bootstrap-automation-and-nagarectl-init-onboarding-command.md | EP-60, EP-62 | EP-61 | Not Started |
| 64 | Bring-your-own-project onboarding documentation | docs/plans/64-bring-your-own-project-onboarding-documentation.md | None | EP-60, EP-61, EP-62, EP-63 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference other
rows by their `EP-<#>` prefix.

Implementation waves (phases):

- **Wave 1 — Contract:** EP-60. Defines the `nagare.target.env` schema, `scripts/lib/target.sh`, and the
  `.envrc` rewrite. Nothing else can correctly read the target until this exists.
- **Wave 2 — Consumers (parallel):** EP-61 and EP-62. Disjoint file sets (bash vs Haskell); both
  hard-depend only on EP-60. A single implementer can do them in either order or interleave them.
- **Wave 3 — Product surface:** EP-63. The `nagarectl init` command and codified API enablement;
  hard-depends on EP-62 (shares the CLI's target-resolution types) and soft-depends on EP-61 (its
  guided flow calls the parameterized scripts).
- **Wave 4 — Documentation:** EP-64. Drafted from Wave 1 onward, finalized after EP-63 so the documented
  onboarding matches the shipped `nagarectl init` behavior.


## Dependency Graph

EP-60 (target profile contract) has no dependencies. It is the single source of truth: it creates
`nagare.target.env.example`, the git-ignore entry for the real `nagare.target.env`, the shared bash
helper `scripts/lib/target.sh` that loads the profile and runs the configurable preflight assertion, and
the rewritten `.envrc` that sources the profile with `tan-nb-exp`/`us-west1`/`us-west1-a` as fallback
defaults. Every other plan depends on the variable names and semantics EP-60 fixes.

EP-61 (scripts and `.envrc`) **hard-depends on EP-60** because every script is rewritten to `source`
EP-60's `scripts/lib/target.sh` in place of its own `PROJECT=tan-nb-exp` preflight, and the template
`scripts/nix-builder-startup.sh.tpl` is rewritten to take the project as a substituted parameter. It
would not function without the helper EP-60 defines.

EP-62 (nagarectl + DSL image refs) **hard-depends on EP-60** because the Haskell target-resolution layer
reads exactly the environment variables EP-60 names (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`,
`CLOUDSDK_COMPUTE_ZONE`, `NAGARE_REGISTRY_HOST`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
`NAGARE_INSTANCE_NAME`, etc.). EP-61 and EP-62 share no code and can proceed in parallel.

EP-63 (bootstrap + `nagarectl init`) **hard-depends on EP-62** (it is a new `nagarectl` subcommand that
constructs and writes a target profile and reuses EP-62's `TargetProfile` record and resolution code)
and on EP-60 (the file it writes is EP-60's contract). It **soft-depends on EP-61** because the guided
flow invokes the parameterized provisioning scripts and the new `scripts/enable-apis.sh`; if EP-61 is not
yet done, `init` can still write the profile and call gcloud directly, but the end-to-end story is
cleanest once EP-61's scripts read the same profile.

EP-64 (documentation) has **no hard dependency** — prose can be written against the design at any time —
but **soft-depends on all four** because it documents their delivered behavior; it is finalized last so
the runbook matches the shipped `nagarectl init` and the parameterized scripts.

Parallelism: after EP-60, EP-61 and EP-62 run in parallel. EP-63 begins once EP-62 is Complete. EP-64
drafting overlaps everything and is finalized after EP-63.


## Integration Points

**1. The target profile contract (defined by EP-60; consumed by EP-61, EP-62, EP-63, EP-64).** EP-60 is
the single source of truth for the GCP target. The contract is a git-ignored file `nagare.target.env` at
the repo root, a sequence of `export VAR=value` lines, with a tracked `nagare.target.env.example`
carrying the schema and the `tan-nb-exp` worked example. The canonical variable names — which every
consumer must use verbatim — are: `CLOUDSDK_CORE_PROJECT` (GCP project id), `CLOUDSDK_COMPUTE_REGION`
(e.g. `us-west1`), `CLOUDSDK_COMPUTE_ZONE` (e.g. `us-west1-a`), `NAGARE_REGISTRY_HOST` (e.g.
`us-west1-docker.pkg.dev`, derived as `<region>-docker.pkg.dev`), `NAGARE_ARTIFACT_REGISTRY_ID` (e.g.
`nagare`), `NAGARE_IMAGE_BUCKET` (e.g. `<project>-nagare-images`), `NAGARE_BACKUP_BUCKET` (e.g.
`<project>-nagare-backups`), `NAGARE_BASE_DOMAIN` (e.g. `apps.example.com`), and `NAGARE_INSTANCE_NAME`
(e.g. `nagare-01`). The first three reuse the standard Cloud SDK variable names so interactive `gcloud`
and the Pulumi GCP provider also honor them. Precedence: a value already present in the environment
wins; otherwise the profile value applies; otherwise EP-60's fallback default (the `tan-nb-exp` value)
applies, so an operator who does nothing keeps today's behavior. Consumers must never re-introduce a
literal `tan-nb-exp`/`us-west1` — they read these variables. EP-60 owns this list; if a later plan needs
a new target field, it adds the variable to EP-60's `.example` and this section and notifies the other
consumers.

**2. The configurable isolation guardrail (defined by EP-60; consumed by EP-61, EP-63).** Today every
script embeds a six-line preflight that refuses to run unless gcloud's active project equals the literal
`tan-nb-exp` (MasterPlan-1 Integration Point 9). EP-60 replaces that with a single sourced helper
`scripts/lib/target.sh` exposing `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE` (loaded from the profile)
and a `_require_target_project` check that refuses to run unless the active project equals
`$TARGET_PROJECT`. The guardrail is preserved in force — it is still fail-closed — but it now asserts
against the configured project. EP-61 replaces each script's inline preflight with `source
"$(dirname "$0")/lib/target.sh"`. EP-63's onboarding scripts (e.g. `scripts/enable-apis.sh`) source the
same helper. No plan may weaken the fail-closed behavior; only the compared value becomes configurable.

**3. Pulumi config as a derived projection of the profile (Pulumi already parameterized by MasterPlan-1
EP-2; projection written by EP-63; read by EP-61).** The Pulumi program `infra/pulumi/index.ts` already
reads every GCP target from stack config (`gcp:project`, `gcp:region`, `gcp:zone`, `nagare:baseDomain`,
`nagare:imageBucket`, `nagare:backupBucket`, `nagare:artifactRegistryId`, `nagare:instanceName`,
`nagare:nagareImageSelfLink`) — no Pulumi *code* change is required for portability. What changes is that
the stack config becomes a projection of the profile rather than a hand-edited file: EP-63's `nagarectl
init` runs `pulumi config set` from the profile values, and a `just target-sync` re-applies them. EP-61's
`scripts/upload-images.sh` continues to read `imageBucket` via `pulumi config get` and writes
`nagareImageSelfLink` back — that self-link embeds the project, so it must be (re)generated per target,
never committed for a foreign project. The committed `Pulumi.dev.yaml` keeps the `tan-nb-exp` values as
the worked example; a new operator's stack config is generated, not the committed one.

**4. Registry-host derivation for image references (defined by EP-62; affects EP-63, EP-64, and example
apps).** Today each app's `cli/nagare-dsl/.../nagare/Config.hs` calls `mkImageRef
"us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>"`, baking project and region into application source.
EP-62 makes the registry prefix (`<registry-host>/<project>/<artifact-registry-id>`) derivable from the
target profile so an app's `Config.hs` supplies only the app's own image *name* and the prefix comes from
`NAGARE_REGISTRY_HOST`/`CLOUDSDK_CORE_PROJECT`/`NAGARE_ARTIFACT_REGISTRY_ID` at deploy time. EP-62 defines
the derivation and updates the example/fixture `Config.hs` files; EP-64 documents the new image-ref
authoring story; EP-63's `init` ensures the variables the derivation needs are present in the profile.

**5. CLAUDE.md policy revision and the Decision Log requirement (owned by EP-60).** The repo's `CLAUDE.md`
currently states the single-project `tan-nb-exp` binding as immutable policy and requires a MasterPlan
Decision Log entry before any code targets another project. This MasterPlan *is* that decision (see the
Decision Log below). EP-60 rewrites the `CLAUDE.md` "GCP project isolation" section to describe the new
model: the guardrail is configurable via the target profile, still fail-closed against the *configured*
project, and `tan-nb-exp` is the default example, not a hard constraint. EP-64 aligns the user-facing
docs (`docs/user/`) with the same model. No other plan edits `CLAUDE.md`; they rely on EP-60's revision.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-60: `nagare.target.env.example` + git-ignore entry exist; `scripts/lib/target.sh` loads the profile and runs the configurable fail-closed preflight; `.envrc` sources the profile with `tan-nb-exp` fallbacks; `CLAUDE.md` isolation section rewritten to the configurable model. (2026-06-10)
- [x] EP-61: all eight `scripts/` files source `scripts/lib/target.sh` (no literal `tan-nb-exp`/`us-west1` preflight remains); the one in-cluster project literal (`restore-volume.sh` Job manifest) is interpolated from `$TARGET_PROJECT`; the cdn-spike example scripts are reconciled; scripts run green against the default profile. (Note: `nix-builder-startup.sh.tpl` was found to carry no project literal, so it needs no change — see EP-61 Surprises.) (2026-06-10)
- [ ] EP-62: `nagarectl` resolves a `TargetProfile` from the environment; the six literal `tan-nb-exp` refs, the `registryHost` constant, and the region/zone/bucket defaults are gone; DSL image refs derive their prefix from the profile; example/fixture `Config.hs` no longer bake project/region; CLI test suite green.
- [ ] EP-63: `scripts/enable-apis.sh` (and/or `gcp.projects.Service`) codifies API enablement; `nagarectl init` preflights gcloud auth + operator IAM, prompts and writes `nagare.target.env`, enables APIs, and seeds Pulumi config; verified by onboarding a fresh (or simulated) project.
- [ ] EP-64: `docs/user/gcp-prerequisites.md` and `docs/user/onboarding-bring-your-own-project.md` exist; getting-started / provisioning / host-image docs are project-agnostic; the configurable-guardrail model and the documented onboarding gaps (auth, IAM, age key, Tailscale, Docker auth) are covered.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Planning-time correction (EP-61): the initial research claimed `scripts/nix-builder-startup.sh.tpl`
  hard-codes `tan-nb-exp` at line ~84 and would need an `@TARGET_PROJECT@` substitution. Reading the
  template disproved this — line 84 is a systemd heredoc terminator, and a tree grep finds no project
  literal or `CLOUDSDK_CORE_PROJECT` in the `.tpl`. The only in-cluster project literal in the repo is
  `scripts/restore-volume.sh` line ~84 (a line-number coincidence), which EP-61 interpolates from
  `$TARGET_PROJECT`. Scope for EP-61 was trimmed accordingly; Integration Point 3 and the EP-61 Progress
  line were corrected. Lesson for the remaining plans: verify each claimed hard-coded site against the
  live file before treating it as work. (2026-06-10)
- Cross-plan consistency pass (all five child plans drafted in parallel) found full agreement on every
  shared contract — the nine `nagare.target.env` variable names and defaults, the `nagare.target.env` /
  `.example` file names, the `scripts/lib/target.sh` helper path + `TARGET_PROJECT/REGION/ZONE` +
  `_require_target_project`, the Haskell `Nagare.Target.TargetProfile` record + `resolveTargetProfile`,
  the image-ref derivation (`registryPrefix`, bare-name-only app `Config.hs`), the six operator IAM
  roles, the six service APIs, the `nagarectl init` flags, and the eight seeded Pulumi keys all match
  across the plans that touch them. No reconciliation edits were needed beyond the `.tpl` correction
  above. (2026-06-10)


- Implementation-time contract correction (EP-60 → EP-61, affects EP-63). The child plans assumed
  EP-60's `scripts/lib/target.sh` would run the fail-closed preflight automatically *on source*. As
  delivered (and verified), the helper instead only loads the profile, sets
  `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`, and **defines** `_require_target_project`; the
  caller must invoke it explicitly. EP-61 therefore writes `source ".../lib/target.sh"` **followed by
  a `_require_target_project` line** in every script. EP-63's onboarding scripts (e.g.
  `scripts/enable-apis.sh`) must do the same — source then call. This is consistent with EP-60's own
  CLAUDE.md/Interfaces text ("scripts source it and call `_require_target_project`"); the discrepancy
  was only in the consumer plans' Interfaces summaries. (2026-06-10)
- Implementation-time semantics note (EP-61, affects EP-63 and EP-64 docs). Because the helper
  derives `TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"` from the same Cloud SDK variable it
  reads as the "active" project, setting `CLOUDSDK_CORE_PROJECT=wrong` makes both sides equal and the
  preflight passes — by design, since an explicitly-set Cloud SDK project *is* the configured target.
  The guard bites the real failure mode: `CLOUDSDK_CORE_PROJECT` unset (operator forgot `direnv
  allow`) while gcloud's *config* default differs from the profile/default target. EP-64's docs and
  any onboarding-time verification in EP-63 should demonstrate the guard this way (env unset +
  divergent gcloud config), not by exporting a "wrong" `CLOUDSDK_CORE_PROJECT`. (2026-06-10)


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: nagare will support being deployed against any GCP project/account, and `tan-nb-exp` ceases
  to be a hard-coded constraint — it becomes the default worked example. This MasterPlan is the
  architectural decision that `CLAUDE.md` requires before any code targets another project.
  Rationale: The owner asked whether nagare could be documented and used on any GCP project/account, and
  chose "full product onboarding" (anyone can bring their own GCP account/project from scratch) with the
  single-project isolation guardrail kept but made configurable. The `CLAUDE.md` policy explicitly states
  that changing the target project requires a Decision Log entry first (it points at this MasterPlan's
  predecessor, `docs/masterplans/1-bootstrap-nagare-personal-paas.md`, Decision of 2026-06-02). EP-60
  carries out the corresponding `CLAUDE.md` rewrite.
  Date: 2026-06-10

- Decision: the **target profile is canonical; the Pulumi stack config is a derived projection** of it.
  The profile is a git-ignored `nagare.target.env` of `export`ed variables, sourced by `.envrc` and
  `scripts/lib/target.sh` and read from the environment by `nagarectl`; Pulumi config is written from it
  at onboarding (`nagarectl init`) and re-syncable, not hand-edited.
  Rationale: Compared against making Pulumi config the single source of truth, the env-file approach
  avoids paying Pulumi-engine latency (and an init-order chicken-and-egg) on every shell entry and every
  script preflight, keeps day-to-day CLI ops commands decoupled from a working local Pulumi state, and
  gives "bring your own project" a clean git-ignored front door that keeps the committed repo
  project-agnostic. Pulumi's program is already fully parameterized (MasterPlan-1 EP-2), so no Pulumi
  *code* change is needed — only the projection step. See Integration Point 3 and the Decomposition
  Strategy.
  Date: 2026-06-10

- Decision: the isolation guardrail is preserved and remains fail-closed; only the project it compares
  against becomes configurable (asserts `active == $TARGET_PROJECT` instead of `== tan-nb-exp`),
  centralized in a single sourced helper `scripts/lib/target.sh`.
  Rationale: The owner chose "keep the single-project isolation guardrail, made configurable" over
  relaxing it to per-command targeting. Centralizing the preflight removes six lines of duplicated
  boilerplate per script and ensures every consumer enforces the same configurable check (Integration
  Point 2).
  Date: 2026-06-10

- Decision: the guided onboarding surface is a first-class `nagarectl init` command (EP-63), not a
  `just`-plus-scripts orchestrator nor docs-only. Ops commands (`status`, `doctor`, `db`, `cdn`) still
  resolve their target purely from the environment profile and never require Pulumi; `init` is the one
  command allowed to drive Pulumi (`pulumi config set`) and gcloud (`services enable`) as a deliberate
  one-time bootstrap.
  Rationale: The owner selected `nagarectl init` for a testable, guided UX. Confining the Pulumi-driving
  to `init` keeps the env-canonical decoupling intact for everyday commands while still giving onboarding
  a single front door. API-enablement codification lives in the same plan because it is part of the same
  bootstrap concern.
  Date: 2026-06-10

- Decision: decompose into five child plans in four waves — EP-60 (profile contract + guardrail), EP-61
  (scripts/.envrc), EP-62 (nagarectl + DSL image refs), EP-63 (bootstrap + `nagarectl init`), EP-64
  (docs).
  Rationale: Boundaries follow the layers the `tan-nb-exp` binding runs through, each reading config by a
  different mechanism and ending in an independently verifiable behavior. EP-61 and EP-62 touch disjoint
  file sets (bash vs Haskell) and run in parallel after the contract. See Decomposition Strategy for the
  rejected alternatives (mega-plan; splitting CLI from DSL image refs; folding API enablement into
  EP-60; a `just`-only onboarding surface).
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
