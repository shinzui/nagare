---
id: 17
slug: first-class-target-contexts-for-nagare
title: "First-class target contexts for nagare"
kind: master-plan
created_at: 2026-06-30T23:47:48Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
---

# First-class target contexts for nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today nagare's deploy target — the GCP project, region, zone, registry, buckets, apps domain, VM
instance name, build platform, and cloud-vs-local mode — is resolved from **process environment
variables**, populated by a single git-ignored profile file per working directory: `nagare.target.env`
for the cloud target (MasterPlan 12) and `nagare.local.env` + `NAGARE_MODE=local` for local mode
(MasterPlan 16). `.envrc` (direnv) sources whichever is present and exports the contract; both the
Haskell CLI (`Nagare.Target.resolveTargetProfile`) and the shell scripts (`scripts/lib/target.sh`)
read those exported variables. Because the profile and the in-repo Pulumi state
(`file://./infra/pulumi/.pulumi-state`, stack `dev`) are keyed off `$PWD`, **the unit of "a nagare
instance" is a working directory**: running a second target means a second checkout. Switching targets
means editing a file and re-running `direnv allow`. There is no concept of a named, selectable target.

After this initiative, nagare has **first-class target contexts** modeled on `kubectl`/kubeconfig: an
operator defines many named contexts (each a full target bundle) in a user-level store, marks one as
the **current context**, and selects a context per command with `--context <name>` or the
`NAGARE_CONTEXT` environment variable — exactly as `kubectl --context` / `kubectl config use-context`
work. `nagarectl context list|current|use|show|create|delete` manage them; `nagarectl --context labs
deploy …` deploys to the `labs` target without leaving the current directory or touching any file. The
same context drives the shell scripts and the justfile (so `NAGARE_CONTEXT=labs just smoke` works), the
fail-closed project guardrail (which now asserts against the active context's project), and the Pulumi
state (each context owns its own stack/state, so two contexts never collide). Crucially, **every place
that still hard-codes `tan-nb-exp` / `us-west1-docker.pkg.dev` / `apps.example.com` into something
*applied to a real cluster or project*** — the cert-manager DNS-01 `ClusterIssuer` project, the
auth-plane and `nagared` Service image references, the tracked `Pulumi.dev.yaml` config projection, and
the NixOS containerd registry host — is **parameterized from the active context**, so a second instance
needs zero tracked-file edits.

The unifying concept is the **context**: a named, fully-resolved target bundle
(`project, region, zone, registryHost, artifactRegistryId, imageBucket, backupBucket, baseDomain,
instanceName, targetPlatform, mode, localObjectStore`, plus its Pulumi state location). It **generalizes
and subsumes** the two existing mechanisms: a cloud `nagare.target.env` becomes "a context with
`mode=cloud`"; the `nagare.local.env` + `NAGARE_MODE=local` pair becomes "a context with `mode=local`".
The current single-profile behavior is preserved as a fully back-compatible special case: with no
context store and an in-repo `nagare.target.env`, nagare behaves exactly as it does today, and the
historic `tan-nb-exp` defaults still reproduce the original setup when nothing is configured.

In scope: a context store + resolver in `Nagare.Target` with explicit precedence and back-compat
(EP-87); the `nagarectl context` command group and the global `--context`/`NAGARE_CONTEXT` selection,
with `nagarectl init` writing a context (EP-88); shell + direnv resolution of the active context and the
context-aware fail-closed guardrail (EP-89); per-context Pulumi state/stack and the config projection
that replaces the tracked `Pulumi.dev.yaml` (EP-90); de-hardcoding the applied cluster manifests and the
NixOS registry host so they derive from the active context (EP-91); and the operator documentation plus
the migration path from the two profile files to contexts (EP-92).

Explicitly out of scope: **kubeconfig-style normalization** (separate cluster/credentials/context
objects so two contexts can share a sub-bundle) — contexts are flat bundles in v1; normalization can be
added later if reuse demands it. **Standing up N NixOS *hosts*** — EP-91 parameterizes the single host's
registry host so it follows the context, but generating a distinct NixOS host configuration per instance
(the `nixos/hosts/nagare-01/` tree and `nixosConfigurations.nagare-01`) remains a one-host story; running
two *cloud* VMs concurrently still implies per-host config, which this initiative does not automate.
**Migrating Pulumi to a remote/GCS backend** — EP-90 keeps the file backend, only relocating it per
context (the more Pulumi-idiomatic stack-per-shared-backend model is noted as a follow-on). **Changing
*what* nagare deploys** — the DSL, the Knative shape, the database engines, and the cloud/local runtime
behavior are unchanged; this initiative changes only *how the target is selected and resolved*. Test
fixtures and golden files that pin the `tan-nb-exp` worked example are intentional and stay (they assert
the default-reproduces-tan-nb-exp guarantee); they are not "hardcodes to fix".


## Decomposition Strategy

The initiative was decomposed by **the layer at which the target is resolved or consumed**, because each
layer has a distinct toolchain and an independently verifiable behavior, and they share exactly one new
contract — the context model — which one keystone plan owns. Research (recorded in the Decision Log)
found the resolution surface splits cleanly into: the resolver/store (Haskell), the CLI selection
surface (Haskell/optparse), the shell+direnv consumers and the guardrail (bash), the Pulumi state/config
(TypeScript + `nagarectl init`), the applied manifests and NixOS host (YAML/Nix), and the docs. Six
child plans result, inside the recommended two-to-seven range, grouped into four implementation waves.

The keystone is **EP-87**, which defines the **context contract**: the context model (the existing
`TargetProfile` fields plus `mode`, `localObjectStore`, and the Pulumi-state location), the store layout
(a user-level directory of named context files in the same flat `export VAR=value` format the profiles
already use, so bash can read it without a YAML parser), the `current-context` pointer, and the
resolution precedence — `--context`/`NAGARE_CONTEXT` > current-context pointer > in-repo
`nagare.target.env`/`nagare.local.env` (back-compat) > built-in default — with per-field environment
overrides preserved (`env > context > default`). It reworks `Nagare.Target.resolveTargetProfile` to be
context-aware while keeping its env-override semantics, and folds `mode` into the context (subsuming
MasterPlan 16's `NAGARE_MODE` switch). Nothing else can be built until the contract exists, so EP-87
comes first and is deliberately the broadest.

**EP-88** and **EP-89** are the two consumer surfaces and run in parallel after EP-87. EP-88 is the
Haskell CLI: the `nagarectl context` command group (`list`/`current`/`use`/`show`/`create`/`delete`),
the global `--context` flag and `NAGARE_CONTEXT` env wired into every command's target resolution, and
`nagarectl init` writing a *context* (not a bare `nagare.target.env`). EP-89 is the shell side: making
`scripts/lib/target.sh` and `.envrc` resolve the active context from the same store (dependency-free
bash), so the justfile and scripts honor `NAGARE_CONTEXT`, and reworking the fail-closed guardrail
`_require_target_project` to compare against the active context's project (replacing MasterPlan 16's
local short-circuit with a "mode == local" branch). They are disjoint (Haskell vs bash) and both consume
EP-87's contract.

**EP-90** and **EP-91** are the two "de-hardcoding" plans and run in parallel after EP-87. EP-90 maps
each context to its own Pulumi state — relocating the file backend per context and replacing the tracked,
`tan-nb-exp`-pinned `Pulumi.dev.yaml` with a per-context config projection regenerated by
`nagarectl init`/`context use` (it soft-depends on EP-88 because `init` is where the projection is
written). EP-91 templates every manifest/Nix value still baked to `tan-nb-exp`/the cloud registry — the
DNS-01 issuer project, the auth-plane + `nagared` Service image refs, and the NixOS `registries.nix`
host — so they render from the active context at apply time, mirroring how `cluster-bootstrap` already
patches `config-domain`/`registriesSkippingTagResolving` dynamically (it soft-depends on EP-89 because
the bootstrap recipes resolve the context through the shell layer). The two touch disjoint files.

**EP-92** is the docs-and-migration layer: a `docs/user/contexts.md` runbook, the reconciliation of
`CLAUDE.md` (the isolation policy re-expressed over the active context), `getting-started.md`,
`onboarding-bring-your-own-project.md`, and `local-development.md`, and a documented migration from the
two profile files to contexts. It soft-depends on all four behavioral plans and is finalized last.

A central design decision shaping the boundaries (see Decision Log): **contexts are a backward-compatible
generalization, not a rewrite.** The flat `export VAR=value` format is retained (so the existing bash
`.envrc`/`target.sh` keep working and need no parser, and an in-repo profile is still honored), the
`TargetProfile` record is extended rather than replaced, and the historic defaults remain — so "do
nothing" reproduces today's single-target, `tan-nb-exp` behavior at every layer. This was chosen over a
clean-slate YAML kubeconfig because the dual bash/Haskell consumer split makes a parser-free flat format
far cheaper, and because preserving the MasterPlan 12/16 behavior verbatim de-risks the migration.

Alternatives considered and rejected. **One mega-plan ("add contexts")**: rejected — the work spans
Haskell resolver internals, optparse command wiring, bash/direnv, a TypeScript Pulumi program, YAML/Nix
manifests, and docs; it could not be verified incrementally. **Splitting the store format from the
resolver**: rejected — the format and the resolver are one small contract with a single first consumer;
a separate plan boundary would add coordination cost with no parallelism gain, so the format is EP-87's
first milestone. **A separate plan per hardcode site**: rejected — the manifest/Nix hardcodes (EP-91)
share one mechanism (template-from-active-context-at-apply-time) and one verification (a non-`tan-nb-exp`
context renders clean), so splitting them would separate one change from its own test; the Pulumi
hardcodes are different in kind (state/stack layout, not apply-time templating) and stay in EP-90.
**Folding the guardrail rework into EP-87**: rejected — the guardrail lives in bash (`target.sh`) with
the other shell consumers, so it belongs with EP-89, not the Haskell resolver. **kubeconfig-style
normalized contexts**: rejected for v1 as over-engineering (see Scope); flat bundles ship first.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 87 | Target context model, store, and resolver for nagarectl | docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md | None | None | Complete |
| 88 | nagarectl context command group and --context selection | docs/plans/88-nagarectl-context-command-group-and-context-selection.md | EP-87 | None | Not Started |
| 89 | Shell and direnv context resolution and the context-aware guardrail | docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md | EP-87 | None | Not Started |
| 90 | Per-context Pulumi state and config projection | docs/plans/90-per-context-pulumi-state-and-config-projection.md | EP-87 | EP-88 | Not Started |
| 91 | De-hardcode cluster manifests and NixOS registry from the active context | docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md | EP-87 | EP-89 | Not Started |
| 92 | Context documentation and migration from target and local profiles | docs/plans/92-context-documentation-and-migration-from-target-and-local-profiles.md | None | EP-87, EP-88, EP-89, EP-90, EP-91 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-87, EP-89).

