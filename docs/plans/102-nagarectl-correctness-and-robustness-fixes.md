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


## Context and Orientation

This repository ("nagare") is a personal PaaS targeting one configurable GCP
project (or a loopback-local substitute). The parts relevant here:

- `cli/nagarectl` — the Haskell deploy CLI. Library modules under
  `cli/nagarectl/src/`, the executable in `cli/nagarectl/app/Main.hs`, the test
  suite in `cli/nagarectl/test/` (tasty + HUnit, entry `test/Spec.hs`, plus
  `test/AppDeploySpec.hs` for the `app deploy` orchestration).
- `cli/nagare-dsl` — the sibling library holding the typed config model and the
  YAML manifest renderers. `nagarectl` builds against it via
  `cli/nagarectl/cabal.project` (`packages: . ../nagare-dsl`). **This plan does not
  modify `nagare-dsl`** (see Decision D3).
- `cli/nagare-access` — the forward-auth proxy. **Owned by
  `docs/plans/98-...md`; not touched here.**
- Formatting: `fourmolu` configured by `cli/fourmolu.yaml` (the pinned tool is in
  the flake dev shell: `nix develop` provides
  `haskell.packages.ghc912.fourmolu`). Note the flake deliberately has *no*
  format check (fourmolu 0.19 drifts from the tree), so format only the files you
  touch.
- CI: the flake checks in `flake.nix` run exactly
  `cabal build all` and `cabal test nagarectl-test --test-show-details=streaming`
  from `cli/nagarectl` (check `nagarectl-build-test`, `flake.nix` lines 63-73).
  Those are also the local validation commands.

Terms used below, in plain language:

- A **Knative Service** (`ksvc`) is the Kubernetes object that runs a
  request-driven web workload; `kubectl wait --for=condition=Ready ksvc/<name>`
  blocks until it serves traffic or a timeout expires.
- A **StatefulSet** / **Deployment** are Kubernetes objects for a database /
  background worker respectively; `kubectl rollout status <kind>/<name>` blocks
  the same way.
- The **managed credential Secret** is a Kubernetes Secret named
  `nagare-db-<name>` that `nagarectl db create` writes; its keys include the raw
  password (e.g. `POSTGRES_PASSWORD`) and a composed connection URL
  (e.g. `DATABASE_URL`) that apps consume verbatim.
- **cradle** is the shelling-out library used everywhere: `run_` runs a command
  and *throws* on non-zero exit; `run` returns whatever outputs you bind (an
  `ExitCode`, captured stdout, or a tuple) and does *not* throw on non-zero exit.
- A **rollout phase** is one step of `nagarectl app deploy`'s fixed order (hooks →
  databases → service → workers). `runPhases` (`App/Deploy.hs:185-193`) executes
  them and stops at the first `PhaseFailed`, whose message `liveDeploy`
  (`App/Deploy.hs:419-421`) prints as `nagarectl app deploy: <msg>`.
- The **kotei contract**: every object `app deploy` applies must carry the label
  `nagare.dev/app: <appname>` so the kotei backend can enumerate an app's
  resources (`RenderedObject` docs at `App/Deploy.hs:277-292`).

The five findings, located precisely (line numbers verified on this tree at
commit `28a67ef`):

**Finding 1 — password alphabet vs URL splicing.**
`cli/nagarectl/src/Nagare/Database/Create.hs:184-190`:

```haskell
generatePassword :: IO Text
generatePassword = do
  (code, StdoutRaw out) <-
    run $ cmd "openssl" & addArgs (["rand", "-base64", "24"] :: [String]) & silenceStderr
  case code of
    ExitSuccess -> pure (T.strip (TE.decodeUtf8 out))
    ExitFailure _ -> dieT "could not generate a password: 'openssl rand' failed"
```

and `cli/nagarectl/src/Nagare/Database/Secret.hs:67-73`:

```haskell
composeConnectionUrl :: Engine -> ConnectionParts -> Text
composeConnectionUrl Postgres p =
  "postgresql://" <> cpUser p <> ":" <> cpPassword p <> "@" <> cpHost p <> ":5432/" <> cpDb p
composeConnectionUrl Redis p =
  "redis://:" <> cpPassword p <> "@" <> cpHost p <> ":6379"
composeConnectionUrl ClickHouse p =
  "clickhouse://" <> cpUser p <> ":" <> cpPassword p <> "@" <> cpHost p <> ":9000"
```

A 24-byte base64 password contains `+` or `/` with high probability and always
ends in a padding-free 32-char string here (24 bytes → 32 chars, no `=`), but `+`
and `/` alone are enough to break URL parsing in libpq-style and Redis clients.
`secretKeysFor` (same file, lines 78-93) stores both the raw password key *and*
the composed URL, so only the URL needs encoding — the raw key must stay raw.

