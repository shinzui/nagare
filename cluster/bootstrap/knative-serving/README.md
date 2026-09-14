# Knative Serving (EP-4 Milestone 2/3)

Knative Serving turns a container image plus a small manifest into an
auto-scaling, scale-to-zero web service. A *Knative Service* (`ksvc`,
`serving.knative.dev/v1`) expands into a Deployment, autoscaler, routing, and a
public URL.

## Install

Pinned version: **knative-v1.22.0**. To find the latest:
`gh release list -R knative/serving`.

```bash
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-core.yaml
kubectl -n knative-serving rollout status deploy/controller --timeout=5m
kubectl -n knative-serving rollout status deploy/webhook --timeout=5m
```

Then install Kourier (see `../kourier/README.md`) and net-certmanager (see
`../net-certmanager/README.md`).

## ConfigMap patches (applied onto the upstream-installed ConfigMaps)

- `config-network.yaml` — selects Kourier as the ingress class. **Applied** in
  the HTTP-first bootstrap.
- `config-domain.yaml` — sets the public base domain (key=domain, value empty).
  Render the real `baseDomain` before applying (see the file header).
- `config-network-tls.yaml` — enables automatic wildcard TLS only for namespaces labeled
  `nagare.dev/app-namespace=true`. **Deferred** — apply only after a real domain is delegated.
- `config-certmanager.yaml` — routes external-domain certificates to the context-owned
  `letsencrypt-dns` ClusterIssuer and routes cluster-local and system-internal certificates to
  `knative-selfsigned-issuer`. Applied during bootstrap (external issuance remains inert until TLS
  is enabled).
- `config-features.yaml` — enables PVC volume + read-write mounts (EP-33).
  **Applied** to allow Nagare apps to mount durable `local-path` storage.
- `config-deployment.yaml` — adds the Artifact Registry host to
  `registriesSkippingTagResolving` so Knative defers PRIVATE-image tag→digest
  resolution to (authenticated) containerd instead of failing controller-side
  with an auth error (EP-2). **Applied.** Its host is substituted from
  `$NAGARE_REGISTRY_HOST` at apply time.

## Apply order

Bootstrap waits for `deploy/webhook` before submitting any Knative-owned ConfigMap change. Merge
patches run through `scripts/retry-knative-configmap-patch.sh`, which makes at most five attempts two
seconds apart. This covers the short interval in which a rolled-out webhook Deployment may not yet
have a published Service endpoint. The direct JSON removal stays best-effort because an already
absent `svc.cluster.local` key is the desired state.

```bash
# ingress class
scripts/retry-knative-configmap-patch.sh config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
# base domain (render the real one)
BASE_DOMAIN=$(pulumi -C infra/pulumi stack output baseDomain)
scripts/retry-knative-configmap-patch.sh config-domain \
  --type merge --patch "{\"data\":{\"${BASE_DOMAIN}\":\"\"}}"
kubectl -n knative-serving patch configmap config-domain \
  --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
# cert-manager bridge issuer (inert until TLS enabled)
scripts/retry-knative-configmap-patch.sh config-certmanager \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
# PVC volume support (EP-33)
scripts/retry-knative-configmap-patch.sh config-features \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
# private-image admission: skip controller-side tag resolution for the AR host (EP-2)
REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
scripts/retry-knative-configmap-patch.sh config-deployment \
  --type merge --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
```

## Enabling TLS later (deferred)

Once a real `baseDomain` is set and delegated (see
`../cert-manager/README.md`), enable automatic HTTPS with a single patch:

```bash
kubectl -n knative-serving patch configmap config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
# Knative then requests *.<namespace>.<baseDomain> only for namespaces labeled
# nagare.dev/app-namespace=true; cert-manager fulfils them via DNS-01.
# Watch: kubectl get certificate -A -w
```

Nagare workload commands reconcile that opt-in label before creating application resources. Do not
label control-plane or observability namespaces: each public wildcard consumes certificate-authority
rate budget and publishes the namespace-derived name to Certificate Transparency logs.
