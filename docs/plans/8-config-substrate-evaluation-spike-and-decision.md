---
id: 8
slug: config-substrate-evaluation-spike-and-decision
title: "Config substrate evaluation spike and decision"
kind: exec-plan
created_at: 2026-06-03T03:44:07Z
intention: "intention_01kt5s3j2zedh8ew1yp9qdp6c7"
master_plan: "docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md"
---

# Config substrate evaluation spike and decision

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today Nagare apps describe their deployment in an untyped `nagare.yaml` file. The parent
MasterPlan (`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`) replaces
that YAML entirely with a typed configuration surface in which whole classes of mistakes — a
bad service name, an env var that is simultaneously a literal value and a secret reference, a
scale whose max is below its min — are impossible to write at all. Before any production code
is committed, the MasterPlan demands the initiative begin with a research-and-prototype plan
that builds three candidate configuration substrates as working toys, compares them on five
concrete scoring criteria, and records a binding substrate decision. This plan is that spike.

After this spike is complete, a future implementer (or the next plan in the wave) has: three
runnable prototypes in `docs/spikes/ep8-substrate-spike/`, each of which accepts a shared
"hello" example app and renders Knative Service YAML that is byte-identical to EP-6's golden
target; a completed scoring table; and a written substrate decision recorded in this plan's
Decision Log and in the parent MasterPlan's Decision Log. No cluster access is needed: the
entire spike is offline. The prototypes are explicitly throwaway and are discarded once the
decision is written; downstream EP-9 (typed core) and EP-10 (config surface and loader) build
the production winner.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0.1 Pin GHC 9.12 in the repository root Nix flake (replace unpinned `pkgs.ghc`/`pkgs.cabal-install` with `pkgs.haskell.compiler.ghc912` + `pkgs.cabal-install` + `pkgs.haskell.packages.ghc912.{haskell-language-server,fourmolu,cabal-gild}`); verify `nix develop` provides `ghc --version` → 9.12.x. _(2026-06-02: done; both the `default` and `haskell` dev shells re-pinned, `pkgs.zlib`+`pkgs.pkg-config` added; `nix develop --command ghc --version` → 9.12.3.)_
- [x] M1.1 Create the spike workspace at `docs/spikes/ep8-substrate-spike/` with the shared hello input and golden target YAML copied verbatim from EP-6. _(2026-06-02)_
- [x] M1.2 Create `docs/spikes/ep8-substrate-spike/cabal.project`. _(2026-06-02: deviated — lists only `.` + `cradle` initially; `dhall` added in M4 to keep the M1/M2 build closure small. See Decision Log.)_
- [x] M1.3 Create `docs/spikes/ep8-substrate-spike/spike.cabal` with three executable targets: `proto1-config-as-program`, `proto2-interpreter`, `proto3-dhall`. _(2026-06-02; `proto2`/`proto3` start as stubs, substrate deps added in M3/M4.)_
- [x] M2.1 Implement the prototype DSL stub library (`Spike.Types`, `Spike.Render`) shared by all three prototypes. _(2026-06-02: renderer uses `Data.Yaml.Pretty.encodePretty` + explicit key comparator; renders byte-identical to golden.)_
- [x] M2.2 Implement the hello config file for Prototype 1 (`hello/Config.hs`), importing the stub DSL library and binding `deployment :: Deployment`. _(2026-06-02)_
- [x] M2.3 Implement Prototype 1 executable: shell out via `cradle` to `cabal exec -- runghc` on `helper/RunConfig.hs`, capture the rendered YAML (`StdoutRaw`), diff against the golden file. _(2026-06-02; needs `-threaded` for cradle.)_
- [x] M2.4 Validate M2: `cabal run proto1-config-as-program` prints `PASS: output matches golden target`. _(2026-06-02: PASS; round-trip ~1.47s.)_
- [x] M3.1 Investigate `hint` availability. _(2026-06-02: absent from mori corpus; resolved cleanly from Hackage as `hint-0.9.0.9`. Feasible but operationally heavy — see Surprises/Decision Log.)_
- [x] M3.2 Implement Prototype 2 executable via `hint` (`runInterpreter`): load `Config`/`Spike.Types`/`Spike.Render` from source, render inside the interpreter, return the `ByteString`. _(2026-06-02)_
- [x] M3.3 Validate M3: `cabal run proto2-interpreter` prints `PASS: output matches golden target`. _(2026-06-02: PASS; round-trip ~1.35s. Required four non-obvious workarounds — see Surprises.)_
- [x] M4.1 Implement the hello config file for Prototype 3 (`hello/hello.dhall`). _(2026-06-02; M4.4 reuse demo applied — imports `prelude.dhall`'s `webService` preset and layers env via `//`.)_
- [x] M4.2 Implement Prototype 3 executable: `Dhall.inputFile Dhall.auto` decodes `hello.dhall` into `SpikeDhallDeployment` (generic `FromDhall`); convert to `Deployment`; render. _(2026-06-02; numeric fields are `Natural`, narrowed to `Int`; `scaleMin`/`scaleMax` disambiguated with `OverloadedRecordDot`.)_
- [x] M4.3 Validate M4: `cabal run proto3-dhall` prints `PASS: output matches golden target`. _(2026-06-02: PASS, including the composed reuse config; round-trip ~0.5s — the fastest of the three. Broken-name test (M4.5): `name : Text` accepts `Hello_Bad` silently at the substrate level.)_
- [x] M5.1 Fill in the scoring table (all five criteria, all three prototypes). _(2026-06-02: P1 20/25, P2 16/25, P3 19/25; see Decision Log.)_
- [x] M5.2 Write the substrate decision in this plan's Decision Log. _(2026-06-03: native eDSL, config-as-program — user's choice given the 1-point margin and the maximal-safety priority.)_
- [x] M5.3 Write a note in the parent MasterPlan's Decision Log directing the implementer of EP-10 to the chosen substrate. _(2026-06-03: MasterPlan Decision Log + Exec-Plan Registry updated; EP-8 marked Complete.)_
- [x] M5.4 Update Outcomes & Retrospective in this plan. _(2026-06-03)_


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Byte-exact rendering needs an explicit key comparator, not plain `Yaml.encode`.** The
  golden YAML is not alphabetically ordered: inside the autoscaling annotations block,
  `autoscaling.knative.dev/min-scale` precedes `autoscaling.knative.dev/max-scale` (but `max` <
  `min` alphabetically), and a container lists `image`/`ports`/`env`/`resources` in document
  order. `Data.Yaml.encode` orders object keys by the aeson `KeyMap`'s internal order, which
  reproduces neither. `Spike.Render` therefore renders through `Data.Yaml.Pretty.encodePretty`
  with a `setConfCompare` comparator that ranks each key explicitly (falling back to alphabetical
  for unranked keys). With this, the rendered bytes are byte-identical to `hello/golden.yaml`
  (verified by `diff` returning empty). (2026-06-02)
- **`runghc` does not inherit the cabal `common` stanza's language edition.** When Prototype 1
  shells out to `runghc`, GHC compiles the source files fresh and defaults to `Haskell2010`, so
  `deriving stock` fails with "Illegal deriving strategy". The harness must pass `-XGHC2024
  -XOverloadedStrings` explicitly to `runghc`. This is a real operational data point for the
  config-as-program substrate (criterion e): the tool must reproduce the project's language
  flags when it interprets the user's config. (2026-06-02)
- **`cradle` requires the threaded RTS.** Linking `proto1` without `-threaded` makes every
  `cradle` `run`/`run_` throw `Cradle needs the ghc's threaded runtime system`. Added
  `ghc-options: -threaded` to the `proto1` stanza. (2026-06-02)
- **cabal does not always relink on a lone `ghc-options` change.** After adding `-threaded`,
  `cabal build` reported "Up to date" and kept the old non-threaded binary; the fix was to remove
  the executable's `dist-newstyle/.../x/proto1-config-as-program` build dir to force a relink.
  Worth remembering for the later plans. (2026-06-02)
- **`hint` works but is operationally heavy (Prototype 2).** `hint-0.9.0.9` resolves cleanly from
  Hackage (not in the corpus), but getting it to evaluate the shared `Config.hs` against the
  shared renderer took four non-obvious workarounds, each a concrete cost the production tool
  would carry: (1) hint's GHC session does **not** see cabal's in-place `spike-lib` package, so
  `Config`'s `import Spike.Types` cannot resolve against the compiled library — the modules must
  be loaded from **source** on the search path instead; (2) loading from source means the
  interpreted `Deployment` is a *different* type from the host's, so a `Deployment` value cannot
  cross the boundary — the prototype renders *inside* the interpreter and returns only a
  `ByteString`; (3) hint's typed `Extension` enum predates `DerivingStrategies`/`ImportQualifiedPost`,
  so the house-standard sources only compile after `unsafeSetGhcOption "-XGHC2024"` (the raw-flag
  escape hatch); (4) a fresh GHC session sees only boot packages, so `aeson`/`yaml` are invisible
  until cabal is told to emit a `.ghc.environment.*` file (`write-ghc-environment-files: always`).
  And underneath all of that, `hint` links the **GHC API** (`ghc` package) into the binary and
  requires GHC's `libdir` + package databases present at runtime. PASS achieved, but the closure
  and runtime requirements are the heaviest of the three. (2026-06-02)
