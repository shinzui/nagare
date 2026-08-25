---
id: 104
slug: upgrade-nagare-to-the-latest-shomei-and-en
title: "Upgrade nagare to the latest shomei and en"
kind: exec-plan
created_at: 2026-08-25T03:44:59Z
intention: "intention_01m0vgasdwe5qr63fr1tqhhts0"
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
---

# Upgrade nagare to the latest shomei and en

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare has an optional "auth plane": three services that together let a Nagare-hosted
website require a sign-in and an authorization grant before a visitor sees it. Those three
services are **shomei** (the authentication service — it owns users, passwords, passkeys,
sessions, and it mints signed JSON Web Tokens), **en** (the authorization service — it
stores relationship facts like "user alice is a viewer of app protected-hello.example.com"
and answers yes/no questions about them), and **nagare-access** (a small proxy written in
this repository that sits in front of a protected site, verifies the shomei token, asks en
for a decision, and then forwards the request to the real application).

shomei and en are developed in sibling repositories. Nagare consumes them in two ways: it
pins their Haskell libraries as Git dependencies so `nagare-access` can link against them,
and it builds container images from local checkouts of their source. Both of those pins are
now **120 commits (shomei) and 155 commits (en) behind**, and the intervening work contains
several deliberate breaking changes. The result today is that `nagare-access` cannot be
built against current shomei/en at all, and that the cluster manifests describe a shape of
those services that no longer exists — wrong health-probe URLs, a missing mandatory API key,
and HTTP paths that moved.

After this change a person can: build `nagare-access` against today's shomei and en with a
single `cabal build`; install the auth plane onto the local k3d cluster and watch all three
pods reach Ready; run `nagarectl access grant` and have en actually record the grant; sign
in to `protected-hello.<base-domain>` and be let through; and see `nagarectl access revoke`
take that access away. None of those work today.

The other half of the work is the schema story. Both shomei and en replaced **codd** (their
old database-migration tool) with **pg-migrate** (a different one), and shomei renamed all 28
of its migration files in the process. A migration tool records "which migrations has this
database already received" in a table keyed by the migration's *name*; renaming the files
therefore makes the old records meaningless, and swapping the tool means the new tool cannot
see the old records at all. Nagare additionally used to carry its own hand-copied duplicate
of en's SQL inside a Kubernetes ConfigMap. All of that is replaced here by a single rule:
the container image that runs the service also carries the migration executable that owns
that service's schema, and the databases are recreated from empty so each new ledger starts
clean.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: resolve the exact shomei and en commits to pin (must exist on `origin`), record
      them in the Decision Log, and capture the current build failure as a baseline.
      Completed 2026-08-25T04:34:44Z. The baseline was a successful old-pin build rather
      than a failure; that result and the remote-pin evidence are recorded below.
- [x] M1 (source adaptation): update the planned dependency closure and adapt the
      `nagare-access` **library** source to current shomei/en APIs. Completed
      2026-08-25T13:14:23Z.
- [x] M1 (dependency validation): pin the newly corrected en dependency commit once it is reachable on
      GitHub, remove the temporary downstream OpenAPI compatibility patch, and make
      `cabal build lib:nagare-access` pass. Completed 2026-08-25T13:17:54Z.
- [x] M2: make the `nagare-access` **test suite** compile and pass. Completed
      2026-08-25T13:27:32Z: all 100 focused tests pass, including the real Shomei JWT plus
      real En authorization path. The flake-isolated repetition reached dependency cloning
      but cannot clone the private `mori://shinzui/en` repository without credentials; this
      pre-existing infrastructure limitation is recorded under Surprises & Discoveries.
- [x] M3: teach `nagare-access` to send en's mandatory API key, with a new
      `NAGARE_ACCESS_EN_API_KEY` configuration variable. Completed
      2026-08-25T13:30:55Z: the configured bearer value and intentionally absent-header
      paths are covered by live HTTP tests; all 103 tests and `cabal build
      exe:nagare-access` pass.
- [x] M4: fix `nagarectl`'s hand-written en client (`cli/nagarectl/src/Nagare/Access/Grants.hs`)
      — new `/v1` paths, the bearer API key, and en's hand-written wire JSON. Completed
      2026-08-25T13:36:23Z: the CLI and all 374 tests pass; exact tuple/expand request bytes
      and union/intersection/exclusion decoding are pinned in `AccessGrantsSpec`.
- [x] M5: update the cluster manifests and the image build script — en API-key Secret and
      environment, shomei's moved health probes, a shomei migration Job, and a cabal-project
      tail that mirrors upstream's current dependency pins (no more codd). Completed
      2026-08-25T14:46:15Z: all manifests parse, all three production images build on
      `linux/arm64`, and the image builder now preserves its Cabal caches and retries
      transient registry downloads.
- [x] M6: recreate `shomei-db` and `en-db`, install the auth plane on the local cluster, and
      prove grant → sign-in → allow → revoke → deny end to end. Completed
      2026-08-25T14:55:59Z on a fresh `k3d-nagare-local` cluster: both migration Jobs and
      all three auth workloads reached Ready, Shomei signup and password sign-in succeeded,
      and the protected example produced 302 → 403 → 200 → 403 across the grant lifecycle.
- [ ] M7: update `docs/user/access.md`, the two bootstrap READMEs, and distil durable
      findings into ADRs.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: the old-pin baseline still builds cleanly; incompatibility begins when the
  dependency pins move, not because the existing checkout has already stopped compiling.
  Evidence: `cabal build lib:nagare-access` from `cli/nagare-access` exited 0 on
  2026-08-25 after resolving shomei `af09ace`, en `d27bb44`, codd `c32d365`, and the old
  Git-pinned `ephemeral-pg`. This is the before-state against which M1 is compared.

- Observation: en at remote commit `c213e2b` and shomei at `26361f2` have no common
  unmodified OpenAPI dependency pair. Hackage/fork OpenAPI 5.0 with servant-openapi-hs 5.1
  compiles shomei but en imports the pre-5.0 ordered-map type; en's 4.1 fork pair compiles en
  but shomei needs the newer MultiVerb class kind. Evidence: the 5.0 build failed in
  `En.Servant.OpenApi` with `InsOrdHashMap` versus `InsOrdHashMap.Compat`; the 4.1 build
  reached `Shomei.Servant.OpenApi` and failed because `IsSwaggerResponseList` had the old
  kind.

- Observation: the en checkout now contains the upstream resolution at local commit
  `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634`: it imports
  `Data.HashMap.Strict.InsOrd.Compat`, consumes OpenAPI from Hackage, and pins the real
  `mori://shinzui/biscuit-haskell` fork at
  `8c0b3c5a13ce4a310737c0336f2ae167a1597588`. Both pins became remote-reachable on
  2026-08-25, and `cabal build lib:nagare-access` then exited 0 using Hackage
  `openapi-hs-5.0.0` and `servant-openapi-hs-5.1.0` without a downstream patch.

- Observation: current Shomei and En changed substantially more of the test-facing API than
  the original plan anticipated. Shomei's signup/login/session/MFA DTOs moved into
  concept-specific modules; signup now returns an `ApplicationResult (CookieResponse ...)`;
  token fields in response bodies are optional; the server fixture needs loaded signing keys,
  a key-encryption key, a TOTP key, Argon2 parameters, a hashing limiter, and separate liveness
  and readiness probes. En's `CheckResponseWire` includes `checkedAt`, and an embedded
  `En.Servant.Seam.Env` now reads an `ActiveSchema` snapshot and supplies lookup-subjects,
  watch, deadline, budget, and minting policy hooks. Evidence: after adapting those surfaces,
  `cabal test nagare-access-test --test-show-details=streaming` passed all 100 tests on
  2026-08-25, including both real HTTP integration cases.

