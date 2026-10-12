---
id: 102
slug: nagarectl-correctness-and-robustness-fixes
title: "nagarectl correctness and robustness fixes"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
intention: "intention_01kzakvy1qeasagg3rpbn44749"
---

# nagarectl correctness and robustness fixes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [102-nagarectl-correctness-and-robustness-fixes.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/102-nagarectl-correctness-and-robustness-fixes.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagarectl` is the Haskell deploy CLI of this personal PaaS (it lives in
`cli/nagarectl`). A platform review found four correctness defects and one batch of
style debt in it. Each defect produces a real, user-visible failure:

1. **Managed-database passwords can break `DATABASE_URL`.** `nagarectl db create`
   generates passwords with `openssl rand -base64 24`. The base64 alphabet includes
   `+`, `/`, and `=`, and the password is spliced *raw* into
   `postgresql://user:PASSWORD@host:5432/db` (and the Redis/ClickHouse equivalents).
   Whenever the random draw contains one of those characters, the URL stored in the
   credential Secret misparses in most client libraries, so an app connected via
   `DATABASE_URL` fails to authenticate — intermittently, depending on luck of the
   draw. After this plan, generated passwords are URL-safe hex, *and* the URL
   composer percent-encodes the userinfo part regardless (defense in depth), so even
   a pre-existing hostile password produces a valid URL on an idempotent re-create.

2. **A service or worker that never becomes Ready crashes the deploy with a raw
   Haskell exception.** The readiness waits in `cli/nagarectl/src/Nagare/Deploy.hs`
   use `run_`, which throws on non-zero exit (for example when the 300-second
   `kubectl wait` times out). `nagarectl app deploy` calls them inside its phase
   runner with no handler, so instead of the intended clean
   `nagarectl app deploy: <reason>` message the user gets an uncaught cradle
   exception and a stack-trace-looking abort. After this plan, a failed readiness
   wait surfaces as a clean phase failure, exactly like a failed pre-deploy hook
   already does.

3. **The shared `nagare.dev/app` label can silently vanish.** `app deploy` stamps
   the app-identity label into every rendered manifest by text-munging YAML: it
   finds the line containing `nagare.dev/managed-by:` and splices a sibling line
   after it. If that anchor line is ever absent, the splice silently returns the
   manifest unchanged and the label — the contract the kotei backend reconciles
   on — is dropped without any warning. After this plan, stamping is verified
   structurally: the stamped manifest is parsed back and the label's presence at
   the object's top-level `metadata.labels` is asserted; a missing anchor or a
   mis-placed splice aborts the deploy loudly instead of corrupting the contract.

4. **Invalid UTF-8 in a Secret value crashes instead of erroring.** Two base64
   decoders use the partial `Data.Text.Encoding.decodeUtf8`, which throws on invalid
   UTF-8 bytes. After this plan they use the total `decodeUtf8'` and return a clean
   error message.

5. **House-style debt:** several `maybe x id` spellings are replaced with the
   standard `Data.Maybe.fromMaybe` (the house rule prefers standard base idioms —
   see the Decision Log for the exact scope).

How to see it working: after implementation, the unit test suite
(`cd cli/nagarectl && cabal test nagarectl-test`) contains tests proving that
`composeConnectionUrl` percent-encodes the hostile password `a+b/c=`, that a
manifest without the `managed-by` anchor makes stamping fail loudly, that a
non-zero readiness exit code becomes a `PhaseFailed` with a human message, and
that `b64decode` on non-UTF-8 bytes returns `Left` instead of throwing.

## Progress

- [x] M1: switch `generatePassword` to `openssl rand -hex 24` in
      `cli/nagarectl/src/Nagare/Database/Create.hs`.
- [x] M1: add `percentEncode` to `cli/nagarectl/src/Nagare/Database/Secret.hs` and
      apply it to the user and password in `composeConnectionUrl`.
- [x] M1: switch `b64decode` in `cli/nagarectl/src/Nagare/Database/Secret.hs` and
      `cli/nagarectl/src/Nagare/Env/Store.hs` to `TE.decodeUtf8'`.
- [x] M1: unit tests — hostile-password URL composition per engine, `percentEncode`
      character coverage, `b64decode` on invalid UTF-8; update the three existing
      `composeConnectionUrl` expectations if needed (plain passwords are unchanged).
- [x] M1: run `cabal build all` and `cabal test nagarectl-test` in `cli/nagarectl`;
      format with fourmolu; commit.
- [x] M2: change `waitForReady` / `waitForRollout` / `waitForWorkerRollout` in
      `cli/nagarectl/src/Nagare/Deploy.hs` to return `IO ExitCode` and add the
      `requireWait` helper for the non-app call sites.
- [x] M2: update all legacy callers (`app/Main.hs`, `Server/Deploy.hs`,
      `Static/Deploy.hs`, `Worker/Deploy.hs`, `Broker/Create.hs`,
      `Broker/Restart.hs`, `Database/Create.hs`, `Database/Restart.hs`) to
      `requireWait`-wrap the new exit-code-returning waits.
