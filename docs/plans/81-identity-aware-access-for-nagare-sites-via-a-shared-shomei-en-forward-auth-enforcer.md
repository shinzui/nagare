---
id: 81
slug: identity-aware-access-for-nagare-sites-via-a-shared-shomei-en-forward-auth-enforcer
title: "Identity-aware access for nagare sites via a shared shomei+en forward-auth enforcer"
kind: exec-plan
created_at: 2026-06-24T19:03:05Z
intention: "intention_01kvxg3mdke08s9pk87a3dqj1b"
---

# Identity-aware access for nagare sites via a shared shomei+en forward-auth enforcer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today every site nagare deploys is reachable by anyone on the internet. nagare turns a
typed Haskell description of a web service into a **Knative Service** (Knative is the
serverless layer running on the single-node `k3s` cluster; a "Knative Service", or
`ksvc`, is one deployed web app that can scale to zero) and exposes it at a subdomain of
`NAGARE_BASE_DOMAIN` (for example `hello.apps.example.com`). There is no login in front of
it. If you want a "private intranet" — internal tools that are reachable from anywhere
without a VPN but only after signing in — you currently cannot express that.

After this change, a site's author adds **one line** to its typed config:

```haskell
, access = requireLogin   -- this site now requires login; everyone else stays public
```

and after deploying it, the site behaves like this:

1. An unauthenticated browser requesting `https://tools.apps.example.com/` is redirected to
   a login page, signs in with an existing **shomei** account (shomei is the project's
   Haskell authentication service: it checks the password and issues a signed JSON Web
   Token — a "JWT", a compact signed token carrying claims like *who you are* and *when it
   expires*), and is sent back to the site, now logged in.
2. On every subsequent request the site is only served if the visitor (a) carries a valid,
   unexpired shomei token **and** (b) is authorized to reach *this specific site* according
   to **en** (en is the project's Haskell relationship-based authorization service — it
   answers questions of the form "may subject *S* perform permission *P* on object *O*?").
   A logged-in user who is not granted access to `tools.apps.example.com` gets `403
   Forbidden`, not the site.
3. A single sign-in works across **all** protected sites under the base domain, because the
   session cookie is scoped to the parent domain `.apps.example.com`. This is the
   "BeyondCorp" / "identity-aware proxy" model: the network stays open, identity is checked
   in the request path, and no VPN client is required.

The thing that makes (1)–(3) happen is a **single shared service** we will build, the
**nagare access enforcer** (working name `nagare-access`): a small Haskell reverse proxy
that sits in the request path of protected sites, verifies shomei tokens, asks en for an
authorization decision, and forwards authorized requests to the real site. It is **not** a
sidecar copied into every app's pod — there is exactly one enforcer for the whole cluster,
and "which sites require login / who may reach them" lives in data (en relation tuples and
a small host→backend map), not in per-pod containers.

You can see it working end-to-end at the end of Milestone 5 by deploying the example site
`cluster/examples/protected-hello`, then:

```bash
# Unauthenticated request is redirected to login:
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://protected-hello.apps.example.com/
# expect: 302 https://protected-hello.apps.example.com/_nagare/login?rd=%2F

# After logging in as a user WITHOUT access, the site returns 403:
# After granting access in en, the same user gets 200 and the page body.
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] **M0 — Spike: prove the request-path insertion and the shomei+en integration.** Stand
  up shomei-server and en-server locally; write a ~100-line WAI proxy that verifies a shomei
  token, calls `en` check, and forwards to a dummy upstream. Confirm 302 / 403 / 200 paths
  by hand. Prove a Knative route can be pointed at a stand-in backend that then forwards to a
  cluster-local `ksvc`. Record findings in Surprises & Discoveries.
- [x] **M1a — `nagare-access` package scaffold and pure request-policy helpers.** Completed
  2026-06-24. Added `cli/nagare-access/` with its own `cabal.project`, executable, WAI
  health endpoint, listen parsing, safe return-destination validation, and the 302-vs-401
  challenge classifier. Added package metadata in `mori.dhall` and a root flake build/test
  check.
- [x] **M1b — backend map, cookie headers, and concrete unauthenticated responses.** Completed
  2026-06-24. Added parsing/lookup for the `NAGARE_ACCESS_BACKENDS` JSON host→upstream map,
  deterministic `Set-Cookie` header construction for the shared session cookie and `__Host`
  CSRF cookie, and WAI behavior for protected hosts with no token: document requests get 302
  to login, JSON/API requests get 401 JSON, and unknown hosts get a clear backend error. The
  executable now reads `NAGARE_ACCESS_BACKENDS` as an optional JSON file path and fails fast
  on malformed map data.
- [x] **M1c — raw credential extraction.** Completed 2026-06-24. Added
  `Nagare.Access.Credential`, which extracts the raw access token from the `nagare_session`
  cookie first and falls back to `Authorization: Bearer ...`, rejecting empty or malformed
  values without adding a new cookie parsing dependency.
- [x] **M1d — en decision cache primitive.** Completed 2026-06-24. Added
  `Nagare.Access.DecisionCache`, a short-lived in-process cache keyed by `(subject, host)`
  with an injectable clock, TTL expiry, and `0`/negative TTL disablement. This is the cache the
  future en-client authorization call will use to avoid one en round-trip per static asset.
- [x] **M1e — authenticated request-path wiring.** Completed 2026-06-24. Added
  `Nagare.Access.Auth` and `appWithRuntime`, so protected requests now flow through credential
  extraction, injected token verification, cached authorization, 403 handling for denied or
  conditional decisions, and an injected forwarder for allowed requests. Authorization uses the
  backend map's canonical host, stripping any request `Host` port before building the decision
  key.
- [x] **M1f — basic reverse-proxy forwarding.** Completed 2026-06-24. Added
  `Nagare.Access.Proxy`, a concrete `http-client` forwarder for authorized requests. It builds
  upstream requests from the backend map target, preserves method/path/query/body, strips
  hop-by-hop headers and inbound spoofable `X-Forwarded-*` identity headers, injects trusted
  `X-Forwarded-User`, `X-Forwarded-Host`, and `X-Forwarded-Proto`, disables upstream redirect
  following, and maps upstream responses back to WAI responses. This is the initial buffered
  request/response forwarder; WebSocket upgrade handling, SSE/large-body streaming, and
  end-to-end shomei+en integration remain in M1.
- [x] **M1g — runtime auth-plane environment parsing.** Completed 2026-06-24. Added a typed
  `RuntimeConfig` and `AuthPlaneConfig` parser for `NAGARE_ACCESS_LISTEN`,
  `NAGARE_ACCESS_BACKENDS`, `NAGARE_ACCESS_SHOMEI_URL`,
  `NAGARE_ACCESS_SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_AUDIENCE`,
  `NAGARE_ACCESS_EN_URL`, `NAGARE_ACCESS_COOKIE_DOMAIN`, `NAGARE_ACCESS_COOKIE_KEY`, and
  `NAGARE_ACCESS_DECISION_TTL`. The executable now uses this parser for listen/backend config.
  With no auth env, the auth plane remains absent; if any auth-plane setting is present, the
  required auth settings must all be valid, so partial configuration fails fast before request
  handling starts. `NAGARE_ACCESS_DECISION_TTL` defaults to 30 seconds and accepts `0` to
  disable caching.
- [x] **M1h — shomei JWT verifier adapter.** Completed 2026-06-24. Pinned shomei's
  `shomei-core` and `shomei-jwt` packages in `cli/nagare-access/cabal.project` with
  Cabal `source-repository-package` stanzas at commit
  `af09acecee6bafa3cf0087c5397c0f85da7aa1cc`, added `Nagare.Access.Shomei`, and mapped
  `Shomei.Jwt.Verify.verifyToken` into the existing `verifyCredential` shape. The adapter
  derives `ShomeiConfig` from `AuthPlaneConfig`, converts verified `AuthClaims.subject` to
  `AuthenticatedUser.userSubject`, maps expired tokens to `ExpiredCredential`, and treats
  malformed/signature/issuer/audience failures as invalid credentials. JWKS fetching/caching
  and executable wiring remain separate M1 work.
- [x] **M1i — JWKS fetch and cache.** Completed 2026-06-24. Added
  `Nagare.Access.Jwks`, which constructs the shomei JWKS URL
  `/.well-known/jwks.json`, fetches it with `http-client`, decodes the `{"keys":[...]}` JSON
  document into jose's `JWKSet`, and caches successful fetches behind an injectable TTL clock.
  Added `verifyShomeiCredentialCached` so the shomei adapter can fail closed with
  `VerificationUnavailable` when keys cannot be loaded, instead of pretending the credential is
  invalid. This narrows remaining token-verification work to wiring the executable's runtime
  services through the cache.
- [x] **M1j — en authorization adapter.** Completed 2026-06-24. Pinned en's `en-core`,
  `en-migrations`, `en-postgres`, `en-servant`, and `en-client` packages in
  `cli/nagare-access/cabal.project` with Cabal `source-repository-package` stanzas at commit
  `d27bb440b4b125c9844be95a02d00f54c1eec261`, added `Nagare.Access.En`, and mapped the real
  `En.Client.EnClient.check` API into the existing `AuthenticatedUser -> host ->
  AccessDecision` shape. The adapter builds checks for subject object type `user`, object type
  `app`, object id = canonical public host, permission `access`, and consistency
  `MinimizeLatencyWire`; en client failures fail closed as `AccessDenied`.
- [x] **M1k — executable runtime auth-service wiring.** Completed 2026-06-24. `app/Main.hs`
  now constructs real `AccessServices` when the auth-plane environment is present: a TLS
  `http-client` manager, a 5-minute JWKS cache backed by `fetchJwksFromShomei`, the cached
  shomei verifier, a Servant `ClientEnv` for en, the configured en decision cache, and the
  concrete proxy forwarder. With no auth-plane environment, the executable keeps the existing
  `appWithBackends` path.
- [x] **M1l — reserved userinfo/logout endpoints.** Completed 2026-06-24. Added
  `GET /_nagare/userinfo`, which verifies the request credential and returns JSON
  `{ "authenticated": true, "user": "<subject>" }` or `401 { "authenticated": false }`, and
  `GET /_nagare/logout`, which redirects to `/_nagare/login` and clears the shared
  `nagare_session` cookie when runtime cookie settings are configured.
- [x] **M1m — shomei-backed login form and session cookie issuance.** Completed 2026-06-24.
  Added `GET /_nagare/login` and `POST /_nagare/login` to the enforcer. The form sets a
  `__Host-nagare_csrf` cookie, preserves only safe same-host return destinations, validates the
  submitted CSRF token before calling shomei, calls the real `shomei-client` login API through
  `Nagare.Access.ShomeiClient`, and sets the shared-domain `nagare_session` access-token cookie
  on success before redirecting back to the requested path.
- [x] **M1n — refresh-token cookie wrapping and session renewal.** Completed 2026-06-24. Added
  the authenticated `nagare_refresh` cookie, wrapped as `v1.<base64url refresh>.<base64url
  hmac>` with HMAC-SHA256 keyed by `NAGARE_ACCESS_COOKIE_KEY`; login now sets the refresh cookie
  when the key is configured, missing/expired access tokens transparently call shomei
  `refresh`, rotated access+refresh cookies are attached to the forwarded response, and failed
  refresh clears both auth cookies before returning the existing content-negotiated challenge.
- [x] **M1o — streaming proxy request and response bodies.** Completed 2026-06-24.
  Replaced the initial buffered proxy body path with `http-client` `RequestBodyStreamChunked`
  and `responseOpen`/`BodyReader`, bridged to WAI `responseStream`, and disabled transparent
  decompression so proxied response headers continue to describe the bytes sent downstream.
  Tests now pin the streaming request-body constructor and exercise an SSE-like upstream through
  a local Warp app.
- [x] **M1p — WebSocket `Upgrade` tunneling.** Completed 2026-06-24. Added a WAI
  `responseRaw` path for authenticated WebSocket upgrade requests. The raw callback opens an
  interactive upstream `http-client` connection, forwards the upstream 101 response bytes to the
  browser, then relays bytes in both directions until either side closes. A raw-socket test
  drives an upgrade request through the proxy to a local Warp upstream and verifies post-101
  bytes are tunneled.
- [x] **M1q — MFA browser ceremony completion.** Completed 2026-06-24. Preserved shomei's
  `ceremonyId` and WebAuthn `options` when password login returns `mfa_required`, rendered a
  passkey challenge page that calls `navigator.credentials.get()`, added
  `POST /_nagare/mfa/complete` to submit the assertion JSON with CSRF protection, and wired the
  real shomei `mfaComplete` client call so a successful ceremony sets the same access and
  refresh cookies as password login.
- [x] **M1r — real `nagare-access` enforcer integration coverage.** Completed 2026-06-24.
  Added integration tests for the shomei HTTP login/refresh/MFA adapter, the real `en-client`
  talking over HTTP to an in-process `en-servant` app, and a full request-path test where a
  real DB-backed `shomei-server` signs a JWT, `nagare-access` fetches the JWKS and verifies the
  session cookie, `en` authorizes the shomei user id, and the proxy forwards the request to an
  upstream WAI app.
- [x] **M2 — DSL `access` binding.** Completed 2026-06-24. New `AccessPolicy` type + `requireLogin` /
  `mkAudience` smart constructors; `access :: Maybe AccessPolicy` field on `Deployment` and
  on the `Application` web service. Render/round-trip tests green.
- [x] **M3a — Deploy-time access resolver in `nagarectl`.** Completed 2026-06-24. Added
  `Nagare.Access.Resolve`, wired it into both `nagarectl deploy` and `nagarectl app deploy`
  after the app `ksvc` is Ready, and covered the fail-closed preflight, protected backend-map
  upsert, protected route-to-enforcer action, public backend removal, public route-to-app
  action, and wildcard-host DomainMapping override deletion in `nagarectl-test`.
- [x] **M3b — `nagarectl access grant/revoke/list`.** Completed 2026-06-24. Added
  `Nagare.Access.Grants` and top-level `nagarectl access grant`, `nagarectl access revoke`,
  and `nagarectl access list` commands. Grant/revoke write and delete `app:<host>#viewer`
  tuples for shomei users through en's HTTP JSON API; list expands `app:<host>#access` and
  prints the expanded users. The commands accept `--en-url` or `NAGARE_EN_URL`.
- [ ] **M3c — Remaining deploy-time access verification.** Ensure the en "app" object for the
  hostname is schema-valid in the installed M4 bundle and verify the resolver plus grant
  commands against the real M4 bootstrap bundle once that bundle exists.
- [x] **M4a — Auth-plane bootstrap manifests and `nagare-access` image path.** Completed
  2026-06-24. Added `cli/nagare-access/Dockerfile`, an Artifact Registry build/push helper at
  `cluster/bootstrap/nagare-access/build-image.sh`, and opt-in `kubectl apply` directories for
  `cluster/bootstrap/shomei/`, `cluster/bootstrap/en/`, and
  `cluster/bootstrap/nagare-access/`. The en bundle mounts the Nagare `app.en` schema with
  `object user {}` and `object app { relation viewer: user permission access: viewer }`; the
  enforcer bundle is a Knative Service with `min-scale=1`, the backend-map ConfigMap, and the
  cookie-key Secret template.
- [ ] **M4b — Remaining live bootstrap hardening and verification.** Local bootstrap hardening
  progressed on 2026-06-24: shomei/en image provenance is now documented from the dependency
  source, `cluster/bootstrap/en/migrations.yaml` runs en's SQL migrations as an explicit
  Kubernetes Job before `en-server` starts, `nagare-system` now exists on the target `nagare-01`
  cluster, all auth-plane manifests pass server-side dry-run against that cluster, and the safe
  live prerequisites (`en-schema`, empty backend map, real `nagare-access` cookie-key Secret)
  are applied. On 2026-06-25, the shomei/en bootstrap manifests were aligned with Nagare's
  managed database Secret contract: shomei now reads `PG_CONNECTION_STRING` from
  `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` from `nagare-db-shomei-db`, and en
  plus the en migration Job read the same key set from `nagare-db-en-db`; the stale bespoke
  shomei/en Secret templates were removed. A live attempt to use database name `shomei` exposed
  a Service-name collision with the auth service, so the managed databases are named
  `shomei-db` and `en-db`. The corrected managed PostgreSQL databases are live and Ready on
  `nagare-01`, and the replacement psql-based `en-migrate` Job completed successfully. Later on
  2026-06-25, `cluster/bootstrap/auth-images/` added a shared local-source Docker build path plus
  `cluster/bootstrap/shomei/build-image.sh` and `cluster/bootstrap/en/build-image.sh`, so
  shomei/en/nagare-access no longer depend on a nonexistent upstream release image or private
  GitHub fetches during image build. The helper now also supports
  `NAGARE_AUTH_BUILDER=cloud-build` for non-amd64 local hosts; Cloud Build was enabled in
  `tan-nb-exp`, but submitting the first `en` build failed because the only active gcloud account
  lacks Cloud Build submit permission. The helper now also supports
  `NAGARE_AUTH_BUILDER=k3s-import` for the single-node `nagare-01` cluster: it builds on the
  remote amd64 node with Podman through Nix, saves the image, and imports it directly into k3s
  containerd under a `dev.local/nagare-auth/<service>:<tag>` name. The first real `en` build
  succeeded and imported `dev.local/nagare-auth/en:k3s-test`. The first real `shomei` build also
  succeeded after the generated Cabal workspace stopped using stale local `hs-jose` and
  `tweag/webauthn` checkouts and instead pinned `hs-jose@d00ad179`,
  `servant-openapi@558b7b9`, `openapi-hs@dfcd77d`, and the Shomei WebAuthn fork at
  `c274e23`; it imported `dev.local/nagare-auth/shomei:k3s-test`. The
  `nagare-access` local-source build also completed on `nagare-01` with those pins and imported
  `dev.local/nagare-auth/nagare-access:k3s-test`. Remaining M4b work is live-cluster work:
  apply the shomei/en/nagare-access workloads to the target `nagare-01` context with non-latest
  imported-image tags, verify Ready status, and prove `nagarectl`'s M3 preflight succeeds
  against the installed bundle.
- [x] **M5a — Protected example artifact.** Completed 2026-06-24. Added
  `cluster/examples/protected-hello/nagare/Config.hs`, a compile-checked Deployment using the
  public Knative hello image, `protected-hello.apps.example.com`, and `access = Just
  requireLogin`, plus a README runbook for deploy, unauthenticated redirect, grant, revoke,
  and expected 403/200 behavior.
- [ ] **M5b — Live end-to-end acceptance.** Deploy `cluster/examples/protected-hello` against
  the target cluster after M4b, reproduce the Purpose curl transcript, and capture the
  authorized-vs-unauthorized 403/200 evidence in Outcomes & Retrospective.
- [x] **Docs.** Completed 2026-06-24. Added `docs/user/access.md` covering the
  `access = Just requireLogin` one-liner, optional auth-plane install, enforcer image build
  helper, `nagarectl access grant/revoke/list`, request behavior, cookie/security model, the
  protected-hello verification flow, and the future Envoy Gateway `ext_authz` direction. Linked
  it from `docs/user/README.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**Pre-implementation validation (2026-06-24).** Before any code, the API and layout claims in
this plan were checked against the actual source of shomei, en, and nagare. Findings:

- **CONFIRMED — shomei emits no `Set-Cookie`.** `extractToken`
  (`shomei-servant/src/Shomei/Servant/Auth.hs`) does read the `shomei_session` cookie as a
  token source, but a repo-wide search for `Set-Cookie`/cookie emission in `shomei-*/` returns
  nothing. The `TokenTransport` enum (`BearerToken | HttpOnlyCookie | BearerAndCookie`) exists
  (`shomei-core/src/Shomei/Config.hs:46`) but generation is unimplemented. **The enforcer owns
  all cookie issuance**, as designed.
- **CONFIRMED — all shomei/en API signatures match the plan.** `verifyToken :: JWKSet ->
  ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)` (`shomei-jwt/src/Shomei/Jwt/Verify.hs:77`);
  `AuthClaims` (has the named fields plus extra `issuedAt`/`actor`/`extraClaims`); `login`/
  `refresh`/`shomeiClientEnv` exact; ES256 default; 15-min access / 30-day refresh TTLs; no OIDC
  endpoints; `PG_CONNECTION_STRING`; `shomei-admin` subcommands present. en: all 6 routes,
  `CheckRequestWire`/`CheckResponseWire`/`SubjectWire`/`ObjectRefWire`/`TupleWire`, the `EnClient`
  record, and the schema-builder combinators all match. (`ConsistencyWire` additionally has
  `AtExactSnapshotWire`; we use `MinimizeLatencyWire`, so irrelevant.)
- **CORRECTION — package layout.** There is **no repo-root `cabal.project`** and **no
  `services/` directory**. The Haskell workspace lives under `cli/`. The enforcer is therefore a
  new `cli/nagare-access/` package (see Decision Log), not `services/nagare-access/`. All
  milestone/Interfaces references updated accordingly.
- **CORRECTION — en schema is a text-DSL `.en` file**, parsed at runtime by
  `En.Schema.Parse.parseSchema`; the builder combinators are in-Haskell only (see Decision Log).
- **CORRECTION — no image build pipeline exists.** `registries.nix` solves image *pull* only;
  nagared's image has no Dockerfile/nix derivation in-repo. M1/M4 must build+push the enforcer
  image themselves (see Decision Log).
- **CORRECTION — bootstrap entrypoint is `just cluster-bootstrap`** (a `justfile` recipe), not
  `./scripts/bootstrap-cluster.sh`; the `nagare-system` namespace does not exist yet (current
  bootstrap creates cert-manager/knative-serving/kourier-system/personal). nagared is applied
  as separate `kubectl apply` of `cluster/bootstrap/nagared/{rbac,secret,service}.yaml` — the
  precedent to mirror for the new components.

Remaining to confirm or refute during M0:

- **Expectation to verify:** Kourier (the Knative ingress, just Envoy) does **not** expose an
  external-authorization (`ext_authz`) hook through Knative config. This is why the enforcer
  must be inserted at the *routing* layer (a Knative route pointed at the enforcer) rather
  than as an Envoy filter. Confirm by inspecting `cluster/bootstrap/kourier/` and
  `cluster/bootstrap/knative-serving/config-network.yaml`. (Note: nagared already proves a
  **DomainMapping → a plain Service** works — `hooks.apps.example.com` maps to the nagared
  Service — so the enforcer-as-DomainMapping-target half is precedented; the open question is
  the enforcer forwarding to a *cluster-local `ksvc`* that is not itself publicly routable.)

**M2 implementation evidence (2026-06-24).** The typed DSL surface is implemented in
`cli/nagare-dsl/src/Nagare/Dsl/Access.hs`, with `access :: Maybe AccessPolicy` on
`Deployment` and `Application`. The encoder emits a nullable `access` object and the loader
defaults an absent key to `Nothing`, preserving existing public-site configs. The Knative
renderer ignores the field; a new test asserts protected and public deployments render
identical Service YAML. Validation after formatting:

```text
cli/nagare-dsl$ cabal test all
All 354 tests passed (5.87s)

