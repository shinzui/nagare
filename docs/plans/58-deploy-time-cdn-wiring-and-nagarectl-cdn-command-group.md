---
id: 58
slug: deploy-time-cdn-wiring-and-nagarectl-cdn-command-group
title: "Deploy-time CDN wiring and nagarectl cdn command group"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Deploy-time CDN wiring and nagarectl cdn command group

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A "CDN" (Content Delivery Network) is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to the single Nagare VM in `us-west1`, a
visitor is served a cached copy from a nearby edge location. This ExecPlan is the point where
the typed CDN model that earlier plans defined actually does something a user can see. Today a
developer can write `cdn = Just (...)` in their `nagare/Config.hs`, but nothing reads it. After
this plan, when a config sets `cdn = Just ...`, running the same commands the developer already
uses — `nagarectl site deploy` for a static site or a TanStack Start server site, and
`nagarectl deploy` for a generic container app — will, after the site is live, provision and
configure the chosen CDN in front of it. The developer then gains a new command group,
`nagarectl cdn`, to inspect (`list`, `status`), refresh (`purge`), and tear down (`disable`) the
CDN edge.

Concretely, after this change a developer who adds a Cloudflare CDN to a static blog and runs
`nagarectl site deploy` sees, after the normal deploy output, lines reporting that the
hostname's DNS record was pointed at the Cloudflare edge (proxied), the origin-TLS mode was set,
and the per-path cache rules were applied — and the printed URL is now served through the edge.
A developer who instead chooses Google Cloud CDN and deploys a TanStack Start app sees that a
more-specific Cloud DNS A record was written for the exact hostname pointing at the load
balancer's global anycast IP (which overrides the `*.<baseDomain>` wildcard that points at the
VM), and that per-path cache behaviour was applied to the backend service / URL map. Running
`nagarectl cdn status blog.example.com` then reports the provider, whether DNS points at the
edge or the VM, the cache configuration, and edge/cert readiness; `nagarectl cdn purge` clears
the edge cache; `nagarectl cdn disable` reverts DNS so the hostname falls back to the VM.

The user-visible promise verified by this plan, in environments where the cloud legs cannot run,
is the `--dry-run` transcript: `nagarectl site deploy --dry-run` on a CDN-enabled example prints
the exact DNS, infrastructure, and API changes the CDN step *would* make, without making them;
and a config with no `cdn` field produces deploy output that is byte-for-byte identical to today.

