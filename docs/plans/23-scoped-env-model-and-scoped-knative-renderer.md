---
id: 23
slug: scoped-env-model-and-scoped-knative-renderer
title: "Scoped env model and scoped Knative renderer"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Scoped env model and scoped Knative renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan is the foundation of the "Environment and Secret Management" initiative
(parent MasterPlan: `docs/masterplans/5-environment-and-secret-management-for-nagare.md`).
It changes the typed deployment model in the `nagare-dsl` Haskell library so that every
environment variable carries a set of *scopes* — when it applies — and so that every
rendered Knative `Service` reaches out to a per-app managed environment store.

Concretely, after this change a config author can say "this variable is only needed at
build time, not in the running container," and the production manifest will leave it out
of the container's inline `env:`. And every rendered `Service` gains an `envFrom:` block
that pulls additional variables from a Kubernetes ConfigMap and Secret named for the app,
so an operator can add or change variables later (in a future plan, EP-24/EP-25) without
editing Haskell or rebuilding the image. Both abilities are new; today every variable is
unconditionally a runtime variable baked inline, and there is no managed store.

Two terms used throughout, defined here so the reader needs no outside context:

- **Knative `Service`** is the single YAML resource Nagare deploys for an app. It contains
  a pod template whose `spec.template.spec.containers[0]` lists the container `image`,
  `ports`, `env` (inline variables), `envFrom` (variables pulled from external sources),
  and `resources`. We render this YAML in Haskell; there is no `kubectl` in this plan.
- **`envFrom`** is the Kubernetes container field that says "import all keys from this
  ConfigMap and/or Secret as environment variables." With `optional: true`, the container
  still starts if the referenced ConfigMap/Secret does not exist. Kubernetes applies
  `envFrom` *first* and the inline `env:` list *second*, so an inline variable overrides a
  managed one of the same name. That precedence is part of the contract this plan owns.

### Before / after of a rendered Service

Today, a config with a runtime variable `API_BASE` and a (hypothetical) build-only
variable `BUILD_TOKEN` renders every variable inline and has no `envFrom`:

```yaml
# BEFORE (current behavior): all env inline, no envFrom, no scope concept
spec:
  template:
    spec:
      containers:
      - image: gcr.io/myproject/notes:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: API_BASE
          value: https://api.example.com
        - name: BUILD_TOKEN          # leaks a build-only value into the runtime container
          value: abc123
```

After this change, `BUILD_TOKEN` (scoped `{Build}` only) is excluded from the runtime
container's inline `env:`, and the container gains an `envFrom:` block that references the
app's Runtime-scoped managed ConfigMap and Secret:

```yaml
# AFTER (this plan): scope-filtered inline env + envFrom to the managed store
spec:
  template:
    spec:
      containers:
      - image: gcr.io/myproject/notes:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: API_BASE
          value: https://api.example.com
        envFrom:
        - configMapRef:
            name: nagare-env-notes-runtime
            optional: true
        - secretRef:
            name: nagare-secret-notes-runtime
            optional: true
```

`BUILD_TOKEN` no longer appears in the running container. The two `envFrom` references are
the managed store for the app named `notes`; `optional: true` means the app still deploys
even though no plan has created those resources yet (that is EP-24/EP-25). A config author
who writes a plain variable with no scope still gets the old behavior: the variable defaults
to scope `{Runtime}` and renders inline exactly as before. The only universally visible new
output is the `envFrom` block, which now appears on every app and server-site Service.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `EnvScope` and `ScopedEnvVar` to `Nagare.Dsl.Types`, with the
      non-empty-set invariant, `runtimeScoped`, and `scopedEnv`; export them. (2026-06-09)
- [x] M1: Change `Deployment.env` and `ServerSite.env` to `Map EnvName ScopedEnvVar`. (2026-06-09)
- [x] M1: Update `Nagare.Dsl.Presets.secretEnv` to produce a Runtime-scoped entry. (2026-06-09)
- [x] M1: Update example/fixture configs and in-test fixtures so they compile with the
      default `{Runtime}` scope; document each touched file. Touched:
      `cluster/examples/hello-knative-service/nagare/Config.hs`,
      `cli/nagare-dsl/test/fixtures/nagare/Config.hs`,
      `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs`,
      `cli/nagare-dsl/test/Spec.hs`, `cli/nagare-dsl/test/ServerSpec.hs`.
      `cluster/examples/preset-app-b/nagare/Config.hs` needed no edit (uses `secretEnv`). (2026-06-09)
- [x] M1: `cabal build` succeeds; existing golden tests still pass byte-for-byte
      (all 135 tests pass, no `envFrom` yet). (2026-06-09)
- [x] M2: Add `"scopes"` to the emitted JSON in `Nagare.Dsl.Config`
      (`envJSON`/`envEntryJSON`, via shared `scopeTokensJSON`); decode it in
      `Nagare.Dsl.Load` (`JsonEnvEntry.jeScopes`/`parseScope`/`toEnvEntry`) with
      missing/empty defaulting to `{Runtime}` and unknown tokens rejected via a
      `MarshalError "env.<var>.scopes"`. (2026-06-09)
- [x] M2: Unit tests for round-trip: scopes survive emit→decode (Spec.hs
      `scopedEnvTests`); missing/empty default to Runtime, a multi-scope entry
      decodes to both, and an unknown scope token yields a `MarshalError`
      (LoadSpec.hs). 142 tests pass. (2026-06-09)
- [x] M3: Add `scopeToken`, `managedConfigMapName`, `managedSecretName`; export them
      from `Nagare.Dsl.Render`. `Server/Render.hs` imports and reuses them. (2026-06-09)
- [x] M3: Scope-filter the inline `env:` (Runtime-only) and add the always-present
      `envFrom` block in both `Nagare.Dsl.Render` and `Nagare.Dsl.Server.Render`;
      placed `envFrom` (rank 3) between `env` (2) and `resources` (4) in `keyCompare`,
      plus `optional`/`configMapRef`/`secretRef` ranks. (2026-06-09)
