---
id: 29
slug: extended-application-model-health-checks-resource-limits-multiple-domains
title: "Extended application model: health checks, resource limits, multiple domains"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# Extended application model: health checks, resource limits, multiple domains

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the first child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It is self-contained: you do
not need to read the MasterPlan or any sibling plan to implement it. Where it defines an artifact
that a sibling plan consumes, that is noted, but nothing here depends on a sibling.


## Purpose / Big Picture

Today a Nagare application is described by a single Haskell record, `Deployment`, defined in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`. An app author writes a `nagare/Config.hs` that constructs a
`Deployment` (usually via the `webService` preset in `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`) and
emits it as JSON; `nagarectl deploy` loads that JSON, renders a Knative `Service` (and at most one
`DomainMapping`), applies them, and waits for readiness. That model is thinner than a real PaaS
application in three ways that this plan fixes:

1. **No health checks.** Knative can run an HTTP *readiness probe* (don't send traffic to a pod until
   it answers), a *liveness probe* (restart a pod that stops answering), and a *startup probe* (give a
   slow-booting pod extra grace before the other probes apply). Nagare cannot express any of these, so
   every app uses Knative's default TCP readiness check only.

2. **Resource requests but not limits.** A Kubernetes container can declare *requests* (the CPU/memory
   it is guaranteed and scheduled against) and *limits* (the ceiling it may not exceed). Nagare's
   `Resources` type today carries only requests; the renderer emits `resources.requests` and never
   `resources.limits`. An app cannot cap its memory.

3. **At most one custom domain.** `Deployment` has `domain :: Maybe Domain`, so an app can have one
   custom hostname or none. Real apps often serve several (`app.example.com`, `www.example.com`,
   `example.com`), and one of them is "canonical" — the address you advertise and redirect toward.

After this plan, an app author can write — entirely in the typed config, with illegal states rejected
at construction — an optional HTTP health check, both resource requests and limits, and a list of
domains with exactly one marked canonical. The renderer turns these into Knative `readinessProbe`/
`livenessProbe`/`startupProbe` blocks, a `resources.limits` block, and one `DomainMapping` per domain;
and it stamps every Service with a label `nagare.dev/managed-by: nagarectl` so other Nagare commands
can recognize Nagare-managed apps. **Crucially, every existing config keeps working unchanged**: a
config that mentions none of the new fields renders byte-for-byte as it does today, because health
checks default to absent, limits default to absent, and the domain list defaults to empty.

You can see it working by running the package's golden tests (`cabal test` in `cli/nagare-dsl`), which
compare the rendered YAML against committed fixture files, and by a `nagarectl deploy --dry-run` that
now prints probe and `limits` blocks and multiple DomainMapping documents for a config that declares
them.


## Progress

- [x] M1: `HealthCheck` type + `Resources` limits added with smart constructors and unit tests. (2026-06-10)
- [x] M2: `domain → domains :: [DomainSpec]` with `mkDomains` canonical-enforcing constructor; presets/fixtures/examples updated to compile. (2026-06-10)
- [x] M3: JSON emission (`Config.hs`) and decoding (`Load.hs`) round-trip the new fields; round-trip test passes. (2026-06-10)
- [x] M4: Renderer emits probes, `resources.limits`, per-domain DomainMappings, and the managed-by label; `serviceUrl` and deploy call sites updated; golden fixtures regenerated; `cabal test` green in both packages. (2026-06-10)


## Surprises & Discoveries

- EP-23 (scoped env, a child of MasterPlan 5) had already landed before this plan
  started, contrary to MasterPlan 6's IP5 expectation that EP-29 would land first. The
  `Deployment.env` field is therefore already `Map EnvName ScopedEnvVar` (not
  `Map EnvName EnvVar` as this plan's Context section assumed), and `Resources` literals
  now also live in the env-scope-aware codebase. The changes were fully orthogonal as IP5
  predicted: health/limits/domains touched different fields, and EP-29 rebased onto the
  pluralized env model with no conflict. Evidence: `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`
  already defined `ScopedEnvVar`, `runtimeScoped`, `scopedEnv`, and the recent commits
  baf4c92–1469785 are EP-25..EP-28 (MasterPlan 5). (2026-06-10)

- The `nagare.dev/managed-by: nagarectl` label is rendered on **every** Service
  unconditionally, so all four existing Deployment service goldens (`hello`, `build-only`,
  `preset-app-a`, `preset-app-b`) changed — each gained exactly the two-line `labels:` block
  and nothing else (verified by `git diff`). The plan's "existing goldens unchanged" invariant
  holds for the probe/limits/domain blocks (a config declaring none of those renders no probe
  or limits YAML — proven by a dedicated test) but **not** for the label, which is a deliberate
  universal addition. The server-site and static-site service goldens are rendered by separate
  renderers (`Nagare.Dsl.Server.Render`, `Nagare.Dsl.Static.Render`) that this plan did not
  touch, so they did not get the label and stayed byte-for-byte identical. (2026-06-10)

- `Resources` is shared by `ServerSite` as well as `Deployment`, and `Nagare.Dsl.Server.Render`
  has its **own** `resourcesField` that reads only `cpu`/`memory`. Adding `cpuLimit`/`memoryLimit`
  (defaulting to `Nothing`) to `Resources` therefore required updating every `Resources {…}`
  literal across the workspace (presets, both loaders, three fixtures, two test specs) but did
  **not** change server-site rendering output. (2026-06-10)


## Decision Log

- Decision: Model the three Knative probes with a single `HealthCheck` value that describes one HTTP
  GET check, and apply it as the readiness probe always, and as the liveness and startup probes when
  the author opts in via booleans on the record.
  Rationale: A single HTTP endpoint (e.g. `/healthz`) is almost always the same for readiness,
  liveness, and startup; one shared description with opt-in flags avoids three near-identical records
  while still letting the renderer emit all three Knative probe keys. Keeps the common case (just a
  readiness check) a one-liner.
  Date: 2026-06-10

- Decision: Represent domains as `domains :: [DomainSpec]` where `DomainSpec = DomainSpec { domain ::
  Domain, canonical :: Bool }`, constructed through `mkDomains :: [(Text, Bool)] -> Either Text
  [DomainSpec]` which rejects a list with zero or more-than-one canonical entries (an empty list is
  allowed and means "no custom domain").
  Rationale: Mirrors the existing `ServerSite.domains :: [Domain]` while adding the canonical marker
  the roadmap asks for, and makes "two canonical domains" or "a non-empty list with no canonical"
  unrepresentable after construction. The wildcard Knative URL is still used when the list is empty.
  Date: 2026-06-10

- Decision: Carry limits inside the existing `Resources` record by adding `cpuLimit`/`memoryLimit`
  fields, rather than introducing a separate `limits :: Maybe Resources` field on `Deployment`.
  Rationale: Keeps all resource quantities in one place, keeps the `Deployment` record changes
  minimal, and lets the renderer emit `requests` and `limits` from one source. The existing
  `cpu`/`memory` fields become the requests; the new fields are the optional limits.
  Date: 2026-06-10

- Decision: Render the `nagare.dev/managed-by: nagarectl` label unconditionally on every
  Deployment Service and accept the resulting change to the four existing service goldens, after
  confirming via `git diff` that the *only* change to each is the added two-line `labels:` block.
  Rationale: `app list` (EP-30) needs every Nagare-managed app to carry the label; a conditional
  label would defeat its purpose. The regenerated goldens are a reviewed, understood change — not
  a blind `--accept` — and a separate test asserts a label-free probe/limits surface for configs
  that declare none of the new fields, preserving the real backward-compat guarantee.
  Date: 2026-06-10

- Decision: Add committed `rich.service.yaml` / `rich.domainmapping.yaml` golden fixtures rendered
  from a single `richDep` (liveness+startup health check, both requests and limits, two domains
  with one canonical) instead of (or in addition to) relying on a manual `--dry-run` transcript.
  Rationale: A committed golden is a reviewable, regression-proof artifact that exercises the exact
  same `renderService`/`renderDomainMappings` code path the dry-run prints, so it subsumes the
  manual check and proves Validation point 3 in CI.
  Date: 2026-06-10

- Decision: Decode `JsonDomainSpec.canonical` with a `.!= False` default and `JsonHealthCheck`
  fields with `.!=` defaults mirroring `httpHealthCheck`, and report a non-empty domain list with
  no/too-many canonical entries as `MarshalError "domains"` (re-running `mkDomains` on decode).
  Rationale: Keeps the loader's defence-in-depth contract — every field is re-validated through the
  same smart constructor the in-process model uses — while letting partial/hand-written JSON decode
  to documented defaults rather than failing with an opaque aeson parse error.
  Date: 2026-06-10


## Outcomes & Retrospective

Completed 2026-06-10. All four milestones landed; both `cli/nagare-dsl` (165 tests) and
`cli/nagarectl` (89 tests) build and test green.

What exists now that did not before:

- `HealthCheck`/`HealthScheme` types with `mkHealthCheck` (validates an assembled record) and
  `httpHealthCheck` (path → defaulted check) in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`.