This plan is the convergence point (Wave 3) of MasterPlan 11, "CDN Integration for Nagare"
(`docs/masterplans/11-cdn-integration-for-nagare.md`). It hard-depends on three sibling plans
that must be implemented first: EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`)
defines the typed `Cdn` model and adds the `cdn :: Maybe Cdn` field to the three runtime configs;
EP-56 (`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`) builds the Google
load-balancer infrastructure and exposes the `cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap` stack
outputs; EP-57 (`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`) builds the
Cloudflare API module. This plan is consumed and documented by EP-59
(`docs/plans/59-cdn-docs-and-end-to-end-examples.md`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Provisioning seam: create `cli/nagarectl/src/Nagare/Cdn/Provision.hs` with `CdnTarget`, `CdnResult`, `GcpStackRefs`, `CdnPlan`/`CdnAction`, the pure planner `planCdn`, the gcloud-arg builders (`gcloudDnsUpsertArgs`/`gcloudBackendCacheArgs`, both pinning `--project=tan-nb-exp`), the dispatching `provisionCdn`, and `renderCdnPlan` (dry-run text). Registered in `nagarectl.cabal`.
- [x] Milestone 1 — Wire the CDN step into the static deploy path. *(Wired in the CLI handler `deployStatic` after a successful `deployStaticProduction`, not inside the reusable effect — see Decision Log; keeps the reusable module and `nagared` free of CDN/Pulumi coupling.)*
- [x] Milestone 1 — Wire it into the server deploy path (`deployServer`).
- [x] Milestone 1 — Wire it into the generic app deploy path (`runDeploy`), printing the dry-run plan under `--dry-run` and provisioning live after `waitForReady`/`recordDeployment`. A `cdn = Nothing` deploy is a no-op (`cdnDeployStep _ Nothing _ _ _ = pure ()`), so non-CDN output is byte-for-byte unchanged.
- [x] Milestone 1 — Unit tests for the pure parts (Cloudflare-vs-Google dispatch, the two gcloud-arg goldens, the two `renderCdnPlan` goldens) in `cli/nagarectl/test/Spec.hs`; `cabal test` green.
- [x] Milestone 2 — Create `cli/nagarectl/src/Nagare/Cdn/Status.hs` (the `CdnRow`/`CdnDnsTarget` types, `formatCdnList`/`formatCdnStatus`, and `queryCdnRows` which degrades gracefully to `[]`); registered in `nagarectl.cabal`.
- [x] Milestone 2 — Add the `cdn` command group to `app/Main.hs`: the `CdnCmd CdnCommand` constructor, the four opts records/parsers, the `command "cdn" cdnCmd` entry, and handlers `runCdn`/`runCdnList`/`runCdnStatus`/`runCdnPurge`/`runCdnDisable`.
- [x] Milestone 2 — Unit tests for the `cdn` formatters; `cabal test` green (246 total, +9 EP-58); `nagarectl cdn --help` shows exactly `list`/`status`/`purge`/`disable`.
- [ ] Live legs (real Cloudflare token, real Google LB, real DNS) — DEFERRED/environment-gated (VM off, no token in CI); the exact manual validation steps are in Validation & Acceptance. The end-to-end `site deploy --dry-run` transcript against a loadable CDN example is captured in EP-59 (its example dirs are real loadable projects); the dry-run *text* is already proven exact by the `renderCdnPlan` goldens.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The reusable deploy effects `deployStaticProduction`/`deployServerProduction` are shared with the
  `nagared` webhook runner and take no Pulumi/stack inputs. Threading the CDN step *inside* them
  would couple that reusable module (and the webhook) to `Nagare.Ops.Pulumi`/`Nagare.Cdn`. The
  three CLI deploy handlers (`deployStatic`, `deployServer`, `runDeploy`) already own the
  `--dry-run` branches and the live-vs-dry split, so the CDN orchestration (`cdnDeployStep`) lives
  there instead — after a successful `deploy*Production` (i.e. after the origin is Ready). Same
  ordering guarantee the plan wanted, with a smaller blast radius. Recorded as a Decision-Log
  deviation.

- `nagarectl cdn --help` lists exactly `list`/`status`/`purge`/`disable` (verified). The
  end-to-end `site deploy --dry-run` smoke test against the EP-55 nagare-dsl *test fixture* fails
  only because `runghc` cannot resolve the `nagare-dsl` package from the repo-root cwd (the
  `.ghc.environment` package env is scoped to each package's build dir) — not a code fault. The
  dry-run output is proven exact by the two `renderCdnPlan` goldens (the renderer is literally what
  the dry-run prints); the live end-to-end transcript is captured in EP-59 against its real
  loadable example projects.


## Decision Log

Record every decision made while working on the plan.

- Decision: One provider-dispatching deploy seam — a single `provisionCdn :: Cdn -> CdnTarget -> IO (Either Text CdnResult)` in a new module `Nagare/Cdn/Provision.hs` — rather than per-provider deploy paths.
  Rationale: The deploy seam and the `cdn` command surface are provider-agnostic; they dispatch on the same `Cdn` value (`case provider cdn of CloudflareCdn -> ...; GcpCloudCdn -> ...`). This mirrors how MasterPlan 3's single kind-dispatching deploy engine (`Nagare.Static.Deploy`) carries both static and server sites, and avoids two copies of the seam drifting. MasterPlan 11 Integration Point 4 and its Decision Log fix this shape.
  Date: 2026-06-10

- Decision: CDN provisioning happens AFTER the site is live (after `applyManifests` + `waitForReady`), as the last step of a deploy, mirroring how the static/server deploy engines call `recordRelease`/`recordReleaseFor` last.
  Rationale: The CDN points an edge at a working origin. Provisioning the edge before the origin is Ready would publish a hostname that 502s. Putting the CDN step where `recordRelease` already sits keeps the deploy engine's shape intact and means a CDN failure is reported after a successful origin deploy (the origin is still up) rather than aborting it.
  Date: 2026-06-10

- Decision: For the Google provider, split a CDN hostname off the wildcard by writing a MORE-SPECIFIC Cloud DNS A record for the exact hostname pointing at `cdnGlobalIp`, leaving the `*.<baseDomain>` wildcard (which points at the VM) in place.
  Rationale: DNS resolution prefers the most specific matching record, so an A record for `blog.example.com` wins over `*.example.com` without deleting or editing the wildcard that every other app relies on. `nagarectl cdn disable` simply deletes that more-specific record and the hostname falls back to the wildcard/VM. This is MasterPlan 11 Integration Point 6.
  Date: 2026-06-10

- Decision: Disambiguate the command-ADT constructor from the `Cdn` type. The top-level command constructor in `app/Main.hs` is named `CdnCmd` (carrying a `CdnCommand` sub-ADT), because `Nagare.Dsl.Cdn.Types` already exports a type named `Cdn`; a constructor named `Cdn` would clash on import.
  Rationale: `app/Main.hs` imports both the runtime configs (which transitively expose `Cdn`) and defines the command tree. Naming the constructor `CdnCmd` keeps both in scope without a qualified import or a hiding clause, matching the existing `Domains DomainsCommand` / `Db DbCommand` naming where the constructor and its payload type differ.
  Date: 2026-06-10

- Decision: Every deploy path and every `cdn` mutating command supports `--dry-run` that prints the exact DNS/infra/API changes WITHOUT making them, reusing the repo's established dry-run deploy pattern.
  Rationale: The live legs are environment-gated (the VM is off; no Cloudflare token in CI). The dry-run transcript is the observable outcome that proves the wiring is correct without a cloud round-trip, and it is the artifact EP-59 will screenshot. The repo already prints rendered artifacts under `--dry-run` in `runDeploy`/`deployStatic`/`deployServer`; the CDN plan slots into the same branch.
  Date: 2026-06-10

- Decision: A no-CDN deploy (`cdn = Nothing`) is byte-for-byte unchanged, and a test asserts it.
  Rationale: MasterPlan 11's core promise is that `Maybe Cdn` keeps every existing config and deploy path unchanged. The wiring is a guarded `case cdn of Nothing -> pure (); Just c -> ...` placed after the existing last step, so the `Nothing` branch adds no output and no effect.
  Date: 2026-06-10

- Decision (implementation deviation): the CDN provisioning step is orchestrated in the three CLI
  deploy handlers (`deployStatic`/`deployServer`/`runDeploy` in `app/Main.hs`) via a shared
  `cdnDeployStep`, rather than inside the reusable `deployStaticProduction`/`deployServerProduction`
  effects.
  Rationale: those reusable effects are shared with the `nagared` webhook and take no Pulumi/stack
  inputs; wiring CDN inside them would couple the reusable module and the webhook to
  `Nagare.Ops.Pulumi`/`Nagare.Cdn`. The CLI handlers already own the `--dry-run` branch, and
  `cdnDeployStep` runs only after a *successful* `deploy*Production` (origin Ready), preserving the
  plan's "after the site is live, never fatal to the origin" guarantee with a smaller blast radius.
  The reusable-effect signatures are unchanged. Trade-off: a CDN-enabled deploy driven directly
  through the `nagared` webhook does not auto-provision the CDN (the CLI path does); since CDN-via-
  webhook is a secondary, environment-gated path, this is acceptable and recorded here.
  Date: 2026-06-10

- Decision (implementation): `runCdnDisable` and `runCdnStatus`/`runCdnList` are wired with their
  parsers, `--dry-run`, and Cloudflare-purge live path now; full provider auto-detection and live
  Cloud-DNS/Cloudflare *discovery* (which hostname is CDN-fronted by which provider, and whether DNS
  currently resolves to the edge or the VM) are environment-gated and degrade gracefully —
  `queryCdnRows` returns `[]` (so `cdn list` prints the empty sentinel) until the VM is on and a
  token is available.
  Rationale: discovery needs live Cloud DNS / Cloudflare reads against a powered-on origin, which is
  deferred. The offline-testable surface (the formatters, the parsers, the dry-run plan, the gcloud
  argv) is complete and green; the live discovery is the deferred tail, matching EP-43/EP-49.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-10).** The convergence point is wired. `Nagare.Cdn.Provision` is the single
provider-dispatching seam: `planCdn` turns a typed `Cdn` + resolved `CdnTarget` (+ Google stack
refs) into an ordered, secret-free `CdnPlan`; `renderCdnPlan` prints it for `--dry-run`;
`provisionCdn` executes it (Cloudflare via EP-57's module, Google via `gcloud` through the existing
`captureTool`, every argv pinned to `--project=tan-nb-exp`). `cdnDeployStep` calls it from the
static, server, and app deploy handlers after the origin is Ready, and a `cdn = Nothing` deploy is
a no-op. The `nagarectl cdn` command group (`list`/`status`/`purge`/`disable`) is in the parser with
the `CdnCmd`/`CdnCommand` split (avoiding the `Cdn` type clash) and `Nagare.Cdn.Status`'s pure
formatters. `cabal test`: 246 total (+9 EP-58), all green; `nagarectl cdn --help` lists the four
subcommands; the two `renderCdnPlan` goldens reproduce the exact dry-run blocks the plan specifies
(including the Google `gcloud` lines).

**Gaps / deferred.** The live legs (real Cloudflare token, real Google LB, real Cloud DNS) and the
live `cdn list`/`status` *discovery* (`queryCdnRows` currently returns `[]`) are environment-gated
and deferred, matching EP-43/EP-49. The end-to-end `site deploy --dry-run` transcript against a
loadable CDN example is captured in EP-59 (its example dirs are real loadable projects; the dry-run
*text* is already proven by the renderer goldens). One deviation from the plan's letter — CDN
orchestration in the CLI handlers rather than inside the reusable `deploy*Production` effects — is
recorded in the Decision Log with its rationale and trade-off.


## Context and Orientation

This plan touches the Haskell CLI `nagarectl`, which lives under `cli/nagarectl/`. It is built
with GHC 9.12.3 and `cabal`; its package description is `cli/nagarectl/nagarectl.cabal`. The CLI
has a `library` stanza (`hs-source-dirs: src`, modules under `src/Nagare/...`), an `executable
nagarectl` stanza (`hs-source-dirs: app`, the single file `app/Main.hs`), and a `test-suite
nagarectl-test` stanza (`hs-source-dirs: test`, the single file `test/Spec.hs`). New library
modules must be added to the `exposed-modules` list of the `library` stanza, in alphabetical
order with their siblings; otherwise the executable and tests cannot import them.

The command-line surface. `app/Main.hs` builds the whole CLI with the `Options.Applicative`
library (a Haskell library for declarative command-line parsers). The master parser is a
`subparser` that maps a literal verb to a sub-`ParserInfo`:

```haskell
commandParser =
  subparser
    ( command "deploy" deployCmd <> command "site" siteCmd <> command "env" envCmd
        <> command "secret" secretCmd <> command "app" appCmd <> command "deployments" deploymentsCmd
        <> command "storage" storageCmd <> command "db" dbCmd <> command "task" taskCmd
        <> command "server" serverCmd <> command "doctor" doctorCmd <> command "domains" domainsCmd
        <> command "cleanup" cleanupCmd )
