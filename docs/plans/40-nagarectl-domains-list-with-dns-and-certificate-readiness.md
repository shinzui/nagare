---
id: 40
slug: nagarectl-domains-list-with-dns-and-certificate-readiness
title: "nagarectl domains list with DNS and certificate readiness"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# nagarectl domains list with DNS and certificate readiness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change an operator can run one command and see every domain the platform serves —
the shared platform base domain plus every per-app Knative `DomainMapping` — together with the
Service each domain belongs to, what DNS record the domain *should* resolve to, and whether its
TLS certificate is ready. Today that knowledge is scattered: the base domain lives in a Pulumi
stack output and an in-cluster ConfigMap, per-app domains live in `DomainMapping` objects across
namespaces, and certificate state lives in cert-manager `Certificate` objects. There is no single
place to answer "what domains do I have, where should they point, and are they HTTPS-ready?" This
plan adds `nagarectl domains list` to answer exactly that, in one aligned table.

The command surface this plan delivers:

```text
nagarectl domains list [-n NS] [--all-namespaces] [--base-domain DOMAIN]

  list   Enumerate the platform base domain and every per-app DomainMapping,
         showing the owning Service, the expected DNS record, and certificate
         readiness. Read-only.
```

`domains` is introduced as a command *group* (like the existing `site` group) so that future
`domains add` / `domains remove` subcommands have a home, but this plan ships only `domains list`.

You can see it working end to end. Deploy an app that requests a custom domain, which makes
`nagarectl deploy` create a Knative `DomainMapping`; then run `domains list`:

```text
$ nagarectl deploy            # app config maps app.nadeem.dev -> the Service
...
$ nagarectl domains list
  DOMAIN                          SERVICE          DNS                              CERT
  apps.example.com               (base)           *.apps.example.com A -> 34.x.x.x  disabled
  app.nadeem.dev                 blog             *.apps.example.com A -> 34.x.x.x  Ready
```

The first row is the platform base domain (the wildcard apex). Each subsequent row is a
`DomainMapping`: its hostname, the Service it routes to (`.spec.ref.name`), the DNS record the
domain is expected to match (computed from the Pulumi wildcard + reserved IP — not a live `dig`),
and its certificate readiness. When external-domain TLS is disabled (the current bootstrap state,
because the placeholder `apps.example.com` cannot pass an ACME DNS-01 challenge), the `CERT` column
reads `disabled` rather than erroring.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Pure module `Nagare.Ops.Domains` — `DomainRow`/`DnsExpectation`/`CertState` types, the
  `DomainMapping` and `Certificate` JSON extractors (`extractDomainMappings`,
  `extractCertReadiness`), the DNS-expectation computation (`dnsExpectationFor`), and the
  `formatDomainList` table formatter. Added to the cabal library `exposed-modules`. Covered by
  `testGroup "Nagare.Ops.Domains"` in `test/Spec.hs`.
- [ ] M2: `nagarectl domains list` wired in `app/Main.hs` — `domains` command group with a `list`
  subcommand, namespace selection (`-n` / `--all-namespaces`, default `personal`), base-domain
  resolution (Pulumi-then-ConfigMap-then-fallback), and graceful TLS-disabled handling so a missing
  `Certificate` (or a TLS-off cluster) shows `disabled`, not an error.
- [ ] M3: Tests green (`cabal build && cabal test`) and a captured `nagarectl domains list --help`
  transcript. Live cluster run deferred (pure parsers/formatters validated by unit tests).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `domains list` is strictly read-only. It only runs `kubectl get … -o json` (and reads
  the base domain). It never patches, deletes, or applies anything.
  Rationale: An inventory command must be safe to run anywhere, anytime, including against a
  production cluster, with no risk of side effects. Mutating domains (`add`/`remove`) is explicitly
  out of scope for this plan.
  Date: 2026-06-09

- Decision: Reuse `Nagare.App`'s existing `DomainMapping` query path rather than duplicating kubectl
  plumbing. `Nagare.App.extractDomainsFor` already decodes a `kubectl get domainmapping … -o json`
  list and pulls `.spec.ref.name`; the new `Nagare.Ops.Domains` extractors decode the same JSON shape
  and extend it (keep the hostname, the owning Service, and the Ready condition) instead of inventing
  a new query.
  Rationale: One JSON shape, one tested decoder family. Diverging plumbing would risk the two
  commands disagreeing about what domains exist.
  Date: 2026-06-09

