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

Full plan before trimming: [98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M3: introduce `AuthorizationResult` in
      `cli/nagare-access/src/Nagare/Access/DecisionCache.hs`, change
      `authorizeUser` and `Nagare.Access.En` to return it, and make
      `handleProtected` answer 503 for `AuthorizationUnavailable` without
      caching it. (2026-08-05 — `app/Main.hs` typechecked unchanged, as the
      plan predicted)
- [x] M3: evict expired entries in `writeCache` and export `cacheSize` for
      tests. (2026-08-05)
- [x] M3: tests — unavailable is 503 and not cached, denials still cached,
      eviction shrinks the map; `cabal test` green in `cli/nagare-access`;
      fourmolu; commit. (2026-08-05 — 100 tests pass, up from 94 after M2)
- [x] Final: update Progress/Surprises/Decision Log/Outcomes in this file and
      commit the plan update. (2026-08-05)

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

- **The plan's `ClientError` construction needed two things it did not
  mention.** `ConnectionError` takes a `SomeException`, so the test constructs
  `ConnectionError (SomeException (userError "connection refused"))`, and
  `cli/nagare-access/test/Spec.hs` had no `Servant.Client` import at all (the
  package was already in the suite's `build-depends`, so only the import line
  was needed). The closed-port variant of the same check is implemented with a
  `closedPort` helper that binds a loopback socket, reads its assigned port,
  and closes it — `network` was already a test dependency.

- **`cli/nagare-access/app/Main.hs` needed no change**, as the plan predicted:
  `authorizeUser = authorizeWithEn enEnv` typechecks unchanged once `En.hs`
  returns `AuthorizationResult`.

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

All three milestones landed on 2026-08-05 as three commits on `master`
(`e2f3849`, `b229ba3`, and the M3 commit), each with the `MasterPlan:`,
`ExecPlan:`, and `Intention:` trailers.

**What is closed.** The fork-PR remote code execution is gone: `routeEvent`
parses `pull_request.base.repo.full_name` and refuses any pull request whose
head repository differs from its base, so `checkoutRepo` and `runghc` are
unreachable for a fork no matter how correctly the delivery is signed. Its
result type changed from `Maybe` to `Either Text`, which means every ignore now
carries a reason that `decideWebhook` returns as the HTTP body and `nagared`
logs — a fork PR is no longer a silent 200. Config execution is bounded: a
`ConfigTimeout` (default 120 s, `--config-timeout` on `nagared`) kills a
`Config.hs` that loops or blocks and reports `LoadTimedOut`, with the child
`runghc` reaped rather than orphaned.

In `nagare-access`: the refresh-cookie MAC is compared with `BA.constEq` on raw
bytes, so the constant-time property is visible in the function rather than
inherited from an `Eq` instance; `safeReturnDestination` rejects backslashes
(which browsers normalize into a protocol-relative off-site redirect) and
control characters (which would split a response header); an invalid-UTF-8
`Host` header is an ordinary unmapped host answering 404 instead of an
exception that crashed the handler; an unreachable `en` produces HTTP 503 and
is never cached, while genuine denials are still cached exactly as before; and
the decision cache prunes expired entries on every write, so it cannot grow
without bound in a weeks-long process.

Test counts: `nagare-dsl` 384, `nagarectl` 361, `nagare-access` 100 (from 94).

**Nothing is deferred.** Every item in Progress is checked; there is no
credential-gated or environment-blocked step in this plan — all three suites
run in-process with no cluster, no GCP, and no external services.

**Lessons.** Two of the plan's code snippets did not survive contact. The
`System.Timeout (timeout)` import collided with two record fields already in
scope in `Load.hs` and had to be qualified — a reminder that a plan naming an
import should check the target module's existing scope, not just the function
signature. And the plan's suggestion to construct "any `ClientError`, e.g.
`ConnectionError`" needed a `SomeException` wrapper and a `Servant.Client`
import in the test file that the plan did not mention.

The thing that worked best was the plan's instruction to write the Host-header
test *before* the fix and watch it fail. It failed with exactly the predicted
exception, which turned a plausible-sounding finding into a demonstrated one;
the same discipline applied to the smoke-test traps in the sibling plan EP-1
caught a probe that proved nothing. Where a fix is defensive, asserting on the
absence of the dangerous behavior — no cluster call in a trap, no cached
denial after an outage — is worth more than asserting on a status code.

