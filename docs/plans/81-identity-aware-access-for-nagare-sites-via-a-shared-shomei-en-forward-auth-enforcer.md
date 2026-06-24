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
- [ ] **M1 remaining — real `nagare-access` enforcer behavior.** Token verify via
  `shomei-jwt`, login flow via `shomei-client`, session-cookie parsing/refresh semantics, en
  authZ via `en-client`, JWKS caching, decision caching, reverse-proxy forwarding,
  WebSocket/SSE handling, and integration tests against shomei+en.
- [x] **M2 — DSL `access` binding.** Completed 2026-06-24. New `AccessPolicy` type + `requireLogin` /
  `mkAudience` smart constructors; `access :: Maybe AccessPolicy` field on `Deployment` and
  on the `Application` web service. Render/round-trip tests green.
- [ ] **M3 — Deploy-time wiring in `nagarectl`.** Resolve the `access` binding: preflight that
  the auth plane is installed (fail closed with an actionable error if not), ensure the en
  "app" object for the hostname exists, register the host→backend mapping the enforcer reads,
  and repoint the public route to the enforcer. Inject enforcer config.
- [ ] **M4 — Cluster bootstrap (optional, opt-in plane).** Build+push the enforcer image (no
  existing pipeline — must be created), then idempotent bootstrap of `shomei-server`,
  `en-server`, and the `nagare-access` enforcer (a Knative `ksvc`, `min-scale=1`; + internal
  Service + ConfigMap + Secret) in a new `nagare-system` namespace, plus JWKS / DB / cookie-key
  secrets. Its own `kubectl apply` bundle, NOT part of `just cluster-bootstrap`, following the
  nagared precedent.
- [ ] **M5 — End-to-end acceptance.** `cluster/examples/protected-hello` deploys; the curl
  transcript in Purpose reproduces; an authorized vs unauthorized user differ as specified.
- [ ] **Docs.** A user guide `docs/user/access.md` (or the nagare-docs equivalent) plus an
  entry in the example index.


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
  if not, the deploy aborts with a message naming the fix (`access=requireLogin requires the auth
  plane — run: kubectl apply -f cluster/bootstrap/nagare-access/`) and the route is **not**
  repointed. Without this, M3 would silently repoint a host's route at a nonexistent enforcer
  Service and break the site with an opaque 5xx.
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
            Install it once with:
              kubectl apply -f cluster/bootstrap/shomei/
              kubectl apply -f cluster/bootstrap/en/
              kubectl apply -f cluster/bootstrap/nagare-access/
            Then redeploy. (See docs/user/access.md.)
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
# The new components follow the nagared precedent — a directory of kubectl-apply manifests
# applied by the operator:
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cluster/bootstrap/shomei/
kubectl apply -f cluster/bootstrap/en/
kubectl apply -f cluster/bootstrap/nagare-access/

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