- **Dhall builds big but runs cleanest (Prototype 3).** Building `dhall-1.42.3` from the corpus
  pulled a ~78-package closure (`megaparsec`, `prettyprinter`, `cborg`/`serialise`, and a full
  network/TLS/crypto stack — `http-client`, `tls`, `crypton-*`, `network` — for Dhall's remote
  imports). That is a one-time *build/link* cost folded into the `nagarectl` binary. At *run*
  time, Prototype 3 needs nothing but the linked binary — no GHC, no package db, no language
  runtime — and round-trips in ~0.5s, half the GHC-based prototypes' ~1.4s. Generic `FromDhall`
  derivation worked once two shape facts were respected: Dhall numeric literals (`8080`, `0`) are
  `Natural`, not `Int` (decode to `Natural`, narrow afterward); and the Haskell field/constructor
  names must match the Dhall record fields / union alternatives exactly. Reuse (criterion c) is
  first-class: a `webService` **function** in `prelude.dhall` plus the `//` override operator
  composes a preset with per-app fields, type-checked by Dhall, no copy-paste. Like the eDSL
  paths, a bad `name` passes through at the substrate level (`name : Text`), though Dhall could add
  an assertion/refinement and real validation lands in the Haskell marshalling layer. (2026-06-02)


## Decision Log

- M5 scoring table (all three prototypes verified PASS against the same golden, 2026-06-02):

  | Criterion | P1: config-as-program | P2: interpreter (hint) | P3: Dhall |
  |-----------|----------------------|------------------------|-----------|
  | (a) Type-safety / unrepresentable invariants | **5** | **5** | **3** |
  | (b) Error-message quality (broken-config) | **4** | **3** | **4** |
  | (c) Reuse ergonomics (webService + env overlay) | **5** | **5** | **4** |
  | (d) Build/eval latency + dependency-closure weight | **4** | **2** | **3** |
  | (e) Operational complexity (what's needed at deploy time) | **2** | **1** | **5** |
  | **Total** | **20 / 25** | **16 / 25** | **19 / 25** |

  Per-cell evidence:
  - **(a)** P1/P2 are real Haskell, so EP-9's maximal-safety surface (hidden-constructor
    `ServiceName` newtype, the `EnvLiteral | EnvSecretRef` sum, smart-constructed `Scale`/
    `Quantity`) makes all three target invariants unrepresentable *by construction* — bad configs
    fail to compile. **5**. P3/Dhall makes the env literal-vs-secret exclusivity unrepresentable-both
    by construction (a union value is exactly one alternative), but a DNS-safe `name` and `max≥min`
    are not expressible in Dhall's own type system without awkward assertions; they land in the
    Haskell `FromDhall` marshalling layer as *load-time* errors, not config type-check errors. **3**.
  - **(b)** Broken-name test (`Hello_Bad`): at the spike level every prototype passes the bad name
    through silently (the shared `Spike.Types` has no validation). In production: P1 surfaces GHC's
    direct, source-located diagnostic / a smart-constructor `Left` message (**4**); P2 surfaces the
    same wrapped in a hint `InterpreterError`/`GhcError` (unicode-escaped `Show`, less readable —
    **3**); Dhall's own type errors are excellent and source-located, and refinement failures come
    from the marshalling smart constructor (**4**).
  - **(c)** P1/P2: a `webService :: Text -> Text -> Deployment` Haskell function + record/lens
    update — fully type-checked, maximally expressive (**5**). P3: a `webService` Dhall *function*
    in `prelude.dhall` + the `//` override operator, type-checked by Dhall, demonstrated composing
    the preset with per-app env without copy-paste (**4**).
  - **(d)** Eval latency: P3 ~0.5s (best) < P2 ~1.35s < P1 ~1.47s. Closure weight (linked into the
    `nagarectl` binary): P1 tiny (`cradle`; GHC is external) → **4**; P3 large but self-contained
    (~78 pkgs: `megaparsec`/`cborg`/`http-client`/`tls`/`crypton`) → **3**; P2 worst — links the
    GHC API (`ghc` package, the compiler itself) → **2**.
  - **(e)** At deploy time P1 needs GHC + `cabal`/`runghc` + the DSL package env + the right
    `-XGHC2024` flags (**2**); P2 needs all of that plus hint's `.ghc.environment`/package-db
    handling, `unsafeSetGhcOption` escapes, and the GHC API+libdir at runtime (**1**); P3 needs
    nothing but the compiled `nagarectl` binary — the `dhall` library is linked in, no language
    runtime (**5**).

  Note on sensitivity: P1 and P3 are within one point. The decisive axes pull in opposite
  directions — (a) maximal type-safety favors the native eDSL (P1), while (e) operational
  complexity strongly favors Dhall (P3). Because that trade-off engages the user's explicitly
  stated top priority ("maximal type-level safety") against the practical reality of deploying a
  personal PaaS from a laptop, the final substrate choice was put to the user rather than decided
  by the raw total alone (see the Decision below). Date: 2026-06-02

- **SUBSTRATE DECISION: the native Haskell embedded DSL in the *config-as-program* model
  (Prototype 1) wins.** An app ships a real Haskell source file (e.g. `nagare/Config.hs`) that
  imports the `nagare-dsl` library and binds a top-level `deployment :: Deployment`; `nagarectl`
  compiles-and-runs it (as Prototype 1 did via `cabal exec -- runghc`) to obtain the typed value,
  then renders it.
  Rationale: It scores highest (20/25) and, decisively, it is the only substrate that fully
  satisfies the MasterPlan's binding *maximal type-safety* decision — the user's explicitly stated
  top priority. Because the config *is* Haskell, EP-9's hidden-constructor `ServiceName` newtype,
  the `EnvLiteral | EnvSecretRef` sum type, and the smart-constructed `Scale`/`Quantity` make
  every documented illegal configuration (non-DNS-safe name, value+secretRef together, `max < min`)
  **fail to compile** — not merely fail validation at load time. Reuse is also maximal: shared
  shapes are ordinary Haskell functions over the typed model. When the scores were presented (the
  one-point P1-vs-P3 margin, with criterion (a) favoring the eDSL and (e) favoring Dhall), the user
  chose the native eDSL, accepting its operational cost.
  Accepted trade-off (criterion e = 2): the machine running `nagarectl deploy` must have GHC +
  `cabal`/`runghc` and the `nagare-dsl` package available. This is acceptable because the Nagare
  operator already works inside this repo's Nix dev shell, which EP-8 M0 pinned to GHC 9.12 — so
  the toolchain is present in the standard operating environment — and the maximal-safety guarantee
  was judged worth the cost. The interpreter variant (Prototype 2, 16/25) is rejected as dominated:
  same type-safety as P1 but the heaviest closure (it links the GHC API) and the most fragile
  runtime (GHC libdir + package db, `.ghc.environment`, `unsafeSetGhcOption`).
  Consequences for downstream plans: EP-10's `loadDeployment :: FilePath -> IO (Either LoadError
  Deployment)` implements the config-as-program mechanism — locate the app's `Config.hs`, compile
  and run it against the `nagare-dsl` package, and capture the bound `deployment` value; its
  `LoadError` enumerates "config file not found", "compilation failed" (carrying the GHC
  diagnostic), and "config did not bind `deployment`" (matching MasterPlan Integration Point 3's
  native-eDSL outcome). EP-9, EP-11, EP-12 are unaffected by the choice (they target the
  substrate-independent `Deployment` type). EP-8's prototypes surfaced concrete ergonomic lessons
  EP-9/EP-10 should carry: pass `-XGHC2024 -XOverloadedStrings` (or the app file's own pragmas)
  when interpreting the config; expose the DSL library to the compile step via a generated
  `.ghc.environment.*` file or an explicit package-db/`-package` flag (a bare `runghc` sees only
  boot packages); and `cradle`-based process spawning needs `-threaded`.
  Date: 2026-06-03

- Decision: Place the spike workspace at `docs/spikes/ep8-substrate-spike/` (not under `cli/`).
  Rationale: The spike is explicitly throwaway and must be isolated from production code. Putting
  it under `cli/` would pollute the package layout that EP-9 and EP-10 create. A `docs/spikes/`
  directory signals "prototyping artifact, not production" to any future reader and is easy to
  delete as a whole directory after the decision is recorded. The `docs/` tree already holds the
  plans and masterplans; a sibling `spikes/` folder is the natural companion.
  Date: 2026-06-03

- Decision: All three prototypes share one `spike.cabal` with three executable stanzas and one
  shared internal library (`Spike.Types`, `Spike.Render`).
  Rationale: The comparison is only meaningful if the rendering logic is identical across
  candidates; a shared library enforces this. Three separate cabal projects would make the diff
  command in M5 harder to mechanise and would triplicate the cabal boilerplate. One project with
  three executables is the minimal, most comparable structure.
  Date: 2026-06-03

- Decision: The `hint` candidate (Prototype 2) must investigate availability from Hackage if it
  is absent from the local mori corpus; if investigation concludes it is impractical or requires
  a heavy dependency closure, that is a legitimate "infeasible / costly" verdict for criterion (d)
  and (e) rather than a reason to skip the prototype.
  Rationale: The MasterPlan explicitly notes that `hint` is absent from the corpus and calls this
  "a real feasibility risk" to be measured, not assumed. Skipping the prototype would leave the
  decision unsupported by evidence.
  Date: 2026-06-03

- Decision: Prototype 2 falls back to the GHC API (`GHC.Paths` + the `ghc` boot library) if
  `hint` cannot be obtained in a reasonable time. The GHC boot library is always present when GHC
  is installed; `GHC.Paths` is a tiny Hackage package that locates the installed GHC. Both must be
  recorded in the scoring under criterion (e) (operational complexity).
  Rationale: This ensures the interpreter prototype is grounded in a concrete API regardless of
  the `hint` outcome, so the scoring table has real numbers rather than a blank row.
  Date: 2026-06-03

- Decision: EP-8 pins GHC 9.12 in the repository root Nix flake (M0) and builds all prototypes
  with `default-language: GHC2024` per the house Haskell standards (haskell-jitsurei).
  Rationale: The house standard requires GHC 9.12+ and GHC2024; EP-8 is the earliest plan and its
  prototypes need the compiler, so it establishes the pinned toolchain that EP-9–EP-12 inherit.
  The pattern mirrors `bokuno/nix/nix-flake-templates/haskell-9_12`.
  Date: 2026-06-03


- Decision (implementation): Keep `cabal.project` lean (only `.` + the `cradle` corpus path)
  through M1/M2 and add the `dhall` corpus package only in M4; stub `proto2`/`proto3` until their
  milestones. Render through `Data.Yaml.Pretty.encodePretty` with an explicit key comparator
  rather than the plan's literal `Data.Yaml.encode`.
  Rationale: deferring `dhall` avoids dragging its large transitive closure into the early,
  fast-iterating M1/M2 builds; the comparator is required for byte-exact output (see Surprises).
  All three are local, recorded deviations that do not change the spike's outcome — every
  prototype still renders the shared hello example through the one `Spike.Render` and is compared
  to the same golden.
  Date: 2026-06-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome.** The spike met its purpose in full. Three runnable prototypes were built under
`docs/spikes/ep8-substrate-spike/`, each rendering the shared hello example to Knative YAML
**byte-identical** to the EP-6 golden, all verified offline with no cluster access:

- Prototype 1 (config-as-program, `cabal exec -- runghc` via `cradle`): PASS, ~1.47s.
- Prototype 2 (interpreter, `hint-0.9.0.9`): PASS, ~1.35s — but only after four workarounds
  (source-loading instead of the in-place package, in-interpreter rendering, `unsafeSetGhcOption
  "-XGHC2024"`, and a generated `.ghc.environment.*`), and it links the GHC API.
- Prototype 3 (Dhall, `Dhall.inputFile auto`): PASS, ~0.5s (fastest), with a `prelude.dhall`
  `webService` preset composed via `//` proving first-class reuse; large build closure, zero
  runtime deps.

