---
id: 57
slug: cloudflare-cdn-provisioning-via-api-in-nagarectl
title: "Cloudflare CDN provisioning via API in nagarectl"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Cloudflare CDN provisioning via API in nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a single-node personal Platform-as-a-Service. "Single-node" means the whole
platform runs on exactly one Google Cloud virtual machine named `nagare-01` in the GCP
project `tan-nb-exp`, region `us-west1`. A developer describes an app or a website in a
typed Haskell configuration file and runs one command (`nagarectl ...`) to deploy it.

This plan delivers the **Cloudflare provider capability**: a new Haskell module inside the
`nagarectl` command-line tool that talks to Cloudflare's public REST API to put a Cloudflare
edge (a globally distributed cache and reverse proxy) in front of the one VM. "Cloudflare"
here is a third-party CDN service: when you point a hostname's DNS at Cloudflare with the
"proxied" flag turned on, visitors hit a nearby Cloudflare data center, which serves cached
content directly and forwards cache-misses to the VM (the "origin"). A "CDN" (Content
Delivery Network) is exactly that globally distributed cache-in-front-of-an-origin.

After this plan, the `nagarectl` library contains a single module,
`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`, that can: create-or-update a proxied DNS
record so a hostname resolves to Cloudflare and forwards to the VM's public IP; apply a set
of cache rules (a default edge time-to-live plus per-path overrides, where one path can be
marked "never cache"); set the "origin-TLS mode" (how Cloudflare's edge connects back to the
VM — plaintext or encrypted); and purge the edge cache after a deploy so visitors stop
seeing stale content. The module reads its credential (a scoped Cloudflare API token) from
an environment variable and never logs it.

What you can observe when this plan is done. First, a unit-test transcript: running
`cabal test` in `cli/nagarectl` exercises pure functions that build the exact JSON request
bodies Cloudflare expects, and the tests assert those bodies byte-for-byte — so you can read
the test output and see, for example, a `Cdn` configuration with a one-year `/assets/` rule
and a never-cache `/api/` rule turn into a concrete Cloudflare ruleset. Second, a deferred
live demonstration (gated on a real Cloudflare zone, a real token, and the powered-on VM):
a recorded `curl` transcript showing a proxied DNS record created and a second request to the
same URL returning the HTTP response header `CF-Cache-Status: HIT`, which is Cloudflare's
proof that the response came from the edge cache rather than the origin.

