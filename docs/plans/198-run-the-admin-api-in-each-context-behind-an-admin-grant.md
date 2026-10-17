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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T22:20:47Z
      mode: "update"
      note: "Source-based API validation: correct shared interfaces, bounded read costs, HTTP behavior and serving acceptance."
---

# Run the admin API in each context behind an admin grant


## Purpose / Big Picture

Run the recorded-state service at `https://admin.<base domain>/v1/…` behind the existing
`nagare-access` gateway. People use their session cookie; Kotei uses a Shomei service-account
bearer token. Both require an ordinary reviewed grant on the exact hostname. `/` is reserved
for the later UI on the same origin. Ordinary workload pods cannot bypass the gateway to reach
the API. Cluster administrators/node access remain trusted infrastructure, not something a
NetworkPolicy isolates. [MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md)
coordinates the service, credentials and contract.


## Progress

- [x] M1. Offline, except the image build (moved to M2, which first needs a container daemon).
  Scope `platform:admin-api` (`Nagare.Inventory.Components.AdminApi`, wired into the platform
  candidate when the context sets `NAGARE_ADMIN_API_ENABLED=1`): Deployment, Service and
  NetworkPolicy from `cluster/bootstrap/admin-api/admin-api-{cloud,local}.yaml.tmpl`, a protected
  DomainMapping for `admin.<base>` ordered after the backend map and enforcer, and an `ApiBackend`
  contribution, which the backend map renders as `apiPrefix: /v1`, `timeoutSeconds: 15`. In a cloud
  context the scope also binds the sops reader Secret `admin-api-reader.yaml` as a member with
  sensitivity `Secret`, and its digest annotates the pod template. A local context's
  substrate spec gains `inventoryMount`, and the transport mounts it read-only. Transition row
  `admin-api` is `NotInLocalContext`. Image: `build-local-image.sh nagare-admin-api`. Gateway:
  `/v1` on an API backend, a bearer credential, or an Accept that prefers JSON now get RFC 9457
  problems (401 with `WWW-Authenticate: Bearer`, 403, 503 `authorization_unavailable`, 502
  `upstream_unavailable`, 504 `upstream_timeout`, all `no-store`). Proxy failures carry no
  exception text. Authorization is bounded at 5 s. Pass: `nagarectl-test` "admin API inventory
  component" (5 tests: local and cloud members, policy conjunction and egress exclusions,
  route ordering and alias, wire round trip, key rotation rolls the pod, refused inputs, the
  composed backend entry, no other platform contributor) and the transition table spec;
  `nagare-access-test` 168 tests (19 new in `AdminApiGatewaySpec`: missing/`*/*`/HTML Accept
  on `/v1`, expired bearer, denial, unavailable and hung authorizer, Accept quality values,
  closed and slow upstreams, 304/ETag forwarding, spoofed `X-Forwarded-User`);
  `just haskell-style-check`, the architecture ratchet, and `just gate-fast`.
- [x] M2. 2026-10-17, candidate `6f5ea259`, local context on `nagare-mp23` (arm64), images
  built from this tree. The bootstrap converged with the admin API, and the final plan had 0
  operations. Through the gateway:
  - anonymous `/v1` requests get 401 problems (`WWW-Authenticate: Bearer`, also with no Accept or
    `*/*`), and `/` redirects;
  - a person and a Shomei service account get 403 `forbidden` before their grants and 200 after;
  - `If-None-Match` answers 304, an unknown route 404 and POST 405;
  - a revoked grant is refused within the TTL.

  Requests to the Service and the Pod IP get no answer from an application pod, from an unrelated
  `nagare-system` pod, and from a look-alike-labelled pod, while their control requests reach
  other Services. Warm p95 is 23–41 ms; a stopped server is 502 `upstream_unavailable` within
  1 s; a replan has 0 operations. Evidence:
  [`docs/audits/ep198-admin-api/`](../audits/ep198-admin-api/README.md). Two findings were fixed on
  the way: the packaged suite needed the spec's cluster-source patch, and a VM shares the store's
  owner-private files as root-owned (decision below).
