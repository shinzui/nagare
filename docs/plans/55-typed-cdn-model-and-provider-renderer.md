---
id: 55
slug: typed-cdn-model-and-provider-renderer
title: "Typed CDN model and provider renderer"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Typed CDN model and provider renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A "CDN" (Content Delivery Network) is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to the single Nagare VM in `us-west1`, a
visitor near London or Tokyo is served a cached copy of the response from a nearby edge
location. Nagare's MasterPlan 11 (`docs/masterplans/11-cdn-integration-for-nagare.md`) adds
first-class CDN support so a developer can put their static site, their TanStack Start app, or
any generic container app behind Cloudflare or Google Cloud CDN by adding a few lines to the
same typed `nagare/Config.hs` file they already write — no separate CDN console, no
hand-written load-balancer YAML, no manual DNS edits.

This ExecPlan, EP-55, is the **shared typed contract** at the centre of that initiative: the
one piece of code every later plan reads from and writes to. It is deliberately small and
deliberately library-only. It adds, to the Haskell DSL library `cli/nagare-dsl/`, a typed
model of a CDN configuration and its JSON transport, and it attaches an optional `cdn` field
to the three top-level deployment shapes Nagare already understands (a static site, a
server-rendered site, and a generic container deployment). It renders no infrastructure and
talks to no cloud; it only lets a config author *describe* a CDN, and lets the rest of the
system *read that description back* with the same validation guarantees every other field in
the DSL already enjoys.

After this change, an author can write, in a `nagare/Config.hs`, something like
`cloudflareCdn & withDefaultTtl 3600`, attach the result to their site as `cdn = Just thatCdn`,
and the config will emit a JSON object that carries a nested `"cdn"` block. The loader will
read that block back, re-run every validation rule, and hand the rest of the system a fully
validated `Cdn` value riding inside the site record. You can *see this working entirely
offline* by running the package's test suite: `cd cli/nagare-dsl && cabal test`. The new tests
prove that a CDN with a Cloudflare provider and a 3600-second default TTL round-trips through
JSON unchanged, that a negative TTL or an empty path prefix is rejected with a precise error,
that an unknown provider token is rejected, and — crucially for backward compatibility — that a
config with no CDN emits exactly the JSON it emitted before this plan, with no `"cdn"` key at
all.

The downstream plans that consume this exact contract are EP-56 (Cloudflare provider renderer),
EP-57 (Google Cloud CDN provider renderer), and EP-58 (deploy-time CDN wiring and the
`nagarectl cdn` command group), all under `docs/plans/`. The master plan describes EP-55 as
"a shared typed contract every later plan consumes." Because three later plans depend on the
*shape* defined here, this plan implements that shape verbatim and treats it as fixed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1 — the `Cdn` model: create `cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs` with
  `CdnProvider`, `CdnCacheRule`, `Cdn`, the smart constructor `mkCdnCacheRule`, the validated
  list builder `mkCacheRules`, the presets `cloudflareCdn`/`gcpCloudCdn`, and the combinators
  `withDefaultTtl`/`withCacheRule`/`withoutStaticAssetCache`.
- [ ] Milestone 1 — add `Nagare.Dsl.Cdn.Types` to the `exposed-modules` of
  `cli/nagare-dsl/nagare-dsl.cabal`.
- [ ] Milestone 1 — add a `CdnSpec` test module exercising the constructors, combinators, and
  presets; register it in the `.cabal` test-suite `other-modules` and wire it into `Spec.hs`.
- [ ] Milestone 1 — `cd cli/nagare-dsl && cabal test` passes with the new `CdnSpec` group.
- [ ] Milestone 2 — add `cdn :: !(Maybe Cdn)` to `StaticSite`, `ServerSite`, and `Deployment`.
- [ ] Milestone 2 — emit a nested `"cdn"` object (omitted when `Nothing`) from `staticSiteJSON`,
  `serverSiteJSON`, and `deploymentJSON` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`.
- [ ] Milestone 2 — add the `JsonCdn`/`JsonCdnCacheRule` mirrors and a `toCdn` validator to
  `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, wired into `decodeStaticSite`, `decodeServerSite`,
  and `decodeDeployment`.
- [ ] Milestone 2 — update the three fixture `Config.hs` files (and add CDN-bearing variants)
  under `cli/nagare-dsl/test/fixtures/` to show real usage.
- [ ] Milestone 2 — add golden and negative round-trip tests; confirm existing goldens still
  pass (no `"cdn"` key appears when CDN is absent).
- [ ] Milestone 2 — `cd cli/nagare-dsl && cabal test` passes; capture an emitted-JSON transcript.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: the new field is `cdn :: !(Maybe Cdn)`, not a non-optional `Cdn`.
  Rationale: backward compatibility. Every existing `StaticSite`, `ServerSite`, and
  `Deployment` config, fixture, and golden output predates CDN. `Nothing` means "no CDN, behave
  exactly as before", so existing configs compile and existing golden files are byte-identical.
  A non-optional field would force every config author and every fixture to mention CDN.
  Date: 2026-06-10