The five-criterion scoring (full table + evidence in the Decision Log) put P1 at 20/25, P3 at
19/25, P2 at 16/25. The P1-vs-P3 margin was one point, with the two decisive criteria opposed:
(a) maximal type-safety favors the native eDSL, (e) operational simplicity favors Dhall. The
choice was presented to the user, who selected the **native eDSL in the config-as-program model**
— honoring the MasterPlan's binding maximal-type-safety priority (illegal configs fail to
*compile*) and accepting that the deploy machine must carry GHC (mitigated by the repo's pinned
GHC-9.12 Nix shell).

**Lessons carried forward (for EP-9/EP-10).** Byte-exact rendering needs an explicit key
comparator (`Data.Yaml.Pretty.encodePretty` + `setConfCompare`), not plain `Yaml.encode`, because
the golden order is non-alphabetical. A bare `runghc`/interpreter sees only boot packages and the
project's default language edition is *not* inherited — the compile/eval step must supply
`-XGHC2024 -XOverloadedStrings` (or rely on the app file's pragmas) and expose `nagare-dsl` via a
`.ghc.environment.*` file or explicit `-package`/`-package-db` flags. `cradle` requires
`-threaded`, and cabal may not relink on a lone `ghc-options` change (remove the component's build
dir to force it).

**Gaps / future cleanup.** The prototypes are throwaway; per the plan they are left in place for
reference until EP-9 lands, then deleted. The `Spike.Types` fields use `dep*`/`res*` prefixes
(the spike predates adopting the house unprefixed-field convention); EP-9's production
`Nagare.Dsl.Types` uses the unprefixed names per MasterPlan Integration Point 6.


## Context and Orientation

This section explains everything a novice needs to understand before touching a file. Read it
fully before starting.

**What Nagare is.** Nagare is a personal Platform-as-a-Service: one Google Cloud Platform
virtual machine running the small Kubernetes distribution k3s with Knative Serving installed.
Knative Serving turns a container image into an auto-scaling web service called a *Knative
Service*. Today an app is described by `nagare.yaml`; `nagarectl deploy` reads it, renders
Kubernetes YAML, and applies it. This initiative replaces `nagare.yaml` with a type-safe
configuration surface. This plan (EP-8) is the spike that decides which surface to use.

**The three candidates.** The candidates are described in prose in the parent MasterPlan.
In short:

Candidate 1 — *config-as-program* — means an app ships a real Haskell source file (e.g.
`nagare/Config.hs`) that imports a tiny DSL library and binds a top-level `deployment ::
Deployment` value. The tool compiles and runs that file (via `runghc` or `cabal run`) to obtain
the value, then renders it to YAML. This is the model used by xmonad (window manager whose
config is a Haskell program), Hakyll (static site generator), and Shake (build tool).

Candidate 2 — *embedded interpreter* — same app-side source file, but evaluated at runtime
through an embedded Haskell interpreter — the `hint` package (a wrapper around the GHC API that
exposes a `Hint.runInterpreter :: Interpreter a -> IO (Either InterpreterError a)` monad) or
the raw GHC API — so there is no per-app compile step visible to the user. The critical risk: the
`hint` package is not in the local mori corpus (confirmed by `mori registry search hint` →
no matches) and the embedded GHC API requires GHC to be present at runtime on the machine
running `nagarectl`.

Candidate 3 — *Dhall* — means an app ships a `nagare.dhall` file written in Dhall, a typed,
non-Turing-complete functional configuration language. The tool reads it with the `dhall`
Haskell package (which is in the mori corpus at
`/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`), marshals it
into a Haskell record via `Dhall.inputFile auto`, and renders. Dhall has first-class imports and
functions for reuse, and this repository already uses Dhall (`mori.dhall`,
`.seihou/config.dhall`).

**The fixed target.** Every prototype must render the *same* output: the Knative Service YAML
defined verbatim in EP-6 (`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`, "What the renderer
must produce"). The shared hello example is: service name `hello`, namespace `personal`, image
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello` (no tag in the descriptor; the tag
`20260602-120000` is passed at render time), port `8080`, two env vars (`LOG_LEVEL` as a literal
`info` and `DATABASE_URL` as a secretRef `hello-db-url`), resources `cpu: 250m`/`memory: 512Mi`,
scale `min: 0` / `max: 3`, no custom domain. The expected rendered YAML is reproduced in full in
M1 below.

**The scoring rubric.** Five criteria are scored for each prototype on a 1–5 scale (5 = best),
with a brief evidence note for each cell:

(a) **Type-safety** — how well does the substrate let the future DSL express maximal-safety
invariants? Can the "value + secretRef simultaneously" bug, a `max < min` scale, and a
non-DNS-safe service name each be made unrepresentable — i.e., rejected before any YAML is
rendered, by the type system or the substrate's own type-checker? Score 5 means all three
invariants hold by construction; score 1 means they all require runtime validation.

(b) **Error-message quality** — deliberately introduce one broken config into each prototype
(e.g., change `"hello"` to `"Hello_bad"` to trigger a DNS-label violation, or set `max: -1`
to trigger a scale invariant). Record the exact error text the tool produces and assess whether
a non-expert user would understand what to fix.

(c) **Reuse ergonomics** — factor out a shared `webService` shape (e.g., `port: 8080`,
`min: 0`, `max: 3`) and a `prodEnv` overlay (adds a `LOG_LEVEL=info` literal). Compose them
to derive the hello config without copy-paste, in the substrate's own idiom (a Haskell function,
a Dhall function, a Haskell record update). Assess how natural the composition feels and whether
the type-checker or type-system validates the result.

(d) **Build/eval latency and dependency-closure weight** — time the round-trip from `cabal run
proto<N>` to "PASS". Identify the packages pulled in beyond what the production DSL already
needs. For the interpreter candidate, count the packages in the `hint` or GHC API closure and
note any C libraries required.

(e) **Operational complexity** — what must be present at deploy time on the machine running
`nagarectl`? For config-as-program: GHC and `cabal` must be installed (or `runghc`). For the
interpreter: GHC, a package database visible to the interpreter, and `hint`'s C dependency on
the GHC runtime. For Dhall: only the compiled `nagarectl` binary (the `dhall` library is linked
in statically or as a shared library that ships with the binary); no separate language runtime.

**Repository layout relevant to this plan.** The spike files all live in
`docs/spikes/ep8-substrate-spike/` (created in M1). Nothing under `cli/` is touched. After the
decision is recorded the implementer *does not* delete the spike; it is left for reference until
EP-9 is complete, then deleted (or archived) together with EP-9's Decision Log note.

**Toolchain prerequisites.** Run all commands inside the repository-root developer shell:

```bash
# from /Users/shinzui/Keikaku/bokuno/nagare
nix develop
```

This provides GHC 9.12 (pinned via the flake), `cabal` 3.x, and `runghc`. If the Nix shell is
unavailable, any environment with GHC 9.12 and `cabal` 3.x suffices. M0.1 below pins GHC 9.12 in
the repository root flake, and all prototypes are built with `default-language: GHC2024` per the
house standards. The `dhall` CLI tool is not required — the prototype calls the `dhall` Haskell
library directly. No cluster access, no `kubectl`, no `docker` is needed anywhere in this plan.

> **Haskell standards (binding; see MasterPlan Integration Point 6).** Every Haskell artifact in this initiative is built with **GHC 9.12** pinned through the repository Nix flake and follows the house standards in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`. Cabal stanzas use `default-language: GHC2024` and `import: common`, where the `common` stanza enables `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (and `MultilineStrings` where useful). Record types use strict (`!`) unprefixed fields with explicit `deriving stock`/`deriving newtype`/`deriving anyclass` strategies; qualified imports are postpositive (`import X qualified as Y`). Formatting is `fourmolu` + `cabal-gild` via `treefmt`.

**Key library paths (from the mori corpus — read these sources before guessing at APIs).**

- `dhall` package: `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`
  — the main module is `Dhall` (re-exporting `Dhall.Marshal.Decode`); relevant exports:
  `inputFile :: Decoder a -> FilePath -> IO a`, `auto :: FromDhall a => Decoder a`,
  `record :: RecordDecoder a -> Decoder a`, `field :: Text -> Decoder a -> RecordDecoder a`,
  `union :: UnionDecoder a -> Decoder a`, `constructor :: Text -> Decoder a -> UnionDecoder a`.
  `FromDhall` instances can be derived via `DeriveGeneric` + `DeriveAnyClass`.
- `cradle` package: `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle/src/Cradle.hs`
  — relevant exports: `run_`, `cmd`, `addArgs`.
- `tasty` package: `/Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty`
  — not required for the spike prototypes (a simple `diff` check suffices), but available if a
  proper test harness is desired.


## Plan of Work

The spike has five milestones. Each is independently verifiable before the next begins. The
first milestone pins the shared inputs; the next three implement one prototype each; the fifth
scores them and writes the decision. Do not proceed to M3 until M2 is validated; do not proceed
to M4 until M3's feasibility verdict is written.

**Milestone M1 — Spike workspace, shared hello example, and golden target.** At the end of M1
there is a directory `docs/spikes/ep8-substrate-spike/` containing the hello input files in three
substrate formats, the golden target YAML copied verbatim from EP-6, a single `spike.cabal` with
three executable stanzas, a `cabal.project` pointing at the local mori corpus, and a shared
internal library with the minimal `Deployment` type and renderer needed by all three prototypes.
The workspace compiles to at least stub executables (`cabal build all` succeeds).

**Milestone M2 — Prototype 1: config-as-program.** At the end of M2, running `cabal run
proto1-config-as-program` from inside the spike workspace executes a process that: locates
`hello/Config.hs` (a Haskell source file binding `deployment :: Deployment`); compiles and runs
it via `runghc` (using `cradle` to shell out); captures the rendered YAML; and diffs it
byte-for-byte against the golden target, printing `PASS: output matches golden target`.

**Milestone M3 — Prototype 2: interpreter.** At the end of M3, the `hint` availability
investigation is concluded and recorded in the Decision Log. If `hint` is obtainable (Hackage
fetch or Nix package), the prototype evaluates `hello/Config.hs` at runtime through
`Hint.runInterpreter` without a separate compile step, extracts the `deployment` value, renders
YAML, and diffs against the golden target. If `hint` cannot be made to work (missing package
database, import resolution failures, prohibitive closure), the prototype instead uses the GHC
API directly (`GHC.Paths` + `GHC.runGhcT`); either way the executable runs and the result is
`PASS` or a documented "infeasible" verdict with the exact error.

**Milestone M4 — Prototype 3: Dhall.** At the end of M4, running `cabal run proto3-dhall` from
the spike workspace: reads `hello/hello.dhall` using `Dhall.inputFile auto`; unmarshals into a
`SpikeDhallDeployment` Haskell record (a flat record with all the hello fields, deriving
`Generic` and `FromDhall`); passes the fields into the shared `Spike.Render.renderService`
function; and diffs the rendered bytes against the golden target, printing `PASS`.

**Milestone M5 — Scoring and decision.** At the end of M5, the scoring table (five criteria,
three prototypes) is filled in with evidence from M2–M4, a clear substrate winner is chosen with
a one-paragraph rationale, the decision is entered in this plan's Decision Log, and a note is
added here directing the implementer to propagate the decision to the parent MasterPlan's
Decision Log (that propagation is an implementer responsibility, not done by this plan to avoid
modifying an unrelated file automatically).


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/nagare` inside `nix develop` unless stated
otherwise.

### M0 — Pin GHC 9.12 in the Nix flake

This milestone pins the Haskell toolchain in the repository root flake
(`/Users/shinzui/Keikaku/bokuno/nagare/flake.nix`) before any prototype is built. The flake
currently ships unpinned `pkgs.ghc` and `pkgs.cabal-install` entries in the dev-shell `packages`
list, plus an optional lighter `haskell` shell using `[ pkgs.ghc pkgs.cabal-install ]`. Replace
the unpinned entries in the dev-shell `packages` list with the pinned GHC-9.12 toolchain:

```nix
# Haskell toolchain pinned to GHC 9.12 (house standard;
# see haskell-jitsurei/core/standards.md). Pattern mirrors
# bokuno/nix/nix-flake-templates/haskell-9_12/flake.nix.
pkgs.haskell.compiler.ghc912
pkgs.cabal-install
pkgs.haskell.packages.ghc912.haskell-language-server
pkgs.haskell.packages.ghc912.fourmolu
pkgs.haskell.packages.ghc912.cabal-gild
pkgs.zlib
pkgs.pkg-config
```

Verify the pinned compiler is what `nix develop` provides:

```bash
nix develop --command ghc --version   # expect: ... version 9.12.x
```

The optional lighter `haskell` shell in the flake should be updated the same way (or removed) so
it does not reintroduce an unpinned GHC. This is a deliberate, recorded modification of the shared
root flake: the bootstrap flake's Haskell tools were labelled "for nagarectl — EP-6" and are not
yet used, so bumping them to 9.12 is forward-compatible.

### M1 — Spike workspace

**M1.1 — Create the directory layout.**

```bash
mkdir -p docs/spikes/ep8-substrate-spike/hello
mkdir -p docs/spikes/ep8-substrate-spike/src/Spike
```

The layout you are building:

```text
docs/spikes/ep8-substrate-spike/
  cabal.project                     -- points at local mori corpus packages
  spike.cabal                       -- one library + three executables
  src/
    Spike/
      Types.hs                      -- minimal Deployment type (shared by all prototypes)
      Render.hs                     -- renderService :: Deployment -> Text -> ByteString
  hello/
    Config.hs                       -- Prototype 1 & 2: Haskell source binding deployment
    hello.dhall                     -- Prototype 3: Dhall expression
    golden.yaml                     -- the fixed target YAML (copied from EP-6)
  app/
    Proto1.hs                       -- Prototype 1 main (config-as-program via runghc)
    Proto2.hs                       -- Prototype 2 main (interpreter)
    Proto3.hs                       -- Prototype 3 main (Dhall)
```

**M1.2 — Write the golden target YAML.** Create
`docs/spikes/ep8-substrate-spike/hello/golden.yaml` with this exact content — it is copied
verbatim from EP-6's "What the renderer must produce" section, adapted to the hello example (name
`hello`, image `us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello`, tag `20260602-120000`, env
`DATABASE_URL` as a secretRef to `hello-db-url` and `LOG_LEVEL` as literal `info`, resources cpu
`250m` / memory `512Mi`, scale 0..3, no domain). The two env entries are sorted alphabetically
by variable name (DATABASE_URL before LOG_LEVEL) as required by EP-6's stability rule:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: '0'
        autoscaling.knative.dev/max-scale: '3'
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: hello-db-url
              key: DATABASE_URL
        - name: LOG_LEVEL
          value: info
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
```

This file must not be modified after M1 completes. It is the fixed contract all three prototypes
must reproduce byte-for-byte.

**M1.3 — Write `cabal.project`.** Create
`docs/spikes/ep8-substrate-spike/cabal.project`:

```cabal
packages:
  .

-- Local mori corpus sources (avoid Hackage fetch for packages already on disk)
source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall
  tag: HEAD

source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle
  tag: HEAD
```

If `source-repository-package` with `file://` paths does not work in your cabal version, replace
them with `packages:` entries pointing at the source trees directly:

```cabal
packages:
  .
  /Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall
  /Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle
```

The `yaml` and `aeson` packages come from Hackage (they are not in the local corpus but are
standard Haskell libraries). The `hint` package, if used, must also come from Hackage; record
the version resolved in the Decision Log for M3.

**M1.4 — Write `spike.cabal`.** Create
`docs/spikes/ep8-substrate-spike/spike.cabal`:

```cabal
cabal-version:      3.0
name:               spike
version:            0.1.0.0
synopsis:           EP-8 throwaway substrate evaluation prototypes.
build-type:         Simple

common common
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        OverloadedLabels
        OverloadedStrings
    ghc-options: -Wall

-- Shared library: the minimal Deployment type and renderer used by all prototypes.
library spike-lib
    import:           common
    hs-source-dirs:   src
    exposed-modules:  Spike.Types
                      Spike.Render
    build-depends:    base >=4.17 && <5
                    , text
                    , bytestring
                    , containers
                    , aeson
                    , yaml

-- Prototype 1: config-as-program (shell out to runghc / cabal run).
executable proto1-config-as-program
    import:           common
    main-is:          Proto1.hs
    hs-source-dirs:   app
    build-depends:    base
                    , spike-lib
                    , text
                    , bytestring
                    , cradle
                    , directory
                    , filepath

-- Prototype 2: interpreter (hint or GHC API).
executable proto2-interpreter
    import:           common
    main-is:          Proto2.hs
    hs-source-dirs:   app
    build-depends:    base
                    , spike-lib
                    , text
                    , bytestring
                    -- Add 'hint' here if obtained from Hackage:
                    -- , hint
                    -- Or use the ghc boot library + GHC.Paths:
                    -- , ghc
                    -- , ghc-paths

-- Prototype 3: Dhall (Dhall.inputFile auto).
executable proto3-dhall
    import:           common
    main-is:          Proto3.hs
    hs-source-dirs:   app
    build-depends:    base
                    , spike-lib
                    , text
                    , bytestring
                    , dhall
```

**M1.5 — Write `Spike.Types`.** Create
`docs/spikes/ep8-substrate-spike/src/Spike/Types.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Minimal, un-validated Deployment record shared by all three spike prototypes.
-- This is NOT the production type (that lives in EP-9's Nagare.Dsl.Types).
-- Invariants are deliberately loose here so we can test all three substrates
-- against the same rendering function; the scoring rubric assesses each
-- substrate's ability to enforce invariants via its own type system.
module Spike.Types
  ( Deployment(..)
  , EnvVar(..)
  , Resources(..)
  , Scale(..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

data EnvVar
  = EnvLiteral !Text      -- ^ a plain value:  { value: "info" }
  | EnvSecretRef !Text    -- ^ a secret reference: { secretRef: "notes-db-url" }
  deriving stock (Eq, Show)

data Resources = Resources
  { resCpu    :: !(Maybe Text)
  , resMemory :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data Scale = Scale
  { scaleMin :: !Int
  , scaleMax :: !Int
  }
  deriving stock (Eq, Show)

data Deployment = Deployment
  { depName      :: !Text
  , depNamespace :: !Text
  , depImage     :: !Text         -- ^ repository path; no tag
  , depPort      :: !Int
  , depEnv       :: !(Map Text EnvVar)
  , depResources :: !(Maybe Resources)
  , depScale     :: !(Maybe Scale)
  , depDomain    :: !(Maybe Text)
  }
  deriving stock (Eq, Show)
```

**M1.6 — Write `Spike.Render`.** Create
`docs/spikes/ep8-substrate-spike/src/Spike/Render.hs`. This is the single renderer shared by
all three prototypes; the comparison is only meaningful if they all use it.

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Render a spike Deployment to Knative Service YAML.
-- Rules (from EP-6):
--   - env entries sorted by variable name (Data.Map is already ordered)
--   - autoscaling annotation values are Strings (quoted)
--   - absent optional fields produce no YAML sub-objects
--   - secretRef: valueFrom.secretKeyRef.name = secret, key = env var name
module Spike.Render
  ( renderService
  , renderDomainMapping
  ) where

import qualified Data.Aeson           as A
import qualified Data.Aeson.Key       as AK
import qualified Data.Aeson.KeyMap    as KM
import qualified Data.ByteString      as BS
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Yaml            as Yaml
import           Spike.Types

-- | Render to Knative Service YAML bytes.  The second argument is the
-- resolved image tag (e.g. "20260602-120000").
renderService :: Deployment -> Text -> BS.ByteString
renderService dep tag = Yaml.encode (serviceValue dep tag)

-- | Render a DomainMapping if depDomain is set, else Nothing.
renderDomainMapping :: Deployment -> Maybe BS.ByteString
renderDomainMapping dep = fmap (Yaml.encode . domainValue dep) (depDomain dep)

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> A.Value
serviceValue dep tag = A.object
  [ "apiVersion" A..= ("serving.knative.dev/v1" :: Text)
  , "kind"       A..= ("Service" :: Text)
  , "metadata"   A..= A.object
      [ "name"      A..= depName dep
      , "namespace" A..= depNamespace dep
      ]
  , "spec"       A..= A.object
      [ "template" A..= templateValue dep tag ]
  ]

templateValue :: Deployment -> Text -> A.Value
templateValue dep tag = A.object $
  [ "metadata" A..= templateMeta dep
  , "spec"     A..= A.object [ "containers" A..= [containerValue dep tag] ]
  ]

templateMeta :: Deployment -> A.Value
templateMeta dep =
  case depScale dep of
    Nothing -> A.object []
    Just s  -> A.object
      [ "annotations" A..= A.object
          [ "autoscaling.knative.dev/min-scale" A..= show (scaleMin s)
          , "autoscaling.knative.dev/max-scale" A..= show (scaleMax s)
          ]
      ]

containerValue :: Deployment -> Text -> A.Value
containerValue dep tag =
  A.object $ concat
    [ [ "image" A..= (depImage dep <> ":" <> tag)
      , "ports" A..= [A.object ["containerPort" A..= depPort dep]]
      ]
    , if Map.null (depEnv dep) then []
      else [("env", envValue (depEnv dep))]
    , case depResources dep of
        Nothing -> []
        Just r  -> [("resources", resourcesValue r)]
    ]

envValue :: Map Text EnvVar -> A.Value
envValue m = A.Array . foldMap singleton . Map.toAscList $ m
  where
    singleton (name, EnvLiteral v) = pure $ A.object
      [ "name"  A..= name
      , "value" A..= v
      ]
    singleton (name, EnvSecretRef secret) = pure $ A.object
      [ "name" A..= name
      , "valueFrom" A..= A.object
          [ "secretKeyRef" A..= A.object
              [ "name" A..= secret
              , "key"  A..= name
              ]
          ]
      ]
    foldMap f = foldr ((<>) . f) mempty

resourcesValue :: Resources -> A.Value
resourcesValue r = A.object
  [ "requests" A..= A.object (catMaybes
      [ fmap ("cpu"    A..=) (resCpu r)
      , fmap ("memory" A..=) (resMemory r)
      ])
  ]
  where
    catMaybes = foldr (\mx acc -> maybe acc (:acc) mx) []

domainValue :: Deployment -> Text -> A.Value
domainValue dep domain = A.object
  [ "apiVersion" A..= ("serving.knative.dev/v1beta1" :: Text)
  , "kind"       A..= ("DomainMapping" :: Text)
  , "metadata"   A..= A.object
      [ "name"      A..= domain
      , "namespace" A..= depNamespace dep
      ]
  , "spec"       A..= A.object
      [ "ref" A..= A.object
          [ "apiVersion" A..= ("serving.knative.dev/v1" :: Text)
          , "kind"       A..= ("Service" :: Text)
          , "name"       A..= depName dep
          ]
      ]
  ]
```

**M1.7 — Build to confirm the library compiles.** From
`docs/spikes/ep8-substrate-spike/`:

```bash
cabal build spike-lib
```

Expected:

```text
Build profile: -w ghc-9.4.x -O1
...
[1 of 2] Compiling Spike.Types ...
[2 of 2] Compiling Spike.Render ...
```

Any type error here must be fixed before proceeding to M2. The three executable stanzas will
fail to compile until their `app/Proto*.hs` files are written; that is expected.

---

### M2 — Prototype 1: config-as-program

**M2.1 — Write the hello config file.** Create
`docs/spikes/ep8-substrate-spike/hello/Config.hs`. This is the file an imagined app author would
ship. It imports the spike DSL library and binds a top-level `deployment :: Deployment`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Hello app deployment descriptor — Prototype 1 / Prototype 2 shared input.
-- An app author writes this file. nagarectl compiles-and-runs it (P1) or
-- interprets it at runtime (P2) to obtain the Deployment value.
module Config (deployment) where

import Data.Map.Strict (fromList)
import Spike.Types

deployment :: Deployment
deployment = Deployment
  { depName      = "hello"
  , depNamespace = "personal"
  , depImage     = "us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello"
  , depPort      = 8080
  , depEnv       = fromList
      [ ("DATABASE_URL", EnvSecretRef "hello-db-url")
      , ("LOG_LEVEL",    EnvLiteral   "info")
      ]
  , depResources = Just (Resources (Just "250m") (Just "512Mi"))
  , depScale     = Just (Scale 0 3)
  , depDomain    = Nothing
  }
```

**M2.2 — Write `app/Proto1.hs`.** This executable locates `hello/Config.hs`, writes a small
wrapper `Main.hs` to a temp directory that imports `Config` and calls `Spike.Render.renderService
deployment "20260602-120000"` then `BS.putStr`, shells out to `runghc` with the spike library on
the GHC include path, captures stdout, and diffs it against `hello/golden.yaml`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Cradle
import qualified Data.ByteString       as BS
import           System.Exit           (exitFailure, exitSuccess)
import           System.FilePath       ((</>))
import           System.Directory      (getCurrentDirectory, makeAbsolute)

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  -- We invoke runghc with -i<spikeDir>/src -i<spikeDir>/hello so that
  -- GHC can find both Spike.* and Config.
  let srcDir  = spikeDir </> "src"
      helloDir = spikeDir </> "hello"
      wrapper  = spikeDir </> "helper" </> "RunConfig.hs"
  got <- fmap fromStdout $
    run $ cmd "runghc"
        & addArgs [ "-i" <> srcDir
                  , "-i" <> helloDir
                  , wrapper
                  ]
  golden <- BS.readFile (helloDir </> "golden.yaml")
  if got == golden
    then putStrLn "PASS: output matches golden target" >> exitSuccess
    else do
      putStrLn "FAIL: output does not match golden target"
      putStrLn "--- got ---"
      BS.putStr got
      putStrLn "--- expected ---"
      BS.putStr golden
      exitFailure
```

You also need a small driver file at
`docs/spikes/ep8-substrate-spike/helper/RunConfig.hs` that the `runghc` invocation executes:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString as BS
import           Config          (deployment)
import           Spike.Render    (renderService)

main :: IO ()
main = BS.putStr (renderService deployment "20260602-120000")
```

Add `helper/` as a directory; it is not a Cabal source dir — it is data consumed by the
prototype at runtime. The proto1 executable must be run from the
`docs/spikes/ep8-substrate-spike/` directory so that relative paths resolve correctly.

Note on `fromStdout`: `cradle`'s output type `StdoutRaw` or the `run` polymorphic output needs
to be matched to `BS.ByteString`. Check
`/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle/src/Cradle.hs` for the exact output
type names; as of the committed corpus they include `StdoutTrimmed` (trims trailing whitespace)
and raw variants. Use the raw variant to preserve exact bytes. If `cradle` does not expose a raw
`ByteString` output, write stdout to a temp file instead:

```haskell
-- Alternative: write to temp file and read back
import System.IO.Temp (withSystemTempFile)
import System.IO      (hClose)

withSystemTempFile "proto1-out.yaml" $ \fp h -> do
  hClose h
  run_ $ cmd "runghc"
       & addArgs [ "-i" <> srcDir, "-i" <> helloDir
                 , "-e", "import qualified Data.ByteString as BS; import Config; import Spike.Render; BS.writeFile " <> show fp <> " (renderService deployment \"20260602-120000\")"
                 , helloDir </> "Config.hs"
                 ]
  got <- BS.readFile fp
  ...
```

**M2.3 — Add `helper/` directory and `mkdir app`.** From
`docs/spikes/ep8-substrate-spike/`:

```bash
mkdir -p helper app
```

**M2.4 — Build and run Prototype 1.** From
`docs/spikes/ep8-substrate-spike/`:

```bash
cabal build proto1-config-as-program
cabal run proto1-config-as-program
```

Expected:

```text
PASS: output matches golden target
```

If the output does not match, run the diff manually to diagnose:

```bash
cabal run proto1-config-as-program 2>&1 | diff - hello/golden.yaml
```

Fix any rendering discrepancy in `Spike.Render` (not in `Config.hs`; the app-side file is fixed
as the input). Common failure modes: annotation values not quoted as strings (the YAML encoder
must emit `'0'` not `0`); env entries not sorted alphabetically; extraneous or missing blank
lines between YAML blocks. Each fix must keep the golden file unchanged — adjust the renderer
to match the golden, not vice versa.

**M2.5 — Scoring evidence for the broken-config test (criterion b).** Modify
`hello/Config.hs` temporarily, changing `depName = "hello"` to `depName = "Hello_Bad"`. Re-run
`cabal run proto1-config-as-program`. Note the exact output: does the tool reject the bad name?
At the spike level, `Spike.Types.Deployment` has no smart constructor for `depName`, so the bad
name silently passes through and the rendered YAML contains `name: Hello_Bad`. Record this
observation in Surprises — it is the evidence for criterion (a) score of 1 for this prototype
at the spike level, while also showing the score would rise to 5 in EP-9's production type.
Restore `Config.hs` afterward.

---

### M3 — Prototype 2: interpreter

**M3.1 — Investigate `hint` availability.**

```bash
# Check mori corpus (expected: no matches)
mori registry search hint

# Attempt to obtain hint from Hackage; add it to spike.cabal's proto2 stanza
# and run cabal build to see if it resolves:
cabal build proto2-interpreter 2>&1 | head -40
```

Also check whether the `ghc` boot library (available as GHC's own package, always present when
GHC is installed) and `ghc-paths` (a tiny Hackage package that exposes `GHC.Paths.libdir`) can
be used as a fallback:

```bash
# In a cabal repl, check what's available:
cabal repl --build-depends "ghc, ghc-paths"
# At the prompt:
import GHC.Paths (libdir)
libdir
```

Record in the Decision Log one of three verdicts:
- `hint` obtained and resolves cleanly → use `hint`;
- `hint` fails but `ghc` + `ghc-paths` works → use GHC API directly;
- neither works in a reasonable time → "interpreter path infeasible" verdict; implement a stub
  that prints the diagnostic and records the exact error, then proceed to M4.

**M3.2 — Write `app/Proto2.hs` using `hint` (preferred path).** If `hint` is available, add it
to the `proto2-interpreter` stanza's `build-depends` and implement:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Language.Haskell.Interpreter (runInterpreter, interpret, as,
                                               loadModules, setTopLevelModules,
                                               set, searchPath, OptionVal(..))