- [x] M2: add pure `waitResult` to `cli/nagarectl/src/Nagare/App/Deploy.hs`; make
      `applyServicePhase` / `applyWorkerPhase` return `IO PhaseResult` and convert
      wait exit codes into `PhaseFailed`.
- [x] M2: make `stampAppLabel` return `Either Text ByteString` with structural
      post-verification; thread the `Either` through `stamp`, `renderAppObjects`,
      `renderPlan`, and `runAppDeploy`.
- [x] M2: unit tests — `waitResult` conversion, `stampAppLabel` loud failure on a
      manifest without the anchor, structural verification of a stamped manifest,
      idempotent already-stamped case; adapt `test/AppDeploySpec.hs` to the new
      `Either` shape.
- [x] M2: build, test, format, commit.
- [x] M3: `fromMaybe` cleanup at `Target.hs:347`, `Target.hs:427`,
      `App/Deploy.hs:391` (plus the same-package incidental sites listed in the
      Plan of Work).
- [x] M3: full `cabal build all` + `cabal test nagarectl-test`, format, commit.
- [x] Final: update Progress, Surprises & Discoveries, Outcomes & Retrospective in
      this file; record evidence transcripts.

## Surprises & Discoveries

Recorded during plan authoring (verify again during implementation and append new
entries as they occur):

- The review cited style sites "App.hs:221,253,321". Grepping `cli/` shows those
  are in `cli/nagare-access/src/Nagare/Access/App.hs` — the forward-auth proxy
  package, which `docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md`
  owns. They are therefore **excluded** here (see Decision Log D5); the in-scope
  `maybe x id` sites are in `cli/nagarectl`.
- `readOrGeneratePassword` (`Database/Create.hs:170-181`) reuses an *existing*
  Secret's password on an idempotent re-create and then re-composes the URL. This
  means the percent-encoding fix (M1) does more than protect future passwords: a
  legacy database whose password contains `+` or `/` gets a *corrected*
  `DATABASE_URL` the next time `db create` runs against it.
- `cradle`'s `run` can capture a bare `ExitCode` without redirecting the child's
  stdout/stderr — the codebase already does this at
  `cli/nagarectl/src/Nagare/Static/Checkout.hs:52`
  (`code <- run (cmd "git" & addArgs args) :: IO ExitCode`) — so making the waits
  non-throwing does not hide `kubectl`'s live progress output.
- Mori has no registered local corpus project for `http-types`, so the exact
  `urlEncode` behavior was re-verified against the current authoritative Hackage
  documentation and in the repository's resolved build environment before M1.
- The library component already depended on `yaml`, but the test component did
  not expose it. M2's direct structural YAML assertion therefore required adding
  the existing package to the test suite's `build-depends`; no new package was
  introduced.

(Append implementation-time discoveries here.)

## Decision Log

- Decision D1: fix the password/URL defect with **both** URL-safe generation and
  percent-encoding, not one or the other.
  Rationale: hex generation (`openssl rand -hex 24`) fixes future passwords, but
  `composeConnectionUrl` is also re-run over passwords read back from existing
  Secrets (idempotent `db create`), and user-supplied or legacy passwords can
  contain reserved characters. Percent-encoding at composition is the only fix that
  covers every input; hex generation removes the sharp edge at the source. Existing
  deployed Secrets are untouched until a `db create` re-run (documented in M1).
  Date: 2026-07-16 (authoring).

- Decision D2: percent-encode with `Network.HTTP.Types.URI.urlEncode True` from
  `http-types`, which is already a `nagarectl` library dependency
  (`cli/nagarectl/nagarectl.cabal`, `build-depends: http-types`).
  Rationale: `urlEncode True` (query-string mode) escapes everything except the
  RFC 3986 unreserved set (`A-Z a-z 0-9 - _ . ~`), which is a strict superset of
  what the userinfo component requires — `+` becomes `%2B`, `/` becomes `%2F`,
  `=` becomes `%3D`, `:` becomes `%3A`, `@` becomes `%40`. `urlEncode False`
  (path-segment mode) would leave `+`, `:` and `@` raw, which is exactly wrong for
  a password. No new dependency is needed.
  Date: 2026-07-16 (authoring).