cli/nagarectl$ cabal test all
All 354 tests passed (6.21s)
All 315 tests passed (1.38s)
```

**Formatter note (2026-06-24).** A targeted `fourmolu -i` over config fixture/example files
failed because those files use postpositive `qualified` imports and the standalone formatter
invocation did not enable that parser extension. The formatter was rerun only on the library
and test modules it can parse cleanly; the fixture/example edits are one-line `access =
Nothing` initializers and were left otherwise untouched.

**M1a implementation evidence (2026-06-24).** `cli/nagare-access/` now exists as a standalone
Haskell package with a runnable `nagare-access` executable and tested pure helpers. The package
currently exposes only the request-independent pieces needed before wiring shomei/en:
`Nagare.Access.Config` parses `NAGARE_ACCESS_LISTEN`; `Nagare.Access.Challenge` validates
same-host return destinations and classifies unauthenticated requests as document redirects or
JSON API challenges; `Nagare.Access.App` serves `GET /_nagare/healthz` and a 404 fallback.
Validation:

```text
cli/nagare-access$ cabal build all
Linking .../nagare-access

cli/nagare-access$ cabal test all
All 15 tests passed (0.00s)
All 354 tests passed (5.87s)
```

The same workspace test run also executes `nagare-dsl-test` because `cli/nagare-access/
cabal.project` lists `../nagare-dsl`, matching the plan's per-package workspace pattern.
`mori show --full` now reports `nagare-access` as a Haskell application package at
`cli/nagare-access`. Attempting `nix fmt flake.nix` failed because this flake does not expose
`formatter.aarch64-darwin`; the flake change is a small check stanza matching the existing
Haskell checks and was left manually formatted in the surrounding style.

**M1b implementation evidence (2026-06-24).** The enforcer now has `Nagare.Access.BackendMap`
for the `NAGARE_ACCESS_BACKENDS` JSON file contract, `Nagare.Access.Cookie` for the session
and CSRF `Set-Cookie` headers, and `Nagare.Access.Response` for shared 302/401/403 response
construction. `Nagare.Access.App.appWithBackends` uses the host map to distinguish configured
protected hosts from misrouted hosts, then returns the correct unauthenticated response shape
until token verification lands. Validation:

```text
cli/nagare-access$ cabal test all
All 27 tests passed (0.01s)
All 354 tests passed (6.23s)
```

The repo now ignores Cabal `dist-newstyle/` and `.ghc.environment.*` outputs so repeated local
validation does not leave untracked build artifacts in each Cabal workspace.

**M1c implementation evidence (2026-06-24).** `Nagare.Access.Credential` now provides the
request credential extraction rule from the handler contract: prefer the `nagare_session`
cookie, otherwise accept a case-insensitive `Authorization: Bearer ...` header. The parser is
intentionally small and dependency-free because the enforcer only needs one known cookie name
and one bearer scheme before handing the raw token to shomei verification. Validation:

```text
cli/nagare-access$ cabal test all
All 33 tests passed (0.01s)
All 354 tests passed (5.66s)
```

**M1d implementation evidence (2026-06-24).** `Nagare.Access.DecisionCache` implements the
per-`(subject, host)` decision cache required before putting en authorization on the hot
request path. Tests cover cache hits, TTL expiry, zero-TTL disablement, and key isolation
between subjects and hosts. Validation:

```text
cli/nagare-access$ cabal test all
All 37 tests passed (0.01s)
All 354 tests passed (5.76s)
```

**M1e implementation evidence (2026-06-24).** `Nagare.Access.App.appWithRuntime` now wires
the protected request path through injectable auth services: no or invalid credential returns
the existing content-negotiated challenge, denied or conditional authorization returns 403, an
allowed decision calls the forwarder, and the decision cache is used per canonical
`(subject, host)`. This keeps the app fail-closed by default while giving the upcoming
`shomei-jwt`, `en-client`, and reverse-proxy modules concrete integration points. Validation:

```text
cli/nagare-access$ cabal test all
All 43 tests passed (0.01s)
All 354 tests passed (6.07s)
```

**M1f implementation evidence (2026-06-24).** `Nagare.Access.Proxy` now provides the first
concrete forwarding layer. The dependency lookup before implementation found
`snoyberg/http-client` in the local `mori` registry at
`/Users/shinzui/Keikaku/hub/haskell/http-client-project` and no registered
`http-reverse-proxy` package, so this slice uses the same `http-client`/`http-client-tls`
family already used by `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`. The proxy builder reads
the WAI request body strictly, constructs an upstream `Network.HTTP.Client.Request`, strips
hop-by-hop and spoofable identity headers, injects trusted `X-Forwarded-*` headers, and leaves
streaming/WebSocket work explicitly for the remaining M1 items. Validation:

```text
cli/nagare-access$ cabal test all
All 45 tests passed (0.01s)
All 354 tests passed (5.73s)
```

**M1g implementation evidence (2026-06-24).** `Nagare.Access.Config` now has the typed runtime
config record needed before wiring shomei, en, cookies, and the decision cache into the
executable. `parseRuntimeConfig` keeps the auth plane optional when no auth env is present, but
rejects partial/malformed auth env once any auth setting appears. `app/Main.hs` now uses this
single parser instead of reading `NAGARE_ACCESS_LISTEN` and `NAGARE_ACCESS_BACKENDS`
separately. Validation:

```text
cli/nagare-access$ cabal test all
All 51 tests passed (0.01s)
All 354 tests passed (5.88s)
```

**M1h implementation evidence (2026-06-24).** `cli/nagare-access/cabal.project` now pins the
own-project shomei packages with reproducible `source-repository-package` stanzas instead of a
machine-local sibling path. `Nagare.Access.Shomei` calls the real
`Shomei.Jwt.Verify.verifyToken` API confirmed during pre-implementation validation, builds the
`ShomeiConfig` from the parsed auth-plane issuer/audience, converts `AuthClaims.subject` via
`Shomei.Id.idText`, and maps shomei `TokenError` values into the enforcer's `AuthFailure`
type. Validation:

```text
cli/nagare-access$ cabal build all
Linking .../nagare-access

cli/nagare-access$ cabal test all
All 54 tests passed (0.00s)
All 354 tests passed (5.71s)
```

**M1i implementation evidence (2026-06-24).** `Nagare.Access.Jwks` now owns the shomei key
fetching boundary. It uses jose's `JWKSet` Aeson instance, confirmed in the local `hs-jose`
source (`Crypto.JOSE.JWK` parses `{"keys": ...}`), and shomei's documented/served
`/.well-known/jwks.json` route. Tests cover URL construction, decode failure/success shape,
success caching, TTL expiry, `0` TTL disablement, and unavailable JWKS mapping through the
cached shomei verifier. Validation:

```text
cli/nagare-access$ cabal build all
Linking .../nagare-access

cli/nagare-access$ cabal test all
All 61 tests passed (0.01s)
All 354 tests passed (5.94s)
```

**M1j implementation evidence (2026-06-24).** `Nagare.Access.En` now owns the en authorization
boundary. `mori registry show shinzui/en --full` confirmed the registered source path
`/Users/shinzui/Keikaku/bokuno/en` and the `en-client`, `en-servant`, and `en-core` package
layout; `mori registry docs shinzui/en` returned no curated docs, so the implementation read
the source directly. `en-client/src/En/Client.hs` exposes `EnClient.check :: CheckRequestWire
-> ClientM CheckResponseWire`, and `en-servant/src/En/Servant/API.hs` defines
`CheckRequestWire`, `CheckResponseWire`, `AllowedWire`, `DeniedWire`, `ConditionalWire`,
`SubjectIdWire`, `ObjectRefWire`, and `MinimizeLatencyWire`. The adapter builds the exact
`app:<host>` / `access` check from the Decision Log and converts en responses into the local
`AccessDecision` type. Because `en-servant` currently exposes server modules in the same
library, `en-client`'s transitive closure includes `en-postgres`; `flake.nix` now includes
`pkgs.postgresql` in the Cabal check/dev-shell tooling so `postgresql-libpq` can find
`pg_config`. Validation was run through the flake shell so the native dependency is present:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 64 tests passed (0.01s)
All 354 tests passed (6.54s)
```

**M1k implementation evidence (2026-06-24).** The executable now uses the real auth services
when `parseRuntimeConfig` yields `Just AuthPlaneConfig`. `app/Main.hs` builds one shared
TLS-capable `http-client` manager, a `JwksCache` that refreshes shomei keys every 300 seconds,
an en Servant `ClientEnv` from `NAGARE_ACCESS_EN_URL`, a `DecisionCache` using
`NAGARE_ACCESS_DECISION_TTL`, and an `AccessServices` record that wires
`verifyShomeiCredentialCached`, `authorizeWithEn`, and `proxyForwarder` into `appWithRuntime`.
This makes the executable exercise the M1h/M1i/M1j adapters rather than only the injected test
seams. `appWithBackends` remains the no-auth-plane path so a process started without auth env
keeps the earlier behavior. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 64 tests passed (0.01s)
All 354 tests passed (6.94s)
```

**M1l implementation evidence (2026-06-24).** `Nagare.Access.App.appWithRuntime` now
special-cases two more reserved endpoints before backend-map lookup. `GET /_nagare/userinfo`
uses the configured `verifyCredential` service and returns JSON for SPA callers without
requiring a protected host entry in the backend map. `GET /_nagare/logout` redirects to
`/_nagare/login`; because logout must clear the shared-domain cookie, `AccessServices` now
carries optional `CookieSettings`, and `app/Main.hs` populates them from
`NAGARE_ACCESS_COOKIE_DOMAIN` when the auth plane is configured. Unit tests cover
unauthenticated userinfo, authenticated userinfo, and logout's `Set-Cookie` clearing header.
Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 67 tests passed (0.01s)
All 354 tests passed (6.20s)
```

**M1m implementation evidence (2026-06-24).** `Nagare.Access.App.appWithRuntime` now handles
`GET /_nagare/login` and `POST /_nagare/login` before backend lookup. The GET path mints an
injectable CSRF token, emits the existing `__Host-nagare_csrf` cookie header, renders a minimal
HTML form, and normalizes unsafe `rd` values to `/`. The POST path parses
`application/x-www-form-urlencoded` bodies with `http-types`, validates the hidden CSRF token
against the `__Host-nagare_csrf` cookie before invoking the login service, accepts either
`loginId` or `email` plus a password, and on success sets the shared-domain `nagare_session`
cookie before a `302` redirect. `Nagare.Access.ShomeiClient` maps the real
`Shomei.Client.login` / `Shomei.Servant.DTO.LoginResponse` API into the local
`LoginCredentials -> LoginOutcome` service shape, and `app/Main.hs` wires it using
`NAGARE_ACCESS_SHOMEI_URL` plus UUID-v4 CSRF tokens. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 72 tests passed (0.01s)
All 354 tests passed (6.32s)
```

**M1n implementation evidence (2026-06-24).** `Nagare.Access.Cookie` now wraps refresh tokens
in an authenticated cookie value using HMAC-SHA256 and base64url-unpadded segments from
`crypton`/`ram`, keyed by `NAGARE_ACCESS_COOKIE_KEY`. `CookieSettings` carries the optional key,
`app/Main.hs` populates it when configured, and `Nagare.Access.ShomeiClient` maps shomei
`refresh` into the existing `LoginOutcome` shape. `Nagare.Access.App` now attempts refresh when
the access credential is missing or invalid/expired and a valid `nagare_refresh` cookie is
present; on success it verifies the new access token, authorizes as usual, forwards the request,
and attaches rotated access+refresh `Set-Cookie` headers to the upstream response. On failed
refresh it clears both auth cookies and returns the same 302-or-401 challenge path as any other
unauthenticated request. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 76 tests passed (0.01s)
All 354 tests passed (5.99s)
```

**M1o implementation evidence (2026-06-24).** `Nagare.Access.Proxy` now streams normal HTTP
request and response bodies instead of buffering them. The request bridge uses
`RequestBodyStreamChunked ($ Wai.getRequestBodyChunk waiReq)`, which avoids
`Wai.strictRequestBody`; the response bridge uses `http-client` `responseOpen` to receive an
upstream `BodyReader`, then returns a WAI `responseStream` that writes each chunk and closes the
upstream response with `responseClose` in a `finally` handler. The proxy disables
`http-client` transparent decompression and suppresses its implicit `Accept-Encoding: gzip`
header when the browser did not send `Accept-Encoding`, so forwarded `Content-Encoding` and
`Content-Length` headers continue to describe the bytes sent downstream. WebSocket `Upgrade`
traffic remains separate because it needs WAI raw response support and a bidirectional tunnel,
not the normal `responseStream` body path. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Up to date

cli/nagare-access$ nix develop --command cabal test all
All 77 tests passed (0.02s)
All 354 tests passed (6.48s)
```

The attempted repo-root command `nix develop --command cabal build all` failed because this
repository still has no root `cabal.project`; Cabal validation for this slice must run from
`cli/nagare-access/`, whose workspace includes `nagare-access` and `../nagare-dsl`.

**M1p implementation evidence (2026-06-24).** `Nagare.Access.Proxy` now recognizes WebSocket
upgrade requests by requiring both `Connection: Upgrade` and `Upgrade: websocket` tokens. Those
requests use a separate header hardening path that still strips spoofable identity headers but
preserves the upgrade and `Sec-WebSocket-*` handshake headers. The WAI response is
`responseRaw`; inside the raw callback the proxy uses `http-client`'s documented
`withConnection` hook for interactive protocols plus its internal request/header helpers to
send the upstream request, parse the upstream status and headers, write the raw HTTP response to
the browser, and then relay bytes in both directions. The regression test starts a raw Warp
upstream, sends an HTTP/1.1 upgrade request through the proxy over a real TCP socket, confirms a
`101 Switching Protocols` response, then sends `hello` and observes `upstream:hello` back over
the tunnel. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 78 tests passed (0.04s)
All 354 tests passed (6.80s)
```

**M1q implementation evidence (2026-06-24).** The shomei source was rechecked through
`mori registry show shinzui/shomei --full`; the local checkout's actual package layout is
top-level `shomei-client/`, `shomei-servant/`, and so on, despite the registry metadata showing
`packages/...` paths. `Shomei.Servant.DTO.LoginResponse` has the documented
`LoginMfaRequiredResponse { ceremonyId, options }`, and `Shomei.Client.mfaComplete` calls
`POST /auth/mfa/complete` with `MfaCompleteRequest { ceremonyId, assertion }` to receive a
`TokenPairResponse`. `Nagare.Access.Auth.LoginMfaRequired` now carries that ceremony id and
options, `AccessServices` has a `completeMfa` service, `Nagare.Access.ShomeiClient` maps the
real shomei `mfaComplete` client into the existing `LoginOutcome` shape, and `app/Main.hs`
wires it in production. `Nagare.Access.App` now renders a passkey challenge page after
password login returns MFA, uses browser-side JavaScript to convert shomei's WebAuthn JSON
options into `ArrayBuffer` fields for `navigator.credentials.get()`, submits the assertion JSON
to `POST /_nagare/mfa/complete` with the existing CSRF token, and returns JSON containing the
validated redirect path while setting access and refresh cookies. Tests cover rendering the
challenge page, successful completion with rotated cookies, and CSRF rejection before shomei is
called. Validation:

```text
cli/nagare-access$ nix develop --command cabal build all
Linking .../nagare-access

cli/nagare-access$ nix develop --command cabal test all
All 81 tests passed (0.01s)
All 354 tests passed (6.44s)
```

**M1r implementation evidence (2026-06-24).** The remaining M1 integration-test gap is now
covered in `cli/nagare-access/test/Spec.hs`. The shomei adapter test drives
`loginWithShomei`, `refreshWithShomei`, and `completeMfaWithShomei` through the real
`shomei-client` Servant client against a local WAI app that emits `Shomei.Servant.DTO` wire
values. The en adapter test drives `authorizeWithEn` through the real `en-client` HTTP client
against an in-process `En.Servant.API.app` with an in-memory `app#viewer -> access` schema.
The full request-path test provisions a fresh ephemeral PostgreSQL database with
`shomei-migrations:test-support`, boots a real `shomei-server` WAI app in-process, signs up a
user, submits the enforcer login form, extracts the `nagare_session` cookie, verifies that JWT
through `fetchJwksFromShomei`/`verifyShomeiCredentialCached`, authorizes the shomei user id
through en, and confirms the proxy forwards to an upstream that sees the trusted
`X-Forwarded-User` header. This keeps the DB-backed shomei server proof in the normal
`nagare-access` test suite rather than a hand-run script.

Adding the DB-backed shomei harness required test-only `source-repository-package` pins for
`shomei-migrations`, `shomei-postgres`, `shomei-webauthn`, `shomei-server`, `ephemeral-pg`,
`codd`, and the shomei WebAuthn fork. Cabal initially selected Hackage `time-1.12.2`, which
made en's `Lift UTCTime` derivation fail; `cli/nagare-access/cabal.project` now constrains
`time ==1.14`, matching the GHC 9.12.3 package DB, and carries the same targeted
`allow-newer: haxl:time` relaxation used by shomei's own workspace.

Validation after formatting:

```text
cli/nagare-access$ nix develop --command cabal build all
Up to date

cli/nagare-access$ nix develop --command cabal test all
All 85 tests passed (0.87s)
All 354 tests passed (7.08s)
```

**M3a implementation evidence (2026-06-24).** `cli/nagarectl/src/Nagare/Access/Resolve.hs`
now owns the deploy-time access resolver. The resolver keeps public deploys public by removing
the host from the enforcer backend map and restoring the route to the app; protected deploys
first check for the optional auth plane (`ksvc/nagare-access` and `service/nagare-access` in
`nagare-system`), then write the host to the `nagare-access-backends` ConfigMap and apply a
DomainMapping pointing the public host at the shared enforcer. `cli/nagarectl/app/Main.hs` and
`cli/nagarectl/src/Nagare/App/Deploy.hs` call this resolver after the app Service is applied
and Ready, so both single-Service and aggregate app deploys honor the DSL `access` field.

The new `cli/nagarectl/test/AccessResolveSpec.hs` tests the route planner, the fail-closed
preflight, protected backend-map upsert and route-to-enforcer action, public backend removal
and route-to-app action, and wildcard-host rollback by deleting the protective DomainMapping
override.

Validation after formatting:

```text
cli/nagarectl$ nix develop --command cabal build all
Linking .../nagarectl

cli/nagarectl$ nix develop --command cabal test all
All 354 tests passed (6.68s)
All 321 tests passed (1.69s)
```

**M3b implementation evidence (2026-06-24).** `cli/nagarectl/src/Nagare/Access/Grants.hs`
now owns the operator grant commands. It builds the same en model used by the enforcer:
`app:<public-host>#viewer@user:<shomei-user>` grants access and `app:<public-host>#access` is
the permission expanded for listing. `nagarectl access grant --host HOST --user USER` sends
`POST /tuples`, `nagarectl access revoke --host HOST --user USER` sends `DELETE /tuples`, and
`nagarectl access list --host HOST` sends `POST /expand`. All three commands resolve the en
server URL from `--en-url` first and `NAGARE_EN_URL` second, then fail with an actionable
message if neither is set.

The test suite now includes `cli/nagarectl/test/AccessGrantsSpec.hs`, which pins hostname
canonicalization, the generic en JSON shape for `SubjectIdWire`, and expansion-tree subject
collection. `cli/nagarectl/app/Main.hs` wires the commands under the existing top-level parser,
and `cli/nagarectl/nagarectl.cabal` exposes the new module plus the small `http-types`
dependency needed for method constants and content headers.

Validation after formatting:

```text
cli/nagarectl$ nix develop --command cabal build all
Up to date

cli/nagarectl$ nix develop --command cabal test all --test-options=--hide-successes
All 324 tests passed (1.43s)
All 354 tests passed (6.49s)
```

**M4a implementation evidence (2026-06-24).** The first optional auth-plane bootstrap slice is
now present on disk. `cluster/bootstrap/shomei/` contains a `shomei-db` Secret template and a
Deployment+Service for `shomei`, using the real shomei env contract:
`PG_CONNECTION_STRING`, `SHOMEI_PORT`, `SHOMEI_ISSUER`, and `SHOMEI_AUDIENCE`.
`cluster/bootstrap/en/` contains an `en-db` Secret template, an `en-schema` ConfigMap with the
Nagare authorization schema, and a Deployment+Service for `en` using `EN_DATABASE_URL`,
`EN_PORT`, and `EN_SCHEMA_PATH`. `cluster/bootstrap/nagare-access/` contains the backend-map
ConfigMap, cookie-key Secret template, a Knative `Service` named `nagare-access` in
`nagare-system`, and `build-image.sh`, which builds `cli/nagare-access/Dockerfile` for
`linux/amd64`, tags it under the configured Artifact Registry repository, and pushes by
default.

Dependency-source checks before writing the manifests confirmed a useful difference in startup
behavior: shomei's `Shomei.Server.Boot.buildEnv` runs its migrations and bootstraps an active
signing key on server startup, while en's `en-server` expects the `en-migrations` schema to
already exist and fails with a message pointing at `En.Migrations.migrationsDir` if the
database is not migrated. The first M4 bundle therefore documents en migrations as remaining
operator work rather than pretending `en-server` migrates itself.