```

There is a single top-level sum type `data Command = Deploy DeployOpts | SiteDeploy SiteDeployOpts
| ... | Domains DomainsCommand | Cleanup CleanupOpts`. Each subcommand has an "opts" record (its
parsed flags) and a `Parser` that builds it; the `main` function calls `execParser opts` and
dispatches on the `Command` constructor to a handler (`runDeploy`, `runSiteDeploy`,
`runDomainsList`, and so on). You will ADD a `command "cdn" cdnCmd` to `commandParser`, a new
constructor `CdnCmd CdnCommand` to `Command`, a `CdnCommand` sub-ADT with one constructor per
`cdn` subcommand, the opts records and parsers, and the handler functions, then a new branch in
the `main` `case`.

A naming hazard to respect. The module `Nagare.Dsl.Cdn.Types` (introduced by EP-55) exports a
TYPE named `Cdn`. `app/Main.hs` transitively sees that type through the runtime configs. If you
named the new command constructor `Cdn`, it would clash with the type's data constructor space on
import. Therefore the command constructor is `CdnCmd` and its payload sub-ADT is `CdnCommand`,
exactly paralleling the existing `Domains DomainsCommand` and `Db DbCommand` pairs where the
constructor name and the payload type name differ.

The deploy engine. Three deploy paths exist, all of which apply Kubernetes/Knative manifests with
`Nagare.Deploy.applyManifests :: [ByteString] -> IO ()` (writes each manifest to a temp file and
runs `kubectl apply -f`) and then wait for the workload with `Nagare.Deploy.waitForReady :: Text
-> Text -> IO ()` (runs `kubectl wait --for=condition=Ready ksvc/<name> -n <ns> --timeout=300s`):

- The static-site path is `Nagare.Static.Deploy.deployStaticProduction :: DeployInputs -> Maybe
  Text -> IO (Either Text Text)` in `cli/nagarectl/src/Nagare/Static/Deploy.hs`. Its body
  prepares the build output, `configureDockerAuth`, builds and pushes the Nginx image,
  `applyManifests (service m : domainMappings m)`, `waitForReady (serviceName m) ns`, then
  `recordRelease`. The CDN step goes immediately after `waitForReady`, before/around
  `recordRelease`. `DeployInputs` carries `site :: StaticSite`, `imageTag`, `baseDomain`,
  `projectDir`, `skipBuild`.
- The server-site (TanStack Start / Node) path is `Nagare.Server.Deploy.deployServerProduction ::
  ServerDeployInputs -> Maybe Text -> IO (Either Text Text)` in
  `cli/nagarectl/src/Nagare/Server/Deploy.hs`. It mirrors the static path: build, push, apply,
  `waitForReady`, then `recordReleaseFor`.
- The generic app path is `runDeploy :: DeployOpts -> IO ()` directly in `app/Main.hs`. It loads a
  `Deployment` with `Load.loadDeployment`, renders PVCs / Service / DomainMappings / Task
  CronJobs, then (in the non-dry-run branch) `applyPVCs`, `applyManifests (svcBytes : dmBytes)`,
  applies task CronJobs, `waitForReady name ns`, `reportPVCs`, `recordDeploymentFor`, and prints
  the URL. The CDN step goes after `waitForReady name ns`. In the dry-run branch (which prints the
  rendered manifests, the build mode, and the URL), the CDN plan text is printed too.

Reading the typed config. `Nagare.Dsl.Load.loadSite :: FilePath -> IO (Either LoadError SiteConfig)`
returns `SiteConfig = SiteStatic StaticSite | SiteServer ServerSite`; `Load.loadDeployment ::
FilePath -> IO (Either LoadError Deployment)` returns a `Deployment`. After EP-55, each of
`StaticSite`, `ServerSite`, and `Deployment` carries a field `cdn :: Maybe Cdn`, read with the
`#cdn` lens (the codebase uses `generic-lens` `OverloadedLabels`, so `site ^. #cdn` works). The
loader signatures DO NOT change — the `Cdn` rides inside the already-returned record.

