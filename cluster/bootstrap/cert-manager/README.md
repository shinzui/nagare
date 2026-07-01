# cert-manager (EP-4 Milestone 1)

cert-manager obtains and renews TLS certificates from Let's Encrypt. In Nagare
it issues one **wildcard** certificate per Kubernetes namespace
(`*.<namespace>.<baseDomain>`) via a Let's Encrypt **DNS-01** challenge against
the project's Google Cloud DNS zone, authorized by the VM's attached service
account (`roles/dns.admin`, granted by EP-2). DNS-01 is required because it is
the only ACME challenge type that can issue wildcard certificates.

## Install

Pinned version: **v1.20.2** (current as of June 2026). To find the latest:
`gh release list -R cert-manager/cert-manager`.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector
```

## Files

- `letsencrypt-dns.yaml.tmpl` — the cluster-wide DNS-01 `ClusterIssuer`
  (`letsencrypt-dns`). Uses ambient Application Default Credentials (no
  `serviceAccountSecretRef`). Apply it and confirm it becomes Ready (this only
  registers/validates the ACME account; it does not require DNS access):

  ```bash
  cluster/bootstrap/render-context-template.sh cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl | kubectl apply -f -
  kubectl get clusterissuer letsencrypt-dns -o wide   # READY=True within a minute
  ```

- `test-wildcard-cert.yaml` — a throwaway proof-of-issuance `Certificate`.
  **Deferred** until a real `baseDomain` is delegated (see the file header and
  the note below); the placeholder `apps.example.com` cannot pass DNS-01.

## TLS status: deferred (HTTP-first)

The apps base domain is currently the placeholder `apps.example.com`, whose
real authoritative nameservers are not this Cloud DNS zone, so Let's Encrypt
DNS-01 cannot validate. The `ClusterIssuer` is installed and Ready (ACME
account registered), but no certificate is issued yet. To enable real HTTPS
once you own and delegate a domain:

1. Set the real domain: `pulumi -C infra/pulumi config set baseDomain apps.yourdomain.com`, `pulumi up` (recreates the zone), then delegate that name to the zone's Cloud DNS nameservers at your registrar.
2. (Optional) apply `test-wildcard-cert.yaml` (rendered with the real domain) to prove issuance, then delete it.
3. Enable Knative auto-TLS: apply `cluster/bootstrap/knative-serving/config-network-tls.yaml` (see that directory's README).
