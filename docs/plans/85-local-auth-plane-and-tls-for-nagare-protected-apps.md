---
id: 85
slug: local-auth-plane-and-tls-for-nagare-protected-apps
title: "Local auth plane and TLS for nagare protected apps"
kind: exec-plan
created_at: 2026-06-30T00:56:38Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
master_plan: "docs/masterplans/16-local-development-and-testing-for-nagare.md"
---

# Local auth plane and TLS for nagare protected apps

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [85-local-auth-plane-and-tls-for-nagare-protected-apps.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/85-local-auth-plane-and-tls-for-nagare-protected-apps.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

nagare can already put a web app behind a login. A site author adds one line to its typed
config — `access = requireLogin` — and after deploying, an unauthenticated browser is bounced
to a sign-in page, signs in, and is let through only if it is authorized for *that* site. The
machinery that makes this happen is the **auth plane**: three small Haskell services that run
in the cluster. **Shomei** is the identity service (it checks credentials and issues a signed
JSON Web Token — a "JWT", a compact signed string that says *who you are* and *when the proof
expires* — and it also offers a passkey/WebAuthn second factor). **en** is the authorization
service (it answers "may user *U* reach app *A*?" from relationship data). **nagare-access** is
the *forward-auth enforcer*: a reverse proxy that sits in the request path of protected sites,
verifies the Shomei JWT, asks en for a yes/no, and proxies authorized requests to the real app.
All three exist and work **on the cloud** today (see the checked-in plan
`docs/plans/81-identity-aware-access-for-nagare-sites-via-a-shared-shomei-en-forward-auth-enforcer.md`).

The problem this plan solves: **you cannot test a require-login app on your laptop today.** The
parent initiative (`docs/masterplans/16-local-development-and-testing-for-nagare.md`) introduces
a **local mode** — a second target for nagare selected by the environment variable
`NAGARE_MODE=local`, running on a [k3d](https://k3d.io/) cluster (k3s packaged inside Docker)
with a local image registry and a loopback wildcard domain such as `127-0-0-1.sslip.io` (any
name `<app>.127-0-0-1.sslip.io` resolves to `127.0.0.1` with no DNS setup). Two sibling plans
build the substrate (`docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`,
"EP-82") and the GCP-free build/deploy path in the CLI
(`docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md`, "EP-83"). This
plan, **EP-85**, makes the *auth plane* run on that local cluster so a require-login app is
fully testable with no GCP account.

After this change an operator can, entirely on their machine: build the Shomei, en, and
nagare-access images and push them to the **local** registry; install the three services with a
**local** managed Postgres for Shomei and en; trust a **local** certificate authority so the
loopback domain is reachable over HTTPS; deploy the example app
`cluster/examples/protected-hello` with `access = requireLogin`; and watch the full login
round-trip work — an unauthenticated request is challenged (HTTP 302 to the login page), a
browser completes a Shomei password+passkey login over locally-trusted HTTPS, and the
authenticated, authorized request reaches the app and returns its page. They can also run
`nagarectl access grant`, `list`, and `revoke` against the local en to manage who may reach the
app. The acceptance for this plan **is** that login round-trip on the local cluster.

The single hardest local-only requirement, and the reason this plan owns a TLS issuer, is
**WebAuthn**. WebAuthn (the browser passkey API Shomei uses for its second factor) only runs in
a browser **"secure context"** — that means HTTPS, *or* the literal host `localhost`. A loopback
*wildcard* domain like `protected-hello.personal.127-0-0-1.sslip.io` is **not** `localhost`, so
plain HTTP would make the browser refuse the passkey ceremony and block login. Therefore local
mode must serve the loopback domain over HTTPS with a certificate the developer's browser
trusts. Providing that locally-trusted certificate is **Integration Point 5** of the MasterPlan,
which this plan owns.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1a — Local-registry image naming in the auth build helper.** Added a `NAGARE_MODE=local`
  branch to `cluster/bootstrap/auth-images/build-local-image.sh` so it derives
  `image="${NAGARE_REGISTRY_HOST}/<service>:<tag>"` (no GCP project segment), pushes with a plain
  `docker push` (no `gcloud`), and defaults the build platform to `NAGARE_TARGET_PLATFORM`.
  Verified live: the running builds tag `k3d-registry.localhost:5000/<svc>:dev` on `linux/arm64`
  with no gcloud. (Done 2026-06-29.)
- [x] **M1b — Build + push the three images to the local registry.** Built `en`, `shomei`,
  `nagare-access` against the EP-82 local registry; `/v2/_catalog` (via the registry container)
  lists all three with tag `dev`. (Done 2026-06-29.)
- [x] **M2a — Local managed Postgres for Shomei and en.** `nagarectl db create postgres shomei-db
  -n nagare-system` / `... en-db -n nagare-system`; both StatefulSets `1/1` Ready, Secrets
  `nagare-db-shomei-db` / `nagare-db-en-db` present with `POSTGRES_USER`/`PASSWORD`/`DB`.
  (Done 2026-06-29.)
- [x] **M2b — Local installer + apply the auth-plane manifests.** Shipped
  `cluster/bootstrap/local-auth/install.sh` (the validated explicit path — a kustomize overlay
  can't aggregate the bases, see Surprises): applies the cloud bases, runs `en-migrate` first,
  then overrides images to the local registry, sets `NAGARE_ACCESS_COOKIE_DOMAIN=.<base>` and
  Shomei `SHOMEI_WEBAUTHN_RP_ID`/`ORIGINS`. `shomei`/`en` Deployments Ready, `nagare-access` ksvc
  Ready, `/_nagare/healthz` → 200. (Done 2026-06-29.)
- [x] **M3a — Local CA + cert-manager `ClusterIssuer`.** `cluster/bootstrap/local-tls/` bootstraps
  a self-signed `nagare-local-ca` `ca` `ClusterIssuer` (no `mkcert` needed); Ready. CA root
  exported; OS/browser trust-store install documented in `local-tls/README.md`. (Done 2026-06-29.)
- [x] **M3b — Wire Knative auto-TLS to the local issuer.** Repointed `config-certmanager`
  `issuerRef` at `nagare-local-ca`, enabled `external-domain-tls` + namespace-wildcard. The
  protected host serves a cert with subject `protected-hello.127-0-0-1.sslip.io`, issuer
  `CN=nagare-local-ca`, `SSL certificate verified`. (Done 2026-06-29.)
- [x] **M4a — Deploy `protected-hello` in local mode and observe the unauthenticated challenge.**
  Updated the example to derive its public host from `NAGARE_BASE_DOMAIN` (cloud output
  byte-identical; local → `protected-hello.127-0-0-1.sslip.io`). `curl --cacert` of the protected
  HTTPS host returns `302` → `/_nagare/login?rd=%2F`. (Done 2026-06-29.)
- [~] **M4b — Login over local HTTPS and reach the app.** Password login over the locally-trusted
  HTTPS origin succeeds (`302` with `nagare_session`/`nagare_refresh` set; the `__Host-nagare_csrf`
  round-trip is direct secure-context evidence). Authenticated-but-unauthorized → `403`; after
  `access grant`, authorized → `200`. **Remaining (interactive hand-off):** the WebAuthn *passkey*
  ceremony — registering a passkey and completing an MFA login — needs a real browser with a
  platform/virtual authenticator and the CA trusted in the OS, which cannot be driven headlessly;
  steps documented for the operator. (WebAuthn MFA only engages once an account has a passkey, so
  the no-passkey password login exercises the full enforcer path.) (Functional path done 2026-06-29.)
- [x] **M4c — Exercise `nagarectl access grant/list/revoke` against the local en.** `list` empty →
  `grant` flips the app `403`→`200` and `list` shows the user → `revoke` flips `200`→`403` and
  `list` shows none (en read-cache ~5s, enforcer decision cache ~30s observed). (Done 2026-06-29.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **macOS AirPlay Receiver shadows the local registry's host port 5000, but the
  docker daemon still reaches it.** `curl http://k3d-registry.localhost:5000/v2/_catalog`
  from the host returns `403` with `Server: AirTunes` — Control Center's AirPlay
  Receiver listens on `*:5000` (`lsof -iTCP:5000` shows `ControlCe`). The k3d
  registry container maps `0.0.0.0:5000`, but the host loopback is taken by
  AirPlay. The docker daemon runs in a Linux VM whose own loopback reaches the
  registry, so `docker pull/push k3d-registry.localhost:5000/...` works
  regardless (verified by pulling an existing EP-83 image). Implication for the
  runbook (EP-86): verify registry contents via
  `docker exec k3d-registry.localhost wget -qO- http://localhost:5000/v2/_catalog`,
  not a host-side `curl :5000`, or disable AirPlay Receiver to free port 5000.
  Date: 2026-06-29.

- **WebAuthn MFA only triggers when the account HAS a passkey, so the functional
  login flow is automatable without a browser.** `shomei-core/src/Shomei/Workflow.hs:228`
  gates MFA on `mfaRequired (webauthnConfig cfg) && passkeyCount > 0`. A user with
  no registered passkey gets a full session on password alone. This means the
  enforcer/Shomei/en functional acceptance (302 → login → 403 → grant → 200 →
  revoke → 403) can be driven entirely with `curl` over local HTTPS; only the
  passkey ceremony itself — the load-bearing proof of the TLS secure-context —
  needs a real browser with a platform/virtual authenticator (interactive).
  Date: 2026-06-29.

- **A kustomize overlay cannot aggregate the auth-plane bases — each base file
  redundantly declares `Namespace: nagare-system`.** kustomize rejects the second
  occurrence with "may not add resource with an already registered id:
  Namespace.v1/nagare-system", and the default load restrictor also forbids the
  `../` sibling-file references. Removing the namespace docs from the cloud bases
  would change the cloud apply path (forbidden by the MasterPlan). So
  `cluster/bootstrap/local-auth/` ships an idempotent `install.sh` implementing
  the plan's "validated explicit path" (apply unchanged bases, then
  `set image`/`set env`/`patch` overrides) instead of an overlay. Date: 2026-06-29.

- **The auth-plane images are full from-scratch Haskell builds with no shared
  cabal cache between them.** `Dockerfile.local-haskell` runs `cabal build` per
  image from a clean workspace, so each of `en`/`shomei`/`nagare-access`
  recompiles its entire dependency closure (Cabal, crypton, servant, and for
  shomei: jose, webauthn, servant-openapi). Wall-clock here: en ~13.5 min, shomei
  ~17.5 min, nagare-access ~15.5 min (~47 min total, sequential). EP-86's
  `just local-smoke` should reuse already-pushed `:dev` images rather than
  rebuilding. Date: 2026-06-29.

- **A protected app needs an *explicit* custom domain mapped to the enforcer, and
  the example hard-coded the cloud one — fixed by deriving it from
  `NAGARE_BASE_DOMAIN`.** `Nagare.Access.Resolve.deploymentAccessRoutes` only
  routes a host through the enforcer when the Deployment has an explicit `domains`
  entry (`ExistingDomainMapping` → a `DomainMapping` to nagare-access); the
  empty-`domains` `DefaultKnativeHost` branch creates *no* interception. The
  `protected-hello` example hard-coded `protected-hello.apps.example.com`, so in
  local mode it deployed at that unreachable cloud host (a browser can't resolve
  it, and it mismatches the loopback cookie domain / WebAuthn origin). Fix: the
  example now reads `NAGARE_BASE_DOMAIN` (via `lookupEnv`, inherited by the
  `runghc` config loader) and builds `protected-hello.<baseDomain>` — **byte-for-
  byte identical in the cloud** (`apps.example.com` default) and
  `protected-hello.127-0-0-1.sslip.io` locally (sslip resolves it to 127.0.0.1
  with no DNS setup). Knative auto-TLS issued a per-host cert for that
  DomainMapping host from `nagare-local-ca` (`SSL certificate verified`).
  Date: 2026-06-29.

- **Knative's `external-domain-tls` issues a per-host cert for an explicit
  DomainMapping host even when it is *not* under the wildcard base domain.** The
  first `apps.example.com` deploy produced a Ready `Certificate
  protected-hello.apps.example.com` in `nagare-system` signed by `nagare-local-ca`
  — so the `ca` issuer handles both the per-namespace wildcards and explicit
  DomainMapping hosts. This is why the local CA (not just DNS-01 wildcards) is the
  right fit. Date: 2026-06-29.

- **The enforcer caches authorization decisions (~30 s) and en caches tuple reads
  (~5 s), so grant/revoke effects lag.** After `access grant`, the app stayed
  `403` for ~15 s (the prior `AccessDenied` was cached for `NAGARE_ACCESS_DECISION_TTL=30`)
  then flipped to `200`; `access list` showed the new viewer only after en's
  `EN_TUPLE_READ_CACHE`/`EN_OPTIMIZED_REVISION_CACHE_TTL_MS=5000` settled. EP-86's
  smoke test must poll (not assert instantly) around grant/revoke. Date: 2026-06-29.

## Decision Log

Record every decision made while working on the plan.

- Decision: Use a **self-signed/`mkcert`-rooted local CA `ClusterIssuer`**, not Let's Encrypt, for
  local TLS.
  Rationale: The cloud path mints browser-trusted wildcard certs from Let's Encrypt via a **DNS-01**
  ACME challenge against a real Cloud DNS zone (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`),
  which EP-82's local bootstrap deliberately skips. Let's Encrypt cannot issue a certificate for
  `127-0-0-1.sslip.io`-style loopback names a laptop owns: there is no public DNS zone to delegate,
  no reachable HTTP-01 endpoint, and Let's Encrypt will not sign names that resolve to `127.0.0.1`.
  A local CA the developer trusts on their own machine sidesteps all of this and is exactly the
  "locally-trusted, not publicly valid" TLS the MasterPlan scopes (its Decision Log, 2026-06-29).
  A bonus: a private CA of kind `ca` can mint **wildcard** certs (`*.<ns>.<base>`) with no ACME
  challenge at all, whereas only DNS-01 issues wildcards on the public path — so the same Knative
  auto-TLS wiring works locally, just pointed at the local issuer.
  Date: 2026-06-30

- Decision: The auth plane is its **own** ExecPlan (EP-85), separate from the data-plane plan
  (EP-84), even though Shomei and en both need Postgres.
  Rationale: This mirrors the MasterPlan's decomposition decision. The auth plane is a distinct
  functional concern with its own images, manifests, TLS issuer, cookie-domain story, and WebAuthn
  secure-context constraint; folding it into the data plan would unbalance the plans and mix two
  unrelated verification stories. The Postgres need is modeled as a **soft** dependency on EP-84:
  the `nagarectl db create postgres` create path runs on the EP-82 cluster without EP-84, but EP-84
  is where running managed Postgres locally is verified and documented, so EP-85 benefits from it
  landing first.
  Date: 2026-06-30

- Decision: The session **cookie domain** in local mode is the **parent of the loopback base
  domain**, e.g. `.127-0-0-1.sslip.io` (leading dot), not the cloud value `.apps.example.com`.
  Rationale: The shared session cookie must be visible to every protected app under the base domain
  so a single sign-in covers all of them (the "identity-aware proxy" model). The enforcer scopes the
  cookie via `NAGARE_ACCESS_COOKIE_DOMAIN`. Locally, apps live at `<app>.<ns>.127-0-0-1.sslip.io`, so
  the parent that covers all of them is `.127-0-0-1.sslip.io`. We must verify the browser accepts this
  Domain attribute (it must not be a public suffix); `127-0-0-1.sslip.io` is a specific subdomain of
  `sslip.io`, not the registrable apex, so it should be accepted — flagged for confirmation in M4.
  Date: 2026-06-30

- Decision: In local mode, override Shomei's **WebAuthn relying-party** settings
  (`SHOMEI_WEBAUTHN_RP_ID`, `SHOMEI_WEBAUTHN_ORIGINS`) to the loopback domain.
  Rationale: WebAuthn binds a passkey to a "relying party ID" (a registrable domain suffix of the
  login origin) and validates the browser's origin against an allow-list. Shomei reads these from
  `SHOMEI_WEBAUTHN_RP_ID` and `SHOMEI_WEBAUTHN_ORIGINS`
  (`shomei-server/src/Shomei/Server/Config.hs`). The cloud values point at the public domain; left
  unchanged locally, the passkey ceremony fails with an RP-ID-hash or origin mismatch. Setting RP ID
  to `127-0-0-1.sslip.io` (a suffix of every `*.127-0-0-1.sslip.io` app origin) lets one passkey work
  across all local protected apps; origins list the exact HTTPS app origins the browser will present.
  This is *why* WebAuthn's secure-context rule drives the whole TLS requirement: the origin must be
  `https://…`.
  Date: 2026-06-30

- Decision: Add a local-mode branch to the existing `cluster/bootstrap/auth-images/build-local-image.sh`
  rather than writing a new builder.
  Rationale: That script already builds all three images from local source checkouts (it exists
  precisely because the images are built **from this repo** — `nagare-access` has a Dockerfile and
  Shomei/en enter via `source-repository-package` pins in `cli/nagare-access/cabal.project`). It just
  lacks a local-registry naming/push path; the cloud path derives an Artifact Registry image name and
  authenticates with `gcloud auth configure-docker`. A small `NAGARE_MODE=local` branch reuses all the
  build machinery and only changes the image name and the push command, matching EP-83's
  conditional-auth rule.
  Date: 2026-06-30

- Decision: Ship `cluster/bootstrap/local-auth/` as an idempotent `install.sh`, not a kustomize
  overlay.
  Rationale: A kustomize overlay cannot aggregate the cloud auth bases — every base file redundantly
  declares `Namespace: nagare-system`, which kustomize rejects as a duplicate resource id, and the
  default load restrictor forbids the `../` sibling-file references. Removing the namespace docs from
  the cloud bases would change the cloud apply path (forbidden by the MasterPlan). The plan already
  blessed an explicit `kubectl apply -f` + `set image`/`set env`/`patch` path as "the validated
  path"; `install.sh` encodes exactly that, keeping the cloud bases byte-for-byte unchanged.
  Date: 2026-06-29

- Decision: Make the `protected-hello` example derive its public domain from `NAGARE_BASE_DOMAIN`
  instead of hard-coding `protected-hello.apps.example.com`.
  Rationale: A protected app requires an explicit custom domain to be intercepted by the enforcer
  (`deploymentAccessRoutes`); the hard-coded cloud domain is unreachable in local mode and mismatches
  the loopback cookie domain / WebAuthn origin. Reading `NAGARE_BASE_DOMAIN` (inherited by the
  `runghc` config loader) makes the one example portable: identical cloud output, and a loopback host
  (`protected-hello.127-0-0-1.sslip.io`) locally that resolves to 127.0.0.1 with no DNS setup so a
  browser can complete the login. This was a necessary, in-scope adjustment the plan's M4 assumed.
  Date: 2026-06-29

- Decision: Use the cert-manager self-signed bootstrap for `nagare-local-ca` (not `mkcert`) on this
  machine; document `mkcert` as the trust-store-automation alternative.
  Rationale: `mkcert` is not installed here, and the self-signed bootstrap (selfSigned issuer → CA
  Certificate → `ca` ClusterIssuer) needs no extra tooling and produces the identical end state
  (a `ca` ClusterIssuer named `nagare-local-ca`). `mkcert`'s one advantage — automatic OS+browser
  trust-store install — is documented in `local-tls/README.md` for operators who prefer it.
  Date: 2026-06-29

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-29).** The auth plane runs end to end on the local k3d cluster with no GCP. All
four milestones landed; the full functional acceptance was demonstrated live over locally-trusted
HTTPS:

- **M1** — `build-local-image.sh` builds and pushes `en`/`shomei`/`nagare-access` to the local
  registry (`k3d-registry.localhost:5000/<svc>:dev`) with no gcloud; all three are in the catalog.
- **M2** — `shomei-db`/`en-db` managed Postgres up; `install.sh` installed the three services with
  local-registry images, the loopback cookie domain, and Shomei's WebAuthn RP/origin; `shomei`/`en`
  Ready, `nagare-access` ksvc Ready, `/_nagare/healthz` → 200.
- **M3** — `nagare-local-ca` `ca` ClusterIssuer Ready; Knative auto-TLS repointed at it; the
  protected host serves a cert chaining to the local CA (`SSL certificate verified`,
  issuer `CN=nagare-local-ca`).
- **M4** — `protected-hello` (now base-domain-derived → `protected-hello.127-0-0-1.sslip.io`)
  deployed; the progression **302 (unauthenticated) → 403 (authenticated, not a viewer) → 200
  (after `access grant`) → 403 (after `access revoke`)** was observed, with `access list`
  reflecting the viewer between grant and revoke, all over the local-CA HTTPS origin.

**The one gap — the WebAuthn passkey ceremony — is an inherent interactive hand-off, not a missing
deliverable.** WebAuthn's `navigator.credentials` ceremony needs a real browser with a platform or
CDP virtual authenticator; it cannot be driven from a shell. Crucially, the login flow *was* proven
over the locally-trusted HTTPS origin (the `__Host-nagare_session`/`__Host-nagare_csrf` cookies only
round-trip over a Secure context), which is exactly what the TLS work (M3) exists to enable — so the
secure-context requirement is demonstrably satisfied; only the authenticator gesture remains for an
operator. To complete it: trust the CA root (`local-tls/README.md`), browse to
`https://protected-hello.127-0-0-1.sslip.io/`, register a passkey for `dev@example.test`, and
complete the password+passkey MFA login. Because Shomei only demands MFA once an account *has* a
passkey, the no-passkey password path used here exercises the entire enforcer/Shomei/en chain.

**Lessons.** (1) The cloud auth bases can't be kustomized locally (duplicate `Namespace`), so an
imperative installer is the honest fit. (2) Protected apps need an explicit enforcer-mapped domain;
hard-coded example domains must become base-domain-relative to be target-portable. (3) macOS AirPlay
shadows registry port 5000 host-side but not for the docker daemon — verify registry contents
in-container. (4) The auth images are slow from-scratch Haskell builds (~47 min for all three);
reuse `:dev` tags. See Surprises & Discoveries for evidence.