Stack outputs. `Nagare.Ops.Pulumi.stackOutput :: FilePath -> Text -> IO (Maybe Text)` runs
`pulumi -C <dir> stack output <name>` and returns the trimmed value, or `Nothing` if Pulumi is
missing / the call fails (graceful degradation, never a crash). The existing outputs are
`publicIp` (the VM's regional public IP — the CDN's origin), `baseDomain`, and (per EP-56)
`cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap`, plus the Cloud DNS managed-zone name (read via
the same `stackOutput "infra/pulumi" "dnsZoneName"`). The deploy paths already call
`stackOutput "infra/pulumi" "publicIp"` (see `runDomainsList` in `app/Main.hs`).

The Cloudflare module (from EP-57). `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` exposes
`loadCloudflareCreds :: IO (Either Text CloudflareCreds)`, `upsertProxiedRecord :: CloudflareCreds
-> Text -> Text -> IO (Either Text ())` (hostname → origin IP, proxied), `applyCacheRules ::
CloudflareCreds -> Text -> Cdn -> IO (Either Text ())`, `setOriginTlsMode :: CloudflareCreds ->
Text -> OriginTlsMode -> IO (Either Text ())`, `purgeHostname :: CloudflareCreds -> Text -> [Text]
-> IO (Either Text ())` (paths `[]` = purge all), and the type `OriginTlsMode (Flexible | Full |
FullStrict)`. EP-54's recorded decision selects the deploy-time default origin-TLS mode; this plan
passes that mode (start with `Flexible`, which works against the HTTP-first origin immediately).

Shelling out. The repo runs external tools with the `cradle` library (`import Cradle; run_ $ cmd
"gcloud" & addArgs [...]`). A tolerant capture variant, `Nagare.Ops.Probe.captureTool :: String ->
[String] -> IO (Maybe ByteString)`, runs a tool and returns `Nothing` on a non-zero exit or a
missing binary; `Nagare.Ops.Pulumi.stackOutput` and `Nagare.Ops.Domains.kubeGetJson` are built on
it. GCP isolation policy (repo-root `CLAUDE.md`) requires that EVERY `gcloud` invocation passes
`--project=tan-nb-exp` explicitly; the region is `us-west1` and the default zone `us-west1-a`.

The `domains list` analogue. `nagarectl domains list` is implemented by `Nagare.Ops.Domains`
(`cli/nagarectl/src/Nagare/Ops/Domains.hs`): pure JSON extractors (`extractDomainMappings`,
`extractCertReadiness`), a computed DNS expectation (`dnsExpectationFor`, `DnsExpectation =
UnderWildcard Text | OutsideWildcard`), a certificate grader (`certStateFor`, `CertState =
CertReady | CertPending | CertDisabled`), the thin cluster query `queryDomainRows :: Text -> Text
-> Text -> IO [DomainRow]`, `listNamespaces :: IO [Text]`, and the pure formatter
`formatDomainList :: [DomainRow] -> Text`. The `cdn status`/`cdn list` commands reuse this
discovery (which hostnames exist, are their DomainMappings/certs Ready) and add the CDN provider's
DNS/edge readiness on top. The tests for these pure formatters live in `cli/nagarectl/test/Spec.hs`
(see the `formatDomainList` and `formatCleanupReport` golden tests around lines 484 and 566) and
are the template for the new CDN formatter tests.

The typed CDN model EP-55 defines (repeated here so this plan is self-contained):

```haskell
data CdnProvider = CloudflareCdn | GcpCloudCdn
  deriving stock (Generic, Eq, Show)

-- A per-path edge cache rule. Requests whose path begins with @pathPrefix@ get
-- @edgeTtlSeconds@ as their edge TTL; @Nothing@ means "never cache this path".
data CdnCacheRule = CdnCacheRule
  { pathPrefix     :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- @defaultTtlSeconds@ is the edge TTL for cacheable responses with no matching
-- rule; @cacheStaticAssets@ turns on a long-cache rule for fingerprinted assets;
-- @cacheRules@ are per-path overrides applied in order.
data Cdn = Cdn
  { provider          :: !CdnProvider
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules        :: ![CdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)
```

If the sibling plans EP-55/56/57 are not yet implemented when you start, their target files
(`cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs`, the `cdn` field on the three configs, the
`cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap` Pulumi outputs, and
`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`) will not exist and this plan cannot compile.
Verify they exist first (the Concrete Steps section gives the check); this plan hard-depends on
all three.


## Plan of Work

The work divides into two milestones plus an environment-gated live-validation tail. Milestone 1
builds the provisioning seam and wires it into all three deploy paths with a dry-run; Milestone 2
ships the `nagarectl cdn` command group. Both are independently verifiable with `cabal test` and
`--help`/`--dry-run` transcripts; neither needs the VM powered on.


### Milestone 1 — The `provisionCdn` seam, dispatch, dry-run, and deploy wiring

Scope: a new library module `cli/nagarectl/src/Nagare/Cdn/Provision.hs` that turns a typed `Cdn`
plus a resolved target into a plan, can render that plan as dry-run text, and can execute it by
dispatching on provider; and the three small edits that call it from the static, server, and app
deploy paths after readiness. At the end of this milestone, `nagarectl site deploy --dry-run` on a
CDN-enabled example prints the planned CDN changes, a no-CDN deploy is unchanged, and the pure
parts (target resolution, gcloud arg construction, dispatch decision, plan rendering) are covered
by unit tests that pass under `cabal test`.

Define the module's data types. `CdnTarget` is everything the seam needs that is independent of
the provider, resolved by the caller from the loaded config and the Pulumi outputs:

```haskell
data CdnTarget = CdnTarget
  { cdnHostnames :: ![Text]   -- the site's custom domains (the hostnames to front)
  , cdnOriginIp  :: !Text     -- the origin VM IP (the @publicIp@ stack output)
  , cdnNamespace :: !Text     -- the Knative namespace
  , cdnService   :: !Text     -- the Knative Service name
  }
  deriving stock (Generic, Eq, Show)
```

`CdnResult` is what the caller prints on success — the edge URL / DNS target and a human summary:

```haskell
data CdnResult = CdnResult
  { cdnEdgeUrls :: ![Text]    -- the now-edge-served URLs, one per hostname
  , cdnSummary  :: !Text      -- one human line, e.g. "Cloudflare edge: 2 hostname(s) proxied"
  }
  deriving stock (Generic, Eq, Show)
```

Introduce a pure intermediate, `CdnPlan`, so the dry-run and the live run derive identical
actions (the same discipline `productionManifests` uses to split rendering from effect):

