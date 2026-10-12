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

Full plan before trimming: [117-let-operators-deploy-their-own-authentication-portal-for-protected-sites.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/117-let-operators-deploy-their-own-authentication-portal-for-protected-sites.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