Implementation waves (phases):

- **Wave 1 — Context contract:** EP-87. The context model, the user-level store layout + `current-context`
  pointer, the resolution precedence, and the context-aware `Nagare.Target` resolver (folding in `mode`).
  Nothing else can resolve a context until this exists.
- **Wave 2 — Consumer surfaces (parallel):** EP-88 (the `nagarectl context` command group + `--context`
  selection + `init` writing a context) and EP-89 (shell/direnv resolution + the context-aware guardrail).
  Disjoint toolchains (Haskell vs bash); both consume EP-87.
- **Wave 3 — De-hardcoding (parallel):** EP-90 (per-context Pulumi state/stack + config projection
  replacing the pinned `Pulumi.dev.yaml`) and EP-91 (template the DNS-01 issuer project, auth/`nagared`
  image refs, and NixOS registry host from the active context). Disjoint files.
- **Wave 4 — Docs + migration:** EP-92. The `contexts.md` runbook, doc reconciliation, and the migration
  path from `nagare.target.env`/`nagare.local.env` to contexts. Finalized after the behavioral plans.


## Dependency Graph

EP-87 (context model + store + resolver) has no dependencies. It is the foundation: it defines the
context model, the store layout and `current-context` pointer (Integration Point 1), the
`--context`/`NAGARE_CONTEXT`/pointer/in-repo precedence (Integration Point 2), and the context-aware
`Nagare.Target` resolver. Every other plan needs the contract it fixes.