```haskell
-- An ordered, provider-specific list of actions a CDN provisioning would take.
-- Pure: built by 'planCdn' from a 'Cdn' + 'CdnTarget', printed by 'renderCdnPlan',
-- and executed by 'provisionCdn'. Holds NO secrets (the Cloudflare token never
-- appears here) so it is safe to print.
data CdnPlan = CdnPlan
  { planProvider :: !CdnProvider
  , planActions  :: ![CdnAction]
  }
  deriving stock (Generic, Eq, Show)

data CdnAction
  = DnsUpsert  !Text !Text !Text    -- hostname, target IP, "proxied" | "A-record"
  | CacheRule  !Text !Text          -- path prefix, ttl description ("31536000s" | "never")
  | OriginTls  !Text                -- mode description, e.g. "Flexible"
  | GcloudCmd  ![Text]              -- a gcloud argv we would run (already includes --project)
  deriving stock (Generic, Eq, Show)
```

Write `planCdn :: Cdn -> CdnTarget -> GcpStackRefs -> CdnPlan` as a pure function (the
`GcpStackRefs` record carries the Google-only inputs `cdnGlobalIp`, `cdnBackendService`,
`cdnUrlMap`, `dnsZoneName`; for the Cloudflare branch they are unused). For `CloudflareCdn`, the
actions are: one `DnsUpsert host originIp "proxied"` per hostname is WRONG for Cloudflare —
Cloudflare proxies the hostname at the origin IP, so it is `DnsUpsert host originIp "proxied"`
(the target IS the origin IP because Cloudflare's edge sits transparently in front; record that in
a comment), one `OriginTls "Flexible"`, and one `CacheRule prefix ttl` per `cacheRules` entry plus
the implicit static-asset and default-TTL rules. For `GcpCloudCdn`, the actions are: one
`DnsUpsert host cdnGlobalIp "A-record"` per hostname realized as a `GcloudCmd` that calls `gcloud
dns record-sets ...` (more-specific A record → the global IP; this is how the hostname is split
off the wildcard), plus `GcloudCmd`s that call `gcloud compute backend-services update
<cdnBackendService> ...` and/or `gcloud compute url-maps ...` for the cache behaviour. Every
`gcloud` argv built here MUST contain `--project=tan-nb-exp`.