This module is the hard contract that a sibling plan,
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` (EP-58), calls at
deploy time. EP-58 does not re-implement any Cloudflare logic; it imports the five functions
this plan exports. This plan introduces the outbound-HTTP capability into the CLI for the
first time (the CLI has no HTTP-client dependency today), and confines every Cloudflare call
to this one module.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1 — Add `http-client` and `http-client-tls` to the `nagarectl.cabal` library
  `build-depends`, and expose the new module `Nagare.Cdn.Cloudflare`.
- [ ] Milestone 1 — Create `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` with the credential,
  origin-TLS, and result types plus the pure request-builders
  (`buildUpsertRecordPayload`, `buildCacheRulesPayload`, `buildPurgePayload`,
  `sslModeToken`, `zoneNameFromHostname`, the Cloudflare-envelope parsers).
- [ ] Milestone 1 — Add a `Nagare.Cdn` test group to `cli/nagarectl/test/Spec.hs` asserting the
  exact JSON payloads (default-TTL + `/assets/` + never-cache `/api/` + static-asset caching),
  the SSL-mode mapping, purge-all vs purge-paths, and the success/error envelope parsing.
- [ ] Milestone 1 — `cd cli/nagarectl && cabal test` passes; record the transcript in Concrete
  Steps.
- [ ] Milestone 2 — Implement the five IO functions (`loadCloudflareCreds`,
  `upsertProxiedRecord`, `applyCacheRules`, `setOriginTlsMode`, `purgeHostname`) on top of the
  pure builders, with the find-or-create idempotency and the `Either Text` totality.
- [ ] Milestone 2 — Write the manual live-validation runbook (token scopes, env vars, the
  `curl` transcript showing `CF-Cache-Status: HIT`) and mark the live leg deferred/manual.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `http-client` + `http-client-tls` as the HTTP library, added only to the
  `nagarectl.cabal` *library* stanza, and route every Cloudflare call through
  `Nagare.Cdn.Cloudflare`.
  Rationale: The CLI today has no outbound-HTTP dependency at all (verified: no
  `http-client`/`wreq`/`req`/`servant-client` in `nagarectl.cabal`; the `nagared` executable
  uses `wai`/`warp`/`http-types` only for an *inbound* webhook server). `http-client` is the
  lowest-dependency, most widely-used Haskell HTTP client and matches the repository's
  minimalism better than the heavier `req` or `wreq`. Confining it to this one module keeps the
  outbound-HTTP blast radius to a single file, mirroring how `Nagare.Ops.Probe` confines all
  external-tool shell-outs.
  Date: 2026-06-10

- Decision: Read the Cloudflare credential from the environment variable `CF_API_TOKEN` (a
  *scoped API token*, never the account-global API key), with an optional `CF_ZONE_ID`, and
  never log the token.
  Rationale: A scoped token can be limited to exactly the permissions this module needs
  (DNS edit, cache rules, cache purge, zone settings) on exactly one zone, so a leak is far less
  damaging than the global key (which can do anything to every zone on the account). Reading from
  the environment matches the secret-handling convention already used elsewhere in the CLI and
  keeps the token out of config files and process arguments. When `CF_ZONE_ID` is absent the
  module discovers the zone from the hostname's registrable domain via the Cloudflare API, so the
  operator only has to set it when auto-discovery is ambiguous.
  Date: 2026-06-10

- Decision: Factor all URL/JSON construction into *pure* functions and unit-test those,
  mirroring `Nagare.Ops.Domains`.
  Rationale: `Nagare.Ops.Domains` separates pure JSON extractors/formatters from the thin
  `kubectl` IO so the inventory is testable without a cluster. The same split lets us assert the
  exact Cloudflare request bodies in `cabal test` with no network, no token, and no live zone —
  which is the only way to get meaningful coverage while the live leg is environment-gated.
  Date: 2026-06-10

- Decision: Apply cache behaviour through the Cloudflare **Rulesets** API — specifically the
  `http_request_cache_settings` phase entrypoint — replacing the managed ruleset wholesale on
  each apply.
  Rationale: The Rulesets engine is Cloudflare's current, account-API-token-accessible mechanism
  for per-path edge-TTL control (the older "Page Rules" product is legacy and capped at a small
  count). Writing the whole phase entrypoint in one PUT makes `applyCacheRules` deterministic and
  idempotent: the result is a function of the `Cdn` value, with no accumulation of stale rules
  across re-runs.
  Date: 2026-06-10

- Decision: `OriginTlsMode` defaults to `Flexible` until the origin serves the Let's Encrypt
  wildcard certificate on port 443, per the sibling spike
  `docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md` (EP-54).
  Rationale: `Flexible` means Cloudflare terminates client TLS at the edge and talks to the
  origin over plain HTTP, which works against today's HTTP-first Kourier origin (TLS is deferred
  in `docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md` until a real
  `baseDomain` is delegated). Once the origin presents the wildcard on 443, the operator can move
  to `Full`/`FullStrict`. EP-57 only honours whichever mode it is handed;
  `docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` (EP-58) passes the
  EP-54 default at deploy time.
  Date: 2026-06-10

- Decision: `upsertProxiedRecord` is find-or-create-then-update; `applyCacheRules` replaces the
  managed ruleset deterministically.
  Rationale: Re-running a deploy must not create duplicate DNS records or accumulate duplicate
  cache rules. Listing the record by name, then PATCHing if found or POSTing if not, makes the
  DNS write idempotent; PUTting the whole cache phase entrypoint makes the cache write
  idempotent. Both are safe to run any number of times.
  Date: 2026-06-10

- Decision: Every exported function returns `Either Text` and never throws to the caller for an
  *expected* failure (auth rejected, zone not found, Cloudflare `success:false`).
  Rationale: EP-58 composes these calls in a deploy path and needs to turn failures into a clean
  user-facing message and a non-zero exit, not a Haskell exception stack. Parsing Cloudflare's
  `{ "success": false, "errors": [...] }` envelope into a `Left Text` keeps the surface total and
  greppable, matching the tolerant style of `Nagare.Ops.Probe.captureTool`.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan touches one Haskell package, `cli/nagarectl/`, which is the Nagare deploy
command-line tool (CLI). The package is built with GHC 9.12.3 and `cabal`. Its build
description is `cli/nagarectl/nagarectl.cabal`. The package has three components: a `library`
(everything under `cli/nagarectl/src/Nagare/...`), an executable `nagarectl` (the CLI entry
point, `cli/nagarectl/app/Main.hs`), an executable `nagared` (a small inbound webhook server),
and a test suite `nagarectl-test` (`cli/nagarectl/test/Spec.hs`). The library's current
`build-depends` are `aeson`, `base`, `bytestring`, `containers`, `cradle`, `crypton`,
`directory`, `filepath`, `generic-lens ^>=2.2`, `lens ^>=5.3`, `memory`, `nagare-dsl`,
`temporary`, `text`, `time`, `vector`, and `yaml`. There is **no** HTTP-client library among
them — verified by reading `nagarectl.cabal`; the only HTTP-ish deps anywhere are `wai`,
`warp`, and `http-types` on the *separate* `nagared` executable, which runs an *inbound*
server and makes no outbound calls. So this plan adds the first outbound-HTTP dependency.

Two existing modules establish the patterns this plan copies. The first is
`cli/nagarectl/src/Nagare/Ops/Domains.hs`: it keeps *pure* functions (JSON extractors like
`extractDomainMappings`, the `dnsExpectationFor` computation, and the `formatDomainList`
table renderer) separate from a thin IO layer (`queryDomainRows`) that shells out to
`kubectl` and feeds the bytes to the pure functions. This separation is exactly the shape
this plan uses: pure request-builders that are unit-tested, plus thin IO that performs the
HTTP. The second is `cli/nagarectl/src/Nagare/Ops/Probe.hs`, which defines `captureTool ::
String -> [String] -> IO (Maybe ByteString)` — a tolerant external-call wrapper that catches
an `IOException` (a missing binary) and returns `Nothing` instead of throwing. This plan
mirrors that "never throw for an expected failure; return a total value" convention, except
the total value here is `Either Text a` so callers get an actionable message.

Shell-outs in this codebase use the `cradle` library: `import Cradle`, then `run_ $ cmd
"tool" & addArgs [...]` (run, fail on non-zero) or `run $ cmd ... & silenceStderr` returning
`(ExitCode, StdoutRaw out)`. This plan does **not** use `cradle` for the Cloudflare calls —
it uses `http-client` directly — but the `cradle` idiom is named here so a reader knows the
difference between "shell out to a local tool" (everywhere else) and "make an HTTP request to
Cloudflare" (this module only).

The typed CDN model this plan translates into Cloudflare API payloads is owned by the sibling
plan `docs/plans/55-typed-cdn-model-and-provider-renderer.md` (EP-55), which defines, in the
`nagare-dsl` library, the module `Nagare.Dsl.Cdn.Types`. Because EP-55 may not be merged when
this plan is implemented, the exact contract is restated here so this plan is self-contained.
The relevant types are:

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn
  deriving stock (Generic, Eq, Show)

-- A per-path edge cache rule. Requests whose path begins with @pathPrefix@ get
-- @edgeTtlSeconds@ as their edge time-to-live (in seconds); @Nothing@ means
-- "never cache this path" (bypass the edge cache).
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- The CDN configuration attached to a site or app. @defaultTtlSeconds@ is the
-- edge TTL for cacheable responses with no matching rule; @cacheStaticAssets@
-- turns on a long-cache rule for fingerprinted assets (js/css/fonts/images);
-- @cacheRules@ are per-path overrides applied in order.
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)
```