EP-88 (CLI) and EP-89 (shell + guardrail) each **hard-depend on EP-87** because they are the two
consumers of the resolver and the store. EP-88 adds the `nagarectl context` commands and the `--context`
flag — both call EP-87's resolver and read/write EP-87's store. EP-89 makes bash read the same store and
reworks the guardrail (Integration Point 4) over EP-87's resolved context. They are independent of each
other (Haskell vs bash, disjoint files) and run in parallel.

EP-90 (Pulumi) **hard-depends on EP-87** and **soft-depends on EP-88**. The hard dependency is the
context model: EP-90 derives each context's Pulumi state location and config projection (Integration
Point 5) from the context EP-87 defines. The soft dependency is on EP-88's `nagarectl init`, which is the
natural place to *write* the per-context Pulumi config — EP-90 can land its backend-relocation and
projection logic against EP-87 alone, but the end-to-end "`init` seeds a context's stack" story is best
demonstrated once EP-88 exists.

EP-91 (de-hardcode manifests + NixOS) **hard-depends on EP-87** and **soft-depends on EP-89**. The hard
dependency is the resolved context whose values (project, registry prefix, base domain) get templated
into the manifests at apply time (Integration Point 6). The soft dependency is on EP-89 because the
`cluster-bootstrap` (and related) recipes resolve the active context through the shell layer EP-89
provides; EP-91's rendering can be unit-verified against EP-87, but the live `just cluster-bootstrap`
path reads the context via EP-89.

