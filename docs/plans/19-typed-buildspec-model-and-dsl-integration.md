---
id: 19
slug: typed-buildspec-model-and-dsl-integration
title: "Typed BuildSpec model and DSL integration"
kind: exec-plan
created_at: 2026-06-09T23:51:00Z
intention: "intention_01ktqcgfx8end8kwp5ejmy0k6q"
master_plan: "docs/masterplans/4-application-build-modes-for-nagare.md"
---

# Typed BuildSpec model and DSL integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan is the first of four under the MasterPlan
`docs/masterplans/4-application-build-modes-for-nagare.md` ("Application Build Modes for
Nagare"). It adds a typed way to say *how* a Nagare application's container image is produced.

Today an application deployment is described by a `Deployment` value in a user's `nagare/Config.hs`,
and the image is always built from a hand-written `Dockerfile` by `nagarectl deploy`. There is no
typed way to express "this image already exists, just deploy it" or "build this with a tool other
than a raw Dockerfile". After this plan, the `Deployment` model carries a new `build` field of a
new type `BuildSpec` with three variants: `PrebuiltImage` (deploy an existing image by tag, build
nothing), `DockerfileBuild` (build from a named Dockerfile and context with build arguments), and
`NixpacksBuild` (build from source with no Dockerfile — execution arrives in a later plan,
`docs/plans/21-nixpacks-zero-dockerfile-builder.md`).

This plan is **library-only**: it changes the `nagare-dsl` Haskell package and nothing in the CLI.
You can see it working by running the package's test suite (`cabal test` in `cli/nagare-dsl`): new
golden files show a `Deployment` with each build mode emitting and round-tripping correctly, and a
prebuilt-image deployment renders a Knative Service whose container image carries the prebuilt
tag rather than a freshly computed one. The CLI work that actually performs the builds lives in
`docs/plans/20-build-mode-execution-in-nagarectl-deploy.md` and is out of scope here.

A note on terms used throughout. A **smart constructor** is a function named `mkX` that validates
its inputs and returns `Either Text X`, where the data constructor of `X` is hidden so the only
way to build a value is through `mkX`. An **`ImageRef`** is a container image repository path
*without* a tag, e.g. `us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes`; the tag is appended
separately. A **golden test** compares generated output (here, emitted JSON or rendered YAML)
against a checked-in expected file; if they differ the test fails and prints a diff. **Nixpacks**
is an open-source command-line tool that inspects a source directory, auto-detects its language
and framework, and builds an OCI container image without a Dockerfile; this plan only adds the
*type* for it, not the build itself.


## Progress

- [x] Milestone 1: `Tag`, `BuildSpec`, and the `Nagare.Dsl.Build` module exist and are exposed from the cabal file; `resolveImageTag` and `requiresBuild` compile.
- [x] Milestone 2: `Deployment` has a `build` field; `webService` preset defaults it to a Dockerfile build; all in-repo fixtures and example configs updated and the package builds.
- [x] Milestone 3: JSON emission (`Nagare.Dsl.Config`) and loading (`Nagare.Dsl.Load`) handle all three build kinds with a `"kind"` discriminator and precise `MarshalError`s.
- [x] Milestone 4: the renderer (`Nagare.Dsl.Render`) uses `resolveImageTag` so a prebuilt image renders with its own tag.
- [x] Milestone 5: golden files and round-trip/unit tests added; `cabal test` passes for all three modes plus failure cases.


## Surprises & Discoveries

- The import-cycle the plan anticipated is real: `Deployment` (in `Nagare.Dsl.Types`)
  needs `BuildSpec` (in `Nagare.Dsl.Build`), which needs `FilePathText` — and
  `FilePathText` lived in `Nagare.Dsl.Static.Types`, which imports
  `Nagare.Dsl.Types` for `Domain`/`ImageRef`/`Namespace`. That closes the loop
  `Types -> Build -> Static.Types -> Types`. The plan's suggested fix (move
  `FilePathText` into `Nagare.Dsl.Types`) does **not** resolve it — it would make
  `Build` import `Types` and `Types` import `Build`, a direct two-module cycle.
  Resolution taken: extract `FilePathText`/`mkFilePathText`/`filePathText` into a
  new leaf module `Nagare.Dsl.Path` that depends only on `text`. `Build` imports
  `Path`; `Static.Types` re-exports `FilePathText` from `Path` so every existing
  importer is unaffected. See Decision Log.

