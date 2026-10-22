---
id: 216
slug: reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward
title: "Reach En through the API server's service proxy instead of a port-forward"
kind: exec-plan
created_at: 2026-10-22T21:24:47Z
master_plan: "docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T21:24:47Z
---

# Reach En through the API server's service proxy instead of a port-forward

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md)
and is **Held** behind a trigger: an En release that accepts its API key in the `X-En-Api-Key`
header (`mori://shinzui/en/okf/improvement-requests/concepts/IR-1`) is pinned by Nagare's auth plane
and rolled onto the context. Until then EP-214's one-forward-per-command design is the En path.


## Purpose / Big Picture

Every reviewed access relationship is written to and observed in En, the authorization service in
`nagare-system`, through `kubectl port-forward svc/en`. The forward rides the tailnet already: the
prepared kubeconfig's server is the host's tailnet name on port 6443. What costs time is the
`kubectl` process and its tunnel, about 0.9 s to become ready, plus the readiness parsing, reopen
and termination logic that EP-214 has to carry. The Kubernetes API server can proxy an HTTP request
to a Service directly: `GET /api/v1/namespaces/nagare-system/services/en:80/proxy/v1/...` on the
same server, authenticated with the kubeconfig's client certificate. A read-only probe from the
operator's workstation on 2026-10-22 reached En that way in 0.10 to 0.12 s per request. The
blocker is that the API server deletes the `Authorization` header after it has authenticated the
caller, and En reads its key only from `Authorization: Bearer`; IR-1 asks En to accept
`X-En-Api-Key` as well.

After this plan a command that touches En makes plain HTTPS requests to the API server with the
kubeconfig's identity and En's key in `X-En-Api-Key`. No `kubectl` process is spawned for En, no
forward is opened, and En stays unreachable except through the API server's authentication and
RBAC, which is a stronger gate than exposing it on the tailnet. The observable outcome is the
same reviewed grant, membership, check and portal sync with `NAGARE_TRACE=1` showing zero
forwards and En calls of about a tenth of a second.


## Progress

- [ ] M0 (trigger): Nagare's auth plane pins an En release whose `/v1/openapi.json` declares an
  `apiKeyAuth` security scheme in header `X-En-Api-Key` beside `bearerAuth`, and a reviewed
  platform update has rolled it onto the intranet. Pass: `access check` through the existing
  forward sees the scheme in En's OpenAPI document; recorded here with the En version.
- [ ] M1: A TLS client built from the prepared kubeconfig. `Nagare.Cluster.ApiServer` reads the
  context's kubeconfig (one cluster with `server` and `certificate-authority-data`, one user with
  `client-certificate-data` and `client-key-data`) and gives an `http-client` manager that
  presents that certificate; any other credential form refuses with a reason. Pass: unit tests
  over a kubeconfig fixture; a local k3d kubeconfig and the cloud form both load; a token or exec
  user is refused before any request.
- [ ] M2: An `EnTransport` over the service proxy. `withEn` runs the action against
  `<server>/api/v1/namespaces/nagare-system/services/en:80/proxy` with `X-En-Api-Key` from the
  private `NAGARE_EN_API_KEY`, never `Authorization`; the capability check verifies En's OpenAPI
  document declares `apiKeyAuth` and refuses otherwise with a reason naming IR-1. Pass: a Warp
  fixture that mimics the proxy (strips `Authorization`, forwards the rest) proves the key
  arrives and the forward is never spawned; the EP-214 counting tests pass with this transport
  substituted.
- [ ] M3: The forward is gone. `openEnForward`, `closeEnForward` and `parseEnForwardPort` are
  removed; the direct `--en-url` forms are unchanged; `docs/user/access.md` and
  `docs/user/accessing-the-host.md` describe the proxy path and the `services/proxy` RBAC it needs.
  Pass: `grep port-forward cli/nagarectl/src` finds nothing under the access path; intranet
  confirmation shows zero `kubectl` processes for one grant plan and apply and En call times under
  0.2 s, recorded here.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: Proxy through the API server; do not expose En on the tailnet. The host firewall
trusts `tailscale0` wholesale, so a hostPort, a subnet route for the k3s service range, or the
Tailscale Kubernetes operator would make En's write API reachable by every tailnet device with
only its API key as the gate, and a subnet route would expose every ClusterIP. The API server
keeps a client certificate and RBAC in front of En.

