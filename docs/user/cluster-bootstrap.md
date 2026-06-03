# Cluster bootstrap

> **Status:** 🔭 Planned (EP-4) — **not built yet.**
>
> This is a *target* runbook describing the intended bootstrap. The manifests
> under `cluster/bootstrap/` do not exist on disk yet (the directory is a
> placeholder), and the `just cluster-bootstrap` recipe references paths that
> EP-4 will create. Treat every command here as the design, not a working step,
> until EP-4 lands. The authoritative status is the MasterPlan Progress section.

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

- A healthy node: [host booted](host-image-and-boot.md), `kubectl get nodes` =
  `Ready`, and a working [kubeconfig](accessing-the-host.md#getting-a-working-kubectl).
- The Pulumi perimeter applied, providing the **DNS zone**
  (`pulumi stack output dnsZoneName`) and the service account with
  `roles/dns.admin`.
- Your `baseDomain` zone **delegated** from your registrar to the Cloud DNS
  nameservers (so Let's Encrypt and real traffic resolve).

## Run it

```bash
just cluster-bootstrap
```

which (per the `justfile`) applies, in order:

```bash
kubectl apply -f cluster/bootstrap/cert-manager
kubectl apply -f cluster/bootstrap/knative-serving
kubectl apply -f cluster/bootstrap/kourier
kubectl apply -f cluster/bootstrap/config-domain
```

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
service account, and the wildcard is wired into Knative via `net-certmanager`
with `external-domain-tls: Enabled`.

> This is a deliberate override of the spec's "start with host-level Caddy"
> suggestion: Nagare chose the Kubernetes-native cert-manager + Kourier path.
> See the [spec corrections](../initial-spec.md#spec-accuracy-corrections-2026-06-02).

`DomainMapping` (`serving.knative.dev/v1beta1`) is enabled by default — no
feature flag — and maps a custom hostname onto a Knative service.

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