- `Resources` carries optional `cpuLimit`/`memoryLimit` alongside the existing `cpu`/`memory`
  requests.
- `Deployment.domain :: Maybe Domain` is now `domains :: [DomainSpec]` with `mkDomains`
  (enforces exactly one canonical in a non-empty list) and `canonicalDomain`. `healthCheck ::
  Maybe HealthCheck` added.
- The renderer (`Nagare.Dsl.Render`) emits `readinessProbe` (always when a check is present) plus
  `livenessProbe`/`startupProbe` (opt-in), a `resources.limits` block, one `DomainMapping` per
  domain via `renderDomainMappings`, and the `nagare.dev/managed-by: nagarectl` label on every
  Service. `Nagare.Deploy.serviceUrl` reports the canonical domain.
- JSON emit (`Config.hs`) and decode (`Load.hs`) round-trip all new fields; backward-compatible
  defaults mean old JSON (no `domains`/`healthCheck`/limits keys) still decodes.

Verification artifacts: the `rich.service.yaml` / `rich.domainmapping.yaml` goldens show the full
new surface; the `extendedModelTests` group asserts the round-trip, label, probes, limits, and the
label-free/probe-free rendering for a bare config; `mkHealthCheck`/`mkDomains` validation cases
cover the rejection paths.

Note for the EP-30 implementer: the integration contract label string is exactly
`nagare.dev/managed-by: nagarectl` (see `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`
`serviceValue`). The hard HTTP redirect between non-canonical and canonical domains remains
deferred as stated in the MasterPlan scope — a `DomainMapping` is rendered for every domain and
the canonical one drives `serviceUrl`, but no redirect rule is installed.