- The `build` field is decoded as **optional with a default** (`o .:? "build"`,
  defaulting to the standard Dockerfile build) rather than the strictly-required
  `o .: "build"` the plan sketched. Reason: pre-`BuildSpec` deployment JSON (and
  the hand-written JSON fixtures in `test/LoadSpec.hs`, which omit `build`) must
  still decode — they are designed to fail at the `name`/`scale` smart
  constructors, which a required `build` would pre-empt with a JSON parse error.
  Optional-with-default is also strictly backward-compatible and matches the
  MasterPlan decision to make the default mode reproduce today's behavior.

- Added one exported helper not in the plan's signature list: `encodeDeployment ::
  Deployment -> ByteString` in `Nagare.Dsl.Config` (the pure bytes `emitDeployment`
  writes). It makes the emit→decode round-trip testable in-process without
  capturing stdout or spawning `runghc`. `emitDeployment` is now `LBS.putStr .
  encodeDeployment`; its `IO ()` signature is unchanged.


## Decision Log

- Decision: Put `BuildSpec`, `Tag`, and the `resolveImageTag`/`requiresBuild` helpers in a new
  module `Nagare.Dsl.Build` rather than in `Nagare.Dsl.Types`.
  Rationale: `Nagare.Dsl.Types` is already large and holds only leaf newtypes; a dedicated module
  keeps the build concept cohesive and gives the CLI a single import. The helpers are pure and
  shared by both the renderer (this plan) and the CLI (EP-20), so they belong with the type.
  Date: 2026-06-09

- Decision: Reuse `FilePathText` from `Nagare.Dsl.Static.Types` for the `context` and `dockerfile`
  path fields instead of inventing a new path newtype.
  Rationale: `FilePathText` already rejects empty, absolute, and `..`-escaping paths, exactly the
  validation we want for a build context and Dockerfile path. Reusing it avoids duplicate
  validation logic. Milestone 1 verifies that `mkFilePathText "."` succeeds (the default context);
  if it does not, the fallback is to relax `mkFilePathText` to accept a lone `.` and re-run the
  static golden tests, which must stay green.
  Date: 2026-06-09

- Decision: `PrebuiltImage` carries a `Tag`; `Deployment.image` stays a tagless `ImageRef` for all
  modes.
  Rationale: Preserves the existing renderer contract and `mkImageRef` validation; see the
  MasterPlan Decision Log for the full rationale.
  Date: 2026-06-09

- Decision: Break the `Types -> Build -> Static.Types -> Types` import cycle by extracting
  `FilePathText`/`mkFilePathText`/`filePathText` into a new leaf module `Nagare.Dsl.Path` (depending
  only on `text`), rather than moving them into `Nagare.Dsl.Types` as the plan's fallback suggested.
  Rationale: Moving `FilePathText` into `Types` would not help — `Build` would then import `Types`
  for `FilePathText` while `Types` imports `Build` for `BuildSpec`, a direct two-module cycle. A
  dedicated leaf module that imports neither `Types` nor `Build` is the only acyclic option that
  keeps `Build` separate. `Static.Types` re-exports `FilePathText` from `Path`, so every existing
  importer (`Server.Types`, `Config`, `Load`, `Static.Render`, the CLI) is unchanged.
  Date: 2026-06-09

- Decision: Decode the `Deployment.build` field as optional-with-default (`o .:? "build"` defaulting
  to the Dockerfile build) rather than strictly required.
  Rationale: Backward compatibility with pre-`BuildSpec` JSON and with the existing `LoadSpec` JSON
  fixtures (which omit `build` and are designed to fail at the `name`/`scale` constructors). A
  required field would turn those into JSON parse errors. Matches the MasterPlan default-preserving
  decision.
  Date: 2026-06-09


## Outcomes & Retrospective

Delivered. `cli/nagare-dsl` now carries a typed `BuildSpec` (`PrebuiltImage`,
`DockerfileBuild`, `NixpacksBuild`) on `Deployment`, with a `Tag` newtype,
`resolveImageTag`/`requiresBuild`/`defaultBuild` helpers, `"kind"`-tagged JSON
emission and loading for all three modes, and a renderer that honors a prebuilt
image's embedded tag. `cabal test` passes (135 tests, including a new
`Nagare.Dsl.Build` group covering all three modes, the two helpers, the renderer,
emit→decode round-trips, and the failure cases: empty/invalid tag, absolute
context, unknown `build.kind`). The `nagarectl` package still builds against the
new required field (it only reads `Deployment` via lenses; no literal to update).

Key deviation from the written plan: `FilePathText` was extracted into a new leaf
module `Nagare.Dsl.Path` to break the import cycle, rather than moved into
`Nagare.Dsl.Types` (which would have cycled `Types`↔`Build`). See Decision Log
and Surprises.


## Context and Orientation

All paths below are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`.