import qualified Data.ByteString               as BS
import           Data.Time.Clock               (getCurrentTime)
import           Spike.Types
import           Spike.Render                  (renderService)
import           System.Exit                   (exitFailure, exitSuccess)
import           System.FilePath               ((</>))
import           System.Directory              (getCurrentDirectory)

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  let configPath = spikeDir </> "hello" </> "Config.hs"
      srcPath    = spikeDir </> "src"
  result <- runInterpreter $ do
    set [searchPath := [srcPath, spikeDir </> "hello"]]
    loadModules [configPath]
    setTopLevelModules ["Config"]
    interpret "deployment" (as :: Deployment)
  case result of
    Left err  -> print err >> exitFailure
    Right dep -> do
      let got    = renderService dep "20260602-120000"
          golden = spikeDir </> "hello" </> "golden.yaml"
      want <- BS.readFile golden
      if got == want
        then putStrLn "PASS: output matches golden target" >> exitSuccess
        else do
          putStrLn "FAIL: output does not match golden target"
          BS.putStr got
          exitFailure
```

Note: `hint` requires that the types used in `interpret ... as :: T` are visible to both the
interpreter and the host program. Since `Spike.Types.Deployment` is defined in the `spike-lib`
library (which both `proto2-interpreter` and the interpreted `Config.hs` import), the package
database must include `spike-lib`. This works when running via `cabal run` because cabal adds the
local library to the package database; it is a key operational concern captured in criterion (e).

**M3.3 — GHC API fallback (if `hint` is unavailable).** If `hint` cannot be obtained, add
`ghc` and `ghc-paths` to the `proto2-interpreter` stanza's `build-depends` and implement a
minimal interpreter using `GHC.runGhcT`. The GHC API is considerably more verbose; a minimal
sketch:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import GHC
import GHC.Paths     (libdir)
import DynFlags
import Outputable
import System.Exit   (exitFailure, exitSuccess)

-- NOTE: The GHC API changes significantly between GHC versions.
-- This sketch targets GHC 9.4; adjust the DynFlags API as needed.
main :: IO ()
main = do
  result <- runGhc (Just libdir) $ do
    dflags <- getSessionDynFlags
    _ <- setSessionDynFlags dflags
    -- Add spike-lib source dir to import search path
    let dflags' = dflags { importPaths = ["src", "hello"] }
    _ <- setSessionDynFlags dflags'
    target <- guessTarget "hello/Config.hs" Nothing
    setTargets [target]
    _ <- load LoadAllTargets
    modSum <- getModSummary (mkModuleName "Config")
    parsedMod <- parseModule modSum
    typedMod  <- typecheckModule parsedMod
    -- Extracting a runtime value from the GHC API requires Template Haskell
    -- or a splice step; this is the key limitation that makes the raw GHC API
    -- harder than hint for this use case.
    -- Record this as a finding in Surprises.
    return ()
  ...
```