- Decision D3: fix the silent label drop with a **verified splice**, not by
  threading an extra-labels parameter through the `nagare-dsl` renderers.
  Rationale (the investigation the review asked for): rendering happens in
  `cli/nagare-dsl` — `Nagare.Dsl.Render.renderService` and its siblings build an
  Aeson `Value` and serialise it through `Data.Yaml.Pretty.encodePretty` with a
  *per-module* key-ordering comparator (`knativeConfig` / `keyCompare` at
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs:196-207`, with parallel copies in
  `Database/Render.hs`, `Worker/Render.hs`, `Server/Render.hs`, `Static/Render.hs`,
  `Broker/Render.hs`, `Batch/Render.hs`). A truly structural stamp would require
  either (a) adding a labels parameter to `renderService`, `renderWorker`,
  `renderDatabase`, `renderVolumeClaims`, `renderDomainMappings`, and
  `renderResolvedTask` — a cross-package signature change rippling through every
  single-workload deploy path that does *not* stamp an app label, plus golden-file
  churn in `nagare-dsl` — or (b) decode/re-encode in `nagarectl`, which cannot
  reproduce the per-kind key order and would break the documented byte-for-byte
  dry-run output. The least invasive layer that eliminates the *silent* failure is
  `stampAppLabel` itself: keep the byte-preserving splice, but return
  `Either Text ByteString`, fail when the anchor is absent, and *verify* the result
  structurally (parse the stamped YAML with `Data.Yaml.decodeEither'` and assert
  `metadata.labels."nagare.dev/app"` equals the app name at the top level). This
  also catches the latent first-match hazard where the first `managed-by:` line
  could belong to a nested pod template rather than the object's own metadata.
  Date: 2026-07-16 (authoring).

- Decision D4: readiness waits return `ExitCode`; conversion to a failure is the
  caller's job. Inside `app deploy` the conversion is the pure
  `waitResult :: Text -> ExitCode -> PhaseResult` (unit-testable, mirroring how
  `waitForJobComplete` + `runHooks` already handle hook failures at
  `cli/nagarectl/src/Nagare/App/Deploy.hs:461-495`). The eight *other* call sites
  (single-service deploy, worker deploy, static/server deploy, broker and database
  create/restart) wrap the wait in a new `requireWait` helper that prints one clean
  `nagarectl: ... did not become ready ...` line and exits non-zero — strictly
  better than today's raw cradle exception, without restructuring those commands
  around `PhaseResult`. One accepted limit: a database created *inside* the
  `app deploy` database phase (`ensureDatabase` → `runDbCreate` →
  `waitForRollout`) exits through `requireWait`/`dieT` rather than returning
  `PhaseFailed`, because `runDbCreate` is a self-contained command entry point;
  the user still gets a clean one-line error and a non-zero exit, and no later
  phase runs. Threading `PhaseResult` through `runDbCreate` is out of scope.
  Date: 2026-07-16 (authoring).

- Decision D5: style-cleanup scope. In scope: the `maybe x id` sites in
  `cli/nagarectl` modules this plan owns or that no sibling plan owns —
  `Target.hs:347`, `Target.hs:427`, `App/Deploy.hs:391`, plus the incidental
  same-package sites `Env/PreviewOverlay.hs:96`, `Cdn/Cloudflare.hs:215`,
  `Ops/Cleanup.hs:145`. Out of scope: (a) the review's
  `cli/nagare-access/src/Nagare/Access/App.hs:221,253,321` sites — that whole
  package is owned by `docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md`
  and must not be touched here; (b) `cli/nagarectl/src/Nagare/Ops/Status.hs:53` —
  owned by `docs/plans/101-alerting-and-backup-freshness-monitoring.md`; (c) the
  seven `rank k = maybe maxBound id (lookup k ranks)` copies in `nagare-dsl`
  renderers — zero-behavior churn across golden-covered modules this plan
  otherwise does not touch. For `either (const Nothing) Just`
  (`Target.hs:376`, `App/Deployments.hs:112`): base ships no `eitherToMaybe`, and
  the house rule ("prefer standard base idioms", cf. `Data.Bifunctor.first` over a
  hand-rolled `mapLeft`) cuts *against* both adding the `extra` package for one
  function and hand-rolling a `hush` helper — `either (const Nothing) Just` *is*
  the standard base spelling, so those sites stay as they are.
  Date: 2026-07-16 (authoring).

(Record every further decision here as work proceeds.)

## Outcomes & Retrospective

- M1 completed on 2026-08-24. New passwords are 48 lowercase hex characters;
  connection URL usernames and passwords are percent-encoded while the engine's
  raw Secret password key remains unchanged. Both base64 decoders now return
  `Left` for invalid UTF-8. `cabal build all` passed, and the post-format
  `nagarectl-test` run passed all 368 tests (five more than the EP-5 baseline).
- M2 completed on 2026-08-24. Readiness waits now return `ExitCode`; legacy
  commands fail with a one-line diagnostic, while app deploy converts service
  and worker timeouts into `PhaseFailed` and stops the rollout. Label stamping
  fails when its anchor is missing and verifies the resulting top-level label
  structurally. The build passed, all 372 tests passed, and the fixed-tag dry-run
  transcript remained byte-identical before and after the change.
- M3 completed on 2026-08-24. All six owned `maybe x id` sites now use
  `fromMaybe`; the only remaining match in `cli/nagarectl/src` is
  `Nagare.Ops.Status`, deliberately owned by EP-5. The final build and all 372
  tests pass. EP-6 delivered every behavior in the Purpose without modifying
  `nagare-dsl`, `nagare-access`, or the sibling-plan-owned status module.

