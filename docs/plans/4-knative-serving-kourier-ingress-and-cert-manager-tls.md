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

Milestone 0 — Prerequisites and repository scaffolding:

- [ ] Confirm EP-3 is deployed and `kubectl get nodes` shows the node `Ready` (see Concrete Steps M0).
- [ ] Confirm the Pulumi stack outputs `baseDomain`, `publicIp`, `serviceAccountEmail`, `dnsZoneName` are readable.
- [ ] Create the directory tree under `cluster/bootstrap/` and `cluster/examples/`.
- [ ] Create the namespaces `cert-manager`, `knative-serving`, `kourier-system`, `personal`.

Milestone 1 — cert-manager + DNS-01 ClusterIssuer + test wildcard certificate:

- [ ] Install cert-manager from the pinned upstream manifest into namespace `cert-manager`.
- [ ] Apply the `ClusterIssuer` `letsencrypt-dns` (Cloud DNS DNS-01 solver, ambient creds).
- [ ] Verify `kubectl get clusterissuer letsencrypt-dns` shows `READY=True`.
- [ ] Issue a TEST `Certificate` for `*.apps.example.com`; verify it reaches `READY=True`.
- [ ] Delete the test `Certificate` (it is only a proof; the real ones are created by Knative).

Milestone 2 — Knative Serving + Kourier + config-domain + config-network (HTTP):

- [ ] Apply `serving-crds.yaml` then `serving-core.yaml` (pinned Knative version).
- [ ] Apply `kourier.yaml` (pinned net-kourier version).
- [ ] Patch `config-network` so `ingress-class: kourier.ingress.networking.knative.dev`.
- [ ] Patch `config-domain` so the key is `baseDomain` (the real apps base) with empty value.
- [ ] Verify all pods in `knative-serving` and `kourier-system` are `Running`.
- [ ] Verify the Kourier gateway Service has an external IP equal to `publicIp`.
- [ ] Apply the rendered hello Knative Service and verify `kubectl get ksvc -n personal` is `Ready`.
- [ ] `curl http://hello.personal.apps.example.com` returns `200` with the hello body.

Milestone 3 — net-certmanager + external-domain-tls + per-namespace wildcard + HTTPS + DomainMapping:

- [ ] Install net-certmanager from the Knative GCS bucket (pinned version).
- [ ] Patch `config-certmanager` so `issuerRef` points at `letsencrypt-dns`.
- [ ] Patch `config-network` with `external-domain-tls: Enabled` and `namespace-wildcard-cert-selector: {}`.
- [ ] Verify a `Certificate` `*.personal.apps.example.com` appears and reaches `READY=True`.
- [ ] `curl -v https://hello.personal.apps.example.com` shows a trusted cert and `200`.
- [ ] Apply a `DomainMapping` for a custom domain and verify it routes to the hello service.

Living-document upkeep:

- [ ] Record any surprises in Surprises & Discoveries.
- [ ] Update the MasterPlan Progress line for EP-4 when all milestones pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. As you implement, record here things like: how long the first DNS-01 challenge took to
propagate, whether Let's Encrypt rate limits were hit, or any version-specific manifest changes
between the pinned versions in this plan and the current upstream releases.)


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

- Decision: Pin concrete versions in examples (Knative `v1.22.0`, net-kourier `v1.22.0`,
  net-certmanager `v1.22.0`-line from the GCS bucket, cert-manager `v1.20.2`) but tell the reader
  these move and how to find the current release.
  Rationale: A self-contained plan must be runnable as written, so it needs concrete URLs; but
  pinning forever would rot. The plan states the version-discovery procedure next to each pin.
  Date: 2026-06-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. At completion, confirm against the Purpose: an
operator can `kubectl apply` the hello example and reach it over HTTPS with a trusted cert, and a
custom DomainMapping resolves. Note what the next plans inherit: EP-5 reaches Grafana through this
ingress; EP-6's `nagarectl` renders the same Knative Service / DomainMapping shapes and consumes
the `cluster/examples/hello-knative-service/` artifact.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before running anything.

**Where you are.** The repository root is `/Users/shinzui/Keikaku/bokuno/nagare`. It is a monorepo
for "Nagare", a single-node personal Platform-as-a-Service running on one Google Compute Engine
virtual machine in the Google Cloud project `tan-nb-exp`, region `us-west1`, zone `us-west1-a`.
Prior plans built the layers underneath this one:

- EP-2 (`docs/plans/2-pulumi-gcp-infrastructure.md`) created the cloud resources with Pulumi: a
  static public IP, a Cloud DNS managed zone with a wildcard record `*.apps.example.com` pointing
  at that IP, and a Google service account attached to the VM that has the IAM role
  `roles/dns.admin` (permission to edit DNS records in the zone). It exposes these as Pulumi *stack
  outputs* you can read with `pulumi stack output <name>`: `publicIp`, `baseDomain` (the apps base,
  e.g. `apps.example.com`), `serviceAccountEmail`, and `dnsZoneName` (the Cloud DNS managed-zone
  name). "Stack output" just means a named value Pulumi printed after creating resources.
- EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) built the NixOS host `nagare-01` and a
  single-node Kubernetes cluster using **k3s** (a small Kubernetes distribution). It deliberately
  disabled k3s's built-in Traefik ingress (so Knative/Kourier can own ingress) but **kept k3s's
  built-in ServiceLB** (also called "Klipper"). ServiceLB is the piece that satisfies a Kubernetes
  Service of `type: LoadBalancer` on a bare node: on a single node it simply binds the host's
  ports 80 and 443 to that Service. This matters here because Kourier's gateway is exactly such a
  `type: LoadBalancer` Service. k3s writes its cluster credentials file (the "kubeconfig") at
  `/etc/rancher/k3s/k3s.yaml` on the VM with file mode `0644`.

**This is a hard dependency.** EP-4 cannot be validated until EP-3 is deployed and the cluster is
live, because everything here is `kubectl apply` against a running cluster.

**How you talk to the cluster (kubeconfig).** Every command in this plan runs from your laptop and
talks to the remote cluster through an environment variable `KUBECONFIG` that points at a copy of
the VM's kubeconfig. A "kubeconfig" is a YAML file holding the cluster's API server address and the
client credentials. The file on the VM lists the server as `https://127.0.0.1:6443`, which is only
correct *on the VM*; you must rewrite that address to a hostname reachable from your laptop — either
the VM's Tailscale name (Tailscale is the private mesh VPN installed by EP-3) or the public IP from
EP-2. Concrete copy-and-rewrite steps are in Concrete Steps M0 below.

**Key terms used throughout (plain language).**

- *ConfigMap*: a Kubernetes object that stores configuration as key/value pairs. Knative reads its
  behavior from several ConfigMaps in the `knative-serving` namespace; in this plan we change
  `config-network`, `config-domain`, and `config-certmanager` by "patching" them (applying a small
  partial update with `kubectl patch`).
- *ClusterIssuer*: a cert-manager object describing *how* to obtain certificates (which certificate
  authority, and how to prove domain ownership). "Cluster" means it is cluster-wide (usable from any
  namespace), as opposed to a namespaced `Issuer`. Ours is named `letsencrypt-dns`.
- *DNS-01 challenge*: one of the ways Let's Encrypt verifies you control a domain before issuing a
  certificate. cert-manager creates a temporary TXT DNS record (e.g. `_acme-challenge.apps.example.com`)
  in your DNS zone; Let's Encrypt queries DNS and, on seeing the expected value, issues the cert.
  Crucially, DNS-01 is the *only* challenge type that can issue a **wildcard** certificate.
- *Wildcard certificate*: one certificate valid for every subdomain at a level, e.g.
  `*.personal.apps.example.com` covers `hello.personal.apps.example.com`,
  `notes.personal.apps.example.com`, and so on. The contrasting HTTP-01 challenge cannot issue
  wildcards (it proves control of exactly one hostname by serving a file over HTTP), which is the
  reason we are forced onto DNS-01.
- *Knative Service* / *ksvc*: the top-level Knative object (API group `serving.knative.dev`, version
  `v1`, kind `Service`) that you submit to deploy an app. Knative expands it into a Deployment, an
  autoscaler, internal routing, and a public URL.
- *DomainMapping*: a Knative object (API group `serving.knative.dev`, version `v1beta1`, kind
  `DomainMapping`) that maps a custom hostname like `hello.example.com` onto a Knative Service. It is
  enabled by default in current Knative; **no feature flag is required** (older documentation implied
  one).

**Where new files go.** All work in this plan lives under `cluster/` (the directory the MasterPlan
reserves for cluster workloads). The exact tree you will create:

```text
cluster/
  bootstrap/
    cert-manager/
      README.md               # install notes + upstream URL + version-discovery procedure
      letsencrypt-dns.yaml    # the DNS-01 ClusterIssuer
      test-wildcard-cert.yaml # M1 proof-of-issuance Certificate (deleted after verifying)
    kourier/
      README.md               # install notes + upstream URL
    knative-serving/
      README.md               # install notes + upstream URLs
      config-network.yaml     # patch body: ingress-class + (M3) external-domain-tls + selector
      config-domain.yaml      # patch body: baseDomain key, empty value
      config-certmanager.yaml # patch body: issuerRef -> letsencrypt-dns
    net-certmanager/
      README.md               # install notes + GCS-bucket URL + version-discovery procedure
  examples/
    hello-knative-service/
      nagare.yaml             # the app contract (MasterPlan Integration Point 6 schema)
      service.yaml            # the rendered Knative Service that nagare.yaml maps to
      domainmapping.yaml      # M3 custom-domain demonstration
      README.md               # how to deploy and curl it
```

A `justfile` recipe `cluster-bootstrap` ties the apply steps together; the patch ConfigMaps and the
ClusterIssuer are stored in the repo and applied declaratively.


## Plan of Work

The work is three milestones, each independently verifiable, plus a short Milestone 0 of
prerequisites and scaffolding. The order matters: cert-manager and a *working* DNS-01 issuer come
first (M1) because the hardest, most failure-prone part of the whole plan is proving that DNS-01 +
Cloud DNS + the VM's IAM permissions actually let us obtain a wildcard certificate. Doing that with
a throwaway test certificate *before* installing Knative means that if it fails, we debug a tiny,
isolated thing rather than an entangled stack. Then M2 installs Knative + Kourier and proves plain
HTTP routing works end-to-end (DNS resolves to the VM, ServiceLB hands the request to Kourier,
Kourier routes to the Knative Service). Finally M3 connects the two halves with net-certmanager so
Knative requests the per-namespace wildcard certificate from our issuer, and the same hello service
answers over HTTPS.