The raw GHC API does not provide a clean `interpret "deployment" as :: Deployment` path without
either Template Haskell or running the compiled code in a subprocess — which is effectively the
same as Prototype 1. Record this observation in Surprises; it is direct evidence for criterion
(e) and (a).

**M3.4 — Validate M3.** From `docs/spikes/ep8-substrate-spike/`:

```bash
cabal run proto2-interpreter
```

Expected (if `hint` works):

```text
PASS: output matches golden target
```

Expected (if interpreter path is infeasible):

```text
InterpreterError: ... [exact error text] ...
FAIL: interpreter path infeasible — see Decision Log
```

Either outcome is acceptable; the scoring table will reflect the evidence.

**M3.5 — Timing measurement for criterion (d).** Measure evaluation latency with `time`:

```bash
time cabal run --verbose=0 proto2-interpreter
```

Record the real time. Compare it against Prototype 1 (`time cabal run --verbose=0
proto1-config-as-program`) and later Prototype 3. This is the raw data for criterion (d).

---

### M4 — Prototype 3: Dhall

**M4.1 — Write `hello/hello.dhall`.** This is the file an app author would ship in the Dhall
substrate. Dhall is a typed, non-Turing-complete functional language; its syntax is close to a
typed JSON with functions and imports. The record type must be compatible with the
`SpikeDhallDeployment` Haskell type defined in M4.2.