**Finding 2 — throwing readiness waits.**
`cli/nagarectl/src/Nagare/Deploy.hs:87-133` defines `waitForReady` (line 87),
`waitForRollout` (line 104), and `waitForWorkerRollout` (line 122), all shaped
like:

```haskell
waitForReady :: Text -> Text -> IO ()
waitForReady name namespace =
  run_ $
    cmd "kubectl"
      & addArgs ["wait", "--for=condition=Ready", "--timeout=300s", "ksvc/" <> T.unpack name, "-n", T.unpack namespace]
```

`run_` throws on the timeout's non-zero exit. `applyServicePhase` and
`applyWorkerPhase` (`cli/nagarectl/src/Nagare/App/Deploy.hs:518-528`) call them
under `runPhases` with no handler. Contrast the hook path, which is already
correct: `waitForJobComplete` (`App/Deploy.hs:481-495`) captures
`(code, _ :: StdoutUntrimmed) <- run ...` and `runHooks` (lines 461-478) turns a
non-zero code into `PhaseFailed`. All callers of the three waits (found by grep):
`app/Main.hs:2523,2719,2910`, `Server/Deploy.hs:92`, `Static/Deploy.hs:122,141`,
`Worker/Deploy.hs:110`, `Broker/Create.hs:110`, `Broker/Restart.hs:31`,
`Database/Create.hs:164`, `Database/Restart.hs:25`, `App/Deploy.hs:521,528`.

**Finding 3 — silent label splice.**
`cli/nagarectl/src/Nagare/App/Deploy.hs:262-272`:

```haskell
stampAppLabel :: Text -> ByteString -> ByteString
stampAppLabel appName bs
  | "nagare.dev/app:" `T.isInfixOf` text = bs
  | otherwise = TE.encodeUtf8 (T.unlines (insertAfterFirst (T.lines text)))
  where
    text = TE.decodeUtf8 bs
    insertAfterFirst [] = []
    insertAfterFirst (l : ls)
      | "nagare.dev/managed-by:" `T.isInfixOf` l =
          l : (T.takeWhile (== ' ') l <> "nagare.dev/app: " <> appName) : ls
      | otherwise = l : insertAfterFirst ls
```

If no line matches the anchor, `insertAfterFirst` returns the lines unchanged and
the label is dropped silently. The kotei backend reconciles on this label
(`App/Deploy.hs:277-292`), and `toRenderedObject` (`App/Deploy.hs:337-360`)
already re-parses each stamped manifest with `Data.Yaml.decodeEither'` — proof
that a structural post-check is cheap and idiomatic here. Today every
`nagare-dsl` renderer does emit `nagare.dev/managed-by: nagarectl`, so the bug is
latent — it fires the day a renderer changes, which is exactly why it must fail
loudly.

**Finding 4 — partial UTF-8 decode.**
`cli/nagarectl/src/Nagare/Database/Secret.hs:137-141` and
`cli/nagarectl/src/Nagare/Env/Store.hs:148-152`, both:

```haskell
b64decode :: Text -> Either Text Text
b64decode t =
  case convertFromBase Base64 (TE.encodeUtf8 t) :: Either String ByteString of
    Left e -> Left ("could not base64-decode secret value: " <> T.pack e)
    Right bs -> Right (TE.decodeUtf8 bs)
```

`TE.decodeUtf8` throws a `UnicodeException` on invalid bytes (a Secret can hold
arbitrary binary), even though the function already returns `Either Text Text`.

**Finding 5 — style sites** (see Decision D5 for scope): `maybe s id` at
`cli/nagarectl/src/Nagare/Target.hs:347`, `maybe Map.empty id` at
`Target.hs:427`, `maybe (tpBaseDomain tp) id` at
`cli/nagarectl/src/Nagare/App/Deploy.hs:391`, plus incidental
`Env/PreviewOverlay.hs:96`, `Cdn/Cloudflare.hs:215`, `Ops/Cleanup.hs:145`.
`Nagare.Dsl.Prelude` already re-exports `fromMaybe`
(`cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs:17`); `Target.hs` does *not* import
that prelude, so it needs `import Data.Maybe (fromMaybe)`.

Sibling-plan ownership (do not cross these lines):

- `docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md`
  owns `cli/nagarectl/nagared/Main.hs`, `cli/nagarectl/src/Nagare/Static/Webhook.hs`,
  all of `cli/nagare-access`, and the `Dsl/Load.hs` timeout.
- `docs/plans/101-alerting-and-backup-freshness-monitoring.md` owns
  `cli/nagarectl/src/Nagare/Ops/Status.hs`.
