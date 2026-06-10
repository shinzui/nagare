---
id: 26
slug: generated-and-predefined-environment-variables
title: "Generated and predefined environment variables"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Generated and predefined environment variables

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, every app and server site that Nagare deploys automatically receives a
small, documented set of environment variables that describe the deployment's own identity:
its public URL, its service name, its Kubernetes namespace, the apps base domain, the
release id (the image tag), and — when the deploy was triggered from a git source — the
source branch or commit. The names all start with the prefix `NAGARE_` (for example
`NAGARE_SERVICE_URL`). An application can read these at runtime to self-configure instead of
hard-coding values that only the deploy step knows. A Node server that needs to build a link
back to itself can read `process.env.NAGARE_SERVICE_URL`; a script that wants to tag logs
with the running release can read `process.env.NAGARE_RELEASE_ID`. None of this is possible
today: the running container has no idea what URL it answers on or what release it is.

You can see it working by running a deploy in dry-run mode and reading the rendered Knative
`Service` manifest. A **Knative `Service`** is the single YAML resource Nagare applies for an
app; its container spec carries an inline `env:` list (variables written directly into the
manifest) and an `envFrom:` block (variables pulled from external Kubernetes ConfigMaps and
Secrets). Before this change, the inline `env:` shows only what the config author wrote.
After this change, the same `env:` additionally contains the generated `NAGARE_*` variables.

Concretely, deploying a server site named `notes` into namespace `personal` with base domain
`apps.example.com`, image tag `20260602-120000`, and `--source main` renders this difference
in the container's inline `env:` (the user wrote only `API_BASE`):

```diff
         env:
         - name: API_BASE
           value: https://api.example.com
+        - name: NAGARE_BASE_DOMAIN
+          value: apps.example.com
+        - name: NAGARE_NAMESPACE
+          value: personal
+        - name: NAGARE_RELEASE_ID
+          value: "20260602-120000"
+        - name: NAGARE_SERVICE_NAME
+          value: notes
+        - name: NAGARE_SERVICE_URL
+          value: https://notes.personal.apps.example.com
+        - name: NAGARE_SOURCE
+          value: main
         envFrom:
         - configMapRef:
             name: nagare-env-notes-runtime
             optional: true
         - secretRef:
             name: nagare-secret-notes-runtime
             optional: true
```