**Milestone 0 — Prerequisites and scaffolding.** Confirm the cluster is live and the Pulumi outputs
are readable, set up `KUBECONFIG`, create the four namespaces, and create the directory tree and
files described in Context. At the end, `kubectl get ns` lists `cert-manager`, `knative-serving`,
`kourier-system`, and `personal`, and the repository contains the (still-inert) manifests.

**Milestone 1 — cert-manager and a proven DNS-01 wildcard issuer.** Install cert-manager from its
upstream release manifest into the `cert-manager` namespace. Create the `letsencrypt-dns`
ClusterIssuer that uses Let's Encrypt's ACME server with a Google Cloud DNS DNS-01 solver bound to
project `tan-nb-exp`, authorized by ambient credentials. Verify the issuer becomes `Ready`. Then
prove the whole chain by creating a real wildcard `Certificate` for `*.apps.example.com` and watching
it reach `Ready=True` — this is the moment we know DNS-01, Cloud DNS, and the VM's IAM all work
together. Delete that test certificate afterward (Knative will create the real per-namespace ones in
M3). At the end: `kubectl get clusterissuer` shows `letsencrypt-dns` `READY=True`, and a test
`Certificate` reached `READY=True` (captured in the transcript) before being deleted.

**Milestone 2 — Knative Serving + Kourier, HTTP working.** Apply Knative's CRDs and core, apply
Kourier, patch `config-network` to select Kourier as the ingress class, and patch `config-domain` so
Knative builds URLs under the real apps base domain. Deploy the hello example as a Knative Service in
the `personal` namespace and curl its plain-HTTP URL from your laptop. At the end:
`kubectl get ksvc -n personal hello` shows `READY=True` with a URL of the form
`http://hello.personal.apps.example.com`, the Kourier gateway Service shows the VM's public IP as its
external IP, and `curl http://hello.personal.apps.example.com` returns `200` and the hello body.

**Milestone 3 — Automatic per-namespace wildcard HTTPS + DomainMapping.** Install net-certmanager
(the Knative↔cert-manager bridge), point its `config-certmanager` at the `letsencrypt-dns`
ClusterIssuer, and turn on `external-domain-tls: Enabled` with an empty
`namespace-wildcard-cert-selector: {}` so Knative requests one wildcard certificate per namespace.
Watch a `Certificate` `*.personal.apps.example.com` appear and become `Ready`, then curl the hello
service over HTTPS and observe a trusted Let's Encrypt certificate and `200`. Finally apply a
`DomainMapping` to demonstrate a custom public hostname routing to the same service. At the end:
`kubectl get certificate -A` shows the per-namespace wildcard `READY=True`, and
`curl -v https://hello.personal.apps.example.com` shows a trusted certificate chain and `HTTP/2 200`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` on your laptop,
inside the project dev shell. Enter the dev shell first (it provides `kubectl`, `gcloud`, `jq`, and
`just`; it is defined by EP-1):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nix develop
```

Throughout, the placeholder `apps.example.com` stands for the real apps base domain. Do not type the
placeholder literally; resolve it from Pulumi and store it in a shell variable as shown in M0. The
verified upstream facts this plan relies on (state them as embedded knowledge, do not chase external
blogs):

- Knative Serving current line is **v1.22** (released 2026-04-28). Install `serving-crds.yaml` then
  `serving-core.yaml` from `https://github.com/knative/serving/releases`. Kourier matches Knative's
  version; install `kourier.yaml` from `https://github.com/knative-extensions/net-kourier/releases`.
  To find the current version: open the releases page (or `gh release list -R knative/serving`) and
  read the newest `knative-vX.Y.Z` tag; the download URLs follow the templates shown below.
- cert-manager current line is **v1.20.2** (released 2026-04-11). Install the single
  `cert-manager.yaml` from `https://github.com/cert-manager/cert-manager/releases`. To find the
  current version: `gh release list -R cert-manager/cert-manager`.
- net-certmanager release artifacts are **no longer on GitHub past v1.14.0**; pull `net-certmanager.yaml`
  from the Knative GCS bucket at `https://storage.googleapis.com/knative-releases/net-certmanager/...`.
  The path template is shown in M3. To confirm the current path/version, consult the Knative
  "Configure cert-manager integration" install page; it directs to the GCS bucket.

The Kourier ingress-class key value is exactly `kourier.ingress.networking.knative.dev`.

### M0 — Prerequisites and scaffolding

First confirm EP-3 is live and read the Pulumi outputs. Set up kubeconfig by copying the VM's
k3s.yaml and rewriting its server address to a name reachable from your laptop (the VM's Tailscale
hostname is preferred; the public IP also works):