- Decision: Readiness is shown for both the `DomainMapping` and the `Certificate`. The table has a
  per-row `CERT` column derived from the cert-manager `Certificate` Ready condition; the
  `DomainMapping`'s own Ready condition is also surfaced (so a routing-not-ready domain is visible
  distinct from a cert-not-ready one).
  Rationale: A domain can be live-but-insecure (route Ready, cert pending) or
  configured-but-unrouted (mapping not Ready). Operators need to tell those apart.
  Date: 2026-06-09

- Decision: The DNS column is a *computed expectation*, not a live DNS lookup, for v1. It is derived
  from the Pulumi `publicIp` and the wildcard `*.<baseDomain>` record Pulumi provisions — the column
  states whether the domain falls under that wildcard and what IP it should resolve to. No `dig` /
  resolver call is made.
  Rationale: Live DNS resolution is flaky, slow, and environment-dependent (split-horizon, caching),
  and would make the command non-deterministic and untestable without network. A computed
  expectation is deterministic, unit-testable, and still answers "is this domain provisioned to
  resolve?". Live resolution can be layered on later.
  Date: 2026-06-09

- Decision: Soft-reuse EP-38's helpers when present, but do not block on EP-38. If
  `Nagare.Ops.Pulumi.stackOutput` and EP-38's shared table `pad`/formatter exist, use them;
  otherwise read the base domain via the existing fallback chain and copy the `pad` helper from
  `Nagare.App.formatAppList` verbatim. EP-38's probe *grading* model is not used.
  Rationale: EP-40 has its own data sources (`DomainMapping`, `Certificate`) and can be built
  independently against the same kubectl patterns; coupling its delivery to EP-38 would serialize
  two otherwise-parallel plans.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about the codebase. Read it before touching any file.

**The CLI structure.** `nagarectl` is a Haskell/Cabal/GHC-9.12 program under
`cli/nagarectl/`. The executable entry point is `cli/nagarectl/app/Main.hs` (~1462 lines); reusable
logic lives in library modules under `cli/nagarectl/src/Nagare/` and is declared in
`cli/nagarectl/nagarectl.cabal`. Commands are modeled as a `Command` sum type
(`app/Main.hs` ~line 233, constructors like `AppList`, `DeploymentsList`, `SitePreviewList`). The
parser `opts` (~line 540) builds a top-level `subparser` (~line 549) registering
`deploy`/`site`/`env`/`secret`/`app`/`deployments`. `main` (~line 776) pattern-matches each
`Command` constructor to a `run*` handler. The `site` command (~line 561, `siteCmd` → `siteSubparser`)
is the precedent for a *group*: a subparser nested inside the top-level subparser, e.g. `site
preview list`. We follow that precedent: `domains` is a group whose first (and, for this plan, only)
subcommand is `list`, so the invocation is `nagarectl domains list`.

**What already queries DomainMappings.** `cli/nagarectl/src/Nagare/App.hs` already talks to Knative
`DomainMapping` objects. `appDomains` (~line 348) runs `kubectl get domainmapping -n <ns> -o json`
and feeds the bytes to the pure `extractDomainsFor :: Text -> ByteString -> Either Text [Text]`
(~line 361), which decodes the `.items` array and returns the `.metadata.name` of every mapping
whose `.spec.ref.name` equals a given Service. A *DomainMapping* is a Knative object
(`apiVersion: serving.knative.dev/v1beta1`, `kind: DomainMapping`) that binds a custom hostname to a
Service; its `.spec.ref.name` is the owning Service and its `.status.conditions[]` contains a
`Ready` condition. This plan's `Nagare.Ops.Domains` extractors decode the *same* JSON shape but keep more
fields (hostname, owning Service, Ready). Reuse the JSON-walking helpers' approach from `Nagare.App`:
`lookupPath` (~line 256), `textAt` (~line 262), and `readyOf` (~line 247, the
`select(.type=="Ready") | .status == "True"` pattern). These are currently un-exported from
`Nagare.App`; `Nagare.Ops.Domains` will define its own tiny copies (they are three lines each) to stay
self-contained and unit-testable, mirroring how `Nagare.App` already keeps a local `dieApp` copy.