The DSL package is `cli/nagare-dsl`. Its library modules are declared in
`cli/nagare-dsl/nagare-dsl.cabal` under `exposed-modules`. The files you will read and change:

- `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` — the canonical typed model. It defines leaf newtypes
  (`ServiceName`, `Namespace`, `ImageRef`, `EnvName`, `SecretName`, `Port`, `Quantity`, `Domain`)
  each with a hidden constructor and a smart constructor, the `EnvVar`/`Resources`/`Scale` types,
  and the top-level `Deployment` record. The relevant excerpt today:

  ```haskell
  data Deployment = Deployment
    { name :: !ServiceName
    , namespace :: !Namespace
    , image :: !ImageRef
    , domain :: !(Maybe Domain)
    , port :: !Port
    , env :: !(Map EnvName EnvVar)
    , resources :: !(Maybe Resources)
    , scale :: !(Maybe Scale)
    }
    deriving stock (Generic, Eq, Show)
  ```

  `ImageRef` is constructed by `mkImageRef :: Text -> Either Text ImageRef`, which rejects a colon
  (so the repository path never carries a tag) and reads back with `imageRefText :: ImageRef -> Text`.

- `cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` — defines `FilePathText` (a relative path that
  rejects empty, absolute, and `..` segments) with `mkFilePathText :: Text -> Either Text FilePathText`
  and `filePathText :: FilePathText -> Text`, and the `StaticBuild` sum type
  (`NoBuild`/`BuildCommand`) which is the template to imitate for `BuildSpec`. It is already an
  exposed module, so you can import `FilePathText` from it.

- `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` — serialization. `emitDeployment :: Deployment -> IO ()`
  writes the deployment as JSON to stdout via the helper `deploymentJSON`. The static-site encoder
  `staticSiteJSON` shows the `"kind"`-tagged object pattern you will copy for `build`:

  ```haskell
  buildJSON (NoBuild dir) =
    object [ "kind" .= ("NoBuild" :: Text), "directory" .= filePathText dir ]
  buildJSON (BuildCommand cmd outDir) =
    object [ "kind" .= ("BuildCommand" :: Text), "command" .= cmd
           , "outputDirectory" .= filePathText outDir ]
  ```

- `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` — loading. `loadDeployment` runs the config with `runghc`,
  captures its JSON, and `decodeDeployment :: ByteString -> Either LoadError Deployment` decodes it.
  Inside, `JsonDeployment` is an intermediate record with a `FromJSON` instance and `toDeployment`
  re-runs the smart constructors, mapping failures to `MarshalError "<field>" "<message>"`. The
  static path (`JsonStaticBuild`, `toStaticBuild`) shows how to decode a `"kind"`-tagged sub-object
  and report `MarshalError "build.kind" "unknown build kind: ..."`.

- `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` — rendering. `renderService :: Deployment -> Text -> ByteString`
  takes the deployment and a resolved image tag and produces Knative Service YAML. The container
  image string is built in `containerValue`:

  ```haskell
  containerValue :: Deployment -> Text -> Value
  containerValue dep tag =
    object (required <> optionals)
    where
      imageStr = imageRefText (dep ^. #image) <> ":" <> tag
      ...
  ```

