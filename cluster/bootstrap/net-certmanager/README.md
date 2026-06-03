# net-certmanager (EP-4 Milestone 3)

net-certmanager is the bridge controller that lets Knative request certificates
from cert-manager automatically (per namespace). It watches Knative's internal
`Certificate`/`KCert` objects and creates matching cert-manager `Certificate`
resources, which the `letsencrypt-dns` ClusterIssuer fulfils via DNS-01.

## Install

net-certmanager release artifacts left GitHub after v1.14.0, and its version
line **diverged from Knative's and froze at v1.14.0** — the Knative GCS bucket's
`net-certmanager/latest/` and newest `previous/` both resolve to **v1.14.0**
(April 2024). So v1.14.0 is the current net-certmanager even against Knative
Serving v1.22; there is no v1.22.0 net-certmanager. To check for a newer one:
`gsutil ls gs://knative-releases/net-certmanager/previous/`.

```bash
kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.14.0/net-certmanager.yaml
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
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