## Context and Orientation

Everything in this plan lives in the `cli/nagare-dsl` package (the typed DSL library) plus two small
call-site edits in `cli/nagarectl` (the CLI that consumes the library). You will not touch any cluster.

**The package layout.** `cli/nagare-dsl/nagare-dsl.cabal` lists the exposed modules. The ones this
plan edits are:

- `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` — the typed model. Defines `Deployment` and every field
  type (`ServiceName`, `Namespace`, `ImageRef`, `Port`, `Quantity`, `Resources`, `Scale`, `Domain`,
  `EnvVar`, …). Each newtype hides its constructor behind a validating `mkX :: ... -> Either Text X`
  smart constructor and a read-only accessor. The `Deployment` record itself has no hidden constructor;
  its safety comes from its field types. The current record is:

  ```haskell
  data Deployment = Deployment
    { name      :: !ServiceName
    , namespace :: !Namespace
    , image     :: !ImageRef
    , build     :: !BuildSpec
    , domain    :: !(Maybe Domain)
    , port      :: !Port
    , env       :: !(Map EnvName EnvVar)
    , resources :: !(Maybe Resources)
    , scale     :: !(Maybe Scale)
    }
  ```

  The current `Resources` and `Domain`:

  ```haskell
  data Resources = Resources
    { cpu    :: !(Maybe Quantity)
    , memory :: !(Maybe Quantity)
    }

  newtype Domain = Domain Text          -- mkDomain rejects empty, spaces, and URI schemes
  ```

  `Quantity` (e.g. `"250m"`, `"512Mi"`) is constructed by `mkQuantity`; `Port` by `mkPort` (1–65535).

- `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs` — the `webService` preset and overlays. `webService`
  constructs a `Deployment` record literal; it currently sets `domain = Nothing`. It must be updated
  to set `domains = []` and `healthCheck = Nothing`, and `stdResources`/`production` may set limits.

- `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` — JSON *emission*. `deploymentJSON :: Deployment -> Value`
  builds the JSON object an app's `Config.hs` writes to stdout. Today it emits `"domain"`,
  `"cpuRequest"`, `"memoryRequest"`, `"scaleMin"`, `"scaleMax"`, etc. (no limits, no health check, a
  single domain). `encodeDeployment :: Deployment -> LBS.ByteString` is exported for in-process
  round-trip tests.

- `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` — JSON *decoding*. A `JsonDeployment` intermediate record is
  parsed with Aeson, then `toDeployment :: JsonDeployment -> Either LoadError Deployment` re-runs the
  smart constructors. `LoadError` has variants `FileNotFound`, `CompileError`, `MissingBinding`,
  `MarshalError !Text !Text`, `UnexpectedKind`; `renderLoadError` turns them into messages. The
  pure entry point is `decodeDeployment :: ByteString -> Either LoadError Deployment`; the IO one is
  `loadDeployment :: FilePath -> IO (Either LoadError Deployment)`.

