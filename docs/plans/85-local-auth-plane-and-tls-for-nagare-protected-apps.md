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

- [ ] **M1a — Local-registry image naming in the auth build helper.** Add a `NAGARE_MODE=local`
  branch to `cluster/bootstrap/auth-images/build-local-image.sh` so it derives
  `image="${NAGARE_REGISTRY_HOST}/<service>:<tag>"` (no GCP project segment) and pushes with a
  plain `docker push` instead of `gcloud auth configure-docker` + push. Mirrors EP-83's
  conditional-Docker-auth rule (MasterPlan Integration Point 2): in local mode, no gcloud.
- [ ] **M1b — Build + push the three images to the local registry.** Run the helper for
  `shomei`, `en`, and `nagare-access` against the EP-82 local registry; confirm all three image
  tags are present in the registry catalog.
- [ ] **M2a — Local managed Postgres for Shomei and en.** `nagarectl db create postgres
  shomei-db` and `... en-db` against the local cluster; confirm the StatefulSets are Ready and
  the Secrets `nagare-db-shomei-db` / `nagare-db-en-db` exist with the expected keys.
- [ ] **M2b — Local-image overlay + apply the auth-plane manifests.** Create a local overlay
  (`cluster/bootstrap/local-auth/`) that rewrites the three image refs to the local-registry
  images, sets `NAGARE_ACCESS_COOKIE_DOMAIN` to the loopback parent domain, and sets Shomei's
  `SHOMEI_WEBAUTHN_RP_ID` / `SHOMEI_WEBAUTHN_ORIGINS` to the loopback domain. Apply en's
  `en-migrate` Job, verify it completes, then apply Shomei/en/nagare-access and confirm Ready.
- [ ] **M3a — Local CA + cert-manager `ClusterIssuer`.** Create a locally-trusted CA (via
  `mkcert` or a cert-manager self-signed bootstrap), load it as a cert-manager `ca`
  `ClusterIssuer` named `nagare-local-ca`, and document installing the CA root into the OS/browser
  trust store.
- [ ] **M3b — Wire Knative auto-TLS to the local issuer.** Point `config-certmanager`'s
  `issuerRef` at `nagare-local-ca`, enable `external-domain-tls` with the namespace-wildcard
  selector, and confirm the protected host serves an HTTPS cert chaining to the local CA.
- [ ] **M4a — Deploy `protected-hello` in local mode and observe the unauthenticated challenge.**
  `curl` the protected HTTPS host with `--cacert` (or the trusted root) and observe `302` to
  `/_nagare/login`.
- [ ] **M4b — Complete a Shomei login over local HTTPS and reach the app.** Create a Shomei user,
  register a passkey, grant en access with `nagarectl access grant`, complete the browser
  password+WebAuthn login, and observe the app's page. Show the unauthenticated→302,
  authenticated-but-unauthorized→403, authorized→200 progression.
- [ ] **M4c — Exercise `nagarectl access grant/list/revoke` against the local en.** Confirm a
  grant flips 403→200 and a revoke flips 200→403, with `list` reflecting both.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of nagare. Read it before touching anything.

**What nagare deploys.** nagare turns a typed Haskell description of a web service into a
**Knative Service** (Knative is a serverless layer on the cluster; a "Knative Service", or
`ksvc`, is one deployed web app) and exposes it at a subdomain of the **base domain**. In local
mode the base domain is a loopback wildcard such as `127-0-0-1.sslip.io`, so an app named
`protected-hello` in namespace `personal` is reachable at
`protected-hello.personal.127-0-0-1.sslip.io`, which resolves to `127.0.0.1`. The CLI is
`nagarectl`; the cluster is a k3d cluster created by EP-82.

**The three auth-plane services.** All three are built **from this repository**:

- **Shomei** — the identity service. It stores users in Postgres, runs its schema migrations on
  startup (`Shomei.Server.Boot.buildEnv`), checks passwords, and issues a signed JWT access token
  (~15 min) plus a refresh token (~30 days). It publishes its public verification keys at
  `/.well-known/jwks.json` (a "JWKS" is a JSON Web Key Set — the public half of the signing keys,
  used to verify a JWT's signature). It offers a passkey/WebAuthn second factor via `/mfa/complete`.
  Its container env contract (see `cluster/bootstrap/shomei/service.yaml`) includes
  `PG_CONNECTION_STRING` (built from the managed-DB secret), `SHOMEI_ISSUER`, `SHOMEI_AUDIENCE`,
  and the WebAuthn settings `SHOMEI_WEBAUTHN_RP_ID` / `SHOMEI_WEBAUTHN_ORIGINS`. It is a plain
  Kubernetes `Deployment` + `Service` in namespace `nagare-system`, reachable in-cluster at
  `http://shomei.nagare-system.svc.cluster.local`.

- **en** — the relationship-based authorization service. It stores "relation tuples" in Postgres
  and answers authorization checks over an HTTP JSON API (`POST /tuples`, `DELETE /tuples`,
  `POST /expand`, and a check endpoint). Its authorization model is a tiny schema (mounted as the
  `en-schema` ConfigMap at `/etc/en/schema/app.en`):

  ```text
  object user {}
  object app {
    relation viewer: user
    permission access = viewer
  }
  ```

  meaning "an app has viewers; the `access` permission is granted to viewers." Granting user `U`
  access to app host `H` writes the tuple `app:<H>#viewer@user:<U>`. Unlike Shomei, **en does not
  migrate itself** — its schema must be created first by the `en-migrate` Kubernetes Job in
  `cluster/bootstrap/en/migrations.yaml`, which runs the SQL in the `en-migrations` ConfigMap
  against the en database before `en-server` starts. en is a `Deployment` + `Service` in
  `nagare-system`, reachable at `http://en.nagare-system.svc.cluster.local`. Both Shomei and en
  read their database credentials from managed-DB Secrets named `nagare-db-shomei-db` and
  `nagare-db-en-db` (keys `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`), produced by
  `nagarectl db create postgres shomei-db` / `... en-db`. (The databases are named `shomei-db` and
  `en-db`, not `shomei`/`en`, because the bare names collide with the Kubernetes Service names of
  the auth services — a collision discovered live during EP-81.)

- **nagare-access** — the forward-auth enforcer. It is a **Knative Service** in `nagare-system`
  pinned to exactly one replica (`autoscaling.knative.dev/min-scale: "1"` and `max-scale: "1"` in
  `cluster/bootstrap/nagare-access/service.yaml`). It verifies Shomei JWTs against the JWKS, asks en
  for an authorization decision, and proxies authorized requests to the real backend app. There is
  exactly **one** enforcer for the whole cluster; "which hosts require login and where they proxy
  to" lives in data — the `nagare-access-backends` ConfigMap (a host→upstream map) plus the en
  relation tuples — not in per-app sidecars. Its env contract (`service.yaml`) is:
  `NAGARE_ACCESS_SHOMEI_URL`, `NAGARE_ACCESS_SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_AUDIENCE`,
  `NAGARE_ACCESS_EN_URL`, `NAGARE_ACCESS_BACKENDS`, `NAGARE_ACCESS_COOKIE_DOMAIN`,
  `NAGARE_ACCESS_COOKIE_KEY` (HMAC key for the refresh cookie, from the `nagare-access` Secret), and
  `NAGARE_ACCESS_DECISION_TTL`.

**How a request flows when an app requires login.** When you deploy an app whose config has
`access = requireLogin`, `nagarectl`'s deploy-time resolver
(`cli/nagarectl/src/Nagare/Access/Resolve.hs`) writes the app's public host into the
`nagare-access-backends` map and routes that host's traffic to the enforcer (via a Knative
`DomainMapping` in `nagare-system`). The enforcer, on each request: looks up the host in the
backend map; if there is no valid session it returns `302` to `/_nagare/login` for browser
requests (or `401` JSON for API requests); after the user signs in, it sets a shared session
cookie scoped to the cookie domain and proxies authorized requests upstream. A logged-in user who
is *not* an en viewer of the host gets `403`.

**The fail-closed guard you must not remove.** `Nagare.Access.Resolve.resolveAccessRouteWithOps`
(around lines 122–133 of `Resolve.hs`) refuses to deploy a protected app if the enforcer is not
installed — it calls `checkEnforcerPresent` and, when absent, dies with `authPlaneMissingMessage`
(lines 99–105). This is deliberate: a require-login app must never be silently deployed wide open.
**So the auth plane must be installed before you deploy a protected app locally**, and this plan
does not weaken that guard.