**How it shells out.** All `kubectl` calls go through the `cradle` library (`import Cradle`). Two
forms appear: fire-and-forget `run_ $ cmd "kubectl" & addArgs [...]`, and capture
`(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs [...] & silenceStderr` where `out` is a
`ByteString` you decode with Aeson. `appDomains` (`Nagare.App.hs` ~line 348) is the exact pattern to
copy for the new domain/cert queries: capture stdout, `silenceStderr`, and on `ExitFailure` treat
the resource as absent (return `[]`) rather than failing — important because `Certificate` objects
may not exist at all (TLS disabled). Errors to the user go through `dieT :: Text -> IO a`
(`app/Main.hs` ~line 1439), which prints `nagarectl: <msg>` to stderr and exits non-zero.

**DNS and certificate ground truth.** The platform base domain is authoritative in two places that
should agree: the Pulumi stack output `baseDomain` (`infra/pulumi/index.ts:47`, read with
`pulumi -C infra/pulumi stack output baseDomain`; currently the placeholder `apps.example.com`) and
the in-cluster `config-domain` ConfigMap (`cluster/bootstrap/knative-serving/config-domain.yaml`;
read with `kubectl get configmap config-domain -n knative-serving -o json` — Knative's convention is
unusual: the domain is a *key* under `.data` with an empty string value). DNS is provisioned by
Pulumi: a Cloud DNS managed zone (output `dnsZoneName`, `infra/pulumi/index.ts:51`) holds a wildcard
record `*.<baseDomain> A -> publicIp` with TTL 300, where `publicIp` is the reserved static IP
(output `publicIp`, `infra/pulumi/index.ts:46`). For v1 the DNS column is *computed* from these two
facts (does the domain fall under `*.<baseDomain>`, and the target is `publicIp`) — not a live
lookup. Certificates are cert-manager `Certificate` objects (`apiVersion: cert-manager.io`,
`kind: Certificate`), one wildcard `*.<namespace>.<baseDomain>` per namespace, issued by the
`letsencrypt-dns` ClusterIssuer (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) via DNS-01,
once external-domain TLS is enabled. **Current state: external-domain TLS is DISABLED.** The toggle
lives in the `config-network` ConfigMap; the enabling patch
`cluster/bootstrap/knative-serving/config-network-tls.yaml` (`external-domain-tls: Enabled`,
`namespace-wildcard-cert-selector: "{}"`) is deliberately not applied in the HTTP-first bootstrap,
because the placeholder `apps.example.com` cannot complete an ACME DNS-01 challenge. Consequently
`Certificate` objects may be entirely absent today, so the `CERT` column must render `disabled` (or
`absent`) gracefully rather than treating the missing resource as an error.

**Namespaces.** Apps live in the `personal` namespace by default (and possibly others). The default
namespace constant pattern is `appNamespace = maybe "personal" T.pack` (`app/Main.hs` ~line 1063),
and the namespace flag parser is `namespaceOpt :: Parser (Maybe String)` (`app/Main.hs` ~line 405,
`-n`/`--namespace`). `DomainMapping` and `Certificate` are namespaced resources, so the query is
per-namespace; `--all-namespaces` will iterate the namespaces the operator cares about (default:
just `personal`).

**Tests.** `cli/nagarectl/test/Spec.hs` is a Tasty + tasty-hunit suite. `main` (~line 82) calls
`defaultMain $ testGroup "nagarectl" [ … ]` with one `testGroup` per module, e.g.
`testGroup "Nagare.App" appTests` (~line 99). We add `testGroup "Nagare.Ops.Domains" domainsTests` to
that list. Tests exercise only the pure extractors and formatter with `@?=`; there is no kubectl
mocking, and live runs are deferred.

