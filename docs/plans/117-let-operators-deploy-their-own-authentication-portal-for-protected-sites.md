---
id: 117
slug: let-operators-deploy-their-own-authentication-portal-for-protected-sites
title: "Let operators deploy their own authentication portal for protected sites"
kind: exec-plan
created_at: 2026-09-12T21:38:15Z
intention: "intention_01m2brkd4geymrhxas4me86gwd"
provenance:
  created_by:
    model: "claude-opus-5"
    harness: "claude-code"
    at: 2026-09-12T21:38:15Z
  revisions:
    - model: "claude-opus-5"
      harness: "claude-code"
      at: 2026-09-12T21:55:22Z
      mode: "update"
      note: "Replace bare-Text and nested Either/Maybe interfaces with domain types"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-13T04:50:20Z
      mode: "implement"
      note: "Implemented auth portal plan milestones beginning with backend roles and cookie isolation"
---

# Let operators deploy their own authentication portal for protected sites

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today every protected Nagare site shows the same unstyled sign-in form, a passkey page
built from inline JavaScript, and one-word error pages ("Forbidden", "authorization
service unavailable"). All of them are hard-coded Haskell strings inside the shared
enforcer, `nagare-access`. Users cannot sign up, change their password, reset a
forgotten password, verify their email, or add a passkey anywhere. Those features exist
in the identity service (Shomei), but nothing exposes them to people.

After this change an operator can deploy an **authentication portal**. The portal is an
ordinary Nagare app, written in any language, that owns every page a person sees while
signing in or managing their account: sign-in, the passkey step, sign-up, forgot and
reset password, email verification, change password, passkey management, sign-out, and
the branded "you do not have access" (403) and "temporarily unavailable" (503) pages. The
operator opts in by setting `access = Just authPortal` in the portal's `Config.hs` and
running `nagarectl deploy`. From then on, `nagare-access` sends unauthenticated visitors of
every protected site to the portal. When the portal finishes a sign-in, `nagare-access`
turns the result into its usual single-sign-on cookie and sends the person back to where
they started. Its 403 and 503 responses carry the portal's HTML.

**The built-in pages remain the default.** A cluster with no portal behaves exactly as
it does today, byte for byte on the login, passkey and error responses. Removing the
portal, by deleting the app or dropping `authPortal` from its config, returns every
protected site to the built-in pages. The built-in sign-in form also stays reachable as
a break-glass path at `/_nagare/login?builtin=1` on every protected host, so a broken
portal can never lock operators out.

To see it working (Milestone 6, on a local k3d cluster):

- **Before signing in:** `curl` a protected site and get a `302` to
  `https://auth.127-0-0-1.sslip.io/login?return_to=…`.
- **Sign in:** submit the portal's form and get a `303` back to the protected site,
  along with a `nagare_session` cookie scoped to the parent domain.
- **Signed in, not granted:** the `403` body is the portal's branded page.
- **After `nagarectl access grant`:** the site returns `200`.
- **Account page:** the portal's account page shows the signed-in login name, and
  changing the password there works.
- **Portal deleted:** the protected site challenges with the built-in
  `/_nagare/login` again.

This plan also ships a small reference portal in `cluster/examples/auth-portal`. Operators
can deploy it as is, restyle it, or replace it with their own implementation of the same
contract, which is documented in `docs/user/auth-portal.md`.


## Progress

- [x] (2026-09-13T04:50:20Z) Milestone 1: backend-map roles and auth-cookie stripping in `nagare-access`.
  - [x] Extend `Nagare.Access.BackendMap` so a value may be a string (protected site) or an
    object with `upstream` and `role`; reject more than one `portal` entry.
  - [x] Strip `nagare_session`, `nagare_refresh`, and `__Host-nagare_csrf` from the
    `Cookie` header before proxying to any backend.
  - [x] Tests in `cli/nagare-access/test/Spec.hs` for both; all 109 tests pass.
- [x] (2026-09-13T04:58:30Z) Milestone 2: portal routing mode in `nagare-access`.
  - [x] Optional authentication and identity forwarding (with `Authorization: Bearer`) for
    the portal host.
  - [x] Session hand-off: intercept `Nagare-Session-Establish` / `Nagare-Session-Clear`
    response headers from the portal upstream only; rotate the refresh token; validate the
    return URL.
  - [x] Revoke the Shomei session on `/_nagare/logout` (both default and portal modes).
  - [x] Tests with stub upstreams; all 120 tests pass.
- [x] (2026-09-13T05:03:30Z) Milestone 3: portal-driven challenges and branded error pages.
  - [x] Document challenges redirect to the portal when one is configured; JSON challenges
    carry the absolute portal login URL.
  - [x] `GET /_nagare/login` redirects to the portal unless `builtin=1`.
  - [x] 403 and 503 document responses embed the portal's `/errors/403` and `/errors/503`
    HTML with a timeout and built-in fallback.
  - [x] Tests proving the no-portal responses are unchanged; all 128 tests pass.
- [x] (2026-09-13T05:16:52Z) Milestone 4: DSL and `nagarectl` wiring.
  - [x] `authPortal` in `Nagare.Dsl.Access` with a `role` field, JSON round trip in the
    loader.
  - [x] `Nagare.Access.Resolve` writes a `portal` entry, refuses a second portal or a host
    outside the base domain, and configures Shomei for the portal origin.
  - [x] `nagarectl app delete` removes the app's access wiring.
  - [x] `nagarectl access portal show` and `nagarectl access portal sync`.
  - [x] All 387 `nagare-dsl-test` and all 438 `nagarectl-test` tests pass.
- [x] (2026-09-13T05:24:21Z) Milestone 5: reference portal example.
  - [x] `cluster/examples/auth-portal` Node app, non-root Dockerfile, typed
    `nagare/Config.hs`, styles, passkey browser client, and README.
  - [x] All seven offline contract tests pass with Node 22.22.3.
  - [x] The `linux/amd64` Docker image builds successfully and runs as user `node`.
  - [x] `nagarectl deploy --dry-run` renders only the ordinary Service and DomainMapping;
    access registration remains a deploy-time effect.
- [ ] Milestone 6: documentation and local end-to-end validation (manual passkey ceremony pending).
  - [x] `docs/user/auth-portal.md` (contract), updates to `docs/user/access.md` and
    `cluster/bootstrap/nagare-access/README.md`.
  - [x] Local k3d run of every non-browser scenario in Validation and Acceptance,
    transcript captured here.
  - [ ] Manual passkey ceremony in a browser that trusts `nagare-local-ca`. Chrome
    correctly refused the untrusted certificate; its security interstitial was not bypassed.
  - [x] ADR distillation (portal contract and cookie ownership).


## Surprises & Discoveries

These were found while researching the plan (2026-09-12), before any implementation.

- **Every backend receives the enforcer's session tokens today.**
  `cli/nagare-access/src/Nagare/Access/Proxy.hs` (`shouldStripRequestHeader`) strips hop
  headers and `X-Forwarded-*`, but not `Cookie`. Every protected app therefore receives
  the user's `nagare_session` access token and the signed `nagare_refresh` cookie on each
  request. This matters for the portal design, which gives a token only to the portal and
  only on purpose, so Milestone 1 closes the leak.
- **Cloud Shomei has no WebAuthn configuration.** `cluster/bootstrap/shomei/service.yaml`
  sets only `SHOMEI_PORT`, `SHOMEI_ISSUER`, `SHOMEI_AUDIENCE`, and the key-encryption key.
  Only `cluster/bootstrap/local-auth/install.sh` sets `SHOMEI_WEBAUTHN_RP_ID` and
  `SHOMEI_WEBAUTHN_ORIGINS`, and only for `protected-hello`. With the built-in pages, a
  passkey ceremony happens on each protected host's own origin, so every protected host
  would have to be listed as an allowed origin. A portal gives Shomei exactly one origin
  to allow, and Milestone 4 configures it.
- **Shomei's email links point at its JSON API, not at a page.**
  `mori://shinzui/shomei` `shomei-server/src/Shomei/Notify.hs:463-490` builds
  `SHOMEI_PUBLIC_BASE_URL + "/v1/auth/password-reset/confirm?token=…"` and the same for
  `/v1/auth/verify-email/confirm`. Both are POST-only JSON routes (the artifact-level URI
  for this file is pending; the project URI plus path is the reference). The portal
  therefore serves `GET` pages at exactly those two paths, and Shomei's public base URL
  must be the portal origin.
- **Shomei has no CORS support and no switch to disable sign-up.** A browser page cannot
  call Shomei directly from another origin, so the reference portal calls Shomei from
  its server side. `POST /v1/auth/signup` is always open on Shomei itself. The portal
  decides whether to offer sign-up, but anyone who can reach Shomei's API could still
  sign up. Shomei is cluster-internal (`http://shomei.nagare-system.svc.cluster.local`)
  and not publicly routed, so this is acceptable.
- **Refresh tokens rotate with reuse detection.** Presenting an already-used refresh
  token revokes the whole Shomei session (`token_reuse`, `mori://shinzui/shomei`
  `shomei-core/src/Shomei/Session/Authentication/Workflow.hs:360-441`). Two parties must
  never both hold and use the same refresh token, which is why the hand-off in Milestone
  2 rotates the token immediately and the portal keeps no tokens.
- **`nagare-access` reads its backend map only at startup.** `cli/nagare-access/app/Main.hs`
  (`loadBackends`) reads it once, and `nagarectl` forces a new revision by patching the
  annotation `nagare.dev/backend-map-reload`
  (`cli/nagarectl/src/Nagare/Access/Resolve.hs`). The portal entry rides the same
  mechanism and needs no new reload path.
- **`nagarectl app delete` leaves access wiring behind.** `deleteApp` in
  `cli/nagarectl/src/Nagare/App.hs` removes the Knative Service and the app-namespace
  DomainMappings. It leaves the host in `nagare-access-backends` and the
  `nagare-system` DomainMapping. For a portal this would send every login to a dead
  host, so Milestone 4 fixes the cleanup.
- **All logins reach Shomei from a single pod IP.** Shomei limits failed logins per IP
  (20) and requests per minute per IP (60) (`mori://shinzui/shomei`
  `shomei-server/src/Shomei/Server/Config.hs:706-712`). Both the built-in pages and a
  portal call Shomei from one pod, so one attacker's failures count against everyone.
  This is not introduced by this plan; see the Decision Log.
- **The plan's required `ExceptT` hand-off block needs a direct `transformers`
  dependency.** Cabal hides transitive packages, so importing
  `Control.Monad.Trans.Except` requires listing the compiler-bundled `transformers`
  package in `cli/nagare-access/nagare-access.cabal`. This is the only Haskell
  dependency-list change; no new package source or version bound was introduced.
- **The pinned Shomei release already exposes an authenticated logout client.** The
  pinned commit `6a96185f4f809e5e7a99095274caa6bd90e7a8d7` is the peeled target of the
  authoritative upstream tags `release-2026-08-27` and `shomei-core-0.2.0.0`, and
  `Shomei.Client.logout` sends the bearer token to `POST /v1/auth/logout`.
- **A name-only `-package nagare-dsl` flag conflicts with the exact Cabal environment.**
  Both CLI test suites inherited an environment that exposed the in-place package by
  package ID, while the loader's extra name-only flag exposed another installed version.
  Every config-as-program import then became ambiguous. Letting `runghc` use the exact
  `GHC_ENVIRONMENT` package ID removed the ambiguity; all 825 tests across the two suites
  then passed.
- **A cold auth-image build exposed three integration drifts.** The standalone En image
  needed the unpublished `mori://shinzui/hs-opentelemetry-instrumentation-servant` source
  pin from En's project; the combined image was copying the current En and Shomei sibling
  checkouts instead of the revisions pinned by `cli/nagare-access/cabal.project`; and
  current En resolves `generic-lens-2.3.0.0` while `nagare-dsl` unnecessarily capped the
  package below 2.3. The builder now extracts the declared Git revisions, the missing En
  source pin is explicit, and the tested DSL bound is `>=2.2 && <2.4`. Mori located each
  dependency source, while upstream refs and Hackage confirmed the selected revisions.
- **The En manifest still used retired health paths.** Current En deliberately exposes
  unauthenticated `/health/live` and `/health/ready`; Kubernetes probes against `/healthz`
  and `/readyz` received 401 and prevented rollout. The bootstrap manifest now follows
  the registered En source contract.
- **The existing local Shomei database predated Shomei 0.2's repaired migration history.**
  Its ledger correctly reported checksum mismatches. Validation used a fresh
  `nagare_plan117` database while preserving the original database rather than deleting
  it.
- **Auth-plane reinstall used to erase access state.** Both installers reapplied the
  bootstrap `backends.json: "{}"`, which would remove protected routes and the portal.
  They now create the managed ConfigMap only when absent. A live reinstall retained the
  portal entry and `SHOMEI_PUBLIC_BASE_URL`, so `nagarectl access portal sync` is a repair
  command rather than a normal post-install step.
- **The workstation's localhost port 443 was intercepted by an unrelated Portless TLS
  endpoint.** Kubernetes held the expected `nagare-local-ca` certificates, but the host
  listener served `portless Local CA`. The transcript therefore forwarded Kourier's
  external TLS service to localhost:18443 and used explicit SNI/Host values; the cluster
  path then passed CA verification. Chrome still required the CA to be installed in its
  trust store, so the manual passkey ceremony remains outstanding.
- **Knative treats `max-scale: "0"` as unlimited, not disabled.** To exercise the
  enforcer fallback deterministically, the validation temporarily pointed the portal
  backend at an unavailable cluster-local service and forced a backend-map reload. The
  request remained 503 and changed from the branded page to the exact built-in
  `authorization service unavailable` body; redeploy restored the real upstream.


## Decision Log

- Decision: The portal is an ordinary Nagare app that opts in with a new DSL value,
  `authPortal`. It is not a new platform service installed by `auth-install.sh`.
  Rationale: The user asked for a separately deployable app that operators build and
  brand themselves. Reusing the app deploy path gives builds, domains, env and secrets,
  and rollbacks for free. The source of truth for which host is the portal is the
  portal's own config, so no context variable has to be kept in sync with it.
  Date: 2026-09-12

- Decision: The built-in login, passkey, and error pages remain the default and stay
  byte-for-byte unchanged when no portal is configured. `/_nagare/login?builtin=1` keeps
  the built-in form reachable even when a portal exists.
  Rationale: The user asked to keep the current defaults. The break-glass path means a
  broken or misdeployed portal cannot lock operators out of every protected site.
  Date: 2026-09-12

- Decision: `nagare-access` remains the only component that sets the `nagare_session` and
  `nagare_refresh` cookies and the only holder of the cookie-signing key. The portal
  hands a completed sign-in to `nagare-access` through response headers
  (`Nagare-Session-Establish`), and `nagare-access` honors them only on responses from
  the configured portal upstream.
  Rationale: The alternatives are worse. Sharing the cookie key with the portal would
  couple an operator-written app to the enforcer's cookie format and let any bug in it
  forge sessions. Handing tokens through the browser (redirect URLs, auto-posted forms)
  exposes them to logs and needs extra anti-forgery state. Response-header interception
  never exposes tokens to the browser, needs no shared secret (trust comes from the
  cluster-internal hop to a known upstream), and keeps the existing security model in
  `docs/user/access.md`: "`nagare-access` owns the browser-facing session cookies".
  Date: 2026-09-12

- Decision: On a hand-off, `nagare-access` immediately refreshes the portal-provided
  refresh token with Shomei and stores only the new pair.
  Rationale: Shomei revokes a whole session when a used refresh token is presented
  again. Rotating at hand-off makes the portal's copy worthless, so a portal bug that
  logs or reuses it cannot hijack or kill the session. It also proves the token is live
  before a cookie is set.
  Date: 2026-09-12

- Decision: The portal host is routed through `nagare-access` like a protected site, but
  in a portal mode that does not require login and never consults En.
  `nagare-access` forwards anonymous requests with identity headers stripped, and
  authenticated requests with `X-Forwarded-User` plus `Authorization: Bearer <access
  token>`.
  Rationale: The portal's account pages (change password, passkeys) must call Shomei
  as the user, which needs the user's access token. Forwarding the token explicitly,
  and only to the portal, is safer than the current accidental cookie forwarding that
  Milestone 1 removes. Routing the portal through the enforcer is also what lets the
  hand-off response set cookies on the parent domain.
  Date: 2026-09-12

- Decision: The portal contract uses fixed paths: `/login`, `/errors/403`, `/errors/503`,
  and Shomei's two email-link paths. Everything under `/_nagare/` stays reserved for
  `nagare-access`.
  Rationale: Fixed paths keep the enforcer configuration-free (its only input is which
  host is the portal) and make the contract easy to document and test. Operators who
  want other URLs can redirect inside their portal.
  Date: 2026-09-12

- Decision: Branded 403 and 503 pages are fetched server-side by `nagare-access` from the
  portal upstream (two-second timeout, 256 KiB cap), and served with the original
  status on the original URL. Any failure falls back to the built-in body.
  Rationale: A redirect would turn a 403 into a 302 and change the URL, which breaks
  "reload after being granted". A 503 happens exactly when part of the auth plane is
  down, so a fallback is mandatory.
  Date: 2026-09-12

- Decision: `nagarectl` configures Shomei for the portal when it registers the portal. It
  patches the `shomei` Deployment's `SHOMEI_WEBAUTHN_RP_ID`, `SHOMEI_WEBAUTHN_ORIGINS`
  (added to, never replaced), and `SHOMEI_PUBLIC_BASE_URL`. `nagarectl access portal
  sync` re-applies the same values on demand.
  Rationale: The portal host is only known when the portal is deployed, and the deploy
  resolver is already the component that writes access wiring into `nagare-system`. A
  separate operator step would be forgotten, and passkeys and email links would then
  silently fail.
  Date: 2026-09-12

- Decision: `/_nagare/logout` also revokes the Shomei session, in both default and portal
  modes.
  Rationale: Logout currently only clears cookies, so a copied refresh token stays valid
  for 30 days. Revocation has no visible effect on the built-in pages, so it respects
  the "keep the defaults" requirement while fixing a real gap.
  Date: 2026-09-12

- Decision: The reference portal is a dependency-free Node.js server
  (`node:http`, global `fetch`), built with a Dockerfile.
  Rationale: It matches the existing `cluster/examples/env-and-secrets` pattern, builds
  quickly, and is easy for operators to restyle or port. A Haskell portal would pull the
  forked WebAuthn dependency closure (see
  [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md)) into an
  example that operators are meant to copy.
  Date: 2026-09-12

- Decision: New code carries domain types instead of bare `Text` and layered
  `Either`/`Maybe`.
  - New types: `PublicHost`, `AccessToken`, `RefreshToken`, `SafePath`,
    `ReturnTarget`, `SessionHandoff`, `CapturedResponse`, `PortalPage`, and `Origin` on
    the enforcer side; `BackendMap`, `BackendEntry`, `BaseDomain`, and
    `ShomeiPortalChange` on the `nagarectl` side.
  - `nagarectl`'s `AccessOps` is refactored so that operations return domain values
    (`loadBackends :: IO BackendMap`), and the `kubectl` boundary handles decode
    failures and absence.
  - Side effects that vary by case are described as data (`RouteOp`,
    `ShomeiPortalChange`) and interpreted by one operation each, instead of one record
    field per variant.
  - The multi-step hand-off is one `ExceptT HandoffFailure IO` block.

  Rationale: The first draft specified signatures such as
  `loadBackendMap :: IO (Either Text (Maybe (Map Text BackendEntry)))`,
  `portalLoginUrl :: Text -> Text -> Text -> Text`, and
  `configureShomeiPortal :: Text -> Text -> IO ()`. They let hosts, tokens, and URLs be
  swapped silently, and made every caller unwrap the same failure layers. The user
  rejected them as not idiomatic Haskell.
  Date: 2026-09-12

- Decision: Per-IP rate limiting in Shomei (all logins arrive from one pod IP) is out of
  scope and recorded as follow-up work.
  Rationale: The problem predates the portal and affects the built-in pages equally.
  Fixing it means trusting forwarded client addresses from cluster pods
  (`SHOMEI_TRUSTED_PROXIES`), which is a separate security decision.
  Date: 2026-09-12

- Decision: Implement session revocation with the generated
  `Shomei.Client.logout` function from the pinned Shomei source, wrapped as a
  best-effort `logoutWithShomei` adapter.
  Rationale: The typed client exactly matches the pinned server API and avoids a
  parallel hand-written HTTP contract. Logout must still clear browser cookies when
  Shomei is unreachable, so transport or application failures are logged and do not
  escape the adapter.
  Date: 2026-09-13

- Decision: Add the compiler-bundled `transformers` package as a direct
  `nagare-access` dependency.
  Rationale: The plan requires the multi-step hand-off to be one `ExceptT` block;
  Cabal package visibility requires the owning package to be named directly even
  though it is already present in the compiler package set.
  Date: 2026-09-13

- Decision: `Nagare.Dsl.Load.runConfigWith` relies on the caller's exact GHC package
  environment instead of adding a name-only `-package nagare-dsl` flag.
  Rationale: `nagarectl` already provisions `GHC_ENVIRONMENT`, and Cabal tests expose the
  in-place library there by package ID. Re-exposing a package by name can select another
  installed version and make every `Nagare.Dsl.*` import ambiguous.
  Date: 2026-09-13

- Decision: The local-source auth-image builder extracts En and Shomei at the Git tags
  declared in `cli/nagare-access/cabal.project` when building `nagare-access`; standalone
  En and Shomei service images still use their current Mori-located source checkout.
  Rationale: The enforcer compiles against a pinned API and must not silently adopt an
  unrelated sibling HEAD. This makes the Cabal project the single compatibility source
  of truth and preserves normal current-source service development.
  Date: 2026-09-13

- Decision: Auth-plane installation creates `nagare-access-backends` only when it is
  absent and otherwise leaves it to `nagarectl`.
  Rationale: The ConfigMap's managed label already identifies the resolver as owner.
  Replacing it with the bootstrap empty value during reinstall destroys durable operator
  routing and portal state.
  Date: 2026-09-13


## Outcomes & Retrospective

Milestones 1 through 5 are complete, and Milestone 6's documentation, ADR, offline
checks, and non-browser local acceptance are complete. Operators can deploy an ordinary
app with `authPortal`, receive login and account traffic there, brand 403/503 pages, and
remove it to restore the built-in pages. `nagare-access` alone owns cookies; upstream
apps no longer receive them; a portal response can establish a session only through the
bounded internal header handoff, whose refresh token is rotated before use.

The local transcript on 2026-09-13 observed:

- unauthenticated protected traffic returned 302 to the portal with the original URL;
- password login returned 303, set both parent-domain cookies, and exposed no handoff
  header; unauthorized and authorized requests returned the branded 403 and 200;
- `/account` showed `plan117@example.test`; password change returned 303, did **not**
  revoke the current session, and the new password created a new session;
- Shomei's default log notifier wrote a `password_reset` event with email, token hash,
  and expiry to the Shomei pod log, but no full reset URL unless
  `SHOMEI_NOTIFIER_LOG_SECRETS=true` is intentionally enabled;
- En downtime returned the branded 503, and an unreachable portal changed that response
  to the built-in `authorization service unavailable` body;
- the break-glass login rendered, logout redirected to `logged_out=1`, and replaying the
  pre-logout refresh token against Shomei returned 401;
- re-running `cluster/bootstrap/local-auth/install.sh` preserved the portal registration
  and Shomei public base URL after the installer fix; and
- deleting the portal removed its backend, DomainMapping, Shomei origin, Knative Service,
  and deployment history. Once the enforcer reload revision was ready, protected traffic
  returned to the built-in `/_nagare/login?rd=%2F` challenge.

The cold image run also proved all three ARM64 auth-plane images can build and push to
the local registry. The only remaining acceptance item is the manual WebAuthn ceremony:
the connected Chrome instance refused the intentionally local CA with
`ERR_CERT_AUTHORITY_INVALID`. Bypassing that interstitial would invalidate the secure
origin being tested, so a human must first trust `nagare-local-ca` and perform Validation
step 10.


## Context and Orientation

This section explains the pieces involved as if you have never seen this repository.

**Protected site.** A Nagare app whose `Config.hs` sets `access = Just requireLogin`. Its
public traffic is routed through a shared reverse proxy instead of straight to the app,
and the proxy only lets through people who are signed in and have been granted access.
The user-facing runbook is `docs/user/access.md`.

**The auth plane.** Three services in the Kubernetes namespace `nagare-system`, installed
by `cluster/bootstrap/auth-install.sh` (cloud) or `cluster/bootstrap/local-auth/install.sh`
(local k3d):

- **Shomei** (`mori://shinzui/shomei`) is the identity service. It stores users and
  passwords, runs passkey (WebAuthn) ceremonies, and issues tokens: a short-lived
  *access token*, which is a signed JWT valid for 15 minutes by default, and a
  long-lived *refresh token*, an opaque string valid for 30 days that can be exchanged
  once for a new pair. Its manifest is `cluster/bootstrap/shomei/service.yaml` (a
  Deployment), and it is reachable in-cluster at
  `http://shomei.nagare-system.svc.cluster.local`.
- **En** (`mori://shinzui/en`) is the authorization service. It stores relationships such
  as "user X is a viewer of app:host" and answers "may X access host?". Its schema is in
  `cluster/bootstrap/en/configmap.yaml`.
- **`nagare-access`** is the enforcer: a Haskell WAI (web application interface) server
  in `cli/nagare-access`. It runs as the Knative Service
  `cluster/bootstrap/nagare-access/service.yaml` (exactly one replica). Its code is
  organized as follows:
  - `app/Main.hs` reads configuration from environment variables and builds a record
    of effectful functions, `AccessServices`, defined in `src/Nagare/Access/Auth.hs`.
  - `src/Nagare/Access/App.hs` (`appWithRuntime`) routes each request. The paths
    `/_nagare/healthz`, `/_nagare/userinfo`, `/_nagare/logout`, `GET`/`POST
    /_nagare/login`, and `POST /_nagare/mfa/complete` are handled on every host.
  - Any other request looks up its `Host` header in the backend map. Unknown hosts get
    `502`. Known hosts go through `handleProtected`, which authenticates with the
    `nagare_session` cookie or a bearer token, refreshing through the signed
    `nagare_refresh` cookie when the access token has expired. It then asks En (the
    answer is cached for 30 seconds) and either proxies the request, returns `403`, or
    returns `503`.
  - `src/Nagare/Access/Challenge.hs` decides whether an unauthenticated request is a
    browser document, which gets a 302 to `/_nagare/login?rd=<path>`, or an API call,
    which gets a JSON 401. It also contains `safeReturnDestination`, which only accepts
    same-host absolute paths.
  - `src/Nagare/Access/Response.hs` builds the 302, 401, and 403 responses.
  - The login form and passkey page are inline strings in `App.hs` (`loginFormHtml`,
    `mfaFormHtml`).
  - `src/Nagare/Access/Cookie.hs` builds the cookies: `nagare_session` (the access
    token), `nagare_refresh` (the refresh token plus an HMAC-SHA256 signature made with
    `NAGARE_ACCESS_COOKIE_KEY`), and `__Host-nagare_csrf` (double-submit CSRF token for
    the built-in form). The session and refresh cookies use
    `Domain=NAGARE_ACCESS_COOKIE_DOMAIN`, which is the parent of all protected hosts
    (for example `.labs.example.net`), so one sign-in works on every protected
    subdomain.
  - `src/Nagare/Access/ShomeiClient.hs` calls Shomei's login, MFA-complete, and refresh
    endpoints through Shomei's generated Servant client (`Shomei.Client`).
  - `src/Nagare/Access/Shomei.hs` verifies access-token JWTs against Shomei's published
    keys (issuer `nagare-shomei`, audience `nagare-access`).
  - `src/Nagare/Access/Proxy.hs` (`proxyForwarder`) streams the request to the upstream
    with `http-client`, strips hop-by-hop headers, and adds `X-Forwarded-User` (the
    Shomei user id, a TypeID string such as `user_01h…`), `X-Forwarded-Host`, and
    `X-Forwarded-Proto: https`.

**Backend map.** A JSON object, host to upstream URL, stored under the key `backends.json`
in the ConfigMap `nagare-access-backends` (namespace `nagare-system`). It is mounted into
`nagare-access` at `/etc/nagare-access/backends/backends.json`. For example:

```json
{"protected-hello.apps.example.com":"http://protected-hello.personal.svc.cluster.local"}
```

It is parsed by `cli/nagare-access/src/Nagare/Access/BackendMap.hs` (`decodeBackendMap`,
`canonicalHost`, `lookupBackendWithHost`) and read once at startup.

**Deploy-time wiring.** `nagarectl` is the operator CLI in `cli/nagarectl`. When an app is
deployed (`nagarectl deploy`, `cli/nagarectl/app/Main.hs`, or the app deploy path in
`cli/nagarectl/src/Nagare/App/Deploy.hs`), `resolveDeploymentAccess` in
`cli/nagarectl/src/Nagare/Access/Resolve.hs` runs after the app is ready.

- It computes the app's public hosts (`deploymentAccessRoutes`): each custom domain,
  or `<service>.<namespace>.<baseDomain>` when there are none.
- If `access` is `Just _`, it checks that `nagare-access` exists, inserts
  `host -> http://<service>.<namespace>.svc.cluster.local` into the backend map, writes
  the ConfigMap, patches the reload annotation, and points the host's Knative
  DomainMapping (the object that binds a public hostname to a Knative Service) at
  `nagare-access` in `nagare-system`.
- If `access` is `Nothing`, it removes the host and restores the direct route.
- All side effects go through the record `AccessOps`, so
  `cli/nagarectl/test/AccessResolveSpec.hs` can test the logic with a fake
  (`fakeOps`).
- Only whether `access` is `Just` or `Nothing` matters today. The policy's `audience`
  and `permission` fields are ignored.

**DSL.** Apps are configured in Haskell with the `nagare-dsl` package (`cli/nagare-dsl`).

- `cli/nagare-dsl/src/Nagare/Dsl/Access.hs` defines `AccessPolicy { audience,
  permission }` and `requireLogin`.
- The `Deployment` record in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` has
  `access :: Maybe AccessPolicy`, and so does `Application` in
  `cli/nagare-dsl/src/Nagare/Dsl/Application.hs`.
- A `Config.hs` is run with `runghc` and prints JSON (`emitDeployment`; the access
  object is serialized by `accessPolicyJSON` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`).
