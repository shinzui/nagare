---
type: Improvement Request
title: Deliver rotated session cookies before waiting on the upstream
description: Answer a GET or HEAD that rotated the refresh token with an immediate 307 carrying the new cookies, so a slow upstream and a dropped request cannot lose the token and end the session.
timestamp: "2026-11-01T21:52:18Z"
generated:
  by: process:claude-code
  at: "2026-11-01T21:52:18Z"
requestId: IR-41
status: proposed
origin: mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option
acceptanceCriteria:
  - id: AC-1
    statement: A GET or HEAD with an expired access token and a valid refresh token, which leads a refresh, is answered with a 307 to the same path and query, carrying the rotated cookies and Cache-Control no-store, without contacting the upstream.
    verification: An App test with a counting fake upstream asserts the status, Location, both Set-Cookie headers, no-store and zero upstream calls, for a protected backend and for the portal backend.
  - id: AC-2
    statement: The retry that carries the new cookies is served normally, with no second refresh.
    verification: The same test follows the redirect with the returned cookies and asserts one Shomei refresh and one upstream call.
  - id: AC-3
    statement: Requests that cannot safely be redirected, meaning other methods and WebSocket upgrades, are forwarded with the cookies on the upstream response, as they are today.
    verification: App tests for POST with a body and for a GET with an Upgrade header assert the upstream is called and the cookies are on its response.
  - id: AC-4
    statement: A client that does not store cookies gets at most one redirect. A request that reuses a refresh already in flight or settled in the coalescer's window is forwarded with the cookies on its response.
    verification: An App test repeats the request with the original cookies, asserts a 307 and then an upstream response, and asserts one Shomei refresh.
  - id: AC-5
    statement: A concurrent burst carrying one refresh token produces one Shomei refresh and one redirect.
    verification: A concurrency test sends several requests with one token and asserts the counts of refreshes, redirects and upstream calls.
  - id: AC-6
    statement: In a real browser, the rotated cookies survive when the request is abandoned after the 307 arrives, and the next refresh after the coalescer window raises no reuse alarm.
    verification: A browser test holds the upstream, aborts the page's fetch after the redirect, waits past the window and asserts that the session is still active and Shomei recorded no refresh_token_reuse_detected.
  - id: AC-7
    statement: The documentation states how a 307 behaves for fetch with redirect error or manual, for credentialed cross-origin fetch, and for EventSource, based on tests in Chromium, Firefox and WebKit.
    verification: The browser tests cover each case in each engine, and the guide records which ones store the cookies and which ones fail the request.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-01T21:52:18Z"
    document_timestamp: "2026-11-01T21:52:18Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against cli/nagare-access/src/Nagare/Access/App.hs,
      RefreshCoalescer.hs, and gateway and Shomei records from the labs intranet.
      The design has not been built or tested in a browser.
---

# Deliver rotated session cookies before waiting on the upstream

nagare-access spends a refresh token before it can deliver the replacement. It
rotates the token when the request arrives, then waits for the upstream, and only
then sends `Set-Cookie` on the upstream's response (`handleProtected` and
`handlePortal` in `cli/nagare-access/src/Nagare/Access/App.hs`). If the browser
drops the request during that wait, it keeps the spent token. Its next refresh
looks like theft, and Shōmei correctly revokes the session.

On `mori://tan/tan-ng-labs` this signed a user out of two 365-day sessions in
about a day.

## Evidence

Labs records from 2026-10-28 20:45Z to 2026-11-01 21:00Z, running the enforcer
deployed with v0.11.0. `cli/nagare-access` has no changes between v0.11.0 and
v0.14.1. Of 55 rotations, 45 had matching Chrome requests in the gateway logs, and
11 of those had a request dropped (Envoy status `0`, flag `DR`):

| What happened after the drop | Rotations | Signed out |
|---|---|---|
| Another request received the new cookie at the same moment | 7 | No |
| All dropped, and another request followed within 30 seconds | 2 | No |
| All dropped, and no request followed within 30 seconds | 2 | Yes, both |

| | First sign-out | Second sign-out |
|---|---|---|
| Rotation | 2026-10-31 17:50:46Z | 2026-11-01 19:41:19Z |
| Dropped | 1 request after 1.75s | 4 requests after about 1.17s |
| Upstream answered after | 2.07s | 1.36s and later |
| Reuse alarm | 18:25:11Z | 19:56:01Z |

The two survivors were saved by the coalescer's 30-second window
(`RefreshCoalescer.hs`, `defaultRefreshReuseSeconds`). This is a small sample, but
it fits the mechanism in all 11 cases.

Labs can only remove its own causes. It found a 2-second abort on a portal analytics
fetch, involved in all 11 drops, and is removing it. The second sign-out had a
different cause: every request on the page dropped together before that timer
fired. Other whole-page drops appear in the logs too, and any browser can close a
tab, navigate, sleep or lose its network during the wait.

## Proposal

When a GET or HEAD leads a refresh, stop there and answer with a 307 to the same
path and query, carrying the rotated cookies and `Cache-Control: no-store`, without
contacting the upstream. The browser stores the cookies and retries, and the retry
is served normally. The token is then at risk only for one round trip to the
enforcer instead of for the upstream's latency. On labs that is about 18ms, measured
from a 401 answered by the enforcer, compared with 1.4s to 2.1s.

This costs one extra round trip per refresh, and nothing changes in Shōmei.

### Cases the design must handle

- **Redirect loops:** a client that does not store cookies would present the old
  token again and could be redirected until its limit. `coalesceRefresh` should tell
  the caller whether it led the refresh. Only a leader redirects; a request that
  joined or reused a refresh is forwarded with the cookies on its response, which
  also means a burst causes one redirect rather than one per request.
- **Requests that cannot be redirected:** other methods and WebSocket upgrades keep
  today's behavior and today's exposure. A POST could use a 307 too, but streamed
  bodies cannot be replayed, so this request leaves POST out.
- **`redirect: "error"` and `"manual"`:** these fetches will not follow the 307, so
  the request fails even if the browser keeps the cookies. Whether it keeps them
  needs testing. The labs portal's two analytics fetches use `redirect: "error"`, and
  the identity fetch also rejects `response.redirected`. They are often the first
  request after returning to a tab, so they would often lead a refresh. Labs must
  allow the redirect on them before this ships, or they fail on every refresh they
  lead, and they may lose the token as they do today.
- **Cross-origin credentialed fetch and EventSource:** these need testing in each
  browser engine.

The remaining risk is a request dropped during that one round trip. That should be
rare, but it is not zero.

## Alternatives rejected

- **Accept a replayed token when its replacement is unused:**
  `mori://shinzui/shomei/okf/improvement-requests/concepts/IR-4` proposed this and was
  rejected because it makes Shōmei less secure. Spent tokens would become usable
  credentials: on labs a replacement sat unused for a median of 57
  minutes, 19.9 hours at the 90th percentile and up to 10 days.
- **Lengthen the coalescer's window:** this has the same exposure, and the window is
  lost on every enforcer restart.
- **Keep tokens in the enforcer behind an opaque session cookie:** a lost response
  could then lose nothing, but the enforcer would need durable session storage, and
  the browser cookie would become a non-rotating credential. This remains the option
  to revisit if the remaining risk proves too high.
