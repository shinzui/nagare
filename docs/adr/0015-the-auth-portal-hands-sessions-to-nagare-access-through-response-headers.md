---
title: "The auth portal hands sessions to nagare-access through response headers"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/117-let-operators-deploy-their-own-authentication-portal-for-protected-sites.md
  - docs/user/auth-portal.md
  - docs/user/access.md
---

# ADR 15 — The auth portal hands sessions to nagare-access through response headers

## Status

Accepted, 2026-09-13. Implemented by
[ExecPlan 117](../plans/117-let-operators-deploy-their-own-authentication-portal-for-protected-sites.md).

## Context

Nagare's built-in sign-in page kept authentication simple but could not provide an
operator's brand, password-reset pages, account management, or complete passkey flows.
An operator-owned portal needs to call Shomei with passwords and authenticated access
tokens, then establish the same parent-domain browser session used by every protected
host.

Sharing the `nagare-access` cookie-signing key with an arbitrary portal would couple the
app to the enforcer's private cookie format and let a portal forge sessions. Passing
access and refresh tokens through redirects or auto-submitted browser forms would put
credentials in browser-visible content, logs, and history. Letting both components use
the same refresh token is also unsafe because Shomei detects reuse and revokes the whole
session.

The portal cannot call Shomei directly from browser JavaScript: Shomei is intentionally
cluster-internal and does not provide a cross-origin browser API. The portal therefore
acts as a server-side UI adapter while the enforcer remains the session authority.

## Decision

`nagare-access` remains the only component that sets or verifies `nagare_session` and
`nagare_refresh`, and the only component that receives the cookie-signing key. It strips
those cookies and `__Host-nagare_csrf` before proxying to every upstream.

Exactly one backend-map entry may have role `portal`. Anonymous requests reach that
upstream with client-supplied identity and authorization headers removed. Authenticated
requests receive `X-Forwarded-User` and `Authorization: Bearer <access-token>` so the
portal can render and mutate the user's Shomei account.

After completing authentication, the portal returns an internal
`Nagare-Session-Establish` response header containing unpadded base64url JSON with the
Shomei access token, refresh token, and optional return URL. `nagare-access` honors this
header only from the configured portal upstream, removes it before replying to the
browser, verifies the access token, and immediately refreshes the supplied refresh token.
Only the rotated token pair enters the enforcer's cookies. Return URLs are restricted to
HTTPS hosts in the backend map and safe absolute paths.

`Nagare-Session-Clear` is the corresponding portal-only request to revoke and clear a
session. `/_nagare/logout` remains the normal browser route and also revokes the Shomei
session.

Fixed portal paths cover login, account recovery, account and passkey management, and
branded 403/503 pages. Branded errors are fetched server-side with a two-second timeout,
256 KiB cap, and built-in fallback. `/_nagare/login?builtin=1` keeps the original form
available as a break-glass path.

## Consequences

Operators can build and deploy the portal as an ordinary Nagare app without receiving a
platform secret. They may change its implementation and brand while preserving the
documented path and header contract. The backend map and portal host become the trust
anchor, so the resolver permits only one portal and deletion must remove its routing and
Shomei origin.

The portal is still security-sensitive: users submit passwords to it and authenticated
requests carry access tokens. Its code, dependencies, logging, and deployment access need
credential-handler review. Compromise does not reveal the cookie key or reusable refresh
cookie, and a handed-off refresh token becomes useless after rotation.

Protected apps no longer receive Nagare's session cookies. They trust
`X-Forwarded-User` only on their cluster-internal path behind `nagare-access`. A forged
handoff header from a protected upstream is stripped and cannot establish a session.

Because the enforcer is the only holder of the refresh cookie, it is also the only place a
browser session can be refreshed twice. Concurrent requests carrying one refresh token share
a single Shomei refresh, and for 30 seconds afterwards a late request with the old token
receives the pair already obtained instead of spending it again, which would trigger Shomei's
reuse revocation. Only Shomei's explicit 4xx rejection ends a session: when Shomei or its
keys are unavailable the enforcer answers 503 and keeps the cookies
([ExecPlan 211](../plans/211-keep-protected-site-sessions-across-concurrent-refreshes-and-shomei-outages.md)).

A refresh spends the old token before the replacement reaches the browser, so a request dropped
while its site responded used to lose the session. A GET or HEAD that leads a refresh is now
answered at once with an empty 307 to itself carrying the rotated cookies, after the new access
token verifies and before authorization or any upstream contact. Only the coalescer's leader may
answer this way, which gives a burst one redirect and a client that stores no cookies at most
one. Other methods, requests with `Origin`, unsafe paths and upgrades are still forwarded with
the cookies on the response. WAI cannot decorate a raw response, so the forwarders must write
rotated cookies into the WebSocket handshake themselves; an upgrade stays exposed until that
handshake arrives
([ExecPlan 239](../plans/239-deliver-rotated-session-cookies-before-waiting-on-the-upstream.md)).

A sign-in may ask to stay signed in. The portal forwards the person's choice to Shomei as
`remember` on password sign-in, MFA completion and passkey completion; Shomei records it on
the session, gives a remembered session its longer `rememberedSessionTTL`, and reports
`remembered` with every token pair, including every refresh. The enforcer keeps no state of
its own for it: a remembered session gets persistent cookies, any other session
browser-session cookies without `Max-Age`, and the choice survives every renewal because each
refresh reports it again. An absent `remembered`, from a Shomei that predates it, keeps the
cookies persistent. The handoff header is unchanged.