- `nagarectl` reads that JSON back with `JsonAccessPolicy` / `toAccessPolicy` in
  `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`.

**Grants.** `nagarectl access grant|revoke|list` (`cli/nagarectl/src/Nagare/Access/Grants.hs`)
writes `app:<host>#viewer@user:<shomei-user-id>` tuples to En.

**Shomei's public API** (everything the portal needs; all JSON, all under
`http://shomei.nagare-system.svc.cluster.local`, errors as `application/problem+json`):

- **Sign-in and sessions:**
  - `POST /v1/auth/login` takes `{loginId, password}`. It returns either
    `{"status":"complete","user":…,"token":{accessToken,refreshToken,expiresIn}}` or
    `{"status":"mfa_required","ceremonyId":…,"options":{…WebAuthn request options…},"methods":[…]}`.
  - `POST /v1/auth/mfa/complete` takes `{ceremonyId, proof:{type:"passkey", assertion}}`
    and returns a bare token pair.
  - `POST /v1/auth/login/passkey/begin` and `…/complete` perform passwordless passkey
    sign-in.
  - `POST /v1/auth/refresh` takes `{refreshToken}`.
  - `POST /v1/auth/logout` (bearer) revokes the session.
- **Account:**
  - `POST /v1/auth/signup` takes `{loginId, email?, password, displayName}` and returns
    201 `{user, token}`.
  - `GET /v1/auth/me` (bearer) returns `{userId, loginId, email?, displayName, status}`.
  - `POST /v1/auth/password/change` (bearer) takes `{currentPassword, newPassword}` and
    returns 204.
  - `POST /v1/auth/password-reset/request` takes `{email}` (202), and `…/confirm` takes
    `{token, newPassword}`.
  - `POST /v1/auth/verify-email/request` takes `{email}`, and `…/confirm` takes
    `{token}`.