This plan imports those types from `Nagare.Dsl.Cdn.Types` (the EP-55 module). If EP-55 is not
yet merged when Milestone 1 begins, the implementer adds a tiny local stand-in module with the
identical definitions so this plan can compile and test independently, and removes it once
EP-55 lands. That fallback is itself a Decision-Log entry to be added at implementation time.

Cloudflare terms used below, defined in plain language. A **zone** is Cloudflare's unit for a
domain (e.g. `example.com`); every DNS record and cache rule lives under a zone, addressed by a
`zone id`. A **proxied DNS record** is an A record whose "proxied" flag is on, so the hostname
resolves to Cloudflare's edge instead of straight to the origin IP; Cloudflare then forwards
to the origin IP you stored in the record. The **origin** is the VM (`nagare-01`). The
**origin-TLS mode** (Cloudflare calls it the zone "SSL mode") controls how the edge talks back
to the origin: `Flexible` = edge↔origin over plain HTTP, `Full` = over HTTPS but the origin
cert is not verified, `Full (strict)` = over HTTPS with the origin cert verified.
`CF-Cache-Status` is an HTTP response header Cloudflare adds; the value `HIT` means the response
was served from the edge cache (the proof of a working CDN), `MISS`/`DYNAMIC`/`BYPASS` mean it
went to the origin.

The Cloudflare REST API used is **v4**, base URL `https://api.cloudflare.com/client/v4`. Every
request carries the header `Authorization: Bearer <CF_API_TOKEN>` and `Content-Type:
application/json`. Every response is a JSON envelope of the shape
`{ "success": true|false, "errors": [...], "messages": [...], "result": <payload> }`.


## Plan of Work

The work splits into two milestones. Milestone 1 is entirely offline-testable: the module, its
pure request-builders, and the unit tests that pin the exact JSON. Milestone 2 is the live IO
wiring plus a documented, environment-gated manual validation, because there is no Cloudflare
account or token wired into continuous integration and the VM is powered off to save cost —
exactly the gating posture the sibling plans `docs/plans/43-...` and `docs/plans/49-...`
used for their live legs.


### Milestone 1 — Module, pure request-builders, and unit tests (offline)

Scope: add the HTTP dependency to the cabal file, create
`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` with all of its types and *pure* helpers, and add a
`Nagare.Cdn` test group to `cli/nagarectl/test/Spec.hs`. At the end of this milestone the
package compiles, `cabal test` passes, and the tests prove that a `Cdn` value becomes the exact
Cloudflare request bodies. No network is touched.

First, edit `cli/nagarectl/nagarectl.cabal`. Add `Nagare.Cdn.Cloudflare` to the library's
`exposed-modules` list (alphabetically it sits just before `Nagare.Database.*` if you keep the
`Nagare.Cdn.*` group ahead of `Nagare.Database.*`, or simply place it after `Nagare.App.*`), and
add `http-client` and `http-client-tls` to the library `build-depends`. The diff is:

```diff
   exposed-modules:
     Nagare.App
     Nagare.App.Deployments
     Nagare.Build
+    Nagare.Cdn.Cloudflare
     Nagare.Database.Backup
```

```diff
   build-depends:
     aeson,
     base >=4.17 && <5,
     bytestring,
     containers,
     cradle,
     crypton,
     directory,
     filepath,
     generic-lens ^>=2.2,
+    http-client,
+    http-client-tls,
     lens ^>=5.3,
     memory,
     nagare-dsl,
     temporary,
     text,
     time,
     vector,
     yaml,
```

Second, create `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`. The module header declares the
public surface — the five IO functions EP-58 consumes plus the pure builders the tests pin:

```haskell
module Nagare.Cdn.Cloudflare
  ( -- * Credentials and origin-TLS model
    CloudflareCreds (..)
  , OriginTlsMode (..)
  , loadCloudflareCreds

    -- * Provisioning (IO; total via Either)
  , upsertProxiedRecord
  , applyCacheRules
  , setOriginTlsMode
  , purgeHostname

    -- * Pure request-builders (unit-tested; no network)
  , buildUpsertRecordPayload
  , buildCacheRulesPayload
  , buildPurgePayload
  , sslModeToken
  , zoneNameFromHostname
  , parseEnvelopeUnit
  , parseDnsRecordId
  , parseZoneId
  ) where
```

The types come next. `CloudflareCreds` and `OriginTlsMode` are the exact shapes EP-58 depends
on (Integration Point 3 in the MasterPlan):

```haskell
-- | Cloudflare API credentials. @cfApiToken@ is a scoped API token read from
-- @CF_API_TOKEN@; never logged. @cfZoneId@ is the optional @CF_ZONE_ID@; when
-- 'Nothing', the zone is discovered from the hostname via 'zoneNameFromHostname'
-- and a @GET /zones?name=<root>@ call.
data CloudflareCreds = CloudflareCreds
  { cfApiToken :: !Text
  , cfZoneId   :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | How Cloudflare's edge connects back to the origin VM. 'Flexible' = edge to
-- origin over plain HTTP (works against today's HTTP-first Kourier origin);
-- 'Full' = HTTPS without verifying the origin cert; 'FullStrict' = HTTPS with
-- the origin cert verified. Default is 'Flexible' per EP-54 until the origin
-- serves the Let's Encrypt wildcard on port 443.
data OriginTlsMode = Flexible | Full | FullStrict
  deriving stock (Generic, Eq, Show)
```

Now the pure helpers. `zoneNameFromHostname` reduces a fully-qualified hostname to its
registrable domain (the last two labels — `blog.example.com` becomes `example.com`), which is
what `GET /zones?name=<root>` expects when `CF_ZONE_ID` is not set:

```haskell
-- | The registrable domain (last two dot-labels) of a hostname. This is a
-- deliberately simple heuristic: it is correct for ordinary @sub.example.com@
-- inputs and the operator can always set @CF_ZONE_ID@ to bypass discovery for
-- multi-label public suffixes (e.g. @example.co.uk@).
zoneNameFromHostname :: Text -> Text
zoneNameFromHostname host =
  let labels = T.splitOn "." (T.toLower (T.dropWhileEnd (== '.') host))
   in T.intercalate "." (lastN 2 labels)
  where
    lastN n xs = drop (length xs - n) xs
```

`sslModeToken` maps `OriginTlsMode` to the literal string Cloudflare's
`PATCH /zones/{zone}/settings/ssl` expects in its `value` field:

```haskell
-- | The Cloudflare @ssl@ setting token for an 'OriginTlsMode'.
sslModeToken :: OriginTlsMode -> Text
sslModeToken Flexible   = "flexible"
sslModeToken Full       = "full"
sslModeToken FullStrict = "strict"
```

`buildUpsertRecordPayload` produces the JSON body for creating/updating a proxied A record. The
Cloudflare DNS-records endpoint (`POST`/`PATCH /zones/{zone}/dns_records`) takes
`{ "type": "A", "name": <hostname>, "content": <origin IP>, "proxied": true, "ttl": 1 }`
(`ttl: 1` means "automatic" and is required when `proxied` is true):

```haskell
-- | The request body to create or update a proxied A record pointing @hostname@
-- at @originIp@. @proxied: true@ is what routes the hostname through Cloudflare's
-- edge; @ttl: 1@ ("automatic") is mandatory for proxied records.
buildUpsertRecordPayload :: Text -> Text -> Value
buildUpsertRecordPayload hostname originIp =
  object
    [ "type"    .= ("A" :: Text)
    , "name"    .= hostname
    , "content" .= originIp
    , "proxied" .= True
    , "ttl"     .= (1 :: Int)
    ]
```

`buildCacheRulesPayload` is the heart of the module: it turns a `Cdn` value into the body for
`PUT /zones/{zone}/rulesets/phases/http_request_cache_settings/entrypoint`. Each entry in the
`rules` array has an `expression` (a Cloudflare filter expression matching by hostname and path)
and an `action_parameters` block. A cacheable rule sets `cache: true` and an `edge_ttl` of mode
`override_origin` with the given `default` seconds; a never-cache rule (`edgeTtlSeconds =
Nothing`) sets `cache: false` ("bypass cache"). The default-TTL and static-asset behaviours
become their own rules. Rules are emitted in this order: explicit `cacheRules` first (so a
specific `/api/` override wins), then the static-asset rule if enabled, then the catch-all
default-TTL rule last:

```haskell
-- | Translate a typed 'Cdn' into the Cloudflare cache-settings ruleset body.
-- Rule precedence is by array order: explicit path rules first, then the
-- static-asset long-cache rule (when @cacheStaticAssets@), then a catch-all
-- default-TTL rule last. @edgeTtlSeconds = Nothing@ becomes a "bypass cache"
-- rule (@cache: false@); a present TTL becomes @cache: true@ with an
-- @override_origin@ edge TTL.
buildCacheRulesPayload :: Text -> Cdn -> Value
buildCacheRulesPayload hostname cdn =
  object
    [ "rules" .=
        ( map (pathRule hostname) (cacheRules cdn)
            ++ staticAssetRules hostname (cacheStaticAssets cdn)
            ++ defaultRules hostname (defaultTtlSeconds cdn)
        )
    ]

-- | A per-path rule. @Just ttl@ caches for @ttl@ seconds; @Nothing@ bypasses.
pathRule :: Text -> CdnCacheRule -> Value
pathRule hostname (CdnCacheRule prefix mttl) =
  cacheRule
    ( hostExpr hostname
        <> " and starts_with(http.request.uri.path, "
        <> quoteExpr prefix
        <> ")"
    )
    mttl

-- | The fingerprinted-static-asset long-cache rule (one year) when enabled.
staticAssetRules :: Text -> Bool -> [Value]
staticAssetRules _ False = []
staticAssetRules hostname True =
  [ cacheRule
      ( hostExpr hostname
          <> " and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\""
          <> " \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})"
      )
      (Just 31536000)
  ]

-- | The catch-all default-TTL rule, last so specific rules win. Omitted when no
-- default TTL is configured (Cloudflare's own default caching then applies).
defaultRules :: Text -> Maybe Int -> [Value]
defaultRules _ Nothing = []
defaultRules hostname (Just ttl) = [cacheRule (hostExpr hostname) (Just ttl)]

-- | One ruleset rule from an expression and an optional edge TTL.
cacheRule :: Text -> Maybe Int -> Value
cacheRule expr mttl =
  object
    [ "expression" .= expr
    , "action"     .= ("set_cache_settings" :: Text)
    , "action_parameters" .= actionParams mttl
    ]

actionParams :: Maybe Int -> Value
actionParams Nothing = object [ "cache" .= False ]
actionParams (Just ttl) =
  object
    [ "cache"    .= True
    , "edge_ttl" .= object
        [ "mode"    .= ("override_origin" :: Text)
        , "default" .= ttl
        ]
    ]

hostExpr :: Text -> Text
hostExpr hostname = "(http.host eq " <> quoteExpr hostname <> ")"

-- | A double-quoted literal for a Cloudflare filter expression.
quoteExpr :: Text -> Text
quoteExpr t = "\"" <> t <> "\""
```

`buildPurgePayload` produces the body for `POST /zones/{zone}/purge_cache`. An empty path list
purges everything (`{ "purge_everything": true }`); a non-empty list purges specific URLs
(`{ "files": ["https://host/path", ...] }`), which is why the function needs the hostname:

```haskell
-- | The purge request body. @[]@ purges the whole zone
-- (@{ "purge_everything": true }@); a non-empty path list purges those exact
-- URLs under @hostname@ over HTTPS.
buildPurgePayload :: Text -> [Text] -> Value
buildPurgePayload _ [] = object [ "purge_everything" .= True ]
buildPurgePayload hostname paths =
  object [ "files" .= map (\p -> "https://" <> hostname <> p) paths ]
```

Finally the envelope parsers. `parseEnvelopeUnit` turns a raw response body into `Right ()` on
`success: true` or `Left <joined error messages>` on `success: false`; `parseDnsRecordId` and
`parseZoneId` pull the `result.id` (and `result[0].id` for the zone list) that the IO functions
need to thread between calls:

```haskell
-- | Decode a Cloudflare envelope into @Right ()@ on @success:true@ or
-- @Left <messages>@ on @success:false@ (or undecodable bytes).
parseEnvelopeUnit :: ByteString -> Either Text ()
parseEnvelopeUnit bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode Cloudflare response: " <> T.pack e)
    Right v
      | envelopeOk v -> Right ()
      | otherwise    -> Left (envelopeErrors v)

envelopeOk :: Value -> Bool
envelopeOk v = lookupBool ["success"] v == Just True

-- | Join the @errors[].message@ strings (with codes) into one human line.
envelopeErrors :: Value -> Text
envelopeErrors v =
  case lookupPath ["errors"] v of
    Just (Array errs)
      | not (V.null errs) ->
          T.intercalate "; "
            [ maybe "unknown error" id (textAt ["message"] e) | e <- V.toList errs ]
    _ -> "Cloudflare reported failure with no error detail"

-- | The created/updated record id from @result.id@.
parseDnsRecordId :: ByteString -> Maybe Text
parseDnsRecordId bs = decodeStrict bs >>= textAt ["result", "id"]

-- | The first matching zone id from a @GET /zones?name=...@ list response
-- (@result[0].id@).
parseZoneId :: ByteString -> Maybe Text
parseZoneId bs = do
  v <- decodeStrict bs
  Array results <- lookupPath ["result"] v
  first <- results V.!? 0
  textAt ["id"] first
```

The `lookupPath`, `textAt`, and `lookupBool` helpers are the same three-line JSON walkers used
in `Nagare.Ops.Domains` and `Nagare.Ops.Probe`; copy them verbatim into this module so it stays
self-contained (those modules keep local copies for the same reason). `lookupBool` is the
boolean analogue of `textAt`:

```haskell
lookupBool :: [Text] -> Value -> Maybe Bool
lookupBool path v = case lookupPath path v of
  Just (Bool b) -> Just b
  _ -> Nothing
```