Validation:

```text
$ kubectl apply --dry-run=client --validate=false -f cluster/bootstrap/shomei/
namespace/nagare-system created (dry run)
secret/shomei-db created (dry run)
namespace/nagare-system created (dry run)
deployment.apps/shomei created (dry run)
service/shomei created (dry run)

$ kubectl apply --dry-run=client --validate=false -f cluster/bootstrap/en/
namespace/nagare-system created (dry run)
configmap/en-schema created (dry run)
namespace/nagare-system created (dry run)
secret/en-db created (dry run)
namespace/nagare-system created (dry run)
deployment.apps/en created (dry run)
service/en created (dry run)

$ ruby -e 'require "yaml"; ARGV.each { |p| YAML.load_stream(File.read(p)); puts "ok #{p}" }' \
    cluster/bootstrap/nagare-access/service.yaml \
    cluster/bootstrap/nagare-access/configmap.yaml \
    cluster/bootstrap/nagare-access/secret.example.yaml \
    cluster/bootstrap/en/service.yaml \
    cluster/bootstrap/en/configmap.yaml \
    cluster/bootstrap/en/secret.example.yaml \
    cluster/bootstrap/shomei/service.yaml \
    cluster/bootstrap/shomei/secret.example.yaml
ok cluster/bootstrap/nagare-access/service.yaml
ok cluster/bootstrap/nagare-access/configmap.yaml
ok cluster/bootstrap/nagare-access/secret.example.yaml
ok cluster/bootstrap/en/service.yaml
ok cluster/bootstrap/en/configmap.yaml
ok cluster/bootstrap/en/secret.example.yaml
ok cluster/bootstrap/shomei/service.yaml
ok cluster/bootstrap/shomei/secret.example.yaml

cli/nagare-access$ nix develop --command cabal build all
Up to date

cli/nagare-access$ nix develop --command cabal test all --test-options=--hide-successes
All 85 tests passed (0.88s)
All 354 tests passed (6.61s)
```

Local `kubectl apply --dry-run=client --validate=false -f cluster/bootstrap/nagare-access/`
successfully parsed the Namespace, ConfigMap, and Secret, then failed to map the Knative
`serving.knative.dev/v1 Service` because the local client was not connected to a cluster with
Knative Serving CRDs installed. The manifest was therefore YAML-parsed locally and remains to
be server-side dry-run/applied against the target Knative cluster in M4b.

**M4b local bootstrap-hardening evidence (2026-06-24).** Dependency-source inspection sharpened
the remaining auth-plane install contract. `mori registry show shinzui/shomei --full` and
`mori registry show shinzui/en --full` located the local shomei and en repositories. A later
source check corrected the shomei side: shomei's runtime `Dockerfile` is only a secondary path,
and `flake.module.nix` advertises a reproducible `.#dockerImage` output that should build
`shomei-server:latest` with the server/admin binaries, `dhall-to-json`, BusyBox, and CA
certificates. Validation from the Nagare worktree showed that output is not currently usable:
`nix build /Users/shinzui/Keikaku/bokuno/shomei#dockerImage` fails in `cabal2nix` because the
flake's `callCabal2nix` target points at the multi-package repo root, which has no root `.cabal`
or `package.yaml`. en still has no Dockerfile, `flake.module.nix`, or flake image output in the
inspected source, so both shomei and en remain operator-provided image references until shomei's
flake image is fixed and en gains a verified build path.

The en migration workflow is now explicit in `cluster/bootstrap/en/migrations.yaml`. en's own
`en-migrations` package exposes only `migrationsDir = "db/migrations"` and the two SQL files
under that directory; it does not provide a migration executable. codd's local docs and source
confirm the CLI contract: it reads `CODD_CONNECTION`, `CODD_MIGRATION_DIRS`, and
`CODD_EXPECTED_SCHEMA_DIR`, and `codd up --no-check --wait 60` applies pending migrations
without expected-schema verification. The codd parser requires dashed timestamp filenames
(`YYYY-MM-DD-HH-MM-SS-...`), while en's checked-in SQL files currently use compact timestamp
names (`YYYYMMDD...`), so the Kubernetes ConfigMap keys use codd-compatible names while
preserving the SQL content. Because en currently ships no codd expected-schema snapshot, the
Job mirrors shomei's production behavior and uses `--no-check` rather than pretending strict
schema verification is available. A read-only Docker manifest lookup showed
`docker.io/mzabani/codd:0.1.8` is not published, while `docker.io/mzabani/codd:latest` exists;
the README therefore tells operators to mirror or digest-pin the codd image before production
use.

Validation:

```text
$ ruby -e 'require "yaml"; ARGV.each { |p| YAML.load_stream(File.read(p)); puts "ok #{p}" }' \
    cluster/bootstrap/en/migrations.yaml \
    cluster/bootstrap/en/service.yaml \
    cluster/bootstrap/en/configmap.yaml \
    cluster/bootstrap/en/secret.example.yaml \
    cluster/bootstrap/shomei/service.yaml \
    cluster/bootstrap/shomei/secret.example.yaml \
    cluster/bootstrap/nagare-access/service.yaml \
    cluster/bootstrap/nagare-access/configmap.yaml \
    cluster/bootstrap/nagare-access/secret.example.yaml
ok cluster/bootstrap/en/migrations.yaml
ok cluster/bootstrap/en/service.yaml
ok cluster/bootstrap/en/configmap.yaml
ok cluster/bootstrap/en/secret.example.yaml
ok cluster/bootstrap/shomei/service.yaml
ok cluster/bootstrap/shomei/secret.example.yaml
ok cluster/bootstrap/nagare-access/service.yaml
ok cluster/bootstrap/nagare-access/configmap.yaml
ok cluster/bootstrap/nagare-access/secret.example.yaml

$ kubectl apply --dry-run=client --validate=false -f cluster/bootstrap/en/
namespace/nagare-system created (dry run)
configmap/en-schema created (dry run)
namespace/nagare-system created (dry run)
configmap/en-migrations created (dry run)
job.batch/en-migrate created (dry run)
namespace/nagare-system created (dry run)
secret/en-db created (dry run)
namespace/nagare-system created (dry run)
deployment.apps/en created (dry run)
service/en created (dry run)

$ docker manifest inspect docker.io/mzabani/codd:0.1.8
no such manifest: docker.io/mzabani/codd:0.1.8

$ docker manifest inspect docker.io/mzabani/codd:latest
{
        "schemaVersion": 2,
        "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        "config": {
                "digest": "sha256:6b75ebd204c55e338f37c0287f68780d4f3a35995584b8d51bb15a9e1f16266f"
        },
        "layers": [
                {
                        "digest": "sha256:fe3cd06e3b57f9431eaf00f17bda9f3b4d31b6ff569e92ef7785c6dfa0c54a96"
                }
        ]
}
```

Live target-cluster apply was not attempted from the current kube context. The active context
was `sennari`, a GKE cluster with Ready nodes but none of Nagare's expected namespaces
(`nagare-system`, `personal`, `knative-serving`, `kourier-system`) and no Knative Serving CRDs
(`services.serving.knative.dev`, `domainmappings.serving.knative.dev`). Applying the Nagare
auth-plane bundle there would target the wrong cluster. Evidence:

```text
$ kubectl config current-context
sennari

$ kubectl get namespace nagare-system personal knative-serving kourier-system --ignore-not-found

$ kubectl get crd services.serving.knative.dev domainmappings.serving.knative.dev --ignore-not-found

$ kubectl get nodes
NAME                               STATUS   ROLES    AGE    VERSION
gke-sennari-pool-1-3dc72b9e-0n9j   Ready    <none>   2d8h   v1.34.7-gke.1499000
...
```

The actual `nagare-01` k3s cluster is reachable through `scripts/iap-ssh.sh` and has Knative
Serving installed. The local `just live-test` kubeconfig tunnel opened and printed PIDs, but the
local API forward dropped before `kubectl` could connect (`127.0.0.1:16443` refused
connections). Direct remote `sudo k3s kubectl` over IAP works and shows the cluster is the right
target. It also shows the auth-plane namespace/resources are absent, and Artifact Registry does
not yet contain `nagare-access`, `shomei`, or `en` images. Therefore a real apply would not be a
valid M4b acceptance run yet: the templates still need real image refs plus real database/cookie
Secrets.

```text
$ gcloud compute instances describe nagare-01 --zone=us-west1-a --project=tan-nb-exp --format=value\(status\)
RUNNING

$ just live-test
KUBECONFIG=/Users/shinzui/Keikaku/bokuno/nagare/.live-test/kubeconfig.yaml
# k3s API forwarded to https://127.0.0.1:16443 (ssh -L pid 51999, IAP tunnel pid 51392)

$ KUBECONFIG=/Users/shinzui/Keikaku/bokuno/nagare/.live-test/kubeconfig.yaml kubectl get nodes
The connection to the server 127.0.0.1:16443 was refused - did you specify the right host or port?

$ scripts/iap-ssh.sh ssh nagare-01 -- 'systemctl is-active k3s; sudo k3s kubectl get nodes'
active
NAME        STATUS   ROLES           AGE   VERSION
nagare-01   Ready    control-plane   21d   v1.35.4+k3s1

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get namespace nagare-system personal knative-serving kourier-system --ignore-not-found'
NAME              STATUS   AGE
personal          Active   21d
knative-serving   Active   21d
kourier-system    Active   21d

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get crd services.serving.knative.dev domainmappings.serving.knative.dev --ignore-not-found'
NAME                                 CREATED AT
services.serving.knative.dev         2026-06-03T04:03:48Z
domainmappings.serving.knative.dev   2026-06-03T04:03:47Z

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get all,configmap,secret,ksvc,domainmapping --ignore-not-found'

$ gcloud artifacts docker images list us-west1-docker.pkg.dev/tan-nb-exp/nagare --include-tags --format='table(IMAGE,TAGS)'
IMAGE                                                     TAGS
us-west1-docker.pkg.dev/tan-nb-exp/nagare/audit-build
us-west1-docker.pkg.dev/tan-nb-exp/nagare/audit-static    20260610-234750
us-west1-docker.pkg.dev/tan-nb-exp/nagare/nixapp
us-west1-docker.pkg.dev/tan-nb-exp/nagare/uploads-volume  20260611-050844
```

An attempted no-push validation of a shomei image helper also found that shomei's advertised
flake image output is currently broken. The helper was not kept in Nagare; shomei remains an
operator-provided image reference until that upstream flake output is fixed or another verified
build path exists.

```text
$ SHOMEI_PUSH=0 cluster/bootstrap/shomei/build-image.sh test-local
error: Cannot build '/nix/store/nqfkibpmk79xcml1l3x5lgzy758i3cj1-cabal2nix-shomei.drv'.
Last 7 log lines:
> cabal2nix: user error (*** Found neither a .cabal file nor package.yaml. Exiting.)
```

After creating the required `nagare-system` namespace on the target cluster, all auth-plane
manifests passed server-side dry-run. The first `nagare-access` dry-run emitted a Knative
security-default warning, so `cluster/bootstrap/nagare-access/service.yaml` now declares
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `runAsNonRoot: true`, and
`seccompProfile: RuntimeDefault`, and `cli/nagare-access/Dockerfile` creates/runs as a non-root
`nagare` system user. The repeated dry-run for `nagare-access` was clean.

```text
$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl create namespace nagare-system --dry-run=client -o yaml | sudo k3s kubectl apply -f -'
namespace/nagare-system created

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply --dry-run=server --validate=true -f /tmp/nagare-auth-plane-81/shomei/'
namespace/nagare-system configured (server dry run)
secret/shomei-db created (server dry run)
namespace/nagare-system configured (server dry run)
deployment.apps/shomei created (server dry run)
service/shomei created (server dry run)

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply --dry-run=server --validate=true -f /tmp/nagare-auth-plane-81/en/'
namespace/nagare-system configured (server dry run)
configmap/en-schema created (server dry run)
namespace/nagare-system configured (server dry run)
configmap/en-migrations created (server dry run)
job.batch/en-migrate created (server dry run)
namespace/nagare-system configured (server dry run)
secret/en-db created (server dry run)
namespace/nagare-system configured (server dry run)
deployment.apps/en created (server dry run)
service/en created (server dry run)

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply --dry-run=server --validate=true -f /tmp/nagare-auth-plane-81/nagare-access/'
namespace/nagare-system configured (server dry run)
configmap/nagare-access-backends created (server dry run)
namespace/nagare-system configured (server dry run)
secret/nagare-access created (server dry run)
service.serving.knative.dev/nagare-access created (server dry run)

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get all,configmap,secret,ksvc,domainmapping --ignore-not-found'
NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      83s
```

Local no-push validation of the updated `nagare-access` Dockerfile found and fixed one image
build bug, then exposed the remaining credential prerequisite. Initially the helper could not
connect to Docker because Docker was pointed at a stale Colima socket; after `colima restart`,
the build reached Docker Hub and showed that the original `haskell:9.12.2-slim` base image tag
does not exist. `cli/nagare-access/Dockerfile` now uses the existing `haskell:9.12.2` build
stage tag. The next no-push build reached Cabal dependency fetching and failed because the
Docker build environment has no credentials for the private `shinzui/shomei` and `shinzui/en`
source repositories pinned in `cli/nagare-access/cabal.project`. The Dockerfile and build helper
now accept an optional BuildKit secret from `GITHUB_TOKEN`; no token was present in this
environment, so a complete image build/push remains open.

```text
$ NAGARE_ACCESS_PUSH=0 cluster/bootstrap/nagare-access/build-image.sh test-local
ERROR: Cannot connect to the Docker daemon at unix:///Users/shinzui/.colima/docker.sock. Is the docker daemon running?

$ colima restart
...
time="2026-06-24T17:24:03-07:00" level=info msg=done

$ NAGARE_ACCESS_PUSH=0 cluster/bootstrap/nagare-access/build-image.sh test-local
ERROR: failed to build: failed to solve: haskell:9.12.2-slim: failed to resolve source metadata for docker.io/library/haskell:9.12.2-slim: not found

$ docker manifest inspect docker.io/library/haskell:9.12.2 >/dev/null && echo haskell:9.12.2
haskell:9.12.2

$ NAGARE_ACCESS_PUSH=0 cluster/bootstrap/nagare-access/build-image.sh test-local
fatal: could not read Username for 'https://github.com': No such device or address

$ if [ -n "${GITHUB_TOKEN:-}" ]; then echo present; else echo absent; fi
absent
```

The safe live prerequisites that do not require DB credentials or image availability were then
applied to `nagare-01`: the en schema ConfigMap, the empty nagare-access backend map, and a real
random cookie-key Secret. The first cookie-key attempt used `openssl` on the VM, but NixOS did
not have `openssl` on PATH and the shell command still created an empty Secret; it was
immediately corrected with a `set -euo pipefail` command using `/dev/urandom` and `base64`.
Verification checked only the decoded byte count, not the secret value.

```text
$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply -f /tmp/nagare-auth-plane-81/en/configmap.yaml'
namespace/nagare-system configured
configmap/en-schema created

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply -f /tmp/nagare-auth-plane-81/nagare-access/configmap.yaml'
namespace/nagare-system configured
configmap/nagare-access-backends created

$ scripts/iap-ssh.sh ssh nagare-01 -- 'COOKIE_KEY="$(openssl rand -base64 48)"; sudo k3s kubectl -n nagare-system create secret generic nagare-access --from-literal=cookie-key="$COOKIE_KEY" --dry-run=client -o yaml | sudo k3s kubectl apply -f -'
bash: line 1: openssl: command not found
secret/nagare-access created

$ scripts/iap-ssh.sh ssh nagare-01 -- 'set -euo pipefail; COOKIE_KEY="$(dd if=/dev/urandom bs=48 count=1 2>/dev/null | base64)"; test -n "$COOKIE_KEY"; sudo k3s kubectl -n nagare-system create secret generic nagare-access --from-literal=cookie-key="$COOKIE_KEY" --dry-run=client -o yaml | sudo k3s kubectl apply -f -'
secret/nagare-access configured

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get secret nagare-access -o jsonpath="{.data.cookie-key}" | base64 -d | wc -c'
64

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get all,configmap,secret,ksvc,domainmapping --ignore-not-found'
NAME                               DATA   AGE
configmap/en-schema                1      33s
configmap/kube-root-ca.crt         1      3m35s
configmap/nagare-access-backends   1      33s

NAME                   TYPE     DATA   AGE
secret/nagare-access   Opaque   1      33s
```

**M4b managed-database Secret alignment (2026-06-25).** A source check of Nagare's managed DB
code showed that `nagarectl db create postgres <name> --namespace <ns>` renders an Opaque
Secret named `nagare-db-<name>` with keys `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB`,
and `DATABASE_URL`, where the URL points at `<name>.<namespace>.svc.cluster.local:5432`. The
auth-plane manifests previously expected bespoke Secrets named `shomei-db` and `en-db`, which
would have required a parallel manual credential path and made `kubectl apply -f
cluster/bootstrap/shomei/` or `cluster/bootstrap/en/` accidentally apply placeholder Secrets.
The current manifests now reuse Nagare's managed DB contract directly: `shomei` reads
`POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` from Secret `nagare-db-shomei-db`,
while `en` and `en-migrate` read the same key set from Secret `nagare-db-en-db`. The shomei/en
`secret.example.yaml` files were removed; the only remaining hand-edited Secret template in
the auth plane is the `nagare-access` cookie key, and it is named
`secret.example.yaml.tmpl` so directory-wide `kubectl apply -f cluster/bootstrap/nagare-access/`
cannot accidentally apply the placeholder over the real Secret.

Validation:

```text
$ ruby -e 'require "yaml"; ARGV.each { |p| YAML.load_stream(File.read(p)); puts "ok #{p}" }' \
    cluster/bootstrap/shomei/service.yaml \
    cluster/bootstrap/en/service.yaml \
    cluster/bootstrap/en/configmap.yaml \
    cluster/bootstrap/en/migrations.yaml \
    cluster/bootstrap/nagare-access/service.yaml \
    cluster/bootstrap/nagare-access/configmap.yaml \
    cluster/bootstrap/nagare-access/secret.example.yaml.tmpl
ok cluster/bootstrap/shomei/service.yaml
ok cluster/bootstrap/en/service.yaml
ok cluster/bootstrap/en/configmap.yaml
ok cluster/bootstrap/en/migrations.yaml
ok cluster/bootstrap/nagare-access/service.yaml
ok cluster/bootstrap/nagare-access/configmap.yaml
ok cluster/bootstrap/nagare-access/secret.example.yaml.tmpl
```

The first live managed DB create used the database name `shomei`, which created a Service named
`shomei` and therefore conflicted with the planned shomei auth Service. Those empty, just-created
resources were deleted, and the contract was corrected to use managed DB names `shomei-db` and
`en-db`. Applying those dry-run-rendered managed DB manifests through remote `sudo k3s kubectl`
created Ready StatefulSets and nonempty managed Secret keys without storing the generated
passwords in repository files.

```text
$ nix develop --command cabal exec -v0 nagarectl -- db create postgres shomei-db --namespace nagare-system --dry-run | ... | scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply -f -'
secret/nagare-db-shomei-db created
persistentvolumeclaim/nagare-db-shomei-db-data created
service/shomei-db created
statefulset.apps/shomei-db created
cronjob.batch/nagare-dbbackup-shomei-db created

$ nix develop --command cabal exec -v0 nagarectl -- db create postgres en-db --namespace nagare-system --dry-run | ... | scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply -f -'
secret/nagare-db-en-db created
persistentvolumeclaim/nagare-db-en-db-data created
service/en-db created
statefulset.apps/en-db created
cronjob.batch/nagare-dbbackup-en-db created

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get statefulset,service,pvc,secret,cronjob | grep -E "shomei-db|en-db|nagare-db"'
statefulset.apps/en-db       1/1     25s
statefulset.apps/shomei-db   1/1     24s
service/en-db                ClusterIP   ...   5432/TCP
service/shomei-db            ClusterIP   ...   5432/TCP
secret/nagare-db-en-db       Opaque      4
secret/nagare-db-shomei-db   Opaque      4
```

The initial codd-based en migration Job could not run on `nagare-01`: containerd rejected
`docker.io/mzabani/codd:latest` because the image config encodes `Entrypoint` as a string
instead of the OCI array shape. The local codd source's Nix image definition uses the same
string `Entrypoint`, so the bootstrap switched to a `postgres:18`/`psql` Job that applies en's
two SQL migration files only when `public.relation_tuple` is absent. This keeps the current
first-install path idempotent with an image the cluster already pulls, and it should be replaced
with codd when en publishes a valid migration image or executable.

