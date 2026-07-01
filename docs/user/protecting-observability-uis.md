# Protecting observability UIs

> **Status:** 🟡 **Manual integration.**
>
> Grafana and VictoriaTraces are installed by `just observability`, and the
> auth plane can protect arbitrary HTTP upstreams. This page documents the
> manual route until `nagarectl` grows a first-class command for platform-owned
> services.

Nagare's normal identity-aware access flow protects apps deployed through
`nagarectl`: the deploy resolver writes a host to the `nagare-access` backend
map, creates a Knative `DomainMapping` for that host, and grants are managed
with `nagarectl access`.

Grafana and VictoriaTraces are different. They are Helm-managed Kubernetes
`Service`s, not Nagare app `Deployment`s, so there is no typed `access =
requireLogin` config to deploy. To publish them on the wildcard domain, wire the
same three pieces by hand:

1. A public host, such as `grafana.apps.example.com`.
2. A `nagare-access-backends` entry mapping that host to a cluster-local HTTP
   upstream.
3. A `DomainMapping` in `nagare-system` that sends the public host to the shared
   `nagare-access` Knative Service.

## Recommended shape

Expose Grafana and keep trace storage private:

- `grafana.<base-domain>` -> `http://vmks-grafana.monitoring.svc.cluster.local`
- Grafana queries VictoriaTraces internally through its Jaeger datasource:
  `http://victoria-traces-vt-single-server.tracing.svc:10428/select/jaeger`

This gives browser access to metrics, logs, dashboards, and traces without
publishing VictoriaTraces' ingest/query/UI surface directly.

Do not expose VictoriaTraces directly unless you need an operator-only endpoint.
VictoriaTraces serves ingest, query, the Jaeger-compatible API, and its UI on
the same port. `nagare-access` authorizes by host, not by path, so a user granted
to a direct traces host can reach every path on that upstream.

## Prerequisites

Install observability and the optional auth plane:

```bash
just observability
cluster/bootstrap/auth-install.sh
```

For local mode, use `cluster/bootstrap/local-auth/install.sh` instead of the
cloud auth installer. The same backend-map and `DomainMapping` pattern applies;
set `BASE_DOMAIN` to the local loopback domain, such as
`127-0-0-1.sslip.io`.

The backend-map commands below use `jq`.

Make sure `nagare-access` is configured for the real parent cookie domain. The
checked-in manifest defaults to `.apps.example.com`; patch it if your active
target uses a different base domain.

Grafana still has its own admin account. Change
`cluster/observability/victoria-metrics/values.yaml` before a real install, or
move the admin password into a Secret with the Grafana chart's
`admin.existingSecret` support. `nagare-access` controls who can reach Grafana;
Grafana still controls what that user can do once inside Grafana.

## Expose Grafana

Set the host you want to publish:

```bash
export BASE_DOMAIN="apps.example.com"
export GRAFANA_HOST="grafana.${BASE_DOMAIN}"
```

Add the host to the enforcer backend map:

```bash
kubectl -n nagare-system get configmap nagare-access-backends \
  -o jsonpath='{.data.backends\.json}' > /tmp/nagare-access-backends.json

jq --arg host "$GRAFANA_HOST" \
   --arg upstream "http://vmks-grafana.monitoring.svc.cluster.local" \
   '. + {($host): $upstream}' \
   /tmp/nagare-access-backends.json > /tmp/nagare-access-backends.new.json

kubectl -n nagare-system create configmap nagare-access-backends \
  --from-file=backends.json=/tmp/nagare-access-backends.new.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

Restart the single `nagare-access` revision so it reloads the mounted ConfigMap:

```bash
kubectl -n nagare-system patch ksvc nagare-access --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/backend-map-reload\":\"$(date +%s)\"}}}}}"
```

Create the public route:

```bash
cat >/tmp/grafana-domainmapping.yaml <<EOF
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: ${GRAFANA_HOST}
  namespace: nagare-system
  labels:
    nagare.dev/managed-by: manual