**Relationship to EP-38 (soft dependency).** This plan is EP-40 of MasterPlan 8
(`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`). It *soft-depends* on EP-38
(`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`), which introduces
`cli/nagarectl/src/Nagare/Ops/` with `Nagare.Ops.Pulumi.stackOutput` (a Pulumi-stack-output
reader) and a shared aligned-table formatter built on the same `pad` helper. If those exist when you
implement this plan, reuse them for base-domain resolution and table padding. If they do not (EP-38
is not a hard prerequisite), read the base domain via the existing fallback chain and copy `pad` from
`Nagare.App.formatAppList`. EP-40 does **not** use EP-38's probe *grading* model.


## Plan of Work

The work splits into three independently verifiable milestones: a pure, fully-tested
`Nagare.Ops.Domains` module (M1); wiring it into the CLI as `domains list` (M2); and final test/help
verification with the live run deferred (M3).

### Milestone 1 — Pure `Nagare.Ops.Domains` module with extractors, DNS expectation, and formatter

**Scope:** Create `cli/nagarectl/src/Nagare/Ops/Domains.hs` containing only pure functions and data
types — no `kubectl` IO. Decode `DomainMapping` and `Certificate` JSON, compute the DNS expectation,
and format the table. Add the module to the cabal library `exposed-modules`. Add a
`testGroup "Nagare.Ops.Domains"` to `cli/nagarectl/test/Spec.hs`. At the end of M1 the module compiles,
is exported, and its tests pass — without any cluster.

Define the data types. A `DomainRow` is one table row; `DnsExpectation` and `CertState` are small
sums kept distinct from `Text` so the formatter is total:

```haskell
-- | One row of `domains list`: a domain, the Service it routes to, its DNS
-- expectation, and its certificate state.
data DomainRow = DomainRow
  { drDomain      :: !Text            -- ^ the hostname (base apex, or DomainMapping host)
  , drService     :: !(Maybe Text)    -- ^ owning Service (.spec.ref.name); Nothing for the base row
  , drMappingReady :: !(Maybe Bool)   -- ^ DomainMapping Ready condition; Nothing for the base row
  , drDns         :: !DnsExpectation
  , drCert        :: !CertState
  }
  deriving stock (Generic, Eq, Show)

-- | What DNS *should* look like for this domain (computed, not resolved).
data DnsExpectation
  = UnderWildcard !Text   -- ^ falls under *.<baseDomain>; payload is the expected A target (publicIp)
  | OutsideWildcard       -- ^ does NOT fall under *.<baseDomain>; needs its own record
  deriving stock (Generic, Eq, Show)

-- | Certificate readiness for a domain's namespace.
data CertState
  = CertReady             -- ^ a Certificate exists and its Ready condition is True
  | CertPending           -- ^ a Certificate exists but is not yet Ready
  | CertDisabled          -- ^ no Certificate present / external-domain TLS off
  deriving stock (Generic, Eq, Show)
```

Define the extractors. They decode the same `-o json` list shapes the cluster returns, defensively
(malformed → `Left`, absent items → `Right []`), mirroring `Nagare.App.extractDomainsFor`:

```haskell
-- | Decode `kubectl get domainmapping -n <ns> -o json` into (host, service, ready) triples.
extractDomainMappings :: ByteString -> Either Text [DomainMapping]
-- where
data DomainMapping = DomainMapping
  { dmHost :: !Text, dmService :: !(Maybe Text), dmReady :: !(Maybe Bool) }
  deriving stock (Generic, Eq, Show)
-- dmHost  = .metadata.name (the hostname is the DomainMapping's name in Knative)
-- dmService = .spec.ref.name
-- dmReady  = .status.conditions[] | select(.type=="Ready") | .status == "True"

-- | Decode `kubectl get certificate -n <ns> -o json` into per-DNS-name readiness.
-- Returns the map of dnsName -> Ready (covering both .spec.dnsNames and the
-- wildcard). Used to grade each DomainRow's CertState.
extractCertReadiness :: ByteString -> Either Text [(Text, Bool)]
-- each Certificate contributes (dnsName, ready) for every name in .spec.dnsNames,
-- with ready from .status.conditions[] | select(.type=="Ready") | .status == "True"
```

Define the pure DNS-expectation computation. A domain is "under the wildcard" iff it equals
`<label>.<baseDomain>` for a single label (matching `*.<baseDomain>`), or is the apex itself:

```haskell
-- | Compute the DNS expectation for `domain` given the base domain and the
-- reserved public IP. Pure; no resolver call. v1: wildcard membership only.
dnsExpectationFor :: Text -> Text -> Text -> DnsExpectation
-- args: baseDomain publicIp domain
-- domain == baseDomain                              -> UnderWildcard publicIp (the apex/base row)
-- domain `endsWith` ("." <> baseDomain) && one extra label -> UnderWildcard publicIp
-- otherwise                                          -> OutsideWildcard
```

Define the cert grader and the formatter:

```haskell
-- | Grade one domain's CertState from the readiness map. A domain is covered by
-- a wildcard cert name *.<ns>.<baseDomain>, so match both exact and wildcard.
certStateFor :: [(Text, Bool)] -> Text -> CertState
-- no entry matches            -> CertDisabled
-- a matching entry, ready     -> CertReady
-- a matching entry, not ready -> CertPending

-- | Render rows as an aligned DOMAIN / SERVICE / DNS / CERT table. Pure.
formatDomainList :: [DomainRow] -> Text
-- header: "  " <> pad 32 "DOMAIN" <> pad 16 "SERVICE" <> pad 32 "DNS" <> "CERT"
-- DNS cell: "*.<base> A -> <ip>" for UnderWildcard ip; "(outside wildcard)" otherwise
-- SERVICE cell: drService or "(base)"; CERT cell: "Ready"/"pending"/"disabled"
-- empty input -> "(no domains)\n"
-- pad copied verbatim from Nagare.App.formatAppList (or EP-38's shared helper if present)
```

kubectl is *not* called here — these functions take `ByteString`/`Text` only. The cabal edit adds
the module to the library:

```diff
   exposed-modules:
     Nagare.App
     Nagare.App.Deployments
     Nagare.Build
     Nagare.Deploy
+    Nagare.Ops.Domains
     Nagare.Env.BuildArgs
```

The test group (added to `test/Spec.hs`, imported from `Nagare.Ops.Domains`) covers: decoding a
two-item `DomainMapping` list (host, service, ready extracted); a malformed body → `Left`; an empty
list → `Right []`; `dnsExpectationFor` for the apex, a one-label subdomain, and an unrelated domain;
`certStateFor` for ready / pending / no-match; and `formatDomainList` on a base row plus two app rows
compared with `@?=` to a golden string (including the `(no domains)` empty case).

**Acceptance:** `cd cli/nagarectl && cabal build && cabal test` passes with the new
`Nagare.Ops.Domains` test group present and green; the module is listed in `exposed-modules`.

### Milestone 2 — Wire `nagarectl domains list` with namespace selection and graceful TLS handling

**Scope:** Add the `domains` command group and its `list` subcommand to `cli/nagarectl/app/Main.hs`,
plus a small IO layer that runs the kubectl queries, resolves the base domain and public IP, and
assembles `[DomainRow]` for `Nagare.Ops.Domains.formatDomainList`. This milestone is where the only IO
lives.

Add the command constructor to the `Command` sum type (`app/Main.hs` ~line 233). Use a nested
command type so the group can grow:

```haskell
data Command
  = ...
  | DeploymentsLogs DepLogsOpts
  | Domains DomainsCommand            -- ^ EP-40: domains group

data DomainsCommand
  = DomainsList DomainsListOpts

data DomainsListOpts = DomainsListOpts
  { dloNamespace      :: !(Maybe String)  -- ^ -n/--namespace (default: personal)
  , dloAllNamespaces  :: !Bool            -- ^ --all-namespaces
  , dloBaseDomain     :: !(Maybe String)  -- ^ --base-domain override (like other commands)
  }
  deriving stock (Generic, Show)
```

Add the parsers near the other `*OptsParser`s (~line 460), reusing `namespaceOpt` (~line 405):

```haskell
domainsListOptsParser :: Parser DomainsListOpts
domainsListOptsParser =
  DomainsListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List domains across all namespaces")
    <*> baseDomainOpt   -- the same --base-domain optional strOption other commands use
```

