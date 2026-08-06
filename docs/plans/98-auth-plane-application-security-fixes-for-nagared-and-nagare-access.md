---
id: 98
slug: auth-plane-application-security-fixes-for-nagared-and-nagare-access
title: "Auth-plane application security fixes for nagared and nagare-access"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
---

# Auth-plane application security fixes for nagared and nagare-access

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare's auth plane is written in Haskell and has two runtime services. `nagared`
(source: `cli/nagarectl/nagared/Main.hs`, built from the `nagarectl` package) is a
small HTTP daemon that receives GitHub webhooks, verifies their HMAC signature,
checks out the pushed commit, and deploys it. `nagare-access` (package
`cli/nagare-access`) is a forward-auth proxy: every request to a protected site
flows through it; it authenticates the browser session (cookies signed against
the shomei identity service) and asks the `en` authorization service whether the
user may reach the requested host, caching those decisions briefly.

A verified security review found seven application-level defects in this plane.
The worst is remote code execution: anyone on GitHub can open a pull request
against a watched repository from a fork, GitHub delivers that `pull_request`
webhook signed with the repository's real webhook secret, `nagared` checks out
the fork's commit, and the config loader (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`)
executes the fork's `nagare/Config.hs` with `runghc` — arbitrary attacker Haskell
running with `nagared`'s privileges on the host. The remaining findings are: no
timeout on that `runghc` (a looping config hangs the webhook handler forever), a
refresh-cookie MAC comparison whose constant-time property is accidental, an open
redirect via backslash in the post-login return path, transient `en` outages
being cached as access denials, unbounded growth of the decision cache, and a
partial UTF-8 decode of the `Host` header that can crash a request handler.

After this plan is implemented: a fork PR webhook is acknowledged but ignored
with a logged reason (only same-repo branches get preview deploys); a
misbehaving `Config.hs` is killed after a configurable timeout (default 120
seconds) and reported as a load error; the refresh-cookie MAC check is
explicitly constant-time; return destinations containing backslashes or control
characters are rejected; an unreachable `en` yields HTTP 503 (never a cached
denial); the decision cache evicts expired entries on every write; and an
invalid-UTF-8 `Host` header yields a clean 4xx. Every behavioral change is
demonstrated by unit tests named in Validation and Acceptance, runnable with
plain `cabal test` in each package directory.


## Progress

- [x] M1: parse base-repo identity into `PullRequestEvent` in
      `cli/nagarectl/src/Nagare/Static/Webhook.hs` and change `routeEvent` to
      return `Either Text DeployAction` (Left = ignore reason). (2026-08-05)
- [x] M1: gate previews to same-repo PRs (head repo full name must equal base
      repo full name); update `decideWebhook` to surface the reason; log the
      outcome in `cli/nagarectl/nagared/Main.hs`. (2026-08-05)
- [x] M1: update existing webhook fixtures in `cli/nagarectl/test/Spec.hs`
      (they need a `base` object now) and add fork-PR gating tests. (2026-08-05
      — 6 new cases; `prForkOpened` and `prNoBase` fixtures added)
