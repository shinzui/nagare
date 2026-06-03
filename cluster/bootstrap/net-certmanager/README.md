# net-certmanager (EP-4 Milestone 3)

net-certmanager is the bridge controller that lets Knative request certificates
from cert-manager automatically (per namespace). It watches Knative's internal
`Certificate`/`KCert` objects and creates matching cert-manager `Certificate`
resources, which the `letsencrypt-dns` ClusterIssuer fulfils via DNS-01.

## Install

net-certmanager release artifacts left GitHub after v1.14.0, so the canonical
source is the Knative GCS bucket. Version tracks the Knative line
(**v1.22.0**). Confirm the current path on the Knative "Configure cert-manager
integration" install page.

```bash
kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.22.0/net-certmanager.yaml
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
```

It is configured by the `config-certmanager` ConfigMap patch in
`../knative-serving/config-certmanager.yaml` (which points `issuerRef` at the
`letsencrypt-dns` ClusterIssuer).

## Effect is gated on TLS being enabled

With `external-domain-tls` disabled (the HTTP-first state), Knative creates no
`KCert` objects, so net-certmanager idles and no certificates are requested.
Installing it now means enabling TLS later is a single `config-network` patch
(see `../knative-serving/README.md`).