- Decision: when `cdn = Nothing`, the encoders OMIT the `"cdn"` key entirely rather than
  emitting `"cdn": null`.
  Rationale: the existing golden JSON/YAML for static sites, server sites, and deployments has
  no `"cdn"` key. Emitting `"cdn": null` would change those bytes and break the golden tests
  that prove backward compatibility. Omission keeps the no-CDN output identical to today's, so
  the only observable JSON change is for configs that actually opt in. The decoders read the
  key with the optional `.:?` combinator, so a missing key decodes to `Nothing`.
  Date: 2026-06-10

- Decision: the provider tokens in JSON are EXACTLY `"Cloudflare"` and `"GcpCloudCdn"`.
  Rationale: this is the wire contract three downstream plans (EP-56, EP-57, EP-58) match
  against. Fixing the strings here, in writing, prevents drift. `"Cloudflare"` reads naturally;
  `"GcpCloudCdn"` mirrors the Haskell constructor name `GcpCloudCdn` so the encode/decode tables
  are mechanical (`Show`-style tokens, the same convention `accessModeToken`/`retentionToken`
  use in `Nagare.Dsl.Config`). Note the asymmetry is intentional: the Haskell constructor for
  Cloudflare is `CloudflareCdn` but its wire token drops the `Cdn` suffix to read as
  `"Cloudflare"`; the GCP token keeps `GcpCloudCdn`. The mapping lives in one place each
  direction so the asymmetry is impossible to get wrong twice.
  Date: 2026-06-10

- Decision: per-path edge TTL is `Maybe Int`, where `Nothing` (encoded as JSON `null`) means
  "never cache this path".
  Rationale: a CDN config commonly needs to say "cache `/assets/` for a year, but never cache
  `/api/`". Modelling the TTL as `Maybe Int` lets a single `CdnCacheRule` express both: a
  `Just seconds` rule caches for that long, a `Nothing` rule is a pass-through (bypass). This is
  cleaner than a sentinel value like `0` or `-1`, which would collide with validation and read
  ambiguously. `edgeTtlSeconds: null` is therefore a *meaningful* value, not an absent field.
  Date: 2026-06-10

- Decision: combinators that cannot fail are total (`withDefaultTtl`, `withoutStaticAssetCache`
  return `Cdn`); combinators that can fail validation return `Either Text`
  (`mkCdnCacheRule`, `withCacheRule`, `mkCacheRules`).
  Rationale: this matches the repository's existing approach. Leaf builders that validate
  (`mkSiteName`, `mkCachePolicy`, `mkHeaderRule`, `mkRedirectRule` in
  `Nagare.Dsl.Static.Types`) return `Either Text`; pure transformations that cannot produce an
  invalid value are plain functions. `withDefaultTtl` is kept total (it takes an `Int` and sets
  the field) for ergonomics, and the validating entry points are
  `mkCdnCacheRule`/`withCacheRule`/`mkCacheRules`, which is where untrusted per-path TTLs enter.
  A default TTL set via `withDefaultTtl` is not validated by the combinator itself, but a
  hand-written or out-of-range value is still caught on the round-trip by the loader's `toCdn`
  re-validation (which rejects a negative `cdn.defaultTtlSeconds`), so nothing invalid reaches
  the rest of the system. See "Interfaces and Dependencies" for the exact signatures.
  Date: 2026-06-10

- Decision: the contract shape (field names, provider tokens, `null`-means-never-cache) is
  fixed by EP-54, the substrate spike at
  `docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`.
  Rationale: EP-54 proves the cloud topology (Google global load balancer health-checking
  Kourier while preserving the `Host` header; Cloudflare proxying a wildcard origin that still
  presents a valid TLS certificate) and, in doing so, pins down what knobs a CDN config actually
  needs to expose. EP-55 hard-depends on EP-54: this plan must not invent shape that EP-54's
  findings contradict. If EP-54's outcome differs from the shape transcribed here, update this
  plan's Decision Log and the contract before implementing.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This work happens entirely inside one Haskell package: `cli/nagare-dsl/`. That package is the
"DSL" (domain-specific language) library for Nagare — a set of carefully validated Haskell
types that describe a deployment, plus encoders that turn those types into JSON and decoders
that read the JSON back. It builds with GHC 9.12.3 and `cabal`. Its dependencies include
`aeson` (JSON), `text`, `containers`, `generic-lens` (^>=2.2), `lens` (^>=5.3), `bytestring`,
and `yaml`. You do not need any cloud access, any cluster, or any network to do this plan: it
is pure library code and offline tests.

A few conventions of this package matter and are worth stating plainly, because you will mirror
them exactly.

First, **field access uses the overloaded-labels lens syntax**. You will see `site ^. #cache`
in the code; that reads the `cache` field of `site`. The `#cache` is an overloaded label, made
available by importing `Data.Generics.Labels` from `generic-lens` (note: the custom prelude
`Nagare.Dsl.Prelude` deliberately does *not* re-export it, so any module that uses `#field`
access imports `import "generic-lens" Data.Generics.Labels ()` itself). The `^.` operator comes
from `lens`, re-exported by the prelude.

Second, **leaf values are built through validating "smart constructors"** named `mkX`, each of
which returns `Either Text X`: a `Left` carries a human-readable error message, a `Right`
carries the validated value. For example, in
`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs`:

```haskell
data CachePolicy = CachePolicy { immutableAssets :: !Bool, defaultMaxAge :: !(Maybe Int) }

-- | Validate and construct a 'CachePolicy'. A negative @defaultMaxAge@ is rejected.
mkCachePolicy :: Bool -> Maybe Int -> Either Text CachePolicy
mkCachePolicy immutable maxAge
  | Just n <- maxAge, n < 0 = Left ("cache max-age must be >= 0, got: " <> tshow n)
  | otherwise = Right (CachePolicy {immutableAssets = immutable, defaultMaxAge = maxAge})
```

Note `tshow` there: it is a tiny module-internal helper, `tshow = Text.pack . show`, defined at
the bottom of that file. You will define an identical helper in the new CDN module so error
messages can interpolate numbers.

Third, **the JSON transport is a deliberate boundary**. A user's `nagare/Config.hs` is a tiny
Haskell program whose `main` calls one of the `emit*` functions in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (`emitStaticSite`, `emitServerSite`,
`emitDeployment`, …). Each `emit*` builds an `aeson` `Value` with `object [ "field" .= ... ]`
and writes the encoded JSON to standard output. On the other side,
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` reads that JSON back. The loader does not trust the
JSON: it decodes it into an intermediate `Json*` record (a plain mirror of the wire shape with
`FromJSON` instances), then runs a `toX` function that re-applies every smart constructor, so
an invalid value that somehow reached the wire is still rejected — "defence in depth". Failures
become a precise `LoadError`. The two `LoadError` constructors that matter here are
`MarshalError !Text !Text` (a named field failed validation — first argument is a dotted field
path like `"cdn.provider"`, second is the message) and `UnexpectedKind !Text !Text` (the config
emitted the wrong top-level shape).

Fourth, **the top-level shapes carry a `"kind"` discriminator, except `Deployment`**. A
`StaticSite` emits `"kind": "StaticSite"`; a `ServerSite` emits `"kind": "ServerSite"`; a
`Database` and a `Task` likewise. A `Deployment` emits *no* `"kind"` key — its absence is how
the loader tells a deployment apart from a kinded shape. The loader reads a minimal
`JsonKindEnvelope { jkeKind :: Maybe Text }` first, then dispatches. You will not change any of
this; the `cdn` field rides *inside* each shape, so it has no effect on kind dispatch.

The three records you will edit are:

`StaticSite` in `cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` has fields `name`, `namespace`,
`image`, `build`, `domains :: [Domain]`, `redirects`, `headers`, `cache`, `notFound`. It is the
Nginx-served folder-of-files case (MasterPlan 3). Its design and renderer come from
`docs/plans/13-typed-static-site-model-and-renderer.md` (EP-13), which is checked in; this plan
soft-depends on it because it edits the `StaticSite` record.

`ServerSite` in `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` has fields `name`, `namespace`,
`image`, `build`, `runtime`, `port`, `env`, `resources`, `scale`, `domains :: [Domain]`,
`volumes`. It is the build-from-source Node-server case (TanStack Start). Its design comes from
`docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md` (EP-18), checked in; this
plan soft-depends on it for the same reason.

`Deployment` in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` has fields `name`, `namespace`,
`image`, `build`, `domains :: [DomainSpec]`, `port`, `env`, `resources`, `scale`, `healthCheck`,
`volumes`, `databases`, `tasks`. It is the run-a-prebuilt-image generic web service.

The encoders for the three shapes are `staticSiteJSON`, `serverSiteJSON`, and `deploymentJSON`,
all in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. The decoders are `decodeStaticSite`,
`decodeServerSite`, and `decodeDeployment` in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, each with
a `Json*` mirror record and a `toX` validator. `loadSite :: FilePath -> IO (Either LoadError
SiteConfig)` (where `SiteConfig = SiteStatic StaticSite | SiteServer ServerSite`) and
`loadDeployment` are the IO entry points; their signatures **do not change** — the `Cdn` rides
inside the record they already return.

Tests live in `cli/nagare-dsl/test/`: `StaticSpec.hs`, `ServerSpec.hs`, `LoadSpec.hs`, and the
driver `Spec.hs`, with golden fixtures under `cli/nagare-dsl/test/fixtures/` (one
`nagare/Config.hs` per shape) and golden output under `cli/nagare-dsl/test/golden/`. The repo
prizes golden tests (compare exact output to a checked-in file) and *negative* tests (feed
invalid input, assert a precise error). You will add both.


## Plan of Work

The work splits into two milestones, each independently verifiable by `cabal test`. Milestone 1
builds the model in isolation — types, constructors, combinators, presets, and unit tests — with
no change to any existing record or encoder, so it cannot break existing behaviour. Milestone 2
attaches the field to the three records, wires the encoders and decoders, updates the fixtures,
and adds round-trip and backward-compatibility tests.


### Milestone 1 — the typed CDN model

Scope: a self-contained new module that defines what a CDN configuration *is* and how to build
one safely, with unit tests, touching nothing else. At the end of this milestone the type
`Cdn` exists, can be constructed only through validating entry points, and has presets and
combinators a config author would actually use. Nothing yet emits or reads it.

Create the new module `cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs`. It defines three data types
and their builders. The provider enumeration:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn
  deriving stock (Generic, Eq, Show)