**The TLS gap this plan fills.** EP-82's local bootstrap installs cert-manager, Knative Serving,
Kourier, and net-certmanager, but **skips** the DNS-01 `ClusterIssuer`
(`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) because it hard-codes a GCP project and
uses ambient GCE credentials. The Knative cert-manager bridge config
(`cluster/bootstrap/knative-serving/config-certmanager.yaml`) and the auto-TLS toggle
(`cluster/bootstrap/knative-serving/config-network-tls.yaml`) both reference that skipped issuer.
This plan **replaces** the DNS-01 issuer with a local CA issuer and repoints those configs at it —
layered *on top of* EP-82's bootstrap, never re-installing cert-manager.

**The local-target contract this plan consumes** (defined by EP-82, MasterPlan Integration Point
1; resolved in `cli/nagarectl/src/Nagare/Target.hs`): `NAGARE_MODE=local` selects local mode;
`NAGARE_REGISTRY_HOST` is the local registry (e.g. `k3d-registry.localhost:5000`);
`NAGARE_BASE_DOMAIN` is the loopback wildcard (e.g. `127-0-0-1.sslip.io`); `NAGARE_TARGET_PLATFORM`
is the host architecture for image builds (e.g. `linux/arm64` on Apple Silicon). EP-83 adds a
resolved `tpMode :: Mode` (`data Mode = Cloud | Local`) to `Nagare.Target`'s `TargetProfile`
record (MasterPlan Integration Point 2); this plan reads that mode where it needs to branch and
reuses EP-83's local-registry host derivation rather than re-deriving the mode from the
environment itself.


## Plan of Work

The work is four milestones. M1 gets the images into the local registry. M2 stands up local
Postgres and installs the services. M3 supplies the locally-trusted TLS (Integration Point 5). M4
proves the end-to-end login round-trip — the acceptance for the whole plan. M1 and M3 touch
disjoint things and could be done in either order; M2 needs M1's images, and M4 needs all three.

Throughout, assume the prerequisites are met: EP-82 has created the k3d cluster and local registry
and run the local bootstrap (cert-manager + Knative + Kourier installed, DNS-01 issuer skipped),
and EP-83 has made `nagarectl` build/push/deploy work in local mode. A `nagare.local.env` profile
exists at the repo root with at least `NAGARE_MODE=local`, `NAGARE_REGISTRY_HOST`, and
`NAGARE_BASE_DOMAIN` set, and the shell has sourced it. The example values used below are
`NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000` and `NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io`;
substitute the actual values EP-82 fixed if they differ.


### Milestone M1 — Build and push the auth-plane images to the local registry

**Scope.** Make `cluster/bootstrap/auth-images/build-local-image.sh` name and push images to the
local registry when `NAGARE_MODE=local`, then build all three. At the end, the local registry
holds `k3d-registry.localhost:5000/shomei:<tag>`, `…/en:<tag>`, and `…/nagare-access:<tag>`.

**Why a code change is needed.** The helper today derives an Artifact Registry image name
(`<registry>/<project>/<repo>/<service>:<tag>`) and, for `docker`/non-`k3s-import` builders, pushes
with `gcloud auth configure-docker` (see lines ~82–92 and ~363–366 of the script). In local mode
there is no GCP project and no gcloud; pushing must go straight to the local registry. EP-83
establishes the rule "in local mode, skip `gcloud auth configure-docker`" (MasterPlan Integration
Point 2); this milestone applies the same rule to the auth-image builder.

**Work.** In `build-local-image.sh`, in the image-name selection block, add a branch *before* the
project-based derivation: when `${NAGARE_MODE:-}` equals `local`, set
`image="${NAGARE_REGISTRY_HOST:?NAGARE_REGISTRY_HOST must be set in local mode}/${service}:${tag}"`
(no project segment). In the push block, when `NAGARE_MODE=local`, run a plain `docker push
"$image"` and **skip** `gcloud auth configure-docker`. Keep `NAGARE_CONTAINER_PLATFORM` honoring
`NAGARE_TARGET_PLATFORM` from the profile so the image matches the local node architecture (the
helper already reads `NAGARE_CONTAINER_PLATFORM`; have it default to `NAGARE_TARGET_PLATFORM` when
that is set). The build itself is unchanged: it assembles a `cabal.project` from the local
`nagare`, `shomei`, `en`, and `codd` checkouts and builds via `Dockerfile.local-haskell` (the
`nagare-access` target builds `exe:nagare-access`; `shomei` builds `exe:shomei-server` +
`exe:shomei-admin`; `en` builds `exe:en-server`). This means M1 requires the sibling source
checkouts the helper expects (`../shomei`, `../en`, the codd package dir) to be present.

**Acceptance.** All three image references resolve in the local registry's catalog (shown via the
registry's `/v2/_catalog` endpoint or `crane catalog`/`docker pull`). See Concrete Steps for the
exact commands and expected output.


### Milestone M2 — Local managed Postgres and the installed auth plane

**Scope.** Provision the two managed Postgres databases, run the en migration Job, install the
three services pointed at the local-registry images and local-mode env, and confirm all are Ready.

**Why.** Shomei and en both need Postgres. nagare already renders managed Postgres as an in-cluster
StatefulSet + Service + Secret via `nagarectl db create postgres NAME`; that create path is
cloud-agnostic and runs on the EP-82 cluster (this is the soft dependency on EP-84, which verifies
and documents managed Postgres locally). The bootstrap manifests read the Secrets
`nagare-db-shomei-db` and `nagare-db-en-db`.

**Work.**
1. `nagarectl db create postgres shomei-db` and `nagarectl db create postgres en-db` against the
   local cluster. Confirm the StatefulSets become Ready and the two Secrets exist with keys
   `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
2. Create a small local overlay directory `cluster/bootstrap/local-auth/` that takes the existing
   `cluster/bootstrap/shomei/`, `cluster/bootstrap/en/`, and `cluster/bootstrap/nagare-access/`
   manifests as bases and applies local-mode differences via a `kustomization.yaml`: rewrite the
   three container images to the local-registry refs; set `NAGARE_ACCESS_COOKIE_DOMAIN` to
   `.127-0-0-1.sslip.io` (the loopback parent — see Decision Log); add `SHOMEI_WEBAUTHN_RP_ID:
   127-0-0-1.sslip.io` and `SHOMEI_WEBAUTHN_ORIGINS:
   https://protected-hello.personal.127-0-0-1.sslip.io` to the Shomei Deployment. (If kustomize's
   built-in image transformer does not reach the Knative `Service`'s container, fall back to the
   explicit `kubectl set image` / `kubectl patch ksvc` commands in Concrete Steps — those are the
   validated path; the overlay is a convenience.)
3. Apply the `en-migrate` Job (`cluster/bootstrap/en/migrations.yaml`) **first** and wait for it to
   complete; it creates the `relation_tuple` schema and is a no-op on reruns (it self-checks for
   `public.relation_tuple`). Shomei needs no separate migration Job — it migrates on startup.
4. Apply the Shomei, en, and nagare-access manifests through the overlay (plus the `en-schema`
   ConfigMap, the empty `nagare-access-backends` ConfigMap, and a real `nagare-access` cookie-key
   Secret). Confirm the `shomei` and `en` Deployments are Ready and the `nagare-access` ksvc is
   Ready.

**Acceptance.** `kubectl -n nagare-system get deploy shomei en` shows both Ready; `kubectl -n
nagare-system get ksvc nagare-access` shows Ready; `GET /_nagare/healthz` through the enforcer
returns 200.


### Milestone M3 — Local TLS issuer (Integration Point 5)

**Scope.** Stand up a locally-trusted CA, install it as a cert-manager `ca` `ClusterIssuer` named
`nagare-local-ca`, install the CA root into the developer's trust store, and repoint Knative's
auto-TLS at the local issuer so the loopback domain serves HTTPS the browser trusts. This is what
makes WebAuthn's secure-context requirement satisfiable.

**Two ways to get the CA, with a clear tradeoff.**

- **`mkcert` (recommended).** [`mkcert`](https://github.com/FiloSottile/mkcert) is a one-binary tool
  that creates a local CA and, crucially, **installs it into the OS and browser trust stores for
  you** (`mkcert -install`), including the separate NSS store that Firefox and Chrome use on Linux.
  You then feed mkcert's `rootCA.pem` and `rootCA-key.pem` (found under `$(mkcert -CAROOT)`) into a
  cert-manager CA issuer secret. Tradeoff: it requires installing `mkcert`, and the CA **private
  key** leaves mkcert's CAROOT to live in a cluster Secret — acceptable for a throwaway local CA on
  your own machine, never for anything shared. The big win is automatic, cross-browser trust-store
  installation, which is fiddly to do by hand.

- **cert-manager self-signed bootstrap (no extra tool).** cert-manager can bootstrap its own CA: a
  `selfSigned` `ClusterIssuer` issues one self-signed **CA `Certificate`** (with `isCA: true`),
  whose key/cert land in a Secret, and a second `ca` `ClusterIssuer` references that Secret to sign
  leaf certs. Tradeoff: you must **manually** export the CA cert from the Secret and import it into
  every trust store you care about (OS keychain plus, on some platforms, the browser's own NSS
  store), which is exactly the chore mkcert automates. Choose this only if installing mkcert is
  undesirable.

Either way the end state is identical: a cert-manager `ClusterIssuer` named `nagare-local-ca` of
kind `ca`, backed by a Secret holding the CA cert+key, with the CA root trusted on the developer's
machine. A `ca` issuer can mint **wildcard** certs without any ACME challenge, so per-namespace
wildcard auto-TLS (`*.<ns>.<base>`) works locally.

**Work.**
1. Create the CA (mkcert or self-signed bootstrap) and load it as `nagare-local-ca`.
2. Install the CA root into the OS/browser trust store (`mkcert -install`, or manual import).
3. Patch `config-certmanager` so Knative's bridge issues from `nagare-local-ca` instead of
   `letsencrypt-dns`, and patch `config-network` to enable `external-domain-tls` with the
   namespace-wildcard selector (the bodies in
   `cluster/bootstrap/knative-serving/config-certmanager.yaml` and `…/config-network-tls.yaml`,
   with the `issuerRef` name changed to `nagare-local-ca`).
4. Trigger a cert for the protected namespace (deploying the app in M4 does this) and confirm the
   served cert chains to the local CA.

**Acceptance.** `curl -v https://protected-hello.personal.127-0-0-1.sslip.io/` (with the local CA
trusted, or `--cacert` pointing at the CA root) completes the TLS handshake with **no** certificate
warning, and the served chain's issuer is the local CA.


### Milestone M4 — End-to-end: a require-login app, logged into over local HTTPS

**Scope.** Deploy `cluster/examples/protected-hello` with `access = requireLogin` in local mode and
demonstrate the full progression: unauthenticated → `302` challenge; authenticated-but-unauthorized
→ `403`; authorized → `200` with the app body. Exercise `nagarectl access grant/list/revoke`
against the local en. This is the plan's acceptance.

**Why this is the proof.** It strings together every piece: the local images (M1), the local
Postgres + installed services (M2), the locally-trusted HTTPS that lets WebAuthn run (M3), the
fail-closed deploy resolver, the Shomei login + passkey ceremony, the en authorization decision,
and the enforcer's proxy to the app.

**Work.**
1. Create a Shomei user (via `shomei-admin` in the Shomei pod, or Shomei's signup endpoint) and
   register a passkey for it through the browser login flow. Note the user's Shomei id.
2. `nagarectl deploy` the `protected-hello` example in local mode. The deploy resolver verifies the
   enforcer is present (the guard from `Resolve.hs`), writes the host into the backend map, and
   routes the host to the enforcer.
3. Observe the unauthenticated `curl` returns `302 Location: …/_nagare/login?rd=%2F`.
4. In a browser, complete the Shomei login over `https://…` — password then the WebAuthn passkey
   prompt (which only works because the origin is locally-trusted HTTPS). Before granting en access,
   the authenticated request returns `403`.
5. `nagarectl access grant --host protected-hello.personal.127-0-0-1.sslip.io --user <shomei-id>`
   against the local en (resolved via `--en-url` or `NAGARE_EN_URL`). Reload: the app now returns
   `200` and its page body.
6. `nagarectl access list --host …` shows the user; `nagarectl access revoke --host … --user …`
   flips the app back to `403`.

**Acceptance.** The three-state progression (302 / 403 / 200) is observed, with the browser
completing a real password+WebAuthn login over locally-trusted HTTPS, and grant/revoke flip the
authorized state. Capture the transcript in Concrete Steps and the Validation section.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` with the local
profile sourced, unless a different working directory is shown. Substitute your EP-82 values for
`NAGARE_REGISTRY_HOST` / `NAGARE_BASE_DOMAIN` if they differ from the examples.

```bash
# Confirm local mode is active (set by nagare.local.env / .envrc per EP-82).
echo "mode=$NAGARE_MODE registry=$NAGARE_REGISTRY_HOST base=$NAGARE_BASE_DOMAIN platform=$NAGARE_TARGET_PLATFORM"
# expect: mode=local registry=k3d-registry.localhost:5000 base=127-0-0-1.sslip.io platform=linux/arm64
```

### M1 — build + push images

```bash
# After adding the NAGARE_MODE=local branch to build-local-image.sh:
export NAGARE_AUTH_LOCAL_SOURCES=1       # build from local shomei/en checkouts
export NAGARE_CONTAINER_PLATFORM="$NAGARE_TARGET_PLATFORM"
for svc in shomei en nagare-access; do
  cluster/bootstrap/auth-images/build-local-image.sh "$svc" dev
done
# expect each run to end by printing the pushed image, e.g.:
#   k3d-registry.localhost:5000/shomei:dev
#   k3d-registry.localhost:5000/en:dev
#   k3d-registry.localhost:5000/nagare-access:dev
```

```bash
# Confirm the registry holds all three:
curl -s http://k3d-registry.localhost:5000/v2/_catalog
# expect (order may vary):
# {"repositories":["en","nagare-access","shomei"]}
```

### M2 — local Postgres + install

```bash
nagarectl db create postgres shomei-db
nagarectl db create postgres en-db
kubectl -n nagare-system get statefulset shomei-db en-db
# expect both READY 1/1 after a short wait
kubectl -n nagare-system get secret nagare-db-shomei-db nagare-db-en-db \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.data.POSTGRES_DB}{"\n"}{end}'
# expect each secret listed with a (base64) POSTGRES_DB value
```

```bash
# Apply en's schema + migration Job FIRST, then wait for completion:
kubectl apply -f cluster/bootstrap/en/configmap.yaml
kubectl apply -f cluster/bootstrap/en/migrations.yaml
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
# expect: job.batch/en-migrate condition met
```

```bash
# Install the three services with local-registry images + local env. Using the
# local-auth overlay (preferred):
kubectl apply -k cluster/bootstrap/local-auth/
# OR, the explicit validated path if the overlay's image transform misses the ksvc:
kubectl apply -f cluster/bootstrap/shomei/ -f cluster/bootstrap/en/ -f cluster/bootstrap/nagare-access/
kubectl -n nagare-system set image deployment/shomei shomei=k3d-registry.localhost:5000/shomei:dev
kubectl -n nagare-system set image deployment/en      en=k3d-registry.localhost:5000/en:dev
kubectl -n nagare-system patch ksvc nagare-access --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"k3d-registry.localhost:5000/nagare-access:dev"}]'
# Local-mode env overrides (cookie domain + WebAuthn RP/origins):
kubectl -n nagare-system set env deployment/shomei \
  SHOMEI_WEBAUTHN_RP_ID=127-0-0-1.sslip.io \
  SHOMEI_WEBAUTHN_ORIGINS=https://protected-hello.personal.127-0-0-1.sslip.io