- **Passkeys** (all bearer): `POST /v1/auth/passkeys/register/begin` returns
  `{ceremonyId, options}`, `…/register/complete` takes `{ceremonyId, credential,
  label?}`, `GET /v1/auth/passkeys` lists them, and `DELETE /v1/auth/passkeys/{id}`
  removes one.
- **Configuration:** Shomei reads `SHOMEI_WEBAUTHN_RP_ID` (the "relying party" domain a
  passkey is bound to; a parent domain covers all its subdomains),
  `SHOMEI_WEBAUTHN_ORIGINS` (a comma-separated list of exact `https://host` origins
  allowed to run ceremonies), and `SHOMEI_PUBLIC_BASE_URL` (the origin placed in email
  links) from `mori://shinzui/shomei` `shomei-server/src/Shomei/Server/Config.hs`.

Before relying on a field name, check it against the pinned Shomei revision used by
`cli/nagare-access/cabal.project`. Use `mori registry show shinzui/shomei --full` to find
the source checkout.

**Relevant ADRs.**
[ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md) says the
`nagare-access` image mirrors Shomei's and En's pinned dependency plans; this plan adds
only the compiler-bundled `transformers` package as a direct dependency and introduces
no new package source or version bound for the enforcer.
[ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) says
Shomei and En own their schemas; this plan changes no schema.
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires every cloud-mutating path to assert the active context's project, and
`nagarectl`'s existing deploy path already does that for the Shomei patch added here.
No existing ADR covers login UI or session hand-off; Milestone 6 creates one.

**Tests and builds.**

- `nagare-access` has its own Cabal project. Run
  `cd cli/nagare-access && cabal test nagare-access-test --test-show-details=streaming`.
  - The suite is `cli/nagare-access/test/Spec.hs` (tasty). Application tests call
    `runSession` from `Network.Wai.Test` against `appWithRuntime backends testServices`.
    `testServices` is a fake `AccessServices` near the end of the file, and real-socket
    stubs use `testWithApplication` (see `identityUpstreamApp`).
  - CI builds it with `nix build .#hydraJobs.x86_64-linux.nagare-access-build-test`.
- `nagarectl`: `cd cli/nagarectl && cabal test nagarectl-test`.
- `nagare-dsl`: `cd cli/nagare-dsl && cabal test nagare-dsl-test`.


## Plan of Work

The work is six milestones. Milestones 1–3 change only `nagare-access` and are fully
testable offline. Milestone 4 teaches the DSL and `nagarectl` to register a portal.
Milestone 5 builds the reference portal. Milestone 6 documents the contract and proves
the whole flow on a local cluster.

