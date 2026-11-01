---
id: 239
slug: deliver-rotated-session-cookies-before-waiting-on-the-upstream
title: "Deliver rotated session cookies before waiting on the upstream"
kind: exec-plan
created_at: 2026-11-01T22:20:53Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-01T22:20:53Z
---

# Deliver rotated session cookies before waiting on the upstream

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements improvement request IR-41,
[docs/improvement-requests/deliver-rotated-session-cookies-before-the-upstream.md](../improvement-requests/deliver-rotated-session-cookies-before-the-upstream.md),
which holds the production evidence and the acceptance criteria AC-1 to AC-7 cited below.


## Purpose / Big Picture

People on the intranet are signed out of sessions meant to last 365 days, because a browser can
drop a request after the session was renewed. nagare-access, the gateway that signs people in to
protected sites, spends the browser's refresh token when a request arrives, then waits for the
site to answer, and only then sends the replacement cookie. If the browser drops the request during
that wait, it keeps the spent token. Its next renewal looks like theft, and Shōmei, the sign-in
service, correctly ends the session. This happened twice in about a day on the labs intranet.

After this change, an ordinary GET or HEAD that renews a session gets an immediate empty redirect to
the same URL carrying the new cookies, before any site is contacted. The browser stores the cookies
and retries, and the retry is served normally. The token is at risk only for one round trip to the
gateway (about 18ms on labs) rather than for the site's response time (1.4s to 2.1s in the two
sign-outs). Shōmei does not change.

To see it working, run `just access-browser-test`. In Chromium, Firefox and WebKit, against the real
gateway and a real Shōmei, a page's request is abandoned while the site is holding the response. The
session then survives its next renewal with no theft alarm. The same scenario with the redirect
turned off reproduces the labs sign-out, so the test demonstrably detects the defect.


## Progress

- [ ] M1: the enforcer answers a refresh-leading GET or HEAD with a 307. `cabal test
  nagare-access-test` passes with new tests for AC-1 to AC-5 on protected and portal backends,
  including the refusal of unsafe paths and cross-origin requests.
- [ ] M2: `just access-browser-test` passes in Chromium, Firefox and WebKit, covering AC-6 and the
  behaviour matrix of AC-7, and the control scenario without the redirect ends the session with one
  `refresh_token_reuse_detected`.
- [ ] M3: `docs/user/access.md`, `docs/user/auth-portal.md` and ADR 15 state the new behaviour and the
  measured matrix (AC-7), and `just user-documentation-validate` passes.
- [ ] M4: the labs portal's analytics fetches follow the redirect, committed and deployed in
  `mori://tan/tan-ng-labs` before the intranet upgrades.
- [ ] M5: a Nagare release carrying this runs on the labs intranet. A live renewal is seen as a 307 in
  the gateway log, and no sign-out is traced to a request dropped during the upstream's wait.


## Surprises & Discoveries

- A throwaway probe on 2026-11-01 answered the browser questions IR-41 left open, and they changed
  the design (see the Decision Log). It ran a plain HTTPS server answering a request that carried the
  old cookie with a 307 and `Set-Cookie`, on Playwright 1.64.1. All three engines agreed. The cookie
  was stored in every case, including when the request failed, so a fetch that will not follow the
  redirect loses the request but not the session:

  ```text
  Chromium 156, Firefox 157, WebKit 27.2, all the same     request result              cookie stored
  document navigation                                      200 at the same URL         yes
  same-origin fetch, redirect follow                       200, redirected=true        yes
  same-origin fetch, mode same-origin                      200, redirected=true        yes
  same-origin fetch, redirect error                        TypeError                   yes
  same-origin fetch, redirect manual                       opaqueredirect, status 0    yes
  same-origin EventSource                                  message received            yes
  cross-origin credentialed fetch, plain 307               TypeError                   yes
  cross-origin credentialed fetch, 307 with CORS headers   200, redirected=true        yes
  cross-origin EventSource, plain 307                      closed, readyState 2        yes
  cross-origin EventSource, 307 with CORS headers          message received            yes
  fetch aborted while the retry is held upstream           AbortError                  yes
  ```

- Firefox requests `/favicon.ico` right after a page loads, and in the probe's first run that request
  took the rotation before the fetch under test. Real pages can behave this way, and it is harmless,
  but the browser tests must block the favicon or they measure the wrong request.