```dhall
-- hello/hello.dhall
-- Nagare deployment descriptor for the "hello" app.
-- Dhall record; fields match SpikeDhallDeployment in Proto3.hs.
{ name      = "hello"
, namespace = "personal"
, image     = "us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello"
, port      = 8080
, env       =
    -- Dhall List of { name : Text, kind : < Literal : Text | Secret : Text > }
    [ { varName = "DATABASE_URL"
      , kind    = < Literal : Text | Secret : Text >.Secret "hello-db-url"
      }
    , { varName = "LOG_LEVEL"
      , kind    = < Literal : Text | Secret : Text >.Literal "info"
      }
    ]
, cpuRequest    = Some "250m"
, memoryRequest = Some "512Mi"
, scaleMin      = Some 0
, scaleMax      = Some 3
, domain        = None Text
}
```

Note that Dhall's union type `< Literal : Text | Secret : Text >` maps to Haskell's sum type
`EnvKind = EnvKindLiteral Text | EnvKindSecret Text` via `FromDhall` generic derivation.

**M4.2 — Write `app/Proto3.hs`.** Define a `SpikeDhallDeployment` Haskell record whose shape
matches the Dhall expression, derive `Generic` and `FromDhall`, unmarshal with
`Dhall.inputFile auto`, convert to `Spike.Types.Deployment`, and render.

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString  as BS
import qualified Data.Map.Strict  as Map
import           Data.Text        (Text)
import qualified Dhall
import           GHC.Generics     (Generic)
import           Spike.Render     (renderService)
import           Spike.Types
import           System.Exit      (exitFailure, exitSuccess)
import           System.FilePath  ((</>))
import           System.Directory (getCurrentDirectory)

