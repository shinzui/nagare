# Nagare command runner. These recipes are THIN WRAPPERS. The detailed
# contents of each step are owned by the child plans referenced below,
# under docs/plans/. Run `just --list` to see all recipes.
#
# Cloud commands target the active target context: a named env file under
# ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env, selected with
# `nagarectl context use NAME`, `NAGARE_CONTEXT`, or `--context`. The in-repo
# `nagare.target.env` and `nagare.local.env` remain lower-precedence compatibility
# fallbacks; with nothing configured, defaults reproduce tan-nb-exp / us-west1 /
# us-west1-a. See .envrc, CLAUDE.md, and docs/user/contexts.md. Enter the dev
# shell with `nix develop`, or let direnv load it after `direnv allow`.

# Show all recipes.
default:
    @just --list

# Strictly validate commit-pinned review records against the shared
# assurance.reviews profile. Findings stay in the review body or become records
# in the owning bug-report or improvement-request bundle.
[group('docs')]
reviews-validate:
    okf validate docs/reviews \
      --strict \
      --profile docs/reviews/profile.dhall \
      --profile-enforce \
      --log-enforce

# EP-2 (docs/plans/2-pulumi-gcp-infrastructure.md): create/update the GCP
# resources (VM, static IP, Cloud DNS, disks, service account, Artifact
# Registry, backup bucket).
# Create/update GCP infrastructure (pulumi up).
[group('infra')]
infra-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    cd infra/pulumi && pulumi up

# EP-2: preview the Pulumi changes without applying them.
[group('infra')]
infra-preview:
    cd infra/pulumi && pulumi preview

# Cheapest reversible "off": halts compute charges; the boot/data disks and the
# reserved static IP keep their small storage/reservation cost. Targets the
# instance/zone/project from the target profile (.envrc / nagare.target.env),
# defaulting to nagare-01 / us-west1-a / tan-nb-exp. For a FULL teardown instead,
# use `pulumi destroy` in infra/pulumi (see docs/runbooks/disaster-recovery.md).
# Stop the VM (reversible; restart with `just vm-start`).
[group('infra')]
vm-stop:
    scripts/vm-power.sh stop

# Caveat: a plain start boots the EXISTING boot disk (the current system
# generation), NOT the latest registered image, and some runtime-only fixes do
# not survive a reboot — see the "Power management" section of
# docs/runbooks/disaster-recovery.md.
# Start the VM again after `just vm-stop`.
[group('infra')]
vm-start:
    scripts/vm-power.sh start

# EP-3 (docs/plans/3-nixos-host-nagare-01-with-k3s.md): build the NixOS
# GCE image on the remote x86_64-linux Nix builder, upload the tarball to
# the image-staging GCS bucket, register it as a GCE image, and write its
# self-link into Pulumi config key `nagareImageSelfLink`. The script owns
# the details.
# Build + upload + register the NixOS GCE image.
[group('host')]
host-image:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/upload-images.sh

# Show the registry host now carried by the generated context host flake.
[group('host')]
nixos-registry-host:
    @echo "nixos-registry-host no longer writes into the Nagare source."
    nagarectl host show

# EP-3: apply day-2 host configuration changes to the running nagare-01
# over Tailscale. The non-root deploy user needs --sudo.
# Apply day-2 host config to running nagare-01.
[group('host')]
host-switch:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/host-switch.sh

# Pinned upstream versions for the cluster platform (EP-4). These move; see
# each cluster/bootstrap/*/README.md for the version-discovery procedure.
# Knative Serving v1.22.0 has no net-certmanager release asset; the independent
# GCS artifact remains pinned at the verified v1.14.0 URL (checked 2026-08-24).
knative_version := "knative-v1.22.0"
certmanager_version := "v1.20.2"
netcertmanager_version := "v1.14.0"

# Local k3s image pin for `just local-up` (EP-82). k3d's compiled-in default k3s
# can be far older than what the platform needs (it defaulted to v1.21.7, whose
# apiserver rejects the cert-manager {{certmanager_version}} CRDs with "unknown
# field selectableFields"). Knative {{knative_version}} additionally refuses to
# run on Kubernetes older than 1.34.0 ("version ... is not compatible, need at
# least 1.34.0-0"), so pin a k3s >= 1.34 to reproduce the cloud's Kubernetes API
# surface. Bump in lockstep with the knative/certmanager pins above.
k3s_image := "rancher/k3s:v1.34.6-k3s1"

