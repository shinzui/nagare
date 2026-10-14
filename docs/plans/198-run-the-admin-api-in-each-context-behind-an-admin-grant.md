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
---

# Run the admin API in each context behind an admin grant

Child of [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md).
Progress holds the deliverables with pass/fail evidence; the Decision Log holds dated decisions.


## Purpose / Big Picture

After this plan, a context converged on the release that carries it runs `nagare-api-server`
(from [EP-197](197-serve-the-read-documents-through-a-typed-servant-admin-api.md)) in
`nagare-system`, at the protected hostname `admin-api.<base domain>`. A person signs in through
the context's existing portal; if the operator has granted them access to that hostname with an
ordinary reviewed `nagarectl access grant`, their browser can read
`https://admin-api.<base domain>/v1/...`. Anyone else gets the gateway's login or 403, exactly as
for any protected site. The server reads the context's GCS inventory store with the read-only
credential from [EP-196](196-read-the-inventory-store-from-an-in-cluster-service-identity.md).

The requirement this moves (operator, 2026-10-10): the operator can see the state of what they
change and upgrade, without running the CLI.


## Progress

- [ ] M1. The image and the platform scope, offline. Pass: a Dockerfile and build script for
  `nagare-api-server` beside the `nagare-access` ones; a new platform scope `admin-api` whose
  members are the Knative Service (cluster-local visibility, `min-scale` 1, the same pod security
  context as `nagare-access`), its configuration (context name, store URL, OTLP endpoint) and its
  backend-map contribution for the protected hostname; the scope added to the release transition
  table (`cli/nagarectl/src/Nagare/Platform/Transition.hs`) so an existing context gains it through
  `platform transition`; interpreter tests that plan the scope on a fixture context, and a model
  scenario that adds it through a transition. Gates green, landed.
- [ ] M2. Local native run (disposable local context, per ADR 25). Pass: the scope converges, an
  unchanged replan has zero operations, `/health/ready` is 200, a user granted the hostname reads
  `/v1/inventory/scopes` and gets the context's scopes, and an ungranted signed-in user gets 403.
  The local context's store is a local directory, so the server reads it through the M1 decision
  recorded below.
- [ ] M3. The intranet. Pass: after the release that carries this plan, the intranet upgrade
  through `platform transition` adds the scope and applies EP-196's grant; the operator grants
  themselves the hostname; the operator's signed-in browser reads `/v1/platform/version` and
  `/v1/inventory/scopes`, and the deploy-and-login check still passes. Cloud mutations here follow
  the operator's go-ahead rule.


## Decision Log

- 2026-10-14: The API is its own platform scope, `admin-api`, not a member of `auth`. It has its own
  image, credential and failure modes; retiring or upgrading it must not touch the login path.
- 2026-10-14: The Knative Service is cluster-local and reachable only through `nagare-access`, which
  makes `X-Forwarded-User` trustworthy for logging (EP-197). The protected hostname is wired the
  way protected sites are: a backend-map contribution plus a DomainMapping moved to the shared
  enforcer (`cli/nagarectl/src/Nagare/Inventory/ProtectedRoute.hs`,
  `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`).
- 2026-10-14 (to settle in M1): A local-mode context keeps its store on the workstation. Default:
  for local contexts only, mount the context's store directory read-only into the server pod from
  the k3d node (the k3d cluster is created in `scripts/inventory-artifact-transport.sh`); a cloud
  context always uses the GCS store. If the mount cannot be made read-only and context-scoped,
  serve the local run from the workstation instead and record that.


## Context and Orientation

**How `nagare-access` is deployed today.** `cluster/bootstrap/nagare-access/service.yaml` is a
Knative Service in `nagare-system` with `min-scale` and `max-scale` 1, a non-root restricted
security context and a memory limit; `cluster/bootstrap/nagare-access/build-image.sh` and
`cli/nagare-access/Dockerfile` build its image, which is published to the context registry with
the other auth-plane images. Protected hosts reach their origins through the backend map,
the ConfigMap `nagare-access-backends` built in `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`.
Grants are reviewed per hostname ([ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md);
`docs/user/access.md` shows `nagarectl access grant --host <host> --user <email>`).

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
`cluster/bootstrap/admin-api/`, mirroring `nagare-access`. Add the scope's compiler beside the
other platform scopes, its backend-map contribution, and its transition row. Its configuration
carries EP-196's `ServiceCredential` (for the GCS store) or the local mount (for local contexts).
Settle the local-store decision above with a quick experiment on a disposable k3d cluster.

M2 and M3 are native confirmations; each records its evidence path in Progress.


## Validation and Acceptance

M1 offline with `just haskell-style-check`, `just gate-fast` and the interpreter tests. M2 and M3
as stated in Progress.


## Interfaces and Dependencies

- Consumes the `nagare-api-server` executable and its flags (EP-197), `openServiceStore` and the IAM
  grant declaration (EP-196).
- Produces the `admin-api` platform scope and the `admin-api.<base domain>` protected hostname.
