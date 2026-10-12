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

Full plan before trimming: [8-config-substrate-evaluation-spike-and-decision.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/8-config-substrate-evaluation-spike-and-decision.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

