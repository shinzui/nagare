# hello — example Knative service (EP-4)

A minimal scale-to-zero web service used to validate the cluster ingress/TLS
path, and the reference artifact EP-6's `nagarectl` renders against.

## Files

- `nagare/Config.hs` — the app contract: a typed, compile-checked
  config-as-program (the substrate chosen by MasterPlan 2 / EP-8). It imports
  the `nagare-dsl` library and binds a `Deployment` through maximal-safety smart
  constructors, so an invalid service name, a `max < min` scale, a malformed
  CPU/memory quantity, or an env var that is both a literal and a secret
  reference is a **compile-time or load-time error**, never a silent cluster
  rejection. This replaced the former untyped `nagare.yaml` in the EP-12 cutover
  (see `docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`).
- `service.yaml` — the rendered `serving.knative.dev/v1` Service, kept as a
  reference manifest (it is what `nagarectl deploy` renders from `Config.hs`).
  `min`/`max` scale become `autoscaling.knative.dev/{min,max}-scale` annotations.
- `domainmapping.yaml` — a `serving.knative.dev/v1beta1` DomainMapping mapping a
  custom hostname (`hello.example.com`) onto the service.

## Preview the rendered manifest (no cluster)

`nagarectl deploy --dry-run` compiles-and-runs `nagare/Config.hs` and prints the
Knative Service (and DomainMapping) YAML plus the computed URL, without touching
the cluster:

```bash
# From cli/nagarectl/ (where `cabal build` materialised a .ghc.environment.* so
# the loader's runghc can resolve nagare-dsl):
cabal run -v0 nagarectl -- deploy --dry-run \
  --file ../../cluster/examples/hello-knative-service/nagare/Config.hs
```

To run from this directory instead, point the loader at a built GHC package
environment: `nagarectl deploy --dry-run --ghc-env <path-to-.ghc.environment.*>`
(or export `NAGARE_GHC_ENVIRONMENT`).

## Deploy and test (HTTP)

```bash
export KUBECONFIG=/tmp/nagare-kubeconfig.yaml   # see EP-4 M0 / MasterPlan access note
kubectl apply -f cluster/examples/hello-knative-service/service.yaml
kubectl -n personal get ksvc hello -w           # wait for READY=True

BASE_DOMAIN=$(pulumi -C infra/pulumi stack output baseDomain)
PUBLIC_IP=$(pulumi -C infra/pulumi stack output publicIp)

# DNS for *.apps.example.com is the placeholder zone; prove routing by sending
# the Host header to the VM's IP directly:
curl -i --resolve hello.personal.${BASE_DOMAIN}:80:${PUBLIC_IP} \
  http://hello.personal.${BASE_DOMAIN}
# Expect: HTTP/1.1 200 OK, body "Hello Nagare!"
```

## DomainMapping (HTTP)

```bash
kubectl apply -f cluster/examples/hello-knative-service/domainmapping.yaml
kubectl -n personal get domainmapping hello.example.com
curl -i --resolve hello.example.com:80:${PUBLIC_IP} http://hello.example.com
# Expect: 200, "Hello Nagare!"
```

## HTTPS (deferred)

Real Let's Encrypt HTTPS needs a real `baseDomain` delegated to the Cloud DNS
zone; see `../../bootstrap/cert-manager/README.md`. Once enabled,
`curl -v https://hello.personal.<baseDomain>` returns HTTP/2 200 behind a
browser-trusted wildcard cert.

## Cleanup

```bash
kubectl delete -f cluster/examples/hello-knative-service/domainmapping.yaml
kubectl delete -f cluster/examples/hello-knative-service/service.yaml
```