```bash
# Copy the cluster credentials off the VM (uses the SSH command exported by EP-2).
scp nagare-01:/etc/rancher/k3s/k3s.yaml /tmp/nagare-kubeconfig.yaml

# Rewrite the server address from the VM-local 127.0.0.1 to a reachable name.
# Use the Tailscale hostname if you have it; otherwise substitute the publicIp output.
PUBLIC_IP=$(cd infra/pulumi && pulumi stack output publicIp)
sed -i '' "s#https://127.0.0.1:6443#https://${PUBLIC_IP}:6443#" /tmp/nagare-kubeconfig.yaml
export KUBECONFIG=/tmp/nagare-kubeconfig.yaml

# Confirm the cluster is live (EP-3). Expected: one node, STATUS Ready.
kubectl get nodes
```

Expected output (abbreviated):

```text
NAME        STATUS   ROLES                  AGE   VERSION
nagare-01   Ready    control-plane,master   1d    v1.31.x+k3s1
```

Note: if your kubeconfig's server uses the public IP, the TLS certificate baked into k3s may not
list that IP as a valid name. If `kubectl` complains about the certificate, either prefer the
Tailscale hostname (which EP-3 added to the k3s TLS SANs) or, as a temporary measure, append
`--insecure-skip-tls-verify` to commands. The Tailscale path is the documented, secure default.

Read the Pulumi outputs this plan consumes and store the base domain:

```bash
cd infra/pulumi
pulumi stack output baseDomain            # e.g. apps.example.com
pulumi stack output publicIp              # e.g. 34.x.x.x
pulumi stack output serviceAccountEmail   # e.g. nagare-node@tan-nb-exp.iam.gserviceaccount.com
pulumi stack output dnsZoneName           # e.g. nagare-zone
cd /Users/shinzui/Keikaku/bokuno/nagare
export BASE_DOMAIN=$(cd infra/pulumi && pulumi stack output baseDomain)
echo "Apps base domain: ${BASE_DOMAIN}"
```

Create the namespaces (Integration Point 5 fixes these exact names):

```bash
kubectl create namespace cert-manager     --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace knative-serving  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kourier-system   --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace personal         --dry-run=client -o yaml | kubectl apply -f -
kubectl get ns
```

The `--dry-run=client -o yaml | kubectl apply -f -` idiom makes namespace creation idempotent: it
emits the namespace object and applies it, so re-running does not error if it already exists.

Note: the Knative and cert-manager release manifests below *also* create the `knative-serving` and
`cert-manager` namespaces themselves. Creating them here first is harmless (apply is declarative) and
makes the ordering robust.

Now create the repository files. The full contents of each are given in the milestones below.

### M1 — cert-manager + DNS-01 ClusterIssuer + test wildcard certificate

Install cert-manager from its pinned release manifest (this creates CRDs, the `cert-manager`
namespace, and the controller/webhook/cainjector Deployments):

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
```

Wait for the three cert-manager Deployments to become available:

```bash
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector
kubectl -n cert-manager get pods
```

Expected (abbreviated):

```text
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-...                           1/1     Running   0          60s
cert-manager-cainjector-...                1/1     Running   0          60s
cert-manager-webhook-...                   1/1     Running   0          60s
```

Create `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`. This is the ClusterIssuer. It uses
Let's Encrypt's *production* ACME endpoint and a Google CloudDNS DNS-01 solver. Note there is **no**
`serviceAccountSecretRef`: omitting it tells cert-manager to use the VM's ambient Application Default
Credentials (the attached service account with `roles/dns.admin`). The `project` is the GCP project
that owns the DNS zone, `tan-nb-exp`. The `email` should be a real address for expiry notices.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    # Let's Encrypt production endpoint. Use the staging endpoint
    # https://acme-staging-v02.api.letsencrypt.org/directory while testing to avoid
    # hitting production rate limits; staging certs are NOT browser-trusted.
    server: https://acme-v02.api.letsencrypt.org/directory
    email: nadeem@gmail.com
    privateKeySecretRef:
      name: letsencrypt-dns-account-key
    solvers:
      - dns01:
          cloudDNS:
            # GCP project that owns the Cloud DNS managed zone (from EP-2).
            project: tan-nb-exp
            # No serviceAccountSecretRef: use the VM's ambient ADC (the attached
            # service account holds roles/dns.admin, granted by EP-2). GKE Workload
            # Identity does not exist on self-managed k3s, so ambient creds are the
            # mechanism here.
```

Apply it and wait for it to validate the ACME account:

```bash
kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml
kubectl get clusterissuer letsencrypt-dns -o wide
```

Expected once ready (the `READY` column becomes `True` within a minute or two; it registers/validates
the ACME account, which does not require DNS access yet):

```text
NAME              READY   STATUS                                                 AGE
letsencrypt-dns   True    The ACME account was registered with the ACME server   90s
```

If `READY` stays `False`, inspect the issuer and the controller logs:

```bash
kubectl describe clusterissuer letsencrypt-dns
kubectl -n cert-manager logs deploy/cert-manager --tail=100
```

Now prove the hard part: that DNS-01 against Cloud DNS, authorized by the VM's service account, can
actually obtain a **wildcard** certificate. Create `cluster/bootstrap/cert-manager/test-wildcard-cert.yaml`.
Substitute the real base domain for `apps.example.com` (or template it as shown after the block):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-wildcard
  namespace: cert-manager
spec:
  secretName: test-wildcard-tls
  dnsNames:
    - "*.apps.example.com"
  issuerRef:
    name: letsencrypt-dns
    kind: ClusterIssuer