- [ ] M3. After the release and operator authorization for the bounded cloud sequence, reviewed
  infrastructure applies EP-196's identity/IAM first, then the intranet transition adds the API.
  Browser and service-account access work, actual IAM denies writes and sibling Pulumi reads,
  the pod cannot reach the mutating node metadata credential, and gateway-to-GCS latency meets
  EP-197's measured acceptance. Deploy-and-login still passes; record the tested release/evidence.


## Surprises & Discoveries

The existing proxy emits text 502 responses, the backend map is loaded at startup, and the
nix-cache policy permits general HTTPS egress. Those facts require explicit gateway rendering,
a rollout and honest network-policy boundaries for this service.


## Decision Log

2026-10-17 (M2): The local pod runs as UID 0 with every capability dropped except
`DAC_READ_SEARCH`, with a read-only root filesystem and mount and no privilege escalation.
Colima's file sharing presents the store's 0600/0700 files as root-owned, and a native daemon as
the workstation user's. No fixed non-root UID can read both, and the store's private modes stay.
The cloud pod is unchanged: UID 10001, no capabilities.

2026-10-17 (M1): EP-198 M1–M2 depend on EP-196 M2's `openServiceStore` (complete). Only M3
depends on EP-196 M3, whose Pulumi preview and apply are M3's first step. The gateway already
re-reads its mounted backend map every five seconds (`refreshLoop`), so no enforcer rollout is
needed; this supersedes the startup-load surprise below.

2026-10-17 (M1): The admin host is a new backend role `ApiBackend` (wire `api`). The backend map
renders it as an ordinary protected object plus `apiPrefix` and `timeoutSeconds`, so a gateway
that predates the fields degrades to plain protected handling. A platform scope may contribute
a backend only if it is `platform:admin-api`. The API is opt-in per context
(`NAGARE_ADMIN_API_ENABLED`, plus `NAGARE_PROJECT_NUMBER` in cloud), so contexts that don't
enable it compile unchanged; enabling it seeds `enableAdminApiReader`. The image is built like
the auth plane's and bound through `NAGARE_ADMIN_API_IMAGE`.

2026-10-17 (M1): Local mode mounts the store through the substrate spec, which the enabled context
writes beside its store with `inventoryMount`. An existing cluster created without the mount
fails the substrate's "differs from the selected specification" check instead of being reused.
The pod's hostPath is `type: Directory`, so a missing mount fails the pod rather than serving
an empty store. Cloud egress is TCP 443 to addresses outside 10/8, 172.16/12, 192.168/16,
100.64/10 and 169.254/16. Every host now treats a bearer credential or a JSON-preferring Accept
as an API call, has a 5 s authorization budget, and gets proxy failures without exception text.

2026-10-14: The API is its own `admin-api` platform scope with its own image and credential.
It runs as a plain Deployment and ClusterIP Service: a shared cluster-local Knative route would
permit other pods to reach it through ingress/activator. The hostname is `admin.<base domain>`;
API and future UI share one origin and need no CORS expansion.

2026-10-14: Machine clients use Shomei service accounts and ordinary per-host grants. Gateway
JSON challenges use the shared problem catalog while keeping existing `error`/`login` fields.
The browser login flow remains unchanged for the future UI at `/`.

2026-10-16: Validation makes the gateway's API classifier explicit for the admin backend's
`/v1` paths, even without Accept, and includes proxy failures. Extending only a substring match
for `+json` would still redirect a machine client's ordinary `Accept: */*` request. HTTP errors
from infrastructure outside Nagare, or after response commit, cannot promise a problem body.

2026-10-16: Native Kubernetes NetworkPolicy cannot select a DNS name such as
`storage.googleapis.com`; the existing nix-cache precedent permits TCP 443 to all IPs. Do not
label that rule “GCS only.” Use the bounded policy below and exact IAM confinement. A dedicated
reader identity also requires blocking the API pod's path to the node metadata credential.
Kubernetes/node administrative access is outside ordinary workload isolation.