EP-92 (docs + migration) **soft-depends on all five** because it documents and migrates their delivered
behavior. Its prose can be drafted from Wave 1 onward and is finalized after EP-91/EP-90 so the runbook
matches what shipped. It has no hard dependency — docs can be written against the contract even before
the consumers land — but it is sequenced last.

Parallelism: after EP-87, EP-88 and EP-89 run in parallel (Wave 2); then EP-90 and EP-91 run in parallel
(Wave 3). EP-92 begins once EP-87 exists and is finalized after Wave 3.


## Integration Points

**1. The context model and store layout (defined by EP-87; consumed by EP-88, EP-89, EP-90, EP-91,
EP-92).** EP-87 is the single source of truth for what a context is and where it lives. A **context** is
the existing `Nagare.Target.TargetProfile` bundle (`tpProject`, `tpRegion`, `tpZone`, `tpRegistryHost`,
`tpArtifactRegistryId`, `tpImageBucket`, `tpBackupBucket`, `tpBaseDomain`, `tpInstanceName`,
`tpTargetPlatform`, `tpMode`, `tpLocalObjectStore`) plus its Pulumi-state location (Integration Point 5).
The **store** is a user-level directory — `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`
— each file in the same flat `export VAR=value` schema as today's `nagare.target.env` (so bash sources it
directly, no YAML parser), plus a `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` file naming
the default. EP-87 owns this layout and the exact paths; a later plan needing a new context field adds it
to the `TargetProfile` record, the `.env` schema, and this section, and notifies the consumers.

**2. The active-context selection mechanism (defined by EP-87; the `--context` flag added by EP-88;
consumed by EP-88, EP-89).** Precedence, highest first: an explicit `--context <name>` (EP-88's global
flag) or the `NAGARE_CONTEXT` environment variable > the `current-context` pointer > an in-repo
`nagare.target.env`/`nagare.local.env` (back-compat with MasterPlan 12/16) > the built-in `tan-nb-exp`
default. Independently, per-field environment variables still override the chosen context's values
(`env > context > default`), preserving today's "environment wins" semantics. EP-87 defines the
precedence and the `NAGARE_CONTEXT` semantics; EP-88 adds the `--context` flag that feeds the same
resolver; EP-89 implements the identical precedence in bash. No consumer re-derives this order
independently. **Flag-name reconciliation:** `deploy`/`site`/`app deploy` already use `--context`/`-c` for
the *build-context directory* (Docker-style); to give the global target selector the kubectl-faithful name
`--context`, EP-88 **renames that pre-existing flag to `--build-context`** (keeping its `-c` short form).
This is a deliberate breaking change to `nagarectl deploy --context <dir>`; EP-92's docs and any justfile
recipes/examples using `deploy --context`/`-c` for a build dir are updated to `--build-context`.