```

Render the real domain into the file and apply it (this keeps the repo copy with the
`apps.example.com` placeholder while applying the substituted version):

```bash
sed "s/apps.example.com/${BASE_DOMAIN}/g" \
  cluster/bootstrap/cert-manager/test-wildcard-cert.yaml | kubectl apply -f -

# Watch progress. cert-manager creates a CertificateRequest -> Order -> Challenge,
# writes a TXT record into Cloud DNS, waits for propagation, then Let's Encrypt issues.
# This typically takes 1-3 minutes; DNS propagation is the slow part.
kubectl -n cert-manager get certificate test-wildcard -w
```

Expected end state:

```text
NAME            READY   SECRET              AGE
test-wildcard   True    test-wildcard-tls   2m
```

If it does not become `True`, walk the chain to find where it is stuck (the order of objects is
Certificate → CertificateRequest → Order → Challenge):

```bash
kubectl -n cert-manager describe certificate test-wildcard
kubectl -n cert-manager get challenge
kubectl -n cert-manager describe challenge        # shows DNS-01 presented record + status
kubectl -n cert-manager logs deploy/cert-manager --tail=200 | grep -i -E "dns|challenge|cloud"
```

The most common cause of a stuck DNS-01 challenge is the VM service account lacking `roles/dns.admin`
on the project/zone (EP-2/Integration Point 2). A challenge stuck in `pending` whose logs mention a
403 / permission error on `dns.changes.create` confirms an IAM problem, not a Nagare-cluster problem.

Once `READY=True`, you have *proven* the issuer works. Delete the test certificate and its secret;
the real per-namespace wildcards are created automatically by Knative in M3:

```bash
kubectl -n cert-manager delete certificate test-wildcard
kubectl -n cert-manager delete secret test-wildcard-tls --ignore-not-found
```

### M2 — Knative Serving + Kourier + config patches + hello over HTTP

Install Knative Serving. Apply the CRDs first (the custom resource *definitions* that teach
Kubernetes about Knative kinds), then the core controllers. The version is pinned to `v1.22.0`;
substitute the current `knative-vX.Y.Z` tag if it has moved (see the version-discovery note above):

```bash
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-core.yaml
kubectl -n knative-serving rollout status deploy/controller
kubectl -n knative-serving rollout status deploy/webhook
kubectl -n knative-serving get pods
```

Install Kourier (version matches Knative). This creates the `kourier-system` namespace, the Kourier
controller in `knative-serving`, and the gateway Service `kourier` in `kourier-system`:

```bash
kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.22.0/kourier.yaml
kubectl -n kourier-system get pods
kubectl -n kourier-system get svc
```

Now tell Knative to use Kourier as its ingress. Create
`cluster/bootstrap/knative-serving/config-network.yaml` as the *patch body* (M3 will add two more
keys to this same file; for M2 it contains only the ingress class):

```yaml
data:
  ingress-class: kourier.ingress.networking.knative.dev
```

Apply it as a strategic-merge patch onto the existing `config-network` ConfigMap that Knative
installed:

```bash
kubectl -n knative-serving patch configmap config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
```

Set the apps base domain. By default Knative serves under `svc.cluster.local` (cluster-internal
only). We replace that with the real public base domain so Knative builds public URLs of the form
`service.namespace.<baseDomain>`. The `config-domain` ConfigMap convention is unusual: the *key* is
the domain and the *value* is empty. Create `cluster/bootstrap/knative-serving/config-domain.yaml`
with the placeholder:

```yaml
data:
  apps.example.com: ""
```

Apply it with the real base domain substituted in. Because we are replacing the default
`svc.cluster.local` key with our domain key, use a full apply of a freshly rendered ConfigMap rather
than a merge (a merge would *add* our key while leaving the default key present). The cleanest
approach is to build the ConfigMap explicitly:

```bash
kubectl create configmap config-domain -n knative-serving \
  --from-literal="${BASE_DOMAIN}=" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - \
    app.kubernetes.io/component=domain-mapping app.kubernetes.io/name=knative-serving -o yaml | \
  kubectl apply -f -
```

If the labeling pipe is awkward in your shell, the simpler equivalent is to patch and then remove the
default key:

```bash
kubectl -n knative-serving patch configmap config-domain \
  --type merge --patch "{\"data\":{\"${BASE_DOMAIN}\":\"\"}}"
kubectl -n knative-serving patch configmap config-domain \
  --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
```

Verify everything is healthy and that Kourier got an external IP from ServiceLB equal to `publicIp`:

```bash
kubectl -n knative-serving get pods
kubectl -n kourier-system get pods
kubectl -n kourier-system get svc kourier
```

Expected (the EXTERNAL-IP of the `kourier` LoadBalancer Service should equal your `publicIp`; on k3s
ServiceLB binds host ports 80/443 to it):

```text
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
kourier   LoadBalancer   10.43.x.x       34.x.x.x       80:3xxxx/TCP,443:3xxxx/TCP   2m
```

Now deploy the hello example. First create the application contract file
`cluster/examples/hello-knative-service/nagare.yaml`. This conforms to MasterPlan Integration Point 6
(the schema `nagarectl` in EP-6 will parse). It uses a public hello image so no build step is needed:

```yaml
name: hello                                        # Knative Service name (DNS-safe)
namespace: personal                                # Kubernetes namespace
image: gcr.io/knative-samples/helloworld-go        # public sample image, no tag here
domain: hello.example.com                          # optional custom public domain (used in M3)
port: 8080                                          # container port the app listens on
env:
  TARGET:
    value: "Nagare"                                 # literal env var; sample app echoes it