- `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` — renders a `Deployment` to Knative YAML.
  `renderService :: Deployment -> Text -> ByteString` and
  `renderDomainMapping :: Deployment -> Maybe ByteString`. Rendering goes through
  `Data.Yaml.Pretty.encodePretty` with an explicit key comparator `keyCompare` (the Knative key order
  is not alphabetical, so the comparator assigns ranks to keys). `containerValue` builds the container
  object: `image`, `ports`, then optional `env` and `resources`. `resourcesField` today emits only
  `resources.requests`. `domainMappingValue` builds one DomainMapping from one `Domain`.

**Two consumer call sites in `cli/nagarectl`** that the `domain → domains` change forces to update:

- `cli/nagarectl/src/Nagare/Deploy.hs` — `serviceUrl :: Deployment -> Text -> Text` currently does
  `case dep ^. #domain of Just d -> "https://" <> domainText d; Nothing -> <wildcard URL>`. It must
  select the canonical domain from `domains` instead.

- `cli/nagarectl/app/Main.hs` — `runDeploy` calls
  `dmBytes = maybeToList (renderDomainMapping dep)` and prints each DomainMapping. It must call the
  new plural `renderDomainMappings dep :: [ByteString]`.

**The test suite.** `cli/nagare-dsl`'s tests use `tasty` with `tasty-golden`, `tasty-hunit`, and
`tasty-quickcheck`. The test modules are `LoadSpec`, `ServerSpec`, `StaticSpec` under
`cli/nagare-dsl/test/`. Golden tests compare rendered output to committed `.golden` files; a
round-trip test encodes a `Deployment` and decodes it back. Fixtures used by the loader live under
`cli/nagare-dsl/test/fixtures/` (e.g. `cli/nagare-dsl/test/fixtures/nagare/Config.hs`).

**Term definitions.** *Knative Service* — the single custom resource Nagare deploys; it owns the pods,
autoscaling, and routing. *DomainMapping* — a Knative resource that points a custom hostname at a
Service. *Probe* — a periodic check Kubernetes runs against a container (`httpGet`, `tcpSocket`, or
`exec`); we use `httpGet`. *Request/limit* — the guaranteed vs. ceiling resource amounts. *Golden
test* — a test that compares produced output to a committed expected file and fails on any difference.


## Plan of Work

### Milestone 1 — `HealthCheck` type and resource limits