- `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs` — the `webService :: Text -> Text -> Either Text Deployment`
  preset that assembles a `Deployment` record literal. It will not compile once `Deployment` gains a
  required field, so it must be updated.

- `cli/nagare-dsl/test/Spec.hs` and the fixtures under `cli/nagare-dsl/test/fixtures/` and golden
  files under `cli/nagare-dsl/test/golden/` — the test suite uses `tasty` with `tasty-golden`,
  `tasty-hunit`, and `tasty-quickcheck`. There is a deployment fixture at
  `cli/nagare-dsl/test/fixtures/nagare/Config.hs` that emits a `Deployment` and any `Deployment`
  record literals in the repo (this fixture, the `cluster/examples/*/nagare/Config.hs` configs)
  must be updated to add the new field.

Non-obvious detail: the `Deployment` record has no hidden constructor — code assembles it as a
record literal. Adding a required field is therefore a compile-breaking change for every literal,
which is why Milestone 2 updates the preset and all fixtures in the same step.

The cabal file uses `default-extensions` including `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`, and `GHC2024`. The `#field` lens syntax (`dep ^. #build`) is available via
`generic-lens`.


## Plan of Work

### Milestone 1 — The `BuildSpec` type and `Nagare.Dsl.Build` module

Create `cli/nagare-dsl/src/Nagare/Dsl/Build.hs`. Define a `Tag` newtype with a hidden constructor
and `mkTag :: Text -> Either Text Tag` that rejects an empty value, any whitespace, and any
character outside the Docker tag set (`[A-Za-z0-9_.-]`), and that rejects a leading `.` or `-`
(Docker forbids those); expose `tagText :: Tag -> Text`. Define `BuildSpec` exactly as in the
MasterPlan Integration Points, reusing `FilePathText` (imported from `Nagare.Dsl.Static.Types`)
for the `dockerfile` and `context` fields and `Data.Map.Map Text Text` for `buildArgs`. Define and
export the two helpers:

```haskell
resolveImageTag :: BuildSpec -> Text -> Text
resolveImageTag (PrebuiltImage t) _ = tagText t
resolveImageTag _ deployTag = deployTag

requiresBuild :: BuildSpec -> Bool
requiresBuild (PrebuiltImage _) = False
requiresBuild _ = True
```

Add `Nagare.Dsl.Build` to `exposed-modules` in `cli/nagare-dsl/nagare-dsl.cabal`. At the end of this
milestone the module compiles (`cabal build`) and a one-off GHCi check confirms `mkFilePathText "."`
returns `Right`. Acceptance: `cabal build` succeeds and `cabal repl` evaluating
`resolveImageTag (PrebuiltImage <whatever>) "deploytag"` returns the prebuilt tag.

### Milestone 2 — Add the `build` field and preserve the default

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, add `build :: !BuildSpec` to the `Deployment` record.
Because `Types.hs` would otherwise import `Build.hs` while `Build.hs` imports `FilePathText` from
`Static.Types`, keep the dependency direction clean: `BuildSpec` lives in `Nagare.Dsl.Build`, and
`Nagare.Dsl.Types` imports `Nagare.Dsl.Build`. Verify there is no import cycle (`Build` imports only
`Prelude`, `Static.Types`, and `Data.Map`; it must not import `Types`). If a cycle appears, the
resolution is to move `FilePathText` into `Nagare.Dsl.Types` and re-export it from `Static.Types`;
record that in the Decision Log if needed.

Update `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`: in `webService`, add
`build = DockerfileBuild { dockerfile = <mkFilePathText "Dockerfile">, context = <mkFilePathText ".">, buildArgs = Map.empty }`
to the record literal, threading the `mkFilePathText` calls through the existing `Either` do-block
so validation stays explicit. Add a small exported helper `defaultBuild :: Either Text BuildSpec`
in `Nagare.Dsl.Build` (or `Presets`) so example configs can reuse it.