kubectl -n nagare-system patch ksvc nagare-access --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/<COOKIE_DOMAIN_INDEX>/value","value":".127-0-0-1.sslip.io"}]'
```

```bash
kubectl -n nagare-system rollout status deploy/shomei deploy/en
kubectl -n nagare-system get ksvc nagare-access
# expect shomei/en rollouts complete and nagare-access READY=True
```

### M3 — local CA issuer + Knative auto-TLS

```bash
# Option A: mkcert (auto trust-store install).
mkcert -install
CAROOT="$(mkcert -CAROOT)"
kubectl -n cert-manager create secret tls nagare-local-ca \
  --cert="$CAROOT/rootCA.pem" --key="$CAROOT/rootCA-key.pem"
cat <<'YAML' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: nagare-local-ca
spec:
  ca:
    secretName: nagare-local-ca
YAML
```

```bash
# Repoint Knative's cert-manager bridge at the local issuer and enable auto-TLS.
kubectl -n knative-serving patch configmap config-certmanager --type merge \
  --patch 'data:
  issuerRef: |
    kind: ClusterIssuer
    name: nagare-local-ca'
kubectl -n knative-serving patch configmap config-network --type merge \
  --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
```

```bash
# Verify the served cert chains to the local CA (after M4 deploy triggers issuance):
curl -v https://protected-hello.personal.127-0-0-1.sslip.io/ 2>&1 | grep -E 'issuer:|SSL certificate verify'
# expect issuer to be the mkcert/local CA and no verify failure
```

### M4 — end-to-end login round-trip

```bash
# Create a Shomei user (admin path inside the pod):
kubectl -n nagare-system exec deploy/shomei -- shomei-admin user create --email dev@example.test --password 'correct horse'
# note the printed user id, e.g. user_01kw...

