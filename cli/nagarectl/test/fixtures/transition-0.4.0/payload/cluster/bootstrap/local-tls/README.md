# Local-mode TLS issuer (`nagare-local-ca`)

Local-mode counterpart to the cloud DNS-01 Let's Encrypt issuer. It exists so the
loopback apps domain (`*.<ns>.127-0-0-1.sslip.io`) is reachable over HTTPS the
developer's browser trusts — which is what makes **WebAuthn** (the Shomei passkey
second factor) usable locally, since WebAuthn only runs in a browser "secure
context" (HTTPS, or the literal host `localhost`). A loopback *wildcard* domain is
not `localhost`, so plain HTTP would block the passkey ceremony. See MasterPlan 16
Integration Point 5 and `docs/plans/85-local-auth-plane-and-tls-for-nagare-protected-apps.md`.

## What this installs

`clusterissuer.yaml` bootstraps a private CA entirely inside cert-manager — no
extra host tooling required:

1. `nagare-local-selfsigned` — a `selfSigned` `ClusterIssuer`.
2. `nagare-local-ca` — a 10-year CA `Certificate` (`isCA: true`) signed by it,
   stored in the Secret `nagare-local-ca` in the `cert-manager` namespace
   (cert-manager's `--cluster-resource-namespace`, where a `ca` `ClusterIssuer`
   reads its signing key).
3. `nagare-local-ca` — a `ca` `ClusterIssuer` that signs leaf certs from that CA.

A `ca` issuer mints **wildcard** certs with no ACME challenge, so Knative's
per-namespace wildcard auto-TLS (`*.<ns>.<base>`) works locally once
`config-certmanager`/`config-network` are repointed at it (see below).

> **mkcert alternative.** If you prefer [`mkcert`](https://github.com/FiloSottile/mkcert)
> (it installs the CA into the OS *and* browser trust stores for you, including
> Firefox/Chrome NSS), create the issuer Secret from mkcert's root instead of the
> self-signed bootstrap:
> ```bash
> mkcert -install
> CAROOT="$(mkcert -CAROOT)"
> kubectl -n cert-manager create secret tls nagare-local-ca \
>   --cert="$CAROOT/rootCA.pem" --key="$CAROOT/rootCA-key.pem"
> kubectl apply -f cluster/bootstrap/local-tls/clusterissuer.yaml  # keeps only the `ca` ClusterIssuer
> ```
> Then skip the manual trust-store import below — mkcert already did it.

## Install

```bash
kubectl apply -f cluster/bootstrap/local-tls/clusterissuer.yaml
kubectl -n cert-manager wait --for=condition=Ready certificate/nagare-local-ca --timeout=60s

# Repoint Knative's cert-manager bridge at the local CA and enable auto-TLS:
kubectl -n knative-serving patch configmap config-certmanager --type merge \
  --patch "$(cat cluster/bootstrap/local-tls/config-certmanager-local.yaml)"
kubectl -n knative-serving patch configmap config-network --type merge \
  --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
```

Knative issues the per-namespace wildcard cert lazily, the first time an app in
that namespace is deployed with external-domain-tls enabled.

## Trust the CA root on your machine

Needed only to use a real browser (WebAuthn / M4). Automated `curl` checks can use
`--cacert` against the exported root and skip this.

```bash
kubectl -n cert-manager get secret nagare-local-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/nagare-local-ca.pem
```

- **macOS** (system keychain; trusted by Safari and Chrome):
  ```bash
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain /tmp/nagare-local-ca.pem
  ```
  Firefox uses its own store: import `/tmp/nagare-local-ca.pem` under
  Settings → Privacy & Security → Certificates → View Certificates → Authorities.
- **Linux** (Debian/Ubuntu):
  ```bash
  sudo cp /tmp/nagare-local-ca.pem /usr/local/share/ca-certificates/nagare-local-ca.crt
  sudo update-ca-certificates
  ```
  Firefox/Chrome NSS may need a separate `certutil -A` import.

## Teardown

```bash
kubectl delete -f cluster/bootstrap/local-tls/clusterissuer.yaml
kubectl -n cert-manager delete secret nagare-local-ca
# macOS: remove the trusted root
sudo security delete-certificate -c nagare-local-ca /Library/Keychains/System.keychain
```

None of this touches the cloud path: the cloud `letsencrypt-dns` issuer and the
cloud `config-certmanager`/`config-network` values are unchanged in git and apply
only in cloud mode.