- This plan owns `cli/nagarectl/src/Nagare/Deploy.hs`,
  `cli/nagarectl/src/Nagare/App/Deploy.hs`, `cli/nagarectl/src/Nagare/Database/*`,
  `cli/nagarectl/src/Nagare/Env/Store.hs` (and would own any
  `Dsl/Render.hs` change for label stamping, but Decision D3 avoids one). If plan
  98 lands first there is no conflict — the module sets are disjoint.


## Plan of Work

The work is three milestones, each independently buildable, testable, and
committable. Commit messages follow Conventional Commits and carry the trailers

```text
MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/102-nagarectl-correctness-and-robustness-fixes.md
```

### Milestone 1 — URL-safe database credentials and total secret decoding

Scope: findings 1 and 4. At the end of this milestone, `nagarectl db create`
generates hex passwords, every composed connection URL percent-encodes its
userinfo, and both `b64decode` helpers are total. All new logic is pure and
unit-tested, matching the codebase's pure/IO separation.

In `cli/nagarectl/src/Nagare/Database/Create.hs`, change `generatePassword`
(lines 184-190) to run `openssl rand -hex 24` instead of
`openssl rand -base64 24`, and update its Haddock: 24 random bytes rendered as 48
lowercase hex characters — the same 192 bits of entropy, drawn from an alphabet
(`0-9a-f`) that is a subset of the RFC 3986 unreserved set, so it can never need
escaping anywhere a credential is spliced. (Hex was chosen over
base64url-minus-padding because `openssl rand -hex` produces it directly with no
post-processing; see Decision D1.)

In `cli/nagarectl/src/Nagare/Database/Secret.hs`, add a pure, exported helper:

```haskell
-- | Percent-encode a URL userinfo component (RFC 3986): every byte outside
-- the unreserved set (A-Z a-z 0-9 - _ . ~) becomes %XX. Uses http-types'
-- query-mode encoder, whose kept set is exactly the unreserved set.
percentEncode :: Text -> Text
percentEncode = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8
```

with `import Network.HTTP.Types.URI (urlEncode)` (the `TE.decodeUtf8` here is
safe: `urlEncode` output is pure ASCII). Then apply it to the userinfo in
`composeConnectionUrl` (lines 67-73): replace every `cpUser p` and `cpPassword p`
occurrence with `percentEncode (cpUser p)` / `percentEncode (cpPassword p)`. Do
*not* touch `cpHost` or `cpDb` (both are validated DNS/identifier names), and do
*not* touch `secretKeysFor` — the `POSTGRES_PASSWORD` / `REDIS_PASSWORD` /
`CLICKHOUSE_PASSWORD` keys must keep the raw password; only the URL embeds an
encoded copy. Export `percentEncode` from the module's export list so the test
suite can cover it directly.

Behavior note to preserve in the module Haddock: existing deployed Secrets are
not rewritten by this change — new generation affects only future `db create`
runs. On an idempotent re-create of an existing database,
`readOrGeneratePassword` reuses the stored raw password and the recomposed URL
now comes out percent-encoded (a strict correctness improvement; a legacy
password without reserved characters produces a byte-identical URL).

In both `cli/nagarectl/src/Nagare/Database/Secret.hs` (line 141) and
`cli/nagarectl/src/Nagare/Env/Store.hs` (line 152), replace the partial decode in
`b64decode`:

```haskell
    Right bs -> case TE.decodeUtf8' bs of
      Left _ -> Left "secret value is not valid UTF-8 after base64 decoding"
      Right txt -> Right txt
```

(`decodeUtf8'` is in the already-imported `Data.Text.Encoding`.)

Tests, in `cli/nagarectl/test/Spec.hs` inside the existing
`databaseTests` → `testGroup "Nagare.Database.Secret"` (around line 2402), which
already checks `composeConnectionUrl` against the benign password `pw` — those
three expectations stay byte-identical, which itself proves the encoding is a
no-op for safe passwords. Add cases using a hostile parts value
(`cpPassword = "a+b/c="`, and one with `cpUser = "us:er"`):

- Postgres URL equals
  `postgresql://nagare:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:5432/pg_main`.
- Redis URL equals `redis://:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:6379`.
- ClickHouse URL equals
  `clickhouse://nagare:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:9000`.
- `percentEncode "a+b/c=:@ ~"` equals `"a%2Bb%2Fc%3D%3A%40%20~"` (space encodes,
  tilde does not).
- `secretKeysFor Postgres hostileParts` still stores the *raw* password under
  `POSTGRES_PASSWORD` (lookup the pair and compare to `a+b/c=`).
- `b64decode` of base64-encoded invalid UTF-8 (e.g. `b64encode` cannot build it,
  so hard-code `"/w=="`, the base64 of the lone byte `0xFF`) is `Left` and does
  not throw — assert with `isLeft` (already imported in `Spec.hs`).

