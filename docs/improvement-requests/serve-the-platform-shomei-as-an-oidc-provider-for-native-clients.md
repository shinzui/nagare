---
type: Improvement Request
title: Serve the platform Shomei as an OIDC provider for native clients
description: Let a context give the auth plane's Shomei an absolute https issuer with OIDC enabled, shared by Shomei and nagare-access, and publicly serve its discovery, signing-key, authorize and token endpoints, so command-line clients and services can sign in with the same identity that protects intranet sites.
timestamp: "2026-11-17T23:31:15Z"
generated:
  by: process:claude-code
  at: "2026-11-17T23:31:15Z"
requestId: IR-47
status: completed
completedAt: "2026-11-18T05:40:00Z"
resolution: "ExecPlan 264 shipped the setting in v0.22.0. NAGARE_AUTH_ISSUER renders SHOMEI_ISSUER and NAGARE_ACCESS_SHOMEI_ISSUER from one value and turns OIDC on; unset, the packaged manifests are unchanged. nagare-access serves discovery, the key set, authorize and token on the portal host. The local drill proved the authorization-code flow with PKCE from a signed-in browser, client_credentials, refusal of old tokens and one-renewal sessions. On the intranet, mori://tan/tan-ng-labs c4c1bf7 set https://auth.labs.topagentnetwork.net through reviewed plan 35940818; the next plan has no operations, platform status is exact, and public and in-cluster discovery and JWKS answer with that issuer."
targetPlan: docs/plans/264-serve-the-platform-shomei-as-an-oidc-provider-for-native-clients.md
origin: mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot
acceptanceCriteria:
  - id: AC-1
    statement: A context can set the auth plane's Shomei issuer to an absolute https URL. The Shomei Deployment's SHOMEI_ISSUER and nagare-access's NAGARE_ACCESS_SHOMEI_ISSUER are both rendered from that one value, so they cannot diverge. A context that sets nothing keeps the issuer nagare-shomei and renders exactly as before.
    verification: Plan the auth plane for a context with the setting and one without; assert both rendered issuer values equal the setting in the first and nagare-shomei in the second, and that the second plan has no operations against an accepted v0.21.0 inventory. Assert a non-https or trailing-slash issuer is refused before planning.
  - id: AC-2
    statement: With a URL issuer, Shomei runs with SHOMEI_OIDC_ENABLED=true and SHOMEI_OAUTH_LOGIN_URL set to the registered auth portal's /login, so an anonymous authorization request is sent to sign in and then returns to the authorization. With the opaque default issuer, OIDC stays off.
    verification: On a local or disposable cluster with a URL issuer, GET the public discovery document and assert its issuer equals the setting and it advertises the S256 code challenge method; send an anonymous GET /oauth/authorize and assert a redirect to the portal's /login carrying return_to.
  - id: AC-3
    statement: The issuer origin publicly serves Shomei's GET /.well-known/openid-configuration, GET /.well-known/jwks.json, GET /oauth/authorize and POST /oauth/token, and nothing else of Shomei's API that is not already exposed. An authorization request from a browser already signed in to the intranet reaches Shomei as that user, so it completes without a second sign-in.
    verification: Register a public OAuth client with a fixed http://127.0.0.1:PORT/PATH redirect, then from outside the cluster run an authorization-code flow with PKCE from a signed-in browser session; assert a 302 to the loopback redirect with a code, a successful code exchange at the public token endpoint, and an access token whose iss is the setting and whose signature verifies against the public JWKS. Assert Shomei's admin and other non-listed routes are not reachable on the issuer origin.
  - id: AC-4
    statement: A Shomei service account obtains a client_credentials token from the public token endpoint, from outside the cluster, carrying the configured issuer and the cluster audience.
    verification: Create a service account with shomei-admin, POST grant_type=client_credentials to the public token endpoint from a workstation, and assert a 200 whose token has the configured iss and aud nagare-access.
  - id: AC-5
    statement: Moving an existing context from the opaque issuer to a URL issuer is a reviewed platform transition that states its effect on existing sessions. Afterwards every site protected by requireLogin still admits its granted users, at most after one new sign-in, and nagare-access accepts only tokens with the new issuer.
    verification: On a context with a signed-in session to a protected site, save and apply the transition; assert its review names the issuer change and the session effect, then assert the site admits the granted user after at most one sign-in and that a token minted before the change is refused.
  - id: AC-6
    statement: The access and auth-portal guides document the issuer setting, the public OIDC endpoints, the single audience every token carries, and how an operator registers a public OAuth client and a service account.
    verification: Follow the guides on a fresh disposable context to the point of AC-3 and AC-4 without consulting source.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-17T23:31:15Z"
    document_timestamp: "2026-11-17T23:31:15Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.21.0 (tag) and 242c06ed auth-plane manifests and the
      nagarectl auth component, Shomei 6179d567 OAuth configuration and handlers, Mori's Lite
      OIDC client and Shomei verifier, and a disposable Mori cutover rehearsal that enabled OIDC
      with a URL issuer; no live intranet inspection or independent review is claimed.