# EP-4 (docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md):
# install cert-manager + DNS-01 issuer, Knative Serving, Kourier ingress, and
# net-certmanager, then wire the config-network / config-domain / config-certmanager
# ConfigMaps. HTTP-first: external-domain-tls stays OFF here — run
# `just cluster-enable-tls` once a real baseDomain is delegated.
#
# Assumes KUBECONFIG points at the cluster (see the MasterPlan access note: an
# SSH local-forward to 127.0.0.1:6443 until Tailscale is joined) and that the
# Pulumi stack output `baseDomain` is the real apps domain.
# Install cert-manager, Knative Serving, Kourier + wire ConfigMaps (HTTP-first).
[group('cluster')]
cluster-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    for ns in cert-manager knative-serving kourier-system personal nagare-system; do \
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; \
    done
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook
    cluster/bootstrap/render-context-template.sh cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl | kubectl apply -f -
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
    kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
    BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
      : "${BASE_DOMAIN:?empty baseDomain — run 'pulumi -C infra/pulumi up' (or 'pulumi config set baseDomain …') before cluster-bootstrap}"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
    kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
    kubectl -n knative-serving patch configmap config-certmanager --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
    kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
    REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"; \
      kubectl -n knative-serving patch configmap config-deployment --type merge \
        --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform stamp; fi

# EP-95: install the two-slot ResourceQuota for deadline-bounded one-shot Jobs.
# Create/update the personal namespace and bounded Job-run quota.
[group('cluster')]
job-runs-bootstrap:
    kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f cluster/bootstrap/job-runs/resourcequota.yaml

# EP-95: show current quota usage and the admission events used as backpressure.
# Inspect the bounded Job-run quota, admitted Pods, and recent Job events.
[group('cluster')]
job-runs-status:
    kubectl -n personal describe resourcequota nagare-terminating-jobs
    kubectl -n personal get pods -o custom-columns='NAME:.metadata.name,DEADLINE:.spec.activeDeadlineSeconds,PHASE:.status.phase'
    kubectl -n personal get events --field-selector=reason=FailedCreate --sort-by=.lastTimestamp

# Show the selected kubectl context and API server without contacting the cluster.
[group('cluster')]
context-show:
    @printf 'context: '
    @kubectl config current-context
    @printf 'server:  '
    @kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'

# EP-4 (deferred): enable automatic per-namespace wildcard HTTPS. Only run this
# AFTER a real baseDomain is set in Pulumi config and delegated to the Cloud DNS
# zone's nameservers (see cluster/bootstrap/cert-manager/README.md).
# Enable automatic per-namespace wildcard HTTPS (run after baseDomain delegated).
[group('cluster')]
cluster-enable-tls:
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
    @echo "external-domain-tls enabled. Watch: kubectl get certificate -A -w"

# EP-82 (docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md):
# stand up the LOCAL development substrate — a k3d (k3s-in-Docker) cluster plus a
# managed local registry — so nagare can be exercised on a laptop with NO GCP
# account. Requires a running Docker daemon. Pair with `just local-bootstrap`.
# `--registry-create k3d-registry.localhost:0.0.0.0:5000` starts a registry
# container, injects a registries.yaml so in-cluster pulls of
# k3d-registry.localhost:5000/... resolve to it, AND binds it to host 0.0.0.0:5000
# so `docker push` reaches it. Traefik is disabled so it does not claim host
# port 80 and collide with Kourier; host 80/443 map to the cluster load balancer.
# Create the local k3d cluster + registry (NixOS/cloud substrate substitute).
[group('local')]
local-up:
    k3d cluster create nagare-local \
      --image {{k3s_image}} \
      --registry-create k3d-registry.localhost:0.0.0.0:5000 \
      --port "80:80@loadbalancer" \
      --port "443:443@loadbalancer" \
      --k3s-arg "--disable=traefik@server:0"
    @echo "Cluster up. For host 'docker push' to k3d-registry.localhost:5000 you need (see nagare.local.env.example):"
    @echo "  1) name resolution: add '127.0.0.1 k3d-registry.localhost' to /etc/hosts if your resolver ignores .localhost"
    @echo "  2) insecure registry: add 'k3d-registry.localhost:5000' to your Docker daemon insecure-registries and restart it"
    @echo "  (the in-cluster pull needs neither — k3d wires it automatically)"

# EP-82: tear down the local cluster (deleting it also removes the managed
# registry container).
# Delete the local k3d cluster + registry.
[group('local')]
local-down:
    k3d cluster delete nagare-local

# EP-82: install the SAME ingress stack the cloud uses (cert-manager + Knative
# Serving + Kourier + net-certmanager, at the pins above) onto the local k3d
# cluster, but HTTP-first for laptop use. This is `cluster-bootstrap` minus the
# three cloud-coupled steps:
#   - SKIP cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl (renders a GCP
#     project + needs ambient GCE creds); local TLS issuer is EP-85's job (IP-5).
#   - SKIP the config-certmanager patch (it points Knative at that letsencrypt-dns
#     issuer); external-domain-tls stays OFF so apps serve over HTTP.
#   - read the apps domain from NAGARE_BASE_DOMAIN (profile) instead of `pulumi
#     stack output baseDomain`, and put the LOCAL registry host into
#     registriesSkippingTagResolving.
# Requires the cluster (`just local-up`) and local mode active in the shell
# (NAGARE_MODE=local; copy nagare.local.env.example to nagare.local.env).
# Install Knative + Kourier + cert-manager on the local cluster (HTTP-first).
[group('local')]
local-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    for ns in cert-manager knative-serving kourier-system personal nagare-system; do \
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; \
    done
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook
    # NOTE: cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl is
    # intentionally NOT applied — it renders a GCP project and needs ambient GCE
    # creds. Local TLS issuer is EP-85's job (MasterPlan 16 IP-5).
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
    kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
    BASE_DOMAIN="${NAGARE_BASE_DOMAIN:?set NAGARE_MODE=local and copy nagare.local.env.example to nagare.local.env}"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
    kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
    # NOTE: config-certmanager patch is intentionally skipped — it points Knative at
    # the letsencrypt-dns ClusterIssuer this bootstrap does not install (EP-85 wires
    # the local issuer). external-domain-tls stays off, so apps serve over HTTP.
    kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
    REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-k3d-registry.localhost:5000}"; \
      kubectl -n knative-serving patch configmap config-deployment --type merge \
        --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform stamp; fi

