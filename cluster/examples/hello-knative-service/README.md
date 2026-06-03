# hello — example Knative service (EP-4)

A minimal scale-to-zero web service used to validate the cluster ingress/TLS
path, and the reference artifact EP-6's `nagarectl` renders against.

## Files

- `nagare.yaml` — the app contract (MasterPlan Integration Point 6 schema). EP-6
  parses this and generates the `service.yaml`/`domainmapping.yaml` shapes below.
- `service.yaml` — the rendered `serving.knative.dev/v1` Service. `min`/`max`
  scale become `autoscaling.knative.dev/{min,max}-scale` annotations.
- `domainmapping.yaml` — a `serving.knative.dev/v1beta1` DomainMapping mapping a
  custom hostname (`hello.example.com`) onto the service.

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