nagarectl deploy --config cluster/examples/protected-hello/nagare/Config.hs
# deploy resolver confirms the enforcer is present, writes the backend map, routes the host.

# 1) Unauthenticated -> 302 challenge:
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://protected-hello.personal.127-0-0-1.sslip.io/
# expect: 302 https://protected-hello.personal.127-0-0-1.sslip.io/_nagare/login?rd=%2F
```

Then, in a browser pointed at `https://protected-hello.personal.127-0-0-1.sslip.io/`: the page
redirects to `/_nagare/login`; enter the email + password; Shomei returns `mfa_required` and the
page renders a passkey challenge that calls `navigator.credentials.get()` — the browser shows the
platform passkey prompt (this only appears because the origin is locally-trusted HTTPS; over plain
HTTP the browser refuses with a secure-context error). Complete the passkey; the enforcer sets the
`nagare_session` cookie and redirects back to `/`.

```bash
# 2) Authenticated but NOT yet an en viewer -> 403. Grant access, then 200:
nagarectl access list --host protected-hello.personal.127-0-0-1.sslip.io --en-url http://localhost:8090
# expect: (no users) before granting

nagarectl access grant --host protected-hello.personal.127-0-0-1.sslip.io --user user_01kw... --en-url http://localhost:8090
# expect: granted app:protected-hello.personal.127-0-0-1.sslip.io#viewer@user:user_01kw...

# Reload the app in the browser (or replay the session cookie): now 200 with the app body.
nagarectl access revoke --host protected-hello.personal.127-0-0-1.sslip.io --user user_01kw... --en-url http://localhost:8090
# expect: revoked ...  -> the app returns 403 again
```