The replacement psql Job initially used the managed `DATABASE_URL` key and failed because the
generated password contained URL metacharacters that were not percent-encoded. The auth-plane
manifests now avoid the managed URL key and consume `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB` separately. shomei and en construct libpq keyword connection strings inside the
container, and the migration Job uses `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and
`PGDATABASE`.

After replacing the failed Job with the `PG*` version, the live migration completed and the
current `nagare-system` namespace contains Ready managed DB StatefulSets, the completed
migration Job, the en schema/migrations/backend-map ConfigMaps, and the real nagare-access
cookie Secret. shomei, en, and nagare-access workloads are still intentionally not applied
because their real image references are unresolved.

```text
$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=180s'
job.batch/en-migrate condition met

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system logs job/en-migrate --tail=80'
CREATE TABLE
CREATE TABLE
CREATE INDEX
CREATE INDEX
CREATE INDEX
CREATE INDEX
CREATE INDEX
CREATE INDEX
CREATE INDEX

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system get all,configmap,secret,ksvc,domainmapping --ignore-not-found'
pod/en-db-0            1/1     Running
pod/en-migrate-4tqqq   0/1     Completed
pod/shomei-db-0        1/1     Running
statefulset.apps/en-db       1/1
statefulset.apps/shomei-db   1/1
job.batch/en-migrate   Complete   1/1
configmap/en-migrations            2
configmap/en-schema                1
configmap/nagare-access-backends   1
secret/nagare-access         Opaque   1
secret/nagare-db-en-db       Opaque   4
secret/nagare-db-shomei-db   Opaque   4
```

```text
$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl -n nagare-system describe pod/en-migrate-jtg4g | tail -n 60'
Warning  Failed  ...  Failed to pull image "docker.io/mzabani/codd:latest": ... json: cannot unmarshal string into Go struct field ImageConfig.config.Entrypoint of type []string
```

**M4b local-source image helper evidence (2026-06-25).** The auth-plane image gap is now
represented by checked-in build machinery instead of only README instructions. The new
`cluster/bootstrap/auth-images/build-local-image.sh` helper builds one of `nagare-access`,
`shomei`, or `en` from a temporary Docker context containing local checkouts of Nagare, shomei,
en, and codd, plus pinned public git dependencies for jose, servant-openapi, openapi-hs, and the
Shomei WebAuthn fork. The helper generates a Cabal workspace that uses local package
paths for shomei/en rather than Cabal `source-repository-package` private GitHub fetches, uses
`haskell:9.12.4` to match the shomei/en workspaces, defaults to `linux/amd64`, and exposes
`NAGARE_AUTH_PUSH=0` for no-push validation. `cluster/bootstrap/shomei/build-image.sh` and
`cluster/bootstrap/en/build-image.sh` are thin wrappers over the common helper, while
`cluster/bootstrap/nagare-access/build-image.sh` can opt into the local-source path with
`NAGARE_ACCESS_LOCAL_SOURCES=1` or `NAGARE_AUTH_LOCAL_SOURCES=1`.

Cheap validation passed:

```text
$ bash -n cluster/bootstrap/auth-images/build-local-image.sh
$ bash -n cluster/bootstrap/nagare-access/build-image.sh
$ bash -n cluster/bootstrap/shomei/build-image.sh
$ bash -n cluster/bootstrap/en/build-image.sh
$ git diff --check
```

No-push Docker validation of the `en` image reached the generated local Cabal workspace and did
not fail on missing private source repositories, but this local Docker VM could not complete the
amd64 build. The builder is an aarch64 Colima VM with 8 GB RAM emulating `linux/amd64`, and
BuildKit killed Cabal for memory even after the Dockerfile defaulted to `--jobs=1`. The target
cluster needs amd64 images, so M4b still needs a native/larger amd64 builder or a remote build
before the manifests can be applied.

```text
$ docker manifest inspect docker.io/library/haskell:9.12.4 >/dev/null && echo haskell-9.12.4-ok
haskell-9.12.4-ok

$ NAGARE_AUTH_PUSH=0 cluster/bootstrap/en/build-image.sh test-local
...
#15 104.7 Killed
ERROR: failed to build: failed to solve: ResourceExhausted: process "... cabal build exe:en-server ..." did not complete successfully: cannot allocate memory

$ NAGARE_AUTH_PUSH=0 cluster/bootstrap/en/build-image.sh test-local
...
#15 135.9 Killed
ERROR: failed to build: failed to solve: ResourceExhausted: process "... cabal build ${CABAL_BUILD_FLAGS} ${CABAL_TARGETS} ..." did not complete successfully: cannot allocate memory

$ docker info --format 'arch={{.Architecture}} os={{.OSType}} cpus={{.NCPU}} mem={{.MemTotal}}'
arch=aarch64 os=linux cpus=4 mem=8308084736

$ colima status
arch: aarch64
runtime: docker
```

Live apply validation was deliberately not attempted in this slice because the active Kubernetes
context was not the target `nagare-01` k3s cluster.

```text
$ kubectl config current-context
sennari
```

The helper then gained a remote amd64 builder mode:
`NAGARE_AUTH_BUILDER=cloud-build` copies the same generated local-source context to Cloud Build,
runs Docker with `DOCKER_BUILDKIT=1`, and defaults to machine type `e2-highcpu-32`. This is the
right shape for the target `nagare-01` amd64 node when the local Docker host is Apple Silicon,
but the first build submission could not start because the active gcloud account lacks Cloud
Build submit permission in `tan-nb-exp`. Cloud Build itself was enabled successfully, and
Artifact Registry already had the `us-west1/nagare` Docker repository.

```text
$ gcloud services list --enabled --filter='NAME:cloudbuild.googleapis.com OR NAME:artifactregistry.googleapis.com' --format='value(NAME)'
artifactregistry.googleapis.com

$ gcloud services enable cloudbuild.googleapis.com --project=tan-nb-exp
Operation "operations/acf.p2-1087727631858-0356f4a1-1a9c-4e52-80f5-a6ecdd9136d6" finished successfully.

$ NAGARE_AUTH_BUILDER=cloud-build cluster/bootstrap/en/build-image.sh cloudbuild-test
Creating temporary archive of 4243 file(s) totalling 305.0 MiB before compression.
Uploading tarball of [/var/folders/.../nagare-auth-image.fmQvxV] to [gs://tan-nb-exp_cloudbuild/source/1782349952.506533-2476653fe03143f0b84b26eb23349013.tgz]
ERROR: (gcloud.builds.submit) PERMISSION_DENIED: The caller does not have permission. This command is authenticated as nadeem@topagentnetwork.com which is the active account specified by the [core/account] property

$ gcloud auth list --format='table(account,status)'
ACCOUNT                     ACTIVE
nadeem@topagentnetwork.com  *
```

The helper then gained a single-node remote import mode for the real `nagare-01` cluster.
`NAGARE_AUTH_BUILDER=k3s-import` sends the generated local-source context to `nagare-01`, builds
with `podman` from `nixpkgs#podman`, saves the resulting image as a Docker archive, and imports it
with `sudo k3s ctr images import`. The Dockerfile had to use fully qualified base-image names
(`docker.io/library/haskell:9.12.4` and `docker.io/library/debian:bookworm-slim`) because Podman
does not have Docker's default short-name behavior in the temporary build environment. The
BuildKit cache mount was also removed from the shared Dockerfile because Podman/buildah does not
support that Dockerfile frontend extension in this path.

Before the real image build, a tiny Podman smoke test proved that `nagare-01` can build and import
a `dev.local` image into k3s containerd. The `dev.local` prefix is already covered by Knative's
tag-resolution skip configuration, and a non-`latest` tag lets Kubernetes use the imported local
image with the default `IfNotPresent` pull policy.

```text
$ scripts/iap-ssh.sh ssh nagare-01 -- 'uname -m; nix shell nixpkgs#podman -c podman --version; sudo k3s kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,KUBELET:.status.nodeInfo.kubeletVersion'
x86_64
podman version 5.8.2
NAME        ARCH    KUBELET
nagare-01   amd64   v1.35.4+k3s1

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s ctr images list name==dev.local/nagare-auth/podman-smoke:test'
REF                                           TYPE                                                 DIGEST                                                                  SIZE     PLATFORMS   LABELS
dev.local/nagare-auth/podman-smoke:test      application/vnd.docker.distribution.manifest.v2+json sha256:...                                                               ...      linux/amd64 io.cri-containerd.image=managed
```

The first real `en` image build initially reached the local `en-core` source and failed because
`CaveatValue` derived `Lift`, but its `ValueTimestamp UTCTime` constructor has no `Lift UTCTime`
instance under the repo's declared GHC 9.12.4 compiler. The fix is in the sibling `en` checkout:
`en-core/src/En/Caveat/Value.hs` now has a manual `Lift CaveatValue` instance that lifts
timestamps through their `Show`/`Read` representation. That dependency-side fix was validated
locally before rerunning the remote image build, then committed in the `en` checkout as
`a8bf91a fix(core): support lifting timestamp caveat values`.

```text
$ cd /Users/shinzui/Keikaku/bokuno/en
$ nix develop --command cabal build en-core
Build profile: -w ghc-9.12.4 -O1
...
Up to date

$ nix develop --command cabal build exe:en-server
Build profile: -w ghc-9.12.4 -O1
...
Linking .../en-server
```

With that patch in the generated context, the remote build compiled `en-server`, committed the
runtime image, imported it into k3s, and verified the imported image by exact name.

```text
$ NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/en/build-image.sh k3s-test
...
[2/2] COMMIT dev.local/nagare-auth/en:k3s-test
Successfully tagged dev.local/nagare-auth/en:k3s-test
...
REF                               TYPE                                                 DIGEST                                                                  SIZE      PLATFORMS   LABELS
dev.local/nagare-auth/en:k3s-test application/vnd.docker.distribution.manifest.v2+json sha256:c9c9a715e559a11f51c2cc5685fc3983bd1030b2d9e9a7682783752c2a957e97 173.5 MiB linux/amd64 io.cri-containerd.image=managed
dev.local/nagare-auth/en:k3s-test

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s ctr images list name==dev.local/nagare-auth/en:k3s-test'
REF                               TYPE                                                 DIGEST                                                                  SIZE      PLATFORMS   LABELS
dev.local/nagare-auth/en:k3s-test application/vnd.docker.distribution.manifest.v2+json sha256:c9c9a715e559a11f51c2cc5685fc3983bd1030b2d9e9a7682783752c2a957e97 173.5 MiB linux/amd64 io.cri-containerd.image=managed
```

The first `shomei` `k3s-import` attempt exposed stale generated dependency sources. Local
`hs-jose` resolved to `jose-0.12` and failed under GHC 9.12/crypton 1.1/ram at the
`Crypto.JOSE.AESKW` and `Crypto.JOSE.JWA.JWK` byte-array constraints. After pinning the
reachable `sumo/hs-jose` `jose-0.13` commit, the generated project then needed the shomei
EP-27 OpenAPI pins; `servant-openapi@558b7b9` and `openapi-hs@dfcd77d` fixed that. A later
attempt failed in the local upstream `tweag/webauthn` checkout at
`Crypto.WebAuthn.Internal.ToJSONOrphans` with a `memory` `ByteArrayAccess (Digest h)` instance
gap. The mori corpus and shomei's own `cabal.project` point downstream consumers at the patched
`shinzui/webauthn` fork, so the generated Cabal project now pins `webauthn@c274e23` instead of
copying the stale local upstream checkout. With those pins, `shomei` built and imported into k3s:

```text
$ NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/shomei/build-image.sh k3s-test
...
Installing library .../jose-0.13-.../lib
Installing library .../servant-openapi-4.0.0-.../lib
Installing library .../webauthn-0.11.0.0-.../lib
Linking .../shomei-server
Successfully tagged dev.local/nagare-auth/shomei:k3s-test

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s ctr images list name==dev.local/nagare-auth/shomei:k3s-test'
REF                                      TYPE                                                 DIGEST                                                                  SIZE      PLATFORMS   LABELS
dev.local/nagare-auth/shomei:k3s-test   application/vnd.docker.distribution.manifest.v2+json  sha256:da00b800d6bc702f4a832d70c7a884cf4acf2dab103c0f03d7bf801e58673a3b  345.7 MiB linux/amd64 io.cri-containerd.image=managed
```

The `nagare-access` wrapper used the same generated local-source workspace and remote
`k3s-import` builder. The build compiled the local `en-*`, `shomei-*`, and `nagare-access`
packages, linked the `nagare-access` executable, committed the runtime image, imported it into
k3s, and verified the imported image by exact name:

```text
$ NAGARE_ACCESS_LOCAL_SOURCES=1 NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/nagare-access/build-image.sh k3s-test
...
Linking .../nagare-access
Successfully tagged dev.local/nagare-auth/nagare-access:k3s-test
REF                                          TYPE                                                 DIGEST                                                                  SIZE      PLATFORMS   LABELS
dev.local/nagare-auth/nagare-access:k3s-test application/vnd.docker.distribution.manifest.v2+json sha256:9d7cb460dd8247a1f3ec10762bc74393223f2a560d80f9da707a3020f19ddbdd 200.5 MiB linux/amd64 io.cri-containerd.image=managed

$ scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s ctr images list name==dev.local/nagare-auth/nagare-access:k3s-test'
REF                                          TYPE                                                 DIGEST                                                                  SIZE      PLATFORMS   LABELS
dev.local/nagare-auth/nagare-access:k3s-test application/vnd.docker.distribution.manifest.v2+json sha256:9d7cb460dd8247a1f3ec10762bc74393223f2a560d80f9da707a3020f19ddbdd 200.5 MiB linux/amd64 io.cri-containerd.image=managed
```

**M5a implementation evidence (2026-06-24).** `cluster/examples/protected-hello/` now contains
the protected hello example the Purpose section refers to. Its `nagare/Config.hs` mirrors the
plain hello example but uses a prebuilt `gcr.io/knative-samples/helloworld-go:latest` image,
sets the custom domain to `protected-hello.apps.example.com`, and sets
`access = Just requireLogin`. The example README records the expected deploy behavior: with the
auth plane absent the deploy should fail closed, and with the auth plane installed an
unauthenticated document request should redirect to `/_nagare/login`, an authenticated
ungranted user should receive `403`, and `nagarectl access grant --host
protected-hello.apps.example.com --user alice` should flip that user to `200`.

Validation:

```text
cli/nagarectl$ nix develop --command cabal build all
Up to date

cli/nagarectl$ nix develop --command cabal exec -v0 -- \
  runghc -XGHC2024 \
  -i../../cluster/examples/protected-hello/nagare \
  ../../cluster/examples/protected-hello/nagare/Config.hs
{"access":{"audience":null,"permission":"access"},"brokers":[],"build":{"kind":"PrebuiltImage","tag":"latest"},"cpuLimit":null,"cpuRequest":"250m","databases":[],"domains":[{"canonical":true,"domain":"protected-hello.apps.example.com"}],"env":[{"kind":"Literal","scopes":["Runtime"],"value":"Nagare","varName":"TARGET"}],"healthCheck":null,"image":"gcr.io/knative-samples/helloworld-go","memoryLimit":null,"memoryRequest":"128Mi","name":"protected-hello","namespace":"personal","port":8080,"scaleMax":3,"scaleMin":0,"tasks":[],"volumes":[]}
```

**Docs implementation evidence (2026-06-24).** `docs/user/access.md` now documents the user
and operator workflow for protected sites: the typed `access = Just requireLogin` field, the
optional `cluster/bootstrap/{shomei,en,nagare-access}/` install, the `nagare-access` image
build helper, `nagarectl access grant/revoke/list`, request outcomes for unauthenticated,
ungranted, and granted users, the parent-domain cookie/security model, and the future Envoy
Gateway `ext_authz` direction. `docs/user/README.md` links the guide under the app-deployment
section next to static hosting and CDN.


## Decision Log

Record every decision made while working on the plan.

- Decision: **Use a single shared enforcer, not a per-deployment sidecar.**
  Rationale: A sidecar is a container in each `ksvc` pod template, so N protected sites means
  N proxy copies to configure, version, and patch; worse, Knative routes external traffic to
  a single revision port, so a sidecar would have to become that port and forward to the app
  on localhost — fiddly and re-derived per deployment. None of that buys anything a shared
  enforcer lacks. Per-app behavior ("does this site need login, who may reach it") is *data*
  (en tuples + a host→backend map), so it does not require per-pod topology. One enforcer
  validates one JWKS and consults one authorization graph for every site.
  Date: 2026-06-24

- Decision: **Build a thin native Haskell enforcer (Path A), not OIDC-into-shomei (Path B).**
  Rationale: shomei is not an OpenID Connect provider (no `/authorize`, `/token`, or
  `/.well-known/openid-configuration`; it exposes its own `POST /auth/login` + a JWKS at
  `/.well-known/jwks.json`). Path B would add a full OIDC authorization-code flow, a hosted
  consent/login UI, and discovery to shomei so an off-the-shelf proxy (oauth2-proxy /
  Pomerium) could drive the browser dance. But off-the-shelf proxies give authentication plus
  at most a coarse allowlist — **they do not speak en's ReBAC**, so Path B would *still* need
  a second authorization hop into en. Path A does authN (shomei) and authZ (en) in one hop
  with code we already have clients for (`shomei-client`, `shomei-jwt`, `en-client`), and
  fits the all-Haskell stack. The full comparison is recorded under "Decision: Path A vs Path
  B" in Context and Orientation. Path B is retained as a *future* option for third-party /
  non-browser OIDC interop, not on this plan's critical path.
  Date: 2026-06-24

- Decision: **Insert the enforcer behind Kourier's TLS at the Knative routing layer.**
  Rationale: Two placements were considered for "today" (pre-Envoy-Gateway). (a) A front
  proxy *ahead* of Kourier would have to take over TLS termination for *all* traffic
  (including public sites) and own the wildcard certificate — too invasive. (b) Keep Kourier
  as the TLS terminator and front door, and for a *protected* host point its public route at
  the enforcer, which forwards to the app's cluster-local address
  (`<svc>.<ns>.svc.cluster.local`). (b) is chosen: it touches only protected hosts, leaves
  public sites and TLS untouched, and the enforcer is itself just another internal workload.
  Date: 2026-06-24

- Decision: **`access` is scoped to web-facing Services, not Workers.**
  Rationale: Workers (the long-running, non-HTTP workloads from EP-71) are not internet
  exposed, so "require login" is meaningless for them. The `access` field goes on
  `Deployment` (a single web service) and on the `Application` aggregate's web service only.
  Date: 2026-06-24

- Decision: **The protected workloads are language-agnostic; "all-Haskell" is the auth plane
  only.** The sites this feature gates are mostly static bundles and TanStack apps (SSR and
  client-rendered SPAs), not Haskell. Path A's "native Haskell" applies solely to building the
  enforcer (reusing `shomei-client`/`shomei-jwt`/`en-client`); the enforcer reverse-proxies to
  any HTTP upstream and imposes nothing on the app. The app-language mix is therefore neutral
  between Path A and Path B. Consequence for the design: the enforcer must serve single-page
  and static traffic correctly — see the next decision.
  Rationale: Clears a real misreading; without this, "all-Haskell" wrongly implies the
  protected apps must be Haskell, which would defeat the purpose of edge auth.
  Date: 2026-06-24

- Decision: **The enforcer is SPA- and static-aware: content-negotiated 302-vs-401, en-decision
  caching, WebSocket/SSE pass-through, and a `/_nagare/userinfo` endpoint.** Unauthenticated
  document navigations get `302` to login; unauthenticated XHR/`fetch()` get `401`+JSON (never
  a 302-to-HTML, which breaks SPAs on token expiry). en decisions are cached per `(subject,
  host)` for `NAGARE_ACCESS_DECISION_TTL` seconds (default 30) so a page's dozens of asset
  requests don't each incur an en round-trip — at the cost of a grant/revoke taking up to one
  TTL to take effect. The proxy streams SSE and handles HTTP `Upgrade` for WebSockets.
  `X-Forwarded-User` is injected for SSR upstreams and stripped from inbound requests so it
  cannot be spoofed; `GET /_nagare/userinfo` lets client-rendered apps fetch the current
  identity.
  Rationale: The static + TanStack workload mix (raised during review) exposes request
  patterns a single server-rendered page would not; without these, SPAs break on expiry and
  static pages incur an authorization round-trip per asset.
  Date: 2026-06-24

- Decision: **Authorize against en with object type `app`, object id = the public hostname,
  permission `access`.** Default consistency is `MinimizeLatency` (fast, possibly slightly
  stale reads — acceptable for access checks; a freshly granted user may need a few seconds).
  Rationale: Hostname is the stable, unique identifier the enforcer already has from the
  `Host` header; modeling each site as an `app` object keyed by hostname makes "grant Alice
  access to tools.apps.example.com" a single en tuple write.
  Date: 2026-06-24

- Decision: **The enforcer is a new standalone package `cli/nagare-access/`, not `services/`.**
  Rationale (added after pre-implementation validation): the plan originally proposed
  `services/nagare-access/` as a sibling to `cli/` and assumed a repo-root `cabal.project`.
  Neither exists. The Haskell workspace root is `cli/`; cabal.project files live at
  `cli/nagarectl/cabal.project` (lists `.` + `../nagare-dsl`) and `cli/nagare-dsl/cabal.project`.
  The only in-cluster Haskell-service precedent, **nagared**, is a *second executable* inside
  `nagarectl.cabal` (`hs-source-dirs: nagared/`) reusing the nagarectl library. We deliberately
  do **not** follow the bundle-into-nagarectl shape, because the enforcer pulls in heavy
  auth/JWT/proxy dependencies (`shomei-jwt` → `jose`, `shomei-client`/`en-client` →
  `servant-client`, a reverse-proxy stack) that have no business in the CLI's dependency
  closure. Instead `cli/nagare-access/` is its own package with its own
  `cabal.project` referencing `.` and `../nagare-dsl`, mirroring the `cli/nagare-dsl/` layout.
  Date: 2026-06-24

- Decision: **The en schema is shipped as a text-DSL `.en` file, not Haskell builder code.**
  Rationale (added after validation): `en-server` reads `EN_SCHEMA_PATH`, `Text.readFile`s it,
  and parses it with `parseSchema` (`en-core/src/En/Schema/Parse.hs`) — the file is en's compact
  textual schema DSL, **not** a serialized `Schema` and **not** Haskell. The `En.Schema.Builder`
  combinators (`object`/`relation`/`permission`/`computed`/`this`) are for constructing a
  `Schema` *in Haskell* (e.g. en's own `demoSchema`); they are reference-only for us. The
  artifact this plan ships to `en-server` is a `.en` text file (see Context for the exact
  syntax), mounted via ConfigMap.
  Date: 2026-06-24

- Decision: **This plan must build a container-image build+push step for the enforcer; none
  exists to reuse.** Rationale (added after validation): the repo's "private registry pull gap"
  work (`nixos/hosts/nagare-01/registries.nix`) solves *pulling* private Artifact Registry
  images into k3s. It does **not** build or push images. nagared's image
  (`…/nagare/nagared:latest`) is referenced by a hardcoded URI with **no Dockerfile and no nix
  derivation in the repo** — its build is manual/undocumented. So "reuse the existing
  private-image build machinery" is not possible; M1/M4 must establish an actual image build
  (Dockerfile or a nix image derivation producing an `amd64` image) and a push step, then reuse
  only the existing *pull* credentials path. This is the largest newly-surfaced scope item.
  Date: 2026-06-24

- Decision: **The auth plane (shomei + en + nagare-access) is an OPTIONAL, separately-bootstrapped
  component — opt-in at two independent levels.** (1) *Per-site:* the DSL `access` field defaults
  to `Nothing` = public; a site is protected only when it explicitly sets `access = requireLogin`,
  and public sites' routes are never repointed at the enforcer, so the enforcer is invisible to
  them. (2) *Cluster-wide:* the three services are their own `kubectl apply` bundle under
  `cluster/bootstrap/{shomei,en,nagare-access}/`, deliberately **not** part of the core
  `just cluster-bootstrap`. An operator who never uses `requireLogin` simply never applies them
  and therefore never runs the two Postgres DBs + three services on the single VM. Consequence
  (handled by the next decision): because the plane can be absent, `nagarectl` must fail closed
  with a clear message when a site requests login but the plane is not installed — it must never
  produce a route pointing at a nonexistent enforcer.
  Rationale: nagare is a single-tenant personal PaaS on one VM; forcing the full auth stack on
  every operator regardless of need is the wrong default. Making optionality an explicit
  guarantee (not just an emergent property of the bootstrap layout) keeps the resource cost
  pay-for-what-you-use and the failure modes honest.
  Date: 2026-06-24

- Decision: **`nagarectl` preflights enforcer presence before wiring a protected site, and fails
  closed with an actionable error if the auth plane is absent.** When `resolveAccess` is asked to
  protect a host (`Just policy`) it first checks the enforcer Service exists in `nagare-system`;
  if not, the deploy aborts with a message pointing at the managed DB, shomei, en, and
  nagare-access install sequence in `docs/user/access.md`, and the route is **not** repointed.
  Without this, M3 would silently repoint a host's route at a nonexistent enforcer Service and
  break the site with an opaque 5xx.
  Rationale: Closes the gap that "the plane is optional" otherwise opens; preserves the
  fail-closed property (a broken-but-loud deploy beats a silently dead site).
  Date: 2026-06-24

- Decision: **The enforcer is deployed as a Knative Service (`ksvc`, `min-scale=1`), not a raw
  k8s Deployment — pending M0 confirmation.** A Knative `DomainMapping` can only target a Knative
  resource, and M3 repoints a protected host's DomainMapping at the enforcer; a raw Deployment +
  Service could not be a DomainMapping target. So the enforcer mirrors nagared's shape (always-on
  via `min-scale=1`/`max-scale=1`, never scale-to-zero, since it sits in the hot request path).
  This is **contingent on the M0 routing-insertion finding**: if M0 shows the route must instead
  forward to a cluster-local address that a `ksvc` cannot serve, fall back to a raw Deployment +
  a dedicated route object (the fallback already noted in Idempotence and Recovery). Earlier
  prose said "Deployment + internal Service"; this supersedes it.
  Rationale: Resolves the M3/M4 inconsistency (DomainMapping target must be Knative); aligns the
  enforcer with the one working in-cluster-service precedent (nagared).
  Date: 2026-06-24

- Decision: **The M2 config wire format is a nullable `access` object, omitted/absent meaning
  public.** `Nagare.Dsl.Config` emits `"access": null` for public deployments and an object
  `{ "audience": ..., "permission": "access" }` for protected deployments. `Nagare.Dsl.Load`
  treats an absent `access` key as `Nothing` so older config output and hand-written JSON stay
  public. The renderer continues to emit no access-specific YAML; deploy-time code in M3 must
  read the in-memory `Deployment` / `Application` field.
  Rationale: This mirrors the broker-binding pattern: the DSL carries typed intent, while
  `nagarectl` performs all cluster side effects. Making absence public preserves backward
  compatibility and keeps the one-line opt-in (`access = Just requireLogin`) explicit.
  Date: 2026-06-24

- Decision: **Bootstrap `nagare-access` as a compiling package before adding shomei/en
  dependencies.** The initial package contains the WAI shell and pure request-policy helpers
  only; shomei/en dependencies will be added when the modules that actually use them land.
  Rationale: This keeps the first M1 slice buildable and testable while still creating the
  intended standalone package boundary. It avoids adding a large auth/proxy dependency closure
  to a cabal file before any code proves the imports and API usage. The package-level boundary,
  executable name, workspace shape, health endpoint, and SPA challenge semantics are now
  fixed for the remaining M1 work.
  Date: 2026-06-24

- Decision: **Use a hand-rolled `http-client` forwarder before introducing a streaming proxy
  abstraction.** `mori registry search http-client` found the local `snoyberg/http-client`
  corpus and `mori registry search http-reverse-proxy` found no registered reverse-proxy
  package. The existing nagare code already uses `http-client` in
  `cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs`, and the source confirms `parseRequest`,
  record updates for `method`/`path`/`queryString`/`requestHeaders`/`requestBody`, `httpLbs`,
  and response accessors are stable enough for this package. This first forwarder buffers
  request and response bodies with `strictRequestBody`/`httpLbs`; the M1 streaming item remains
  open for WebSocket upgrades, SSE, and large response bodies.
  Rationale: This creates a real, tested forwarding surface now, hardens the trusted identity
  headers before any upstream app can consume them, and avoids adding an unregistered proxy
  library before the project has proven exactly which streaming semantics it needs.
  Date: 2026-06-24

- Decision: **Stream normal HTTP/SSE bodies with `http-client` and WAI primitives; keep
  WebSocket `Upgrade` as a separate raw-tunnel task.** The local `http-client` source exposes
  `RequestBodyStreamChunked`, `responseOpen`, `BodyReader`, `brRead`, and `responseClose`; the
  local WAI source exposes `responseStream`. Those APIs cover large uploads, large downloads,
  and server-sent events because they are still ordinary HTTP request/response bodies. They do
  not grant bidirectional raw socket ownership after an `Upgrade: websocket` handshake, so
  WebSocket support remains in M1 as a later `responseRaw`/tunnel design rather than being
  hidden inside the body-streaming slice.
  Rationale: This removes the memory-risking buffered path immediately while keeping the
  harder WebSocket semantics explicit and testable. It also avoids incorrectly treating
  WebSockets as just another response body, which would fail real browser WebSocket clients.
  Date: 2026-06-24

- Decision: **Implement WebSocket proxying as a WAI raw response backed by an interactive
  `http-client` connection.** `mori registry search websockets` found no registered WebSocket
  package to read or depend on. The WAI/Warp source already exposes and tests `responseRaw` for
  upgrade situations, and `http-client` documents `withConnection` as the hook to use when a
  caller must read and write interactively through a connection, such as WebSocket protocol
  traffic. The implementation therefore uses `responseRaw` for the browser side and
  `withConnection` plus `Network.HTTP.Client.Internal` request/header helpers for the upstream
  side. The internal-module usage is deliberately isolated to `Nagare.Access.Proxy`'s upgrade
  path; normal HTTP and SSE continue to use stable `responseOpen`/`responseStream`.
  Rationale: This provides real byte tunneling without adding an unread/unregistered WebSocket
  dependency or terminating the WebSocket protocol in the enforcer. It also keeps the browser
  handshake owned by the upstream app: the proxy forwards the upstream 101 response rather than
  fabricating one itself.
  Date: 2026-06-24

- Decision: **Parse auth-plane environment now, but defer direct `shomei-jwt`/`en-client`
  package wiring until dependency sourcing is reproducible.** `mori registry show
  shinzui/shomei --full` confirmed the shomei source and APIs, but the current
  `nagare-access` flake check copies only the nagare repository into the build tree. Adding a
  committed sibling path such as `../../../shomei/shomei-jwt` to
  `cli/nagare-access/cabal.project` would work only on the local machine layout and would fail
  in the flake check. The next direct shomei/en integration should first add a reproducible
  source-repository-package, flake input, or in-repo vendoring strategy for these own-project
  packages. Until then, `RuntimeConfig` captures the required URL/issuer/audience/cookie/cache
  settings without importing those packages.
  Rationale: This moves M1 forward on the executable's real configuration contract while
  avoiding a machine-local dependency path in committed build metadata.
  Date: 2026-06-24

- Decision: **Pin shomei through Cabal source repositories for the verifier adapter.** The
  shomei repository has an HTTPS GitHub remote and a clean local checkout at
  `af09acecee6bafa3cf0087c5397c0f85da7aa1cc`. `cli/nagare-access/cabal.project` now pins
  `shomei-core` and `shomei-jwt` from that commit using the real repo subdirectories
  `shomei-core` and `shomei-jwt`. This resolves the shomei side of the dependency-sourcing
  issue without committing `/Users/...` paths. en remains unpinned until the first `en-client`
  adapter lands, at which point it should use the same source-repository pattern with the en
  repo's real subdirectories.
  Rationale: The verifier adapter needs actual `shomei-jwt` code, and Cabal source repositories
  are already the local pattern in `cli/nagarectl/cabal.project` for non-Hackage dependencies.
  Pinning by commit keeps the flake check's copied source tree reproducible enough for this
  project's current relaxed-sandbox Cabal checks.
  Date: 2026-06-24

- Decision: **Pin en through Cabal source repositories for the authorization adapter, and add
  PostgreSQL tooling to the flake's Cabal environments.** The en repository has an HTTPS GitHub
  remote and a local checkout at `d27bb440b4b125c9844be95a02d00f54c1eec261`. `cli/nagare-access/
  cabal.project` now pins the real en subdirectories `en-core`, `en-migrations`, `en-postgres`,
  `en-servant`, and `en-client`. The enforcer only calls `en-client`, but `en-client` depends on
  `en-servant`, whose exposed library includes server modules that depend on `en-postgres`;
  therefore the package closure currently requires libpq. `flake.nix` now adds
  `pkgs.postgresql` next to `zlib`/`pkg-config` in `haskellTooling`, the default dev shell, and
  the Haskell dev shell so local and flake-check Cabal builds provide `pg_config`.
  Rationale: The plan requires the real `en-client` API rather than an ad hoc HTTP client, and
  source-repository-package pins avoid committing machine-local sibling paths. Adding the narrow
  native PostgreSQL tool keeps this exact dependency path buildable until en splits wire/client
  types from server/Postgres modules.
  Date: 2026-06-24

- Decision: **Use a fixed 300-second JWKS cache TTL for the first executable wiring.** The
  runtime config already exposes `NAGARE_ACCESS_DECISION_TTL` for en authorization decisions,
  but that knob has different semantics from public-key refresh. `app/Main.hs` therefore uses a
  separate constant, `defaultJwksTtlSeconds = 300`, when constructing `JwksCache`; decision
  caching still uses the configured TTL. A later hardening pass can add
  `NAGARE_ACCESS_JWKS_TTL` or refresh-on-`kid`-miss behavior without changing the request-path
  service interfaces.
  Rationale: This wires real token verification now without conflating authorization staleness
  with key-rotation polling. Five minutes is short enough for shomei key rotation in this first
  pass and avoids fetching keys per request.
  Date: 2026-06-24

- Decision: **Carry optional cookie settings on `AccessServices` for reserved endpoints.**
  Most request-path auth behavior only needs token verification, en authorization, and
  forwarding, but `GET /_nagare/logout` must emit a `Set-Cookie` header with the configured
  parent-domain cookie scope. Rather than make `Nagare.Access.App` depend directly on
  `RuntimeConfig`, `AccessServices` now carries `cookieSettings :: Maybe CookieSettings`.
  `app/Main.hs` sets it when the auth plane is configured; tests and no-auth-plane defaults use
  `Nothing`.
  Rationale: This keeps the WAI app injectable in tests while giving reserved endpoints access
  to the one runtime value they need for browser-session behavior.
  Date: 2026-06-24

- Decision: **Implement the first login slice with an access-token cookie only; defer refresh-token
  storage and renewal.** `POST /_nagare/login` now calls shomei and stores the returned access
  token in `nagare_session` with `Max-Age = expiresIn`, making browser login immediately usable
  for the existing verifier path. The shomei response also returns a refresh token, but this
  slice deliberately does not store it yet because the plan still needs a cookie-key wrapping
  design and refresh-token rotation semantics. MFA is surfaced as `401 mfa required` for now;
  browser WebAuthn ceremony completion remains a separate remaining M1 item. Superseded for
  current behavior by the later `nagare_refresh` cookie decision and by the M1q WebAuthn MFA
  completion decision; retained here as the M1m scope decision.
  Rationale: This lands a working shomei-backed password login without inventing a weak
  long-lived refresh-token cookie format. Keeping refresh renewal explicit preserves the
  fail-closed behavior: sessions expire after the access-token lifetime until the refresh slice
  is implemented.
  Date: 2026-06-24

- Decision: **Store refresh tokens in a separate authenticated `nagare_refresh` cookie.** The
  cookie value format is `v1.<base64url refresh token>.<base64url HMAC-SHA256>`, where the HMAC
  signs the version and encoded refresh token using `NAGARE_ACCESS_COOKIE_KEY`. The cookie uses
  the same parent-domain, `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/` attributes as the
  access cookie, but a longer 30-day max age matching shomei's default refresh-token lifetime.
  The value is authenticated, not encrypted; the refresh token is already an opaque random
  bearer secret, and the cookie is not readable by JavaScript because it is `HttpOnly`.
  Rationale: This satisfies the plan's tamper-prevention requirement without introducing a
  custom encryption scheme or server-side session database. Shomei still owns refresh-token
  rotation and theft detection; the enforcer only stores the latest opaque token and clears both
  auth cookies when refresh fails.
  Date: 2026-06-24

- Decision: **Complete shomei MFA in the enforcer with a small WebAuthn bridge page, not by
  redirecting the browser to shomei.** shomei has no hosted login UI; it returns
  `ceremonyId` plus WebAuthn `options` from `POST /auth/login`, and expects the browser's
  assertion JSON at `POST /auth/mfa/complete`. The enforcer therefore keeps owning the
  browser-facing login surface: it renders a page that calls `navigator.credentials.get()` with
  shomei's options, posts the assertion to `/_nagare/mfa/complete`, and sets the same
  `nagare_session` / `nagare_refresh` cookies after shomei returns tokens.
  Rationale: This preserves the single shared-domain session-cookie model and avoids adding a
  second browser origin or redirect target for shomei. CSRF remains enforced by reusing the
  `__Host-nagare_csrf` token issued by the login form; the actual WebAuthn assertion is still
  verified by shomei.
  Date: 2026-06-24

- Decision: **Keep the shomei+en request-path integration test in `nagare-access-test`, with
  shomei-server dependencies test-only.** The test suite now boots the real shomei WAI app
  against ephemeral PostgreSQL and the real en Servant app in-memory, then drives the enforcer
  through login, JWKS verification, en authorization, and proxy forwarding. This is heavier than
  a pure unit test, but it is the strongest local evidence for the M1 contract and avoids a
  separate script that can rot. The required shomei-server, migrations, WebAuthn, codd, and
  ephemeral-pg pins live in `cli/nagare-access/cabal.project`; production `library` and
  executable dependencies are unchanged, while the test suite explicitly depends on the
  shomei-server test-support closure. The `time ==1.14` constraint and `allow-newer:
  haxl:time` relaxation are copied in spirit from shomei's workspace so en and shomei solve
  together under this repo's GHC 9.12.3 shell.
  Rationale: M1's last open risk was that individually-correct shomei, en, and proxy adapters
  might not compose on the browser request path. A normal-suite integration test proves that
  composition every time `cabal test all` runs from `cli/nagare-access`.
  Date: 2026-06-24

- Decision: **Represent protected wildcard hosts with a temporary DomainMapping override.**
  Custom domains already have DomainMapping objects, so the access resolver can apply the same
  DomainMapping name with its target switched between the app and the enforcer. A deployment
  with no custom domains normally uses Knative's generated wildcard host
  `<service>.<namespace>.<baseDomain>` and has no DomainMapping object of its own; for a
  protected wildcard host, the resolver creates a DomainMapping for that exact host pointing at
  the enforcer, and when the site becomes public again it deletes that override so Knative's
  default generated route serves the app directly.
  Rationale: This gives `access = requireLogin` a route object to repoint even for the default
  host form without changing the DSL surface or app renderer. It is idempotent and reversible:
  protected deploys re-apply the same override, while public deploys remove it with
  `--ignore-not-found`.
  Date: 2026-06-24

- Decision: **Use raw en HTTP JSON in `nagarectl access`, not the `en-client` dependency
  closure.** The grant commands only need en's stable wire endpoints (`POST /tuples`,
  `DELETE /tuples`, and `POST /expand`) and the tiny `ObjectRefWire`/`SubjectWire`/`TupleWire`
  JSON shapes already confirmed from `en-servant`. Pulling `en-client` into `nagarectl` would
  also pull `en-servant` and its current server/Postgres closure into the deploy CLI, while the
  enforcer package already carries that heavier dependency where it is needed for per-request
  authorization. `nagarectl` therefore keeps a local, tested HTTP wrapper for these operator
  commands.
  Rationale: This keeps the CLI's dependency surface small and avoids adding server-side en
  build requirements to ordinary deploy workflows solely for three administrative tuple
  operations.
  Date: 2026-06-24