spec:
  ref:
    apiVersion: serving.knative.dev/v1
    kind: Service
    name: nagare-access
    namespace: nagare-system
EOF

kubectl apply -f /tmp/grafana-domainmapping.yaml
kubectl -n nagare-system wait domainmapping "$GRAFANA_HOST" \
  --for=condition=Ready --timeout=120s
```

Grant a Shomei user access to the host:

```bash
kubectl -n nagare-system port-forward svc/en 8090:80
```

In another shell:

```bash
NAGARE_EN_URL=http://localhost:8090 \
  nagarectl access grant --host "$GRAFANA_HOST" --user alice
```

Open `https://grafana.${BASE_DOMAIN}/`. An unauthenticated browser request
should redirect to `/_nagare/login`; a signed-in but ungranted user should get
`403`; a granted user should reach Grafana.

## Grafana external URL

Grafana usually works behind the enforcer because `nagare-access` forwards
`X-Forwarded-Host` and `X-Forwarded-Proto`. If redirects, absolute links, or
OAuth callback URLs use the internal service name, pin Grafana's public root URL
in `cluster/observability/victoria-metrics/values.yaml`:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: https://grafana.apps.example.com/
```

Then run `just observability` again to apply the Helm values.

## Optional direct traces host

Prefer Grafana for trace browsing. If you still need direct VictoriaTraces
access, use a separate operator-only host:

```bash
export TRACES_HOST="traces.${BASE_DOMAIN}"
```

Add a backend map entry:

```bash
kubectl -n nagare-system get configmap nagare-access-backends \
  -o jsonpath='{.data.backends\.json}' > /tmp/nagare-access-backends.json

jq --arg host "$TRACES_HOST" \
   --arg upstream "http://victoria-traces-vt-single-server.tracing.svc.cluster.local:10428" \
   '. + {($host): $upstream}' \
   /tmp/nagare-access-backends.json > /tmp/nagare-access-backends.new.json

kubectl -n nagare-system create configmap nagare-access-backends \
  --from-file=backends.json=/tmp/nagare-access-backends.new.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n nagare-system patch ksvc nagare-access --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/backend-map-reload\":\"$(date +%s)\"}}}}}"
```

Create the same kind of `DomainMapping`, replacing the metadata name with
`${TRACES_HOST}`, then grant only operator users:

```bash
NAGARE_EN_URL=http://localhost:8090 \
  nagarectl access grant --host "$TRACES_HOST" --user alice
```

## Remove public access

Remove the route, backend map entry, and grants:

```bash
kubectl -n nagare-system delete domainmapping "$GRAFANA_HOST"

kubectl -n nagare-system get configmap nagare-access-backends \
  -o jsonpath='{.data.backends\.json}' > /tmp/nagare-access-backends.json

jq --arg host "$GRAFANA_HOST" 'del(.[$host])' \
  /tmp/nagare-access-backends.json > /tmp/nagare-access-backends.new.json

kubectl -n nagare-system create configmap nagare-access-backends \
  --from-file=backends.json=/tmp/nagare-access-backends.new.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n nagare-system patch ksvc nagare-access --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/backend-map-reload\":\"$(date +%s)\"}}}}}"
```

Revoke any grants that were added:

```bash
NAGARE_EN_URL=http://localhost:8090 \
  nagarectl access revoke --host "$GRAFANA_HOST" --user alice
```

## Troubleshooting

If the browser shows `404` or a backend-map error, confirm the backend map
contains the public host and that `nagare-access` has restarted after the
ConfigMap update.

If the page redirects to an internal Kubernetes service name, set Grafana's
`grafana.ini.server.root_url` as shown above.

If login succeeds but the page returns `403`, grant the exact public host shown
in the browser address bar. Grants are keyed by host, for example
`app:grafana.apps.example.com#viewer@user:alice`.

If a grant or revoke appears delayed, wait up to the enforcer decision TTL
(`NAGARE_ACCESS_DECISION_TTL`, default 30 seconds) or restart `nagare-access`.