- Observation: the flake's isolated `nagare-access-build-test` cannot clone En because
  `mori://shinzui/en` is private and the Nix builder has no GitHub credential helper. This is
  not caused by the new pin: the standalone Cabal plan has always fetched En from that private
  repository, and an anonymous `git ls-remote` fails while the same probe succeeds for the
  public Biscuit fork. Evidence: `nix build
  .#checks.aarch64-darwin.nagare-access-build-test` reached the Git clone phase on
  2026-08-25 and exited 128 with `could not read Username for 'https://github.com'`; the
  focused suite passes from the authenticated/warm developer checkout.

- Observation: Aeson's generic record encoding does not preserve En's reviewed golden field
  order. The first M4 exact-byte test encoded `ExpandRequestWire` fields and nested
  `ObjectRefWire` fields in key order rather than declaration order. Evidence: the focused
  test expected En's `consistency, object, permission, context, limit, cursor` order but saw
  `consistency, context, cursor, limit, object, permission`; replacing generic derivation
  with the same explicit `toEncoding` sequence as En made the byte-exact test pass.

- Observation: current Shomei cannot start with only its database and issuer/audience
  configuration. `buildEnv` unconditionally loads `SHOMEI_KEY_ENCRYPTION_KEY`, so the
  deployment needs a stable secret even when Nagare does not adopt Shomei's newly added
  capabilities. Evidence: the current source at `mori://shinzui/shomei` calls
  `loadKekFromEnv` while constructing the server environment; the M5 manifest now mounts
  `nagare-shomei-keys/key-encryption-key`, created once by both installers.

- Observation: local sibling checkouts can contain generated Unix sockets under `.dev/`
  and `db/`, which cannot be copied reliably into a Docker build context. Evidence: the
  first Shomei image attempt failed while `rsync` encountered `en/.dev/process-compose.sock`
  and PostgreSQL `.s.PGSQL.*` sockets; excluding generated development/database trees and
  socket names made all three `linux/arm64` images build.

- Observation: Hackage's selected DreamHost mirror can transiently reject a package that
  authoritative Hackage serves normally. Evidence: the first `nagare-access` image attempt
  compiled through TLS and then received HTTP 403 for `wai-app-static-3.2.1` from
  `objects-us-east-1.dream.io`; the authoritative Hackage URL returned HTTP 200 immediately.
  BuildKit-backed Cabal cache mounts plus bounded build retries made the second attempt pass
  and prevent a transient fetch from discarding the full compilation cache in future runs.

- Observation: a successful En relationship mutation is not immediately visible to an
  expand/list query because En publishes optimized revisions on an interval. Evidence: an
  immediate list after revoke still returned the subject, while the same command returned
  `(none)` after 12 seconds. End-to-end revocation additionally remained allowed until
  nagare-access's configured 30-second decision-cache TTL expired, then returned 403.

- Observation: a Ready local Knative DomainMapping can still appear unreachable when a
  workstation reverse proxy owns ports 80/443. Evidence: the mapping itself reported Ready,
  but direct curl reached the host's Caddy 404; forwarding `svc/kourier` to port 18080 and
  preserving the public `Host` header exercised the intended route and produced the full
  302 → 403 → 200 → 403 sequence. This is the documented local-development access path and
  did not require changing cluster state.

- Observation: the auth installers return as soon as their Deployment rollouts and
  migration Jobs finish, while the Knative nagare-access revision can take a few additional
  seconds to report Ready. Evidence: the fresh install briefly showed `RevisionMissing`,
  then converged without intervention; all service and proxy pods were Running before the
  behavioural checks began.


## Decision Log

Record every decision made while working on the plan.

- Decision: Recreate `shomei-db` and `en-db` from empty rather than migrating their existing
  contents onto the new pg-migrate ledgers.
  Rationale: confirmed with the repository owner on 2026-08-25 that the auth-plane databases
  on `nagare-01` hold no data that must survive. shomei renamed all 28 migration files and
  changed migration tools, and nagare's old en schema was applied by a hand-copied SQL
  ConfigMap that never wrote any ledger at all; adopting either existing database into a
  pg-migrate ledger would mean hand-seeding checksums, which pg-migrate's own contract (see
  en ADR 1, cited in Context and Orientation) explicitly forbids. Recreating is both smaller
  and safer. This decision is what keeps this plan out of the `cohort-migrate` territory of
  proving a remediation against a restored clone.
  Date: 2026-08-25

- Decision: Keep `nagarectl` free of the shomei/en Haskell dependency closure; fix its
  hand-written en HTTP client in place instead of switching it to the `en-client` library.
  Rationale: `cli/nagare-access/Dockerfile` and the separate `cli/nagare-access/cabal.project`
  exist specifically so the deploy CLI does not inherit that closure, which now includes a
  forked `biscuit-haskell`, Hackage OpenAPI libraries and a forked `webauthn`. Pulling
  `en-client` into `nagarectl` would drag all of that into every `nagarectl` build. The cost
  is that `nagarectl` must hand-encode en's wire JSON; M4 pins that with a byte-exact test so
  the duplication cannot drift silently again.
  Date: 2026-08-25

- Decision: This plan is a child of MasterPlan 19
  (`docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md`).
  Rationale: MasterPlan 19 owns platform-review remediation across security, reliability and
  operability, and its ExecPlan 100 (`docs/plans/100-bound-and-harden-cluster-workloads.md`)
  already began the auth-plane half of that work by replacing nagare's copied en SQL with
  en's own migration executable. This plan finishes what that started: it is remediation of
  the same surfaces (an unauthenticated authorization service, broken health probes, stale
  dependency pins), not new capability.
  Date: 2026-08-25

- Decision: Scope excludes adopting any of shomei's new capabilities — OpenID Connect,
  TOTP, service accounts, role permissions, token exchange, and en's Biscuit decision tokens,
  lookup-subjects, and watch feeds.
  Rationale: the request is an upgrade, not a feature adoption. Those surfaces are additive
  and cost nothing to leave unused. Adopting them would multiply the validation surface of an
  already large compatibility change. They remain available to a later plan.
  Date: 2026-08-25

- Decision: Pin shomei at `26361f21325f4c0d2d1751365542d6c0adc83839` and en at
  `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634`.
  Rationale: `git ls-remote --heads --tags` showed those exact commits at each repository's
  remote `master` ref on 2026-08-25. The en pin supersedes the initially selected `c213e2b`:
  it carries the compatible OpenAPI 5 import and switches en to the real
  `mori://shinzui/biscuit-haskell` fork, resolving the combined shomei/en dependency solve
  without a Nagare-owned source patch. Pinning the remote tips keeps builds reproducible
  from a fresh checkout.
  Date: 2026-08-25

- Decision: Store raw En bearer secrets in `nagare-en-api-keys`, then compose En's required
  `caller-name:secret` configuration strings in the Deployment environment while mounting
  only each raw secret into its caller.
  Rationale: En's server parser requires named entries such as `nagarectl:<secret>`, but its
  HTTP middleware compares the bearer credential to the secret portion alone. Keeping raw
  values in the Secret lets `nagarectl` receive the read-write bearer and `nagare-access`
  receive the read-only bearer without either caller learning or stripping an En-specific
  configuration prefix.
  Date: 2026-08-25


## Context and Orientation

### What lives where

You are working in the `nagare` repository at the root of this checkout. Three of its
directories matter here.

