# net-certmanager (EP-138)

net-certmanager is the bridge controller that lets Knative request certificates
from cert-manager automatically (per namespace). It watches Knative's internal
`Certificate`/`KCert` objects and creates matching cert-manager `Certificate`
resources, which the `letsencrypt-dns` ClusterIssuer fulfils via DNS-01.

## Install

The manifests are pinned independently at v1.14.0 in the Knative release GCS
bucket. On 2026-09-14, the authoritative release API, tags, and GCS prefix all
confirmed v1.14.0 (source tag v0.41.0, commit
`dcff3644e7037215a084af52905fb0e9e78bab52`) as the latest and final release;
the `knative-extensions/net-certmanager` repository is archived. Knative Serving
v1.22.0 has no `net-certmanager.yaml` asset, so this independent pin cannot be
derived from `knative_version`.

That release aliases the default pointers for `issuerRef`,
`clusterLocalIssuerRef`, and `systemInternalIssuerRef`. Configuring three
different roles therefore lets the last value overwrite all three. Current
upstream `main` retains the defect. Nagare carries the focused source patch at
`patches/0001-use-distinct-default-issuer-references.patch`, including a combined
upstream regression case. The owning upstream project is
`mori://knative-extensions/net-certmanager`; artifact-level Mori coverage for
`pkg/reconciler/certificate/config/cert_manager.go` is pending.

Nix fetches that exact release commit, applies the patch, builds a Linux/amd64
controller, and creates the local-only image reference
`nagare/net-certmanager-controller:v1.14.0-nagare.1`. Every immutable
`nagare-platform` payload includes the resulting Docker archive. Bootstrap
applies the latest upstream manifest (retaining its webhook), imports the
bundled controller archive directly into k3s/containerd, and patches only the
controller Deployment within the reviewed inventory operation. There is no
mutable registry tag or separate fork to keep synchronized.

```bash
review_dir="$(mktemp -d)"
nagarectl platform bootstrap plan --out "$review_dir"
nagarectl platform bootstrap apply "$review_dir" --yes
```

Before changing the pin, inspect both sources again:

```bash
gh api repos/knative-extensions/net-certmanager
gh release list -R knative-extensions/net-certmanager
git ls-remote https://github.com/knative-extensions/net-certmanager.git refs/tags/v0.41.0 refs/heads/main
gsutil ls gs://knative-releases/net-certmanager/previous/
```

Compatibility: the patched v1.14.0 controller reconciles `networking.internal.knative.dev`
`Certificate` (KCert) objects, a stable API, so it coexists with Knative v1.22.
With `external-domain-tls` disabled it creates no certificates, so any latent
skew is inert until TLS is enabled.

It is configured by the `config-certmanager` ConfigMap patch in
`../knative-serving/config-certmanager.yaml`. External-domain certificates use the context-owned
`letsencrypt-dns` ClusterIssuer; cluster-local and system-internal certificates explicitly use
`knative-selfsigned-issuer`. Bootstrap orders the reviewed ConfigMap update
after the webhook is available and uses a conditional Kubernetes write.

Build the archive and run its native upstream regression case with:

```bash
nix build .#net-certmanager-controller-image
nix build .#checks.x86_64-linux.net-certmanager-controller --print-build-logs
```

## Effect is gated on TLS being enabled

With `external-domain-tls` disabled (the HTTP-first state), Knative creates no
`KCert` objects, so net-certmanager idles and no certificates are requested.
Installing it now means enabling TLS later is a single `config-network` patch
(see `../knative-serving/README.md`).
