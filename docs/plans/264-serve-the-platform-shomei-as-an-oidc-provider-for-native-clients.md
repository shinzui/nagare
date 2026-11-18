---
id: 264
slug: serve-the-platform-shomei-as-an-oidc-provider-for-native-clients
title: "Serve the platform Shomei as an OIDC provider for native clients"
kind: exec-plan
created_at: 2026-11-17T23:37:14Z
intention: "intention_01m7nxy63wemh92j515ya60z28"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-17T23:37:14Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-17T23:52:58Z
      mode: "update"
      note: "Added the six constraints Mori's client and registry enforce as tested acceptance, Mori's redirect URI and scope, the in-cluster JWKS check, and release timing"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T00:39:18Z
      mode: "implement"
      note: "M1 and M2 implemented and tested"
---

# Serve the platform Shomei as an OIDC provider for native clients

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Nagare's auth plane runs Shomei, the identity service that signs every intranet user in.
Today only protected web sites can use it: Shomei is reachable only inside the cluster, its
token issuer is the opaque string `nagare-shomei`, and its OpenID Connect (OIDC) endpoints
are switched off. A command-line tool or a separate service therefore cannot sign a person
in with their intranet identity. The first consumer is the team's shared Mori registry
(`mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot`),
whose `mori-lite login` opens a browser, runs the OAuth authorization-code flow with PKCE
against a loopback redirect, and whose publisher uses a service account.

This plan implements the improvement request
[IR-47](../improvement-requests/serve-the-platform-shomei-as-an-oidc-provider-for-native-clients.md).
After it, an operator sets one context variable, `NAGARE_AUTH_ISSUER`, to the `https` origin
of the context's auth portal, for example `https://auth.labs.topagentnetwork.net`. Then:

- Shomei and the access enforcer `nagare-access` both use that URL as the token issuer, and
  Shomei runs with OIDC enabled.
- That origin publicly serves four Shomei endpoints and nothing else of Shomei's API:
  `GET /.well-known/openid-configuration`, `GET /.well-known/jwks.json`,
  `GET /oauth/authorize` and `POST /oauth/token`.
- A browser already signed in to the intranet completes an authorization request without
  signing in again. An anonymous one is sent to the portal's `/login` and comes back.
- A Shomei service account gets a `client_credentials` token from a workstation.

A context that does not set the variable keeps `nagare-shomei`, keeps OIDC off, and plans
no change.

To see it working on a local cluster with the variable set:

```bash
curl -s --cacert /tmp/nagare-local-ca.pem \
  https://auth.127-0-0-1.sslip.io/.well-known/openid-configuration | jq '{issuer, code_challenge_methods_supported}'
```

```json
{"issuer": "https://auth.127-0-0-1.sslip.io", "code_challenge_methods_supported": ["S256"]}
```


## Progress

- [x] M1: `NAGARE_AUTH_ISSUER` is parsed, refused when malformed, and rendered into both
  workloads from one value (IR-47 AC-1, and the environment half of AC-2). Acceptance:
  `nagarectl-test` cases listed under Validation pass; the two workloads' native bytes for a
  context without the setting equal the digests pinned before any source change.
  Done 2026-11-18: the seven cases of `test/InventoryAuthIssuerSpec.hs` pass, and the whole
  `nagarectl-test` suite passes. The pins (`e9fab8df…` for Shomei, `6f61ec08…` for the
  enforcer) were read on the untouched tree with every source change stashed. With the
  setting only those two members change; without it every auth member's bytes are as
  before, which is the evidence for "no operation" (no separate planner run).
- [x] M2: `nagare-access` serves the four endpoints on the issuer host and nothing else of
  Shomei (the routing half of AC-3, and AC-4). Acceptance: `nagare-access-test` cases against
  a real Shomei server run a full authorization-code flow with PKCE and a
  `client_credentials` grant through the enforcer, and show `/v1/admin/users`,
  `/v1/auth/signup`, `/oauth/userinfo` and `/metrics` are not answered by Shomei.
  Done 2026-11-18: the eleven cases of `test/OidcProviderSpec.hs` pass against a real Shomei
  with the platform's OIDC settings and its rate limiter, and the whole suite passes (247
  tests). `parseReturnTarget` accepts Shomei's `return_to` unchanged, so it was not widened.
- [x] M3: Confirmed on a disposable `mode=local` context (AC-2 to AC-5): public discovery,
  anonymous redirect to `/login`, signed-in authorization to a loopback redirect, code
  exchange, signature check against the public JWKS, service-account token, and the move
  from `nagare-shomei` to the URL issuer with a signed-in session.
  Done 2026-11-18 by `scripts/oidc-issuer-drill.sh` on a disposable `ep264` context that
  `NAGARE_DRILL_BOOTSTRAP_ONLY=1 scripts/site-access-drill.sh` bootstrapped with the
  packaged nagarectl `2cbfef8d` and the en, shomei and nagare-access images built from it
  (`ep264-eb9e9388`). Without the setting the converged platform planned 0 operations.
  With it the review named `Shomei issuer https://auth.127-0-0-1.sslip.io with OIDC
  enabled` on exactly one operation; both workloads carried the issuer; discovery answered
  200 with the issuer, the two exact endpoint URLs and `S256`; `/v1/admin/users`,
  `/metrics` and `/oauth/userinfo` were the portal's 404. An anonymous authorize went to
  `<issuer>/login?return_to=…`; the reference portal signed the user in and handed the
  session back to that exact authorization request; the signed-in authorize answered 302 to
  the loopback URI with `state` and `iss`; the code exchange and a refresh answered 200; the
  code-flow and service-account tokens verified against the key set fetched from the
  workstation (`typ` `at+jwt`, exact `iss`, `aud` `"nagare-access"`, a `sid`). An access
  token minted before the move was refused (401); the cookie jar from before the move
  reached the protected site with 200 after 0 new sign-ins and authorized a client. Moving
  back (setting unset) restored `nagare-shomei` with OIDC off. From a Pod in `personal`,
  the public key set did not answer (`000`): locally the portal name resolves to the Pod's
  own loopback, so this says nothing about labs, where the 2026-11-17 read reached it.