# EP-84 (docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md):
# install the local MinIO object store — the S3-compatible stand-in for GCS that
# `db backup`/`db restore` and `storage snapshot`/`storage restore` move data
# through in local mode. Run AFTER `just local-bootstrap`; it does not duplicate
# any cluster setup. In-cluster S3 endpoint:
# http://minio.nagare-system.svc.cluster.local:9000 (bucket nagare-backups) — the
# NAGARE_LOCAL_OBJECT_STORE contract value.
# Install the local MinIO object store for backups/snapshots (EP-84).
[group('local')]
local-minio:
    # Ensure the default app/db namespace exists so the seeded credentials Secret
    # applies even if local-minio is run before local-bootstrap.
    kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f cluster/local/minio/minio.yaml
    kubectl -n nagare-system rollout status deploy/minio
    kubectl -n nagare-system wait --for=condition=complete --timeout=120s job/minio-make-bucket
    @echo "MinIO ready at http://minio.nagare-system.svc.cluster.local:9000 (bucket: nagare-backups)"

# EP-5 (docs/plans/5-victoria-observability-stack-and-grafana.md): install the
# VictoriaMetrics/Logs/Traces stack + OpenTelemetry Collector + Grafana via Helm.
# The script owns the pinned chart versions and the install order; it is idempotent
# (helm upgrade --install). Assumes KUBECONFIG points at the cluster.
# Install the VictoriaMetrics/Logs/Traces + OTel + Grafana stack.
[group('cluster')]
observability:
    cluster/observability/install.sh

# EP-4 ships the sample app; this applies it as a smoke test. Apply the
# Kubernetes manifests explicitly (the app contract is the typed
# nagare/Config.hs, not a k8s object, so it must not be passed to kubectl;
# `nagarectl deploy` is the path that renders it).
# Apply the hello Knative sample app as a smoke test.
[group('apps')]
deploy-hello:
    kubectl apply -f cluster/examples/hello-knative-service/service.yaml
    kubectl apply -f cluster/examples/hello-knative-service/domainmapping.yaml

# Quick cluster status across all namespaces (pods and Knative services).
[group('apps')]
status:
    kubectl get pods -A
    kubectl get ksvc -A

# EP-6 (docs/plans/70-cli-and-operator-harness-ergonomics.md): stand up a
# workstation->cluster kube connection in one command — open the IAP port-22
# tunnel, layer an ssh -L forward of the k3s API (127.0.0.1:6443 -> :16443),
# fetch /etc/rancher/k3s/k3s.yaml and rewrite its server: to the forwarded
# port, and print the KUBECONFIG to export. Reuses scripts/iap-ssh.sh.
# Open a workstation->cluster kube connection in one command.
[group('test')]
live-test:
    scripts/live-test.sh

# EP-5 (docs/plans/69-ci-pipeline-and-live-smoke-test.md): live smoke test.
# Starts the VM if needed, deploys a private-registry build-mode app, snapshots
# and RESTORES a volume (confirming a sentinel round-trips through GCS), verifies
# HTTP 200, and tears down. Requires the running VM + GCP credentials; this is
# NOT part of the per-PR offline CI (that is `nix flake check`).
# Run the live smoke test (deploy, volume snapshot/restore, HTTP 200, teardown).
[group('test')]
smoke:
    scripts/live-smoke.sh

# EP-86 (docs/plans/86): LOCAL smoke test — the cloud `smoke`'s zero-cloud twin.
# Assumes the EP-82 local cluster (stands it up with just local-up +
# local-bootstrap + local-minio if it is down); sets NAGARE_MODE=local so the GCP
# guardrail steps aside, deploys uploads-volume, round-trips a volume snapshot
# through local MinIO, verifies HTTP 200, and tears down. NO gcloud / IAP / GCS.
# Needs only Docker + the dev shell.
# Run the LOCAL smoke test (zero-cloud deploy, MinIO snapshot/restore, HTTP 200).
[group('test')]
local-smoke:
    scripts/local-smoke.sh