**3. The bash resolution contract (defined by EP-89; consumed by the justfile, scripts, EP-90, EP-91).**
EP-89 makes `scripts/lib/target.sh` and `.envrc` resolve the active context from the EP-87 store using the
Integration Point 2 precedence, then export the contract variables (`CLOUDSDK_*`, `NAGARE_*`) exactly as
today — so the justfile recipes, `scripts/*.sh`, and EP-91's bootstrap rendering consume the active
context with no change to how they read the environment. This keeps a single resolution behavior across
Haskell and bash without a shared parser: both read the same flat files with the same precedence. EP-89
**additionally exports two derived variables the de-hardcoding plans consume**, so there is one canonical
producer: (a) `NAGARE_CONTEXT` re-exported as the **resolved active-context name** — always populated
(`"default"` when neither a context nor an in-repo profile is selected). Because `NAGARE_CONTEXT` is also
the top-precedence *selector*, EP-89 makes re-entry safe with a companion `NAGARE_RESOLVED_CONTEXT` marker
(recording that the exported value came from resolution, not an explicit selection), so a later
`nagarectl context use` / current-context change is not defeated by a stale exported value; a readable
mirror `NAGARE_ACTIVE_CONTEXT` is also exported. EP-90 keys the per-context Pulumi backend directory and
stack name off `NAGARE_CONTEXT` (Integration Point 5). And (b) `NAGARE_REGISTRY_PREFIX`, the mode-aware
image-name prefix (cloud: `<registryHost>/<project>/<artifactRegistryId>`; local: the flat local-registry
prefix), which EP-91 substitutes into the auth-plane/`nagared` Service image refs (Integration Point 6).
No consumer recomputes these independently; EP-89 (bash) and EP-90 (Pulumi) agree on `NAGARE_CONTEXT` as
the resolved-name key.

**4. The context-aware fail-closed guardrail (defined by EP-89; consumed by all scripts).** EP-89 reworks
`scripts/lib/target.sh`'s `_require_target_project` to assert against the **active context's** project: in
a `mode=cloud` context it fails closed unless gcloud's active project equals the context project (today's
behavior, now context-driven); in a `mode=local` context it steps aside after asserting the loopback
invariants — replacing MasterPlan 16's `NAGARE_MODE=local` special-case with a context-`mode` branch. The
cloud branch must never become anything but fail-closed; the only change is that the compared project now
comes from the active context.