Scope: add the typed shapes and their smart constructors and unit tests, with no renderer or JSON
changes yet, so the model compiles and the constructors are proven before anything consumes them.

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`:

- Add a `HealthCheck` record and export it (add it to the module export list near `Resources`):

  ```haskell
  -- | An HTTP health check applied to the container. Rendered as a Knative
  -- @readinessProbe@ always, and additionally as @livenessProbe@/@startupProbe@
  -- when 'asLiveness'/'asStartup' are set. All timings are in seconds.
  data HealthCheck = HealthCheck
    { path             :: !Text       -- ^ HTTP path, e.g. "/healthz". Must start with "/".
    , checkPort        :: !(Maybe Port) -- ^ Port to probe; Nothing means the container port.
    , scheme           :: !HealthScheme -- ^ HTTP or HTTPS.
    , expectedStatus   :: !Int        -- ^ Expected HTTP status, default 200. (Knative supports httpHeaders, not status assert; see render note.)
    , initialDelay     :: !Int        -- ^ Seconds before the first probe. >= 0.
    , period           :: !Int        -- ^ Seconds between probes. >= 1.
    , timeout          :: !Int        -- ^ Per-probe timeout seconds. >= 1.
    , failureThreshold :: !Int        -- ^ Consecutive failures before unhealthy. >= 1.
    , asLiveness       :: !Bool       -- ^ Also emit a livenessProbe.
    , asStartup        :: !Bool       -- ^ Also emit a startupProbe.
    }
    deriving stock (Generic, Eq, Show)

  data HealthScheme = HTTP | HTTPS
    deriving stock (Generic, Eq, Show, Enum, Bounded)
  ```

  Provide a smart constructor `mkHealthCheck` that validates: `path` non-empty and starts with `/`;
  `expectedStatus` in 100–599; `initialDelay >= 0`; `period`, `timeout`, `failureThreshold >= 1`. It
  returns `Either Text HealthCheck`. Also provide a convenience `httpHealthCheck :: Text -> Either Text
  HealthCheck` that fills sensible defaults (`scheme = HTTP`, `expectedStatus = 200`,
  `initialDelay = 0`, `period = 10`, `timeout = 1`, `failureThreshold = 3`, `asLiveness = False`,
  `asStartup = False`, `checkPort = Nothing`) and only takes the path. Note in a comment that Knative's
  `httpGet` probe does not assert a response status (any 2xx/3xx is healthy); `expectedStatus` is
  retained in the model for documentation and future use and is *not* rendered — record this honestly
  so a reader is not misled. Export `HealthCheck(..)`, `HealthScheme(..)`, `mkHealthCheck`,
  `httpHealthCheck`.

- Extend `Resources` with optional limits and keep the existing requests fields:

  ```haskell
  data Resources = Resources
    { cpu         :: !(Maybe Quantity)  -- ^ CPU request.
    , memory      :: !(Maybe Quantity)  -- ^ Memory request.
    , cpuLimit    :: !(Maybe Quantity)  -- ^ CPU limit (ceiling).
    , memoryLimit :: !(Maybe Quantity)  -- ^ Memory limit (ceiling).
    }
  ```

  This is a breaking change to every `Resources` literal in the repo (in `Presets.hs` and any fixture
  that builds one). Update them all in this milestone to add `cpuLimit = Nothing, memoryLimit =
  Nothing` (or real limits where appropriate). Search with `rg "Resources \{" cli/` to find them.

- Add the `healthCheck` field to `Deployment` and change `domain` to `domains` (the domains change is
  Milestone 2; you may do the record-shape edit here and the constructor in M2, but it is cleaner to do
  the whole record change in M2 — keep M1 to `HealthCheck` + `Resources` + adding `healthCheck ::
  !(Maybe HealthCheck)` to the record). After this milestone the record is:

  ```haskell
  data Deployment = Deployment
    { name        :: !ServiceName
    , namespace   :: !Namespace
    , image       :: !ImageRef
    , build       :: !BuildSpec
    , domain      :: !(Maybe Domain)     -- still single here; becomes 'domains' in M2
    , port        :: !Port
    , env         :: !(Map EnvName EnvVar)
    , resources   :: !(Maybe Resources)
    , scale       :: !(Maybe Scale)
    , healthCheck :: !(Maybe HealthCheck)
    }
  ```

  Update `webService` in `Presets.hs` to set `healthCheck = Nothing` so it still compiles. Update any
  fixture `Config.hs` that builds a `Deployment` record literal directly (search `rg "Deployment$|
  Deployment \{" cli/`).

Add unit tests in a new or existing tasty test (e.g. extend `LoadSpec` or add a `TypesSpec`) asserting:
`mkHealthCheck` rejects a path without a leading slash and a `period` of 0; `httpHealthCheck "/healthz"`
succeeds with the documented defaults. Acceptance: `cabal test` compiles and the new HUnit cases pass.

### Milestone 2 — Multiple domains with a canonical marker

Scope: replace the single optional domain with a validated list, updating every construction site so
the whole workspace compiles. After this milestone the model supports several domains with exactly one
canonical, but nothing renders them yet (that is M4).

In `Nagare/Dsl/Types.hs`:

- Add `DomainSpec` and a constructor, and export them:

  ```haskell
  -- | A custom domain plus whether it is the canonical (advertised) one.
  data DomainSpec = DomainSpec
    { domain    :: !Domain
    , canonical :: !Bool
    }
    deriving stock (Generic, Eq, Show)

  -- | Build a domain list from (hostname, isCanonical) pairs. An empty list is
  -- allowed (no custom domain). A non-empty list must have EXACTLY one canonical
  -- entry. Each hostname goes through 'mkDomain'.
  mkDomains :: [(Text, Bool)] -> Either Text [DomainSpec]
  ```

  `mkDomains` validates each hostname via `mkDomain`, and checks the canonical count: zero entries →
  `Right []`; non-empty with exactly one `True` → `Right [...]`; otherwise `Left` with a precise
  message ("a non-empty domain list must mark exactly one domain canonical, found N"). Provide a helper
  `canonicalDomain :: [DomainSpec] -> Maybe Domain` returning the canonical entry's domain (Nothing for
  an empty list). Export `DomainSpec(..)`, `mkDomains`, `canonicalDomain`.

- Change the `Deployment` record field from `domain :: !(Maybe Domain)` to `domains :: ![DomainSpec]`.

In `Nagare/Dsl/Presets.hs`: change `webService` to set `domains = []`; change `teamDefaults` (which
does `& #domain .~ Nothing`) to `& #domains .~ []`. Any overlay or example that set `domain` must move
to `domains`.

In `cli/nagarectl/src/Nagare/Deploy.hs`: rewrite `serviceUrl` to use the canonical domain:

```haskell
serviceUrl :: Deployment -> Text -> Text
serviceUrl dep baseDomain =
  case canonicalDomain (dep ^. #domains) of
    Just d  -> "https://" <> domainText d
    Nothing -> "https://" <> serviceNameText (dep ^. #name)
                 <> "." <> namespaceText (dep ^. #namespace)
                 <> "." <> baseDomain
```

Import `canonicalDomain` from `Nagare.Dsl.Types`.

Update every fixture/example `Config.hs` that referenced `domain`. Search the whole repo
(`rg "#domain|\bdomain =|domain ::" cli/ cluster/`). Acceptance: `cabal build` succeeds across the
workspace (`cli/nagare-dsl` and `cli/nagarectl`).

### Milestone 3 — JSON round-trip for the new fields

Scope: teach `Config.hs` to emit the new fields and `Load.hs` to decode them, so a `Deployment` that
declares a health check, limits, and several domains survives `encode` → `decode` unchanged.

In `Nagare/Dsl/Config.hs`, in `deploymentJSON`:

- Replace `"domain" .= fmap domainText (dep ^. #domain)` with
  `"domains" .= map domainSpecJSON (dep ^. #domains)`, where

  ```haskell
  domainSpecJSON ds = object
    [ "domain" .= domainText (ds ^. #domain)
    , "canonical" .= (ds ^. #canonical)
    ]
  ```

- Add `"cpuLimit" .= fmap quantityText (resources >>= (^. #cpuLimit))` and
  `"memoryLimit" .= fmap quantityText (resources >>= (^. #memoryLimit))` alongside the existing
  `cpuRequest`/`memoryRequest`.

- Add `"healthCheck" .= fmap healthCheckJSON (dep ^. #healthCheck)`, where `healthCheckJSON` emits
  every field (`path`, `checkPort` as `fmap portInt`, `scheme` as `"HTTP"`/`"HTTPS"`, `expectedStatus`,
  `initialDelay`, `period`, `timeout`, `failureThreshold`, `asLiveness`, `asStartup`).

In `Nagare/Dsl/Load.hs`:

- Extend the `JsonDeployment` intermediate: replace the single-domain field with `jdDomains ::
  ![JsonDomainSpec]` (default `[]` when the key is absent, for backward compatibility with old JSON);
  add `jdCpuLimit`, `jdMemoryLimit` (optional); add `jdHealthCheck :: !(Maybe JsonHealthCheck)`.
  Define `JsonDomainSpec { jdsDomain :: Text, jdsCanonical :: Bool }` and `JsonHealthCheck` mirroring
  the emitted shape, with Aeson `FromJSON` instances (use `.:?`/`.!=` for optional/defaulted keys so
  absent keys decode to the documented defaults — a missing `healthCheck` → `Nothing`, a missing
  `domains` → `[]`, missing limits → `Nothing`).

- In `toDeployment`, marshal the new fields back through the smart constructors:
  `domains` via `mkDomains [(jdsDomain, jdsCanonical) | …]` (report `MarshalError "domains"` on Left);
  `cpuLimit`/`memoryLimit` via `mkQuantity` (report `MarshalError "cpuLimit"`/`"memoryLimit"`);
  `healthCheck` via `mkHealthCheck` (report `MarshalError "healthCheck"`). Assemble the `Resources`
  value from the four optional quantities; emit `resources = Nothing` only when *all four* are absent
  (so an app with only a limit still gets a `Resources`).

Add a round-trip HUnit test (in `LoadSpec` or a new `TypesSpec`): build a `Deployment` with a health
check, both requests and limits, and two domains (one canonical) via the smart constructors; assert
`decodeDeployment (LBS.toStrict (encodeDeployment dep)) == Right dep`. Acceptance: that test passes.

### Milestone 4 — Renderer: probes, limits, multiple DomainMappings, managed-by label

Scope: emit the new Knative YAML. After this milestone a config that declares the new fields renders
real probe/limits/mapping/label YAML, and a config that declares none renders exactly as before
(verified by unchanged golden files for existing fixtures).

In `Nagare/Dsl/Render.hs`:

- **Managed-by label.** In `serviceValue`, change the `metadata` from `namespacedMeta name ns` to a
  variant that also sets `labels`:

  ```haskell
  "metadata" .= object
    [ "name" .= serviceNameText (dep ^. #name)
    , "namespace" .= namespaceText (dep ^. #namespace)
    , "labels" .= object [ "nagare.dev/managed-by" .= ("nagarectl" :: Text) ]
    ]
  ```

  Add `"labels"` to the `keyCompare` rank table (after `namespace`, before `spec`) so key order stays
  deterministic. **This label string is an integration contract** consumed by EP-30's `app list`
  (`docs/plans/30-nagarectl-app-lifecycle-commands.md`): it must be exactly
  `nagare.dev/managed-by: nagarectl`.