resources:
  cpu: 250m
  memory: 128Mi
scale:
  min: 0                                            # scale-to-zero when idle
  max: 3
```

Then create the *rendered* Knative Service `cluster/examples/hello-knative-service/service.yaml`.
This is what `nagare.yaml` maps to (EP-6 will generate this shape automatically; here we hand-write
it so M2 can be validated before EP-6 exists). The image is pinned by digest-less tag `latest` for
the sample; the `min/max` scale values become Knative autoscaling annotations:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "0"
        autoscaling.knative.dev/max-scale: "3"
    spec:
      containers:
        - image: gcr.io/knative-samples/helloworld-go
          ports:
            - containerPort: 8080
          env:
            - name: TARGET
              value: "Nagare"
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
```

Apply it and wait for readiness:

```bash
kubectl apply -f cluster/examples/hello-knative-service/service.yaml
kubectl -n personal get ksvc hello -w
```

Expected once Knative has created the Deployment, routing, and (for now plain-HTTP) URL:

```text
NAME    URL                                          LATESTCREATED   LATESTREADY   READY   REASON
hello   http://hello.personal.apps.example.com       hello-00001     hello-00001   True
```

Now curl it from your laptop. Because EP-2 created the wildcard DNS record `*.apps.example.com`
pointing at `publicIp`, the hostname `hello.personal.apps.example.com` resolves to the VM, ServiceLB
delivers port 80 to Kourier, and Kourier routes by Host header to the hello Knative Service:

```bash
curl -i http://hello.personal.${BASE_DOMAIN}
```

Expected:

```text
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
...
Hello Nagare!
```

If DNS has not propagated yet, you can prove routing independently of public DNS by sending the Host
header explicitly to the VM's IP:

```bash
curl -i --resolve hello.personal.${BASE_DOMAIN}:80:${PUBLIC_IP} \
  http://hello.personal.${BASE_DOMAIN}
```

This `200` with `Hello Nagare!` completes M2.

### M3 — net-certmanager + external-domain-tls + per-namespace wildcard HTTPS + DomainMapping

Install the net-certmanager bridge from the Knative GCS bucket. Its artifacts left GitHub after
v1.14.0, so the canonical source is the bucket. The path template is
`https://storage.googleapis.com/knative-releases/net-certmanager/previous/<version>/net-certmanager.yaml`
(confirm the exact current path on the Knative "Configure cert-manager integration" page; the version
tracks the Knative line, here `v1.22.0`):

```bash
kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.22.0/net-certmanager.yaml
kubectl -n knative-serving get pods | grep -i certmanager
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
```

Point net-certmanager at our ClusterIssuer. Create
`cluster/bootstrap/knative-serving/config-certmanager.yaml` as the patch body. The `issuerRef` is a
YAML *string* under the `data` key (ConfigMap values are strings), naming our cluster-wide issuer:

```yaml
data:
  issuerRef: |
    kind: ClusterIssuer
    name: letsencrypt-dns
```

Apply the patch:

```bash
kubectl -n knative-serving patch configmap config-certmanager \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
```

Now enable automatic external-domain TLS with per-namespace wildcards. Update
`cluster/bootstrap/knative-serving/config-network.yaml` so it now contains all three keys (the M2
ingress class plus the two TLS keys). `external-domain-tls: Enabled` turns on automatic certificates
for public domains; `namespace-wildcard-cert-selector: {}` (an empty label selector, matching every
namespace) tells Knative to create *one wildcard certificate per namespace*
(`*.<namespace>.apps.example.com`) instead of one certificate per service. Per-namespace wildcards
work only with DNS-01, which we proved in M1:

```yaml
data:
  ingress-class: kourier.ingress.networking.knative.dev
  external-domain-tls: Enabled
  namespace-wildcard-cert-selector: "{}"
```

Re-apply the merged patch:

```bash
kubectl -n knative-serving patch configmap config-network \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
```

Within a minute Knative should create a `Certificate` for the `personal` namespace's wildcard, and
cert-manager should fulfill it via DNS-01 (the same path proven in M1, now driven by Knative):

```bash
kubectl get certificate -A -w
```

Expected (the name is Knative-generated; the dnsNames cover the namespace wildcard):

```text
NAMESPACE   NAME                       READY   SECRET                     AGE
personal    route-...                  True    route-...                  2m
```

Inspect to confirm it covers `*.personal.<baseDomain>`:

```bash
kubectl -n personal get certificate -o jsonpath='{.items[0].spec.dnsNames}'; echo
# Expected: ["*.personal.apps.example.com"]
```

Now curl the hello service over HTTPS. It should present a browser-trusted Let's Encrypt certificate
and return `200`:

```bash
curl -v https://hello.personal.${BASE_DOMAIN} 2>&1 | grep -E "subject:|issuer:|SSL certificate verify|HTTP/"
curl -i https://hello.personal.${BASE_DOMAIN}
```

Expected (trusted issuer "Let's Encrypt", verify ok, 200 with the hello body):