- Echoing the request path into `Location` is an open redirect for `//evil.example/` and
  `/\evil.example`, which browsers resolve to another host. IR-41 does not mention this. The enforcer
  already has `safeReturnDestination` for the same hazard, so M1 reuses it.

- `just gate-fast` and the flake checks do not run `nagare-access-test`: the suites in
  `cli/nagare-harness/src/Nagare/Harness/Gate.hs` are nagarectl, nagare-dsl and nagare-api-server, and
  `nix/checks/default.nix` leaves the access suite to `hydraJobs`, which nothing here runs. This plan
  therefore runs it by hand on every commit. It took 50 seconds on 2026-11-01 (184 tests, all passing).


## Decision Log

- Decision: Answer after the new access token verifies and before authorization. Verification comes
  first because a retry with a pair that does not verify would lead another refresh and loop; today's
  responses for that case stay. Authorization comes after because En may take up to its 5-second
  budget, which would put the exposure back.
  Date: 2026-11-01

- Decision: Do not redirect a GET or HEAD that carries an `Origin` header. Forward it with the cookies
  on its response, as today. This adds to the requests AC-3 lists as unable to be redirected, and it
  narrows AC-1. Browsers send `Origin` on a GET or HEAD only for cross-origin CORS requests, and the
  probe shows a plain 307 fails those in all three engines. An app's working cross-origin fetch would
  fail on every refresh it led, and the enforcer does not know the app's CORS policy. These requests
  keep today's exposure. If that exposure proves to matter, a 307 with CORS headers worked in all three
  engines, restricted to origins in the backend map.
  Date: 2026-11-01

- Decision: Do not redirect when the path fails `safeReturnDestination` or the query has control
  characters. Forward those with cookies, as today. The check applies to the path alone, because `://`
  is common in a query and harmless there. `Location` is relative, so it needs no scheme and works
  behind TLS termination and in local mode.
  Date: 2026-11-01

- Decision: The only redirect-loop guard is IR-41's leader rule. A client that stores neither cookie
  gets one 307 and then a forward. A browser storing the refresh cookie but refusing the session cookie
  would lead a refresh on each hop up to its redirect limit. That needs a session cookie over the
  browser's size limit, which would already break sign-in, so it gets no extra code.
  Date: 2026-11-01

- Decision: The browser suite is an on-demand recipe, not a gate step. It downloads three browsers,
  and the facts it proves change only when this redirect code changes or browsers change their fetch
  rules. Run it for changes to `rotationRedirect` or `RefreshCoalescer`.
  Date: 2026-11-01

- Decision: Reject `redirect: "error"` as a blocker for sessions, while keeping IR-41's ordering. The
  probe shows the cookies survive, so the labs fetches only lose that one analytics request when they
  lead a refresh. M4 still lands before the upgrade so analytics keeps working, but a late M4 does not
  risk a sign-out.
  Date: 2026-11-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

nagare-access, also called the enforcer, is the Haskell service in `cli/nagare-access` that sits in
front of every protected site. It holds two browser cookies. `nagare_session` is a short-lived access
token, and `nagare_refresh` is a long-lived refresh token. Shōmei is the sign-in service. It rotates a
refresh token on each use, meaning it marks the presented token spent and returns a replacement. A
second use of a spent token is treated as theft: Shōmei records `refresh_token_reuse_detected` and
revokes the session. The change to Shōmei that would have tolerated this,
`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-4`, was rejected because it makes spent
tokens usable.

`cli/nagare-access/src/Nagare/Access/App.hs` is the WAI application (WAI is Haskell's web server
interface). `handleProtected` serves a protected site: it calls `authenticateRequest`, then authorizes
through `cacheLookupOrLoad`, then calls `forwardAuthorized`, then adds any rotated cookies to the
upstream's response. `authenticateRequest` returns `Either Response (AuthenticatedUser, [Header])`,
where `Left` means "answer this now" and is already used for sign-in challenges. Its helper
`refreshOrChallenge` holds the refresh logic. `handlePortal` serves the one sign-in portal backend
through `authenticatePortal` and `refreshPortalIdentity`, which today return a pair and cannot answer
early. `establishSession` also refreshes, for a sign-in hand-off, and must keep its behaviour.

