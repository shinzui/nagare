---
id: 4
slug: knative-serving-kourier-ingress-and-cert-manager-tls
title: "Knative Serving Kourier ingress and cert-manager TLS"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# Knative Serving Kourier ingress and cert-manager TLS

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [4-knative-serving-kourier-ingress-and-cert-manager-tls.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan is finished, the single-node Nagare cluster can take any container image and
serve it on the public internet as an auto-scaling, scale-to-zero web service reachable over a
real HTTPS URL with a browser-trusted certificate. Concretely, an operator will be able to run
one `kubectl apply` against the example app shipped in this repository and then run
`curl https://hello.personal.apps.example.com` from their laptop and receive `HTTP/2 200` with a
"Hello World!" body, served behind a valid Let's Encrypt certificate that was obtained
automatically. That is the user-visible payoff: a project becomes a public HTTPS service without
anyone hand-writing ingress rules, requesting certificates, or editing DNS.

To make that work, this plan installs and wires together four pieces of cluster software on top
of the running k3s cluster that the prior plan (EP-3) produced:

1. **Knative Serving** — the component that turns a container image plus a tiny manifest into a
   "serverless" web service. A *Knative Service* (Kubernetes kind `Service` in API group
   `serving.knative.dev`, abbreviated `ksvc` on the command line — distinct from a plain
   Kubernetes core `Service`) automatically creates the Deployment, the autoscaler, and the
   routing so the app scales up on the first request and back down to zero pods when idle.
2. **Kourier** — the *ingress* for Knative. "Ingress" means the layer that accepts HTTP/HTTPS
   requests arriving from outside the cluster and routes each request to the right service inside
   the cluster based on the request's hostname. Kourier is a thin Knative-specific controller in
   front of Envoy (a fast C++ proxy); it programs Envoy from Knative's routing model so we do not
   have to write Envoy configuration by hand.
3. **cert-manager** — the component that obtains and renews TLS certificates from Let's Encrypt
   (the free public certificate authority). "TLS certificate" is the cryptographic document that
   makes `https://` work and shows a padlock in the browser instead of a security warning.
4. **net-certmanager** — the small "bridge" controller that connects Knative to cert-manager, so
   that when Knative needs a certificate for a service's hostname it asks cert-manager to produce
   one, automatically, per Kubernetes namespace.

The defining constraint, recorded in the MasterPlan Decision Log, is that we use the
Kubernetes-native TLS path (cert-manager + Kourier) rather than a host-level proxy such as Caddy.
That single decision forces a specific certificate-issuance technique, explained in detail below:
because we want one *wildcard* certificate covering every service in a namespace
(`*.personal.apps.example.com`), and Let's Encrypt will only issue a wildcard via a **DNS-01
challenge**, cert-manager must prove control of the domain by writing a temporary DNS TXT record
into the project's Google Cloud DNS zone. It is authorized to do that by the virtual machine's
attached Google service account, which the prior infrastructure plan (EP-2) granted the
`roles/dns.admin` IAM role.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**Operator decision (2026-06-02): HTTP-first.** The apps base domain is still the placeholder
`apps.example.com`, whose Cloud DNS zone is not the real authoritative zone for `example.com`, so
Let's Encrypt DNS-01 cannot validate. EP-4 therefore installs and wires the full stack and proves the
hello app over **HTTP**; the Let's Encrypt wildcard TLS items are **deferred** until a real domain is
delegated. Items marked DEFERRED below are the only remaining work, and they are gated solely on the
domain — the cluster wiring is in place so enabling TLS is one `config-network` patch
(`just cluster-enable-tls`).

Milestone 0 — Prerequisites and repository scaffolding:

- [x] Confirm EP-3 is deployed and `kubectl get nodes` shows the node `Ready`. (2026-06-02 — node
      Ready, k3s v1.35.4, NixOS 26.11. Cluster reached via an SSH local-forward to 127.0.0.1:6443; see
      Surprises.)
- [x] Confirm the Pulumi stack outputs `baseDomain`, `publicIp`, `serviceAccountEmail`, `dnsZoneName` are readable. (2026-06-02 — `apps.example.com`, `34.145.74.203`, `nagare-node@tan-nb-exp.iam.gserviceaccount.com`, `nagare-zone-e572adf`.)
- [x] Create the directory tree under `cluster/bootstrap/` and `cluster/examples/`. (2026-06-02)
- [x] Create the namespaces `cert-manager`, `knative-serving`, `kourier-system`, `personal`. (2026-06-02)

Milestone 1 — cert-manager + DNS-01 ClusterIssuer + test wildcard certificate:

- [x] Install cert-manager (v1.20.2) into namespace `cert-manager`. (2026-06-02 — controller/webhook/cainjector all Running.)
- [x] Apply the `ClusterIssuer` `letsencrypt-dns` (Cloud DNS DNS-01 solver, ambient creds). (2026-06-02)
- [x] Verify `kubectl get clusterissuer letsencrypt-dns` shows `READY=True`. (2026-06-02 — "The ACME account was registered with the ACME server".)
- [~] Issue a TEST `Certificate` for `*.apps.example.com`; verify `READY=True`. **DEFERRED** — cannot
      pass DNS-01 against the placeholder domain (Let's Encrypt queries the real public nameservers for
      example.com, not this zone). `test-wildcard-cert.yaml` is authored for when a real domain exists.
- [~] Delete the test `Certificate`. **DEFERRED** with the item above (never created).

Milestone 2 — Knative Serving + Kourier + config-domain + config-network (HTTP):

- [x] Apply `serving-crds.yaml` then `serving-core.yaml` (knative-v1.22.0). (2026-06-02 — controller/webhook/activator/autoscaler Running.)
- [x] Apply `kourier.yaml` (knative-v1.22.0). (2026-06-02 — gateway + controller Running.)
- [x] Patch `config-network` so `ingress-class: kourier.ingress.networking.knative.dev`. (2026-06-02 — also set `autocreate-cluster-domain-claims: "true"`, see Surprises.)
- [x] Patch `config-domain` so the key is `baseDomain` with empty value. (2026-06-02 — `apps.example.com: ""`.)
- [x] Verify all pods in `knative-serving` and `kourier-system` are `Running`. (2026-06-02)
- [x] Verify the Kourier gateway Service external IP. (2026-06-02 — shows the node **internal** IP
      `10.10.0.3` on GCE, not `publicIp`; ServiceLB binds the node and GCP 1:1-NATs the public IP. The
      functional proof is the curl below. See Surprises.)
- [x] Apply the rendered hello Knative Service; `kubectl get ksvc -n personal` is `Ready`. (2026-06-02 — URL `http://hello.personal.apps.example.com`.)
- [x] `curl http://hello.personal.apps.example.com` returns `200` with the hello body. (2026-06-02 — `HTTP/1.1 200 OK`, `Hello Nagare!` via `--resolve …:80:34.145.74.203`, served by Envoy.)

Milestone 3 — net-certmanager + external-domain-tls + per-namespace wildcard + HTTPS + DomainMapping:

- [x] Install net-certmanager from the Knative GCS bucket. (2026-06-02 — **v1.14.0**, not v1.22.0; the line froze at 1.14.0, see Surprises. Controller + webhook Running.)
- [x] Patch `config-certmanager` so `issuerRef` points at `letsencrypt-dns`. (2026-06-02 — inert while TLS is off.)
- [~] Patch `config-network` with `external-domain-tls: Enabled` and `namespace-wildcard-cert-selector: {}`. **DEFERRED** — authored as `config-network-tls.yaml` / `just cluster-enable-tls`; not applied (would request a wildcard cert that cannot issue for the placeholder domain).
- [~] Verify a `Certificate` `*.personal.apps.example.com` reaches `READY=True`. **DEFERRED** (domain).
- [~] `curl -v https://hello.personal.apps.example.com` shows a trusted cert and `200`. **DEFERRED** (domain).
- [x] Apply a `DomainMapping` for a custom domain and verify it routes to the hello service. (2026-06-02 — `hello.example.com` Ready; `curl --resolve …:80:34.145.74.203` returns `200`/`Hello Nagare!` over HTTP.)

Living-document upkeep:

- [x] Record surprises in Surprises & Discoveries. (2026-06-02)
- [x] Update the MasterPlan Progress line for EP-4 (HTTP done; TLS deferred). (2026-06-02)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The apps base domain is the placeholder `apps.example.com`, so Let's Encrypt DNS-01 (and thus all
  real HTTPS) is deferred.** EP-2's Cloud DNS zone `nagare-zone-e572adf` is authoritative only for
  `apps.example.com.`; the real public authoritative nameservers for `example.com` are not this zone,
  so Let's Encrypt's DNS-01 lookup of `_acme-challenge.apps.example.com` never sees cert-manager's TXT
  record. Per the operator's HTTP-first choice, M1's test cert and all of M3's TLS issuance are
  deferred; the ClusterIssuer still reaches `READY=True` because that only registers the ACME account
  (no DNS access needed). Enabling real HTTPS later: set a real `baseDomain` in Pulumi, `pulumi up`,
  delegate the name to the zone's nameservers, then `just cluster-enable-tls`. (2026-06-02)