(`--en-url http://localhost:8090` assumes a `kubectl port-forward svc/en 8090:80 -n nagare-system`
to reach the in-cluster en from the host; alternatively set `NAGARE_EN_URL`.)

### Commit conventions

Commit directly to the current branch (no feature branch unless asked), using Conventional Commit
subjects and the MasterPlan trailers. Example:

```text
feat(access): build and install the auth plane in local mode

Add a NAGARE_MODE=local branch to the auth-image build helper, a
local-auth overlay, and a local CA ClusterIssuer so a require-login app
is testable on the k3d cluster.

MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md
ExecPlan: docs/plans/85-local-auth-plane-and-tls-for-nagare-protected-apps.md
Intention: intention_01kwb012h6ebgs5qjn5r12nyda
```

Use scopes like `feat(access)`, `fix(access)`, `chore(access)`, or `docs(access)` as appropriate,
matching the recent history (`a6cf1bf fix(access): complete live auth plane routing`,
`8d9713a feat(access): add cloud auth image builds`).


## Validation and Acceptance

The plan is accepted when, on a laptop with no GCP account, the following are all true.

1. **Images present locally.** `curl -s http://k3d-registry.localhost:5000/v2/_catalog` lists
   `en`, `nagare-access`, and `shomei`.

2. **Services Ready.** `kubectl -n nagare-system get deploy shomei en` shows both Ready;
   `kubectl -n nagare-system get ksvc nagare-access` shows `READY=True`; the `en-migrate` Job
   reports `complete`.