`cli/nagare-access/src/Nagare/Access/RefreshCoalescer.hs` makes one Shōmei call per refresh token.
`coalesceRefresh` classifies each caller as `Lead` (runs the refresh), `Join` (waits for a running
one) or `Reuse` (within 30 seconds of a success, `defaultRefreshReuseSeconds`, gets the same pair). It
returns only a `LoginOutcome`, so the caller cannot tell which it was. `AccessServices` in
`cli/nagare-access/src/Nagare/Access/Auth.hs` holds it as `refreshUserSession :: Text -> IO
LoginOutcome`, wired in `cli/nagare-access/app/Main.hs`.

`safeReturnDestination` in `cli/nagare-access/src/Nagare/Access/Challenge.hs` accepts a value that
starts with `/`, does not start with `//`, has no `://`, no backslash and no control characters.
`App.hs` already imports it.

Tests live in `cli/nagare-access/test`. `TestServices.hs` gives a fake service record that tests
override with lens syntax, and `SessionRefreshSpec.hs` shows the request and cookie helpers to copy.
`RealShomei.hs` runs a real Shōmei over a temporary PostgreSQL database and needs nothing installed
beyond the dev shell. `Spec.hs`, around line 1176, shows the wiring of real verification and login
against it. Eleven sites set `refreshUserSession`, in `TestServices.hs`, `RememberedSessionSpec.hs`,
`SessionRefreshSpec.hs` and `Spec.hs`, and `RefreshCoalescerSpec.hs` compares the results of
`coalesceRefresh`. All of them change with the type.

The repository has no browser test tooling today. Node 22 is on the path in the dev shell.

The relevant decision is
[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md): the
enforcer alone sets and verifies the session cookies, and its Consequences record the coalescer and the
rule that only Shōmei's explicit rejection ends a session (from
[ExecPlan 211](211-keep-protected-site-sessions-across-concurrent-refreshes-and-shomei-outages.md)).
This plan amends that ADR. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
is why defects are found in tests with fakes and M5 only confirms.

The labs intranet is `mori://tan/tan-ng-labs`. Its portal's analytics code, in the project paths
`web/apps/portal/src/lib/analytics/config.ts` and `web/apps/portal/src/lib/analytics/identity.ts`,
fetches same-origin with `redirect: "error"`, and the identity fetch also rejects `response.redirected`.
The operator's plan there, `mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option`,
found the intranet once ran an older enforcer than its reported version, so M5 confirms by observing
the behaviour and not by reading a version.


## Plan of Work

### M1: the enforcer redirects

Add the leader's identity to the refresh result. In `Auth.hs` define `RefreshRole` and `RefreshResult`
as shown under Interfaces and Dependencies, and change the field to `refreshUserSession :: Text -> IO
RefreshResult`. In `RefreshCoalescer.hs`, `coalesceRefresh` returns `RefreshResult RefreshLed outcome`
from the `Lead` branch and `RefreshResult RefreshShared outcome` from `Reuse` and `Join`. `Main.hs`
needs no edit. `establishSession` reads `#outcome` and otherwise behaves as before.

In `App.hs` add one pure function, the only place that decides:

```haskell
-- | The immediate answer to a request that led a refresh: an empty redirect to
-- itself carrying the rotated cookies, so the browser has them before any
-- upstream wait. Nothing when the request cannot safely repeat that way.
rotationRedirect :: Request -> RefreshRole -> [Header] -> Maybe Response
rotationRedirect req role rotated
  | role /= RefreshLed || null rotated = Nothing
  | requestMethod req `notElem` ["GET", "HEAD"] = Nothing
  | any ((`elem` ["Upgrade", "Origin"]) . fst) (requestHeaders req) = Nothing
  | BS.any (\byte -> byte < 32 || byte == 127) query = Nothing
  | otherwise = do
      path <- either (const Nothing) Just (TE.decodeUtf8' (rawPathInfo req))
      _ <- safeReturnDestination path
      pure (responseLBS status307 ([(hLocation, rawPathInfo req <> query), ("Cache-Control", "no-store")] <> rotated) "")
  where
    query = rawQueryString req
```