Register the group in the top-level subparser (`opts`, ~line 549) — **append**, do not remove
existing commands (this is the shared Integration Point IP3 in EP-38's terms):

```diff
       subparser
         ( command "deploy" deployCmd
             <> command "site" siteCmd
             <> command "env" envCmd
             <> command "secret" secretCmd
             <> command "app" appCmd
             <> command "deployments" deploymentsCmd
+            <> command "domains" domainsCmd
         )
```

and define `domainsCmd` as a group following the `siteCmd`/`siteSubparser` precedent (~line 561):

```haskell
domainsCmd =
  info (domainsSubparser <**> helper)
       (fullDesc <> progDesc "Inspect platform domains, DNS expectation, and certificate readiness")
domainsSubparser =
  subparser
    ( command "list"
        (info (Domains . DomainsList <$> domainsListOptsParser <**> helper)
              (progDesc "List the base domain and per-app DomainMappings with DNS and cert state")) )
```

Add the dispatch arm to `main` (~line 786):

```haskell
    Domains (DomainsList o) -> runDomainsList o
```

Implement the IO handler `runDomainsList`. It (1) resolves the base domain and public IP, (2)
resolves the target namespaces, (3) queries `DomainMapping` and `Certificate` per namespace, (4)
assembles rows with `Nagare.Ops.Domains`, and (5) prints `formatDomainList`:

```haskell
runDomainsList :: DomainsListOpts -> IO ()
runDomainsList o = do
  base <- resolveBaseDomain (dloBaseDomain o)   -- Pulumi/ConfigMap via EP-38 if present, else fallback
  ip   <- resolvePublicIp                       -- Pulumi `publicIp` (EP-38 stackOutput) or "(unknown)"
  nss  <- if dloAllNamespaces o then listAppNamespaces else pure [appNamespace (dloNamespace o)]
  rows <- concat <$> traverse (domainRowsForNamespace base ip) nss
  TIO.putStr (formatDomainList (baseRow base ip : rows))
```

The base row is computed purely: `baseRow base ip = DomainRow base Nothing Nothing (UnderWildcard ip)
CertDisabled` (the apex has no per-app cert). Per namespace, run two read-only kubectl captures
mirroring `Nagare.App.appDomains` (capture stdout, `silenceStderr`, treat `ExitFailure` as "resource
absent"):

```haskell
domainRowsForNamespace :: Text -> Text -> Text -> IO [DomainRow]
domainRowsForNamespace base ip ns = do
  dms   <- kubeGetJson ["get", "domainmapping", "-n", T.unpack ns, "-o", "json"]
  certs <- kubeGetJson ["get", "certificate",   "-n", T.unpack ns, "-o", "json"]
  let mappings = either (const []) id (extractDomainMappings dms)
      readi    = either (const []) id (extractCertReadiness  certs) -- [] when TLS disabled/absent
  pure [ DomainRow (dmHost m) (dmService m) (dmReady m)
                   (dnsExpectationFor base ip (dmHost m))
                   (certStateFor readi (dmHost m))
       | m <- mappings ]
```

**Graceful TLS-disabled handling is the key behavior here.** When the `certificate` query returns a
non-zero exit (the CRD or resources absent) or an empty list, `readi` is `[]`, so `certStateFor`
yields `CertDisabled` for every row and the column prints `disabled` — never an error. This matches
the current bootstrap state where `external-domain-tls` is off and no `Certificate` objects exist.

`resolvePublicIp` reads the Pulumi `publicIp` output via `Nagare.Ops.Pulumi.stackOutput` if EP-38
is present; otherwise it shells `pulumi -C infra/pulumi stack output publicIp` (or returns
`"(unknown)"` if Pulumi is unavailable, so the command still runs). All gcloud/pulumi access targets
`tan-nb-exp` / `us-west1` / `us-west1-a` only, per the repo isolation policy.

**Acceptance:** `cabal build` succeeds; `nagarectl domains list --help` prints the `list` usage;
running `nagarectl domains list` against a cluster (or with kubectl absent) prints at least the base
row and never crashes on a missing `Certificate` CRD.

### Milestone 3 — Tests green, `--help` transcript captured, live run deferred

**Scope:** No new feature code. Confirm the whole suite is green, capture the `--help` transcript
into Concrete Steps, and mark the live cluster run as deferred (the pure parsers/formatters are the
contract; the IO is thin glue exercised by hand later).

Run `cd cli/nagarectl && cabal build && cabal test` and confirm `Nagare.Ops.Domains` tests pass within
the existing suite. Run `cabal run nagarectl -- domains list --help` and paste the output into
Concrete Steps. Tick the M3 checklist item with the date and the note "tests green + --help
transcript; live cluster run deferred."

**Acceptance:** `cabal test` green; a `domains list --help` transcript is recorded; Progress shows
M1–M3 done.


## Concrete Steps

All commands run from the repository root unless noted. Build and test from the CLI package:

```bash
cd cli/nagarectl && cabal build && cabal test
```

Expected tail of the test output (the new group appears alongside the existing ones):

```text
nagarectl
  ...
  Nagare.App:            OK
  Nagare.App.Deployments: OK
  Nagare.Ops.Domains:        OK
    extractDomainMappings decodes host/service/ready: OK
    extractDomainMappings malformed -> Left:          OK
    dnsExpectationFor apex / subdomain / outside:      OK
    certStateFor ready / pending / absent:             OK
    formatDomainList golden:                           OK

All N tests passed
```

Inspect the command surface:

```bash
cd cli/nagarectl && cabal run nagarectl -- domains list --help
```

Expected output shape:

```text
Usage: nagarectl domains list [-n|--namespace NS] [--all-namespaces]
                              [--base-domain DOMAIN]

  List the base domain and per-app DomainMappings with DNS and cert state

Available options:
  -n,--namespace NS        Kubernetes namespace (default: personal)
  --all-namespaces         List domains across all namespaces
  --base-domain DOMAIN     Override the platform base domain
  -h,--help                Show this help text
```

End-to-end transcript (against a reachable cluster, with an app that owns a DomainMapping):

```bash
nagarectl deploy                 # config maps app.nadeem.dev -> the "blog" Service
nagarectl domains list -n personal
```

Expected output shape:

```text
  DOMAIN                          SERVICE          DNS                              CERT
  apps.example.com               (base)           *.apps.example.com A -> 34.x.x.x  disabled
  app.nadeem.dev                 blog             *.apps.example.com A -> 34.x.x.x  disabled
```

With external-domain TLS enabled and a ready wildcard cert in the namespace, the `CERT` column reads
`Ready` (or `pending` while the ACME challenge is in flight). With no cluster reachable, the command
still prints the base row; the per-app rows are empty:

```text
  DOMAIN                          SERVICE          DNS                              CERT
  apps.example.com               (base)           *.apps.example.com A -> (unknown) disabled
```


## Validation and Acceptance

1. `cd cli/nagarectl && cabal build` succeeds with `Nagare.Ops.Domains` in `exposed-modules`.
2. `cd cli/nagarectl && cabal test` is green, and the output shows the `Nagare.Ops.Domains` test group
   passing (the `extractDomainMappings`, `dnsExpectationFor`, `certStateFor`, and `formatDomainList`
   cases listed in Concrete Steps).
3. `cabal run nagarectl -- domains list --help` prints the `list` usage with `-n/--namespace`,
   `--all-namespaces`, and `--base-domain` options.
4. `extractDomainMappings` on a representative `kubectl get domainmapping -o json` fixture returns
   the expected `(host, service, ready)` triples; on a malformed body it returns `Left`, never
   crashing (unit test with `@?=`).
5. `extractCertReadiness` on a `Certificate` list fixture returns the expected `(dnsName, ready)`
   pairs; on an empty/absent list it returns `Right []`, and `certStateFor [] domain == CertDisabled`
   (unit test) — proving the graceful TLS-disabled path.
6. `dnsExpectationFor base ip domain` returns `UnderWildcard ip` for the apex and a one-label
   subdomain of `base`, and `OutsideWildcard` for an unrelated domain (unit test).
7. `formatDomainList` produces the aligned `DOMAIN / SERVICE / DNS / CERT` table matching the golden
   string, and `(no domains)\n` for the empty case (unit test).
8. Behavioral (cluster) check: with a deployed app owning a `DomainMapping`, `nagarectl domains list`
   shows a base row plus one row per mapping, each with its owning Service and a `disabled` (TLS off)
   or `Ready`/`pending` (TLS on) cert state — and never errors when `Certificate` objects are absent.

If no cluster is reachable, items 8 (and the live parts of 3) are validated by unit tests on the pure
parsers/formatters; the live run is deferred.


## Idempotence and Recovery

`nagarectl domains list` is strictly **read-only**: it only issues `kubectl get … -o json` and reads
the base domain / public IP (a `pulumi … stack output` read or the fallback chain). It never patches,
applies, or deletes any resource, so it is safe to run any number of times, in any order, against any
cluster, with no side effects. Re-running it after a deploy simply reflects the new `DomainMapping`.

The implementation steps are likewise safe to repeat: adding the `Nagare.Ops.Domains` module, the cabal
`exposed-modules` line, the command wiring, and the test group are all additive edits to existing
files; re-running `cabal build`/`cabal test` is idempotent. The base-domain and public-IP resolvers
degrade gracefully (fallback domain, `(unknown)` IP) rather than failing when Pulumi or kubectl is
unavailable. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

This plan adds one library module, `Nagare.Ops.Domains` (`cli/nagarectl/src/Nagare/Ops/Domains.hs`), and
wires it into the executable `cli/nagarectl/app/Main.hs`. It depends on libraries already in the
`nagarectl` cabal package: `aeson` (decode `-o json`), `bytestring`, `text`, `vector` (walk
`.items`), `cradle` (shell `kubectl`), and `optparse-applicative` (the `domains`/`list` parsers).
No new build-dependency is required.

**Soft reuse of EP-38** (`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`).
If EP-38 has landed, reuse two of its helpers rather than re-deriving them: the base-domain resolver
backed by `Nagare.Ops.Pulumi.stackOutput` (which reads `pulumi -C infra/pulumi stack output
<name>` and cross-checks the `config-domain` ConfigMap) for both the base domain and the `publicIp`
target, and EP-38's shared aligned-table `pad` helper / formatter for column alignment. If EP-38 is
not present, resolve the base domain via the existing `resolveBaseDomain` fallback chain
(`app/Main.hs` ~line 1446: `--base-domain` → `$NAGARE_BASE_DOMAIN` → literal `apps.example.com`),
read `publicIp` by shelling Pulumi directly (or print `(unknown)`), and copy the `pad` helper
verbatim from `Nagare.App.formatAppList` (`cli/nagarectl/src/Nagare/App.hs` ~line 283:
`pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "`). EP-40 does not
use EP-38's probe-grading model.

Signatures that must exist at the end of M1 (in `Nagare.Ops.Domains`):

```haskell
data DomainRow
data DnsExpectation = UnderWildcard !Text | OutsideWildcard
data CertState      = CertReady | CertPending | CertDisabled
data DomainMapping  -- dmHost, dmService, dmReady

extractDomainMappings :: ByteString -> Either Text [DomainMapping]
extractCertReadiness  :: ByteString -> Either Text [(Text, Bool)]
dnsExpectationFor     :: Text -> Text -> Text -> DnsExpectation   -- baseDomain publicIp domain
certStateFor          :: [(Text, Bool)] -> Text -> CertState
formatDomainList      :: [DomainRow] -> Text
```

At the end of M2, `cli/nagarectl/app/Main.hs` additionally defines the `Domains DomainsCommand`
constructor (with `DomainsCommand = DomainsList DomainsListOpts`), the `domainsListOptsParser ::
Parser DomainsListOpts`, the `command "domains" domainsCmd` registration, and the
`runDomainsList :: DomainsListOpts -> IO ()` handler plus its `main` dispatch arm.

**Integration.** This is EP-40 of MasterPlan 8
(`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`). It shares the top-level
`subparser` block (Integration Point IP3) with EP-38
(`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`) and EP-39
(`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`): register
`command "domains" domainsCmd` by **appending** to that block in EP-38's style, never removing
other commands. EP-40 reuses EP-38's base-domain resolver and table `pad` helper when present, and
reuses `Nagare.App`'s `DomainMapping` JSON shape (`extractDomainsFor` family) as the model for its
own extractors. It is independent of EP-39's `doctor` health checks and of EP-41's cleanup
(`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`); operator-facing docs for
`domains list` are owned by EP-42
(`docs/plans/42-server-and-operations-ux-docs-and-runbook-integration.md`) and are out of scope
here.
