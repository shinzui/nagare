---
id: 2
slug: type-safe-haskell-deployment-dsl-for-nagarectl
title: "Type-Safe Haskell Deployment DSL for nagarectl"
kind: master-plan
created_at: 2026-06-03T03:43:59Z
intention: "intention_01kt5s3j2zedh8ew1yp9qdp6c7"
---


# Type-Safe Haskell Deployment DSL for nagarectl

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan coordinates the design and construction of a **type-safe configuration language for
deploying applications with the `nagarectl` command-line tool**, replacing the untyped
`nagare.yaml` file that the existing plan EP-6
(`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`) defines. Nagare is a single-node personal
Platform-as-a-Service: one Google Cloud Platform virtual machine running the small Kubernetes
distribution k3s with **Knative Serving** installed (Knative Serving turns a single container
image into an auto-scaling, scale-to-zero web service it calls a *Knative Service*). Today an app
is described by a short YAML file, `nagare.yaml`, and `nagarectl deploy` renders that YAML into a
Knative `Service` manifest and applies it. YAML has no types: a misspelled field, a number where
a string belongs, an environment variable that is *both* a literal value and a secret reference,
a `max` scale below `min`, or a name that is not DNS-safe are all silently accepted by the parser
and only fail — if at all — when the cluster rejects the manifest minutes later. This initiative
replaces that YAML contract with a configuration surface in which **those mistakes cannot be
written down at all**, and in which common configuration (a "web service" shape, a shared
environment overlay, a team's standard resource limits) can be factored out and reused with the
compiler or type-checker guaranteeing the result is still valid.

The work is **exploratory by design**. The user asked us to *evaluate how to create* such a DSL,
so the initiative leads with a research-and-prototype plan that builds working toy versions of
three candidate substrates and decides between them with evidence, rather than committing to one
on day one. The three candidates are: (1) a **native Haskell embedded DSL** where each app ships a
real Haskell source file that `nagarectl` compiles and runs to emit a typed deployment value (the
"configuration as a program" model used by xmonad, Hakyll, and Shake); (2) the same native eDSL
but evaluated at runtime through an **embedded Haskell interpreter** (the `hint` package or the GHC
API) so no per-app compilation step is needed; and (3) **Dhall**, a typed, non-Turing-complete
functional configuration language with first-class Haskell marshalling (`FromDhall`) and native
imports and functions for reuse — a language this very repository already uses (`mori.dhall`,
`.seihou/config.dhall`) and that the user maintains a project around (`shinzui/dhall-grafana`).

Two scope decisions were made with the user up front (see Decision Log) and bind every child plan:
the new DSL **replaces `nagare.yaml` entirely** (a hard cutover, not a parallel option), and the
type-safety target is **maximal** — the design pushes invariants into the type system so that
illegal configurations fail to compile or type-check rather than merely being validated at parse
time. Both decisions raise the stakes of the substrate choice, which is exactly why the spike comes
first.


## Vision & Scope

After this initiative is complete, an app author describes a deployment in a typed configuration
file — not YAML — and the machinery that turns that description into a running Knative Service
guarantees, before anything touches the cluster, that the description is internally consistent.
Concretely, when the initiative is done:

An app repository no longer contains a `nagare.yaml`. Instead it contains a typed config in the
substrate the spike selected — for the native-eDSL outcome, a `nagare/Config.hs` (or equivalent)
importing a `nagare-dsl` library and binding a top-level `deployment :: Deployment` value; for the
Dhall outcome, a `nagare.dhall` importing a published `Nagare` package and producing a record the
tool marshals into the same `Deployment` type. The author cannot express a service whose name is
not DNS-safe, an environment variable that is simultaneously a literal and a secret reference, a
scale whose maximum is below its minimum, a CPU or memory quantity that is not valid Kubernetes
quantity syntax, or a reference to a field that does not exist — each of these is a type error or a
construction error with a precise, human-readable message, surfaced the moment the config is
written or loaded, never as an opaque cluster rejection.

The author can factor shared configuration into reusable, type-checked building blocks: a
`webService` preset that fixes the common shape of an HTTP app, a `production`/`development`
overlay that adjusts scale and resources, a team-wide set of standard secrets — and compose them
so that two different apps share one definition without copy-paste, with the type system or
type-checker proving the composed result is still a valid `Deployment`. Running `nagarectl deploy`
loads that typed config, evaluates it to the canonical `Deployment` value, renders the exact same
Knative `Service` (and optional `DomainMapping`) manifests the YAML path used to produce, applies
them, waits for readiness, and prints the live URL — the user-visible deploy experience is
unchanged except that whole classes of misconfiguration are now impossible.

In scope: the substrate evaluation and decision; the canonical typed deployment model with
maximal-safety constructors; the renderer from that model to Knative manifests (byte-for-byte
compatible with the cluster contract EP-4 and the existing EP-6 golden output established); the
config surface and loading mechanism for the chosen substrate; a reusable-presets library with a
demonstrated composition across two example apps; and the integration into `nagarectl` together
with the complete removal of the `nagare.yaml` parsing path and migration of the in-repo example
app(s).

Explicitly out of scope: changing what gets deployed (this initiative changes *how a deployment is
described*, not the Knative/Kourier/cert-manager platform underneath, which the bootstrap
MasterPlan owns); supporting non-Knative workloads (CronJobs, StatefulSets, raw Deployments) —
the model targets exactly the Knative `Service` + `DomainMapping` surface EP-6 targets; a graphical
or web configuration editor; and multi-cluster or multi-environment *deployment orchestration*
beyond letting a config express environment overlays (the tool still deploys to the one Nagare
cluster). Backwards compatibility with `nagare.yaml` is explicitly a non-goal: per the user's
decision the YAML path is removed, not preserved.


## Decomposition Strategy

The initiative was decomposed by **functional concern and by the single hard unknown that gates
everything else**. That unknown is the substrate: a native Haskell eDSL, an interpreted eDSL, and
Dhall lead to materially different loading mechanisms, build-time stories, and reuse ergonomics, so
the first plan is a dedicated evaluation spike that resolves it with running prototypes before any
production code is committed. This mirrors the ExecPlan specification's encouragement to use
prototyping milestones to de-risk significant unknowns, elevated here to a whole plan because the
decision changes the shape of three downstream plans.

After the spike, the work splits along a clean seam that holds regardless of which substrate wins:
**the canonical typed `Deployment` value**. Every candidate substrate ultimately produces a value
of one Haskell type — the native eDSL produces it directly, the interpreter evaluates source to it,
and Dhall marshals into it through `FromDhall`. That observation lets the substrate-independent
core (the types, the maximal-safety smart constructors, and the renderer to Knative manifests) be
one self-contained plan that does not depend on the spike's verdict, while the substrate-specific
front-end (how a config file becomes a `Deployment`) is a separate plan that does. Reuse — a
headline user requirement, stated twice ("easy to reuse configs") — is given its own plan because
it is an independently demonstrable behavior (two apps sharing one preset library, with property
tests that composition preserves validity) and because its idioms differ by substrate. Integration
and the YAML cutover is the final plan because it can only be done once the core renderer and the
loader both exist, and because removing the YAML path safely requires migrating the example app and
retiring EP-6's `Config`/`Render` modules in one coordinated step.

This yields five child plans grouped into three implementation waves (below). Five sits comfortably
in the recommended two-to-seven range. The boundaries were chosen to maximize independent
verifiability: the spike ends in a recorded decision plus three runnable prototypes that each emit
identical Knative YAML for one shared example; the core plan ends in a library whose golden test
renders the canonical example byte-for-byte and whose *negative* type tests prove illegal configs
fail to compile; the surface plan ends in `loadDeployment :: FilePath -> IO (Either LoadError
Deployment)` succeeding on a real config file; the reuse plan ends in two example apps sharing one
preset library; and the integration plan ends in `nagarectl deploy` deploying from the typed config
with no `nagare.yaml` anywhere in the tree.

Alternatives considered and rejected. **Committing to one substrate without a spike**: rejected
because the user explicitly framed the request as an evaluation, the three substrates have very
different operational consequences (per-app compilation vs. a heavy interpreter dependency vs. a
second language), and one candidate (the interpreter) depends on a package — `hint` — that is *not*
in the local `mori` corpus, a feasibility risk that must be measured, not assumed. **Folding the
renderer into the core-types plan's parent and the reuse library into the surface plan** (a
three-plan shape): considered and rejected because it would bundle two independently verifiable
behaviors (illegal-states-unrepresentable typing vs. byte-exact rendering) and would bury the
reuse requirement, which the user emphasized, inside an implementation detail. **Keeping
`nagare.yaml` as a coexisting option** (so the DSL is additive): rejected by explicit user decision
to replace YAML entirely; coexistence would have added a permanent migration-shim surface and a
second contract to keep in sync. **Splitting the core types and the renderer into two plans**:
rejected because they live in the same `nagare-dsl` library, the renderer imports the core types
pervasively, and two plans modifying the same modules in lockstep is exactly the high-coupling
shape the decomposition principles say to merge.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 8 | Config substrate evaluation spike and decision | docs/plans/8-config-substrate-evaluation-spike-and-decision.md | None | EP-6 | Complete |
| 9 | Typed core deployment model and Knative renderer | docs/plans/9-typed-core-deployment-model-and-knative-renderer.md | None | EP-8, EP-6 | Complete |
| 10 | Config surface and loading for the chosen substrate | docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md | EP-8, EP-9 | None | Not Started |
| 11 | Reusable config presets and composition library | docs/plans/11-reusable-config-presets-and-composition-library.md | EP-10 | EP-9 | Not Started |
| 12 | nagarectl integration and full YAML cutover | docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md | EP-9, EP-10 | EP-11, EP-6 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference
other rows by their `EP-<#>` prefix, where the number is the child plan's `docs/plans/<#>` file
number (matching the repository's existing convention that EP-6 is `docs/plans/6-...`). EP-6 is the
existing `nagare.yaml` deploy CLI plan from the bootstrap MasterPlan
(`docs/masterplans/1-bootstrap-nagare-personal-paas.md`); this initiative supersedes its YAML
contract — see Integration Point 4.

Implementation waves (phases):

- **Wave 1 — Decide the substrate:** EP-8. A pure research-and-prototype plan; nothing downstream
  commits production code until its Decision Log entry is written. EP-8 first pins **GHC 9.12** in
  the repository Nix flake (its M0 milestone, Integration Point 6) and builds every prototype with
  the house `GHC2024` standard, establishing the toolchain the later plans inherit. The core plan EP-9 may begin
  authoring/implementing in parallel because it is substrate-independent, but should not finalize
  its public constructor surface until EP-8's prototypes have stress-tested the ergonomics.
- **Wave 2 — Build the substrate-independent core and the substrate-specific surface:** EP-9 (the
  typed model + renderer) and then EP-10 (loading the chosen substrate into that model). EP-9 has no
  hard dependency and is the spine everything else imports; EP-10 hard-depends on both the decision
  (EP-8) and the target type (EP-9).
- **Wave 3 — Reuse and ship:** EP-11 (the preset/composition library, after a working surface
  exists) and EP-12 (wire into `nagarectl`, delete the YAML path, migrate the example). EP-12 can
  start once EP-9 and EP-10 are complete; EP-11 sharpens the reuse story EP-12 then showcases.


## Dependency Graph

EP-8 (substrate spike) has no dependencies. It soft-depends on EP-6 only as a *reference*: it reuses
EP-6's `nagare.yaml` schema (Integration Point 6 of the bootstrap MasterPlan) and EP-6's exact
rendered Knative `Service` YAML as the **fixed target** that all three prototypes must reproduce, so
that the comparison is apples-to-apples. EP-8 produces two artifacts the rest of the initiative
consumes: a written substrate decision (recorded in both this MasterPlan's Decision Log and EP-8's),
and three throwaway prototypes plus a scoring of them on type-safety, error-message quality, reuse
ergonomics, build/eval latency, and operational complexity. EP-8 also owns a toolchain prerequisite
(its **M0** milestone): it pins **GHC 9.12** in the repository Nix flake (Integration Point 6),
which every downstream Haskell plan inherits.

EP-9 (typed core model + renderer) has **no hard dependency** and can be authored and even
implemented in parallel with EP-8, because the canonical `Deployment` type and the rendering of that
type to Knative manifests do not depend on which surface syntax wins — all three surfaces target the
same type. It soft-depends on EP-8 because the spike's prototypes will surface ergonomic lessons
(which constructors are pleasant, which type-level tricks are worth their weight) that should inform
the final public API before it is frozen, and on EP-6 because the renderer must reproduce EP-6's
exact Knative output (the golden contract). EP-9 is the single most depended-upon plan: it defines
the `Deployment` type and the renderer that EP-10, EP-11, and EP-12 all build on (Integration
Point 1 and 2).

EP-10 (config surface and loading) **hard-depends on EP-8** (it implements whichever substrate the
spike chose — its entire content is conditional on that decision) and **hard-depends on EP-9** (it
must marshal a config file into EP-9's `Deployment` type; without that type there is nothing to load
into). It produces the loader `loadDeployment :: FilePath -> IO (Either LoadError Deployment)`
(Integration Point 3) that EP-12 calls.

EP-11 (reuse and presets) **hard-depends on EP-10**: reusable presets are written *in* the chosen
surface substrate, so the surface and its loader must exist first. It soft-depends on EP-9 because
presets are ultimately typed constructors over the core model. It produces a `nagare-presets`
library and a second example app proving composition, plus property tests that composing valid
presets yields a valid `Deployment` (Integration Point 1).

EP-12 (nagarectl integration + YAML cutover) **hard-depends on EP-9 and EP-10**: it wires the loader
(EP-10) and renderer (EP-9) into the `nagarectl deploy` command and then *deletes* the `nagare.yaml`
parsing path. It soft-depends on EP-11 (a richer reuse story makes a better end-to-end demo, but the
cutover does not require it) and on EP-6 (it modifies EP-6's `cli/nagarectl` package, removing
`Nagare.Config`'s YAML parser and `Nagare.Render`'s YAML renderer and rewiring `Main.hs`).

Parallelism: EP-8 and EP-9 can proceed concurrently (different concerns, no shared code), and a
single implementer should let EP-8's findings settle EP-9's public constructor names before freezing
them. After EP-8 and EP-9 are complete, EP-10 proceeds; EP-11 follows EP-10; EP-12 can begin as soon
as EP-9 and EP-10 are both complete and finalizes after EP-11 if the richer demo is wanted.


## Integration Points

**1. The canonical `Deployment` type and the maximal-safety constructors (defined by EP-9;
consumed by EP-10, EP-11, EP-12).** EP-9 is the single source of truth for what a Nagare deployment
*is*, as Haskell types, in a new library at `cli/nagare-dsl/` (a sibling of EP-6's
`cli/nagarectl/`). The canonical type is `Nagare.Dsl.Types.Deployment`, with field types that make
illegal states unrepresentable: a `ServiceName` newtype that can only be constructed from a
DNS-safe string (RFC 1123 label: lowercase alphanumerics and hyphens, not starting/ending with a
hyphen, length-bounded), an `EnvVar` modeled as a sum type `EnvLiteral Text | EnvSecretRef SecretName`
so that "value" and "secretRef" are mutually exclusive *by construction* (the YAML bug where both
appear becomes unrepresentable), a `Scale` smart constructor that rejects `max < min`, a `Quantity`
newtype validated against Kubernetes quantity syntax for CPU/memory, and a `Port` newtype bounded to
1–65535. The exact module layout, every constructor's name and signature, and the failure mode of
each (a total `Either`-returning smart constructor, a refined type, or a compile-time error) are
specified in EP-9 and reproduced in the consuming plans. EP-10 marshals into these constructors;
EP-11 builds presets as functions returning these types; EP-12 renders them. If EP-9 renames or
re-shapes a constructor, it updates this section and the consuming plans.

**2. The Knative manifest renderer and its golden contract (defined by EP-9; consumed by EP-12;
contract shared with EP-6).** EP-9 owns `Nagare.Dsl.Render.renderService :: Deployment -> Text ->
ByteString` (the `Text` is the resolved image tag) and `renderDomainMapping :: Deployment -> Maybe
ByteString`, producing the exact same Knative `serving.knative.dev/v1` `Service` and
`serving.knative.dev/v1beta1` `DomainMapping` YAML that EP-6's `Nagare.Render` produces. The
authoritative byte-for-byte target is the example rendering reproduced verbatim in EP-6
(`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`, "What the renderer must produce") and, once
EP-4's example lands, `cluster/examples/hello-knative-service/`. EP-9 ships a golden test asserting
this equality. The rendering rules that must be preserved exactly: env entries sorted by variable
name for determinism; autoscaling annotation *values* quoted as strings; sub-objects (`env`,
`resources`, the annotations block) omitted entirely when their source field is absent; `secretRef`
rendering `valueFrom.secretKeyRef` with `name` = the secret and `key` = the env var's own name.
EP-12 calls this renderer and removes EP-6's duplicate.

**3. The loader entry point (defined by EP-10; consumed by EP-12).** EP-10 owns the single function
`Nagare.Dsl.Load.loadDeployment :: FilePath -> IO (Either LoadError Deployment)` and the
`LoadError` type that enumerates the failure modes of the chosen substrate (for the native-eDSL
outcome: "config file not found", "compilation failed" with the GHC/interpreter diagnostic, "config
did not bind `deployment`"; for the Dhall outcome: "Dhall parse/type error", "marshalling error").
EP-12 calls exactly this function and maps a `Left` to a clear one-line CLI error and non-zero exit.
The signature is fixed here so EP-12 can be authored against it before EP-10 picks the internal
mechanism. If the spike's outcome forces a different signature (for example, a config that needs an
explicit search path), EP-10 updates this section and notifies EP-12.

**4. Supersession of EP-6's `nagare.yaml` contract (owned jointly by EP-12 and this MasterPlan;
affects the bootstrap MasterPlan's Integration Point 6 and EP-6).** This initiative **replaces** the
YAML contract that the bootstrap MasterPlan (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`)
documents as its Integration Point 6 and that EP-6 owns. Because EP-6 is currently *Not Started*,
nothing is yet built to remove; but EP-6's plan text, its `cli/nagarectl` skeleton (modules
`Nagare.Config` and `Nagare.Render`), and the example app's `nagare.yaml` are the surfaces EP-12
must reconcile. When EP-12 completes, it deletes the YAML parser/renderer, replaces the example
app's `nagare.yaml` with the chosen typed config, and records the cutover; at that point the
bootstrap MasterPlan's Integration Point 6 must be amended to point at this initiative. **Until the
user decides to *adopt* this initiative, the bootstrap MasterPlan and EP-6 are left unmodified** —
this MasterPlan documents the intended supersession but does not edit the other plan. The decision
to begin EP-12's cutover is the decision to adopt.

**5. The `nagare-dsl` library and the `nagarectl` package boundary (established by EP-9; consumed by
EP-10, EP-11, EP-12).** All new typed-model code lives in a new Cabal library package
`cli/nagare-dsl/` (package name `nagare-dsl`) so that the model, renderer, loader, and presets are
reusable independently of the CLI executable and testable offline. The `nagarectl` executable
(EP-6's `cli/nagarectl/`) depends on `nagare-dsl`. Whether the two packages share one
`cabal.project` at `cli/cabal.project` or each carry their own is decided in EP-9 and documented
there; EP-10, EP-11, and EP-12 must add their modules and dependencies within this package layout.
The local `mori` corpus supplies the Haskell dependencies (see Surprises for the inventory):
`dhall-haskell` (packages `dhall`, `dhall-json`/`dhall-yaml`) for the Dhall outcome at
`/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project`; `garnix-io/cradle` for shelling out;
`pcapriotti/optparse-applicative` for the CLI; `yaml`/`aeson` for rendering Knative YAML. There is
**no `hint` package in the corpus**, which directly shapes the feasibility of the interpreter
candidate in EP-8.

**6. The Haskell toolchain (GHC 9.12 via Nix) and house code standards (the flake pin is
established by EP-8 as a prerequisite milestone; the `common` stanza and `Nagare.Dsl.Prelude` are
established by EP-9; binding on EP-9, EP-10, EP-11, and EP-12).** Every Haskell artifact in this
initiative — the `nagare-dsl` library and the EP-12 changes to `nagarectl` — is built with **GHC
9.12** pinned through the repository's Nix flake (`flake.nix` at the repo root) and follows the
house Haskell standards recorded in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`
(`core/standards.md`, `core/custom-prelude.md`, `core/record-patterns.md`,
`core/multiline-strings.md`). Concretely:

- **GHC 9.12 via Nix.** EP-8 (the earliest plan, whose prototypes need a compiler) replaces the
  unpinned `pkgs.ghc` / `pkgs.cabal-install` in the dev-shell `packages` list with the pinned 9.12
  toolchain — `pkgs.haskell.compiler.ghc912`, `pkgs.cabal-install`,
  `pkgs.haskell.packages.ghc912.{haskell-language-server,fourmolu,cabal-gild}`, plus `pkgs.zlib`
  and `pkgs.pkg-config`. The pattern mirrors the canonical template at
  `bokuno/nix/nix-flake-templates/haskell-9_12/flake.nix` (the sibling project `bokuno/mina` is a
  working real-world example). Bumping the flake's Haskell tools is a deliberate, recorded
  modification of shared infrastructure; it is safe because the bootstrap flake's Haskell entries
  are labelled "for nagarectl — EP-6", EP-6 is Not Started so nothing yet depends on the old
  version, and GHC 9.12 is forward-compatible with EP-6's `Haskell2010` package when it lands.
- **Language edition & extensions.** Every Cabal stanza uses `default-language: GHC2024` and
  `import: common`, where a single `common` stanza enables `DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings` (and `MultilineStrings`
  where embedded YAML/text literals benefit). GHC2024 already provides `DataKinds`,
  `DerivingStrategies`, `LambdaCase`, and `ImportQualifiedPost`, so those are not listed.
- **Custom prelude.** `nagare-dsl` exposes `Nagare.Dsl.Prelude` (created in EP-9) re-exporting the
  common imports — `Generic`, `Text`, the aeson classes, and the lens operators via
  `Control.Lens`. Every module imports it instead of repeating imports. The prelude deliberately
  does **not** re-export `Data.Generics.Labels`; modules that use generic-lens `#label` access
  import `"generic-lens" Data.Generics.Labels ()` themselves (per `core/custom-prelude.md`, this
  avoids forcing the orphan `IsLabel` instance on every module).
- **Records.** No field prefixes (rely on `DuplicateRecordFields`): `Deployment`'s fields are
  `name`, `namespace`, `image`, `domain`, `port`, `env`, `resources`, `scale` — not `depName`,
  `depImage`, etc.; `Resources` has `cpu`/`memory`; `Scale` has `minScale`/`maxScale` (avoiding a
  clash with `Prelude.min`/`max`). All fields are strict (`!`). All deriving is explicit
  (`deriving stock (Generic, Eq, Ord, Show)`, `deriving newtype (...)`, `deriving anyclass
  (...)`). Field access and update use generic-lens `#label` with lens operators (`^.`, `.~`,
  `?~`, `%~`, `at`, `ix`) rather than record selectors or record-update syntax.
- **Imports.** Qualified imports are postpositive (`import Data.Text qualified as Text`).
- **Formatting.** `fourmolu` and `cabal-gild`, wired through `treefmt` (pattern from the
  `haskell-9_12` flake template).

These standards govern *how* the Haskell is written; they do **not** change the canonical types of
Integration Point 1 or the exact bytes of Integration Point 2. The maximal-safety surface of
Integration Point 1 is expressed in these conventions: a `ServiceName` newtype still hides its
constructor and derives `deriving stock (Generic, Eq, Ord, Show)`; `EnvVar` is still the sum type
`EnvLiteral Text | EnvSecretRef SecretName`; `Deployment` simply uses strict, unprefixed fields
that consumers read via `#label`. If EP-9 adjusts a field name to satisfy these conventions it
updates Integration Point 1 and the consuming plans accordingly.


## Progress

Milestone-level progress across all child plans. Updated as each child plan's milestones complete.

- [x] Toolchain: GHC 9.12 pinned in the repository Nix flake (EP-8 M0); `nagare-dsl` uses
  `GHC2024` + the house `common` stanza and a `Nagare.Dsl.Prelude` custom prelude. (Integration
  Point 6.) _(2026-06-03. `fourmolu` + `cabal-gild` are provided by the dev shell; wiring a
  `treefmt` config for the `cli/` tree is deferred to EP-12 when `nagarectl` joins.)_
- [x] EP-8: Three runnable prototypes (config-as-program, interpreted eDSL, Dhall) each render the
  shared hello example to Knative YAML byte-identical to EP-6's target; scored on the five criteria;
  a substrate decision is recorded in this MasterPlan's and EP-8's Decision Log. _(2026-06-03:
  Complete. Winner: native Haskell eDSL, config-as-program. GHC 9.12 pinned (M0).)_
- [x] EP-9: `cli/nagare-dsl/` library exists with the `Deployment` type and maximal-safety
  constructors; a golden test renders the canonical example byte-for-byte to Knative YAML; negative
  type tests prove illegal configs (bad name, value+secretRef, max<min) fail to compile or
  construct. _(2026-06-03: 45 tests green; unprefixed strict fields; renderer uses `encodePretty`
  + key comparator to match EP-6 byte-for-byte.)_
- [ ] EP-10: `loadDeployment :: FilePath -> IO (Either LoadError Deployment)` loads a real config
  file in the chosen substrate into a `Deployment`, with clear `LoadError`s for each failure mode.
- [ ] EP-11: a `nagare-presets` library plus two example apps that share one preset and one
  environment overlay; property tests show composing valid presets yields a valid `Deployment`.
- [ ] EP-12: `nagarectl deploy` deploys from the typed config end-to-end and prints a live URL; the
  `nagare.yaml` parsing path is deleted, EP-6's `Nagare.Config`/`Nagare.Render` are retired, and the
  in-repo example app carries the typed config instead of YAML.


## Surprises & Discoveries

- Dependency inventory from the local `mori` corpus (run `mori registry list` / `mori registry
  search`): `dhall-lang/dhall-haskell` is present at
  `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project` and includes the `dhall`, `dhall-json`,
  `dhall-yaml`, `dhall-toml`, and `dhall-openapi` packages — the Dhall candidate is well-supported
  and the user already maintains `shinzui/dhall-grafana`. The repo itself already uses Dhall
  (`mori.dhall`, `.seihou/config.dhall`). **There is no `hint` package and no GHC-interpreter
  package in the corpus** (`mori registry search hint` → no matches), so the interpreted-eDSL
  candidate (EP-8 prototype 2) either needs a network fetch of `hint` from Hackage or must use the
  raw GHC API; EP-8 must measure this feasibility/operational cost explicitly rather than assume it.
  `garnix-io/cradle` (process running) and `pcapriotti/optparse-applicative` (CLI) are present, as
  used by EP-6. (2026-06-03)
- The clean architectural seam that makes the decomposition robust to the spike's outcome: every
  candidate substrate produces the *same* `Deployment` Haskell value (the native eDSL directly, the
  interpreter by evaluation, Dhall by `FromDhall` marshalling). This is why EP-9 (the type + renderer)
  has no hard dependency on EP-8 (the substrate choice) — recorded so a future contributor does not
  mistakenly serialize the two plans. (2026-06-03)
- Nix GHC 9.12 pattern: the canonical pinned-GHC-9.12 flake template lives at
  `/Users/shinzui/Keikaku/bokuno/nix/nix-flake-templates/haskell-9_12/flake.nix` (uses
  `pkgs.haskell.compiler.ghc912`, `pkgs.haskell.packages.ghc912.{haskell-language-server,fourmolu,cabal-gild}`,
  and a `treefmt.nix` wiring `fourmolu` + `cabal-gild`). The sibling Haskell CLI `bokuno/mina` is a
  working real-world example (`ghc9122`, `callCabal2nix`, a `nix/haskell-overlay.nix`). The current
  nagare root `flake.nix` ships an *unpinned* `pkgs.ghc`/`pkgs.cabal-install` in its dev shell,
  labelled "for nagarectl — EP-6"; because EP-6 is Not Started, EP-8 can safely re-pin it to GHC
  9.12 as its first milestone. The house Haskell standards at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei` require GHC 9.12+, GHC2024, the `common`-stanza
  extensions, a custom prelude, generic-lens `#label` records, strict unprefixed fields, explicit
  deriving strategies, and postpositive qualified imports. (2026-06-03)


## Decision Log

- Decision: Lead the initiative with a dedicated substrate-evaluation spike (EP-8) that builds three
  runnable prototypes — native eDSL as config-as-program, native eDSL via an embedded interpreter,
  and Dhall — and decides between them with evidence before any production code is committed.
  Rationale: The user framed the request as "evaluate how to create a haskell DSL", and the three
  substrates have materially different loading mechanisms, build-time stories, and operational costs;
  one (the interpreter) depends on `hint`, which is absent from the local corpus and is therefore a
  measured feasibility risk, not an assumption. A spike is the ExecPlan-spec-endorsed way to de-risk
  a significant unknown, and here the unknown reshapes three downstream plans, so it warrants a whole
  plan rather than a milestone.
  Date: 2026-06-03

- Decision: The new DSL **replaces `nagare.yaml` entirely**; backwards compatibility and coexistence
  are non-goals.
  Rationale: The user chose "Replace YAML entirely" when asked how the DSL should relate to the
  existing contract. This avoids maintaining two parallel contracts and a permanent migration shim,
  at the cost of a hard cutover that EP-12 performs (delete the YAML parser/renderer, migrate the
  example app). It also means the bootstrap MasterPlan's Integration Point 6 and EP-6 will be
  superseded once this initiative is adopted (Integration Point 4).
  Date: 2026-06-03

- Decision: The type-safety target is **maximal** — invariants are pushed into the type system so
  illegal configurations fail to compile or type-check, not merely fail validation at parse time.
  Rationale: The user chose "Maximal type-level safety". This drives EP-9's design toward newtypes
  with hidden constructors, sum types for mutually-exclusive choices (env literal vs secretRef),
  refined/smart-constructed quantities and names, and *negative* type tests that assert illegal
  configs do not compile. It raises EP-9's complexity, which is accepted as the core value of the
  initiative ("eliminate errors"), and it raises the bar on the substrate (the chosen surface must be
  able to express or marshal into these guarantees), feeding back into EP-8's scoring.
  Date: 2026-06-03

- Decision: Decompose into five child plans (EP-8 spike, EP-9 typed core + renderer, EP-10 surface +
  loading, EP-11 reuse/presets, EP-12 integration + cutover) in three waves.
  Rationale: The substrate is the gating unknown (own plan, Wave 1); the canonical `Deployment` type
  is the substrate-independent seam, so the type + its renderer is one cohesive, offline-verifiable
  library plan (EP-9) and the substrate-specific loading is a separate plan that depends on the
  decision (EP-10); reuse is a headline user requirement with its own demonstrable outcome (EP-11);
  and the YAML cutover can only happen once renderer and loader exist (EP-12). Rejected alternatives:
  no-spike single-substrate commitment, splitting types from renderer (too coupled — same library
  modules), and YAML coexistence (overruled by the replace-entirely decision). See Decomposition
  Strategy.
  Date: 2026-06-03

- Decision: Keep the typed model in a new `cli/nagare-dsl/` library package, separate from EP-6's
  `cli/nagarectl/` executable; `nagarectl` depends on `nagare-dsl`.
  Rationale: A library makes the model, renderer, loader, and presets reusable and offline-testable
  independently of the CLI, keeps EP-9 verifiable without the deploy machinery, and gives EP-11's
  presets a natural home. The executable stays thin (argument parsing, process orchestration). See
  Integration Point 5.
  Date: 2026-06-03

- Decision: This MasterPlan does not modify the bootstrap MasterPlan
  (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) or EP-6 until the user adopts this
  initiative; adoption is signalled by starting EP-12's cutover.
  Rationale: The work is exploratory; EP-6 is Not Started, so there is nothing built to remove yet.
  Documenting the intended supersession in Integration Point 4 keeps the two MasterPlans consistent
  without prematurely entangling them. The actual amendment to the bootstrap plan's Integration
  Point 6 happens as part of EP-12.
  Date: 2026-06-03

- Decision: Adopt the house Haskell standards (`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`)
  for all Haskell in this initiative — the `GHC2024` language edition; a shared `common` stanza
  enabling `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (plus
  `MultilineStrings` where useful); a `Nagare.Dsl.Prelude` custom prelude; strict, unprefixed
  record fields with explicit deriving strategies; generic-lens `#label` field access; postpositive
  qualified imports; and `fourmolu` + `cabal-gild` formatting.
  Rationale: the user directed the initiative to follow these standards; they are the
  repository-wide Haskell conventions and keep `nagare-dsl` consistent with the user's other
  Haskell projects (`mina`, `rei`). This supersedes the earlier child-plan drafts that used
  `GHC2021`/`Haskell2010` and `dep*`/`res*` prefixed fields. The canonical field names become
  `Deployment.{name,namespace,image,domain,port,env,resources,scale}`, `Resources.{cpu,memory}`,
  and `Scale.{minScale,maxScale}`. See Integration Point 6.
  Date: 2026-06-03

- Decision: Pin GHC 9.12 through the repository Nix flake, replacing the unpinned `pkgs.ghc`. The
  flake change uses `pkgs.haskell.compiler.ghc912` + `pkgs.cabal-install` +
  `pkgs.haskell.packages.ghc912.{haskell-language-server,fourmolu,cabal-gild}`, mirroring
  `bokuno/nix/nix-flake-templates/haskell-9_12`. EP-8 performs this pin as its first milestone (M0)
  because it is the earliest plan and its prototypes need the compiler; EP-9–EP-12 inherit it.
  Rationale: the house standard requires GHC 9.12+ (core dependencies, `MultilineStrings`, and the
  `GHC2024` edition all need it); the current flake ships an unpinned `pkgs.ghc` (~9.10). Bumping
  the shared flake is acceptable because EP-6 — the only other Haskell consumer — is Not Started.
  See Integration Point 6.
  Date: 2026-06-03


## Surprises & Discoveries (continued)

- EP-8 substrate decision (2026-06-03): all three prototypes were built and each rendered the
  shared hello example **byte-identically** to the EP-6 golden, scored P1 (config-as-program)
  20/25, P3 (Dhall) 19/25, P2 (interpreter) 16/25. The P1-vs-P3 margin was one point with the
  decisive criteria opposed — (a) maximal type-safety favors the native eDSL, (e) operational
  simplicity favors Dhall — so the choice was put to the user, who selected the **native Haskell
  eDSL in the config-as-program model**, honoring the binding maximal-type-safety priority. See
  EP-8's Decision Log for the full table, evidence, and the downstream consequences for EP-10's
  loader (it implements compile-and-run of the app's `Config.hs`).


## Decision Log (continued)

- Decision: **The chosen substrate is the native Haskell embedded DSL in the config-as-program
  model** (EP-8 Prototype 1). An app ships a real Haskell source file binding `deployment ::
  Deployment`; `nagarectl` compiles-and-runs it to obtain the typed value, then renders it.
  Rationale: highest spike score (20/25) and the only substrate that fully delivers the binding
  *maximal type-safety* decision — because the config is Haskell, EP-9's hidden-constructor
  newtypes and sum types make every documented illegal config *fail to compile*. The one-point
  margin over Dhall (which wins on operational simplicity) was resolved by the user in favor of
  the maximal-safety priority, accepting that the deploy machine must carry GHC (mitigated by the
  repo's pinned GHC-9.12 Nix shell). The interpreter variant is rejected as dominated. This fixes
  EP-10's loader as a compile-and-run mechanism with a `LoadError` covering "file not found",
  "compilation failed" (GHC diagnostic), and "did not bind `deployment`" (Integration Point 3,
  native-eDSL outcome). EP-9/EP-11/EP-12 are unaffected (substrate-independent `Deployment` type).
  Date: 2026-06-03


## Outcomes & Retrospective

(To be filled during and after implementation. Compare the delivered system against the Vision &
Scope: a typed config in which the documented classes of misconfiguration are unrepresentable,
demonstrable reuse across two apps, and `nagarectl deploy` producing a live URL from the typed
config with `nagare.yaml` fully removed. Record which substrate won and whether its real-world
ergonomics matched the spike's prediction.)


## Revision Notes

- 2026-06-03 — Adopted the house Haskell standards
  (`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`) and a Nix-pinned **GHC 9.12** toolchain across
  the whole initiative. Added **Integration Point 6** (toolchain + code standards), two Decision
  Log entries (adopt the standards; pin GHC 9.12 via the flake), a Surprises entry pointing at the
  `haskell-9_12` flake template and the `mina` reference project, and a toolchain milestone in
  Progress. Assigned the flake pin to EP-8 as its **M0** milestone (earliest plan; prototypes need
  a compiler). Cascaded the binding standards note and the GHC2024/9.12 conventions into all five
  child plans (EP-8–EP-12): every Cabal stanza now uses `default-language: GHC2024` with a shared
  `common` stanza; `nagare-dsl` gains a `Nagare.Dsl.Prelude` custom prelude; record types use
  strict, unprefixed fields (`Deployment.{name,namespace,image,domain,port,env,resources,scale}`,
  `Resources.{cpu,memory}`, `Scale.{minScale,maxScale}`) with explicit deriving strategies and
  generic-lens `#label` access; imports are postpositive-qualified; formatting is `fourmolu` +
  `cabal-gild` via `treefmt`. These changes affect *how* the Haskell is written, not the canonical
  types (Integration Point 1) or the rendered bytes (Integration Point 2).
</content>
</invoke>
