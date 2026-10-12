# nagared — Git webhook runner (EP-16)

`nagared` deploys static sites automatically from GitHub events. It verifies the
webhook HMAC-SHA256 signature, checks out the named commit, selects its accepted
OCI image publication, and invokes the reviewed `nagarectl site` command:

- a push to the configured production branch → production deploy + release record;
- a pull request `opened`/`synchronize`/`reopened` → preview deploy named `pr-<number>`.

The runner requires a named active context and initialized inventory history.
The exact `<image>:<first-12-SHA>` tag must already be an accepted OCI publication;
the runner does not build or push it. Pull-request previews also require the
four accepted Runtime and Preview ConfigMap/Secret stores. It rechecks store
availability before submitting the reviewed command, and the command validates
accepted dependencies again. In cloud mode the context must use a shared GCS
inventory store. The example in-cluster Service manifest has no named context
mounted and therefore cannot deploy until its context and store are configured.

## Routes

```text
GET  /healthz                          -> 200 ("ok")
POST /webhooks/github/static/<site>    -> verify signature, checkout, deploy
```

An unsigned or mis-signed request is rejected with 401 **before** the body is
parsed or any deploy runs. A push to a non-production branch or a non-deploy PR
action returns 200 with a no-op message. An interrupted reviewed apply resumes
through the inventory journal.

## Local run

```bash
cd cli/nagarectl
NAGARE_CONTEXT=my-context NAGARE_WEBHOOK_SECRET=dev-secret cabal run nagared -- --port 8088 --production-branch main
# health check
curl -s localhost:8088/healthz            # -> ok
# signed ping (GitHub-compatible HMAC):
BODY='{"zen":"x"}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac dev-secret | sed 's/^.*= //')"
curl -s -XPOST localhost:8088/webhooks/github/static/demo \
  -H "X-GitHub-Event: ping" -H "X-Hub-Signature-256: $SIG" --data "$BODY"   # -> pong
```

## Cluster deploy

`service.yaml` runs nagared as an always-on Knative Service, exposed through
Kourier and cert-manager with a stable hook URL via the DomainMapping.
`secret.example.yaml` is the webhook-secret template. The example `rbac.yaml`
is a starting point; reviewed scope execution needs permissions for every
resource type in the submitted site scope.

```bash
kubectl apply -f cluster/bootstrap/nagared/rbac.yaml
cp cluster/bootstrap/nagared/secret.example.yaml /tmp/nagared-secret.yaml   # edit, then:
kubectl apply -f /tmp/nagared-secret.yaml
cluster/bootstrap/render-context-template.sh cluster/bootstrap/nagared/service.yaml | kubectl apply -f -
```

### Runtime requirements (not turnkey)

The runner needs `git`, `nagarectl` (or `--nagarectl-bin`), `runghc`, and a GHC
package environment for the config loader (`--ghc-env`). The reviewed command
also needs access to the selected inventory store and its Kubernetes provider.
Publish the exact commit-tagged OCI image with `app image-plan` and apply its
review before the webhook arrives. Supply a named context and shared GCS store
configuration to an in-cluster runner. The manifests here are a starting point;
they do not provision the binary, context, store credentials, or complete RBAC.

## Configure the GitHub webhook

In the repository settings → Webhooks → Add webhook:

- **Payload URL**: `https://hooks.apps.example.com/webhooks/github/static/<site>`
- **Content type**: `application/json`
- **Secret**: the same value as the `webhook-secret` key in the Secret
- **Events**: "Just the push event" plus "Pull requests" for previews