-- | The Dhall union for env var kind.
data EnvKind
  = Literal !Text
  | Secret  !Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

-- | One env var entry as encoded in hello.dhall.
data DhallEnvEntry = DhallEnvEntry
  { varName :: !Text
  , kind    :: !EnvKind
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

-- | The top-level record shape that hello.dhall must produce.
data SpikeDhallDeployment = SpikeDhallDeployment
  { name          :: !Text
  , namespace     :: !Text
  , image         :: !Text
  , port          :: !Int
  , env           :: ![DhallEnvEntry]
  , cpuRequest    :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , scaleMin      :: !(Maybe Int)
  , scaleMax      :: !(Maybe Int)
  , domain        :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

-- | Convert the Dhall record to the shared Spike.Types.Deployment.
toDeployment :: SpikeDhallDeployment -> Deployment
toDeployment d = Deployment
  { depName      = name d
  , depNamespace = namespace d
  , depImage     = image d
  , depPort      = port d
  , depEnv       = Map.fromList (map toEnvVar (env d))
  , depResources = case (cpuRequest d, memoryRequest d) of
      (Nothing, Nothing) -> Nothing
      (c, m)             -> Just (Resources c m)
  , depScale     = case (scaleMin d, scaleMax d) of
      (Just mn, Just mx) -> Just (Scale mn mx)
      _                  -> Nothing
  , depDomain    = domain d
  }

toEnvVar :: DhallEnvEntry -> (Text, EnvVar)
toEnvVar e = (varName e, case kind e of
  Literal v -> EnvLiteral v
  Secret  s -> EnvSecretRef s)

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  let dhallPath = spikeDir </> "hello" </> "hello.dhall"
      goldenPath = spikeDir </> "hello" </> "golden.yaml"
  dhallDep <- Dhall.inputFile Dhall.auto dhallPath
  let dep = toDeployment dhallDep
      got = renderService dep "20260602-120000"
  want <- BS.readFile goldenPath
  if got == want
    then putStrLn "PASS: output matches golden target" >> exitSuccess
    else do
      putStrLn "FAIL: output does not match golden target"
      BS.putStr got
      exitFailure
```

Key note on `Dhall.FromDhall` generic derivation: `DeriveAnyClass` must be enabled and both
`GHC.Generics` and `Dhall` must be imported. The `GenericFromDhall` mechanism in
`Dhall.Marshal.Decode` (source at
`/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall/src/Dhall/Marshal/Decode.hs`)
derives decoders from the GHC generic `Rep`. Union constructors must match the Dhall union
alternative names exactly (case-sensitive). If the names do not align, use the manual `record`
/ `field` / `union` / `constructor` combinators instead:

```haskell
-- Manual decoder for EnvKind (use if generic derivation fails):
envKindDecoder :: Dhall.Decoder EnvKind
envKindDecoder = Dhall.union
  (   (Literal <$> Dhall.constructor "Literal" Dhall.strictText)
  <>  (Secret  <$> Dhall.constructor "Secret"  Dhall.strictText)
  )
```

**M4.3 — Validate M4.** From `docs/spikes/ep8-substrate-spike/`:

```bash
cabal build proto3-dhall
cabal run proto3-dhall
```

Expected:

```text
PASS: output matches golden target
```

**M4.4 — Reuse demonstration for criterion (c).** Extend `hello/hello.dhall` with a Dhall
function that factors out a shared shape. Create a second file,
`docs/spikes/ep8-substrate-spike/hello/prelude.dhall`:

```dhall
-- hello/prelude.dhall
-- A shared "web service" shape.  App configs import this and override as needed.
let webService =
  \(appName : Text) ->
  \(img : Text) ->
    { name          = appName
    , namespace     = "personal"
    , image         = img
    , port          = 8080
    , env           = [] : List { varName : Text
                                , kind    : < Literal : Text | Secret : Text > }
    , cpuRequest    = Some "250m"
    , memoryRequest = Some "512Mi"
    , scaleMin      = Some 0
    , scaleMax      = Some 3
    , domain        = None Text
    }
in webService
```

Then rewrite `hello/hello.dhall` to import and extend it:

```dhall
let webService = ./prelude.dhall

let hello = webService "hello" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello"

in hello // {
     env =
       [ { varName = "DATABASE_URL"
         , kind    = < Literal : Text | Secret : Text >.Secret "hello-db-url"
         }
       , { varName = "LOG_LEVEL"
         , kind    = < Literal : Text | Secret : Text >.Literal "info"
         }
       ]
   }
```

Re-run `cabal run proto3-dhall` and confirm it still prints `PASS`. Record the ergonomics
observation in the scoring table for criterion (c): the `//` override operator composes the
preset with the env overlay without copy-paste, and Dhall's type-checker validates the result.

**M4.5 — Broken-config test for criterion (b).** Modify `hello.dhall` temporarily, changing
`"hello"` to `"Hello_Bad"` in the `name` field. Re-run `cabal run proto3-dhall` and observe
whether Dhall's type system catches it. At the Dhall level, `name : Text` accepts any `Text`, so
the bad name passes through — the same score 1 on type-safety as Prototype 1 at the spike level.
Note, however, that the Dhall substrate could express a refined type for name using a Dhall
function that validates and fails with an informative error; record this in Surprises.
Restore `hello.dhall` afterward.

---

### M5 — Scoring and decision

**M5.1 — Complete the scoring table.** Fill in this table in the Decision Log entry for M5
(not here in Concrete Steps — the Decision Log is the authoritative record):

| Criterion | P1: config-as-program | P2: interpreter | P3: Dhall |
|-----------|----------------------|-----------------|-----------|
| (a) Type-safety / unrepresentable invariants | ? / 5 | ? / 5 | ? / 5 |
| (b) Error-message quality (broken-config) | ? / 5 | ? / 5 | ? / 5 |
| (c) Reuse ergonomics (webService + env overlay) | ? / 5 | ? / 5 | ? / 5 |
| (d) Build/eval latency + dependency-closure weight | ? / 5 | ? / 5 | ? / 5 |
| (e) Operational complexity (what must be on PATH at deploy time) | ? / 5 | ? / 5 | ? / 5 |
| **Total** | **?/25** | **?/25** | **?/25** |

Scoring guidance (record brief evidence for each cell):

For **(a)**: score 5 if the substrate's type system can reject a bad name, a value+secretRef
env var, and a max<min scale without any runtime validation code. Score 3 if it can express
one or two of the three invariants at the type level. Score 1 if all three require runtime
checks. At the spike level, all three prototypes score 1 on their own (the shared `Spike.Types`
type has no smart constructors); but the question is: how well does each substrate *support
lifting* these invariants? A native Haskell eDSL scores 5 for (a) because EP-9 can add
refined newtypes and smart constructors with hidden constructors trivially. The Dhall substrate
scores 3-4 because Dhall can express some constraints (non-empty strings, bounded naturals via
assertions) but not arbitrary Haskell newtype invariants without the marshalling layer. The
interpreter candidate scores the same as config-as-program on this axis because it evaluates
the same Haskell source.

For **(b)**: show the exact error text each prototype (or its substrate) produces for the
`"Hello_Bad"` name input. For the Haskell eDSL paths (P1, P2), the error at spike level is
silence (the rendered YAML contains the bad name); in production with EP-9's smart constructor
the error would be a Haskell type or constructor error at compile/load time. For Dhall, the
error is also silence at the spike level but a Dhall assertion error if a guard is added.

For **(c)**: the Prototype 1 reuse test is: add a `webService :: Text -> Text -> Deployment`
Haskell function in a shared module, import it in `Config.hs`, and define `deployment =
webService "hello" "..." & \d -> d { depEnv = ... }`. Prototype 2 reuse is identical (same
source file). Prototype 3 reuse is the Dhall function in `prelude.dhall` demonstrated in M4.4.
Score each on: is composition natural? Does the type-checker validate the result? Can the
shared shape be published and imported without copy-paste?

For **(d)**: use the `time cabal run` results from M2.4, M3.4, and M4.3. Count additional
packages each prototype introduces beyond what the production DSL (`aeson`, `yaml`, `text`,
`bytestring`, `containers`) already requires. For P1: `cradle` (small; already in scope).
For P2: `hint` plus its closure (if used); or the `ghc` boot library (already installed, 0
new packages but large). For P3: `dhall` and its dependencies (substantial: `megaparsec`,
`prettyprinter`, `http-client`, `cryptonite`, etc. — list the actual transitive closure from
`cabal freeze`).

For **(e)**: state what must be present on the machine running `nagarectl deploy`. P1:
`runghc` (or `cabal`), which means GHC must be installed; if the user is on a machine without
GHC, they cannot deploy. P2: same as P1 plus the interpreter package database; even harder to
ship. P3: only the compiled `nagarectl` binary, because the `dhall` library is a Haskell library
linked into the binary — no external language runtime.

**M5.2 — Write the decision.** Based on the table, enter a Decision Log entry in *this plan*
(see format in the Decision Log section). The entry must name the winning substrate, cite the
total score, identify the one or two criteria that were decisive, and acknowledge the trade-offs
of the choice. If the decision is not unanimous (i.e., the winner is not clear from the totals),
the tiebreaker criterion is (e) operational complexity, because the Nagare user deploys from
their local machine and cannot guarantee GHC is installed.

**M5.3 — Note for the parent MasterPlan.** The implementer must manually add a Decision Log
entry to `docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md` recording the
substrate chosen by this plan, citing EP-8's Decision Log. This plan does not edit the parent
file automatically (to avoid unreviewed cross-file mutations). The parent MasterPlan's entry
should also mark EP-8 status in the Exec-Plan Registry as "Complete".


## Validation and Acceptance

Acceptance for this plan is behavioral and documented. There are three acceptance gates.

**Gate 1 — All three prototypes print `PASS`.** Run from
`docs/spikes/ep8-substrate-spike/` inside `nix develop`:

```bash
cabal run proto1-config-as-program
cabal run proto2-interpreter
cabal run proto3-dhall
```

Each must print `PASS: output matches golden target`. Alternatively, confirm byte-exact
equality explicitly:

```bash
# For prototype 1: pipe its output to diff against golden
cabal run --verbose=0 proto1-config-as-program 2>/dev/null | \
  diff - hello/golden.yaml && echo "proto1: byte-identical"

# For prototype 3 (redirect stdout from the executable):
cabal run --verbose=0 proto3-dhall 2>/dev/null | \
  diff - hello/golden.yaml && echo "proto3: byte-identical"
```

If Prototype 2 is infeasible, Gate 1 for P2 is satisfied by a written "infeasible" verdict in
the Decision Log with the exact error and an explanation of why the interpreter path cannot
produce a `PASS`.

**Gate 2 — The scoring table is complete.** Every cell of the five-by-three table in the M5
Decision Log entry is filled in with a score and a one-line evidence note. No empty cells.

**Gate 3 — The substrate decision is written.** The Decision Log for M5 in *this plan* contains
a decision entry naming the winning substrate with rationale. A note directs the implementer to
propagate the decision to the parent MasterPlan.

A reviewer can confirm all three gates without cluster access, GCP credentials, or Docker — the
entire spike runs offline.


## Idempotence and Recovery

The spike workspace is entirely additive; no existing file outside `docs/spikes/ep8-substrate-spike/` is modified. Every step can be re-run safely:

Re-running `cabal build` is idempotent. Re-running `cabal run proto<N>` re-runs the prototype
and re-compares against the golden file; as long as `hello/golden.yaml` is not modified, the
result is stable. If a prototype exits with `FAIL`, diagnose by examining the diff output printed
to stdout, fix `Spike.Render` (not `hello/golden.yaml`), and re-run.

If the `cabal.project` corpus paths break (e.g., the mori corpus is moved), update the paths in
`cabal.project` and re-run `cabal build`. The workspace has no network dependency except for
Hackage packages (`aeson`, `yaml`, `hint` if used); if offline, ensure those packages are in the
local cabal store (`~/.cabal/store`).

The golden file `hello/golden.yaml` must never be modified. If you suspect the renderer is
correct but the golden differs, re-read EP-6's "What the renderer must produce" section verbatim
and reconcile. The golden file is the contract, not a test artifact to regenerate.


## Interfaces and Dependencies

**Packages used and why.**

- `aeson` + `yaml` (Hackage) — building and serializing the Knative YAML object graph in
  `Spike.Render`. Same combination as EP-6's `Nagare.Render`.
- `containers` (Hackage, boot) — `Data.Map.Strict` for the sorted env map.
- `text` + `bytestring` (Hackage, boot) — string types throughout.
- `cradle` (corpus: `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`) — shelling out
  to `runghc` in Prototype 1. Not used by Prototypes 2 or 3.
- `dhall` (corpus:
  `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`) — decoding
  `hello.dhall` in Prototype 3. The key API surface used: `Dhall.inputFile :: Decoder a ->
  FilePath -> IO a`, `Dhall.auto :: FromDhall a => Decoder a`, `Dhall.FromDhall` typeclass with
  generic derivation (`DeriveGeneric` + `DeriveAnyClass`), and manual combinators `Dhall.record`,
  `Dhall.field`, `Dhall.union`, `Dhall.constructor`, `Dhall.strictText`.
- `hint` (Hackage, if available) — embedding the GHC interpreter in Prototype 2. If unavailable,
  replaced by the `ghc` boot library + `ghc-paths` (Hackage). Both require GHC present at
  runtime.
- `directory` + `filepath` (Hackage, boot) — resolving file paths in all three executables.

**Types that must exist at the end of each milestone.**

After M1: `Spike.Types.Deployment`, `Spike.Types.EnvVar` (`EnvLiteral Text | EnvSecretRef
Text`), `Spike.Types.Resources`, `Spike.Types.Scale` in module `Spike.Types`; and
`Spike.Render.renderService :: Deployment -> Text -> BS.ByteString`,
`Spike.Render.renderDomainMapping :: Deployment -> Maybe BS.ByteString` in module `Spike.Render`.

After M2: the Prototype 1 executable runs and compares output to the golden file.

After M3: the Prototype 2 executable runs and prints `PASS` or a documented `FAIL` verdict.

After M4: `Proto3.Main.SpikeDhallDeployment` (a record deriving `Generic` and `FromDhall`),
`Proto3.Main.EnvKind` (a sum type deriving `Generic` and `FromDhall`), and the Prototype 3
executable prints `PASS`.

After M5: the Decision Log contains the substrate decision; the scoring table is complete.

**What this plan does NOT define or touch.** The production `Nagare.Dsl.Types.Deployment`
type (EP-9), the production `Nagare.Dsl.Render` module (EP-9), the loader
`Nagare.Dsl.Load.loadDeployment` (EP-10), the `cli/nagare-dsl/` Cabal library (EP-9), the
`cli/nagarectl/` executable (EP-12), and the `nagare.yaml` schema (EP-6). No file outside
`docs/spikes/ep8-substrate-spike/` is created or modified by this plan.
