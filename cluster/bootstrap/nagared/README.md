# nagared — Git webhook runner (EP-16)

`nagared` deploys static sites automatically from GitHub events. It verifies the
webhook HMAC-SHA256 signature, checks out the named commit, and runs the **same**
deploy path as `nagarectl site deploy` (it imports `Nagare.Static.Deploy`, not a
second engine):

- a push to the configured production branch → production deploy + release record;
- a pull request `opened`/`synchronize`/`reopened` → preview deploy named `pr-<number>`.

## Routes

```text
GET  /healthz                          -> 200 ("ok")
POST /webhooks/github/static/<site>    -> verify signature, checkout, deploy
```

An unsigned or mis-signed request is rejected with 401 **before** the body is
parsed or any deploy runs. A push to a non-production branch or a non-deploy PR
action returns 200 with a no-op message. Handling is idempotent: a retried
delivery for the same commit re-resets the checkout and re-records the same
release id (deduped by `Nagare.Static.Release.addRelease`).

## Local run

```bash
cd cli/nagarectl
NAGARE_WEBHOOK_SECRET=dev-secret cabal run nagared -- --port 8088 --production-branch main
# health check
curl -s localhost:8088/healthz            # -> ok
# signed ping (GitHub-compatible HMAC):
BODY='{"zen":"x"}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac dev-secret | sed 's/^.*= //')"
curl -s -XPOST localhost:8088/webhooks/github/static/demo \
  -H "X-GitHub-Event: ping" -H "X-Hub-Signature-256: $SIG" --data "$BODY"   # -> pong
```

## Cluster deploy

`service.yaml` runs nagared as an always-on Knative Service (`min-scale: 1` so a
long deploy is never scaled away mid-build), exposed through the existing Kourier
ingress + cert-manager, with a stable hook URL via the DomainMapping. `rbac.yaml`
grants exactly the verbs the deploy path needs in `personal` (Knative Services,
DomainMappings, release ConfigMaps). `secret.example.yaml` is the webhook-secret
template.

```bash
kubectl apply -f cluster/bootstrap/nagared/rbac.yaml
cp cluster/bootstrap/nagared/secret.example.yaml /tmp/nagared-secret.yaml   # edit, then:
kubectl apply -f /tmp/nagared-secret.yaml
kubectl apply -f cluster/bootstrap/nagared/service.yaml
```

### Runtime requirements (not turnkey)

The deploy path shells out to `docker`, `kubectl`, and `git`, and loads the typed
config with `runghc`. The `nagared` image must therefore provide a Docker daemon
(or a rootless/buildkit equivalent), `git`, and a GHC package environment for the
loader (`--ghc-env`); `kubectl` uses the mounted ServiceAccount token. On a
single-node personal PaaS it is often simpler to run `nagared` on the host (where
the Docker daemon and toolchain already live) and expose it through Kourier with
an ExternalName/Ingress, rather than in a privileged pod. The manifests here are
the starting point.

## Configure the GitHub webhook

In the repository settings → Webhooks → Add webhook:

- **Payload URL**: `https://hooks.apps.example.com/webhooks/github/static/<site>`
- **Content type**: `application/json`
- **Secret**: the same value as the `webhook-secret` key in the Secret
- **Events**: "Just the push event" plus "Pull requests" for previews
