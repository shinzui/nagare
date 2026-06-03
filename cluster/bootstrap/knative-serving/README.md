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
kubectl -n knative-serving rollout status deploy/controller
kubectl -n knative-serving rollout status deploy/webhook
```

Then install Kourier (see `../kourier/README.md`) and net-certmanager (see
`../net-certmanager/README.md`).

## ConfigMap patches (applied onto the upstream-installed ConfigMaps)

- `config-network.yaml` — selects Kourier as the ingress class. **Applied** in
  the HTTP-first bootstrap.
- `config-domain.yaml` — sets the public base domain (key=domain, value empty).
  Render the real `baseDomain` before applying (see the file header).
- `config-network-tls.yaml` — enables automatic per-namespace wildcard TLS.
  **Deferred** — apply only after a real domain is delegated.
- `config-certmanager.yaml` — points the net-certmanager bridge at the
  `letsencrypt-dns` ClusterIssuer. Applied (inert until TLS is enabled).

## Apply order

```bash
# ingress class
kubectl -n knative-serving patch configmap config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
# base domain (render the real one)
BASE_DOMAIN=$(pulumi -C infra/pulumi stack output baseDomain)
kubectl -n knative-serving patch configmap config-domain \
  --type merge --patch "{\"data\":{\"${BASE_DOMAIN}\":\"\"}}"
kubectl -n knative-serving patch configmap config-domain \
  --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
# cert-manager bridge issuer (inert until TLS enabled)
kubectl -n knative-serving patch configmap config-certmanager \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
```

## Enabling TLS later (deferred)

Once a real `baseDomain` is set and delegated (see
`../cert-manager/README.md`), enable automatic HTTPS with a single patch:

```bash
kubectl -n knative-serving patch configmap config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
# Knative then requests *.<namespace>.<baseDomain> certs; cert-manager fulfils
# them via DNS-01. Watch: kubectl get certificate -A -w
```