- [x] M1: add `ConfigTimeout` and `runConfigWith`/`loadStaticSiteWith` to
      `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, wrap `readProcessWithExitCode`
      in `System.Timeout.timeout`, add `LoadTimedOut` to `LoadError` and
      `renderLoadError`. (2026-08-05 — import had to be qualified, see
      Surprises & Discoveries)
- [x] M1: add a `--config-timeout` option to `nagared` and use
      `loadStaticSiteWith` in `runAction`. (2026-08-05 — with a `positiveInt`
      reader so a non-positive budget is a usage error)
- [x] M1: add a timeout test with a sleeping fixture to
      `cli/nagare-dsl/test/LoadSpec.hs`; verify no lingering `runghc`.
      (2026-08-05 — test completes in 1.04s with a 1s budget; `pgrep -fl
      runghc` finds nothing afterward)
- [x] M1: `cabal test` green in `cli/nagare-dsl` and `cli/nagarectl`;
      `cabal build exe:nagared` green; fourmolu run on touched files; commit.
      (2026-08-05 — 384 and 361 tests pass respectively)
- [x] M2: replace the MAC comparison in
      `cli/nagare-access/src/Nagare/Access/Cookie.hs` with explicit
      `Data.ByteArray.constEq` on raw digest bytes. (2026-08-05)
- [x] M2: reject backslash and control characters in `safeReturnDestination`
      (`cli/nagare-access/src/Nagare/Access/Challenge.hs`). (2026-08-05)
- [x] M2: switch `lookupHost` in `cli/nagare-access/src/Nagare/Access/App.hs`
      to the lenient `decodeUtf8Maybe` pattern. (2026-08-05)
- [x] M2: unit tests for all three in `cli/nagare-access/test/Spec.hs`;
      `cabal test` green in `cli/nagare-access`; fourmolu; commit. (2026-08-05
      — 94 tests pass; the Host test was verified to FAIL against the old
      `lookupHost`, see Surprises & Discoveries)
- [ ] M3: introduce `AuthorizationResult` in
      `cli/nagare-access/src/Nagare/Access/DecisionCache.hs`, change
      `authorizeUser` and `Nagare.Access.En` to return it, and make
      `handleProtected` answer 503 for `AuthorizationUnavailable` without
      caching it.
- [ ] M3: evict expired entries in `writeCache` and export `cacheSize` for
      tests.
- [ ] M3: tests — unavailable is 503 and not cached, denials still cached,
      eviction shrinks the map; `cabal test` green in `cli/nagare-access`;
      fourmolu; commit.
- [ ] Final: update Progress/Surprises/Decision Log/Outcomes in this file and
      commit the plan update.


## Surprises & Discoveries

Seeded during plan research (2026-07-15); extend during implementation.

- The refresh-cookie comparison at
  `cli/nagare-access/src/Nagare/Access/Cookie.hs:161` is *already* constant-time
  in practice, but only by library accident: it compares two `HMAC SHA256`
  values with `==`, and crypton's instance is explicitly constant-time:

  ```haskell
  -- /Users/shinzui/Keikaku/hub/haskell/crypton-project/crypton/Crypto/MAC/HMAC.hs
  instance Eq (HMAC a) where
      (HMAC b1) == (HMAC b2) = B.constEq b1 b2
  ```

  The finding is therefore lower severity than reported, but the fix stands:
  the property should be locally evident (`BA.constEq` on raw bytes, as
  `verifySignature` in `cli/nagarectl/src/Nagare/Static/Webhook.hs:49-55`
  already does), not dependent on which `Eq` instance resolution picks.

- `parsePullRequest` (`cli/nagarectl/src/Nagare/Static/Webhook.hs:106-129`)
  reads only `pull_request.head` — including the *head* repo's `clone_url` —
  so a fork PR is checked out from the attacker's repository. GitHub delivers
  fork-PR `pull_request` events to the base repository's webhooks signed with
  the base repository's secret, so the HMAC check passes by design.

- The existing PR fixtures in `cli/nagarectl/test/Spec.hs:2257-2263`
  (`prOpened`, `prClosed`) have no `base` object. Once the parser requires
  `pull_request.base.repo.full_name`, those fixtures must be extended or every
  PR test fails with a 400 parse rejection.

Found during implementation (2026-08-05):

- **`import System.Timeout (timeout)` does not compile in `Load.hs`.** The name
  collides with two record fields already in scope there — `timeout` on
  `ProbeTiming` (from `Nagare.Dsl.Worker`) and on `HealthCheck` (from
  `Nagare.Dsl.Types`), both imported unqualified:

  ```text
  src/Nagare/Dsl/Load.hs:1578:9: error: [GHC-87543]
      Ambiguous occurrence ‘timeout’.
      It could refer to
         either the field ‘timeout’ of record ‘ProbeTiming’, …
             or the field ‘timeout’ of record ‘HealthCheck’, …
             or ‘System.Timeout.timeout’, …
  ```

  Fixed with `import System.Timeout qualified as Timeout` and a
  `Timeout.timeout` call site. The plan's snippet would not have built as
  written.

- **The child `runghc` really is reaped, as the plan predicted.** The timeout
  test finishes in 1.04 s against a 1-second budget — i.e. the bound fires
  rather than the config completing — and no process survives it:

  ```text
  a config that never terminates returns LoadTimedOut: OK (1.04s)
  All 1 tests passed (1.04s)
  === orphan check ===
  no lingering runghc
  ```

  So no explicit `withCreateProcess`/`terminateProcess` rewrite was needed.

- **`--config-timeout` rejects non-positive values at parse time.** The plan
  said to "reject non-positive values with optparse-applicative's standard
  tools" without naming a mechanism; implemented as a `positiveInt :: ReadM Int`
  reader built from `auto` plus `readerError`, so `--config-timeout 0` is a
  usage error rather than a daemon whose every config load times out instantly.

- **The invalid-UTF-8 `Host` finding is real, and the test proves it.** Written
  before the fix as the plan instructed, then run against the old strict
  `lookupHost`:

  ```text
  an invalid-UTF-8 Host header gets a clean 4xx, not a crash: FAIL
    Exception: Cannot decode byte '\xc3': Data.Text.Encoding: Invalid UTF-8 stream
  1 out of 1 tests failed (0.01s)
  ```

  With `decodeUtf8Maybe` the same request is an ordinary unmapped host and
  answers 404. (Verified by temporarily reverting the one-line change, running
  the single test, and restoring it.)


## Decision Log

- Decision: gate fork PRs in the pure router (`routeEvent`), not in `nagared`'s
  IO handler, and change `routeEvent`'s result from `Maybe DeployAction` to
  `Either Text DeployAction` where `Left` carries the human-readable ignore
  reason.
  Rationale: the module header of `Nagare.Static.Webhook` promises that all
  security-sensitive decisions are pure and unit-testable; `Either` is the
  standard-base idiom for "no, and here is why" (house style prefers standard
  idioms over bespoke sum types), and `decideWebhook` can surface the reason
  verbatim as the `Ignored` body that `nagared` returns and logs.
  Date: 2026-07-15.

- Decision: represent the runghc timeout as a new `LoadError` constructor
  `LoadTimedOut !FilePath !Int` plus a `ConfigTimeout` value threaded through a
  new `runConfigWith`; keep `runConfig` as `runConfigWith defaultConfigTimeout`
  so `loadDeployment`, `loadDatabase`, and the other loaders inherit the 120 s
  default without signature churn. Only `loadStaticSiteWith` (used by
  `nagared`) gets an explicit-timeout variant now.
  Rationale: "map expiry to the existing load-error type" — a distinct
  constructor renders a precise message and is directly assertable in
  `LoadSpec`; a changed default parameter on every `load*` would ripple through
  every `nagarectl` call site for no benefit.
  Date: 2026-07-15.

- Decision: model "authorizer unreachable" as a new two-constructor type
  `AuthorizationResult` (`AuthorizationDecision AccessDecision` |
  `AuthorizationUnavailable Text`) living in `Nagare.Access.DecisionCache`,
  and change `cacheLookupOrLoad` to operate on it, caching only
  `AuthorizationDecision` values.
  Rationale: extending `AccessDecision` itself with an `Unavailable`
  constructor would force the cache and every pattern match to treat a
  non-decision as a decision; a wrapper keeps "what en said" separate from
  "whether en answered". It lives in `DecisionCache` (a pure module already
  imported by `En` and `App`) to avoid an import cycle. The four existing
  decision-cache tests are updated to wrap loads in `AuthorizationDecision`.
  Date: 2026-07-15.

- Decision: an invalid-UTF-8 `Host` header falls into the existing
  no-backend branch and yields the existing 404 "not found" (or the
  `missingBackendResponse` when a raw host is still printable) rather than a
  bespoke 400.
  Rationale: the fix is one line — reuse the `decodeUtf8Maybe` pattern already
  at `App.hs:412-414` — and the observable requirement is "clean 4xx instead
  of a crashed handler". Inventing a new response path for a hostile header is
  more surface for no user value.
  Date: 2026-07-15.

- Decision: decision-cache growth is bounded by opportunistic eviction — every
  `writeCache` drops all expired entries before inserting — rather than an LRU
  size cap.
  Rationale: entries are one small record per (subject, host) pair; the danger
  is only unbounded accumulation of *expired* keys over weeks. Filtering on
  write is O(n) on a map that eviction itself keeps small, needs no new
  dependency, and is deterministic to test with the injected clock.
  Date: 2026-07-15.

- Decision: this plan owns `cli/nagarectl/nagared/Main.hs`,
  `cli/nagarectl/src/Nagare/Static/Webhook.hs`, the timeout change in
  `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, and all of `cli/nagare-access`.
  ExecPlan `docs/plans/102-nagarectl-correctness-and-robustness-fixes.md`
  (same MasterPlan) touches the same `nagarectl` package but different modules
  (`Nagare.Deploy`, `Nagare.Database.*`). Do not edit those modules here; if a
  shared file must change, note it in both plans' Decision Logs first.
  Date: 2026-07-15.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan happens under `cli/`, the repository's Haskell tree.
