---
id: 211
slug: keep-protected-site-sessions-across-concurrent-refreshes-and-shomei-outages
title: "Keep protected-site sessions across concurrent refreshes and Shomei outages"
kind: exec-plan
created_at: 2026-10-22T19:55:59Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-22T19:55:59Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-22T20:15:25Z
      mode: "implement"
      note: "M1 coalescer and M2 outage handling implemented with tests"
---

# Keep protected-site sessions across concurrent refreshes and Shomei outages

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10).


## Purpose / Big Picture

People signed in to the intranet's protected sites are sent back to the sign-in page well before
their 30-day session ends. The operator noticed it around cluster changes. After this change a
session ends only when the user signs out, an operator revokes it, or it really expires. Running
`nagare-access` (the enforcer in front of every protected site) no longer ends it in two
situations:

1. A browser sends several requests at once just after its 15-minute access token expires. This
   is the cause seen on the intranet.
2. Shomei, the authentication service, or its database is briefly unavailable during a rollout,
   a k3s restart or a host switch. While Shomei is down the user now gets a 503 with their
   cookies kept, and they are still signed in once Shomei is back.

Observable outcome: against a real Shomei, eight concurrent requests carrying the same expired
access token and refresh cookie all succeed, Shomei records no `refresh_token_reuse_detected`,
and the session still refreshes afterwards. With Shomei stopped, a protected request returns 503
with no `Set-Cookie` that clears `nagare_session` or `nagare_refresh`.


## Progress

- [x] M0: The cause is identified from intranet evidence (2026-10-22, read-only, context
  `intranet`, project `tan-ng-labs`).
  In `nagare-system`, `shomei` and `shomei-db-0` were 10 days old and `nagare-access` 4d16h, so
  no Shomei outage happened in the period of the reports. Shomei's audit table
  `shomei.shomei_auth_events` over 14 days held 55 `refresh_token_rotated`, 22 `session_started`
  and 5 `refresh_token_reuse_detected` events, all of them on 2026-10-22. In each of the 5, the
  winning `refresh_token_rotated` and the losing `refresh_token_reuse_detected` share one
  timestamp to the millisecond, at the first refresh after sign-in (about 16 minutes later):

  ```text
   sid      | event_type                   | created_at              | dt_s
   01a16164 | session_started              | 2026-10-22 02:15:54.693 | -964.850
   01a16164 | refresh_token_rotated        | 2026-10-22 02:31:59.543 |    0.000
   01a16164 | refresh_token_reuse_detected | 2026-10-22 02:31:59.543 |    0.000
   01a16507 | session_started              | 2026-10-22 19:12:14.79  | -948.135
   01a16507 | refresh_token_reuse_detected | 2026-10-22 19:28:02.925 |    0.000
   01a16507 | refresh_token_rotated        | 2026-10-22 19:28:02.925 |    0.000
  ```

  The same pattern holds for sessions `01a12de0` (01:48:28.965), `01a16193` (04:42:17.481) and
  `01a16373` (18:50:45.813). Reuse detection revokes the whole session, so the user is signed
  out. Shomei's own log holds only sweep lines, so it gives no per-request evidence.
- [x] M1: Concurrent refreshes of one refresh token make one Shomei call. A new module,
  `Nagare.Access.RefreshCoalescer`, is wired around `refreshUserSession` in
  `cli/nagare-access/app/Main.hs`. Unit tests show that 8 concurrent callers make 1 upstream
  call and get the same tokens, that a caller within the reuse window after completion gets the
  same tokens without a call, that a caller after the window makes a call, that a failure is not
  kept, and that an exception in the leader reaches every waiter and clears the entry. A
  real-Shomei test reproduces the defect without the coalescer (some refresh is rejected, and
  the session is revoked) and shows it gone with the coalescer (all 8 succeed, and the next
  refresh with the rotated token succeeds).
  Done 2026-10-22: the 6 cases of `test/RefreshCoalescerSpec.hs` pass. In the real-Shomei case
  without the coalescer, three probe runs each produced exactly 1 winner, and the next refresh
  with the winner's rotated token returned `LoginFailed "refresh failed"` because the session
  was revoked, matching the intranet pattern. With the coalescer, all 8 got the same pair and
  the session refreshed again.