```text
*  subject: CN=*.personal.apps.example.com
*  issuer: C=US; O=Let's Encrypt; CN=...
*  SSL certificate verify ok.
< HTTP/2 200
...
Hello Nagare!
```

Finally, demonstrate a DomainMapping (a custom public hostname mapped onto the service). Create
`cluster/examples/hello-knative-service/domainmapping.yaml`. The custom domain `hello.example.com`
must itself resolve to the VM and be covered by a certificate; for a one-off demo you can point a DNS
record at `publicIp` and rely on Knative to request a per-host certificate for it, or use
`--resolve` to test routing without public DNS. The DomainMapping object:

```yaml
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: hello.example.com
  namespace: personal
spec:
  ref:
    name: hello
    kind: Service
    apiVersion: serving.knative.dev/v1
```

Apply and verify it becomes Ready, then prove it routes to the hello service (using `--resolve` so
the demo does not require you to own `example.com`):

```bash
kubectl apply -f cluster/examples/hello-knative-service/domainmapping.yaml
kubectl -n personal get domainmapping hello.example.com
curl -i --resolve hello.example.com:80:${PUBLIC_IP} http://hello.example.com
```

Expected:

```text
NAME                URL                       READY   REASON
hello.example.com   http://hello.example.com  True

HTTP/1.1 200 OK
...
Hello Nagare!
```

That completes M3 and the plan: a container image is now a public, auto-TLS, scale-to-zero web
service, and a custom domain can be mapped onto it.

### The cluster-bootstrap justfile recipe

Add (or update) the `cluster-bootstrap` recipe in the repo-root `justfile` so the apply steps are
reproducible. Manifests stay in the repo; the recipe pins the upstream release URLs. The recipe
assumes `KUBECONFIG` and `BASE_DOMAIN` are already exported (M0):

```make
# Versions are pinned but move; see cluster/bootstrap/*/README.md for discovery.
knative_version := "knative-v1.22.0"
certmanager_version := "v1.20.2"
netcertmanager_version := "v1.22.0"

cluster-bootstrap:
	# Namespaces (idempotent)
	kubectl create namespace cert-manager    --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace knative-serving --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace kourier-system  --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace personal        --dry-run=client -o yaml | kubectl apply -f -
	# M1: cert-manager + DNS-01 ClusterIssuer
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
	kubectl -n cert-manager rollout status deploy/cert-manager-webhook
	kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml
	# M2: Knative + Kourier
	kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
	kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
	kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
	kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
	kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"
	kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
	# M3: net-certmanager bridge + issuer wiring (config-network already has the TLS keys)
	kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
	kubectl -n knative-serving patch configmap config-certmanager --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"

deploy-hello:
	kubectl apply -f cluster/examples/hello-knative-service/service.yaml
```


## Validation and Acceptance

Acceptance is behavioral and is checked at the end of each milestone with the transcripts shown in
Concrete Steps. The consolidated checks:

For M1 (issuer + DNS-01 proven):

```bash
kubectl get clusterissuer letsencrypt-dns -o wide
# Acceptance: READY column is True ("The ACME account was registered with the ACME server").
# And during M1 a test Certificate for *.<baseDomain> reached READY=True before deletion.
```

For M2 (Knative + Kourier + HTTP):

```bash
kubectl -n knative-serving get pods            # all Running
kubectl -n kourier-system get pods             # all Running
kubectl -n kourier-system get svc kourier      # EXTERNAL-IP == publicIp
kubectl get ksvc -A                            # hello in personal, READY True, http URL
curl -i http://hello.personal.${BASE_DOMAIN}   # HTTP/1.1 200 OK, body "Hello Nagare!"
```

For M3 (per-namespace wildcard HTTPS + DomainMapping):

```bash
kubectl get certificate -A                     # personal wildcard cert READY True
curl -v https://hello.personal.${BASE_DOMAIN}  # trusted Let's Encrypt cert, HTTP/2 200, hello body
kubectl -n personal get domainmapping hello.example.com   # READY True
curl -i --resolve hello.example.com:80:${PUBLIC_IP} http://hello.example.com  # 200, hello body
```

The single most important end-to-end assertion (the Purpose realized): from a laptop,
`curl https://hello.personal.<baseDomain>` returns `200` with `Hello Nagare!` over a browser-trusted
certificate. If that holds, EP-4 is functionally complete.


## Idempotence and Recovery

Everything here is declarative. `kubectl apply` of the upstream manifests, the ClusterIssuer, the
ConfigMap patches, and the example Service can be run repeatedly; Kubernetes converges to the
declared state rather than erroring on the second run. The namespace creation idiom
(`--dry-run=client -o yaml | kubectl apply -f -`) is explicitly idempotent. Re-running
`just cluster-bootstrap` is safe and is the intended recovery path after, for example, recreating the
cluster from EP-3.

Recovering a stuck certificate. If a `Certificate` does not reach `READY=True`, the failure is almost
always in the DNS-01 challenge. Diagnose by walking Certificate → CertificateRequest → Order →
Challenge and reading cert-manager's logs:

```bash
kubectl describe certificate -A | sed -n '1,80p'   # or describe the specific one
kubectl get challenge -A
kubectl describe challenge -A                       # shows the presented TXT record and status
kubectl -n cert-manager logs deploy/cert-manager --tail=200
```