2026-10-16: A local mount is required to accept M2's deployed path. A workstation-only service
proves EP-197 but does not prove the Deployment or bypass policy; it is not a substitute for M2.
The API never initializes a local store or writes its source mount.


## Context and Orientation

`cluster/bootstrap/nagare-access/service.yaml` deploys the Knative enforcer in `nagare-system`.
Use its actual stable pod label (`serving.knative.dev/service: nagare-access`) in policy selectors,
not revision names. `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs` builds backend entries;
`Nagare/Access/Resolve.hs` constructs the service upstream URL. `Nagare/Inventory/ProtectedRoute.hs`
provides protected route conventions; its workload compiler assumes Knative origins, so the new
Deployment compiler must explicitly create its ClusterIP Service, backend entry and protected
DomainMapping, rather than blindly passing a Deployment through that compiler.
`cluster/bootstrap/nix-cache/` is a Deployment/Service/policy precedent, not an exact policy to copy.

`cli/nagare-access/src/Nagare/Access/Challenge.hs` currently classifies JSON by request headers;
`Response.hs` renders challenges; `App.hs` emits auth failures; `Proxy.hs` currently emits plain
text 502s, including exception text. `Credential.hs` prefers the session cookie when present,
then bearer. Document machine requests without session cookies; preserve and test precedence.
`Proxy.hs` already overwrites forwarded identity headers. The backend uses `X-Forwarded-User`
for logs/traces only; gateway En checks remain the sole application authorization decision.

`cli/nagarectl/src/Nagare/Platform/Transition.hs` lists platform scopes and release stages.
Register the new scope in the actual compiler/assembly, release/payload image sources and
transition table; a table row alone cannot materialize it. Review how the backend map and auth
rollout are contributed: `nagare-access` loads its map at startup, so a ConfigMap update without
a rollout will not route the new hostname. Exercise that producer/consumer path offline first.
Relevant ADRs are [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) and
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md).


## Plan of Work

M1 packages `nagare-api-server` with a Dockerfile and `cluster/bootstrap/admin-api/` templates.
Use one replica, non-root restricted security context, read-only root filesystem, no automatic
Kubernetes service-account token, explicit CPU request/limit 100m/1 and memory request/limit
128Mi/512Mi. Mount a bounded writable private `/tmp` and cache directory; mount EP-196's reader
key read-only. The server binds `0.0.0.0:8085`; Service port 80 targets 8085. Configure startup,
liveness and readiness probes, with readiness's timeout above its one-second internal budget.
Allow startup hydration without using liveness as a dependency restart loop. Include graceful
shutdown and an always-running replica so ordinary calls do not wait for scale-from-zero.

Select ingress from the conjunction of namespace `nagare-system` AND the gateway's stable pod
label on TCP 8085 only. A namespace-only rule would admit unrelated platform pods; a list of two
separate peers would OR the selectors. Policy must cover Pod IP and Service paths under the
installed k3s network-policy controller; prove enforcement rather than assuming a manifest is
sufficient. Kubelet/node probes are infrastructure access; no public DomainMapping may target the
API Service directly. Restrict who can create gateway-labelled pods in the trusted namespace.

For the dedicated-key configuration, egress permits cluster DNS (TCP/UDP 53 to the DNS pods),
the selected collector namespace/pods and port, and TCP 443 to external IPs for Google storage,
token exchange and authoritative project lookup. Exclude link-local metadata ranges (at least
`169.254.0.0/16`, and applicable IPv6 paths); grant no metadata port 80. Test hostname and IP
metadata paths from the API pod. This is HTTPS egress, not an FQDN allowlist. If the installed
CNI offers no enforceable metadata isolation, M1/M2 must resolve that before claiming the pod
holds only a read-only identity. Do not apply the new account's grant to the node account.

For local mode, extend the disposable k3d fixture in `scripts/inventory-artifact-transport.sh`
to mount only that context's preinitialized state directory into the node. The Deployment mounts
it read-only and writes temp/cache elsewhere. Verify host updates are visible through atomic
head replacement, access permissions for the non-root UID, and refusal of an uninitialized store.
A cloud context serves in-cluster only when its authoritative inventory store is GCS; a
cloud context still using workstation-local history must explicitly migrate it through the
existing reviewed procedure before enabling this scope. Do not silently open an empty store.