- **Cluster access is via an SSH local-forward, not a rewritten kubeconfig.** The plan's M0 assumed
  `kubectl` could reach the apiserver at `publicIp:6443` (or a Tailscale name). Neither works yet: the
  host firewall opens only 22/80/443, the apiserver (6443) is bound to `trustedInterfaces =
  [tailscale0]`, and Tailscale is not joined (placeholder key). IAP can't tunnel to 6443 either (the
  IAP firewall rule permits only port 22). Working pattern: `ssh -L 6443:127.0.0.1:6443 -N
  deploy@nagare-01` through the port-22 IAP tunnel, then `kubectl` against the **unmodified** kubeconfig
  (server `https://127.0.0.1:6443`, whose k3s cert SAN includes 127.0.0.1). One durable connection
  avoids the per-command IAP-tunnel throttling EP-3 documented. (2026-06-02)

- **net-certmanager's version line froze at v1.14.0** (April 2024) and diverged from Knative's; there
  is no v1.22.0. The Knative GCS bucket's `net-certmanager/latest/` and newest `previous/` both
  resolve to v1.14.0 (`gsutil ls gs://knative-releases/net-certmanager/previous/`). The plan's guessed
  `previous/v1.22.0/net-certmanager.yaml` 404s. v1.14.0 reconciles the stable
  `networking.internal.knative.dev` `Certificate` (KCert) API, so it coexists with Knative Serving
  v1.22; with TLS disabled it idles. The plan/README/justfile pin is corrected to v1.14.0. (2026-06-02)

