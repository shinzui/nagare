# Nagare command runner. These recipes are THIN WRAPPERS. The detailed
# contents of each step are owned by the child plans referenced below,
# under docs/plans/. Run `just --list` to see all recipes.
#
# All cloud commands target the tan-nb-exp GCP project (see .envrc and
# CLAUDE.md). Enter the dev shell first with `nix develop`, or let direnv
# load it automatically after `direnv allow`.

# Show all recipes.
default:
    @just --list

# EP-2 (docs/plans/2-pulumi-gcp-infrastructure.md): create/update the GCP
# resources (VM, static IP, Cloud DNS, disks, service account, Artifact
# Registry, backup bucket).
infra-up:
    cd infra/pulumi && pulumi up

# EP-2: preview the Pulumi changes without applying them.
infra-preview:
    cd infra/pulumi && pulumi preview

# EP-3 (docs/plans/3-nixos-host-nagare-01-with-k3s.md): build the NixOS
# GCE image on the remote x86_64-linux Nix builder, upload the tarball to
# the image-staging GCS bucket, register it as a GCE image, and write its
# self-link into Pulumi config key `nagareImageSelfLink`. The script owns
# the details.
host-image:
    scripts/upload-images.sh

# EP-3: apply day-2 host configuration changes to the running nagare-01
# over Tailscale. The non-root deploy user needs --sudo.
host-switch:
    nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo

# EP-4 (docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md):
# install cert-manager, Knative Serving, Kourier ingress, and the
# config-domain / config-network wiring.
cluster-bootstrap:
    kubectl apply -f cluster/bootstrap/cert-manager
    kubectl apply -f cluster/bootstrap/knative-serving
    kubectl apply -f cluster/bootstrap/kourier
    kubectl apply -f cluster/bootstrap/config-domain

# EP-5 (docs/plans/5-victoria-observability-stack-and-grafana.md): install
# the VictoriaMetrics/Logs/Traces stack + Grafana via Helm.
observability:
    helm repo add vm https://victoriametrics.github.io/helm-charts/
    helm repo update
    helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
      --namespace monitoring --create-namespace \
      -f cluster/observability/victoria-metrics/values.yaml
    helm upgrade --install victoria-logs vm/victoria-logs-single \
      --namespace logging --create-namespace \
      -f cluster/observability/victoria-logs/values.yaml
    helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
      --namespace logging \
      -f cluster/observability/victoria-logs/collector-values.yaml
    helm upgrade --install victoria-traces vm/victoria-traces-single \
      --namespace tracing --create-namespace \
      -f cluster/observability/victoria-traces/values.yaml

# EP-4 ships the sample app; this applies it as a smoke test.
deploy-hello:
    kubectl apply -f cluster/examples/hello-knative-service

# Quick cluster status across all namespaces (pods and Knative services).
status:
    kubectl get pods -A
    kubectl get ksvc -A