3. **Locally-trusted HTTPS.** `curl -v https://protected-hello.personal.127-0-0-1.sslip.io/`
   completes the TLS handshake with no certificate warning when the local CA is trusted, and the
   served certificate's issuer is the local CA.

4. **The login round-trip (the acceptance).** With `protected-hello` deployed
   (`access = requireLogin`):
   - an unauthenticated request returns `302` to `/_nagare/login`;
   - a browser completes a Shomei **password + WebAuthn passkey** login over the locally-trusted
     HTTPS origin and is redirected back;
   - before an en grant, the authenticated request returns `403`;
   - after `nagarectl access grant`, the same request returns `200` with the app body;
   - after `nagarectl access revoke`, it returns `403` again; `nagarectl access list` reflects the
     viewer before revoke and not after.

   The WebAuthn step is the load-bearing demonstration that the local TLS (M3) is doing its job: on
   plain HTTP the browser refuses the passkey ceremony with a secure-context error, so observing a
   *successful* passkey prompt is direct evidence the secure-context requirement is met.

No new automated unit tests are required by this plan — the enforcer/Shomei/en code already carries
the EP-81 test suite, and this plan's deliverables are bootstrap/build/TLS wiring whose correctness
is the live round-trip above. If `build-local-image.sh` gains non-trivial shell logic, add a small
shell assertion (e.g. that local mode never emits a `gcloud` invocation) to keep the
no-gcloud-in-local-mode guarantee honest.


## Idempotence and Recovery

- **Image builds (M1)** are repeatable: rebuilding overwrites the `<service>:dev` tag in the local
  registry. To force a fresh pull after a rebuild, restart the workloads
  (`kubectl -n nagare-system rollout restart deploy/shomei deploy/en` and re-patch the ksvc image to
  cut a new revision); the enforcer reloads its mounted backend map on revision restart.
- **`nagarectl db create postgres` (M2)** is safe to re-run: an existing database is left in place.
  The **`en-migrate` Job** self-checks for `public.relation_tuple` and exits 0 if the schema already
  exists, so re-applying it is a no-op. A Job object cannot be re-applied with changes once it has
  run; to rerun it after editing, delete it first (`kubectl -n nagare-system delete job en-migrate`)
  and re-apply.
- **Manifest applies (M2)** are declarative `kubectl apply` and converge on re-run. Re-running
  `set image` / `set env` / `patch` is idempotent (no-op when the value already matches).
- **The CA issuer (M3)** is idempotent: re-applying the `ClusterIssuer` is a no-op; recreating the
  `nagare-local-ca` Secret requires deleting it first. `mkcert -install` is safe to run repeatedly.
  **Recovery from a broken cert:** delete the per-namespace `Certificate`/Secret Knative created and
  let cert-manager re-issue from `nagare-local-ca`.
- **Teardown.** The auth plane is removed by deleting the `nagare-system` Deployments/ksvc and the
  two managed databases (`nagarectl db delete postgres shomei-db en-db`). The local CA is removed by
  `mkcert -uninstall` (or removing the imported root) plus deleting the `nagare-local-ca` Secret and
  `ClusterIssuer`. None of this touches the cloud path.
- **Guard safety.** Do not disable the fail-closed enforcer check in `Resolve.hs`. If a protected
  deploy fails with the "auth plane is not installed" message, the fix is to finish M2 (install the
  plane), never to bypass the guard.


