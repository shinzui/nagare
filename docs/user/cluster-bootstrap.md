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
| **`net-certmanager`** | The bridge that lets Knative request certs from cert-manager. |

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
cluster/bootstrap/knative-serving/config-certmanager.yaml
cluster/bootstrap/knative-serving/config-features.yaml
cluster/bootstrap/knative-serving/config-deployment.yaml
```

The webhook waits happen before their dependent ConfigMap patches and have explicit five-minute
deadlines, so an unhealthy installation stops before the platform is stamped complete. Each
idempotent Knative ConfigMap merge patch is also attempted at most five times with two seconds
between attempts. This absorbs the brief gap between a successful Deployment rollout and its
Service publishing an endpoint while still failing promptly when a patch is genuinely invalid.

For laptop development, use:

```bash
just local-up
just local-bootstrap
```

`local-bootstrap` installs cert-manager, Knative, Kourier, and net-certmanager,
but intentionally does not apply the GCP DNS-01 issuer or enable external-domain
TLS. It reads `NAGARE_BASE_DOMAIN` and `NAGARE_REGISTRY_HOST` from the active
local context. It uses the same bounded cert-manager and Knative Serving webhook waits and the same
bounded ConfigMap retry behavior; the cloud-only net-certmanager webhook gate protects the
cloud-only `config-certmanager` patch.

## DNS and TLS model

Nagare uses **one wildcard domain** for automatic app URLs and optional pretty
public domains on top.

```text
Automatic internal app domains:   service.namespace.<baseDomain>
                                  e.g. notes.personal.apps.example.com
Manual public domains (per app):  notes.example.com   (via Knative DomainMapping)
```

The wildcard `*.<baseDomain>` `A` record (created by Pulumi) points at the
static IP. For **wildcard TLS**, Nagare uses cert-manager with a Let's Encrypt
**DNS-01** challenge — HTTP-01 cannot issue wildcard certs. The DNS-01 solver
uses a **Google Cloud DNS** solver authorized by the VM's `roles/dns.admin`
zone grant and project-level `roles/dns.reader`, and the wildcard is wired into
Knative via `net-certmanager` with `external-domain-tls: Enabled`.

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

## Next

Add metrics, logs, and traces:
**[Observability →](observability.md)**