- [x] M2: Shomei being unavailable never clears a session. `LoginOutcome` gains
  `LoginUnavailable`. `refreshWithShomei`, `loginWithShomei` and `completeMfaWithShomei` return
  it for a transport error, 429, 500, 503 or an unexpected response, and keep `LoginFailed` for
  Shomei's 4xx rejections. In `cli/nagare-access/src/Nagare/Access/App.hs`:
  - `LoginUnavailable` answers 503 and keeps the cookies.
  - `VerificationUnavailable` answers 503 without spending the refresh token.
  - A refresh that succeeds but cannot be verified answers 503 and still sets the rotated cookies.
  - The portal path keeps the cookies in all three cases.

  `getCachedJwks` keeps serving the last good key set for up to 24 hours after a failed refetch.
  Tests cover each case, and the existing "refresh failed clears cookies" test still passes.
  Done 2026-10-22: the 7 cases of `test/SessionRefreshSpec.hs` pass. They cover the document
  and API 503s (`authentication_unavailable`, a new code in `Nagare.Contract.Problem` and
  `docs/api/README.md`) with no `Set-Cookie`, no refresh when verification is unavailable, the
  rotated cookies kept, the portal, the JWKS stale window, Shomei's own 401 mapping to
  `LoginFailed`, and a closed port mapping to `LoginUnavailable`. The full suite reports
  `All 181 tests passed`. `withRealShomeiServer` moved to `test/RealShomei.hs`, and the
  `Spec.hs` allowance was lowered from 1720 to 1678.
- [ ] M3: The work is gated and landed. `just haskell-style-check`, the nagare-access suite
  (`cabal test nagare-access-test` in `cli/nagare-access`, which `just gate-fast` does not run),
  `just gate-fast` and `just land` all pass. ADR 15 gains one consequence: the enforcer
  coalesces refreshes of one refresh token.
