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
3. Set `NAGARE_AUTH_EN_IMAGE`, `NAGARE_AUTH_SHOMEI_IMAGE`, and
   `NAGARE_AUTH_ACCESS_IMAGE` to the built immutable image references. The
   reviewed bootstrap creates both managed Postgres databases and the local TLS
   issuer before the auth services.

### Upgrading from pre-0.2 Shomei

Shomei 0.2.0.0 repaired migration bugs by rewriting its migration history with
schema-qualified SQL, changing pg-migrate checksums. A pre-0.2 database needs
operator-led ledger remediation before the reviewed migration; preserve its data
and review that recovery separately. See
`mori://shinzui/shomei/packages/shomei-migrations`.

## Install

```bash
cluster/bootstrap/local-auth/install.sh
```

`install.sh` publishes and applies the complete local bootstrap through reviewed
inventory. The component compiler binds the packaged auth manifests and these
local values before review:

| difference | value | why |
|---|---|---|
| container images | `NAGARE_AUTH_*_IMAGE` | use the reviewed immutable image references |
| `NAGARE_ACCESS_COOKIE_DOMAIN` | `.$NAGARE_BASE_DOMAIN` | one sign-in covers every local app |
| `SHOMEI_WEBAUTHN_RP_ID` / `SHOMEI_WEBAUTHN_ORIGINS` | `$NAGARE_BASE_DOMAIN` / `https://protected-hello.$NAGARE_BASE_DOMAIN` | the passkey ceremony validates against the loopback HTTPS origin (the protected-hello example derives its public host from the base domain) |

It generates the `nagare-access` cookie key, En API keys, and Shomei encryption
key only after confirmed absence. Migration Jobs have revision-bound identities
and retained completion proof; the services depend on those operations.

## Verify

```bash
kubectl -n nagare-system get deploy shomei en
kubectl -n nagare-system get ksvc nagare-access
# enforcer health through a port-forward:
kubectl -n nagare-system port-forward ksvc/nagare-access 8080:80 &
curl -sS http://localhost:8080/_nagare/healthz   # 200
```

Retiring a retained auth database requires a reviewed inventory lifecycle
operation and an explicit data recovery decision.