Update every `Deployment` record literal in the repo to add the field: the test fixture
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`, and any `cluster/examples/*/nagare/Config.hs` that
construct a `Deployment` literal directly (grep for `Deployment` to find them). At the end of this
milestone `cabal build` succeeds and the existing tests still compile.

### Milestone 3 — JSON emission and loading for all three kinds

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, extend `deploymentJSON` to add a `"build"` key whose
value is a `"kind"`-tagged object, following the `staticSiteJSON`/`buildJSON` pattern:

```haskell
buildJSON (PrebuiltImage t) =
  object [ "kind" .= ("PrebuiltImage" :: Text), "tag" .= tagText t ]
buildJSON (DockerfileBuild df ctx args) =
  object [ "kind" .= ("DockerfileBuild" :: Text)
         , "dockerfile" .= filePathText df
         , "context" .= filePathText ctx
         , "buildArgs" .= args ]
buildJSON (NixpacksBuild ctx args) =
  object [ "kind" .= ("NixpacksBuild" :: Text)
         , "context" .= filePathText ctx
         , "buildArgs" .= args ]
```

In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, add a `JsonBuildSpec` intermediate with a `FromJSON`
instance reading `kind` plus the optional per-kind fields, add a `jdBuild` field to `JsonDeployment`
and its `FromJSON` instance (`o .: "build"`), and add `toBuildSpec :: JsonBuildSpec -> Either LoadError BuildSpec`
that dispatches on `kind`, re-running `mkTag`/`mkFilePathText` and reporting precise
`MarshalError "build..."` messages (mirroring `toStaticBuild`). Wire `toBuildSpec` into
`toDeployment` so the new field is populated. An unknown kind reports
`MarshalError "build.kind" "unknown build kind: <x>"`. `buildArgs` defaults to empty when absent
(`o .:? "buildArgs" .!= mempty`). At the end of this milestone, `decodeDeployment` round-trips every
mode.

### Milestone 4 — Renderer respects the prebuilt tag

In `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`, change `containerValue` so
`imageStr = imageRefText (dep ^. #image) <> ":" <> resolveImageTag (dep ^. #build) tag`. Import
`resolveImageTag` from `Nagare.Dsl.Build`. The passed `tag` argument keeps its meaning for build
modes; for a `PrebuiltImage` it is ignored in favor of the embedded tag. No signature change to
`renderService`. Acceptance: rendering a `PrebuiltImage "v1.2.3"` deployment with deploy tag
`"20260609-000000"` produces a container image ending in `:v1.2.3`.

### Milestone 5 — Tests and golden files

Add or extend fixtures and golden files under `cli/nagare-dsl/test/`. Create three fixture configs
(or one parameterized fixture) that emit a `Deployment` using each build mode, add golden files for
the emitted JSON and the rendered Knative Service YAML, and extend `cli/nagare-dsl/test/Spec.hs`
(or a new `BuildSpec` test group) to cover: (a) emit→decode round-trips for all three modes;
(b) `resolveImageTag`/`requiresBuild` behavior; (c) the renderer image string for prebuilt vs.
built; (d) failure cases — an empty tag (`mkTag ""`), an invalid tag (`mkTag "-bad"`), an absolute
context path, and an unknown `build.kind` in JSON reporting the right `MarshalError`. Run
`cabal test` and confirm all pass.


## Concrete Steps

Work from the repository root unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Find every `Deployment` record literal that must gain the new field:

```bash
grep -rn "Deployment$\|Deployment {" cli/nagare-dsl/src cli/nagare-dsl/test cluster/examples
```

Inspect the patterns you are imitating before editing:

```bash
sed -n '100,135p' cli/nagare-dsl/src/Nagare/Dsl/Types.hs        # ImageRef + mkImageRef
sed -n '108,130p' cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs # StaticBuild + FilePathText
sed -n '72,99p'   cli/nagare-dsl/src/Nagare/Dsl/Config.hs       # staticSiteJSON build encoding
sed -n '319,334p' cli/nagare-dsl/src/Nagare/Dsl/Load.hs         # toStaticBuild decoding
```

Confirm the default context path validates (Milestone 1 gate):

```bash
cd cli/nagare-dsl
cabal repl nagare-dsl
# in GHCi:
-- > :m + Nagare.Dsl.Static.Types
-- > mkFilePathText "."
-- expect: Right ...
-- > :q
```

Build and test after each milestone:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
cabal test
```

Expected `cabal test` transcript at the end (names illustrative):

```text
nagare-dsl-test
  Deployment golden
    dockerfile build JSON:    OK
    prebuilt image JSON:      OK
    nixpacks build JSON:      OK
  BuildSpec
    resolveImageTag prebuilt: OK
    requiresBuild prebuilt:   OK
    render prebuilt tag:      OK
    mkTag rejects "-bad":     OK
    unknown build.kind:       OK

All N tests passed
```

When a golden test fails on first run because the expected file does not yet exist, create it from
the actual output (tasty-golden writes a `.actual` file or supports `--accept`); review the content
by eye before accepting so the golden encodes the intended JSON/YAML, then re-run `cabal test`.


## Validation and Acceptance

The change is effective beyond compilation when `cabal test` in `cli/nagare-dsl` passes with the new
test group, demonstrating concrete behavior: a `Deployment` whose `build` is `PrebuiltImage "v1.2.3"`
emits JSON containing `"kind":"PrebuiltImage","tag":"v1.2.3"`, decodes back to the same value, and
renders a Knative Service whose `image` ends in `:v1.2.3` regardless of the deploy tag passed to
`renderService`; a `DockerfileBuild` with a custom `dockerfile`/`context`/`buildArgs` round-trips
those fields; a `NixpacksBuild` round-trips its `context`/`buildArgs`; and the failure cases
(`mkTag ""`, `mkTag "-bad"`, an absolute context, an unknown `build.kind`) each produce the expected
`Left`/`MarshalError`. The existing static-site and server-site golden tests must remain green,
proving the change did not disturb those models.


## Idempotence and Recovery

All edits are additive to source files and re-runnable; `cabal build`/`cabal test` are safe to run
repeatedly. The only subtlety is the new required `Deployment` field: if a `Deployment` literal is
missed, the build fails with a clear "missing field `build`" error naming the file, which is the
recovery signal — add the field and rebuild. Golden files are regenerated by deleting the stale
expected file and re-accepting from actual output; because they are checked in, `git checkout` on a
golden file restores the prior expectation if an accept was premature. No cluster, registry, or
network access is involved, so there is nothing to roll back outside the working tree.


## Interfaces and Dependencies

Libraries are already in `cli/nagare-dsl/nagare-dsl.cabal`: `aeson` (JSON), `containers`
(`Data.Map`), `text`, `generic-lens`/`lens` (the `#field` and `^.` syntax), `yaml` (rendering), and
`tasty`/`tasty-golden`/`tasty-hunit`/`tasty-quickcheck` (tests). No new dependency is required.

Signatures that must exist at the end of this plan, in `Nagare.Dsl.Build`:

```haskell
data Tag
mkTag :: Text -> Either Text Tag
tagText :: Tag -> Text

data BuildSpec
  = PrebuiltImage Tag
  | DockerfileBuild { dockerfile :: !FilePathText, context :: !FilePathText, buildArgs :: !(Map Text Text) }
  | NixpacksBuild   { context :: !FilePathText, buildArgs :: !(Map Text Text) }

resolveImageTag :: BuildSpec -> Text -> Text
requiresBuild :: BuildSpec -> Bool
```

In `Nagare.Dsl.Types`, `Deployment` gains `build :: !BuildSpec`. In `Nagare.Dsl.Config`,
`emitDeployment` is unchanged in signature but emits the `build` object. In `Nagare.Dsl.Load`,
`decodeDeployment`/`loadDeployment` are unchanged in signature but populate `build`. In
`Nagare.Dsl.Render`, `renderService`/`containerValue` are unchanged in signature but use
`resolveImageTag`. These exact signatures are what `docs/plans/20-build-mode-execution-in-nagarectl-deploy.md`
imports — do not change them without updating that plan.