- Decision: **Use en `expand`, not `lookup`, for `nagarectl access list --host`.** en's
  `lookup` endpoint starts from a subject and returns objects the subject can access; the
  operator command starts from one host and needs the subjects that expand to its `access`
  permission. `POST /expand` is the endpoint with the correct direction for that question.
  Rationale: Listing grants by host must be object-to-subject expansion. Using lookup would
  require one request per possible user and would not answer the command's question.
  Date: 2026-06-24

- Decision: **Use a repository-root Docker build for the first `nagare-access` image path.**
  `cli/nagare-access/Dockerfile` is built from the repository root so it can copy both
  `cli/nagare-access/` and the sibling `cli/nagare-dsl/` package that the Cabal workspace
  lists. The bootstrap helper `cluster/bootstrap/nagare-access/build-image.sh` tags the result
  as `${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/nagare-access:<tag>`
  for `linux/amd64` and pushes it by default.
  Rationale: The repo did not have reusable image-build machinery for in-cluster services, and
  a root-context Docker build is the smallest explicit path that preserves the standalone
  `nagare-access` package boundary while producing the platform image the single-node cluster
  needs.
  Date: 2026-06-24

- Decision: **Ship the first auth-plane bootstrap as opt-in apply-able templates, not a
  turnkey `just cluster-bootstrap` addition.** The new `cluster/bootstrap/shomei/`,
  `cluster/bootstrap/en/`, and `cluster/bootstrap/nagare-access/` directories each include the
  `nagare-system` Namespace so applying any one directory is idempotent, but the core
  `just cluster-bootstrap` recipe remains unchanged.
  Rationale: This preserves the plan's cluster-wide optionality guarantee: operators who never
  use `access = requireLogin` do not install shomei, en, or the enforcer. The example image
  refs, database connection Secret templates, cookie key, and cookie domain are intentionally
  operator-edited until M4b verifies the exact target-cluster release images and database
  wiring.
  Date: 2026-06-24

- Decision: **Run en migrations with a `postgres:18` psql bootstrap Job until en publishes a
  valid migration image or executable.** en's `en-migrations` package currently ships SQL files
  and a `migrationsDir` pointer, but no standalone migration executable. The first bootstrap
  attempted to run those SQL files through codd, but `docker.io/mzabani/codd:latest` is not
  pullable by the target cluster's containerd because its image config has a string `Entrypoint`;
  the local codd Nix image definition has the same issue. The Kubernetes bootstrap therefore
  mounts en's two SQL files into `cluster/bootstrap/en/migrations.yaml` and runs `psql` from
  `postgres:18` against Secret `nagare-db-en-db` keys `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
  `POSTGRES_DB`. The script checks `to_regclass('public.relation_tuple')` first and exits
  successfully when the schema is already present.
  Rationale: `en-server` fails if its tables do not exist, so migrations must be part of the
  install workflow. The psql Job is narrower than codd but idempotent for the current en schema
  and uses an image the cluster already needs for managed Postgres. Replace it with codd or an
  en-owned migration executable once a valid image exists.
  Date: 2026-06-25

- Decision: **Temporarily kept shomei/en image references operator-provided until their image
  build paths were verified.** shomei advertises `packages.dockerImage` in `flake.module.nix`, but
  `SHOMEI_PUSH=0 cluster/bootstrap/shomei/build-image.sh test-local` failed during validation
  when `nix build ../shomei#dockerImage` reached `cabal2nix` and found neither a root `.cabal`
  file nor `package.yaml`. That helper was not kept. en's inspected source has no Dockerfile or
  image derivation. `cluster/bootstrap/shomei/service.yaml` and
  `cluster/bootstrap/en/service.yaml` therefore remain operator-provided image references until
  shomei's flake image is fixed and en publishes a release image or this plan adds separately
  verified helpers.
  Rationale: M4b needs a truthful install contract. Shipping an unverified helper would make the
  auth plane look more complete than it is and would fail late in the cluster.
  Date: 2026-06-24

- Decision: **Harden the `nagare-access` Knative container security context now.** Server-side
  dry-run against the target Knative cluster accepted the enforcer manifest but warned that
  several Kubernetes default values are insecure. The manifest now sets explicit no-privilege,
  drop-all-capabilities, non-root, RuntimeDefault-seccomp settings, and the Dockerfile creates a
  non-root `nagare` user so `runAsNonRoot: true` has a matching image-level user.
  Rationale: The enforcer is request-path infrastructure for private sites. Tightening these
  defaults while the bootstrap manifest is still being hardened is low-risk and removes a
  target-cluster warning from the acceptance path.
  Date: 2026-06-24

- Decision: **Keep the `nagare-access` Docker build on Docker Hub `haskell:9.12.2` and pass
  private GitHub access as a BuildKit secret.** Docker Hub does not publish
  `haskell:9.12.2-slim`, so the build stage now uses `haskell:9.12.2`. The Cabal workspace pins
  private own-project source repositories (`shinzui/shomei`, `shinzui/en`, and related forks),
  so a clean Docker build needs credentials. `cluster/bootstrap/nagare-access/build-image.sh`
  passes `GITHUB_TOKEN` as a BuildKit secret when it is set, and the Dockerfile temporarily
  rewrites `https://github.com/` fetches only inside the build layer before removing that Git
  config.
  Rationale: The enforcer image must be buildable in a clean Docker environment without baking a
  token into the image or repository. BuildKit secrets are the narrowest available mechanism for
  the current Cabal source-repository-package setup.
  Date: 2026-06-24