**5. Per-context Pulumi state and config projection (defined by EP-90; relates to EP-88, EP-91).** Today
Pulumi state is a single in-repo file backend (`file://./infra/pulumi/.pulumi-state`, stack `dev`) and the
tracked `infra/pulumi/Pulumi.dev.yaml` pins `tan-nb-exp`/`us-west1`/`tan-nb-exp-nagare-images` plus a
project-specific `nagareImageSelfLink`. EP-90 segregates state per context by **mapping each context to
its own Pulumi stack** (stack name = context name, so `Pulumi.<context>.yaml` config files coexist in the
project dir and switching a context never overwrites another's config) **backed by a per-context file
backend directory** (e.g. `file://${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state`, with a
matching per-context `PULUMI_HOME`) for hard state-tree isolation. `nagarectl context use` repoints
`PULUMI_BACKEND_URL`/`PULUMI_HOME` and selects the stack; each context's config is a **per-context
projection** that `nagarectl init`/`nagarectl context use` regenerate from the active context — so the
tracked `Pulumi.dev.yaml` (pinned to `tan-nb-exp`) is removed and its values stop being a tracked default.
EP-88's `init` writes this projection; EP-91 does not touch Pulumi. EP-90 owns the stack-naming,
backend-path, and projection scheme. (The alternative — one shared backend keyed only by stack, or keeping
a single stack `dev` and relocating just the backend — was rejected: stack-per-context plus a per-context
backend gives both a legible `pulumi stack ls` and hard filesystem isolation. See Decision Log.)

**6. The manifest templating seam (defined by EP-91; relates to EP-89).** EP-91 enumerates and removes
every hardcode still *applied to a real target*: `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`
(`project: tan-nb-exp`), the Service image refs in `cluster/bootstrap/{nagare-access,en,shomei,nagared}/
service.yaml` (`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<svc>:…`), and `nixos/hosts/nagare-01/
registries.nix` (`registryHost = "us-west1-docker.pkg.dev"`). Each is rendered from the active context at
apply time — the issuer project from `tpProject`, the image refs from `registryPrefix`, the NixOS host
from `tpRegistryHost` — mirroring how `cluster-bootstrap` already patches `config-domain` (from
`baseDomain`) and `registriesSkippingTagResolving` (from `NAGARE_REGISTRY_HOST`). The bootstrap recipes
read the active context through EP-89's bash layer (Integration Point 3). Test/golden fixtures pinning
`tan-nb-exp` are intentional and are **not** in this seam. EP-91 owns the list; if a later change adds a
new applied hardcode, it is added here and to EP-91.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-87: Context model defined (`TargetProfile` + Pulumi-state location), the user-level store layout (`~/.config/nagare/contexts/<name>.env` + `current-context`), and the resolution precedence documented and unit-tested.
- [x] EP-87: `Nagare.Target` resolves the active context with `env > context > default` field precedence and `--context`/`NAGARE_CONTEXT` > pointer > in-repo profile > default selection; `mode` folded into the context; in-repo `nagare.target.env`/`nagare.local.env` still reproduce today's behavior.
- [ ] EP-88: `nagarectl context list|current|use|show|create|delete` implemented against the EP-87 store; global `--context` flag wired into every command's target resolution.
- [ ] EP-88: `nagarectl init` writes a named context (not a bare `nagare.target.env`); `nagarectl --context <name> deploy` deploys to that target with no `cd` and no file edit.
- [ ] EP-89: `scripts/lib/target.sh` and `.envrc` resolve the active context from the EP-87 store with the same precedence; `NAGARE_CONTEXT=<name> just <recipe>` targets that context; justfile/scripts unchanged in how they read the environment.
- [ ] EP-89: `_require_target_project` asserts against the active context's project (fail-closed in `mode=cloud`, steps aside in `mode=local`), replacing the `NAGARE_MODE=local` special-case.
- [ ] EP-90: each context owns its Pulumi state (per-context file backend, stack `dev`); the tracked `Pulumi.dev.yaml` pinned to `tan-nb-exp` is replaced by a per-context projection regenerated by `nagarectl init`/`context use`.
- [ ] EP-91: the DNS-01 issuer project, the auth-plane + `nagared` Service image refs, and the NixOS `registries.nix` host all render from the active context; a non-`tan-nb-exp` context renders clean (no `tan-nb-exp`/`us-west1-docker.pkg.dev` leaks); cloud and local behavior for `tan-nb-exp`/local contexts unchanged.
- [ ] EP-92: `docs/user/contexts.md` runbook written; `CLAUDE.md`/getting-started/onboarding/local-development reconciled; the `nagare.target.env`/`nagare.local.env` → context migration documented.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- **`--context` already means something on `deploy` (EP-88 → affects EP-92, justfile).** `deploy`/`site`/
  `app deploy` bind `--context`/`-c` to the *build-context directory*. Making the global target selector
  `--context` (kubectl-faithful) requires renaming that pre-existing flag to `--build-context` — a
  deliberate breaking change the owner approved (2026-06-30). Recorded in Integration Point 2; EP-92 docs
  and any recipes/examples using `deploy --context <dir>` must be updated. Date: 2026-06-30.
- **`TargetProfile` already carries all 12 context fields; but its renderer does not (EP-87 → affects
  EP-88).** MasterPlan 16 already added `tpMode`/`tpLocalObjectStore`, so "extend the record" is a no-op —
  *except* the existing `Nagare.Init.renderTargetEnv` does **not** emit `NAGARE_MODE`/
  `NAGARE_LOCAL_OBJECT_STORE` lines. EP-87's context-file renderer must emit them so a `mode=local` context
  round-trips through the store; EP-88's `context create`/`init` reuse that extended renderer. EP-87
  implemented the renderer extension and added cloud/local assertions in `Nagare.Init` tests. Date:
  2026-06-30; updated 2026-07-01.
- **The store is user-level, so tests must isolate `XDG_CONFIG_HOME` (EP-87 → affects EP-89).** Because the
  context store lives under `~/.config/nagare/`, a real `current-context` on the dev machine could perturb
  the "defaults reproduce tan-nb-exp" assertion; EP-87's tests pin `XDG_CONFIG_HOME` to a temp dir and
  clear `NAGARE_CONTEXT`. EP-89's shell tests must apply the identical isolation. Also decided: a
  named-but-missing context (explicit/`NAGARE_CONTEXT`/stale pointer) is a **hard error**, not a silent
  fall-through to `tan-nb-exp`. Date: 2026-06-30.
- **The cloud auth-plane has no installer — only a manual `kubectl apply` sequence in `docs/user/access.md`
  (EP-91).** The local installer (`cluster/bootstrap/local-auth/install.sh`) already de-hardcodes image
  refs via `kubectl set image`, but the cloud path tells the operator to hand-edit them. EP-91 therefore
  adds a cloud render seam (a `cluster/bootstrap/auth-install.sh`) that substitutes `NAGARE_REGISTRY_PREFIX`
  at apply time, and ensures no installer ever applies an unresolved `${…}` placeholder. Date: 2026-06-30.
- **NixOS build purity forces a generated, git-ignored per-operator artifact (EP-91 → aligns with EP-90).**
  The flake cannot read the active context at build time, so `nixos/hosts/nagare-01/registries.nix`'s
  registry host becomes a generated, git-ignored `registry-host.nix` imported with a default — the same
  "generated, git-ignored, per-operator" shape EP-90 uses for `Pulumi.<context>.yaml`. EP-92 documents both
  consistently. The single-host boundary stands: this parameterizes one host, not N. Date: 2026-06-30.

- **Back-compat correction: the pure-default case must keep exporting the `tan-nb-exp` defaults (EP-89
  reconciliation).** EP-89's draft proposed leaving `CLOUDSDK_CORE_PROJECT` *unset* in the no-context/
  no-profile case. That is NOT "reproduce today's behavior": today `.envrc` does
  `export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"`, so a bare shell pins `tan-nb-exp`
  and the guardrail *passes* against it; leaving it unset would make the bare guardrail fail-closed against
  whatever `gcloud config` holds — a regression. **Resolution (authoritative):** when no context and no
  in-repo profile are selected, `.envrc`/`target.sh` export the historic `tan-nb-exp`/`us-west1`/
  `us-west1-a` defaults exactly as today. EP-89's plan is to be adjusted to this before implementation.
  Separately, EP-89's `NAGARE_RESOLVED_CONTEXT` marker (to stop a direnv shell's inherited
  `CLOUDSDK_CORE_PROJECT` from defeating `NAGARE_CONTEXT=labs just …`) is accepted, with its one lossy edge
  case (a different-context selection *plus* a manual per-field override in the same command drops the
  override) documented; EP-87's once-per-process Haskell resolver does not hit this, so the two resolvers
  agree everywhere else. Date: 2026-06-30.

