---
id: 198
slug: run-the-admin-api-in-each-context-behind-an-admin-grant
title: "Run the admin API in each context behind an admin grant"
kind: exec-plan
created_at: 2026-10-14T17:49:39Z
master_plan: "docs/masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-14T17:49:39Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T00:19:10Z
      mode: "update"
      note: "MasterPlan 28 design review for the admin UI and Kotei: one recorded-state reader, admin.<base> origin, service-account bearer, Deployment+NetworkPolicy, gateway problem documents, ETag/head summary"
---

# Run the admin API in each context behind an admin grant

Child of [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md).
Progress holds the deliverables with pass/fail evidence; the Decision Log holds dated decisions.


## Purpose / Big Picture

After this plan, a context converged on the release that carries it runs `nagare-api-server`
(from [EP-197](197-serve-the-read-documents-through-a-typed-servant-admin-api.md)) in
`nagare-system`, at the protected hostname `admin.<base domain>`. A person signs in through
the context's existing portal; if the operator has granted them access to that hostname with an
ordinary reviewed `nagarectl access grant`, their browser can read
`https://admin.<base domain>/v1/...`. A machine client (Kotei) presents a Shomei service
account's access token as `Authorization: Bearer` and is granted on the hostname the same way.
Anyone else gets the gateway's challenge or 403, as a problem document when the request is
JSON-shaped, exactly as for any protected site. The gateway is the only network path to the
server: an in-cluster pod that is not `nagare-access` cannot connect to it. The server reads the
context's GCS inventory store with the read-only credential from
[EP-196](196-read-the-inventory-store-from-an-in-cluster-service-identity.md). The path `/` on the
hostname is reserved for the admin UI, which a later plan serves from the same image and origin.

The requirement this moves (operator, 2026-10-10): the operator can see the state of what they
change and upgrade, without running the CLI.


## Progress

- [ ] M1. The image, the platform scope and the gateway's problem documents, offline. Pass: a
  Dockerfile and build script for `nagare-api-server` beside the `nagare-access` ones; a new
  platform scope `admin-api` whose members are a Deployment (one replica, the same pod security
  context as `nagare-access`, readiness on `/health/ready`), a ClusterIP Service `admin-api`, a
  NetworkPolicy admitting ingress only from the `nagare-access` pods and egress only to DNS, the
  store (the GCS endpoint and the metadata server under EP-196's option 1) and the OTLP collector,
  its configuration (context name, store source, OTLP endpoint) and its backend-map contribution
  for the protected hostname; the scope added to the release transition table
  (`cli/nagarectl/src/Nagare/Platform/Transition.hs`) so an existing context gains it through
  `platform transition`; interpreter tests that plan the scope on a fixture context, and a model
  scenario that adds it through a transition. In `cli/nagare-access`: `nagare-contract` added to
  its `cabal.project` and Dockerfile; the JSON-shape classifier accepts any `+json` `Accept`; the
  401, 403 and 503 answers to a JSON-shaped request are `application/problem+json` from the
  catalog (`unauthenticated`, `forbidden`, `authorization_unavailable` with `retryable: true`),
  with the existing `error` and `login` members kept as extension members, under tests that pin
  the body and media type. Gates green, landed.
- [ ] M2. Local native run (disposable local context, per ADR 25). Pass: the scope converges, an
  unchanged replan has zero operations, `/health/ready` is 200; a user granted the hostname reads
  `/v1/inventory/scopes` and gets the context's scopes; an ungranted signed-in user gets 403 as a
  problem document when the request is JSON-shaped and the portal page otherwise; an
  unauthenticated `Accept: application/json` request gets a 401 problem document, not a redirect;
  a Shomei service account's bearer token, granted on the hostname, reads `/v1/platform/version`,
  and ungranted gets 403; and a pod in an application namespace cannot connect to
  `admin-api.nagare-system.svc.cluster.local` (connection refused or timed out, recorded). The
  local context's store is a local directory, so the server reads it through the M1 decision
  recorded below.
- [ ] M3. The intranet. Pass: after the release that carries this plan, the intranet upgrade
  through `platform transition` adds the scope and applies EP-196's grant; the operator grants
  themselves the hostname; the operator's signed-in browser reads `/v1/platform/version` and
  `/v1/inventory/scopes`, and the deploy-and-login check still passes. Cloud mutations here follow
  the operator's go-ahead rule.


## Decision Log

- 2026-10-14: The API is its own platform scope, `admin-api`, not a member of `auth`. It has its own
  image, credential and failure modes; retiring or upgrading it must not touch the login path.
- 2026-10-14 (revised in the MasterPlan 28 review): The API is a plain Deployment and ClusterIP
  Service with a NetworkPolicy, not a Knative Service. The service makes no access decision
  (EP-197), so the gateway must be its only path, and only a pod selector can pin that: a
  cluster-local Knative route is reachable from every pod through the shared ingress and
  activator, so "reachable only through `nagare-access`" was not true of the first draft. The
  precedent is the nix cache (`cluster/bootstrap/nix-cache/workloads.yaml.tmpl` and
  `networkpolicies.yaml`, compiled by `cli/nagarectl/src/Nagare/Inventory/Cache.hs`). The
  protected hostname is still wired the way protected sites are: a backend-map contribution plus
  a DomainMapping to the shared enforcer (`cli/nagarectl/src/Nagare/Inventory/ProtectedRoute.hs`,
  `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`); the upstream that `upstreamFor` builds
  (`cli/nagarectl/src/Nagare/Access/Resolve.hs:340`) resolves to the plain Service unchanged.
- 2026-10-14 (MasterPlan 28 review): The hostname is `admin.<base domain>`, not `admin-api`. The
  admin UI will be served from the same origin (path `/`, later plan), so the browser never makes
  a cross-origin request and the gateway needs no CORS handling.
- 2026-10-14 (MasterPlan 28 review): Machine clients are Shomei service accounts presenting a
  bearer token through the gateway, granted on the hostname with the ordinary `access grant
  --user <user id>`. The gateway already accepts a bearer when no cookie is present
  (`cli/nagare-access/src/Nagare/Access/Credential.hs`) and verifies it as it verifies a cookie
  token (`Nagare/Access/Shomei.hs`); this plan proves it natively (M2, M3) and documents it in
  `docs/user/access.md`. ADR 29's "machine access" exclusion is amended at the MasterPlan's
  completion.
- 2026-10-14 (MasterPlan 28 review): The gateway's refusals on a JSON-shaped request are problem
  documents from the shared catalog, so the UI and Kotei decode one error shape for the gateway
  and the API. The HTML and redirect answers to document requests are unchanged.
- 2026-10-14 (to settle in M1): A local-mode context keeps its store on the workstation. Default:
  for local contexts only, the k3d cluster (created in `scripts/inventory-artifact-transport.sh`)
  mounts the context's state directory into the node, and the Deployment mounts it as a read-only
  `hostPath` volume; a plain Deployment needs no Knative feature flag for that. A cloud context
  always uses the GCS store. The store source is the one member that differs by mode, as the
  backup object store already does (MinIO locally, GCS in the cloud). If the mount cannot be made
  read-only and context-scoped, serve the local run from the workstation instead and record that.


## Context and Orientation

**How `nagare-access` is deployed today.** `cluster/bootstrap/nagare-access/service.yaml` is a
Knative Service in `nagare-system` with `min-scale` and `max-scale` 1, a non-root restricted
security context and a memory limit; `cluster/bootstrap/nagare-access/build-image.sh` and
`cli/nagare-access/Dockerfile` build its image, which is published to the context registry with
the other auth-plane images. Protected hosts reach their origins through the backend map,
the ConfigMap `nagare-access-backends` built in `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`.
Grants are reviewed per hostname ([ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md);
`docs/user/access.md` shows `nagarectl access grant --host <host> --user <email>`). The API's pod
shape does not copy the Knative Service; it follows the nix cache, a plain Deployment with a
NetworkPolicy (Decision Log).

**Platform scopes and releases.** Platform components are inventory scopes
([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)). The
release transition table in `cli/nagarectl/src/Nagare/Platform/Transition.hs` (around line 250)
lists every platform scope with its stage and change class; a release adding a scope adds a row,
and EP-172's transition carries an existing context to it
([ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)).
The release proof after v0.5.0 is the full gate, the EP-172 rehearsal on a disposable local
context, and the intranet's upgrade with the deploy-and-login check (CLAUDE.md).

**Native runs.** Before any native step, complete `docs/runbooks/before-a-native-run.md`;
defects are found by interpreters first ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).
Cloud mutations need the operator's go-ahead, asked once for a bounded sequence.