Third, add the tests. In `cli/nagarectl/test/Spec.hs`, import the new module and add a
`testGroup "Nagare.Cdn"` to the existing `tasty` tree (the file already uses
`tasty`/`tasty-hunit` with `@?=` assertions and imports sibling modules the same way). The
tests assert the *exact* JSON. The headline test takes a Cloudflare `Cdn` with a 3600-second
default TTL, an `/assets/` rule at one year, an `/api/` never-cache rule, and static-asset
caching on, and checks that `buildCacheRulesPayload "blog.example.com" cdn` equals the worked
example shown under Validation. Additional tests assert: `buildUpsertRecordPayload` for a
proxied A record; `sslModeToken` for all three modes; `buildPurgePayload` for the purge-all and
purge-paths cases; and `parseEnvelopeUnit` returning `Right ()` on a `success:true` fixture and
`Left` carrying the message on a `success:false` fixture. Comparing `Value`s (not encoded
bytes) makes the assertions insensitive to key order.

Acceptance for Milestone 1: `cd cli/nagarectl && cabal test` builds the library with the new
dependency and runs the `Nagare.Cdn` group green.


### Milestone 2 — Live IO wiring and the deferred manual validation

Scope: implement the five IO functions on top of the Milestone-1 builders, then write the
manual runbook that an operator with a real Cloudflare zone and token follows to see a proxied
record created and `CF-Cache-Status: HIT`. The live leg is **deferred/manual** — no Cloudflare
account or token is wired into CI and the VM is off — so this milestone delivers the code plus
the exact steps, and records the live transcript when the operator runs it.

The IO functions share one private helper, `cfRequest`, that performs a single Cloudflare call
with `http-client`/`http-client-tls` and returns the raw response body so a pure parser can
interpret it. It sets the bearer token and JSON content-type headers, uses the TLS-enabled
manager, and — crucially — never logs the token. Its skeleton:

```haskell
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)

cfBaseUrl :: String
cfBaseUrl = "https://api.cloudflare.com/client/v4"

-- | Perform one Cloudflare call. @method@ is "GET"/"POST"/"PATCH"/"PUT";
-- @path@ is appended to 'cfBaseUrl'; @mbody@ is an optional JSON body. Returns
-- the raw response bytes (any HTTP status) so the caller's pure parser decides
-- success from the envelope. Catches connection-level 'HttpException' into a
-- 'Left' so the function is total.
cfRequest :: Text -> Text -> Text -> Maybe Value -> IO (Either Text ByteString)
cfRequest token method path mbody =
  ( do
      manager <- newTlsManager
      initReq <- parseRequest (T.unpack (T.pack method' <> " " <> T.pack cfBaseUrl <> path))
      let req = initReq
            { requestHeaders =
                [ ("Authorization", TE.encodeUtf8 ("Bearer " <> token))
                , ("Content-Type", "application/json")
                ]
            , requestBody = maybe mempty (RequestBodyLBS . encode) mbody
            }
      resp <- httpLbs req manager
      pure (Right (LBS.toStrict (responseBody resp)))
  ) `catch` \(e :: HttpException) ->
      pure (Left ("Cloudflare request failed: " <> T.pack (show e)))
  where
    method' = T.unpack method
```

`loadCloudflareCreds` reads `CF_API_TOKEN` (required → `Left` when unset or empty) and
`CF_ZONE_ID` (optional) from the environment via `System.Environment.lookupEnv`, and never
echoes the token:

```haskell
loadCloudflareCreds :: IO (Either Text CloudflareCreds)
loadCloudflareCreds = do
  mtok <- lookupEnv "CF_API_TOKEN"
  mzone <- lookupEnv "CF_ZONE_ID"
  pure $ case mtok of
    Just t | not (null t) ->
      Right (CloudflareCreds (T.pack t) (T.pack <$> mzone))
    _ -> Left "CF_API_TOKEN is not set; export a scoped Cloudflare API token"
```

Each provisioning function resolves the zone id first (use `cfZoneId` if present, otherwise
`GET /zones?name=<zoneNameFromHostname host>` and `parseZoneId`), then performs its call and
runs the matching pure parser:

- `upsertProxiedRecord creds host originIp`: resolve zone; `GET
  /zones/{zone}/dns_records?type=A&name=<host>`; if `parseDnsRecordId` finds an id, `PATCH
  /zones/{zone}/dns_records/<id>` with `buildUpsertRecordPayload host originIp`, else `POST
  /zones/{zone}/dns_records` with the same body. This is the find-or-create idempotency.
- `applyCacheRules creds host cdn`: resolve zone; `PUT
  /zones/{zone}/rulesets/phases/http_request_cache_settings/entrypoint` with
  `buildCacheRulesPayload host cdn`. The whole-entrypoint write makes re-runs deterministic.
- `setOriginTlsMode creds _host mode`: resolve zone; `PATCH /zones/{zone}/settings/ssl` with
  `object ["value" .= sslModeToken mode]`.
- `purgeHostname creds host paths`: resolve zone; `POST /zones/{zone}/purge_cache` with
  `buildPurgePayload host paths`.