```

A per-path edge cache rule — requests whose path begins with `pathPrefix` get `edgeTtlSeconds`
as their edge TTL, and `Nothing` means "never cache this path":

```haskell
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)
```

And the CDN configuration itself:

```haskell
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)
```

The validating constructor for one rule rejects an empty or all-whitespace `pathPrefix` and a
negative TTL, mirroring `mkCachePolicy`'s style:

```haskell
-- | Validate and construct a 'CdnCacheRule'. The @pathPrefix@ must be non-empty
-- and not all whitespace; a 'Just' @edgeTtlSeconds@ must be >= 0. A 'Nothing'
-- TTL means "never cache this path" and is always allowed.
mkCdnCacheRule :: Text -> Maybe Int -> Either Text CdnCacheRule
mkCdnCacheRule prefix ttl
  | Text.null prefix = Left "cdn cache rule pathPrefix must not be empty"
  | Text.all isSpace prefix =
      Left "cdn cache rule pathPrefix must not be all whitespace"
  | Just n <- ttl, n < 0 =
      Left ("cdn cache rule edgeTtlSeconds must be >= 0 (or null), got: " <> tshow n)
  | otherwise = Right (CdnCacheRule {pathPrefix = prefix, edgeTtlSeconds = ttl})
```

Two presets give a config author a one-word starting point. They use sensible defaults: no
default-TTL override (let the provider/origin headers decide), static-asset caching on, and no
per-path rules:

```haskell
-- | A Cloudflare CDN with default settings: no default-TTL override, static-asset
-- caching enabled, no per-path rules. Refine with the @with*@ combinators.
cloudflareCdn :: Cdn
cloudflareCdn = Cdn
  { provider = CloudflareCdn
  , defaultTtlSeconds = Nothing
  , cacheStaticAssets = True
  , cacheRules = []
  }

-- | A Google Cloud CDN with the same default settings as 'cloudflareCdn'.
gcpCloudCdn :: Cdn
gcpCloudCdn = cloudflareCdn { provider = GcpCloudCdn }
```

The combinators let an author refine a preset fluently with `&` (reverse application, from
`Data.Function`, re-exported through `lens`/the prelude). The two that cannot fail are total;
the one that takes an untrusted per-path TTL validates and returns `Either Text`:

```haskell
-- | Set a default edge TTL (in seconds) for everything not matched by a
-- per-path rule. Total: a caller-supplied negative value is still rejected on
-- the load-time round-trip by 'Nagare.Dsl.Load.toCdn'.
withDefaultTtl :: Int -> Cdn -> Cdn
withDefaultTtl n c = c { defaultTtlSeconds = Just n }

-- | Turn off the "cache fingerprinted static assets aggressively" behaviour.
withoutStaticAssetCache :: Cdn -> Cdn
withoutStaticAssetCache c = c { cacheStaticAssets = False }

-- | Append a validated per-path cache rule. Fails if the rule is invalid
-- (empty prefix, negative TTL).
withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn
withCacheRule prefix ttl c = do
  rule <- mkCdnCacheRule prefix ttl
  Right c { cacheRules = cacheRules c <> [rule] }

