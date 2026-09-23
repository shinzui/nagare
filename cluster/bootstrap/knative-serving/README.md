# Knative Serving (EP-4 Milestone 2/3)

Knative Serving turns a container image plus a small manifest into an
auto-scaling, scale-to-zero web service. A *Knative Service* (`ksvc`,
`serving.knative.dev/v1`) expands into a Deployment, autoscaler, routing, and a
public URL.

## Install

Pinned version: **knative-v1.22.0**. The packaged release manifests and digests
are bound into the bootstrap review.

```bash
review_dir="$(mktemp -d)"
nagarectl platform bootstrap plan --out "$review_dir"
nagarectl platform bootstrap apply "$review_dir" --yes
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

Bootstrap compiles the packaged Knative ConfigMaps into the platform inventory. Their
reviewed updates wait for the Serving webhook and use exact retained native bytes and
conditional Kubernetes writes. The compiled `config-domain` removes the default
`svc.cluster.local` key as part of its desired state.

```bash
just cluster-bootstrap
```

## Enabling TLS later (deferred)

Once a real `baseDomain` is set and delegated (see
`../cert-manager/README.md`), persist the cloud TLS policy and review its
bootstrap update:

```bash
nagarectl context create NAME --force --enable-external-tls
just cluster-enable-tls
# Knative then requests *.<namespace>.<baseDomain> only for namespaces labeled
# nagare.dev/app-namespace=true; cert-manager fulfils them via DNS-01.
# Watch: kubectl get certificate -A -w
```

Nagare workload commands reconcile that opt-in label before creating application resources. Do not
label control-plane or observability namespaces: each public wildcard consumes certificate-authority
rate budget and publishes the namespace-derived name to Certificate Transparency logs.