Wire `admin.<base domain>` to the gateway through a protected DomainMapping and its backend map,
then roll the enforcer through the existing reviewed mechanism. Grant the hostname through
ordinary `access grant`. The admin backend's `/v1` requests always receive API-shaped gateway
errors; preserve existing HTML/redirect behavior for UI document paths. Also honor actual JSON
media types (including structured `+json`, respecting quality values) and bearer requests where
appropriate. API 401 includes `WWW-Authenticate: Bearer` and a safe login link; 403 is
`forbidden`; dependency 503 is `authorization_unavailable`; proxy connection failure is 502
`upstream_unavailable` and proxy timeout is 504 `upstream_timeout`. Use the shared catalog and
optional gateway extensions, `Cache-Control: no-store`, and sanitized details without raw
`HttpException` text. Do not rewrite successful upstream responses or arbitrary streamed bodies.

Set the admin backend's upstream deadline above the API's ten-second total deadline (15 seconds)
and a bounded gateway auth budget; preserve existing unrelated-site streaming behavior. Forward
ETag/If-None-Match and snapshot/cache headers, including 304, and never bypass authentication on
conditional requests. Generate/document gateway error statuses in EP-197's OpenAPI artifact.
Test wrong method, invalid Accept, missing Accept, no token, expired bearer, revoked grant,
upstream down and timed-out upstream, alongside an ordinary browser login and successful bearer.
Revocation respects ADR 29's existing decision TTL; this plan does not claim instant revocation.

M2 confirms the installed path with disposable identities and fixture store. Use a Shomei
service account created by the shipped `shomei-admin service-accounts create`, request a token
at `/oauth/token` with `grant_type=client_credentials`, and grant its backing `user_…` subject.
Keep the one-time secret in operator secret storage and out of logs. Verify the CLI syntax
against the pinned Shomei source via Mori before running it. The positive gateway access and
negative direct access must run against the same candidate and policy.

M3 follows `docs/runbooks/before-a-native-run.md` and the existing cloud authorization rule.
First review/apply EP-196's Pulumi identity/IAM and credential delivery; then release/transition
the platform scope. Test actual provider authorization from the dedicated identity using a
disposable forbidden write target and a nonsecret sibling object, with expected denials. Never
attempt a production mutation as a permissions test. Record 100 warm requests at concurrency
eight through the real gateway and GCS, as specified by EP-197, plus a separately identified cold
request and dependency failure. A passing local store run cannot substitute for remote proof.


## Validation and Acceptance

M1 runs the existing interpreter/model suites and style/fast gates; M2/M3 provide only the native
confirmations stated in Progress. The service must meet EP-197's two-second warm p95 through the
gateway and ten-second backend deadline, with cold/startup evidence reported separately. Isolation
proof includes same-namespace unrelated pods and Pod-IP bypass, not only an application pod's
Service DNS. The declared IAM and actual denial tests must agree. Any unresolved credential,
policy or mount choice keeps its milestone open; no new child plan is needed to finish it.


## Interfaces and Dependencies

Hard dependencies: complete
[EP-196](196-read-the-inventory-store-from-an-in-cluster-service-identity.md) and
[EP-197](197-serve-the-read-documents-through-a-typed-servant-admin-api.md).
EP-198 owns deployment, resource limits, mounts, routing, gateway rendering and native measurements.
EP-197 owns API semantics and generated OpenAPI, EP-192 the catalog/schema. EP-198 extends the
catalog and asks the existing generator to include gateway responses; it does not fork the schema.

The policy's peer conjunctions, additive allow rules and node-traffic limitations follow the
[Kubernetes NetworkPolicy contract](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
Inspect all policies selecting the API pod: adding a restrictive policy cannot subtract access
already allowed by another policy.


## Outcomes & Retrospective

The deployment and native proof are specified. No cloud infrastructure was changed and no
latency or bypass test has been run by this plan validation.