-- | Build and validate a whole list of per-path rules at once, for the common
-- record-literal case. Equivalent to folding 'withCacheRule'.
mkCacheRules :: [(Text, Maybe Int)] -> Either Text [CdnCacheRule]
mkCacheRules = traverse (uncurry mkCdnCacheRule)
```

The module's export list surfaces the three types (with their constructors so encoders and the
loader can pattern-match and build), the constructors `mkCdnCacheRule` and `mkCacheRules`, the
presets `cloudflareCdn` and `gcpCloudCdn`, and the combinators `withDefaultTtl`,
`withCacheRule`, and `withoutStaticAssetCache`. Add a module-internal `tshow :: Show a => a ->
Text` exactly as `Nagare.Dsl.Static.Types` does, and `import Data.Char (isSpace)` and
`import Data.Text qualified as Text`. Begin the module with `import Nagare.Dsl.Prelude` to pick
up `Generic`, `Text`, and the lens operators, mirroring the sibling type modules.

Register the module by adding `Nagare.Dsl.Cdn.Types` to the `exposed-modules` stanza of
`cli/nagare-dsl/nagare-dsl.cabal` (alphabetical position is between `Nagare.Dsl.Build` and
`Nagare.Dsl.Config`).

Add a test module `cli/nagare-dsl/test/CdnSpec.hs` exporting `cdnTests :: TestTree`, register
it in the test-suite `other-modules` of the `.cabal`, and call `cdnTests` from the `testGroup`
list in `cli/nagare-dsl/test/Spec.hs`. The unit tests assert: `mkCdnCacheRule "/assets/"
(Just 31536000)` is `Right`; `mkCdnCacheRule "" (Just 1)` is a `Left` containing `"empty"`;
`mkCdnCacheRule "   " (Just 1)` is a `Left` containing `"whitespace"`; `mkCdnCacheRule "/x"
(Just (-1))` is a `Left` containing `">= 0"`; `mkCdnCacheRule "/api/" Nothing` is `Right`
(never-cache is allowed); `cloudflareCdn` has `provider == CloudflareCdn`, `cacheStaticAssets
== True`, `defaultTtlSeconds == Nothing`, `cacheRules == []`; `gcpCloudCdn` differs only in
`provider == GcpCloudCdn`; `cloudflareCdn & withDefaultTtl 3600` has `defaultTtlSeconds == Just
3600`; `withoutStaticAssetCache cloudflareCdn` has `cacheStaticAssets == False`; and
`withCacheRule "/api/" Nothing cloudflareCdn` is `Right` with one rule whose `edgeTtlSeconds ==
Nothing`. Reuse the `assertRight`/`assertLeftContains`/`unsafe` helper style from `StaticSpec.hs`
(copy the small helpers into `CdnSpec.hs`; the existing specs each define their own, so this
matches the house pattern).

Acceptance: in `cli/nagare-dsl`, `cabal test` compiles the library with the new module and runs
the suite with the new `Nagare.Dsl.Cdn` test group passing. No existing test changes behaviour
because nothing else references the new module yet.


### Milestone 2 — JSON transport, loader, and the three records

Scope: attach `cdn :: !(Maybe Cdn)` to the three records, encode it as a nested optional object,
decode it back through a `toCdn` validator, update the fixtures to demonstrate it, and prove the
round-trip and the backward-compatibility guarantee with golden and negative tests. At the end,
a config author can attach a CDN to any of the three shapes and the value survives an
emit→decode cycle intact, while a config that attaches no CDN emits byte-identical JSON to
before.

Add the field to each record. In `StaticSite`
(`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs`) add `, cdn :: !(Maybe Cdn)` after `notFound`;
in `ServerSite` (`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`) add it after `volumes`; in
`Deployment` (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`) add it after `tasks`. Each module must
import the `Cdn` type — `import Nagare.Dsl.Cdn.Types (Cdn)`. Because the field is `Maybe`, the
neutral value is `Nothing`, so any in-repo construction site that builds one of these records
with a positional/record literal must be given `cdn = Nothing` (the compiler will point each one
out; the fixtures, the `*Spec.hs` expected values, and any preset builder in
`Nagare.Dsl.Presets` are the likely sites — there is no `webService`-style preset for sites, so
the static/server builders are the fixtures themselves).

