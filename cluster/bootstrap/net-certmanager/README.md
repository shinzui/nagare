# net-certmanager (EP-4 Milestone 3)

net-certmanager is the bridge controller that lets Knative request certificates
from cert-manager automatically (per namespace). It watches Knative's internal
`Certificate`/`KCert` objects and creates matching cert-manager `Certificate`
resources, which the `letsencrypt-dns` ClusterIssuer fulfils via DNS-01.

## Install

The controller is pinned independently at v1.14.0 in the Knative release GCS
bucket. On 2026-08-24, the authoritative `knative/serving` v1.22.0 release asset
list contained six serving manifests and no `net-certmanager.yaml`, while this
GCS artifact still returned HTTP 200. Therefore it cannot be versioned from
`knative_version` and the independent pin remains evidence-based rather than an
assumed lockstep release.

```bash
kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.14.0/net-certmanager.yaml
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
```

Before changing the pin, inspect both sources again:

```bash
gh release view knative-v1.22.0 -R knative/serving --json assets --jq '.assets[].name'
gsutil ls gs://knative-releases/net-certmanager/previous/
```

Compatibility: the v1.14.0 controller reconciles `networking.internal.knative.dev`
`Certificate` (KCert) objects, a stable API, so it coexists with Knative v1.22.
With `external-domain-tls` disabled it creates no certificates, so any latent
skew is inert until TLS is enabled.

It is configured by the `config-certmanager` ConfigMap patch in
`../knative-serving/config-certmanager.yaml` (which points `issuerRef` at the
`letsencrypt-dns` ClusterIssuer).

## Effect is gated on TLS being enabled

With `external-domain-tls` disabled (the HTTP-first state), Knative creates no
`KCert` objects, so net-certmanager idles and no certificates are requested.
Installing it now means enabling TLS later is a single `config-network` patch
(see `../knative-serving/README.md`).
