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