- **DomainMapping for a custom domain needs `autocreate-cluster-domain-claims: "true"`.** A
  `DomainMapping` for `hello.example.com` first sat `Ready=False` with the misleading status reason
  `DomainAlreadyClaimed`; the controller log gave the true cause: *"no ClusterDomainClaim found … and
  autocreate-cluster-domain-claims property is not true"*. Knative defaults this to `false` (multi-tenant
  safety: an admin must pre-create a `ClusterDomainClaim`). Nagare is single-tenant and `nagarectl`
  (EP-6) maps arbitrary custom domains, so `config-network.yaml` sets `autocreate-cluster-domain-claims:
  "true"`; the DomainMapping then auto-created its claim and went `Ready`. (2026-06-02)

- **On GCE the Kourier LoadBalancer's EXTERNAL-IP is the node's *internal* IP** (`10.10.0.3`), not the
  `publicIp` the plan expected. k3s ServiceLB (Klipper) binds the node address; GCP 1:1-NATs the
  external IP onto it, so an external `curl` to `publicIp:80` still reaches Kourier. The functional
  proof is the HTTP 200, not the EXTERNAL-IP value. (2026-06-02)

- Knative warns on apply that the hello pod's `securityContext` defaults are insecure
  (`allowPrivilegeEscalation`, `runAsNonRoot`, etc.). Harmless for the sample; EP-6's renderer can set
  a hardened `securityContext` for real apps. (2026-06-02)

## Decision Log

Record every decision made while working on the plan.

- Decision: Use the Kubernetes-native TLS path (cert-manager + Kourier), not host-level Caddy.
  Rationale: Inherited from the MasterPlan Decision Log (the user chose cert-manager + Kourier).
  This forces wildcard certificates, which forces a Let's Encrypt DNS-01 challenge, which forces a
  Google Cloud DNS solver authorized by `roles/dns.admin` on the VM service account.
  Date: 2026-06-02