`null rotated` covers a `sessionHeaders` failure, which today yields no cookies. In
`refreshOrChallenge`, on `LoginSucceeded` and `Right user`, answer `Left redirect` when
`rotationRedirect` gives one and `Right (user, rotated)` otherwise; every other branch is unchanged.
Change `authenticatePortal` and `refreshPortalIdentity` to return `Either Response (PortalIdentity,
[Header])` the same way, and have `handlePortal` answer a `Left` before calling `forwardPortal`.
Portal branches other than a verified success keep today's forwarding.

Migrate existing tests by having fakes return `RefreshResult RefreshShared ...`, so they keep testing
forwarding with cookies. Fakes for hand-off tests are unaffected in behaviour. In
`RefreshCoalescerSpec.hs`, compare whole results: the first call is `RefreshLed`, a reuse or waiter is
`RefreshShared`, a retry past the window is `RefreshLed` again, and a burst holds exactly one
`RefreshLed`.

Add `cli/nagare-access/test/RotatedCookieRedirectSpec.hs`, registered in `other-modules` and in
`Spec.hs`, using the real `coalesceRefresh` around a counting fake refresh, a verifier accepting only
`access.new`, and counting `authorizeUser`, `forwardAuthorized` and `forwardPortal`. Its tests are:

- AC-1: expired session plus valid refresh cookie, for a GET and a HEAD on `/x?y=1`, on protected and
  portal backends. The status is 307, `Location` is `/x?y=1`, both `Set-Cookie` headers and
  `Cache-Control: no-store` are present, and the upstream and authorizer counts are zero.
- AC-2: repeat with the returned cookies. The status is 200, one refresh, one upstream call.
- AC-3: POST with a body, and a GET with `Upgrade: websocket`, reach the upstream with cookies on its
  response. A GET with `Origin` behaves the same, and so do `//evil.example/x` and `/\evil.example`.
- AC-4: repeat with the original cookies. First 307, then 200 with cookies, and one refresh.
- AC-5: start eight requests with one token while the refresh is held on an `MVar`, then release it.
  One refresh, one 307, and seven upstream calls.
- A pair that does not verify still clears cookies and challenges, with no 307.

### M2: the browser suite

The suite has two spec files in a new directory, `cli/nagare-access/browser-test`, with `package.json`
pinning `@playwright/test` at exactly 1.64.1, a committed `package-lock.json`, and `playwright.config.ts`
defining one project per engine, `workers: 1`, `ignoreHTTPSErrors: true` and a loopback `proxy`.

`*.example.test` must resolve to loopback in all three engines, and cookies need HTTPS and a real parent
domain. Hosts files are off limits and `--host-resolver-rules` is Chromium-only. So `tls-proxy.ts`, in
Playwright's `globalSetup`, generates a throwaway certificate for `*.example.test` with `openssl` and
runs a small HTTP CONNECT proxy, which all three engines support. It terminates TLS the way Envoy does
and connects by hostname: `legacy.example.test` to port 18782, every other host to port 18780. Each test
blocks `**/favicon.ico` with `page.route`.

`browser-semantics.spec.ts` (AC-7) ports the probe in Surprises & Discoveries. Its own Node HTTPS server
on the same proxy answers an old cookie with a 307, and it asserts the table's rows in each engine. This
pins the browser facts the design rests on.

The harness is a new cabal `test-suite nagare-access-browser-harness` with `main-is: BrowserHarness.hs` in
`cli/nagare-access/test`, sharing `RealShomei` through `other-modules`. A test-suite does not enter the
release image's build, unlike an executable. It adds `hasql` to the dependencies of that stanza. Extend
`RealShomei.hs` with a variant passing the `Hasql.Pool.Pool` as well as the port. `BrowserHarness.hs`
starts:

- a real Shōmei;
- a plain upstream on 18783: `/held` sleeps 5 seconds before answering, `/sse` sends one event and stays
  open, every other path returns 200 text with CORS headers echoing `Origin`, and it counts requests per
  path;
- the enforcer on 18780, with real verification, login and `coalesceRefresh` over real refresh, a 2-second
  coalescer window, an allow-all `authorizeUser`, the real `proxyForwarder`, cookie domain `.example.test`,
  and backends `app.example.test` and `other.example.test`;
- a control enforcer on 18782, identical but with `refreshUserSession` forcing `#role` to `RefreshShared`,
  which reproduces today's behaviour without any production switch, with backend `legacy.example.test`;