### The portal contract (read this first)

Everything below implements this contract, which `docs/user/auth-portal.md` will state
for operators. In this contract `P` is the portal's public host (for example
`auth.labs.example.net`), and `H` is any protected host.

1. **Where the portal lives.** `P` must be a subdomain of the cluster's cookie domain,
   so that cookies set on `P` reach every `H`. `nagarectl` enforces this by requiring
   `P` to end in `.<NAGARE_BASE_DOMAIN>`. There is at most one portal per cluster.

2. **Sign-in redirect.** When a browser without a valid session opens
   `https://H/some/path?x=1`, `nagare-access` answers
   `302 Location: https://P/login?return_to=https%3A%2F%2FH%2Fsome%2Fpath%3Fx%3D1`. An API
   request (detected exactly as today) gets
   `401 {"error":"unauthenticated","login":"https://P/login?return_to=…"}`.

3. **What the portal receives.** Every request to `P` except `/_nagare/*` is proxied to
   the portal's upstream.
   - If the browser has a valid session (after a silent refresh if needed), the request
     carries `X-Forwarded-User: <shomei user id>` and
     `Authorization: Bearer <access token>`.
   - Otherwise both headers are absent. Any client-sent values are always stripped
     first.
   - `X-Forwarded-Host: P` and `X-Forwarded-Proto: https` are always set.
   - The portal must not trust `X-Forwarded-User` on its own. To learn who the user is,
     it calls Shomei `GET /v1/auth/me` with the bearer token.