- Decision: Authorize the DNS-01 solver with the VM's *ambient* Application Default Credentials
  (the attached Google service account), omitting `serviceAccountSecretRef` from the ClusterIssuer.
  Rationale: This is a self-managed k3s node, not GKE, so GKE Workload Identity does not exist.
  EP-2 attached a service account with `roles/dns.admin` to the VM; on Google Compute Engine any
  process on the VM (including cert-manager's pods) can obtain a token for that service account via
  the instance metadata server, which is exactly what "Application Default Credentials" means.
  Supplying no secret tells cert-manager's Cloud DNS solver to fall back to those ambient creds.
  Date: 2026-06-02

- Decision: Get one wildcard certificate per namespace (`*.<namespace>.apps.example.com`) via
  Knative's `external-domain-tls: Enabled` plus `namespace-wildcard-cert-selector: {}`.
  Rationale: Per-namespace wildcard certs minimize the number of ACME orders (one cert covers every
  service in a namespace, e.g. `hello`, `notes`, `wiki` under `personal`) and avoid hitting Let's
  Encrypt rate limits. This mode requires DNS-01 (the only challenge type that issues wildcards),
  which we already have. An empty selector `{}` matches all namespaces.
  Date: 2026-06-02

- Decision: Keep manifests in the repository and apply them with `kubectl apply`, rather than using
  a package manager such as Helm for these four components.
  Rationale: The MasterPlan's bootstrap layout and `justfile` use `kubectl apply -f cluster/bootstrap/...`.
  Upstream Knative, Kourier, and cert-manager all ship plain YAML release manifests, so we vendor a
  small wrapper/patch set and the upstream URLs are documented for re-download. Helm is reserved for
  the observability stack (EP-5).
  Date: 2026-06-02

- Decision: Pin concrete versions (Knative/Kourier `knative-v1.22.0`, cert-manager `v1.20.2`,
  net-certmanager `v1.14.0`) but tell the reader these move and how to find the current release.
  Rationale: A self-contained plan must be runnable as written, so it needs concrete URLs; but
  pinning forever would rot. The plan states the version-discovery procedure next to each pin.
  **Corrected during implementation:** net-certmanager is `v1.14.0`, not the `v1.22.0` the draft
  guessed — its release line froze at 1.14.0 and the v1.22.0 path 404s (see Surprises).
  Date: 2026-06-02

- Decision: Implement EP-4 **HTTP-first**, deferring all Let's Encrypt wildcard TLS until a real apps
  base domain is delegated.
  Rationale: The base domain is the placeholder `apps.example.com`, whose Cloud DNS zone is not the
  real authoritative zone, so DNS-01 cannot validate. The operator chose (2026-06-02) to install and
  wire the whole stack and prove the app over HTTP now, leaving TLS as a one-config flip
  (`config-network-tls.yaml` / `just cluster-enable-tls`) once a domain is delegated. This makes
  maximum verifiable progress without burning Let's Encrypt orders on an unvalidatable domain. The
  net-certmanager bridge and `config-certmanager` issuerRef are installed now so enabling TLS is a
  single patch.
  Date: 2026-06-02

- Decision: Set `autocreate-cluster-domain-claims: "true"` in `config-network`.
  Rationale: Nagare is single-tenant and `nagarectl` (EP-6) maps arbitrary custom domains via
  `DomainMapping`. Knative's default (`false`) requires an admin-created `ClusterDomainClaim` per
  domain, which blocked the example DomainMapping. Autocreation is safe with one tenant and is what
  lets custom-domain mappings work without manual claim management.
  Date: 2026-06-02

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Status (2026-06-02): **Marked Complete in the MasterPlan registry by operator decision** — HTTP path
complete and verified live; Let's Encrypt HTTPS deferred on the placeholder domain as a domain-gated
follow-up (one config flip, `just cluster-enable-tls`, once a real `baseDomain` is set in Pulumi and
delegated). Marking EP-4 Complete unblocks EP-6's hard dependency so the initiative can proceed.
Delivered against the Purpose:

- cert-manager v1.20.2 installed; the `letsencrypt-dns` DNS-01 ClusterIssuer (ambient ADC, project
  `tan-nb-exp`) is `READY=True`.
- Knative Serving + Kourier (knative-v1.22.0) installed; `config-network` selects Kourier and
  `config-domain` serves under `apps.example.com`. The hello Knative Service is `Ready` at
  `http://hello.personal.apps.example.com` and returns `HTTP/1.1 200 OK` / `Hello Nagare!` from a
  laptop via Envoy (proved with `--resolve` to the public IP, since the placeholder wildcard DNS is
  not real public DNS).
- net-certmanager v1.14.0 installed and pointed at `letsencrypt-dns`; a `DomainMapping`
  (`hello.example.com`) is `Ready` and routes over HTTP. `autocreate-cluster-domain-claims: "true"`
  lets custom domains be mapped without manual claims.

**Deferred (the only remaining EP-4 work), gated solely on a real domain:** apply
`config-network-tls.yaml` (`just cluster-enable-tls`) to turn on `external-domain-tls` +
`namespace-wildcard-cert-selector: {}`, then confirm the `*.personal.<baseDomain>` `Certificate`
reaches `READY=True` and `curl -v https://hello.personal.<baseDomain>` shows a trusted Let's Encrypt
cert. The cluster wiring is fully in place, so this is one patch once a domain is set in Pulumi
(`baseDomain`), `pulumi up` recreates the zone, and the name is delegated to the zone's Cloud DNS
nameservers.

What the next plans inherit: EP-5 reaches Grafana through this Kourier ingress (over HTTP today);
EP-6's `nagarectl` renders the same Knative Service / DomainMapping shapes and consumes the
`cluster/examples/hello-knative-service/` artifact — and will print HTTP URLs until TLS is enabled.
Cluster access for all three uses the SSH local-forward to `127.0.0.1:6443` (see Surprises) until
Tailscale is joined.

