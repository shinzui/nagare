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

Full plan before trimming: [104-upgrade-nagare-to-the-latest-shomei-and-en.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

A post-completion refresh on 2026-08-27 moves Nagare to Shomei's official second release,
`release-2026-08-27` / package version `0.2.0.0`. This release fixes migration namespace
bugs by rewriting the existing 36-file history in place, so its checksums deliberately do
not match the earlier Shomei plan. Nagare has no retained auth-plane data, so the supported
Nagare upgrade is to discard and recreate only `shomei-db`; a deployment with data to
preserve must not copy that policy and instead needs operator-led ledger remediation.

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
- [x] M7: update `docs/user/access.md`, the auth bootstrap READMEs, and distil durable
      findings into ADRs. Completed 2026-08-25T15:02:44Z: the operator flow now names
      both migration Jobs and En credentials, all stale codd descriptions are gone from
      `cluster/`, and Nagare's first two ADRs record dependency-plan and schema ownership.
- [x] M8: refresh Shomei to its 2026-08-27 `0.2.0.0` release, adapt the new verifier and
      embedded-server test seams, and document the breaking migration reset. Completed
      2026-08-28T05:18:13Z: the authoritative release tag peels to `6a96185`, `cabal build
      all` succeeds, all 104 focused tests pass against a freshly migrated database, and
      the updated Shomei production image and all native `nix flake check` targets succeed
      on `aarch64-darwin`/`linux/arm64`.

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

- Observation: building the refreshed Shomei image for `linux/amd64` under emulation on the
  arm64 workstation exhausted Docker's available memory during dependency compilation; the
  same source built successfully for native `linux/arm64`, including `shomei-server`,
  `shomei-admin`, and `shomei-migrate`. This is a local cross-architecture resource limit,
  not a Shomei 0.2 source or migration-package failure.

- Observation: a successful En relationship mutation is not immediately visible to an
  expand/list query because En publishes optimized revisions on an interval. Evidence: an
  immediate list after revoke still returned the subject, while the same command returned
  `(none)` after 12 seconds. End-to-end revocation additionally remained allowed until
  nagare-access's configured 30-second decision-cache TTL expired, then returned 403.

- Observation: the workstation initially pointed at the cloud `sennari` context and had no
  saved local Nagare context, so the planned database delete was neither safe nor necessary.
  Evidence: the preflight context check stopped before any mutation, `just local-up` created
  a fresh `k3d-nagare-local` cluster, and `nagare-system` contained no databases to delete;
  creating `shomei-db` and `en-db` there still satisfied the clean-ledger decision without
  touching cloud state or the unrelated `kotei-dev` cluster.

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

- Observation: M7 originally named only the Shomei and En bootstrap READMEs, but the
  nagare-access and local-auth READMEs carried the same stale build-closure and one-Job
  descriptions. Evidence: the final documentation search found codd in
  `cluster/bootstrap/nagare-access/README.md` and found local-auth claiming it created only
  the cookie Secret and ran only `en-migrate`; updating all four bootstrap guides made the
  repository-wide search clean and aligned the operator path with the manifests.

- Observation: Shomei's second release intentionally rewrites all 36 published migration
  files to fix namespace leakage instead of appending corrective migrations. Evidence:
  `shomei-migrations` 0.2.0.0 states that every checksum differs from 0.1.0.0, so an existing
  ledger fails verification before any pending migration can run.

- Observation: the Shomei 0.2 server test seam grew with its security and operability work.
  `TokenError` adds `TokenKeyNotFound`; `acquirePool` adds a statement-timeout argument; and
  `Shomei.Server.App.Env` adds notifier secrets and a bounded notifier queue. Evidence: after
  adapting those surfaces, Nagare's real Shomei JWT plus En authorization test passes as one
  of 104 focused cases against Shomei's freshly applied 36-file plan.

- Observation: the host's bare GHC 9.10.3 cannot solve packages that require
  `MultilineStrings`, while Nagare's Nix shell supplies GHC 9.12.3 and builds the release.
  Evidence: bare `cabal build all` rejected `pg-migrate-cli-1.1.0.0`; the same build under
  `nix develop` completed with Shomei 0.2.0.0.

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

- Decision: For the initial 2026-08-25 upgrade, pin shomei at
  `26361f21325f4c0d2d1751365542d6c0adc83839` and en at
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

- Decision: Treat the generated Cabal projects in the local-source image builder as mirrors
  of the relevant Shomei and En dependency pins and compatibility constraints.
  Rationale: Nagare consumes those projects through both its standalone nagare-access plan
  and generated image plans. Letting the latter drift can select a different cryptographic
  closure or omit a reviewed fork even when the library build remains green. This durable
  rule is recorded in `docs/adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md`.
  Date: 2026-08-25

- Decision: Apply each auth service's embedded pg-migrate plan through an explicit Job from
  the exact same image tag as its server, and keep no Nagare-owned copy of upstream SQL.
  Rationale: one owner and one embedded plan prevent schema drift, while same-image Jobs
  provide observable ordering and provenance. Ledger checksums and advisory locking make
  the delete-and-recreate Job lifecycle idempotent. This durable rule is recorded in
  `docs/adr/0002-auth-service-images-own-and-apply-their-database-schemas.md`.
  Date: 2026-08-25

- Decision: Refresh only Shomei to commit
  `6a96185f4f809e5e7a99095274caa6bd90e7a8d7`, the commit peeled from the authoritative
  `release-2026-08-27` and `shomei-*-0.2.0.0` tags; retain En at its existing pin.
  Rationale: the release tags and GitHub remote agree on that exact commit, and an exact
  commit keeps Nagare's source-repository-package build reproducible even though
  `shomei-server`, `shomei-client`, and `shomei-webauthn` are not all published on Hackage.
  Date: 2026-08-27

- Decision: Treat Shomei 0.2.0.0 as a destructive reset boundary for Nagare's unused
  `shomei-db`, but do not make either installer delete the database automatically.
  Rationale: the release repairs bad migrations by changing already-ledgered SQL bytes, so
  checksum verification correctly blocks an in-place run. The repository owner confirmed
  Nagare has no data to preserve, making recreation the smallest safe path. Keeping deletion
  explicit prevents a routine installer rerun from destroying a future deployment that does
  have retained identities and sessions. ADR 2 records this qualified exception.
  Date: 2026-08-27

## Outcomes & Retrospective

The upgrade achieved its intended behaviour. After the 2026-08-27 refresh, Nagare-access
builds against Shomei `6a96185f4f809e5e7a99095274caa6bd90e7a8d7` (the official 0.2.0.0
release) and En `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634`; its 104 focused tests pass, and
nagarectl's 374 tests pass with the current En protocol pinned by exact wire fixtures. En
now rejects missing bearer credentials, nagare-access uses the read-only key, and nagarectl
uses the read-write key.

All three `linux/arm64` production images built successfully. On a fresh local cluster the
Shomei and En migration Jobs completed from those images, their ledgers contained 28 and 1
applied migrations respectively, both Deployments reached Ready, and the nagare-access
Knative revision converged to Ready. The protected example then demonstrated the full
contract: an unauthenticated document request returned 302, a signed-in ungranted user
received 403, a grant produced `Hello Nagare!` with status 200, and a revoke returned to 403
after the configured decision-cache TTL. En's relationship listing converged to `(none)`.
The M8 refresh separately rebuilt the Shomei `linux/arm64` image at the 0.2.0.0 pin,
including the rewritten 36-migration bundle.

The durable operational result is smaller than the code diff: each service image now owns
both its server and its schema executable, and Nagare carries neither copied SQL nor a codd
build path. ADRs 1 and 2 preserve that schema-ownership rule and the corresponding
dependency-plan maintenance obligation.

One repository-wide check remains constrained by existing infrastructure rather than this
upgrade: the isolated Nix `nagare-access-build-test` cannot clone the private
`mori://shinzui/en` repository without a credential helper. The authenticated focused build,
test suites, production image builds, and live cluster proof all pass. Cloud rollout was
explicitly outside this plan; the validated images remain deployed only to the disposable
local k3d cluster.

The refresh also makes the migration limitation explicit. Shomei's fixed, schema-qualified
36-file history is verified on an empty database by the focused suite, while operator docs
require Nagare's unused pre-0.2 `shomei-db` to be recreated. No installer performs an
implicit destructive reset, and no in-place preservation claim is made for a database with
real auth data.