- a control server on 18781: `GET /healthz`, `POST /users` (signs up a new person, returns the login, the
  password and the user ID), `GET /counts?path=` and `GET /reuse-alarms?user=`, the last running
  `SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'refresh_token_reuse_detected' AND
  user_id = $1`. Check the column types in migration 0007 of `mori://shinzui/shomei`, project path
  `shomei-migrations/migrations/shomei/0007-shomei-auth-events.sql`.

Playwright starts it through `webServer`: `command: 'cabal run -v0 test:nagare-access-browser-harness'`,
`cwd: '..'`, `url: 'http://127.0.0.1:18781/healthz'`, and `gracefulShutdown: { signal: 'SIGINT', timeout:
10000 }`. SIGINT is required because Haskell runs its `bracket` cleanups, which remove the temporary
database, on an interrupt and not on SIGTERM. Run without arguments by another tool, the suite would just
serve forever, so `BrowserHarness.hs` exits 0 with a message unless `NAGARE_ACCESS_BROWSER_HARNESS=1`,
which the config sets.

`session-rotation.spec.ts` signs in through the real `/_nagare/login` form as a new person per test. It
simulates token expiry with `context.clearCookies({ name: 'nagare_session' })`, which gives the enforcer
exactly what it sees for an expired cookie. Its tests are:

- AC-6, on `app.example.test`: expire, start `fetch('/held', { signal })` in the page, wait until
  `/counts?path=/held` is 1 (the 307 arrived and the retry reached the site), abort, and assert the
  refresh cookie changed. Wait 3 seconds, past the window. Expire again, navigate to `/`, and assert a 200
  at the same URL, a refresh cookie changed again, and zero reuse alarms.
- Control, the same on `legacy.example.test`: the navigation lands on `/_nagare/login` and the user has one
  reuse alarm. This is the labs sign-out reproduced.
- `redirect: "error"` on `/plain`: the fetch throws, the cookie changed, the upstream count is 0, and the
  next navigation is a 200 with no reuse alarm.
- Cross-origin: from `app.example.test`, a credentialed fetch to `other.example.test/plain` succeeds with
  the cookie rotated, because the `Origin` rule forwards it.
- Same-origin `EventSource` on `/sse` receives its event across the rotation.

Add the `access-browser-test` recipe from Concrete Steps to `justfile` and register it in the `"local"`
line of `RECIPES` in `scripts/audit-managed-commands.py`, or `architecture-and-command-audit` fails. Add
`test-results/`, `playwright-report/` and the certificate directory under `browser-test` to `.gitignore`,
and add `cli/nagare-access/browser-test/node_modules/`, since today only a personal global ignore covers it.

### M3: documentation

In `docs/user/access.md`, after the cookie paragraph of "Security model", add a short section on session
renewal: what the 307 is and when it is sent, what stays forwarded and why, the measured table (AC-7, from
`browser-semantics.spec.ts`, naming the engine versions), and what an app author must do: a same-origin
fetch needs nothing unless it uses `redirect: "error"` or `"manual"` or checks `response.redirected`, and a
script using a cookie jar without following redirects will see the 307. Add the remaining risk, a request
dropped during the one round trip. In `docs/user/auth-portal.md`, after the "Keep me signed in" paragraphs,
say the portal gets the same 307 and that its fetches must allow it. Amend ADR 15's Consequences with a
paragraph naming this plan and the leader rule, and update the module comment in `RefreshCoalescer.hs`.

### M4: the labs portal

In `mori://tan/tan-ng-labs`, in the project's `web/apps/portal/src/lib/analytics/config.ts` and
`identity.ts`, change `redirect: "error"` to `"follow"`. In `identity.ts`, replace the `response.redirected`
check with one rejecting only a final URL that differs from the requested endpoint, so a redirect to a
sign-in page still counts as no subject and the rotation retry does not. Update `config.test.ts` and
`identity.test.ts`. Deploy through that repository's normal portal deployment.

### M5: release and confirm

This ships in the next Nagare release through the `nagare-release` skill, and upgrading the real intranet is
that release's own third proof. Upgrading the intranet is a cloud mutation that needs the operator's
go-ahead under the repository's host and cloud mutation rules. Confirm on labs with its gateway logs, using
the method in IR-41's Evidence section: a rotation by a GET now appears as a 307 with no upstream contact,
followed by the retry. Then read Shōmei's records until the next 50 rotations have passed, and trace any
`refresh_token_reuse_detected`: a drop during an upstream's wait after a GET leader means this plan failed,
and a drop within the one round trip or on a request kept forwarded is the accepted remaining risk.