Each returns `parseEnvelopeUnit` of the response body (or threads the parsed id, in
`upsertProxiedRecord`'s case), so the result is `Right ()` on success and a precise `Left Text`
on any auth/zone/`success:false` failure.

Acceptance for Milestone 2 is documented under Validation: the code compiles and `cabal test`
still passes (the pure builders are unchanged), and the manual runbook is in place. The live
`curl` transcript is recorded into Concrete Steps and Outcomes when an operator runs it.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a
working directory is given. The repo pins GCP to `tan-nb-exp`/`us-west1`; nothing in this plan
calls `gcloud`, so that policy is not exercised here, but no command in this plan may target any
other GCP project.

Build the library after the cabal and module edits:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build nagarectl
```

Expected (abbreviated) — the new module compiles and `http-client`/`http-client-tls` resolve:

```text
Resolving dependencies...
Building library for nagarectl-0.1.0.0...
[ x of y] Compiling Nagare.Cdn.Cloudflare
Linking ...
```

Run the unit tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test
```

Expected — the `Nagare.Cdn` group passes alongside the existing suite:

```text
Nagare.Cdn
  buildCacheRulesPayload: default + /assets/ + never-cache /api/ + static: OK
  buildUpsertRecordPayload: proxied A record:                              OK
  sslModeToken: flexible/full/strict:                                      OK
  buildPurgePayload: purge-all vs purge-paths:                             OK
  parseEnvelopeUnit: success:true -> Right ():                             OK
  parseEnvelopeUnit: success:false -> Left message:                        OK

All N tests passed
```

The live leg (Milestone 2) is deferred/manual. When an operator runs it, they record the
transcript here. The exact manual steps are in Validation and Acceptance below.


## Validation and Acceptance

Offline acceptance is the `cabal test` run above. The load-bearing assertion is the worked
example: `buildCacheRulesPayload "blog.example.com" cdn`, for the `Cdn`

```haskell
Cdn
  { provider          = CloudflareCdn
  , defaultTtlSeconds = Just 3600
  , cacheStaticAssets = True
  , cacheRules =
      [ CdnCacheRule "/assets/" (Just 31536000)
      , CdnCacheRule "/api/"    Nothing
      ]
  }
```

must equal exactly this JSON (the test compares decoded `Value`s, so key order is irrelevant):

```json
{
  "rules": [
    {
      "expression": "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/assets/\")",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": true,
        "edge_ttl": { "mode": "override_origin", "default": 31536000 }
      }
    },
    {
      "expression": "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/api/\")",
      "action": "set_cache_settings",
      "action_parameters": { "cache": false }
    },
    {
      "expression": "(http.host eq \"blog.example.com\") and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\" \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": true,
        "edge_ttl": { "mode": "override_origin", "default": 31536000 }
      }
    },
    {
      "expression": "(http.host eq \"blog.example.com\")",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": true,
        "edge_ttl": { "mode": "override_origin", "default": 3600 }
      }
    }
  ]
}
```

A reader can verify the precedence by eye: the `/api/` never-cache rule and the `/assets/`
one-year rule appear before the catch-all 3600-second default, so a request to `/api/x` bypasses
the cache, `/assets/x` caches for a year, and anything else caches for an hour.

The representative request/response for `upsertProxiedRecord` (what the IO layer sends and what
Cloudflare returns) is:

```json
{ "type": "A", "name": "blog.example.com", "content": "34.105.10.20", "proxied": true, "ttl": 1 }
```

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": { "id": "abc123", "type": "A", "name": "blog.example.com", "proxied": true }
}
```

and a failure envelope `parseEnvelopeUnit` turns into a `Left`:

```json
{ "success": false, "errors": [ { "code": 9109, "message": "Invalid access token" } ], "result": null }
```

becomes `Left "Invalid access token"`.

Live acceptance (deferred/manual). The operator needs a real Cloudflare zone they control (a
test domain, e.g. `nagare-test.example`) and a scoped API token. Create the token in the
Cloudflare dashboard with exactly these zone-scoped permissions, restricted to the one test
zone: **Zone › DNS › Edit** (for `upsertProxiedRecord`), **Zone › Cache Rules › Edit** and the
**cache-purge** capability (for `applyCacheRules` and `purgeHostname`), and **Zone › Zone
Settings › Edit** (for `setOriginTlsMode`). Do **not** use the account-global API key. Then:

```bash
export CF_API_TOKEN='<the scoped token>'
export CF_ZONE_ID='<the test zone id>'   # optional; omit to exercise discovery
```

Power on the VM and learn its public IP, then point a test hostname at it through Cloudflare and
confirm an edge cache hit. The proof is two `curl -I` calls to the same URL: the first is a
`MISS`, the second a `HIT`:

```bash
# After the deploy code (EP-58) calls upsertProxiedRecord/applyCacheRules,
# or by exercising the functions from a one-off ghci session:
curl -sI https://nagare-test.example/assets/app.css | grep -i cf-cache-status
# first request:
#   cf-cache-status: MISS
curl -sI https://nagare-test.example/assets/app.css | grep -i cf-cache-status
# second request:
#   cf-cache-status: HIT
```

Seeing `cf-cache-status: HIT` on the second request is the observable proof that Cloudflare is
serving the asset from its edge cache rather than forwarding to the VM — the whole point of the
CDN. The operator pastes this transcript into Outcomes & Retrospective when the live leg is run.

This live leg is gated on a real Cloudflare account/token and the powered-on VM, neither wired
into CI, so it is recorded as deferred/manual — the same posture the sibling plans
`docs/plans/43-...` and `docs/plans/49-...` used for their environment-dependent legs. The code
and the exact steps are delivered now; the transcript is filled in when the box is on.


## Idempotence and Recovery

Every step in this plan is safe to repeat. The cabal/module edits are ordinary source changes;
re-running `cabal build`/`cabal test` is idempotent. The Cloudflare operations are designed to
be re-run without drift: `upsertProxiedRecord` lists the record by name first and PATCHes the
existing one rather than creating a duplicate, so deploying twice leaves exactly one record;
`applyCacheRules` PUTs the entire `http_request_cache_settings` phase entrypoint, so the live
rules are always a function of the current `Cdn` value with no stale-rule accumulation;
`setOriginTlsMode` PATCHes a single zone setting to a fixed value; and `purgeHostname` is a
read-through cache invalidation that is harmless to repeat (at worst it costs a few extra origin
fetches as the cache refills).

Recovery from a bad apply is straightforward because the operations are declarative: re-running
with a corrected `Cdn` overwrites the cache ruleset, and `purgeHostname creds host []` empties
the edge cache so visitors immediately stop seeing stale content. To fully detach a hostname
from Cloudflare, the operator flips the DNS record's proxied flag off (handled by EP-58's
`disable` command, out of scope here). If a token lacks a needed scope, the affected function
returns a precise `Left` (e.g. `Left "Invalid access token"` or a permission error) rather than
throwing, so a deploy fails cleanly and the operator can widen the token and retry.

A note on the origin-TLS / DNS-authority interaction the operator must set up once, recorded by
EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`). Today the origin
certificate is issued by cert-manager using a Cloud DNS DNS-01 challenge (it proves domain
control by writing a `_acme-challenge` TXT record into the Cloud DNS zone created by EP-2). When
Cloudflare becomes the authoritative DNS for the zone, that challenge can no longer be satisfied
from Cloud DNS unless one of two things is done: either move cert-manager's DNS-01 solver to a
Cloudflare API token (so it writes the challenge record into Cloudflare), or keep cert-manager
on Cloud DNS and CNAME-delegate `_acme-challenge.<host>` from Cloudflare back to Cloud DNS. EP-57
does not implement that setup — it only honours whichever `OriginTlsMode` it is handed
(defaulting to `Flexible`, which needs no origin cert at all) — but the operator must perform one
of those two delegations before moving to `Full`/`FullStrict`. This is documented for the
operator so the deferred live `Full`-mode validation does not surprise them.


