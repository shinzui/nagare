---
type: Runbook
title: "Cluster bootstrap"
description: "Install, configure, smoke-test, and verify the Nagare Kubernetes platform components."
docId: DOC-8
tags: [cluster, bootstrap, kubernetes, knative, tls]
generated:
  by: human:nadeem
  at: 2026-08-23T20:57:05Z
---

# Cluster bootstrap

> **Status:** ✅ Cloud bootstrap is implemented and verified live. Local bootstrap
> is also implemented as `just local-bootstrap`, using the same Knative/Kourier
> stack with cloud-coupled DNS-01/TLS steps skipped.

Cluster bootstrap turns the bare k3s node into an app platform: **Knative
Serving** (one image → a scale-to-zero web service), **Kourier** (the Knative
ingress, backed by Envoy), and **cert-manager** (TLS from Let's Encrypt),
wired together so apps get automatic wildcard HTTPS URLs.

---

## What gets installed

| Component | Role |
| --- | --- |
| **cert-manager** | Obtains TLS certificates from Let's Encrypt. |
| **Knative Serving** | The serverless app runtime (Revisions, scale-to-zero, traffic routing). ~v1.22. |
| **Kourier** (`net-kourier`) | Knative's lightweight Envoy-based ingress gateway. |
| **`config-domain` / `config-network`** | ConfigMaps wiring the base domain, the Kourier ingress class, and `external-domain-tls`. |
| **`net-certmanager`** | The latest v1.14 bridge, with Nagare's issuer-isolation patch, that lets Knative request certs from cert-manager. |

On a single k3s node, Kourier's gateway `Service` is `type: LoadBalancer`, and
k3s's built-in **ServiceLB** binds host ports `80`/`443` directly to it — which
is why the Pulumi firewall opens `80`/`443` to the world and why ServiceLB is
kept enabled (only Traefik is disabled).

## Prerequisites

- A healthy node: [host booted](host-image-and-boot.md), a context-specific
  [kubeconfig](accessing-the-host.md#getting-a-working-kubectl), and
  `nagarectl cluster guard --context <name>` succeeding before `kubectl get nodes` reports `Ready`.
- The Pulumi perimeter applied, providing the **DNS zone**
  (`pulumi stack output dnsZoneName`) and the service account with
  `roles/dns.admin` on that zone plus project-level `roles/dns.reader` for zone
  discovery.
- Your `baseDomain` zone **delegated** from your registrar to the Cloud DNS
  nameservers (so Let's Encrypt and real traffic resolve).
- An **ACME contact** in the active context (`NAGARE_ACME_EMAIL`). There is no
  default: bootstrap refuses to create the `letsencrypt-dns` issuer without one.
  Check with `nagarectl context show | grep ACME`, and see
  [ACME identity](contexts.md#acme-identity).

## Run it

```bash
nagarectl kubeconfig fetch --context prod
export KUBECONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/prod.yaml"
nagare cluster-bootstrap
```

`cluster-bootstrap` first checks the selected platform/context and then runs the cluster identity
guard. It makes no Kubernetes change unless the active kube context is `prod` and the sole server
node is the context-owned host. The same fail-closed ordering protects `cluster-enable-tls`,
`job-runs-bootstrap`, `observability`, and `deploy-hello`; local-mode recipes keep their separate
local identity model.

which (per the `justfile`) creates namespaces and applies, in order:

```bash
cert-manager
wait up to 5m for cert-manager-webhook
rendered cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl
Knative Serving CRDs and core
wait up to 5m for the Knative Serving webhook
Kourier
cluster/bootstrap/knative-serving/config-network.yaml
config-domain from `pulumi stack output baseDomain`
net-certmanager
wait up to 5m for the net-certmanager webhook
import the payload's patched controller image directly into k3s and wait for its rollout
cluster/bootstrap/knative-serving/config-certmanager.yaml
cluster/bootstrap/knative-serving/config-features.yaml
cluster/bootstrap/knative-serving/config-deployment.yaml
```

The webhook waits happen before their dependent ConfigMap patches and have explicit five-minute
deadlines, so an unhealthy installation stops before the platform is stamped complete. Each
idempotent Knative ConfigMap merge patch is also attempted at most five times with two seconds
between attempts. This absorbs the brief gap between a successful Deployment rollout and its
Service publishing an endpoint while still failing promptly when a patch is genuinely invalid.
The controller archive is part of the immutable release payload: cloud bootstrap copies it through
the selected context's project-confined IAP transport and imports it with k3s; local bootstrap uses
`k3d image import`. Bootstrap never pulls a Nagare fork or a mutable patch tag from a registry.

For laptop development, use:

```bash
just local-up
just local-bootstrap
```

`local-bootstrap` installs cert-manager, Knative, Kourier, net-certmanager, and
the `nagare-local-ca` issuer, then enables external-domain TLS against that CA.
It never installs the GCP DNS-01 issuer or invokes `gcloud`. It reads
`NAGARE_BASE_DOMAIN` and `NAGARE_REGISTRY_HOST` from the active local context and
uses bounded webhook, issuer, and ConfigMap waits.

## DNS and TLS model

Nagare uses **one wildcard domain** for automatic app URLs and optional pretty
public domains on top.

```text
Automatic internal app domains:   service.namespace.<baseDomain>
                                  e.g. notes.personal.apps.example.com
Manual public domains (per app):  notes.example.com   (via Knative DomainMapping)
```

The wildcard `*.<baseDomain>` and exact `<baseDomain>` `A` records (created by
Pulumi) point at the VM unless the apex is assigned to Google CDN. For
**wildcard TLS**, Nagare uses cert-manager with a Let's Encrypt
**DNS-01** challenge — HTTP-01 cannot issue wildcard certs. The DNS-01 solver
uses a **Google Cloud DNS** solver authorized by the VM's `roles/dns.admin`
zone grant and project-level `roles/dns.reader`, and the wildcard is wired into
Knative via `net-certmanager` with `external-domain-tls: Enabled`.

Public wildcard eligibility is opt-in. A namespace must carry
`nagare.dev/app-namespace=true`; bootstrap labels `personal`, and Nagare's app,
worker, database, broker, task, and static-site deployment paths reconcile the
same label before creating namespaced resources. Control-plane and observability
namespaces are refused by that reconciler. The public `letsencrypt-dns` issuer
handles only external-domain certificates; cluster-local and system-internal
certificates explicitly use `knative-selfsigned-issuer`.

Explicit DomainMappings can cause exact certificates in addition to the
namespace wildcard that covers automatic Service URLs. Deploy success requires
the certificate appropriate to every `DomainTls` policy. Automatic TLS is
supported for the platform Cloud DNS zone and other authoritative zones in the
active project; external DNS authority needs its own solver or a supplied
namespace-local TLS Secret.

This boundary matters beyond readiness. Each unnecessary production wildcard
spends the registered domain's issuance budget, and every publicly trusted
certificate can expose its DNS names through Certificate Transparency. Do not
label a namespace merely to make a certificate appear.

### Upgrading a legacy wildcard selector

Nagare 0.2.2 enabled namespace wildcards with selector `{}`, which also issued public wildcard
certificates in system namespaces. A current `nagarectl platform upgrade` detects that exact legacy
state during its read-only Kubernetes diff phase. Review the transaction's private
`kubernetes-plan/review.json`: it lists application wildcard chains to preserve and exact obsolete
chains to remove. Apply narrows the selector before the bootstrap certificate-policy gate, waits for
the controllers to converge, and removes only still-identical orphaned generated Secrets.

Do not manually bulk-delete Certificate or Secret resources before planning; doing so discards the
identity evidence the guarded cleanup needs. If apply reports drift, inspect the named object and
make a fresh plan after deciding whether the change is legitimate. A controller timeout is
resumable after repair, and the previous platform pin remains active until the selector, resources,
and certificate policy all converge.

> This is a deliberate override of the spec's "start with host-level Caddy"
> suggestion: Nagare chose the Kubernetes-native cert-manager + Kourier path.
> See the [spec corrections](../initial-spec.md#spec-accuracy-corrections-2026-06-02).

### Where the issuer's identity comes from

The `letsencrypt-dns` `ClusterIssuer` is **rendered from the active target
context** — not from a packaged file you edit. Its `email:` is the context's
`NAGARE_ACME_EMAIL`, its `server:` comes from `NAGARE_ACME_DIRECTORY`, and the
project its DNS-01 solver writes into is the context's own project, checked by
the same fail-closed project guardrail every cloud-touching script uses.

With no contact configured, `nagare cluster-bootstrap` stops before `kubectl
apply` runs and prints:

```text
nagare: no ACME contact is configured for context 'prod'.
  Set NAGARE_ACME_EMAIL in the active context:
    nagarectl init <name> --acme-email you@example.com
    nagarectl context create <name> --acme-email you@example.com
```

Nothing is applied, so no cluster ends up with an account under an address its
operator did not choose. Confirm what landed:

```bash
kubectl get clusterissuer letsencrypt-dns \
  -o jsonpath='{.spec.acme.email}{"\n"}{.spec.acme.server}{"\n"}{.spec.acme.solvers[0].dns01.cloudDNS.project}{"\n"}'
```

### Rehearsing with Let's Encrypt staging

Let's Encrypt's production service applies per-domain issuance rate limits.
While iterating on DNS-01 for a **new** domain, point the context at staging —
certificates it issues are not browser-trusted, but the limits are far looser:

```bash
nagarectl context create prod --force --project YOUR_PROJECT_ID \
  --acme-email you@yourdomain.com --acme-directory staging
nagare cluster-bootstrap
```

Switch back to `--acme-directory production` once issuance works end to end.
Because an ACME account is keyed by its stored private key rather than by the
`email:` field, moving between services (or correcting a wrong address) also
means deleting the account key so cert-manager registers afresh:

```bash
kubectl -n cert-manager delete secret letsencrypt-dns-account-key
nagare cluster-bootstrap
```

`DomainMapping` (`serving.knative.dev/v1beta1`) is enabled by default — no
feature flag — and maps a custom hostname onto a Knative service. Local mode is
HTTP-first at `*.127-0-0-1.sslip.io`; local TLS for protected apps is tracked
separately.

## Smoke test

EP-4 ships a sample Knative service. Apply it and confirm HTTPS:

```bash
just deploy-hello       # kubectl apply -f cluster/examples/hello-knative-service
just status             # ksvc shows the hello service with a URL + Ready
curl https://hello.default.<baseDomain>
```

## Verify

The bootstrap is done when:

- cert-manager, Knative Serving, and Kourier pods are all `Running`.
- `kubectl get ksvc -A` shows the sample service `Ready` with a URL.
- That URL serves over **HTTPS** with a valid Let's Encrypt certificate.
- A second app at a different name resolves under the same wildcard without any
  per-app DNS work.
- `nagarectl cluster certificate-policy` exits zero: public wildcards exist only
  in labeled app namespaces, and no public ACME certificate contains a short,
  `.svc`, or `.svc.cluster.local` name. `nagarectl doctor` reports the same probe.

If a cluster previously used the broad selector, inventory stale objects before
deleting anything:

```bash
kubectl get certificate,certificaterequest,order -A \
  -o custom-columns='KIND:.kind,NAMESPACE:.metadata.namespace,NAME:.metadata.name,ISSUER:.spec.issuerRef.name'
kubectl get secret -A -l networking.knative.dev/certificate-type
```

Review owners and exact names, then delete only the obsolete Certificate,
CertificateRequest, Order, and matching Secret. Selector convergence does not
guarantee deletion of already-issued resources. Keep the context on Let's
Encrypt staging until the inventory and `certificate-policy` check are clean;
Nagare deliberately does not automate bulk certificate deletion.

## Next

Add metrics, logs, and traces:
**[Observability →](observability.md)**