Acceptance: `cd cli/nagarectl && cabal build all && cabal test nagarectl-test
--test-show-details=streaming` passes with the new cases listed in the streaming
output. Commit as `fix(nagarectl): make managed-db credentials URL-safe and secret
decoding total` with the trailers above.

### Milestone 2 — clean phase failures and verified label stamping

Scope: findings 2 and 3. At the end of this milestone a readiness timeout in any
deploy path produces a one-line human error (and, inside `app deploy`, a proper
`PhaseFailed` that stops later phases), and a manifest that cannot be stamped
with `nagare.dev/app` aborts the deploy loudly.

First, `cli/nagarectl/src/Nagare/Deploy.hs`. Change the three waits (lines
87-133) from `IO ()` to `IO ExitCode` by swapping `run_` for `run` with a bare
exit-code binding, keeping the child's output streaming to the terminal exactly
as today (the codebase precedent is `Static/Checkout.hs:52`):

```haskell
waitForReady :: Text -> Text -> IO ExitCode
waitForReady name namespace =
  run $
    cmd "kubectl"
      & addArgs
        [ "wait"
        , "--for=condition=Ready"
        , "--timeout=300s"
        , "ksvc/" <> T.unpack name
        , "-n"
        , T.unpack namespace
        ]
```

(and the parallel edits to `waitForRollout` and `waitForWorkerRollout`). Add and
export a small helper for the legacy call sites:

```haskell
-- | Exit with a clean one-line error when a readiness wait failed. @what@ is a
-- human description like "service 'foo'" or "statefulset 'pg-main'".
requireWait :: Text -> ExitCode -> IO ()
requireWait _ ExitSuccess = pure ()
requireWait what (ExitFailure c) = do
  TIO.hPutStrLn stderr ("nagarectl: " <> what <> " did not become ready within the timeout (kubectl exited " <> T.pack (show c) <> ")")
  exitFailure
```

(add the `Data.Text.IO qualified as TIO`, `System.IO (stderr)`, and
`System.Exit (exitFailure)` imports this needs; `ExitCode` is already imported).
Update every non-app caller to `waitFor... >>= requireWait "<description>"`:
`app/Main.hs:2523,2719,2910` (single-service deploys), `Server/Deploy.hs:92`,
`Static/Deploy.hs:122,141`, `Worker/Deploy.hs:110`, `Broker/Create.hs:110`,
`Broker/Restart.hs:31`, `Database/Create.hs:164`, `Database/Restart.hs:25`. Each
becomes for example:

```haskell
waitForRollout ns (statefulSetName name) >>= requireWait ("database '" <> name <> "'")
```

This is behaviorally identical on success and strictly better on failure (clean
message + non-zero exit instead of a raw cradle exception).

Second, `cli/nagarectl/src/Nagare/App/Deploy.hs`. Add a pure, exported
conversion mirroring the hook path:

```haskell
-- | Convert a readiness wait's exit code into a phase result, mirroring how
-- 'runHooks' converts 'waitForJobComplete' exit codes.
waitResult :: Text -> ExitCode -> PhaseResult
waitResult _ ExitSuccess = PhaseOk
waitResult what (ExitFailure c) =
  PhaseFailed (what <> " did not become Ready within the 300s timeout (kubectl wait exited " <> T.pack (show c) <> ")")
```

Change `applyServicePhase` and `applyWorkerPhase` (lines 518-528) to return
`IO PhaseResult`:

```haskell
applyServicePhase :: RolloutEnv -> Deployment -> IO PhaseResult
applyServicePhase env svc = do
  applyManifests (map snd (renderServiceObjects env svc))
  code <- waitForReady (serviceNameText (svc ^. #name)) (reNamespace env)
  case waitResult ("service '" <> serviceNameText (svc ^. #name) <> "'") code of
    PhaseOk -> resolveDeploymentAccess (reBaseDomain env) svc >> pure PhaseOk
    failed -> pure failed

applyWorkerPhase :: RolloutEnv -> Worker -> IO PhaseResult
applyWorkerPhase env w = do
  applyManifests (map snd (renderWorkerObjects env w))
  code <- waitForWorkerRollout (reNamespace env) (serviceNameText (w ^. #name))
  pure (waitResult ("worker '" <> serviceNameText (w ^. #name) <> "'") code)
```

and update `livePhaseExec` (lines 450-455) so the service phase returns the
result directly and the workers phase stops at the first failure (the same `go`
shape `runHooks` uses):