- **EP-87 exposed a test-harness global-state assumption that affects later context work.** The
  `nagarectl-test` suite mutates process-global environment variables in multiple groups, and EP-87's
  in-repo profile back-compat test also temporarily changes the process working directory. Tasty's
  default parallelism made the first full run fail nondeterministically (`NAGARE_MODE` was cleared during
  another test, and `AppDeploySpec` looked for fixtures from a temporary CWD). EP-87 therefore sets the
  top-level test tree to `localOption (NumThreads 1)`. Future EP-88/EP-89 tests that mutate
  `NAGARE_CONTEXT`, `XDG_CONFIG_HOME`, or CWD can rely on the same serial harness but must still
  save/restore state within each case. Full validation after the renderer extension: `cabal test` passed
  340 tests. Date: 2026-07-01.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: nagare will support **first-class, named target contexts** (a `kubectl`/kubeconfig model) —
  many named target bundles in a user-level store, a current-context pointer, and `--context`/
  `NAGARE_CONTEXT` selection — so an operator can run multiple nagare instances (different GCP projects /
  domains / use cases) from one checkout without per-directory profiles or per-instance clones. This
  MasterPlan authorizes that capability and decomposes it.
  Rationale: The owner is running multiple nagare instances for different use cases (e.g.
  `labs.topagentnetwork.net` on a non-`tan-nb-exp` project) and wants something more robust than the
  current `$PWD`-bound single-profile model — explicitly "like kubernetes contexts where I can define a
  default context and multiple contexts, and nagarectl uses the context for those values."
  Date: 2026-06-30