2026-10-22: Held until En ships the header. The API server's `withAuthentication` filter deletes
`Authorization` after a successful authentication, so no nagarectl-only change can carry the
bearer through the proxy. The MasterPlan keeps EP-214 as written; this plan replaces EP-214's
kubectl transport behind the same `EnTransport` seam when the trigger fires. No fallback to the
forward is kept once this lands: an En without the header refuses with a reason.

2026-10-22: Owner UID reads stay on `kubectl get`. Moving them to the API server would need
discovery of each kind's resource path and is a separate change.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

**Today's En path.** `cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs`: `withContextEn`
spawns `kubectl --context C -n nagare-system port-forward svc/en :80 --address 127.0.0.1`, waits
for the "Forwarding from" line, and runs the action with an `EnCall` built by `enRequest`, which
sends `Authorization: Bearer <NAGARE_EN_API_KEY>` with a 10 s timeout and no redirects. After
EP-214 this lives behind `EnTransport { withEn, readOwner, clusterGuard }` and
`accessRuntimeOpsWith`; this plan supplies a second `EnTransport` implementation and deletes the
first.

**The API server proxy.** Kubernetes serves
`/api/v1/namespaces/{ns}/services/{name}:{port}/proxy/{path}` by forwarding the request to one
endpoint of the Service. The caller needs `get` (and `create` for POST) on `services/proxy` for
that Service; the k3s administrator certificate the prepared kubeconfig carries is cluster-admin.
`k8s.io/apiserver/pkg/endpoints/filters/authentication.go` removes the `Authorization` header
after authenticating ("authorization header is not required anymore in case of a successful
authentication"), which is why En must read a different header. Probe from the operator's
workstation on 2026-10-22, read-only, using the prepared kubeconfig's client certificate with
`curl`: `/v1/schema` and `/v1/openapi.json` answered En's own 401 problem document
("missing or invalid API key") in 0.10 to 0.12 s, the same with a bogus bearer, confirming both
the route and the header removal.

**The kubeconfig.** `Nagare.Cluster.Kubeconfig` (`cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs`)
fetches the cluster's kubeconfig, normalizes it to one cluster named after the context with
`server = https://<host name>:6443` and one user, and writes it under the context's state
directory; `kubeconfigPath` names it. The cloud form carries `certificate-authority-data`,
`client-certificate-data` and `client-key-data`; `normalizeLocalKubeconfig` keeps a k3d
loopback endpoint for local mode. The host name resolves over the tailnet (MagicDNS), which is
how `kubectl` reaches the API server today (`docs/user/accessing-the-host.md`).

**En.** `mori://shinzui/en`: `en-server/app/Middleware.hs` `authenticate` reads `hAuthorization`
and accepts `Bearer <secret>` against `EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY`
(`en-server/app/Config.hs`); `en-servant/src/En/Servant/OpenApi.hs` `withSecurityScheme`
declares `bearerAuth`. IR-1 asks for `X-En-Api-Key` with the same keys and roles and an
`apiKeyAuth` scheme in the OpenAPI document, which is the capability this plan checks.

**Dependencies.** `http-client-tls` is already a `nagarectl` dependency; presenting a client
certificate needs `crypton-connection`'s `TLSSettings` (or `tls`' `ClientParams` directly) and
PEM decoding through `crypton-x509` and `crypton-x509-store`, which gogol already pulls in.
`Nagare.Inventory.Store.Gogol.inventoryManagerSettings` is the precedent for a bounded,
non-retrying manager.