- [x] M4: The access, auth-portal and contexts guides document the setting, the endpoints,
  the single audience, and registering a public client and a service account (AC-6), and an
  ADR records the routing decision. Acceptance: a reader follows the guides on a fresh
  local context to the M3 results without opening source.
  Done 2026-11-18: `docs/user/access.md` "Sign in native clients and services",
  `docs/user/auth-portal.md`, `docs/user/contexts.md` and ADR 40. The M3 drill follows the
  guides' commands (the setting, `shomei-admin oauth-clients create` and `service-accounts
  create` through `kubectl exec deploy/shomei`, the `client_credentials` request) and reaches
  the M3 results.

- [ ] M5: Released, and the labs intranet context runs with its URL issuer. Acceptance: the
  release proves the three release facts; on labs, after the reviewed issuer move, the
  deploy-and-login check passes, the public discovery document reports the issuer, and
  IR-47's status is updated. Needs the operator's go-ahead before any labs mutation.


## Surprises & Discoveries

- Shomei at `6179d567` does have a trusted-proxy setting, `SHOMEI_TRUSTED_PROXIES`
  (`shomei-server/src/Shomei/Server/Config.hs`, `trustedProxiesEnv`), which the Context
  section said it lacks. The limiter is one token bucket per client address over every
  throttled route (signup, login, MFA, `/oauth/token`): a burst of 60, refilled at 60 a
  minute. The first consumer's fifteen-minute load plus ten failed grants, sent at once,
  passes through the enforcer's one address; failed grants count only as requests. A single
  client sending more than 60 throttled requests a minute would still exhaust the bucket for
  everyone, sign-ins included. The remedy needs no pin move: the enforcer would send
  `X-Forwarded-For` and Shomei would trust the enforcer's Pod range. Not decided here; for
  the operator.
- Every Shomei access token carries `aud` as the string `"nagare-access"`, not a one-element
  array: jose renders a single audience as a string, which RFC 7519 allows. Concrete Steps'
  expected output is corrected; Mori's audience check must accept the string form.


## Decision Log

- Decision: The issuer origin is the registered auth portal's origin, and `nagare-access`
  serves the four endpoints there by proxying them to the private Shomei Service.
  Rationale: The portal host is already routed to `nagare-access`, which holds the browser's
  intranet session cookies and already turns them into the `Authorization: Bearer` access
  token Shomei's `/oauth/authorize` reads. No new DNS name, certificate, route or public
  Shomei Service is needed, and nothing but an exact list of four method-and-path pairs
  reaches Shomei. A separate public route of the Shomei Service would expose `/v1/auth/signup`,
  `/v1/admin/*` and `/metrics` unless filtered, and would not see the session, because the
  session cookie belongs to `nagare-access`, not to Shomei.
  Date: 2026-11-17
- Decision: One context variable, `NAGARE_AUTH_ISSUER`. It must be `https://HOST` with no
  port, path, trailing slash, query, fragment or user info. The platform plan refuses it
  unless the accepted inventory registers a portal on exactly `HOST`, and a portal deploy
  refuses a host that differs from a set issuer's host.
  Rationale: Shomei publishes the issuer verbatim and compares `iss` exactly, so
  `https://x` and `https://x/` are different issuers; Shomei serves only at the root, so a
  path would need rewriting. Tying the issuer to the portal host makes the login URL
  `<issuer>/login` a plain derivation with nothing to keep in step.
  Date: 2026-11-17
- Decision: The enforcer takes no new variable. It serves the OIDC endpoints when its
  existing `NAGARE_ACCESS_SHOMEI_ISSUER` is an `https://` URL, on that URL's host.
  Rationale: IR-47 AC-1 asks that the two issuer values cannot diverge; a second switch
  could.
  Date: 2026-11-17
- Decision: The packaged manifests stay byte-identical. The auth component rewrites the two
  issuer values and appends the OIDC variables only when the setting is present.
  Rationale: The manifests are digest-pinned, the legacy installers render them too, and a
  context without the setting must plan no operation (AC-1).
  Date: 2026-11-17
- Decision: The review states the issuer and its session effect in the summary of the
  Shomei Deployment's operation, derived from the reviewed native object, as the En tenant
  proof is.
  Rationale: AC-5 asks that the review name the change and its effect. The summary is the
  operator-facing text of an operation, and deriving it from the reviewed bytes needs no new
  review field or wire format.
  Date: 2026-11-17
- Decision: The audience stays `nagare-access` for every token, and `userinfo`,
  `introspect` and `revoke` are not served although Shomei's discovery document names them.
  Rationale: IR-47 asks for exactly four endpoints and keeps the single audience.
  Date: 2026-11-17
- Decision: Acceptance includes six constraints Mori's client and registry enforce, taken
  from the Mori session's review of this plan against `mori://shinzui/mori` (its
  `mori-client/src/Mori/Client/Auth/Oidc.hs`, `mori-api/src/Mori/Api/Access/Shomei.hs` and
  `mori-api/src/Mori/Api/Access/Jwks.hs`, artifact-level URIs pending). They are listed
  under "What the first consumer enforces" and each has a test. The design is unchanged.
  Rationale: Each would break `mori-lite login` or the registry's token check without
  failing any test the plan had. Mori confirmed it calls none of `userinfo`, `introspect`
  and `revoke`, requests only the `openid` scope, and keeps the in-cluster JWKS fetch as
  its own work.
  Date: 2026-11-17
- Decision: `nagarectl context move` refuses a context that sets `NAGARE_AUTH_ISSUER`,
  naming the issuer and what moving it would break. Carrying a URL issuer across a
  base-domain move is not part of this plan.
  Rationale: [ExecPlan 246](246-move-a-context-to-a-new-base-domain-and-carry-its-routes-grants-and-sign-in.md)
  moves a context's base domain on the stated premise that Shomei's issuer does not follow
  the domain. That holds only for the opaque `nagare-shomei`. With a URL issuer the portal
  host, and so the issuer, changes with the base domain: every token's `iss` changes and
  every consumer binding on the exact issuer stops matching. Without this refusal the move
  would flip the base and leave a platform plan that refuses on the host mismatch. The
  labs operator repository plans such a move (`mori://tan/tan-ng-labs`, its plan 14 to
  re-home the intranet onto `topagentnetworklabs.com` through a Cloudflare tunnel,
  artifact-level URI pending), so the order of that move and the labs issuer is the
  operator's decision before M5.
  Date: 2026-11-17
- Decision: At `/oauth/authorize` only the browser's session cookie names the user. A
  client's own `Authorization` header is removed before the session is resolved, so it is
  neither taken as the session nor forwarded.
  Rationale: `authenticatePortal` also accepts a bearer header as the session. Shomei mints a
  code at once with no consent page, so an access token held by one client could otherwise
  mint a code for another without the browser.
  Date: 2026-11-18
- Decision: The portal-host check runs in two places. The platform plan refuses when the
  accepted inventory registers no portal or one on another host; every candidate plan
  (`validateTarget` in `Nagare.Inventory.Command`) refuses a composed portal on a host other
  than the issuer's, which covers every reviewed deploy path at once.
  Rationale: The reviewed deploy paths (application, deployment, sites, previews) share no
  portal-specific function, but all plan through `validateTarget` with the active profile.
  A deploy is not refused for having no portal, so removing an unrelated app still plans.
  Date: 2026-11-18
- Decision: On a context behind an edge, the four endpoints' responses get the same
  `Cache-Control` tightening as every other response the enforcer proxies.
  Rationale: The plan first passed Shomei's headers through unchanged, which on a tunnel
  context would leave authorize and token responses guarded by the zone's cache-bypass rule
  alone. ADR 34 requires both controls.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**The auth plane.** Three workloads in the `nagare-system` namespace protect intranet sites.
*Shomei* (`mori://shinzui/shomei`, pinned at `6179d567`) is the identity service: it holds
users, passwords and passkeys and signs access tokens (JWTs). *En* decides who may open
which site. *nagare-access*, the "enforcer", is a Haskell reverse proxy in
`cli/nagare-access`; every protected hostname is routed to it. It verifies the session,
asks En, and forwards the request to the site. The manifests are
`cluster/bootstrap/shomei/service.yaml` (Deployment `shomei` and Service `shomei`, port 80)
and `cluster/bootstrap/nagare-access/service.yaml` (Knative Service `nagare-access`).
Shomei's Service is cluster-internal; no public hostname reaches it.

**Where the issuer is fixed today.** `cluster/bootstrap/shomei/service.yaml` sets
`SHOMEI_ISSUER=nagare-shomei` and `SHOMEI_AUDIENCE=nagare-access`.
`cluster/bootstrap/nagare-access/service.yaml` sets `NAGARE_ACCESS_SHOMEI_ISSUER=nagare-shomei`
among its environment entries (the local installer
`cluster/bootstrap/local-auth/install.sh` patches the cookie domain by its index, so
entries must not be reordered or inserted before it). Neither sets `SHOMEI_OIDC_ENABLED`, which defaults to false.

**How the manifests become a reviewed plan.**
`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs` compiles them. Its `packaged` list
pins each file's SHA-256, so the files must not be edited without updating the digest.
`AuthInput` carries what a context contributes: `authBaseDomain`, `authProxiedCacheControl`
(a recent example of an optional setting that adds environment entries only when present,
through `addEnforcerEnv`), and `authEnTenants`. `appendShomeiEnv` appends
`SHOMEI_WEBAUTHN_RP_ID`, `SHOMEI_WEBAUTHN_ORIGINS` and `SHOMEI_PUBLIC_BASE_URL` to the
Shomei container; the last two come from the ConfigMap `nagare-shomei-settings`.
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` builds `AuthInput` from the active
context (see `rawAuth`, and `retiredEnTenants` for a check that reads the accepted auth
scope from the snapshot before planning).

**Contexts.** A *context* is a flat `export VAR=value` file that selects a target. It is
parsed by `cli/nagarectl/src/Nagare/Target.hs` into `TargetProfile`; `enTenants`, parsed by
`cli/nagarectl/src/Nagare/Target/EnTenants.hs`, is the closest precedent for a new optional
field, including its rendering by `renderContextShellEnv` for `nagarectl context env`. The
schema is documented in `nagare.target.env.example` and `docs/user/contexts.md`. A
*disposable local context* is a `mode=local` k3d cluster (`docs/user/local-development.md`);
its auth plane is installed by `cluster/bootstrap/local-auth/install.sh` and its portal
host is `auth.127-0-0-1.sslip.io`.

**The auth portal.** An operator deploys one ordinary app whose access policy is
`authPortal` (`docs/user/auth-portal.md`; reference implementation in
`cluster/examples/auth-portal`, whose `server.mjs` passes `return_to` through unchanged). Its
host is routed to the enforcer in a special mode: anonymous requests reach it, signed-in
requests carry `Authorization: Bearer <access token>`. After a sign-in the portal answers
with a `Nagare-Session-Establish` header holding the tokens and a `returnTo` URL; the
enforcer sets its own cookies and redirects there. `returnTo` is accepted only when it is
`https`, names a routed host, and its path passes `safeReturnDestination` in
`cli/nagare-access/src/Nagare/Access/Challenge.hs`, which refuses a literal `://` after the
host. Registering a portal writes the declaration `ShomeiSettingsSpec baseDomain (Just
portalHost)` (`cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`), which is how a plan can
learn the registered portal host. `nagarectl` already refuses a second portal or one outside
the base domain; the new host check belongs beside that refusal.

**The enforcer's request path.** `cli/nagare-access/src/Nagare/Access/App.hs`:
`appWithRuntime` matches the `/_nagare/*` routes, then looks the `Host` up in the backend
map and calls `handleProtected` or `handlePortal`. `authenticatePortal` resolves the
session without challenging: a valid `nagare_session` cookie, or a refresh through
`refreshPortalIdentity`, which may answer an empty `307` to the same URL carrying renewed
cookies. `cli/nagare-access/src/Nagare/Access/Proxy.hs` builds upstream requests
(`portalRequestHeaders` strips client `Authorization` and adds the session's bearer token).
`cli/nagare-access/src/Nagare/Access/Config.hs` parses `NAGARE_ACCESS_SHOMEI_URL`
(`http://shomei.nagare-system.svc.cluster.local`) and `NAGARE_ACCESS_SHOMEI_ISSUER` into
`AuthPlaneConfig`; `cli/nagare-access/app/Main.hs` wires `AccessServices`
(`cli/nagare-access/src/Nagare/Access/Auth.hs`). Tests live in `cli/nagare-access/test`;
`RealShomei.hs` starts a real Shomei over a migrated test database with
`defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")`.

**Reviews.** A plan is saved as a directory whose `review.json` lists operations, each with
a `summary`. For Kubernetes objects the text comes from `summary` in
`cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`. The same adapter already
inspects a reviewed object's bytes to add behavior for one workload:
`enDeclaredTenants` in `cli/nagarectl/src/Nagare/Inventory/Adapters/EnTenants.hs`.

**Shomei facts this plan relies on** (read at `6179d567`; file names are in
`mori://shinzui/shomei`, artifact-level URIs pending):

- Settings: `SHOMEI_OIDC_ENABLED` (`true`/`false`), `SHOMEI_OAUTH_LOGIN_URL` (unvalidated
  text). With OIDC on, boot refuses an issuer that does not start with `http://` or
  `https://` (`shomei-server/src/Shomei/Server/Boot.hs`, `validateOidcIssuer`). A trailing
  slash is not refused but is published verbatim.
- Discovery (`shomei-servant/src/Shomei/Servant/Oidc.hs`): every endpoint is the issuer
  plus a root path. It advertises `code_challenge_methods_supported: ["S256"]`,
  `token_endpoint_auth_methods_supported: ["client_secret_basic","client_secret_post"]`,
  and also `userinfo`, `introspect` and `revoke` endpoints. With OIDC off it answers 404.
  `/.well-known/jwks.json` is served either way.
- `GET /oauth/authorize` (`shomei-servant/src/Shomei/OAuth/Handler.hs`) identifies the user
  from `Authorization: Bearer <access JWT>`. Shomei's own cookie is read only under a
  cookie transport Nagare does not use. Anonymous, or with a token it cannot verify, it
  answers `302` to `<login-url>?return_to=<issuer>/oauth/authorize?<the validated
  parameters>`; with no login URL, `401 login_required`. A machine or delegated session is
  refused. On success it answers `302 <redirect_uri>?code=…&state=…&iss=<issuer>` at once;
  there is no consent page. `redirect_uri` must equal a registered URI byte for byte, port
  included. A public client must send `code_challenge` with `code_challenge_method=S256`.
- `POST /oauth/token` accepts `authorization_code`, `refresh_token` and
  `client_credentials`. A confidential client or service account authenticates with HTTP
  Basic or form fields; a public client sends a bare `client_id`. A non-Basic
  `Authorization` header fails `invalid_client`. Access tokens carry `iss` = the issuer,
  `aud` = `[SHOMEI_AUDIENCE]`, `sub`, `sid`, `scopes`; a service account's `sub` is its
  backing `user_…` id and its token lasts 300 seconds with no refresh token.
- An issuer change: access tokens minted under the old issuer fail verification. Refresh
  tokens are opaque rows and still work, and the refreshed access token carries the new
  issuer. Signing keys are not tied to the issuer.
- `shomei-admin oauth-clients create --display-name TEXT --type public --redirect-uri URI
  [--scope S]…` and `shomei-admin service-accounts create --display-name TEXT [--scope S]…`
  print the `client_id` (and the secret once). They need `DATABASE_URL`, which the Shomei
  Deployment already sets, so they run with `kubectl exec deploy/shomei`.
- `POST /oauth/token` is rate-limited, and the limiter attributes a request to the
  connection's remote address (`shomei-servant/src/Shomei/OAuth/Api.hs`, `RateLimited` and
  `RemoteHost` on `TokenRoute`). At this pin Shomei has no trusted-proxy setting, so every
  token request the enforcer forwards counts against the enforcer Pod's one address, as
  sign-ins already do. The limits are in `RateLimitConfig`
  (`shomei-core/src/Shomei/Config.hs`).
- Other routes on the same port, which must stay private: `/v1/auth/*` (including an
  always-open `signup`), `/v1/admin/*`, `/oauth/userinfo`, `/oauth/introspect`,
  `/oauth/revoke`, `/health/*`, `/openapi.json`, `/metrics`.

Shomei's `master` is 50 commits past the pin and slightly stricter at `/oauth/authorize`
(it validates scope names and refuses a session with an actor). This plan does not move the
pin.

**What the first consumer enforces.** Mori's command-line client and registry were
reviewed against this plan. They need nothing beyond the four endpoints, but they refuse a
provider that breaks any of these:

- The discovery document's `authorization_endpoint` must be exactly
  `<issuer>/oauth/authorize` and its `token_endpoint` exactly `<issuer>/oauth/token`; the
  client compares strings. The redirect back to the client must carry `iss` equal to the
  issuer.
- None of discovery, JWKS and token may answer with a redirect. The registry fetches the
  JWKS with redirects disabled, a 5-second deadline and a 1 MiB limit.
- Shomei's `302` from `/oauth/authorize` to `http://127.0.0.1:PORT/PATH` must reach the
  browser unchanged. The enforcer's return-target check applies to the portal hand-off,
  never to this response.
- Any signed-in user must be able to authorize, whatever their site grants in En. The
  registry decides permission in its own En tenant.
- `POST /oauth/token` comes from a command-line program with no cookie, `Origin` or CSRF
  token.
- The issuer origin needs a publicly trusted certificate; both programs use the system
  trust store.

The client requests the scope `openid` only, and its guide registers the redirect
`http://127.0.0.1:18090/callback`. The registry requires the access token's header `typ`
`at+jwt`, exact `iss` and `aud`, `exp`, `iat` and a non-empty `sid`, and binds the exact
`(issuer, subject)` pair to a Mori principal, so the issuer must be final before any
intranet identity is bound.

**Base-domain moves.** `nagarectl context move` (ExecPlan 246, `Nagare.Context.BaseMove`
under `cli/nagarectl`, guide `docs/user/moving-to-a-new-base-domain.md`) moves a context to
a new base domain and lists its refusals by name. Its compiled-scope test in
`InventoryAuthSpec` asserts both issuer variables are byte-identical across a move.

**Labs today** (read on 2026-11-17 from the running `mori-registry` Pod in namespace
`personal`, with no object created): the Pod resolves `auth.labs.topagentnetwork.net`,
reaches it over the public address, verifies its Let's Encrypt certificate against the
image's trust store, and gets `200` from `/healthz` with no redirect. Labs serves directly,
not through a Cloudflare tunnel. An in-cluster consumer can therefore fetch the public JWKS
on labs as it stands; the result must be read again after any move behind a tunnel.

**Relevant ADRs.**
[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md):
the enforcer owns every `nagare_*` cookie and the portal hands sessions over through a
response header, which is why the authorization endpoint must pass through the enforcer to
see a session.
[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md): hostnames and
certificates are explicit and owned; this plan adds none.
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md): site access
is decided by En per hostname and is untouched; an OAuth token is not a site grant.
[ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md):
a context may sit behind a Cloudflare edge, where the enforcer tightens `Cache-Control` on
every proxied response as one of two independent cache controls, and where the edge never
challenges a machine client (Browser Integrity Check off, Bot Fight Mode and Under Attack
mode never on). The four endpoints follow the first and rely on the second.
[ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md): the Shomei pin
mirrors upstream and does not move here.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
the labs context file lives in `mori://tan/tan-ng-labs`, never here.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
defects are found by interpreter tests; the local run only confirms. No ADR covers exposing
Shomei publicly; M4 adds one.


## Plan of Work

### M1: one issuer setting, rendered into both workloads

Before changing any source, add a test to `cli/nagarectl/test/InventoryAuthSpec.hs` that
pins the content digests of the native bytes `compileAuth fixture` produces for Deployment
`shomei` and Knative Service `nagare-access`. It passes on the untouched tree and must keep
passing: it is the proof that a context without the setting renders exactly as v0.21.0 did.

Add a module `cli/nagarectl/src/Nagare/Target/AuthIssuer.hs` holding a validated
`AuthIssuer` and `parseAuthIssuer :: Map String Text -> Either Text (Maybe AuthIssuer)`.
An unset or empty `NAGARE_AUTH_ISSUER` is `Nothing`. A value is accepted only as
`https://HOST`, where `HOST` is a lower-case DNS name: no port, path, trailing slash,
query, fragment or user info. Every refusal names the variable and the rule. Add
`authIssuer :: !(Maybe AuthIssuer)` to `TargetProfile` in
`cli/nagarectl/src/Nagare/Target.hs`, parse it at both places `enTenants` is parsed, and
print it from `renderContextShellEnv`. Add the variable to `nagare.target.env.example` and
`nagare.local.env.example`. `scripts/lib/target.sh` needs no change unless a script reads
the value.

Add `authIssuer :: !(Maybe Text)` to `AuthInput` in
`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`, `Nothing` in every existing
constructor and fixture. When it is `Just issuer`, `transformSource`:

- replaces the value of the existing `SHOMEI_ISSUER` entry in the Shomei container, in
  place, and appends `SHOMEI_OIDC_ENABLED=true` and `SHOMEI_OAUTH_LOGIN_URL=<issuer>/login`
  after the three entries `appendShomeiEnv` adds;
- replaces the value of the existing `NAGARE_ACCESS_SHOMEI_ISSUER` entry in the enforcer
  container, in place.

Each replacement fails the compile if the entry is absent or appears twice. When it is
`Nothing`, nothing is touched.

In `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`, set the field from the profile.
When the setting is present, read the registered portal host from the snapshot's accepted
`ShomeiSettingsSpec` declaration and refuse to plan unless it equals the issuer's host,
with a message that tells the operator to deploy the auth portal on that host first. In the
portal registration path (where a second or out-of-domain portal is refused), refuse a
portal host that differs from a set issuer's host. Add a named refusal to
`nagarectl context move list` and the move itself for a context that sets the issuer, and
say so in `docs/user/moving-to-a-new-base-domain.md`.

In `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`, extend `summary` so that an
operation on the Shomei Deployment whose reviewed `SHOMEI_ISSUER` is an `https://` URL ends
with a clause such as: `; Shomei issuer https://HOST with OIDC enabled: tokens minted under
any other issuer are refused, so a signed-in browser renews its session and may be asked to
sign in once`. Put the detection beside `enDeclaredTenants`, in the same style.

### M2: the enforcer serves four endpoints on the issuer host

In `cli/nagare-access`, derive an optional *OIDC host* from `AuthPlaneConfig.shomeiIssuer`:
present only when the issuer parses as `https://HOST`. In `appWithRuntime`, after the
`/_nagare/*` routes and before the backend lookup, when the request's `Host` equals the
OIDC host and the method and path are one of exactly these four, proxy to
`NAGARE_ACCESS_SHOMEI_URL` at the same path and query, and return Shomei's status, headers
and body unchanged apart from hop-by-hop headers and, on a context behind an edge, the
cache headers described after this list:

- `GET /.well-known/openid-configuration` and `GET /.well-known/jwks.json`: no identity, no
  request body, no `Cookie` or `Authorization` forwarded.
- `GET /oauth/authorize`: resolve the session exactly as `authenticatePortal` does,
  including the `307` renewal answer. Drop any client `Authorization` and `Cookie`. Signed
  in, forward with `Authorization: Bearer <access token>`; anonymous, forward without it,
  so Shomei answers the redirect to `<issuer>/login?return_to=…`. Add any renewed-cookie
  headers to the response.
- `POST /oauth/token`: no session lookup. Forward the body (bounded, 64 KiB is ample),
  `Content-Type` and the client's `Authorization` header verbatim, because a confidential
  client or service account authenticates with HTTP Basic. Do not forward `Cookie`.

When `NAGARE_ACCESS_PROXIED_CACHE_CONTROL` is set, which `nagarectl` does only for a
context behind a Cloudflare edge, pass all four responses through
`withProxiedCacheControl` (`cli/nagare-access/src/Nagare/Access/EdgeCacheControl.hs`), as
`Main.hs` already does for protected sites and the portal. Authorize and token responses
carry codes and tokens, and ADR 34 keeps the enforcer's header as a control independent of
the zone's cache-bypass rule. The key set and discovery document are public, so tightening
them costs only edge caching. Without the variable the headers are untouched.

The authorize route makes no En call and consults no site grant. The token route applies
no CSRF, `Origin` or cookie requirement. The enforcer never rewrites a `Location` header
it proxies from Shomei.

Every other path on that host keeps going to the portal as today; with no OIDC host
nothing changes. Add the forwarder as a field of `AccessServices` so tests can stub it, and
wire it in `cli/nagare-access/app/Main.hs`. Do not follow redirects when proxying.

Tests go in `cli/nagare-access/test`. Give `RealShomei.hs` a variant that starts Shomei
with a URL issuer, OIDC enabled and a login URL. The representative end-to-end case, to be
written first because it exercises the one uncertain seam (Shomei's `return_to`, the
portal hand-off and `parseReturnTarget`): an anonymous authorize is redirected to
`/login?return_to=…`; that exact `return_to`, handed back in a `Nagare-Session-Establish`
header, is accepted by `parseReturnTarget`; the follow-up authorize with the session
cookie answers `302` to the registered `http://127.0.0.1:PORT/PATH` with a `code`; the code
is exchanged at `/oauth/token`; the token's `iss` is the issuer and it verifies against
the JWKS fetched through the enforcer. If `parseReturnTarget` refuses the value (for
example because the query holds an unencoded `://`), widen it for the OIDC host's
`/oauth/authorize` path only, and record the finding.

### M3: native confirmation on a disposable local context

Complete `docs/runbooks/before-a-native-run.md`. On a fresh `mode=local` context with the
auth plane and the reference portal installed and no issuer set, sign a test user in to a
protected site and keep the cookie jar. Then set
`NAGARE_AUTH_ISSUER=https://auth.127-0-0-1.sslip.io`, save the platform plan, read its
review, apply it, and run the checks under Validation. This milestone changes no design; a
defect found here is first reproduced in an interpreter test.

### M4: guides and ADR

`docs/user/access.md` gains a section "Sign in native clients and services" covering the
setting, the four public endpoints, what is deliberately not served, the single audience
`nagare-access` and what a consumer must therefore check itself, the session effect of
changing the issuer, that the issuer is in practice permanent once a consumer has bound
identities to it (Mori binds the exact `(issuer, subject)` pair, so a later change of the
portal host orphans every binding and each must be made again), and the two `shomei-admin` commands run through
`kubectl -n nagare-system exec deploy/shomei`. `docs/user/auth-portal.md` states that the
enforcer answers the four paths on the portal host before the portal sees them, that a
custom portal must return `return_to` unchanged, and that the portal host and the issuer
host must match. `docs/user/contexts.md` lists the variable. Add an ADR for the routing
decision following the conventions of `docs/adr/`, and update IR-47's status following its
bundle's profile.

### M5: release and the labs issuer

Cut the release with the `nagare-release` skill; the `nagare-access` image digest changes,
so `release.json` `releaseImages` is regenerated. After the labs context has moved to the
release, the operator sets `NAGARE_AUTH_ISSUER` in `mori://tan/tan-ng-labs`
(`contexts/intranet.env`, artifact-level URI pending) to the labs portal origin, and the
plan is saved, reviewed and applied with the operator's go-ahead. The labs portal is the
operator's own app (`web/apps/portal` there), so confirm on labs that it returns
`return_to` unchanged. Mori needs this release before its plan 302 M2 settings and M3
pilot, and the issuer must be moved before any intranet identity is bound to a Mori
principal; none is bound yet.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`.

Build and test (M1, M2):

```bash
(cd cli/nagarectl && cabal test nagarectl-test)
(cd cli/nagare-access && cabal build all && cabal test nagare-access-test)
just haskell-style-check
just gate-fast
```

Expected: both suites end with `0 failures`. `just gate-fast` gates the committed revision,
so commit first. Land with `just land`.

Local confirmation (M3), with the packaged `nagarectl` built from the commit under test:

```bash
nix build "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
nagarectl --context local platform bootstrap plan --out ./issuer-review
jq -r '.operations[].summary' ./issuer-review/review.json | grep 'Shomei issuer'
nagarectl --context local platform bootstrap apply ./issuer-review --yes
```

Expected from the `jq` line: one summary naming `https://auth.127-0-0-1.sslip.io` and the
session effect.

Register a public client and a service account:

```bash
kubectl --context k3d-nagare-local -n nagare-system exec deploy/shomei -- \
  env LC_ALL=C.UTF-8 shomei-admin oauth-clients create --display-name cli --type public \
    --redirect-uri http://127.0.0.1:18090/callback --scope openid
kubectl --context k3d-nagare-local -n nagare-system exec deploy/shomei -- \
  env LC_ALL=C.UTF-8 shomei-admin service-accounts create --display-name publisher
```

Expected: a `client_id: oauthclient_…` with `client_secret: (none - public client; …)`,
and a `client_id: svcacct_…` with a secret shown once.

Authorization-code flow with PKCE, from the workstation (`$JAR` is the cookie jar of a
signed-in session, `$CA` the exported local CA):

```bash
ISS=https://auth.127-0-0-1.sslip.io
VERIFIER=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-43)
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | basenc --base64url | tr -d '=')
curl -s -o /dev/null -D - --cacert "$CA" -b "$JAR" -G "$ISS/oauth/authorize" \
  --data-urlencode response_type=code --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode redirect_uri=http://127.0.0.1:18090/callback --data-urlencode scope=openid \
  --data-urlencode state=s1 --data-urlencode "code_challenge=$CHALLENGE" \
  --data-urlencode code_challenge_method=S256 | grep -i '^location:'
curl -s --cacert "$CA" "$ISS/oauth/token" -d grant_type=authorization_code \
  -d "client_id=$CLIENT_ID" -d "code=$CODE" -d "code_verifier=$VERIFIER" \
  --data-urlencode redirect_uri=http://127.0.0.1:18090/callback | jq '{token_type, expires_in}'
```

Expected: `location: http://127.0.0.1:18090/callback?code=…&state=s1&iss=https://auth.127-0-0-1.sslip.io`,
then a 200 with an `access_token`. Without `-b "$JAR"` the first command's location is
`https://auth.127-0-0-1.sslip.io/login?return_to=…`.

Service-account token:

```bash
curl -s --cacert "$CA" -u "$SVC_ID:$SVC_SECRET" "$ISS/oauth/token" -d grant_type=client_credentials \
  | jq -r .access_token | cut -d. -f2 | basenc --base64url -d 2>/dev/null | jq '{iss, aud}'
```

Expected: `{"iss": "https://auth.127-0-0-1.sslip.io", "aud": "nagare-access"}`.


## Validation and Acceptance

- **M1** (`nagarectl-test`):
  - with `authIssuer = Just "https://auth.apps.example.com"`, the Shomei Deployment's
    `SHOMEI_ISSUER` and the enforcer's `NAGARE_ACCESS_SHOMEI_ISSUER` both equal it,
    `SHOMEI_OIDC_ENABLED` is `true`, and `SHOMEI_OAUTH_LOGIN_URL` is
    `https://auth.apps.example.com/login`;
  - with `Nothing`, both issuers are `nagare-shomei`, neither OIDC variable exists, the
    native digests equal the pinned ones, and planning that candidate against an inventory
    accepted from the same input yields no operation;
  - `http://auth.example.com`, `https://auth.example.com/`, `https://auth.example.com/x`,
    `https://auth.example.com:8443`, `https://user@auth.example.com` and `auth.example.com`
    are each refused at context parsing, and an empty value is unset;
  - a platform plan with the setting and no registered portal, or a portal on another host,
    is refused before any operation is proposed; a portal deploy on a host other than the
    issuer's is refused; `context move list --base-domain NEW` on a context with the
    setting is refused by name, and without the setting behaves as before;
  - the Shomei Deployment's summary names the issuer and the session effect when the
    setting is present, and is unchanged when it is not.
- **M2** (`nagare-access-test`, against a real Shomei):
  - `GET /.well-known/openid-configuration` on the issuer host returns 200 with `issuer`
    equal to the setting and `S256`; the same path on a protected host does not reach
    Shomei;
  - the end-to-end case described in M2 passes, including the JWKS signature check;
  - the discovery document's `authorization_endpoint` and `token_endpoint` equal
    `<issuer>/oauth/authorize` and `<issuer>/oauth/token` exactly;
  - discovery, JWKS and token answer directly, never with a 3xx, including for a request
    that carries an expired session cookie;
  - the `Location` of a successful authorize is the registered loopback URI with `code`,
    `state` and `iss` equal to the issuer, byte for byte as Shomei sent it;
  - a signed-in user with no En relationship of any kind authorizes successfully, and the
    En stub records no call;
  - a client-supplied `Authorization: Bearer` on `/oauth/authorize` is not forwarded;
  - `POST /oauth/token` with `grant_type=client_credentials` and HTTP Basic returns 200
    with `iss` = the issuer and `aud` = the configured audience, with no cookie, `Origin`
    or CSRF token on the request; the same holds for a public client's code exchange and
    refresh;
  - `GET /v1/admin/users`, `POST /v1/auth/signup`, `GET /oauth/userinfo`,
    `POST /oauth/introspect`, `GET /metrics`, `GET /openapi.json` and `POST /oauth/authorize`
    on the issuer host are forwarded to the portal upstream, never to Shomei;
  - with the issuer `nagare-shomei`, all four paths go to the portal as before;
  - with the edge cache header configured, each of the four responses carries `private`
    and `no-transform`, never `public` or `s-maxage`, and no `CDN-Cache-Control`,
    `Cloudflare-CDN-Cache-Control` or `Surrogate-Control`, and a response Shomei sent with
    no `Cache-Control` gets the configured value; without it, each response's
    `Cache-Control` is exactly Shomei's;
  - a rate-limit case: read the limits that apply to `/oauth/token` from Shomei's
    `RateLimitConfig`, then drive the real Shomei through the enforcer with the load the
    first consumer makes (one `client_credentials` grant every 270 seconds and one refresh
    per signed-in teammate every 15 minutes, for twenty teammates) plus ten failed grants
    from another client, and assert the valid grants still succeed. If one client's
    failures can lock out the others, stop and record it in the Decision Log for the
    operator. (They cannot; see Surprises & Discoveries for what volume can do.)
- **M3** (local context): the Concrete Steps outputs appear. Additionally: the token from
  the code exchange verifies against `$ISS/.well-known/jwks.json` fetched from the
  workstation; `curl "$ISS/v1/admin/users"` and `curl "$ISS/metrics"` are answered by the
  portal (404), not Shomei; an access token minted before the issuer move gets no access
  to the protected site as a bearer token; the cookie jar from before the move reaches the
  protected site with 200 after at most one new sign-in. From a Pod in the
  `personal` namespace, `curl` the issuer's `/.well-known/jwks.json` and record in Progress
  whether in-cluster traffic reaches the public origin; either result is acceptable, and a
  failure is reported to Mori, which then adds its own cluster-local fetch setting.
- **M4**: the guide walk-through on a fresh local context reaches the M3 outputs.
- **M5**: the release record shows the full gate green and the EP-172 rehearsal read-back
  passing; labs passes deploy-and-login after the release move and again after the issuer
  move; `curl https://<labs portal>/.well-known/openid-configuration`, with no CA option
  so the system trust store is used, reports the issuer and the two exact endpoint URLs;
  the JWKS fetch from a Pod in `personal` on labs is recorded.
  Mori's own acceptance is recorded in Mori's plan 302, not here.


## Idempotence and Recovery

Planning and applying again is safe: the setting only changes environment values, and a
second plan has no operations. Signing keys, users, OAuth clients and service accounts
live in `shomei-db` and are untouched by an issuer change.

Moving the issuer rolls Shomei first and the enforcer after it (the enforcer already waits
for the Shomei Deployment). Between the two rolls Shomei mints tokens the old enforcer
refuses, so a sign-in attempted in that window fails and a browser that renews its session
in that window is signed out. Once the enforcer has rolled, a browser's old access cookie
is refused, its refresh token still works, and the renewed token carries the new issuer.
If the apply is interrupted, resume the same review.

Moving back is the same reviewed change with the variable unset; it has the same session
effect and turns OIDC off, so every client configured with the URL issuer stops working.
Tokens are not portable across the move in either direction, and neither are a
consumer's identity bindings: a consumer that bound `(issuer, subject)` pairs must bind
them again under the new issuer. Choose the portal host before the first binding.

The registered loopback redirect is matched byte for byte, so a client that picks a
different port needs its own registered URI. Any guard that refuses on labs stops the work
and is reported to the operator.


## Interfaces and Dependencies

- Context variable `NAGARE_AUTH_ISSUER`; `Nagare.Target.AuthIssuer` (`AuthIssuer`,
  `parseAuthIssuer`, a text accessor and a host accessor); `TargetProfile.authIssuer`.
- `Nagare.Inventory.Components.Auth.AuthInput.authIssuer :: !(Maybe Text)`.
- Rendered environment with the setting: `SHOMEI_ISSUER`, `SHOMEI_OIDC_ENABLED=true`,
  `SHOMEI_OAUTH_LOGIN_URL=<issuer>/login` on Shomei; `NAGARE_ACCESS_SHOMEI_ISSUER` on the
  enforcer. `SHOMEI_AUDIENCE` and `NAGARE_ACCESS_SHOMEI_AUDIENCE` stay `nagare-access`.
- `nagare-access`: an OIDC host derived from `AuthPlaneConfig.shomeiIssuer`, and one new
  `AccessServices` field for the Shomei forwarder. No new environment variable.
- Shomei stays at `6179d567` (`cli/nagare-access/cabal.project`, `nix/release-images.nix`).
  The portal contract (`docs/user/auth-portal.md`) gains one requirement already met by the
  reference portal: `return_to` is returned unchanged.
- Consumers: Mori sets `MORI_SHOMEI_ISSUER` to the context's issuer and
  `MORI_SHOMEI_AUDIENCE=nagare-access`. Whether Mori's Pod can reach the public JWKS URL
  from inside the cluster is Mori's concern, per IR-47.
