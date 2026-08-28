# Local-mode auth-plane install

Installs the nagare auth plane — **Shomei** (identity/JWT + WebAuthn), **en**
(relationship authorization), **nagare-access** (forward-auth enforcer) — on the
local k3d cluster in `NAGARE_MODE=local`, so a `access = requireLogin` app is
testable on a laptop with no GCP. See
`docs/plans/85-local-auth-plane-and-tls-for-nagare-protected-apps.md` and
MasterPlan 16 Integration Points 4 and 5.

## Prerequisites

1. The EP-82 local cluster + bootstrap (cert-manager + Knative + Kourier) and the
   local profile sourced (`NAGARE_MODE=local`, `NAGARE_REGISTRY_HOST`,
   `NAGARE_BASE_DOMAIN`).
2. The three images built and pushed to the local registry:
   ```bash
   export NAGARE_MODE=local NAGARE_CONTAINER_PLATFORM="$NAGARE_TARGET_PLATFORM"
   for svc in en shomei nagare-access; do
     cluster/bootstrap/auth-images/build-local-image.sh "$svc" dev
   done
   ```
   (Requires the sibling `../shomei` and `../en` checkouts the build helper
   expects. The host-side `insecure-registries` prerequisite for
   `k3d-registry.localhost:5000` is documented in `nagare.local.env.example`.)
3. The two managed Postgres databases in `nagare-system`:
   ```bash
   nagarectl db create postgres shomei-db -n nagare-system
   nagarectl db create postgres en-db     -n nagare-system
   ```
4. The local TLS issuer (`cluster/bootstrap/local-tls/`) — needed for the browser
   login (WebAuthn secure context).

### Upgrading from pre-0.2 Shomei

Shomei 0.2.0.0 repaired migration bugs by rewriting its migration history with
schema-qualified SQL, changing pg-migrate checksums. Nagare has no retained auth
data, so discard and recreate an existing pre-0.2 database before installing:

```bash
nagarectl context show
nagarectl db delete shomei-db -n nagare-system --yes
nagarectl db create postgres shomei-db -n nagare-system
```

This is a Nagare-only discard policy, not an in-place upgrade procedure for a
deployment with data to preserve; see
`mori://shinzui/shomei/packages/shomei-migrations`.

## Install

```bash
cluster/bootstrap/local-auth/install.sh
```

`install.sh` is the **validated explicit path**: it applies the cloud bases under
`cluster/bootstrap/{shomei,en,nagare-access}/` unchanged, then layers the three
local-mode differences as imperative overrides:

| difference | value | why |
|---|---|---|
| container images | `$NAGARE_REGISTRY_HOST/<svc>:dev` | pull from the local registry |
| `NAGARE_ACCESS_COOKIE_DOMAIN` | `.$NAGARE_BASE_DOMAIN` | one sign-in covers every local app |
| `SHOMEI_WEBAUTHN_RP_ID` / `SHOMEI_WEBAUTHN_ORIGINS` | `$NAGARE_BASE_DOMAIN` / `https://protected-hello.$NAGARE_BASE_DOMAIN` | the passkey ceremony validates against the loopback HTTPS origin (the protected-hello example derives its public host from the base domain) |

It also generates the `nagare-access` cookie key, En read-write/read-only API keys,
and Shomei key-encryption key once, preserving each Secret on reruns. It applies the
`en-schema` and `nagare-access-backends` ConfigMaps, then runs both services' explicit
`shomei-migrate` and `en-migrate` Jobs before starting their servers.

### Why a script and not a kustomize overlay

A kustomize overlay cannot aggregate these bases: every base file redundantly
declares `Namespace: nagare-system`, which kustomize rejects as a duplicate
resource id, and removing those namespace docs from the cloud bases would change
the cloud apply path (forbidden by the MasterPlan). Imperative `kubectl set
image` / `set env` / `patch` overrides keep the cloud bases byte-for-byte
unchanged while applying exactly the local differences. The Knative
`nagare-access` Service's container is unnamed, so its image and cookie-domain
env are patched by JSON path/index (fixed by `nagare-access/service.yaml`), not
by a name-keyed strategic merge.

## Verify

```bash
kubectl -n nagare-system get deploy shomei en
kubectl -n nagare-system get ksvc nagare-access
# enforcer health through a port-forward:
kubectl -n nagare-system port-forward ksvc/nagare-access 8080:80 &
curl -sS http://localhost:8080/_nagare/healthz   # 200
```

## Teardown

```bash
kubectl -n nagare-system delete deploy shomei en
kubectl -n nagare-system delete ksvc nagare-access
kubectl -n nagare-system delete secret nagare-access
nagarectl db delete shomei-db -n nagare-system --yes
nagarectl db delete en-db     -n nagare-system --yes
```

None of this touches the cloud path — the cloud bases and their cloud image
refs/env values are unchanged in git.