The generated variables are injected as **inline `env:` entries scoped `{Runtime}`** at
deploy time. This matters for two reasons that this plan relies on. First, the env entries in
a Knative container are sorted by variable name when rendered (the renderer uses
`Data.Map.toAscList`), which is why `NAGARE_*` appears after `API_BASE` and the `NAGARE_*`
entries are themselves alphabetical above. Second, **Kubernetes applies `envFrom` first and
the inline `env:` list second, so an inline variable overrides a managed one of the same
name** (this is the precedence the dependency plan EP-23 establishes; see "Context and
Orientation"). Because the generated variables are inline, they are authoritative: they win
over anything in the managed ConfigMap/Secret store, and — by deliberate design in this plan
— they also win over a user-declared variable of the same `NAGARE_*` name. The `NAGARE_`
prefix is therefore **reserved**: a config author who writes `NAGARE_SERVICE_URL` themselves
will see it silently replaced by the generated value.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Created `cli/nagarectl/src/Nagare/Env/Generated.hs` with `GeneratedContext`,
      `generatedEnv`, and `mergeGenerated`; added it to `nagarectl.cabal`
      `exposed-modules` (not `other-modules` — the test suite imports it). (2026-06-09)
- [x] M1: `containers` already present in the `nagarectl` library stanza (no change
      needed). (2026-06-09)
- [x] M1: Added a pure unit-test group `Nagare.Env.Generated` to
      `cli/nagarectl/test/Spec.hs` (6 cases): the six keys + alphabetical order,
      `NAGARE_SOURCE` only when `source` is `Just`, every value an `EnvLiteral` scoped
      `{Runtime}`, and `mergeGenerated` left-biased (generated overrides user; unrelated
      user vars kept). (2026-06-09)
- [x] M1: `cabal build && cabal test` green. (2026-06-09)
- [x] M2: Wired `generatedEnv`/`mergeGenerated` into `runDeploy` (prebuilt-image path),
      merging into `dep`'s `env` to form `dep'` before `renderService`. (2026-06-09)
- [x] M2: Wired into `deployServer`: merge generated env into the `ServerSite`'s `env`
      before building `ServerDeployInputs`; `serverUrl site0 bd` is reused so the
      generated `NAGARE_SERVICE_URL` matches the rendered Service URL, and `--source`
      flows into `NAGARE_SOURCE`. (2026-06-09)
- [x] M2: Documented (code comment on `deployStatic` + Decision Log) that the **static**
      deploy path is skipped — `StaticSite` has no `env`. (2026-06-09)
- [x] M2: Added a render-level demonstration group `EP-26 render demonstration`
      (2 HUnit cases) proving a rendered Service's inline `env:` contains the
      `NAGARE_*` vars and the preserved user var, and that `NAGARE_SOURCE` is absent
      without a source. (2026-06-09)
- [x] M2: `cabal test` green (81 tests); `--dry-run` deploy shows the injected
      `NAGARE_*` block on both the app path (no `NAGARE_SOURCE`) and the server path
      (`NAGARE_SOURCE=main` with `--source main`). (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `GeneratedContext`'s field names (`namespace`, `releaseId`, `source`, `serviceUrl`,
  `baseDomain`) collide, under `DuplicateRecordFields`, with existing bare selectors and
  a top-level function in the consuming modules: in `Spec.hs` the static-release tests
  use `releaseId`/`source` as bare selectors, and in `Main.hs` `Nagare.Deploy.serviceUrl`
  is a function. Importing `GeneratedContext (..)` made those ambiguous (GHC-87543). Fix:
  import the type/functions plainly but construct the record through a qualified alias
  (`import Nagare.Env.Generated qualified as Gen`; `Gen.GeneratedContext { Gen.serviceUrl
  = ... }`), so the field labels never enter the bare namespace. EP-28 (and any other
  consumer) should construct `GeneratedContext` the same qualified way.

- A record *update* on `env` (`dep { env = ... }` / `site { env = ... }`) is ambiguous
  because both `Deployment` and `ServerSite` have an `env` field. In `Main.hs` the
  generic-lens form `dep & #env %~ f` sidesteps it; in `Spec.hs` (no generic-lens) the
  demo Deployment is built by a constructor function `mkDemoDep envMap` (record
  *construction* names the type and is unambiguous) instead of a record update.


## Decision Log

Record every decision made while working on the plan.

- Decision: Inject generated variables as **inline `{Runtime}` env merged into the app's env
  map at the deploy call site**, via a pure function `generatedEnv :: GeneratedContext ->
  Map EnvName ScopedEnvVar`, rather than changing the `nagare-dsl` renderer's signature
  (`renderService :: Deployment -> Text -> ByteString`).
  Rationale: keeps the renderer a pure function of the typed model and leaves EP-23's
  contract untouched; the CLI is the only place that knows the resolved URL, the release id,
  and the `--source` provenance, so it is the natural place to assemble them. Inline env also
  gives the generated values overriding precedence over the managed `envFrom` store (EP-23
  IP3: inline `env` wins), which is exactly what we want for self-describing identity vars.
  Date: 2026-06-09

- Decision: Reserve the `NAGARE_` name prefix and make `mergeGenerated` **left-biased toward
  the generated map** so a generated variable overrides any user-declared variable of the
  same name.
  Rationale: the generated values are the ground truth about the deployment's identity; a
  user override would be either redundant or wrong. A single, predictable rule ("generated
  wins; `NAGARE_*` is reserved") is easier to document (EP-28 will cite it) than a
  per-variable policy. The reserved prefix is documented in the variable table below.
  Date: 2026-06-09

- Decision: **Skip the static-site deploy path.** Static sites (`Nagare.Dsl.Static.Types`)
  have no `env` field and serve a folder of files through Nginx; there is no application
  process to read environment variables.
  Rationale: there is no place to inject runtime env, and EP-23 IP3 already states static
  sites carry no env and emit no `envFrom`. Injecting generated vars there would be
  meaningless. The static deploy functions in `cli/nagarectl/app/Main.hs` are therefore left
  unchanged, with a comment recording why.
  Date: 2026-06-09

- Decision: Emit `NAGARE_SOURCE` **only when `source` is `Just`**; omit it entirely when the
  deploy carried no provenance (the prebuilt-image `nagarectl deploy` path has no `--source`
  flag, so it always omits it).
  Rationale: an empty `NAGARE_SOURCE=""` is more confusing than an absent one; "the variable
  is not set" is the honest signal that this deploy had no recorded source.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, both milestones.** `Nagare.Env.Generated` produces
the reserved `NAGARE_*` identity variables as inline `{Runtime}` `EnvLiteral`s and
`mergeGenerated` (a left-biased `Map.union`) makes them authoritative over user and
managed env. Both deploy paths that have an `env` field inject them: `runDeploy`
(prebuilt-image, `source=Nothing`) and `deployServer` (server, `--source` →
`NAGARE_SOURCE`). The static path is intentionally untouched.

**Against the purpose:** verified end-to-end via `--dry-run`:
- App: the hello deploy renders inline `env:` with `NAGARE_BASE_DOMAIN`,
  `NAGARE_NAMESPACE`, `NAGARE_RELEASE_ID`, `NAGARE_SERVICE_NAME`, `NAGARE_SERVICE_URL`
  (alphabetical, before `envFrom`), the user's `TARGET` preserved, and no
  `NAGARE_SOURCE`.
- Server: the server fixture with `--source main` additionally renders
  `NAGARE_SOURCE: main`, with user vars `API_BASE`/`HOSTNAME` preserved.
The reserved-prefix override and the `NAGARE_SOURCE`-only-when-`Just` rules are proven
by unit tests; 81 tests pass.

**Notes / lessons:** see Surprises & Discoveries for the two
`DuplicateRecordFields` ambiguities (field-name collisions and `env` record-update) and
their fixes — qualified `GeneratedContext` construction and a constructor function for
the demo Deployment. `NAGARE_SERVICE_URL` correctly honors a config's custom domain
(e.g. `https://hello.example.com`) because it is computed from `serviceUrl`/`serverUrl`,
which prefer the custom domain over the wildcard.


## Context and Orientation

This plan adds code to the **`nagarectl`** Cabal package at
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl`, and reuses types from the
**`nagare-dsl`** library at `/Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl`. Both are
built with GHC 9.12 inside the repository's Nix flake dev shell (the repo uses direnv; run
`direnv allow` once, or `nix develop`, before building). The build tool is Cabal; the test
framework is **tasty** (`tasty-hunit` for assertion tests in `IO`, `tasty-golden` for
byte-for-byte comparisons against files in `test/golden/`).

Three terms used throughout, defined so the reader needs no outside context:

- **Inline `env:`** is the list of environment variables written directly into the Knative
  `Service` manifest's container spec. The renderer in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`
  builds it from the typed model's `env` map.
- **`envFrom:`** is the Kubernetes container field that imports all keys from a named
  ConfigMap and/or Secret as environment variables. EP-23 (below) adds an `envFrom:` block
  to every Service referencing an app-named managed store, with `optional: true` so the
  container still starts if that store does not exist yet.
- **Scope** (`EnvScope`) is "when a variable applies": `Runtime` (present in the running
  container), `Build` (present during the image build), or `Preview` (overlay for preview
  deploys). Generated variables are all `{Runtime}` — they describe the running deployment.

### The dependency: EP-23's scoped env model (hard dependency)

This plan **hard-depends on EP-23**
(`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`), which must be implemented
first. EP-23 changes the typed env model so each variable carries a *set of scopes* and adds
the managed `envFrom:` store. From EP-23, this plan consumes this exact contract, all defined
in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`:

```haskell
-- | When an environment variable applies.
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | An env value (literal or secret reference) plus the non-empty set of scopes
-- it applies to. The EnvVar sum type (EnvLiteral | EnvSecretRef) is unchanged.
data ScopedEnvVar = ScopedEnvVar
  { value  :: !EnvVar
  , scopes :: !(Set EnvScope)
  }
  deriving stock (Generic, Eq, Show)

runtimeScoped :: EnvVar -> ScopedEnvVar   -- always {Runtime}; total
scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar  -- rejects empty set
```

After EP-23, the `env` field of both `Deployment` (`Nagare.Dsl.Types`) and `ServerSite`
(`Nagare.Dsl.Server.Types`) is `Map EnvName ScopedEnvVar` (it is `Map EnvName EnvVar` *before*
EP-23 — this plan assumes EP-23 is already merged, so the maps already hold `ScopedEnvVar`).
`EnvVar` is the unchanged sum type from `Nagare.Dsl.Types`:

```haskell
data EnvVar
  = EnvLiteral Text
  | EnvSecretRef SecretName
```

The crucial precedence rule this plan leans on is **EP-23 IP3**: every rendered Service emits
its `envFrom:` block first and its inline `env:` list second, and *Kubernetes applies
`envFrom` first, then inline `env`, so an inline variable overrides a managed one of the same
name*. Because this plan injects the generated variables as inline `env`, they are
authoritative over the managed store. This plan does **not** modify EP-23's renderer
signature; it only assembles a `Map EnvName ScopedEnvVar` and merges it into the model's
`env` field before the renderer runs.

### The deploy call sites this plan wires into

The CLI entry points live in `cli/nagarectl/app/Main.hs`. The prebuilt-image path,
`runDeploy`, currently reads (lines ~324–357):

```haskell
runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  bd <- resolveBaseDomain (dopts ^. #baseDomain)
  provisionGhcEnv (dopts ^. #ghcEnv)

  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d

  imageTag <- resolveTag (dopts ^. #tag)

  let ref = imageRef dep imageTag
      svcBytes = renderService dep imageTag
      dmBytes = maybeToList (renderDomainMapping dep)
      url = serviceUrl dep bd
      name = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
  ...
```

The values this plan needs are all already in scope here: `dep` (the typed `Deployment`),
`imageTag` (the release id), `bd` (the resolved base domain), `url = serviceUrl dep bd`
(the resolved https URL), `name`, and `ns`. Note: the `DeployOpts` record (lines ~82–90) has
**no** `--source` flag, so the generated `source` for this path is always `Nothing` and
`NAGARE_SOURCE` is omitted on this path.

`serviceUrl` is defined in `cli/nagarectl/src/Nagare/Deploy.hs`:

```haskell
serviceUrl :: Deployment -> Text -> Text
serviceUrl dep baseDomain =
  case dep ^. #domain of
    Just d -> "https://" <> domainText d
    Nothing ->
      "https://"
        <> serviceNameText (dep ^. #name)
        <> "."
        <> namespaceText (dep ^. #namespace)
        <> "."
        <> baseDomain
```

So for a deployment `notes` in namespace `personal` with base domain `apps.example.com` and
no custom domain, `serviceUrl` yields `https://notes.personal.apps.example.com`. This is
exactly the value that becomes `NAGARE_SERVICE_URL`.

The site deploy paths are `deployStatic` and `deployServer` (lines ~373–416 of `Main.hs`).
`deployStatic` operates on a `StaticSite`, which has **no** `env` field — that path is
skipped (see Decision Log). `deployServer` operates on a `ServerSite` (which *does* have
`env :: Map EnvName ScopedEnvVar`) and builds a `ServerDeployInputs`:

```haskell
deployServer :: SiteDeployOpts -> ServerSite -> Text -> IO ()
deployServer sopts site bd = do
  imageTag <- resolveTag (sopts ^. #tag)
  let inputs =
        ServerDeployInputs
          { site = site
          , imageTag = imageTag
          , baseDomain = bd
          , projectDir = sopts ^. #projectDir
          , skipBuild = sopts ^. #skipBuild
          }
      m = serverManifests inputs
  ...
```

The server `SiteDeployOpts` record *does* have a `source :: Maybe String` field (used today
to record release provenance — see `T.pack <$> sopts ^. #source` at line ~413), so the server
path can populate `NAGARE_SOURCE`. The server renderer lives in
`cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs` and renders from `ServerSite` directly
(`renderServerService :: ServerSite -> ServerDeployContext -> ByteString`); the deploy-side
wrapper `serverManifests` is in `cli/nagarectl/src/Nagare/Server/Deploy.hs` and computes the
URL with `serverUrl s (inputs ^. #baseDomain)`. The cleanest injection point for the server
path is to merge the generated env into `site ^. #env` *before* constructing
`ServerDeployInputs`, so the merged `ServerSite` flows through both the dry-run render and the
real deploy unchanged.

### The renderer that consumes the merged env

`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (post-EP-23) builds the inline `env:` from the env
map, sorting by name and filtering to `{Runtime}`-scoped entries:

```haskell
envField :: Map EnvName ScopedEnvVar -> [Pair]
envField m
  | null runtimeEntries = []
  | otherwise = ["env" .= toJSON (map envEntry runtimeEntries)]
  where
    runtimeEntries =
      [ (n, sev ^. #value)
      | (n, sev) <- Map.toAscList m
      , Set.member Runtime (sev ^. #scopes)
      ]
    envEntry (n, ev) = envEntryValue (envNameText n) ev

envEntryValue :: Text -> EnvVar -> Value
envEntryValue n (EnvLiteral lit) = object ["name" .= n, "value" .= lit]
envEntryValue n (EnvSecretRef sn) = ...
```

Because `envField` reads the map and `Map.toAscList` sorts by `EnvName`, simply inserting the
generated `NAGARE_*` entries into the map (as `{Runtime}`-scoped `EnvLiteral`s) is enough for
them to render inline, in alphabetical order, alongside the user's variables. No renderer
change is needed.


## Plan of Work

The work is two milestones. M1 builds and tests the pure `Generated` module in isolation — it
adds no behavior to the CLI yet, only a tested pure function. M2 wires that function into the
two relevant deploy paths (prebuilt-image and server) and adds a render-level demonstration
that the generated variables actually appear in a deployed Service's inline `env:`. Each
milestone is independently verifiable: M1 by a green `cabal test` exercising `generatedEnv`
and `mergeGenerated` directly; M2 by a render demonstration and a `--dry-run` transcript
showing the injected block.


### Milestone M1 — The pure `Generated` module and its unit tests

Goal: a new module `cli/nagarectl/src/Nagare/Env/Generated.hs` that, given a small context
record, produces the `Map EnvName ScopedEnvVar` of generated `NAGARE_*` variables, plus a
left-biased merge. At the end of M1 the module compiles, is listed in `nagarectl.cabal`, and a
pure unit test proves its outputs. No deploy behavior changes yet.

Create `cli/nagarectl/src/Nagare/Env/Generated.hs`:

```haskell
{-# LANGUAGE PackageImports #-}

-- | Deploy-time generated environment variables (EP-26).
--
-- A pure assembly of the @NAGARE_*@ variables that describe a deployment's own
-- identity (URL, name, namespace, base domain, release id, optional source).
-- They are produced as inline @{Runtime}@-scoped 'EnvLiteral' entries and merged
-- into the app's env map at the deploy call site, /before/ rendering, so they
-- render inline and override the managed @envFrom@ store (EP-23 IP3 precedence)
-- and any user variable of the same name. The @NAGARE_@ prefix is reserved.
module Nagare.Env.Generated
  ( GeneratedContext (..)
  , generatedEnv
  , mergeGenerated
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral)
  , ScopedEnvVar
  , mkEnvName
  , runtimeScoped
  )

-- | Everything the deploy step knows that the running app would otherwise have
-- to hard-code. All fields are already resolved 'Text' at the call site.
data GeneratedContext = GeneratedContext
  { serviceName :: !Text
  -- ^ The Knative Service / app name, e.g. @"notes"@.
  , namespace :: !Text
  -- ^ The Kubernetes namespace, e.g. @"personal"@.
  , serviceUrl :: !Text
  -- ^ The resolved public https URL, e.g. @"https://notes.personal.apps.example.com"@.
  , baseDomain :: !Text
  -- ^ The apps base domain, e.g. @"apps.example.com"@.
  , releaseId :: !Text
  -- ^ The image tag for this deploy, e.g. @"20260602-120000"@.
  , source :: !(Maybe Text)
  -- ^ Provenance from @--source@ (branch or commit), if the deploy carried one.
  }
  deriving stock (Generic, Eq, Show)

-- | The generated @NAGARE_*@ variables for a context, as inline @{Runtime}@
-- 'EnvLiteral' entries. @NAGARE_SOURCE@ is present only when 'source' is 'Just'.
generatedEnv :: GeneratedContext -> Map EnvName ScopedEnvVar
generatedEnv ctx =
  Map.fromList
    ( fixed <> sourceEntry )
  where
    lit name v = (envName name, runtimeScoped (EnvLiteral v))
    fixed =
      [ lit "NAGARE_SERVICE_URL" (serviceUrl ctx)
      , lit "NAGARE_SERVICE_NAME" (serviceName ctx)
      , lit "NAGARE_NAMESPACE" (namespace ctx)
      , lit "NAGARE_BASE_DOMAIN" (baseDomain ctx)
      , lit "NAGARE_RELEASE_ID" (releaseId ctx)
      ]
    sourceEntry = case source ctx of
      Just s -> [lit "NAGARE_SOURCE" s]
      Nothing -> []

-- | Merge generated variables over an app's existing env map, generated winning
-- on key collisions (left-biased on the generated map). Reserves @NAGARE_*@.
mergeGenerated
  :: Map EnvName ScopedEnvVar  -- ^ generated (wins)
  -> Map EnvName ScopedEnvVar  -- ^ user / config env
  -> Map EnvName ScopedEnvVar
mergeGenerated = Map.union  -- Data.Map.union is left-biased

-- | Construct an 'EnvName' from a known-valid @NAGARE_*@ literal. These names are
-- compile-time constants that 'mkEnvName' always accepts (non-empty), so a
-- failure here is a programmer error, surfaced loudly.
envName :: Text -> EnvName
envName t = either (\e -> error ("EP-26 generated env name invalid: " <> show e)) id (mkEnvName t)
```

A few notes on this code so a novice can reproduce it confidently. `Nagare.Dsl.Prelude` is the
package's local prelude (already imported by every module in `nagare-dsl` and reused by
`nagarectl` modules such as `Nagare.Deploy`); it re-exports `Generic`, `Text`, lens operators,
and friends. `mkEnvName :: Text -> Either Text EnvName` is the validating constructor from
`Nagare.Dsl.Types`; it only rejects the empty string, so the fixed `NAGARE_*` names always
succeed — the `error` branch is unreachable and exists solely to satisfy totality. `Map.union`
is documented as left-biased (it keeps the left map's value on a key collision), which is
exactly the "generated wins" rule.

Add the module to the **library** stanza of `cli/nagarectl/nagarectl.cabal`:

```cabal
  exposed-modules:
    Nagare.Deploy
    Nagare.Env.Generated
    Nagare.Image
    ...
```

The `nagarectl` library `build-depends` already lists `nagare-dsl`, `text`, `lens`,
`generic-lens`, and `containers`? Check: the current stanza does **not** list `containers`. Add
it so `Data.Map` is available:

```cabal
  build-depends:
    aeson,
    base >=4.17 && <5,
    bytestring,
    containers,
    ...
```

(`Data.Map` comes from `containers`. If a later check shows `containers` is already pulled in
transitively and the module compiles without the explicit dependency, still add it explicitly —
depending on a module you import directly is correct hygiene.)

Add a pure unit-test group to `cli/nagarectl/test/Spec.hs`. The suite is a `tasty` tree built
in `main`; add a new `testGroup "Nagare.Env.Generated" generatedEnvTests` to the list and
define:

```haskell
import Nagare.Env.Generated
import Nagare.Dsl.Types (EnvVar (EnvLiteral), envNameText, mkEnvName, runtimeScoped)
import qualified Data.Map as Map

sampleCtx :: GeneratedContext
sampleCtx = GeneratedContext
  { serviceName = "notes"
  , namespace = "personal"
  , serviceUrl = "https://notes.personal.apps.example.com"
  , baseDomain = "apps.example.com"
  , releaseId = "20260602-120000"
  , source = Just "main"
  }

-- look up a generated value by name, as plain Text (asserts it is an EnvLiteral)
genLit :: Map.Map EnvName ScopedEnvVar -> Text -> Maybe Text
genLit m name = do
  en <- either (const Nothing) Just (mkEnvName name)
  sev <- Map.lookup en m
  case value sev of
    EnvLiteral t -> Just t
    _ -> Nothing

generatedEnvTests :: [TestTree]
generatedEnvTests =
  [ testCase "produces the six NAGARE_* keys when source is Just" $ do
      let m = generatedEnv sampleCtx
      map envNameText (Map.keys m)
        @?= [ "NAGARE_BASE_DOMAIN", "NAGARE_NAMESPACE", "NAGARE_RELEASE_ID"
            , "NAGARE_SERVICE_NAME", "NAGARE_SERVICE_URL", "NAGARE_SOURCE" ]
  , testCase "values match the context" $ do
      let m = generatedEnv sampleCtx
      genLit m "NAGARE_SERVICE_URL" @?= Just "https://notes.personal.apps.example.com"
      genLit m "NAGARE_SERVICE_NAME" @?= Just "notes"
      genLit m "NAGARE_NAMESPACE" @?= Just "personal"
      genLit m "NAGARE_BASE_DOMAIN" @?= Just "apps.example.com"
      genLit m "NAGARE_RELEASE_ID" @?= Just "20260602-120000"
      genLit m "NAGARE_SOURCE" @?= Just "main"
  , testCase "omits NAGARE_SOURCE when source is Nothing" $ do
      let m = generatedEnv sampleCtx { source = Nothing }
      genLit m "NAGARE_SOURCE" @?= Nothing
      length (Map.keys m) @?= 5
  , testCase "every generated entry is Runtime-scoped" $ do
      let m = generatedEnv sampleCtx
      mapM_ (\sev -> scopes sev @?= scopes (runtimeScoped (EnvLiteral "x"))) (Map.elems m)
  , testCase "mergeGenerated overrides a user var of the same name" $ do
      let user = Map.singleton (unsafe (mkEnvName "NAGARE_SERVICE_URL"))
                               (runtimeScoped (EnvLiteral "https://evil.example"))
          merged = mergeGenerated (generatedEnv sampleCtx) user
      genLit merged "NAGARE_SERVICE_URL" @?= Just "https://notes.personal.apps.example.com"
  , testCase "mergeGenerated keeps unrelated user vars" $ do
      let user = Map.singleton (unsafe (mkEnvName "API_BASE"))
                               (runtimeScoped (EnvLiteral "https://api.example.com"))
          merged = mergeGenerated (generatedEnv sampleCtx) user
      genLit merged "API_BASE" @?= Just "https://api.example.com"
  ]
```

The names `value`, `scopes`, `ScopedEnvVar`, `EnvName` come from `Nagare.Dsl.Types`; import
whatever the test file does not yet have. `unsafe` is the existing test helper in `Spec.hs`
that forces a `Right` (`unsafe :: Either Text a -> a`). The expected key order in the first
test is alphabetical because `Map.keys` returns ascending keys — this also documents the order
in which the renderer will emit them.

Commands (working directory `cli/nagarectl`):

```bash
cabal build
cabal test
```

Acceptance: `cabal build` succeeds; the six new `Nagare.Env.Generated` test cases pass. The
first asserts the exact key set (and order), the third proves `NAGARE_SOURCE` is absent when
`source` is `Nothing`, and the override test proves the reserved-prefix behavior. Nothing about
a real deploy has changed yet — this milestone is the pure core in isolation.


### Milestone M2 — Wire into the deploy paths and demonstrate the rendered env

Goal: the prebuilt-image deploy (`runDeploy`) and the server deploy (`deployServer`) inject
the generated variables so they appear inline in the rendered Service; the static path is left
untouched; and a render-level test proves the injection end-to-end. At the end of M2, a
`--dry-run` deploy of a config prints a Service whose inline `env:` contains the `NAGARE_*`
block.

Work — `runDeploy` in `cli/nagarectl/app/Main.hs`. After `dep` and `imageTag` are bound and
before the manifests are rendered, build a `GeneratedContext` from the values already in scope
and merge the generated env into `dep`'s env map. Because `renderService`, `imageRef`,
`renderDomainMapping`, and `serviceUrl` all read from `dep`, replace `dep` with a `dep'` that
has the merged env, and render from `dep'`:

```haskell
  imageTag <- resolveTag (dopts ^. #tag)

  let url = serviceUrl dep bd
      gctx =
        GeneratedContext
          { serviceName = serviceNameText (dep ^. #name)
          , namespace = namespaceText (dep ^. #namespace)
          , serviceUrl = url
          , baseDomain = bd
          , releaseId = imageTag
          , source = Nothing   -- the prebuilt-image deploy has no --source flag
          }
      dep' = dep & #env %~ mergeGenerated (generatedEnv gctx)

  let ref = imageRef dep' imageTag
      svcBytes = renderService dep' imageTag
      dmBytes = maybeToList (renderDomainMapping dep')
      name = serviceNameText (dep' ^. #name)
      ns = namespaceText (dep' ^. #namespace)
```

Add the import `import Nagare.Env.Generated (GeneratedContext (..), generatedEnv, mergeGenerated)`
to `Main.hs`. The `#env %~` lens update works because `Main.hs` already imports
`Data.Generics.Labels ()` (it uses `^. #name` etc.). `url` is computed from `dep` (the URL does
not depend on env), so computing it before `dep'` is fine; everything else renders from `dep'`.

Work — `deployServer` in `cli/nagarectl/app/Main.hs`. Merge the generated env into the
`ServerSite` before building `ServerDeployInputs`, computing the URL with the same
`serverUrl`-equivalent the manifests use. The deploy-side `serverManifests` computes the URL as
`serverUrl s (inputs ^. #baseDomain)`; import `serverUrl` (already exported from
`Nagare.Server.Deploy`) and reuse it so the generated `NAGARE_SERVICE_URL` matches the rendered
Service URL exactly:

```haskell
deployServer :: SiteDeployOpts -> ServerSite -> Text -> IO ()
deployServer sopts site0 bd = do
  imageTag <- resolveTag (sopts ^. #tag)
  let gctx =
        GeneratedContext
          { serviceName = siteNameText (site0 ^. #name)
          , namespace = namespaceText (site0 ^. #namespace)
          , serviceUrl = serverUrl site0 bd
          , baseDomain = bd
          , releaseId = imageTag
          , source = T.pack <$> sopts ^. #source
          }
      site = site0 & #env %~ mergeGenerated (generatedEnv gctx)
      inputs =
        ServerDeployInputs
          { site = site
          , imageTag = imageTag
          , baseDomain = bd
          , projectDir = sopts ^. #projectDir
          , skipBuild = sopts ^. #skipBuild
          }
      m = serverManifests inputs
  ...
```

`siteNameText` comes from `Nagare.Dsl.Static.Types` (already used in the server deploy
module); import it in `Main.hs` if not present. `serverUrl` is exported from
`Nagare.Server.Deploy`; add it to that import list in `Main.hs`. The rest of `deployServer`
(the `if dryRun` block and the `deployServerProduction inputs (T.pack <$> sopts ^. #source)`
real path) is unchanged because it reads `m`/`inputs` built from the merged `site`. Note the
`source` provenance is now consumed in two places — the generated `NAGARE_SOURCE` and the
existing release record — which is consistent and intentional.

Work — `deployStatic` is **not** changed. Add a one-line comment above it recording why:

```haskell
-- NOTE (EP-26): static sites have no env field and serve files via Nginx, so the
-- generated NAGARE_* runtime variables do not apply here and are intentionally
-- not injected. See docs/plans/26-...md Decision Log.
```

Work — render-level demonstration test. The cleanest demonstration that does not require a
cluster is to render a Service from a `Deployment` whose env has been merged with
`generatedEnv`, and assert the rendered bytes contain the generated variables. Add to
`cli/nagarectl/test/Spec.hs` a test that mirrors what `runDeploy` does, using
`renderService` from `nagare-dsl`:

```haskell
import Nagare.Dsl.Render (renderService)
import Nagare.Dsl.Types (Deployment (..), defaultPort, mkServiceName, mkNamespace, mkImageRef)
import qualified Data.ByteString.Char8 as BC

demoDep :: Deployment
demoDep = Deployment
  { name = unsafe (mkServiceName "notes")
  , namespace = unsafe (mkNamespace "personal")
  , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
  , domain = Nothing
  , port = defaultPort
  , env = Map.singleton (unsafe (mkEnvName "API_BASE"))
                        (runtimeScoped (EnvLiteral "https://api.example.com"))
  , resources = Nothing
  , scale = Nothing
  }

renderDemonstrationTests :: [TestTree]
renderDemonstrationTests =
  [ testCase "deployed Service inline env contains the generated NAGARE_* vars" $ do
      let gctx = GeneratedContext
            { serviceName = "notes"
            , namespace = "personal"
            , serviceUrl = "https://notes.personal.apps.example.com"
            , baseDomain = "apps.example.com"
            , releaseId = "20260602-120000"
            , source = Just "main"
            }
          dep' = demoDep { env = mergeGenerated (generatedEnv gctx) (env demoDep) }
          yaml = renderService dep' "20260602-120000"
      assertInfix "NAGARE_SERVICE_URL" yaml
      assertInfix "https://notes.personal.apps.example.com" yaml
      assertInfix "NAGARE_RELEASE_ID" yaml
      assertInfix "NAGARE_SOURCE" yaml
      assertInfix "main" yaml
      assertInfix "API_BASE" yaml          -- user var preserved
  , testCase "without --source, NAGARE_SOURCE is absent from the rendered Service" $ do
      let gctx = GeneratedContext
            { serviceName = "notes", namespace = "personal"
            , serviceUrl = "https://notes.personal.apps.example.com"
            , baseDomain = "apps.example.com", releaseId = "20260602-120000"
            , source = Nothing }
          dep' = demoDep { env = mergeGenerated (generatedEnv gctx) (env demoDep) }
          yaml = renderService dep' "20260602-120000"
      assertBool "NAGARE_SOURCE absent" (not ("NAGARE_SOURCE" `BC.isInfixOf` yaml))
  ]
```

`assertInfix` already exists in `Spec.hs` (it asserts a `ByteString` needle is in a
`ByteString` haystack). `Deployment (..)`, `mkServiceName`, and `defaultPort` come from
`Nagare.Dsl.Types`. Note the record field type for `env` is `Map EnvName ScopedEnvVar`
(post-EP-23), which is why the user entry is wrapped in `runtimeScoped`. Wire both new groups
into `main` alongside the M1 group:

```haskell
      , testGroup "Nagare.Env.Generated" generatedEnvTests
      , testGroup "EP-26 render demonstration" renderDemonstrationTests
```

If you prefer a durable golden record, you may instead add a
`test/golden/generated-env.service.yaml` and a `goldenVsString` test that renders `dep'` and
compares byte-for-byte; the HUnit `assertInfix` form above is sufficient for acceptance and is
less brittle, so prefer it unless a golden is explicitly wanted.

Commands (working directory `cli/nagarectl`):

```bash
cabal build
cabal test
```

Acceptance: `cabal test` is green, including the two render-demonstration cases (the first
asserting the generated vars and the preserved user var are present, the second asserting
`NAGARE_SOURCE` is absent without a source). Then a `--dry-run` deploy (see Concrete Steps)
prints a Service whose inline `env:` contains the `NAGARE_*` block.


## Concrete Steps

All commands run from `cli/nagarectl` unless stated otherwise. Enter the flake dev shell first
if not already inside it (the repo uses direnv: `direnv allow` once, or `nix develop`).

Build and test after M1:

```bash
cabal build
cabal test
```

Expected (abbreviated) — the new pure tests appear and pass:

```text
nagarectl
  Nagare.Env.Generated
    produces the six NAGARE_* keys when source is Just:   OK
    values match the context:                             OK
    omits NAGARE_SOURCE when source is Nothing:           OK
    every generated entry is Runtime-scoped:              OK
    mergeGenerated overrides a user var of the same name: OK
    mergeGenerated keeps unrelated user vars:             OK
All N tests passed (…s)
```

Build and test after M2:

```bash
cabal build
cabal test
```

Expected — the render-demonstration group also passes:

```text
  EP-26 render demonstration
    deployed Service inline env contains the generated NAGARE_* vars:   OK
    without --source, NAGARE_SOURCE is absent from the rendered Service: OK
```

End-to-end dry-run transcript. Use the existing example/fixture config that produces a
`Deployment` (the loader path `Load.loadDeployment` reads a typed `Config.hs`). From the repo
root, against the hello example (substitute your own base domain to see the URL change):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/hello-knative-service/nagare/Config.hs \
  --base-domain apps.example.com \
  --tag 20260602-120000 \
  --dry-run
```

Expected — the printed Knative Service manifest's container spec shows the user's `TARGET`
variable plus the injected `NAGARE_*` block (alphabetically sorted, all inline, before the
`envFrom:` from EP-23). `NAGARE_SOURCE` is **absent** because the prebuilt-image `deploy` path
has no `--source` flag:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
spec:
  template:
    spec:
      containers:
      - image: gcr.io/.../hello:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: NAGARE_BASE_DOMAIN
          value: apps.example.com
        - name: NAGARE_NAMESPACE
          value: personal
        - name: NAGARE_RELEASE_ID
          value: "20260602-120000"
        - name: NAGARE_SERVICE_NAME
          value: hello
        - name: NAGARE_SERVICE_URL
          value: https://hello.personal.apps.example.com
        - name: TARGET
          value: Nagare
        envFrom:
        - configMapRef:
            name: nagare-env-hello-runtime
            optional: true
        - secretRef:
            name: nagare-secret-hello-runtime
            optional: true
URL: https://hello.personal.apps.example.com
```

For a server site (which *does* carry `--source`), the server dry-run additionally shows
`NAGARE_SOURCE`. Using the server example with `--source main`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- site deploy \
  -f cluster/examples/server-site/nagare/Config.hs \
  --base-domain apps.example.com \
  --tag 20260602-120000 \
  --source main \
  --dry-run
```

Expected — the server Service's inline `env:` contains the same `NAGARE_*` keys *plus*
`NAGARE_SOURCE: main`. (The exact example path may differ; use whichever server-site example
or fixture exists, e.g. `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs`.)


## Validation and Acceptance

Acceptance is behavioral, phrased as observable input/output, not "code compiles."

First, generated variables appear inline. Deploying `notes` (or any app) with base domain
`apps.example.com`, namespace `personal`, and tag `20260602-120000` renders a Service whose
inline `env:` contains `NAGARE_SERVICE_URL=https://notes.personal.apps.example.com`,
`NAGARE_SERVICE_NAME=notes`, `NAGARE_NAMESPACE=personal`, `NAGARE_BASE_DOMAIN=apps.example.com`,
and `NAGARE_RELEASE_ID=20260602-120000`. Observe this via the `--dry-run` transcript above and
via the render-demonstration test in `cli/nagarectl/test/Spec.hs` (which asserts the strings
are present in the rendered bytes).

Second, `--source` provenance flows through on the server path. Running `site deploy ...
--source main --dry-run` renders a server Service whose inline `env:` additionally contains
`NAGARE_SOURCE=main`. Without `--source`, `NAGARE_SOURCE` is absent — confirmed by the
"omits NAGARE_SOURCE when source is Nothing" unit test and the "without --source, NAGARE_SOURCE
is absent from the rendered Service" render test, both of which fail before this change (the
variable cannot exist) and pass after.

Third, the reserved prefix overrides user vars. A config author who writes a variable named
`NAGARE_SERVICE_URL` gets the generated value, not theirs: the `mergeGenerated overrides a user
var of the same name` unit test asserts `genLit merged "NAGARE_SERVICE_URL"` equals the
generated URL even when the user map set it to `https://evil.example`. This documents and
enforces the reserved-prefix rule. Unrelated user variables (e.g. `API_BASE`) are preserved —
asserted by the `mergeGenerated keeps unrelated user vars` test and visible as `TARGET`/`API_BASE`
still present in the dry-run output.

Fourth, static sites are unaffected. The static deploy path renders no `env:` and no
`NAGARE_*` (a `StaticSite` has no `env` field); the static golden
`cli/nagare-dsl/test/golden/static-site.service.yaml` is unchanged by this plan.

The exact test command is `cabal test` (from `cli/nagarectl`). A failing `tasty-hunit` test
prints the failed assertion and the offending value; if `assertInfix "NAGARE_SERVICE_URL"`
fails it dumps the full rendered YAML so you can see what was emitted instead.


## Idempotence and Recovery

`generatedEnv` and `mergeGenerated` are pure total functions; calling them repeatedly with the
same `GeneratedContext` yields byte-for-byte identical maps, so re-rendering and re-deploying
the same app at the same release produces an identical Service manifest. The only fields that
change between two deploys of the same app are `NAGARE_RELEASE_ID` (the new image tag) and
`NAGARE_SOURCE` (the new provenance) — by design, these reflect the specific deploy, and a
redeploy with the same tag and source is fully reproducible. There is no on-disk state and no
destructive operation introduced by this plan.

Every command here (`cabal build`, `cabal test`, `--dry-run`) is safe to repeat. A real (non
`--dry-run`) deploy applies the rendered Service with `kubectl apply`, which is itself
idempotent: re-applying an identical manifest is a no-op. To roll back the code, revert the
commits; the `Generated` module and the call-site merges are additive, so reverting restores
the previous (no generated vars) behavior with no migration.


## Interfaces and Dependencies

This plan adds one module and depends only on libraries already in the build. From the
`nagare-dsl` library it imports (all from `Nagare.Dsl.Types`): `EnvName`, `mkEnvName`,
`envNameText`, `EnvVar (EnvLiteral)`, `ScopedEnvVar` with its `value`/`scopes` accessors,
`runtimeScoped`, and (in tests) `Deployment (..)`, `mkServiceName`, `mkNamespace`, `mkImageRef`,
`defaultPort`; plus `Nagare.Dsl.Render.renderService`. From the `nagarectl` library it imports
`Nagare.Server.Deploy.serverUrl` and `Nagare.Dsl.Static.Types.siteNameText` at the wiring
sites. It needs `containers` (for `Data.Map`) in the `nagarectl` library stanza — add it if
absent. No new third-party dependency is introduced.

The **new public interface** this plan defines, in module
`cli/nagarectl/src/Nagare/Env/Generated.hs` (full module path `Nagare.Env.Generated`):

```haskell
data GeneratedContext = GeneratedContext
  { serviceName :: Text
  , namespace   :: Text
  , serviceUrl  :: Text       -- the resolved https URL
  , baseDomain  :: Text
  , releaseId   :: Text       -- the image tag
  , source      :: Maybe Text -- --source provenance (branch/commit), if any
  }

-- Inline {Runtime} EnvLiteral entries for NAGARE_SERVICE_URL, NAGARE_SERVICE_NAME,
-- NAGARE_NAMESPACE, NAGARE_BASE_DOMAIN, NAGARE_RELEASE_ID, and NAGARE_SOURCE
-- (the last only when source is Just).
generatedEnv :: GeneratedContext -> Map EnvName ScopedEnvVar

-- Left-biased on the generated map: generated entries override user entries of the
-- same key. NAGARE_* is reserved.
mergeGenerated
  :: Map EnvName ScopedEnvVar  -- generated (wins)
  -> Map EnvName ScopedEnvVar  -- user / config env
  -> Map EnvName ScopedEnvVar
```

**Dependency on EP-23 (`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`).** This
plan assumes EP-23 is already merged, so that `Deployment.env` and `ServerSite.env` are both
`Map EnvName ScopedEnvVar`, and `ScopedEnvVar`/`runtimeScoped`/`EnvScope` exist in
`Nagare.Dsl.Types`. The exact consumed contract (EP-23 IP1):

```haskell
data EnvScope = Runtime | Build | Preview
data ScopedEnvVar = ScopedEnvVar { value :: EnvVar, scopes :: Set EnvScope }
runtimeScoped :: EnvVar -> ScopedEnvVar   -- {Runtime}
```

This plan also relies on EP-23 IP3 (the `envFrom`-then-inline-`env` precedence) for the
generated variables to be authoritative over the managed store. It does **not** modify EP-23's
renderer signature `renderService :: Deployment -> Text -> ByteString`; injection happens by
merging into the env map at the deploy call site, before rendering.


## The generated variables

The following six variables make up the reserved `NAGARE_*` set this plan injects. This table
is the canonical reference that the user-facing documentation plan (EP-28) cites. Every entry
is rendered as an inline `{Runtime}`-scoped `value:` literal in the Knative Service. The first
five are always present on the prebuilt-image and server deploy paths; `NAGARE_SOURCE` is
present only when the deploy carried a `--source` (so: on the server path with `--source`, and
never on the prebuilt-image path, which has no such flag).

| Variable | Meaning | Example value |
| --- | --- | --- |
| `NAGARE_SERVICE_URL` | The deployment's resolved public https URL (custom domain if set, else the Knative wildcard) | `https://notes.personal.apps.example.com` |
| `NAGARE_SERVICE_NAME` | The Knative Service / app name | `notes` |
| `NAGARE_NAMESPACE` | The Kubernetes namespace the Service runs in | `personal` |
| `NAGARE_BASE_DOMAIN` | The apps base domain used to derive the wildcard URL | `apps.example.com` |
| `NAGARE_RELEASE_ID` | The image tag deployed (the release id) | `20260602-120000` |
| `NAGARE_SOURCE` | Source provenance from `--source` (branch or commit); omitted when absent | `main` |

The `NAGARE_` prefix is **reserved**: any user-declared variable with one of these names is
overridden by the generated value (the merge is left-biased toward the generated map). A
running app reads them through the platform's normal environment, for example
`process.env.NAGARE_SERVICE_URL` in Node or `System.getenv "NAGARE_RELEASE_ID"` in Haskell.