There are three Cabal packages, each with its own `cabal.project` workspace, so
commands below always name the working directory:

- `cli/nagare-dsl` — the configuration library. User apps ship a
  `nagare/Config.hs` ("config-as-program"): a real Haskell file that prints a
  JSON description of the app when run. `Nagare.Dsl.Load`
  (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`) runs such a file with `runghc`
  (a GHC tool that compiles and executes a Haskell source file in one step),
  captures its stdout, and decodes it. Test suite: `nagare-dsl-test`
  (tasty/HUnit, entry `cli/nagare-dsl/test/Spec.hs`, load tests in
  `cli/nagare-dsl/test/LoadSpec.hs`).

- `cli/nagarectl` — the deploy CLI plus the `nagared` executable
  (`cli/nagarectl/nagared/Main.hs`). `nagared` listens on
  `POST /webhooks/github/static/<site>`, and `handleWebhook` (Main.hs:165-177)
  delegates the entire accept/reject decision to the pure function
  `decideWebhook` in `cli/nagarectl/src/Nagare/Static/Webhook.hs:190-206`.
  `decideWebhook` verifies the `X-Hub-Signature-256` HMAC first
  (`verifySignature`, Webhook.hs:49-55, already constant-time via
  `BA.constEq`), then parses the event (`parseGitHubEvent`, Webhook.hs:80-91)
  and routes it (`routeEvent`, Webhook.hs:159-168). On `Triggered`, `runAction`
  (Main.hs:179-203) clones/fetches the repo (`checkoutRepo ::
  FilePath -> CheckoutSpec -> IO (Either Text FilePath)` in
  `cli/nagarectl/src/Nagare/Static/Checkout.hs`) and calls
  `loadStaticSite (dir </> "nagare" </> "Config.hs")` (Main.hs:186) — this is
  where the fork's code would execute. Test suite: `nagarectl-test`
  (entry `cli/nagarectl/test/Spec.hs`; webhook tests are the `webhookTests`
  list at Spec.hs:2188-2263, wired as
  `testGroup "Nagare.Static.Webhook" webhookTests` at Spec.hs:285). This
  workspace's `cabal.project` also builds `../nagare-dsl`, so `Load.hs`
  changes are picked up here automatically.

- `cli/nagare-access` — the forward-auth proxy library plus executable.
  "Forward auth" means the ingress sends every request for a protected host to
  this service first; it either proxies the request onward or answers with a
  challenge/denial itself. Key modules, all under
  `cli/nagare-access/src/Nagare/Access/`:
  `App.hs` (WAI routing; `handleProtected` at App.hs:93-114 is the
  authenticate-authorize-forward pipeline), `Challenge.hs` (pure login-redirect
  helpers; `safeReturnDestination` at Challenge.hs:31-37), `Cookie.hs`
  (session/refresh/CSRF `Set-Cookie` construction; `decodeRefreshCookieValue`
  at Cookie.hs:150-163), `En.hs` (the servant HTTP client for the `en`
  authorization service; `authorizeWithEnClient` at En.hs:45-50), and
  `DecisionCache.hs` (a TTL cache from `DecisionKey {subject, host}` to
  `AccessDecision`, held in an `IORef (Map ...)` with an injected clock
  `nowSeconds :: IO Int`). The executable wiring is
  `cli/nagare-access/app/Main.hs`, where `authorizeUser = authorizeWithEn
  enEnv` (Main.hs:59). Test suite: `nagare-access-test` (single file
  `cli/nagare-access/test/Spec.hs`, ~1165 lines; it runs everything in-process
  — the `en` conformance backend is in-memory (`En.Conformance.Kikan`) and WAI
  apps are exercised with `wai-extra`'s `runSession`, so `cabal test` needs no
  external services). Note: the first build of this workspace fetches several
  git dependencies (shomei, en, codd, webauthn) pinned in
  `cli/nagare-access/cabal.project`, so it needs network access and time.

The seven findings, restated precisely:

1. Fork-PR remote code execution (CRITICAL). `parsePullRequest`
   (Webhook.hs:106-129) builds the `CheckoutSpec` entirely from
   `pull_request.head` — including the head repo's `clone_url` and
   `full_name` — and `routeEvent` (Webhook.hs:159-168) triggers a preview for
   any signed `opened`/`synchronize`/`reopened` PR. GitHub signs fork-PR
   deliveries with the base repo's secret, so signature verification does not
   help. Fix: parse `pull_request.base.repo.full_name` too and ignore (with a
   logged reason) any PR whose head repo differs from its base repo.

2. No timeout on `runghc`. `runConfig` (Load.hs:1526-1544) calls
   `readProcessWithExitCode "runghc" [...] ""` (Load.hs:1533-1538) with no
   bound; a `Config.hs` that loops or sleeps forever wedges the `nagared`
   handler thread permanently. Fix: `System.Timeout.timeout` (from `base`)
   around the call, default 120 seconds, configurable from `nagared`, expiry
   mapped to a new `LoadError` constructor.

3. Refresh-cookie MAC compared via an `Eq` instance (Cookie.hs:161:
   `if (HMAC providedDigest :: HMAC SHA256) == hmac keyBytes signedPart`).
   Verified: crypton's instance is constant-time today (see Surprises &
   Discoveries), but the guarantee is incidental. Fix: compare raw MAC bytes
   with `Data.ByteArray.constEq`, mirroring `verifySignature`.

4. Open redirect via backslash. `safeReturnDestination`
   (Challenge.hs:31-37) accepts `"/\\evil.com"`; browsers normalize `\` to `/`
   in `Location`, turning it into `//evil.com` (protocol-relative, off-site).
   The value flows into the post-login redirect at App.hs:262
   (`loginSuccessResponse` puts it in the `Location` header) and into the
   login/MFA forms. Control characters in the same value are a header-
   injection risk. Fix: additionally reject any value containing `\`, any
   character below space, or DEL.

5. Transient `en` outages cached as denials. `authorizeWithEnClient`
   (En.hs:45-50) maps *every* `runClientM` `Left` — connection refused,
   timeout, DNS failure — to `AccessDenied`, and `handleProtected`
   (App.hs:100-111) writes that through `cacheLookupOrLoad`
   (DecisionCache.hs:56-69) for the full TTL: a blip in `en` locks users out
   for `ttlSeconds` and the denial looks legitimate. Genuine denials arrive as
   `Right (CheckResponseWire DeniedWire)`, so `Left` is *always* transport
   failure. Fix: a distinct unavailable outcome that renders HTTP 503 and is
   never written to the cache.

6. `DecisionCache` never evicts. `writeCache` (DecisionCache.hs:76-82) only
   inserts; expired entries for keys never queried again accumulate forever in
   a weeks-long process. Fix: drop expired entries on every write.

7. Partial UTF-8 decode of `Host`. `lookupHost` (App.hs:149-151) is
   `TE.decodeUtf8 <$> lookup hHost (requestHeaders req)`; `TE.decodeUtf8`
   throws an imprecise exception on invalid bytes when the `Text` is forced,
   crashing the handler with a 500. The lenient pattern already exists in the
   same file: `decodeUtf8Maybe = either (const Nothing) Just . TE.decodeUtf8'`
   (App.hs:412-414). Fix: use it.

House style (from the user's global instructions and repo memory): prefer
standard `base` idioms (`Data.Bifunctor.first`, `fromMaybe`, `either`) over
hand-rolled helpers, and keep decision logic pure and unit-tested, with IO as a
thin shell — every fix below (fork gating, redirect validation,
unavailable-vs-denied classification, eviction) is specified as a pure function
change with tests. Formatting: the shared config is `cli/fourmolu.yaml`
(leading commas, 2-space indent). The dev shell pins fourmolu 0.19.x
(`flake.nix:214`), and `flake.nix:25-28` notes that this pinned version would
reformat most of the committed tree (version drift), so run fourmolu only on
the files you touched, never tree-wide:

```bash
fourmolu -i <exact files you edited>
```

Commit conventions: Conventional Commits, no feature branch (commit to
`master`), never `git add -A` (stage explicit paths; a concurrent actor commits
mid-session). Every commit for this plan carries these trailers:

```text
MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md
```


## Plan of Work

The work is three milestones: M1 closes the two `nagared`-side holes (fork RCE,
runghc hang), M2 the three request-hygiene fixes in `nagare-access` (cookie MAC,
redirect, Host header), M3 the decision-cache semantics (503 for outages,
eviction). Each milestone compiles, tests green, gets formatted, and is
committed on its own.


### Milestone 1 — nagared: fork-PR gating and a runghc timeout

Scope: `cli/nagarectl/src/Nagare/Static/Webhook.hs`,
`cli/nagarectl/nagared/Main.hs`, `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, plus
tests in `cli/nagarectl/test/Spec.hs` and `cli/nagare-dsl/test/LoadSpec.hs`.
At the end, a signed fork-PR webhook is answered 200 with an explicit "ignoring
fork pull request" body (and a log line), and a `Config.hs` that never
terminates is killed after the configured timeout and reported as
`LoadTimedOut`.

First, head/base repo identity. In `Webhook.hs`, extend the
`PullRequestEvent` constructor of `GitHubEvent` (currently Webhook.hs:70-75)
with a `baseRepoFullName :: !Text` field. In `parsePullRequest`
(Webhook.hs:106-129), inside `prFields`, additionally read the base repo:

```haskell
    prFields o = do
      headObj <- o .: "head"
      baseObj <- o .: "base"
      (bClone, bFull) <- repoFields' baseObj
      (hRef, hSha, hClone, hFull) <- withObject "pull_request.head" headFields headObj
      pure (hRef, hSha, hClone, hFull, bFull)
```

where `repoFields' v = withObject "pull_request.base" (\b -> b .: "repo" >>= repoFields) v`
— reuse the existing `repoFields` (Webhook.hs:131-135) for the inner repo
object exactly as `headFields` does; only the shape shown matters, name the
helpers to taste. The head repo's `full_name` already flows into
`CheckoutSpec.repoFullName`; keep that (it is the identity of what would be
cloned) and store the base's `full_name` in the new field. A fork PR whose
head repo was deleted has `"repo": null` under `head`; the existing
`h .: "repo"` already fails that parse and `decideWebhook` turns it into
`Rejected 400`, which is safe — no change needed, but do not "fix" it into
leniency.

Second, routing. Change `routeEvent` (Webhook.hs:159-168) from
`WebhookConfig -> GitHubEvent -> Maybe DeployAction` to:

```haskell
routeEvent :: WebhookConfig -> GitHubEvent -> Either Text DeployAction
```

`Left` is the ignore reason. Give every non-trigger a concrete reason: a push
to a non-production branch ⇒ `Left ("push to non-production branch '" <>
branch <> "'")`; a PR action outside opened/synchronize/reopened ⇒
`Left ("pull request action '" <> action <> "' is not a deploy trigger")`;
other events ⇒ `Left "event is not a deploy trigger"`. The new security gate
goes first among the PR guards:

```haskell
  PullRequestEvent {action, prNumber, baseRepoFullName, checkout}
    | repoFullName checkout /= baseRepoFullName ->
        Left
          ( "ignoring fork pull request: head repo '"
              <> repoFullName checkout
              <> "' is not base repo '"
              <> baseRepoFullName
              <> "'"
          )
    | action `elem` ["opened", "synchronize", "reopened"] ->
        Right (DeployPreview (previewNameForPr prNumber) checkout)
    | otherwise -> Left (...)
```

In `decideWebhook` (Webhook.hs:190-206), the final case becomes
`Right ev -> either Ignored Triggered (routeEvent cfg ev)` — the fork reason
travels to the HTTP response body as the `Ignored` text. Update the haddocks on
`routeEvent` and the module header to say fork PRs are ignored by design.

Third, visibility. In `cli/nagarectl/nagared/Main.hs`, `handleWebhook`
(Main.hs:165-177) currently returns responses silently; add one `putStrLn` per
outcome so the operator's journal shows why a delivery did or did not deploy —
at minimum log the `Ignored` reason and the `Triggered` action before running
it (site name plus reason/action; `nagared` already line-buffers stdout at
Main.hs:104).

Fourth, the timeout, in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. Add to the
export list and define:

```haskell
newtype ConfigTimeout = ConfigTimeout {configTimeoutSeconds :: Int}
  deriving stock (Eq, Show)

defaultConfigTimeout :: ConfigTimeout
defaultConfigTimeout = ConfigTimeout 120
```

Add a `LoadTimedOut !FilePath !Int` constructor to `LoadError` (Load.hs:76-93)
— the `Int` is the timeout in seconds — and a `renderLoadError` case
(Load.hs:96 ff.), e.g. `"nagare: config " <> Text.pack path <> " timed out
after " <> ... <> "s (does it loop or block?)"`. Rename the body of `runConfig`
(Load.hs:1526-1544) into `runConfigWith :: ConfigTimeout -> FilePath -> IO
(Either LoadError ByteString)`, keeping `runConfig = runConfigWith
defaultConfigTimeout` so `loadDeployment`, `loadBroker`, `loadDatabase`,
`loadServerSite`, `loadSite`, `loadTask`, `loadJob`, `loadWorker`, and
`loadApplication` are all untouched but bounded. Wrap the process call
(import `System.Timeout (timeout)` from `base`):

```haskell
      result <-
        timeout (configTimeoutSeconds t * 1_000_000) . try @IOException $
          readProcessWithExitCode
            "runghc"
            ["--ghc-arg=-XGHC2024", "--ghc-arg=-package", "--ghc-arg=nagare-dsl", "-i" <> configDir, path]
            ""
      pure $ case result of
        Nothing -> Left (LoadTimedOut path (configTimeoutSeconds t))
        Just (Left ioErr) -> Left (CompileError path (Text.pack (show ioErr)))
        Just (Right (ExitFailure _, _out, err)) -> Left (CompileError path (Text.pack err))
        Just (Right (ExitSuccess, out, _err))
          | null out -> Left (MissingBinding path)
          | otherwise -> Right (BC.pack out)
```

(`1_000_000` needs `NumericUnderscores`, which GHC2024 includes; `timeout`
takes microseconds.) Child-process cleanup: `readProcessWithExitCode` is
implemented with `withCreateProcess`, whose cleanup terminates the child when
the waiting thread is interrupted by the async timeout exception — so the
`runghc` process is killed, not leaked. Verify this during implementation (see
Validation); if a lingering `runghc` is observed, switch to an explicit
`withCreateProcess`/`terminateProcess` layout and record it in Surprises &
Discoveries. Also add `loadStaticSiteWith :: ConfigTimeout -> FilePath -> IO
(Either LoadError StaticSite)` (the timeout-taking sibling of `loadStaticSite`,
same one-liner via `runConfigWith`).

Fifth, wire it into `nagared`. In `cli/nagarectl/nagared/Main.hs` add a
`--config-timeout SECONDS` option (default 120, `showDefault`, reader `auto`,
reject non-positive values with `optparse-applicative`'s standard tools) to
`Options`/`optionsParser` (Main.hs:72-89), carry it through `Env`
(Main.hs:91-97), and change Main.hs:186 to
`loadStaticSiteWith (envConfigTimeout env) (dir </> "nagare" </> "Config.hs")`.

Tests. In `cli/nagarectl/test/Spec.hs` `webhookTests` (Spec.hs:2188-2263):
extend `prOpened`/`prClosed` with a same-repo base object, e.g.

```haskell
prOpened :: ByteString
prOpened =
  "{\"action\":\"opened\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}},\"base\":{\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"
```

add a `prForkOpened` fixture identical except head repo
`"full_name\":\"attacker/x\"` (and a fork clone_url), then add cases: a signed
fork PR is `Ignored` with a body mentioning `fork` (assert via
`decideWebhook`); `routeEvent` on a fork `PullRequestEvent` is `Left`;
`parseGitHubEvent` extracts `baseRepoFullName`; a PR payload *missing* `base`
is a parse `Left` (i.e. `Rejected 400` through `decideWebhook`). Update the
existing `Triggered (DeployPreview ...)`/`Ignored` matches for the
`Either`-shaped `routeEvent` where they call it directly (the
`decideWebhook`-level tests keep their shape).

In `cli/nagare-dsl/test/LoadSpec.hs`, add a fixture that blocks forever and a
test using a 1-second timeout (do not test the 120 s default by waiting):

```haskell
sleepingConfig :: String
sleepingConfig =
  unlines
    [ "module Main where"
    , "import Control.Concurrent (threadDelay)"
    , "main :: IO ()"
    , "main = threadDelay maxBound"
    ]
```

Load it through the fixture helper the file already uses
(`withSystemTempFile`, see LoadSpec.hs:114) but via
`runConfigWith (ConfigTimeout 1)` (export it) or a
`loadStaticSiteWith (ConfigTimeout 1)` call, and assert the result is
`Left (LoadTimedOut path 1)` modulo the temp path — pattern match on the
constructor. Note the test still pays one real `runghc` compile (a few
seconds), which is in line with the existing compile-error tests in that file.

Acceptance: both suites green (commands and expected shapes in Validation and
Acceptance), `cabal build exe:nagared` green, then commit, e.g.
`fix(nagared)!: ignore fork pull requests and bound config execution` with the
two trailers. (The `!` is warranted: `routeEvent`'s type and `LoadError`'s
constructor set are exported surface.)


### Milestone 2 — nagare-access: cookie MAC, return destination, Host header

Scope: `cli/nagare-access/src/Nagare/Access/Cookie.hs`, `Challenge.hs`,
`App.hs`, and `cli/nagare-access/test/Spec.hs`. At the end, the refresh-cookie
MAC check is explicitly constant-time, `"/\\evil.com"` and control-character
destinations are rejected everywhere `safeReturnDestination` is consulted
(login form `rd`, login submit, MFA payload), and an invalid-UTF-8 `Host`
header gets a 4xx instead of crashing the handler.

Cookie MAC. In `decodeRefreshCookieValue` (Cookie.hs:150-163), stop
round-tripping through `Digest`/`HMAC` values and compare raw bytes:

```haskell
  providedMacBytes <- either (const Nothing) Just (convertFromBase Base64URLUnpadded macPart :: Either String BS.ByteString)
  let expectedMacBytes = macBytes keyBytes signedPart
  if BA.constEq providedMacBytes expectedMacBytes
    then either (const Nothing) Just (TE.decodeUtf8' tokenBytes)
    else Nothing
```

Import `Data.ByteArray qualified as BA` (the module already imports
`Data.ByteArray (convert)`; merge the imports) and drop the now-unused
`digestFromByteString`/`Digest` machinery from the import of `Crypto.Hash`
(keep what `macBytes`, Cookie.hs:165-167, still needs). `BA.constEq` returns
`False` on length mismatch without early exit, so the old implicit
length-check-by-`digestFromByteString` is subsumed. The existing round-trip
and tamper tests (Spec.hs:227-233) must stay green; add one test that a
truncated MAC part (valid base64, wrong length) decodes to `Nothing`.

Return destination. Tighten `safeReturnDestination` (Challenge.hs:31-37):

```haskell
safeReturnDestination :: Text -> Maybe Text
safeReturnDestination rd
  | Text.isPrefixOf "/" rd
  , not (Text.isPrefixOf "//" rd)
  , not ("://" `Text.isInfixOf` rd)
  , not (Text.any forbiddenReturnChar rd) =
      Just rd
  | otherwise = Nothing

forbiddenReturnChar :: Char -> Bool
forbiddenReturnChar c = c == '\\' || c < ' ' || c == '\DEL'
```

This pure function is the single chokepoint: App.hs already routes the login
form's `rd` query (App.hs:220-222), the login submit's form field
(App.hs:252-254), and the MFA payload's `rd` (App.hs:321) through it, so no
caller changes. Add unit tests to `challengeTests` (Spec.hs:158 ff.):
`safeReturnDestination "/\\evil.com" @?= Nothing`,
`safeReturnDestination "/a\\b" @?= Nothing`,
`safeReturnDestination "/a\r\nSet-Cookie: x" @?= Nothing`,
`safeReturnDestination "/tools?tab=1" @?= Just "/tools?tab=1"` (regression),
and one end-to-end style assertion mirroring the existing "rejects an unsafe
return destination" app test (Spec.hs:549-555) with
`rd=%2F%5Cevil.com` expecting the hidden field to fall back to `/`.

Host header. Change `lookupHost` (App.hs:149-151) to:

```haskell
lookupHost :: Request -> Maybe Text
lookupHost req =
  lookup hHost (requestHeaders req) >>= decodeUtf8Maybe
```

(`decodeUtf8Maybe` is defined below in the same file, App.hs:412-414.) With an
undecodable `Host`, both uses in `appWithRuntime` (App.hs:87-91) see
`Nothing`, and the response is the existing `textResponse status404 "not
found"` — a clean 4xx, no exception. Add an app test: build a request with
`("Host", BS.pack [0x2f, 0xc3, 0x28, ...])` — any invalid UTF-8 byte sequence
such as `\xc3\x28` — through `runSession` against
`appWithRuntime emptyBackendMap testServices` and assert status 404 (today
this raises before responding; write it, watch it fail, then apply the fix).

Acceptance: `nagare-access-test` green; commit, e.g.
`fix(nagare-access): harden cookie MAC, return destination, and Host decoding`
with the trailers.


### Milestone 3 — nagare-access: unavailable-vs-denied and cache eviction

Scope: `cli/nagare-access/src/Nagare/Access/DecisionCache.hs`, `En.hs`,
`Auth.hs`, `App.hs`, `app/Main.hs` (type flows only), and tests. At the end, a
dead `en` yields HTTP 503 on protected hosts, never poisons the cache, and the
cache prunes expired entries whenever it writes.

The type. In `DecisionCache.hs`, next to `AccessDecision`, add:

```haskell
data AuthorizationResult
  = AuthorizationDecision !AccessDecision
  | AuthorizationUnavailable !Text
  deriving stock (Eq, Show)
```

and change the cache entry point to operate on it (still caching only real
decisions):

```haskell
cacheLookupOrLoad :: DecisionCache -> DecisionKey -> IO AuthorizationResult -> IO AuthorizationResult
```

A fresh hit returns `AuthorizationDecision cached`; on a miss run the load; if
it is `AuthorizationDecision d`, `writeCache` it and return it; if it is
`AuthorizationUnavailable _`, return it *without* writing. Keep the function
total over `DecisionCacheDisabled` as today (just run the load).

Eviction. Change `writeCache` (DecisionCache.hs:76-82) to prune while
inserting:

```haskell
writeCache cache key now decision =
  atomicModifyIORef'
    (entriesRef cache)
    ( \entries ->
        ( Map.insert
            key
            CachedDecision {cachedAtSeconds = now, cachedDecision = decision}
            (Map.filter (not . isExpired cache now) entries)
        , ()
        )
    )
```

Export a test-only observer `cacheSize :: DecisionCache -> IO Int` (0 for
disabled, `Map.size <$> readIORef (entriesRef cache)` otherwise) so eviction is
assertable without exposing the map.

The client. In `En.hs`, change the result type and factor the classification
into a pure function (import `ClientError` from `Servant.Client`):

```haskell
authorizeWithEn :: ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult

authorizeWithEnClient :: EnClient -> ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult
authorizeWithEnClient client env user host =
  authorizationFromClientResult <$> runClientM (client.check (buildCheckRequest user host)) env

authorizationFromClientResult :: Either ClientError CheckResponseWire -> AuthorizationResult
authorizationFromClientResult =
  either
    (AuthorizationUnavailable . Text.pack . show)
    (AuthorizationDecision . checkResponseToDecision)
```

Every `Left` is transport-level (connection refused, timeout, non-2xx,
undecodable body) — `en` expresses "no" as `Right (CheckResponseWire
DeniedWire)` — so classifying all `Left`s as unavailable is correct, not
lenient. Export `authorizationFromClientResult` for unit testing.

The pipeline. In `Auth.hs`, `AccessServices.authorizeUser` (Auth.hs:67)
becomes `!(AuthenticatedUser -> Text -> IO AuthorizationResult)`. In `App.hs`,
`defaultAccessServices` (App.hs:157) becomes
`authorizeUser = \_ _ -> pure (AuthorizationDecision AccessDenied)`, and the
decision case in `handleProtected` (App.hs:100-111) becomes:

```haskell
      case outcome of
        AuthorizationDecision AccessAllowed ->
          addResponseHeaders responseHeaders <$> forwardAuthorized services user host target req
        AuthorizationDecision _ ->
          pure (addResponseHeaders responseHeaders (forbiddenResponse requestShape))
        AuthorizationUnavailable _ ->
          pure (addResponseHeaders responseHeaders (textResponse status503 "authorization service unavailable"))
```

(import `status503` from `Network.HTTP.Types`; `AccessDenied` and
`AccessConditional` both remain 403 via `forbiddenResponse` exactly as
before). `cli/nagare-access/app/Main.hs:59` (`authorizeUser = authorizeWithEn
enEnv`) typechecks unchanged once `En.hs` is updated.

Tests, all in `cli/nagare-access/test/Spec.hs`:

- Update the four `decisionCacheTests` (Spec.hs:405-446) to wrap loads and
  expectations in `AuthorizationDecision`.
- New cache tests: an `AuthorizationUnavailable` load is returned but a second
  lookup loads again (assert the load counter is 2 and, via `cacheSize`, that
  nothing was written); a denial *is* cached (counter stays 1 — this pins the
  "only genuine denials are cached" behavior); eviction — write key A at
  t=100 with TTL 30, advance the `IORef` clock to 200, look up key B (miss,
  load, write), then `cacheSize` is 1 (A evicted, B present).
- `enTests` (Spec.hs:372-403): update the wire-mapping expectations to the
  wrapped shape; add `authorizationFromClientResult (Right (CheckResponseWire
  DeniedWire)) @?= AuthorizationDecision AccessDenied` and a `Left`-maps-to-
  unavailable case (construct any `ClientError`, e.g. `ConnectionError`); the
  live-servant test (Spec.hs:393-402) now expects
  `AuthorizationDecision AccessAllowed`/`AccessDenied`, and add a sibling that
  points the client env at a closed port (bind a socket, note the port, close
  it — or reuse the `network` dependency already in the test suite) and
  asserts the result matches `AuthorizationUnavailable _`.
- App test: services whose `authorizeUser` counts calls and returns
  `AuthorizationUnavailable "en is down"`, with a real
  `newDecisionCache 30 (pure 100)` and a backend map from
  `backendMapFromList [("tools.example.com", "http://tools.svc")]`; two
  authenticated requests (the `Authorization: Bearer valid` pattern from
  Spec.hs:523-529 plus a `Host: tools.example.com` header) must both return
  503 and the counter must read 2.

Acceptance: `nagare-access-test` green; commit, e.g.
`fix(nagare-access)!: return 503 for authorizer outages and evict expired decisions`
with the trailers (again `!`: `authorizeUser`'s and `cacheLookupOrLoad`'s
types are exported surface).


## Concrete Steps

All commands are run from the repository root
`/Users/shinzui/Keikaku/bokuno/nagare` unless a `cd` says otherwise. Enter the
dev shell if tools are missing (`nix develop` provides GHC, cabal, fourmolu).

Milestone 1:

```bash
cd cli/nagare-dsl
cabal build
cabal test nagare-dsl-test
```

Expected tail of a green run (test count will be higher than before this plan):

```text
All N tests passed (…s)
Test suite nagare-dsl-test: PASS
```

```bash
cd ../nagarectl
cabal build exe:nagared
cabal test nagarectl-test
```

Expect `Test suite nagarectl-test: PASS`, with the
`Nagare.Static.Webhook` group listing the new fork cases. Then verify the
timeout leaves no orphan (run right after the nagare-dsl timeout test):

```bash
pgrep -fl runghc || echo "no lingering runghc"
```

Expect `no lingering runghc`. Format and commit (adjust the file list to what
you actually touched):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
fourmolu -i cli/nagarectl/src/Nagare/Static/Webhook.hs cli/nagarectl/nagared/Main.hs \
  cli/nagare-dsl/src/Nagare/Dsl/Load.hs cli/nagarectl/test/Spec.hs cli/nagare-dsl/test/LoadSpec.hs
git add cli/nagarectl/src/Nagare/Static/Webhook.hs cli/nagarectl/nagared/Main.hs \
  cli/nagare-dsl/src/Nagare/Dsl/Load.hs cli/nagarectl/test/Spec.hs cli/nagare-dsl/test/LoadSpec.hs \
  docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md
git commit -m "fix(nagared)!: ignore fork pull requests and bound config execution" \
  -m "Gate preview deploys to same-repo pull requests by comparing head and base repo identity in the parsed webhook event, and kill runghc config loads after a configurable timeout (default 120s) mapped to LoadTimedOut." \
  -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" \
  -m "ExecPlan: docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md"
```

Milestone 2:

```bash
cd cli/nagare-access
cabal build
cabal test nagare-access-test
```

The first build fetches the pinned shomei/en/codd/webauthn git dependencies
(needs network; can take a while). Expect
`Test suite nagare-access-test: PASS`. Format and commit the touched files
(`Cookie.hs`, `Challenge.hs`, `App.hs`, `test/Spec.hs`, this plan) with the
same trailer pattern.

Milestone 3:

```bash
cd cli/nagare-access
cabal test nagare-access-test
```

Expect PASS with the updated `en`, `decision cache`, and `app` groups. Format
and commit (`DecisionCache.hs`, `En.hs`, `Auth.hs`, `App.hs`, `app/Main.hs` if
touched, `test/Spec.hs`, this plan) with the same trailer pattern.

At every stopping point, update the Progress checklist and the living sections
of this file and include the plan file in the commit.


## Validation and Acceptance

Beyond green suites, each finding has a concrete observable:

1. Fork gating: in `cli/nagarectl`,
   `cabal test nagarectl-test --test-options='-p "fork"'` runs the new cases.
   Behavior: `decideWebhook` on a correctly signed `pull_request` `opened`
   payload whose `head.repo.full_name` is `attacker/x` and
   `base.repo.full_name` is `o/x` returns
   `Ignored "ignoring fork pull request: head repo 'attacker/x' is not base repo 'o/x'"`
   — an HTTP 200 no-op, never `Triggered`, so `checkoutRepo` and `runghc` are
   unreachable for forks. The same payload with matching repos still returns
   `Triggered (DeployPreview "pr-7" …)`. End to end (optional, no cluster
   needed — the deploy will fail later but the decision is what matters):
   start `NAGARE_WEBHOOK_SECRET=topsecret cabal run exe:nagared -- --port 8088`
   and POST the fork fixture with its correct `sha256=` signature; the response
   body is the fork reason and stdout logs it.

2. Timeout: in `cli/nagare-dsl`,
   `cabal test nagare-dsl-test --test-options='-p "timed out"'` (match the
   test name you add). Behavior: loading the `threadDelay maxBound` fixture
   with `ConfigTimeout 1` returns `Left (LoadTimedOut _ 1)` in roughly the
   compile time plus one second, and `pgrep -fl runghc` finds nothing
   afterward. `renderLoadError` output contains "timed out after 1s".

3. Cookie MAC: existing round-trip and tampered-MAC tests
   (`cli/nagare-access/test/Spec.hs:227-233`) stay green against the
   `BA.constEq` implementation; the new wrong-length-MAC test returns
   `Nothing`. Reading `decodeRefreshCookieValue` now shows `BA.constEq`
   directly — the acceptance is partly this local-evidence property.

4. Redirect: `safeReturnDestination "/\\evil.com"` is `Nothing`; the app-level
   test shows `GET /_nagare/login?rd=%2F%5Cevil.com` renders the hidden `rd`
   field as `/`, so a post-login `Location` can never be `/\evil.com`.

5. Unavailable en: the app-level test drives two authenticated requests for a
   mapped host while `authorizeUser` reports unavailable — both responses are
   `503` with body `authorization service unavailable`, and the loader ran
   twice (nothing cached). The closed-port `en` client test returns
   `AuthorizationUnavailable _`. Real denials still produce 403 and are still
   cached (load counter pinned at 1 in the denial-caching test).

6. Eviction: the clock-advancing cache test ends with `cacheSize` equal to 1
   after two distinct keys were written across an expiry boundary.

7. Host header: the invalid-UTF-8 `Host` app test gets HTTP 404 (previously
   the handler threw a decode exception). Write the test before the fix and
   observe the failure to prove causality.

Full-suite commands and their expected `PASS` lines are in Concrete Steps. All
three suites run hermetically (tasty in-process; nagare-access uses the
in-memory Kikan en backend and `runSession` — no cluster, no GCP; only the
nagare-dsl/nagarectl load tests spawn local `runghc`).


## Idempotence and Recovery

Every step is safe to repeat. `cabal build` and `cabal test` are pure with
respect to the source tree; re-running them after a partial edit simply
reports the current compile/test state. The code changes are ordinary edits —
if a milestone goes sideways, `git status` plus `git checkout -- <file>` on
the touched paths restores the last commit (stage explicit paths only; never
`git add -A`, as unrelated concurrent work may be in the tree). The milestones
are independent enough to land separately: M1 touches only
`nagarectl`/`nagare-dsl`, M2/M3 only `nagare-access` (M3 builds on M2 only in
that both edit `App.hs`; land them in order to avoid conflicts). If the
nagare-access first build fails on fetching a pinned git dependency, re-run
`cabal build` (transient network); nothing is left half-configured. The
`fourmolu -i` runs are idempotent, and are deliberately restricted to touched
files because the pinned fourmolu 0.19.x would reformat most of the historical
tree (see `flake.nix:25-28`). No step touches GCP, the cluster, or any target
context, so the repository's project-isolation guardrail is not in play.


## Interfaces and Dependencies

No new package dependencies anywhere: `System.Timeout` and
`Control.Concurrent` are `base`; `Data.ByteArray.constEq` comes from `memory`
via the already-present `crypton`/`memory` imports (`nagare-access` already
depends on `crypton`; `Data.ByteArray` is provided by `memory`, which is in
scope through crypton's dependency — if the build objects, add `memory` to the
`nagare-access` library `build-depends` in
`cli/nagare-access/nagare-access.cabal`, matching `nagarectl.cabal` which
already lists it); `ClientError` comes from `servant-client`, already a
dependency. `tasty`/`tasty-hunit` are already in every suite.

End-state signatures that must exist, by module:

`cli/nagarectl/src/Nagare/Static/Webhook.hs`:

```haskell
data GitHubEvent
  = PushEvent {branch :: !Text, checkout :: !CheckoutSpec}
  | PullRequestEvent
      { action :: !Text
      , prNumber :: !Int
      , headRef :: !Text
      , baseRepoFullName :: !Text
      , checkout :: !CheckoutSpec
      }
  | PingEvent
  | OtherEvent !Text

routeEvent :: WebhookConfig -> GitHubEvent -> Either Text DeployAction
-- decideWebhook keeps its type; Ignored now carries routeEvent's Left reasons.
```

`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (exported):

```haskell
newtype ConfigTimeout = ConfigTimeout {configTimeoutSeconds :: Int}

defaultConfigTimeout :: ConfigTimeout -- 120 seconds

data LoadError = … | LoadTimedOut !FilePath !Int | …

runConfigWith :: ConfigTimeout -> FilePath -> IO (Either LoadError ByteString)

loadStaticSiteWith :: ConfigTimeout -> FilePath -> IO (Either LoadError StaticSite)
```

`cli/nagare-access/src/Nagare/Access/Challenge.hs`: `safeReturnDestination ::
Text -> Maybe Text` (type unchanged; now also rejects `\`, chars below space,
and DEL).

`cli/nagare-access/src/Nagare/Access/DecisionCache.hs` (exported):

```haskell
data AuthorizationResult
  = AuthorizationDecision !AccessDecision
  | AuthorizationUnavailable !Text

cacheLookupOrLoad :: DecisionCache -> DecisionKey -> IO AuthorizationResult -> IO AuthorizationResult

cacheSize :: DecisionCache -> IO Int
```

`cli/nagare-access/src/Nagare/Access/En.hs`:

```haskell
authorizeWithEn :: ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult

authorizeWithEnClient :: EnClient -> ClientEnv -> AuthenticatedUser -> Text -> IO AuthorizationResult

authorizationFromClientResult :: Either ClientError CheckResponseWire -> AuthorizationResult
```

`cli/nagare-access/src/Nagare/Access/Auth.hs`: field
`authorizeUser :: !(AuthenticatedUser -> Text -> IO AuthorizationResult)` in
`AccessServices`.

Services relied upon: none at runtime for tests (see Validation). The
sibling-plan boundary from the Decision Log bears repeating as an interface
constraint: `docs/plans/102-nagarectl-correctness-and-robustness-fixes.md`
owns `Nagare.Deploy` and `Nagare.Database.*` in the same `nagarectl` package;
this plan must not edit those modules.