```haskell
livePhaseExec :: RolloutEnv -> PhaseExec
livePhaseExec env = \case
  PhaseHooks ts -> runHooks env ts
  PhaseDatabases dbs -> mapM_ (ensureDatabase env) dbs >> pure PhaseOk
  PhaseService svc -> applyServicePhase env svc
  PhaseWorkers ws -> go ws
  where
    go [] = pure PhaseOk
    go (w : rest) = do
      r <- applyWorkerPhase env w
      case r of
        PhaseOk -> go rest
        failed -> pure failed
```

(The database phase keeps its current shape; a rollout timeout inside
`runDbCreate` now exits through `requireWait` with a clean message — Decision D4.
Note the `renderServiceObjects`/`renderWorkerObjects` calls above pick up the
`Either` threading below, so in the final code they appear inside the
`Either`-aware plumbing described next.)

Third, still in `App/Deploy.hs`, the verified stamp. Change `stampAppLabel`
(lines 262-272) to:

```haskell
stampAppLabel :: Text -> ByteString -> Either Text ByteString
stampAppLabel appName bs
  | "nagare.dev/app:" `T.isInfixOf` text = Right bs
  | not ("nagare.dev/managed-by:" `T.isInfixOf` text) =
      Left (describe bs <> " has no 'nagare.dev/managed-by:' anchor to stamp nagare.dev/app after")
  | otherwise = verify (TE.encodeUtf8 (T.unlines (insertAfterFirst (T.lines text))))
  where
    text = TE.decodeUtf8 bs
    insertAfterFirst = ...  -- unchanged
    verify stamped = ...    -- parse stamped YAML; Right stamped only when
                            -- metadata.labels."nagare.dev/app" == appName
    describe b = ...        -- "<kind> '<name>'" parsed best-effort from the manifest
```

`verify` reuses the exact parsing idiom of `toRenderedObject` (lines 349-360):
`Yaml.decodeEither' stamped`, walk `metadata` → `labels` → key
`nagare.dev/app`, and require `String appName`; anything else is
`Left (describe bs <> ": stamped nagare.dev/app label did not land in metadata.labels")`.
This catches both the missing anchor and the nested-pod-template first-match
hazard structurally, while the applied bytes stay splice-produced
(byte-for-byte key ordering preserved — Decision D3). Keep `TE.decodeUtf8` on
`bs` itself: these bytes come from our own renderers and are re-encoded UTF-8
one line above.

Thread the `Either` outward: `stamp` returns
`Either Text (Text, ByteString)`; `renderAppObjects`, `renderPhaseObjects`,
`renderDatabaseObjects`, `renderServiceObjects`, `renderWorkerObjects`, and
`renderTaskObjects` return `Either Text [(Text, ByteString)]` (a `traverse` over
the per-object stamps); `renderPlan` returns `Either Text AppDeployPlan`. In
`runAppDeploy` (lines 395-405) and the live path (`runHooks` line 466,
`applyServicePhase`, `applyWorkerPhase`), unwrap once with
`either (\e -> dieT ("nagarectl app deploy: " <> e)) pure` before using the
objects. This keeps all rendering pure and testable; only the final unwrap does
IO.

Tests. In `cli/nagarectl/test/AppDeploySpec.hs`: adapt the three `renderTests`
(lines 74-102) and `planTests` to the `Either` shape with a small
`unwrapRender :: Either Text a -> IO a` helper
(`either (assertFailure . T.unpack) pure`); the existing assertions (phase order,
`nagare.dev/app: kizashi` infix on every object, plan labels) are unchanged in
substance. Add new cases:

- `stampAppLabel "kizashi" "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n"`
  (no anchor) is `Left` and the message mentions `nagare.dev/managed-by`.
- `stampAppLabel` on a minimal manifest *with* the anchor is `Right`, and
  `Yaml.decodeEither'` of the result finds `nagare.dev/app: kizashi` under
  top-level `metadata.labels` (assert structurally, not by infix).
- `stampAppLabel` on an already-stamped manifest returns it byte-identically
  (idempotence).
- `waitResult "service 'kizashi-serve'" ExitSuccess @?= PhaseOk` and
  `waitResult "service 'kizashi-serve'" (ExitFailure 1)` is a `PhaseFailed` whose
  message contains `did not become Ready` — this is the unit-level demonstration
  of the ExitCode-to-PhaseFailed conversion (finding 2), the practical substitute
  for simulating a live `kubectl wait` timeout (see Validation for the optional
  live demo).

Acceptance: `cabal build all` and `cabal test nagarectl-test` pass;
`cabal run -v0 exe:nagarectl -- app deploy --dry-run` output for the test fixture
app is byte-identical to before (the splice bytes are unchanged; only the failure
mode changed). Commit as `fix(nagarectl): clean phase failures on readiness
timeouts and verified app-label stamping` with the trailers.

### Milestone 3 — house-style sweep and final validation