---

# Serve the platform Shomei as an OIDC provider for native clients

**Authored by:** a `claude-code` session implementing
`mori://shinzui/mori/plans/302-migrate-the-shared-registry-from-legacy-tokens-to-shomei-and-en-with-a-team-pilot`,
the cutover of the team's shared Mori registry on `mori://tan/tan-ng-labs` from Mori-minted
tokens to Shomei identities and the platform En's `mori` tenant.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-11-17.

## Consumer evidence

The shared Mori registry runs on the tan-ng-labs intranet as the `mori-registry` Application
under Nagare v0.21.0. Its plan reuses the auth plane rather than deploying a second identity
service: teammates sign in with `mori-lite login`, a native browser login using the OAuth
authorization-code flow with PKCE and a fixed loopback redirect. A publisher pushes with a
Shomei service account through `client_credentials`. The registry verifies each access token
against Shomei's signing keys and binds `(issuer, subject)` to a Mori principal.

A disposable rehearsal of that cutover passed against Shomei `6179d567`, the revision v0.21.0
pins, and En `5bb3f80d` in tenant mode. That rehearsal ran Shomei with
`SHOMEI_OIDC_ENABLED=true` and a URL issuer. The auth plane as v0.21.0 deploys it supports
neither:

- `cluster/bootstrap/shomei/service.yaml` sets `SHOMEI_ISSUER` to the literal `nagare-shomei`
  and `SHOMEI_AUDIENCE` to `nagare-access`. It does not set `SHOMEI_OIDC_ENABLED`, which
  defaults to false (`shomei-core/src/Shomei/Config.hs` in `mori://shinzui/shomei`,
  artifact-level URI pending).
- `cluster/bootstrap/nagare-access/service.yaml` hard-codes the same issuer as
  `NAGARE_ACCESS_SHOMEI_ISSUER`.
- The auth component in `cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs` lets a context
  supply only `SHOMEI_WEBAUTHN_RP_ID`, the WebAuthn origins and `SHOMEI_PUBLIC_BASE_URL`.
  `mori://tan/tan-ng-labs` sets no Shomei override in `contexts/intranet.env`
  (artifact-level URI pending).

With OIDC off, Shomei answers its discovery document with 404 and refuses `/oauth/authorize`
(`shomei-servant/src/Shomei/OAuth/Handler.hs`). It also refuses to enable OIDC unless the
issuer is an absolute URL (`shomei-server/src/Shomei/Server/Boot.hs`). Mori's native client
requires an `https:` issuer and reads `<issuer>/.well-known/openid-configuration`. Mori's
server locates the signing keys from the issuer. In
`mori://shinzui/mori`, these are `mori-client/src/Mori/Client/Auth/Oidc.hs` and
`mori-api/src/Mori/Api/Server.hs` (artifact-level URIs pending). So no native client or
separate service can sign in through the platform Shomei today. Patching the live
Deployments would be drift from the reviewed auth plane and would be reverted by the next
transition.

Shomei is also not public. The operator-owned portal calls it server-side
(`docs/user/auth-portal.md`, "Portal HTTP contract"). No public origin serves Shomei's OAuth
or signing-key endpoints.

## Requested outcome and boundary

Give a context one setting for the auth plane's issuer, an absolute `https` URL such as
`https://auth.labs.topagentnetwork.net`. That origin publicly serves Shomei's OIDC discovery,
signing keys, authorization and token endpoints. Shomei and `nagare-access` both take their
issuer from that setting. OIDC is enabled whenever the issuer is a URL, and Shomei's OAuth
login URL is the portal's `/login`. An anonymous authorization then signs in through the
same portal and returns, and a signed-in intranet user authorizes without signing in again.

The default stays `nagare-shomei` with OIDC off, so a context that does not opt in is
unchanged. The single audience `nagare-access` is kept: the Mori registry has decided to
accept it, because it admits only identities bound to a Mori principal and En decides every
permission. Per-resource audiences are not requested.

How the public endpoints are routed is Nagare's choice: through the portal host, a reviewed
route of the Shomei Service, or another mechanism. The authorization endpoint must see the
browser's existing intranet session. Nothing beyond the four listed endpoints should become
newly public.

## Not requested

- Registering OAuth clients or service accounts through `nagarectl`. `shomei-admin` through
  the Shomei Deployment, as the auth-portal guide already does for users, is enough if it is
  documented (AC-6).
- Changes to En, to `requireLogin`, or to how sites are protected.
- Per-resource audiences or audience-scoped tokens.

## Consumer acceptance

After a release meets this request, the Mori registry's ExecPlan 302 configures
`MORI_SHOMEI_ISSUER` as the context's issuer and `MORI_SHOMEI_AUDIENCE=nagare-access`. Its
teammates then run `mori-lite login --issuer <issuer>` against the intranet, and its publisher
pushes with a service account. That plan records the consumer result. If the registry Pod
cannot reach the public signing-key endpoint from inside the cluster, Mori will add its own
cluster-local fetch setting; that is Mori's work and not part of this request.