- Decision: **Use Nagare managed databases named `shomei-db` and `en-db` instead of bespoke auth-plane DB
  Secrets.** The bootstrap manifests now expect the `nagare-system` namespace to exist, then
  `nagarectl db create postgres shomei-db --namespace nagare-system` and
  `nagarectl db create postgres en-db --namespace nagare-system` to create the PostgreSQL
  StatefulSets, Services, and managed credential Secrets. shomei maps Secret
  `nagare-db-shomei-db` keys `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` into a
  libpq keyword `PG_CONNECTION_STRING`. en maps Secret `nagare-db-en-db` keys `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, and `POSTGRES_DB` into a libpq keyword `EN_DATABASE_URL`; the
  `en-migrate` Job consumes the same keys through standard `PG*` environment variables.
  Rationale: This reuses the existing Nagare DB lifecycle, backup, and Secret naming contract,
  avoids a second manual credential format, prevents placeholder shomei/en Secret templates
  from being accidentally applied as real credentials, and avoids Kubernetes Service name
  collisions with the auth services named `shomei` and `en`. The remaining `nagare-access`
  cookie-key example uses a `.tmpl` suffix for the same reason.
  Date: 2026-06-25

- Decision: **Build auth-plane images from local source checkouts when upstream release images
  are unavailable.** `cluster/bootstrap/auth-images/build-local-image.sh` now constructs a
  temporary Docker context containing Nagare plus local shomei, en, and codd checkouts, pins
  jose, servant-openapi, openapi-hs, and the Shomei WebAuthn fork as public git dependencies,
  writes a service-specific `cabal.project` with local package paths, and builds
  one of `nagare-access`, `shomei`, or `en` with the shared
  `cluster/bootstrap/auth-images/Dockerfile.local-haskell`. The helper defaults to
  `haskell:9.12.4`, `linux/amd64`, `NAGARE_AUTH_CABAL_BUILD_FLAGS=--jobs=1`, and Artifact
  Registry-compatible image names, while `NAGARE_AUTH_PUSH=0` keeps validation local.
  `cluster/bootstrap/shomei/build-image.sh` and `cluster/bootstrap/en/build-image.sh` delegate
  directly to it, and `cluster/bootstrap/nagare-access/build-image.sh` opts into it with
  `NAGARE_ACCESS_LOCAL_SOURCES=1` or `NAGARE_AUTH_LOCAL_SOURCES=1`. The same helper supports
  `NAGARE_AUTH_BUILDER=cloud-build`, which uploads the generated context to Cloud Build, uses
  Docker BuildKit, and defaults to an `e2-highcpu-32` remote builder for amd64 images. For the
  current single-node `nagare-01` cluster, the helper also supports
  `NAGARE_AUTH_BUILDER=k3s-import`, which builds with Podman on the remote amd64 node and imports
  the resulting `dev.local/nagare-auth/<service>:<tag>` image directly into k3s containerd.
  Rationale: The earlier clean Docker path still required private GitHub credentials for Cabal
  to fetch `shinzui/shomei` and `shinzui/en`, and shomei/en do not currently publish working
  release images. A local-source context makes the install contract explicit and reproducible
  from the checked-out dependency source already required by this plan. The helper deliberately
  copies only dependency checkouts that are current for GHC 9.12 and uses public pins for
  `jose`, `servant-openapi`, `openapi-hs`, and the Shomei WebAuthn fork, because the local mori
  `hs-jose` and upstream `tweag/webauthn` checkouts are stale for the active crypton/ram stack.
  The first no-push amd64 validation reached Cabal but exhausted the local aarch64 Colima VM
  while emulating amd64, so Cloud Build is the repeatable remote-builder path for non-amd64
  local hosts. Cloud Build was enabled in `tan-nb-exp`, but the first submit failed with IAM
  `PERMISSION_DENIED` for the only active gcloud account. The `k3s-import` backend is the
  lowest-friction path for the current single-node deployment because it avoids registry
  push/pull IAM entirely while still producing the same amd64 image on the target machine; it is
  not a general multi-node distribution path.
  Date: 2026-06-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of nagare, shomei, or en. Read it fully before
starting.

### What nagare is, and how a site reaches the internet today

nagare is a single-tenant personal platform-as-a-service. It runs one `k3s` cluster (a
lightweight Kubernetes) on one GCP virtual machine. On top of `k3s` it runs **Knative
Serving** (the layer that turns a container into an auto-scaling, scale-to-zero web service)
and **Kourier** (Knative's ingress; Kourier is just an Envoy proxy with no extra Kubernetes
custom resources). The request path for a deployed site is:

```text
Internet
  → Cloud DNS resolves *.apps.example.com to the VM's public IP (wildcard A record)
  → Kourier's Envoy on host ports 80/443 terminates TLS (cert-manager wildcard cert)
  → routes by HTTP Host header to the Knative Service (ksvc)
  → the app pod
```

Key files for that path:

- `cluster/bootstrap/kourier/` — Kourier install notes; it is "just Envoy, no extra CRDs".
- `cluster/bootstrap/knative-serving/config-network.yaml` — selects Kourier as the ingress
  class and sets `autocreate-cluster-domain-claims: "true"` (lets a site claim a custom
  domain without manual admin approval).
- `cluster/bootstrap/knative-serving/config-domain.yaml` — sets the base domain (replaces the
  Kubernetes-internal default), so a `ksvc` named `hello` in namespace `personal` is reachable
  at `hello.personal.<baseDomain>` (and at any custom domain bound by a **DomainMapping**, a
  Knative resource that maps an external hostname to a `ksvc`).
- `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml` — the TLS certificate issuer.
- `infra/pulumi/src/components/NagarePerimeter.ts` — creates the Cloud DNS zone and the
  `*.apps.example.com` wildcard record.

Crucially, **Kourier does not expose an external-authorization hook through Knative
configuration.** There is no place to say "before routing to this app, call my auth
service." That is the central constraint this plan works around (see the routing-layer
insertion decision above), and the reason the eventual clean solution is an Envoy Gateway
migration (covered under "Future direction").

### How a site is described: the typed DSL and the broker-binding template

A site is **not** YAML. It is a Haskell value of type `Deployment` (single web service) or
`Application` (a multi-workload aggregate). The DSL library lives under
`cli/nagare-dsl/src/Nagare/Dsl/`. The relevant types:

- `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` — the `Deployment` record. Its fields include
  `name`, `namespace`, `image`, `domains`, `port`, `env`, `resources`, `scale`,
  `healthCheck`, `volumes`, `databases`, and (added recently) `brokers`.
- `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` — the `Application` aggregate (shared
  image/env, an optional web service, workers, databases, tasks, and `brokers`).
- `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` — `Worker`, a long-running non-HTTP workload.

The most recent feature (git log: `feat(dsl): add typed broker model`, `feat(dsl): add
broker workload bindings`, `feat(nagarectl): inject broker connection env`) added a
**workload binding**: a small typed reference an app declares, which `nagarectl` resolves to
concrete configuration **at deploy time** and injects as environment variables. We mirror
this pattern exactly. The broker binding is the template:

- `cli/nagare-dsl/src/Nagare/Dsl/Broker/Types.hs`:

  ```haskell
  data BrokerBinding = BrokerBinding
    { name :: !BrokerName
    , topics :: ![TopicName]
    }
    deriving stock (Generic, Eq, Show)
  ```

  with smart constructors of the standard shape `mkBrokerName :: Text -> Either Text
  BrokerName` (reject empty, too-long, bad characters) and accessors like `brokerNameText ::
  BrokerName -> Text`. This `mkXxx :: Text -> Either Text Xxx` idiom is used throughout the
  DSL; every new type we add follows it.

- The `Deployment`/`Worker`/`Application` records each carry `brokers :: ![BrokerBinding]`,
  defaulting to `[]` (the backward-compatible "no brokers" default).

- Deploy-time resolution lives in `nagarectl`, not in the renderer:
  `cli/nagarectl/src/Nagare/Deploy/Resolve.hs` has `resolveBrokerEnv :: Namespace ->
  [BrokerBinding] -> IO (Map EnvName ScopedEnvVar)`, which for each binding looks up the live
  broker and produces env vars; `cli/nagarectl/src/Nagare/App/Deploy.hs` calls it and merges
  the result into the rollout's shared env (`RolloutEnv.reAppEnv`). A binding produces **no
  standalone YAML**; it contributes env to the workload's container.

- A concrete example to copy the *shape* of:
  `cluster/examples/broker-worker/nagare/Config.hs` declares `brokers = [BrokerBinding {name
  = broker, topics = [topic]}]`.

Our `access` binding is slightly richer than "inject env" because it also has to (a) ensure
an en object exists, (b) update the enforcer's host→backend map, and (c) repoint the route —
all at deploy time, the same place `resolveBrokerEnv` runs.

### What shomei provides (authentication)

shomei (`/Users/shinzui/Keikaku/bokuno/shomei`, registered in `mori` as `shinzui/shomei`)
is a Haskell authentication toolkit. Relevant facts confirmed by reading its source:

- It runs as `shomei-server`, a Warp HTTP server backed by PostgreSQL, exposing the
  `ShomeiAPI` (`shomei-servant/src/Shomei/Servant/API.hs`). The endpoints we use:
  - `POST /auth/login` — body `LoginRequest { loginId?, email?, password }`; success returns
    `LoginResponse` tagged `"complete"` with `user` and a `token` pair, or `"mfa_required"`
    with a ceremony id (passkey step-up). On bad credentials it returns a deliberately
    generic `401 invalid_login`.
  - `POST /auth/refresh` — body `RefreshRequest { refreshToken }`; returns a rotated
    `TokenPairResponse { accessToken, refreshToken, expiresIn }`. Reusing an old refresh
    token returns `401 token_reuse` and revokes the session family.
  - `GET /.well-known/jwks.json` — the public JSON Web Key Set: the public keys (active plus
    recently-rotated) that verify access tokens. No private material.
- Access tokens are signed JWTs (ES256 by default). Claims include `iss` (issuer), `sub`
  (the user id), `aud` (audience), `iat`/`exp`, and custom `sid` (session id), `scopes`,
  `roles`. Default access-token lifetime is **15 minutes**; refresh token / session **30
  days** (`shomei-core/src/Shomei/Config.hs`).
- Verification is a library function in `shomei-jwt`:

  ```haskell
  -- shomei-jwt/src/Shomei/Jwt/Verify.hs
  verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
  ```

  Given the fetched JWKS, the expected issuer+audience (from a `ShomeiConfig`), and the raw
  JWT string, it returns the verified `AuthClaims` (`shomei-core/src/Shomei/Domain/Claims.hs`)
  carrying `subject :: UserId`, `sessionId`, `issuer`, `audience`, `expiresAt`, `scopes`,
  `roles`. **This is the function the enforcer calls on every request.**
- The Haskell client (`shomei-client/src/Shomei/Client.hs`) offers `login :: ClientEnv ->
  LoginRequest -> IO (Either ClientError LoginResponse)` and `refresh :: ... ->
  RefreshRequest -> IO (Either ClientError TokenPairResponse)`, plus `shomeiClientEnv :: String
  -> IO ClientEnv`. The enforcer uses these to perform the actual login when a user submits
  the login form.
- **Cookies:** shomei's server *reads* a `shomei_session` cookie as a token source
  (`extractToken` in `shomei-servant/src/Shomei/Servant/Auth.hs`) and defines a
  `TokenTransport` config enum, but it **does not currently emit `Set-Cookie`** (the
  generation is unimplemented). Therefore the enforcer owns cookie issuance: on successful
  login it sets `Set-Cookie: nagare_session=<accessToken>; Domain=.<baseDomain>; HttpOnly;
  Secure; SameSite=Lax; Path=/; Max-Age=<expiresIn>` and clears it on logout. The
  `Domain=.<baseDomain>` scope is what makes single sign-on span every protected site.
  (Confirm the "no Set-Cookie yet" fact in M0; if shomei has since added cookie emission,
  record it and prefer reusing it.)

shomei is **not** an OIDC provider — there is no `/authorize`, `/token`, or
`/.well-known/openid-configuration`. That single fact is what rules an off-the-shelf
OIDC proxy out of the direct path and motivates Path A.

### What en provides (authorization)

en (`/Users/shinzui/Keikaku/bokuno/en`, `mori` `shinzui/en`) is a Haskell ReBAC
(relationship-based access control, the Google-Zanzibar model) toolkit. Relevant facts
confirmed by reading its source:

- It runs as `en-server` (`en-server/app/Main.hs`), a Warp server backed by PostgreSQL,
  configured by env: `EN_DATABASE_URL` (required), `EN_PORT` (default 8080), `EN_SCHEMA_PATH`
  (the authorization schema to load), plus optional cache knobs.
- The wire API (`en-servant/src/En/Servant/API.hs`) includes `POST /check`, `POST /tuples`
  (write), `DELETE /tuples`, `POST /batch-check`, `POST /lookup`, `POST /expand`.
- A **check** asks "does subject *S* have permission *P* on object *O*?":

  ```haskell
  data CheckRequestWire = CheckRequestWire
    { consistency :: !ConsistencyWire   -- MinimizeLatencyWire | FullyConsistentWire | AtLeastAsFreshWire Text | ...
    , context     :: !CaveatContextWire -- runtime values for conditional rules; empty for us
    , subject     :: !SubjectWire        -- who is asking
    , permission  :: !Text               -- e.g. "access"
    , object      :: !ObjectRefWire      -- { objectType, objectId }
    }

  newtype CheckResponseWire = CheckResponseWire { decision :: CheckDecisionWire }
  data CheckDecisionWire = AllowedWire | DeniedWire | ConditionalWire ![CaveatObligationWire]
  ```

- The Haskell client (`en-client/src/En/Client.hs`) exposes a record `EnClient` whose
  `check :: CheckRequestWire -> ClientM CheckResponseWire` (and `writeTuples`, etc.) run in
  Servant's `ClientM`; you execute them with `runClientM`. **This is what the enforcer calls
  for the authZ decision.**
- The **schema** defines object types, relations, and permissions. **`en-server` loads it from
  a text file**: it reads `EN_SCHEMA_PATH`, `Text.readFile`s the contents, and parses them with
  `parseSchema` (`en-core/src/En/Schema/Parse.hs`) — en's compact textual schema DSL. The file
  this plan ships (mounted via ConfigMap, conventionally `app.en`) is therefore **text, not
  Haskell and not JSON**. We add an `app` object type; the actual file content is:

  ```text
  object app {
    relation viewer: user
    permission access: viewer
  }
  ```

  So an `app` has a `viewer` relation (users directly granted), and an `access` permission
  that is satisfied by being a viewer. (Groups/teams can be layered later via `userset` /
  `tupleToUserset`; out of scope here.)

  The Haskell builder combinators (`object`/`relation`/`permission`/`computed`/`this` in
  `en-core/src/En/Schema/Builder.hs`) construct the same `Schema` value **in-process** — en's
  own `demoSchema` uses them — but they are **reference-only** here: what we deploy is the `.en`
  text above. For comparison, the equivalent builder form is:

  ```haskell
  -- reference only; NOT what en-server loads from EN_SCHEMA_PATH
  appObject <- object "app"
    [ relation "viewer" [subject "user"] this
    , permission "access" (computed "viewer")
    ]
  ```
- **Granting** a user access to a site is one tuple write (`POST /tuples`):

  ```json
  {
    "tuples": [{
      "object":   { "objectType": "app", "objectId": "tools.apps.example.com" },
      "relation": "viewer",
      "subject":  { "tag": "SubjectIdWire",
                    "contents": { "objectType": "user", "objectId": "alice" } },
      "caveat": null
    }]
  }
  ```

  The response returns a consistency token (used only if you need read-your-writes; with
  `MinimizeLatency` we ignore it).

### Decision: Path A vs Path B (the enforcer technology)

Both paths share everything *except* how authentication is performed; both still require en
for per-site authorization. The user explicitly asked to compare them, so the comparison is
recorded here in full and the choice is logged in the Decision Log.

**Path A — thin native Haskell enforcer (CHOSEN).** The `nagare-access` service speaks
shomei's existing APIs directly: it renders its own minimal login page, POSTs submitted
credentials to shomei `POST /auth/login` via `shomei-client`, issues the `nagare_session`
cookie itself, and on every request verifies the cookie's JWT with `shomei-jwt`'s
`verifyToken` and authorizes with `en-client`'s `check`. One service, one hop, authN+authZ
together.

**A note on "stack", because it is easy to misread:** "native Haskell" / "all-Haskell"
describes the *enforcer and the auth plane only* (the enforcer, shomei, en). It says nothing
about the protected workloads. The whole point of forward-auth is that the upstream is opaque:
the enforcer reverse-proxies to any HTTP server. The sites this feature protects are expected
to be mostly **static bundles and TanStack apps (TanStack Start SSR and client-rendered
SPAs)**, plus the occasional other-language service — none of them Haskell, and none of them
needing to know they are behind auth. Path A reuses `shomei-client`/`shomei-jwt`/`en-client`
to *build the enforcer*; it imposes nothing on the apps. This makes the protected-app language
mix **neutral between Path A and Path B** — both gate any HTTP app identically — and if
anything it favors a single uniform edge enforcer (Path A's shape), since the apps will not
implement authentication themselves. (Path B's "shomei becomes a standard OIDC provider" only
pays off when apps perform their own in-app OIDC login, which is the opposite of edge
enforcement and not a goal here.)

- Pros: No new protocol to implement in shomei. Reuses `shomei-client`, `shomei-jwt`,
  `en-client` — all already in the monorepo. authN and authZ happen in the same process, so
  there is exactly one place to reason about access. Smallest moving-parts count for a
  single-tenant PaaS. The same service becomes the Envoy Gateway `ext_authz` target later
  with no redesign.
- Cons: We own and must harden the browser-facing bits ourselves: the login form, CSRF
  protection on the login POST, an open-redirect allowlist for the post-login `rd` (return
  destination) parameter, cookie flags, and the access-token refresh dance (15-minute access
  tokens mean the enforcer must transparently refresh using the stored refresh token). shomei
  has no hosted login UI, so the enforcer is the login UI.

**Path B — add OIDC to shomei, then use an off-the-shelf proxy.** Implement the OpenID
Connect authorization-code flow in shomei (`/.well-known/openid-configuration`, `/authorize`,
`/token`, PKCE, a hosted login+consent UI), then deploy a mature proxy such as oauth2-proxy
or Pomerium as the enforcer; it handles the browser redirect dance and cookie/session.

- Pros: Battle-tested browser/session/CSRF/refresh handling lives in the proxy, not in our
  code. shomei becomes a standard OIDC identity provider, which any future third-party or
  non-Haskell tool can integrate with. A hosted login UI is a natural by-product.
- Cons: Substantially more work *in shomei* (a correct OIDC provider is a large, security-
  sensitive surface: auth-code+PKCE, token endpoint, discovery, consent, client registration).
  And it does **not** remove the en hop: oauth2-proxy/Pomerium authenticate and at most apply
  a coarse allowlist or their own policy language — neither speaks en's ReBAC graph — so we
  would *still* bolt en on via a second authorization step (oauth2-proxy's upstream headers
  feeding an en check, or Pomerium policy that cannot express our tuples). So Path B fractures
  authorization across two systems while adding a protocol, for a single-tenant deployment
  that does not yet need third-party OIDC interop.

**Verdict:** Path A now; keep Path B's OIDC work as a *future, independent* enhancement to
shomei if and when external OIDC interop is actually needed. Choosing A does not preclude B:
if shomei later grows OIDC, the enforcer can be swapped for oauth2-proxy in front of the same
en check, because the en authorization model is unchanged.

### Future direction (out of scope, but the plan is shaped to reach it)

The `docs/roadmaps/ingress-networking-layer-roadmap.md` already anticipates migrating ingress
from Kourier to **Envoy Gateway** (Envoy with the Kubernetes Gateway API and `SecurityPolicy`
custom resources). When that happens, the same `nagare-access` enforcer becomes an
**`ext_authz`** target referenced by a per-route `SecurityPolicy`, and the routing-layer
insertion (and host→backend map) from this plan disappears in favor of native per-route
policy. The DSL surface (`access = requireLogin`) does **not** change across that migration —
only the enforcement plumbing does. Nothing in this plan should hard-code assumptions that
block that future; in particular, the enforcer must be able to run both as a forwarding
reverse proxy (today) and as a pure decision endpoint (the `ext_authz` "check" response) later.


## Plan of Work

The work is six milestones. Each is independently verifiable. Earlier milestones de-risk the
unknowns (M0 spike) and build the core service in isolation (M1) before any nagare wiring, so
that a failure is localized.

### Milestone 0 — Spike: prove insertion and integration (throwaway, ~½ day)

Scope: answer the two riskiest unknowns before building anything real. (1) Can a single small
proxy verify a shomei token + call en + forward to an upstream, producing the 302/403/200
behaviors? (2) Can a Knative route be pointed at a stand-in backend that forwards to a
cluster-local `ksvc`, i.e. is the routing-layer insertion actually viable on this Kourier
setup?

What exists at the end: a `scratchpad`/spike directory (not committed, or committed under
`docs/plans/spikes/81/` if useful) with a working toy proxy and a short written finding in
Surprises & Discoveries confirming or refuting the two cookie/ingress expectations.

Work:

1. Run shomei and en locally. In the shomei repo: `nix develop`, `just create-database`,
   `cabal run exe:shomei-server` (reads `PG_CONNECTION_STRING`). Create a user with
   `shomei-admin` (`users create --loginId alice --password ...`). In the en repo: `nix
   develop`, start `en-server` with `EN_DATABASE_URL`, `EN_SCHEMA_PATH` pointed at an `app.en`
   file containing the **text-DSL** schema from Context (`object app { relation viewer: user
   permission access: viewer }`) — not Haskell, not JSON; `en-server` parses it with
   `parseSchema`. Fetch
   `http://localhost:8080/.well-known/jwks.json` from shomei to confirm the JWKS shape.
