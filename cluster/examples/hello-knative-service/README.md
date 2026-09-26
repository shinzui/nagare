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
- `service.yaml` and `domainmapping.yaml` — historical example manifests for
  inspection. They are not deployment inputs; the reviewed command compiles
  `Config.hs` and binds the selected context's accepted image publication.

## Preview the rendered manifest (no cluster)

`nagarectl deploy --dry-run` compiles `nagare/Config.hs` against an accepted
image publication and prints the public scope without changing the cluster:

```bash
# From cli/nagarectl/ (where `cabal build` materialised a .ghc.environment.* so
# the loader's runghc can resolve nagare-dsl):
cabal run -v0 nagarectl -- deploy --dry-run --tag sample-v1 \
  --image-resource publication:app-image-hello-sample-v1/hello-sample-v1/oci-image \
  --file ../../cluster/examples/hello-knative-service/nagare/Config.hs
```

To run from this directory instead, point the loader at a built GHC package
environment: `nagarectl deploy --dry-run --ghc-env <path-to-.ghc.environment.*>`
(or export `NAGARE_GHC_ENVIRONMENT`).

## Deploy and test (HTTP)

Publish the chosen hello image archive to the selected context registry with
`nagarectl app image-plan --archive FILE --destination PREFIX/hello:sample-v1
--key hello-sample-v1`. `PREFIX` is the selected context's
`NAGARE_REGISTRY_PREFIX`; the archive and resulting publication are bound by
digest. See [Deploying applications](../../../docs/user/deploying-apps.md) for
the image publication procedure. The example config uses the short image name
`hello`, which the CLI qualifies under that prefix. Replace `sample-v1` and the
resource ID together when publishing a different image.

```bash
export KUBECONFIG=/tmp/nagare-kubeconfig.yaml
just deploy-hello publication:app-image-hello-sample-v1/hello-sample-v1/oci-image sample-v1
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

The reviewed deploy includes the declared `hello.example.com` DomainMapping.

```bash
kubectl -n personal get domainmapping hello.example.com
curl -i --resolve hello.example.com:80:${PUBLIC_IP} http://hello.example.com
# Expect: 200, "Hello Nagare!"
```

## HTTPS (deferred)

Real Let's Encrypt HTTPS needs a real `baseDomain` delegated to the Cloud DNS
zone; see `../../bootstrap/cert-manager/README.md`. Once enabled,
`curl -v https://hello.personal.<baseDomain>` returns HTTP/2 200 behind a
browser-trusted wildcard cert.

## Retirement

Retire the accepted standalone Service scope through a saved inventory review.
The first apply retains its provider objects; collect each retained member by
exact resource ID in a separate reviewed `inventory collect` operation. The
inventory status output supplies those IDs.

```bash
nagarectl app delete hello --save-plan hello-retirement
nagarectl inventory apply hello-retirement --yes
nagarectl inventory status
```