- [ ] Intranet (release work, needs the operator's go-ahead): the intranet runs a release with
  this change. A day of normal use afterwards records no `refresh_token_reuse_detected` in
  `shomei.shomei_auth_events`, and the operator's passkey sign-in still works.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

- Decision: Fix the race in `nagare-access`, not in Shomei. The enforcer coalesces concurrent
  refreshes of one refresh token and, for a short reuse window after a success, answers a late
  request carrying the old token with the pair it already obtained. Shomei's reuse detection
  stays strict.
  Rationale: per ADR 15, `nagare-access` is the only component that holds `nagare_refresh`, so
  every refresh of a browser session goes through it, and it runs as one replica
  (`autoscaling.knative.dev/max-scale: "1"` in `cluster/bootstrap/nagare-access/service.yaml`).
  An in-process coalescer therefore covers every refresh. Relaxing reuse detection in Shomei
  would weaken a theft signal for every Shomei client and would need a Shomei release.
  Date: 2026-10-22

- Decision: The reuse window is 30 seconds, a constant, and only successes are kept. Entries are
  keyed by the SHA-256 of the refresh token and bounded at 10 000.
  Rationale: a page's subresource requests leave the browser within a second or two of the
  document, before its `Set-Cookie` arrives. Thirty seconds covers slow mobile links. Anyone
  holding a stolen old refresh token for those 30 seconds could also have replayed it against
  Shomei, so the window adds no new capability. Keeping failures would turn a transient Shomei
  error into a 30-second lockout. Hashing keeps raw tokens out of the map's keys.
  Date: 2026-10-22

- Decision: Only an explicit Shomei rejection (400, 401, 403, 404, 409, 422) ends a session.
  Every other refresh result, including transport errors, 429, 500, 503 and responses that do
  not decode, is `LoginUnavailable` and answers 503 with the cookies kept.
  Rationale: the session cookie is the user's only copy of a still-valid refresh token, and
  clearing it on an outage is permanent. A 503 grants nothing. Shomei rate-limits per client IP
  (60 per minute by default), and every refresh reaches Shomei from the enforcer's single pod
  IP, so a burst after an outage can return 429 for users whose tokens are valid.
  Date: 2026-10-22


## Context and Orientation

The terms used below:

- **`nagare-access`**: the Haskell package in `cli/nagare-access`. It runs as a single-replica
  Knative Service named `nagare-access` in the `nagare-system` namespace. Every request to a
  protected site passes through it, and so do the operator's auth portal (`auth.<base domain>`)
  and the portal's assets.
- **Shomei**: the authentication service (`mori://shinzui/shomei`). It is a Deployment named
  `shomei` with its database `shomei-db`. It issues an ES256-signed access token (a JWT, valid
  15 minutes, `defaultAccessTokenTTL` in `shomei-core/src/Shomei/Config.hs`) and a refresh token
  (valid 30 days). The package pins Shomei at commit `0eedad1328a910b457f86bc79bc42024aca33a20`
  in `cli/nagare-access/cabal.project`.
- **Rotation and reuse detection**: each refresh (`POST /refresh`) returns a new refresh token
  and retires the old one. A retired token presented again is treated as theft:
  `reuseDetected` in `shomei-core/src/Shomei/Session/Authentication/Workflow.hs` revokes the
  whole session and answers 401 `token_reuse`.

Today's flow in `cli/nagare-access/src/Nagare/Access/App.hs`:

1. `authenticateRequest` verifies the `nagare_session` cookie, which holds the access token. On
   any `Left`, it calls `refreshOrChallenge`.
2. `refreshOrChallenge` decodes the `nagare_refresh` cookie (HMAC-signed with
   `NAGARE_ACCESS_COOKIE_KEY`; see `cli/nagare-access/src/Nagare/Access/Cookie.hs`) and calls
   `refreshUserSession`. That function is `refreshWithShomei` in
   `cli/nagare-access/src/Nagare/Access/ShomeiClient.hs`. On `LoginFailed` it calls
   `clearAuthCookies`, which expires both cookies.
3. `refreshPortalIdentity` does the same for portal requests.

There are two defects:

- **Concurrent refreshes.** Several requests that arrive together each refresh the same token.
  One wins, and the others trigger reuse detection, which revokes the session. This is the
  M0 evidence.
- **Outages treated as rejections.** `refreshWithShomei` maps every non-success, including a
  connection error, to `LoginFailed`, so a Shomei outage clears cookies permanently. A JWKS
  fetch failure in `getCachedJwks` (`cli/nagare-access/src/Nagare/Access/Jwks.hs`) gives
  `VerificationUnavailable`. Today that also falls into the refresh path, which spends the
  token.

Shomei's client returns `Either ClientError RefreshResult`. `RefreshResult` is
`ApplicationResult (CookieResponse TokenPairResponse)` from
`shomei-servant/src/Shomei/Servant/Result.hs`, with these constructors: `ApplicationSuccess`,
`ApplicationBadRequest`, `ApplicationAuthenticationFailed`, `ApplicationForbidden`,
`ApplicationNotFound`, `ApplicationConflict`, `ApplicationUnprocessable`,
`ApplicationRateLimited`, `ApplicationInternal` and `ApplicationUnavailable`.

`cli/nagare-access/src/Nagare/Access/DecisionCache.hs` is the model to follow for the
coalescer. It has an injected monotonic clock (`currentSeconds` in `app/Main.hs`), bounded
entries, and a rule that an "unavailable" answer is never cached.

Relevant ADRs:

- [ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md):
  `nagare-access` is the only session authority. It already records that two components sharing
  one refresh token trigger Shomei's reuse revocation. This plan applies the same reasoning
  within the enforcer itself.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  defect is reproduced in the test suite against a real Shomei, and the intranet only confirms.

Module sizes are bounded at 1000 lines by `scripts/check-haskell-architecture.py`.
`cli/nagare-access/test/Spec.hs` sits at its allowance of 1720 in
`scripts/haskell-size-allowances.json`, so new tests go in new test modules. The real-Shomei
helper `withRealShomeiServer` and its keys move from `Spec.hs` to a shared test module, and the
allowance is lowered to the new line count.


## Plan of Work

**M1 (coalescer).** Add `cli/nagare-access/src/Nagare/Access/RefreshCoalescer.hs` and list it
in `nagare-access.cabal`. It holds an `IORef (Map ByteString Entry)` keyed by the SHA-256 of
the refresh token, where an `Entry` is either `InFlight (MVar LoginOutcome)` or
`Settled Int SessionTokens` (with the settle time). `coalesceRefresh` works as follows:

- In one `atomicModifyIORef'`, it returns a settled pair that is still inside the window, joins
  an in-flight `MVar`, or inserts a new `InFlight` and becomes the leader.
- The leader calls Shomei under `onException`. On an exception it puts
  `LoginUnavailable "refresh raised"` for its waiters, removes the entry, and rethrows.
- On `LoginSucceeded` the entry becomes `Settled`. Any other outcome removes the entry.
- Inserts prune expired entries once the map reaches its bound.

Wrap `refreshWithShomei shomeiLoginEnv` with the coalescer in `buildAccessServices`, so
`refreshOrChallenge`, `refreshPortalIdentity` and `establishSession` all share it. Unit tests go
in `test/RefreshCoalescerSpec.hs`, and the real-Shomei reproduction goes in
`test/SessionRefreshSpec.hs`. The reproduction signs up and logs in a user, then fires 8
concurrent refreshes of the same refresh token. Without the coalescer, at least one call
returns `LoginFailed` and a further refresh with the winner's token fails (the session is
revoked). With the coalescer, all 8 return the same pair and a further refresh with that pair's
token succeeds.