- **Resource limits.** Rewrite `resourcesField` so it emits `requests` and/or `limits` sub-blocks,
  each omitted when empty:

  ```haskell
  resourcesField :: Maybe Resources -> [Pair]
  resourcesField Nothing = []
  resourcesField (Just res)
    | null reqs && null lims = []
    | otherwise = ["resources" .= object (reqBlock <> limBlock)]
    where
      reqs = quantities (res ^. #cpu) (res ^. #memory)
      lims = quantities (res ^. #cpuLimit) (res ^. #memoryLimit)
      reqBlock = if null reqs then [] else ["requests" .= object reqs]
      limBlock = if null lims then [] else ["limits" .= object lims]
      quantities mc mm =
        maybe [] (\q -> ["cpu" .= quantityText q]) mc
          <> maybe [] (\q -> ["memory" .= quantityText q]) mm
  ```

  Add `"limits"` and `"requests"` ranks if needed (requests is already ranked 0; give limits rank 1).

- **Probes.** Add a `probesField :: Maybe HealthCheck -> Port -> [Pair]` that returns the probe keys
  for the container object (it needs the container `Port` as the default probe port). For a `Just hc`
  it emits `readinessProbe` always, plus `livenessProbe` when `asLiveness`, plus `startupProbe` when
  `asStartup`, each an object:

  ```yaml
  readinessProbe:
    httpGet:
      path: /healthz
      port: 8080            # hc.checkPort or the container port
      scheme: HTTP
    initialDelaySeconds: 0
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
  ```

  Build this with `object [...]`; map `HTTP`/`HTTPS` to the strings `"HTTP"`/`"HTTPS"`. Add the probe
  keys (`readinessProbe`, `livenessProbe`, `startupProbe`, `httpGet`, `initialDelaySeconds`,
  `periodSeconds`, `timeoutSeconds`, `failureThreshold`, `scheme`) to `keyCompare` ranks so output is
  deterministic. Note: Knative's `httpGet` probe does not assert `expectedStatus`; do not render it,
  matching the Decision Log note in this plan.

- Wire `probesField` into `containerValue` (append after `resourcesField`):
  `optionals = envField (dep ^. #env) <> resourcesField (dep ^. #resources) <> probesField (dep ^. #healthCheck) (dep ^. #port)`.

- **Multiple DomainMappings.** Replace `renderDomainMapping :: Deployment -> Maybe ByteString` with

  ```haskell
  renderDomainMappings :: Deployment -> [ByteString]
  renderDomainMappings dep =
    map (YP.encodePretty knativeConfig . domainMappingValue dep . (^. #domain)) (dep ^. #domains)
  ```

  Keep `domainMappingValue :: Deployment -> Domain -> Value` as-is. Update the module export list to
  export `renderDomainMappings` instead of `renderDomainMapping`.

In `cli/nagarectl/app/Main.hs` `runDeploy`: change
`dmBytes = maybeToList (renderDomainMapping dep)` to `dmBytes = renderDomainMappings dep`, and update
the import. Remove the now-unused `maybeToList` import if nothing else uses it.

**Regenerate golden fixtures.** Add new golden fixtures that exercise the new fields (a config with a
health check, limits, and two domains) and confirm existing golden fixtures are *unchanged* (a config
mentioning none of the new fields must render identically — if a golden file changed, the change broke
backward compatibility and must be investigated, not blindly accepted). Tasty-golden writes new
`.golden` files with `--accept`; run that only for genuinely new fixtures.

Acceptance: `cabal test` is green in `cli/nagare-dsl`, `cabal build` is green in `cli/nagarectl`, and a
`nagarectl deploy --dry-run` against a config declaring the new fields prints probe/limits/label YAML
and one DomainMapping document per domain (see Validation).


## Concrete Steps

All commands run from the repository root unless a working directory is shown. The repo provides a Nix
dev shell; if `cabal` is not on your PATH, prefix commands with `nix develop -c` (or enter the shell
once with `nix develop`).

Build and test the DSL package after each milestone:

```bash
cd cli/nagare-dsl
cabal build
cabal test
```

Build the CLI package after the M2/M4 call-site edits:

```bash
cd cli/nagarectl
cabal build
cabal test
```

Find every construction site that the breaking record changes affect:

```bash
rg -n "Resources \{|#domain|domain =|renderDomainMapping|maybeToList" cli/ cluster/
```