To force a clean retry, delete the failed `Certificate` (Knative recreates the per-namespace one
automatically; for the M1 test cert you recreate it by re-applying) and, if orders are wedged, delete
the stale `Order`/`CertificateRequest`/`Challenge` objects so cert-manager starts fresh:

```bash
# Example: reset the personal-namespace wildcard.
kubectl -n personal delete certificaterequest --all
kubectl -n personal delete order --all
kubectl -n personal delete challenge --all
# Knative re-requests the Certificate; cert-manager re-runs DNS-01.
```

If you suspect Let's Encrypt rate limiting (the *production* endpoint limits duplicate certificates),
switch the ClusterIssuer's `server` to the staging endpoint
`https://acme-staging-v02.api.letsencrypt.org/directory`, re-apply, and iterate until issuance
succeeds; staging certificates are *not* browser-trusted, so switch back to production for the final
acceptance. A permission failure (403 on `dns.changes.create` in the logs) is an IAM problem in EP-2,
not in this plan: confirm the VM's service account (`serviceAccountEmail`) holds `roles/dns.admin`.

Reverting cleanly. To remove a component, `kubectl delete -f <same manifest URL>`; to undo the
ConfigMap patches, re-apply Knative's `serving-core.yaml` (it resets the ConfigMaps to defaults) and
re-patch as needed. Deleting the hello example: `kubectl delete -f cluster/examples/hello-knative-service/service.yaml`.


## Interfaces and Dependencies

This plan **hard-depends on EP-3** (a live k3s cluster; `kubectl get nodes` Ready) and
**soft-depends on EP-2** (the Pulumi outputs `baseDomain`, `publicIp`, `serviceAccountEmail`,
`dnsZoneName`, the wildcard DNS record, and the VM service account's `roles/dns.admin`). Access to the
cluster is via the EP-3 kubeconfig at `/etc/rancher/k3s/k3s.yaml`, copied locally with its `server:`
field rewritten to the Tailscale name or `publicIp` (Integration Point 7).

Components installed (libraries/services to use and why):

- **cert-manager `v1.20.2`** (`github.com/cert-manager/cert-manager`) in namespace `cert-manager` —
  obtains/renews Let's Encrypt certificates. Used because the project chose Kubernetes-native TLS.
- **Knative Serving `knative-v1.22.0`** (`github.com/knative/serving`) in namespace `knative-serving`
  — turns container images into scale-to-zero web services.
- **Kourier `knative-v1.22.0`** (`github.com/knative-extensions/net-kourier`), controller in
  `knative-serving`, gateway Service `kourier` in namespace `kourier-system` — the Knative ingress.
- **net-certmanager `v1.22.0`** (Knative GCS bucket) in namespace `knative-serving` — the bridge that
  lets Knative request certificates from cert-manager automatically.

Concrete interfaces other plans depend on (these names and keys are the contract):

- ClusterIssuer name: **`letsencrypt-dns`** (cert-manager.io/v1, DNS-01 Cloud DNS, project
  `tan-nb-exp`, ambient creds).
- ConfigMaps in `knative-serving` and their keys: `config-network` →
  `ingress-class: kourier.ingress.networking.knative.dev`, `external-domain-tls: Enabled`,
  `namespace-wildcard-cert-selector: "{}"`; `config-domain` → key is `<baseDomain>` with empty value;
  `config-certmanager` → `issuerRef` naming the `letsencrypt-dns` ClusterIssuer.
- Namespaces (Integration Point 5): `cert-manager`, `knative-serving`, `kourier-system`, and the app
  namespace `personal`.
- The URL shape Knative produces (Integration Point 4): `service.namespace.<baseDomain>`, e.g.
  `hello.personal.apps.example.com`.
- The hello example under `cluster/examples/hello-knative-service/` — its `nagare.yaml` conforms to
  MasterPlan Integration Point 6 and is **consumed by EP-6**
  (`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`), whose `nagarectl` renders the same Knative
  Service and DomainMapping shapes shown here. EP-5
  (`docs/plans/5-victoria-observability-stack-and-grafana.md`) reaches Grafana through this ingress.

Required object kinds/API groups that must exist at completion: `cert-manager.io/v1` (`ClusterIssuer`,
`Certificate`), `serving.knative.dev/v1` (`Service`/`ksvc`), `serving.knative.dev/v1beta1`
(`DomainMapping`), and `networking.internal.knative.dev` (the internal `Certificate`/`KCert` objects
net-certmanager fulfills via cert-manager).


## Revision Note

2026-06-02: Initial authored version replacing the skeleton body. Frontmatter (lines 1-9) and the
required section headings preserved. Versions pinned from current upstream as of June 2026
(Knative/Kourier v1.22, cert-manager v1.20.2, net-certmanager v1.22 from the Knative GCS bucket) with
discovery procedures embedded so the pins can be refreshed. Reason: this is the first full draft of
EP-4 derived from the MasterPlan Integration Points and the spec's "Spec Accuracy Corrections"
appendix; the corrections (cert-manager+Kourier over Caddy, DNS-01 wildcard, ambient creds, ServiceLB
kept enabled, DomainMapping needs no feature flag, net-certmanager from GCS) are reflected throughout.