**Rules.** [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) (the
access model), [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
(the cluster guard stays), [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
(a fixture proves the header path; the intranet confirms),
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) with
`mori://shinzui/haskell-jitsurei/docs/core-standards`.


## Plan of Work

M0 is not nagarectl work: when En publishes the release that closes IR-1, the auth plane's En
image pin is bumped as any auth-plane update is (ADR 1), the release ships, and the intranet's
platform update rolls En. Record the version here and start M1.

M1 adds `Nagare.Cluster.ApiServer` with
`loadApiServerIdentity :: FilePath -> IO (Either Text ApiServerIdentity)` (server URL, CA
certificates, client certificate chain and private key, decoded from the kubeconfig's embedded
data) and `newApiServerManager :: ApiServerIdentity -> IO Manager`, a manager whose TLS client
hooks present the certificate and validate the server against the embedded CA, with the same
20 s response timeout and no retries as the inventory manager. Anything but one cluster and one
client-certificate user is a refusal.

M2 adds `proxyEnTransport :: ApiServerIdentity -> Manager -> Text -> IO (Either Text ()) -> EnTransport`
in `Nagare.Inventory.AccessRuntime`: `withEn` builds the `EnCall` whose requests go to
`<server>/api/v1/namespaces/nagare-system/services/en:80/proxy<path>` with
`X-En-Api-Key: <key>` and `Content-Type: application/json`, 10 s timeout, no redirects, and
never an `Authorization` header. The capability check (`parseAccessCapabilities`) additionally
requires `components.securitySchemes.apiKeyAuth` with `in: header` and `name: X-En-Api-Key`;
a document without it refuses with "En does not accept X-En-Api-Key; roll the auth plane that
ships IR-1". `readOwner` and `clusterGuard` keep EP-214's kubectl implementations. The command
boundaries that EP-214 wrapped in `withEnSession` construct this transport instead; the private
key is still required before any request (`accessKeyRefusal`).

M3 deletes the forward code and updates the two user documents, then runs the intranet
confirmation with `NAGARE_TRACE=1` and EP-185's kubectl PATH shim.


## Concrete Steps

From the repository root after every Haskell change:

```bash
just haskell-style-check
just gate-fast
```

Focused suites:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/Access/||/ApiServer/"' --test-show-details=direct
```

Read-only check that the trigger has fired, on the intranet (through the existing forward):

```bash
kubectl -n nagare-system port-forward svc/en 18082:80 &
curl -sS -H "Authorization: Bearer $NAGARE_EN_API_KEY" http://127.0.0.1:18082/v1/openapi.json | jq '.components.securitySchemes'
```

Commit message shape:

```text
feat(access): reach en through the API server's service proxy with the kubeconfig identity

MasterPlan: docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md
ExecPlan: docs/plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward.md
```


## Validation and Acceptance

- A kubeconfig fixture with embedded CA, client certificate and key loads; one with a `token`
  user, an `exec` user, two clusters or a missing CA refuses with the field named.
- A Warp fixture standing in for the API server requires the client certificate, strips any
  `Authorization` header, forwards `X-En-Api-Key`, and records that the En side saw the key:
  the full adapter lifecycle for one tuple passes through it with zero forwards opened (the
  EP-214 counting test with the transport swapped).
- An En OpenAPI document without `apiKeyAuth` makes prepare refuse with the IR-1 reason and
  sends no write.
- No `Authorization` header is ever sent to the API server by the En path (the fixture asserts
  its absence).
- Intranet: one grant plan and apply with `NAGARE_TRACE=1` and the kubectl shim show zero
  `port-forward` processes and En calls under 0.2 s; the apply is a real reviewed change and runs
  with the operator's go-ahead.


## Idempotence and Recovery

The transport change moves no data. A lost response is handled as today: the adapter reports
`AdapterEffectAmbiguous` and `inventory resume` re-observes the exact tuple. Reverting the landed
commit restores EP-214's forward. The En release that carries the header keeps `Bearer`, so the
direct `--en-url` forms and older nagarectl keep working during the roll.


## Interfaces and Dependencies

```haskell
-- cli/nagarectl/src/Nagare/Cluster/ApiServer.hs (new)
data ApiServerIdentity = ApiServerIdentity
  { server :: !Text                 -- https://<host>:6443
  , authority :: ![SignedCertificate]
  , credential :: !Credential       -- client certificate chain and key
  }
loadApiServerIdentity :: FilePath -> IO (Either Text ApiServerIdentity)
newApiServerManager :: ApiServerIdentity -> IO Manager

-- cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs
proxyEnTransport :: ApiServerIdentity -> Manager -> Text -> IO (Either Text ()) -> EnTransport
-- withEn sends X-En-Api-Key, never Authorization; capability check requires apiKeyAuth
```

Hard dependencies: EP-214 complete (the `EnTransport` seam and `withEnSession` boundaries), and
the M0 trigger (En release with `X-En-Api-Key`, pinned and rolled). Cross-repository:
`mori://shinzui/en/okf/improvement-requests/concepts/IR-1`.