## Interfaces and Dependencies

**Consumes (hard dependencies).**

- **EP-82** (`docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`): the
  k3d cluster, the local registry (`NAGARE_REGISTRY_HOST`), the loopback base domain
  (`NAGARE_BASE_DOMAIN`), and the local bootstrap that installs cert-manager + Knative + Kourier +
  net-certmanager while **skipping** `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`. This
  plan layers the auth-plane manifests and the local TLS issuer **on top** of that bootstrap
  (MasterPlan Integration Points 4 and 5) — it must not re-install cert-manager.
- **EP-83** (`docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md`): the
  resolved `tpMode :: Mode` (`data Mode = Cloud | Local`) on `Nagare.Target.TargetProfile` and the
  conditional-Docker-auth rule (MasterPlan Integration Point 2). This plan applies the same
  "no-gcloud-in-local-mode" rule to the auth-image build helper and reuses the local-registry host
  derivation rather than re-deriving the mode from the environment.

**Consumes (soft dependency).**

- **EP-84** (`docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md`):
  the managed-Postgres create path verified locally. Shomei and en need Postgres; the
  `nagarectl db create postgres` create path runs on the EP-82 cluster without EP-84, so the
  dependency is soft, but EP-84 documents running managed Postgres locally.

**Owns (Integration Point 5).** The local TLS issuer: a cert-manager `ClusterIssuer` named
`nagare-local-ca` (kind `ca`, backed by a Secret of the local CA cert+key), with the CA root trusted
on the developer's machine, replacing the skipped DNS-01 issuer. Knative's `config-certmanager`
`issuerRef` and `config-network` auto-TLS toggle are repointed at it.

**Files and manifests this plan touches or creates.**

- `cluster/bootstrap/auth-images/build-local-image.sh` — add the `NAGARE_MODE=local` image-naming
  and plain-`docker push` branch (no gcloud).
- `cluster/bootstrap/local-auth/` (new) — a kustomize overlay over `cluster/bootstrap/shomei/`,
  `cluster/bootstrap/en/`, and `cluster/bootstrap/nagare-access/` that rewrites images to the local
  registry and applies the local-mode env (`NAGARE_ACCESS_COOKIE_DOMAIN=.127-0-0-1.sslip.io`,
  `SHOMEI_WEBAUTHN_RP_ID=127-0-0-1.sslip.io`, `SHOMEI_WEBAUTHN_ORIGINS=https://<app-origin>`).
- A local CA `ClusterIssuer` (`nagare-local-ca`) and the `config-certmanager` / `config-network-tls`
  patches in `cluster/bootstrap/knative-serving/`.

**Environment variables read by the installed services** (unchanged shapes; local-mode *values*
differ):

- Shomei (`cluster/bootstrap/shomei/service.yaml`): `PG_CONNECTION_STRING` (from
  `nagare-db-shomei-db`), `SHOMEI_ISSUER`, `SHOMEI_AUDIENCE`, plus local-mode
  `SHOMEI_WEBAUTHN_RP_ID` and `SHOMEI_WEBAUTHN_ORIGINS`
  (`shomei-server/src/Shomei/Server/Config.hs`).
- en (`cluster/bootstrap/en/service.yaml`): `EN_DATABASE_URL` (from `nagare-db-en-db`), `EN_PORT`,
  `EN_SCHEMA_PATH=/etc/en/schema/app.en`; schema mounted from the `en-schema` ConfigMap; migrations
  run by the `en-migrate` Job in `cluster/bootstrap/en/migrations.yaml`.
- nagare-access (`cluster/bootstrap/nagare-access/service.yaml`): `NAGARE_ACCESS_SHOMEI_URL`,
  `NAGARE_ACCESS_SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_AUDIENCE`, `NAGARE_ACCESS_EN_URL`,
  `NAGARE_ACCESS_BACKENDS`, `NAGARE_ACCESS_COOKIE_DOMAIN` (local: `.127-0-0-1.sslip.io`),
  `NAGARE_ACCESS_COOKIE_KEY` (from the `nagare-access` Secret), `NAGARE_ACCESS_DECISION_TTL`.

**CLI surface used.** `nagarectl db create postgres NAME`; `nagarectl deploy`; `nagarectl access
grant|list|revoke --host HOST --user USER [--en-url URL]`
(`cli/nagarectl/src/Nagare/Access/Grants.hs`, which speaks en's `POST/DELETE /tuples` and
`POST /expand` and resolves the en URL from `--en-url` then `NAGARE_EN_URL`). The deploy-time
resolver `cli/nagarectl/src/Nagare/Access/Resolve.hs` enforces the fail-closed "auth plane present"
check and writes the backend map / routes the host — this plan relies on it unchanged.