`cli/nagare-access/` is a Haskell package: the forward-auth proxy. "Forward auth" means the
proxy is placed in front of a real application; it inspects the incoming request, decides
whether the caller may proceed, and if so forwards ("proxies") the request onward. Its
source is in `cli/nagare-access/src/Nagare/Access/`, its entry point is
`cli/nagare-access/app/Main.hs`, and its tests are the single file
`cli/nagare-access/test/Spec.hs`. The four files that touch shomei and en directly are
`Shomei.hs` (verifies a token), `ShomeiClient.hs` (performs sign-in over HTTP), `En.hs`
(asks en for a decision), and `Jwks.hs` (fetches shomei's public keys).

`cli/nagare-access/cabal.project` is a **standalone build plan**: a file telling the Haskell
build tool `cabal` which packages make up this workspace and where to fetch each external
dependency. It deliberately does not include `nagarectl`, so the deploy CLI never inherits
the shomei/en dependency closure. It currently pins shomei at commit `af09acec` and en at
commit `d27bb440` by listing one `source-repository-package` stanza per sub-package.

`cli/nagarectl/` is the deploy CLI. One of its modules,
`cli/nagarectl/src/Nagare/Access/Grants.hs`, speaks to en over plain HTTP with hand-written
JSON encoders rather than linking en's client library — that is what backs
`nagarectl access grant`, `nagarectl access list`, and `nagarectl access revoke`.

`cluster/bootstrap/` holds the Kubernetes manifests. `shomei/service.yaml` and
`en/service.yaml` each declare a Deployment and a Service; `en/migrations.yaml` declares a
one-shot Job that applies en's schema; `nagare-access/service.yaml` declares a Knative
Service. `auth-install.sh` applies all of them for a cloud target and
`local-auth/install.sh` does the same for the local k3d cluster.
`render-context-template.sh` is a small `sed` wrapper that substitutes
`${NAGARE_REGISTRY_PREFIX}` and `${NAGARE_AUTH_TAG}` into those manifests before they are
applied. `auth-images/build-local-image.sh` builds all three container images from local
source checkouts; it writes a throwaway `cabal.project` into a temporary build context, and
that generated file — not `cli/nagare-access/cabal.project` — is what the images are built
with. Both must be updated, and they must agree.

The sibling checkouts this plan reads from are `/Users/shinzui/Keikaku/bokuno/shomei` and
`/Users/shinzui/Keikaku/bokuno/en`. The build script defaults to exactly those paths through
its `SHOMEI_SRC` and `EN_SRC` variables.

### Terms used throughout

A **migration** is a single `.sql` file that moves a database schema forward one step. A
**migration ledger** is a table the migration tool keeps inside the database recording which
migrations have already run; the tool consults it to apply only what is pending. **codd** and
**pg-migrate** are two different migration tools; both keep a ledger, but in different tables
with different keys, and neither can read the other's. pg-migrate stores a SHA-256 checksum
of each applied migration's exact bytes in a table `pgmigrate.migrations`, and its identity
for a migration is the string `component/name` — for example `en/0001-en-bootstrap`. **JWKS**
("JSON Web Key Set") is the document of public keys shomei publishes so that anything holding
one of its tokens can verify the signature without calling shomei. A **health probe** is a
URL Kubernetes polls to decide whether a container is alive and whether it should receive
traffic.

### Relevant ADRs

Nagare has no ADR corpus: there is no `docs/adr/` directory, and `mori show --full` reports
zero OKF bundles for `mori://shinzui/nagare`. So no local ADR governs this work, and this
plan is the primary written context for it. M7 creates nagare's first ADRs under a plain
`docs/adr/` directory, following the "preserve the repository's established filesystem
convention" branch of the skill's ADR workflow — nagare has no convention yet, so this plan
establishes the same plain-frontmatter shape en already uses, and does **not** invent OKF
metadata or Mori identity as an incidental edit.

Two cross-repository ADRs in the `en` project are directly relevant. `en`'s ADR corpus is a
plain `docs/adr/` directory and is not yet an OKF bundle, so it has no artifact-level
`mori://` URI; per this repository's cross-repository reference rule they are cited as the
canonical project URI plus the project-relative path, and the artifact-level URI is pending.

* `mori://shinzui/en` — `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`.
  en's schema is owned by pg-migrate as a component named `en`; the SQL is embedded into the
  binary at compile time from an ordered `manifest` file; `en-migrations/app/Main.hs` builds
  the `en-migrate` executable, which is *the only supported way to apply migrations*;
  `en-server` neither applies nor verifies migrations at startup. Crucially: **migrations are
  append-only, and a migration's identity is `component/name`** — editing an applied file or
  renaming it orphans every applied ledger row, and the forward path for a mistake is always
  a newly appended migration, never a hand correction of the ledger. This ADR is also the
  record that en's SQL was never really codd-managed: what applied it was a shell recipe that
  probed the live database, and nagare's `cluster/bootstrap/en/migrations.yaml` ConfigMap was
  a hand-copied second copy of that SQL which had already drifted.

* `mori://shinzui/en` — `docs/adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md`.
  pg-migrate computes its checksums with the cryptography library `crypton` at version 1.1 or
  newer; crypton 1.1 dropped the deprecated `memory` package in favour of `ram`. en's
  `biscuit-haskell` dependency caps crypton below 1.1 upstream, so en pins a fork that both
  widens the bound and performs the `memory` → `ram` swap. Relaxing the bound without the
  swap makes the dependency solver succeed and the compile then fail on a missing
  `ByteArrayAccess Ed25519.PublicKey` instance. This constrains the generated cabal projects
  in M1 and M5.

### What actually changed upstream, and what it breaks here

This is the load-bearing part of the plan. Everything below was verified by reading the
current source in the sibling checkouts on 2026-08-25; do not take it on faith if something
does not match, but do expect it to match.

**1. shomei's Haskell modules were reorganised, so four imports no longer resolve.** shomei
commits `994f947` (`refactor(core)!: organize authentication by concept`), `f06ad75`
(`refactor(http)!: organize servant API by concept`) and `bd07009` (`feat(api)!: adopt typed
MultiVerb results`) moved most of shomei's modules into concept-first paths. Of the modules
`nagare-access` imports, these four moved:

```text
Shomei.Domain.Claims      ->  Shomei.Authorization.Claims.Domain
Shomei.Jwt.Verify         ->  Shomei.SigningKey.Verify.Jwt
Shomei.Postgres.Pool      ->  Shomei.Persistence.Pool.Postgres
Shomei.Domain.SigningKey  ->  Shomei.SigningKey.Domain
```

`Shomei.Servant.DTO` did not move — it was **split**. The data types `nagare-access` uses now
live in `Shomei.Session.Dto` (`LoginRequest`, `LoginResponse` with its constructors
`LoginCompleteResponse` and `LoginMfaRequiredResponse`, `TokenPairResponse`, `RefreshRequest`)
and `Shomei.Mfa.Dto` (`MfaCompleteRequest`). These remain present and unchanged in shape:
`Shomei.Config` (with `ShomeiConfig` and `defaultShomeiConfig`), `Shomei.Error` (with
`TokenError` and its six constructors), `Shomei.Id`, `Shomei.Client`,
`Shomei.Migrations.TestSupport` (with `withShomeiMigratedDatabase`), `Shomei.Server.App`,
`Shomei.Server.Boot`, and `Shomei.Server.Keys` (with `bootstrapKeys`). `verifyToken` keeps
the signature `JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)`, and
`AuthClaims` still has a `subject` field, so `Nagare.Access.Shomei`'s logic survives an import
rewrite unchanged.

**2. shomei's client functions now return a rich result type instead of a bare response.**
Every shomei client call used to return `Either ClientError <response>`. It now returns
`Either ClientError (ApplicationResult (CookieResponse <response>))` for the session routes.
`ApplicationResult` is defined in `Shomei.Servant.Result` and re-exported from
`Shomei.Client`; it has ten constructors — `ApplicationSuccess`, `ApplicationBadRequest`,
`ApplicationAuthenticationFailed`, `ApplicationForbidden`, `ApplicationNotFound`,
`ApplicationConflict`, `ApplicationUnprocessable`, `ApplicationRateLimited`,
`ApplicationInternal`, `ApplicationUnavailable` — where every non-success arm carries an
RFC 7807 `ProblemDetails` value. `CookieResponse a` is a record with fields `cookieBody :: a`,
`sessionCookieHeader :: Maybe Text` and `refreshCookieHeader :: Maybe Text`. Concretely, the
three calls `Nagare.Access.ShomeiClient` makes now have these result types:

```haskell
login       :: ClientEnv -> LoginRequest       -> IO (Either ClientError (ApplicationResult (CookieResponse LoginResponse)))
refresh     :: ClientEnv -> RefreshRequest     -> IO (Either ClientError (ApplicationResult (CookieResponse TokenPairResponse)))
mfaComplete :: ClientEnv -> MfaCompleteRequest -> IO (Either ClientError (ApplicationResult (CookieResponse TokenPairResponse)))
```

This is genuinely better for nagare-access, which currently collapses every failure to the
string `"invalid login"`; M1 keeps that behaviour but M1's acceptance notes where the richer
information is now available.

**3. shomei's application routes moved under `/v1`, and its health probes moved.** shomei's
route record is now `application :: "v1" :> ...`, `oauth :: "oauth" :> ...`,
`wellKnown :: ".well-known" :> ...`, `health :: "health" :> ...`. `nagare-access` builds only
one shomei URL by hand — the JWKS URL in `cli/nagare-access/src/Nagare/Access/Jwks.hs`, which
appends `/.well-known/jwks.json`. That is still correct, because `.well-known` stayed at the
root. Everything else goes through the generated client, which carries `/v1` in the API type,
so no path constant needs changing in Haskell.

The manifests are a different story. shomei now mounts the third-party `servant-health`
package (Hackage, version 0.1.0.0) under the `health` segment, and that package serves
exactly two probe paths: **`/health/live`** and **`/health/ready`**.
`cluster/bootstrap/shomei/service.yaml` currently probes `/health` and `/ready`. Both now
return 404, so the shomei pod would never become Ready and the Deployment rollout would hang.
This is the single most likely thing to waste an afternoon if it is not fixed first.

**4. en now refuses to start without an API key, and every request must carry one.** en
commit `d6fee32` added mandatory caller authentication. `en-server` reads
`EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY`, each a comma-separated list of
`name:secret` pairs where the secret is at least 16 characters. With neither set and
`EN_AUTH_DISABLED` unset, the process **exits 1** with:

```text
No API keys configured; refusing to start an unauthenticated authorization service.
```

`cluster/bootstrap/en/service.yaml` sets neither. Callers present the secret as
`Authorization: Bearer <secret>`. This check runs as WAI middleware, *before* servant routing,
so it is not part of the API type — which means `en-client`'s generated functions do not take
a token parameter and the header must be attached at the HTTP-manager level instead. Both
`nagare-access` and `nagarectl` are callers and both must be taught to send it. Writes
(granting and revoking) need a read-write key; the proxy's checks need only a read-only key.

**5. en's routes moved under `/v1` and one verb changed.** en's route record mounts every
slice under `"v1"`. The three endpoints nagare uses are now:

```text
POST /v1/relationships          (write tuples — was POST /tuples)
POST /v1/relationships/delete   (delete tuples — was DELETE /tuples)
POST /v1/expand                 (expand a permission — was POST /expand)
POST /v1/check                  (the authorization decision the proxy asks for)
```

Deletion moved from `DELETE`-with-a-body to a `POST` deliberately: HTTP intermediaries may
drop a `DELETE` body, and the 405 servant raises does not consume the request body.
`nagare-access` reaches `/v1/check` through the generated `en-client`, so it needs no path
edit. `nagarectl` hand-builds all three of the others and needs all three fixed.

**6. en's client operations now return `EnResult`, not the bare response.** In
`en-client`, `check` used to be `CheckRequestWire -> ClientM CheckResponseWire`. It is now:

```haskell
check :: CheckRequestWire -> ClientM (EnResult CheckResponseWire)
```

`EnResult` (from `En.Servant.Response`, re-exported through `En.Servant.API` and
`En.Client`) has five constructors: `EnOk a`, `EnClientError !ErrorEnvelopeWire` (HTTP 400),
`EnPreconditionFailed !ErrorEnvelopeWire` (412), `EnUnprocessable !ErrorEnvelopeWire` (422),
and `EnUnavailable !ErrorEnvelopeWire` (503). An `ErrorEnvelopeWire` carries a stable `code`
and a `retryable` flag. Transport failures — connection refused, timeout, a rejected API key —
still arrive as `Left ClientError`. This directly invalidates the comment in
`cli/nagare-access/src/Nagare/Access/En.hs` above `authorizationFromClientResult`, which
asserts that "every `Left` here is transport-level ... because en expresses a genuine refusal
as `Right (CheckResponseWire DeniedWire)`". That is still true of `Left`, but `Right` is no
longer a bare response and must be destructured. Getting this wrong in the lenient direction
would turn an en outage into a silent *allow*, so M1 states the required mapping explicitly:
`EnOk` carries the real decision; every other `EnResult` constructor and every `Left` must map
to `AuthorizationUnavailable`, never to `AccessDenied` and never to `AccessAllowed`.

**7. en's wire JSON is now hand-written, so `nagarectl`'s generic encoders are wrong.** en
commit `0442a83` (`feat(en-servant): hand-write the wire JSON so constructor names stop
leaking`) replaced derived JSON instances with explicit ones. `nagarectl`'s
`Grants.hs` still derives its instances generically, which produces aeson's default
tagged-sum shape (`{"tag":"SubjectIdWire","contents":...}`). en now expects and emits:

```json
{"kind":"id","objectType":"user","objectId":"alice"}
{"kind":"set","objectType":"app","objectId":"h","relation":"viewer"}
{"kind":"wildcard","objectType":"user"}
{"mode":"minimizeLatency"}
{"mode":"atLeastAsFresh","token":"..."}
```

for `SubjectWire` and `ConsistencyWire` respectively. Separately, en commit `88e6de9`
(`feat(en-core): preserve set operators in expand trees`) added three constructors to
`ExpandNodeWire` — `ExpandUnionWire`, `ExpandIntersectionWire`, and `ExpandExclusionWire`
(granted children first, subtracted children second) — which `nagarectl`'s copy does not
know, and en's `ExpandTreeWire` gained a `checkedAt` field. `nagarectl access list` would
therefore fail to decode any non-trivial tree. The `kind` discriminators en uses for expand
nodes are read straight from `en-servant/src/En/Expand/Api.hs`; M4 says to copy them from
that file rather than guessing.

**8. Both projects replaced codd with pg-migrate, and shomei renamed all 28 migration
files.** shomei commit `78faeef` and en commit `b734f48`. shomei's migrations are now
`shomei-migrations/migrations/shomei/0001-shomei-schema.sql` through
`0028-shomei-role-permissions.sql`, listed in a plain-text `manifest`; en's is the single
`en-migrations/migrations/0001-en-bootstrap.sql`. Both are embedded into their binaries at
compile time. shomei gained a `shomei-migrate` executable (in the `shomei-migrations`
package) alongside the existing `shomei-admin migrate` subcommand, which still exists and now
delegates to pg-migrate — so shomei's container entrypoint
(`/Users/shinzui/Keikaku/bokuno/shomei/deploy/entrypoint.sh`, copied into nagare's image),
which runs `shomei-admin migrate` before exec'ing the server, is still correct. en, by ADR 1,
does not self-migrate: the separate `en-migrate up` Job is mandatory, which
`cluster/bootstrap/en/migrations.yaml` already does as of commit `6c5e8ba`.

Because both ledgers are new and keyed by names that never existed before, an existing
database gets no credit for the schema it already has: `pg-migrate` would try to apply
`0001` against tables that already exist and fail. Per the Decision Log this plan recreates
both databases rather than adopting them.

**9. Upstream's dependency pins changed shape, and the two projects now disagree.** This is
the subtlest risk in the plan, because `cli/nagare-access/cabal.project` and the generated
project inside `build-local-image.sh` must build shomei *and* en in one dependency solve,
while upstream builds each alone.

shomei's `cabal.project` today pins only the `shinzui/webauthn` fork
(`c274e23a5e31aac8932bac6398b65e8bca584a99`), with `allow-newer: webauthn:*` and a
`constraints: crypton-x509-validation >= 1.9.1` floor. That floor is security-relevant:
relaxing webauthn's bounds also removes its ceiling on `crypton-x509-validation`, and versions
before 1.9.1 do not enforce X.509 name constraints (CVE-2026-9648). **Carry that constraint
into every generated project that includes shomei.** shomei has dropped its codd, jose,
`ephemeral-pg`, `openapi-hs` and `servant-openapi-hs` pins — all now resolve from Hackage.
`shomei-servant.cabal` bounds them at `openapi-hs >=5.0 && <5.1` and
`servant-openapi-hs >=5.1 && <5.2`, and `shomei-migrations`'s public `test-support`
sub-library requires `ephemeral-pg >=0.2.2 && <0.3`.

en's `cabal.project` pins the real `shinzui/biscuit-haskell` fork at
`8c0b3c5a13ce4a310737c0336f2ae167a1597588` (subdir `biscuit`) and resolves OpenAPI from
Hackage. It also constrains `crypton >= 1.1` and — conflicting with shomei —
`ephemeral-pg ==0.2.1.0`.

Three consequences follow. First, `en-servant` now depends on `en-biscuit` and
`biscuit-haskell`, so **every generated project that includes `en-servant` must add the
package `en/en-biscuit` and the biscuit fork pin** — nagare's current script lists neither, and
`nagare-access` depends on `en-servant`. Second, the `ephemeral-pg` disagreement must be
resolved in nagare's favour: nagare does not build en's test suites, so drop en's
`ephemeral-pg` constraint and let shomei's `>=0.2.2` floor win. Third, both projects now
resolve `openapi-hs` 5.0.0 and `servant-openapi-hs` 5.1.0 from Hackage; the combined M1
build proves no Git OpenAPI fallback or bound relaxation is needed.

Verified on Hackage on 2026-08-25: `pg-migrate`, `pg-migrate-embed` and `pg-migrate-cli` are
all at `1.1.0.0`; `ephemeral-pg` at `0.2.2.0`; `openapi-hs` at `5.0.0`; `servant-openapi-hs`
at `5.1.0`; `jose` at `0.13`; `servant-health` at `0.1.0.0`. `codd` is **not** on Hackage,
which is exactly why nagare's build script copies a local checkout of it — a copy this plan
deletes.

**10. Pin only commits that exist on the remote.** `cabal` fetches a
`source-repository-package` from GitHub, not from the local checkout. As of 2026-08-25 the
shomei checkout is at `26361f21325f4c0d2d1751365542d6c0adc83839` and in sync with
`origin/master`. The en checkout is at
`054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634` and in sync with `origin/master`. M0 exists to
verify this rather than let a `cabal build` fail deep into a container build with an
unhelpful message.

### Where this plan does not go

The live `nagare-01` cloud cluster is not touched by this plan. All validation happens
against the local k3d cluster (`NAGARE_MODE=local`), which is the supported testing path
described in `docs/user/local-development.md` and in this repository's `CLAUDE.md`. Rolling
the change out to a cloud context is a separate operational act, and M6's acceptance is what
would gate it.


## Plan of Work

### Milestone M0 — Resolve the pins and capture the baseline

Scope: no code changes. At the end of M0 the plan records two exact commit SHAs that are
known to exist on GitHub, and a captured transcript of today's failure so later milestones
can be compared against it.

The pins must exist on the remote because `cabal` clones from GitHub. Check both, and if the
en checkout is still ahead of its remote, either push it (if that is appropriate and the
owner agrees) or pin `origin/master`'s tip and note in the Decision Log which commits were
deliberately left out. Do not pin a local-only commit.

Then run the existing build once and save the error. It is expected to fail; the value is a
concrete before/after record for the Outcomes section.

Acceptance: two SHAs recorded in the Decision Log, each confirmed present by
`git ls-remote`; a short failure transcript pasted into Surprises & Discoveries.

### Milestone M1 — Repin, and make the nagare-access library compile

Scope: `cli/nagare-access/cabal.project`, `cli/nagare-access/src/Nagare/Access/Shomei.hs`,
`ShomeiClient.hs`, and `En.hs`. At the end of M1, `cabal build lib:nagare-access` succeeds
against current shomei and en. The test suite is deliberately left for M2 so that a compile
failure has one obvious cause at a time.

Rewrite `cabal.project` first. Update every `tag:` line for the nine shomei sub-packages and
the five en sub-packages to the M0 SHAs, and add a sixth en stanza for `en-biscuit`
(`subdir: en-biscuit`) because `en-servant` now depends on it. Delete the `codd` stanza and
its `package codd` block entirely — codd is gone from both projects and is not on Hackage.
Delete the `ephemeral-pg` Git pin; Hackage 0.2.2.0 supersedes it and shomei's `test-support`
requires at least that. Keep the `shinzui/webauthn` pin and its `allow-newer: webauthn:*`.
Add the biscuit fork pin from en's project file, and add the two constraints that fork and
pg-migrate imply: `crypton >= 1.1` and `crypton-x509-validation >= 1.9.1`. Keep
`constraints: time ==1.14` — it is nagare's own pin and unrelated to this change. Do not add
Git OpenAPI forks; let the solver take Hackage `openapi-hs` 5.0.0 and
`servant-openapi-hs` 5.1.0, which satisfy both projects' declarations. The M1 implementation
briefly exposed an incompatibility in an earlier en commit, but en `054afad` fixes the import
at source, so Nagare carries no downstream patch or relaxed OpenAPI bounds.

Then fix the three source files.

In `Shomei.hs`, change `import Shomei.Domain.Claims (Audience (..), Issuer (..))` and
`import Shomei.Domain.Claims qualified as Claims` to `Shomei.Authorization.Claims.Domain`,
and `import Shomei.Jwt.Verify (verifyToken)` to `import Shomei.SigningKey.Verify.Jwt
(verifyToken)`. Nothing else in that file changes: `verifyToken`'s signature, `TokenError`'s
six constructors, `defaultShomeiConfig`, and `AuthClaims`'s `subject` field are all unchanged.

In `ShomeiClient.hs`, replace `import Shomei.Servant.DTO qualified as DTO` with imports of
`Shomei.Session.Dto` (for `LoginRequest`, `LoginResponse`'s constructors, `TokenPairResponse`,
`RefreshRequest`) and `Shomei.Mfa.Dto` (for `MfaCompleteRequest`), and then unwrap the new
two-layer result. Each of the three functions now matches on `Either ClientError`, then on
`ApplicationResult`, then reaches through `CookieResponse`'s `cookieBody` field. Keep the
existing outward behaviour — any failure becomes `LoginFailed` with the same message — so
that M1 is a pure compatibility change and M6's end-to-end proof is not confounded by a
behaviour change. Do add a brief comment noting that the non-success `ApplicationResult`
constructors now carry `ProblemDetails` and that surfacing them is available future work.

In `En.hs`, handle `EnResult`. `authorizeWithEnClient` still calls `client.check`, but the
result type is now `Either ClientError (EnResult CheckResponseWire)`. Rewrite
`authorizationFromClientResult` to take that type and map it as follows, and rewrite the
comment above it to match, because the current comment is now false:

```haskell
authorizationFromClientResult :: Either ClientError (EnResult CheckResponseWire) -> AuthorizationResult
authorizationFromClientResult = \case
  Left transportError            -> AuthorizationUnavailable (Text.pack (show transportError))
  Right (EnOk response)          -> AuthorizationDecision (checkResponseToDecision response)
  Right (EnClientError envelope) -> AuthorizationUnavailable (envelopeMessage envelope)
  Right (EnPreconditionFailed e) -> AuthorizationUnavailable (envelopeMessage e)
  Right (EnUnprocessable e)      -> AuthorizationUnavailable (envelopeMessage e)
  Right (EnUnavailable e)        -> AuthorizationUnavailable (envelopeMessage e)
```

The safety property to preserve, and to state in the comment: a refusal by en is an
`EnOk` carrying `DeniedWire`; every *other* shape means en did not answer, and must become
`AuthorizationUnavailable` — which the proxy turns into a 503 — rather than an allow or a
deny. Write `envelopeMessage` as a small local helper that renders the envelope's stable
`code` and message; read `ErrorEnvelopeWire`'s field names from
`en-servant/src/En/Servant/Seam.hs` in the en checkout rather than guessing them.

Acceptance: from `cli/nagare-access`, `cabal build lib:nagare-access` exits 0.

### Milestone M2 — Make the test suite compile and pass

Scope: `cli/nagare-access/test/Spec.hs` and `cli/nagare-access/nagare-access.cabal`. At the
end of M2, `cabal test nagare-access-test` is green, which matters because that suite starts
a real shomei server against an ephemeral PostgreSQL database migrated by shomei's own
pg-migrate plan — so a passing suite is the first real proof that the new migration path works.

`Spec.hs` imports both the moved shomei modules (`Shomei.Domain.Claims`,
`Shomei.Domain.SigningKey`, `Shomei.Postgres.Pool`, `Shomei.Servant.DTO`) and a set of en
modules that all still exist under their old names (`En.Client`, `En.Check`,
`En.Conformance.Kikan`, `En.Effect.ConsistencyStore`, `En.Effect.TupleStore`, `En.Error`,
`En.Lookup`, `En.Reachability`, `En.Schema`, `En.Schema.Builder`, `En.Servant.API`,
`En.Servant.Seam`, `En.Tuple`) — verified present in the current en checkout. So the shomei
imports need the same rewrites as M1 plus `Shomei.Domain.SigningKey` →
`Shomei.SigningKey.Domain` and `Shomei.Postgres.Pool` → `Shomei.Persistence.Pool.Postgres`,
and any assertion that pattern-matches a shomei client result or an en client result needs
the same unwrapping M1 introduced. Add `en-biscuit` to the test suite's `build-depends` only
if the compiler asks for it.

Expect the suite to surface at least one behavioural difference beyond types: any test that
asserts a specific HTTP status from shomei must account for commit `7a89950`
(`fix(servant)!: signup 201, synchronous confirms 200, idempotent logout`), and any test that
builds a shomei URL by hand must account for the `/v1` prefix. Record each such adjustment in
Surprises & Discoveries with the failing assertion, because those are exactly the
compatibility facts a future upgrade will want.

Acceptance: from `cli/nagare-access`, `cabal test nagare-access-test
--test-show-details=streaming` reports every test passing. Also run `nix build .#checks.<system>.nagare-access-build-test`
if the Nix toolchain is available locally, since that is what CI runs.

### Milestone M3 — Send en's API key from nagare-access

Scope: `cli/nagare-access/src/Nagare/Access/Config.hs` and `En.hs`. At the end of M3 the
proxy attaches `Authorization: Bearer <key>` to every en request, configured by a new
environment variable `NAGARE_ACCESS_EN_API_KEY`.

Because en enforces the key in WAI middleware ahead of servant routing, the generated client
functions take no token argument. The right seam is servant-client's `ClientEnv`, which
carries a `makeClientRequest` function; set it so that every outgoing request gains the
header. Do this inside `enClientEnvFromAuthPlane`, which already builds the `ClientEnv`, so
no call site changes.

Make the variable **required when set to nothing but non-fatal to omit only if en is
unauthenticated**: the honest default is to fail closed. Read it in `Config.hs` alongside the
existing `NAGARE_ACCESS_EN_URL`; if it is absent, the proxy should log a clear warning at
startup naming the variable and continue, because en itself will then reject the calls and
the proxy will correctly report `503` rather than allowing anyone through. State that
reasoning in a comment. Do not invent a default key value.

Acceptance: a unit test in `Spec.hs` that stands up a tiny WAI application asserting the
`Authorization` header is present and equals the configured value, and that no header is sent
when the variable is unset.

### Milestone M4 — Fix nagarectl's en client

Scope: `cli/nagarectl/src/Nagare/Access/Grants.hs`, plus a new test in `nagarectl`'s existing
test suite. At the end of M4, `nagarectl access grant`, `list` and `revoke` speak current en.

Four changes. Change the three paths to `/v1/relationships`, `/v1/relationships/delete` and
`/v1/expand`, and change the revoke call's method from `methodDelete` to `methodPost`. Add
the bearer header to `enRequest`, reading a key from a new `--en-api-key` option falling back
to `NAGARE_EN_API_KEY`, mirroring how `--en-url`/`NAGARE_EN_URL` already works in
`cli/nagarectl/app/Main.hs` around line 1022 and `resolveEnUrl` in `Grants.hs` around line
221. Replace the derived `ToJSON`/`FromJSON` instances for `SubjectWire`, `ConsistencyWire`,
`ExpandNodeWire` and `ExpandStateWire` with hand-written ones matching en's exactly — copy the
shapes from `en-servant/src/En/Servant/Wire.hs` and `en-servant/src/En/Expand/Api.hs` in the
en checkout, do not infer them. Extend `ExpandNodeWire` with `ExpandUnionWire`,
`ExpandIntersectionWire` and `ExpandExclusionWire`, extend `collectExpandedSubjects` to walk
all three (for exclusion, collect only the granted children — the first list — since a
subtracted subject does not have access), and add the `checkedAt` field to `ExpandTreeWire`.

Finally, note that responses are now `MultiVerb`-shaped: a 400/412/422/503 from en carries an
error envelope, not the response body `enRequest` tries to decode. Make `enRequest` check the
status code and report en's envelope message on a non-2xx rather than dying inside a JSON
decode with an unhelpful error.

Acceptance: a test that encodes one `accessTuple` and one `expandRequest` and compares the
produced JSON byte-for-byte against the expected shapes above; and a decode test that feeds
an expand tree containing a union node and an exclusion node and asserts the collected
subject list. This test is the guard that stops nagarectl's duplicate wire types drifting
from en again.

### Milestone M5 — Cluster manifests and the image build script

Scope: `cluster/bootstrap/shomei/service.yaml`, `cluster/bootstrap/en/service.yaml`, a new
`cluster/bootstrap/shomei/migrations.yaml`, `cluster/bootstrap/auth-install.sh`,
`cluster/bootstrap/local-auth/install.sh`, `cluster/bootstrap/nagare-access/service.yaml`,
and `cluster/bootstrap/auth-images/build-local-image.sh`. At the end of M5 the manifests
describe services that actually exist and the images can be built.

Fix shomei's probes first: `readinessProbe` to `/health/ready` and `livenessProbe` to
`/health/live`, with a comment naming `servant-health` as the reason. Leave en's `/readyz`
and `/healthz` alone — those are en's own hand-rolled probes and are unchanged.

Give en its API keys. Add a Secret named `nagare-en-api-keys` in `nagare-system` with two
keys — one read-write for `nagarectl`, one read-only for `nagare-access` — created
imperatively by both install scripts (`openssl rand -base64 32`, guarded by a
`kubectl get secret ... || create` so re-running is safe), exactly as
`local-auth/install.sh` already does for the `nagare-access` cookie key. Then in
`en/service.yaml` add `EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY` as
`secretKeyRef`s in the `name:secret` form en expects, and in `nagare-access/service.yaml` add
`NAGARE_ACCESS_EN_API_KEY` sourced from the read-only entry. Do not commit any generated
secret value.

Note carefully: `local-auth/install.sh` patches the nagare-access Knative Service by
**numeric env index** (`/spec/template/spec/containers/0/env/5/value` for the cookie domain).
Adding an environment variable to `nagare-access/service.yaml` before index 5 silently
retargets that patch to the wrong variable. Append the new variable at the end of the list,
and add a comment at both sites recording the coupling.

Add `cluster/bootstrap/shomei/migrations.yaml`, a Job modelled directly on
`en/migrations.yaml` — same namespace, labels, `securityContext`, resource bounds and Secret
references — running `/usr/local/bin/shomei-migrate up` from the same image tag as the
server, with `PG*` variables from `nagare-db-shomei-db`. shomei's entrypoint already migrates
on start, so this Job is not strictly required; it is worth adding anyway because it makes
the migration an explicit, observable deployment step with its own logs and exit status
rather than something buried in a container's first seconds, and because it matches how en is
already handled. Wire it into both install scripts with the same delete-then-apply-then-wait
sequence `auth-install.sh` already uses for `en-migrate`, and preserve the comment explaining
why the Job is deleted first (a Job's pod template is immutable and a completed Job never
re-runs).

Then rewrite `build-local-image.sh`'s generated cabal projects to mirror upstream. Delete
`CODD_SRC`, its `required_sources` entry, its `copy_tree` call, the `deps/codd` package line
and the `package codd` block, and remove codd from the usage text. In the common tail, drop
the `sumo/hs-jose`, `shinzui/servant-openapi` and `shinzui/openapi-hs` pins — shomei resolves
all three from Hackage now — and keep the `shinzui/webauthn` pin with `allow-newer:
webauthn:*`, adding `constraints: crypton-x509-validation >= 1.9.1` and `crypton >= 1.1`. Add
`en/en-biscuit` to `write_en_packages` and the biscuit fork `source-repository-package` to the
en tail, since `en-servant` now needs it. For the `shomei` service, add `exe:shomei-migrate`
to `cabal_targets` and `cabal_binaries` so the migration Job has a binary to run. For the
`nagare-access` service, the generated project is the union of all of the above and resolves
the OpenAPI packages from Hackage exactly as the standalone M1 project does.

Acceptance: `cluster/bootstrap/auth-images/build-local-image.sh shomei` and `... en` and
`... nagare-access` each build successfully with `NAGARE_AUTH_PUSH=0`; `grep -ri codd
cluster/` returns nothing.

### Milestone M6 — Recreate the databases and prove it end to end

Scope: no source changes; this is the behavioural proof. At the end of M6 a person has
watched a real sign-in succeed against a real grant.

Recreate both databases so the new ledgers start clean, per the Decision Log. Then install
the auth plane on the local cluster, watch all three workloads reach Ready — which is the
first thing that would have failed on shomei's moved probes — and run the grant/sign-in/
revoke sequence from `docs/user/access.md`.

Acceptance is stated as observable behaviour in Validation and Acceptance below.

### Milestone M7 — Documentation and ADR distillation

Scope: `docs/user/access.md`, `cluster/bootstrap/shomei/README.md`,
`cluster/bootstrap/en/README.md`, and a new `docs/adr/` directory.

The two bootstrap READMEs both still describe the build script as assembling "a temporary
Docker context from the local Nagare, shomei, en, codd checkout, plus pinned public git
dependencies for jose, servant-openapi, openapi-hs" and both still mention `CODD_SRC`. Every
one of those clauses is now false. `docs/user/access.md` line 84 still says "en currently
expects its PostgreSQL..." and needs to describe the `en-migrate` and `shomei-migrate` Jobs
instead; the "Manage grants" section needs the new `NAGARE_EN_API_KEY`.

Then create `docs/adr/` with nagare's first two records, in the same plain-frontmatter shape
en uses (`title`, `status`, `date`, `authors`, `related`). The two durable facts that outlive
this plan are: (a) nagare consumes shomei and en as Git-pinned sources built into images from
local checkouts, and the generated cabal projects must mirror each upstream project's own
pins — including the security-relevant `crypton-x509-validation >= 1.9.1` floor; and (b) each
auth-plane service's schema is owned by that service's own embedded pg-migrate plan and
applied by a Job from the same image tag, so nagare never keeps a second copy of anyone's
SQL. Cite en's two ADRs from them using the canonical-project-URI-plus-path form used in
Context and Orientation.


## Concrete Steps

All commands below assume you have run `direnv allow` once at the repository root so the
active target context is exported, and that your working directory is
`/Users/shinzui/Keikaku/bokuno/nagare` unless a step says otherwise.

### M0

```bash
git -C /Users/shinzui/Keikaku/bokuno/shomei rev-parse HEAD
git -C /Users/shinzui/Keikaku/bokuno/shomei status -sb | head -1
git -C /Users/shinzui/Keikaku/bokuno/en rev-parse HEAD
git -C /Users/shinzui/Keikaku/bokuno/en status -sb | head -1
```

Expect something like:

```text
26361f21325f4c0d2d1751365542d6c0adc83839
## master...origin/master
054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634
## master...origin/master
```

`[ahead N]` means those commits are not on GitHub and cannot be pinned. Confirm the chosen
SHAs are fetchable before relying on them:

```bash
git ls-remote https://github.com/shinzui/shomei.git | grep -c "$SHOMEI_SHA" || echo "not on remote"
git ls-remote https://github.com/shinzui/en.git    | grep -c "$EN_SHA"     || echo "not on remote"
```

`git ls-remote` lists refs, not every commit, so a cleaner check is to fetch the SHA
directly into a scratch clone. Then capture the baseline failure:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-access
cabal build lib:nagare-access 2>&1 | tail -40
```

Expect failures naming `Shomei.Domain.Claims`, `Shomei.Jwt.Verify` and `Shomei.Servant.DTO`
as modules that could not be found once the pins are moved forward — before repinning it may
simply succeed against the old commits, which is itself the baseline worth recording.

### M1

Edit `cli/nagare-access/cabal.project`, then:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-access
cabal update
cabal build lib:nagare-access
```

A successful solve prints a plan that mentions `pg-migrate-1.1.0.0`, `openapi-hs-5.0.0`,
`servant-openapi-hs-5.1.0`, `servant-health-0.1.0.0` and `ephemeral-pg-0.2.2.0`.

### M2

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-access
cabal test nagare-access-test --test-show-details=streaming
```

This starts a real PostgreSQL through `ephemeral-pg` and migrates it with shomei's plan. A
green run is the first evidence the pg-migrate switch works end to end.

### M4

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build all && cabal test nagarectl-test --test-show-details=streaming
```

### M5

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
NAGARE_AUTH_PUSH=0 cluster/bootstrap/auth-images/build-local-image.sh shomei
NAGARE_AUTH_PUSH=0 cluster/bootstrap/auth-images/build-local-image.sh en
NAGARE_AUTH_PUSH=0 cluster/bootstrap/auth-images/build-local-image.sh nagare-access
grep -ri codd cluster/ docs/user/access.md || echo "no codd references remain"
```

Each build prints the image reference on its last line.

### M6

Select the local context, rebuild and push the three images to the local registry, recreate
the databases, and install:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nagarectl context use local           # or: export NAGARE_CONTEXT=local
nagarectl db delete shomei-db --namespace nagare-system --yes
nagarectl db delete en-db     --namespace nagare-system --yes
nagarectl db create postgres shomei-db --namespace nagare-system
nagarectl db create postgres en-db     --namespace nagare-system
for svc in shomei en nagare-access; do
  cluster/bootstrap/auth-images/build-local-image.sh "$svc"
done
cluster/bootstrap/local-auth/install.sh
```

Then confirm the plane is healthy:

```bash
kubectl -n nagare-system get pods -l app.kubernetes.io/part-of=nagare-auth-plane
kubectl -n nagare-system logs job/shomei-migrate
kubectl -n nagare-system logs job/en-migrate
```

Expect both migration Jobs to report their applied counts (28 for shomei, 1 for en) and all
three workload pods to be `Running` and `READY 1/1`. Confirm the ledgers directly. A managed
database is a StatefulSet, and `nagarectl db shell` opens `psql` inside it:

```bash
nagarectl db shell shomei-db --namespace nagare-system
# then, at the psql prompt:
#   SELECT count(*) FROM pgmigrate.migrations WHERE status = 'applied';
```

Expect `28`. The equivalent against `en-db` should print `1`. If `db shell` is unavailable in
your environment, the same query runs through
`kubectl -n nagare-system exec statefulset/shomei-db -- psql ...`.


## Validation and Acceptance

Acceptance for this plan is behavioural. Six things must be observable, in this order.

**1. The proxy builds against current shomei and en.** From `cli/nagare-access`,
`cabal build all` exits 0. Before this plan it cannot: the shomei modules it imports no longer
exist under those names.

**2. The test suite passes, including a real migrated database.** From `cli/nagare-access`,
`cabal test nagare-access-test --test-show-details=streaming` reports every case passing. This
suite provisions PostgreSQL through `ephemeral-pg` and applies shomei's pg-migrate plan to it,
so it fails loudly if the migration switch is wrong.

**3. Every auth-plane pod reaches Ready.** After `cluster/bootstrap/local-auth/install.sh`,
`kubectl -n nagare-system get pods -l app.kubernetes.io/part-of=nagare-auth-plane` shows all
three as `1/1 Running`. Specifically, `kubectl -n nagare-system describe pod -l
app.kubernetes.io/name=shomei` must show **no** `Readiness probe failed: HTTP probe failed
with statuscode: 404` events — that 404 is exactly what the un-fixed `/ready` path produces,
and it is the sharpest single test of the probe-path change.

**4. en refuses unauthenticated callers and accepts authenticated ones.** Port-forward en and
show both halves:

```bash
kubectl -n nagare-system port-forward svc/en 8090:80 &
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8090/v1/check \
  -H 'Content-Type: application/json' -d '{}'
# 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8090/v1/check \
  -H "Authorization: Bearer $EN_READ_ONLY_KEY" \
  -H 'Content-Type: application/json' -d '{}'
# 400   (authenticated, and the empty body is now the only complaint)
```

The first line proves the API key is enforced; the second proves the key we provisioned is
the one en accepts, and that the route really is `/v1/check`.

**5. Grants round-trip through nagarectl.** With `NAGARE_EN_URL` and `NAGARE_EN_API_KEY` set:

```bash
nagarectl access grant  --host protected-hello.<base> --user alice
nagarectl access list   --host protected-hello.<base>
nagarectl access revoke --host protected-hello.<base> --user alice
nagarectl access list   --host protected-hello.<base>
```

The first `list` must print `alice`; the second must print `(none)`. Before this plan the
grant fails outright — wrong path, no API key, and a request body en cannot parse.

**6. A protected site actually enforces access.** Deploy the `cluster/examples/protected-hello`
application, then:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://protected-hello.<base>/
# 302 https://protected-hello.<base>/_nagare/login?rd=%2F
```

Sign in through that login page as a shomei user with no grant and confirm the site returns
`403`. Grant that user access with `nagarectl access grant`, wait out the 30-second decision
cache, reload, and confirm the application's own page renders. Revoke, wait 30 seconds, and
confirm `403` returns. That full cycle exercises every surface this plan touched: shomei's
`/v1` sign-in through the regenerated client, the JWKS fetch at `.well-known`, en's
API-key-protected `/v1/check` returning an `EnResult`, and nagarectl's rewritten wire JSON.

Finally, confirm nothing regressed in the rest of the repository by running the Nix checks the
CI runs, if the toolchain is available:

```bash
nix flake check
```


## Idempotence and Recovery

Every step in this plan is safe to repeat.

`cabal build` and `cabal test` are pure re-runs. Editing `cabal.project` and rebuilding never
mutates anything outside `dist-newstyle/`; if a dependency solve goes wrong, `rm -rf
dist-newstyle` and rebuild.

`build-local-image.sh` assembles a fresh temporary context on every invocation and removes it
on exit through its `trap cleanup EXIT`, so a failed build leaves nothing behind. Running it
with `NAGARE_AUTH_PUSH=0` never touches a registry. Because images are tagged with the
repository's short Git SHA rather than a mutable tag, rebuilding the same commit produces the
same reference and re-applying the manifests is a no-op.

Both install scripts are idempotent by construction: the Secret creation is guarded by a
`kubectl get ... ||` test, `kubectl apply` is declarative, and each migration Job is deleted
before being re-applied precisely so a completed Job can be re-run. Re-running
`local-auth/install.sh` after a partial failure is the normal recovery path.

The one destructive step is M6's `nagarectl db delete`. It is destructive on purpose and it is
authorised by the Decision Log entry recording that these databases hold nothing that must
survive. Before running it, confirm you are on the intended context —
`nagarectl context show` — because the same command against a cloud context would delete real
databases. If a delete succeeds and the following create fails, simply re-run the create; the
migration Jobs will populate an empty database from scratch, which is the expected path.

To roll the whole change back: `git revert` the plan's commits, then re-run
`cluster/bootstrap/local-auth/install.sh`. Because the images are SHA-tagged, the reverted
manifests point at the previously built images and the plane returns to its prior state; the
databases would then need recreating again, which is the same cheap operation.


## Interfaces and Dependencies

At the end of M1, `cli/nagare-access/cabal.project` must pin shomei's nine sub-packages
(`shomei-core`, `shomei-jwt`, `shomei-webauthn`, `shomei-postgres`, `shomei-migrations`,
`shomei-servant`, `shomei-server`, `shomei-client`, and — through the test suite —
`shomei-migrations:test-support`) and en's six (`en-core`, `en-migrations`, `en-postgres`,
`en-servant`, `en-client`, and the newly required `en-biscuit`) at the M0 SHAs. It must pin
`https://github.com/shinzui/webauthn.git` at `c274e23a5e31aac8932bac6398b65e8bca584a99` and
`https://github.com/shinzui/biscuit-haskell.git` at
`8c0b3c5a13ce4a310737c0336f2ae167a1597588` (subdir `biscuit`). It must carry
`allow-newer: webauthn:*` and the constraints `crypton >= 1.1` and
`crypton-x509-validation >= 1.9.1`. It must contain no reference to `codd` and no
`ephemeral-pg` Git pin.

At the end of M1, these signatures must hold in `cli/nagare-access/src/Nagare/Access/`:

```haskell
-- Nagare.Access.Shomei
verifyShomeiCredential :: JWKSet -> AuthPlaneConfig -> Credential -> IO (Either AuthFailure AuthenticatedUser)

-- Nagare.Access.En
authorizationFromClientResult :: Either ClientError (EnResult CheckResponseWire) -> AuthorizationResult
authorizeWithEnClient :: EnClient -> ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult
```

with `EnResult` and `CheckResponseWire` imported from `En.Client` (which re-exports
`En.Servant.API`), and with the shomei imports being `Shomei.Config`,
`Shomei.Authorization.Claims.Domain`, `Shomei.Error`, `Shomei.Id`, and
`Shomei.SigningKey.Verify.Jwt`.

At the end of M3, `Nagare.Access.Config.AuthPlaneConfig` must carry a field for the en API
key (`Maybe Text`), populated from `NAGARE_ACCESS_EN_API_KEY`, and
`enClientEnvFromAuthPlane :: HC.Manager -> AuthPlaneConfig -> IO (Either Text ClientEnv)` must
return a `ClientEnv` whose `makeClientRequest` attaches `Authorization: Bearer <key>` when the
field is present.

At the end of M4, `Nagare.Access.Grants` in `nagarectl` must expose an `ExpandNodeWire` with
six constructors (`ExpandSubjectWire`, `ExpandUsersetWire`, `ExpandCaveatedWire`,
`ExpandUnionWire`, `ExpandIntersectionWire`, `ExpandExclusionWire`) and hand-written JSON
instances matching `en-servant`'s. Its `enRequest` must take an API key and a path under
`/v1`.

External packages this plan newly depends on, all from Hackage and all verified published on
2026-08-25: `pg-migrate` 1.1.0.0, `pg-migrate-embed` 1.1.0.0, `pg-migrate-cli` 1.1.0.0
(`mori://shinzui/pg-migrate`), `servant-health` 0.1.0.0 (`mori://shinzui/servant-health`),
`ephemeral-pg` 0.2.2.0, `openapi-hs` 5.0.0, `servant-openapi-hs` 5.1.0, and `jose` 0.13.
Packages this plan removes: `codd` (`mori://mzabani/codd`), which is not on Hackage and whose
local checkout nagare was copying into every image build.

The upstream projects themselves are `mori://shinzui/shomei` and `mori://shinzui/en`; their
migration components are described by `mori://shinzui/shomei/packages/shomei-migrations` and
`mori://shinzui/en/packages/en-migrations`.