4. **Completing a sign-in.** After the portal obtains a token pair from Shomei (password
   login, MFA completion, passkey login, or sign-up), it responds with the header
   `Nagare-Session-Establish: <base64url of JSON {"accessToken":…,"refreshToken":…,"returnTo":…}>`.
   The status and body of that response are ignored. `nagare-access` removes the header,
   verifies the access token, exchanges the refresh token with Shomei for a fresh pair,
   and sets `nagare_session` and `nagare_refresh`. It then answers `303 See Other` to
   `returnTo` for a document request, or `200 {"redirect": returnTo}` when the request
   was an API request (for the portal's `fetch`-driven passkey page).
   - `returnTo` is accepted only if it is an `https://` URL whose host is `P` or a
     host in the backend map, and whose path passes `safeReturnDestination`.
     Otherwise `https://P/` is used.
   - If verification or refresh fails, `nagare-access` answers `303` to
     `https://P/login?error=session` and sets no cookie.

5. **Ending a session from the portal.** A portal response carrying
   `Nagare-Session-Clear: 1` makes `nagare-access` revoke the Shomei session (using the
   request's access token, when it has one), clear both cookies, and pass the rest of
   the portal response through unchanged. The portal's sign-out link should simply
   point at `https://P/_nagare/logout`, which does the same and then redirects to
   `https://P/login?logged_out=1`.

6. **Branded errors.** When `nagare-access` would answer a document request on `H` with
   403 (signed in, no grant) or 503 (En unreachable), it first requests
   `GET <portal upstream>/errors/403` or `/errors/503` with `Accept: text/html` and these
   headers:
   - `X-Nagare-Error-Host: H`
   - `X-Nagare-Error-Path: <original path and query>`
   - `X-Nagare-Return-To: https://H<path>`
   - `X-Forwarded-User` when known

   A `200` HTML answer received within two seconds and no larger than 256 KiB becomes
   the body of the original 403 or 503, sent with `Content-Type: text/html;
   charset=utf-8` and `Cache-Control: no-store`. Anything else yields today's built-in
   body. API requests keep their JSON bodies.

7. **Email links.** Shomei's password-reset and verification emails link to
   `https://P/v1/auth/password-reset/confirm?token=…` and
   `https://P/v1/auth/verify-email/confirm?token=…`. The portal must serve `GET` pages at
   those paths.

8. **Break-glass.** `https://H/_nagare/login?builtin=1` always shows the built-in form.

9. **Reserved paths.** Every path under `/_nagare/` on every host is handled by
   `nagare-access` and never reaches an app or the portal.

`nagare-access` removes `Nagare-Session-Establish` and `Nagare-Session-Clear` from every
upstream response, not just the portal's. It honors them only when the upstream is the
portal, so a compromised protected app cannot mint sessions.

### Milestone 1: backend-map roles and auth-cookie stripping

This milestone lets the enforcer know which backend is the portal, and stops leaking the
enforcer's own cookies to apps. No routing behavior changes yet. At the end, the backend
map accepts both the old format and the new object format, and upstreams no longer see
`nagare_session`, `nagare_refresh`, or `__Host-nagare_csrf`.

**Backend map.** In `cli/nagare-access/src/Nagare/Access/BackendMap.hs`:

- Introduce `newtype PublicHost = PublicHost Text`, a host already put through
  `canonicalHost`. Its only constructor is `mkPublicHost :: Text -> Either Text
  PublicHost`, and the module exports the type without its data constructor.
  - New code passes hosts as `PublicHost`, never as bare `Text`.
  - Existing `Text`-typed host plumbing (for example `DecisionKey`) is converted only
    where this plan touches it.
- Give `BackendTarget` a role:

  ```haskell
  data BackendRole = ProtectedBackend | PortalBackend
    deriving stock (Eq, Show)

  data BackendTarget = BackendTarget
    { upstreamUrl :: !Text
    , backendRole :: !BackendRole
    }
  ```

- The map becomes `newtype BackendMap = BackendMap (Map PublicHost BackendTarget)`.
- `decodeBackendMap` accepts, for each host, either:
  - a JSON string, which means `ProtectedBackend` (today's format, so existing
    ConfigMaps keep working), or
  - an object `{"upstream": "<url>", "role": "protected" | "portal"}`.

  Write a `FromJSON BackendTarget` instance that handles both shapes. Any other shape,
  an unknown role, or more than one `portal` entry is a decode error whose message
  names the offending host.
- Add a `Portal` value (see Interfaces and Dependencies), plus:
  - `findPortal :: BackendMap -> Maybe Portal`
  - `isRoutedHost :: PublicHost -> BackendMap -> Bool`
- `backendMapFromList :: [(Text, Text)] -> Either Text BackendMap` keeps its type for
  existing callers (all entries protected), and
  `backendMapFromTargets :: [(Text, BackendTarget)] -> Either Text BackendMap` is added.
- Update every construction of `BackendTarget` in `cli/nagare-access/src` and
  `cli/nagare-access/test/Spec.hs`.

**Cookie stripping.** In `cli/nagare-access/src/Nagare/Access/Proxy.hs`, add
`stripEnforcerCookies :: [Header] -> [Header]`.

- It rewrites every `Cookie` header, dropping the pairs named `nagare_session`,
  `nagare_refresh`, and `__Host-nagare_csrf`, and drops the header entirely if nothing
  remains.
- Apply it in both `hardenRequestHeaders` and `hardenWebSocketRequestHeaders`, before
  the forwarded headers are appended.
- Parse cookie pairs the same way `parseCookieHeader` in `App.hs` does (split on `;`,
  trim spaces, split at the first `=`). Rebuild the kept pairs joined with `"; "`.

**Tests.** Add to `cli/nagare-access/test/Spec.hs`:

- In `backendMapTests`:
  - the old string format decodes as protected;
  - the object format decodes both roles;
  - two portals are rejected, with the error naming a host;
  - an unknown role is rejected;
  - `findPortal` finds the portal.
- In `proxyTests`, a `hardenRequestHeaders` case with
  `Cookie: theme=dark; nagare_session=abc; nagare_refresh=v1.x.y; __Host-nagare_csrf=z; lang=en`
  yields exactly `Cookie: theme=dark; lang=en`, and a header containing only enforcer
  cookies is removed.

Acceptance: `cabal test nagare-access-test` passes, including the new cases. The
existing test that forwards to `identityUpstreamApp` still passes.

### Milestone 2: portal routing mode and session hand-off

At the end of this milestone, a request to the portal host is proxied with optional
identity. A portal response can create or clear a session, and logout revokes the Shomei
session. Protected-host behavior is unchanged except for the logout revocation.

**New module.** Create `cli/nagare-access/src/Nagare/Access/Portal.hs`, added to
`exposed-modules` in `cli/nagare-access/nagare-access.cabal`. It holds the portal
vocabulary listed in Interfaces and Dependencies:

- the `AccessToken` and `RefreshToken` newtypes;
- `PortalIdentity`, `SessionHandoff`, `CapturedResponse`, `PortalUpstreamResult`,
  `PortalPageKind`, `PortalPageRequest`, `PortalPage`, `SafePath`, and
  `ReturnTarget`;
- the pure functions that decode and render them.

Keeping the contract in one module keeps `App.hs` about routing and `Proxy.hs` about
HTTP.

`decodeSessionHandoff :: ByteString -> Either Text SessionHandoff` base64url-decodes the
header value and parses the JSON with a `FromJSON SessionHandoff` instance. Both token
fields are required, and `returnTo` is optional.

**New service functions.** Extend `AccessServices` in
`cli/nagare-access/src/Nagare/Access/Auth.hs`:

- `revokeSession :: !(AccessToken -> IO ())`: revoke the Shomei session that owns this
  access token, best effort. Log failures and never throw.
- `forwardPortal :: !(Portal -> PortalIdentity -> Request -> IO PortalUpstreamResult)`:
  proxy to the portal and report whether the response asked for a session change.
- `fetchPortalPage :: !(Portal -> PortalPageRequest -> IO (Maybe PortalPage))`: used in
  Milestone 3. Add it now with a stub that returns `Nothing`, so the record changes
  once.

**Real implementations.**

- `revokeSession`: add `logoutWithShomei :: Shomei.ClientEnv -> AccessToken -> IO ()` to
  `cli/nagare-access/src/Nagare/Access/ShomeiClient.hs`. It calls Shomei's
  `POST /v1/auth/logout` with `Authorization: Bearer`. Use the generated `Shomei.Client`
  function if it exposes one; otherwise issue the request with the existing
  `http-client` manager. Record which you used in the Decision Log.
- `forwardPortal`: add `portalForwarder :: HC.Manager -> Portal -> PortalIdentity ->
  Wai.Request -> IO PortalUpstreamResult` to `Proxy.hs`.
  - It builds the upstream request like `buildProxyRequest`. It first strips any
    client `Authorization`, `X-Forwarded-User`, `Nagare-Session-Establish`, and
    `Nagare-Session-Clear`, and then adds `X-Forwarded-User` and
    `Authorization: Bearer` only for `PortalAuthenticated`.
  - It opens the response.
    - If the response carries `Nagare-Session-Establish`, it closes the response and
      returns `PortalSessionEstablish` or `PortalHandoffMalformed`, depending on
      `decodeSessionHandoff`.
    - If it carries `Nagare-Session-Clear`, it reads at most 64 KiB of the body into a
      `CapturedResponse`, closes the response, and returns `PortalSessionClear`.
    - Otherwise it returns `PortalPassThrough`, holding the same streaming response
      `proxyResponseToWai` builds.
  - Closing the upstream response before returning is required on the interception
    path. Otherwise the connection leaks, because `proxyResponseToWai` only closes it
    inside the streaming body.
  - WebSocket upgrades to the portal pass through with `hardenWebSocketRequestHeaders`
    and no interception.
- Also add `Nagare-Session-Establish` and `Nagare-Session-Clear` to
  `shouldStripResponseHeader`, so a protected app's response can never carry them to a
  browser.
- Wire all three functions in `cli/nagare-access/app/Main.hs` (`buildAccessServices`).

**Routing.** In `cli/nagare-access/src/Nagare/Access/App.hs`, change the fall-through
branch of `appWithRuntime`: when the looked-up target has `backendRole == PortalBackend`,
call a new `handlePortal`; otherwise call `handleProtected` as today. `handlePortal`
works like this:

1. Authenticate exactly like `authenticateRequest`, except that failure is not a
   challenge.
   - With no credential, or an invalid credential and no usable refresh cookie, the
     identity is `PortalAnonymous`.
   - With a verified credential it is `PortalAuthenticated user token`. The token is
     the access token from the cookie or bearer header, or the refreshed token.
   - Refresh-cookie headers produced during authentication are added to whatever
     response is finally returned.
   - A failed refresh clears the auth cookies, just as `refreshOrChallenge` does.
2. Call `forwardPortal`.
3. For `PortalPassThrough`, return the response with the refresh headers added.
4. For `PortalSessionEstablish handoff`:
   - Verify the handoff's access token with `verifyCredential`.
   - Call `refreshUserSession` with its refresh token. It must return `LoginSucceeded`
     with a new refresh token. Verify that new access token too.
   - Choose the destination with `parseReturnTarget backends (handoffReturnTo handoff)`,
     falling back to `portalHome portal`.
   - Build `sessionHeaders` from the refreshed tokens. Answer `303` with
     `Location: renderReturnTarget target`, or `200 {"redirect": …}` when
     `classifyChallenge` says the request is a JSON API call.
   - On any failure, answer `303` to `portalLoginUrl portal (Just SessionFailed)
     Nothing`, set no cookies, and log one line naming the failing step, never token
     values.
5. For `PortalHandoffMalformed reason`, do the same as a failed hand-off.
6. For `PortalSessionClear captured`:
   - If the identity is authenticated, call `revokeSession` with its token.
   - Return `captured` (status, filtered headers, and the at most 64 KiB body) with the
     clear-cookie headers added.

Write the steps of 4 as one `ExceptT HandoffFailure IO` block, with a
`data HandoffFailure` naming each step. Do not use a ladder of nested `case`s.

**Return targets.** Add to `Nagare.Access.Portal`:

- `newtype SafePath = SafePath Text`, built only by
  `mkSafePath :: Text -> Maybe SafePath`, which wraps the existing
  `safeReturnDestination`.
- `data ReturnTarget = ReturnTarget { targetHost :: PublicHost, targetPath :: SafePath }`.
- `renderReturnTarget :: ReturnTarget -> Text`, which renders `https://host/path`.
- `parseReturnTarget :: BackendMap -> Text -> Maybe ReturnTarget`. It accepts a
  candidate only if all of the following hold:
  - it starts with `https://`;
  - the authority (up to the first `/`, `?`, or `#`) contains no `@` or `\`;
  - `mkPublicHost` accepts the authority, and the resulting host is routed by the
    backend map (`isRoutedHost`, which includes the portal itself);
  - `mkSafePath` accepts the remainder (defaulting to `/`).
- `portalHome :: Portal -> ReturnTarget`, which is the portal host and `/`.

**Logout.** `logoutResponse` becomes `IO Response`.

- It calls `revokeSession` when the request carries a verifiable credential.
- It keeps clearing the cookies.
- The redirect target is `/_nagare/login` when `findPortal backends` is `Nothing`
  (unchanged). With a portal, it is `portalLoginUrl portal (Just LoggedOut) Nothing`.

**Tests.** Add to `cli/nagare-access/test/Spec.hs`, with a `portalBackends` fixture
(one protected host `app.example.test`, and portal `auth.example.test`) and a
`portalServices` fake that records calls in an `IORef`:

- **Anonymous request:** a request to `auth.example.test` with no cookie is forwarded
  with identity `PortalAnonymous` and no challenge. A client-supplied
  `X-Forwarded-User` and `Authorization` do not reach the portal; prove this with a
  real `testWithApplication` stub portal that echoes the headers it received.
- **Signed-in request:** a request with a valid session cookie is forwarded with
  `Authorization: Bearer <that token>`.
- **Establish, document request:** an establish response with a valid payload and
  `returnTo = https://app.example.test/x?y=1` yields `303` to that URL, `Set-Cookie`
  `nagare_session` carrying the refreshed token (not the portal's), and a refresh
  cookie. The fake must record that `refreshUserSession` received the portal's
  refresh token.
- **Establish, API request:** the same with `Accept: application/json` yields `200`
  and `{"redirect":"https://app.example.test/x?y=1"}`.
- **Return URL validation:** `returnTo = https://evil.example/`,
  `https://app.example.test@evil.example/`, `http://app.example.test/`, and
  `https://app.example.test//evil` each fall back to `https://auth.example.test/`.
- **Establish failure:** an establish payload whose access token fails verification
  yields `303` to `/login?error=session` with no `Set-Cookie`.
- **Clear:** a clear response calls `revokeSession` and clears both cookies.
- **Forged headers from a protected app:** a protected-host upstream that returns
  `Nagare-Session-Establish` passes through with the header removed and no cookie set.
- **Logout:** `/_nagare/logout` without a portal still redirects to `/_nagare/login`
  and now calls `revokeSession`. With a portal it redirects to
  `https://auth.example.test/login?logged_out=1`.

Acceptance: all tests pass, and every existing app test passes unmodified except those
whose fixtures had to construct `BackendTarget` or `AccessServices`.

### Milestone 3: portal-driven challenges and branded error pages

At the end of this milestone, when a portal is registered, protected hosts send people
to the portal to sign in and show the portal's 403 and 503 pages. When no portal is
registered, every response is identical to today.

**Challenges.** Add to `Nagare.Access.Portal`:

```haskell
data LoginNotice = SessionFailed | LoggedOut
portalLoginUrl :: Portal -> Maybe LoginNotice -> Maybe ReturnTarget -> Text
```

It renders `https://P/login`, with `error=session` or `logged_out=1` for the notice, and
`return_to=<urlencoded renderReturnTarget target>` for the target. Encode with
`urlEncode True`, as `loginPathFor` does.

Change `classifyChallenge`'s callers, not `classifyChallenge` itself.

- Introduce, in `App.hs`:

  ```haskell
  data LoginPage = BuiltinLoginPage | PortalLoginPage Portal
  ```

  It is computed once per request as `maybe BuiltinLoginPage PortalLoginPage (findPortal backends)`.
- `handleProtected` and `refreshOrChallenge` take the `LoginPage`. The location is
  `loginPathFor path` for `BuiltinLoginPage` (today's behavior). For `PortalLoginPage
  portal` it is `portalLoginUrl portal Nothing (ReturnTarget host <$> mkSafePath path)`.
- `Response.challengeResponse` keeps its type. `ChallengeMode` already carries the
  location text, so only the text changes.

**The built-in login route.** In `appWithRuntime`, the `GET /_nagare/login` branch cases
on `LoginPage`:

- `BuiltinLoginPage`: today's form.
- `PortalLoginPage _` with `builtin=1` in the query: today's form. Its hidden `rd`
  field posts back to `/_nagare/login`, and that POST path is unchanged.
- `PortalLoginPage portal` otherwise: `302` to
  `portalLoginUrl portal Nothing (ReturnTarget requestHost <$> mkSafePath rd)`.

**Branded errors.**

- In `handleProtected`, for `AuthorizationDecision _` (403) and
  `AuthorizationUnavailable _` (503), when the challenge mode is `RedirectDocument` and
  the `LoginPage` is `PortalLoginPage portal`, call
  `fetchPortalPage portal PortalPageRequest{…}`.
  - `Just page` becomes `portalPageResponse status page`, which is
    `text/html; charset=utf-8` with `Cache-Control: no-store`.
  - `Nothing` keeps today's response.
  - JSON requests and `BuiltinLoginPage` keep today's responses exactly.
- Implement `portalPageFetcher :: HC.Manager -> Portal -> PortalPageRequest -> IO (Maybe PortalPage)`
  in `Proxy.hs`:
  - It sends `GET upstream + "/errors/403"` or `"/errors/503"` with the contract
    headers, and uses `HC.responseTimeout = HC.responseTimeoutMicro 2000000`.
  - It requires status 200 and a `Content-Type` starting with `text/html`.
  - It reads with a 256 KiB cap (stop and return `Nothing` if exceeded), and catches
    every `HttpException` as `Nothing`.
  - Wire it in `Main.hs`.

**Tests.**

- With no portal, the existing 302 (`/_nagare/login?rd=%2F`), JSON 401, 403, and 503
  tests are unchanged and pass.
- With `portalBackends`:
  - A document request to `app.example.test/x?y=1` with no session yields `302` to
    `https://auth.example.test/login?return_to=https%3A%2F%2Fapp.example.test%2Fx%3Fy%3D1`.
  - The JSON variant's body has that absolute URL in `login`.
  - `GET /_nagare/login` on `app.example.test` yields `302` to the portal.
  - `GET /_nagare/login?builtin=1` yields the built-in form (body contains
    `<h1>Sign in</h1>`).
  - A denied document request whose `fetchPortalPage` returns
    `Just (PortalPage "<p>portal 403</p>")` yields `403` with that body.
  - When it returns `Nothing`, the body is `Forbidden`.
  - The same pair of checks holds for 503.
- A real-socket test of `portalPageFetcher`:
  - a stub that sleeps three seconds yields `Nothing`;
  - a stub returning `text/plain` yields `Nothing`;
  - a stub returning 300 KiB yields `Nothing`;
  - a stub returning a small HTML page yields `Just`, and the stub received
    `X-Nagare-Error-Host`.

Acceptance: `cabal test nagare-access-test` passes.

### Milestone 4: DSL and nagarectl wiring

At the end of this milestone an operator can mark an app as the portal in `Config.hs`.
`nagarectl deploy` then registers it, configures Shomei for it, and refuses unsafe
setups, and deleting the app unregisters it.

**DSL.** In `cli/nagare-dsl/src/Nagare/Dsl/Access.hs`:

- Add `data AccessRole = ProtectedSite | AuthPortal deriving stock (Generic, Eq, Show)`
  and a field `role :: !AccessRole` on `AccessPolicy`.
- `requireLogin` gets `role = ProtectedSite`.
- Add `authPortal :: AccessPolicy` with `role = AuthPortal`, `audience = Nothing`,
  `permission = AccessPermission "access"`. The permission is unused for portals.
- Export `AccessRole (..)` and `authPortal`.
- In `accessPolicyJSON` (`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`), add
  `"role" .= ("protected" | "portal")`.
- In `JsonAccessPolicy` (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`), read
  `o .:? "role" .!= "protected"`. `toAccessPolicy` maps the two strings and fails with
  `MarshalError "access.role"` otherwise.
- Existing configs that construct `AccessPolicy` with record syntax would break. Search
  `cluster/examples` and the test suites for `AccessPolicy {` and update any hits.
  `requireLogin` users are unaffected.

**Resolver.** In `cli/nagarectl/src/Nagare/Access/Resolve.hs`:

- **Backend map type.** Replace the raw `Map Text Text` with a real type:

  ```haskell
  newtype BackendMap = BackendMap (Map PublicHost BackendEntry)
  ```

  - `BackendEntry` holds the upstream and an `EntryRole` (`ProtectedEntry` or
    `PortalEntry`), and `PublicHost` is a canonical host with a smart constructor.
  - `FromJSON`/`ToJSON` instances for `BackendEntry` accept both JSON shapes, mirroring
    Milestone 1. They render a plain string for protected entries, so existing
    ConfigMaps do not churn, and `{"upstream":…,"role":"portal"}` for the portal.
  - An absent ConfigMap is simply `mempty`. It is not a separate `Maybe` layer, because
    every caller already treats "absent" and "empty" the same way.
- **Refactor `AccessOps` instead of growing it.** Today's
  `loadBackendMap :: IO (Either Text (Maybe (Map Text Text)))` pushes decoding
  failures, absence, and the map's representation onto every caller.
  - Replace it with a small store interface whose operations return domain values:
    `loadBackends :: IO BackendMap` and `saveBackends :: BackendMap -> IO ()`.
    `saveBackends` writes the ConfigMap and patches the reload annotation, since the
    two always happen together.
  - A ConfigMap that exists but does not decode is a fatal error at the `kubectl`
    boundary. `kubectlAccessOps` reports it with `dieT`, exactly as the resolver does
    today, so the pure resolution logic never sees an `Either`.
  - Routes and Shomei changes are described as data (`RouteOp`, `ShomeiPortalChange`)
    and interpreted by one operation each. The full record is in Interfaces and
    Dependencies.
- **Registering with `Just policy`:** the entry's role follows `policy ^. #role`.
- **Refusal: portal outside the base domain.** Before writing a portal entry, refuse
  (with `dieT`) if the host does not end in `"." <> baseDomain`:

  ```text
  the auth portal host auth.other.example is not under the base domain labs.example.net.
         Session cookies are scoped to .labs.example.net, so a portal elsewhere could not sign anyone in.
  ```

  `resolveAccessRouteWithOps` does not currently receive `baseDomain`, so pass it
  through from `resolveDeploymentAccessWithOps`.
- **Refusal: a second portal.** Refuse if a different host already has `PortalEntry`:

  ```text
  auth.labs.example.net is already the auth portal (service auth-portal).
         Remove `access = Just authPortal` from that app (or delete it) before registering another portal.
  ```

  Name the service from the existing entry's upstream URL.
- **Portal with several domains.** A portal app with more than one domain is refused
  ("an auth portal must have exactly one public host").
- **Configuring Shomei.** After saving a portal entry, call
  `applyShomeiPortal ops (EnablePortal host baseDomain)`. It is idempotent. The real
  implementation (`kubectlAccessOps`):
  1. Reads the current `SHOMEI_WEBAUTHN_ORIGINS` from
     `kubectl -n nagare-system get deployment shomei -o json`
     (`.spec.template.spec.containers[0].env`).
  2. Parses it into `[Origin]` and computes `addOrigin (portalOrigin host)`, which keeps
     order and removes duplicates.
  3. If anything differs, runs:

     ```bash
     kubectl -n nagare-system set env deployment/shomei \
       SHOMEI_WEBAUTHN_RP_ID=<base domain> \
       SHOMEI_WEBAUTHN_ORIGINS=<union> \
       SHOMEI_PUBLIC_BASE_URL=https://<portal host>
     ```

     Changing env rolls the Deployment. If nothing differs, it runs nothing.
- **When a portal entry is removed** (policy `Nothing`, or role switched to protected),
  call `applyShomeiPortal ops (DisablePortal host)`. It removes that origin from
  `SHOMEI_WEBAUTHN_ORIGINS` and unsets `SHOMEI_PUBLIC_BASE_URL` with
  `kubectl set env deployment/shomei SHOMEI_PUBLIC_BASE_URL-`. It leaves
  `SHOMEI_WEBAUTHN_RP_ID` in place, because local mode sets it for `protected-hello`
  too.

**Cleanup on delete.** In `cli/nagarectl/src/Nagare/App.hs` (`deleteApp`), before deleting
the Knative Service:

- Load the backend map.
- Remove every entry whose upstream is `http://<name>.<ns>.svc.cluster.local`.
- If any were removed:
  - save the map;
  - apply `DeleteEnforcerRoute` for each removed host (a new `RouteOp` constructor,
    interpreted as
    `kubectl -n nagare-system delete domainmapping <host> --ignore-not-found`);
  - if one of them was the portal, apply `DisablePortal`.
- Put this logic in `Nagare.Access.Resolve` as
  `removeServiceAccessWithOps :: AccessOps -> Namespace -> ServiceName -> IO [PublicHost]`,
  so it is testable with `fakeOps`. `deleteApp` calls the `kubectlAccessOps` version.
- A missing ConfigMap or a missing `nagare-access` is a no-op, so deleting apps on
  clusters without the auth plane keeps working.

**CLI.** In `cli/nagarectl/app/Main.hs`, extend `accessSubparser` with a `portal` group:

- `nagarectl access portal show` prints `portal: <host> -> <upstream>` or
  `portal: (none; protected sites use the built-in sign-in pages)`.
- `nagarectl access portal sync` re-applies `EnablePortal` for the registered
  portal, and prints `no portal registered` and exits 0 when there is none.

`sync` exists for the case where `cluster/bootstrap/auth-install.sh` is re-run and
replaces Shomei's env. Milestone 6 checks whether that happens and documents the answer.

**Tests.**

- In `cli/nagare-dsl/test`: `authPortal` round-trips through `accessPolicyJSON` and
  `toAccessPolicy`, and JSON without `role` loads as `ProtectedSite`.
- In `cli/nagarectl/test/AccessResolveSpec.hs`, rework `fakeOps` for the new `AccessOps`
  (an `IORef BackendMap` as the store, recording `Saved`, `Routed`, and `ShomeiChanged
  ShomeiPortalChange` events):
  - a portal deploy writes `{"upstream":…,"role":"portal"}`, reloads, routes to
    `nagare-access`, and configures Shomei with the host and base domain;
  - a second portal host is refused, with nothing written;
  - a portal outside the base domain is refused;
  - redeploying the same portal is idempotent (same map written);
  - switching the portal app to `access = Nothing` removes the entry and unconfigures
    Shomei;
  - `removeServiceAccessWithOps` removes only that service's hosts and returns them;
  - loading an old all-string ConfigMap still works, and re-rendering it produces
    identical JSON.
- Pure tests for `addOrigin` and `removeOrigin` (order kept, no duplicates, removing an
  absent origin is a no-op), and for `BackendEntry`'s JSON round trip.

Acceptance: `cabal test nagare-dsl-test` and `cabal test nagarectl-test` pass. In addition,
`nagarectl deploy --dry-run` on the reference portal config (Milestone 5) shows no
access YAML, as today.

### Milestone 5: the reference portal

At the end of this milestone `cluster/examples/auth-portal` is a deployable portal that
implements the whole contract with only Node's standard library. An offline script
proves its contract behavior against a fake Shomei.

**Files.**

- `cluster/examples/auth-portal/server.mjs`: the portal.
- `cluster/examples/auth-portal/views.mjs`: HTML templates as functions. Every
  interpolated value goes through one `escapeHtml` function.
- `cluster/examples/auth-portal/public/portal.css` and `public/passkey.js`.
- `cluster/examples/auth-portal/Dockerfile`: `node:22-alpine`, non-root user, `EXPOSE 8080`.
- `cluster/examples/auth-portal/nagare/Config.hs`: modeled on
  `cluster/examples/protected-hello/nagare/Config.hs` and the Dockerfile build in
  `cluster/examples/dockerfile-app`.
  - Service `auth-portal`, namespace `personal`, `DockerfileBuild`.
  - Domain `auth.<NAGARE_BASE_DOMAIN>` (defaulting to `apps.example.com`), port 8080.
  - Env `SHOMEI_URL=http://shomei.nagare-system.svc.cluster.local`,
    `PORTAL_TITLE=Nagare`, `PORTAL_ALLOW_SIGNUP=false`.
  - `access = Just authPortal`.
- `cluster/examples/auth-portal/README.md`.
- `cluster/examples/auth-portal/test/contract-test.mjs`: the offline test.

**Behavior of `server.mjs`** (all Shomei calls are server-side `fetch` to `SHOMEI_URL`):

- **CSRF.** Every form page sets a `portal_csrf` cookie (random, `HttpOnly; Secure;
  SameSite=Lax; Path=/`) and embeds the same value, and every POST compares them. The
  portal's cookies are its own, so they never collide with `nagare_*`.
- **`GET /login`.** Renders the sign-in form. It carries `return_to` through a hidden
  field, and shows notices for `error=session`, `logged_out=1`, and `reset=1`. It also
  offers a "Sign in with a passkey" button (passwordless) and links to
  `/password/forgot` and, if sign-up is allowed, `/signup`.
- **`POST /login`.** Calls `POST /v1/auth/login`.
  - On `complete`, it responds `204` with `Nagare-Session-Establish` built from the
    token and `returnTo`.
  - On `mfa_required`, it renders the passkey page with `ceremonyId`, `options`, and
    `return_to` embedded as JSON in a `<script type="application/json">` block (never
    in inline JS).
  - On a problem response, it re-renders the form with a generic "Sign-in failed"
    message.
- **`POST /login/mfa`** (JSON, called by `public/passkey.js`). Calls
  `POST /v1/auth/mfa/complete` with `{ceremonyId, proof:{type:"passkey", assertion}}` and
  answers with `Nagare-Session-Establish`. Because the browser request has
  `Accept: application/json`, `nagare-access` turns this into
  `200 {"redirect": …}`, and the script navigates there.
- **`POST /login/passkey/begin`** and **`POST /login/passkey/complete`**. Proxy
  passwordless sign-in to Shomei. The complete step answers with
  `Nagare-Session-Establish`.
- **`GET/POST /signup`.** Returns 404 unless `PORTAL_ALLOW_SIGNUP=true`. Calls
  `POST /v1/auth/signup` and then establishes a session.
- **`GET/POST /password/forgot`.** Calls `POST /v1/auth/password-reset/request` and
  always shows "If that address exists, we sent a link", so it does not reveal whether
  an account exists.
- **`GET /v1/auth/password-reset/confirm?token=…`** and its POST. The GET renders a
  new-password form, and the POST calls Shomei's confirm and redirects to
  `/login?reset=1`.
- **`GET /v1/auth/verify-email/confirm?token=…`.** Calls Shomei's confirm and renders the
  result.
- **`GET /account`.** Requires `Authorization`; without it, it redirects to
  `/login?return_to=https://<X-Forwarded-Host>/account`. It calls `GET /v1/auth/me` and
  renders the login name, display name, and email, a change-password form, the
  passkey list (`GET /v1/auth/passkeys`) with delete buttons, an "Add a passkey"
  button, and a sign-out link to `/_nagare/logout`.
- **`POST /account/password`.** Calls `POST /v1/auth/password/change` with the bearer
  token.
- **`POST /account/passkeys/begin`**, **`/complete`**, and
  **`/account/passkeys/<id>/delete`.** Call the Shomei passkey endpoints with the
  bearer token.
- **`GET /errors/403`.** Renders "You don't have access to <X-Nagare-Error-Host>". It
  shows who is signed in (from `X-Forwarded-User`, display only), a link to
  `/_nagare/logout` ("Switch account"), and a link back to `X-Nagare-Return-To`.
- **`GET /errors/503`.** Renders "Sign-in is temporarily unavailable" with a retry
  link.
- **Other paths.** `GET /` redirects to `/account`, `GET /healthz` returns `ok`, and
  `/public/*` serves the static files.

Branding is controlled by `PORTAL_TITLE`, an optional `PORTAL_LOGO_URL`, and
`public/portal.css`.

**Contract test.** `cluster/examples/auth-portal/test/contract-test.mjs` starts a fake
Shomei (a `node:http` server with canned responses) and the portal on ephemeral ports,
then checks:

1. `POST /login` with a correct CSRF token and a fake "complete" login answers with a
   decodable `Nagare-Session-Establish` whose `returnTo` equals the posted `return_to`.
2. `mfa_required` renders the passkey page.
3. A missing or mismatched CSRF token answers 403 without calling the fake Shomei.
4. `GET /account` without `Authorization` redirects to `/login`.
5. `GET /account` with a bearer token calls `/v1/auth/me` with that bearer token and
   renders the login name HTML-escaped (use the login id `<b>eve</b>`).
6. `GET /errors/403` escapes `X-Nagare-Error-Host`.
7. `/signup` is 404 by default.

Run it with `node --test cluster/examples/auth-portal/test/contract-test.mjs`.

Acceptance: the contract test passes with Node 22, and
`docker build --platform linux/amd64 cluster/examples/auth-portal` succeeds.

### Milestone 6: documentation and local end-to-end validation

At the end of this milestone the contract is documented for operators, and the whole
scenario has been observed on a local k3d cluster, with the transcript recorded in this
plan.

**Documentation.**

- Write `docs/user/auth-portal.md`, a Runbook with the same frontmatter shape as
  `docs/user/access.md` (with its own `docId`; check `docs/user/index.md` for the next
  free one). It restates the portal contract from this plan in operator language,
  covers deploy and removal of the reference portal, explains the break-glass URL,
  and describes the security model: the portal is trusted with users' passwords and
  access tokens; it never sees the cookie key; tokens handed to `nagare-access` are
  rotated.
- Link it from `docs/user/access.md` (a new "Customize sign-in with an auth portal"
  section) and from `docs/user/index.md`.
- In `cluster/bootstrap/nagare-access/README.md`, note that the backend map may now hold a
  portal entry.
- Create an ADR: a new file under `docs/adr/`, with the next number after the highest
  existing one, following the format of
  `docs/adr/0011-host-activation-is-guarded-and-self-reverting.md`. Title: "The auth
  portal hands sessions to nagare-access through response headers". It records the
  cookie-ownership and hand-off decisions from the Decision Log.

**Local validation.** Run the scenario in Validation and Acceptance on the local k3d
path, record the transcript in Surprises & Discoveries or Outcomes, and fix anything it
exposes. Specifically confirm and record:

1. whether re-running `cluster/bootstrap/local-auth/install.sh` keeps the Shomei env
   set by `nagarectl` (the 2026-09-13 run kept it; the docs retain `nagarectl access
   portal sync` as an explicit repair command);
2. whether Shomei's password change revokes the current session;
3. where the log notifier prints reset links, for the forgot-password check.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, unless a
`cd` is shown. Do not `git add -A`; stage explicit paths.

**Milestones 1–3** (repeat after each change):

```bash
cd cli/nagare-access
cabal build all
cabal test nagare-access-test --test-show-details=streaming
```

Expected tail:

```text
All N tests passed (…s)
```

**Milestone 4:**

```bash
cd cli/nagare-dsl && cabal test nagare-dsl-test
cd ../nagarectl && cabal test nagarectl-test
```

**Milestone 5:**

```bash
node --test cluster/examples/auth-portal/test/contract-test.mjs
docker build --platform linux/amd64 -t auth-portal:dev cluster/examples/auth-portal
```

Expected test output ends with:

```text
# pass 7
# fail 0
```

**Milestone 6** (local cluster; follow `docs/user/local-development.md` first so the
active context has `mode=local` and `NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io`). Build and
install the auth plane from this working tree:

```bash
nagarectl context show            # confirm mode=local before anything else
for service in shomei en nagare-access; do
  cluster/bootstrap/auth-images/build-local-image.sh "$service"
done
cluster/bootstrap/local-auth/install.sh
kubectl -n cert-manager get secret nagare-local-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/nagare-local-ca.pem
```

The local image build and push flow is described in `docs/user/local-development.md`
("Optional: the auth plane"); follow that if the command above differs for your setup.

Deploy the protected example and the portal, then check the registration:

```bash
nagarectl deploy -f cluster/examples/protected-hello/nagare/Config.hs
(cd cluster/examples/auth-portal && nagarectl deploy -f nagare/Config.hs)
nagarectl access portal show
```

Expected:

```text
portal: auth.127-0-0-1.sslip.io -> http://auth-portal.personal.svc.cluster.local
```

Create a test user. Shomei 0.2 reads the password from stdin:

```bash
printf '%s\n' 'correct horse battery staple' | \
  kubectl -n nagare-system exec -i deploy/shomei -- \
  shomei-admin users create --email dev@example.test --email-verified
```

Note the printed user id (`user_01…`); the steps below call it `$USER_ID`.


## Validation and Acceptance

**Offline acceptance** is the three test commands above, all passing. The critical new
tests are:

- the backend-map role decoding;
- cookie stripping;
- portal forwarding with and without identity;
- hand-off with refresh rotation and return-URL rejection;
- forged hand-off headers from protected apps being dropped;
- portal challenge URLs;
- branded error bodies with fallback;
- the unchanged no-portal responses;
- resolver refusals and delete cleanup;
- the portal contract test.

**End-to-end acceptance** runs on the local cluster after the Concrete Steps. Let
`CA=/tmp/nagare-local-ca.pem`, `APP=https://protected-hello.127-0-0-1.sslip.io`,
`P=https://auth.127-0-0-1.sslip.io`, and `JAR=$(mktemp)`.

1. **Unauthenticated visitors go to the portal.**

   ```bash
   curl -sS --cacert $CA -o /dev/null -w '%{http_code} %{redirect_url}\n' "$APP/hello?x=1"
   ```

   ```text
   302 https://auth.127-0-0-1.sslip.io/login?return_to=https%3A%2F%2Fprotected-hello.127-0-0-1.sslip.io%2Fhello%3Fx%3D1
   ```

2. **Password sign-in through the portal sets the parent-domain session.** Fetch the
   form (this stores `portal_csrf`), extract the token, and post:

   ```bash
   CSRF=$(curl -sS --cacert $CA -c $JAR "$P/login?return_to=$APP/" | sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p')
   curl -sS --cacert $CA -b $JAR -c $JAR -o /dev/null -D - \
     --data-urlencode "csrf=$CSRF" --data-urlencode "return_to=$APP/" \
     --data-urlencode loginId=dev@example.test \
     --data-urlencode 'password=correct horse battery staple' "$P/login" | grep -Ei '^(HTTP|location|set-cookie)'
   ```

   Expect `HTTP/2 303`, `location: https://protected-hello.127-0-0-1.sslip.io/`, and a
   `set-cookie: nagare_session=…; Domain=.127-0-0-1.sslip.io` line. The response must not
   contain any `nagare-session-establish` header.

3. **Signed in but not granted: the portal's branded 403.**

   ```bash
   curl -sS --cacert $CA -b $JAR -o /tmp/body -w '%{http_code}\n' "$APP/" && grep -c "have access" /tmp/body
   ```

   ```text
   403
   1
   ```

4. **Grant, then 200.** Port-forward En as described in `docs/user/access.md`
   ("Manage grants"), then:

   ```bash
   nagarectl access grant --host protected-hello.127-0-0-1.sslip.io --user "$USER_ID"
   ```

   Poll for up to 40 seconds (En publishes revisions with a delay, and the decision cache
   holds for 30 seconds):

   ```bash
   curl -sS --cacert $CA -b $JAR -o /dev/null -w '%{http_code}\n' "$APP/"
   ```

   ```text
   200
   ```

5. **The portal sees the user.**

   ```bash
   curl -sS --cacert $CA -b $JAR "$P/account" | grep -c dev@example.test
   ```

   ```text
   1
   ```

6. **Change password.** Post the change-password form on `/account` (fetch CSRF the
   same way as in step 2), then repeat step 2 with the new password. Expect `303` and a
   new session. Record whether the old `JAR` session still works (Milestone 6 item 2).

7. **Branded 503 with fallback.**

   ```bash
   kubectl -n nagare-system scale deploy/en --replicas=0
   ```

   After the decision cache expires (30 seconds), a request with the session returns
   `503` whose body contains "temporarily unavailable". Knative interprets a maximum
   scale of zero as unlimited, so it cannot disable the portal. For this failure-only
   check, preserve the map, change the portal entry's upstream to a nonexistent
   cluster-local Service, apply the ConfigMap, and force the normal enforcer reload:

   ```bash
   BACKENDS=$(kubectl -n nagare-system get cm nagare-access-backends \
     -o go-template='{{index .data "backends.json"}}')
   BROKEN=$(printf '%s' "$BACKENDS" | jq -c \
     '."auth.127-0-0-1.sslip.io".upstream="http://auth-portal-unavailable.personal.svc.cluster.local"')
   kubectl -n nagare-system create configmap nagare-access-backends \
     --from-literal="backends.json=$BROKEN" --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n nagare-system patch ksvc nagare-access --type=merge \
     -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/backend-map-reload\":\"fallback-$(date +%s)\"}}}}}"
   ```

   The same request must still return `503` with the built-in body `authorization
   service unavailable`. Restore both; redeploying the portal restores its map entry:

   ```bash
   kubectl -n nagare-system scale deploy/en --replicas=1
   (cd cluster/examples/auth-portal && nagarectl deploy -f nagare/Config.hs)
   ```

8. **Break-glass.**

   ```bash
   curl -sS --cacert $CA "$APP/_nagare/login?builtin=1" | grep -c '<h1>Sign in</h1>'
   ```

   ```text
   1
   ```

9. **Logout revokes the session.**

   ```bash
   curl -sS --cacert $CA -b $JAR -c $JAR -o /dev/null -w '%{http_code} %{redirect_url}\n' "$P/_nagare/logout"
   ```

   ```text
   302 https://auth.127-0-0-1.sslip.io/login?logged_out=1
   ```

   Replaying the old `nagare_refresh` value against Shomei's refresh endpoint must fail
   with 401. Check it from inside the cluster with a throwaway `curlimages/curl` pod
   posting `{"refreshToken": …}` to `http://shomei.nagare-system.svc.cluster.local/v1/auth/refresh`.
   Take the token from the cookie jar before logging out, decoding the `v1.<b64>.<mac>`
   middle part.

10. **Passkeys (manual, real browser).** Trust the CA as described in
    `cluster/bootstrap/local-tls/README.md`.
    - Open `$P/account`, sign in, choose "Add a passkey", and complete the browser
      prompt.
    - Sign out, open `$APP/`, and sign in with the password. The portal must show the
      passkey step, and completing it lands on the app.
    - Also try "Sign in with a passkey" on the login page.

11. **Removing the portal restores the defaults.**

    ```bash
    (cd cluster/examples/auth-portal && nagarectl app delete auth-portal --namespace personal --file nagare/Config.hs)
    nagarectl access portal show
    curl -sS --cacert $CA -o /dev/null -w '%{http_code} %{redirect_url}\n' "$APP/"
    ```

    ```text
    portal: (none; protected sites use the built-in sign-in pages)
    302 https://protected-hello.127-0-0-1.sslip.io/_nagare/login?rd=%2F
    ```

    `kubectl -n nagare-system get deploy shomei -o yaml` no longer lists
    `https://auth.127-0-0-1.sslip.io` in `SHOMEI_WEBAUTHN_ORIGINS`.

The plan is complete when all eleven checks pass on the local cluster and the offline
suites pass. Cloud validation is not required by this plan. It needs human approval for
each cloud-mutating command under the repository rules, so it is left to the operator
using `docs/user/auth-portal.md`.


## Idempotence and Recovery

Code milestones are additive and can be retried freely. Every test command is safe to
re-run.

**Deploy-time registration is idempotent.**

- Deploying the portal twice writes the same backend map.
- `applyShomeiPortal (EnablePortal …)` changes nothing when the origin and base URL are
  already present, so it does not roll Shomei needlessly.
- `nagarectl access portal sync` can be run any number of times.

**Recovery when a portal breaks sign-in on a live cluster.** Use these in order:

1. Sign in with the built-in form at `https://<protected host>/_nagare/login?builtin=1`.
2. Remove the portal's registration by deploying the portal app with
   `access = Nothing`, or by deleting it. Every protected host then falls back to the
   built-in pages as soon as `nagare-access` rolls to the new revision.
3. As a last resort, edit the ConfigMap by hand. Remove the entry whose value has
   `"role":"portal"` from `backends.json` in `nagare-access-backends`, then patch the
   annotation `nagare.dev/backend-map-reload` on `ksvc/nagare-access` to a new value.
   This is exactly what `nagarectl` does.

On a cloud context, any of these kubectl mutations requires the operator's approval
under the repository rules.

**Rolling back the code.** An old `nagare-access` image cannot parse a backend map that
contains an object entry. Remove the portal registration (recovery step 2) before
deploying an older `nagare-access` image. Protected-only maps keep the old string format
and stay compatible in both directions.

**Local end-to-end checks.** Step 7 scales En and the portal down; its own last command
restores them. If a check is interrupted, run `kubectl -n nagare-system scale deploy/en
--replicas=1` and redeploy the portal.


## Interfaces and Dependencies

No new npm dependencies or externally sourced Haskell packages are added. Milestone 2
adds the compiler-bundled `transformers` package as a direct Cabal dependency because
the required `ExceptT` hand-off block imports `Control.Monad.Trans.Except`; the package
was already present in the compiler package set.

- `nagare-access` keeps using `wai`, `http-client`, `http-types`, `aeson`, `base64`
  handling from `memory`/`crypton` (`Data.ByteArray.Encoding`, already used in
  `Cookie.hs`), and the Shomei client already pinned in
  `cli/nagare-access/cabal.project`.
- The reference portal uses Node 22's standard library only.

The signatures below are the shape the code must have at the end of each milestone. They
follow two rules. Values that mean different things get different types, so a portal
host, a return URL, an access token, and a refresh token can never be swapped for one
another. And effectful records return domain values, while decoding failures and
absence are handled at the boundary that talks to `kubectl` or HTTP, never threaded
through every caller as `Either`/`Maybe` layers.

At the end of Milestone 1, in `cli/nagare-access/src/Nagare/Access/BackendMap.hs`:

```haskell
-- | A host already canonicalized (lowercase, no port, no trailing dot).
newtype PublicHost = PublicHost Text
  deriving stock (Eq, Ord, Show)

mkPublicHost :: Text -> Either Text PublicHost
publicHostText :: PublicHost -> Text

data BackendRole = ProtectedBackend | PortalBackend
  deriving stock (Eq, Show)

data BackendTarget = BackendTarget
  { upstreamUrl :: !Text
  , backendRole :: !BackendRole
  }
  deriving stock (Eq, Show)

newtype BackendMap = BackendMap (Map PublicHost BackendTarget)
  deriving stock (Eq, Show)

data Portal = Portal
  { portalHost :: !PublicHost
  , portalTarget :: !BackendTarget
  }
  deriving stock (Eq, Show)

backendMapFromTargets :: [(Text, BackendTarget)] -> Either Text BackendMap
findPortal :: BackendMap -> Maybe Portal
isRoutedHost :: PublicHost -> BackendMap -> Bool
```

and in `cli/nagare-access/src/Nagare/Access/Proxy.hs`:

```haskell
stripEnforcerCookies :: [Header] -> [Header]
```

At the end of Milestone 2, the new module `cli/nagare-access/src/Nagare/Access/Portal.hs`
holds the contract vocabulary. It imports `Nagare.Access.BackendMap` and
`Nagare.Access.Challenge`, but not `Nagare.Access.Auth`, so that `Auth` can import it
without an import cycle:

```haskell
newtype AccessToken = AccessToken Text
  deriving stock (Eq, Show)

newtype RefreshToken = RefreshToken Text
  deriving stock (Eq, Show)

-- | What the portal hands back after a completed sign-in.
data SessionHandoff = SessionHandoff
  { handoffAccessToken :: !AccessToken
  , handoffRefreshToken :: !RefreshToken
  , handoffReturnTo :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON SessionHandoff

decodeSessionHandoff :: ByteString -> Either Text SessionHandoff

-- | A portal response that nagare-access has read into memory (bounded).
data CapturedResponse = CapturedResponse
  { capturedStatus :: !Status
  , capturedHeaders :: ![Header]
  , capturedBody :: !LBS.ByteString
  }

-- | A path that passed 'safeReturnDestination'.
newtype SafePath = SafePath Text
  deriving stock (Eq, Show)

mkSafePath :: Text -> Maybe SafePath

data ReturnTarget = ReturnTarget
  { targetHost :: !PublicHost
  , targetPath :: !SafePath
  }
  deriving stock (Eq, Show)

renderReturnTarget :: ReturnTarget -> Text
parseReturnTarget :: BackendMap -> Text -> Maybe ReturnTarget
portalHome :: Portal -> ReturnTarget

data LoginNotice = SessionFailed | LoggedOut
  deriving stock (Eq, Show)

portalLoginUrl :: Portal -> Maybe LoginNotice -> Maybe ReturnTarget -> Text

data PortalPageKind = ForbiddenPage | UnavailablePage
  deriving stock (Eq, Show)

newtype PortalPage = PortalPage LBS.ByteString

portalPageResponse :: Status -> PortalPage -> Response
```

and in `cli/nagare-access/src/Nagare/Access/Auth.hs`, the types that mention
`AuthenticatedUser`, plus the new `AccessServices` fields:

```haskell
data PortalIdentity
  = PortalAnonymous
  | PortalAuthenticated !AuthenticatedUser !AccessToken
  deriving stock (Eq, Show)

data PortalUpstreamResult
  = PortalPassThrough !Response
  | PortalSessionEstablish !SessionHandoff
  | PortalHandoffMalformed !Text
  | PortalSessionClear !CapturedResponse

data PortalPageRequest = PortalPageRequest
  { pageKind :: !PortalPageKind
  , pageTarget :: !ReturnTarget
  , pageUser :: !(Maybe AuthenticatedUser)
  }

data AccessServices = AccessServices
  { -- existing fields unchanged
    revokeSession :: !(AccessToken -> IO ())
  , forwardPortal :: !(Portal -> PortalIdentity -> Request -> IO PortalUpstreamResult)
  , fetchPortalPage :: !(Portal -> PortalPageRequest -> IO (Maybe PortalPage))
  }
```

together with:

```haskell
-- Nagare.Access.ShomeiClient
logoutWithShomei :: Shomei.ClientEnv -> AccessToken -> IO ()

-- Nagare.Access.Proxy
portalForwarder :: HC.Manager -> Portal -> PortalIdentity -> Wai.Request -> IO PortalUpstreamResult

-- Nagare.Access.App (internal)
data HandoffFailure
  = HandoffMalformed !Text
  | HandoffAccessTokenRejected
  | HandoffRefreshFailed
  | HandoffRefreshedTokenRejected
  deriving stock (Eq, Show)

establishSession :: AccessServices -> BackendMap -> Portal -> SessionHandoff -> ExceptT HandoffFailure IO (ReturnTarget, [Header])
```

At the end of Milestone 3:

```haskell
-- Nagare.Access.App (internal)
data LoginPage = BuiltinLoginPage | PortalLoginPage !Portal

-- Nagare.Access.Proxy
portalPageFetcher :: HC.Manager -> Portal -> PortalPageRequest -> IO (Maybe PortalPage)
```

At the end of Milestone 4, in `cli/nagare-dsl/src/Nagare/Dsl/Access.hs`:

```haskell
data AccessRole = ProtectedSite | AuthPortal
  deriving stock (Generic, Eq, Show)

data AccessPolicy = AccessPolicy
  { audience :: !(Maybe Audience)
  , permission :: !AccessPermission
  , role :: !AccessRole
  }

authPortal :: AccessPolicy
```

and in `cli/nagarectl/src/Nagare/Access/Resolve.hs`:

```haskell
newtype PublicHost = PublicHost Text
  deriving stock (Eq, Ord, Show)

mkPublicHost :: Text -> Either Text PublicHost

data EntryRole = ProtectedEntry | PortalEntry
  deriving stock (Eq, Show)

data BackendEntry = BackendEntry
  { entryUpstream :: !Text
  , entryRole :: !EntryRole
  }
  deriving stock (Eq, Show)

instance FromJSON BackendEntry   -- a bare string, or {"upstream", "role"}
instance ToJSON BackendEntry     -- a bare string for protected entries

newtype BackendMap = BackendMap (Map PublicHost BackendEntry)
  deriving stock (Eq, Show)
  deriving newtype (Semigroup, Monoid)

newtype Origin = Origin Text
  deriving stock (Eq, Show)

portalOrigin :: PublicHost -> Origin
addOrigin :: Origin -> [Origin] -> [Origin]
removeOrigin :: Origin -> [Origin] -> [Origin]

data ShomeiPortalChange
  = EnablePortal !PublicHost !BaseDomain
  | DisablePortal !PublicHost
  deriving stock (Eq, Show)

data RouteOp
  = RouteTo !RouteTarget
  | DeleteRouteOverride
  | DeleteEnforcerRoute
  deriving stock (Eq, Show)

data AccessOps = AccessOps
  { checkEnforcerPresent :: !(IO Bool)
  , loadBackends :: !(IO BackendMap)
  , saveBackends :: !(BackendMap -> IO ())
  , applyRouteOp :: !(Namespace -> PublicHost -> RouteOp -> IO ())
  , applyShomeiPortal :: !(ShomeiPortalChange -> IO ())
  }

removeServiceAccessWithOps :: AccessOps -> Namespace -> ServiceName -> IO [PublicHost]
```

`nagarectl` has no base-domain type today; it passes `Text` everywhere. Add
`newtype BaseDomain = BaseDomain Text` next to `PublicHost`, make
`resolveDeploymentAccessWithOps` take it instead of `Text`, and add
`isUnderBaseDomain :: BaseDomain -> PublicHost -> Bool` for the portal refusal.

The wire contract between `nagare-access` and a portal (headers `X-Forwarded-User`,
`Authorization`, `X-Forwarded-Host`, `X-Forwarded-Proto`, `Nagare-Session-Establish`,
`Nagare-Session-Clear`, `X-Nagare-Error-Host`, `X-Nagare-Error-Path`,
`X-Nagare-Return-To`, and the paths `/login`, `/errors/403`, `/errors/503`,
`/v1/auth/password-reset/confirm`, `/v1/auth/verify-email/confirm`) is the public
interface of this plan. Any change to it after Milestone 6 must update
`docs/user/auth-portal.md`, the reference portal, and the ADR together.


## Revision notes

- 2026-09-13: Added a resumable macOS passkey-validation procedure to
  `docs/user/auth-portal.md`. It covers CA inspection, explicit system trust and exact
  removal, the port-443 certificate check, disposable identity/grant setup, all three
  browser ceremonies, and cleanup. The acceptance checkbox remains open until the
  ceremony is actually observed.

- 2026-09-13: Implemented Milestones 1–5 and the non-browser portion of Milestone 6.
  Added the operator runbook and ADR, recorded the local transcript, and updated the
  cold auth-image path to honor dependency pins. Local validation fixed current En
  probes and made auth-plane reinstall preserve the resolver-owned backend map. The
  manual passkey ceremony remains open until a browser trusts the local CA.

- 2026-09-12: Reworked the Haskell interfaces after review.
  - Replaced bare-`Text` and nested `Either`/`Maybe` signatures with domain types.
    There is a new `Nagare.Access.Portal` module for the contract vocabulary, and
    `Portal`/`PublicHost` in `BackendMap`.
  - Refactored `nagarectl`'s `AccessOps` to `loadBackends`/`saveBackends`, with data
    descriptions of route and Shomei changes.
  - Updated Milestones 1–4, the tests, Idempotence and Recovery, and Interfaces and
    Dependencies to match, and recorded the decision in the Decision Log.
  - The portal wire contract and milestone scope are unchanged.