Scope: finding 5 within the boundaries of Decision D5, then a full validation
pass and the closing bookkeeping of this document.

Replace `maybe x id` with `fromMaybe x`:

- `cli/nagarectl/src/Nagare/Target.hs:347`:
  `let s' = fromMaybe s (T.stripPrefix "export " s)`; line 427:
  `base <- fromMaybe Map.empty <$> readContextMap "nagare.target.env"`. Add
  `import Data.Maybe (fromMaybe)` (this module uses plain imports, not
  `Nagare.Dsl.Prelude`).
- `cli/nagarectl/src/Nagare/App/Deploy.hs:391`:
  `reBaseDomain = fromMaybe (tpBaseDomain tp) (adpBaseDomain p)` (`fromMaybe` is
  already in scope via `Nagare.Dsl.Prelude`).
- `cli/nagarectl/src/Nagare/Env/PreviewOverlay.hs:96`,
  `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs:215`,
  `cli/nagarectl/src/Nagare/Ops/Cleanup.hs:145`: same mechanical swap; check each
  module's imports for `fromMaybe` availability first.

Do **not** touch `Ops/Status.hs:53` (plan 101), anything under
`cli/nagare-access` (plan 98), or the `nagare-dsl` `rank` sites; leave
`either (const Nothing) Just` as-is (all per Decision D5 — if the implementer
disagrees, that is a new Decision Log entry, not a silent change).

Acceptance: full build and test pass, fourmolu clean on touched files. Commit as
`refactor(nagarectl): prefer fromMaybe over maybe-id` with the trailers. Then
fill in Outcomes & Retrospective here with the final test counts and any evidence
transcripts, and tick off Progress.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/nagare`) unless a `cd` is shown. Enter the dev
shell first if `cabal`/GHC are not on PATH:

```bash
nix develop
```

Baseline (before any edit) — confirm the suite is green so later failures are
attributable to your changes:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
```

Expected tail of the test output (counts will differ slightly as the tree moves):

```text
All N tests passed (X.XXs)
Test suite nagarectl-test: PASS
```

Milestone 1 edits: `src/Nagare/Database/Create.hs` (hex generation),
`src/Nagare/Database/Secret.hs` (`percentEncode`, encoded userinfo, total
`b64decode`, export-list addition), `src/Nagare/Env/Store.hs` (total
`b64decode`), `test/Spec.hs` (new cases in the `Nagare.Database.Secret` group;
import `percentEncode` in the existing `Nagare.Database.Secret` import block near
line 81). Then:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
fourmolu -i src/Nagare/Database/Create.hs src/Nagare/Database/Secret.hs src/Nagare/Env/Store.hs test/Spec.hs
cabal test nagarectl-test -v0   # confirm formatting broke nothing
```

A quick behavioral spot-check of the generator itself (this only exercises
`openssl`, no cluster):

```bash
openssl rand -hex 24
```

Expected: a 48-character lowercase-hex line, e.g.
`3f9c0a71e2b44d8896aa01c4de5f6a7b8c9d0e1f2a3b4c5d`.

Commit (staging explicit paths only — never `git add -A` in this repo):

```bash
git add cli/nagarectl/src/Nagare/Database/Create.hs cli/nagarectl/src/Nagare/Database/Secret.hs cli/nagarectl/src/Nagare/Env/Store.hs cli/nagarectl/test/Spec.hs docs/plans/102-nagarectl-correctness-and-robustness-fixes.md
git commit -m "fix(nagarectl): make managed-db credentials URL-safe and secret decoding total" -m "Generate hex passwords, percent-encode connection-URL userinfo, and replace partial decodeUtf8 with decodeUtf8' in both b64decode helpers." -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" -m "ExecPlan: docs/plans/102-nagarectl-correctness-and-robustness-fixes.md"
```

Milestone 2 edits: `src/Nagare/Deploy.hs` (waits return `ExitCode`,
`requireWait`), the eight legacy caller files listed in the Plan of Work,
`src/Nagare/App/Deploy.hs` (`waitResult`, `PhaseResult`-returning phase appliers,
`Either`-threaded stamping), `test/AppDeploySpec.hs` (adapted + new cases). Then
the same build/test/format cycle:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
fourmolu -i src/Nagare/Deploy.hs src/Nagare/App/Deploy.hs test/AppDeploySpec.hs   # plus the other touched files
```

Dry-run regression check (no cluster, no GCP; uses the checked-in test fixture):

```bash
cd cli/nagarectl
cabal run -v0 exe:nagarectl -- app deploy test/fixtures/app/kizashi/Config.hs --dry-run > /tmp/dryrun-after.txt || true
```

