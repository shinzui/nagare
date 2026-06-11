# Nagare command runner. These recipes are THIN WRAPPERS. The detailed
# contents of each step are owned by the child plans referenced below,
# under docs/plans/. Run `just --list` to see all recipes.
#
# All cloud commands target the GCP project configured in the target profile
# `nagare.target.env` (copy nagare.target.env.example to create one); with no
# profile they default to tan-nb-exp / us-west1 / us-west1-a. See .envrc and
# CLAUDE.md. Enter the dev shell first with `nix develop`, or let direnv load
# it automatically after `direnv allow`.

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

# Pinned upstream versions for the cluster platform (EP-4). These move; see
# each cluster/bootstrap/*/README.md for the version-discovery procedure.
# net-certmanager froze at v1.14.0 (its line diverged from Knative's).
knative_version := "knative-v1.22.0"
certmanager_version := "v1.20.2"
netcertmanager_version := "v1.14.0"

# EP-4 (docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md):
# install cert-manager + DNS-01 issuer, Knative Serving, Kourier ingress, and
# net-certmanager, then wire the config-network / config-domain / config-certmanager
# ConfigMaps. HTTP-first: external-domain-tls stays OFF here — run
# `just cluster-enable-tls` once a real baseDomain is delegated.
#
# Assumes KUBECONFIG points at the cluster (see the MasterPlan access note: an
# SSH local-forward to 127.0.0.1:6443 until Tailscale is joined) and that the
# Pulumi stack output `baseDomain` is the real apps domain.
cluster-bootstrap:
    for ns in cert-manager knative-serving kourier-system personal; do \
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; \
    done
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{{certmanager_version}}/cert-manager.yaml
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook
    kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-crds.yaml
    kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/serving-core.yaml
    kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/{{knative_version}}/kourier.yaml
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network.yaml)"
    BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
    kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml
    kubectl -n knative-serving patch configmap config-certmanager --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-certmanager.yaml)"
    kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
    REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"; \
      kubectl -n knative-serving patch configmap config-deployment --type merge \
        --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"

# EP-4 (deferred): enable automatic per-namespace wildcard HTTPS. Only run this
# AFTER a real baseDomain is set in Pulumi config and delegated to the Cloud DNS
# zone's nameservers (see cluster/bootstrap/cert-manager/README.md).
cluster-enable-tls:
    kubectl -n knative-serving patch configmap config-network --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-network-tls.yaml)"
    @echo "external-domain-tls enabled. Watch: kubectl get certificate -A -w"

# EP-5 (docs/plans/5-victoria-observability-stack-and-grafana.md): install the
# VictoriaMetrics/Logs/Traces stack + OpenTelemetry Collector + Grafana via Helm.
# The script owns the pinned chart versions and the install order; it is idempotent
# (helm upgrade --install). Assumes KUBECONFIG points at the cluster.
observability:
    cluster/observability/install.sh

# EP-4 ships the sample app; this applies it as a smoke test. Apply the
# Kubernetes manifests explicitly (the app contract is the typed
# nagare/Config.hs, not a k8s object, so it must not be passed to kubectl;
# `nagarectl deploy` is the path that renders it).
deploy-hello:
    kubectl apply -f cluster/examples/hello-knative-service/service.yaml
    kubectl apply -f cluster/examples/hello-knative-service/domainmapping.yaml

# Quick cluster status across all namespaces (pods and Knative services).
status:
    kubectl get pods -A
    kubectl get ksvc -A

# EP-6 (docs/plans/70-cli-and-operator-harness-ergonomics.md): stand up a
# workstation->cluster kube connection in one command — open the IAP port-22
# tunnel, layer an ssh -L forward of the k3s API (127.0.0.1:6443 -> :16443),
# fetch /etc/rancher/k3s/k3s.yaml and rewrite its server: to the forwarded
# port, and print the KUBECONFIG to export. Reuses scripts/iap-ssh.sh.
live-test:
    scripts/live-test.sh