Write a single shared `cdnJSON :: Cdn -> Value` encoder. Put it in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` near the other shared helpers (`volumeJSON`,
`scopeTokensJSON`), so all three site encoders call the same function:

```haskell
-- | The nested @"cdn"@ object emitted inside a static site, server site, or
-- deployment. Provider tokens are the wire contract EP-56/EP-57/EP-58 read:
-- @"Cloudflare"@ and @"GcpCloudCdn"@. A per-path rule's @edgeTtlSeconds: null@
-- encodes the "never cache this path" case.
cdnJSON :: Cdn -> Value
cdnJSON c =
  object
    [ "provider" .= providerToken (c ^. #provider)
    , "defaultTtlSeconds" .= (c ^. #defaultTtlSeconds)
    , "cacheStaticAssets" .= (c ^. #cacheStaticAssets)
    , "cacheRules" .= map ruleJSON (c ^. #cacheRules)
    ]
  where
    providerToken CloudflareCdn = "Cloudflare" :: Text
    providerToken GcpCloudCdn = "GcpCloudCdn"
    ruleJSON r =
      object
        [ "pathPrefix" .= (r ^. #pathPrefix)
        , "edgeTtlSeconds" .= (r ^. #edgeTtlSeconds)
        ]
```

Then, in each of `staticSiteJSON`, `serverSiteJSON`, and `deploymentJSON`, append the `"cdn"`
key *only when the field is `Just`*, so that a `Nothing` CDN produces no key and existing golden
output is unchanged. The clean way that matches `aeson`'s `object` (which takes a fixed list of
pairs) is to build the base list and concatenate an optional one-element list:

```haskell
staticSiteJSON :: StaticSite -> Value
staticSiteJSON site =
  object (baseFields <> cdnField)
  where
    baseFields =
      [ "kind" .= ("StaticSite" :: Text)
      , "name" .= siteNameText (site ^. #name)
      -- ... all the existing fields unchanged ...
      , "notFound" .= fmap filePathText (site ^. #notFound)
      ]
    cdnField = maybe [] (\c -> ["cdn" .= cdnJSON c]) (site ^. #cdn)
    -- ... existing where-clause helpers (buildJSON, redirectJSON, …) unchanged ...
```

Apply the same `baseFields <> cdnField` refactor to `serverSiteJSON` and `deploymentJSON`,
reading `site ^. #cdn` / `dep ^. #cdn` respectively. Import the `Cdn` types and constructors
into `Config.hs` with `import Nagare.Dsl.Cdn.Types`.

On the loader side, in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, add two intermediate mirror
records and their `FromJSON` instances:

```haskell
data JsonCdnCacheRule = JsonCdnCacheRule
  { jcrPathPrefix     :: !Text
  , jcrEdgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdnCacheRule where
  parseJSON = withObject "CdnCacheRule" $ \o ->
    JsonCdnCacheRule <$> o .: "pathPrefix" <*> o .:? "edgeTtlSeconds"

data JsonCdn = JsonCdn
  { jcProvider          :: !Text
  , jcDefaultTtlSeconds :: !(Maybe Int)
  , jcCacheStaticAssets :: !Bool
  , jcCacheRules        :: ![JsonCdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdn where
  parseJSON = withObject "Cdn" $ \o ->
    JsonCdn
      <$> o .: "provider"
      <*> o .:? "defaultTtlSeconds"
      <*> o .:? "cacheStaticAssets" .!= True
      <*> o .:? "cacheRules" .!= []
```

Note `edgeTtlSeconds` is read with `.:?` so a missing key is `Nothing`; but because the encoder
always writes the key (as `null` for the never-cache case), the round-trip preserves `Nothing`
faithfully either way. `cacheStaticAssets` defaults to `True` and `cacheRules` to `[]` so a
hand-written partial object is forgiving, matching how `JsonVolume`/`JsonHealthCheck` default
their optional fields.

Add the validator that re-runs the smart constructors and decodes the provider token, reporting
a precise `MarshalError` keyed by a dotted field path:

```haskell
toCdn :: JsonCdn -> Either LoadError Cdn
toCdn j = do
  prov <- case jcProvider j of
    "Cloudflare" -> Right CloudflareCdn
    "GcpCloudCdn" -> Right GcpCloudCdn
    other -> Left (MarshalError "cdn.provider" ("unknown cdn provider: " <> other))
  -- A negative default TTL is rejected here (the encoder/combinator cannot
  -- catch a hand-written value).
  case jcDefaultTtlSeconds j of
    Just n | n < 0 ->
      Left (MarshalError "cdn.defaultTtlSeconds" ("must be >= 0, got: " <> Text.pack (show n)))
    _ -> Right ()
  rules <- traverse toCdnCacheRule (jcCacheRules j)
  Right
    Cdn
      { provider = prov
      , defaultTtlSeconds = jcDefaultTtlSeconds j
      , cacheStaticAssets = jcCacheStaticAssets j
      , cacheRules = rules
      }
  where
    toCdnCacheRule r =
      mapLeft (MarshalError "cdn.cacheRules") $
        mkCdnCacheRule (jcrPathPrefix r) (jcrEdgeTtlSeconds r)
```

Wire it into the three decoders. Each `Json*Site`/`JsonDeployment` mirror record gains a field
`jXXCdn :: !(Maybe JsonCdn)` read with `<*> o .:? "cdn"` in its `FromJSON` instance (a missing
key decodes to `Nothing`). Each `toX` validator gains `cdn' <- traverse toCdn (jXXCdn j)` and
sets `cdn = cdn'` in the assembled record. Concretely: `JsonStaticSite` + `toStaticSite`,
`JsonServerSite` + `toServerSite`, and `JsonDeployment` + `toDeployment`. Import the `Cdn` types
and `mkCdnCacheRule` into `Load.hs` with `import Nagare.Dsl.Cdn.Types`. The IO entry points
`loadStaticSite`, `loadServerSite`, `loadSite`, and `loadDeployment` need no change — they call
the decoders, and the `Cdn` now rides inside the record they already return.

Update the fixtures. Edit `cli/nagare-dsl/test/fixtures/static-site/nagare/Config.hs` to attach
a Cloudflare CDN so the headline path is demonstrated, and add `cdn = Just …` to its record
literal. A worked excerpt of that fixture's CDN section:

```haskell
import Nagare.Dsl.Cdn.Types

-- inside the do-block that assembles the StaticSite:
cdn' <-
  mapLeft show $
    withCacheRule "/api/" Nothing
      =<< withCacheRule "/assets/" (Just 31536000) (cloudflareCdn & withDefaultTtl 3600)
-- ...
Right StaticSite { {- existing fields -}, cdn = Just cdn' }
```

That excerpt reads: start from the Cloudflare preset, set a one-hour default edge TTL, cache
`/assets/` for a year, and never cache `/api/`. Similarly give the server-site fixture
(`cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs`) a `gcpCloudCdn`-based CDN, and add
`cdn = Just …` there. Leave at least one fixture (or add a second static fixture) with `cdn =
Nothing` so the no-CDN backward-compat path is covered by a real `Config.hs`. For the
`Deployment` fixture (`cli/nagare-dsl/test/fixtures/nagare/Config.hs`), keep `cdn = Nothing`
unless a CDN-bearing deployment is needed for the round-trip test; the round-trip test below can
exercise the deployment CDN path in-process instead.

The exact JSON the static fixture above emits (the `"cdn"` block) is:

```json
"cdn": {
  "provider": "Cloudflare",
  "defaultTtlSeconds": 3600,
  "cacheStaticAssets": true,
  "cacheRules": [
    { "pathPrefix": "/assets/", "edgeTtlSeconds": 31536000 },
    { "pathPrefix": "/api/", "edgeTtlSeconds": null }
  ]
}
```

Add tests. In `CdnSpec.hs` (or extend it), add a round-trip test that builds a `StaticSite` with
a Cloudflare CDN, encodes it with `staticSiteJSON`/`encode` (or the in-process helper
`emitStaticSite`'s pure counterpart — note `encodeDeployment` is exposed for exactly this kind
of in-process round-trip; for sites, encode `staticSiteJSON site` via `Data.Aeson.encode`),
feeds the bytes to `decodeStaticSite`, and asserts the result equals the original site. Add the
analogous server-site (GCP CDN) and deployment round-trips. Add negative tests over hand-built
JSON strings (the `StaticSpec.hs` `staticJSON`/`StaticParts` template approach is the model):
an unknown provider token (`"provider":"Fastly"`) yields `MarshalError "cdn.provider"`; a
negative `defaultTtlSeconds` yields `MarshalError "cdn.defaultTtlSeconds"`; a cache rule with a
negative `edgeTtlSeconds` yields `MarshalError "cdn.cacheRules"`; and a rule with
`"edgeTtlSeconds": null` round-trips to a rule whose `edgeTtlSeconds == Nothing`. Add the
backward-compat assertion: a static-site JSON string with no `"cdn"` key decodes to a site whose
`cdn == Nothing`, and a `StaticSite` with `cdn = Nothing` encodes to JSON that contains no
`"cdn"` substring (assert with a simple `Text.isInfixOf "cdn"` check over the encoded bytes).

The existing goldens under `cli/nagare-dsl/test/golden/` (for the static, server, and deployment
fixtures) must still pass. The static and server fixtures now carry a CDN, so if a golden
*JSON* artifact existed for them it would change — but the goldens in that directory are
rendered *Nginx config / Knative YAML*, not the transport JSON, and EP-55 renders no
infrastructure from the CDN field, so those YAML/conf goldens are unaffected by adding the field
(the field is inert until EP-56/EP-57/EP-58 render it). Confirm this by running the suite; if any
golden does change, that is a signal the field leaked into a renderer it should not have, and is
a bug to fix, not a golden to bless.

Acceptance: in `cli/nagare-dsl`, `cabal test` passes. The new round-trip tests demonstrate that
a CDN survives emit→decode; the negative tests demonstrate precise rejection; the backward-compat
tests demonstrate `cdn = Nothing` is invisible in the output.


## Concrete Steps

Run everything from the package directory. First confirm a clean baseline so you can attribute
any later failure to your change:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build all
cabal test
```

Expect the existing suite to pass, ending with a line like:

```text
All N tests passed (0.10s)
```

Milestone 1: create `src/Nagare/Dsl/Cdn/Types.hs` (use the `mkdir -p` first so the directory
exists), add the module to `exposed-modules` in `nagare-dsl.cabal`, create `test/CdnSpec.hs`,
add `CdnSpec` to the test-suite `other-modules`, and call `cdnTests` from `test/Spec.hs`. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
mkdir -p src/Nagare/Dsl/Cdn
cabal build all
cabal test
```

Expect the suite to now include the new group, e.g.:

```text
Nagare.Dsl.Cdn
  mkCdnCacheRule
    accepts /assets/ with a year TTL:        OK
    rejects empty prefix:                    OK
    rejects all-whitespace prefix:           OK
    rejects negative TTL:                    OK
    allows null TTL (never cache):           OK
  presets
    cloudflareCdn defaults:                  OK
    gcpCloudCdn differs only in provider:    OK
  combinators
    withDefaultTtl sets the TTL:             OK
    withoutStaticAssetCache clears the flag: OK
    withCacheRule appends a validated rule:  OK
```

Milestone 2: edit the three record modules, `Config.hs`, `Load.hs`, the fixtures, and the tests
as described in the Plan of Work, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build all
cabal test
```

To *see* the emitted JSON for the CDN-bearing static fixture (a real observable outcome, not just
a passing test), run the fixture `Config.hs` the same way the loader does and pretty-print the
`"cdn"` block:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
runghc -XGHC2024 -itest/fixtures/static-site/nagare test/fixtures/static-site/nagare/Config.hs \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["cdn"], indent=2))'
```

Expect exactly:

```text
{
  "provider": "Cloudflare",
  "defaultTtlSeconds": 3600,
  "cacheStaticAssets": true,
  "cacheRules": [
    {
      "pathPrefix": "/assets/",
      "edgeTtlSeconds": 31536000
    },
    {
      "pathPrefix": "/api/",
      "edgeTtlSeconds": null
    }
  ]
}
```

To prove the backward-compatibility guarantee from the shell, run the deployment fixture (which
keeps `cdn = Nothing`) and confirm there is no `cdn` key:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
runghc -XGHC2024 -itest/fixtures/nagare test/fixtures/nagare/Config.hs \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("has cdn key:", "cdn" in d)'
```

Expect:

```text
has cdn key: False
```


## Validation and Acceptance

The change is internal (a library type and its transport), so validation is by tests that fail
before the change and pass after, plus the two shell transcripts above that show real emitted
JSON.

Milestone 1 is accepted when `cabal test` runs the `Nagare.Dsl.Cdn` group green and the four
validation behaviours are demonstrated by name: an empty `pathPrefix` is rejected with a message
containing `"empty"`; an all-whitespace prefix with `"whitespace"`; a negative TTL with
`">= 0"`; and a `Nothing` TTL is accepted (never-cache is legal). The presets and combinators
are demonstrated by equality assertions: `cloudflareCdn` and `gcpCloudCdn` carry the expected
defaults and differ only in `provider`; `withDefaultTtl 3600` sets `defaultTtlSeconds` to `Just
3600`; `withoutStaticAssetCache` clears the flag; `withCacheRule` appends one validated rule.

Milestone 2 is accepted when `cabal test` passes with the new round-trip and negative tests, and
when the two shell transcripts above reproduce exactly. Specifically, the round-trip behaviour to
observe is: a `StaticSite` carrying `cloudflareCdn & withDefaultTtl 3600` with an `/assets/` rule
(1-year TTL) and an `/api/` never-cache rule, encoded to JSON and decoded back with
`decodeStaticSite`, is `Right` and equal to the original — including the `Nothing` TTL surviving
as `null` and back. The precise-rejection behaviour to observe is: feeding `decodeStaticSite` a
JSON body whose `cdn.provider` is `"Fastly"` returns `Left (MarshalError "cdn.provider" …)`; a
negative `cdn.defaultTtlSeconds` returns `Left (MarshalError "cdn.defaultTtlSeconds" …)`; a
negative `edgeTtlSeconds` in a rule returns `Left (MarshalError "cdn.cacheRules" …)`. The
backward-compatibility behaviour to observe is: a static-site JSON with no `"cdn"` key decodes to
`cdn == Nothing`, and encoding a `cdn = Nothing` site yields bytes with no `"cdn"` substring —
and the deployment fixture transcript prints `has cdn key: False`.

All existing tests (the static, server, deployment, database, and task goldens and the load
specs) must remain green, proving the addition is non-breaking.


## Idempotence and Recovery

Every step here is additive and repeatable. Creating the module, editing the `.cabal`, and
adding the test module can be re-run safely; `cabal build`/`cabal test` are idempotent. If a
build fails because an existing record-construction site now lacks the new `cdn` field, the GHC
error names the exact file and line — add `cdn = Nothing` there and rebuild. There is no
migration, no destructive operation, no cloud or filesystem state to roll back: a `git checkout
-- cli/nagare-dsl` discards the entire change cleanly if you need to start over. Because
`Nothing` is the neutral value and the encoder omits the key for it, even a partially completed
Milestone 2 (say, the field added to records but encoders not yet updated) leaves existing
behaviour intact for all no-CDN configs.


## Interfaces and Dependencies

This plan uses only libraries already in `cli/nagare-dsl/nagare-dsl.cabal`: `aeson` for the JSON
`Value`/`object`/`.=`/`.:`/`.:?`/`.!=` machinery, `text` for `Text` and `Text.null`/`isInfixOf`,
`containers` only transitively, and the project's `Nagare.Dsl.Prelude` for `Generic`, `Text`,
and the `lens` operators (`^.`, `&`). No new dependency is added.

At the end of Milestone 1, the module `Nagare.Dsl.Cdn.Types` exists and exports exactly these
types and functions:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn
data CdnCacheRule = CdnCacheRule { pathPrefix :: !Text, edgeTtlSeconds :: !(Maybe Int) }
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }

mkCdnCacheRule          :: Text -> Maybe Int -> Either Text CdnCacheRule
mkCacheRules            :: [(Text, Maybe Int)] -> Either Text [CdnCacheRule]
cloudflareCdn           :: Cdn
gcpCloudCdn             :: Cdn
withDefaultTtl          :: Int -> Cdn -> Cdn
withCacheRule           :: Text -> Maybe Int -> Cdn -> Either Text Cdn
withoutStaticAssetCache :: Cdn -> Cdn
```

At the end of Milestone 2, the three records each carry `cdn :: !(Maybe Cdn)`; the shared
encoder `cdnJSON :: Cdn -> Value` exists in `Nagare.Dsl.Config`; and the loader
`Nagare.Dsl.Load` has `JsonCdn`/`JsonCdnCacheRule` mirrors and `toCdn :: JsonCdn -> Either
LoadError Cdn`, with `decodeStaticSite`, `decodeServerSite`, and `decodeDeployment` all reading
and re-validating the optional `"cdn"` object. The public IO entry points
`loadStaticSite :: FilePath -> IO (Either LoadError StaticSite)`,
`loadServerSite :: FilePath -> IO (Either LoadError ServerSite)`,
`loadSite :: FilePath -> IO (Either LoadError SiteConfig)`, and
`loadDeployment :: FilePath -> IO (Either LoadError Deployment)` keep their exact signatures.

This plan hard-depends on EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`),
whose spike fixes the contract shape and the origin-TLS decisions transcribed above. It
soft-depends on EP-13 (`docs/plans/13-typed-static-site-model-and-renderer.md`) and EP-18
(`docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`), whose `StaticSite` and
`ServerSite` records it edits. It is consumed by EP-56
(`docs/plans/56-cloudflare-cdn-provider-renderer.md` — to be created), EP-57
(`docs/plans/57-google-cloud-cdn-provider-renderer.md` — to be created), and EP-58
(`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` — to be created),
each of which reads the exact `Cdn` shape and wire tokens defined here. The master plan
(`docs/masterplans/11-cdn-integration-for-nagare.md`) frames EP-55 as "a shared typed contract
every later plan consumes"; that framing is the reason this plan fixes the shape verbatim and
treats the provider tokens, the `null`-means-never-cache encoding, and the omit-when-`Nothing`
rule as a stable interface rather than an implementation detail.