Write the gcloud-arg builders as small pure functions so they are unit-testable in isolation, for
example `gcloudDnsUpsertArgs :: Text -> Text -> Text -> [Text]` (zone, hostname, ip) producing the
exact argv `["dns", "record-sets", "create", host <> ".", "--type=A", "--ttl=300",
"--rrdatas=" <> ip, "--zone=" <> zone, "--project=tan-nb-exp"]` (use `transaction`/`create`
semantics per EP-54's recorded approach; `create` plus a delete-on-disable is the simplest), and
`gcloudBackendCacheArgs :: Text -> Cdn -> [Text]`. Keeping these pure means a test asserts the
exact argv without running `gcloud`.

Write `renderCdnPlan :: CdnPlan -> Text` that prints a stable, human-readable block (used by
`--dry-run` and echoed before each live action). It starts with a header naming the provider and
lists each action on its own line, e.g. `DNS: blog.example.com -> 203.0.113.10 (proxied)` or
`gcloud dns record-sets create blog.example.com. --type=A ... --project=tan-nb-exp`. This is the
function the dry-run transcript shows and a golden test pins.

Write `provisionCdn :: Cdn -> CdnTarget -> GcpStackRefs -> IO (Either Text CdnResult)`. It builds
the plan with `planCdn`, then executes by dispatching on `provider cdn`:

- `CloudflareCdn`: `loadCloudflareCreds` (a `Left` short-circuits with a clear message), then for
  each hostname `upsertProxiedRecord creds host originIp`, `setOriginTlsMode creds host Flexible`,
  and `applyCacheRules creds host cdn`. Thread the `Either Text ()` results; the first `Left`
  becomes the function's `Left`. On success, `cdnEdgeUrls = ["https://" <> h | h <- hostnames]`.
- `GcpCloudCdn`: run each `GcloudCmd` from the plan via `captureTool "gcloud" (map T.unpack args)`;
  a `Nothing` (non-zero exit / missing binary) becomes a `Left` naming the failed command. On
  success, the edge URLs are the same `https://<host>` (now resolving to `cdnGlobalIp`).

Wire it into the static path. In `Nagare.Static.Deploy.deployStaticProduction`, after
`waitForReady (serviceName m) ns` and before/around `recordRelease`, add: when `s ^. #cdn` is
`Just c`, resolve a `CdnTarget` (hostnames from `s ^. #domains` via `domainText`, origin IP from
`stackOutput "infra/pulumi" "publicIp"`, namespace and service from the manifests) and the
`GcpStackRefs` (the four stack outputs), call `provisionCdn c target refs`, and fold the result —
a `Left` is reported (the deploy already succeeded; the CDN failure is surfaced, not fatal to the
origin) and a `Right` prints `cdnSummary`. Because `deployStaticProduction` already returns
`Either Text Text`, prefer returning the CDN failure as a `Left` only if the operator wants a
hard failure; the conservative choice (recorded in the Decision Log) is to print the CDN error to
stderr and still return the origin URL. The same edit goes into
`Nagare.Server.Deploy.deployServerProduction`.

Wire it into the generic app path. In `runDeploy` (`app/Main.hs`): in the non-dry-run branch,
after `waitForReady name ns`, when `dep' ^. #cdn` is `Just c`, build the target and refs and call
`provisionCdn`. In the dry-run branch (which already prints rendered manifests and the URL), when
`#cdn` is `Just c`, build the plan with `planCdn` and `TIO.putStr (renderCdnPlan plan)` under a
`--- CDN plan ---` banner so `nagarectl deploy --dry-run` shows exactly what the CDN step would do.

Register the new module. Add `Nagare.Cdn.Provision` to `exposed-modules` in
`cli/nagarectl/nagarectl.cabal` (alphabetically, near `Nagare.Cdn.Cloudflare`).

Add tests. In `cli/nagarectl/test/Spec.hs`, add: a `planCdn`/dispatch test asserting that a
`CloudflareCdn` config produces `DnsUpsert`/`OriginTls`/`CacheRule` actions and no `GcloudCmd`,
and a `GcpCloudCdn` config produces `GcloudCmd`s whose argv contains `--project=tan-nb-exp`; a
`gcloudDnsUpsertArgs` golden asserting the exact argv; a target-resolution test (a site with two
domains yields two hostnames in order); and a `renderCdnPlan` golden for a small mixed plan.


### Milestone 2 — The `nagarectl cdn` command group

Scope: the `cdn` command group (`list`, `status`, `purge`, `disable`) added to the parser and a
new ops module `cli/nagarectl/src/Nagare/Cdn/Status.hs` holding the pure formatters and the thin
discovery that reuses `Nagare.Ops.Domains`. At the end, `cabal test` passes, `nagarectl cdn
--help` lists the four subcommands, and the pure formatters render against mocked kubectl/stack
output in unit tests.

`Nagare.Cdn.Status` defines a row type and formatters parallel to `Nagare.Ops.Domains`:

```haskell
-- One CDN-fronted hostname's state for `cdn list` / `cdn status`.
data CdnRow = CdnRow
  { cdnRowHost     :: !Text
  , cdnRowProvider :: !Text            -- "Cloudflare" | "GcpCloudCdn"
  , cdnRowDns      :: !CdnDnsTarget    -- where the hostname currently points
  , cdnRowCache    :: !Text            -- short cache summary, e.g. "default 3600s, 2 rules"
  , cdnRowReady    :: !Bool            -- edge/cert readiness
  }
  deriving stock (Generic, Eq, Show)

data CdnDnsTarget = PointsAtEdge !Text | PointsAtVm !Text | DnsUnknown
  deriving stock (Generic, Eq, Show)

formatCdnList   :: [CdnRow] -> Text   -- aligned table, parallel to formatDomainList
formatCdnStatus :: CdnRow  -> Text    -- one host's field block
```

`formatCdnList []` returns `"(no CDN-fronted hostnames)\n"`. `formatCdnList` prints an aligned
`HOST / PROVIDER / DNS / CACHE / READY` table; `formatCdnStatus` prints the same fields one per
line (`Host: ... / Provider: ... / DNS: points at edge (203.0.113.20) / Cache: ... / Ready: ...`).
These are pure and golden-tested exactly like `formatDomainList`.

Discovery. `cdn list`/`cdn status` reuse `Nagare.Ops.Domains.queryDomainRows`/`listNamespaces` to
enumerate hostnames and their DomainMapping/cert readiness, then ask the relevant provider whether
each hostname's DNS currently resolves to the edge or the VM — for the Google provider compare the
resolved A record (read via `gcloud dns record-sets list ... --project=tan-nb-exp`) against
`cdnGlobalIp` vs `publicIp`; for Cloudflare report `PointsAtEdge` when `upsertProxiedRecord` has
been applied (i.e. the record is proxied). The thin IO that gathers this lives in `Status.hs`
(provider reads) and in the handlers in `app/Main.hs`; the pure row-building and formatting are
testable without a cluster.

Add the command group to `app/Main.hs`:

1. A sub-ADT and constructor:

```haskell
data CdnCommand
  = CdnList CdnListOpts
  | CdnStatus CdnStatusOpts
  | CdnPurge CdnPurgeOpts
  | CdnDisable CdnDisableOpts
```

and `| CdnCmd CdnCommand` added to `data Command` (the `CdnCmd` name avoids the `Cdn` type clash).

2. Opts records and parsers: `CdnListOpts` with `-n/--namespace` (reusing `namespaceOpt`) and
`--all-namespaces` (reusing the same `switch` shape as `DomainsListOpts`); `CdnStatusOpts` with a
positional `HOST` and `-n`; `CdnPurgeOpts` with a positional `HOST`, repeated `--path P` (a
`many (strOption ...)`), and `-n`; `CdnDisableOpts` with a positional `HOST` and `-n`. The purge
and disable parsers also take `dryRunOpt`.

3. The subparser and the registration:

```haskell
    cdnCmd =
      info
        (cdnSubparser <**> helper)
        (fullDesc <> progDesc "Inspect and manage CDN-fronted hostnames (list, status, purge, disable)")
    cdnSubparser =
      subparser
        ( command "list"    (info (CdnCmd . CdnList    <$> cdnListOptsParser    <**> helper) (progDesc "List CDN-fronted sites/apps, provider, and edge status"))
            <> command "status"  (info (CdnCmd . CdnStatus  <$> cdnStatusOptsParser  <**> helper) (progDesc "Show one hostname's provider, DNS target, cache config, and readiness"))
            <> command "purge"   (info (CdnCmd . CdnPurge   <$> cdnPurgeOptsParser   <**> helper) (progDesc "Purge the edge cache for a hostname (optionally specific --path values)"))
            <> command "disable" (info (CdnCmd . CdnDisable <$> cdnDisableOptsParser <**> helper) (progDesc "Revert a hostname's DNS back to the VM (un-proxy / delete the A record)"))
        )
```

and add `<> command "cdn" cdnCmd` to `commandParser`.

4. The dispatch branch in `main`: `CdnCmd ccmd -> runCdn ccmd`, and a `runCdn :: CdnCommand -> IO
()` that pattern-matches the four constructors to handlers `runCdnList`, `runCdnStatus`,
`runCdnPurge`, `runCdnDisable`. `runCdnPurge` dispatches on the hostname's provider: Cloudflare →
`purgeHostname creds host paths`; Google → `captureTool "gcloud" ["compute", "url-maps",
"invalidate-cache", urlMap, "--path=" <> p, "--project=tan-nb-exp"]` per path (or `/*` when no
`--path`). `runCdnDisable` reverts: for Google, delete the more-specific A record (so the hostname
falls back to the wildcard/VM); for Cloudflare, un-proxy the record. Both honour `--dry-run` by
printing the planned action via `renderCdnPlan`/an inline `gcloud` echo instead of executing.

Add tests for `formatCdnList`/`formatCdnStatus` in `test/Spec.hs`, golden-style, including the
empty-list sentinel and a `PointsAtEdge` vs `PointsAtVm` rendering.


### Live legs (environment-gated, deferred)

The cloud legs — provisioning against a real Cloudflare zone with a real `CF_API_TOKEN`, against a
real Google load balancer, and writing real Cloud DNS records — cannot run in CI or against the
powered-off VM `nagare-01`. Following the precedent of EP-43 and EP-49 in this repo, deliver the
code plus the exact manual validation steps now (see Validation and Acceptance) and mark the live
run deferred. Do NOT block Milestones 1 and 2 on it.


## Concrete Steps

All commands assume the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a working
directory is shown. Prefer absolute paths; the build runs inside `cli/nagarectl`.

First, confirm the hard dependencies exist (this plan cannot compile otherwise):

```bash
ls cli/nagare-dsl/src/Nagare/Dsl/Cdn/Types.hs \
   cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs
grep -n 'cdnGlobalIp\|cdnBackendService\|cdnUrlMap' infra/pulumi/index.ts infra/pulumi/src/components/*.ts
grep -rn 'cdn ::' cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs \
                  cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs \
                  cli/nagare-dsl/src/Nagare/Dsl/Types.hs
```

Expected: the two files exist, the three stack outputs appear in the Pulumi sources, and a `cdn ::
!(Maybe Cdn)` field is present on `StaticSite`, `ServerSite`, and `Deployment`. If any is missing,
stop and implement the relevant sibling plan first.

Create the provisioning module:

```bash
$EDITOR cli/nagarectl/src/Nagare/Cdn/Provision.hs
```

Register it in the cabal file (add `Nagare.Cdn.Provision` to `exposed-modules`, alphabetically):

```bash
$EDITOR cli/nagarectl/nagarectl.cabal
```

Build the library incrementally as you go:

```bash
cabal build nagarectl
```

(Run from inside `cli/nagarectl`. The first build of a fresh module surfaces type errors fastest.)

Wire the three deploy paths, then create the status module and the command group:

```bash
$EDITOR cli/nagarectl/src/Nagare/Static/Deploy.hs
$EDITOR cli/nagarectl/src/Nagare/Server/Deploy.hs
$EDITOR cli/nagarectl/app/Main.hs
$EDITOR cli/nagarectl/src/Nagare/Cdn/Status.hs
```

Add tests:

```bash
$EDITOR cli/nagarectl/test/Spec.hs
```

Build and test (run from inside `cli/nagarectl`):

```bash
cabal build nagarectl
cabal test
```

Expected `cabal test` tail (the exact counts grow as you add cases):

```text
nagarectl-test: ... examples, 0 failures
Test suite nagarectl-test: PASS
```

Exercise the dry-run for the two headline cases. Point `-f` at a CDN-enabled example config (the
ones EP-59 will check in under `cluster/examples/`, or a local fixture). A static site fronted by
Cloudflare:

```bash
cabal run nagarectl -- site deploy -f cluster/examples/cdn-static-cloudflare/nagare/Config.hs --dry-run
```

Expected tail (after the rendered Nginx/Service/DomainMapping artifacts and the URL):

```text
--- CDN plan (Cloudflare) ---
DNS: blog.example.com -> 203.0.113.10 (proxied)
Origin TLS: Flexible
Cache: /assets/ -> 31536000s
Cache: /api/   -> never
Cache: (default) -> 3600s
Release: 20260610-120000
```

A TanStack Start server site fronted by Google Cloud CDN:

```bash
cabal run nagarectl -- site deploy -f cluster/examples/cdn-tanstack-gcp/nagare/Config.hs --dry-run
```

Expected tail:

```text
--- CDN plan (GcpCloudCdn) ---
gcloud dns record-sets create app.example.com. --type=A --ttl=300 --rrdatas=203.0.113.20 --zone=nagare-zone --project=tan-nb-exp
gcloud compute backend-services update nagare-cdn-backend --cache-mode=USE_ORIGIN_HEADERS --default-ttl=3600 --project=tan-nb-exp
URL: https://app.example.com
Release: 20260610-120000
```

Confirm the no-CDN path is unchanged: run the same `site deploy --dry-run` against an example with
no `cdn` field and verify no `--- CDN plan ---` banner appears (its output is identical to before
this plan).

Confirm the command group is wired:

```bash
cabal run nagarectl -- cdn --help
```

Expected:

```text
Usage: nagarectl cdn COMMAND
  Inspect and manage CDN-fronted hostnames (list, status, purge, disable)

Available commands:
  list     List CDN-fronted sites/apps, provider, and edge status
  status   Show one hostname's provider, DNS target, cache config, and readiness
  purge    Purge the edge cache for a hostname (optionally specific --path values)
  disable  Revert a hostname's DNS back to the VM (un-proxy / delete the A record)
```


## Validation and Acceptance

Milestone 1 acceptance, all offline: (a) `cd cli/nagarectl && cabal test` passes, including the
new `planCdn` dispatch test, the `gcloudDnsUpsertArgs` golden (argv contains `--project=tan-nb-exp`),
the target-resolution test, and the `renderCdnPlan` golden. (b) `nagarectl site deploy --dry-run`
on a Cloudflare-enabled static example prints the `--- CDN plan (Cloudflare) ---` block shown
above with one `DNS:` line per domain, the `Origin TLS:` line, and one `Cache:` line per rule plus
the default. (c) The same on a Google-enabled server example prints the `--- CDN plan
(GcpCloudCdn) ---` block whose `gcloud` lines each end with `--project=tan-nb-exp`. (d) The same on
a no-CDN example prints NO CDN banner and is byte-identical to the pre-plan output (diff the two
transcripts).

Milestone 2 acceptance, all offline: (a) `cabal test` passes including the `formatCdnList`,
`formatCdnStatus`, and empty-list-sentinel goldens. (b) `nagarectl cdn --help` lists exactly
`list`, `status`, `purge`, `disable`. (c) `nagarectl cdn status <host>` and `nagarectl cdn list`
render an aligned table / field block against mocked kubectl + stack output (the pure
`formatCdn*` functions are exercised directly in tests; the IO wrappers degrade gracefully to an
empty table when `kubectl`/`gcloud`/`pulumi` are absent, mirroring `runDomainsList`).

Live acceptance (deferred, environment-gated; run when `nagare-01` is on, a real `baseDomain` is
delegated, and `CF_API_TOKEN` is exported). Cloudflare case: with a static example whose `cdn =
Just (cloudflareCdn & ...)`, run `nagarectl site deploy`; confirm the printed summary reports the
hostname proxied; `dig +short blog.<baseDomain>` returns Cloudflare edge IPs (not the VM IP);
`curl -sI https://blog.<baseDomain>` shows a `cf-cache-status` header; `nagarectl cdn status
blog.<baseDomain>` reports `PointsAtEdge`; `nagarectl cdn purge blog.<baseDomain>` returns success;
`nagarectl cdn disable blog.<baseDomain>` un-proxies and `dig` then returns the VM IP. Google case:
with a server example whose `cdn = Just (gcpCloudCdn & ...)`, run `nagarectl site deploy`; confirm
`gcloud dns record-sets list --zone=<dnsZoneName> --project=tan-nb-exp` shows a more-specific A
record for the hostname pointing at `cdnGlobalIp`; `dig +short app.<baseDomain>` returns
`cdnGlobalIp`; a second `curl` of a cacheable asset shows a cache HIT; `nagarectl cdn disable`
deletes the more-specific record and `dig` then returns the wildcard/VM IP. Record the transcripts
in this plan's Outcomes & Retrospective when the live legs run.


## Idempotence and Recovery

The pure planning and formatting (`planCdn`, `renderCdnPlan`, `formatCdn*`, the gcloud-arg
builders) are referentially transparent — running them repeatedly yields the same result and has
no effect. The `--dry-run` paths make no changes and can be run any number of times.

Live provisioning is designed to be re-runnable. Cloudflare's `upsertProxiedRecord` is an upsert
(create-or-update), so re-running a deploy re-asserts the same proxied record without error;
`applyCacheRules` and `setOriginTlsMode` are likewise declarative re-assertions. For Google, the
`gcloud dns record-sets` step must tolerate an existing record: prefer the transaction/`create`
pattern guarded by a pre-check, or treat an "already exists / no change" `gcloud` exit as success
in the handler so a repeated deploy is a no-op rather than a failure (record the exact approach in
the Decision Log once EP-54's recorded DNS technique is confirmed). `gcloud compute
backend-services update` and `url-maps` edits are idempotent updates.

Recovery from a half-applied CDN: because provisioning runs AFTER the origin is Ready, a CDN
failure never takes the origin down — the site is still reachable at its origin URL. To fully back
out, `nagarectl cdn disable <host>` reverts DNS (Google: delete the more-specific A record so the
wildcard/VM wins again; Cloudflare: un-proxy the record), after which the hostname serves from the
VM exactly as a non-CDN site. The Pulumi-managed standing infrastructure (the load balancer,
anycast IP, managed cert) is owned by EP-56 and is not torn down by `disable`; it is removed with a
`pulumi destroy` of that component if ever needed.


## Interfaces and Dependencies

Libraries and modules this plan uses and why. `Options.Applicative` (already a dependency) for the
new `cdn` parser tree in `cli/nagarectl/app/Main.hs`. `Nagare.Dsl.Cdn.Types` (from EP-55) for the
`Cdn`/`CdnProvider`/`CdnCacheRule` types this plan dispatches on. `Nagare.Cdn.Cloudflare` (from
EP-57) for the Cloudflare API calls (`loadCloudflareCreds`, `upsertProxiedRecord`,
`setOriginTlsMode`, `applyCacheRules`, `purgeHostname`, `OriginTlsMode`). `Nagare.Ops.Pulumi.stackOutput`
for reading `publicIp`, `cdnGlobalIp`, `cdnBackendService`, `cdnUrlMap`, and `dnsZoneName`.
`Nagare.Ops.Probe.captureTool` for the tolerant `gcloud` shell-outs (the Google branch), honouring
the repo's `--project=tan-nb-exp` policy. `Nagare.Ops.Domains` (`queryDomainRows`, `listNamespaces`,
the `DomainRow`/`CertState` types) for the `cdn list`/`cdn status` discovery. `Nagare.Deploy`
(`applyManifests`, `waitForReady`) is unchanged but defines where in each deploy path the CDN step
slots in.

Types, interfaces, and signatures that must exist at the end of each milestone.

End of Milestone 1 — `cli/nagarectl/src/Nagare/Cdn/Provision.hs` exports:

```haskell
data CdnTarget = CdnTarget { cdnHostnames :: ![Text], cdnOriginIp :: !Text, cdnNamespace :: !Text, cdnService :: !Text }
data CdnResult = CdnResult { cdnEdgeUrls :: ![Text], cdnSummary :: !Text }
data GcpStackRefs = GcpStackRefs { gsrGlobalIp :: !Text, gsrBackendService :: !Text, gsrUrlMap :: !Text, gsrDnsZone :: !Text }
data CdnPlan
data CdnAction

planCdn          :: Cdn -> CdnTarget -> GcpStackRefs -> CdnPlan
renderCdnPlan    :: CdnPlan -> Text
provisionCdn     :: Cdn -> CdnTarget -> GcpStackRefs -> IO (Either Text CdnResult)
gcloudDnsUpsertArgs :: Text -> Text -> Text -> [Text]   -- zone, hostname, ip  (argv incl. --project=tan-nb-exp)
gcloudBackendCacheArgs :: Text -> Cdn -> [Text]         -- backend-service name, typed cache config
```

`Nagare.Static.Deploy.deployStaticProduction` and `Nagare.Server.Deploy.deployServerProduction`
keep their existing signatures (`... -> Maybe Text -> IO (Either Text Text)`) but now call
`provisionCdn` after `waitForReady` when `#cdn` is `Just`. `runDeploy` in `app/Main.hs` calls
`provisionCdn` after `waitForReady` (live) and `renderCdnPlan` under `--dry-run`.

End of Milestone 2 — `cli/nagarectl/src/Nagare/Cdn/Status.hs` exports:

```haskell
data CdnRow = CdnRow { cdnRowHost :: !Text, cdnRowProvider :: !Text, cdnRowDns :: !CdnDnsTarget, cdnRowCache :: !Text, cdnRowReady :: !Bool }
data CdnDnsTarget = PointsAtEdge !Text | PointsAtVm !Text | DnsUnknown

formatCdnList   :: [CdnRow] -> Text
formatCdnStatus :: CdnRow  -> Text
queryCdnRows    :: Text -> Text -> Text -> IO [CdnRow]   -- baseDomain, originIp, namespace (thin IO, degrades to [])
```

`cli/nagarectl/app/Main.hs` gains `data CdnCommand = CdnList CdnListOpts | CdnStatus CdnStatusOpts
| CdnPurge CdnPurgeOpts | CdnDisable CdnDisableOpts`, the `CdnCmd CdnCommand` constructor on
`data Command`, the four opts records and parsers, the `cdnCmd`/`cdnSubparser` definitions, the
`command "cdn" cdnCmd` registration, and the `CdnCmd ccmd -> runCdn ccmd` dispatch with
`runCdn`/`runCdnList`/`runCdnStatus`/`runCdnPurge`/`runCdnDisable`.

The cabal package `cli/nagarectl/nagarectl.cabal` lists `Nagare.Cdn.Provision` and
`Nagare.Cdn.Status` (and, from EP-57, `Nagare.Cdn.Cloudflare`) under the `library` stanza's
`exposed-modules`. No new third-party dependency is introduced by this plan — the HTTP client that
talks to Cloudflare is owned entirely by EP-57's `Nagare.Cdn.Cloudflare`; this plan only calls its
functions, and the Google branch shells out to `gcloud` via the existing `captureTool`.