Run the same command on the pre-change commit (`git stash` or a worktree) into
`/tmp/dryrun-before.txt` and compare — `diff` must be empty, proving the stamped
bytes are unchanged. (If the fixture invocation needs flags the CLI has grown,
mirror however `test/AppDeploySpec.hs` drives `loadApplication` instead; the
authoritative acceptance is the test suite.)

Commit:

```bash
git add cli/nagarectl/src/Nagare/Deploy.hs cli/nagarectl/src/Nagare/App/Deploy.hs cli/nagarectl/src/Nagare/Server/Deploy.hs cli/nagarectl/src/Nagare/Static/Deploy.hs cli/nagarectl/src/Nagare/Worker/Deploy.hs cli/nagarectl/src/Nagare/Broker/Create.hs cli/nagarectl/src/Nagare/Broker/Restart.hs cli/nagarectl/src/Nagare/Database/Create.hs cli/nagarectl/src/Nagare/Database/Restart.hs cli/nagarectl/app/Main.hs cli/nagarectl/test/AppDeploySpec.hs docs/plans/102-nagarectl-correctness-and-robustness-fixes.md
git commit -m "fix(nagarectl): clean phase failures on readiness timeouts and verified app-label stamping" -m "Readiness waits return ExitCode; app deploy converts them to PhaseFailed and other paths die with a one-line message. stampAppLabel now fails loudly and verifies the label structurally." -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" -m "ExecPlan: docs/plans/102-nagarectl-correctness-and-robustness-fixes.md"
```

Milestone 3 edits: the `fromMaybe` swaps in `src/Nagare/Target.hs`,
`src/Nagare/App/Deploy.hs`, `src/Nagare/Env/PreviewOverlay.hs`,
`src/Nagare/Cdn/Cloudflare.hs`, `src/Nagare/Ops/Cleanup.hs`. Then:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
fourmolu -i src/Nagare/Target.hs src/Nagare/App/Deploy.hs src/Nagare/Env/PreviewOverlay.hs src/Nagare/Cdn/Cloudflare.hs src/Nagare/Ops/Cleanup.hs
git add cli/nagarectl/src/Nagare/Target.hs cli/nagarectl/src/Nagare/App/Deploy.hs cli/nagarectl/src/Nagare/Env/PreviewOverlay.hs cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs cli/nagarectl/src/Nagare/Ops/Cleanup.hs docs/plans/102-nagarectl-correctness-and-robustness-fixes.md
git commit -m "refactor(nagarectl): prefer fromMaybe over maybe-id" -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" -m "ExecPlan: docs/plans/102-nagarectl-correctness-and-robustness-fixes.md"
```

Update this plan file (Progress checkboxes, evidence, Outcomes) alongside each
commit — the plan file is part of every commit's staged paths above.


## Validation and Acceptance

The authoritative gate is the `nagarectl` test suite, run exactly as CI's flake
check does:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
```

Acceptance is behavioral, per finding:

1. **Credentials.** The streaming test output shows the new
   `Nagare.Database.Secret` cases passing, including
   `composeConnectionUrl postgres percent-encodes a hostile password` asserting
   the exact URL
   `postgresql://nagare:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:5432/pg_main`,
   and the pre-existing plain-password cases still pass byte-identically
   (proving no regression for safe passwords). `openssl rand -hex 24` at a shell
   prints 48 hex characters. To demonstrate the write-through before/after: on
   the pre-change tree these hostile-password tests, if added, would fail with
   the raw `a+b/c=` embedded in the URL — you can verify this by running the new
   tests against a stash of the old `Secret.hs` and watching them fail.
2. **Readiness failures.** The new `waitResult` tests pass:
   `ExitFailure 1` maps to `PhaseFailed` whose message contains
   `did not become Ready within the 300s timeout`. This is the unit-level proof
   of the conversion. Optional live demonstration (only if a cluster context is
   at hand — the local k3d path via `just local-smoke` or the nagare-01 harness
   in the workstation memory notes): deploy an app whose service image
   crash-loops (e.g. a config pointing at a nonexistent tag) and observe that
   `nagarectl app deploy` now ends with
   `nagarectl app deploy: service '<name>' did not become Ready within the 300s timeout (kubectl wait exited 1)`
   and exit code 1, where before it ended with an uncaught cradle exception. Do
   not treat the live demo as blocking; the unit conversion plus the unchanged
   `runPhases` sequencing tests are sufficient.
3. **Label stamping.** The new `stampAppLabel` tests pass: `Left` (mentioning the
   missing `nagare.dev/managed-by` anchor) on an anchor-less manifest — before
   this change the same input silently returned the manifest unstamped — and a
   structural (parsed, not substring) assertion that the label lands at
   top-level `metadata.labels` on the happy path. The dry-run byte-comparison in
   Concrete Steps shows rendered output is unchanged for well-formed manifests.