2. Write a ~100-line WAI app (in the scratchpad) that: extracts a token from the
   `nagare_session` cookie or `Authorization` header; if absent, returns `302` to a fake
   `/_nagare/login`; else `verifyToken jwks cfg token`; if invalid/expired, `302` to login;
   else build a `CheckRequestWire` (subject = `user:<sub>`, permission `access`, object =
   `app:<Host header>`) and call en `check`; on `DeniedWire` return `403`; on `AllowedWire`
   reverse-proxy to a dummy upstream (`http-echo` or a tiny warp app) and return its response.
3. By hand (curl), reproduce: no cookie → 302; valid token but no en tuple → 403; after
   `POST /tuples` granting `alice` viewer on `app:localhost` → 200 with the upstream body.
4. On the cluster (or a local k3s), point a Knative route/DomainMapping at a stand-in backend
   and confirm it can forward to another `ksvc`'s cluster-local address. The goal is to confirm
   the *mechanism* (route → enforcer → cluster-local app), not to wire nagare. **Crucially, this
   step also fixes the enforcer's deployed shape:** a DomainMapping can only target a Knative
   resource, so deploy the stand-in as a Knative `ksvc` and confirm the DomainMapping→`ksvc`→
   cluster-local-`ksvc` chain works. If it does, the enforcer is a `ksvc` (the planned shape,
   like nagared); if a `ksvc` cannot serve this role, record it and switch to the raw
   Deployment + dedicated-route fallback (Idempotence and Recovery). Write the confirmed shape
   into the M4 decision.

Acceptance: the three curl outcomes above are observed and pasted into Surprises &
Discoveries; the routing-insertion question is answered yes/no with evidence. If routing
insertion proves infeasible on Kourier, stop and revise the plan (fallback options noted in
Idempotence and Recovery).

### Milestone 1 — The `nagare-access` enforcer service

Scope: build the real enforcer as a new Haskell package in the nagare monorepo, fully tested
in isolation (no nagare DSL/nagarectl involvement yet). At the end, `nagare-access` is a
runnable Warp service configured entirely by environment variables, with green unit and
integration tests.

What exists at the end:

- A new package directory `cli/nagare-access/` (sibling to `cli/nagare-dsl/` and
  `cli/nagarectl/`), with a cabal package `nagare-access`, an executable `nagare-access`
  (`app/Main.hs`), a library (`src/`), a test suite (`test/`), and its own `cli/nagare-access/
  cabal.project` listing `.` and `../nagare-dsl` — mirroring `cli/nagare-dsl/cabal.project`.
  (Validated: there is no repo-root `cabal.project` and no `services/` dir; `cli/` is the Haskell
  workspace root. The only in-cluster service precedent, **nagared**, is a second executable
  inside `nagarectl.cabal`; we deliberately use a *separate* package instead so the enforcer's
  auth/JWT/proxy dep closure stays out of the CLI — see the Decision Log.) Also add the new
  package to nagare's `mori.dhall` packages list, and (if the dev `flake.nix` checks should
  cover it) a `nagare-access-build-test` check mirroring `nagarectl-build-test`.
- The service reads this configuration from the environment:
  - `NAGARE_ACCESS_LISTEN` (default `:8080`),
  - `NAGARE_ACCESS_SHOMEI_URL` (e.g. `http://shomei.nagare-system.svc.cluster.local`),
  - `NAGARE_ACCESS_SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_AUDIENCE` (passed to `verifyToken`),
  - `NAGARE_ACCESS_EN_URL`,
  - `NAGARE_ACCESS_COOKIE_DOMAIN` (e.g. `.apps.example.com`),
  - `NAGARE_ACCESS_COOKIE_KEY` (a secret used to authenticate/encrypt the cookie payload if we
    wrap the token rather than store it raw; see security note below),
  - `NAGARE_ACCESS_BACKENDS` (path to the host→backend map file/ConfigMap the enforcer reads;
    JSON mapping public host → cluster-local upstream URL),
  - `NAGARE_ACCESS_DECISION_TTL` (seconds to cache an en authorization decision per
    `(subject, host)`; default 30; `0` disables caching).
- Behavior (the request handler):
  1. Read the host→backend map; if the request `Host` is not a protected host, this enforcer
     should not have received the request — return `404`/`502` with a clear message (the
     routing only sends protected hosts here).
  2. Special-case the enforcer's own endpoints under the reserved path prefix `/_nagare/`:
     `GET /_nagare/login` (render the login form, carrying the `rd` return-destination query
     param through a hidden field), `POST /_nagare/login` (validate CSRF token, call shomei
     `login`, on success set the `nagare_session` cookie and `302` to a **validated** `rd`),
     `GET /_nagare/logout` (clear cookie, `302` to login), `GET /_nagare/userinfo` (return the
     current identity as JSON — `{ "user": "<subject>", "authenticated": true }` or `401` —
     so a client-rendered SPA can ask "who am I" without parsing the opaque cookie),
     `GET /_nagare/healthz` (liveness).
  3. Otherwise: extract the token from the `nagare_session` cookie (fallback `Authorization:
     Bearer`). If missing → respond per the **content-negotiation rule** below. Verify with
     `verifyToken`. If expired and a refresh token is available, attempt shomei `refresh`,
     re-issue the cookie, and continue; if refresh fails → the content-negotiation rule. If
     invalid → the content-negotiation rule.
  4. With valid `AuthClaims`, authorize via en, but **cache the decision** to survive
     static-asset fan-out (a single page load fires dozens of asset requests; JWT verify is
     local and cheap, but an en network round-trip per asset is not). Keep a small in-process
     cache keyed by `(subject, host)` with a short TTL (default 30–60s, configurable via
     `NAGARE_ACCESS_DECISION_TTL`); on a miss call en `check` (subject `user:<claims.subject>`,
     permission `access`, object `app:<Host>`, consistency `MinimizeLatency`). A revoked grant
     therefore takes effect within one TTL — acceptable, and documented. On `Denied`/
     `Conditional` → `403` (HTML page for document requests, JSON for XHR — same rule below).
     On `Allowed` → reverse proxy to the mapped cluster-local upstream, streaming request and
     response faithfully (preserve method, path, query, body, and hop-by-hop-correct headers;
     **handle HTTP `Upgrade` for WebSockets and stream Server-Sent Events** rather than
     buffering; inject `X-Forwarded-User: <subject>` and `X-Forwarded-Host` so an SSR upstream
     that wants identity can trust them — only the enforcer can reach the cluster-local
     upstream, so these headers are trustworthy and must be **stripped from the inbound
     request** before forwarding so a client cannot spoof them).
- **Content-negotiation rule (this is what makes SPAs work).** For an unauthenticated/expired
  request the response depends on what the caller can handle:
  - A **top-level document navigation** (`Accept:` contains `text/html`, or `Sec-Fetch-Mode:
    navigate`) → `302 /_nagare/login?rd=<url-encoded original path>`.
  - An **API/XHR request** (a TanStack SPA `fetch()` — `Accept: application/json`, or
    `X-Requested-With: XMLHttpRequest`, or `Sec-Fetch-Mode: cors`/`same-origin`) → `401
    Unauthorized` with a tiny JSON body `{ "error": "unauthenticated", "login":
    "/_nagare/login?rd=..." }` and **no** redirect, so the SPA's fetch layer can detect it and
    redirect the *top-level window* to the `login` URL. Returning a `302`-to-HTML here is the
    classic failure that breaks single-page apps on token expiry; do not do it.
  This rule applies uniformly to the missing-token, failed-refresh, and invalid-token cases in
  step 3, and to the `Denied` case in step 4 (403 HTML vs 403 JSON).
- The reverse proxy: use `http-client` + `wai` (or `wai-http2-extra`/`http-reverse-proxy`
  if already a dependency in the monorepo — check `mori registry show` and existing packages
  before adding a new dep). Streaming bodies, not buffering, so large responses, SSE, and
  WebSocket upgrades work. Confirm the chosen library supports request `Upgrade`/hijack for
  WebSockets during M1; if not, add explicit upgrade handling.

Security details to implement (do not skip — these are the "cons" of Path A):

- **CSRF on `POST /_nagare/login`:** issue a `__Host-nagare_csrf` cookie + hidden form field;
  reject mismatches.
- **Open-redirect prevention:** `rd` must be a path on the same protected host (begins with a
  single `/`, no `//` or scheme). Reject and default to `/` otherwise.
- **Cookie:** `Domain=<NAGARE_ACCESS_COOKIE_DOMAIN>; HttpOnly; Secure; SameSite=Lax; Path=/`.
  Decide whether the cookie stores the raw access token or a server-authenticated wrapper
  (HMAC with `NAGARE_ACCESS_COOKIE_KEY`) that also holds the refresh token; storing the
  refresh token in an HttpOnly cookie is acceptable for a single-tenant PaaS but must be
  authenticated to prevent tampering. Record the choice in the Decision Log when made.
- **JWKS caching:** fetch shomei's JWKS once at startup and refresh periodically / on a
  verification `kid` miss (shomei rotates keys); never fetch per request.

Tests (`cli/nagare-access/test/`):

- Unit: `rd` validation (rejects `//evil.com`, `https://evil`, accepts `/foo`); cookie
  attribute construction; CSRF accept/reject.