- [x] M3: Updated the 4 affected goldens (hello, preset-app-a, preset-app-b,
      server-site) — diff is exactly the inserted `envFrom` block — and added a new
      `test/golden/build-only.service.yaml` proving `BUILD_TOKEN` ({Build}) is
      excluded from inline `env:` while `API_BASE` and the `envFrom` refs remain.
      `static-site.service.yaml` and the DomainMapping/Dockerfile goldens are
      unchanged. Full `cabal test` green (143 tests); `nagarectl` builds and its 52
      tests pass against the updated library. (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Model scope as `data EnvScope = Runtime | Build | Preview` and attach a
  `Set EnvScope` to each entry via `data ScopedEnvVar = ScopedEnvVar { value :: EnvVar,
  scopes :: Set EnvScope }`, keeping the existing `EnvVar = EnvLiteral | EnvSecretRef`
  sum type untouched.
  Rationale: a set most directly expresses "a variable can apply to several phases"; it
  preserves the headline safety invariant (an env value is a literal *or* a secret ref,
  never both, enforced by the compiler); and it defaults cleanly to `{Runtime}` so every
  existing config keeps compiling. This mirrors IP1 in the parent MasterPlan verbatim.
  Date: 2026-06-09

- Decision: Make the non-empty-scopes invariant a runtime-checked smart-constructor rule
  (`scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar`, rejecting the empty
  set) plus a total convenience constructor (`runtimeScoped :: EnvVar -> ScopedEnvVar`)
  that always yields `{Runtime}`, rather than a `NonEmpty`-of-scope type.
  Rationale: `Set` is the natural carrier for "membership, deduplicated, unordered," and
  there is no standard "non-empty set"; a validating constructor plus a guaranteed-valid
  default constructor gives the same safety with a far simpler type. The decoder defaults a
  missing/empty scope list to `{Runtime}`, so the invariant is also restored on load.
  Date: 2026-06-09

- Decision: Emit `envFrom` referencing the Runtime managed ConfigMap and Secret with
  `optional: true` on every app and server Service, and document the Kubernetes precedence
  (`envFrom` first, inline `env` second) as part of the contract.
  Rationale: lets a later plan change managed env without re-rendering or rebuilding;
  `optional: true` means an app whose store was never written still deploys; the precedence
  gives explicit inline declarations (and, later, generated variables) the final say. This
  is IP3 in the parent MasterPlan.
  Date: 2026-06-09

- Decision: Own the managed-resource name format here (`scopeToken`,
  `managedConfigMapName`, `managedSecretName`) and export it from the library, so EP-24,
  EP-25, and EP-27 call these helpers and never re-derive names by hand. The format is
  `nagare-env-<app>-<scope>` and `nagare-secret-<app>-<scope>` with the scope token
  lowercased (`runtime`/`build`/`preview`). This is IP2.
  Rationale: a single owner of the string format prevents drift between the names the
  Service references in `envFrom` and the names the store creates.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, all three milestones delivered.** The
`nagare-dsl` model now carries `EnvScope`/`ScopedEnvVar`, every existing config
compiles unchanged through the `runtimeScoped` default, the scope set survives
the JSON round-trip, and every rendered app and server Service scope-filters its
inline `env:` to Runtime entries and emits the `envFrom` block referencing the
managed store with `optional: true`. The three integration contracts (IP1 type +
env-map change, IP2 naming helpers, IP3 `envFrom` wiring + precedence) are in
place for the downstream plans to import.

**Against the purpose:** both new abilities exist — a `{Build}`-only variable is
excluded from the running container (proven by `build-only.service.yaml`), and
every Service reaches out to a per-app managed store it can be populated from
later without editing Haskell or rebuilding.

**Notes / lessons:**
- `Server/Render.hs` imports the naming helpers from `Nagare.Dsl.Render` rather
  than redefining them, keeping a single owner of the string format (IP2). There
  is no import cycle: `Render` depends only on `Build` and `Types`.
- `DuplicateRecordFields` is on, so the new `value`/`scopes` selectors of
  `ScopedEnvVar` coexist with other records; tests poke them via the
  constructor-qualified record pattern `Deployment{env = m}` and the unambiguous
  `scopes`/`value` selectors, avoiding a `generic-lens` test dependency.
- The workspace beyond the library (`nagarectl`) was rebuilt and its suite run to
  confirm the env-field type change is transparent to consumers that go through
  `loadDeployment`/`renderService`.


## Context and Orientation

Everything in this plan lives under the `nagare-dsl` library at
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl`. It is a Cabal package built with
GHC 9.12 inside the repository's Nix flake dev shell. The library defines a *typed*
deployment model: every field goes through a validating "smart constructor"
(`mkX :: ... -> Either Text X`) so an invalid value (a bad DNS name, an out-of-range port)
cannot be constructed. The model is serialized to JSON, written to stdout by an app's
`Config.hs`, read back by a loader that re-runs the constructors, and finally rendered to
Knative `Service` YAML.

The files this plan touches, by full path, and what each currently holds:

- `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` — the core model. The relevant current shapes:

  ```haskell
  -- The headline safety invariant: an env value is a literal OR a secret ref,
  -- never both, enforced by the compiler.
  data EnvVar
    = EnvLiteral Text
    | EnvSecretRef SecretName
    deriving stock (Generic, Eq, Show)

  data Deployment = Deployment
    { name :: !ServiceName
    , namespace :: !Namespace
    , image :: !ImageRef
    , domain :: !(Maybe Domain)
    , port :: !Port
    , env :: !(Map EnvName EnvVar)   -- <-- changes to Map EnvName ScopedEnvVar
    , resources :: !(Maybe Resources)
    , scale :: !(Maybe Scale)
    }
  ```

  `EnvName` and `SecretName` are validating newtypes with accessors `envNameText` and
  `secretNameText`. The module's export list is explicit; new names (`EnvScope`,
  `ScopedEnvVar`, `runtimeScoped`, `scopedEnv`) must be added to it. The module imports
  `Data.Map (Map)`; it will also need `Data.Set (Set)`.

- `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` — the `ServerSite` model (a full-stack
  Node app). It has the same `env :: !(Map EnvName EnvVar)` field (line ~116) that must
  change to `Map EnvName ScopedEnvVar`. It imports the env types from `Nagare.Dsl.Types`
  in an explicit import list (currently importing `EnvVar`); that list must add
  `ScopedEnvVar` (and it already imports `EnvName`).

- `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` — serialization to JSON (what `Config.hs`
  prints). The two env encoders today:

  ```haskell
  -- in deploymentJSON:
  envJSON (n, EnvLiteral lit) =
    object ["varName" .= envNameText n, "kind" .= ("Literal" :: Text), "value" .= lit]
  envJSON (n, EnvSecretRef sn) =
    object ["varName" .= envNameText n, "kind" .= ("SecretRef" :: Text), "secretName" .= secretNameText sn]

  -- in serverSiteJSON: envEntryJSON has the identical two clauses.
  ```

  After the type change, the map values are `ScopedEnvVar`, so each clause must read
  `sev ^. value` (the `EnvVar`) and emit an additional `"scopes"` array from
  `sev ^. scopes`.

- `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` — deserialization. The intermediate record and
  marshaller today:

  ```haskell
  data JsonEnvEntry = JsonEnvEntry
    { jeVarName :: !Text
    , jeKind :: !Text
    , jeValue :: !(Maybe Text)
    , jeSecretName :: !(Maybe Text)
    }

  instance FromJSON JsonEnvEntry where
    parseJSON = withObject "EnvEntry" $ \o ->
      JsonEnvEntry <$> o .: "varName" <*> o .: "kind" <*> o .:? "value" <*> o .:? "secretName"

  toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, EnvVar)
  toEnvEntry e = do
    n <- mapLeft (MarshalError "env.varName") $ mkEnvName (jeVarName e)
    v <- case jeKind e of
      "Literal"  -> ...EnvLiteral...
      "SecretRef"-> ...EnvSecretRef...
      other      -> Left (MarshalError ... ("unknown env kind: " <> other))
    Right (n, v)
  ```

  `toEnvEntry` is called from both `toDeployment` (via `mapM toEnvEntry (jdEnv jd)`) and
  `toServerSite` (via `mapM toEnvEntry (jsvEnv j)`), then `Map.fromList`'d. Its return type
  changes to `Either LoadError (EnvName, ScopedEnvVar)`. `JsonEnvEntry` gains an optional
  `jeScopes :: !(Maybe [Text])` field parsed from `"scopes"`.

- `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` — the app renderer. It serializes a `Value`
  with `Data.Yaml.Pretty.encodePretty` under a fixed key comparator so the YAML key order
  matches the cluster contract. The relevant current code:

  ```haskell
  -- container assembly: required keys then optional sub-blocks
  optionals = envField (dep ^. #env) <> resourcesField (dep ^. #resources)

  envField :: Map EnvName EnvVar -> [Pair]
  envField m
    | Map.null m = []
    | otherwise  = ["env" .= toJSON (map envEntry (Map.toAscList m))]
    where envEntry (n, ev) = envEntryValue (envNameText n) ev

  envEntryValue :: Text -> EnvVar -> Value
  envEntryValue n (EnvLiteral lit) = object ["name" .= n, "value" .= lit]
  envEntryValue n (EnvSecretRef sn) =
    object ["name" .= n, "valueFrom" .= object
              ["secretKeyRef" .= object ["name" .= secretNameText sn, "key" .= n]]]
  ```

  And the key-ordering comparator (note `"env"` has rank 2, `"resources"` rank 3; we will
  insert `"envFrom"` between them):

  ```haskell
  keyCompare :: Text -> Text -> Ordering
  keyCompare a b = compare (rank a, a) (rank b, b)
    where rank k = maybe maxBound id (lookup k ranks)
          ranks = [ ... ("image", 0), ("ports", 1), ("env", 2), ("resources", 3) ... ]
  ```

  After this plan: `envField` takes `Map EnvName ScopedEnvVar`, filters to entries whose
  `scopes` contains `Runtime`, and unwraps `value` before calling `envEntryValue`; the
  container assembly also gains an always-present `envFromField` keyed `"envFrom"`; and
  `keyCompare`'s `ranks` table inserts `("envFrom", ...)` between `env` and `resources`.

- `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs` — the server-site renderer. It has its
  own copy of `envField`, `envEntryValue`, and `keyCompare` with the same shapes (the
  module comment says it "mirrors `Nagare.Dsl.Render`"). The same three edits apply.

- `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs` — reusable overlays. `secretEnv` inserts an
  env entry today as a bare `EnvVar`:

  ```haskell
  secretEnv varName secretNameText dep = do
    en <- mkEnvName varName
    sn <- mkSecretName secretNameText
    pure (dep & #env %~ Map.insert en (EnvSecretRef sn))
  ```

  It must wrap that in `runtimeScoped` so the map value typechecks as `ScopedEnvVar`.

- `cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs` and `.../Static/Types.hs` — the static
  (Nginx) site path. A `StaticSite` has **no** env field, and its golden
  `test/golden/static-site.service.yaml` shows no `env`/`envFrom`. This plan does **not**
  touch static rendering: per IP3 in the parent MasterPlan, static sites carry no env and
  are unaffected. Do not add `envFrom` to the static renderer.

The example and fixture configs that construct an `env` map literal, and must be updated to
the new `ScopedEnvVar` value type:

- `cluster/examples/hello-knative-service/nagare/Config.hs` — builds
  `env = Map.singleton target (EnvLiteral "Nagare")`.
- `cli/nagare-dsl/test/fixtures/nagare/Config.hs` — same `Map.singleton target (EnvLiteral "Nagare")`.
- `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs` — builds a two-entry map of
  `EnvLiteral`s.
- `cli/nagare-dsl/test/Spec.hs` — `helloDep` builds `env = Map.fromList [(..., EnvLiteral "Nagare")]`.
- `cli/nagare-dsl/test/ServerSpec.hs` — `notesApp` builds a two-entry `EnvLiteral` map.
- `cluster/examples/preset-app-b/nagare/Config.hs` — uses `secretEnv` (so it is fixed
  automatically once `secretEnv` is updated; no manual edit needed, but verify it compiles).

The test harness uses **tasty** with two relevant kinds of test. A `tasty-hunit` test
(`testCase`) makes an assertion in `IO` (e.g. `result @?= expected`). A `tasty-golden`
test (`goldenVsString name goldenPath action`) runs `action` to produce a `ByteString`,
compares it byte-for-byte against the file at `goldenPath`, and fails on any difference;
running the suite with `--accept` overwrites the golden file with the new output (used
deliberately when an output shape change is intended). The test suite's golden files live
in `cli/nagare-dsl/test/golden/`. The `.cabal` test stanza `nagare-dsl-test` lists
`other-modules: LoadSpec, ServerSpec, StaticSpec` and depends on `tasty`, `tasty-golden`,
`tasty-hunit`, `tasty-quickcheck`, `temporary`, `containers`. No new dependency is needed
(`containers` already provides `Data.Set`).


## Plan of Work

The work is three milestones. M1 introduces the types and makes everything compile with the
default `{Runtime}` scope, changing no rendered output. M2 makes the scope set survive the
JSON round-trip with tests. M3 adds the scope-filtered render and the `envFrom` block,
which is the only milestone that changes golden output. Each milestone is independently
verifiable: M1 by a successful build and unchanged goldens, M2 by new round-trip unit
tests, M3 by updated goldens plus a behavioral exclusion test.


### Milestone M1 — Types and a clean compile with the default scope

Goal: introduce `EnvScope` and `ScopedEnvVar`, retype the two `env` maps, and update every
config that constructs an env entry, so the whole package and its tests compile and the
existing golden outputs are unchanged. At the end of M1, nothing about the rendered YAML or
the JSON has changed yet — this milestone is purely the model and a mechanical migration.

Work, file by file:

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, add (placed right after the `EnvVar`
definition, around line 178) the new types and constructors:

```haskell
import Data.Set (Set)
import Data.Set qualified as Set

-- | When an environment variable applies. 'Runtime' is present in the running
-- container; 'Build' is present during the image build; 'Preview' overlays
-- preview deployments. A variable may carry several scopes at once.
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | An env value (literal or secret reference) together with the non-empty set
-- of scopes it applies to. The 'EnvVar' sum type is unchanged, preserving the
-- headline safety invariant (literal XOR secret ref). Invariant: 'scopes' is
-- non-empty; construct via 'runtimeScoped' (always 'Runtime') or 'scopedEnv'
-- (validates non-emptiness).
data ScopedEnvVar = ScopedEnvVar
  { value :: !EnvVar
  , scopes :: !(Set EnvScope)
  }
  deriving stock (Generic, Eq, Show)

-- | The backward-compatible default: a single 'Runtime' scope. A bare variable
-- with no scope decoration behaves exactly as before this change.
runtimeScoped :: EnvVar -> ScopedEnvVar
runtimeScoped v = ScopedEnvVar {value = v, scopes = Set.singleton Runtime}

-- | Construct a 'ScopedEnvVar' from an explicit scope set, rejecting the empty
-- set so the non-empty invariant cannot be violated.
scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar
scopedEnv ss v
  | Set.null ss = Left "env scopes must not be empty"
  | otherwise = Right (ScopedEnvVar {value = v, scopes = ss})
```

Add `EnvScope (..)`, `ScopedEnvVar (..)`, `runtimeScoped`, and `scopedEnv` to the module's
export list (a new `-- * EnvScope` / `-- * ScopedEnvVar` section near the existing
`-- * EnvVar` block). Change the `Deployment` record's field to
`env :: !(Map EnvName ScopedEnvVar)`.

In `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`, change the `ServerSite` record field to
`env :: !(Map EnvName ScopedEnvVar)`, and add `ScopedEnvVar` to the explicit import list
from `Nagare.Dsl.Types`.

In `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`, wrap the inserted secret env value:

```haskell
pure (dep & #env %~ Map.insert en (runtimeScoped (EnvSecretRef sn)))
```

and import `runtimeScoped` (it comes from `Nagare.Dsl.Types`, already imported wholesale).

Update the env-constructing configs to wrap values in `runtimeScoped`:

- `cluster/examples/hello-knative-service/nagare/Config.hs`:
  `env = Map.singleton target (runtimeScoped (EnvLiteral "Nagare"))` and import
  `runtimeScoped` (the file imports `Nagare.Dsl.Types` unqualified, so it is already in
  scope; confirm).
- `cli/nagare-dsl/test/fixtures/nagare/Config.hs`: same change.
- `cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs`: wrap both entries:
  `[(host, runtimeScoped (EnvLiteral "0.0.0.0")), (apiBase, runtimeScoped (EnvLiteral "https://api.example.com"))]`.
- `cli/nagare-dsl/test/Spec.hs` (`helloDep`):
  `env = Map.fromList [(unsafe (mkEnvName "TARGET"), runtimeScoped (EnvLiteral "Nagare"))]`.
- `cli/nagare-dsl/test/ServerSpec.hs` (`notesApp`): wrap both entries in `runtimeScoped`.

At this point `Config.hs` (`Nagare.Dsl.Config`), `Load.hs`, `Render.hs`, and
`Server/Render.hs` will **not** compile yet because they pattern-match `EnvVar` where the
map now holds `ScopedEnvVar`. M1 makes the minimal compile-fixing edits that preserve
behavior, deferring the real round-trip and render changes to M2/M3:

- In `Config.hs`, change `envJSON`/`envEntryJSON` to take a `ScopedEnvVar` and match on its
  `value`, emitting the same JSON as before but *not yet* the `"scopes"` field (added in
  M2). For example:

  ```haskell
  envJSON (n, sev) = case sev ^. #value of
    EnvLiteral lit  -> object ["varName" .= envNameText n, "kind" .= ("Literal" :: Text), "value" .= lit]
    EnvSecretRef sn -> object ["varName" .= envNameText n, "kind" .= ("SecretRef" :: Text), "secretName" .= secretNameText sn]
  ```

- In `Load.hs`, change `toEnvEntry`'s result type to `Either LoadError (EnvName, ScopedEnvVar)`
  and wrap the decoded `EnvVar` in `runtimeScoped` for now (M2 reads the real scopes).

- In `Render.hs` and `Server/Render.hs`, change `envField` to take
  `Map EnvName ScopedEnvVar` and unwrap `value` before `envEntryValue`, with no scope
  filtering and no `envFrom` yet (those are M3). For now:

  ```haskell
  envEntry (n, sev) = envEntryValue (envNameText n) (sev ^. #value)
  ```

  (The `Render` modules already import `Data.Generics.Labels ()` so `^. #value` works.)

Commands to run (working directory `cli/nagare-dsl`):

```bash
cabal build
cabal test
```

Acceptance: `cabal build` succeeds. `cabal test` passes with **unchanged** golden files —
M1 changes no JSON and no YAML output, so `test/golden/*.yaml` must still match byte-for-byte.
If any golden test fails at M1, that is a bug (some output changed unintentionally), not a
golden to accept.


### Milestone M2 — Scopes survive the JSON round-trip

Goal: the scope set is written into the emitted JSON and read back, with a missing or empty
`"scopes"` array defaulting to `{Runtime}` for backward compatibility, and an unknown scope
token rejected with a precise `MarshalError`. At the end of M2, a `Deployment` or
`ServerSite` with a `{Build}`-scoped variable emitted by `Config.hs` and re-loaded comes
back with that exact scope set.

Work:

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, make `envJSON`/`envEntryJSON` emit the scope
set as a JSON array of capitalized tokens matching the `Show EnvScope` names
(`"Runtime"`, `"Build"`, `"Preview"`), sorted ascending for determinism (the derived `Ord`
gives `Runtime < Build < Preview`, but render the *tokens* sorted so the JSON is stable):

```haskell
scopeTokensJSON :: ScopedEnvVar -> [Text]
scopeTokensJSON sev = map (Text.pack . show) (Set.toAscList (sev ^. #scopes))

envJSON (n, sev) = case sev ^. #value of
  EnvLiteral lit ->
    object [ "varName" .= envNameText n, "kind" .= ("Literal" :: Text)
           , "value" .= lit, "scopes" .= scopeTokensJSON sev ]
  EnvSecretRef sn ->
    object [ "varName" .= envNameText n, "kind" .= ("SecretRef" :: Text)
           , "secretName" .= secretNameText sn, "scopes" .= scopeTokensJSON sev ]
```

Apply the identical change to `envEntryJSON` in `serverSiteJSON`. Add the imports
`Data.Set qualified as Set` and (if not present) `Data.Text qualified as Text`. The JSON
tokens are the capitalized constructor names (`Runtime`/`Build`/`Preview`); the *resource
name* tokens defined in M3 (`scopeToken`) are lowercased and are a separate concern — do not
conflate them.

In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`:

Add an optional scopes field to the intermediate record and parse it:

```haskell
data JsonEnvEntry = JsonEnvEntry
  { jeVarName :: !Text
  , jeKind :: !Text
  , jeValue :: !(Maybe Text)
  , jeSecretName :: !(Maybe Text)
  , jeScopes :: !(Maybe [Text])
  }

instance FromJSON JsonEnvEntry where
  parseJSON = withObject "EnvEntry" $ \o ->
    JsonEnvEntry <$> o .: "varName" <*> o .: "kind"
                 <*> o .:? "value" <*> o .:? "secretName" <*> o .:? "scopes"
```

Update `toEnvEntry` to decode the value (as today) and the scope set, defaulting a
missing/empty list to `{Runtime}` and rejecting unknown tokens:

```haskell
parseScope :: Text -> Text -> Either LoadError EnvScope
parseScope var t = case t of
  "Runtime" -> Right Runtime
  "Build"   -> Right Build
  "Preview" -> Right Preview
  other     -> Left (MarshalError ("env." <> var <> ".scopes") ("unknown env scope: " <> other))

toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, ScopedEnvVar)
toEnvEntry e = do
  n <- mapLeft (MarshalError "env.varName") $ mkEnvName (jeVarName e)
  v <- case jeKind e of
    "Literal"   -> ...                                 -- unchanged: EnvLiteral
    "SecretRef" -> ...                                 -- unchanged: EnvSecretRef
    other       -> Left (MarshalError ("env." <> jeVarName e <> ".kind") ("unknown env kind: " <> other))
  scopeList <- traverse (parseScope (jeVarName e)) (fromMaybe [] (jeScopes e))
  let scopeSet = Set.fromList scopeList
      finalScopes = if Set.null scopeSet then Set.singleton Runtime else scopeSet
  sev <- mapLeft (MarshalError ("env." <> jeVarName e <> ".scopes")) (scopedEnv finalScopes v)
  Right (n, sev)
```

Because `toEnvEntry`'s default already restores a non-empty set, `scopedEnv` never fails
here; calling it keeps the single invariant-enforcing constructor as the only path to a
`ScopedEnvVar`, which is good hygiene. Add `Data.Set qualified as Set` to `Load.hs`. Note
the `JsonServerSite` decoder already reads `env` with `.:? "env" .!= []`, and the
`JsonDeployment` decoder reads it with `.: "env"`; both feed `mapM toEnvEntry`, so no change
is needed at those call sites beyond the new return type flowing through.

Tests — add to `cli/nagare-dsl/test/LoadSpec.hs` (these run through the pure
`decodeDeployment`, no subprocess):

1. A deployment JSON whose single env entry has `"scopes": ["Build"]` decodes to a
   `Deployment` whose `env` value has `scopes == Set.fromList [Build]`. Assert by decoding
   and inspecting the map (expose the value via the `value`/`scopes` accessors).
2. A deployment JSON whose env entry omits `"scopes"` decodes with `scopes == {Runtime}`
   (backward compatibility). The existing fixtures already cover the "no scopes field"
   path; add an explicit assertion.
3. A deployment JSON with `"scopes": []` (empty array) also decodes to `{Runtime}`.
4. A deployment JSON with `"scopes": ["Nope"]` decodes to
   `Left (MarshalError "env.<var>.scopes" msg)` where `msg` contains `"unknown env scope"`.

Also add a true round-trip unit test in `cli/nagare-dsl/test/Spec.hs` (or `LoadSpec.hs`):
construct a `Deployment` with a `scopedEnv (Set.fromList [Build, Runtime]) (EnvLiteral "x")`
entry, emit it through `Nagare.Dsl.Config` (call the JSON encoder; you can use
`Data.Aeson.encode` on the value the library emits, or capture `emitDeployment` output —
prefer adding a tiny exposed pure encoder if needed, otherwise encode via the existing path
and re-decode with `decodeDeployment`), and assert the decoded scope set equals the original.

Commands (working directory `cli/nagare-dsl`):

```bash
cabal test
```

Acceptance: the four new `LoadSpec` cases and the round-trip case pass. Golden YAML files
are still unchanged at M2 (render is untouched until M3). The emitted JSON now contains
`"scopes"`, but no golden file captures raw JSON, so no golden update is required here.


### Milestone M3 — Scope-filtered inline render, envFrom wiring, and naming helpers

Goal: the inline container `env:` includes only entries whose scope set contains `Runtime`;
every app and server Service emits the `envFrom` block referencing the Runtime managed
ConfigMap and Secret with `optional: true`; and the three naming helpers are exported. At
the end of M3, a config with a Build-only variable renders a Service whose inline `env:`
omits it, and whose `envFrom` references `nagare-env-<app>-runtime` and
`nagare-secret-<app>-runtime`.

Work — naming helpers. Add to `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` and export them
from that module (this is the canonical home named in IP2):

```haskell
-- | The lowercased scope token used in managed-resource names:
-- Runtime -> "runtime", Build -> "build", Preview -> "preview".
scopeToken :: EnvScope -> Text
scopeToken Runtime = "runtime"
scopeToken Build = "build"
scopeToken Preview = "preview"

-- | Name of the non-secret managed-env ConfigMap for one app and scope, e.g.
-- managedConfigMapName "notes" Runtime == "nagare-env-notes-runtime".
managedConfigMapName :: Text -> EnvScope -> Text
managedConfigMapName app s = "nagare-env-" <> app <> "-" <> scopeToken s

-- | Name of the managed-env Secret for one app and scope, e.g.
-- managedSecretName "notes" Runtime == "nagare-secret-notes-runtime".
managedSecretName :: Text -> EnvScope -> Text
managedSecretName app s = "nagare-secret-" <> app <> "-" <> scopeToken s
```

`scopeToken` needs `EnvScope` in scope, so add it to the `Nagare.Dsl.Types` import in
`Render.hs`. Export `scopeToken`, `managedConfigMapName`, `managedSecretName` from the
`Nagare.Dsl.Render` module header. `Server/Render.hs` should *import and reuse* these from
`Nagare.Dsl.Render` rather than redefining them, so there is exactly one owner of the string
format.

Work — scope-filtered inline env. In both `Render.hs` and `Server/Render.hs`, change
`envField` so it filters to Runtime-scoped entries and unwraps `value`:

```haskell
import Data.Set qualified as Set

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
```

`envEntryValue` is unchanged (it already takes a plain `EnvVar`). An entry scoped only
`{Build}` or `{Preview}` is excluded; an entry scoped `{Build, Runtime}` is included. If no
Runtime entry remains, the `env:` block is omitted entirely (preserving the existing
"never emit an empty block" rule).

Work — `envFrom` wiring. Add to both renderers a field builder that is always present
(unlike `env`/`resources`, the `envFrom` block is emitted on every Service):

```haskell
envFromField :: Text -> [Pair]
envFromField app =
  [ "envFrom" .= toJSON
      [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
      , object ["secretRef"    .= object ["name" .= managedSecretName    app Runtime, "optional" .= True]]
      ]
  ]
```

The `app` text is the service/site name: in `Render.hs` it is
`serviceNameText (dep ^. #name)`; in `Server/Render.hs` it is the name the Service is
deployed under, `serviceNameFor site ctx` (which already resolves preview-vs-production).
Insert `envFromField` into the container's `optionals` list, after `env` and before
`resources`, so the document order reads `image`, `ports`, `env`, `envFrom`, `resources`:

```haskell
-- Render.hs:
optionals = envField (dep ^. #env)
         <> envFromField (serviceNameText (dep ^. #name))
         <> resourcesField (dep ^. #resources)

-- Server/Render.hs:
optionals = envField (site ^. #env)
         <> envFromField (serviceNameFor site ctx)
         <> resourcesField (site ^. #resources)
```

Work — key ordering. In both `keyCompare` `ranks` tables, the container object currently
ranks `image(0) < ports(1) < env(2) < resources(3)`. Insert `envFrom` between `env` and
`resources` by re-ranking: `env(2)`, `envFrom(3)`, `resources(4)`. Also add ranks for the
new inner keys so the `envFrom` entries are deterministic: within each `configMapRef` /
`secretRef` object, `name` must precede `optional`. `name` already has rank 2; add
`("optional", 4)` (any rank greater than `name`'s 2 within that object works). Because the
existing `name` rank (2) already sorts before a higher `optional` rank, the `configMapRef`
and `secretRef` inner objects render `name` then `optional` as required. The updated tail of
`ranks`:

```haskell
, ("image", 0)
, ("ports", 1)
, ("env", 2)
, ("envFrom", 3)
, ("resources", 4)
, ("cpu", 0)
, ("memory", 1)
, ("optional", 4)
, ("configMapRef", 0)
, ("secretRef", 1)
```

(`configMapRef`/`secretRef` rank only matters relative to each other inside the list items,
which are separate objects, so their ranks are harmless; they are listed for clarity.)

Work — update goldens and add a behavioral test. The `envFrom` block now appears on every
app and server Service, so these goldens change and must be regenerated:

- `test/golden/hello.service.yaml`
- `test/golden/preset-app-a.service.yaml`
- `test/golden/preset-app-b.service.yaml`
- `test/golden/server-site.service.yaml`

`test/golden/static-site.service.yaml`, `test/golden/hello.domainmapping.yaml`,
`test/golden/server-site.domainmapping.yaml`, and `test/golden/server-site.dockerfile` are
**unchanged** (static carries no env; DomainMappings and the Dockerfile have no container
env). Regenerate the four changed goldens with `cabal test --test-options=--accept`, then
**read the diff** to confirm the only change is the appended `envFrom` block in the expected
place (after `env`, before `resources`), e.g. for `hello`:

```yaml
        env:
        - name: TARGET
          value: Nagare
        envFrom:
        - configMapRef:
            name: nagare-env-hello-runtime
            optional: true
        - secretRef:
            name: nagare-secret-hello-runtime
            optional: true
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

Add a new behavioral golden or unit test that proves the Build-only exclusion (the headline
new behavior). Add to `cli/nagare-dsl/test/Spec.hs` a fixture deployment that has one
Runtime variable and one Build-only variable:

```haskell
buildOnlyDep :: Deployment
buildOnlyDep = helloDep
  { env = Map.fromList
      [ (unsafe (mkEnvName "API_BASE"), runtimeScoped (EnvLiteral "https://api.example.com"))
      , (unsafe (mkEnvName "BUILD_TOKEN"), unsafe (scopedEnv (Set.singleton Build) (EnvLiteral "abc123")))
      ]
  }
```

Render it with `renderService buildOnlyDep "20260602-120000"` and either (a) add a
`goldenVsString` against a new `test/golden/build-only.service.yaml` whose inline `env:`
contains only `API_BASE` and whose `envFrom` references `nagare-env-hello-runtime`, or
(b) a `tasty-hunit` test that decodes the rendered bytes to `Text` and asserts
`"BUILD_TOKEN"` is *not* present while `"API_BASE"` and `"nagare-env-hello-runtime"` are.
Prefer (a), a golden, for a durable record of the exact shape. (`Set` and `scopedEnv` must
be imported in `Spec.hs`.)

Commands (working directory `cli/nagare-dsl`):

```bash
cabal build
cabal test --test-options=--accept   # regenerate the 4 changed goldens + the new one
git diff -- test/golden              # inspect: only envFrom added where expected
cabal test                           # re-run; everything green against the accepted goldens
```

Acceptance: `cabal test` is green. The four updated goldens differ from their previous
content *only* by the inserted `envFrom` block. The new build-only test demonstrates a
`{Build}`-scoped variable is excluded from inline `env:` while the Runtime variable and the
`envFrom` reference to `nagare-env-hello-runtime` are present. `static-site.service.yaml` is
byte-for-byte unchanged.


## Concrete Steps

All commands run from `cli/nagare-dsl` unless stated otherwise. Enter the flake dev shell
first if not already inside it (the repo uses direnv; `direnv allow` once, or
`nix develop`).

M1:

```bash
cabal build
cabal test
```

Expected (abbreviated) — build succeeds and the suite passes with no golden changes:

```text
All 70+ tests passed (…s)
```

M2:

```bash
cabal test
```

Expected — the new round-trip and scope-decode cases appear and pass, e.g.:

```text
Nagare.Dsl.Load failure modes
  scopes: ["Build"] decodes to {Build}:                  OK
  missing scopes defaults to {Runtime}:                  OK
  empty scopes array defaults to {Runtime}:              OK
  unknown scope token returns MarshalError:              OK
```

M3 — regenerate the four changed goldens and the new build-only golden, inspect, re-run:

```bash
cabal test --test-options=--accept
git diff -- test/golden
cabal test
```

Expected `git diff -- test/golden` shows, for each of `hello`, `preset-app-a`,
`preset-app-b`, and `server-site`, only added lines forming the `envFrom` block between the
existing `env:` (or `ports:` where there is no env) and `resources:`; and a new file
`test/golden/build-only.service.yaml`. Expected final `cabal test`:

```text
All tests passed (…s)
```


## Validation and Acceptance

The acceptance is behavioral, not "code compiles." Three observable facts must hold.

First, backward compatibility: a config that writes a plain `EnvLiteral`/`EnvSecretRef` with
no scope (every existing example) still renders that variable inline. Verify with the `hello`
golden: after M3 its inline `env:` still shows `- name: TARGET` / `value: Nagare`, now
followed by the `envFrom` block. The `preset-app-b` golden still shows the `DATABASE_URL`
secret ref inline (proving `secretEnv` is Runtime-scoped through `runtimeScoped`).

Second, scope filtering: a config with a `{Build}`-only variable renders a Service whose
inline `env:` omits that variable. Verify with the new `test/golden/build-only.service.yaml`
(or the equivalent HUnit assertion): `BUILD_TOKEN` is absent from `env:`, `API_BASE` is
present, and the `envFrom` references `nagare-env-hello-runtime` and
`nagare-secret-hello-runtime`.

Third, the `envFrom` wiring: every rendered app and server Service contains, in the container
spec, exactly:

```yaml
envFrom:
- configMapRef:
    name: nagare-env-<app>-runtime
    optional: true
- secretRef:
    name: nagare-secret-<app>-runtime
    optional: true
```

with `<app>` the service/site name. Verify across the `hello`, `preset-app-a`,
`preset-app-b`, and `server-site` goldens. Verify `static-site.service.yaml` has **no**
`envFrom` (static sites carry no env).

To dump a rendered manifest by hand for inspection, run the loader-and-render path the tests
use against a real config — for example from `cli/nagare-dsl`:

```bash
cabal repl
-- in GHCi:
:set -XOverloadedStrings
import Nagare.Dsl.Load (loadDeployment)
import Nagare.Dsl.Render (renderService)
import qualified Data.ByteString.Char8 as BC
Right dep <- loadDeployment "test/fixtures/nagare/Config.hs"
BC.putStrLn (renderService dep "20260602-120000")
```

The printed YAML must show the `env:` then the `envFrom:` block described above.

The exact test commands are `cabal test` (full suite, all milestones) and, when an output
shape change is intended in M3, `cabal test --test-options=--accept` to regenerate goldens
followed by a plain `cabal test` to confirm the suite is green against the accepted files.
Interpreting results: a failing `tasty-golden` test prints a unified diff of expected vs.
actual bytes; if the diff is anything other than the intended `envFrom` insertion, the
change is wrong and must be fixed rather than accepted.


## Idempotence and Recovery

Every step is safe to repeat. `cabal build` and `cabal test` are idempotent. The only
mutating step is `cabal test --test-options=--accept`, which overwrites golden files; run it
only in M3 and always follow it with `git diff -- test/golden` to confirm the change is
exactly the intended `envFrom` insertion (plus the one new file). If `--accept` captures an
unintended change (e.g. a wrong key order), discard with `git checkout -- test/golden`,
fix the renderer, and re-accept.

The code changes are additive and reversible through version control. `runtimeScoped` and
the decoder's `{Runtime}` default guarantee that no previously valid config becomes invalid:
a config emitting env without `"scopes"` still loads (defaulting to Runtime), so an
old-format JSON and a new-format JSON both decode. There is no on-disk migration and no
destructive operation; reverting the commits restores the previous behavior entirely.


## Interfaces and Dependencies

This plan depends only on libraries already in `nagare-dsl.cabal`: `aeson`, `containers`
(provides `Data.Set` and `Data.Map`), `text`, `yaml`, `lens`, and `generic-lens`; the test
suite already depends on `tasty`, `tasty-golden`, `tasty-hunit`, `tasty-quickcheck`, and
`temporary`. No new dependency is introduced.

This plan **owns** three integration contracts that downstream plans (EP-24 store, EP-25
CLI, EP-26 generated variables, EP-27 build/preview) import and rely on. They are stated
here verbatim so those plans can depend on them without reading the parent MasterPlan.

**IP1 — `EnvScope`, `ScopedEnvVar`, and the env-map type change.** Defined in
`Nagare.Dsl.Types`:

```haskell
-- | When an environment variable applies.
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | An env value (literal or secret reference) plus the non-empty set of scopes
-- it applies to. A bare variable defaults to {Runtime}.
data ScopedEnvVar = ScopedEnvVar
  { value  :: !EnvVar          -- existing sum type: EnvLiteral | EnvSecretRef
  , scopes :: !(Set EnvScope)  -- invariant: non-empty
  }
  deriving stock (Generic, Eq, Show)

runtimeScoped :: EnvVar -> ScopedEnvVar
scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar  -- rejects the empty set
```

The `env` field of both `Deployment` (`Nagare.Dsl.Types`) and `ServerSite`
(`Nagare.Dsl.Server.Types`) is `Map EnvName ScopedEnvVar`. Downstream plans must treat
`Runtime` as the default when a scope is unspecified; the decoder enforces this.

**IP2 — The managed-resource naming helpers.** Defined and exported from
`Nagare.Dsl.Render` (the single owner of the string format):

```haskell
-- | Runtime -> "runtime", Build -> "build", Preview -> "preview".
scopeToken :: EnvScope -> Text

-- | "nagare-env-" <> app <> "-" <> scopeToken s
managedConfigMapName :: Text -> EnvScope -> Text

-- | "nagare-secret-" <> app <> "-" <> scopeToken s
managedSecretName :: Text -> EnvScope -> Text
```

EP-24, EP-25, and EP-27 import these and must never re-derive the names by hand.

**IP3 — The `envFrom` wiring and precedence.** Every rendered Knative Service
(`Nagare.Dsl.Render.renderService` for apps, `Nagare.Dsl.Server.Render.renderServerService`
for server sites) emits, in the container spec, this `envFrom` list referencing the
Runtime-scoped managed ConfigMap and Secret with `optional: true`:

```yaml
envFrom:
- configMapRef:
    name: nagare-env-<app>-runtime
    optional: true
- secretRef:
    name: nagare-secret-<app>-runtime
    optional: true
```

`<app>` is the service/site name (for server sites, the name the Service deploys under, i.e.
`serviceNameFor site ctx`). `optional: true` means an app whose store has never been written
still deploys. The documented Kubernetes precedence is: **`envFrom` is applied first, then
the inline `env:` list**, so inline DSL env (and, later, EP-26 generated variables) overrides
managed env of the same key. EP-25/EP-26/EP-28 must document this precedence. Static sites
(`Nagare.Dsl.Static.Render`) carry no env and emit no `envFrom`; they are unaffected.

The final type signatures that must exist at the end of this plan, with full module paths:

- `Nagare.Dsl.Types.EnvScope` — `data EnvScope = Runtime | Build | Preview`
- `Nagare.Dsl.Types.ScopedEnvVar` — `data ScopedEnvVar = ScopedEnvVar { value :: EnvVar, scopes :: Set EnvScope }`
- `Nagare.Dsl.Types.runtimeScoped :: EnvVar -> ScopedEnvVar`
- `Nagare.Dsl.Types.scopedEnv :: Set EnvScope -> EnvVar -> Either Text ScopedEnvVar`
- `Nagare.Dsl.Types.Deployment.env :: Map EnvName ScopedEnvVar`
- `Nagare.Dsl.Server.Types.ServerSite.env :: Map EnvName ScopedEnvVar`
- `Nagare.Dsl.Render.scopeToken :: EnvScope -> Text`
- `Nagare.Dsl.Render.managedConfigMapName :: Text -> EnvScope -> Text`
- `Nagare.Dsl.Render.managedSecretName :: Text -> EnvScope -> Text`
- `Nagare.Dsl.Load.toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, ScopedEnvVar)`
  (internal, but its new shape is what carries scopes through the loader)