4. **UTF-8 totality.** The `b64decode "/w=="` test returns `Left` mentioning
   `not valid UTF-8`; on the pre-change tree the same call throws a
   `Data.Text.Encoding: Invalid UTF-8 stream` exception from pure code.
5. **Style.** `grep -rn "maybe .* id" cli/nagarectl/src --include='*.hs'` no
   longer matches the six swapped sites (remaining matches are only the
   out-of-scope files named in Decision D5), and the suite is green.

Success is: every command above exits 0, the final test summary reads
`All N tests passed` with N strictly larger than the baseline count, and the two
excluded ownership areas (`cli/nagare-access`, `Ops/Status.hs`, `nagared/Main.hs`,
`Static/Webhook.hs`, `Dsl/Load.hs`) show no diff in `git status`.


## Idempotence and Recovery

Every step is safe to repeat. `cabal build`/`cabal test` are idempotent. The
edits are ordinary source changes on the `master` branch (no feature branch, per
repo convention); if a milestone goes wrong mid-way, `git checkout -- <file>` the
affected files (or `git stash`) and restart that milestone — the milestones are
independent and each leaves the tree green, so recovery never requires undoing a
previous milestone's commit.

No step touches a cluster, GCP, or any deployed state: the entire plan is
compile-plus-unit-test scoped. In particular, existing managed-database Secrets
are *not* migrated — the credential fix changes only what future
`db create` runs write, and the optional live readiness demo in Validation is
read-mostly (one throwaway app deploy in whatever context is active; if you run
it, do so in a `mode=local` k3d context so no cloud project is involved, and
delete the throwaway app afterwards).

If a rebase conflict arises with plan 98 or 101 landing first: the owned module
sets are disjoint (see Context and Orientation), so conflicts can only appear in
shared leaf files like `app/Main.hs` import lists; resolve by keeping both sides'
imports and re-running the test suite.


## Interfaces and Dependencies

No new packages. Everything uses dependencies already in
`cli/nagarectl/nagarectl.cabal`: `http-types` (percent-encoding), `cradle`
(process running), `yaml` (structural verification), `text`, `bytestring`,
`memory`. `cli/nagare-dsl` is not modified.

Signatures that must exist at the end of each milestone (full module paths;
"exported" means present in the module's export list so tests can import them):

After Milestone 1, in `Nagare.Database.Secret`
(`cli/nagarectl/src/Nagare/Database/Secret.hs`):

```haskell
percentEncode :: Text -> Text                       -- exported
composeConnectionUrl :: Engine -> ConnectionParts -> Text   -- unchanged type; encoded userinfo
b64decode :: Text -> Either Text Text               -- now total (decodeUtf8')
```

and in `Nagare.Env.Store` (`cli/nagarectl/src/Nagare/Env/Store.hs`) the same
total `b64decode :: Text -> Either Text Text`. `Nagare.Database.Create`'s
`generatePassword :: IO Text` keeps its type but produces 48-char hex.

After Milestone 2, in `Nagare.Deploy` (`cli/nagarectl/src/Nagare/Deploy.hs`):

```haskell
waitForReady :: Text -> Text -> IO ExitCode         -- was IO ()
waitForRollout :: Text -> Text -> IO ExitCode       -- was IO ()
waitForWorkerRollout :: Text -> Text -> IO ExitCode -- was IO ()
requireWait :: Text -> ExitCode -> IO ()            -- new, exported
```

and in `Nagare.App.Deploy` (`cli/nagarectl/src/Nagare/App/Deploy.hs`):

```haskell
waitResult :: Text -> ExitCode -> PhaseResult                    -- new, exported
stampAppLabel :: Text -> ByteString -> Either Text ByteString    -- was ... -> ByteString
renderAppObjects :: RolloutEnv -> Application -> Either Text [(Text, ByteString)]
renderPlan :: RolloutEnv -> Application -> Either Text AppDeployPlan
applyServicePhase :: RolloutEnv -> Deployment -> IO PhaseResult  -- was IO ()
applyWorkerPhase :: RolloutEnv -> Worker -> IO PhaseResult       -- was IO ()
```

(`PhaseResult`, `PhaseExec`, `runPhases`, `runHooks`, and `waitForJobComplete`
are unchanged.)

Milestone 3 changes no types.

---

Revision note (2026-07-16): rewrote the skeleton into a full ExecPlan from a
verified review of the tree at commit `28a67ef` — all quoted code and line
numbers were re-checked against the actual modules, the test/build commands were
taken from `flake.nix`'s `nagarectl-build-test` check, and the scope boundaries
against plans 98 and 101 were recorded as Decisions D3-D5. Reason: this plan is
the designated remediation vehicle for the nagarectl findings of MasterPlan 19.