## Interfaces and Dependencies

This plan adds two libraries to the `nagarectl` *library* component in
`cli/nagarectl/nagarectl.cabal`: `http-client` (the HTTP request/response engine) and
`http-client-tls` (its TLS-enabled connection manager, needed because Cloudflare's API is
HTTPS-only). They are chosen over `req`/`wreq` for being the lowest-dependency option and the
de-facto base of the Haskell HTTP ecosystem, matching this repo's minimalism. They are added
**only** to the library stanza; the `nagarectl`/`nagared` executables and the test suite are
untouched, so no other module gains an outbound-HTTP dependency. The module reuses `aeson` (JSON),
`text`, `bytestring`, `vector` (already library deps) and `System.Environment` from `base`.

The new module is `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`, added to the library
`exposed-modules`. It imports the typed CDN model from `Nagare.Dsl.Cdn.Types` (owned by EP-55,
`docs/plans/55-typed-cdn-model-and-provider-renderer.md`); if that module is not yet merged when
this plan starts, a local stand-in with identical `Cdn`/`CdnProvider`/`CdnCacheRule` definitions
is used and removed once EP-55 lands.

The contract that must exist at the end of Milestone 2 — the exact surface
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md` (EP-58) consumes, which
is Integration Point 3 of MasterPlan 11 — is:

```haskell
data CloudflareCreds = CloudflareCreds { cfApiToken :: !Text, cfZoneId :: !(Maybe Text) }
data OriginTlsMode = Flexible | Full | FullStrict
  deriving (Generic, Eq, Show)

loadCloudflareCreds :: IO (Either Text CloudflareCreds)
upsertProxiedRecord :: CloudflareCreds -> Text -> Text -> IO (Either Text ())
applyCacheRules     :: CloudflareCreds -> Text -> Cdn -> IO (Either Text ())
setOriginTlsMode    :: CloudflareCreds -> Text -> OriginTlsMode -> IO (Either Text ())
purgeHostname       :: CloudflareCreds -> Text -> [Text] -> IO (Either Text ())
```

At the end of Milestone 1 the pure builders must also exist and be exported (for tests, and for
any future caller that wants to preview a payload without sending it):
`buildUpsertRecordPayload :: Text -> Text -> Value`, `buildCacheRulesPayload :: Text -> Cdn ->
Value`, `buildPurgePayload :: Text -> [Text] -> Value`, `sslModeToken :: OriginTlsMode -> Text`,
`zoneNameFromHostname :: Text -> Text`, `parseEnvelopeUnit :: ByteString -> Either Text ()`,
`parseDnsRecordId :: ByteString -> Maybe Text`, and `parseZoneId :: ByteString -> Maybe Text`.

The services this plan depends on are the Cloudflare REST API v4 (base
`https://api.cloudflare.com/client/v4`) and the GCP VM `nagare-01` as the proxy origin. The
credential is the `CF_API_TOKEN` environment variable (a scoped token, never the global key,
never logged), with optional `CF_ZONE_ID`. No part of this module calls `kubectl`, `gcloud`, or
`pulumi`; it is purely an HTTP client plus pure builders, parallel to EP-56's Google Cloud CDN
Pulumi infrastructure (`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`) and
consumed by EP-58.