## Concrete Steps

Work from the repository root in the dev shell. For each Haskell commit in M1 and M2:

```bash
(cd cli/nagare-access && cabal test nagare-access-test --test-show-details=direct)
just haskell-style-check
just gate-fast
```

Expect `All 184 tests passed` today, growing with M1, and exit code 0 from each command; check the exit
codes rather than grepping the output. New modules need `cabal-gild` formatting, which the style check
reports. Stage files by explicit path. Land with `just land` after a clean `just gate-fast`.

The recipe for `justfile`:

```text
# The enforcer's session rotation in real browsers, against a real Shomei (EP-239).
# Run the enforcer's browser tests in Chromium, Firefox and WebKit.
[group('test')]
access-browser-test:
    #!/usr/bin/env bash
    set -euo pipefail
    cd cli/nagare-access
    cabal build test:nagare-access-browser-harness
    cd browser-test
    npm ci --no-audit --no-fund
    npx playwright install chromium firefox webkit
    npx playwright test
```

Expected end of a passing run (the count is whatever the two spec files hold across three projects):

```text
  N passed
```

For M3:

```bash
just user-documentation-validate
```


## Validation and Acceptance

M1 is accepted when `cabal test nagare-access-test` passes with the tests listed for AC-1 to AC-5, and when
removing the `rotationRedirect` call makes the AC-1 test fail. M2 is accepted when `just access-browser-test`
exits 0 in all three engines, with the AC-6 test showing zero reuse alarms and the control showing exactly
one. The control is what proves AC-6 detects the defect, so a control that stops failing the session is a
failure of the suite. M3 is accepted when the documented table matches the semantics spec. M4 is accepted
when the labs portal's analytics fetches keep working across a renewal in that repository's tests and after
its deployment. M5 is accepted with the labs observations described above recorded in Progress.

IR-41's AC-1 is met for every GET or HEAD except the requests the Decision Log keeps forwarded. AC-3 is met
with that longer list. AC-7 is met by the semantics spec and the guide. The remaining risk, a request dropped
during the one round trip, and today's exposure for forwarded requests, are accepted by IR-41 and stated in
the guide; they are not acceptance failures.


## Idempotence and Recovery

Every test and recipe can be rerun. The harness uses a temporary database, fixed loopback ports and throwaway
certificates, and `npx playwright install` does nothing when the browsers are present. If a harness run is
killed and a port stays busy, find the process with `lsof -i :18780` and stop it by its exact PID.

The enforcer change stores nothing and changes no cookie or token format, so rolling back is a code revert and
a new enforcer image. Sessions continue across it in either direction. A browser mid-redirect during an
enforcer restart simply retries with cookies it already has. If M5 finds harm, roll back the enforcer on labs
and record it here; M4 is safe to leave in place because `"follow"` also works when no redirect occurs.


## Interfaces and Dependencies

In `cli/nagare-access/src/Nagare/Access/Auth.hs`, exported and following the house rules for strict fields
and explicit deriving strategies:

```haskell
-- | Whether this request ran the refresh or shared one already running or
-- recently settled. Only a leader may answer with the rotation redirect, so a
-- client that keeps no cookies is redirected at most once.
data RefreshRole
  = RefreshLed
  | RefreshShared
  deriving stock (Generic, Eq, Show)

data RefreshResult = RefreshResult
  { role :: !RefreshRole
  , outcome :: !LoginOutcome
  }
  deriving stock (Generic, Eq, Show)
```

`coalesceRefresh :: RefreshCoalescer -> (Text -> IO LoginOutcome) -> Text -> IO RefreshResult` in
`cli/nagare-access/src/Nagare/Access/RefreshCoalescer.hs` keeps a plain `LoginOutcome` for the underlying
refresh, so `refreshWithShomei` is unchanged. `status307` comes from `Network.HTTP.Types`; `rawPathInfo` is
added to the `Network.Wai` imports in `App.hs`.

New test dependencies are `@playwright/test` 1.64.1, the current release on npm on 2026-11-01, and `hasql` in
the harness stanza only. No production dependency is added. No Shōmei, En, Dhall or Kubernetes change is
needed.