Exercise the new rendering with a dry run. Use an existing example app config and add the new fields,
or copy a fixture. With the dev environment provisioned (`NAGARE_GHC_ENVIRONMENT` pointing at the
package-environment file, as `nagarectl deploy --help` documents), run:

```bash
cd <an example app project>
nagarectl deploy --dry-run
```

Expected (abridged) transcript showing the new blocks:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: notes
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
spec:
  template:
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes:20260610-...
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
          limits:
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          periodSeconds: 10
          timeoutSeconds: 1
          failureThreshold: 3
--- DomainMapping manifest ---
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: notes.example.com
  namespace: personal
...
--- DomainMapping manifest ---
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: www.example.com
...
```


## Validation and Acceptance

The change is proven by three observable facts:

1. **Unit and round-trip tests pass.** `cabal test` in `cli/nagare-dsl` is green, including the new
   `mkHealthCheck`/`mkDomains` validation cases and the `encodeDeployment`/`decodeDeployment`
   round-trip on a `Deployment` that uses a health check, both requests and limits, and two domains.

2. **Existing golden fixtures are unchanged.** A config that declares none of the new fields renders
   the same bytes as before this plan — confirmed by the existing `.golden` files still matching with
   no `--accept`. This proves backward compatibility (the headline non-negotiable of the plan).

3. **New fields render the expected YAML.** A new golden fixture (or the `--dry-run` transcript above)
   shows `metadata.labels.nagare.dev/managed-by: nagarectl`, a `resources.limits` block, a
   `readinessProbe` (and liveness/startup when opted in), and one `DomainMapping` document per domain
   with the canonical domain also driving the printed `URL:` line.

To verify backward compatibility concretely: before starting, run `cabal test` and note the passing
golden tests; after M4, run it again — the pre-existing golden tests must still pass without
regenerating their files.


## Idempotence and Recovery

Every step is a source edit followed by a rebuild; repeating a build or test is safe. The breaking
record changes (`Resources`, `domain → domains`) will produce compile errors at every unported call
site — that is the recovery guide: build, read the error, port the site, rebuild, until clean. No
cluster or external state is touched, so there is nothing to roll back beyond `git checkout` of the
edited files. Regenerate golden files only with an explicit `--accept` and only for fixtures you
intentionally added; never `--accept` a change to a pre-existing golden file without understanding why
it changed.


## Interfaces and Dependencies

Libraries already in `cli/nagare-dsl/nagare-dsl.cabal`: `aeson` (JSON), `containers` (`Data.Map`),
`text`, `yaml` (`Data.Yaml.Pretty`), `generic-lens` + `lens` (the `^.`/`.~`/`%~`/`#field` optics).
No new dependency is required.

Signatures that must exist at the end of this plan (all in `Nagare.Dsl.Types` unless noted):

```haskell
data HealthCheck = HealthCheck { path :: !Text, checkPort :: !(Maybe Port), scheme :: !HealthScheme
                               , expectedStatus :: !Int, initialDelay :: !Int, period :: !Int
                               , timeout :: !Int, failureThreshold :: !Int
                               , asLiveness :: !Bool, asStartup :: !Bool }
data HealthScheme = HTTP | HTTPS
mkHealthCheck   :: HealthCheck -> Either Text HealthCheck   -- validates an assembled record
httpHealthCheck :: Text -> Either Text HealthCheck           -- path -> defaulted check

data Resources = Resources { cpu :: !(Maybe Quantity), memory :: !(Maybe Quantity)
                           , cpuLimit :: !(Maybe Quantity), memoryLimit :: !(Maybe Quantity) }

data DomainSpec = DomainSpec { domain :: !Domain, canonical :: !Bool }
mkDomains       :: [(Text, Bool)] -> Either Text [DomainSpec]
canonicalDomain :: [DomainSpec] -> Maybe Domain

-- Deployment gains:  domains :: ![DomainSpec]   (replacing domain)
--                    healthCheck :: !(Maybe HealthCheck)

-- Nagare.Dsl.Render:
renderDomainMappings :: Deployment -> [ByteString]   -- replaces renderDomainMapping

-- Nagare.Deploy (cli/nagarectl):
serviceUrl :: Deployment -> Text -> Text             -- now uses canonicalDomain
```

Consumers downstream (in sibling plans, for awareness — not implemented here):
`docs/plans/30-nagarectl-app-lifecycle-commands.md` reads the `nagare.dev/managed-by: nagarectl` label
for `app list` and may read `healthCheck`/`domains`/`resources` for `app get`.