- Integration (`tasty` + spun-up fakes or the real `shomei-server`/`en-server` via the
  project's existing test harness, e.g. `ephemeral-pg`): full 302→login→cookie→200 path, and
  the authorized-vs-unauthorized 200-vs-403 split. Mirror how shomei/en tests stand up their
  servers.

Acceptance: `cabal test all` (run from `cli/nagare-access/`) is green; running the executable
locally against the M0 shomei+en reproduces the three curl outcomes, now through the *real*
service.

### Milestone 2 — The DSL `access` binding

Scope: add the typed, opt-in `access = requireLogin` surface, modeled on the broker binding.
Pure library change, no behavior yet beyond carrying the value through render/round-trip.

What exists at the end:

- A new module `cli/nagare-dsl/src/Nagare/Dsl/Access.hs` (re-exported via the DSL's public
  module the way `Nagare.Dsl.Broker` is) defining:

  ```haskell
  -- The audience a protected site's tokens must carry, and the en permission to require.
  data AccessPolicy = AccessPolicy
    { audience   :: !(Maybe Audience)      -- Nothing = the cluster-default audience
    , permission :: !AccessPermission       -- defaults to "access"
    }
    deriving stock (Generic, Eq, Show)

  newtype Audience = Audience Text deriving stock (Generic, Eq, Ord, Show)
  newtype AccessPermission = AccessPermission Text deriving stock (Generic, Eq, Ord, Show)

  -- The one-liner the example uses; the common case.
  requireLogin :: AccessPolicy
  requireLogin = AccessPolicy { audience = Nothing, permission = AccessPermission "access" }

  mkAudience :: Text -> Either Text Audience            -- non-empty, no spaces, host-ish
  mkAccessPermission :: Text -> Either Text AccessPermission  -- non-empty, lowercase identifier
  audienceText :: Audience -> Text
  accessPermissionText :: AccessPermission -> Text
  ```

  Smart constructors follow the broker `mkXxx :: Text -> Either Text Xxx` validation idiom.

- `Deployment` (in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`) gains
  `access :: !(Maybe AccessPolicy)` with `Nothing` the backward-compatible default ("public").
- `Application` (in `cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) gains the same `access`
  field on its web service. `Worker` does **not** (decision logged).
- The renderer (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`) does **not** emit access-specific
  YAML (consistent with broker bindings, which render no standalone YAML). All access wiring
  is deploy-time (M3). The renderer changes only if it needs to surface the access intent as
  an annotation for nagarectl to read; prefer passing it through the in-memory model instead.

Tests: extend the DSL test suite (wherever broker-binding tests live, e.g.
`cli/nagare-dsl/test/`) to cover `requireLogin` round-tripping in a `Deployment` and
`Application`, and the smart-constructor rejections.

Acceptance: `cabal build nagare-dsl && cabal test nagare-dsl` green; a `Config.hs` that sets
`access = Just requireLogin` type-checks and renders the same `ksvc` YAML as before (the
binding is invisible to the renderer).

### Milestone 3 — Deploy-time wiring in `nagarectl`

Scope: make `access` actually do something at deploy time, mirroring where and how
`resolveBrokerEnv` runs. At the end, deploying a `Deployment`/`Application` whose web service
sets `access = Just requireLogin` performs three idempotent side effects and repoints the
public route to the enforcer.

What exists at the end, in `cli/nagarectl/src/Nagare/`:

- A new resolver `Nagare/Access/Resolve.hs` exposing something like:

  ```haskell
  resolveAccess :: Namespace -> Hostname -> Maybe AccessPolicy -> IO ()
  ```

  which, when given `Just policy`, performs (all idempotent):
  0. **Preflight: the auth plane must be installed (fail closed).** Because the auth plane is an
     optional, separately-bootstrapped component (decision logged), `resolveAccess` first checks
     that the enforcer is present — the `nagare-access` Service (and its DomainMapping target)
     exists in `nagare-system`. If it is **absent**, abort the deploy with an actionable error
     and make **no** changes (do not touch the backend map, do not repoint the route):

     ```text
     error: this site sets `access = requireLogin`, but the nagare auth plane is not installed.
            Install it once with the managed DB, shomei, en, and nagare-access sequence in docs/user/access.md.
            Then redeploy.
     ```

     This guarantees a protected site is never wired to a nonexistent enforcer (which would yield
     an opaque 5xx); a loud, actionable deploy failure is the fail-closed behavior.
  1. **Ensure the en `app` object is referenceable.** With en, objects are implicit until a
     tuple references them, so "ensure" may be a no-op beyond validating the schema has the
     `app` type and the requested permission; if a bootstrap/owner tuple is desired (e.g. the
     operator as owner), write it via `en-client` `writeTuples`. Do not grant any end-user
     here — granting is an operator action (see Validation).
  2. **Register the host→backend mapping** the enforcer reads: upsert `Host →
     <svc>.<ns>.svc.cluster.local` into the ConfigMap the enforcer mounts
     (`NAGARE_ACCESS_BACKENDS`). This is the map that lets one enforcer serve every protected
     host.
  3. **Repoint the public route.** For the protected hostname, the public Knative
     route/DomainMapping must target the enforcer Service instead of the app `ksvc`. Implement
     by making the app's DomainMapping/route resolve to the enforcer (which then forwards to
     the app's cluster-local address from step 2). The exact Knative mechanism (DomainMapping
     target swap vs. a dedicated route object) is settled in M0 and recorded here when known.
  - On `Nothing` (public site), `resolveAccess` ensures the host is **absent** from the
    backend map and the route points directly at the app (so flipping a site from
    private→public on redeploy cleanly reverts).

- This resolver is called from `cli/nagarectl/src/Nagare/App/Deploy.hs` alongside
  `resolveBrokerEnv`, after the `ksvc`/route is created so the cluster-local address exists.

- `nagarectl` gains operator subcommands to manage grants (thin wrappers over en
  `writeTuples`/`deleteTuples`), so an operator never has to hand-craft JSON:

  ```text
  nagarectl access grant  --host tools.apps.example.com --user alice
  nagarectl access revoke --host tools.apps.example.com --user alice
  nagarectl access list   --host tools.apps.example.com
  ```

Tests: extend the nagarectl test suite to cover `resolveAccess` producing the right ConfigMap
upsert and route target for `Just`/`Nothing`, **plus the preflight path** (enforcer-present →
wires the site; enforcer-absent → aborts with the actionable error and makes no cluster changes),
using the existing fakes/k8s test doubles that the broker resolver tests use.

Acceptance: with the auth plane installed, deploying the M5 example flips the route to the
enforcer and writes the backend map entry; with the plane absent, the same deploy fails closed
with the actionable error and leaves the route untouched; `nagarectl access grant/revoke/list`
round-trips a tuple against en.

### Milestone 4 — Cluster bootstrap

Scope: make `shomei-server`, `en-server`, and `nagare-access` bootstrappable cluster
components, the way `cluster/bootstrap/` already bootstraps `nagared`. **This whole plane is
optional** (decision logged): it is its own `kubectl apply` bundle, deliberately **not** part of
the core `just cluster-bootstrap`, so an operator who never uses `access = requireLogin` never
installs it and never runs its services/DBs. Installing it is the cluster-wide opt-in; `nagarectl`
preflights its presence per protected site (M3).

What exists at the end, under `cluster/bootstrap/`:

- **An image build+push step for the enforcer — this must be built, not reused.** Validation
  found the repo has **no** image-build pipeline: `nixos/hosts/nagare-01/registries.nix` solves
  only *pulling* private Artifact Registry images into k3s (the "private registry pull gap"),
  and nagared's image is a hardcoded URI with no Dockerfile or nix derivation in-repo. So this
  milestone must add an actual build: either a `cli/nagare-access/Dockerfile` (multi-stage cabal
  build) or a nix image derivation, producing an **`amd64`** image, plus a push to
  `${NAGARE_REGISTRY_HOST}/${NAGARE_ARTIFACT_REGISTRY_ID}/nagare-access:<tag>`. Reuse only the
  existing *pull* credentials path (`registries.nix`). Record the chosen build mechanism in the
  Decision Log when implemented. (Same gap applies if shomei/en images must be built from
  source rather than pulled from their own registries — confirm during M4.)
- `cluster/bootstrap/nagare-access/` — the enforcer **as a Knative Service (`ksvc`), not a raw
  Deployment** (decision logged): it is always-on (`min-scale: 1`, `max-scale: 1`, never
  scale-to-zero — it sits in the hot request path), exactly like nagared. The Knative shape is
  required because M3 repoints a protected host's **DomainMapping** at the enforcer, and a
  DomainMapping can only target a Knative resource. The bundle also includes the ConfigMap for
  the host→backend map and a Secret for `NAGARE_ACCESS_COOKIE_KEY`. The enforcer does **not**
  need its own dedicated public hostname: each protected host's route already points at it, and
  its login/admin endpoints are served on that same host under the reserved `/_nagare/` path
  prefix (so `/_nagare/login`, `/_nagare/healthz`, etc. are reachable on every protected host).
  Follow the **nagared bootstrap precedent**: a directory of `kubectl apply`-able manifests
  (`cluster/bootstrap/nagared/` has `rbac.yaml` + `secret.example.yaml` + `service.yaml`,
  applied by the operator), not a turnkey part of `just cluster-bootstrap`. (Fallback per
  Idempotence and Recovery: if M0 shows a `ksvc` cannot serve the routing role, use a raw
  Deployment + a dedicated route object instead — and update this decision.)
- `cluster/bootstrap/shomei/` and `cluster/bootstrap/en/` — Deployments + Services + their
  PostgreSQL wiring (reuse nagare's managed-DB story from MasterPlan 9 / the DB bindings),
  with `en` loading the `app.en` text-DSL schema from a mounted ConfigMap (via `EN_SCHEMA_PATH`),
  and `shomei` configured (`PG_CONNECTION_STRING`, issuer/audience) to match what the enforcer
  expects. Run in a dedicated `nagare-system` namespace — **which does not exist yet**; the
  current bootstrap creates only cert-manager/knative-serving/kourier-system/personal, so adding
  it (in the manifests or as a `just` recipe step) is part of this milestone.
- Bootstrap is idempotent kubectl-apply (the established pattern in `cluster/bootstrap/`, and the
  `just cluster-bootstrap` recipe in the `justfile`), safe to re-run.

Acceptance: after bootstrap, `kubectl get deploy -n nagare-system` shows `shomei` and `en` Ready
and `kubectl get ksvc -n nagare-system` shows `nagare-access` Ready; `GET
https://<any-protected-host>/_nagare/healthz` returns 200; the enforcer logs show it loaded the
backend map and fetched the JWKS. Conversely, on a cluster where the plane was **not** applied,
deploying a site with `access = requireLogin` fails closed with the actionable preflight error
(M3) and public sites are unaffected.

### Milestone 5 — End-to-end acceptance

Scope: a real protected example proving the whole chain, reproducing the Purpose transcript.

What exists at the end:

- `cluster/examples/protected-hello/nagare/Config.hs` — a `Deployment` identical to the
  existing `hello-knative-service` example but with `access = Just requireLogin` and a domain
  like `protected-hello.apps.example.com`.
- A short runbook (in the example's README and the docs) showing deploy → unauthenticated 302
  → login → 403 (no grant) → `nagarectl access grant` → 200.

Acceptance: the Purpose section's curl transcript reproduces against the live cluster, and an
ungranted vs granted user observably differ (403 vs 200). Capture the transcript into
Outcomes & Retrospective.

### Docs milestone

Add `docs/user/access.md` (or the nagare-docs equivalent — check whether user docs live in
this repo or in the sibling `nagare-docs` project before writing) covering: the `access =
requireLogin` one-liner, the SSO-across-subdomains behavior, the `nagarectl access`
grant/revoke/list commands, the security model (cookie scope, audience, en authorization),
and a pointer to the future Envoy Gateway `ext_authz` direction. Add `protected-hello` to the
examples index.


## Concrete Steps

Run everything from the nagare repo root `/Users/shinzui/Keikaku/bokuno/nagare` unless a step
says otherwise. The repo uses a Nix dev shell and direnv; ensure `direnv allow` has been run
so the target profile (`nagare.target.env`) and toolchain are loaded.

The following are the load-bearing commands; fill in exact transcripts as each milestone is
implemented (this section is updated as work proceeds).

M0 (spike), in the shomei and en repos respectively:

```bash
# shomei (/Users/shinzui/Keikaku/bokuno/shomei)
nix develop
just create-database
cabal run shomei-admin -- migrate
cabal run shomei-admin -- keys generate     # note the printed kid
cabal run shomei-admin -- keys activate <kid>
cabal run shomei-admin -- users create --loginId alice --password 'correct horse battery staple'
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" cabal run exe:shomei-server &
curl -s localhost:8080/.well-known/jwks.json | jq .   # confirm JWKS shape

# en (/Users/shinzui/Keikaku/bokuno/en)
nix develop
# app.en — en's TEXT schema DSL (parsed by en-server via parseSchema), NOT Haskell/JSON:
#   object app { relation viewer: user  permission access: viewer }
EN_DATABASE_URL="host=$PGHOST dbname=en user=$(id -un)" EN_PORT=8090 EN_SCHEMA_PATH=./app.en \
  cabal run en-server &
```

M1 build/test — there is no repo-root `cabal.project`; run inside the new package's workspace:

```bash
cd cli/nagare-access     # has its own cabal.project (. , ../nagare-dsl)
cabal build all
cabal test  all
```

M2/M3 build/test — run inside the `cli/nagarectl` workspace (its `cabal.project` lists `.` +
`../nagare-dsl`), matching the existing `nagarectl-build-test` flake check:

```bash
cd cli/nagarectl
cabal build all
cabal test  all
```

M4/M5 (nagare repo), against the configured target cluster (never another project — the
`scripts/lib/target.sh` guardrail must pass):

```bash
# bootstrap the auth plane (idempotent). The cluster-wide bootstrap entrypoint is the justfile
# recipe `just cluster-bootstrap` (NOT scripts/bootstrap-cluster.sh, which does not exist).
# The new components follow the nagared precedent: apply-able manifests plus a hand-edited
# Secret template for operator-owned secret material.
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
nagarectl db create postgres shomei-db --namespace nagare-system
nagarectl db create postgres en-db --namespace nagare-system
kubectl apply -f cluster/bootstrap/shomei/service.yaml
kubectl apply -f cluster/bootstrap/en/migrations.yaml
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
kubectl apply -f cluster/bootstrap/en/configmap.yaml
kubectl apply -f cluster/bootstrap/en/service.yaml
cp cluster/bootstrap/nagare-access/secret.example.yaml.tmpl /tmp/nagare-access-secret.yaml
# edit /tmp/nagare-access-secret.yaml: set cookie-key to a long random value
kubectl apply -f /tmp/nagare-access-secret.yaml
kubectl apply -f cluster/bootstrap/nagare-access/configmap.yaml
kubectl apply -f cluster/bootstrap/nagare-access/service.yaml

# deploy the protected example
nagarectl app deploy --config cluster/examples/protected-hello

# acceptance
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://protected-hello.apps.example.com/
nagarectl access grant --host protected-hello.apps.example.com --user alice
# log in via browser or scripted form POST, then:
curl -sS https://protected-hello.apps.example.com/ --cookie "nagare_session=<token>"
```

(Exact bootstrap entrypoint names and the deploy command flags are confirmed and pasted here
during M3/M4.)


## Validation and Acceptance

The system is correct when, against the live cluster:

1. **Public sites are unchanged.** A site without `access` (e.g. the existing
   `hello-knative-service`) still returns its content directly with no redirect. Verify:
   `curl -sS -o /dev/null -w '%{http_code}\n' https://hello.apps.example.com/` → `200`.
2. **Unauthenticated access to a protected site redirects to login.**
   `curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n'
   https://protected-hello.apps.example.com/` → `302
   https://protected-hello.apps.example.com/_nagare/login?rd=%2F`.
3. **Authenticated-but-unauthorized returns 403.** Log in as `alice` (no grant yet) and
   request the site with the resulting `nagare_session` cookie → `403` and the "no access"
   page. Evidence: paste the response status + body.
4. **Granting access flips 403 → 200.** `nagarectl access grant --host
   protected-hello.apps.example.com --user alice`, then repeat the request → `200` and the
   site body, with the upstream seeing `X-Forwarded-User: alice`.
5. **Single sign-on spans subdomains.** With the same cookie, a second protected site
   `tools.apps.example.com` (granted to alice) returns `200` without a fresh login, because
   the cookie is `Domain=.apps.example.com`.
6. **Token expiry is handled.** After the 15-minute access-token lifetime, a request
   transparently refreshes (if the refresh token is valid) and still returns `200`; a revoked
   session returns `302` to login. (Can be exercised faster by configuring a short access TTL
   in the test shomei.)
7. **SPA traffic is handled correctly.** A simulated TanStack `fetch()` to a protected site
   with an expired/absent session — `curl -H 'Accept: application/json' -H 'Sec-Fetch-Mode:
   cors' ...` — returns `401` with a JSON body carrying the `login` URL, **not** a `302` to
   HTML. The same path requested as a document — `curl -H 'Accept: text/html' ...` — returns
   `302` to `/_nagare/login`. `GET /_nagare/userinfo` returns the signed-in user as JSON (or
   `401`). Static-asset fan-out does not produce one en `check` per asset (observable in en
   server logs: a burst of asset requests yields a single check within the decision TTL).
8. **The auth plane is optional and fails closed when absent.** On a cluster where the plane was
   never applied, deploying a public site (no `access`) still succeeds and serves normally, while
   deploying a site with `access = requireLogin` aborts with the actionable preflight error
   (naming the `kubectl apply` commands) and leaves the cluster untouched — no route is repointed
   at a nonexistent enforcer. After applying the plane, the same deploy succeeds. Evidence: paste
   the failed-deploy message and the subsequent success.
9. **Tests are green.** `cabal test all` in `cli/nagare-access/` and `cabal test all` in
   `cli/nagarectl/` (covering nagare-dsl + nagarectl) all pass — including the integration test
   that stands up shomei+en and asserts the 302/403/200 progression and the 302-vs-401
   content-negotiation split, plus the M3 unit test for the enforcer-absent preflight abort.

Acceptance is behavior, not code presence: each item above is a command with an observable
result, captured into Outcomes & Retrospective with real transcripts.


## Idempotence and Recovery

- **Bootstrap** (`cluster/bootstrap/*`) is kubectl-apply and re-runnable; re-running converges
  rather than duplicating, matching the existing bootstrap components.
- **Deploy-time `resolveAccess`** is idempotent: the ConfigMap upsert and route repoint are
  declarative; redeploying the same config is a no-op. Flipping a site from private→public (or
  vice versa) on the next deploy cleanly adds/removes the backend-map entry and points the
  route at the enforcer or the app respectively, so there is no stuck intermediate state.
- **Grants** via `nagarectl access grant/revoke` are en tuple writes/deletes; writing an
  existing tuple or deleting an absent one is safe.
- **Optional plane / not-installed:** the auth plane is optional and separately bootstrapped, so
  the "not installed at all" state is normal, not an error. `nagarectl` handles it at deploy time
  via the M3 **preflight**: a public deploy proceeds unchanged; a `requireLogin` deploy aborts
  with an actionable error and changes nothing, so a protected route is never created pointing at
  a missing enforcer. Installing the plane (`kubectl apply -f cluster/bootstrap/{shomei,en,
  nagare-access}/`) and redeploying is the recovery.
- **Failure isolation:** if the enforcer, shomei, or en is down (plane *installed* but unhealthy),
  protected sites fail **closed** (the enforcer returns 5xx / redirects to a login that cannot
  complete) — they do not silently become public. Public sites are entirely unaffected because
  their routes never touch the enforcer. Verify this fail-closed property explicitly.
- **Spike fallback (M0):** if pointing a Knative route at the enforcer that forwards to a
  cluster-local `ksvc` proves infeasible on Kourier, the fallback is to give the enforcer a
  Knative-external route per protected host and have the *app* keep only a cluster-local
  address (no public DomainMapping), so the app is simply unreachable except through the
  enforcer. If even that is blocked, the larger fallback is to bring the Envoy Gateway
  migration forward and implement `ext_authz` directly (the "Future direction"); record which
  path was taken and why.
- **Rollback:** removing `access` from a config and redeploying reverts a site to public;
  deleting the `nagare-access` bootstrap removes the enforcer, at which point no route points
  at it (because public sites never did) — but any still-protected route would break, so
  rollback order is: flip all sites public (redeploy) → then remove the enforcer.


## Interfaces and Dependencies

Libraries and services this plan depends on, and the interface contracts that must hold at
each milestone's end.

From **shomei** (`/Users/shinzui/Keikaku/bokuno/shomei`):

- `shomei-jwt` — `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError
  AuthClaims)` (`shomei-jwt/src/Shomei/Jwt/Verify.hs`). The enforcer's per-request verify.
- `shomei-core` — `AuthClaims` (`shomei-core/src/Shomei/Domain/Claims.hs`): `subject ::
  UserId`, `audience`, `expiresAt`, `scopes`, `roles`. `ShomeiConfig`
  (`shomei-core/src/Shomei/Config.hs`) supplies the expected issuer/audience.
- `shomei-client` — `login :: ClientEnv -> LoginRequest -> IO (Either ClientError
  LoginResponse)`, `refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError
  TokenPairResponse)`, `shomeiClientEnv :: String -> IO ClientEnv`
  (`shomei-client/src/Shomei/Client.hs`). The login-form and refresh implementations.
- HTTP: `GET /.well-known/jwks.json`, `POST /auth/login`, `POST /auth/refresh`
  (`shomei-servant/src/Shomei/Servant/API.hs`).

From **en** (`/Users/shinzui/Keikaku/bokuno/en`):

- `en-client` — the `EnClient` record with `check :: CheckRequestWire -> ClientM
  CheckResponseWire` and `writeTuples`/`deleteTuples`/`lookup`
  (`en-client/src/En/Client.hs`), executed via `runClientM`. The enforcer's authZ; nagarectl's
  grant/revoke.
- `en-servant` — wire types `CheckRequestWire`, `CheckResponseWire`, `CheckDecisionWire`,
  `WriteTuplesRequestWire`, `TupleWire`, `ObjectRefWire`, `SubjectWire`
  (`en-servant/src/En/Servant/API.hs`).
- `en-core` — `Schema`/`Schema.Builder` (`en-core/src/En/Schema.hs`,
  `en-core/src/En/Schema/Builder.hs`) for the `app` object type shipped to `en-server` via
  `EN_SCHEMA_PATH`.
- HTTP: `POST /check`, `POST /tuples`, `DELETE /tuples`.

From **nagare** itself:

- DSL: `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (`Deployment`),
  `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` (`Application`), the new
  `cli/nagare-dsl/src/Nagare/Dsl/Access.hs` (`AccessPolicy`, `requireLogin`, `mkAudience`),
  modeled on `cli/nagare-dsl/src/Nagare/Dsl/Broker/Types.hs`.
- nagarectl: the resolve/deploy seam `cli/nagarectl/src/Nagare/Deploy/Resolve.hs` and
  `cli/nagarectl/src/Nagare/App/Deploy.hs` (where `resolveBrokerEnv` is called), plus the new
  `cli/nagarectl/src/Nagare/Access/Resolve.hs` and the `nagarectl access` subcommands.
- Cluster: `cluster/bootstrap/{nagare-access,shomei,en}/`, the new service package
  `cli/nagare-access/` (with its own `cabal.project` + an entry in `mori.dhall`), and
  `cluster/examples/protected-hello/`.

New third-party Haskell deps to evaluate before adding (check `mori` and existing monorepo
deps first to avoid duplication): a streaming reverse-proxy (`http-reverse-proxy` or a
hand-rolled `http-client`+`wai` forwarder), `wai`/`warp`, `http-client-tls`, a cookie library
(`cookie`), and a JWKS HTTP fetch (reuse whatever `shomei` uses to avoid `jose` version skew).

Contracts at milestone boundaries:

- End of M1: `nagare-access` executable runs from env config and passes its own test suite
  against a real shomei+en; the request handler implements the 302/refresh/403/200 state
  machine and streams proxied bodies.
- End of M2: `Deployment` and `Application` expose `access :: Maybe AccessPolicy`;
  `requireLogin :: AccessPolicy` and the smart constructors exist and are tested; the renderer
  output is unchanged for `Nothing`.
- End of M3: `resolveAccess :: Namespace -> Hostname -> Maybe AccessPolicy -> IO ()` is wired
  into `App/Deploy.hs`, preflights enforcer presence and fails closed when the plane is absent;
  `nagarectl access grant/revoke/list` operate against en.
- End of M4: the optional plane installs as its own bundle; the three services are bootstrapped
  and Ready in `nagare-system` (shomei/en as Deployments, `nagare-access` as a `ksvc`); the
  enforcer's health endpoint is green and it has the backend map + JWKS.
- End of M5: the Validation transcript reproduces end to end.


## Revision Notes

- 2026-06-24 — Clarified the "all-Haskell" framing and added SPA/static handling. During
  review it was (rightly) noted that the protected workloads are mostly static and TanStack
  (SSR + SPA) apps, not Haskell, making "all-Haskell" misleading. Reworked the Path A vs Path
  B comparison to state explicitly that "native Haskell" describes only the enforcer/auth
  plane and that the protected-app language mix is neutral between A and B. Added two Decision
  Log entries (language-agnostic workloads; SPA/static-aware enforcer) and folded the
  resulting requirements into Milestone 1: content-negotiated `302` (document) vs `401`+JSON
  (XHR) for unauthenticated/expired requests, en-decision caching keyed by `(subject, host)`
  with `NAGARE_ACCESS_DECISION_TTL` to absorb static-asset fan-out, WebSocket `Upgrade` and
  SSE streaming pass-through, a `GET /_nagare/userinfo` endpoint for client-rendered apps, and
  inbound-`X-Forwarded-User` stripping plus injection for SSR upstreams. Added Validation item
  7 covering the SPA content-negotiation behavior. No change to the chosen path (still Path A)
  or the topology.

- 2026-06-24 — Pre-implementation validation pass (requested: "validate before we start
  implementing"). Verified every API and path claim against the live source of shomei, en, and
  nagare via parallel exploration. **All shomei/en/nagare-DSL API signatures and the critical
  "shomei emits no Set-Cookie" assumption were confirmed accurate.** Four corrections were
  folded in across all sections: (1) **Package layout** — `services/nagare-access/` and the
  assumed repo-root `cabal.project` do not exist; the enforcer becomes a standalone
  `cli/nagare-access/` package (user-chosen over bundling into `nagarectl.cabal` à la nagared,
  to keep auth deps out of the CLI). (2) **en schema** is a text-DSL `.en` file parsed at
  runtime, not Haskell builder code or JSON; Context now shows the real syntax and marks the
  builder API reference-only. (3) **No image build/push pipeline exists** (`registries.nix`
  solves pull only; nagared's image is hardcoded with no Dockerfile/derivation) — M1/M4 must
  create one. (4) **Bootstrap entrypoint** is `just cluster-bootstrap`, not
  `scripts/bootstrap-cluster.sh`; `nagare-system` namespace is new; the nagared per-component
  `kubectl apply` directory is the precedent to mirror. Added four Decision Log entries and a
  validation summary in Surprises & Discoveries; corrected the Concrete Steps build/bootstrap
  commands (run cabal inside the per-package workspaces; no root `cabal.project`). The chosen
  path (A), topology, and DSL surface are unchanged.

- 2026-06-24 — Made deployment shape and optionality explicit (follow-up to "how is it deployed
  / is it optional"). Three changes: (1) **Optionality is now a stated guarantee, not an
  emergent one** — added a Decision Log entry establishing the auth plane (shomei + en +
  nagare-access) as an optional, separately-bootstrapped component with two independent opt-in
  levels (per-site `access` field; cluster-wide install of the bootstrap bundle, deliberately
  outside `just cluster-bootstrap`). Threaded through M4 scope, Progress, Idempotence, and a new
  Validation item 8 (public deploy succeeds / `requireLogin` deploy fails closed when the plane
  is absent). (2) **Closed the missing-plane gap** — added a Decision Log entry plus an M3 step 0
  preflight: `resolveAccess` checks the enforcer Service exists before wiring a protected site
  and, if absent, aborts the deploy with an actionable error (naming the `kubectl apply`
  commands) and makes no cluster changes, so a route is never repointed at a nonexistent
  enforcer. Added matching M3 tests/acceptance and a contract update. (3) **Pinned the
  enforcer's k8s shape** — added a Decision Log entry: the enforcer deploys as a Knative `ksvc`
  (`min-scale=1`, always-on), not a raw Deployment, because M3 repoints a host's DomainMapping
  at it and DomainMappings can only target Knative resources (mirrors nagared). This is
  contingent on the M0 routing finding (raw-Deployment + dedicated-route fallback retained); M0
  step 4 now explicitly confirms the DomainMapping→`ksvc`→cluster-local chain and writes the
  result into the M4 decision. Updated the M4 acceptance to check `kubectl get ksvc` for the
  enforcer. No change to the chosen path, the request-handling behavior, or the DSL surface.

- 2026-06-24 — Recorded M1f, the first concrete reverse-proxy forwarding slice. Added progress,
  validation evidence, and a Decision Log entry explaining why `nagare-access` now uses a
  direct `http-client`/`http-client-tls` forwarder while keeping WebSocket/SSE and large-body
  streaming in the remaining M1 scope. No change to the chosen topology or auth model.

- 2026-06-24 — Recorded M1g, runtime auth-plane environment parsing. Added progress,
  validation evidence, and a Decision Log entry explaining why direct `shomei-jwt`/`en-client`
  imports are deferred until dependency sourcing is reproducible in flake checks. No change to
  the runtime env contract already described in the plan.

- 2026-06-24 — Recorded M1h, shomei JWT verifier adapter. Added progress, validation evidence,
  and a Decision Log entry for the reproducible shomei source-repository-package pins. This
  narrows the remaining token-verification work to JWKS fetching/caching and wiring the
  executable's `AccessServices` to the adapter.

- 2026-06-24 — Recorded M1i, JWKS fetch/cache support. Added progress and validation evidence
  for the `Nagare.Access.Jwks` module and the cached shomei verifier path. Remaining
  token-verification work is now executable wiring, not another missing library boundary.

- 2026-06-24 — Recorded M1j, the en authorization adapter. Added progress, validation evidence,
  and a Decision Log entry for reproducible en source-repository-package pins and the
  `pkgs.postgresql` flake-tooling addition required by the current `en-client` dependency
  closure. No change to the authorization model: en object type remains `app`, object id remains
  the public hostname, and permission remains `access`.

- 2026-06-24 — Recorded M1k, executable runtime auth-service wiring. Added progress,
  validation evidence, and a Decision Log entry for the first fixed JWKS cache TTL. Remaining M1
  work is now focused on browser/session endpoints, refresh semantics, streaming proxy behavior,
  and real shomei+en integration tests.

- 2026-06-24 — Recorded M1l, reserved `/_nagare/userinfo` and `/_nagare/logout` endpoints.
  Added progress, validation evidence, and a Decision Log entry for carrying optional cookie
  settings through `AccessServices`. Remaining M1 browser work is now the actual login form,
  CSRF validation, shomei-client login/refresh semantics, streaming proxy behavior, and real
  shomei+en integration tests.

- 2026-06-24 — Recorded M3b, the `nagarectl access grant/revoke/list` operator commands. Split
  the old broad M3b item so this completed CLI slice is checked off while M3c keeps the
  remaining real M4 bootstrap-bundle validation open. Added validation evidence and two
  Decision Log entries: `nagarectl` uses a small raw en HTTP wrapper instead of taking the
  heavier `en-client` dependency closure, and `access list --host` uses en `expand` because
  the command starts from an object/host and needs subjects.

- 2026-06-24 — Recorded M4a, the first optional auth-plane bootstrap slice. Added
  `nagare-access` image build metadata plus `cluster/bootstrap/{shomei,en,nagare-access}/`
  apply-able templates, validation evidence, and Decision Log entries for the root-context
  Docker build and opt-in bootstrap shape. Split remaining M4 work into M4b because live
  target-cluster apply, shomei/en release images, en migrations, and M3 preflight verification
  still need real-cluster evidence.

- 2026-06-24 — Recorded M5a, the protected example artifact. Added
  `cluster/examples/protected-hello/` with a compile-checked `access = Just requireLogin`
  Deployment and a README runbook. Split live acceptance into M5b because the real 302/403/200
  transcript still depends on M4b installing the auth plane on the target cluster.

- 2026-06-24 — Recorded the docs milestone. Added `docs/user/access.md` and linked it from
  `docs/user/README.md`, covering the opt-in config field, auth-plane bootstrap, grant
  commands, request behavior, cookie/security model, protected-hello verification flow, and
  future Envoy Gateway direction. Live transcripts remain tracked under M5b.

- 2026-06-25 — Added and recorded the local-source auth-plane image builder. The repo now has a
  shared `cluster/bootstrap/auth-images/` Dockerfile/helper plus shomei/en wrappers, and
  `nagare-access` can opt into the same local-source context. The helper now also has a
  Cloud Build backend for amd64 images from non-amd64 local hosts; Cloud Build was enabled in
  `tan-nb-exp`, but the first submit failed because the active gcloud account lacks permission.
  Updated M4b Progress, Surprises & Discoveries, Decision Log, and bootstrap READMEs to reflect
  that image references are no longer purely operator-provided, while live M4b remains open
  because amd64 no-push validation exhausted the local aarch64 Colima builder, Cloud Build submit
  is blocked by IAM, and the active Kubernetes context was not the target `nagare-01` cluster.

- 2026-06-25 — Added and recorded the `k3s-import` image-builder backend for the single-node
  `nagare-01` cluster. The backend builds local-source auth-plane images on the remote amd64 node
  with Podman from Nix and imports them directly into k3s containerd under
  `dev.local/nagare-auth/<service>:<tag>` names. The first real `en` image build/import succeeded
  as `dev.local/nagare-auth/en:k3s-test`.
- 2026-06-25 — Fixed the generated local-source Cabal workspace for `shomei` images by replacing
  stale local `hs-jose` and upstream `tweag/webauthn` copies with public pins for
  `hs-jose@d00ad179`, `servant-openapi@558b7b9`, `openapi-hs@dfcd77d`, and
  `shinzui/webauthn@c274e23`. The target-node `k3s-import` run built and imported
  `dev.local/nagare-auth/shomei:k3s-test`; at that point M4b remained open for nagare-access
  image import plus workload apply, Ready verification, and real `nagarectl` preflight evidence.

- 2026-06-25 — Built and imported the `nagare-access` auth image on the target node using
  `NAGARE_ACCESS_LOCAL_SOURCES=1 NAGARE_AUTH_BUILDER=k3s-import`. The imported k3s image is
  `dev.local/nagare-auth/nagare-access:k3s-test` with digest
  `sha256:9d7cb460dd8247a1f3ec10762bc74393223f2a560d80f9da707a3020f19ddbdd`. M4b now has all
  three auth-plane images imported on `nagare-01`; remaining work is workload apply, Ready
  verification, and real `nagarectl` preflight evidence.