## Plan of Work

M1: add the Dockerfile and build script under `cli/nagare-api-server/` and
`cluster/bootstrap/admin-api/`, mirroring `nagare-access` for the image and the nix cache for
the workload templates (Deployment, Service, NetworkPolicy). Add the scope's compiler beside the
other platform scopes, its backend-map contribution, and its transition row. Its configuration
carries EP-196's `ServiceCredential` (for the GCS store) or the local mount (for local contexts).
Settle the local-store decision above with a quick experiment on a disposable k3d cluster. In
`cli/nagare-access`, add `nagare-contract` to `cabal.project` and the Dockerfile `COPY` lines, and
change `Nagare.Access.Response` (and the 503 in `Nagare.Access.App`) to render problem documents
for the `JsonApi` challenge mode; widen `wantsJson` in `Nagare.Access.Challenge` to any `+json`
`Accept` value.

M2 and M3 are native confirmations; each records its evidence path in Progress. The service
account for the bearer check is created the way `docs/user/auth-portal.md` creates a test user,
since the auth image ships `shomei-admin` (`cluster/bootstrap/shomei/README.md`):
`kubectl -n nagare-system exec -i deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin
service-accounts create --display-name kotei`. Its one-time secret goes to the operator's secret
store, never into a plan or a log; the token comes from Shomei's `/oauth/token` with
`grant_type=client_credentials`; the subject to grant is the token's `sub` claim, the account's
backing user, passed to `access grant --host admin.<base domain> --user <user id>`.


## Validation and Acceptance

M1 offline with `just haskell-style-check`, `just gate-fast` and the interpreter tests. M2 and M3
as stated in Progress.


## Interfaces and Dependencies

- Consumes the `nagare-api-server` executable and its flags (EP-197), `openServiceStore` and the IAM
  grant declaration (EP-196).
- Produces the `admin-api` platform scope, the `admin.<base domain>` protected hostname (API under
  `/v1`, `/` reserved for the UI), the gateway's problem-document rendering, and the documented
  machine-client path (`docs/user/access.md`).