- Decision: contexts are a **backward-compatible generalization**, not a rewrite — retain the flat
  `export VAR=value` profile format (so bash `.envrc`/`target.sh` need no YAML parser and an in-repo
  `nagare.target.env` is still honored), extend the `TargetProfile` record rather than replace it, fold
  MasterPlan 16's `NAGARE_MODE`/`nagare.local.env` into a context with `mode=local`, and keep the historic
  `tan-nb-exp` defaults so "do nothing" reproduces today's behavior.
  Rationale: The dual bash/Haskell consumer split makes a parser-free flat format far cheaper than a YAML
  kubeconfig, and preserving the MasterPlan 12/16 behavior verbatim de-risks the migration. This
  supersedes MasterPlan 12's single-profile model and unifies MasterPlan 16's mode switch.
  Date: 2026-06-30

- Decision: as part of this initiative, **every hardcode still applied to a real cluster/project is
  parameterized from the active context** — the cert-manager DNS-01 issuer project, the auth-plane +
  `nagared` Service image refs, the tracked `Pulumi.dev.yaml`, and the NixOS containerd registry host —
  while test/golden fixtures that pin the `tan-nb-exp` worked example are intentionally left (they assert
  the default-reproduces-tan-nb-exp guarantee).
  Rationale: The owner explicitly asked to "fix any place we hardcode values." A second instance must
  need zero tracked-file edits; the only places that previously forced an edit were these applied
  manifests and the Pulumi config projection (EP-90/EP-91). Defaults in `Nagare.Target`/`target.sh` stay
  as documented fallbacks; fixtures stay as the back-compat assertion.
  Date: 2026-06-30

- Decision: decompose into six child plans in four waves — EP-87 (context model/store/resolver), EP-88
  (CLI command group + `--context` + `init`), EP-89 (shell/direnv + guardrail), EP-90 (per-context Pulumi
  state + projection), EP-91 (de-hardcode manifests + NixOS), EP-92 (docs + migration).
  Rationale: Boundaries follow the layer at which the target is resolved/consumed, each ending in an
  independently verifiable behavior. EP-88/EP-89 (Haskell vs bash) and EP-90/EP-91 (Pulumi vs
  manifests/Nix) are disjoint pairs that run in parallel. See Decomposition Strategy for rejected
  alternatives (mega-plan; splitting the store format from the resolver; a plan per hardcode site;
  folding the guardrail into EP-87; kubeconfig-style normalization).
  Date: 2026-06-30

- Decision: **scope boundaries** — flat context bundles (not kubeconfig-style cluster/credentials/context
  normalization) in v1; the Pulumi file backend is relocated per context (not migrated to a remote/GCS
  backend); the NixOS *host registry* follows the context but generating N distinct NixOS *hosts* for N
  concurrent cloud VMs is not automated.
  Rationale: Each excluded item is a larger, separable concern that the context contract does not require;
  shipping flat bundles + per-context file state + a parameterized single host delivers the multi-instance
  capability the owner asked for, and the heavier variants can follow once the contract exists.
  Date: 2026-06-30

- Decision: **Pulumi state is segregated Option B — a context maps to a Pulumi stack (stack name = context)
  backed by a per-context file backend directory** (`file://${XDG_STATE_HOME:-$HOME/.local/state}/nagare/
  <context>/state`, matching per-context `PULUMI_HOME`). `nagarectl context use` repoints
  `PULUMI_BACKEND_URL`/`PULUMI_HOME` and selects the stack; `Pulumi.<context>.yaml` config files coexist
  (git-ignored, projected from the context) and the tracked `Pulumi.dev.yaml` is removed.
  Rationale: Owner chose this over the relocate-backend-only/keep-stack-`dev` alternative (which would have
  to overwrite the singular `Pulumi.dev.yaml` on every switch). Stack-per-context makes `pulumi stack ls`
  read as the context list (the kubeconfig analogy) and the per-context backend adds hard filesystem
  isolation. The shared-remote-backend variant is a follow-on. Supersedes EP-90's initial draft, which is
  being realigned. Date: 2026-06-30

- Decision: the global target selector is **`--context <name>`** (matching kubectl), and the pre-existing
  build-context-directory flag on `deploy`/`site`/`app deploy` is **renamed to `--build-context`** (keeping
  `-c`).
  Rationale: The owner wants the kubectl model, which uses `--context`; the collision with the existing
  build-dir flag is resolved by renaming the latter (a clearer name anyway). Owner approved the breaking
  change (2026-06-30). EP-88 owns the rename; EP-92 updates docs/examples. Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