**M2 (outage).** Add `LoginUnavailable !Text` to `LoginOutcome` in
`cli/nagare-access/src/Nagare/Access/Auth.hs`. Give `ShomeiClient.hs` one pure classifier,
used by all three Shomei calls, that maps a client result to "rejected" or "unavailable" as the
Decision Log describes. Export it so tests can use it directly. Then:

- In `App.hs`, `authenticateRequest` answers 503 on `Left (VerificationUnavailable _)` without
  refreshing.
- `refreshOrChallenge` answers 503 on `LoginUnavailable` without clearing cookies. When a
  refresh succeeds but verification is unavailable, it answers 503 with `sessionHeaders` for the
  rotated pair.
- `refreshPortalIdentity` and `authenticatePortal` return `PortalAnonymous` with no clearing
  headers, or with the rotated session headers after a successful refresh.
- The built-in login and MFA handlers answer 503 on `LoginUnavailable`.
- The 503 body comes from a new `authenticationUnavailableResponse` in
  `cli/nagare-access/src/Nagare/Access/Response.hs`, built like
  `authorizationUnavailableResponse`.
- In `Jwks.hs`, a failed refetch returns the cached set while it is less than 24 hours past
  expiry.

Tests go in `test/SessionRefreshSpec.hs` (App behaviour with `TestServices`) and in
`jwksTests`, which moves with the JWKS cases if `Spec.hs` must shrink.

**M3.** Amend ADR 15's Consequences with one paragraph, run the gates, and land.


## Concrete Steps

From the repository root:

```bash
cd cli/nagare-access && cabal build nagare-access-test && cabal test nagare-access-test --test-show-details=streaming
```

Expected: the new `refresh coalescer` and `session refresh` groups pass, along with every
existing case, and the run ends with `All N tests passed`.

```bash
just haskell-style-check && python3 scripts/check-haskell-architecture.py
```

Expected: both exit 0. Check `$?`, not grep output.

After committing:

```bash
just gate-fast && just land HEAD
```

The read-only intranet query used for M0 and for the intranet deliverable:

```bash
K=$(echo ${XDG_STATE_HOME:-$HOME/.local/state}/nagare/intranet/prepared-kubeconfig/*.yaml)
Q="set default_transaction_read_only=on; select event_type, count(*) from shomei.shomei_auth_events where created_at > now() - interval '1 day' group by 1 order by 2 desc;"
kubectl --kubeconfig "$K" -n nagare-system exec shomei-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -c "$0"' "$Q"
```


## Validation and Acceptance

- The real-Shomei case in `test/SessionRefreshSpec.hs` fails with the coalescer bypassed and
  passes with it. This is the behavioural proof of M1.
- With `refreshUserSession` returning `LoginUnavailable`, a document request to a protected host
  that carries an expired session and a valid refresh cookie answers 503. No response header
  starts with `nagare_session=;` or `nagare_refresh=;`.
- With `refreshUserSession` returning `LoginFailed`, the same request still redirects to sign-in
  and clears both cookies (an existing test).
- With `verifyCredential` returning `VerificationUnavailable`, the request answers 503 and
  `refreshUserSession` is never called.
- Intranet confirmation is the last Progress item. It runs only after a release.


## Idempotence and Recovery

Every step is a code change under test, and the intranet query is read-only
(`default_transaction_read_only=on`). Reverting the landed commit restores today's behaviour.
The coalescer holds no state across restarts.


## Interfaces and Dependencies

```haskell
-- cli/nagare-access/src/Nagare/Access/Auth.hs
data LoginOutcome
  = LoginSucceeded !SessionTokens
  | LoginMfaRequired !MfaChallenge
  | LoginFailed !Text
  | LoginUnavailable !Text

-- cli/nagare-access/src/Nagare/Access/RefreshCoalescer.hs
newRefreshCoalescer :: Int -> IO Int -> IO RefreshCoalescer   -- window seconds, monotonic clock
coalesceRefresh :: RefreshCoalescer -> (Text -> IO LoginOutcome) -> Text -> IO LoginOutcome
```

The plan adds no dependencies. SHA-256 comes from the crypton `Crypto.Hash` module that
`Cookie.hs` already uses, and concurrency uses `base`'s `MVar`.
